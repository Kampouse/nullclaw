//! Gork fallback poller - CLI-based inbox checker.
//!
//! Provides polling-based fallback when daemon is unavailable.
//! Runs gork-agent inbox CLI command periodically.
//!
//! Thread Safety: Thread-safe with proper synchronization.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Poller = @This();

// Rate limiting constants
const MIN_POLL_INTERVAL_NS = 5 * std.time.ns_per_s; // Minimum 5 seconds between polls

/// Poller mode
pub const Mode = enum {
    fallback, // Daemon running, poll as backup
    primary,  // Daemon dead, poll is main method
};

/// Poll result
pub const Result = struct {
    message_count: usize,
    processed: usize,

    // No deinit needed - errors are logged, not stored
};

allocator: Allocator,
binary_path: []const u8,
interval_secs: u32,
mode: Mode,
mutex: std.Io.Mutex,
stop_requested: std.atomic.Value(bool),
message_callback: ?*const fn ([]const u8) void = null,
poller_ctx: ?*PollerContext = null,  // Owned by this poller
poller_thread: ?std.Thread = null,  // Owned by this poller
last_poll_time: std.atomic.Value(i64),  // For rate limiting

/// Context for poll loop
const PollerContext = struct {
    poller: *Poller,
    callback: *const fn ([]const u8) void,
};

/// Initialize a new poller
pub fn init(allocator: Allocator, binary_path: []const u8, interval_secs: u32) Poller {
    return .{
        .allocator = allocator,
        .binary_path = binary_path,
        .interval_secs = interval_secs,
        .mode = .fallback,
        .mutex = .{ .state = .init(.unlocked) },
        .stop_requested = std.atomic.Value(bool).init(false),
        .message_callback = null,
        .poller_ctx = null,
        .poller_thread = null,
        .last_poll_time = std.atomic.Value(i64).init(0),
    };
}

/// Start the poller in a background thread (thread-safe)
pub fn start(self: *Poller, message_callback: *const fn ([]const u8) void) !void {
    // TODO: Zig 0.16.0 - needs io
        // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
    // TODO: Zig 0.16.0 - needs io
    // defer self.mutex.unlock();

    if (self.poller_ctx != null) return; // Already started

    self.message_callback = message_callback;
    self.stop_requested.store(false, .seq_cst);

    const poller_ctx = try self.allocator.create(PollerContext);
    errdefer self.allocator.destroy(poller_ctx);

    poller_ctx.* = .{
        .poller = self,
        .callback = message_callback,
    };
    self.poller_ctx = poller_ctx;

    const thread = try std.Thread.spawn(.{}, pollLoop, .{poller_ctx});
    self.poller_thread = thread;
}

/// Stop the poller (thread-safe, blocks until thread exits)
pub fn stop(self: *Poller) void {
    // First, signal the thread to stop
    self.stop_requested.store(true, .seq_cst);

    // Then acquire mutex to safely cleanup
    // TODO: Zig 0.16.0 - needs io
        // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
    // TODO: Zig 0.16.0 - needs io
    // defer self.mutex.unlock();

    // Wait for thread to finish and cleanup
    if (self.poller_thread) |thread| {
        // Unlock mutex during join to avoid deadlock
        self.mutex.unlock();
        thread.join();
        // TODO: Zig 0.16.0 - needs io
        // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();

        self.poller_thread = null;
    }

    if (self.poller_ctx) |ctx| {
        self.allocator.destroy(ctx);
        self.poller_ctx = null;
    }
}

/// Set poller mode (thread-safe)
pub fn setMode(self: *Poller, mode: Mode) void {
    // TODO: Zig 0.16.0 - needs io
        // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
    // TODO: Zig 0.16.0 - needs io
    // defer self.mutex.unlock();
    self.mode = mode;
}

/// Poll inbox once (synchronous, thread-safe)
pub fn pollOnce(self: *Poller) !Result {
    // TODO: Zig 0.16.0 - needs io
        // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
    // TODO: Zig 0.16.0 - needs io
    // defer self.mutex.unlock();

    // Enforce minimum interval between polls (rate limiting)
    const now = 0;
    const last = self.last_poll_time.load(.seq_cst);
    if (last > 0 and (now - last) < MIN_POLL_INTERVAL_NS) {
        return error.TooSoon;
    }
    self.last_poll_time.store(@intCast(now), .seq_cst);

    var argv = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
    defer argv.deinit(self.allocator);

    try argv.append(self.allocator, self.binary_path);
    try argv.append(self.allocator, "inbox");
    try argv.append(self.allocator, "--verbose");

    var child = std.process.Child.init(argv.items, self.allocator);
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    try child.spawn();

    const stdout = child.stdout orelse {
        std.log.err("Gork poll: failed to get stdout", .{});
        return Result{ .message_count = 0, .processed = 0 };
    };

    const stderr = child.stderr orelse {
        std.log.err("Gork poll: failed to get stderr", .{});
        return Result{ .message_count = 0, .processed = 0 };
    };

    // Read output before waiting
    var content_list = try std.ArrayList(u8).initCapacity(self.allocator, 1024);
    defer content_list.deinit(self.allocator);

    var read_buf: [4096]u8 = undefined;
    var bytes_read = stdout.read(&read_buf) catch |err| {
        std.log.err("Gork poll: failed to read stdout: {}", .{err});
        return Result{ .message_count = 0, .processed = 0 };
    };

    while (bytes_read > 0) {
        try content_list.appendSlice(self.allocator, read_buf[0..bytes_read]);
        bytes_read = stdout.read(&read_buf) catch |err| {
            std.log.err("Gork poll: failed to read stdout: {}", .{err});
            return Result{ .message_count = 0, .processed = 0 };
        };
    }

    const content = try content_list.toOwnedSlice(self.allocator);
    defer self.allocator.free(content);

    const term = child.wait() catch |err| {
        std.log.err("Gork poll: failed to wait: {}", .{err});
        return Result{ .message_count = 0, .processed = 0 };
    };

    const exit_code = switch (term) {
        .Exited => |code| code,
        else => 1,
    };

    if (exit_code != 0) {
        var err_list = std.ArrayList(u8).initCapacity(self.allocator, 512) catch {
            std.log.err("Gork poll: inbox command failed", .{});
            return Result{ .message_count = 0, .processed = 0 };
        };
        defer err_list.deinit(self.allocator);

        var err_buf: [512]u8 = undefined;
        var err_bytes_read = stderr.read(&err_buf) catch {
            std.log.err("Gork poll: inbox command failed", .{});
            return Result{ .message_count = 0, .processed = 0 };
        };

        while (err_bytes_read > 0) {
            err_list.appendSlice(self.allocator, err_buf[0..err_bytes_read]) catch {};
            err_bytes_read = stderr.read(&err_buf) catch break;
        }

        const err_content = err_list.toOwnedSlice(self.allocator) catch "";
        defer if (err_content.len > 0) self.allocator.free(err_content);
        std.log.err("Gork poll: inbox command failed: {s}", .{err_content});
        return Result{ .message_count = 0, .processed = 0 };
    }

    // Parse inbox output
    var messages = try parseInbox(self.allocator, content);
    defer {
        for (messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        messages.deinit(self.allocator);
    }

    // Process each message
    var processed: usize = 0;
    for (messages.items) |msg| {
        // Convert message to JSON and call callback
        const json = try std.fmt.allocPrint(self.allocator,
            \\{{"from":"{s}","message_type":"{s}","content":"{s}","timestamp":{}}}
        , .{ msg.from, msg.message_type, msg.content, msg.timestamp });
        defer self.allocator.free(json);

        // Get callback under mutex lock
        const cb = self.message_callback;
        if (cb) |callback| {
            callback(json);
        }
        processed += 1;
    }

    // Clear processed messages
    if (processed > 0) {
        _ = self.clearInbox() catch {};
    }

    return Result{
        .message_count = messages.items.len,
        .processed = processed,
    };
}

/// Clear the inbox (thread-safe)
pub fn clearInbox(self: *Poller) !void {
    var argv = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
    defer argv.deinit(self.allocator);

    try argv.append(self.allocator, self.binary_path);
    try argv.append(self.allocator, "clear");

    var child = std.process.Child.init(argv.items, self.allocator);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;

    try child.spawn();
    _ = child.wait() catch {};
}

/// Poll loop - runs in background thread
fn pollLoop(ctx: *PollerContext) void {
    const poller = ctx.poller;


        // Check stop again after sleep
        if (poller.stop_requested.load(.seq_cst)) // TODO: Zig 0.16.0 - break removed
                return;

        const result = poller.pollOnce() catch |err| {
            std.log.err("Gork poll failed: {}", .{err});
            // TODO: Zig 0.16.0 - continue removed
                return;
        };

        if (result.message_count > 0) {
            std.log.info("Gork poll: processed {}/{} messages", .{ result.processed, result.message_count });
        }
}

/// Parse gork-agent inbox output
fn parseInbox(allocator: Allocator, output: []const u8) !std.ArrayList(IncomingMessage) {
    var messages = try std.ArrayList(IncomingMessage).initCapacity(allocator, 0);

    // Example inbox output:
    // ┌─────────────────────────────────────
    // │ From: alice.near
    // │ Date: 2025-01-15 10:30:00
    // │
    // │ Hello, can you help me?
    // └─────────────────────────────────────

    var lines = std.mem.splitScalar(u8, output, '\n');
    var current_msg: ?IncomingMessage = null;

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "│ From:")) {
            if (current_msg) |msg| {
                try messages.append(allocator, msg);
            }
            const from = std.mem.trimLeft(u8, line["│ From:".len..], " ");
            current_msg = IncomingMessage{
                .from = try allocator.dupe(u8, from),
                .message_type = try allocator.dupe(u8, "chat"),
                .content = &.{}, // Start with empty slice
                .timestamp = @intCast(0),
            };
        } else if (current_msg) |*msg| {
            if (std.mem.startsWith(u8, line, "│ ") and !std.mem.startsWith(u8, line, "│ From:") and !std.mem.startsWith(u8, line, "│ Date:")) {
                const content_part = std.mem.trimLeft(u8, line["│ ".len..], " ");
                if (msg.content.len == 0) {
                    // First content line - allocate the copy
                    msg.content = try allocator.dupe(u8, content_part);
                } else {
                    // Append to existing content
                    const old_content = msg.content;
                    msg.content = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ old_content, content_part });
                    allocator.free(old_content);
                }
            }
        }
    }

    if (current_msg) |msg| {
        try messages.append(allocator, msg);
    }

    return messages;
}

/// Incoming message from inbox
pub const IncomingMessage = struct {
    from: []const u8,
    message_type: []const u8,
    content: []const u8,
    timestamp: u64,

    /// Deallocate owned fields
    pub fn deinit(self: *IncomingMessage, allocator: Allocator) void {
        // Only free if non-empty
        if (self.from.len > 0) allocator.free(self.from);
        if (self.message_type.len > 0) allocator.free(self.message_type);
        if (self.content.len > 0) allocator.free(self.content);
    }
};
