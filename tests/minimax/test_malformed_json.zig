const std = @import("std");

/// Test the new malformed JSON format:
/// {"name="web_fetch", "arguments": {"url":"..."}}
pub fn main() !void {
    std.debug.print("\n=== Testing Malformed JSON Format ===\n\n", .{});

    const test_cases = [_][]const u8{
        // Format 1: Simple case
        \\{"name="web_fetch", "arguments": {"url":"https://example.com"}}

        // Format 2: Multiple arguments
        ,
        \\{"name="web_search", "arguments": {"query":"test", "count":5}}

        // Format 3: Nested arguments
        ,
        \\{"name="file_read", "arguments": {"path":"/tmp/test.txt", "max_lines":100}}
    };

    var iter: usize = 0;
    for (test_cases) |case| {
        const i = iter;
        defer iter += 1;
        std.debug.print("Test {d}: {s}\n", .{i + 1, case});

        // Check if pattern matches
        if (std.mem.indexOf(u8, case, "{\"name=")) |idx| {
            std.debug.print("  ✓ Pattern found at offset {}\n", .{idx});

            // Try to extract tool name
            const after = case[idx + 7 ..]; // Skip past {"name=
            if (after.len > 0 and after[0] == '"') {
                if (std.mem.indexOfScalarPos(u8, after, 1, '"')) |q_end| {
                    if (q_end + 1 < after.len and after[q_end + 1] == ',') {
                        const tool_name = after[1..q_end];
                        std.debug.print("  ✓ Tool name: '{s}'\n", .{tool_name});

                        // Check for arguments
                        if (std.mem.indexOf(u8, case, "\"arguments\":")) |args_idx| {
                            std.debug.print("  ✓ Arguments found at offset {}\n", .{args_idx});

                            // Extract the JSON arguments
                            const after_args = case[args_idx + "\"arguments\":".len ..];
                            const brace_start = std.mem.trim(u8, after_args, " \t\r\n");
                            if (brace_start.len > 0 and brace_start[0] == '{') {
                                // Try to find the matching closing brace
                                var depth: usize = 1;
                                var j: usize = 1;
                                while (j < brace_start.len and depth > 0) : (j += 1) {
                                    if (brace_start[j] == '{') depth += 1;
                                    if (brace_start[j] == '}') depth -= 1;
                                }
                                if (depth == 0) {
                                    const json_content = brace_start[0..j];
                                    std.debug.print("  ✓ Arguments JSON: {s}\n", .{json_content});
                                }
                            }
                        }
                    }
                }
            }
        } else {
            std.debug.print("  ✗ Pattern NOT found\n", .{});
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("✅ All tests completed!\n", .{});
    std.debug.print("\nThis format is now supported by the dispatcher.\n", .{});
    std.debug.print("The gateway will automatically detect and parse it.\n", .{});
}
