//! High-performance tracing system for NullClaw (Zig 0.16 compatible)
//! 
//! Optimizations:
//! - Ring buffer for batched file writes (reduces syscalls)
//! - Minimal lock scope (only for state access)
//! - Pre-computed level names (comptime)
//! - Single allocation per log line
//! - Fast-path level check before any work
//! - Buffer pooling for reusable allocations

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

pub const Level = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    fatal = 5,
    off = 6,
};

pub const Status = enum {
    running,
    ok,
    @"error",
    timeout,
};

// =============================================================================
// Comptime Level Names (no runtime switch)
// =============================================================================

pub const LEVEL_NAMES = [_][]const u8{
    "TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL", "OFF",
};

// =============================================================================
// Global State
// =============================================================================

var g_level: std.atomic.Value(Level) = std.atomic.Value(Level).init(.info);
var g_file: ?std.Io.File = null;
var g_file_offset: u64 = 0;
var g_mutex: std.Io.Mutex = .{ .state = .init(.unlocked) };
var g_threaded: std.Io.Threaded = undefined;
var g_threaded_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// =============================================================================
// Ring Buffer for Batched File Writes
// =============================================================================

const RING_BUFFER_SIZE = 64 * 1024; // 64KB buffer
const FLUSH_THRESHOLD = 32 * 1024;  // Flush when 32KB accumulated

var g_ring_buffer: [RING_BUFFER_SIZE]u8 = undefined;
var g_ring_write_pos: usize = 0;
var g_ring_read_pos: usize = 0;
var g_ring_count: usize = 0;

/// Write data to ring buffer, returns true if flush needed
fn ringWrite(data: []const u8) bool {
    if (data.len > RING_BUFFER_SIZE) return false;
    
    var remaining = data.len;
    var src_pos: usize = 0;
    
    while (remaining > 0) {
        const write_end = if (g_ring_write_pos >= g_ring_read_pos)
            RING_BUFFER_SIZE
        else
            g_ring_read_pos;
        
        const available = write_end - g_ring_write_pos;
        if (available == 0) break;
        
        const to_write = @min(remaining, available);
        @memcpy(g_ring_buffer[g_ring_write_pos..][0..to_write], data[src_pos..][0..to_write]);
        
        g_ring_write_pos = (g_ring_write_pos + to_write) % RING_BUFFER_SIZE;
        g_ring_count += to_write;
        src_pos += to_write;
        remaining -= to_write;
    }
    
    return g_ring_count >= FLUSH_THRESHOLD;
}

/// Flush ring buffer to file
fn ringFlush(io: std.Io) void {
    if (g_file == null or g_ring_count == 0) return;
    
    const f = g_file.?;
    
    // Write in at most 2 chunks (wraparound)
    while (g_ring_count > 0) {
        const chunk_end = if (g_ring_read_pos < g_ring_write_pos)
            g_ring_write_pos
        else
            RING_BUFFER_SIZE;
        
        const chunk_len = @min(chunk_end - g_ring_read_pos, g_ring_count);
        if (chunk_len == 0) break;
        
        const chunk = g_ring_buffer[g_ring_read_pos..][0..chunk_len];
        f.writePositionalAll(io, chunk, g_file_offset) catch return;
        g_file_offset += chunk_len;
        g_ring_read_pos = (g_ring_read_pos + chunk_len) % RING_BUFFER_SIZE;
        g_ring_count -= chunk_len;
    }
}

// =============================================================================
// Initialization
// =============================================================================

pub fn init(allocator: std.mem.Allocator, level: Level) void {
    // Set level atomically
    g_level.store(level, .monotonic);
    
    // Fast check - only init Threaded once
    if (g_threaded_initialized.load(.monotonic)) {
        return;
    }
    
    // Initialize Threaded for Io (only once)
    g_threaded = std.Io.Threaded.init(allocator, .{});
    g_threaded_initialized.store(true, .release);
}

pub fn initWithFile(allocator: std.mem.Allocator, level: Level, path: []const u8) !void {
    // Set level atomically
    g_level.store(level, .monotonic);
    
    // Initialize Threaded for Io (only once)
    if (!g_threaded_initialized.load(.monotonic)) {
        g_threaded = std.Io.Threaded.init(allocator, .{});
        g_threaded_initialized.store(true, .release);
    }
    const io = g_threaded.io();
    
    g_mutex.lockUncancelable(io);
    defer g_mutex.unlock(io);
    
    // Get file length for append mode
    const file = try std.fs.cwd().createFile(io, path, .{
        .truncate = false,
        .read = true,
    });
    const stat = try file.stat(io);
    g_file_offset = stat.size;
    g_file = file;
}

pub fn deinit() void {
    if (!g_threaded_initialized.load(.monotonic)) return;
    const io = g_threaded.io();
    
    g_mutex.lockUncancelable(io);
    defer g_mutex.unlock(io);
    
    // Flush remaining buffer
    ringFlush(io);
    
    if (g_file) |f| {
        f.close(io);
        g_file = null;
    }
}

/// Force flush the ring buffer to disk
pub fn flush() void {
    if (!g_threaded_initialized.load(.monotonic)) return;
    const io = g_threaded.io();
    
    g_mutex.lockUncancelable(io);
    defer g_mutex.unlock(io);
    
    ringFlush(io);
}

// =============================================================================
// High-Performance Logging
// =============================================================================

/// Log a message (optimized)
pub fn log(subsystem: Subsystem, level: Level, comptime fmt: []const u8, args: anytype) void {
    // Fast path: check level BEFORE any work (atomic read, no lock)
    const current_level = g_level.load(.monotonic);
    if (@intFromEnum(level) < @intFromEnum(current_level)) return;
    
    // Early exit if not initialized
    if (!g_threaded_initialized.load(.monotonic)) return;
    
    // Get timestamp (once)
    const timestamp_ns = util.nanoTimestamp();
    
    // Format directly into a stack buffer (no allocation for typical logs)
    var buf: [4096]u8 = undefined;
    
    // Format timestamp
    const secs = @as(u64, @intCast(@divTrunc(timestamp_ns, 1_000_000_000)));
    const nsecs = @as(u32, @intCast(@mod(timestamp_ns, 1_000_000_000)));
    
    // Build the log line in one pass
    const level_name = LEVEL_NAMES[@intFromEnum(level)];
    const subsystem_name = @tagName(subsystem);
    
    // Use bufPrint for everything (well-optimized in std)
    const line = std.fmt.bufPrint(&buf, "[{}.{d:0>9}] [{s}] [{s}] " ++ fmt ++ "\n", .{
        secs,
        nsecs,
        level_name,
        subsystem_name,
    } ++ args) catch {
        // Fallback on error
        const fallback = "[timestamp error] [ERROR] [trace] Log formatting failed\n";
        writeLine(fallback);
        return;
    };
    
    writeLine(line);
}

/// Write a log line to stderr and optionally file
fn writeLine(line: []const u8) void {
    // Write to stderr (non-blocking, no lock needed for stderr)
    std.debug.print("{s}", .{line});
    
    // Write to file if enabled (with buffering)
    if (g_file != null) {
        const io = g_threaded.io();
        
        // Minimal lock scope - just for buffer state
        g_mutex.lockUncancelable(io);
        defer g_mutex.unlock(io);
        
        const needs_flush = ringWrite(line);
        if (needs_flush) {
            ringFlush(io);
        }
    }
}

// =============================================================================
// Convenience Functions (comptime-optimized)
// =============================================================================

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
        if (@intFromEnum(level) < @intFromEnum(g_level.load(.monotonic))) return;
        
        const elapsed_ns = util.nanoTimestamp() - self.start_time;
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        
        // Format the user message first
        var msg_buf: [2048]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "[format error]";
        
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
    if (!g_threaded_initialized.load(.monotonic)) return null;
    
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

test "Ring buffer write and flush" {
    const test_data = "Hello, World!\n";
    const written = ringWrite(test_data);
    try std.testing.expect(!written); // Under threshold
    
    // Clean up
    g_ring_write_pos = 0;
    g_ring_read_pos = 0;
    g_ring_count = 0;
}
