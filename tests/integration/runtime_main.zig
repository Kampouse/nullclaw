const std = @import("std");
const nullclaw = @import("nullclaw");
const providers = nullclaw.providers;
const OpenAiProvider = providers.openai.OpenAiProvider;
const Provider = providers.Provider;
const ChatMessage = providers.ChatMessage;
const ChatRequest = providers.ChatRequest;

// Simple integration test runner for NullClaw runtime with mock server
// Run with: zig run tests/integration/runtime_main.zig

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  NullClaw Integration Tests with mock server                  ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
    
    var passed: usize = 0;
    var failed: usize = 0;
    
    // Test 1: Basic chat
    std.debug.print("Test 1: Basic chat flow... ", .{});
    if (testBasicChat(allocator)) {
        std.debug.print("✅ PASS\n", .{});
        passed += 1;
    } else |_| {
        std.debug.print("❌ FAIL\n", .{});
        failed += 1;
    }
    
    // Test 2: Tool calls
    std.debug.print("Test 2: Tool call execution... ", .{});
    if (testToolCalls(allocator)) {
        std.debug.print("✅ PASS\n", .{});
        passed += 1;
    } else |_| {
        std.debug.print("❌ FAIL\n", .{});
        failed += 1;
    }
    
    // Test 3: Streaming
    std.debug.print("Test 3: Streaming response... ", .{});
    if (testStreaming(allocator)) {
        std.debug.print("✅ PASS\n", .{});
        passed += 1;
    } else |_| {
        std.debug.print("❌ FAIL\n", .{});
        failed += 1;
    }
    
    // Test 4: Error handling
    std.debug.print("Test 4: Error handling... ", .{});
    if (testErrorHandling(allocator)) {
        std.debug.print("✅ PASS\n", .{});
        passed += 1;
    } else |_| {
        std.debug.print("❌ FAIL\n", .{});
        failed += 1;
    }
    
    // Test 5: Connection reuse
    std.debug.print("Test 5: Connection reuse (3 requests)... ", .{});
    if (testConnectionReuse(allocator)) {
        std.debug.print("✅ PASS\n", .{});
        passed += 1;
    } else |_| {
        std.debug.print("❌ FAIL\n", .{});
        failed += 1;
    }
    
    // Test 6: Multi-turn conversation
    std.debug.print("Test 6: Multi-turn conversation... ", .{});
    if (testMultiTurn(allocator)) {
        std.debug.print("✅ PASS\n", .{});
        passed += 1;
    } else |_| {
        std.debug.print("❌ FAIL\n", .{});
        failed += 1;
    }
    
    // Summary
    std.debug.print("\n", .{});
    std.debug.print("══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("Results: {} passed, {} failed\n", .{ passed, failed });
    std.debug.print("══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});
    
    if (failed > 0) {
        std.process.exit(1);
    }
}

fn testBasicChat(allocator: std.mem.Allocator) !void {
    var openai_provider = OpenAiProvider.init(allocator, "mock-key");
    defer openai_provider.deinit();
    
    var provider = openai_provider.provider();
    
    const response = try provider.chatWithSystem(
        allocator,
        "You are a helpful assistant",
        "hello",
        "gpt-4",
        0.7,
    );
    defer allocator.free(response);
    
    if (response.len == 0) return error.EmptyResponse;
}

fn testToolCalls(allocator: std.mem.Allocator) !void {
    var openai_provider = OpenAiProvider.init(allocator, "mock-key");
    defer openai_provider.deinit();
    
    var provider = openai_provider.provider();
    
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "test tool" },
    };
    
    const response = try provider.chat(allocator, .{ .messages = &messages }, "gpt-4", 0.7);
    defer if (response.content) |c| allocator.free(c);
    defer if (response.tool_calls.len > 0) {
        for (response.tool_calls) |call| {
            allocator.free(call.id);
            allocator.free(call.name);
            allocator.free(call.arguments);
        }
        allocator.free(response.tool_calls);
    };
    
    // Response should have content or tool_calls
    if (response.content == null and response.tool_calls.len == 0) {
        return error.NoResponse;
    }
}

fn testStreaming(allocator: std.mem.Allocator) !void {
    var openai_provider = OpenAiProvider.init(allocator, "mock-key");
    defer openai_provider.deinit();
    
    var provider = openai_provider.provider();
    
    const StreamContext = struct {
        count: usize,
    };
    
    var ctx = StreamContext{ .count = 0 };
    
    const callback = struct {
        fn call(ctx_ptr: *anyopaque, chunk: providers.StreamChunk) void {
            const c: *StreamContext = @ptrCast(@alignCast(ctx_ptr));
            if (!chunk.is_final and chunk.delta.len > 0) {
                c.count += 1;
            }
        }
    }.call;
    
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "hello" },
    };
    
    const result = try provider.streamChat(allocator, .{ .messages = &messages }, "gpt-4", 0.7, callback, &ctx);
    _ = result;
    
    if (ctx.count == 0) return error.NoChunksReceived;
}

fn testErrorHandling(allocator: std.mem.Allocator) !void {
    var openai_provider = OpenAiProvider.init(allocator, "mock-key");
    defer openai_provider.deinit();
    
    var provider = openai_provider.provider();
    
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "test error" },
    };
    
    const result = provider.chat(allocator, .{ .messages = &messages }, "gpt-4", 0.7);
    
    // Should get an error
    if (result) |_| {
        return error.ExpectedError;
    } else |_| {
        // Expected to fail
        return;
    }
}

fn testConnectionReuse(allocator: std.mem.Allocator) !void {
    var openai_provider = OpenAiProvider.init(allocator, "mock-key");
    defer openai_provider.deinit();
    
    var provider = openai_provider.provider();
    
    // Make 3 requests - should reuse connection
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const messages = [_]ChatMessage{
            .{ .role = .user, .content = "hello" },
        };
        
        const response = try provider.chat(allocator, .{ .messages = &messages }, "gpt-4", 0.7);
        defer if (response.content) |c| allocator.free(c);
        defer if (response.tool_calls.len > 0) {
            for (response.tool_calls) |call| {
                allocator.free(call.id);
                allocator.free(call.name);
                allocator.free(call.arguments);
            }
            allocator.free(response.tool_calls);
        };
    }
}

fn testMultiTurn(allocator: std.mem.Allocator) !void {
    var openai_provider = OpenAiProvider.init(allocator, "mock-key");
    defer openai_provider.deinit();
    
    var provider = openai_provider.provider();
    
    // Turn 1
    const messages1 = [_]ChatMessage{
        .{ .role = .user, .content = "hello" },
    };
    
    const response1 = try provider.chat(allocator, .{ .messages = &messages1 }, "gpt-4", 0.7);
    defer if (response1.content) |c| allocator.free(c);
    defer if (response1.tool_calls.len > 0) {
        for (response1.tool_calls) |call| {
            allocator.free(call.id);
            allocator.free(call.name);
            allocator.free(call.arguments);
        }
        allocator.free(response1.tool_calls);
    };
    
    // Turn 2 with history
    const messages2 = [_]ChatMessage{
        .{ .role = .user, .content = "hello" },
        .{ .role = .assistant, .content = response1.content orelse "" },
        .{ .role = .user, .content = "what did I just say?" },
    };
    
    const response2 = try provider.chat(allocator, .{ .messages = &messages2 }, "gpt-4", 0.7);
    defer if (response2.content) |c| allocator.free(c);
    defer if (response2.tool_calls.len > 0) {
        for (response2.tool_calls) |call| {
            allocator.free(call.id);
            allocator.free(call.name);
            allocator.free(call.arguments);
        }
        allocator.free(response2.tool_calls);
    };
    
    if (response2.content == null and response2.tool_calls.len == 0) return error.NoContent;
}
