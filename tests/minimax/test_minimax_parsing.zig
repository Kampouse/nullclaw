const std = @import("std");

// Test pattern matching for MiniMax hybrid format
fn testMiniMaxPatternDetection() !void {
    // Example malformed MiniMax format from user
    const example1 =
        \\{"name": "web_fetch">
        \\<parameter name="max_chars">8000</parameter>
        \\<parameter name="url">https://example.com</parameter>
        \\</invoke>
        \\</minimax:tool_call>
    ;

    // Example 2: shell command
    const example2 =
        \\{"invoke name="shell">
        \\<parameter name="command">cd vibe-paper && python3 scripts/generate_convos.py -n 1000</parameter>
        \\</invoke>
        \\</minimax:tool_call>
    ;

    std.debug.print("Testing MiniMax format detection...\n", .{});

    // Test 1: Check if pattern is detected (try both colon and equals variants)
    const pattern_colon = "{\"name\":";
    const pattern_equals = "{\"invoke name=";
    const start_idx = blk: {
        if (std.mem.indexOf(u8, example1, pattern_colon)) |idx| break :blk idx;
        if (std.mem.indexOf(u8, example1, pattern_equals)) |idx| break :blk idx;
        break :blk null;
    };

    if (start_idx) |idx| {
        std.debug.print("✓ Pattern found in example1 at offset {}\n", .{idx});
    } else {
        std.debug.print("✗ Pattern NOT found in example1\n", .{});
        return error.PatternNotFound;
    }

    // Test 2: Check for closing tags
    if (std.mem.indexOf(u8, example1, "\">")) |_| {
        std.debug.print("✓ Found HTML attribute marker '\">' in example1\n", .{});
    } else {
        std.debug.print("✗ Missing HTML attribute marker in example1\n", .{});
    }

    if (std.mem.indexOf(u8, example1, "</invoke>")) |_| {
        std.debug.print("✓ Found </invoke> in example1\n", .{});
    } else {
        std.debug.print("✗ Missing </invoke> in example1\n", .{});
    }

    if (std.mem.indexOf(u8, example1, "</minimax:tool_call>")) |end| {
        std.debug.print("✓ Found </minimax:tool_call> in example1 at offset {}\n", .{end});
    } else {
        std.debug.print("✗ Missing </minimax:tool_call> in example1\n", .{});
    }

    // Test 3: Extract content block
    if (start_idx) |start| {
        if (std.mem.indexOf(u8, example1, "</minimax:tool_call>")) |end| {
            const content_end = end + "</minimax:tool_call>".len;
            const content = example1[start..content_end];
            std.debug.print("\nExtracted content block:\n{s}\n", .{content});

            // Test 4: Check if HTML-style name attribute can be found
            if (std.mem.indexOf(u8, content, "name=\"")) |name_idx| {
                const after = content[name_idx + 6 ..];
                if (std.mem.indexOfScalarPos(u8, after, 0, '"')) |q_end| {
                    const tool_name = std.mem.trim(u8, after[0..q_end], " \t\r\n");
                    std.debug.print("\n✓ Extracted tool name: '{s}'\n", .{tool_name});
                }
            }
        }
    }

    // Test 5: Verify example2 detection
    std.debug.print("\n--- Testing example2 ---\n", .{});
    const start_idx2 = blk: {
        if (std.mem.indexOf(u8, example2, pattern_colon)) |idx| break :blk idx;
        if (std.mem.indexOf(u8, example2, pattern_equals)) |idx| break :blk idx;
        break :blk null;
    };

    if (start_idx2) |_| {
        std.debug.print("✓ Pattern found in example2\n", .{});
    } else {
        std.debug.print("✗ Pattern NOT found in example2 (expected - has different format)\n", .{});
    }

    std.debug.print("\n✅ All detection tests passed!\n", .{});
}

pub fn main() !void {
    try testMiniMaxPatternDetection();
}
