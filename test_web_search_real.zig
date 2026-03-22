const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("═══════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  DuckDuckGo Live API Test - Real HTTP Requests\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════\n\n", .{});

    // Test 1: Search for "weather"
    std.debug.print("Test 1: Searching for 'weather'\n", .{});
    std.debug.print("───────────────────────────────────────────────────────────────\n", .{});

    const url1 = try std.fmt.allocPrint(allocator, "https://api.duckduckgo.com/?q=weather&format=json&no_html=1&skip_disambig=1", .{});
    defer allocator.free(url1);

    const response1 = try curlGet(allocator, url1);
    defer allocator.free(response1);

    std.debug.print("Response length: {d} bytes\n", .{response1.len});
    std.debug.print("\nResponse:\n{s}\n", .{response1});
    std.debug.print("\n", .{});

    // Test 2: Search for "zig programming"
    std.debug.print("\nTest 2: Searching for 'zig programming language'\n", .{});
    std.debug.print("───────────────────────────────────────────────────────────────\n", .{});

    const query2 = try std.fmt.allocPrint(allocator, "https://api.duckduckgo.com/?q=zig+programming+language&format=json&no_html=1&skip_disambig=1", .{});
    defer allocator.free(query2);

    const response2 = try curlGet(allocator, query2);
    defer allocator.free(response2);

    std.debug.print("Response length: {d} bytes\n", .{response2.len});

    if (response2.len < 500) {
        std.debug.print("\nResponse:\n{s}\n", .{response2});
    } else {
        std.debug.print("\nResponse (first 500 chars):\n{s}\n", .{response2[0..500]});
        std.debug.print("...\n", .{});
    }

    std.debug.print("\n", .{});

    std.debug.print("\n═══════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  All tests completed!\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════\n", .{});
}

fn curlGet(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const args = [_][]const u8{ "curl", "-s", "-L", url };
    const result = try std.process.Child.exec(.{
        .allocator = allocator,
        .argv = &args,
        .max_output_bytes = 1024 * 1024, // 1MB max
    });

    if (result.term.Exited != 0) {
        std.debug.print("curl failed with stderr: {s}\n", .{result.stderr});
        return error.CurlFailed;
    }

    return result.stdout;
}
