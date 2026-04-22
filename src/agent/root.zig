//! Agent core — struct definition, turn loop, tool execution.
//!
//! Sub-modules: dispatcher.zig (tool call parsing), compaction.zig (history
//! compaction/trimming), cli.zig (CLI entry point + REPL), prompt.zig
//! (system prompt), memory_loader.zig (memory enrichment).

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.agent);
const slog = @import("../structured_log.zig");
const Config = @import("../config.zig").Config;
const config_types = @import("../config_types.zig");
const providers = @import("../providers/root.zig");
const Provider = providers.Provider;
const ChatMessage = providers.ChatMessage;
const ChatResponse = providers.ChatResponse;
const ToolSpec = providers.ToolSpec;
const tools_mod = @import("../tools/root.zig");
const Tool = tools_mod.Tool;
const memory_mod = @import("../memory/root.zig");
const Memory = memory_mod.Memory;
const capabilities_mod = @import("../capabilities.zig");
const multimodal = @import("../multimodal.zig");
const platform = @import("../platform.zig");
const observability = @import("../observability.zig");
const Observer = observability.Observer;
const ObserverEvent = observability.ObserverEvent;
const SecurityPolicy = @import("../security/policy.zig").SecurityPolicy;
const util = @import("../util.zig");

const cache = memory_mod.cache;
pub const dispatcher = @import("dispatcher.zig");
pub const compaction = @import("compaction.zig");
pub const context_tokens = @import("context_tokens.zig");
pub const max_tokens_resolver = @import("max_tokens.zig");
pub const prompt = @import("prompt.zig");
pub const memory_loader = @import("memory_loader.zig");
pub const commands = @import("commands.zig");
const ParsedToolCall = dispatcher.ParsedToolCall;
const ToolExecutionResult = dispatcher.ToolExecutionResult;

// ═══════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════

/// Maximum agentic tool-use iterations per user message.
const DEFAULT_MAX_TOOL_ITERATIONS: u32 = 25;

/// Maximum non-system messages before trimming.
const DEFAULT_MAX_HISTORY: u32 = 50;

// ═══════════════════════════════════════════════════════════════════════════
// Agent
// ═══════════════════════════════════════════════════════════════════════════

pub const Agent = struct {
    const VerboseLevel = enum {
        off,
        on,
        full,

        pub fn toSlice(self: VerboseLevel) []const u8 {
            return switch (self) {
                .off => "off",
                .on => "on",
                .full => "full",
            };
        }
    };

    const ReasoningMode = enum {
        off,
        on,
        stream,

        pub fn toSlice(self: ReasoningMode) []const u8 {
            return switch (self) {
                .off => "off",
                .on => "on",
                .stream => "stream",
            };
        }
    };

    const UsageMode = enum {
        off,
        tokens,
        full,
        cost,

        pub fn toSlice(self: UsageMode) []const u8 {
            return switch (self) {
                .off => "off",
                .tokens => "tokens",
                .full => "full",
                .cost => "cost",
            };
        }
    };

    const ExecHost = enum {
        sandbox,
        gateway,
        node,

        pub fn toSlice(self: ExecHost) []const u8 {
            return switch (self) {
                .sandbox => "sandbox",
                .gateway => "gateway",
                .node => "node",
            };
        }
    };

    const ExecSecurity = enum {
        deny,
        allowlist,
        full,

        pub fn toSlice(self: ExecSecurity) []const u8 {
            return switch (self) {
                .deny => "deny",
                .allowlist => "allowlist",
                .full => "full",
            };
        }
    };

    const ExecAsk = enum {
        off,
        on_miss,
        always,

        pub fn toSlice(self: ExecAsk) []const u8 {
            return switch (self) {
                .off => "off",
                .on_miss => "on-miss",
                .always => "always",
            };
        }
    };

    const QueueMode = enum {
        off,
        serial,
        latest,
        debounce,

        pub fn toSlice(self: QueueMode) []const u8 {
            return switch (self) {
                .off => "off",
                .serial => "serial",
                .latest => "latest",
                .debounce => "debounce",
            };
        }
    };

    const QueueDrop = enum {
        summarize,
        oldest,
        newest,

        pub fn toSlice(self: QueueDrop) []const u8 {
            return switch (self) {
                .summarize => "summarize",
                .oldest => "oldest",
                .newest => "newest",
            };
        }
    };

    const TtsMode = enum {
        off,
        always,
        inbound,
        tagged,

        pub fn toSlice(self: TtsMode) []const u8 {
            return switch (self) {
                .off => "off",
                .always => "always",
                .inbound => "inbound",
                .tagged => "tagged",
            };
        }
    };

    const ActivationMode = enum {
        mention,
        always,

        pub fn toSlice(self: ActivationMode) []const u8 {
            return switch (self) {
                .mention => "mention",
                .always => "always",
            };
        }
    };

    const SendMode = enum {
        on,
        off,
        inherit,

        pub fn toSlice(self: SendMode) []const u8 {
            return switch (self) {
                .on => "on",
                .off => "off",
                .inherit => "inherit",
            };
        }
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    provider: Provider,
    tools: []const Tool,
    tool_specs: []const ToolSpec,
    mem: ?Memory,
    session_store: ?memory_mod.SessionStore = null,
    response_cache: ?*cache.ResponseCache = null,
    /// Optional MemoryRuntime pointer for diagnostics (e.g. /doctor command).
    mem_rt: ?*memory_mod.MemoryRuntime = null,
    /// Optional session scope for memory read/write operations.
    memory_session_id: ?[]const u8 = null,
    observer: Observer,
    model_name: []const u8,
    model_name_owned: bool = false,
    default_provider: []const u8 = "openrouter",
    default_provider_owned: bool = false,
    default_model: []const u8 = "anthropic/claude-sonnet-4",
    configured_providers: []const config_types.ProviderEntry = &.{},
    fallback_providers: []const []const u8 = &.{},
    model_fallbacks: []const config_types.ModelFallbackEntry = &.{},
    temperature: f64,
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},
    max_tool_iterations: u32,
    max_history_messages: u32,
    auto_save: bool,
    token_limit: u64 = 0,
    token_limit_override: ?u64 = null,
    max_tokens: u32 = max_tokens_resolver.DEFAULT_MODEL_MAX_TOKENS,
    max_tokens_override: ?u32 = null,
    reasoning_effort: ?[]const u8 = null,
    verbose_level: VerboseLevel = .off,
    reasoning_mode: ReasoningMode = .off,
    usage_mode: UsageMode = .off,
    exec_host: ExecHost = .gateway,
    exec_security: ExecSecurity = .allowlist,
    exec_ask: ExecAsk = .on_miss,
    exec_node_id: ?[]const u8 = null,
    exec_node_id_owned: bool = false,
    queue_mode: QueueMode = .off,
    queue_debounce_ms: u32 = 0,
    queue_cap: u32 = 0,
    queue_drop: QueueDrop = .summarize,
    tts_mode: TtsMode = .off,
    tts_provider: ?[]const u8 = null,
    tts_provider_owned: bool = false,
    tts_limit_chars: u32 = 0,
    tts_summary: bool = false,
    tts_audio: bool = false,
    pending_exec_command: ?[]const u8 = null,
    pending_exec_command_owned: bool = false,
    pending_exec_id: u64 = 0,
    session_ttl_secs: ?u64 = null,
    focus_target: ?[]const u8 = null,
    focus_target_owned: bool = false,
    dock_target: ?[]const u8 = null,
    dock_target_owned: bool = false,
    activation_mode: ActivationMode = .mention,
    send_mode: SendMode = .inherit,
    last_turn_usage: providers.TokenUsage = .{},
    message_timeout_secs: u64 = 0,
    log_tool_calls: bool = false,
    log_llm_io: bool = false,
    /// Maximum number of tools to execute in parallel (0 = sequential, 1+ = parallel)
    max_parallel_tools: u32 = 0,
    compaction_keep_recent: u32 = compaction.DEFAULT_COMPACTION_KEEP_RECENT,
    compaction_max_summary_chars: u32 = compaction.DEFAULT_COMPACTION_MAX_SUMMARY_CHARS,
    compaction_max_source_chars: u32 = compaction.DEFAULT_COMPACTION_MAX_SOURCE_CHARS,

    /// Optional security policy for autonomy checks and rate limiting.
    policy: ?*const SecurityPolicy = null,

    /// Optional streaming callback. When set, turn() uses streamChat() for streaming providers.
    stream_callback: ?providers.StreamCallback = null,
    /// Context pointer passed to stream_callback.
    stream_ctx: ?*anyopaque = null,
    /// Conversation context for the current turn (Signal-specific for now).
    conversation_context: ?prompt.ConversationContext = null,

    /// Conversation history — owned, growable list.
    history: std.ArrayListUnmanaged(OwnedMessage) = .empty,

    /// Total tokens used across all turns.
    total_tokens: u64 = 0,

    /// Whether the system prompt has been injected.
    has_system_prompt: bool = false,
    /// Whether the currently injected system prompt contains conversation context.
    system_prompt_has_conversation_context: bool = false,
    /// Fingerprint of workspace prompt files for the currently injected system prompt.
    workspace_prompt_fingerprint: ?u64 = null,

    /// Whether compaction was performed during the last turn.
    last_turn_compacted: bool = false,

    /// Whether context was force-compacted due to exhaustion during the current turn.
    context_was_compacted: bool = false,

    // ── Performance caches (FIX 13, 19, 20, 21) ──

    /// Cached capabilities section to avoid 15 allocations per system prompt rebuild.
    cached_capabilities_section: ?[]u8 = null,
    /// Whether the capabilities cache needs to be rebuilt.
    capabilities_dirty: bool = true,

    /// Pre-computed FNV1a-64 hash of the system prompt for cache key partial hashing.
    cached_sys_prompt_hash: u64 = 0,

    /// Whether the allowed-dirs list for buildProviderMessages has been built.
    cached_allowed_dirs_built: bool = false,
    /// Cached allowed-dirs slice (arena-allocated, valid until arena reset).
    cached_allowed_dirs: []const []const u8 = &.{},

    /// Running character count across all history messages for fast tokenEstimate.
    total_history_chars: u64 = 0,

    /// Pending vector sync keys for deferred processing after LLM call.
    /// Stores (key, content) pairs to sync after the response is ready.
    pending_sync_keys: [4]?PendingSyncEntry = [_]?PendingSyncEntry{null} ** 4,
    pending_sync_count: usize = 0,

    /// Entry for deferred vector sync queue.
    pub const PendingSyncEntry = struct {
        key: []const u8,
        content: []const u8,
    };

    /// An owned copy of a ChatMessage, where content is heap-allocated.
    pub const OwnedMessage = struct {
        role: providers.Role,
        content: []const u8,

        pub fn deinit(self: *const OwnedMessage, allocator: std.mem.Allocator) void {
            allocator.free(self.content);
        }

        fn toChatMessage(self: *const OwnedMessage) ChatMessage {
            return .{ .role = self.role, .content = self.content };
        }
    };

    /// Initialize agent from a loaded Config.
    pub fn fromConfig(
        allocator: std.mem.Allocator,
        cfg: *const Config,
        provider_i: Provider,
        tools: []const Tool,
        mem: ?Memory,
        observer_i: Observer,
        io: std.Io,
    ) !Agent {
        const default_model = cfg.default_model orelse return error.NoDefaultModel;
        const token_limit_override = if (cfg.agent.token_limit_explicit) cfg.agent.token_limit else null;
        const resolved_token_limit = context_tokens.resolveContextTokens(token_limit_override, default_model);
        const resolved_max_tokens_raw = max_tokens_resolver.resolveMaxTokens(cfg.max_tokens, default_model);
        const token_limit_cap: u32 = @intCast(@min(resolved_token_limit, @as(u64, std.math.maxInt(u32))));
        const resolved_max_tokens = @min(resolved_max_tokens_raw, token_limit_cap);

        // Build tool specs for function-calling APIs
        const specs = try allocator.alloc(ToolSpec, tools.len);
        for (tools, 0..) |t, i| {
            specs[i] = .{
                .name = t.name(),
                .description = t.description(),
                .parameters_json = t.parametersJson(),
            };
        }

        return .{
            .allocator = allocator,
            .io = io,
            .provider = provider_i,
            .tools = tools,
            .tool_specs = specs,
            .mem = mem,
            .observer = observer_i,
            .model_name = default_model,
            .default_provider = cfg.default_provider,
            .default_model = default_model,
            .configured_providers = cfg.providers,
            .fallback_providers = cfg.reliability.fallback_providers,
            .model_fallbacks = cfg.reliability.model_fallbacks,
            .temperature = cfg.default_temperature,
            .workspace_dir = cfg.workspace_dir,
            .allowed_paths = cfg.autonomy.allowed_paths,
            .max_tool_iterations = cfg.agent.max_tool_iterations,
            .max_history_messages = cfg.agent.max_history_messages,
            .auto_save = cfg.memory.auto_save,
            .token_limit = resolved_token_limit,
            .token_limit_override = token_limit_override,
            .max_tokens = resolved_max_tokens,
            .max_tokens_override = cfg.max_tokens,
            .reasoning_effort = cfg.reasoning_effort,
            .message_timeout_secs = cfg.agent.message_timeout_secs,
            .log_tool_calls = cfg.diagnostics.log_tool_calls,
            .log_llm_io = cfg.diagnostics.log_llm_io,
            .max_parallel_tools = cfg.diagnostics.max_parallel_tools,
            .compaction_keep_recent = cfg.agent.compaction_keep_recent,
            .compaction_max_summary_chars = cfg.agent.compaction_max_summary_chars,
            .compaction_max_source_chars = cfg.agent.compaction_max_source_chars,
            .history = .empty,
            .total_tokens = 0,
            .has_system_prompt = false,
            .last_turn_compacted = false,
        };
    }

    pub fn deinit(self: *Agent) void {
        if (self.model_name_owned) self.allocator.free(self.model_name);
        if (self.default_provider_owned) self.allocator.free(self.default_provider);
        if (self.exec_node_id_owned and self.exec_node_id != null) self.allocator.free(self.exec_node_id.?);
        if (self.tts_provider_owned and self.tts_provider != null) self.allocator.free(self.tts_provider.?);
        if (self.pending_exec_command_owned and self.pending_exec_command != null) self.allocator.free(self.pending_exec_command.?);
        if (self.focus_target_owned and self.focus_target != null) self.allocator.free(self.focus_target.?);
        if (self.dock_target_owned and self.dock_target != null) self.allocator.free(self.dock_target.?);
        if (self.cached_capabilities_section) |section| self.allocator.free(section);
        if (self.cached_allowed_dirs.len > 0) {
            // On macOS, entries starting with "/private/" were allocated via
            // allocPrint in appendMultimodalAllowedDir and must be freed individually.
            if (comptime @import("builtin").os.tag == .macos) {
                for (self.cached_allowed_dirs) |dir| {
                    if (std.mem.startsWith(u8, dir, "/private/")) {
                        self.allocator.free(dir);
                    }
                }
            }
            self.allocator.free(self.cached_allowed_dirs);
        }
        for (self.history.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.history.deinit(self.allocator);
        self.allocator.free(self.tool_specs);
    }

    /// Estimate total tokens in conversation history.
    /// FIX 21: Uses running character counter instead of scanning all messages.
    pub fn tokenEstimate(self: *const Agent) u64 {
        return compaction.tokenEstimateFromTotal(self.total_history_chars);
    }

    /// FIX 19: Compute cache key using pre-hashed system prompt + user message.
    /// Avoids re-hashing the entire system prompt every turn.
    pub fn computeCacheKeyHex(self: *const Agent, buf: *[16]u8, user_message: []const u8) []const u8 {
        // Hash the user message
        var user_hasher = std.hash.Fnv1a_64.init();
        user_hasher.update(std.mem.asBytes(&@as(u32, @intCast(user_message.len))));
        user_hasher.update(user_message);
        const user_hash = user_hasher.final();

        // XOR with cached system prompt hash for final key
        const final_hash = self.cached_sys_prompt_hash ^ user_hash;
        return std.fmt.bufPrint(buf, "{x:0>16}", .{final_hash}) catch "0000000000000000";
    }

    /// FIX 19: Compute FNV1a-64 hash of the system prompt.
    fn hashSystemPrompt(sys_prompt: []const u8) u64 {
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(std.mem.asBytes(&@as(u32, @intCast(sys_prompt.len))));
        hasher.update(sys_prompt);
        return hasher.final();
    }

    /// Auto-compact history when it exceeds thresholds.
    pub fn autoCompactHistory(self: *Agent) !bool {
        const result = try compaction.autoCompactHistory(self.allocator, &self.history, self.provider, self.model_name, .{
            .keep_recent = self.compaction_keep_recent,
            .max_summary_chars = self.compaction_max_summary_chars,
            .max_source_chars = self.compaction_max_source_chars,
            .token_limit = self.token_limit,
            .max_history_messages = self.max_history_messages,
            .workspace_dir = self.workspace_dir,
        });
        if (result) {
            // FIX 21: Recalculate total_history_chars after compaction
            self.total_history_chars = self.recalculateHistoryChars();
        }
        return result;
    }

    /// Force-compress history for context exhaustion recovery.
    pub fn forceCompressHistory(self: *Agent) bool {
        const result = compaction.forceCompressHistory(self.allocator, &self.history);
        if (result) {
            // FIX 21: Recalculate total_history_chars after compression
            self.total_history_chars = self.recalculateHistoryChars();
        }
        return result;
    }

    /// FIX 21: Recalculate total_history_chars from current history.
    fn recalculateHistoryChars(self: *const Agent) u64 {
        var total: u64 = 0;
        for (self.history.items) |*msg| {
            total += msg.content.len;
        }
        return total;
    }

    fn appendUniqueString(
        list: *std.ArrayListUnmanaged([]const u8),
        allocator: std.mem.Allocator,
        value: []const u8,
    ) !void {
        if (value.len == 0) return;
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, value)) return;
        }
        try list.append(allocator, value);
    }

    /// FIX 21: Append message to history and update running char counter.
    fn appendToHistory(self: *Agent, role: providers.Role, content: []const u8) !void {
        try self.history.append(self.allocator, .{ .role = role, .content = content });
        self.total_history_chars += content.len;
    }

    fn providerIsFallback(self: *const Agent, provider_name: []const u8) bool {
        for (self.fallback_providers) |fallback_name| {
            if (std.mem.eql(u8, fallback_name, provider_name)) return true;
        }
        return false;
    }

    fn providerAuthStatus(self: *const Agent, provider_name: []const u8) []const u8 {
        if (providers.classifyProvider(provider_name) == .openai_codex_provider) {
            return "oauth";
        }

        const resolved_key = providers.resolveApiKeyFromConfig(
            self.allocator,
            provider_name,
            self.configured_providers,
        ) catch null;
        defer if (resolved_key) |key| self.allocator.free(key);

        if (resolved_key) |key| {
            if (std.mem.trim(u8, key, " \t\r\n").len > 0) return "configured";
        }
        return "missing";
    }

    fn currentModelFallbacks(self: *const Agent) ?[]const []const u8 {
        for (self.model_fallbacks) |entry| {
            if (std.mem.eql(u8, entry.model, self.model_name)) return entry.fallbacks;
        }
        return null;
    }

    fn composeFinalReply(self: *const Agent, base_text: []const u8, reasoning_content: ?[]const u8, usage: providers.TokenUsage) ![]const u8 {
        return commands.composeFinalReply(self, base_text, reasoning_content, usage);
    }

    fn shouldForceActionFollowThrough(text: []const u8) bool {
        const ascii_patterns = [_][]const u8{
            "i'll try",
            "i will try",
            "let me try",
            "i'll check",
            "i will check",
            "let me check",
            "i'll retry",
            "i will retry",
            "let me retry",
            "i'll attempt",
            "i will attempt",
            "i'll do that now",
            "i will do that now",
            "doing that now",
        };
        inline for (ascii_patterns) |pattern| {
            if (containsAsciiIgnoreCase(text, pattern)) return true;
        }

        const exact_patterns = [_][]const u8{
            "сейчас попробую",
            "Сейчас попробую",
            "попробую снова",
            "Попробую снова",
            "сейчас проверю",
            "Сейчас проверю",
            "сейчас сделаю",
            "Сейчас сделаю",
            "попробую переснять",
            "Попробую переснять",
            "сейчас перепроверю",
            "Сейчас перепроверю",
            "попробую ещё раз",
            "Попробую ещё раз",
        };
        inline for (exact_patterns) |pattern| {
            if (std.mem.indexOf(u8, text, pattern) != null) return true;
        }
        return false;
    }

    fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0 or haystack.len < needle.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var matched = true;
            var j: usize = 0;
            while (j < needle.len) : (j += 1) {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }

    fn isExecToolName(tool_name: []const u8) bool {
        return commands.isExecToolName(tool_name);
    }

    fn execBlockMessage(self: *Agent, args: std.json.ObjectMap) ?[]const u8 {
        return commands.execBlockMessage(self, args);
    }

    pub fn formatModelStatus(self: *const Agent) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        const allocator = self.allocator;

        try out.appendSlice(allocator, "Current model: ");
        try out.appendSlice(allocator, self.model_name);
        try out.appendSlice(allocator, "\n");
        try out.appendSlice(allocator, "Default model: ");
        try out.appendSlice(allocator, self.default_model);
        try out.appendSlice(allocator, "\n");
        try out.appendSlice(allocator, "Default provider: ");
        try out.appendSlice(allocator, self.default_provider);
        try out.appendSlice(allocator, "\n");

        var provider_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer provider_names.deinit(self.allocator);
        try appendUniqueString(&provider_names, self.allocator, self.default_provider);
        for (self.configured_providers) |entry| {
            try appendUniqueString(&provider_names, self.allocator, entry.name);
        }
        for (self.fallback_providers) |fallback_name| {
            try appendUniqueString(&provider_names, self.allocator, fallback_name);
        }

        if (provider_names.items.len > 0) {
            try out.appendSlice(allocator, "\nProviders:\n");
            for (provider_names.items) |provider_name| {
                const is_default = std.mem.eql(u8, provider_name, self.default_provider);
                const is_fallback = self.providerIsFallback(provider_name);
                const role_label = if (is_default and is_fallback)
                    " [default,fallback]"
                else if (is_default)
                    " [default]"
                else if (is_fallback)
                    " [fallback]"
                else
                    "";
                try out.appendSlice(allocator, "  - ");
                try out.appendSlice(allocator, provider_name);
                try out.appendSlice(allocator, role_label);
                try out.appendSlice(allocator, " (auth: ");
                try out.appendSlice(allocator, self.providerAuthStatus(provider_name));
                try out.appendSlice(allocator, ")\n");
            }
        }

        var model_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer model_names.deinit(self.allocator);
        try appendUniqueString(&model_names, self.allocator, self.model_name);
        try appendUniqueString(&model_names, self.allocator, self.default_model);
        for (self.model_fallbacks) |entry| {
            try appendUniqueString(&model_names, self.allocator, entry.model);
            for (entry.fallbacks) |fallback_model| {
                try appendUniqueString(&model_names, self.allocator, fallback_model);
            }
        }

        if (model_names.items.len > 0) {
            try out.appendSlice(allocator, "\nModels:\n");
            for (model_names.items) |model_name| {
                const is_current = std.mem.eql(u8, model_name, self.model_name);
                const is_default = std.mem.eql(u8, model_name, self.default_model);
                const role_label = if (is_current and is_default)
                    " [current,default]"
                else if (is_current)
                    " [current]"
                else if (is_default)
                    " [default]"
                else
                    "";
                try out.appendSlice(allocator, "  - ");
                try out.appendSlice(allocator, model_name);
                try out.appendSlice(allocator, role_label);
                try out.appendSlice(allocator, "\n");
            }
        }

        try out.appendSlice(allocator, "\nProvider chain: ");
        try out.appendSlice(allocator, self.default_provider);
        if (self.fallback_providers.len == 0) {
            try out.appendSlice(allocator, " (no fallback providers)");
        } else {
            for (self.fallback_providers) |fallback_provider| {
                try out.appendSlice(allocator, " -> ");
                try out.appendSlice(allocator, fallback_provider);
            }
        }

        try out.appendSlice(allocator, "\nModel chain: ");
        try out.appendSlice(allocator, self.model_name);
        if (self.currentModelFallbacks()) |fallbacks| {
            for (fallbacks) |fallback_model| {
                try out.appendSlice(allocator, " -> ");
                try out.appendSlice(allocator, fallback_model);
            }
        } else {
            try out.appendSlice(allocator, " (no configured fallbacks)");
        }

        try out.appendSlice(allocator, "\nSwitch: /model <name>");
        return try out.toOwnedSlice(self.allocator);
    }

    /// Handle slash commands that don't require LLM.
    /// Returns an owned response string, or null if not a slash command.
    pub fn handleSlashCommand(self: *Agent, message: []const u8) !?[]const u8 {
        return commands.handleSlashCommand(self, message);
    }

    /// Execute a single conversation turn: send messages to LLM, parse tool calls,
    /// execute tools, and loop until a final text response is produced.
    pub fn turn(self: *Agent, user_message: []const u8) ![]const u8 {
        // Set trace ID for this turn (appears in all slog lines)
        const tid = slog.generateTraceId();
        slog.setTraceId(&tid);
        defer slog.clearTraceId();

        const turn_start_ns = util.nanoTimestamp();
        slog.logStructured("DEBUG", "agent", "turn_start", .{});
        self.context_was_compacted = false;
        commands.refreshSubagentToolContext(self);

        const effective_user_message = blk: {
            if (commands.bareSessionResetPrompt(user_message)) |fresh_prompt| {
                // Preserve slash side-effects (/new|/reset session clear), but route bare command
                // through a fresh-session prompt instead of returning command text.
                if (try self.handleSlashCommand(user_message)) |slash_response| {
                    self.allocator.free(slash_response);
                }
                break :blk fresh_prompt;
            }

            // Handle regular slash commands before sending to LLM (saves tokens).
            if (try self.handleSlashCommand(user_message)) |response| {
                return response;
            }
            break :blk user_message;
        };

        // Flush any leftover deferred vector syncs from previous turn
        const flush_ns = util.nanoTimestamp();
        self.flushPendingSyncs();
        slog.debugSpan("agent", "flush_syncs", flush_ns);

        // Inject system prompt on first turn (or when tracked workspace files changed).
        const sysprompt_ns = util.nanoTimestamp();
        const workspace_fp: ?u64 = prompt.workspacePromptFingerprint(self.allocator, self.workspace_dir) catch null;
        if (self.has_system_prompt and workspace_fp != null and self.workspace_prompt_fingerprint != workspace_fp) {
            self.has_system_prompt = false;
        }

        const turn_has_conversation_context = self.conversation_context != null;
        const conversation_context_changed = self.has_system_prompt and
            self.system_prompt_has_conversation_context != turn_has_conversation_context;

        if (!self.has_system_prompt or conversation_context_changed) {
            // FIX 13: Use cached capabilities section when available and not dirty
            const capabilities_section: ?[]const u8 = if (!self.capabilities_dirty and self.cached_capabilities_section != null)
                self.cached_capabilities_section.?
            else blk: {
                var cfg_for_caps_opt: ?Config = Config.load(self.allocator, std.Options.debug_io) catch null;
                defer if (cfg_for_caps_opt) |*cfg_loaded| cfg_loaded.deinit();
                const cfg_for_caps_ptr: ?*const Config = if (cfg_for_caps_opt) |*cfg_loaded| cfg_loaded else null;

                const section = capabilities_mod.buildPromptSection(
                    self.allocator,
                    cfg_for_caps_ptr,
                    self.tools,
                ) catch null;
                if (section) |sec| {
                    // Update cache
                    if (self.cached_capabilities_section) |old| self.allocator.free(old);
                    self.cached_capabilities_section = sec;
                    self.capabilities_dirty = false;
                    break :blk sec;
                }
                break :blk null;
            };

            const system_prompt = try prompt.buildSystemPrompt(self.allocator, .{
                .workspace_dir = self.workspace_dir,
                .model_name = self.model_name,
                .tools = self.tools,
                .capabilities_section = capabilities_section,
                .conversation_context = self.conversation_context,
            });
            defer self.allocator.free(system_prompt);

            // Append tool instructions
            const tool_instructions = try dispatcher.buildToolInstructions(self.allocator, self.tools);
            defer self.allocator.free(tool_instructions);

            const full_system = try self.allocator.alloc(u8, system_prompt.len + tool_instructions.len);
            @memcpy(full_system[0..system_prompt.len], system_prompt);
            @memcpy(full_system[system_prompt.len..], tool_instructions);

            // Keep exactly one canonical system prompt at history[0].
            // This allows /model to invalidate and refresh the prompt in place.
            if (self.history.items.len > 0 and self.history.items[0].role == .system) {
                self.total_history_chars -= self.history.items[0].content.len;
                self.history.items[0].deinit(self.allocator);
                self.history.items[0] = .{
                    .role = .system,
                    .content = full_system,
                };
                self.total_history_chars += full_system.len;
            } else if (self.history.items.len > 0) {
                try self.history.insert(self.allocator, 0, .{
                    .role = .system,
                    .content = full_system,
                });
                self.total_history_chars += full_system.len;
            } else {
                try self.history.append(self.allocator, .{
                    .role = .system,
                    .content = full_system,
                });
                self.total_history_chars += full_system.len;
            }
            self.has_system_prompt = true;
            self.system_prompt_has_conversation_context = turn_has_conversation_context;
            self.workspace_prompt_fingerprint = workspace_fp;

            // FIX 19: Pre-compute system prompt hash for fast cache key computation
            self.cached_sys_prompt_hash = hashSystemPrompt(full_system);

            slog.logStructured("DEBUG", "agent", "system_prompt_size", .{
                .chars = full_system.len,
            });
        }
        slog.debugSpan("agent", "system_prompt", sysprompt_ns);

        // Enrich message with memory context (always returns owned slice; ownership → history)
        // Uses retrieval pipeline (hybrid search, RRF, temporal decay, MMR) when MemoryRuntime is available.
        const retrieval_ns = util.nanoTimestamp();
        const enriched = if (self.mem) |mem|
            try memory_loader.enrichMessageWithRuntime(self.allocator, mem, self.mem_rt, effective_user_message, self.memory_session_id)
        else
            try self.allocator.dupe(u8, effective_user_message);
        errdefer self.allocator.free(enriched);
        slog.debugSpan("agent", "retrieval", retrieval_ns);

        // FIX 15: Auto-save user message to memory AFTER retrieval to avoid
        // FTS5 trigger updates contending with the subsequent FTS5 read.
        const autosave_ns = util.nanoTimestamp();
        if (self.auto_save) {
            if (self.mem) |mem| {
                const ts: u128 = 0;
                const save_key = std.fmt.allocPrint(self.allocator, "autosave_user_{d}", .{ts}) catch null;
                if (save_key) |key| {
                    defer self.allocator.free(key);
                    if (mem.store(key, effective_user_message, .conversation, self.memory_session_id)) |_| {
                        // Defer vector sync to after LLM response (avoids blocking the call)
                        if (self.mem_rt) |_| {
                            self.queueVectorSync(key, effective_user_message);
                        }
                    } else |_| {}
                }
            }
        }
        slog.debugSpan("agent", "auto_save", autosave_ns);

        try self.appendToHistory(.user, enriched);

        // ── Response cache check (FIX 19: uses pre-hashed system prompt) ──
        if (self.response_cache) |rc| {
            var key_buf: [16]u8 = undefined;
            const key_hex = self.computeCacheKeyHex(&key_buf, effective_user_message);
            if (rc.get(self.allocator, key_hex) catch null) |cached_response| {
                errdefer self.allocator.free(cached_response);
                const history_copy = try self.allocator.dupe(u8, cached_response);
                errdefer self.allocator.free(history_copy);
                try self.appendToHistory(.assistant, history_copy);
                slog.debug("agent", "turn_cache_hit", .{});
                return cached_response;
            }
        }

        slog.debug("agent", "turn_no_cache_proceeding", .{});
        slog.debugSpan("agent", "pre_call", turn_start_ns);

        // Tool call loop — reuse a single arena across iterations (retains pages)
        var iter_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer iter_arena.deinit();

        var iteration: u32 = 0;
        var forced_follow_through_count: u32 = 0;
        while (iteration < self.max_tool_iterations) : (iteration += 1) {
            slog.debug("agent", "turn_loop_start", .{ .iteration = iteration + 1, .max_iterations = self.max_tool_iterations });
            _ = iter_arena.reset(.retain_capacity);
            const arena = iter_arena.allocator();

            // Build messages slice for provider (arena-owned; freed at end of iteration)
            const messages = try self.buildProviderMessages(arena);

            // Record llm_request with message content snapshot for spy dashboard
            const msg_snapshot = self.snapshotMessages(arena, messages);
            const req_event = ObserverEvent{ .llm_request = .{
                .provider = self.provider.getName(),
                .model = self.model_name,
                .messages_count = messages.len,
                .messages_snapshot = msg_snapshot,
            } };
            self.observer.recordEvent(&req_event);

            const timer_start = util.timestampUnix();
            const is_streaming = self.stream_callback != null and self.provider.supportsStreaming();
            const native_tools_enabled = !is_streaming and self.provider.supportsNativeTools();

            // Call provider: streaming (no retries, no native tools) or blocking with retry
            var response: ChatResponse = undefined;
            var response_attempt: u32 = 1;
            slog.debug("agent", "turn_calling_provider", .{ .iteration = iteration + 1, .streaming = is_streaming, .native_tools = native_tools_enabled });
            const llm_ns = util.nanoTimestamp();
            if (is_streaming) {
                slog.logStructured("DEBUG", "agent", "llm_call_start", .{});
                self.logLlmRequest(iteration + 1, 1, messages, native_tools_enabled, true);
                const stream_result = self.provider.streamChat(
                    self.allocator,
                    .{
                        .messages = messages,
                        .model = self.model_name,
                        .temperature = self.temperature,
                        .max_tokens = self.max_tokens,
                        .tools = null,
                        .timeout_secs = self.message_timeout_secs,
                        .reasoning_effort = self.reasoning_effort,
                    },
                    self.model_name,
                    self.temperature,
                    self.stream_callback.?,
                    self.stream_ctx.?,
                ) catch |err| {
                    slog.logStructured("ERROR", "agent", "llm_error", .{ .err_msg = @errorName(err) });
                    const fail_duration: u64 = @as(u64, @intCast(@max(0, util.timestampUnix() - timer_start)));
                    const fail_event = ObserverEvent{ .llm_response = .{
                        .provider = self.provider.getName(),
                        .model = self.model_name,
                        .duration_ms = fail_duration,
                        .success = false,
                        .error_message = @errorName(err),
                    } };
                    self.observer.recordEvent(&fail_event);
                    return err;
                };
                slog.logStructured("DEBUG", "agent", "llm_success", .{});
                slog.debugSpan("agent", "llm_call", llm_ns);
                response = ChatResponse{
                    .content = stream_result.content,
                    .tool_calls = &.{},
                    .usage = stream_result.usage,
                    .model = stream_result.model,
                };
                slog.debug("agent", "turn_streaming_response_constructed", .{});
                slog.debug("agent", "turn_llm_call_complete", .{ .iteration = iteration + 1, .content_len = if (response.content) |c| c.len else 0 });
            } else {
                self.logLlmRequest(iteration + 1, 1, messages, native_tools_enabled, false);
                response = self.provider.chat(
                    self.allocator,
                    .{
                        .messages = messages,
                        .model = self.model_name,
                        .temperature = self.temperature,
                        .max_tokens = self.max_tokens,
                        .tools = if (native_tools_enabled) self.tool_specs else null,
                        .timeout_secs = self.message_timeout_secs,
                        .reasoning_effort = self.reasoning_effort,
                    },
                    self.model_name,
                    self.temperature,
                ) catch |err| retry_blk: {
                    // Record the failed attempt
                    const fail_duration: u64 = @as(u64, @intCast(@max(0, util.timestampUnix() - timer_start)));
                    const fail_event = ObserverEvent{ .llm_response = .{
                        .provider = self.provider.getName(),
                        .model = self.model_name,
                        .duration_ms = fail_duration,
                        .success = false,
                        .error_message = @errorName(err),
                    } };
                    self.observer.recordEvent(&fail_event);

                    // Context exhaustion: compact immediately before first retry
                    const err_name = @errorName(err);
                    if (providers.reliable.isContextExhausted(err_name) and
                        self.history.items.len > compaction.CONTEXT_RECOVERY_MIN_HISTORY and
                        self.forceCompressHistory())
                    {
                        self.context_was_compacted = true;
                        const recovery_msgs = self.buildProviderMessages(arena) catch |prep_err| return prep_err;
                        response_attempt = 2;
                        self.logLlmRequest(iteration + 1, 2, recovery_msgs, native_tools_enabled, false);
                        break :retry_blk self.provider.chat(
                            self.allocator,
                            .{
                                .messages = recovery_msgs,
                                .model = self.model_name,
                                .temperature = self.temperature,
                                .max_tokens = self.max_tokens,
                                .tools = if (native_tools_enabled) self.tool_specs else null,
                                .timeout_secs = self.message_timeout_secs,
                                .reasoning_effort = self.reasoning_effort,
                            },
                            self.model_name,
                            self.temperature,
                        ) catch return err;
                    }

                    // Retry once
                    util.sleep(500 * std.time.ns_per_ms);
                    response_attempt = 2;
                    self.logLlmRequest(iteration + 1, 2, messages, native_tools_enabled, false);
                    break :retry_blk self.provider.chat(
                        self.allocator,
                        .{
                            .messages = messages,
                            .model = self.model_name,
                            .temperature = self.temperature,
                            .max_tokens = self.max_tokens,
                            .tools = if (native_tools_enabled) self.tool_specs else null,
                            .timeout_secs = self.message_timeout_secs,
                            .reasoning_effort = self.reasoning_effort,
                        },
                        self.model_name,
                        self.temperature,
                    ) catch |retry_err| {
                        // Context exhaustion recovery: if we have enough history,
                        // force-compress and retry once more
                        if (self.history.items.len > compaction.CONTEXT_RECOVERY_MIN_HISTORY and self.forceCompressHistory()) {
                            self.context_was_compacted = true;
                            const recovery_msgs = self.buildProviderMessages(arena) catch |prep_err| return prep_err;
                            response_attempt = 3;
                            self.logLlmRequest(iteration + 1, 3, recovery_msgs, native_tools_enabled, false);
                            break :retry_blk self.provider.chat(
                                self.allocator,
                                .{
                                    .messages = recovery_msgs,
                                    .model = self.model_name,
                                    .temperature = self.temperature,
                                    .max_tokens = self.max_tokens,
                                    .tools = if (native_tools_enabled) self.tool_specs else null,
                                    .timeout_secs = self.message_timeout_secs,
                                    .reasoning_effort = self.reasoning_effort,
                                },
                                self.model_name,
                                self.temperature,
                            ) catch return retry_err;
                        }
                        return retry_err;
                    };
                };
            }
            slog.debug("agent", "turn_before_log_llm_response", .{});
            self.logLlmResponse(iteration + 1, response_attempt, &response);
            slog.debug("agent", "turn_after_log_llm_response", .{});

            const duration_ms: u64 = @as(u64, @intCast(@max(0, util.timestampUnix() - timer_start)));

            // Build response preview + tool calls JSON for spy dashboard
            const resp_text = response.contentOrEmpty();
            const resp_preview = if (resp_text.len > 0) resp_text[0..@min(resp_text.len, 2048)] else "";
            const tools_json = self.snapshotToolCalls(arena, response.tool_calls);

            const resp_event = ObserverEvent{ .llm_response = .{
                .provider = self.provider.getName(),
                .model = self.model_name,
                .duration_ms = duration_ms,
                .success = true,
                .error_message = null,
                .response_preview = resp_preview,
                .tool_calls_json = tools_json,
            } };
            self.observer.recordEvent(&resp_event);

            // Track tokens
            self.total_tokens += response.usage.total_tokens;
            self.last_turn_usage = response.usage;

            slog.logStructured("DEBUG", "agent", "token_usage", .{
                .prompt_tokens = response.usage.prompt_tokens,
                .completion_tokens = response.usage.completion_tokens,
                .total_tokens = response.usage.total_tokens,
            });

            const response_text = response.contentOrEmpty();
            const use_native = response.hasToolCalls();

            // Determine tool calls: structured (native) first, then XML fallback.
            // Keep the same loop semantics used by the reference runtime.
            var parsed_calls: []ParsedToolCall = &.{};
            var parsed_text: []const u8 = "";
            var assistant_history_content: []const u8 = "";

            // Track what we need to free
            var free_parsed_calls = false;
            var free_parsed_text = false;
            var free_assistant_history = false;

            defer {
                if (free_parsed_calls) {
                    for (parsed_calls) |call| {
                        self.allocator.free(call.name);
                        self.allocator.free(call.arguments_json);
                        if (call.tool_call_id) |id| self.allocator.free(id);
                    }
                    self.allocator.free(parsed_calls);
                }
                if (free_parsed_text and parsed_text.len > 0) self.allocator.free(parsed_text);
                if (free_assistant_history and assistant_history_content.len > 0) self.allocator.free(assistant_history_content);
            }

            slog.debug("agent", "turn_parsing_tool_calls", .{ .use_native = use_native });

            if (use_native) {
                // Provider returned structured tool_calls — convert them
                parsed_calls = try dispatcher.parseStructuredToolCalls(self.allocator, response.tool_calls);
                free_parsed_calls = true;
                slog.debug("agent", "turn_parsed_structured_tool_calls", .{ .count = parsed_calls.len });

                if (parsed_calls.len == 0) {
                    // Structured calls were empty (e.g. all had empty names) — try XML fallback
                    self.allocator.free(parsed_calls);
                    free_parsed_calls = false;

                    const xml_parsed = try dispatcher.parseToolCalls(self.allocator, response_text);
                    parsed_calls = xml_parsed.calls;
                    free_parsed_calls = true;
                    parsed_text = xml_parsed.text;
                    free_parsed_text = true;
                }

                // Build history content with serialized tool calls
                assistant_history_content = try dispatcher.buildAssistantHistoryWithToolCalls(
                    self.allocator,
                    response_text,
                    parsed_calls,
                );
                free_assistant_history = true;
                slog.debug("agent", "turn_built_assistant_history_with_tool_calls", .{});
            } else {
                // No native tool calls — parse response text for XML tool calls
                const xml_parsed = try dispatcher.parseToolCalls(self.allocator, response_text);
                parsed_calls = xml_parsed.calls;
                free_parsed_calls = true;
                parsed_text = xml_parsed.text;
                free_parsed_text = true;
                // For XML path, store the raw response text as history
                assistant_history_content = response_text;
                slog.debug("agent", "turn_parsed_xml_tool_calls", .{ .count = parsed_calls.len });
            }

            slog.debug("agent", "turn_total_parsed_calls", .{ .count = parsed_calls.len });

            // Determine display text
            // IMPORTANT: When there are tool calls, NEVER show raw response_text to user
            // Only show parsed_text (which has tool calls removed) or nothing
            const display_text = if (parsed_text.len > 0) parsed_text else "";

            if (parsed_calls.len == 0) {
                // Guardrail: if the model promises "I'll try/check now" but emits no
                // tool call, force one follow-up completion to either act now or
                // explicitly state the limitation without deferred promises.
                if (!is_streaming and
                    forced_follow_through_count < 2 and
                    iteration + 1 < self.max_tool_iterations and
                    shouldForceActionFollowThrough(display_text))
                {
                    try self.appendToHistory(.assistant, try self.allocator.dupe(u8, display_text));
                    try self.appendToHistory(.user, try self.allocator.dupe(u8, "SYSTEM: You just promised to take action now (for example: \"I'll try/check now\"). " ++
                        "Do it in this turn by issuing the appropriate tool call(s). " ++
                        "If no tool can perform it, respond with a clear limitation now and do not promise another future attempt."));
                    self.trimHistory();
                    self.freeResponseFields(&response);
                    forced_follow_through_count += 1;
                    continue;
                }

                // No tool calls — final response
                const base_text = if (self.context_was_compacted) blk: {
                    self.context_was_compacted = false;
                    break :blk try std.fmt.allocPrint(self.allocator, "[Context compacted]\n\n{s}", .{display_text});
                } else try self.allocator.dupe(u8, display_text);
                errdefer self.allocator.free(base_text);

                const final_text = try self.composeFinalReply(base_text, response.reasoning_content, response.usage);
                errdefer self.allocator.free(final_text);

                // Dupe from display_text directly (not from final_text) to avoid double-dupe
                try self.appendToHistory(.assistant, try self.allocator.dupe(u8, display_text));

                // Auto-compaction before hard trimming to preserve context
                self.last_turn_compacted = self.autoCompactHistory() catch false;
                self.trimHistory();

                // Auto-save assistant response
                if (self.auto_save) {
                    if (self.mem) |mem| {
                        // Truncate to ~100 bytes on a valid UTF-8 boundary
                        const summary = if (base_text.len > 100) blk: {
                            var end: usize = 100;
                            while (end > 0 and base_text[end] & 0xC0 == 0x80) end -= 1;
                            break :blk base_text[0..end];
                        } else base_text;
                        const ts: u128 = 0;
                        const save_key = std.fmt.allocPrint(self.allocator, "autosave_assistant_{d}", .{ts}) catch null;
                        if (save_key) |key| {
                            defer self.allocator.free(key);
                            if (mem.store(key, summary, .conversation, self.memory_session_id)) |_| {
                                // Defer vector sync to after LLM response
                                if (self.mem_rt) |_| {
                                    self.queueVectorSync(key, summary);
                                }
                            } else |_| {}
                        }
                    }
                }

                // Flush deferred vector syncs (runs after response is ready)
                self.flushPendingSyncs();

                // Drain durable outbox after turn completion (best-effort)
                if (self.mem_rt) |rt| {
                    _ = rt.drainOutbox(self.allocator);
                }

                const complete_event = ObserverEvent{ .turn_complete = {} };
                self.observer.recordEvent(&complete_event);

                // Free provider response fields (content, tool_calls, model)
                // All borrows have been duped into final_text and history at this point.
                self.freeResponseFields(&response);
                self.allocator.free(base_text);

                // ── Cache store (only for direct responses, no tool calls) (FIX 19) ──
                if (self.response_cache) |rc| {
                    var store_key_buf: [16]u8 = undefined;
                    const store_key_hex = self.computeCacheKeyHex(&store_key_buf, effective_user_message);
                    const token_count: u32 = @intCast(@min(self.last_turn_usage.total_tokens, std.math.maxInt(u32)));
                    rc.put(self.allocator, store_key_hex, self.model_name, final_text, token_count) catch {};
                }

                return final_text;
            }

            // There are tool calls — execute tools, then return final answer.
            // DO NOT show any intermediary text to the user (including tool calls)
            // The user should only see the final response AFTER tools have executed.
            // In tests, avoid corrupting the test runner protocol.
            if (false) { // Disabled - no intermediary text shown to users
                // Only show a brief "thinking" indicator, not the full text
                // The actual text content will be incorporated into the final response
                var out_buf: [256]u8 = undefined;
                var bw = std.Io.File.stdout().writer(std.Options.debug_io, &out_buf);
                const w = &bw.interface;
                const plural = if (parsed_calls.len == 1) "" else "s";
                w.print("⚙️ Using {d} tool{s}...\n", .{ parsed_calls.len, plural }) catch {};
                w.flush() catch {};
            }

            slog.debug("agent", "turn_appending_assistant_message", .{});

            // Record assistant message with tool calls in history.
            // Native path (free_assistant_history=true): transfer ownership directly to avoid
            // a redundant allocation; clear the flag so the outer defer does not double-free.
            // XML path (free_assistant_history=false): response_text is not owned, must dupe.
            const assistant_content: []const u8 = if (free_assistant_history) blk: {
                free_assistant_history = false;
                break :blk assistant_history_content;
            } else try self.allocator.dupe(u8, assistant_history_content);
            errdefer self.allocator.free(assistant_content);

            try self.appendToHistory(.assistant, assistant_content);

            slog.debug("agent", "turn_history_append_complete", .{});

            // Execute each tool call
            const tools_ns = util.nanoTimestamp();
            var results_buf: std.ArrayListUnmanaged(ToolExecutionResult) = .empty;
            defer results_buf.deinit(self.allocator);
            try results_buf.ensureTotalCapacity(self.allocator, parsed_calls.len);
            const batch_updates_tools_md = tool_call_batch_updates_tools_md(arena, parsed_calls);

            const session_hash: u64 = if (self.memory_session_id) |sid| std.hash.Wyhash.hash(0, sid) else 0;
            if (self.log_tool_calls) {
                log.info("tool-call batch session=0x{x} count={d}", .{ session_hash, parsed_calls.len });
            }

            slog.debug("agent", "turn_entering_tool_execution_loop", .{ .parsed_calls_count = parsed_calls.len });

            // Parallel tool execution is safe: RateTracker uses an internal spinlock,
            // tools iteration is over a const slice, std.Io is passed by value,
            // and the observer already has its own mutex.
            const use_parallel = parsed_calls.len > 1;

            if (use_parallel) {
                // Parallel execution for multiple tools
                slog.debug("agent", "turn_using_parallel_tool_execution", .{ .count = parsed_calls.len });
                const parallel_results = try self.executeToolsParallel(arena, parsed_calls, batch_updates_tools_md);

                // Copy results to results_buf
                for (parallel_results) |result| {
                    try results_buf.append(self.allocator, result);
                }
            } else {
                // Sequential execution (single tool or parallel disabled)
                slog.debug("agent", "turn_using_sequential_tool_execution", .{ .count = parsed_calls.len });
                for (parsed_calls, 0..) |call, idx| {
                    slog.logStructured("DEBUG", "agent", "tool_iteration", .{ .index = idx, .tool = call.name });

                    if (self.log_tool_calls) {
                        log.info(
                            "tool-call start session=0x{x} index={d} name={s} id={s}",
                            .{ session_hash, idx + 1, call.name, call.tool_call_id orelse "-" },
                        );
                    }

                    slog.debug("agent", "turn_recording_tool_call_start_event", .{});
                    const tool_start_event = ObserverEvent{ .tool_call_start = .{ .tool = call.name } };
                    self.observer.recordEvent(&tool_start_event);

                    const tool_timer = util.timestampUnix();

                    const result = if (should_skip_tools_memory_store_duplicate(arena, batch_updates_tools_md, call)) blk: {
                        break :blk ToolExecutionResult{
                            .name = call.name,
                            .output = "Skipped duplicate memory_store: TOOLS.md was updated in the same tool batch",
                            .success = true,
                            .tool_call_id = call.tool_call_id,
                        };
                    } else blk: {
                        break :blk self.executeTool(arena, call);
                    };
                    const tool_duration: u64 = @as(u64, @intCast(@max(0, util.timestampUnix() - tool_timer)));

                    if (self.log_tool_calls) {
                        log.info(
                            "tool-call done session=0x{x} index={d} name={s} success={} duration_ms={d}",
                            .{ session_hash, idx + 1, call.name, result.success, tool_duration },
                        );
                    }

                    const tool_event = ObserverEvent{ .tool_call = .{
                        .tool = call.name,
                        .duration_ms = tool_duration,
                        .success = result.success,
                        .detail = result.output,
                    } };
                    self.observer.recordEvent(&tool_event);

                    try results_buf.append(self.allocator, result);
                }
            }

            slog.debugSpan("agent", "tool_execution", tools_ns);

            // Format tool results, scrub credentials, add reflection prompt, and add to history
            slog.debug("agent", "turn_formatting_tool_results", .{ .count = results_buf.items.len });
            const formatted_results = try dispatcher.formatToolResults(arena, results_buf.items);
            slog.debug("agent", "turn_tool_results_formatted", .{ .len = formatted_results.len });

            const scrubbed_results = try providers.scrubToolOutput(arena, formatted_results);
            slog.debug("agent", "turn_tool_results_scrubbed", .{ .len = scrubbed_results.len });

            const with_reflection = try std.fmt.allocPrint(
                arena,
                "{s}\n\nReflect on the tool results above and decide your next steps. " ++
                    "If a tool failed due to policy/permissions, do not repeat the same blocked call; explain the limitation and choose a different available tool or ask the user for permission/config change. " ++
                    "If a tool failed due to a transient issue (timeout/network/rate-limit), proactively retry up to 2 times with adjusted parameters before giving up.",
                .{scrubbed_results},
            );
            slog.debug("agent", "turn_reflection_prompt_created", .{});

            try self.appendToHistory(.user, try self.allocator.dupe(u8, with_reflection));
            slog.debug("agent", "turn_history_appended_trimming", .{});

            self.trimHistory();

            // Free provider response fields now that all borrows are consumed.
            self.freeResponseFields(&response);
            slog.debug("agent", "turn_tools_processed_continuing_loop", .{});
        }

        slog.debug("agent", "turn_loop_exhausted", .{ .max_iterations = self.max_tool_iterations });

        // ── Graceful degradation: tool iterations exhausted ──────────
        // Instead of returning an error, ask the LLM to summarize what it
        // has accomplished so far and return that as the final response.
        const exhausted_event = ObserverEvent{ .tool_iterations_exhausted = .{ .iterations = self.max_tool_iterations } };
        self.observer.recordEvent(&exhausted_event);
        log.warn("Tool iterations exhausted ({d}/{d}), requesting summary", .{ self.max_tool_iterations, self.max_tool_iterations });

        // Append a pseudo-user message forcing a text-only summary
        try self.appendToHistory(.user, try self.allocator.dupe(u8, "SYSTEM: You have reached the maximum number of tool iterations. " ++
                "You MUST NOT call any more tools. Summarize what you have accomplished " ++
                "so far and what remains to be done. Respond in the same language the user used."));

        // Build messages for the summary call
        slog.debug("agent", "turn_building_summary_messages", .{});
        const summary_messages = self.buildMessageSlice() catch {
            slog.debug("agent", "turn_summary_messages_failed", .{});
            const fallback = try std.fmt.allocPrint(self.allocator, "[Tool iteration limit: {d}/{d}] Could not produce a summary. Try /new and repeat your request.", .{ self.max_tool_iterations, self.max_tool_iterations });
            const complete_event = ObserverEvent{ .turn_complete = {} };
            self.observer.recordEvent(&complete_event);
            slog.debug("agent", "turn_returning_fallback", .{});
            return fallback;
        };
        defer self.allocator.free(summary_messages);

        slog.debug("agent", "turn_calling_summary_llm", .{});
        self.logLlmRequest(self.max_tool_iterations + 1, 1, summary_messages, false, false);
        var summary_response = self.provider.chat(
            self.allocator,
            .{
                .messages = summary_messages,
                .model = self.model_name,
                .temperature = self.temperature,
                .max_tokens = self.max_tokens,
                .tools = null, // force text-only
                .timeout_secs = self.message_timeout_secs,
                .reasoning_effort = self.reasoning_effort,
            },
            self.model_name,
            self.temperature,
        ) catch {
            const fallback = try std.fmt.allocPrint(self.allocator, "[Tool iteration limit: {d}/{d}] Could not produce a summary. Try /new and repeat your request.", .{ self.max_tool_iterations, self.max_tool_iterations });
            const complete_event = ObserverEvent{ .turn_complete = {} };
            self.observer.recordEvent(&complete_event);
            return fallback;
        };
        self.logLlmResponse(self.max_tool_iterations + 1, 1, &summary_response);
        defer self.freeResponseFields(&summary_response);

        const summary_text = summary_response.contentOrEmpty();
        const prefixed = try std.fmt.allocPrint(self.allocator, "[Tool iteration limit: {d}/{d}]\n\n{s}", .{ self.max_tool_iterations, self.max_tool_iterations, summary_text });
        errdefer self.allocator.free(prefixed);

        // Store in history (dupe the raw summary, not the prefixed version)
        try self.appendToHistory(.assistant, try self.allocator.dupe(u8, summary_text));

        // Compact/trim history so the next turn doesn't start with bloated context
        self.last_turn_compacted = self.autoCompactHistory() catch false;
        self.trimHistory();

        const complete_event = ObserverEvent{ .turn_complete = {} };
        self.observer.recordEvent(&complete_event);

        return prefixed;
    }

    /// Execute a tool by name lookup.
    /// Parses arguments_json once into a std.json.ObjectMap and passes it to the tool.
    fn tool_call_batch_updates_tools_md(allocator: std.mem.Allocator, calls: []const ParsedToolCall) bool {
        for (calls) |call| {
            if (tool_call_updates_tools_md(allocator, call)) return true;
        }
        return false;
    }

    fn tool_call_updates_tools_md(allocator: std.mem.Allocator, call: ParsedToolCall) bool {
        if (!std.mem.eql(u8, call.name, "file_write") and !std.mem.eql(u8, call.name, "file_edit")) return false;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, call.arguments_json, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;

        const path_value = parsed.value.object.get("path") orelse return false;
        const path = switch (path_value) {
            .string => |s| s,
            else => return false,
        };
        return is_tools_markdown_path(path);
    }

    fn should_skip_tools_memory_store_duplicate(
        allocator: std.mem.Allocator,
        batch_updates_tools_md: bool,
        call: ParsedToolCall,
    ) bool {
        if (!batch_updates_tools_md) return false;
        if (!std.mem.eql(u8, call.name, "memory_store")) return false;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, call.arguments_json, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;

        if (parsed.value.object.get("key")) |key_value| {
            const key = switch (key_value) {
                .string => |s| s,
                else => "",
            };
            if (is_tools_memory_key(key)) return true;
        }

        if (parsed.value.object.get("content")) |content_value| {
            const content = switch (content_value) {
                .string => |s| s,
                else => "",
            };
            if (std.ascii.indexOfIgnoreCase(content, "tools.md") != null) return true;
        }

        return false;
    }

    fn is_tools_markdown_path(path: []const u8) bool {
        const basename = path_basename_any_separator(path);
        if (basename.len == 0) return false;
        return std.ascii.eqlIgnoreCase(basename, "TOOLS.md");
    }

    fn path_basename_any_separator(path: []const u8) []const u8 {
        const slash_idx = std.mem.lastIndexOfScalar(u8, path, '/');
        const backslash_idx = std.mem.lastIndexOfScalar(u8, path, '\\');
        const sep_idx = switch (slash_idx != null and backslash_idx != null) {
            true => if (slash_idx.? > backslash_idx.?) slash_idx.? else backslash_idx.?,
            false => slash_idx orelse backslash_idx orelse return path,
        };
        if (sep_idx + 1 >= path.len) return "";
        return path[sep_idx + 1 ..];
    }

    fn starts_with_ascii_ignore_case(value: []const u8, prefix: []const u8) bool {
        if (value.len < prefix.len) return false;
        return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
    }

    fn is_tools_memory_key(key: []const u8) bool {
        return starts_with_ascii_ignore_case(key, "pref.tools.") or
            starts_with_ascii_ignore_case(key, "preference.tools.") or
            std.ascii.eqlIgnoreCase(key, "__bootstrap.prompt.TOOLS.md");
    }

    fn executeTool(self: *Agent, tool_allocator: std.mem.Allocator, call: ParsedToolCall) ToolExecutionResult {
        slog.logStructured("DEBUG", "agent", "tool_execute_start", .{ .tool = call.name });

        // Policy gate: check autonomy and rate limit
        if (self.policy) |pol| {
            if (!pol.canAct()) {
                return .{
                    .name = call.name,
                    .output = "Action blocked: agent is in read-only mode",
                    .success = false,
                    .tool_call_id = call.tool_call_id,
                };
            }
            const allowed = pol.recordAction() catch true;
            if (!allowed) {
                return .{
                    .name = call.name,
                    .output = "Rate limit exceeded",
                    .success = false,
                    .tool_call_id = call.tool_call_id,
                };
            }
        }

        const trimmed_call_name = std.mem.trim(u8, call.name, " \t\r\n");
        slog.debug("agent", "execute_tool_trimmed_name", .{ .trimmed_name = trimmed_call_name });

        for (self.tools) |t| {
            if (std.ascii.eqlIgnoreCase(t.name(), trimmed_call_name)) {
                slog.debug("agent", "execute_tool_found_parsing_args", .{});

                // Parse arguments JSON to ObjectMap ONCE
                const parsed = std.json.parseFromSlice(
                    std.json.Value,
                    tool_allocator,
                    call.arguments_json,
                    .{},
                ) catch {
                    slog.debug("agent", "execute_tool_json_parse_failed", .{});
                    return .{
                        .name = call.name,
                        .output = "Invalid arguments JSON",
                        .success = false,
                        .tool_call_id = call.tool_call_id,
                    };
                };
                defer parsed.deinit();

                slog.debug("agent", "execute_tool_json_parse_success", .{});

                const args: std.json.ObjectMap = switch (parsed.value) {
                    .object => |o| o,
                    else => {
                        return .{
                            .name = call.name,
                            .output = "Arguments must be a JSON object",
                            .success = false,
                            .tool_call_id = call.tool_call_id,
                        };
                    },
                };

                if (isExecToolName(call.name)) {
                    if (self.execBlockMessage(args)) |msg| {
                        return .{
                            .name = call.name,
                            .output = msg,
                            .success = false,
                            .tool_call_id = call.tool_call_id,
                        };
                    }
                }

                slog.debug("agent", "execute_tool_calling_tool_execute", .{ .tool = call.name });
                const result = t.execute(tool_allocator, args, self.io) catch |err| {
                    slog.debug("agent", "execute_tool_failed", .{ .tool = call.name, .error_msg = @errorName(err) });
                    return .{
                        .name = call.name,
                        .output = @errorName(err),
                        .success = false,
                        .tool_call_id = call.tool_call_id,
                    };
                };
                slog.debug("agent", "execute_tool_success", .{ .tool = call.name, .output_len = result.output.len });
                // Arena allocator is used - no need to dupe or deinit.
                // Arena memory is valid until the arena is destroyed at end of turn(),
                // and arena doesn't support individual free() calls.
                const output = if (result.success) result.output else (result.error_msg orelse result.output);

                slog.debug("agent", "execute_tool_returning_result", .{ .tool = call.name, .success = result.success });
                return .{
                    .name = call.name,
                    .output = output,
                    .success = result.success,
                    .tool_call_id = call.tool_call_id,
                };
            }
        }

        slog.debug("agent", "execute_tool_not_found", .{ .tool = call.name });
        return .{
            .name = call.name,
            .output = "Unknown tool",
            .success = false,
            .tool_call_id = call.tool_call_id,
        };
    }

    /// Context for parallel tool execution - shared across threads
    const ParallelToolContext = struct {
        agent: *Agent,
        calls: []const ParsedToolCall,
        results: []ToolExecutionResult,
        arenas: []std.mem.Allocator,
        arena_allocators: []std.heap.ArenaAllocator,
        mutex: @import("../spinlock.zig").Spinlock = .{},
        batch_updates_tools_md: bool,
        session_hash: u64,
        log_tool_calls: bool,
        observer: *Observer,

        fn executeOne(context: *ParallelToolContext, index: usize) void {
            const call = context.calls[index];
            const arena = context.arenas[index];

            slog.logStructured("DEBUG", "agent", "parallel_tool_start", .{ .index = index, .tool = call.name });

            if (context.log_tool_calls) {
                log.info(
                    "tool-call start session=0x{x} index={d} name={s} id={s}",
                    .{ context.session_hash, index + 1, call.name, call.tool_call_id orelse "-" },
                );
            }

            const tool_start_event = ObserverEvent{ .tool_call_start = .{ .tool = call.name } };
            context.observer.recordEvent(&tool_start_event);

            const tool_timer = util.timestampUnix();

            // Check for duplicate memory_store
            const result = if (should_skip_tools_memory_store_duplicate(arena, context.batch_updates_tools_md, call)) blk: {
                slog.debug("agent", "parallel_tool_skipping_duplicate_memory_store", .{ .index = index });
                break :blk ToolExecutionResult{
                    .name = call.name,
                    .output = "Skipped duplicate memory_store: TOOLS.md was updated in the same tool batch",
                    .success = true,
                    .tool_call_id = call.tool_call_id,
                };
            } else blk: {
                // Execute the tool
                break :blk context.agent.executeTool(arena, call);
            };

            const tool_duration: u64 = @as(u64, @intCast(@max(0, util.timestampUnix() - tool_timer)));

            if (context.log_tool_calls) {
                log.info(
                    "tool-call done session=0x{x} index={d} name={s} success={} duration_ms={d}",
                    .{ context.session_hash, index + 1, call.name, result.success, tool_duration },
                );
            }

            const tool_event = ObserverEvent{ .tool_call = .{
                .tool = call.name,
                .duration_ms = tool_duration,
                .success = result.success,
                .detail = result.output,
            } };
            context.observer.recordEvent(&tool_event);

            // Store result (protected by mutex)
            context.mutex.lock();
            defer context.mutex.unlock();
            context.results[index] = result;
        }
    };

    // ── Deferred vector sync (queue for post-response processing) ──

    /// Queue a vector sync for processing after the LLM response.
    /// The key and content pointers must remain valid until flushPendingSyncs is called.
    fn queueVectorSync(self: *Agent, key: []const u8, content: []const u8) void {
        if (self.pending_sync_count < self.pending_sync_keys.len) {
            self.pending_sync_keys[self.pending_sync_count] = .{ .key = key, .content = content };
            self.pending_sync_count += 1;
        }
    }

    /// Process all queued vector syncs. Called after the LLM response is ready.
    fn flushPendingSyncs(self: *Agent) void {
        if (self.mem_rt) |rt| {
            for (self.pending_sync_keys[0..self.pending_sync_count]) |item| {
                if (item) |sync| {
                    rt.syncVectorAfterStore(self.allocator, sync.key, sync.content);
                }
            }
        }
        self.pending_sync_count = 0;
        for (&self.pending_sync_keys) |*slot| {
            slot.* = null;
        }
    }

    /// Execute multiple tools in parallel using threads.
    /// Returns results in the same order as the input calls.
    fn executeToolsParallel(
        self: *Agent,
        base_arena: std.mem.Allocator,
        calls: []const ParsedToolCall,
        batch_updates_tools_md: bool,
    ) ![]ToolExecutionResult {
        const call_count = calls.len;
        slog.debug("agent", "execute_tools_parallel_start", .{ .count = call_count });

        // Determine number of parallel workers
        const max_workers = if (self.max_parallel_tools == 0)
            @min(call_count, @as(usize, 3)) // Default: max 3 parallel tools
        else
            @min(call_count, @as(usize, self.max_parallel_tools));

        slog.debug("agent", "execute_tools_parallel_workers", .{ .max_workers = max_workers });

        // Allocate results array
        const results = try base_arena.alloc(ToolExecutionResult, call_count);

        // Create arena for each thread
        const arena_allocators = try base_arena.alloc(std.heap.ArenaAllocator, call_count);
        const arenas = try base_arena.alloc(std.mem.Allocator, call_count);
        for (arena_allocators, arenas) |*arena_alloc, *arena| {
            arena_alloc.* = std.heap.ArenaAllocator.init(base_arena);
            arena.* = arena_alloc.allocator();
        }

        // Create shared context
        var context = ParallelToolContext{
            .agent = self,
            .calls = calls,
            .results = results,
            .arenas = arenas,
            .arena_allocators = arena_allocators,
            .batch_updates_tools_md = batch_updates_tools_md,
            .session_hash = if (self.memory_session_id) |sid| std.hash.Wyhash.hash(0, sid) else 0,
            .log_tool_calls = self.log_tool_calls,
            .observer = &self.observer,
        };

        // Spawn worker threads
        var threads = try self.allocator.alloc(std.Thread, max_workers);
        defer self.allocator.free(threads);

        var next_index: usize = 0;
        var thread_count: usize = 0;

        // Distribute work across threads
        while (next_index < call_count and thread_count < max_workers) : ({
            next_index += 1;
            thread_count += 1;
        }) {
            const index = next_index;
            threads[thread_count] = try std.Thread.spawn(
                .{ .allocator = self.allocator },
                struct {
                    fn threadFn(ctx: *ParallelToolContext, idx: usize) void {
                        ctx.executeOne(idx);
                    }
                }.threadFn,
                .{ &context, index },
            );
        }

        // Wait for all threads to complete
        for (threads[0..thread_count]) |thread| {
            thread.join();
        }

        slog.debug("agent", "execute_tools_parallel_complete", .{ .count = call_count });

        slog.debug("agent", "execute_tools_parallel_complete", .{ .count = call_count });
        return results;
    }

    const LLM_LOG_MAX_BYTES: usize = 8192;

    fn llmLogPreview(text: []const u8) struct { slice: []const u8, truncated: bool } {
        if (text.len <= LLM_LOG_MAX_BYTES) {
            return .{ .slice = text, .truncated = false };
        }
        return .{ .slice = text[0..LLM_LOG_MAX_BYTES], .truncated = true };
    }

    /// Maximum content preview per message in snapshot (bytes).
    const SNAPSHOT_MSG_PREVIEW: usize = 300;
    /// Maximum total snapshot size (bytes).
    const SNAPSHOT_MAX_SIZE: usize = 7680;

    fn snapshotMessages(self: *Agent, arena: std.mem.Allocator, messages: []const ChatMessage) []const u8 {
        _ = self;
        if (messages.len == 0) return "";
        var sbuf: [SNAPSHOT_MAX_SIZE]u8 = undefined;
        var w = util.fixedBufferStream(&sbuf);
        const writer = w.writer();
        writer.writeAll("[") catch return "";
        for (messages, 0..) |msg, idx| {
            if (idx > 0) writer.writeAll(",") catch return "";
            writer.writeAll("{") catch return "";
            writer.writeAll("\"r\":") catch return "";
            writer.writeAll("\"") catch return "";
            writer.writeAll(msg.role.toSlice()) catch return "";
            writer.writeAll("\"") catch return "";
            const content = msg.content;
            if (content.len > 0) {
                writer.writeAll(",") catch return "";
                writer.writeAll("\"c\":") catch return "";
                writer.writeAll("\"") catch return "";
                const preview_len = @min(content.len, SNAPSHOT_MSG_PREVIEW);
                for (content[0..preview_len]) |ch| {
                    switch (ch) {
                        0x22 => { writer.writeAll("\\\"") catch return ""; },
                        0x5c => { writer.writeAll("\\\\") catch return ""; },
                        0x0a => { writer.writeAll("\\\n") catch return ""; },
                        0x0d => { writer.writeAll("\\\r") catch return ""; },
                        0x09 => { writer.writeAll("\\\t") catch return ""; },
                        else => { writer.writeAll(&.{ch}) catch return ""; },
                    }
                }
                if (content.len > preview_len) writer.writeAll("...") catch return "";
                writer.writeAll("\"") catch return "";
            }
            writer.writeAll("}") catch return "";
            if (w.getWritten().len > SNAPSHOT_MAX_SIZE - 50) {
                return w.getWritten();
            }
        }
        writer.writeAll("]") catch return "";
        // Copy to arena so it persists
        const written = w.getWritten();
        const copy = arena.alloc(u8, written.len) catch return "";
        @memcpy(copy, written);
        return copy;
    }

    fn snapshotToolCalls(self: *Agent, arena: std.mem.Allocator, tool_calls: []const providers.ToolCall) []const u8 {
        _ = self;
        if (tool_calls.len == 0) return "";
        var sbuf: [SNAPSHOT_MAX_SIZE]u8 = undefined;
        var w = util.fixedBufferStream(&sbuf);
        const writer = w.writer();
        writer.writeAll("[") catch return "";
        for (tool_calls, 0..) |tc, idx| {
            if (idx > 0) writer.writeAll(",") catch return "";
            writer.writeAll("{") catch return "";
            writer.writeAll("\"n\":") catch return "";
            writer.writeAll("\"") catch return "";
            writer.writeAll(tc.name) catch return "";
            writer.writeAll("\"") catch return "";
            if (tc.arguments.len > 0) {
                writer.writeAll(",") catch return "";
                writer.writeAll("\"a\":") catch return "";
                writer.writeAll("\"") catch return "";
                const preview_len = @min(tc.arguments.len, SNAPSHOT_MSG_PREVIEW);
                for (tc.arguments[0..preview_len]) |ch| {
                    switch (ch) {
                        0x22 => { writer.writeAll("\\\"") catch return ""; },
                        0x5c => { writer.writeAll("\\\\") catch return ""; },
                        0x0a => { writer.writeAll("\\\n") catch return ""; },
                        0x0d => { writer.writeAll("\\\r") catch return ""; },
                        0x09 => { writer.writeAll("\\\t") catch return ""; },
                        else => { writer.writeAll(&.{ch}) catch return ""; },
                    }
                }
                if (tc.arguments.len > preview_len) writer.writeAll("...") catch return "";
                writer.writeAll("\"") catch return "";
            }
            writer.writeAll("}") catch return "";
        }
        writer.writeAll("]") catch return "";
        const written = w.getWritten();
        const copy = arena.alloc(u8, written.len) catch return "";
        @memcpy(copy, written);
        return copy;
    }

    fn logLlmRequest(self: *Agent, iteration: u32, attempt: u32, messages: []const ChatMessage, native_tools_enabled: bool, is_streaming: bool) void {
        if (!self.log_llm_io) return;
        const session_hash: u64 = if (self.memory_session_id) |sid| std.hash.Wyhash.hash(0, sid) else 0;
        log.info(
            "llm request session=0x{x} iter={d} attempt={d} provider={s} model={s} messages={d} native_tools={} streaming={}",
            .{
                session_hash,
                iteration,
                attempt,
                self.provider.getName(),
                self.model_name,
                messages.len,
                native_tools_enabled,
                is_streaming,
            },
        );
        for (messages, 0..) |msg, idx| {
            const preview = llmLogPreview(msg.content);
            const parts_count: usize = if (msg.content_parts) |parts| parts.len else 0;
            log.info(
                "llm request msg session=0x{x} iter={d} attempt={d} index={d} role={s} bytes={d} parts={d} content={f}{s}",
                .{
                    session_hash,
                    iteration,
                    attempt,
                    idx + 1,
                    msg.role.toSlice(),
                    msg.content.len,
                    parts_count,
                    std.json.fmt(preview.slice, .{}),
                    if (preview.truncated) " [truncated]" else "",
                },
            );
        }
    }

    fn logLlmResponse(self: *Agent, iteration: u32, attempt: u32, response: *const ChatResponse) void {
        if (!self.log_llm_io) return;
        const session_hash: u64 = if (self.memory_session_id) |sid| std.hash.Wyhash.hash(0, sid) else 0;
        const content = response.contentOrEmpty();
        const preview = llmLogPreview(content);
        log.info(
            "llm response session=0x{x} iter={d} attempt={d} model={s} bytes={d} tool_calls={d} usage={f} content={f}{s}",
            .{
                session_hash,
                iteration,
                attempt,
                if (response.model.len > 0) response.model else self.model_name,
                content.len,
                response.tool_calls.len,
                std.json.fmt(response.usage, .{}),
                std.json.fmt(preview.slice, .{}),
                if (preview.truncated) " [truncated]" else "",
            },
        );

        if (response.reasoning_content) |reasoning| {
            const r_preview = llmLogPreview(reasoning);
            log.info(
                "llm response reasoning session=0x{x} iter={d} attempt={d} bytes={d} content={f}{s}",
                .{
                    session_hash,
                    iteration,
                    attempt,
                    reasoning.len,
                    std.json.fmt(r_preview.slice, .{}),
                    if (r_preview.truncated) " [truncated]" else "",
                },
            );
        }

        for (response.tool_calls, 0..) |tc, idx| {
            const args_preview = llmLogPreview(tc.arguments);
            log.info(
                "llm response tool-call session=0x{x} iter={d} attempt={d} index={d} id={s} name={s} args={f}{s}",
                .{
                    session_hash,
                    iteration,
                    attempt,
                    idx + 1,
                    if (tc.id.len > 0) tc.id else "-",
                    tc.name,
                    std.json.fmt(args_preview.slice, .{}),
                    if (args_preview.truncated) " [truncated]" else "",
                },
            );
        }
    }

    /// Build provider-ready ChatMessage slice from owned history.
    /// Applies multimodal preprocessing and vision capability checks.
    fn buildProviderMessages(self: *Agent, arena: std.mem.Allocator) ![]ChatMessage {
        const m = try arena.alloc(ChatMessage, self.history.items.len);
        for (self.history.items, 0..) |*msg, i| {
            m[i] = msg.toChatMessage();
        }

        const image_marker_count = multimodal.countImageMarkersInLastUser(m);
        if (image_marker_count > 0 and !self.provider.supportsVisionForModel(self.model_name)) {
            return error.ProviderDoesNotSupportVision;
        }

        // FIX 20: Cache allowed-dirs list across iterations (allocated with agent allocator).
        // workspace_dir, allowed_paths, and temp dir don't change within a session.
        if (!self.cached_allowed_dirs_built) {
            var allowed_dirs_list: std.ArrayListUnmanaged([]const u8) = .empty;
            try appendMultimodalAllowedDir(self.allocator, &allowed_dirs_list, self.workspace_dir);
            for (self.allowed_paths) |dir| {
                try appendMultimodalAllowedDir(self.allocator, &allowed_dirs_list, dir);
            }
            // Use a temporary arena for temp dir allocation
            var tmp_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer tmp_arena.deinit();
            if (platform.getTempDir(tmp_arena.allocator()) catch null) |tmp_dir| {
                try appendMultimodalAllowedDir(self.allocator, &allowed_dirs_list, tmp_dir);
            }
            self.cached_allowed_dirs = try allowed_dirs_list.toOwnedSlice(self.allocator);
            self.cached_allowed_dirs_built = true;
        }

        return multimodal.prepareMessagesForProvider(arena, m, .{
            .allowed_dirs = self.cached_allowed_dirs,
        }, self.io);
    }

    fn appendMultimodalAllowedDir(
        arena: std.mem.Allocator,
        dirs: *std.ArrayListUnmanaged([]const u8),
        raw_dir: []const u8,
    ) !void {
        // Only strip trailing slashes — keep leading / for absolute paths
        var trimmed = raw_dir;
        while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == '/' or trimmed[trimmed.len - 1] == '\\')) {
            trimmed = trimmed[0 .. trimmed.len - 1];
        }
        if (trimmed.len == 0) return;

        if (!containsMultimodalDir(dirs.items, trimmed)) {
            try dirs.append(arena, trimmed);
        }

        // Add /var <-> /private/var symlink variant on macOS
        if (comptime @import("builtin").os.tag == .macos) {
            const variant = if (std.mem.startsWith(u8, trimmed, "/private/"))
                trimmed["/private".len..]
            else if (std.mem.startsWith(u8, trimmed, "/var/"))
                try std.fmt.allocPrint(arena, "/private{s}", .{trimmed})
            else
                null;
            if (variant) |v| {
                if (!containsMultimodalDir(dirs.items, v)) {
                    try dirs.append(arena, v);
                }
            }
        }
    }

    fn containsMultimodalDir(dirs: []const []const u8, target: []const u8) bool {
        for (dirs) |dir| {
            if (std.mem.eql(u8, dir, target)) return true;
        }
        return false;
    }

    /// Build a flat ChatMessage slice from owned history.
    fn buildMessageSlice(self: *Agent) ![]ChatMessage {
        const messages = try self.allocator.alloc(ChatMessage, self.history.items.len);
        for (self.history.items, 0..) |*msg, i| {
            messages[i] = msg.toChatMessage();
        }
        return messages;
    }

    /// Free heap-allocated fields of a ChatResponse.
    /// Providers allocate content, tool_calls, and model on the heap.
    /// After extracting/duping what we need, call this to prevent leaks.
    fn freeResponseFields(self: *Agent, resp: *ChatResponse) void {
        if (resp.content) |c| {
            if (c.len > 0) self.allocator.free(c);
        }
        for (resp.tool_calls) |tc| {
            if (tc.id.len > 0) self.allocator.free(tc.id);
            if (tc.name.len > 0) self.allocator.free(tc.name);
            if (tc.arguments.len > 0) self.allocator.free(tc.arguments);
        }
        if (resp.tool_calls.len > 0) self.allocator.free(resp.tool_calls);
        if (resp.model.len > 0) self.allocator.free(resp.model);
        if (resp.reasoning_content) |rc| {
            if (rc.len > 0) self.allocator.free(rc);
        }
        // Mark as consumed to prevent double-free
        resp.content = null;
        resp.tool_calls = &.{};
        resp.model = "";
        resp.reasoning_content = null;
    }

    /// Trim history to prevent unbounded growth.
    fn trimHistory(self: *Agent) void {
        const before = self.history.items.len;
        compaction.trimHistory(self.allocator, &self.history, self.max_history_messages);
        // FIX 21: Recalculate if messages were trimmed
        if (self.history.items.len != before) {
            self.total_history_chars = self.recalculateHistoryChars();
        }
    }

    /// Run a single message through the agent and return the response.
    pub fn runSingle(self: *Agent, message: []const u8) ![]const u8 {
        return self.turn(message);
    }

    /// Clear conversation history (for starting a new session).
    pub fn clearHistory(self: *Agent) void {
        for (self.history.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.history.items.len = 0;
        self.has_system_prompt = false;
        self.system_prompt_has_conversation_context = false;
        self.workspace_prompt_fingerprint = null;
        self.total_history_chars = 0;
        self.cached_sys_prompt_hash = 0;
        self.capabilities_dirty = true;
        self.cached_allowed_dirs_built = false;
    }

    /// Get total tokens used.
    pub fn tokensUsed(self: *const Agent) u64 {
        return self.total_tokens;
    }

    /// Get current history length.
    pub fn historyLen(self: *const Agent) usize {
        return self.history.items.len;
    }

    /// Load persisted messages into history (for session restore).
    /// Each entry has .role ("user"/"assistant") and .content.
    /// The agent takes ownership of the content strings.
    pub fn loadHistory(self: *Agent, entries: anytype) !void {
        for (entries) |entry| {
            const role: providers.Role = if (std.mem.eql(u8, entry.role, "assistant"))
                .assistant
            else if (std.mem.eql(u8, entry.role, "system"))
                .system
            else
                .user;
            const content = try self.allocator.dupe(u8, entry.content);
            try self.appendToHistory(role, content);
        }
    }

    /// Get history entries as role-string + content pairs (for persistence).
    /// Caller owns the returned slice but NOT the inner strings (borrows from history).
    pub fn getHistory(self: *const Agent, allocator: std.mem.Allocator) ![]struct { role: []const u8, content: []const u8 } {
        const Pair = struct { role: []const u8, content: []const u8 };
        const result = try allocator.alloc(Pair, self.history.items.len);
        for (self.history.items, 0..) |*msg, i| {
            result[i] = .{
                .role = switch (msg.role) {
                    .system => "system",
                    .user => "user",
                    .assistant => "assistant",
                    .tool => "tool",
                },
                .content = msg.content,
            };
        }
        return result;
    }
};

pub const cli = @import("cli.zig");

/// CLI entry point — re-exported for backward compatibility.
pub const run = cli.run;

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "Agent.OwnedMessage toChatMessage" {
    const msg = Agent.OwnedMessage{
        .role = .user,
        .content = "hello",
    };
    const chat = msg.toChatMessage();
    try std.testing.expect(chat.role == .user);
    try std.testing.expectEqualStrings("hello", chat.content);
}

test "Agent trim history preserves system prompt" {
    const allocator = std.testing.allocator;

    // Create a minimal agent config
    const cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = allocator,
    };

    var noop = observability.NoopObserver{};

    // We can't create a real provider in tests, but we can test trimHistory
    // by creating an Agent with minimal fields
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = cfg.default_model orelse "test",
        .temperature = 0.7,
        .workspace_dir = cfg.workspace_dir,
        .max_tool_iterations = 10,
        .max_history_messages = 5,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    // Add system prompt
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system prompt"),
    });

    // Add more messages than max
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "msg {d}", .{i}),
        });
    }

    try std.testing.expect(agent.history.items.len == 11); // 1 system + 10 user

    agent.trimHistory();

    // System prompt should be preserved
    try std.testing.expect(agent.history.items[0].role == .system);
    try std.testing.expectEqualStrings("system prompt", agent.history.items[0].content);

    // Should be trimmed to max + 1 (system)
    try std.testing.expect(agent.history.items.len <= 6); // 1 system + 5 messages

    // Most recent message should be the last one added
    const last = agent.history.items[agent.history.items.len - 1];
    try std.testing.expectEqualStrings("msg 9", last.content);
}

test "Agent clear history" {
    const allocator = std.testing.allocator;

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = true,
        .workspace_prompt_fingerprint = 1234,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "sys"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    try std.testing.expectEqual(@as(usize, 2), agent.historyLen());

    agent.clearHistory();

    try std.testing.expectEqual(@as(usize, 0), agent.historyLen());
    try std.testing.expect(!agent.has_system_prompt);
    try std.testing.expect(agent.workspace_prompt_fingerprint == null);
}

test "dispatcher module reexport" {
    _ = dispatcher.ParsedToolCall;
    _ = dispatcher.ToolExecutionResult;
    _ = dispatcher.parseToolCalls;
    _ = dispatcher.formatToolResults;
    _ = dispatcher.buildToolInstructions;
    _ = dispatcher.buildAssistantHistoryWithToolCalls;
}

test "compaction module reexport" {
    _ = compaction.tokenEstimate;
    _ = compaction.autoCompactHistory;
    _ = compaction.forceCompressHistory;
    _ = compaction.trimHistory;
    _ = compaction.CompactionConfig;
}

test "cli module reexport" {
    _ = cli.run;
}

test "prompt module reexport" {
    _ = prompt.buildSystemPrompt;
    _ = prompt.PromptContext;
}

test "memory_loader module reexport" {
    _ = memory_loader.loadContext;
    _ = memory_loader.enrichMessage;
}

test {
    _ = dispatcher;
    _ = compaction;
    _ = cli;
    _ = prompt;
    _ = memory_loader;
}

// ── Additional agent tests ──────────────────────────────────────

test "Agent.OwnedMessage system role" {
    const msg = Agent.OwnedMessage{
        .role = .system,
        .content = "system prompt",
    };
    const chat = msg.toChatMessage();
    try std.testing.expect(chat.role == .system);
    try std.testing.expectEqualStrings("system prompt", chat.content);
}

test "Agent.OwnedMessage assistant role" {
    const msg = Agent.OwnedMessage{
        .role = .assistant,
        .content = "I can help with that.",
    };
    const chat = msg.toChatMessage();
    try std.testing.expect(chat.role == .assistant);
    try std.testing.expectEqualStrings("I can help with that.", chat.content);
}

test "Agent initial state" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.5,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    try std.testing.expectEqual(@as(usize, 0), agent.historyLen());
    try std.testing.expectEqual(@as(u64, 0), agent.tokensUsed());
    try std.testing.expect(!agent.has_system_prompt);
}

test "Agent tokens tracking" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    agent.total_tokens = 100;
    try std.testing.expectEqual(@as(u64, 100), agent.tokensUsed());
    agent.total_tokens += 50;
    try std.testing.expectEqual(@as(u64, 150), agent.tokensUsed());
}

test "Agent trimHistory no-op when under limit" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "sys"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    agent.trimHistory();
    try std.testing.expectEqual(@as(usize, 2), agent.historyLen());
}

test "Agent trimHistory without system prompt" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 3,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    // Add 6 user messages (no system prompt)
    for (0..6) |i| {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "msg {d}", .{i}),
        });
    }

    agent.trimHistory();
    // Should trim to max_history_messages (3) + 1 for system = 4, but no system
    try std.testing.expect(agent.history.items.len <= 4);
}

test "Agent clearHistory resets all state" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = true,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });
    try agent.history.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "hi"),
    });

    try std.testing.expectEqual(@as(usize, 3), agent.historyLen());
    try std.testing.expect(agent.has_system_prompt);

    agent.clearHistory();

    try std.testing.expectEqual(@as(usize, 0), agent.historyLen());
    try std.testing.expect(!agent.has_system_prompt);
}

test "Agent buildMessageSlice" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "sys"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    const messages = try agent.buildMessageSlice();
    defer allocator.free(messages);

    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expect(messages[0].role == .system);
    try std.testing.expect(messages[1].role == .user);
    try std.testing.expectEqualStrings("sys", messages[0].content);
    try std.testing.expectEqualStrings("hello", messages[1].content);
}

test "Agent buildProviderMessages uses model-aware vision capability" {
    const DummyProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }
        fn chat(_: *anyopaque, _: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{};
        }
        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }
        fn supportsVision(_: *anyopaque) bool {
            return true;
        }
        fn supportsVisionForModel(_: *anyopaque, model: []const u8) bool {
            return std.mem.eql(u8, model, "vision-model");
        }
        fn getName(_: *anyopaque) []const u8 {
            return "dummy";
        }
        fn deinitFn(_: *anyopaque) void {}
    };

    var dummy: u8 = 0;
    const vtable = Provider.VTable{
        .chatWithSystem = DummyProvider.chatWithSystem,
        .chat = DummyProvider.chat,
        .supportsNativeTools = DummyProvider.supportsNativeTools,
        .supports_vision = DummyProvider.supportsVision,
        .supports_vision_for_model = DummyProvider.supportsVisionForModel,
        .getName = DummyProvider.getName,
        .deinit = DummyProvider.deinitFn,
    };
    const prov = Provider{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = prov,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "text-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "Check [IMAGE:https://example.com/a.jpg]"),
    });

    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    try std.testing.expectError(error.ProviderDoesNotSupportVision, agent.buildProviderMessages(arena));

    agent.model_name = "vision-model";
    const messages = try agent.buildProviderMessages(arena);
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expect(messages[0].content_parts != null);
}

test "Agent buildProviderMessages allows workspace image paths" {
    const DummyProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }
        fn chat(_: *anyopaque, _: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{};
        }
        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }
        fn supportsVision(_: *anyopaque) bool {
            return true;
        }
        fn supportsVisionForModel(_: *anyopaque, _: []const u8) bool {
            return true;
        }
        fn getName(_: *anyopaque) []const u8 {
            return "dummy";
        }
        fn deinitFn(_: *anyopaque) void {}
    };

    const io = std.Options.debug_io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "screen.png",
        .data = "\x89PNG\x0d\x0a\x1a\x0a",
    });

    const allocator = std.testing.allocator;
    const workspace_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(workspace_path_z.ptr[0 .. workspace_path_z.len + 1]);
    const workspace_path = workspace_path_z[0..workspace_path_z.len]; // Drop sentinel
    const image_path = try std.fs.path.join(allocator, &.{ workspace_path, "screen.png" });
    defer allocator.free(image_path);

    var dummy: u8 = 0;
    const vtable = Provider.VTable{
        .chatWithSystem = DummyProvider.chatWithSystem,
        .chat = DummyProvider.chat,
        .supportsNativeTools = DummyProvider.supportsNativeTools,
        .supports_vision = DummyProvider.supportsVision,
        .supports_vision_for_model = DummyProvider.supportsVisionForModel,
        .getName = DummyProvider.getName,
        .deinit = DummyProvider.deinitFn,
    };
    const prov = Provider{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = prov,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "vision-model",
        .temperature = 0.7,
        .workspace_dir = workspace_path,
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try std.fmt.allocPrint(allocator, "Inspect [IMAGE:{s}]", .{image_path}),
    });

    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();
    const messages = try agent.buildProviderMessages(arena);

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expect(messages[0].content_parts != null);
    const parts = messages[0].content_parts.?;
    var has_image_part = false;
    for (parts) |part| {
        if (part == .image_base64) {
            has_image_part = true;
            break;
        }
    }
    try std.testing.expect(has_image_part);
}

test "Agent max_tool_iterations default" {
    try std.testing.expectEqual(@as(u32, 25), DEFAULT_MAX_TOOL_ITERATIONS);
}

test "Agent max_history default" {
    try std.testing.expectEqual(@as(u32, 50), DEFAULT_MAX_HISTORY);
}

test "Agent trimHistory keeps most recent messages" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 3,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    // Add system + 5 messages
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system"),
    });
    for (0..5) |i| {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "msg-{d}", .{i}),
        });
    }

    agent.trimHistory();

    // Should keep system + last 3 messages
    try std.testing.expectEqual(@as(usize, 4), agent.historyLen());
    try std.testing.expect(agent.history.items[0].role == .system);
    // Last message should be msg-4
    try std.testing.expectEqualStrings("msg-4", agent.history.items[3].content);
}

test "Agent clearHistory then add messages" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = true,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "old"),
    });
    agent.clearHistory();

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "new"),
    });
    try std.testing.expectEqual(@as(usize, 1), agent.historyLen());
    try std.testing.expectEqualStrings("new", agent.history.items[0].content);
}

// ── Slash Command Tests ──────────────────────────────────────────

fn makeTestAgent(allocator: std.mem.Allocator) !Agent {
    var noop = observability.NoopObserver{};
    return Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
}

fn find_tool_by_name(tools: []const Tool, name: []const u8) ?Tool {
    for (tools) |t| {
        if (std.mem.eql(u8, t.name(), name)) return t;
    }
    return null;
}

test "Agent.fromConfig resolves token limit from model lookup when unset" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "openai/gpt-4.1-mini",
        .allocator = allocator,
    };
    cfg.agent.token_limit = config_types.DEFAULT_AGENT_TOKEN_LIMIT;
    cfg.agent.token_limit_explicit = false;

    var noop = observability.NoopObserver{};
    var agent = try Agent.fromConfig(allocator, &cfg, undefined, &.{}, null, noop.observer(), std.testing.io);
    defer agent.deinit();

    try std.testing.expectEqual(@as(u64, 128_000), agent.token_limit);
    try std.testing.expect(agent.token_limit_override == null);
    try std.testing.expectEqual(@as(u32, max_tokens_resolver.DEFAULT_MODEL_MAX_TOKENS), agent.max_tokens);
    try std.testing.expect(agent.max_tokens_override == null);
}

test "Agent.fromConfig keeps explicit token_limit override" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "openai/gpt-4.1-mini",
        .allocator = allocator,
    };
    cfg.agent.token_limit = 64_000;
    cfg.agent.token_limit_explicit = true;

    var noop = observability.NoopObserver{};
    var agent = try Agent.fromConfig(allocator, &cfg, undefined, &.{}, null, noop.observer(), std.testing.io);
    defer agent.deinit();

    try std.testing.expectEqual(@as(u64, 64_000), agent.token_limit);
    try std.testing.expectEqual(@as(?u64, 64_000), agent.token_limit_override);
}

test "Agent.fromConfig resolves max_tokens from provider lookup when unset" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "qianfan/custom-model",
        .allocator = allocator,
    };
    cfg.max_tokens = null;

    var noop = observability.NoopObserver{};
    var agent = try Agent.fromConfig(allocator, &cfg, undefined, &.{}, null, noop.observer(), std.testing.io);
    defer agent.deinit();

    try std.testing.expectEqual(@as(u32, 32_768), agent.max_tokens);
    try std.testing.expect(agent.max_tokens_override == null);
}

test "Agent.fromConfig keeps explicit max_tokens override" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "qianfan/custom-model",
        .allocator = allocator,
    };
    cfg.max_tokens = 1536;

    var noop = observability.NoopObserver{};
    var agent = try Agent.fromConfig(allocator, &cfg, undefined, &.{}, null, noop.observer(), std.testing.io);
    defer agent.deinit();

    try std.testing.expectEqual(@as(u32, 1536), agent.max_tokens);
    try std.testing.expectEqual(@as(?u32, 1536), agent.max_tokens_override);
}

test "Agent.fromConfig clamps max_tokens to token_limit" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "openai/gpt-4.1-mini",
        .allocator = allocator,
    };
    cfg.agent.token_limit = 4096;
    cfg.agent.token_limit_explicit = true;
    cfg.max_tokens = 8192;

    var noop = observability.NoopObserver{};
    var agent = try Agent.fromConfig(allocator, &cfg, undefined, &.{}, null, noop.observer(), std.testing.io);
    defer agent.deinit();

    try std.testing.expectEqual(@as(u64, 4096), agent.token_limit);
    try std.testing.expectEqual(@as(u32, 4096), agent.max_tokens);
}

test "slash /new clears history" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Add some history
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "sys"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });
    agent.has_system_prompt = true;

    const response = (try agent.handleSlashCommand("/new")).?;
    defer allocator.free(response);

    try std.testing.expectEqualStrings("Session cleared.", response);
    try std.testing.expectEqual(@as(usize, 0), agent.historyLen());
    try std.testing.expect(!agent.has_system_prompt);
}

test "slash /reset clears history and switches model" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    const response = (try agent.handleSlashCommand("/reset gpt-4o-mini")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Session cleared.") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "gpt-4o-mini") != null);
    try std.testing.expectEqual(@as(usize, 0), agent.historyLen());
    try std.testing.expectEqualStrings("gpt-4o-mini", agent.model_name);
}

test "turn bare /new routes through fresh-session prompt" {
    const EchoProvider = struct {
        const Self = @This();
        call_count: usize = 0,

        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, req: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.call_count += 1;

            var last_user: []const u8 = "";
            for (req.messages) |msg| {
                if (msg.role == .user) last_user = msg.content;
            }

            return .{
                .content = try allocator.dupe(u8, last_user),
                .tool_calls = &.{},
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "echo-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;

    var provider_state = EchoProvider{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = EchoProvider.chatWithSystem,
        .chat = EchoProvider.chat,
        .supportsNativeTools = EchoProvider.supportsNativeTools,
        .getName = EchoProvider.getName,
        .deinit = EchoProvider.deinitFn,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = provider,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = true,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "old-before-reset"),
    });

    const response = try agent.turn("/new");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Execute your Session Startup sequence now") != null);
    try std.testing.expectEqual(@as(usize, 1), provider_state.call_count);

    for (agent.history.items) |msg| {
        try std.testing.expect(std.mem.indexOf(u8, msg.content, "old-before-reset") == null);
    }
}

test "turn /reset with argument stays slash-only command" {
    const NoCallProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(_: *anyopaque, _: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return error.UnexpectedProviderCall;
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "nocall-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;

    var provider_state: u8 = 0;
    const provider_vtable = Provider.VTable{
        .chatWithSystem = NoCallProvider.chatWithSystem,
        .chat = NoCallProvider.chat,
        .supportsNativeTools = NoCallProvider.supportsNativeTools,
        .getName = NoCallProvider.getName,
        .deinit = NoCallProvider.deinitFn,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = provider,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    const response = try agent.turn("/reset gpt-4o-mini");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Session cleared.") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "gpt-4o-mini") != null);
    try std.testing.expectEqualStrings("gpt-4o-mini", agent.model_name);
}

test "slash /help returns help text" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/help")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "/new") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/help") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/status") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/model") != null);
}

test "slash /commands aliases to help" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/commands")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "/new") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/commands") != null);
}

test "slash /status returns agent info" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.total_tokens = 42;
    const response = (try agent.handleSlashCommand("/status")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "test-model") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "42") != null);
}

test "slash /whoami returns current session id" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    agent.memory_session_id = "telegram:chat123";

    const response = (try agent.handleSlashCommand("/whoami")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "telegram:chat123") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "test-model") != null);
}

test "slash /model switches model" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    agent.max_tokens = 111;
    agent.has_system_prompt = true;

    const response = (try agent.handleSlashCommand("/model gpt-4o")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "gpt-4o") != null);
    try std.testing.expectEqualStrings("gpt-4o", agent.model_name);
    try std.testing.expectEqualStrings("gpt-4o", agent.default_model);
    try std.testing.expectEqual(@as(u64, 128_000), agent.token_limit);
    try std.testing.expectEqual(@as(u32, 8192), agent.max_tokens);
    try std.testing.expect(!agent.has_system_prompt);
}

test "slash /model with colon switches model" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    agent.max_tokens = 111;

    const response = (try agent.handleSlashCommand("/model: gpt-4.1-mini")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "gpt-4.1-mini") != null);
    try std.testing.expectEqualStrings("gpt-4.1-mini", agent.model_name);
    try std.testing.expectEqual(@as(u64, 128_000), agent.token_limit);
    try std.testing.expectEqual(@as(u32, 8192), agent.max_tokens);
}

test "slash /model with telegram bot mention switches model" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    agent.max_tokens = 111;

    const response = (try agent.handleSlashCommand("/model@nullclaw_bot qianfan/custom-model")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "qianfan/custom-model") != null);
    try std.testing.expectEqualStrings("qianfan/custom-model", agent.model_name);
    try std.testing.expectEqualStrings("qianfan/custom-model", agent.default_model);
    try std.testing.expectEqual(@as(u32, 32_768), agent.max_tokens);
}

test "slash /model resolves provider max_tokens fallback" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    agent.max_tokens = 111;

    const response = (try agent.handleSlashCommand("/model qianfan/custom-model")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "qianfan/custom-model") != null);
    try std.testing.expectEqualStrings("qianfan/custom-model", agent.model_name);
    try std.testing.expectEqual(@as(u32, 32_768), agent.max_tokens);
}

test "slash /model keeps explicit token_limit override" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    agent.token_limit_override = 64_000;
    agent.token_limit = 64_000;
    agent.max_tokens_override = 1024;
    agent.max_tokens = 1024;

    const response = (try agent.handleSlashCommand("/model claude-opus-4-6")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "claude-opus-4-6") != null);
    try std.testing.expectEqual(@as(u64, 64_000), agent.token_limit);
    try std.testing.expectEqual(@as(u32, 1024), agent.max_tokens);
}

test "slash /model without name shows current" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/model ")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "test-model") != null);
}

test "slash /models aliases to /model" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/models list")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Current model: test-model") != null);
}

test "slash /model list aliases to model status" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/model list")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Current model: test-model") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Switch: /model <name>") != null);
}

test "slash /memory list hides internal autosave and hygiene entries by default" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("autosave_user_1", "hello", .conversation, null);
    try mem.store("last_hygiene_at", "1772051598", .core, null);
    try mem.store("MEMORY:99", "**last_hygiene_at**: 1772051691", .core, null);
    try mem.store("user_language", "ru", .core, null);

    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "test",
        .retrieval_mode = "keyword",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .snapshot_enabled = false,
        .cache_enabled = false,
        .semantic_cache_enabled = false,
        .summarizer_enabled = false,
        .source_count = 0,
        .fallback_policy = "degrade",
    };
    var rt = memory_mod.MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = resolved,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = allocator,
    };
    agent.mem_rt = &rt;

    const response = (try agent.handleSlashCommand("/memory list --limit 10")).?;
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "user_language") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "autosave_user_") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "last_hygiene_at") == null);
}

test "slash /memory list includes internal entries when requested" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("autosave_user_1", "hello", .conversation, null);
    try mem.store("last_hygiene_at", "1772051598", .core, null);

    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "test",
        .retrieval_mode = "keyword",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .snapshot_enabled = false,
        .cache_enabled = false,
        .semantic_cache_enabled = false,
        .summarizer_enabled = false,
        .source_count = 0,
        .fallback_policy = "degrade",
    };
    var rt = memory_mod.MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = resolved,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = allocator,
    };
    agent.mem_rt = &rt;

    const response = (try agent.handleSlashCommand("/memory list --limit 10 --include-internal")).?;
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "autosave_user_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "last_hygiene_at") != null);
}

test "slash /model shows provider and model fallback chains" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const configured_providers = [_]config_types.ProviderEntry{
        .{ .name = "openai-codex" },
        .{ .name = "openrouter", .api_key = "sk-or-test" },
    };
    const model_fallbacks = [_]config_types.ModelFallbackEntry{
        .{
            .model = "gpt-5.3-codex",
            .fallbacks = &.{"openrouter/anthropic/claude-sonnet-4"},
        },
    };

    agent.model_name = "gpt-5.3-codex";
    agent.default_model = "gpt-5.3-codex";
    agent.default_provider = "openai-codex";
    agent.configured_providers = &configured_providers;
    agent.fallback_providers = &.{"openrouter"};
    agent.model_fallbacks = &model_fallbacks;

    const response = (try agent.handleSlashCommand("/model")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Provider chain: openai-codex -> openrouter") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        response,
        "Model chain: gpt-5.3-codex -> openrouter/anthropic/claude-sonnet-4",
    ) != null);
}

test "slash /compact with short history is a no-op" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/compact")).?;
    defer allocator.free(response);

    try std.testing.expectEqualStrings("Nothing to compact.", response);
}

test "slash /think updates reasoning effort" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const set_resp = (try agent.handleSlashCommand("/think high")).?;
    defer allocator.free(set_resp);
    try std.testing.expect(std.mem.indexOf(u8, set_resp, "high") != null);
    try std.testing.expectEqualStrings("high", agent.reasoning_effort.?);

    const off_resp = (try agent.handleSlashCommand("/think off")).?;
    defer allocator.free(off_resp);
    try std.testing.expect(agent.reasoning_effort == null);
}

test "slash /verbose updates verbose level" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/verbose full")).?;
    defer allocator.free(response);

    try std.testing.expect(agent.verbose_level == .full);
}

test "slash /reasoning updates reasoning mode" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/reasoning stream")).?;
    defer allocator.free(response);

    try std.testing.expect(agent.reasoning_mode == .stream);
}

test "slash /exec updates runtime exec settings" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/exec host=sandbox security=full ask=off node=node-1")).?;
    defer allocator.free(response);

    try std.testing.expect(agent.exec_host == .sandbox);
    try std.testing.expect(agent.exec_security == .full);
    try std.testing.expect(agent.exec_ask == .off);
    try std.testing.expect(agent.exec_node_id != null);
    try std.testing.expectEqualStrings("node-1", agent.exec_node_id.?);
}

test "slash /queue updates queue settings" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/queue debounce debounce:2s cap:25 drop:newest")).?;
    defer allocator.free(response);

    try std.testing.expect(agent.queue_mode == .debounce);
    try std.testing.expectEqual(@as(u32, 2000), agent.queue_debounce_ms);
    try std.testing.expectEqual(@as(u32, 25), agent.queue_cap);
    try std.testing.expect(agent.queue_drop == .newest);
}

test "slash /usage updates usage mode" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/usage full")).?;
    defer allocator.free(response);

    try std.testing.expect(agent.usage_mode == .full);
}

test "slash /tts updates tts settings" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/tts always provider openai limit 1200 summary on audio off")).?;
    defer allocator.free(response);

    try std.testing.expect(agent.tts_mode == .always);
    try std.testing.expect(agent.tts_provider != null);
    try std.testing.expectEqualStrings("openai", agent.tts_provider.?);
    try std.testing.expectEqual(@as(u32, 1200), agent.tts_limit_chars);
    try std.testing.expect(agent.tts_summary);
    try std.testing.expect(!agent.tts_audio);
}

test "slash /stop handled explicitly" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/stop")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "No active background task") != null);
}

test "slash /approve executes pending bash command" {
    const allocator = std.testing.allocator;

    const shell_impl = try allocator.create(tools_mod.shell.ShellTool);
    shell_impl.* = .{ .workspace_dir = "." };
    const shell_tool = shell_impl.tool();
    defer shell_tool.deinit(allocator);

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = undefined,
        .tools = &.{shell_tool},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    const exec_resp = (try agent.handleSlashCommand("/exec ask=always")).?;
    defer allocator.free(exec_resp);

    const pending_resp = (try agent.handleSlashCommand("/bash echo hello-approve")).?;
    defer allocator.free(pending_resp);
    try std.testing.expect(std.mem.indexOf(u8, pending_resp, "Exec approval required") != null);
    try std.testing.expect(agent.pending_exec_command != null);

    const approve_resp = (try agent.handleSlashCommand("/approve allow-once")).?;
    defer allocator.free(approve_resp);
    try std.testing.expect(std.mem.indexOf(u8, approve_resp, "Approved exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, approve_resp, "hello-approve") != null);
    try std.testing.expect(agent.pending_exec_command == null);
}

test "slash /restart clears runtime command settings" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const think_resp = (try agent.handleSlashCommand("/think high")).?;
    defer allocator.free(think_resp);
    const verbose_resp = (try agent.handleSlashCommand("/verbose full")).?;
    defer allocator.free(verbose_resp);
    const usage_resp = (try agent.handleSlashCommand("/usage full")).?;
    defer allocator.free(usage_resp);
    const tts_resp = (try agent.handleSlashCommand("/tts always provider test-provider")).?;
    defer allocator.free(tts_resp);

    const response = (try agent.handleSlashCommand("/restart")).?;
    defer allocator.free(response);

    try std.testing.expectEqualStrings("Session restarted.", response);
    try std.testing.expect(agent.reasoning_effort == null);
    try std.testing.expect(agent.verbose_level == .off);
    try std.testing.expect(agent.usage_mode == .off);
    try std.testing.expect(agent.tts_mode == .off);
    try std.testing.expect(agent.tts_provider == null);
}

test "turn includes reasoning and usage footer when enabled" {
    const ProviderState = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(_: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{
                .content = try allocator.dupe(u8, "final answer"),
                .tool_calls = &.{},
                .usage = .{ .prompt_tokens = 4, .completion_tokens = 6, .total_tokens = 10 },
                .model = try allocator.dupe(u8, "test-model"),
                .reasoning_content = try allocator.dupe(u8, "thinking trace"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "test";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    var state: u8 = 0;
    const vtable = Provider.VTable{
        .chatWithSystem = ProviderState.chatWithSystem,
        .chat = ProviderState.chat,
        .supportsNativeTools = ProviderState.supportsNativeTools,
        .getName = ProviderState.getName,
        .deinit = ProviderState.deinitFn,
    };
    const provider = Provider{ .ptr = @ptrCast(&state), .vtable = &vtable };

    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = provider,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    const reasoning_cmd = (try agent.handleSlashCommand("/reasoning on")).?;
    defer allocator.free(reasoning_cmd);
    const usage_cmd = (try agent.handleSlashCommand("/usage tokens")).?;
    defer allocator.free(usage_cmd);

    const response = try agent.turn("hello");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Reasoning:\nthinking trace") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "[usage] total_tokens=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "final answer") != null);
}

test "turn refreshes system prompt after workspace markdown change" {
    const ReloadProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(_: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{
                .content = try allocator.dupe(u8, "ok"),
                .tool_calls = &.{},
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "reload-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile(std.Options.debug_io, "SOUL.md", .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "SOUL-V1");
    }

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path.ptr[0 .. tmp_path.len + 1]);
    const workspace = tmp_path[0..tmp_path.len];

    var provider_state: u8 = 0;
    const provider_vtable = Provider.VTable{
        .chatWithSystem = ReloadProvider.chatWithSystem,
        .chat = ReloadProvider.chat,
        .supportsNativeTools = ReloadProvider.supportsNativeTools,
        .getName = ReloadProvider.getName,
        .deinit = ReloadProvider.deinitFn,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = provider,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = workspace,
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    const first = try agent.turn("first");
    defer allocator.free(first);
    try std.testing.expect(agent.history.items.len > 0);
    try std.testing.expectEqual(providers.Role.system, agent.history.items[0].role);
    try std.testing.expect(std.mem.indexOf(u8, agent.history.items[0].content, "SOUL-V1") != null);

    {
        const f = try tmp.dir.createFile(std.Options.debug_io, "SOUL.md", .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "SOUL-V2-UPDATED");
    }

    const second = try agent.turn("second");
    defer allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, agent.history.items[0].content, "SOUL-V2-UPDATED") != null);
}

test "turn refreshes system prompt after TOOLS.md change" {
    const ReloadProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(_: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{
                .content = try allocator.dupe(u8, "ok"),
                .tool_calls = &.{},
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "reload-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile(std.Options.debug_io, "TOOLS.md", .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "TOOLS-V1");
    }

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path.ptr[0 .. tmp_path.len + 1]);
    const workspace = tmp_path[0..tmp_path.len];

    var provider_state: u8 = 0;
    const provider_vtable = Provider.VTable{
        .chatWithSystem = ReloadProvider.chatWithSystem,
        .chat = ReloadProvider.chat,
        .supportsNativeTools = ReloadProvider.supportsNativeTools,
        .getName = ReloadProvider.getName,
        .deinit = ReloadProvider.deinitFn,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = provider,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = workspace,
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    const first = try agent.turn("first");
    defer allocator.free(first);
    try std.testing.expect(agent.history.items.len > 0);
    try std.testing.expectEqual(providers.Role.system, agent.history.items[0].role);
    try std.testing.expect(std.mem.indexOf(u8, agent.history.items[0].content, "TOOLS-V1") != null);

    {
        const f = try tmp.dir.createFile(std.Options.debug_io, "TOOLS.md", .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "TOOLS-V2-UPDATED");
    }

    const second = try agent.turn("second");
    defer allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, agent.history.items[0].content, "TOOLS-V2-UPDATED") != null);
}

test "turn refreshes system prompt after USER.md change" {
    const ReloadProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(_: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{
                .content = try allocator.dupe(u8, "ok"),
                .tool_calls = &.{},
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "reload-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile(std.Options.debug_io, "USER.md", .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "- **Name:** USER-V1");
    }

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path.ptr[0 .. tmp_path.len + 1]);
    const workspace = tmp_path[0..tmp_path.len];

    var provider_state: u8 = 0;
    const provider_vtable = Provider.VTable{
        .chatWithSystem = ReloadProvider.chatWithSystem,
        .chat = ReloadProvider.chat,
        .supportsNativeTools = ReloadProvider.supportsNativeTools,
        .getName = ReloadProvider.getName,
        .deinit = ReloadProvider.deinitFn,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = provider,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = workspace,
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    const first = try agent.turn("first");
    defer allocator.free(first);
    try std.testing.expect(agent.history.items.len > 0);
    try std.testing.expectEqual(providers.Role.system, agent.history.items[0].role);
    try std.testing.expect(std.mem.indexOf(u8, agent.history.items[0].content, "USER-V1") != null);

    {
        const f = try tmp.dir.createFile(std.Options.debug_io, "USER.md", .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "- **Name:** USER-V2-UPDATED");
    }

    const second = try agent.turn("second");
    defer allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, agent.history.items[0].content, "USER-V2-UPDATED") != null);
}

test "exec security deny blocks shell tool execution" {
    const allocator = std.testing.allocator;
    const shell_impl = try allocator.create(tools_mod.shell.ShellTool);
    shell_impl.* = .{ .workspace_dir = "." };
    const shell_tool = shell_impl.tool();
    defer shell_tool.deinit(allocator);

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = undefined,
        .tools = &.{shell_tool},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    const cmd_resp = (try agent.handleSlashCommand("/exec security=deny")).?;
    defer allocator.free(cmd_resp);

    const call = ParsedToolCall{
        .name = "shell",
        .arguments_json = "{\"command\":\"echo hello\"}",
        .tool_call_id = null,
    };
    const result = agent.executeTool(allocator, call);

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "security=deny") != null);
}

test "exec ask always registers pending approval from tool path" {
    const allocator = std.testing.allocator;
    const shell_impl = try allocator.create(tools_mod.shell.ShellTool);
    shell_impl.* = .{ .workspace_dir = "." };
    const shell_tool = shell_impl.tool();
    defer shell_tool.deinit(allocator);

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = undefined,
        .tools = &.{shell_tool},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 2,
        .max_history_messages = 20,
        .auto_save = false,
        .history = .empty,
    };
    defer agent.deinit();

    const cmd_resp = (try agent.handleSlashCommand("/exec ask=always")).?;
    defer allocator.free(cmd_resp);

    const call = ParsedToolCall{
        .name = "shell",
        .arguments_json = "{\"command\":\"echo hello\"}",
        .tool_call_id = null,
    };
    const result = agent.executeTool(allocator, call);

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "approval required") != null);
    try std.testing.expect(agent.pending_exec_command != null);
    try std.testing.expectEqualStrings("echo hello", agent.pending_exec_command.?);
}

test "slash additional commands are handled" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const cmd_list = [_][]const u8{
        "/allowlist",
        "/elevated full",
        "/dock-telegram",
        "/bash echo hi",
        "/approve",
        "/poll",
        "/subagents",
        "/config get model",
        "/skill list",
    };

    for (cmd_list) |cmd| {
        const response_opt = try agent.handleSlashCommand(cmd);
        try std.testing.expect(response_opt != null);
        const response = response_opt.?;
        try std.testing.expect(response.len > 0);
        allocator.free(response);
    }
}

test "non-slash message returns null" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = try agent.handleSlashCommand("hello world");
    try std.testing.expect(response == null);
}

test "slash command with whitespace" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("  /help  ")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "/new") != null);
}

test "Agent streaming fields default to null" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
    };
    defer agent.deinit();

    try std.testing.expect(agent.stream_callback == null);
    try std.testing.expect(agent.stream_ctx == null);
}

// ── Bug regression tests ─────────────────────────────────────────

// Bug 1: /model command should dupe the arg to avoid use-after-free.
// model_name must survive past the stack buffer that held the original message.
test "slash /model dupe prevents use-after-free" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Build message in a buffer that we then invalidate (simulate stack lifetime end)
    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "/model new-model-xyz", .{}) catch unreachable;
    const response = (try agent.handleSlashCommand(msg)).?;
    defer allocator.free(response);

    // Overwrite the source buffer to verify model_name is an independent copy
    @memset(&msg_buf, 0);
    try std.testing.expectEqualStrings("new-model-xyz", agent.model_name);
}

// Bug 2: @intCast on negative i64 duration should not panic.
// Simulate by verifying the @max(0, ...) clamping logic.
test "milliTimestamp negative difference clamps to zero" {
    // Simulate: timer_start is in the future relative to "now" (negative diff)
    const timer_start = @as(i64, 0) + 10_000;
    const diff = @as(i64, 0) - timer_start;
    // diff < 0 here; @max(0, diff) must clamp to 0 without panic
    const clamped = @max(0, diff);
    const duration: u64 = @as(u64, @intCast(clamped));
    try std.testing.expectEqual(@as(u64, 0), duration);
}

test "tool_call_batch_updates_tools_md detects writes to TOOLS.md" {
    const allocator = std.testing.allocator;

    const calls_match = [_]ParsedToolCall{
        .{ .name = "file_write", .arguments_json = "{\"path\":\"TOOLS.md\",\"content\":\"x\"}" },
        .{ .name = "file_edit", .arguments_json = "{\"path\":\"notes/TOOLS.md\",\"old_text\":\"a\",\"new_text\":\"b\"}" },
    };
    try std.testing.expect(Agent.tool_call_batch_updates_tools_md(allocator, &calls_match));

    const calls_no_match = [_]ParsedToolCall{
        .{ .name = "file_write", .arguments_json = "{\"path\":\"README.md\",\"content\":\"x\"}" },
        .{ .name = "memory_store", .arguments_json = "{\"key\":\"pref.tools.file_read_over_cat\",\"content\":\"rule\"}" },
    };
    try std.testing.expect(!Agent.tool_call_batch_updates_tools_md(allocator, &calls_no_match));
}

test "should_skip_tools_memory_store_duplicate skips only tools-related memory_store entries" {
    const allocator = std.testing.allocator;

    const calls = [_]ParsedToolCall{
        .{ .name = "file_edit", .arguments_json = "{\"path\":\"./config/TOOLS.md\",\"old_text\":\"old\",\"new_text\":\"new\"}" },
        .{ .name = "memory_store", .arguments_json = "{\"key\":\"pref.tools.file_read_over_cat\",\"content\":\"Always use file_read\"}" },
        .{ .name = "memory_store", .arguments_json = "{\"key\":\"user.nickname\",\"content\":\"DonPrus\"}" },
        .{ .name = "memory_store", .arguments_json = "{\"key\":\"session.note\",\"content\":\"Rule is documented in TOOLS.md\"}" },
    };

    const batch_updates_tools_md = Agent.tool_call_batch_updates_tools_md(allocator, &calls);
    try std.testing.expect(batch_updates_tools_md);
    try std.testing.expect(Agent.should_skip_tools_memory_store_duplicate(allocator, batch_updates_tools_md, calls[1]));
    try std.testing.expect(!Agent.should_skip_tools_memory_store_duplicate(allocator, batch_updates_tools_md, calls[2]));
    try std.testing.expect(Agent.should_skip_tools_memory_store_duplicate(allocator, batch_updates_tools_md, calls[3]));
    try std.testing.expect(!Agent.should_skip_tools_memory_store_duplicate(allocator, false, calls[1]));
}

test "Agent turn skips duplicate memory_store when TOOLS.md is updated in same batch" {
    const FileWriteProbeTool = struct {
        const Self = @This();
        count: *usize,
        pub const tool_name = "file_write";
        pub const tool_description = "probe";
        pub const tool_params =
            \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
        ;
        pub const vtable = tools_mod.ToolVTable(Self);

        fn tool(self: *Self) Tool {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }

        pub fn execute(self: *Self, _: std.mem.Allocator, _: tools_mod.JsonObjectMap, io: std.Io) !tools_mod.ToolResult {
            _ = io;
            self.count.* += 1;
            return .{ .success = true, .output = "file_write probe ok" };
        }
    };

    const MemoryStoreProbeTool = struct {
        const Self = @This();
        count: *usize,
        pub const tool_name = "memory_store";
        pub const tool_description = "probe";
        pub const tool_params =
            \\{"type":"object","properties":{"key":{"type":"string"},"content":{"type":"string"}},"required":["key","content"]}
        ;
        pub const vtable = tools_mod.ToolVTable(Self);

        fn tool(self: *Self) Tool {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }

        pub fn execute(self: *Self, _: std.mem.Allocator, _: tools_mod.JsonObjectMap, io: std.Io) !tools_mod.ToolResult {
            _ = io;
            self.count.* += 1;
            return .{ .success = true, .output = "memory_store probe ok" };
        }
    };

    const StepProvider = struct {
        const Self = @This();
        call_count: usize = 0,

        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.call_count += 1;

            if (self.call_count == 1) {
                const tool_calls = try allocator.alloc(providers.ToolCall, 2);
                tool_calls[0] = .{
                    .id = try allocator.dupe(u8, "call-file"),
                    .name = try allocator.dupe(u8, "file_write"),
                    .arguments = try allocator.dupe(u8, "{\"path\":\"TOOLS.md\",\"content\":\"Use file_read\"}"),
                };
                tool_calls[1] = .{
                    .id = try allocator.dupe(u8, "call-memory"),
                    .name = try allocator.dupe(u8, "memory_store"),
                    .arguments = try allocator.dupe(u8, "{\"key\":\"pref.tools.file_read_over_cat\",\"content\":\"Use file_read\"}"),
                };
                return .{
                    .content = try allocator.dupe(u8, "applying"),
                    .tool_calls = tool_calls,
                    .usage = .{},
                    .model = try allocator.dupe(u8, "test-model"),
                };
            }

            return .{
                .content = try allocator.dupe(u8, "done"),
                .tool_calls = &.{},
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return true;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "step-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;

    var provider_state = StepProvider{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = StepProvider.chatWithSystem,
        .chat = StepProvider.chat,
        .supportsNativeTools = StepProvider.supportsNativeTools,
        .getName = StepProvider.getName,
        .deinit = StepProvider.deinitFn,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

    var file_write_count: usize = 0;
    var memory_store_count: usize = 0;
    var file_write_tool_impl = FileWriteProbeTool{ .count = &file_write_count };
    var memory_store_tool_impl = MemoryStoreProbeTool{ .count = &memory_store_count };
    const tool_list = [_]Tool{ file_write_tool_impl.tool(), memory_store_tool_impl.tool() };

    var specs = try allocator.alloc(ToolSpec, tool_list.len);
    for (tool_list, 0..) |t, i| {
        specs[i] = .{
            .name = t.name(),
            .description = t.description(),
            .parameters_json = t.parametersJson(),
        };
    }

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = provider,
        .tools = &tool_list,
        .tool_specs = specs,
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 4,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    const response = try agent.turn("update tools guidance");
    defer allocator.free(response);

    try std.testing.expectEqualStrings("done", response);
    try std.testing.expectEqual(@as(usize, 1), file_write_count);
    try std.testing.expectEqual(@as(usize, 0), memory_store_count);
    try std.testing.expectEqual(@as(usize, 2), provider_state.call_count);
}

test "bindMemoryTools wires memory tools to sqlite backend" {
    const allocator = std.testing.allocator;

    var cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .default_model = "test/mock-model",
        .allocator = allocator,
    };

    const tools = try tools_mod.allTools(allocator, cfg.workspace_dir, std.testing.io, .{});
    defer tools_mod.deinitTools(allocator, tools);

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    var mem = sqlite_mem.memory();
    tools_mod.bindMemoryTools(tools, mem);

    const DummyProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator_: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator_.dupe(u8, "");
        }

        fn chat(_: *anyopaque, _: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{};
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "dummy";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    var dummy_state: u8 = 0;
    const provider_vtable = Provider.VTable{
        .chatWithSystem = DummyProvider.chatWithSystem,
        .chat = DummyProvider.chat,
        .supportsNativeTools = DummyProvider.supportsNativeTools,
        .getName = DummyProvider.getName,
        .deinit = DummyProvider.deinitFn,
    };
    const provider_i = Provider{
        .ptr = @ptrCast(&dummy_state),
        .vtable = &provider_vtable,
    };

    var noop = observability.NoopObserver{};
    var agent = try Agent.fromConfig(
        allocator,
        &cfg,
        provider_i,
        tools,
        mem,
        noop.observer(),
        std.testing.io,
    );
    defer agent.deinit();

    const store_tool = find_tool_by_name(tools, "memory_store").?;
    const store_args = try tools_mod.parseTestArgs("{\"key\":\"preference.test\",\"content\":\"123\"}");
    defer store_args.deinit();

    const store_result = try store_tool.execute(allocator, store_args.parsed.value.object, std.testing.io);
    defer if (store_result.output.len > 0) allocator.free(store_result.output);
    try std.testing.expect(store_result.success);
    try std.testing.expect(std.mem.indexOf(u8, store_result.output, "Stored memory") != null);

    const entry = try mem.get(allocator, "preference.test");
    try std.testing.expect(entry != null);
    if (entry) |e| {
        defer e.deinit(allocator);
        try std.testing.expectEqualStrings("123", e.content);
    }

    const recall_tool = find_tool_by_name(tools, "memory_recall").?;
    const recall_args = try tools_mod.parseTestArgs("{\"query\":\"preference.test\"}");
    defer recall_args.deinit();

    const recall_result = try recall_tool.execute(allocator, recall_args.parsed.value.object, std.testing.io);
    defer if (recall_result.output.len > 0) allocator.free(recall_result.output);
    try std.testing.expect(recall_result.success);
    try std.testing.expect(std.mem.indexOf(u8, recall_result.output, "preference.test") != null);
    try std.testing.expect(std.mem.indexOf(u8, recall_result.output, "123") != null);
}

test "Agent tool loop frees dynamic tool outputs" {
    const DynamicOutputTool = struct {
        const Self = @This();
        pub const tool_name = "leak_probe";
        pub const tool_description = "Returns dynamically allocated tool output";
        pub const tool_params = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}";
        pub const vtable = tools_mod.ToolVTable(Self);

        fn tool(self: *Self) Tool {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }

        pub fn execute(_: *Self, allocator: std.mem.Allocator, _: tools_mod.JsonObjectMap, io: std.Io) !tools_mod.ToolResult {
            _ = io;
            return tools_mod.ToolResult.okAlloc(allocator, "dynamic-tool-output");
        }
    };

    const StepProvider = struct {
        const Self = @This();
        call_count: usize = 0,

        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.call_count += 1;

            if (self.call_count == 1) {
                const tool_calls = try allocator.alloc(providers.ToolCall, 1);
                tool_calls[0] = .{
                    .id = try allocator.dupe(u8, "call-1"),
                    .name = try allocator.dupe(u8, "leak_probe"),
                    .arguments = try allocator.dupe(u8, "{}"),
                };

                return .{
                    .content = try allocator.dupe(u8, "Running tool"),
                    .tool_calls = tool_calls,
                    .usage = .{},
                    .model = try allocator.dupe(u8, "test-model"),
                };
            }

            return .{
                .content = try allocator.dupe(u8, "done"),
                .tool_calls = &.{},
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return true;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "step-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;

    var provider_state = StepProvider{};
    const provider_vtable = Provider.VTable{
        .chatWithSystem = StepProvider.chatWithSystem,
        .chat = StepProvider.chat,
        .supportsNativeTools = StepProvider.supportsNativeTools,
        .getName = StepProvider.getName,
        .deinit = StepProvider.deinitFn,
    };
    const provider = Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };

    var tool_impl = DynamicOutputTool{};
    const tool_list = [_]Tool{tool_impl.tool()};

    var specs = try allocator.alloc(ToolSpec, tool_list.len);
    for (tool_list, 0..) |t, i| {
        specs[i] = .{
            .name = t.name(),
            .description = t.description(),
            .parameters_json = t.parametersJson(),
        };
    }

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = provider,
        .tools = &tool_list,
        .tool_specs = specs,
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 4,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    const response = try agent.turn("run tool");
    defer allocator.free(response);

    try std.testing.expectEqualStrings("done", response);
    try std.testing.expectEqual(@as(usize, 2), provider_state.call_count);
}

test "Agent streaming fields can be set" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .io = std.testing.io,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
    };
    defer agent.deinit();

    var ctx: u8 = 42;
    const test_cb: providers.StreamCallback = struct {
        fn cb(_: *anyopaque, _: providers.StreamChunk) void {}
    }.cb;
    agent.stream_callback = test_cb;
    agent.stream_ctx = @ptrCast(&ctx);

    try std.testing.expect(agent.stream_callback != null);
    try std.testing.expect(agent.stream_ctx != null);
}

test "Agent shouldForceActionFollowThrough detects english deferred promise" {
    try std.testing.expect(Agent.shouldForceActionFollowThrough("I'll try again with a different filename now."));
    try std.testing.expect(Agent.shouldForceActionFollowThrough("let me check that and get back in a moment"));
}

test "Agent shouldForceActionFollowThrough detects russian deferred promise" {
    try std.testing.expect(Agent.shouldForceActionFollowThrough("Сейчас попробую переснять и отправить файл."));
    try std.testing.expect(Agent.shouldForceActionFollowThrough("сейчас проверю и вернусь с результатом"));
}

test "Agent shouldForceActionFollowThrough ignores normal final answer" {
    try std.testing.expect(!Agent.shouldForceActionFollowThrough("Вот результат: файл успешно отправлен."));
    try std.testing.expect(!Agent.shouldForceActionFollowThrough("I cannot do that in this environment."));
}
