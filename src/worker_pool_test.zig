//! Tests for worker pool and session management
//! Validates parallelism, serialization, and error handling

const std = @import("std");
const worker_pool = @import("worker_pool.zig");
const Spinlock = @import("spinlock.zig").Spinlock;

// ═══════════════════════════════════════════════════════════════════════════
// MessageQueue Tests
// ═══════════════════════════════════════════════════════════════════════════

test "MessageQueue - basic enqueue/dequeue" {
    const TestQueue = worker_pool.MessageQueue(i32);
    var queue: TestQueue = .{};
    defer queue.deinit(std.testing.allocator);

    try queue.enqueue(std.testing.allocator, 42);
    try queue.enqueue(std.testing.allocator, 100);

    const a = queue.dequeue() orelse return error.UnexpectedNull;
    const b = queue.dequeue() orelse return error.UnexpectedNull;

    try std.testing.expectEqual(@as(i32, 42), a);
    try std.testing.expectEqual(@as(i32, 100), b);
}

test "MessageQueue - dequeue returns null when empty and closed" {
    const TestQueue = worker_pool.MessageQueue(i32);
    var queue: TestQueue = .{};
    defer queue.deinit(std.testing.allocator);

    // Empty queue should block (but we can't test blocking easily)
    // Close it and verify null
    queue.close();
    const result = queue.dequeue();
    try std.testing.expect(result == null);
}

test "MessageQueue - close wakes waiting workers" {
    const TestQueue = worker_pool.MessageQueue(i32);
    var queue: TestQueue = .{};
    defer queue.deinit(std.testing.allocator);

    try queue.enqueue(std.testing.allocator, 1);
    
    queue.close();
    
    // Should still return the queued item
    const item = queue.dequeue() orelse return error.UnexpectedNull;
    try std.testing.expectEqual(@as(i32, 1), item);
    
    // Then null
    const next = queue.dequeue();
    try std.testing.expect(next == null);
}

test "MessageQueue - length tracking" {
    const TestQueue = worker_pool.MessageQueue(i32);
    var queue: TestQueue = .{};
    defer queue.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), queue.len());
    
    try queue.enqueue(std.testing.allocator, 1);
    try std.testing.expectEqual(@as(usize, 1), queue.len());
    
    try queue.enqueue(std.testing.allocator, 2);
    try std.testing.expectEqual(@as(usize, 2), queue.len());
    
    _ = queue.dequeue();
    try std.testing.expectEqual(@as(usize, 1), queue.len());
}

// ═══════════════════════════════════════════════════════════════════════════
// SessionLockManager Tests
// ═══════════════════════════════════════════════════════════════════════════

test "SessionLockManager - acquire and release" {
    var mgr = worker_pool.SessionLockManager.init(std.testing.allocator);
    defer mgr.deinit();

    const lock = mgr.acquire("session1");
    mgr.release(lock);

    // Should be able to acquire again
    const lock2 = mgr.acquire("session1");
    mgr.release(lock2);
}

test "SessionLockManager - different sessions don't block" {
    var mgr = worker_pool.SessionLockManager.init(std.testing.allocator);
    defer mgr.deinit();

    const lock1 = mgr.acquire("session1");
    // Don't release yet
    
    // Different session should NOT block
    const lock2 = mgr.acquire("session2");
    
    mgr.release(lock2);
    mgr.release(lock1);
}

// ═══════════════════════════════════════════════════════════════════════════
// Integration Tests
// ═══════════════════════════════════════════════════════════════════════════

test "SessionConfig - serialize_sessions default" {
    const config = @import("config_types.zig").SessionConfig{};
    try std.testing.expect(!config.serialize_sessions);
}

test "SessionConfig - serialize_sessions enabled" {
    const config = @import("config_types.zig").SessionConfig{
        .serialize_sessions = true,
    };
    try std.testing.expect(config.serialize_sessions);
}

// ═══════════════════════════════════════════════════════════════════════════
// Spinlock Tests
// ═══════════════════════════════════════════════════════════════════════════

test "Spinlock - basic lock/unlock" {
    var lock = Spinlock.init();
    
    lock.lock();
    lock.unlock();
    
    // Should be able to lock again
    lock.lock();
    lock.unlock();
}

test "Spinlock - mutual exclusion" {
    var lock = Spinlock.init();
    var counter: usize = 0;
    
    const ThreadContext = struct {
        lock: *Spinlock,
        counter: *usize,
        
        fn run(ctx: *@This()) void {
            var i: usize = 0;
            while (i < 1000) : (i += 1) {
                ctx.lock.lock();
                ctx.counter.* += 1;
                ctx.lock.unlock();
            }
        }
    };
    
    var ctx = ThreadContext{ .lock = &lock, .counter = &counter };
    
    // Spawn multiple threads
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, ThreadContext.run, .{&ctx});
    }
    
    // Wait for all threads
    for (threads) |t| {
        t.join();
    }
    
    // Counter should be exactly 4000 (4 threads * 1000 iterations)
    try std.testing.expectEqual(@as(usize, 4000), counter);
}

// ═══════════════════════════════════════════════════════════════════════════
// Parallel Processing Tests
// ═══════════════════════════════════════════════════════════════════════════

test "SessionLockManager - parallel access to different sessions" {
    var mgr = worker_pool.SessionLockManager.init(std.testing.allocator);
    defer mgr.deinit();

    const ThreadContext = struct {
        mgr: *worker_pool.SessionLockManager,
        session_id: []const u8,
        iterations: usize,
        
        fn run(ctx: *@This()) void {
            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                const lock = ctx.mgr.acquire(ctx.session_id);
                // Simulate some work
                var sum: usize = 0;
                var j: usize = 0;
                while (j < 100) : (j += 1) {
                    sum += j;
                }
                ctx.mgr.release(lock);
            }
        }
    };
    
    // 4 threads, different sessions - should run fully parallel
    var ctx1 = ThreadContext{ .mgr = &mgr, .session_id = "session1", .iterations = 100 };
    var ctx2 = ThreadContext{ .mgr = &mgr, .session_id = "session2", .iterations = 100 };
    var ctx3 = ThreadContext{ .mgr = &mgr, .session_id = "session3", .iterations = 100 };
    var ctx4 = ThreadContext{ .mgr = &mgr, .session_id = "session4", .iterations = 100 };
    
    const t1 = try std.Thread.spawn(.{}, ThreadContext.run, .{&ctx1});
    const t2 = try std.Thread.spawn(.{}, ThreadContext.run, .{&ctx2});
    const t3 = try std.Thread.spawn(.{}, ThreadContext.run, .{&ctx3});
    const t4 = try std.Thread.spawn(.{}, ThreadContext.run, .{&ctx4});
    
    t1.join();
    t2.join();
    t3.join();
    t4.join();
    
    // If we get here without deadlock, test passes
    try std.testing.expect(true);
}

test "SessionLockManager - same session serialization under load" {
    var mgr = worker_pool.SessionLockManager.init(std.testing.allocator);
    defer mgr.deinit();

    const ThreadContext = struct {
        mgr: *worker_pool.SessionLockManager,
        counter: *usize,
        
        fn run(ctx: *@This()) void {
            var i: usize = 0;
            while (i < 1000) : (i += 1) {
                const lock = ctx.mgr.acquire("shared_session");
                ctx.counter.* += 1;
                ctx.mgr.release(lock);
            }
        }
    };
    
    var counter: usize = 0;
    var ctx1 = ThreadContext{ .mgr = &mgr, .counter = &counter };
    var ctx2 = ThreadContext{ .mgr = &mgr, .counter = &counter };
    var ctx3 = ThreadContext{ .mgr = &mgr, .counter = &counter };
    var ctx4 = ThreadContext{ .mgr = &mgr, .counter = &counter };
    
    const t1 = try std.Thread.spawn(.{}, ThreadContext.run, .{&ctx1});
    const t2 = try std.Thread.spawn(.{}, ThreadContext.run, .{&ctx2});
    const t3 = try std.Thread.spawn(.{}, ThreadContext.run, .{&ctx3});
    const t4 = try std.Thread.spawn(.{}, ThreadContext.run, .{&ctx4});
    
    t1.join();
    t2.join();
    t3.join();
    t4.join();
    
    // Counter should be exactly 4000 (no race conditions)
    try std.testing.expectEqual(@as(usize, 4000), counter);
}

// ═══════════════════════════════════════════════════════════════════════════
// Edge Case Tests
// ═══════════════════════════════════════════════════════════════════════════

test "MessageQueue - enqueue then close then dequeue all" {
    const TestQueue = worker_pool.MessageQueue(i32);
    var queue: TestQueue = .{};
    defer queue.deinit(std.testing.allocator);

    // Enqueue many items
    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        try queue.enqueue(std.testing.allocator, i);
    }
    
    // Close queue
    queue.close();
    
    // Should still be able to dequeue all
    var count: usize = 0;
    while (queue.dequeue()) |_| {
        count += 1;
    }
    
    try std.testing.expectEqual(@as(usize, 100), count);
    
    // Further dequeue should return null
    try std.testing.expect(queue.dequeue() == null);
}

test "MessageQueue - rapid enqueue/dequeue" {
    const TestQueue = worker_pool.MessageQueue(i32);
    var queue: TestQueue = .{};
    defer queue.deinit(std.testing.allocator);

    const ThreadContext = struct {
        queue: *TestQueue,
        role: enum { producer, consumer },
        count: *usize,
        
        fn run(ctx: *@This()) void {
            switch (ctx.role) {
                .producer => {
                    var i: i32 = 0;
                    while (i < 1000) : (i += 1) {
                        ctx.queue.enqueue(std.testing.allocator, i) catch continue;
                    }
                },
                .consumer => {
                    var received: usize = 0;
                    while (received < 1000) {
                        if (ctx.queue.dequeue()) |_| {
                            received += 1;
                            ctx.count.* += 1;
                        }
                    }
                },
            }
        }
    };
    
    var consumed: usize = 0;
    
    var producer_ctx = ThreadContext{ .queue = &queue, .role = .producer, .count = &consumed };
    var consumer_ctx = ThreadContext{ .queue = &queue, .role = .consumer, .count = &consumed };
    
    const producer = try std.Thread.spawn(.{}, ThreadContext.run, .{&producer_ctx});
    const consumer = try std.Thread.spawn(.{}, ThreadContext.run, .{&consumer_ctx});
    
    producer.join();
    consumer.join();
    
    // All 1000 messages should have been consumed
    try std.testing.expectEqual(@as(usize, 1000), consumed);
}

test "SessionLockManager - many sessions" {
    var mgr = worker_pool.SessionLockManager.init(std.testing.allocator);
    defer mgr.deinit();

    // Acquire many different sessions
    var locks: [100]*Spinlock = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "session_{}", .{i}) catch unreachable;
        locks[i] = mgr.acquire(key);
    }
    
    // Release all
    i = 0;
    while (i < 100) : (i += 1) {
        mgr.release(locks[i]);
    }
    
    // Should complete without memory issues
    try std.testing.expect(true);
}

test "SessionLockManager - empty session key" {
    var mgr = worker_pool.SessionLockManager.init(std.testing.allocator);
    defer mgr.deinit();

    // Empty string should work as a valid session key
    const lock = mgr.acquire("");
    mgr.release(lock);
    
    // Should not crash
    try std.testing.expect(true);
}

test "MessageQueue - empty queue close" {
    const TestQueue = worker_pool.MessageQueue(i32);
    var queue: TestQueue = .{};
    defer queue.deinit(std.testing.allocator);

    // Close empty queue
    queue.close();
    
    // Should return null
    try std.testing.expect(queue.dequeue() == null);
}

test "MessageQueue - multiple close calls" {
    const TestQueue = worker_pool.MessageQueue(i32);
    var queue: TestQueue = .{};
    defer queue.deinit(std.testing.allocator);

    try queue.enqueue(std.testing.allocator, 1);
    
    // Multiple close calls should be safe
    queue.close();
    queue.close();
    queue.close();
    
    // Should still return the queued item
    const item = queue.dequeue() orelse return error.UnexpectedNull;
    try std.testing.expectEqual(@as(i32, 1), item);
}

// ═══════════════════════════════════════════════════════════════════════════
// Stress Tests
// ═══════════════════════════════════════════════════════════════════════════

test "MessageQueue - high contention" {
    const TestQueue = worker_pool.MessageQueue(i32);
    var queue: TestQueue = .{};
    defer queue.deinit(std.testing.allocator);

    const ThreadContext = struct {
        queue: *TestQueue,
        produced: *std.atomic.Value(usize),
        consumed: *std.atomic.Value(usize),
        role: enum { producer, consumer },
        allocator: std.mem.Allocator,
        
        fn run(ctx: *@This()) void {
            defer ctx.allocator.destroy(ctx);
            
            switch (ctx.role) {
                .producer => {
                    var i: i32 = 0;
                    while (i < 100) : (i += 1) {
                        ctx.queue.enqueue(ctx.allocator, i) catch continue;
                        _ = ctx.produced.fetchAdd(1, .monotonic);
                    }
                },
                .consumer => {
                    while (ctx.consumed.load(.monotonic) < 400) {
                        if (ctx.queue.dequeue()) |_| {
                            _ = ctx.consumed.fetchAdd(1, .monotonic);
                        }
                    }
                },
            }
        }
    };
    
    var produced = std.atomic.Value(usize).init(0);
    var consumed = std.atomic.Value(usize).init(0);
    
    // 4 producers, 4 consumers
    var threads: [8]std.Thread = undefined;
    
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const ctx = try std.testing.allocator.create(ThreadContext);
        ctx.* = .{ 
            .queue = &queue, 
            .produced = &produced, 
            .consumed = &consumed, 
            .role = .producer,
            .allocator = std.testing.allocator,
        };
        threads[i] = try std.Thread.spawn(.{}, ThreadContext.run, .{ctx});
    }
    
    i = 4;
    while (i < 8) : (i += 1) {
        const ctx = try std.testing.allocator.create(ThreadContext);
        ctx.* = .{ 
            .queue = &queue, 
            .produced = &produced, 
            .consumed = &consumed, 
            .role = .consumer,
            .allocator = std.testing.allocator,
        };
        threads[i] = try std.Thread.spawn(.{}, ThreadContext.run, .{ctx});
    }
    
    // Wait for all threads
    for (threads) |t| {
        t.join();
    }
    
    // All messages should be consumed
    try std.testing.expectEqual(@as(usize, 400), consumed.load(.monotonic));
}

test "Spinlock - high contention" {
    var lock = Spinlock.init();
    var counter: usize = 0;
    
    const ThreadContext = struct {
        lock: *Spinlock,
        counter: *usize,
        
        fn run(ctx: *@This()) void {
            var i: usize = 0;
            while (i < 1000) : (i += 1) {
                ctx.lock.lock();
                ctx.counter.* += 1;
                ctx.lock.unlock();
            }
        }
    };
    
    var ctx = ThreadContext{ .lock = &lock, .counter = &counter };
    
    // 8 threads contending for same lock
    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, ThreadContext.run, .{&ctx});
    }
    
    for (threads) |t| {
        t.join();
    }
    
    // Should be exactly 8000 (8 threads * 1000 iterations)
    try std.testing.expectEqual(@as(usize, 8000), counter);
}

