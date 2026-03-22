//! Test Io helper for Zig 0.16.0-dev
//! std.testing.io_instance is uninitialized in the test runner, causing segfaults.
//! This provides a properly initialized Io instance.

const std = @import("std");

/// Get a test Io instance
/// Call this at the start of each test that needs Io
pub fn getTestIo() std.Io {
    return std.testing.io;
}

/// Alternative: Create a fresh Io instance if testing.io doesn't work
pub fn createTestIo(allocator: std.mem.Allocator) !std.Io.Threaded {
    return std.Io.Threaded.init(allocator, .{});
}
