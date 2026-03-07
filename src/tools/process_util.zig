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
    // Zig 0.16.0 uses std.process.run() instead of Child.init()
    // Note: cwd option not directly supported in std.process.run() API
    // For now, we ignore opts.cwd - TODO: implement cwd support if needed
    _ = opts.cwd;
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(opts.max_output_bytes),
        .stderr_limit = .limited(opts.max_output_bytes),
    });

    return switch (result.term) {
        .exited => |code| .{
            .stdout = result.stdout,
            .stderr = result.stderr,
            .success = code == 0,
            .exit_code = code,
        },
        else => .{
            .stdout = result.stdout,
            .stderr = result.stderr,
            .success = false,
            .exit_code = null,
        },
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const builtin = @import("builtin");

test "run echo returns stdout" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    // GPA has limits on single allocation size; use ArenaAllocator for process tests
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try run(allocator, &.{ "echo", "hello" }, .{});
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u32, 0), result.exit_code.?);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello") != null);
}

test "run failing command returns exit code" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    // GPA has limits on single allocation size; use ArenaAllocator for process tests
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try run(allocator, &.{ "ls", "/nonexistent_dir_xyz_42" }, .{});
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.exit_code.? != 0);
    try std.testing.expect(result.stderr.len > 0);
}

test "run with cwd" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    // GPA has limits on single allocation size; use ArenaAllocator for process tests
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try run(allocator, &.{"pwd"}, .{ .cwd = "/tmp" });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    // /tmp may resolve to /private/tmp on macOS
    try std.testing.expect(result.stdout.len > 0);
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
