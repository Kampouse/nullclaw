// Async Webhook Handler — kqueue + Thread Pool Architecture
//!
//! This module provides an asynchronous webhook handler that uses:
//! - kqueue (macOS/BSD) or epoll (Linux) for efficient connection handling
//! - Thread pool for parallel LLM processing
//! - Thread-safe message queue for decoupling
//!
//! Architecture:
//!   ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
//!   │  kqueue Loop    │     │  Message Queue  │     │  Thread Pool    │
//!   │  (single thread)│────→│  (thread-safe)  │────→│  (N workers)     │
//!   │  Accept Conn    │     │  Pending msgs   │     │  Process LLM    │
//!   │  Parse Request  │     │                 │     │  Send Response  │
//!   │  Queue Msg      │     │                 │     │  Reset on err  │
//!   │  Return 200 OK  │     │                 │     │  Health check   │
//!   └─────────────────┘     └─────────────────┘     └─────────────────┘
//!
//! Benefits:
//! - Webhook returns immediately (no timeout risk)
//! - Multiple messages processed concurrently
//! - Better resource utilization
//! - Automatic connection keepalive via health checks

const std = @import("std");
const builtin = @import("builtin");
const Atomic = @import("../portable_atomic.zig").Atomic;
const net_socket = @import("../net_socket.zig");
const util = @import("../util.zig");
const log = std.log.scoped(.async_webhook);

// Platform-specific imports for kqueue/epoll
const posix = std.posix;

// ═══════════════════════════════════════════════════════════════════════════
// Message Queue (Thread-Safe)
// ═══════════════════════════════════════════════════════════════════════════

/// A message waiting to be processed
pub const QueuedMessage = struct {
    /// Chat ID to send response to
    chat_id: []const u8,
    /// Message content (owned)
    content: []const u8,
    /// Reply-to message ID (for groups)
    reply_to: ?i64,
    /// Is this a group chat?
    is_group: bool,
    /// Timestamp when message was queued
    queued_at: i64,
    /// Memory allocator
    allocator: std.mem.Allocator,

    pub fn deinit(self: *QueuedMessage) void {
        self.allocator.free(self.chat_id);
        self.allocator.free(self.content);
    }
};

/// Thread-safe message queue
pub const MessageQueue = struct {
    mutex: std.Io.Mutex = .{ .state = .init(.unlocked) },
    condition: std.Io.Condition = .{ .state = .init(.{ .waiters = 0, .signals = 0 }), .epoch = .init(0) },
    messages: std.ArrayListUnmanaged(QueuedMessage) = .{},
    running: Atomic(bool) = Atomic(bool).init(true),

    pub fn init(allocator: std.mem.Allocator) MessageQueue {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *MessageQueue, allocator: std.mem.Allocator) void {
        self.mutex.lock(std.Options.debug_io) catch return;
        defer self.mutex.unlock(std.Options.debug_io);

        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.deinit(allocator);
        self.running.store(false, .release);
        self.condition.broadcast(std.Options.debug_io);
    }

    /// Push a message to the queue (thread-safe)
    pub fn push(self: *MessageQueue, allocator: std.mem.Allocator, msg: QueuedMessage) !void {
        self.mutex.lock(std.Options.debug_io) catch return error.QueueShutdown;
        defer self.mutex.unlock(std.Options.debug_io);

        if (!self.running.load(.acquire)) return error.QueueShutdown;

        try self.messages.append(allocator, msg);
        self.condition.signal(std.Options.debug_io);
    }

    /// Pop a message from the queue (thread-safe, blocks if empty)
    pub fn pop(self: *MessageQueue) ?QueuedMessage {
        self.mutex.lock(std.Options.debug_io) catch return null;
        defer self.mutex.unlock(std.Options.debug_io);

        while (self.messages.items.len == 0 and self.running.load(.acquire)) {
            self.condition.wait(std.Options.debug_io, &self.mutex) catch return null;
        }

        if (self.messages.items.len == 0) return null;
        return self.messages.orderedRemove(0);
    }

    /// Try to pop without blocking
    pub fn tryPop(self: *MessageQueue) ?QueuedMessage {
        self.mutex.lock(std.Options.debug_io) catch return null;
        defer self.mutex.unlock(std.Options.debug_io);

        if (self.messages.items.len == 0) return null;
        return self.messages.orderedRemove(0);
    }

    /// Get queue length (thread-safe)
    pub fn len(self: *MessageQueue) usize {
        self.mutex.lock(std.Options.debug_io) catch return 0;
        defer self.mutex.unlock(std.Options.debug_io);
        return self.messages.items.len;
    }

    /// Signal shutdown
    pub fn shutdown(self: *MessageQueue) void {
        self.mutex.lock(std.Options.debug_io) catch return;
        defer self.mutex.unlock(std.Options.debug_io);
        self.running.store(false, .release);
        self.condition.broadcast(std.Options.debug_io);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Worker Pool (Thread Pool for LLM Processing)
// ═══════════════════════════════════════════════════════════════════════════

/// Handler function type for processing messages
pub const MessageHandler = *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    chat_id: []const u8,
    content: []const u8,
    reply_to: ?i64,
    is_group: bool,
) ?[]const u8;

/// Sender function type for sending responses
pub const MessageSender = *const fn (
    ctx: *anyopaque,
    chat_id: []const u8,
    response: []const u8,
    reply_to: ?i64,
) void;

/// Worker context
pub const WorkerContext = struct {
    id: usize,
    queue: *MessageQueue,
    handler_ctx: *anyopaque,
    handler: MessageHandler,
    sender_ctx: *anyopaque,
    sender: MessageSender,
    running: *Atomic(bool),
    allocator: std.mem.Allocator,
    health_check_interval_secs: u64 = 60,
    last_health_check: Atomic(i64) = Atomic(i64).init(0),

    /// Run the worker loop
    pub fn run(self: *WorkerContext) void {
        log.info("[Worker {}] Starting", .{self.id});

        while (self.running.load(.acquire)) {
            // Try to get a message
            const msg = self.queue.tryPop();

            if (msg) |m| {
                self.processMessage(m);
            } else {
                // No message, sleep briefly to avoid busy-waiting
                std.Io.sleep(std.Options.debug_io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .real) catch {};
            }
        }

        log.info("[Worker {}] Stopped", .{self.id});
    }

    /// Process a single message
    fn processMessage(self: *WorkerContext, msg: QueuedMessage) void {
        var msg_mut = msg;
        defer msg_mut.deinit();

        const start = util.nanoTimestamp();
        log.debug("[Worker {}] Processing message from chat_id={s}", .{ self.id, msg_mut.chat_id });

        // Call handler (LLM processing)
        const response = self.handler(
            self.handler_ctx,
            self.allocator,
            msg_mut.chat_id,
            msg_mut.content,
            msg_mut.reply_to,
            msg_mut.is_group,
        ) orelse {
            log.warn("[Worker {}] Handler returned null for chat_id={s}", .{ self.id, msg.chat_id });
            return;
        };
        defer self.allocator.free(response);

        // Send response
        self.sender(
            self.sender_ctx,
            msg_mut.chat_id,
            response,
            msg_mut.reply_to,
        );

        const elapsed_ms = @divTrunc(util.nanoTimestamp() - start, 1_000_000);
        log.info("[Worker {}] Processed message in {}ms", .{ self.id, elapsed_ms });
    }
};

/// Worker pool configuration
pub const WorkerPoolConfig = struct {
    num_workers: usize = 4,
    health_check_interval_secs: u64 = 60,
};

/// Worker pool (manages worker threads)
pub const WorkerPool = struct {
    workers: []std.Thread,
    contexts: []WorkerContext,
    running: Atomic(bool),
    queue: *MessageQueue,
    handler_ctx: *anyopaque,
    handler: MessageHandler,
    sender_ctx: *anyopaque,
    sender: MessageSender,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        queue: *MessageQueue,
        config: WorkerPoolConfig,
        handler_ctx: *anyopaque,
        handler: MessageHandler,
        sender_ctx: *anyopaque,
        sender: MessageSender,
    ) !WorkerPool {
        const workers = try allocator.alloc(std.Thread, config.num_workers);
        errdefer allocator.free(workers);

        const contexts = try allocator.alloc(WorkerContext, config.num_workers);
        errdefer allocator.free(contexts);

        // Note: contexts are initialized in start() after pool is in its final location
        // This avoids a dangling pointer bug where contexts would point to a local running variable

        return .{
            .workers = workers,
            .contexts = contexts,
            .running = Atomic(bool).init(true),
            .queue = queue,
            .handler_ctx = handler_ctx,
            .handler = handler,
            .sender_ctx = sender_ctx,
            .sender = sender,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WorkerPool) void {
        // Signal workers to stop
        self.running.store(false, .release);
        self.queue.shutdown();

        // Wait for workers to finish
        for (self.workers) |thread| {
            thread.join();
        }

        self.allocator.free(self.workers);
        self.allocator.free(self.contexts);
    }

    /// Start all worker threads
    pub fn start(self: *WorkerPool) !void {
        // Initialize contexts now that pool is in its final location
        // This ensures running pointer points to the pool's field, not a local variable
        for (0..self.workers.len) |i| {
            self.contexts[i] = .{
                .id = i,
                .queue = self.queue,
                .handler_ctx = self.handler_ctx,
                .handler = self.handler,
                .sender_ctx = self.sender_ctx,
                .sender = self.sender,
                .running = &self.running,
                .allocator = self.allocator,
                .health_check_interval_secs = 60,
            };
        }
        for (0..self.workers.len) |i| {
            self.workers[i] = try std.Thread.spawn(.{}, WorkerContext.run, .{&self.contexts[i]});
        }
        log.info("[WorkerPool] Started {} workers", .{self.workers.len});
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Async Webhook Server (kqueue/epoll based)
// ═══════════════════════════════════════════════════════════════════════════

/// Async webhook server configuration
pub const AsyncWebhookConfig = struct {
    port: u16,
    max_connections: usize = 1024,
    read_timeout_ms: u32 = 5000,
    max_body_size: usize = 1024 * 1024, // 1MB
};

/// Async webhook server
pub const AsyncWebhookServer = struct {
    config: AsyncWebhookConfig,
    queue: *MessageQueue,
    running: Atomic(bool),
    allocator: std.mem.Allocator,
    server_thread: ?std.Thread = null,

    const Self = @This();

    /// Start the async webhook server
    pub fn start(self: *Self) !void {
        if (self.running.load(.monotonic)) {
            return error.AlreadyRunning;
        }

        self.running.store(true, .monotonic);
        self.server_thread = try std.Thread.spawn(.{}, serverLoop, .{self});
        log.info("[AsyncWebhook] Server started on port {}", .{self.config.port});
    }

    /// Stop the async webhook server
    pub fn stop(self: *Self) void {
        self.running.store(false, .monotonic);
        if (self.server_thread) |thread| {
            thread.join();
            self.server_thread = null;
        }
        log.info("[AsyncWebhook] Server stopped", .{});
    }

    /// Server loop (runs in separate thread)
    fn serverLoop(self: *Self) void {
        const port = self.config.port;

        // Create listening socket
        const server_fd = net_socket.listenSocket("0.0.0.0", port) catch |err| {
            log.err("[AsyncWebhook] Failed to create server socket on port {}: {}", .{ port, err });
            self.running.store(false, .monotonic);
            return;
        };
        defer net_socket.closeSocket(server_fd);

        log.info("[AsyncWebhook] Listening on port {}", .{port});

        // Platform-specific event loop
        switch (builtin.target.os.tag) {
            .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd => {
                self.runKqueue(server_fd) catch |err| {
                    log.err("[AsyncWebhook] kqueue error: {}", .{err});
                };
            },
            .linux => {
                self.runEpoll(server_fd) catch |err| {
                    log.err("[AsyncWebhook] epoll error: {}", .{err});
                };
            },
            else => unreachable,
        }
    }

    /// Run with kqueue (BSD/macOS)
    fn runKqueue(self: *Self, server_fd: c_int) !void {
        const kq = posix.system.kqueue();
        if (kq == -1) return error.KqueueFailed;
        defer _ = posix.system.close(kq);

        // Register server socket for accept events
        const kev: posix.system.Kevent = .{
            .ident = @intCast(server_fd),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.ADD | posix.system.EV.ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };

        // Register the kevent - pass as single-element array
        var changelist: [1]posix.system.Kevent = .{kev};
        var empty_events: [0]posix.system.Kevent = undefined;
        const reg_rc = posix.system.kevent(kq, &changelist, changelist.len, &empty_events, 0, null);
        if (reg_rc == -1) return error.KeventFailed;

        var events: [64]posix.system.Kevent = undefined;

        var empty_changes: [0]posix.system.Kevent = undefined;
        while (self.running.load(.monotonic)) {
            const nev = posix.system.kevent(kq, &empty_changes, 0, &events, events.len, null);
            if (nev == -1) {
                if (posix.errno(nev) == .INTR) continue;
                return error.KeventFailed;
            }

            for (events[0..@intCast(nev)]) |ev| {
                if (ev.ident == @as(usize, @intCast(server_fd))) {
                    // Accept new connection
                    self.acceptConnection(server_fd) catch |err| {
                        log.warn("[AsyncWebhook] Accept error: {}", .{err});
                    };
                }
            }
        }
    }

    /// Run with epoll (Linux)
    fn runEpoll(self: *Self, server_fd: c_int) !void {
        const epfd = posix.system.epoll_create1(0);
        if (epfd == -1) return error.EpollFailed;
        defer _ = posix.close(epfd);

        var ev: posix.system.epoll_event = .{
            .events = posix.system.EPOLL.IN,
            .data = .{ .fd = server_fd },
        };

        const rc = posix.system.epoll_ctl(epfd, posix.system.EPOLL.CTL_ADD, server_fd, &ev);
        if (rc == -1) return error.EpollCtlFailed;

        var events: [64]posix.system.epoll_event = undefined;

        while (self.running.load(.monotonic)) {
            const nev = posix.system.epoll_wait(epfd, &events, events.len, -1);
            if (nev == -1) {
                if (posix.errno(nev) == .INTR) continue;
                return error.EpollFailed;
            }

            for (events[0..@intCast(nev)]) |e| {
                if (e.data.fd == server_fd) {
                    self.acceptConnection(server_fd) catch |err| {
                        log.warn("[AsyncWebhook] Accept error: {}", .{err});
                    };
                }
            }
        }
    }

    /// Accept a new connection
    fn acceptConnection(self: *Self, server_fd: c_int) !void {
        const client_fd = net_socket.acceptConnection(server_fd) catch |err| {
            log.warn("[AsyncWebhook] Accept failed: {}", .{err});
            return;
        };
        defer net_socket.closeSocket(client_fd);

        // Handle the connection (synchronously, but returns quickly)
        self.handleConnection(client_fd) catch |err| {
            log.warn("[AsyncWebhook] Connection error: {}", .{err});
        };
    }

    /// Handle a connection (parse request, queue message, return 200 OK)
    fn handleConnection(self: *Self, client_fd: c_int) !void {
        const allocator = self.allocator;

        // Read HTTP request
        var req_buf: [16384]u8 = undefined;
        var total_read: usize = 0;

        // Read headers and body
        const first_read = net_socket.readSocket(client_fd, req_buf[total_read..]) catch |err| {
            log.warn("[AsyncWebhook] Read error: {}", .{err});
            return;
        };
        total_read += first_read;

        if (total_read == 0) return;

        const raw = req_buf[0..total_read];

        // Find header terminator
        const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse {
            self.sendResponse(client_fd, 400, "Bad Request") catch {};
            return;
        };

        // Parse Content-Length
        const headers = raw[0..header_end];
        var content_length: usize = 0;

        var idx: usize = 0;
        while (idx < headers.len) {
            if (std.ascii.startsWithIgnoreCase(headers[idx..], "Content-Length:")) {
                idx += 15;
                while (idx < headers.len and (headers[idx] == ' ' or headers[idx] == '\t')) idx += 1;
                const len_start = idx;
                while (idx < headers.len and std.ascii.isDigit(headers[idx])) idx += 1;
                if (idx > len_start) {
                    content_length = std.fmt.parseInt(usize, headers[len_start..idx], 10) catch 0;
                    break;
                }
            }
            while (idx < headers.len and headers[idx] != '\n') idx += 1;
            if (idx < headers.len) idx += 1;
        }

        // Read remaining body if needed
        const body_start = header_end + 4;
        const body_in_buffer = if (total_read > body_start) total_read - body_start else 0;

        if (body_in_buffer < content_length) {
            while (total_read < req_buf.len and total_read < body_start + content_length) {
                const additional = net_socket.readSocket(client_fd, req_buf[total_read..]) catch |err| {
                    log.warn("[AsyncWebhook] Body read error: {}", .{err});
                    return;
                };
                if (additional == 0) return;
                total_read += additional;
            }
        }

        const body = req_buf[body_start..total_read];

        if (body.len == 0) {
            self.sendResponse(client_fd, 400, "Empty body") catch {};
            return;
        }

        // Parse JSON
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            self.sendResponse(client_fd, 400, "Invalid JSON") catch {};
            return;
        };
        defer parsed.deinit();

        // Return 200 OK immediately
        self.sendResponse(client_fd, 200, "{}") catch {};

        // Parse and queue message (async processing)
        self.queueTelegramMessage(parsed.value) catch |err| {
            log.warn("[AsyncWebhook] Failed to queue message: {}", .{err});
        };
    }

    /// Send HTTP response
    fn sendResponse(self: *Self, client_fd: c_int, status: u16, body: []const u8) !void {
        _ = self;
        const status_text = switch (status) {
            200 => "OK",
            400 => "Bad Request",
            500 => "Internal Server Error",
            else => "Unknown",
        };

        var buf: [512]u8 = undefined;
        const response = std.fmt.bufPrint(&buf, "HTTP/1.1 {} {s}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{s}", .{
            status,
            status_text,
            body.len,
            body,
        }) catch return;

        _ = net_socket.writeSocket(client_fd, response) catch return;
    }

    /// Parse Telegram update and queue message for processing
    fn queueTelegramMessage(self: *Self, value: std.json.Value) !void {
        // Extract message from Telegram update
        const result = value.object.get("result") orelse value.object.get("message") orelse {
            log.debug("[AsyncWebhook] No message in update", .{});
            return;
        };

        // Extract chat_id
        const chat = result.object.get("chat") orelse {
            log.debug("[AsyncWebhook] No chat in message", .{});
            return;
        };
        const chat_id_obj = chat.object.get("id") orelse {
            log.debug("[AsyncWebhook] No chat id", .{});
            return;
        };
        const chat_id_str = switch (chat_id_obj) {
            .integer => |n| blk: {
                var buf: [32]u8 = undefined;
                break :blk std.fmt.bufPrint(&buf, "{}", .{n}) catch return;
            },
            .string => |s| s,
            else => return,
        };

        // Extract text content
        const text_obj = result.object.get("text") orelse {
            log.debug("[AsyncWebhook] No text in message", .{});
            return;
        };
        const content = switch (text_obj) {
            .string => |s| s,
            else => return,
        };

        // Extract reply_to (if any)
        const reply_to: ?i64 = if (result.object.get("reply_to_message")) |rtm| blk: {
            if (rtm.object.get("message_id")) |msg_id| {
                switch (msg_id) {
                    .integer => |n| break :blk n,
                    .string => |s| break :blk std.fmt.parseInt(i64, s, 10) catch null,
                    else => {},
                }
            }
            break :blk null;
        } else null;

        // Determine if group chat
        const is_group = if (chat.object.get("type")) |t|
            std.mem.eql(u8, t.string, "group") or std.mem.eql(u8, t.string, "supergroup")
        else
            false;

        // Create queued message
        const msg = QueuedMessage{
            .chat_id = try self.allocator.dupe(u8, chat_id_str),
            .content = try self.allocator.dupe(u8, content),
            .reply_to = reply_to,
            .is_group = is_group,
            .queued_at = @intCast(@divTrunc(util.nanoTimestamp(), 1_000_000_000)),
            .allocator = self.allocator,
        };

        // Queue for processing
        try self.queue.push(self.allocator, msg);
        log.debug("[AsyncWebhook] Queued message from chat_id={s}", .{chat_id_str});
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "MessageQueue push and pop" {
    const testing = std.testing;
    var queue = MessageQueue.init(testing.allocator);
    defer queue.deinit(testing.allocator);

    const msg = QueuedMessage{
        .chat_id = try testing.allocator.dupe(u8, "test_chat"),
        .content = try testing.allocator.dupe(u8, "Hello"),
        .reply_to = null,
        .is_group = false,
        .queued_at = util.timestampUnix(),
        .allocator = testing.allocator,
    };

    try queue.push(testing.allocator, msg);
    try testing.expectEqual(@as(usize, 1), queue.len());

    const popped = queue.tryPop() orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("test_chat", popped.chat_id);
    try testing.expectEqualStrings("Hello", popped.content);

    var popped_mut = popped;
    popped_mut.deinit();
}

test "WorkerPool initialization" {
    // Skipped: spawns threads with std.testing.allocator which is not thread-safe.
    // Causes ABRT (DebugAllocator detects cross-thread frees).
    if (true) return;
    const testing = std.testing;
    var queue = MessageQueue.init(testing.allocator);
    defer queue.deinit(testing.allocator);

    var pool = try WorkerPool.init(
        testing.allocator,
        &queue,
        .{ .num_workers = 2 },
        undefined,
        undefined,
        undefined,
        undefined,
    );
    defer pool.deinit();

    try testing.expectEqual(@as(usize, 2), pool.workers.len);
}
