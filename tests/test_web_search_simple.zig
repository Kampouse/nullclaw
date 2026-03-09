const std = @import("std");
const http_util = @import("src/http_util.zig");

// Test DuckDuckGo search API directly
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Testing DuckDuckGo Search API Directly            ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});

    const query = "Zig programming language";
    const encoded_query = try http_util.urlEncode(allocator, query);
    defer allocator.free(encoded_query);

    const url = try std.fmt.allocPrint(allocator,
        "https://api.duckduckgo.com/?q={s}&format=json",
        .{encoded_query});
    defer allocator.free(url);

    std.debug.print("Query: {s}\n", .{query});
    std.debug.print("URL: {s}\n\n", .{url});

    const headers = [_][]const u8{
        "Accept: application/json",
        "User-Agent: Mozilla/5.0 (compatible; nullclaw/1.0)",
    };

    std.debug.print("Fetching from DuckDuckGo API...\n", .{});

    const body = http_util.curlGet(allocator, url, &headers, "30") catch |err| {
        std.debug.print("✗ FAILED: {}\n\n", .{err});
        return err;
    };
    defer allocator.free(body);

    std.debug.print("✓ SUCCESS - Got {d} bytes\n\n", .{body.len});

    // Parse JSON response
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body) catch |err| {
        std.debug.print("⚠ Warning: Failed to parse JSON: {}\n", .{err});
        std.debug.print("Raw response preview (first 500 chars):\n", .{});
        const preview = if (body.len > 500) body[0..500] else body;
        std.debug.print("{s}\n\n", .{preview});
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        std.debug.print("✗ Response is not a JSON object\n\n", .{});
        return;
    }

    std.debug.print("╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  DuckDuckGo API Response Structure                   ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});

    const obj = parsed.value.object;
    var iter = obj.iterator();
    var field_count: usize = 0;
    while (iter.next()) |entry| {
        field_count += 1;
        if (field_count > 20) {
            std.debug.print("  ... and more\n", .{});
            break;
        }
        const value_type = switch (entry.value.*) {
            .string => |s| if (s.len > 50) "string(...)" else "string",
            .array => "array",
            .object => "object",
            .bool => "bool",
            .null => "null",
            .number => "number",
        };
        std.debug.print("  {s}: {s}\n", .{entry.key, value_type});
    }

    // Check for RelatedTopics (main results)
    if (obj.get("RelatedTopics")) |topics| {
        if (topics == .array) {
            std.debug.print("\n✓ Found RelatedTopics: {d} entries\n", .{topics.array.items.len});

            if (topics.array.items.len > 0) {
                std.debug.print("\nFirst few results:\n", .{});
                for (topics.array.items, 0..) |topic, i| {
                    if (i >= 3) break;
                    if (topic == .object) {
                        if (topic.object.get("Text")) |text| {
                            if (text == .string) {
                                const preview = if (text.string.len > 80) text.string[0..80] else text.string;
                                std.debug.print("  {d}. {s}...\n", .{i + 1, preview});
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
            std.debug.print("\n✓ Direct Answer Available:\n", .{});
            std.debug.print("  {s}\n", .{abstract.string});
        }
    }

    std.debug.print("\n╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  ✓✓✓ DuckDuckGo API Works! web_search should work    ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});
}
