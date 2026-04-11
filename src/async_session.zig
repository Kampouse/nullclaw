//! AsyncSessionManager - Parallel session processing using Git-like architecture.
//!
//! This module integrates GitSessionManager with SessionManager to enable
//! parallel processing of messages for the same chat session.
//!
//! Architecture:
//! - GitSessionManager tracks conversation history with fork/merge semantics
//! - Each worker thread gets its own Agent clone with forked history
//! - "First-to-complete wins" conflict resolution for concurrent messages
//!
//! Flow:
//! 1. Message arrives → fork worker thread with cloned Agent
//! 2. Process message with forked Agent (no mutex during LLM call)
//! 3. Lock mutex, merge results back to main Agent
//! 4. Commit to GitSession, try merge (first-to-complete wins)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const util = @import("util.zig");
const session_git = @import("session_git.zig");
const GitSession = session_git.GitSession;
const GitSessionManager = session_git.GitSessionManager;
const Message = session_git.Message;
const MessageRole = session_git.MessageRole;
const TurnMetadata = session_git.TurnMetadata;
const MergeResult = session_git.MergeResult;
const session_mod = @import("session.zig");
const SessionManager = session_mod.SessionManager;
const Session = session_mod.Session;
const Agent = @import("agent/root.zig").Agent;
// OwnedMessage is Agent.OwnedMessage, used in tests below
const Config = @import("config.zig").Config;
const providers = @import("providers/root.zig");
const Provider = providers.Provider;
const Role = providers.Role;
const tools_mod = @import("tools/root.zig");
const Tool = tools_mod.Tool;
const memory_mod = @import("memory/root.zig");
const Memory = memory_mod.Memory;
const observability = @import("observability.zig");
const Observer = observability.Observer;
const SecurityPolicy = @import("security/policy.zig").SecurityPolicy;
const streaming = @import("streaming.zig");
const StreamSink = streaming.Sink;
const ConversationContext = @import("agent/prompt.zig").ConversationContext;
const HistoryEntry = session_git.HistoryEntry;
const log = std.log.scoped(.async_session);

// ═══════════════════════════════════════════════════════════════════════════
// Error Types
// ═══════════════════════════════════════════════════════════════════════════

pub const AsyncSessionError = error{
    /// Another worker finished first - message was discarded
    ConflictResolutionNeeded,
    /// Session not found for chat_id
    SessionNotFound,
    /// Failed to fork worker thread
    ForkFailed,
    /// Failed to merge worker results
    MergeFailed,
    /// Provider error during processing
    ProviderError,
    /// Out of memory
    OutOfMemory,
    /// Invalid state
    InvalidState,
    /// All providers failed
    AllProvidersFailed,
    /// Rate limited
    RateLimited,
    /// Context length exceeded
    ContextLengthExceeded,
    /// Provider does not support vision
    ProviderDoesNotSupportVision,
    /// No response content
    NoResponseContent,
};

// ═══════════════════════════════════════════════════════════════════════════
// AsyncSessionManager
// ═══════════════════════════════════════════════════════════════════════════

/// Manages sessions with parallel processing capability.
/// Uses GitSessionManager for history tracking and SessionManager for Agent management.
pub const AsyncSessionManager = struct {
    allocator: Allocator,
    io: Io,
    config: *const Config,
    provider: Provider,
    tools: []const Tool,
    mem: ?Memory,
    observer: Observer,
    policy: ?*const SecurityPolicy,

    /// Git-like session manager for history tracking
    git_manager: GitSessionManager,

    /// Traditional session manager for Agent management
    session_manager: SessionManager,

    /// Configuration for async processing
    max_concurrent_workers: usize = 4,

    pub fn init(
        allocator: Allocator,
        io: Io,
        config: *const Config,
        provider: Provider,
        tools: []const Tool,
        mem: ?Memory,
        observer_i: Observer,
        session_store: ?memory_mod.SessionStore,
        response_cache: ?*memory_mod.cache.ResponseCache,
    ) AsyncSessionManager {
        tools_mod.bindMemoryTools(tools, mem);

        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .provider = provider,
            .tools = tools,
            .mem = mem,
            .observer = observer_i,
            .policy = null,
            .git_manager = GitSessionManager.init(allocator),
            .session_manager = SessionManager.init(
                allocator,
                io,
                config,
                provider,
                tools,
                mem,
                observer_i,
                session_store,
                response_cache,
            ),
            .max_concurrent_workers = 4,
        };
    }

    pub fn deinit(self: *AsyncSessionManager) void {
        self.git_manager.deinit();
        self.session_manager.deinit();
    }

    /// Process a message asynchronously with parallel processing support.
    /// Uses fork/merge pattern to allow concurrent message processing.
    /// Returns the response or error.
    pub fn processMessageAsync(
        self: *AsyncSessionManager,
        session_key: []const u8,
        content: []const u8,
        conversation_context: ?ConversationContext,
        stream_sink: ?StreamSink,
    ) AsyncSessionError![]const u8 {
        // Generate unique worker ID
        const worker_id = GitSessionManager.generateWorkerId(self.allocator) catch return error.OutOfMemory;
        defer self.allocator.free(worker_id);

        // Fork a worker thread from current history
        const fork_result = self.git_manager.forkWorker(session_key, worker_id) catch {
            return error.ForkFailed;
        };
        defer self.allocator.free(fork_result.thread_name);

        // Get or create session
        const session = self.session_manager.getOrCreate(session_key) catch return error.SessionNotFound;

        // Sync history from GitSession to Agent (locks session mutex internally)
        self.syncHistoryToAgent(session, "main") catch {
            // If sync fails, continue with existing Agent history
        };

        // Process message with forked Agent for true parallel processing
        const result = self.processWithForkedAgent(
            session,
            content,
            conversation_context,
            stream_sink,
        ) catch |err| {
            return err;
        };

        // Commit new messages to GitSession worker thread
        // Content was already copied while holding mutex in processWithForkedAgent
        if (result.user_content != null and result.assistant_content != null) {
            // Expected: user message + assistant response
            var roles: [2]MessageRole = .{ .user, .assistant };
            var contents: [2][]const u8 = .{ result.user_content.?, result.assistant_content.? };

            _ = self.git_manager.commitToWorker(
                session_key,
                fork_result.thread_name,
                &roles,
                &contents,
                .{},
            ) catch return error.MergeFailed;

            // Free the copied content after commit
            self.allocator.free(result.user_content.?);
            self.allocator.free(result.assistant_content.?);
        }

        // Try to merge using "first-to-complete wins" strategy
        // On conflict, we still return the response - the user wants both answers
        const merge_result = self.git_manager.tryMergeWorkerIfFirst(
            session_key,
            fork_result.thread_name,
            fork_result.expected_main_head,
        ) catch |err| {
            if (err == error.StaleFork) {
                // Another worker finished first - history may be out of order
                // but we still return the response so the user gets both answers
                log.warn("Conflict detected for session={s} - returning response anyway", .{session_key});
                // Return the response directly - no need to duplicate again
                // (response is already allocated by processWithForkedAgent)
                return result.response;
            }
            log.err("Merge failed for session={s}: {}", .{ session_key, err });
            return error.MergeFailed;
        };

        log.debug("Merged worker results for session={s}", .{session_key});
        _ = merge_result;

        // Return the response directly - no need to duplicate again
        // (response is already allocated by processWithForkedAgent)
        return result.response;
    }

    /// Result of processing a message with a forked Agent.
    /// Contains the response and any new messages to commit to GitSession.
    const ForkedAgentResult = struct {
        response: []const u8,
        /// Copied content strings from new messages (owned by caller)
        user_content: ?[]const u8,
        assistant_content: ?[]const u8,
    };

    /// Create a true deep copy of a history ArrayList.
    /// Unlike ArrayList.clone() which only allocates a new items array,
    /// this also duplicates each message's content string.
    /// This is essential for thread safety: if another thread deallocates
    /// the original history during an LLM call, this deep copy remains valid.
    fn deepCloneHistory(
        source: std.ArrayListUnmanaged(Agent.OwnedMessage),
        allocator: std.mem.Allocator,
    ) !std.ArrayListUnmanaged(Agent.OwnedMessage) {
        var result = std.ArrayListUnmanaged(Agent.OwnedMessage).empty;
        errdefer {
            // Clean up on error
            for (result.items) |*msg| {
                msg.deinit(allocator);
            }
            result.deinit(allocator);
        }

        for (source.items) |msg| {
            const owned_content = try allocator.dupe(u8, msg.content);
            errdefer allocator.free(owned_content);
            try result.append(allocator, .{
                .role = msg.role,
                .content = owned_content,
            });
        }

        return result;
    }

    /// Process a message using a forked Agent with independent history.
    /// This allows true parallel processing - each worker has its own history clone.
    fn processWithForkedAgent(
        self: *AsyncSessionManager,
        session: *Session,
        content: []const u8,
        conversation_context: ?ConversationContext,
        stream_sink: ?StreamSink,
    ) AsyncSessionError!ForkedAgentResult {
        const allocator = self.allocator;

        // PHASE 1: Lock briefly to clone history and set up context
        log.debug("PHASE 1: Acquiring mutex for history clone", .{});
        session.mutex.lock(std.Options.debug_io) catch {
            log.err("Failed to acquire mutex for history clone", .{});
            return error.InvalidState;
        };
        log.debug("PHASE 1: Mutex acquired, original_history_len={}", .{session.agent.history.items.len});

        // Set conversation context for this turn
        session.agent.conversation_context = conversation_context;

        // Set stream callback if provided
        const prev_stream_callback = session.agent.stream_callback;
        const prev_stream_ctx = session.agent.stream_ctx;
        if (stream_sink) |sink| {
            _ = sink;
        }

        // Clone the Agent's history for this worker (forked history)
        // Each worker gets its own independent copy
        log.debug("PHASE 1: Cloning history (len={})", .{session.agent.history.items.len});
        var worker_history = session.agent.history.clone(allocator) catch {
            log.err("PHASE 1: Failed to clone history", .{});
            session.mutex.unlock(std.Options.debug_io);
            return error.OutOfMemory;
        };
        log.debug("PHASE 1: History cloned successfully (worker_history_len={})", .{worker_history.items.len});
        errdefer {
            for (worker_history.items) |*msg| {
                msg.deinit(allocator);
            }
            worker_history.deinit(allocator);
        }

        // Create a DEEP COPY of the original history before swapping
        // This is critical: a shallow copy would share the items pointer,
        // and if another worker calls syncHistoryToAgent during our LLM call,
        // it would deallocate the memory we still reference.
        var original_history = try deepCloneHistory(session.agent.history, session.agent.allocator);
        errdefer {
            // On error, clean up the deep copy
            for (original_history.items) |*msg| {
                msg.deinit(session.agent.allocator);
            }
            original_history.deinit(session.agent.allocator);
        }
        const original_len = original_history.items.len;

        // Swap in the forked history
        log.debug("PHASE 1: Swapping in forked history", .{});
        session.agent.history = worker_history;
        log.debug("PHASE 1: History swapped, original_history ptr={*}, worker_history ptr={*}", .{ original_history.items.ptr, worker_history.items.ptr });

        // Unlock before LLM call - this allows parallel processing
        log.debug("PHASE 1: Releasing mutex before LLM call", .{});
        session.mutex.unlock(std.Options.debug_io);

        // PHASE 2: Process message WITHOUT mutex (LLM call can be parallel)
        // Each worker has its own forked history, so no race condition
        log.debug("PHASE 2: Starting LLM call (history_len={})", .{worker_history.items.len});
        const result = session.agent.turn(content);
        log.debug("PHASE 2: LLM call completed, result={s}", .{if (result) |_| "success" else |err| @errorName(err)});

        // PHASE 3: Re-lock to merge results back
        log.debug("PHASE 3: Acquiring mutex for merge", .{});
        session.mutex.lock(std.Options.debug_io) catch {
            log.err("PHASE 3: Failed to acquire mutex for merge", .{});
            // On lock failure, clean up worker history
            for (session.agent.history.items) |*msg| {
                msg.deinit(allocator);
            }
            session.agent.history.deinit(allocator);
            // Transfer ownership of original_history back to agent
            session.agent.history = original_history;
            // Clear the errdefer since we've transferred ownership
            original_history = std.ArrayListUnmanaged(Agent.OwnedMessage).empty;
            return error.InvalidState;
        };
        log.debug("PHASE 3: Mutex acquired for merge", .{});

        if (result) |response| {
            log.debug("PHASE 3: Processing successful response (len={})", .{response.len});
            // Success - merge new messages back to main history
            // session.agent.history now contains the worker's processed history
            var processed_history = session.agent.history;
            const processed_len = processed_history.items.len;

            // The worker's history contains: [original messages...] + [new messages...]
            // New messages are those added after original_len
            const num_new = if (processed_len > original_len) processed_len - original_len else 0;
            log.debug("PHASE 3: processed_len={}, original_len={}, num_new={}", .{ processed_len, original_len, num_new });

            if (num_new > 0) {
                log.debug("PHASE 3: Merging {} new messages to original history", .{num_new});
                // Copy new messages from worker history to original history
                for (processed_history.items[original_len..], 0..) |msg, i| {
                    log.debug("PHASE 3: Merging message {}/{} (role={})", .{ i + 1, num_new, msg.role });
                    const owned_content = allocator.dupe(u8, msg.content) catch {
                        // Clean up worker history on error
                        for (processed_history.items) |*m| {
                            m.deinit(allocator);
                        }
                        processed_history.deinit(allocator);
                        // Transfer ownership of original_history back to agent
                        session.agent.history = original_history;
                        session.agent.conversation_context = null;
                        session.agent.stream_callback = prev_stream_callback;
                        session.agent.stream_ctx = prev_stream_ctx;
                        session.mutex.unlock(std.Options.debug_io);
                        // Prevent errdefer from deinitializing transferred memory
                        original_history = std.ArrayListUnmanaged(Agent.OwnedMessage).empty;
                        return error.OutOfMemory;
                    };
                    errdefer allocator.free(owned_content);
                    original_history.append(allocator, .{
                        .role = msg.role,
                        .content = owned_content,
                    }) catch {
                        allocator.free(owned_content);
                        for (processed_history.items) |*m| {
                            m.deinit(allocator);
                        }
                        processed_history.deinit(allocator);
                        // Transfer ownership of original_history back to agent
                        session.agent.history = original_history;
                        session.agent.conversation_context = null;
                        session.agent.stream_callback = prev_stream_callback;
                        session.agent.stream_ctx = prev_stream_ctx;
                        session.mutex.unlock(std.Options.debug_io);
                        // Prevent errdefer from deinitializing transferred memory
                        original_history = std.ArrayListUnmanaged(Agent.OwnedMessage).empty;
                        return error.OutOfMemory;
                    };
                }
            }

            log.debug("PHASE 3: Cleaning up worker history ({} items)", .{processed_history.items.len});
            // Clean up worker history
            for (processed_history.items) |*msg| {
                msg.deinit(allocator);
            }
            processed_history.deinit(allocator);
            log.debug("PHASE 3: Worker history cleaned up", .{});

            // Restore original history (now with new messages appended)
            log.debug("PHASE 3: Restoring original history (ptr={*})", .{original_history.items.ptr});
            session.agent.history = original_history;
            // Prevent errdefer from deinitializing transferred memory
            original_history = std.ArrayListUnmanaged(Agent.OwnedMessage).empty;
            session.agent.conversation_context = null;
            session.agent.stream_callback = prev_stream_callback;
            session.agent.stream_ctx = prev_stream_ctx;
            session.turn_count += 1;
            session.last_active = @intCast(@divFloor(util.nanoTimestamp(), 1_000_000_000));
            // Copy new messages content while mutex is still held
            // This prevents race condition with syncHistoryToAgent clearing history
            var user_content: ?[]const u8 = null;
            var assistant_content: ?[]const u8 = null;

            if (num_new >= 2) {
                // Get current history length after merge
                const current_len = session.agent.history.items.len;
                if (current_len >= 2) {
                    // Copy the last two messages (user + assistant)
                    user_content = allocator.dupe(u8, session.agent.history.items[current_len - 2].content) catch null;
                    assistant_content = allocator.dupe(u8, session.agent.history.items[current_len - 1].content) catch null;
                }
            }

            log.debug("PHASE 3: Releasing mutex after merge", .{});
            session.mutex.unlock(std.Options.debug_io);

            log.debug("Forked Agent processing complete (new_msgs={})", .{num_new});

            // Duplicate the response for the caller
            log.debug("PHASE 3: Duplicating response for caller", .{});
            const response_copy = allocator.dupe(u8, response) catch {
                log.err("PHASE 3: Failed to duplicate response", .{});
                // Free original response on error
                session.agent.allocator.free(response);
                // Free copied content on error
                if (user_content) |uc| allocator.free(uc);
                if (assistant_content) |ac| allocator.free(ac);
                return error.OutOfMemory;
            };

            // Free the original response (allocated by Agent.turn)
            session.agent.allocator.free(response);
            log.debug("PHASE 3: Response duplicated, returning (len={})", .{response_copy.len});

            return .{
                .response = response_copy,
                .user_content = user_content,
                .assistant_content = assistant_content,
            };
        } else |err| {
            log.err("PHASE 3: Agent turn failed with error: {}", .{err});
            // Error case - clean up worker history
            var processed_history = session.agent.history;
            log.debug("PHASE 3: Cleaning up worker history after error ({} items)", .{processed_history.items.len});
            for (processed_history.items) |*msg| {
                msg.deinit(allocator);
            }
            processed_history.deinit(allocator);

            // Restore original history
            session.agent.history = original_history;
            // Prevent errdefer from deinitializing transferred memory
            original_history = std.ArrayListUnmanaged(Agent.OwnedMessage).empty;
            session.agent.conversation_context = null;
            session.agent.stream_callback = prev_stream_callback;
            session.agent.stream_ctx = prev_stream_ctx;
            session.mutex.unlock(std.Options.debug_io);

            log.err("Agent turn failed in forked processing", .{});

            // Note: response is not valid in error case, nothing to free
            return error.ProviderError;
        }
    }

    /// Sync history from GitSession to Agent.
    /// This replaces the Agent's history with the GitSession's history.
    /// Thread-safe: locks session mutex to serialize writes to agent.history.
    fn syncHistoryToAgent(
        self: *AsyncSessionManager,
        session: *Session,
        thread_name: []const u8,
    ) !void {
        // Lock session mutex to serialize writes to agent.history
        // This prevents race condition with processWithForkedAgent which also writes to history
        session.mutex.lock(std.Options.debug_io) catch return error.InvalidState;
        defer session.mutex.unlock(std.Options.debug_io);

        // Get history from GitSession (already mutex-protected in GitSessionManager)
        const history = try self.git_manager.getHistory(
            session.session_key,
            thread_name,
            self.allocator,
        );
        defer {
            // Free all history content - now safe after fixing race condition in getHistory()
            for (history) |item| {
                self.allocator.free(item.content);
            }
            self.allocator.free(history);
        }

        // Clear Agent's current history (mutex already held)
        for (session.agent.history.items) |msg| {
            msg.deinit(session.agent.allocator);
        }
        session.agent.history.clearAndFree(session.agent.allocator);

        // Populate Agent's history with GitSession's history
        for (history) |item| {
            const role: Role = switch (item.role) {
                .user => .user,
                .assistant => .assistant,
                .tool => .tool,
                .system => .system,
            };
            const owned_content = try session.agent.allocator.dupe(u8, item.content);
            errdefer session.agent.allocator.free(owned_content);
            try session.agent.history.append(session.agent.allocator, .{
                .role = role,
                .content = owned_content,
            });
        }

        log.debug("Synced {} messages from GitSession to Agent for session={s}", .{ history.len, session.session_key });
    }

    /// Sync history from Agent to GitSession.
    /// This commits new messages from Agent to GitSession.
    fn syncHistoryFromAgent(
        self: *AsyncSessionManager,
        session_key: []const u8,
        thread_name: []const u8,
        agent: *Agent,
        history_len_before: usize,
    ) !void {
        // Extract new messages from Agent history
        const new_messages = agent.history.items[history_len_before..];

        if (new_messages.len == 0) return;

        // Convert to GitSession format
        var roles = try self.allocator.alloc(MessageRole, new_messages.len);
        defer self.allocator.free(roles);
        var contents = try self.allocator.alloc([]const u8, new_messages.len);
        defer self.allocator.free(contents);

        for (new_messages, 0..) |msg, i| {
            roles[i] = switch (msg.role) {
                .user => MessageRole.user,
                .assistant => MessageRole.assistant,
                .tool => MessageRole.tool,
                .system => MessageRole.system,
            };
            contents[i] = msg.content;
        }

        // Commit to GitSession
        _ = try self.git_manager.commitToWorker(session_key, thread_name, roles, contents, .{});
    }

    /// Get conversation history for a session.
    pub fn getHistory(
        self: *AsyncSessionManager,
        session_key: []const u8,
        allocator: Allocator,
    ) ![]HistoryEntry {
        return self.git_manager.getHistory(session_key, "main", allocator);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "AsyncSessionManager initializes correctly" {
    const testing = std.testing;

    var manager = AsyncSessionManager.init(
        testing.allocator,
        std.Options.debug_io,
        undefined,
        undefined,
        &.{},
        null,
        undefined,
        null,
        null,
    );
    defer manager.deinit();

    try testing.expect(manager.max_concurrent_workers == 4);
}

test "processWithForkedAgent clones history independently" {
    // This test verifies that each worker gets its own history clone
    // and that modifications don't affect other workers
    const testing = std.testing;

    // Create a mock session with a history
    var mock_history: std.ArrayListUnmanaged(Agent.OwnedMessage) = .empty;
    defer {
        for (mock_history.items) |*msg| {
            msg.deinit(testing.allocator);
        }
        mock_history.deinit(testing.allocator);
    }

    // Add a message to the history
    try mock_history.append(testing.allocator, .{
        .role = .user,
        .content = try testing.allocator.dupe(u8, "Hello"),
    });

    // Clone the history
    var cloned = try mock_history.clone(testing.allocator);
    defer {
        for (cloned.items) |*msg| {
            msg.deinit(testing.allocator);
        }
        cloned.deinit(testing.allocator);
    }

    // Verify they are independent
    try testing.expectEqual(@as(usize, 1), mock_history.items.len);
    try testing.expectEqual(@as(usize, 1), cloned.items.len);

    // Modify the clone
    try cloned.append(testing.allocator, .{
        .role = .assistant,
        .content = try testing.allocator.dupe(u8, "Hi there"),
    });

    // Original should be unchanged
    try testing.expectEqual(@as(usize, 1), mock_history.items.len);
    try testing.expectEqual(@as(usize, 2), cloned.items.len);
}
