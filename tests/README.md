# nullclaw Tests

This directory contains test files and utilities for testing nullclaw functionality.

## Directory Structure

- **dispatcher/** - Tool call dispatcher tests
  - MiniMax format parsing tests
  - Tool call deduplication tests
  - Integration tests

- **fetch/** - web_fetch tool tests
  - HTTP request handling
  - Content parsing
  - Error handling

- **integration/** - Integration tests
  - End-to-end tests
  - Shell scripts for running tests
  - Test utilities

- **minimax/** - MiniMax LLM format tests
  - JSON format variations
  - Malformed input handling
  - Tool call parsing edge cases

- **tls/** - TLS/SSL tests
  - Certificate handling
  - ECDSA support
  - HTTPS connections

- **web/** - Web-related tool tests
  - Hacker News API tests
  - web_search functionality
  - Content fetching

## Running Tests

```bash
# Run all tests
zig build test

# Run specific test category
zig test test_dispatcher_integration.zig

# Run integration scripts
./test_nullclaw.sh
```

## Documentation Files

- `DEDUPLICATION_FIX.md` - Tool call deduplication implementation
- `DISPATCHER_TOOL_CALL_LEAK_FIX.md` - MiniMax tool call parsing fixes
- `MEMORY.md` - Memory system documentation
- `MINIMAX_FIX_*.md` - MiniMax format handling documentation
- `OPTIMIZATION_TEST_RESULTS.md` - Performance optimization results
- `TOOL_CALL_LOGGING.md` - Tool call logging implementation
