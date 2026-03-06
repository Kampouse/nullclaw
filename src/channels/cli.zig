const std = @import("std");
const platform = @import("../platform.zig");
const root = @import("root.zig");

/// CLI channel — reads from stdin, writes to stdout.
/// Simplest channel implementation; used for local interactive testing.
pub const CliChannel = struct {
    allocator: std.mem.Allocator,
    running: bool,

    pub fn init(allocator: std.mem.Allocator) CliChannel {
        return .{ .allocator = allocator, .running = false };
    }

    pub fn channelName(_: *CliChannel) []const u8 {
        return "cli";
    }

    pub fn sendMessage(_: *CliChannel, _: []const u8, message: []const u8) !void {
        var out_buf: [4096]u8 = undefined;
        var bw = std.Io.File.stdout().writer(std.Options.debug_io, &out_buf);
        const w = &bw.interface;
        try w.print("{s}\n", .{message});
        try w.flush();
    }

    pub fn readLine(_: *CliChannel, buf: []u8) !?[]const u8 {
        const stdin = std.Io.File.stdin();
        var pos: usize = 0;
        while (pos < buf.len) {
            const n = stdin.read(buf[pos .. pos + 1]) catch return null;
            if (n == 0) return null; // EOF
            if (buf[pos] == '\n') break;
            pos += 1;
        }
        return buf[0..pos];
    }

    pub fn isQuitCommand(line: []const u8) bool {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        return std.mem.eql(u8, trimmed, "exit") or
            std.mem.eql(u8, trimmed, "quit") or
            std.mem.eql(u8, trimmed, ":q") or
            std.mem.eql(u8, trimmed, "/quit") or
            std.mem.eql(u8, trimmed, "/exit");
    }

    pub fn healthCheck(_: *CliChannel) bool {
        return true; // CLI is always available
    }

    // ── Channel vtable ──────────────────────────────────────────────

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        const self: *CliChannel = @ptrCast(@alignCast(ptr));
        self.running = true;
    }

    fn vtableStop(ptr: *anyopaque) void {
        const self: *CliChannel = @ptrCast(@alignCast(ptr));
        self.running = false;
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8, _: []const []const u8) anyerror!void {
        const self: *CliChannel = @ptrCast(@alignCast(ptr));
        return self.sendMessage(target, message);
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        const self: *CliChannel = @ptrCast(@alignCast(ptr));
        return self.channelName();
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *CliChannel = @ptrCast(@alignCast(ptr));
        return self.healthCheck();
    }

    pub const vtable = root.Channel.VTable{
        .start = &vtableStart,
        .stop = &vtableStop,
        .send = &vtableSend,
        .name = &vtableName,
        .healthCheck = &vtableHealthCheck,
    };

    pub fn channel(self: *CliChannel) root.Channel {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// History — persistent REPL command history (~/.nullclaw_history)
// ═══════════════════════════════════════════════════════════════════════════

const MAX_HISTORY_LINES: usize = 500;

/// Load command history from a file (one command per line).
/// Returns up to MAX_HISTORY_LINES most recent entries.
/// If the file does not exist, returns an empty slice.
/// Caller owns the returned slice and all strings within it.
pub fn loadHistory(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    _ = path;
    // TODO: Zig 0.16.0 - file.read() API changed, stubbed for now
    return try allocator.alloc([]const u8, 0);
}

/// Free history entries returned by loadHistory.
pub fn freeHistory(allocator: std.mem.Allocator, history: [][]const u8) void {
    for (history) |entry| allocator.free(entry);
    allocator.free(history);
}

/// Save command history to a file (one command per line).
/// Writes at most MAX_HISTORY_LINES entries.
pub fn saveHistory(history: []const []const u8, path: []const u8) !void {
    _ = history;
    _ = path;
    // TODO: Zig 0.16.0 - createFile/writeAll APIs changed, stubbed for now
}

/// Resolve the default history file path (~/.nullclaw_history).
/// Caller owns the returned string.
pub fn defaultHistoryPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = try platform.getHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".nullclaw_history" });
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "cli quit commands" {
    try std.testing.expect(CliChannel.isQuitCommand("exit"));
    try std.testing.expect(CliChannel.isQuitCommand("quit"));
    try std.testing.expect(CliChannel.isQuitCommand(":q"));
    try std.testing.expect(CliChannel.isQuitCommand("/quit"));
    try std.testing.expect(CliChannel.isQuitCommand("/exit"));
    try std.testing.expect(CliChannel.isQuitCommand("  exit  "));
    try std.testing.expect(CliChannel.isQuitCommand("  :q  "));
    try std.testing.expect(!CliChannel.isQuitCommand("hello"));
    try std.testing.expect(!CliChannel.isQuitCommand(""));
}

test "loadHistory reads file lines" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try std.testing.allocator.dupe(u8, ".");
    defer allocator.free(base);
    const tmp_path = try std.fs.path.join(allocator, &.{ base, "history_test" });
    defer allocator.free(tmp_path);

    // Write a temporary history file
    {
        const f = try std.Io.Dir.cwd().createFile(std.Options.debug_io, tmp_path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "hello world\nhow are you\ngoodbye\n");
    }

    const history = try loadHistory(allocator, tmp_path);
    defer freeHistory(allocator, history);

    try std.testing.expectEqual(@as(usize, 3), history.len);
    try std.testing.expectEqualStrings("hello world", history[0]);
    try std.testing.expectEqualStrings("how are you", history[1]);
    try std.testing.expectEqualStrings("goodbye", history[2]);
}

test "loadHistory returns empty for missing file" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try std.testing.allocator.dupe(u8, ".");
    defer allocator.free(base);
    const tmp_path = try std.fs.path.join(allocator, &.{ base, "nonexistent_history_file" });
    defer allocator.free(tmp_path);

    const history = try loadHistory(allocator, tmp_path);
    defer freeHistory(allocator, history);
    try std.testing.expectEqual(@as(usize, 0), history.len);
}

test "saveHistory writes file" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try std.testing.allocator.dupe(u8, ".");
    defer allocator.free(base);
    const tmp_path = try std.fs.path.join(allocator, &.{ base, "save_history_test" });
    defer allocator.free(tmp_path);

    const entries = [_][]const u8{ "first", "second", "third" };
    try saveHistory(&entries, tmp_path);

    // Read back and verify
    const loaded = try loadHistory(allocator, tmp_path);
    defer freeHistory(allocator, loaded);

    try std.testing.expectEqual(@as(usize, 3), loaded.len);
    try std.testing.expectEqualStrings("first", loaded[0]);
    try std.testing.expectEqualStrings("second", loaded[1]);
    try std.testing.expectEqualStrings("third", loaded[2]);
}

test "saveHistory and loadHistory roundtrip" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try std.testing.allocator.dupe(u8, ".");
    defer allocator.free(base);
    const tmp_path = try std.fs.path.join(allocator, &.{ base, "roundtrip_history_test" });
    defer allocator.free(tmp_path);

    // Save
    const entries = [_][]const u8{ "alpha", "beta" };
    try saveHistory(&entries, tmp_path);

    // Load
    const loaded = try loadHistory(allocator, tmp_path);
    defer freeHistory(allocator, loaded);

    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqualStrings("alpha", loaded[0]);
    try std.testing.expectEqualStrings("beta", loaded[1]);
}

test "loadHistory trims whitespace from entries" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try std.testing.allocator.dupe(u8, ".");
    defer allocator.free(base);
    const tmp_path = try std.fs.path.join(allocator, &.{ base, "trim_history_test" });
    defer allocator.free(tmp_path);

    {
        const f = try std.Io.Dir.cwd().createFile(std.Options.debug_io, tmp_path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "  hello  \n\t world \t\nfoo\r\n");
    }

    const history = try loadHistory(allocator, tmp_path);
    defer freeHistory(allocator, history);

    try std.testing.expectEqual(@as(usize, 3), history.len);
    try std.testing.expectEqualStrings("hello", history[0]);
    try std.testing.expectEqualStrings("world", history[1]);
    try std.testing.expectEqualStrings("foo", history[2]);
}

test "loadHistory skips blank lines" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try std.testing.allocator.dupe(u8, ".");
    defer allocator.free(base);
    const tmp_path = try std.fs.path.join(allocator, &.{ base, "blank_history_test" });
    defer allocator.free(tmp_path);

    {
        const f = try std.Io.Dir.cwd().createFile(std.Options.debug_io, tmp_path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "first\n\n   \n\nsecond\n  \nthird\n");
    }

    const history = try loadHistory(allocator, tmp_path);
    defer freeHistory(allocator, history);

    try std.testing.expectEqual(@as(usize, 3), history.len);
    try std.testing.expectEqualStrings("first", history[0]);
    try std.testing.expectEqualStrings("second", history[1]);
    try std.testing.expectEqualStrings("third", history[2]);
}

test "loadHistory enforces max entries limit" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try std.testing.allocator.dupe(u8, ".");
    defer allocator.free(base);
    const tmp_path = try std.fs.path.join(allocator, &.{ base, "max_history_test" });
    defer allocator.free(tmp_path);

    {
        const f = try std.Io.Dir.cwd().createFile(std.Options.debug_io, tmp_path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        // Write more than MAX_HISTORY_LINES (500) entries
        for (0..600) |i| {
            var buf: [32]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "cmd-{d}\n", .{i}) catch unreachable;
            f.writeStreamingAll(std.Options.debug_io, line) catch break;
        }
    }

    const history = try loadHistory(allocator, tmp_path);
    defer freeHistory(allocator, history);

    // Should be capped at MAX_HISTORY_LINES (500)
    try std.testing.expectEqual(@as(usize, MAX_HISTORY_LINES), history.len);
    // First entry should be cmd-100 (600 - 500 = 100 oldest dropped)
    try std.testing.expectEqualStrings("cmd-100", history[0]);
    // Last entry should be cmd-599
    try std.testing.expectEqualStrings("cmd-599", history[history.len - 1]);
}

test "MAX_HISTORY_LINES is 500" {
    try std.testing.expectEqual(@as(usize, 500), MAX_HISTORY_LINES);
}
