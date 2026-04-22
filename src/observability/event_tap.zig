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

/// Maximum content payload for llm events (message snapshots, response previews).
pub const MAX_CONTENT_LEN: usize = 8192;

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
    /// Outbound HTTP request completed. detail=url, model=method, v1=status, v2=duration_ms, ok=success, provider=source_label.
    http_request,

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
    content: [MAX_CONTENT_LEN]u8 = [_]u8{0} ** MAX_CONTENT_LEN,
    content_len: u16 = 0,
    /// Session identifier - Wyhash of session key (e.g. "telegram:5125145880").
    /// Set via threadlocal before agent turn. 0 means no session.
    session_hash: u64 = 0,

    fn copyString(dst: []u8, src: []const u8) usize {
        const len = @min(src.len, dst.len);
        @memcpy(dst[0..len], src[0..len]);
        return len;
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

/// Thread-local session hash - set before agent turn, read during record().
/// 0 = no session context (eval endpoint, health checks, etc.).
threadlocal var current_session_hash: u64 = 0;

/// Set the session hash for the current thread. Call before agent.turn().
pub fn setSessionHash(hash: u64) void {
    current_session_hash = hash;
}

/// Get the current thread's session hash.
pub fn getSessionHash() u64 {
    return current_session_hash;
}

/// Record an outbound HTTP request directly into the event tap.
/// Bypasses the observer vtable — called from http_util.zig.
/// All params are optional comptime-known strings except url/method.
/// Thread-safe, allocation-free (truncates to fit fixed-size fields).
pub fn recordHttpRequest(
    url: []const u8,
    method: []const u8,
    status_code: u16,
    duration_ms: u64,
    success: bool,
    source_label: []const u8,
) void {
    const tap = global_tap orelse return;
    // Spinlock for write
    while (tap.write_lock.swap(true, .acquire)) {}
    defer tap.write_lock.store(false, .release);

    const pos = tap.write_pos.load(.monotonic);
    const idx = pos % RING_SIZE;
    var entry = &tap.ring[idx];
    entry.timestamp_ns = 0; // will be set below
    entry.event_type = .http_request;
    entry.provider_len = 0;
    entry.model_len = @intCast(TapEvent.copyString(&entry.model, method));
    entry.value1 = status_code;
    entry.value2 = duration_ms;
    entry.flag = success;
    entry.detail_len = @intCast(TapEvent.copyString(&entry.detail, url));
    entry.content_len = 0;
    entry.provider_len = @intCast(TapEvent.copyString(&entry.provider, source_label));
    entry.timestamp_ns = util.nanoTimestamp();
    entry.session_hash = current_session_hash;

    tap.write_pos.store(pos + 1, .release);
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
        entry.content_len = 0;
        entry.session_hash = 0;

        switch (event.*) {
            .agent_start => |e| {
                entry.event_type = .agent_start;
                entry.provider_len = @intCast(TapEvent.copyString(&entry.provider, e.provider));
                entry.model_len = @intCast(TapEvent.copyString(&entry.model, e.model));
            },
            .llm_request => |e| {
                entry.event_type = .llm_request;
                entry.provider_len = @intCast(TapEvent.copyString(&entry.provider, e.provider));
                entry.model_len = @intCast(TapEvent.copyString(&entry.model, e.model));
                entry.value1 = @intCast(e.messages_count);
                if (e.messages_snapshot.len > 0) {
                    entry.content_len = @intCast(TapEvent.copyString(&entry.content, e.messages_snapshot));
                }
            },
            .llm_response => |e| {
                entry.event_type = .llm_response;
                entry.provider_len = @intCast(TapEvent.copyString(&entry.provider, e.provider));
                entry.model_len = @intCast(TapEvent.copyString(&entry.model, e.model));
                entry.value1 = e.duration_ms;
                entry.flag = e.success;
                if (e.error_message) |msg| {
                    entry.detail_len = @intCast(TapEvent.copyString(&entry.detail, msg));
                }
                if (e.response_preview.len > 0 and e.tool_calls_json.len > 0) {
                    var cbuf: [MAX_CONTENT_LEN]u8 = [_]u8{0} ** MAX_CONTENT_LEN;
                    const combined = std.fmt.bufPrint(&cbuf, "{{\"r\":\"{s}\",\"t\":{s}}}", .{ e.response_preview, e.tool_calls_json }) catch "";
                    entry.content_len = @intCast(TapEvent.copyString(&entry.content, combined));
                } else if (e.response_preview.len > 0) {
                    entry.content_len = @intCast(TapEvent.copyString(&entry.content, e.response_preview));
                } else if (e.tool_calls_json.len > 0) {
                    entry.content_len = @intCast(TapEvent.copyString(&entry.content, e.tool_calls_json));
                }
            },
            .agent_end => |e| {
                entry.event_type = .agent_end;
                entry.value1 = e.duration_ms;
                if (e.tokens_used) |tok| entry.value2 = tok;
            },
            .tool_call_start => |e| {
                entry.event_type = .tool_call_start;
                entry.model_len = @intCast(TapEvent.copyString(&entry.model, e.tool));
            },
            .tool_call => |e| {
                entry.event_type = .tool_call;
                entry.model_len = @intCast(TapEvent.copyString(&entry.model, e.tool));
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
                entry.provider_len = @intCast(TapEvent.copyString(&entry.provider, e.channel));
                entry.model_len = @intCast(TapEvent.copyString(&entry.model, e.direction));
            },
            .heartbeat_tick => {
                entry.event_type = .heartbeat_tick;
            },
            .err => |e| {
                entry.event_type = .err;
                entry.provider_len = @intCast(TapEvent.copyString(&entry.provider, e.component));
                entry.detail_len = @intCast(TapEvent.copyString(&entry.detail, e.message));
            },
        }

        // Capture session hash from threadlocal (set before agent.turn())
        entry.session_hash = current_session_hash;

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

            // session
            if (entry.session_hash > 0) {
                fbs.writeAll(",\"session\":") catch break;
                fbs.print("{d}", .{entry.session_hash}) catch break;
            }

            // provider
            if (entry.provider_len > 0) {
                fbs.writeAll(",\"provider\":\"") catch break;
                writeJsonString(&fbs, entry.provider[0..entry.provider_len]) catch break;
                fbs.writeAll("\"") catch break;
            }

            // model (used for tool name too)
            if (entry.model_len > 0) {
                fbs.writeAll(",\"model\":\"") catch break;
                writeJsonString(&fbs, entry.model[0..entry.model_len]) catch break;
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
                writeJsonString(&fbs, entry.detail[0..entry.detail_len]) catch break;
                fbs.writeAll("\"") catch break;
            }

            // content payload
            if (entry.content_len > 0) {
                fbs.writeAll(",\"content\":\"") catch break;
                writeJsonString(&fbs, entry.content[0..entry.content_len]) catch break;
                fbs.writeAll("\"") catch break;
            }

            fbs.writeAll("}") catch break;
            count += 1;
            pos += 1;
        }

        fbs.writeAll("]") catch {};
        return fbs.getWritten();
    }

    /// Read events since a given position, grouped by session_hash.
    /// Returns JSON object: { "session_hash_hex": [events...], ... }
    /// If session_filter is provided, only return that session's events.
    pub fn readTraceSinceJson(self: *const EventTap, since_pos: u64, buf: []u8, session_filter: ?[]const u8) []const u8 {
        var fbs = util.FixedBufferStream.init(buf);
        fbs.writeAll("{") catch {
            @memcpy(buf[0..2], "{}");
            return buf[0..2];
        };

        const current_write = self.write_pos.load(.acquire);
        var pos = @max(since_pos, if (current_write > RING_SIZE) current_write - RING_SIZE else 0);

        // Parse session filter to u64
        const filter_hash: u64 = if (session_filter) |sf| blk: {
            break :blk std.fmt.parseInt(u64, sf, 16) catch 0;
        } else 0;

        // Track unique session hashes we've started writing
        var seen_sessions: [32]u64 = [_]u64{0} ** 32;
        var seen_event_counts: [32]usize = [_]usize{0} ** 32;
        var seen_count: usize = 0;

        while (pos < current_write) {
            const idx = pos % RING_SIZE;
            const entry = &self.ring[idx];
            pos += 1;

            // Apply session filter
            if (filter_hash > 0 and entry.session_hash != filter_hash) continue;

            // Find or start this session group
            const sh = entry.session_hash;
            var session_idx: usize = 0;
            var found = false;
            for (seen_sessions[0..seen_count], 0..) |s, i| {
                if (s == sh) {
                    found = true;
                    session_idx = i;
                    break;
                }
            }
            if (!found) {
                if (seen_count >= seen_sessions.len) break; // too many sessions
                // Close previous session's array (not before first)
                if (seen_count > 0) {
                    fbs.writeAll("]") catch break;
                }
                session_idx = seen_count;
                seen_sessions[seen_count] = sh;
                seen_event_counts[seen_count] = 0;
                seen_count += 1;

                // Write comma separator between session groups (not before first)
                if (seen_count > 1) {
                    fbs.writeAll(",") catch break;
                }
                fbs.writeAll("\"") catch break;
                fbs.print("{x}", .{sh}) catch break;
                fbs.writeAll("\":[") catch break;
            }

            // Comma separator between events within a session
            if (seen_event_counts[session_idx] > 0) {
                fbs.writeAll(",") catch break;
            }

            // Write the event (same format as readSinceJson but without surrounding array)
            fbs.writeAll("{\"ts\":") catch break;
            fbs.print("{d}", .{entry.timestamp_ns}) catch break;
            fbs.writeAll(",\"type\":\"") catch break;
            fbs.writeAll(@tagName(entry.event_type)) catch break;
            fbs.writeAll("\"") catch break;

            if (entry.session_hash > 0) {
                fbs.writeAll(",\"session\":") catch break;
                fbs.print("{d}", .{entry.session_hash}) catch break;
            }
            if (entry.provider_len > 0) {
                fbs.writeAll(",\"provider\":\"") catch break;
                writeJsonString(&fbs, entry.provider[0..entry.provider_len]) catch break;
                fbs.writeAll("\"") catch break;
            }
            if (entry.model_len > 0) {
                fbs.writeAll(",\"model\":\"") catch break;
                writeJsonString(&fbs, entry.model[0..entry.model_len]) catch break;
                fbs.writeAll("\"") catch break;
            }
            if (entry.value1 > 0) {
                fbs.writeAll(",\"v1\":") catch break;
                fbs.print("{d}", .{entry.value1}) catch break;
            }
            if (entry.value2 > 0) {
                fbs.writeAll(",\"v2\":") catch break;
                fbs.print("{d}", .{entry.value2}) catch break;
            }
            if (entry.flag) {
                fbs.writeAll(",\"ok\":true") catch break;
            }
            if (entry.detail_len > 0) {
                fbs.writeAll(",\"detail\":\"") catch break;
                writeJsonString(&fbs, entry.detail[0..entry.detail_len]) catch break;
                fbs.writeAll("\"") catch break;
            }
            if (entry.content_len > 0) {
                fbs.writeAll(",\"content\":\"") catch break;
                writeJsonString(&fbs, entry.content[0..entry.content_len]) catch break;
                fbs.writeAll("\"") catch break;
            }
            fbs.writeAll("}") catch break;
            seen_event_counts[session_idx] += 1;
        }

        // Close last session array and outer object
        if (seen_count > 0) {
            fbs.writeAll("]") catch {};
        }
        fbs.writeAll("}") catch {};
        return fbs.getWritten();
    }

    /// Write a byte slice as a JSON-escaped string (no surrounding quotes).
    /// Escapes control characters (0x00-0x1F) via \u00XX, plus " and \.
    /// Invalid UTF-8 bytes (lone continuations, overlong sequences, etc.)
    /// are also escaped as \u00XX to ensure valid JSON output.
    fn writeJsonString(fbs: *util.FixedBufferStream, data: []const u8) @TypeOf(fbs.writer()).Error!void {
        const w = fbs.writer();
        const hex = "0123456789abcdef";
        var i: usize = 0;
        while (i < data.len) {
            const c = data[i];
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => {
                    if (c < 0x20) {
                        // Control character
                        try w.writeAll("\\u00");
                        try w.writeByte(hex[c >> 4]);
                        try w.writeByte(hex[c & 0x0f]);
                    } else if (c < 0x80) {
                        // Valid ASCII (0x20-0x7F)
                        try w.writeByte(c);
                    } else {
                        // Multi-byte UTF-8 — validate and write or escape
                        const seq_len: usize = switch (c) {
                            0xC0...0xDF => 2,
                            0xE0...0xEF => 3,
                            0xF0...0xF7 => 4,
                            else => 0, // invalid start byte (0x80-0xBF, 0xF8-0xFF)
                        };
                        if (seq_len == 0 or i + seq_len > data.len) {
                            // Invalid start byte or truncated sequence — escape this byte
                            try w.writeAll("\\u00");
                            try w.writeByte(hex[c >> 4]);
                            try w.writeByte(hex[c & 0x0f]);
                            i += 1;
                            continue;
                        }
                        // Validate continuation bytes
                        var valid = true;
                        for (data[i + 1 .. i + seq_len]) |cb| {
                            if (cb < 0x80 or cb > 0xBF) {
                                valid = false;
                                break;
                            }
                        }
                        // Check for overlong encodings
                        if (valid and seq_len == 2 and c < 0xC2) valid = false;
                        if (valid and seq_len == 3 and c == 0xE0 and data[i + 1] < 0xA0) valid = false;
                        if (valid and seq_len == 3 and c == 0xED and data[i + 1] > 0x9F) valid = false;
                        if (valid and seq_len == 4 and c == 0xF0 and data[i + 1] < 0x90) valid = false;
                        if (valid and seq_len == 4 and c == 0xF4 and data[i + 1] > 0x8F) valid = false;

                        if (!valid) {
                            // Invalid sequence — escape just the start byte
                            try w.writeAll("\\u00");
                            try w.writeByte(hex[c >> 4]);
                            try w.writeByte(hex[c & 0x0f]);
                            i += 1;
                            continue;
                        }
                        // Valid UTF-8 sequence — write raw bytes
                        for (data[i .. i + seq_len]) |b| {
                            try w.writeByte(b);
                        }
                        i += seq_len;
                        continue;
                    }
                },
            }
            i += 1;
        }
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
    try testing.expectEqual(@as(usize, 4), len);
    try testing.expectEqualSlices(u8, "hell", buf[0..len]);
}
