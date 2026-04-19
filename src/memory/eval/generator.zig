//! Benchmark generator — produces evaluation benchmarks from memory entries.
//!
//! Takes a slice of memory entries (id, key, content), builds a bag-of-words
//! index, and generates synthetic (query, expected_ids) pairs based on word
//! overlap (Jaccard similarity).  The caller is responsible for fetching
//! entries from the memory store — this module is pure and testable.
//!
//! For production use, the benchmark should be curated by a human or an LLM
//! that can craft realistic queries.  This generator provides a reasonable
//! automated starting point.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.eval_generator);

const types = @import("types.zig");

// ---------------------------------------------------------------------------
// Input entry
// ---------------------------------------------------------------------------

/// Minimal entry representation needed for benchmark generation.
/// The caller maps from `MemoryEntry` to this.
pub const InputEntry = struct {
    id: []const u8,
    key: []const u8,
    content: []const u8,
};

// ---------------------------------------------------------------------------
// Generation options
// ---------------------------------------------------------------------------

pub const GenerateOptions = struct {
    /// Maximum number of benchmark entries to generate.
    max_entries: u32 = 20,

    /// Maximum number of expected_ids per entry.
    max_expected: u32 = 3,

    /// Minimum content length (in bytes) for an entry to be considered.
    min_content_len: u32 = 10,

    /// Random seed for deterministic output.
    seed: u64 = 42,
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Generate a benchmark from a slice of memory entries.
///
/// Builds a bag-of-words index and for each qualifying entry constructs a
/// query from its key, marking entries with overlapping vocabulary as
/// expected hits (sorted by Jaccard similarity).
pub fn generate(
    allocator: Allocator,
    entries: []const InputEntry,
    options: GenerateOptions,
) !types.Benchmark {
    if (entries.len == 0) return emptyBenchmark();

    // Build word sets for each entry.
    const word_sets = try buildWordSets(allocator, entries);
    defer {
        for (word_sets) |*ws| {
            for (ws.items) |w| allocator.free(w);
            ws.deinit(allocator);
        }
        allocator.free(word_sets);
    }

    // Filter by content length and collect valid indices.
    var valid = std.ArrayListUnmanaged(usize){};
    errdefer valid.deinit(allocator);
    for (entries, 0..) |e, i| {
        if (e.content.len >= options.min_content_len and word_sets[i].items.len >= 2) {
            try valid.append(allocator, i);
        }
    }
    defer valid.deinit(allocator);

    if (valid.items.len == 0) return emptyBenchmark();

    // Shuffle for variety.
    var prng = std.Random.DefaultPrng.init(options.seed);
    const rng = prng.random();
    const items = valid.items;
    for (0..items.len) |i| {
        const j = rng.uintLessThan(usize, items.len);
        const tmp = items[i];
        items[i] = items[j];
        items[j] = tmp;
    }

    const limit = @min(options.max_entries, @as(u32, @intCast(items.len)));

    var bench_entries = std.ArrayListUnmanaged(types.BenchmarkEntry){};
    errdefer {
        for (bench_entries.items) |*e| {
            for (e.expected_ids) |id| allocator.free(id);
            allocator.free(e.expected_ids);
        }
        bench_entries.deinit(allocator);
    }

    for (items[0..limit]) |idx| {
        const query_entry = entries[idx];
        const expected = try findSimilar(allocator, entries, word_sets, idx, options.max_expected);

        const q = try allocator.dupe(u8, query_entry.key);
        const rationale = if (expected.len > 1) "auto-generated from word overlap" else "self-match (no similar entries found)";

        try bench_entries.append(allocator, .{
            .query = q,
            .expected_ids = expected,
            .rationale = rationale,
        });
    }

    const ts = try timestampString(allocator);
    const entries_slice = try bench_entries.toOwnedSlice(allocator);
    return .{
        .entries = entries_slice,
        .description = try std.fmt.allocPrint(allocator, "Auto-generated benchmark from {d} memory entries", .{entries.len}),
        .created_at = ts,
    };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn emptyBenchmark() types.Benchmark {
    return .{
        .entries = &.{},
        .description = "empty",
        .created_at = "",
    };
}

/// Build a set of unique lowercase words for each entry.
fn buildWordSets(
    allocator: Allocator,
    entries: []const InputEntry,
) ![]std.ArrayListUnmanaged([]const u8) {
    const sets = try allocator.alloc(std.ArrayListUnmanaged([]const u8), entries.len);
    errdefer allocator.free(sets);

    for (entries, 0..) |entry, i| {
        var set = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (set.items) |w| allocator.free(w);
            set.deinit(allocator);
        }

        var it = std.mem.tokenizeAny(u8, entry.content, " \t\n\r.,;:!?'\"()[]{}/<>@#$%^&*+-=_~`|\\0123456789");
        while (it.next()) |word| {
            if (word.len < 3) continue;
            // Linear dedup — small N, no HashMap overhead.
            var found = false;
            for (set.items) |existing| {
                if (std.mem.eql(u8, existing, word)) {
                    found = true;
                    break;
                }
            }
            if (found) continue;
            const lower = try std.ascii.allocLowerString(allocator, word);
            try set.append(allocator, lower);
        }
        sets[i] = set;
    }
    return sets;
}

/// Find the top-N entries most similar to `target_idx` by Jaccard similarity.
fn findSimilar(
    allocator: Allocator,
    entries: []const InputEntry,
    word_sets: []std.ArrayListUnmanaged([]const u8),
    target_idx: usize,
    max_expected: u32,
) ![][]const u8 {
    const target_words = word_sets[target_idx];

    var scores = std.ArrayListUnmanaged(struct {
        idx: usize,
        score: f64,
    }){};
    errdefer scores.deinit(allocator);

    for (entries, 0..) |_, i| {
        if (i == target_idx) continue;
        const other_words = word_sets[i];
        if (other_words.items.len == 0) continue;

        const jaccard = computeJaccard(target_words.items, other_words.items);
        if (jaccard > 0.0) {
            try scores.append(allocator, .{ .idx = i, .score = jaccard });
        }
    }

    // Sort descending by score (bubble sort for simplicity — small N).
    const items = scores.items;
    for (0..items.len) |outer| {
        for (outer + 1..items.len) |inner| {
            if (items[inner].score > items[outer].score) {
                const tmp = items[outer];
                items[outer] = items[inner];
                items[inner] = tmp;
            }
        }
    }

    const n = @min(max_expected, @as(u32, @intCast(items.len)));
    // result[0] = self, result[1..n+1] = similar entries.
    const result = try allocator.alloc([]const u8, n + 1);
    result[0] = try allocator.dupe(u8, entries[target_idx].id);
    for (items[0..n], 0..) |item, i| {
        result[i + 1] = try allocator.dupe(u8, entries[item.idx].id);
    }

    scores.deinit(allocator);
    return result;
}

fn computeJaccard(a: []const []const u8, b: []const []const u8) f64 {
    var intersection: u32 = 0;
    for (a) |wa| {
        for (b) |wb| {
            if (std.mem.eql(u8, wa, wb)) {
                intersection += 1;
                break;
            }
        }
    }

    const union_size: f64 = @floatFromInt(a.len + b.len - intersection);
    if (union_size == 0.0) return 0.0;
    return @as(f64, @floatFromInt(intersection)) / union_size;
}

fn timestampString(allocator: Allocator) ![]const u8 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(tv.sec) };

    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_secs.getDaySeconds();

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "empty entries returns empty benchmark" {
    const bench = try generate(testing.allocator, &[_]InputEntry{}, .{});
    try testing.expectEqual(@as(usize, 0), bench.entries.len);
    try testing.expectEqualStrings("empty", bench.description);
}

test "generate from overlapping entries" {
    const entries = [_]InputEntry{
        .{ .id = "mem_001", .key = "zig programming", .content = "Zig is a systems programming language with manual memory management and comptime" },
        .{ .id = "mem_002", .key = "rust programming", .content = "Rust is a systems programming language with ownership and borrowing" },
        .{ .id = "mem_003", .key = "python scripting", .content = "Python is a high level scripting language used for data science and automation" },
    };

    const bench = try generate(testing.allocator, &entries, .{
        .max_entries = 10,
        .max_expected = 3,
        .min_content_len = 5,
        .seed = 123,
    });
    defer {
        for (bench.entries) |*e| {
            for (e.expected_ids) |id| testing.allocator.free(id);
            testing.allocator.free(e.expected_ids);
            testing.allocator.free(e.query);
        }
        testing.allocator.free(bench.entries);
        testing.allocator.free(bench.description);
        testing.allocator.free(bench.created_at);
    }

    try testing.expect(bench.entries.len > 0);
    // Each entry should have at least 1 expected_id (itself).
    for (bench.entries) |e| {
        try testing.expect(e.expected_ids.len >= 1);
    }
}

test "computeJaccard identical sets" {
    const a = [_][]const u8{ "hello", "world" };
    const b = [_][]const u8{ "hello", "world" };
    try testing.expectApproxEqAbs(1.0, computeJaccard(&a, &b), 1e-9);
}

test "computeJaccard disjoint sets" {
    const a = [_][]const u8{ "foo", "bar" };
    const b = [_][]const u8{ "baz", "qux" };
    try testing.expectApproxEqAbs(0.0, computeJaccard(&a, &b), 1e-9);
}

test "computeJaccard partial overlap" {
    const a = [_][]const u8{ "alpha", "beta", "gamma" };
    const b = [_][]const u8{ "beta", "gamma", "delta" };
    try testing.expectApproxEqAbs(0.5, computeJaccard(&a, &b), 1e-9);
}

test "computeJaccard empty sets" {
    const a = [_][]const u8{};
    const b = [_][]const u8{"hello"};
    try testing.expectApproxEqAbs(0.0, computeJaccard(&a, &b), 1e-9);
}

test "timestampString returns ISO 8601 format" {
    const ts = try timestampString(testing.allocator);
    defer testing.allocator.free(ts);
    try testing.expect(std.mem.indexOf(u8, ts, "T") != null);
    try testing.expect(std.mem.endsWith(u8, ts, "Z"));
}

test "entries below min_content_len are skipped" {
    const entries = [_]InputEntry{
        .{ .id = "mem_001", .key = "short", .content = "hi" },
    };

    const bench = try generate(testing.allocator, &entries, .{
        .min_content_len = 10,
    });
    try testing.expectEqual(@as(usize, 0), bench.entries.len);
}
