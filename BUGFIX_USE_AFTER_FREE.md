# Bug Fix: Use-After-Free in executeTool

## Summary

Fixed a critical **use-after-free bug** in `src/agent/root.zig` that caused the agent to crash with a segmentation fault when executing tools that return heap-allocated output (like the `shell` tool).

## Root Cause

The bug was in the `executeTool` function at line 1500-1508:

```zig
// BUGGY CODE:
const output = if (result.success) result.output else (result.error_msg orelse result.output);
const success = result.success;
result.deinit(tool_allocator); // ⚠️ FREES OUTPUT MEMORY
return .{
    .name = call.name,
    .output = output, // ⚠️ DANGLING POINTER TO FREED MEMORY!
    .success = success,
    .tool_call_id = call.tool_call_id,
};
```

When a tool (like `shell`) returns heap-allocated output with `owns_output = true`, calling `result.deinit()` frees that memory. Then we returned a pointer to the freed memory in `ToolExecutionResult.output`.

Later, when `formatToolResults` tried to access `result.output`, it accessed freed memory, causing a **segmentation fault**.

## Crash Reproduction

```bash
$ zig test test_hello_world_crash.zig
Segmentation fault at address 0x101220000
```

## The Fix

Duplicate the output BEFORE calling `deinit()`:

```zig
// FIXED CODE:
const output_src = if (result.success) result.output else (result.error_msg orelse result.output);
const success = result.success;

// Duplicate output before deinit to avoid use-after-free
const output = tool_allocator.dupe(u8, output_src) catch {
    result.deinit(tool_allocator);
    return .{
        .name = call.name,
        .output = "Memory allocation failed",
        .success = false,
        .tool_call_id = call.tool_call_id,
    };
};
result.deinit(tool_allocator);

return .{
    .name = call.name,
    .output = output, // ✅ SAFE: We own this memory now
    .success = success,
    .tool_call_id = call.tool_call_id,
};
```

## Changes Made

- **File**: `src/agent/root.zig`
- **Function**: `executeTool` (lines ~1500-1508)
- **Change**: Added memory duplication before deinit to prevent use-after-free

## Testing

The fix has been verified to:
1. Compile successfully without errors
2. Prevent segmentation faults when executing tools with heap-allocated output
3. Properly handle memory allocation failures by returning an error result

## Related Files

- Bug reproduction test: `test_hello_world_crash.zig`
- Tool execution code: `src/agent/root.zig` (executeTool function)
- Tool result definition: `src/tools/root.zig` (ToolResult struct)
- Shell tool example: `src/tools/shell.zig` (returns heap-allocated stdout)

## Memory Safety Notes

This fix ensures proper memory ownership transfer:
- Tools allocate output and set `owns_output = true`
- `executeTool` duplicates the output to take ownership
- Original tool result is deinitialized safely
- `ToolExecutionResult` owns its output memory for the rest of its lifetime
