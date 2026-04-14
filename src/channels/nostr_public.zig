const std = @import("std");
const Allocator = std.mem.Allocator;
const config_types = @import("../config_types.zig");
const bus = @import("../bus.zig");
const secrets = @import("../security/secrets.zig");
const util = @import("../util.zig");
const nostr = @import("../nostr.zig");

const log = std.log.scoped(.nostr_public);

/// Nostr public feed channel — listens to public notes and coordination events,
/// routing them into the agent's event bus as primary input context.
///
/// Uses native WebSocket relay client (nostr.zig + websocket.zig) instead of
/// shelling out to nak. Supports:
/// - Kind 1: public text notes (mentions, replies)
/// - Kinds 7201, 7203, 7204: agent coordination events (dispatch, result, claim)
///
/// Replies are published as kind 1 public notes with a p-tag for the recipient.
pub const NostrPublicChannel = struct {
    allocator: Allocator,
    config: config_types.NostrPublicConfig,
    /// Raw 32-byte secret key for signing (heap, zeroed before free).
    secret_key_bytes: ?[32]u8,
    /// Derived public key hex (for self-echo filtering).
    own_pubkey_hex: ?[]u8,
    /// Native relay client for listening.
    relay: ?nostr.RelayClient,
    /// Event bus for publishing inbound messages to the agent.
    event_bus: ?*bus.Bus,
    /// Reader thread that processes incoming events from the relay.
    reader_thread: ?std.Thread,
    /// Atomic flag to signal the reader thread to stop.
    running: std.atomic.Value(bool),
    /// Recently-seen event IDs for deduplication.
    seen_ids: std.StringHashMapUnmanaged(void),
    /// Whether the channel has been started.
    started: bool,
    /// Map of sender pubkey -> last inbound event_id, for reply threading (e-tag).
    last_event_ids: std.StringHashMapUnmanaged([]u8),

    pub fn init(allocator: Allocator, config: config_types.NostrPublicConfig) NostrPublicChannel {
        return .{
            .allocator = allocator,
            .config = config,
            .secret_key_bytes = null,
            .own_pubkey_hex = null,
            .relay = null,
            .event_bus = null,
            .reader_thread = null,
            .running = std.atomic.Value(bool).init(false),
            .seen_ids = .empty,
            .started = false,
            .last_event_ids = .empty,
        };
    }

    pub fn initFromConfig(allocator: Allocator, config: config_types.NostrPublicConfig) NostrPublicChannel {
        // Debug: log parsed listen_kinds to catch u16 parsing bugs
        std.log.info("nostr_public: listen_kinds.len={}, kinds={any}", .{
            config.listen_kinds.len,
            config.listen_kinds,
        });
        return init(allocator, config);
    }

    pub fn deinit(self: *NostrPublicChannel) void {
        self.running.store(false, .release);
        // Join reader before closing relay — same race as vtableStop.
        if (self.reader_thread) |t| {
            t.join();
            self.reader_thread = null;
        }
        self.stopRelay();

        // Free seen_ids keys.
        var it = self.seen_ids.keyIterator();
        while (it.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.seen_ids.deinit(self.allocator);

        // Zero and free secret key.
        if (self.secret_key_bytes) |*sk| {
            @memset(sk, 0);
            self.secret_key_bytes = null;
        }

        // Free own pubkey hex.
        if (self.own_pubkey_hex) |pk| {
            self.allocator.free(pk);
            self.own_pubkey_hex = null;
        }

        // Free last_event_ids.
        var it2 = self.last_event_ids.iterator();
        while (it2.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.last_event_ids.deinit(self.allocator);
    }

    // ── Constants ──────────────────────────────────────────────────

    /// Max event IDs to track for dedup before clearing the set.
    /// At ~100 bytes/event, this caps memory at ~1MB.
    const MAX_SEEN_IDS: usize = 10_000;

    // ── Relay lifecycle ────────────────────────────────────────────

    fn stopRelay(self: *NostrPublicChannel) void {
        if (self.relay) |*r| {
            r.deinit();
            self.relay = null;
        }
    }

    // ── JSON parsing helpers ───────────────────────────────────────

    /// Extract a JSON string value given a prefix like `\"key\":\"`.
    fn extractJsonString(json: []const u8, prefix: []const u8) ?[]const u8 {
        const start_idx = (std.mem.indexOf(u8, json, prefix) orelse return null) + prefix.len;
        var i: usize = start_idx;
        while (i < json.len) {
            if (json[i] == '\\') {
                if (i + 1 < json.len) {
                    if (json[i + 1] == 'u' and i + 6 <= json.len) {
                        i += 6;
                    } else {
                        i += 2;
                    }
                } else {
                    i += 1;
                }
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
        const lower_content = toLower(self.allocator, content) catch return true;
        defer self.allocator.free(lower_content);
        for (self.config.keywords) |keyword| {
            const lower_kw = toLower(self.allocator, keyword) catch continue;
            defer self.allocator.free(lower_kw);
            if (std.mem.indexOf(u8, lower_content, lower_kw) != null) return true;
        }
        return false;
    }

    /// Check if the event mentions us. Detects mentions in three standard formats:
    ///   a) Text mention: `name` or `@name` (case-insensitive) in content
    ///   b) NIP-01 p-tag: `"p","<our_hex_pubkey>"` in the event's tags
    ///   c) NIP-19 npub mention: `npub1...` encoding our pubkey in content
    fn passesMentionFilter(self: *NostrPublicChannel, content: []const u8, event_json: []const u8) bool {
        if (self.config.mention_name.len == 0) return true;

        // (b) Check NIP-01 p-tags — if any p-tag matches our pubkey, always accept.
        if (self.own_pubkey_hex) |own_pk| {
            if (hasPTagMatchingPubkey(event_json, own_pk)) {
                log.info("nostr_public: mention matched via p-tag (our pubkey)", .{});
                return true;
            }
        }

        // (a) Text mention: case-insensitive check for `name` or `@name`
        const lower_content = toLower(self.allocator, content) catch return true;
        defer self.allocator.free(lower_content);
        const lower_name = toLower(self.allocator, self.config.mention_name) catch return true;
        defer self.allocator.free(lower_name);
        if (std.mem.indexOf(u8, lower_content, lower_name) != null) {
            return true;
        }
        // Also check @name
        if (std.fmt.allocPrint(self.allocator, "@{s}", .{lower_name})) |at_name| {
            defer self.allocator.free(at_name);
            if (std.mem.indexOf(u8, lower_content, at_name) != null) {
                return true;
            }
        } else |_| {}

        // (c) NIP-19 npub mention: check if our own npub1... prefix appears in content.
        // We build the npub bech32 encoding of our pubkey and check for a prefix match.
        if (self.own_pubkey_hex) |own_pk| {
            if (own_pubkey_npub_prefix(own_pk)) |npub_prefix| {
                if (std.mem.indexOf(u8, content, npub_prefix) != null) {
                    log.info("nostr_public: mention matched via npub prefix in content", .{});
                    return true;
                }
            }
        }

        return false;
    }

    /// Check if any p-tag in the event JSON matches the given pubkey hex.
    /// Scans for `"p","<hex64>"` patterns in the tags array.
    fn hasPTagMatchingPubkey(event_json: []const u8, own_pubkey_hex: []const u8) bool {
        // The tags array in JSON looks like: "tags":[["p","hex..."],["e","hex..."],...]
        // We scan for the pattern "p","<64 hex chars>" after the tags key.
        var search_from: usize = 0;
        while (search_from < event_json.len) {
            const idx = std.mem.indexOfPos(u8, event_json, search_from, "\"p\",\"") orelse return false;
            // Advance past "p","
            const val_start = idx + 5; // len of "\"p\",\""
            if (val_start + own_pubkey_hex.len > event_json.len) return false;
            const val = event_json[val_start .. val_start + own_pubkey_hex.len];
            // The value should end with a quote
            if (val_start + own_pubkey_hex.len < event_json.len and event_json[val_start + own_pubkey_hex.len] == '"') {
                if (std.mem.eql(u8, val, own_pubkey_hex)) return true;
            }
            search_from = val_start;
        }
        return false;
    }

    /// Compute the first ~20 chars of the bech32 npub encoding of a hex pubkey.
    /// Returns a pointer into a static buffer. Npub encoding: bech32 with HRP "npub",
    /// data = 0x00 (version byte) || pubkey_bytes (33 bytes converted from x-only 32 bytes
    /// by prepending 0x02 prefix). We only need enough prefix to uniquely match in content.
    fn own_pubkey_npub_prefix(hex_pubkey: []const u8) ?[]const u8 {
        if (hex_pubkey.len != 64) return null;
        // Decode hex pubkey to bytes
        const pk_bytes = nostr.hexDecodeFixed(32, hex_pubkey) catch return null;
        // Build npub data: 1 version byte (0) + 32 pubkey bytes = 33 bytes
        // Then convert to 5-bit groups and bech32 encode
        // For a prefix match, we just need ~20 chars of the bech32 output
        var data8: [33]u8 = undefined;
        data8[0] = 0x00; // version byte for npub
        @memcpy(data8[1..33], &pk_bytes);
        // Convert 8-bit to 5-bit groups: 33 bytes -> ceil(33*8/5) = 53 five-bit groups
        var data5: [53]u5 = undefined;
        var acc: u32 = 0;
        var bits: u5 = 0;
        var di: usize = 0;
        for (data8) |b| {
            acc = (acc << 8) | b;
            bits += 8;
            while (bits >= 5) {
                bits -= 5;
                data5[di] = @intCast((acc >> bits) & 0x1F);
                di += 1;
            }
        }
        if (bits > 0) {
            data5[di] = @intCast((acc << (5 - bits)) & 0x1F);
            di += 1;
        }
        // Bech32 encode: "npub1" + 53 five-bit chars (no checksum needed for prefix match)
        const bech32_charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
        // Build prefix: "npub1" + first 16 data chars = 21 chars (enough to match in content)
        var buf: [21]u8 = undefined;
        @memcpy(buf[0..5], "npub1");
        for (0..16) |i| {
            buf[5 + i] = bech32_charset[data5[i]];
        }
        return buf[0..21];
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
        defer {
            log.warn("nostr_public: reader loop exiting", .{});
            self.running.store(false, .release);
        }
        const eb = self.event_bus orelse {
            log.warn("nostr_public: reader loop — event_bus is null", .{});
            return;
        };

        log.info("nostr_public: reader loop started — native websocket mode", .{});

        while (self.running.load(.acquire)) {
            // readMessage returns null on close/error.
            const raw = self.relay.?.readMessage() catch |err| {
                log.warn("nostr_public: readMessage error: {}", .{err});
                break;
            } orelse {
                log.info("nostr_public: relay connection closed", .{});
                break;
            };
            defer self.allocator.free(raw);

            // Parse the relay message to check type.
            const msg = nostr.parseRelayMessage(self.allocator, raw) catch {
                log.warn("nostr_public: failed to parse relay message ({d} bytes)", .{raw.len});
                continue;
            };
            defer {
                if (msg.event_json) |ej| self.allocator.free(ej);
                self.allocator.free(msg.raw);
            }

            switch (msg.msg_type) {
                .event => {
                    if (msg.event_json) |event_json| {
                        self.processEvent(event_json, eb);
                    }
                },
                .eose => {
                    log.info("nostr_public: received EOSE — live subscription active", .{});
                },
                .ok => {
                    log.info("nostr_public: received OK: {s}", .{msg.raw[0..@min(msg.raw.len, 120)]});
                },
                .notice => {
                    log.info("nostr_public: received NOTICE: {s}", .{msg.raw[0..@min(msg.raw.len, 200)]});
                },
                .unknown => {
                    // Ignore other relay messages (CLOSED, etc.)
                },
            }
        }

        log.info("nostr_public: reader loop stopped", .{});
    }

    /// Build metadata JSON with full event context (e-tags, p-tags, event_id, kind, full pubkey).
    /// This gives the agent enough context to formulate proper replies with thread references.
    fn buildEventMetadata(self: *NostrPublicChannel, event_json: []const u8, event_id: []const u8, kind: u16, sender_pubkey: []const u8) !?[]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "{\"event_id\":\"");
        try buf.appendSlice(self.allocator, event_id);
        try buf.appendSlice(self.allocator, "\",\"kind\":");
        var int_buf: [20]u8 = undefined;
        const kind_str = std.fmt.bufPrint(&int_buf, "{d}", .{kind}) catch unreachable;
        try buf.appendSlice(self.allocator, kind_str);
        try buf.appendSlice(self.allocator, ",\"sender\":\"");
        try buf.appendSlice(self.allocator, sender_pubkey);
        try buf.appendSlice(self.allocator, "\"");

        // Extract e-tags (reply/thread references)
        var e_tags_found: usize = 0;
        try buf.appendSlice(self.allocator, ",\"reply_to\":[");
        var search_from: usize = 0;
        while (search_from < event_json.len) {
            const idx = std.mem.indexOfPos(u8, event_json, search_from, "\"e\",\"") orelse break;
            const val_start = idx + 5;
            // Find closing quote for the event ID
            const end_quote = std.mem.indexOfScalarPos(u8, event_json, val_start, '"') orelse break;
            const e_id = event_json[val_start..end_quote];
            if (e_id.len > 0) {
                if (e_tags_found > 0) try buf.appendSlice(self.allocator, ",");
                try buf.appendSlice(self.allocator, "\"");
                try buf.appendSlice(self.allocator, e_id);
                try buf.appendSlice(self.allocator, "\"");
                e_tags_found += 1;
            }
            search_from = val_start;
        }
        try buf.appendSlice(self.allocator, "]");

        // Extract p-tags (mentioned pubkeys)
        var p_tags_found: usize = 0;
        try buf.appendSlice(self.allocator, ",\"mentions\":[");
        search_from = 0;
        while (search_from < event_json.len) {
            const idx = std.mem.indexOfPos(u8, event_json, search_from, "\"p\",\"") orelse break;
            const val_start = idx + 5;
            const end_quote = std.mem.indexOfScalarPos(u8, event_json, val_start, '"') orelse break;
            const p_id = event_json[val_start..end_quote];
            if (p_id.len > 0) {
                if (p_tags_found > 0) try buf.appendSlice(self.allocator, ",");
                try buf.appendSlice(self.allocator, "\"");
                try buf.appendSlice(self.allocator, p_id);
                try buf.appendSlice(self.allocator, "\"");
                p_tags_found += 1;
            }
            search_from = val_start;
        }
        try buf.appendSlice(self.allocator, "]}");

        const slice = try buf.toOwnedSlice(self.allocator);
        return slice;
    }

    /// Process a single event JSON from the relay.
    fn processEvent(self: *NostrPublicChannel, event_json: []const u8, eb: *bus.Bus) void {
        // Extract event ID for dedup.
        const event_id = extractJsonString(event_json, "\"id\":\"") orelse {
            log.info("nostr_public: event has no id, skipping ({d} bytes)", .{event_json.len});
            return;
        };
        // Check dedup.
        if (self.seen_ids.contains(event_id)) {
            log.info("nostr_public: dedup skip event {s}...", .{event_id[0..@min(event_id.len, 12)]});
            return;
        }
        // Store the ID (duped so it outlives the line buffer).
        const id_copy = self.allocator.dupe(u8, event_id) catch return;
        self.seen_ids.put(self.allocator, id_copy, {}) catch {
            self.allocator.free(id_copy);
            return;
        };
        // Evict oldest entries when set grows too large.
        if (self.seen_ids.count() > MAX_SEEN_IDS) {
            log.info("nostr_public: seen_ids hit {d} cap, clearing", .{self.seen_ids.count()});
            var it = self.seen_ids.keyIterator();
            while (it.next()) |key_ptr| {
                self.allocator.free(key_ptr.*);
            }
            self.seen_ids.deinit(self.allocator);
            self.seen_ids = .empty;
        }

        // Extract kind and check if we care.
        const kind = extractEventKind(event_json) orelse {
            log.info("nostr_public: event {s}... has no kind, skipping", .{event_id[0..@min(event_id.len, 12)]});
            return;
        };
        if (!self.isKindWanted(kind)) {
            log.info("nostr_public: event {s}... kind {d} not in listen list, skipping", .{ event_id[0..@min(event_id.len, 12)], kind });
            return;
        }

        // Extract pubkey and content.
        const pubkey = extractJsonString(event_json, "\"pubkey\":\"") orelse {
            log.info("nostr_public: event {s}... kind {d} has no pubkey, skipping", .{ event_id[0..@min(event_id.len, 12)], kind });
            return;
        };
        const content = extractJsonString(event_json, "\"content\":\"") orelse {
            log.info("nostr_public: event {s}... kind {d} from {s}... has no content, skipping", .{ event_id[0..@min(event_id.len, 12)], kind, pubkey[0..@min(pubkey.len, 12)] });
            return;
        };

        log.info("nostr_public: event {s}... kind {d} from {s}... content={d} chars", .{
            event_id[0..@min(event_id.len, 12)],
            kind,
            pubkey[0..@min(pubkey.len, 12)],
            content.len,
        });

        // Filter out own events to prevent self-echo loops.
        if (self.own_pubkey_hex) |own_pk| {
            if (std.mem.eql(u8, own_pk, pubkey)) {
                log.info("nostr_public: DROP self-echo — own event {s}...", .{event_id[0..@min(event_id.len, 12)]});
                return;
            }
        }

        // Apply filters.
        if (!self.passesPubkeyFilter(pubkey)) {
            log.info("nostr_public: DROP pubkey filter — {s}... not in allowed_pubkeys", .{pubkey[0..@min(pubkey.len, 12)]});
            return;
        }
        if (!self.passesKeywordFilter(content)) {
            log.info("nostr_public: DROP keyword filter — content: {s}", .{content[0..@min(content.len, 80)]});
            return;
        }
        if (!self.passesMentionFilter(content, event_json)) {
            log.info("nostr_public: DROP mention filter — '{s}' not found in content/tags", .{self.config.mention_name});
            return;
        }

        // Build sender display name (first 12 hex chars).
        const display_len = @min(pubkey.len, 12);
        const sender_display = pubkey[0..display_len];

        // Build session key.
        var session_buf: [83]u8 = undefined;
        const session_key = buildSessionKey(pubkey, &session_buf);

        // Build metadata JSON with full event context for the agent.
        const metadata_json: ?[]u8 = if (self.buildEventMetadata(event_json, event_id, kind, pubkey)) |md|
            md
        else |err| blk: {
            log.warn("nostr_public: failed to build event metadata: {}", .{err});
            break :blk null;
        };

        // Build inbound message and publish to bus.
        const msg = bus.makeInboundFull(
            self.allocator,
            "nostr_public",
            sender_display,
            pubkey, // chat_id = pubkey (for reply routing)
            content,
            session_key,
            &[_][]const u8{}, // no media
            metadata_json,
        ) catch |err| {
            log.warn("nostr_public: failed to create inbound message: {}", .{err});
            if (metadata_json) |md| self.allocator.free(md);
            return;
        };

        // Store event_id for reply threading (e-tag). Replace any previous entry.
        const event_id_copy = self.allocator.dupe(u8, event_id) catch return;
        const pubkey_copy = self.allocator.dupe(u8, pubkey) catch {
            self.allocator.free(event_id_copy);
            return;
        };
        if (self.last_event_ids.getPtr(pubkey_copy)) |existing| {
            self.allocator.free(existing.*);
            existing.* = event_id_copy;
            self.allocator.free(pubkey_copy); // key already exists
        } else {
            self.last_event_ids.put(self.allocator, pubkey_copy, event_id_copy) catch {
                self.allocator.free(event_id_copy);
                self.allocator.free(pubkey_copy);
            };
        }

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

    // ── Key management ────────────────────────────────────────────

    /// Load nostr secret key from .nostr_key file, or auto-generate a new one.
    /// Priority: .nostr_key file exists and is readable → load it; otherwise → generate, save, return.
    /// Returns the 32-byte secret key.
    fn loadOrGenerateKey(allocator: Allocator, config_dir: []const u8) ![32]u8 {
        const store = secrets.SecretStore.init(config_dir, true);
        const io = std.Options.debug_io;

        // Build path: config_dir/.nostr_key
        var key_file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const key_file_name = "/.nostr_key";
        const path_total = @min(config_dir.len + key_file_name.len, key_file_path_buf.len);
        @memcpy(key_file_path_buf[0..config_dir.len], config_dir);
        @memcpy(key_file_path_buf[config_dir.len..][0..key_file_name.len], key_file_name);
        const key_file_path = key_file_path_buf[0..path_total];

        // Try reading existing .nostr_key file
        const file = std.Io.Dir.cwd().openFile(io, key_file_path, .{}) catch |err| {
            if (err != error.FileNotFound) {
                log.warn("nostr_public: error reading .nostr_key: {}", .{err});
            }
            // File doesn't exist (or unreadable) — generate a new key
            return generateAndSaveKey(allocator, store, key_file_path);
        };
        defer file.close(io);

        // Read file content via reader
        var buf: [512]u8 = undefined;
        var reader = file.reader(io, &buf);
        const content = reader.interface.readAlloc(allocator, 512) catch |err| {
            log.warn("nostr_public: error reading .nostr_key content: {}", .{err});
            return generateAndSaveKey(allocator, store, key_file_path);
        };
        defer allocator.free(content);

        // Trim whitespace/newlines
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (trimmed.len == 0) {
            return generateAndSaveKey(allocator, store, key_file_path);
        }

        // Decrypt the stored key
        const decrypted = store.decryptSecret(allocator, trimmed) catch |err| {
            log.warn("nostr_public: failed to decrypt .nostr_key: {} — regenerating", .{err});
            return generateAndSaveKey(allocator, store, key_file_path);
        };
        defer allocator.free(decrypted);

        const sk_bytes = nostr.hexDecodeFixed(32, decrypted) catch |err| {
            log.warn("nostr_public: invalid hex in .nostr_key: {} — regenerating", .{err});
            return generateAndSaveKey(allocator, store, key_file_path);
        };

        // Validate key is usable
        const kp = nostr.keyPairFromSecret(sk_bytes) catch |err| {
            log.warn("nostr_public: invalid key in .nostr_key: {} — regenerating", .{err});
            return generateAndSaveKey(allocator, store, key_file_path);
        };
        const pk_hex = nostr.hexEncode32(kp.public_key);
        log.info("nostr_public: loaded key from .nostr_key — pubkey: {s}...", .{pk_hex[0..16]});

        return sk_bytes;
    }

    /// Generate a fresh nostr keypair, encrypt it, and save to .nostr_key file.
    fn generateAndSaveKey(allocator: Allocator, store: secrets.SecretStore, key_file_path: []const u8) ![32]u8 {
        const io = std.Options.debug_io;

        // Generate random 32-byte secret (retry if invalid scalar)
        var sk_bytes: [32]u8 = undefined;
        var kp: nostr.KeyPair = undefined;
        var attempts: u8 = 0;
        while (attempts < 5) : (attempts += 1) {
            util.randomBytes(&sk_bytes);
            if (nostr.keyPairFromSecret(sk_bytes)) |ok| {
                kp = ok;
                break;
            } else |_| {
                continue;
            }
        } else {
            return error.KeyGenerationFailed;
        }

        const pk_hex = nostr.hexEncode32(kp.public_key);
        const sk_hex = nostr.hexEncode32(sk_bytes);

        // Encrypt the hex secret and write to .nostr_key
        const encrypted = store.encryptSecret(allocator, &sk_hex) catch |err| {
            log.err("nostr_public: failed to encrypt generated key: {}", .{err});
            // Fall back to writing raw hex (less secure but functional)
            return sk_bytes;
        };
        defer allocator.free(encrypted);

        // Write to file
        const file = std.Io.Dir.cwd().createFile(io, key_file_path, .{}) catch |err| {
            log.warn("nostr_public: failed to write .nostr_key: {} — key will not persist across restarts", .{err});
            return sk_bytes;
        };
        defer file.close(io);
        if (@import("builtin").os.tag != .windows) {
            file.setPermissions(io, @enumFromInt(0o600)) catch {};
        }
        file.writeStreamingAll(io, encrypted) catch |err| {
            log.warn("nostr_public: failed to write .nostr_key content: {} — key will not persist across restarts", .{err});
        };

        log.info("nostr_public: AUTO-GENERATED new nostr keypair", .{});
        log.info("nostr_public:   pubkey (hex): {s}", .{&pk_hex});
        log.info("nostr_public:   saved to: {s}", .{key_file_path});

        return sk_bytes;
    }

    // ── Channel vtable ─────────────────────────────────────────────

    /// Check if the .nostr_key file exists at config_dir/.nostr_key.
    fn nostrKeyFileExists(config_dir: []const u8) bool {
        var key_file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const key_file_name = "/.nostr_key";
        const path_total = @min(config_dir.len + key_file_name.len, key_file_path_buf.len);
        @memcpy(key_file_path_buf[0..config_dir.len], config_dir);
        @memcpy(key_file_path_buf[config_dir.len..][0..key_file_name.len], key_file_name);
        const key_file_path = key_file_path_buf[0..path_total];
        const io = std.Options.debug_io;
        const file = std.Io.Dir.cwd().openFile(io, key_file_path, .{}) catch return false;
        file.close(io);
        return true;
    }

    /// Migrate an existing secret key (from config) to the encrypted .nostr_key file.
    /// This encrypts the key and writes it so future starts use the encrypted file.
    fn migrateKeyToNostrKeyFile(self: *NostrPublicChannel) !void {
        const sk = self.secret_key_bytes orelse return;
        const store = secrets.SecretStore.init(self.config.config_dir, true);
        const sk_hex = nostr.hexEncode32(sk);
        const io = std.Options.debug_io;

        // Encrypt the hex secret
        const encrypted = store.encryptSecret(self.allocator, &sk_hex) catch |err| {
            log.warn("nostr_public: migration encrypt failed: {}", .{err});
            return err;
        };
        defer self.allocator.free(encrypted);

        // Build path
        var key_file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const key_file_name = "/.nostr_key";
        const path_total = @min(self.config.config_dir.len + key_file_name.len, key_file_path_buf.len);
        @memcpy(key_file_path_buf[0..self.config.config_dir.len], self.config.config_dir);
        @memcpy(key_file_path_buf[self.config.config_dir.len..][0..key_file_name.len], key_file_name);
        const key_file_path = key_file_path_buf[0..path_total];

        // Write to file
        const file = std.Io.Dir.cwd().createFile(io, key_file_path, .{}) catch |err| {
            log.warn("nostr_public: migration write failed: {}", .{err});
            return err;
        };
        defer file.close(io);
        if (@import("builtin").os.tag != .windows) {
            file.setPermissions(io, @enumFromInt(0o600)) catch {};
        }
        file.writeStreamingAll(io, encrypted) catch |err| {
            log.warn("nostr_public: migration write content failed: {}", .{err});
            return err;
        };

        log.info("nostr_public: migrated key from config to encrypted .nostr_key file", .{});
    }

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        const self: *NostrPublicChannel = @ptrCast(@alignCast(ptr));

        // 1. Load secret key.
        // Priority: .nostr_key file (encrypted) > config private_key (with migration) > auto-generate.
        if (self.secret_key_bytes == null) {
            // Check if .nostr_key file exists first (encrypted, secure).
            const nostr_key_exists = nostrKeyFileExists(self.config.config_dir);
            if (nostr_key_exists) {
                log.info("nostr_public: loading key from encrypted .nostr_key file", .{});
                self.secret_key_bytes = loadOrGenerateKey(self.allocator, self.config.config_dir) catch |err| {
                    log.err("nostr_public: failed to load .nostr_key: {}", .{err});
                    return err;
                };
            } else if (self.config.private_key.len > 0) {
                // No .nostr_key file but config has private_key — load from config.
                log.info("nostr_public: loading key from config (plaintext), will migrate to .nostr_key", .{});
                const store = secrets.SecretStore.init(self.config.config_dir, true);
                // Try hex decode first (raw 32-byte hex key without enc2: prefix).
                if (self.config.private_key.len == 64) {
                    // Raw hex secret key (no encryption).
                    if (nostr.hexDecodeFixed(32, self.config.private_key)) |sk_bytes| {
                        self.secret_key_bytes = sk_bytes;
                    } else |_| {
                        log.warn("nostr_public: private_key is 64 chars but not valid hex, trying encrypted...", .{});
                        // Try encrypted.
                        const sec_str = try store.decryptSecret(self.allocator, self.config.private_key);
                        defer self.allocator.free(sec_str);
                        self.secret_key_bytes = nostr.hexDecodeFixed(32, sec_str) catch
                            return error.InvalidSecretKey;
                    }
                } else {
                    // Encrypted key (enc2:...).
                    const sec_str = try store.decryptSecret(self.allocator, self.config.private_key);
                    defer self.allocator.free(sec_str);
                    self.secret_key_bytes = nostr.hexDecodeFixed(32, sec_str) catch
                        return error.InvalidSecretKey;
                }
                // Migrate: save the loaded key to .nostr_key for future encrypted use.
                self.migrateKeyToNostrKeyFile() catch |err| {
                    log.warn("nostr_public: failed to migrate key to .nostr_key: {} — continuing with config key", .{err});
                };
            } else {
                // Neither .nostr_key nor config key — auto-generate.
                self.secret_key_bytes = try loadOrGenerateKey(self.allocator, self.config.config_dir);
            }
        }

        // 2. Derive own pubkey for self-echo filtering.
        if (self.secret_key_bytes) |sk| {
            if (nostr.keyPairFromSecret(sk)) |kp| {
                const pk_hex = nostr.hexEncode32(kp.public_key);
                self.own_pubkey_hex = self.allocator.dupe(u8, &pk_hex) catch return error.OutOfMemory;
                log.info("nostr_public: own pubkey derived: {s}... (self-echo filter active)", .{self.own_pubkey_hex.?[0..12]});
            } else |err| {
                log.warn("nostr_public: failed to derive keypair: {} — self-echo filter disabled", .{err});
            }
        }

        // 3. Connect to relay via native WebSocket.
        if (self.config.relays.len == 0) return error.NoRelays;

        const relay_url = self.config.relays[0];
        log.info("nostr_public: connecting to relay {s}...", .{relay_url});
        const relay = nostr.RelayClient.connect(self.allocator, relay_url) catch |err| {
            log.err("nostr_public: relay connect failed: {}", .{err});
            return err;
        };
        self.relay = relay;
        errdefer self.stopRelay();

        // 4. Subscribe with filter for configured kinds.
        const filter = try nostr.buildFilter(self.allocator, .{
            .kinds = self.config.listen_kinds,
            .since = util.timestampUnix(),
        });
        defer self.allocator.free(filter);

        _ = self.relay.?.subscribe(filter) catch |err| {
            log.err("nostr_public: subscribe failed: {}", .{err});
            return err;
        };
        log.info("nostr_public: subscribed to {d} kinds on {s}", .{
            self.config.listen_kinds.len,
            relay_url,
        });

        // 5. Spawn reader thread.
        self.running.store(true, .release);
        self.reader_thread = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, readerLoop, .{self}) catch {
            self.running.store(false, .release);
            return error.ReaderThreadFailed;
        };

        self.started = true;
        log.info("nostr_public: started — native websocket, listening on {d} kinds across {d} relays", .{
            self.config.listen_kinds.len,
            self.config.relays.len,
        });
    }

    fn vtableStop(ptr: *anyopaque) void {
        const self: *NostrPublicChannel = @ptrCast(@alignCast(ptr));

        // Signal reader thread to stop FIRST.
        self.running.store(false, .release);

        // Join reader thread BEFORE closing the relay — the reader may still
        // be mid-read on the TLS stream. Closing the fd under it corrupts
        // the global Io's TLS state and causes a segfault on next connect.
        if (self.reader_thread) |t| {
            t.join();
            self.reader_thread = null;
        }

        // Now safe to close relay (no need to unsubscribe — if we're here
        // the reader loop already exited due to disconnect or stop signal).
        self.stopRelay();
        self.started = false;
        log.info("nostr_public: stopped", .{});
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8, media: []const []const u8) anyerror!void {
        _ = media;
        const self: *NostrPublicChannel = @ptrCast(@alignCast(ptr));

        log.info("nostr_public: sending reply to {s} ({d} chars)", .{ target[0..@min(target.len, 12)], message.len });

        // Pre-flight checks.
        const sk = self.secret_key_bytes orelse {
            log.err("nostr_public: cannot send - no secret key", .{});
            return error.NoSigningKey;
        };
        if (self.config.relays.len == 0) {
            log.err("nostr_public: cannot send - no relays configured", .{});
            return error.NoRelays;
        }

        // Build tags: p-tag for recipient, e-tag for threading.
        var tags_buf: [4]nostr.Tag = undefined;
        var tags_len: usize = 0;

        // p-tag
        tags_buf[tags_len] = try nostr.pTag(self.allocator, target);
        tags_len += 1;

        // e-tag for threading if we have the original event ID.
        if (self.last_event_ids.get(target)) |event_id| {
            tags_buf[tags_len] = try nostr.eTag(self.allocator, event_id);
            tags_len += 1;
        }

        const tags = tags_buf[0..tags_len];

        // Build and sign the event.
        const kp = try nostr.keyPairFromSecret(sk);
        const now = util.timestampUnix();

        var event: nostr.Event = .{
            .id = [_]u8{0} ** 32,
            .pubkey = kp.public_key,
            .created_at = now,
            .kind = 1,
            .tags = tags,
            .content = message,
            .sig = [_]u8{0} ** 64,
        };
        try nostr.signEvent(&event, sk, self.allocator);

        const event_json = try nostr.eventToJson(event, self.allocator);
        defer self.allocator.free(event_json);

        log.info("nostr_public: publishing kind 1 event to {s} ({d} bytes)", .{
            self.config.relays[0],
            event_json.len,
        });

        // Connect, publish, disconnect (one-shot per send).
        // TODO: keep a persistent relay for publishing too.
        var pub_relay = nostr.RelayClient.connect(self.allocator, self.config.relays[0]) catch |err| {
            log.err("nostr_public: publish relay connect failed: {}", .{err});
            return err;
        };
        defer pub_relay.deinit();

        const response = pub_relay.publish(event_json) catch |err| {
            log.err("nostr_public: publish failed: {}", .{err});
            return err;
        };
        defer self.allocator.free(response);

        log.info("nostr_public: reply published — relay response: {s}", .{
            response[0..@min(response.len, 120)],
        });
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "nostr_public";
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *NostrPublicChannel = @ptrCast(@alignCast(ptr));
        if (!self.running.load(.acquire)) return false;
        if (self.relay == null) return false;
        return true;
    }

    // ── NIP-50 search ──────────────────────────────────────────────

    /// Search result: a single matching event from the relay.
    pub const SearchResult = struct {
        /// Event ID (hex).
        id: []u8,
        /// Author pubkey (hex).
        pubkey: []u8,
        /// Event kind.
        kind: u16,
        /// Created_at unix timestamp.
        created_at: i64,
        /// Event content (heap-allocated).
        content: []u8,
    };

    /// Perform a NIP-50 full-text search on the configured relay.
    /// Opens a one-shot connection, sends a REQ with the search filter,
    /// collects events until EOSE, then closes.
    ///
    /// Returns a slice of SearchResult. Caller owns the returned slice and
    /// each SearchResult's fields (all heap-allocated).
    pub fn searchNostr(self: *NostrPublicChannel, query: []const u8, limit: u32) ![]SearchResult {
        if (self.config.relays.len == 0) return error.NoRelays;

        const relay_url = self.config.relays[0];
        log.info("nostr_public: NIP-50 search for \"{s}\" on {s} (limit={d})", .{ query, relay_url, limit });

        // Connect.
        var client = nostr.RelayClient.connect(self.allocator, relay_url, null) catch |err| {
            log.err("nostr_public: search relay connect failed: {}", .{err});
            return err;
        };
        defer client.deinit();

        // Build NIP-50 search filter.
        const filter = try nostr.buildFilter(self.allocator, .{
            .kinds = self.config.listen_kinds,
            .search = query,
            .limit = limit,
        });
        defer self.allocator.free(filter);

        // Subscribe (sends REQ with hardcoded "sub" sub_id).
        _ = client.subscribe(filter) catch |err| {
            log.err("nostr_public: search subscribe failed: {}", .{err});
            return err;
        };

        // Collect events until EOSE or timeout.
        var results = std.ArrayListUnmanaged(SearchResult).empty;
        const deadline = std.time.nanoTimestamp() + 10 * std.time.ns_per_s; // 10s timeout

        while (std.time.nanoTimestamp() < deadline) {
            const raw = client.readMessage() catch |err| {
                log.warn("nostr_public: search readMessage error: {}", .{err});
                break;
            } orelse {
                log.info("nostr_public: search relay closed", .{});
                break;
            };
            defer self.allocator.free(raw);

            const msg = nostr.parseRelayMessage(self.allocator, raw) catch continue;
            defer {
                if (msg.event_json) |ej| self.allocator.free(ej);
                self.allocator.free(msg.raw);
            }

            switch (msg.msg_type) {
                .eose => {
                    log.info("nostr_public: search EOSE received", .{});
                    break;
                },
                .event => {
                    if (msg.event_json) |event_json| {
                        const result = parseSearchResult(self.allocator, event_json) catch |err| {
                            log.warn("nostr_public: search result parse failed: {}", .{err});
                            continue;
                        };
                        try results.append(self.allocator, result);
                    }
                },
                else => {},
            }
        }

        // Unsubscribe and close.
        client.unsubscribe("sub");

        log.info("nostr_public: search returned {d} results", .{results.items.len});
        return results.toOwnedSlice(self.allocator);
    }

    /// Parse a relay event JSON into a SearchResult.
    fn parseSearchResult(allocator: Allocator, event_json: []const u8) !SearchResult {
        const id = extractJsonString(event_json, "\"id\":\"") orelse return error.MissingEventId;
        const pubkey = extractJsonString(event_json, "\"pubkey\":\"") orelse return error.MissingPubkey;
        const content = extractJsonString(event_json, "\"content\":\"") orelse return error.MissingContent;
        const kind = extractEventKind(event_json) orelse 1;
        const created_at = extractJsonInt(event_json, "\"created_at\":") orelse 0;

        return .{
            .id = try allocator.dupe(u8, id),
            .pubkey = try allocator.dupe(u8, pubkey),
            .kind = kind,
            .created_at = created_at,
            .content = try allocator.dupe(u8, content),
        };
    }

    /// Free a slice of SearchResult.
    pub fn freeSearchResults(self: *NostrPublicChannel, results: []SearchResult) void {
        for (results) |*r| {
            self.allocator.free(r.id);
            self.allocator.free(r.pubkey);
            self.allocator.free(r.content);
        }
        self.allocator.free(results);
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
