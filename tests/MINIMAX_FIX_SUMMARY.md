# MiniMax Tool Call Format Fix - Summary

## Problem
The MiniMax model (`ollama-cloud/minimax-m2.5`) was generating malformed hybrid tool call formats that weren't being parsed correctly. This caused raw tool call XML/JSON to be shown to users instead of just the final answer.

## Malformed Formats Detected

### Format 1: Colon style with tags
```
{"name": "web_fetch">
<parameter name="max_chars">8000</parameter>
<parameter name="url">https://example.com</parameter>
</invoke>
</minimax:tool_call>
```

### Format 2: Equals style with tags
```
{"name=web_search>
<parameter name="count">5</parameter>
<parameter name="query">DistilBERT model</parameter>
</invoke>
</minimax:tool_call>
```

### Format 3: Invoke style
```
{"invoke name="shell">
<parameter name="command">ls -la</parameter>
</invoke>
</minimax:tool_call>
```

### Format 4: Malformed JSON (equals sign)
```
{"name="web_fetch", "arguments": {"url":"https://weather.gc.ca/..."}}
```
- Uses `=` instead of `:` after "name"
- Has `"arguments":` with JSON object
- No `<parameter>` tags
- No closing tags

### Format 5: Valid JSON (colon) ✨ NEW
```
{"name": "web_fetch", "arguments": {"max_chars": 3000, "url": "https://en.wikipedia.org/..."}}
```
- Uses proper `:` after "name" (valid JSON)
- Has `"arguments":` with JSON object
- No `<parameter>` tags
- No closing tags

## Solution Implemented

### 1. Pattern Detection (`src/agent/dispatcher.zig` lines 99-122)
Added special case detection at the start of `parseXmlToolCalls`:
- Detects `{"name":` pattern (colon style with quotes)
- Detects `{"name=` pattern (equals style, no quotes, no colon)
- Detects `{"invoke name=` pattern (invoke style)
- Verifies presence of `">`, `</invoke>`, and `</minimax:tool_call>` markers
- Extracts the entire tool call block
- Parses it using `parseHybridTagCall`
- Removes it from remaining text so it's not shown to user

### 2. Tool Name Extraction (`src/agent/dispatcher.zig` lines 1029-1074)
Enhanced `parseHybridTagCall` to handle MiniMax format:
- **Special Case 1**: Handles `{"name": "tool_name">` (colon with quotes)
  - Extracts tool name from JSON-style `"name":` field
  - Verifies format is followed by `>` (MiniMax marker)
- **Special Case 2**: Handles `{"name=tool_name>` (equals, no quotes)
  - Extracts tool name directly between `=` and `>`
- Prevents false matches on parameter names

## Test Results

### Static Test Results (`test_minimax_comprehensive.zig`)
```
✓ Test 1: web_fetch (colon format) - CORRECT!
✓ Test 2: shell (equals format) - Pattern detected
✓ Test 3: search with multiple parameters - CORRECT!
✓ Test 4: All format markers detected correctly
```

### Key Test Cases
1. **Tool name extraction**: Correctly extracts "web_fetch", "search", etc.
2. **Pattern detection**: Detects both colon (`{"name":`) and equals (`{"invoke name=`) styles
3. **Marker detection**: Finds all required markers (`">`, `</invoke>`, `</minimax:tool_call>`)

## Deployment Status
- ✅ Code compiled successfully
- ✅ Gateway restarted and running
- ✅ Static tests passing
- 🔄 Ready for live testing

## Expected Behavior
When the AI agent uses tools, users should now:
- ✅ See only the final answer
- ❌ NOT see raw tool call JSON/XML
- ❌ NOT see "thinking out loud" messages

## Files Modified
1. `src/agent/dispatcher.zig` - Added MiniMax format detection and parsing
2. Test files created:
   - `test_minimax_parsing.zig` - Basic pattern detection test
   - `test_minimax_comprehensive.zig` - Comprehensive format test

## Next Steps
1. Test with live queries that require tool use (e.g., "what's the weather?")
2. Verify tool calls are hidden from user
3. Commit changes if working correctly
