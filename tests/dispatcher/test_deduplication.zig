const std = @import("std");

/// Test deduplication logic to verify the optimization works correctly
/// This simulates what happens in dispatcher.zig when duplicate tool calls are detected

const ParsedToolCall = struct {
    name: []const u8,
    arguments_json: []const u8,
};

const trackToolCall = struct {
    fn track(alloc: std.mem.Allocator, seen: *std.StringHashMap(void), call: ParsedToolCall) !bool {
        const key = std.fmt.allocPrint(alloc, "{s}|{s}", .{call.name, call.arguments_json}) catch return false;
        errdefer alloc.free(key);

        // getOrPut returns whether the key was already present
        const gop = try seen.getOrPut(key);
        if (gop.found_existing) {
            // Key already exists - this is a duplicate, free our key
            alloc.free(key);
            return true; // Is duplicate
        }
        // Key was inserted - not a duplicate, key is now owned by hashmap
        return false; // Not duplicate
    }
};

pub fn main() !void {
    std.debug.print("\n=== Testing Deduplication Optimization ===\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Track seen tool calls
    var seen_calls = std.StringHashMap(void).init(allocator);
    defer seen_calls.deinit();

    // Test 1: Same tool, same arguments (should be duplicate)
    std.debug.print("Test 1: Duplicate detection\n", .{});
    {
        const call1 = ParsedToolCall{
            .name = "web_fetch",
            .arguments_json = "{\"url\":\"https://example.com\"}",
        };

        const is_dup1 = try trackToolCall.track(allocator, &seen_calls, call1);
        std.debug.print("  First call: duplicate={}\n", .{is_dup1});
        if (is_dup1) {
            std.debug.print("  ✗ FAILED: First call should not be duplicate\n", .{});
            return error.TestFailed;
        }

        const is_dup2 = try trackToolCall.track(allocator, &seen_calls, call1);
        std.debug.print("  Second call (same): duplicate={}\n", .{is_dup2});
        if (!is_dup2) {
            std.debug.print("  ✗ FAILED: Second call should be duplicate\n", .{});
            return error.TestFailed;
        }

        std.debug.print("  ✓ PASSED: Duplicate correctly detected\n\n", .{});
    }

    // Test 2: Same tool, different arguments (should NOT be duplicate)
    std.debug.print("Test 2: Different arguments\n", .{});
    {
        const call2 = ParsedToolCall{
            .name = "web_fetch",
            .arguments_json = "{\"url\":\"https://different.com\"}",
        };

        const is_dup = try trackToolCall.track(allocator, &seen_calls, call2);
        std.debug.print("  Same tool, different args: duplicate={}\n", .{is_dup});
        if (is_dup) {
            std.debug.print("  ✗ FAILED: Different arguments should not be duplicate\n", .{});
            return error.TestFailed;
        }

        std.debug.print("  ✓ PASSED: Different arguments correctly treated as unique\n\n", .{});
    }

    // Test 3: Different tool (should NOT be duplicate)
    std.debug.print("Test 3: Different tool\n", .{});
    {
        const call3 = ParsedToolCall{
            .name = "web_search",
            .arguments_json = "{\"query\":\"test\"}",
        };

        const is_dup = try trackToolCall.track(allocator, &seen_calls, call3);
        std.debug.print("  Different tool: duplicate={}\n", .{is_dup});
        if (is_dup) {
            std.debug.print("  ✗ FAILED: Different tool should not be duplicate\n", .{});
            return error.TestFailed;
        }

        std.debug.print("  ✓ PASSED: Different tool correctly treated as unique\n\n", .{});
    }

    // Test 4: Verify hashmap state
    std.debug.print("Test 4: Hashmap state verification\n", .{});
    const count = seen_calls.count();
    std.debug.print("  Unique tool calls tracked: {}\n", .{count});
    if (count != 3) {
        std.debug.print("  ✗ FAILED: Expected 3 unique entries, got {}\n", .{count});
        return error.TestFailed;
    }

    std.debug.print("  ✓ PASSED: Correct number of unique entries\n\n", .{});
    std.debug.print("✅ All deduplication tests passed!\n\n", .{});
    std.debug.print("The optimization correctly:\n", .{});
    std.debug.print("  - Detects exact duplicates (same name + same arguments)\n", .{});
    std.debug.print("  - Allows same tool with different arguments\n", .{});
    std.debug.print("  - Allows different tools\n", .{});
    std.debug.print("  - Uses single allocation per check (via getOrPut)\n", .{});
}
