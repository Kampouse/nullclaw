//! NIP-59 — Gift Wrap: Sealed Direct Messages.
//!
//! Reference: https://github.com/nostr-protocol/nips/blob/master/59.md
//! Reference impl: src/security/nip44-ref/nip59.ts (nostr-tools)
//!
//! Gift Wrap provides sealed, anonymous messaging on Nostr:
//! 1. Create a "rumor" (unsigned event with computed ID)
//! 2. Create a "seal" (kind 14): NIP-44 encrypt rumor for recipient
//! 3. Create a "wrap" (kind 1059): NIP-44 encrypt seal with random ephemeral key
//!
//! The recipient unwraps: decrypt wrap → get seal → decrypt seal → get rumor.

const std = @import("std");
const Allocator = std.mem.Allocator;

const nostr = @import("../nostr.zig");
const nip44 = @import("nip44.zig");
const util = @import("../util.zig");

const log = std.log.scoped(.nip59);

// ═══════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════

pub const KIND_SEAL: u16 = 14;
pub const KIND_GIFT_WRAP: u16 = 1059;

const TWO_DAYS: i64 = 2 * 24 * 60 * 60;

// ═══════════════════════════════════════════════════════════════
// Rumor
// ═══════════════════════════════════════════════════════════════

/// A rumor is an unsigned event that has an ID computed as if it were signed.
/// It carries the actual content (kind, tags, content) but no signature.
pub const Rumor = struct {
    id: [32]u8,
    pubkey: [32]u8,
    created_at: i64,
    kind: u16,
    tags: []const nostr.Tag,
    content: []const u8,
};

/// Create a rumor from event fields. Computes the ID as if it were a proper Nostr event.
pub fn createRumor(
    allocator: Allocator,
    sender_privkey: [32]u8,
    kind: u16,
    tags: []const nostr.Tag,
    content: []const u8,
    created_at: ?i64,
) !Rumor {
    const kp = try nostr.keyPairFromSecret(sender_privkey);
    const ts = created_at orelse util.timestampUnix();

    const id = try nostr.computeEventId(kp.public_key, ts, kind, tags, content, allocator);

    return .{
        .id = id,
        .pubkey = kp.public_key,
        .created_at = ts,
        .kind = kind,
        .tags = tags,
        .content = content,
    };
}

// ═══════════════════════════════════════════════════════════════
// Seal
// ═══════════════════════════════════════════════════════════════

/// Create a seal (kind 14): NIP-44 encrypt the rumor for the recipient, then sign.
pub fn createSeal(
    allocator: Allocator,
    rumor: Rumor,
    sender_privkey: [32]u8,
    recipient_pubkey: [32]u8,
) !nostr.Event {
    const kp = try nostr.keyPairFromSecret(sender_privkey);

    // Serialize rumor as JSON for NIP-44 encryption
    const rumor_json = try serializeRumor(allocator, rumor);
    defer allocator.free(rumor_json);

    // NIP-44 encrypt
    const conv_key = try nip44.getConversationKey(sender_privkey, recipient_pubkey);
    const encrypted = try nip44.encrypt(allocator, rumor_json, conv_key, null);

    // Random created_at within last 2 days
    const ts = randomNow();

    var event: nostr.Event = .{
        .id = undefined,
        .pubkey = kp.public_key,
        .created_at = ts,
        .kind = KIND_SEAL,
        .tags = &.{},
        .content = encrypted,
        .sig = undefined,
    };

    try nostr.signEvent(&event, sender_privkey, allocator);
    return event;
}

// ═══════════════════════════════════════════════════════════════
// Wrap
// ═══════════════════════════════════════════════════════════════

/// Create a gift wrap (kind 1059): encrypt the seal with a random ephemeral key.
pub fn createWrap(
    allocator: Allocator,
    seal: nostr.Event,
    recipient_pubkey: [32]u8,
) !nostr.Event {
    // Generate ephemeral keypair
    var ephemeral_secret: [32]u8 = undefined;
    util.randomBytes(&ephemeral_secret);
    const ephemeral_kp = try nostr.keyPairFromSecret(ephemeral_secret);

    // Serialize seal as JSON for NIP-44 encryption
    const seal_json = try nostr.eventToJson(seal, allocator);
    defer allocator.free(seal_json);

    // NIP-44 encrypt with ephemeral key
    const conv_key = try nip44.getConversationKey(ephemeral_secret, recipient_pubkey);
    const encrypted = try nip44.encrypt(allocator, seal_json, conv_key, null);

    // Create p-tag for recipient (heap-allocated so it outlives this function)
    var pk_hex: [64]u8 = undefined;
    nostr.hexEncode(&pk_hex, &recipient_pubkey);
    const tags = try allocator.alloc(nostr.Tag, 1);
    tags[0] = .{
        .fields = try allocator.alloc([]const u8, 2),
    };
    tags[0].fields[0] = try allocator.dupe(u8, "p");
    tags[0].fields[1] = try allocator.dupe(u8, pk_hex[0..]);

    const ts = randomNow();

    var event: nostr.Event = .{
        .id = undefined,
        .pubkey = ephemeral_kp.public_key,
        .created_at = ts,
        .kind = KIND_GIFT_WRAP,
        .tags = tags,
        .content = encrypted,
        .sig = undefined,
    };

    try nostr.signEvent(&event, ephemeral_secret, allocator);
    return event;
}

// ═══════════════════════════════════════════════════════════════
// High-level wrap/unwrap
// ═══════════════════════════════════════════════════════════════

/// Wrap an event into a gift wrap for the recipient.
/// This is the main entry point for sending sealed messages.
pub fn wrapEvent(
    allocator: Allocator,
    sender_privkey: [32]u8,
    recipient_pubkey: [32]u8,
    kind: u16,
    tags: []const nostr.Tag,
    content: []const u8,
) !nostr.Event {
    // 1. Create rumor
    const rumor = try createRumor(allocator, sender_privkey, kind, tags, content, null);

    // 2. Create seal
    const seal = try createSeal(allocator, rumor, sender_privkey, recipient_pubkey);
    defer allocator.free(@constCast(seal.content));

    // 3. Create wrap
    return createWrap(allocator, seal, recipient_pubkey);
}

/// Unwrap a gift wrap event. Returns the inner rumor.
/// The recipient's private key is needed to decrypt both layers.
pub fn unwrapEvent(
    allocator: Allocator,
    wrap: nostr.Event,
    recipient_privkey: [32]u8,
) !Rumor {
    // 1. Decrypt wrap → seal JSON
    const conv_key_wrap = try nip44.getConversationKey(recipient_privkey, wrap.pubkey);
    const seal_json = try nip44.decrypt(allocator, wrap.content, conv_key_wrap);
    defer allocator.free(seal_json);

    // 2. Parse seal event
    const seal = try nostr.parseEventJson(allocator, seal_json);
    defer nostr.freeEvent(seal, allocator);

    // 3. Decrypt seal → rumor JSON
    const conv_key_seal = try nip44.getConversationKey(recipient_privkey, seal.pubkey);
    const rumor_json = try nip44.decrypt(allocator, seal.content, conv_key_seal);
    defer allocator.free(rumor_json);

    // 4. Parse rumor
    return parseRumor(allocator, rumor_json);
}

// ═══════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════

fn randomNow() i64 {
    const now = util.timestampUnix();
    const offset = util.randomInt(u64) % TWO_DAYS;
    return now - @as(i64, @intCast(offset));
}

fn serializeRumor(allocator: Allocator, rumor: Rumor) ![]u8 {
    // Serialize as canonical Nostr event JSON (same as eventToJson but without sig)
    const pk_hex = nostr.hexEncode32(rumor.pubkey);
    const id_hex = nostr.hexEncode32(rumor.id);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"id\":\"");
    try buf.appendSlice(allocator, &id_hex);
    try buf.appendSlice(allocator, "\",\"pubkey\":\"");
    try buf.appendSlice(allocator, &pk_hex);
    try buf.appendSlice(allocator, "\",\"created_at\":");
    var int_buf: [20]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&int_buf, "{d}", .{rumor.created_at}) catch unreachable;
    try buf.appendSlice(allocator, ts_str);
    try buf.appendSlice(allocator, ",\"kind\":");
    const kind_str = std.fmt.bufPrint(&int_buf, "{d}", .{rumor.kind}) catch unreachable;
    try buf.appendSlice(allocator, kind_str);
    try buf.appendSlice(allocator, ",\"tags\":[");

    for (rumor.tags, 0..) |tag, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "[");
        for (tag.fields, 0..) |field, j| {
            if (j > 0) try buf.appendSlice(allocator, ",");
            try buf.appendSlice(allocator, "\"");
            // JSON escape (simplified — reuse nostr's approach)
            for (field) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(allocator, "\\\""),
                    '\\' => try buf.appendSlice(allocator, "\\\\"),
                    '\n' => try buf.appendSlice(allocator, "\\n"),
                    else => try buf.append(allocator, c),
                }
            }
            try buf.appendSlice(allocator, "\"");
        }
        try buf.appendSlice(allocator, "]");
    }

    try buf.appendSlice(allocator, "],\"content\":\"");
    for (rumor.content) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.appendSlice(allocator, "\"}");

    return buf.toOwnedSlice(allocator);
}

fn parseRumor(allocator: Allocator, json_str: []const u8) !Rumor {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn("rumor JSON parse failed: {}", .{err});
        return error.JsonParseFailed;
    };
    defer parsed.deinit();
    const obj = parsed.value.object;

    const id_hex = obj.get("id") orelse return error.MissingField;
    const pk_hex = obj.get("pubkey") orelse return error.MissingField;
    const created_at = obj.get("created_at") orelse return error.MissingField;
    const kind = obj.get("kind") orelse return error.MissingField;
    const content_val = obj.get("content") orelse return error.MissingField;

    const id = try nostr.hexDecodeFixed(32, id_hex.string);
    const pubkey = try nostr.hexDecodeFixed(32, pk_hex.string);

    // Parse tags
    var tags_list: std.ArrayListUnmanaged(nostr.Tag) = .empty;
    defer tags_list.deinit(allocator);
    if (obj.get("tags")) |tags_val| {
        if (tags_val == .array) {
            for (tags_val.array.items) |tag_item| {
                if (tag_item == .array) {
                    var fields: std.ArrayListUnmanaged([]const u8) = .empty;
                    defer fields.deinit(allocator);
                    for (tag_item.array.items) |field| {
                        if (field == .string) {
                            try fields.append(allocator, try allocator.dupe(u8, field.string));
                        }
                    }
                    try tags_list.append(allocator, .{ .fields = try fields.toOwnedSlice(allocator) });
                }
            }
        }
    }

    return .{
        .id = id,
        .pubkey = pubkey,
        .created_at = created_at.integer,
        .kind = @intCast(kind.integer),
        .tags = try tags_list.toOwnedSlice(allocator),
        .content = try allocator.dupe(u8, content_val.string),
    };
}

// ═══════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════

test "nip59 wrap/unwrap round-trip" {
    // Using known keys from nostr-tools nip59.test.ts
    // sender: nsec1p0ht6p3wepe47sjrgesyn4m50m6avk2waqudu9rl324cg2c4ufesyp6rdg
    // recipient: nsec1uyyrnx7cgfp40fcskcr2urqnzekc20fj0er6de0q8qvhx34ahazsvs9p36
    const sender_priv = try nostr.hexDecodeFixed(32, "0beebd062ec8735f4243466049d7747ef5d6594ee838de147f8aab842b15e273");
    const recipient_priv = try nostr.hexDecodeFixed(32, "e108399bd8424357a710b606ae0c13166d853d327e47a6e5e038197346bdbf45");
    const recipient_pub = try nostr.hexDecodeFixed(32, "166bf3765ebd1fc55decfe395beff2ea3b2a4e0a8946e7eb578512b555737c99");

    const content = "Are you going to the party tonight?";

    // Wrap: sender → recipient
    const wrapped = try wrapEvent(
        std.testing.allocator,
        sender_priv,
        recipient_pub,
        1, // kind 1 = text note
        &.{},
        content,
    );
    defer freeWrappedEvent(std.testing.allocator, wrapped);

    // Verify wrap structure
    try std.testing.expectEqual(@as(u16, KIND_GIFT_WRAP), wrapped.kind);
    try std.testing.expectEqual(@as(usize, 1), wrapped.tags.len);
    // First tag should be ["p", "<recipient_pubkey_hex>"]
    try std.testing.expectEqualStrings("p", wrapped.tags[0].fields[0]);
    const pk_hex = nostr.hexEncode32(recipient_pub);
    try std.testing.expectEqualStrings(&pk_hex, wrapped.tags[0].fields[1]);

    // Unwrap: recipient decrypts
    const rumor = try unwrapEvent(
        std.testing.allocator,
        wrapped,
        recipient_priv,
    );
    defer freeRumor(std.testing.allocator, rumor);

    // Verify rumor content matches original
    try std.testing.expectEqualStrings(content, rumor.content);
    try std.testing.expectEqual(@as(u16, 1), rumor.kind);
}

test "nip59 wrap/unwrap with tags" {
    const sender_priv = try nostr.hexDecodeFixed(32, "0beebd062ec8735f4243466049d7747ef5d6594ee838de147f8aab842b15e273");
    const recipient_priv = try nostr.hexDecodeFixed(32, "e108399bd8424357a710b606ae0c13166d853d327e47a6e5e038197346bdbf45");
    const recipient_pub = try nostr.hexDecodeFixed(32, "166bf3765ebd1fc55decfe395beff2ea3b2a4e0a8946e7eb578512b555737c99");

    // Test with kind 1301 (email) and tags
    const reply_tag = nostr.tagLiterals(&[_][]const u8{
        "e",
        "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
    });
    const p_tag = nostr.tagLiterals(&[_][]const u8{
        "p",
        "fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321",
    });

    const content = "Subject: Re: Hello\r\nFrom: alice@example.com\r\nTo: bob@example.com\r\n\r\nHey Bob!";

    const wrapped = try wrapEvent(
        std.testing.allocator,
        sender_priv,
        recipient_pub,
        1301, // email kind
        &[_]nostr.Tag{ reply_tag, p_tag },
        content,
    );
    defer freeWrappedEvent(std.testing.allocator, wrapped);

    const rumor = try unwrapEvent(
        std.testing.allocator,
        wrapped,
        recipient_priv,
    );
    defer freeRumor(std.testing.allocator, rumor);
    try std.testing.expectEqualStrings(content, rumor.content);
    try std.testing.expectEqual(@as(u16, 1301), rumor.kind);
    try std.testing.expectEqual(@as(usize, 2), rumor.tags.len);
    try std.testing.expectEqualStrings("e", rumor.tags[0].fields[0]);
    try std.testing.expectEqualStrings("p", rumor.tags[1].fields[0]);
}

// NOTE: Memory management for wrap/unwrap needs proper ownership tracking.
// The wrapped event's content and rumor fields are heap-allocated.
// In production, callers must use freeWrappedEvent() and freeRumor()
// or a general-purpose arena allocator.

/// Free heap memory owned by a wrapped event (from wrapEvent/createWrap).
/// Frees content, tags slice, each tag's fields slice, and each field string.
pub fn freeWrappedEvent(allocator: Allocator, event: nostr.Event) void {
    for (event.tags) |tag| {
        for (tag.fields) |field| {
            allocator.free(@constCast(field));
        }
        allocator.free(@constCast(tag.fields));
    }
    allocator.free(@constCast(event.tags));
    allocator.free(@constCast(event.content));
}

/// Free heap memory owned by a rumor (from unwrapEvent/parseRumor).
/// Frees content, tags slice, each tag's fields slice, and each field string.
pub fn freeRumor(allocator: Allocator, rumor: Rumor) void {
    for (rumor.tags) |tag| {
        for (tag.fields) |field| {
            allocator.free(@constCast(field));
        }
        allocator.free(@constCast(tag.fields));
    }
    allocator.free(@constCast(rumor.tags));
    allocator.free(@constCast(rumor.content));
}
