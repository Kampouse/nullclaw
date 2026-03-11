# Web Search Fix - Verified ✅

## Problem
DuckDuckGo API was returning empty results for all queries because it requires a User-Agent header.

## Root Cause
Without a User-Agent header, DuckDuckGo's API returns a fake test response:
```json
{
  "RelatedTopics": [],
  "AbstractText": "",
  "Heading": "",
  "meta": {
    "id": "just_another_test",
    "name": "Just Another Test"
  }
}
```

## Solution
Added User-Agent header to DuckDuckGo provider in `src/tools/web_search_providers/duckduckgo.zig`:

```zig
const headers = [_][]const u8{
    "Accept: application/json",
    "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
};
```

## Verification Results

### Before Fix (no User-Agent)
```bash
curl "https://api.duckduckgo.com/?q=weather&format=json"
# Returns: {"id":"just_another_test", "RelatedTopics":[]}
```

### After Fix (with User-Agent)
```bash
curl -A "Mozilla/5.0" "https://api.duckduckgo.com/?q=weather&format=json"
# Returns: Real results with AbstractText and RelatedTopics
```

### Test Results (2025-03-11)

**Query: "Tesla"**
- ✅ Heading: "Tesla"
- ✅ RelatedTopics: 8 topics
- ⚠️ AbstractText: Empty (expected for some queries)

**Query: "zig programming language"**
- ✅ Heading: "Zig (programming language)"
- ✅ AbstractText: Full description (300+ chars)
- ✅ RelatedTopics: 9 topics
- ✅ First Result: "Systems programming languages"

**Query: "weather today"**
- ⚠️ RelatedTopics: 0 (some queries don't have data in DuckDuckGo)

## What This Fixes

1. **web_search tool now returns real results** instead of "No web results found."
2. **Agent no longer falls back to shell** when web_search should work
3. **Better debug logging** added to track query execution and response parsing

## Debug Logging

Added comprehensive logging to help diagnose issues:
- `duckduckgo` log scope with info/debug/warn levels
- Logs query, URL, response length, and result count
- Warns when no results are found with response keys
- Logs parsing errors with context

## Usage

Enable debug logging to see web_search execution:
```bash
NULLCLAW_LOG=debug ./zig-out/bin/nullclaw gateway
```

Example log output:
```
[duckduckgo] INFO: Executing DuckDuckGo search for query: 'Tesla', count: 5
[duckduckgo] DEBUG: DuckDuckGo URL: https://api.duckduckgo.com/?q=Tesla&format=json&no_html=1&skip_disambig=1
[duckduckgo] DEBUG: Response length: 2847 bytes
[duckduckgo] DEBUG: Heading: 'Tesla', AbstractURL: '', AbstractText length: 0
[duckduckgo] DEBUG: Found RelatedTopics array with 8 items
[duckduckgo] DEBUG: Total entries collected: 8
[duckduckgo] INFO: DuckDuckGo search completed: has_results=true
```

## Commit
Commit: `e811357` - "fix(web_search): add User-Agent header and debug logging to DuckDuckGo provider"

Files changed:
- src/tools/web_search_providers/duckduckgo.zig (User-Agent + logging)
- src/providers/compatible.zig (MiniMax content array parsing)
- src/agent/root.zig (debug logging)
- test_web_search_real.zig (test file)

## Next Steps

The web_search tool should now work correctly. Test with:
```bash
./zig-out/bin/nullclaw gateway
# Then send: "search for Tesla stock news"
```

Expected behavior:
- ✅ Uses web_search tool (not shell fallback)
- ✅ Returns real search results from DuckDuckGo
- ✅ Agent uses results to answer the question
