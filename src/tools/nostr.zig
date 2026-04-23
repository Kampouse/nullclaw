// Nostr Tool — native Nostr operations for the agent.
//
// Actions:
//   post           — Publish a kind 1 text note to relay(s)
//   read           — Subscribe to relay(s) and read events matching filters
//   search         — NIP-50 full-text search across relay events
//   profile        — Publish a kind 0 metadata event (name, about, picture)
//   react          — Publish a kind 7 reaction to an event
//   channel_create — NIP-28: Create a channel (kind 40)
//   channel_send   — NIP-28: Send a message to a channel (kind 42)
//   channel_read   — NIP-28: Read messages from a channel (kinds 41, 42)
//
// Uses BIP-340 Schnorr signing + WebSocket relay connections — zero nak dependency.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const nostr = @import("../nostr.zig");
const util = @import("../util.zig");

const log = std.log.scoped(.nostr_tool);

/// Default relay if none configured.
const DEFAULT_RELAY = "wss://relay.ditto.pub";

/// Well-known public relays for read/post (no NIP-50 required).
/// Selected for reliability, speed, and open write access (no auth/payment).
/// Ordered by handshake latency (fastest first). Refreshed via NIP-65 relay list
/// discovery from fiatjaf, jb55, and live latency testing.
const WELL_KNOWN_RELAYS = [_][]const u8{
    "wss://relay.spacetomatoes.net",
    "wss://nostr-relay.moe.gift",
    "wss://relay.cloistr.xyz",
    "wss://dm.czas.xyz",
    "wss://cdn.czas.xyz",
    "wss://relay.damus.io",
    "wss://relay.44billion.net",
    "wss://relay.ditto.pub",
    "wss://relay.og.coop",
    "wss://relay.gulugulu.moe",
    "wss://henhouse.social/relay",
    "wss://relay.primal.net",
    "wss://relay.crostr.com",
    "wss://private.nostr.bar",
    "wss://relay.nostrverse.net",
    "wss://relay.nostr.net",
    "wss://nos.lol",
};

/// Relays confirmed to support NIP-50 full-text search.
/// Tested live — all returned search results for "bitcoin" queries.
/// Dead relays removed (orly-relay.imwald.eu, nostr.wine, us.nostr.wine).
const SEARCH_RELAYS = [_][]const u8{
    "wss://relay.noswhere.com",
    "wss://nostrja-kari-nip50.heguro.com",
    "wss://relay.ditto.pub",
    "wss://cobrafuma.com/relay",
    "wss://relay.gulugulu.moe",
    "wss://relay.spacetomatoes.net",
    "wss://relay2.veganostr.com",
    "wss://nostr.me/relay",
    "wss://librepress.libretechsystems.xyz",
    "wss://aeon.libretechsystems.xyz",
    "wss://relay.staging.plebeian.market",
    "wss://relay.cxplay.org",
    "wss://henhouse.social/relay",
    "wss://social.protest.net/relay",
    "wss://relay.nostrverse.net",
    "wss://cdn.czas.xyz",
    "wss://dm.czas.xyz",
    "wss://relay.og.coop",
    "wss://relay.44billion.net",
    "wss://relay.cloistr.xyz",
};

/// Relays known to carry Clawstr (kind 1111) content.
/// ditto.pub is the primary Clawstr relay.
const CLAWSTR_RELAYS = [_][]const u8{
    "wss://relay.ditto.pub",
    "wss://nos.lol",
    "wss://relay.nostr.net",
    "wss://relay.crostr.com",
};

// ── Relay health tracking ──────────────────────────────────────────
// In-memory tracker that remembers recent connection failures per relay
// and skips them with exponential backoff (30s / 60s / 120s).
// Thread-safe via spinlock.

const RelaySpinlock = @import("../spinlock.zig").Spinlock;

const RelayHealth = struct {
    const MAX_ENTRIES = 64;
    const MAX_URL_LEN = 256;
    const BACKOFF_NS_1 = 30 * std.time.ns_per_s;
    const BACKOFF_NS_2 = 60 * std.time.ns_per_s;
    const BACKOFF_NS_3 = 120 * std.time.ns_per_s;

    const Entry = struct {
        url: [MAX_URL_LEN]u8 = [_]u8{0} ** MAX_URL_LEN,
        url_len: u16 = 0,
        fail_count: u32 = 0,
        last_fail_ns: u64 = 0,
    };

    mu: RelaySpinlock = .{},
    entries: [MAX_ENTRIES]Entry = [_]Entry{.{}} ** MAX_ENTRIES,
    len: u32 = 0,

    fn entrySlice(e: *Entry) []const u8 {
        return e.url[0..e.url_len];
    }

    fn findEntry(self: *RelayHealth, url: []const u8) ?*Entry {
        for (self.entries[0..self.len]) |*e| {
            if (std.mem.eql(u8, entrySlice(e), url)) return e;
        }
        return null;
    }

    fn copyUrl(e: *Entry, url: []const u8) void {
        const n = @min(url.len, MAX_URL_LEN);
        @memcpy(e.url[0..n], url[0..n]);
        e.url_len = @intCast(n);
    }

    /// Record a connection failure for the given relay URL.
    pub fn recordFailure(self: *RelayHealth, url: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();

        const now: u64 = @intCast(util.nanoTimestamp());

        if (self.findEntry(url)) |e| {
            e.fail_count += 1;
            e.last_fail_ns = now;
        } else if (self.len < MAX_ENTRIES) {
            copyUrl(&self.entries[self.len], url);
            self.entries[self.len].fail_count = 1;
            self.entries[self.len].last_fail_ns = now;
            self.len += 1;
        }
        // If MAX_ENTRIES reached and url not found, silently drop (unlikely).
    }

    /// Record a successful connection — resets the failure counter for this relay.
    pub fn recordSuccess(self: *RelayHealth, url: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.findEntry(url)) |e| {
            e.fail_count = 0;
            e.last_fail_ns = 0;
        }
    }

    /// Check whether a relay is healthy (not in backoff period).
    pub fn isHealthy(self: *RelayHealth, url: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();

        const now: u64 = @intCast(util.nanoTimestamp());

        if (self.findEntry(url)) |e| {
            if (e.fail_count == 0) return true;
            const backoff: u64 = switch (e.fail_count) {
                1 => BACKOFF_NS_1,
                2 => BACKOFF_NS_2,
                else => BACKOFF_NS_3,
            };
            return now >= e.last_fail_ns + backoff;
        }
        return true; // no entry = never failed
    }

    /// Filter a relay list, returning only the healthy ones.
    /// Caller must free the returned slice with `allocator`.
    pub fn filterHealthy(self: *RelayHealth, allocator: std.mem.Allocator, relays: []const []const u8) ![]const []const u8 {
        var filtered: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer filtered.deinit(allocator);

        for (relays) |r| {
            if (self.isHealthy(r)) {
                try filtered.append(allocator, r);
            }
        }

        return filtered.toOwnedSlice(allocator);
    }
};

/// Global relay health tracker — lives for the process lifetime.
var global_relay_health: RelayHealth = .{};

pub const NostrTool = struct {
    config_dir: []const u8,
    allocator: std.mem.Allocator,

    pub const tool_name = "nostr";
    pub const tool_description = "Native Nostr operations. Actions: identity (return this agent's npub and hex pubkey), post (kind 1 note), read (subscribe + fetch events from multiple relays, deduplicated), search (NIP-50 full-text search across relay events), profile (kind 0 metadata), react (kind 7 reaction), channel_create (NIP-28 create channel, kind 40), channel_send (NIP-28 send message to channel, kind 42), channel_read (NIP-28 read channel messages, kinds 41/42). Supports full NIP-01 filters (kinds, authors, #p, #e, #t, since, until, limit). Uses direct WebSocket relay connections with BIP-340 Schnorr signing.";
    pub const tool_params =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["identity","post","read","search","profile","react","channel_create","channel_send","channel_read","clawstr_post","clawstr_read","relay_list"],"description":"Action to perform"},"content":{"type":"string","description":"Content for post/profile/react/channel_send/clawstr_post"},"relays":{"type":"array","items":{"type":"string"},"description":"Relay URLs (queries all relays in parallel; defaults to config)"},"private_key":{"type":"string","description":"Hex private key (default from config)"},"filter_kinds":{"type":"array","items":{"type":"integer"},"description":"For read/search: event kinds to filter"},"filter_authors":{"type":"array","items":{"type":"string"},"description":"For read/search: pubkeys to filter"},"filter_tags":{"type":"array","items":{"type":"string"},"description":"For read/search: #t tag values to filter"},"filter_p_tags":{"type":"array","items":{"type":"string"},"description":"For read/search: #p tag pubkeys to filter"},"filter_e_tags":{"type":"array","items":{"type":"string"},"description":"For read/search: #e tag event IDs to filter"},"filter_limit":{"type":"integer","description":"For read/search: max events per relay (default 20)"},"filter_since":{"type":"integer","description":"For read/search: unix timestamp lower bound"},"filter_until":{"type":"integer","description":"For read/search: unix timestamp upper bound"},"query":{"type":"string","description":"For search: NIP-50 full-text search query"},"event_id":{"type":"string","description":"For react: event ID to react to"},"event_pubkey":{"type":"string","description":"For react: pubkey of event author"},"deep_search":{"type":"boolean","description":"For read/search: when true, fire all relays in parallel and return as soon as 5 respond with events. Default false returns after the first relay responds (fastest response wins)."},"name":{"type":"string","description":"For channel_create: channel name"},"about":{"type":"string","description":"For channel_create: channel description/about text"},"channel_id":{"type":"string","description":"For channel_send/channel_read: event ID of the kind 40 channel creation event"},"subclaw":{"type":"string","description":"For clawstr_post/clawstr_read: subclaw community name (e.g. ai-freedom, videogames)"},"reply_to":{"type":"string","description":"For clawstr_post: event ID of the post being replied to"},"reply_pubkey":{"type":"string","description":"For clawstr_post: pubkey of the post author being replied to"}}}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *NostrTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *NostrTool, allocator: std.mem.Allocator, args: JsonObjectMap, io: std.Io) !ToolResult {
        const action = root.getString(args, "action") orelse
            return ToolResult.fail("Missing required 'action' parameter. Use: post, read, profile, react.");

        // Get private key — from args or config
        const sk_hex = root.getString(args, "private_key");
        var sk_buf: [32]u8 = undefined;
        const has_sk = if (sk_hex) |hex| blk: {
            sk_buf = nostr.hexDecodeFixed(32, hex) catch
                return ToolResult.fail("Invalid private_key hex (must be 64 hex chars)");
            break :blk true;
        } else blk: {
            sk_buf = self.loadPrivateKey(allocator, io) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "Failed to load/generate private key: {}", .{err}) catch
                    "Failed to load/generate private key";
                return ToolResult.failAlloc(allocator, msg);
            };
            break :blk true;
        };

        // Get relays — from args or config
        var relay_urls: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (relay_urls.items) |r| allocator.free(r);
            relay_urls.deinit(allocator);
        }

        // Check for relay array in args
        if (root.getValue(args, "relays")) |relays_val| {
            if (relays_val == .array) {
                for (relays_val.array.items) |rv| {
                    if (rv == .string) {
                        try relay_urls.append(allocator, try allocator.dupe(u8, rv.string));
                    }
                }
            }
        }
        if (relay_urls.items.len == 0) {
            if (std.mem.startsWith(u8, action, "clawstr")) {
                // Clawstr actions use their own relay list — config relays
                // (agent's private message relay) don't carry public Clawstr content.
                for (&CLAWSTR_RELAYS) |r| {
                    try relay_urls.append(allocator, try allocator.dupe(u8, r));
                }
            } else {
                // Load from config
                const config_relays = self.loadRelays(allocator, io) catch &.{};
                for (config_relays) |r| {
                    try relay_urls.append(allocator, r);
                }
            }
        }
        if (relay_urls.items.len == 0) {
            // Use appropriate fallback relays based on action
            const fallback_relays = if (std.mem.eql(u8, action, "search"))
                &SEARCH_RELAYS
            else if (std.mem.startsWith(u8, action, "clawstr"))
                &CLAWSTR_RELAYS
            else
                &WELL_KNOWN_RELAYS;
            for (fallback_relays) |r| {
                try relay_urls.append(allocator, try allocator.dupe(u8, r));
            }
        }
        // For search, always ensure SEARCH_RELAYS are included — most random
        // relays don't support NIP-50 and will just timeout.
        if (std.mem.eql(u8, action, "search")) {
            for (&SEARCH_RELAYS) |sr| {
                var found = false;
                for (relay_urls.items) |existing| {
                    if (std.mem.eql(u8, existing, sr)) { found = true; break; }
                }
                if (!found) {
                    try relay_urls.append(allocator, try allocator.dupe(u8, sr));
                }
            }
        }
        if (std.mem.eql(u8, action, "identity")) {
            return self.actionIdentity(allocator, sk_buf);
        } else if (std.mem.eql(u8, action, "post")) {
            if (!has_sk) return ToolResult.fail("Private key required for posting. Provide 'private_key' parameter or configure channels.nostr_public.private_key.");
            return self.actionPost(allocator, sk_buf, relay_urls.items, args);
        } else if (std.mem.eql(u8, action, "read")) {
            return self.actionRead(allocator, relay_urls.items, args);
        } else if (std.mem.eql(u8, action, "search")) {
            return self.actionSearch(allocator, relay_urls.items, args);
        } else if (std.mem.eql(u8, action, "profile")) {
            if (!has_sk) return ToolResult.fail("Private key required for profile. Provide 'private_key' parameter or configure channels.nostr_public.private_key.");
            return self.actionProfile(allocator, sk_buf, relay_urls.items, args);
        } else if (std.mem.eql(u8, action, "react")) {
            if (!has_sk) return ToolResult.fail("Private key required for reactions. Provide 'private_key' parameter or configure channels.nostr_public.private_key.");
            return self.actionReact(allocator, sk_buf, relay_urls.items, args);
        } else if (std.mem.eql(u8, action, "channel_create")) {
            if (!has_sk) return ToolResult.fail("Private key required for channel creation. Provide 'private_key' parameter or configure channels.nostr_public.private_key.");
            return self.actionChannelCreate(allocator, sk_buf, relay_urls.items, args);
        } else if (std.mem.eql(u8, action, "channel_send")) {
            if (!has_sk) return ToolResult.fail("Private key required for channel messages. Provide 'private_key' parameter or configure channels.nostr_public.private_key.");
            return self.actionChannelSend(allocator, sk_buf, relay_urls.items, args);
        } else if (std.mem.eql(u8, action, "channel_read")) {
            return self.actionChannelRead(allocator, relay_urls.items, args);
        } else if (std.mem.eql(u8, action, "clawstr_post")) {
            return self.actionClawstrPost(allocator, sk_buf, relay_urls.items, args);
        } else if (std.mem.eql(u8, action, "clawstr_read")) {
            return self.actionClawstrRead(allocator, relay_urls.items, args);
        } else if (std.mem.eql(u8, action, "relay_list")) {
            return self.actionRelayList(allocator, sk_buf, relay_urls.items, args);
        } else {
            return ToolResult.fail("Unknown action. Use: identity, post, read, search, profile, react, channel_create, channel_send, channel_read, clawstr_post, clawstr_read, relay_list.");
        }
    }

    // ── Relay query context (shared across threads) ─────────────────

    /// Per-relay result collected by a worker thread.
    const RelayResult = struct {
        relay: []const u8,
        events: []nostr.Event,
        error_msg: ?[]const u8,
    };

    /// Shared context for parallel relay queries.
    const RelayQueryContext = struct {
        allocator: std.mem.Allocator,
        filter_json: []const u8,
        relays: []const []const u8,
        /// One result per relay (written by worker, read after join).
        results: []RelayResult,
        /// Raw socket fds per relay (written by worker after connect).
        /// -1 means not yet connected. Used by watchdog to interrupt blocked reads.
        socket_fds: []std.atomic.Value(i32),
        /// Set to true by main thread when enough results collected — workers should exit early.
        stop_flag: std.atomic.Value(bool),
        /// Number of workers that have finished (connected or failed).
        completed_count: std.atomic.Value(usize),
        /// Number of workers that returned at least 1 event.
        event_count: std.atomic.Value(usize),
    };

    /// Worker thread function — queries a single relay and stores result.
    /// Each thread owns its own `std.Io.Threaded` instance to avoid TLS
    /// bus errors from concurrent access to the global singleton.
    fn relayQueryThread(ctx: *RelayQueryContext, relay_index: usize) void {
        const relay = ctx.relays[relay_index];
        const allocator = ctx.allocator;

        var client = nostr.RelayClient.connect(allocator, relay) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{s}: {}", .{ relay, err }) catch relay;
            ctx.results[relay_index] = .{ .relay = relay, .events = &.{}, .error_msg = msg };
            _ = ctx.completed_count.fetchAdd(1, .monotonic);
            return;
        };
        defer client.deinit();

        // Store fd so the watchdog thread can interrupt blocked reads.
        ctx.socket_fds[relay_index].store(client.getSocketFd(), .monotonic);

        // Set read timeout for one-shot query reads.
        client.setReadTimeout(10_000);

        const sub_id = client.subscribe(ctx.filter_json) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{s}: subscribe {}", .{ relay, err }) catch relay;
            ctx.results[relay_index] = .{ .relay = relay, .events = &.{}, .error_msg = msg };
            _ = ctx.completed_count.fetchAdd(1, .monotonic);
            return;
        };
        defer allocator.free(sub_id);

        var events: std.ArrayListUnmanaged(nostr.Event) = .empty;
        const timeout_ns: u64 = 10 * std.time.ns_per_s;
        const start = util.nanoTimestamp();
        var eose_received = false;
        var msg_count: u32 = 0;

        while (!eose_received and !ctx.stop_flag.load(.monotonic)) {
            if (util.nanoTimestamp() - start > timeout_ns) break;
            const raw = client.readMessage() catch null orelse break;
            msg_count += 1;
            defer allocator.free(raw);
            const msg = nostr.parseRelayMessage(allocator, raw) catch continue;
            defer if (msg.event_json) |ej| allocator.free(ej);
            defer allocator.free(msg.raw);

            switch (msg.msg_type) {
                .eose => eose_received = true,
                .event => {
                    if (msg.event_json) |ej| {
                        const event = nostr.parseEventJson(allocator, ej) catch continue;
                        events.append(allocator, event) catch {};
                    }
                },
                .notice => log.warn("relay notice from {s}: {s}", .{ relay, msg.raw }),
                else => {},
            }
        }
        client.unsubscribe(sub_id);

        log.info("relay {s}: {d} msgs, {d} events, eose={}", .{
            relay, msg_count, events.items.len, eose_received,
        });

        ctx.results[relay_index] = .{
            .relay = relay,
            .events = events.items,
            .error_msg = null,
        };

        // Update atomics — main thread polls these for early exit.
        const had_events = events.items.len > 0;
        _ = ctx.completed_count.fetchAdd(1, .monotonic);
        if (had_events) {
            _ = ctx.event_count.fetchAdd(1, .monotonic);
        }
    }

    /// Watchdog thread — sleeps until deadline, then interrupts all workers
    /// still blocked in read() by calling shutdown(SHUT_RD) on their sockets.
    /// This is the only reliable way to unblock TLS reads: SO_RCVTIMEO is a
    /// no-op for TLS (causes Io.Threaded ABRT), and the per-read wall-clock
    /// check never runs while blocked inside read().
    fn relayWatchdog(ctx: *RelayQueryContext, timeout_ns: u64) void {
        const start = util.nanoTimestamp();
        const check_interval: u64 = 100 * std.time.ns_per_ms; // 100ms polling
        while (util.nanoTimestamp() - start < timeout_ns) {
            if (ctx.completed_count.load(.monotonic) >= ctx.relays.len) return;
            util.sleep(check_interval);
        }
        log.warn("watchdog: {d}s deadline reached, interrupting {d} blocked workers", .{
            timeout_ns / std.time.ns_per_s,
            ctx.relays.len - ctx.completed_count.load(.monotonic),
        });
        interruptAllWorkers(ctx);
    }

    /// Call shutdown(SHUT_RD) on all connected relay sockets.
    /// This unblocks workers stuck inside TLS read(), causing them to
    /// see EOF and exit their read loop cleanly.
    fn interruptAllWorkers(ctx: *RelayQueryContext) void {
        for (ctx.socket_fds) |*fd_slot| {
            const fd = fd_slot.load(.monotonic);
            if (fd >= 0) {
                _ = std.posix.system.shutdown(fd, std.posix.SHUT.RD);
            }
        }
    }

    /// Query multiple relays in parallel, merge results, deduplicate by event ID.
    /// Each relay gets its own thread with a dedicated `std.Io.Threaded` instance
    /// so TLS handshakes don't corrupt shared global Io state.
    ///
    /// When `min_results` > 0, returns as soon as that many relays have responded
    /// with events (a "deep search" mode). Remaining workers are signalled to stop
    /// via stop_flag. Set to 0 to wait for all relays (default).
    /// Mutex-protected allocator wrapper for use in spawned threads.
    /// Zig's GPA (including std.testing.allocator) is NOT thread-safe;
    /// this wrapper serializes all allocations through a spin-lock mutex.
    const ThreadSafeAllocator = struct {
        mutex: std.atomic.Mutex = .unlocked,
        backing: std.mem.Allocator,

        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
            while (!self.mutex.tryLock()) {
                std.Thread.yield() catch {};
            }
            defer self.mutex.unlock();
            return self.backing.rawAlloc(len, alignment, ret_addr);
        }

        fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
            while (!self.mutex.tryLock()) {
                std.Thread.yield() catch {};
            }
            defer self.mutex.unlock();
            return self.backing.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
            while (!self.mutex.tryLock()) {
                std.Thread.yield() catch {};
            }
            defer self.mutex.unlock();
            return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
            while (!self.mutex.tryLock()) {
                std.Thread.yield() catch {};
            }
            defer self.mutex.unlock();
            self.backing.rawFree(memory, alignment, ret_addr);
        }

        fn allocator(self: *ThreadSafeAllocator) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = ThreadSafeAllocator.alloc,
                    .resize = ThreadSafeAllocator.resize,
                    .remap = ThreadSafeAllocator.remap,
                    .free = ThreadSafeAllocator.free,
                },
            };
        }
    };

    /// Result type for parallel relay queries.
    const QueryResult = struct {
        events: std.ArrayListUnmanaged(nostr.Event),
        errors: std.ArrayListUnmanaged(u8),
    };

    fn queryRelaysParallel(allocator: std.mem.Allocator, relays: []const []const u8, filter_json: []const u8, min_results: usize) !QueryResult {
        // Filter out relays that failed recently (backoff).
        const healthy_relays = try global_relay_health.filterHealthy(allocator, relays);
        defer allocator.free(healthy_relays);

        if (healthy_relays.len == 0) {
            log.warn("all {d} relays are in backoff, using full list", .{relays.len});
            return queryRelaysParallelInner(allocator, relays, filter_json, min_results);
        }
        if (healthy_relays.len < relays.len) {
            log.info("relay health: skipped {d}/{d} unhealthy relays", .{
                relays.len - healthy_relays.len, relays.len,
            });
        }

        return queryRelaysParallelInner(allocator, healthy_relays, filter_json, min_results);
    }

    fn queryRelaysParallelInner(allocator: std.mem.Allocator, relays: []const []const u8, filter_json: []const u8, min_results: usize) !QueryResult {
        // Wrap allocator in mutex for thread safety (GPA is not thread-safe).
        var safe_alloc: ThreadSafeAllocator = .{ .backing = allocator };
        const thread_alloc = safe_alloc.allocator();

        // Prepare per-relay result slots
        const results = try thread_alloc.alloc(RelayResult, relays.len);
        defer thread_alloc.free(results);
        @memset(results, RelayResult{ .relay = "", .events = &.{}, .error_msg = null });

        // Per-relay socket fd slots for watchdog interrupt. -1 = not connected.
        const socket_fds = try thread_alloc.alloc(std.atomic.Value(i32), relays.len);
        defer thread_alloc.free(socket_fds);
        for (socket_fds) |*fd| {
            fd.* = std.atomic.Value(i32).init(-1);
        }

        var ctx = RelayQueryContext{
            .allocator = thread_alloc,
            .filter_json = filter_json,
            .relays = relays,
            .results = results,
            .socket_fds = socket_fds,
            .stop_flag = std.atomic.Value(bool).init(false),
            .completed_count = std.atomic.Value(usize).init(0),
            .event_count = std.atomic.Value(usize).init(0),
        };

        // Spawn one thread per relay. Each thread creates its own Io.Threaded
        // instance inside relayQueryThread for TLS isolation.
        const threads = try thread_alloc.alloc(std.Thread, relays.len);
        defer thread_alloc.free(threads);
        var thread_spawned = try thread_alloc.alloc(bool, relays.len);
        defer thread_alloc.free(thread_spawned);
        @memset(thread_spawned, false);

        for (relays, 0..) |_, i| {
            if (std.Thread.spawn(.{}, relayQueryThread, .{ &ctx, i })) |t| {
                threads[i] = t;
                thread_spawned[i] = true;
            } else |err| {
                log.warn("failed to spawn thread for relay {d}: {}", .{ i, err });
                // Run sequentially as fallback
                relayQueryThread(&ctx, i);
            }
        }

        // Spawn watchdog thread to interrupt blocked reads after deadline.
        // readTimeout() is a no-op for TLS, so without this, workers block
        // forever on relays that don't respond.
        const query_timeout_ns: u64 = 10 * std.time.ns_per_s;
        const watchdog = std.Thread.spawn(.{}, relayWatchdog, .{ &ctx, query_timeout_ns }) catch null;

        // Wait loop: poll atomics until we have enough results or all done.
        // When min_results is set, return early once N relays answer with events.
        if (min_results > 0 and min_results < relays.len) {
            while (true) {
                const completed = ctx.completed_count.load(.monotonic);
                const event_responders = ctx.event_count.load(.monotonic);
                // Got enough relays with events — signal workers to stop
                if (event_responders >= min_results) {
                    log.info("deep search: {d}/{d} relays responded with events, stopping remaining", .{
                        event_responders, min_results,
                    });
                    ctx.stop_flag.store(true, .monotonic);
                    // Interrupt workers still blocked in read().
                    interruptAllWorkers(&ctx);
                    break;
                }
                // All relays finished (success or failure) — can't get more
                if (completed >= relays.len) {
                    break;
                }
                // Still waiting — yield CPU to let workers progress
                std.Thread.yield() catch {};
            }
        }

        // Join worker threads (watchdog already interrupted blocked ones).
        for (threads, 0..) |t, i| {
            if (thread_spawned[i]) {
                t.join();
            }
        }

        // Join watchdog (it exits once all workers complete or deadline passes).
        if (watchdog) |w| w.join();

        // Merge results, deduplicate by event ID (back on main thread)
        var all_events: std.ArrayListUnmanaged(nostr.Event) = .empty;
        var seen_ids: std.ArrayListUnmanaged([32]u8) = .empty;
        defer seen_ids.deinit(thread_alloc);

        var relay_errors: std.ArrayListUnmanaged(u8) = .empty;

        for (results) |result| {
            // Record health outcome for each relay.
            if (result.error_msg != null) {
                global_relay_health.recordFailure(result.relay);
            } else {
                global_relay_health.recordSuccess(result.relay);
            }

            if (result.error_msg) |err_msg| {
                try relay_errors.appendSlice(thread_alloc, err_msg);
                try relay_errors.appendSlice(thread_alloc, "; ");
                thread_alloc.free(err_msg);
            }
            for (result.events) |event| {
                var already_seen = false;
                for (seen_ids.items) |sid| {
                    if (std.mem.eql(u8, &sid, &event.id)) {
                        already_seen = true;
                        nostr.freeEvent(event, thread_alloc);
                        break;
                    }
                }
                if (!already_seen) {
                    try seen_ids.append(thread_alloc, event.id);
                    try all_events.append(thread_alloc, event);
                }
            }
        }

        return .{ .events = all_events, .errors = relay_errors };
    }

    /// Format events into a human-readable string.
    fn formatEvents(allocator: std.mem.Allocator, events: []const nostr.Event, header: []const u8, errors: []const u8) ![]const u8 {
        var results: std.ArrayListUnmanaged(u8) = .empty;
        const w = struct {
            fn print(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, ap: anytype) !void {
                const line = try std.fmt.allocPrint(alloc, fmt, ap);
                defer alloc.free(line);
                try buf.appendSlice(alloc, line);
            }
            fn writeAll(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, data: []const u8) !void {
                try buf.appendSlice(alloc, data);
            }
        };

        try w.writeAll(&results, allocator, header);
        if (errors.len > 0) {
            try w.writeAll(&results, allocator, "Errors: ");
            try w.writeAll(&results, allocator, errors);
            try w.writeAll(&results, allocator, "\n");
        }
        try w.writeAll(&results, allocator, "\n");

        for (events, 0..) |ev, i| {
            const pk_hex = nostr.hexEncode32(ev.pubkey);
            try w.print(&results, allocator, "[{d}] kind={d} author={s} ago={d}s\n", .{
                i + 1, ev.kind, &pk_hex, util.timestampUnix() - ev.created_at,
            });
            const display_len = @min(ev.content.len, 200);
            try w.print(&results, allocator, "    {s}", .{ev.content[0..display_len]});
            if (ev.content.len > 200) try w.writeAll(&results, allocator, "...");
            try w.writeAll(&results, allocator, "\n\n");
        }

        if (events.len == 0) {
            try w.writeAll(&results, allocator, "No events found.\n");
            log.info("query returned 0 events", .{});
        } else {
            log.info("query returned {} events", .{events.len});
        }

        return results.toOwnedSlice(allocator);
    }

    // ── Actions ─────────────────────────────────────────────────────

    /// Return this agent's Nostr identity (npub + hex pubkey).
    /// Derives the public key from the configured private key using secp256k1,
    /// then encodes it as both hex and bech32 npub format.
    fn actionIdentity(self: *NostrTool, allocator: std.mem.Allocator, sk: [32]u8) !ToolResult {
        _ = self;
        const kp = nostr.keyPairFromSecret(sk) catch
            return ToolResult.fail("Failed to derive public key from private key.");
        const hex_pk = nostr.hexEncode32(kp.public_key);
        const npub = nostr.npubEncodeAlloc(allocator, kp.public_key) catch
            return ToolResult.fail("Failed to encode npub.");

        const result = try std.fmt.allocPrint(allocator,
            "Nostr Identity:\n  npub: {s}\n  hex:  {s}",
            .{ npub, &hex_pk },
        );
        return ToolResult.ok(result);
    }

    fn actionPost(self: *NostrTool, allocator: std.mem.Allocator, sk: [32]u8, relays: []const []const u8, args: JsonObjectMap) !ToolResult {
        const content = root.getString(args, "content") orelse
            return ToolResult.fail("Missing 'content' parameter for post.");

        const kp = nostr.keyPairFromSecret(sk) catch
            return ToolResult.fail("Invalid private key (must be a valid secp256k1 scalar).");

        const now = util.timestampUnix();
        var event: nostr.Event = .{
            .id = [_]u8{0} ** 32,
            .pubkey = kp.public_key,
            .created_at = now,
            .kind = 1,
            .tags = &.{},
            .content = content,
            .sig = [_]u8{0} ** 64,
        };
        nostr.signEvent(&event, sk, allocator) catch
            return ToolResult.fail("Failed to sign event.");

        const event_json = nostr.eventToJson(event, allocator) catch
            return ToolResult.fail("Failed to serialize event.");
        defer allocator.free(event_json);

        const event_id_hex = nostr.hexEncode32(event.id);
        log.info("posting note: {s}...", .{content[0..@min(content.len, 50)]});

        var results: std.ArrayListUnmanaged(u8) = .empty;
        const w = struct {
            fn print(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, ap: anytype) !void {
                const line = try std.fmt.allocPrint(alloc, fmt, ap);
                defer alloc.free(line);
                try buf.appendSlice(alloc, line);
            }
        }.print;
        try w(&results, allocator, "Posted kind 1 note\n", .{});
        try w(&results, allocator, "Event ID: {s}\n", .{&event_id_hex});
        try w(&results, allocator, "Relays:\n", .{});

        for (relays) |relay| {
            try w(&results, allocator, "  {s}: ", .{relay});
            const result = self.publishToRelay(allocator, relay, event_json);
            if (result) |resp| {
                defer allocator.free(resp);
                try w(&results, allocator, "{s}\n", .{resp[0..@min(resp.len, 100)]});
            } else {
                try w(&results, allocator, "FAILED\n", .{});
            }
        }

        return ToolResult.okAlloc(allocator, results.items);
    }

    fn actionRead(self: *NostrTool, allocator: std.mem.Allocator, relays: []const []const u8, args: JsonObjectMap) !ToolResult {
        _ = self;

        // Build filter from args
        var kinds_list: std.ArrayListUnmanaged(u16) = .empty;
        defer kinds_list.deinit(allocator);
        if (root.getValue(args, "filter_kinds")) |kinds_val| {
            if (kinds_val == .array) {
                for (kinds_val.array.items) |kv| {
                    if (kv == .integer) try kinds_list.append(allocator, @intCast(kv.integer));
                }
            }
        }
        if (kinds_list.items.len == 0) try kinds_list.append(allocator, 1);

        var authors_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer { for (authors_list.items) |a| allocator.free(a); authors_list.deinit(allocator); }
        try extractStringArray(allocator, args, "filter_authors", &authors_list);

        var tags_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer { for (tags_list.items) |t| allocator.free(t); tags_list.deinit(allocator); }
        try extractStringArray(allocator, args, "filter_tags", &tags_list);

        var p_tags_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer { for (p_tags_list.items) |p| allocator.free(p); p_tags_list.deinit(allocator); }
        try extractStringArray(allocator, args, "filter_p_tags", &p_tags_list);

        var e_tags_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer { for (e_tags_list.items) |e| allocator.free(e); e_tags_list.deinit(allocator); }
        try extractStringArray(allocator, args, "filter_e_tags", &e_tags_list);

        const limit = if (root.getInt(args, "filter_limit")) |l| @as(u32, @intCast(l)) else @as(u32, 20);
        const since = root.getInt(args, "filter_since");
        const until = root.getInt(args, "filter_until");

        const filter_json = nostr.buildFilter(allocator, .{
            .kinds = kinds_list.items,
            .authors = authors_list.items,
            .limit = limit,
            .since = if (since) |s| @intCast(s) else null,
            .until = if (until) |u| @intCast(u) else null,
            .p_tags = p_tags_list.items,
            .e_tags = e_tags_list.items,
            .t_tags = tags_list.items,
        }) catch return ToolResult.fail("Failed to build filter JSON.");
        defer allocator.free(filter_json);

        // Query all relays in parallel (deep_search: race to 5, default: race to 1)
        const deep = root.getBool(args, "deep_search") orelse false;
        const min_results: usize = if (deep) 5 else 1;
        const query_result = try queryRelaysParallel(allocator, relays, filter_json, min_results);
        var all_events = query_result.events;
        defer { for (all_events.items) |ev| nostr.freeEvent(ev, allocator); all_events.deinit(allocator); }
        var relay_errors = query_result.errors;
        defer relay_errors.deinit(allocator);

        // Sort by created_at descending (newest first)
        std.mem.sort(nostr.Event, all_events.items, {}, struct {
            fn lessThan(_: void, a: nostr.Event, b: nostr.Event) bool {
                return a.created_at > b.created_at;
            }
        }.lessThan);

        const header = try std.fmt.allocPrint(allocator, "Read {d} events from {d} relay(s)\n", .{ all_events.items.len, relays.len });
        defer allocator.free(header);

        const output = try formatEvents(allocator, all_events.items, header, relay_errors.items);
        return ToolResult.okAlloc(allocator, output);
    }

    /// Helper: extract a string array from args into an ArrayList.
    fn extractStringArray(allocator: std.mem.Allocator, args: JsonObjectMap, key: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
        if (root.getValue(args, key)) |val| {
            if (val == .array) {
                for (val.array.items) |item| {
                    if (item == .string) {
                        try out.append(allocator, try allocator.dupe(u8, item.string));
                    }
                }
            }
        }
    }

    fn actionSearch(self: *NostrTool, allocator: std.mem.Allocator, relays: []const []const u8, args: JsonObjectMap) !ToolResult {
        _ = self;
        const query = root.getString(args, "query") orelse
            return ToolResult.fail("Missing 'query' parameter for search. Provide a NIP-50 search query string.");

        // Build filter — same as read but with search query
        var kinds_list: std.ArrayListUnmanaged(u16) = .empty;
        defer kinds_list.deinit(allocator);
        if (root.getValue(args, "filter_kinds")) |kinds_val| {
            if (kinds_val == .array) {
                for (kinds_val.array.items) |kv| {
                    if (kv == .integer) try kinds_list.append(allocator, @intCast(kv.integer));
                }
            }
        }
        if (kinds_list.items.len == 0) try kinds_list.append(allocator, 1);

        var authors_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer { for (authors_list.items) |a| allocator.free(a); authors_list.deinit(allocator); }
        try extractStringArray(allocator, args, "filter_authors", &authors_list);

        var tags_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer { for (tags_list.items) |t| allocator.free(t); tags_list.deinit(allocator); }
        try extractStringArray(allocator, args, "filter_tags", &tags_list);

        var p_tags_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer { for (p_tags_list.items) |p| allocator.free(p); p_tags_list.deinit(allocator); }
        try extractStringArray(allocator, args, "filter_p_tags", &p_tags_list);

        var e_tags_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer { for (e_tags_list.items) |e| allocator.free(e); e_tags_list.deinit(allocator); }
        try extractStringArray(allocator, args, "filter_e_tags", &e_tags_list);

        const limit = if (root.getInt(args, "filter_limit")) |l| @as(u32, @intCast(l)) else @as(u32, 20);
        const since = root.getInt(args, "filter_since");
        const until = root.getInt(args, "filter_until");

        const filter_json = nostr.buildFilter(allocator, .{
            .kinds = kinds_list.items,
            .authors = authors_list.items,
            .limit = limit,
            .since = if (since) |s| @intCast(s) else null,
            .until = if (until) |u| @intCast(u) else null,
            .p_tags = p_tags_list.items,
            .e_tags = e_tags_list.items,
            .t_tags = tags_list.items,
            .search = query,
        }) catch return ToolResult.fail("Failed to build search filter JSON.");
        defer allocator.free(filter_json);

        log.info("searching for: {s}", .{query[0..@min(query.len, 80)]});

        // Query all relays in parallel (deep_search: race to 5, default: race to 1)
        const deep = root.getBool(args, "deep_search") orelse false;
        const min_results: usize = if (deep) 5 else 1;
        const query_result = try queryRelaysParallel(allocator, relays, filter_json, min_results);
        var all_events = query_result.events;
        defer { for (all_events.items) |ev| nostr.freeEvent(ev, allocator); all_events.deinit(allocator); }
        var relay_errors = query_result.errors;
        defer relay_errors.deinit(allocator);

        // Sort by created_at descending (newest first)
        std.mem.sort(nostr.Event, all_events.items, {}, struct {
            fn lessThan(_: void, a: nostr.Event, b: nostr.Event) bool {
                return a.created_at > b.created_at;
            }
        }.lessThan);

        const header = try std.fmt.allocPrint(allocator, "Search \"{s}\" — {d} results from {d} relay(s)\n", .{ query, all_events.items.len, relays.len });
        defer allocator.free(header);

        var output = try formatEvents(allocator, all_events.items, header, relay_errors.items);

        if (all_events.items.len == 0) {
            const note = try std.fmt.allocPrint(allocator, "{s}\nNote: NIP-50 search requires relay support. Not all relays implement full-text search.\n", .{output});
            allocator.free(output);
            output = note;
        }

        return ToolResult.okAlloc(allocator, output);
    }

    fn actionProfile(self: *NostrTool, allocator: std.mem.Allocator, sk: [32]u8, relays: []const []const u8, args: JsonObjectMap) !ToolResult {
        const content = root.getString(args, "content") orelse
            return ToolResult.fail("Missing 'content' parameter for profile. Pass a JSON string like {\"name\":\"...\",\"about\":\"...\",\"picture\":\"...\"}.");

        const kp = nostr.keyPairFromSecret(sk) catch
            return ToolResult.fail("Invalid private key.");

        const now = util.timestampUnix();
        var event: nostr.Event = .{
            .id = [_]u8{0} ** 32,
            .pubkey = kp.public_key,
            .created_at = now,
            .kind = 0,
            .tags = &.{},
            .content = content,
            .sig = [_]u8{0} ** 64,
        };
        nostr.signEvent(&event, sk, allocator) catch
            return ToolResult.fail("Failed to sign profile event.");

        const event_json = nostr.eventToJson(event, allocator) catch
            return ToolResult.fail("Failed to serialize event.");
        defer allocator.free(event_json);

        var results: std.ArrayListUnmanaged(u8) = .empty;
        const w = struct {
            fn print(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, ap: anytype) !void {
                const line = try std.fmt.allocPrint(alloc, fmt, ap);
                defer alloc.free(line);
                try buf.appendSlice(alloc, line);
            }
        }.print;
        try w(&results, allocator, "Published kind 0 profile\n", .{});

        for (relays) |relay| {
            try w(&results, allocator, "  {s}: ", .{relay});
            const result = self.publishToRelay(allocator, relay, event_json);
            if (result) |resp| {
                defer allocator.free(resp);
                try w(&results, allocator, "{s}\n", .{resp[0..@min(resp.len, 100)]});
            } else {
                try w(&results, allocator, "FAILED\n", .{});
            }
        }

        return ToolResult.okAlloc(allocator, results.items);
    }

    fn actionReact(self: *NostrTool, allocator: std.mem.Allocator, sk: [32]u8, relays: []const []const u8, args: JsonObjectMap) !ToolResult {
        const event_id = root.getString(args, "event_id") orelse
            return ToolResult.fail("Missing 'event_id' parameter for react.");
        const event_pubkey = root.getString(args, "event_pubkey") orelse
            return ToolResult.fail("Missing 'event_pubkey' parameter for react.");

        const content = root.getString(args, "content") orelse "+";

        const kp = nostr.keyPairFromSecret(sk) catch
            return ToolResult.fail("Invalid private key.");

        const now = util.timestampUnix();

        // Build tags: ["e", <event_id>], ["p", <pubkey>]
        const e_tag = nostr.eTag(allocator, event_id) catch
            return ToolResult.fail("Failed to create e-tag.");
        const p_tag = nostr.pTag(allocator, event_pubkey) catch
            return ToolResult.fail("Failed to create p-tag.");
        const tags = [_]nostr.Tag{ e_tag, p_tag };

        var event: nostr.Event = .{
            .id = [_]u8{0} ** 32,
            .pubkey = kp.public_key,
            .created_at = now,
            .kind = 7,
            .tags = &tags,
            .content = content,
            .sig = [_]u8{0} ** 64,
        };
        nostr.signEvent(&event, sk, allocator) catch
            return ToolResult.fail("Failed to sign reaction event.");

        const event_json = nostr.eventToJson(event, allocator) catch
            return ToolResult.fail("Failed to serialize event.");
        defer allocator.free(event_json);

        // Cleanup tags
        for (tags) |t| t.deinit(allocator);

        var results: std.ArrayListUnmanaged(u8) = .empty;
        const w = struct {
            fn print(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, ap: anytype) !void {
                const line = try std.fmt.allocPrint(alloc, fmt, ap);
                defer alloc.free(line);
                try buf.appendSlice(alloc, line);
            }
        }.print;
        try w(&results, allocator, "Published kind 7 reaction: {s}\n", .{content});

        for (relays) |relay| {
            try w(&results, allocator, "  {s}: ", .{relay});
            const result = self.publishToRelay(allocator, relay, event_json);
            if (result) |resp| {
                defer allocator.free(resp);
                try w(&results, allocator, "{s}\n", .{resp[0..@min(resp.len, 100)]});
            } else {
                try w(&results, allocator, "FAILED\n", .{});
            }
        }

        return ToolResult.okAlloc(allocator, results.items);
    }

    fn actionChannelCreate(self: *NostrTool, allocator: std.mem.Allocator, sk: [32]u8, relays: []const []const u8, args: JsonObjectMap) !ToolResult {
        const name = root.getString(args, "name") orelse
            return ToolResult.fail("Missing 'name' parameter for channel_create.");
        const about = root.getString(args, "about") orelse "";

        const kp = nostr.keyPairFromSecret(sk) catch
            return ToolResult.fail("Invalid private key (must be a valid secp256k1 scalar).");

        // Build content: name + about if provided
        const content = if (about.len > 0)
            try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ name, about })
        else
            name;

        const now = util.timestampUnix();
        var event: nostr.Event = .{
            .id = [_]u8{0} ** 32,
            .pubkey = kp.public_key,
            .created_at = now,
            .kind = 40,
            .tags = &.{},
            .content = content,
            .sig = [_]u8{0} ** 64,
        };
        nostr.signEvent(&event, sk, allocator) catch
            return ToolResult.fail("Failed to sign channel creation event.");

        const event_json = nostr.eventToJson(event, allocator) catch
            return ToolResult.fail("Failed to serialize event.");
        defer allocator.free(event_json);

        if (about.len > 0) allocator.free(content);

        const event_id_hex = nostr.hexEncode32(event.id);
        log.info("creating channel: {s}", .{name});

        var results: std.ArrayListUnmanaged(u8) = .empty;
        const w = struct {
            fn print(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, ap: anytype) !void {
                const line = try std.fmt.allocPrint(alloc, fmt, ap);
                defer alloc.free(line);
                try buf.appendSlice(alloc, line);
            }
        }.print;
        try w(&results, allocator, "Created channel (kind 40)\n", .{});
        try w(&results, allocator, "Channel ID: {s}\n", .{&event_id_hex});
        try w(&results, allocator, "Name: {s}\n", .{name});
        try w(&results, allocator, "Relays:\n", .{});

        for (relays) |relay| {
            try w(&results, allocator, "  {s}: ", .{relay});
            const result = self.publishToRelay(allocator, relay, event_json);
            if (result) |resp| {
                defer allocator.free(resp);
                try w(&results, allocator, "{s}\n", .{resp[0..@min(resp.len, 100)]});
            } else {
                try w(&results, allocator, "FAILED\n", .{});
            }
        }

        return ToolResult.okAlloc(allocator, results.items);
    }

    fn actionChannelSend(self: *NostrTool, allocator: std.mem.Allocator, sk: [32]u8, relays: []const []const u8, args: JsonObjectMap) !ToolResult {
        const channel_id = root.getString(args, "channel_id") orelse
            return ToolResult.fail("Missing 'channel_id' parameter for channel_send.");
        const content = root.getString(args, "content") orelse
            return ToolResult.fail("Missing 'content' parameter for channel_send.");

        const kp = nostr.keyPairFromSecret(sk) catch
            return ToolResult.fail("Invalid private key (must be a valid secp256k1 scalar).");

        const now = util.timestampUnix();

        // Build e-tag: ["e", "<channel_id>", "", "root"]
        const e_tag_fields = try allocator.alloc([]const u8, 4);
        e_tag_fields[0] = try allocator.dupe(u8, "e");
        e_tag_fields[1] = try allocator.dupe(u8, channel_id);
        e_tag_fields[2] = try allocator.dupe(u8, "");
        e_tag_fields[3] = try allocator.dupe(u8, "root");
        const e_tag = nostr.Tag{ .fields = e_tag_fields };

        var event: nostr.Event = .{
            .id = [_]u8{0} ** 32,
            .pubkey = kp.public_key,
            .created_at = now,
            .kind = 42,
            .tags = &.{e_tag},
            .content = content,
            .sig = [_]u8{0} ** 64,
        };
        nostr.signEvent(&event, sk, allocator) catch
            return ToolResult.fail("Failed to sign channel message event.");

        const event_json = nostr.eventToJson(event, allocator) catch
            return ToolResult.fail("Failed to serialize event.");
        defer allocator.free(event_json);

        // Cleanup e-tag
        for (e_tag_fields) |f| allocator.free(f);
        allocator.free(e_tag_fields);

        log.info("sending message to channel {s}: {s}", .{ channel_id[0..@min(channel_id.len, 16)], content[0..@min(content.len, 50)] });

        var results: std.ArrayListUnmanaged(u8) = .empty;
        const w = struct {
            fn print(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, ap: anytype) !void {
                const line = try std.fmt.allocPrint(alloc, fmt, ap);
                defer alloc.free(line);
                try buf.appendSlice(alloc, line);
            }
        }.print;
        try w(&results, allocator, "Sent message to channel (kind 42)\n", .{});
        try w(&results, allocator, "Channel ID: {s}\n", .{channel_id});
        try w(&results, allocator, "Relays:\n", .{});

        for (relays) |relay| {
            try w(&results, allocator, "  {s}: ", .{relay});
            const result = self.publishToRelay(allocator, relay, event_json);
            if (result) |resp| {
                defer allocator.free(resp);
                try w(&results, allocator, "{s}\n", .{resp[0..@min(resp.len, 100)]});
            } else {
                try w(&results, allocator, "FAILED\n", .{});
            }
        }

        return ToolResult.okAlloc(allocator, results.items);
    }

    fn actionChannelRead(self: *NostrTool, allocator: std.mem.Allocator, relays: []const []const u8, args: JsonObjectMap) !ToolResult {
        _ = self;

        const channel_id = root.getString(args, "channel_id") orelse
            return ToolResult.fail("Missing 'channel_id' parameter for channel_read.");

        const limit: u32 = if (root.getInt(args, "filter_limit")) |l|
            @intCast(l)
        else
            50;

        // Build filter: {"kinds": [41, 42], "#e": ["<channel_id>"], "limit": <limit>}
        const filter_json = nostr.buildFilter(allocator, .{
            .kinds = &[_]u16{ 41, 42 },
            .e_tags = &[_][]const u8{channel_id},
            .limit = limit,
        }) catch return ToolResult.fail("Failed to build channel filter JSON.");
        defer allocator.free(filter_json);

        log.info("reading channel {s} (limit={d})", .{ channel_id[0..@min(channel_id.len, 16)], limit });

        // Query all relays in parallel (race to 1)
        const query_result = try queryRelaysParallel(allocator, relays, filter_json, 1);
        var all_events = query_result.events;
        defer {
            for (all_events.items) |ev| nostr.freeEvent(ev, allocator);
            all_events.deinit(allocator);
        }
        var relay_errors = query_result.errors;
        defer relay_errors.deinit(allocator);

        // Sort by created_at ascending (oldest first for chat history)
        std.mem.sort(nostr.Event, all_events.items, {}, struct {
            fn lessThan(_: void, a: nostr.Event, b: nostr.Event) bool {
                return a.created_at < b.created_at;
            }
        }.lessThan);

        // Format output with channel-specific formatting
        var results: std.ArrayListUnmanaged(u8) = .empty;
        const w = struct {
            fn print(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, ap: anytype) !void {
                const line = try std.fmt.allocPrint(alloc, fmt, ap);
                defer alloc.free(line);
                try buf.appendSlice(alloc, line);
            }
            fn writeAll(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, data: []const u8) !void {
                try buf.appendSlice(alloc, data);
            }
        };

        try w.print(&results, allocator, "Channel {s} — {d} messages from {d} relay(s)\n", .{
            channel_id[0..@min(channel_id.len, 20)],
            all_events.items.len,
            relays.len,
        });
        if (relay_errors.items.len > 0) {
            try w.writeAll(&results, allocator, "Errors: ");
            try w.writeAll(&results, allocator, relay_errors.items);
            try w.writeAll(&results, allocator, "\n");
        }
        try w.writeAll(&results, allocator, "\n");

        for (all_events.items, 0..) |ev, i| {
            const pk_hex = nostr.hexEncode32(ev.pubkey);
            const ago = util.timestampUnix() - ev.created_at;
            if (ev.kind == 42) {
                // Channel message
                try w.print(&results, allocator, "[{d}] <{s}> {d}s ago\n", .{
                    i + 1, pk_hex[0..12], ago,
                });
                const display_len = @min(ev.content.len, 300);
                try w.writeAll(&results, allocator, "    ");
                try w.writeAll(&results, allocator, ev.content[0..display_len]);
                if (ev.content.len > 300) try w.writeAll(&results, allocator, "...");
                try w.writeAll(&results, allocator, "\n\n");
            } else if (ev.kind == 41) {
                // Channel metadata update
                try w.print(&results, allocator, "[{d}] [metadata] <{s}> {d}s ago\n", .{
                    i + 1, pk_hex[0..12], ago,
                });
                const display_len = @min(ev.content.len, 200);
                try w.writeAll(&results, allocator, "    ");
                try w.writeAll(&results, allocator, ev.content[0..display_len]);
                if (ev.content.len > 200) try w.writeAll(&results, allocator, "...");
                try w.writeAll(&results, allocator, "\n\n");
            }
        }

        if (all_events.items.len == 0) {
            try w.writeAll(&results, allocator, "No messages found in channel.\n");
            log.info("channel read returned 0 events", .{});
        } else {
            log.info("channel read returned {} events", .{all_events.items.len});
        }

        return ToolResult.okAlloc(allocator, results.items);
    }

    // ── NIP-65 Relay List Discovery ─────────────────────────────────

    /// Query NIP-65 relay list (kind 10002) for one or more pubkeys.
    /// Parses "r" tags to extract relay URLs with read/write permissions.
    /// Defaults to the agent's own pubkey if no filter_authors provided.
    fn actionRelayList(self: *NostrTool, allocator: std.mem.Allocator, sk: [32]u8, relays: []const []const u8, args: JsonObjectMap) !ToolResult {
        _ = self;

        // Collect pubkeys to query
        var pubkeys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer { for (pubkeys.items) |p| allocator.free(p); pubkeys.deinit(allocator); }

        if (root.getValue(args, "filter_authors")) |authors_val| {
            if (authors_val == .array) {
                for (authors_val.array.items) |item| {
                    if (item == .string) {
                        try pubkeys.append(allocator, try allocator.dupe(u8, item.string));
                    }
                }
            }
        }
        if (pubkeys.items.len == 0) {
            // Default to agent's own pubkey
            const kp = nostr.keyPairFromSecret(sk) catch
                return ToolResult.fail("Failed to derive public key from private key for relay list query.");
            const hex_pk = try std.fmt.allocPrint(allocator, "{s}", .{&nostr.hexEncode32(kp.public_key)});
            try pubkeys.append(allocator, hex_pk);
        }

        // Build filter: kind 10002, limit 1 per author
        const filter_json = nostr.buildFilter(allocator, .{
            .kinds = &[_]u16{10002},
            .authors = pubkeys.items,
            .limit = 1,
            .since = null,
            .until = null,
            .p_tags = &[_][]const u8{},
            .e_tags = &[_][]const u8{},
            .t_tags = &[_][]const u8{},
        }) catch return ToolResult.fail("Failed to build NIP-65 relay list filter.");
        defer allocator.free(filter_json);

        // Query relays
        const query_result = try queryRelaysParallel(allocator, relays, filter_json, 1);
        var all_events = query_result.events;
        defer { for (all_events.items) |ev| nostr.freeEvent(ev, allocator); all_events.deinit(allocator); }
        var relay_errors = query_result.errors;
        defer relay_errors.deinit(allocator);

        // Deduplicated relay entries: url -> permission bitmask
        // bit 0 = read, bit 1 = write
        var relay_map: std.StringHashMapUnmanaged(u2) = .empty;
        defer {
            var it = relay_map.keyIterator();
            while (it.next()) |key| allocator.free(key.*);
            relay_map.deinit(allocator);
        }

        for (all_events.items) |ev| {
            for (ev.tags) |tag| {
                if (tag.fields.len < 2) continue;
                if (!std.mem.eql(u8, tag.fields[0], "r")) continue;
                const url = tag.fields[1];

                // Deduplicate by normalizing URL (strip trailing slash)
                const trimmed = std.mem.trimEnd(u8, url, "/");
                // Look up or insert
                const existing = relay_map.get(trimmed);
                var perm: u2 = if (existing) |p| p else 0;
                // Parse optional third field: "read" or "write"
                // If absent, implies both read+write
                if (tag.fields.len >= 3) {
                    if (std.mem.eql(u8, tag.fields[2], "read")) {
                        perm |= 0b01;
                    } else if (std.mem.eql(u8, tag.fields[2], "write")) {
                        perm |= 0b10;
                    }
                    // Unknown marker — ignore
                } else {
                    // No permission specified = read+write
                    perm = 0b11;
                }
                const gop = try relay_map.getOrPut(allocator, trimmed);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try allocator.dupe(u8, trimmed);
                }
                gop.value_ptr.* = perm;
            }
        }

        // Build output grouped by permission
        var read_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer { for (read_list.items) |r| allocator.free(r); read_list.deinit(allocator); }
        var write_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer { for (write_list.items) |r| allocator.free(r); write_list.deinit(allocator); }
        var rw_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer { for (rw_list.items) |r| allocator.free(r); rw_list.deinit(allocator); }

        var map_it = relay_map.iterator();
        while (map_it.next()) |entry| {
            const url = entry.key_ptr.*;
            const perm = entry.value_ptr.*;
            if (perm == 0b11) {
                try rw_list.append(allocator, try allocator.dupe(u8, url));
            } else {
                if (perm & 0b01 != 0) try read_list.append(allocator, try allocator.dupe(u8, url));
                if (perm & 0b10 != 0) try write_list.append(allocator, try allocator.dupe(u8, url));
            }
        }

        // Sort each group for stable output
        const str_sort_ctx = struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        };
        std.mem.sort([]const u8, rw_list.items, {}, str_sort_ctx.lessThan);
        std.mem.sort([]const u8, read_list.items, {}, str_sort_ctx.lessThan);
        std.mem.sort([]const u8, write_list.items, {}, str_sort_ctx.lessThan);

        var results: std.ArrayListUnmanaged(u8) = .empty;
        const w = struct {
            fn print(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, ap: anytype) !void {
                const line = try std.fmt.allocPrint(alloc, fmt, ap);
                defer alloc.free(line);
                try buf.appendSlice(alloc, line);
            }
            fn writeAll(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, data: []const u8) !void {
                try buf.appendSlice(alloc, data);
            }
        };

        try w.print(&results, allocator, "NIP-65 Relay List ({d} relays from {d} events)\n", .{
            relay_map.count(), all_events.items.len,
        });

        if (rw_list.items.len > 0) {
            try w.writeAll(&results, allocator, "\nRead+Write:\n");
            for (rw_list.items) |url| {
                try w.print(&results, allocator, "  {s}\n", .{url});
            }
        }
        if (read_list.items.len > 0) {
            try w.writeAll(&results, allocator, "\nRead-only:\n");
            for (read_list.items) |url| {
                try w.print(&results, allocator, "  {s}\n", .{url});
            }
        }
        if (write_list.items.len > 0) {
            try w.writeAll(&results, allocator, "\nWrite-only:\n");
            for (write_list.items) |url| {
                try w.print(&results, allocator, "  {s}\n", .{url});
            }
        }

        if (relay_map.count() == 0) {
            try w.writeAll(&results, allocator, "\nNo relay lists found for the queried pubkey(s).\n");
        }

        return ToolResult.okAlloc(allocator, results.items);
    }

    // ── Clawstr (clawstr.com) ──────────────────────────────────────

    /// Post to a Clawstr subclaw community (kind 1111, NIP-22 + NIP-73 + NIP-32).
    fn actionClawstrPost(self: *NostrTool, allocator: std.mem.Allocator, sk: [32]u8, relays: []const []const u8, args: JsonObjectMap) !ToolResult {
        const subclaw = root.getString(args, "subclaw") orelse
            return ToolResult.fail("Missing 'subclaw' parameter. Specify the community name (e.g. ai-freedom, videogames).");
        const content = root.getString(args, "content") orelse
            return ToolResult.fail("Missing 'content' parameter.");
        const reply_to = root.getString(args, "reply_to");
        const reply_pubkey = root.getString(args, "reply_pubkey");

        const kp = nostr.keyPairFromSecret(sk) catch
            return ToolResult.fail("Invalid private key.");

        const now = util.timestampUnix();

        // Build NIP-73 web URL identifier for the subclaw
        const subclaw_url = try std.fmt.allocPrint(allocator, "https://clawstr.com/c/{s}", .{subclaw});
        defer allocator.free(subclaw_url);

        // Count tags: 4 base (I, K, i, k) + 2 AI labels (L, l) + optional reply tags (e, p, k)
        const is_reply = reply_to != null;
        const tag_count: usize = if (is_reply) 9 else 6;
        var tags = try allocator.alloc(nostr.Tag, tag_count);
        defer allocator.free(tags);

        // Tag 0: Root scope — ["I", "<subclaw_url>"]
        {
            const fields = try allocator.alloc([]const u8, 2);
            fields[0] = try allocator.dupe(u8, "I");
            fields[1] = try allocator.dupe(u8, subclaw_url);
            tags[0] = .{ .fields = fields };
        }
        // Tag 1: Root kind — ["K", "web"]
        {
            const fields = try allocator.alloc([]const u8, 2);
            fields[0] = try allocator.dupe(u8, "K");
            fields[1] = try allocator.dupe(u8, "web");
            tags[1] = .{ .fields = fields };
        }
        // Tag 2: Parent item — ["i", "<subclaw_url>"] (same as root for top-level)
        {
            const fields = try allocator.alloc([]const u8, 2);
            fields[0] = try allocator.dupe(u8, "i");
            fields[1] = try allocator.dupe(u8, subclaw_url);
            tags[2] = .{ .fields = fields };
        }
        // Tag 3: Parent kind — ["k", "web"]
        {
            const fields = try allocator.alloc([]const u8, 2);
            fields[0] = try allocator.dupe(u8, "k");
            fields[1] = try allocator.dupe(u8, "web");
            tags[3] = .{ .fields = fields };
        }
        // Tag 4: NIP-32 AI label — ["L", "agent"]
        {
            const fields = try allocator.alloc([]const u8, 2);
            fields[0] = try allocator.dupe(u8, "L");
            fields[1] = try allocator.dupe(u8, "agent");
            tags[4] = .{ .fields = fields };
        }
        // Tag 5: NIP-32 AI value — ["l", "ai", "agent"]
        {
            const fields = try allocator.alloc([]const u8, 3);
            fields[0] = try allocator.dupe(u8, "l");
            fields[1] = try allocator.dupe(u8, "ai");
            fields[2] = try allocator.dupe(u8, "agent");
            tags[5] = .{ .fields = fields };
        }

        // Reply tags
        if (is_reply) {
            // Tag 6: ["e", "<reply_to>", "<relay>", "<reply_pubkey>"]
            {
                const fields = try allocator.alloc([]const u8, 4);
                fields[0] = try allocator.dupe(u8, "e");
                fields[1] = try allocator.dupe(u8, reply_to.?);
                fields[2] = try allocator.dupe(u8, if (relays.len > 0) relays[0] else "");
                fields[3] = try allocator.dupe(u8, reply_pubkey orelse "");
                tags[6] = .{ .fields = fields };
            }
            // Tag 7: ["p", "<reply_pubkey>"]
            {
                const fields = try allocator.alloc([]const u8, 2);
                fields[0] = try allocator.dupe(u8, "p");
                fields[1] = try allocator.dupe(u8, reply_pubkey orelse "");
                tags[7] = .{ .fields = fields };
            }
            // Tag 8: ["k", "1111"] — parent event kind
            {
                const fields = try allocator.alloc([]const u8, 2);
                fields[0] = try allocator.dupe(u8, "k");
                fields[1] = try allocator.dupe(u8, "1111");
                tags[8] = .{ .fields = fields };
            }
        }

        var event: nostr.Event = .{
            .id = [_]u8{0} ** 32,
            .pubkey = kp.public_key,
            .created_at = now,
            .kind = 1111,
            .tags = tags,
            .content = content,
            .sig = [_]u8{0} ** 64,
        };
        nostr.signEvent(&event, sk, allocator) catch
            return ToolResult.fail("Failed to sign Clawstr event.");

        const event_json = nostr.eventToJson(event, allocator) catch
            return ToolResult.fail("Failed to serialize event.");
        defer allocator.free(event_json);

        // Cleanup tags
        for (tags) |t| t.deinit(allocator);

        log.info("clawstr_post to c/{s}: {s}", .{ subclaw, content[0..@min(content.len, 60)] });

        var results: std.ArrayListUnmanaged(u8) = .empty;
        const w = struct {
            fn print(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, ap: anytype) !void {
                const line = try std.fmt.allocPrint(alloc, fmt, ap);
                defer alloc.free(line);
                try buf.appendSlice(alloc, line);
            }
        }.print;

        const action_type = if (is_reply) "Reply" else "Post";
        try w(&results, allocator, "{s} to c/{s} (kind 1111)\n", .{ action_type, subclaw });
        try w(&results, allocator, "Relays:\n", .{});

        for (relays) |relay| {
            try w(&results, allocator, "  {s}: ", .{relay});
            const result = self.publishToRelay(allocator, relay, event_json);
            if (result) |resp| {
                defer allocator.free(resp);
                try w(&results, allocator, "{s}\n", .{resp[0..@min(resp.len, 100)]});
            } else {
                try w(&results, allocator, "FAILED\n", .{});
            }
        }

        return ToolResult.okAlloc(allocator, results.items);
    }

    /// Read posts from a Clawstr subclaw community.
    fn actionClawstrRead(_: *NostrTool, allocator: std.mem.Allocator, relays: []const []const u8, args: JsonObjectMap) !ToolResult {
        const subclaw = root.getString(args, "subclaw") orelse
            return ToolResult.fail("Missing 'subclaw' parameter. Specify the community name (e.g. ai-freedom, videogames).");

        const limit: u32 = if (root.getInt(args, "filter_limit")) |l|
            @intCast(l)
        else
            30;

        const subclaw_url = try std.fmt.allocPrint(allocator, "https://clawstr.com/c/{s}", .{subclaw});
        defer allocator.free(subclaw_url);

        // Build Clawstr filter: kinds [1111], #I [subclaw_url], #K [web], #l [ai], #L [agent]
        const filter_json = try std.fmt.allocPrint(allocator,
            \\"{{"kinds":[1111],"#I":["{s}"],"#K":["web"],"#l":["ai"],"#L":["agent"],"limit":{d}}}\\
        , .{ subclaw_url, limit });
        defer allocator.free(filter_json);

        // Query relays sequentially (avoids TLS thread issues)
        var all_events: std.ArrayListUnmanaged(nostr.Event) = .empty;
        defer {
            for (all_events.items) |*e| nostr.freeEvent(e.*, allocator);
            all_events.deinit(allocator);
        }

        for (relays) |relay| {
            var client = nostr.RelayClient.connect(allocator, relay) catch |err| {
                log.warn("clawstr_read: connect to {s} failed: {}", .{ relay, err });
                continue;
            };
            defer client.deinit();

            // Set read timeout for one-shot reads so readMessage() doesn't block forever.
            client.setReadTimeout(10_000);

            const sub_id = client.subscribe(filter_json) catch |err| {
                log.warn("clawstr_read: subscribe to {s} failed: {}", .{ relay, err });
                continue;
            };
            defer allocator.free(sub_id);

            // Collect events until EOSE or timeout
            const timeout_ns: u64 = 8 * std.time.ns_per_s;
            const start = util.nanoTimestamp();
            var local_events: std.ArrayListUnmanaged(nostr.Event) = .empty;

            while (util.nanoTimestamp() - start < timeout_ns) {
                const msg = client.readMessage() catch break;
                if (msg) |m| {
                    defer allocator.free(m);
                    if (std.mem.indexOf(u8, m, "\"EOSE\"") != null) break;
                    if (std.mem.indexOf(u8, m, "\"EVENT\"") != null) {
                        if (nostr.parseEventJson(allocator, m)) |ev| {
                            local_events.append(allocator, ev) catch {};
                        } else |_| {}
                    }
                } else break;
            }

            for (local_events.items) |ev| {
                // Dedup by event ID
                var dup = false;
                for (all_events.items) |existing| {
                    if (std.mem.eql(u8, &existing.id, &ev.id)) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) {
                    all_events.append(allocator, ev) catch continue;
                } else {
                    nostr.freeEvent(ev, allocator);
                }
            }
            local_events.deinit(allocator);
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

        try w(&results, allocator, "Clawstr c/{s} — {d} posts\n", .{ subclaw, all_events.items.len });

        // Sort by created_at descending
        std.mem.sort(nostr.Event, all_events.items, {}, struct {
            fn lessThan(_: void, a: nostr.Event, b: nostr.Event) bool {
                return a.created_at > b.created_at;
            }
        }.lessThan);

        for (all_events.items, 0..) |ev, i| {
            const pk_hex = nostr.hexEncode32(ev.pubkey);
            try w(&results, allocator, "\n--- Post {d} ---\n", .{i + 1});
            try w(&results, allocator, "Author: {s}\n", .{&pk_hex});
            try w(&results, allocator, "Time: {d}\n", .{ev.created_at});
            try w(&results, allocator, "ID: ", .{});
            const id_hex = nostr.hexEncode32(ev.id);
            try w(&results, allocator, "{s}\n", .{&id_hex});
            try w(&results, allocator, "{s}\n", .{ev.content});
        }

        if (all_events.items.len == 0) {
            try w(&results, allocator, "\nNo posts found in c/{s}.\n", .{subclaw});
        }

        return ToolResult.okAlloc(allocator, results.items);
    }

    // ── Helpers ────────────────────────────────────────────────────

    fn publishToRelay(self: *NostrTool, allocator: std.mem.Allocator, relay: []const u8, event_json: []const u8) ?[]const u8 {
        _ = self;
        var client = nostr.RelayClient.connect(allocator, relay) catch |err| {
            log.warn("publishToRelay: connect to {s} failed: {}", .{ relay, err });
            return null;
        };
        defer client.deinit();

        return client.publish(event_json) catch |err| {
            log.warn("publishToRelay: publish to {s} failed: {}", .{ relay, err });
            return null;
        };
    }

    /// Load private key from nullclaw config, or auto-generate one.
    /// Priority: config channels.nostr_public.private_key > .nostr_key file > auto-generate.
    fn loadPrivateKey(self: *NostrTool, allocator: std.mem.Allocator, io: std.Io) ![32]u8 {
        // 1. Try config.json channels.nostr_public.private_key
        const from_config = try self.loadPrivateKeyFromConfig(allocator, io);
        if (from_config) |sk| {
            log.info("nostr_tool: loaded private key from config", .{});
            return sk;
        }

        // 2. Try .nostr_key file
        const from_file = try self.loadPrivateKeyFromFile(allocator, io);
        if (from_file) |sk| {
            log.info("nostr_tool: loaded private key from .nostr_key file", .{});
            return sk;
        }

        // 3. Auto-generate a new keypair and save it
        log.warn("nostr_tool: no existing key found, generating new keypair", .{});
        return try self.generateAndSaveKey(allocator, io);
    }

    /// Load private key from config.json channels.nostr_public.private_key.
    fn loadPrivateKeyFromConfig(self: *NostrTool, allocator: std.mem.Allocator, io: std.Io) !?[32]u8 {
        const config_path = std.fmt.allocPrint(allocator, "{s}/config.json", .{self.config_dir}) catch
            return null;
        defer allocator.free(config_path);

        const content = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(64 * 1024)) catch return null;
        defer allocator.free(content);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
        defer parsed.deinit();

        const root_obj = if (parsed.value == .object) parsed.value.object else return null;
        const channels = root_obj.get("channels") orelse return null;
        if (channels != .object) return null;

        // Try nostr_public first, then nostr
        const nostr_public = channels.object.get("nostr_public") orelse
            channels.object.get("nostr") orelse return null;
        if (nostr_public != .object) return null;

        const pk_val = nostr_public.object.get("private_key") orelse return null;
        if (pk_val != .string) return null;

        // Try hex decode first, then encrypted
        if (pk_val.string.len == 64) {
            if (nostr.hexDecodeFixed(32, pk_val.string)) |sk| return sk else |_| {}
        }

        // Try encrypted (enc2:...)
        const secrets_mod = @import("../security/secrets.zig");
        const store = secrets_mod.SecretStore.init(self.config_dir, true);
        const decrypted = store.decryptSecret(allocator, pk_val.string) catch return null;
        defer allocator.free(decrypted);
        const sk = nostr.hexDecodeFixed(32, decrypted) catch return null;
        return sk;
    }

    /// Load private key from .nostr_key file (auto-generated keys).
    fn loadPrivateKeyFromFile(self: *NostrTool, allocator: std.mem.Allocator, io: std.Io) !?[32]u8 {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const key_file_name = "/.nostr_key";
        const path_total = @min(self.config_dir.len + key_file_name.len, path_buf.len);
        @memcpy(path_buf[0..self.config_dir.len], self.config_dir);
        @memcpy(path_buf[self.config_dir.len..][0..key_file_name.len], key_file_name);
        const key_file_path = path_buf[0..path_total];

        // Use readFileAlloc to avoid reader buffering issues with std.Io in threads
        const content = std.Io.Dir.cwd().readFileAlloc(io, key_file_path, allocator, .limited(1024)) catch return null;
        defer allocator.free(content);

        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (trimmed.len == 0) return null;

        // Decrypt
        const secrets_mod = @import("../security/secrets.zig");
        const store = secrets_mod.SecretStore.init(self.config_dir, true);
        const decrypted = store.decryptSecret(allocator, trimmed) catch |err| {
            log.warn("nostr_tool: failed to decrypt .nostr_key: {} (file exists, key may have changed)", .{err});
            return null;
        };
        defer allocator.free(decrypted);

        const sk = nostr.hexDecodeFixed(32, decrypted) catch return null;
        return sk;
    }

    /// Generate a fresh nostr keypair, encrypt it, and save to .nostr_key file.
    fn generateAndSaveKey(self: *NostrTool, allocator: std.mem.Allocator, io: std.Io) ![32]u8 {
        const secrets_mod = @import("../security/secrets.zig");
        const store = secrets_mod.SecretStore.init(self.config_dir, true);

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

        // Encrypt and save
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const key_file_name = "/.nostr_key";
        const path_total = @min(self.config_dir.len + key_file_name.len, path_buf.len);
        @memcpy(path_buf[0..self.config_dir.len], self.config_dir);
        @memcpy(path_buf[self.config_dir.len..][0..key_file_name.len], key_file_name);
        const key_file_path = path_buf[0..path_total];

        const encrypted = store.encryptSecret(allocator, &sk_hex) catch |err| {
            log.warn("nostr_tool: failed to encrypt generated key: {} — using in-memory only", .{err});
            return sk_bytes;
        };
        defer allocator.free(encrypted);

        const file = std.Io.Dir.cwd().createFile(io, key_file_path, .{}) catch |err| {
            log.warn("nostr_tool: failed to write .nostr_key: {} — using in-memory only", .{err});
            return sk_bytes;
        };
        defer file.close(io);
        if (@import("builtin").os.tag != .windows) {
            file.setPermissions(io, @enumFromInt(0o600)) catch {};
        }
        file.writeStreamingAll(io, encrypted) catch |err| {
            log.warn("nostr_tool: failed to write .nostr_key content: {}", .{err});
        };

        log.info("nostr_tool: AUTO-GENERATED new nostr keypair", .{});
        log.info("nostr_tool:   pubkey (hex): {s}", .{&pk_hex});
        log.info("nostr_tool:   saved to: {s}", .{key_file_path});

        return sk_bytes;
    }

    /// Load relay URLs from nullclaw config.
    fn loadRelays(self: *NostrTool, allocator: std.mem.Allocator, io: std.Io) ![][]const u8 {
        const config_path = std.fmt.allocPrint(allocator, "{s}/config.json", .{self.config_dir}) catch return &.{};
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

        // Collect from nostr_public and nostr channels, deduplicating
        const channel_names = [_][]const u8{ "nostr_public", "nostr" };
        for (channel_names) |ch_name| {
            const ch = channels.object.get(ch_name) orelse continue;
            if (ch != .object) continue;
            const relays_val = ch.object.get("relays") orelse continue;
            if (relays_val != .array) continue;
            for (relays_val.array.items) |rv| {
                if (rv != .string) continue;
                // Dedup
                var dup = false;
                for (seen.items) |s| {
                    if (std.mem.eql(u8, s, rv.string)) { dup = true; break; }
                }
                if (!dup) {
                    try seen.append(allocator, try allocator.dupe(u8, rv.string));
                    try relays.append(allocator, try allocator.dupe(u8, rv.string));
                }
            }
        }
        if (relays.items.len == 0) return &.{};

        return relays.items;
    }
};

// ── Tests ───────────────────────────────────────────────────────────


test "nostr tool name and description" {
    var nt = NostrTool{ .config_dir = "/tmp", .allocator = std.testing.allocator };
    const t = nt.tool();
    try std.testing.expectEqualStrings("nostr", t.name());
    try std.testing.expect(t.description().len > 0);
}

test "nostr tool schema has required fields" {
    var nt = NostrTool{ .config_dir = "/tmp", .allocator = std.testing.allocator };
    const t = nt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "action") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "post") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "read") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "react") != null);
}

test "nostr tool missing action returns error" {
    var nt = NostrTool{ .config_dir = "/tmp", .allocator = std.testing.allocator };
    const t = nt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
    try std.testing.expect(!result.success);
}

test "nostr tool unknown action returns error" {
    var nt = NostrTool{ .config_dir = "/tmp", .allocator = std.testing.allocator };
    const t = nt.tool();
    const parsed = try root.parseTestArgs("{\"action\":\"fly\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
    try std.testing.expect(!result.success);
}

// ── Integration tests (require network) ─────────────────────────────

test "nostr tool search across multiple relays in parallel" {
    // Integration test: connects to real WebSocket relays.
    // SKIP: vendored karlseguin/websocket.zig ABRTs in readMessage() on Zig 0.16.
    // TODO: unskip after fixing ws client or migrating to std.http.websocket
    if (true) return;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var nt = NostrTool{ .config_dir = "/tmp", .allocator = allocator };
    const t = nt.tool();
    const parsed = try root.parseTestArgs(
        "{\"action\":\"search\",\"query\":\"zig programming language\",\"relays\":[\"wss://relay.damus.io\",\"wss://nos.lol\"],\"filter_limit\":5}"
    );
    defer parsed.deinit();
    const result = t.execute(allocator, parsed.parsed.value.object, std.testing.io) catch return;
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "relay(s)") != null);
}

test "nostr tool read from relay" {
    // Integration test: connects to real WebSocket relay.
    // SKIP: freeEvent() ABRTs when freeing parsed event tags on Zig 0.16.
    // TODO: unskip after fixing freeEvent or migrating event parser.
    if (true) return;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var nt = NostrTool{ .config_dir = "/tmp", .allocator = allocator };
    const t = nt.tool();
    const parsed = try root.parseTestArgs("{\"action\":\"read\",\"relays\":[\"wss://relay.damus.io\"],\"filter_kinds\":[1],\"filter_limit\":3}");
    defer parsed.deinit();
    const result = t.execute(allocator, parsed.parsed.value.object, std.testing.io) catch return;
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "kind=1") != null);
}
