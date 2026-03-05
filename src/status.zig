const std = @import("std");
const Config = @import("config.zig").Config;
const version = @import("version.zig");
const channel_catalog = @import("channel_catalog.zig");

pub fn run(allocator: std.mem.Allocator) !void {
    var cfg = Config.load(allocator) catch {
        std.debug.print("nullclaw Status (no config found -- run `nullclaw onboard` first)\n", .{});
        std.debug.print("\nVersion: {s}\n", .{version.string});
        return;
    };
    defer cfg.deinit();

    std.debug.print("nullclaw Status\n\n", .{});
    std.debug.print("Version:     {s}\n", .{version.string});
    std.debug.print("Workspace:   {s}\n", .{cfg.workspace_dir});
    std.debug.print("Config:      {s}\n", .{cfg.config_path});
    std.debug.print("\n", .{});
    std.debug.print("Provider:    {s}\n", .{cfg.default_provider});
    std.debug.print("Model:       {s}\n", .{cfg.default_model orelse "(default)"});
    std.debug.print("Temperature: {d:.1}\n", .{cfg.temperature});
    std.debug.print("\n", .{});
    std.debug.print("Memory:      {s} (auto-save: {s})\n", .{
        cfg.memory_backend,
        if (cfg.memory_auto_save) "on" else "off",
    });
    std.debug.print("Heartbeat:   {s}\n", .{
        if (cfg.heartbeat_enabled) "enabled" else "disabled",
    });
    std.debug.print("Security:    workspace_only={s}, max_actions/hr={d}\n", .{
        if (cfg.workspace_only) "yes" else "no",
        cfg.max_actions_per_hour,
    });
    std.debug.print("\n", .{});

    // Diagnostics
    std.debug.print("Diagnostics:   {s}\n", .{cfg.diagnostics.backend});

    // Runtime
    std.debug.print("Runtime:     {s}\n", .{cfg.runtime.kind});

    // Gateway
    std.debug.print("Gateway:     {s}:{d}\n", .{ cfg.gateway_host, cfg.gateway_port });

    // Scheduler
    std.debug.print("Scheduler:   {s} (max_tasks={d}, max_concurrent={d})\n", .{
        if (cfg.scheduler.enabled) "enabled" else "disabled",
        cfg.scheduler.max_tasks,
        cfg.scheduler.max_concurrent,
    });

    // Cost tracking
    std.debug.print("Cost:        {s}\n", .{
        if (cfg.cost.enabled) "tracking enabled" else "disabled",
    });

    // Hardware
    std.debug.print("Hardware:    {s}\n", .{
        if (cfg.hardware.enabled) "enabled" else "disabled",
    });

    // Peripherals
    std.debug.print("Peripherals: {s} ({d} boards)\n", .{
        if (cfg.peripherals.enabled) "enabled" else "disabled",
        cfg.peripherals.boards.len,
    });

    // Sandbox
    std.debug.print("Sandbox:     {s}\n", .{
        if (cfg.security.sandbox.enabled orelse false) "enabled" else "disabled",
    });

    // Audit
    std.debug.print("Audit:       {s}\n", .{
        if (cfg.security.audit.enabled) "enabled" else "disabled",
    });

    std.debug.print("\n", .{});

    // Channels
    std.debug.print("Channels:\n", .{});
    for (channel_catalog.known_channels) |meta| {
        var status_buf: [64]u8 = undefined;
        const status_text = if (meta.id == .cli)
            "always"
        else
            channel_catalog.statusText(&cfg, meta, &status_buf);
        std.debug.print("  {s}: {s}\n", .{ meta.label, status_text });
    }

    // flush removed;
}
