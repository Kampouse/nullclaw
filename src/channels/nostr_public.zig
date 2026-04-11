const std = @import("std");
const Allocator = std.mem.Allocator;
const config_types = @import("../config_types.zig");
const bus = @import("../bus.zig");
const secrets = @import("../security/secrets.zig");

const io = std.Options.debug_io;
const log = std.log.scoped(.nostr_public);

/// Nostr public feed channel — listens to public notes and coordination events,
/// routing them into the agent's event bus as primary input context.
///
/// Unlike the nostr channel (DMs only, NIP-17/NIP-04), this handles:
/// - Kind 1: public text notes (mentions, replies)
/// - Kinds 7201, 7203, 7204: agent coordination events (dispatch, result, claim)
///
/// Replies are published as kind 1 public notes with a p-tag for the recipient.
pub const NostrPublicChannel = struct {
    allocator: Allocator,
    config: config_types.NostrPublicConfig,
    /// Decrypted private key for signing. Zeroed before free.
    signing_sec: ?[]u8,
    /// nak req --stream subprocess for listening to relay events.
    listener: ?std.process.Child,
    /// Event bus for publishing inbound messages to the agent.
    event_bus: ?*bus.Bus,
    /// Reader thread that processes incoming events from the listener subprocess.
    reader_thread: ?std.Thread,
    /// Atomic flag to signal the reader thread to stop.
    running: std.atomic.Value(bool),
    /// Recently-seen event IDs for deduplication.
    seen_ids: std.StringHashMapUnmanaged(void),
    /// Whether the channel has been started.
    started: bool,

    pub fn init(allocator: Allocator, config: config_types.NostrPublicConfig) NostrPublicChannel {
        return .{
            .allocator = allocator,
            .config = config,
            .signing_sec = null,
            .listener = null,
            .event_bus = null,
            .reader_thread = null,
            .running = std.atomic.Value(bool).init(false),
            .seen_ids = .empty,
            .started = false,
        };
    }

    pub fn initFromConfig(allocator: Allocator, config: config_types.NostrPublicConfig) NostrPublicChannel {
        return init(allocator, config);
    }

    pub fn deinit(self: *NostrPublicChannel) void {
        self.running.store(false, .release);
        self.stopListener();
        if (self.reader_thread) |t| {
            t.join();
            self.reader_thread = null;
        }

        // Free seen_ids keys.
        var it = self.seen_ids.keyIterator();
        while (it.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.seen_ids.deinit(self.allocator);

        // Zero and free signing credential.
        if (self.signing_sec) |sec| {
            @memset(sec, 0);
            self.allocator.free(sec);
            self.signing_sec = null;
        }
    }

    // ── Constants ──────────────────────────────────────────────────

    const MAX_RELAYS = 10;

    // ── Listener args ──────────────────────────────────────────────

    /// Build listener args at runtime with formatted kind numbers.
    /// Returns a slice of string pointers (no nulls) suitable for std.process.spawn.
    fn buildListenerArgsRuntime(self: *const NostrPublicChannel) Allocator.Error![]const []const u8 {
        // Count: nak + req + --stream + 2 per kind + relays
        const total = 3 + 2 * self.config.listen_kinds.len + self.config.relays.len;
        const args = try self.allocator.alloc([]const u8, total);
        var i: usize = 0;
        args[i] = self.config.nak_path; i += 1;
        args[i] = "req"; i += 1;
        args[i] = "--stream"; i += 1;
        for (self.config.listen_kinds) |kind| {
            const kind_str = try std.fmt.allocPrint(self.allocator, "{d}", .{kind});
            args[i] = "-k"; i += 1;
            args[i] = kind_str; i += 1;
        }
        for (self.config.relays) |relay| {
            args[i] = relay; i += 1;
        }
        return args[0..i];
    }

    /// Build argv for `nak event -k 1 --sec <sec> -t p=<pubkey> -c <content> <relays...>`.
    fn buildSendArgs(
        self: *NostrPublicChannel,
        recipient_pubkey: []const u8,
        content: []const u8,
    ) ![]const []const u8 {
        // nak event -k 1 --sec <sec> -t p=<hex> -c <content> <relays...>
        const sec = self.signing_sec orelse return error.NoSigningKey;
        const total = 3 + 2 + 2 + 2 + self.config.relays.len;
        const args = try self.allocator.alloc([]const u8, total);
        var i: usize = 0;

        args[i] = self.config.nak_path; i += 1;
        args[i] = "event"; i += 1;
        args[i] = "-k"; i += 1;
        args[i] = "1"; i += 1;
        args[i] = "--sec"; i += 1;
        args[i] = sec; i += 1;
        args[i] = "-t"; i += 1;
        const p_tag = try std.fmt.allocPrint(self.allocator, "p={s}", .{recipient_pubkey});
        args[i] = p_tag; i += 1;
        args[i] = "-c"; i += 1;
        args[i] = content; i += 1;
        for (self.config.relays) |relay| {
            args[i] = relay; i += 1;
        }
        return args[0..i];
    }

    // ── Listener lifecycle ─────────────────────────────────────────

    fn stopListener(self: *NostrPublicChannel) void {
        if (self.listener) |*child| {
            child.kill(io);
            _ = child.wait(io) catch {};
            self.listener = null;
        }
    }

    // ── JSON parsing helpers ───────────────────────────────────────

    /// Extract a JSON string value given a prefix like `"key":"`.
    fn extractJsonString(json: []const u8, prefix: []const u8) ?[]const u8 {
        const start_idx = (std.mem.indexOf(u8, json, prefix) orelse return null) + prefix.len;
        var i: usize = start_idx;
        while (i < json.len) {
            if (json[i] == '\\') {
                i += 2;
                continue;
            }
            if (json[i] == '"') {
                return json[start_idx..i];
            }
            i += 1;
        }
        return null;
    }

    /// Extract a JSON integer value given a prefix like `"key":`.
    fn extractJsonInt(json: []const u8, prefix: []const u8) ?i64 {
        const start_idx = (std.mem.indexOf(u8, json, prefix) orelse return null) + prefix.len;
        var i: usize = start_idx;
        while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
        var end: usize = i;
        if (end < json.len and json[end] == '-') end += 1;
        while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
        if (end == i) return null;
        return std.fmt.parseInt(i64, json[i..end], 10) catch null;
    }

    /// Extract event kind from a JSON line.
    fn extractEventKind(json: []const u8) ?u16 {
        const val = extractJsonInt(json, "\"kind\":") orelse return null;
        if (val < 0 or val > 65535) return null;
        return @intCast(val);
    }

    /// Check if the event kind is in the configured listen list.
    fn isKindWanted(self: *const NostrPublicChannel, kind: u16) bool {
        for (self.config.listen_kinds) |k| {
            if (k == kind) return true;
        }
        return false;
    }

    /// Check if the content passes keyword filtering.
    fn passesKeywordFilter(self: *const NostrPublicChannel, content: []const u8) bool {
        if (self.config.keywords.len == 0) return true;
        // Case-insensitive search for any keyword
        const lower_content = toLower(self.allocator, content) catch return true;
        defer self.allocator.free(lower_content);
        for (self.config.keywords) |keyword| {
            const lower_kw = toLower(self.allocator, keyword) catch continue;
            defer self.allocator.free(lower_kw);
            if (std.mem.indexOf(u8, lower_content, lower_kw) != null) return true;
        }
        return false;
    }

    /// Check if the content mentions the configured display name.
    fn passesMentionFilter(self: *const NostrPublicChannel, content: []const u8) bool {
        if (self.config.mention_name.len == 0) return true;
        const lower_content = toLower(self.allocator, content) catch return true;
        defer self.allocator.free(lower_content);
        const lower_name = toLower(self.allocator, self.config.mention_name) catch return true;
        defer self.allocator.free(lower_name);
        return std.mem.indexOf(u8, lower_content, lower_name) != null;
    }

    /// Check if the sender is in the allowed pubkeys list.
    fn passesPubkeyFilter(self: *const NostrPublicChannel, sender: []const u8) bool {
        if (self.config.allowed_pubkeys.len == 0) return true;
        for (self.config.allowed_pubkeys) |pk| {
            if (std.mem.eql(u8, pk, sender)) return true;
        }
        return false;
    }

    /// Case-insensitive lowercase conversion.
    fn toLower(allocator: Allocator, s: []const u8) ![]u8 {
        const result = try allocator.alloc(u8, s.len);
        for (s, 0..) |c, i| {
            result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        return result;
    }

    // ── Session key ────────────────────────────────────────────────

    /// Build session key: "nostr_public:<sender_hex>"
    fn buildSessionKey(sender_hex: []const u8, buf: *[83]u8) []const u8 {
        const prefix = "nostr_public:";
        @memcpy(buf[0..prefix.len], prefix);
        const len = @min(sender_hex.len, 64);
        @memcpy(buf[prefix.len..][0..len], sender_hex[0..len]);
        return buf[0 .. prefix.len + len];
    }

    // ── Reader loop ────────────────────────────────────────────────

    fn readerLoop(self: *NostrPublicChannel) void {
        defer self.running.store(false, .release);
        const stdout_file = if (self.listener) |*l| (l.stdout orelse return) else return;
        const eb = self.event_bus orelse return;

        var buf: [65536]u8 = undefined;
        var filled: usize = 0;
        var reader_buf: [4096]u8 = undefined;
        var reader = stdout_file.reader(io, &reader_buf);

        while (self.running.load(.acquire)) {
            var dest: [1][]u8 = .{buf[filled..]};
            const n = reader.interface.readVec(dest[0..]) catch break;
            if (n == 0) break; // EOF
            filled += n;

            // Process complete lines.
            var start: usize = 0;
            while (std.mem.indexOfPos(u8, buf[0..filled], start, "\n")) |nl| {
                const line = buf[start..nl];
                start = nl + 1;
                if (line.len == 0) continue;
                self.processLine(line, eb);
            }

            // Move remaining partial line to front.
            if (start > 0) {
                const remaining = filled - start;
                std.mem.copyForwards(u8, buf[0..remaining], buf[start..filled]);
                filled = remaining;
            } else if (filled == buf.len) {
                log.warn("nostr_public: discarding oversized line ({d} bytes)", .{filled});
                filled = 0;
            }
        }
    }

    /// Process a single JSON event line from the listener.
    fn processLine(self: *NostrPublicChannel, line: []const u8, eb: *bus.Bus) void {
        // Extract event ID for dedup.
        const event_id = extractJsonString(line, "\"id\":\"") orelse return;
        // Check dedup.
        if (self.seen_ids.contains(event_id)) return;
        // Store the ID (duped so it outlives the line buffer).
        const id_copy = self.allocator.dupe(u8, event_id) catch return;
        self.seen_ids.put(self.allocator, id_copy, {}) catch {
            self.allocator.free(id_copy);
            return;
        };

        // Extract kind and check if we care.
        const kind = extractEventKind(line) orelse return;
        if (!self.isKindWanted(kind)) return;

        // Extract pubkey and content.
        const pubkey = extractJsonString(line, "\"pubkey\":\"") orelse return;
        const content = extractJsonString(line, "\"content\":\"") orelse return;

        // Apply filters.
        if (!self.passesPubkeyFilter(pubkey)) return;
        if (!self.passesKeywordFilter(content)) return;
        if (!self.passesMentionFilter(content)) return;

        // Build sender display name (first 12 hex chars).
        const display_len = @min(pubkey.len, 12);
        const sender_display = pubkey[0..display_len];

        // Build session key.
        var session_buf: [83]u8 = undefined;
        const session_key = buildSessionKey(pubkey, &session_buf);

        // Unescape JSON string escapes in content for display.
        // nak outputs content with JSON escapes — we publish as-is, the agent handles it.

        // Build inbound message and publish to bus.
        const msg = bus.makeInbound(
            self.allocator,
            "nostr_public",
            sender_display,
            pubkey, // chat_id = pubkey (for reply routing)
            content,
            session_key,
        ) catch |err| {
            log.warn("nostr_public: failed to create inbound message: {}", .{err});
            return;
        };

        eb.publishInbound(msg) catch |err| {
            log.warn("nostr_public: failed to publish to bus: {}", .{err});
            msg.deinit(self.allocator);
        };

        log.info("nostr_public: inbound kind {d} from {s}... ({d} chars)", .{
            kind,
            sender_display,
            content.len,
        });
    }

    // ── Channel vtable ─────────────────────────────────────────────

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        const self: *NostrPublicChannel = @ptrCast(@alignCast(ptr));

        // 1. Decrypt signing key.
        if (self.config.private_key.len > 0) {
            const store = secrets.SecretStore.init(self.config.config_dir, true);
            self.signing_sec = try store.decryptSecret(self.allocator, self.config.private_key);
        } else {
            log.warn("nostr_public: no private_key configured — replies will be disabled", .{});
        }
        errdefer {
            if (self.signing_sec) |sec| {
                @memset(sec, 0);
                self.allocator.free(sec);
                self.signing_sec = null;
            }
        }

        // 2. Build listener args and spawn nak req --stream.
        const args = try self.buildListenerArgsRuntime();

        if (args.len < 4) return error.ListenerStartFailed;

        const child = try std.process.spawn(io, .{
            .argv = args,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        self.listener = child;
        errdefer self.stopListener();

        // 3. Spawn reader thread.
        self.running.store(true, .release);
        self.reader_thread = std.Thread.spawn(.{ .stack_size = 128 * 1024 }, readerLoop, .{self}) catch {
            self.running.store(false, .release);
            return error.ReaderThreadFailed;
        };

        self.started = true;
        log.info("nostr_public: started — listening on {d} kinds across {d} relays", .{
            self.config.listen_kinds.len,
            self.config.relays.len,
        });
    }

    fn vtableStop(ptr: *anyopaque) void {
        const self: *NostrPublicChannel = @ptrCast(@alignCast(ptr));

        self.running.store(false, .release);
        self.stopListener();

        if (self.reader_thread) |t| {
            t.join();
            self.reader_thread = null;
        }

        if (self.signing_sec) |sec| {
            @memset(sec, 0);
            self.allocator.free(sec);
            self.signing_sec = null;
        }

        self.started = false;
        log.info("nostr_public: stopped", .{});
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8, media: []const []const u8) anyerror!void {
        _ = media;
        const self: *NostrPublicChannel = @ptrCast(@alignCast(ptr));

        // target is the pubkey (stored as chat_id in inbound messages).
        log.info("nostr_public: sending reply to {s}", .{target[0..@min(target.len, 12)]});

        const args = try self.buildSendArgs(target, message);
        defer self.allocator.free(args);

        var child = std.process.spawn(io, .{
            .argv = args,
            .stdout = .pipe,
            .stderr = .inherit,
        }) catch |err| {
            log.err("nostr_public: nak event spawn failed: {}", .{err});
            return err;
        };
        errdefer {
            child.kill(io);
            _ = child.wait(io) catch {};
        }

        // Read and discard stdout.
        const stdout_file = child.stdout orelse return error.NakCommandFailed;
        var read_buf: [4096]u8 = undefined;
        var reader = stdout_file.reader(io, &read_buf);
        const stdout_data = reader.interface.allocRemaining(self.allocator, .unlimited) catch return error.NakCommandFailed;
        defer self.allocator.free(stdout_data);

        const term = child.wait(io) catch return error.NakCommandFailed;
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    log.warn("nostr_public: nak event exited with {d}", .{code});
                    return error.NakCommandFailed;
                }
            },
            else => return error.NakCommandFailed,
        }

        log.info("nostr_public: reply published ({d} bytes)", .{message.len});
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "nostr_public";
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *NostrPublicChannel = @ptrCast(@alignCast(ptr));
        if (!self.running.load(.acquire)) return false;
        if (self.listener == null) return false;
        return true;
    }

    // ── Bus integration ────────────────────────────────────────────

    /// Set the event bus for publishing inbound messages.
    pub fn setBus(self: *NostrPublicChannel, b: *bus.Bus) void {
        self.event_bus = b;
    }

    /// Wrap as a Channel interface.
    pub fn channel(self: *NostrPublicChannel) root.Channel {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &static_vtable,
        };
    }

    const root = @import("root.zig");

    const static_vtable: root.Channel.VTable = .{
        .start = &vtableStart,
        .stop = &vtableStop,
        .send = &vtableSend,
        .name = &vtableName,
        .healthCheck = &vtableHealthCheck,
    };
};
