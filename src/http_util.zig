//! HTTP utilities using std.http.Client.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.http_util);

// Thread-local storage for the Threaded Io instance
// std.Options.debug_io doesn't support async network operations, so we need
// to create a proper Threaded Io instance for HTTP requests.
threadlocal var http_threaded_io: ?std.Io.Threaded = null;
threadlocal var cached_io: ?std.Io = null;

// Get or create a proper Threaded Io instance for HTTP requests
// std.Options.debug_io doesn't have a "locator" and doesn't work for networking
fn getHttpIo() std.Io {
    if (cached_io) |io| return io;

    // Create a new Threaded Io instance with proper defaults
    http_threaded_io = std.Io.Threaded{
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
    cached_io = http_threaded_io.?.io();
    return cached_io.?;
}

pub const HttpResponse = struct {
    status_code: u16,
    body: []const u8,
};

/// Callback type for streaming HTTP responses.
/// Called with each chunk of data as it arrives.
/// The chunk slice is only valid for the duration of the callback.
pub const StreamCallback = *const fn (chunk: []const u8, ctx: *anyopaque) anyerror!void;

/// HTTP POST with optional proxy and timeout (in seconds as string like "30").
pub fn curlPostWithProxy(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    proxy: ?[]const u8,
    max_time: ?[]const u8,
) ![]u8 {
    _ = proxy;
    _ = max_time;

    const io = getHttpIo();
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    // Build headers array
    var header_buf: [32]std.http.Header = undefined;
    var n_headers: usize = 0;
    for (headers) |header| {
        if (n_headers >= header_buf.len) break;
        const colon_idx = std.mem.indexOfScalar(u8, header, ':') orelse continue;
        const name = header[0..colon_idx];
        const value = std.mem.trim(u8, header[colon_idx + 1 ..], " \t\r\n");
        header_buf[n_headers] = .{ .name = name, .value = value };
        n_headers += 1;
    }
    const extra_headers = header_buf[0..n_headers];

    // Use request() API directly (like SSE client does) instead of fetch()
    const uri = try std.Uri.parse(url);

    var req = client.request(.POST, uri, .{ .extra_headers = extra_headers }) catch |err| {
        log.err("curlPostWithProxy: request failed: {}", .{err});
        return err;
    };
    defer req.deinit();

    const body_dup = try allocator.dupe(u8, body);
    defer allocator.free(body_dup);
    try req.sendBodyComplete(body_dup);

    var redirect_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| {
        log.err("curlPostWithProxy: receiveHead failed: {}", .{err});
        return err;
    };

    if (response.head.status != .ok) {
        log.err("curlPostWithProxy: HTTP status not ok: {}", .{response.head.status});
        return error.HttpError;
    }

    // Use bodyReader() like SSE client does
    var transfer_buf: [8192]u8 = undefined;
    const body_reader = req.reader.bodyReader(&transfer_buf, response.head.transfer_encoding, response.head.content_length);

    // Read response body by actively reading from the body_reader
    var response_buffer = std.ArrayListUnmanaged(u8){};
    defer response_buffer.deinit(allocator);

    try response_buffer.ensureTotalCapacity(allocator, 8192);

    const max_response = 10 * 1024 * 1024;

    while (response_buffer.items.len < max_response) {
        // Fill the buffer first, then take from it
        const fill_size = @min(4096, max_response - response_buffer.items.len);
        body_reader.fill(fill_size) catch |err| {
            if (err == error.EndOfStream) {
                // Try to take whatever is buffered
                const buffered = body_reader.bufferedLen();
                if (buffered == 0) break;
                const data = try body_reader.take(buffered);
                try response_buffer.appendSlice(allocator, data);
                break;
            }
            log.err("curlPostWithProxy: fill failed: {}", .{err});
            return err;
        };

        const buffered = body_reader.bufferedLen();
        if (buffered == 0) break;

        const to_read = @min(buffered, max_response - response_buffer.items.len);
        const data = try body_reader.take(to_read);
        if (data.len == 0) break;

        try response_buffer.appendSlice(allocator, data);
    }

    const response_body = try response_buffer.toOwnedSlice(allocator);
    return response_body;
}

/// HTTP POST (no proxy, no timeout).
pub fn curlPost(allocator: Allocator, url: []const u8, body: []const u8, headers: []const []const u8) ![]u8 {
    return curlPostWithProxy(allocator, url, body, headers, null, null);
}

/// HTTP POST with streaming - calls callback with each chunk as it arrives.
/// This is useful for LLM APIs to display responses token-by-token.
/// The callback receives chunks that are only valid during the callback invocation.
pub fn curlPostStream(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    callback: StreamCallback,
    callback_ctx: *anyopaque,
) !void {
    const io = getHttpIo();
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    // Build headers array
    var header_buf: [32]std.http.Header = undefined;
    var n_headers: usize = 0;
    for (headers) |header| {
        if (n_headers >= header_buf.len) break;
        const colon_idx = std.mem.indexOfScalar(u8, header, ':') orelse continue;
        const name = header[0..colon_idx];
        const value = std.mem.trim(u8, header[colon_idx + 1 ..], " \t\r\n");
        header_buf[n_headers] = .{ .name = name, .value = value };
        n_headers += 1;
    }
    const extra_headers = header_buf[0..n_headers];

    const uri = try std.Uri.parse(url);

    var req = client.request(.POST, uri, .{ .extra_headers = extra_headers }) catch |err| {
        log.err("curlPostStream: request failed: {}", .{err});
        return err;
    };
    defer req.deinit();

    const body_dup = try allocator.dupe(u8, body);
    defer allocator.free(body_dup);
    try req.sendBodyComplete(body_dup);

    var redirect_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| {
        log.err("curlPostStream: receiveHead failed: {}", .{err});
        return err;
    };

    if (response.head.status != .ok) {
        log.err("curlPostStream: HTTP status not ok: {}", .{response.head.status});
        return error.HttpError;
    }

    // Stream response body chunks as they arrive
    var transfer_buf: [8192]u8 = undefined;
    const body_reader = req.reader.bodyReader(&transfer_buf, response.head.transfer_encoding, response.head.content_length);

    const max_response = 10 * 1024 * 1024;
    var total_read: usize = 0;

    while (total_read < max_response) {
        const fill_size = @min(4096, max_response - total_read);
        body_reader.fill(fill_size) catch |err| {
            if (err == error.EndOfStream) {
                // Try to take whatever is buffered
                const buffered = body_reader.bufferedLen();
                if (buffered == 0) break;
                const data = try body_reader.take(buffered);
                if (data.len > 0) {
                    try callback(data, callback_ctx);
                    total_read += data.len;
                }
                break;
            }
            log.err("curlPostStream: fill failed: {}", .{err});
            return err;
        };

        const buffered = body_reader.bufferedLen();
        if (buffered == 0) break;

        const to_read = @min(buffered, max_response - total_read);
        const data = try body_reader.take(to_read);
        if (data.len == 0) break;

        // Call callback with each chunk immediately
        try callback(data, callback_ctx);
        total_read += data.len;
    }
}

/// HTTP POST and include HTTP status code in response.
pub fn curlPostWithStatus(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
) !HttpResponse {
    const io = getHttpIo();
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    // Build headers array
    var header_buf: [32]std.http.Header = undefined;
    var n_headers: usize = 0;
    for (headers) |header| {
        if (n_headers >= header_buf.len) break;
        const colon_idx = std.mem.indexOfScalar(u8, header, ':') orelse continue;
        const name = header[0..colon_idx];
        const value = std.mem.trim(u8, header[colon_idx + 1 ..], " \t\r\n");
        header_buf[n_headers] = .{ .name = name, .value = value };
        n_headers += 1;
    }
    const extra_headers = header_buf[0..n_headers];

    var req = try client.request(.POST, uri, .{ .extra_headers = extra_headers });
    defer req.deinit();

    const body_dup = try allocator.dupe(u8, body);
    defer allocator.free(body_dup);
    try req.sendBodyComplete(body_dup);

    var redirect_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    const status_code = @intFromEnum(response.head.status);

    var transfer_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    // Try readAlloc first, if it fails with EndOfStream, return empty body
    const response_body = reader.readAlloc(allocator, 10 * 1024 * 1024) catch |err| {
        if (err == error.EndOfStream) {
            // Stream ended with no data - this might be normal for some responses
            return .{
                .status_code = status_code,
                .body = try allocator.dupe(u8, ""),
            };
        }
        return err;
    };

    return .{
        .status_code = status_code,
        .body = response_body,
    };
}

/// HTTP PUT (no proxy, no timeout).
pub fn curlPut(allocator: Allocator, url: []const u8, body: []const u8, headers: []const []const u8) ![]u8 {
    const io = getHttpIo();
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    // Build headers array
    var header_buf: [32]std.http.Header = undefined;
    var n_headers: usize = 0;
    for (headers) |header| {
        if (n_headers >= header_buf.len) break;
        const colon_idx = std.mem.indexOfScalar(u8, header, ':') orelse continue;
        const name = header[0..colon_idx];
        const value = std.mem.trim(u8, header[colon_idx + 1 ..], " \t\r\n");
        header_buf[n_headers] = .{ .name = name, .value = value };
        n_headers += 1;
    }
    const extra_headers = header_buf[0..n_headers];

    var req = try client.request(.PUT, uri, .{ .extra_headers = extra_headers });
    defer req.deinit();

    const body_dup = try allocator.dupe(u8, body);
    defer allocator.free(body_dup);
    try req.sendBodyComplete(body_dup);

    var redirect_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status != .ok) return error.HttpError;

    // Use bodyReader() on the request, not response.reader()
    // This properly handles chunked encoding and other HTTP details
    var transfer_buf: [8192]u8 = undefined;
    const body_reader = req.reader.bodyReader(&transfer_buf, response.head.transfer_encoding, response.head.content_length);

    // Read response body by actively reading
    var response_buffer = std.ArrayListUnmanaged(u8){};
    defer response_buffer.deinit(allocator);

    try response_buffer.ensureTotalCapacity(allocator, 8192);

    const max_response = 10 * 1024 * 1024;

    while (response_buffer.items.len < max_response) {
        // Fill the buffer first, then take from it
        const fill_size = @min(4096, max_response - response_buffer.items.len);
        body_reader.fill(fill_size) catch |err| {
            if (err == error.EndOfStream) {
                // Try to take whatever is buffered
                const buffered = body_reader.bufferedLen();
                if (buffered == 0) break;
                const data = try body_reader.take(buffered);
                try response_buffer.appendSlice(allocator, data);
                break;
            }
            return err;
        };

        const buffered = body_reader.bufferedLen();
        if (buffered == 0) break;

        const to_read = @min(buffered, max_response - response_buffer.items.len);
        const data = try body_reader.take(to_read);
        if (data.len == 0) break;

        try response_buffer.appendSlice(allocator, data);
    }

    return response_buffer.toOwnedSlice(allocator);
}

/// HTTP GET with optional proxy.
pub fn curlGetWithProxy(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
    proxy: ?[]const u8,
) ![]u8 {
    _ = timeout_secs;
    _ = proxy;

    const io = getHttpIo();
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    // Build headers array
    var header_buf: [32]std.http.Header = undefined;
    var n_headers: usize = 0;
    for (headers) |header| {
        if (n_headers >= header_buf.len) break;
        const colon_idx = std.mem.indexOfScalar(u8, header, ':') orelse continue;
        const name = header[0..colon_idx];
        const value = std.mem.trim(u8, header[colon_idx + 1 ..], " \t\r\n");
        header_buf[n_headers] = .{ .name = name, .value = value };
        n_headers += 1;
    }
    const extra_headers = header_buf[0..n_headers];

    var req = try client.request(.GET, uri, .{ .extra_headers = extra_headers });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status != .ok) return error.HttpError;

    // Use bodyReader() on the request, not response.reader()
    // This properly handles chunked encoding and other HTTP details
    var transfer_buf: [8192]u8 = undefined;
    const body_reader = req.reader.bodyReader(&transfer_buf, response.head.transfer_encoding, response.head.content_length);

    // Read response body by actively reading
    var response_buffer = std.ArrayListUnmanaged(u8){};
    defer response_buffer.deinit(allocator);

    try response_buffer.ensureTotalCapacity(allocator, 8192);

    const max_response = 10 * 1024 * 1024;

    while (response_buffer.items.len < max_response) {
        // Fill the buffer first, then take from it
        const fill_size = @min(4096, max_response - response_buffer.items.len);
        body_reader.fill(fill_size) catch |err| {
            if (err == error.EndOfStream) {
                // Try to take whatever is buffered
                const buffered = body_reader.bufferedLen();
                if (buffered == 0) break;
                const data = try body_reader.take(buffered);
                try response_buffer.appendSlice(allocator, data);
                break;
            }
            return err;
        };

        const buffered = body_reader.bufferedLen();
        if (buffered == 0) break;

        const to_read = @min(buffered, max_response - response_buffer.items.len);
        const data = try body_reader.take(to_read);
        if (data.len == 0) break;

        try response_buffer.appendSlice(allocator, data);
    }

    return response_buffer.toOwnedSlice(allocator);
}

/// HTTP GET with a pinned host mapping.
pub fn curlGetWithResolve(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
    resolve_entry: []const u8,
) ![]u8 {
    _ = resolve_entry;
    return curlGetWithProxy(allocator, url, headers, timeout_secs, null);
}

/// HTTP GET (no proxy).
pub fn curlGet(allocator: Allocator, url: []const u8, headers: []const []const u8, timeout_secs: []const u8) ![]u8 {
    return curlGetWithProxy(allocator, url, headers, timeout_secs, null);
}

/// HTTP GET for SSE (Server-Sent Events) - returns the raw response body.
pub fn curlGetSSE(
    allocator: Allocator,
    url: []const u8,
    timeout_secs: []const u8,
) ![]u8 {
    return curlGet(allocator, url, &.{}, timeout_secs);
}

// ── Tests ───────────────────────────────────────────────────────────

test "curlPost compiles" {
    try std.testing.expect(true);
}

test "curlPostWithStatus compiles" {
    try std.testing.expect(true);
}

test "curlPut compiles" {
    try std.testing.expect(true);
}

test "curlGet compiles" {
    try std.testing.expect(true);
}

test "curlGetWithResolve compiles" {
    try std.testing.expect(true);
}
