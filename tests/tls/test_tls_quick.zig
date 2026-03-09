const std = @import("std");

// Quick focused test of critical TLS sites with Google workaround
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Quick TLS Test - With Google Workaround             ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});

    const tls = @import("lib/tls_zig/src/root.zig");

    const sites = [_]struct {
        name: []const u8,
        url: []const u8,
        why: []const u8,
        use_http10: bool, // Workaround for HTTP/2 sites
    }{
        .{ .name = "Hacker News", .url = "https://news.ycombinator.com", .why = "ECDSA cert (was broken)", .use_http10 = false },
        .{ .name = "DuckDuckGo", .url = "https://api.duckduckgo.com", .why = "RSA cert", .use_http10 = false },
        .{ .name = "Wikipedia", .url = "https://en.wikipedia.org", .why = "Major site", .use_http10 = false },
        .{ .name = "GitHub", .url = "https://github.com", .why = "Popular", .use_http10 = false },
        .{ .name = "Google", .url = "https://www.google.com", .why = "HTTP/2 workaround", .use_http10 = true },
    };

    var passed: usize = 0;
    var failed: usize = 0;

    for (sites, 0..) |site, i| {
        std.debug.print("[{d}/{d}] {s}: {s}\n", .{i + 1, sites.len, site.name, site.why});

        const uri = std.Uri.parse(site.url) catch {
            std.debug.print("  ✗ Parse failed\n\n", .{});
            failed += 1;
            continue;
        };

        const host = uri.host.?.percent_encoded;

        var threaded = std.Io.Threaded.init(allocator, .{
            .async_limit = .nothing,
            .concurrent_limit = .nothing,
        });
        defer threaded.deinit();
        const io = threaded.io();

        const host_name = std.Io.net.HostName.init(host) catch {
            std.debug.print("  ✗ Host init failed\n\n", .{});
            failed += 1;
            continue;
        };

        var tcp = host_name.connect(io, 443, .{ .mode = .stream }) catch {
            std.debug.print("  ✗ TCP failed\n\n", .{});
            failed += 1;
            continue;
        };
        defer tcp.close(io);

        var root_ca = tls.config.cert.fromSystem(allocator, io) catch {
            std.debug.print("  ✗ Root CA failed\n\n", .{});
            failed += 1;
            continue;
        };
        defer root_ca.deinit(allocator);

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
        }) catch {
            std.debug.print("  ✗ TLS failed\n\n", .{});
            failed += 1;
            continue;
        };
        defer conn.close() catch {};

        // Workaround: Use HTTP/1.0 for sites that negotiate HTTP/2
        // This prevents ALPN from upgrading to HTTP/2
        var request_buf: [256]u8 = undefined;
        const http_version = if (site.use_http10) "HTTP/1.0" else "HTTP/1.1";
        const request = try std.fmt.bufPrint(&request_buf,
            "HEAD / {s}\r\nHost: {s}\r\nConnection: close\r\nUser-Agent: nullclaw-tls-test/1.0\r\n\r\n",
            .{http_version, host});
        try conn.writeAll(request);

        // Read just first chunk
        const data = (conn.next() catch null) orelse {
            std.debug.print("  ✗ No response\n\n", .{});
            failed += 1;
            continue;
        };

        if (data.len > 0 and std.mem.indexOf(u8, data, "HTTP") != null) {
            std.debug.print("  ✓ SUCCESS ({d} bytes)", .{data.len});
            if (site.use_http10) {
                std.debug.print(" [HTTP/1.0 workaround]", .{});
            }
            std.debug.print("\n\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ✗ Unexpected response\n\n", .{});
            failed += 1;
        }
    }

    std.debug.print("╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Passed: {d}/{d}                                         ║\n", .{passed, sites.len});
    if (passed == sites.len) {
        std.debug.print("║  ✓✓✓ ALL TESTS PASSED (with Google workaround)      ║\n", .{});
    }
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});
}
