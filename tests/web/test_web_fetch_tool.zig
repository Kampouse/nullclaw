const std = @import("std");
const web_fetch = @import("src/tools/web_fetch.zig");

// Test the actual web_fetch tool
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Testing web_fetch Tool Directly                   ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});

    const test_urls = [_][]const u8{
        "https://news.ycombinator.com",
        "https://example.com",
        "https://www.weather.gc.ca/city/pages/on-118_e.html",
    };

    var tool = web_fetch.WebFetchTool{};

    for (test_urls, 0..) |url, i| {
        std.debug.print("Test {d}/{d}: {s}\n", .{i + 1, test_urls.len, url});
        std.debug.print("─────────────────────────────────────────────────────\n", .{});

        // Create args object with URL
        const args_json = try std.fmt.allocPrint(allocator, "{{\"url\":\"{s}\"}}", .{url});
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

        // Clean up result if needed
        if (result.owns_output) allocator.free(result.output);
        if (result.owns_error_msg and result.error_msg != null) allocator.free(result.error_msg);

        if (result.success) {
            std.debug.print("✓ SUCCESS\n", .{});
            std.debug.print("  Output length: {d} bytes\n", .{result.output.len});

            // Show preview
            const preview_len = @min(300, result.output.len);
            std.debug.print("\n  Preview:\n", .{});
            std.debug.print("  ┌", .{});
            for (0..50) |_| std.debug.print("─", .{});
            std.debug.print("┐\n", .{});

            var line_start: usize = 0;
            var line_count: usize = 0;
            while (line_start < preview_len and line_count < 10) : (line_count += 1) {
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
