# Plan: nostr_public Channel for NullClaw

## Goal

Add a new `nostr_public` channel adapter that listens to public Nostr notes
(kind 1) and agent coordination events (kinds 7201, 7203, 7204), routing them
into the agent's event bus as primary input context — same as Telegram messages.

The existing `nostr` channel handles DMs only (NIP-17 gift wraps, NIP-04).
This new channel handles the public feed. Both can run simultaneously.

## Architecture

```
Relay ──kind 1,7201,7203,7204──> nak req --stream ──stdout──> reader thread
                                                               │
                                                               ▼
                                                        filter/dedup
                                                               │
                                                               ▼
                                                        event_bus.publish
                                                               │
                                                               ▼
                                                     agent routing (same as telegram)
                                                               │
Agent reply ────────────────────────────────────> nak event -k 1 ──> Relay
```

## Files to Change

### 1. NEW: `src/channels/nostr_public.zig` (~250 lines)

New channel type `NostrPublicChannel` implementing the Channel vtable:

- `init()` / `initFromConfig()` — store config, allocator
- `deinit()` — free seen_ids, signing_sec
- `vtableStart()`:
  1. Decrypt signing key via SecretStore (same as nostr.zig)
  2. Spawn `nak req --stream -k 1 -k 7201 -k 7203 -k 7204 <relays...>`
  3. Spawn reader thread processing stdout line by line
  4. Filter by `listen_kinds`, optional `keywords`, optional `mention_name`
  5. Dedup via `seen_ids` set
  6. Publish matching events as `ChannelMessage` to event_bus
- `vtableStop()`:
  1. Set running = false
  2. Kill listener subprocess
  3. Join reader thread
  4. Zero/free signing_sec
- `vtableSend()`:
  - `nak event -k 1 --sec <sec> -t p=<recipient> -c <content> <relays...>`
- `vtableName()` → "nostr_public"
- `vtableHealthCheck()` → listener child still alive + running flag

Key differences from nostr.zig:
- No NIP-17 gift wrap/unwrap (public notes, no encryption)
- No NIP-04 encrypt/decrypt
- No DM protocol mirroring
- No inbox relay lookup
- Simpler: just kind 1 public notes + coordination kinds
- Optional keyword/mention filtering (nostr.zig has no filtering — all DMs are relevant)

### 2. MODIFY: `src/config_types.zig`

Add `NostrPublicConfig` struct:

```zig
pub const NostrPublicConfig = struct {
    /// enc2:-encrypted private key for signing replies.
    private_key: []const u8 = "",
    /// Relay URLs for listening and publishing.
    relays: []const []const u8 = &.{
        "wss://nostr-relay-production.up.railway.app",
    },
    /// Which event kinds to listen to (default: public notes + coordination).
    listen_kinds: []const u16 = &.{ 1, 7201, 7203, 7204 },
    /// Only process notes containing at least one of these keywords (empty = all).
    keywords: []const []const u8 = &.{},
    /// Only process notes mentioning this display name (empty = no mention filter).
    mention_name: []const u8 = "",
    /// Only process notes from these pubkeys (empty = allow all senders).
    allowed_pubkeys: []const []const u8 = &.{},
    /// Path to the nak binary.
    nak_path: []const u8 = "nak",
    /// Directory containing the config file and .secret_key.
    config_dir: []const u8 = ".",
};
```

Add to `ChannelsConfig`:
```zig
nostr_public: ?*NostrPublicConfig = null,
```

### 3. MODIFY: `src/channels/root.zig`

Add import:
```zig
pub const nostr_public = @import("nostr_public.zig");
```

### 4. MODIFY: `src/channel_catalog.zig`

- Add `nostr_public` to `ChannelId` enum
- Add entry to `known_channels` array (listener_mode: .gateway_loop)
- Add `nostr_public` case to `isBuildEnabled()`
- Add `nostr_public` case to `isBuildEnabledByKey()`
- Add `nostr_public` case to `configuredCount()`

### 5. MODIFY: `build.zig`

- Add `enable_channel_nostr_public: bool = false` to `ChannelSelection`
- Add `self.enable_channel_nostr_public = true` in `enableAll()`
- Add parse case in `parseChannelsOption()`
- Add `build_options.addOption(bool, "enable_channel_nostr_public", ...)` in build step

### 6. CONFIG: `~/.nullclaw/config.json`

Add section:
```json
"nostr_public": {
  "relays": ["wss://nostr-relay-production.up.railway.app"],
  "listen_kinds": [1, 7201, 7203, 7204],
  "keywords": ["near", "agent", "inlayer", "rust", "wasm"],
  "mention_name": "NullGork",
  "private_key": "enc2:...",
  "nak_path": "nak"
}
```

## Event Flow

1. `nak req --stream -k 1 -k 7201 -k 7203 -k 7204 <relays...>` streams JSON events
2. Reader thread parses each line for `pubkey`, `content`, `created_at`, `id`, `kind`
3. Dedup: skip if `id` already in `seen_ids`
4. Filter:
   - Skip if kind not in `listen_kinds`
   - Skip if `mention_name` set and not found in content (case-insensitive)
   - Skip if `keywords` set and none found in content (case-insensitive)
   - Skip if `allowed_pubkeys` set and sender not in list
5. Publish `ChannelMessage` to event_bus:
   - `sender` = pubkey (hex, first 12 chars for display)
   - `content` = note content
   - `channel` = "nostr_public"
   - `reply_target` = full pubkey (for p-tag replies)
6. Agent processes via normal routing (same as Telegram message)
7. Reply sent via `nak event -k 1 --sec <sec> -t p=<pubkey> -c <content> <relays...>`

## Implementation Order

1. `src/config_types.zig` — NostrPublicConfig + ChannelsConfig field
2. `src/channels/nostr_public.zig` — full channel implementation
3. `src/channels/root.zig` — import
4. `src/channel_catalog.zig` — catalog entry + build flags
5. `build.zig` — build option
6. Build and test
7. Update config
