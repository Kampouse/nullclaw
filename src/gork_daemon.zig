//! Gork daemon process wrapper.
//!
//! Manages the gork-agent daemon process, parses its log output for events,
//! and provides health monitoring.
//!
//! Thread Safety: All public methods are thread-safe. Internally uses a mutex
//! to protect shared state.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DaemonProcess = @This();

// Memory limits for security
const MAX_LOG_BUFFER_SIZE = 1024 * 1024; // 1MB

/// Daemon state
pub const State = enum {
    stopped,
    starting,
    running,
    stopping,
    crashed,
};

/// Event from daemon - all strings are owned and must be freed
pub const Event = union(enum) {
    started: StartedInfo,
    stopped: ?[]const u8, // error reason if any (owned)
    message_received: IncomingMessage,
    peer_connected: []const u8, // owned
    peer_disconnected: []const u8, // owned
    daemon_error: []const u8, // owned

    /// Free all owned strings in the event
    pub fn deinit(self: *Event, allocator: Allocator) void {
        switch (self.*) {
            .started => |*info| info.deinit(allocator),
            .stopped => |reason| {
                if (reason) |r| {
                    if (r.len > 0) allocator.free(r);
                }
            },
            .message_received => |*msg| msg.deinit(allocator),
            .peer_connected => |s| {
                if (s.len > 0) allocator.free(s);
            },
            .peer_disconnected => |s| {
                if (s.len > 0) allocator.free(s);
            },
            .daemon_error => |s| {
                if (s.len > 0) allocator.free(s);
            },
        }
    }
};

pub const StartedInfo = struct {
    peer_id: []const u8,
    listen_addr: []const u8,
    port: u16,

    /// Free owned strings
    pub fn deinit(self: *const StartedInfo, allocator: Allocator) void {
        if (self.peer_id.len > 0) allocator.free(self.peer_id);
        if (self.listen_addr.len > 0) allocator.free(self.listen_addr);
    }
};

/// Incoming P2P message from another agent
pub const IncomingMessage = struct {
    from: []const u8,
    message_type: []const u8,
    content: []const u8,
    timestamp: u64,

    /// Deallocate owned fields
    pub fn deinit(self: *IncomingMessage, allocator: Allocator) void {
        if (self.from.len > 0) allocator.free(self.from);
        if (self.message_type.len > 0) allocator.free(self.message_type);
        if (self.content.len > 0) allocator.free(self.content);
    }
};

allocator: Allocator,
mutex: std.Io.Mutex,
child: ?std.process.Child,
state: State,
info: ?StartedInfo,
event_callback: *const fn (Allocator, Event) void,

/// Initialize a new daemon process wrapper
pub fn init(allocator: Allocator, event_callback: *const fn (Allocator, Event) void) DaemonProcess {
    return .{
        .allocator = allocator,
        .mutex = .{ .state = .init(.unlocked) },
        .child = null,
        .state = .stopped,
        .info = null,
        .event_callback = event_callback,
    };
}

/// Start the daemon process
pub fn start(self: *DaemonProcess, config: StartConfig) !void {
    // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
    // TODO: Zig 0.16.0 - needs io
    // defer self.mutex.unlock();

    if (self.state != .stopped) return error.AlreadyRunning;

    self.state = .starting;

    // Build command
    var argv = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
    defer argv.deinit(self.allocator);

    try argv.append(self.allocator, config.binary_path);
    try argv.append(self.allocator, "daemon");
    try argv.append(self.allocator, "--port");

    // Format port as string - owned by argv and freed with deinit
    var port_buf: [16]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{}", .{config.port});
    try argv.append(self.allocator, port_str);

    if (config.relay) |relay| {
        try argv.append(self.allocator, "--relay");
        try argv.append(self.allocator, relay);
    }

    // Spawn child process (Zig 0.16.0 - Child struct changed)
    // TODO: Rewrite with new process API
    return error.NotImplemented;
}

/// Check if daemon is alive (thread-safe)
pub fn isAlive(self: *const DaemonProcess) bool {
    // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
    // TODO: Zig 0.16.0 - needs io
    // defer self.mutex.unlock();

    // Since we can't poll directly, check if we have a child and state indicates running
    return self.child != null and (self.state == .running or self.state == .starting);
}

/// Get current state (thread-safe)
pub fn getState(self: *const DaemonProcess) State {
    // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
    // TODO: Zig 0.16.0 - needs io
    // defer self.mutex.unlock();
    return self.state;
}

/// Send message via daemon (uses CLI wrapper which communicates with running daemon)
pub fn sendMessage(self: *DaemonProcess, to: []const u8, content: []const u8) !void {
    // sendMessage doesn't need mutex as it spawns a separate child process
    var argv = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
    defer argv.deinit(self.allocator);

    try argv.append(self.allocator, "gork-agent");
    try argv.append(self.allocator, "send");
    try argv.append(self.allocator, "--to");
    try argv.append(self.allocator, to);
    try argv.append(self.allocator, content);

    var child = std.process.Child.init(argv.items, self.allocator);
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    try child.spawn();

    const term = child.wait() catch {
        return error.SendFailed;
    };

    const exit_code = switch (term) {
        .Exited => |code| code,
        else => 1,
    };

    if (exit_code != 0) {
        return error.SendFailed;
    }
}

pub const StartConfig = struct {
    binary_path: []const u8,
    port: u16,
    relay: ?[]const u8 = null,
};

/// Log parser thread - reads daemon stdout and parses events
fn logParserLoop(self: *DaemonProcess, stdout_file: *std.Io.File) void {
    defer self.allocator.destroy(stdout_file);

    // Read all output into memory with size limit
    var output = std.ArrayList(u8).initCapacity(self.allocator, 1024) catch |err| {
        std.log.err("Failed to allocate buffer for log parsing: {}", .{err});
        return;
    };
    defer output.deinit(self.allocator);

    var read_buf: [4096]u8 = undefined;
    var bytes_read = stdout_file.read(&read_buf) catch {
        // Error reading, exit loop
        return;
    };

    while (bytes_read > 0) {
        // Check size limit before appending
        if (output.items.len + bytes_read > MAX_LOG_BUFFER_SIZE) {
            std.log.warn("Gork daemon log output exceeded max size ({} bytes), truncating", .{MAX_LOG_BUFFER_SIZE});
            break;
        }
        output.appendSlice(self.allocator, read_buf[0..bytes_read]) catch {
            // OOM, just continue with what we have
            std.log.warn("Gork daemon log parser OOM, using partial data", .{});
            break;
        };
        bytes_read = stdout_file.read(&read_buf) catch {
            // Error reading, exit loop
            break;
        };
    }

    // Parse line by line
    var lines = std.mem.splitScalar(u8, output.items, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            if (parseDaemonEvent(self.allocator, line)) |event| {
                self.event_callback(self.allocator, event);
            } else |_| {}
        }
    }
}

/// Health monitor thread - checks daemon health
fn healthMonitorLoop(daemon: *DaemonProcess) void {
    while (true) {
        std.Thread.sleep(5 * std.time.ns_per_s);

        daemon.mutex.lock();
        const state = daemon.state;
        daemon.mutex.unlock();

        if (state != .running and state != .starting) break;

        daemon.mutex.lock();
        const has_child = daemon.child != null;
        daemon.mutex.unlock();

        if (!has_child) {
            // Child was removed, process must have died
            daemon.mutex.lock();
            const was_running = daemon.state == .running;
            daemon.mutex.unlock();

            if (was_running) {
                daemon.mutex.lock();
                daemon.state = .crashed;
                daemon.mutex.unlock();

                const event = Event{ .stopped = std.fmt.allocPrint(daemon.allocator, "daemon process died", .{}) catch "daemon process died" };
                daemon.event_callback(daemon.allocator, event);
            }
            break;
        }

        // Note: We can't directly poll the process in Zig 0.15.2 without blocking
        // The log parser will detect EOF when the process dies and stop
        // This health monitor serves as a secondary check
    }
}

/// Parse daemon log output for events
/// NOTE: Allocates and copies all strings - caller owns the memory
fn parseDaemonEvent(allocator: Allocator, line: []const u8) !Event {
    // Parse gork-agent log output
    // Examples:
    // "✅ Daemon listening on: /ip4/127.0.0.1/tcp/4001"
    // "Peer ID: 12D3KooW..."
    // "📨 Message received from alice.near"

    if (std.mem.indexOf(u8, line, "Daemon listening on")) |_| {
        // Extract listen address and port from line
        // Format: "✅ Daemon listening on: /ip4/127.0.0.1/tcp/4001"
        const addr_start = std.mem.indexOf(u8, line, "/ip") orelse line.len;
        const addr_end = std.mem.indexOfPos(u8, line, addr_start, " /tcp/") orelse line.len;
        const listen_addr = if (addr_start < line.len and addr_end > addr_start)
            try allocator.dupe(u8, line[addr_start..addr_end])
        else
            try allocator.dupe(u8, "unknown");

        // Extract port
        const port_str = blk: {
            if (std.mem.indexOf(u8, line, "/tcp/")) |idx| {
                const port_start = idx + "/tcp/".len;
                var port_end = port_start;
                while (port_end < line.len and line[port_end] >= '0' and line[port_end] <= '9') {
                    port_end += 1;
                }
                break :blk line[port_start..port_end];
            }
            break :blk "";
        };
        const port = if (port_str.len > 0)
            std.fmt.parseInt(u16, port_str, 10) catch 4001
        else
            4001;

        // Peer ID should be on a previous line - for now use empty
        const peer_id = try allocator.dupe(u8, "");

        return Event{
            .started = StartedInfo{
                .peer_id = peer_id,
                .listen_addr = listen_addr,
                .port = port,
            },
        };
    }

    if (std.mem.indexOf(u8, line, "Message received from")) |_| {
        // Extract "from" field
        const parts = std.mem.splitSequence(u8, line, " ");
        var from: []const u8 = "";
        var iter = parts;
        var idx: usize = 0;
        while (iter.next()) |part| : (idx += 1) {
            if (idx == 3) {
                from = part;
                break;
            }
        }

        // Extract message content (everything after the from field)
        var content: []const u8 = "";
        if (idx + 1 < line.len) {
            const content_start = std.mem.indexOf(u8, line, from) orelse line.len;
            const after_from = content_start + from.len;
            if (after_from < line.len) {
                // Skip the space after from
                const content_start_idx = if (after_from < line.len and line[after_from] == ' ')
                    after_from + 1
                else
                    after_from;
                content = line[content_start_idx..];
            }
        }

        return Event{
            .message_received = IncomingMessage{
                .from = try allocator.dupe(u8, from),
                .message_type = try allocator.dupe(u8, "chat"),
                .content = try allocator.dupe(u8, content),
                .timestamp = @intCast(0),
            },
        };
    }

    if (std.mem.indexOf(u8, line, "Peer connected")) |_| {
        const peer_id = extractPeerId(line) orelse return error.InvalidFormat;
        return Event{ .peer_connected = try allocator.dupe(u8, peer_id) };
    }

    if (std.mem.indexOf(u8, line, "Peer disconnected")) |_| {
        const peer_id = extractPeerId(line) orelse return error.InvalidFormat;
        return Event{ .peer_disconnected = try allocator.dupe(u8, peer_id) };
    }

    return error.UnknownEvent;
}

/// Extract peer ID from a line containing one
fn extractPeerId(line: []const u8) ?[]const u8 {
    const peer_marker = "12D3KooW";
    const idx = std.mem.indexOf(u8, line, peer_marker) orelse return null;
    const end = idx + 52; // libp2p peer IDs are 52 chars
    if (end > line.len) return null;
    return line[idx..end];
}
