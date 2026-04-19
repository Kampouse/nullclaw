//! Continuous consolidation & learning scheduler.
//!
//! This module implements the always-on learning system that runs periodically
//! to extract patterns from conversations and prepare training data for LoRA
//! fine-tuning. Integrates with the cron scheduler for background execution.
//!
//! ## Workflow
//!
//! 1. **Collection**: Gather conversations since last consolidation run
//! 2. **Extraction**: Run consolidation engine to extract patterns
//! 3. **Storage**: Store patterns in SQLite for approval workflow
//! 4. **Validation**: Run test-based validation where applicable
//! 5. **Training Prep**: Prepare training data when enough patterns approved
//!
//! ## Configuration
//!
//! ```zig
//! pub const ConsolidationSchedule = struct {
//!     enabled: bool = false,
//!     interval_minutes: u32 = 30,
//!     min_conversations: usize = 10,
//!     auto_approve_positive: bool = true,
//!     auto_approve_improvement: bool = false,
//!     feedback_loop_detection: bool = true,
//! };
//! ```

const std = @import("std");
const consolidation = @import("consolidation.zig");
const mem_root = @import("../root.zig");
const Memory = mem_root.Memory;
const MemoryEntry = mem_root.MemoryEntry;
const ConvMessageEntry = consolidation.MessageEntry;

const log = std.log.scoped(.consolidation_scheduler);

// ── Configuration ─────────────────────────────────────────────────────

/// Scheduler configuration for periodic consolidation.
pub const ConsolidationSchedule = struct {
    enabled: bool = false,
    interval_minutes: u32 = 30,
    min_conversations: usize = 10,
    auto_approve_positive: bool = true,
    auto_approve_improvement: bool = false,
    feedback_loop_detection: bool = true,
};

// ── Timestamp Utilities ───────────────────────────────────────────────

/// Get current Unix timestamp (milliseconds).
fn timestampMillis() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @as(i64, tv.sec) * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
}

// ── Consolidation Scheduler ───────────────────────────────────────────

/// Continuous consolidation scheduler that runs periodic pattern extraction.
pub const ConsolidationScheduler = struct {
    engine: consolidation.ConsolidationEngine,
    allocator: std.mem.Allocator,
    last_run_timestamp: i64 = 0,
    last_conversation_id: ?[]const u8 = null,
    metrics: Metrics = .{},

    const Self = @This();

    /// Runtime metrics for the consolidation scheduler.
    pub const Metrics = struct {
        total_runs: usize = 0,
        total_conversations_processed: usize = 0,
        total_patterns_extracted: usize = 0,
        total_patterns_approved: usize = 0,
        total_patterns_rejected: usize = 0,
        feedback_loop_detected: bool = false,
        recent_rewards: std.ArrayListUnmanaged(f32) = .empty,

        pub fn deinit(self: *Metrics, allocator: std.mem.Allocator) void {
            self.recent_rewards.deinit(allocator);
        }
    };

    /// Initialize a new consolidation scheduler.
    pub fn init(allocator: std.mem.Allocator, config: consolidation.ConsolidationConfig) Self {
        return Self{
            .engine = consolidation.ConsolidationEngine.init(allocator, config),
            .allocator = allocator,
        };
    }

    /// Deinitialize and free resources.
    pub fn deinit(self: *Self) void {
        self.engine.deinit();
        self.metrics.deinit(self.allocator);
        if (self.last_conversation_id) |id| {
            self.allocator.free(id);
        }
    }

    /// Check if consolidation should run based on schedule.
    pub fn shouldRun(self: *const Self, schedule: ConsolidationSchedule) bool {
        if (!schedule.enabled) return false;

        const now = timestampMillis();
        const interval_ms = @as(i64, schedule.interval_minutes) * 60 * 1000;
        const elapsed = now - self.last_run_timestamp;

        return elapsed >= interval_ms;
    }

    /// Collect conversation batches from memory since last consolidation.
    /// Returns conversations grouped by session/conversation.
    pub fn collectConversations(
        self: *Self,
        memory: *Memory,
        since_timestamp: i64,
        limit: usize,
    ) ![]consolidation.ConversationBatch {
        // 1. Query all conversation-category entries from memory
        const entries = memory.list(self.allocator, .conversation, null) catch return try self.allocator.alloc(consolidation.ConversationBatch, 0);
        defer mem_root.freeEntries(self.allocator, entries);

        // 2. Build an ISO timestamp string for since_timestamp comparison.
        //    since_timestamp is i64 millis; MemoryEntry.timestamp is an ISO string.
        //    Lexicographic comparison works for ISO 8601 format.
        const since_iso = if (since_timestamp > 0) blk: {
            const epoch_secs = @divTrunc(since_timestamp, 1000);
            // Format as ISO 8601: YYYY-MM-DDTHH:MM:SS
            const epoch_days = @divTrunc(epoch_secs, 86400);
            const day_secs: i64 = @intCast(@mod(epoch_secs, 86400));
            // Compute date from epoch days (simplified algorithm)
            var y: i64 = 1970;
            var days_remaining = epoch_days;
            while (true) {
                const days_in_year: i64 = if (@mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0)) 366 else 365;
                if (days_remaining < days_in_year) break;
                days_remaining -= days_in_year;
                y += 1;
            }
            const is_leap = @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
            const month_days = if (is_leap)
                [_]u5{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
            else
                [_]u5{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
            var m: usize = 0;
            while (m < 12) : (m += 1) {
                if (days_remaining < month_days[m]) break;
                days_remaining -= month_days[m];
            }
            const d = days_remaining + 1;
            const hours = @divTrunc(day_secs, 3600);
            const mins = @divTrunc(@mod(day_secs, 3600), 60);
            const secs = @mod(day_secs, 60);
            const iso = try std.fmt.allocPrint(self.allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ y, m + 1, d, hours, mins, secs });
            break :blk iso;
        } else null;
        defer if (since_iso) |iso| self.allocator.free(iso);

        // 3. Group entries by session_id using a StringHashMap.
        //    Each value is an ArrayListUnmanaged of indices into `entries`.
        var session_groups: std.StringHashMap(std.ArrayListUnmanaged(usize)) = std.StringHashMap(std.ArrayListUnmanaged(usize)).init(self.allocator);
        defer {
            var it = session_groups.iterator();
            while (it.next()) |kv| {
                kv.value_ptr.deinit(self.allocator);
                self.allocator.free(kv.key_ptr.*);
            }
            session_groups.deinit();
        }

        for (entries, 0..) |entry, idx| {
            // Skip entries without a session_id
            const sid = entry.session_id orelse continue;

            // Quality filter: skip entries with content shorter than 10 chars
            if (entry.content.len < 10) continue;

            // Timestamp filter: skip entries before since_timestamp
            if (since_iso) |iso| {
                if (std.mem.order(u8, entry.timestamp, iso) == .lt) continue;
            }

            const gop = try session_groups.getOrPut(sid);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, sid);
                gop.value_ptr.* = .empty;
            }
            try gop.value_ptr.append(self.allocator, idx);
        }

        // 4. Build ConversationBatch slices, respecting the limit
        const batch_count = @min(session_groups.count(), limit);
        const batches = try self.allocator.alloc(consolidation.ConversationBatch, batch_count);

        var it = session_groups.iterator();
        var batch_idx: usize = 0;
        while (it.next()) |kv| {
            if (batch_idx >= batch_count) break;
            const session_id = kv.key_ptr.*;
            const indices = kv.value_ptr.items;

            // Allocate message slice
            const msg_slice = try self.allocator.alloc(ConvMessageEntry, indices.len);
            for (indices, 0..) |entry_idx, msg_idx| {
                // Dupe content so it survives freeEntries of the original list
                const content_dupe = try self.allocator.dupe(u8, entries[entry_idx].content);
                msg_slice[msg_idx] = .{
                    .role = "message",
                    .content = content_dupe,
                };
            }

            batches[batch_idx] = .{
                .messages = msg_slice,
                .conversation_id = try self.allocator.dupe(u8, session_id),
            };
            batch_idx += 1;
        }

        return batches;
    }

    /// Run a single consolidation cycle.
    pub fn tick(
        self: *Self,
        memory: *Memory,
        schedule: ConsolidationSchedule,
    ) !?consolidation.ConsolidationResult {
        if (!self.shouldRun(schedule)) {
            return null;
        }

        log.info("Starting consolidation run #{d}", .{self.metrics.total_runs + 1});

        // 1. Collect conversations since last run
        const conversations = try self.collectConversations(
            memory,
            self.last_run_timestamp,
            schedule.min_conversations,
        );
        defer {
            for (conversations) |*conv| {
                for (conv.messages) |msg| {
                    // role is a string literal, don't free; content was duped
                    self.allocator.free(msg.content);
                }
                self.allocator.free(conv.messages);
                self.allocator.free(conv.conversation_id);
            }
            self.allocator.free(conversations);
        }

        if (conversations.len < schedule.min_conversations) {
            log.info("Not enough conversations for consolidation ({d} < {d})", .{
                conversations.len, schedule.min_conversations
            });
            return null;
        }

        // 2. Extract patterns via consolidation engine
        const result = try self.engine.processBatch(conversations);
        errdefer result.deinit(self.allocator);

        // 3. Update metrics
        self.metrics.total_runs += 1;
        self.metrics.total_conversations_processed += conversations.len;
        self.metrics.total_patterns_extracted += result.patterns.len;

        // 4. Track rewards for feedback loop detection
        if (schedule.feedback_loop_detection) {
            for (result.patterns) |pattern| {
                try self.metrics.recent_rewards.append(self.allocator, pattern.reward);
            }
            self.metrics.feedback_loop_detected = self.detectFeedbackLoop();
        }

        // 5. Auto-approve based on configuration
        for (result.patterns) |*pattern| {
            const should_approve = switch (pattern.pattern_type) {
                .positive => schedule.auto_approve_positive,
                .negative => false, // Never auto-approve negative patterns
                .improvement => schedule.auto_approve_improvement,
            };

            if (should_approve and pattern.confidence >= 0.8) {
                self.metrics.total_patterns_approved += 1;
            }
        }

        // 6. Update timestamp
        self.last_run_timestamp = timestampMillis();
        if (conversations.len > 0) {
            if (self.last_conversation_id) |old| {
                self.allocator.free(old);
            }
            self.last_conversation_id = try self.allocator.dupe(
                u8,
                conversations[conversations.len - 1].conversation_id,
            );
        }

        log.info("Consolidation complete: {d} patterns extracted from {d} conversations", .{
            result.patterns.len, conversations.len
        });

        return result;
    }

    /// Detect feedback loop based on recent reward history.
    /// Returns true if average reward is below threshold (negative spiral).
    pub fn detectFeedbackLoop(self: *const Self) bool {
        const window_size = 100;
        const threshold: f32 = -0.3;

        if (self.metrics.recent_rewards.items.len < window_size) {
            return false;
        }

        const start = self.metrics.recent_rewards.items.len - window_size;
        var sum: f32 = 0;
        for (self.metrics.recent_rewards.items[start..]) |reward| {
            sum += reward;
        }

        const average = @as(f32, @floatCast(sum)) / @as(f32, @floatFromInt(window_size));
        return average < threshold;
    }

    /// Get snapshot of current metrics.
    pub fn getMetrics(self: *const Self) Metrics {
        return .{
            .total_runs = self.metrics.total_runs,
            .total_conversations_processed = self.metrics.total_conversations_processed,
            .total_patterns_extracted = self.metrics.total_patterns_extracted,
            .total_patterns_approved = self.metrics.total_patterns_approved,
            .total_patterns_rejected = self.metrics.total_patterns_rejected,
            .feedback_loop_detected = self.metrics.feedback_loop_detected,
            .recent_rewards = .empty, // Don't copy rewards array
        };
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

test "ConsolidationScheduler initializes correctly" {
    const allocator = std.testing.allocator;

    const mock_callback = struct {
        fn callback(
            alloc: std.mem.Allocator,
            prompt: []const u8,
        ) anyerror![]const u8 {
            _ = alloc;
            _ = prompt;
            return error.MockNotImplemented;
        }
    }.callback;

    const config = consolidation.ConsolidationConfig{
        .llm_callback = mock_callback,
        .min_confidence = 0.6,
    };

    var scheduler = try ConsolidationScheduler.init(allocator, config);
    defer scheduler.deinit();

    try std.testing.expectEqual(@as(usize, 0), scheduler.metrics.total_runs);
    try std.testing.expectEqual(@as(i64, 0), scheduler.last_run_timestamp);
}

test "shouldRun returns false when disabled" {
    const allocator = std.testing.allocator;
    const config = consolidation.ConsolidationConfig{ .llm_callback = null };

    var scheduler = try ConsolidationScheduler.init(allocator, config);
    defer scheduler.deinit();

    const schedule = ConsolidationSchedule{ .enabled = false };
    try std.testing.expect(!scheduler.shouldRun(schedule));
}

test "shouldRun returns false before interval" {
    const allocator = std.testing.allocator;
    const config = consolidation.ConsolidationConfig{ .llm_callback = null };

    var scheduler = try ConsolidationScheduler.init(allocator, config);
    defer scheduler.deinit();
    scheduler.last_run_timestamp = timestampMillis();

    // 1 minute interval, just ran
    const schedule = ConsolidationSchedule{
        .enabled = true,
        .interval_minutes = 1,
    };

    try std.testing.expect(!scheduler.shouldRun(schedule));
}

test "shouldRun returns true after interval" {
    const allocator = std.testing.allocator;
    const config = consolidation.ConsolidationConfig{ .llm_callback = null };

    var scheduler = try ConsolidationScheduler.init(allocator, config);
    defer scheduler.deinit();

    // Set last run to 2 hours ago
    scheduler.last_run_timestamp = timestampMillis() - (2 * 60 * 60 * 1000);

    // 1 minute interval
    const schedule = ConsolidationSchedule{
        .enabled = true,
        .interval_minutes = 1,
    };

    try std.testing.expect(scheduler.shouldRun(schedule));
}

test "detectFeedbackLoop returns false with insufficient data" {
    const allocator = std.testing.allocator;
    const config = consolidation.ConsolidationConfig{ .llm_callback = null };

    var scheduler = try ConsolidationScheduler.init(allocator, config);
    defer scheduler.deinit();

    // Add less than 100 rewards
    for (0..50) |_| {
        try scheduler.metrics.recent_rewards.append(allocator, -1.0);
    }

    try std.testing.expect(!scheduler.detectFeedbackLoop());
}

test "detectFeedbackLoop detects negative spiral" {
    const allocator = std.testing.allocator;
    const config = consolidation.ConsolidationConfig{ .llm_callback = null };

    var scheduler = try ConsolidationScheduler.init(allocator, config);
    defer scheduler.deinit();

    // Add 100 negative rewards (below -0.3 threshold)
    for (0..100) |_| {
        try scheduler.metrics.recent_rewards.append(allocator, -0.8);
    }

    try std.testing.expect(scheduler.detectFeedbackLoop());
}

test "detectFeedbackLoop returns false with mixed rewards" {
    const allocator = std.testing.allocator;
    const config = consolidation.ConsolidationConfig{ .llm_callback = null };

    var scheduler = try ConsolidationScheduler.init(allocator, config);
    defer scheduler.deinit();

    // Mix of positive and negative rewards
    for (0..50) |_| {
        try scheduler.metrics.recent_rewards.append(allocator, 1.0);
    }
    for (0..50) |_| {
        try scheduler.metrics.recent_rewards.append(allocator, -0.5);
    }

    // Average = (50*1.0 + 50*-0.5) / 100 = 0.25 > -0.3
    try std.testing.expect(!scheduler.detectFeedbackLoop());
}

test "getMetrics returns snapshot" {
    const allocator = std.testing.allocator;
    const config = consolidation.ConsolidationConfig{ .llm_callback = null };

    var scheduler = try ConsolidationScheduler.init(allocator, config);
    defer scheduler.deinit();

    scheduler.metrics.total_runs = 42;
    scheduler.metrics.total_conversations_processed = 100;
    scheduler.metrics.total_patterns_extracted = 200;

    const metrics = scheduler.getMetrics();
    try std.testing.expectEqual(@as(usize, 42), metrics.total_runs);
    try std.testing.expectEqual(@as(usize, 100), metrics.total_conversations_processed);
    try std.testing.expectEqual(@as(usize, 200), metrics.total_patterns_extracted);
}
