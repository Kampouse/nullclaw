//! gen_schema.zig -- Extract event tap schema from Zig types, writes schema.json.

//! Usage: zig run gen_schema.zig

//!

//! Reads TapEventType enum + TapEvent struct at comptime,

//! produces spy/src/generated/schema.json for the TypeScript codegen.



const std = @import("std");

const event_tap = @import("src/observability/event_tap.zig");



// Comptime: extract enum variant names
const tap_event_type_info = @typeInfo(event_tap.TapEventType).@"enum";
const tap_event_type_names: [tap_event_type_info.fields.len][]const u8 = blk: {
    var names: [tap_event_type_info.fields.len][]const u8 = undefined;
    for (tap_event_type_info.fields, 0..) |f, i| names[i] = f.name;
    break :blk names;
};



pub fn main() !void {

    const allocator = std.heap.page_allocator;



    // ── Build schema as Zig values ──

    const type_names = &tap_event_type_names;



    const FieldDef = struct {

        zig_name: []const u8,

        zig_type: []const u8,

        json_name: []const u8,

        json_type: []const u8,

        always_emitted: bool,

        condition: []const u8,

        description: []const u8,

    };



    const ParamDef = struct {

        name: []const u8,

        @"type": []const u8,

        required: bool,

        description: []const u8,

    };



    const RespField = struct {

        field: []const u8,

        @"type": []const u8,

        description: []const u8,

    };



    const EndpointDef = struct {

        route: []const u8,

        method: []const u8,

        description: []const u8,

        params: []const ParamDef,

        response: []const RespField,

    };



    const ContentFormat = struct {

        event_type: []const u8,

        description: []const u8,

        format: []const u8,

        example: []const u8,

    };



    const schema = .{

        .tap_event_types = .{

            .values = type_names,

        },

        .tap_event = .{

            .description = "TapEvent struct fields and their JSON serialization mappings. JSON names are hardcoded in readSinceJson().",

            .zig_type = "struct",

            .fields = &[_]FieldDef{

                .{ .zig_name = "timestamp_ns", .zig_type = "i128", .json_name = "ts", .json_type = "integer", .always_emitted = true, .condition = "", .description = "Nanosecond timestamp from util.nanoTimestamp()" },

                .{ .zig_name = "event_type",  .zig_type = "TapEventType", .json_name = "type", .json_type = "string", .always_emitted = true, .condition = "", .description = "Enum tag name via @tagName()" },

                .{ .zig_name = "session_hash", .zig_type = "u64", .json_name = "session", .json_type = "integer", .always_emitted = false, .condition = "value > 0", .description = "Wyhash of session key. Omitted when 0 (no session)." },

                .{ .zig_name = "provider",    .zig_type = "[64]u8", .json_name = "provider", .json_type = "string", .always_emitted = false, .condition = "provider_len > 0", .description = "Provider or channel name, JSON-escaped, truncated to 64 bytes" },

                .{ .zig_name = "model",       .zig_type = "[64]u8", .json_name = "model", .json_type = "string", .always_emitted = false, .condition = "model_len > 0", .description = "Model name or tool name, JSON-escaped, truncated to 64 bytes" },

                .{ .zig_name = "value1",      .zig_type = "u64", .json_name = "v1", .json_type = "integer", .always_emitted = false, .condition = "value > 0", .description = "Primary numeric: duration_ms, messages_count, status_code, iterations" },

                .{ .zig_name = "value2",      .zig_type = "u64", .json_name = "v2", .json_type = "integer", .always_emitted = false, .condition = "value > 0", .description = "Secondary numeric: tokens_used, exit_code, duration_ms" },

                .{ .zig_name = "flag",        .zig_type = "bool", .json_name = "ok", .json_type = "boolean", .always_emitted = false, .condition = "value == true", .description = "Success flag. Only emitted as true -- never false (omitted when false)." },

                .{ .zig_name = "detail",      .zig_type = "[512]u8", .json_name = "detail", .json_type = "string", .always_emitted = false, .condition = "detail_len > 0", .description = "Optional detail string, JSON-escaped, truncated to 512 bytes" },

                .{ .zig_name = "content",     .zig_type = "[8192]u8", .json_name = "content", .json_type = "string", .always_emitted = false, .condition = "content_len > 0", .description = "Message snapshots (llm_request), response preview + tool calls (llm_response). JSON-escaped, truncated to 8192 bytes." },

            },

        },

        .api_endpoints = [_]EndpointDef{

            .{ .route = "/api/events", .method = "GET", .description = "Polling endpoint for live event feed", .params = &[_]ParamDef{.{ .name = "since", .@"type" = "integer", .required = false, .description = "Ring buffer position to start from" }}, .response = &[_]RespField{ .{ .field = "pos", .@"type" = "integer", .description = "current ring buffer write position" }, .{ .field = "events", .@"type" = "SpyEvent[]", .description = "array of TapEvent JSON objects" }} },

            .{ .route = "/api/trace", .method = "GET", .description = "Events grouped by session_hash for waterfall/trace view", .params = &[_]ParamDef{.{ .name = "since", .@"type" = "integer", .required = false, .description = "Ring buffer position to start from" }, .{ .name = "session", .@"type" = "string", .required = false, .description = "Hex session hash to filter by" }}, .response = &[_]RespField{ .{ .field = "pos", .@"type" = "integer", .description = "current ring buffer write position" }, .{ .field = "sessions", .@"type" = "Record<string, SpyEvent[]>", .description = "hex_hash to events array" }} },

            .{ .route = "/api/status", .method = "GET", .description = "Gateway health, uptime, event tap status, version", .params = &[_]ParamDef{}, .response = &[_]RespField{ .{ .field = "health", .@"type" = "Record<string, {status, error?}>", .description = "component health checks" }, .{ .field = "uptime_ns", .@"type" = "integer", .description = "nanoseconds since gateway start" }, .{ .field = "event_tap", .@"type" = "{pos, ring_size} | null", .description = "event tap status or null" }, .{ .field = "version", .@"type" = "string", .description = "git build name" }} },

            .{ .route = "/spy", .method = "GET", .description = "Embedded HTML dashboard (single-file Vite build)", .params = &[_]ParamDef{}, .response = &[_]RespField{} },

        },

        .content_formats = [_]ContentFormat{

            .{ .event_type = "llm_request", .description = "Compact message snapshot", .format = "JSON array of {r: role, c: content_preview}", .example = "[{\"r\":\"user\",\"c\":\"Hello world\"},{\"r\":\"system\",\"c\":\"You are...\"}]" },

            .{ .event_type = "llm_response", .description = "Response preview + tool calls", .format = "{r: response text, t: [{n: tool_name, a: tool_args_json}]", .example = "{\"r\":\"I'll check that file.\",\"t\":[{\"n\":\"file_read\",\"a\":\"{\\\"path\\\":\\\"/tmp/x.zig\\\"}\"}]}" },

        },

        .event_field_semantics = .{
            .description = "Field meaning varies by event_type — this maps which fields carry what data per type",
            .mappings = .{
                .agent_start = .{ .provider = "provider name", .model = "model name" },
                .llm_request = .{ .provider = "provider name", .model = "model name", .v1 = "messages_count", .content = "messages_snapshot" },
                .llm_response = .{ .provider = "provider name", .model = "model name", .v1 = "duration_ms", .ok = "success", .detail = "error_message", .content = "response + tool_calls" },
                .agent_end = .{ .v1 = "duration_ms", .v2 = "tokens_used" },
                .tool_call_start = .{ .model = "tool name" },
                .tool_call = .{ .model = "tool name", .v1 = "duration_ms", .ok = "success", .detail = "tool output" },
                .tool_iterations_exhausted = .{},
                .turn_complete = .{},
                .channel_message = .{ .provider = "channel platform", .model = "channel name", .detail = "message preview" },
                .heartbeat_tick = .{},
                .err = .{ .provider = "source component", .detail = "error message" },
                .http_request = .{ .provider = "source label", .model = "HTTP method", .v1 = "status code", .v2 = "duration_ms", .ok = "success", .detail = "URL" },
            },
        },

    };



    // ── Write JSON (only if changed) ──

    const out_path = "spy/src/generated/schema.json";
    const io = std.Options.debug_io;

    const json = try std.json.Stringify.valueAlloc(allocator, schema, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    // Ensure output directory exists
    std.Io.Dir.cwd().createDirPath(io, "spy/src/generated") catch |err| {
        std.debug.print("mkdir failed: {}\n", .{err});
        return err;
    };

    // Skip write if content is identical (preserves mtime for make)
    const existing = std.Io.Dir.cwd().readFileAlloc(io, out_path, allocator, .limited(@intCast(json.len + 1))) catch null;
    if (existing) |prev| {
        defer allocator.free(prev);
        if (std.mem.eql(u8, prev, json)) {
            std.debug.print("{s} unchanged\n", .{out_path});
            return;
        }
    }

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = json }) catch |err| {
        std.debug.print("write failed: {}\n", .{err});
        return err;
    };

    std.debug.print("wrote {s} ({d} bytes)\n", .{out_path, json.len});

}
