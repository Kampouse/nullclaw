/// Test isolation helper - resets global state between tests
/// Call resetAll() in test setup or beforeEach hooks
const std = @import("std");
const health = @import("health.zig");
const daemon_mod = @import("daemon.zig");
const gork_hybrid = @import("gork_hybrid.zig");
const onboard_mod = @import("onboard.zig");

/// Reset all global state for test isolation
/// Call this at the start of tests that may be affected by global state pollution
pub fn resetAll() void {
    resetHealth();
    resetDaemon();
    resetGorkHybrid();
    // Note: onboard uses file system state, harder to reset
}

/// Reset health registry state
pub fn resetHealth() void {
    health.reset();
}

/// Reset daemon shutdown flag
pub fn resetDaemon() void {
    daemon_mod.resetShutdownRequested();
}

/// Reset gork_hybrid active instance
pub fn resetGorkHybrid() void {
    gork_hybrid.resetActiveHybrid();
}

test "resetAll does not crash" {
    resetAll();
    // If we get here, all reset functions exist and work
}
