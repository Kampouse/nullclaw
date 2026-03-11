const std = @import("std");
const common = @import("common.zig");

pub fn execute(
    allocator: std.mem.Allocator,
    query: []const u8,
    count: usize,
    timeout_secs: u64,
) (common.ProviderSearchError || error{OutOfMemory})!common.ToolResult {
    const log = std.log.scoped(.duckduckgo);
    log.info("Executing DuckDuckGo search for query: '{s}', count: {d}", .{query, count});

    const encoded_query = try common.urlEncode(allocator, query);
    defer allocator.free(encoded_query);

    const url_str = try std.fmt.allocPrint(
        allocator,
        "https://api.duckduckgo.com/?q={s}&format=json&no_html=1&skip_disambig=1",
        .{encoded_query},
    );
    defer allocator.free(url_str);

    log.debug("DuckDuckGo URL: {s}", .{url_str});

    const timeout_str = try common.timeoutToString(allocator, timeout_secs);
    defer allocator.free(timeout_str);

    const headers = [_][]const u8{
        "Accept: application/json",
        "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
    };

    const body = common.curlGet(allocator, url_str, &headers, timeout_str) catch |err| {
        log.err("DuckDuckGo HTTP request failed: {}", .{err});
        common.logRequestError("duckduckgo", query, err);
        return err;
    };
    defer allocator.free(body);

    log.debug("DuckDuckGo response length: {d} bytes", .{body.len});
    if (body.len < 500) {
        log.debug("Response body: {s}", .{body});
    }

    const result = try formatResults(allocator, body, query, count);
    if (!result.success) {
        log.err("Failed to format DuckDuckGo results", .{});
        return error.InvalidResponse;
    }
    const has_results = !std.mem.eql(u8, result.output, "No web results found.");
    log.info("DuckDuckGo search completed: has_results={}", .{has_results});
    return result;
}

pub fn formatResults(allocator: std.mem.Allocator, json_body: []const u8, query: []const u8, count: usize) !common.ToolResult {
    const log = std.log.scoped(.duckduckgo);
    log.debug("Parsing DuckDuckGo response for query: '{s}', count: {d}", .{query, count});
    log.debug("Response body length: {d} bytes", .{json_body.len});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, arena_alloc, json_body, .{}) catch {
        log.err("Failed to parse DuckDuckGo response JSON", .{});
        return common.ToolResult.fail("Failed to parse search response JSON");
    };

    const root_val = switch (parsed.value) {
        .object => |o| o,
        else => {
            log.err("Unexpected DuckDuckGo response format (not an object)", .{});
            return common.ToolResult.fail("Unexpected search response format");
        },
    };

    const max_results = @min(count, 10);
    var entries: [10]common.ResultEntry = undefined;
    var entry_len: usize = 0;

    const heading = common.extractString(root_val, "Heading") orelse "";
    const abstract_text = common.extractString(root_val, "AbstractText") orelse "";
    const abstract_url = common.extractString(root_val, "AbstractURL") orelse "";

    log.debug("Heading: '{s}', AbstractURL: '{s}', AbstractText length: {d}", .{heading, abstract_url, abstract_text.len});

    if (abstract_url.len > 0 and abstract_text.len > 0 and entry_len < max_results) {
        const title = if (heading.len > 0) heading else common.duckduckgoTitleFromText(abstract_text);
        entries[entry_len] = .{
            .title = title,
            .url = abstract_url,
            .description = abstract_text,
        };
        entry_len += 1;
        log.debug("Added abstract result: '{s}'", .{title});
    }

    if (root_val.get("RelatedTopics")) |related_topics| {
        if (related_topics == .array) {
            log.debug("Found RelatedTopics array with {d} items", .{related_topics.array.items.len});
            collectTopics(related_topics.array.items, &entries, &entry_len, max_results);
        } else {
            log.debug("RelatedTopics is not an array", .{});
        }
    } else {
        log.debug("No RelatedTopics field in response", .{});
    }

    log.debug("Total entries collected: {d}", .{entry_len});

    if (entry_len == 0) {
        log.warn("No results found for query: '{s}'. Response keys: ", .{query});
        var key_iter = root_val.iterator();
        while (key_iter.next()) |entry| {
            log.warn("  - {s}", .{entry.key_ptr.*});
        }
        return common.ToolResult.ok("No web results found.");
    }
    return common.formatResultEntries(allocator, query, entries[0..entry_len]);
}

fn collectTopics(
    topics: []const std.json.Value,
    entries: *[10]common.ResultEntry,
    entry_len: *usize,
    max_results: usize,
) void {
    for (topics) |topic| {
        if (entry_len.* >= max_results) return;

        const topic_obj = switch (topic) {
            .object => |o| o,
            else => continue,
        };

        const text = common.extractString(topic_obj, "Text");
        const first_url = common.extractString(topic_obj, "FirstURL");

        if (text != null and first_url != null and text.?.len > 0 and first_url.?.len > 0) {
            entries[entry_len.*] = .{
                .title = common.duckduckgoTitleFromText(text.?),
                .url = first_url.?,
                .description = text.?,
            };
            entry_len.* += 1;
            continue;
        }

        if (topic_obj.get("Topics")) |nested_topics| {
            if (nested_topics == .array) {
                collectTopics(nested_topics.array.items, entries, entry_len, max_results);
            }
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════

const testing = std.testing;

test "DuckDuckGo formatResults parses valid JSON" {
    const json =
        \\{"AbstractText":"Zig is a programming language","AbstractURL":"https://ziglang.org","Heading":"Zig"}
    ;
    const result = try formatResults(testing.allocator, json, "zig", 5);
    defer if (result.owns_output) testing.allocator.free(result.output);

    try testing.expect(result.success);
    try testing.expect(!std.mem.eql(u8, result.output, "No web results found."));
}

test "DuckDuckGo formatResults empty results" {
    const json = "{\"AbstractText\":\"\",\"AbstractURL\":\"\",\"Heading\":\"\",\"RelatedTopics\":[]}";
    const result = try formatResults(testing.allocator, json, "test", 5);
    defer if (result.owns_output) testing.allocator.free(result.output);

    try testing.expect(result.success);
    try testing.expectEqualStrings("No web results found.", result.output);
}

test "DuckDuckGo formatResults with RelatedTopics" {
    const json =
        \\{"Heading":"","AbstractText":"","AbstractURL":"","RelatedTopics":[
        \\  {"Text":"Zig - Programming language","FirstURL":"https://ziglang.org"}
        \\]}
    ;
    const result = try formatResults(testing.allocator, json, "zig", 5);
    defer if (result.owns_output) testing.allocator.free(result.output);

    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, result.output, "Zig") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "ziglang.org") != null);
}
