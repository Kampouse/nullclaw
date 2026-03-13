const std = @import("std");
const cron = @import("src/cron.zig");
const util = @import("src/util.zig");

test "cron scheduler executes jobs with real timestamp" {
    var allocator = std.heap.page_allocator;
    var scheduler = cron.CronScheduler.init(allocator, null, .{ .enabled = true, .{} })    defer scheduler.deinit(allocator);

    // Add a job that should execute immediately (next_run_secs = 0)
    const job_id = try scheduler.addJob(.{
        .id = "test-immediate",
        .expression = "* * * * * *",
        .command = "echo 'test passed'",
        .job_type = .shell,
    });
    try std.testing.expect(job_id.len > 0);

    // Verify job is registered
    try std.testing.expect(scheduler.jobs.items.len == 1);
    try std.testing.expectEqualStrings("test-immediate", scheduler.jobs.items[0].id);

    // Job should have next_run_secs = 0 (or very close)
    try std.testing.expect(scheduler.jobs.items[0].next_run_secs == 0);

    // Run one tick with current timestamp
    const now = util.timestampUnix();
    const executed = scheduler.tick(now, null);

    // Job should have executed
    try std.testing.expect(executed);

    // Check that job status was updated
    try std.testing.expectEqualStrings("ok", scheduler.jobs.items[0].last_status orelse "expected 'ok' status");
}

test "cron scheduler skips future jobs" {
    var allocator = std.heap.page_allocator;
    var scheduler = cron.CronScheduler.init(allocator, null, .{ .enabled = true, .{} })
    defer scheduler.deinit(allocator);

    // Add a job that should NOT execute yet (1 hour in future)
    const future_time = util.timestampUnix() + 3600;
    const job_id = try scheduler.addAtJob(.{
        .id = "test-future",
        .timestamp_s = future_time,
        .command = "echo 'should not run'",
        .job_type = .shell,
    });
    try std.testing.expect(job_id.len > 0);

    // Verify job is registered
    try std.testing.expect(scheduler.jobs.items.len == 1);

    // Run one tick with current timestamp
    const now = util.timestampUnix();
    const executed = scheduler.tick(now, null);

    // Job should NOT have executed (it's in the future)
    try std.testing.expect(!executed);

    // Status should still be null
    try std.testing.expect(scheduler.jobs.items[0].last_status == null);
}

test "cron scheduler respects paused jobs" {
    var allocator = std.heap.page_allocator;
    var scheduler = cron.CronScheduler.init(allocator, null, .{ .enabled = true, .{} })
    defer scheduler.deinit(allocator);

    // Add a paused job
    const job_id = try scheduler.addJob(.{
        .id = "test-paused",
        .expression = "* * * * * *",
        .command = "echo 'should not run'",
        .job_type = .shell,
        .paused = true,
    });
    try std.testing.expect(job_id.len > 0);

    // Verify job is paused
    try std.testing.expect(scheduler.jobs.items[0].paused);

    // Run one tick with current timestamp
    const now = util.timestampUnix();
    const executed = scheduler.tick(now, null);

    // Job should NOT have executed (it's paused)
    try std.testing.expect(!executed);
}
