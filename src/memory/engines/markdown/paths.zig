//! Path generation utilities for Markdown memory engine.
//!
//! Provides functions to generate file paths for MEMORY.md, daily logs,
//! and the memory directory.

const std = @import("std");

/// Generate path to MEMORY.md (core long-term memory)
pub fn corePath(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{workspace_dir});
}

/// Generate path to any file in workspace root
pub fn rootPath(allocator: std.mem.Allocator, workspace_dir: []const u8, filename: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ workspace_dir, filename });
}

/// Generate path to memory/ subdirectory
pub fn memoryDir(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/memory", .{workspace_dir});
}

/// Generate path to daily log file (YYYY-MM-DD.md)
pub fn dailyPath(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]u8 {
    const ts = 0;
    const epoch: u64 = @intCast(ts);
    const es = std.time.epoch.EpochSeconds{ .secs = epoch };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();

    return std.fmt.allocPrint(allocator, "{s}/memory/{d:0>4}-{d:0>2}-{d:0>2}.md", .{
        workspace_dir,
        day.year,
        @intFromEnum(md.month),
        md.day_index + 1,
    });
}

// ── Tests ────────────────────────────────────────────────────────────

test "corePath generates MEMORY.md path" {
    const path = try corePath(std.testing.allocator, "/workspace");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/workspace/MEMORY.md", path);
}

test "rootPath generates file path in workspace" {
    const path = try rootPath(std.testing.allocator, "/workspace", "config.json");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/workspace/config.json", path);
}

test "memoryDir generates memory subdirectory path" {
    const path = try memoryDir(std.testing.allocator, "/workspace");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/workspace/memory", path);
}

test "dailyPath generates dated log file path" {
    const path = try dailyPath(std.testing.allocator, "/workspace");
    defer std.testing.allocator.free(path);
    // Path should start with workspace and contain date format
    try std.testing.expect(std.mem.startsWith(u8, path, "/workspace/memory/"));
    try std.testing.expect(std.mem.endsWith(u8, path, ".md"));
}
