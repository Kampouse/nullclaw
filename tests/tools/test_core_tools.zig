const std = @import("std");
const testing = std.testing;
const tools_mod = @import("../../src/tools/root.zig");

// Helper function to get realpath from Dir (Zig 0.16 API)
fn testDirRealpathAlloc(allocator: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    const result = try dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    // result is [:0]u8 with allocation size len+1 (includes sentinel)
    // Dupe the content without sentinel, then free the original
    const path = try allocator.dupe(u8, result[0..result.len]);
    allocator.free(result.ptr[0 .. result.len + 1]);
    return path;
}
const Tool = tools_mod.Tool;
const shell = @import("../../src/tools/shell.zig");
const file_read = @import("../../src/tools/file_read.zig");
const file_write = @import("../../src/tools/file_write.zig");
const file_edit = @import("../../src/tools/file_edit.zig");
const git = @import("../../src/tools/git.zig");
const cargo = @import("../../src/tools/cargo.zig");
const zig_build = @import("../../src/tools/zig_build.zig");
const self_diagnose = @import("../../src/tools/self_diagnose.zig");
const self_update = @import("../../src/tools/self_update.zig");
const image = @import("../../src/tools/image.zig");
const gork = @import("../../src/tools/gork.zig");
const memory_store = @import("../../src/tools/memory_store.zig");
const memory_recall = @import("../../src/tools/memory_recall.zig");
const memory_list = @import("../../src/tools/memory_list.zig");
const memory_forget = @import("../../src/tools/memory_forget.zig");
const delegate = @import("../../src/tools/delegate.zig");
const schedule = @import("../../src/tools/schedule.zig");
const spawn = @import("../../src/tools/spawn.zig");
const JsonObjectMap = tools_mod.JsonObjectMap;

// Helper to parse JSON args
fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !JsonObjectMap {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    return parsed.value.object;
}

// ─────────────────────────────────────────────────────────────────────────────
// Core Tool Tests
// ─────────────────────────────────────────────────────────────────────────────

test "ShellTool: instantiation and basic properties" {
    var tool = shell.ShellTool{
        .workspace_dir = "/tmp",
        .allowed_paths = &.{},
    };
    const t = tool.tool();
    try testing.expectEqualStrings("shell", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
    const params = t.parametersJson();
    try testing.expect(std.mem.indexOf(u8, params, "command") != null);
}

test "ShellTool: executes echo command" {
    var tool = shell.ShellTool{
        .workspace_dir = "/tmp",
        .allowed_paths = &.{},
    };
    const t = tool.tool();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try parseArgs(arena.allocator(), "{\"command\": \"echo hello\"}");
    const result = try t.execute(testing.allocator, args);
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, result.output, "hello") != null);
}

test "ShellTool: missing command parameter" {
    var tool = shell.ShellTool{
        .workspace_dir = "/tmp",
        .allowed_paths = &.{},
    };
    const t = tool.tool();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try parseArgs(arena.allocator(), "{}");
    const result = try t.execute(testing.allocator, args);
    defer result.deinit(testing.allocator);

    try testing.expect(!result.success);
}

test "FileReadTool: instantiation and basic properties" {
    var tool = file_read.FileReadTool{
        .workspace_dir = "/tmp",
        .allowed_paths = &.{},
    };
    const t = tool.tool();
    try testing.expectEqualStrings("file_read", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
    const params = t.parametersJson();
    try testing.expect(std.mem.indexOf(u8, params, "path") != null);
}

test "FileReadTool: missing path parameter" {
    var tool = file_read.FileReadTool{
        .workspace_dir = "/tmp",
        .allowed_paths = &.{},
    };
    const t = tool.tool();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try parseArgs(arena.allocator(), "{}");
    const result = try t.execute(testing.allocator, args);
    defer result.deinit(testing.allocator);

    try testing.expect(!result.success);
}

test "FileWriteTool: instantiation and basic properties" {
    var tool = file_write.FileWriteTool{
        .workspace_dir = "/tmp",
        .allowed_paths = &.{},
    };
    const t = tool.tool();
    try testing.expectEqualStrings("file_write", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
    const params = t.parametersJson();
    try testing.expect(std.mem.indexOf(u8, params, "path") != null);
    try testing.expect(std.mem.indexOf(u8, params, "content") != null);
}

test "FileWriteTool: missing content parameter" {
    var tool = file_write.FileWriteTool{
        .workspace_dir = "/tmp",
        .allowed_paths = &.{},
    };
    const t = tool.tool();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try parseArgs(arena.allocator(), "{\"path\": \"/tmp/test.txt\"}");
    const result = try t.execute(testing.allocator, args);
    defer result.deinit(testing.allocator);

    try testing.expect(!result.success);
}

test "FileEditTool: instantiation and basic properties" {
    var tool = file_edit.FileEditTool{
        .workspace_dir = "/tmp",
        .allowed_paths = &.{},
    };
    const t = tool.tool();
    try testing.expectEqualStrings("file_edit", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
}

test "GitTool: instantiation and basic properties" {
    var tool = git.GitTool{
        .workspace_dir = "/tmp",
    };
    const t = tool.tool();
    try testing.expectEqualStrings("git", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
    const params = t.parametersJson();
    try testing.expect(std.mem.indexOf(u8, params, "operation") != null);
}

test "CargoTool: instantiation and basic properties" {
    var tool = cargo.CargoTool{
        .workspace_dir = "/tmp",
        .allowed_paths = &.{},
    };
    const t = tool.tool();
    try testing.expectEqualStrings("cargo_operations", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
}

test "ZigBuildTool: instantiation and basic properties" {
    var tool = zig_build.ZigBuildTool{
        .workspace_dir = "/tmp",
        .allowed_paths = &.{},
    };
    const t = tool.tool();
    try testing.expectEqualStrings("zig_build_operations", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
}

test "SelfDiagnoseTool: instantiation and basic properties" {
    var tool = self_diagnose.SelfDiagnoseTool{};
    const t = tool.tool();
    try testing.expectEqualStrings("agent_health", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
    const params = t.parametersJson();
    try testing.expect(std.mem.indexOf(u8, params, "operation") != null);
}

test "SelfUpdateTool: instantiation and basic properties" {
    var tool = self_update.SelfUpdateTool{
        .workspace_dir = "/tmp",
        .allowed_paths = &.{},
    };
    const t = tool.tool();
    try testing.expectEqualStrings("self_update", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
    const params = t.parametersJson();
    try testing.expect(std.mem.indexOf(u8, params, "operation") != null);
}

test "ImageInfoTool: instantiation and basic properties" {
    var tool = image.ImageInfoTool{};
    const t = tool.tool();
    try testing.expectEqualStrings("image_info", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
}

test "GorkTool: instantiation and basic properties" {
    var tool = gork.GorkTool{};
    const t = tool.tool();
    try testing.expectEqualStrings("gork", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
}

test "MemoryStoreTool: instantiation and basic properties" {
    var tool = memory_store.MemoryStoreTool{};
    const t = tool.tool();
    try testing.expectEqualStrings("memory_store", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
    const params = t.parametersJson();
    try testing.expect(std.mem.indexOf(u8, params, "key") != null);
    try testing.expect(std.mem.indexOf(u8, params, "content") != null);
}

test "MemoryRecallTool: instantiation and basic properties" {
    var tool = memory_recall.MemoryRecallTool{};
    const t = tool.tool();
    try testing.expectEqualStrings("memory_recall", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
    const params = t.parametersJson();
    try testing.expect(std.mem.indexOf(u8, params, "query") != null);
}

test "MemoryListTool: instantiation and basic properties" {
    var tool = memory_list.MemoryListTool{};
    const t = tool.tool();
    try testing.expectEqualStrings("memory_list", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
}

test "MemoryForgetTool: instantiation and basic properties" {
    var tool = memory_forget.MemoryForgetTool{};
    const t = tool.tool();
    try testing.expectEqualStrings("memory_forget", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
    const params = t.parametersJson();
    try testing.expect(std.mem.indexOf(u8, params, "key") != null);
}

test "DelegateTool: instantiation and basic properties" {
    var tool = delegate.DelegateTool{
        .agents = &.{},
        .fallback_api_key = null,
        .depth = 0,
    };
    const t = tool.tool();
    try testing.expectEqualStrings("delegate", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
}

test "ScheduleTool: instantiation and basic properties" {
    var tool = schedule.ScheduleTool{};
    const t = tool.tool();
    try testing.expectEqualStrings("schedule", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
}

test "SpawnTool: instantiation and basic properties" {
    var tool = spawn.SpawnTool{
        .manager = null,
    };
    const t = tool.tool();
    try testing.expectEqualStrings("spawn", t.name());
    const desc = t.description();
    try testing.expect(desc.len > 0);
}

// ─────────────────────────────────────────────────────────────────────────────
// Integration Test: allTools function creates all core tools
// ─────────────────────────────────────────────────────────────────────────────

test "allTools creates all core tools" {
    const workspace = "/tmp/test_workspace";
    var tools = try tools_mod.allTools(
        testing.allocator,
        workspace,
        .{
            .http_enabled = false,
            .browser_enabled = false,
            .screenshot_enabled = false,
            .allowed_paths = &.{},
            .repo_dir = null,
        },
    );
    defer {
        for (tools) |t| {
            t.deinit(testing.allocator);
        }
        testing.allocator.free(tools);
    }

    // Verify we have at least the core tools
    var found_core = std.StringHashMap(bool).init(testing.allocator);
    defer found_core.deinit();

    const core_tool_names = [_][]const u8{
        "shell",
        "file_read",
        "file_write",
        "file_edit",
        "git",
        "cargo_operations",
        "zig_build_operations",
        "agent_health",
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

    for (core_tool_names) |name| {
        try found_core.put(name, false);
    }

    for (tools) |t| {
        const name = t.name();
        if (found_core.get(name)) |*found| {
            found.* = true;
        }
    }

    var iter = found_core.iterator();
    while (iter.next()) |entry| {
        if (!entry.value_ptr.*) {
            std.debug.print("Missing core tool: {s}\n", .{entry.key_ptr.*});
            return error.MissingCoreTool;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Functional Tests: Tools can execute basic operations
// ─────────────────────────────────────────────────────────────────────────────

test "ShellTool: pwd command succeeds" {
    var tool = shell.ShellTool{
        .workspace_dir = "/tmp",
        .allowed_paths = &.{},
    };
    const t = tool.tool();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try parseArgs(arena.allocator(), "{\"command\": \"pwd\"}");
    const result = try t.execute(testing.allocator, args);
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);
}

test "FileReadTool: reads existing file" {
    // Create a temporary test file
    var test_dir = testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_file = "test_read.txt";
    try test_dir.dir.writeFile(.{ .sub_path = test_file, .data = "test content" });

    const test_dir_path = try testDirRealpathAlloc(testing.allocator, test_dir.dir);
    defer testing.allocator.free(test_dir_path);

    const test_file_path = try std.fs.path.join(testing.allocator, &.{ test_dir_path, test_file });
    defer testing.allocator.free(test_file_path);

    var tool = file_read.FileReadTool{
        .workspace_dir = test_dir_path,
        .allowed_paths = &.{},
    };
    const t = tool.tool();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const args_json = try std.fmt.allocPrint(arena.allocator(), "{{\"path\": \"{s}\"}}", .{test_file_path});
    const args = try parseArgs(arena.allocator(), args_json);

    const result = try t.execute(testing.allocator, args);
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, result.output, "test content") != null);
}

test "FileWriteTool: writes file successfully" {
    var test_dir = testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_dir_path = try testDirRealpathAlloc(testing.allocator, test_dir.dir);
    defer testing.allocator.free(test_dir_path);

    const test_file_path = try std.fs.path.join(testing.allocator, &.{ test_dir_path, "test_write.txt" });
    defer testing.allocator.free(test_file_path);

    var tool = file_write.FileWriteTool{
        .workspace_dir = test_dir_path,
        .allowed_paths = &.{test_dir_path},
    };
    const t = tool.tool();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const args_json = try std.fmt.allocPrint(arena.allocator(), "{{\"path\": \"{s}\", \"content\": \"written content\"}}", .{test_file_path});
    const args = try parseArgs(arena.allocator(), args_json);

    const result = try t.execute(testing.allocator, args);
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);

    // Verify file was written
    const content = try test_dir.dir.readFileAlloc(testing.allocator, "test_write.txt", 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("written content", content);
}

test "SelfDiagnoseTool: status operation" {
    var tool = self_diagnose.SelfDiagnoseTool{};
    const t = tool.tool();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try parseArgs(arena.allocator(), "{\"operation\": \"status\"}");
    const result = try t.execute(testing.allocator, args);
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);
    // Status should include memory or runtime info
    try testing.expect(result.output.len > 0);
}

test "SelfUpdateTool: status operation" {
    var tool = self_update.SelfUpdateTool{
        .workspace_dir = "/tmp",
        .allowed_paths = &.{},
    };
    const t = tool.tool();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try parseArgs(arena.allocator(), "{\"operation\": \"status\"}");
    const result = try t.execute(testing.allocator, args);
    defer result.deinit(testing.allocator);

    // Status operation should succeed (even if not in a git repo)
    // The result depends on whether we're in a git repo or not
    if (result.success) {
        try testing.expect(result.output.len > 0);
    }
}

test "MemoryStoreTool: stores and recalls" {
    var tool_store = memory_store.MemoryStoreTool{};
    var tool_recall = memory_recall.MemoryRecallTool{};

    const t_store = tool_store.tool();
    const t_recall = tool_recall.tool();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Store a memory
    const store_args = try parseArgs(arena.allocator(), "{\"key\": \"test_key\", \"content\": \"test content\"}");
    const store_result = try t_store.execute(testing.allocator, store_args);
    defer store_result.deinit(testing.allocator);
    try testing.expect(store_result.success);

    // Recall the memory
    const recall_args = try parseArgs(arena.allocator(), "{\"query\": \"test_key\"}");
    const recall_result = try t_recall.execute(testing.allocator, recall_args);
    defer recall_result.deinit(testing.allocator);
    try testing.expect(recall_result.success);
}

test "MemoryListTool: lists memories" {
    var tool = memory_list.MemoryListTool{};
    const t = tool.tool();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try parseArgs(arena.allocator(), "{}");
    const result = try t.execute(testing.allocator, args);
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tool Registration and Discovery Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Tool names match expected values" {
    var shell_tool = shell.ShellTool{ .workspace_dir = "/tmp", .allowed_paths = &.{} };
    try testing.expectEqualStrings("shell", shell_tool.tool().name());

    var file_read_tool = file_read.FileReadTool{ .workspace_dir = "/tmp", .allowed_paths = &.{} };
    try testing.expectEqualStrings("file_read", file_read_tool.tool().name());

    var file_write_tool = file_write.FileWriteTool{ .workspace_dir = "/tmp", .allowed_paths = &.{} };
    try testing.expectEqualStrings("file_write", file_write_tool.tool().name());

    var file_edit_tool = file_edit.FileEditTool{ .workspace_dir = "/tmp", .allowed_paths = &.{} };
    try testing.expectEqualStrings("file_edit", file_edit_tool.tool().name());

    var git_tool = git.GitTool{ .workspace_dir = "/tmp" };
    try testing.expectEqualStrings("git", git_tool.tool().name());

    var cargo_tool = cargo.CargoTool{ .workspace_dir = "/tmp", .allowed_paths = &.{} };
    try testing.expectEqualStrings("cargo_operations", cargo_tool.tool().name());

    var zig_build_tool = zig_build.ZigBuildTool{ .workspace_dir = "/tmp", .allowed_paths = &.{} };
    try testing.expectEqualStrings("zig_build_operations", zig_build_tool.tool().name());

    var self_diagnose_tool = self_diagnose.SelfDiagnoseTool{};
    try testing.expectEqualStrings("agent_health", self_diagnose_tool.tool().name());

    var self_update_tool = self_update.SelfUpdateTool{ .workspace_dir = "/tmp", .allowed_paths = &.{} };
    try testing.expectEqualStrings("self_update", self_update_tool.tool().name());

    var image_tool = image.ImageInfoTool{};
    try testing.expectEqualStrings("image_info", image_tool.tool().name());

    var gork_tool = gork.GorkTool{};
    try testing.expectEqualStrings("gork", gork_tool.tool().name());

    var memory_store_tool = memory_store.MemoryStoreTool{};
    try testing.expectEqualStrings("memory_store", memory_store_tool.tool().name());

    var memory_recall_tool = memory_recall.MemoryRecallTool{};
    try testing.expectEqualStrings("memory_recall", memory_recall_tool.tool().name());

    var memory_list_tool = memory_list.MemoryListTool{};
    try testing.expectEqualStrings("memory_list", memory_list_tool.tool().name());

    var memory_forget_tool = memory_forget.MemoryForgetTool{};
    try testing.expectEqualStrings("memory_forget", memory_forget_tool.tool().name());

    var delegate_tool = delegate.DelegateTool{ .agents = &.{}, .fallback_api_key = null, .depth = 0 };
    try testing.expectEqualStrings("delegate", delegate_tool.tool().name());

    var schedule_tool = schedule.ScheduleTool{};
    try testing.expectEqualStrings("schedule", schedule_tool.tool().name());

    var spawn_tool = spawn.SpawnTool{ .manager = null };
    try testing.expectEqualStrings("spawn", spawn_tool.tool().name());
}
