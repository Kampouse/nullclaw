//! NIP-44 v2 encryption for Nostr sealed messages.
//!
//! Reference: https://github.com/nostr-protocol/nips/blob/master/44.md
//! Reference impl: src/security/nip44-ref/nip44.ts (nostr-tools)
//!
//! Uses secp256k1 ECDH (not X25519) for key agreement, ChaCha20-IETF
//! stream cipher, and HMAC-SHA256 for authentication.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Secp256k1 = std.crypto.ecc.Secp256k1;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const ChaCha20IETF = std.crypto.stream.chacha.ChaCha20IETF;

const nostr = @import("../nostr.zig");
const util = @import("../util.zig");

const log = std.log.scoped(.nip44);

// ═══════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════

const min_plaintext_size: u32 = 0x0001;
const max_plaintext_size: u32 = 0xffffffff;
const extended_prefix_threshold: u32 = 0x10000; // 65536

const HKDF_SALT = "nip44-v2";
const HKDF_INFO_LEN: usize = 76; // 32 (chacha_key) + 12 (chacha_nonce) + 32 (hmac_key)

// ═══════════════════════════════════════════════════════════════
// Errors
// ═══════════════════════════════════════════════════════════════

pub const Nip44Error = error{
    InvalidPayloadLength,
    InvalidBase64,
    UnknownVersion,
    InvalidPadding,
    InvalidMac,
    InvalidKeyLength,
    PlaintextTooLarge,
    PlaintextEmpty,
    InvalidHex,
};

// ═══════════════════════════════════════════════════════════════
// Base64 (standard with padding)
// ═══════════════════════════════════════════════════════════════

const b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn base64Encode(allocator: Allocator, data: []const u8) ![]u8 {
    const out_len = ((data.len + 2) / 3) * 4;
    const out = try allocator.alloc(u8, out_len);
    var i: usize = 0;
    var j: usize = 0;
    while (i + 2 < data.len) : (i += 3) {
        const triple = (@as(u32, data[i]) << 16) | (@as(u32, data[i + 1]) << 8) | data[i + 2];
        out[j] = b64_chars[(triple >> 18) & 0x3F];
        out[j + 1] = b64_chars[(triple >> 12) & 0x3F];
        out[j + 2] = b64_chars[(triple >> 6) & 0x3F];
        out[j + 3] = b64_chars[triple & 0x3F];
        j += 4;
    }
    if (i + 1 == data.len) {
        const pair = @as(u32, data[i]) << 16;
        out[j] = b64_chars[(pair >> 18) & 0x3F];
        out[j + 1] = b64_chars[(pair >> 12) & 0x3F];
        out[j + 2] = '=';
        out[j + 3] = '=';
        j += 4;
    } else if (i + 2 == data.len) {
        const pair = (@as(u32, data[i]) << 16) | (@as(u32, data[i + 1]) << 8);
        out[j] = b64_chars[(pair >> 18) & 0x3F];
        out[j + 1] = b64_chars[(pair >> 12) & 0x3F];
        out[j + 2] = b64_chars[(pair >> 6) & 0x3F];
        out[j + 3] = '=';
        j += 4;
    }
    return out[0..j];
}

fn base64Val(c: u8) ?u6 {
    return switch (c) {
        'A'...'Z' => @intCast(c - 'A'),
        'a'...'z' => @intCast(c - 'a' + 26),
        '0'...'9' => @intCast(c - '0' + 52),
        '+' => 62,
        '/' => 63,
        else => null,
    };
}

pub fn base64Decode(allocator: Allocator, encoded: []const u8) ![]u8 {
    var data_chars: usize = 0;
    for (encoded) |c| {
        if (c == '=' or c == '\n' or c == '\r' or c == ' ') continue;
        data_chars += 1;
    }
    const full_groups = data_chars / 4;
    const remainder = data_chars % 4;
    var out_len = full_groups * 3;
    if (remainder == 3) out_len += 2 else if (remainder == 2) out_len += 1;

    const out = try allocator.alloc(u8, out_len);
    var buf: [4]u6 = undefined;
    var buf_len: usize = 0;
    var o: usize = 0;
    for (encoded) |c| {
        if (c == '=' or c == '\n' or c == '\r' or c == ' ') continue;
        const val = base64Val(c) orelse return Nip44Error.InvalidBase64;
        buf[buf_len] = val;
        buf_len += 1;
        if (buf_len == 4) {
            const triple = (@as(u32, buf[0]) << 18) | (@as(u32, buf[1]) << 12) | (@as(u32, buf[2]) << 6) | buf[3];
            out[o] = @truncate((triple >> 16) & 0xFF);
            out[o + 1] = @truncate((triple >> 8) & 0xFF);
            out[o + 2] = @truncate(triple & 0xFF);
            o += 3;
            buf_len = 0;
        }
    }
    if (buf_len == 3) {
        const triple = (@as(u32, buf[0]) << 18) | (@as(u32, buf[1]) << 12) | (@as(u32, buf[2]) << 6);
        out[o] = @truncate((triple >> 16) & 0xFF);
        out[o + 1] = @truncate((triple >> 8) & 0xFF);
        o += 2;
    } else if (buf_len == 2) {
        const triple = (@as(u32, buf[0]) << 18) | (@as(u32, buf[1]) << 12);
        out[o] = @truncate((triple >> 16) & 0xFF);
        o += 1;
    }
    return out[0..o];
}

// ═══════════════════════════════════════════════════════════════
// Padding
// ═══════════════════════════════════════════════════════════════

pub fn calcPaddedLen(len: u32) u32 {
    if (len <= 32) return 32;
    const log2 = std.math.log2_int(u32, len - 1);
    const next_power = @as(u32, 1) << (log2 + 1);
    const chunk: u32 = if (next_power <= 256) 32 else next_power / 8;
    return chunk * ((len - 1) / chunk + 1);
}

// ═══════════════════════════════════════════════════════════════
// Key derivation
// ═══════════════════════════════════════════════════════════════

/// Derive NIP-44 conversation key from a 32-byte private key and
/// a 32-byte raw public key (x-only, as used in Nostr).
pub fn getConversationKey(privkey: [32]u8, pubkey_bytes: [32]u8) ![32]u8 {
    // Build compressed point: 0x02 || pubkey_bytes
    var sec1_buf: [33]u8 = undefined;
    sec1_buf[0] = 0x02;
    @memcpy(sec1_buf[1..33], &pubkey_bytes);

    // ECDH: shared = privkey * recipient_pubkey_point
    const recipient_point = Secp256k1.fromSec1(&sec1_buf) catch
        return Nip44Error.InvalidHex;
    const shared_point = Secp256k1.mul(recipient_point, privkey, .big) catch
        return Nip44Error.InvalidHex;

    // Extract x-coordinate from compressed form
    const shared_sec1 = Secp256k1.toCompressedSec1(shared_point);
    const shared_x = shared_sec1[1..33].*;

    // HKDF-Extract: PRK = HMAC-SHA256(salt="nip44-v2", shared_x)
    const prk = HkdfSha256.extract(HKDF_SALT, &shared_x);
    return prk;
}

// ═══════════════════════════════════════════════════════════════
// Message keys (internal)
// ═══════════════════════════════════════════════════════════════

const MessageKeys = struct {
    chacha_key: [32]u8,
    chacha_nonce: [12]u8,
    hmac_key: [32]u8,
};

pub fn getMessageKeys(conversation_key: [32]u8, nonce: [32]u8) MessageKeys {
    var out: [HKDF_INFO_LEN]u8 = undefined;
    HkdfSha256.expand(&out, &nonce, conversation_key);
    return .{
        .chacha_key = out[0..32].*,
        .chacha_nonce = out[32..44].*,
        .hmac_key = out[44..76].*,
    };
}

// ═══════════════════════════════════════════════════════════════
// HMAC-AAD
// ═══════════════════════════════════════════════════════════════

pub fn hmacAad(key: [32]u8, message: []const u8, aad: [32]u8) [32]u8 {
    var h = HmacSha256.init(&key);
    h.update(&aad);
    h.update(message);
    var mac: [32]u8 = undefined;
    h.final(&mac);
    return mac;
}

// ═══════════════════════════════════════════════════════════════
// Encrypt / Decrypt
// ═══════════════════════════════════════════════════════════════

/// Encrypt a plaintext using NIP-44 v2. Returns base64-encoded string.
/// If nonce is null, random bytes are generated.
pub fn encrypt(allocator: Allocator, plaintext: []const u8, conversation_key: [32]u8, nonce: ?[32]u8) ![]u8 {
    const actual_nonce = nonce orelse blk: {
        var n: [32]u8 = undefined;
        util.randomBytes(&n);
        break :blk n;
    };

    if (plaintext.len == 0) return Nip44Error.PlaintextEmpty;
    if (plaintext.len > max_plaintext_size) return Nip44Error.PlaintextTooLarge;

    const keys = getMessageKeys(conversation_key, actual_nonce);
    const padded = try pad(allocator, plaintext);

    // ChaCha20-IETF stream cipher XOR (counter=0)
    ChaCha20IETF.xor(padded, padded, 0, keys.chacha_key, keys.chacha_nonce);

    // HMAC-SHA256(hmac_key, nonce || ciphertext)
    const mac = hmacAad(keys.hmac_key, padded, actual_nonce);

    // Build: version(1) || nonce(32) || ciphertext || mac(32)
    const payload_len = 1 + 32 + padded.len + 32;
    const payload = try allocator.alloc(u8, payload_len);
    payload[0] = 2;
    @memcpy(payload[1..33], &actual_nonce);
    @memcpy(payload[33 .. 33 + padded.len], padded);
    const mac_off = 33 + padded.len;
    @memcpy(payload[mac_off .. mac_off + 32], &mac);

    const encoded = try base64Encode(allocator, payload);
    allocator.free(payload);
    allocator.free(padded);
    return encoded;
}

/// Decrypt a NIP-44 v2 base64-encoded payload.
pub fn decrypt(allocator: Allocator, payload_b64: []const u8, conversation_key: [32]u8) ![]u8 {
    const data = try base64Decode(allocator, payload_b64);
    defer allocator.free(data);

    if (data.len < 99) return Nip44Error.InvalidPayloadLength;
    if (data[0] != 2) return Nip44Error.UnknownVersion;

    const nonce = data[1..33].*;
    const ciphertext = data[33 .. data.len - 32];
    var mac: [32]u8 = undefined;
    @memcpy(&mac, data[data.len - 32 ..]);

    const keys = getMessageKeys(conversation_key, nonce);

    // Verify MAC
    const calculated_mac = hmacAad(keys.hmac_key, ciphertext, nonce);
    if (!std.mem.eql(u8, &calculated_mac, &mac)) return Nip44Error.InvalidMac;

    // ChaCha20 XOR (stream cipher is its own inverse)
    const padded = try allocator.dupe(u8, ciphertext);
    ChaCha20IETF.xor(padded, padded, 0, keys.chacha_key, keys.chacha_nonce);
    const result = try unpad(allocator, padded);
    allocator.free(padded);
    return result;
}

// ═══════════════════════════════════════════════════════════════
// Padding (internal)
// ═══════════════════════════════════════════════════════════════

fn pad(allocator: Allocator, plaintext: []const u8) ![]u8 {
    const unpadded_len: u32 = @intCast(plaintext.len);
    if (unpadded_len < min_plaintext_size or unpadded_len > max_plaintext_size)
        return Nip44Error.PlaintextEmpty;

    const padded_len = calcPaddedLen(unpadded_len);
    const prefix_len: usize = if (unpadded_len >= extended_prefix_threshold) 6 else 2;
    const total = prefix_len + @as(usize, padded_len);
    const out = try allocator.alloc(u8, total);
    @memset(out, 0);

    if (unpadded_len >= extended_prefix_threshold) {
        out[0] = 0;
        out[1] = 0;
        std.mem.writeInt(u32, out[2..6], unpadded_len, .big);
    } else {
        std.mem.writeInt(u16, out[0..2], @intCast(unpadded_len), .big);
    }

    @memcpy(out[prefix_len .. prefix_len + plaintext.len], plaintext);
    return out;
}

fn unpad(allocator: Allocator, padded: []const u8) ![]u8 {
    if (padded.len < 2) return Nip44Error.InvalidPadding;

    const first_two = std.mem.readInt(u16, padded[0..2], .big);
    var unpadded_len: u32 = 0;
    var prefix_len: usize = 0;

    if (first_two == 0) {
        if (padded.len < 6) return Nip44Error.InvalidPadding;
        unpadded_len = std.mem.readInt(u32, padded[2..6], .big);
        if (unpadded_len < extended_prefix_threshold) return Nip44Error.InvalidPadding;
        prefix_len = 6;
    } else {
        unpadded_len = first_two;
        prefix_len = 2;
    }

    if (unpadded_len < min_plaintext_size or unpadded_len > max_plaintext_size)
        return Nip44Error.InvalidPadding;
    if (prefix_len + unpadded_len > padded.len)
        return Nip44Error.InvalidPadding;
    if (padded.len != prefix_len + calcPaddedLen(unpadded_len))
        return Nip44Error.InvalidPadding;

    return allocator.dupe(u8, padded[prefix_len .. prefix_len + unpadded_len]);
}

// ═══════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════

test "calcPaddedLen matches reference" {
    try std.testing.expectEqual(@as(u32, 32), calcPaddedLen(1));
    try std.testing.expectEqual(@as(u32, 32), calcPaddedLen(32));
    try std.testing.expectEqual(@as(u32, 64), calcPaddedLen(33));
    try std.testing.expectEqual(@as(u32, 256), calcPaddedLen(256));
    try std.testing.expectEqual(@as(u32, 1024), calcPaddedLen(1000));
    try std.testing.expectEqual(@as(u32, 65536), calcPaddedLen(65535));
    try std.testing.expectEqual(@as(u32, 65536), calcPaddedLen(65536));
    try std.testing.expectEqual(@as(u32, 81920), calcPaddedLen(65537));
}

test "getConversationKey vector 0" {
    const sec1 = try nostr.hexDecodeFixed(32, "315e59ff51cb9209768cf7da80791ddcaae56ac9775eb25b6dee1234bc5d2268");
    const pub2 = try nostr.hexDecodeFixed(32, "c2f9d9948dc8c7c38321e4b85c8558872eafa0641cd269db76848a6073e69133");
    const expected = try nostr.hexDecodeFixed(32, "3dfef0ce2a4d80a25e7a328accf73448ef67096f65f79588e358d9a0eb9013f1");

    const conv_key = try getConversationKey(sec1, pub2);
    try std.testing.expectEqual(expected, conv_key);
}

test "getConversationKey vector 1 (sec1=1, sec2=2)" {
    const sec1 = [_]u8{0} ** 31 ++ [_]u8{1};
    const pub2 = try nostr.hexDecodeFixed(32, "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5");
    const expected = try nostr.hexDecodeFixed(32, "c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d");

    const conv_key = try getConversationKey(sec1, pub2);
    try std.testing.expectEqual(expected, conv_key);
}

test "encrypt/decrypt round-trip" {
    const sec1 = try nostr.hexDecodeFixed(32, "315e59ff51cb9209768cf7da80791ddcaae56ac9775eb25b6dee1234bc5d2268");
    const pub2 = try nostr.hexDecodeFixed(32, "c2f9d9948dc8c7c38321e4b85c8558872eafa0641cd269db76848a6073e69133");

    const conv_key = try getConversationKey(sec1, pub2);

    const plaintext = "hello from nullclaw!";
    const encrypted = try encrypt(std.testing.allocator, plaintext, conv_key, null);
    defer std.testing.allocator.free(encrypted);

    const decrypted = try decrypt(std.testing.allocator, encrypted, conv_key);
    defer std.testing.allocator.free(decrypted);

    try std.testing.expectEqualStrings(plaintext, decrypted);
}

// ═══════════════════════════════════════════════════════════════
// Cross-implementation tests (nostr-tools reference vectors)
// Generated with: node gen-vectors.js using nostr-tools v2.7.x
// ═══════════════════════════════════════════════════════════════

test "nip44 cross-impl: conversation key (nostr-tools reference)" {
    // sender: nsec1p0ht6p3wepe47sjrgesyn4m50m6avk2waqudu9rl324cg2c4ufesyp6rdg
    // recipient: nsec1uyyrnx7cgfp40fcskcr2urqnzekc20fj0er6de0q8qvhx34ahazsvs9p36
    const sender_priv = try nostr.hexDecodeFixed(32, "0beebd062ec8735f4243466049d7747ef5d6594ee838de147f8aab842b15e273");
    const recipient_pub = try nostr.hexDecodeFixed(32, "166bf3765ebd1fc55decfe395beff2ea3b2a4e0a8946e7eb578512b555737c99");
    const expected = try nostr.hexDecodeFixed(32, "3665e8fae510c7b811db64f2305fd2e5d0706465b80c170f2614ddbc2b12b489");

    const conv_key = try getConversationKey(sender_priv, recipient_pub);
    try std.testing.expectEqual(expected, conv_key);
}

test "nip44 cross-impl: encrypt with known nonce matches nostr-tools" {
    // Same keys, nonce = 0x01 followed by 31 zero bytes
    const sender_priv = try nostr.hexDecodeFixed(32, "0beebd062ec8735f4243466049d7747ef5d6594ee838de147f8aab842b15e273");
    const recipient_pub = try nostr.hexDecodeFixed(32, "166bf3765ebd1fc55decfe395beff2ea3b2a4e0a8946e7eb578512b555737c99");
    const conv_key = try getConversationKey(sender_priv, recipient_pub);

    const nonce: [32]u8 = [_]u8{1} ++ [_]u8{0} ** 31;
    const plaintext = "hello nullclaw";

    const encrypted = try encrypt(std.testing.allocator, plaintext, conv_key, nonce);
    defer std.testing.allocator.free(encrypted);

    // Debug: print what we got vs expected
    const expected = "AgEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAASv/+x4l7JOsmW5Fgptjx7qY52enLkvzunDYiyc+XVuIHu6akwpM6tT9e59k1HWxRb6GZmLYzMqe1q0szlW3hjKcr";
    try std.testing.expectEqualStrings(expected, encrypted);
}

test "nip44 cross-impl: encrypt 'a' with zero nonce matches nostr-tools" {
    const sender_priv = try nostr.hexDecodeFixed(32, "0beebd062ec8735f4243466049d7747ef5d6594ee838de147f8aab842b15e273");
    const recipient_pub = try nostr.hexDecodeFixed(32, "166bf3765ebd1fc55decfe395beff2ea3b2a4e0a8946e7eb578512b555737c99");
    const conv_key = try getConversationKey(sender_priv, recipient_pub);

    const nonce: [32]u8 = [_]u8{0} ** 32;
    const encrypted = try encrypt(std.testing.allocator, "a", conv_key, nonce);
    defer std.testing.allocator.free(encrypted);

    const expected = "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAylJpbX9z0SwgCkfUcNC8v2WcvpM3h/LTL4YpuicotW9EK9LxgTMLiQnWozUzM1GPEYBo2x83omz+pRjZ5WZSZOBj";
    try std.testing.expectEqualStrings(expected, encrypted);
}

test "nip44 cross-impl: decrypt nostr-tools output" {
    const sender_priv = try nostr.hexDecodeFixed(32, "0beebd062ec8735f4243466049d7747ef5d6594ee838de147f8aab842b15e273");
    const recipient_pub = try nostr.hexDecodeFixed(32, "166bf3765ebd1fc55decfe395beff2ea3b2a4e0a8946e7eb578512b555737c99");
    const conv_key = try getConversationKey(sender_priv, recipient_pub);

    // nostr-tools encrypted output for "Are you going to the party tonight?"
    const nostr_tools_encrypted = "AmhXJm76Q/qp4xfkXz7jPcRWRo+JyGwU5jLK58GrzRbKfcozBAa4AA+YPBQpHa4AWY96xpkEJWtSR5y0YiaQiH9lxJ1lV3BQS5hzfSjgCquRmPMep38Z+GoAdNt17FDt9SmGYALtiu8EKgJI02JeiuUxRUFGM3fHQ6/12ZV8uEnTd/c=";

    const decrypted = try decrypt(std.testing.allocator, nostr_tools_encrypted, conv_key);
    defer std.testing.allocator.free(decrypted);

    try std.testing.expectEqualStrings("Are you going to the party tonight?", decrypted);
}
