const std = @import("std");
const providers = @import("providers");
const OpenAiProvider = providers.openai.OpenAiProvider;

// Integration tests for NullClaw providers with mock server
// Run with: ./tests/mock server/runner.sh tests/integration/provider_test.zig

test "OpenAI provider: basic chat with mock server" {
    const allocator = std.testing.allocator;
    
    // Uses OPENAI_BASE_URL from environment (set by runner.sh)
    var provider = OpenAiProvider.init(allocator, "mock-key");
    defer provider.deinit();
    
    const response = try provider.chatWithSystem(
        allocator,
        "You are helpful",
        "hello",
        "gpt-4",
        0.7,
    );
    defer allocator.free(response);
    
    try std.testing.expect(response.len > 0);
    std.debug.print("Response: {s}\n", .{response});
}

test "OpenAI provider: tool calls with mock server" {
    const allocator = std.testing.allocator;
    
    var provider = OpenAiProvider.init(allocator, "mock-key");
    defer provider.deinit();
    
    const messages = [_]providers.ChatMessage{
        .{
            .role = .user,
            .content = "test tool",
        },
    };
    
    const request = providers.ChatRequest{
        .messages = &messages,
    };
    
    const response = try provider.chat(
        allocator,
        request,
        "gpt-4",
        0.7,
    );
    defer if (response.content) |c| allocator.free(c);
    defer if (response.model) |m| allocator.free(m);
    defer if (response.tool_calls) |tc| {
        for (tc) |call| {
            allocator.free(call.id);
            allocator.free(call.name);
            allocator.free(call.arguments);
        }
        allocator.free(tc);
    };
    
    // Check if we got tool calls
    if (response.tool_calls) |tc| {
        try std.testing.expect(tc.len > 0);
        try std.testing.expectEqualStrings("shell", tc[0].name);
        std.debug.print("Tool call: {s}\n", .{tc[0].name});
    } else {
        std.debug.print("No tool calls in response (content-only response)\n", .{});
    }
}

test "OpenAI provider: streaming with mock server" {
    const allocator = std.testing.allocator;
    
    var provider = OpenAiProvider.init(allocator, "mock-key");
    defer provider.deinit();
    
    var received_chunks: usize = 0;
    
    const StreamContext = struct {
        count: *usize,
    };
    
    var ctx = StreamContext{ .count = &received_chunks };
    
    const callback = struct {
        fn call(chunk: []const u8, context: *anyopaque) anyerror!void {
            const c: *StreamContext = @ptrCast(@alignCast(context));
            c.count.* += 1;
            std.debug.print("Chunk {}: {s}\n", .{ c.count.*, chunk });
        }
    }.call;
    
    const messages = [_]providers.ChatMessage{
        .{
            .role = .user,
            .content = "hello",
        },
    };
    
    const request = providers.ChatRequest{
        .messages = &messages,
    };
    
    const result = try provider.streamChat(
        allocator,
        request,
        "gpt-4",
        0.7,
        callback,
        &ctx,
    );
    
    _ = result;
    
    try std.testing.expect(received_chunks > 0);
    std.debug.print("Received {} chunks\n", .{received_chunks});
}

test "OpenAI provider: error handling with mock server" {
    const allocator = std.testing.allocator;
    
    var provider = OpenAiProvider.init(allocator, "mock-key");
    defer provider.deinit();
    
    const messages = [_]providers.ChatMessage{
        .{
            .role = .user,
            .content = "test error",
        },
    };
    
    const request = providers.ChatRequest{
        .messages = &messages,
    };
    
    const result = provider.chat(
        allocator,
        request,
        "gpt-4",
        0.7,
    );
    
    // Should get an error
    try std.testing.expectError(error.OpenAiApiError, result);
}
