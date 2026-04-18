const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const path_security = @import("path_security.zig");
const isResolvedPathAllowed = @import("path_security.zig").isResolvedPathAllowed;
const UNAVAILABLE_WORKSPACE_SENTINEL = "/__nullclaw_workspace_unavailable__";

/// Cargo operations tool for Rust project management.
pub const CargoTool = struct {
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},

    pub const tool_name = "cargo";
    pub const tool_description = "Perform Cargo operations: build, test, run, check, clean, doc, new, init, update, clippy, fmt, add. Use this tool for all Rust/Cargo tasks.";
    pub const tool_params =
        \\{"type":"object","properties":{"operation":{"type":"string","enum":["build","test","run","check","clean","doc","new","init","update","clippy","fmt"],"description":"Cargo operation to perform"},"args":{"type":"string","description":"Additional arguments to pass to cargo (e.g., '--release', '--bin foo')"},"manifest_path":{"type":"string","description":"Path to Cargo.toml (for project-specific operations)"},"package_name":{"type":"string","description":"Package name (for 'new' operation)"},"cwd":{"type":"string","description":"Working directory (absolute path within allowed paths; defaults to workspace)"}},"required":["operation"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *CargoTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    /// Returns false if cargo args contain dangerous patterns.
    fn sanitizeCargoArgs(args: []const u8) bool {
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

        // Block explicit config flags
        if (std.mem.indexOf(u8, args, "--config") != null or
            std.mem.indexOf(u8, args, "-Z") != null)
        {
            return false;
        }

        return true;
    }

    pub fn execute(self: *CargoTool, allocator: std.mem.Allocator, args: JsonObjectMap, io: std.Io) !ToolResult {
        _ = io;
        const operation = root.getString(args, "operation") orelse
            return ToolResult.fail("Missing 'operation' parameter");

        // Sanitize all string arguments before execution
        const fields_to_check = [_][]const u8{ "args", "manifest_path", "package_name" };
        for (fields_to_check) |field| {
            if (root.getString(args, field)) |val| {
                if (!sanitizeCargoArgs(val))
                    return ToolResult.fail("Unsafe cargo arguments detected");
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

        const CargoOp = enum { build, test_op, run, check, clean, doc, new, init, update, clippy, fmt };
        const op_map = std.StaticStringMap(CargoOp).initComptime(.{
            .{ "build", .build },
            .{ "test", .test_op },
            .{ "run", .run },
            .{ "check", .check },
            .{ "clean", .clean },
            .{ "doc", .doc },
            .{ "new", .new },
            .{ "init", .init },
            .{ "update", .update },
            .{ "clippy", .clippy },
            .{ "fmt", .fmt },
        });

        if (op_map.get(operation)) |op| return switch (op) {
            .build => self.cargoBuild(allocator, effective_cwd, args),
            .test_op => self.cargoTest(allocator, effective_cwd, args),
            .run => self.cargoRun(allocator, effective_cwd, args),
            .check => self.cargoCheck(allocator, effective_cwd, args),
            .clean => self.cargoClean(allocator, effective_cwd, args),
            .doc => self.cargoDoc(allocator, effective_cwd, args),
            .new => self.cargoNew(allocator, effective_cwd, args),
            .init => self.cargoInit(allocator, effective_cwd, args),
            .update => self.cargoUpdate(allocator, effective_cwd, args),
            .clippy => self.cargoClippy(allocator, effective_cwd, args),
            .fmt => self.cargoFmt(allocator, effective_cwd, args),
        };

        const msg = try std.fmt.allocPrint(allocator, "Unknown operation: {s}", .{operation});
        return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
    }

    fn runCargo(_: *CargoTool, allocator: std.mem.Allocator, cargo_cwd: []const u8, args: []const []const u8) !struct { stdout: []u8, stderr: []u8, success: bool } {
        var argv_buf: [32][]const u8 = undefined;
        argv_buf[0] = "cargo";
        const arg_count = @min(args.len, argv_buf.len - 1);
        for (args[0..arg_count], 1..) |a, i| {
            argv_buf[i] = a;
        }

        const proc = @import("process_util.zig");
        const result = try proc.run(allocator, argv_buf[0 .. arg_count + 1], .{ .cwd = cargo_cwd });
        return .{ .stdout = result.stdout, .stderr = result.stderr, .success = result.success };
    }

    fn runCargoOp(self: *CargoTool, allocator: std.mem.Allocator, cargo_cwd: []const u8, args: []const []const u8, extra_args: ?[]const u8) !ToolResult {
        var argv_buf: [32][]const u8 = undefined;
        @memcpy(argv_buf[0..args.len], args);
        var argc = args.len;

        // Add extra args if provided (with proper quote handling)
        if (extra_args) |extra| {
            var token_iter = Tokenizer.init(extra);
            while (token_iter.next(allocator) catch null) |token| {
                if (argc >= argv_buf.len - 1) break;
                argv_buf[argc] = token;
                argc += 1;
            }
        }

        const result = self.runCargo(allocator, cargo_cwd, argv_buf[0..argc]) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to run cargo: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        };
        defer allocator.free(result.stderr);
        if (!result.success) {
            defer allocator.free(result.stdout);
            const msg = try allocator.dupe(u8, if (result.stderr.len > 0) result.stderr else "Cargo operation failed");
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

        fn next(self: *Tokenizer, allocator: std.mem.Allocator) !?[]u8 {
            // Skip leading whitespace
            while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) {
                self.pos += 1;
            }

            if (self.pos >= self.input.len) return null;

            var in_quote: u8 = 0; // 0 = none, 1 = double quote, 2 = single quote
            var escaped = false;

            var result: std.ArrayListUnmanaged(u8) = .empty;
            defer result.deinit(allocator);

            while (self.pos < self.input.len) {
                const ch = self.input[self.pos];

                if (escaped) {
                    // Append the character after the backslash
                    try result.append(allocator, ch);
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
                    } else {
                        // Opening double quote
                        in_quote = 1;
                    }
                    self.pos += 1;
                    continue;
                }

                if (ch == '\'' and in_quote != 1) {
                    if (in_quote == 2) {
                        // Closing single quote
                        in_quote = 0;
                    } else {
                        // Opening single quote
                        in_quote = 2;
                    }
                    self.pos += 1;
                    continue;
                }

                if (in_quote == 0 and std.ascii.isWhitespace(ch)) {
                    // End of token
                    break;
                }

                try result.append(allocator, ch);
                self.pos += 1;
            }

            if (result.items.len > 0) {
                return try result.toOwnedSlice(allocator);
            }

            return null;
        }
    };

    fn cargoBuild(self: *CargoTool, allocator: std.mem.Allocator, cargo_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        return self.runCargoOp(allocator, cargo_cwd, &.{"build"}, extra);
    }

    fn cargoTest(self: *CargoTool, allocator: std.mem.Allocator, cargo_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        return self.runCargoOp(allocator, cargo_cwd, &.{"test"}, extra);
    }

    fn cargoRun(self: *CargoTool, allocator: std.mem.Allocator, cargo_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        return self.runCargoOp(allocator, cargo_cwd, &.{"run"}, extra);
    }

    fn cargoCheck(self: *CargoTool, allocator: std.mem.Allocator, cargo_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        return self.runCargoOp(allocator, cargo_cwd, &.{"check"}, extra);
    }

    fn cargoClean(self: *CargoTool, allocator: std.mem.Allocator, cargo_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        return self.runCargoOp(allocator, cargo_cwd, &.{"clean"}, extra);
    }

    fn cargoDoc(self: *CargoTool, allocator: std.mem.Allocator, cargo_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        return self.runCargoOp(allocator, cargo_cwd, &.{"doc"}, extra);
    }

    fn cargoNew(self: *CargoTool, allocator: std.mem.Allocator, cargo_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const package_name = root.getString(args, "package_name") orelse
            return ToolResult.fail("Missing 'package_name' parameter for 'new' operation");

        const extra = root.getString(args, "args");
        var argv_buf: [32][]const u8 = undefined;
        argv_buf[0] = "new";
        argv_buf[1] = package_name;
        var argc: usize = 2;

        if (extra) |e| {
            var it = std.mem.tokenizeScalar(u8, e, ' ');
            while (it.next()) |arg| {
                if (argc >= argv_buf.len) break;
                argv_buf[argc] = arg;
                argc += 1;
            }
        }

        const result = self.runCargo(allocator, cargo_cwd, argv_buf[0..argc]) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to run cargo new: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        };
        defer allocator.free(result.stderr);
        if (!result.success) {
            defer allocator.free(result.stdout);
            const msg = try allocator.dupe(u8, if (result.stderr.len > 0) result.stderr else "Cargo new failed");
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        }
        // Free stdout before creating output message
        allocator.free(result.stdout);
        const out = try std.fmt.allocPrint(allocator, "Created new Rust project: {s}", .{package_name});
        return ToolResult{ .success = true, .output = out, .owns_output = true };
    }

    fn cargoInit(self: *CargoTool, allocator: std.mem.Allocator, cargo_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        return self.runCargoOp(allocator, cargo_cwd, &.{"init"}, extra);
    }

    fn cargoUpdate(self: *CargoTool, allocator: std.mem.Allocator, cargo_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        return self.runCargoOp(allocator, cargo_cwd, &.{"update"}, extra);
    }

    fn cargoClippy(self: *CargoTool, allocator: std.mem.Allocator, cargo_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        return self.runCargoOp(allocator, cargo_cwd, &.{"clippy"}, extra);
    }

    fn cargoFmt(self: *CargoTool, allocator: std.mem.Allocator, cargo_cwd: []const u8, args: JsonObjectMap) !ToolResult {
        const extra = root.getString(args, "args");
        // Support both --check and regular fmt
        return self.runCargoOp(allocator, cargo_cwd, &.{"fmt"}, extra);
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "cargo tool name" {
    var ct = CargoTool{ .workspace_dir = "/tmp" };
    const t = ct.tool();
    try std.testing.expectEqualStrings("cargo", t.name());
}

test "cargo tool schema has operation" {
    var ct = CargoTool{ .workspace_dir = "/tmp" };
    const t = ct.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "operation") != null);
}

test "cargo rejects missing operation" {
    var ct = CargoTool{ .workspace_dir = "/tmp" };
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

test "cargo rejects unknown operation" {
    var ct = CargoTool{ .workspace_dir = "/tmp" };
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"operation\": \"publish\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Unknown operation") != null);
}

test "cargo blocks injection in args" {
    var ct = CargoTool{ .workspace_dir = "/tmp" };
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"operation\": \"build\", \"args\": \"--release; rm -rf /\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Unsafe") != null);
}

test "cargo new missing package_name" {
    var ct = CargoTool{ .workspace_dir = "/tmp" };
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"operation\": \"new\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
    try std.testing.expect(!result.success);
}

test "sanitizeCargoArgs blocks pipe" {
    try std.testing.expect(!CargoTool.sanitizeCargoArgs("arg | cat /etc/passwd"));
}

test "sanitizeCargoArgs blocks semicolon" {
    try std.testing.expect(!CargoTool.sanitizeCargoArgs("arg; rm -rf /"));
}

test "sanitizeCargoArgs blocks command substitution" {
    try std.testing.expect(!CargoTool.sanitizeCargoArgs("$(evil)"));
    try std.testing.expect(!CargoTool.sanitizeCargoArgs("`evil`"));
}

test "sanitizeCargoArgs blocks --config flag" {
    try std.testing.expect(!CargoTool.sanitizeCargoArgs("--config=key=value"));
}

test "sanitizeCargoArgs blocks -Z flag" {
    try std.testing.expect(!CargoTool.sanitizeCargoArgs("-Z unstable-options"));
}

test "sanitizeCargoArgs allows safe args" {
    try std.testing.expect(CargoTool.sanitizeCargoArgs("--release"));
    try std.testing.expect(CargoTool.sanitizeCargoArgs("--bin foo"));
    try std.testing.expect(CargoTool.sanitizeCargoArgs("--features bar"));
}

// ── Tokenizer Tests ───────────────────────────────────────────────────

test "Tokenizer handles simple args" {
    const input = "--release --bins";
    var tokenizer = CargoTool.Tokenizer.init(input);

    const first = try tokenizer.next(std.testing.allocator);
    defer std.testing.allocator.free(first.?);
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("--release", first.?);

    const second = try tokenizer.next(std.testing.allocator);
    defer std.testing.allocator.free(second.?);
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings("--bins", second.?);

    const third = try tokenizer.next(std.testing.allocator);
    try std.testing.expect(third == null);
}

test "Tokenizer handles double quoted args" {
    const input = "--features \"default feature\"";
    var tokenizer = CargoTool.Tokenizer.init(input);

    const first = try tokenizer.next(std.testing.allocator);
    defer std.testing.allocator.free(first.?);
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("--features", first.?);

    const second = try tokenizer.next(std.testing.allocator);
    defer std.testing.allocator.free(second.?);
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings("default feature", second.?);

    const third = try tokenizer.next(std.testing.allocator);
    try std.testing.expect(third == null);
}

test "Tokenizer handles single quoted args" {
    const input = "--target 'x86_64-unknown-linux-gnu'";
    var tokenizer = CargoTool.Tokenizer.init(input);

    const first = try tokenizer.next(std.testing.allocator);
    defer std.testing.allocator.free(first.?);
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("--target", first.?);

    const second = try tokenizer.next(std.testing.allocator);
    defer std.testing.allocator.free(second.?);
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings("x86_64-unknown-linux-gnu", second.?);

    const third = try tokenizer.next(std.testing.allocator);
    try std.testing.expect(third == null);
}

test "Tokenizer handles escaped spaces" {
    const input = "--bin\\ name test";
    var tokenizer = CargoTool.Tokenizer.init(input);

    const first = try tokenizer.next(std.testing.allocator);
    defer std.testing.allocator.free(first.?);
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("--bin name", first.?);

    const second = try tokenizer.next(std.testing.allocator);
    defer std.testing.allocator.free(second.?);
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings("test", second.?);

    const third = try tokenizer.next(std.testing.allocator);
    try std.testing.expect(third == null);
}

test "Tokenizer handles mixed quotes and spaces" {
    const input = "--release --features \"feat1 feat2\" --bin myapp";
    var tokenizer = CargoTool.Tokenizer.init(input);

    const t1 = try tokenizer.next(std.testing.allocator); defer std.testing.allocator.free(t1.?);
    try std.testing.expectEqualStrings("--release", t1.?);
    const t2 = try tokenizer.next(std.testing.allocator); defer std.testing.allocator.free(t2.?);
    try std.testing.expectEqualStrings("--features", t2.?);
    const t3 = try tokenizer.next(std.testing.allocator); defer std.testing.allocator.free(t3.?);
    try std.testing.expectEqualStrings("feat1 feat2", t3.?);
    const t4 = try tokenizer.next(std.testing.allocator); defer std.testing.allocator.free(t4.?);
    try std.testing.expectEqualStrings("--bin", t4.?);
    const t5 = try tokenizer.next(std.testing.allocator); defer std.testing.allocator.free(t5.?);
    try std.testing.expectEqualStrings("myapp", t5.?);
    try std.testing.expect((try tokenizer.next(std.testing.allocator)) == null);
}

test "Tokenizer handles equals flags" {
    const input = "-Doptimize=ReleaseFast --target=x86_64-linux";
    var tokenizer = CargoTool.Tokenizer.init(input);

    const t1 = try tokenizer.next(std.testing.allocator); defer std.testing.allocator.free(t1.?);
    try std.testing.expectEqualStrings("-Doptimize=ReleaseFast", t1.?);
    const t2 = try tokenizer.next(std.testing.allocator); defer std.testing.allocator.free(t2.?);
    try std.testing.expectEqualStrings("--target=x86_64-linux", t2.?);
    try std.testing.expect((try tokenizer.next(std.testing.allocator)) == null);
}

test "Tokenizer handles complex real-world cargo args" {
    const input = "--release --features \"tokio rustls\" --target \"x86_64-unknown-linux-musl\" --no-default-features";
    var tokenizer = CargoTool.Tokenizer.init(input);

    const t1 = try tokenizer.next(std.testing.allocator); defer std.testing.allocator.free(t1.?);
    try std.testing.expectEqualStrings("--release", t1.?);
    const t2 = try tokenizer.next(std.testing.allocator); defer std.testing.allocator.free(t2.?);
    try std.testing.expectEqualStrings("--features", t2.?);
    const t3 = try tokenizer.next(std.testing.allocator); defer std.testing.allocator.free(t3.?);
    try std.testing.expectEqualStrings("tokio rustls", t3.?);
    const t4 = try tokenizer.next(std.testing.allocator); defer std.testing.allocator.free(t4.?);
    try std.testing.expectEqualStrings("--target", t4.?);
    const t5 = try tokenizer.next(std.testing.allocator); defer std.testing.allocator.free(t5.?);
    try std.testing.expectEqualStrings("x86_64-unknown-linux-musl", t5.?);
    const t6 = try tokenizer.next(std.testing.allocator); defer std.testing.allocator.free(t6.?);
    try std.testing.expectEqualStrings("--no-default-features", t6.?);
    try std.testing.expect((try tokenizer.next(std.testing.allocator)) == null);
}

// ── Agent Integration Tests ───────────────────────────────────────

test "cargo tool can be used by agent - tool invocation" {
    var ct = CargoTool{ .workspace_dir = "/tmp" };
    const t = ct.tool();

    // Simulate agent calling the tool with JSON arguments
    const parsed = try root.parseTestArgs("{\"operation\": \"version\"}");
    defer parsed.deinit();

    // This will fail because "version" isn't a valid cargo operation,
    // but it validates that the tool can be invoked by the agent
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
    defer result.deinit(std.testing.allocator);

    // Should fail gracefully with "Unknown operation" not a crash
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

test "cargo tool validates operation parameter" {
    var ct = CargoTool{ .workspace_dir = "/tmp" };
    const t = ct.tool();

    // Test with missing operation (agent error case)
    {
        const parsed = try root.parseTestArgs("{}");
        defer parsed.deinit();
        const result = try t.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(!result.success);
        try std.testing.expect(result.error_msg != null);
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Missing") != null);
    }

    // Test with invalid operation (agent error case)
    {
        const parsed = try root.parseTestArgs("{\"operation\": \"invalid_op\"}");
        defer parsed.deinit();
        const result = try t.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(!result.success);
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Unknown") != null);
    }
}

test "cargo tool handles new operation correctly" {
    var ct = CargoTool{ .workspace_dir = "/tmp" };
    const t = ct.tool();

    // Test new operation without package_name
    {
        const parsed = try root.parseTestArgs("{\"operation\": \"new\"}");
        defer parsed.deinit();
        const result = try t.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(!result.success);
    }

    // Test new operation with package_name (validation only, won't actually create)
    {
        const parsed = try root.parseTestArgs("{\"operation\": \"new\", \"package_name\": \"test_project\", \"args\": \"--lib\"}");
        defer parsed.deinit();
        // We can't actually test this without creating files, but we can validate the parameters parse correctly
        _ = parsed.parsed;
    }
}

test "cargo tool supports all documented operations" {
    var ct = CargoTool{ .workspace_dir = "/tmp" };
    const t = ct.tool();

    const operations = [_][]const u8{
        "build", "test", "run", "check", "clean",
        "doc", "init", "update", "clippy", "fmt"
    };

    for (operations) |op| {
        const json = try std.fmt.allocPrint(std.testing.allocator, "{{\"operation\": \"{s}\"}}", .{op});
        defer std.testing.allocator.free(json);

        const parsed = try root.parseTestArgs(json);
        defer parsed.deinit();

        const result = try t.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
        defer result.deinit(std.testing.allocator);

        // Operations will fail without a real Rust project, but they should be recognized
        // (not return "Unknown operation")
        if (!result.success) {
            if (result.error_msg) |err| {
                try std.testing.expect(std.mem.indexOf(u8, err, "Unknown") == null);
            }
        }
    }
}

test "cargo tool prevents command injection via args" {
    var ct = CargoTool{ .workspace_dir = "/tmp" };
    const t = ct.tool();

    const injection_attempts = [_][]const u8{
        "{\"operation\": \"build\", \"args\": \"--release; rm -rf /tmp\"}",
        "{\"operation\": \"test\", \"args\": \"--verbose | cat /etc/passwd\"}",
        "{\"operation\": \"run\", \"args\": \"--release $(whoami)\"}",
        "{\"operation\": \"check\", \"args\": \"--release `evil_command`\"}",
    };

    for (injection_attempts) |injection| {
        const parsed = try root.parseTestArgs(injection);
        defer parsed.deinit();

        const result = try t.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(!result.success);
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Unsafe") != null);
    }
}

test "cargo tool tool_metadata" {
    var ct = CargoTool{ .workspace_dir = "/tmp" };
    const t = ct.tool();

    // Verify tool metadata is correct
    try std.testing.expectEqualStrings("cargo", t.name());

    const desc = t.description();
    try std.testing.expect(desc.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, desc, "Cargo") != null);

    const schema = t.parametersJson();
    try std.testing.expect(schema.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, schema, "operation") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "build") != null);
}
