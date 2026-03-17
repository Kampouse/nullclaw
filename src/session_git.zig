//! Git-Like Session Architecture
//!
//! This module implements a Git-like content-addressable session model where:
//! - Each conversation turn is an immutable commit
//! - Threads (branches) allow parallel processing
//! - Merge combines divergent conversation histories
//!
//! Memory Management:
//! - ObjectStore owns all Message and Turn objects
//! - Reference counting ensures safe sharing across threads
//! - Thread names are owned separately from hash map keys
//! - All allocations are tracked and freed in deinit()
//! - No global state, all ownership is explicit

const std = @import("std");
const crypto = std.crypto;
const hash = crypto.hash;
const Sha256 = hash.sha2.Sha256;
const Atomic = @import("portable_atomic.zig").Atomic;
const Allocator = std.mem.Allocator;
const util = @import("util.zig");

pub const log = std.log.scoped(.session_git);

// ═══════════════════════════════════════════════════════════════════════════
// Content-Addressable Hash
// ═══════════════════════════════════════════════════════════════════════════

/// SHA-256 hash used for content addressing
pub const Hash = [32]u8;

/// Compute SHA-256 hash of data
fn computeHash(data: []const u8) Hash {
    var result: Hash = undefined;
    Sha256.hash(data, &result, .{});
    return result;
}

/// Convert hash to hex string (caller owns memory)
fn hashToHex(allocator: Allocator, h: Hash) ![]const u8 {
    var buf: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x}", .{std.fmt.fmtSliceHexLower(&h)}) catch return error.OutOfMemory;
    return allocator.dupe(u8, buf[0..64]);
}

// ═══════════════════════════════════════════════════════════════════════════
// Message (like Git blob - immutable content)
// ═══════════════════════════════════════════════════════════════════════════

/// Role in conversation
pub const MessageRole = enum {
    user,
    assistant,
    tool,
    system,

    pub fn toSlice(self: MessageRole) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
            .system => "system",
        };
    }
};

/// Immutable message (like Git blob)
/// Reference counted for safe sharing across threads
pub const Message = struct {
    role: MessageRole,
    content: []const u8,
    hash: Hash,
    ref_count: Atomic(usize),

    /// Create a new message (owned by ObjectStore)
    pub fn init(allocator: Allocator, role: MessageRole, content: []const u8) !*Message {
        const owned_content = try allocator.dupe(u8, content);
        errdefer allocator.free(owned_content);

        const msg = try allocator.create(Message);
        errdefer allocator.destroy(msg);

        // Compute hash from role + content
        var hasher = Sha256.init(.{});
        hasher.update(role.toSlice());
        hasher.update(content);
        var computed_hash: Hash = undefined;
        hasher.final(&computed_hash);

        msg.* = .{
            .role = role,
            .content = owned_content,
            .hash = computed_hash,
            .ref_count = Atomic(usize).init(1),
        };

        return msg;
    }

    /// Increment reference count (safe for const pointers - atomic is internally mutable)
    pub fn ref(self: *const Message) *const Message {
        // Atomic operations are thread-safe, ref_count is safe to modify
        _ = @constCast(self).ref_count.fetchAdd(1, .monotonic);
        return self;
    }

    /// Decrement reference count, returns true if should be freed
    pub fn unref(self: *const Message) bool {
        return @constCast(self).ref_count.fetchSub(1, .monotonic) == 1;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Turn (like Git commit - immutable snapshot)
// ═══════════════════════════════════════════════════════════════════════════

/// Metadata for a turn
pub const TurnMetadata = struct {
    token_count: u64 = 0,
    model_name: []const u8 = "",
    provider: []const u8 = "",
};

/// Immutable conversation turn (like Git commit)
/// Can have multiple parents for merge commits
pub const Turn = struct {
    id: Hash,
    messages: []*const Message,
    parents: []*const Turn,
    timestamp: i64,
    metadata: TurnMetadata,
    ref_count: Atomic(usize),

    /// Create a new turn (owned by ObjectStore)
    pub fn init(
        allocator: Allocator,
        messages: []*const Message,
        parents: []*const Turn,
        metadata: TurnMetadata,
    ) !*Turn {
        // Compute hash from all content
        var hasher = Sha256.init(.{});

        // Hash messages
        for (messages) |msg| {
            hasher.update(&msg.hash);
        }

        // Hash parents
        for (parents) |parent| {
            hasher.update(&parent.id);
        }

        // Hash timestamp
        hasher.update(std.mem.asBytes(&metadata.token_count));

        var computed_hash: Hash = undefined;
        hasher.final(&computed_hash);

        // Copy messages and parents arrays
        const owned_messages = try allocator.dupe(*const Message, messages);
        errdefer allocator.free(owned_messages);

        const owned_parents = try allocator.dupe(*const Turn, parents);
        errdefer allocator.free(owned_parents);

        // Copy metadata strings
        var owned_metadata = metadata;
        if (metadata.model_name.len > 0) {
            owned_metadata.model_name = try allocator.dupe(u8, metadata.model_name);
        }
        if (metadata.provider.len > 0) {
            owned_metadata.provider = try allocator.dupe(u8, metadata.provider);
        }

        const turn = try allocator.create(Turn);
        errdefer allocator.destroy(turn);

        turn.* = .{
            .id = computed_hash,
            .messages = owned_messages,
            .parents = owned_parents,
            .timestamp = @intCast(@divTrunc(util.nanoTimestamp(), 1_000_000_000)),
            .metadata = owned_metadata,
            .ref_count = Atomic(usize).init(1),
        };

        // Ref all messages
        for (messages) |msg| {
            _ = msg.ref();
        }

        // Ref all parents
        for (parents) |parent| {
            _ = parent.ref();
        }

        return turn;
    }

    /// Increment reference count (safe for const pointers - atomic is internally mutable)
    pub fn ref(self: *const Turn) *const Turn {
        _ = @constCast(self).ref_count.fetchAdd(1, .monotonic);
        return self;
    }

    /// Decrement reference count, returns true if should be freed
    pub fn unref(self: *const Turn) bool {
        return @constCast(self).ref_count.fetchSub(1, .monotonic) == 1;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Thread (like Git branch - mutable pointer)
// ═══════════════════════════════════════════════════════════════════════════

/// Thread (like Git branch)
/// Just a named pointer to a head Turn
pub const Thread = struct {
    /// Thread name (owned separately by Thread struct)
    name: []const u8,
    head: *const Turn,
    created_at: i64,

    /// Update head to new turn (does not take ownership)
    pub fn updateHead(self: *Thread, new_head: *const Turn) void {
        // Ref new head before unref'ing old
        _ = new_head.ref();
        // Unref old head
        if (self.head.unref()) {
            // Should not happen - ObjectStore owns turns
            log.warn("Thread head reached zero ref count unexpectedly", .{});
        }
        self.head = new_head;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// ObjectStore (content-addressable storage)
// ═══════════════════════════════════════════════════════════════════════════

/// Content-addressable object store (like Git object database)
/// Owns all Message and Turn objects
pub const ObjectStore = struct {
    allocator: Allocator,

    /// Message hash -> Message (owned)
    messages: std.HashMapUnmanaged(Hash, *Message, struct {
        pub fn hash(_: @This(), h: Hash) u64 {
            return @as(u64, @bitCast(h[0..8].*));
        }
        pub fn eql(_: @This(), a: Hash, b: Hash) bool {
            return std.mem.eql(u8, &a, &b);
        }
    }, std.hash_map.default_max_load_percentage),

    /// Turn hash -> Turn (owned)
    turns: std.HashMapUnmanaged(Hash, *Turn, struct {
        pub fn hash(_: @This(), h: Hash) u64 {
            return @as(u64, @bitCast(h[0..8].*));
        }
        pub fn eql(_: @This(), a: Hash, b: Hash) bool {
            return std.mem.eql(u8, &a, &b);
        }
    }, std.hash_map.default_max_load_percentage),

    pub fn init(allocator: Allocator) ObjectStore {
        return .{
            .allocator = allocator,
            .messages = .{},
            .turns = .{},
        };
    }

    pub fn deinit(self: *ObjectStore) void {
        // Free all turns first (they reference messages)
        var turn_iter = self.turns.valueIterator();
        while (turn_iter.next()) |turn| {
            // Free messages array
            self.allocator.free(turn.*.messages);
            // Free parents array
            self.allocator.free(turn.*.parents);
            // Free metadata strings
            if (turn.*.metadata.model_name.len > 0) {
                self.allocator.free(turn.*.metadata.model_name);
            }
            if (turn.*.metadata.provider.len > 0) {
                self.allocator.free(turn.*.metadata.provider);
            }
            // Destroy turn struct
            self.allocator.destroy(turn.*);
        }
        self.turns.deinit(self.allocator);

        // Free all messages
        var msg_iter = self.messages.valueIterator();
        while (msg_iter.next()) |msg| {
            self.allocator.free(msg.*.content);
            self.allocator.destroy(msg.*);
        }
        self.messages.deinit(self.allocator);
    }

    /// Store a message (deduplicated by hash)
    pub fn storeMessage(self: *ObjectStore, role: MessageRole, content: []const u8) !*const Message {
        // Compute hash first
        var hasher = Sha256.init(.{});
        hasher.update(role.toSlice());
        hasher.update(content);
        var computed_hash: Hash = undefined;
        hasher.final(&computed_hash);

        // Check if already stored
        if (self.messages.get(computed_hash)) |existing| {
            return existing;
        }

        // Create new message
        const msg = try Message.init(self.allocator, role, content);
        errdefer self.allocator.destroy(msg);

        try self.messages.putNoClobber(self.allocator, msg.hash, msg);
        return msg;
    }

    /// Store a turn (deduplicated by hash)
    pub fn storeTurn(
        self: *ObjectStore,
        messages: []*const Message,
        parents: []*const Turn,
        metadata: TurnMetadata,
    ) !*const Turn {
        // Create turn (computes hash internally)
        const turn = try Turn.init(self.allocator, messages, parents, metadata);
        errdefer self.allocator.destroy(turn);

        // Check if already stored
        if (self.turns.get(turn.id)) |existing| {
            // Unref the newly created turn and return existing
            // Note: turn was created with ref_count=1, so unref will return false
            _ = turn.unref();
            return existing;
        }

        try self.turns.putNoClobber(self.allocator, turn.id, turn);
        return turn;
    }

    /// Get message by hash
    pub fn getMessage(self: *ObjectStore, h: Hash) ?*const Message {
        return self.messages.get(h);
    }

    /// Get turn by hash
    pub fn getTurn(self: *ObjectStore, h: Hash) ?*const Turn {
        return self.turns.get(h);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Session (like Git repository)
// ═══════════════════════════════════════════════════════════════════════════

/// Result of a merge operation
pub const MergeResult = struct {
    success: bool,
    conflicts: []const Conflict,
    merged_turn: ?*const Turn,
};

/// Conflict between two turns
pub const Conflict = struct {
    turn_a: *const Turn,
    turn_b: *const Turn,
    resolution: Resolution,

    const Resolution = enum {
        take_ours,
        take_theirs,
        keep_both,
        manual,
    };
};

/// Git-like session (repository)
pub const GitSession = struct {
    allocator: Allocator,
    object_store: ObjectStore,
    /// Thread name -> Thread pointer
    /// Key is owned by this map, Thread.name points to the same memory
    threads: std.StringHashMapUnmanaged(*Thread),
    /// Current active thread name (points to a key in threads map)
    active_thread_name: []const u8,
    main_thread_name: []const u8 = "main",

    // Empty root turn (like Git root commit)
    root_turn: ?*const Turn = null,

    pub fn init(allocator: Allocator) !GitSession {
        var store = ObjectStore.init(allocator);

        // Create empty root turn
        const root = try store.storeTurn(&.{}, &.{}, .{});
        errdefer store.deinit();

        var threads: std.StringHashMapUnmanaged(*Thread) = .{};
        errdefer threads.deinit(allocator);

        // Create main thread
        // Allocate name once - shared by hash map key, thread.name, and active_thread_name
        const owned_name = try allocator.dupe(u8, "main");
        errdefer allocator.free(owned_name);

        const main_thread = try allocator.create(Thread);
        errdefer allocator.destroy(main_thread);

        main_thread.* = .{
            .name = owned_name, // Points to same memory as hash map key
            .head = root,
            .created_at = @intCast(@divTrunc(util.nanoTimestamp(), 1_000_000_000)),
        };

        try threads.putNoClobber(allocator, owned_name, main_thread);

        return .{
            .allocator = allocator,
            .object_store = store,
            .threads = threads,
            .active_thread_name = owned_name, // Points to same memory as hash map key
            .root_turn = root,
        };
    }

    pub fn deinit(self: *GitSession) void {
        // Free all threads
        // Note: thread.name and hash map key point to the same memory.
        // We only free the key (which also frees thread.name).
        // active_thread_name also points to one of these keys.
        var thread_iter = self.threads.iterator();
        while (thread_iter.next()) |entry| {
            const thread = entry.value_ptr.*;
            const key = entry.key_ptr.*;

            // Unref head turn
            if (thread.head.unref()) {
                // Should not happen - ObjectStore owns turns
            }

            // Free thread struct (name points to key, freed below)
            self.allocator.destroy(thread);

            // Free hash map key (thread.name points to this)
            self.allocator.free(key);
        }

        self.threads.deinit(self.allocator);

        // Free object store (owns all messages and turns)
        self.object_store.deinit();
    }

    /// Get current active thread
    pub fn getActiveThread(self: *GitSession) ?*Thread {
        return self.threads.get(self.active_thread_name);
    }

    /// Get main thread
    pub fn getMainThread(self: *GitSession) ?*Thread {
        return self.threads.get(self.main_thread_name);
    }

    /// Fork current thread (create new branch from current head)
    pub fn fork(self: *GitSession, new_thread_name: []const u8) !*Thread {
        const active = self.getActiveThread() orelse return error.NoActiveThread;

        // Check if thread name already exists
        if (self.threads.get(new_thread_name)) |_| {
            return error.ThreadAlreadyExists;
        }

        // Allocate name once - shared by hash map key and thread.name
        const owned_name = try self.allocator.dupe(u8, new_thread_name);
        errdefer self.allocator.free(owned_name);

        const new_thread = try self.allocator.create(Thread);
        errdefer self.allocator.destroy(new_thread);

        new_thread.* = .{
            .name = owned_name, // Points to same memory as hash map key
            .head = active.head.ref(),
            .created_at = @intCast(@divTrunc(util.nanoTimestamp(), 1_000_000_000)),
        };

        try self.threads.putNoClobber(self.allocator, owned_name, new_thread);
        return new_thread;
    }

    /// Add a turn to a thread
    pub fn commit(
        self: *GitSession,
        thread_name: []const u8,
        messages: []const MessageRole,
        contents: []const []const u8,
        metadata: TurnMetadata,
    ) !*const Turn {
        const thread = self.threads.get(thread_name) orelse return error.ThreadNotFound;

        // Store all messages
        var msg_list: std.ArrayListUnmanaged(*const Message) = .{};
        defer msg_list.deinit(self.allocator);

        for (messages, contents) |role, content| {
            const msg = try self.object_store.storeMessage(role, content);
            try msg_list.append(self.allocator, msg);
        }

        // Create new turn with current head as parent
        var parent_buf: [1]*const Turn = .{thread.head};
        const new_turn = try self.object_store.storeTurn(
            msg_list.items,
            &parent_buf,
            metadata,
        );

        // Update thread head
        thread.updateHead(new_turn);

        return new_turn;
    }

    /// Commit to active thread
    pub fn commitActive(
        self: *GitSession,
        messages: []const MessageRole,
        contents: []const []const u8,
        metadata: TurnMetadata,
    ) !*const Turn {
        return self.commit(self.active_thread_name, messages, contents, metadata);
    }

    /// Switch to a thread
    pub fn checkout(self: *GitSession, thread_name: []const u8) !void {
        const thread = self.threads.get(thread_name) orelse return error.ThreadNotFound;
        // active_thread_name just points to the thread's name (which is the hash map key)
        // No allocation needed - just point to existing memory
        self.active_thread_name = thread.name;
    }

    /// Get history for a thread (from head to root)
    pub fn getHistory(
        self: *GitSession,
        thread_name: []const u8,
        allocator: Allocator,
    ) ![]const *const Turn {
        const thread = self.threads.get(thread_name) orelse return error.ThreadNotFound;

        var history: std.ArrayListUnmanaged(*const Turn) = .{};
        errdefer history.deinit(allocator);

        var current: *const Turn = thread.head;
        while (true) {
            try history.append(allocator, current);
            if (current.parents.len == 0) break;
            current = current.parents[0]; // Follow first parent
        }

        return history.toOwnedSlice(allocator);
    }

    /// Find common ancestor of two turns
    pub fn findCommonAncestor(
        self: *GitSession,
        turn_a: *const Turn,
        turn_b: *const Turn,
    ) ?*const Turn {
        // Collect ancestors of turn_a
        var ancestors_a: std.HashMapUnmanaged(Hash, void, struct {
            pub fn hash(_: @This(), h: Hash) u64 {
                return @as(u64, @bitCast(h[0..8].*));
            }
            pub fn eql(_: @This(), a: Hash, b: Hash) bool {
                return std.mem.eql(u8, &a, &b);
            }
        }, std.hash_map.default_max_load_percentage) = .{};
        defer ancestors_a.deinit(self.allocator);

        // BFS walk of turn_a's ancestors
        var queue_a: std.ArrayListUnmanaged(*const Turn) = .{};
        defer queue_a.deinit(self.allocator);

        queue_a.append(self.allocator, turn_a) catch return null;
        while (queue_a.items.len > 0) {
            const current = queue_a.orderedRemove(0);
            ancestors_a.putNoClobber(self.allocator, current.id, {}) catch return null;
            for (current.parents) |parent| {
                queue_a.append(self.allocator, parent) catch return null;
            }
        }

        // BFS walk of turn_b's ancestors, looking for match
        var queue_b: std.ArrayListUnmanaged(*const Turn) = .{};
        defer queue_b.deinit(self.allocator);

        queue_b.append(self.allocator, turn_b) catch return null;
        while (queue_b.items.len > 0) {
            const current = queue_b.orderedRemove(0);
            if (ancestors_a.contains(current.id)) {
                return current;
            }
            for (current.parents) |parent| {
                queue_b.append(self.allocator, parent) catch return null;
            }
        }

        return null;
    }

    /// Merge a thread into main thread
    pub fn merge(self: *GitSession, source_thread_name: []const u8) !MergeResult {
        const source = self.threads.get(source_thread_name) orelse return error.ThreadNotFound;
        const main = self.getMainThread() orelse return error.NoMainThread;

        // Find common ancestor
        const ancestor = self.findCommonAncestor(main.head, source.head);

        // Collect turns from source branch (after ancestor)
        var source_turns: std.ArrayListUnmanaged(*const Turn) = .{};
        defer source_turns.deinit(self.allocator);

        var current: *const Turn = source.head;
        while (true) {
            if (ancestor) |a| {
                if (std.mem.eql(u8, &current.id, &a.id)) break;
            }
            source_turns.append(self.allocator, current) catch return error.OutOfMemory;
            if (current.parents.len == 0) break;
            current = current.parents[0];
        }

        // Reverse to get chronological order
        std.mem.reverse(*const Turn, source_turns.items);

        // Collect messages from source branch
        var all_messages: std.ArrayListUnmanaged(*const Message) = .{};
        defer all_messages.deinit(self.allocator);

        for (source_turns.items) |turn| {
            for (turn.messages) |msg| {
                all_messages.append(self.allocator, msg) catch return error.OutOfMemory;
            }
        }

        // Create merge commit with both parents
        var merge_parents: [2]*const Turn = .{ main.head, source.head };
        const merge_turn = try self.object_store.storeTurn(
            all_messages.items,
            &merge_parents,
            .{ .model_name = "merge", .provider = "system" },
        );

        // Update main thread head
        main.updateHead(merge_turn);

        // Clean up merged thread
        if (self.threads.fetchRemove(source_thread_name)) |entry| {
            self.allocator.destroy(entry.value);
            self.allocator.free(entry.key);
        }

        return .{
            .success = true,
            .conflicts = &.{},
            .merged_turn = merge_turn,
        };
    }

    /// Delete a thread (does not delete turns)
    pub fn deleteThread(self: *GitSession, thread_name: []const u8) !void {
        if (std.mem.eql(u8, thread_name, self.main_thread_name)) {
            return error.CannotDeleteMainThread;
        }
        if (std.mem.eql(u8, thread_name, self.active_thread_name)) {
            return error.CannotDeleteActiveThread;
        }

        if (self.threads.fetchRemove(thread_name)) |entry| {
            self.allocator.destroy(entry.value);
            self.allocator.free(entry.key);
        }
    }

    /// List all thread names (returns owned copies)
    pub fn listThreads(
        self: *GitSession,
        allocator: Allocator,
    ) ![]const []const u8 {
        var names: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (names.items) |name| {
                allocator.free(name);
            }
            names.deinit(allocator);
        }

        // Pre-allocate space
        try names.ensureTotalCapacity(allocator, self.threads.count());

        // Use iterator to get thread names
        var iter = self.threads.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            // Duplicate for caller ownership
            const duped = try allocator.dupe(u8, key);
            names.appendAssumeCapacity(duped);
        }

        return names.toOwnedSlice(allocator);
    }

    /// Get turn count in active thread
    pub fn turnCount(self: *GitSession) usize {
        const thread = self.getActiveThread() orelse return 0;
        var count: usize = 0;
        var current: *const Turn = thread.head;
        while (true) {
            count += 1;
            if (current.parents.len == 0) break;
            current = current.parents[0];
        }
        return count;
    }

    /// Compact history (like Git GC - removes old turns)
    /// Keeps the last N turns
    pub fn compact(self: *GitSession, keep_last: usize) !void {
        const thread = self.getActiveThread() orelse return;

        if (keep_last == 0) return;

        // Walk back to find the turn to keep
        var current: *const Turn = thread.head;
        var count: usize = 0;
        while (count < keep_last and current.parents.len > 0) {
            current = current.parents[0];
            count += 1;
        }

        // Create a new root at this point
        // (In a full implementation, we'd also clean up orphaned turns from ObjectStore)
        // For now, just update the chain
        // TODO: Use current to create new root and garbage collect old turns
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "ObjectStore stores messages deduplicated" {
    const testing = std.testing;
    var store = ObjectStore.init(testing.allocator);
    defer store.deinit();

    const msg1 = try store.storeMessage(.user, "Hello");
    const msg2 = try store.storeMessage(.user, "Hello");

    try testing.expectEqual(msg1, msg2); // Same hash = same pointer
}

test "GitSession init and deinit" {
    const testing = std.testing;
    var session = try GitSession.init(testing.allocator);
    defer session.deinit();

    // Check initial state
    try testing.expectEqual(@as(usize, 1), session.threads.count());
}

test "GitSession fork and deinit" {
    const testing = std.testing;
    var session = try GitSession.init(testing.allocator);

    // Create a fork
    const fork_thread = try session.fork("feature");
    try testing.expectEqualStrings("feature", fork_thread.name);

    // Check hash map has 2 entries
    try testing.expectEqual(@as(usize, 2), session.threads.count());

    // Deinit should not crash
    session.deinit();
}

test "GitSession commits and merges" {
    const testing = std.testing;
    var session = try GitSession.init(testing.allocator);
    defer session.deinit();

    // Commit to main
    _ = try session.commitActive(
        &.{ .user, .assistant },
        &.{ "Hello", "Hi there!" },
        .{},
    );

    try testing.expectEqual(@as(usize, 2), session.turnCount());

    // Fork and commit to feature
    _ = try session.fork("feature");
    try session.checkout("feature");

    _ = try session.commit(
        "feature",
        &.{.user},
        &.{"What is the weather?"},
        .{},
    );

    // Merge back to main
    const result = try session.merge("feature");
    try testing.expect(result.success);
    try testing.expect(result.merged_turn != null);
}

test "GitSession finds common ancestor" {
    const testing = std.testing;
    var session = try GitSession.init(testing.allocator);
    defer session.deinit();

    // Commit to main
    _ = try session.commitActive(&.{.user}, &.{"base"}, .{});

    // Fork
    _ = try session.fork("branch");

    // Commit to main
    try session.checkout("main");
    _ = try session.commitActive(&.{.user}, &.{"main commit"}, .{});

    // Commit to branch
    try session.checkout("branch");
    _ = try session.commit("branch", &.{.user}, &.{"branch commit"}, .{});

    // Find common ancestor
    const main_thread = session.getMainThread().?;
    const branch_thread = session.threads.get("branch").?;

    const ancestor = session.findCommonAncestor(main_thread.head, branch_thread.head);
    try testing.expect(ancestor != null);
}
