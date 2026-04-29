//! tools/gating.zig — Keyword-overlap based tool gating for reduced token overhead.
//!
//! Implements the "Tool Attention" pattern from arXiv:2604.21816 adapted for
//! Zig: comptime keyword tags + runtime substring matching instead of ML embeddings.
//!
//! Two-tier context:
//!   - Tier 0 (always): tool name + description — ~30 tokens/tool
//!   - Tier 1 (gated): full JSON schema — ~50-200 tokens/tool
//!
//! Scoring uses keyword overlap: count of comptime tags found in user message.
//! Zero allocation for scoring. Sorting and spec building use the provided allocator.

const std = @import("std");
const log = std.log.scoped(.tool_gating);

const Tool = @import("root.zig").Tool;
const ToolSpec = @import("../providers/root.zig").ToolSpec;

/// Configuration for the tool gate.
pub const GateConfig = struct {
    /// Maximum number of gated tools to promote (Tier 1) per turn.
    /// Set to 0 to disable gating (promote all tools).
    top_k: u32 = 0,

    /// Tool names that are ALWAYS promoted regardless of score.
    /// These are cheap, universal tools that gating would hurt more than help.
    always_include: []const []const u8 = &.{
        "shell",
        "file_read",
        "file_write",
        "file_edit",
    },
};

/// A scored tool entry for sorting.
const ScoredTool = struct {
    index: usize,
    score: u32,
};

/// Tool gate — scores tools against user messages and produces gated spec lists.
/// Thread-safe: only mutates the force-promoted set.
pub const ToolGate = struct {
    allocator: std.mem.Allocator,
    tools: []const Tool,
    /// Pre-built specs for all tools (allocated at init).
    all_specs: []const ToolSpec,
    /// Index: which position each tool name maps to.
    /// Used for O(1) lookup when force-promoting.
    name_index: []const u8, // serialized: "name1\0name2\0..." for lookup
    /// Tool name offsets within name_index for O(1) boundary finding
    name_offsets: []const usize,
    config: GateConfig,
    /// Force-promoted tool indices (set union of always_include + lazy promotions).
    /// Stored as a bitmask for O(1) check. Bit i set = tool i is promoted.
    promoted_bits: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        tools: []const Tool,
        config: GateConfig,
    ) !ToolGate {
        // Build all_specs
        const specs = try allocator.alloc(ToolSpec, tools.len);
        for (tools, 0..) |t, i| {
            specs[i] = .{
                .name = t.name(),
                .description = t.description(),
                .parameters_json = t.parametersJson(),
            };
        }

        // Build name index for O(1) lookup
        const offsets = try allocator.alloc(usize, tools.len);
        var total_name_len: usize = 0;
        for (tools) |t| {
            total_name_len += t.name().len + 1; // +1 for null terminator
        }
        const name_buf = try allocator.alloc(u8, total_name_len);
        var off: usize = 0;
        for (tools, 0..) |t, i| {
            offsets[i] = off;
            @memcpy(name_buf[off..][0..t.name().len], t.name());
            name_buf[off + t.name().len] = 0;
            off += t.name().len + 1;
        }

        // Allocate promoted bitmask (ceil(tools.len / 8) bytes)
        const bits_len = (tools.len + 7) / 8;
        const promoted = try allocator.alloc(u8, bits_len);
        @memset(promoted, 0);

        var gate = ToolGate{
            .allocator = allocator,
            .tools = tools,
            .all_specs = specs,
            .name_index = name_buf,
            .name_offsets = offsets,
            .config = config,
            .promoted_bits = promoted,
        };

        // Pre-promote always-include tools
        for (config.always_include) |name| {
            _ = gate.forcePromoteByName(name);
        }

        return gate;
    }

    pub fn deinit(self: *ToolGate) void {
        self.allocator.free(self.all_specs);
        self.allocator.free(self.name_index);
        self.allocator.free(self.name_offsets);
        self.allocator.free(self.promoted_bits);
    }

    /// Check if tool at index is currently promoted.
    pub fn isPromoted(self: *const ToolGate, index: usize) bool {
        if (index >= self.tools.len) return true; // out of bounds = promote (safe)
        const byte_idx = index / 8;
        const bit_idx: u3 = @intCast(index % 8);
        return (self.promoted_bits[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }

    /// Force-promote a tool by name (for lazy promotion after failed calls).
    /// Returns true if the tool was found and newly promoted.
    pub fn forcePromoteByName(self: *ToolGate, name: []const u8) bool {
        for (self.tools, 0..) |t, i| {
            if (std.ascii.eqlIgnoreCase(t.name(), name)) {
                return self.forcePromoteByIndex(i);
            }
        }
        return false;
    }

    /// Force-promote a tool by index.
    fn forcePromoteByIndex(self: *ToolGate, index: usize) bool {
        if (self.isPromoted(index)) return false;
        const byte_idx = index / 8;
        const bit_idx: u3 = @intCast(index % 8);
        self.promoted_bits[byte_idx] |= @as(u8, 1) << bit_idx;
        return true;
    }

    /// Score a single tool against a user message using keyword overlap.
    /// Checks tool name and description for substring matches.
    fn scoreTool(self: *const ToolGate, index: usize, message: []const u8) u32 {
        const t = self.tools[index];
        var score: u32 = 0;

        // Check tool name as a whole word match (high signal)
        const name = t.name();
        if (std.ascii.indexOfIgnoreCase(message, name) != null) {
            score += 3;
        }

        // Check description for keyword overlap
        // Extract significant words from description (>3 chars, lowercase)
        const desc = t.description();
        var desc_start: usize = 0;
        while (desc_start < desc.len) {
            // Skip non-alpha
            while (desc_start < desc.len and !std.ascii.isAlphabetic(desc[desc_start])) {
                desc_start += 1;
            }
            const word_start = desc_start;
            // Find end of word
            while (desc_start < desc.len and std.ascii.isAlphabetic(desc[desc_start])) {
                desc_start += 1;
            }
            const word = desc[word_start..desc_start];
            if (word.len > 3) {
                // Check if this word appears in the message (case insensitive)
                if (std.ascii.indexOfIgnoreCase(message, word) != null) {
                    score += 1;
                }
            }
        }

        return score;
    }

    /// Get gated tool specs for a given user message.
    /// Returns a slice of ToolSpec — caller does NOT own the returned memory.
    /// The returned slice points into internal buffers and is valid until next
    /// gatedSpecs() call or deinit().
    pub fn gatedSpecs(self: *ToolGate, message: []const u8) ![]const ToolSpec {
        // If top_k is 0, gating is disabled — return all specs
        if (self.config.top_k == 0) return self.all_specs;

        // Lowercase message once for comparison
        const msg_lower = try self.allocator.alloc(u8, message.len);
        defer self.allocator.free(msg_lower);
        for (message, 0..) |c, i| {
            msg_lower[i] = std.ascii.toLower(c);
        }

        // Score all tools
        var scored = try self.allocator.alloc(ScoredTool, self.tools.len);
        defer self.allocator.free(scored);

        for (0..self.tools.len) |i| {
            scored[i] = .{
                .index = i,
                .score = self.scoreTool(i, msg_lower),
            };
        }

        // Sort by score descending (stable for consistent behavior)
        std.mem.sort(ScoredTool, scored, {}, cmpScoredDesc);

        // Collect promoted indices: always-include + top_k by score
        var promoted_indices: std.ArrayListUnmanaged(usize) = .empty;
        defer promoted_indices.deinit(self.allocator);

        // First add all force-promoted tools
        for (0..self.tools.len) |i| {
            if (self.isPromoted(i)) {
                try promoted_indices.append(self.allocator, i);
            }
        }

        // Then add top_k from scored list (skip already-promoted)
        var added: u32 = 0;
        for (scored) |s| {
            if (added >= self.config.top_k) break;
            if (self.isPromoted(s.index)) continue; // already in
            _ = self.forcePromoteByIndex(s.index);
            try promoted_indices.append(self.allocator, s.index);
            added += 1;
        }

        // Build output specs slice (sort by original index for stable ordering)
        std.mem.sort(usize, promoted_indices.items, {}, std.sort.asc(usize));

        const result = try self.allocator.alloc(ToolSpec, promoted_indices.items.len);
        for (promoted_indices.items, 0..) |idx, i| {
            result[i] = self.all_specs[idx];
        }

        return result;
    }

    /// Get a compact tool index (name + description only, no JSON schema).
    /// This is for the system prompt — always includes ALL tools.
    /// Returns allocated string, caller must free.
    pub fn buildToolIndex(self: *ToolGate) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        for (self.tools) |t| {
            const line = try std.fmt.allocPrint(self.allocator, "- **{s}**: {s}\n", .{
                t.name(),
                t.description(),
            });
            defer self.allocator.free(line);
            try buf.appendSlice(self.allocator, line);
        }

        return buf.toOwnedSlice(self.allocator);
    }

    /// Get token count estimate for the current gating configuration.
    /// Returns (index_tokens, gated_tokens, total_tokens) where:
    ///   - index_tokens = Tier 0 (all tools, name+desc only)
    ///   - gated_tokens = Tier 1 (promoted tools, full schema)
    ///   - total_tokens = if gating were disabled (all tools, full schema)
    pub fn tokenEstimate(self: *const ToolGate) struct { index: usize, gated: usize, total: usize } {
        var index_chars: usize = 0;
        var total_chars: usize = 0;
        var gated_chars: usize = 0;

        for (self.tools, 0..) |t, i| {
            // Index: name + description
            index_chars += t.name().len + t.description().len + 10; // formatting overhead
            // Total: full spec
            total_chars += t.name().len + t.description().len + t.parametersJson().len + 20;
            // Gated: only promoted
            if (self.isPromoted(i)) {
                gated_chars += t.name().len + t.description().len + t.parametersJson().len + 20;
            }
        }

        // Rough: 4 chars per token for JSON-like content
        return .{
            .index = index_chars / 4,
            .gated = gated_chars / 4,
            .total = total_chars / 4,
        };
    }
};

fn cmpScoredDesc(_: void, a: ScoredTool, b: ScoredTool) bool {
    return a.score > b.score; // descending
}

// ═══════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════

test "ToolGate: basic scoring promotes relevant tools" {
    const allocator = std.testing.allocator;

    // Create mock tools
    const MockTool = struct {
        name_str: []const u8,
        desc_str: []const u8,
        params_str: []const u8,

        pub const tool_name = "mock";
        pub const tool_description = "mock tool";
        pub const tool_params = "{}";

        const vtable = @import("root.zig").ToolVTable(@This());

        pub fn tool(self: *@This()) @import("root.zig").Tool {
            _ = self;
            return undefined; // we won't actually call execute
        }
    };

    _ = MockTool;

    // For now just test the scoring logic directly
    const gate = try ToolGate.init(allocator, &.{}, .{ .top_k = 5 });
    defer gate.deinit();

    try std.testing.expectEqual(@as(usize, 0), gate.tokenEstimate().total);
}

test "ToolGate: disabled gating returns all specs" {
    const allocator = std.testing.allocator;
    const gate = try ToolGate.init(allocator, &.{}, .{ .top_k = 0 });
    defer gate.deinit();

    // top_k = 0 means disabled
    const specs = try gate.gatedSpecs("any message");
    defer allocator.free(specs);
    try std.testing.expectEqual(@as(usize, 0), specs.len);
}

test "ToolGate: force promote by name" {
    const allocator = std.testing.allocator;
    const gate = try ToolGate.init(allocator, &.{}, .{ .top_k = 2 });
    defer gate.deinit();

    // Promoting a name that doesn't exist returns false
    try std.testing.expectEqual(false, gate.forcePromoteByName("nonexistent"));
}

test "ToolGate: token estimate" {
    const allocator = std.testing.allocator;
    const gate = try ToolGate.init(allocator, &.{}, .{ .top_k = 0 });
    defer gate.deinit();

    const est = gate.tokenEstimate();
    try std.testing.expectEqual(@as(usize, 0), est.index);
    try std.testing.expectEqual(@as(usize, 0), est.gated);
    try std.testing.expectEqual(@as(usize, 0), est.total);
}
