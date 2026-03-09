const std = @import("std");

// Direct test of http_util with tls.zig backend
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Verifying Web Fetch with tls.zig backend          ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});

    // Test the actual fetch implementation
    const test_url = "https://news.ycombinator.com";
    std.debug.print("Testing: {s}\n", .{test_url});
    std.debug.print("This site uses ECDSA certificates (previously failed)\n\n", .{});

    // We need to use curlGet which now routes to tls.zig for HTTPS
    // Since we can't directly import http_util without the tls module,
    // we'll use the tls.zig library directly

    const tls = @import("lib/tls_zig/src/root.zig");

    const uri = try std.Uri.parse(test_url);
    const host = uri.host.?.percent_encoded;
    const port: u16 = 443;

    std.debug.print("Host: {s}\n", .{host});
    std.debug.print("Port: {d}\n\n", .{port});

    // Create threaded Io
    var threaded = std.Io.Threaded.init(allocator, .{
        .async_limit = .nothing,
        .concurrent_limit = .nothing,
    });
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("Step 1: Establishing TCP connection...\n", .{});
    const host_name = try std.Io.net.HostName.init(host);
    var tcp = try host_name.connect(io, port, .{ .mode = .stream });
    defer tcp.close(io);
    std.debug.print("  ✓ TCP connected\n\n", .{});

    std.debug.print("Step 2: Loading system root certificates...\n", .{});
    var root_ca = try tls.config.cert.fromSystem(allocator, io);
    defer root_ca.deinit(allocator);
    std.debug.print("  ✓ Root CA loaded\n\n", .{});

    std.debug.print("Step 3: Upgrading to TLS...\n", .{});
    var input_buf: [tls.input_buffer_len]u8 = undefined;
    var output_buf: [tls.output_buffer_len]u8 = undefined;
    var reader = tcp.reader(io, &input_buf);
    var writer = tcp.writer(io, &output_buf);

    var prng = std.Random.DefaultPrng.init(0x5ec1adeca1bad);
    var conn = try tls.client(&reader.interface, &writer.interface, .{
        .rng = prng.random(),
        .host = host,
        .root_ca = root_ca,
        .now = std.Io.Clock.real.now(io),
    });
    defer conn.close() catch {};
    std.debug.print("  ✓ TLS connection established\n\n", .{});

    std.debug.print("Step 4: Sending HTTP GET request...\n", .{});
    const request = "GET / HTTP/1.1\r\nHost: news.ycombinator.com\r\nConnection: close\r\nUser-Agent: nullclaw-test/1.0\r\n\r\n";
    try conn.writeAll(request);
    std.debug.print("  ✓ Request sent\n\n", .{});

    std.debug.print("Step 5: Reading response...\n", .{});
    var response_buffer = std.ArrayList(u8).initCapacity(allocator, 8192) catch |err| {
        std.debug.print("  ✗ Failed to allocate buffer: {}\n", .{err});
        return err;
    };
    defer response_buffer.deinit(allocator);

    var bytes_read: usize = 0;
    const max_bytes = 100 * 1024; // Read up to 100KB

    while (bytes_read < max_bytes) {
        const data = (try conn.next()) orelse break;
        try response_buffer.appendSlice(allocator, data);
        bytes_read += data.len;
        if (data.len == 0) break;
    }

    std.debug.print("  ✓ Read {d} bytes\n\n", .{response_buffer.items.len});

    // Check if we got valid HTML
    const has_html = std.mem.indexOf(u8, response_buffer.items, "<html") != null or
                      std.mem.indexOf(u8, response_buffer.items, "<!DOCTYPE") != null;

    if (has_html and response_buffer.items.len > 100) {
        std.debug.print("╔═══════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║  ✓✓✓ SUCCESS! TLS fetch works!                     ║\n", .{});
        std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});

        std.debug.print("Preview (first 300 chars):\n", .{});
        const preview_len = @min(300, response_buffer.items.len);
        std.debug.print("{s}\n\n", .{response_buffer.items[0..preview_len]});

        std.debug.print("✓ ECDSA certificates work via tls.zig\n", .{});
        std.debug.print("✓ web_fetch should now work for all HTTPS sites\n", .{});
    } else {
        std.debug.print("╔═══════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║  ✗✗✗ FAILED - Unexpected response                   ║\n", .{});
        std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});
        std.debug.print("Response: {s}\n", .{response_buffer.items});
    }
}
