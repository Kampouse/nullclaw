const std = @import("std");
const http_util = @import("src/http_util.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n=== Testing Web Fetch ===\n\n", .{});

    // Test sites with different TLS configurations
    const tests = [_]struct {
        name: []const u8,
        url: []const u8,
    }{
        .{ .name = "DuckDuckGo (RSA, TLS 1.3)", .url = "https://api.duckduckgo.com" },
        .{ .name = "Hacker News (ECDSA, TLS 1.2)", .url = "https://news.ycombinator.com" },
        .{ .name = "Example.com", .url = "https://example.com" },
        .{ .name = "Weather Canada (Quebec)", .url = "https://www.weather.gc.ca/city/pages/on-118_e.html" },
    };

    for (tests) |tc| {
        std.debug.print("\nTest: {s}\n", .{tc.name});
        std.debug.print("  URL: {s}\n", .{tc.url});

        const headers = [_][]const u8{
            "User-Agent: nullclaw-test/1.0",
            "Accept: text/html, text/plain",
        };

        const result = http_util.curlGet(allocator, tc.url, &headers, "30") catch |err| {
            std.debug.print("  ✗ FAILED: {}\n", .{err});
            std.debug.print("  Error: {s}\n\n", .{@errorName(err)});
            continue;
        };
        defer allocator.free(result);

        std.debug.print("  ✓ SUCCESS\n", .{});
        std.debug.print("  Response: {d} bytes\n", .{result.len});

        // Show preview
        const preview_len = @min(200, result.len);
        const preview = result[0..preview_len];
        std.debug.print("  Preview: {s}\n", .{preview});
        if (result.len > 200) std.debug.print("  ...\n", .{});
    }

    std.debug.print("\n=== Test Complete ===\n", .{});
    std.debug.print("\nIf all tests passed, web fetch is working!\n", .{});
}
