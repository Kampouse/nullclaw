//! Memory snapshot — export/import core memories as JSON.
//!
//! Mirrors ZeroClaw's snapshot module:
//!   - export_snapshot: dumps all Memory entries to a JSON file
//!   - hydrate_from_snapshot: restores entries from JSON
//!   - should_hydrate: checks if memory is empty but snapshot exists

const std = @import("std");
const io = std.Options.debug_io;
const build_options = @import("build_options");
const root = @import("../root.zig");
const json_util = @import("../../json_util.zig");
const Memory = root.Memory;
const MemoryEntry = root.MemoryEntry;
const MemoryCategory = root.MemoryCategory;
const sqlite_mod = if (build_options.enable_sqlite) @import("../engines/sqlite.zig") else @import("../engines/sqlite_disabled.zig");

/// Default snapshot filename.
pub const SNAPSHOT_FILENAME = "MEMORY_SNAPSHOT.json";

// ── Export ─────────────────────────────────────────────────────────

/// Export all core memories to a JSON snapshot file.
/// Returns the number of entries exported.
pub fn exportSnapshot(allocator: std.mem.Allocator, mem: Memory, workspace_dir: []const u8) !usize {
    // List all core memories
    const entries = try mem.list(allocator, .core, null);
    defer root.freeEntries(allocator, entries);

    if (entries.len == 0) return 0;

    // Build JSON output
    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer json_buf.deinit(allocator);

    try json_buf.appendSlice(allocator, "[\n");

    for (entries, 0..) |entry, i| {
        if (i > 0) try json_buf.appendSlice(allocator, ",\n");
        try json_buf.appendSlice(allocator, "  {");
        try json_util.appendJsonKeyValue(&json_buf, allocator, "key", entry.key);
        try json_buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&json_buf, allocator, "content", entry.content);
        try json_buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&json_buf, allocator, "category", entry.category.toString());
        try json_buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&json_buf, allocator, "timestamp", entry.timestamp);
        try json_buf.append(allocator, '}');
    }

    try json_buf.appendSlice(allocator, "\n]\n");

    // Write to file (Zig 0.16.0 I/O API)
    const snapshot_path = try std.fs.path.join(allocator, &.{ workspace_dir, SNAPSHOT_FILENAME });
    defer allocator.free(snapshot_path);

    const file = std.Io.Dir.cwd().createFile(io, snapshot_path, .{}) catch |err| {
        std.log.err("Failed to create snapshot file: {}", .{err});
        return error.SnapshotWriteFailed;
    };
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var bw = file.writer(io, &write_buf);
    const w = &bw.interface;

    try w.writeAll(json_buf.items);
    try w.flush();

    return entries.len;
}

// ── Hydrate ───────────────────────────────────────────────────────

/// A parsed snapshot entry.
const SnapshotEntry = struct {
    key: []const u8,
    content: []const u8,
    category: []const u8,
};

/// Restore memory entries from a JSON snapshot file.
/// Returns the number of entries hydrated.
pub fn hydrateFromSnapshot(allocator: std.mem.Allocator, mem: Memory, workspace_dir: []const u8) !usize {
    const snapshot_path = try std.fs.path.join(allocator, &.{ workspace_dir, SNAPSHOT_FILENAME });
    defer allocator.free(snapshot_path);

    const json_bytes = std.Io.Dir.cwd().readFileAlloc(io, snapshot_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        std.log.err("Failed to read snapshot file: {}", .{err});
        return error.SnapshotReadFailed;
    };
    defer allocator.free(json_bytes);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch |err| {
        std.log.err("Failed to parse snapshot JSON: {}", .{err});
        return error.SnapshotParseFailed;
    };
    defer parsed.deinit();

    const root_array = switch (parsed.value) {
        .array => |arr| arr,
        else => return error.SnapshotInvalidFormat,
    };

    var hydrated_count: usize = 0;
    for (root_array.items) |entry_val| {
        const entry_obj = switch (entry_val) {
            .object => |obj| obj,
            else => continue,
        };

        const key = switch (entry_obj.get("key") orelse continue) {
            .string => |s| s,
            else => continue,
        };

        const content = switch (entry_obj.get("content") orelse continue) {
            .string => |s| s,
            else => continue,
        };

        const category_str = switch (entry_obj.get("category") orelse continue) {
            .string => |s| s,
            else => continue,
        };

        const category = MemoryCategory.fromString(category_str);

        mem.store(key, content, category, null) catch |err| {
            std.log.err("Failed to hydrate memory entry {s}: {}", .{key, err});
            continue;
        };

        hydrated_count += 1;
    }

    return hydrated_count;
}

// ── Should hydrate ────────────────────────────────────────────────

/// Check if we should auto-hydrate on startup.
/// Returns true if memory is empty but snapshot file exists.
pub fn shouldHydrate(allocator: std.mem.Allocator, mem: ?Memory, workspace_dir: []const u8) bool {
    // Check if memory is empty
    if (mem) |m| {
        const count = m.count() catch 0;
        if (count > 0) return false;
    }

    // Check if snapshot file exists
    const snapshot_path = std.fs.path.join(allocator, &.{ workspace_dir, SNAPSHOT_FILENAME }) catch return false;
    defer allocator.free(snapshot_path);

    std.Io.Dir.cwd().access(io, snapshot_path, .{}) catch return false;
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────

test "shouldHydrate no memory no snapshot" {
    try std.testing.expect(!shouldHydrate(std.testing.allocator, null, "/nonexistent"));
}

test "shouldHydrate with non-empty memory" {
    if (!build_options.enable_sqlite) return;

    // Create an in-memory SQLite for test
    var mem_impl = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    // Store something
    try mem.store("test", "data", .core, null);

    // Should not hydrate because memory is not empty
    try std.testing.expect(!shouldHydrate(std.testing.allocator, mem, "/nonexistent"));
}

test "exportSnapshot returns zero for empty memory" {
    if (!build_options.enable_sqlite) return;

    var mem_impl = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    const count = try exportSnapshot(std.testing.allocator, mem, "/tmp/yc_snapshot_test_nonexist");
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "SNAPSHOT_FILENAME is correct" {
    try std.testing.expectEqualStrings("MEMORY_SNAPSHOT.json", SNAPSHOT_FILENAME);
}

// ── R3 Tests ──────────────────────────────────────────────────────

test "R3: snapshot export then import roundtrip preserves all entries" {
    if (!build_options.enable_sqlite) return;

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_dir = try std.testing.allocator.dupe(u8, ".");
    defer allocator.free(workspace_dir);

    // Source memory: populate with entries
    var src_impl = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer src_impl.deinit();
    const src_mem = src_impl.memory();

    try src_mem.store("pref_lang", "Zig is the best", .core, null);
    try src_mem.store("pref_editor", "NeoVim forever", .core, null);
    try src_mem.store("user_name", "Igor", .core, null);

    // Export
    const exported = try exportSnapshot(allocator, src_mem, workspace_dir);
    try std.testing.expectEqual(@as(usize, 3), exported);

    // Destination memory: empty, then hydrate
    var dst_impl = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer dst_impl.deinit();
    const dst_mem = dst_impl.memory();

    const hydrated = try hydrateFromSnapshot(allocator, dst_mem, workspace_dir);
    try std.testing.expectEqual(@as(usize, 3), hydrated);

    // Verify all entries are present
    const count = try dst_mem.count();
    try std.testing.expectEqual(@as(usize, 3), count);

    // Verify specific entries
    const e1 = try dst_mem.get(allocator, "pref_lang");
    try std.testing.expect(e1 != null);
    defer e1.?.deinit(allocator);
    try std.testing.expectEqualStrings("Zig is the best", e1.?.content);

    const e2 = try dst_mem.get(allocator, "pref_editor");
    try std.testing.expect(e2 != null);
    defer e2.?.deinit(allocator);
    try std.testing.expectEqualStrings("NeoVim forever", e2.?.content);

    const e3 = try dst_mem.get(allocator, "user_name");
    try std.testing.expect(e3 != null);
    defer e3.?.deinit(allocator);
    try std.testing.expectEqualStrings("Igor", e3.?.content);
}

test "R3: shouldHydrate returns true when memory is empty and snapshot exists" {
    if (!build_options.enable_sqlite) return;

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const snap_file = try tmp.dir.createFile(std.Options.debug_io, SNAPSHOT_FILENAME, .{});
    snap_file.close(std.Options.debug_io);

    const workspace_dir = try std.testing.allocator.dupe(u8, ".");
    defer allocator.free(workspace_dir);

    var mem_impl = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    try std.testing.expect(shouldHydrate(allocator, mem, workspace_dir));
}

test "R3: hydrateFromSnapshot with no file returns 0" {
    if (!build_options.enable_sqlite) return;

    const allocator = std.testing.allocator;

    var mem_impl = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    const hydrated = try hydrateFromSnapshot(allocator, mem, "/nonexistent_dir_xyz");
    try std.testing.expectEqual(@as(usize, 0), hydrated);
}
