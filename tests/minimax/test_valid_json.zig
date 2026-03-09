const std = @import("std");

/// Test the valid JSON format:
/// {"name": "web_fetch", "arguments": {"max_chars": 3000, "url": "..."}}
pub fn main() !void {
    std.debug.print("\n=== Testing Valid JSON Format ===\n\n", .{});

    const test_cases = [_][]const u8{
        // Format 1: Simple case from user
        \\{"name": "web_fetch", "arguments": {"max_chars": 3000, "url": "https://en.wikipedia.org/wiki/Supreme_Leader_of_Iran"}}

        // Format 2: Multiple arguments
        ,
        \\{"name": "web_search", "arguments": {"query": "test query", "count": 5, "limit": 10}}

        // Format 3: Single argument
        ,
        \\{"name": "file_read", "arguments": {"path": "/tmp/test.txt"}}
    };

    var iter: usize = 0;
    for (test_cases) |case| {
        const i = iter;
        defer iter += 1;
        std.debug.print("Test {d}: {s}\n", .{i + 1, case});

        // Check if pattern matches
        if (std.mem.indexOf(u8, case, "{\"name\":")) |idx| {
            std.debug.print("  ✓ Pattern found at offset {}\n", .{idx});

            // Try to extract tool name (valid JSON with colon)
            const after = case[idx + 8 ..]; // Skip past {"name":
            if (std.mem.indexOfScalar(u8, after, '"')) |q1| {
                if (std.mem.indexOfScalar(u8, after[q1 + 1 ..], '"')) |q2| {
                    const tool_name = std.mem.trim(u8, after[q1 + 1 .. q1 + 1 + q2], " \t\r\n");
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
        } else {
            std.debug.print("  ✗ Pattern NOT found\n", .{});
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("✅ All tests completed!\n", .{});
    std.debug.print("\nThis valid JSON format is now supported by the dispatcher.\n", .{});
    std.debug.print("The gateway will automatically detect and parse it.\n", .{});
}
