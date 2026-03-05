const std = @import("std");
const ChildProcess = std.process.Child;

/// QUIC client that uses a bridge process to avoid Zig 0.15.2 compatibility issues
/// The bridge is a Rust binary that handles actual QUIC protocol
pub const GorkQuicClient = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: Config,
    bridge_process: ?ChildProcess,
    state: State,
    metrics: Metrics,

    pub const Config = struct {
        server_address: []const u8 = "127.0.0.1",
        server_port: u16 = 4003,
        bridge_path: []const u8 = "gork-quic-bridge",
        timeout_ms: u64 = 5000,
    };

    pub const State = enum {
        disconnected,
        connecting,
        connected,
        error_state,
    };

    pub const Metrics = struct {
        messages_sent: std.atomic.Value(u64),
        messages_received: std.atomic.Value(u64),
        bytes_sent: std.atomic.Value(u64),
        bytes_received: std.atomic.Value(u64),
        total_latency_ms: std.atomic.Value(u64),
        connection_time_ms: std.atomic.Value(u64),
    };

    pub const QuicError = error{
        ConnectionFailed,
        SendFailed,
        ReceiveFailed,
        Timeout,
        BridgeProcessFailed,
        InvalidResponse,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) QuicError!Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .bridge_process = null,
            .state = .disconnected,
            .metrics = .{
                .messages_sent = std.atomic.Value(u64).init(0),
                .messages_received = std.atomic.Value(u64).init(0),
                .bytes_sent = std.atomic.Value(u64).init(0),
                .bytes_received = std.atomic.Value(u64).init(0),
                .total_latency_ms = std.atomic.Value(u64).init(0),
                .connection_time_ms = std.atomic.Value(u64).init(0),
            },
        };
    }

    pub fn deinit(self: *Self) void {
        self.disconnect() catch {};
    }

    pub fn connect(self: *Self) QuicError!void {
        if (self.state == .connected) return;
        if (self.state == .connecting) return;

        self.state = .connecting;
        const start_time = 0;

        // Start bridge process
        var child = ChildProcess.init(&[_][]const u8{
            self.config.bridge_path,
        }, self.allocator);
        
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch |err| {
            std.log.err("Failed to spawn QUIC bridge: {}", .{err});
            self.state = .error_state;
            return QuicError.BridgeProcessFailed;
        };

        self.bridge_process = child;

        // Wait for bridge to initialize
        // std.Thread.sleep() - TODO: Fix for Zig 0.16

        const elapsed = @divTrunc(0 - start_time, 1_000_000);
        self.metrics.connection_time_ms.store(@intCast(elapsed), .monotonic);
        self.state = .connected;

        std.log.info("QUIC bridge process started ({}ms)", .{elapsed});
    }

    pub fn disconnect(self: *Self) QuicError!void {
        if (self.bridge_process) |*child| {
            // Close stdin to signal shutdown
            if (child.stdin) |stdin| {
                stdin.close();
            }

            // Wait for process to exit
            _ = child.wait() catch {};

            self.bridge_process = null;
        }

        self.state = .disconnected;
    }

    pub fn sendMessage(self: *Self, agent_id: []const u8, message: []const u8) anyerror![]const u8 {
        if (self.state != .connected) {
            return QuicError.ConnectionFailed;
        }

        if (self.bridge_process == null) {
            return QuicError.ConnectionFailed;
        }

        const child = &self.bridge_process.?;

        const start_time = 0;

        // Format: "agent_id:message\n"
        var buffer: [4096]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buffer, "{s}:{s}\n", .{ agent_id, message }) catch
            return QuicError.SendFailed;

        // Send to bridge via stdin
        if (child.stdin) |stdin| {
            stdin.writeStreamingAll(std.Options.debug_io, formatted) catch |err| {
                std.log.err("Failed to write to bridge stdin: {}", .{err});
                return QuicError.SendFailed;
            };
        } else {
            return QuicError.SendFailed;
        }

        _ = self.metrics.messages_sent.fetchAdd(1, .monotonic);
        _ = self.metrics.bytes_sent.fetchAdd(formatted.len, .monotonic);

        // Read response from stdout
        if (child.stdout) |stdout| {
            var response_buf: [4096]u8 = undefined;
            const response_len = stdout.read(&response_buf) catch |err| {
                std.log.err("Failed to read from bridge stdout: {}", .{err});
                return QuicError.ReceiveFailed;
            };

            if (response_len == 0) {
                return QuicError.Timeout;
            }

            const response = std.mem.trim(u8, response_buf[0..response_len], " \n\r\t");
            const elapsed = @divTrunc(0 - start_time, 1_000_000);

            _ = self.metrics.messages_received.fetchAdd(1, .monotonic);
            _ = self.metrics.bytes_received.fetchAdd(response.len, .monotonic);
            _ = self.metrics.total_latency_ms.store(@intCast(elapsed), .monotonic);

            return self.allocator.dupe(u8, response) catch QuicError.ReceiveFailed;
        } else {
            return QuicError.ReceiveFailed;
        }
    }

    pub fn getState(self: Self) State {
        return self.state;
    }

    pub fn getMetrics(self: Self) Metrics {
        return self.metrics;
    }

    pub fn isConnected(self: Self) bool {
        return self.state == .connected;
    }
};
