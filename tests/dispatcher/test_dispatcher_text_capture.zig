const std = @import("std");
const dispatcher = @import("src/agent/dispatcher.zig");

// Test that text before tool calls is captured
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n=== Testing Dispatcher Text Capture ===\n\n", .{});

    // Test 1: MiniMax format with text before tool call
    {
        std.debug.print("Test 1: MiniMax format with text before tool call\n", .{});
        const input = "{\"name\": \"web_fetch\", \"parameter name=\"max_chars\">2000</parameter><parameter name=\"url\">https://example.com</parameter></invoke>";
        const result = try dispatcher.parseXmlToolCalls(allocator, input);
        defer {
            allocator.free(result.text);
            for (result.calls) |call| {
                allocator.free(call.name);
                allocator.free(call.arguments_json);
            }
            allocator.free(result.calls);
        }

        std.debug.print("  Input: {s}\n", .{input});
        std.debug.print("  Tool calls found: {d}\n", .{result.calls.len});
        std.debug.print("  Text returned: '{s}'\n", .{result.text});

        if (result.text.len == 0) {
            std.debug.print("  ✓ PASS: No text returned (as expected)\n\n", .{});
        } else {
            std.debug.print("  ✗ FAIL: Expected empty text, got '{s}'\n\n", .{result.text});
        }
    }

    // Test 2: Valid JSON format with text before tool call
    {
        std.debug.print("Test 2: Valid JSON format with text before tool call\n", .{});
        const input = "Let me fetch that for you. {\"name\": \"web_search\", \"arguments\": {\"query\": \"test\"}}";
        const result = try dispatcher.parseXmlToolCalls(allocator, input);
        defer {
            allocator.free(result.text);
            for (result.calls) |call| {
                allocator.free(call.name);
                allocator.free(call.arguments_json);
            }
            allocator.free(result.calls);
        }

        std.debug.print("  Input: {s}\n", .{input});
        std.debug.print("  Tool calls found: {d}\n", .{result.calls.len});
        std.debug.print("  Text returned: '{s}'\n", .{result.text});

        if (std.mem.indexOf(u8, result.text, "Let me fetch that for you") != null) {
            std.debug.print("  ✓ PASS: Text before tool call captured\n\n", .{});
        } else {
            std.debug.print("  ✗ FAIL: Text before tool call not captured\n\n", .{});
        }
    }

    // Test 3: Text after tool call
    {
        std.debug.print("Test 3: Text after tool call\n", .{});
        const input = "{\"name\": \"web_search\", \"arguments\": {\"query\": \"test\"}} Here are the results.";
        const result = try dispatcher.parseXmlToolCalls(allocator, input);
        defer {
            allocator.free(result.text);
            for (result.calls) |call| {
                allocator.free(call.name);
                allocator.free(call.arguments_json);
            }
            allocator.free(result.calls);
        }

        std.debug.print("  Input: {s}\n", .{input});
        std.debug.print("  Tool calls found: {d}\n", .{result.calls.len});
        std.debug.print("  Text returned: '{s}'\n", .{result.text});

        if (std.mem.indexOf(u8, result.text, "Here are the results") != null) {
            std.debug.print("  ✓ PASS: Text after tool call captured\n\n", .{});
        } else {
            std.debug.print("  ✗ FAIL: Text after tool call not captured\n\n", .{});
        }
    }

    // Test 4: Text before and after tool call
    {
        std.debug.print("Test 4: Text before and after tool call\n", .{});
        const input = "Checking weather. {\"name\": \"web_fetch\", \"arguments\": {\"url\": \"https://weather.com\"}} Done!";
        const result = try dispatcher.parseXmlToolCalls(allocator, input);
        defer {
            allocator.free(result.text);
            for (result.calls) |call| {
                allocator.free(call.name);
                allocator.free(call.arguments_json);
            }
            allocator.free(result.calls);
        }

        std.debug.print("  Input: {s}\n", .{input});
        std.debug.print("  Tool calls found: {d}\n", .{result.calls.len});
        std.debug.print("  Text returned: '{s}'\n", .{result.text});

        const has_before = (std.mem.indexOf(u8, result.text, "Checking weather") != null);
        const has_after = std.mem.indexOf(u8, result.text, "Done") != null;
        if (has_before and has_after) {
            std.debug.print("  ✓ PASS: Both before and after text captured\n\n", .{});
        } else {
            std.debug.print("  ✗ FAIL: Before or after text missing\n\n", .{});
        }
    }

    std.debug.print("=== Test Complete ===\n\n", .{});
    std.debug.print("Summary:\n", .{});
    std.debug.print("  The dispatcher should now capture text BEFORE tool calls.\n", .{});
    std.debug.print("  This prevents tool call JSON from leaking into user messages.\n\n", .{});
}
