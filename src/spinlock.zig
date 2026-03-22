//! Thread-safe spinlock using atomics
//! Avoids std.Io.Mutex which requires I/O context parameters

const std = @import("std");

pub const Spinlock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init() Spinlock {
        return .{};
    }

    pub fn lock(self: *Spinlock) void {
        while (true) {
            // Try to acquire the lock
            if (!self.locked.swap(true, .acquire)) {
                // Successfully acquired
                return;
            }
            // Lock is held, spin with pause
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Spinlock) void {
        self.locked.store(false, .release);
    }
};
