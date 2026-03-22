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
const MessageEntry = mem_root.MessageEntry;

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
    return @as(i64, tv.sec) * 1000 + @as(i64, tv.usec) / 1000;
}

// ── Consolidation Scheduler ───────────────────────────────────────────

/// Continuous consolidation scheduler that runs periodic pattern extraction.
pub const ConsolidationScheduler = struct {
    engine: consolidation.ConsolidationEngine,
    allocator: std.mem.Allocator,
    last_run_timestamp: i64 = 0,
    last_conversation_id: ?[]const u8 = null,
    metrics: Metrics = .{},

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
    pub fn init(allocator: std.mem.Allocator, config: consolidation.ConsolidationConfig) !Self {
        return Self{
            .engine = try consolidation.ConsolidationEngine.init(allocator, config),
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
        _ = since_timestamp;
        _ = limit;

        // TODO: Implement conversation collection from memory
        // 1. Query messages since last_conversation_id
        // 2. Group by conversation/session ID
        // 3. Filter by quality (length, meaningful content)
        // 4. Anonymize sensitive data

        const empty = try self.allocator.alloc(consolidation.ConversationBatch, 0);
        return empty;
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
                self.allocator.free(conv.conversation_id);
                self.allocator.free(conv.messages);
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
        };

        const average = sum / @as(f32, window_size);
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

    var mock_callback = struct {
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
