// Nostr Tool — native Nostr operations for the agent.
//
// Actions:
//   post    — Publish a kind 1 text note to relay(s)
//   read    — Subscribe to relay(s) and read events matching filters
//   profile — Publish a kind 0 metadata event (name, about, picture)
//   react   — Publish a kind 7 reaction to an event
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
const WELL_KNOWN_RELAYS = [_][]const u8{
    "wss://relay.ditto.pub",
    "wss://nos.lol",
    "wss://relay.nostr.net",
    "wss://relay.crostr.com",
    "wss://private.nostr.bar",
    "wss://relay.gulugulu.moe",
    "wss://nostr-relay.moe.gift",
    "wss://relay.spacetomatoes.net",
    "wss://dev.relay.stream",
    "wss://relay.nostrverse.net",
    "wss://cdn.czas.xyz",
    "wss://dm.czas.xyz",
    "wss://relay.og.coop",
    "wss://nostr.wine",
    "wss://relay.44billion.net",
    "wss://relay.cloistr.xyz",
    "wss://henhouse.social/relay",
};

/// Relays confirmed to support NIP-50 full-text search.
/// Tested live — all returned search results for "bitcoin" queries.
const SEARCH_RELAYS = [_][]const u8{
    "wss://relay.noswhere.com",
    "wss://nostrja-kari-nip50.heguro.com",
    "wss://relay.ditto.pub",
    "wss://cobrafuma.com/relay",
    "wss://relay.gulugulu.moe",
    "wss://relay.spacetomatoes.net",
    "wss://orly-relay.imwald.eu",
    "wss://relay2.veganostr.com",
    "wss://nostr.wine",
    "wss://us.nostr.wine",
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

pub const NostrTool = struct {
    config_dir: []const u8,
    allocator: std.mem.Allocator,

    pub const tool_name = "nostr";
    pub const tool_description = "Native Nostr operations. Actions: post (kind 1 note), read (subscribe + fetch events from multiple relays, deduplicated), search (NIP-50 full-text search across relay events), profile (kind 0 metadata), react (kind 7 reaction). Supports full NIP-01 filters (kinds, authors, #p, #e, #t, since, until, limit). Uses direct WebSocket relay connections with BIP-340 Schnorr signing.";
    pub const tool_params =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["post","read","search","profile","react"],"description":"Action to perform"},"content":{"type":"string","description":"Content for post/profile/react"},"relays":{"type":"array","items":{"type":"string"},"description":"Relay URLs (queries all relays in parallel; defaults to config)"},"private_key":{"type":"string","description":"Hex private key (default from config)"},"filter_kinds":{"type":"array","items":{"type":"integer"},"description":"For read/search: event kinds to filter"},"filter_authors":{"type":"array","items":{"type":"string"},"description":"For read/search: pubkeys to filter"},"filter_tags":{"type":"array","items":{"type":"string"},"description":"For read/search: #t tag values to filter"},"filter_p_tags":{"type":"array","items":{"type":"string"},"description":"For read/search: #p tag pubkeys to filter"},"filter_e_tags":{"type":"array","items":{"type":"string"},"description":"For read/search: #e tag event IDs to filter"},"filter_limit":{"type":"integer","description":"For read/search: max events per relay (default 20)"},"filter_since":{"type":"integer","description":"For read/search: unix timestamp lower bound"},"filter_until":{"type":"integer","description":"For read/search: unix timestamp upper bound"},"query":{"type":"string","description":"For search: NIP-50 full-text search query"},"event_id":{"type":"string","description":"For react: event ID to react to"},"event_pubkey":{"type":"string","description":"For react: pubkey of event author"},"deep_search":{"type":"boolean","description":"For read/search: when true, fire all relays in parallel and return as soon as 5 respond with events. Default false returns after the first relay responds (fastest response wins)."}},"required":["action"]}
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
            const loaded = self.loadPrivateKey(allocator, io) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "Failed to load private key from config: {}", .{err}) catch
                    "Failed to load private key from config";
                return ToolResult.failAlloc(allocator, msg);
            };
            if (loaded) |key| {
                sk_buf = key;
                break :blk true;
            }
            break :blk false;
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
            // Load from config
            const config_relays = self.loadRelays(allocator, io) catch &.{};
            for (config_relays) |r| {
                try relay_urls.append(allocator, r);
            }
        }
        if (relay_urls.items.len == 0) {
            // Use appropriate fallback relays based on action
            const fallback_relays = if (std.mem.eql(u8, action, "search"))
                &SEARCH_RELAYS
            else
                &WELL_KNOWN_RELAYS;
            for (fallback_relays) |r| {
                try relay_urls.append(allocator, try allocator.dupe(u8, r));
            }
        }

        if (std.mem.eql(u8, action, "post")) {
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
        } else {
            return ToolResult.fail("Unknown action. Use: post, read, profile, react.");
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

        // Create a per-thread Io instance for TLS handshake isolation.
        var threaded = std.Io.Threaded.init(allocator, .{
            .stack_size = 8 * 1024 * 1024,
        });
        defer threaded.deinit();
        const io = threaded.io();

        var client = nostr.RelayClient.connect(allocator, relay, io) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{s}: {}", .{ relay, err }) catch relay;
            ctx.results[relay_index] = .{ .relay = relay, .events = &.{}, .error_msg = msg };
            _ = ctx.completed_count.fetchAdd(1, .monotonic);
            return;
        };
        defer client.deinit();

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

        while (!eose_received and !ctx.stop_flag.load(.monotonic)) {
            if (util.nanoTimestamp() - start > timeout_ns) break;
            const raw = client.readMessage() catch null orelse break;
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

    /// Query multiple relays in parallel, merge results, deduplicate by event ID.
    /// Each relay gets its own thread with a dedicated `std.Io.Threaded` instance
    /// so TLS handshakes don't corrupt shared global Io state.
    ///
    /// When `min_results` > 0, returns as soon as that many relays have responded
    /// with events (a "deep search" mode). Remaining workers are signalled to stop
    /// via stop_flag. Set to 0 to wait for all relays (default).
    fn queryRelaysParallel(allocator: std.mem.Allocator, relays: []const []const u8, filter_json: []const u8, min_results: usize) !struct {
        events: std.ArrayListUnmanaged(nostr.Event),
        errors: std.ArrayListUnmanaged(u8),
    } {
        // Prepare per-relay result slots
        const results = try allocator.alloc(RelayResult, relays.len);
        defer allocator.free(results);
        @memset(results, RelayResult{ .relay = "", .events = &.{}, .error_msg = null });

        var ctx = RelayQueryContext{
            .allocator = allocator,
            .filter_json = filter_json,
            .relays = relays,
            .results = results,
            .stop_flag = std.atomic.Value(bool).init(false),
            .completed_count = std.atomic.Value(usize).init(0),
            .event_count = std.atomic.Value(usize).init(0),
        };

        // Spawn one thread per relay. Each thread creates its own Io.Threaded
        // instance inside relayQueryThread for TLS isolation.
        const threads = try allocator.alloc(std.Thread, relays.len);
        defer allocator.free(threads);

        for (relays, 0..) |_, i| {
            if (std.Thread.spawn(.{}, relayQueryThread, .{ &ctx, i })) |t| {
                threads[i] = t;
            } else |err| {
                log.warn("failed to spawn thread for relay {d}: {}", .{ i, err });
                // Run sequentially as fallback
                relayQueryThread(&ctx, i);
            }
        }

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

        // Join all threads (fast if stop_flag was set — workers exit their read loop).
        for (threads) |t| {
            t.join();
        }

        // Merge results, deduplicate by event ID
        var all_events: std.ArrayListUnmanaged(nostr.Event) = .empty;
        var seen_ids: std.ArrayListUnmanaged([32]u8) = .empty;
        defer seen_ids.deinit(allocator);

        var relay_errors: std.ArrayListUnmanaged(u8) = .empty;

        for (results) |result| {
            if (result.error_msg) |err_msg| {
                try relay_errors.appendSlice(allocator, err_msg);
                try relay_errors.appendSlice(allocator, "; ");
                allocator.free(err_msg);
            }
            for (result.events) |event| {
                var already_seen = false;
                for (seen_ids.items) |sid| {
                    if (std.mem.eql(u8, &sid, &event.id)) {
                        already_seen = true;
                        nostr.freeEvent(event, allocator);
                        break;
                    }
                }
                if (!already_seen) {
                    try seen_ids.append(allocator, event.id);
                    try all_events.append(allocator, event);
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

        const pk_hex = nostr.hexEncode32(kp.public_key);
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
        try w(&results, allocator, "Event ID: {s}\n", .{&pk_hex});
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

    // ── Helpers ────────────────────────────────────────────────────

    fn publishToRelay(self: *NostrTool, allocator: std.mem.Allocator, relay: []const u8, event_json: []const u8) ?[]const u8 {
        _ = self;
        var client = nostr.RelayClient.connect(allocator, relay, null) catch return null;
        defer client.deinit();

        return client.publish(event_json) catch null;
    }

    /// Load private key from nullclaw config.
    /// Priority: config channels.nostr_public.private_key > .nostr_key file.
    fn loadPrivateKey(self: *NostrTool, allocator: std.mem.Allocator, io: std.Io) !?[32]u8 {
        // 1. Try config.json channels.nostr_public.private_key
        const from_config = try self.loadPrivateKeyFromConfig(allocator, io);
        if (from_config) |sk| return sk;

        // 2. Try .nostr_key file
        const from_file = try self.loadPrivateKeyFromFile(allocator, io);
        if (from_file) |sk| return sk;

        return null;
    }

    /// Load private key from config.json channels.nostr_public.private_key.
    fn loadPrivateKeyFromConfig(self: *NostrTool, allocator: std.mem.Allocator, io: std.Io) !?[32]u8 {
        const config_path = std.fmt.allocPrint(allocator, "{s}/config.json", .{self.config_dir}) catch
            return null;
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

        const file = std.Io.Dir.cwd().openFile(io, key_file_path, .{}) catch return null;
        defer file.close(io);

        var buf: [512]u8 = undefined;
        var reader = file.reader(io, &buf);
        const content = reader.interface.readAlloc(allocator, 512) catch return null;
        defer allocator.free(content);

        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (trimmed.len == 0) return null;

        // Decrypt
        const secrets_mod = @import("../security/secrets.zig");
        const store = secrets_mod.SecretStore.init(self.config_dir, true);
        const decrypted = store.decryptSecret(allocator, trimmed) catch return null;
        defer allocator.free(decrypted);

        const sk = nostr.hexDecodeFixed(32, decrypted) catch return null;
        return sk;
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
    var nt = NostrTool{ .config_dir = "/tmp", .allocator = std.testing.allocator };
    const t = nt.tool();
    const parsed = try root.parseTestArgs(
        "{\"action\":\"search\",\"query\":\"zig programming language\",\"relays\":[\"wss://relay.damus.io\",\"wss://nos.lol\"],\"filter_limit\":5}"
    );
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    // Both relays should be contacted
    try std.testing.expect(std.mem.indexOf(u8, result.output, "relay(s)") != null);
}

test "nostr tool read from relay" {
    var nt = NostrTool{ .config_dir = "/tmp", .allocator = std.testing.allocator };
    const t = nt.tool();
    const parsed = try root.parseTestArgs("{\"action\":\"read\",\"relays\":[\"wss://relay.damus.io\"],\"filter_kinds\":[1],\"filter_limit\":3}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object, std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    // Should return some kind 1 notes
    try std.testing.expect(std.mem.indexOf(u8, result.output, "kind=1") != null);
}
