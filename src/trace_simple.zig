//! Simplified tracing wrapper for quick integration
//!
//! Usage:
//!   const trace = @import("trace_simple.zig");
//!   
//!   trace.init(allocator, .debug);
//!   defer trace.deinit();
//!   
//!   trace.info(.daemon, "Starting daemon", .{});
//!   trace.err(.provider_openai, "API error: {}", .{err});

const std = @import("std");
const main_trace = @import("trace.zig");

pub const Subsystem = main_trace.Subsystem;
pub const Level = main_trace.Level;
pub const Span = main_trace.Span;
pub const ScopedSpan = main_trace.ScopedSpan;

/// Initialize global tracer
pub fn init(allocator: std.mem.Allocator, level: Level) void {
    main_trace.init(allocator, level);
}

/// Initialize with file output
pub fn initWithFile(allocator: std.mem.Allocator, level: Level, path: []const u8) !void {
    try main_trace.initWithFile(allocator, level, path);
}

/// Cleanup global tracer
pub fn deinit() void {
    main_trace.deinit();
}

// =============================================================================
// Logging Functions
// =============================================================================

pub fn trace(subsystem: Subsystem, comptime fmt: []const u8, args: anytype) void {
    main_trace.trace(subsystem, fmt, args);
}

pub fn debug(subsystem: Subsystem, comptime fmt: []const u8, args: anytype) void {
    main_trace.debug(subsystem, fmt, args);
}

pub fn info(subsystem: Subsystem, comptime fmt: []const u8, args: anytype) void {
    main_trace.info(subsystem, fmt, args);
}

pub fn warn(subsystem: Subsystem, comptime fmt: []const u8, args: anytype) void {
    main_trace.warn(subsystem, fmt, args);
}

pub fn err(subsystem: Subsystem, comptime fmt: []const u8, args: anytype) void {
    main_trace.err(subsystem, fmt, args);
}

pub fn fatal(subsystem: Subsystem, comptime fmt: []const u8, args: anytype) void {
    main_trace.fatal(subsystem, fmt, args);
}

// =============================================================================
// Span Functions
// =============================================================================

/// Start a new span
pub fn startSpan(subsystem: Subsystem, operation: []const u8) ?Span {
    return main_trace.startSpan(subsystem, operation);
}

/// End a span
pub fn endSpan(span: *Span) void {
    main_trace.endSpan(span);
}

// =============================================================================
// Testing
// =============================================================================

test "Simple trace usage" {
    init(std.testing.allocator, .debug);
    defer deinit();
    
    info(.daemon, "Test message: {}", .{42});
    err(.provider_openai, "Error: {s}", .{"test error"});
}

test "Span usage" {
    init(std.testing.allocator, .debug);
    defer deinit();
    
    var span = startSpan(.agent_dispatcher, "test_op") orelse return;
    defer endSpan(&span);
    
    span.logInSpan(.info, "Inside span", .{});
}

test "Scoped span" {
    init(std.testing.allocator, .debug);
    defer deinit();
    
    {
        var scoped = ScopedSpan.init(.daemon, "scoped_op");
        defer scoped.deinit();
        
        if (scoped.get()) |s| {
            s.logInSpan(.info, "Inside scoped span", .{});
        }
    }
}
