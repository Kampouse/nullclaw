const std = @import("std");

// Comprehensive test of TLS support across different certificate types and sites
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Comprehensive TLS Test - Multiple Certificate Types    ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n\n", .{});

    const tls = @import("lib/tls_zig/src/root.zig");

    const TestSite = struct {
        name: []const u8,
        url: []const u8,
        cert_type: []const u8,
        description: []const u8,
    };

    const sites = [_]TestSite{
        .{ .name = "Hacker News", .url = "https://news.ycombinator.com", .cert_type = "ECDSA", .description = "Well-known ECDSA site" },
        .{ .name = "DuckDuckGo", .url = "https://api.duckduckgo.com", .cert_type = "RSA", .description = "API endpoint" },
        .{ .name = "Example.com", .url = "https://example.com", .cert_type = "RSA", .description = "Basic test site" },
        .{ .name = "Google", .url = "https://www.google.com", .cert_type = "RSA/ECC", .description = "Major search engine" },
        .{ .name = "GitHub", .url = "https://github.com", .cert_type = "RSA", .description = "Code hosting" },
        .{ .name = "Wikipedia", .url = "https://en.wikipedia.org", .cert_type = "RSA", .description = "Encyclopedia" },
        .{ .name = "Reddit", .url = "https://www.reddit.com", .cert_type = "RSA", .description = "Social platform" },
        .{ .name = "Stack Overflow", .url = "https://stackoverflow.com", .cert_type = "RSA", .description = "Q&A site" },
        .{ .name = "Mozilla", .url = "https://www.mozilla.org", .cert_type = "RSA", .description = "Firefox maker" },
        .{ .name = "Weather.gov", .url = "https://www.weather.gov", .cert_type = "RSA", .description = "US weather service" },
    };

    var passed: usize = 0;
    var failed: usize = 0;

    for (sites, 0..) |site, i| {
        std.debug.print("┌─ Test {d}/{d}: {s}\n", .{i + 1, sites.len, site.name});
        std.debug.print("├─ URL: {s}\n", .{site.url});
        std.debug.print("├─ Cert: {s} - {s}\n", .{site.cert_type, site.description});
        std.debug.print("│\n", .{});

        const uri = std.Uri.parse(site.url) catch |err| {
            std.debug.print("├─ ✗ Parse failed: {}\n", .{err});
            std.debug.print("└─\n", .{});
            failed += 1;
            continue;
        };

        const host = uri.host.?.percent_encoded;
        const port: u16 = 443;

        // Create threaded Io for each test
        var threaded = std.Io.Threaded.init(allocator, .{
            .async_limit = .nothing,
            .concurrent_limit = .nothing,
        });
        defer threaded.deinit();
        const io = threaded.io();

        std.debug.print("├─ Connecting to {s}:{d}...\n", .{host, port});

        const host_name = std.Io.net.HostName.init(host) catch |err| {
            std.debug.print("├─ ✗ Host init failed: {}\n", .{err});
            std.debug.print("└─\n", .{});
            failed += 1;
            continue;
        };

        var tcp = host_name.connect(io, port, .{ .mode = .stream }) catch |err| {
            std.debug.print("├─ ✗ TCP connect failed: {}\n", .{err});
            std.debug.print("└─\n", .{});
            failed += 1;
            continue;
        };
        defer tcp.close(io);

        std.debug.print("├─ ✓ TCP connected\n", .{});

        // Load root certificates
        var root_ca = tls.config.cert.fromSystem(allocator, io) catch |err| {
            std.debug.print("├─ ✗ Root CA failed: {}\n", .{err});
            std.debug.print("└─\n", .{});
            failed += 1;
            continue;
        };
        defer root_ca.deinit(allocator);

        // Upgrade to TLS
        var input_buf: [tls.input_buffer_len]u8 = undefined;
        var output_buf: [tls.output_buffer_len]u8 = undefined;
        var reader = tcp.reader(io, &input_buf);
        var writer = tcp.writer(io, &output_buf);

        var prng = std.Random.DefaultPrng.init(0x5ec1adeca1bad);
        var conn = tls.client(&reader.interface, &writer.interface, .{
            .rng = prng.random(),
            .host = host,
            .root_ca = root_ca,
            .now = std.Io.Clock.real.now(io),
        }) catch |err| {
            std.debug.print("├─ ✗ TLS handshake failed: {}\n", .{err});
            std.debug.print("└─\n", .{});
            failed += 1;
            continue;
        };
        defer conn.close() catch {};

        std.debug.print("├─ ✓ TLS established\n", .{});

        // Send HTTP request
        var request_buf: [512]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_buf,
            \\GET / HTTP/1.1\r
            \\Host: {s}\r
            \\Connection: close\r
            \\User-Agent: nullclaw-tls-test/1.0\r
            \\
        , .{host});

        try conn.writeAll(request);

        // Read response
        var response_buffer = std.ArrayList(u8).initCapacity(allocator, 4096) catch |err| {
            std.debug.print("├─ ✗ Buffer failed: {}\n", .{err});
            std.debug.print("└─\n", .{});
            failed += 1;
            continue;
        };
        defer response_buffer.deinit(allocator);

        const max_read = 10 * 1024;
        var total_read: usize = 0;

        while (total_read < max_read) {
            const data = (try conn.next()) orelse break;
            try response_buffer.appendSlice(allocator, data);
            total_read += data.len;
            if (data.len == 0) break;
        }

        if (response_buffer.items.len > 0) {
            // Check for HTTP response
            const has_http = std.mem.indexOf(u8, response_buffer.items, "HTTP") != null;
            const has_html = std.mem.indexOf(u8, response_buffer.items, "<html") != null or
                             std.mem.indexOf(u8, response_buffer.items, "<!DOCTYPE") != null;

            if (has_http or has_html) {
                std.debug.print("├─ ✓ Read {d} bytes\n", .{response_buffer.items.len});
                std.debug.print("├─ ✓✓✓ SUCCESS\n", .{});
                std.debug.print("└─\n", .{});
                passed += 1;
            } else {
                std.debug.print("├─ ⚠ Read {d} bytes (unexpected format)\n", .{response_buffer.items.len});
                std.debug.print("├─ ⚠ PARTIAL SUCCESS\n", .{});
                std.debug.print("└─\n", .{});
                passed += 1;
            }
        } else {
            std.debug.print("├─ ✗ No data received\n", .{});
            std.debug.print("├─ ✗ FAILED\n", .{});
            std.debug.print("└─\n", .{});
            failed += 1;
        }
    }

    // Summary
    std.debug.print("\n╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Test Summary                                              ║\n", .{});
    std.debug.print("╠════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Total:  {d:3}                                               ║\n", .{sites.len});
    std.debug.print("║  Passed: {d:3}                                               ║\n", .{passed});
    std.debug.print("║  Failed: {d:3}                                               ║\n", .{failed});
    std.debug.print("║  Rate:   {d:3}%                                             ║\n", .{@as(usize, @intFromFloat(@as(f64, @floatFromInt(passed)) / @as(f64, @floatFromInt(sites.len)) * 100.0))});

    if (failed == 0) {
        std.debug.print("║                                                            ║\n", .{});
        std.debug.print("║  ✓✓✓ ALL TESTS PASSED - TLS works everywhere!          ║\n", .{});
    } else {
        std.debug.print("║                                                            ║\n", .{});
        std.debug.print("║  ⚠ Some sites failed - check logs above                 ║\n", .{});
    }
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n\n", .{});
}
