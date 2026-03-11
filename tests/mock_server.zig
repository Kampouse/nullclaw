const std = @import("std");

/// Simple mock HTTP server for testing NullClaw providers
/// Simulates OpenAI API responses without external dependencies

pub fn main() !void {
    const port: u16 = 4010;
    
    // Initialize threaded IO properly
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var server = try address.listen(io, .{
        .reuse_address = true,
    });
    defer server.deinit(io);
    
    std.debug.print("NullClaw Mock Server listening on http://127.0.0.1:{}\n", .{port});
    std.debug.print("Endpoints:\n", .{});
    std.debug.print("  POST /v1/chat/completions - Chat completion\n", .{});
    std.debug.print("  POST /v1/messages - Anthropic messages\n", .{});
    std.debug.print("\n", .{});
    
    while (true) {
        var stream = server.accept(io) catch continue;
        defer stream.close(io);
        
        handleConnection(&stream, io) catch |err| {
            std.debug.print("Connection error: {}\n", .{err});
        };
    }
}

fn handleConnection(stream: *std.Io.net.Stream, io: std.Io) !void {
    var read_buf: [8192]u8 = undefined;
    var conn_reader = stream.reader(io, &read_buf);
    
    // Read HTTP request using buffered() for non-blocking read
    // First peek triggers the actual read into buffer
    _ = conn_reader.interface.peek(1) catch |err| {
        if (err == error.EndOfStream) return error.EmptyRequest;
        return err;
    };
    
    // Get what's buffered - this IS our read_buf
    var buffered_data = conn_reader.interface.buffered();
    if (buffered_data.len == 0) return error.EmptyRequest;
    
    var total_read = buffered_data.len;
    conn_reader.interface.toss(total_read);
    
    // Check if we have headers complete
    var request = buffered_data[0..total_read];
    
    // Find Content-Length if present
    const header_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return error.InvalidRequest;
    const headers = request[0..header_end];
    
    // Parse Content-Length
    var content_length: usize = 0;
    if (std.mem.indexOf(u8, headers, "Content-Length:")) |cl_pos| {
        const cl_start = cl_pos + 15;
        const cl_end = std.mem.indexOfScalarPos(u8, headers, cl_start, '\r') orelse cl_start;
        const cl_str = std.mem.trim(u8, headers[cl_start..cl_end], " ");
        content_length = std.fmt.parseInt(usize, cl_str, 10) catch 0;
    }
    
    // Read remaining body if needed
    const body_start = header_end + 4;
    const expected_body_end = body_start + content_length;
    
    if (total_read < expected_body_end) {
        // Need more data - peek again
        const remaining = expected_body_end - total_read;
        if (conn_reader.interface.peek(remaining)) |more| {
            total_read += more.len;
            conn_reader.interface.toss(more.len);
            request = buffered_data[0..total_read];
        } else |_| {
            // EndOfStream or other error - use what we have
        }
    }
    
    // Parse HTTP request
    const method_end = std.mem.indexOfScalar(u8, request, ' ') orelse return error.InvalidRequest;
    const method = request[0..method_end];
    
    const path_start = method_end + 1;
    const path_end = std.mem.indexOfScalarPos(u8, request, path_start, ' ') orelse return error.InvalidRequest;
    const path = request[path_start..path_end];
    
    // Body starts after headers (already computed as body_start above)
    const body = request[body_start..];
    
    std.debug.print("{s} {s} ({} bytes)\n", .{ method, path, body.len });
    
    // Route to handler
    if (std.mem.eql(u8, method, "POST")) {
        if (std.mem.startsWith(u8, path, "/v1/chat/completions")) {
            try handleChatCompletion(stream, body, io);
        } else if (std.mem.startsWith(u8, path, "/v1/messages")) {
            try handleAnthropicMessages(stream, body, io);
        } else {
            try send404(stream, io);
        }
    } else {
        try send404(stream, io);
    }
}

fn handleChatCompletion(stream: *std.Io.net.Stream, body: []const u8, io: std.Io) !void {
    // Check for streaming request
    const is_streaming = std.mem.indexOf(u8, body, "\"stream\":true") != null or
        std.mem.indexOf(u8, body, "\"stream\": true") != null;
    
    // Check for tool request
    const has_tools = std.mem.indexOf(u8, body, "\"tools\"") != null;
    
    // Check for tool result (has role: tool)
    const is_tool_result = std.mem.indexOf(u8, body, "\"role\":\"tool\"") != null;
    
    // Check message content for keywords
    const has_weather = std.mem.indexOf(u8, body, "weather") != null;
    const has_hello = std.mem.indexOf(u8, body, "hello") != null;
    const has_error_msg = std.mem.indexOf(u8, body, "test error") != null;
    
    if (has_error_msg) {
        try sendError(stream, 500, "Mock error", io);
        return;
    }
    
    // Handle streaming request
    if (is_streaming) {
        try sendStreamingResponse(stream, "Hello! Mock assistant here.", io);
        return;
    }
    
    if (is_tool_result) {
        const response = 
            \\{"id":"chatcmpl-mock","object":"chat.completion","created":1234567890,"model":"gpt-4","choices":[{"index":0,"message":{"role":"assistant","content":"The weather in Tokyo is sunny, 22°C."},"finish_reason":"stop"}],"usage":{"prompt_tokens":50,"completion_tokens":20,"total_tokens":70}}
        ;
        try sendJson(stream, response, io);
        return;
    }
    
    if (has_tools and has_weather) {
        const response = 
            \\{"id":"chatcmpl-mock","object":"chat.completion","created":1234567890,"model":"gpt-4","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_mock123","type":"function","function":{"name":"get_weather","arguments":"{\"location\":\"Tokyo, Japan\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":30,"completion_tokens":15,"total_tokens":45}}
        ;
        try sendJson(stream, response, io);
        return;
    }
    
    if (has_hello) {
        const response = 
            \\{"id":"chatcmpl-mock","object":"chat.completion","created":1234567890,"model":"gpt-4","choices":[{"index":0,"message":{"role":"assistant","content":"Hello! Mock assistant here."},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":15,"total_tokens":25}}
        ;
        try sendJson(stream, response, io);
        return;
    }
    
    // Default response
    const response = 
        \\{"id":"chatcmpl-mock","object":"chat.completion","created":1234567890,"model":"gpt-4","choices":[{"index":0,"message":{"role":"assistant","content":"Default mock response."},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
    ;
    try sendJson(stream, response, io);
}

/// Send SSE streaming response (OpenAI format)
fn sendStreamingResponse(stream: *std.Io.net.Stream, content: []const u8, io: std.Io) !void {
    var write_buf: [16384]u8 = undefined;
    var conn_writer = stream.writer(io, &write_buf);
    
    // Send SSE headers
    try std.Io.Writer.writeAll(&conn_writer.interface, 
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "\r\n"
    );
    try std.Io.Writer.flush(&conn_writer.interface);
    
    // Split content into chunks for realistic streaming
    const chunk_size = 5;
    var pos: usize = 0;
    var chunk_idx: usize = 0;
    
    while (pos < content.len) {
        const end = @min(pos + chunk_size, content.len);
        const chunk = content[pos..end];
        
        // Build SSE event with OpenAI streaming format
        // Format: data: {...}\n\n
        var delta_buf: [1024]u8 = undefined;
        const delta_with_chunk = std.fmt.bufPrint(&delta_buf, 
            \\{{"id":"chatcmpl-mock","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4","choices":[{{"index":0,"delta":{{"content":"{s}"}},"finish_reason":null}}]}}
        , .{chunk}) catch continue;
        
        try std.Io.Writer.print(&conn_writer.interface, "data: {s}\n\n", .{delta_with_chunk});
        try std.Io.Writer.flush(&conn_writer.interface);
        
        pos = end;
        chunk_idx += 1;
    }
    
    // Send final chunk with finish_reason
    const final_chunk = 
        \\{"id":"chatcmpl-mock","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
    ;
    try std.Io.Writer.print(&conn_writer.interface, "data: {s}\n\n", .{final_chunk});
    try std.Io.Writer.flush(&conn_writer.interface);
    
    // Send [DONE] marker
    try std.Io.Writer.writeAll(&conn_writer.interface, "data: [DONE]\n\n");
    try std.Io.Writer.flush(&conn_writer.interface);
}

fn handleAnthropicMessages(stream: *std.Io.net.Stream, body: []const u8, io: std.Io) !void {
    _ = body;
    
    const response = 
        \\{"id":"msg_mock","type":"message","role":"assistant","content":[{"type":"text","text":"Mock Anthropic response."}],"model":"claude-3-sonnet","stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5}}
    ;
    try sendJson(stream, response, io);
}

fn sendJson(stream: *std.Io.net.Stream, json: []const u8, io: std.Io) !void {
    var write_buf: [16384]u8 = undefined;
    var conn_writer = stream.writer(io, &write_buf);
    
    try std.Io.Writer.print(&conn_writer.interface, 
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: {}\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "{s}", 
        .{ json.len, json }
    );
    
    try std.Io.Writer.flush(&conn_writer.interface);
}

fn sendError(stream: *std.Io.net.Stream, code: u16, message: []const u8, io: std.Io) !void {
    var write_buf: [4096]u8 = undefined;
    var conn_writer = stream.writer(io, &write_buf);
    
    try std.Io.Writer.print(&conn_writer.interface, 
        "HTTP/1.1 {} Error\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: {}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "{{\"error\":{{\"message\":\"{s}\",\"type\":\"mock_error\"}}}}", 
        .{ code, message.len + 40, message }
    );
    
    try std.Io.Writer.flush(&conn_writer.interface);
}

fn send404(stream: *std.Io.net.Stream, io: std.Io) !void {
    var write_buf: [1024]u8 = undefined;
    var conn_writer = stream.writer(io, &write_buf);
    
    try std.Io.Writer.writeAll(&conn_writer.interface, 
        "HTTP/1.1 404 Not Found\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 27\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "{\"error\":\"Not found\"}"
    );
    
    try std.Io.Writer.flush(&conn_writer.interface);
}
