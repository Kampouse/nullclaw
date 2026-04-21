//! Consolidation pattern persistence to SQLite.
//!
//! Stores extracted consolidation patterns in a SQLite table so they can
//! be reviewed and approved/rejected by a human operator before being
//! used for reinforcement-learning training.

const std = @import("std");
const build_options = @import("build_options");
const sqlite_mod = if (build_options.enable_sqlite) @import("../engines/sqlite.zig") else @import("../engines/sqlite_disabled.zig");
const c = sqlite_mod.c;
const SQLITE_STATIC = sqlite_mod.SQLITE_STATIC;
const consolidation = @import("consolidation.zig");
const util = @import("../../util.zig");

const log = std.log.scoped(.pattern_store);

const Allocator = std.mem.Allocator;

// ── Stored Pattern ────────────────────────────────────────────────────

/// A pattern row as read back from the database.
pub const StoredPattern = struct {
    id: []const u8,
    pattern_type: []const u8,
    description: []const u8,
    confidence: f64,
    reward: f64,
    hint: ?[]const u8,
    source_conversations: ?[]const u8,
    status: []const u8,
    auto_approved: bool,
    created_at: ?[]const u8,
    reviewed_at: ?[]const u8,

    pub fn deinit(self: *StoredPattern, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.pattern_type);
        allocator.free(self.description);
        if (self.hint) |h| allocator.free(h);
        if (self.source_conversations) |s| allocator.free(s);
        allocator.free(self.status);
        if (self.created_at) |t| allocator.free(t);
        if (self.reviewed_at) |t| allocator.free(t);
    }
};

// ── Pattern Store ─────────────────────────────────────────────────────

/// Persists consolidation patterns to a SQLite table for human review.
///
/// The store borrows a `*c.sqlite3` handle — it does NOT own or close it.
pub const PatternStore = struct {
    db: *c.sqlite3,
    allocator: Allocator,

    const Self = @This();

    /// Create a new PatternStore. `db` must remain valid for the
    /// lifetime of this store; the store does not close it.
    pub fn init(allocator: Allocator, db: *c.sqlite3) Self {
        return Self{ .db = db, .allocator = allocator };
    }

    /// Create the consolidation_patterns table and indexes if they
    /// do not already exist.
    pub fn ensureSchema(self: *Self) !void {
        const sql =
            \\CREATE TABLE IF NOT EXISTS consolidation_patterns (
            \\    id TEXT PRIMARY KEY,
            \\    pattern_type TEXT NOT NULL CHECK(pattern_type IN ('positive','negative','improvement')),
            \\    description TEXT NOT NULL,
            \\    confidence REAL NOT NULL DEFAULT 0.0,
            \\    reward REAL NOT NULL DEFAULT 0.0,
            \\    hint TEXT,
            \\    source_conversations TEXT,
            \\    status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','approved','rejected')),
            \\    auto_approved INTEGER NOT NULL DEFAULT 0,
            \\    created_at TEXT NOT NULL DEFAULT (datetime('now')),
            \\    reviewed_at TEXT
            \\);
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_step(stmt);

        // Create indexes for common query patterns
        const indexes =
            \\CREATE INDEX IF NOT EXISTS idx_patterns_status ON consolidation_patterns(status);
            \\CREATE INDEX IF NOT EXISTS idx_patterns_type ON consolidation_patterns(pattern_type);
        ;
        var stmt2: ?*c.sqlite3_stmt = null;
        const rc2 = c.sqlite3_prepare_v2(self.db, indexes, -1, &stmt2, null);
        if (rc2 == c.SQLITE_OK) {
            _ = c.sqlite3_step(stmt2);
            _ = c.sqlite3_finalize(stmt2);
        }
    }

    /// Store a single pattern.
    pub fn storePattern(
        self: *Self,
        allocator: Allocator,
        pattern_type: []const u8,
        description: []const u8,
        confidence: f64,
        reward: f64,
        hint: ?[]const u8,
        source_convs_json: ?[]const u8,
    ) !void {
        const id_str = try std.fmt.allocPrint(allocator, "{d}", .{util.nanoTimestamp()});
        defer allocator.free(id_str);

        const sql =
            \\INSERT INTO consolidation_patterns
            \\  (id, pattern_type, description, confidence, reward, hint, source_conversations, status)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, 'pending');
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, id_str.ptr, @intCast(id_str.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, pattern_type.ptr, @intCast(pattern_type.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, description.ptr, @intCast(description.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_double(stmt, 4, confidence);
        _ = c.sqlite3_bind_double(stmt, 5, reward);
        if (hint) |h| {
            _ = c.sqlite3_bind_text(stmt, 6, h.ptr, @intCast(h.len), SQLITE_STATIC);
        } else {
            _ = c.sqlite3_bind_null(stmt, 6);
        }
        if (source_convs_json) |sc| {
            _ = c.sqlite3_bind_text(stmt, 7, sc.ptr, @intCast(sc.len), SQLITE_STATIC);
        } else {
            _ = c.sqlite3_bind_null(stmt, 7);
        }

        const step_rc = c.sqlite3_step(stmt);
        if (step_rc != c.SQLITE_DONE) return error.InsertFailed;
    }

    /// Bulk-store patterns extracted by the consolidation engine.
    /// Returns the number of patterns successfully stored.
    pub fn storePatterns(
        self: *Self,
        allocator: Allocator,
        patterns: []const consolidation.ExtractedPattern,
        source_conv_ids: []const []const u8,
    ) !usize {
        var stored: usize = 0;
        for (patterns) |pat| {
            const type_str = switch (pat.pattern_type) {
                .positive => "positive",
                .negative => "negative",
                .improvement => "improvement",
            };

            self.storePattern(
                allocator,
                type_str,
                pat.description,
                @floatCast(pat.confidence),
                @floatCast(pat.reward),
                pat.hint,
                if (source_conv_ids.len > 0) blk: {
                    var parts: std.ArrayList([]const u8) = .empty;
                    defer parts.deinit(allocator);
                    for (source_conv_ids) |cid| {
                        try parts.append(allocator, cid);
                    }
                    const joined = try std.mem.join(allocator, ",", parts.items);
                    const result = try std.fmt.allocPrint(allocator, "[{s}]", .{joined});
                    allocator.free(joined);
                    break :blk result;
                } else null,
            ) catch |err| {
                log.warn("Failed to store pattern: {}", .{err});
                continue;
            };
            stored += 1;
        }
        return stored;
    }

    /// List patterns, optionally filtered by status.
    pub fn listPatterns(
        self: *Self,
        allocator: Allocator,
        status_filter: ?[]const u8,
        limit: usize,
    ) ![]StoredPattern {
        const sql = if (status_filter != null)
            \\SELECT id, pattern_type, description, confidence, reward, hint,
            \\       source_conversations, status, auto_approved, created_at, reviewed_at
            \\FROM consolidation_patterns WHERE status = ? ORDER BY created_at DESC LIMIT ?;
        else
            \\SELECT id, pattern_type, description, confidence, reward, hint,
            \\       source_conversations, status, auto_approved, created_at, reviewed_at
            \\FROM consolidation_patterns ORDER BY created_at DESC LIMIT ?;
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (status_filter) |sf| {
            _ = c.sqlite3_bind_text(stmt, 1, sf.ptr, @intCast(sf.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_int64(stmt, 2, @intCast(limit));
        } else {
            _ = c.sqlite3_bind_int64(stmt, 1, @intCast(limit));
        }

        var results = std.ArrayList(StoredPattern).init(allocator);
        errdefer {
            for (results.items) |*r| r.deinit(allocator);
            results.deinit();
        }

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const row = try self.readRow(allocator, stmt);
            try results.append(row);
        }

        return results.toOwnedSlice();
    }

    /// Count patterns matching a given status.
    pub fn countByStatus(self: *Self, status: []const u8) !usize {
        const sql = "SELECT COUNT(*) FROM consolidation_patterns WHERE status = ?;";

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, status.ptr, @intCast(status.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            return @intCast(c.sqlite3_column_int(stmt, 0));
        }

        return 0;
    }

    /// Update the status of a pending pattern.
    pub fn approvePattern(self: *Self, id: []const u8) !bool {
        return self.setStatus(id, "approved");
    }

    /// Reject a pending pattern.
    pub fn rejectPattern(self: *Self, id: []const u8) !bool {
        return self.setStatus(id, "rejected");
    }

    /// Delete a pattern by id.
    pub fn deletePattern(self: *Self, id: []const u8) !bool {
        const sql = "DELETE FROM consolidation_patterns WHERE id = ?;";

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);

        const step_rc = c.sqlite3_step(stmt);
        if (step_rc != c.SQLITE_DONE) return error.DeleteFailed;

        return c.sqlite3_changes(self.db) > 0;
    }

    /// Get count of pending patterns awaiting review.
    pub fn getPendingCount(self: *Self) !usize {
        return self.countByStatus("pending");
    }

    pub fn deinit(_: *Self) void {
        // No owned resources — db handle is borrowed.
    }

    fn setStatus(self: *Self, id: []const u8, new_status: []const u8) !bool {
        const sql =
            \\UPDATE consolidation_patterns
            \\SET status = ?, reviewed_at = datetime('now')
            \\WHERE id = ? AND status = 'pending';
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, new_status.ptr, @intCast(new_status.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);

        const step_rc = c.sqlite3_step(stmt);
        if (step_rc != c.SQLITE_DONE) return error.UpdateFailed;

        return c.sqlite3_changes(self.db) > 0;
    }

    fn readRow(self: *Self, allocator: Allocator, stmt: *c.sqlite3_stmt) !StoredPattern {
        return StoredPattern{
            .id = try self.colText(allocator, stmt, 0),
            .pattern_type = try self.colText(allocator, stmt, 1),
            .description = try self.colText(allocator, stmt, 2),
            .confidence = c.sqlite3_column_double(stmt, 3),
            .reward = c.sqlite3_column_double(stmt, 4),
            .hint = try self.colTextOpt(allocator, stmt, 5),
            .source_conversations = try self.colTextOpt(allocator, stmt, 6),
            .status = try self.colText(allocator, stmt, 7),
            .auto_approved = c.sqlite3_column_int(stmt, 8) != 0,
            .created_at = try self.colTextOpt(allocator, stmt, 9),
            .reviewed_at = try self.colTextOpt(allocator, stmt, 10),
        };
    }

    fn colText(_: *Self, allocator: Allocator, stmt: *c.sqlite3_stmt, col: c_int) ![]const u8 {
        const ptr = c.sqlite3_column_text(stmt, col) orelse return "";
        const typed: [*]const u8 = @ptrCast(ptr);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
        return allocator.dupe(u8, typed[0..len]);
    }

    fn colTextOpt(_: *Self, allocator: Allocator, stmt: *c.sqlite3_stmt, col: c_int) !?[]const u8 {
        const ptr = c.sqlite3_column_text(stmt, col) orelse return null;
        const typed: [*]const u8 = @ptrCast(ptr);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
        return allocator.dupe(u8, typed[0..len]);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "ensureSchema creates table and indexes" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var mem = try sqlite_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer mem.deinit();
    const db = mem.db.?;

    var store = PatternStore.init(testing.allocator, db);
    try store.ensureSchema();

    // Verify the table exists by inserting and reading back.
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM consolidation_patterns;", -1, &stmt, null);
    try testing.expectEqual(@as(c_int, c.SQLITE_OK), rc);
    defer _ = c.sqlite3_finalize(stmt);
    try testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try testing.expectEqual(0, c.sqlite3_column_int(stmt, 0));
}

test "storePattern and listPatterns round-trip" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var mem = try sqlite_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer mem.deinit();
    const db = mem.db.?;

    var store = PatternStore.init(testing.allocator, db);
    try store.ensureSchema();

    try store.storePattern(
        testing.allocator,
        "positive",
        "User prefers concise responses",
        0.95,
        0.8,
        null,
        null,
    );

    const patterns = try store.listPatterns(testing.allocator, null, 10);
    defer {
        for (patterns) |*p| p.deinit(testing.allocator);
        testing.allocator.free(patterns);
    }

    try testing.expectEqual(@as(usize, 1), patterns.len);
    try testing.expectEqualStrings("positive", patterns[0].pattern_type);
    try testing.expectEqualStrings("User prefers concise responses", patterns[0].description);
    try testing.expectEqualStrings("pending", patterns[0].status);
}

test "storePattern with hint and source conversations" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var mem = try sqlite_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer mem.deinit();
    const db = mem.db.?;

    var store = PatternStore.init(testing.allocator, db);
    try store.ensureSchema();

    // Use Python-style string with escaped quotes for JSON
    const json_conv_ids = "[\"conv-1\",\"conv-2\"]";
    try store.storePattern(
        testing.allocator,
        "improvement",
        "Should ask clarifying questions",
        0.7,
        0.0,
        "When requirements are ambiguous, ask before proceeding",
        json_conv_ids,
    );

    const patterns = try store.listPatterns(testing.allocator, null, 10);
    defer {
        for (patterns) |*p| p.deinit(testing.allocator);
        testing.allocator.free(patterns);
    }

    try testing.expectEqual(@as(usize, 1), patterns.len);
    try testing.expect(patterns[0].hint != null);
    try testing.expectEqualStrings("When requirements are ambiguous, ask before proceeding", patterns[0].hint.?);
    try testing.expect(patterns[0].source_conversations != null);
}

test "listPatterns with status filter" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var mem = try sqlite_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer mem.deinit();
    const db = mem.db.?;

    var store = PatternStore.init(testing.allocator, db);
    try store.ensureSchema();

    try store.storePattern(testing.allocator, "positive", "A", 0.9, 0.5, null, null);
    try store.storePattern(testing.allocator, "negative", "B", 0.3, -0.5, null, null);

    _ = try store.approvePattern("1");

    const pending = try store.listPatterns(testing.allocator, "pending", 10);
    defer {
        for (pending) |*p| p.deinit(testing.allocator);
        testing.allocator.free(pending);
    }
    try testing.expectEqual(@as(usize, 1), pending.len);

    const approved = try store.listPatterns(testing.allocator, "approved", 10);
    defer {
        for (approved) |*p| p.deinit(testing.allocator);
        testing.allocator.free(approved);
    }
    try testing.expectEqual(@as(usize, 1), approved.len);
}

test "countByStatus" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var mem = try sqlite_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer mem.deinit();
    const db = mem.db.?;

    var store = PatternStore.init(testing.allocator, db);
    try store.ensureSchema();

    try store.storePattern(testing.allocator, "positive", "A", 0.9, 0.5, null, null);
    try store.storePattern(testing.allocator, "positive", "B", 0.8, 0.4, null, null);

    const count = try store.countByStatus("pending");
    try testing.expectEqual(@as(usize, 2), count);
}

test "deletePattern" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var mem = try sqlite_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer mem.deinit();
    const db = mem.db.?;

    var store = PatternStore.init(testing.allocator, db);
    try store.ensureSchema();

    try store.storePattern(testing.allocator, "positive", "To delete", 0.5, 0.0, null, null);

    const deleted = try store.deletePattern("1");
    try testing.expect(deleted);

    const patterns = try store.listPatterns(testing.allocator, null, 10);
    defer {
        for (patterns) |*p| p.deinit(testing.allocator);
        testing.allocator.free(patterns);
    }
    try testing.expectEqual(@as(usize, 0), patterns.len);
}

test "getPendingCount" {
    if (!build_options.enable_sqlite) return error.SkipZigTest;

    var mem = try sqlite_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer mem.deinit();
    const db = mem.db.?;

    var store = PatternStore.init(testing.allocator, db);
    try store.ensureSchema();

    try store.storePattern(testing.allocator, "positive", "A", 0.9, 0.5, null, null);
    try store.storePattern(testing.allocator, "negative", "B", 0.3, -0.5, null, null);

    const count = try store.getPendingCount();
    try testing.expectEqual(@as(usize, 2), count);
}
