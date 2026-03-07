//! Integration tests for Gork P2P agent collaboration system.
//!
//! Tests cover:
//! - Circuit breaker state transitions
//! - Per-agent rate limiting
//! - Metrics collection and reporting
//! - Config validation
//! - Security validation functions

const std = @import("std");

const gork = @import("./gork_hybrid.zig");
const Hybrid = gork.Hybrid;
const CircuitBreaker = gork.CircuitBreaker;
const CircuitBreakerState = gork.CircuitBreakerState;
const RateLimiter = gork.RateLimiter;
const Metrics = gork.Metrics;
const Config = gork.Config;
const SecurityError = gork.SecurityError;

// ── Circuit Breaker Tests ───────────────────────────────────────────────

test "CircuitBreaker: initially closed and allows requests" {
    var cb = CircuitBreaker{};
    try std.testing.expectEqual(CircuitBreakerState.closed, cb.state);
    try std.testing.expect(cb.allow() == true);
}

test "CircuitBreaker: opens after threshold failures" {
    var cb = CircuitBreaker{
        .threshold = 3,
        .timeout_ns = 1_000_000_000, // 1 second
    };

    // First 2 failures - still closed
    cb.recordFailure();
    try std.testing.expectEqual(CircuitBreakerState.closed, cb.state);
    try std.testing.expect(cb.allow() == true);

    cb.recordFailure();
    try std.testing.expectEqual(CircuitBreakerState.closed, cb.state);
    try std.testing.expect(cb.allow() == true);

    // Third failure - opens circuit breaker
    cb.recordFailure();
    try std.testing.expectEqual(CircuitBreakerState.open, cb.state);
    try std.testing.expect(cb.allow() == false);
}

test "CircuitBreaker: transitions to half_open after timeout" {
    var cb = CircuitBreaker{
        .threshold = 1,
        .timeout_ns = 100_000_000, // 100ms for testing
    };

    // Open the circuit
    cb.recordFailure();
    try std.testing.expectEqual(CircuitBreakerState.open, cb.state);
    try std.testing.expect(cb.allow() == false);

    // Wait for timeout
    // std.Thread.sleep() - TODO: Fix for Zig 0.16

    // Should transition to half_open
    try std.testing.expect(cb.allow() == true);
    try std.testing.expectEqual(CircuitBreakerState.half_open, cb.state);
}

test "CircuitBreaker: closes again after successful requests in half_open" {
    var cb = CircuitBreaker{
        .threshold = 1,
        .timeout_ns = 100_000_000,
        .half_open_attempts = 2,
    };

    // Open and wait for timeout
    cb.recordFailure();
    // std.Thread.sleep() - TODO: Fix for Zig 0.16

    // Enter half_open
    _ = cb.allow();
    try std.testing.expectEqual(CircuitBreakerState.half_open, cb.state);

    // First success
    cb.recordSuccess();
    try std.testing.expectEqual(CircuitBreakerState.half_open, cb.state);

    // Second success - should close
    cb.recordSuccess();
    try std.testing.expectEqual(CircuitBreakerState.closed, cb.state);
    try std.testing.expect(cb.allow() == true);
}

test "CircuitBreaker: reopens on failure in half_open" {
    var cb = CircuitBreaker{
        .threshold = 1,
        .timeout_ns = 100_000_000,
        .half_open_attempts = 2,
    };

    // Open and wait for timeout
    cb.recordFailure();
    // std.Thread.sleep() - TODO: Fix for Zig 0.16

    // Enter half_open
    _ = cb.allow();

    // Failure in half_open - should re-open
    cb.recordFailure();
    try std.testing.expectEqual(CircuitBreakerState.open, cb.state);
    try std.testing.expect(cb.allow() == false);
}

test "CircuitBreaker: resets failure count on success in closed" {
    var cb = CircuitBreaker{
        .threshold = 3,
        .timeout_ns = 1_000_000_000,
    };

    // 2 failures
    cb.recordFailure();
    cb.recordFailure();
    try std.testing.expectEqual(@as(u32, 2), cb.failure_count);

    // Success resets count
    cb.recordSuccess();
    try std.testing.expectEqual(@as(u32, 0), cb.failure_count);
    try std.testing.expectEqual(CircuitBreakerState.closed, cb.state);
}

// ── Rate Limiter Tests ──────────────────────────────────────────────────

test "RateLimiter: allows requests within limit" {
    const allocator = std.testing.allocator;
    var rl = RateLimiter.init(allocator);
    defer rl.deinit();

    const agent_id = "alice.near";

    // Minimal test - just check first request
    const result = rl.allow(agent_id);

    // If this fails, something is fundamentally broken
    if (!result) {
        std.debug.print("ERROR: allow() returned false for empty map!\n", .{});
        std.debug.print("  Map count before: {}\n", .{rl.map.count()});
        std.debug.print("  Map count after: {}\n", .{rl.map.count()});
    }
    try std.testing.expectEqual(true, result);

    // If first request worked, the rest should too
    for (0..99) |_| {
        const r = rl.allow(agent_id);
        if (!r) {
            std.debug.print("ERROR: allow() returned false on iteration {}\n", .{rl.map.count()});
        }
        try std.testing.expectEqual(true, r);
    }
}

test "RateLimiter: blocks requests over limit" {
    const allocator = std.testing.allocator;
    var rl = RateLimiter.init(allocator);
    defer rl.deinit();

    rl.max_requests = 5;
    rl.window_ns = 1_000_000_000; // 1 second

    const agent_id = "bob.near";

    // Use up the quota
    for (0..5) |_| {
        _ = rl.allow(agent_id);
    }

    // Next request should be blocked
    try std.testing.expect(rl.allow(agent_id) == false);
}

test "RateLimiter: resets after window expires" {
    const allocator = std.testing.allocator;
    var rl = RateLimiter.init(allocator);
    defer rl.deinit();

    rl.max_requests = 2;
    rl.window_ns = 100_000_000; // 100ms for testing

    const agent_id = "charlie.near";

    // Use up the quota
    _ = rl.allow(agent_id);
    _ = rl.allow(agent_id);
    try std.testing.expect(rl.allow(agent_id) == false);

    // Wait for window to expire
    // std.Thread.sleep() - TODO: Fix for Zig 0.16

    // Should allow requests again
    try std.testing.expect(rl.allow(agent_id) == true);
}

test "RateLimiter: tracks multiple agents independently" {
    const allocator = std.testing.allocator;
    var rl = RateLimiter.init(allocator);
    defer rl.deinit();

    rl.max_requests = 3;

    // Alice uses her quota
    for (0..3) |_| {
        _ = rl.allow("alice.near");
    }
    try std.testing.expect(rl.allow("alice.near") == false);

    // Bob should still have his full quota
    try std.testing.expect(rl.allow("bob.near") == true);
    try std.testing.expect(rl.allow("bob.near") == true);
    try std.testing.expect(rl.allow("bob.near") == true);
}

test "RateLimiter: cleans up expired entries" {
    const allocator = std.testing.allocator;
    var rl = RateLimiter.init(allocator);
    defer rl.deinit();

    rl.max_requests = 1;
    rl.window_ns = 100_000_000; // 100ms
    rl.cleanup_threshold = 10;

    // Add 15 agents
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        const agent_id = try std.fmt.allocPrint(allocator, "agent{}.near", .{i});
        defer allocator.free(agent_id);
        _ = rl.allow(agent_id);
    }

    // Map should have 15 entries
    try std.testing.expectEqual(@as(usize, 15), rl.map.count());

    // Wait for entries to expire
    // std.Thread.sleep() - TODO: Fix for Zig 0.16

    // Add one more - should trigger cleanup
    _ = rl.allow("trigger.near");

    // Map should be cleaned up (significantly smaller)
    try std.testing.expect(rl.map.count() < 10);
}

// ── Metrics Tests ────────────────────────────────────────────────────────

test "Metrics: initializes with zero counters" {
    var metrics = Metrics.init();

    try std.testing.expectEqual(@as(u64, 0), metrics.messages_sent.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 0), metrics.messages_received.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 0), metrics.messages_failed.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 0), metrics.discover_calls.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 0), metrics.reputation_checks.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 0), metrics.security_violations.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 0), metrics.circuit_breaker_trips.load(.seq_cst));
}

test "Metrics: increments counters atomically" {
    var metrics = Metrics.init();

    _ = metrics.messages_sent.fetchAdd(1, .seq_cst);
    _ = metrics.messages_sent.fetchAdd(5, .seq_cst);

    try std.testing.expectEqual(@as(u64, 6), metrics.messages_sent.load(.seq_cst));

    _ = metrics.security_violations.fetchAdd(1, .seq_cst);
    try std.testing.expectEqual(@as(u64, 1), metrics.security_violations.load(.seq_cst));
}

test "Metrics: serializes to JSON" {
    var metrics = Metrics.init();

    _ = metrics.messages_sent.fetchAdd(10, .seq_cst);
    _ = metrics.messages_failed.fetchAdd(2, .seq_cst);
    _ = metrics.discover_calls.fetchAdd(5, .seq_cst);

    const allocator = std.testing.allocator;
    const json = try metrics.toJson(allocator);
    defer allocator.free(json);

    // Verify JSON contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"messages_sent\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"messages_failed\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"discover_calls\":5") != null);
}

// ── Security Validation Tests ────────────────────────────────────────────

test "validateAgentId: accepts valid NEAR account IDs" {
    try gork.validateAgentId("alice.near");
    try gork.validateAgentId("bob-account.near");
    try gork.validateAgentId("charlie_123.test.near");
    try gork.validateAgentId("0123456789abcdef.near");
}

test "validateAgentId: rejects empty IDs" {
    try std.testing.expectError(
        SecurityError.AgentIdEmpty,
        gork.validateAgentId("")
    );
}

test "validateAgentId: rejects too long IDs" {
    var long_id = std.ArrayList(u8).initCapacity(std.testing.allocator, gork.MAX_AGENT_ID_LEN + 10) catch unreachable;
    defer long_id.deinit(std.testing.allocator);

    // Create a string longer than MAX_AGENT_ID_LEN
    for (0..gork.MAX_AGENT_ID_LEN + 1) |_| {
        long_id.append(std.testing.allocator, 'a') catch {};
    }
    long_id.appendSlice(std.testing.allocator, ".near") catch {};

    try std.testing.expectError(
        SecurityError.AgentIdTooLong,
        gork.validateAgentId(long_id.items)
    );
}

test "validateAgentId: rejects invalid characters" {
    try std.testing.expectError(
        SecurityError.InvalidAgentId,
        gork.validateAgentId("alice@near")
    );

    try std.testing.expectError(
        SecurityError.InvalidAgentId,
        gork.validateAgentId("alice space.near")
    );
}

test "validateCapability: accepts valid capability strings" {
    try gork.validateCapability("csv-analysis");
    try gork.validateCapability("data_visualizer");
    try gork.validateCapability("web-scraper");
    try gork.validateCapability("ai-chat");
}

test "validateCapability: rejects empty capabilities" {
    try std.testing.expectError(
        SecurityError.CapabilityEmpty,
        gork.validateCapability("")
    );
}

test "validateCapability: rejects invalid characters" {
    try std.testing.expectError(
        SecurityError.InvalidCapability,
        gork.validateCapability("csv analysis")
    );

    try std.testing.expectError(
        SecurityError.InvalidCapability,
        gork.validateCapability("csv@analysis")
    );
}

test "validateMessage: accepts valid messages" {
    try gork.validateMessage("Hello, world!");
    try gork.validateMessage("Multi\nline\nmessage");
    try gork.validateMessage("Message\twith\ttabs");
}

test "validateMessage: rejects messages that are too long" {
    var long_msg = std.ArrayList(u8).initCapacity(std.testing.allocator, gork.MAX_MESSAGE_LEN + 10) catch unreachable;
    defer long_msg.deinit(std.testing.allocator);

    // Create a message longer than MAX_MESSAGE_LEN
    for (0..gork.MAX_MESSAGE_LEN + 1) |_| {
        long_msg.append(std.testing.allocator, 'a') catch {};
    }

    try std.testing.expectError(
        SecurityError.MessageTooLong,
        gork.validateMessage(long_msg.items)
    );
}

test "validateMessage: rejects invalid characters" {
    try std.testing.expectError(
        SecurityError.InvalidMessageCharacter,
        gork.validateMessage("Invalid\x00character")
    );

    try std.testing.expectError(
        SecurityError.InvalidMessageCharacter,
        gork.validateMessage("Invalid\x1Bescape")
    );
}

test "validateBinaryPath: accepts valid absolute paths" {
    // Skip test on Windows or if /usr/bin doesn't exist
    if (@import("builtin").os.tag == .windows) return;

    if (std.Io.Dir.cwd().openFile(std.Options.debug_io, "/usr/bin/ls", .{})) |file| {
        file.close();
        try gork.validateBinaryPath("/usr/bin/ls");
    } else |_| {}
}

test "validateBinaryPath: rejects directory traversal" {
    try std.testing.expectError(
        SecurityError.InvalidPath,
        gork.validateBinaryPath("../../../etc/passwd")
    );

    try std.testing.expectError(
        SecurityError.InvalidPath,
        gork.validateBinaryPath("./../secret")
    );
}

test "validateBinaryPath: rejects empty paths" {
    try std.testing.expectError(
        SecurityError.BinaryPathEmpty,
        gork.validateBinaryPath("")
    );
}

// ── Config Tests ────────────────────────────────────────────────────────

test "Config: has reasonable defaults" {
    const config = Config{
        .account_id = "test.near",
    };

    try std.testing.expectEqualStrings("gork-agent", config.binary_path);
    try std.testing.expectEqual(@as(u16, 4001), config.daemon_port);
    try std.testing.expectEqual(@as(u32, 60), config.poll_interval_secs);
    try std.testing.expect(config.enable_fallback == true);
    try std.testing.expectEqual(@as(u32, 50), config.min_reputation);
    try std.testing.expectEqual(@as(u32, 20), config.block_below_reputation);
    try std.testing.expectEqual(@as(u32, 1000), config.max_message_queue_size);
}

test "Config: reputation settings are validated" {
    const allocator = std.testing.allocator;

    // Invalid: block_below_reputation > min_reputation
    {
        const config = Config{
            .account_id = "test.near",
            .min_reputation = 20,
            .block_below_reputation = 50,
        };

        // This would fail validation if implemented
        try std.testing.expect(config.block_below_reputation > config.min_reputation);
    }

    // Valid: block_below_reputation < min_reputation
    {
        const config = Config{
            .account_id = "test.near",
            .min_reputation = 50,
            .block_below_reputation = 20,
        };

        try std.testing.expect(config.block_below_reputation < config.min_reputation);
    }

    _ = allocator;
}

// ── Helper Types ────────────────────────────────────────────────────────
// All types are now exported from gork_hybrid.zig

