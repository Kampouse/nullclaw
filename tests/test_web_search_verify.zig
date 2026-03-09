const std = @import("std");
const web_search = @import("src/tools/web_search.zig");

// Test web_search with actual API calls
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Testing web_search Tool - Real API Calls            ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});

    const tests = [_]struct {
        name: []const u8,
        query: []const u8,
        provider: []const u8,
    }{
        .{ .name = "Basic search", .query = "Zig programming language", .provider = "duckduckgo" },
        .{ .name = "Tech news", .query = "latest tech news", .provider = "duckduckgo" },
        .{ .name = "Weather query", .query = "weather Toronto", .provider = "duckduckgo" },
    };

    var tool = web_search.WebSearchTool{};

    for (tests, 0..) |test_case, i| {
        std.debug.print("Test {d}/{d}: {s}\n", .{i + 1, tests.len, test_case.name});
        std.debug.print("Query: {s}\n", .{test_case.query});
        std.debug.print("Provider: {s}\n", .{test_case.provider});
        std.debug.print("─────────────────────────────────────────────────────\n", .{});

        // Create args object
        const args_json = try std.fmt.allocPrint(allocator,
            "{{\"query\":\"{s}\",\"provider\":\"{s}\"}}",
            .{test_case.query, test_case.provider});
        defer allocator.free(args_json);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
        defer parsed.deinit();

        if (parsed.value != .object) {
            std.debug.print("✗ Failed to parse args\n\n", .{});
            continue;
        }

        // Execute the tool
        const result = tool.execute(allocator, parsed.value.object) catch |err| {
            std.debug.print("✗ Execute failed: {}\n\n", .{err});
            continue;
        };

        defer {
            if (result.owns_output) allocator.free(result.output);
            if (result.owns_error_msg and result.error_msg != null) allocator.free(result.error_msg);
        }

        if (result.success) {
            std.debug.print("✓ SUCCESS\n", .{});
            std.debug.print("  Output length: {d} bytes\n", .{result.output.len});

            // Show preview
            const preview_len = @min(500, result.output.len);
            std.debug.print("\n  Preview:\n", .{});
            std.debug.print("  ┌", .{});
            for (0..50) |_| std.debug.print("─", .{});
            std.debug.print("┐\n", .{});

            var line_start: usize = 0;
            var line_count: usize = 0;
            while (line_start < preview_len and line_count < 15) : (line_count += 1) {
                const line_end = std.mem.indexOfScalarPos(u8, result.output, line_start, '\n') orelse preview_len;
                const line = result.output[line_start..@min(line_end + 1, preview_len)];
                if (line.len > 0) {
                    std.debug.print("  {s}", .{line});
                }
                line_start = line_end + 1;
            }

            std.debug.print("  └", .{});
            for (0..50) |_| std.debug.print("─", .{});
            std.debug.print("┘\n\n", .{});
        } else {
            std.debug.print("✗ FAILED\n", .{});
            if (result.error_msg) |msg| {
                std.debug.print("  Error: {s}\n\n", .{msg});
            } else {
                std.debug.print("  No error message\n\n", .{});
            }
        }
    }

    std.debug.print("╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Test Complete                                        ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});
}
