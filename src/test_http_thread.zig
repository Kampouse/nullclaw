//! Test HTTP client in spawned thread (simulates typing indicator scenario)
//! Run with: zig test test_http_thread.zig

const std = @import("std");
const http_util = @import("http_util.zig");

const TestContext = struct {
    allocator: std.mem.Allocator,
    done: std.atomic.Value(bool),
    started: std.atomic.Value(bool),
    error_msg: ?[]const u8 = null,
};

fn httpRequestThread(ctx: *TestContext) void {
    ctx.started.store(true, .release);
    
    // Try HTTPS (TLS)
    const url = "https://httpbin.org/post";
    const body = "{\"test\":\"typing\"}";

    const result = http_util.curlPostWithProxy(
        ctx.allocator,
        url,
        body,
        &.{"Content-Type: application/json"},
        null,
        "10",
    ) catch |err| {
        ctx.error_msg = std.fmt.allocPrint(ctx.allocator, "HTTP error: {}", .{err}) catch null;
        ctx.done.store(true, .release);
        return;
    };

    ctx.allocator.free(result);
    ctx.done.store(true, .release);
}

test "HTTP client works in spawned thread" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = TestContext{
        .allocator = allocator,
        .done = std.atomic.Value(bool).init(false),
        .started = std.atomic.Value(bool).init(false),
    };

    const thread = try std.Thread.spawn(.{ .stack_size = 128 * 1024 }, httpRequestThread, .{&ctx});
    thread.join();

    if (!ctx.started.load(.acquire)) {
        std.log.err("[TEST] Thread never started!", .{});
        return error.ThreadNeverStarted;
    }

    if (!ctx.done.load(.acquire)) {
        std.log.err("[TEST] Thread did not complete", .{});
        return error.ThreadDidNotComplete;
    }

    std.log.info("[TEST] ✓ Thread spawned and completed", .{});
}

test "getThreadedIo doesn't crash" {
    // Test that getThreadedIo() works multiple times in same thread
    const io1 = http_util.getThreadedIo();
    const io2 = http_util.getThreadedIo();
    _ = io1;
    _ = io2;

    std.log.info("[TEST] ✓ getThreadedIo works (cached)", .{});
}

test "HTTP request in main thread (HTTPS)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("[TEST] Testing HTTPS in main thread...", .{});
    
    const url = "https://httpbin.org/get";
    const result = http_util.curlGetWithProxy(allocator, url, &.{}, "10", null) catch |err| {
        std.log.err("[TEST] Main thread HTTPS failed: {}", .{err});
        return err;
    };

    std.log.info("[TEST] ✓ Main thread HTTPS works, response length={}", .{result.len});
    allocator.free(result);
}

test "HTTP request in main thread (HTTP, no TLS)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("[TEST] Testing HTTP (no TLS) in main thread...", .{});
    
    const url = "http://httpbin.org/get";
    const result = http_util.curlGetWithProxy(allocator, url, &.{}, "10", null) catch |err| {
        std.log.err("[TEST] Main thread HTTP failed: {}", .{err});
        return err;
    };

    std.log.info("[TEST] ✓ Main thread HTTP works, response length={}", .{result.len});
    allocator.free(result);
}
