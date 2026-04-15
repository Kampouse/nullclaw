//! Benchmark and metrics data types for the meta-harness evaluation system.
//!
//! Provides structured types for defining benchmarks (query / expected-id pairs),
//! per-query retrieval metrics, aggregated eval metrics, and full eval results
//! tied to a specific configuration.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fmt = std.fmt;

// ---------------------------------------------------------------------------
// BenchmarkEntry
// ---------------------------------------------------------------------------

/// A single (query, expected_ids) pair used to evaluate retrieval quality.
pub const BenchmarkEntry = struct {
    /// Natural-language query submitted to the retrieval pipeline.
    query: []const u8,

    /// Memory / chunk IDs that should appear in the top-k results.
    expected_ids: [][]const u8,

    /// Optional per-id relevance weights (1.0 = fully relevant, 0.0 = not).
    /// When non-null, its length must equal `expected_ids.len`.
    weights: ?[]f64 = null,

    /// Optional human-readable explanation of why these IDs are expected.
    rationale: []const u8 = "",
};

// ---------------------------------------------------------------------------
// Benchmark
// ---------------------------------------------------------------------------

/// The full benchmark file — a collection of entries plus metadata.
pub const Benchmark = struct {
    entries: []BenchmarkEntry,
    description: []const u8,
    created_at: []const u8,

    /// Release every heap-allocated field owned by this Benchmark.
    /// Note: `entries[i].query` and `entries[i].rationale` are assumed to be
    /// slices into memory not separately allocated (e.g. they point into the
    /// parsed JSON buffer).  Only `expected_ids` inner slices are freed here.
    pub fn deinit(self: *Benchmark, allocator: Allocator) void {
        for (self.entries) |*entry| {
            for (entry.expected_ids) |id| {
                allocator.free(id);
            }
            allocator.free(entry.expected_ids);
            if (entry.weights) |w| {
                allocator.free(w);
            }
        }
        allocator.free(self.entries);
        allocator.free(self.description);
        allocator.free(self.created_at);
        self.* = .{
            .entries = &.{},
            .description = "",
            .created_at = "",
        };
    }
};

// ---------------------------------------------------------------------------
// QueryMetrics
// ---------------------------------------------------------------------------

/// Metrics computed for a single query evaluation.
pub const QueryMetrics = struct {
    query: []const u8,

    recall_at_1: f64,
    recall_at_3: f64,
    recall_at_k: f64,

    precision_at_k: f64,

    /// Mean reciprocal rank — 1 / rank_of_first_relevant_hit.
    mrr: f64,

    /// Normalised discounted cumulative gain.
    ndcg: f64,

    /// Wall-clock latency of the retrieval call, in microseconds.
    latency_us: u64,
};

// ---------------------------------------------------------------------------
// EvalMetrics
// ---------------------------------------------------------------------------

/// Aggregated metrics across all queries in an evaluation run.
pub const EvalMetrics = struct {
    mean_recall_at_1: f64,
    mean_recall_at_3: f64,
    mean_recall_at_k: f64,

    mean_precision_at_k: f64,

    mean_mrr: f64,
    mean_ndcg: f64,

    mean_latency_us: u64,
    median_latency_us: u64,

    total_queries: u32,
    k: u32,

    /// Return a human-readable one-line summary of the eval metrics.
    pub fn formatSummary(self: *const EvalMetrics, allocator: Allocator) ![]u8 {
        return fmt.allocPrint(
            allocator,
            "queries={d} k={d}  recall@1={d:.2} recall@3={d:.2} recall@k={d:.2}  P@k={d:.2}  MRR={d:.4}  nDCG={d:.4}  latency_mean={d}us median={d}us",
            .{
                self.total_queries,
                self.k,
                self.mean_recall_at_1,
                self.mean_recall_at_3,
                self.mean_recall_at_k,
                self.mean_precision_at_k,
                self.mean_mrr,
                self.mean_ndcg,
                self.mean_latency_us,
                self.median_latency_us,
            },
        );
    }
};

// ---------------------------------------------------------------------------
// EvalResult
// ---------------------------------------------------------------------------

/// Complete result of one evaluation run, tying metrics to a specific config.
pub const EvalResult = struct {
    /// SHA-256 hash of the configuration used for this run.
    config_hash: [32]u8,

    /// Serialised configuration JSON (for reproducibility / logging).
    config_json: []const u8,

    /// Aggregated metrics across all queries.
    metrics: EvalMetrics,

    /// Per-query breakdown.
    query_metrics: []QueryMetrics,

    /// Unix timestamp (seconds since epoch) when the run completed.
    timestamp: i64,

    /// Iteration index inside an outer optimisation loop.
    iteration: u32,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "BenchmarkEntry defaults" {
    const entry = BenchmarkEntry{
        .query = "test query",
        .expected_ids = &.{},
    };
    try testing.expectEqual(@as(?[]f64, null), entry.weights);
    try testing.expectEqualStrings("", entry.rationale);
}

test "EvalMetrics formatSummary" {
    const allocator = testing.allocator;
    var metrics = EvalMetrics{
        .mean_recall_at_1 = 0.5,
        .mean_recall_at_3 = 0.75,
        .mean_recall_at_k = 0.8,
        .mean_precision_at_k = 0.6,
        .mean_mrr = 0.65,
        .mean_ndcg = 0.7,
        .mean_latency_us = 1200,
        .median_latency_us = 1100,
        .total_queries = 10,
        .k = 5,
    };
    const summary = try metrics.formatSummary(allocator);
    defer allocator.free(summary);

    // Just verify it contains key fragments — exact formatting may vary.
    try testing.expect(std.mem.indexOf(u8, summary, "queries=10") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "k=5") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "MRR=") != null);
}

test "EvalResult field sizes" {
    const result = EvalResult{
        .config_hash = [_]u8{0} ** 32,
        .config_json = "{}",
        .metrics = EvalMetrics{
            .mean_recall_at_1 = 0.0,
            .mean_recall_at_3 = 0.0,
            .mean_recall_at_k = 0.0,
            .mean_precision_at_k = 0.0,
            .mean_mrr = 0.0,
            .mean_ndcg = 0.0,
            .mean_latency_us = 0,
            .median_latency_us = 0,
            .total_queries = 0,
            .k = 0,
        },
        .query_metrics = &.{},
        .timestamp = 0,
        .iteration = 0,
    };
    try testing.expectEqual(@as([32]u8, [_]u8{0} ** 32), result.config_hash);
    try testing.expectEqual(@as(u32, 0), result.iteration);
}
