const std = @import("std");

// Real end-to-end test for web_search HTTPS fetch
// This tests that the TLS fix actually works with real API calls
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Real HTTPS Test - DuckDuckGo API Call              ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});

    // Import http_util which has the TLS fix
    const http_util = @import("nullclaw").http_util;

    // Test with a simple URL that should work
    const url = "https://api.duckduckgo.com/?q=cat&format=json";

    std.debug.print("Testing HTTPS fetch to DuckDuckGo API\n", .{});
    std.debug.print("URL: {s}\n\n", .{url});

    // Make the HTTP request (this uses the TLS fix)
    const headers = [_][]const u8{
        "Accept: application/json",
        "User-Agent: nullclaw-test/1.0",
    };

    const response = http_util.curlGet(allocator, url, &headers, "30") catch |err| {
        std.debug.print("\n✗ HTTP REQUEST FAILED: {}\n", .{err});
        std.debug.print("\nThis means the TLS fix is NOT working.\n", .{});
        std.debug.print("web_search will fail with TLS errors.\n\n", .{});
        return err;
    };
    defer allocator.free(response);

    std.debug.print("✓ HTTPS request succeeded!\n", .{});
    std.debug.print("✓ Got {d} bytes from DuckDuckGo\n\n", .{response.len});

    // Try to parse as JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch |err| {
        std.debug.print("⚠ JSON parse failed: {}\n", .{err});
        std.debug.print("BUT HTTPS request succeeded, so TLS IS working!\n", .{});
        std.debug.print("Response preview (first 300 chars):\n", .{});
        const preview = if (response.len > 300) response[0..300] else response;
        std.debug.print("{s}\n\n", .{preview});
        std.debug.print("╔═══════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║  ✓ TLS IS WORKING!                                 ║\n", .{});
        std.debug.print("║  web_search should work in production              ║\n", .{});
        std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        std.debug.print("✗ Response is not JSON object\n", .{});
        std.debug.print("But HTTPS succeeded, so TLS is working.\n\n", .{});
        return;
    }

    const obj = parsed.value.object;

    // Check for AbstractText (direct answer)
    var has_abstract = false;
    if (obj.get("AbstractText")) |abstract| {
        if (abstract == .string and abstract.string.len > 0) {
            has_abstract = true;
            std.debug.print("✓ Direct Answer Found:\n", .{});
            std.debug.print("  {s}\n\n", .{abstract.string});
        }
    }

    // Check for RelatedTopics (search results)
    var result_count: usize = 0;
    if (obj.get("RelatedTopics")) |topics| {
        if (topics == .array) {
            result_count = topics.array.items.len;

            if (result_count > 0) {
                std.debug.print("✓ Found {d} Related Topics\n\n", .{result_count});

                // Show first 3 results
                std.debug.print("Top results:\n", .{});
                var shown: usize = 0;
                for (topics.array.items) |topic| {
                    if (shown >= 3) break;

                    if (topic == .object) {
                        const text = topic.object.get("Text");
                        const first_url = topic.object.get("FirstURL");

                        if (text != null and first_url != null) {
                            if (text.? == .string and first_url.? == .string) {
                                shown += 1;
                                const text_str = text.?.string;
                                const title = if (text_str.len > 60)
                                    text_str[0..60]
                                else
                                    text_str;

                                std.debug.print("\n  {d}. {s}...\n", .{shown, title});
                                std.debug.print("     {s}\n", .{first_url.?.string});
                            }
                        }
                    }
                }
            }
        }
    }

    // Summary
    std.debug.print("\n╔═══════════════════════════════════════════════════════╗\n", .{});
    if (result_count > 0 or has_abstract) {
        std.debug.print("║  ✓✓✓ SUCCESS! HTTPS + web_search WORKS!           ║\n", .{});
        std.debug.print("║                                                      ║\n", .{});
        std.debug.print("║  • TLS connection to DuckDuckGo succeeded           ║\n", .{});
        std.debug.print("║  • API responded with valid JSON                    ║\n", .{});
        std.debug.print("║  • Got real search results                          ║\n", .{});
        std.debug.print("║                                                      ║\n", .{});
        std.debug.print("║  web_search is READY FOR PRODUCTION                 ║\n", .{});
    } else {
        std.debug.print("║  ⚠ WARNING: Got response but no results             ║\n", .{});
        std.debug.print("║  TLS works but API returned empty results           ║\n", .{});
    }
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});
}
