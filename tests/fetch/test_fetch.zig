const std = @import("std");

// Simple test to verify HTTPS fetching works
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n=== Testing HTTPS Fetch ===\n\n", .{});

    // Test: Simple HTTPS fetch
    {
        std.debug.print("Fetching from https://httpbin.org/get\n", .{});

        const url = "https://httpbin.org/get";
        const headers = [_][]const u8{
            "User-Agent: nullclaw-test/1.0",
        };

        const result = testFetch(allocator, url, &headers) catch |err| {
            std.debug.print("✗ FAILED: {}\n", .{err});
            std.debug.print("Error name: {s}\n", .{@errorName(err)});
            return;
        };

        std.debug.print("✓ SUCCESS\n", .{});
        std.debug.print("Response length: {d} bytes\n", .{result.len});
        std.debug.print("Response preview: {s}\n\n", .{if (result.len > 100) result[0..100] else result});
    }

    std.debug.print("=== Fetch Test Complete ===\n\n", .{});
    std.debug.print("If test passed, HTTPS fetching is working!\n", .{});
    std.debug.print("If test failed, check network connectivity.\n\n", .{});
}

fn testFetch(allocator: std.mem.Allocator, url: []const u8, headers: []const []const u8) ![]u8 {
    // Use the project's http_util which has proper TLS setup
    const http_util = @import("src/http_util.zig");
    return http_util.curlGet(allocator, url, headers, "30");
}
