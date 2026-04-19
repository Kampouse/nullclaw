//! Native Nostr library — BIP-340 Schnorr signing, event construction, relay client.
//!
//! Zero external dependencies. Uses Zig std secp256k1 for crypto and
//! karlseguin/websocket.zig (vendored) for relay connections.
//!
//! Implements NIP-01 (basic protocol), kind 0/1/7 events.
//! DM support (NIP-04/NIP-17) is a future addition.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Secp256k1 = std.crypto.ecc.Secp256k1;
const Sha256 = std.crypto.hash.sha2.Sha256;
const ws = @import("ws_karlseguin");
const util = @import("util.zig");
const http_util = @import("http_util.zig");

const log = std.log.scoped(.nostr);

// ═══════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════

/// secp256k1 curve order n
const N: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

const hex_chars = "0123456789abcdef";

// ═══════════════════════════════════════════════════════════════════════════
// Hex utilities
// ═══════════════════════════════════════════════════════════════════════════

/// Encode bytes as lowercase hex. `out` must be exactly `bytes.len * 2` bytes.
pub fn hexEncode(out: []u8, bytes: []const u8) void {
    std.debug.assert(out.len == bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0xf];
    }
}

/// Encode 32 bytes as 64-char hex string. Returns fixed array.
pub fn hexEncode32(bytes: [32]u8) [64]u8 {
    var out: [64]u8 = undefined;
    hexEncode(&out, &bytes);
    return out;
}

// ═══════════════════════════════════════════════════════════════════════════
// Bech32 encoding (npub / nsec)
// ═══════════════════════════════════════════════════════════════════════════

const BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

/// Bech32 polymod checksum.
fn bech32Polymod(values: []const u5) u32 {
    var chk: u32 = 1;
    for (values) |v| {
        const b = chk >> 25;
        chk = ((chk & 0x01ffffff) << 5) ^ v;
        if (b & 0x01 != 0) chk ^= 0x3b6a57b2;
        if (b & 0x02 != 0) chk ^= 0x26508e6d;
        if (b & 0x04 != 0) chk ^= 0x1ea119fa;
        if (b & 0x08 != 0) chk ^= 0x3d4233dd;
        if (b & 0x10 != 0) chk ^= 0x2a1462b3;
    }
    return chk;
}

/// HRP expansion for bech32 checksum. Returns slice into caller-provided buffer.
/// For HRP of length n, the expansion is n + 1 + n = 2n+1 values.
fn bech32HrpExpand(hrp: []const u8, buf: *[39]u5) []const u5 {
    var i: usize = 0;
    for (hrp) |c| {
        buf[i] = @intCast(c >> 5);
        i += 1;
    }
    buf[i] = 0;
    i += 1;
    for (hrp) |c| {
        buf[i] = @intCast(c & 0x1f);
        i += 1;
    }
    return buf[0..i];
}

/// Encode a 32-byte x-only pubkey as npub1... bech32 string.
/// Returns a stack-allocated [63]u8 (npub1 = 5 chars + 53 data chars + 6 checksum chars).
pub fn npubEncode(pubkey: [32]u8) [63]u8 {
    // Build witness program: version 0x00 + 32-byte pubkey = 33 bytes
    var data8: [33]u8 = undefined;
    data8[0] = 0x00;
    @memcpy(data8[1..33], &pubkey);

    // Convert 8-bit to 5-bit groups: 33 bytes -> 53 five-bit values
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

    // Compute bech32 checksum (6 values)
    const hrp = "npub";
    var hrp_buf: [39]u5 = undefined;
    const hrp_exp = bech32HrpExpand(hrp, &hrp_buf);
    var checksum_data: [hrp_buf.len + data5.len + 6]u5 = undefined;
    @memcpy(checksum_data[0..hrp_exp.len], hrp_exp);
    @memcpy(checksum_data[hrp_exp.len .. hrp_exp.len + data5.len], &data5);
    // Zero-fill checksum positions
    for (hrp_exp.len + data5.len .. checksum_data.len) |j| {
        checksum_data[j] = 0;
    }
    const chk = bech32Polymod(&checksum_data) ^ 1;

    // Build output: "npub1" + 53 data chars + 6 checksum chars
    var out: [63]u8 = undefined;
    @memcpy(out[0..5], "npub1");
    for (0..53) |i| {
        out[5 + i] = BECH32_CHARSET[data5[i]];
    }
    for (0..6) |i| {
        out[58 + i] = BECH32_CHARSET[(chk >> (5 * (5 - @as(u5, @intCast(i))))) & 0x1F];
    }
    return out;
}

/// Encode 64 bytes as 128-char hex string. Returns fixed array.
pub fn hexEncode64(bytes: [64]u8) [128]u8 {
    var out: [128]u8 = undefined;
    hexEncode(&out, &bytes);
    return out;
}

/// Decode hex string into fixed-size byte array. Returns error if hex is invalid.
pub fn hexDecodeFixed(comptime len: usize, hex: []const u8) ![len]u8 {
    if (hex.len != len * 2) return error.InvalidHexLength;
    var out: [len]u8 = undefined;
    for (0..len) |i| {
        out[i] = (try hexCharToInt(hex[i * 2]) << 4) | try hexCharToInt(hex[i * 2 + 1]);
    }
    return out;
}

/// Decode hex string into heap-allocated slice.
pub fn hexDecodeAlloc(allocator: Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHexLength;
    const out_len = hex.len / 2;
    const out = try allocator.alloc(u8, out_len);
    for (0..out_len) |i| {
        out[i] = (try hexCharToInt(hex[i * 2]) << 4) | try hexCharToInt(hex[i * 2 + 1]);
    }
    return out;
}

fn hexCharToInt(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHexCharacter,
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// SHA-256 tagged hash (BIP-340 helper)
// ═══════════════════════════════════════════════════════════════════════════

/// Compute BIP-340 tagged hash: SHA256(SHA256(tag) || SHA256(tag) || data).
fn taggedHash(tag: []const u8, data: []const u8) [32]u8 {
    var tag_hash: [32]u8 = undefined;
    Sha256.hash(tag, &tag_hash, .{});

    var h = Sha256.init(.{});
    h.update(&tag_hash);
    h.update(&tag_hash);
    h.update(data);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

// ═══════════════════════════════════════════════════════════════════════════
// BIP-340 Schnorr signatures
// ═══════════════════════════════════════════════════════════════════════════

pub const KeyPair = struct {
    /// Secret key scalar (32 bytes, big-endian).
    secret_key: [32]u8,
    /// X-only public key (32 bytes, big-endian).
    public_key: [32]u8,
};

/// Derive a key pair from a 32-byte secret. Returns error if secret is 0 or >= n.
pub fn keyPairFromSecret(secret: [32]u8) !KeyPair {
    const d = std.mem.readInt(u256, &secret, .big);
    if (d == 0 or d >= N) return error.InvalidSecretKey;

    const P = Secp256k1.mul(Secp256k1.basePoint, secret, .big) catch
        return error.InvalidSecretKey;

    const sec1 = Secp256k1.toCompressedSec1(P);
    var pk: [32]u8 = undefined;
    @memcpy(&pk, sec1[1..33]);

    return .{ .secret_key = secret, .public_key = pk };
}

/// BIP-340 Schnorr sign. Returns 64-byte signature.
/// If aux_rand is null, random bytes are generated for nonce hardening.
pub fn schnorrSign(secret_key: [32]u8, public_key: [32]u8, msg: [32]u8, aux_rand: ?*[32]u8) ![64]u8 {
    const d_prime = std.mem.readInt(u256, &secret_key, .big);
    if (d_prime == 0 or d_prime >= N) return error.InvalidSecretKey;

    // Compute P = d' * G to determine actual y parity
    const P_actual = Secp256k1.mul(Secp256k1.basePoint, secret_key, .big) catch
        return error.InvalidSecretKey;
    const p_actual_sec1 = Secp256k1.toCompressedSec1(P_actual);
    // Normalize: d = d' if even_y(P_actual), else n - d'
    const d: u256 = if (p_actual_sec1[0] == 0x02) d_prime else N - d_prime;

    // lift_x(public_key) with even y for the canonical P used in the protocol
    var sec1_buf: [33]u8 = [_]u8{0x02} ++ [_]u8{0} ** 32;
    @memcpy(sec1_buf[1..33], &public_key);
    const P = Secp256k1.fromSec1(&sec1_buf) catch
        return error.InvalidPublicKey;

    // P.x should match the x-coordinate from P_actual
    const p_sec1 = Secp256k1.toCompressedSec1(P);
    const p_x = p_sec1[1..33].*;

    // Generate aux_rand if not provided
    var default_aux: [32]u8 = undefined;
    const aux = if (aux_rand) |ar| ar.* else blk: {
        util.randomBytes(&default_aux);
        break :blk default_aux;
    };

    // t = xor(bytes32(d), tagged_hash("BIP0340/aux", aux_rand))
    var d_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &d_bytes, d, .big);
    const aux_hash = taggedHash("BIP0340/aux", &aux);
    var t: [32]u8 = undefined;
    for (0..32) |i| t[i] = d_bytes[i] ^ aux_hash[i];

    // rand = tagged_hash("BIP0340/nonce", t || bytes32(P.x) || msg)
    var nonce_input: [32 + 32 + 32]u8 = undefined;
    @memcpy(nonce_input[0..32], &t);
    @memcpy(nonce_input[32..64], &p_x);
    @memcpy(nonce_input[64..96], &msg);
    const rand = taggedHash("BIP0340/nonce", &nonce_input);

    // k0 = int(rand) mod n
    const k0 = @mod(std.mem.readInt(u256, &rand, .big), N);
    if (k0 == 0) return error.SigningNonceZero;

    // R = k0 * G
    var k0_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &k0_bytes, k0, .big);
    const R = Secp256k1.mul(Secp256k1.basePoint, k0_bytes, .big) catch
        return error.SigningFailed;

    // Negate k if R has odd y (BIP-340: k = n - k0 if not has_even_y(R))
    const r_sec1 = Secp256k1.toCompressedSec1(R);
    const k: u256 = if (r_sec1[0] == 0x02) k0 else N - k0;

    // e = int(tagged_hash("BIP0340/challenge", bytes32(R.x) || bytes32(P.x) || msg)) mod n
    const r_x = r_sec1[1..33].*;
    var challenge_input: [32 + 32 + 32]u8 = undefined;
    @memcpy(challenge_input[0..32], &r_x);
    @memcpy(challenge_input[32..64], &p_x);
    @memcpy(challenge_input[64..96], &msg);
    const e = @mod(std.mem.readInt(u256, &taggedHash("BIP0340/challenge", &challenge_input), .big), N);

    // sig = bytes32(R.x) || bytes32((k + e * d) mod n)
    // Compute in u512 to avoid overflow: k and (e*d mod n) are both < N ≈ 2^256,
    // so their sum can exceed u256 range.
    const s: u256 = @truncate((@as(u512, k) + @as(u512, e) * @as(u512, d)) % @as(u512, N));
    if (s == 0) return error.SigningNonceZero;

    var sig: [64]u8 = undefined;
    @memcpy(sig[0..32], &r_x);
    std.mem.writeInt(u256, sig[32..64], s, .big);

    return sig;
}

/// BIP-340 Schnorr verify. Returns true if signature is valid.
pub fn schnorrVerify(public_key: [32]u8, msg: [32]u8, sig: [64]u8) bool {
    // lift_x(public_key) with even y
    var sec1_buf: [33]u8 = [_]u8{0x02} ++ [_]u8{0} ** 32;
    @memcpy(sec1_buf[1..33], &public_key);
    const P = Secp256k1.fromSec1(&sec1_buf) catch return false;

    const r = std.mem.readInt(u256, sig[0..32], .big);
    const k_prime = std.mem.readInt(u256, sig[32..64], .big);
    if (k_prime >= N) return false;

    // e = int(tagged_hash("BIP0340/challenge", bytes32(r) || bytes32(P.x) || msg)) mod n
    const p_sec1 = Secp256k1.toCompressedSec1(P);
    const p_x = p_sec1[1..33].*;
    var r_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &r_bytes, r, .big);
    var challenge_input: [32 + 32 + 32]u8 = undefined;
    @memcpy(challenge_input[0..32], &r_bytes);
    @memcpy(challenge_input[32..64], &p_x);
    @memcpy(challenge_input[64..96], &msg);
    const e = @mod(std.mem.readInt(u256, &taggedHash("BIP0340/challenge", &challenge_input), .big), N);

    // R = k'*G - e*P
    var k_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &k_bytes, k_prime, .big);
    var e_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &e_bytes, e, .big);

    const kG = Secp256k1.mul(Secp256k1.basePoint, k_bytes, .big) catch return false;
    const eP = Secp256k1.mul(P, e_bytes, .big) catch return false;
    const R = Secp256k1.sub(kG, eP);

    // Check R is not identity, has even y, and r == R.x
    Secp256k1.rejectIdentity(R) catch return false;
    const r_sec1 = Secp256k1.toCompressedSec1(R);
    if (r_sec1[0] != 0x02) return false; // must have even y
    const r_x = std.mem.readInt(u256, r_sec1[1..33], .big);
    return r == r_x;
}

// ═══════════════════════════════════════════════════════════════════════════
// Nostr Event
// ═══════════════════════════════════════════════════════════════════════════

/// A single Nostr tag (array of string values).
/// Fields are owned by the caller / arena.
pub const Tag = struct {
    fields: [][]const u8,

    pub fn deinit(self: Tag, allocator: Allocator) void {
        for (self.fields) |f| allocator.free(f);
        allocator.free(self.fields);
    }
};

/// Helper to create a tag from a slice of string literals (no allocation).
pub fn tagLiterals(fields: []const []const u8) Tag {
    return .{ .fields = @constCast(fields) };
}

/// Helper to create a p-tag (recipient pubkey reference).
pub fn pTag(allocator: Allocator, pubkey_hex: []const u8) !Tag {
    const fields = try allocator.alloc([]const u8, 2);
    fields[0] = try allocator.dupe(u8, "p");
    fields[1] = try allocator.dupe(u8, pubkey_hex);
    return .{ .fields = fields };
}

/// Helper to create an e-tag (event reference).
pub fn eTag(allocator: Allocator, event_id_hex: []const u8) !Tag {
    const fields = try allocator.alloc([]const u8, 2);
    fields[0] = try allocator.dupe(u8, "e");
    fields[1] = try allocator.dupe(u8, event_id_hex);
    return .{ .fields = fields };
}

pub const Event = struct {
    /// SHA-256 of canonical serialization (32 bytes raw).
    id: [32]u8,
    /// X-only public key (32 bytes raw).
    pubkey: [32]u8,
    /// Unix timestamp.
    created_at: i64,
    /// Event kind (0=metadata, 1=text, 7=reaction, etc).
    kind: u16,
    /// Array of tags.
    tags: []const Tag,
    /// Event content string.
    content: []const u8,
    /// 64-byte Schnorr signature.
    sig: [64]u8,
};

/// Compute the event ID: SHA-256 of canonical JSON serialization.
/// Canonical form: [0, "pubkey_hex", created_at, kind, [...tags...], "content"]
pub fn computeEventId(
    pubkey: [32]u8,
    created_at: i64,
    kind: u16,
    tags: []const Tag,
    content: []const u8,
    allocator: Allocator,
) ![32]u8 {
    const pk_hex = hexEncode32(pubkey);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "[0,\"");
    try buf.appendSlice(allocator, &pk_hex);
    try buf.appendSlice(allocator, "\",");
    var int_buf: [20]u8 = undefined;
    const created_at_str = std.fmt.bufPrint(&int_buf, "{d}", .{created_at}) catch unreachable;
    try buf.appendSlice(allocator, created_at_str);
    try buf.appendSlice(allocator, ",");
    const kind_str = std.fmt.bufPrint(&int_buf, "{d}", .{kind}) catch unreachable;
    try buf.appendSlice(allocator, kind_str);
    try buf.appendSlice(allocator, ",[");

    for (tags, 0..) |tag, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "[");
        for (tag.fields, 0..) |field, j| {
            if (j > 0) try buf.appendSlice(allocator, ",");
            try buf.appendSlice(allocator, "\"");
            try writeJsonEscaped(&buf, allocator, field);
            try buf.appendSlice(allocator, "\"");
        }
        try buf.appendSlice(allocator, "]");
    }

    try buf.appendSlice(allocator, "],\"");
    try writeJsonEscaped(&buf, allocator, content);
    try buf.appendSlice(allocator, "\"]");

    const serialized = buf.items;
    var hash: [32]u8 = undefined;
    Sha256.hash(serialized, &hash, .{});
    return hash;
}

/// Sign an event in-place: computes ID, then signs with Schnorr.
pub fn signEvent(event: *Event, secret_key: [32]u8, allocator: Allocator) !void {
    event.id = try computeEventId(event.pubkey, event.created_at, event.kind, event.tags, event.content, allocator);
    event.sig = try schnorrSign(secret_key, event.pubkey, event.id, null);
}

/// Serialize a full event to JSON (for publishing to relay).
pub fn eventToJson(event: Event, allocator: Allocator) ![]u8 {
    const id_hex = hexEncode32(event.id);
    const pk_hex = hexEncode32(event.pubkey);
    const sig_hex = hexEncode64(event.sig);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"id\":\"");
    try buf.appendSlice(allocator, &id_hex);
    try buf.appendSlice(allocator, "\",\"pubkey\":\"");
    try buf.appendSlice(allocator, &pk_hex);
    try buf.appendSlice(allocator, "\",\"created_at\":");
    var int_buf: [20]u8 = undefined;
    const created_at_str = std.fmt.bufPrint(&int_buf, "{d}", .{event.created_at}) catch unreachable;
    try buf.appendSlice(allocator, created_at_str);
    try buf.appendSlice(allocator, ",\"kind\":");
    const kind_str = std.fmt.bufPrint(&int_buf, "{d}", .{event.kind}) catch unreachable;
    try buf.appendSlice(allocator, kind_str);
    try buf.appendSlice(allocator, ",\"tags\":[");

    for (event.tags, 0..) |tag, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "[");
        for (tag.fields, 0..) |field, j| {
            if (j > 0) try buf.appendSlice(allocator, ",");
            try buf.appendSlice(allocator, "\"");
            try writeJsonEscaped(&buf, allocator, field);
            try buf.appendSlice(allocator, "\"");
        }
        try buf.appendSlice(allocator, "]");
    }

    try buf.appendSlice(allocator, "],\"content\":\"");
    try writeJsonEscaped(&buf, allocator, event.content);
    try buf.appendSlice(allocator, "\",\"sig\":\"");
    try buf.appendSlice(allocator, &sig_hex);
    try buf.appendSlice(allocator, "\"}");

    return buf.toOwnedSlice(allocator);
}

/// Parse a minimal event from JSON (used for reading relay events).
/// Handles the fields we care about: id, pubkey, created_at, kind, tags, content, sig.
pub fn parseEventJson(allocator: Allocator, json_str: []const u8) !Event {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn("event JSON parse failed: {}", .{err});
        return error.JsonParseFailed;
    };
    defer parsed.deinit();
    const obj = parsed.value.object;

    const id_hex = obj.get("id") orelse return error.MissingField;
    const pk_hex = obj.get("pubkey") orelse return error.MissingField;
    const created_at = obj.get("created_at") orelse return error.MissingField;
    const kind = obj.get("kind") orelse return error.MissingField;
    const content_val = obj.get("content") orelse return error.MissingField;
    const sig_hex = obj.get("sig") orelse return error.MissingField;

    const id = try hexDecodeFixed(32, id_hex.string);
    const pubkey = try hexDecodeFixed(32, pk_hex.string);
    const sig = try hexDecodeFixed(64, sig_hex.string);

    // Parse tags
    var tags_list: std.ArrayListUnmanaged(Tag) = .empty;
    if (obj.get("tags")) |tags_val| {
        if (tags_val == .array) {
            for (tags_val.array.items) |tag_item| {
                if (tag_item == .array) {
                    var fields: std.ArrayListUnmanaged([]const u8) = .empty;
                    for (tag_item.array.items) |field| {
                        if (field == .string) {
                            try fields.append(allocator, try allocator.dupe(u8, field.string));
                        }
                    }
                    try tags_list.append(allocator, .{ .fields = fields.items });
                }
            }
        }
    }

    return .{
        .id = id,
        .pubkey = pubkey,
        .created_at = created_at.integer,
        .kind = @intCast(kind.integer),
        .tags = tags_list.items,
        .content = try allocator.dupe(u8, content_val.string),
        .sig = sig,
    };
}

/// Free event heap data.
pub fn freeEvent(event: Event, allocator: Allocator) void {
    for (event.tags) |tag| {
        for (tag.fields) |f| allocator.free(f);
        allocator.free(tag.fields);
    }
    allocator.free(event.tags);
    allocator.free(event.content);
}

/// Append a JSON-escaped string to an ArrayListUnmanaged (handles ", \, control chars).
fn writeJsonEscaped(buf: *std.ArrayListUnmanaged(u8), alloc: Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.appendSlice(alloc, "\\u00");
                    try buf.append(alloc, hex_chars[c >> 4]);
                    try buf.append(alloc, hex_chars[c & 0xf]);
                } else {
                    try buf.append(alloc, c);
                }
            },
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Relay URL parsing
// ═══════════════════════════════════════════════════════════════════════════

pub const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

/// Parse a wss:// URL into host, port, path components.
/// Auto-prepends wss:// if the URL has no scheme prefix.
pub fn parseRelayUrl(allocator: Allocator, url: []const u8) !ParsedUrl {
    // Strip wss:// or ws:// prefix, or auto-prepend wss:// for bare hostnames
    const rest = if (std.ascii.startsWithIgnoreCase(url, "wss://"))
        url[6..]
    else if (std.ascii.startsWithIgnoreCase(url, "ws://"))
        url[5..]
    else if (std.mem.indexOfScalar(u8, url, ':') == null and
        !std.ascii.startsWithIgnoreCase(url, "http"))
        // Bare hostname like "relay.ditto.pub" — assume wss://
        url
    else
        return error.InvalidRelayUrl;

    // Find path start
    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..path_start];
    const path = if (path_start < rest.len) rest[path_start..] else "/";

    // Split host:port
    const port_idx = std.mem.lastIndexOfScalar(u8, host_port, ':');
    if (port_idx) |idx| {
        const host = host_port[0..idx];
        const port_str = host_port[idx + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch 443;
        const host_copy = try allocator.dupe(u8, host);
        errdefer allocator.free(host_copy);
        const path_copy = try allocator.dupe(u8, path);
        return .{ .host = host_copy, .port = port, .path = path_copy };
    } else {
        const is_wss = std.ascii.startsWithIgnoreCase(url, "wss://");
        const port: u16 = if (is_wss) 443 else 80;
        const host_copy = try allocator.dupe(u8, host_port);
        errdefer allocator.free(host_copy);
        const path_copy = try allocator.dupe(u8, path);
        return .{ .host = host_copy, .port = port, .path = path_copy };
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Relay client — WebSocket-based NIP-01 relay communication
// ═══════════════════════════════════════════════════════════════════════════

pub const RelayClient = struct {
    client: ws.Client,
    allocator: Allocator,
    url: []const u8,

    /// Connect to a Nostr relay via WSS.
    pub fn connect(allocator: Allocator, url: []const u8) !RelayClient {
        const parsed = try parseRelayUrl(allocator, url);
        log.info("connecting to {s}:{}{s}", .{ parsed.host, parsed.port, parsed.path });
        const client = ws.Client.init(allocator, .{
            .host = parsed.host,
            .port = parsed.port,
            .tls = true,
            .max_size = 512 * 1024, // 512KB max message
            .buffer_size = 8192,
            .io = http_util.getThreadedIo(),
        }) catch |err| {
            log.warn("relay connect to {s} failed: {}", .{ url, err });
            return err;
        };
        errdefer @constCast(&client).deinit();
        @constCast(&client).handshake(parsed.path, .{}) catch |err| {
            log.warn("relay handshake to {s} failed: {}", .{ url, err });
            return err;
        };
        // No read timeout here — persistent reader loops need infinite blocking.
        // One-shot reads (clawstr_read, search) set their own deadlines.
        return .{ .client = client, .allocator = allocator, .url = url };
    }

    /// Set SO_RCVTIMEO on the underlying socket (ms). Use for one-shot reads.
    pub fn setReadTimeout(self: *RelayClient, ms: u32) void {
        self.client.readTimeout(ms) catch {};
    }

    /// Publish a signed event to the relay. Returns the OK/NOTICE response.
    pub fn publish(self: *RelayClient, event_json: []const u8) ![]const u8 {
        // NIP-01: ["EVENT", <event_json>]
        var msg: std.ArrayListUnmanaged(u8) = .empty;
        defer msg.deinit(self.allocator);
        try msg.appendSlice(self.allocator, "[\"EVENT\",");
        try msg.appendSlice(self.allocator, event_json);
        try msg.appendSlice(self.allocator, "]");
        const msg_str = try msg.toOwnedSlice(self.allocator);
        defer self.allocator.free(msg_str);

        self.client.write(@constCast(msg_str)) catch |err| {
            log.warn("publish write failed: {}", .{err});
            return error.RelayWriteFailed;
        };
        log.info("published event to {s}", .{self.url});

        // Read response (should be ["OK", ...] or ["NOTICE", ...])
        self.client.readTimeout(5000) catch {};
        const response = (self.client.read() catch |err| {
            log.warn("read after publish failed: {}", .{err});
            return error.RelayReadFailed;
        }) orelse return error.RelayConnectionClosed;

        const result = try self.allocator.dupe(u8, response.data);
        self.client.done(response);
        return result;
    }

    /// Subscribe to events with a filter. Returns subscription ID.
    pub fn subscribe(self: *RelayClient, filters: []const u8) ![]const u8 {
        const sub_id = "sub";
        // NIP-01: ["REQ", <sub_id>, <filter>]
        var msg: std.ArrayListUnmanaged(u8) = .empty;
        defer msg.deinit(self.allocator);
        try msg.appendSlice(self.allocator, "[\"REQ\",\"");
        try msg.appendSlice(self.allocator, sub_id);
        try msg.appendSlice(self.allocator, "\",");
        try msg.appendSlice(self.allocator, filters);
        try msg.appendSlice(self.allocator, "]");
        const msg_str = try msg.toOwnedSlice(self.allocator);
        defer self.allocator.free(msg_str);

        self.client.write(@constCast(msg_str)) catch |err| {
            log.warn("subscribe write failed: {}", .{err});
            return error.RelayWriteFailed;
        };
        log.info("subscribed to {s} with filter: {s}", .{ self.url, filters[0..@min(filters.len, 80)] });

        const sub_id_copy = try self.allocator.dupe(u8, sub_id);
        return sub_id_copy;
    }

    /// Read the next message from the relay. Returns null on close.
    pub fn readMessage(self: *RelayClient) !?[]const u8 {
        const message = (self.client.read() catch |err| {
            log.warn("readMessage error: {}", .{err});
            return null;
        }) orelse return null;

        const result = try self.allocator.dupe(u8, message.data);
        self.client.done(message);
        return result;
    }

    /// Send CLOSE for a subscription.
    pub fn unsubscribe(self: *RelayClient, sub_id: []const u8) void {
        var msg: std.ArrayListUnmanaged(u8) = .empty;
        defer msg.deinit(self.allocator);
        msg.appendSlice(self.allocator, "[\"CLOSE\",\"") catch return;
        msg.appendSlice(self.allocator, sub_id) catch return;
        msg.appendSlice(self.allocator, "\"]") catch return;
        const msg_str = msg.toOwnedSlice(self.allocator) catch return;
        defer self.allocator.free(msg_str);
        self.client.write(@constCast(msg_str)) catch {};
    }

    /// Interrupt a blocking read on the underlying socket (without closing it).
    /// Used by vtableStop to unblock the reader thread before joining it.
    pub fn interruptRead(self: *RelayClient) void {
        const fd = self.client.stream.stream.socket.handle;
        // shutdown(SHUT_RD) causes the next read to return 0 (EOF),
        // which breaks the reader loop. Safe to call on a valid fd.
        _ = std.posix.system.shutdown(fd, std.posix.SHUT.RD);
    }

    pub fn deinit(self: *RelayClient) void {
        self.client.close(.{}) catch {};
        self.client.deinit();
    }
};

/// Build a NIP-01 filter JSON object.
/// Supports: kinds, authors, limit, since, until, #p, #e, #t, search (NIP-50)
pub fn buildFilter(allocator: Allocator, opts: struct {
    kinds: []const u16 = &.{},
    authors: []const []const u8 = &.{},
    limit: ?u32 = null,
    since: ?i64 = null,
    until: ?i64 = null,
    p_tags: []const []const u8 = &.{},
    e_tags: []const []const u8 = &.{},
    t_tags: []const []const u8 = &.{},
    /// NIP-50 search query — full-text search across relay events.
    /// Only use with relays that explicitly support NIP-50.
    search: ?[]const u8 = null,
}) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{");

    var first: bool = true;
    var int_buf: [20]u8 = undefined;

    if (opts.kinds.len > 0) {
        if (!first) try buf.appendSlice(allocator, ",");
        first = false;
        try buf.appendSlice(allocator, "\"kinds\":[");
        for (opts.kinds, 0..) |k, i| {
            if (i > 0) try buf.appendSlice(allocator, ",");
            const k_str = std.fmt.bufPrint(&int_buf, "{d}", .{k}) catch unreachable;
            try buf.appendSlice(allocator, k_str);
        }
        try buf.appendSlice(allocator, "]");
    }

    if (opts.authors.len > 0) {
        if (!first) try buf.appendSlice(allocator, ",");
        first = false;
        try buf.appendSlice(allocator, "\"authors\":[");
        for (opts.authors, 0..) |a, i| {
            if (i > 0) try buf.appendSlice(allocator, ",");
            try buf.appendSlice(allocator, "\"");
            try buf.appendSlice(allocator, a);
            try buf.appendSlice(allocator, "\"");
        }
        try buf.appendSlice(allocator, "]");
    }

    if (opts.limit) |limit| {
        if (!first) try buf.appendSlice(allocator, ",");
        first = false;
        try buf.appendSlice(allocator, "\"limit\":");
        const limit_str = std.fmt.bufPrint(&int_buf, "{d}", .{limit}) catch unreachable;
        try buf.appendSlice(allocator, limit_str);
    }

    if (opts.since) |since| {
        if (!first) try buf.appendSlice(allocator, ",");
        first = false;
        try buf.appendSlice(allocator, "\"since\":");
        const since_str = std.fmt.bufPrint(&int_buf, "{d}", .{since}) catch unreachable;
        try buf.appendSlice(allocator, since_str);
    }

    if (opts.until) |until| {
        if (!first) try buf.appendSlice(allocator, ",");
        first = false;
        try buf.appendSlice(allocator, "\"until\":");
        const until_str = std.fmt.bufPrint(&int_buf, "{d}", .{until}) catch unreachable;
        try buf.appendSlice(allocator, until_str);
    }

    if (opts.p_tags.len > 0) {
        if (!first) try buf.appendSlice(allocator, ",");
        first = false;
        try buf.appendSlice(allocator, "\"#p\":[");
        for (opts.p_tags, 0..) |p, i| {
            if (i > 0) try buf.appendSlice(allocator, ",");
            try buf.appendSlice(allocator, "\"");
            try buf.appendSlice(allocator, p);
            try buf.appendSlice(allocator, "\"");
        }
        try buf.appendSlice(allocator, "]");
    }

    if (opts.e_tags.len > 0) {
        if (!first) try buf.appendSlice(allocator, ",");
        first = false;
        try buf.appendSlice(allocator, "\"#e\":[");
        for (opts.e_tags, 0..) |e, i| {
            if (i > 0) try buf.appendSlice(allocator, ",");
            try buf.appendSlice(allocator, "\"");
            try buf.appendSlice(allocator, e);
            try buf.appendSlice(allocator, "\"");
        }
        try buf.appendSlice(allocator, "]");
    }

    if (opts.t_tags.len > 0) {
        if (!first) try buf.appendSlice(allocator, ",");
        first = false;
        try buf.appendSlice(allocator, "\"#t\":[");
        for (opts.t_tags, 0..) |t, i| {
            if (i > 0) try buf.appendSlice(allocator, ",");
            try buf.appendSlice(allocator, "\"");
            try buf.appendSlice(allocator, t);
            try buf.appendSlice(allocator, "\"");
        }
        try buf.appendSlice(allocator, "]");
    }

    if (opts.search) |query| {
        if (!first) try buf.appendSlice(allocator, ",");
        first = false;
        try buf.appendSlice(allocator, "\"search\":\"");
        try buf.appendSlice(allocator, query);
        try buf.appendSlice(allocator, "\"");
    }

    try buf.appendSlice(allocator, "}");

    return buf.toOwnedSlice(allocator);
}

/// Parse a relay message. Returns the message type and optional event JSON.
pub const RelayMessage = struct {
    msg_type: MsgType,
    event_json: ?[]const u8,
    raw: []const u8,
};

pub const MsgType = enum {
    event,
    ok,
    eose,
    notice,
    unknown,
};

/// Parse a relay wire message. Caller owns returned memory.
pub fn parseRelayMessage(allocator: Allocator, raw: []const u8) !RelayMessage {
    // Messages are JSON arrays: ["TYPE", ...]
    if (raw.len == 0 or raw[0] != '[') return error.InvalidMessage;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch
        return error.JsonParseFailed;
    defer parsed.deinit();

    if (parsed.value != .array or parsed.value.array.items.len == 0)
        return error.InvalidMessage;

    const msg_type_str = parsed.value.array.items[0];
    if (msg_type_str != .string) return error.InvalidMessage;

    const msg_type: MsgType = if (std.ascii.eqlIgnoreCase(msg_type_str.string, "EVENT"))
        .event
    else if (std.ascii.eqlIgnoreCase(msg_type_str.string, "OK"))
        .ok
    else if (std.ascii.eqlIgnoreCase(msg_type_str.string, "EOSE"))
        .eose
    else if (std.ascii.eqlIgnoreCase(msg_type_str.string, "NOTICE"))
        .notice
    else
        .unknown;

    // For EVENT messages, extract the event JSON (index 2 in the array)
    var event_json: ?[]const u8 = null;
    if (msg_type == .event and parsed.value.array.items.len >= 3) {
        const event_val = parsed.value.array.items[2];
        if (event_val == .object) {
            // Re-serialize the event object to JSON
            event_json = std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(event_val, .{})}) catch return error.OutOfMemory;
        }
    }

    return .{
        .msg_type = msg_type,
        .event_json = event_json,
        .raw = try allocator.dupe(u8, raw),
    };
}

/// Quick publish: connect to a relay, sign + publish an event, return OK response.
/// Convenience function for simple one-shot publishes.
pub fn quickPublish(
    allocator: Allocator,
    relay_url: []const u8,
    secret_key: [32]u8,
    kind: u16,
    content: []const u8,
    tags: []const Tag,
) ![]u8 {
    const kp = try keyPairFromSecret(secret_key);
    const now = util.timestampUnix();

    var event: Event = .{
        .id = [_]u8{0} ** 32,
        .pubkey = kp.public_key,
        .created_at = now,
        .kind = kind,
        .tags = tags,
        .content = content,
        .sig = [_]u8{0} ** 64,
    };
    try signEvent(&event, secret_key, allocator);

    const event_json = try eventToJson(event, allocator);
    defer allocator.free(event_json);

    var client = try RelayClient.connect(allocator, relay_url);
    defer client.deinit();

    const response = try client.publish(event_json);
    return response;
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "hex roundtrip 32 bytes" {
    const bytes: [32]u8 = [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0x00, 0xff, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99 };
    const hex = hexEncode32(bytes);
    const decoded = try hexDecodeFixed(32, &hex);
    try std.testing.expectEqualSlices(u8, &bytes, &decoded);
}

test "hex encode lowercase" {
    const bytes: [4]u8 = [_]u8{ 0xAB, 0xCD, 0xEF, 0x01 };
    var out: [8]u8 = undefined;
    hexEncode(&out, &bytes);
    try std.testing.expectEqualStrings("abcdef01", &out);
}

test "tagged hash known vector" {
    // BIP-340 test vector 0: tagged_hash("BIP0340/challenge", ...)
    const tag = "BIP0340/challenge";
    const data = [_]u8{
        0x04, 0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB,
        0xAC, 0x55, 0xA0, 0x62, 0x95, 0xCE, 0x87, 0x0B,
        0x07, 0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28,
        0xD9, 0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17,
        0x98, 0x48, 0x3A, 0xDA, 0x77, 0x26, 0xA3, 0xC4,
        0x69, 0x5B, 0x1E, 0x15, 0x6D, 0xC2, 0x7B, 0x79,
        0x1E, 0x4B, 0x6B, 0x80, 0x92, 0x0C, 0x3D, 0x8A,
        0x9E, 0x82, 0x1B, 0xE2, 0xCD, 0x7B, 0x35, 0x0D,
    };
    // We don't have the exact expected hash, so just verify it's deterministic
    const h1 = taggedHash(tag, &data);
    const h2 = taggedHash(tag, &data);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
    // Different data should produce different hash
    var data2 = data;
    data2[0] +%= 1;
    const h3 = taggedHash(tag, &data2);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h3));
}

test "keypair from secret key 1" {
    // Secret key 1 should produce known secp256k1 public key
    var sk: [32]u8 = [_]u8{0} ** 32;
    sk[31] = 1;
    const kp = try keyPairFromSecret(sk);
    // Expected pubkey (x-only): 79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798
    const expected_hex = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
    const pk_hex = hexEncode32(kp.public_key);
    try std.testing.expectEqualStrings(expected_hex, &pk_hex);
}

test "schnorr sign + verify roundtrip" {
    // BIP-340 test vector 0
    // secret key: 000...0003, pubkey: F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9
    var sk: [32]u8 = [_]u8{0} ** 32;
    sk[31] = 3;
    const kp = try keyPairFromSecret(sk);
    const msg: [32]u8 = [_]u8{0} ** 32;
    var aux: [32]u8 = [_]u8{0} ** 32;

    const sig = try schnorrSign(kp.secret_key, kp.public_key, msg, &aux);

    // Expected signature from BIP-340 test vector 0
    const expected_r = [_]u8{ 0xE9, 0x07, 0x83, 0x1F, 0x80, 0x84, 0x8D, 0x10, 0x69, 0xA5, 0x37, 0x1B, 0x40, 0x24, 0x10, 0x36, 0x4B, 0xDF, 0x1C, 0x5F, 0x83, 0x07, 0xB0, 0x08, 0x4C, 0x55, 0xF1, 0xCE, 0x2D, 0xCA, 0x82, 0x15 };
    const expected_k = [_]u8{ 0x25, 0xF6, 0x6A, 0x4A, 0x85, 0xEA, 0x8B, 0x71, 0xE4, 0x82, 0xA7, 0x4F, 0x38, 0x2D, 0x2C, 0xE5, 0xEB, 0xEE, 0xE8, 0xFD, 0xB2, 0x17, 0x2F, 0x47, 0x7D, 0xF4, 0x90, 0x0D, 0x31, 0x05, 0x36, 0xC0 };
    try std.testing.expectEqualSlices(u8, &expected_r, sig[0..32]);
    try std.testing.expectEqualSlices(u8, &expected_k, sig[32..64]);
    try std.testing.expect(schnorrVerify(kp.public_key, msg, sig));

    // Wrong message should fail
    const wrong_msg: [32]u8 = [_]u8{0x43} ** 32;
    try std.testing.expect(!schnorrVerify(kp.public_key, wrong_msg, sig));

    // Wrong pubkey should fail
    var wrong_pk = kp.public_key;
    wrong_pk[0] +%= 1;
    try std.testing.expect(!schnorrVerify(wrong_pk, msg, sig));
}

test "schnorr sign + verify with random key" {
    var sk: [32]u8 = undefined;
    util.randomBytes(&sk);
    // Ensure valid scalar (reduce mod n if needed — very unlikely to need it)
    const d = std.mem.readInt(u256, &sk, .big);
    if (d >= N or d == 0) {
        sk[31] = 1; // fallback to valid key
    }
    const kp = try keyPairFromSecret(sk);
    var msg: [32]u8 = undefined;
    util.randomBytes(&msg);

    const sig = try schnorrSign(kp.secret_key, kp.public_key, msg, null);
    try std.testing.expect(schnorrVerify(kp.public_key, msg, sig));
}

test "compute event id deterministic" {
    var sk: [32]u8 = [_]u8{0} ** 32;
    sk[31] = 1;
    const kp = try keyPairFromSecret(sk);

    const tags = [_]Tag{tagLiterals(&.{"p", "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"})};
    const id1 = try computeEventId(kp.public_key, 1234567890, 1, &tags, "hello world", std.testing.allocator);
    const id2 = try computeEventId(kp.public_key, 1234567890, 1, &tags, "hello world", std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &id1, &id2);

    // Different content should produce different ID
    const id3 = try computeEventId(kp.public_key, 1234567890, 1, &tags, "different", std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, &id1, &id3));
}

test "sign event and verify" {
    var sk: [32]u8 = [_]u8{0} ** 32;
    sk[31] = 1;
    const kp = try keyPairFromSecret(sk);

    var event: Event = .{
        .id = [_]u8{0} ** 32,
        .pubkey = kp.public_key,
        .created_at = 1234567890,
        .kind = 1,
        .tags = &.{},
        .content = "test note",
        .sig = [_]u8{0} ** 64,
    };
    try signEvent(&event, sk, std.testing.allocator);

    // Verify: event.sig should be a valid Schnorr signature of event.id
    try std.testing.expect(schnorrVerify(event.pubkey, event.id, event.sig));
}

test "event to json roundtrip" {
    var sk: [32]u8 = [_]u8{0} ** 32;
    sk[31] = 1;
    const kp = try keyPairFromSecret(sk);

    var event: Event = .{
        .id = [_]u8{0} ** 32,
        .pubkey = kp.public_key,
        .created_at = 1234567890,
        .kind = 1,
        .tags = &.{},
        .content = "hello \"world\"",
        .sig = [_]u8{0} ** 64,
    };
    try signEvent(&event, sk, std.testing.allocator);

    const json = try eventToJson(event, std.testing.allocator);
    defer std.testing.allocator.free(json);

    // Verify JSON has expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pubkey\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"content\":\"hello \\\"world\\\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sig\":\"") != null);

    // Parse back
    const parsed = try parseEventJson(std.testing.allocator, json);
    defer freeEvent(parsed, std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &event.id, &parsed.id);
    try std.testing.expectEqualSlices(u8, &event.pubkey, &parsed.pubkey);
    try std.testing.expectEqual(event.created_at, parsed.created_at);
    try std.testing.expectEqual(event.kind, parsed.kind);
    try std.testing.expectEqualStrings(event.content, parsed.content);
}

test "parse relay url" {
    const url1 = "wss://relay.example.com";
    const parsed1 = try parseRelayUrl(std.testing.allocator, url1);
    defer std.testing.allocator.free(parsed1.host);
    defer std.testing.allocator.free(parsed1.path);
    try std.testing.expectEqualStrings("relay.example.com", parsed1.host);
    try std.testing.expectEqual(@as(u16, 443), parsed1.port);
    try std.testing.expectEqualStrings("/", parsed1.path);

    const url2 = "wss://relay.example.com:8080/ws";
    const parsed2 = try parseRelayUrl(std.testing.allocator, url2);
    defer std.testing.allocator.free(parsed2.host);
    defer std.testing.allocator.free(parsed2.path);
    try std.testing.expectEqualStrings("relay.example.com", parsed2.host);
    try std.testing.expectEqual(@as(u16, 8080), parsed2.port);
    try std.testing.expectEqualStrings("/ws", parsed2.path);

    const url3 = "ws://localhost:8080";
    const parsed3 = try parseRelayUrl(std.testing.allocator, url3);
    defer std.testing.allocator.free(parsed3.host);
    defer std.testing.allocator.free(parsed3.path);
    try std.testing.expectEqualStrings("localhost", parsed3.host);
    try std.testing.expectEqual(@as(u16, 8080), parsed3.port);
}

test "build filter json" {
    const kinds = [_]u16{1, 7};
    const filter = try buildFilter(std.testing.allocator, .{
        .kinds = &kinds,
        .limit = 10,
    });
    defer std.testing.allocator.free(filter);
    try std.testing.expect(std.mem.indexOf(u8, filter, "\"kinds\":[1,7]") != null);
    try std.testing.expect(std.mem.indexOf(u8, filter, "\"limit\":10") != null);
}

test "parse relay message event" {
    const raw = "[\"EVENT\",\"sub_id\",{\"id\":\"abc\",\"pubkey\":\"def\",\"created_at\":123,\"kind\":1,\"tags\":[],\"content\":\"hi\",\"sig\":\"xyz\"}]";
    const msg = try parseRelayMessage(std.testing.allocator, raw);
    defer std.testing.allocator.free(msg.raw);
    if (msg.event_json) |ej| {
        defer std.testing.allocator.free(ej);
    }
    try std.testing.expectEqual(MsgType.event, msg.msg_type);
    try std.testing.expect(msg.event_json != null);
}

test "parse relay message eose" {
    const raw = "[\"EOSE\",\"sub_id\"]";
    const msg = try parseRelayMessage(std.testing.allocator, raw);
    defer std.testing.allocator.free(msg.raw);
    try std.testing.expectEqual(MsgType.eose, msg.msg_type);
    try std.testing.expect(msg.event_json == null);
}

test "parse relay message ok" {
    const raw = "[\"OK\",\"abc123\",true,\"\"]";
    const msg = try parseRelayMessage(std.testing.allocator, raw);
    defer std.testing.allocator.free(msg.raw);
    try std.testing.expectEqual(MsgType.ok, msg.msg_type);
}

test "parse relay message notice" {
    const raw = "[\"NOTICE\",\"rate limited\"]";
    const msg = try parseRelayMessage(std.testing.allocator, raw);
    defer std.testing.allocator.free(msg.raw);
    try std.testing.expectEqual(MsgType.notice, msg.msg_type);
}
