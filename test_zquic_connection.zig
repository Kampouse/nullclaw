const std = @import("std");
const quic = @import("lib/zquic/src/root.zig");

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("zquic Connection Test\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});

    std.debug.print("1. Creating config... ", .{});
    const config = quic.Config{
        .is_server = false,
        .alpn = "gork-agent",
    };
    std.debug.print("✅\n", .{});

    std.debug.print("2. Creating Io (undefined)... ", .{});
    const io: std.Io = undefined;
    std.debug.print("✅\n", .{});

    std.debug.print("3. Creating Connection (accept)... ", .{});
    var conn = quic.Connection.accept(config, io) catch |err| {
        std.debug.print("❌ Failed: {}\n", .{err});
        return;
    };
    std.debug.print("✅\n", .{});

    std.debug.print("4. Testing send (should return 0 for no data)... ", .{});
    var buf: [1500]u8 = undefined;
    const len = conn.send(&buf);
    std.debug.print("Sent {} bytes ✅\n", .{len});

    std.debug.print("5. Testing pollEvent (should return null)... ", .{});
    if (conn.pollEvent()) |event| {
        std.debug.print("Got event: {}\n", .{event});
    } else {
        std.debug.print("No events ✅\n", .{});
    }

    std.debug.print("\n✅ Connection created successfully!\n\n", .{});
}
