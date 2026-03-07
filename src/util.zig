const std = @import("std");

/// CRITICAL: std.Options.debug_io uses a .failing allocator (see Io/Threaded.zig:1622)
/// This causes OutOfMemory when std.process.run() creates internal ArenaAllocator.
/// Helper function to create a Threaded Io instance with page_allocator for process spawning.
/// Use this for any code that needs to spawn child processes.
pub fn createProcessIo() std.Io {
    var threaded_io = std.Io.Threaded{
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
    return threaded_io.ioBasic();
}

/// Format bytes as human-readable string (e.g. "3.4 MB")
pub fn formatBytes(bytes: u64) struct { value: f64, unit: []const u8 } {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var size: f64 = @floatFromInt(bytes);
    var idx: usize = 0;
    while (size >= 1024.0 and idx < units.len - 1) : (idx += 1) {
        size /= 1024.0;
    }
    return .{ .value = size, .unit = units[idx] };
}

/// Get current timestamp as ISO 8601 string
pub fn timestamp(buf: []u8) []const u8 {
    // Use C library time in Zig 0.16.0
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    const epoch = tv.sec;
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(epoch) };
    const day = epoch_seconds.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const result = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch "0000-00-00T00:00:00Z";

    return result;
}

test "formatBytes" {
    const result = formatBytes(3_500_000);
    try std.testing.expect(result.value > 3.3 and result.value < 3.4);
    try std.testing.expectEqualStrings("MB", result.unit);
}

test "timestamp produces valid length" {
    var buf: [32]u8 = undefined;
    const ts = timestamp(&buf);
    try std.testing.expectEqual(@as(usize, 20), ts.len);
}

/// Get current Unix timestamp in seconds (Zig 0.16.0 compatible)
pub fn timestampUnix() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return tv.sec;
}

/// Get current Unix timestamp in nanoseconds (Zig 0.16.0 compatible)
pub fn nanoTimestamp() i128 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    const secs: i128 = @intCast(tv.sec);
    const usecs: i128 = @intCast(tv.usec);
    return secs * 1_000_000_000 + usecs * 1_000;
}

/// Fill buffer with random bytes (Zig 0.16.0 compatible)
pub fn randomBytes(buf: []u8) void {
    const io = std.Options.debug_io;
    io.random(buf);
}

/// Get a random integer of the specified type (Zig 0.16.0 compatible)
pub fn randomInt(comptime T: type) T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    randomBytes(&bytes);
    return std.mem.readInt(T, &bytes, .little);
}

// ── FixedBufferStream Compatibility Layer for Zig 0.16.0 ───────────────

/// FixedBufferStream provides a buffer stream compatible with Zig 0.16.0's IO interface.
/// This replaces the removed std.io.fixedBufferStream functionality.
pub const FixedBufferStream = struct {
    buf: []u8,
    pos: usize = 0,

    const Self = @This();

    /// Create a new FixedBufferStream backed by the provided buffer.
    pub fn init(buf: []u8) Self {
        return .{ .buf = buf, .pos = 0 };
    }

    /// Get a writer for this stream (compatible with Zig 0.16.0's IO interface).
    pub fn writer(self: *Self) Writer {
        return .{ .context = self };
    }

    /// Get the written portion of the buffer.
    pub fn getWritten(self: *const Self) []const u8 {
        return self.buf[0..self.pos];
    }

    /// Write bytes to the buffer. Returns error.OutOfMemory if buffer is full.
    pub fn write(self: *Self, bytes: []const u8) error{OutOfMemory}!usize {
        if (self.pos + bytes.len > self.buf.len) {
            return error.OutOfMemory;
        }
        @memcpy(self.buf[self.pos .. self.pos + bytes.len], bytes);
        self.pos += bytes.len;
        return bytes.len;
    }

    /// Write all bytes to the buffer (compatibility method).
    pub fn writeAll(self: *Self, bytes: []const u8) error{OutOfMemory}!void {
        const n = try self.write(bytes);
        if (n != bytes.len) return error.OutOfMemory;
    }

    /// Write a byte to the buffer.
    pub fn writeByte(self: *Self, byte: u8) error{OutOfMemory}!void {
        if (self.pos >= self.buf.len) return error.OutOfMemory;
        self.buf[self.pos] = byte;
        self.pos += 1;
    }

    /// Print formatted string to the buffer.
    pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        const result = std.fmt.bufPrint(self.buf[self.pos..], fmt, args) catch return error.OutOfMemory;
        self.pos += result.len;
    }

    /// Writer interface for Zig 0.16.0.
    pub const Writer = struct {
        context: *Self,

        pub const Error = error{OutOfMemory};

        pub fn write(self: Writer, bytes: []const u8) Error!usize {
            return self.context.write(bytes);
        }

        pub fn writeAll(self: Writer, bytes: []const u8) Error!void {
            return self.context.writeAll(bytes);
        }

        pub fn writeByte(self: Writer, byte: u8) Error!void {
            return self.context.writeByte(byte);
        }

        pub fn print(self: Writer, comptime fmt: []const u8, args: anytype) Error!void {
            return self.context.print(fmt, args);
        }

        pub fn writeStreamingAll(self: Writer, io: std.Io, bytes: []const u8) Error!void {
            _ = io;
            return self.context.writeAll(bytes);
        }
    };
};

/// Convenience function to create a FixedBufferStream (Zig 0.16.0 compatible).
/// Replaces std.io.fixedBufferStream which was removed in Zig 0.16.0.
pub fn fixedBufferStream(buf: []u8) FixedBufferStream {
    return FixedBufferStream.init(buf);
}

// ── JSON helpers ────────────────────────────────────────────────

/// Append a string to an ArrayList with JSON escaping (quotes, backslashes, control chars).
/// Used by embedding providers, vector stores, and API backends when building JSON payloads.
pub fn appendJsonEscaped(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) {
                    var hex_buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{ch}) catch continue;
                    try buf.appendSlice(allocator, hex);
                } else {
                    try buf.append(allocator, ch);
                }
            },
        }
    }
}

// ── Additional util tests ───────────────────────────────────────

test "formatBytes zero" {
    const result = formatBytes(0);
    try std.testing.expect(result.value == 0.0);
    try std.testing.expectEqualStrings("B", result.unit);
}

test "formatBytes exact KB" {
    const result = formatBytes(1024);
    try std.testing.expect(result.value == 1.0);
    try std.testing.expectEqualStrings("KB", result.unit);
}

test "formatBytes exact MB" {
    const result = formatBytes(1024 * 1024);
    try std.testing.expect(result.value == 1.0);
    try std.testing.expectEqualStrings("MB", result.unit);
}

test "formatBytes exact GB" {
    const result = formatBytes(1024 * 1024 * 1024);
    try std.testing.expect(result.value == 1.0);
    try std.testing.expectEqualStrings("GB", result.unit);
}

test "formatBytes exact TB" {
    const result = formatBytes(1024 * 1024 * 1024 * 1024);
    try std.testing.expect(result.value == 1.0);
    try std.testing.expectEqualStrings("TB", result.unit);
}

test "formatBytes small value stays in bytes" {
    const result = formatBytes(500);
    try std.testing.expect(result.value == 500.0);
    try std.testing.expectEqualStrings("B", result.unit);
}

test "formatBytes 1 byte" {
    const result = formatBytes(1);
    try std.testing.expect(result.value == 1.0);
    try std.testing.expectEqualStrings("B", result.unit);
}

test "formatBytes large value" {
    const result = formatBytes(5 * 1024 * 1024 * 1024 * 1024);
    try std.testing.expect(result.value > 4.9 and result.value < 5.1);
    try std.testing.expectEqualStrings("TB", result.unit);
}

test "timestamp ends with Z" {
    var buf: [32]u8 = undefined;
    const ts = timestamp(&buf);
    try std.testing.expect(ts[ts.len - 1] == 'Z');
}

test "timestamp contains T separator" {
    var buf: [32]u8 = undefined;
    const ts = timestamp(&buf);
    try std.testing.expect(std.mem.indexOf(u8, ts, "T") != null);
}

test "appendJsonEscaped basic text" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendJsonEscaped(&buf, std.testing.allocator, "hello world");
    try std.testing.expectEqualStrings("hello world", buf.items);
}

test "appendJsonEscaped escapes special chars" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendJsonEscaped(&buf, std.testing.allocator, "say \"hello\"\nnewline\\backslash");
    try std.testing.expectEqualStrings("say \\\"hello\\\"\\nnewline\\\\backslash", buf.items);
}

test "appendJsonEscaped escapes control chars" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendJsonEscaped(&buf, std.testing.allocator, "tab\there\rreturn");
    try std.testing.expectEqualStrings("tab\\there\\rreturn", buf.items);
}

test "appendJsonEscaped empty string" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendJsonEscaped(&buf, std.testing.allocator, "");
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}
