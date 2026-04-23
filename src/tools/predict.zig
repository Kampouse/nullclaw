//! predict.zig — RLM predict tool for NullClaw.
//!
//! Makes a fresh LLM API call with a DSPy-like signature. Each call gets
//! its own context window — no history from the parent agent loop leaks in.
//!
//! This is the "inner LLM" in the RLM (Recursive Language Model) pattern:
//!   - Outer LLM = the agent loop (iterates, decides what to do)
//!   - Inner LLM = predict() calls (fresh context, perception/extraction)
//!   - Sandbox = vm_exec (code execution, state persists between calls)
//!
//! The agent orchestrates: predict() → vm_exec() → observe → repeat.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const json_util = @import("../json_util.zig");
const http_util = @import("../http_util.zig");
const extractContent = @import("../providers/helpers.zig").extractContent;
const buildRequestBodyWithSystem = @import("../providers/helpers.zig").buildRequestBodyWithSystem;
const providerUrl = @import("../providers/helpers.zig").providerUrl;

const log = std.log.scoped(.predict);

pub const PredictTool = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    provider: []const u8,
    model: []const u8,
    base_url: ?[]const u8 = null,
    temperature: f64 = 0.3,
    max_tokens: u32 = 4096,

    pub const tool_name = "predict";
    pub const tool_description =
        "Run a fresh LLM prediction with a DSPy-like signature. Each call gets its own isolated context window — no history from the parent agent leaks in. Use for perception, extraction, classification, and structured reasoning. The outer agent loop sees the result and decides what to do next.";

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
        _ = io;

        const signature = root.getString(args, "signature") orelse {
            return ToolResult.fail("missing 'signature' parameter");
        };
        const input_val = root.getValue(args, "input") orelse {
            return ToolResult.fail("missing 'input' parameter");
        };
        const instructions = root.getString(args, "instructions") orelse "";

        // Serialize input value back to JSON string
        const input_json = try std.json.Stringify.valueAlloc(allocator, input_val, .{});

        log.info("predict: signature='{s}' ({d} bytes input)", .{ signature, input_json.len });
        const system_prompt = try buildSystemPrompt(allocator, signature, instructions);
        defer allocator.free(system_prompt);

        // Build user message from input JSON
        const user_message = try buildUserMessage(allocator, signature, input_json);
        defer allocator.free(user_message);

        // Resolve API endpoint
        const url = if (self.base_url) |bu| bu else providerUrl(self.provider);

        // Build request body
        const body = try buildRequestBodyWithSystem(
            allocator,
            self.model,
            system_prompt,
            user_message,
            self.temperature,
            self.max_tokens,
        );
        defer allocator.free(body);

        // Make HTTP call
        var auth_buf: [1024]u8 = undefined;
        const auth_val = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.api_key}) catch
            return ToolResult.fail("API key too long");

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
            const msg = try std.fmt.allocPrint(allocator, "HTTP request failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        };

        if (result.status != .ok) {
            const msg = try std.fmt.allocPrint(allocator, "LLM API returned status {d}", .{@intFromEnum(result.status)});
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        }

        const response_body = aw.writer.buffer[0..aw.writer.end];

        // Extract content from response
        const content = extractContent(allocator, response_body) catch |err| {
            log.warn("extractContent failed: {s}, body: {s}", .{ @errorName(err), response_body });
            const msg = try std.fmt.allocPrint(allocator, "Failed to parse LLM response: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        };
        defer allocator.free(content);

        log.info("predict: {d} bytes response", .{content.len});

        return ToolResult.okAlloc(allocator, content);
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
