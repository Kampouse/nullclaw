const std = @import("std");
const proto = @import("../proto.zig");
const buffer = @import("../buffer.zig");

const ascii = std.ascii;
const posix = std.posix;
const ionet = std.Io.net;
const tls = std.crypto.tls;
const log = std.log.scoped(.websocket);

const Reader = proto.Reader;
const Allocator = std.mem.Allocator;
const Bundle = std.crypto.Certificate.Bundle;
// Compression disabled (removed for Zig 0.15+ port)
const ServerHandshake = struct {
    pub const Compression = struct {
        client_no_context_takeover: bool,
        server_no_context_takeover: bool,
    };
};

fn ReadLoopHandler(comptime T: type) type {
    const info = @typeInfo(T);

    switch (info) {
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple)
                @compileError("readLoop: handler does not support tuples.");

            return T;
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .one => return ReadLoopHandler(ptr_info.child),
                else => @compileError("readLoop: handler does not support Slice, C and Many pointers."),
            }
        },
        else => @compileError("readLoop: expected handler to be a struct or pointer to a struct but found '" ++ @tagName(info) ++ "'"),
    }
}

pub const Client = struct {
    stream: Stream,
    _reader: Reader,
    _closed: bool,
    _compression_opts: ?void,
    _compression: ?Client.Compression = null,
    _host: []const u8,

    // When creating a client, we can either be given a BufferProvider or create
    // one ourselves. If we create it ourselves (in init), we "own" it and must
    // free it on deinit. (The reference to the buffer provider is already in the
    // reader, no need to hold another reference in the client).
    _own_bp: bool,

    // For advanced cases, a custom masking function can be provided. Masking
    // is a security feature that only really makes sense in the browser. If you
    // aren't running websockets in the browser AND you control both the client
    // and the server, you could get a performance boost by not masking.
    _mask_fn: *const fn () [4]u8,

    pub const Config = struct {
        port: u16,
        host: []const u8,
        tls: bool = false,
        max_size: usize = 65536,
        buffer_size: usize = 4096,
        ca_bundle: ?Bundle = null,
        mask_fn: *const fn () [4]u8 = generateMask,
        buffer_provider: ?*buffer.Provider = null,
        compression: ?void = null,
        /// Optional per-connection Io instance. When null, falls back to
        /// `std.Io.Threaded.global_single_threaded.io()`.  Supplying a
        /// dedicated instance is required when connecting from multiple
        /// threads simultaneously (e.g. parallel relay queries) because
        /// the global singleton is not thread-safe for TLS handshakes.
        io: ?std.Io = null,
    };

    pub const HandshakeOpts = struct {
        timeout_ms: u32 = 10000,
        headers: ?[]const u8 = null,
        host: []const u8 = "",
    };

    const Compression = struct {
        allocator: Allocator,
        retain_writer: bool,
        write_treshold: usize,
        writer: std.Io.Writer.Allocating,
    };

    pub fn init(allocator: Allocator, config: Config) !Client {
        if (config.compression != null) {
            log.err("Compression is disabled as part of the 0.15 upgrade. I do hope to re-enable it soon.", .{});
            return error.InvalidConfiguraion;
        }

        // Direct getaddrinfo for DNS resolution (works without Io.Threaded)
        var port_buf: [8]u8 = undefined;
        const port_c = try std.fmt.bufPrintZ(&port_buf, "{d}", .{config.port});
        var host_buf: [256]u8 = undefined;
        if (config.host.len >= host_buf.len) return error.HostNameTooLong;
        @memcpy(host_buf[0..config.host.len], config.host);
        host_buf[config.host.len] = 0;
        const hints: posix.addrinfo = .{
            .flags = .{ .NUMERICSERV = true },
            .family = posix.AF.UNSPEC,
            .socktype = posix.SOCK.STREAM,
            .protocol = posix.IPPROTO.TCP,
            .canonname = null,
            .addr = null,
            .addrlen = 0,
            .next = null,
        };
        var res: ?*posix.addrinfo = null;
        const gai_err = posix.system.getaddrinfo(host_buf[0..config.host.len :0].ptr, port_c.ptr, &hints, &res);
        if (gai_err != @as(posix.system.EAI, @enumFromInt(0))) return error.DnsResolutionFailed;
        defer if (res) |some| posix.system.freeaddrinfo(some);
        const ai = res orelse return error.DnsResolutionFailed;
        const fd = posix.system.socket(@intCast(ai.family), @intCast(ai.socktype), @intCast(ai.protocol));
        if (fd < 0) return error.SocketFailed;
        const connect_rc = posix.system.connect(fd, ai.addr.?, ai.addrlen);
        if (connect_rc != 0) {
            _ = posix.system.close(fd);
            return error.ConnectionFailed;
        }
        const net_stream = ionet.Stream{ .socket = .{ .handle = fd, .address = .{ .ip4 = ionet.Ip4Address.loopback(0) } } };

        var tls_client: ?*TLSClient = null;
        const tls_io = config.io orelse std.Io.Threaded.global_single_threaded.io();
        if (config.tls) {
            std.log.info("ws_client: starting TLS handshake...", .{});
            tls_client = TLSClient.init(allocator, net_stream, &config, tls_io) catch |err| {
                std.log.err("ws_client: TLS init failed: {}", .{err});
                return err;
            };
            std.log.info("ws_client: TLS handshake complete", .{});
        }
        const stream = Stream.init(net_stream, tls_client, tls_io);

        var own_bp = false;
        var buffer_provider: *buffer.Provider = undefined;

        // If a buffer_provider is provided, we'll use that.
        // If it isn't, we need to create one which also means we now "own" it
        // and we're responsible for cleaning it up
        if (config.buffer_provider) |shared_bp| {
            buffer_provider = shared_bp;
        } else {
            own_bp = true;
            buffer_provider = try allocator.create(buffer.Provider);
            errdefer allocator.destroy(buffer_provider);
            buffer_provider.* = try buffer.Provider.init(allocator, .{
                .size = 0,
                .count = 0,
                .max = config.max_size,
            });
        }

        errdefer if (own_bp) {
            buffer_provider.deinit();
            allocator.destroy(buffer_provider);
        };

        const reader_buf = try buffer_provider.allocator.alloc(u8, config.buffer_size);
        errdefer buffer_provider.allocator.free(reader_buf);

        return .{
            .stream = stream,
            ._closed = false,
            ._own_bp = own_bp,
            ._mask_fn = config.mask_fn,
            ._compression_opts = null, //TODO: ZIG 0.15
            ._reader = Reader.init(reader_buf, buffer_provider, null),
            ._host = config.host,
        };
    }

    pub fn deinit(self: *Client) void {
        self.closeStream();

        const larger_buffer_provider = self._reader.large_buffer_provider;
        const allocator = larger_buffer_provider.allocator;
        allocator.free(self._reader.static);

        self._reader.deinit();

        if (self._own_bp) {
            larger_buffer_provider.deinit();
            allocator.destroy(larger_buffer_provider);
        }
    }

    pub fn handshake(self: *Client, path: []const u8, opts: HandshakeOpts) !void {
        const opts_with_host: HandshakeOpts = .{
            .timeout_ms = opts.timeout_ms,
            .headers = opts.headers,
            .host = if (opts.host.len > 0) opts.host else self._host,
        };
        const actual_opts = &opts_with_host;
        const stream = &self.stream;
        errdefer self.closeStream();

        // we've already setup our reader, and the reader has a static buffer
        // we might as well use it!
        const buf = self._reader.static;
        const key = blk: {
            const bin_key = generateKey();
            var encoded_key: [24]u8 = undefined;
            break :blk std.base64.standard.Encoder.encode(&encoded_key, &bin_key);
        };

        try sendHandshake(path, key, buf, actual_opts, self._compression_opts != null, stream);

        const res = try HandShakeReply.read(buf, key, actual_opts, self._compression_opts != null, stream);
        errdefer self.close(.{ .code = 1001 }) catch unreachable;

        // Set up compression with agreed-on parameters
        if (res.compression) {
            try self.setupCompression();
        }

        // We might have read more than handshake response. If so, readHandshakeReply
        // has positioned the extra data at the start of the buffer, but we need
        // to set the length.
        self._reader.pos = res.over_read;
    }

    fn setupCompression(_: *Client) !void {
        // Compression is disabled in this Zig 0.16 port.
        return error.CompressionDisabled;
    }

    pub fn readLoop(self: *Client, handler: anytype) !void {
        const Handler = ReadLoopHandler(@TypeOf(handler));
        var reader = &self._reader;

        defer if (comptime std.meta.hasFn(Handler, "close")) {
            handler.close();
        };

        // block until we have data
        try self.readTimeout(0);

        while (true) {
            const message = self.read() catch |err| switch (err) {
                error.Closed => return,
                else => return err,
            } orelse unreachable;

            const message_type = message.type;
            defer reader.done(message_type);

            switch (message_type) {
                .text, .binary => {
                    switch (comptime @typeInfo(@TypeOf(Handler.serverMessage)).@"fn".params.len) {
                        2 => try handler.serverMessage(message.data),
                        3 => try handler.serverMessage(message.data, if (message_type == .text) .text else .binary),
                        else => @compileError(@typeName(Handler) ++ ".serverMessage must accept 2 or 3 parameters"),
                    }
                },
                .ping => if (comptime std.meta.hasFn(Handler, "serverPing")) {
                    try handler.serverPing(message.data);
                } else {
                    // @constCast is safe because we know message.data points to
                    // reader.buffer.buf, which we own and which can be mutated
                    try self.writeFrame(.pong, @constCast(message.data));
                },
                .close => {
                    if (comptime std.meta.hasFn(Handler, "serverClose")) {
                        try handler.serverClose(message.data);
                    } else {
                        self.close(.{}) catch unreachable;
                    }
                    return;
                },
                .pong => if (comptime std.meta.hasFn(Handler, "serverPong")) {
                    try handler.serverPong(message.data);
                },
            }
        }
    }

    pub fn read(self: *Client) !?proto.Message {
        var reader = &self._reader;
        const stream = &self.stream;

        while (true) {
            // try to read a message from our buffer first, before trying to
            // get more data from the socket.
            const has_more, const message = reader.read() catch |err| {
                self.close(.{ .code = 1002 }) catch unreachable;
                return err;
            } orelse {
                reader.fill(stream) catch |err| switch (err) {
                    error.WouldBlock => return null,
                    error.Closed, error.ConnectionResetByPeer, error.NotOpenForReading => {
                        @atomicStore(bool, &self._closed, true, .monotonic);
                        return error.Closed;
                    },
                    else => {
                        self.close(.{ .code = 1002 }) catch unreachable;
                        return err;
                    },
                };
                continue;
            };

            _ = has_more;
            return message;
        }
    }

    pub fn done(self: *Client, message: proto.Message) void {
        self._reader.done(message.type);
    }

    pub fn readLoopInNewThread(self: *Client, h: anytype) !std.Thread {
        return std.Thread.spawn(.{}, readLoopOwnedThread, .{ self, h });
    }

    fn readLoopOwnedThread(self: *Client, h: anytype) void {
        self.readLoop(h) catch {};
    }

    pub fn writeTimeout(self: *const Client, ms: u32) !void {
        return self.stream.writeTimeout(ms);
    }

    pub fn readTimeout(self: *const Client, ms: u32) !void {
        return self.stream.readTimeout(ms);
    }

    pub fn write(self: *Client, data: []u8) !void {
        return self.writeFrame(.text, data);
    }

    pub fn writeText(self: *Client, data: []u8) !void {
        return self.writeFrame(.text, data);
    }

    pub fn writeBin(self: *Client, data: []u8) !void {
        return self.writeFrame(.binary, data);
    }

    pub fn writePing(self: *Client, data: []u8) !void {
        return self.writeFrame(.ping, data);
    }

    pub fn writePong(self: *Client, data: []u8) !void {
        return self.writeFrame(.pong, data);
    }

    const CloseOpts = struct {
        code: ?u16 = null,
        reason: []const u8 = "",
    };

    pub fn close(self: *Client, opts: CloseOpts) !void {
        if (@atomicRmw(bool, &self._closed, .Xchg, true, .monotonic) == true) {
            // already closed
            return;
        }

        defer self.stream.close();

        const code = opts.code orelse {
            self.writeFrame(.close, "") catch {};
            return;
        };

        const reason = opts.reason;
        if (reason.len > 123) {
            return error.ReasonTooLong;
        }

        var buf: [125]u8 = undefined;
        buf[0] = @intCast((code >> 8) & 0xFF);
        buf[1] = @intCast(code & 0xFF);

        const end = 2 + reason.len;
        @memcpy(buf[2..end], reason);
        self.writeFrame(.close, buf[0..end]) catch {};
    }

    pub fn writeFrame(self: *Client, op_code: proto.OpCode, data: []u8) !void {
        const payload = data;
        const compressed = false;
        // if (self._compression) |c| {
        //     if (data.len >= c.write_treshold and (op_code == .binary or op_code == .text)) {
        //         compressed = true;

        //         var writer = &c.writer;
        //         var compressor = &c.compressor;
        //         var fbs = std.io.fixedBufferStream(data);
        //         _ = try compressor.compress(fbs.reader());
        //         try compressor.flush();
        //         payload = writer.items[0 .. writer.items.len - 4];

        //         if (c.reset) {
        //             c.compressor = try Compression.Type.init(writer.writer(), .{});
        //         }
        //     }
        // }
        // defer if (compressed) {
        //     const c = self._compression.?;
        //     if (c.retain_writer) {
        //         c.compressor.wrt.context.clearRetainingCapacity();
        //     } else {
        //         c.compressor.wrt.context.clearAndFree();
        //     }
        // };

        // maximum possible prefix length. op_code + length_type + 8byte length + 4 byte mask
        var buf: [14]u8 = undefined;
        const header = proto.writeFrameHeader(&buf, op_code, payload.len, compressed);

        const header_len = header.len;
        const header_end = header.len + 4; // for the mask

        buf[1] |= 128; // indicate that the payload is masked

        const mask = self._mask_fn();
        @memcpy(buf[header_len..header_end], &mask);
        try self.stream.writeAll(buf[0..header_end]);

        if (payload.len > 0) {
            proto.mask(&mask, payload);
            try self.stream.writeAll(payload);
        }
    }

    fn closeStream(self: *Client) void {
        if (@atomicRmw(bool, &self._closed, .Xchg, true, .monotonic) == false) {
            self.stream.close();
        }
    }
};

// wraps a std.Io.net.Stream and optional a tls.Client
pub const Stream = struct {
    stream: ionet.Stream,
    io: std.Io,
    tls_client: ?*TLSClient = null,

    pub fn init(stream: ionet.Stream, tls_client: ?*TLSClient, io: std.Io) Stream {
        return .{
            .stream = stream,
            .io = io,
            .tls_client = tls_client,
        };
    }

    pub fn close(self: *Stream) void {
        const fd = self.stream.socket.handle;
        const builtin = @import("builtin");
        const native_os = builtin.os.tag;

        if (self.tls_client) |tls_client| {
            // Shutdown the socket first, so readLoop() can exit, before tls_client's buffers are freed
            if (native_os == .windows) {
                _ = std.os.windows.ws2_32.shutdown(fd, std.os.windows.ws2_32.SD_BOTH);
            } else if (native_os == .wasi and !builtin.link_libc) {
                _ = std.os.wasi.sock_shutdown(fd, .{ .WR = true, .RD = true });
            } else {
                _ = posix.system.shutdown(fd, posix.SHUT.WR);
            }
            tls_client.deinit();
        }

        // std.posix.close panics on EBADF
        // This is a general issue in Zig:
        // https://github.com/ziglang/zig/issues/6389
        //
        // we don't want to crash on double close

        if (native_os == .windows) {
            return std.os.windows.CloseHandle(fd);
        }
        if (native_os == .wasi and !builtin.link_libc) {
            _ = std.os.wasi.fd_close(fd);
            return;
        }
        _ = std.posix.system.close(fd);
    }

    pub fn read(self: *Stream, buf: []u8) !usize {
        if (self.tls_client) |tls_client| {
            var w: std.Io.Writer = .fixed(buf);
            var consecutive_zeros: usize = 0;
            while (true) {
                const n = tls_client.client.reader.stream(&w, .limited(buf.len)) catch |err| {
                    // If socket has SO_RCVTIMEO set, EAGAIN/EWOULDBLOCK means timeout.
                    // Return WouldBlock so callers can handle it (e.g. break read loop).
                    if (err == error.WouldBlock or err == error.ConnectionTimedOut) return err;
                    return err;
                };
                if (n != 0) {
                    return n;
                }
                // TLS returned 0 bytes — with SO_RCVTIMEO this means socket timed out.
                // Without timeout, 0 means connection closed. Break either way.
                consecutive_zeros += 1;
                if (consecutive_zeros >= 3) return error.WouldBlock;
            }
        }
        return posix.read(self.stream.socket.handle, buf);
    }

    pub fn writeAll(self: *Stream, data: []const u8) !void {
        if (self.tls_client) |tls_client| {
            try tls_client.client.writer.writeAll(data);
            try tls_client.client.writer.flush();
            try tls_client.client.output.flush();
            return;
        }
        const fd = self.stream.socket.handle;
        var offset: usize = 0;
        while (offset < data.len) {
            const n = posix.system.write(fd, data[offset..].ptr, data[offset..].len);
            if (n <= 0) return error.BrokenPipe;
            offset += @as(usize, @intCast(n));
        }
    }

    const zero_timeout = std.mem.toBytes(posix.timeval{ .sec = 0, .usec = 0 });
    pub fn writeTimeout(self: *const Stream, ms: u32) !void {
        return self.setTimeout(posix.SO.SNDTIMEO, ms);
    }

    pub fn readTimeout(self: *const Stream, ms: u32) !void {
        return self.setTimeout(posix.SO.RCVTIMEO, ms);
    }

    fn setTimeout(self: *const Stream, opt_name: u32, ms: u32) !void {
        if (ms == 0) {
            return self.setsockopt(opt_name, &zero_timeout);
        }

        const timeout = std.mem.toBytes(posix.timeval{
            .sec = @intCast(@divTrunc(ms, 1000)),
            .usec = @intCast(@mod(ms, 1000) * 1000),
        });
        return self.setsockopt(opt_name, &timeout);
    }

    pub fn setsockopt(self: *const Stream, opt_name: u32, value: []const u8) !void {
        return posix.setsockopt(self.stream.socket.handle, posix.SOL.SOCKET, opt_name, value);
    }
};

const TLSClient = struct {
    client: tls.Client,
    stream: ionet.Stream,
    stream_writer: ionet.Stream.Writer,
    stream_reader: ionet.Stream.Reader,
    arena: std.heap.ArenaAllocator,
    io: std.Io,

    fn init(allocator: Allocator, stream: ionet.Stream, config: *const Client.Config, io: std.Io) !*TLSClient {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const aa = arena.allocator();

        const bundle = config.ca_bundle orelse blk: {
            var b = Bundle{};
            try b.rescan(aa, io, std.Io.Timestamp.now(io, .real));
            break :blk b;
        };

        // The TLS input and output have to be max_ciphertext_record_len each.
        // It isn't clear to me how big the un-encrypted reader and writer
        // need to be. I would think 0, but that will fail an assertion. I
        // don't think that it's right that we need 4 buffers, but apparently
        // we do. Until i figure this out, using 4 x max_ciphertext_record_len
        // seems like the only safe choice.
        const buf_len = std.crypto.tls.max_ciphertext_record_len;
        var buf = try aa.alloc(u8, buf_len * 4);

        const self = try aa.create(TLSClient);
        self.* = .{
            .stream = stream,
            .arena = arena,
            .client = undefined,
            .io = io,
            .stream_writer = ionet.Stream.writer(stream, io, buf.ptr[0..buf_len][0..buf_len]),
            .stream_reader = ionet.Stream.reader(stream, io, buf.ptr[buf_len .. 2 * buf_len][0..buf_len]),
        };

        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        posix.system.arc4random_buf(&entropy, entropy.len);
        
        self.client = try tls.Client.init(
            &self.stream_reader.interface,
            &self.stream_writer.interface,
            .{
                .ca = .{ .bundle = bundle },
                .host = .{ .explicit = config.host },
                .read_buffer = buf.ptr[2 * buf_len .. 3 * buf_len][0..buf_len],
                .write_buffer = buf.ptr[3 * buf_len .. 4 * buf_len][0..buf_len],
                .entropy = &entropy,
                .realtime_now_seconds = blk: { var ts: posix.timespec = undefined; _ = posix.system.clock_gettime(.REALTIME, &ts); break :blk ts.sec; },
            },
        );

        return self;
    }

    fn deinit(self: *TLSClient) void {
        _ = self.client.end() catch {};
        self.arena.deinit();
    }
};

fn generateKey() [16]u8 {
    if (comptime @import("builtin").is_test) {
        return [16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    }
    var key: [16]u8 = undefined;
    posix.system.arc4random_buf(&key, key.len);
    return key;
}

fn generateMask() [4]u8 {
    var m: [4]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(0);
    rng.random().bytes(&m);
    return m;
}

fn sendHandshake(path: []const u8, key: []const u8, buf: []u8, opts: *const Client.HandshakeOpts, compression: bool, stream: anytype) !void {
    @memcpy(buf[0..4], "GET ");
    var pos: usize = 4;

    // path
    @memcpy(buf[pos..][0..path.len], path);
    pos += path.len;

    // host header
    const host_header = if (opts.host.len > 0) " HTTP/1.1\r\nhost: " else " HTTP/1.1\r\n";
    @memcpy(buf[pos..][0..host_header.len], host_header);
    pos += host_header.len;
    if (opts.host.len > 0) {
        @memcpy(buf[pos..][0..opts.host.len], opts.host);
        pos += opts.host.len;
    }

    // standard headers
    const headers = "\r\nupgrade: websocket\r\nsec-websocket-version: 13\r\nconnection: upgrade\r\nsec-websocket-key: ";
    @memcpy(buf[pos..][0..headers.len], headers);
    pos += headers.len;

    // key
    @memcpy(buf[pos..][0..key.len], key);
    pos += key.len;

    // compression extension
    if (compression) {
        const permessage_deflate = "\r\nSec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover";
        @memcpy(buf[pos..][0..permessage_deflate.len], permessage_deflate);
        pos += permessage_deflate.len;
    }

    // end of headers
    @memcpy(buf[pos..][0..2], "\r\n");
    pos += 2;

    // extra headers
    if (opts.headers) |extra_headers| {
        @memcpy(buf[pos..][0..extra_headers.len], extra_headers);
        pos += extra_headers.len;
        if (!std.mem.endsWith(u8, extra_headers, "\r\n")) {
            buf[pos] = '\r';
            buf[pos + 1] = '\n';
            pos += 2;
        }
    }
    buf[pos] = '\r';
    buf[pos + 1] = '\n';
    pos += 2;

    try stream.writeTimeout(opts.timeout_ms);
    try stream.writeAll(buf[0..pos]);
    try stream.writeTimeout(0);
}

const HandShakeReply = struct {
    compression: bool,
    over_read: usize,

    fn read(buf: []u8, key: []const u8, opts: *const Client.HandshakeOpts, compression: bool, stream: anytype) !HandShakeReply {
        const timeout_ms = opts.timeout_ms;
        var deadline_ts: posix.timespec = undefined;
        _ = posix.system.clock_gettime(.REALTIME, &deadline_ts);
        const deadline = @as(i64, deadline_ts.sec) * 1000 + @divTrunc(deadline_ts.nsec, 1000000) + timeout_ms;
        try stream.readTimeout(timeout_ms);
        std.log.info("ws_client: waiting for WS handshake reply (timeout={}ms)...", .{timeout_ms});

        var pos: usize = 0;
        var line_start: usize = 0;
        var complete_response: u8 = 0;
        var server_compression: bool = false;

        while (true) {
            const n = stream.read(buf[pos..]) catch |err| switch (err) {
                error.WouldBlock, error.Unexpected => return error.Timeout,
                else => return err,
            };
            if (n == 0) {
                return error.ConnectionClosed;
            }

            pos += n;
            while (std.mem.indexOfScalar(u8, buf[line_start..pos], '\r')) |relative_end| {
                if (relative_end == 0) {
                    if (complete_response != 15) {
                        return error.InvalidHandshakeResponse;
                    }
                    const over_read = pos - (line_start + 2);
                    std.mem.copyForwards(u8, buf[0..over_read], buf[line_start + 2 .. pos]);
                    try stream.readTimeout(0);
                    return .{
                        .over_read = over_read,
                        .compression = server_compression,
                    };
                }

                const line_end = line_start + relative_end;
                const line = buf[line_start..line_end];

                // the next line starts where this line ends, skip over the \r\n
                line_start = line_end + 2;

                if (complete_response == 0) {
                    std.log.info("ws_client: first response line: {s}", .{line});
                    if (!ascii.startsWithIgnoreCase(line, "HTTP/1.1 101 ")) {
                        return error.InvalidHandshakeResponse;
                    }
                    complete_response |= 1;
                    continue;
                }

                for (line, 0..) |b, i| {
                    // find the colon and lowercase the header while we're iterating
                    if ('A' <= b and b <= 'Z') {
                        line[i] = b + 32;
                        continue;
                    }

                    if (b != ':') {
                        continue;
                    }

                    switch (i) {
                        7 => if (std.mem.eql(u8, line[0..i], "upgrade")) {
                            if (!ascii.eqlIgnoreCase(std.mem.trim(u8, line[i + 1 ..], &ascii.whitespace), "websocket")) {
                                return error.InvalidUpgradeHeader;
                            }
                            complete_response |= 2;
                        },
                        10 => if (std.mem.eql(u8, line[0..i], "connection")) {
                            if (!ascii.eqlIgnoreCase(std.mem.trim(u8, line[i + 1 ..], &ascii.whitespace), "upgrade")) {
                                return error.InvalidConnectionHeader;
                            }
                            complete_response |= 4;
                        },
                        20 => if (std.mem.eql(u8, line[0..i], "sec-websocket-accept")) {
                            var h: [20]u8 = undefined;
                            {
                                var hasher = std.crypto.hash.Sha1.init(.{});
                                hasher.update(key);
                                hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
                                hasher.final(&h);
                            }

                            var encoded_buf: [28]u8 = undefined;
                            const sec_hash = std.base64.standard.Encoder.encode(&encoded_buf, &h);
                            const header_value = std.mem.trim(u8, line[i + 1 ..], &ascii.whitespace);

                            if (!std.mem.eql(u8, header_value, sec_hash)) {
                                return error.InvalidWebsocketAcceptHeader;
                            }
                            complete_response |= 8;
                        },
                        24 => if (std.mem.eql(u8, line[0..i], "sec-websocket-extensions")) {
                            if (try parseExtension(line[i + 1 ..])) |sc| {
                                if (!compression) {
                                    // server is saying compression, but we didn't ask for it.
                                    return error.InvalidExtensionHeader;
                                }
                                if (!sc.client_no_context_takeover or !sc.server_no_context_takeover) {
                                    // as of Zig 0.15, we no longer support context takeover
                                    // We told the server this, it should have respected it.
                                    return error.InvalidExtensionHeader;
                                }

                                server_compression = true;
                            }
                        },
                        else => {}, // some other header we don't care about
                    }
                }
            }

            var now_ts: posix.timespec = undefined;
            _ = posix.system.clock_gettime(.REALTIME, &now_ts);
            const now_ms = @as(i64, now_ts.sec) * 1000 + @divTrunc(now_ts.nsec, 1000000);
            if (now_ms > deadline) {
                return error.Timeout;
            }

            if (pos == buf.len) {
                return error.ResponseTooLarge;
            }
        }
    }

    pub fn parseExtension(value: []const u8) !?ServerHandshake.Compression {
        var deflate = false;
        var client_max_bits: u8 = 15;
        var client_no_context_takeover = false;
        var server_no_context_takeover = false;

        var it = std.mem.splitScalar(u8, value, ';');
        while (it.next()) |param_| {
            const param = std.mem.trim(u8, param_, &ascii.whitespace);
            if (std.mem.eql(u8, param, "permessage-deflate")) {
                deflate = true;
                continue;
            }
            if (std.mem.eql(u8, param, "client_no_context_takeover")) {
                client_no_context_takeover = true;
                continue;
            }
            if (std.mem.eql(u8, param, "server_no_context_takeover")) {
                server_no_context_takeover = true;
                continue;
            }
            const client_max_window_bits = "client_max_window_bits=";
            if (std.mem.startsWith(u8, param, client_max_window_bits)) {
                client_max_bits = std.fmt.parseInt(u8, param[client_max_window_bits.len..], 10) catch {
                    return error.InvalidCompressionServerMaxBits;
                };
            }
        }
        if (deflate == false) {
            return null;
        }

        if (client_max_bits != 15) {
            // We don't offer client window, so if the server asks for one, that's an error
            return error.InvalidExtensionHeader;
        }

        return .{
            .client_no_context_takeover = client_no_context_takeover,
            .server_no_context_takeover = server_no_context_takeover,
        };
    }
};

