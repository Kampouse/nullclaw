# Meta-Harness: Self-Optimizing Retrieval Pipeline

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Add an eval loop that measures retrieval quality against a benchmark dataset, then uses an LLM to propose improved pipeline configurations — making NullClaw's memory retrieval self-improving.

**Architecture:** 
1. A `nullclaw memory eval` CLI subcommand runs RetrievalEngine.search() against a JSON benchmark file, computing recall@k and MRR per query.
2. A `nullclaw memory eval-optimize` subcommand runs the eval loop: evaluate current config, call LLM proposer to suggest improvements, re-evaluate, repeat for N iterations.
3. A benchmark generator (`nullclaw memory eval-generate`) extracts (query, expected_memory_ids) pairs from the existing memory store via LLM synthesis.
4. Results are logged to `~/.nullclaw/eval_results.jsonl` — one JSON object per (config, metrics) pair.

**Tech Stack:** Zig (eval harness, metrics), JSON benchmark format, LLM API for proposer (reuses existing model routing)

---

## Phase 1: Eval Infrastructure

### Task 1: Add eval benchmark types

**Objective:** Define the data structures for the benchmark dataset and eval results.

**Files:**
- Create: `src/memory/eval/types.zig`

**Step 1: Create types file with benchmark entry, eval result, and metrics structs**

```zig
//! Meta-harness evaluation types — benchmark entries, eval results, metrics.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// A single benchmark entry: query + the memory IDs that should be retrieved.
pub const BenchmarkEntry = struct {
    /// Natural language query (what a user might ask)
    query: []const u8,
    /// Memory entry IDs that are relevant to this query
    expected_ids: [][]const u8,
    /// Optional: relevance weights (1.0 = must-have, 0.5 = nice-to-have)
    weights: ?[]const f64 = null,
    /// Optional: human-readable description of why these are relevant
    rationale: []const u8 = "",
};

/// Parsed benchmark file
pub const Benchmark = struct {
    entries: []BenchmarkEntry,
    description: []const u8 = "",
    created_at: []const u8 = "",

    pub fn deinit(self: *Benchmark, allocator: Allocator) void {
        for (self.entries) |*e| {
            allocator.free(e.query);
            allocator.free(e.rationale);
            for (e.expected_ids) |id| allocator.free(id);
            allocator.free(e.expected_ids);
            if (e.weights) |w| allocator.free(w);
        }
        allocator.free(self.entries);
        allocator.free(self.description);
        allocator.free(self.created_at);
    }
};

/// Metrics for a single query evaluation
pub const QueryMetrics = struct {
    query: []const u8,
    recall_at_1: f64,
    recall_at_3: f64,
    recall_at_k: f64,
    precision_at_k: f64,
    mrr: f64, // mean reciprocal rank
    ndcg: f64, // normalized discounted cumulative gain
    latency_us: u64, // microseconds
};

/// Aggregated metrics across all benchmark queries
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

    /// Format as a summary string
    pub fn formatSummary(self: *const EvalMetrics, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, 
            "queries={d} k={d} recall@1={d:.3} recall@3={d:.3} recall@k={d:.3} P@k={d:.3} MRR={d:.3} nDCG={d:.3} latency={d}us",
            .{ self.total_queries, self.k, self.mean_recall_at_1, self.mean_recall_at_3, 
              self.mean_recall_at_k, self.mean_precision_at_k, self.mean_mrr, self.mean_ndcg,
              self.mean_latency_us }
        ) catch "metrics format failed";
    }
};

/// A complete eval result: config + metrics
pub const EvalResult = struct {
    config_hash: [32]u8, // SHA256 of the config JSON
    config_json: []const u8,
    metrics: EvalMetrics,
    query_metrics: []QueryMetrics,
    timestamp: i64,
    iteration: u32,
};
```

**Step 2: Commit**

```bash
git add src/memory/eval/types.zig
git commit -m "feat(meta-harness): add eval benchmark and metrics types"
```

---

### Task 2: Add metrics computation

**Objective:** Implement recall@k, precision@k, MRR, and nDCG calculation from ranked retrieval results.

**Files:**
- Create: `src/memory/eval/metrics.zig`

**Step 1: Implement metrics calculation**

```zig
//! Metrics computation — recall@k, precision@k, MRR, nDCG.
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

/// Compute metrics for a single query.
/// `retrieved_ids` are the memory IDs returned by the retrieval engine, in ranked order.
/// `expected_ids` are the ground-truth relevant IDs.
/// `weights` are optional relevance weights (1.0 = highly relevant, 0.5 = partially).
pub fn computeQueryMetrics(
    allocator: Allocator,
    query: []const u8,
    retrieved_ids: [][]const u8,
    expected_ids: [][]const u8,
    weights: ?[]const f64,
    k: u32,
    latency_us: u64,
) !types.QueryMetrics {
    const effective_k = @min(k, @as(u32, @intCast(retrieved_ids.len)));
    
    // Count how many expected IDs appear in top-k results
    var hits_at_k: u32 = 0;
    var first_rank: u32 = 0; // 0 = not found (MRR contribution = 0)
    var dcg: f64 = 0;
    var idcg: f64 = 0;
    
    // Compute IDCG (ideal DCG — all relevant docs at top positions)
    var w_idx: u32 = 0;
    var sorted_weights = try allocator.alloc(f64, expected_ids.len);
    defer allocator.free(sorted_weights);
    for (expected_ids, 0..) |_, i| {
        sorted_weights[i] = if (weights) |w| w[i] else 1.0;
    }
    // Sort descending for ideal ranking
    std.mem.sort(f64, sorted_weights, {}, comptime std.sort.desc(f64));
    for (sorted_weights, 0..) |w, i| {
        if (i < effective_k) {
            const discount = @as(f64, @floatFromInt(i + 1));
            idcg += (std.math.pow(f64, 2.0, w) - 1.0) / std.math.log2(discount + 2.0);
        }
    }
    
    // Compute actual metrics
    for (retrieved_ids[0..effective_k], 0..) |rid, rank| {
        const r: u32 = @intCast(rank);
        // Find this ID in expected
        var relevance: f64 = 0;
        for (expected_ids, 0..) |eid, ei| {
            if (std.mem.eql(u8, rid, eid)) {
                relevance = if (weights) |w| w[ei] else 1.0;
                hits_at_k += 1;
                if (first_rank == 0) first_rank = r + 1;
                break;
            }
        }
        const discount = @as(f64, @floatFromInt(r + 1));
        dcg += (std.math.pow(f64, 2.0, relevance) - 1.0) / std.math.log2(discount + 2.0);
    }
    
    // Also check hits at 1 and 3
    var hits_at_1: u32 = 0;
    var hits_at_3: u32 = 0;
    const check_3 = @min(3, effective_k);
    for (retrieved_ids[0..check_3]) |rid| {
        for (expected_ids) |eid| {
            if (std.mem.eql(u8, rid, eid)) {
                if (hits_at_1 == 0) hits_at_1 = 1;
                hits_at_3 += 1;
                break;
            }
        }
    }
    
    const ndcg: f64 = if (idcg > 0) dcg / idcg else 0;
    const mrr: f64 = if (first_rank > 0) 1.0 / @as(f64, @floatFromInt(first_rank)) else 0;
    
    const recall_at_k: f64 = if (expected_ids.len > 0) 
        @as(f64, @floatFromInt(hits_at_k)) / @as(f64, @floatFromInt(expected_ids.len)) 
        else 0;
    const recall_at_1: f64 = if (expected_ids.len > 0) 
        @as(f64, @floatFromInt(hits_at_1)) / @as(f64, @floatFromInt(expected_ids.len)) 
        else 0;
    const recall_at_3: f64 = if (expected_ids.len > 0) 
        @as(f64, @floatFromInt(hits_at_3)) / @as(f64, @floatFromInt(expected_ids.len)) 
        else 0;
    const precision_at_k: f64 = if (effective_k > 0) 
        @as(f64, @floatFromInt(hits_at_k)) / @as(f64, @floatFromInt(effective_k)) 
        else 0;
    
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
}

/// Aggregate query-level metrics into overall metrics.
pub fn aggregateMetrics(
    allocator: Allocator,
    query_metrics: []types.QueryMetrics,
    k: u32,
) !types.EvalMetrics {
    if (query_metrics.len == 0) {
        return .{
            .mean_recall_at_1 = 0,
            .mean_recall_at_3 = 0,
            .mean_recall_at_k = 0,
            .mean_precision_at_k = 0,
            .mean_mrr = 0,
            .mean_ndcg = 0,
            .mean_latency_us = 0,
            .median_latency_us = 0,
            .total_queries = 0,
            .k = k,
        };
    }
    
    var sum_r1: f64 = 0;
    var sum_r3: f64 = 0;
    var sum_rk: f64 = 0;
    var sum_pk: f64 = 0;
    var sum_mrr: f64 = 0;
    var sum_ndcg: f64 = 0;
    var sum_lat: u64 = 0;
    
    var latencies = try allocator.alloc(u64, query_metrics.len);
    defer allocator.free(latencies);
    
    for (query_metrics, 0..) |qm, i| {
        sum_r1 += qm.recall_at_1;
        sum_r3 += qm.recall_at_3;
        sum_rk += qm.recall_at_k;
        sum_pk += qm.precision_at_k;
        sum_mrr += qm.mrr;
        sum_ndcg += qm.ndcg;
        sum_lat += qm.latency_us;
        latencies[i] = qm.latency_us;
    }
    
    const n: f64 = @floatFromInt(query_metrics.len);
    std.mem.sort(u64, latencies, {}, std.sort.asc(u64));
    const median = latencies[query_metrics.len / 2];
    
    return .{
        .mean_recall_at_1 = sum_r1 / n,
        .mean_recall_at_3 = sum_r3 / n,
        .mean_recall_at_k = sum_rk / n,
        .mean_precision_at_k = sum_pk / n,
        .mean_mrr = sum_mrr / n,
        .mean_ndcg = sum_ndcg / n,
        .mean_latency_us = sum_lat / query_metrics.len,
        .median_latency_us = median,
        .total_queries = @intCast(query_metrics.len),
        .k = k,
    };
}
```

**Step 2: Commit**

```bash
git add src/memory/eval/metrics.zig
git commit -m "feat(meta-harness): add recall/precision/MRR/nDCG metrics computation"
```

---

### Task 3: Add benchmark JSON parser

**Objective:** Parse benchmark files from JSON format.

**Files:**
- Create: `src/memory/eval/benchmark.zig`

**Step 1: Implement benchmark loader**

The benchmark JSON format:
```json
{
  "description": "NullClaw retrieval benchmark v1",
  "created_at": "2026-04-15T12:00:00Z",
  "entries": [
    {
      "query": "what was the NEAR account name?",
      "expected_ids": ["mem_001", "mem_042"],
      "rationale": "User frequently asks about NEAR account; stored in two memory entries"
    },
    {
      "query": "help me debug this Zig error",
      "expected_ids": ["mem_015"],
      "weights": [1.0],
      "rationale": "Zig debugging patterns stored in single entry"
    }
  ]
}
```

Implement `loadBenchmark(allocator, path) !Benchmark` that reads the JSON file, parses entries, and returns the Benchmark struct. Use `std.json` for parsing.

**Step 2: Commit**

```bash
git add src/memory/eval/benchmark.zig
git commit -m "feat(meta-harness): add benchmark JSON loader"
```

---

### Task 4: Add eval runner

**Objective:** Run the retrieval pipeline against benchmark queries and compute metrics.

**Files:**
- Create: `src/memory/eval/runner.zig`

**Step 1: Implement eval runner**

```zig
//! Eval runner — executes retrieval pipeline against benchmark and computes metrics.
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const metrics_mod = @import("metrics.zig");
const benchmark_mod = @import("benchmark.zig");

const retrieval = @import("../retrieval/engine.zig");

/// Run evaluation of the retrieval engine against a benchmark.
pub fn runEval(
    allocator: Allocator,
    engine: *retrieval.RetrievalEngine,
    benchmark: *const types.Benchmark,
    k: u32,
) !struct { query_metrics: []types.QueryMetrics, aggregated: types.EvalMetrics } {
    var qm_list = try std.ArrayList(types.QueryMetrics).initCapacity(allocator, benchmark.entries.len);
    errdefer {
        for (qm_list.items) |*qm| allocator.free(qm.query);
        qm_list.deinit(allocator);
    }
    
    for (benchmark.entries) |entry| {
        var tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&tv, null);
        const start_us = @as(u64, @intCast(tv.sec)) * 1_000_000 + @as(u64, @intCast(tv.usec));
        
        // Run retrieval
        const candidates = engine.search(allocator, entry.query, null) catch |err| {
            std.log.warn("eval: search failed for query '{s}': {}", .{ entry.query, err });
            continue;
        };
        defer retrieval.freeCandidates(allocator, candidates);
        
        _ = std.c.gettimeofday(&tv, null);
        const end_us = @as(u64, @intCast(tv.sec)) * 1_000_000 + @as(u64, @intCast(tv.usec));
        const latency = end_us -| start_us;
        
        // Extract returned IDs
        var retrieved_ids = try allocator.alloc([]const u8, candidates.len);
        defer allocator.free(retrieved_ids);
        for (candidates, 0..) |c, i| {
            retrieved_ids[i] = c.id;
        }
        
        const qm = try metrics_mod.computeQueryMetrics(
            allocator,
            entry.query,
            retrieved_ids,
            entry.expected_ids,
            entry.weights,
            k,
            latency,
        );
        try qm_list.append(allocator, qm);
    }
    
    const aggregated = try metrics_mod.aggregateMetrics(
        allocator,
        qm_list.items,
        k,
    );
    
    return .{
        .query_metrics = qm_list.toOwnedSlice(allocator),
        .aggregated = aggregated,
    };
}
```

**Step 2: Commit**

```bash
git add src/memory/eval/runner.zig
git commit -m "feat(meta-harness): add eval runner that executes retrieval against benchmark"
```

---

### Task 5: Add eval results logger

**Objective:** Persist eval results to JSONL for the optimizer loop to read.

**Files:**
- Create: `src/memory/eval/logger.zig`

**Step 1: Implement results logger**

JSONL format — one JSON object per line:
```json
{"iteration":0,"timestamp":1744737600,"config_hash":"abc123","metrics":{"mean_recall_at_k":0.45,"mean_mrr":0.62,...},"config_json":"{\"max_results\":6,\"rrf_k\":60,...}"}
```

Implement `appendResult(allocator, path, result) !void` and `loadResults(allocator, path) ![]EvalResult`.

**Step 2: Commit**

```bash
git add src/memory/eval/logger.zig
git commit -m "feat(meta-harness): add JSONL results logger for eval history"
```

---

### Task 6: Add `nullclaw memory eval` CLI subcommand

**Objective:** Wire the eval infrastructure into the CLI.

**Files:**
- Modify: `src/main.zig` — add `eval` to the `memory` subcommand handler
- Modify: `src/memory/root.zig` — add eval module export

**Step 1: Add eval module to memory root**

In `src/memory/root.zig`, add:
```zig
pub const eval = @import("eval/types.zig");
pub const eval_runner = @import("eval/runner.zig");
pub const eval_benchmark = @import("eval/benchmark.zig");
pub const eval_logger = @import("eval/logger.zig");
```

**Step 2: Add memory eval subcommand**

In `src/main.zig`, inside the `runMemory` function, add handling for `eval` subcommand:

```
nullclaw memory eval <benchmark.json> [--k 6] [--output results.jsonl]
```

This loads the benchmark, initializes the retrieval engine from the current config, runs the eval, prints metrics summary, and optionally writes results to JSONL.

**Step 3: Build and test**

```bash
cd ~/dev/nullclaw && ~/.local/zig/zig build
./zig-out/bin/nullclaw memory eval benchmark.json
```

**Step 4: Commit**

```bash
git add src/main.zig src/memory/root.zig
git commit -m "feat(meta-harness): add 'nullclaw memory eval' CLI subcommand"
```

---

## Phase 2: Benchmark Generation

### Task 7: Add benchmark generator

**Objective:** Generate (query, expected_ids) pairs from existing memory store.

**Files:**
- Create: `src/memory/eval/generator.zig`
- Modify: `src/main.zig` — add `eval-generate` subcommand

**Step 1: Implement generator**

```
nullclaw memory eval-generate [--count 50] [--output benchmark.json]
```

Strategy:
1. Load all memories from the store via `memory.list(null, null)`
2. Sample N memories (or use all if < N)
3. For each sampled memory, use the LLM to generate 1-3 natural language queries that should retrieve it
4. Build entries with the memory's ID as the expected result
5. Deduplicate queries (similar queries get merged with multiple expected_ids)
6. Split into train (80%) and test (20%) sets
7. Write to JSON

The generator uses the existing model routing (same LLM config the agent uses) to synthesize queries. No API key changes needed.

**Step 2: Commit**

```bash
git add src/memory/eval/generator.zig src/main.zig
git commit -m "feat(meta-harness): add benchmark generator from existing memory store"
```

---

## Phase 3: Optimizer Loop

### Task 8: Add LLM proposer

**Objective:** An LLM reads eval history and proposes new retrieval configs.

**Files:**
- Create: `src/memory/eval/proposer.zig`

**Step 1: Implement proposer**

The proposer takes:
- Current config JSON
- Last N eval results (config + metrics)
- Benchmark description

It calls the LLM with a system prompt that explains the retrieval pipeline stages and their knobs, then asks it to propose the next config. The LLM returns JSON with the proposed config.

Key design: the proposer only changes `MemoryQueryConfig` and `MemoryRetrievalStagesConfig` fields — it never touches backend config or security settings. This is a narrow, safe surface.

**Step 2: Commit**

```bash
git add src/memory/eval/proposer.zig
git commit -m "feat(meta-harness): add LLM proposer for config optimization"
```

---

### Task 9: Add `nullclaw memory eval-optimize` CLI subcommand

**Objective:** Wire the full optimize loop: eval → propose → reconfig → eval → repeat.

**Files:**
- Modify: `src/main.zig`

**Step 1: Add eval-optimize subcommand**

```
nullclaw memory eval-optimize <benchmark.json> [--iterations 10] [--k 6]
```

Loop:
1. Load benchmark
2. For i in 0..iterations:
   a. Create RetrievalEngine with current config
   b. Run eval, compute metrics
   c. Log result
   d. Print metrics summary
   e. If i < iterations - 1: call proposer with history, get new config
   f. Apply new config to next iteration
3. Print final summary: best config, improvement delta

**Step 2: Commit**

```bash
git add src/main.zig
git commit -m "feat(meta-harness): add 'nullclaw memory eval-optimize' optimization loop"
```

---

## Phase 4: Testing

### Task 10: Add eval unit tests

**Objective:** Test metrics computation with known inputs.

**Files:**
- Create: `src/memory/eval/metrics.zig` (add tests at bottom)

**Step 1: Write tests**

```zig
test "perfect recall — all expected IDs retrieved" { ... }
test "zero recall — no expected IDs retrieved" { ... }
test "partial recall — some expected IDs retrieved" { ... }
test "MRR — first result is relevant" { ... }
test "MRR — relevant result at rank 3" { ... }
test "nDCG with weighted relevance" { ... }
test "aggregate over empty query set" { ... }
test "aggregate over single query" { ... }
```

**Step 2: Run tests**

```bash
cd ~/dev/nullclaw && ~/.local/zig/zig build test
```

**Step 3: Commit**

```bash
git add src/memory/eval/metrics.zig
git commit -m "test(meta-harness): add unit tests for metrics computation"
```

---

### Task 11: Integration test with in-memory store

**Objective:** Test the full eval pipeline with a synthetic memory store.

**Files:**
- Modify: `src/memory/eval/runner.zig` (add integration test)

**Step 1: Write integration test**

Use `memory_lru` engine (no disk), store 10 entries, create a 5-query benchmark, run eval, verify metrics.

**Step 2: Run tests**

```bash
cd ~/dev/nullclaw && ~/.local/zig/zig build test
```

**Step 3: Commit**

```bash
git add src/memory/eval/runner.zig
git commit -m "test(meta-harness): add integration test with in-memory store"
```

---

## File Summary

| File | Action | Phase |
|------|--------|-------|
| `src/memory/eval/types.zig` | Create | 1 |
| `src/memory/eval/metrics.zig` | Create | 1 |
| `src/memory/eval/benchmark.zig` | Create | 1 |
| `src/memory/eval/runner.zig` | Create | 1 |
| `src/memory/eval/logger.zig` | Create | 1 |
| `src/memory/eval/generator.zig` | Create | 2 |
| `src/memory/eval/proposer.zig` | Create | 3 |
| `src/memory/root.zig` | Modify (add eval exports) | 1 |
| `src/main.zig` | Modify (add eval/eval-generate/eval-optimize subcmds) | 1-3 |

## Verification

After all tasks:

```bash
# Build
cd ~/dev/nullclaw && ~/.local/zig/zig build

# Run tests
~/.local/zig/zig build test

# Generate benchmark from existing memory
./zig-out/bin/nullclaw memory eval-generate --count 20 --output test_bench.json

# Run eval with current config
./zig-out/bin/nullclaw memory eval test_bench.json --k 6

# Run optimization loop
./zig-out/bin/nullclaw memory eval-optimize test_bench.json --iterations 5 --k 6
```

Expected: eval prints metrics summary, optimize loops and reports improving (or stable) metrics across iterations.
