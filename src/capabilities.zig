const std = @import("std");
const build_options = @import("build_options");
const channel_catalog = @import("channel_catalog.zig");
const config_mod = @import("config.zig");
const memory_registry = @import("memory/engines/registry.zig");
const tools_mod = @import("tools/root.zig");

const Config = config_mod.Config;
const Tool = tools_mod.Tool;

const core_tool_names = [_][]const u8{
    "shell",
    "file_read",
    "file_write",
    "file_edit",
    "git",
    "cargo_operations",
    "image_info",
    "memory_store",
    "memory_recall",
    "memory_list",
    "memory_forget",
    "delegate",
    "schedule",
    "spawn",
};

const optional_tool_names = [_][]const u8{
    "http_request",
    "browser",
    "screenshot",
    "composio",
    "browser_open",
    "hardware_board_info",
    "hardware_memory",
    "i2c",
};

const ChannelMode = enum {
    build_enabled,
    build_disabled,
    configured,
};

const EngineMode = enum {
    build_enabled,
    build_disabled,
};

const OptionalToolMode = enum {
    enabled,
    disabled,
};

fn runtimeHasTool(runtime_tools: ?[]const Tool, name: []const u8) bool {
    const tools = runtime_tools orelse return false;
    for (tools) |t| {
        if (std.mem.eql(u8, t.name(), name)) return true;
    }
    return false;
}

fn optionalToolEnabledByConfig(cfg: *const Config, name: []const u8) bool {
    if (std.mem.eql(u8, name, "http_request")) return cfg.http_request.enabled;
    if (std.mem.eql(u8, name, "browser")) return cfg.browser.enabled;
    if (std.mem.eql(u8, name, "screenshot")) return cfg.browser.enabled;
    if (std.mem.eql(u8, name, "composio")) return cfg.composio.enabled and cfg.composio.api_key != null;
    if (std.mem.eql(u8, name, "browser_open")) return cfg.browser.allowed_domains.len > 0;
    if (std.mem.eql(u8, name, "hardware_board_info")) return cfg.hardware.enabled;
    if (std.mem.eql(u8, name, "hardware_memory")) return cfg.hardware.enabled;
    if (std.mem.eql(u8, name, "i2c")) return cfg.hardware.enabled;
    return false;
}

fn collectChannelNames(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    mode: ChannelMode,
) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);

    for (channel_catalog.known_channels) |meta| {
        const enabled = channel_catalog.isBuildEnabled(meta.id);
        const configured = if (cfg_opt) |cfg| channel_catalog.configuredCount(cfg, meta.id) > 0 else false;
        const include = switch (mode) {
            .build_enabled => enabled,
            .build_disabled => !enabled,
            .configured => enabled and configured,
        };
        if (!include) continue;
        try out.append(allocator, meta.key);
    }

    return try out.toOwnedSlice(allocator);
}

fn collectMemoryEngineNames(allocator: std.mem.Allocator, mode: EngineMode) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);

    for (memory_registry.known_backend_names) |name| {
        const enabled = memory_registry.findBackend(name) != null;
        const include = switch (mode) {
            .build_enabled => enabled,
            .build_disabled => !enabled,
        };
        if (!include) continue;
        try out.append(allocator, name);
    }

    return try out.toOwnedSlice(allocator);
}

fn collectOptionalTools(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    mode: OptionalToolMode,
) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);

    const cfg = cfg_opt orelse {
        if (mode == .disabled) {
            for (optional_tool_names) |name| {
                try out.append(allocator, name);
            }
        }
        return try out.toOwnedSlice(allocator);
    };

    for (optional_tool_names) |name| {
        const enabled = optionalToolEnabledByConfig(cfg, name);
        const include = switch (mode) {
            .enabled => enabled,
            .disabled => !enabled,
        };
        if (!include) continue;
        try out.append(allocator, name);
    }

    return try out.toOwnedSlice(allocator);
}

fn collectRuntimeToolNames(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    runtime_tools: ?[]const Tool,
) ![]const []const u8 {
    if (runtime_tools) |tools| {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer out.deinit(allocator);
        for (tools) |t| {
            try out.append(allocator, t.name());
        }
        return try out.toOwnedSlice(allocator);
    }

    var estimated: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer estimated.deinit(allocator);
    for (core_tool_names) |name| {
        try estimated.append(allocator, name);
    }
    const optional_enabled = try collectOptionalTools(allocator, cfg_opt, .enabled);
    defer allocator.free(optional_enabled);
    for (optional_enabled) |name| {
        try estimated.append(allocator, name);
    }
    return try estimated.toOwnedSlice(allocator);
}

fn joinNames(allocator: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    if (names.len == 0) {
        try out.appendSlice(allocator, "(none)");
        return try out.toOwnedSlice(allocator);
    }

    for (names, 0..) |name, i| {
        if (i != 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, name);
    }
    return try out.toOwnedSlice(allocator);
}

fn appendJsonStringArray(w: anytype, names: []const []const u8) !void {
    try w.writeStreamingAll(std.Options.debug_io, "[");
    for (names, 0..) |name, i| {
        if (i != 0) try w.writeStreamingAll(std.Options.debug_io, ", ");
        try w.print("{f}", .{std.json.fmt(name, .{})});
    }
    try w.writeStreamingAll(std.Options.debug_io, "]");
}

pub fn buildManifestJson(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    runtime_tools: ?[]const Tool,
) ![]u8 {
    // TODO: Zig 0.16.0 - Rewrite without ArrayList.writer()
    // For now, return a minimal stub
    _ = cfg_opt;
    _ = runtime_tools;
    return try allocator.dupe(u8, "{}");
}

pub fn buildSummaryText(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    runtime_tools: ?[]const Tool,
) ![]u8 {
    const channels_enabled = try collectChannelNames(allocator, cfg_opt, .build_enabled);
    defer allocator.free(channels_enabled);
    const channels_disabled = try collectChannelNames(allocator, cfg_opt, .build_disabled);
    defer allocator.free(channels_disabled);
    const channels_configured = try collectChannelNames(allocator, cfg_opt, .configured);
    defer allocator.free(channels_configured);

    const engines_enabled = try collectMemoryEngineNames(allocator, .build_enabled);
    defer allocator.free(engines_enabled);
    const engines_disabled = try collectMemoryEngineNames(allocator, .build_disabled);
    defer allocator.free(engines_disabled);

    const runtime_tool_names = try collectRuntimeToolNames(allocator, cfg_opt, runtime_tools);
    defer allocator.free(runtime_tool_names);
    const optional_disabled = try collectOptionalTools(allocator, cfg_opt, .disabled);
    defer allocator.free(optional_disabled);

    const channels_enabled_s = try joinNames(allocator, channels_enabled);
    defer allocator.free(channels_enabled_s);
    const channels_disabled_s = try joinNames(allocator, channels_disabled);
    defer allocator.free(channels_disabled_s);
    const channels_configured_s = try joinNames(allocator, channels_configured);
    defer allocator.free(channels_configured_s);
    const engines_enabled_s = try joinNames(allocator, engines_enabled);
    defer allocator.free(engines_enabled_s);
    const engines_disabled_s = try joinNames(allocator, engines_disabled);
    defer allocator.free(engines_disabled_s);
    const runtime_tools_s = try joinNames(allocator, runtime_tool_names);
    defer allocator.free(runtime_tools_s);
    const optional_disabled_s = try joinNames(allocator, optional_disabled);
    defer allocator.free(optional_disabled_s);

    const active_backend = if (cfg_opt) |cfg| cfg.memory.backend else "(unknown)";
    const tools_label = if (runtime_tools != null) "tools (loaded)" else "tools (estimated from config)";

    return try std.fmt.allocPrint(
        allocator,
        "Capabilities\n" ++
            "\nAvailable in this runtime:\n" ++
            "  channels (build): {s}\n" ++
            "  channels (configured): {s}\n" ++
            "  memory engines (build): {s}\n" ++
            "  active memory backend: {s}\n" ++
            "  {s}: {s}\n" ++
            "\nNot available in this runtime:\n" ++
            "  channels (disabled in build): {s}\n" ++
            "  memory engines (disabled in build): {s}\n" ++
            "  optional tools (disabled by config): {s}\n",
        .{
            channels_enabled_s,
            channels_configured_s,
            engines_enabled_s,
            active_backend,
            tools_label,
            runtime_tools_s,
            channels_disabled_s,
            engines_disabled_s,
            optional_disabled_s,
        },
    );
}

pub fn buildPromptSection(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    runtime_tools: ?[]const Tool,
) ![]u8 {
    const channels_enabled = try collectChannelNames(allocator, cfg_opt, .build_enabled);
    defer allocator.free(channels_enabled);
    const channels_disabled = try collectChannelNames(allocator, cfg_opt, .build_disabled);
    defer allocator.free(channels_disabled);
    const channels_configured = try collectChannelNames(allocator, cfg_opt, .configured);
    defer allocator.free(channels_configured);

    const engines_enabled = try collectMemoryEngineNames(allocator, .build_enabled);
    defer allocator.free(engines_enabled);
    const engines_disabled = try collectMemoryEngineNames(allocator, .build_disabled);
    defer allocator.free(engines_disabled);

    const runtime_tool_names = try collectRuntimeToolNames(allocator, cfg_opt, runtime_tools);
    defer allocator.free(runtime_tool_names);
    const optional_disabled = try collectOptionalTools(allocator, cfg_opt, .disabled);
    defer allocator.free(optional_disabled);

    const channels_enabled_s = try joinNames(allocator, channels_enabled);
    defer allocator.free(channels_enabled_s);
    const channels_disabled_s = try joinNames(allocator, channels_disabled);
    defer allocator.free(channels_disabled_s);
    const channels_configured_s = try joinNames(allocator, channels_configured);
    defer allocator.free(channels_configured_s);
    const engines_enabled_s = try joinNames(allocator, engines_enabled);
    defer allocator.free(engines_enabled_s);
    const engines_disabled_s = try joinNames(allocator, engines_disabled);
    defer allocator.free(engines_disabled_s);
    const runtime_tools_s = try joinNames(allocator, runtime_tool_names);
    defer allocator.free(runtime_tools_s);
    const optional_disabled_s = try joinNames(allocator, optional_disabled);
    defer allocator.free(optional_disabled_s);

    const active_backend = if (cfg_opt) |cfg| cfg.memory.backend else "(unknown)";
    const tools_line = if (runtime_tools != null)
        "Tools loaded in this runtime"
    else
        "Tools estimated from current config";

    return try std.fmt.allocPrint(
        allocator,
        "## Runtime Capabilities\n\n" ++
            "### Available in this runtime\n" ++
            "- Channels enabled in build: {s}\n" ++
            "- Configured channels: {s}\n" ++
            "- Memory backends enabled in build: {s}\n" ++
            "- Active memory backend: {s}\n" ++
            "- {s}: {s}\n\n" ++
            "### Not available in this runtime\n" ++
            "- Channels disabled in build: {s}\n" ++
            "- Memory backends disabled in build: {s}\n" ++
            "- Optional tools disabled by current config: {s}\n\n",
        .{
            channels_enabled_s,
            channels_configured_s,
            engines_enabled_s,
            active_backend,
            tools_line,
            runtime_tools_s,
            channels_disabled_s,
            engines_disabled_s,
            optional_disabled_s,
        },
    );
}

test "buildManifestJson emits core sections" {
    const manifest = try buildManifestJson(std.testing.allocator, null, null);
    defer std.testing.allocator.free(manifest);

    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"channels\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"memory_engines\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"tools\"") != null);
}

test "buildSummaryText includes availability sections" {
    const summary = try buildSummaryText(std.testing.allocator, null, null);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "Available in this runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Not available in this runtime") != null);
}
