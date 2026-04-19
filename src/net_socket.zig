const std = @import("std");

// Direct extern declarations for BSD socket API (Zig 0.16 I/O subsystem has race conditions)
extern fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern fn bind(fd: c_int, addr: *const anyopaque, addrlen: std.c.socklen_t) c_int;
extern fn listen(fd: c_int, backlog: c_int) c_int;
extern fn accept(fd: c_int, addr: ?*anyopaque, addrlen: ?*std.c.socklen_t) c_int;
extern fn close(fd: c_int) c_int;
extern fn read(fd: c_int, buf: *anyopaque, count: usize) isize;
extern fn write(fd: c_int, buf: *const anyopaque, count: usize) isize;
extern fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: std.c.socklen_t) c_int;

// macOS socket constants
const AF_INET: c_int = 2;
const SOCK_STREAM: c_int = 1;
const SOL_SOCKET: c_int = 0xffff;
const SO_REUSEADDR: c_int = 4;
const SO_RCVTIMEO: c_int = 0x1006; // SO_RCVTIMEO on macOS/BSD

const sockaddr_in = extern struct {
    len: u8 = @sizeOf(@This()),
    family: u8 = AF_INET,
    port: u16,
    addr: u32 align(1),
    zero: [8]u8 = [_]u8{0} ** 8,
};

/// Create a listening socket using direct BSD socket calls
/// Returns the socket fd or error
pub fn listenSocket(host: []const u8, port: u16) !c_int {
    _ = host; // TODO: parse host for non-localhost

    // Create socket
    const server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) return error.SocketFailed;

    // Set SO_REUSEADDR
    const opt: c_int = 1;
    _ = setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, @sizeOf(c_int));

    // Bind
    var addr: sockaddr_in = .{
        .port = @byteSwap(port),
        .addr = 0, // 0.0.0.0
    };
    if (bind(server_fd, &addr, @sizeOf(sockaddr_in)) < 0) {
        _ = close(server_fd);
        return error.BindFailed;
    }

    // Listen
    if (listen(server_fd, 128) < 0) {
        _ = close(server_fd);
        return error.ListenFailed;
    }

    return server_fd;
}

/// Accept a connection on the socket
pub fn acceptConnection(server_fd: c_int) !c_int {
    const client_fd = accept(server_fd, null, null);
    if (client_fd < 0) return error.AcceptFailed;
    return client_fd;
}
/// Accept with a timeout (seconds). Uses SO_RCVTIMEO on the server socket
/// so accept() returns -1 with EAGAIN/EWOULDBLOCK after the timeout.
/// Falls back to non-timeout accept if setsockopt fails.
pub fn acceptConnectionTimeout(server_fd: c_int, timeout_secs: u64) !c_int {
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_secs),
        .usec = 0,
    };
    _ = setsockopt(server_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, @sizeOf(std.posix.timeval));
    const client_fd = accept(server_fd, null, null);
    if (client_fd < 0) return error.AcceptFailed;
    // Clear timeout on accepted socket so reads don't inherit it
    const clear_tv = std.posix.timeval{ .sec = 0, .usec = 0 };
    _ = setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &clear_tv, @sizeOf(std.posix.timeval));
    return client_fd;
}

/// Write to socket (may write fewer bytes than requested)
pub fn writeSocket(fd: c_int, buf: []const u8) !usize {
    const n = write(fd, buf.ptr, buf.len);
    if (n < 0) return error.WriteFailed;
    return @intCast(n);
}

/// Write entire buffer to socket, handling partial writes.
/// Loops until all bytes are sent or an error occurs.
pub fn writeAllSocket(fd: c_int, buf: []const u8) !void {
    var remaining = buf;
    while (remaining.len > 0) {
        const n = write(fd, remaining.ptr, remaining.len);
        if (n <= 0) return error.WriteFailed;
        remaining = remaining[@intCast(n)..];
    }
}

/// Read from socket (single syscall, may return partial data)
pub fn readSocket(fd: c_int, buf: []u8) !usize {
    const n = read(fd, buf.ptr, buf.len);
    if (n < 0) return error.ReadFailed;
    return @intCast(n);
}

/// Read a full HTTP request from socket: headers + body according to Content-Length.
/// Returns an allocator-owned slice. Caller must free.
/// Enforces max_size limit (MAX_BODY_SIZE) and per-read timeout (timeout_secs).
pub fn readFullRequest(alloc: std.mem.Allocator, fd: c_int, max_size: usize, timeout_secs: u64) ![]u8 {
    // Set read timeout on the client socket
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_secs),
        .usec = 0,
    };
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, @sizeOf(std.posix.timeval));
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(alloc);

    // Read until we find \r\n\r\n (end of headers)
    const header_end_marker = "\r\n\r\n";
    var found_header_end = false;

    // Initial read buffer — 8KB is a good balance for HTTP headers
    var tmp: [8192]u8 = undefined;
    var total_read: usize = 0;

    while (true) {
        if (total_read >= max_size) return error.RequestTooLarge;

        const to_read = @min(tmp.len, max_size - total_read);
        const n = try readSocket(fd, tmp[0..to_read]);
        if (n == 0) return error.ConnectionClosed;
        total_read += n;
        try buf.appendSlice(alloc, tmp[0..n]);

        // Check if we've received the full headers
        if (!found_header_end) {
            if (std.mem.indexOf(u8, buf.items, header_end_marker)) |_| {
                found_header_end = true;
            } else if (total_read >= max_size) {
                return error.HeadersTooLarge;
            } else {
                continue; // Keep reading headers
            }
        }

        // Headers received — check for Content-Length
        var content_length: ?usize = null;
        const header_bytes = buf.items;
        var scan: usize = 0;
        while (scan < header_bytes.len) : (scan += 1) {
            if (scan + 15 <= header_bytes.len and
                asciiEqlIgnoreCase(header_bytes[scan .. scan + 15], "content-length:"))
            {
                var val_start = scan + 15;
                while (val_start < header_bytes.len and
                    (header_bytes[val_start] == ' ' or header_bytes[val_start] == '\t'))
                {
                    val_start += 1;
                }
                var val_end = val_start;
                while (val_end < header_bytes.len and
                    header_bytes[val_end] != '\r' and header_bytes[val_end] != '\n')
                {
                    val_end += 1;
                }
                content_length = std.fmt.parseInt(usize, header_bytes[val_start..val_end], 10) catch null;
                break;
            }
        }

        const body_start = (std.mem.indexOf(u8, buf.items, header_end_marker) orelse 0) + header_end_marker.len;
        const body_received = if (total_read > body_start) total_read - body_start else 0;

        if (content_length) |cl| {
            if (cl > max_size) return error.RequestTooLarge;
            if (body_received >= cl) {
                // Full body received
                return buf.toOwnedSlice(alloc);
            }
            // Need more body data — keep reading
            // Adjust max to not exceed Content-Length
            const remaining_body = cl - body_received;
            if (remaining_body == 0) return buf.toOwnedSlice(alloc);
        } else {
            // No Content-Length — assume we have everything after headers
            return buf.toOwnedSlice(alloc);
        }
    }
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (toLower(ac) != toLower(bc)) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Close socket
pub fn closeSocket(fd: c_int) void {
    _ = close(fd);
}
