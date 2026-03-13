//! Tracy Profiler Integration Module
//!
//! This module provides zero-overhead profiling wrappers for Tracy.
//! When Tracy is disabled (via -Dtracy=false), all functions compile to no-ops.
//! When enabled, they provide nanosecond-precision profiling.

const std = @import("std");
const build_options = @import("build_options");

const enable_tracy = build_options.enable_tracy;

// When Tracy is enabled, import the tracy module
// When disabled, all functions become no-ops at comptime
const tracy = if (enable_tracy) @import("tracy") else struct {
    pub const ZoneContext = struct {
        pub inline fn end(_: ZoneContext) void {}
        pub inline fn text(_: ZoneContext, comptime fmt: []const u8, args: anytype) void {
            _ = fmt;
            _ = args;
        }
        pub inline fn name(_: ZoneContext, comptime fmt: []const u8, args: anytype) void {
            _ = fmt;
            _ = args;
        }
        pub inline fn color(_: ZoneContext, _: u32) void {}
        pub inline fn value(_: ZoneContext, _: u64) void {}
    };

    pub inline fn beginZone(comptime src: std.builtin.SourceLocation, opts: anytype) ZoneContext {
        _ = src;
        _ = opts;
        return .{};
    }

    pub inline fn frameMark() void {}
    pub inline fn frameMarkNamed(_: []const u8) void {}
    pub inline fn plot(_: []const u8, _: anytype) void {}
    pub inline fn message(comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
    }
    pub inline fn messageColor(comptime fmt: []const u8, args: anytype, _: u32) void {
        _ = fmt;
        _ = args;
    }
    pub inline fn isConnected() bool {
        return false;
    }

    pub const TracingAllocator = struct {
        child_allocator: std.mem.Allocator,

        pub fn init(backing: std.mem.Allocator) TracingAllocator {
            return .{ .child_allocator = backing };
        }

        pub fn allocator(self: *TracingAllocator) std.mem.Allocator {
            return self.child_allocator;
        }
    };
};

/// Create a scoped profiling zone
/// Usage:
///   const zone = zone(@src());
///   defer zone.end();
pub inline fn zone(src: std.builtin.SourceLocation) tracy.ZoneContext {
    return tracy.beginZone(src, .{});
}

/// Create a named profiling zone
pub inline fn zoneNamed(src: std.builtin.SourceLocation, name: []const u8) tracy.ZoneContext {
    return tracy.beginZone(src, .{ .name = name });
}

/// Create a zone with text color
pub inline fn zoneColor(src: std.builtin.SourceLocation, color: u32) tracy.ZoneContext {
    return tracy.beginZone(src, .{ .color = color });
}

/// Zone alias - just use tracy.ZoneContext directly
pub const Zone = tracy.ZoneContext;

/// Mark a frame boundary (useful for frame-time profiling)
pub inline fn frameMark() void {
    tracy.frameMark();
}

/// Mark a frame with a custom name
pub inline fn frameMarkNamed(name: []const u8) void {
    tracy.frameMarkNamed(name);
}

/// Plot a numeric value on a graph
pub inline fn plot(name: []const u8, value: anytype) void {
    tracy.plot(name, value);
}

/// Log a message to Tracy
pub inline fn message(comptime fmt: []const u8, args: anytype) void {
    tracy.message(fmt, args);
}

/// Log a message with color
pub inline fn messageColor(comptime fmt: []const u8, args: anytype, color: u32) void {
    tracy.messageColor(fmt, args, color);
}

/// Memory allocation tracking - wrap an allocator with Tracy
pub inline fn alloc(allocator: std.mem.Allocator) tracy.TracingAllocator {
    return tracy.TracingAllocator.init(allocator);
}

/// Connection state - check if profiler is connected
pub inline fn isConnected() bool {
    return tracy.isConnected();
}

