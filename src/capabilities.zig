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
    "zig_build_operations",
    "self_diagnose",
    "self_update",
    "image_info",
    "gork",
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

fn categorizeTool(name: []const u8) []const u8 {
    // Categorize tools based on name patterns
    if (std.mem.eql(u8, name, "shell") or
        std.mem.eql(u8, name, "file_read") or
        std.mem.eql(u8, name, "file_write") or
        std.mem.eql(u8, name, "file_edit") or
        std.mem.eql(u8, name, "git")) {
        return "core";
    }
    if (std.mem.eql(u8, name, "cargo_operations") or
        std.mem.eql(u8, name, "zig_build_operations")) {
        return "package_managers";
    }
    if (std.mem.eql(u8, name, "self_diagnose")) {
        return "diagnostics";
    }
    if (std.mem.startsWith(u8, name, "memory_")) {
        return "memory";
    }
    return "advanced";
}

fn formatToolCategory(allocator: std.mem.Allocator, tools: []const []const u8, category: []const u8, label: []const u8) !?[]u8 {
    var filtered: std.ArrayListUnmanaged([]const u8) = .empty;
    defer filtered.deinit(allocator);

    for (tools) |tool| {
        if (std.mem.eql(u8, categorizeTool(tool), category)) {
            try filtered.append(allocator, tool);
        }
    }

    if (filtered.items.len == 0) return null;

    const joined = try joinNames(allocator, filtered.items);
    defer allocator.free(joined);
    return try std.fmt.allocPrint(allocator, "  {s}: {s}\n", .{ label, joined });
}

fn buildToolsSection(allocator: std.mem.Allocator, tool_names: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "Tools (compiled in):\n");

    // Core tools
    if (try formatToolCategory(allocator, tool_names, "core", "Core tools")) |line| {
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    // Package managers
    if (try formatToolCategory(allocator, tool_names, "package_managers", "Package managers")) |line| {
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    // Diagnostics
    if (try formatToolCategory(allocator, tool_names, "diagnostics", "Diagnostics")) |line| {
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    // Memory
    if (try formatToolCategory(allocator, tool_names, "memory", "Memory")) |line| {
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    // Advanced (everything else)
    if (try formatToolCategory(allocator, tool_names, "advanced", "Advanced")) |line| {
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    return try out.toOwnedSlice(allocator);
}

fn appendJsonStringArray(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, names: []const []const u8) !void {
    try buf.appendSlice(allocator, "[");
    for (names, 0..) |name, i| {
        if (i != 0) try buf.appendSlice(allocator, ", ");
        try buf.append(allocator, '"');
        try buf.appendSlice(allocator, name);
        try buf.append(allocator, '"');
    }
    try buf.appendSlice(allocator, "]");
}

pub fn buildManifestJson(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    runtime_tools: ?[]const Tool,
) ![]u8 {
    const channels_enabled = try collectChannelNames(allocator, cfg_opt, .build_enabled);
    defer allocator.free(channels_enabled);
    const engines_enabled = try collectMemoryEngineNames(allocator, .build_enabled);
    defer allocator.free(engines_enabled);
    const runtime_tool_names = try collectRuntimeToolNames(allocator, cfg_opt, runtime_tools);
    defer allocator.free(runtime_tool_names);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n");

    // Channels section
    try buf.appendSlice(allocator, "  \"channels\": ");
    try appendJsonStringArray(&buf, allocator, channels_enabled);
    try buf.appendSlice(allocator, ",\n");

    // Memory engines section
    try buf.appendSlice(allocator, "  \"memory_engines\": ");
    try appendJsonStringArray(&buf, allocator, engines_enabled);
    try buf.appendSlice(allocator, ",\n");

    // Tools section
    try buf.appendSlice(allocator, "  \"tools\": ");
    try appendJsonStringArray(&buf, allocator, runtime_tool_names);
    try buf.appendSlice(allocator, "\n");

    try buf.appendSlice(allocator, "}");

    return buf.toOwnedSlice(allocator);
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

    // Build tools section dynamically from core_tool_names
    const core_tools_list: []const []const u8 = &core_tool_names;
    const tools_section = try buildToolsSection(allocator, core_tools_list);
    defer allocator.free(tools_section);

    return try std.fmt.allocPrint(
        allocator,
        "NullClaw Capabilities\n" ++
            "\n" ++
            "Channels:\n" ++
            "  Enabled (build):     {s}\n" ++
            "  Configured:          {s}\n" ++
            "  Disabled (build):    {s}\n" ++
            "\n" ++
            "Memory:\n" ++
            "  Engines (build):     {s}\n" ++
            "  Active backend:      {s}\n" ++
            "  Disabled (build):    {s}\n" ++
            "\n" ++
            "{s}" ++
            "  Optional:            {s}\n" ++
            "  Disabled (config):   {s}\n" ++
            "\n" ++
            "Total tools available: {d}\n",
        .{
            channels_enabled_s,
            channels_configured_s,
            channels_disabled_s,
            engines_enabled_s,
            active_backend,
            engines_disabled_s,
            tools_section,
            runtime_tools_s,
            optional_disabled_s,
            runtime_tool_names.len,
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

    try std.testing.expect(std.mem.indexOf(u8, summary, "NullClaw Capabilities") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Tools (compiled in)") != null);
}

test "categorizeTool returns correct categories" {
    try std.testing.expectEqualStrings("core", categorizeTool("shell"));
    try std.testing.expectEqualStrings("core", categorizeTool("file_read"));
    try std.testing.expectEqualStrings("core", categorizeTool("git"));
    try std.testing.expectEqualStrings("package_managers", categorizeTool("cargo_operations"));
    try std.testing.expectEqualStrings("package_managers", categorizeTool("zig_build_operations"));
    try std.testing.expectEqualStrings("diagnostics", categorizeTool("self_diagnose"));
    try std.testing.expectEqualStrings("memory", categorizeTool("memory_store"));
    try std.testing.expectEqualStrings("memory", categorizeTool("memory_recall"));
    try std.testing.expectEqualStrings("advanced", categorizeTool("gork"));
    try std.testing.expectEqualStrings("advanced", categorizeTool("delegate"));
}

test "formatToolCategory allocates and frees correctly" {
    const tools = [_][]const u8{ "shell", "file_read", "git" };
    const result = try formatToolCategory(std.testing.allocator, &tools, "core", "Core tools");
    defer {
        if (result) |r| std.testing.allocator.free(r);
    }

    try std.testing.expect(result != null);
    if (result) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "Core tools") != null);
        try std.testing.expect(std.mem.indexOf(u8, r, "shell") != null);
    }
}

test "formatToolCategory returns null for empty category" {
    const tools = [_][]const u8{ "shell", "file_read" };
    const result = try formatToolCategory(std.testing.allocator, &tools, "memory", "Memory");
    try std.testing.expect(result == null);
}

test "buildToolsSection has no memory leaks" {
    const tools = [_][]const u8{
        "shell",
        "file_read",
        "file_write",
        "file_edit",
        "git",
        "cargo_operations",
        "zig_build_operations",
        "self_diagnose",
        "image_info",
        "gork",
        "memory_store",
        "memory_recall",
        "memory_list",
        "memory_forget",
        "delegate",
        "schedule",
        "spawn",
    };

    const result = try buildToolsSection(std.testing.allocator, &tools);
    defer std.testing.allocator.free(result);

    // Verify all categories are present
    try std.testing.expect(std.mem.indexOf(u8, result, "Core tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Package managers") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Diagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Advanced") != null);

    // Verify specific tools are present
    try std.testing.expect(std.mem.indexOf(u8, result, "gork") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "cargo_operations") != null);
}

test "buildToolsSection handles empty tool list" {
    const tools = [_][]const u8{};
    const result = try buildToolsSection(std.testing.allocator, &tools);
    defer std.testing.allocator.free(result);

    // Should only have header, no categories
    try std.testing.expect(std.mem.indexOf(u8, result, "Tools (compiled in)") != null);
}

test "buildSummaryText memory leak check" {
    // Run multiple times to check for leaks
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const summary = try buildSummaryText(std.testing.allocator, null, null);
        std.testing.allocator.free(summary);
    }
    try std.testing.expect(true); // If we got here, no leaks
}

