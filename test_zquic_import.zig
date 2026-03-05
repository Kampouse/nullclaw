const std = @import("std");
const quic = @import("lib/zquic/src/root.zig");

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("zquic Import Test\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});

    std.debug.print("1. Testing zquic import... ", .{});
    _ = quic;
    std.debug.print("✅\n", .{});

    std.debug.print("2. Testing Config type... ", .{});
    const config = quic.Config{
        .is_server = false,
    };
    _ = config;
    std.debug.print("✅\n", .{});

    std.debug.print("3. Testing ConnectionId... ", .{});
    const io: std.Io = undefined;
    const cid = quic.ConnectionId.generate(0, io);
    std.debug.print("✅ CID: ", .{});
    for (cid.bytes) |b| {
        std.debug.print("{x:0>2}", .{b});
    }
    std.debug.print("\n", .{});

    std.debug.print("\n✅ All zquic types accessible!\n\n", .{});
}
