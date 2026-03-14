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

