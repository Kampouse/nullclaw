!//! TRUE Auto-Discovery in ZIG - No hardcoding
//!
//! Discovers all test modules by running shell commands from Zig

const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stderr = std.io.getStdErr().writer();

    stderr.print("🔍 Auto-discovering test modules...\n\n", .{}) catch {};

    // Use find command to discover all test files
    const find_result = try std.process.Child.run(&[_][]const u8{
        "bash", "-c",
        "find src -name '*.zig' -exec grep -l 'test \"' {} \\; | sed 's|^src/||' | sed 's|\\.zig$||'",
    }, .{ .allocator = allocator }) catch |err| {
        stderr.print("Error running find: {}\n", .{err}) catch {};
        std.process.exit(1);
    };
    defer {
        allocator.free(find_result.stdout);
        allocator.free(find_result.stderr);
    }

    if (find_result.term != .Exited) {
        stderr.print("Find command failed\n", .{}) catch {};
        std.process.exit(1);
    }

    // Parse discovered modules
    var modules = std.ArrayList([]const u8).init(allocator);
    defer {
        for (modules.items) |m| allocator.free(m);
        modules.deinit(allocator);
    }

    var iter = std.mem.splitScalar(u8, find_result.stdout, '\n');
    while (iter.next()) |module_path| {
        const trimmed = std.mem.trim(u8, module_path, " \r\n\t");
        if (trimmed.len == 0) continue;

        const module_copy = try allocator.dupe(u8, trimmed);
        try modules.append(module_copy);
    }

    if (modules.items.len == 0) {
        stderr.print("No test modules found!\n", .{}) catch {};
        std.process.exit(1);
    }

    stderr.print("Found {d} test modules\n\n", .{modules.items.len}) catch {};

    // Test each discovered module
    var passed: usize = 0;
    var failed: usize = 0;
    var leaked: usize = 0;

    for (modules.items) |module| {
        stderr.print("  {s}... ", .{module}) catch {};

        const result = try testModule(module);

        if (result.passed) {
            stderr.print("✅\n", .{}) catch {};
            passed += 1;
        } else {
            stderr.print("❌\n", .{}) catch {};
            failed += 1;
            if (result.leak_count > 0) {
                stderr.print("    ({d} leaks)\n", .{result.leak_count}) catch {};
                leaked += 1;
            }
        }
    }

    stderr.print(
        \\
        \\========================================
        \\Results: {d} passed, {d} failed, {d} with leaks
        \\========================================
        \\
    , .{ passed, failed, leaked }) catch {};

    if (failed > 0 or leaked > 0) {
        std.process.exit(1);
    }
}

const TestResult = struct {
    passed: bool,
    leak_count: usize,
};

fn testModule(module: []const u8) !TestResult {
    const allocator = std.heap.page_allocator;

    // Run: zig build test -Dtest-file=<module> --summary all
    const test_file_arg = try std.fmt.allocPrint(allocator, "-Dtest-file={s}", .{module});
    defer allocator.free(test_file_arg);

    const args = [_][]const u8{
        "zig", "build", "test",
        test_file_arg,
        "--summary", "all",
    };

    const result = try std.process.Child.run(&args, .{ .allocator = allocator }) catch |err| {
        return TestResult{
            .passed = false,
            .leak_count = 0,
        };
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Check for leaks
    var leak_count: usize = 0;
    var iter = std.mem.splitScalar(u8, result.stdout, '\n');
    while (iter.next()) |line| {
        if (std.mem.indexOf(u8, line, "leaked")) |_| {
            leak_count += 1;
        }
    }

    const passed = result.term == .Exited and result.term.Exited == 0 and leak_count == 0;

    return TestResult{
        .passed = passed,
        .leak_count = leak_count,
    };
}
