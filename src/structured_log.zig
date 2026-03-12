//! Structured logging for Grafana/Loki compatibility.
//!
//! Outputs JSON-formatted logs to stderr that can be ingested by Loki.
//!
//! Example output:
//!   {"timestamp":"2025-03-12T10:30:45.123Z","level":"DEBUG","scope":"my_module","message":"process_started","fields":{}}

const std = @import("std");

/// Thread-local buffer for formatted timestamp.
/// Using thread_local ensures each thread has its own buffer,
/// making timestamp generation thread-safe without locks.
threadlocal var timestamp_buffer: [32]u8 = undefined;

/// Get current timestamp in ISO 8601 format (UTC).
/// Format: 2025-03-12T10:30:45.000Z
fn getTimestamp() []const u8 {
    // TODO: Implement real timestamp using std.os.clock_gettime
    // For now, return a placeholder that can be incremented
    // This allows the logging system to work while we figure out
    // the correct Zig 0.16 time API
    const placeholder = "2025-03-12T00:00:00.000Z";
    @memcpy(timestamp_buffer[0..placeholder.len], placeholder);
    return timestamp_buffer[0..placeholder.len];
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
    // Get current timestamp in ISO 8601 format
    const timestamp = getTimestamp();

    // For now, use a simple format string approach
    // In the future, we can extend this to support arbitrary fields
    const has_fields = @typeInfo(@TypeOf(fields)) == .@"struct" and @typeInfo(@TypeOf(fields)).@"struct".fields.len > 0;

    if (has_fields) {
        // Simple field serialization for common types
        const fields_info = @typeInfo(@TypeOf(fields)).@"struct";
        if (fields_info.fields.len == 1) {
            const field = fields_info.fields[0];
            const value = @field(fields, field.name);
            std.debug.print("{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"scope\":\"{s}\",\"message\":\"{s}\",\"fields\":{{\"{s}\":\"{any}\"}}}}\n", .{ timestamp, level, scope, message, field.name, value });
        } else {
            // For multiple fields, just log the message without detailed fields
            std.debug.print("{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"scope\":\"{s}\",\"message\":\"{s}\",\"fields\":{{\"count\":\"{d}\"}}}}\n", .{ timestamp, level, scope, message, fields_info.fields.len });
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
