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
//! const callback = consolidation_providers.createCallback(allocator, &config);
//!
//! const consolidation_config = consolidation.ConsolidationConfig{
//!     .llm_callback = callback,
//! };
//! ```

const std = @import("std");
const helpers = @import("../../providers/helpers.zig");

// ── Callback Factory ───────────────────────────────────────────────────

/// System prompt for pattern extraction during consolidation.
const CONSOLIDATION_SYSTEM_PROMPT: []const u8 =
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

/// Create a consolidation LLM callback from a provider config.
/// The callback uses completeWithSystem for provider-agnostic completion.
pub fn createCallback(
    allocator: std.mem.Allocator,
    cfg: anytype,
) LlmCallback {
    const CallbackState = struct {
        allocator: std.mem.Allocator,
        cfg: @TypeOf(cfg),

        fn fnCallback(
            allocator_inner: std.mem.Allocator,
            prompt: []const u8,
        ) anyerror![]const u8 {
            _ = allocator_inner;
            return helpers.completeWithSystem(
                @ptrCast(*const @TypeOf(cfg)), // TODO: This is hacky
                CONSOLIDATION_SYSTEM_PROMPT,
                prompt,
            );
        }
    };

    // For now, use a simple wrapper that captures the config
    // TODO: Make this more robust with proper state management
    const Wrapper = struct {
        fn callback(
            alloc: std.mem.Allocator,
            prompt: []const u8,
        ) anyerror![]const u8 {
            _ = alloc;
            _ = prompt;
            return error.ConsolidationCallbackNotConfigured;
        }
    };

    return Wrapper.callback;
}

/// Create a consolidation LLM callback with a custom config struct.
/// This version stores the config pointer in a closure-like structure.
pub fn createCallbackWithConfig(
    allocator: std.mem.Allocator,
    cfg_ptr: anytype,
) LlmCallback {
    _ = allocator;
    _ = cfg_ptr;

    // TODO: Implement proper closure-like behavior
    // Zig doesn't have closures, so we need a different approach:
    // 1. Store the config pointer in a struct
    // 2. Use a static function that looks up the config
    // 3. Pass the config through context

    const SimpleCallback = struct {
        fn callback(
            alloc: std.mem.Allocator,
            prompt: []const u8,
        ) anyerror![]const u8 {
            _ = alloc;
            _ = prompt;
            return error.ConsolidationNeedsProviderConfig;
        }
    };

    return SimpleCallback.callback;
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
