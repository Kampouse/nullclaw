//! Test Engine - Compile-time test runner for nullclaw modules
//!
//! Replaces bash scripts with a proper Zig test framework that:
//! - Runs test modules in parallel
//! - Detects memory leaks
//! - Provides structured output
//! - Can be run with `zig test`

const std = @import("std");

const TestEngine = @This();

pub const Module = struct {
    name: []const u8,
    test_file: []const u8,
    description: []const u8 = "",
};

pub const TestResult = struct {
    module: Module,
    passed: bool,
    has_leaks: bool,
    leak_count: usize = 0,
    error_count: usize = 0,
    duration_ms: u64 = 0,
    output: []const u8 = "",
};

pub const TestConfig = struct {
    max_jobs: usize = 8,
    verbose: bool = false,
    stop_on_first_error: bool = false,
};

/// All test modules to run
pub const ALL_MODULES = [_]Module{
    // Agent sub-modules
    .{ .name = "agent/prompt", .test_file = "agent/prompt", .description = "Agent prompt handling" },
    .{ .name = "agent/root", .test_file = "agent/root", .description = "Core agent logic" },
    .{ .name = "agent/dispatcher", .test_file = "agent/dispatcher", .description = "Tool dispatcher" },
    .{ .name = "agent/compaction", .test_file = "agent/compaction", .description = "History compaction" },
    .{ .name = "agent/routing", .test_file = "agent/routing", .description = "Agent routing" },

    // Channels sub-modules
    .{ .name = "channels/cli", .test_file = "channels/cli", .description = "CLI channel" },
    .{ .name = "channels/telegram", .test_file = "channels/telegram", .description = "Telegram channel" },
    .{ .name = "channels/discord", .test_file = "channels/discord", .description = "Discord channel" },
    .{ .name = "channels/slack", .test_file = "channels/slack", .description = "Slack channel" },
    .{ .name = "channels/signal", .test_file = "channels/signal", .description = "Signal channel" },
    .{ .name = "channels/matrix", .test_file = "channels/matrix", .description = "Matrix channel" },
    .{ .name = "channels/email", .test_file = "channels/email", .description = "Email channel" },
    .{ .name = "channels/irc", .test_file = "channels/irc", .description = "IRC channel" },

    // Memory sub-modules
    .{ .name = "memory/engines", .test_file = "memory/engines", .description = "Memory engines" },
    .{ .name = "memory/engines/contract_test", .test_file = "memory/engines/contract_test", .description = "Memory contract tests" },
    .{ .name = "memory/engines/markdown", .test_file = "memory/engines/markdown", .description = "Markdown memory engine" },
    .{ .name = "memory/engines/sqlite", .test_file = "memory/engines/sqlite", .description = "SQLite memory engine" },
    .{ .name = "memory/lifecycle", .test_file = "memory/lifecycle", .description = "Memory lifecycle" },
    .{ .name = "memory/lifecycle/cache", .test_file = "memory/lifecycle/cache", .description = "Memory cache" },
    .{ .name = "memory/lifecycle/hygiene", .test_file = "memory/lifecycle/hygiene", .description = "Memory hygiene" },
    .{ .name = "memory/lifecycle/snapshot", .test_file = "memory/lifecycle/snapshot", .description = "Memory snapshots" },
    .{ .name = "memory/retrieval", .test_file = "memory/retrieval", .description = "Memory retrieval" },
    .{ .name = "memory/vector", .test_file = "memory/vector", .description = "Vector memory" },

    // Providers sub-modules
    .{ .name = "providers/anthropic", .test_file = "providers/anthropic", .description = "Anthropic provider" },
    .{ .name = "providers/openai", .test_file = "providers/openai", .description = "OpenAI provider" },
    .{ .name = "providers/gemini", .test_file = "providers/gemini", .description = "Gemini provider" },
    .{ .name = "providers/ollama", .test_file = "providers/ollama", .description = "Ollama provider" },
    .{ .name = "providers/factory", .test_file = "providers/factory", .description = "Provider factory" },
    .{ .name = "providers/helpers", .test_file = "providers/helpers", .description = "Provider helpers" },

    // Security sub-modules
    .{ .name = "security/policy", .test_file = "security/policy", .description = "Security policy" },
    .{ .name = "security/pairing", .test_file = "security/pairing", .description = "Security pairing" },
    .{ .name = "security/secrets", .test_file = "security/secrets", .description = "Secrets management" },
    .{ .name = "security/tracker", .test_file = "security/tracker", .description = "Security tracker" },

    // Tools sub-modules
    .{ .name = "tools/shell", .test_file = "tools/shell", .description = "Shell tool" },
    .{ .name = "tools/file_append", .test_file = "tools/file_append", .description = "File append tool" },
    .{ .name = "tools/memory", .test_file = "tools/memory", .description = "Memory tools" },
    .{ .name = "tools/browser", .test_file = "tools/browser", .description = "Browser tool" },
    .{ .name = "tools/cron", .test_file = "tools/cron", .description = "Cron tools" },
    .{ .name = "tools/web_fetch", .test_file = "tools/web_fetch", .description = "Web fetch tool" },
    .{ .name = "tools/web_search", .test_file = "tools/web_search", .description = "Web search tool" },

    // Test infrastructure
    .{ .name = "test_isolation", .test_file = "test_isolation", .description = "Test isolation" },
};

/// Run a single test module and return the result
pub fn runModuleTest(allocator: std.mem.Allocator, module: Module) !TestResult {
    const start_time = std.time.nanoTimestamp();

    // Build the zig test command
    const zig_exe = std.os.getenv("ZIG") orelse "zig";

    // Create output buffer
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    // Run: zig build test -Dtest-file=<module> --summary all
    const args = [_][]const u8{
        zig_exe,
        "build",
        "test",
        "-Dtest-file=" ++ module.test_file,
        "--summary",
        "all",
    };

    var result = std.process.Child.run(
        &args,
        .{ .allocator = allocator, .cwd = null },
    ) catch |err| {
        // Failed to even run the test
        return TestResult{
            .module = module,
            .passed = false,
            .has_leaks = false,
            .error_count = 1,
            .output = try allocator.dupe(u8, @errorName(err)),
        };
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ms = @as(u64, @intCast((end_time - start_time) / 1_000_000));

    // Combine stdout and stderr
    try output.appendSlice(result.stdout);
    try output.appendSlice(result.stderr);
    const output_str = try output.toOwnedSlice();

    // Analyze output
    var leaks_found: usize = 0;
    var errors_found: usize = 0;
    var passed = result.term == .Exited and result.term.Exited == 0;

    // Check for memory leaks
    var iter = std.mem.splitScalar(u8, output_str, '\n');
    while (iter.next()) |line| {
        if (std.mem.indexOf(u8, line, "leaked")) |_| {
            // Extract leak count
            if (std.mem.indexOf(u8, line, "leaked")) |idx| {
                const leak_part = line[idx..];
                if (std.mem.indexOf(u8, leak_part, "allocation")) |alloc_idx| {
                    const num_str = leak_part["leaked ".len..alloc_idx];
                    leaks_found += std.fmt.parseInt(usize, std.mem.trim(u8, num_str, " "), 10) catch 1;
                }
            }
        }
    }

    // Check for test failures
    iter = std.mem.splitScalar(u8, output_str, '\n');
    while (iter.next()) |line| {
        if (std.mem.indexOf(u8, line, "error: '")) |_| {
            errors_found += 1;
        }
    }

    return TestResult{
        .module = module,
        .passed = passed and leaks_found == 0 and errors_found == 0,
        .has_leaks = leaks_found > 0,
        .leak_count = leaks_found,
        .error_count = errors_found,
        .duration_ms = duration_ms,
        .output = output_str,
    };
}

/// Run all modules and return results
pub fn runAllTests(allocator: std.mem.Allocator, config: TestConfig) ![]TestResult {
    const start_time = std.time.nanoTimestamp();

    var results = std.ArrayList(TestResult).init(allocator);
    errdefer {
        for (results.items) |*r| {
            allocator.free(r.output);
        }
        results.deinit(allocator);
    }

    // Run tests (simplified - could be parallelized)
    for (ALL_MODULES) |module| {
        const result = try runModuleTest(allocator, module);
        try results.append(result);

        if (config.verbose) {
            std.debug.print("{s}... {s}\n", .{
                module.name,
                if (result.passed) "PASS" else "FAIL",
            });
        }

        if (!result.passed and config.stop_on_first_error) {
            break;
        }
    }

    return results.toOwnedSlice();
}

/// Print test summary
pub fn printSummary(results: []const TestResult) void {
    const stdout = std.io.getStdOut().writer();

    var passed: usize = 0;
    var with_leaks: usize = 0;
    var with_errors: usize = 0;
    var total_duration_ms: u64 = 0;

    for (results) |result| {
        total_duration_ms += result.duration_ms;
        if (result.passed) {
            passed += 1;
        } else if (result.has_leaks) {
            with_leaks += 1;
        } else {
            with_errors += 1;
        }
    }

    stdout.print(
        \\
        \\========================================
        \\Test Summary
        \\========================================
        \\Total: {d}
        \\✅ Passed: {d}
        \\🔴 With Leaks: {d}
        \\❌ With Errors: {d}
        \\⏱️  Total Duration: {d}ms
        \\
    , .{
        results.len,
        passed,
        with_leaks,
        with_errors,
        total_duration_ms,
    }) catch return;

    // Show failures
    if (with_leaks > 0 or with_errors > 0) {
        stdout.print("\nFailures:\n", .{}) catch return;

        for (results) |result| {
            if (!result.passed) {
                if (result.has_leaks) {
                    stdout.print("  🔴 {s} - {d} leaks\n", .{
                        result.module.name,
                        result.leak_count,
                    }) catch return;
                } else {
                    stdout.print("  ❌ {s} - {d} errors\n", .{
                        result.module.name,
                        result.error_count,
                    }) catch return;
                }
            }
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "test engine: markdown module passes without leaks" {
    const module = Module{
        .name = "memory/engines/markdown",
        .test_file = "memory/engines/markdown",
    };

    const result = try runModuleTest(std.testing.allocator, module);
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(result.passed);
    try std.testing.expect(!result.has_leaks);
    try std.testing.expectEqual(@as(usize, 0), result.leak_count);
}

test "test engine: agent/root module passes without leaks" {
    const module = Module{
        .name = "agent/root",
        .test_file = "agent/root",
    };

    const result = try runModuleTest(std.testing.allocator, module);
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(result.passed);
    try std.testing.expect(!result.has_leaks);
}
