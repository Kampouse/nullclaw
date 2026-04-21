const std = @import("std");
const platform = @import("../platform.zig");
const root = @import("root.zig");
const slog = @import("../structured_log.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const path_security = @import("path_security.zig");
const isResolvedPathAllowed = path_security.isResolvedPathAllowed;
const resolvePathAlloc = path_security.resolvePathAlloc;
const SecurityPolicy = @import("../security/policy.zig").SecurityPolicy;
const Spinlock = @import("../spinlock.zig").Spinlock;
const util = @import("../util.zig");
const UNAVAILABLE_WORKSPACE_SENTINEL = "/__nullclaw_workspace_unavailable__";

const log = std.log.scoped(.shell_subprocess);

/// Default maximum shell command execution time (nanoseconds).
const DEFAULT_SHELL_TIMEOUT_NS: u64 = 60 * std.time.ns_per_s;
/// Default maximum output size in bytes (1MB).
const DEFAULT_MAX_OUTPUT_BYTES: usize = 1_048_576;
/// Environment variables safe to pass to shell commands.
const SAFE_ENV_VARS = [_][]const u8{
    "PATH", "HOME", "TERM", "LANG", "LC_ALL", "LC_CTYPE", "USER", "SHELL", "TMPDIR",
};

/// Subprocess request - command to execute (heap-allocated, lives until executor processes it)
const SubprocessRequest = struct {
    command: []const u8, // page_allocator-owned, freed by executor
    cwd: []const u8,     // page_allocator-owned, freed by executor
};

/// Subprocess result - output from command execution (heap-allocated, freed by caller)
const SubprocessResult = struct {
    success: bool,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: ?u8,
};

/// Dedicated subprocess thread - executes shell commands safely.
/// Uses a single-slot synchronous relay pattern: one request at a time,
/// no queue, no stack-pointer sharing, proper cancellation on timeout.
const SubprocessExecutor = struct {
    thread: ?std.Thread,
    running: std.atomic.Value(bool),

    // Single request slot (written by caller, consumed by executor thread)
    pending_request: ?*SubprocessRequest,
    pending_lock: Spinlock,
    request_available: std.atomic.Value(bool),

    // Single result slot (written by executor thread, consumed by caller)
    pending_result: ?*SubprocessResult,
    result_available: std.atomic.Value(bool),

    // Cancellation flag - set by caller on timeout, checked by executor
    cancelled: std.atomic.Value(bool),

    fn run(executor: *SubprocessExecutor) void {
        log.info("Subprocess executor thread started", .{});

        while (executor.running.load(.acquire)) {
            // Wait for a request
            if (!executor.request_available.load(.acquire)) {
                util.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            // Grab the request
            executor.pending_lock.lock();
            const req = executor.pending_request.?;
            executor.pending_request = null;
            executor.pending_lock.unlock();
            executor.request_available.store(false, .release);

            // Reset cancellation for this request
            executor.cancelled.store(false, .release);

            // Execute the command
            const proc = @import("process_util.zig");
            const result = proc.run(std.heap.page_allocator, &.{
                platform.getShell(), platform.getShellFlag(), req.command,
            }, .{
                .cwd = req.cwd,
                .max_output_bytes = DEFAULT_MAX_OUTPUT_BYTES,
            }) catch |err| {
                log.err("Subprocess execution failed: {}", .{err});

                // Build an error result
                const err_result = std.heap.page_allocator.create(SubprocessResult) catch {
                    log.err("Failed to allocate error result", .{});
                    std.heap.page_allocator.free(req.command);
                    std.heap.page_allocator.free(req.cwd);
                    std.heap.page_allocator.destroy(req);
                    continue;
                };
                err_result.* = .{
                    .success = false,
                    .stdout = "",
                    .stderr = "Execution failed",
                    .exit_code = null,
                };

                // Check cancellation before delivering
                if (executor.cancelled.load(.acquire)) {
                    // Caller timed out - clean up everything ourselves
                    std.heap.page_allocator.destroy(err_result);
                    std.heap.page_allocator.free(req.command);
                    std.heap.page_allocator.free(req.cwd);
                    std.heap.page_allocator.destroy(req);
                    continue;
                }

                executor.pending_result = err_result;
                executor.result_available.store(true, .release);
                std.heap.page_allocator.free(req.command);
                std.heap.page_allocator.free(req.cwd);
                std.heap.page_allocator.destroy(req);
                continue;
            };

            // Build the success/failure result
            const result_ptr = std.heap.page_allocator.create(SubprocessResult) catch {
                log.err("Failed to allocate subprocess result", .{});
                result.deinit(std.heap.page_allocator);
                std.heap.page_allocator.free(req.command);
                std.heap.page_allocator.free(req.cwd);
                std.heap.page_allocator.destroy(req);
                continue;
            };
            result_ptr.* = .{
                .success = result.success,
                .stdout = if (result.stdout.len > 0)
                    std.heap.page_allocator.dupe(u8, result.stdout) catch ""
                else
                    "",
                .stderr = if (result.stderr.len > 0)
                    std.heap.page_allocator.dupe(u8, result.stderr) catch ""
                else
                    "",
                .exit_code = if (result.exit_code) |code| @as(u8, @intCast(code)) else null,
            };
            result.deinit(std.heap.page_allocator);

            // Check cancellation before delivering
            if (executor.cancelled.load(.acquire)) {
                // Caller timed out - clean up everything ourselves
                if (result_ptr.stdout.len > 0) std.heap.page_allocator.free(result_ptr.stdout);
                if (result_ptr.stderr.len > 0) std.heap.page_allocator.free(result_ptr.stderr);
                std.heap.page_allocator.destroy(result_ptr);
                std.heap.page_allocator.free(req.command);
                std.heap.page_allocator.free(req.cwd);
                std.heap.page_allocator.destroy(req);
                continue;
            }

            // Deliver result
            executor.pending_result = result_ptr;
            executor.result_available.store(true, .release);

            // Free request resources (no longer needed)
            std.heap.page_allocator.free(req.command);
            std.heap.page_allocator.free(req.cwd);
            std.heap.page_allocator.destroy(req);
        }
    }

    pub fn init(allocator: std.mem.Allocator) !*SubprocessExecutor {
        const executor = try allocator.create(SubprocessExecutor);
        errdefer allocator.destroy(executor);

        executor.* = .{
            .thread = null,
            .running = std.atomic.Value(bool).init(true),
            .pending_request = null,
            .pending_lock = Spinlock.init(),
            .request_available = std.atomic.Value(bool).init(false),
            .pending_result = null,
            .result_available = std.atomic.Value(bool).init(false),
            .cancelled = std.atomic.Value(bool).init(false),
        };

        executor.thread = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, run, .{executor});
        log.info("Subprocess executor thread spawned", .{});

        return executor;
    }

    pub fn deinit(self: *SubprocessExecutor, allocator: std.mem.Allocator) void {
        self.running.store(false, .release);

        if (self.thread) |t| {
            t.join();
        }

        allocator.destroy(self);
        log.info("Subprocess executor thread stopped", .{});
    }

    /// Submit a command and block until the result is ready (or timeout).
    /// Returns a heap-allocated SubprocessResult — caller MUST free it with freeResult().
    pub fn execute(self: *SubprocessExecutor, command: []const u8, cwd: []const u8) !*SubprocessResult {
        // Allocate request on heap (lives until executor processes it)
        const req = try std.heap.page_allocator.create(SubprocessRequest);
        errdefer std.heap.page_allocator.destroy(req);
        req.* = .{
            .command = try std.heap.page_allocator.dupe(u8, command),
            .cwd = try std.heap.page_allocator.dupe(u8, cwd),
        };
        errdefer {
            std.heap.page_allocator.free(req.command);
            std.heap.page_allocator.free(req.cwd);
        }

        // Reset state
        self.cancelled.store(false, .release);
        self.result_available.store(false, .release);

        // Submit request
        self.pending_lock.lock();
        self.pending_request = req;
        self.pending_lock.unlock();
        self.request_available.store(true, .release);

        // Wait for result with timeout (60s at 10ms intervals = 6000 iterations)
        const timeout_iterations = 6000;
        var iteration: usize = 0;

        while (!self.result_available.load(.acquire)) {
            if (iteration >= timeout_iterations) {
                // Timeout - tell executor to clean up the request and result
                self.cancelled.store(true, .release);
                return error.Timeout;
            }
            util.sleep(10 * std.time.ns_per_ms);
            iteration += 1;
        }

        // Grab result
        self.result_available.store(false, .release);
        const result = self.pending_result.?;
        self.pending_result = null;

        return result;
    }

    /// Free a result previously returned by execute().
    pub fn freeResult(result: *SubprocessResult) void {
        if (result.stdout.len > 0) std.heap.page_allocator.free(result.stdout);
        if (result.stderr.len > 0) std.heap.page_allocator.free(result.stderr);
        std.heap.page_allocator.destroy(result);
    }
};

/// Global subprocess executor (initialized lazily)
var subprocess_executor: ?*SubprocessExecutor = null;
var subprocess_executor_spinlock: Spinlock = .init();

/// Get or create the global subprocess executor.
/// Uses page_allocator since the executor is a process-lifetime singleton.
fn getSubprocessExecutor() !*SubprocessExecutor {
    subprocess_executor_spinlock.lock();
    defer subprocess_executor_spinlock.unlock();

    if (subprocess_executor == null) {
        subprocess_executor = try SubprocessExecutor.init(std.heap.page_allocator);
    }

    return subprocess_executor.?;
}

/// Shell command execution tool with workspace scoping.
pub const ShellTool = struct {
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},
    timeout_ns: u64 = DEFAULT_SHELL_TIMEOUT_NS,
    max_output_bytes: usize = DEFAULT_MAX_OUTPUT_BYTES,
    policy: ?*const SecurityPolicy = null,

    pub const tool_name = "shell";
    pub const tool_description = "Execute a shell command in the workspace directory";
    pub const tool_params =
        \\{"type":"object","properties":{"command":{"type":"string","description":"The shell command to execute"},"cwd":{"type":"string","description":"Working directory (absolute path within allowed paths; defaults to workspace)"}},"required":["command"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ShellTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *ShellTool, allocator: std.mem.Allocator, args: JsonObjectMap, io: std.Io) !ToolResult {
        _ = io;
        slog.logStructured("DEBUG", "shell", "execute_start", .{});

        // Parse the command from the pre-parsed JSON object
        const command = root.getString(args, "command") orelse {
            slog.logStructured("WARN", "shell", "missing_command", .{});
            return ToolResult.fail("Missing 'command' parameter");
        };
        slog.logStructured("DEBUG", "shell", "executing_command", .{.command = command});

        // Validate command against security policy
        if (self.policy) |pol| {
            _ = pol.validateCommandExecution(command, false) catch |err| {
                return switch (err) {
                    error.CommandNotAllowed => ToolResult.fail("Command not allowed by security policy"),
                    error.HighRiskBlocked => ToolResult.fail("High-risk command blocked by security policy"),
                    error.ApprovalRequired => blk: {
                        const msg = try std.fmt.allocPrint(allocator, "Command requires approval (medium/high risk): {s}", .{command});
                        break :blk ToolResult{ .success = false, .output = "", .error_msg = msg };
                    },
                };
            };
        }

        // Determine working directory
        const effective_cwd = if (root.getString(args, "cwd")) |cwd| blk: {
            // cwd must be absolute
            if (cwd.len == 0 or !std.fs.path.isAbsolute(cwd))
                return ToolResult.fail("cwd must be an absolute path");
            // Resolve and validate
            const resolved_cwd = resolvePathAlloc(allocator, cwd) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to resolve cwd: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
            };
            defer allocator.free(resolved_cwd);

            const ws_resolved: ?[]const u8 = resolvePathAlloc(allocator, self.workspace_dir) catch null;
            defer if (ws_resolved) |wr| allocator.free(wr);
            if (ws_resolved == null and self.allowed_paths.len == 0)
                return ToolResult.fail("cwd not allowed (workspace unavailable and no allowed_paths configured)");

            if (!isResolvedPathAllowed(allocator, resolved_cwd, ws_resolved orelse UNAVAILABLE_WORKSPACE_SENTINEL, self.allowed_paths))
                return ToolResult.fail("cwd is outside allowed areas");

            break :blk cwd;
        } else self.workspace_dir;

        // Note: In Zig 0.16.0, environment is inherited from parent process.
        // Environment filtering is not supported in the new API.
        // TODO: Implement environment filtering if needed for security

        // Execute in dedicated subprocess thread to avoid macOS fork() crashes
        slog.logStructured("DEBUG", "shell", "spawn_start", .{});
        const executor = try getSubprocessExecutor();
        const exec_result = executor.execute(command, effective_cwd) catch |err| {
            slog.logStructured("ERROR", "shell", "execute_failed", .{.err_str = @errorName(err)});
            const msg = try std.fmt.allocPrint(allocator, "Shell execution failed: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        };
        defer SubprocessExecutor.freeResult(exec_result);
        slog.logStructured("DEBUG", "shell", "spawn_complete", .{.success = exec_result.success});

        // Convert subprocess result to ToolResult
        if (exec_result.success) {
            const result = if (exec_result.stdout.len > 0)
                ToolResult{ .success = true, .output = try allocator.dupe(u8, exec_result.stdout), .owns_output = true }
            else
                ToolResult{ .success = true, .output = try allocator.dupe(u8, "(no output)") };
            return result;
        }

        // Failure path
        const err_out = if (exec_result.exit_code != null)
            if (exec_result.stderr.len > 0)
                try allocator.dupe(u8, exec_result.stderr)
            else
                "Command failed with non-zero exit code"
        else
            "Command terminated by signal";

        return ToolResult{ .success = false, .output = "", .error_msg = err_out, .owns_error_msg = true };
    }
};

/// Extract a string field value from a JSON blob (minimal parser — no allocations).
/// NOTE: Prefer root.getString() with pre-parsed ObjectMap for tool implementations.
pub fn parseStringField(json: []const u8, key: []const u8) ?[]const u8 {
    // Find "key": "value"
    // Build the search pattern: "key":"  or "key" : "
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1; // skip opening quote

    // Find closing quote (handle escaped quotes)
    const start = i;
    while (i < after_key.len) : (i += 1) {
        if (after_key[i] == '\\' and i + 1 < after_key.len) {
            i += 1; // skip escaped char
            continue;
        }
        if (after_key[i] == '"') {
            return after_key[start..i];
        }
    }
    return null;
}

/// Extract a boolean field value from a JSON blob.
pub fn parseBoolField(json: []const u8, key: []const u8) ?bool {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    if (i + 4 <= after_key.len and std.mem.eql(u8, after_key[i..][0..4], "true")) return true;
    if (i + 5 <= after_key.len and std.mem.eql(u8, after_key[i..][0..5], "false")) return false;
    return null;
}

/// Extract an integer field value from a JSON blob.
pub fn parseIntField(json: []const u8, key: []const u8) ?i64 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    const start = i;
    if (i < after_key.len and after_key[i] == '-') i += 1;
    while (i < after_key.len and after_key[i] >= '0' and after_key[i] <= '9') : (i += 1) {}
    if (i == start) return null;

    return std.fmt.parseInt(i64, after_key[start..i], 10) catch null;
}

// ── Tests ───────────────────────────────────────────────────────────

test "shell tool name" {
    var st = ShellTool{ .workspace_dir = "/tmp" };
    const t = st.tool();
    try std.testing.expectEqualStrings("shell", t.name());
}

test "shell tool schema has command" {
    var st = ShellTool{ .workspace_dir = "/tmp" };
    const t = st.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "command") != null);
}

test "shell executes echo" {
    var st = ShellTool{ .workspace_dir = "." };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"command\": \"echo hello\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello") != null);
}

test "shell captures failing command" {
    var st = ShellTool{ .workspace_dir = "." };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"command\": \"ls /nonexistent_dir_xyz_42\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.success);
}

test "shell missing command param" {
    var st = ShellTool{ .workspace_dir = "." };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

test "parseStringField basic" {
    const json = "{\"command\": \"echo hello\", \"other\": \"val\"}";
    const val = parseStringField(json, "command");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("echo hello", val.?);
}

test "parseStringField missing" {
    const json = "{\"other\": \"val\"}";
    try std.testing.expect(parseStringField(json, "command") == null);
}

test "parseBoolField true" {
    const json = "{\"cached\": true}";
    try std.testing.expectEqual(@as(?bool, true), parseBoolField(json, "cached"));
}

test "parseBoolField false" {
    const json = "{\"cached\": false}";
    try std.testing.expectEqual(@as(?bool, false), parseBoolField(json, "cached"));
}

test "parseIntField positive" {
    const json = "{\"limit\": 42}";
    try std.testing.expectEqual(@as(?i64, 42), parseIntField(json, "limit"));
}

test "parseIntField negative" {
    const json = "{\"offset\": -5}";
    try std.testing.expectEqual(@as(?i64, -5), parseIntField(json, "offset"));
}

test "shell cwd inside workspace works without allowed_paths" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // pwd not available on Windows

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path.ptr[0 .. tmp_path.len + 1]);

    var args_buf: [512]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"command\": \"pwd\", \"cwd\": \"{s}\"}}", .{tmp_path});

    var st = ShellTool{ .workspace_dir = tmp_path };
    const parsed = try root.parseTestArgs(args);
    defer parsed.deinit();
    const result = try st.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, tmp_path) != null);
}

test "shell cwd outside workspace without allowed_paths is rejected" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // pwd not available on Windows

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    // Create directories using createDirPath (Zig 0.16 API)
    try tmp_dir.dir.createDirPath(std.Options.debug_io, "ws");
    try tmp_dir.dir.createDirPath(std.Options.debug_io, "other");
    const root_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path.ptr[0 .. root_path.len + 1]);
    const ws_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "ws" });
    defer std.testing.allocator.free(ws_path);
    const other_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "other" });
    defer std.testing.allocator.free(other_path);

    var args_buf: [768]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"command\": \"pwd\", \"cwd\": \"{s}\"}}", .{other_path});

    var st = ShellTool{ .workspace_dir = ws_path };
    const parsed = try root.parseTestArgs(args);
    defer parsed.deinit();
    const result = try st.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "outside allowed areas") != null);
}

test "shell cwd relative path is rejected" {
    var st = ShellTool{ .workspace_dir = "/tmp", .allowed_paths = &.{"/tmp"} };
    const parsed = try root.parseTestArgs("{\"command\": \"pwd\", \"cwd\": \"relative\"}");
    defer parsed.deinit();
    const result = try st.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "absolute") != null);
}

test "shell cwd with allowed_paths runs in cwd" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // pwd not available on Windows

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path.ptr[0 .. tmp_path.len + 1]);

    var args_buf: [512]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"command\": \"pwd\", \"cwd\": \"{s}\"}}", .{tmp_path});

    const parsed = try root.parseTestArgs(args);
    defer parsed.deinit();

    var st = ShellTool{ .workspace_dir = ".", .allowed_paths = &.{tmp_path} };
    const result = try st.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, tmp_path) != null);
}

test "shell ApprovalRequired error includes command name" {
    const policy_mod = @import("../security/policy.zig");
    var tracker = policy_mod.RateTracker.init(std.testing.allocator, 100);
    defer tracker.deinit();
    const allowed = [_][]const u8{ "git", "ls", "cat", "grep", "echo", "touch" };
    var policy = policy_mod.SecurityPolicy{
        .autonomy = .supervised,
        .workspace_dir = "/tmp",
        .require_approval_for_medium_risk = true,
        .block_high_risk_commands = false,
        .tracker = &tracker,
        .allowed_commands = &allowed,
    };

    var st = ShellTool{ .workspace_dir = "/tmp", .policy = &policy };
    const parsed = try root.parseTestArgs("{\"command\": \"touch test.txt\"}");
    defer parsed.deinit();
    const result = try st.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
    defer std.testing.allocator.free(result.error_msg.?);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "touch test.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "approval") != null);
}

test "shell ApprovalRequired propagates oom for error message allocation" {
    const policy_mod = @import("../security/policy.zig");
    var tracker = policy_mod.RateTracker.init(std.testing.allocator, 100);
    defer tracker.deinit();
    const allowed = [_][]const u8{ "git", "ls", "cat", "grep", "echo", "touch" };
    var policy = policy_mod.SecurityPolicy{
        .autonomy = .supervised,
        .workspace_dir = "/tmp",
        .require_approval_for_medium_risk = true,
        .block_high_risk_commands = false,
        .tracker = &tracker,
        .allowed_commands = &allowed,
    };

    var st = ShellTool{ .workspace_dir = "/tmp", .policy = &policy };
    const parsed = try root.parseTestArgs("{\"command\": \"touch test.txt\"}");
    defer parsed.deinit();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        st.execute(failing.allocator(), parsed.parsed.value.object, std.testing.io),
    );
}
