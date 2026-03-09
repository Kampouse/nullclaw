const std = @import("std");
const tls = @import("lib/tls_zig/src/root.zig");

// Simple test for tls.zig library with ECDSA certificates
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{
        .async_limit = .nothing,
        .concurrent_limit = .nothing,
    });
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("\n=== Testing tls.zig with ECDSA ===\n\n", .{});

    const test_url = "https://news.ycombinator.com";
    std.debug.print("URL: {s}\n", .{test_url});

    // Parse URL
    const uri = try std.Uri.parse(test_url);
    const host = uri.host.?.percent_encoded;
    const port: u16 = 443;

    // Establish TCP connection
    std.debug.print("Connecting...\n", .{});
    const host_name = try std.Io.net.HostName.init(host);
    var tcp = try host_name.connect(io, port, .{ .mode = .stream });
    defer tcp.close(io);

    // Load system root certificates
    std.debug.print("Loading CA bundle...\n", .{});
    var root_ca = try tls.config.cert.fromSystem(allocator, io);
    defer root_ca.deinit(allocator);

    // Upgrade TCP to TLS
    std.debug.print("Upgrading to TLS...\n", .{});
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

    std.debug.print("✓ TLS connection established!\n", .{});

    // Send HTTP GET request
    const request = "GET / HTTP/1.1\r\nHost: news.ycombinator.com\r\nConnection: close\r\n\r\n";
    try conn.writeAll(request);

    // Read first chunk of response
    const data = (try conn.next()) orelse {
        std.debug.print("\n✗ No response data\n", .{});
        return;
    };

    std.debug.print("\n✓ SUCCESS: Read {d} bytes\n", .{data.len});
    const preview = if (data.len > 200) data[0..200] else data;
    std.debug.print("Preview: {s}\n\n", .{preview});

    std.debug.print("=== Test Complete ===\n", .{});
    std.debug.print("\ntls.zig successfully handles ECDSA certificates!\n", .{});
}
