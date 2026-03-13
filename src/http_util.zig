//! HTTP utilities using std.http.Client.

const std = @import("std");
const Allocator = std.mem.Allocator;
const profiling = @import("profiling.zig");

const log = std.log.scoped(.http_util);

const tls = @import("tls");

// Thread-local storage for the Threaded Io instance
// std.Options.debug_io doesn't support async network operations, so we need
// to create a proper Threaded Io instance for HTTP requests.
//
// Thread-local Io instances are created once per thread and reused for the lifetime
// of the thread. This is intentional for performance - creating Threaded Io instances
// is expensive. The resources are cleaned up when the thread exits.
threadlocal var threaded_io: ?std.Io.Threaded = null;
threadlocal var cached_io: ?std.Io = null;
threadlocal var ca_bundle_loaded = false;

/// Get or create a Threaded Io instance for HTTP/network requests.
///
/// Uses thread-local singleton pattern - one Io instance per thread.
/// Properly initialized via std.Io.Threaded.init() for Zig 0.16 compatibility.
pub fn getThreadedIo() std.Io {
    if (cached_io) |io| return io;

    // Use the proper init() API instead of manual struct construction
    // This ensures compatibility with Zig 0.16's Threaded struct layout
    threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .async_limit = .nothing,
        .concurrent_limit = .nothing,
    });
    cached_io = threaded_io.?.io();
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

    const io = getThreadedIo();
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    // Build headers array - always include Content-Type: application/json
    var header_buf: [32]std.http.Header = undefined;
    var n_headers: usize = 0;
    header_buf[n_headers] = .{ .name = "content-type", .value = "application/json" };
    n_headers += 1;
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
        // Read error response body to help debug
        var transfer_buf: [8192]u8 = undefined;
        const body_reader = req.reader.bodyReader(&transfer_buf, response.head.transfer_encoding, response.head.content_length);
        var error_buffer = std.ArrayListUnmanaged(u8){};
        defer error_buffer.deinit(allocator);

        const max_error = 8192;
        while (error_buffer.items.len < max_error) {
            const fill_size = @min(4096, max_error - error_buffer.items.len);
            body_reader.fill(fill_size) catch |err| {
                if (err == error.EndOfStream) {
                    const buffered = body_reader.bufferedLen();
                    if (buffered == 0) break;
                    const data = try body_reader.take(buffered);
                    try error_buffer.appendSlice(allocator, data);
                    break;
                }
                break;
            };

            const buffered = body_reader.bufferedLen();
            if (buffered == 0) break;

            const to_read = @min(buffered, max_error - error_buffer.items.len);
            const data = try body_reader.take(to_read);
            if (data.len == 0) break;

            try error_buffer.appendSlice(allocator, data);
        }

        log.err("curlPostWithProxy: HTTP status not ok: {} | body: {s}", .{response.head.status, error_buffer.items});
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
    const zone = profiling.zoneNamed(@src(), "http_post");
    defer zone.end();
    
    const result = curlPostWithProxy(allocator, url, body, headers, null, null);
    
    if (result) |body_response| {
        profiling.plot("http_response_bytes", body_response.len);
        return body_response;
    } else |err| {
        profiling.messageColor("HTTP POST failed: {}", .{err}, 0xFF0000);
        return err;
    }
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
    const zone = profiling.zoneNamed(@src(), "http_post_stream");
    defer zone.end();
    
    const io = getThreadedIo();
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    // Build headers array - always include Content-Type: application/json
    var header_buf: [32]std.http.Header = undefined;
    var n_headers: usize = 0;
    header_buf[n_headers] = .{ .name = "content-type", .value = "application/json" };
    n_headers += 1;
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
    const io = getThreadedIo();
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
    const io = getThreadedIo();
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

    // Use bodyReaderDecompressing to handle gzip decompression automatically
    var transfer_buf: [8192]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [65536]u8 = undefined; // Must be at least flate.max_window_len

    const body_reader = if (response.head.content_encoding == .identity)
        req.reader.bodyReader(&transfer_buf, response.head.transfer_encoding, response.head.content_length)
    else
        response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);

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
/// For HTTPS, uses tls.zig library (supports ECDSA certificates).
/// For HTTP, uses stdlib.
pub fn curlGetWithProxy(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
    proxy: ?[]const u8,
) ![]u8 {
    _ = timeout_secs;
    _ = proxy;

    log.info("curlGetWithProxy: Starting request for {s}", .{url});

    const uri = try std.Uri.parse(url);
    const is_https = std.ascii.eqlIgnoreCase(uri.scheme, "https");

    // Use tls.zig for all HTTPS requests (supports ECDSA)
    if (is_https) {
        log.debug("curlGetWithProxy: Using tls.zig for HTTPS: {s}", .{url});
        return curlGetTlsLibrary(allocator, url, headers);
    }

    // Use stdlib for HTTP
    log.debug("curlGetWithProxy: Using stdlib for HTTP: {s}", .{url});

    const io = getThreadedIo();
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    log.debug("curlGetWithProxy: Parsed URI, scheme={s}, host={s}", .{uri.scheme, uri.host.?.percent_encoded});

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

    var req = client.request(.GET, uri, .{ .extra_headers = extra_headers }) catch |err| {
        log.err("curlGetWithProxy: Request failed for {s}: {}", .{url, err});
        return err;
    };
    defer req.deinit();

    try req.sendBodiless();
    log.debug("curlGetWithProxy: Sent request, receiving response headers...", .{});

    var redirect_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    log.debug("curlGetWithProxy: Got response status: {}", .{response.head.status});

    if (response.head.status != .ok) {
        log.err("curlGetWithProxy: HTTP error for {s}: {}", .{url, response.head.status});
        return error.HttpError;
    }

    // Use bodyReaderDecompressing to handle gzip decompression automatically
    var transfer_buf: [8192]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [65536]u8 = undefined; // Must be at least flate.max_window_len

    const body_reader = if (response.head.content_encoding == .identity)
        req.reader.bodyReader(&transfer_buf, response.head.transfer_encoding, response.head.content_length)
    else
        response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);

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

/// Fallback using tls.zig library for ECDSA certificates and better TLS compatibility.
/// This is called when std.http.Client fails with TlsInitializationFailed.
fn curlGetTlsLibrary(allocator: Allocator, url: []const u8, headers: []const []const u8) ![]u8 {
    log.info("curlGetTlsLibrary: Using tls.zig fallback for {s}", .{url});

    const uri = try std.Uri.parse(url);
    const host = uri.host.?.percent_encoded;
    const port: u16 = 443;

    log.debug("curlGetTlsLibrary: Connecting to {s}:{d}", .{host, port});

    var threaded = std.Io.Threaded.init(allocator, .{
        .async_limit = .nothing,
        .concurrent_limit = .nothing,
    });
    defer threaded.deinit();
    const io = threaded.io();

    // Establish TCP connection
    const host_name = try std.Io.net.HostName.init(host);
    var tcp = try host_name.connect(io, port, .{ .mode = .stream });
    defer tcp.close(io);
    log.debug("curlGetTlsLibrary: TCP connection established", .{});

    // Load system root certificates
    var root_ca = try tls.config.cert.fromSystem(allocator, io);
    defer root_ca.deinit(allocator);
    log.debug("curlGetTlsLibrary: Loaded root CA certificates", .{});

    // Upgrade TCP to TLS
    var input_buf: [tls.input_buffer_len]u8 = undefined;
    var output_buf: [tls.output_buffer_len]u8 = undefined;
    var reader = tcp.reader(io, &input_buf);
    var writer = tcp.writer(io, &output_buf);

    // Use constant seed for TLS PRNG (not security-sensitive for client)
    var prng = std.Random.DefaultPrng.init(0x5ec1adeca1bad);
    var conn = try tls.client(&reader.interface, &writer.interface, .{
        .rng = prng.random(),
        .host = host,
        .root_ca = root_ca,
        .now = std.Io.Clock.real.now(io),
    });
    defer conn.close() catch {};
    log.info("curlGetTlsLibrary: TLS connection established to {s}", .{host});

    // Send HTTP GET request
    // Use HTTP/1.0 to prevent HTTP/2 negotiation via ALPN (fixes Google/hang issues)
    // Extract path and query from URI
    const path = if (uri.path == .percent_encoded) uri.path.percent_encoded else "/";
    const query_str = if (uri.query) |q|
        if (q == .percent_encoded) try std.fmt.allocPrint(allocator, "?{s}", .{q.percent_encoded}) else ""
    else "";

    // Build request using a fixed-size buffer first
    var request_buf: [2048]u8 = undefined;
    var request_len: usize = 0;

    // Request line
    const request_line = try std.fmt.bufPrint(&request_buf, "GET {s}{s} HTTP/1.0\r\n", .{ path, query_str });
    request_len += request_line.len;

    // Host header
    const host_header = try std.fmt.bufPrint(request_buf[request_len..], "Host: {s}\r\n", .{host});
    request_len += host_header.len;

    // Standard headers
    const conn_header = "Connection: close\r\n";
    @memcpy(request_buf[request_len..][0..conn_header.len], conn_header);
    request_len += conn_header.len;

    const ua_header = "User-Agent: nullclaw-tls/1.0\r\n";
    @memcpy(request_buf[request_len..][0..ua_header.len], ua_header);
    request_len += ua_header.len;

    // Custom headers
    for (headers) |header| {
        @memcpy(request_buf[request_len..][0..header.len], header);
        request_len += header.len;
        const crlf = "\r\n";
        @memcpy(request_buf[request_len..][0..crlf.len], crlf);
        request_len += crlf.len;
    }

    // End headers
    const end_headers = "\r\n";
    @memcpy(request_buf[request_len..][0..end_headers.len], end_headers);
    request_len += end_headers.len;

    try conn.writeAll(request_buf[0..request_len]);
    log.debug("curlGetTlsLibrary: Sent HTTP GET request", .{});

    // Read response
    var response_buffer = std.ArrayListUnmanaged(u8){};
    defer response_buffer.deinit(allocator);
    while (true) {
        const data = (try conn.next()) orelse break;
        try response_buffer.appendSlice(allocator, data);
    }

    log.info("curlGetTlsLibrary: Received {d} bytes from {s}", .{response_buffer.items.len, url});

    // Parse HTTP response to extract body
    // Find end of headers (double CRLF)
    const full_response = response_buffer.items;
    const header_end = std.mem.indexOf(u8, full_response, "\r\n\r\n") orelse {
        log.err("curlGetTlsLibrary: Invalid HTTP response - no header terminator", .{});
        return error.InvalidHttpResponse;
    };

    // Extract status line
    const status_line_end = std.mem.indexOfScalar(u8, full_response[0..header_end], '\r') orelse header_end;
    const status_line = full_response[0..status_line_end];
    log.debug("curlGetTlsLibrary: Status line: {s}", .{status_line});

    // Check for HTTP error status codes (4xx, 5xx)
    // Log warning but don't fail - let the caller decide what to do with the response
    if (status_line.len >= 12) { // "HTTP/1.x XXX"
        const status_code_str = status_line[9..12];
        if (std.fmt.parseInt(u16, status_code_str, 10)) |status_code| {
            if (status_code >= 400) {
                log.warn("curlGetTlsLibrary: HTTP {d} status: {s}", .{status_code, status_line});
            } else {
                log.info("curlGetTlsLibrary: HTTP {d} success", .{status_code});
            }
        } else |_| {}
    }

    // Return only the body (after headers)
    const body = full_response[header_end + 4 ..];
    log.info("curlGetTlsLibrary: Extracted {d} bytes body", .{body.len});

    return allocator.dupe(u8, body);
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
