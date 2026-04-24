//! predict.zig — RLM predict tool for NullClaw.
//!
//! Makes LLM API calls with a DSPy-like signature. Supports two modes:
//!   1. Single-shot (no tools): one API call → returns text content.
//!   2. Inner loop (with tools): multi-turn agent loop with bounded iterations.
//!
//! When tools are configured, predict becomes a mini agent:
//!   - Builds request with tool schemas (OpenAI function calling format)
//!   - Parses tool_calls from response
//!   - Dispatches to matched tools
//!   - Feeds tool results back as multi-turn messages
//!   - Loops up to max_rounds, returns final text content
//!
//! This is the "inner LLM" in the RLM pattern:
//!   - Outer LLM = the agent loop (iterates, decides what to do)
//!   - Inner LLM = predict() calls (fresh context, perception/extraction)
//!   - Sandbox = vm_exec (code execution, state persists between calls)

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolSpec = root.ToolSpec;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const json_util = @import("../json_util.zig");
const http_util = @import("../http_util.zig");
const providers = @import("../providers/root.zig");

const log = std.log.scoped(.predict);

pub const PredictTool = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    provider: []const u8,
    model: []const u8,
    base_url: ?[]const u8 = null,
    temperature: f64 = 0.3,
    max_tokens: u32 = 4096,
    /// Tools available to the inner loop. Empty = single-shot mode.
    inner_tools: []const Tool = &.{},
    /// Max inner loop iterations.
    max_rounds: u32 = 3,

    pub const tool_name = "predict";
    pub const tool_description =
        "Run a fresh LLM prediction with a DSPy-like signature. Each call gets its own isolated context window — no history from the parent agent leaks in. Use for perception, extraction, classification, and structured reasoning. When tools are configured, can execute multi-step tasks autonomously (e.g. write and run code in the VM sandbox).";

    pub const tool_params =
        \\{"type":"object","properties":{
        \\  "signature":{"type":"string","description":"DSPy-like signature defining inputs and outputs. Format: 'input1: type1, input2: type2 -> output1: type1, output2: type2'. Types are informational only (str, int, float, bool, list, dict). Example: 'question: str -> answer: str'"},
        \\  "instructions":{"type":"string","description":"Task instructions telling the model what to do with the inputs"},
        \\  "input":{"type":"object","description":"JSON object with input field values matching the signature's input fields. Example: {\"question\": \"What is 2+2?\"}"}
        \\},"required":["signature","input"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *PredictTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *PredictTool, allocator: std.mem.Allocator, args: JsonObjectMap, io: std.Io) !ToolResult {

        const signature = root.getString(args, "signature") orelse {
            return ToolResult.fail("missing 'signature' parameter");
        };
        const input_val = root.getValue(args, "input") orelse {
            return ToolResult.fail("missing 'input' parameter");
        };
        const instructions = root.getString(args, "instructions") orelse "";

        // Serialize input value back to JSON string
        const input_json = try std.json.Stringify.valueAlloc(allocator, input_val, .{});
        defer allocator.free(input_json);

        log.info("predict: signature='{s}' ({d} bytes input, {d} tools, max_rounds={d})", .{
            signature,
            input_json.len,
            self.inner_tools.len,
            self.max_rounds,
        });

        const system_prompt = try buildSystemPrompt(allocator, signature, instructions);
        defer allocator.free(system_prompt);

        const user_message = try buildUserMessage(allocator, signature, input_json);
        defer allocator.free(user_message);

        // Build tool specs from inner_tools
        var tool_specs: std.ArrayListUnmanaged(ToolSpec) = .empty;
        defer tool_specs.deinit(allocator);
        for (self.inner_tools) |t| {
            try tool_specs.append(allocator, t.spec());
        }
        const specs = tool_specs.items;

        // Single-shot mode (no tools)
        if (specs.len == 0) {
            return self.executeSingleShot(allocator, system_prompt, user_message);
        }

        // Multi-turn inner loop mode
        return self.executeWithTools(allocator, io, system_prompt, user_message, specs);
    }

    /// Single-shot: one API call, return text content.
    fn executeSingleShot(self: *PredictTool, allocator: std.mem.Allocator, system_prompt: []const u8, user_message: []const u8) !ToolResult {
        const body = try providers.buildRequestBodyWithSystem(
            allocator,
            self.model,
            system_prompt,
            user_message,
            self.temperature,
            self.max_tokens,
        );
        defer allocator.free(body);

        const response_body = try self.httpPost(allocator, body);
        defer allocator.free(response_body);

        const content = providers.extractContent(allocator, response_body) catch |err| {
            log.warn("extractContent failed: {s}", .{@errorName(err)});
            const msg = try std.fmt.allocPrint(allocator, "Failed to parse LLM response: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        };

        log.info("predict single-shot: {d} bytes response", .{content.len});
        return ToolResult.okAlloc(allocator, content);
    }

    /// Multi-turn inner loop with tool dispatch.
    fn executeWithTools(
        self: *PredictTool,
        allocator: std.mem.Allocator,
        io: std.Io,
        system_prompt: []const u8,
        user_message: []const u8,
        tool_specs: []const ToolSpec,
    ) !ToolResult {
        // We need a scratch arena for per-iteration allocations.
        // Use the main allocator and carefully free per-iteration.
        var messages: std.ArrayListUnmanaged(Message) = .empty;
        defer {
            for (messages.items) |*msg| {
                msg.deinit(allocator);
            }
            messages.deinit(allocator);
        }

        // System prompt as first message
        try messages.append(allocator, Message{ .role = "system", .content = try allocator.dupe(u8, system_prompt) });
        // User message
        try messages.append(allocator, Message{ .role = "user", .content = try allocator.dupe(u8, user_message) });

        var round: u32 = 0;
        while (round < self.max_rounds) : (round += 1) {
            log.info("predict inner loop round {d}/{d}", .{ round + 1, self.max_rounds });

            // Build request body with messages + tools
            const body = try buildRequestBody(allocator, self.model, messages.items, tool_specs, self.temperature, self.max_tokens);
            defer allocator.free(body);

            const response_body = try self.httpPost(allocator, body);
            defer allocator.free(response_body);

            // Parse response
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to parse LLM response JSON: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
            };
            defer parsed.deinit();

            const resp_obj = if (parsed.value == .object) parsed.value.object else {
                const msg = try std.fmt.allocPrint(allocator, "LLM response is not a JSON object", .{});
                return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
            };

            // Get choices[0].message
            const choices = resp_obj.get("choices") orelse {
                // No choices — maybe content-only response
                if (resp_obj.get("content")) |content| {
                    if (content == .string and content.string.len > 0) {
                        return ToolResult.okAlloc(allocator, content.string);
                    }
                }
                const msg = try std.fmt.allocPrint(allocator, "LLM response missing 'choices' field", .{});
                return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
            };

            const choices_arr = if (choices == .array) choices.array else {
                const msg = try std.fmt.allocPrint(allocator, "LLM response 'choices' is not an array", .{});
                return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
            };

            if (choices_arr.items.len == 0) {
                const msg = try std.fmt.allocPrint(allocator, "LLM response 'choices' is empty", .{});
                return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
            }

            const message_obj = if (choices_arr.items[0] == .object) choices_arr.items[0].object else {
                const msg = try std.fmt.allocPrint(allocator, "LLM response choices[0] is not an object", .{});
                return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
            };

            // Check for tool_calls
            const tool_calls_val = message_obj.get("tool_calls");
            if (tool_calls_val == null or tool_calls_val.? != .array or tool_calls_val.?.array.items.len == 0) {
                // No tool calls — extract text content and return
                // Also check reasoning_content (qwen3, deepseek thinking models)
                const content_val = message_obj.get("content");
                const reasoning_val = message_obj.get("reasoning_content");
                if (content_val != null and content_val.? == .string and content_val.?.string.len > 0) {
                    log.info("predict loop done: {d} rounds, {d} bytes final content", .{ round + 1, content_val.?.string.len });
                    return ToolResult.okAlloc(allocator, content_val.?.string);
                }
                if (reasoning_val != null and reasoning_val.? == .string and reasoning_val.?.string.len > 0) {
                    log.info("predict loop done: {d} rounds, {d} bytes reasoning_content fallback", .{ round + 1, reasoning_val.?.string.len });
                    return ToolResult.okAlloc(allocator, reasoning_val.?.string);
                }
                // Empty content with no tool calls — return what we have
                const msg = try std.fmt.allocPrint(allocator, "LLM returned empty content after {d} rounds", .{round + 1});
                return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
            }

            // Has tool calls — add assistant message and dispatch
            const tool_calls_arr = tool_calls_val.?.array;

            // Add assistant message (with tool_calls) to conversation
            const assistant_content = message_obj.get("content");
            const assistant_text = if (assistant_content != null and assistant_content.? == .string)
                assistant_content.?.string
            else
                "";
            try messages.append(allocator, Message{
                .role = "assistant",
                .content = if (assistant_text.len > 0) try allocator.dupe(u8, assistant_text) else "",
                .tool_calls = try parseToolCallsFromResponse(allocator, tool_calls_arr),
            });

            // Dispatch each tool call
            for (tool_calls_arr.items) |tc_val| {
                if (tc_val != .object) continue;
                const tc_obj = tc_val.object;

                const tc_id = if (tc_obj.get("id")) |v| (if (v == .string) v.string else "unknown") else "unknown";
                const func_obj = if (tc_obj.get("function")) |v| (if (v == .object) v.object else null) else null;
                if (func_obj == null) continue;

                const func_name = if (func_obj.?.get("name")) |v| (if (v == .string) v.string else "") else "";
                const func_args_str = if (func_obj.?.get("arguments")) |v| (if (v == .string) v.string else "{}") else "{}";

                log.info("predict tool call: {s}({d} bytes args)", .{ func_name, func_args_str.len });

                // Find matching tool
                const result = self.dispatchTool(allocator, io, func_name, func_args_str);

                // Add tool result message
                const result_str = if (result.success) result.output else (result.error_msg orelse "unknown error");
                try messages.append(allocator, Message{
                    .role = "tool",
                    .content = try allocator.dupe(u8, result_str),
                    .tool_call_id = try allocator.dupe(u8, tc_id),
                });
            }
        }

        // Exhausted max_rounds — make one final call without tools to get summary
        log.info("predict exhausted {d} rounds, making final summary call", .{self.max_rounds});
        const final_body = try providers.buildRequestBodyWithSystem(
            allocator,
            self.model,
            system_prompt,
            try std.fmt.allocPrint(allocator, "{s}\n\nNote: You have used all your tool calls. Provide your final answer based on what you've learned.", .{user_message}),
            self.temperature,
            self.max_tokens,
        );
        defer allocator.free(final_body);

        const final_response = try self.httpPost(allocator, final_body);
        defer allocator.free(final_response);

        const content = providers.extractContent(allocator, final_response) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to parse final LLM response: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        };

        return ToolResult.okAlloc(allocator, content);
    }

    /// Dispatch a tool call by name to the matching inner tool.
    fn dispatchTool(self: *PredictTool, allocator: std.mem.Allocator, io: std.Io, func_name: []const u8, func_args_str: []const u8) ToolResult {
        for (self.inner_tools) |t| {
            if (std.mem.eql(u8, t.name(), func_name)) {
                // Parse arguments JSON
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, func_args_str, .{}) catch |err| {
                    const msg = std.fmt.allocPrint(allocator, "Failed to parse tool arguments: {s}", .{@errorName(err)}) catch return ToolResult.fail("parse error");
                    return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
                };
                defer parsed.deinit();

                const args_map = if (parsed.value == .object) parsed.value.object else blk: {
                    break :blk std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) catch return ToolResult.fail("failed to create empty args map");
                };

                return t.execute(allocator, args_map, io) catch |err| {
                    const msg = std.fmt.allocPrint(allocator, "Tool '{s}' failed: {s}", .{ func_name, @errorName(err) }) catch return ToolResult.fail("tool error");
                    return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
                };
            }
        }
        const msg = std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{func_name}) catch return ToolResult.fail("unknown tool");
        return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
    }

    /// Make an HTTP POST to the LLM API, return response body.
    fn httpPost(self: *PredictTool, allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
        const url = if (self.base_url) |bu| bu else providers.providerUrl(self.provider);

        var auth_buf: [1024]u8 = undefined;
        const auth_val = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.api_key}) catch
            return error.ApiKeyTooLong;

        const client = http_util.getThreadLocalHttpClient();
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth_val },
                .{ .name = "Content-Type", .value = "application/json" },
            },
            .response_writer = &aw.writer,
        }) catch |err| {
            log.warn("HTTP request failed: {s}", .{@errorName(err)});
            return error.HttpRequestFailed;
        };

        if (result.status != .ok) {
            log.warn("LLM API returned status {d}", .{@intFromEnum(result.status)});
            return error.LlmApiError;
        }

        return try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
    }

    pub fn deinit(_: *PredictTool, _: std.mem.Allocator) void {}

    /// Build system prompt from signature and optional instructions.
    fn buildSystemPrompt(allocator: std.mem.Allocator, signature: []const u8, instructions: []const u8) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator, "You are a precise extraction and reasoning module. You receive structured input and must produce structured output.\n\n");

        if (instructions.len > 0) {
            try buf.appendSlice(allocator, "## Task\n");
            try buf.appendSlice(allocator, instructions);
            try buf.appendSlice(allocator, "\n\n");
        }

        try buf.appendSlice(allocator, "## Signature\n");
        try buf.appendSlice(allocator, signature);
        try buf.appendSlice(allocator, "\n\n");

        try buf.appendSlice(allocator, "## Output format\n");
        try buf.appendSlice(allocator, "Return ONLY valid JSON matching the output fields from the signature. No explanation, no markdown, no code fences. Just the JSON object.\n");

        return try buf.toOwnedSlice(allocator);
    }

    /// Build user message from input JSON, referencing signature field names.
    fn buildUserMessage(allocator: std.mem.Allocator, _: []const u8, input_json: []const u8) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator, "Input data (JSON):\n");
        try buf.appendSlice(allocator, input_json);
        try buf.appendSlice(allocator, "\n\nExtract and produce the output fields from the above data.");

        return try buf.toOwnedSlice(allocator);
    }
};

// ── Message type for multi-turn conversation ──────────────────────────

const Message = struct {
    role: []const u8, // "system", "user", "assistant", "tool"
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    tool_calls: []const ParsedToolCall = &.{},

    fn deinit(self: Message, allocator: std.mem.Allocator) void {
        if (self.content.len > 0) allocator.free(self.content);
        if (self.tool_call_id) |id| allocator.free(id);
        for (self.tool_calls) |*tc| {
            tc.deinit(allocator);
        }
        if (self.tool_calls.len > 0) allocator.free(self.tool_calls);
    }
};

const ParsedToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,

    fn deinit(self: ParsedToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments);
    }
};

/// Parse tool_calls from the OpenAI response format.
fn parseToolCallsFromResponse(allocator: std.mem.Allocator, arr: std.json.Array) ![]const ParsedToolCall {
    var list: std.ArrayListUnmanaged(ParsedToolCall) = .empty;
    errdefer {
        for (list.items) |*tc| tc.deinit(allocator);
        list.deinit(allocator);
    }

    for (arr.items) |tc_val| {
        if (tc_val != .object) continue;
        const tc_obj = tc_val.object;

        const id = if (tc_obj.get("id")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "unknown")) else try allocator.dupe(u8, "unknown");

        const func_obj = if (tc_obj.get("function")) |v| (if (v == .object) v.object else null) else null;
        if (func_obj == null) {
            allocator.free(id);
            continue;
        }

        const name = if (func_obj.?.get("name")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
        const arguments = if (func_obj.?.get("arguments")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "{}")) else try allocator.dupe(u8, "{}");

        try list.append(allocator, .{ .id = id, .name = name, .arguments = arguments });
    }

    return list.toOwnedSlice(allocator);
}

/// Build a multi-turn request body with messages and tools.
fn buildRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
    tool_specs: []const ToolSpec,
    temperature: f64,
    max_tokens: u32,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Opening
    try buf.appendSlice(allocator, "{\"model\":");
    try json_util.appendJsonString(&buf, allocator, model);

    // Messages
    try buf.appendSlice(allocator, ",\"messages\":[");
    for (messages, 0..) |msg, i| {
        if (i > 0) try buf.append(allocator, ',');

        try buf.appendSlice(allocator, "{\"role\":");
        try json_util.appendJsonString(&buf, allocator, msg.role);
        try buf.appendSlice(allocator, ",\"content\":");
        try json_util.appendJsonString(&buf, allocator, msg.content);

        // tool_calls for assistant messages
        if (msg.tool_calls.len > 0) {
            try buf.appendSlice(allocator, ",\"tool_calls\":[");
            for (msg.tool_calls, 0..) |tc, j| {
                if (j > 0) try buf.append(allocator, ',');
                try buf.appendSlice(allocator, "{\"id\":");
                try json_util.appendJsonString(&buf, allocator, tc.id);
                try buf.appendSlice(allocator, ",\"type\":\"function\",\"function\":{\"name\":");
                try json_util.appendJsonString(&buf, allocator, tc.name);
                try buf.appendSlice(allocator, ",\"arguments\":");
                try buf.appendSlice(allocator, tc.arguments); // already JSON string
                try buf.appendSlice(allocator, "}}");
            }
            try buf.append(allocator, ']');
        }

        // tool_call_id for tool messages
        if (msg.tool_call_id) |tcid| {
            try buf.appendSlice(allocator, ",\"tool_call_id\":");
            try json_util.appendJsonString(&buf, allocator, tcid);
        }

        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');

    // Tools
    try buf.appendSlice(allocator, ",\"tools\":[");
    for (tool_specs, 0..) |ts, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"type\":\"function\",\"function\":{\"name\":");
        try json_util.appendJsonString(&buf, allocator, ts.name);
        try buf.appendSlice(allocator, ",\"description\":");
        try json_util.appendJsonString(&buf, allocator, ts.description);
        try buf.appendSlice(allocator, ",\"parameters\":");
        try buf.appendSlice(allocator, ts.parameters_json);
        try buf.appendSlice(allocator, "}}");
    }
    try buf.append(allocator, ']');

    // Temperature + max_tokens
    try buf.appendSlice(allocator, ",\"temperature\":");
    var temp_buf: [32]u8 = undefined;
    const temp_str = std.fmt.bufPrint(&temp_buf, "{d:.1}", .{temperature}) catch unreachable;
    try buf.appendSlice(allocator, temp_str);

    try buf.appendSlice(allocator, ",\"max_tokens\":");
    var tokens_buf: [16]u8 = undefined;
    const tokens_str = std.fmt.bufPrint(&tokens_buf, "{d}", .{max_tokens}) catch unreachable;
    try buf.appendSlice(allocator, tokens_str);

    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}
