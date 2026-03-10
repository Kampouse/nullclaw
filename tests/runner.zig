//! Simple compile-time test runner
//!
//! Usage:
//!   zig test tests/runner.zig -Dtest-module=memory/engines/markdown
//!
//! Or run all tests:
//!   zig test tests/runner.zig

const std = @import("std");

const builtin = @import("builtin");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Get test module from command line or run all
    const test_module = std.os.getenv("TEST_MODULE");

    if (test_module) |module| {
        try runSingleTest(allocator, module);
    } else {
        try runAllTests(allocator);
    }
}

fn runSingleTest(allocator: std.mem.Allocator, module: []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    stdout.print("Running test module: {s}\n", .{module}) catch return;

    const result = try runZigTest(allocator, module);
    defer allocator.free(result.output);

    stdout.print("  Result: {s}\n", .{if (result.passed) "✅ PASS" else "❌ FAIL"}) catch return;
    if (result.leak_count > 0) {
        stdout.print("  Leaks: {d}\n", .{result.leak_count}) catch return;
    }
    if (result.duration_ms > 0) {
        stdout.print("  Duration: {d}ms\n", .{result.duration_ms}) catch return;
    }

    if (!result.passed) {
        stdout.print("\nOutput:\n{s}\n", .{result.output}) catch return;
        std.process.exit(1);
    }
}

fn runAllTests(allocator: std.mem.Allocator) !void {
    const modules = [_][]const u8{
        "memory/engines/markdown",
        "memory/engines/contract_test",
        "agent/root",
        "agent/prompt",
        "tools/shell",
        "tools/memory",
        "providers/helpers",
        "test_isolation",
    };

    var passed: usize = 0;
    var failed: usize = 0;

    const stdout = std.io.getStdOut().writer();

    for (modules) |module| {
        stdout.print("Testing {s}... ", .{module}) catch return;

        const result = try runZigTest(allocator, module);
        defer allocator.free(result.output);

        if (result.passed) {
            stdout.print("✅\n", .{}) catch return;
            passed += 1;
        } else {
            stdout.print("❌\n", .{}) catch return;
            failed += 1;
        }
    }

    stdout.print(
        \\
        \\========================================
        \\Results: {d} passed, {d} failed
        \\========================================
        \\
    , .{ passed, failed }) catch return;

    if (failed > 0) {
        std.process.exit(1);
    }
}

const TestResult = struct {
    passed: bool,
    leak_count: usize,
    duration_ms: u64,
    output: []const u8,
};

fn runZigTest(allocator: std.mem.Allocator, module: []const u8) !TestResult {
    const start_time = std.time.nanoTimestamp();

    // Build command
    const zig_exe = std.os.getenv("ZIG") orelse "zig";

    const args = [_][]const u8{
        zig_exe,
        "build",
        "test",
        "-Dtest-file=" ++ module,
        "--summary",
        "all",
    };

    var result = std.process.Child.run(
        &args,
        .{ .allocator = allocator, .cwd = null },
    ) catch |err| {
        return TestResult{
            .passed = false,
            .leak_count = 0,
            .duration_ms = 0,
            .output = try allocator.dupe(u8, @errorName(err)),
        };
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ms = @as(u64, @intCast((end_time - start_time) / 1_000_000));

    // Combine output
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    try output.appendSlice(result.stdout);
    try output.appendSlice(result.stderr);
    const output_str = try output.toOwnedSlice();

    // Check for leaks
    var leak_count: usize = 0;
    var iter = std.mem.splitScalar(u8, output_str, '\n');
    while (iter.next()) |line| {
        if (std.mem.indexOf(u8, line, "leaked")) |_| {
            leak_count += 1;
        }
    }

    // Check if passed
    const passed = result.term == .Exited and
        result.term.Exited == 0 and
        leak_count == 0;

    return TestResult{
        .passed = passed,
        .leak_count = leak_count,
        .duration_ms = duration_ms,
        .output = output_str,
    };
}

// ── Compile-time Tests ────────────────────────────────────────────────

test "compile-time: markdown memory has no leaks" {
    const result = try runZigTest(std.testing.allocator, "memory/engines/markdown");
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 0), result.leak_count);
}

test "compile-time: agent/root has no leaks" {
    const result = try runZigTest(std.testing.allocator, "agent/root");
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 0), result.leak_count);
}

test "compile-time: critical modules pass" {
    const critical_modules = [_][]const u8{
        "memory/engines/markdown",
        "agent/root",
        "tools/shell",
    };

    for (critical_modules) |module| {
        const result = try runZigTest(std.testing.allocator, module);
        defer std.testing.allocator.free(result.output);

        try std.testing.expect(result.passed);
        try std.testing.expectEqual(@as(usize, 0), result.leak_count);
    }
}
