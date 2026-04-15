// Nostr Email Tool — send and receive sealed emails via NIP-59 Gift Wrap.
//
// Actions:
//   send     — Send a sealed email (kind 1301) wrapped in NIP-59 gift wrap
//   receive  — Subscribe to relays for kind 1059, unwrap, return emails
//
// Email format (kind 1301 rumor):
//   content: "Subject: ...\r\nFrom: ...\r\nTo: ...\r\n\r\n<Body>"
//   tags:    ["p", "<recipient_pubkey>"]
//
// Uses NIP-44 v2 encryption + NIP-59 gift wrapping for end-to-end privacy.
// The recipient's pubkey is resolved via NIP-05 (_nostraddr TXT record).

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const nostr = @import("../nostr.zig");
const nip44 = @import("../security/nip44.zig");
const nip59 = @import("../security/nip59.zig");
const util = @import("../util.zig");

const log = std.log.scoped(.nostr_email);

/// Kind 1301 = Email event (proposed).
const KIND_EMAIL: u16 = 1301;

const DEFAULT_RELAYS = [_][]const u8{
    "wss://relay.ditto.pub",
    "wss://nos.lol",
    "wss://relay.nostr.net",
    "wss://relay.crostr.com",
    "wss://relay.gulugulu.moe",
};

pub const NostrEmailTool = struct {
    config_dir: []const u8,
    allocator: std.mem.Allocator,

    pub const tool_name = "nostr_email";
    pub const tool_description = "Send and receive sealed emails via Nostr NIP-59 Gift Wrap. Actions: send (encrypt + wrap a kind 1301 email rumor, publish to relays), receive (subscribe to kind 1059, unwrap, return emails). The recipient can be a Nostr hex pubkey or a NIP-05 address (user@domain) which is resolved via DNS. All emails are end-to-end encrypted using NIP-44 v2.";
    pub const tool_params =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["send","receive"],"description":"Action to perform"},"to":{"type":"string","description":"Recipient: hex pubkey (64 chars) or NIP-05 address (user@domain)"},"subject":{"type":"string","description":"Email subject line"},"body":{"type":"string","description":"Email body text"},"reply_to":{"type":"string","description":"Event ID of the email being replied to (adds #e tag)"},"private_key":{"type":"string","description":"Hex private key (default from config)"},"relays":{"type":"array","items":{"type":"string"},"description":"Relay URLs (default: well-known relays)"},"limit":{"type":"integer","description":"For receive: max emails to return (default 20)"}}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *NostrEmailTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *NostrEmailTool, allocator: std.mem.Allocator, args: JsonObjectMap, io: std.Io) !ToolResult {
        const action = root.getString(args, "action") orelse
            return ToolResult.fail("Missing 'action'. Use: send, receive.");

        // Load private key
        const sk_hex = root.getString(args, "private_key");
        var sk_buf: [32]u8 = undefined;
        const has_sk = if (sk_hex) |hex| blk: {
            sk_buf = nostr.hexDecodeFixed(32, hex) catch
                return ToolResult.fail("Invalid private_key hex (must be 64 hex chars)");
            break :blk true;
        } else blk: {
            const loaded = self.loadPrivateKey(allocator, io) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "Failed to load private key: {}", .{err}) catch
                    "Failed to load private key";
                return ToolResult.failAlloc(allocator, msg);
            };
            if (loaded) |key| {
                sk_buf = key;
                break :blk true;
            }
            break :blk false;
        };

        // Load relays
        var relay_urls: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (relay_urls.items) |r| allocator.free(r);
            relay_urls.deinit(allocator);
        }
        if (root.getValue(args, "relays")) |rv| {
            if (rv == .array) {
                for (rv.array.items) |item| {
                    if (item == .string) {
                        try relay_urls.append(allocator, try allocator.dupe(u8, item.string));
                    }
                }
            }
        }
        if (relay_urls.items.len == 0) {
            const config_relays = self.loadRelays(allocator, io) catch &.{};
            for (config_relays) |r| {
                try relay_urls.append(allocator, r);
            }
        }
        if (relay_urls.items.len == 0) {
            for (&DEFAULT_RELAYS) |r| {
                try relay_urls.append(allocator, try allocator.dupe(u8, r));
            }
        }

        if (std.mem.eql(u8, action, "send")) {
            if (!has_sk) return ToolResult.fail("Private key required for sending. Provide 'private_key' or configure channels.nostr_public.private_key.");
            return self.actionSend(allocator, sk_buf, relay_urls.items, args, io);
        } else if (std.mem.eql(u8, action, "receive")) {
            if (!has_sk) return ToolResult.fail("Private key required for receiving (needed to decrypt gift wraps).");
            return self.actionReceive(allocator, sk_buf, relay_urls.items, args, io);
        } else {
            return ToolResult.fail("Unknown action. Use: send, receive.");
        }
    }

    // ── Send ──────────────────────────────────────────────────────

    fn actionSend(_: *NostrEmailTool, allocator: std.mem.Allocator, sk: [32]u8, relays: []const []const u8, args: JsonObjectMap, io: std.Io) !ToolResult {
        const to = root.getString(args, "to") orelse
            return ToolResult.fail("Missing 'to' — recipient pubkey (hex) or NIP-05 address.");
        const subject = root.getString(args, "subject") orelse "(no subject)";
        const body = root.getString(args, "body") orelse "";
        const reply_to = root.getString(args, "reply_to");

        const kp = nostr.keyPairFromSecret(sk) catch
            return ToolResult.fail("Invalid private key.");

        // Resolve recipient pubkey
        const recipient_pub = if (to.len == 64 and isHexString(to))
            nostr.hexDecodeFixed(32, to) catch
                return ToolResult.fail("Invalid hex pubkey.")
        else if (std.mem.indexOfScalar(u8, to, '@') != null)
            resolveNip05(allocator, to, io) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "NIP-05 resolution failed for '{s}': {}", .{ to, err }) catch
                    "NIP-05 resolution failed";
                return ToolResult.failAlloc(allocator, msg);
            }
        else
            return ToolResult.fail("'to' must be a 64-char hex pubkey or NIP-05 address (user@domain).");

        // Build email content (RFC 2822-ish format)
        const content = try std.fmt.allocPrint(allocator, "Subject: {s}\r\nFrom: {s}\r\nTo: {s}\r\n\r\n{s}", .{
            subject,
            &nostr.hexEncode32(kp.public_key),
            to,
            body,
        });
        defer allocator.free(content);

        // Build tags
        var tags: std.ArrayListUnmanaged(nostr.Tag) = .empty;
        defer {
            for (tags.items) |tag| {
                for (tag.fields) |f| allocator.free(f);
                allocator.free(tag.fields);
            }
            tags.deinit(allocator);
        }

        // p-tag (recipient)
        var fields_p = try allocator.alloc([]const u8, 2);
        fields_p[0] = try allocator.dupe(u8, "p");
        const to_hex = nostr.hexEncode32(recipient_pub);
        fields_p[1] = try allocator.dupe(u8, &to_hex);
        try tags.append(allocator, .{ .fields = fields_p });

        // e-tag (reply_to if provided)
        if (reply_to) |rt| {
            if (rt.len == 64 and isHexString(rt)) {
                var fields_e = try allocator.alloc([]const u8, 2);
                fields_e[0] = try allocator.dupe(u8, "e");
                fields_e[1] = try allocator.dupe(u8, rt);
                try tags.append(allocator, .{ .fields = fields_e });
            }
        }

        // Gift wrap the email
        const tags_slice = try allocator.dupe(nostr.Tag, tags.items);
        const wrapped = nip59.wrapEvent(allocator, sk, recipient_pub, KIND_EMAIL, tags_slice, content) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "Gift wrap failed: {}", .{err}) catch "Gift wrap failed";
            return ToolResult.failAlloc(allocator, msg);
        };
        defer nip59.freeWrappedEvent(allocator, wrapped);

        // Serialize and publish
        const event_json = nostr.eventToJson(wrapped, allocator) catch
            return ToolResult.fail("Failed to serialize gift wrap event.");
        defer allocator.free(event_json);

        const event_id_hex = nostr.hexEncode32(wrapped.id);
        log.info("sending email to {s}: {s}", .{ to, subject });

        var results: std.ArrayListUnmanaged(u8) = .empty;
        const w = struct {
            fn print(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, ap: anytype) !void {
                const line = try std.fmt.allocPrint(alloc, fmt, ap);
                defer alloc.free(line);
                try buf.appendSlice(alloc, line);
            }
        }.print;

        try w(&results, allocator, "Email sent (NIP-59 gift wrap)\n", .{});
        try w(&results, allocator, "Wrap ID: {s}\n", .{&event_id_hex});
        try w(&results, allocator, "To: {s}\n", .{to});
        try w(&results, allocator, "Subject: {s}\n", .{subject});
        try w(&results, allocator, "Relays:\n", .{});

        var ok_count: usize = 0;
        for (relays) |relay| {
            try w(&results, allocator, "  {s}: ", .{relay});
            const result = publishToRelay(allocator, relay, event_json);
            if (result) |resp| {
                defer allocator.free(resp);
                const display = resp[0..@min(resp.len, 100)];
                try w(&results, allocator, "{s}\n", .{display});
                ok_count += 1;
            } else {
                try w(&results, allocator, "FAILED\n", .{});
            }
        }

        try w(&results, allocator, "\nPublished to {d}/{d} relays.\n", .{ ok_count, relays.len });

        return ToolResult.okAlloc(allocator, results.items);
    }

    // ── Receive ───────────────────────────────────────────────────

    fn actionReceive(_: *NostrEmailTool, allocator: std.mem.Allocator, sk: [32]u8, relays: []const []const u8, args: JsonObjectMap, _: std.Io) !ToolResult {
        const limit: usize = if (root.getInt(args, "limit")) |l| @as(usize, @intCast(@max(l, 1))) else 20;

        const kp = nostr.keyPairFromSecret(sk) catch
            return ToolResult.fail("Invalid private key.");
        const pk_hex = nostr.hexEncode32(kp.public_key);

        // Build filter: kind 1059, #p = our pubkey
        const filter_json = try std.fmt.allocPrint(allocator, "[{{\"kinds\":[1059],\"#p\":[\"{s}\"],\"limit\":{d}}}]", .{ &pk_hex, limit });
        defer allocator.free(filter_json);

        log.info("receiving emails: subscribing to kind 1059 for {s}...", .{pk_hex[0..16]});

        // Query relays sequentially (single-threaded for simplicity — gift wrap unwrapping is fast)
        var all_emails: std.ArrayListUnmanaged(EmailInfo) = .empty;
        defer {
            for (all_emails.items) |*email| {
                allocator.free(email.subject);
                allocator.free(email.from);
                allocator.free(email.body);
                allocator.free(email.wrap_id);
            }
            all_emails.deinit(allocator);
        }
        var seen_ids: std.ArrayListUnmanaged([32]u8) = .empty;
        defer seen_ids.deinit(allocator);

        for (relays) |relay| {
            const events = queryRelay(allocator, relay, filter_json) catch |err| {
                log.warn("relay {s} query failed: {}", .{ relay, err });
                continue;
            };
            defer allocator.free(events);

            // Parse events
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, events, .{}) catch {
                log.warn("failed to parse events from {s}", .{relay});
                continue;
            };
            defer parsed.deinit();

            if (parsed.value != .array) continue;
            for (parsed.value.array.items) |item| {
                if (item != .object) continue;
                const obj = item.object;

                // Only process EVENT messages
                if (obj.get("type")) |t| {
                    if (t != .string or !std.mem.eql(u8, t.string, "EVENT")) continue;
                }
                const event_val = obj.get("event") orelse continue;
                if (event_val != .object) continue;

                // Extract event
                const id_hex_val = event_val.object.get("id") orelse continue;
                if (id_hex_val != .string) continue;
                const wrap_id = try allocator.dupe(u8, id_hex_val.string);

                const id_bytes = nostr.hexDecodeFixed(32, id_hex_val.string) catch {
                    allocator.free(wrap_id);
                    continue;
                };

                // Deduplicate
                var dup = false;
                for (seen_ids.items) |sid| {
                    if (std.mem.eql(u8, &sid, &id_bytes)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) {
                    allocator.free(wrap_id);
                    continue;
                }
                try seen_ids.append(allocator, id_bytes);

                // Parse wrap event
                const wrap_event_json = try std.fmt.allocPrint(allocator, "{}", .{event_val});
                defer allocator.free(wrap_event_json);

                const wrap_event = nostr.parseEventJson(allocator, wrap_event_json) catch {
                    log.warn("failed to parse wrap event {s}", .{id_hex_val.string});
                    allocator.free(wrap_id);
                    continue;
                };
                defer nostr.freeEvent(wrap_event, allocator);

                // Unwrap → rumor
                const rumor = nip59.unwrapEvent(allocator, wrap_event, sk) catch |err| {
                    log.warn("failed to unwrap {s}: {}", .{ id_hex_val.string, err });
                    allocator.free(wrap_id);
                    continue;
                };
                defer nip59.freeRumor(allocator, rumor);

                // Filter: only kind 1301 emails
                if (rumor.kind != KIND_EMAIL) {
                    allocator.free(wrap_id);
                    continue;
                }

                // Parse email headers from content
                const email = parseEmailContent(allocator, rumor.content, wrap_id, &rumor.id) catch {
                    allocator.free(wrap_id);
                    continue;
                };

                try all_emails.append(allocator, email);
            }
        }

        // Format results
        var results: std.ArrayListUnmanaged(u8) = .empty;
        const w = struct {
            fn print(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, ap: anytype) !void {
                const line = try std.fmt.allocPrint(alloc, fmt, ap);
                defer alloc.free(line);
                try buf.appendSlice(alloc, line);
            }
        }.print;

        if (all_emails.items.len == 0) {
            try w(&results, allocator, "No sealed emails found.\n", .{});
        } else {
            try w(&results, allocator, "Received {d} email(s):\n\n", .{all_emails.items.len});
            for (all_emails.items, 0..) |email, i| {
                try w(&results, allocator, "[{d}] Subject: {s}\n", .{ i + 1, email.subject });
                try w(&results, allocator, "    From: {s}\n", .{email.from});
                try w(&results, allocator, "    Wrap ID: {s}\n", .{email.wrap_id});
                try w(&results, allocator, "    Body: {s}\n\n", .{email.body});
            }
        }

        return ToolResult.okAlloc(allocator, results.items);
    }

    // ── Email parsing ─────────────────────────────────────────────

    const EmailInfo = struct {
        subject: []u8,
        from: []u8,
        body: []u8,
        wrap_id: []u8,
        event_id: [32]u8,
    };

    fn parseEmailContent(allocator: std.mem.Allocator, content: []const u8, wrap_id: []u8, event_id: *const [32]u8) !EmailInfo {
        var subject: []const u8 = "(no subject)";
        var from: []const u8 = "(unknown)";
        var body: []const u8 = "";

        // Parse headers (key: value\r\n format, ends at \r\n\r\n)
        var pos: usize = 0;
        var header_end: usize = 0;
        while (pos < content.len) {
            // Find end of line
            const line_end = if (std.mem.indexOfScalarPos(u8, content, pos, '\n')) |i| i else content.len;
            const line = std.mem.trimEnd(u8, content[pos..line_end], "\r");

            if (line.len == 0) {
                // Empty line = end of headers
                header_end = line_end + 1;
                break;
            }

            if (std.mem.startsWith(u8, line, "Subject:")) {
                subject = std.mem.trim(u8, line["Subject:".len..], " \t");
            } else if (std.mem.startsWith(u8, line, "From:")) {
                from = std.mem.trim(u8, line["From:".len..], " \t");
            }

            pos = line_end + 1;
        }
        if (header_end == 0) header_end = pos;
        if (header_end > content.len) header_end = content.len;
        body = if (header_end < content.len) content[header_end..] else "";

        return .{
            .subject = try allocator.dupe(u8, subject),
            .from = try allocator.dupe(u8, from),
            .body = try allocator.dupe(u8, body),
            .wrap_id = wrap_id,
            .event_id = event_id.*,
        };
    }

    // ── NIP-05 resolution ─────────────────────────────────────────

    fn resolveNip05(allocator: std.mem.Allocator, nip05: []const u8, io: std.Io) ![32]u8 {
        // Parse "user@domain"
        const at_idx = std.mem.indexOfScalar(u8, nip05, '@') orelse
            return error.InvalidNip05;
        const user = nip05[0..at_idx];
        const domain = nip05[at_idx + 1 ..];

        // HTTPS well-known: https://<domain>/.well-known/nostr.json?name=<user>
        const url = try std.fmt.allocPrint(allocator, "https://{s}/.well-known/nostr.json?name={s}", .{ domain, user });
        defer allocator.free(url);

        const uri = std.Uri.parse(url) catch return error.DnsFailed;

        // Native HTTPS via std.http.Client
        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();

        var req = client.request(.GET, uri, .{}) catch return error.DnsFailed;
        defer req.deinit();
        req.sendBodiless() catch return error.DnsFailed;

        var head_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&head_buf) catch return error.DnsFailed;
        const status = @intFromEnum(response.head.status);
        if (status < 200 or status >= 300) return error.Nip05NotFound;

        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const response_body = reader.readAlloc(allocator, 4096) catch return error.DnsFailed;
        defer allocator.free(response_body);

        // Parse JSON: {"names": {"user": "npub..."}}
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch
            return error.InvalidNip05Response;
        defer parsed.deinit();

        const root_obj = if (parsed.value == .object) parsed.value.object else
            return error.InvalidNip05Response;
        const names = root_obj.get("names") orelse return error.InvalidNip05Response;
        if (names != .object) return error.InvalidNip05Response;

        const pubkey_str = names.object.get(user) orelse return error.Nip05NotFound;
        if (pubkey_str != .string) return error.InvalidNip05Response;

        // Strip "npub1" prefix if present (bech32)
        const pk_hex = if (std.mem.startsWith(u8, pubkey_str.string, "npub1"))
            bech32ToHex(allocator, pubkey_str.string) catch
                return error.InvalidNip05Response
        else
            pubkey_str.string;

        return nostr.hexDecodeFixed(32, pk_hex);
    }

    fn bech32ToHex(allocator: std.mem.Allocator, bech32_str: []const u8) ![]const u8 {
        // Bech32 decode: skip HRP, take data part, convert 5-bit to 8-bit
        const sep_idx = std.mem.lastIndexOfScalar(u8, bech32_str, '1') orelse
            return error.InvalidBech32;
        const data_part = bech32_str[sep_idx + 1 ..];

        // Decode 5-bit groups to bytes
        var accumulator: u10 = 0;
        var bit_count: u4 = 0;
        var result: std.ArrayListUnmanaged(u8) = .empty;
        defer result.deinit(allocator);

        for (data_part) |c| {
            const val = bech32CharVal(c) orelse return error.InvalidBech32;
            if (val >= 32) continue; // padding
            accumulator = (accumulator << 5) | @as(u10, val);
            bit_count += 5;
            if (bit_count >= 8) {
                bit_count -= 8;
                const byte: u8 = @truncate((accumulator >> bit_count) & 0xFF);
                try result.append(allocator, byte);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    fn bech32CharVal(c: u8) ?u5 {
        const val: u5 = switch (c) {
            'q' => 0, 'p' => 1, 'z' => 2, 'r' => 3,
            'y' => 4, '9' => 5, 'x' => 6, '8' => 7,
            'g' => 8, 'f' => 9, '2' => 10, 't' => 11,
            'v' => 12, 'd' => 13, 'w' => 14, '0' => 15,
            's' => 16, '3' => 17, 'j' => 18, 'n' => 19,
            '5' => 20, '4' => 21, 'k' => 22, 'h' => 23,
            'c' => 24, 'e' => 25, '6' => 26, 'm' => 27,
            'u' => 28, 'a' => 29, '7' => 30, 'l' => 31,
            else => return null,
        };
        return val;
    }

    // ── Relay helpers ─────────────────────────────────────────────

    fn publishToRelay(allocator: std.mem.Allocator, relay: []const u8, event_json: []const u8) ?[]const u8 {
        var client = nostr.RelayClient.connect(allocator, relay) catch return null;
        defer client.deinit();
        return client.publish(event_json) catch null;
    }

    fn queryRelay(allocator: std.mem.Allocator, relay: []const u8, filter_json: []const u8) ![]const u8 {
        var client = nostr.RelayClient.connect(allocator, relay) catch
            return error.RelayConnectFailed;
        defer client.deinit();

        const sub_id = try client.subscribe(filter_json);
        defer allocator.free(sub_id);

        var messages: std.ArrayListUnmanaged(u8) = .empty;
        const timeout_ns: i128 = 10 * std.time.ns_per_s;
        const start = util.nanoTimestamp();
        var eose_received = false;

        while (!eose_received) {
            if (util.nanoTimestamp() - start > timeout_ns) break;
            const raw = (client.readMessage() catch null) orelse break;
            defer allocator.free(raw);

            // Collect all messages into a JSON array
            if (messages.items.len > 0) {
                try messages.appendSlice(allocator, ",");
            } else {
                try messages.appendSlice(allocator, "[");
            }
            try messages.appendSlice(allocator, raw);

            // Check for EOSE
            if (std.mem.indexOf(u8, raw, "\"EOSE\"") != null) {
                eose_received = true;
            }
        }
        client.unsubscribe(sub_id);

        if (messages.items.len == 0) return "[]";
        try messages.appendSlice(allocator, "]");
        return messages.toOwnedSlice(allocator);
    }

    // ── Config helpers ────────────────────────────────────────────

    fn loadPrivateKey(self: *NostrEmailTool, allocator: std.mem.Allocator, io: std.Io) !?[32]u8 {
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{self.config_dir});
        defer allocator.free(config_path);

        const file = std.Io.Dir.cwd().openFile(io, config_path, .{}) catch return null;
        defer file.close(io);

        const stat = file.stat(io) catch return null;
        const content = allocator.alloc(u8, @intCast(stat.size)) catch return null;
        defer allocator.free(content);

        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        const data = reader.interface.allocRemaining(allocator, .limited64(@intCast(stat.size))) catch return null;
        defer allocator.free(data);
        @memcpy(content, data);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
        defer parsed.deinit();

        const root_obj = if (parsed.value == .object) parsed.value.object else return null;
        const channels = root_obj.get("channels") orelse return null;
        if (channels != .object) return null;

        const nostr_public = channels.object.get("nostr_public") orelse
            channels.object.get("nostr") orelse return null;
        if (nostr_public != .object) return null;

        const pk_val = nostr_public.object.get("private_key") orelse return null;
        if (pk_val != .string) return null;

        // Hex decode
        if (pk_val.string.len == 64) {
            if (nostr.hexDecodeFixed(32, pk_val.string)) |sk| return sk else |_| {}
        }

        // Encrypted
        const secrets_mod = @import("../security/secrets.zig");
        const store = secrets_mod.SecretStore.init(self.config_dir, true);
        const decrypted = store.decryptSecret(allocator, pk_val.string) catch return null;
        defer allocator.free(decrypted);
        return nostr.hexDecodeFixed(32, decrypted) catch return null;
    }

    fn loadRelays(self: *NostrEmailTool, allocator: std.mem.Allocator, io: std.Io) ![][]const u8 {
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{self.config_dir});
        defer allocator.free(config_path);

        const file = std.Io.Dir.cwd().openFile(io, config_path, .{}) catch return &.{};
        defer file.close(io);

        const stat = file.stat(io) catch return &.{};
        const content = allocator.alloc(u8, @intCast(stat.size)) catch return &.{};
        defer allocator.free(content);

        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        const data = reader.interface.allocRemaining(allocator, .limited64(@intCast(stat.size))) catch return &.{};
        defer allocator.free(data);
        @memcpy(content, data);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return &.{};
        defer parsed.deinit();

        const root_obj = if (parsed.value == .object) parsed.value.object else return &.{};
        const channels = root_obj.get("channels") orelse return &.{};
        if (channels != .object) return &.{};

        var relays: std.ArrayListUnmanaged([]const u8) = .empty;
        var seen: std.ArrayListUnmanaged([]const u8) = .empty;
        defer { for (seen.items) |s| allocator.free(s); seen.deinit(allocator); }

        for (&[_][]const u8{ "nostr_public", "nostr" }) |ch_name| {
            const ch = channels.object.get(ch_name) orelse continue;
            if (ch != .object) continue;
            const relays_val = ch.object.get("relays") orelse continue;
            if (relays_val != .array) continue;
            for (relays_val.array.items) |rv| {
                if (rv != .string) continue;
                var already = false;
                for (seen.items) |s| {
                    if (std.mem.eql(u8, s, rv.string)) { already = true; break; }
                }
                if (!already) {
                    try seen.append(allocator, try allocator.dupe(u8, rv.string));
                    try relays.append(allocator, try allocator.dupe(u8, rv.string));
                }
            }
        }

        return relays.toOwnedSlice(allocator);
    }

    // ── Util ──────────────────────────────────────────────────────

    fn isHexString(s: []const u8) bool {
        for (s) |c| {
            if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')))
                return false;
        }
        return true;
    }
};
