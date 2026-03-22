//! Compatibility layer for Zig 0.16.0-dev API changes
//! Provides drop-in replacements for deprecated APIs

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Replacement for std.process.argsAlloc
/// In Zig 0.16.0, this was replaced with iterator-based API
pub fn argsAlloc(allocator: Allocator) ![][:0]const u8 {
    var args = std.process.Args.init(.{ .vector = undefined }, allocator) catch {
        // Fallback for non-WASI/Windows
        return error.OutOfMemory;
    };
    defer args.deinit();

    var list = std.ArrayList([:0]const u8).init(allocator);
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit();
    }

    while (args.next()) |arg| {
        const duped = try allocator.dupeZ(u8, arg);
        try list.append(duped);
    }

    return list.toOwnedSlice();
}

/// Replacement for std.process.argsFree
pub fn argsFree(allocator: Allocator, args: [][:0]const u8) void {
    for (args) |arg| {
        allocator.free(arg);
    }
    allocator.free(args);
}

/// Replacement for std.Io.Dir.cwd()
/// Returns the current working directory handle
pub fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

/// Helper to get Io instance for tests
pub fn getTestIo() std.Io {
    return std.testing.io;
}
