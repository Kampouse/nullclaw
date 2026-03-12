//! Gork P2P agent collaboration tool.
//!
//! Wraps the Gork hybrid system to enable agents to discover peers,
//! verify reputation, send messages, and execute tasks across a
//! decentralized P2P network with NEAR blockchain trust verification.

const std = @import("std");
const io = std.Options.debug_io;
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

const hybrid_mod = @import("../gork_hybrid.zig");

pub const GorkTool = struct {
    allocator: std.mem.Allocator,
    hybrid: ?*hybrid_mod.Hybrid,
    config: hybrid_mod.Config,
    allocator_for_callbacks: std.mem.Allocator,  // Stored for callbacks

    pub const tool_name = "gork";
    pub const tool_description =
        \\P2P agent collaboration with NEAR trust verification.
        \\Discover agents, verify reputation, send messages, and execute tasks across a decentralized network.
        \\
        \\Actions:
        \\- discover: Find agents by capability (e.g., "csv-analysis")
        \\- send: Send message to agent
        \\- whoami: Show your agent identity
        \\- status: Show system status
        \\- health: Show system health and metrics
        \\- metrics: Show performance and security metrics
    ;

    pub const tool_params =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["discover","send","whoami","status","health","metrics"],"description":"Action to perform"},"capability":{"type":"string","description":"Capability to search for (discover action)"},"limit":{"type":"integer","description":"Maximum results (discover action)","default":10},"to":{"type":"string","description":"Recipient agent ID (send action)"},"message":{"type":"string","description":"Message content (send action)"}},"required":["action"]}
    ;

    const vtable: root.Tool.VTable = .{
        .execute = &struct {
            fn f(ptr: *anyopaque, allocator: std.mem.Allocator, args: JsonObjectMap) anyerror!root.ToolResult {
                const self: *GorkTool = @ptrCast(@alignCast(ptr));
                return self.execute(allocator, args);
            }
        }.f,
        .name = &struct {
            fn f(_: *anyopaque) []const u8 {
                return tool_name;
            }
        }.f,
        .description = &struct {
            fn f(_: *anyopaque) []const u8 {
                return tool_description;
            }
        }.f,
        .parameters_json = &struct {
            fn f(_: *anyopaque) []const u8 {
                return tool_params;
            }
        }.f,
        .deinit = &struct {
            fn f(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *GorkTool = @ptrCast(@alignCast(ptr));
                self.stop(); // Stop the hybrid system before destroying
                allocator.destroy(self);
            }
        }.f,
    };

    pub fn init(allocator: std.mem.Allocator, config: hybrid_mod.Config) !*GorkTool {
        const gork_tool = try allocator.create(GorkTool);
        gork_tool.* = .{
            .allocator = allocator,
            .hybrid = null,
            .config = config,
            .allocator_for_callbacks = allocator,
        };
        return gork_tool;
    }

    pub fn tool(self: *GorkTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    /// Initialize the hybrid system
    pub fn start(self: *GorkTool) !void {
        if (self.hybrid != null) return;

        const hybrid = try self.allocator.create(hybrid_mod.Hybrid);
        errdefer self.allocator.destroy(hybrid);

        hybrid.* = try hybrid_mod.Hybrid.init(
            self.allocator,
            self.config,
            handleHybridEventWrapper,
            io,
        );

        // Register this hybrid instance for replay protection callbacks
        hybrid_mod.Hybrid.setActiveHybrid(hybrid);

        try hybrid.start();
        self.hybrid = hybrid;
    }

    /// Stop the hybrid system
    pub fn stop(self: *GorkTool) void {
        if (self.hybrid) |h| {
            h.stop();
            self.allocator.destroy(h);
            self.hybrid = null;
        }
    }

    pub fn execute(self: *GorkTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse
            return ToolResult.fail("Missing 'action' parameter");

        if (std.mem.eql(u8, action, "discover")) {
            return self.discover(allocator, args);
        } else if (std.mem.eql(u8, action, "send")) {
            return self.send(allocator, args);
        } else if (std.mem.eql(u8, action, "whoami")) {
            return self.whoami(allocator);
        } else if (std.mem.eql(u8, action, "status")) {
            return self.status(allocator);
        } else if (std.mem.eql(u8, action, "health")) {
            return self.health(allocator);
        } else if (std.mem.eql(u8, action, "metrics")) {
            return self.metrics(allocator);
        } else {
            return ToolResult.fail("Unknown action");
        }
    }

    fn discover(self: *GorkTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const capability = root.getString(args, "capability") orelse
            return ToolResult.fail("Missing 'capability' parameter");

        const limit = root.getInt(args, "limit") orelse 10;

        if (self.hybrid == null) {
            return ToolResult.fail("Gork hybrid system not started");
        }

        const agents = self.hybrid.?.discover(capability, @intCast(limit)) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Discover failed: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        };
        defer {
            for (agents) |*a| a.deinit(allocator);
            allocator.free(agents);
        }

        // Format output as JSON
        var output = try std.ArrayList(u8).initCapacity(allocator, 0);
        try output.appendSlice(allocator, "{\"agents\":[");

        for (agents, 0..) |agent, i| {
            if (i > 0) try output.appendSlice(allocator, ",");
            try output.appendSlice(allocator, "{\"agent_id\":\"");
            try output.appendSlice(allocator, agent.account_id);
            try output.appendSlice(allocator, "\",\"reputation\":");
            const rep_str = try std.fmt.allocPrint(allocator, "{}", .{agent.reputation});
            defer allocator.free(rep_str);
            try output.appendSlice(allocator, rep_str);
            try output.appendSlice(allocator, ",\"online\":");
            try output.appendSlice(allocator, if (agent.online) "true" else "false");
            try output.appendSlice(allocator, "}");
        }

        try output.appendSlice(allocator, "]}");

        return ToolResult.ok(try output.toOwnedSlice(allocator));
    }

    fn send(self: *GorkTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const to = root.getString(args, "to") orelse
            return ToolResult.fail("Missing 'to' parameter");

        const message = root.getString(args, "message") orelse
            return ToolResult.fail("Missing 'message' parameter");

        if (self.hybrid == null) {
            return ToolResult.fail("Gork hybrid system not started");
        }

        self.hybrid.?.sendMessage(to, message) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Send failed: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        };

        const output = try std.fmt.allocPrint(allocator, "Message sent to {s}", .{to});
        return ToolResult.ok(output);
    }

    fn whoami(self: *GorkTool, allocator: std.mem.Allocator) !ToolResult {
        if (self.config.account_id.len == 0) {
            return ToolResult.fail("No account ID configured");
        }

        const output = try std.fmt.allocPrint(allocator, "{{\"agent_id\":\"{s}\"}}", .{self.config.account_id});
        return ToolResult.ok(output);
    }

    fn status(self: *GorkTool, allocator: std.mem.Allocator) !ToolResult {
        const state = if (self.hybrid) |h| h.getState() else .stopped;

        const state_str = switch (state) {
            .stopped => "stopped",
            .starting => "starting",
            .running => "running",
            .degraded => "degraded",
            .stopping => "stopping",
        };

        const has_daemon = self.hybrid != null and self.hybrid.?.daemon != null;
        const has_poller = self.hybrid != null and self.hybrid.?.poller != null;

        const output = try std.fmt.allocPrint(allocator,
            \\{{"state":"{s}","daemon":{},"poller":{},"account_id":"{s}"}}
        , .{ state_str, has_daemon, has_poller, self.config.account_id });

        return ToolResult.ok(output);
    }

    fn health(self: *GorkTool, allocator: std.mem.Allocator) !ToolResult {
        if (self.hybrid) |h| {
            const state = h.getState();
            const is_healthy = state == .running or state == .degraded;
            const has_daemon = h.daemon != null;
            const has_poller = h.poller != null;
            const queue_size = h.message_queue_size.load(.seq_cst);
            const queue_max = h.message_queue_max;

            const output = try std.fmt.allocPrint(allocator,
                \\{{"healthy":{},"state":"{s}","daemon":{},"poller":{},"queue_size":{d},"queue_max":{d},"account_id":"{s}"}}
            , .{ is_healthy, @tagName(state), has_daemon, has_poller, queue_size, queue_max, self.config.account_id });

            return ToolResult.ok(output);
        } else {
            return ToolResult.ok("{\"healthy\":false,\"state\":\"not_initialized\"}");
        }
    }

    fn metrics(self: *GorkTool, allocator: std.mem.Allocator) !ToolResult {
        if (self.hybrid) |h| {
            const output = h.getMetrics() catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to get metrics: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
            };
            return ToolResult.ok(output);
        } else {
            return ToolResult.ok("{\"error\":\"hybrid_not_started\"}");
        }
    }
};

/// Handle events from the hybrid system (wrapper for callback)
/// NOTE: This function frees all owned strings in the event
fn handleHybridEventWrapper(allocator: std.mem.Allocator, event: hybrid_mod.Event) void {
    handleHybridEvent(allocator, event);
}

/// Handle events from the hybrid system
/// NOTE: This function frees all owned strings in the event
fn handleHybridEvent(allocator: std.mem.Allocator, event: hybrid_mod.Event) void {
    // Ensure event is always cleaned up, even on panic
    // Note: We need to copy to a mutable variable to call deinit
    var mut_event = event;
    defer mut_event.deinit(allocator);

    // Log the event
    switch (mut_event) {
        .message_received => |*msg| {
            // Replay protection: check timestamp
            const now_ns = std.Io.Clock.real.now(io).nanoseconds;
            const now: u64 = @intCast(@divTrunc(now_ns, 1_000_000_000));
            const msg_time = msg.timestamp;

            if (now > msg_time) {
                const age = now - msg_time;
                std.log.info("Gork: Message received from {s}: {s} (age: {d}s)", .{ msg.from, msg.content, age });

                // TODO: Full replay protection would require checking seen_messages cache
                // and rejecting messages older than max_message_age_secs
                // This needs access to the Hybrid instance which isn't available here
                if (age > 300) { // Log warning for messages > 5 minutes old
                    std.log.warn("Gork: Very old message received, possible replay attack", .{});
                }
            } else {
                // Message from the future - clock skew
                const skew = msg_time - now;
                std.log.info("Gork: Message received from {s}: {s} (clock skew: {d}s)", .{ msg.from, msg.content, skew });
            }
        },
        .peer_connected => |peer| {
            std.log.info("Gork: Peer connected: {s}", .{peer});
        },
        .peer_disconnected => |peer| {
            std.log.info("Gork: Peer disconnected: {s}", .{peer});
        },
        .daemon_started => |*info| {
            std.log.info("Gork: Daemon started on {s}:{}", .{ info.listen_addr, info.port });
        },
        .daemon_stopped => |reason| {
            if (reason) |r| {
                if (r.len > 0) {
                    std.log.warn("Gork: Daemon stopped: {s}", .{r});
                } else {
                    std.log.warn("Gork: Daemon stopped: unknown", .{});
                }
            } else {
                std.log.warn("Gork: Daemon stopped: unknown", .{});
            }
        },
        .poll_result => |result| {
            if (result.message_count > 0) {
                std.log.info("Gork: Poll processed {} messages", .{result.processed});
            }
        },
        .state_changed => |state| {
            std.log.info("Gork: State changed to {}", .{state});
        },
    }
}
