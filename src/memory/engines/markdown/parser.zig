//! Markdown entry parsing utilities.
//!
//! Parses markdown files into MemoryEntry structures, handling
//! comments, headings, and bullet points.

const std = @import("std");
const MemoryEntry = @import("../../root.zig").MemoryEntry;
const MemoryCategory = @import("../../root.zig").MemoryCategory;

const io = std.Options.debug_io;

/// Parse markdown text into memory entries.
///
/// Args:
///   - text: Raw markdown content
///   - filename: Source filename (used for entry IDs)
///   - category: Memory category for all entries
///   - allocator: Memory allocator
///
/// Returns: Slice of MemoryEntry (caller owns)
pub fn parseEntries(
    text: []const u8,
    filename: []const u8,
    category: MemoryCategory,
    allocator: std.mem.Allocator,
) ![]MemoryEntry {
    var entries: std.ArrayList(MemoryEntry) = .empty;
    errdefer {
        for (entries.items) |*e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    var line_idx: usize = 0;
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') {
            continue;
        }

        const clean = if (std.mem.startsWith(u8, trimmed, "- "))
            trimmed[2..]
        else
            trimmed;

        const id = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ filename, line_idx });
        errdefer allocator.free(id);
        const key = try allocator.dupe(u8, id);
        errdefer allocator.free(key);
        const content_dup = try allocator.dupe(u8, clean);
        errdefer allocator.free(content_dup);
        const timestamp = try allocator.dupe(u8, filename);
        errdefer allocator.free(timestamp);

        const cat = switch (category) {
            .custom => |name| MemoryCategory{ .custom = try allocator.dupe(u8, name) },
            else => category,
        };

        try entries.append(allocator, MemoryEntry{
            .id = id,
            .key = key,
            .content = content_dup,
            .category = cat,
            .timestamp = timestamp,
        });

        line_idx += 1;
    }

    return entries.toOwnedSlice(allocator);
}

// ── Tests ────────────────────────────────────────────────────────────

test "parseEntries skips empty lines" {
    const text = "line one\n\n\nline two\n";
    const entries = try parseEntries(text, "test", .core, std.testing.allocator);
    defer {
        for (entries) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("line one", entries[0].content);
    try std.testing.expectEqualStrings("line two", entries[1].content);
}

test "parseEntries skips headings" {
    const text = "# Heading\nContent under heading\n## Sub\nMore content";
    const entries = try parseEntries(text, "test", .core, std.testing.allocator);
    defer {
        for (entries) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("Content under heading", entries[0].content);
    try std.testing.expectEqualStrings("More content", entries[1].content);
}

test "parseEntries strips bullet prefix" {
    const text = "- Item one\n- Item two\nPlain line";
    const entries = try parseEntries(text, "test", .core, std.testing.allocator);
    defer {
        for (entries) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("Item one", entries[0].content);
    try std.testing.expectEqualStrings("Item two", entries[1].content);
    try std.testing.expectEqualStrings("Plain line", entries[2].content);
}

test "parseEntries generates sequential ids" {
    const text = "a\nb\nc";
    const entries = try parseEntries(text, "myfile", .core, std.testing.allocator);
    defer {
        for (entries) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("myfile:0", entries[0].id);
    try std.testing.expectEqualStrings("myfile:1", entries[1].id);
    try std.testing.expectEqualStrings("myfile:2", entries[2].id);
}

test "parseEntries empty text returns empty" {
    const entries = try parseEntries("", "test", .core, std.testing.allocator);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "parseEntries only headings returns empty" {
    const text = "# Heading\n## Another\n### Third";
    const entries = try parseEntries(text, "test", .core, std.testing.allocator);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "parseEntries preserves category" {
    const text = "content";
    const entries = try parseEntries(text, "test", .daily, std.testing.allocator);
    defer {
        for (entries) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expect(entries[0].category.eql(.daily));
}
