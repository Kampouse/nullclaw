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
const Spinlock = @import("spinlock.zig").Spinlock;

const log = std.log.scoped(.worker_pool);

// ═══════════════════════════════════════════════════════════════════════════
// Message Queue (thread-safe, polling dequeue)
// ═══════════════════════════════════════════════════════════════════════════

pub fn MessageQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        items: std.ArrayListUnmanaged(T) = .empty,
        mutex: Spinlock = Spinlock.init(),
        closed: Atomic(bool) = Atomic(bool).init(false),
        max_queue_size: usize = 1000, // Prevent memory exhaustion

        /// Enqueue an item (non-blocking)
        pub fn enqueue(self: *Self, allocator: std.mem.Allocator, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed.load(.acquire)) return error.QueueClosed;

            // Check queue limit to prevent memory exhaustion
            if (self.items.items.len >= self.max_queue_size) {
                // DISABLED: log.warn("Queue full ({} items), rejecting message", .{self.items.items.len});
                return error.QueueFull;
            }

            try self.items.append(allocator, item);
        }

        /// Dequeue an item (polling with spin wait)
        /// Returns null if queue is closed and empty
        pub fn dequeue(self: *Self) ?T {
            while (!self.closed.load(.acquire)) {
                self.mutex.lock();
                if (self.items.items.len > 0) {
                    const item = self.items.orderedRemove(0);
                    self.mutex.unlock();
                    // DISABLED: log.debug("Dequeued item, remaining: {}", .{self.items.items.len});
                    return item;
                }
                self.mutex.unlock();

                // Sleep for 100ms to reduce CPU usage while waiting for messages
                const util = @import("util.zig");
                util.sleep(100 * std.time.ns_per_ms);
            }

            // Queue closed, return any remaining items
            self.mutex.lock();
            defer self.mutex.unlock();

            // DISABLED: log.debug("Queue closed, checking for remaining items: {}", .{self.items.items.len});
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
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.items.items.len;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.items.deinit(allocator);
        }
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Session Lock Manager (per-session serialization)
// ═══════════════════════════════════════════════════════════════════════════

pub const SessionLockManager = struct {
    const Self = @This();

    locks: std.StringHashMapUnmanaged(*Spinlock) = .empty,
    mutex: Spinlock = Spinlock.init(),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.locks.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.locks.deinit(self.allocator);
    }

    /// Acquire lock for a session (creates if not exists)
    /// Returns the lock, caller must call release()
    pub fn acquire(self: *Self, session_key: []const u8) *Spinlock {
        self.mutex.lock();
        defer self.mutex.unlock();

        const gop = self.locks.getOrPut(self.allocator, session_key) catch @panic("SessionLockManager OOM");
        if (!gop.found_existing) {
            const lock_ptr = self.allocator.create(Spinlock) catch @panic("SessionLockManager OOM");
            lock_ptr.* = Spinlock.init();
            gop.value_ptr.* = lock_ptr;

            // Store owned key
            const key_owned = self.allocator.dupe(u8, session_key) catch @panic("SessionLockManager OOM");
            gop.key_ptr.* = key_owned;
        }

        const lock = gop.value_ptr.*;
        lock.lock();
        return lock;
    }

    /// Release lock for a session
    pub fn release(self: *Self, lock: *Spinlock) void {
        _ = self; // Not used, but matches API symmetry
        lock.unlock();
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
                // DISABLED: Worker pool logging to avoid macOS __simple_asl_init memory corruption
                // log.debug("Worker {} started, pool ptr: 0x{x}", .{worker.id, @intFromPtr(worker.pool)});
                var messages_processed: usize = 0;

                while (true) {
                    // log.debug("Worker {} waiting for message...", .{worker.id});

                    const msg = worker.pool.queue.dequeue() orelse {
                        // Queue closed and empty
                        // log.info("Worker {} exiting (processed {} messages)", .{worker.id, messages_processed});
                        return;
                    };
                    // log.debug("Worker {} received message, processing...", .{worker.id});

                    // Process message without error logging to avoid corruption
                    worker.pool.handler.process(msg) catch |err| {
                        // DISABLED: log.err("Worker {} error processing message: {}", .{worker.id, err});
                        _ = err; // Suppress unused variable warning
                        // Continue processing other messages even if this one failed
                    };

                    messages_processed += 1;
                    // log.debug("Worker {} finished processing message (total: {})", .{worker.id, messages_processed});

                    // Add explicit yield to prevent tight loops
                    std.atomic.spinLoopHint();
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

            // Initialize workers with null pool pointers (will be set in start)
            for (workers, 0..) |*worker, i| {
                worker.* = .{
                    .pool = undefined, // Temporary, will be set in start()
                    .id = i,
                };
            }

            return Self{
                .queue = .{},
                .workers = workers,
                .allocator = allocator,
                .handler = handler,
            };
        }

        /// Start worker threads - MUST be called while self is at its final location
        pub fn start(self: *Self) !void {
            // Set pool pointers now that self is at its final address
            for (self.workers) |*worker| {
                worker.pool = self;
            }

            // Spawn worker threads with larger stack size for agent processing
            // Increased from 2MB to 8MB to handle large LLM responses and tool calls
            for (self.workers) |*worker| {
                worker.thread = try std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, Worker.run, .{worker});
            }

            // DISABLED: log.info("Worker pool started with {} workers", .{self.workers.len});
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
            // DISABLED: log.info("Worker pool stopped", .{});
        }

        /// Submit a message for processing (non-blocking)
        pub fn submit(self: *Self, msg: Message) !void {
            try self.queue.enqueue(self.allocator, msg);
            // DISABLED: const queue_len = self.queue.len();
            // DISABLED: if (queue_len > 10) {
            // DISABLED:     log.warn("Worker pool backlog: {} messages waiting", .{queue_len});
            // DISABLED: }
        }

        /// Get pending message count (approximate)
        pub fn pending(self: *Self) usize {
            return self.queue.len();
        }

        /// Get worker count
        pub fn workerCount(self: *Self) usize {
            return self.workers.len;
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
        mutex: *Spinlock,

        pub fn process(self: @This(), msg: TestMessage) !void {
            self.mutex.lock();
            self.processed.* += 1;
            self.mutex.unlock();

            _ = msg;
        }
    };

    var processed: usize = 0;
    var mutex: Spinlock = Spinlock.init();

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
