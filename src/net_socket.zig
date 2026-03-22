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

/// Read from socket
pub fn readSocket(fd: c_int, buf: []u8) !usize {
    const n = read(fd, buf.ptr, buf.len);
    if (n < 0) return error.ReadFailed;
    return @intCast(n);
}

/// Write to socket
pub fn writeSocket(fd: c_int, buf: []const u8) !usize {
    const n = write(fd, buf.ptr, buf.len);
    if (n < 0) return error.WriteFailed;
    return @intCast(n);
}

/// Close socket
pub fn closeSocket(fd: c_int) void {
    _ = close(fd);
}
