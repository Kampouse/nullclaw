const std = @import("std");
const builtin = @import("builtin");

const VendoredFileHash = struct {
    path: []const u8,
    sha256_hex: []const u8,
};

const VENDORED_SQLITE_HASHES = [_]VendoredFileHash{
    .{
        .path = "vendor/sqlite3/sqlite3.c",
        .sha256_hex = "dc58f0b5b74e8416cc29b49163a00d6b8bf08a24dd4127652beaaae307bd1839",
    },
    .{
        .path = "vendor/sqlite3/sqlite3.h",
        .sha256_hex = "05c48cbf0a0d7bda2b6d0145ac4f2d3a5e9e1cb98b5d4fa9d88ef620e1940046",
    },
    .{
        .path = "vendor/sqlite3/sqlite3ext.h",
        .sha256_hex = "ea81fb7bd05882e0e0b92c4d60f677b205f7f1fbf085f218b12f0b5b3f0b9e48",
    },
};

fn hashWithCanonicalLineEndings(bytes: []const u8) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk_start: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') {
            if (i > chunk_start) hasher.update(bytes[chunk_start..i]);
            hasher.update("\n");
            i += 1;
            chunk_start = i + 1;
        }
    }
    if (chunk_start < bytes.len) hasher.update(bytes[chunk_start..]);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn verifyVendoredSqliteHashes(b: *std.Build) !void {
    const max_vendor_file_size = 16 * 1024 * 1024;
    _ = max_vendor_file_size; // Used in error messages
    for (VENDORED_SQLITE_HASHES) |entry| {
        const file_path = b.pathFromRoot(entry.path);
        defer b.allocator.free(file_path);

        const bytes = blk: {
            const file = std.Io.Dir.cwd().openFile(b.graph.io, file_path, .{}) catch |err| {
                std.log.err("failed to open {s}: {s}", .{ file_path, @errorName(err) });
                return err;
            };
            defer file.close(b.graph.io);

            // Get file size
            const stat = file.stat(b.graph.io) catch |err| {
                std.log.err("failed to stat {s}: {s}", .{ file_path, @errorName(err) });
                return err;
            };

            // Read entire file
            const content = b.allocator.alloc(u8, stat.size) catch |err| {
                std.log.err("failed to allocate memory for {s}: {s}", .{ file_path, @errorName(err) });
                return err;
            };

            var buffer: [1024 * 1024]u8 = undefined;
            var reader_stream = file.reader(b.graph.io, &buffer);
            reader_stream.interface.readSliceAll(content) catch |err| {
                std.log.err("failed to read {s}: {s}", .{ file_path, @errorName(err) });
                return err;
            };

            break :blk content;
        };
        defer b.allocator.free(bytes);

        const digest = hashWithCanonicalLineEndings(bytes);

        const actual_hex_buf = std.fmt.bytesToHex(digest, .lower);
        const actual_hex = actual_hex_buf[0..];

        if (!std.mem.eql(u8, actual_hex, entry.sha256_hex)) {
            std.log.err("vendored sqlite checksum mismatch for {s}", .{entry.path});
            std.log.err("expected: {s}", .{entry.sha256_hex});
            std.log.err("actual:   {s}", .{actual_hex});
            return error.VendoredSqliteChecksumMismatch;
        }
    }
}

const ChannelSelection = struct {
    enable_channel_cli: bool = false,
    enable_channel_telegram: bool = false,
    enable_channel_discord: bool = false,
    enable_channel_slack: bool = false,
    enable_channel_whatsapp: bool = false,
    enable_channel_matrix: bool = false,
    enable_channel_mattermost: bool = false,
    enable_channel_irc: bool = false,
    enable_channel_imessage: bool = false,
    enable_channel_email: bool = false,
    enable_channel_lark: bool = false,
    enable_channel_dingtalk: bool = false,
    enable_channel_line: bool = false,
    enable_channel_onebot: bool = false,
    enable_channel_qq: bool = false,
    enable_channel_maixcam: bool = false,
    enable_channel_signal: bool = false,
    enable_channel_nostr: bool = false,
    enable_channel_nostr_public: bool = false,
    enable_channel_web: bool = false,

    fn enableAll(self: *ChannelSelection) void {
        self.enable_channel_cli = true;
        self.enable_channel_telegram = true;
        self.enable_channel_discord = true;
        self.enable_channel_slack = true;
        self.enable_channel_whatsapp = true;
        self.enable_channel_matrix = true;
        self.enable_channel_mattermost = true;
        self.enable_channel_irc = true;
        self.enable_channel_imessage = true;
        self.enable_channel_email = true;
        self.enable_channel_lark = true;
        self.enable_channel_dingtalk = true;
        self.enable_channel_line = true;
        self.enable_channel_onebot = true;
        self.enable_channel_qq = true;
        self.enable_channel_maixcam = true;
        self.enable_channel_signal = true;
        self.enable_channel_nostr = true;
        self.enable_channel_nostr_public = true;
        self.enable_channel_web = true;
    }
};

fn defaultChannels() ChannelSelection {
    var selection = ChannelSelection{};
    selection.enableAll();
    return selection;
}

fn parseChannelsOption(raw: []const u8) !ChannelSelection {
    var selection = ChannelSelection{};
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        std.log.err("empty -Dchannels list; use e.g. -Dchannels=all or -Dchannels=telegram,slack", .{});
        return error.InvalidChannelsOption;
    }

    var saw_token = false;
    var saw_all = false;
    var saw_none = false;

    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t\r\n");
        if (token.len == 0) continue;
        saw_token = true;

        if (std.mem.eql(u8, token, "all")) {
            saw_all = true;
            selection.enableAll();
        } else if (std.mem.eql(u8, token, "none")) {
            saw_none = true;
            selection = .{};
        } else if (std.mem.eql(u8, token, "cli")) {
            selection.enable_channel_cli = true;
        } else if (std.mem.eql(u8, token, "telegram")) {
            selection.enable_channel_telegram = true;
        } else if (std.mem.eql(u8, token, "discord")) {
            selection.enable_channel_discord = true;
        } else if (std.mem.eql(u8, token, "slack")) {
            selection.enable_channel_slack = true;
        } else if (std.mem.eql(u8, token, "whatsapp")) {
            selection.enable_channel_whatsapp = true;
        } else if (std.mem.eql(u8, token, "matrix")) {
            selection.enable_channel_matrix = true;
        } else if (std.mem.eql(u8, token, "mattermost")) {
            selection.enable_channel_mattermost = true;
        } else if (std.mem.eql(u8, token, "irc")) {
            selection.enable_channel_irc = true;
        } else if (std.mem.eql(u8, token, "imessage")) {
            selection.enable_channel_imessage = true;
        } else if (std.mem.eql(u8, token, "email")) {
            selection.enable_channel_email = true;
        } else if (std.mem.eql(u8, token, "lark")) {
            selection.enable_channel_lark = true;
        } else if (std.mem.eql(u8, token, "dingtalk")) {
            selection.enable_channel_dingtalk = true;
        } else if (std.mem.eql(u8, token, "line")) {
            selection.enable_channel_line = true;
        } else if (std.mem.eql(u8, token, "onebot")) {
            selection.enable_channel_onebot = true;
        } else if (std.mem.eql(u8, token, "qq")) {
            selection.enable_channel_qq = true;
        } else if (std.mem.eql(u8, token, "maixcam")) {
            selection.enable_channel_maixcam = true;
        } else if (std.mem.eql(u8, token, "signal")) {
            selection.enable_channel_signal = true;
        } else if (std.mem.eql(u8, token, "nostr")) {
            selection.enable_channel_nostr = true;
        } else if (std.mem.eql(u8, token, "nostr_public")) {
            selection.enable_channel_nostr_public = true;
        } else if (std.mem.eql(u8, token, "web")) {
            selection.enable_channel_web = true;
        } else {
            std.log.err("unknown channel '{s}' in -Dchannels list", .{token});
            return error.InvalidChannelsOption;
        }
    }

    if (!saw_token) {
        std.log.err("empty -Dchannels list; use e.g. -Dchannels=all or -Dchannels=telegram,slack", .{});
        return error.InvalidChannelsOption;
    }
    if (saw_all and saw_none) {
        std.log.err("ambiguous -Dchannels list: cannot combine 'all' with 'none'", .{});
        return error.InvalidChannelsOption;
    }

    return selection;
}

const EngineSelection = struct {
    // Base backends
    enable_memory_none: bool = false,
    enable_memory_markdown: bool = false,
    enable_memory_memory: bool = false,
    enable_memory_api: bool = false,

    // Optional backends
    enable_sqlite: bool = false,
    enable_memory_sqlite: bool = false,
    enable_memory_lucid: bool = false,
    enable_memory_redis: bool = false,
    enable_memory_lancedb: bool = false,
    enable_postgres: bool = false,

    fn enableBase(self: *EngineSelection) void {
        self.enable_memory_none = true;
        self.enable_memory_markdown = true;
        self.enable_memory_memory = true;
        self.enable_memory_api = true;
    }

    fn enableAllOptional(self: *EngineSelection) void {
        self.enable_memory_sqlite = true;
        self.enable_memory_lucid = true;
        self.enable_memory_redis = true;
        self.enable_memory_lancedb = true;
        self.enable_postgres = true;
    }

    fn finalize(self: *EngineSelection) void {
        // SQLite runtime is needed by sqlite/lucid/lancedb memory backends.
        self.enable_sqlite = self.enable_memory_sqlite or self.enable_memory_lucid or self.enable_memory_lancedb;
    }

    fn hasAnyBackend(self: EngineSelection) bool {
        return self.enable_memory_none or
            self.enable_memory_markdown or
            self.enable_memory_memory or
            self.enable_memory_api or
            self.enable_memory_sqlite or
            self.enable_memory_lucid or
            self.enable_memory_redis or
            self.enable_memory_lancedb or
            self.enable_postgres;
    }
};

fn defaultEngines() EngineSelection {
    var selection = EngineSelection{};
    // Default binary: practical local setup with file/memory/api plus sqlite.
    selection.enableBase();
    selection.enable_memory_sqlite = true;
    selection.finalize();
    return selection;
}

fn parseEnginesOption(raw: []const u8) !EngineSelection {
    var selection = EngineSelection{};
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        std.log.err("empty -Dengines list; use e.g. -Dengines=base or -Dengines=base,sqlite", .{});
        return error.InvalidEnginesOption;
    }

    var saw_token = false;
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t\r\n");
        if (token.len == 0) continue;
        saw_token = true;

        if (std.mem.eql(u8, token, "base") or std.mem.eql(u8, token, "minimal")) {
            selection.enableBase();
        } else if (std.mem.eql(u8, token, "all")) {
            selection.enableBase();
            selection.enableAllOptional();
        } else if (std.mem.eql(u8, token, "none")) {
            selection.enable_memory_none = true;
        } else if (std.mem.eql(u8, token, "markdown")) {
            selection.enable_memory_markdown = true;
        } else if (std.mem.eql(u8, token, "memory")) {
            selection.enable_memory_memory = true;
        } else if (std.mem.eql(u8, token, "api")) {
            selection.enable_memory_api = true;
        } else if (std.mem.eql(u8, token, "sqlite")) {
            selection.enable_memory_sqlite = true;
        } else if (std.mem.eql(u8, token, "lucid")) {
            selection.enable_memory_lucid = true;
        } else if (std.mem.eql(u8, token, "redis")) {
            selection.enable_memory_redis = true;
        } else if (std.mem.eql(u8, token, "lancedb")) {
            selection.enable_memory_lancedb = true;
        } else if (std.mem.eql(u8, token, "postgres")) {
            selection.enable_postgres = true;
        } else {
            std.log.err("unknown engine '{s}' in -Dengines list", .{token});
            return error.InvalidEnginesOption;
        }
    }

    if (!saw_token) {
        std.log.err("empty -Dengines list; use e.g. -Dengines=base or -Dengines=base,sqlite", .{});
        return error.InvalidEnginesOption;
    }

    selection.finalize();
    if (!selection.hasAnyBackend()) {
        std.log.err("no memory backends selected; choose at least one engine (e.g. base or none)", .{});
        return error.InvalidEnginesOption;
    }

    return selection;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_wasi = target.result.os.tag == .wasi;

    // Get git branch
    const git_branch = b: {
        var out_code: u8 = 0;
        const result = b.runAllowFail(&[_][]const u8{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, &out_code, .ignore) catch {
            break :b "main";
        };
        const trimmed = if (result.len > 0) std.mem.trim(u8, result, "\r\n ") else "main";
        break :b trimmed;
    };

    // Get build timestamp (compact format: YYYYMMDD-HHMM)
    const build_timestamp = b: {
        var out_code: u8 = 0;
        const result = b.runAllowFail(&[_][]const u8{ "date", "-u", "+%Y%m%d-%H%M" }, &out_code, .ignore) catch {
            break :b "unknown";
        };
        const trimmed = if (result.len > 0) std.mem.trim(u8, result, "\r\n ") else "unknown";
        break :b trimmed;
    };

    // Get git commit for build name generation
    const git_commit_for_name = b: {
        var out_code: u8 = 0;
        const result = b.runAllowFail(&[_][]const u8{ "git", "rev-parse", "HEAD" }, &out_code, .ignore) catch {
            break :b "";
        };
        break :b if (result.len > 0) result[0..@min(31, result.len)] else "";
    };

    // Generate random build name
    const build_name = generateBuildName(b, git_commit_for_name);

    // Build version string: nullclaw beta-b-20260308-2030 (crimson-phoenix)
    const app_version = b.fmt("nullclaw {s}-{s} ({s})", .{ git_branch, build_timestamp, build_name });

    // Get git commit hash at build time
    const git_commit = b: {
        var out_code: u8 = 0;
        const result = b.runAllowFail(&[_][]const u8{ "git", "rev-parse", "HEAD" }, &out_code, .ignore) catch "unknown";
        break :b if (result.len > 0) result[0..@min(8, result.len)] else "unknown"; // Short hash
    };
    const channels_raw = b.option(
        []const u8,
        "channels",
        "Channels list. Tokens: all|none|cli|telegram|discord|slack|whatsapp|matrix|mattermost|irc|imessage|email|lark|dingtalk|line|onebot|qq|maixcam|signal|nostr|web (default: all)",
    );
    const channels = if (channels_raw) |raw| blk: {
        const parsed = parseChannelsOption(raw) catch {
            std.process.exit(1);
        };
        break :blk parsed;
    } else defaultChannels();

    const engines_raw = b.option(
        []const u8,
        "engines",
        "Memory engines list. Tokens: base|minimal|all|none|markdown|memory|api|sqlite|lucid|redis|lancedb|postgres (default: base,sqlite)",
    );
    const engines = if (engines_raw) |raw| blk: {
        const parsed = parseEnginesOption(raw) catch {
            std.process.exit(1);
        };
        break :blk parsed;
    } else defaultEngines();

    // Tracy profiler options
    const enable_tracy = b.option(bool, "tracy", "Enable Tracy profiling (default: false)") orelse false;
    const tracy_on_demand = b.option(bool, "tracy_on_demand", "Tracy on-demand mode (connect from GUI instead of broadcast discovery)") orelse false;

    const enable_memory_none = engines.enable_memory_none;
    const enable_memory_markdown = engines.enable_memory_markdown;
    const enable_memory_memory = engines.enable_memory_memory;
    const enable_memory_api = engines.enable_memory_api;
    const enable_sqlite = engines.enable_sqlite;
    const enable_memory_sqlite = engines.enable_memory_sqlite;
    const enable_memory_lucid = engines.enable_memory_lucid;
    const enable_memory_redis = engines.enable_memory_redis;
    const enable_memory_lancedb = engines.enable_memory_lancedb;
    const enable_postgres = engines.enable_postgres;
    const enable_channel_cli = channels.enable_channel_cli;
    const enable_channel_telegram = channels.enable_channel_telegram;
    const enable_channel_discord = channels.enable_channel_discord;
    const enable_channel_slack = channels.enable_channel_slack;
    const enable_channel_whatsapp = channels.enable_channel_whatsapp;
    const enable_channel_matrix = channels.enable_channel_matrix;
    const enable_channel_mattermost = channels.enable_channel_mattermost;
    const enable_channel_irc = channels.enable_channel_irc;
    const enable_channel_imessage = channels.enable_channel_imessage;
    const enable_channel_email = channels.enable_channel_email;
    const enable_channel_lark = channels.enable_channel_lark;
    const enable_channel_dingtalk = channels.enable_channel_dingtalk;
    const enable_channel_line = channels.enable_channel_line;
    const enable_channel_onebot = channels.enable_channel_onebot;
    const enable_channel_qq = channels.enable_channel_qq;
    const enable_channel_maixcam = channels.enable_channel_maixcam;
    const enable_channel_signal = channels.enable_channel_signal;
    const enable_channel_nostr = channels.enable_channel_nostr;
    const enable_channel_nostr_public = channels.enable_channel_nostr_public;
    const enable_channel_web = channels.enable_channel_web;

    const effective_enable_memory_sqlite = enable_sqlite and enable_memory_sqlite;
    const effective_enable_memory_lucid = enable_sqlite and enable_memory_lucid;
    const effective_enable_memory_lancedb = enable_sqlite and enable_memory_lancedb;

    if (enable_sqlite) {
        verifyVendoredSqliteHashes(b) catch {
            std.log.err("vendored sqlite integrity check failed", .{});
            std.process.exit(1);
        };
    }

    const sqlite3 = if (enable_sqlite) blk: {
        const sqlite3_dep = b.dependency("sqlite3", .{
            .target = target,
            .optimize = optimize,
        });
        const sqlite3_artifact = sqlite3_dep.artifact("sqlite3");
        sqlite3_artifact.root_module.addCMacro("SQLITE_ENABLE_FTS5", "1");
        break :blk sqlite3_artifact;
    } else null;

    // Tracy profiler setup
    const tracy_module = if (enable_tracy) blk: {
        const zig_tracy_dep = b.dependency("zig_tracy", .{
            .target = target,
            .optimize = optimize,
            .tracy_enable = true,
            .tracy_on_demand = tracy_on_demand,
        });

        // Get the Tracy module from zig-tracy
        const module = zig_tracy_dep.module("tracy");

        break :blk module;
    } else null;

    var build_options = b.addOptions();
    build_options.addOption([]const u8, "version", app_version);
    build_options.addOption([]const u8, "git_commit", git_commit);
    build_options.addOption([]const u8, "git_branch", git_branch);
    build_options.addOption([]const u8, "build_timestamp", build_timestamp);
    build_options.addOption([]const u8, "spy_dashboard", @embedFile("spy/spy.html"));
    build_options.addOption(bool, "enable_memory_none", enable_memory_none);
    build_options.addOption(bool, "enable_memory_markdown", enable_memory_markdown);
    build_options.addOption(bool, "enable_memory_memory", enable_memory_memory);
    build_options.addOption(bool, "enable_memory_api", enable_memory_api);
    build_options.addOption(bool, "enable_sqlite", enable_sqlite);
    build_options.addOption(bool, "enable_postgres", enable_postgres);
    build_options.addOption(bool, "enable_memory_sqlite", effective_enable_memory_sqlite);
    build_options.addOption(bool, "enable_memory_lucid", effective_enable_memory_lucid);
    build_options.addOption(bool, "enable_memory_redis", enable_memory_redis);
    build_options.addOption(bool, "enable_memory_lancedb", effective_enable_memory_lancedb);
    build_options.addOption(bool, "enable_channel_cli", enable_channel_cli);
    build_options.addOption(bool, "enable_channel_telegram", enable_channel_telegram);
    build_options.addOption(bool, "enable_channel_discord", enable_channel_discord);
    build_options.addOption(bool, "enable_channel_slack", enable_channel_slack);
    build_options.addOption(bool, "enable_channel_whatsapp", enable_channel_whatsapp);
    build_options.addOption(bool, "enable_channel_matrix", enable_channel_matrix);
    build_options.addOption(bool, "enable_channel_mattermost", enable_channel_mattermost);
    build_options.addOption(bool, "enable_channel_irc", enable_channel_irc);
    build_options.addOption(bool, "enable_channel_imessage", enable_channel_imessage);
    build_options.addOption(bool, "enable_channel_email", enable_channel_email);
    build_options.addOption(bool, "enable_channel_lark", enable_channel_lark);
    build_options.addOption(bool, "enable_channel_dingtalk", enable_channel_dingtalk);
    build_options.addOption(bool, "enable_channel_line", enable_channel_line);
    build_options.addOption(bool, "enable_channel_onebot", enable_channel_onebot);
    build_options.addOption(bool, "enable_channel_qq", enable_channel_qq);
    build_options.addOption(bool, "enable_channel_maixcam", enable_channel_maixcam);
    build_options.addOption(bool, "enable_channel_signal", enable_channel_signal);
    build_options.addOption(bool, "enable_channel_nostr", enable_channel_nostr);
    build_options.addOption(bool, "enable_channel_nostr_public", enable_channel_nostr_public);
    build_options.addOption(bool, "enable_channel_web", enable_channel_web);
    build_options.addOption(bool, "enable_tracy", enable_tracy);
    const build_options_module = build_options.createModule();

    // ---------- library module (importable by consumers) ----------
    const lib_mod: ?*std.Build.Module = if (is_wasi) null else blk: {
        const module = b.addModule("nullclaw", .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("build_options", build_options_module);

        // Vendored karlseguin/websocket.zig (client only, patched for 0.16)
        const ws_mod = b.addModule("ws_karlseguin", .{
            .root_source_file = b.path("lib/websocket-zig/src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("ws_karlseguin", ws_mod);

        // Add zquic for QUIC protocol support
        const zquic_dep = b.dependency("zquic", .{
            .target = target,
            .optimize = optimize,
        });
        module.addImport("zquic", zquic_dep.module("zquic"));

        // Add tls.zig for better ECDSA certificate support
        const tls_mod = b.addModule("tls", .{
            .root_source_file = b.path("lib/tls_zig/src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("tls", tls_mod);
        // websocket client needs tls_zig for TLS connections
        ws_mod.addImport("tls", tls_mod);

        // Add Tracy profiler module
        if (tracy_module) |tm| {
            module.addImport("tracy", tm);
        }

        break :blk module;
    };

    // ---------- executable ----------
    const exe_imports: []const std.Build.Module.Import = if (is_wasi)
        &.{}
    else
        &.{.{ .name = "nullclaw", .module = lib_mod.? }};

    const exe = b.addExecutable(.{
        .name = "nullclaw",
        .root_module = b.createModule(.{
            .root_source_file = if (is_wasi) b.path("src/main_wasi.zig") else b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = exe_imports,
        }),
    });
    exe.root_module.addImport("build_options", build_options_module);

    // Link SQLite on the compile step (not the module)
    if (!is_wasi) {
        if (sqlite3) |lib| {
            exe.root_module.linkLibrary(lib);
        }
        if (enable_postgres) {
            exe.root_module.linkSystemLibrary("pq", .{});
        }
        // Link Tracy C++ library
        if (enable_tracy) {
            if (tracy_module) |tm| {
                // Tracy module already links the library, but we need to ensure
                // the module is available to the executable
                _ = tm; // Mark as used
            }
        }
    }
    exe.dead_strip_dylibs = true;

    if (optimize != .Debug) {
        exe.root_module.strip = true;
        exe.root_module.unwind_tables = .none;
        exe.root_module.omit_frame_pointer = true;
    }

    b.installArtifact(exe);

    // macOS host+target only: strip local symbols post-install.
    // Host `strip` cannot process ELF/PE during cross-builds.
    if (optimize != .Debug and builtin.os.tag == .macos and target.result.os.tag == .macos) {
        const strip_cmd = b.addSystemCommand(&.{"strip"});
        strip_cmd.addArgs(&.{"-x"});
        strip_cmd.addFileArg(exe.getEmittedBin());
        strip_cmd.step.dependOn(b.getInstallStep());
        b.default_step = &strip_cmd.step;
    }

    // ---------- run step ----------
    const run_step = b.step("run", "Run nullclaw");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ---------- web_search real test ----------
    if (lib_mod) |mod| {
        const web_search_test_exe = b.addExecutable(.{
            .name = "test_web_search_real",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test_web_search_real.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "nullclaw", .module = mod },
                },
            }),
        });

        const web_search_test_step = b.step("test-web-search-real", "Run real web_search integration test");
        const web_search_test_cmd = b.addRunArtifact(web_search_test_exe);
        web_search_test_step.dependOn(&web_search_test_cmd.step);

        // Hacker News ECDSA test
        const hn_test_exe = b.addExecutable(.{
            .name = "test_hacker_news",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test_hacker_news.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "nullclaw", .module = mod },
                },
            }),
        });

        const hn_test_step = b.step("test-hacker-news", "Run Hacker News ECDSA certificate test");
        const hn_test_cmd = b.addRunArtifact(hn_test_exe);
        hn_test_step.dependOn(&hn_test_cmd.step);

        // Hacker News content quality test
        const hn_content_exe = b.addExecutable(.{
            .name = "test_hacker_news_content",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test_hacker_news_content.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "nullclaw", .module = mod },
                },
            }),
        });

        const hn_content_step = b.step("test-hn-content", "Run Hacker News content extraction test");
        const hn_content_cmd = b.addRunArtifact(hn_content_exe);
        hn_content_step.dependOn(&hn_content_cmd.step);
    }

    // ---------- tests ----------
    const test_step = b.step("test", "Run all tests");

    // Test file filter: run tests only from matching files
    // Usage: zig build test -Dtest-file=file_append (runs tests from file_append.zig)
    //        zig build test -Dtest-file=tools/file_append (runs tests from tools/file_append.zig)
    //        zig build test -Dtest-file=memory (runs tests from any file containing 'memory')
    const test_file_filter = b.option([]const u8, "test-file", "Filter tests by file pattern (substring match)");

    if (!is_wasi) {
        // Build filters array if specified
        const filters: []const []const u8 = if (test_file_filter) |filter| blk: {
            const filters_array = b.allocator.alloc([]const u8, 1) catch @panic("OOM");
            filters_array[0] = filter;
            break :blk filters_array;
        } else &[_][]const u8{};

        const lib_tests = b.addTest(.{
            .root_module = lib_mod.?,
            .filters = filters,
        });
        if (sqlite3) |lib| {
            lib_tests.root_module.linkLibrary(lib);
        }
        if (enable_postgres) {
            lib_tests.root_module.linkSystemLibrary("pq", .{});
        }

        const exe_tests = b.addTest(.{
            .root_module = exe.root_module,
            .filters = filters,
        });

        test_step.dependOn(&b.addRunArtifact(lib_tests).step);
        test_step.dependOn(&b.addRunArtifact(exe_tests).step);

        // ---------- Test Engine Steps ----------

        // Test critical modules only (fast check during development)
        const critical_test_step = b.step("test-critical", "Run critical module tests only (markdown, agent/root, tools/shell, tools/memory)");

        // Test markdown
        const markdown_cmd = b.addSystemCommand(&[_][]const u8{
            b.graph.zig_exe, "build", "test", "-Dtest-file=memory/engines/markdown", "--summary", "all",
        });
        critical_test_step.dependOn(&markdown_cmd.step);

        // Test agent/root
        const agent_cmd = b.addSystemCommand(&[_][]const u8{
            b.graph.zig_exe, "build", "test", "-Dtest-file=agent/root", "--summary", "all",
        });
        critical_test_step.dependOn(&agent_cmd.step);

        // Test tools/shell
        const shell_cmd = b.addSystemCommand(&[_][]const u8{
            b.graph.zig_exe, "build", "test", "-Dtest-file=tools/shell", "--summary", "all",
        });
        critical_test_step.dependOn(&shell_cmd.step);

        // Test tools/memory
        const tools_memory_cmd = b.addSystemCommand(&[_][]const u8{
            b.graph.zig_exe, "build", "test", "-Dtest-file=tools/memory", "--summary", "all",
        });
        critical_test_step.dependOn(&tools_memory_cmd.step);

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

        // Add file-level summary using native build system (no separate executable)
        const summary_header = b.addSystemCommand(&[_][]const u8{
            "echo",
            "\n═══════════════════════════════════════════════════════════════════════════════",
        });
        summary_header.step.name = "Summary Header";

        const summary_title = b.addSystemCommand(&[_][]const u8{
            "echo", "📋 FILE-LEVEL TEST SUMMARY",
        });
        summary_title.step.name = "Summary Title";

        const summary_separator = b.addSystemCommand(&[_][]const u8{
            "echo",
            "═══════════════════════════════════════════════════════════════════════════════",
        });
        summary_separator.step.name = "Summary Separator";

        const summary_note = b.addSystemCommand(&[_][]const u8{
            "echo",
            "💡 Run individual tests: zig build test-discover-<subsystem>",
        });
        summary_note.step.name = "Summary Note";

        const summary_footer = b.addSystemCommand(&[_][]const u8{
            "echo",
            "═══════════════════════════════════════════════════════════════════════════════\n",
        });
        summary_footer.step.name = "Summary Footer";

        // Chain summary commands to run in order
        summary_title.step.dependOn(&summary_header.step);
        summary_separator.step.dependOn(&summary_title.step);
        summary_note.step.dependOn(&summary_separator.step);
        summary_footer.step.dependOn(&summary_note.step);

        // Add summary to auto-discovery (runs after all tests)
        auto_discovery_step.dependOn(&summary_footer.step);

        // ---------- Integration Tests with mock server ----------
        const integration_test_step = b.step("test-integration", "Run integration tests with mock server mock server");

        const integration_test_exe = b.addExecutable(.{
            .name = "nullclaw-integration-tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/integration/runtime_main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "nullclaw", .module = lib_mod.? },
                },
            }),
        });

        if (sqlite3) |lib| {
            integration_test_exe.root_module.linkLibrary(lib);
        }

        const integration_test_run = b.addRunArtifact(integration_test_exe);
        integration_test_step.dependOn(&integration_test_run.step);

        // Tool call test
        const tool_call_test_step = b.step("test-tool-calls", "Run tool calling integration tests");

        const tool_call_test_exe = b.addExecutable(.{
            .name = "nullclaw-tool-call-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/integration/tool_call_test.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "nullclaw", .module = lib_mod.? },
                },
            }),
        });

        if (sqlite3) |lib| {
            tool_call_test_exe.root_module.linkLibrary(lib);
        }

        const tool_call_test_run = b.addRunArtifact(tool_call_test_exe);
        tool_call_test_step.dependOn(&tool_call_test_run.step);

        // Comprehensive integration tests
        const comprehensive_test_step = b.step("test-comprehensive", "Run comprehensive integration tests (requires mock server)");

        const comprehensive_test_exe = b.addExecutable(.{
            .name = "nullclaw-comprehensive-tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/integration/comprehensive_tests.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "nullclaw", .module = lib_mod.? },
                },
            }),
        });

        if (sqlite3) |lib| {
            comprehensive_test_exe.root_module.linkLibrary(lib);
        }

        const comprehensive_test_run = b.addRunArtifact(comprehensive_test_exe);
        comprehensive_test_step.dependOn(&comprehensive_test_run.step);

        // Mock server for testing
        const mock_server_step = b.step("mock-server", "Start mock HTTP server for testing");

        const http_util_mod = b.createModule(.{
            .root_source_file = b.path("src/http_util.zig"),
            .target = target,
            .optimize = optimize,
        });

        const mock_server_exe = b.addExecutable(.{
            .name = "nullclaw-mock-server",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/mock_server.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "http_util", .module = http_util_mod },
                },
            }),
        });

        const mock_server_run = b.addRunArtifact(mock_server_exe);
        mock_server_step.dependOn(&mock_server_run.step);
    }
}

// Generate a fun, memorable build name from git commit hash
fn generateBuildName(b: *std.Build, git_commit: []const u8) []const u8 {
    // Fun adjectives and nouns for build names
    const adjectives = [_][]const u8{
        "crimson", "quantum",  "neon",    "phoenix", "thunder",
        "cobalt",  "ember",    "frost",   "golden",  "hollow",
        "iron",    "jade",     "kinetic", "lunar",   "mystic",
        "nebula",  "obsidian", "prism",   "quartz",  "radiant",
        "shadow",  "titan",    "umbra",   "vivid",   "wicked",
        "azure",   "brisk",    "cosmic",  "drift",   "electric",
    };

    const nouns = [_][]const u8{
        "panda",    "phoenix", "raven",   "tiger",       "vortex",
        "badger",   "bear",    "cougar",  "dragon",      "eagle",
        "fox",      "griffin", "hawk",    "iguana",      "jaguar",
        "koala",    "leopard", "mammoth", "nightingale", "owl",
        "panther",  "quokka",  "raptor",  "shark",       "tiger",
        "urchin",   "viper",   "wolf",    "yak",         "zebra",
        "asteroid", "comet",   "cosmos",  "drift",       "eclipse",
        "flux",     "galaxy",  "horizon", "impact",      "jet",
    };

    // Hash the git commit to get a deterministic index
    var hash: u32 = 5381;
    for (git_commit) |byte| {
        hash = ((hash << 5) +% hash) +% byte;
    }

    // Use hash to pick adjective and noun
    const adj = adjectives[hash % adjectives.len];
    const noun = nouns[(hash / adjectives.len) % nouns.len];

    return b.fmt("{s}-{s}", .{ adj, noun });
}
