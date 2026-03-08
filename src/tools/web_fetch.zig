//! Web Fetch Tool — fetch and extract content from web pages.
//!
//! Converts HTML to readable text/markdown. Removes scripts, styles,
//! and navigation. Preserves headings, links, and lists.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const net_security = @import("../root.zig").net_security;
const http_util = @import("../http_util.zig");

const log = std.log.scoped(.web_fetch);

/// Default max chars for extracted content.
const DEFAULT_MAX_CHARS: usize = 50_000;

/// Web fetch tool — fetches URLs and extracts readable content.
pub const WebFetchTool = struct {
    default_max_chars: usize = DEFAULT_MAX_CHARS,

    pub const tool_name = "web_fetch";
    pub const tool_description = "Fetch a web page and extract its text content. Converts HTML to readable text with markdown formatting.";
    pub const tool_params =
        \\{"type":"object","properties":{"url":{"type":"string","description":"URL to fetch (http or https)"},"max_chars":{"type":"integer","default":50000,"description":"Maximum characters to return"}},"required":["url"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *WebFetchTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *WebFetchTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const url = root.getString(args, "url") orelse
            return ToolResult.fail("Missing required 'url' parameter");

        log.info("web_fetch: Starting fetch for URL: {s}", .{url});

        // Validate URL scheme
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
            log.err("web_fetch: Invalid URL scheme for {s}", .{url});
            return ToolResult.fail("Only http:// and https:// URLs are allowed");
        }

        const uri = std.Uri.parse(url) catch {
            log.err("web_fetch: Failed to parse URL: {s}", .{url});
            return ToolResult.fail("Invalid URL format");
        };
        const default_port: u16 = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) 443 else 80;
        const resolved_port: u16 = uri.port orelse default_port;

        // SSRF protection and DNS-rebinding hardening:
        // resolve once, validate global address, and connect directly to it.
        const host = net_security.extractHost(url) orelse {
            log.err("web_fetch: Cannot extract host from URL: {s}", .{url});
            return ToolResult.fail("Invalid URL: cannot extract host");
        };
        log.debug("web_fetch: Resolved host: {s}, port: {d}", .{host, resolved_port});

        const connect_host = net_security.resolveConnectHost(allocator, host, resolved_port) catch |err| switch (err) {
            error.LocalAddressBlocked => {
                log.warn("web_fetch: Blocked local/private host: {s}", .{host});
                return ToolResult.fail("Blocked local/private host");
            },
            else => {
                log.err("web_fetch: Unable to verify host safety for {s}: {}", .{host, err});
                return ToolResult.fail("Unable to verify host safety");
            },
        };
        defer allocator.free(connect_host);

        const max_chars = parseMaxCharsWithDefault(args, self.default_max_chars);
        log.debug("web_fetch: max_chars={d}", .{max_chars});

        // Step 1: Try fetching with markdown Accept header
        const markdown_headers = [_][]const u8{
            "User-Agent: nullclaw/1.0 (web_fetch tool - markdown)",
            "Accept: text/markdown, text/plain, text/x-markdown",
        };

        log.info("web_fetch: Fetching {s} with markdown headers", .{url});
        const body = blk: {
            if (shouldUseCurlResolve(host)) {
                const resolve_entry = try buildCurlResolveEntry(allocator, host, resolved_port, connect_host);
                defer allocator.free(resolve_entry);
                log.debug("web_fetch: Using curlGetWithResolve for {s}", .{url});
                break :blk http_util.curlGetWithResolve(
                    allocator,
                    url,
                    &markdown_headers,
                    "30",
                    resolve_entry,
                );
            }
            log.debug("web_fetch: Using curlGet for {s}", .{url});
            break :blk http_util.curlGet(
                allocator,
                url,
                &markdown_headers,
                "30",
            );
        } catch |err| {
            log.err("web_fetch connection failed for {s}: {}", .{ url, err });
            const msg = try std.fmt.allocPrint(allocator, "Fetch failed: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        };
        defer allocator.free(body);

        log.info("web_fetch: Got {d} bytes from {s}", .{body.len, url});

        // Step 2: Check if we got markdown back (naive check)
        const is_markdown = looksLikeMarkdown(body);

        if (is_markdown) {
            log.info("web_fetch: Got markdown directly from {s}, returning {d} chars", .{url, @min(body.len, max_chars)});
            // Return markdown as-is (truncate if needed)
            const content = if (body.len > max_chars) body[0..max_chars] else body;
            return ToolResult.ok(try allocator.dupe(u8, content));
        }

        // Step 3: Convert HTML to markdown (with max_chars for early termination)
        log.info("web_fetch: Converting HTML to markdown for {s}", .{url});
        const extracted = try htmlToText(allocator, body, max_chars);
        defer allocator.free(extracted);

        log.info("web_fetch: Successfully extracted {d} chars from {s}", .{extracted.len, url});
        return ToolResult.ok(try allocator.dupe(u8, extracted));
    }
};

fn parseMaxChars(args: JsonObjectMap) usize {
    return parseMaxCharsWithDefault(args, DEFAULT_MAX_CHARS);
}

fn parseMaxCharsWithDefault(args: JsonObjectMap, default: usize) usize {
    const val_i64 = root.getInt(args, "max_chars") orelse return default;
    if (val_i64 < 100) return 100;
    if (val_i64 > 200_000) return 200_000;
    return @intCast(val_i64);
}

fn shouldUseCurlResolve(host: []const u8) bool {
    // DNS pinning is required for hostname-based URLs. IPv6 literals do not
    // involve DNS and don't fit curl's host:port `--resolve` syntax cleanly.
    return std.mem.indexOfScalar(u8, stripHostBrackets(host), ':') == null;
}

fn buildCurlResolveEntry(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    connect_host: []const u8,
) ![]u8 {
    const host_for_resolve = stripHostBrackets(host);
    const connect_target = if (std.mem.indexOfScalar(u8, connect_host, ':') != null)
        try std.fmt.allocPrint(allocator, "[{s}]", .{connect_host})
    else
        try allocator.dupe(u8, connect_host);
    defer allocator.free(connect_target);

    return std.fmt.allocPrint(allocator, "{s}:{d}:{s}", .{ host_for_resolve, port, connect_target });
}

fn stripHostBrackets(host: []const u8) []const u8 {
    if (std.mem.startsWith(u8, host, "[") and std.mem.endsWith(u8, host, "]")) {
        return host[1 .. host.len - 1];
    }
    return host;
}

/// Check if content looks like markdown (not HTML).
/// Naive heuristic: markdown doesn't have HTML tags.
fn looksLikeMarkdown(content: []const u8) bool {
    // Check for HTML indicators
    if (std.mem.indexOf(u8, content, "<html") != null) return false;
    if (std.mem.indexOf(u8, content, "<!DOCTYPE") != null) return false;
    if (std.mem.indexOf(u8, content, "<body") != null) return false;

    // Check for markdown indicators
    if (std.mem.indexOf(u8, content, "# ") != null) return true;
    if (std.mem.indexOf(u8, content, "## ") != null) return true;
    if (std.mem.indexOf(u8, content, "- ") != null) return true;
    if (std.mem.indexOf(u8, content, "* ") != null) return true;

    // If no HTML tags and has some structure, assume markdown
    return true;
}

/// Convert HTML to readable text with basic markdown formatting.
/// Sanitizes page to extract clean text content and links for AI agents.
/// max_chars: optional limit to stop processing early (saves memory on large pages)
pub fn htmlToText(allocator: std.mem.Allocator, html: []const u8, max_chars: ?usize) ![]u8 {
    // Estimate output size and pre-allocate
    const estimated_size = @min(html.len / 2, max_chars orelse 1_000_000);
    var buf = try std.ArrayList(u8).initCapacity(allocator, estimated_size);
    errdefer buf.deinit(allocator);

    // Link struct for tracking links
    const Link = struct { text: []const u8, url: []const u8 };

    // Limit link tracking to avoid massive memory usage
    const MAX_LINKS = 500;
    var links = try std.ArrayList(Link).initCapacity(allocator, MAX_LINKS);
    defer {
        for (links.items) |l| {
            allocator.free(l.text);
            allocator.free(l.url);
        }
        links.deinit(allocator);
    }

    var i: usize = 0;
    var in_script = false;
    var in_style = false;
    var in_head = false;
    var in_nav = false;
    var in_footer = false;
    var in_aside = false;
    var in_iframe = false;
    var skip_content = false;
    var last_was_newline = false;
    var consecutive_newlines: u32 = 0;

    while (i < html.len) {
        // Skip HTML comments <!-- ... -->
        if (i + 4 < html.len and html[i] == '<' and html[i+1] == '!' and
            html[i+2] == '-' and html[i+3] == '-') {
            const comment_end = std.mem.indexOfPos(u8, html, i + 4, "-->") orelse {
                i += 1;
                continue;
            };
            i = comment_end + 3;
            continue;
        }

        // Check for tag start
        if (html[i] == '<') {
            const tag_end = std.mem.indexOfScalarPos(u8, html, i + 1, '>') orelse {
                i += 1;
                continue;
            };

            const tag_content = html[i + 1 .. tag_end];
            const tag_lower = tagName(tag_content);

            // Handle closing tags
            if (tag_content.len > 0 and tag_content[0] == '/') {
                const close_tag = tagName(tag_content[1..]);
                if (eqlTag(close_tag, "script")) in_script = false;
                if (eqlTag(close_tag, "style")) in_style = false;
                if (eqlTag(close_tag, "noscript")) skip_content = false;
                if (eqlTag(close_tag, "head")) in_head = false;
                if (eqlTag(close_tag, "nav")) in_nav = false;
                if (eqlTag(close_tag, "footer")) in_footer = false;
                if (eqlTag(close_tag, "aside")) in_aside = false;
                if (eqlTag(close_tag, "iframe")) in_iframe = false;
                if (eqlTag(close_tag, "svg")) skip_content = false;
                i = tag_end + 1;
                continue;
            }

            // Opening tags - skip junk content
            if (eqlTag(tag_lower, "script")) {
                in_script = true;
                i = tag_end + 1;
                continue;
            }
            if (eqlTag(tag_lower, "style")) {
                in_style = true;
                i = tag_end + 1;
                continue;
            }
            if (eqlTag(tag_lower, "noscript")) {
                skip_content = true;
                i = tag_end + 1;
                continue;
            }
            if (eqlTag(tag_lower, "head")) {
                in_head = true;
                i = tag_end + 1;
                continue;
            }
            if (eqlTag(tag_lower, "nav")) {
                in_nav = true;
                i = tag_end + 1;
                continue;
            }
            if (eqlTag(tag_lower, "footer")) {
                in_footer = true;
                i = tag_end + 1;
                continue;
            }
            if (eqlTag(tag_lower, "aside")) {
                in_aside = true;
                i = tag_end + 1;
                continue;
            }
            if (eqlTag(tag_lower, "iframe")) {
                in_iframe = true;
                i = tag_end + 1;
                continue;
            }
            if (eqlTag(tag_lower, "svg")) {
                skip_content = true;
                i = tag_end + 1;
                continue;
            }

            // Skip content in junk sections
            if (in_script or in_style or in_head or in_nav or in_footer or in_aside or in_iframe or skip_content) {
                i = tag_end + 1;
                continue;
            }

            // Block elements → newline
            if (isBlockTag(tag_lower)) {
                if (!last_was_newline and buf.items.len > 0) {
                    try appendNewline(&buf, allocator, &consecutive_newlines);
                    last_was_newline = true;
                }
            }

            // Headings → markdown
            if (tag_lower.len == 2 and tag_lower[0] == 'h' and tag_lower[1] >= '1' and tag_lower[1] <= '6') {
                const level = tag_lower[1] - '0';
                if (!last_was_newline and buf.items.len > 0) {
                    try appendNewline(&buf, allocator, &consecutive_newlines);
                    last_was_newline = true;
                }
                for (0..level) |_| try buf.append(allocator, '#');
                try buf.append(allocator, ' ');
                last_was_newline = false;
                consecutive_newlines = 0;
            }

            // List items → markdown
            if (eqlTag(tag_lower, "li")) {
                if (!last_was_newline and buf.items.len > 0) {
                    try appendNewline(&buf, allocator, &consecutive_newlines);
                }
                try buf.appendSlice(allocator, "- ");
                last_was_newline = false;
                consecutive_newlines = 0;
            }

            // <br> → newline
            if (eqlTag(tag_lower, "br") or eqlTag(tag_lower, "br/") or eqlTag(tag_lower, "br /")) {
                try appendNewline(&buf, allocator, &consecutive_newlines);
                last_was_newline = true;
            }

            // <hr> → separator
            if (eqlTag(tag_lower, "hr") or eqlTag(tag_lower, "hr/") or eqlTag(tag_lower, "hr /")) {
                if (!last_was_newline) try appendNewline(&buf, allocator, &consecutive_newlines);
                try buf.appendSlice(allocator, "---");
                try appendNewline(&buf, allocator, &consecutive_newlines);
                last_was_newline = true;
            }

            // <a href="url">text</a> — extract href for markdown link and track for Links section
            if (eqlTag(tag_lower, "a")) {
                if (extractHref(tag_content)) |href| {
                    // Find closing </a>
                    const close_a = findClosingTag(html, tag_end + 1, "a");
                    if (close_a) |close_pos| {
                        const link_text = std.mem.trim(u8, html[tag_end + 1 .. close_pos.start], " \t\n\r");
                        const clean_text = try stripInnerTags(allocator, link_text);
                        defer allocator.free(clean_text);
                        if (clean_text.len > 0) {
                            // Add inline markdown link
                            try buf.append(allocator, '[');
                            try buf.appendSlice(allocator, clean_text);
                            try buf.appendSlice(allocator, "](");
                            try buf.appendSlice(allocator, href);
                            try buf.append(allocator, ')');
                            last_was_newline = false;
                            consecutive_newlines = 0;

                            // Track links for Links section (limit to MAX_LINKS to save memory)
                            if (links.items.len < MAX_LINKS and
                                !std.mem.startsWith(u8, href, "#") and
                                !std.mem.startsWith(u8, href, "javascript:") and
                                href.len > 0 and clean_text.len > 0) {
                                const text_copy = try allocator.dupe(u8, clean_text);
                                const url_copy = try allocator.dupe(u8, href);
                                try links.append(allocator, .{ .text = text_copy, .url = url_copy });
                            }
                        }
                        i = close_pos.end;
                        continue;
                    }
                }
            }

            i = tag_end + 1;
            continue;
        }

        // Skip content in script/style
        if (in_script or in_style) {
            i += 1;
            continue;
        }

        // Handle HTML entities
        if (html[i] == '&') {
            const entity_end = std.mem.indexOfScalarPos(u8, html, i + 1, ';');
            if (entity_end) |end| {
                const entity = html[i .. end + 1];
                const decoded = decodeEntity(entity);
                if (decoded) |ch| {
                    try buf.append(allocator, ch);
                    last_was_newline = false;
                    consecutive_newlines = 0;
                    i = end + 1;
                    continue;
                }
            }
        }

        // Regular character
        const c = html[i];
        if (c == '\n' or c == '\r') {
            if (!last_was_newline) {
                try buf.append(allocator, ' ');
            }
        } else if (c == ' ' or c == '\t') {
            // Collapse whitespace
            if (buf.items.len > 0 and buf.items[buf.items.len - 1] != ' ' and !last_was_newline) {
                try buf.append(allocator, ' ');
            }
        } else {
            try buf.append(allocator, c);
            last_was_newline = false;
            consecutive_newlines = 0;

            // Early termination: stop if approaching max_chars (leave room for Links section)
            if (max_chars) |limit| {
                if (buf.items.len >= limit - 1000) { // Leave 1KB for Links section
                    break; // Stop processing HTML
                }
            }
        }

        i += 1;
    }

    // Trim trailing whitespace
    while (buf.items.len > 0 and (buf.items[buf.items.len - 1] == ' ' or
        buf.items[buf.items.len - 1] == '\n' or buf.items[buf.items.len - 1] == '\r'))
    {
        _ = buf.pop();
    }

    // Add Links section at the end for agent navigation
    if (links.items.len > 0) {
        try buf.appendSlice(allocator, "\n\n---\n## Links\n\n");
        for (links.items, 0..) |link, idx| {
            try buf.append(allocator, '[');
            try buf.appendSlice(allocator, link.text);
            try buf.appendSlice(allocator, "](");
            try buf.appendSlice(allocator, link.url);
            try buf.appendSlice(allocator, ")");
            if (idx < links.items.len - 1) {
                try buf.appendSlice(allocator, " |\n");
            }
        }
    }

    return buf.toOwnedSlice(allocator);
}

fn appendNewline(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, consecutive: *u32) !void {
    if (consecutive.* < 2) {
        try buf.append(allocator, '\n');
        consecutive.* += 1;
    }
}

fn tagName(content: []const u8) []const u8 {
    var end: usize = 0;
    while (end < content.len and content[end] != ' ' and content[end] != '\t' and
        content[end] != '\n' and content[end] != '/' and content[end] != '>')
    {
        end += 1;
    }
    return content[0..end];
}

fn eqlTag(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
    }
    return true;
}

fn isBlockTag(tag: []const u8) bool {
    const block_tags = [_][]const u8{
        "p",     "div",        "section", "article", "main", "header",   "footer", "nav",
        "aside", "blockquote", "pre",     "table",   "tr",   "th",       "td",     "ul",
        "ol",    "dl",         "dt",      "dd",      "form", "fieldset", "figure",
    };
    for (block_tags) |bt| {
        if (eqlTag(tag, bt)) return true;
    }
    return false;
}

fn extractHref(tag_content: []const u8) ?[]const u8 {
    // Find href="..." in tag attributes
    const href_pos = std.mem.indexOf(u8, tag_content, "href=\"") orelse
        std.mem.indexOf(u8, tag_content, "href='") orelse return null;
    const start = href_pos + 6;
    const quote = tag_content[href_pos + 5]; // " or '
    const end = std.mem.indexOfScalarPos(u8, tag_content, start, quote) orelse return null;
    return tag_content[start..end];
}

const ClosingTagPos = struct { start: usize, end: usize };

fn findClosingTag(html: []const u8, from: usize, tag: []const u8) ?ClosingTagPos {
    var pos = from;
    while (pos < html.len) {
        const lt = std.mem.indexOfScalarPos(u8, html, pos, '<') orelse return null;
        if (lt + 2 + tag.len >= html.len) return null;
        if (html[lt + 1] == '/') {
            const after_slash = html[lt + 2 ..];
            if (eqlTag(after_slash[0..@min(tag.len, after_slash.len)], tag)) {
                const gt = std.mem.indexOfScalarPos(u8, html, lt + 2, '>') orelse return null;
                return .{ .start = lt, .end = gt + 1 };
            }
        }
        pos = lt + 1;
    }
    return null;
}

fn stripInnerTags(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, html, i + 1, '>') orelse {
                i += 1;
                continue;
            };
            i = end + 1;
        } else {
            try buf.append(allocator, html[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn decodeEntity(entity: []const u8) ?u8 {
    if (std.mem.eql(u8, entity, "&amp;")) return '&';
    if (std.mem.eql(u8, entity, "&lt;")) return '<';
    if (std.mem.eql(u8, entity, "&gt;")) return '>';
    if (std.mem.eql(u8, entity, "&quot;")) return '"';
    if (std.mem.eql(u8, entity, "&apos;")) return '\'';
    if (std.mem.eql(u8, entity, "&nbsp;")) return ' ';
    return null;
}

// ══════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════

const testing = std.testing;

test "WebFetchTool name and description" {
    var wft = WebFetchTool{};
    const t = wft.tool();
    try testing.expectEqualStrings("web_fetch", t.name());
    try testing.expect(t.description().len > 0);
    try testing.expect(t.parametersJson()[0] == '{');
}

test "WebFetchTool missing url fails" {
    var wft = WebFetchTool{};
    const parsed = try root.parseTestArgs("{\"max_chars\":1000}");
    defer parsed.deinit();
    const result = try wft.execute(testing.allocator, parsed.parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Missing required 'url' parameter", result.error_msg.?);
}

test "WebFetchTool non-http url fails" {
    var wft = WebFetchTool{};
    const parsed = try root.parseTestArgs("{\"url\":\"ftp://example.com\"}");
    defer parsed.deinit();
    const result = try wft.execute(testing.allocator, parsed.parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Only http:// and https:// URLs are allowed", result.error_msg.?);
}

test "WebFetchTool localhost blocked" {
    var wft = WebFetchTool{};
    const parsed = try root.parseTestArgs("{\"url\":\"http://localhost:8080/api\"}");
    defer parsed.deinit();
    const result = try wft.execute(testing.allocator, parsed.parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Blocked local/private host", result.error_msg.?);
}

test "WebFetchTool private IP blocked" {
    var wft = WebFetchTool{};
    const p1 = try root.parseTestArgs("{\"url\":\"http://192.168.1.1/\"}");
    defer p1.deinit();
    const r1 = try wft.execute(testing.allocator, p1.parsed.value.object);
    try testing.expect(!r1.success);
    const p2 = try root.parseTestArgs("{\"url\":\"http://10.0.0.1/\"}");
    defer p2.deinit();
    const r2 = try wft.execute(testing.allocator, p2.parsed.value.object);
    try testing.expect(!r2.success);
    const p3 = try root.parseTestArgs("{\"url\":\"http://127.0.0.1/\"}");
    defer p3.deinit();
    const r3 = try wft.execute(testing.allocator, p3.parsed.value.object);
    try testing.expect(!r3.success);
}

test "WebFetchTool loopback decimal alias blocked" {
    var wft = WebFetchTool{};
    const parsed = try root.parseTestArgs("{\"url\":\"http://2130706433/\"}");
    defer parsed.deinit();
    const result = try wft.execute(testing.allocator, parsed.parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Blocked local/private host", result.error_msg.?);
}

test "buildCurlResolveEntry formats ipv4 connect target" {
    const entry = try buildCurlResolveEntry(testing.allocator, "example.com", 443, "93.184.216.34");
    defer testing.allocator.free(entry);
    try testing.expectEqualStrings("example.com:443:93.184.216.34", entry);
}

test "buildCurlResolveEntry wraps ipv6 connect target" {
    const entry = try buildCurlResolveEntry(testing.allocator, "example.com", 443, "2001:db8::1");
    defer testing.allocator.free(entry);
    try testing.expectEqualStrings("example.com:443:[2001:db8::1]", entry);
}

test "shouldUseCurlResolve skips ipv6 literal hosts" {
    try testing.expect(shouldUseCurlResolve("example.com"));
    try testing.expect(!shouldUseCurlResolve("[2001:db8::1]"));
}

test "htmlToText strips script and style" {
    const html = "<html><head><style>body{color:red}</style></head><body><script>alert(1)</script>Hello</body></html>";
    const text = try htmlToText(testing.allocator, html, null);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "alert") == null);
    try testing.expect(std.mem.indexOf(u8, text, "color:red") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Hello") != null);
}

test "htmlToText headings become markdown" {
    const html = "<h1>Title</h1><h2>Subtitle</h2><p>Content</p>";
    const text = try htmlToText(testing.allocator, html, null);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "# Title") != null);
    try testing.expect(std.mem.indexOf(u8, text, "## Subtitle") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Content") != null);
}

test "htmlToText links become markdown" {
    const html = "<a href=\"https://example.com\">Example</a>";
    const text = try htmlToText(testing.allocator, html, null);
    defer testing.allocator.free(text);
    // htmlToText adds a Links section at the end
    try testing.expect(std.mem.indexOf(u8, text, "[Example](https://example.com)") != null);
}

test "htmlToText list items" {
    const html = "<ul><li>First</li><li>Second</li></ul>";
    const text = try htmlToText(testing.allocator, html, null);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "- First") != null);
    try testing.expect(std.mem.indexOf(u8, text, "- Second") != null);
}

test "htmlToText entities decoded" {
    const html = "A &amp; B &lt; C &gt; D";
    const text = try htmlToText(testing.allocator, html, null);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("A & B < C > D", text);
}

test "htmlToText whitespace normalization" {
    const html = "hello   \n\n\n   world";
    const text = try htmlToText(testing.allocator, html, null);
    defer testing.allocator.free(text);
    // Multiple whitespace collapsed, newlines become spaces
    try testing.expect(std.mem.indexOf(u8, text, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, text, "world") != null);
}

test "htmlToText br becomes newline" {
    const html = "line1<br>line2<br/>line3";
    const text = try htmlToText(testing.allocator, html, null);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "line1\nline2") != null);
}

test "htmlToText empty input" {
    const text = try htmlToText(testing.allocator, "", null);
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 0), text.len);
}

test "htmlToText plain text passthrough" {
    const text = try htmlToText(testing.allocator, "Just plain text", null);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("Just plain text", text);
}

test "extractHost parses correctly" {
    try testing.expectEqualStrings("example.com", net_security.extractHost("https://example.com/path").?);
    try testing.expectEqualStrings("sub.domain.org", net_security.extractHost("http://sub.domain.org?q=1").?);
    try testing.expectEqualStrings("host", net_security.extractHost("https://host:8080/").?);
    try testing.expectEqualStrings("::1", net_security.extractHost("http://::1:8080/").?);
    try testing.expect(net_security.extractHost("ftp://nope") == null);
}

test "isLocalHost detects private ranges" {
    try testing.expect(net_security.isLocalHost("localhost"));
    try testing.expect(net_security.isLocalHost("127.0.0.1"));
    try testing.expect(net_security.isLocalHost("10.0.0.1"));
    try testing.expect(net_security.isLocalHost("192.168.1.1"));
    try testing.expect(net_security.isLocalHost("0.0.0.0"));
    try testing.expect(net_security.isLocalHost("[fe80::1%25lo0]"));
    try testing.expect(!net_security.isLocalHost("example.com"));
    try testing.expect(!net_security.isLocalHost("8.8.8.8"));
}

test "parseMaxChars" {
    const p1 = try root.parseTestArgs("{}");
    defer p1.deinit();
    try testing.expectEqual(DEFAULT_MAX_CHARS, parseMaxChars(p1.parsed.value.object));
    const p2 = try root.parseTestArgs("{\"max_chars\":1000}");
    defer p2.deinit();
    try testing.expectEqual(@as(usize, 1000), parseMaxChars(p2.parsed.value.object));
    const p3 = try root.parseTestArgs("{\"max_chars\":10}");
    defer p3.deinit();
    try testing.expectEqual(@as(usize, 100), parseMaxChars(p3.parsed.value.object)); // clamped
    const p4 = try root.parseTestArgs("{\"max_chars\":999999}");
    defer p4.deinit();
    try testing.expectEqual(@as(usize, 200_000), parseMaxChars(p4.parsed.value.object)); // clamped
}

test "decodeEntity" {
    try testing.expectEqual(@as(u8, '&'), decodeEntity("&amp;").?);
    try testing.expectEqual(@as(u8, '<'), decodeEntity("&lt;").?);
    try testing.expectEqual(@as(u8, '>'), decodeEntity("&gt;").?);
    try testing.expect(decodeEntity("&unknown;") == null);
}
