# Tracy Profiler Integration Analysis

## Current State (March 13, 2026)

### ✅ What's Working

**1. Basic Integration**
- Tracy module integrated via `zig-tracy` dependency
- Build flag `-Dtracy=true` enables profiling
- Zero-overhead when disabled (compile-time no-ops)
- Wrapper module in `src/profiling.zig`

**2. Current Usage**
- Memory retrieval engine (2 zones)
- Vector embeddings (1 zone)
- Vector math operations

**3. Build Configuration**
- Optional Tracy dependency in `build.zig`
- Module imports correctly configured
- Start script (`start_tracy.sh`) for easy profiling

---

## 🔍 Gaps & Issues

### 1. **Limited Coverage**
**Problem:** Only 3 zones in memory subsystem

**Missing profiling in:**
- ❌ Session management (critical path)
- ❌ Provider API calls (HTTP requests)
- ❌ Channel polling loops (Telegram, Discord, etc.)
- ❌ Memory lifecycle consolidation
- ❌ Tool execution
- ❌ Message routing/dispatch

**Impact:** Can't see where 90% of time is spent

---

### 2. **No Memory Tracking**
**Problem:** Tracy has memory profiling, but it's not used

**Missing:**
- ❌ Allocation tracking (TracingAllocator not used)
- ❌ Memory pressure monitoring
- ❌ Leak detection integration

**Current code:**
```zig
// profiling.zig has TracingAllocator but it's never used
pub const TracingAllocator = struct {
    child_allocator: std.mem.Allocator,
    // ...
};
```

---

### 3. **No Frame Markers**
**Problem:** No frame boundaries defined

**Missing:**
- ❌ Per-message processing frames
- ❌ Channel poll cycle frames
- ❌ Consolidation cycle frames

**Impact:** Can't measure message latency or throughput

---

### 4. **No Plots/Metrics**
**Problem:** No numeric metrics tracked

**Missing:**
- ❌ Message queue depth
- ❌ Active sessions count
- ❌ Memory usage over time
- ❌ Provider latency
- ❌ Error rates

---

### 5. **No GPU/Memory Profiling**
**Problem:** Tracy supports GPU zones, but not used

**Missing:**
- ❌ GPU memory tracking (if using GPU)
- ❌ Lock contention profiling
- ❌ Context switch tracking

---

### 6. **Startup Script Issues**
**Problem:** `start_tracy.sh` has issues

```bash
# Issues:
1. Uses nix-shell (not everyone has Nix)
2. Hardcoded `gateway` command
3. Kills Tracy on exit (inconvenient for multi-runs)
4. No control over Tracy options
```

---

## 🎯 Improvement Plan

### Phase 1: Critical Path Profiling (HIGH PRIORITY)

#### 1.1 Session Management

**File:** `src/session.zig`

```zig
const profiling = @import("profiling.zig");

pub fn processMessageStreaming(...) ![]const u8 {
    const zone = profiling.zoneNamed(@src(), "processMessage");
    defer zone.end();
    
    // Track session hash for correlation
    zone.text("session:{}", .{session_hash});
    
    // ... existing code
}

pub fn getOrCreateSession(...) !*Session {
    const zone = profiling.zoneNamed(@src(), "getOrCreateSession");
    defer zone.end();
    
    // ... existing code
}
```

**Benefit:** See message processing latency

---

#### 1.2 Provider Calls

**Files:** `src/providers/*.zig`

```zig
// In each provider (anthropic.zig, openai.zig, etc.)

pub fn complete(...) ![]const u8 {
    const zone = profiling.zoneNamed(@src(), "provider_complete");
    defer zone.end();
    
    zone.text("provider:{}", .{provider_name});
    
    // Track HTTP request time
    const start = std.time.nanoTimestamp();
    const response = try http_request(...);
    const elapsed = std.time.nanoTimestamp() - start;
    
    // Plot latency
    profiling.plot("provider_latency_ns", elapsed);
    
    return response;
}
```

**Benefit:** Identify slow providers

---

#### 1.3 Channel Polling

**Files:** `src/channels/telegram.zig`, `src/channels/discord.zig`, etc.

```zig
pub fn pollUpdates(...) ![]ChannelMessage {
    const zone = profiling.zoneNamed(@src(), "channel_poll");
    defer zone.end();
    
    // Mark frame boundary for this channel
    profiling.frameMarkNamed("telegram_poll");
    
    // ... existing code
    
    // Plot queue depth
    profiling.plot("telegram_queue_depth", messages.len);
}
```

**Benefit:** Track channel performance

---

### Phase 2: Memory Profiling (MEDIUM PRIORITY)

#### 2.1 Wrap GPA with Tracy

**File:** `src/main.zig`

```zig
const profiling = @import("profiling.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    // Wrap with Tracy tracking
    var tracy_alloc = profiling.alloc(gpa.allocator());
    const allocator = tracy_alloc.allocator();
    
    // ... rest of main
}
```

**Benefit:** See all allocations in Tracy

---

#### 2.2 Track Memory Pools

**File:** `src/session.zig`

```zig
pub fn processMessage(...) {
    // Track session memory
    const mem_before = allocator.queryCapacity();
    
    // ... process
    
    const mem_after = allocator.queryCapacity();
    profiling.plot("session_memory_bytes", mem_after - mem_before);
}
```

---

### Phase 3: Metrics & Plots (MEDIUM PRIORITY)

#### 3.1 System Metrics

**File:** `src/profiling.zig` (add new functions)

```zig
/// Track system metrics periodically
pub fn trackSystemMetrics() void {
    // These could be called from a background thread
    profiling.plot("active_sessions", sessions.count());
    profiling.plot("pending_messages", message_queue.len);
    profiling.plot("memory_total_bytes", getMemoryUsage());
    profiling.plot("goroutines", getGoroutineCount());
}
```

---

#### 3.2 Error Tracking

```zig
/// Track errors with Tracy
pub fn trackError(error_type: []const u8, err: anyerror) void {
    profiling.messageColor("ERROR {}: {}", .{ error_type, err }, 0xFF0000);
    profiling.plot("error_count", @as(u64, 1));
}
```

---

### Phase 4: Advanced Features (LOW PRIORITY)

#### 4.1 Lock Contention

```zig
const profiling = @import("profiling.zig");

pub const ProfiledMutex = struct {
    mutex: std.Thread.Mutex,
    
    pub fn lock(self: *ProfiledMutex) void {
        const zone = profiling.zoneNamed(@src(), "lock_wait");
        defer zone.end();
        
        self.mutex.lock();
    }
    
    pub fn unlock(self: *ProfiledMutex) void {
        self.mutex.unlock();
    }
};
```

---

#### 4.2 Consolidation Profiling

**File:** `src/memory/lifecycle/consolidation.zig`

```zig
pub fn runConsolidation(...) void {
    const zone = profiling.zoneNamed(@src(), "consolidation_cycle");
    defer zone.end();
    
    profiling.frameMarkNamed("consolidation");
    
    // Track each phase
    {
        const phase = profiling.zoneNamed(@src(), "consolidation_extract");
        defer phase.end();
        // extract patterns
    }
    
    {
        const phase = profiling.zoneNamed(@src(), "consolidation_train");
        defer phase.end();
        // train model
    }
    
    profiling.plot("consolidation_samples", samples.len);
}
```

---

## 🔧 Startup Script Improvements

### Improved `start_tracy.sh`

```bash
#!/bin/bash
# Enhanced Tracy launcher with better control

set -e

# Configuration
TRACY_PORT="${TRACY_PORT:-8086}"
NULLCLAW_CMD="${NULLCLAW_CMD:-gateway}"
BUILD_MODE="${BUILD_MODE:-Debug}"
TRACY_OPTS="${TRACY_OPTS:-}"

echo "🚀 Tracy Profiler + nullclaw"
echo "============================"
echo ""

# Check dependencies
if ! command -v tracy &> /dev/null; then
    echo "❌ Tracy not found. Install with:"
    echo "   macOS: brew install tracy"
    echo "   Linux: cargo install tracy-client"
    exit 1
fi

# Start Tracy (detached)
if ! pgrep -f "tracy" > /dev/null; then
    echo "📊 Starting Tracy Profiler (port $TRACY_PORT)..."
    tracy $TRACY_OPTS &
    TRACY_PID=$!
    echo "   PID: $TRACY_PID"
    sleep 2
else
    echo "✅ Tracy already running"
fi

# Build with Tracy
echo "🔨 Building nullclaw with Tracy ($BUILD_MODE)..."
zig build -Dtracy=true -Doptimize=$BUILD_MODE

# Run nullclaw
echo "🤖 Running: nullclaw $NULLCLAW_CMD"
echo ""

if [ -n "$TRACY_PID" ]; then
    # Trap to keep Tracy alive
    trap 'echo ""; echo "✅ nullclaw exited. Tracy still running (PID $TRACY_PID)"; echo "Kill with: kill $TRACY_PID"' EXIT
fi

./zig-out/bin/nullclaw $NULLCLAW_CMD
```

**Usage:**
```bash
# Basic
./start_tracy.sh

# Custom command
NULLCLAW_CMD="daemon --port 4001" ./start_tracy.sh

# Release mode
BUILD_MODE=ReleaseFast ./start_tracy.sh

# Keep Tracy after exit
KEEP_TRACY=1 ./start_tracy.sh
```

---

## 📊 Recommended Zones (Priority Order)

### Tier 1: Critical (Must Have)

| Zone | File | Why |
|------|------|-----|
| `processMessage` | `session.zig` | Message latency |
| `provider_complete` | `providers/*.zig` | API call time |
| `channel_poll` | `channels/*.zig` | Poll latency |
| `http_request` | `http_util.zig` | Network time |

### Tier 2: Important (Should Have)

| Zone | File | Why |
|------|------|-----|
| `consolidation_cycle` | `consolidation.zig` | RL training time |
| `memory_retrieval` | `retrieval/engine.zig` | Query time |
| `embedding_generate` | `embeddings.zig` | Embed latency |
| `tool_execute` | `tools/*.zig` | Tool time |

### Tier 3: Nice to Have

| Zone | File | Why |
|------|------|-----|
| `session_create` | `session.zig` | Session init |
| `route_resolve` | `agent_routing.zig` | Routing time |
| `memory_store` | `memory/*.zig` | Write time |
| `lock_contention` | `*.zig` | Mutex wait |

---

## 📈 Expected Benefits

### After Phase 1 (Critical Path)
- ✅ Identify slow providers
- ✅ Measure message latency
- ✅ Find channel bottlenecks
- ✅ Correlate issues with sessions

### After Phase 2 (Memory)
- ✅ Detect memory leaks
- ✅ Track allocation hot paths
- ✅ Optimize memory usage
- ✅ Identify large allocations

### After Phase 3 (Metrics)
- ✅ Real-time dashboards
- ✅ Capacity planning
- ✅ Performance regression detection
- ✅ Alert on anomalies

### After Phase 4 (Advanced)
- ✅ Lock contention analysis
- ✅ Consolidation optimization
- ✅ GPU profiling (if used)
- ✅ Multi-thread analysis

---

## 🚀 Quick Start Implementation

### Step 1: Add Critical Zones (30 min)

```bash
# Add to top files
src/session.zig
src/providers/anthropic.zig
src/channels/telegram.zig
```

### Step 2: Enable Memory Tracking (15 min)

```bash
# Wrap GPA in main.zig
```

### Step 3: Add Frame Markers (10 min)

```bash
# In main loop
profiling.frameMark();
```

### Step 4: Test (5 min)

```bash
./start_tracy.sh
# Run some messages
# Check Tracy UI
```

---

## 📚 Resources

- **Tracy Manual:** `vendor/tracy/manual/tracy.tex` (PDF available)
- **Tracy Examples:** `vendor/tracy/profiler/src/profiler/`
- **Zig-Tracy Docs:** `lib/zig-tracy/README.md`
- **Current Integration:** `src/profiling.zig`

---

## ✅ Summary

**Current:** Basic Tracy integration (3 zones in memory subsystem)

**Recommended:**
1. Add 20-30 zones in critical paths
2. Enable memory tracking
3. Add frame markers for message processing
4. Plot system metrics
5. Improve startup script

**Expected Outcome:**
- 10x better visibility into performance
- Identify bottlenecks in minutes vs hours
- Detect memory leaks automatically
- Real-time performance monitoring

**Time Investment:**
- Phase 1: 1-2 hours
- Phase 2: 30 min
- Phase 3: 1 hour
- Phase 4: 2-3 hours

**Total:** ~5 hours for complete integration

---

**Status:** Analysis complete, ready for implementation
**Priority:** HIGH (significant performance insights)
