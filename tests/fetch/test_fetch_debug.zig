const std = @import("std");

// This test directly uses http_util to see which TLS path is taken

// Minimal http implementation to test
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  HTTP Fetch Debug Test - Checking TLS Fallback    ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});

    const tests = [_]struct {
        name: []const u8,
        url: []const u8,
        expected: []const u8,
    }{
        .{ .name = "RSA Certificate (stdlib)", .url = "https://api.duckduckgo.com", .expected = "Should work with stdlib" },
        .{ .name = "ECDSA Certificate (needs fallback)", .url = "https://news.ycombinator.com", .expected = "Should trigger tls.zig fallback" },
        .{ .name = "Weather Site", .url = "https://www.weather.gc.ca/city/pages/on-118_e.html", .expected = "May need fallback" },
    };

    for (tests, 0..) |tc, i| {
        std.debug.print("\n┌─ Test {d}/{d}: {s}\n", .{i + 1, tests.len, tc.name});
        std.debug.print("├─ URL: {s}\n", .{tc.url});
        std.debug.print("├─ Expected: {s}\n", .{tc.expected});
        std.debug.print("│\n", .{});

        // Get threaded Io for network operations
        var threaded = std.Io.Threaded.init(allocator, .{
            .async_limit = .nothing,
            .concurrent_limit = .nothing,
        });
        defer threaded.deinit();
        const io = threaded.io();

        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();

        const uri = std.Uri.parse(tc.url) catch |err| {
            std.debug.print("├─ ✗ Parse failed: {}\n", .{err});
            std.debug.print("└─\n", .{});
            continue;
        };

        std.debug.print("├─ Attempting stdlib http.Client...\n", .{});

        var req = client.request(.GET, uri, .{}) catch |err| {
            std.debug.print("├─ ✗ stdlib failed: {}\n", .{err});
            if (err == error.TlsInitializationFailed) {
                std.debug.print("├─ ⚠ This is the ECDSA issue - tls.zig fallback should handle this\n", .{});
                std.debug.print("├─ ℹ Check if daemon's http_util.zig is calling curlGetTlsLibrary()\n", .{});
            } else {
                std.debug.print("├─ ℹ Error: {s}\n", .{@errorName(err)});
            }
            std.debug.print("└─\n", .{});
            continue;
        };
        defer req.deinit();

        std.debug.print("├─ ✓ stdlib request created\n", .{});

        try req.sendBodiless();
        std.debug.print("├─ ✓ Request sent\n", .{});

        var redirect_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            std.debug.print("├─ ✗ Receive failed: {}\n", .{err});
            std.debug.print("└─\n", .{});
            continue;
        };

        std.debug.print("├─ Status: {}\n", .{response.head.status});

        if (response.head.status != .ok) {
            std.debug.print("├─ ✗ HTTP error status\n", .{});
            std.debug.print("└─\n", .{});
            continue;
        }

        // Read first chunk to verify it works
        var response_buffer = std.ArrayList(u8).initCapacity(allocator, 1024) catch |err| {
            std.debug.print("├─ ✗ Buffer init failed: {}\n", .{err});
            std.debug.print("└─\n", .{});
            continue;
        };
        defer response_buffer.deinit(allocator);

        var transfer_buf: [4096]u8 = undefined;
        const body_reader = req.reader.bodyReader(&transfer_buf, response.head.transfer_encoding, response.head.content_length);

        // Use fill() to read data
        const fill_size = @min(512, response.head.content_length orelse 512);
        body_reader.fill(fill_size) catch |err| {
            if (err == error.EndOfStream) {
                std.debug.print("├─ ✓ Connection closed by server\n", .{});
            } else {
                std.debug.print("├─ ✗ Fill error: {}\n", .{err});
            }
        };

        const buffered = body_reader.bufferedLen();
        if (buffered > 0) {
            const data = try body_reader.take(@min(buffered, 1024));
            try response_buffer.appendSlice(allocator, data);
        }

        std.debug.print("├─ ✓ Read {d} bytes\n", .{response_buffer.items.len});
        std.debug.print("├─ ✓ SUCCESS\n", .{});
        std.debug.print("└─\n", .{});
    }

    std.debug.print("\n╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Summary:                                              ║\n", .{});
    std.debug.print("║  - RSA sites: Should work with stdlib                  ║\n", .{});
    std.debug.print("║  - ECDSA sites: Fail with stdlib, need tls.zig fallback║\n", .{});
    std.debug.print("║                                                        ║\n", .{});
    std.debug.print("║  If ECDSA fails above, the daemon's http_util.zig     ║\n", .{});
    std.debug.print("║  should catch TlsInitializationFailed and call        ║\n", .{});
    std.debug.print("║  curlGetTlsLibrary() as fallback.                     ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});
}
