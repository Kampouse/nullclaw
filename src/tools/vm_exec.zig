//! vm_exec.zig — VM code execution tool for NullClaw.
//!
//! Lets the agent run code in a sandboxed Alpine Linux VM via Apple VZ.
//! Uses the global pooled VmManager — first call boots the VM (~5.6s),
//! subsequent calls reuse it (~40-60ms per exec).
//!
//! Only available when compiled with -Dvm=true on macOS ARM64.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const build_options = @import("build_options");

const log = std.log.scoped(.vm_exec_tool);

pub const VmExecTool = struct {
    allocator: std.mem.Allocator,

    pub const tool_name = "code_sandbox";
    pub const tool_description = "Execute code in a sandboxed Alpine Linux VM with Python 3.12. First call boots the VM (~6s), subsequent calls are fast (~50ms). Use for running untrusted code, computations, or any code that needs isolation.";

    pub const tool_params =
        \\{"type":"object","properties":{"command":{"type":"string","description":"Shell or Python command to execute in the VM"}},"required":["command"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *VmExecTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *VmExecTool, allocator: std.mem.Allocator, args: JsonObjectMap, io: std.Io) !ToolResult {
        _ = io;

        if (!build_options.enable_vm) {
            return ToolResult.fail("VM backend not enabled (compile with -Dvm=true)");
        }

        const command = root.getString(args, "command") orelse {
            return ToolResult.failAlloc(allocator, "missing 'command' parameter");
        };

        log.info("vm_exec: {d} bytes", .{command.len});

        // Use the tool's heap allocator (self.allocator) for all VM operations.
        // The `allocator` parameter is the per-turn arena — using it for VM I/O
        // can exhaust the arena across iterations (confirmed crash: arena OOM → SIGABRT).
        // The heap allocator is safe for large/unbounded allocations and persists
        // across the entire agent session.
        const heap = self.allocator;

        const vm_mod = @import("../vm.zig");
        const manager = vm_mod.getGlobalVmManager(heap) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "VM manager init failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        };

        const output = manager.execCode(heap, command) catch |err| {
            const err_name = @errorName(err);
            if (comptime std.mem.eql(u8, err_name, "OutOfMemory")) {
                log.warn("vm_exec: out of memory", .{});
            }
            const msg = try std.fmt.allocPrint(allocator, "VM exec failed: {s}", .{err_name});
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        };
        defer heap.free(output);

        return ToolResult.okAlloc(allocator, output);
    }

    pub fn deinit(_: *VmExecTool, _: std.mem.Allocator) void {
        // VM manager is global singleton — don't destroy it here
    }
};
