//! Test each module discovered by find command
//!
//! Reads module paths from stdin and tests each one

const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdin = std.io.getStdIn().reader();
    const stderr = std.io.getStdErr().writer();

    // Read all module paths from stdin
    const input = try stdin.readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(input);

    var passed: usize = 0;
    var failed: usize = 0;
    var leaked: usize = 0;

    stderr.print("🔍 Testing discovered modules...\n\n", .{}) catch {};

    // Split by lines and test each module
    var iter = std.mem.splitScalar(u8, input, '\n');
    while (iter.next()) |module_path| {
        const trimmed = std.mem.trim(u8, module_path, " \r\n\t");
        if (trimmed.len == 0) continue;

        stderr.print("  {s}... ", .{trimmed}) catch {};

        // Run zig build test for this module
        const result = try testModule(trimmed);

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

    // Use runCommand which actually works
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

    // Check for leaks in output
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
