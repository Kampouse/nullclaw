const std = @import("std");

/// Simple mock HTTP server for testing NullClaw providers
/// Simulates OpenAI API responses without external dependencies

pub fn main() !void {
    const port: u16 = 4010;
    
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var server = try address.listen(std.Options.debug_io, .{
        .reuse_address = true,
    });
    defer server.deinit(std.Options.debug_io);
    
    std.debug.print("NullClaw Mock Server listening on http://127.0.0.1:{}\n", .{port});
    std.debug.print("Endpoints:\n", .{});
    std.debug.print("  POST /v1/chat/completions - Chat completion\n", .{});
    std.debug.print("  POST /v1/messages - Anthropic messages\n", .{});
    std.debug.print("\n", .{});
    
    while (true) {
        var conn = server.accept(std.Options.debug_io) catch continue;
        defer conn.close(std.Options.debug_io);
        
        handleConnection(&conn) catch |err| {
            std.debug.print("Connection error: {}\n", .{err});
        };
    }
}

fn handleConnection(conn: *std.Io.net.IpConnection) !void {
    var buf: [8192]u8 = undefined;
    const bytes_read = try conn.read(std.Options.debug_io, &buf);
    const request = buf[0..bytes_read];
    
    // Parse HTTP request
    const method_end = std.mem.indexOfScalar(u8, request, ' ') orelse return error.InvalidRequest;
    const method = request[0..method_end];
    
    const path_start = method_end + 1;
    const path_end = std.mem.indexOfScalarPos(u8, request, path_start, ' ') orelse return error.InvalidRequest;
    const path = request[path_start..path_end];
    
    // Find body (after \r\n\r\n)
    const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return error.InvalidRequest;
    const body = request[body_start + 4 ..];
    
    std.debug.print("{} {s} ({} bytes)\n", .{ std.mem.span(method), std.mem.span(path), body.len });
    
    // Route to handler
    if (std.mem.eql(u8, method, "POST")) {
        if (std.mem.startsWith(u8, path, "/v1/chat/completions")) {
            try handleChatCompletion(conn, body);
        } else if (std.mem.startsWith(u8, path, "/v1/messages")) {
            try handleAnthropicMessages(conn, body);
        } else {
            try send404(conn);
        }
    } else {
        try send404(conn);
    }
}

fn handleChatCompletion(conn: *std.Io.net.IpConnection, body: []const u8) !void {
    // Check for tool request
    const has_tools = std.mem.indexOf(u8, body, "\"tools\"") != null;
    
    // Check for tool result (has role: tool)
    const is_tool_result = std.mem.indexOf(u8, body, "\"role\":\"tool\"") != null;
    
    // Check message content for keywords
    const has_weather = std.mem.indexOf(u8, body, "weather") != null;
    const has_hello = std.mem.indexOf(u8, body, "hello") != null;
    const has_error = std.mem.indexOf(u8, body, "test error") != null;
    
    if (has_error) {
        // Return error
        try sendError(conn, 500, "Mock error");
        return;
    }
    
    if (is_tool_result) {
        // Return response after tool execution
        const response = 
            \\{"id":"chatcmpl-mock","object":"chat.completion","created":1234567890,"model":"gpt-4","choices":[{"index":0,"message":{"role":"assistant","content":"The weather in Tokyo is currently sunny with a temperature of 22°C. Perfect day to be outside!"},"finish_reason":"stop"}],"usage":{"prompt_tokens":50,"completion_tokens":20,"total_tokens":70}}
        ;
        try sendJson(conn, response);
        return;
    }
    
    if (has_tools and has_weather) {
        // Return tool call
        const response = 
            \\{"id":"chatcmpl-mock","object":"chat.completion","created":1234567890,"model":"gpt-4","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_mock123","type":"function","function":{"name":"get_weather","arguments":"{\"location\":\"Tokyo, Japan\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":30,"completion_tokens":15,"total_tokens":45}}
        ;
        try sendJson(conn, response);
        return;
    }
    
    if (has_hello) {
        // Return simple greeting
        const response = 
            \\{"id":"chatcmpl-mock","object":"chat.completion","created":1234567890,"model":"gpt-4","choices":[{"index":0,"message":{"role":"assistant","content":"Hello! I'm a mock assistant for testing NullClaw."},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":15,"total_tokens":25}}
        ;
        try sendJson(conn, response);
        return;
    }
    
    // Default response
    const response = 
        \\{"id":"chatcmpl-mock","object":"chat.completion","created":1234567890,"model":"gpt-4","choices":[{"index":0,"message":{"role":"assistant","content":"Default mock response."},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
    ;
    try sendJson(conn, response);
}

fn handleAnthropicMessages(conn: *std.Io.net.IpConnection, body: []const u8) !void {
    _ = body;
    
    // Simple Anthropic mock
    const response = 
        \\{"id":"msg_mock","type":"message","role":"assistant","content":[{"type":"text","text":"Mock Anthropic response."}],"model":"claude-3-sonnet","stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5}}
    ;
    try sendJson(conn, response);
}

fn sendJson(conn: *std.Io.net.IpConnection, json: []const u8) !void {
    var buf: [16384]u8 = undefined;
    
    const response = try std.fmt.bufPrint(&buf, 
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: {}\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "\r\n" ++
        "{s}", 
        .{ json.len, json }
    );
    
    _ = try conn.write(std.Options.debug_io, response);
}

fn sendError(conn: *std.Io.net.IpConnection, code: u16, message: []const u8) !void {
    var buf: [4096]u8 = undefined;
    
    const response = try std.fmt.bufPrint(&buf, 
        "HTTP/1.1 {} Error\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: {}\r\n" ++
        "\r\n" ++
        "{{\"error\":{{\"message\":\"{s}\",\"type\":\"mock_error\"}}}}", 
        .{ code, message.len + 40, message }
    );
    
    _ = try conn.write(std.Options.debug_io, response);
}

fn send404(conn: *std.Io.net.IpConnection) !void {
    const response = 
        "HTTP/1.1 404 Not Found\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 27\r\n" ++
        "\r\n" ++
        "{\"error\":\"Not found\"}"
    ;
    
    _ = try conn.write(std.Options.debug_io, response);
}
