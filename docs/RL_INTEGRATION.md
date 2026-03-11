# NullClaw + Always-On RL Integration

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        NullClaw (Zig)                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │   Session    │  │    Agent     │  │   Memory     │     │
│  │   Manager    │──▶    Core      │◀──│   (SQLite)   │     │
│  └──────────────┘  └──────┬───────┘  └──────┬───────┘     │
│                           │                  │              │
│                    ┌──────▼──────────────────▼─────┐       │
│                    │      RL Bridge (new)          │       │
│                    │  • Memory sync                │       │
│                    │  • Pattern queries            │       │
│                    │  • Feedback signals           │       │
│                    └──────────────┬────────────────┘       │
└───────────────────────────────────┼─────────────────────────┘
                                    │ HTTP (localhost)
┌───────────────────────────────────┼─────────────────────────┐
│                   Always-On RL (Python)                      │
│                           │                                  │
│         ┌─────────────────┼─────────────────┐               │
│         │                 │                 │                │
│  ┌──────▼──────┐   ┌─────▼──────┐   ┌─────▼──────┐         │
│  │   Memory    │   │Consolidate │   │     RL     │         │
│  │   Server    │◀──│  (30 min)  │──▶│   Server   │         │
│  │  :8888      │   │            │   │  :30000    │         │
│  └─────────────┘   └────────────┘   └────────────┘         │
│                                                             │
│  Features:                                                  │
│  • SQLite memory storage                                    │
│  • Pattern extraction (LLM)                                │
│  • MLX training (Apple Silicon)                            │
│  • Reward-based learning                                    │
└─────────────────────────────────────────────────────────────┘
```

## Integration Modes

### Mode 1: Sidecar (Recommended - Start Here)

**Pros:** Minimal changes, uses Python's MLX, fast iteration
**Cons:** Two languages, HTTP latency

**Implementation:**
1. NullClaw sends conversations to Memory Server
2. Queries learned patterns before responding
3. Sends feedback (user reactions, explicit ratings)
4. Receives training signals from consolidation

### Mode 2: Hybrid

**Pros:** Better performance, shared memory
**Cons:** More complex, IPC overhead

**Implementation:**
1. Shared SQLite database
2. Zig reads patterns directly
3. Python handles training
4. Real-time sync via file watching

### Mode 3: Native (Future)

**Pros:** Single language, maximum performance
**Cons:** Significant development effort

**Implementation:**
1. Port MLX to Zig (or use Zig ML libraries)
2. Implement consolidation in Zig
3. Training runs in NullClaw process

## Phase 1: Sidecar Integration (2-3 days)

### Step 1: Add RL Bridge Module

**File:** `src/rl_bridge.zig`

```zig
const std = @import("std");
const http = std.http;
const json_util = @import("json_util.zig");

pub const RLConfig = struct {
    memory_url: []const u8 = "http://localhost:8888",
    rl_url: []const u8 = "http://localhost:30000",
    enabled: bool = true,
    sync_conversations: bool = true,
    query_patterns: bool = true,
    send_feedback: bool = true,
};

pub const RLBridge = struct {
    allocator: std.mem.Allocator,
    config: RLConfig,
    client: http.Client,
    
    pub fn init(allocator: std.mem.Allocator, config: RLConfig) RLBridge {
        return .{
            .allocator = allocator,
            .config = config,
            .client = http.Client{ .allocator = allocator },
        };
    }
    
    pub fn deinit(self: *RLBridge) void {
        self.client.deinit();
    }
    
    /// Send conversation turn to memory server
    pub fn syncConversation(
        self: *RLBridge,
        session_key: []const u8,
        user_msg: []const u8,
        assistant_msg: []const u8,
    ) !void {
        if (!self.config.enabled or !self.config.sync_conversations) return;
        
        const body = try std.fmt.allocPrint(
            self.allocator,
            \\{{"text":"Session {s} - User: {s} - Assistant: {s}","source":"conversation","importance":0.7}}
        ,
            .{ session_key, user_msg, assistant_msg },
        );
        defer self.allocator.free(body);
        
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/ingest",
            .{self.config.memory_url},
        );
        defer self.allocator.free(url);
        
        _ = try self.httpPost(url, body);
    }
    
    /// Query learned patterns for context
    pub fn queryPatterns(
        self: *RLBridge,
        question: []const u8,
    ) !?[]const u8 {
        if (!self.config.enabled or !self.config.query_patterns) return null;
        
        const body = try std.fmt.allocPrint(
            self.allocator,
            \\{{"question":"{s}","include_insights":true,"limit":5}}
        ,
            .{question},
        );
        defer self.allocator.free(body);
        
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/query",
            .{self.config.memory_url},
        );
        defer self.allocator.free(url);
        
        const response = try self.httpPost(url, body);
        defer self.allocator.free(response);
        
        // Extract patterns from response
        // TODO: Parse JSON and return relevant patterns
        return try self.allocator.dupe(u8, response);
    }
    
    /// Send feedback signal (reward)
    pub fn sendFeedback(
        self: *RLBridge,
        session_id: []const u8,
        turn_id: usize,
        reward: f32,
        hint: ?[]const u8,
    ) !void {
        if (!self.config.enabled or !self.config.send_feedback) return;
        
        const body = if (hint) |h|
            try std.fmt.allocPrint(
                self.allocator,
                \\{{"session_id":"{s}","turn_id":{},"reward":{},"hint":"{s}"}}
            ,
                .{ session_id, turn_id, reward, h },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                \\{{"session_id":"{s}","turn_id":{},"reward":{}}}
            ,
                .{ session_id, turn_id, reward },
            );
        defer self.allocator.free(body);
        
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/feedback",
            .{self.config.rl_url},
        );
        defer self.allocator.free(url);
        
        _ = try self.httpPost(url, body);
    }
    
    fn httpPost(self: *RLBridge, url: []const u8, body: []const u8) ![]u8 {
        _ = self;
        _ = url;
        _ = body;
        // TODO: Implement HTTP POST using std.http.Client
        return error.NotImplemented;
    }
};
```

### Step 2: Integrate with Agent

**File:** `src/agent/root.zig` (modifications)

```zig
const rl_bridge = @import("rl_bridge.zig");

pub const Agent = struct {
    // ... existing fields ...
    rl: ?rl_bridge.RLBridge,
    
    pub fn processMessage(
        self: *Agent,
        allocator: std.mem.Allocator,
        messages: []const ChatMessage,
    ) ![]const u8 {
        // 1. Query learned patterns (if RL enabled)
        var context_hints: ?[]const u8 = null;
        if (self.rl) |*rl| {
            const last_msg = messages[messages.len - 1];
            context_hints = try rl.queryPatterns(last_msg.content);
        }
        defer if (context_hints) |h| allocator.free(h);
        
        // 2. Build system prompt with patterns
        const system_prompt = if (context_hints) |hints|
            try self.buildPromptWithHints(hints)
        else
            self.config.system_prompt;
        
        // 3. Get response from provider
        const response = try self.provider.chat(
            allocator,
            .{
                .messages = messages,
                .system = system_prompt,
            },
            self.config.model,
            self.config.temperature,
        );
        
        // 4. Sync conversation to RL memory
        if (self.rl) |*rl| {
            const user_msg = messages[messages.len - 1].content;
            try rl.syncConversation(
                self.session_key,
                user_msg,
                response.content,
            );
        }
        
        return response.content;
    }
    
    /// Call this when user provides feedback
    pub fn recordFeedback(
        self: *Agent,
        turn_id: usize,
        reward: f32,
        hint: ?[]const u8,
    ) !void {
        if (self.rl) |*rl| {
            try rl.sendFeedback(
                self.session_key,
                turn_id,
                reward,
                hint,
            );
        }
    }
};
```

### Step 3: Add Configuration

**File:** `src/config_types.zig` (additions)

```zig
pub const Config = struct {
    // ... existing fields ...
    
    /// RL integration settings
    rl: ?RLConfig = null,
    
    pub const RLConfig = struct {
        enabled: bool = true,
        memory_url: []const u8 = "http://localhost:8888",
        rl_url: []const u8 = "http://localhost:30000",
        sync_conversations: bool = true,
        query_patterns: bool = true,
        send_feedback: bool = true,
    };
};
```

### Step 4: Add Telegram Feedback Handler

**File:** `src/channels/telegram.zig` (additions)

```zig
/// Handle /reward command for explicit feedback
fn handleRewardCommand(
    self: *TelegramChannel,
    chat_id: i64,
    args: []const u8,
) !void {
    const agent = self.getAgentForChat(chat_id);
    
    // Parse: /reward 0.5 "hint text"
    var reward: f32 = 0.5;
    var hint: ?[]const u8 = null;
    
    // TODO: Parse args
    
    try agent.recordFeedback(
        self.current_turn_id,
        reward,
        hint,
    );
    
    try self.sendMessage(chat_id, "✅ Feedback recorded");
}

/// Auto-detect implicit feedback from reactions
fn handleReaction(
    self: *TelegramChannel,
    chat_id: i64,
    msg_id: i64,
    reaction: []const u8,
) !void {
    const agent = self.getAgentForChat(chat_id);
    
    // Map reactions to rewards
    const reward: f32 = if (std.mem.eql(u8, reaction, "👍")) 1.0
        else if (std.mem.eql(u8, reaction, "👎")) -1.0
        else 0.0;
    
    if (reward != 0.0) {
        try agent.recordFeedback(
            self.getTurnIdForMessage(msg_id),
            reward,
            null,
        );
    }
}
```

## Usage

### Start RL Services

```bash
# Terminal 1: Memory server
cd vibe-paper/always-on-rl
python memory/memory_server.py

# Terminal 2: RL server
python rl/rl_server.py

# Terminal 3: NullClaw
./zig-out/bin/nullclaw gateway
```

### Configuration

**File:** `~/.nullclaw/config.json`

```json
{
  "rl": {
    "enabled": true,
    "memory_url": "http://localhost:8888",
    "rl_url": "http://localhost:30000",
    "sync_conversations": true,
    "query_patterns": true,
    "send_feedback": true
  }
}
```

### Testing

```bash
# Test memory sync
curl -X POST http://localhost:8888/ingest \
  -H "Content-Type: application/json" \
  -d '{"text":"User prefers short answers","source":"feedback"}'

# Query patterns
curl -X POST http://localhost:8888/query \
  -H "Content-Type: application/json" \
  -d '{"question":"What are user preferences?"}'

# Trigger consolidation
curl -X POST http://localhost:8888/consolidate

# View learned patterns
curl http://localhost:30000/patterns
```

## Feedback Signals

### Automatic (Implicit)
- **User continues conversation** → Reward +0.1 (good response)
- **User ignores response** → Reward -0.1 (irrelevant)
- **User reacts 👍** → Reward +1.0
- **User reacts 👎** → Reward -1.0
- **User asks follow-up** → Reward +0.3 (helpful)

### Manual (Explicit)
```
/reward 0.8 "Good explanation"
/reward -0.5 "Too verbose"
/reward 1.0 "Perfect answer"
```

## Pattern Examples

After consolidation, the system learns:

| Pattern | Type | Reward | Usage |
|---------|------|--------|-------|
| "User prefers short answers" | Preference | +0.8 | Adjust response length |
| "Checking file before suggesting works well" | Success | +1.0 | Prioritize file checks |
| "Forgot to check PATH causes failures" | Failure | -1.0 | Always check PATH |
| "Should ask clarifying questions" | Improvement | 0.0 + hint | Add to system prompt |

## Benefits

1. **Continuous Learning** - Gets better with every conversation
2. **Personalized** - Learns individual user preferences
3. **Automatic** - No manual training data needed
4. **Transparent** - Patterns are queryable and debuggable
5. **Safe** - Learning rate controlled, patterns reviewable

## Next Steps

1. ✅ Design integration (this document)
2. ⬜ Implement `rl_bridge.zig` (2 hours)
3. ⬜ Integrate with Agent (2 hours)
4. ⬜ Add Telegram feedback handlers (1 hour)
5. ⬜ Test with real conversations (1 day)
6. ⬜ Monitor consolidation quality (ongoing)
7. ⬜ Optimize pattern queries (as needed)

## Future Enhancements

- **Multi-user patterns** - Learn from all users, apply per-user
- **Pattern versioning** - Track pattern evolution
- **Confidence scores** - Weight patterns by reliability
- **Conflict resolution** - Handle contradictory patterns
- **A/B testing** - Compare pattern effectiveness
- **Export/Import** - Share patterns across instances

## Troubleshooting

**RL services not running:**
```bash
# Check if ports are in use
lsof -i :8888
lsof -i :30000

# Check logs
tail -f vibe-paper/always-on-rl/logs/memory.log
tail -f vibe-paper/always-on-rl/logs/rl.log
```

**No patterns being learned:**
```bash
# Trigger manual consolidation
curl -X POST http://localhost:8888/consolidate

# Check consolidation logs
grep "consolidation" vibe-paper/always-on-rl/logs/*.log
```

**High latency on pattern queries:**
- Reduce `limit` in query
- Add caching in RL Bridge
- Pre-fetch patterns on session start
