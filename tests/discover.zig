//! TRUE Test Discovery - Scans codebase and finds all tests
//!
//! This actually scans the src/ directory, finds .zig files,
//! checks for test blocks, and returns the list dynamically.

const std = @import("std");

/// Discovered test module with its path and test count
pub const DiscoveredModule = struct {
    name: []const u8,
    path: []const u8,
    test_count: usize,
};

/// Scan the codebase and discover ALL test modules
pub fn discoverTests(allocator: std.mem.Allocator) ![]DiscoveredModule {
    var modules = std.ArrayList(DiscoveredModule){};
    errdefer {
        for (modules.items) |m| {
            allocator.free(m.name);
            allocator.free(m.path);
        }
        modules.deinit(allocator);
    }

    // Scan src/ directory
    var src_dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, "src", .{}) catch |err| {
        std.debug.print("Error opening src/: {}\n", .{err});
        return error.CannotOpenSrc;
    };
    defer src_dir.close();

    // Walk all subdirectories
    var walker = try src_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        // Skip test files themselves (avoid recursion)
        if (std.mem.indexOf(u8, entry.path, "test_") != null) continue;

        // Read file and count tests
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ "src", entry.path });
        defer allocator.free(file_path);

        const content = std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch |err| {
            std.debug.print("Warning: cannot read {s}: {}\n", .{file_path, err});
            continue;
        };
        defer allocator.free(content);

        // Count test blocks
        const test_count = countTests(content);
        if (test_count == 0) continue;

        // Convert path to module name (remove .zig, use forward slashes)
        var module_name = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(module_name);

        // Remove .zig extension
        if (std.mem.endsWith(u8, module_name, ".zig")) {
            module_name = allocator.realloc(module_name, module_name.len - 4) catch unreachable;
        }

        // Store the module
        const module_path = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(module_path);

        try modules.append(DiscoveredModule{
            .name = module_name,
            .path = module_path,
            .test_count = test_count,
        });
    }

    return modules.toOwnedSlice();
}

/// Count test blocks in source code
fn countTests(content: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;

    while (i < content.len) {
        // Look for 'test "' pattern
        if (i + 6 <= content.len and
            content[i] == 't' and
            content[i + 1] == 'e' and
            content[i + 2] == 's' and
            content[i + 3] == 't' and
            content[i + 4] == ' ' and
            content[i + 5] == '"')
        {
            count += 1;
            i += 6;
        } else {
            i += 1;
        }
    }

    return count;
}

// ── Tests ────────────────────────────────────────────────────────────

test "discover tests in codebase" {
    const modules = try discoverTests(std.testing.allocator);
    defer {
        for (modules) |m| {
            std.testing.allocator.free(m.name);
            std.testing.allocator.free(m.path);
        }
        std.testing.allocator.free(modules);
    }

    // Should find some tests
    try std.testing.expect(modules.len > 0);

    // Print discovered modules
    const stdout = std.io.getStdErr().writer();
    stdout.print("\n🔍 Discovered {d} test modules:\n", .{modules.len}) catch {};

    var total_tests: usize = 0;
    for (modules) |m| {
        stdout.print("  {s:40} ({d} tests)\n", .{m.name, m.test_count}) catch {};
        total_tests += m.test_count;
    }

    stdout.print("\n✅ Total: {d} test blocks found\n", .{total_tests}) catch {};

    // Verify we found expected modules
    var found_markdown = false;
    var found_agent = false;

    for (modules) |m| {
        if (std.mem.indexOf(u8, m.name, "markdown") != null) found_markdown = true;
        if (std.mem.indexOf(u8, m.name, "agent") != null) found_agent = true;
    }

    try std.testing.expect(found_markdown, "Should find markdown tests");
    try std.testing.expect(found_agent, "Should find agent tests");
}

test "countTests function works" {
    const code_with_tests =
        \\const std = @import("std");
        \\
        \\test "first test" {
        \\    try std.testing.expect(true);
        \\}
        \\
        \\test "second test" {
        \\    try std.testing.expect(true);
        \\}
        \\
        \\fn helper() void {}
    ;

    const count = countTests(code_with_tests);
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "countTests ignores non-test functions" {
    const code_without_tests =
        \\const std = @import("std");
        \\
        \\fn helper() void {}
        \\pub fn other() void {}
        \\
        \\// The word "test" appears but not as a test block
        \\const testing = @import("testing");
    ;

    const count = countTests(code_without_tests);
    try std.testing.expectEqual(@as(usize, 0), count);
}
