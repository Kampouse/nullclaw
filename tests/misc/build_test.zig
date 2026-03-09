const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add zquic module
    const zquic_module = b.addModule("zquic", .{
        .root_source_file = b.path("lib/zquic/src/root.zig"),
    });

    // Create test executable
    const test_exe = b.addExecutable(.{
        .name = "test-quic-runtime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_runtime_quic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zquic", .module = zquic_module },
            },
        }),
    });

    b.installArtifact(test_exe);

    // Run step
    const run_cmd = b.addRunArtifact(test_exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("test-quic", "Run QUIC runtime test");
    run_step.dependOn(&run_cmd.step);
}
