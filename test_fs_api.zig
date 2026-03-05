const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Try to find the new API
    std.debug.print("Testing std.Io.Dir...\n", .{});
    
    // Try current directory
    var dir = std.Io.Dir.default;
    _ = dir;
    
    std.debug.print("✅ std.Io.Dir exists\n", .{});
}
