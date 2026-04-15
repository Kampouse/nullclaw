//! JSONL logger for eval results.
//!
//! Persists `EvalResult` values to a newline-delimited JSON file and provides
//! a loader to reconstruct them.  Each line is a single JSON object containing
//! the iteration, timestamp, config hash (hex), aggregated metrics, and the
//! raw config JSON string.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fmt = std.fmt;

const io = std.Options.debug_io;
const types = @import("types.zig");

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Append one `EvalResult` as a JSON line to `file_path`.
/// The file is created (with parent directories) if it does not yet exist.
pub fn appendResult(allocator: Allocator, file_path: []const u8, result: *const types.EvalResult) !void {
    try ensureParentDir(file_path);

    const file = try std.Io.Dir.cwd().createFile(io, file_path, .{ .truncate = false, .read = true });
    defer file.close(io);

    const stat = try file.stat(io);
    const size = stat.size;
    try file.seekTo(io, size);

    // Ensure the file ends with a newline so our JSONL stays well-formed.
    if (size > 0) {
        try file.seekTo(io, size - 1);
        var last_byte: [1]u8 = undefined;
        var read_buf: [1]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        const n = reader.interface.readSliceShort(&last_byte) catch |err| switch (err) {
            error.EndOfStream => return error.ReadFailed,
            else => return err,
        };
        if (n == 1 and last_byte[0] != '\n') {
            try file.seekTo(io, size);
            try file.writeStreamingAll(io, "\n");
        } else {
            try file.seekTo(io, size);
        }
    }

    const line = try formatResultJson(allocator, result);
    defer allocator.free(line);

    try file.writeStreamingAll(io, line);
    try file.writeStreamingAll(io, "\n");
}

/// Read all JSONL lines from `file_path` and parse them into `EvalResult`
/// values.  `query_metrics` is always set to an empty slice for loaded
/// results — only the aggregated metrics matter for the proposer.
pub fn loadResults(allocator: Allocator, file_path: []const u8) ![]types.EvalResult {
    const file = std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return &[_]types.EvalResult{},
        else => return err,
    };
    defer file.close(io);

    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const content = try reader.interface.readAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);

    // Count non-empty lines.
    var line_count: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len > 0) line_count += 1;
    }

    if (line_count == 0) return &[_]types.EvalResult{};

    const results = try allocator.alloc(types.EvalResult, line_count);
    errdefer allocator.free(results);

    it = std.mem.splitScalar(u8, content, '\n');
    var idx: usize = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        results[idx] = try parseResultJson(allocator, line);
        idx += 1;
    }

    return results[0..idx];
}

/// Compute a SHA-256 hash of `config_json` and return the 32-byte digest.
pub fn computeConfigHash(allocator: Allocator, config_json: []const u8) [32]u8 {
    _ = allocator;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(config_json, &digest, .{});
    return digest;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Ensure the parent directory of `path` exists.
fn ensureParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    std.Io.Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Return the current wall-clock time as a Unix timestamp (seconds).
pub fn timestamp() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return tv.sec;
}

/// Convert a 32-byte hash to a 64-char lowercase hex string.
fn hashToHex(hash: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(hash, .lower);
}

/// Format an `EvalResult` as a single JSON line.
fn formatResultJson(allocator: Allocator, result: *const types.EvalResult) ![]u8 {
    const hex = hashToHex(result.config_hash);
    const m = result.metrics;

    // Escape config_json for safe embedding inside a JSON string.
    // We need to handle at least: backslash, double-quote, newline, tab.
    const escaped = try escapeJsonString(allocator, result.config_json);
    defer allocator.free(escaped);

    return std.fmt.allocPrint(allocator,
        \{"iteration":{d},"timestamp":{d},"config_hash":"{s}","metrics":{"mean_recall_at_1":{d},"mean_recall_at_3":{d},"mean_recall_at_k":{d},"mean_precision_at_k":{d},"mean_mrr":{d},"mean_ndcg":{d},"mean_latency_us":{d},"median_latency_us":{d},"total_queries":{d},"k":{d}},"config_json":"{s}"}},
        .{
            result.iteration,
            result.timestamp,
            hex,
            m.mean_recall_at_1,
            m.mean_recall_at_3,
            m.mean_recall_at_k,
            m.mean_precision_at_k,
            m.mean_mrr,
            m.mean_ndcg,
            m.mean_latency_us,
            m.median_latency_us,
            m.total_queries,
            m.k,
            escaped,
        },
    );
}

/// Minimal JSON string escaping: handles `\`, `"`, `\n`, `\r`, `\t`, and
/// control characters below 0x20.
fn escapeJsonString(allocator: Allocator, input: []const u8) ![]u8 {
    // Worst case: every byte becomes 6 bytes (\uXXXX).
    var buf = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len * 2);
    errdefer buf.deinit(allocator);

    for (input) |ch| {
        switch (ch) {
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) {
                    const hex_byte = std.fmt.bytesToHex([_]u8{ch}, .lower);
                    try buf.appendSlice(allocator, "\\u00");
                    try buf.appendSlice(allocator, &hex_byte);
                } else {
                    try buf.append(allocator, ch);
                }
            },
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// Parse a single JSON line back into an `EvalResult`.
fn parseResultJson(allocator: Allocator, line: []const u8) !types.EvalResult {
    var result: types.EvalResult = undefined;
    result.query_metrics = &[_]types.QueryMetrics{};

    // Use std.json to parse the top-level object.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, line, .{}) catch |err| {
        return err;
    };
    const obj = parsed.object;

    // iteration
    result.iteration = if (obj.get("iteration")) |v| v.integer else 0;

    // timestamp
    result.timestamp = if (obj.get("timestamp")) |v| v.integer else 0;

    // config_hash — hex string to [32]u8
    if (obj.get("config_hash")) |v| {
        const hex_str = v.string;
        if (hex_str.len != 64) return error.InvalidConfigHash;
        const bytes = std.fmt.hexToBytes([_]u8{0} ** 32, hex_str) catch return error.InvalidConfigHash;
        result.config_hash = bytes;
    } else {
        result.config_hash = [_]u8{0} ** 32;
    }

    // metrics
    if (obj.get("metrics")) |v| {
        const m = v.object;
        result.metrics = .{
            .mean_recall_at_1 = getFloat(m, "mean_recall_at_1"),
            .mean_recall_at_3 = getFloat(m, "mean_recall_at_3"),
            .mean_recall_at_k = getFloat(m, "mean_recall_at_k"),
            .mean_precision_at_k = getFloat(m, "mean_precision_at_k"),
            .mean_mrr = getFloat(m, "mean_mrr"),
            .mean_ndcg = getFloat(m, "mean_ndcg"),
            .mean_latency_us = @intCast(getInt(m, "mean_latency_us")),
            .median_latency_us = @intCast(getInt(m, "median_latency_us")),
            .total_queries = @intCast(getInt(m, "total_queries")),
            .k = @intCast(getInt(m, "k")),
        };
    } else {
        result.metrics = std.mem.zeroInit(types.EvalMetrics, .{});
    }

    // config_json — unescape the JSON string value
    if (obj.get("config_json")) |v| {
        const raw = v.string;
        result.config_json = try unescapeJsonString(allocator, raw);
    } else {
        result.config_json = "{}";
    }

    return result;
}

/// Extract a float field from a JSON object, defaulting to 0.0.
fn getFloat(obj: *const std.json.ObjectMap, key: []const u8) f64 {
    if (obj.get(key)) |v| {
        return v.float;
    }
    return 0.0;
}

/// Extract an integer field from a JSON object, defaulting to 0.
fn getInt(obj: *const std.json.ObjectMap, key: []const u8) i64 {
    if (obj.get(key)) |v| {
        return v.integer;
    }
    return 0;
}

/// Unescape a JSON string value (handles \\, \", \n, \r, \t, \uXXXX).
fn unescapeJsonString(allocator: Allocator, input: []const u8) ![]u8 {
    var buf = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len);
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\\' and i + 1 < input.len) {
            i += 1;
            switch (input[i]) {
                '\\' => try buf.append(allocator, '\\'),
                '"' => try buf.append(allocator, '"'),
                'n' => try buf.append(allocator, '\n'),
                'r' => try buf.append(allocator, '\r'),
                't' => try buf.append(allocator, '\t'),
                'u' => {
                    if (i + 4 >= input.len) {
                        try buf.append(allocator, '\\');
                        try buf.append(allocator, 'u');
                        continue;
                    }
                    const hex_str = input[i + 1 .. i + 5];
                    const code_point = std.fmt.parseInt(u16, hex_str, 16) catch {
                        try buf.appendSlice(allocator, "\\u");
                        i += 4;
                        continue;
                    };
                    if (code_point < 0x80) {
                        try buf.append(allocator, @intCast(code_point));
                    } else if (code_point < 0x800) {
                        try buf.append(allocator, @intCast(0xC0 | (code_point >> 6)));
                        try buf.append(allocator, @intCast(0x80 | (code_point & 0x3F)));
                    } else {
                        try buf.append(allocator, @intCast(0xE0 | (code_point >> 12)));
                        try buf.append(allocator, @intCast(0x80 | ((code_point >> 6) & 0x3F)));
                        try buf.append(allocator, @intCast(0x80 | (code_point & 0x3F)));
                    }
                    i += 4;
                },
                else => {
                    try buf.append(allocator, '\\');
                    try buf.append(allocator, input[i]);
                },
            }
        } else {
            try buf.append(allocator, input[i]);
        }
    }

    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "computeConfigHash returns 32 bytes" {
    const hash = computeConfigHash(testing.allocator, "{\"k\": 10}");
    try testing.expectEqual(@as(usize, 32), hash.len);
    // Deterministic: same input → same output.
    const hash2 = computeConfigHash(testing.allocator, "{\"k\": 10}");
    try testing.expectEqualSlices(u8, &hash, &hash2);
    // Different input → different output.
    const hash3 = computeConfigHash(testing.allocator, "{\"k\": 11}");
    try testing.expect(hash[0] != hash3[0] or hash[31] != hash3[31]);
}

test "escapeJsonString round-trips" {
    const input = "hello \"world\"\n\tback\\slash";
    const escaped = try escapeJsonString(testing.allocator, input);
    defer testing.allocator.free(escaped);
    const unescaped = try unescapeJsonString(testing.allocator, escaped);
    defer testing.allocator.free(unescaped);
    try testing.expectEqualStrings(input, unescaped);
}

test "appendResult and loadResults round-trip" {
    const tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_name = "eval_results.jsonl";

    var result = types.EvalResult{
        .config_hash = computeConfigHash(testing.allocator, "{\"k\":6}"),
        .config_json = "{\"k\": 6, \"name\": \"test\"}",
        .metrics = .{
            .mean_recall_at_1 = 0.45,
            .mean_recall_at_3 = 0.62,
            .mean_recall_at_k = 0.75,
            .mean_precision_at_k = 0.60,
            .mean_mrr = 0.65,
            .mean_ndcg = 0.70,
            .mean_latency_us = 1200,
            .median_latency_us = 1100,
            .total_queries = 20,
            .k = 6,
        },
        .query_metrics = &.{},
        .timestamp = 1744737600,
        .iteration = 0,
    };

    // Write via appendResult using the tmp dir path.
    const abs_path = try tmp.dir.realPathAlloc(testing.allocator, file_name);
    defer testing.allocator.free(abs_path);

    try appendResult(testing.allocator, abs_path, &result);

    // Read back.
    const loaded = try loadResults(testing.allocator, abs_path);
    defer {
        for (loaded) |*r| {
            if (r.config_json.len > 0) testing.allocator.free(r.config_json);
        }
        testing.allocator.free(loaded);
    }

    try testing.expectEqual(@as(usize, 1), loaded.len);
    try testing.expectEqual(result.iteration, loaded[0].iteration);
    try testing.expectEqual(result.timestamp, loaded[0].timestamp);
    try testing.expectEqualSlices(u8, &result.config_hash, &loaded[0].config_hash);
    try testing.expectEqualStrings(result.config_json, loaded[0].config_json);
    try testing.expectEqual(result.metrics.total_queries, loaded[0].metrics.total_queries);
    try testing.expectEqual(result.metrics.k, loaded[0].metrics.k);
    try testing.expectApproxEqAbs(result.metrics.mean_mrr, loaded[0].metrics.mean_mrr, 0.001);
}

test "loadResults returns empty slice for missing file" {
    const loaded = try loadResults(testing.allocator, "/nonexistent/eval.jsonl");
    defer testing.allocator.free(loaded);
    try testing.expectEqual(@as(usize, 0), loaded.len);
}

test "loadResults skips blank lines" {
    const tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_name = "blank.jsonl";
    const abs_path = try tmp.dir.realPathAlloc(testing.allocator, file_name);
    defer testing.allocator.free(abs_path);

    // Write a file with blank lines.
    const f = try tmp.dir.createFile(io, file_name, .{});
    try f.writeStreamingAll(io, "\n\n");
    f.close(io);

    const loaded = try loadResults(testing.allocator, abs_path);
    defer testing.allocator.free(loaded);
    try testing.expectEqual(@as(usize, 0), loaded.len);
}
