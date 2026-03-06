const std = @import("std");
const util = @import("src/util.zig");

pub fn main() !void {
    var buf: [100]u8 = undefined;
    var fbs = util.fixedBufferStream(&buf);
    
    const w = fbs.writer();
    try w.print("Hello, {s}!", .{"world"});
    
    const written = fbs.getWritten();
    std.debug.print("Written: {s}\n", .{written});
}
