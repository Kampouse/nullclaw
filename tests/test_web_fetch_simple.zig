const std = @import("std");

// Simple HTTP client test using stdlib only
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n=== Testing Web Fetch (stdlib only) ===\n\n", .{});

    // Test sites
    const tests = [_]struct {
        name: []const u8,
        url: []const u8,
    }{
        .{ .name = "DuckDuckGo (RSA)", .url = "https://api.duckduckgo.com" },
        .{ .name = "Example.com", .url = "https://example.com" },
        .{ .name = "Hacker News (ECDSA)", .url = "https://news.ycombinator.com" },
    };

    for (tests) |tc| {
        std.debug.print("\nTest: {s}\n", .{tc.name});
        std.debug.print("  URL: {s}\n", .{tc.url});

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
            std.debug.print("  ✗ Parse failed: {}\n", .{err});
            continue;
        };

        var req = client.request(.GET, uri, .{}) catch |err| {
            std.debug.print("  ✗ Request failed: {}\n", .{err});
            std.debug.print("  This may indicate ECDSA TLS issue\n", .{});
            continue;
        };
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            std.debug.print("  ✗ Receive failed: {}\n", .{err});
            continue;
        };

        if (response.head.status != .ok) {
            std.debug.print("  ✗ HTTP status: {}\n", .{response.head.status});
            continue;
        }

        // Read response body
        var response_buffer = std.ArrayList(u8).initCapacity(allocator, 8192) catch |err| {
            std.debug.print("  ✗ Buffer init failed: {}\n", .{err});
            continue;
        };
        defer response_buffer.deinit(allocator);

        var transfer_buf: [8192]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var decompress_buf: [65536]u8 = undefined;

        const body_reader = if (response.head.content_encoding == .identity)
            req.reader.bodyReader(&transfer_buf, response.head.transfer_encoding, response.head.content_length)
        else
            response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);

        const max_response = 10 * 1024 * 1024;
        while (response_buffer.items.len < max_response) {
            const fill_size = @min(4096, max_response - response_buffer.items.len);
            body_reader.fill(fill_size) catch |err| {
                if (err == error.EndOfStream) {
                    const buffered = body_reader.bufferedLen();
                    if (buffered == 0) break;
                    const data = try body_reader.take(buffered);
                    try response_buffer.appendSlice(allocator, data);
                    break;
                }
                std.debug.print("  ✗ Read error: {}\n", .{err});
                break;
            };

            const buffered = body_reader.bufferedLen();
            if (buffered == 0) break;

            const to_read = @min(buffered, max_response - response_buffer.items.len);
            const data = try body_reader.take(to_read);
            if (data.len == 0) break;

            try response_buffer.appendSlice(allocator, data);
        }

        std.debug.print("  ✓ SUCCESS\n", .{});
        std.debug.print("  Status: {}\n", .{response.head.status});
        std.debug.print("  Size: {d} bytes\n", .{response_buffer.items.len});

        // Show preview
        const preview_len = @min(150, response_buffer.items.len);
        std.debug.print("  Preview: {s}\n", .{response_buffer.items[0..preview_len]});
    }

    std.debug.print("\n=== Test Complete ===\n", .{});
}
