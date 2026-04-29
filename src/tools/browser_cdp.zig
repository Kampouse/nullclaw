const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const ws = @import("ws_karlseguin");
const util = @import("../util.zig");
const log = std.log.scoped(.browser_cdp);

// ── CDP Connection Pool ────────────────────────────────────────────
//
// Reuses a single long-lived CDP WebSocket connection across tool calls
// (web_search, web_fetch, browser_cdp).  Avoids ~2 s handshake overhead
// per call and eliminates stale-state issues from repeated target creation.

/// Maximum length of a CDP endpoint string (e.g. "ws://127.0.0.1:9222").
const MAX_ENDPOINT_LEN: usize = 256;

pub const CdpPool = struct {
    mutex: std.atomic.Mutex = .unlocked,
    client: ?*CdpClient = null,
    stored_endpoint: [MAX_ENDPOINT_LEN]u8 = undefined,
    stored_len: usize = 0,
    /// Heap allocator used to create the long-lived CdpClient.
    /// Set once on first acquire; must outlive the pool.
    heap_allocator: ?std.mem.Allocator = null,

    /// Return the global singleton pool instance.
    pub fn global() *CdpPool {
        const S = struct {
            var instance: CdpPool = .{};
        };
        return &S.instance;
    }

    inline fn lock(self: *CdpPool) void {
        while (!self.mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    inline fn unlock(self: *CdpPool) void {
        self.mutex.unlock();
    }

    /// Acquire a CDP client from the pool.
    ///
    /// * If a live client for `endpoint` already exists, it is returned after
    ///   clearing the event buffer and navigating to about:blank for a clean
    ///   slate.
    /// * If no client exists (first call) or the connection has dropped, a
    ///   fresh one is created using `heap_allocator`.
    /// * If the endpoint changed, the old client is destroyed first.
    ///
    /// `heap_allocator` is only used on the very first acquire; subsequent
    /// calls may pass `undefined` for it.
    pub fn acquire(self: *CdpPool, heap_allocator: std.mem.Allocator, endpoint: []const u8) !*CdpClient {
        log.info("[TRACE] CdpPool.acquire: endpoint={s}", .{endpoint});
        self.lock();
        defer self.unlock();

        // Store heap allocator on first use
        if (self.heap_allocator == null) {
            self.heap_allocator = heap_allocator;
        }

        // If we already have a client, check if it matches the endpoint
        if (self.client) |existing| {
            const endpoint_matches = self.stored_len == endpoint.len and
                std.mem.eql(u8, self.stored_endpoint[0..self.stored_len], endpoint);

            if (!endpoint_matches) {
                // Endpoint changed — tear down old connection
                log.info("CdpPool: endpoint changed from {s} to {s}, reconnecting", .{
                    self.stored_endpoint[0..self.stored_len],
                    endpoint,
                });
                self.destroyPooled();
            } else {
                // Same endpoint — health check
                if (self.isHealthy(existing)) {
                    log.info("CdpPool: reusing existing connection to {s}", .{endpoint});
                    // Clear stale events from the buffer
                    existing.clearEventBuffer();
                    // Navigate to about:blank for a clean state
                    if (existing.navigateBlank()) {
                        // Success — return the reused client
                        return existing;
                    } else |err| {
                        log.warn("CdpPool: navigate to about:blank failed: {}, reconnecting", .{err});
                        self.destroyPooled();
                        // Fall through to create new client below
                    }
                } else {
                    log.info("CdpPool: health check failed, reconnecting to {s}", .{endpoint});
                    self.destroyPooled();
                }
            }
        }

        // Create a new client
        log.info("CdpPool: creating new CDP connection to {s}", .{endpoint});
        const alloc = self.heap_allocator.?;
        const client = try alloc.create(CdpClient);
        errdefer alloc.destroy(client);
        client.* = try CdpClient.init(alloc, endpoint);

        self.client = client;
        @memcpy(self.stored_endpoint[0..endpoint.len], endpoint);
        self.stored_len = endpoint.len;

        return client;
    }

    /// Return a client to the pool (no-op — the client stays alive for reuse).
    pub fn release(self: *CdpPool, _: *CdpClient) void {
        _ = self;
    }

    /// Destroy the currently pooled client (if any).  Caller must hold the lock.
    pub fn destroyPooled(self: *CdpPool) void {
        if (self.client) |c| {
            log.info("CdpPool: destroying pooled client", .{});
            c.deinit();
            if (self.heap_allocator) |alloc| {
                alloc.destroy(c);
            }
            self.client = null;
        }
    }

    /// Destroy the pooled connection.  Call at process shutdown or when the
    /// browser is known to have exited.
    pub fn destroy(self: *CdpPool) void {
        self.lock();
        defer self.unlock();

        if (self.client) |c| {
            log.info("CdpPool: destroying pooled client (shutdown)", .{});
            c.deinit();
            if (self.heap_allocator) |alloc| {
                alloc.destroy(c);
            }
            self.client = null;
        }
    }

    /// Check if a CDP client connection is still alive by sending a
    /// lightweight Browser.getVersion command.
    fn isHealthy(self: *CdpPool, client: *CdpClient) bool {
        _ = self;
        // Browser.getVersion works on the browser-level WebSocket (no session needed).
        const id = client.next_id;
        client.next_id += 1;
        const cmd = std.fmt.allocPrint(client.allocator,
            "{{\"id\":{d},\"method\":\"Browser.getVersion\"}}",
            .{id}) catch return false;
        defer client.allocator.free(cmd);

        const msg = client.allocator.dupe(u8, cmd) catch return false;
        defer client.allocator.free(msg);
        client.client.write(msg) catch return false;

        // Try to read a response within 2 seconds
        client.client.readTimeout(2000) catch return false;
        const frame_opt = client.client.read() catch return false;
        const frame = frame_opt orelse return false;
        defer client.client.done(frame);

        if (frame.data.len == 0) return false;

        // Just check that we got valid JSON with our id — that proves the
        // connection is alive.
        var parsed = std.json.parseFromSlice(std.json.Value, client.allocator, frame.data, .{}) catch return false;
        defer parsed.deinit();

        if (parsed.value.object.get("id")) |id_val| {
            if (id_val == .integer and id_val.integer == @as(i64, id)) {
                return true;
            }
        }
        return false;
    }
};

/// CDP (Chrome DevTools Protocol) client over WebSocket.
/// Connects to a headless browser (Lightpanda, Chrome, etc.) and exposes
/// page interaction: navigate, click, type, scroll, evaluate JS, snapshot DOM.
pub const BrowserCdpTool = struct {
    allocator: std.mem.Allocator,
    cdp_endpoint: []const u8,

    pub const tool_name = "browser_cdp";
    pub const tool_description =
        "Interact with a headless browser via CDP. Actions: search, navigate, click, type_text, scroll, evaluate, snapshot, wait_for, hover, keyboard, go_back, go_forward, set_viewport, close." ++
        " The 'search' action performs a full web search (DuckDuckGo) and returns structured results (title, url, snippet)." ++
        " 'wait_for' polls until a CSS selector appears (useful for SPAs). 'keyboard' sends key combos (Enter, Tab, Escape, Ctrl+A)." ++
        " 'hover' triggers mouseover on an element. 'set_viewport' resizes the browser (mobile/tablet/desktop). 'go_back'/'go_forward' navigate browser history." ++
        " Requires a CDP-compatible browser (Lightpanda, Chrome) running with remote debugging enabled.";
    pub const tool_params =
        \\{"type":"object","properties":{
        \\"action":{"type":"string","enum":["search","navigate","click","type_text","scroll","evaluate","snapshot","wait_for","hover","keyboard","go_back","go_forward","set_viewport","close"],"description":"CDP action to perform"},
        \\"url":{"type":"string","description":"URL to navigate to (for navigate action)"},
        \\"selector":{"type":"string","description":"CSS selector for click, type_text, wait_for, hover"},
        \\"text":{"type":"string","description":"Text to type (for type_text action)"},
        \\"expression":{"type":"string","description":"JavaScript expression to evaluate (for evaluate action)"},
        \\"direction":{"type":"string","enum":["up","down"],"description":"Scroll direction (for scroll action)"},
        \\"amount":{"type":"integer","default":500,"description":"Scroll amount in pixels (for scroll action)"},
        \\"query":{"type":"string","description":"Search query (for search action)"},
        \\"count":{"type":"integer","minimum":1,"maximum":10,"default":5,"description":"Number of search results (for search action)"},
        \\"timeout":{"type":"integer","default":10000,"description":"Timeout in ms for wait_for action"},
        \\"key":{"type":"string","description":"Key to press for keyboard action. Examples: Enter, Tab, Escape, Backspace, a, ArrowDown, F5. Use Ctrl+A, Ctrl+C, Ctrl+V, Shift+Tab for combos"},
        \\"width":{"type":"integer","default":1280,"description":"Viewport width in pixels (for set_viewport action)"},
        \\"height":{"type":"integer","default":720,"description":"Viewport height in pixels (for set_viewport action)"},
        \\"preset":{"type":"string","enum":["mobile","tablet","desktop"],"description":"Viewport preset for set_viewport. mobile=375x812, tablet=768x1024, desktop=1280x720. Overrides width/height if set"}
        \\},"required":["action"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *BrowserCdpTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn deinit(self: *BrowserCdpTool, allocator: std.mem.Allocator) void {
        _ = allocator;
        _ = self;
    }

    const MAX_RETRIES: u32 = 1;

    pub fn execute(self: *BrowserCdpTool, allocator: std.mem.Allocator, args: JsonObjectMap, io: std.Io) anyerror!ToolResult {
        _ = io;
        const action = root.getString(args, "action") orelse
            return ToolResult.fail("Missing 'action' parameter");

        // Use the persistent CDP pool instead of creating a fresh connection per call.
        const pool = CdpPool.global();

        // Retry loop: on transient connection errors, destroy the pool connection
        // and try again with a fresh one.
        var retries: u32 = 0;
        while (true) {
            const cdp = pool.acquire(std.heap.page_allocator, self.cdp_endpoint) catch |err| {
                if (retries < MAX_RETRIES) {
                    log.warn("execute: acquire failed (attempt {d}): {}, retrying...", .{ retries + 1, err });
                    retries += 1;
                    continue;
                }
                const msg = try std.fmt.allocPrint(allocator, "Failed to connect to CDP at {s}: {}", .{ self.cdp_endpoint, err });
                return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
            };
            defer pool.release(cdp);

            const result = self.dispatchAction(allocator, cdp, action, args);

            // On transient errors, retry with fresh connection
            if (retries < MAX_RETRIES) {
                if (result) |r| {
                    if (!r.success) {
                        // Check if the error looks transient (connection-related)
                        if (r.error_msg) |em| {
                            if (em.len > 0 and self.isTransientError(em)) {
                                log.warn("execute: action failed with transient error, retrying...", .{});
                                pool.destroyPooled();
                                retries += 1;
                                continue;
                            }
                        }
                    }
                    return r;
                } else |err| {
                    // Zig-level error — likely connection failure
                    log.warn("execute: action threw error (attempt {d}): {}, retrying...", .{ retries + 1, err });
                    pool.destroyPooled();
                    retries += 1;
                    continue;
                }
            }

            return result;
        }
    }

    /// Check if an error message indicates a transient connection issue.
    fn isTransientError(_: *BrowserCdpTool, msg: []const u8) bool {
        // Look for common transient error substrings
        const needles = [_][]const u8{
            "ConnectionResetByPeer",
            "ConnectionClosed",
            "CdpConnectionClosed",
            "CdpTimeout",
            "BrokenPipe",
            "read error",
            "write error",
        };
        for (needles) |needle| {
            if (std.mem.indexOf(u8, msg, needle) != null) return true;
        }
        return false;
    }

    fn dispatchAction(self: *BrowserCdpTool, allocator: std.mem.Allocator, cdp: *CdpClient, action: []const u8, args: JsonObjectMap) anyerror!ToolResult {
        if (std.mem.eql(u8, action, "search")) {
            return try self.actionSearch(allocator, cdp, args);
        } else if (std.mem.eql(u8, action, "navigate")) {
            return try self.actionNavigate(allocator, cdp, args);
        } else if (std.mem.eql(u8, action, "click")) {
            return try self.actionClick(allocator, cdp, args);
        } else if (std.mem.eql(u8, action, "type_text")) {
            return try self.actionType(allocator, cdp, args);
        } else if (std.mem.eql(u8, action, "scroll")) {
            return try self.actionScroll(allocator, cdp, args);
        } else if (std.mem.eql(u8, action, "evaluate")) {
            return try self.actionEvaluate(allocator, cdp, args);
        } else if (std.mem.eql(u8, action, "snapshot")) {
            return try self.actionSnapshot(allocator, cdp);
        } else if (std.mem.eql(u8, action, "wait_for")) {
            return try self.actionWaitFor(allocator, cdp, args);
        } else if (std.mem.eql(u8, action, "hover")) {
            return try self.actionHover(allocator, cdp, args);
        } else if (std.mem.eql(u8, action, "keyboard")) {
            return try self.actionKeyboard(allocator, cdp, args);
        } else if (std.mem.eql(u8, action, "go_back")) {
            return try self.actionGoBack(allocator, cdp);
        } else if (std.mem.eql(u8, action, "go_forward")) {
            return try self.actionGoForward(allocator, cdp);
        } else if (std.mem.eql(u8, action, "set_viewport")) {
            return try self.actionSetViewport(allocator, cdp, args);
        } else if (std.mem.eql(u8, action, "close")) {
            return ToolResult.ok("Tab closed.");
        } else {
            const msg = try std.fmt.allocPrint(allocator, "Unknown browser_cdp action '{s}'", .{action});
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        }
    }

    // ── Actions ─────────────────────────────────────────────────────

    /// Perform a full web search using DuckDuckGo (lite HTML version).
    /// All steps run in a single CDP connection: navigate → extract → return JSON.
    /// Public so web_search tool can delegate to browser-based search.
    pub fn actionSearch(_: *BrowserCdpTool, allocator: std.mem.Allocator, cdp: *CdpClient, args: JsonObjectMap) !ToolResult {
        const query = root.getString(args, "query") orelse
            return ToolResult.fail("Missing 'query' parameter for search action");
        const count = root.getInt(args, "count") orelse 5;
        const max_results = if (count < 1) 1 else if (count > 10) @as(i64, 10) else count;

        log.info("[TRACE] actionSearch: query='{s}' count={d}", .{ query, max_results });

        // 1. Navigate to DuckDuckGo lite (HTML-only, no JS required)
        log.info("[TRACE] actionSearch: calling Page.enable", .{});
        _ = try cdp.send("Page.enable", .{});
        log.info("[TRACE] actionSearch: Page.enable done", .{});
        const search_url = try std.fmt.allocPrint(allocator, "https://lite.duckduckgo.com/lite/?q={s}", .{query});
        defer allocator.free(search_url);
        _ = try cdp.send("Page.navigate", .{ .url = search_url });
        log.info("[TRACE] actionSearch: Page.navigate done, waiting for loadEventFired", .{});
        try cdp.waitForEvent("Page.loadEventFired", 10000);
        log.info("[TRACE] actionSearch: loadEventFired received", .{});

        // Wait a bit for DOM to settle after load
        util.sleep(500_000_000);

        // 2. Extract search results from DOM using JS.
        log.info("[TRACE] actionSearch: building JS extraction expression", .{});
        // DuckDuckGo lite: a.result-link inside TD inside TR,
        // snippet in next TR's td.result-snippet.
        // URLs are DDG redirects — decode uddg param for real URL.
        // Fallback: try broader selectors if result-link class not found.
        const js = try std.fmt.allocPrint(allocator,
            "(function(){{" ++
            "var r=[];" ++
            // Try DDG lite selectors first
            "var links=document.querySelectorAll('a.result-link');" ++
            "if(links.length===0){{" ++
            // Fallback: any link inside a table cell that looks like a search result
            "links=document.querySelectorAll('td a[href*=\"uddg\"]');" ++
            "if(links.length===0){{" ++
            // Last fallback: dump first few links for debugging
            "var all=document.querySelectorAll('a[href]');" ++
            "var dbg=[];for(var i=0;i<Math.min(all.length,10);i++){{dbg.push(all[i].href+'|'+all[i].textContent.trim().substring(0,50));}}" ++
            "return JSON.stringify({{results:[],debug:dbg,page_len:document.documentElement.outerHTML.length}});" ++
            "}}" ++
            "}}" ++
            "var n=Math.min(links.length,{d});" ++
            "for(var i=0;i<n;i++){{" ++
            "var a=links[i];" ++
            "var tr=a.closest('tr');" ++
            "var nx=tr?tr.nextElementSibling:null;" ++
            "var st=nx?nx.querySelector('td.result-snippet'):null;" ++
            // Also check previous sibling for snippet
            "if(!st&&tr){{var pv=tr.previousElementSibling;st=pv?pv.querySelector('td.result-snippet'):null;}}" ++
            // Also check parent row's next td
            "if(!st){{var td=a.closest('td');if(td){{st=td.nextElementSibling;}}}}" ++
            "var t=a.textContent.trim();" ++
            "var u=a.href;" ++
            "try{{var p=new URL(u);var d=p.searchParams.get('uddg');if(d)u=d;}}catch(e){{}}" ++
            "var s=st?st.textContent.trim():'';" ++
            "if(t){{r.push({{title:t,url:u,snippet:s}});}}" ++
            "}}" ++
            "return JSON.stringify(r);" ++
            "}})()",
            .{max_results});
        defer allocator.free(js);

        log.info("[TRACE] actionSearch: calling Runtime.evaluate ({} bytes)", .{js.len});
        const eval_result = try cdp.send("Runtime.evaluate", .{ .expression = js, .returnByValue = true });
        log.info("[TRACE] actionSearch: Runtime.evaluate returned", .{});

        const results_json: []const u8 = blk: {
            if (CdpClient.extractEvalString(eval_result)) |s| {
                if (s.len > 0) {
                    log.info("[TRACE] actionSearch: value string found, len={}", .{s.len});
                    break :blk s;
                }
            }
            // Log JS error if available
            if (CdpClient.extractEvalResult(eval_result)) |js_result| {
                if (js_result == .object) {
                    if (js_result.object.get("description")) |desc| {
                        if (desc == .string) log.info("[TRACE] actionSearch: JS error: {s}", .{desc.string});
                    }
                }
            }
            break :blk "[]";
        };

        // Build markdown output
        var output = std.ArrayListUnmanaged(u8).empty;
        errdefer output.deinit(allocator);

        try output.appendSlice(allocator, "Search results for \"");
        for (query) |ch| {
            if (ch == '"') try output.appendSlice(allocator, "\\\"") else try output.append(allocator, ch);
        }
        try output.appendSlice(allocator, "\":\n\n");

        // Parse the JSON array of results and format as markdown
        var parsed_results = std.json.parseFromSlice(std.json.Value, allocator, results_json, .{}) catch {
            // If JSON parse fails, return raw results
            try output.appendSlice(allocator, results_json);
            return ToolResult{ .success = true, .output = output.items, .error_msg = "", .owns_error_msg = false };
        };
        defer parsed_results.deinit();

        const results_arr = if (parsed_results.value == .array) parsed_results.value.array else {
            try output.appendSlice(allocator, results_json);
            return ToolResult{ .success = true, .output = output.items, .error_msg = "", .owns_error_msg = false };
        };

        var result_count: usize = 0;
        for (results_arr.items) |item| {
            if (item != .object) continue;
            const title_val = item.object.get("title") orelse continue;
            const url_val = item.object.get("url") orelse continue;
            if (title_val != .string or url_val != .string) continue;

            result_count += 1;
            const num_str = try std.fmt.allocPrint(allocator, "{d}", .{result_count});
            defer allocator.free(num_str);
            try output.appendSlice(allocator, num_str);
            try output.appendSlice(allocator, ". ");
            try output.appendSlice(allocator, title_val.string);
            try output.appendSlice(allocator, "\n   ");
            try output.appendSlice(allocator, url_val.string);

            if (item.object.get("snippet")) |snip| {
                if (snip == .string and snip.string.len > 0) {
                    try output.appendSlice(allocator, "\n   ");
                    try output.appendSlice(allocator, snip.string);
                }
            }
            try output.appendSlice(allocator, "\n\n");
        }

        if (result_count == 0) {
            try output.appendSlice(allocator, "No results found.\n");
        }

        return ToolResult{ .success = true, .output = output.items, .error_msg = "", .owns_error_msg = false };
    }

    fn actionNavigate(_: *BrowserCdpTool, allocator: std.mem.Allocator, cdp: *CdpClient, args: JsonObjectMap) !ToolResult {
        const url = root.getString(args, "url") orelse
            return ToolResult.fail("Missing 'url' parameter for navigate action");

        _ = try cdp.send("Page.enable", .{});
        _ = try cdp.send("Page.navigate", .{ .url = url });
        // Wait for page load
        try cdp.waitForEvent("Page.loadEventFired", 10000);

        // Get page title
        const title_result = try cdp.send("Runtime.evaluate", .{ .expression = "document.title" });
        const title = CdpClient.extractEvalString(title_result) orelse "unknown";

        const msg = try std.fmt.allocPrint(allocator, "Navigated to {s}\nTitle: {s}", .{ url, title });
        return ToolResult{ .success = true, .output = msg, .owns_output = true };
    }

    fn actionClick(_: *BrowserCdpTool, allocator: std.mem.Allocator, cdp: *CdpClient, args: JsonObjectMap) !ToolResult {
        const selector = root.getString(args, "selector") orelse
            return ToolResult.fail("Missing 'selector' parameter for click action");

        _ = try cdp.send("Runtime.enable", .{});
        _ = try cdp.send("DOM.enable", .{});

        // Resolve selector to node ID via JS
        const js = try std.fmt.allocPrint(allocator, "document.querySelector('{s}')", .{selector});
        defer allocator.free(js);

        const eval_result = try cdp.send("Runtime.evaluate", .{ .expression = js });
        const remote_obj = if (eval_result.object.get("result")) |r| brk: {
            if (r == .object) {
                if (r.object.get("objectId")) |oid| {
                    if (oid == .string) break :brk oid.string;
                }
            }
            const msg = try std.fmt.allocPrint(allocator, "Element not found: {s}", .{selector});
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        } else {
            const msg = try std.fmt.allocPrint(allocator, "Element not found: {s}", .{selector});
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        };

        // Dispatch click via JS (simpler and more reliable than CDP DOM events)
        const click_js = try std.fmt.allocPrint(allocator,
            "document.querySelector('{s}').click(); 'clicked'", .{selector});
        defer allocator.free(click_js);

        const click_result = try cdp.send("Runtime.evaluate", .{ .expression = click_js });

        // Release remote object
        if (remote_obj.len > 0) {
            _ = try cdp.send("Runtime.releaseObject", .{ .objectId = remote_obj });
        }

        const value = CdpClient.extractEvalString(click_result) orelse "ok";

        const msg = try std.fmt.allocPrint(allocator, "Clicked {s}: {s}", .{ selector, value });
        return ToolResult{ .success = true, .output = msg, .owns_output = true };
    }

    fn actionType(_: *BrowserCdpTool, allocator: std.mem.Allocator, cdp: *CdpClient, args: JsonObjectMap) !ToolResult {
        const selector = root.getString(args, "selector") orelse
            return ToolResult.fail("Missing 'selector' parameter for type_text action");
        const text = root.getString(args, "text") orelse
            return ToolResult.fail("Missing 'text' parameter for type_text action");

        // Use Input.dispatchKeyEvent for reliable typing
        _ = try cdp.send("DOM.enable", .{});
        _ = try cdp.send("Input.enable", .{});

        // Focus element
        const focus_js = try std.fmt.allocPrint(allocator,
            "document.querySelector('{s}').focus(); 'focused'", .{selector});
        defer allocator.free(focus_js);
        _ = try cdp.send("Runtime.evaluate", .{ .expression = focus_js });

        // Type each character via Input.dispatchKeyEvent
        for (text) |char| {
            // keyDown
            _ = try cdp.send("Input.dispatchKeyEvent", .{
                .type = "keyDown",
                .text = &[_]u8{char},
            });
            // keyUp
            _ = try cdp.send("Input.dispatchKeyEvent", .{
                .type = "keyUp",
                .text = &[_]u8{char},
            });
        }

        const msg = try std.fmt.allocPrint(allocator, "Typed '{s}' into {s}", .{ text, selector });
        return ToolResult{ .success = true, .output = msg, .owns_output = true };
    }

    fn actionScroll(_: *BrowserCdpTool, allocator: std.mem.Allocator, cdp: *CdpClient, args: JsonObjectMap) !ToolResult {
        const direction = root.getString(args, "direction") orelse "down";
        const amount = if (root.getInt(args, "amount")) |n| n else 500;

        const dy: i64 = if (std.mem.eql(u8, direction, "up")) -amount else amount;

        const js = try std.fmt.allocPrint(allocator, "window.scrollBy(0, {d}); 'scrolled {d}px {s}'", .{ dy, amount, direction });
        defer allocator.free(js);

        const result = try cdp.send("Runtime.evaluate", .{ .expression = js });
        const value = CdpClient.extractEvalString(result) orelse "ok";

        const msg = try std.fmt.allocPrint(allocator, "Scrolled {s} {d}px: {s}", .{ direction, amount, value });
        return ToolResult{ .success = true, .output = msg, .owns_output = true };
    }

    fn actionEvaluate(_: *BrowserCdpTool, allocator: std.mem.Allocator, cdp: *CdpClient, args: JsonObjectMap) !ToolResult {
        const expression = root.getString(args, "expression") orelse
            return ToolResult.fail("Missing 'expression' parameter for evaluate action");

        const result = try cdp.send("Runtime.evaluate", .{ .expression = expression });
        const output = if (CdpClient.extractEvalResult(result)) |js_result| brk: {
            if (js_result != .object) break :brk try allocator.dupe(u8, "null");
            if (js_result.object.get("value")) |v| {
                if (v == .string) break :brk try allocator.dupe(u8, v.string);
                // Handle non-string values (numbers, bools)
                if (v == .integer) break :brk try std.fmt.allocPrint(allocator, "{d}", .{v.integer});
                if (v == .bool) break :brk try allocator.dupe(u8, if (v.bool) "true" else "false");
            }
            // If value is null but there's a type, it might be undefined
            if (js_result.object.get("type")) |t| {
                if (t == .string) {
                    if (std.mem.eql(u8, t.string, "undefined"))
                        break :brk try allocator.dupe(u8, "undefined");
                }
            }
            break :brk try allocator.dupe(u8, "null");
        } else try allocator.dupe(u8, "null");

        return ToolResult{ .success = true, .output = output, .owns_output = true };
    }

    fn actionSnapshot(_: *BrowserCdpTool, allocator: std.mem.Allocator, cdp: *CdpClient) !ToolResult {
        _ = try cdp.send("Runtime.enable", .{});
        _ = try cdp.send("DOM.enable", .{});

        // Get a simplified DOM snapshot via JS
        const js =
            \\(function() {
            \\  function walk(node, depth) {
            \\    if (depth > 6) return '';
            \\    if (node.nodeType === 3) {
            \\      const t = node.textContent.trim();
            \\      return t ? ' ' + t + ' ' : '';
            \\    }
            \\    if (node.nodeType !== 1) return '';
            \\    const tag = node.tagName.toLowerCase();
            \\    if (['script','style','noscript','svg','path','meta','link'].includes(tag)) return '';
            \\    let out = '';
            \\    if (['a','button','input','select','textarea','img','h1','h2','h3','h4','h5','h6'].includes(tag)) {
            \\      const id = node.id ? '#' + node.id : '';
            \\      const cls = node.className && typeof node.className === 'string' ? '.' + node.className.split(/\s+/).slice(0,2).join('.') : '';
            \\      out += '[' + tag + id + cls + ']';
            \\    }
            \\    for (const child of node.childNodes) {
            \\      out += walk(child, depth + 1);
            \\    }
            \\    if (['p','div','li','tr','h1','h2','h3','h4','h5','h6','br','hr'].includes(tag)) {
            \\      out += '\n';
            \\    }
            \\    return out;
            \\  }
            \\  return walk(document.documentElement, 0).replace(/\n{3,}/g, '\n\n').trim();
            \\})()
        ;

        const result = try cdp.send("Runtime.evaluate", .{ .expression = js, .returnByValue = true });
        const text: ?[]const u8 = CdpClient.extractEvalString(result);

        if (text) |t| {
            // Truncate to 8KB
            const max_bytes: usize = 8192;
            const truncated = t.len > max_bytes;
            const len = if (truncated) max_bytes else t.len;
            const suffix: []const u8 = if (truncated) "\n\n[Content truncated to 8 KB]" else "";
            const output = try std.fmt.allocPrint(allocator, "{s}{s}", .{ t[0..len], suffix });
            return ToolResult{ .success = true, .output = output, .owns_output = true };
        }

        return ToolResult.ok("Page snapshot returned empty content.");
    }

    // ── New Actions ──────────────────────────────────────────────────

    /// Wait for a CSS selector to appear in the DOM. Polls every 200ms
    /// until the element is found or timeout is reached.
    pub fn actionWaitFor(_: *BrowserCdpTool, allocator: std.mem.Allocator, cdp: *CdpClient, args: JsonObjectMap) !ToolResult {
        const selector = root.getString(args, "selector") orelse
            return ToolResult.fail("Missing 'selector' parameter for wait_for action");
        const timeout_ms: u64 = @intCast(root.getInt(args, "timeout") orelse 10000);
        const poll_interval_ns: u64 = 200 * 1_000_000; // 200ms

        const start = util.nanoTimestamp();
        var found = false;

        while (true) {
            const js = try std.fmt.allocPrint(allocator, "!!document.querySelector({s})", .{selector});
            const result = try cdp.send("Runtime.evaluate", .{ .expression = js, .returnByValue = true });
            if (CdpClient.extractEvalString(result)) |val| {
                if (std.mem.eql(u8, val, "true")) {
                    found = true;
                    break;
                }
            }

            const elapsed_ns = util.nanoTimestamp() - start;
            if (elapsed_ns >= timeout_ms * 1_000_000) break;
            util.sleep(poll_interval_ns);
        }

        if (found) {
            return ToolResult.ok("Element found.");
        }
        const msg = try std.fmt.allocPrint(allocator, "Timed out waiting for '{s}' ({d}ms)", .{ selector, timeout_ms });
        return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
    }

    /// Hover over an element matching a CSS selector. Dispatches mouseMoved,
    /// mouseEntered, and mouseOver events. Useful for dropdown menus.
    pub fn actionHover(_: *BrowserCdpTool, allocator: std.mem.Allocator, cdp: *CdpClient, args: JsonObjectMap) !ToolResult {
        const selector = root.getString(args, "selector") orelse
            return ToolResult.fail("Missing 'selector' parameter for hover action");

        // Get element position via JS
        const js = try std.fmt.allocPrint(allocator,
            "(function(){{ try {{ var e=document.querySelector({s}); if(!e) return null; var r=e.getBoundingClientRect(); return {{x:r.x+r.width/2,y:r.y+r.height/2}}; }} catch(err) {{ return {{error:err.message}}; }} }})()",
            .{selector},
        );

        const result = try cdp.send("Runtime.evaluate", .{ .expression = js, .returnByValue = true });
        const val = CdpClient.extractEvalString(result) orelse {
            return ToolResult.fail("Element not found or error evaluating selector");
        };

        // Parse x,y from the result string
        var x: f64 = 0;
        var y: f64 = 0;
        var it = std.mem.splitSequence(u8, val, ",");
        var field_idx: usize = 0;
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " xy:{}\" ");
            if (trimmed.len == 0) continue;
            const num = std.fmt.parseFloat(f64, trimmed) catch continue;
            if (field_idx == 0) x = num else y = num;
            field_idx += 1;
        }

        _ = try cdp.send("Input.dispatchMouseEvent", .{
            .type = "mouseMoved",
            .x = x,
            .y = y,
        });
        _ = try cdp.send("Input.dispatchMouseEvent", .{
            .type = "mousePressed",
            .x = x,
            .y = y,
            .button = "none",
            .clickCount = 0,
        });
        _ = try cdp.send("Input.dispatchMouseEvent", .{
            .type = "mouseReleased",
            .x = x,
            .y = y,
            .button = "none",
            .clickCount = 0,
        });

        const msg = try std.fmt.allocPrint(allocator, "Hovered over '{s}' at ({d}, {d})", .{ selector, x, y });
        return ToolResult.ok(msg);
    }

    /// Send a keyboard key event. Supports simple keys (Enter, Tab, Escape,
    /// Backspace, a, ArrowDown, F5) and combos (Ctrl+A, Ctrl+C, Ctrl+V,
    /// Shift+Tab, Meta+a).
    pub fn actionKeyboard(_: *BrowserCdpTool, allocator: std.mem.Allocator, cdp: *CdpClient, args: JsonObjectMap) !ToolResult {
        const key_spec = root.getString(args, "key") orelse
            return ToolResult.fail("Missing 'key' parameter for keyboard action");

        // Parse optional modifiers from key spec (e.g. "Ctrl+A", "Shift+Tab")
        var modifiers: u8 = 0;
        var key_name: []const u8 = key_spec;

        // Check for modifier prefix
        if (std.mem.indexOf(u8, key_spec, "+")) |plus_idx| {
            const mod_str = key_spec[0..plus_idx];
            key_name = key_spec[plus_idx + 1 ..];

            if (std.ascii.eqlIgnoreCase(mod_str, "ctrl") or std.ascii.eqlIgnoreCase(mod_str, "control")) {
                modifiers = 2; // ctrl bitmask
            } else if (std.ascii.eqlIgnoreCase(mod_str, "shift")) {
                modifiers = 8; // shift bitmask
            } else if (std.ascii.eqlIgnoreCase(mod_str, "alt") or std.ascii.eqlIgnoreCase(mod_str, "option")) {
                modifiers = 1; // alt bitmask
            } else if (std.ascii.eqlIgnoreCase(mod_str, "meta") or std.ascii.eqlIgnoreCase(mod_str, "cmd") or std.ascii.eqlIgnoreCase(mod_str, "command")) {
                modifiers = 4; // meta bitmask
            }
        }

        // Map common key names to CDP key values
        const cdp_key = if (std.mem.eql(u8, key_name, "Enter")) "Enter"
        else if (std.mem.eql(u8, key_name, "Tab")) "Tab"
        else if (std.mem.eql(u8, key_name, "Escape") or std.mem.eql(u8, key_name, "Esc")) "Escape"
        else if (std.mem.eql(u8, key_name, "Backspace")) "Backspace"
        else if (std.mem.eql(u8, key_name, "Delete")) "Delete"
        else if (std.mem.eql(u8, key_name, "ArrowUp")) "ArrowUp"
        else if (std.mem.eql(u8, key_name, "ArrowDown")) "ArrowDown"
        else if (std.mem.eql(u8, key_name, "ArrowLeft")) "ArrowLeft"
        else if (std.mem.eql(u8, key_name, "ArrowRight")) "ArrowRight"
        else if (std.mem.eql(u8, key_name, "Home")) "Home"
        else if (std.mem.eql(u8, key_name, "End")) "End"
        else if (std.mem.eql(u8, key_name, "PageUp")) "PageUp"
        else if (std.mem.eql(u8, key_name, "PageDown")) "PageDown"
        else if (std.mem.eql(u8, key_name, "Space")) " "
        else if (key_name.len == 1) key_name // single character, pass through
        else key_name; // pass through as-is (F1-F12, etc.)

        _ = try cdp.send("Input.dispatchKeyEvent", .{
            .type = "keyDown",
            .key = cdp_key,
            .modifiers = modifiers,
        });
        _ = try cdp.send("Input.dispatchKeyEvent", .{
            .type = "keyUp",
            .key = cdp_key,
            .modifiers = modifiers,
        });

        const msg = try std.fmt.allocPrint(allocator, "Key pressed: {s}", .{key_spec});
        return ToolResult.ok(msg);
    }

    /// Navigate back in browser history.
    pub fn actionGoBack(_: *BrowserCdpTool, allocator: std.mem.Allocator, cdp: *CdpClient) !ToolResult {
        _ = try cdp.send("Page.goBack", .{});
        try cdp.waitForEvent("Page.frameNavigated", 5000);
        const title = try cdp.evalJs(allocator, "document.title");
        const url = try cdp.evalJs(allocator, "window.location.href");
        const msg = try std.fmt.allocPrint(allocator, "Navigated back to: {s} ({s})", .{ title, url });
        return ToolResult.ok(msg);
    }

    /// Navigate forward in browser history.
    pub fn actionGoForward(_: *BrowserCdpTool, allocator: std.mem.Allocator, cdp: *CdpClient) !ToolResult {
        _ = try cdp.send("Page.goForward", .{});
        try cdp.waitForEvent("Page.frameNavigated", 5000);
        const title = try cdp.evalJs(allocator, "document.title");
        const url = try cdp.evalJs(allocator, "window.location.href");
        const msg = try std.fmt.allocPrint(allocator, "Navigated forward to: {s} ({s})", .{ title, url });
        return ToolResult.ok(msg);
    }

    /// Set the browser viewport size. Accepts explicit width/height or a
    /// preset: "mobile" (375x812), "tablet" (768x1024), "desktop" (1280x720).
    pub fn actionSetViewport(_: *BrowserCdpTool, allocator: std.mem.Allocator, cdp: *CdpClient, args: JsonObjectMap) !ToolResult {
        const preset = root.getString(args, "preset");

        const width: i64 = if (preset) |p| blk: {
            if (std.mem.eql(u8, p, "mobile")) break :blk 375;
            if (std.mem.eql(u8, p, "tablet")) break :blk 768;
            if (std.mem.eql(u8, p, "desktop")) break :blk 1280;
            // Unknown preset, fall through to explicit values
            break :blk root.getInt(args, "width") orelse 1280;
        } else root.getInt(args, "width") orelse 1280;

        const height: i64 = if (preset) |p| blk: {
            if (std.mem.eql(u8, p, "mobile")) break :blk 812;
            if (std.mem.eql(u8, p, "tablet")) break :blk 1024;
            if (std.mem.eql(u8, p, "desktop")) break :blk 720;
            break :blk root.getInt(args, "height") orelse 720;
        } else root.getInt(args, "height") orelse 720;

        // Emulation.setDeviceMetricsOverride for best compatibility
        _ = try cdp.send("Emulation.setDeviceMetricsOverride", .{
            .width = width,
            .height = height,
            .deviceScaleFactor = 1,
            .mobile = width <= 768,
        });

        const msg = try std.fmt.allocPrint(allocator, "Viewport set to {d}x{d}", .{ width, height });
        return ToolResult.ok(msg);
    }
};

// ── CDP Client ──────────────────────────────────────────────────────

/// Minimal CDP client that connects via WebSocket, sends commands, and
/// reads responses/events. Supports both:
///   - Chrome-style: direct page-level commands on the WebSocket
///   - Lightpanda-style: browser-level WebSocket with session multiplexing
///
/// Each tool action creates a connection, creates a page target (if needed),
/// performs the action, and closes. No persistent session — stateless per-action.
pub const CdpClient = struct {
    allocator: std.mem.Allocator,
    client: ws.Client,
    next_id: u32,
    /// CDP session ID for page-level commands (Lightpanda multiplexing).
    session_id: []const u8,
    /// Buffer for accumulating event frames while waiting for a specific event.
    event_buffer: std.ArrayListUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !CdpClient {
        log.info("[TRACE] init: parsing endpoint {s}", .{endpoint});
        const parsed = parseEndpoint(endpoint);
        log.info("[TRACE] init: parsed host={s} port={d} tls={}", .{ parsed.host, parsed.port, parsed.tls });

        log.info("[TRACE] init: creating WS client", .{});
        var ws_client = try ws.Client.init(allocator, .{
            .host = parsed.host,
            .port = parsed.port,
            .tls = parsed.tls,
            .max_size = 4 * 1024 * 1024, // 4MB max message
            .buffer_size = 65536,
        });
        errdefer ws_client.deinit();

        log.info("[TRACE] init: WS handshake path={s}", .{parsed.path});
        ws_client.handshake(parsed.path, .{ .timeout_ms = 5000 }) catch |err| {
            log.warn("[TRACE] init: handshake failed: {}", .{err});
            ws_client.deinit();
            return err;
        };
        log.info("[TRACE] init: WS handshake OK", .{});

        var cdp = CdpClient{
            .allocator = allocator,
            .client = ws_client,
            .next_id = 1,
            .session_id = "",
            .event_buffer = .empty,
        };

        // Probe for session-based CDP (Lightpanda).
        log.info("[TRACE] init: calling establishSession", .{});
        cdp.establishSession() catch |err| {
            log.warn("[TRACE] init: establishSession failed (non-fatal): {}", .{err});
        };
        log.info("[TRACE] init: establishSession returned, session_id={s}", .{cdp.session_id});

        // Brief pause to let the WS connection settle — the gateway's IO thread
        // can interfere with socket state during rapid read/write cycles.
        util.sleep(100);

        log.info("[TRACE] init: done, returning CdpClient", .{});
        return cdp;
    }

    /// Try to establish a page session via Target.createTarget + attach.
    /// This is required by Lightpanda and some other non-Chrome CDP implementations.
    fn establishSession(self: *CdpClient) !void {
        log.info("[TRACE] establishSession: start", .{});
        // Create a blank page target
        const create_id = self.next_id;
        self.next_id += 1;
        log.info("[TRACE] establishSession: building Target.createTarget cmd id={d}", .{create_id});
        const create_cmd = try std.fmt.allocPrint(self.allocator,
            "{{\"id\":{d},\"method\":\"Target.createTarget\",\"params\":{{\"url\":\"about:blank\"}}}}",
            .{create_id});
        defer self.allocator.free(create_cmd);

        log.info("[TRACE] establishSession: duping and writing create_cmd ({} bytes)", .{create_cmd.len});
        {
            const msg = try self.allocator.dupe(u8, create_cmd);
            defer self.allocator.free(msg);
            try self.client.write(msg);
        }
        log.info("[TRACE] establishSession: createTarget written, draining for targetCreated", .{});

        // Drain messages looking for Target.targetCreated event
        var target_id: ?[]const u8 = null;
        for (0..10) |i| {
            log.info("[TRACE] establishSession: drain loop i={d}, setting readTimeout", .{i});
            self.client.readTimeout(3000) catch |err| {
                log.warn("[TRACE] establishSession: readTimeout failed i={d}: {}", .{i, err});
                break;
            };
            log.info("[TRACE] establishSession: calling read() i={d}", .{i});
            const frame = self.client.read() catch |err| switch (err) {
                error.WouldBlock => {
                    log.info("[TRACE] establishSession: WouldBlock i={d}", .{i});
                    continue;
                },
                else => {
                    log.warn("[TRACE] establishSession: read error i={d}: {}", .{i, err});
                    break;
                },
            } orelse {
                log.info("[TRACE] establishSession: null frame i={d}", .{i});
                break;
            };
            log.info("[TRACE] establishSession: got frame i={d} data_len={d}", .{i, frame.data.len});
            defer self.client.done(frame);
            if (frame.data.len == 0) {
                log.info("[TRACE] establishSession: empty frame i={d}", .{i});
                continue;
            }

            log.info("[TRACE] establishSession: parsing JSON i={d}", .{i});
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame.data, .{}) catch |err| {
                log.warn("[TRACE] establishSession: JSON parse failed i={d}: {}", .{i, err});
                continue;
            };
            defer parsed.deinit();
            const val = parsed.value;

            // Check for targetCreated event — use nested ifs (NOT "and" between comparisons)
            if (val.object.get("method")) |m| {
                if (m == .string) {
                    if (std.mem.eql(u8, m.string, "Target.targetCreated")) {
                        log.info("[TRACE] establishSession: found targetCreated!", .{});
                        if (val.object.get("params")) |p| {
                            if (p == .object) {
                                if (p.object.get("targetInfo")) |ti| {
                                    if (ti == .object) {
                                        if (ti.object.get("targetId")) |tid_val| {
                                            if (tid_val == .string) {
                                                log.info("[TRACE] establishSession: targetId={s}", .{tid_val.string});
                                                // Dupe immediately — the parse tree is freed by defer
                                                target_id = try self.allocator.dupe(u8, tid_val.string);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        const tid = target_id orelse {
            log.info("[TRACE] establishSession: no targetId found, returning (direct mode)", .{});
            return;
        };
        defer self.allocator.free(tid);
        log.info("[TRACE] establishSession: got targetId={s}, attaching", .{tid});

        // Attach to the target
        const attach_id = self.next_id;
        self.next_id += 1;
        log.info("[TRACE] establishSession: building Target.attachToTarget id={d}", .{attach_id});
        const attach_cmd = try std.fmt.allocPrint(self.allocator,
            "{{\"id\":{d},\"method\":\"Target.attachToTarget\",\"params\":{{\"targetId\":\"{s}\",\"flatten\":true}}}}",
            .{ attach_id, tid });
        defer self.allocator.free(attach_cmd);

        log.info("[TRACE] establishSession: duping and writing attach_cmd ({} bytes)", .{attach_cmd.len});
        {
            const msg = try self.allocator.dupe(u8, attach_cmd);
            defer self.allocator.free(msg);
            try self.client.write(msg);
        }
        log.info("[TRACE] establishSession: attachToTarget written, draining for attachedToTarget", .{});

        // Drain messages looking for Target.attachedToTarget (which contains sessionId)
        var found_session = false;
        for (0..10) |i| {
            log.info("[TRACE] establishSession: attach drain loop i={d}, setting readTimeout", .{i});
            self.client.readTimeout(3000) catch |err| {
                log.warn("[TRACE] establishSession: attach readTimeout failed i={d}: {}", .{i, err});
                break;
            };
            log.info("[TRACE] establishSession: attach calling read() i={d}", .{i});
            const frame = self.client.read() catch |err| switch (err) {
                error.WouldBlock => {
                    log.info("[TRACE] establishSession: attach WouldBlock i={d}", .{i});
                    continue;
                },
                else => {
                    log.warn("[TRACE] establishSession: attach read error i={d}: {}", .{i, err});
                    break;
                },
            } orelse {
                log.info("[TRACE] establishSession: attach null frame i={d}", .{i});
                break;
            };
            log.info("[TRACE] establishSession: attach got frame i={d} data_len={d}", .{i, frame.data.len});
            defer self.client.done(frame);
            if (frame.data.len == 0) {
                log.info("[TRACE] establishSession: attach empty frame i={d}", .{i});
                continue;
            }

            log.info("[TRACE] establishSession: attach parsing JSON i={d}", .{i});
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame.data, .{}) catch |err| {
                log.warn("[TRACE] establishSession: attach JSON parse failed i={d}: {}", .{i, err});
                continue;
            };
            defer parsed.deinit();
            const val = parsed.value;

            // The sessionId may come in the attachedToTarget event params
            if (val.object.get("method")) |m| {
                if (m == .string) {
                    if (std.mem.eql(u8, m.string, "Target.attachedToTarget")) {
                        log.info("[TRACE] establishSession: found attachedToTarget event!", .{});
                        if (val.object.get("params")) |p| {
                            if (p == .object) {
                                if (p.object.get("sessionId")) |sid| {
                                    if (sid == .string) {
                                        log.info("[TRACE] establishSession: sessionId from event={s}", .{sid.string});
                                        self.session_id = try self.allocator.dupe(u8, sid.string);
                                        log.info("[TRACE] establishSession: session_id stored at ptr=0x{x}", .{@intFromPtr(self.session_id.ptr)});
                                        found_session = true;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // Or it might come in the response to attachToTarget
            if (val.object.get("id")) |id_val| {
                if (id_val == .integer) {
                    if (id_val.integer == @as(i64, attach_id)) {
                        log.info("[TRACE] establishSession: got attachToTarget response id={d}", .{attach_id});
                        if (val.object.get("result")) |r| {
                            if (r == .object) {
                                if (r.object.get("sessionId")) |sid| {
                                    if (sid == .string) {
                                        log.info("[TRACE] establishSession: sessionId from response={s}", .{sid.string});
                                        self.session_id = try self.allocator.dupe(u8, sid.string);
                                        log.info("[TRACE] establishSession: session_id stored at ptr=0x{x}", .{@intFromPtr(self.session_id.ptr)});
                                        found_session = true;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if (found_session) {
            log.info("[TRACE] establishSession: session found, returning", .{});
            return;
        }
        log.info("[TRACE] establishSession: no session found - using direct mode", .{});
    }

    pub fn deinit(self: *CdpClient) void {
        log.info("[TRACE] deinit: session_id={s} len={d}", .{ self.session_id, self.session_id.len });
        if (self.session_id.len > 0) {
            self.allocator.free(self.session_id);
            self.session_id = "";
        }
        log.info("[TRACE] deinit: clearing event buffer ({} items)", .{self.event_buffer.items.len});
        self.clearEventBuffer();
        log.info("[TRACE] deinit: closing WS", .{});
        self.client.close(.{}) catch {};
        log.info("[TRACE] deinit: WS deinit", .{});
        self.client.deinit();
        log.info("[TRACE] deinit: done", .{});
    }

    /// Clear all buffered events.  Called when acquiring a pooled client
    /// to discard stale events from previous tool calls.
    pub fn clearEventBuffer(self: *CdpClient) void {
        for (self.event_buffer.items) |item| {
            self.allocator.free(item);
        }
        self.event_buffer.items.len = 0;
    }

    /// Navigate to about:blank to give the caller a clean page state.
    /// Used by the pool when reusing an existing connection.
    pub fn navigateBlank(self: *CdpClient) !void {
        if (self.session_id.len > 0) {
            // Session-based (Lightpanda) — include sessionId
            const id = self.next_id;
            self.next_id += 1;
            const cmd = try std.fmt.allocPrint(self.allocator,
                "{{\"id\":{d},\"method\":\"Page.navigate\",\"sessionId\":\"{s}\",\"params\":{{\"url\":\"about:blank\"}}}}",
                .{ id, self.session_id });
            defer self.allocator.free(cmd);
            const msg = try self.allocator.dupe(u8, cmd);
            defer self.allocator.free(msg);
            try self.client.write(msg);
            // Drain a few frames to consume the response
            for (0..5) |_| {
                self.client.readTimeout(1000) catch break;
                const frame = self.client.read() catch break orelse continue;
                defer self.client.done(frame);
            }
        } else {
            // Direct mode (Chrome) — no session needed
            const id = self.next_id;
            self.next_id += 1;
            const cmd = try std.fmt.allocPrint(self.allocator,
                "{{\"id\":{d},\"method\":\"Page.navigate\",\"params\":{{\"url\":\"about:blank\"}}}}",
                .{id});
            defer self.allocator.free(cmd);
            const msg = try self.allocator.dupe(u8, cmd);
            defer self.allocator.free(msg);
            try self.client.write(msg);
            for (0..5) |_| {
                self.client.readTimeout(1000) catch break;
                const frame = self.client.read() catch break orelse continue;
                defer self.client.done(frame);
            }
        }
    }

    /// Navigate to a URL, wait for load, and extract document.body.innerText.
    /// Returns the extracted text. Caller must free the returned slice.
    pub fn fetchPageText(self: *CdpClient, allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
        _ = try self.send("Page.enable", .{});
        _ = try self.send("Page.navigate", .{ .url = url });
        try self.waitForEvent("Page.loadEventFired", 15000);

        const text = try self.evalJs(allocator, "document.body ? document.body.innerText : ''");
        return allocator.dupe(u8, text);
    }

    // ── Helpers ──────────────────────────────────────────────────────

    /// Extract the string value from a CDP Runtime.evaluate response.
    ///
    /// CDP returns double-nested results:
    ///   {"id":N, "result": {"result": {"type":"string","value":"..."}}}
    /// The outer "result" is the CDP envelope; the inner "result" is the
    /// JS return value.
    ///
    /// Returns the JS value as a string slice, or `null` if extraction fails.
    pub fn extractEvalString(response: std.json.Value) ?[]const u8 {
        const cdp_env = response.object.get("result") orelse return null;
        if (cdp_env != .object) return null;
        const js_result = cdp_env.object.get("result") orelse return null;
        if (js_result != .object) return null;
        const val = js_result.object.get("value") orelse return null;
        if (val != .string) return null;
        return val.string;
    }

    /// Extract the JS result object from a CDP Runtime.evaluate response.
    /// Returns the inner {"type":"...","value":"..."} object, or null.
    pub fn extractEvalResult(response: std.json.Value) ?std.json.Value {
        const cdp_env = response.object.get("result") orelse return null;
        if (cdp_env != .object) return null;
        return cdp_env.object.get("result");
    }

    /// Convenience: evaluate a JS expression and return the string value.
    /// Wraps send() + extractEvalString(). Returns "" on any failure.
    pub fn evalJs(self: *CdpClient, _: std.mem.Allocator, expression: []const u8) ![]const u8 {
        const result = self.send("Runtime.evaluate", .{ .expression = expression, .returnByValue = true }) catch return "";
        return extractEvalString(result) orelse "";
    }

    /// Send a CDP command and return the response value.
    /// If a session is active, includes sessionId in the request.
    fn send(self: *CdpClient, method: []const u8, params: anytype) !std.json.Value {
        const id = self.next_id;
        self.next_id += 1;

        // Serialize params to JSON.
        // Zig 0.16 formats empty structs as [] (array), but CDP expects {} (object).
        // Detect empty structs at comptime and emit {} directly.
        const ParamsType = @TypeOf(params);
        const params_json = if (comptime @typeInfo(ParamsType) == .@"struct" and
            @typeInfo(ParamsType).@"struct".fields.len == 0)
            "{}"
        else
            std.json.Stringify.valueAlloc(self.allocator, params, .{}) catch "{}";

        // Build JSON-RPC request, optionally with sessionId
        log.info("[TRACE] send: building request method={s} id={d} session={s}", .{ method, id, self.session_id });
        const json_str = if (self.session_id.len > 0)
            try std.fmt.allocPrint(self.allocator,
                "{{\"id\":{d},\"method\":\"{s}\",\"sessionId\":\"{s}\",\"params\":{s}}}",
                .{ id, method, self.session_id, params_json })
        else
            try std.fmt.allocPrint(self.allocator,
                "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
                .{ id, method, params_json });
        defer self.allocator.free(json_str);

        // Duplicate as mutable because writeFrame applies XOR masking in-place.
        const msg = try self.allocator.dupe(u8, json_str);
        defer self.allocator.free(msg);
        log.info("[TRACE] send: writing {} bytes to WS", .{msg.len});
        try self.client.write(msg);
        log.info("[TRACE] send: write OK", .{});

        // Read frames until we get a response with our request id.
        var attempts: u32 = 0;
        const max_attempts: u32 = 50;
        while (attempts < max_attempts) : (attempts += 1) {
            log.info("[TRACE] send({s}): waiting for response id={d} attempt={d}", .{ method, id, attempts });
            self.client.readTimeout(5000) catch {
                log.warn("[TRACE] send({s}): readTimeout failed on attempt {d}", .{ method, attempts });
                continue;
            };

            const message = self.client.read() catch |err| switch (err) {
                error.WouldBlock => {
                    log.info("[TRACE] send({s}): WouldBlock attempt={d}", .{ method, attempts });
                    continue;
                },
                else => {
                    log.warn("[TRACE] send({s}): read error on attempt {d}: {}", .{ method, attempts, err });
                    return err;
                },
            } orelse {
                log.warn("[TRACE] send({s}): no message on attempt {d}", .{ method, attempts });
                continue;
            };

            const data = message.data;
            log.info("[TRACE] send({s}): got frame ({d} bytes) attempt={d}", .{ method, data.len, attempts });
            if (data.len == 0) {
                self.client.done(message);
                continue;
            }

            // Parse the frame as JSON.
            log.info("[TRACE] send({s}): parsing JSON from frame", .{method});
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch |err| {
                log.warn("[TRACE] send({s}): JSON parse failed attempt={d}: {}", .{ method, attempts, err });
                self.client.done(message);
                continue;
            };
            log.info("[TRACE] send({s}): JSON parsed OK", .{method});

            const value = parsed.value;

            // Check if this is our response (has "id" matching our request).
            if (value.object.get("id")) |id_val| {
                if (id_val == .integer) {
                    if (id_val.integer == @as(i64, id)) {
                        log.info("[TRACE] send({s}): matched response id={d}", .{ method, id });
                        // Check for CDP-level error.
                        if (value.object.get("error")) |err_val| {
                            const err_msg = if (err_val == .object)
                                if (err_val.object.get("message")) |m| if (m == .string) m.string else "unknown CDP error" else "unknown CDP error"
                            else
                                "unknown CDP error";
                            log.warn("[TRACE] CDP error for {s}: {s}", .{ method, err_msg });
                            self.client.done(message);
                            parsed.deinit();
                            return error.CdpError;
                        }
                        // We found our response — return the value (leaks both the frame
                        // and the parse tree intentionally: the arena backing it is
                        // page_allocator and the caller needs the Value (with its
                        // string slices pointing into the frame data) to outlive this
                        // function. Calling done(message) before return would free
                        // the frame buffer that parsed.value.string slices point into.
                        log.info("[TRACE] send({s}): returning value (parse tree + frame leaked intentionally)", .{ method });
                        return value;
                    }
                }
            }

            // It's an event — buffer it for waitForEvent().
            if (self.event_buffer.items.len < 100) {
                const copy = try self.allocator.dupe(u8, data);
                try self.event_buffer.append(self.allocator, copy);
            }

            self.client.done(message);
            parsed.deinit();
        }

        return error.CdpTimeout;
    }

    /// Wait for a specific CDP event (e.g. "Page.loadEventFired").
    fn waitForEvent(self: *CdpClient, event_name: []const u8, timeout_ms: u32) !void {
        log.info("[TRACE] waitForEvent: looking for {s} timeout={d}ms", .{ event_name, timeout_ms });
        // Check if event already buffered
        for (self.event_buffer.items, 0..) |item, i| {
            if (std.mem.indexOf(u8, item, event_name) != null) {
                log.info("[TRACE] waitForEvent: found in buffer at index {d}", .{i});
                self.allocator.free(item);
                _ = self.event_buffer.orderedRemove(i);
                return;
            }
        }

        // Poll for the event with timeout.
        const max_polls = timeout_ms / 1000 + 1;
        var polls: u32 = 0;
        while (polls < max_polls) : (polls += 1) {
            log.info("[TRACE] waitForEvent: poll {d}/{d}", .{ polls, max_polls });
            self.client.readTimeout(1000) catch continue;

            const message = self.client.read() catch |err| switch (err) {
                error.WouldBlock => continue,
                error.Closed => return error.CdpConnectionClosed,
                else => return err,
            } orelse continue;

            if (message.data.len > 0 and std.mem.indexOf(u8, message.data, event_name) != null) {
                log.info("[TRACE] waitForEvent: got {s} ({d} bytes)", .{ event_name, message.data.len });
                self.client.done(message);
                return;
            }
            self.client.done(message);
        }

        log.warn("[TRACE] waitForEvent: timeout waiting for {s}", .{event_name});
        return error.CdpTimeout;
    }

    const EndpointParts = struct {
        host: []const u8,
        port: u16,
        path: []const u8,
        tls: bool,
    };

    fn parseEndpoint(endpoint: []const u8) EndpointParts {
        const tls = std.mem.startsWith(u8, endpoint, "wss://");
        const after_scheme = if (tls) endpoint[6..] else if (std.mem.startsWith(u8, endpoint, "ws://")) endpoint[5..] else endpoint;

        var host_port: []const u8 = after_scheme;
        var path: []const u8 = "/";
        if (std.mem.indexOf(u8, after_scheme, "/")) |slash| {
            host_port = after_scheme[0..slash];
            path = after_scheme[slash..];
        }

        var host: []const u8 = host_port;
        var port: u16 = if (tls) 443 else 80;
        if (std.mem.lastIndexOf(u8, host_port, ":")) |colon| {
            host = host_port[0..colon];
            port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch port;
        }

        return .{
            .host = if (host.len > 0) host else "127.0.0.1",
            .port = port,
            .path = if (path.len > 0) path else "/",
            .tls = tls,
        };
    }
};
