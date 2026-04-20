const std = @import("std");
const root = @import("root.zig");

const Provider = root.Provider;
const ChatRequest = root.ChatRequest;
const ChatResponse = root.ChatResponse;

// ─── Tool Call Response Structures ───────────────────────────────────────────

const OllamaFunction = struct {
    name: []const u8 = "",
    arguments: std.json.Value = .null,
};

const OllamaToolCall = struct {
    id: ?[]const u8 = null,
    function: OllamaFunction = .{},
};

const OllamaMessage = struct {
    role: []const u8 = "",
    content: ?[]const u8 = null,
    thinking: ?[]const u8 = null,
    tool_calls: ?[]const OllamaToolCall = null,
};

const OllamaChatResponse = struct {
    message: OllamaMessage = .{},
};

// ─── Tool Call Helpers ───────────────────────────────────────────────────────

/// Extract actual tool name and arguments from potentially quirky tool call formats.
///
/// Handles 3 patterns local models commonly produce:
/// 1. Nested wrapper: {"name":"tool_call","arguments":{"name":"shell","arguments":{...}}}
/// 2. Prefixed names: "tool.shell" -> "shell"
/// 3. Normal: return as-is
fn extractToolNameAndArgs(
    allocator: std.mem.Allocator,
    name: []const u8,
    arguments: std.json.Value,
) struct { name: []const u8, args: std.json.Value } {
    // Pattern 1: Nested tool_call wrapper
    if (std.mem.eql(u8, name, "tool_call") or
        std.mem.eql(u8, name, "tool.call") or
        std.mem.startsWith(u8, name, "tool_call>") or
        std.mem.startsWith(u8, name, "tool_call<"))
    {
        if (arguments == .object) {
            if (arguments.object.get("name")) |nested_name_val| {
                if (nested_name_val == .string) {
                    const nested_args = if (arguments.object.get("arguments")) |a| a else std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
                    return .{ .name = nested_name_val.string, .args = nested_args };
                }
            }
        }
    }

    // Pattern 2: Prefixed tool name (tool.shell -> shell, tools.shell -> shell)
    if (std.mem.startsWith(u8, name, "tools.")) {
        return .{ .name = name["tools.".len..], .args = arguments };
    }
    if (std.mem.startsWith(u8, name, "tool.")) {
        return .{ .name = name["tool.".len..], .args = arguments };
    }

    // Pattern 3: Normal
    return .{ .name = name, .args = arguments };
}

/// Convert Ollama native tool calls to the JSON format expected by the agent loop.
///
/// Produces OpenAI-compatible JSON:
/// {"content":"","tool_calls":[{"id":"call_0","type":"function","function":{"name":"shell","arguments":"{...}"}}]}
fn formatToolCallsForLoop(
    allocator: std.mem.Allocator,
    message: OllamaMessage,
) ![]const u8 {
    const tool_calls = message.tool_calls orelse return try allocator.dupe(u8, message.content orelse "");
    if (tool_calls.len == 0) return try allocator.dupe(u8, message.content orelse "");

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "{\"content\":\"\",\"tool_calls\":[");

    for (tool_calls, 0..) |tc, i| {
        if (i > 0) try result.append(allocator, ',');

        const extracted = extractToolNameAndArgs(allocator, tc.function.name, tc.function.arguments);

        // Serialize arguments to string
        const args_str = if (extracted.args == .null)
            try allocator.dupe(u8, "{}")
        else
            try std.json.Stringify.valueAlloc(allocator, extracted.args, .{});
        defer allocator.free(args_str);

        // Escape the args_str for embedding in JSON string
        const escaped_args = try jsonEscapeString(allocator, args_str);
        defer allocator.free(escaped_args);

        // Build the call ID
        const call_id = if (tc.id) |id|
            try allocator.dupe(u8, id)
        else
            try std.fmt.allocPrint(allocator, "call_{d}", .{i});
        defer allocator.free(call_id);

        try result.appendSlice(allocator, "{\"id\":\"");
        try result.appendSlice(allocator, call_id);
        try result.appendSlice(allocator, "\",\"type\":\"function\",\"function\":{\"name\":\"");
        try result.appendSlice(allocator, extracted.name);
        try result.appendSlice(allocator, "\",\"arguments\":\"");
        try result.appendSlice(allocator, escaped_args);
        try result.appendSlice(allocator, "\"}}");
    }

    try result.appendSlice(allocator, "]}");

    return try result.toOwnedSlice(allocator);
}

/// Escape a string for embedding inside a JSON string value.
fn jsonEscapeString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn extractDataUriPayload(image: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, image, "data:")) return image;
    const comma = std.mem.indexOfScalar(u8, image, ',') orelse return image;
    const payload = std.mem.trim(u8, image[comma + 1 ..], " \t\r\n");
    if (payload.len == 0) return image;
    return payload;
}

fn appendOllamaImageValue(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    has_images: *bool,
    value: []const u8,
) !void {
    if (!has_images.*) {
        try buf.appendSlice(allocator, ",\"images\":[\"");
        has_images.* = true;
    } else {
        try buf.appendSlice(allocator, ",\"");
    }
    const escaped = try jsonEscapeString(allocator, value);
    defer allocator.free(escaped);
    try buf.appendSlice(allocator, escaped);
    try buf.append(allocator, '"');
}

/// Ollama local LLM provider.
///
/// Endpoints:
/// - POST {base_url}/api/chat
/// - No authentication required (local service)
pub const OllamaProvider = struct {
    base_url: []const u8,
    allocator: std.mem.Allocator,
    http_client: std.http.Client,

    const DEFAULT_BASE_URL = "http://localhost:11434";

    pub fn init(allocator: std.mem.Allocator, base_url: ?[]const u8) OllamaProvider {
        const url = if (base_url) |u| trimTrailingSlash(u) else DEFAULT_BASE_URL;
        const io = @import("../http_util.zig").getThreadedIo();
        return .{
            .base_url = url,
            .allocator = allocator,
            .http_client = .{ .allocator = allocator, .io = io },
        };
    }

    fn trimTrailingSlash(s: []const u8) []const u8 {
        if (s.len > 0 and s[s.len - 1] == '/') {
            return s[0 .. s.len - 1];
        }
        return s;
    }

    /// Build the chat endpoint URL.
    pub fn chatUrl(self: OllamaProvider, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}/api/chat", .{self.base_url});
    }

    /// Build an Ollama chat request JSON body.
    pub fn buildRequestBody(
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) ![]const u8 {
        if (system_prompt) |sys| {
            return std.fmt.allocPrint(allocator,
                \\{{"model":"{s}","messages":[{{"role":"system","content":"{s}"}},{{"role":"user","content":"{s}"}}],"stream":false,"options":{{"temperature":{d:.2}}}}}
            , .{ model, sys, message, temperature });
        } else {
            return std.fmt.allocPrint(allocator,
                \\{{"model":"{s}","messages":[{{"role":"user","content":"{s}"}}],"stream":false,"options":{{"temperature":{d:.2}}}}}
            , .{ model, message, temperature });
        }
    }

    /// Parse an Ollama response, handling tool calls, thinking-only, and plain text.
    pub fn parseResponse(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
        // First try to parse as OllamaChatResponse
        const parsed = std.json.parseFromSlice(OllamaChatResponse, allocator, body, .{
            .ignore_unknown_fields = true,
        });

        if (parsed) |p| {
            defer p.deinit();
            const message = p.value.message;

            // If model returned tool calls, format them for the agent loop
            if (message.tool_calls) |tcs| {
                if (tcs.len > 0) {
                    return formatToolCallsForLoop(allocator, message);
                }
            }

            // Plain text response
            if (message.content) |content| {
                if (content.len > 0) {
                    // Check if content itself is a tool call (some models put it in content field)
                    if (looksLikeDirectToolCall(content)) {
                        return convertDirectToolCall(allocator, content);
                    }
                    return try allocator.dupe(u8, content);
                }
            }

            // Thinking-only response (model reasoned but produced no output)
            if (message.thinking) |thinking| {
                const preview_len = @min(thinking.len, 200);
                return try std.fmt.allocPrint(
                    allocator,
                    "I was thinking about this: {s}... but I didn't complete my response. Could you try asking again?",
                    .{thinking[0..preview_len]},
                );
            }

            // Empty response
            return try allocator.dupe(u8, "");
        } else |_| {
            // If structured parsing fails, check if body is a tool call in various formats
            // JSON format: {"name":"tool","arguments":{...}}
            if (looksLikeDirectToolCall(body)) {
                return convertDirectToolCall(allocator, body);
            }
            // XML format: <invoke name="tool"><parameter name="arg">value</parameter></invoke>
            if (looksLikeXMLToolCall(body)) {
                return convertXMLToolCall(allocator, body);
            }
            // Not a tool call, return as-is
            return allocator.dupe(u8, body);
        }
    }

    /// Check if JSON looks like a direct tool call: {"name":"tool","arguments":{...}}
    fn looksLikeDirectToolCall(json: []const u8) bool {
        const trimmed = std.mem.trim(u8, json, " \t\r\n");
        return std.mem.startsWith(u8, trimmed, "{\"name\":") and
            std.mem.indexOf(u8, trimmed, "\"arguments\":") != null;
    }

    /// Convert a direct tool call JSON to OpenAI format for the agent loop
    fn convertDirectToolCall(allocator: std.mem.Allocator, json: []const u8) ![]const u8 {
        // Parse {"name":"...","arguments":{...}}
        const parsed = try std.json.parseFromSlice(struct { name: []const u8, arguments: std.json.Value }, allocator, json, .{});
        defer parsed.deinit();

        const name = parsed.value.name;
        const args = parsed.value.arguments;

        // Stringify arguments
        const args_str = try std.json.Stringify.valueAlloc(allocator, args, .{});
        defer allocator.free(args_str);

        // Format as OpenAI tool call
        return try std.fmt.allocPrint(allocator, "{{\"content\":\"\",\"tool_calls\":[{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":\"{s}\"}}}}]}}", .{ name, args_str });
    }

    /// Check if content looks like XML tool call: <invoke name="..."><parameter name="...">...</parameter></invoke>
    fn looksLikeXMLToolCall(content: []const u8) bool {
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        // Check for various XML tool call formats
        const has_invoke = std.mem.indexOf(u8, trimmed, "<invoke") != null or
            std.mem.indexOf(u8, trimmed, "{\"invoke") != null or
            std.mem.indexOf(u8, trimmed, "<invoke>") != null;
        const has_parameter = std.mem.indexOf(u8, trimmed, "<parameter") != null;
        return has_invoke and has_parameter;
    }

    /// Convert XML tool call to OpenAI format for the agent loop
    fn convertXMLToolCall(allocator: std.mem.Allocator, xml: []const u8) ![]const u8 {
        // Handle mixed format: {"invoke name="shell">...</invoke>}
        // Skip the opening { if present
        const content = if (std.mem.startsWith(u8, xml, "{\"invoke")) xml[1..] else xml;

        // Extract tool name from <invoke name="...">
        var tool_name: []const u8 = "";
        if (std.mem.indexOf(u8, content, "<invoke name=\"")) |start| {
            const name_start = start + "<invoke name=\"".len;
            if (std.mem.indexOfScalarPos(u8, content, name_start, '"')) |name_end| {
                tool_name = content[name_start..name_end];
            }
        } else if (std.mem.indexOf(u8, content, "<invoke>")) |start| {
            // Try nested format: <invoke><name>shell</name>...
            const name_tag_start = start + "<invoke>".len;
            if (std.mem.indexOfPos(u8, content, name_tag_start, "<name>")) |name_start| {
                const val_start = name_start + "<name>".len;
                if (std.mem.indexOfPos(u8, content, val_start, "</name>")) |name_end| {
                    tool_name = content[val_start..name_end];
                }
            }
        }

        // If no tool name found, return as-is (not a valid tool call)
        if (tool_name.len == 0) {
            return allocator.dupe(u8, xml);
        }

        // Extract parameters
        var args_obj = std.json.ObjectMap.init(allocator);
        var param_idx = std.mem.indexOf(u8, content, "<parameter");
        while (param_idx != null) : (param_idx = std.mem.indexOfPos(u8, content, param_idx.?, "<parameter")) {
            const param_start = param_idx.? + "<parameter".len;
            // Skip whitespace and find name="
            var name_start = param_start;
            while (name_start < content.len and (content[name_start] == ' ' or content[name_start] == '\t')) : (name_start += 1) {}

            if (name_start >= content.len or !std.mem.startsWith(u8, content[name_start..], "name=\"")) {
                break;
            }

            const val_start = name_start + "name=\"".len;
            const val_end = std.mem.indexOfScalarPos(u8, content, val_start, '"') orelse break;
            const param_name = content[val_start..val_end];

            // Find closing >
            const gt_pos = std.mem.indexOfScalarPos(u8, content, val_end, '>') orelse break;
            const content_start = gt_pos + 1;

            // Find closing </parameter>
            const close_tag = std.mem.indexOfPos(u8, content, content_start, "</parameter>") orelse break;
            const param_value = content[content_start..close_tag];

            // Store in args object
            const key_copy = try allocator.dupe(u8, param_name);
            const val_copy = try allocator.dupe(u8, param_value);
            try args_obj.put(key_copy, std.json.Value{ .string = val_copy });

            param_idx = close_tag + "</parameter>".len;
        }

        // Build arguments JSON string
        const args_str = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = args_obj }, .{});
        defer allocator.free(args_str);

        // Format as OpenAI tool call
        return try std.fmt.allocPrint(allocator, "{{\"content\":\"\",\"tool_calls\":[{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":\"{s}\"}}}}]}}", .{ tool_name, args_str });
    }

    /// Create a Provider interface from this OllamaProvider.
    pub fn provider(self: *OllamaProvider) Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystemImpl,
        .chat = chatImpl,
        .supportsNativeTools = supportsNativeToolsImpl,
        .supports_vision = supportsVisionImpl,
        .getName = getNameImpl,
        .deinit = deinitImpl,
        .resetConnections = resetConnectionsImpl,
    };

    fn resetConnectionsImpl(ptr: *anyopaque) void {
        const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
        self.resetConnections();
    }

    fn chatWithSystemImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) anyerror![]const u8 {
        const self: *OllamaProvider = @ptrCast(@alignCast(ptr));

        var url_buf: [2048]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/api/chat", .{self.base_url}) catch return error.OllamaApiError;

        const body = try buildRequestBody(allocator, system_prompt, message, model, temperature);
        defer allocator.free(body);

        const resp_body = self.httpPost(allocator, url, body, &.{}, 0) catch return error.OllamaApiError;
        defer allocator.free(resp_body);

        return parseResponse(allocator, resp_body);
    }

    fn chatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        temperature: f64,
    ) anyerror!ChatResponse {
        const self: *OllamaProvider = @ptrCast(@alignCast(ptr));

        var url_buf: [2048]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/api/chat", .{self.base_url}) catch return error.OllamaApiError;

        const body = try buildChatRequestBody(allocator, request, model, temperature);
        defer allocator.free(body);

        const resp_body = self.httpPost(allocator, url, body, &.{}, request.timeout_secs) catch return error.OllamaApiError;
        defer allocator.free(resp_body);

        const text = try parseResponse(allocator, resp_body);
        return ChatResponse{ .content = text };
    }

    fn supportsNativeToolsImpl(_: *anyopaque) bool {
        return true; // Ollama supports tool calling via tools parameter
    }

    fn supportsVisionImpl(_: *anyopaque) bool {
        return true;
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "Ollama";
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    pub fn deinit(self: *OllamaProvider) void {
        self.http_client.deinit();
    }

    /// Reset HTTP client connections (recreate client to clear stale connections)
    pub fn resetConnections(self: *OllamaProvider) void {
        self.http_client.deinit();
        const io = @import("../http_util.zig").getThreadedIo();
        self.http_client = .{ .allocator = self.allocator, .io = io };
    }

    /// Persistent HTTP POST using the provider's HTTP client (connection reuse).
    pub fn httpPost(self: *OllamaProvider, allocator: std.mem.Allocator, url: []const u8, body: []const u8, headers: []const []const u8, timeout_secs: u64) ![]u8 {
        _ = timeout_secs; // TODO: Add timeout support

        const uri = try std.Uri.parse(url);

        // Build headers array
        var header_buf: [32]std.http.Header = undefined;
        var n_headers: usize = 0;
        header_buf[n_headers] = .{ .name = "content-type", .value = "application/json" };
        n_headers += 1;
        for (headers) |header| {
            if (n_headers >= header_buf.len) break;
            const colon_idx = std.mem.indexOfScalar(u8, header, ':') orelse continue;
            const name = header[0..colon_idx];
            const value = std.mem.trim(u8, header[colon_idx + 1 ..], " \t\r\n");
            header_buf[n_headers] = .{ .name = name, .value = value };
            n_headers += 1;
        }
        const extra_headers = header_buf[0..n_headers];

        var req = try self.http_client.request(.POST, uri, .{
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        const body_dup = try allocator.dupe(u8, body);
        defer allocator.free(body_dup);
        try req.sendBodyComplete(body_dup);

        var redirect_buf: [4096]u8 = undefined;
        const response = try req.receiveHead(&redirect_buf);

        // Read response body
        var transfer_buf: [16384]u8 = undefined;
        const body_reader = req.reader.bodyReader(&transfer_buf, response.head.transfer_encoding, response.head.content_length);

        var response_body = std.ArrayListUnmanaged(u8).empty;
        errdefer response_body.deinit(allocator);

        while (true) {
            body_reader.fill(4096) catch |err| {
                if (err == error.EndOfStream) {
                    const buffered = body_reader.bufferedLen();
                    if (buffered == 0) break;
                    const data = try body_reader.take(buffered);
                    try response_body.appendSlice(allocator, data);
                    break;
                }
                return err;
            };

            const buffered = body_reader.bufferedLen();
            if (buffered == 0) break;

            const data = try body_reader.take(buffered);
            if (data.len == 0) break;
            try response_body.appendSlice(allocator, data);
        }

        return response_body.toOwnedSlice(allocator);
    }
};

/// Build a full chat request JSON body from a ChatRequest (Ollama format).
fn buildChatRequestBody(
    allocator: std.mem.Allocator,
    request: ChatRequest,
    model: []const u8,
    temperature: f64,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"model\":\"");
    try buf.appendSlice(allocator, model);
    try buf.appendSlice(allocator, "\",\"messages\":[");

    for (request.messages, 0..) |msg, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"role\":\"");
        try buf.appendSlice(allocator, msg.role.toSlice());
        try buf.appendSlice(allocator, "\",\"content\":\"");
        const escaped = try jsonEscapeString(allocator, msg.content);
        defer allocator.free(escaped);
        try buf.appendSlice(allocator, escaped);
        try buf.append(allocator, '"');
        // Append images array if content_parts contains base64 images
        if (msg.content_parts) |parts| {
            var has_images = false;
            for (parts) |part| {
                switch (part) {
                    .image_base64 => |img| {
                        try appendOllamaImageValue(&buf, allocator, &has_images, img.data);
                    },
                    .image_url => |img| {
                        // Ollama API only supports base64-encoded images, not URLs.
                        // Extract payload from data: URIs; skip regular HTTP URLs.
                        if (std.mem.startsWith(u8, img.url, "data:")) {
                            const value = extractDataUriPayload(img.url);
                            try appendOllamaImageValue(&buf, allocator, &has_images, value);
                        }
                    },
                    else => {},
                }
            }
            if (has_images) try buf.append(allocator, ']');
        }
        try buf.append(allocator, '}');
    }

    try buf.appendSlice(allocator, "],\"stream\":false");

    // Add tools if present (Ollama uses OpenAI-compatible tool format)
    if (request.tools) |tools| {
        if (tools.len > 0) {
            try buf.appendSlice(allocator, ",\"tools\":");
            try root.convertToolsOpenAI(&buf, allocator, tools);
        }
    }

    try buf.appendSlice(allocator, ",\"options\":{\"temperature\":");
    var temp_buf: [16]u8 = undefined;
    const temp_str = std.fmt.bufPrint(&temp_buf, "{d:.2}", .{temperature}) catch return error.OllamaApiError;
    try buf.appendSlice(allocator, temp_str);
    try buf.appendSlice(allocator, "}}");

    return try buf.toOwnedSlice(allocator);
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "default url" {
    const p = OllamaProvider.init(std.testing.allocator, null);
    try std.testing.expectEqualStrings("http://localhost:11434", p.base_url);
}

test "custom url trailing slash" {
    const p = OllamaProvider.init(std.testing.allocator, "http://192.168.1.100:11434/");
    try std.testing.expectEqualStrings("http://192.168.1.100:11434", p.base_url);
}

test "chat url is correct" {
    const p = OllamaProvider.init(std.testing.allocator, null);
    const url = try p.chatUrl(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://localhost:11434/api/chat", url);
}

test "buildRequestBody with system" {
    const body = try OllamaProvider.buildRequestBody(std.testing.allocator, "You are helpful", "hello", "llama3", 0.7);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "llama3") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "system") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "temperature") != null);
}

test "buildRequestBody without system" {
    const body = try OllamaProvider.buildRequestBody(std.testing.allocator, null, "test", "mistral", 0.0);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "mistral") != null);
}

test "parseResponse extracts content" {
    const body =
        \\{"message":{"role":"assistant","content":"Hello from Ollama!"}}
    ;
    const result = try OllamaProvider.parseResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello from Ollama!", result);
}

test "parseResponse empty content" {
    const body =
        \\{"message":{"role":"assistant","content":""}}
    ;
    const result = try OllamaProvider.parseResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "supportsNativeTools returns true" {
    var p = OllamaProvider.init(std.testing.allocator, null);
    const prov = p.provider();
    try std.testing.expect(prov.supportsNativeTools());
}

// ─── Tool Call Tests ─────────────────────────────────────────────────────────

test "extractToolNameAndArgs with normal name" {
    const result = extractToolNameAndArgs(std.testing.allocator, "shell", .null);
    try std.testing.expectEqualStrings("shell", result.name);
}

test "extractToolNameAndArgs with tool. prefix" {
    const result = extractToolNameAndArgs(std.testing.allocator, "tool.shell", .null);
    try std.testing.expectEqualStrings("shell", result.name);
}

test "extractToolNameAndArgs with tools. prefix" {
    const result = extractToolNameAndArgs(std.testing.allocator, "tools.file_read", .null);
    try std.testing.expectEqualStrings("file_read", result.name);
}

test "ollama buildChatRequestBody with images" {
    const alloc = std.testing.allocator;
    const cp = &[_]root.ContentPart{
        .{ .text = "Describe this image" },
        .{ .image_base64 = .{ .data = "iVBOR", .media_type = "image/png" } },
    };
    var msgs = [_]root.ChatMessage{
        .{ .role = .user, .content = "Describe this image", .content_parts = cp },
    };
    const body = try buildChatRequestBody(alloc, .{ .messages = &msgs, .model = "llava" }, "llava", 0.7);
    defer alloc.free(body);
    // Verify valid JSON and images array present
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const messages_arr = parsed.value.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 1), messages_arr.items.len);
    const msg_obj = messages_arr.items[0].object;
    try std.testing.expectEqualStrings("Describe this image", msg_obj.get("content").?.string);
    const images = msg_obj.get("images").?.array;
    try std.testing.expectEqual(@as(usize, 1), images.items.len);
    try std.testing.expectEqualStrings("iVBOR", images.items[0].string);
}

test "ollama buildChatRequestBody without content_parts" {
    const alloc = std.testing.allocator;
    var msgs = [_]root.ChatMessage{
        root.ChatMessage.user("Hello"),
    };
    const body = try buildChatRequestBody(alloc, .{ .messages = &msgs, .model = "llama3" }, "llama3", 0.7);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const messages_arr = parsed.value.object.get("messages").?.array;
    const msg_obj = messages_arr.items[0].object;
    // No images field when no content_parts
    try std.testing.expect(msg_obj.get("images") == null);
}

test "ollama buildChatRequestBody with data URI image_url extracts base64 payload" {
    const alloc = std.testing.allocator;
    const cp = &[_]root.ContentPart{
        .{ .image_url = .{ .url = "data:image/png;base64,iVBORw0KGgo=" } },
    };
    var msgs = [_]root.ChatMessage{
        .{ .role = .user, .content = "Describe", .content_parts = cp },
    };
    const body = try buildChatRequestBody(alloc, .{ .messages = &msgs, .model = "llava" }, "llava", 0.7);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const msg_obj = parsed.value.object.get("messages").?.array.items[0].object;
    const images = msg_obj.get("images").?.array;
    try std.testing.expectEqual(@as(usize, 1), images.items.len);
    try std.testing.expectEqualStrings("iVBORw0KGgo=", images.items[0].string);
}

test "ollama buildChatRequestBody skips HTTP URL image_url" {
    const alloc = std.testing.allocator;
    const cp = &[_]root.ContentPart{
        .{ .image_url = .{ .url = "https://example.com/cat.jpg" } },
    };
    var msgs = [_]root.ChatMessage{
        .{ .role = .user, .content = "Describe", .content_parts = cp },
    };
    const body = try buildChatRequestBody(alloc, .{ .messages = &msgs, .model = "llava" }, "llava", 0.7);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const msg_obj = parsed.value.object.get("messages").?.array.items[0].object;
    // HTTP URLs are not supported by Ollama — should be skipped
    try std.testing.expect(msg_obj.get("images") == null);
}

test "extractToolNameAndArgs with nested tool_call wrapper" {
    // Build a JSON object: {"name":"shell","arguments":{"command":"date"}}
    const json_str =
        \\{"name":"shell","arguments":{"command":"date"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{});
    defer parsed.deinit();

    const result = extractToolNameAndArgs(std.testing.allocator, "tool_call", parsed.value);
    try std.testing.expectEqualStrings("shell", result.name);
    // The inner arguments should contain "command"
    try std.testing.expect(result.args == .object);
    const cmd = result.args.object.get("command") orelse return error.MissingField;
    try std.testing.expect(cmd == .string);
    try std.testing.expectEqualStrings("date", cmd.string);
}

test "extractToolNameAndArgs with tool.call wrapper" {
    const json_str =
        \\{"name":"file_read","arguments":{"path":"/tmp"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{});
    defer parsed.deinit();

    const result = extractToolNameAndArgs(std.testing.allocator, "tool.call", parsed.value);
    try std.testing.expectEqualStrings("file_read", result.name);
}

test "formatToolCallsForLoop with single tool call" {
    const alloc = std.testing.allocator;
    const json_str =
        \\{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_abc","function":{"name":"shell","arguments":{"command":"date"}}}]}}
    ;
    const parsed = try std.json.parseFromSlice(OllamaChatResponse, alloc, json_str, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const result = try formatToolCallsForLoop(alloc, parsed.value.message);
    defer alloc.free(result);

    // Verify it's valid JSON
    const verify = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer verify.deinit();

    // Should have tool_calls array
    const tool_calls = verify.value.object.get("tool_calls").?.array;
    try std.testing.expect(tool_calls.items.len == 1);

    // Check function name
    const func = tool_calls.items[0].object.get("function").?;
    try std.testing.expectEqualStrings("shell", func.object.get("name").?.string);

    // Arguments should be a string (JSON-encoded)
    try std.testing.expect(func.object.get("arguments").? == .string);

    // Check ID
    try std.testing.expectEqualStrings("call_abc", tool_calls.items[0].object.get("id").?.string);
}

test "formatToolCallsForLoop with no tool calls returns content" {
    const alloc = std.testing.allocator;
    const msg = OllamaMessage{
        .role = "assistant",
        .content = "Hello there!",
        .tool_calls = null,
    };
    const result = try formatToolCallsForLoop(alloc, msg);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("Hello there!", result);
}

test "formatToolCallsForLoop with empty tool calls returns content" {
    const alloc = std.testing.allocator;
    const empty_tcs: []const OllamaToolCall = &.{};
    const msg = OllamaMessage{
        .role = "assistant",
        .content = "Fallback content",
        .tool_calls = empty_tcs,
    };
    const result = try formatToolCallsForLoop(alloc, msg);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("Fallback content", result);
}

test "formatToolCallsForLoop generates call_N id when id is null" {
    const alloc = std.testing.allocator;
    const tcs = [_]OllamaToolCall{.{
        .id = null,
        .function = .{ .name = "shell", .arguments = .null },
    }};
    const msg = OllamaMessage{
        .role = "assistant",
        .content = "",
        .tool_calls = &tcs,
    };
    const result = try formatToolCallsForLoop(alloc, msg);
    defer alloc.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"call_0\"") != null);
}

test "parseResponse with tool calls produces formatted JSON" {
    const alloc = std.testing.allocator;
    const body =
        \\{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","function":{"name":"shell","arguments":{"command":"ls"}}}]}}
    ;
    const result = try OllamaProvider.parseResponse(alloc, body);
    defer alloc.free(result);

    // Should be valid JSON with tool_calls
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("tool_calls") != null);
}

test "parseResponse thinking-only returns fallback message" {
    const alloc = std.testing.allocator;
    const body =
        \\{"message":{"role":"assistant","content":"","thinking":"Let me reason about this carefully..."}}
    ;
    const result = try OllamaProvider.parseResponse(alloc, body);
    defer alloc.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "I was thinking about this") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Let me reason") != null);
}

test "parseResponse with tool_call nested wrapper unwraps correctly" {
    const alloc = std.testing.allocator;
    const body =
        \\{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"tool_call","arguments":{"name":"shell","arguments":{"command":"whoami"}}}}]}}
    ;
    const result = try OllamaProvider.parseResponse(alloc, body);
    defer alloc.free(result);

    // The formatted output should contain the unwrapped tool name "shell"
    try std.testing.expect(std.mem.indexOf(u8, result, "\"shell\"") != null);
    // And should NOT have "tool_call" as the function name
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"tool_call\"") == null);
}

test "jsonEscapeString escapes quotes and backslashes" {
    const alloc = std.testing.allocator;
    const result = try jsonEscapeString(alloc, "he said \"hello\\world\"");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("he said \\\"hello\\\\world\\\"", result);
}
