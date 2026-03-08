# Testing Guide

This document explains how to run tests in the NullClaw project and what tooling is available.

## Quick Start

```bash
# Run all tests
zig build test --summary all

# Run tests for a specific module
zig build test -Dtest-file=channels/cli --summary all

# Run tests in parallel (recommended)
./test_nullclaw.sh
```

## Test Tooling

### 1. **Main Test Runner** - `test_nullclaw.sh`

The primary test runner that runs all modules in parallel and tracks history.

**Features:**
- ✅ Runs 38 test modules in parallel (8 concurrent jobs)
- 🎨 Color-coded output (green=pass, red=fail, yellow=leak)
- 📊 Tracks history and compares with previous runs
- 🔍 Shows specific failing test names in real-time
- 📈 Saves results to `test_results/history/`

**Usage:**
```bash
./test_nullclaw.sh
```

**Output includes:**
- Real-time progress with timestamps
- Specific test names that failed (not just module names)
- Comparison with previous run (what got fixed/broken)
- Summary statistics with percentages

**Example output:**
```
[19:57:09] Starting: channels/cli
[19:57:12] PASS: channels/cli
[19:57:15] FAIL_ERROR: agent
    Failed tests:
    • daemon.test.mergeSchedulerTickChangesAndSave preserves runtime agent fields
    • agent.prompt.test.buildSystemPrompt includes core sections
    ... and 29 more

========================================
📊 COMPARISON WITH PREVIOUS RUN
========================================

  Previous run: 28 passing, 0 leaks, 10 errors
  Current run:  30 passing, 0 leaks, 8 errors

  Changes:
    ✓+2 more tests passing
    ✓-2 fewer errors
    → No change in leaks

  Module changes:
    ✓ FIXED: channels/email
    ✗ BROKEN: security/policy
```

### 2. **History Viewer** - `test_history.sh`

View and compare historical test runs.

**List all runs:**
```bash
./test_history.sh --list
```

**Compare two specific runs:**
```bash
./test_history.sh --compare 20260307_195500 20260307_200000
```

**View trends graph:**
```bash
./test_history.sh --graph
```

**Output:**
```
Test Run History:

20260307_195500 - Pass: 28, Leaks: 0, Errors: 10 ✓ ALL PASS
20260307_200000 - Pass: 30, Leaks: 0, Errors: 8 ✓ ALL PASS
20260307_210000 - Pass: 25, Leaks: 2, Errors: 15 ⚠ SOME ISSUES
```

### 3. **Built-in Zig Testing**

NullClaw uses Zig's built-in testing framework.

**Run all tests:**
```bash
zig build test --summary all
```

**Run specific module:**
```bash
zig build test -Dtest-file=memory --summary all
```

**Run specific file:**
```bash
zig build test -Dtest-file=channels/cli --summary all
```

**Run single test file directly:**
```bash
zig test src/channels/cli.zig
```

## Test Modules

The test suite is organized into these modules:

| Module | Description | Command |
|--------|-------------|---------|
| **agent** | Agent orchestration, prompts, dispatcher | `-Dtest-file=agent` |
| **channels** | All messaging channels | `-Dtest-file=channels` |
| **channels/cli** | CLI channel with history | `-Dtest-file=channels/cli` |
| **memory** | All memory modules (40 files) | `-Dtest-file=memory` |
| **memory/engines** | Storage engines (sqlite, markdown, etc.) | `-Dtest-file=memory/engines` |
| **memory/lifecycle** | Lifecycle management (cache, hygiene) | `-Dtest-file=memory/lifecycle` |
| **providers** | AI model providers (anthropic, openai, etc.) | `-Dtest-file=providers` |
| **security** | Security policies, pairing, sandboxing | `-Dtest-file=security` |
| **tools** | All tool implementations (39 files) | `-Dtest-file=tools` |
| **tools/shell** | Shell command execution tool | `-Dtest-file=tools/shell` |

## Understanding Test Results

### Test Status

- ✅ **PASS** - All tests in module passed
- 🔴 **LEAK** - Tests passed but memory leaks detected
- ❌ **ERROR** - Tests failed or crashed

### Common Test Patterns

**Passing module:**
```
channels/cli - 10/10 tests passed
```

**Memory leak:**
```
memory.engines.markdown.test.markdown accepts session_id param leaked 4 allocations
```

**Test failure:**
```
agent.prompt.test.buildSystemPrompt includes core sections failed
```

**Crash:**
```
agent.dispatcher.test.buildAssistantHistoryWithToolCalls terminated with signal ABRT
```

## CI/CD Integration

### Pre-commit Hook
```bash
git config core.hooksPath .githooks
```
Blocks commits if formatting is wrong.

### Pre-push Hook
Blocks push if any tests fail:
```bash
zig build test --summary all
```

## Test Files Location

- Test code: Co-located in source files (e.g., `src/channels/cli.zig`)
- Test results: `test_results/`
- Test history: `test_results/history/`

## Writing Tests

Tests are written using Zig's built-in testing framework:

```zig
test "description of what is being tested" {
    // Arrange
    const allocator = std.testing.allocator;

    // Act
    const result = try functionUnderTest(allocator);

    // Assert
    try std.testing.expectEqual(expected, result);
}
```

### Testing Guidelines

1. **Use `std.testing.allocator`** - Enables leak detection
2. **Always clean up** - Use `defer` to free allocations
3. **Test files** - Tests live alongside source code in the same file
4. **Test naming** - Use `subject_expected_behavior` pattern
5. **Deterministic** - Tests must be reproducible

## Troubleshooting

### Tests timing out
```bash
# Run with longer timeout
zig build test --summary all -Dwatchdog-timeout=600
```

### Too many tests failing
```bash
# Run just one module
zig build test -Dtest-file=channels/cli --summary all
```

### Checking for leaks in a specific module
```bash
zig build test -Dtest-file=memory/engines/markdown --summary all
```

### View detailed test output
```bash
# Don't use --summary all
zig build test -Dtest-file=channels/cli
```

## Performance

**Parallel test runner:**
- 38 modules tested in ~30 seconds
- 8 concurrent jobs
- Automatic detection of GNU parallel or fallback to bash background jobs

**Cache:**
- Zig caches compiled test binaries
- Subsequent runs are much faster

## Resources

- [Zig Testing Documentation](https://ziglang.org/documentation/master/#Testing)
- Project `AGENTS.md` - Engineering protocols and validation requirements
- `build.zig` - Build configuration and test setup
