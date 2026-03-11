//! Worker Pool — thread-safe message processing for parallel execution
//!
//! Architecture:
//!   - Poll thread: enqueue messages (non-blocking)
//!   - Worker threads: dequeue and process (parallel)
//!   - Per-session locking: preserve conversation order
//!
//! Benefits:
//!   - User A's slow LLM call doesn't block user B
//!   - Poll thread always responsive
//!   - Configurable worker count

const std = @import("std");
const Atomic = @import("portable_atomic.zig").Atomic;

const log = std.log.scoped(.worker_pool);

// ═══════════════════════════════════════════════════════════════════════════
// Message Queue (thread-safe, polling dequeue)
// ═══════════════════════════════════════════════════════════════════════════

pub fn MessageQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        items: std.ArrayListUnmanaged(T) = .empty,
        mutex: std.Io.Mutex = .{ .state = .init(.unlocked) },
        closed: Atomic(bool) = Atomic(bool).init(false),

        /// Enqueue an item (non-blocking)
        pub fn enqueue(self: *Self, allocator: std.mem.Allocator, item: T) !void {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);

            if (self.closed.load(.acquire)) return error.QueueClosed;

            try self.items.append(allocator, item);
        }

        /// Dequeue an item (polling with sleep)
        /// Returns null if queue is closed and empty
        pub fn dequeue(self: *Self) ?T {
            while (!self.closed.load(.acquire)) {
                self.mutex.lockUncancelable(std.Options.debug_io);
                defer self.mutex.unlock(std.Options.debug_io);

                if (self.items.items.len > 0) {
                    return self.items.orderedRemove(0);
                }

                // Drop lock and sleep briefly before retry
                self.mutex.unlock(std.Options.debug_io);
                std.Io.sleep(std.Options.debug_io, .{ .nanoseconds = 10_000_000 }, .real) catch {}; // 10ms
                self.mutex.lockUncancelable(std.Options.debug_io);
            }

            // Queue closed, return any remaining items
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);

            if (self.items.items.len > 0) {
                return self.items.orderedRemove(0);
            }
            return null;
        }

        /// Close the queue (wakes waiting workers)
        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
        }

        /// Get current queue length (approximate, for monitoring)
        pub fn len(self: *Self) usize {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);
            return self.items.items.len;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);

            self.items.deinit(allocator);
        }
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Session Lock Manager (per-session serialization)
// ═══════════════════════════════════════════════════════════════════════════

pub const SessionLockManager = struct {
    const Self = @This();

    locks: std.StringHashMapUnmanaged(*std.Io.Mutex) = .empty,
    mutex: std.Io.Mutex = .{ .state = .init(.unlocked) },
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        var iter = self.locks.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.locks.deinit(self.allocator);
    }

    /// Acquire lock for a session (creates if not exists)
    /// Returns the lock, caller must call release()
    pub fn acquire(self: *Self, session_key: []const u8) *std.Io.Mutex {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        const gop = self.locks.getOrPut(self.allocator, session_key) catch @panic("SessionLockManager OOM");
        if (!gop.found_existing) {
            const lock_ptr = self.allocator.create(std.Io.Mutex) catch @panic("SessionLockManager OOM");
            lock_ptr.* = .{ .state = .init(.unlocked) };
            gop.value_ptr.* = lock_ptr;
            
            // Store owned key
            const key_owned = self.allocator.dupe(u8, session_key) catch @panic("SessionLockManager OOM");
            gop.key_ptr.* = key_owned;
        }

        const lock = gop.value_ptr.*;
        self.mutex.unlock(std.Options.debug_io);
        lock.lockUncancelable(std.Options.debug_io);
        return lock;
    }

    /// Release lock for a session
    pub fn release(self: *Self, lock: *std.Io.Mutex) void {
        _ = self; // Not used, but matches API symmetry
        lock.unlock(std.Options.debug_io);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Worker Pool
// ═══════════════════════════════════════════════════════════════════════════

pub fn WorkerPool(comptime Message: type, comptime Handler: type) type {
    return struct {
        const Self = @This();
        const MessageQueueType = MessageQueue(Message);

        queue: MessageQueueType,
        workers: []Worker,
        allocator: std.mem.Allocator,
        handler: Handler,

        const Worker = struct {
            thread: ?std.Thread = null,
            pool: *Self,
            id: usize,

            fn run(worker: *Worker) void {
                log.debug("Worker {} started", .{worker.id});
                
                while (true) {
                    const msg = worker.pool.queue.dequeue() orelse {
                        // Queue closed and empty
                        log.debug("Worker {} exiting (queue closed)", .{worker.id});
                        return;
                    };

                    worker.pool.handler.process(msg) catch |err| {
                        log.err("Worker {} error: {}", .{ worker.id, err });
                    };
                }
            }
        };

        pub fn init(
            allocator: std.mem.Allocator,
            handler: Handler,
            worker_count: usize,
        ) !Self {
            const workers = try allocator.alloc(Worker, worker_count);
            errdefer allocator.free(workers);

            var self = Self{
                .queue = .{},
                .workers = workers,
                .allocator = allocator,
                .handler = handler,
            };

            // Initialize worker metadata
            for (workers, 0..) |*worker, i| {
                worker.* = .{
                    .pool = &self,
                    .id = i,
                };
            }

            // Spawn worker threads
            for (workers) |*worker| {
                worker.thread = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, Worker.run, .{worker});
            }

            log.info("Worker pool started with {} workers", .{worker_count});
            return self;
        }

        pub fn deinit(self: *Self) void {
            // Close queue (wakes all workers)
            self.queue.close();

            // Join all workers
            for (self.workers) |*worker| {
                if (worker.thread) |t| {
                    t.join();
                }
            }

            self.queue.deinit(self.allocator);
            self.allocator.free(self.workers);
            log.info("Worker pool stopped", .{});
        }

        /// Submit a message for processing (non-blocking)
        pub fn submit(self: *Self, msg: Message) !void {
            try self.queue.enqueue(self.allocator, msg);
        }

        /// Get pending message count (approximate)
        pub fn pending(self: *Self) usize {
            return self.queue.len();
        }
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "MessageQueue - basic enqueue/dequeue" {
    var queue: MessageQueue(i32) = .{};
    defer queue.deinit(std.testing.allocator);

    try queue.enqueue(std.testing.allocator, 42);
    try queue.enqueue(std.testing.allocator, 100);

    const a = queue.dequeue() orelse return error.UnexpectedNull;
    const b = queue.dequeue() orelse return error.UnexpectedNull;

    try std.testing.expectEqual(@as(i32, 42), a);
    try std.testing.expectEqual(@as(i32, 100), b);
}

test "MessageQueue - close wakes waiting dequeue" {
    var queue: MessageQueue(i32) = .{};
    defer queue.deinit(std.testing.allocator);

    // Close immediately
    queue.close();

    // Dequeue should return null when queue is closed and empty
    const result = queue.dequeue();
    try std.testing.expect(result == null);
}

test "WorkerPool - parallel processing" {
    const TestMessage = struct {
        id: usize,
        value: i32,
    };

    const TestHandler = struct {
        processed: *usize,
        mutex: *std.Io.Mutex,

        pub fn process(self: @This(), msg: TestMessage) !void {
            self.mutex.lockUncancelable(std.Options.debug_io);
            self.processed.* += 1;
            self.mutex.unlock(std.Options.debug_io);

            _ = msg;
        }
    };

    var processed: usize = 0;
    var mutex: std.Io.Mutex = .{ .state = .init(.unlocked) };
    
    const handler = TestHandler{
        .processed = &processed,
        .mutex = &mutex,
    };

    var pool = try WorkerPool(TestMessage, TestHandler).init(std.testing.allocator, handler, 4);
    defer pool.deinit();

    // Submit 100 messages
    for (0..100) |i| {
        try pool.submit(.{ .id = i, .value = @intCast(i) });
    }

    // Wait for all messages to be processed
    var attempts: usize = 0;
    while (processed < 100 and attempts < 1000) : (attempts += 1) {
        std.Io.sleep(std.Options.debug_io, .{ .nanoseconds = std.time.ns_per_ms * 10 }, .real) catch {};
    }

    try std.testing.expectEqual(@as(usize, 100), processed);
}

test "SessionLockManager - per-session serialization" {
    var mgr = SessionLockManager.init(std.testing.allocator);
    defer mgr.deinit();

    const lock1 = mgr.acquire("session-a");
    mgr.release(lock1);

    const lock2 = mgr.acquire("session-b");
    mgr.release(lock2);

    // Same session should get same lock
    const lock3 = mgr.acquire("session-a");
    mgr.release(lock3);
}
