//! Provider integration for consolidation LLM callbacks.
//!
//! This module wraps the existing provider infrastructure (providers/helpers.zig)
//! to create LlmCallback functions for the consolidation engine.
//!
//! ## Usage
//!
//! ```zig
//! const providers = @import("../../providers.zig");
//! const consolidation_providers = @import("consolidation_providers.zig");
//!
//! var config = providers.Config.init(allocator);
//! consolidation_providers.setConfig(&config);
//! defer consolidation_providers.clearConfig();
//!
//! const callback = consolidation_providers.createCallback(allocator, &config);
//!
//! const consolidation_config = consolidation.ConsolidationConfig{
//!     .llm_callback = callback,
//! };
//! ```

const std = @import("std");
const helpers = @import("../../providers/helpers.zig");

// ── Thread-local State ────────────────────────────────────────────────

/// Opaque config pointer set via setConfig / createCallback.
threadlocal var config_ptr: ?*const anyopaque = null;

/// Completion function bound at setConfig / createCallback time.
/// Signature: fn(allocator, *config, system_prompt, user_prompt) -> response
threadlocal var complete_fn: ?*const fn (
    std.mem.Allocator,
    *const anyopaque,
    []const u8,
    []const u8,
) anyerror![]const u8 = null;

// ── Callback Factory ───────────────────────────────────────────────────

/// System prompt for pattern extraction during consolidation.
pub const CONSOLIDATION_SYSTEM_PROMPT: []const u8 =
    \\You are a conversation analyst specializing in behavioral pattern extraction.
    \\
    \\Your task is to analyze conversations and extract actionable patterns that
    ///indicate:
    \\- **Positive patterns**: Behaviors that should be reinforced (reward: +1.0)
    \\- **Negative patterns**: Behaviors that should be avoided (reward: -1.0)
    \\- **Improvement patterns**: Behaviors with specific suggestions (reward: 0.0)
    \\
    \\Format each pattern on a separate line:
    \\[positive] <description> (reward: 1.0, confidence: 0.0-1.0[, hint: "suggestion"])
    \\[negative] <description> (reward: -1.0, confidence: 0.0-1.0)
    \\[improvement] <description> (reward: 0.0, confidence: 0.0-1.0, hint: "specific suggestion")
    \\
    \\Example:
    \\[positive] User appreciated concise, direct answers (reward: 1.0, confidence: 0.9)
    \\[negative] Agent interrupted the user mid-sentence (reward: -1.0, confidence: 0.8)
    \\[improvement] Agent should verify information before responding (reward: 0.0, confidence: 0.7, hint: "Always check file contents when user asks about implementation details")
;

/// LLM callback function type (from consolidation.zig).
pub const LlmCallback = *const fn (allocator: std.mem.Allocator, prompt: []const u8) anyerror![]const u8;

/// Set the thread-local provider config for consolidation callbacks.
/// Must be called on each thread that will invoke the callback returned by
/// createCallback.  Pass null or call clearConfig to unset.
pub fn setConfig(cfg: anytype) void {
    const CfgType = @TypeOf(cfg);
    const CfgPtr = if (@typeInfo(CfgType) == .pointer)
        *const @typeInfo(CfgType).pointer.child
    else
        *const CfgType;

    config_ptr = @ptrCast(cfg);
    complete_fn = struct {
        fn invoke(
            allocator: std.mem.Allocator,
            ptr: *const anyopaque,
            system_prompt: []const u8,
            user_prompt: []const u8,
        ) anyerror![]const u8 {
            const typed: CfgPtr = @ptrCast(@alignCast(ptr));
            return helpers.completeWithSystem(allocator, typed, system_prompt, user_prompt);
        }
    }.invoke;
}

/// Clear the thread-local provider config.
pub fn clearConfig() void {
    config_ptr = null;
    complete_fn = null;
}

/// Create a consolidation LLM callback from a provider config.
/// Stores the config in a thread-local so the bare fn pointer can access it.
/// The caller must ensure setConfig (or createCallback) is called on the
/// same thread that invokes the returned callback.
pub fn createCallback(
    allocator: std.mem.Allocator,
    cfg: anytype,
) LlmCallback {
    _ = allocator;
    setConfig(cfg);

    return consolidationCallback;
}

/// The actual callback function pointer.  Reads config from thread-locals.
fn consolidationCallback(
    alloc: std.mem.Allocator,
    prompt: []const u8,
) anyerror![]const u8 {
    const ptr = config_ptr orelse return error.ConsolidationCallbackNotConfigured;
    const fn_ptr = complete_fn orelse return error.ConsolidationCallbackNotConfigured;
    return fn_ptr(alloc, ptr, CONSOLIDATION_SYSTEM_PROMPT, prompt);
}

// ── Mock Callback for Testing ─────────────────────────────────────────

/// Create a mock LLM callback for testing that returns canned responses.
pub fn createMockCallback(allocator: std.mem.Allocator, responses: []const []const u8) LlmCallback {
    const MockState = struct {
        allocator: std.mem.Allocator,
        responses: []const []const u8,
        index: usize = 0,

        fn callback(
            alloc: std.mem.Allocator,
            prompt: []const u8,
        ) anyerror![]const u8 {
            _ = prompt;
            _ = alloc;
            return error.MockCallbackRequiresState;
        }
    };

    // For testing, use the test mock from consolidation.zig
    const TestMock = struct {
        fn callback(
            alloc: std.mem.Allocator,
            prompt: []const u8,
        ) anyerror![]const u8 {
            _ = prompt;

            const response =
                \\[positive] User appreciated concise answers (reward: 1.0, confidence: 0.9)
                \\[negative] Agent forgot to check file before answering (reward: -1.0, confidence: 0.8)
                \\[improvement] Agent should ask clarifying questions when uncertain (reward: 0.0, confidence: 0.7, hint: "Ask 'What do you mean by X?' when uncertain")
            ;

            return alloc.dupe(u8, response);
        }
    };

    return TestMock.callback;
}

/// Create a mock callback that always returns empty response.
pub fn createEmptyMockCallback() LlmCallback {
    const EmptyMock = struct {
        fn callback(
            alloc: std.mem.Allocator,
            prompt: []const u8,
        ) anyerror![]const u8 {
            _ = prompt;
            return alloc.dupe(u8, "");
        }
    };

    return EmptyMock.callback;
}

/// Create a mock callback that returns an error.
pub fn createErrorMockCallback(comptime err: anyerror) LlmCallback {
    const ErrorMock = struct {
        fn callback(
            alloc: std.mem.Allocator,
            prompt: []const u8,
        ) anyerror![]const u8 {
            _ = alloc;
            _ = prompt;
            return err;
        }
    };

    return ErrorMock.callback;
}

// ── Tests ─────────────────────────────────────────────────────────────

test "createMockCallback returns valid response" {
    const callback = createMockCallback(std.testing.allocator, &.{});

    const response = try callback(std.testing.allocator, "test prompt");
    defer std.testing.allocator.free(response);

    try std.testing.expect(response.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, response, "[positive]") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "[negative]") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "[improvement]") != null);
}

test "createEmptyMockCallback returns empty response" {
    const callback = createEmptyMockCallback();

    const response = try callback(std.testing.allocator, "test prompt");
    defer std.testing.allocator.free(response);

    try std.testing.expectEqual(@as(usize, 0), response.len);
}

test "createErrorMockCallback returns error" {
    const callback = createErrorMockCallback(error.TestError);

    const result = callback(std.testing.allocator, "test prompt");
    try std.testing.expectError(error.TestError, result);
}

test "CONSOLIDATION_SYSTEM_PROMPT is not empty" {
    try std.testing.expect(CONSOLIDATION_SYSTEM_PROMPT.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, CONSOLIDATION_SYSTEM_PROMPT, "pattern extraction") != null);
}
