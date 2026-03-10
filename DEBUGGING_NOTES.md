# Debugging Session: nullclaw Segmentation Fault

**Date:** March 10, 2026  
**Branch:** beta-b  
**Commit:** e735732  
**Issue:** Segmentation fault when running `nullclaw agent -m "what version"` or any message that triggers tool execution

## Summary

The nullclaw agent crashes with a segmentation fault when it tries to execute tools (shell commands, self_update, etc.). Investigation revealed a critical memory bug in the Zig 0.16.0 I/O migration code.

## Critical Bug Found and Fixed

### Memory Corruption in `createProcessIo()` (FIXED)

**Location:** `src/util.zig`

**Problem:** The `createProcessIo()` function was creating a `std.Io.Threaded` struct on the stack and returning `threaded_io.ioBasic()`. However, `ioBasic()` returns a `std.Io` that contains **pointers back to the `threaded_io`**. When the function returns, the stack-allocated `threaded_io` is destroyed, but the returned `std.Io` still holds pointers to it. This is a classic use-after-free bug.

**Fix:** Changed to use a global static `Io.Threaded` instance that persists for the lifetime of the program:

```zig
var global_threaded_io: ?std.Io.Threaded = null;

pub fn createProcessIo() std.Io {
    // Initialize global instance once
    if (global_threaded_io == null) {
        global_threaded_io = std.Io.Threaded{
            .allocator = std.heap.page_allocator,
            .stack_size = std.Thread.SpawnConfig.default_stack_size,
            .async_limit = .nothing,
            .cpu_count_error = null,
            .concurrent_limit = .nothing,
            .old_sig_io = undefined,
            .old_sig_pipe = undefined,
            .have_signal_handler = false,
            .argv0 = .empty,
            .environ_initialized = true,
            .environ = .empty,
            .worker_threads = .init(null),
            .disable_memory_mapping = false,
        };
    }
    return global_threaded_io.?.ioBasic();
}
```

## Current Status

After the fix, the crash **still occurs**. Debug tracing was added to:
- `src/util.zig` - `createProcessIo()` function
- `src/tools/process_util.zig` - `run()` function
- `src/tools/self_update.zig` - `execute()` function
- `src/agent/root.zig` - `executeTool()` function

**Observations:**
1. The `[TOOL_CALL]` output appears, showing the agent is trying to execute tools
2. **None of the TRACE messages appear**, indicating the crash happens **before** tool execution
3. Simple messages like "test" work fine
4. Messages that trigger tool usage (e.g., "what version", "ls") crash

## Symptoms

```bash
$ ./zig-out/bin/nullclaw agent -m "what version"
info(memory): memory plan resolved: backend=sqlite retrieval=hybrid vector=sqlite_shared rollout=on hygiene=true snapshot=false cache=false semantic_cache=false summarizer=false sources=1
Sending to ollama-cloud...

[TOOL_CALL]
{"name": "shell", "arguments": {"command": "git rev-parse --short HEAD 2>/dev/null || echo \"unknown\""}}
[/TOOL_CALL]
Segmentation fault: 11
```

## Debugging Traces Added

The following debug traces were added but **do not appear** in the output:

```
[TRACE] createProcessIo: start
[TRACE] createProcessIo: initializing global_threaded_io
[TRACE] createProcessIo: global_threaded_io initialized
[TRACE] createProcessIo: calling ioBasic()
[TRACE] createProcessIo: returning io
[TRACE] process_util.run: start
[TRACE] process_util.run: calling createProcessIo
[TRACE] self_update.execute: start
[TRACE] executeTool: start, tool=...
```

This indicates the crash occurs **in the dispatcher or tool call parsing layer**, before any tool execution begins.

## Files Modified

1. `src/util.zig` - Fixed memory bug in `createProcessIo()`, added debug tracing
2. `src/tools/process_util.zig` - Added debug tracing
3. `src/tools/self_update.zig` - Added debug tracing
4. `src/agent/root.zig` - Added debug tracing to `executeTool()`

## Next Steps

### 1. Investigate Dispatcher/Tool Call Parsing

The crash is happening **before** tools are executed, likely in:
- `src/agent/dispatcher.zig` - where tool calls are parsed from LLM responses
- Tool call JSON parsing code
- Tool dispatch mechanism

**Key areas to investigate:**
- `parseToolCalls()` function
- `parseXmlToolCalls()` function
- `parseNativeToolCalls()` function
- Any stack-allocated structs with pointers being returned from functions

### 2. Check for Similar Memory Bugs

Look for other instances of:
- Stack-allocated structs being returned by value
- Functions returning pointers to stack-allocated memory
- Zig 0.16.0 I/O migration issues in other parts of the codebase

### 3. Focus Areas

The crash appears to be in the code path:
```
LLM response → parseToolCalls() → dispatcher → executeTool() → CRASH
```

But it crashes **before** `executeTool()` is even called.

## Zig 0.16.0 Migration Issues

The codebase has been migrated to Zig 0.16.0's new I/O interface. Key changes:
- `std.Options.debug_io` is used for I/O operations
- `std.Io.Threaded` is used for process spawning
- Many functions now take `io: std.Io` parameters

**Potential issues:**
- Not all code paths may be properly using the new I/O interface
- Stack-allocated I/O structures with pointers may still exist
- The `std.Options.debug_io` uses a `.failing` allocator which can cause issues

## Testing Commands

```bash
# Works fine
./zig-out/bin/nullclaw agent -m "test"

# Crashes
./zig-out/bin/nullclaw agent -m "what version"
./zig-out/bin/nullclaw agent -m "ls"
```

## Build Commands

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseSmall

# Run tests
zig build test
```

## Git Status

Current branch: `beta-b`  
Last commit: `e735732 fix: memory bug in createProcessIo - use global Io.Threaded`

## Related Code

- `src/agent/root.zig:1376` - `executeTool()` function
- `src/agent/dispatcher.zig` - Tool call parsing
- `src/util.zig:7` - `createProcessIo()` function (FIXED)
- `src/tools/process_util.zig:42` - `run()` function
- `src/main.zig` - Zig 0.16.0 I/O migration entry point

## Zig 0.16.0 I/O Pattern

Correct pattern (heap-allocated or global):
```zig
var global_threaded_io: ?std.Io.Threaded = null;

pub fn createProcessIo() std.Io {
    if (global_threaded_io == null) {
        global_threaded_io = std.Io.Threaded{ ... };
    }
    return global_threaded_io.?.ioBasic();
}
```

Incorrect pattern (stack-allocated - use-after-free):
```zig
pub fn createProcessIo() std.Io {
    var threaded_io = std.Io.Threaded{ ... }; // WRONG: stack allocated
    return threaded_io.ioBasic(); // WRONG: returns pointers to stack memory
}
```

## Notes

- Exit code 139 = 128 + 11 (SIGSEGV)
- Crash happens in both Debug and Release builds
- Binary size: ~28MB debug, ~3.5MB release
- The tool call JSON is being printed but execution never reaches the tool