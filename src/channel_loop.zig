//! Channel Loop — extracted polling loops for daemon-supervised channels.
//!
//! Contains `ChannelRuntime` (shared dependencies for message processing)
//! and `runTelegramLoop` (the polling thread function spawned by the
//! daemon supervisor).
//!
//! Uses worker pool for parallel message processing:
//!   - Poll thread: enqueue messages (non-blocking)
//!   - Worker threads: process messages (parallel, per-session locking)

const std = @import("std");
const util = @import("util.zig");
const Config = @import("config.zig").Config;
const telegram = @import("channels/telegram.zig");
const session_mod = @import("session.zig");
const ConversationContext = @import("agent/prompt.zig").ConversationContext;
const providers = @import("providers/root.zig");
const memory_mod = @import("memory/root.zig");
const observability = @import("observability.zig");
const tools_mod = @import("tools/root.zig");
const mcp = @import("mcp.zig");
const voice = @import("voice.zig");
const health = @import("health.zig");
const daemon = @import("daemon.zig");
const security = @import("security/policy.zig");
const subagent_mod = @import("subagent.zig");
const agent_routing = @import("agent_routing.zig");
const provider_runtime = @import("providers/runtime_bundle.zig");
const worker_pool_mod = @import("worker_pool.zig");
const Spinlock = @import("spinlock.zig").Spinlock;

const signal = @import("channels/signal.zig");
const matrix = @import("channels/matrix.zig");
const channels_mod = @import("channels/root.zig");
const Atomic = @import("portable_atomic.zig").Atomic;

const log = std.log.scoped(.channel_loop);
const TELEGRAM_OFFSET_STORE_VERSION: i64 = 1;

// ════════════════════════════════════════════════════════════════════════════
// Message Classification (Hybrid Strategy)
// ════════════════════════════════════════════════════════════════════════════

const MessageClass = enum {
    /// Independent query - can be processed in parallel (no context needed)
    /// Examples: "/status", "BTC price?", "What's 2+2?"
    independent,

    /// Conversational - needs sequential processing (context-dependent)
    /// Examples: "And tomorrow?", "What about that?", "Continue"
    conversational,
};

/// Classify a message as independent or conversational
fn classifyMessage(content: []const u8) MessageClass {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");

    // Empty message → conversational (will error anyway)
    if (trimmed.len == 0) return .conversational;

    // 1. Commands are always independent
    if (std.mem.startsWith(u8, trimmed, "/")) return .independent;

    const lower = std.ascii.allocLowerString(std.heap.page_allocator, trimmed) catch return .conversational;
    defer std.heap.page_allocator.free(lower);

    // 2. Check for context-dependent keywords at START of message
    const context_starters = [_][]const u8{
        "and ",  "and\t",  "and\n", // "And tomorrow?" but not "Android"
        "also ", "also\t",
        "too", // "me too"
        "continue",
        "go on",
        "keep going",
        "what about",
        "how about",
        "what else",
        "tell me more",
        "why", // Usually follow-up
        "how so",
        "what do you mean",
        "i mean",
        "i meant",
        "actually",
        "wait",
        "sorry",
        "nevermind",
        "forget it",
    };

    for (context_starters) |starter| {
        if (std.mem.startsWith(u8, lower, starter)) {
            return .conversational;
        }
    }

    // 3. Pronoun detection (context references)
    const pronouns = [_][]const u8{
        " it ",   " it?",   " it.",   " it!",   "\nit",   "\tit",
        " that ", " that?", " that.", " that!", " this ", " this?",
        " this.", " this!", " he ",   " he?",   " he.",   " he!",
        " she ",  " she?",  " she.",  " she!",  " they ", " they?",
        " they.", " they!", " them ", " them?", " them.", " them!",
    };

    for (pronouns) |pronoun| {
        if (std.mem.indexOf(u8, lower, pronoun) != null) {
            return .conversational;
        }
    }

    // 4. Questions are usually independent (unless they start with follow-up words)
    if (std.mem.indexOfScalar(u8, trimmed, '?') != null) {
        // Has question mark - likely independent
        // Exception: if it STARTS with "and", "also", etc. (already checked above)
        return .independent;
    }

    // 5. Currency symbols indicate independent queries
    if (std.mem.indexOfAny(u8, trimmed, "$€£¥₿") != null) {
        return .independent;
    }

    // 6. Short follow-ups (< 10 chars, no question mark)
    if (trimmed.len < 10) {
        return .conversational;
    }

    // 7. Default: conversational (safer)
    return .conversational;
}

// ════════════════════════════════════════════════════════════════════════════
// Telegram Worker Pool Types
// ════════════════════════════════════════════════════════════════════════════

/// Message context for worker pool processing
const TelegramWorkerMessage = struct {
    sender: []const u8,
    sender_first_name: ?[]const u8,
    sender_id: []const u8,
    content: []const u8,
    is_group: bool,
    message_id: ?i64,
    account_id: []const u8,
    message_class: MessageClass, // Added: classification

    pub fn deinit(self: *const TelegramWorkerMessage, allocator: std.mem.Allocator) void {
        // Defensive cleanup: only free valid allocated memory
        // Use sentinel checks to detect corruption before freeing
        if (self.sender.len > 0 and self.sender.len < 1024 * 1024) {
            allocator.free(self.sender);
        }
        if (self.sender_first_name) |name| {
            if (name.len > 0 and name.len < 1024) {
                allocator.free(name);
            }
        }
        if (self.sender_id.len > 0 and self.sender_id.len < 1024) {
            allocator.free(self.sender_id);
        }
        if (self.content.len > 0 and self.content.len < 100 * 1024 * 1024) {
            allocator.free(self.content);
        }
        if (self.account_id.len > 0 and self.account_id.len < 1024) {
            allocator.free(self.account_id);
        }
    }
};

/// Handler for worker pool message processing
const TelegramWorkerHandler = struct {
    tg_ptr: *telegram.TelegramChannel,
    runtime: *ChannelRuntime,
    config: *const Config,
    session_locks: ?*worker_pool_mod.SessionLockManager,
    allocator: std.mem.Allocator,

    pub fn process(self: TelegramWorkerHandler, msg: TelegramWorkerMessage) void {
        // Ensure message is always cleaned up, even if validation fails
        defer msg.deinit(self.allocator);

        // Wrap everything in error handler to ensure we never propagate errors up
        self.processInternal(msg) catch |err| {
            log.err("Worker process error: {} - this should not happen", .{err});
        };
    }

    fn processInternal(self: TelegramWorkerHandler, msg: TelegramWorkerMessage) !void {
        // Safety check: validate required pointers
        if (msg.account_id.len == 0 or msg.sender.len == 0) {
            log.warn("Skipping message with empty account_id or sender in worker", .{});
            return;
        }

        const reply_to_id: ?i64 = if (msg.is_group or self.tg_ptr.reply_in_private) msg.message_id else null;

        // Build session key
        var key_buf: [256]u8 = undefined;
        var routed_session_key: ?[]const u8 = null;
        defer if (routed_session_key) |key| self.allocator.free(key);

        const session_key = blk: {
            const route = agent_routing.resolveRouteWithSession(self.allocator, .{
                .channel = "telegram",
                .account_id = msg.account_id,
                .peer = .{ .kind = if (msg.is_group) .group else .direct, .id = msg.sender },
            }, self.config.agent_bindings, self.config.agents, self.config.session) catch break :blk std.fmt.bufPrint(&key_buf, "telegram:{s}:{s}", .{ msg.account_id, msg.sender }) catch msg.sender;
            self.allocator.free(route.main_session_key);
            routed_session_key = route.session_key;
            break :blk route.session_key;
        };

        // Session serialization: only lock if config says to (default: false for full parallelism)
        // Message deduplication already prevents spam, so ordering is optional
        var session_lock: ?*Spinlock = null;
        if (self.config.session.serialize_sessions) {
            if (self.session_locks) |locks| {
                session_lock = locks.acquire(session_key);
            }
        }
        defer if (session_lock) |lock| self.session_locks.?.release(lock);

        // Start typing indicator
        self.tg_ptr.startTyping(msg.sender) catch {};
        defer self.tg_ptr.stopTyping(msg.sender) catch {};

        // Process message through agent
        const reply = self.runtime.session_mgr.processMessage(session_key, msg.content, null) catch |err| {
            log.err("Agent error: {}", .{err});
            const err_msg: []const u8 = switch (err) {
                error.CurlFailed, error.CurlReadError, error.CurlWaitError, error.CurlWriteError => "Network error. Please try again.",
                error.ProviderDoesNotSupportVision => "The current provider does not support image input. Switch to a vision-capable provider or remove [IMAGE:] attachments.",
                error.NoResponseContent => "Model returned an empty response. Please retry or /new for a fresh session.",
                error.AllProvidersFailed => "All configured providers failed for this request. Check model/provider compatibility and credentials.",
                error.OutOfMemory => "Out of memory.",
                else => "An error occurred. Try again or /new for a fresh session.",
            };
            self.tg_ptr.sendMessageWithReply(msg.sender, err_msg, reply_to_id) catch |send_err| log.err("failed to send error reply: {}", .{send_err});
            return;
        };
        defer self.allocator.free(reply);

        // Send reply
        self.tg_ptr.sendAssistantMessageWithReply(msg.sender, msg.sender_id, msg.is_group, reply, reply_to_id) catch |err| {
            log.warn("Send error: {}", .{err});
        };
    }
};

const TelegramWorkerPool = worker_pool_mod.WorkerPool(TelegramWorkerMessage, TelegramWorkerHandler);

fn extractTelegramBotId(bot_token: []const u8) ?[]const u8 {
    const colon_pos = std.mem.indexOfScalar(u8, bot_token, ':') orelse return null;
    if (colon_pos == 0) return null;
    const raw = std.mem.trim(u8, bot_token[0..colon_pos], " \t\r\n");
    if (raw.len == 0) return null;
    for (raw) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return raw;
}

fn normalizeTelegramAccountId(allocator: std.mem.Allocator, account_id: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, account_id, " \t\r\n");
    const source = if (trimmed.len == 0) "default" else trimmed;
    var normalized = try allocator.alloc(u8, source.len);
    for (source, 0..) |c, i| {
        normalized[i] = if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-') c else '_';
    }
    return normalized;
}

/// Check if a message is a duplicate (same user, same content within window)
/// Also enforces command-specific cooldowns (e.g., /reset every 10 seconds)
/// Returns true if message should be skipped, false if it should be processed
fn shouldSkipDuplicateMessage(
    loop_state: *TelegramLoopState,
    allocator: std.mem.Allocator,
    user_id: []const u8,
    content: []const u8,
) bool {
    const now = util.timestampUnix();
    const trimmed = std.mem.trim(u8, content, " \t\r\n");

    // Command-specific cooldowns
    const cooldown_secs: i64 = if (std.mem.eql(u8, trimmed, "/reset") or std.mem.eql(u8, trimmed, "/new"))
        10 // /reset and /new have 10 second cooldown
    else
        2; // Other commands have 2 second dedup window

    const content_hash = std.hash.Wyhash.hash(0, trimmed);

    loop_state.cache_spinlock.lock();
    defer loop_state.cache_spinlock.unlock();

    // Clean up old entries (older than 30 seconds) to prevent memory buildup
    // NOTE: Collect keys first, then remove (can't modify map during iteration)
    const cleanup_threshold = now - 30;
    var keys_to_remove = std.ArrayList([]const u8).initCapacity(allocator, 8) catch return false;
    defer keys_to_remove.deinit(allocator);  // Free ArrayList backing storage
    
    var iter = loop_state.message_cache.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.timestamp < cleanup_threshold) {
            keys_to_remove.appendAssumeCapacity(entry.key_ptr.*);
        }
    }
    
    // Now safely remove collected keys (and free the key strings)
    for (keys_to_remove.items) |key| {
        allocator.free(key);
        _ = loop_state.message_cache.remove(key);
    }

    // Check if this user sent the same command recently
    const gop = loop_state.message_cache.getOrPut(allocator, user_id) catch return false;
    if (!gop.found_existing) {
        // First message from this user, store it
        gop.key_ptr.* = allocator.dupe(u8, user_id) catch return false;
        gop.value_ptr.* = .{ .content_hash = content_hash, .timestamp = now };
        return false; // Don't skip
    }

    // User has sent messages before, check if this is a duplicate or on cooldown
    const entry = gop.value_ptr.*;
    const time_diff = now - entry.timestamp;

    // Check if same command (exact match)
    if (entry.content_hash == content_hash) {
        if (time_diff < cooldown_secs) {
            log.debug("Skipping duplicate '{s}' from user={s} (cooldown: {d}/{d}s)", .{ trimmed, user_id, time_diff, cooldown_secs });
            return true; // Skip duplicate
        }
    }

    // For /reset specifically, also block different commands within cooldown window
    // to prevent /reset -> /new spam
    if (std.mem.eql(u8, trimmed, "/reset") or std.mem.eql(u8, trimmed, "/new")) {
        if (time_diff < cooldown_secs) {
            log.debug("Skipping '{s}' from user={s} (on cooldown from previous session reset: {d}/{d}s)", .{ trimmed, user_id, time_diff, cooldown_secs });
            return true; // Skip due to cooldown
        }
    }

    // Not a duplicate, update cache
    gop.value_ptr.* = .{ .content_hash = content_hash, .timestamp = now };
    return false; // Don't skip
}

fn telegramUpdateOffsetPath(allocator: std.mem.Allocator, config: *const Config, account_id: []const u8) ![]u8 {
    const config_dir = std.fs.path.dirname(config.config_path) orelse ".";
    const normalized_account_id = try normalizeTelegramAccountId(allocator, account_id);
    defer allocator.free(normalized_account_id);

    const file_name = try std.fmt.allocPrint(allocator, "update-offset-{s}.json", .{normalized_account_id});
    defer allocator.free(file_name);

    return std.fs.path.join(allocator, &.{ config_dir, "state", "telegram", file_name });
}

/// Load persisted Telegram update offset. Returns null when missing/invalid/stale.
pub fn loadTelegramUpdateOffset(
    allocator: std.mem.Allocator,
    config: *const Config,
    account_id: []const u8,
    bot_token: []const u8,
) ?i64 {
    const path = telegramUpdateOffsetPath(allocator, config, account_id) catch return null;
    defer allocator.free(path);

    const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return null;
    defer file.close(std.Options.debug_io);

    var read_buffer: [16 * 1024]u8 = undefined;
    var file_reader = file.reader(std.Options.debug_io, &read_buffer);
    const content = std.Io.Reader.allocRemaining(&file_reader.interface, allocator, .unlimited) catch return null;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    if (obj.get("version")) |version_val| {
        if (version_val != .integer or version_val.integer != TELEGRAM_OFFSET_STORE_VERSION) return null;
    }

    const last_update_id_val = obj.get("last_update_id") orelse return null;
    if (last_update_id_val != .integer) return null;

    const expected_bot_id = extractTelegramBotId(bot_token);
    if (expected_bot_id) |expected| {
        const stored_bot_id_val = obj.get("bot_id") orelse return null;
        if (stored_bot_id_val != .string) return null;
        if (!std.mem.eql(u8, stored_bot_id_val.string, expected)) return null;
    } else if (obj.get("bot_id")) |stored_bot_id_val| {
        if (stored_bot_id_val != .null and stored_bot_id_val != .string) return null;
    }

    return last_update_id_val.integer;
}

/// Persist Telegram update offset with bot identity (atomic write).
pub fn saveTelegramUpdateOffset(
    allocator: std.mem.Allocator,
    config: *const Config,
    account_id: []const u8,
    bot_token: []const u8,
    update_id: i64,
) !void {
    const path = try telegramUpdateOffsetPath(allocator, config, account_id);
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir),
        };
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    // Custom writer for ArrayList (Zig 0.16: ArrayList.writer() removed)
    const Writer = struct {
        buffer: *std.ArrayList(u8),
        alloc: std.mem.Allocator,

        fn write(self: @This(), bytes: []const u8) !usize {
            try self.buffer.appendSlice(self.alloc, bytes);
            return bytes.len;
        }

        fn writeAll(self: @This(), bytes: []const u8) !void {
            try self.buffer.appendSlice(self.alloc, bytes);
        }

        fn writeByte(self: @This(), byte: u8) !void {
            try self.buffer.append(self.alloc, byte);
        }

        fn print(self: @This(), comptime fmt: []const u8, args: anytype) !void {
            // Use bufPrint for formatted output
            var stack_buf: [256]u8 = undefined;
            if (std.fmt.bufPrint(&stack_buf, fmt, args)) |formatted| {
                try self.buffer.appendSlice(self.alloc, formatted);
            } else |_| {
                // Only NoSpaceLeft can fail for bufPrint
                // Fallback: allocPrint for larger output
                const alloc_fmt = try std.fmt.allocPrint(self.alloc, fmt, args);
                defer self.alloc.free(alloc_fmt);
                try self.buffer.appendSlice(self.alloc, alloc_fmt);
            }
        }
    };

    const writer = Writer{ .buffer = &buf, .alloc = allocator };
    const w = &writer;

    try buf.appendSlice(allocator, "{\n");
    try w.print("  \"version\": {d},\n", .{TELEGRAM_OFFSET_STORE_VERSION});
    try w.print("  \"last_update_id\": {d},\n", .{update_id});
    if (extractTelegramBotId(bot_token)) |bot_id| {
        try w.print("  \"bot_id\": \"{s}\"\n", .{bot_id});
    } else {
        try buf.appendSlice(allocator, "  \"bot_id\": null\n");
    }
    try buf.appendSlice(allocator, "}\n");

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    {
        var tmp_file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, tmp_path, .{});
        defer tmp_file.close(std.Options.debug_io);
        try tmp_file.writeStreamingAll(std.Options.debug_io, buf.items);
    }

    std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, std.Options.debug_io) catch {
        std.Io.Dir.cwd().deleteFile(std.Options.debug_io, tmp_path) catch {};
        const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{});
        defer file.close(std.Options.debug_io);
        try file.writeStreamingAll(std.Options.debug_io, buf.items);
    };
}

/// Persist candidate Telegram offset only when it advanced beyond the last
/// persisted value. On write failure, keeps watermark unchanged so the caller
/// retries on the next loop iteration.
pub fn persistTelegramUpdateOffsetIfAdvanced(
    allocator: std.mem.Allocator,
    config: *const Config,
    account_id: []const u8,
    bot_token: []const u8,
    persisted_update_id: *i64,
    candidate_update_id: i64,
) void {
    if (candidate_update_id <= persisted_update_id.*) return;
    saveTelegramUpdateOffset(allocator, config, account_id, bot_token, candidate_update_id) catch |err| {
        log.warn("failed to persist telegram update offset: {}", .{err});
        return;
    };
    persisted_update_id.* = candidate_update_id;
}

fn signalGroupPeerId(reply_target: ?[]const u8) []const u8 {
    const target = reply_target orelse "unknown";
    if (std.mem.startsWith(u8, target, signal.GROUP_TARGET_PREFIX)) {
        const raw = target[signal.GROUP_TARGET_PREFIX.len..];
        if (raw.len > 0) return raw;
    }
    return target;
}

fn matrixRoomPeerId(reply_target: ?[]const u8) []const u8 {
    return reply_target orelse "unknown";
}

// ════════════════════════════════════════════════════════════════════════════
// TelegramLoopState — shared state between supervisor and polling thread
// ════════════════════════════════════════════════════════════════════════════

/// Per-user message cache entry for deduplication
const MessageCacheEntry = struct {
    content_hash: u64,
    timestamp: i64,
};

pub const TelegramLoopState = struct {
    /// Updated after each pollUpdates() — epoch seconds.
    last_activity: Atomic(i64),
    /// Supervisor sets this to ask the polling thread to stop.
    stop_requested: Atomic(bool),
    /// Thread handle for join().
    thread: ?std.Thread = null,
    /// Worker pool for parallel message processing (optional, nil = sequential mode)
    worker_pool: ?*TelegramWorkerPool = null,
    /// Session locks for per-session serialization
    session_locks: ?*worker_pool_mod.SessionLockManager = null,
    /// Config for worker count (default: 4)
    worker_count: usize = 4,
    /// Per-user message cache for deduplication (prevents command spam)
    message_cache: std.StringHashMapUnmanaged(MessageCacheEntry) = .empty,
    /// Spinlock for message cache (lightweight, no I/O context needed)
    cache_spinlock: Spinlock = Spinlock.init(),

    pub fn init() TelegramLoopState {
        return .{
            .last_activity = Atomic(i64).init(util.timestampUnix()),
            .stop_requested = Atomic(bool).init(false),
            .worker_count = 4,
        };
    }

    pub fn initWithWorkers(worker_count: usize) TelegramLoopState {
        return .{
            .last_activity = Atomic(i64).init(util.timestampUnix()),
            .stop_requested = Atomic(bool).init(false),
            .worker_count = worker_count,
        };
    }

    pub fn deinit(self: *TelegramLoopState, allocator: std.mem.Allocator) void {
        self.cache_spinlock.lock();
        defer self.cache_spinlock.unlock();

        // Clean up message cache
        var iter = self.message_cache.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.message_cache.deinit(allocator);

        if (self.worker_pool) |pool| {
            pool.deinit();
            allocator.destroy(pool);
            self.worker_pool = null;
        }
        if (self.session_locks) |locks| {
            locks.deinit();
            allocator.destroy(locks);
            self.session_locks = null;
        }
    }
};

// Re-export centralized ProviderHolder from providers module.
pub const ProviderHolder = providers.ProviderHolder;

// ════════════════════════════════════════════════════════════════════════════
// ChannelRuntime — container for polling-thread dependencies
// ════════════════════════════════════════════════════════════════════════════

pub const ChannelRuntime = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    session_mgr: session_mod.SessionManager,
    provider_bundle: provider_runtime.RuntimeProviderBundle,
    tools: []const tools_mod.Tool,
    mem_rt: ?memory_mod.MemoryRuntime,
    noop_obs: *observability.NoopObserver,
    subagent_manager: ?*subagent_mod.SubagentManager,
    policy_tracker: *security.RateTracker,
    security_policy: *security.SecurityPolicy,

    /// Initialize the runtime from config — mirrors main.zig:702-786 setup.
    pub fn init(allocator: std.mem.Allocator, config: *const Config, io: std.Io) !*ChannelRuntime {
        var runtime_provider = try provider_runtime.RuntimeProviderBundle.init(allocator, config);
        errdefer runtime_provider.deinit();

        const provider_i = runtime_provider.provider();
        const resolved_key = runtime_provider.primaryApiKey();

        // MCP tools
        const mcp_tools: ?[]const tools_mod.Tool = if (config.mcp_servers.len > 0)
            mcp.initMcpTools(allocator, io, config.mcp_servers) catch |err| blk: {
                log.warn("MCP init failed: {}", .{err});
                break :blk null;
            }
        else
            null;
        defer if (mcp_tools) |mt| allocator.free(mt);

        const subagent_manager = allocator.create(subagent_mod.SubagentManager) catch null;
        errdefer if (subagent_manager) |mgr| allocator.destroy(mgr);
        if (subagent_manager) |mgr| {
            mgr.* = subagent_mod.SubagentManager.init(allocator, io, config, null, .{});
            errdefer {
                mgr.deinit();
            }
        }

        // Security policy (same behavior as direct channel loops in main.zig).
        const policy_tracker = try allocator.create(security.RateTracker);
        errdefer allocator.destroy(policy_tracker);
        policy_tracker.* = security.RateTracker.init(allocator, config.autonomy.max_actions_per_hour);
        errdefer policy_tracker.deinit();

        const security_policy = try allocator.create(security.SecurityPolicy);
        errdefer allocator.destroy(security_policy);
        security_policy.* = .{
            .autonomy = config.autonomy.level,
            .workspace_dir = config.workspace_dir,
            .workspace_only = config.autonomy.workspace_only,
            .allowed_commands = if (config.autonomy.allowed_commands.len > 0) config.autonomy.allowed_commands else &security.default_allowed_commands,
            .max_actions_per_hour = config.autonomy.max_actions_per_hour,
            .require_approval_for_medium_risk = config.autonomy.require_approval_for_medium_risk,
            .block_high_risk_commands = config.autonomy.block_high_risk_commands,
            .tracker = policy_tracker,
        };

        // Tools
        const tools = tools_mod.allTools(allocator, config.workspace_dir, io, .{
            .http_enabled = config.http_request.enabled,
            .http_allowed_domains = config.http_request.allowed_domains,
            .http_max_response_size = config.http_request.max_response_size,
            .http_timeout_secs = config.http_request.timeout_secs,
            .web_search_base_url = config.http_request.search_base_url,
            .web_search_provider = config.http_request.search_provider,
            .web_search_fallback_providers = config.http_request.search_fallback_providers,
            .browser_enabled = config.browser.enabled,
            .screenshot_enabled = false,
            .mcp_tools = mcp_tools,
            .agents = config.agents,
            .fallback_api_key = resolved_key,
            .tools_config = config.tools,
            .allowed_paths = config.autonomy.allowed_paths,
            .policy = security_policy,
            .subagent_manager = subagent_manager,
        }) catch &.{};
        errdefer if (tools.len > 0) tools_mod.deinitTools(allocator, tools);

        // Optional memory backend
        var mem_rt = memory_mod.initRuntime(allocator, &config.memory, config.workspace_dir);
        errdefer if (mem_rt) |*rt| rt.deinit();
        const mem_opt: ?memory_mod.Memory = if (mem_rt) |rt| rt.memory else null;

        // Noop observer (heap for vtable stability)
        const noop_obs = try allocator.create(observability.NoopObserver);
        errdefer allocator.destroy(noop_obs);
        noop_obs.* = .{};
        const obs = noop_obs.observer();

        // Session manager
        var session_mgr = session_mod.SessionManager.init(allocator, io, config, provider_i, tools, mem_opt, obs, if (mem_rt) |rt| rt.session_store else null, if (mem_rt) |*rt| rt.response_cache else null);
        session_mgr.policy = security_policy;

        // Self — heap-allocated so pointers remain stable
        const self = try allocator.create(ChannelRuntime);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .session_mgr = session_mgr,
            .provider_bundle = runtime_provider,
            .tools = tools,
            .mem_rt = mem_rt,
            .noop_obs = noop_obs,
            .subagent_manager = subagent_manager,
            .policy_tracker = policy_tracker,
            .security_policy = security_policy,
        };
        // Wire MemoryRuntime pointer into SessionManager for /doctor diagnostics
        // and into memory tools for retrieval pipeline + vector sync.
        // self is heap-allocated so the pointer is stable.
        if (self.mem_rt) |*rt| {
            self.session_mgr.mem_rt = rt;
            tools_mod.bindMemoryRuntime(tools, rt);
        }
        return self;
    }

    pub fn deinit(self: *ChannelRuntime) void {
        const alloc = self.allocator;
        self.session_mgr.deinit();
        if (self.tools.len > 0) tools_mod.deinitTools(alloc, self.tools);
        if (self.subagent_manager) |mgr| {
            mgr.deinit();
            alloc.destroy(mgr);
        }
        if (self.mem_rt) |*rt| rt.deinit();
        self.provider_bundle.deinit();
        self.policy_tracker.deinit();
        alloc.destroy(self.security_policy);
        alloc.destroy(self.policy_tracker);
        alloc.destroy(self.noop_obs);
        alloc.destroy(self);
    }
};

// ════════════════════════════════════════════════════════════════════════════
// runTelegramLoop — polling thread function
// ════════════════════════════════════════════════════════════════════════════

/// Thread-entry function for the Telegram polling loop.
/// Mirrors main.zig:793-866 but checks `loop_state.stop_requested` and
/// `daemon.isShutdownRequested()` for graceful shutdown.
///
/// `tg_ptr` is the channel instance owned by the supervisor (ChannelManager).
/// The polling loop uses it directly instead of creating a second
/// TelegramChannel, so health checks and polling operate on the same object.
///
/// Uses worker pool for parallel message processing:
///   - Poll thread: enqueue messages (non-blocking)
///   - Worker threads: process messages (parallel, per-session locking)
pub fn runTelegramLoop(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    loop_state: *TelegramLoopState,
    tg_ptr: *telegram.TelegramChannel,
) void {
    // Set up transcription — key comes from providers.{audio_media.provider}
    const trans = config.audio_media;
    if (config.getProviderKey(trans.provider)) |key| {
        const wt = allocator.create(voice.WhisperTranscriber) catch {
            log.warn("Failed to allocate WhisperTranscriber", .{});
            return;
        };
        wt.* = .{
            .endpoint = voice.resolveTranscriptionEndpoint(trans.provider, trans.base_url),
            .api_key = key,
            .model = trans.model,
            .language = trans.language,
        };
        tg_ptr.transcriber = wt.transcriber();
    }
    defer if (tg_ptr.transcriber) |t| {
        allocator.destroy(@as(*voice.WhisperTranscriber, @ptrCast(@alignCast(t.ptr))));
        tg_ptr.transcriber = null;
    };

    // Restore persisted Telegram offset (OpenClaw parity).
    if (loadTelegramUpdateOffset(allocator, config, tg_ptr.account_id, tg_ptr.bot_token)) |saved_update_id| {
        tg_ptr.last_update_id = saved_update_id;
    }

    // Ensure polling mode is active without dropping queued updates.
    tg_ptr.deleteWebhookKeepPending();

    // Register bot commands
    tg_ptr.setMyCommands();
    var persisted_update_id: i64 = tg_ptr.last_update_id;

    var evict_counter: u32 = 0;

    const model = config.default_model orelse {
        log.err("No default model configured. Set agents.defaults.model.primary in ~/.nullclaw/config.json or run `nullclaw onboard`.", .{});
        return;
    };

    // Initialize worker pool if not already done
    if (loop_state.worker_pool == null) {
        // Create session lock manager only if serialization is enabled
        var locks_ptr: ?*worker_pool_mod.SessionLockManager = null;
        if (config.session.serialize_sessions) {
            locks_ptr = allocator.create(worker_pool_mod.SessionLockManager) catch |err| {
                log.warn("Failed to create session lock manager: {} - using sequential processing", .{err});
                runTelegramLoopSequential(allocator, config, runtime, loop_state, tg_ptr, model);
                return;
            };
            locks_ptr.?.* = worker_pool_mod.SessionLockManager.init(allocator);
        }

        // Create worker pool with handler
        const pool_ptr = allocator.create(TelegramWorkerPool) catch |err| {
            log.warn("Failed to create worker pool: {} - using sequential processing", .{err});
            if (locks_ptr) |l| allocator.destroy(l);
            runTelegramLoopSequential(allocator, config, runtime, loop_state, tg_ptr, model);
            return;
        };

        const handler = TelegramWorkerHandler{
            .tg_ptr = tg_ptr,
            .runtime = runtime,
            .config = config,
            .session_locks = locks_ptr,
            .allocator = allocator,
        };

        pool_ptr.* = TelegramWorkerPool.init(allocator, handler, loop_state.worker_count) catch |err| {
            log.warn("Failed to initialize worker pool: {} - using sequential processing", .{err});
            allocator.destroy(pool_ptr);
            if (locks_ptr) |l| allocator.destroy(l);
            runTelegramLoopSequential(allocator, config, runtime, loop_state, tg_ptr, model);
            return;
        };

        // Start worker threads (must be done after pool is at its final location)
        pool_ptr.start() catch |err| {
            log.warn("Failed to start worker pool: {} - using sequential processing", .{err});
            pool_ptr.deinit();
            allocator.destroy(pool_ptr);
            if (locks_ptr) |l| allocator.destroy(l);
            runTelegramLoopSequential(allocator, config, runtime, loop_state, tg_ptr, model);
            return;
        };

        loop_state.worker_pool = pool_ptr;
        loop_state.session_locks = locks_ptr;
        if (config.session.serialize_sessions) {
            log.info("Worker pool enabled with {} workers (session serialization ON)", .{loop_state.worker_count});
        } else {
            log.info("Worker pool enabled with {} workers (full parallelism)", .{loop_state.worker_count});
        }
    }

    // Update activity timestamp at start
    loop_state.last_activity.store(util.timestampUnix(), .release);

    while (!loop_state.stop_requested.load(.acquire) and !daemon.isShutdownRequested()) {
        const messages = tg_ptr.pollUpdates(allocator) catch |err| {
            log.warn("Telegram poll error: {}", .{err});
            loop_state.last_activity.store(util.timestampUnix(), .release);
            continue;
        };

        // Update activity after each poll (even if no messages)
        loop_state.last_activity.store(util.timestampUnix(), .release);

        for (messages) |msg| {
            // Handle /start command immediately (don't queue)
            const trimmed = std.mem.trim(u8, msg.content, " \t\r\n");
            if (std.mem.eql(u8, trimmed, "/start")) {
                var greeting_buf: [512]u8 = undefined;
                const name = msg.first_name orelse msg.id;
                const greeting = std.fmt.bufPrint(&greeting_buf, "Hello, {s}! I'm nullClaw.\n\nModel: {s}\nType /help for available commands.", .{ name, model }) catch "Hello! I'm nullClaw. Type /help for commands.";
                tg_ptr.sendMessageWithReply(msg.sender, greeting, msg.message_id) catch |err| log.err("failed to send /start reply: {}", .{err});
                msg.deinit(allocator);
                continue;
            }

            // Check for duplicate messages (prevent command spam)
            if (shouldSkipDuplicateMessage(loop_state, allocator, msg.sender, msg.content)) {
                log.debug("Skipping duplicate /reset command from user={s}", .{msg.sender});
                msg.deinit(allocator);
                continue;
            }

            // Classify message for hybrid processing
            const msg_class = classifyMessage(msg.content);

            // Clone message data for worker pool
            // Safety: validate source data first
            if (msg.sender.len == 0 or tg_ptr.account_id.len == 0) {
                log.warn("Skipping message with empty sender or account_id", .{});
                msg.deinit(allocator);
                continue;
            }
            
            const worker_msg = TelegramWorkerMessage{
                .sender = allocator.dupe(u8, msg.sender) catch {
                    log.warn("Failed to clone sender, skipping message", .{});
                    msg.deinit(allocator);
                    continue;
                },
                .sender_first_name = if (msg.first_name) |name| allocator.dupe(u8, name) catch null else null,
                .sender_id = allocator.dupe(u8, msg.id) catch {
                    log.warn("Failed to clone sender_id, skipping message", .{});
                    msg.deinit(allocator);
                    continue;
                },
                .content = allocator.dupe(u8, msg.content) catch {
                    log.warn("Failed to clone content, skipping message", .{});
                    msg.deinit(allocator);
                    continue;
                },
                .is_group = msg.is_group,
                .message_id = msg.message_id,
                .account_id = allocator.dupe(u8, tg_ptr.account_id) catch {
                    log.warn("Failed to clone account_id, skipping message", .{});
                    msg.deinit(allocator);
                    continue;
                },
                .message_class = msg_class,
            };

            // Final validation: ensure cloned fields are valid
            if (worker_msg.sender.len == 0 or worker_msg.account_id.len == 0) {
                log.warn("Skipping message with empty cloned fields (sender={d}, account_id={d})", .{ worker_msg.sender.len, worker_msg.account_id.len });
                worker_msg.deinit(allocator);
                msg.deinit(allocator);
                continue;
            }

            // Log classification (debug)
            if (msg_class == .independent) {
                log.debug("Message classified as independent: {s}", .{msg.content[0..@min(msg.content.len, 50)]});
            }

            // Enqueue for worker pool processing
            if (loop_state.worker_pool) |pool| {
                pool.submit(worker_msg) catch |err| {
                    log.err("Failed to enqueue message: {}", .{err});
                    worker_msg.deinit(allocator);
                };
            }

            // Free original message (worker owns the clones)
            msg.deinit(allocator);
        }

        if (messages.len > 0) {
            allocator.free(messages);
        }

        if (tg_ptr.persistableUpdateOffset()) |persistable_update_id| {
            persistTelegramUpdateOffsetIfAdvanced(
                allocator,
                config,
                tg_ptr.account_id,
                tg_ptr.bot_token,
                &persisted_update_id,
                persistable_update_id,
            );
        }

        // Periodic session eviction
        evict_counter += 1;
        if (evict_counter >= 100) {
            evict_counter = 0;
            _ = runtime.session_mgr.evictIdle(config.agent.session_idle_timeout_secs, std.Options.debug_io);
        }

        health.markComponentOk("telegram");
    }
}

/// Sequential processing fallback (original behavior)
fn runTelegramLoopSequential(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    loop_state: *TelegramLoopState,
    tg_ptr: *telegram.TelegramChannel,
    model: []const u8,
) void {
    var persisted_update_id: i64 = tg_ptr.last_update_id;
    var evict_counter: u32 = 0;

    // Update activity timestamp at start
    loop_state.last_activity.store(util.timestampUnix(), .release);

    while (!loop_state.stop_requested.load(.acquire) and !daemon.isShutdownRequested()) {
        const messages = tg_ptr.pollUpdates(allocator) catch |err| {
            log.warn("Telegram poll error: {}", .{err});
            loop_state.last_activity.store(util.timestampUnix(), .release);
            continue;
        };

        // Update activity after each poll (even if no messages)
        loop_state.last_activity.store(util.timestampUnix(), .release);

        for (messages) |msg| {
            // Handle /start command
            const trimmed = std.mem.trim(u8, msg.content, " \t\r\n");
            if (std.mem.eql(u8, trimmed, "/start")) {
                var greeting_buf: [512]u8 = undefined;
                const name = msg.first_name orelse msg.id;
                const greeting = std.fmt.bufPrint(&greeting_buf, "Hello, {s}! I'm nullClaw.\n\nModel: {s}\nType /help for available commands.", .{ name, model }) catch "Hello! I'm nullClaw. Type /help for commands.";
                tg_ptr.sendMessageWithReply(msg.sender, greeting, msg.message_id) catch |err| log.err("failed to send /start reply: {}", .{err});
                continue;
            }

            // Check for duplicate messages (prevent command spam)
            if (shouldSkipDuplicateMessage(loop_state, allocator, msg.sender, msg.content)) {
                log.debug("Skipping duplicate /reset command from user={s}", .{msg.sender});
                continue;
            }

            // Reply-to logic
            const use_reply_to = msg.is_group or tg_ptr.reply_in_private;
            const reply_to_id: ?i64 = if (use_reply_to) msg.message_id else null;

            // Session key — always resolve through agent routing (falls back on errors)
            var key_buf: [128]u8 = undefined;
            var routed_session_key: ?[]const u8 = null;
            defer if (routed_session_key) |key| allocator.free(key);
            const session_key = blk: {
                const route = agent_routing.resolveRouteWithSession(allocator, .{
                    .channel = "telegram",
                    .account_id = tg_ptr.account_id,
                    .peer = .{ .kind = if (msg.is_group) .group else .direct, .id = msg.sender },
                }, config.agent_bindings, config.agents, config.session) catch break :blk std.fmt.bufPrint(&key_buf, "telegram:{s}:{s}", .{ tg_ptr.account_id, msg.sender }) catch msg.sender;
                allocator.free(route.main_session_key);
                routed_session_key = route.session_key;
                break :blk route.session_key;
            };

            const typing_target = msg.sender;
            tg_ptr.startTyping(typing_target) catch {};
            defer tg_ptr.stopTyping(typing_target) catch {};

            const reply = runtime.session_mgr.processMessage(session_key, msg.content, null) catch |err| {
                log.err("Agent error: {}", .{err});
                const err_msg: []const u8 = switch (err) {
                    error.CurlFailed, error.CurlReadError, error.CurlWaitError, error.CurlWriteError => "Network error. Please try again.",
                    error.ProviderDoesNotSupportVision => "The current provider does not support image input. Switch to a vision-capable provider or remove [IMAGE:] attachments.",
                    error.NoResponseContent => "Model returned an empty response. Please retry or /new for a fresh session.",
                    error.AllProvidersFailed => "All configured providers failed for this request. Check model/provider compatibility and credentials.",
                    error.OutOfMemory => "Out of memory.",
                    else => "An error occurred. Try again or /new for a fresh session.",
                };
                tg_ptr.sendMessageWithReply(msg.sender, err_msg, reply_to_id) catch |send_err| log.err("failed to send error reply: {}", .{send_err});
                continue;
            };
            defer allocator.free(reply);

            tg_ptr.sendAssistantMessageWithReply(msg.sender, msg.id, msg.is_group, reply, reply_to_id) catch |err| {
                log.warn("Send error: {}", .{err});
            };
        }

        if (messages.len > 0) {
            for (messages) |msg| {
                msg.deinit(allocator);
            }
            allocator.free(messages);
        }

        if (tg_ptr.persistableUpdateOffset()) |persistable_update_id| {
            persistTelegramUpdateOffsetIfAdvanced(allocator, config, tg_ptr.account_id, tg_ptr.bot_token, &persisted_update_id, persistable_update_id);
        }

        // Periodic session eviction
        evict_counter += 1;
        if (evict_counter >= 100) {
            evict_counter = 0;
            _ = runtime.session_mgr.evictIdle(config.agent.session_idle_timeout_secs, std.Options.debug_io);
        }

        health.markComponentOk("telegram");
    }
}

// ════════════════════════════════════════════════════════════════════════════
// SignalLoopState — shared state between supervisor and polling thread
// ════════════════════════════════════════════════════════════════════════════

pub const SignalLoopState = struct {
    /// Updated after each pollMessages() — epoch seconds.
    last_activity: Atomic(i64),
    /// Supervisor sets this to ask the polling thread to stop.
    stop_requested: Atomic(bool),
    /// Thread handle for join().
    thread: ?std.Thread = null,

    pub fn init() SignalLoopState {
        return .{
            .last_activity = Atomic(i64).init(util.timestampUnix()),
            .stop_requested = Atomic(bool).init(false),
        };
    }
};

// ════════════════════════════════════════════════════════════════════════════
// runSignalLoop — polling thread function
// ════════════════════════════════════════════════════════════════════════════

/// Thread-entry function for the Signal SSE polling loop.
/// Mirrors runTelegramLoop but uses signal-cli's SSE/JSON-RPC API.
/// Checks `loop_state.stop_requested` and `daemon.isShutdownRequested()`
/// for graceful shutdown.
pub fn runSignalLoop(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    loop_state: *SignalLoopState,
    sg_ptr: *signal.SignalChannel,
) void {
    // Update activity timestamp at start
    loop_state.last_activity.store(util.timestampUnix(), .release);

    var evict_counter: u32 = 0;

    while (!loop_state.stop_requested.load(.acquire) and !daemon.isShutdownRequested()) {
        const messages = sg_ptr.pollMessages(allocator) catch |err| {
            log.warn("Signal poll error: {}", .{err});
            loop_state.last_activity.store(util.timestampUnix(), .release);
            continue;
        };

        // Update activity after each poll (even if no messages)
        loop_state.last_activity.store(util.timestampUnix(), .release);

        for (messages) |msg| {
            // Session key — always resolve through agent routing (falls back on errors)
            var key_buf: [128]u8 = undefined;
            const group_peer_id = signalGroupPeerId(msg.reply_target);
            var routed_session_key: ?[]const u8 = null;
            defer if (routed_session_key) |key| allocator.free(key);
            const session_key = blk: {
                const route = agent_routing.resolveRouteWithSession(allocator, .{
                    .channel = "signal",
                    .account_id = sg_ptr.account_id,
                    .peer = .{
                        .kind = if (msg.is_group) .group else .direct,
                        .id = if (msg.is_group) group_peer_id else msg.sender,
                    },
                }, config.agent_bindings, config.agents, config.session) catch break :blk if (msg.is_group)
                    std.fmt.bufPrint(&key_buf, "signal:{s}:group:{s}:{s}", .{
                        sg_ptr.account_id,
                        group_peer_id,
                        msg.sender,
                    }) catch msg.sender
                else
                    std.fmt.bufPrint(&key_buf, "signal:{s}:{s}", .{ sg_ptr.account_id, msg.sender }) catch msg.sender;
                allocator.free(route.main_session_key);
                routed_session_key = route.session_key;
                break :blk route.session_key;
            };

            const typing_target = msg.reply_target;
            if (typing_target) |target| sg_ptr.startTyping(target) catch {};
            defer if (typing_target) |target| sg_ptr.stopTyping(target) catch {};

            // Build conversation context for Signal
            const conversation_context: ?ConversationContext = .{
                .channel = "signal",
                .sender_number = if (msg.sender.len > 0 and msg.sender[0] == '+') msg.sender else null,
                .sender_uuid = msg.sender_uuid,
                .group_id = msg.group_id,
                .is_group = msg.is_group,
            };

            const reply = runtime.session_mgr.processMessage(session_key, msg.content, conversation_context) catch |err| {
                log.err("Signal agent error: {}", .{err});
                const err_msg: []const u8 = switch (err) {
                    error.CurlFailed, error.CurlReadError, error.CurlWaitError, error.CurlWriteError => "Network error. Please try again.",
                    error.ProviderDoesNotSupportVision => "The current provider does not support image input.",
                    error.NoResponseContent => "Model returned an empty response. Please try again.",
                    error.AllProvidersFailed => "All configured providers failed for this request. Check model/provider compatibility and credentials.",
                    error.OutOfMemory => "Out of memory.",
                    else => "An error occurred. Try again.",
                };
                if (msg.reply_target) |target| {
                    sg_ptr.sendMessage(target, err_msg, &.{}) catch |send_err| log.err("failed to send signal error reply: {}", .{send_err});
                }
                continue;
            };
            defer allocator.free(reply);

            // Reply on Signal
            if (msg.reply_target) |target| {
                sg_ptr.sendMessage(target, reply, &.{}) catch |err| {
                    log.warn("Signal send error: {}", .{err});
                };
            }
        }

        if (messages.len > 0) {
            for (messages) |msg| {
                msg.deinit(allocator);
            }
            allocator.free(messages);
        }

        // Periodic session eviction
        evict_counter += 1;
        if (evict_counter >= 100) {
            evict_counter = 0;
            _ = runtime.session_mgr.evictIdle(config.agent.session_idle_timeout_secs, std.Options.debug_io);
        }

        health.markComponentOk("signal");
    }
}

// ════════════════════════════════════════════════════════════════════════════
// MatrixLoopState — shared state between supervisor and polling thread
// ════════════════════════════════════════════════════════════════════════════

pub const MatrixLoopState = struct {
    /// Updated after each pollMessages() — epoch seconds.
    last_activity: Atomic(i64),
    /// Supervisor sets this to ask the polling thread to stop.
    stop_requested: Atomic(bool),
    /// Thread handle for join().
    thread: ?std.Thread = null,

    pub fn init() MatrixLoopState {
        return .{
            .last_activity = Atomic(i64).init(util.timestampUnix()),
            .stop_requested = Atomic(bool).init(false),
        };
    }
};

pub const PollingState = union(enum) {
    telegram: *TelegramLoopState,
    signal: *SignalLoopState,
    matrix: *MatrixLoopState,
};

pub const PollingSpawnResult = struct {
    thread: std.Thread,
    state: PollingState,
};

pub fn spawnTelegramPolling(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    channel: channels_mod.Channel,
) !PollingSpawnResult {
    const tg_ls = try allocator.create(TelegramLoopState);
    errdefer allocator.destroy(tg_ls);
    tg_ls.* = TelegramLoopState.init();

    const tg_ptr: *telegram.TelegramChannel = @ptrCast(@alignCast(channel.ptr));
    const thread = try std.Thread.spawn(
        .{ .stack_size = 2 * 1024 * 1024 },
        runTelegramLoop,
        .{ allocator, config, runtime, tg_ls, tg_ptr },
    );
    tg_ls.thread = thread;

    return .{
        .thread = thread,
        .state = .{ .telegram = tg_ls },
    };
}

pub fn spawnSignalPolling(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    channel: channels_mod.Channel,
) !PollingSpawnResult {
    const sg_ls = try allocator.create(SignalLoopState);
    errdefer allocator.destroy(sg_ls);
    sg_ls.* = SignalLoopState.init();

    const sg_ptr: *signal.SignalChannel = @ptrCast(@alignCast(channel.ptr));
    const thread = try std.Thread.spawn(
        .{ .stack_size = 2 * 1024 * 1024 },
        runSignalLoop,
        .{ allocator, config, runtime, sg_ls, sg_ptr },
    );
    sg_ls.thread = thread;

    return .{
        .thread = thread,
        .state = .{ .signal = sg_ls },
    };
}

pub fn spawnMatrixPolling(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    channel: channels_mod.Channel,
) !PollingSpawnResult {
    const mx_ls = try allocator.create(MatrixLoopState);
    errdefer allocator.destroy(mx_ls);
    mx_ls.* = MatrixLoopState.init();

    const mx_ptr: *matrix.MatrixChannel = @ptrCast(@alignCast(channel.ptr));
    const thread = try std.Thread.spawn(
        .{ .stack_size = 2 * 1024 * 1024 },
        runMatrixLoop,
        .{ allocator, config, runtime, mx_ls, mx_ptr },
    );
    mx_ls.thread = thread;

    return .{
        .thread = thread,
        .state = .{ .matrix = mx_ls },
    };
}

// ════════════════════════════════════════════════════════════════════════════
// runMatrixLoop — polling thread function
// ════════════════════════════════════════════════════════════════════════════

/// Thread-entry function for Matrix /sync polling.
/// Uses account-aware route resolution and per-room reply targets.
pub fn runMatrixLoop(
    allocator: std.mem.Allocator,
    config: *const Config,
    runtime: *ChannelRuntime,
    loop_state: *MatrixLoopState,
    mx_ptr: *matrix.MatrixChannel,
) void {
    loop_state.last_activity.store(util.timestampUnix(), .release);

    var evict_counter: u32 = 0;

    while (!loop_state.stop_requested.load(.acquire) and !daemon.isShutdownRequested()) {
        const messages = mx_ptr.pollMessages(allocator) catch |err| {
            log.warn("Matrix poll error: {}", .{err});
            loop_state.last_activity.store(util.timestampUnix(), .release);
            continue;
        };

        loop_state.last_activity.store(util.timestampUnix(), .release);

        for (messages) |msg| {
            var key_buf: [192]u8 = undefined;
            const room_peer_id = matrixRoomPeerId(msg.reply_target);
            var routed_session_key: ?[]const u8 = null;
            defer if (routed_session_key) |key| allocator.free(key);

            const session_key = blk: {
                const route = agent_routing.resolveRouteWithSession(allocator, .{
                    .channel = "matrix",
                    .account_id = mx_ptr.account_id,
                    .peer = .{
                        .kind = if (msg.is_group) .group else .direct,
                        .id = if (msg.is_group) room_peer_id else msg.sender,
                    },
                }, config.agent_bindings, config.agents, config.session) catch break :blk if (msg.is_group)
                    std.fmt.bufPrint(&key_buf, "matrix:{s}:room:{s}", .{ mx_ptr.account_id, room_peer_id }) catch msg.sender
                else
                    std.fmt.bufPrint(&key_buf, "matrix:{s}:{s}", .{ mx_ptr.account_id, msg.sender }) catch msg.sender;

                allocator.free(route.main_session_key);
                routed_session_key = route.session_key;
                break :blk route.session_key;
            };

            const typing_target = msg.reply_target orelse msg.sender;
            mx_ptr.startTyping(typing_target) catch {};
            defer mx_ptr.stopTyping(typing_target) catch {};

            const reply = runtime.session_mgr.processMessage(session_key, msg.content, null) catch |err| {
                log.err("Matrix agent error: {}", .{err});
                const err_msg: []const u8 = switch (err) {
                    error.CurlFailed, error.CurlReadError, error.CurlWaitError, error.CurlWriteError => "Network error. Please try again.",
                    error.ProviderDoesNotSupportVision => "The current provider does not support image input.",
                    error.NoResponseContent => "Model returned an empty response. Please try again.",
                    error.AllProvidersFailed => "All configured providers failed for this request. Check model/provider compatibility and credentials.",
                    error.OutOfMemory => "Out of memory.",
                    else => "An error occurred. Try again.",
                };
                mx_ptr.sendMessage(typing_target, err_msg) catch |send_err| log.err("failed to send matrix error reply: {}", .{send_err});
                continue;
            };
            defer allocator.free(reply);

            mx_ptr.sendMessage(typing_target, reply) catch |err| {
                log.warn("Matrix send error: {}", .{err});
            };
        }

        if (messages.len > 0) {
            for (messages) |msg| {
                msg.deinit(allocator);
            }
            allocator.free(messages);
        }

        evict_counter += 1;
        if (evict_counter >= 100) {
            evict_counter = 0;
            _ = runtime.session_mgr.evictIdle(config.agent.session_idle_timeout_secs, std.Options.debug_io);
        }

        health.markComponentOk("matrix");
    }
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "TelegramLoopState init defaults" {
    const state = TelegramLoopState.init();
    try std.testing.expect(!state.stop_requested.load(.acquire));
    try std.testing.expect(state.thread == null);
    try std.testing.expect(state.last_activity.load(.acquire) > 0);
}

test "TelegramLoopState stop_requested toggle" {
    var state = TelegramLoopState.init();
    try std.testing.expect(!state.stop_requested.load(.acquire));
    state.stop_requested.store(true, .release);
    try std.testing.expect(state.stop_requested.load(.acquire));
}

test "TelegramLoopState last_activity update" {
    var state = TelegramLoopState.init();
    const before = state.last_activity.load(.acquire);
    state.last_activity.store(util.timestampUnix(), .release);
    const after = state.last_activity.load(.acquire);
    try std.testing.expect(after >= before);
}

test "ProviderHolder tagged union fields" {
    // Compile-time check that ProviderHolder has expected variants
    try std.testing.expect(@hasField(ProviderHolder, "openrouter"));
    try std.testing.expect(@hasField(ProviderHolder, "anthropic"));
    try std.testing.expect(@hasField(ProviderHolder, "openai"));
    try std.testing.expect(@hasField(ProviderHolder, "gemini"));
    try std.testing.expect(@hasField(ProviderHolder, "ollama"));
    try std.testing.expect(@hasField(ProviderHolder, "compatible"));
    try std.testing.expect(@hasField(ProviderHolder, "openai_codex"));
}

test "channel runtime wires security policy into session manager and shell tool" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try std.testing.allocator.dupe(u8, ".");
    defer allocator.free(workspace);
    const config_path = try std.fs.path.join(allocator, &.{ workspace, "config.json" });
    defer allocator.free(config_path);

    var allowed_paths = [_][]const u8{workspace};
    const cfg = Config{
        .workspace_dir = workspace,
        .config_path = config_path,
        .allocator = allocator,
        .autonomy = .{
            .allowed_paths = &allowed_paths,
        },
    };

    var runtime = try ChannelRuntime.init(allocator, &cfg, std.testing.io);
    defer runtime.deinit();

    try std.testing.expect(runtime.session_mgr.policy != null);
    try std.testing.expect(runtime.session_mgr.policy.? == runtime.security_policy);

    var found_shell = false;
    for (runtime.tools) |tool| {
        if (!std.mem.eql(u8, tool.name(), "shell")) continue;
        found_shell = true;

        const shell_tool: *tools_mod.shell.ShellTool = @ptrCast(@alignCast(tool.ptr));
        try std.testing.expect(shell_tool.policy != null);
        try std.testing.expect(shell_tool.policy.? == runtime.security_policy);
        try std.testing.expectEqual(@as(usize, 1), shell_tool.allowed_paths.len);
        try std.testing.expectEqualStrings(workspace, shell_tool.allowed_paths[0]);
        break;
    }
    try std.testing.expect(found_shell);
}

test "SignalLoopState init defaults" {
    const state = SignalLoopState.init();
    try std.testing.expect(!state.stop_requested.load(.acquire));
    try std.testing.expect(state.thread == null);
    try std.testing.expect(state.last_activity.load(.acquire) > 0);
}

test "SignalLoopState stop_requested toggle" {
    var state = SignalLoopState.init();
    try std.testing.expect(!state.stop_requested.load(.acquire));
    state.stop_requested.store(true, .release);
    try std.testing.expect(state.stop_requested.load(.acquire));
}

test "SignalLoopState last_activity update" {
    var state = SignalLoopState.init();
    const before = state.last_activity.load(.acquire);
    state.last_activity.store(util.timestampUnix(), .release);
    const after = state.last_activity.load(.acquire);
    try std.testing.expect(after >= before);
}

test "MatrixLoopState init defaults" {
    const state = MatrixLoopState.init();
    try std.testing.expect(!state.stop_requested.load(.acquire));
    try std.testing.expect(state.thread == null);
    try std.testing.expect(state.last_activity.load(.acquire) > 0);
}

test "MatrixLoopState stop_requested toggle" {
    var state = MatrixLoopState.init();
    try std.testing.expect(!state.stop_requested.load(.acquire));
    state.stop_requested.store(true, .release);
    try std.testing.expect(state.stop_requested.load(.acquire));
}

test "MatrixLoopState last_activity update" {
    var state = MatrixLoopState.init();
    const before = state.last_activity.load(.acquire);
    state.last_activity.store(util.timestampUnix(), .release);
    const after = state.last_activity.load(.acquire);
    try std.testing.expect(after >= before);
}

test "signalGroupPeerId extracts group id from reply target" {
    const peer_id = signalGroupPeerId("group:1203630@g.us");
    try std.testing.expectEqualStrings("1203630@g.us", peer_id);
}

test "signalGroupPeerId falls back when reply target is missing or malformed" {
    try std.testing.expectEqualStrings("unknown", signalGroupPeerId(null));
    try std.testing.expectEqualStrings("group:", signalGroupPeerId("group:"));
    try std.testing.expectEqualStrings("direct:+15550001111", signalGroupPeerId("direct:+15550001111"));
}

test "matrixRoomPeerId falls back when reply target is missing" {
    try std.testing.expectEqualStrings("unknown", matrixRoomPeerId(null));
    try std.testing.expectEqualStrings("!room:example", matrixRoomPeerId("!room:example"));
}

test "telegram update offset store roundtrip" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try std.testing.allocator.dupe(u8, ".");
    defer allocator.free(base);
    const config_path = try std.fs.path.join(allocator, &.{ base.ptr[0..base.len], "config.json" });
    defer allocator.free(config_path);

    const cfg = Config{
        .workspace_dir = base,
        .config_path = config_path,
        .allocator = allocator,
    };

    try saveTelegramUpdateOffset(allocator, &cfg, "main", "12345:test-token", 777);
    const restored = loadTelegramUpdateOffset(allocator, &cfg, "main", "12345:test-token");
    try std.testing.expectEqual(@as(?i64, 777), restored);
}

test "telegram update offset store returns null for mismatched bot id" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try std.testing.allocator.dupe(u8, ".");
    defer allocator.free(base);
    const config_path = try std.fs.path.join(allocator, &.{ base.ptr[0..base.len], "config.json" });
    defer allocator.free(config_path);

    const cfg = Config{
        .workspace_dir = base,
        .config_path = config_path,
        .allocator = allocator,
    };

    try saveTelegramUpdateOffset(allocator, &cfg, "main", "11111:test-token-a", 123);
    const restored = loadTelegramUpdateOffset(allocator, &cfg, "main", "22222:test-token-b");
    try std.testing.expect(restored == null);
}

test "telegram update offset store treats legacy payload without bot_id as stale" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try std.testing.allocator.dupe(u8, ".");
    defer allocator.free(base);
    const config_path = try std.fs.path.join(allocator, &.{ base.ptr[0..base.len], "config.json" });
    defer allocator.free(config_path);

    const cfg = Config{
        .workspace_dir = base,
        .config_path = config_path,
        .allocator = allocator,
    };

    const offset_path = try telegramUpdateOffsetPath(allocator, &cfg, "default");
    defer allocator.free(offset_path);
    const offset_dir = std.fs.path.dirname(offset_path).?;
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, offset_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, offset_dir),
    };
    const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, offset_path, .{});
    defer file.close(std.Options.debug_io);
    try file.writeStreamingAll(std.Options.debug_io,
        \\{
        \\  "version": 1,
        \\  "last_update_id": 456
        \\}
        \\
    );

    const restored = loadTelegramUpdateOffset(allocator, &cfg, "default", "33333:test-token-c");
    try std.testing.expect(restored == null);
}

test "telegram offset persistence helper retries after write failure" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try std.testing.allocator.dupe(u8, ".");
    defer allocator.free(base);
    const config_path = try std.fs.path.join(allocator, &.{ base.ptr[0..base.len], "config.json" });
    defer allocator.free(config_path);

    const cfg = Config{
        .workspace_dir = base,
        .config_path = config_path,
        .allocator = allocator,
    };

    const blocked_state_path = try std.fs.path.join(allocator, &.{ base.ptr[0..base.len], "state" });
    defer allocator.free(blocked_state_path);

    {
        const blocked_state_file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, blocked_state_path, .{});
        blocked_state_file.close(std.Options.debug_io);
    }

    var persisted_update_id: i64 = 100;
    persistTelegramUpdateOffsetIfAdvanced(
        allocator,
        &cfg,
        "main",
        "12345:test-token",
        &persisted_update_id,
        101,
    );
    try std.testing.expectEqual(@as(i64, 100), persisted_update_id);
    try std.testing.expect(loadTelegramUpdateOffset(allocator, &cfg, "main", "12345:test-token") == null);

    try std.Io.Dir.cwd().deleteFile(std.Options.debug_io, blocked_state_path);

    persistTelegramUpdateOffsetIfAdvanced(
        allocator,
        &cfg,
        "main",
        "12345:test-token",
        &persisted_update_id,
        101,
    );
    try std.testing.expectEqual(@as(i64, 101), persisted_update_id);
    const restored = loadTelegramUpdateOffset(allocator, &cfg, "main", "12345:test-token");
    try std.testing.expectEqual(@as(?i64, 101), restored);
}

// ════════════════════════════════════════════════════════════════════════════
// Message Classification Tests
// ════════════════════════════════════════════════════════════════════════════

test "classifyMessage: commands are independent" {
    try std.testing.expectEqual(MessageClass.independent, classifyMessage("/start"));
    try std.testing.expectEqual(MessageClass.independent, classifyMessage("/status"));
    try std.testing.expectEqual(MessageClass.independent, classifyMessage("/help"));
}

test "classifyMessage: price queries are independent" {
    try std.testing.expectEqual(MessageClass.independent, classifyMessage("What's BTC price?"));
    try std.testing.expectEqual(MessageClass.independent, classifyMessage("BTC?"));
    try std.testing.expectEqual(MessageClass.independent, classifyMessage("How much is $100 in EUR?"));
}

test "classifyMessage: follow-ups are conversational" {
    try std.testing.expectEqual(MessageClass.conversational, classifyMessage("And tomorrow?"));
    try std.testing.expectEqual(MessageClass.conversational, classifyMessage("What about that?"));
    try std.testing.expectEqual(MessageClass.conversational, classifyMessage("Continue"));
    try std.testing.expectEqual(MessageClass.conversational, classifyMessage("Go on"));
}

test "classifyMessage: pronoun references are conversational" {
    try std.testing.expectEqual(MessageClass.conversational, classifyMessage("What is it?"));
    try std.testing.expectEqual(MessageClass.conversational, classifyMessage("Who is he?"));
    try std.testing.expectEqual(MessageClass.conversational, classifyMessage("Explain that"));
}

test "classifyMessage: short messages are conversational" {
    try std.testing.expectEqual(MessageClass.conversational, classifyMessage("Ok"));
    try std.testing.expectEqual(MessageClass.conversational, classifyMessage("Yes"));
    try std.testing.expectEqual(MessageClass.conversational, classifyMessage("No"));
}

test "classifyMessage: mixed patterns" {
    // Has "and" at start → conversational
    try std.testing.expectEqual(MessageClass.conversational, classifyMessage("And BTC price?"));

    // Short question with currency → independent
    try std.testing.expectEqual(MessageClass.independent, classifyMessage("Price?"));

    // Normal question → independent
    try std.testing.expectEqual(MessageClass.independent, classifyMessage("What is Bitcoin?"));
}
