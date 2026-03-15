//! Structured logging for Grafana/Loki compatibility.
//!
//! Outputs JSON-formatted logs to stderr that can be ingested by Loki.
//!
//! Example output:
//!   {"timestamp":"2025-03-12T10:30:45.123Z","level":"DEBUG","scope":"my_module","message":"process_started","fields":{}}

const std = @import("std");

/// EMERGENCY: Override std.log to prevent macOS __simple_asl_init memory corruption
pub const std_log = struct {
    pub fn log(
        comptime level: std.log.Level,
        comptime scope: @TypeOf(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        // COMPLETELY DISABLED: Prevent all logging to avoid memory corruption
        _ = level;
        _ = scope;
        _ = format;
        _ = args;
    }
};

// Declare C time function
extern "c" fn time(?*i64) i64;

/// Log levels ordered by severity (lower = more verbose).
pub const Level = enum(u2) {
    DEBUG = 0,
    INFO = 1,
    WARN = 2,
    ERROR = 3,
};

/// Thread-local buffer for formatted timestamp.
/// Using thread_local ensures each thread has its own buffer,
/// making timestamp generation thread-safe without locks.
threadlocal var timestamp_buffer: [32]u8 = undefined;

/// Get current timestamp in ISO 8601 format (UTC).
/// Format: 2025-03-12T10:30:45.000Z
fn getTimestamp() []const u8 {
    // Use C's time() function to get current Unix timestamp
    const unix_timestamp = time(null);

    if (unix_timestamp == -1) {
        // Fallback to placeholder if time() fails
        const placeholder = "1970-01-01T00:00:00.000Z";
        @memcpy(timestamp_buffer[0..placeholder.len], placeholder);
        return timestamp_buffer[0..placeholder.len];
    }

    // Convert Unix timestamp to datetime
    // For simplicity, we'll use a basic calculation for UTC time
    // This avoids pulling in complex timezone handling

    // Days per month in non-leap year
    const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    // Calculate year, month, day from Unix timestamp
    // This is a simplified calculation that works for years 1970-2099
    var remaining_secs = unix_timestamp;
    var year: i64 = 1970;

    // Calculate years
    while (remaining_secs >= 365 * 86400) {
        const is_leap = (@rem(year, 4) == 0 and @rem(year, 100) != 0) or (@rem(year, 400) == 0);
        const days_in_year = if (is_leap) @as(i64, 366) else 365;
        if (remaining_secs < days_in_year * 86400) break;
        remaining_secs -= days_in_year * 86400;
        year += 1;
    }

    // Calculate month and day
    var month: u8 = 1;
    var day: u8 = 1;
    var days_remaining = @as(usize, @intCast(@divTrunc(remaining_secs, 86400)));
    remaining_secs = @rem(remaining_secs, 86400);

    const is_leap = (@rem(year, 4) == 0 and @rem(year, 100) != 0) or (@rem(year, 400) == 0);
    const month_days = if (is_leap) [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 } else days_in_month;

    for (month_days, 0..) |days, m| {
        if (days_remaining < days) {
            month = @as(u8, @intCast(m + 1));
            day = @as(u8, @intCast(days_remaining + 1));
            break;
        }
        days_remaining -= days;
    }

    // Calculate time
    const hours = @as(u8, @intCast(@divTrunc(remaining_secs, 3600)));
    remaining_secs = @rem(remaining_secs, 3600);
    const minutes = @as(u8, @intCast(@divTrunc(remaining_secs, 60)));
    const seconds = @as(u8, @intCast(@rem(remaining_secs, 60)));

    // We don't have sub-second precision with time(), so use 000 for milliseconds
    const milliseconds: u12 = 0;

    // Format as ISO 8601 string
    const written = std.fmt.bufPrint(timestamp_buffer[0..], "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(u32, @intCast(year)), month, day, hours, minutes, seconds, milliseconds,
    }) catch unreachable;

    return written;
}

/// Log a structured JSON entry to stderr for Grafana/Loki ingestion.
///
/// Parameters:
///   - level: Log level (e.g., "DEBUG", "INFO", "WARN", "ERROR")
///   - scope: Module/component name (e.g., "process_util", "agent")
///   - message: Log message describing the event
///   - fields: Optional struct with key-value pairs (e.g., .{ .user_id = "123" })
///
/// Global log level filter. Can be set via environment variable.
/// Default: show all logs (DEBUG and above)
var max_log_level: Level = .DEBUG;

/// EMERGENCY DISABLE: Disable all logging to fix macOS __simple_asl_init memory corruption
/// TEMPORARY: Set to true to disable all logging system-wide
const EMERGENCY_LOG_DISABLE = true;

/// Initialize logging system from environment variables.
/// Call this at program startup to configure log level.
pub fn init() void {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "NULLCLAW_LOG_LEVEL")) |env| {
        defer std.heap.page_allocator.free(env);
        const upper = std.ascii.upperConst(env);
        max_log_level = std.meta.stringToEnum(Level, upper) orelse .DEBUG;
    } else |_| {
        // Default to DEBUG level if env var not set
        max_log_level = .DEBUG;
    }
}

/// Check if a log level should be output based on current configuration.
/// Only logs at or above the max_log_level severity are shown.
fn shouldLog(level: Level) bool {
    return @intFromEnum(level) >= @intFromEnum(max_log_level);
}

/// Log a structured JSON entry to stderr for Grafana/Loki ingestion.
///
/// Parameters:
///   - level: Log level (e.g., "DEBUG", "INFO", "WARN", "ERROR")
///   - scope: Module/component name (e.g., "process_util", "agent")
///   - message: Log message describing the event
///   - fields: Optional struct with key-value pairs (e.g., .{ .user_id = "123" })
///
pub fn logStructured(
    comptime level: []const u8,
    comptime scope: []const u8,
    comptime message: []const u8,
    fields: anytype,
) void {
    // EMERGENCY DISABLE: Immediately return to prevent macOS logging corruption
    if (EMERGENCY_LOG_DISABLE) return;

    // Check log level filter
    const level_enum = std.meta.stringToEnum(Level, level) orelse return;
    if (!shouldLog(level_enum)) return;

    // Get current timestamp in ISO 8601 format
    const timestamp = getTimestamp();

    // For now, use a simple format string approach
    // In the future, we can extend this to support arbitrary fields
    const has_fields = @typeInfo(@TypeOf(fields)) == .@"struct" and @typeInfo(@TypeOf(fields)).@"struct".fields.len > 0;

    if (has_fields) {
        // Improved field serialization for common types
        const fields_info = @typeInfo(@TypeOf(fields)).@"struct";
        if (fields_info.fields.len == 1) {
            const field = fields_info.fields[0];
            const value = @field(fields, field.name);

            // Format based on type - handle common cases inline
            const T = @TypeOf(value);
            if (T == []const u8 or T == []u8) {
                // String or byte array
                std.debug.print("{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"scope\":\"{s}\",\"message\":\"{s}\",\"fields\":{{\"{s}\":\"{s}\"}}}}\n", .{ timestamp, level, scope, message, field.name, value });
            } else if (@typeInfo(T) == .pointer) {
                // Pointer - check child type to determine what to do
                const ptr_info = @typeInfo(T).pointer;
                const Child = ptr_info.child;

                if (@typeInfo(Child) == .array) {
                    // This is *const [N]u8 or *const [N:0]u8 (pointer to array, like string literal)
                    // In Zig 0.16, sentinel arrays [N:0]T have N elements excluding the sentinel
                    // Convert to slice by casting to [*]const u8 and finding null terminator
                    const array_ptr: [*]const u8 = value;
                    const array_len = @typeInfo(Child).array.len;
                    // Scan for null terminator to get actual string length
                    var actual_len: usize = 0;
                    while (actual_len < array_len and array_ptr[actual_len] != 0) : (actual_len += 1) {}
                    const slice = array_ptr[0..actual_len];
                    std.debug.print("{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"scope\":\"{s}\",\"message\":\"{s}\",\"fields\":{{\"{s}\":\"{s}\"}}}}\n", .{ timestamp, level, scope, message, field.name, slice });
                } else if (ptr_info.size == .many and Child == u8) {
                    // [*]const u8 (many-item pointer) - treat as C string
                    const c_str: [*:0]const u8 = @ptrCast(value);
                    const slice = std.mem.span(c_str);
                    std.debug.print("{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"scope\":\"{s}\",\"message\":\"{s}\",\"fields\":{{\"{s}\":\"{s}\"}}}}\n", .{ timestamp, level, scope, message, field.name, slice });
                } else {
                    // Other pointer type - fallback
                    std.debug.print("{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"scope\":\"{s}\",\"message\":\"{s}\",\"fields\":{{\"{s}\":\"?\"}}}}\n", .{ timestamp, level, scope, message, field.name });
                }
            } else if (T == u32 or T == u64 or T == i32 or T == i64 or T == usize or T == isize) {
                // Integer
                std.debug.print("{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"scope\":\"{s}\",\"message\":\"{s}\",\"fields\":{{\"{s}\":\"{d}\"}}}}\n", .{ timestamp, level, scope, message, field.name, value });
            } else if (@typeInfo(T) == .int or T == comptime_int) {
                // Comptime integers
                std.debug.print("{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"scope\":\"{s}\",\"message\":\"{s}\",\"fields\":{{\"{s}\":\"{d}\"}}}}\n", .{ timestamp, level, scope, message, field.name, value });
            } else if (@typeInfo(T) == .float) {
                // Float types (f32, f64, etc.)
                std.debug.print("{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"scope\":\"{s}\",\"message\":\"{s}\",\"fields\":{{\"{s}\":\"{e}\"}}}}\n", .{ timestamp, level, scope, message, field.name, value });
            } else if (@typeInfo(T) == .@"struct") {
                // Nested struct - serialize recursively
                std.debug.print("{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"scope\":\"{s}\",\"message\":\"{s}\",\"fields\":{{\"{s}\":{{", .{ timestamp, level, scope, message, field.name });
                const struct_info = @typeInfo(T).@"struct";
                inline for (struct_info.fields, 0..) |nested_field, i| {
                    if (i > 0) std.debug.print(",", .{});
                    const nested_value = @field(value, nested_field.name);
                    std.debug.print("\"{s}\":", .{nested_field.name});

                    // Recursively format the nested value
                    const NestedT = @TypeOf(nested_value);
                    if (NestedT == []const u8 or NestedT == []u8) {
                        std.debug.print("\"{s}\"", .{nested_value});
                    } else if (@typeInfo(NestedT) == .pointer) {
                        const nested_ptr_info = @typeInfo(NestedT).pointer;
                        const NestedChild = nested_ptr_info.child;
                        if (@typeInfo(NestedChild) == .array) {
                            const array_ptr: [*]const u8 = nested_value;
                            const array_len = @typeInfo(NestedChild).array.len;
                            var actual_len: usize = 0;
                            while (actual_len < array_len and array_ptr[actual_len] != 0) : (actual_len += 1) {}
                            const slice = array_ptr[0..actual_len];
                            std.debug.print("\"{s}\"", .{slice});
                        } else if (nested_ptr_info.size == .many and NestedChild == u8) {
                            const c_str: [*:0]const u8 = @ptrCast(nested_value);
                            const slice = std.mem.span(c_str);
                            std.debug.print("\"{s}\"", .{slice});
                        } else {
                            std.debug.print("\"?\"", .{});
                        }
                    } else if (NestedT == u32 or NestedT == u64 or NestedT == i32 or NestedT == i64 or NestedT == usize or NestedT == isize) {
                        std.debug.print("\"{d}\"", .{nested_value});
                    } else if (@typeInfo(NestedT) == .int or NestedT == comptime_int) {
                        std.debug.print("\"{d}\"", .{nested_value});
                    } else if (@typeInfo(NestedT) == .float) {
                        std.debug.print("\"{e}\"", .{nested_value});
                    } else if (NestedT == bool) {
                        std.debug.print("\"{any}\"", .{nested_value});
                    } else {
                        std.debug.print("\"?\"", .{});
                    }
                }
                std.debug.print("}}}}\n", .{});
            } else if (T == bool) {
                // Boolean
                std.debug.print("{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"scope\":\"{s}\",\"message\":\"{s}\",\"fields\":{{\"{s}\":\"{any}\"}}}}\n", .{ timestamp, level, scope, message, field.name, value });
            } else {
                // Fallback for other types
                std.debug.print("{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"scope\":\"{s}\",\"message\":\"{s}\",\"fields\":{{\"{s}\":\"?\"}}}}\n", .{ timestamp, level, scope, message, field.name });
            }
        } else {
            // Multiple fields - serialize all of them
            // Print the opening of the JSON
            std.debug.print("{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"scope\":\"{s}\",\"message\":\"{s}\",\"fields\":{{", .{ timestamp, level, scope, message });

            // Iterate over fields at compile time using inline loop
            inline for (fields_info.fields, 0..) |field, i| {
                const value = @field(fields, field.name);
                const T = @TypeOf(value);

                // Add comma if not first field
                if (i > 0) {
                    std.debug.print(",", .{});
                }

                // Format field name
                std.debug.print("\"{s}\":", .{field.name});

                // Format field value based on type
                if (T == []const u8 or T == []u8) {
                    std.debug.print("\"{s}\"", .{value});
                } else if (@typeInfo(T) == .pointer) {
                    // Pointer handling for string literals
                    const ptr_info = @typeInfo(T).pointer;
                    const Child = ptr_info.child;

                    if (@typeInfo(Child) == .array) {
                        // String literal (*const [N:0]u8)
                        const array_ptr: [*]const u8 = value;
                        const array_len = @typeInfo(Child).array.len;
                        var actual_len: usize = 0;
                        while (actual_len < array_len and array_ptr[actual_len] != 0) : (actual_len += 1) {}
                        const slice = array_ptr[0..actual_len];
                        std.debug.print("\"{s}\"", .{slice});
                    } else if (ptr_info.size == .many and Child == u8) {
                        // C string [*:0]const u8
                        const c_str: [*:0]const u8 = @ptrCast(value);
                        const slice = std.mem.span(c_str);
                        std.debug.print("\"{s}\"", .{slice});
                    } else {
                        std.debug.print("\"?\"", .{});
                    }
                } else if (T == u32 or T == u64 or T == i32 or T == i64 or T == usize or T == isize) {
                    std.debug.print("\"{d}\"", .{value});
                } else if (@typeInfo(T) == .int or T == comptime_int) {
                    // Comptime integers or other int types
                    std.debug.print("\"{d}\"", .{value});
                } else if (@typeInfo(T) == .float) {
                    // Float types (f32, f64, etc.)
                    std.debug.print("\"{e}\"", .{value});
                } else if (@typeInfo(T) == .@"struct") {
                    // Nested struct - serialize recursively
                    std.debug.print("{{", .{});
                    const struct_info = @typeInfo(T).@"struct";
                    inline for (struct_info.fields, 0..) |nested_field, j| {
                        if (j > 0) std.debug.print(",", .{});
                        const nested_value = @field(value, nested_field.name);
                        std.debug.print("\"{s}\":", .{nested_field.name});

                        // Recursively format the nested value
                        const NestedT = @TypeOf(nested_value);
                        if (NestedT == []const u8 or NestedT == []u8) {
                            std.debug.print("\"{s}\"", .{nested_value});
                        } else if (@typeInfo(NestedT) == .pointer) {
                            const nested_ptr_info = @typeInfo(NestedT).pointer;
                            const NestedChild = nested_ptr_info.child;
                            if (@typeInfo(NestedChild) == .array) {
                                const array_ptr: [*]const u8 = nested_value;
                                const array_len = @typeInfo(NestedChild).array.len;
                                var actual_len: usize = 0;
                                while (actual_len < array_len and array_ptr[actual_len] != 0) : (actual_len += 1) {}
                                const slice = array_ptr[0..actual_len];
                                std.debug.print("\"{s}\"", .{slice});
                            } else if (nested_ptr_info.size == .many and NestedChild == u8) {
                                const c_str: [*:0]const u8 = @ptrCast(nested_value);
                                const slice = std.mem.span(c_str);
                                std.debug.print("\"{s}\"", .{slice});
                            } else {
                                std.debug.print("\"?\"", .{});
                            }
                        } else if (NestedT == u32 or NestedT == u64 or NestedT == i32 or NestedT == i64 or NestedT == usize or NestedT == isize) {
                            std.debug.print("\"{d}\"", .{nested_value});
                        } else if (@typeInfo(NestedT) == .int or NestedT == comptime_int) {
                            std.debug.print("\"{d}\"", .{nested_value});
                        } else if (@typeInfo(NestedT) == .float) {
                            std.debug.print("\"{e}\"", .{nested_value});
                        } else if (NestedT == bool) {
                            std.debug.print("\"{any}\"", .{nested_value});
                        } else {
                            std.debug.print("\"?\"", .{});
                        }
                    }
                    std.debug.print("}}", .{});
                } else if (T == bool) {
                    std.debug.print("\"{any}\"", .{value});
                } else {
                    std.debug.print("\"?\"", .{});
                }
            }

            // Close the JSON
            std.debug.print("}}\n", .{});
        }
    } else {
        std.debug.print("{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"scope\":\"{s}\",\"message\":\"{s}\"}}\n", .{ timestamp, level, scope, message });
    }
}

/// Convenience function for DEBUG level logs
pub fn debug(comptime scope: []const u8, comptime message: []const u8, fields: anytype) void {
    logStructured("DEBUG", scope, message, fields);
}

/// Convenience function for INFO level logs
pub fn info(comptime scope: []const u8, comptime message: []const u8, fields: anytype) void {
    logStructured("INFO", scope, message, fields);
}

/// Convenience function for WARN level logs
pub fn warn(comptime scope: []const u8, comptime message: []const u8, fields: anytype) void {
    logStructured("WARN", scope, message, fields);
}

/// Convenience function for ERROR level logs
pub fn err(comptime scope: []const u8, comptime message: []const u8, fields: anytype) void {
    logStructured("ERROR", scope, message, fields);
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "logStructured outputs valid JSON" {
    debug("test_module", "test_message", .{.test_field = "test_value"});
}

test "logStructured with no fields" {
    info("test_module", "test_no_fields", .{});
}

test "logStructured with multiple fields" {
    warn("test_module", "test_multiple", .{
        .user_id = "123",
        .action = "login",
        .count = 42,
    });
}

test "log level filtering - INFO level shows INFO and above" {
    // Set max log level to INFO
    max_log_level = .INFO;

    // DEBUG should not appear (filtered out)
    debug("test", "debug_msg", .{.field = "should_not_appear"});

    // INFO should appear
    info("test", "info_msg", .{.field = "should_appear"});

    // WARN should appear
    warn("test", "warn_msg", .{});

    // ERROR should appear
    err("test", "error_msg", .{});

    // Reset to DEBUG for other tests
    max_log_level = .DEBUG;
}

test "log level filtering - ERROR level shows only ERROR" {
    // Set max log level to ERROR
    max_log_level = .ERROR;

    // DEBUG, INFO, WARN should not appear
    debug("test", "debug_msg", .{});
    info("test", "info_msg", .{});
    warn("test", "warn_msg", .{});

    // ERROR should appear
    err("test", "error_msg", .{.field = "only_error"});

    // Reset to DEBUG for other tests
    max_log_level = .DEBUG;
}

test "logStructured with float fields" {
    debug("test", "float_values", .{
        .pi_f32 = @as(f32, 3.14159),
        .pi_f64 = @as(f64, 3.14159265359),
        .large = @as(f64, 1.0e10),
    });
}

test "logStructured with nested struct fields" {
    debug("test", "nested_struct", .{
        .user = .{
            .id = "12345",
            .name = "Alice",
            .age = 30,
        },
    });
}

test "logStructured with multiple nested structs" {
    info("test", "multiple_nested", .{
        .request = .{
            .method = "GET",
            .path = "/api/users",
        },
        .response = .{
            .status = 200,
            .latency_ms = 45,
        },
    });
}
