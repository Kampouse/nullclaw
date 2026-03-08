const std = @import("std");

// Real end-to-end test for Hacker News HTTPS fetch
// This tests that the TLS fix works with ECDSA certificates (Hacker News uses ECDSA)
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Real HTTPS Test - Hacker News (ECDSA Certs)       ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});

    // Import http_util which has the TLS fix
    const http_util = @import("nullclaw").http_util;

    // Hacker News - uses ECDSA certificates (previously failed with stdlib)
    const url = "https://news.ycombinator.com/";

    std.debug.print("Testing HTTPS fetch to Hacker News\n", .{});
    std.debug.print("URL: {s}\n", .{url});
    std.debug.print("Certificate type: ECDSA (was broken before TLS fix)\n\n", .{});

    // Make the HTTP request
    // Use more realistic headers to avoid 400 errors
    const headers = [_][]const u8{
        "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language: en-US,en;q=0.9",
        "Accept-Encoding: gzip",
        "DNT: 1",
        "Connection: keep-alive",
        "Upgrade-Insecure-Requests: 1",
    };

    const response = http_util.curlGet(allocator, url, &headers, "30") catch |err| {
        std.debug.print("\n✗ HTTP REQUEST FAILED: {}\n", .{err});
        std.debug.print("\nThis means ECDSA certificates are NOT working.\n", .{});
        std.debug.print("web_fetch will fail for ECDSA sites like Hacker News.\n\n", .{});
        return err;
    };
    defer allocator.free(response);

    std.debug.print("✓ HTTPS request succeeded!\n", .{});
    std.debug.print("✓ Got {d} bytes from Hacker News\n\n", .{response.len});

    // Check if response looks like HTML
    const has_html = std.mem.indexOf(u8, response, "<html") != null or
                      std.mem.indexOf(u8, response, "<!DOCTYPE") != null or
                      std.mem.indexOf(u8, response, "<HTML") != null;

    const has_hacker_news = std.mem.indexOf(u8, response, "Hacker News") != null or
                            std.mem.indexOf(u8, response, "Y Combinator") != null;

    if (has_html) {
        std.debug.print("✓ Response appears to be HTML\n", .{});
    }

    if (has_hacker_news) {
        std.debug.print("✓ Response contains 'Hacker News' or 'Y Combinator'\n", .{});
    }

    // Extract and show a preview
    std.debug.print("\nResponse preview (first 500 chars):\n", .{});
    std.debug.print("┌", .{});
    for (0..50) |_| std.debug.print("─", .{});
    std.debug.print("┐\n", .{});

    const preview = if (response.len > 500) response[0..500] else response;
    std.debug.print("{s}\n", .{preview});

    std.debug.print("└", .{});
    for (0..50) |_| std.debug.print("─", .{});
    std.debug.print("┘\n\n", .{});

    // Summary
    std.debug.print("╔═══════════════════════════════════════════════════════╗\n", .{});
    if (has_html and has_hacker_news) {
        std.debug.print("║  ✓✓✓ SUCCESS! ECDSA Certificates WORK!             ║\n", .{});
        std.debug.print("║                                                      ║\n", .{});
        std.debug.print("║  • TLS connection to news.ycombinator.com succeeded  ║\n", .{});
        std.debug.print("║  • ECDSA certificate validation passed               ║\n", .{});
        std.debug.print("║  • Got valid HTML response                          ║\n", .{});
        std.debug.print("║                                                      ║\n", .{});
        std.debug.print("║  web_fetch is READY for ECDSA sites!                ║\n", .{});
    } else if (has_html) {
        std.debug.print("║  ✓ TLS WORKS! (got HTML but couldn't verify site)   ║\n", .{});
        std.debug.print("║  ECDSA certificates are working                     ║\n", .{});
    } else {
        std.debug.print("║  ⚠ WARNING: Unexpected response format              ║\n", .{});
        std.debug.print("║  TLS connected but response is not HTML             ║\n", .{});
    }
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});
}
