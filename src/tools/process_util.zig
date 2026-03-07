const std = @import("std");
const io = std.Options.debug_io;

/// Result of a child process execution.
pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    success: bool,
    exit_code: ?u32 = null,
    /// Whether stdout and stderr are owned (allocated) by this RunResult.
    /// If false, deinit() will not free them.
    owns_buffers: bool = true,

    /// Free both stdout and stderr buffers if they are owned.
    /// Only free non-empty slices since std.process.run() may not allocate empty buffers.
    pub fn deinit(self: *const RunResult, allocator: std.mem.Allocator) void {
        if (self.owns_buffers) {
            // Only free if actually allocated (non-empty)
            // Empty slices from std.process.run() are not allocated memory
            if (self.stdout.len > 0) allocator.free(self.stdout);
            if (self.stderr.len > 0) allocator.free(self.stderr);
        }
    }
};

/// Options for running a child process.
pub const RunOptions = struct {
    cwd: ?[]const u8 = null,
    env_map: ?*anyopaque = null, // Ignored in Zig 0.16.0 - environment inherited from parent
    max_output_bytes: usize = 1_048_576,
};

/// Run a child process, capture stdout and stderr, and return the result.
///
/// The caller owns the returned stdout and stderr buffers.
/// Use `result.deinit(allocator)` to free them.
pub fn run(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    opts: RunOptions,
) !RunResult {
    // CRITICAL: std.Options.debug_io uses a .failing allocator (see Io/Threaded.zig:1622)
    // This causes OutOfMemory when std.process.run creates internal ArenaAllocator.
    // Use util.createProcessIo() to get a proper Io instance with page_allocator.
    const util = @import("../util.zig");
    const spawn_io = util.createProcessIo();

    // Use std.process.run with our custom Io and allocator
    // Convert our ?[]const u8 cwd to std.process.Child.Cwd format
    const cwd_option: std.process.Child.Cwd = if (opts.cwd) |path| .{ .path = path } else .inherit;
    const result = try std.process.run(allocator, spawn_io, .{
        .argv = argv,
        .cwd = cwd_option,
        .stdout_limit = .limited(opts.max_output_bytes),
        .stderr_limit = .limited(opts.max_output_bytes),
    });

    return switch (result.term) {
        .exited => |code| .{
            .stdout = result.stdout,
            .stderr = result.stderr,
            .success = code == 0,
            .exit_code = code,
            .owns_buffers = true,
        },
        else => .{
            .stdout = result.stdout,
            .stderr = result.stderr,
            .success = false,
            .exit_code = null,
            .owns_buffers = true,
        },
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const builtin = @import("builtin");

test "run echo returns stdout" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    // Use page_allocator for these tests since the run() function creates its own Io instance
    const allocator = std.heap.page_allocator;
    const result = try run(allocator, &.{ "echo", "hello" }, .{});
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u32, 0), result.exit_code.?);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello") != null);
}

test "run failing command returns exit code" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    // Use page_allocator for these tests since the run() function creates its own Io instance
    const allocator = std.heap.page_allocator;
    const result = try run(allocator, &.{ "ls", "/nonexistent_dir_xyz_42" }, .{});
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.exit_code.? != 0);
    try std.testing.expect(result.stderr.len > 0);
}

test "run with cwd" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    // Test that cwd option works - run pwd in /tmp directory
    const allocator = std.heap.page_allocator;
    const result = try run(allocator, &.{"pwd"}, .{ .cwd = "/tmp" });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(result.stdout.len > 0);
    // /tmp may resolve to /private/tmp on macOS
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "tmp") != null);
}

test "RunResult deinit frees buffers" {
    const allocator = std.testing.allocator;
    const stdout = try allocator.dupe(u8, "output");
    const stderr = try allocator.dupe(u8, "error");
    const result = RunResult{
        .stdout = stdout,
        .stderr = stderr,
        .success = true,
        .exit_code = 0,
        .owns_buffers = true,
    };
    result.deinit(allocator);
}

test "RunResult deinit with empty buffers" {
    const allocator = std.testing.allocator;
    const result = RunResult{
        .stdout = "",
        .stderr = "",
        .success = true,
        .exit_code = 0,
        .owns_buffers = false, // Empty string literals, not owned
    };
    result.deinit(allocator); // should not crash or attempt to free ""
}
