const AnthropicSseResult = union(enum) {
    delta: []const u8,
    usage: u32,
    done: void,
    skip: void,
    event: []const u8,
};

const std = @import("std");
const root = @import("root.zig");
const helpers = @import("helpers.zig");
const slog = @import("../structured_log.zig");

/// Result of parsing a single SSE line.
pub const SseLineResult = union(enum) {
    /// Text delta content (owned, caller frees).
    delta: []const u8,
    /// Stream is complete ([DONE] sentinel).
    done: void,
    /// Line should be skipped (empty, comment, or no content).
    skip: void,
    /// Tool call delta from OpenAI streaming format.
    /// `index` identifies which tool call this chunk belongs to.
    /// `id`, `name` are set only on the first chunk for a given index.
    /// `arguments` is a fragment to be concatenated with previous fragments.
    tool_call_delta: ToolCallDelta,
};

/// A fragment of a tool call received during streaming.
pub const ToolCallDelta = struct {
    index: u32,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: []const u8 = "",
};

/// Parse a single SSE line in OpenAI streaming format.
///
/// Handles:
/// - `data: [DONE]` → `.done`
/// - `data: {JSON}` → extracts `choices[0].delta.content` → `.delta`
/// - `data: {JSON}` → extracts `choices[0].delta.tool_calls[]` → `.tool_call_delta`
/// - Empty lines, comments (`:`) → `.skip`
pub fn parseSseLine(allocator: std.mem.Allocator, line: []const u8) !SseLineResult {
    // const data_prefix = "data: "; // unused in Zig 0.16.0 stub
    const trimmed = std.mem.trimEnd(u8, line, "\r");

    if (trimmed.len == 0) return .skip;
    if (trimmed[0] == ':') return .skip;

    const prefix = "data: ";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return .skip;

    const data = trimmed[prefix.len..];

    if (std.mem.eql(u8, data, "[DONE]")) return .done;

    // Try tool_call deltas first (before text delta, since some chunks have both)
    const tc_delta = try extractToolCallDelta(allocator, data);
    if (tc_delta) |tcd| return .{ .tool_call_delta = tcd };

    // Try text delta
    const content = try extractDeltaContent(allocator, data) orelse return .skip;
    return .{ .delta = content };
}

/// Extract `choices[0].delta.content` from an SSE JSON payload.
/// Returns owned slice or null if no content found.
pub fn extractDeltaContent(allocator: std.mem.Allocator, json_str: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.InvalidSseJson;
    defer parsed.deinit();

    const obj = parsed.value.object;
    const choices = obj.get("choices") orelse return null;
    if (choices != .array or choices.array.items.len == 0) return null;

    const first = choices.array.items[0];
    if (first != .object) return null;

    const delta = first.object.get("delta") orelse return null;
    if (delta != .object) return null;

    const content = delta.object.get("content") orelse return null;
    if (content != .string) return null;
    if (content.string.len == 0) return null;

    return try helpers.sanitizeResponseContent(allocator, content.string);
}

/// Extract `choices[0].delta.tool_calls[]` from an OpenAI SSE JSON payload.
/// Returns the first tool_call delta found, or null if none.
pub fn extractToolCallDelta(allocator: std.mem.Allocator, json_str: []const u8) !?ToolCallDelta {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return null;
    defer parsed.deinit();

    const obj = parsed.value.object;
    const choices = obj.get("choices") orelse return null;
    if (choices != .array or choices.array.items.len == 0) return null;

    const first = choices.array.items[0];
    if (first != .object) return null;

    const delta = first.object.get("delta") orelse return null;
    if (delta != .object) return null;

    const tool_calls = delta.object.get("tool_calls") orelse return null;
    if (tool_calls != .array or tool_calls.array.items.len == 0) return null;

    // Return the first tool_call delta in this chunk
    const tc = tool_calls.array.items[0];
    if (tc != .object) return null;
    const tc_obj = tc.object;

    const index: u32 = if (tc_obj.get("index")) |idx| blk: {
        if (idx == .integer) break :blk @intCast(idx.integer);
        break :blk 0;
    } else 0;

    const id: ?[]const u8 = if (tc_obj.get("id")) |i| blk: {
        if (i == .string and i.string.len > 0) break :blk try allocator.dupe(u8, i.string);
        break :blk null;
    } else null;

    // Extract function.name and function.arguments
    var name: ?[]const u8 = null;
    var arguments: []const u8 = "";
    if (tc_obj.get("function")) |func| {
        if (func == .object) {
            const func_obj = func.object;
            if (func_obj.get("name")) |n| {
                if (n == .string and n.string.len > 0) {
                    name = try allocator.dupe(u8, n.string);
                }
            }
            if (func_obj.get("arguments")) |a| {
                if (a == .string) {
                    arguments = try allocator.dupe(u8, a.string);
                }
            }
        }
    }

    // Only return if we got something useful (id, name, or arguments)
    if (id == null and name == null and arguments.len == 0) return null;

    return .{
        .index = index,
        .id = id,
        .name = name,
        .arguments = arguments,
    };
}

/// Accumulator for streaming tool call deltas.
/// OpenAI sends tool calls as fragments across multiple SSE chunks,
/// keyed by index. This struct collects them into complete ToolCall objects.
pub const ToolCallAccumulator = struct {
    const MaxToolCalls = 16;

    /// Per-tool-call state during accumulation.
    const Slot = struct {
        id: ?[]const u8 = null,
        name: ?[]const u8 = null,
        arguments: std.ArrayListUnmanaged(u8) = .empty,
        has_data: bool = false,
    };

    slots: [MaxToolCalls]Slot = [_]Slot{.{}} ** MaxToolCalls,
    count: u32 = 0,

    pub fn deinit(self: *ToolCallAccumulator, allocator: std.mem.Allocator) void {
        for (&self.slots, 0..) |*slot, i| {
            if (i >= self.count) break;
            if (slot.id) |id| allocator.free(id);
            if (slot.name) |name| allocator.free(name);
            slot.arguments.deinit(allocator);
        }
    }

    /// Feed a tool call delta into the accumulator.
    pub fn feed(self: *ToolCallAccumulator, allocator: std.mem.Allocator, delta: ToolCallDelta) !void {
        if (delta.index >= MaxToolCalls) return;
        const slot = &self.slots[delta.index];
        if (!slot.has_data) {
            slot.has_data = true;
            if (delta.index >= self.count) self.count = delta.index + 1;
        }
        if (delta.id) |id| {
            if (slot.id) |old_id| allocator.free(old_id);
            slot.id = id; // ownership transferred
        }
        if (delta.name) |name| {
            if (slot.name) |old_name| allocator.free(old_name);
            slot.name = name; // ownership transferred
        }
        if (delta.arguments.len > 0) {
            try slot.arguments.appendSlice(allocator, delta.arguments);
            // Note: delta.arguments is owned by caller (parseSseLine), but extractToolCallDelta
            // always allocates a copy, so we don't free it here — caller must free it.
            allocator.free(delta.arguments);
        }
    }

    /// Assemble accumulated deltas into a slice of ToolCall.
    pub fn build(self: *ToolCallAccumulator, allocator: std.mem.Allocator) ![]const root.ToolCall {
        if (self.count == 0) return &.{};

        var list: std.ArrayListUnmanaged(root.ToolCall) = .empty;
        errdefer {
            for (list.items) |tc| {
                allocator.free(tc.id);
                allocator.free(tc.name);
                allocator.free(tc.arguments);
            }
            list.deinit(allocator);
        }

        for (&self.slots, 0..) |*slot, i| {
            if (i >= self.count) break;
            if (!slot.has_data) continue;

            const id = slot.id orelse try allocator.dupe(u8, "unknown");
            const name = slot.name orelse try allocator.dupe(u8, "");
            const args = try slot.arguments.toOwnedSlice(allocator);

            try list.append(allocator, .{
                .id = id,
                .name = name,
                .arguments = args,
            });

            // Prevent double-free in deinit since we transferred ownership
            slot.id = null;
            slot.name = null;
        }

        return try list.toOwnedSlice(allocator);
    }
};

/// Run curl in SSE streaming mode and parse output line by line.
///
/// Uses SSE client to connect to streaming endpoint and parse events incrementally.
/// For each SSE delta, calls `callback(ctx, chunk)`.
/// Returns accumulated result after stream completes.
pub fn curlStream(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    auth_header: ?[]const u8,
    extra_headers: []const []const u8,
    timeout_secs: u64,
    callback: root.StreamCallback,
    ctx: *anyopaque,
) !root.StreamChatResult {
    slog.logStructured("DEBUG", "sse", "curl_stream_start", .{});
    _ = timeout_secs;
    slog.logStructured("DEBUG", "sse", "curl_stream_start", .{});
    const sse = @import("../sse_client.zig");

    // Build headers array
    var header_buf: [32]std.http.Header = undefined;
    var n_headers: usize = 0;

    // Add auth header if provided
    if (auth_header) |hdr| {
        const colon_idx = std.mem.indexOfScalar(u8, hdr, ':') orelse return error.InvalidHeader;
        header_buf[n_headers] = .{
            .name = hdr[0..colon_idx],
            .value = std.mem.trim(u8, hdr[colon_idx + 1 ..], " \t\r\n"),
        };
        n_headers += 1;
    }

    // Add extra headers
    for (extra_headers) |hdr| {
        if (n_headers >= header_buf.len) break;
        const colon_idx = std.mem.indexOfScalar(u8, hdr, ':') orelse continue;
        header_buf[n_headers] = .{
            .name = hdr[0..colon_idx],
            .value = std.mem.trim(u8, hdr[colon_idx + 1 ..], " \t\r\n"),
        };
        n_headers += 1;
    }

    const headers_slice = header_buf[0..n_headers];

    // Create SSE connection and connect
    slog.logStructured("DEBUG", "sse", "creating_connection", .{});
    var conn = try sse.SseConnection.initAndConnect(allocator, url, headers_slice, body);
    slog.logStructured("DEBUG", "sse", "connection_created", .{});
    defer {
        slog.logStructured("DEBUG", "sse", "defer_conn_deinit_start", .{});
        conn.deinit();
        slog.logStructured("DEBUG", "sse", "defer_conn_deinit_complete", .{});
    }

    var accumulated_content = std.ArrayList(u8).initCapacity(allocator, 4096) catch return error.OutOfMemory;
    defer {
        slog.logStructured("DEBUG", "sse", "defer_content_deinit_start", .{});
        accumulated_content.deinit(allocator);
        slog.logStructured("DEBUG", "sse", "defer_content_deinit_complete", .{});
    }
    var total_tokens: u32 = 0;
    var line_count: usize = 0;

    // Accumulator for streaming tool call deltas
    var tc_accum: ToolCallAccumulator = .{};
    defer tc_accum.deinit(allocator);

    // Read and parse SSE events
    slog.logStructured("DEBUG", "sse", "read_loop_start", .{});
    var line_buf: [4096]u8 = undefined;
    while (true) {
        const line_len = conn.readLine(&line_buf) catch |err| switch (err) {
            error.ConnectionClosed => {
                slog.logStructured("DEBUG", "sse", "connection_closed", .{});
                break;
            },
            else => {
                slog.logStructured("WARN", "sse", "read_line_error", .{.err = err});
                return err;
            },
        };
        if (line_len == 0) {
            // Empty line between SSE events - continue reading
            line_count += 1;
            continue;
        }

        const line = line_buf[0..line_len];
        line_count += 1;
        if (line_count <= 10) {}

        const result = try parseSseLine(allocator, line);

        switch (result) {
            .delta => |delta| {
                // Send chunk to callback
                // SAFETY: callback must use delta synchronously and not store the pointer,
                // as delta is freed immediately after this callback returns.
                callback(ctx, root.StreamChunk.textDelta(delta));
                try accumulated_content.appendSlice(allocator, delta);
                total_tokens += @intCast((delta.len + 3) / 4);
                allocator.free(delta);
            },
            .tool_call_delta => |tcd| {
                try tc_accum.feed(allocator, tcd);
            },
            .done => {
                // Send final chunk
                slog.logStructured("DEBUG", "sse", "received_done", .{});
                callback(ctx, root.StreamChunk.finalChunk());
                slog.logStructured("DEBUG", "sse", "final_chunk_sent", .{});
                break;
            },
            .skip => {},
        }
    }

    slog.logStructured("DEBUG", "sse", "loop_exited", .{});
    const owned_content = try accumulated_content.toOwnedSlice(allocator);
    const tool_calls = try tc_accum.build(allocator);
    slog.logStructured("DEBUG", "sse", "building_result", .{ .tokens = total_tokens, .tool_calls = tool_calls.len });
    slog.logStructured("DEBUG", "sse", "returning_result", .{});
    return .{
        .content = owned_content,
        .usage = .{ .total_tokens = total_tokens },
        .model = "",
        .tool_calls = tool_calls,
    };
}
pub fn parseAnthropicSseLine(allocator: std.mem.Allocator, line: []const u8, current_event: []const u8) !AnthropicSseResult {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");

    // Empty lines are skipped
    if (trimmed.len == 0) return .skip;

    // Handle event lines
    const event_prefix = "event: ";
    if (std.mem.startsWith(u8, trimmed, event_prefix)) {
        const event_name = trimmed[event_prefix.len..];
        return .{ .event = event_name };
    }

    // Handle data lines
    const data_prefix = "data: ";
    if (!std.mem.startsWith(u8, trimmed, data_prefix)) return .skip;
    const data = trimmed[data_prefix.len..];

    if (std.mem.eql(u8, current_event, "message_stop")) return .done;

    if (std.mem.eql(u8, current_event, "content_block_delta")) {
        const text = try extractAnthropicDelta(allocator, data) orelse return .skip;
        return .{ .delta = text };
    }

    if (std.mem.eql(u8, current_event, "message_delta")) {
        const tokens = try extractAnthropicUsage(data) orelse return .skip;
        return .{ .usage = tokens };
    }

    return .skip;
}

/// Extract `delta.text` from an Anthropic content_block_delta JSON payload.
/// Returns owned slice or null if not a text_delta.
pub fn extractAnthropicDelta(allocator: std.mem.Allocator, json_str: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.InvalidSseJson;
    defer parsed.deinit();

    const obj = parsed.value.object;
    const delta = obj.get("delta") orelse return null;
    if (delta != .object) return null;

    const dtype = delta.object.get("type") orelse return null;
    if (dtype != .string or !std.mem.eql(u8, dtype.string, "text_delta")) return null;

    const text = delta.object.get("text") orelse return null;
    if (text != .string) return null;
    if (text.string.len == 0) return null;

    return try allocator.dupe(u8, text.string);
}

/// Extract `usage.output_tokens` from an Anthropic message_delta JSON payload.
/// Returns token count or null if not present.
pub fn extractAnthropicUsage(json_str: []const u8) !?u32 {
    // Use a stack buffer for parsing to avoid needing an allocator
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.InvalidSseJson;
    defer parsed.deinit();

    const obj = parsed.value.object;
    const usage = obj.get("usage") orelse return null;
    if (usage != .object) return null;

    const output_tokens = usage.object.get("output_tokens") orelse return null;
    if (output_tokens != .integer) return null;

    return @intCast(output_tokens.integer);
}

/// Run curl in SSE streaming mode for Anthropic and parse output line by line.
///
/// Similar to `curlStream()` but uses stateful Anthropic SSE parsing.
/// `headers` is a slice of pre-formatted header strings (e.g. "x-api-key: sk-...").
pub fn curlStreamAnthropic(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    callback: root.StreamCallback,
    ctx: *anyopaque,
) !root.StreamChatResult {
    _ = allocator;
    _ = url;
    _ = body;
    _ = headers;
    _ = callback;
    _ = ctx;
    return error.NotSupported;
}

test "parseSseLine DONE sentinel" {
    const result = try parseSseLine(std.testing.allocator, "data: [DONE]");
    try std.testing.expect(result == .done);
}

test "parseSseLine empty line" {
    const result = try parseSseLine(std.testing.allocator, "");
    try std.testing.expect(result == .skip);
}

test "parseSseLine comment" {
    const result = try parseSseLine(std.testing.allocator, ":keep-alive");
    try std.testing.expect(result == .skip);
}

test "parseSseLine delta without content" {
    const result = try parseSseLine(std.testing.allocator, "data: {\"choices\":[{\"delta\":{}}]}");
    try std.testing.expect(result == .skip);
}

test "parseSseLine empty choices" {
    const result = try parseSseLine(std.testing.allocator, "data: {\"choices\":[]}");
    try std.testing.expect(result == .skip);
}

test "parseSseLine invalid JSON" {
    try std.testing.expectError(error.InvalidSseJson, parseSseLine(std.testing.allocator, "data: not-json{{{"));
}

test "extractDeltaContent with content" {
    const allocator = std.testing.allocator;
    const result = (try extractDeltaContent(allocator, "{\"choices\":[{\"delta\":{\"content\":\"world\"}}]}")).?;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("world", result);
}

test "extractDeltaContent without content" {
    const result = try extractDeltaContent(std.testing.allocator, "{\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}");
    try std.testing.expect(result == null);
}

test "extractDeltaContent empty content" {
    const result = try extractDeltaContent(std.testing.allocator, "{\"choices\":[{\"delta\":{\"content\":\"\"}}]}");
    try std.testing.expect(result == null);
}

test "StreamChunk textDelta token estimate" {
    const chunk = root.StreamChunk.textDelta("12345678");
    try std.testing.expect(chunk.token_count == 2);
    try std.testing.expect(!chunk.is_final);
    try std.testing.expectEqualStrings("12345678", chunk.delta);
}

test "StreamChunk finalChunk" {
    const chunk = root.StreamChunk.finalChunk();
    try std.testing.expect(chunk.is_final);
    try std.testing.expectEqualStrings("", chunk.delta);
    try std.testing.expect(chunk.token_count == 0);
}

// ── Anthropic SSE Tests ─────────────────────────────────────────

test "parseAnthropicSseLine event line returns event" {
    const result = try parseAnthropicSseLine(std.testing.allocator, "event: content_block_delta", "");
    switch (result) {
        .event => |ev| try std.testing.expectEqualStrings("content_block_delta", ev),
        else => return error.TestUnexpectedResult,
    }
}

test "parseAnthropicSseLine data with content_block_delta returns delta" {
    const allocator = std.testing.allocator;
    const json = "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}";
    const result = try parseAnthropicSseLine(allocator, json, "content_block_delta");
    switch (result) {
        .delta => |text| {
            defer allocator.free(text);
            try std.testing.expectEqualStrings("Hello", text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseAnthropicSseLine data with message_delta returns usage" {
    const json = "data: {\"type\":\"message_delta\",\"delta\":{},\"usage\":{\"output_tokens\":42}}";
    const result = try parseAnthropicSseLine(std.testing.allocator, json, "message_delta");
    switch (result) {
        .usage => |tokens| try std.testing.expect(tokens == 42),
        else => return error.TestUnexpectedResult,
    }
}

test "parseAnthropicSseLine data with message_stop returns done" {
    const result = try parseAnthropicSseLine(std.testing.allocator, "data: {\"type\":\"message_stop\"}", "message_stop");
    try std.testing.expect(result == .done);
}

test "parseAnthropicSseLine empty line returns skip" {
    const result = try parseAnthropicSseLine(std.testing.allocator, "", "");
    try std.testing.expect(result == .skip);
}

test "parseAnthropicSseLine comment returns skip" {
    const result = try parseAnthropicSseLine(std.testing.allocator, ":keep-alive", "");
    try std.testing.expect(result == .skip);
}

test "parseAnthropicSseLine data with unknown event returns skip" {
    const json = "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_123\"}}";
    const result = try parseAnthropicSseLine(std.testing.allocator, json, "message_start");
    try std.testing.expect(result == .skip);
}

test "extractAnthropicDelta correct JSON returns text" {
    const allocator = std.testing.allocator;
    const json = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"world\"}}";
    const result = (try extractAnthropicDelta(allocator, json)).?;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("world", result);
}

test "extractAnthropicDelta without text returns null" {
    const json = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}";
    const result = try extractAnthropicDelta(std.testing.allocator, json);
    try std.testing.expect(result == null);
}

test "extractAnthropicUsage correct JSON returns token count" {
    const json = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":57}}";
    const result = (try extractAnthropicUsage(json)).?;
    try std.testing.expect(result == 57);
}
