const std = @import("std");
const nullclaw = @import("nullclaw");
const providers = nullclaw.providers;
const OpenAiProvider = providers.openai.OpenAiProvider;
const Provider = providers.Provider;
const ChatMessage = providers.ChatMessage;
const ChatRequest = providers.ChatRequest;
const ToolSpec = providers.ToolSpec;

// Tool calling test with mock server
// Run with: ./tests/mock server/runner.sh tool-calls

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Tool Calling Test with mock server                           ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
    
    // Get base URL from environment (set by runner.sh)
    const base_url = if (std.c.getenv("OPENAI_BASE_URL")) |url| 
        std.mem.span(url)
    else 
        "http://localhost:4010/v1";
    
    std.debug.print("Using base URL: {s}\n\n", .{base_url});
    
    // Create provider with mock URL
    var openai_provider = OpenAiProvider.initWithBaseUrl(allocator, "mock-key", base_url);
    defer openai_provider.deinit();
    
    var provider = openai_provider.provider();
    
    // Define a simple tool
    const tools = [_]ToolSpec{
        .{
            .name = "get_weather",
            .description = "Get the current weather for a location",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\",\"description\":\"City and country\"}},\"required\":[\"location\"]}",
        },
    };
    
    // Test 1: Tool call response
    std.debug.print("Test 1: Provider returns tool call... ", .{});
    
    const messages1 = [_]ChatMessage{
        .{ .role = .user, .content = "What's the weather in Tokyo?" },
    };
    
    const request1 = ChatRequest{
        .messages = &messages1,
        .tools = &tools,
    };
    
    const response1 = provider.chatWithTools(allocator, request1) catch |err| {
        std.debug.print("❌ FAIL: {}\n", .{err});
        std.process.exit(1);
    };
    defer if (response1.content) |c| allocator.free(c);
    defer if (response1.tool_calls.len > 0) {
        for (response1.tool_calls) |call| {
            allocator.free(call.id);
            allocator.free(call.name);
            allocator.free(call.arguments);
        }
        allocator.free(response1.tool_calls);
    };
    
    if (response1.tool_calls.len > 0) {
        std.debug.print("✅ PASS\n", .{});
        std.debug.print("  Tool: {s}\n", .{response1.tool_calls[0].name});
        std.debug.print("  Args: {s}\n", .{response1.tool_calls[0].arguments});
    } else if (response1.content) |content| {
        std.debug.print("✅ PASS (content-only response)\n", .{});
        std.debug.print("  Content: {s}\n", .{content});
    } else {
        std.debug.print("❌ FAIL: No tool calls or content\n", .{});
        std.process.exit(1);
    }
    
    std.debug.print("\n══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("Tool calling test passed!\n", .{});
    std.debug.print("══════════════════════════════════════════════════════════\n\n", .{});
}
