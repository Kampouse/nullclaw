//! JSON benchmark loader for the meta-harness evaluation system.
//!
//! Reads a benchmark JSON file and produces a `types.Benchmark` value.
//! Optional fields (`weights`, `rationale`) default to `null` / `""` when
//! absent or malformed.
//!
//! NOTE: `Benchmark.deinit` does *not* free `entry.query` or
//! `entry.rationale` (see types.zig for rationale).  This loader duplicates
//! those strings, so callers using a general-purpose allocator should either
//! free them manually or back the allocator with an arena.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");

const io = std.Options.debug_io;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Load a benchmark from the JSON file at `file_path`.
pub fn loadBenchmark(allocator: Allocator, file_path: []const u8) !types.Benchmark {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        return err;
    };
    defer allocator.free(raw);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        return error.InvalidBenchmark;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidBenchmark;

    // -- description (required) --
    const desc_val = root.object.get("description") orelse return error.InvalidBenchmark;
    if (desc_val != .string) return error.InvalidBenchmark;
    const description = try allocator.dupe(u8, desc_val.string);
    errdefer allocator.free(description);

    // -- created_at (required) --
    const cat_val = root.object.get("created_at") orelse return error.InvalidBenchmark;
    if (cat_val != .string) return error.InvalidBenchmark;
    const created_at = try allocator.dupe(u8, cat_val.string);
    errdefer allocator.free(created_at);

    // -- entries (required array) --
    const entries_val = root.object.get("entries") orelse return error.InvalidBenchmark;
    if (entries_val != .array) return error.InvalidBenchmark;

    var entries = std.ArrayListUnmanaged(types.BenchmarkEntry).empty;
    errdefer {
        for (entries.items) |*e| freeEntry(allocator, e);
        entries.deinit(allocator);
    }

    for (entries_val.array.items) |item| {
        if (item != .object) return error.InvalidBenchmark;

        const entry = parseEntry(allocator, item) catch |err| {
            return err;
        };
        try entries.append(allocator, entry);
    }

    return .{
        .entries = try entries.toOwnedSlice(allocator),
        .description = description,
        .created_at = created_at,
    };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Parse a single JSON object into a `BenchmarkEntry`.
fn parseEntry(allocator: Allocator, obj: std.json.Value) !types.BenchmarkEntry {
    std.debug.assert(obj == .object);

    // -- query (required) --
    const query_val = obj.object.get("query") orelse return error.InvalidBenchmark;
    if (query_val != .string) return error.InvalidBenchmark;
    const query = try allocator.dupe(u8, query_val.string);
    errdefer allocator.free(query);

    // -- expected_ids (required array of strings) --
    const ids_val = obj.object.get("expected_ids") orelse return error.InvalidBenchmark;
    if (ids_val != .array) return error.InvalidBenchmark;

    var expected_ids = std.ArrayListUnmanaged([]const u8).empty;
    errdefer {
        for (expected_ids.items) |id| allocator.free(id);
        expected_ids.deinit(allocator);
    }

    for (ids_val.array.items) |id_item| {
        if (id_item != .string) return error.InvalidBenchmark;
        try expected_ids.append(allocator, try allocator.dupe(u8, id_item.string));
    }

    // -- weights (optional array of numbers) --
    var weights: ?[]f64 = null;
    if (obj.object.get("weights")) |w_val| {
        if (w_val == .array) {
            var w_list = std.ArrayListUnmanaged(f64).empty;
            errdefer w_list.deinit(allocator);

            for (w_val.array.items) |w_item| {
                const w: f64 = switch (w_item) {
                    .float => |f| f,
                    .integer => |n| @floatFromInt(n),
                    else => return error.InvalidBenchmark,
                };
                try w_list.append(allocator, w);
            }
            weights = try w_list.toOwnedSlice(allocator);
        }
    }

    // -- rationale (optional string, default "") --
    const rationale = if (obj.object.get("rationale")) |r_val| blk: {
        if (r_val == .string) {
            break :blk try allocator.dupe(u8, r_val.string);
        }
        break :blk "";
    } else "";

    return .{
        .query = query,
        .expected_ids = try expected_ids.toOwnedSlice(allocator),
        .weights = weights,
        .rationale = rationale,
    };
}

/// Free every heap allocation inside an entry (including query / rationale
/// which Benchmark.deinit skips).
fn freeEntry(allocator: Allocator, entry: *const types.BenchmarkEntry) void {
    for (entry.expected_ids) |id| allocator.free(id);
    allocator.free(entry.expected_ids);
    if (entry.weights) |w| allocator.free(w);
    allocator.free(entry.query);
    if (entry.rationale.len > 0) allocator.free(entry.rationale);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "loadBenchmark: valid benchmark with all fields" {
    const json =
        \\{
        \\  "description": "NullClaw retrieval benchmark v1",
        \\  "created_at": "2026-04-15T12:00:00Z",
        \\  "entries": [
        \\    {
        \\      "query": "what was the NEAR account name?",
        \\      "expected_ids": ["mem_001", "mem_042"],
        \\      "weights": [1.0, 0.5],
        \\      "rationale": "User frequently asks about NEAR account"
        \\    },
        \\    {
        \\      "query": "help me debug this Zig error",
        \\      "expected_ids": ["mem_015"],
        \\      "rationale": "Zig debugging patterns"
        \\    }
        \\  ]
        \\}
    ;

    const tmp = try testing.allocator.create([json.len]u8);
    defer testing.allocator.destroy(tmp);
    @memcpy(tmp, json);
    const path = try writeTempFile(testing.allocator, tmp);
    defer {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        testing.allocator.free(path);
    }

    var bench = try loadBenchmark(testing.allocator, path);
    defer {
        // Full cleanup (includes query/rationale which Benchmark.deinit skips).
        for (bench.entries) |*e| freeEntry(testing.allocator, e);
        testing.allocator.free(bench.entries);
        testing.allocator.free(bench.description);
        testing.allocator.free(bench.created_at);
    }

    try testing.expectEqual(@as(usize, 2), bench.entries.len);

    try testing.expectEqualStrings("NullClaw retrieval benchmark v1", bench.description);
    try testing.expectEqualStrings("2026-04-15T12:00:00Z", bench.created_at);

    // First entry
    try testing.expectEqualStrings("what was the NEAR account name?", bench.entries[0].query);
    try testing.expectEqual(@as(usize, 2), bench.entries[0].expected_ids.len);
    try testing.expectEqualStrings("mem_001", bench.entries[0].expected_ids[0]);
    try testing.expectEqualStrings("mem_042", bench.entries[0].expected_ids[1]);
    try testing.expect(bench.entries[0].weights != null);
    try testing.expectEqual(@as(f64, 1.0), bench.entries[0].weights.?[0]);
    try testing.expectEqual(@as(f64, 0.5), bench.entries[0].weights.?[1]);
    try testing.expectEqualStrings("User frequently asks about NEAR account", bench.entries[0].rationale);

    // Second entry — no weights field
    try testing.expectEqualStrings("help me debug this Zig error", bench.entries[1].query);
    try testing.expectEqual(@as(usize, 1), bench.entries[1].expected_ids.len);
    try testing.expect(bench.entries[1].weights == null);
    try testing.expectEqualStrings("Zig debugging patterns", bench.entries[1].rationale);
}

test "loadBenchmark: optional fields default gracefully" {
    const json =
        \\{
        \\  "description": "minimal benchmark",
        \\  "created_at": "2026-01-01T00:00:00Z",
        \\  "entries": [
        \\    {
        \\      "query": "test",
        \\      "expected_ids": ["mem_000"]
        \\    }
        \\  ]
        \\}
    ;

    const tmp = try testing.allocator.create([json.len]u8);
    defer testing.allocator.destroy(tmp);
    @memcpy(tmp, json);
    const path = try writeTempFile(testing.allocator, tmp);
    defer {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        testing.allocator.free(path);
    }

    var bench = try loadBenchmark(testing.allocator, path);
    defer {
        for (bench.entries) |*e| freeEntry(testing.allocator, e);
        testing.allocator.free(bench.entries);
        testing.allocator.free(bench.description);
        testing.allocator.free(bench.created_at);
    }

    try testing.expectEqual(@as(usize, 1), bench.entries.len);
    try testing.expectEqualStrings("test", bench.entries[0].query);
    try testing.expect(bench.entries[0].weights == null);
    try testing.expectEqualStrings("", bench.entries[0].rationale);
}

test "loadBenchmark: rejects non-existent file" {
    const result = loadBenchmark(testing.allocator, "/tmp/__nullclaw_nonexistent_benchmark.json");
    try testing.expectError(error.FileNotFound, result);
}

test "loadBenchmark: rejects invalid JSON" {
    const json = "this is not json";
    const tmp = try testing.allocator.create([json.len]u8);
    defer testing.allocator.destroy(tmp);
    @memcpy(tmp, json);
    const path = try writeTempFile(testing.allocator, tmp);
    defer {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        testing.allocator.free(path);
    }

    const result = loadBenchmark(testing.allocator, path);
    try testing.expectError(error.InvalidBenchmark, result);
}

test "loadBenchmark: rejects missing required fields" {
    const json =
        \\{
        \\  "description": "missing entries"
        \\}
    ;

    const tmp = try testing.allocator.create([json.len]u8);
    defer testing.allocator.destroy(tmp);
    @memcpy(tmp, json);
    const path = try writeTempFile(testing.allocator, tmp);
    defer {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        testing.allocator.free(path);
    }

    const result = loadBenchmark(testing.allocator, path);
    try testing.expectError(error.InvalidBenchmark, result);
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Write `content` to a temporary file in cwd and return its path (caller owns).
fn writeTempFile(allocator: Allocator, content: []const u8) ![]const u8 {
    const name = try std.fmt.allocPrint(allocator, "/tmp/nullclaw_bench_test_{}.json", .{
        @as(usize, @intFromPtr(&content)),
    });
    const file = try std.Io.Dir.cwd().createFile(io, name, .{ .truncate = true });
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
    return name;
}
