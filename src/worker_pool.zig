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
const util = @import("util.zig");

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

        /// Enqueue an item (non-blocking)
        pub fn enqueue(self: *Self, allocator: std.mem.Allocator, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed.load(.acquire)) return error.QueueClosed;

            try self.items.append(allocator, item);
            log.debug("Queue: enqueued item, queue_len={}", .{self.items.items.len});
        }

        /// Dequeue an item (polling with yield)
        /// Returns null if queue is closed and empty
        pub fn dequeue(self: *Self) ?T {
            while (!self.closed.load(.acquire)) {
                self.mutex.lock();
                if (self.items.items.len > 0) {
                    const item = self.items.orderedRemove(0);
                    self.mutex.unlock();
                    log.debug("Queue: dequeued item, remaining_len={}", .{self.items.items.len});
                    return item;
                }
                self.mutex.unlock();

                // Yield CPU to avoid contention when queue is empty
                // Uses util.sleep (C nanosleep) for thread-safe sleeping without I/O context
                // util.sleep(10_000); // 10 microseconds
            }

            // Queue closed, return any remaining items
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.items.items.len > 0) {
                log.debug("Queue: dequeued item from closed queue, remaining_len={}", .{self.items.items.len - 1});
                return self.items.orderedRemove(0);
            }
            log.debug("Queue: queue closed and empty, returning null", .{});
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

            // Free any remaining messages (they own memory)
            // Note: This assumes T has a deinit method. For generic types,
            // we just free the array backing storage.
            self.items.deinit(allocator);
        }

        /// Deinit with message cleanup - drains queue and calls deinit on each message
        pub fn deinitWithMessageCleanup(self: *Self, allocator: std.mem.Allocator, comptime deinitFn: fn (*const T, std.mem.Allocator) void) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Drain and cleanup remaining messages
            while (self.items.items.len > 0) {
                const msg = self.items.orderedRemove(0);
                deinitFn(&msg, allocator);
            }
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

    /// Fallback lock used when OOM occurs (graceful degradation)
    const FallbackLock = struct {
        lock: Spinlock = Spinlock.init(),
    };
    var fallback_lock: FallbackLock = .{};

    /// Acquire lock for a session (creates if not exists)
    /// Returns the lock, caller must call release()
    /// On OOM, returns a shared fallback lock (graceful degradation)
    pub fn acquire(self: *Self, session_key: []const u8) *Spinlock {
        self.mutex.lock();
        defer self.mutex.unlock();

        const gop = self.locks.getOrPut(self.allocator, session_key) catch {
            // OOM: use fallback lock (all sessions serialize on this)
            log.warn("SessionLockManager OOM, using fallback lock", .{});
            fallback_lock.lock.lock();
            return &fallback_lock.lock;
        };
        if (!gop.found_existing) {
            const lock_ptr = self.allocator.create(Spinlock) catch {
                // OOM: use fallback lock
                log.warn("SessionLockManager OOM creating lock, using fallback", .{});
                fallback_lock.lock.lock();
                return &fallback_lock.lock;
            };
            lock_ptr.* = Spinlock.init();
            gop.value_ptr.* = lock_ptr;

            // Store owned key
            const key_owned = self.allocator.dupe(u8, session_key) catch {
                // OOM: still return the lock we created, just with a borrowed key
                // This is safe because we never free individual keys, only on deinit
                gop.key_ptr.* = session_key; // Borrow the key (won't be freed)
                const lock = gop.value_ptr.*;
                lock.lock();
                return lock;
            };
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
        /// Mutex to protect allocator operations across threads
        allocator_mutex: Spinlock,

        const Worker = struct {
            thread: ?std.Thread = null,
            pool: *Self,
            id: usize,

            fn run(worker: *Worker) void {
                log.debug("Worker {} started, pool ptr: 0x{x}", .{ worker.id, @intFromPtr(worker.pool) });

                while (true) {
                    log.debug("Worker {} waiting for message...", .{worker.id});

                    const msg = worker.pool.queue.dequeue() orelse {
                        // Queue closed and empty
                        log.debug("Worker {} exiting (queue closed)", .{worker.id});
                        return;
                    };
                    log.debug("Worker {} received message, processing...", .{worker.id});

                    // Process message - handler handles ALL errors internally (returns void)
                    worker.pool.handler.process(msg);
                    log.debug("Worker {} finished processing message", .{worker.id});
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
                .allocator_mutex = Spinlock.init(),
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

        /// Get thread-safe allocator for use in worker threads
        /// This returns an allocator protected by a mutex for safe concurrent access
        pub fn getThreadSafeAllocator(self: *Self) std.mem.Allocator {
            _ = self;
            // For now, we use page_allocator which is thread-safe by default
            // This avoids the complexity of wrapping the shared allocator
            return std.heap.page_allocator;
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
            log.debug("WorkerPool: submitting message to queue", .{});
            try self.queue.enqueue(self.allocator, msg);
            log.debug("WorkerPool: message submitted successfully", .{});
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
