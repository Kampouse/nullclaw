# Tool Call Deduplication Fix

## Problem
The MiniMax model was sometimes generating duplicate tool calls in a single response, causing the same request to be executed multiple times. For example:
```json
{"name": "web_fetch", "arguments": {"url": "..."}}
{"name": "web_fetch", "arguments": {"url": "..."}}
```

This would result in:
- Wasteful duplicate HTTP requests
- Slower response times
- Unnecessary API calls

## Solution
Added deduplication logic in `src/agent/dispatcher.zig` to track and skip duplicate tool calls.

### Implementation

**Tracking:**
- Uses `StringHashMap` to track seen tool calls
- Key format: `{tool_name}|{arguments_json}`
- Exact match required (name AND arguments must be identical)

**Detection:**
```zig
// Before appending a tool call, check if it's a duplicate
if (!isDuplicate.check(allocator, &seen_calls, call)) {
    try isDuplicate.mark(allocator, &seen_calls, call);
    try calls.append(allocator, call);
} else {
    log.warn("Skipping duplicate tool call: name='{s}' args='{s}'", ...);
}
```

**Applied to all 8 tool call append locations:**
1. Valid JSON format (`{"name": "tool", "arguments": {...}}`)
2. Malformed JSON format (`{"name="tool", "arguments": {...}}`)
3. MiniMax format with tags (`{"name": "tool">...</minimax:tool_call>`)
4. Native OpenAI format
5. XML-style formats
6. Other hybrid formats

## Behavior

### Before Fix
```
LLM Response:
{"name": "web_fetch", "arguments": {"url": "..."}}
{"name": "web_fetch", "arguments": {"url": "..."}}

Result:
- Request 1 sent to web_fetch
- Request 2 sent to web_fetch (duplicate!)
- Same data fetched twice
```

### After Fix
```
LLM Response:
{"name": "web_fetch", "arguments": {"url": "..."}}
{"name": "web_fetch", "arguments": {"url": "..."}}

Result:
- Request 1 sent to web_fetch
- Request 2 detected as duplicate, skipped
- Log: "Skipping duplicate tool call: name='web_fetch'"
- Data fetched once
```

## Logging

When duplicates are detected, you'll see:
```
[dispatcher] WARN: Skipping duplicate tool call: name='web_fetch' args='{"url":"..."}'
```

## Benefits

1. **Performance**: Eliminates wasteful duplicate HTTP requests
2. **Cost**: Reduces API usage for paid services
3. **Speed**: Faster responses (fewer requests to execute)
4. **Efficiency**: Prevents hammering external APIs

## Testing

To verify deduplication works:
1. Check logs for "Skipping duplicate tool call" messages
2. Monitor that only one request is made per unique tool call
3. Verify final answers are still correct

## Related Features

- Works with all 5 MiniMax format variants
- Does NOT affect legitimate different tool calls (same name, different args)
- Integrates with existing memory_store deduplication
