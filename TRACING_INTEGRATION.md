# Tracing Integration Guide

Quick guide to add tracing to NullClaw subsystems.

---

## Files Created

| File | Size | Purpose |
|------|------|---------|
| `src/trace.zig` | 16KB | Core tracing system |
| `src/trace_simple.zig` | 6KB | Simplified API |
| `docs/TRACING.md` | 8KB | Full documentation |
| `trace_example.sh` | 561B | Example script |

---

## Quick Integration

### 1. Add to main.zig

```zig
const trace = @import("trace_simple.zig");

pub fn main() !void {
    // Initialize tracing FIRST
    try trace.init(allocator, .info);
    defer trace.deinit();
    
    // Rest of your code...
}
```

### 2. Add to daemon.zig

```zig
const trace = @import("trace_simple.zig");

pub fn run(allocator: Allocator) !void {
    var span = (try trace.startSpan(.daemon, "run")) orelse return;
    defer span.end();
    
    trace.info(.daemon, "Starting daemon on port {}", .{port});
    
    // Your code...
}
```

### 3. Add to tools/shell.zig

```zig
const trace = @import("trace_simple.zig");

pub fn execute(allocator: Allocator, cmd: []const u8) ![]const u8 {
    var span = (try trace.startSpan(.tool_shell, "execute")) orelse return error.NoTracer;
    defer span.end();
    
    try span.setField("command", .{ .string = cmd });
    
    trace.debug(.tool_shell, "Executing: {s}", .{cmd});
    
    const result = runCommand(cmd) catch |err| {
        span.setError();
        trace.err(.tool_shell, "Failed: {}", .{err});
        return err;
    };
    
    return result;
}
```

### 4. Add to providers/openai.zig

```zig
const trace = @import("trace_simple.zig");

pub fn complete(self: *Self, messages: []Message) !Response {
    var span = (try trace.startSpan(.provider_openai, "complete")) orelse return error.NoTracer;
    defer span.end();
    
    try span.setField("model", .{ .string = self.model });
    
    const response = try self.sendRequest(messages);
    
    trace.info(.provider_openai, "Got response: {} tokens", .{response.tokens});
    
    return response;
}
```

---

## Subsystem Map

| File | Subsystem |
|------|-----------|
| `src/daemon.zig` | `.daemon` |
| `src/gateway.zig` | `.gateway` |
| `src/config.zig` | `.config` |
| `src/agent/dispatcher.zig` | `.agent_dispatcher` |
| `src/agent/routing.zig` | `.agent_routing` |
| `src/channel_loop.zig` | `.channel_loop` |
| `src/channels/telegram.zig` | `.channel_telegram` |
| `src/providers/openai.zig` | `.provider_openai` |
| `src/tools/shell.zig` | `.tool_shell` |
| `src/tools/file.zig` | `.tool_file` |
| `src/memory/*.zig` | `.memory_engine` |

---

## What Gets Traced

1. **Startup** - All initialization steps
2. **Messages** - Incoming/outgoing with timing
3. **API Calls** - Provider requests with duration
4. **Tool Execution** - Commands, file ops, etc.
5. **Errors** - Full context on failures
6. **Crashes** - Stack trace + active spans

---

## Output Example

```
[2026-03-10T15:30:45.123Z] [INFO] [daemon] Starting NullClay v1.0.0
[2026-03-10T15:30:45.125Z] [SPAN_START] [config] [span:1] load
[2026-03-10T15:30:45.130Z] [INFO] [config] [span:1] Loaded from config.json
[2026-03-10T15:30:45.135Z] [SPAN_END] [config] [span:1] [10.23ms] [ok] load
[2026-03-10T15:30:45.140Z] [SPAN_START] [agent_dispatcher] [span:2] process_message
[2026-03-10T15:30:45.145Z] [INFO] [agent_dispatcher] [span:2] Processing msg:12345
[2026-03-10T15:30:45.150Z] [SPAN_START] [provider_openai] [span:3] complete
[2026-03-10T15:30:46.200Z] [INFO] [provider_openai] [span:3] Response: 450 tokens
[2026-03-10T15:30:46.205Z] [SPAN_END] [provider_openai] [span:3] [1055.23ms] [ok] complete
[2026-03-10T15:30:46.210Z] [SPAN_END] [agent_dispatcher] [span:2] [1070.45ms] [ok] process_message
```

---

## Crash Report Example

```
================================================================================
CRASH DETECTED
================================================================================
Time: 2026-03-10T15:35:22.456Z
Message: index out of bounds

Active Spans:
  - [daemon] run (123456.78ms) [running]
  - [agent_dispatcher] process_message (567.89ms) [running]
  - [tool_shell] execute (234.56ms) [running]
    Fields: command="ls -la"

================================================================================
Stack Trace:
================================================================================
  0: 0x10a3b4c20
  1: 0x10a3b5d10
  2: 0x10a3c1000
================================================================================
```

---

## Testing

```bash
# Build with tracing
zig build

# Run with tracing
mkdir -p /tmp/trace
TRACE_FILE=/tmp/trace/test.log ./zig-out/bin/nullclaw daemon

# View trace
tail -f /tmp/trace/test.log

# Test crash handling
zig build test-trace
```

---

## Performance Impact

| Level | Overhead | Use Case |
|-------|----------|----------|
| `trace` | ~5% | Development |
| `debug` | ~2% | Debugging |
| `info` | <1% | Production |
| `warn` | <0.1% | Production |
| `err` | <0.1% | Production |

---

## Next Steps

1. **Add to main.zig** - Initialize tracer
2. **Wrap key functions** - Add spans to important operations
3. **Set fields** - Add context (msg IDs, user IDs, etc.)
4. **Test crash handling** - Verify crash reports work
5. **Deploy** - Enable in production with `info` level

---

## Full Documentation

See `docs/TRACING.md` for complete API reference.
