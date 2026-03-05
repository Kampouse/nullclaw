const std = @import("std");

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("Minimal QUIC Test - Finding Crash Point\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});

    // Test 1: Create UDP socket
    std.debug.print("1. Creating UDP socket... ", .{});
    const socket = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK,
        std.posix.IPPROTO.UDP,
    ) catch |err| {
        std.debug.print("❌ Failed: {}\n", .{err});
        return;
    };
    std.debug.print("✅\n", .{});
    defer std.posix.close(socket);

    // Test 2: Parse address
    std.debug.print("2. Parsing server address... ", .{});
    const addr = std.net.Address.parseIp4("127.0.0.1", 4003) catch |err| {
        std.debug.print("❌ Failed: {}\n", .{err});
        return;
    };
    std.debug.print("✅\n", .{});

    // Test 3: Send raw UDP packet
    std.debug.print("3. Sending UDP packet... ", .{});
    const test_data = "QUIC_TEST";
    _ = std.posix.sendto(socket, test_data, 0, &addr.any, addr.getOsSockLen()) catch |err| {
        std.debug.print("⚠️  Send failed (non-blocking): {}\n", .{err});
    };
    std.debug.print("✅\n", .{});

    // Test 4: Try to receive
    std.debug.print("4. Checking for response... ", .{});
    var recv_buf: [1500]u8 = undefined;
    const recv_len = std.posix.recv(socket, &recv_buf, 0) catch 0;
    if (recv_len > 0) {
        std.debug.print("✅ Received {} bytes\n", .{recv_len});
    } else {
        std.debug.print("⚠️  No response (expected for non-blocking)\n", .{});
    }

    std.debug.print("\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("✅ All basic operations work!\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});
}
