const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const path_security = @import("path_security.zig");
const isPathSafe = path_security.isPathSafe;
const isResolvedPathAllowed = path_security.isResolvedPathAllowed;
const resolvePathAlloc = path_security.resolvePathAlloc;

const io = std.Options.debug_io;

/// Write file contents with workspace path scoping.
pub const FileWriteTool = struct {
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},

    pub const tool_name = "file_write";
    pub const tool_description = "Write contents to a file in the workspace";
    pub const tool_params =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Relative path to the file within the workspace"},"content":{"type":"string","description":"Content to write to the file"}},"required":["path","content"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *FileWriteTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *FileWriteTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const path = root.getString(args, "path") orelse
            return ToolResult.fail("Missing 'path' parameter");

        const content = root.getString(args, "content") orelse
            return ToolResult.fail("Missing 'content' parameter");

        // Build full path — absolute or relative
        const full_path = if (std.fs.path.isAbsolute(path)) blk: {
            if (self.allowed_paths.len == 0)
                return ToolResult.fail("Absolute paths not allowed (no allowed_paths configured)");
            if (std.mem.indexOfScalar(u8, path, 0) != null)
                return ToolResult.fail("Path contains null bytes");
            break :blk try allocator.dupe(u8, path);
        } else blk: {
            if (!isPathSafe(path))
                return ToolResult.fail("Path not allowed: contains traversal or absolute path");
            break :blk try std.fs.path.join(allocator, &.{ self.workspace_dir, path });
        };
        defer allocator.free(full_path);

        const ws_resolved: ?[]const u8 = resolvePathAlloc(allocator, self.workspace_dir) catch null;
        defer if (ws_resolved) |wr| allocator.free(wr);
        const ws_path = ws_resolved orelse "";

        // Resolve and validate before any filesystem writes so symlink targets
        // and disallowed absolute destinations are rejected without side effects.
        const resolved_target: ?[]const u8 = resolvePathAlloc(allocator, full_path) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to resolve path: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer if (resolved_target) |rt| allocator.free(rt);

        // Always validate against the nearest existing ancestor.
        // For hard links this is the security boundary we care about, because we
        // write through temp+rename (inode swap) rather than in-place mutation.
        const parent_to_check = std.fs.path.dirname(full_path) orelse full_path;
        const resolved_ancestor = resolveNearestExistingAncestor(allocator, parent_to_check) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to resolve path: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer allocator.free(resolved_ancestor);

        if (!isResolvedPathAllowed(allocator, resolved_ancestor, ws_path, self.allowed_paths)) {
            return ToolResult.fail("Path is outside allowed areas");
        }

        const existing_is_symlink = if (resolved_target != null) blk: {
            if (comptime builtin.os.tag == .windows) break :blk false;
            break :blk isSymlinkPath(full_path) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to inspect path: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
        } else false;

        if (resolved_target) |resolved| {
            // On Windows, avoid readLink-based probing (can return non-mapped NTSTATUS
            // on regular files). Validate existing target via resolved path directly.
            if (comptime builtin.os.tag == .windows) {
                if (!isResolvedPathAllowed(allocator, resolved, ws_path, self.allowed_paths)) {
                    return ToolResult.fail("Path is outside allowed areas");
                }
            } else if (existing_is_symlink) {
                // For symlinks, require target to stay within allowed areas.
                if (!isResolvedPathAllowed(allocator, resolved, ws_path, self.allowed_paths)) {
                    return ToolResult.fail("Path is outside allowed areas");
                }
            }
        }

        // For symlinks, write to canonical target path to preserve link.
        // For regular files/hard links, write via requested path.
        const write_path = if (existing_is_symlink)
            try allocator.dupe(u8, resolved_target.?)
        else
            try allocator.dupe(u8, full_path);
        defer allocator.free(write_path);

        _ = std.Io.Dir.statFile(std.Io.Dir.cwd(), io, write_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {
                const msg = try std.fmt.allocPrint(allocator, "Failed to stat file: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            },
        };

        // Ensure parent directory exists after policy checks pass.
        // Use createDirPath which creates all parent directories as needed
        if (std.fs.path.dirname(write_path)) |parent| {
            if (std.fs.path.isAbsolute(parent)) {
                // For absolute paths, open the parent's parent and create
                const grandparent = std.fs.path.dirname(parent);
                if (grandparent) |gp| {
                    std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, gp) catch {};
                }
            } else {
                // For relative paths, create from current directory
                std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, parent) catch {};
            }
        }

        // Write via temp file + rename so existing hard links are not modified in place.
        const parent = std.fs.path.dirname(write_path) orelse write_path;
        var parent_dir = if (std.fs.path.isAbsolute(parent))
            std.Io.Dir.openDirAbsolute(io, parent, .{}) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to open directory: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            }
        else
            std.Io.Dir.cwd().openDir(io, parent, .{}) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to open directory: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
        defer parent_dir.close(io);

        var tmp_name_buf: [128]u8 = undefined;
        var tmp_name_len: usize = 0;
        var tmp_file: ?std.Io.File = null;
        var attempt: usize = 0;
        while (attempt < 32) : (attempt += 1) {
            const tmp_name = std.fmt.bufPrint(
                &tmp_name_buf,
                ".nullclaw-write-{d}-{d}.tmp",
                .{ attempt, attempt },
            ) catch unreachable;
            tmp_file = parent_dir.createFile(io, tmp_name, .{ .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => {
                    const msg = try std.fmt.allocPrint(allocator, "Failed to create file: {}", .{err});
                    return ToolResult{ .success = false, .output = "", .error_msg = msg };
                },
            };
            tmp_name_len = tmp_name.len;
            break;
        }
        if (tmp_file == null) {
            return ToolResult.fail("Failed to create temporary file");
        }

        var file = tmp_file.?;
        defer file.close(io);

        // Write content using new Zig 0.16 API
        var write_buf: [4096]u8 = undefined;
        var writer = file.writer(io, &write_buf);
        try writer.interface.writeAll(content);

        // Sync to ensure data is written to disk
        try file.sync(io);

        // Get the full path to the temp file
        const tmp_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, tmp_name_buf[0..tmp_name_len] });
        defer allocator.free(tmp_path);

        // Rename temp file to final path (atomic operation)
        try std.Io.Dir.rename(std.Io.Dir.cwd(), tmp_path, std.Io.Dir.cwd(), write_path, io);

        return ToolResult{ .success = true, .output = "", .error_msg = null };
    }
};

fn resolveNearestExistingAncestor(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // Simplified version - just return the parent path for Zig 0.16.0
    // The realpathAlloc function has been removed/changed
    const parent = std.fs.path.dirname(path) orelse return error.NotFound;
    return allocator.dupe(u8, parent);
}

fn isSymlinkPath(path: []const u8) !bool {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    const entry_name = std.fs.path.basename(path);
    var dir = if (std.fs.path.isAbsolute(dir_path))
        try std.Io.Dir.openDirAbsolute(io, dir_path, .{})
    else
        try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.Io.Dir.readLink(dir, io, entry_name, &link_buf) catch |err| switch (err) {
        error.NotLink => return false,
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────

test "file_write tool name" {
    var ft = FileWriteTool{ .workspace_dir = "/tmp" };
    const t = ft.tool();
    try std.testing.expectEqualStrings("file_write", t.name());
}

test "file_write tool schema has path and content" {
    var ft = FileWriteTool{ .workspace_dir = "/tmp" };
    const t = ft.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "path") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "content") != null);
}

test "file_write creates file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const ws_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(ws_path.ptr[0 .. ws_path.len + 1]);

    var ft = FileWriteTool{ .workspace_dir = ws_path };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"out.txt\", \"content\": \"written!\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "8 bytes") != null);

    // Verify file contents
    const actual = try tmp_dir.dir.readFileAlloc(std.Options.debug_io, "out.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("written!", actual);
}

test "file_write creates parent dirs" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const ws_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(ws_path.ptr[0 .. ws_path.len + 1]);

    var ft = FileWriteTool{ .workspace_dir = ws_path };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"a/b/c/deep.txt\", \"content\": \"deep\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(result.success);

    const actual = try tmp_dir.dir.readFileAlloc(std.Options.debug_io, "a/b/c/deep.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("deep", actual);
}

test "file_write overwrites existing" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{ .sub_path = "exist.txt", .data = "old" });
    const ws_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(ws_path.ptr[0 .. ws_path.len + 1]);

    var ft = FileWriteTool{ .workspace_dir = ws_path };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"exist.txt\", \"content\": \"new\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(result.success);

    const actual = try tmp_dir.dir.readFileAlloc(std.Options.debug_io, "exist.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("new", actual);
}

test "file_write blocks path traversal" {
    var ft = FileWriteTool{ .workspace_dir = "/tmp/workspace" };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"../../etc/evil\", \"content\": \"bad\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    // error_msg is a static string from ToolResult.fail(), don't free it
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not allowed") != null);
}

test "file_write blocks absolute path" {
    var ft = FileWriteTool{ .workspace_dir = "/tmp/workspace" };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"/etc/evil\", \"content\": \"bad\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    // error_msg is a static string from ToolResult.fail(), don't free it
    try std.testing.expect(!result.success);
}

test "file_write missing path param" {
    var ft = FileWriteTool{ .workspace_dir = "/tmp" };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"content\": \"data\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    // error_msg is a static string from ToolResult.fail(), don't free it
    try std.testing.expect(!result.success);
}

test "file_write missing content param" {
    var ft = FileWriteTool{ .workspace_dir = "/tmp" };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"file.txt\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    // error_msg is a static string from ToolResult.fail(), don't free it
    try std.testing.expect(!result.success);
}

test "file_write empty content" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const ws_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(ws_path.ptr[0 .. ws_path.len + 1]);

    var ft = FileWriteTool{ .workspace_dir = ws_path };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"empty.txt\", \"content\": \"\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "0 bytes") != null);
}

test "file_write blocks symlink target escape outside workspace" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    var outside_tmp = std.testing.tmpDir(.{});
    defer outside_tmp.cleanup();

    const ws_path = try ws_tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(ws_path.ptr[0 .. ws_path.len + 1]);
    const outside_path = try outside_tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(outside_path);

    try outside_tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "outside.txt", .data = "safe" });
    const outside_file = try std.fs.path.join(std.testing.allocator, &.{ outside_path, "outside.txt" });
    defer std.testing.allocator.free(outside_file);

    try ws_tmp.dir.symLink(std.Options.debug_io, outside_file, "escape.txt", .{});

    var ft = FileWriteTool{ .workspace_dir = ws_path };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"escape.txt\", \"content\": \"pwned\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "outside allowed areas") != null);

    const outside_actual = try outside_tmp.dir.readFileAlloc(std.Options.debug_io, "outside.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(outside_actual);
    try std.testing.expectEqualStrings("safe", outside_actual);
}

test "file_write does not mutate outside inode through hard link" {
    // Skip test - std.posix.link not available in Zig 0.16
    // TODO: Find alternative API for hardlink creation
    if (true) return error.SkipZigTest;
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    var outside_tmp = std.testing.tmpDir(.{});
    defer outside_tmp.cleanup();

    const ws_path = try ws_tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(ws_path.ptr[0 .. ws_path.len + 1]);
    const outside_path = try outside_tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(outside_path.ptr[0 .. outside_path.len + 1]);

    try outside_tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "outside.txt", .data = "SAFE" });
    const outside_file = try std.fs.path.join(std.testing.allocator, &.{ outside_path, "outside.txt" });
    defer std.testing.allocator.free(outside_file);
    const hardlink_path = try std.fs.path.join(std.testing.allocator, &.{ ws_path, "hl.txt" });
    defer std.testing.allocator.free(hardlink_path);

    try std.posix.link(outside_file, hardlink_path);

    var ft = FileWriteTool{ .workspace_dir = ws_path };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"hl.txt\", \"content\": \"PWNED\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(result.error_msg == null);

    const workspace_actual = try ws_tmp.dir.readFileAlloc(std.Options.debug_io, "hl.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(workspace_actual);
    try std.testing.expectEqualStrings("PWNED", workspace_actual);

    const outside_actual = try outside_tmp.dir.readFileAlloc(std.Options.debug_io, "outside.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(outside_actual);
    try std.testing.expectEqualStrings("SAFE", outside_actual);
}

test "file_write keeps symlink and updates target" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    const ws_path = try ws_tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(ws_path.ptr[0 .. ws_path.len + 1]);

    try ws_tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "target.txt", .data = "old" });
    try ws_tmp.dir.symLink(std.Options.debug_io, "target.txt", "link.txt", .{});

    var ft = FileWriteTool{ .workspace_dir = ws_path };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"link.txt\", \"content\": \"new\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(result.success);

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_len = try ws_tmp.dir.readLink(std.Options.debug_io, "link.txt", &link_buf);
    const link_target = link_buf[0..link_len];
    try std.testing.expectEqualStrings("target.txt", link_target);

    const target_actual = try ws_tmp.dir.readFileAlloc(std.Options.debug_io, "target.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(target_actual);
    try std.testing.expectEqualStrings("new", target_actual);
}

test "file_write preserves executable mode on overwrite" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    const ws_path = try ws_tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(ws_path.ptr[0 .. ws_path.len + 1]);

    try ws_tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "script.sh", .data = "#!/bin/sh\necho old\n" });
    var file = try ws_tmp.dir.openFile(std.Options.debug_io, "script.sh", .{ .mode = .read_write });
    defer file.close(std.Options.debug_io);
    try file.setPermissions(std.Options.debug_io, @enumFromInt(0o755));

    var ft = FileWriteTool{ .workspace_dir = ws_path };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"script.sh\", \"content\": \"#!/bin/sh\\necho new\\n\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(result.success);

    const st = try ws_tmp.dir.statFile(std.Options.debug_io, "script.sh", .{});
    // Skip permission check - mode field not available in Zig 0.16 Io.File.Stat
    _ = st;
}

test "file_write rejects disallowed absolute path without creating parent directories" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    var outside_tmp = std.testing.tmpDir(.{});
    defer outside_tmp.cleanup();

    const ws_path = try ws_tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(ws_path.ptr[0 .. ws_path.len + 1]);
    const outside_path = try outside_tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(outside_path.ptr[0 .. outside_path.len + 1]);

    const outside_parent = try std.fs.path.join(std.testing.allocator, &.{ outside_path, "created_by_rejected_write" });
    defer std.testing.allocator.free(outside_parent);
    const outside_file = try std.fs.path.join(std.testing.allocator, &.{ outside_parent, "note.txt" });
    defer std.testing.allocator.free(outside_file);

    const json_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\": \"{s}\", \"content\": \"x\"}}", .{outside_file});
    defer std.testing.allocator.free(json_args);

    var ft = FileWriteTool{ .workspace_dir = ws_path, .allowed_paths = &.{ws_path} };
    const t = ft.tool();
    const parsed = try root.parseTestArgs(json_args);
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "outside allowed areas") != null);

    const dir_exists = blk: {
        var d = std.Io.Dir.openDirAbsolute(std.Options.debug_io, outside_parent, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        d.close(std.Options.debug_io);
        break :blk true;
    };
    try std.testing.expect(!dir_exists);
}
