const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Try new API
    const bytes = std.fs.File.readAllAlloc(allocator, "build.zig", 10000) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return;
    };
    defer allocator.free(bytes);
    
    std.debug.print("Read {} bytes\n", .{bytes.len});
}
