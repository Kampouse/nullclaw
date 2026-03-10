# NullClaw Tracing System

Structured logging and crash reporting for easier debugging.

---

## Quick Start

```zig
const trace = @import("trace_simple.zig");

pub fn main() !void {
    // Initialize tracer
    try trace.init(allocator, .debug);
    defer trace.deinit();
    
    // Simple logging
    trace.info(.daemon, "Starting daemon", .{});
    
    // With span (tracks timing)
    var span = (try trace.startSpan(.agent_dispatcher, "process_message")) orelse return;
    defer span.end();
    
    span.info("Processing message: {s}", .{msg_id});
    
    // Mark error if failed
    if (failed) {
        span.setError();
    }
}
```

---

## Subsystems

Each subsystem has its own trace channel:

| Subsystem | Description |
|-----------|-------------|
| `daemon` | Main daemon process |
| `gateway` | Gateway server |
| `config` | Configuration loading |
| `agent_core` | Agent core logic |
| `agent_dispatcher` | Message dispatcher |
| `agent_routing` | Routing logic |
| `channel_loop` | Message loop |
| `channel_manager` | Channel management |
| `channel_telegram` | Telegram adapter |
| `channel_discord` | Discord adapter |
| `provider_openai` | OpenAI provider |
| `provider_gemini` | Gemini provider |
| `tool_shell` | Shell tool |
| `tool_file` | File operations |
| `memory_engine` | Memory system |
| `security_policy` | Security checks |

---

## Log Levels

```zig
trace.trace(...)  // Very detailed
trace.debug(...)  // Debug information
trace.info(...)   // General information
trace.warn(...)   // Warnings
trace.err(...)    // Errors
trace.fatal(...)  // Fatal errors
```

---

## Spans

Spans track operations with timing:

```zig
// Start span
var span = (try trace.startSpan(.provider_openai, "api_call")) orelse return;
defer span.end();

// Add context
try span.setField("model", .{ .string = "gpt-4" });
try span.setField("tokens", .{ .int = 1500 });

// Log within span
span.info("Sending request", .{});

// Mark as error
span.setError();
```

### Scoped Spans

Auto-end when scope exits:

```zig
{
    var scoped = trace.ScopedSpan.init(.tool_shell, "execute_command");
    defer scoped.deinit();
    
    if (scoped.get()) |s| {
        s.info("Running: {s}", .{cmd});
    }
} // Auto-ends here
```

---

## Crash Reporting

Crashes automatically dump:

1. **Error message**
2. **Active spans** with timing
3. **Stack trace**
4. **Subsystem context**

Example crash log:

```
================================================================================
CRASH DETECTED
================================================================================
Time: 2026-03-10T15:30:45.123Z
Message: index out of bounds

Active Spans:
  - [daemon] main_loop (1234.56ms) [running]
  - [agent_dispatcher] process_message (567.89ms) [running]
  - [provider_openai] api_call (234.56ms) [running]

================================================================================
Stack Trace:
================================================================================
  0: 0x10a3b4c20
  1: 0x10a3b5d10
  2: 0x10a3c1000
================================================================================
```

---

## Integration Examples

### Daemon Startup

```zig
// src/daemon.zig

pub fn run(allocator: Allocator, config: Config) !void {
    // Initialize tracing
    try trace.initWithFile(allocator, .info, "nullclaw.log");
    defer trace.deinit();
    
    var main_span = (try trace.startSpan(.daemon, "startup")) orelse return;
    defer main_span.end();
    
    trace.info(.daemon, "Starting NullClaw v{}", .{version});
    
    // Load config
    var config_span = trace.ScopedSpan.init(.config, "load");
    if (config_span.get()) |s| {
        try loadConfig(config_path);
        s.info("Config loaded from {s}", .{config_path});
    }
    
    // Start gateway
    var gateway_span = trace.ScopedSpan.init(.gateway, "start");
    if (gateway_span.get()) |s| {
        try startGateway(config.gateway_port);
        s.info("Gateway listening on port {}", .{config.gateway_port});
    }
}
```

### Tool Execution

```zig
// src/tools/shell.zig

pub fn execute(allocator: Allocator, cmd: []const u8) ![]const u8 {
    var span = (try trace.startSpan(.tool_shell, "execute")) orelse return error.NoTracer;
    defer span.end();
    
    try span.setField("command", .{ .string = cmd });
    
    trace.debug(.tool_shell, "Executing: {s}", .{cmd});
    
    const result = runCommand(cmd) catch |err| {
        span.setError();
        trace.err(.tool_shell, "Command failed: {}", .{err});
        return err;
    };
    
    try span.setField("exit_code", .{ .int = result.exit_code });
    
    return result.output;
}
```

### Provider API Call

```zig
// src/providers/openai.zig

pub fn complete(self: *Self, messages: []Message) ![]const u8 {
    var span = (try trace.startSpan(.provider_openai, "chat_completion")) orelse return error.NoTracer;
    defer span.end();
    
    try span.setField("model", .{ .string = self.model });
    try span.setField("message_count", .{ .int = @intCast(messages.len) });
    
    trace.debug(.provider_openai, "Sending {} messages to {s}", .{ messages.len, self.model });
    
    const response = try self.sendRequest(messages);
    
    try span.setField("response_tokens", .{ .int = response.tokens });
    
    trace.info(.provider_openai, "Received response: {} tokens", .{response.tokens});
    
    return response.content;
}
```

### Message Dispatcher

```zig
// src/agent/dispatcher.zig

pub fn dispatch(self: *Self, message: Message) !Response {
    var span = (try trace.startSpan(.agent_dispatcher, "dispatch")) orelse return error.NoTracer;
    defer span.end();
    
    try span.setField("msg_id", .{ .string = message.id });
    try span.setField("channel", .{ .string = @tagName(message.channel) });
    
    trace.info(.agent_dispatcher, "Dispatching message from {s}", .{@tagName(message.channel)});
    
    // Route message
    const route = self.router.route(message.content) catch |err| {
        span.setError();
        trace.err(.agent_dispatcher, "Routing failed: {}", .{err});
        return err;
    };
    
    try span.setField("route", .{ .string = @tagName(route) });
    
    // Execute route
    const response = try self.execute(route, message);
    
    trace.info(.agent_dispatcher, "Response sent: {} chars", .{response.content.len});
    
    return response;
}
```

---

## Output Format

```
[2026-03-10T15:30:45.123Z] [INFO] [daemon] Starting NullClaw v1.0.0
[2026-03-10T15:30:45.125Z] [SPAN_START] [config] [span:1] load
[2026-03-10T15:30:45.130Z] [INFO] [config] [span:1] Config loaded from config.json
[2026-03-10T15:30:45.135Z] [SPAN_END] [config] [span:1] [10.23ms] [ok] load
[2026-03-10T15:30:45.140Z] [SPAN_START] [gateway] [span:2] start
[2026-03-10T15:30:45.145Z] [INFO] [gateway] [span:2] Gateway listening on port 8080
```

---

## Configuration

### Log Level

```zig
trace.init(allocator, .debug);  // All messages
trace.init(allocator, .info);   // Info and above
trace.init(allocator, .warn);   // Warnings and errors only
trace.init(allocator, .err);    // Errors only
```

### File Output

```zig
try trace.initWithFile(allocator, .debug, "/var/log/nullclaw.log");
```

### Multiple Outputs

```zig
// To both stderr and file
try trace.initWithFile(allocator, .debug, "nullclaw.log");
// stderr is automatic
```

---

## Best Practices

1. **Use spans for operations** - Wrap significant operations in spans
2. **Set fields** - Add context with `setField()`
3. **Mark errors** - Call `span.setError()` on failures
4. **Use appropriate levels** - Don't log everything as INFO
5. **Include IDs** - Always log message IDs, request IDs, etc.

---

## Performance

- **Minimal overhead** when level is INFO or higher
- **Zero allocation** for disabled log levels
- **Async-safe** - Can be called from any thread

---

## Testing

```bash
# Run trace tests
zig build test-trace

# Test crash handling
zig build test-crash
```

---

## Troubleshooting

### No output?

Check log level:
```zig
trace.init(allocator, .debug);  // Not .off
```

### Missing spans?

Make sure to call `span.end()`:
```zig
var span = try trace.startSpan(.daemon, "op");
defer span.end();  // Don't forget!
```

### Crashes not logged?

Ensure tracer is initialized:
```zig
try trace.init(allocator, .debug);  // Must be called first
```
