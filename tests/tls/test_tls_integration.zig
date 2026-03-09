const std = @import("std");
const http_util = @import("src/http_util.zig");

// Test automatic fallback from std.http.Client to tls.zig for ECDSA certificates
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n=== Testing Automatic TLS Fallback ===\n\n", .{});

    // Test sites with different TLS configurations
    const tests = [_]struct {
        name: []const u8,
        url: []const u8,
    }{
        .{ .name = "DuckDuckGo (RSA, TLS 1.3)", .url = "https://api.duckduckgo.com" },
        .{ .name = "Hacker News (ECDSA, TLS 1.2)", .url = "https://news.ycombinator.com" },
        .{ .name = "Weather Network (TLS 1.3)", .url = "https://www.theweathernetwork.com" },
    };

    for (tests) |tc| {
        std.debug.print("\nTest: {s}\n", .{tc.name});
        std.debug.print("  URL: {s}\n", .{tc.url});

        const result = http_util.curlGet(allocator, tc.url, &[_][]const u8{}, "30") catch |err| {
            std.debug.print("  ✗ FAILED: {}\n", .{err});
            std.debug.print("  Error: {s}\n\n", .{@errorName(err)});
            continue;
        };
        defer allocator.free(result);

        std.debug.print("  ✓ SUCCESS\n", .{});
        std.debug.print("  Response: {d} bytes\n", .{result.len});
    }

    std.debug.print("\n=== Test Complete ===\n", .{});
    std.debug.print("\nBoth RSA and ECDSA certificates should now work!\n", .{});
}
