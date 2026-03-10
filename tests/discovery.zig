//! Simple test module list for nullclaw
//!
//! This provides a centralized list of test modules that can be
//! automatically discovered and tested.

const std = @import("std");
const io = std.Options.debug_io;

/// List of all test modules in the codebase
/// TODO: Make this truly automatic by scanning filesystem
pub const ALL_TEST_MODULES = [_][]const u8{
    // Agent modules
    "agent/prompt",
    "agent/root",
    "agent/dispatcher",
    "agent/compaction",
    "agent/routing",

    // Channel modules
    "channels/cli",
    "channels/telegram",
    "channels/discord",
    "channels/slack",
    "channels/signal",
    "channels/matrix",
    "channels/email",
    "channels/irc",

    // Memory modules
    "memory/engines",
    "memory/engines/contract_test",
    "memory/engines/markdown",
    "memory/engines/sqlite",
    "memory/lifecycle",
    "memory/lifecycle/cache",
    "memory/lifecycle/hygiene",
    "memory/lifecycle/snapshot",
    "memory/retrieval",
    "memory/vector",

    // Provider modules
    "providers/anthropic",
    "providers/openai",
    "providers/gemini",
    "providers/ollama",
    "providers/factory",
    "providers/helpers",

    // Security modules
    "security/policy",
    "security/pairing",
    "security/secrets",
    "security/tracker",

    // Tool modules
    "tools/shell",
    "tools/file_append",
    "tools/memory",
    "tools/browser",
    "tools/cron",
    "tools/web_fetch",
    "tools/web_search",

    // Infrastructure
    "test_isolation",
};

/// Run all test modules and check for memory leaks
pub fn testAllModules(allocator: std.mem.Allocator) !TestSummary {
    var summary = TestSummary{
        .total = ALL_TEST_MODULES.len,
        .passed = 0,
        .failed = 0,
        .leaks = 0,
    };

    for (ALL_TEST_MODULES) |module| {
        const result = try runModuleTest(allocator, module);
        defer allocator.free(result.output);

        if (result.passed) {
            summary.passed += 1;
        } else {
            summary.failed += 1;
            if (result.leak_count > 0) {
                summary.leaks += 1;
            }
        }
    }

    return summary;
}

pub const TestSummary = struct {
    total: usize,
    passed: usize,
    failed: usize,
    leaks: usize,
};

const ModuleTestResult = struct {
    passed: bool,
    leak_count: usize,
    output: []const u8,
};

fn runModuleTest(allocator: std.mem.Allocator, module: []const u8) !ModuleTestResult {
    const zig_exe = "zig";

    // Build arguments array
    const test_file_arg = try std.fmt.allocPrint(allocator, "-Dtest-file={s}", .{module});
    defer allocator.free(test_file_arg);

    const args = [_][]const u8{
        zig_exe,
        "build",
        "test",
        test_file_arg,
        "--summary",
        "all",
    };

    // Run the command
    var child = std.process.Child.init(&args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    const child_pid = try child.spawn();
    defer _ = child.kill() catch {};

    // Read output
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);

    const term = try child.wait();

    // Combine output
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    try output.appendSlice(stdout);
    try output.appendSlice(stderr);
    const output_str = try output.toOwnedSlice();

    // Check for leaks
    var leak_count: usize = 0;
    var iter = std.mem.splitScalar(u8, output_str, '\n');
    while (iter.next()) |line| {
        if (std.mem.indexOf(u8, line, "leaked")) |_| {
            leak_count += 1;
        }
    }

    const passed = term == .Exited and term.Exited == 0 and leak_count == 0;

    return ModuleTestResult{
        .passed = passed,
        .leak_count = leak_count,
        .output = output_str,
    };
}

// ── Tests ────────────────────────────────────────────────────────────

test "test all modules and report" {
    const summary = try testAllModules(std.testing.allocator);

    std.debug.print(
        \\
        \\========================================
        \\Summary
        \\========================================
        \\Total: {d}
        \\Passed: {d}
        \\Failed: {d}
        \\With Leaks: {d}
        \\
    , .{ summary.total, summary.passed, summary.failed, summary.leaks });

    try std.testing.expect(summary.failed == 0, "All tests should pass");
    try std.testing.expect(summary.leaks == 0, "No memory leaks should exist");
}

test "module list is non-empty" {
    try std.testing.expect(ALL_TEST_MODULES.len > 0);
    try std.testing.expect(ALL_TEST_MODULES.len >= 40); // Should have 40+ modules
}
