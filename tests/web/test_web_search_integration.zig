const std = @import("std");

// Integration test for web_search - makes real API calls
// This bypasses the builtin.is_test check to test actual network functionality
const http_util = @import("src/http_util.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Web Search Integration Test - Real API Calls        ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});

    // Test 1: DuckDuckGo API
    std.debug.print("Test 1: DuckDuckGo Search API\n", .{});
    std.debug.print("─────────────────────────────────────────────────────\n", .{});

    const query = "Zig programming language";
    const encoded_query = try http_util.urlEncode(allocator, query);
    defer allocator.free(encoded_query);

    const url = try std.fmt.allocPrint(allocator,
        "https://api.duckduckgo.com/?q={s}&format=json&no_html=1&skip_disambig=1",
        .{encoded_query});
    defer allocator.free(url);

    std.debug.print("Query: {s}\n", .{query});
    std.debug.print("URL: {s}\n\n", .{url});

    const headers = [_][]const u8{
        "Accept: application/json",
    };

    std.debug.print("Fetching from DuckDuckGo API...\n", .{});

    const body = http_util.curlGet(allocator, url, &headers, "30") catch |err| {
        std.debug.print("✗ FAILED: {}\n\n", .{err});
        std.debug.print("This means TLS is not working for DuckDuckGo.\n", .{});
        std.debug.print("Check http_util.zig curlGetWithProxy implementation.\n\n", .{});
        return err;
    };
    defer allocator.free(body);

    std.debug.print("✓ SUCCESS - Got {d} bytes from DuckDuckGo\n\n", .{body.len});

    // Parse JSON response
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body) catch |err| {
        std.debug.print("⚠ Warning: Failed to parse JSON: {}\n", .{err});
        std.debug.print("This means the API response changed, but TLS works.\n\n", .{});
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        std.debug.print("✗ Response is not a JSON object\n\n", .{});
        return;
    }

    const obj = parsed.value.object;

    // Check for results
    var result_count: usize = 0;
    if (obj.get("RelatedTopics")) |topics| {
        if (topics == .array) {
            result_count = topics.array.items.len;
            std.debug.print("✓ Found RelatedTopics: {d} entries\n", .{result_count});

            if (result_count > 0) {
                std.debug.print("\nFirst result:\n", .{});
                for (topics.array.items, 0..) |topic, i| {
                    if (i >= 1) break;
                    if (topic == .object) {
                        if (topic.object.get("Text")) |text| {
                            if (text == .string) {
                                const preview = if (text.string.len > 80) text.string[0..80] else text.string;
                                std.debug.print("  {s}...\n", .{preview});
                            }
                        }
                        if (topic.object.get("FirstURL")) |url_val| {
                            if (url_val == .string) {
                                std.debug.print("  URL: {s}\n", .{url_val.string});
                            }
                        }
                    }
                }
            }
        }
    }

    // Check for AbstractTopic (direct answer)
    if (obj.get("AbstractText")) |abstract| {
        if (abstract == .string and abstract.string.len > 0) {
            std.debug.print("\n✓ Direct Answer Available\n", .{});
        }
    }

    std.debug.print("\n╔═══════════════════════════════════════════════════════╗\n", .{});
    if (result_count > 0) {
        std.debug.print("║  ✓✓✓ WEB SEARCH WORKS!                             ║\n", .{});
        std.debug.print("║  TLS + DuckDuckGo API + JSON parsing = SUCCESS      ║\n", .{});
        std.debug.print("║  web_search tool should work in production          ║\n", .{});
    } else {
        std.debug.print("║  ⚠ WARNING: No results found                       ║\n", .{});
        std.debug.print("║  TLS works but API returned no results              ║\n", .{});
    }
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});
}
