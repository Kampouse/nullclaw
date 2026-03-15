//! Tests for provider error handling
//! Validates API responses, error classification, and edge cases

const std = @import("std");
const helpers = @import("providers/helpers.zig");
const error_classify = @import("providers/error_classify.zig");

// ═══════════════════════════════════════════════════════════════════════════
// Response Parsing Tests
// ═══════════════════════════════════════════════════════════════════════════

test "extractContent - OpenAI format" {
    const response = 
        \\{"choices":[{"message":{"content":"Hello, world!"}}]}
    ;
    
    const content = try helpers.extractContent(std.testing.allocator, response);
    defer std.testing.allocator.free(content);
    
    try std.testing.expectEqualStrings("Hello, world!", content);
}

test "extractContent - Anthropic format" {
    const response = 
        \\{"content":[{"text":"Hello from Claude!"}]}
    ;
    
    const content = try helpers.extractContent(std.testing.allocator, response);
    defer std.testing.allocator.free(content);
    
    try std.testing.expectEqualStrings("Hello from Claude!", content);
}

test "extractContent - empty choices array" {
    const response = 
        \\{"choices":[]}
    ;
    
    const result = helpers.extractContent(std.testing.allocator, response);
    try std.testing.expectError(error.UnexpectedResponse, result);
}

test "extractContent - empty content array" {
    const response = 
        \\{"content":[]}
    ;
    
    const result = helpers.extractContent(std.testing.allocator, response);
    try std.testing.expectError(error.UnexpectedResponse, result);
}

test "extractContent - missing content field" {
    const response = 
        \\{"choices":[{"message":{"role":"assistant"}}]}
    ;
    
    const result = helpers.extractContent(std.testing.allocator, response);
    try std.testing.expectError(error.UnexpectedResponse, result);
}

test "extractContent - invalid JSON" {
    const response = "not valid json";
    
    const result = helpers.extractContent(std.testing.allocator, response);
    try std.testing.expectError(error.InvalidCharacter, result);
}

test "extractContent - empty response" {
    const response = "{}";
    
    const result = helpers.extractContent(std.testing.allocator, response);
    try std.testing.expectError(error.UnexpectedResponse, result);
}

test "extractContent - nested content with newlines" {
    const response = 
        \\{"choices":[{"message":{"content":"Line 1\nLine 2\nLine 3"}}]}
    ;
    
    const content = try helpers.extractContent(std.testing.allocator, response);
    defer std.testing.allocator.free(content);
    
    try std.testing.expect(std.mem.indexOf(u8, content, "Line 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Line 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Line 3") != null);
}

test "extractContent - unicode content" {
    const response = 
        \\{"choices":[{"message":{"content":"Hello 世界 🌍"}}]}
    ;
    
    const content = try helpers.extractContent(std.testing.allocator, response);
    defer std.testing.allocator.free(content);
    
    try std.testing.expect(std.mem.indexOf(u8, content, "世界") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "🌍") != null);
}

test "extractContent - multiple choices uses first" {
    const response = 
        \\{"choices":[
        \\  {"message":{"content":"First"}},
        \\  {"message":{"content":"Second"}}
        \\]}
    ;
    
    const content = try helpers.extractContent(std.testing.allocator, response);
    defer std.testing.allocator.free(content);
    
    // Should use first choice
    try std.testing.expectEqualStrings("First", content);
}

test "extractContent - null content" {
    const response = 
        \\{"choices":[{"message":{"content":null}}]}
    ;
    
    const result = helpers.extractContent(std.testing.allocator, response);
    try std.testing.expectError(error.UnexpectedResponse, result);
}

test "extractContent - number content" {
    const response = 
        \\{"choices":[{"message":{"content":42}}]}
    ;
    
    const result = helpers.extractContent(std.testing.allocator, response);
    try std.testing.expectError(error.UnexpectedResponse, result);
}

test "extractContent - array content" {
    const response = 
        \\{"choices":[{"message":{"content":["a","b"]}}]}
    ;
    
    const result = helpers.extractContent(std.testing.allocator, response);
    try std.testing.expectError(error.UnexpectedResponse, result);
}

test "extractContent - extra fields ignored" {
    const response = 
        \\{"id":"chatcmpl-123","object":"chat.completion","created":1234567890,
        \\ "choices":[{"message":{"role":"assistant","content":"Hello"}}],
        \\ "usage":{"prompt_tokens":10,"completion_tokens":5}}
    ;
    
    const content = try helpers.extractContent(std.testing.allocator, response);
    defer std.testing.allocator.free(content);
    
    try std.testing.expectEqualStrings("Hello", content);
}

// ═══════════════════════════════════════════════════════════════════════════
// Error Classification Tests
// ═══════════════════════════════════════════════════════════════════════════

test "isRateLimitedText - common patterns" {
    try std.testing.expect(error_classify.isRateLimitedText("Rate limited"));
    try std.testing.expect(error_classify.isRateLimitedText("ratelimited"));
    try std.testing.expect(error_classify.isRateLimitedText("RATE LIMITED"));
    try std.testing.expect(error_classify.isRateLimitedText("rate_limit_exceeded"));
    try std.testing.expect(error_classify.isRateLimitedText("Too many requests"));
    try std.testing.expect(error_classify.isRateLimitedText("throttled"));
    try std.testing.expect(error_classify.isRateLimitedText("quota exceeded"));
    try std.testing.expect(error_classify.isRateLimitedText("429 rate limit"));
}

test "isRateLimitedText - negative cases" {
    try std.testing.expect(!error_classify.isRateLimitedText("Hello world"));
    try std.testing.expect(!error_classify.isRateLimitedText("Success"));
    try std.testing.expect(!error_classify.isRateLimitedText(""));
    try std.testing.expect(!error_classify.isRateLimitedText("rate: 100 requests/min"));
}

test "isContextExhaustedText - common patterns" {
    try std.testing.expect(error_classify.isContextExhaustedText("Context length exceeded"));
    try std.testing.expect(error_classify.isContextExhaustedText("contextlengthexceeded"));
    try std.testing.expect(error_classify.isContextExhaustedText("CONTEXT LENGTH EXCEEDED"));
    try std.testing.expect(error_classify.isContextExhaustedText("Maximum context length"));
    try std.testing.expect(error_classify.isContextExhaustedText("context window exceeded"));
    try std.testing.expect(error_classify.isContextExhaustedText("prompt is too long"));
    try std.testing.expect(error_classify.isContextExhaustedText("token limit exceeded"));
}

test "isContextExhaustedText - negative cases" {
    try std.testing.expect(!error_classify.isContextExhaustedText("Hello world"));
    try std.testing.expect(!error_classify.isContextExhaustedText(""));
    try std.testing.expect(!error_classify.isContextExhaustedText("context: 4096 tokens"));
}

test "isVisionUnsupportedText - common patterns" {
    try std.testing.expect(error_classify.isVisionUnsupportedText("Vision not supported"));
    try std.testing.expect(error_classify.isVisionUnsupportedText("does not support images"));
    try std.testing.expect(error_classify.isVisionUnsupportedText("image input not available"));
    try std.testing.expect(error_classify.isVisionUnsupportedText("multimodal not supported"));
}

test "isVisionUnsupportedText - negative cases" {
    try std.testing.expect(!error_classify.isVisionUnsupportedText("Hello world"));
    try std.testing.expect(!error_classify.isVisionUnsupportedText(""));
}

test "isRateLimitedText - embedded in JSON error" {
    const error_msg = 
        \\{"error":{"message":"Rate limited. Please retry after 60 seconds.","type":"rate_limit_error"}}
    ;
    
    try std.testing.expect(error_classify.isRateLimitedText(error_msg));
}

test "isContextExhaustedText - embedded in JSON error" {
    const error_msg = 
        \\{"error":{"message":"This model's maximum context length is 4097 tokens.","type":"invalid_request_error"}}
    ;
    
    try std.testing.expect(error_classify.isContextExhaustedText(error_msg));
}

// ═══════════════════════════════════════════════════════════════════════════
// Provider URL Tests
// ═══════════════════════════════════════════════════════════════════════════

test "providerUrl - openai" {
    const url = helpers.providerUrl("openai");
    try std.testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", url);
}

test "providerUrl - anthropic" {
    const url = helpers.providerUrl("anthropic");
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url);
}

test "providerUrl - ollama" {
    const url = helpers.providerUrl("ollama");
    try std.testing.expectEqualStrings("http://localhost:11434/api/chat", url);
}

test "providerUrl - openrouter" {
    const url = helpers.providerUrl("openrouter");
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", url);
}

test "providerUrl - gemini" {
    const url = helpers.providerUrl("gemini");
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta", url);
}

test "providerUrl - unknown provider returns empty" {
    const url = helpers.providerUrl("unknown-provider");
    try std.testing.expectEqualStrings("", url);
}

// ═══════════════════════════════════════════════════════════════════════════
// Request Body Building Tests
// ═══════════════════════════════════════════════════════════════════════════

test "buildRequestBody - basic" {
    const body = try helpers.buildRequestBody(
        std.testing.allocator,
        "gpt-4",
        "Hello",
        0.7,
        100
    );
    defer std.testing.allocator.free(body);
    
    // Should be valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    
    try std.testing.expectEqualStrings("gpt-4", parsed.value.object.get("model").?.string);
    try std.testing.expect(parsed.value.object.get("messages") != null);
}

test "buildRequestBodyWithSystem - includes system prompt" {
    const body = try helpers.buildRequestBodyWithSystem(
        std.testing.allocator,
        "gpt-4",
        "You are helpful",
        "Hello",
        0.7,
        100
    );
    defer std.testing.allocator.free(body);
    
    // Should be valid JSON with system message
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    
    const messages = parsed.value.object.get("messages").?.array;
    try std.testing.expect(messages.items.len >= 2);
    
    // First message should be system
    const first = messages.items[0].object;
    try std.testing.expectEqualStrings("system", first.get("role").?.string);
    try std.testing.expectEqualStrings("You are helpful", first.get("content").?.string);
}

test "buildRequestBody - temperature included" {
    const body = try helpers.buildRequestBody(
        std.testing.allocator,
        "gpt-4",
        "Hello",
        0.5,
        100
    );
    defer std.testing.allocator.free(body);
    
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    
    const temp = parsed.value.object.get("temperature").?.float;
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), temp, 0.01);
}

test "buildRequestBody - max_tokens included" {
    const body = try helpers.buildRequestBody(
        std.testing.allocator,
        "gpt-4",
        "Hello",
        0.7,
        500
    );
    defer std.testing.allocator.free(body);
    
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    
    const max_tokens = parsed.value.object.get("max_tokens").?.integer;
    try std.testing.expectEqual(@as(i64, 500), max_tokens);
}

test "buildRequestBody - special characters in prompt" {
    const body = try helpers.buildRequestBody(
        std.testing.allocator,
        "gpt-4",
        "Hello \"world\" with \n newlines",
        0.7,
        100
    );
    defer std.testing.allocator.free(body);
    
    // Should be valid JSON (properly escaped)
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    
    const messages = parsed.value.object.get("messages").?.array;
    const content = messages.items[0].object.get("content").?.string;
    try std.testing.expect(std.mem.indexOf(u8, content, "Hello") != null);
}
