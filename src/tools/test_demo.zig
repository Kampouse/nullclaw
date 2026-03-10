//! Demo test file with intentional failures and leaks
//! This verifies that the test system actually detects issues

const std = @import("std");

// This test will FAIL
test "intentional failure - this should fail" {
    std.testing.expect(false) catch |err| {
        std.debug.print("\n❌ This test is supposed to fail!\n", .{});
        return err;
    };
}

// This test will LEAK memory
test "intentional leak - this should leak" {
    const allocator = std.testing.allocator;
    // Allocate memory but never free it - LEAK!
    const leaked = allocator.alloc(u8, 100) catch unreachable;
    _ = leaked; // Use it so compiler doesn't optimize it away
    std.debug.print("\n⚠️  This test is leaking 100 bytes!\n", .{});
}

// This test PASSES normally
test "normal passing test" {
    std.testing.expect(true) catch unreachable;
}
