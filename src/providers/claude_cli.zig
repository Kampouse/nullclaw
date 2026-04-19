const std = @import("std");
const root = @import("root.zig");

const Provider = root.Provider;
const ChatRequest = root.ChatRequest;
const ChatResponse = root.ChatResponse;
const ChatMessage = root.ChatMessage;

/// Provider that delegates to the `claude` CLI (Claude Code).
///
/// Runs `claude -p <prompt> --output-format stream-json --model <model> --verbose`
/// and parses the stream-json output for a `type: "result"` event.
pub const ClaudeCliProvider = struct {
    allocator: std.mem.Allocator,
    model: []const u8,

    const DEFAULT_MODEL = "claude-opus-4-6";
    const CLI_NAME = "claude";
    const TIMEOUT_NS: u64 = 120 * std.time.ns_per_s;

    pub fn init(allocator: std.mem.Allocator, model: ?[]const u8) !ClaudeCliProvider {
        // Verify CLI is in PATH
        try checkCliAvailable(allocator, CLI_NAME);
        return .{
            .allocator = allocator,
            .model = model orelse DEFAULT_MODEL,
        };
    }

    /// Create a Provider vtable interface.
    pub fn provider(self: *ClaudeCliProvider) Provider {
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
    };

    fn chatWithSystemImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *ClaudeCliProvider = @ptrCast(@alignCast(ptr));
        const effective_model = if (model.len > 0) model else self.model;

        // Combine system prompt with message if provided
        const prompt = if (system_prompt) |sys|
            try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ sys, message })
        else
            try allocator.dupe(u8, message);
        defer allocator.free(prompt);

        return runClaude(allocator, prompt, effective_model);
    }

    fn chatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        _: f64,
    ) anyerror!ChatResponse {
        const self: *ClaudeCliProvider = @ptrCast(@alignCast(ptr));
        const effective_model = if (model.len > 0) model else self.model;

        // Extract last user message as prompt
        const prompt = extractLastUserMessage(request.messages) orelse return error.NoUserMessage;
        const content = try runClaude(allocator, prompt, effective_model);
        return ChatResponse{ .content = content, .model = try allocator.dupe(u8, effective_model) };
    }

    fn supportsNativeToolsImpl(_: *anyopaque) bool {
        return false;
    }

    fn supportsVisionImpl(_: *anyopaque) bool {
        return false;
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "claude-cli";
    }

    fn deinitImpl(_: *anyopaque) void {}

    /// Run the claude CLI and parse stream-json output.
    fn runClaude(allocator: std.mem.Allocator, prompt: []const u8, model: []const u8) ![]const u8 {
        const io = std.Options.debug_io;

        // Build argv: claude -p <prompt> --output-format stream-json --model <model> --verbose
        var argv_list = std.ArrayList([]const u8).empty;
        try argv_list.append(allocator, "claude");
        try argv_list.append(allocator, "-p");
        try argv_list.append(allocator, prompt);
        try argv_list.append(allocator, "--output-format");
        try argv_list.append(allocator, "stream-json");
        try argv_list.append(allocator, "--model");
        try argv_list.append(allocator, model);
        try argv_list.append(allocator, "--verbose");

        var child = try std.process.spawn(io, .{
            .argv = argv_list.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        defer {
            child.kill(io);
            _ = child.wait(io) catch {};
        }

        // Close stdin
        if (child.stdin) |stdin_file| {
            stdin_file.close(io);
            child.stdin = null;
        }

        // Read stdout
        const stdout_file = child.stdout orelse return error.ClaudeExecutionFailed;
        var read_buf: [4096]u8 = undefined;
        var reader = stdout_file.reader(io, &read_buf);
        const output = reader.interface.allocRemaining(allocator, .limited(10 * 1024 * 1024)) catch return error.ClaudeExecutionFailed;
        defer allocator.free(output);

        const term = child.wait(io) catch return error.ClaudeExecutionFailed;
        switch (term) {
            .exited => |code| {
                if (code != 0) return error.ClaudeExecutionFailed;
            },
            else => return error.ClaudeExecutionFailed,
        }

        return try parseStreamJson(allocator, output);
    }

    /// Parse claude stream-json output lines for a result event.
    fn parseStreamJson(allocator: std.mem.Allocator, output: []const u8) ![]const u8 {
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value != .object) continue;
            const obj = parsed.value.object;

            // Look for type: "result"
            if (obj.get("type")) |type_val| {
                if (type_val == .string and std.mem.eql(u8, type_val.string, "result")) {
                    if (obj.get("result")) |result_val| {
                        if (result_val == .string) {
                            return try allocator.dupe(u8, result_val.string);
                        }
                    }
                }
            }
        }
        return error.NoResultInOutput;
    }

    /// Health check: run `claude --version` and verify exit code 0.
    fn healthCheck(allocator: std.mem.Allocator) !void {
        try checkCliVersion(allocator, CLI_NAME);
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Shared helpers
// ════════════════════════════════════════════════════════════════════════════

/// Check if a CLI tool is available in PATH using `which`.
fn checkCliAvailable(allocator: std.mem.Allocator, cli_name: []const u8) !void {
    _ = allocator;
    const io = std.Options.debug_io;

    // Try to run `which <cli_name>` to check if it exists
    var argv = [_][]const u8{ "which", cli_name };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch return error.NotSupported;

    defer {
        child.kill(io);
        _ = child.wait(io) catch {};
    }

    if (child.stdin) |stdin_file| {
        stdin_file.close(io);
        child.stdin = null;
    }

    const term = child.wait(io) catch return error.NotSupported;
    switch (term) {
        .exited => |code| {
            if (code != 0) return error.NotSupported;
        },
        else => return error.NotSupported,
    }
}

/// Run `<cli> --version` and verify exit code 0.
fn checkCliVersion(allocator: std.mem.Allocator, cli_name: []const u8) !void {
    const io = std.Options.debug_io;

    // Run `<cli> --version` to verify it works
    const version_arg = try std.fmt.allocPrint(allocator, "--version", .{});
    defer allocator.free(version_arg);

    var argv = [_][]const u8{ cli_name, version_arg };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch return error.NotSupported;

    defer {
        child.kill(io);
        _ = child.wait(io) catch {};
    }

    if (child.stdin) |stdin_file| {
        stdin_file.close(io);
        child.stdin = null;
    }

    const term = child.wait(io) catch return error.NotSupported;
    switch (term) {
        .exited => |code| {
            if (code != 0) return error.NotSupported;
        },
        else => return error.NotSupported,
    }
}

/// Extract the content of the last user message from a message slice.
fn extractLastUserMessage(messages: []const ChatMessage) ?[]const u8 {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        if (messages[i].role == .user) return messages[i].content;
    }
    return null;
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "ClaudeCliProvider.getNameImpl returns claude-cli" {
    const vtable = ClaudeCliProvider.vtable;
    var dummy: u8 = 0;
    try std.testing.expectEqualStrings("claude-cli", vtable.getName(@ptrCast(&dummy)));
}

test "extractLastUserMessage finds last user" {
    const msgs = [_]ChatMessage{
        ChatMessage.system("Be helpful"),
        ChatMessage.user("first"),
        ChatMessage.assistant("ok"),
        ChatMessage.user("second"),
    };
    const result = extractLastUserMessage(&msgs);
    try std.testing.expectEqualStrings("second", result.?);
}

test "extractLastUserMessage returns null for no user" {
    const msgs = [_]ChatMessage{
        ChatMessage.system("Be helpful"),
        ChatMessage.assistant("ok"),
    };
    try std.testing.expect(extractLastUserMessage(&msgs) == null);
}

test "extractLastUserMessage empty messages" {
    const msgs = [_]ChatMessage{};
    try std.testing.expect(extractLastUserMessage(&msgs) == null);
}

test "parseStreamJson extracts result" {
    const input =
        \\{"type":"start","session_id":"abc123"}
        \\{"type":"content","content":"partial"}
        \\{"type":"result","result":"Hello from Claude CLI!"}
    ;
    const result = try ClaudeCliProvider.parseStreamJson(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello from Claude CLI!", result);
}

test "parseStreamJson no result returns error" {
    const input =
        \\{"type":"start","session_id":"abc123"}
        \\{"type":"content","content":"partial"}
    ;
    const result = ClaudeCliProvider.parseStreamJson(std.testing.allocator, input);
    try std.testing.expectError(error.NoResultInOutput, result);
}

test "parseStreamJson handles empty input" {
    const result = ClaudeCliProvider.parseStreamJson(std.testing.allocator, "");
    try std.testing.expectError(error.NoResultInOutput, result);
}

test "parseStreamJson handles invalid json lines gracefully" {
    const input =
        \\not json at all
        \\{"type":"result","result":"found it"}
    ;
    const result = try ClaudeCliProvider.parseStreamJson(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("found it", result);
}

test "parseStreamJson skips result with non-string value" {
    const input =
        \\{"type":"result","result":42}
    ;
    const result = ClaudeCliProvider.parseStreamJson(std.testing.allocator, input);
    try std.testing.expectError(error.NoResultInOutput, result);
}

test "ClaudeCliProvider vtable has correct function pointers" {
    const vtable = ClaudeCliProvider.vtable;
    var dummy: u8 = 0;
    try std.testing.expectEqualStrings("claude-cli", vtable.getName(@ptrCast(&dummy)));
    try std.testing.expect(!vtable.supportsNativeTools(@ptrCast(&dummy)));
    try std.testing.expect(vtable.supports_vision != null);
    try std.testing.expect(!vtable.supports_vision.?(@ptrCast(&dummy)));
}

test "ClaudeCliProvider.init returns NotSupported for missing binary" {
    const result = checkCliAvailable(std.testing.allocator, "nonexistent_binary_xyzzy_12345");
    try std.testing.expectError(error.NotSupported, result);
}

test "ClaudeCliProvider default model is claude-opus-4-6" {
    try std.testing.expectEqualStrings("claude-opus-4-6", ClaudeCliProvider.DEFAULT_MODEL);
}
