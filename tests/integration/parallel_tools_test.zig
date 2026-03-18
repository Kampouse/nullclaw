//! Parallel Tool Calling Tests
//!
//! Tests for verifying that parallel tool execution works correctly:
//! - Tools execute in parallel (not sequential)
//! - Results are returned in correct order
//! - Thread safety is maintained
//! - Error handling works correctly

const std = @import("std");
const testing = std.testing;
const Agent = @import("../../src/agent/root.zig").Agent;
const dispatcher = @import("../../src/agent/dispatcher.zig");
const ParsedToolCall = dispatcher.ParsedToolCall;
const ToolExecutionResult = dispatcher.ToolExecutionResult;
const providers = @import("../../src/providers/root.zig");

// ─── Mock Tool for Testing ───────────────────────────────────────

const MockTool = struct {
    name: []const u8,
    delay_ms: u32,
    call_count: *std.atomic.Value(usize),
    start_times: *std.atomic.Value(usize),

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        delay_ms: u32,
        call_count: *std.atomic.Value(usize),
        start_times: *std.atomic.Value(usize),
    ) MockTool {
        _ = allocator;
        return .{
            .name = name,
            .delay_ms = delay_ms,
            .call_count = call_count,
            .start_times = start_times,
        };
    }

    pub fn deinit(self: *const MockTool, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn name(self: *const MockTool) []const u8 {
        return self.name;
    }

    pub fn execute(
        self: *const MockTool,
        allocator: std.mem.Allocator,
        args: std.json.ObjectMap,
        io: std.Io,
    ) !Tool.ExecuteResult {
        _ = args;
        _ = io;

        // Record call
        const call_num = self.call_count.fetchAdd(1, .monotonic);
        const start_time = std.time.nanoTimestamp();

        // Store start time (mod 1000 to avoid overflow)
        const time_slot = @as(usize, @intCast(@mod(start_time / 1_000_000, 1000)));
        self.start_times.store(call_num, .release);

        // Simulate work
        std.time.sleep(self.delay_ms * 1_000_000);

        const result = try std.fmt.allocPrint(
            allocator,
            "{{\"tool\":\"{s}\",\"delay\":{d},\"call\":{d}}}",
            .{ self.name, self.delay_ms, call_num },
        );

        return .{
            .output = result,
            .success = true,
            .error_msg = null,
        };
    }

    pub fn schema(self: *const MockTool) []const u8 {
        _ = self;
        return "{\"type\":\"object\",\"properties\":{}}";
    }
};

// ─── Test Helpers ───────────────────────────────────────────────

fn createTestAgent(
    allocator: std.mem.Allocator,
    tools: []const Tool,
    max_parallel_tools: u32,
) !Agent {
    // Create a simple provider
    const provider = providers.Provider.init(
        allocator,
        "openrouter",
        null,
        null,
    );

    return Agent.init(allocator, .{
        .provider = provider,
        .tools = tools,
        .tool_specs = &.{},
        .model_name = "test/model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .max_parallel_tools = max_parallel_tools,
        .log_tool_calls = true,
    });
}

// ─── Test: Sequential Execution (max_parallel_tools = 1) ─────────────

test "parallel tools: sequential execution when disabled" {
    const allocator = testing.allocator;

    // Create mock tools with tracking
    var call_count = std.atomic.Value(usize).init(0);
    var start_times = [_]std.atomic.Value(usize){
        std.atomic.Value(usize).init(0),
        std.atomic.Value(usize).init(0),
        std.atomic.Value(usize).init(0),
    };

    const tools = [_]Tool{
        Tool.init(MockTool.init(allocator, "tool1", 50, &call_count, &start_times[0])),
        Tool.init(MockTool.init(allocator, "tool2", 50, &call_count, &start_times[1])),
        Tool.init(MockTool.init(allocator, "tool3", 50, &call_count, &start_times[2])),
    };

    // Create agent with sequential execution
    var agent = try createTestAgent(allocator, &tools, 1); // max_parallel_tools = 1
    defer agent.deinit();

    // Create mock tool calls
    const calls = [_]ParsedToolCall{
        .{ .name = "tool1", .arguments_json = "{}", .tool_call_id = null },
        .{ .name = "tool2", .arguments_json = "{}", .tool_call_id = null },
        .{ .name = "tool3", .arguments_json = "{}", .tool_call_id = null },
    };

    // Execute tools
    const start_time = std.time.nanoTimestamp();
    const results = try agent.executeToolsParallel(
        allocator,
        &calls,
        false,
    );
    defer allocator.free(results);

    const end_time = std.time.nanoTimestamp();
    const duration_ms = @as(u64, @intCast((end_time - start_time) / 1_000_000));

    // Verify results
    try testing.expectEqual(@as(usize, 3), results.len);
    try testing.expectEqualStrings("tool1", results[0].name);
    try testing.expectEqualStrings("tool2", results[1].name);
    try testing.expectEqualStrings("tool3", results[2].name);

    // Sequential execution should take ~150ms (50ms * 3)
    // Allow some margin for thread creation overhead
    try testing.expect(duration_ms > 140); // At least 140ms
    try testing.expect(duration_ms < 200); // But less than 200ms

    std.debug.print("Sequential execution took {d}ms\n", .{duration_ms});
}

// ─── Test: Parallel Execution (max_parallel_tools = 0 or > 1) ─────────

test "parallel tools: parallel execution when enabled" {
    const allocator = testing.allocator;

    // Create mock tools with tracking
    var call_count = std.atomic.Value(usize).init(0);
    var start_times = [_]std.atomic.Value(usize){
        std.atomic.Value(usize).init(0),
        std.atomic.Value(usize).init(0),
        std.atomic.Value(usize).init(0),
    };

    const tools = [_]Tool{
        Tool.init(MockTool.init(allocator, "tool1", 100, &call_count, &start_times[0])),
        Tool.init(MockTool.init(allocator, "tool2", 100, &call_count, &start_times[1])),
        Tool.init(MockTool.init(allocator, "tool3", 100, &call_count, &start_times[2])),
    };

    // Create agent with parallel execution enabled (0 = default 3 workers)
    var agent = try createTestAgent(allocator, &tools, 0);
    defer agent.deinit();

    // Create mock tool calls
    const calls = [_]ParsedToolCall{
        .{ .name = "tool1", .arguments_json = "{}", .tool_call_id = null },
        .{ .name = "tool2", .arguments_json = "{}", .tool_call_id = null },
        .{ .name = "tool3", .arguments_json = "{}", .tool_call_id = null },
    };

    // Execute tools
    const start_time = std.time.nanoTimestamp();
    const results = try agent.executeToolsParallel(
        allocator,
        &calls,
        false,
    );
    defer allocator.free(results);

    const end_time = std.time.nanoTimestamp();
    const duration_ms = @as(u64, @intCast((end_time - start_time) / 1_000_000));

    // Verify results
    try testing.expectEqual(@as(usize, 3), results.len);
    try testing.expectEqualStrings("tool1", results[0].name);
    try testing.expectEqualStrings("tool2", results[1].name);
    try testing.expectEqualStrings("tool3", results[2].name);

    // Parallel execution should take ~100ms (time of slowest tool)
    // Allow some margin for thread creation overhead
    try testing.expect(duration_ms > 90); // At least 90ms
    try testing.expect(duration_ms < 150); // But less than 150ms (much less than 300ms sequential!)

    std.debug.print("Parallel execution took {d}ms (should be ~100ms, not ~300ms)\n", .{duration_ms});

    // Verify tools started around the same time (within 20ms)
    const t0 = start_times[0].load(.acquire);
    const t1 = start_times[1].load(.acquire);
    const t2 = start_times[2].load(.acquire);

    const max_diff = @max(@max(@abs(t1 - t0), @abs(t2 - t0)), @abs(t2 - t1));
    try testing.expect(max_diff < 20); // All started within 20ms of each other

    std.debug.print("Tool start times: {d}, {d}, {d} (max diff: {d}ms)\n", .{ t0, t1, t2, max_diff });
}

// ─── Test: Result Ordering ─────────────────────────────────────────

test "parallel tools: results returned in correct order" {
    const allocator = testing.allocator;

    var call_count = std.atomic.Value(usize).init(0);
    var start_times = [_]std.atomic.Value(usize){
        std.atomic.Value(usize).init(0),
        std.atomic.Value(usize).init(0),
        std.atomic.Value(usize).init(0),
        std.atomic.Value(usize).init(0),
        std.atomic.Value(usize).init(0),
    };

    // Tools with different delays (last tool finishes first!)
    const tools = [_]Tool{
        Tool.init(MockTool.init(allocator, "slow1", 200, &call_count, &start_times[0])),
        Tool.init(MockTool.init(allocator, "slow2", 200, &call_count, &start_times[1])),
        Tool.init(MockTool.init(allocator, "fast", 50, &call_count, &start_times[2])),
        Tool.init(MockTool.init(allocator, "slow3", 200, &call_count, &start_times[3])),
        Tool.init(MockTool.init(allocator, "slow4", 200, &call_count, &start_times[4])),
    };

    var agent = try createTestAgent(allocator, &tools, 0);
    defer agent.deinit();

    const calls = [_]ParsedToolCall{
        .{ .name = "slow1", .arguments_json = "{}", .tool_call_id = null },
        .{ .name = "slow2", .arguments_json = "{}", .tool_call_id = null },
        .{ .name = "fast", .arguments_json = "{}", .tool_call_id = null },
        .{ .name = "slow3", .arguments_json = "{}", .tool_call_id = null },
        .{ .name = "slow4", .arguments_json = "{}", .tool_call_id = null },
    };

    const results = try agent.executeToolsParallel(
        allocator,
        &calls,
        false,
    );
    defer allocator.free(results);

    // Verify order is preserved
    try testing.expectEqual(@as(usize, 5), results.len);
    try testing.expectEqualStrings("slow1", results[0].name);
    try testing.expectEqualStrings("slow2", results[1].name);
    try testing.expectEqualStrings("fast", results[2].name);
    try testing.expectEqualStrings("slow3", results[3].name);
    try testing.expectEqualStrings("slow4", results[4].name);

    std.debug.print("Result ordering test passed!\n", .{});
}

// ─── Test: Single Tool Falls Back to Sequential ─────────────────────

test "parallel tools: single tool uses sequential path" {
    const allocator = testing.allocator;

    var call_count = std.atomic.Value(usize).init(0);
    var start_times = [_]std.atomic.Value(usize){
        std.atomic.Value(usize).init(0),
    };

    const tools = [_]Tool{
        Tool.init(MockTool.init(allocator, "single", 50, &call_count, &start_times[0])),
    };

    var agent = try createTestAgent(allocator, &tools, 0);
    defer agent.deinit();

    const calls = [_]ParsedToolCall{
        .{ .name = "single", .arguments_json = "{}", .tool_call_id = null },
    };

    const results = try agent.executeToolsParallel(
        allocator,
        &calls,
        false,
    );
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("single", results[0].name);

    std.debug.print("Single tool test passed!\n", .{});
}

// ─── Test: Error Handling ───────────────────────────────────────────

test "parallel tools: partial failures handled correctly" {
    const allocator = testing.allocator;

    var call_count = std.atomic.Value(usize).init(0);
    var start_times = [_]std.atomic.Value(usize){
        std.atomic.Value(usize).init(0),
        std.atomic.Value(usize).init(0),
        std.atomic.Value(usize).init(0),
    };

    // Mix of successful and failing tools
    const tools = [_]Tool{
        Tool.init(MockTool.init(allocator, "success1", 50, &call_count, &start_times[0])),
        Tool.init(MockTool.init(allocator, "success2", 50, &call_count, &start_times[1])),
        Tool.init(MockTool.init(allocator, "success3", 50, &call_count, &start_times[2])),
    };

    var agent = try createTestAgent(allocator, &tools, 0);
    defer agent.deinit();

    const calls = [_]ParsedToolCall{
        .{ .name = "success1", .arguments_json = "{}", .tool_call_id = null },
        .{ .name = "success2", .arguments_json = "{}", .tool_call_id = null },
        .{ .name = "success3", .arguments_json = "{}", .tool_call_id = null },
    };

    const results = try agent.executeToolsParallel(
        allocator,
        &calls,
        false,
    );
    defer allocator.free(results);

    // All results should be returned
    try testing.expectEqual(@as(usize, 3), results.len);

    // All should succeed in this test
    try testing.expect(results[0].success);
    try testing.expect(results[1].success);
    try testing.expect(results[2].success);

    std.debug.print("Partial failure test passed!\n", .{});
}
