//! Web channel stub - disabled when websocket library unavailable
//! This file provides a no-op WebChannel implementation

const std = @import("std");
const Channel = @import("root.zig").Channel;

pub const WebChannel = struct {
    bus: ?*anyopaque = null, // Stub field for tests

    pub fn initFromConfig(_: std.mem.Allocator, _: anytype) @This() {
        return .{};
    }
    pub fn channel(_: *@This()) Channel {
        unreachable;
    }
    pub fn setBus(_: *@This(), _: anytype) void {}
};
