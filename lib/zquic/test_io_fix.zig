//! Workaround for Zig 0.16.0-dev std.testing.io_instance being uninitialized.
//! This module provides a properly initialized Io instance for tests.

const std = @import("std");

/// Global Io instance for tests
threadlocal var test_io_instance: ?std.Io.Threaded = null;

/// Get or create a test Io instance
pub fn getTestIo() std.Io {
    if (test_io_instance == null) {
        test_io_instance = std.Io.Threaded.init(.{}) catch @panic("failed to init test Io");
    }
    return test_io_instance.?.io();
}

/// Cleanup test Io instance
pub fn cleanupTestIo() void {
    if (test_io_instance) |*instance| {
        instance.deinit();
        test_io_instance = null;
    }
}
