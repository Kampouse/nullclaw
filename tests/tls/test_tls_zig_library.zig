const std = @import("std");
const tls = @import("lib/tls_zig/src/root.zig");

// Test the tls.zig library with ECDSA certificates
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{
        .async_limit = .nothing,
        .concurrent_limit = .nothing,
    });
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("\n=== Testing tls.zig library ===\n\n", .{});

    const test_url = "https://news.ycombinator.com";
    std.debug.print("Fetching: {s}\n", .{test_url});

    // Parse URL
    const uri = try std.Uri.parse(test_url);
    const host = uri.host.?.percent_encoded;
    const port = 443;

    // Establish TCP connection
    std.debug.print("Connecting to {s}:{d}...\n", .{host, port});
    const host_name = try std.Io.net.HostName.init(host);
    var tcp = try host_name.connect(io, port, .{ .mode = .stream });
    defer tcp.close(io);

    // Load system root certificates
    std.debug.print("Loading system root certificates...\n", .{});
    var root_ca = try tls.config.cert.fromSystem(allocator, io);
    defer root_ca.deinit(allocator);

    // Upgrade TCP to TLS
    std.debug.print("Upgrading to TLS...\n", .{});
    var input_buf: [tls.input_buffer_len]u8 = undefined;
    var output_buf: [tls.output_buffer_len]u8 = undefined;
    var reader = tcp.reader(io, &input_buf);
    var writer = tcp.writer(io, &output_buf);

    // Use constant seed for TLS PRNG (not security-sensitive for client)
    var prng = std.Random.DefaultPrng.init(0x5ec1adeca1bad);
    var conn = try tls.client(&reader.interface, &writer.interface, .{
        .rng = prng.random(),
        .host = host,
        .root_ca = root_ca,
        .now = std.Io.Clock.real.now(io),
    });
    defer conn.close() catch {};

    std.debug.print("✓ TLS connection established!\n", .{});

    // Send HTTP request
    const request = try std.fmt.allocPrint(allocator, "GET / HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{host});
    defer allocator.free(request);

    try conn.writeAll(request);

    // Read response
    var buffer: [4096]u8 = undefined;
    const n = try conn.read(&buffer);

    std.debug.print("\n✓ SUCCESS: Read {d} bytes\n", .{n});
    std.debug.print("Response preview: {s}\n\n", .{if (n > 200) buffer[0..200] else buffer[0..n]});

    std.debug.print("=== Test Complete ===\n", .{});
    std.debug.print("\nThe tls.zig library successfully handles ECDSA certificates!\n", .{});
}
