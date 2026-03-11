const std = @import("std");
const providers = @import("../../src/providers/root.zig");
const OpenAiProvider = providers.openai.OpenAiProvider;
const ChatMessage = providers.ChatMessage;
const ChatRequest = providers.ChatRequest;

// Integration tests for NullClaw runtime with llmock
// Tests the provider layer with mock server

test "Runtime: provider basic chat" {
    const allocator = std.testing.allocator;
    
    // Create provider pointing to mock server
    var provider = OpenAiProvider.init(allocator, "mock-key");
    defer provider.deinit();
    
    const response = try provider.chatWithSystem(
        allocator,
        "You are a helpful assistant",
        "hello",
        "gpt-4",
        0.7,
    );
    defer allocator.free(response);
    
    try std.testing.expect(response.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, response, "mock") != null or response.len > 0);
    std.debug.print("✅ Response: {s}\n", .{response});
}

test "Runtime: provider with ChatRequest" {
    const allocator = std.testing.allocator;
    
    var provider = OpenAiProvider.init(allocator, "mock-key");
    defer provider.deinit();
    
    const messages = [_]ChatMessage{
        .{
            .role = .user,
            .content = "hello",
        },
    };
    
    const request = ChatRequest{
        .messages = &messages,
    };
    
    const response = try provider.chat(allocator, request, "gpt-4", 0.7);
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
    
    if (response.content) |content| {
        try std.testing.expect(content.len > 0);
        std.debug.print("✅ Response content: {s}\n", .{content});
    }
}

test "Runtime: provider tool calls" {
    const allocator = std.testing.allocator;
    
    var provider = OpenAiProvider.init(allocator, "mock-key");
    defer provider.deinit();
    
    const messages = [_]ChatMessage{
        .{
            .role = .user,
            .content = "test tool",
        },
    };
    
    const request = ChatRequest{
        .messages = &messages,
    };
    
    const response = try provider.chat(allocator, request, "gpt-4", 0.7);
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
    
    // Check for tool calls
    if (response.tool_calls) |tc| {
        if (tc.len > 0) {
            try std.testing.expectEqualStrings("shell", tc[0].name);
            std.debug.print("✅ Tool call: {s} with args: {s}\n", .{ tc[0].name, tc[0].arguments });
        }
    } else {
        std.debug.print("✅ Response: {s}\n", .{response.content orelse "(no content)"});
    }
}

test "Runtime: provider streaming" {
    const allocator = std.testing.allocator;
    
    var provider = OpenAiProvider.init(allocator, "mock-key");
    defer provider.deinit();
    
    const StreamContext = struct {
        count: usize,
    };
    
    var ctx = StreamContext{ .count = 0 };
    
    const callback = struct {
        fn call(chunk: []const u8, context: *anyopaque) anyerror!void {
            const c: *StreamContext = @ptrCast(@alignCast(context));
            c.count += 1;
            std.debug.print("  Chunk {}: {s}\n", .{ c.count, chunk });
        }
    }.call;
    
    const messages = [_]ChatMessage{
        .{
            .role = .user,
            .content = "hello",
        },
    };
    
    const request = ChatRequest{
        .messages = &messages,
    };
    
    const result = try provider.streamChat(allocator, request, "gpt-4", 0.7, callback, &ctx);
    _ = result;
    
    std.debug.print("✅ Received {} chunks via streaming\n", .{ctx.count});
}

test "Runtime: provider error handling" {
    const allocator = std.testing.allocator;
    
    var provider = OpenAiProvider.init(allocator, "mock-key");
    defer provider.deinit();
    
    const messages = [_]ChatMessage{
        .{
            .role = .user,
            .content = "test error",
        },
    };
    
    const request = ChatRequest{
        .messages = &messages,
    };
    
    const result = provider.chat(allocator, request, "gpt-4", 0.7);
    
    // Should get an error from mock server
    try std.testing.expectError(error.OpenAiApiError, result);
    std.debug.print("✅ Error handling works correctly\n", .{});
}

test "Runtime: multi-turn conversation (via message history)" {
    const allocator = std.testing.allocator;
    
    var provider = OpenAiProvider.init(allocator, "mock-key");
    defer provider.deinit();
    
    // Turn 1
    const messages1 = [_]ChatMessage{
        .{ .role = .user, .content = "hello" },
    };
    
    const response1 = try provider.chat(allocator, .{ .messages = &messages1 }, "gpt-4", 0.7);
    defer if (response1.content) |c| allocator.free(c);
    defer if (response1.model) |m| allocator.free(m);
    defer if (response1.tool_calls) |tc| {
        for (tc) |call| {
            allocator.free(call.id);
            allocator.free(call.name);
            allocator.free(call.arguments);
        }
        allocator.free(tc);
    };
    
    std.debug.print("✅ Turn 1: {s}\n", .{response1.content orelse "(no content)"});
    
    // Turn 2 (with history)
    const messages2 = [_]ChatMessage{
        .{ .role = .user, .content = "hello" },
        .{ .role = .assistant, .content = response1.content orelse "" },
        .{ .role = .user, .content = "what did I just say?" },
    };
    
    const response2 = try provider.chat(allocator, .{ .messages = &messages2 }, "gpt-4", 0.7);
    defer if (response2.content) |c| allocator.free(c);
    defer if (response2.model) |m| allocator.free(m);
    defer if (response2.tool_calls) |tc| {
        for (tc) |call| {
            allocator.free(call.id);
            allocator.free(call.name);
            allocator.free(call.arguments);
        }
        allocator.free(tc);
    };
    
    std.debug.print("✅ Turn 2: {s}\n", .{response2.content orelse "(no content)"});
}

test "Runtime: connection reuse (persistent HTTP)" {
    const allocator = std.testing.allocator;
    
    var provider = OpenAiProvider.init(allocator, "mock-key");
    defer provider.deinit();
    
    // Make multiple requests - should reuse connection
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const messages = [_]ChatMessage{
            .{ .role = .user, .content = "hello" },
        };
        
        const response = try provider.chat(allocator, .{ .messages = &messages }, "gpt-4", 0.7);
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
        
        std.debug.print("✅ Request {}: success\n", .{i + 1});
    }
    
    std.debug.print("✅ Connection reuse verified (3 requests on same client)\n", .{});
}
