//! vm.zig — Conditional VM module wrapper.
//!
//! When compiled with -Dvm=true on macOS ARM64, provides access to
//! the Apple Virtualization Framework-backed VM manager.
//! Otherwise, provides stub functions that always return errors.

const std = @import("std");
const build_options = @import("build_options");
const enable_vm = build_options.enable_vm;

// Re-export types from the real VM module when enabled.
pub const VmConfig = if (enable_vm) @import("vm/vm_manager.zig").VmConfig else struct {};

/// The pooled VM manager type — real or stub depending on build config.
pub const PooledVmManager = if (enable_vm) @import("vm/vm_manager.zig").PooledVmManager else struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: anytype) !@This() {
        _ = config;
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *@This()) void {}

    pub fn isAvailable() bool {
        return false;
    }

    pub fn ensureReady(_: *@This()) !void {
        return error.VmNotAvailable;
    }

    pub fn execCode(_: *@This(), command: []const u8) ![]const u8 {
        _ = command;
        return error.VmNotAvailable;
    }
};

/// Get the global pooled VM manager (lazy singleton).
/// Thread-safe.
pub fn getGlobalVmManager(allocator: std.mem.Allocator) !*PooledVmManager {
    if (!enable_vm) return error.VmNotAvailable;
    return @import("vm/vm_manager.zig").getGlobalManager(allocator);
}

/// Check if Apple Virtualization Framework is available at runtime.
pub fn isVmAvailable() bool {
    if (!enable_vm) return false;
    return @import("vm/vm_manager.zig").isAvailable();
}
