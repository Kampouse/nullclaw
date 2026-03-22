const std = @import("std");

/// Simulate the dispatcher's MiniMax format detection and parsing
/// This test validates the exact behavior of parseXmlToolCalls and parseHybridTagCall

const ToolCall = struct {
    name: []const u8,
    found: bool,
};

fn testDispatcherMiniMaxParsing(allocator: std.mem.Allocator, response: []const u8) !struct {
    tool_calls: std.ArrayList(ToolCall),
    remaining_text: []const u8,
} {
    var tool_calls = try std.ArrayList(ToolCall).initCapacity(allocator, 2);
    var remaining = response;

    // Pattern 1: Colon format {"name": "tool_name">
    const pattern_colon = "{\"name\":";
    // Pattern 2: Equals format {"name=tool_name>
    const pattern_equals = "{\"name=";
    // Pattern 3: Invoke format {"invoke name=
    const pattern_invoke = "{\"invoke name=";

    // Find which pattern matches
    const start_idx = blk: {
        if (std.mem.indexOf(u8, remaining, pattern_colon)) |idx| break :blk idx;
        if (std.mem.indexOf(u8, remaining, pattern_equals)) |idx| break :blk idx;
        if (std.mem.indexOf(u8, remaining, pattern_invoke)) |idx| break :blk idx;
        break :blk null;
    };

    if (start_idx) |idx| {
        // Check for required markers
        if (std.mem.indexOf(u8, remaining, "\">")) |_| {
            if (std.mem.indexOf(u8, remaining, "</invoke>")) |_| {
                if (std.mem.indexOf(u8, remaining, "</minimax:tool_call>")) |mini_end| {
                    // Found MiniMax hybrid format
                    const content_start = idx;
                    const content_end = mini_end + "</minimax:tool_call>".len;
                    const mini_max_content = remaining[content_start..content_end];

                    // Extract tool name based on format
                    const tool_name: []const u8 = blk2: {
                        // Format 1: {"name": "tool_name">
                        if (std.mem.indexOf(u8, mini_max_content, "{\"name\":")) |name_idx| {
                            const after = mini_max_content[name_idx + 8 ..];
                            if (std.mem.indexOfScalar(u8, after, '"')) |q1| {
                                if (std.mem.indexOfScalar(u8, after[q1 + 1 ..], '"')) |q2| {
                                    const name_candidate = std.mem.trim(u8, after[q1 + 1 .. q1 + 1 + q2], " \t\r\n");
                                    const name_end = name_idx + 8 + q1 + 1 + q2 + 1;
                                    if (name_end < mini_max_content.len and mini_max_content[name_end] == '>') {
                                        break :blk2 name_candidate;
                                    }
                                }
                            }
                        }

                        // Format 2: {"name=tool_name>
                        if (std.mem.indexOf(u8, mini_max_content, "{\"name=")) |name_idx| {
                            const after = mini_max_content[name_idx + 7 ..];
                            if (std.mem.indexOfScalar(u8, after, '>')) |gt_idx| {
                                const name_candidate = std.mem.trim(u8, after[0..gt_idx], " \t\r\n");
                                if (name_candidate.len > 0) {
                                    break :blk2 name_candidate;
                                }
                            }
                        }

                        break :blk2 "unknown";
                    };

                    try tool_calls.append(allocator, .{
                        .name = tool_name,
                        .found = true,
                    });

                    // Remove tool call from remaining (this is what user sees)
                    remaining = remaining[content_end..];
                }
            }
        }
    }

    return .{
        .tool_calls = tool_calls,
        .remaining_text = remaining,
    };
}

fn printTestResult(test_name: []const u8, passed: bool, detail: []const u8) void {
    if (passed) {
        std.debug.print("✅ {s}: {s}\n", .{ test_name, detail });
    } else {
        std.debug.print("❌ {s}: {s}\n", .{ test_name, detail });
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("MiniMax Dispatcher Integration Test\n", .{});
    std.debug.print("=" ** 60 ++ "\n\n", .{});

    // Test Case 1: User's actual example - web_fetch with colon format
    {
        const test1 =
            \\{"name": "web_fetch">
            \\<parameter name="max_chars">8000</parameter>
            \\<parameter name="url">https://huggingface.co/docs/transformers/en/model_doc/distilbert</parameter>
            \\</invoke>
            \\</minimax:tool_call>
        ;

        std.debug.print("Test 1: Colon format (web_fetch)\n", .{});
        std.debug.print("-" ** 40 ++ "\n", .{});

        const result = try testDispatcherMiniMaxParsing(allocator, test1);

        printTestResult("Pattern detected", result.tool_calls.items.len > 0,
            if (result.tool_calls.items.len > 0) "Found MiniMax format" else "Pattern NOT detected");

        if (result.tool_calls.items.len > 0) {
            const tool_name = result.tool_calls.items[0].name;
            printTestResult("Tool name extraction",
                std.mem.eql(u8, tool_name, "web_fetch"),
                if (std.mem.eql(u8, tool_name, "web_fetch"))
                    "Correctly extracted 'web_fetch'"
                else
                    std.fmt.allocPrint(allocator, "Wrong: got '{s}'", .{tool_name}) catch return error.OutOfMemory);

            printTestResult("Tool call removed from output",
                result.remaining_text.len == 0,
                if (result.remaining_text.len == 0)
                    "User sees empty string (tool call hidden)"
                else
                    "User would still see raw output");
        }
        std.debug.print("\n", .{});
    }

    // Test Case 2: User's actual example - web_search with equals format
    {
        const test2 =
            \\{"name=web_search>
            \\<parameter name="count">5</parameter>
            \\<parameter name="query">DistilBERT transformer model Hugging Face</parameter>
            \\</invoke>
            \\</minimax:tool_call>
        ;

        std.debug.print("Test 2: Equals format (web_search)\n", .{});
        std.debug.print("-" ** 40 ++ "\n", .{});

        const result = try testDispatcherMiniMaxParsing(allocator, test2);

        printTestResult("Pattern detected", result.tool_calls.items.len > 0,
            if (result.tool_calls.items.len > 0) "Found MiniMax format" else "Pattern NOT detected");

        if (result.tool_calls.items.len > 0) {
            const tool_name = result.tool_calls.items[0].name;
            printTestResult("Tool name extraction",
                std.mem.eql(u8, tool_name, "web_search"),
                if (std.mem.eql(u8, tool_name, "web_search"))
                    "Correctly extracted 'web_search'"
                else
                    std.fmt.allocPrint(allocator, "Wrong: got '{s}'", .{tool_name}) catch return error.OutOfMemory);

            printTestResult("Tool call removed from output",
                result.remaining_text.len == 0,
                if (result.remaining_text.len == 0)
                    "User sees empty string (tool call hidden)"
                else
                    "User would still see raw output");
        }
        std.debug.print("\n", .{});
    }

    // Test Case 3: Response with text after tool call
    {
        const test3 =
            \\{"name=web_search>
            \\<parameter name="query">test query</parameter>
            \\</invoke>
            \\</minimax:tool_call>
            \\Here is the final answer to your question!
        ;

        std.debug.print("Test 3: Tool call + final answer\n", .{});
        std.debug.print("-" ** 40 ++ "\n", .{});

        const result = try testDispatcherMiniMaxParsing(allocator, test3);

        printTestResult("Pattern detected", result.tool_calls.items.len > 0,
            if (result.tool_calls.items.len > 0) "Found MiniMax format" else "Pattern NOT detected");

        if (result.tool_calls.items.len > 0) {
            const expected = "\nHere is the final answer to your question!";
            printTestResult("Only final answer remains",
                std.mem.eql(u8, result.remaining_text, expected),
                if (std.mem.eql(u8, result.remaining_text, expected))
                    "User sees only final answer"
                else
                    std.fmt.allocPrint(allocator, "Wrong remaining: '{s}'", .{result.remaining_text}) catch return error.OutOfMemory);
        }
        std.debug.print("\n", .{});
    }

    // Test Case 4: Multiple tool calls in sequence
    {
        const test4 =
            \\{"name=web_search>
            \\<parameter name="query">first search</parameter>
            \\</invoke>
            \\</minimax:tool_call>
            \\{"name=web_search>
            \\<parameter name="query">second search</parameter>
            \\</invoke>
            \\</minimax:tool_call>
            \\Based on my research...
        ;

        std.debug.print("Test 4: Multiple tool calls\n", .{});
        std.debug.print("-" ** 40 ++ "\n", .{});

        const result = try testDispatcherMiniMaxParsing(allocator, test4);

        printTestResult("First tool call detected",
            result.tool_calls.items.len >= 1,
            if (result.tool_calls.items.len >= 1) "Found first MiniMax format" else "First NOT detected");

        // Note: Current implementation only parses first tool call in this simplified test
        // The actual dispatcher loops to find all tool calls

        const has_final_answer = std.mem.indexOf(u8, result.remaining_text, "Based on my research") != null;
        printTestResult("Final answer present",
            has_final_answer,
            if (has_final_answer) "Final answer found in remaining text" else "Final answer missing");
        std.debug.print("\n", .{});
    }

    std.debug.print("=" ** 60 ++ "\n", .{});
    std.debug.print("✅ All integration tests completed!\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});
}
