// Quick test to verify tracing works
const std = @import("std");
const trace = @import("src/trace.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // Initialize tracing
    trace.init(allocator, .debug);
    defer trace.deinit();
    
    // Test basic logging
    trace.info(.daemon, "Test message from tracing system", .{});
    trace.debug(.provider_openai, "Debug message with value: {}", .{42});
    trace.err(.tool_shell, "Error test: {s}", .{"test error"});
    
    // Test span
    var span = trace.startSpan(.gateway, "test_operation") orelse {
        trace.err(.daemon, "Failed to create span", .{});
        return;
    };
    defer span.end();
    
    span.logInSpan(.info, "Inside span operation", .{});
    
    std.debug.print("\nTracing test complete! Check output above.\n", .{});
}
