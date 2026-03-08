const std = @import("std");

/// Simulate the tool name extraction logic from parseHybridTagCall
fn extractToolName(content: []const u8) ![]const u8 {
    // SPECIAL CASE: MiniMax format starts with {"name": "tool_name">
    if (std.mem.indexOf(u8, content, "{\"name\":")) |idx| {
        const after = content[idx + 8 ..]; // Skip past {"name":
        if (std.mem.indexOfScalar(u8, after, '"')) |q1| {
            if (std.mem.indexOfScalar(u8, after[q1 + 1 ..], '"')) |q2| {
                const name_candidate = std.mem.trim(u8, after[q1 + 1 .. q1 + 1 + q2], " \t\r\n");
                // Verify this is followed by > (MiniMax format marker)
                const name_end = idx + 8 + q1 + 1 + q2 + 1;
                if (name_end < content.len and content[name_end] == '>') {
                    return name_candidate;
                }
            }
        }
    }
    return error.ToolNameNotFound;
}

fn testMiniMaxFormats() !void {
    std.debug.print("\n=== Testing MiniMax Format Detection and Parsing ===\n\n", .{});

    // Test case 1: web_fetch with colon format
    const test1 =
        \\{"name": "web_fetch">
        \\<parameter name="max_chars">8000</parameter>
        \\<parameter name="url">https://example.com</parameter>
        \\</invoke>
        \\</minimax:tool_call>
    ;

    std.debug.print("Test 1: web_fetch (colon format)\n", .{});
    std.debug.print("----------------------------------------\n", .{});
    if (extractToolName(test1)) |tool_name| {
        std.debug.print("✓ Detected tool name: '{s}'\n", .{tool_name});
        if (std.mem.eql(u8, tool_name, "web_fetch")) {
            std.debug.print("✅ CORRECT!\n", .{});
        } else {
            std.debug.print("❌ WRONG! Expected 'web_fetch'\n", .{});
        }
    } else |_| {
        std.debug.print("✗ Failed to extract tool name\n", .{});
    }

    // Test case 2: shell command with equals format
    const test2 =
        \\{"invoke name="shell">
        \\<parameter name="command">ls -la</parameter>
        \\</invoke>
        \\</minimax:tool_call>
    ;

    std.debug.print("\nTest 2: shell (equals format)\n", .{});
    std.debug.print("----------------------------\n", .{});
    if (std.mem.indexOf(u8, test2, "{\"invoke name=")) |idx| {
        std.debug.print("✓ Pattern detected at offset {} (equals format)\n", .{idx});
        std.debug.print("⚠️  Note: This format uses invoke, not direct name\n", .{});
    } else {
        std.debug.print("✗ Pattern not detected\n", .{});
    }

    // Test case 3: Multiple parameters
    const test3 =
        \\{"name": "search">
        \\<parameter name="query">zig language</parameter>
        \\<parameter name="limit">10</parameter>
        \\</invoke>
        \\</minimax:tool_call>
    ;

    std.debug.print("\nTest 3: search with multiple parameters\n", .{});
    std.debug.print("------------------------------------------\n", .{});
    if (extractToolName(test3)) |tool_name| {
        std.debug.print("✓ Detected tool name: '{s}'\n", .{tool_name});
        if (std.mem.eql(u8, tool_name, "search")) {
            std.debug.print("✅ CORRECT!\n", .{});
        } else {
            std.debug.print("❌ WRONG! Expected 'search'\n", .{});
        }
    } else |_| {
        std.debug.print("✗ Failed to extract tool name\n", .{});
    }

    // Test case 4: Format detection markers
    std.debug.print("\nTest 4: Verify format markers\n", .{});
    std.debug.print("-------------------------------\n", .{});
    const Marker = struct { pattern: []const u8, name: []const u8 };
    const markers = [_]Marker{
        .{ .pattern = "{\"name\":", .name = "MiniMax colon pattern" },
        .{ .pattern = "{\"invoke name=", .name = "MiniMax equals pattern" },
        .{ .pattern = "\">", .name = "HTML attribute close" },
        .{ .pattern = "</invoke>", .name = "Invoke close tag" },
        .{ .pattern = "</minimax:tool_call>", .name = "MiniMax close tag" },
    };

    for (markers) |marker| {
        if (std.mem.indexOf(u8, test1, marker.pattern)) |idx| {
            std.debug.print("✓ Found {s} at offset {}\n", .{ marker.name, idx });
        } else {
            std.debug.print("✗ Missing {s}\n", .{marker.name});
        }
    }

    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("✅ All tests completed!\n", .{});
}

pub fn main() !void {
    try testMiniMaxFormats();
}
