//! LLM config proposer — suggests retrieval engine parameter changes.
//!
//! Analyzes evaluation metrics and proposes concrete parameter adjustments
//! to improve retrieval quality.  Uses simple heuristic rules based on
//! metric patterns (no actual LLM call needed).

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.eval_proposer);

const types = @import("types.zig");
const metrics = @import("metrics.zig");

// ---------------------------------------------------------------------------
// Proposed config change
// ---------------------------------------------------------------------------

pub const Proposal = struct {
    parameter: []const u8,
    current_value: f64,
    suggested_value: f64,
    reason: []const u8,
    confidence: f64, // 0.0 to 1.0
};

// ---------------------------------------------------------------------------
// Proposer options
// ---------------------------------------------------------------------------

pub const ProposerOptions = struct {
    /// Minimum confidence threshold to include a proposal.
    min_confidence: f64 = 0.3,
    /// Number of past iterations to consider.
    lookback: u32 = 5,
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Analyze eval results and propose parameter adjustments.
///
/// Uses simple heuristics on metric trends:
/// - Low recall → increase top_k, lower similarity threshold
/// - Low precision → decrease top_k, raise similarity threshold
/// - Low MRR → enable reranking
/// - Low nDCG → adjust mmr_lambda
pub fn propose(
    allocator: Allocator,
    results: []const types.EvalResult,
    options: ProposerOptions,
) ![]Proposal {
    if (results.len == 0) return &[_]Proposal{};

    // Take last N results.
    const start = if (results.len > options.lookback)
        results.len - options.lookback
    else
        0;
    const recent = results[start..];

    var proposals = std.ArrayListUnmanaged(Proposal){};
    errdefer {
        for (proposals.items) |p| allocator.free(p.reason);
        proposals.deinit(allocator);
    }

    // Compute aggregate metrics across the most recent result's queries.
    // We use the latest result's metrics as the primary signal.
    const latest = recent[recent.len - 1];
    const m = latest.metrics;

    // --- Recall-based proposals ---
    if (m.mean_recall_at_k < 0.3) {
        try proposals.append(allocator, .{
            .parameter = "top_k",
            .current_value = @floatFromInt(m.k),
            .suggested_value = @floatFromInt(m.k * 2),
            .reason = try std.fmt.allocPrint(allocator, "recall@k={d:.2} — increase top_k from {d} to {d} to retrieve more candidates", .{ m.mean_recall_at_k, m.k, m.k * 2 }),
            .confidence = 0.7,
        });
    }

    if (m.mean_recall_at_1 < 0.2) {
        try proposals.append(allocator, .{
            .parameter = "similarity_threshold",
            .current_value = 0.7,
            .suggested_value = 0.5,
            .reason = try std.fmt.allocPrint(allocator, "recall@1={d:.2} — lower similarity threshold to surface more results", .{m.mean_recall_at_1}),
            .confidence = 0.5,
        });
    }

    // --- Precision-based proposals ---
    if (m.mean_precision_at_k < 0.5) {
        try proposals.append(allocator, .{
            .parameter = "similarity_threshold",
            .current_value = 0.7,
            .suggested_value = 0.8,
            .reason = try std.fmt.allocPrint(allocator, "precision@k={d:.2} — raise threshold to filter noise", .{m.mean_precision_at_k}),
            .confidence = 0.6,
        });
    }

    // --- MRR-based proposal ---
    if (m.mean_mrr < 0.3) {
        try proposals.append(allocator, .{
            .parameter = "rerank_enabled",
            .current_value = 0,
            .suggested_value = 1,
            .reason = try std.fmt.allocPrint(allocator, "MRR={d:.3} — enable reranking to push relevant results higher", .{m.mean_mrr}),
            .confidence = 0.6,
        });
    }

    // --- nDCG-based proposal ---
    if (m.mean_ndcg < 0.4) {
        try proposals.append(allocator, .{
            .parameter = "mmr_lambda",
            .current_value = 0.5,
            .suggested_value = 0.7,
            .reason = try std.fmt.allocPrint(allocator, "nDCG={d:.3} — increase mmr_lambda for better ranking diversity", .{m.mean_ndcg}),
            .confidence = 0.5,
        });
    }

    // --- Trend-based proposals ---
    if (recent.len >= 3) {
        const trend_recall = computeTrend(recent, .recall);
        if (trend_recall < -0.1) {
            try proposals.append(allocator, .{
                .parameter = "embedding_model",
                .current_value = 0,
                .suggested_value = 1,
                .reason = "recall is declining across iterations — consider upgrading embedding model",
                .confidence = 0.4,
            });
        }
    }

    // Filter by confidence.
    const result = try allocator.alloc(Proposal, proposals.items.len);
    var out_idx: usize = 0;
    for (proposals.items) |p| {
        if (p.confidence >= options.min_confidence) {
            result[out_idx] = p;
            out_idx += 1;
        } else {
            // Free reason string of rejected proposal.
            allocator.free(p.reason);
        }
    }
    proposals.deinit(allocator);

    return result[0..out_idx];
}

const MetricKind = enum { recall, precision, mrr, ndcg };

/// Compute trend of a metric across iterations (negative = declining).
fn computeTrend(results: []const types.EvalResult, metric: MetricKind) f64 {
    if (results.len < 2) return 0.0;

    var improvements: f64 = 0;
    var total: f64 = 0;

    for (1..results.len) |i| {
        const prev = getMetric(results[i - 1], metric);
        const curr = getMetric(results[i], metric);
        improvements += curr - prev;
        total += 1;
    }

    if (total == 0) return 0.0;
    return improvements / total;
}

fn getMetric(result: types.EvalResult, metric: MetricKind) f64 {
    return switch (metric) {
        .recall => result.metrics.mean_recall_at_k,
        .precision => result.metrics.mean_precision_at_k,
        .mrr => result.metrics.mean_mrr,
        .ndcg => result.metrics.mean_ndcg,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeMetrics(recall_at_1: f64, recall_at_3: f64, recall_at_k: f64, precision: f64, mrr: f64, ndcg: f64) types.EvalMetrics {
    return .{
        .mean_recall_at_1 = recall_at_1,
        .mean_recall_at_3 = recall_at_3,
        .mean_recall_at_k = recall_at_k,
        .mean_precision_at_k = precision,
        .mean_mrr = mrr,
        .mean_ndcg = ndcg,
        .mean_latency_us = 100,
        .median_latency_us = 100,
        .total_queries = 10,
        .k = 5,
    };
}

fn makeResult(iteration: u32, m: types.EvalMetrics) types.EvalResult {
    return .{
        .config_hash = [_]u8{0} ** 32,
        .config_json = "{}",
        .metrics = m,
        .query_metrics = &.{},
        .timestamp = @as(i64, 1000) + @as(i64, iteration),
        .iteration = iteration,
    };
}

test "empty results returns empty proposals" {
    const proposals = try propose(testing.allocator, &[_]types.EvalResult{}, .{});
    try testing.expectEqual(@as(usize, 0), proposals.len);
}

test "low recall suggests increasing top_k" {
    const m = makeMetrics(0.1, 0.1, 0.1, 0.8, 0.5, 0.6);

    const results = [_]types.EvalResult{makeResult(0, m)};

    const proposals = try propose(testing.allocator, &results, .{ .min_confidence = 0.0 });
    defer {
        for (proposals) |p| testing.allocator.free(p.reason);
        testing.allocator.free(proposals);
    }

    var found_topk = false;
    for (proposals) |p| {
        if (std.mem.eql(u8, p.parameter, "top_k")) found_topk = true;
    }
    try testing.expect(found_topk);
}

test "good metrics returns no proposals at default confidence" {
    const m = makeMetrics(0.5, 0.7, 0.8, 0.7, 0.5, 0.6);

    const results = [_]types.EvalResult{makeResult(0, m)};

    const proposals = try propose(testing.allocator, &results, .{});
    defer {
        for (proposals) |p| testing.allocator.free(p.reason);
        testing.allocator.free(proposals);
    }

    try testing.expectEqual(@as(usize, 0), proposals.len);
}

test "low MRR suggests reranking" {
    const m = makeMetrics(0.5, 0.8, 0.8, 0.8, 0.1, 0.8);

    const results = [_]types.EvalResult{makeResult(0, m)};

    const proposals = try propose(testing.allocator, &results, .{ .min_confidence = 0.0 });
    defer {
        for (proposals) |p| testing.allocator.free(p.reason);
        testing.allocator.free(proposals);
    }

    var found_rerank = false;
    for (proposals) |p| {
        if (std.mem.eql(u8, p.parameter, "rerank_enabled")) found_rerank = true;
    }
    try testing.expect(found_rerank);
}

test "computeTrend declining" {
    const results = [_]types.EvalResult{
        makeResult(0, makeMetrics(0.5, 0.8, 0.8, 0.7, 0.6, 0.7)),
        makeResult(1, makeMetrics(0.5, 0.6, 0.6, 0.6, 0.5, 0.6)),
        makeResult(2, makeMetrics(0.5, 0.4, 0.4, 0.5, 0.4, 0.5)),
    };

    const trend = computeTrend(&results, .recall);
    try testing.expect(trend < 0);
}

test "computeTrend single result returns zero" {
    const results = [_]types.EvalResult{makeResult(0, makeMetrics(0.5, 0.5, 0.5, 0.5, 0.5, 0.5))};
    try testing.expectApproxEqAbs(0.0, computeTrend(&results, .recall), 1e-9);
}

test "lookback limits analysis to recent results" {
    const m_bad = makeMetrics(0.1, 0.1, 0.1, 0.1, 0.1, 0.1);
    const m_good = makeMetrics(0.5, 0.7, 0.9, 0.9, 0.9, 0.9);

    const results = [_]types.EvalResult{
        makeResult(0, m_bad),
        makeResult(1, m_bad),
        makeResult(2, m_bad),
        makeResult(3, m_good),
        makeResult(4, m_good),
    };

    // lookback=2 means only the last 2 (good) results are considered.
    const proposals = try propose(testing.allocator, &results, .{ .lookback = 2 });
    defer {
        for (proposals) |p| testing.allocator.free(p.reason);
        testing.allocator.free(proposals);
    }

    try testing.expectEqual(@as(usize, 0), proposals.len);
}
