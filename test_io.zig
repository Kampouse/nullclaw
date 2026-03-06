const std = @import("std");

pub fn main() !void {
    // Test what replaced std.io.fixedBufferStream
    var buf: [100]u8 = undefined;
    
    // Try pattern 3: std.Io.FixedBufferStream (capital I)
    var fbs = std.Io.FixedBufferStream.init(&buf);
    _ = fbs;
    
    std.debug.print("Success with std.Io.FixedBufferStream.init\n", .{});
}
