# Tool Call Logging - Implementation Guide

## Overview
Tool call logging has been added to the dispatcher to help with debugging, testing, and analytics. This allows you to see exactly what tool calls the LLM is generating and how they're being parsed.

## What Gets Logged

### 1. MiniMax Format Tool Calls
```
[dispatcher] DEBUG: Detected MiniMax tool call (format: colon)
[dispatcher] DEBUG: Raw MiniMax content: {"name": "web_fetch">
[dispatcher] INFO: ✓ Parsed MiniMax tool call: name='web_fetch' args='{"max_chars":8000}'
```

### 2. Native OpenAI Format Tool Calls
```
[dispatcher] DEBUG: Detected native OpenAI tool call format
[dispatcher] DEBUG: Raw native response: {"tool_calls":[{"type":"function",...}]}
[dispatcher] INFO: ✓ Parsed native tool call: name='web_search' args='{"query":"test"}' id=call_abc123
```

## How to Enable Logging

### Method 1: Environment Variable
```bash
NULLCLAW_LOG=debug ./zig-out/bin/nullclaw gateway
```

### Method 2: Log Levels
- `debug`: Shows raw tool call content (verbose)
- `info`: Shows parsed tool calls (normal)
- `warn`: Shows only parsing failures (quiet)

### Method 3: Log to File
```bash
NULLCLAW_LOG=debug ./zig-out/bin/nullclaw gateway > /tmp/nullclaw_debug.log 2>&1
```

## Extracting Tool Calls for Testing

Use the provided script to extract tool calls from logs:

```bash
# Extract from default log location
./extract_tool_calls.sh

# Extract from specific log file
./extract_tool_calls.sh /tmp/nullclaw_debug.log
```

This creates two files in `test_results/tool_calls/`:
- `minimax_examples.txt` - Raw MiniMax format examples
- `native_examples.txt` - Raw OpenAI format examples

## Use Cases

### 1. Debugging Parse Failures
When a tool call isn't being parsed correctly:
```bash
# Enable debug logging
NULLCLAW_LOG=debug ./zig-out/bin/nullclaw gateway

# Look for:
# - "Detected MiniMax tool call" - was it detected?
# - "Raw MiniMax content" - what was the raw format?
# - "Failed to parse" - what went wrong?
```

### 2. Creating Test Cases
Extract real examples from logs:
```bash
./extract_tool_calls.sh

# Use the extracted examples in tests:
# test_minimax_comprehensive.zig
# test_dispatcher_integration.zig
```

### 3. Analytics
Track which tools are used most:
```bash
grep "Parsed.*tool call" /tmp/nullclaw_gateway.log | \
  sed 's/.*name='\''//' | sed 's/'\''.*$//' | \
  sort | uniq -c | sort -rn
```

### 4. Regression Testing
Save log snapshots and compare:
```bash
# Save baseline
cp /tmp/nullclaw_gateway.log test_results/tool_calls/baseline.log

# After changes, compare
diff test_results/tool_calls/baseline.log /tmp/nullclaw_gateway.log
```

## Log Format Examples

### Successful Parse
```
[dispatcher] DEBUG: Detected MiniMax tool call (format: colon)
[dispatcher] DEBUG: Raw MiniMax content: {"name": "web_fetch">
<parameter name="max_chars">8000</parameter>
</invoke>
</minimax:tool_call>
[dispatcher] INFO: ✓ Parsed MiniMax tool call: name='web_fetch' args='<parameter name="max_chars">8000</parameter>'
```

### Failed Parse
```
[dispatcher] DEBUG: Detected MiniMax tool call (format: equals)
[dispatcher] DEBUG: Raw MiniMax content: {"name=unknown_tool>
[dispatcher] WARN: Failed to parse MiniMax tool call: ToolNameNotFound
```

## Integration with Testing

The extracted examples can be used directly in tests:

```zig
const example =
    \\{"name": "web_fetch">
    \\<parameter name="max_chars">8000</parameter>
    \\</invoke>
    \\</minimax:tool_call>
;

const result = try testDispatcherMiniMaxParsing(allocator, example);
try testing.expectEqual(@as(usize, 1), result.tool_calls.items.len);
try testing.expectEqualStrings("web_fetch", result.tool_calls.items[0].name);
```

## Performance Impact

- **Debug logging**: Minimal impact (< 1% overhead)
- **Info logging**: Negligible impact
- **Disabled**: Zero impact

For production, use `info` or `warn` level to reduce log volume.

## Troubleshooting

### No logs appearing
```bash
# Check log level is set correctly
echo $NULLCLAW_LOG

# Verify logs are being written
tail -f /tmp/nullclaw_gateway.log
```

### Logs too verbose
```bash
# Use info level instead of debug
NULLCLAW_LOG=info ./zig-out/bin/nullclaw gateway
```

### Can't find specific tool call
```bash
# Grep for tool name
grep "name='web_search'" /tmp/nullclaw_gateway.log

# Grep for format type
grep "format: colon" /tmp/nullclaw_gateway.log
```

## Future Enhancements

Potential improvements:
1. Structured JSON logging for machine parsing
2. Tool call statistics dashboard
3. Automatic test case generation from logs
4. Tool call performance metrics
5. Integration with monitoring systems (Prometheus, etc.)
