//! Simplified tracing system for NullClaw (Zig 0.16 compatible)

const std = @import("std");
const util = @import("util.zig");

// =============================================================================
// Subsystem Identification
// =============================================================================

pub const Subsystem = enum {
    daemon,
    gateway,
    config,
    agent_core,
    agent_dispatcher,
    agent_routing,
    channel_loop,
    channel_manager,
    channel_telegram,
    channel_discord,
    channel_slack,
    channel_signal,
    provider_openai,
    provider_gemini,
    provider_anthropic,
    provider_ollama,
    tool_shell,
    tool_file,
    tool_memory,
    tool_cron,
    tool_browser,
    tool_web_fetch,
    tool_web_search,
    memory_engine,
    memory_sqlite,
    memory_markdown,
    memory_vector,
    security_policy,
    security_secrets,
    security_tracker,
    bus,
    cron,
    state,
    http,
    tls,
    unknown,
};

pub const Level = enum {
    trace,
    debug,
    info,
    warn,
    err,
    fatal,
    off,
};

pub const Status = enum {
    running,
    ok,
    @"error",
    timeout,
};

// =============================================================================
// Global State
// =============================================================================

var g_allocator: ?std.mem.Allocator = null;
var g_level: Level = .info;
var g_file: ?std.fs.File = null;
var g_mutex: std.Io.Mutex = .{ .state = .init(.unlocked) };

// =============================================================================
// Initialization
// =============================================================================

pub fn init(allocator: std.mem.Allocator, level: Level) void {
    g_mutex.lock() catch return;
    defer g_mutex.unlock();
    
    g_allocator = allocator;
    g_level = level;
}

pub fn initWithFile(allocator: std.mem.Allocator, level: Level, path: []const u8) !void {
    g_mutex.lock() catch return error.LockFailed;
    defer g_mutex.unlock();
    
    g_allocator = allocator;
    g_level = level;
    g_file = try std.fs.cwd().createFile(path, .{
        .truncate = false,
        .read = false,
    });
    try g_file.?.seekFromEnd(0);
}

pub fn deinit() void {
    g_mutex.lock() catch return;
    defer g_mutex.unlock();
    
    if (g_file) |f| {
        f.close();
        g_file = null;
    }
    g_allocator = null;
}

// =============================================================================
// Logging Functions
// =============================================================================

pub fn log(subsystem: Subsystem, level: Level, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) < @intFromEnum(g_level)) return;
    
    const timestamp_ns = util.nanoTimestamp();
    
    g_mutex.lock();
    defer g_mutex.unlock();
    
    // Format message
    const allocator = g_allocator orelse std.heap.page_allocator;
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(msg);
    
    // Format timestamp as simple ISO
    const secs = @as(u64, @intCast(@divTrunc(timestamp_ns, 1_000_000_000)));
    const nsecs = @as(u32, @intCast(@mod(timestamp_ns, 1_000_000_000)));
    
    var ts_buf: [64]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&ts_buf, "{}.{:0>9}", .{ secs, nsecs }) catch "TIME_ERROR";
    
    // Write to stderr using print
    std.debug.print("[{s}] [{s}] [{s}] {s}\n", .{
        ts_str,
        levelName(level),
        @tagName(subsystem),
        msg,
    });
    
    // Write to file if enabled
    if (g_file) |f| {
        const writer = f.writer();
        writer.print("[{s}] [{s}] [{s}] {s}\n", .{
            ts_str,
            levelName(level),
            @tagName(subsystem),
            msg,
        }) catch {};
    }
}

fn levelName(level: Level) []const u8 {
    return switch (level) {
        .trace => "TRACE",
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERROR",
        .fatal => "FATAL",
        .off => "OFF",
    };
}

pub fn trace(subsystem: Subsystem, comptime fmt: []const u8, args: anytype) void {
    log(subsystem, .trace, fmt, args);
}

pub fn debug(subsystem: Subsystem, comptime fmt: []const u8, args: anytype) void {
    log(subsystem, .debug, fmt, args);
}

pub fn info(subsystem: Subsystem, comptime fmt: []const u8, args: anytype) void {
    log(subsystem, .info, fmt, args);
}

pub fn warn(subsystem: Subsystem, comptime fmt: []const u8, args: anytype) void {
    log(subsystem, .warn, fmt, args);
}

pub fn err(subsystem: Subsystem, comptime fmt: []const u8, args: anytype) void {
    log(subsystem, .err, fmt, args);
}

pub fn fatal(subsystem: Subsystem, comptime fmt: []const u8, args: anytype) void {
    log(subsystem, .fatal, fmt, args);
}

// =============================================================================
// Span - Tracked Operation
// =============================================================================

pub const Span = struct {
    id: u64,
    subsystem: Subsystem,
    operation: []const u8,
    start_time: i128,
    end_time: ?i128 = null,
    status: Status = Status.running,
    
    pub fn end(self: *Span) void {
        self.end_time = util.nanoTimestamp();
        if (self.status == Status.running) {
            self.status = Status.ok;
        }
        
        const duration_ns = self.end_time.? - self.start_time;
        const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
        
        log(self.subsystem, .debug, "Span end: {s} ({d:.2}ms) [{s}]", .{
            self.operation,
            duration_ms,
            @tagName(self.status),
        });
    }
    
    pub fn setError(self: *Span) void {
        self.status = Status.@"error";
    }
    
    pub fn setTimeout(self: *Span) void {
        self.status = Status.timeout;
    }
    
    pub fn logInSpan(self: *Span, level: Level, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(g_level)) return;
        
        const elapsed_ns = util.nanoTimestamp() - self.start_time;
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        
        const allocator = g_allocator orelse std.heap.page_allocator;
        const msg = std.fmt.allocPrint(allocator, fmt, args) catch return;
        defer allocator.free(msg);
        
        log(self.subsystem, level, "[span:{}] [{d:.2}ms] {s}", .{
            self.id,
            elapsed_ms,
            msg,
        });
    }
};

// =============================================================================
// Span Management
// =============================================================================

var g_next_span_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

pub fn startSpan(subsystem: Subsystem, operation: []const u8) ?Span {
    if (g_allocator == null) return null;
    
    const span_id = g_next_span_id.fetchAdd(1, .monotonic);
    
    log(subsystem, .debug, "Span start: {s}", .{operation});
    
    return Span{
        .id = span_id,
        .subsystem = subsystem,
        .operation = operation,
        .start_time = util.nanoTimestamp(),
    };
}

pub fn endSpan(span: *Span) void {
    span.end();
}

// =============================================================================
// Scoped Span (auto-end on deinit)
// =============================================================================

pub const ScopedSpan = struct {
    span: ?Span,
    
    pub fn init(subsystem: Subsystem, operation: []const u8) ScopedSpan {
        return .{
            .span = startSpan(subsystem, operation),
        };
    }
    
    pub fn deinit(self: *ScopedSpan) void {
        if (self.span) |*s| {
            s.end();
        }
    }
    
    pub fn get(self: *ScopedSpan) ?*Span {
        if (self.span) |*s| {
            return s;
        }
        return null;
    }
};

// =============================================================================
// Testing
// =============================================================================

test "Basic logging" {
    const allocator = std.testing.allocator;
    init(allocator, .debug);
    defer deinit();
    
    info(.daemon, "Test message: {}", .{42});
    err(.provider_openai, "Error: {s}", .{"test"});
}

test "Span usage" {
    const allocator = std.testing.allocator;
    init(allocator, .debug);
    defer deinit();
    
    var span = startSpan(.daemon, "test_op") orelse return error.NoTracer;
    defer endSpan(&span);
    
    span.logInSpan(.info, "Inside span", .{});
}

test "Scoped span" {
    const allocator = std.testing.allocator;
    init(allocator, .debug);
    defer deinit();
    
    {
        var scoped = ScopedSpan.init(.daemon, "scoped_op");
        defer scoped.deinit();
        
        if (scoped.get()) |s| {
            s.logInSpan(.info, "Inside scoped span", .{});
        }
    }
}
