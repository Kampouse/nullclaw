const std = @import("std");

// Test TLS connectivity with different sites to identify the issue
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n=== Testing TLS Connectivity ===\n\n", .{});

    // Test sites with different TLS configurations
    const tests = [_]struct {
        name: []const u8,
        url: []const u8,
        expected_tls: []const u8,
    }{
        .{
            .name = "DuckDuckGo (TLS 1.3, RSA)",
            .url = "https://api.duckduckgo.com",
            .expected_tls = "1.3",
        },
        .{
            .name = "Hacker News (TLS 1.2, ECDSA)",
            .url = "https://news.ycombinator.com",
            .expected_tls = "1.2",
        },
        .{
            .name = "Weather Network (TLS 1.3)",
            .url = "https://www.theweathernetwork.com",
            .expected_tls = "1.3",
        },
    };

    const http_util = struct {
        fn testFetch(alloc: std.mem.Allocator, url: []const u8) ![]const u8 {
            const util = @import("src/http_util.zig");
            return util.curlGet(alloc, url, &[_][]const u8{}, "30");
        }
    };

    for (tests) |tc| {
        std.debug.print("\nTest: {s}\n", .{tc.name});
        std.debug.print("  URL: {s}\n", .{tc.url});
        std.debug.print("  Expected TLS: {s}\n", .{tc.expected_tls});

        const result = http_util.testFetch(allocator, tc.url) catch |err| {
            std.debug.print("  ✗ FAILED: {}\n", .{err});
            std.debug.print("  Error name: {s}\n", .{@errorName(err)});

            // Check if it's the specific TLS error
            if (err == error.TlsInitializationFailed) {
                std.debug.print("  ⚠️  This is TlsInitializationFailed!\n", .{});
                std.debug.print("  Likely causes:\n", .{});
                std.debug.print("    - ECDSA certificate not supported\n", .{});
                std.debug.print("    - TLS 1.2 cipher suite not supported\n", .{});
                std.debug.print("    - Secure Transport limitation on macOS\n", .{});
            }
            continue;
        };

        defer allocator.free(result);
        std.debug.print("  ✓ SUCCESS\n", .{});
        std.debug.print("  Response length: {d} bytes\n", .{result.len});
        const preview = if (result.len > 100) result[0..100] else result;
        std.debug.print("  Preview: {s}...\n\n", .{preview});
    }

    std.debug.print("\n=== Test Complete ===\n", .{});
    std.debug.print("\nIf DuckDuckGo works but Hacker News fails:\n", .{});
    std.debug.print("  The issue is ECDSA certificate support in Zig's std.http.Client\n", .{});
    std.debug.print("  This is a known limitation on macOS with Secure Transport\n\n", .{});
}
