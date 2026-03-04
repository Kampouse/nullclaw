# Gork Integration Improvements

**Generated:** March 4, 2026
**Status:** Prioritized roadmap for production hardening

---

## 🔴 HIGH PRIORITY (Security & Reliability)

### 1. Complete Signature Verification ⚠️

**Current:** Signature file detected but not verified (TODO in code)
**Risk:** Binary could be tampered without detection
**Impact:** Security vulnerability

**Implementation:**
```zig
pub fn verifyBinarySignature(allocator: Allocator, binary_path: []const u8) SignatureVerification {
    const sig_path = std.fmt.allocPrint(allocator, "{s}.sig", .{binary_path}) catch return .verification_error;
    defer allocator.free(sig_path);

    // Read Ed25519 signature (64 bytes)
    const sig_file = std.fs.openFileAbsolute(sig_path, .{}) catch |err| {
        return if (err == error.FileNotFound) .not_found else .verification_error;
    };
    defer sig_file.close();

    var signature: [64]u8 = undefined;
    const bytes_read = sig_file.read(&signature) catch return .verification_error;
    if (bytes_read != 64) return .verification_error;

    // Compute SHA-256 of binary
    const hash = computeSha256(allocator, binary_path) catch return .verification_error;
    defer allocator.free(hash);

    // Verify with trusted public key
    const public_key: [32]u8 = .{...}; // Your Ed25519 public key
    std.crypto.sign.Ed25519.verify(signature, hash, public_key) catch return .invalid;

    return .verified;
}
```

**Effort:** 2-3 hours
**Files:** `src/gork_hybrid.zig`

---

### 2. Add Memory Leak Detection Tests 🧪

**Current:** No automated leak detection
**Risk:** Memory leaks could go undetected
**Impact:** Long-running process stability

**Implementation:**
Create `src/gork_memory_test.zig`:

```zig
const std = @import("std");
const hybrid_mod = @import("gork_hybrid.zig");

test "Hybrid: no memory leaks on init/deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = hybrid_mod.Config{};
    var hybrid = try hybrid_mod.Hybrid.init(allocator, config, dummyCallback);
    hybrid.start() catch {};
    hybrid.stop();
}

test "Hybrid: no leaks under stress (100 cycles)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = hybrid_mod.Config{};

    for (0..100) |_| {
        var h = try hybrid_mod.Hybrid.init(allocator, config, dummyCallback);
        h.start() catch {};
        h.stop();
    }
}

test "Hybrid: no leaks on error paths" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = hybrid_mod.Config{};

    // Test error paths
    var h1 = try hybrid_mod.Hybrid.init(allocator, config, dummyCallback);
    _ = h1.sendMessage("invalid@id", "test") catch {}; // Should fail validation
    h1.stop();

    var h2 = try hybrid_mod.Hybrid.init(allocator, config, dummyCallback);
    _ = h2.sendMessage("valid.near", "x" ** 20000) catch {}; // Should fail length check
    h2.stop();
}

fn dummyCallback(alloc: std.mem.Allocator, event: hybrid_mod.Event) void {
    defer event.deinit(alloc);
}
```

**Effort:** 1-2 hours
**Files:** `src/gork_memory_test.zig` (new)

---

## 🟡 MEDIUM PRIORITY (Observability & DX)

### 3. Add Detailed Metrics Collection 📊

**Current:** Basic counters only
**Gap:** No performance insights, hard to debug issues
**Impact:** Operational blind spots

**Implementation:**
```zig
// In gork_hybrid.zig

pub const DetailedMetrics = struct {
    // Existing
    messages_sent: std.atomic.Value(u64),
    messages_failed: std.atomic.Value(u64),
    circuit_breaker_trips: std.atomic.Value(u64),

    // New
    avg_latency_ms: std.atomic.Value(u64),
    peak_memory_kb: std.atomic.Value(u64),
    active_connections: std.atomic.Value(u32),
    cache_hits: std.atomic.Value(u64),
    cache_misses: std.atomic.Value(u64),
    last_error: ?[]const u8, // Owned
    last_error_time: i64,

    pub fn cacheHitRate(self: *const DetailedMetrics) f32 {
        const hits = @as(f64, @floatFromInt(self.cache_hits.load(.seq_cst)));
        const misses = @as(f64, @floatFromInt(self.cache_misses.load(.seq_cst)));
        const total = hits + misses;
        return if (total > 0) @floatCast(hits / total) else 0.0;
    }

    pub fn toJson(self: *const DetailedMetrics, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\{{
            \\  "messages_sent": {},
            \\  "messages_failed": {},
            \\  "circuit_breaker_trips": {},
            \\  "avg_latency_ms": {},
            \\  "peak_memory_kb": {},
            \\  "active_connections": {},
            \\  "cache_hit_rate": {d:.2}
            \\}}
        , .{
            self.messages_sent.load(.seq_cst),
            self.messages_failed.load(.seq_cst),
            self.circuit_breaker_trips.load(.seq_cst),
            self.avg_latency_ms.load(.seq_cst),
            self.peak_memory_kb.load(.seq_cst),
            self.active_connections.load(.seq_cst),
            self.cacheHitRate(),
        });
    }
};
```

**Usage in sendMessage:**
```zig
const start_time = std.time.nanoTimestamp();
// ... send message ...
const elapsed_ns = std.time.nanoTimestamp() - start_time;
const elapsed_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);

// Update rolling average
const current_avg = self.metrics.avg_latency_ms.load(.seq_cst);
const new_avg = (current_avg * 9 + elapsed_ms) / 10;
_ = self.metrics.avg_latency_ms.store(new_avg, .seq_cst);
```

**Effort:** 2-3 hours
**Files:** `src/gork_hybrid.zig`

---

### 4. Improve Error Messages 💬

**Current:** Generic errors like "DaemonNotRunning"
**Gap:** No actionable guidance
**Impact:** Poor developer experience

**Implementation:**
```zig
pub const DetailedError = struct {
    code: anyerror,
    message: []const u8,
    context: []const u8,
    suggested_action: []const u8,
    timestamp: i64,

    pub fn format(self: *const DetailedError, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\Error: {}
            \\Context: {s}
            \\Action: {s}
            \\Time: {}
        , .{
            self.code,
            self.context,
            self.suggested_action,
            self.timestamp,
        });
    }
};

// In sendMessage:
if (daemon == null) {
    const detailed = DetailedError{
        .code = error.DaemonNotRunning,
        .message = "Daemon process not running",
        .context = "Cannot send message via P2P network",
        .suggested_action = "Start daemon: gork-agent daemon --port 4001",
        .timestamp = std.time.nanoTimestamp(),
    };
    const msg = try detailed.format(self.allocator);
    defer self.allocator.free(msg);
    logAudit(.daemon_error, msg);
    return error.DaemonNotRunning;
}
```

**Effort:** 1-2 hours
**Files:** `src/gork_hybrid.zig`

---

### 5. Add Configuration Validation ✅

**Current:** Config fields not validated
**Risk:** Invalid configs cause runtime errors
**Impact:** Reliability

**Implementation:**
```zig
// In gork_hybrid.zig, add to Config:

pub fn validate(self: *const Config) !void {
    // Required fields
    if (self.binary_path.len == 0) return error.BinaryPathEmpty;

    // Range checks
    if (self.max_message_queue_size > 10000) return error.QueueSizeTooLarge;
    if (self.circuit_breaker_threshold == 0) return error.InvalidCircuitBreakerThreshold;
    if (self.circuit_breaker_threshold > 100) return error.CircuitBreakerThresholdTooHigh;

    // Binary existence
    std.fs.accessAbsolute(self.binary_path, .{}) catch return error.BinaryNotFound;

    // Interval checks
    if (self.poll_interval_secs < 5) {
        std.log.warn("Poll interval {}s is too low, minimum is 5s", .{self.poll_interval_secs});
        return error.PollIntervalTooShort;
    }
    if (self.poll_interval_secs > 3600) {
        std.log.warn("Poll interval {}s is very high, messages will be delayed", .{self.poll_interval_secs});
    }

    // Cache size
    if (self.seen_message_cache_size < 100) return error.CacheSizeTooSmall;
    if (self.max_message_age_secs < 60) return error.MessageAgeLimitTooShort;
}

// In Hybrid.init:
pub fn init(allocator: Allocator, config: Config, event_callback: *const fn (Allocator, Event) void) !Hybrid {
    try config.validate(); // Add this line
    // ... rest of init
}
```

**Effort:** 1 hour
**Files:** `src/gork_hybrid.zig`

---

## 🟢 LOW PRIORITY (Optimization)

### 6. Pool ArrayList Instances 🏊

**Current:** New ArrayList allocated per operation
**Gap:** Unnecessary allocations
**Impact:** Performance (minor)

**Implementation:**
```zig
const ArrayListPool = struct {
    mutex: std.Thread.Mutex,
    available: std.ArrayList(*std.ArrayList([]const u8)),

    pub fn init(allocator: Allocator) ArrayListPool {
        return .{
            .mutex = .{},
            .available = std.ArrayList(*std.ArrayList([]const u8)).initCapacity(allocator, 10) catch @panic("OOM"),
        };
    }

    pub fn acquire(self: *ArrayListPool, allocator: Allocator) *std.ArrayList([]const u8) {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.available.items.len > 0) {
            return self.available.pop();
        }

        const list = allocator.create(std.ArrayList([]const u8)) catch @panic("OOM");
        list.* = std.ArrayList([]const u8).initCapacity(allocator, 10) catch @panic("OOM");
        return list;
    }

    pub fn release(self: *ArrayListPool, list: *std.ArrayList([]const u8)) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        list.clearRetainingCapacity();
        self.available.append(list) catch {
            list.deinit(list.allocator);
            allocator.destroy(list);
        };
    }
};
```

**Effort:** 2-3 hours
**Files:** `src/gork_hybrid.zig`
**Impact:** ~5-10% reduction in allocations

---

### 7. Add Integration Tests with Real Binary 🧪

**Current:** Unit tests only, no integration tests
**Gap:** Not tested with actual gork-agent binary
**Impact:** Confidence in real-world usage

**Implementation:**
Create `src/gork_integration_test.zig`:

```zig
const std = @import("std");
const hybrid_mod = @import("gork_hybrid.zig");

test "Integration: start/stop with real binary" {
    if (std.os.getenv("SKIP_INTEGRATION_TESTS") != null) return error.SkipZigTest;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = hybrid_mod.Config{
        .binary_path = "/usr/local/bin/gork-agent", // Real binary
    };

    var hybrid = try hybrid_mod.Hybrid.init(allocator, config, eventCallback);
    try hybrid.start();

    // Wait for startup
    std.Thread.sleep(2 * std.time.ns_per_s);

    hybrid.stop();
}

test "Integration: send message to real daemon" {
    if (std.os.getenv("SKIP_INTEGRATION_TESTS") != null) return error.SkipZigTest;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expectEqual(.ok, leaked);
    }
    const allocator = gpa.allocator();

    var config = hybrid_mod.Config{
        .binary_path = "/usr/local/bin/gork-agent",
    };

    var hybrid = try hybrid_mod.Hybrid.init(allocator, config, eventCallback);
    try hybrid.start();
    defer hybrid.stop();

    // Try sending a message (will fail if no peers, but shouldn't crash)
    const result = hybrid.sendMessage("test.near", "integration test message");
    try std.testing.expect(result != error.DaemonNotRunning);
}

fn eventCallback(allocator: std.mem.Allocator, event: hybrid_mod.Event) void {
    defer event.deinit(allocator);
    std.log.info("Event: {}", .{event});
}
```

**Run with:**
```bash
zig build test
# Or skip integration tests:
SKIP_INTEGRATION_TESTS=1 zig build test
```

**Effort:** 2 hours
**Files:** `src/gork_integration_test.zig` (new)

---

## Implementation Order

**Week 1: Security & Reliability**
1. ✅ Complete signature verification (HIGH)
2. ✅ Add memory leak tests (HIGH)
3. ✅ Add config validation (MEDIUM)

**Week 2: Observability**
4. ✅ Add detailed metrics (MEDIUM)
5. ✅ Improve error messages (MEDIUM)

**Week 3: Optimization**
6. ✅ Pool ArrayList instances (LOW)
7. ✅ Add integration tests (LOW)

---

## Expected Impact

| Improvement | Effort | Impact | Risk Reduction |
|-------------|--------|--------|----------------|
| Signature verification | 2-3h | HIGH | Security vulnerability closed |
| Memory leak tests | 1-2h | HIGH | Detect leaks early |
| Config validation | 1h | MEDIUM | Prevent misconfigurations |
| Detailed metrics | 2-3h | MEDIUM | Operational visibility |
| Error messages | 1-2h | MEDIUM | Better debugging |
| ArrayList pooling | 2-3h | LOW | Minor performance gain |
| Integration tests | 2h | MEDIUM | Real-world confidence |

**Total effort:** ~12-15 hours
**ROI:** High (security + reliability + observability)

---

## Next Steps

1. **Pick high-priority items** (1-2 per week)
2. **Run tests after each change**
3. **Update documentation**
4. **Consider adding benchmarks** (optional)

Would you like me to implement any of these improvements?
