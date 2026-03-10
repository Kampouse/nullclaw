        // ---------- Native Auto-Discovery Using Build System ----------
        // Auto-discovers ALL test modules using subsystem patterns (no hardcoded list, no bash)
        const auto_discovery_step = b.step("test-discover", "Auto-discover and test ALL modules (native API, no bash)");

        // Test all major subsystems using substring filters
        // Use broader filters to catch ALL tests (not just those with "/" in name)
        const subsystems = [_]struct { name: []const u8, description: []const u8 }{
            .{ .name = "agent", .description = "Agent subsystem (root, prompt, dispatcher, etc.)" },
            .{ .name = "memory", .description = "Memory subsystem (engines, retrieval, storage)" },
            .{ .name = "tools", .description = "Tools subsystem (shell, memory, scheduling, etc.)" },
            .{ .name = "providers", .description = "Provider subsystem (SSE, compatible, etc.)" },
            .{ .name = "security", .description = "Security subsystem (policy, validation)" },
            .{ .name = "channels", .description = "Channels subsystem" },
        };

        for (subsystems) |subsystem_info| {
            const subsystem = subsystem_info.name;

            // Create individual step for this subsystem to show clear results
            const subsystem_step_name = b.fmt("test-discover-{s}", .{subsystem});
            const subsystem_step = b.step(subsystem_step_name, subsystem_info.description);
            auto_discovery_step.dependOn(subsystem_step);

            // Create filter array for this subsystem
            const subsystem_filters = b.allocator.alloc([]const u8, 1) catch @panic("OOM");
            subsystem_filters[0] = subsystem;

            // Library tests for this subsystem
            const subsystem_lib_tests = b.addTest(.{
                .root_module = lib_mod.?,
                .filters = subsystem_filters,
            });
            if (sqlite3) |lib| {
                subsystem_lib_tests.root_module.linkLibrary(lib);
            }
            if (enable_postgres) {
                subsystem_lib_tests.root_module.linkSystemLibrary("pq", .{});
            }

            // Executable tests for this subsystem
            const subsystem_exe_tests = b.addTest(.{
                .root_module = exe.root_module,
                .filters = subsystem_filters,
            });

            // Add both to subsystem step
            const lib_run = b.addRunArtifact(subsystem_lib_tests);
            const exe_run = b.addRunArtifact(subsystem_exe_tests);

            subsystem_step.dependOn(&lib_run.step);
            subsystem_step.dependOn(&exe_run.step);
        }
    }
}