const std = @import("std");
const trace = @import("src/trace.zig");

pub fn main() !void {
    // Initialize tracing with DEBUG level
    trace.init(std.heap.page_allocator, .debug);
    defer trace.deinit();
    
    std.debug.print("\n=== NULLCLAW TRACING DEMO ===\n\n", .{});
    
    // Test 1: Basic logging at different levels
    trace.trace(.daemon, "Trace: Very detailed message", .{});
    trace.debug(.daemon, "Debug: Starting initialization", .{});
    trace.info(.daemon, "Info: NullClaw v1.0 starting", .{});
    trace.warn(.config, "Warn: Config file not found, using defaults", .{});
    trace.err(.provider_openai, "Error: API timeout after 30s", .{});
    
    std.debug.print("\n--- Span Tracking ---\n\n", .{});
    
    // Test 2: Span with timing
    var span1 = trace.startSpan(.gateway, "http_request") orelse return;
    defer span1.end();
    
    span1.logInSpan(.info, "Processing GET /api/status", .{});
    
    // Simulate work
    std.time.sleep(50 * std.time.ns_per_ms);
    
    span1.logInSpan(.debug, "Request processed successfully", .{});
    
    // Test 3: Nested span
    std.debug.print("\n--- Nested Spans ---\n\n", .{});
    
    var parent = trace.startSpan(.agent_dispatcher, "process_message") orelse return;
    defer parent.end();
    
    parent.logInSpan(.info, "Received message from Telegram", .{});
    
    {
        var child = trace.startSpan(.tool_shell, "execute_command") orelse return;
        defer child.end();
        
        child.logInSpan(.info, "Running: ls -la", .{});
        std.time.sleep(25 * std.time.ns_per_ms);
        child.logInSpan(.debug, "Command completed", .{});
    }
    
    parent.logInSpan(.info, "Message processed", .{});
    
    // Test 4: Error tracking
    std.debug.print("\n--- Error Tracking ---\n\n", .{});
    
    var error_span = trace.startSpan(.provider_gemini, "api_call") orelse return;
    defer error_span.end();
    
    error_span.logInSpan(.info, "Calling Gemini API", .{});
    std.time.sleep(10 * std.time.ns_per_ms);
    error_span.setError();
    error_span.logInSpan(.err, "API returned 429 Rate Limit", .{});
    
    std.debug.print("\n=== DEMO COMPLETE ===\n\n", .{});
}
