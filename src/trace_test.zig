const std = @import("std");
const testing = std.testing;
const trace = @import("trace.zig");
const trace_simple = @import("trace_simple.zig");

test "Tracer - basic initialization" {
    trace.init(testing.allocator, .debug);
    defer trace.deinit();
}

test "Tracer - logging" {
    trace.init(testing.allocator, .info);
    defer trace.deinit();
    
    trace.info(.daemon, "Test message: {}", .{42});
    trace.err(.provider_openai, "Error: {s}", .{"test"});
}

test "Tracer - span creation" {
    trace.init(testing.allocator, .info);
    defer trace.deinit();
    
    var span = trace.startSpan(.daemon, "test_operation") orelse return error.NoTracer;
    defer trace.endSpan(&span);
    
    try testing.expect(span.id > 0);
    try testing.expect(std.mem.eql(u8, span.operation, "test_operation"));
}

test "Tracer - span timing" {
    trace.init(testing.allocator, .info);
    defer trace.deinit();
    
    var span = trace.startSpan(.daemon, "timed_op") orelse return error.NoTracer;
    
    // Simulate work
    for (0..1000) |_| {
        _ = std.time.nanoTimestamp();
    }
    
    trace.endSpan(&span);
    
    try testing.expect(span.end_time != null);
}

test "Tracer - logging within span" {
    trace.init(testing.allocator, .debug);
    defer trace.deinit();
    
    var span = trace.startSpan(.agent_dispatcher, "test") orelse return error.NoTracer;
    defer trace.endSpan(&span);
    
    span.logInSpan(.info, "Test message", .{});
    span.logInSpan(.debug, "Debug message with value: {}", .{42});
}

test "Simple trace - initialization" {
    trace_simple.init(testing.allocator, .info);
    defer trace_simple.deinit();
}

test "Simple trace - logging" {
    trace_simple.init(testing.allocator, .debug);
    defer trace_simple.deinit();
    
    trace_simple.info(.daemon, "Test info message", .{});
    trace_simple.debug(.agent_dispatcher, "Debug message: {}", .{42});
}

test "Simple trace - span" {
    trace_simple.init(testing.allocator, .debug);
    defer trace_simple.deinit();
    
    var span = trace_simple.startSpan(.daemon, "test") orelse return;
    defer trace_simple.endSpan(&span);
    
    span.logInSpan(.info, "Inside span", .{});
}

test "Simple trace - scoped span" {
    trace_simple.init(testing.allocator, .debug);
    defer trace_simple.deinit();
    
    {
        var scoped = trace_simple.ScopedSpan.init(.daemon, "scoped_op");
        defer scoped.deinit();
        
        if (scoped.get()) |s| {
            s.logInSpan(.info, "Inside scoped span", .{});
        }
    }
}
