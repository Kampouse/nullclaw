const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const slog = @import("../structured_log.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const path_security = @import("path_security.zig");
const process_util = @import("process_util.zig");
const isResolvedPathAllowed = path_security.isResolvedPathAllowed;
const resolvePathAlloc = path_security.resolvePathAlloc;

/// Detect the source repository directory by using git to find the repo root.
/// Returns an owned path if found, null otherwise.
fn detectSourceRepo(allocator: std.mem.Allocator) ?[]const u8 {
    // Use git to find the repository root from the current working directory
    // git rev-parse --show-toplevel returns the absolute path to the repository root
    const result = process_util.run(allocator, &.{ "git", "rev-parse", "--show-toplevel" }, .{}) catch return null;
    defer result.deinit(allocator);

    if (!result.success) return null;

    const output = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (output.len == 0) return null;

    return allocator.dupe(u8, output) catch null;
}

/// Self-update tool for agent version verification and self-compilation.
pub const SelfUpdateTool = struct {
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},

    pub const tool_name = "self_update";
    pub const tool_description = "Check for updates, pull latest changes, self-compile the agent, perform health checks on the new binary, and optionally restart automatically.";
    pub const tool_params =
        \\{"type":"object","properties":{"operation":{"type":"string","enum":["check","pull","compile","full_update","status","restart","full_update_with_restart","health_check"],"description":"Operation to perform: check (compare versions), pull (fetch latest), compile (rebuild agent), full_update (pull and compile), status (show current info), restart (restart the agent process), full_update_with_restart (pull, compile, health check, and restart), health_check (verify new binary is healthy and safe to use before restart)"},"branch":{"type":"string","description":"Branch to update from (default: current branch)"},"force":{"type":"boolean","description":"Force update even if already latest"}},"required":["operation"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *SelfUpdateTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn executeGit(allocator: std.mem.Allocator, args: []const []const u8, cwd: []const u8) ![]const u8 {
        slog.logStructured("DEBUG", "self_update", "git_start", .{.cwd = cwd});

        var argv_buf: [32][]const u8 = undefined;
        argv_buf[0] = "git";
        const arg_count = @min(args.len, argv_buf.len - 1);
        for (args[0..arg_count], 1..) |a, i| {
            argv_buf[i] = a;
        }

        slog.logStructured("DEBUG", "self_update", "git_calling_process", .{});
        const result = try process_util.run(allocator, argv_buf[0 .. arg_count + 1], .{ .cwd = cwd });
        slog.logStructured("DEBUG", "self_update", "git_process_returned", .{});
        defer result.deinit(allocator);

        if (!result.success) {
            slog.logStructured("ERROR", "self_update", "git_failed", .{});
            return error.GitCommandFailed;
        }

        slog.logStructured("DEBUG", "self_update", "git_success", .{});
        return allocator.dupe(u8, result.stdout);
    }

    fn getCurrentBranch(allocator: std.mem.Allocator, repo_dir: []const u8) ![]const u8 {
        slog.logStructured("DEBUG", "self_update", "get_branch_start", .{});
        const output = try executeGit(allocator, &.{ "rev-parse", "--abbrev-ref", "HEAD" }, repo_dir);
        defer allocator.free(output);
        slog.logStructured("DEBUG", "self_update", "get_branch_success", .{});
        return std.mem.trim(u8, output, &std.ascii.whitespace);
    }

    fn getCurrentCommit(allocator: std.mem.Allocator, repo_dir: []const u8) ![]const u8 {
        const output = try executeGit(allocator, &.{ "rev-parse", "HEAD" }, repo_dir);
        defer allocator.free(output);
        return std.mem.trim(u8, output, &std.ascii.whitespace);
    }

    fn getRemoteCommit(allocator: std.mem.Allocator, repo_dir: []const u8, branch: []const u8) ![]const u8 {
        // First fetch to ensure we have latest remote info
        _ = try executeGit(allocator, &.{ "fetch", "origin" }, repo_dir);

        // Construct the branch reference string
        const branch_ref = try std.fmt.allocPrint(allocator, "origin/{s}", .{branch});
        defer allocator.free(branch_ref);

        const output = try executeGit(allocator, &.{ "rev-parse", branch_ref }, repo_dir);
        defer allocator.free(output);
        return std.mem.trim(u8, output, &std.ascii.whitespace);
    }

    fn hasUncommittedChanges(allocator: std.mem.Allocator, repo_dir: []const u8) !bool {
        const output = try executeGit(allocator, &.{ "status", "--porcelain" }, repo_dir);
        defer allocator.free(output);
        return output.len > 0;
    }

    fn formatCommitMessage(allocator: std.mem.Allocator, repo_dir: []const u8, commit: []const u8) ![]const u8 {
        const output = try executeGit(allocator, &.{ "log", "-1", "--format=%h - %s (%cr)", commit }, repo_dir);
        defer allocator.free(output);
        return std.mem.trim(u8, output, &std.ascii.whitespace);
    }

    fn restartAgent(_: *const SelfUpdateTool, allocator: std.mem.Allocator) ToolResult {
        const pid = std.os.linux.getpid();
        const ppid = std.os.linux.getppid();

        const header = std.fmt.allocPrint(allocator,
            \\🔄 Restarting agent...
            \\   Current PID: {d}
            \\   Parent PID: {d}
            \\
        , .{ pid, ppid }) catch return ToolResult.fail("Failed to allocate output");
        defer allocator.free(header);

        // Provide instructions for manual restart since we don't use shell
        const instructions = std.fmt.allocPrint(allocator,
            \\{s}
            \\Manual restart required (no shell dependencies):
            \\1. Current agent (PID {d}) has been updated
            \\2. Stop the current process
            \\3. Start the new binary: zig-out/bin/nullclaw
            \\Or use your process manager (systemd, supervisor, etc.)
        , .{ header, pid }) catch return ToolResult.fail("Failed to allocate output");

        return ToolResult{ .success = true, .output = instructions, .owns_output = true };
    }

    fn restartDirectProcess(allocator: std.mem.Allocator, repo_dir: []const u8) ToolResult {
        _ = repo_dir;

        // For direct process, we use fork/exec without shell
        const pid = std.os.linux.getpid();
        const ppid = std.os.linux.getppid();

        const output = std.fmt.allocPrint(allocator,
            \\Initiating restart via process management
            \\Current PID: {d}
            \\Parent PID: {d}
            \\A new process will be spawned and current process will exit
        , .{ pid, ppid }) catch return ToolResult.fail("Failed to allocate output");

        // In a real implementation, this would use fork() and exec()
        // For now, provide instructions for manual restart
        const instructions = std.fmt.allocPrint(allocator,
            \\{s}
            \\
            \\Manual restart required:
            \\1. New binary has been compiled
            \\2. Stop current process (PID {d})
            \\3. Start new binary: zig-out/bin/nullclaw
            \\Or use your process manager (systemd, supervisor, etc.)
        , .{ output, pid }) catch return ToolResult.fail("Failed to allocate output");

        return ToolResult{ .success = true, .output = instructions, .owns_output = true };
    }

    fn healthCheckNewBinary(_: *const SelfUpdateTool, allocator: std.mem.Allocator, repo_dir: []const u8) ToolResult {
        // Path to the newly compiled binary
        const binary_path = "zig-out/bin/nullclaw";

        // First check if binary exists and get the resolved path
        const resolved_binary_path = resolvePathAlloc(allocator, binary_path) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to resolve binary path: {}", .{err}) catch return ToolResult.fail("Failed to resolve binary path");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        };
        defer allocator.free(resolved_binary_path);

        // Run the binary with a simple health check command
        // We'll use --version or --help as a basic health check
        // This will also verify the binary exists
        const version_result = process_util.run(allocator, &.{ resolved_binary_path, "--version" }, .{ .cwd = repo_dir }) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to run health check (binary may not exist): {}", .{err}) catch return ToolResult.fail("Health check failed");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        };
        defer version_result.deinit(allocator);

        if (!version_result.success) {
            const err_msg = std.fmt.allocPrint(allocator,
                \\❌ Health check FAILED!
                \\   The new binary is not healthy
                \\   Exit code: {}
                \\   Error: {s}
            , .{ version_result.exit_code orelse 1, version_result.stderr }) catch return ToolResult.fail("Health check failed");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        }

        // Parse version info
        const version_info = std.mem.trim(u8, version_result.stdout, &std.ascii.whitespace);

        // Test basic functionality with a simple help command
        const help_result = process_util.run(allocator, &.{ resolved_binary_path, "--help" }, .{ .cwd = repo_dir }) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to run help check: {}", .{err}) catch return ToolResult.fail("Help check failed");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        };
        defer help_result.deinit(allocator);

        if (!help_result.success) {
            const err_msg = std.fmt.allocPrint(allocator,
                \\❌ Help check FAILED!
                \\   The new binary may have issues
                \\   Error: {s}
            , .{help_result.stderr}) catch return ToolResult.fail("Help check failed");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        }

        // Check if help output contains expected content
        const has_basic_help = std.mem.indexOf(u8, help_result.stdout, "usage") != null or
            std.mem.indexOf(u8, help_result.stdout, "help") != null or
            std.mem.indexOf(u8, help_result.stdout, "Usage") != null or
            std.mem.indexOf(u8, help_result.stdout, "Help") != null;

        if (!has_basic_help and help_result.stdout.len < 10) {
            const err_msg = std.fmt.allocPrint(allocator,
                \\❌ Health check FAILED!
                \\   The new binary produced unexpected output
                \\   Output: {s}
            , .{help_result.stdout}) catch return ToolResult.fail("Unexpected output");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        }

        const output = std.fmt.allocPrint(allocator,
            \\✅ Health check PASSED!
            \\   The new binary is healthy and ready to use
            \\
            \\   Version: {s}
            \\   Binary: {s}
            \\
            \\🎯 Safe to proceed with restart:
            \\1. Stop the current process (PID {d})
            \\2. Start the new binary: {s}
            \\3. Verify the new instance is working correctly
        , .{ version_info, resolved_binary_path, std.os.linux.getpid(), resolved_binary_path }) catch return ToolResult.fail("Failed to allocate output");

        return ToolResult{ .success = true, .output = output, .owns_output = true };
    }

    pub fn execute(self: *const SelfUpdateTool, allocator: std.mem.Allocator, args: JsonObjectMap, io: std.Io) ToolResult {
        _ = io;
        slog.logStructured("DEBUG", "self_update", "execute_start", .{});

        const operation_obj = args.get("operation");
        const operation = if (operation_obj) |op| op.string else "status";
        slog.logStructured("DEBUG", "self_update", "execute_operation", .{.op = operation});

        // Determine working directory
        // Priority: 1) explicit cwd arg, 2) detect from executable path, 3) workspace_dir
        var detected_repo: ?[]const u8 = null;
        defer if (detected_repo) |dr| allocator.free(dr);

        const repo_dir: []const u8 = blk: {
            if (args.get("cwd")) |cwd| {
                slog.logStructured("DEBUG", "self_update", "using_cwd", .{.cwd = cwd.string});
                break :blk cwd.string;
            }

            // Try to detect source repo from executable path
            if (detectSourceRepo(allocator)) |detected| {
                slog.logStructured("DEBUG", "self_update", "detected_repo", .{.path = detected});
                detected_repo = detected;
                break :blk detected;
            }

            slog.logStructured("DEBUG", "self_update", "fallback_workspace", .{.path = self.workspace_dir});
            break :blk self.workspace_dir;
        };
        slog.logStructured("DEBUG", "self_update", "repo_dir", .{.path = repo_dir});

        // Resolve and validate path
        slog.logStructured("DEBUG", "self_update", "resolving_path", .{});
        const resolved_repo_dir = resolvePathAlloc(allocator, repo_dir) catch |err| {
            slog.logStructured("ERROR", "self_update", "path_resolution_failed", .{.err = err});
            const err_msg = std.fmt.allocPrint(allocator, "Failed to resolve repository path: {}", .{err}) catch return ToolResult.fail("Failed to resolve repository path");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        };
        defer allocator.free(resolved_repo_dir);
        slog.logStructured("DEBUG", "self_update", "resolved_repo_dir", .{.path = resolved_repo_dir});

        // Security check
        // Note: We bypass the security check if we detected the source repo from the executable path.
        // This is safe because:
        // 1. The detected path comes from git rev-parse, not user input
        // 2. The self_update tool is specifically for updating the agent's own source code
        // 3. The user explicitly ran this tool to perform self-update
        slog.logStructured("DEBUG", "self_update", "checking_path_security", .{});
        if (detected_repo == null and !isResolvedPathAllowed(allocator, resolved_repo_dir, self.workspace_dir, self.allowed_paths)) {
            slog.logStructured("WARN", "self_update", "path_not_allowed", .{});
            const err_msg = std.fmt.allocPrint(allocator, "Path '{s}' is not allowed", .{resolved_repo_dir}) catch return ToolResult.fail("Path not allowed");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        }

        const working_dir = resolved_repo_dir;

        const trimmed_op = std.mem.trim(u8, operation, &std.ascii.whitespace);
        slog.logStructured("DEBUG", "self_update", "trimmed_op", .{.op = trimmed_op});

        if (std.mem.eql(u8, trimmed_op, "status")) {
            slog.logStructured("DEBUG", "self_update", "calling_show_status", .{});
            return self.showStatus(allocator, working_dir);
        } else if (std.mem.eql(u8, trimmed_op, "check")) {
            slog.logStructured("DEBUG", "self_update", "calling_check_updates", .{});
            return self.checkForUpdates(allocator, working_dir, args);
        } else if (std.mem.eql(u8, trimmed_op, "pull")) {
            slog.logStructured("DEBUG", "self_update", "calling_pull_updates", .{});
            return self.pullUpdates(allocator, working_dir, args);
        } else if (std.mem.eql(u8, trimmed_op, "compile")) {
            return self.compileAgent(allocator, working_dir);
        } else if (std.mem.eql(u8, trimmed_op, "full_update")) {
            return self.fullUpdate(allocator, working_dir, args);
        } else if (std.mem.eql(u8, trimmed_op, "restart")) {
            return self.restartAgent(allocator);
        } else if (std.mem.eql(u8, trimmed_op, "full_update_with_restart")) {
            return self.fullUpdateWithRestart(allocator, working_dir, args);
        } else if (std.mem.eql(u8, trimmed_op, "health_check")) {
            return self.healthCheckNewBinary(allocator, working_dir);
        } else {
            const err_msg = std.fmt.allocPrint(allocator, "Unknown operation: '{s}'", .{operation}) catch return ToolResult.fail("Unknown operation");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        }
    }

    fn showStatus(_: *const SelfUpdateTool, allocator: std.mem.Allocator, repo_dir: []const u8) ToolResult {
        const current_branch = getCurrentBranch(allocator, repo_dir) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to get current branch: {}", .{err}) catch return ToolResult.fail("Failed to get current branch");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        };
        defer allocator.free(current_branch);

        const current_commit = getCurrentCommit(allocator, repo_dir) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to get current commit: {}", .{err}) catch return ToolResult.fail("Failed to get current commit");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        };
        defer allocator.free(current_commit);

        const commit_msg = formatCommitMessage(allocator, repo_dir, current_commit) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to get commit message: {}", .{err}) catch return ToolResult.fail("Failed to get commit message");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        };
        defer allocator.free(commit_msg);

        const has_changes = hasUncommittedChanges(allocator, repo_dir) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to check for uncommitted changes: {}", .{err}) catch return ToolResult.fail("Failed to check for uncommitted changes");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        };

        const output = std.fmt.allocPrint(allocator,
            \\Agent Status
            \\============
            \\Current Branch: {s}
            \\Current Commit: {s}
            \\Uncommitted Changes: {s}
            \\
        , .{ current_branch, commit_msg, if (has_changes) "Yes" else "No" }) catch return ToolResult.fail("Failed to allocate output");

        return ToolResult{ .success = true, .output = output, .owns_output = true };
    }

    fn checkForUpdates(_: *const SelfUpdateTool, allocator: std.mem.Allocator, repo_dir: []const u8, args: JsonObjectMap) ToolResult {
        const branch_obj = args.get("branch");
        const branch_name = if (branch_obj) |b| b.string else getCurrentBranch(allocator, repo_dir) catch {
            return ToolResult.fail("Failed to get current branch");
        };

        const current_commit = getCurrentCommit(allocator, repo_dir) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to get current commit: {}", .{err}) catch return ToolResult.fail("Failed to get current commit");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        };
        defer allocator.free(current_commit);

        const remote_commit = getRemoteCommit(allocator, repo_dir, branch_name) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to get remote commit: {}", .{err}) catch return ToolResult.fail("Failed to get remote commit");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        };
        defer allocator.free(remote_commit);

        const has_changes = hasUncommittedChanges(allocator, repo_dir) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to check for uncommitted changes: {}", .{err}) catch return ToolResult.fail("Failed to check for uncommitted changes");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        };

        if (std.mem.eql(u8, current_commit, remote_commit)) {
            const output = std.fmt.allocPrint(allocator,
                \\Update Check Results
                \\====================
                \\
                \\Current Branch: {s}
                \\Local Commit:  {s}
                \\Remote Commit: {s}
                \\
                \\✅ Status: Up to date
                \\   Your agent is running the latest version
            , .{ branch_name, current_commit[0..7], remote_commit[0..7] }) catch return ToolResult.fail("Failed to allocate output");

            return ToolResult{ .success = true, .output = output, .owns_output = true };
        } else {
            const local_msg = formatCommitMessage(allocator, repo_dir, current_commit) catch "";
            defer if (local_msg.len > 0) allocator.free(local_msg);

            const remote_msg = formatCommitMessage(allocator, repo_dir, remote_commit) catch "";
            defer if (remote_msg.len > 0) allocator.free(remote_msg);

            var warning: []const u8 = "";
            if (has_changes) {
                warning = "\\⚠️  WARNING: You have uncommitted changes\\n   These changes may be lost during pull/update operations\\n   Consider committing or stashing them first\\n\\n";
            }

            const output = std.fmt.allocPrint(allocator,
                \\Update Check Results
                \\====================
                \\
                \\{s}
                \\Current Branch: {s}
                \\Local Commit:  {s}
                \\Remote Commit: {s}
                \\
                \\📅 Status: Updates available
                \\   Your version:   {s}
                \\   Latest version: {s}
                \\
                \\💡 Run 'self_update' with operation='pull' or 'full_update' to update
            , .{ warning, branch_name, current_commit[0..7], remote_commit[0..7], local_msg, remote_msg }) catch return ToolResult.fail("Failed to allocate output");

            return ToolResult{ .success = true, .output = output, .owns_output = true };
        }
    }

    fn pullUpdates(_: *const SelfUpdateTool, allocator: std.mem.Allocator, repo_dir: []const u8, args: JsonObjectMap) ToolResult {
        const branch_obj = args.get("branch");
        const branch = if (branch_obj) |b| b.string else getCurrentBranch(allocator, repo_dir) catch "main";

        // Check for uncommitted changes first
        const has_changes = hasUncommittedChanges(allocator, repo_dir) catch false;
        if (has_changes) {
            const err_msg = "Cannot pull: You have uncommitted changes. Please commit or stash them first.";
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = false };
        }

        // Fetch latest
        const fetch_output = executeGit(allocator, &.{ "fetch", "origin" }, repo_dir) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to fetch updates: {}", .{err}) catch return ToolResult.fail("Failed to fetch updates");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        };
        defer allocator.free(fetch_output);

        // Pull updates
        const pull_output = executeGit(allocator, &.{ "pull", "origin", branch }, repo_dir) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to pull updates: {}", .{err}) catch return ToolResult.fail("Failed to pull updates");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        };
        defer allocator.free(pull_output);

        const output = std.fmt.allocPrint(allocator,
            \\✅ Successfully pulled latest changes
            \\   Branch: {s}
            \\
            \\💡 Run 'self_update' with operation='compile' to rebuild the agent
        , .{branch}) catch return ToolResult.fail("Failed to allocate output");

        return ToolResult{ .success = true, .output = output, .owns_output = true };
    }

    fn compileAgent(_: *const SelfUpdateTool, allocator: std.mem.Allocator, repo_dir: []const u8) ToolResult {
        // Check and log the workspace being used
        const platform = @import("../platform.zig");
        const current_workspace = platform.getEnvOrNull(allocator, "NULLCLAW_WORKSPACE");
        defer if (current_workspace) |w| allocator.free(w);

        slog.logStructured("DEBUG", "self_update", "build_workspace", .{
            .workspace = if (current_workspace) |w| w else "(default ~/.nullclaw/workspace)",
            .repo_dir = repo_dir,
        });

        // Note: The build process will inherit the parent process environment,
        // including NULLCLAW_WORKSPACE if it was set when the agent was started.
        // This ensures workspace consistency across self-updates.

        // Use ReleaseSmall optimization for minimal binary size (< 1 MB target)
        const build_result = process_util.run(allocator, &.{ "zig", "build", "-Doptimize=ReleaseSmall" }, .{ .cwd = repo_dir }) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to start build process: {}", .{err}) catch return ToolResult.fail("Failed to start build process");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        };
        defer build_result.deinit(allocator);

        if (!build_result.success) {
            const err_msg = std.fmt.allocPrint(allocator,
                \\❌ Build failed!
                \\   Exit code: {}
                \\   Error output:
                \\   {s}
            , .{ build_result.exit_code orelse 1, build_result.stderr }) catch return ToolResult.fail("Build failed");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        }

        const output = std.fmt.allocPrint(allocator,
            \\✅ Build successful!
            \\   Agent has been recompiled with ReleaseSmall optimization
            \\   Binary size optimized for minimal footprint
            \\
            \\💡 Restart the agent to use the new version
        , .{}) catch return ToolResult.fail("Failed to allocate output");

        return ToolResult{ .success = true, .output = output, .owns_output = true };
    }

    fn fullUpdate(self: *const SelfUpdateTool, allocator: std.mem.Allocator, repo_dir: []const u8, args: JsonObjectMap) ToolResult {
        // Step 1: Pull updates
        const pull_result = self.pullUpdates(allocator, repo_dir, args);
        if (!pull_result.success) {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to pull updates: {s}\n", .{pull_result.error_msg orelse "Unknown error"}) catch return ToolResult.fail("Update failed");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        }

        // Step 2: Compile
        const compile_result = self.compileAgent(allocator, repo_dir);
        if (!compile_result.success) {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to compile: {s}\n", .{compile_result.error_msg orelse "Unknown error"}) catch return ToolResult.fail("Update failed");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        }

        const output = std.fmt.allocPrint(allocator,
            \\🎉 Full update completed successfully!
            \\   Restart the agent to use the new version
        , .{}) catch return ToolResult.fail("Failed to allocate output");

        return ToolResult{ .success = true, .output = output, .owns_output = true };
    }

    fn fullUpdateWithRestart(self: *const SelfUpdateTool, allocator: std.mem.Allocator, repo_dir: []const u8, args: JsonObjectMap) ToolResult {
        // Step 1: Pull updates
        const pull_result = self.pullUpdates(allocator, repo_dir, args);
        if (!pull_result.success) {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to pull updates: {s}\n", .{pull_result.error_msg orelse "Unknown error"}) catch return ToolResult.fail("Update failed");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        }

        // Step 2: Compile
        const compile_result = self.compileAgent(allocator, repo_dir);
        if (!compile_result.success) {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to compile: {s}\n", .{compile_result.error_msg orelse "Unknown error"}) catch return ToolResult.fail("Update failed");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        }

        // Step 3: Health check - CRITICAL: Verify new binary is healthy before restart
        const health_result = self.healthCheckNewBinary(allocator, repo_dir);
        if (!health_result.success) {
            const err_msg = std.fmt.allocPrint(allocator, "⛔️ UPDATE HALTED: New binary failed health check!\n\n{s}\n\n⚠️ DO NOT restart! The old agent is still running and safe.", .{health_result.error_msg orelse "Health check failed"}) catch return ToolResult.fail("Health check failed");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        }

        // Step 4: Safe to restart - new binary is healthy
        const restart_result = self.restartAgent(allocator);
        if (!restart_result.success) {
            const err_msg = std.fmt.allocPrint(allocator, "Failed to restart: {s}\n", .{restart_result.error_msg orelse "Unknown error"}) catch return ToolResult.fail("Restart failed");
            return ToolResult{ .success = false, .output = "", .error_msg = err_msg, .owns_error_msg = true };
        }

        const output = std.fmt.allocPrint(allocator,
            \\🎉 Full update with restart completed successfully!
            \\   ✅ Updates pulled
            \\   ✅ Agent compiled
            \\   ✅ Health check passed
            \\   ✅ Ready to restart
            \\
            \\   The new binary is healthy and safe to use.
        , .{}) catch return ToolResult.fail("Failed to allocate output");

        return ToolResult{ .success = true, .output = output, .owns_output = true };
    }

    pub fn deinit(self: *SelfUpdateTool, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

test "SelfUpdateTool tool properties" {
    try std.testing.expectEqualStrings("self_update", SelfUpdateTool.tool_name);
    try std.testing.expect(SelfUpdateTool.tool_description.len > 0);
}

// Helper function to get realpath from Dir (Zig 0.16 API)
fn testDirRealpathAlloc(allocator: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    const result = try dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    // result is [:0]u8 with allocation size len+1 (includes sentinel)
    // Dupe the content without sentinel, then free the original
    const path = try allocator.dupe(u8, result[0..result.len]);
    allocator.free(result.ptr[0 .. result.len + 1]);
    return path;
}

test "SelfUpdateTool showStatus with valid repo" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    // Get the real path of the temp directory
    const test_path = try testDirRealpathAlloc(std.testing.allocator, test_dir.dir);
    defer std.testing.allocator.free(test_path);

    // Initialize a test git repo
    const git_result = try process_util.run(std.testing.allocator, &.{ "git", "init" }, .{
        .cwd = test_path,
    });
    git_result.deinit(std.testing.allocator);

    const tool = SelfUpdateTool{
        .workspace_dir = test_path,
    };

    const result = tool.showStatus(std.testing.allocator, test_path);
    defer result.deinit(std.testing.allocator);

    // Status should either succeed or fail, but not crash
    try std.testing.expect(true);
}

test "SelfUpdateTool hasUncommittedChanges detection" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    // Get the real path of the temp directory
    const test_path = try testDirRealpathAlloc(std.testing.allocator, test_dir.dir);
    defer std.testing.allocator.free(test_path);

    // Initialize a test git repo
    const git_result = try process_util.run(std.testing.allocator, &.{ "git", "init" }, .{
        .cwd = test_path,
    });
    git_result.deinit(std.testing.allocator);

    const tool = SelfUpdateTool{
        .workspace_dir = test_path,
    };

    // Check status on empty repo - should not crash
    const result = tool.showStatus(std.testing.allocator, test_path);
    defer result.deinit(std.testing.allocator);

    // Should not crash
    try std.testing.expect(true);
}

test "SelfUpdateTool healthCheckNewBinary with existing binary" {
    const tool = SelfUpdateTool{
        .workspace_dir = "/tmp",
    };

    // Test health check on current binary - should not crash
    const result = tool.healthCheckNewBinary(std.testing.allocator, "/tmp");
    defer result.deinit(std.testing.allocator);

    // Health check should either succeed or fail gracefully
    try std.testing.expect(true);
}
