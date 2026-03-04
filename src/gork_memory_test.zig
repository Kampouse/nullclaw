//! Memory leak detection tests for Gork P2P agent collaboration system.
//!
//! Uses General Purpose Allocator (GPA) to detect memory leaks automatically.
//! These tests verify that all resources are properly cleaned up.

const std = @import("std");

const gork = @import("./gork_hybrid.zig");
const Hybrid = gork.Hybrid;
const Config = gork.Config;
const Event = gork.Event;

// ── Basic Lifecycle Tests ─────────────────────────────────────────────

test "Hybrid: no memory leaks on init/deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = Config{};
    var hybrid = try Hybrid.init(allocator, config, dummyCallback);
    hybrid.start() catch {};
    hybrid.stop();
}

test "Hybrid: no memory leaks without start" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = Config{};
    var hybrid = try Hybrid.init(allocator, config, dummyCallback);
    hybrid.stop(); // Stop without start should be safe
}

// ── Stress Tests ───────────────────────────────────────────────────────

test "Hybrid: no memory leaks on repeated start/stop (100 cycles)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = Config{};

    for (0..100) |i| {
        var hybrid = try Hybrid.init(allocator, config, dummyCallback);
        hybrid.start() catch {};
        hybrid.stop();

        if (i % 25 == 0) {
            std.log.debug("Stress test cycle {} complete", .{i});
        }
    }
}

// ── Error Path Tests ───────────────────────────────────────────────────

test "Hybrid: no memory leaks on validation errors" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = Config{};
    var hybrid = try Hybrid.init(allocator, config, dummyCallback);
    hybrid.start() catch {};
    defer hybrid.stop();

    // Test invalid agent ID
    const result1 = hybrid.sendMessage("invalid@agent!id", "test message");
    try std.testing.expectError(error.InvalidAgentId, result1);

    // Test message too long
    const long_message = "x" ** (gork.MAX_MESSAGE_LEN + 1);
    const result2 = hybrid.sendMessage("valid.near", long_message);
    try std.testing.expectError(error.MessageTooLong, result2);

    // Test empty agent ID
    const result3 = hybrid.sendMessage("", "test");
    try std.testing.expectError(error.AgentIdEmpty, result3);

    // Test empty message
    const result4 = hybrid.sendMessage("test.near", "");
    // Empty message is valid, should succeed or fail with different error
    _ = result4 catch {};
}

test "Hybrid: no memory leaks on circuit breaker open" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = Config{
        .circuit_breaker_threshold = 1,
        .circuit_breaker_timeout_secs = 60,
    };
    var hybrid = try Hybrid.init(allocator, config, dummyCallback);
    hybrid.start() catch {};
    defer hybrid.stop();

    // Force circuit breaker to open
    var cb = &hybrid.circuit_breaker;
    cb.recordFailure();

    // Now all sends should fail
    const result = hybrid.sendMessage("test.near", "test");
    try std.testing.expectError(error.CircuitBreakerOpen, result);
}

// ── Rate Limiter Tests ─────────────────────────────────────────────────

test "Hybrid: no memory leaks with rate limiter enabled" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = Config{
        .enable_rate_limiting = true,
    };
    var hybrid = try Hybrid.init(allocator, config, dummyCallback);
    hybrid.start() catch {};
    hybrid.stop();
}

test "Hybrid: rate limiter cleanup on stop" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = Config{
        .enable_rate_limiting = true,
    };
    var hybrid = try Hybrid.init(allocator, config, dummyCallback);

    // Verify rate limiter was created
    try std.testing.expect(hybrid.rate_limiter != null);

    hybrid.stop();

    // Verify rate limiter was cleaned up
    try std.testing.expect(hybrid.rate_limiter == null);
}

// ── Event Cleanup Tests ────────────────────────────────────────────────

test "Event: deinit frees all owned strings" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    // Test message_received event
    var msg = Event{
        .message_received = .{
            .from = try allocator.dupe(u8, "test.near"),
            .message_type = try allocator.dupe(u8, "text"),
            .content = try allocator.dupe(u8, "Hello, world!"),
        },
    };
    msg.deinit(allocator);

    // Test peer_connected event
    var peer_conn = Event{
        .peer_connected = try allocator.dupe(u8, "peer123"),
    };
    peer_conn.deinit(allocator);

    // Test peer_disconnected event
    var peer_disconn = Event{
        .peer_disconnected = try allocator.dupe(u8, "peer456"),
    };
    peer_disconn.deinit(allocator);

    // Test daemon_error event
    var daemon_err = Event{
        .daemon_error = try allocator.dupe(u8, "Connection failed"),
    };
    daemon_err.deinit(allocator);
}

// ── Config Tests ───────────────────────────────────────────────────────

test "Config: validation catches invalid configs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    // Empty binary path should fail
    var config1 = Config{ .binary_path = "" };
    const result1 = config1.validate();
    try std.testing.expectError(error.BinaryPathEmpty, result1);

    // Queue size too large should fail
    var config2 = Config{ .max_message_queue_size = 20000 };
    const result2 = config2.validate();
    try std.testing.expectError(error.QueueSizeTooLarge, result2);

    // Poll interval too short should fail
    var config3 = Config{ .poll_interval_secs = 1 };
    const result3 = config3.validate();
    try std.testing.expectError(error.PollIntervalTooShort, result3);
}

// ── Callback Tests ─────────────────────────────────────────────────────

test "Hybrid: event callback properly cleans up events" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = Config{};
    var hybrid = try Hybrid.init(allocator, config, countingCallback);
    hybrid.start() catch {};
    hybrid.stop();
}

// ── Helper Functions ───────────────────────────────────────────────────

fn dummyCallback(allocator: std.mem.Allocator, event: Event) void {
    defer event.deinit(allocator);
}

fn countingCallback(allocator: std.mem.Allocator, event: Event) void {
    defer event.deinit(allocator);

    // Count different event types (just to verify callback is called)
    switch (event) {
        .state_changed => |state| {
            std.log.debug("State changed to: {}", .{state});
        },
        .daemon_started => {
            std.log.debug("Daemon started", .{});
        },
        .daemon_stopped => {
            std.log.debug("Daemon stopped", .{});
        },
        else => {},
    }
}
