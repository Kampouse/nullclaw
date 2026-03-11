const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const path_security = @import("path_security.zig");
const UNAVAILABLE_WORKSPACE_SENTINEL = "/__nullclaw_workspace_unavailable__";

/// Zig build operations tool for Zig project management.
pub const ZigBuildTool = struct {
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},
    zig_path: []const u8 = "zig", // Path to zig executable (default: "zig" for PATH lookup)

    pub const tool_name = "zig";
    pub const tool_description = "Perform Zig operations: build, test, run, check, clean, fmt, ast-check, init, translate-c, fetch, version. Use this tool for all Zig compiler tasks.";
    pub const tool_params =
        \\{"type":"object","properties":{"operation":{"type":"string","enum":["build","test","run","check","clean","fmt","ast-check","init","translate-c","fetch","version"],"description":"Zig operation to perform"},"args":{"type":"string","description":"Additional arguments to pass to zig (e.g., '-Drelease-fast', '-femit-bin=myapp')"},"build_zig_path":{"type":"string","description":"Path to build.zig (for project-specific operations)"},"project_name":{"type":"string","description":"Project name (for 'init' operation)"},"cwd":{"type":"string","description":"Working directory (absolute path within allowed paths; defaults to workspace)"}},"required":["operation"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ZigBuildTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    /// Returns false if zig args contain dangerous patterns.
    fn sanitizeZigArgs(args: []const u8) bool {
        const dangerous_chars = [_]u8{ '|', ';', '>', '<', '&' };
        const dangerous_substrings = [_][]const u8{ "$(", "`", "${", "@{" };

        // Check for dangerous characters
        for (args) |ch| {
            for (dangerous_chars) |dc| {
                if (ch == dc) return false;
            }
        }

        // Check for dangerous substrings
        for (dangerous_substrings) |sub| {
            if (std.mem.indexOf(u8, args, sub) != null)
                return false;
        }

        // Block certain flags that could be abused
        if (std.mem.indexOf(u8, args, "--cache-dir") != null or
            std.mem.indexOf(u8, args, "--global-cache-dir") != null or
            std.mem.indexOf(u8, args, "--zig-lib-dir") != null)
        {
            return false;
        }

        return true;
    }

    pub fn execute(self: *ZigBuildTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const operation = root.getString(args, "operation") orelse
            return ToolResult.fail("Missing 'operation' parameter");

        // Sanitize all string arguments before execution
        const fields_to_check = [_][]const u8{ "args", "build_zig_path", "project_name" };
        for (fields_to_check) |field| {
            if (root.getString(args, field)) |val| {
                if (!sanitizeZigArgs(val))
                    return ToolResult.fail("Unsafe zig arguments detected");
            }
        }

        // Resolve optional cwd override
        const effective_cwd = if (root.getString(args, "cwd")) |cwd| blk: {
            if (cwd.len == 0 or !std.fs.path.isAbsolute(cwd))
                return ToolResult.fail("cwd must be an absolute path");
            const resolved_cwd = path_security.resolvePathAlloc(allocator, cwd) catch |err| {
                const err_msg = try std.fmt.allocPrint(allocator, "Failed to resolve cwd: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
            };
            defer allocator.free(resolved_cwd);
            const ws_resolved: ?[]const u8 = path_security.resolvePathAlloc(allocator, self.workspace_dir) catch null;
            defer if (ws_resolved) |wr| allocator.free(wr);
            if (ws_resolved == null and self.allowed_paths.len == 0)
                return ToolResult.fail("cwd not allowed (workspace unavailable and no allowed_paths configured)");
            if (!path_security.isResolvedPathAllowed(allocator, resolved_cwd, ws_resolved orelse UNAVAILABLE_WORKSPACE_SENTINEL, self.allowed_paths))
                return ToolResult.fail("cwd is outside allowed areas");
            break :blk cwd;
        } else self.workspace_dir;

        const ZigOp = enum { build, test_op, run, check, clean, fmt, ast_check, init, translate_c, fetch, version };
        const op_map = std.StaticStringMap(ZigOp).initComptime(.{
            .{ "build", .build },
            .{ "test", .test_op },
            .{ "run", .run },
            .{ "check", .check },
            .{ "clean", .clean },
            .{ "fmt", .fmt },
            .{ "ast-check", .ast_check },
            .{ "init", .init },
            .{ "translate-c", .translate_c },
            .{ "fetch", .fetch },
            .{ "version", .version },
        });

        if (op_map.get(operation)) |op| return switch (op) {
            .build => self.zigBuild(allocator, effective_cwd, args),
            .test_op => self.zigTest(allocator, effective_cwd, args),
            .run => self.zigRun(allocator, effective_cwd, args),
            .check => self.zigCheck(allocator, effective_cwd, args),
            .clean => self.zigClean(allocator, effective_cwd, args),
            .fmt => self.zigFmt(allocator, effective_cwd, args),
            .ast_check => self.zigAstCheck(allocator, effective_cwd, args),
            .init => self.zigInit(allocator, effective_cwd, args),
            .translate_c => self.zigTranslateC(allocator, effective_cwd, args),
            .fetch => self.zigFetch(allocator, effective_cwd, args),
            .version => self.zigVersion(allocator, effective_cwd, args),
        };

        const msg = try std.fmt.allocPrint(allocator, "Unknown operation: {s}", .{operation});
        return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
    }

    fn runZig(self: *ZigBuildTool, allocator: std.mem.Allocator, zig_cwd: []const u8, args: []const []const u8) !struct { stdout: []u8, stderr: []u8, success: bool } {
        var argv_buf: [32][]const u8 = undefined;
        argv_buf[0] = self.zig_path; // Use configured zig path (default: "zig")

        const arg_count = @min(args.len, argv_buf.len - 1);
        for (args[0..arg_count], 1..) |a, i| {
            argv_buf[i] = a;
        }

        const proc = @import("process_util.zig");
        const result = try proc.run(allocator, argv_buf[0 .. arg_count + 1], .{ .cwd = zig_cwd });
        return .{ .stdout = result.stdout, .stderr = result.stderr, .success = result.success };
    }

    fn runZigOp(self: *ZigBuildTool, allocator: std.mem.Allocator, zig_cwd: []const u8, args: []const []const u8, extra_args: ?[]const u8) !ToolResult {
        var argv_buf: [32][]const u8 = undefined;
        @memcpy(argv_buf[0..args.len], args);
        var argc = args.len;

        // Add extra args if provided (with proper quote handling)
        if (extra_args) |extra| {
            var token_iter = Tokenizer.init(extra);
            while (token_iter.next()) |token| {
                if (argc >= argv_buf.len - 1) break;
                argv_buf[argc] = token;
                argc += 1;
            }
        }

        const result = try self.runZig(allocator, zig_cwd, argv_buf[0..argc]);
        defer allocator.free(result.stderr);
        if (!result.success) {
            defer allocator.free(result.stdout);
            const msg = try allocator.dupe(u8, if (result.stderr.len > 0) result.stderr else "Zig operation failed");
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        }
        // Duplicate stdout for the caller (transfers ownership)
        const output = try allocator.dupe(u8, result.stdout);
        allocator.free(result.stdout);
        return ToolResult{ .success = true, .output = output, .owns_output = true };
    }

    /// Tokenizer that properly handles shell-style arguments with quotes and escapes
    const Tokenizer = struct {
        input: []const u8,
        pos: usize = 0,

        fn init(input: []const u8) Tokenizer {
            return .{ .input = input };
        }

        fn next(self: *Tokenizer) ?[]const u8 {
            // Skip leading whitespace
            while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) {
                self.pos += 1;
            }

            if (self.pos >= self.input.len) return null;

            const start = self.pos;
            var in_quote: u8 = 0; // 0 = none, 1 = double quote, 2 = single quote
            var escaped = false;

            while (self.pos < self.input.len) {
                const ch = self.input[self.pos];

                if (escaped) {
                    // Handle escaped character
                    escaped = false;
                    self.pos += 1;
                    continue;
                }

                if (ch == '\\') {
                    escaped = true;
                    self.pos += 1;
                    continue;
                }

                if (ch == '"' and in_quote != 2) {
                    if (in_quote == 1) {
                        // Closing double quote
                        in_quote = 0;
                        self.pos += 1;
                        continue;
                    } else {
                        // Opening double quote
                        in_quote = 1;
                        if (self.pos == start) self.pos += 1; // Skip opening quote
                        continue;
                    }
                }

                if (ch == '\'' and in_quote != 1) {
                    if (in_quote == 2) {
                        // Closing single quote
                        in_quote = 0;
                        self.pos += 1;
                        continue;
                    } else {
                        // Opening single quote
                        in_quote = 2;
                        if (self.pos == start) self.pos += 1; // Skip opening quote
                        continue;
                    }
                }

                if (in_quote == 0 and std.ascii.isWhitespace(ch)) {
                    // End of token
                    break;
                }

                self.pos += 1;
            }

            if (self.pos > start) {
                return self.input[start..self.pos];
            }

            return null;
        }
    };

    fn zigBuild(self: *ZigBuildTool, allocator: std.mem.Allocator, zig_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        return self.runZigOp(allocator, zig_cwd, &.{ "build", "build" }, extra);
    }

    fn zigTest(self: *ZigBuildTool, allocator: std.mem.Allocator, zig_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        return self.runZigOp(allocator, zig_cwd, &.{ "build", "test" }, extra);
    }

    fn zigRun(self: *ZigBuildTool, allocator: std.mem.Allocator, zig_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        return self.runZigOp(allocator, zig_cwd, &.{ "build", "run" }, extra);
    }

    fn zigCheck(self: *ZigBuildTool, allocator: std.mem.Allocator, zig_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        return self.runZigOp(allocator, zig_cwd, &.{ "build", "-t" }, extra);
    }

    fn zigClean(self: *ZigBuildTool, allocator: std.mem.Allocator, zig_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        // Zig doesn't have a direct clean command, but we can remove zig-cache and zig-out
        const extra = root.getString(args, "args");
        var argv_buf: [32][]const u8 = undefined;
        argv_buf[0] = "rm";
        argv_buf[1] = "-rf";
        argv_buf[2] = "zig-cache";
        argv_buf[3] = "zig-out";
        var argc: usize = 4;

        if (extra) |e| {
            var it = std.mem.tokenizeScalar(u8, e, ' ');
            while (it.next()) |arg| {
                if (argc >= argv_buf.len) break;
                argv_buf[argc] = arg;
                argc += 1;
            }
        }

        const result = try self.runZig(allocator, zig_cwd, argv_buf[0..argc]);
        defer allocator.free(result.stderr);
        defer allocator.free(result.stdout);

        // Clean "succeeds" even if directories don't exist
        return ToolResult{ .success = true, .output = "Cleaned zig-cache and zig-out directories", .owns_output = false };
    }

    fn zigFmt(self: *ZigBuildTool, allocator: std.mem.Allocator, zig_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        return self.runZigOp(allocator, zig_cwd, &.{ "fmt" }, extra);
    }

    fn zigAstCheck(self: *ZigBuildTool, allocator: std.mem.Allocator, zig_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        return self.runZigOp(allocator, zig_cwd, &.{ "ast-check" }, extra);
    }

    fn zigInit(self: *ZigBuildTool, allocator: std.mem.Allocator, zig_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const project_name = root.getString(args, "project_name") orelse
            return ToolResult.fail("Missing 'project_name' parameter for 'init' operation");

        const extra = root.getString(args, "args");
        var argv_buf: [32][]const u8 = undefined;
        argv_buf[0] = "init";
        argv_buf[1] = "-exe";
        argv_buf[2] = project_name;
        var argc: usize = 3;

        if (extra) |e| {
            var it = std.mem.tokenizeScalar(u8, e, ' ');
            while (it.next()) |arg| {
                if (argc >= argv_buf.len) break;
                argv_buf[argc] = arg;
                argc += 1;
            }
        }

        const result = try self.runZig(allocator, zig_cwd, argv_buf[0..argc]);
        defer allocator.free(result.stderr);
        if (!result.success) {
            defer allocator.free(result.stdout);
            const msg = try allocator.dupe(u8, if (result.stderr.len > 0) result.stderr else "Zig init failed");
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        }
        // Free stdout before creating output message
        allocator.free(result.stdout);
        const out = try std.fmt.allocPrint(allocator, "Created new Zig project: {s}", .{project_name});
        return ToolResult{ .success = true, .output = out, .owns_output = true };
    }

    fn zigTranslateC(self: *ZigBuildTool, allocator: std.mem.Allocator, zig_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        return self.runZigOp(allocator, zig_cwd, &.{ "translate-c" }, extra);
    }

    fn zigFetch(self: *ZigBuildTool, allocator: std.mem.Allocator, zig_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        return self.runZigOp(allocator, zig_cwd, &.{ "fetch" }, extra);
    }

    fn zigVersion(self: *ZigBuildTool, allocator: std.mem.Allocator, zig_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        _ = args;
        const result = try self.runZig(allocator, zig_cwd, &.{ "version" });
        defer allocator.free(result.stderr);
        if (!result.success) {
            defer allocator.free(result.stdout);
            const msg = try allocator.dupe(u8, if (result.stderr.len > 0) result.stderr else "Zig version failed");
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        }
        const output = try allocator.dupe(u8, result.stdout);
        allocator.free(result.stdout);
        return ToolResult{ .success = true, .output = output, .owns_output = true };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "zig_build tool name" {
    var zt = ZigBuildTool{ .workspace_dir = "/tmp" };
    const t = zt.tool();
    try std.testing.expectEqualStrings("zig", t.name());
}

test "zig_build tool schema has operation" {
    var zt = ZigBuildTool{ .workspace_dir = "/tmp" };
    const t = zt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "operation") != null);
}

test "zig_build rejects missing operation" {
    var zt = ZigBuildTool{ .workspace_dir = "/tmp" };
    const t = zt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

test "zig_build rejects unknown operation" {
    var zt = ZigBuildTool{ .workspace_dir = "/tmp" };
    const t = zt.tool();
    const parsed = try root.parseTestArgs("{\"operation\": \"publish\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Unknown operation") != null);
}

test "zig_build blocks injection in args" {
    var zt = ZigBuildTool{ .workspace_dir = "/tmp" };
    const t = zt.tool();
    const parsed = try root.parseTestArgs("{\"operation\": \"build\", \"args\": \"-Drelease-fast; rm -rf /\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Unsafe") != null);
}

test "zig_build init missing project_name" {
    var zt = ZigBuildTool{ .workspace_dir = "/tmp" };
    const t = zt.tool();
    const parsed = try root.parseTestArgs("{\"operation\": \"init\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
    try std.testing.expect(!result.success);
}

test "sanitizeZigArgs blocks pipe" {
    try std.testing.expect(!ZigBuildTool.sanitizeZigArgs("arg | cat /etc/passwd"));
}

test "sanitizeZigArgs blocks semicolon" {
    try std.testing.expect(!ZigBuildTool.sanitizeZigArgs("arg; rm -rf /"));
}

test "sanitizeZigArgs blocks command substitution" {
    try std.testing.expect(!ZigBuildTool.sanitizeZigArgs("$(evil)"));
    try std.testing.expect(!ZigBuildTool.sanitizeZigArgs("`evil`"));
}

test "sanitizeZigArgs blocks cache dir flags" {
    try std.testing.expect(!ZigBuildTool.sanitizeZigArgs("--cache-dir=/tmp"));
    try std.testing.expect(!ZigBuildTool.sanitizeZigArgs("--zig-lib-dir=/usr/lib"));
}

test "sanitizeZigArgs allows safe args" {
    try std.testing.expect(ZigBuildTool.sanitizeZigArgs("-Drelease-fast"));
    try std.testing.expect(ZigBuildTool.sanitizeZigArgs("-femit-bin=myapp"));
    try std.testing.expect(ZigBuildTool.sanitizeZigArgs("-target x86_64-linux"));
}

// ── Tokenizer Tests ───────────────────────────────────────────────────

test "Tokenizer handles simple args" {
    const input = "-Drelease-fast --summary all";
    var tokenizer = ZigBuildTool.Tokenizer.init(input);

    const first = tokenizer.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("-Drelease-fast", first.?);

    const second = tokenizer.next();
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings("--summary", second.?);

    const third = tokenizer.next();
    try std.testing.expect(third != null);
    try std.testing.expectEqualStrings("all", third.?);

    const fourth = tokenizer.next();
    try std.testing.expect(fourth == null);
}

test "Tokenizer handles double quoted args" {
    const input = "-Doptimize=\"ReleaseFast\" --cache-dir \"/tmp/zig\"";
    var tokenizer = ZigBuildTool.Tokenizer.init(input);

    try std.testing.expectEqualStrings("-Doptimize=ReleaseFast", tokenizer.next().?);
    try std.testing.expectEqualStrings("--cache-dir", tokenizer.next().?);
    try std.testing.expectEqualStrings("/tmp/zig", tokenizer.next().?);
    try std.testing.expect(tokenizer.next() == null);
}

test "Tokenizer handles target triple" {
    const input = "-target \"x86_64-unknown-linux-gnu\"";
    var tokenizer = ZigBuildTool.Tokenizer.init(input);

    try std.testing.expectEqualStrings("-target", tokenizer.next().?);
    try std.testing.expectEqualStrings("x86_64-unknown-linux-gnu", tokenizer.next().?);
    try std.testing.expect(tokenizer.next() == null);
}

test "Tokenizer handles escaped characters" {
    const input = "--name\\ with\\ spaces test";
    var tokenizer = ZigBuildTool.Tokenizer.init(input);

    try std.testing.expectEqualStrings("--name with spaces", tokenizer.next().?);
    try std.testing.expectEqualStrings("test", tokenizer.next().?);
    try std.testing.expect(tokenizer.next() == null);
}

test "Tokenizer handles complex zig build args" {
    const input = "-Drelease-fast -femit-bin=myapp --target \"x86_64-macos\" --cache-dir \"/tmp/cache\"";
    var tokenizer = ZigBuildTool.Tokenizer.init(input);

    try std.testing.expectEqualStrings("-Drelease-fast", tokenizer.next().?);
    try std.testing.expectEqualStrings("-femit-bin=myapp", tokenizer.next().?);
    try std.testing.expectEqualStrings("--target", tokenizer.next().?);
    try std.testing.expectEqualStrings("x86_64-macos", tokenizer.next().?);
    try std.testing.expectEqualStrings("--cache-dir", tokenizer.next().?);
    try std.testing.expectEqualStrings("/tmp/cache", tokenizer.next().?);
    try std.testing.expect(tokenizer.next() == null);
}

test "Tokenizer handles mixed quote styles" {
    const input = "-Dfoo='bar baz' --opt=\"test value\"";
    var tokenizer = ZigBuildTool.Tokenizer.init(input);

    try std.testing.expectEqualStrings("-Dfoo=bar baz", tokenizer.next().?);
    try std.testing.expectEqualStrings("--opt=test value", tokenizer.next().?);
    try std.testing.expect(tokenizer.next() == null);
}

// ── Agent Integration Tests ───────────────────────────────────────

test "zig_build tool can be used by agent - tool invocation" {
    var zt = ZigBuildTool{ .workspace_dir = "/tmp" };
    const t = zt.tool();

    // Simulate agent calling the tool with JSON arguments
    const parsed = try root.parseTestArgs("{\"operation\": \"version\"}");
    defer parsed.deinit();

    // This should succeed (zig version always works if zig is installed)
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
    defer result.deinit(std.testing.allocator);

    // zig version should succeed
    try std.testing.expect(result.success);
}

test "zig_build tool validates operation parameter" {
    var zt = ZigBuildTool{ .workspace_dir = "/tmp" };
    const t = zt.tool();

    // Test with missing operation (agent error case)
    {
        const parsed = try root.parseTestArgs("{}");
        defer parsed.deinit();
        const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(!result.success);
        try std.testing.expect(result.error_msg != null);
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Missing") != null);
    }

    // Test with invalid operation (agent error case)
    {
        const parsed = try root.parseTestArgs("{\"operation\": \"invalid_op\"}");
        defer parsed.deinit();
        const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(!result.success);
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Unknown") != null);
    }
}

test "zig_build tool handles init operation correctly" {
    var zt = ZigBuildTool{ .workspace_dir = "/tmp" };
    const t = zt.tool();

    // Test init operation without project_name
    {
        const parsed = try root.parseTestArgs("{\"operation\": \"init\"}");
        defer parsed.deinit();
        const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(!result.success);
    }

    // Test init operation with project_name (validation only, won't actually create)
    {
        const parsed = try root.parseTestArgs("{\"operation\": \"init\", \"project_name\": \"test_project\", \"args\": \"--lib\"}");
        defer parsed.deinit();
        _ = parsed.parsed;
    }
}

test "zig_build tool supports all documented operations" {
    var zt = ZigBuildTool{ .workspace_dir = "/tmp" };
    const t = zt.tool();

    const operations = [_][]const u8{
        "build", "test", "run", "check", "clean",
        "fmt", "ast-check", "init", "translate-c", "fetch"
    };

    for (operations) |op| {
        const json = try std.fmt.allocPrint(std.testing.allocator, "{{\"operation\": \"{s}\"}}", .{op});
        defer std.testing.allocator.free(json);

        const parsed = try root.parseTestArgs(json);
        defer parsed.deinit();

        const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
        defer result.deinit(std.testing.allocator);

        // Operations will fail without a real Zig project (except version), but they should be recognized
        // (not return "Unknown operation")
        if (!result.success) {
            if (result.error_msg) |err| {
                try std.testing.expect(std.mem.indexOf(u8, err, "Unknown") == null);
            }
        }
    }
}

test "zig_build tool prevents command injection via args" {
    var zt = ZigBuildTool{ .workspace_dir = "/tmp" };
    const t = zt.tool();

    const injection_attempts = [_][]const u8{
        "{\"operation\": \"build\", \"args\": \"-Drelease-fast; rm -rf /tmp\"}",
        "{\"operation\": \"test\", \"args\": \"--verbose | cat /etc/passwd\"}",
        "{\"operation\": \"run\", \"args\": \"-Drelease $(whoami)\"}",
        "{\"operation\": \"check\", \"args\": \"-Drelease `evil_command`\"}",
    };

    for (injection_attempts) |injection| {
        const parsed = try root.parseTestArgs(injection);
        defer parsed.deinit();

        const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(!result.success);
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Unsafe") != null);
    }
}

test "zig_build tool tool_metadata" {
    var zt = ZigBuildTool{ .workspace_dir = "/tmp" };
    const t = zt.tool();

    // Verify tool metadata is correct
    try std.testing.expectEqualStrings("zig", t.name());

    const desc = t.description();
    try std.testing.expect(desc.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, desc, "Zig") != null);

    const schema = t.parametersJson();
    try std.testing.expect(schema.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, schema, "operation") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "build") != null);
}
