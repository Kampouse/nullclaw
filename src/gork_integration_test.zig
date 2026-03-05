//! Integration tests for Gork P2P agent collaboration system.
//!
//! These tests require a real gork-agent binary and test actual P2P functionality.
//! Run with: zig build test
//! Skip with: SKIP_INTEGRATION_TESTS=1 zig build test

const std = @import("std");

const gork = @import("./gork_hybrid.zig");
const Hybrid = gork.Hybrid;
const Config = gork.Config;
const Event = gork.Event;

// ── Binary Detection Tests ─────────────────────────────────────────────

test "Integration: detect if gork-agent binary exists" {
    const skip = std.process.getEnvVarOwned(std.heap.page_allocator, "SKIP_INTEGRATION_TESTS") catch null;
    if (skip != null) {
        skip.?.deinit();
        return error.SkipZigTest;
    }

    const binary_path = "/usr/local/bin/gork-agent";
    std.fs.accessAbsolute(binary_path, .{}) catch |err| {
        std.log.warn("gork-agent binary not found at {s}: {} - skipping integration tests", .{binary_path, err});
        return error.SkipZigTest;
    };
}

// ── Lifecycle Tests ────────────────────────────────────────────────────

test "Integration: start and stop with real binary" {
    const skip = std.process.getEnvVarOwned(std.heap.page_allocator, "SKIP_INTEGRATION_TESTS") catch null;
    if (skip != null) {
        skip.?.deinit();
        return error.SkipZigTest;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = Config{
        .binary_path = "/usr/local/bin/gork-agent",
        .account_id = "test.testnet",
    };

    var hybrid = try Hybrid.init(allocator, config, eventCallback);
    try hybrid.start();

    // Wait for startup
    // std.Thread.sleep() - TODO: Fix for Zig 0.16

    hybrid.stop();
}

test "Integration: multiple start/stop cycles" {
    const skip = std.process.getEnvVarOwned(std.heap.page_allocator, "SKIP_INTEGRATION_TESTS") catch null;
    if (skip != null) {
        skip.?.deinit();
        return error.SkipZigTest;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = Config{
        .binary_path = "/usr/local/bin/gork-agent",
        .account_id = "test.testnet",
    };

    // Test 3 cycles
    for (0..3) |i| {
        var hybrid = try Hybrid.init(allocator, config, eventCallback);
        try hybrid.start();
        // std.Thread.sleep() - TODO: Fix for Zig 0.16
        hybrid.stop();

        std.log.debug("Integration cycle {} complete", .{i});
    }
}

// ── Messaging Tests ─────────────────────────────────────────────────────

test "Integration: send message to real daemon" {
    const skip = std.process.getEnvVarOwned(std.heap.page_allocator, "SKIP_INTEGRATION_TESTS") catch null;
    if (skip != null) {
        skip.?.deinit();
        return error.SkipZigTest;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = Config{
        .binary_path = "/usr/local/bin/gork-agent",
        .account_id = "test.testnet",
    };

    var hybrid = try Hybrid.init(allocator, config, eventCallback);
    try hybrid.start();
    defer hybrid.stop();

    // Wait for daemon to be ready
    // std.Thread.sleep() - TODO: Fix for Zig 0.16

    // Try sending a message (will fail if no peers, but shouldn't crash)
    const result = hybrid.sendMessage("test.near", "integration test message");

    // We expect this to fail (no peers), but it should be a proper error
    if (result) |_| {
        std.log.info("Message sent successfully (unexpected but OK)", .{});
    } else |err| {
        std.log.info("Message send failed as expected: {}", .{err});
        // Should not be DaemonNotRunning
        try std.testing.expect(err != error.DaemonNotRunning);
    }
}

test "Integration: send multiple messages" {
    const skip = std.process.getEnvVarOwned(std.heap.page_allocator, "SKIP_INTEGRATION_TESTS") catch null;
    if (skip != null) {
        skip.?.deinit();
        return error.SkipZigTest;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = Config{
        .binary_path = "/usr/local/bin/gork-agent",
        .account_id = "test.testnet",
        .enable_rate_limiting = false, // Disable for testing
    };

    var hybrid = try Hybrid.init(allocator, config, eventCallback);
    try hybrid.start();
    defer hybrid.stop();

    // std.Thread.sleep() - TODO: Fix for Zig 0.16

    // Send 10 messages
    for (0..10) |i| {
        const msg = try std.fmt.allocPrint(allocator, "test message {}", .{i});
        defer allocator.free(msg);

        _ = hybrid.sendMessage("test.near", msg) catch {};
    }

    // Verify metrics
    const sent = hybrid.metrics.messages_sent.load(.seq_cst);
    const failed = hybrid.metrics.messages_failed.load(.seq_cst);

    std.log.info("Messages: sent={}, failed={}", .{sent, failed});
    try std.testing.expect(sent + failed == 10);
}

// ── Error Handling Tests ────────────────────────────────────────────────

test "Integration: validation errors with real daemon" {
    const skip = std.process.getEnvVarOwned(std.heap.page_allocator, "SKIP_INTEGRATION_TESTS") catch null;
    if (skip != null) {
        skip.?.deinit();
        return error.SkipZigTest;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = Config{
        .binary_path = "/usr/local/bin/gork-agent",
        .account_id = "test.testnet",
    };

    var hybrid = try Hybrid.init(allocator, config, eventCallback);
    try hybrid.start();
    defer hybrid.stop();

    // std.Thread.sleep() - TODO: Fix for Zig 0.16

    // Invalid agent ID
    const result1 = hybrid.sendMessage("invalid@agent!", "test");
    try std.testing.expectError(error.InvalidAgentId, result1);

    // Message too long
    const long_msg = "x" ** (gork.MAX_MESSAGE_LEN + 1);
    const result2 = hybrid.sendMessage("test.near", long_msg);
    try std.testing.expectError(error.MessageTooLong, result2);

    // Empty agent ID
    const result3 = hybrid.sendMessage("", "test");
    try std.testing.expectError(error.AgentIdEmpty, result3);
}

// ── Metrics Tests ───────────────────────────────────────────────────────

test "Integration: metrics collection" {
    const skip = std.process.getEnvVarOwned(std.heap.page_allocator, "SKIP_INTEGRATION_TESTS") catch null;
    if (skip != null) {
        skip.?.deinit();
        return error.SkipZigTest;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = Config{
        .binary_path = "/usr/local/bin/gork-agent",
        .account_id = "test.testnet",
        .enable_rate_limiting = false,
    };

    var hybrid = try Hybrid.init(allocator, config, eventCallback);
    try hybrid.start();
    defer hybrid.stop();

    // std.Thread.sleep() - TODO: Fix for Zig 0.16

    // Send some messages
    for (0..5) |_| {
        _ = hybrid.sendMessage("test.near", "test") catch {};
    }

    // Get metrics JSON
    const metrics_json = try hybrid.metrics.toJson(allocator);
    defer allocator.free(metrics_json);

    std.log.info("Metrics: {s}", .{metrics_json});

    // Verify metrics contain expected fields
    try std.testing.expect(std.mem.indexOf(u8, metrics_json, "messages_sent") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics_json, "avg_latency_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics_json, "cache_hit_rate") != null);
}

// ── Stress Tests ────────────────────────────────────────────────────────

test "Integration: stress test with concurrent sends" {
    const skip = std.process.getEnvVarOwned(std.heap.page_allocator, "SKIP_INTEGRATION_TESTS") catch null;
    if (skip != null) {
        skip.?.deinit();
        return error.SkipZigTest;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = Config{
        .binary_path = "/usr/local/bin/gork-agent",
        .account_id = "test.testnet",
        .enable_rate_limiting = false,
        .circuit_breaker_threshold = 100, // High threshold for stress test
    };

    var hybrid = try Hybrid.init(allocator, config, eventCallback);
    try hybrid.start();
    defer hybrid.stop();

    // std.Thread.sleep() - TODO: Fix for Zig 0.16

    // Spawn multiple threads sending messages
    const num_threads = 5;
    const messages_per_thread = 20;

    var threads: [num_threads]std.Thread = undefined;
    var errors: [num_threads]anyerror = [_]anyerror{error.Success} ** num_threads;

    for (0..num_threads) |i| {
        const ctx = try allocator.create(struct {
            hybrid: *Hybrid,
            thread_id: usize,
            error_ptr: *anyerror,
        });
        ctx.* = .{
            .hybrid = &hybrid,
            .thread_id = i,
            .error_ptr = &errors[i],
        };

        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(ctx_ptr: *const @TypeOf(ctx.*)) void {
                for (0..messages_per_thread) |j| {
                    const msg = std.fmt.allocPrint(ctx_ptr.hybrid.allocator, "thread {} msg {}", .{ctx_ptr.thread_id, j}) catch {
                        ctx_ptr.error_ptr.* = error.OutOfMemory;
                        return;
                    };
                    defer ctx_ptr.hybrid.allocator.free(msg);

                    _ = ctx_ptr.hybrid.sendMessage("test.near", msg) catch {};
                }
            }
        }.run, .{ctx});
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Check for errors
    for (errors) |err| {
        try std.testing.expect(err == error.Success);
    }

    // Verify metrics
    const total_attempts = num_threads * messages_per_thread;
    const sent = hybrid.metrics.messages_sent.load(.seq_cst);
    const failed = hybrid.metrics.messages_failed.load(.seq_cst);

    std.log.info("Stress test: {} attempts, {} sent, {} failed", .{total_attempts, sent, failed});
    try std.testing.expect(sent + failed == total_attempts);
}

// ── Helper Functions ───────────────────────────────────────────────────

fn eventCallback(allocator: std.mem.Allocator, event: Event) void {
    defer event.deinit(allocator);

    switch (event) {
        .state_changed => |state| {
            std.log.info("State changed: {}", .{state});
        },
        .daemon_started => |info| {
            std.log.info("Daemon started: peer_id={s}, port={}", .{info.peer_id, info.port});
        },
        .daemon_stopped => |reason| {
            if (reason) |r| {
                std.log.info("Daemon stopped: {s}", .{r});
            } else {
                std.log.info("Daemon stopped cleanly", .{});
            }
        },
        .message_received => |msg| {
            std.log.info("Message from {s}: {s}", .{msg.from, msg.content});
        },
        else => {},
    }
}
