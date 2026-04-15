//! Retrieval evaluation metrics: recall@k, precision@k, MRR, and nDCG.
//!
//! Provides per-query metric computation (`computeQueryMetrics`) and
//! cross-query aggregation (`aggregateMetrics`).

const std = @import("std");
const math = std.math;
const mem = std.mem;

const types = @import("types.zig");

// ---------------------------------------------------------------------------
// computeQueryMetrics
// ---------------------------------------------------------------------------

/// Compute retrieval quality metrics for a single query.
///
/// - `retrieved_ids`: IDs the retrieval engine returned, in ranked order.
/// - `expected_ids`:  Ground-truth relevant IDs.
/// - `weights`:       Optional per-id graded relevance (must match expected_ids length).
/// - `k`:             Evaluation cutoff.
/// - `latency_us`:    Wall-clock latency of the retrieval call.
pub fn computeQueryMetrics(
    allocator: std.mem.Allocator,
    query: []const u8,
    retrieved_ids: []const []const u8,
    expected_ids: []const []const u8,
    weights: ?[]const f64,
    k: u32,
    latency_us: u64,
) !types.QueryMetrics {
    const n_retrieved: u32 = @intCast(retrieved_ids.len);
    const n_expected: u32 = @intCast(expected_ids.len);

    // Clamp effective cutoff to the number of retrieved results.
    const eff_k: u32 = @min(k, n_retrieved);

    // --- Recall helpers -----------------------------------------------------

    // Count how many expected IDs appear in retrieved_ids[0..cutoff].
    const countHits = struct {
        fn countHits(retrieved: []const []const u8, expected: []const []const u8, cutoff: u32) u32 {
            var hits: u32 = 0;
            const lim = @min(cutoff, @as(u32, @intCast(retrieved.len)));
            for (retrieved[0..lim]) |rid| {
                for (expected) |eid| {
                    if (mem.eql(u8, rid, eid)) {
                        hits += 1;
                        break;
                    }
                }
            }
            return hits;
        }
    }.countHits;

    const hits_1 = countHits(retrieved_ids, expected_ids, 1);
    const hits_3 = countHits(retrieved_ids, expected_ids, 3);
    const hits_k = countHits(retrieved_ids, expected_ids, eff_k);

    const recall_at_1: f64 = if (n_expected == 0) 0.0 else @as(f64, @floatFromInt(hits_1)) / @as(f64, @floatFromInt(n_expected));
    const recall_at_3: f64 = if (n_expected == 0) 0.0 else @as(f64, @floatFromInt(hits_3)) / @as(f64, @floatFromInt(n_expected));
    const recall_at_k: f64 = if (n_expected == 0) 0.0 else @as(f64, @floatFromInt(hits_k)) / @as(f64, @floatFromInt(n_expected));

    // --- Precision@k -------------------------------------------------------

    const precision_at_k: f64 = if (eff_k == 0) 0.0
    else @as(f64, @floatFromInt(hits_k)) / @as(f64, @floatFromInt(eff_k));

    // --- MRR ----------------------------------------------------------------

    var mrr: f64 = 0.0;
    for (retrieved_ids, 0..) |rid, rank| {
        for (expected_ids) |eid| {
            if (mem.eql(u8, rid, eid)) {
                mrr = 1.0 / @as(f64, @floatFromInt(rank + 1));
                break;
            }
        }
        if (mrr > 0.0) break;
    }

    // --- nDCG ---------------------------------------------------------------

    // Build a lookup from expected_id -> weight (1.0 when weights is null).
    const getWeight = struct {
        fn getWeight(eid: []const u8, expected: []const []const u8, w: ?[]const f64) f64 {
            if (w) |ws| {
                for (expected, 0..) |candidate, i| {
                    if (mem.eql(u8, eid, candidate)) {
                        return ws[i];
                    }
                }
            }
            return 1.0;
        }
    }.getWeight;

    // DCG: sum over top-k of (2^rel - 1) / log2(rank + 2)
    var dcg: f64 = 0.0;
    const dcg_lim = @min(eff_k, n_retrieved);
    for (retrieved_ids[0..dcg_lim], 0..) |rid, rank| {
        var rel: f64 = 0.0;
        for (expected_ids) |eid| {
            if (mem.eql(u8, rid, eid)) {
                rel = getWeight(eid, expected_ids, weights);
                break;
            }
        }
        if (rel > 0.0) {
            dcg += (math.pow(f64, 2.0, rel) - 1.0) / math.log2(@as(f64, @floatFromInt(rank + 2)));
        }
    }

    // IDCG: ideal ranking — all relevant docs sorted by relevance descending.
    const n_rel = expected_ids.len;
    if (n_rel > 0) {
        // Collect relevance grades for all expected IDs.
        var rel_grades: [1024]f64 = undefined;
        var grades_ptr: ?[]f64 = null;
        var grades: []f64 = undefined;

        if (n_rel <= rel_grades.len) {
            grades = rel_grades[0..n_rel];
        } else {
            // Fallback: heap-allocate for very large expected sets.
            const buf = try allocator.alloc(f64, n_rel);
            grades_ptr = buf;
            grades = buf;
        }
        defer if (grades_ptr) |buf| allocator.free(buf);

        for (expected_ids, 0..) |_, i| {
            grades[i] = if (weights) |ws| ws[i] else 1.0;
        }
        // Insertion sort descending.
        var i: usize = 1;
        while (i < grades.len) : (i += 1) {
            const key = grades[i];
            var j = i;
            while (j > 0 and grades[j - 1] < key) : (j -= 1) {
                grades[j] = grades[j - 1];
            }
            grades[j] = key;
        }
        // Compute IDCG from sorted grades (capped at eff_k positions).
        var idcg: f64 = 0.0;
        const idcg_count = @min(grades.len, @as(usize, eff_k));
        for (grades[0..idcg_count], 0..) |rel, rank| {
            idcg += (math.pow(f64, 2.0, rel) - 1.0) / math.log2(@as(f64, @floatFromInt(rank + 2)));
        }

        const ndcg: f64 = if (idcg == 0.0) 0.0 else dcg / idcg;

        return .{
            .query = query,
            .recall_at_1 = recall_at_1,
            .recall_at_3 = recall_at_3,
            .recall_at_k = recall_at_k,
            .precision_at_k = precision_at_k,
            .mrr = mrr,
            .ndcg = ndcg,
            .latency_us = latency_us,
        };
    } else {
        // No expected IDs → nDCG is undefined; report 0.0.
        return .{
            .query = query,
            .recall_at_1 = recall_at_1,
            .recall_at_3 = recall_at_3,
            .recall_at_k = recall_at_k,
            .precision_at_k = precision_at_k,
            .mrr = mrr,
            .ndcg = 0.0,
            .latency_us = latency_us,
        };
    }
}

// ---------------------------------------------------------------------------
// aggregateMetrics
// ---------------------------------------------------------------------------

/// Aggregate per-query metrics into summary statistics.
pub fn aggregateMetrics(
    allocator: std.mem.Allocator,
    query_metrics: []const types.QueryMetrics,
    k: u32,
) !types.EvalMetrics {
    const n: u32 = @intCast(query_metrics.len);
    if (n == 0) {
        return .{
            .mean_recall_at_1 = 0.0,
            .mean_recall_at_3 = 0.0,
            .mean_recall_at_k = 0.0,
            .mean_precision_at_k = 0.0,
            .mean_mrr = 0.0,
            .mean_ndcg = 0.0,
            .mean_latency_us = 0,
            .median_latency_us = 0,
            .total_queries = 0,
            .k = k,
        };
    }

    var sum_recall_1: f64 = 0.0;
    var sum_recall_3: f64 = 0.0;
    var sum_recall_k: f64 = 0.0;
    var sum_prec_k: f64 = 0.0;
    var sum_mrr: f64 = 0.0;
    var sum_ndcg: f64 = 0.0;
    var sum_latency: u64 = 0;

    for (query_metrics) |qm| {
        sum_recall_1 += qm.recall_at_1;
        sum_recall_3 += qm.recall_at_3;
        sum_recall_k += qm.recall_at_k;
        sum_prec_k += qm.precision_at_k;
        sum_mrr += qm.mrr;
        sum_ndcg += qm.ndcg;
        sum_latency += qm.latency_us;
    }

    const inv_n: f64 = 1.0 / @as(f64, @floatFromInt(n));

    // Collect latencies for median computation.
    const latencies = try allocator.alloc(u64, n);
    defer allocator.free(latencies);
    for (query_metrics, 0..) |qm, i| {
        latencies[i] = qm.latency_us;
    }
    // Sort latencies ascending.
    mem.sort(u64, latencies, {}, comptime std.sort.asc(u64));

    const median_latency: u64 = if (n % 2 == 1)
        latencies[n / 2]
    else
        (latencies[n / 2 - 1] + latencies[n / 2]) / 2;

    return .{
        .mean_recall_at_1 = sum_recall_1 * inv_n,
        .mean_recall_at_3 = sum_recall_3 * inv_n,
        .mean_recall_at_k = sum_recall_k * inv_n,
        .mean_precision_at_k = sum_prec_k * inv_n,
        .mean_mrr = sum_mrr * inv_n,
        .mean_ndcg = sum_ndcg * inv_n,
        .mean_latency_us = sum_latency / n,
        .median_latency_us = median_latency,
        .total_queries = n,
        .k = k,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "perfect retrieval: recall and precision should be 1.0" {
    const retrieved = [_][]const u8{ "a", "b", "c", "d", "e" };
    const expected = [_][]const u8{ "a", "b", "c" };

    const qm = try computeQueryMetrics(
        testing.allocator,
        "test",
        &retrieved,
        &expected,
        null,
        5,
        100,
    );
    try testing.expectEqual(@as(f64, 1.0), qm.recall_at_1);
    try testing.expectEqual(@as(f64, 1.0), qm.recall_at_3);
    try testing.expectEqual(@as(f64, 1.0), qm.recall_at_k);
    try testing.expectEqual(@as(f64, 0.6), qm.precision_at_k);
    try testing.expectEqual(@as(f64, 1.0), qm.mrr);
}

test "no relevant results: all metrics should be 0.0" {
    const retrieved = [_][]const u8{ "x", "y", "z" };
    const expected = [_][]const u8{ "a", "b" };

    const qm = try computeQueryMetrics(
        testing.allocator,
        "test",
        &retrieved,
        &expected,
        null,
        3,
        200,
    );
    try testing.expectEqual(@as(f64, 0.0), qm.recall_at_1);
    try testing.expectEqual(@as(f64, 0.0), qm.recall_at_3);
    try testing.expectEqual(@as(f64, 0.0), qm.recall_at_k);
    try testing.expectEqual(@as(f64, 0.0), qm.precision_at_k);
    try testing.expectEqual(@as(f64, 0.0), qm.mrr);
}

test "empty expected: recall and precision are 0.0" {
    const retrieved = [_][]const u8{ "a", "b" };
    const expected = [_][]const u8{};

    const qm = try computeQueryMetrics(
        testing.allocator,
        "test",
        &retrieved,
        &expected,
        null,
        5,
        50,
    );
    try testing.expectEqual(@as(f64, 0.0), qm.recall_at_1);
    try testing.expectEqual(@as(f64, 0.0), qm.recall_at_3);
    try testing.expectEqual(@as(f64, 0.0), qm.recall_at_k);
}

test "empty retrieved: all metrics are 0.0" {
    const retrieved = [_][]const u8{};
    const expected = [_][]const u8{ "a", "b" };

    const qm = try computeQueryMetrics(
        testing.allocator,
        "test",
        &retrieved,
        &expected,
        null,
        5,
        10,
    );
    try testing.expectEqual(@as(f64, 0.0), qm.recall_at_1);
    try testing.expectEqual(@as(f64, 0.0), qm.mrr);
    try testing.expectEqual(@as(f64, 0.0), qm.precision_at_k);
}

test "k larger than retrieved count" {
    const retrieved = [_][]const u8{ "a", "b" };
    const expected = [_][]const u8{ "a", "b", "c" };

    const qm = try computeQueryMetrics(
        testing.allocator,
        "test",
        &retrieved,
        &expected,
        null,
        10,
        30,
    );
    // Only 2 retrieved, so recall@k should be 2/3.
    try testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), qm.recall_at_k, 1e-9);
    // Precision at effective k (2) = 2/2 = 1.0
    try testing.expectEqual(@as(f64, 1.0), qm.precision_at_k);
}

test "MRR with relevant at rank 3" {
    const retrieved = [_][]const u8{ "x", "y", "a", "z" };
    const expected = [_][]const u8{ "a" };

    const qm = try computeQueryMetrics(
        testing.allocator,
        "test",
        &retrieved,
        &expected,
        null,
        4,
        40,
    );
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), qm.mrr, 1e-9);
    try testing.expectEqual(@as(f64, 0.0), qm.recall_at_1);
    try testing.expectEqual(@as(f64, 1.0), qm.recall_at_3);
}

test "nDCG with binary relevance" {
    const retrieved = [_][]const u8{ "a", "b", "x", "c" };
    const expected = [_][]const u8{ "a", "b", "c" };

    const qm = try computeQueryMetrics(
        testing.allocator,
        "test",
        &retrieved,
        &expected,
        null,
        4,
        50,
    );

    // DCG = (2^1-1)/log2(2) + (2^1-1)/log2(3) + 0/log2(4) + (2^1-1)/log2(5)
    //     = 1/1 + 1/1.585 + 0 + 1/2.322
    //     ≈ 1.0 + 0.631 + 0.431 = 2.062
    // IDCG = 1/log2(2) + 1/log2(3) + 1/log2(4) ≈ 1.0 + 0.631 + 0.500 = 2.131
    try testing.expectApproxEqAbs(2.062, qm.ndcg, 0.01);
}

test "nDCG with graded relevance" {
    const retrieved = [_][]const u8{ "a", "x", "b", "c" };
    const expected = [_][]const u8{ "a", "b", "c" };
    const weights_arr = [_]f64{ 2.0, 1.0, 0.5 };

    const qm = try computeQueryMetrics(
        testing.allocator,
        "test",
        &retrieved,
        &expected,
        &weights_arr,
        4,
        60,
    );

    // DCG = (2^2-1)/log2(2) + 0 + (2^1-1)/log2(4) + (2^0.5-1)/log2(5)
    //     = 3/1 + 0 + 1/2 + 0.414/2.322
    //     ≈ 3.0 + 0.5 + 0.178 = 3.678
    // IDCG (sorted rel: 2.0, 1.0, 0.5):
    //     = 3/log2(2) + 1/log2(3) + 0.414/log2(4)
    //     ≈ 3.0 + 0.631 + 0.207 = 3.838
    try testing.expectApproxEqAbs(0.96, qm.ndcg, 0.02);
}

test "aggregateMetrics with single query" {
    const qms = [_]types.QueryMetrics{.{
        .query = "test",
        .recall_at_1 = 0.5,
        .recall_at_3 = 0.75,
        .recall_at_k = 0.8,
        .precision_at_k = 0.6,
        .mrr = 0.65,
        .ndcg = 0.7,
        .latency_us = 100,
    }};

    const agg = try aggregateMetrics(testing.allocator, &qms, 5);
    try testing.expectEqual(@as(u32, 1), agg.total_queries);
    try testing.expectEqual(@as(f64, 0.5), agg.mean_recall_at_1);
    try testing.expectEqual(@as(f64, 0.75), agg.mean_recall_at_3);
    try testing.expectEqual(@as(f64, 0.8), agg.mean_recall_at_k);
    try testing.expectEqual(@as(f64, 0.6), agg.mean_precision_at_k);
    try testing.expectEqual(@as(f64, 0.65), agg.mean_mrr);
    try testing.expectEqual(@as(f64, 0.7), agg.mean_ndcg);
    try testing.expectEqual(@as(u64, 100), agg.mean_latency_us);
    try testing.expectEqual(@as(u64, 100), agg.median_latency_us);
}

test "aggregateMetrics median with even number of queries" {
    const qms = [_]types.QueryMetrics{
        .{ .query = "q1", .recall_at_1 = 0, .recall_at_3 = 0, .recall_at_k = 0, .precision_at_k = 0, .mrr = 0, .ndcg = 0, .latency_us = 100 },
        .{ .query = "q2", .recall_at_1 = 0, .recall_at_3 = 0, .recall_at_k = 0, .precision_at_k = 0, .mrr = 0, .ndcg = 0, .latency_us = 200 },
        .{ .query = "q3", .recall_at_1 = 0, .recall_at_3 = 0, .recall_at_k = 0, .precision_at_k = 0, .mrr = 0, .ndcg = 0, .latency_us = 300 },
        .{ .query = "q4", .recall_at_1 = 0, .recall_at_3 = 0, .recall_at_k = 0, .precision_at_k = 0, .mrr = 0, .ndcg = 0, .latency_us = 400 },
    };

    const agg = try aggregateMetrics(testing.allocator, &qms, 5);
    try testing.expectEqual(@as(u64, 250), agg.median_latency_us);
    try testing.expectEqual(@as(u64, 250), agg.mean_latency_us);
}

test "aggregateMetrics empty input" {
    const agg = try aggregateMetrics(testing.allocator, &[_]types.QueryMetrics{}, 5);
    try testing.expectEqual(@as(u32, 0), agg.total_queries);
    try testing.expectEqual(@as(f64, 0.0), agg.mean_recall_at_1);
    try testing.expectEqual(@as(u64, 0), agg.mean_latency_us);
}
