const std = @import("std");

// Test web_fetch with Hacker News to see if the extracted content is good
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Testing web_fetch Content Extraction               ║\n", .{});
    std.debug.print("║  Hacker News - What the AI actually sees            ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});

    // Import web_fetch tool
    const web_fetch_mod = @import("nullclaw").tools.web_fetch;

    var tool = web_fetch_mod.WebFetchTool{};

    const url = "https://news.ycombinator.com/";
    std.debug.print("Fetching: {s}\n", .{url});
    std.debug.print("This will convert HTML to readable markdown...\n\n", .{});

    // Execute web_fetch with direct args
    const args_json = try std.fmt.allocPrint(allocator, "{{\"url\":\"{s}\"}}", .{url});
    defer allocator.free(args_json);

    const args_obj = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer args_obj.deinit();

    const result = try tool.execute(allocator, args_obj.value.object);

    defer {
        if (result.owns_output) allocator.free(result.output);
        if (result.owns_error_msg) {
            if (result.error_msg) |msg| allocator.free(msg);
        }
    }

    if (!result.success) {
        std.debug.print("✗ web_fetch failed\n", .{});
        if (result.error_msg) |msg| {
            std.debug.print("Error: {s}\n", .{msg});
        }
        return error.FetchFailed;
    }

    std.debug.print("✓ web_fetch succeeded!\n", .{});
    std.debug.print("✓ Extracted {d} characters\n\n", .{result.output.len});

    // Show the content
    std.debug.print("╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  EXTRACTED CONTENT (What the AI sees)               ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});

    // Show first 2000 chars
    const preview_len = @min(2000, result.output.len);
    std.debug.print("{s}\n\n", .{result.output[0..preview_len]});

    if (result.output.len > preview_len) {
        std.debug.print("... ({d} more characters truncated)\n\n", .{result.output.len - preview_len});
    }

    // Analyze the content
    std.debug.print("╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  CONTENT ANALYSIS                                    ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n\n", .{});

    // Check for good signs
    const has_headings = std.mem.indexOf(u8, result.output, "#") != null;
    const has_links = std.mem.indexOf(u8, result.output, "](") != null;
    const has_numbers = std.mem.indexOf(u8, result.output, "1.") != null or std.mem.indexOf(u8, result.output, "2.") != null;
    const no_script = std.mem.indexOf(u8, result.output, "script") == null;
    const no_style = std.mem.indexOf(u8, result.output, "style") == null;
    const no_nav = std.mem.indexOf(u8, result.output, "navigation") == null;
    const readable = result.output.len > 500 and result.output.len < 100000;

    std.debug.print("Has headings:             {s}\n", .{if (has_headings) "✓" else "✗"});
    std.debug.print("Has links:                {s}\n", .{if (has_links) "✓" else "✗"});
    std.debug.print("Has numbered lists:       {s}\n", .{if (has_numbers) "✓" else "✗"});
    std.debug.print("No <script> tags:         {s}\n", .{if (no_script) "✓" else "✗"});
    std.debug.print("No <style> tags:          {s}\n", .{if (no_style) "✓" else "✗"});
    std.debug.print("No navigation spam:       {s}\n", .{if (no_nav) "✓" else "✗"});
    std.debug.print("Reasonable length:        {s}\n", .{if (readable) "✓" else "✗"});
    std.debug.print("\n", .{});

    const score = [_]bool{ has_headings, has_links, has_numbers, no_script, no_style, no_nav, readable };
    var passed: usize = 0;
    for (score) |s| {
        if (s) passed += 1;
    }

    std.debug.print("Quality Score: {d}/7\n", .{passed});
    if (passed >= 5) {
        std.debug.print("\n✓✓✓ Content quality is GOOD!\n", .{});
        std.debug.print("The AI will get clean, readable content from Hacker News.\n", .{});
    } else {
        std.debug.print("\n⚠ Content quality could be better\n", .{});
    }
    std.debug.print("\n", .{});
}
