//! Child process compatibility layer for Zig 0.16.0
//!
//! Provides backward-compatible API for spawning child processes.
//! Uses the new std.process.spawn/run APIs internally.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Result from running a child process
pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    pub fn deinit(self: *RunResult, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Run a child process and collect output (Zig 0.16.0 compatible)
pub fn run(
    allocator: Allocator,
    io: Io,
    argv: []const []const u8,
    max_output_bytes: usize,
) !RunResult {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
    });

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}

/// Run a child process with custom working directory
pub fn runWithCwd(
    allocator: Allocator,
    io: Io,
    argv: []const []const u8,
    cwd: []const u8,
    max_output_bytes: usize,
) !RunResult {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
    });

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}

/// Run a child process with custom environment
pub fn runWithEnv(
    allocator: Allocator,
    io: Io,
    argv: []const []const u8,
    env_map: *const std.process.Environ.Map,
    max_output_bytes: usize,
) !RunResult {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = env_map,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
    });

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}
