//! Event Tap — global ring buffer that records all ObserverEvents.
//!
//! Used by the /spy dashboard to provide a real-time live feed.
//! The EventTap is a lock-free single-producer multiple-consumer ring buffer.
//! Only one thread writes (the agent's observer callback), but multiple
//! SSE connections may read concurrently. A spinlock protects writes;
//! readers use atomic seq for the read cursor.

const std = @import("std");
const observability = @import("../observability.zig");
const util = @import("../util.zig");

const log = std.log.scoped(.event_tap);

/// Maximum events retained in the ring buffer.
/// ~512 events at ~200 bytes each = ~100KB. Enough for the last few minutes.
pub const RING_SIZE: usize = 512;

/// Maximum detail string length stored per event (truncated if longer).
pub const MAX_DETAIL_LEN: usize = 256;

/// Event types for JSON serialization (simpler than the full ObserverEvent union).
pub const TapEventType = enum {
    agent_start,
    llm_request,
    llm_response,
    agent_end,
    tool_call_start,
    tool_call,
    tool_iterations_exhausted,
    turn_complete,
    channel_message,
    heartbeat_tick,
    err,

    pub fn jsonStringify(self: TapEventType, jw: anytype) !void {
        try jw.write(@tagName(self));
    }
};

/// A serialized event stored in the ring buffer.
/// Uses fixed-size fields to avoid per-event allocations.
pub const TapEvent = struct {
    timestamp_ns: i128,
    event_type: TapEventType,
    /// Provider or channel name (truncated to fit).
    provider: [64]u8 = [_]u8{0} ** 64,
    provider_len: u8 = 0,
    /// Model name or tool name (truncated to fit).
    model: [64]u8 = [_]u8{0} ** 64,
    model_len: u8 = 0,
    /// Numeric value: duration_ms, messages_count, iterations, etc.
    value1: u64 = 0,
    /// Second numeric value: tokens, exit code, etc.
    value2: u64 = 0,
    /// Boolean: success, is_error, etc.
    flag: bool = false,
    /// Optional detail string (truncated).
    detail: [MAX_DETAIL_LEN]u8 = [_]u8{0} ** MAX_DETAIL_LEN,
    detail_len: u16 = 0,

    fn copyString(dst: []u8, src: []const u8) u8 {
        const len = @min(src.len, dst.len);
        @memcpy(dst[0..len], src[0..len]);
        return @intCast(len);
    }

    fn getString(src: []const u8, len: u8) []const u8 {
        return src[0..len];
    }
};

/// Global event tap instance. Initialized once, never freed (process lifetime).
/// Access via eventTap().
var global_tap: ?*EventTap = null;
var global_tap_spinlock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Initialize the global event tap. Call once at startup.
/// Uses page_allocator since the tap is a process-lifetime singleton.
pub fn initGlobal() !void {
    while (global_tap_spinlock.swap(true, .acquire)) {}
    defer global_tap_spinlock.store(false, .release);

    if (global_tap != null) return;

    const tap = try std.heap.page_allocator.create(EventTap);
    tap.* = EventTap.init();
    global_tap = tap;
}

/// Get the global event tap as an Observer. Returns NoopObserver if not initialized.
pub fn globalObserver() observability.Observer {
    const tap = getTap() orelse {
        var noop = observability.NoopObserver{};
        return noop.observer();
    };
    return tap.observer();
}

/// Get the global event tap pointer (null if not initialized).
pub fn getTap() ?*EventTap {
    return global_tap;
}

/// Thread-safe event tap with ring buffer storage.
pub const EventTap = struct {
    /// Ring buffer of events.
    ring: [RING_SIZE]TapEvent = [_]TapEvent{TapEvent{
        .timestamp_ns = 0,
        .event_type = @as(TapEventType, @enumFromInt(0)),
    }} ** RING_SIZE,
    /// Write position (monotonically increasing, wraps via modulo).
    write_pos: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Spinlock for write serialization (single-writer in practice).
    write_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init() EventTap {
        return .{};
    }

    /// Record an event into the ring buffer.
    /// Called from the observer vtable — must be fast and allocation-free.
    pub fn record(self: *EventTap, event: *const observability.ObserverEvent) void {
        // Spinlock for write (contention is rare — single agent thread).
        while (self.write_lock.swap(true, .acquire)) {}
        defer self.write_lock.store(false, .release);

        const pos = self.write_pos.load(.monotonic);
        const idx = pos % RING_SIZE;
        var entry = &self.ring[idx];
        entry.timestamp_ns = util.nanoTimestamp();
        entry.event_type = @as(TapEventType, @enumFromInt(0));
        entry.provider_len = 0;
        entry.model_len = 0;
        entry.value1 = 0;
        entry.value2 = 0;
        entry.flag = false;
        entry.detail_len = 0;

        switch (event.*) {
            .agent_start => |e| {
                entry.event_type = .agent_start;
                entry.provider_len = TapEvent.copyString(&entry.provider, e.provider);
                entry.model_len = TapEvent.copyString(&entry.model, e.model);
            },
            .llm_request => |e| {
                entry.event_type = .llm_request;
                entry.provider_len = TapEvent.copyString(&entry.provider, e.provider);
                entry.model_len = TapEvent.copyString(&entry.model, e.model);
                entry.value1 = @intCast(e.messages_count);
            },
            .llm_response => |e| {
                entry.event_type = .llm_response;
                entry.provider_len = TapEvent.copyString(&entry.provider, e.provider);
                entry.model_len = TapEvent.copyString(&entry.model, e.model);
                entry.value1 = e.duration_ms;
                entry.flag = e.success;
                if (e.error_message) |msg| {
                    entry.detail_len = @intCast(TapEvent.copyString(&entry.detail, msg));
                }
            },
            .agent_end => |e| {
                entry.event_type = .agent_end;
                entry.value1 = e.duration_ms;
                if (e.tokens_used) |tok| entry.value2 = tok;
            },
            .tool_call_start => |e| {
                entry.event_type = .tool_call_start;
                entry.model_len = TapEvent.copyString(&entry.model, e.tool);
            },
            .tool_call => |e| {
                entry.event_type = .tool_call;
                entry.model_len = TapEvent.copyString(&entry.model, e.tool);
                entry.value1 = e.duration_ms;
                entry.flag = e.success;
                if (e.detail) |d| {
                    entry.detail_len = @intCast(TapEvent.copyString(&entry.detail, d));
                }
            },
            .tool_iterations_exhausted => |e| {
                entry.event_type = .tool_iterations_exhausted;
                entry.value1 = e.iterations;
            },
            .turn_complete => {
                entry.event_type = .turn_complete;
            },
            .channel_message => |e| {
                entry.event_type = .channel_message;
                entry.provider_len = TapEvent.copyString(&entry.provider, e.channel);
                entry.model_len = TapEvent.copyString(&entry.model, e.direction);
            },
            .heartbeat_tick => {
                entry.event_type = .heartbeat_tick;
            },
            .err => |e| {
                entry.event_type = .err;
                entry.provider_len = TapEvent.copyString(&entry.provider, e.component);
                entry.detail_len = @intCast(TapEvent.copyString(&entry.detail, e.message));
            },
        }

        self.write_pos.store(pos + 1, .release);
    }

    /// Get the current write position. Events before this position are available.
    pub fn currentPos(self: *const EventTap) u64 {
        return self.write_pos.load(.acquire);
    }

    /// Read events since a given position. Returns the number of events read.
    /// Writes JSON array into the provided buffer.
    /// Returns the slice of buf containing the JSON.
    pub fn readSinceJson(self: *const EventTap, since_pos: u64, buf: []u8) []const u8 {
        var fbs = util.FixedBufferStream.init(buf);
        fbs.writeAll("[") catch {
            @memcpy(buf[0..2], "[]");
            return buf[0..2];
        };
        var count: usize = 0;
        const current_write = self.write_pos.load(.acquire);
        var pos = @max(since_pos, if (current_write > RING_SIZE) current_write - RING_SIZE else 0);

        while (pos < current_write) {
            const idx = pos % RING_SIZE;
            const entry = &self.ring[idx];

            if (count > 0) fbs.writeAll(",") catch break;

            fbs.writeAll("{\"ts\":") catch break;
            fbs.print("{d}", .{entry.timestamp_ns}) catch break;
            fbs.writeAll(",\"type\":\"") catch break;
            fbs.writeAll(@tagName(entry.event_type)) catch break;
            fbs.writeAll("\"") catch break;

            // provider
            if (entry.provider_len > 0) {
                fbs.writeAll(",\"provider\":\"") catch break;
                fbs.writeAll(entry.provider[0..entry.provider_len]) catch break;
                fbs.writeAll("\"") catch break;
            }

            // model (used for tool name too)
            if (entry.model_len > 0) {
                fbs.writeAll(",\"model\":\"") catch break;
                fbs.writeAll(entry.model[0..entry.model_len]) catch break;
                fbs.writeAll("\"") catch break;
            }

            // value1
            if (entry.value1 > 0) {
                fbs.writeAll(",\"v1\":") catch break;
                fbs.print("{d}", .{entry.value1}) catch break;
            }

            // value2
            if (entry.value2 > 0) {
                fbs.writeAll(",\"v2\":") catch break;
                fbs.print("{d}", .{entry.value2}) catch break;
            }

            // flag
            if (entry.flag) {
                fbs.writeAll(",\"ok\":true") catch break;
            }

            // detail
            if (entry.detail_len > 0) {
                fbs.writeAll(",\"detail\":\"") catch break;
                // JSON-escape the detail
                const detail = entry.detail[0..entry.detail_len];
                for (detail) |c| {
                    switch (c) {
                        '"' => fbs.writeAll("\\\"") catch break,
                        '\\' => fbs.writeAll("\\\\") catch break,
                        '\n' => fbs.writeAll("\\n") catch break,
                        '\r' => fbs.writeAll("\\r") catch break,
                        '\t' => fbs.writeAll("\\t") catch break,
                        else => fbs.writeAll(&.{c}) catch break,
                    }
                }
                fbs.writeAll("\"") catch break;
            }

            fbs.writeAll("}") catch break;
            count += 1;
            pos += 1;
        }

        fbs.writeAll("]") catch {};
        return fbs.getWritten();
    }

    /// Create an Observer vtable that feeds into this EventTap.
    pub fn observer(self: *EventTap) observability.Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .record_event = recordEvent,
                .record_metric = recordMetric,
                .flush = flush,
                .name = name,
            },
        };
    }

    fn recordEvent(ptr: *anyopaque, event: *const observability.ObserverEvent) void {
        const self: *EventTap = @ptrCast(@alignCast(ptr));
        self.record(event);
    }

    fn recordMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
    fn flush(_: *anyopaque) void {}
    fn name(_: *anyopaque) []const u8 {
        return "event_tap";
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "EventTap records and reads events" {
    var tap = EventTap.init();

    // Record a tool_call event
    const tool_start = observability.ObserverEvent{
        .tool_call_start = .{ .tool = "shell" },
    };
    tap.record(&tool_start);

    const tool_result = observability.ObserverEvent{
        .tool_call = .{
            .tool = "shell",
            .duration_ms = 150,
            .success = true,
            .detail = "exit 0",
        },
    };
    tap.record(&tool_result);

    // Read all events
    var json_buf: [4096]u8 = undefined;
    const json = tap.readSinceJson(0, &json_buf);

    // Should contain both events
    try testing.expect(std.mem.indexOf(u8, json, "\"tool_call_start\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"tool_call\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"shell\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"v1\":150") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"ok\":true") != null);
}

test "EventTap ring buffer wraps correctly" {
    var tap = EventTap.init();

    // Fill more than RING_SIZE events
    for (0..RING_SIZE + 10) |i| {
        const ev = observability.ObserverEvent{
            .tool_call_start = .{ .tool = "test" },
        };
        _ = i;
        tap.record(&ev);
    }

    // The write position should be RING_SIZE + 10
    try testing.expectEqual(@as(u64, RING_SIZE + 10), tap.currentPos());

    // Reading from position 0 should only give the last RING_SIZE events
    var json_buf: [65536]u8 = undefined;
    const json = tap.readSinceJson(0, &json_buf);

    // Count events by counting occurrences of "tool_call_start"
    var count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOf(u8, json[search_from..], "\"tool_call_start\"")) |idx| {
        count += 1;
        search_from += idx + 1;
    }
    try testing.expectEqual(RING_SIZE, count);
}

test "EventTap observer vtable works" {
    var tap = EventTap.init();
    const obs = tap.observer();

    const ev = observability.ObserverEvent{
        .llm_request = .{
            .provider = "anthropic",
            .model = "claude-opus-4",
            .messages_count = 5,
        },
    };
    obs.recordEvent(&ev);

    try testing.expectEqual(@as(u64, 1), tap.currentPos());

    var json_buf: [2048]u8 = undefined;
    const json = tap.readSinceJson(0, &json_buf);
    try testing.expect(std.mem.indexOf(u8, json, "\"anthropic\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"claude-opus-4\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"v1\":5") != null);
}

test "TapEvent.copyString truncates correctly" {
    var buf: [4]u8 = undefined;
    const len = TapEvent.copyString(&buf, "hello world");
    try testing.expectEqual(@as(u8, 4), len);
    try testing.expectEqualSlices(u8, "hell", buf[0..len]);
}
