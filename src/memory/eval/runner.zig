//! Evaluation runner — executes the retrieval pipeline against a benchmark
//! and computes per-query and aggregated metrics.
//!
//! Orchestration layer between the retrieval engine and the metrics module.
//! For each benchmark entry it times a search call, extracts candidate IDs,
//! and feeds them into `metrics.computeQueryMetrics`.  After all entries are
//! processed, `metrics.aggregateMetrics` produces the final summary.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.eval_runner);

const types = @import("types.zig");
const metrics_mod = @import("metrics.zig");
const retrieval = @import("../retrieval/engine.zig");

// ---------------------------------------------------------------------------
// EvalResultFields
// ---------------------------------------------------------------------------

/// Result produced by `runEval`: per-query metrics plus an aggregate summary.
pub const EvalResultFields = struct {
    query_metrics: []types.QueryMetrics,
    aggregated: types.EvalMetrics,
};

// ---------------------------------------------------------------------------
// runEval
// ---------------------------------------------------------------------------

/// Run the full evaluation pipeline.
///
/// For every entry in `benchmark` the retrieval engine is queried and the
/// results are scored against the expected IDs.  If a search call fails for
/// one query, a warning is logged and the query is skipped — remaining
/// entries are still processed.
pub fn runEval(
    allocator: Allocator,
    engine: *retrieval.RetrievalEngine,
    benchmark: *const types.Benchmark,
    k: u32,
) !EvalResultFields {
    var results = std.ArrayListUnmanaged(types.QueryMetrics){};
    errdefer {
        // Per-query QueryMetrics only borrows the query string; nothing to free.
        results.deinit(allocator);
    }

    for (benchmark.entries) |entry| {
        // 1. Record start time (nanosecond precision).
        const start_ns = std.time.nanoTimestamp();

        // 2. Execute the retrieval search.
        const candidates = engine.search(allocator, entry.query, null) catch |err| {
            log.warn("search failed for query '{s}', skipping: {}", .{ entry.query, err });
            continue;
        };

        // 3. Record end time and compute latency in microseconds.
        const end_ns = std.time.nanoTimestamp();
        const elapsed_ns = @as(u64, @intCast(end_ns - start_ns));
        const latency_us = elapsed_ns / 1_000;

        // 4. Extract candidate IDs into a lightweight slice (no copies).
        var retrieved_ids = try allocator.alloc([]const u8, candidates.len);
        defer allocator.free(retrieved_ids);

        for (candidates, 0..) |candidate, i| {
            retrieved_ids[i] = candidate.id;
        }

        // 5. Compute per-query metrics.
        const qm = metrics_mod.computeQueryMetrics(
            allocator,
            entry.query,
            retrieved_ids,
            entry.expected_ids,
            entry.weights,
            k,
            latency_us,
        ) catch |err| {
            log.warn("computeQueryMetrics failed for query '{s}', skipping: {}", .{ entry.query, err });
            retrieval.freeCandidates(allocator, candidates);
            continue;
        };

        // 6. Free the candidates returned by the engine.
        retrieval.freeCandidates(allocator, candidates);

        // 7. Append to result list.
        try results.append(allocator, qm);
    }

    // Aggregate across all successfully evaluated queries.
    const aggregated = try metrics_mod.aggregateMetrics(allocator, results.items, k);

    return .{
        .query_metrics = results.items,
        .aggregated = aggregated,
    };
}
