//! Web Scraper Tool — embedded HTML to markdown converter.
//!
//! Converts HTML to clean markdown with metadata extraction.
//! No external APIs required - runs entirely in Zig.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const net_security = @import("../root.zig").net_security;
const http_util = @import("../http_util.zig");

const log = std.log.scoped(.web_scrape);

/// Default max chars for extracted content.
const DEFAULT_MAX_CHARS: usize = 50_000;

/// Web scrape tool — fetches URLs and extracts markdown with metadata.
pub const WebScrapeTool = struct {
    default_max_chars: usize = DEFAULT_MAX_CHARS,

    pub const tool_name = "web_scrape";
    pub const tool_description = "Fetch a web page and convert to clean markdown with metadata. Extracts title, content, links, and interactive elements.";
    pub const tool_params =
        \\{"type":"object","properties":{"url":{"type":"string","description":"URL to scrape (http or https)"},"max_chars":{"type":"integer","default":50000,"description":"Maximum characters to return"},"include_metadata":{"type":"boolean","default":true,"description":"Include YAML frontmatter with metadata"}},"required":["url"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *WebScrapeTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *WebScrapeTool, allocator: std.mem.Allocator, args: JsonObjectMap, io: std.Io) !ToolResult {
        _ = io;
        const url = root.getString(args, "url") orelse
            return ToolResult.fail("Missing required 'url' parameter");

        // Validate URL scheme
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
            return ToolResult.fail("Only http:// and https:// URLs are allowed");
        }

        const uri = std.Uri.parse(url) catch
            return ToolResult.fail("Invalid URL format");
        const default_port: u16 = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) 443 else 80;
        const resolved_port: u16 = uri.port orelse default_port;

        // SSRF protection
        const host = net_security.extractHost(url) orelse
            return ToolResult.fail("Invalid URL: cannot extract host");
        const connect_host = net_security.resolveConnectHost(allocator, host, resolved_port) catch |err| switch (err) {
            error.LocalAddressBlocked => return ToolResult.fail("Blocked local/private host"),
            else => return ToolResult.fail("Unable to verify host safety"),
        };
        defer allocator.free(connect_host);

        const max_chars = parseMaxCharsWithDefault(args, self.default_max_chars);
        const include_metadata = root.getBool(args, "include_metadata") orelse true;

        // Fetch URL
        const headers = [_][]const u8{
            "User-Agent: nullclaw/1.0 (web_scrape tool)",
            "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        };

        const body = blk: {
            if (shouldUseCurlResolve(host)) {
                const resolve_entry = try buildCurlResolveEntry(allocator, host, resolved_port, connect_host);
                defer allocator.free(resolve_entry);
                break :blk http_util.curlGetWithResolve(
                    allocator,
                    url,
                    &headers,
                    "30",
                    resolve_entry,
                );
            }
            break :blk http_util.curlGet(
                allocator,
                url,
                &headers,
                "30",
            );
        } catch |err| {
            log.err("web_scrape: fetch failed for {s}: {}", .{ url, err });
            const msg = try std.fmt.allocPrint(allocator, "Fetch failed: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg, .owns_error_msg = true };
        };
        defer allocator.free(body);

        // Extract structured data from HTML
        const scraped = try scrapeHtml(allocator, body, url);
        defer scraped.deinit(allocator);

        // Build markdown output
        var output = std.ArrayList(u8).init(allocator);
        errdefer output.deinit();

        // Add YAML frontmatter if requested
        if (include_metadata) {
            try output.appendSlice("---\n");
            try output.appendSlice("url: ");
            try output.appendSlice(url);
            try output.appendSlice("\ntitle: ");
            try output.appendSlice(scraped.title orelse "Unknown");
            if (scraped.description) |desc| {
                try output.appendSlice("\ndescription: ");
                try output.appendSlice(desc);
            }
            if (scraped.author) |author| {
                try output.appendSlice("\nauthor: ");
                try output.appendSlice(author);
            }
            if (scraped.og_type) |og_type| {
                try output.appendSlice("\ntype: ");
                try output.appendSlice(og_type);
            }
            try output.appendSlice("\nlinks: ");
            try std.fmt.formatInt(output.writer(), @as(u32, @intCast(scraped.links.items.len)), 10, .lower, .{});
            if (scraped.images.items.len > 0) {
                try output.appendSlice("\nimages: ");
                try std.fmt.formatInt(output.writer(), @as(u32, @intCast(scraped.images.items.len)), 10, .lower, .{});
            }
            if (scraped.buttons.items.len > 0) {
                try output.appendSlice("\nbuttons: ");
                try std.fmt.formatInt(output.writer(), @as(u32, @intCast(scraped.buttons.items.len)), 10, .lower, .{});
            }
            try output.appendSlice("\n---\n\n");
        }

        // Add content
        try output.appendSlice(scraped.content.items);

        // Truncate if needed
        if (output.items.len > max_chars) {
            const truncated = try allocator.alloc(u8, max_chars);
            @memcpy(truncated, output.items[0..max_chars]);
            allocator.free(output.items);

            const suffix = try std.fmt.allocPrint(
                allocator,
                "\n\n[Content truncated at {d} chars, total was {d} chars]",
                .{ max_chars, output.items.len },
            );
            defer allocator.free(suffix);

            const final = try allocator.realloc(truncated, truncated.len + suffix.len);
            @memcpy(final[max_chars..], suffix);

            return ToolResult.ok(final);
        }

        return ToolResult.ok(output.toOwnedSlice());
    }
};

/// Structured scraped data from HTML
const ScrapedData = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    author: ?[]const u8 = null,
    og_type: ?[]const u8 = null,
    content: std.ArrayListUnmanaged(u8),
    links: std.ArrayListUnmanaged(Link),
    images: std.ArrayListUnmanaged(Image),
    buttons: std.ArrayListUnmanaged(Button),

    fn deinit(self: *ScrapedData, allocator: std.mem.Allocator) void {
        if (self.title) |t| allocator.free(t);
        if (self.description) |d| allocator.free(d);
        if (self.author) |a| allocator.free(a);
        if (self.og_type) |o| allocator.free(o);
        self.content.deinit(allocator);
        for (self.links.items) |*l| l.deinit(allocator);
        self.links.deinit(allocator);
        for (self.images.items) |*i| i.deinit(allocator);
        self.images.deinit(allocator);
        for (self.buttons.items) |*b| b.deinit(allocator);
        self.buttons.deinit(allocator);
    }
};

const Link = struct {
    text: []const u8,
    url: []const u8,

    fn deinit(self: *Link, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.url);
    }
};

const Image = struct {
    alt: []const u8,
    src: []const u8,

    fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        if (self.alt.len > 0) allocator.free(self.alt);
        allocator.free(self.src);
    }
};

const Button = struct {
    text: []const u8,
    button_type: ?[]const u8 = null, // submit, button, reset

    fn deinit(self: *Button, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.button_type) |t| allocator.free(t);
    }
};

/// Scrape HTML and extract structured data
fn scrapeHtml(allocator: std.mem.Allocator, html: []const u8, base_url: []const u8) !ScrapedData {
    var scraped = ScrapedData{
        .content = .empty,
        .links = .empty,
        .images = .empty,
        .buttons = .empty,
    };
    errdefer scraped.deinit(allocator);

    var i: usize = 0;
    var in_script = false;
    var in_style = false;
    var in_head = true;
    var skip_tag = false;
    var last_was_newline = false;
    var consecutive_newlines: u32 = 0;

    // Parse HTML
    while (i < html.len) {
        if (html[i] == '<') {
            const tag_end = std.mem.indexOfScalarPos(u8, html, i + 1, '>') orelse {
                i += 1;
                continue;
            };

            const tag_content = html[i + 1 .. tag_end];
            const tag_name = parseTagName(tag_content);

            // Handle opening/closing tags
            const is_closing = std.mem.startsWith(u8, tag_content, "/");

            // Track state
            if (std.ascii.eqlIgnoreCase(tag_name, "script")) {
                if (!is_closing) in_script = true else in_script = false;
            } else if (std.ascii.eqlIgnoreCase(tag_name, "style")) {
                if (!is_closing) in_style = true else in_style = false;
            } else if (std.ascii.eqlIgnoreCase(tag_name, "head")) {
                if (!is_closing) {
                    in_head = true;
                    // Extract metadata from head
                    try extractMetadata(allocator, html, i, tag_end, &scraped);
                } else {
                    in_head = false;
                }
            } else if (std.ascii.eqlIgnoreCase(tag_name, "body")) {
                if (!is_closing) in_head = false;
            }

            // Extract specific elements
            if (!in_script and !in_style) {
                if (std.ascii.eqlIgnoreCase(tag_name, "a") and !is_closing) {
                    try extractLink(allocator, html, i, tag_end, &scraped, base_url);
                } else if (std.ascii.eqlIgnoreCase(tag_name, "img") and !is_closing) {
                    try extractImage(allocator, html, i, tag_end, &scraped, base_url);
                } else if (std.ascii.eqlIgnoreCase(tag_name, "button") and !is_closing) {
                    try extractButton(allocator, html, i, tag_end, &scraped);
                } else if (std.ascii.eqlIgnoreCase(tag_name, "input") and !is_closing) {
                    const input_type = extractAttr(html[i .. tag_end], "type") orelse "text";
                    if (std.mem.indexOf(u8, "submit", input_type) != null) {
                        try extractButton(allocator, html, i, tag_end, &scraped);
                    }
                } else if (std.ascii.eqlIgnoreCase(tag_name, "title") and !is_closing) {
                    const title_start = tag_end + 1;
                    const title_end = std.mem.indexOfPos(u8, html, title_start, "</title>") orelse html.len;
                    if (title_end > title_start) {
                        const title_text = try extractText(allocator, html[title_start..title_end]);
                        if (scraped.title == null) {
                            scraped.title = title_text;
                        } else {
                            allocator.free(title_text);
                        }
                    }
                }
            }

            // Skip certain tags
            skip_tag = if (!is_closing)
                (std.ascii.eqlIgnoreCase(tag_name, "nav") or
                 std.ascii.eqlIgnoreCase(tag_name, "footer") or
                 std.ascii.eqlIgnoreCase(tag_name, "header") or
                 std.ascii.eqlIgnoreCase(tag_name, "aside") or
                 std.ascii.eqlIgnoreCase(tag_name, "iframe") or
                 std.ascii.eqlIgnoreCase(tag_name, "noscript"))
            else
                skip_tag;

            i = tag_end + 1;
            continue;
        }

        // Process text content
        if (!in_script and !in_style and !skip_tag and !in_head) {
            const text_start = i;
            while (i < html.len and html[i] != '<') : (i += 1) {}

            if (i > text_start) {
                const text = try extractText(allocator, html[text_start..i]);

                // Add to content
                for (text) |c| {
                    if (c == '\n') {
                        if (!last_was_newline) {
                            try scraped.content.append(allocator, '\n');
                            last_was_newline = true;
                            consecutive_newlines = 0;
                        }
                    } else if (!std.ascii.isSpace(c) or (c == ' ' and !last_was_newline)) {
                        try scraped.content.append(allocator, c);
                        last_was_newline = (c == '\n');
                        consecutive_newlines = 0;
                    }
                }

                allocator.free(text);
            }
        } else {
            i += 1;
        }
    }

    // Convert to markdown format
    var markdown = std.ArrayListUnmanaged(u8){};
    errdefer markdown.deinit(allocator);

    // Add title
    if (scraped.title) |title| {
        try markdown.appendSlice(allocator, "# ");
        try markdown.appendSlice(allocator, title);
        try markdown.appendSlice(allocator, "\n\n");
    }

    // Add main content
    try markdown.appendSlice(allocator, scraped.content.items);

    // Add links section
    if (scraped.links.items.len > 0) {
        try markdown.appendSlice(allocator, "\n\n## Links\n\n");
        for (scraped.links.items, 0..) |link, idx| {
            try std.fmt.formatInt(markdown.writer(), idx + 1, 10, .lower, .{});
            try markdown.appendSlice(allocator, ". ");
            try markdown.appendSlice(allocator, link.text);
            try markdown.appendSlice(allocator, " - ");
            try markdown.appendSlice(allocator, link.url);
            try markdown.appendSlice(allocator, "\n");
        }
    }

    // Replace content with markdown
    scraped.content.deinit(allocator);
    scraped.content = markdown;

    return scraped;
}

/// Parse tag name from tag content (e.g., "a href='...'" -> "a")
fn parseTagName(tag: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, tag, " \t\r\n/>") orelse tag.len;
    return tag[0..end];
}

/// Extract attribute value from tag
fn extractAttr(tag: []const u8, attr_name: []const u8) ?[]const u8 {
    // Simple attribute search - look for "attr_name=" or "attr_name ="
    const search_start = std.mem.indexOf(u8, tag, attr_name) orelse return null;
    var i = search_start + attr_name.len;

    // Skip whitespace after attribute name
    while (i < tag.len and (tag[i] == ' ' or tag[i] == '\t')) : (i += 1) {}

    // Check for '='
    if (i >= tag.len or tag[i] != '=') return null;
    i += 1;

    // Skip whitespace after '='
    while (i < tag.len and (tag[i] == ' ' or tag[i] == '\t')) : (i += 1) {}

    // Skip quotes
    const start = i;
    if (i < tag.len and (tag[i] == '"' or tag[i] == '\'')) {
        const quote = tag[i];
        i += 1;
        const end = std.mem.indexOfScalarPos(u8, tag, i, quote) orelse tag.len;
        return tag[i..end];
    }

    // Find end (space or >)
    const end = std.mem.indexOfAnyPos(u8, tag, start, " \t\r\n/>") orelse tag.len;
    return tag[start..end];
}

/// Extract and decode text content
fn extractText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, ';') orelse {
                try result.append(text[i]);
                i += 1;
                continue;
            };

            const entity = text[i..end];
            const decoded = decodeHtmlEntity(entity);
            if (decoded) |d| {
                try result.appendSlice(d);
            } else {
                try result.appendSlice(entity);
            }
            i = end + 1;
        } else {
            try result.append(text[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

/// Decode HTML entities
fn decodeHtmlEntity(entity: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, entity, "&amp;")) return "&";
    if (std.mem.eql(u8, entity, "&lt;")) return "<";
    if (std.mem.eql(u8, entity, "&gt;")) return ">";
    if (std.mem.eql(u8, entity, "&quot;")) return "\"";
    if (std.mem.eql(u8, entity, "&apos;")) return "'";
    if (std.mem.eql(u8, entity, "&nbsp;")) return " ";
    return null;
}

/// Extract metadata from head section
fn extractMetadata(allocator: std.mem.Allocator, html: []const u8, tag_start: usize, tag_end: usize, scraped: *ScrapedData) !void {
    _ = allocator;
    const tag_content = html[tag_start + 1 .. tag_end];
    const tag_name = parseTagName(tag_content);

    if (!std.ascii.eqlIgnoreCase(tag_name, "meta")) return;

    const property = extractAttr(tag_content, "property") orelse extractAttr(tag_content, "name");
    const content_attr = extractAttr(tag_content, "content");

    if (property == null or content_attr == null) return;

    if (std.mem.eql(u8, property.?, "og:title") or std.mem.eql(u8, property.?, "title")) {
        if (scraped.title == null) {
            scraped.title = try allocator.dupe(u8, content_attr.?);
        }
    } else if (std.mem.eql(u8, property.?, "og:description") or std.mem.eql(u8, property.?, "description")) {
        if (scraped.description == null) {
            scraped.description = try allocator.dupe(u8, content_attr.?);
        }
    } else if (std.mem.eql(u8, property.?, "og:type")) {
        if (scraped.og_type == null) {
            scraped.og_type = try allocator.dupe(u8, content_attr.?);
        }
    } else if (std.mem.eql(u8, property.?, "author")) {
        if (scraped.author == null) {
            scraped.author = try allocator.dupe(u8, content_attr.?);
        }
    }
}

/// Extract link from <a> tag
fn extractLink(allocator: std.mem.Allocator, html: []const u8, tag_start: usize, tag_end: usize, scraped: *ScrapedData, base_url: []const u8) !void {
    const tag_content = html[tag_start + 1 .. tag_end];
    const href = extractAttr(tag_content, "href") orelse return;

    // Resolve relative URLs
    const resolved_url = resolveUrl(allocator, href, base_url) catch |_err| {
        log.warn("Failed to resolve URL: {s}", .{href});
        return;
    };

    // Extract link text (between > and </a>)
    const text_start = tag_end + 1;
    const text_end = std.mem.indexOfPos(u8, html, text_start, "</a>") orelse html.len;
    const text_raw = html[text_start..@min(text_end, text_start + 200)];
    const text = extractText(allocator, text_raw) catch "";

    try scraped.links.append(allocator, .{
        .text = text,
        .url = resolved_url,
    });
}

/// Extract image from <img> tag
fn extractImage(allocator: std.mem.Allocator, html: []const u8, tag_start: usize, tag_end: usize, scraped: *ScrapedData, base_url: []const u8) !void {
    const tag_content = html[tag_start + 1 .. tag_end];
    const src = extractAttr(tag_content, "src") orelse return;
    const alt = extractAttr(tag_content, "alt") orelse "";

    // Resolve relative URLs
    const resolved_src = resolveUrl(allocator, src, base_url) catch |_err| {
        log.warn("Failed to resolve image URL: {s}", .{src});
        return;
    };

    try scraped.images.append(allocator, .{
        .alt = try allocator.dupe(u8, alt),
        .src = resolved_src,
    });
}

/// Extract button from <button> or <input type="submit"> tag
fn extractButton(allocator: std.mem.Allocator, html: []const u8, tag_start: usize, tag_end: usize, scraped: *ScrapedData) !void {
    const tag_content = html[tag_start + 1 .. tag_end];

    // Extract button text
    const text_start = tag_end + 1;
    const text_end = blk: {
        var end = text_start;
        while (end < html.len) {
            if (html[end] == '<') {
                if (std.mem.startsWith(u8, html[end..], "</")) {
                    break :blk @min(end, text_start + 100);
                }
            }
            end += 1;
        }
        break :blk @min(end, text_start + 100);
    };

    const text_raw = html[text_start..text_end];
    const text = if (text_raw.len > 0)
        try extractText(allocator, text_raw)
    else
        try allocator.dupe(u8, "Submit");

    // Get button type
    const button_type = extractAttr(tag_content, "type");

    try scraped.buttons.append(allocator, .{
        .text = text,
        .button_type = if (button_type) |bt| try allocator.dupe(u8, bt) else null,
    });
}

/// Resolve URL relative to base URL
fn resolveUrl(allocator: std.mem.Allocator, url: []const u8, base: []const u8) ![]u8 {
    // Already absolute
    if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) {
        return allocator.dupe(u8, url);
    }

    const base_uri = std.Uri.parse(base) catch return error.InvalidUrl;

    // Extract scheme as string
    const scheme = switch (base_uri.scheme) {
        .raw => |s| s,
        else => return error.InvalidUrl,
    };

    // Extract host as string
    const host = switch (base_uri.host) {
        .raw => |h| h,
        else => return error.InvalidUrl,
    };

    // Protocol-relative
    if (std.mem.startsWith(u8, url, "//")) {
        return std.fmt.allocPrint(allocator, "{s}://{s}", .{ scheme, url[2..] });
    }

    // Absolute path
    if (std.mem.startsWith(u8, url, "/")) {
        return std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{ scheme, host, url });
    }

    // Relative path - resolve relative to base path
    const base_path = switch (base_uri.path) {
        .raw => |p| p,
        .percent_encoded => |p| p,
        null => "/",
    };

    // Remove filename from base path
    const last_slash = std.mem.lastIndexOfScalar(u8, base_path, '/');
    const dir_path = if (last_slash) |pos| base_path[0..pos] else "/";

    return std.fmt.allocPrint(allocator, "{s}://{s}{s}/{s}", .{
        scheme,
        host,
        dir_path,
        url,
    });
}

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
