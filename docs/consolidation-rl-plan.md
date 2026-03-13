# Consolidation & RL Training System - Implementation Plan

> **Status**: Core module complete (`src/memory/lifecycle/consolidation.zig`)
> **Last Updated**: 2025-03-11
> **Inspired By**: [vibe-paper always-on-rl](https://github.com/Kampouse/vibe-paper/tree/main/always-on-rl)

## Overview

This system implements consolidation-driven pattern extraction with reward signals for continuous learning. Inspired by the vibe-paper's "always-on-rl" architecture, it enables NullClaw to learn from conversations through:

- **Pattern Extraction**: LLM-driven identification of positive/negative/improvement patterns
- **Reward Signals**: +1.0 for positive, -1.0 for negative, 0.0 for improvement patterns
- **Human-in-the-Loop**: Approval workflow for high-risk patterns
- **Training Data**: Exportable samples for RL training pipelines

---

## ✅ Completed

### Core Consolidation Module (`src/memory/lifecycle/consolidation.zig`)

**Types & Structures**
- [x] `ExtractedPattern` - Core pattern with type, description, reward, confidence
- [x] `PatternType` - Enum: positive, negative, improvement
- [x] `ConversationBatch` - Input format for consolidation
- [x] `ConsolidationResult` - Output with patterns + metadata
- [x] `TrainingSample` - State/action/reward tuples for RL

**Core Engine**
- [x] `ConsolidationEngine` - Batch processing with confidence filtering
- [x] `LlmCallback` - Provider-agnostic LLM interface
- [x] `buildConsolidationPrompt()` - Creates pattern extraction prompts
- [x] `parseConsolidationResponse()` - Parses LLM responses into patterns
- [x] `generateTrainingSamples()` - Converts patterns to training data

**Configuration**
```zig
pub const ConsolidationConfig = struct {
    min_conversations: usize = 10,
    max_batch_size: usize = 100,
    min_confidence: f32 = 0.6,
    human_approval_negative: bool = true,
    human_approval_improvement: bool = false,
    max_patterns_per_batch: usize = 20,
    llm_callback: ?LlmCallback = null,
};
```

**Tests**
- [x] 7/7 unit tests passing
- [x] LLM callback integration
- [x] Confidence filtering
- [x] Null callback handling
- [x] Training sample generation

---

## 🚧 Remaining Work

### Phase 1: Provider Integration

**1.1 Create Provider Wrapper**
```zig
// src/memory/lifecycle/consolidation_providers.zig
pub fn createConsolidationCallback(cfg: anytype) LlmCallback {
    // Wraps providers.helpers.completeWithSystem
}
```

- [ ] Implement provider-agnostic callback factory
- [ ] Handle API key resolution
- [ ] Add retry logic for transient failures
- [ ] Support multiple provider backends (OpenAI, Anthropic, Ollama)
- [ ] Add request timeout configuration

**1.2 Integration Tests**
- [ ] Test with real provider (mock server)
- [ ] Verify prompt format compatibility
- [ ] Test error handling (rate limits, timeouts)

---

### Phase 2: Persistence Layer

**2.1 SQLite Schema**
```sql
CREATE TABLE extracted_patterns (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pattern_type TEXT NOT NULL, -- 'positive', 'negative', 'improvement'
    description TEXT NOT NULL,
    reward REAL NOT NULL,
    confidence REAL NOT NULL,
    conversation_id TEXT NOT NULL,
    hint TEXT,
    extracted_at INTEGER NOT NULL,
    approved_at INTEGER,
    approved_by TEXT,
    status TEXT NOT NULL DEFAULT 'pending' -- 'pending', 'approved', 'rejected'
);
CREATE INDEX idx_status ON extracted_patterns(status);
CREATE INDEX idx_type ON extracted_patterns(pattern_type);
```

- [ ] Create migration file for patterns table
- [ ] Implement `PatternStore` interface
- [ ] Add CRUD operations for patterns
- [ ] Implement approval workflow storage
- [ ] Add pattern history/audit log

**2.2 Pattern Storage API**
```zig
pub const PatternStore = struct {
    pub fn store(store: PatternStore, pattern: ExtractedPattern) !void
    pub fn approve(store: PatternStore, id: i64) !void
    pub fn reject(store: PatternStore, id: i64) !void
    pub fn listPending(store: PatternStore) ![]ExtractedPattern
    pub fn getApproved(store: PatternStore, since: i64) ![]ExtractedPattern
};
```

---

### Phase 3: Scheduler Integration

**3.1 Consolidation Scheduler**
```zig
// src/cron_consolidation.zig
pub const ConsolidationScheduler = struct {
    engine: *ConsolidationEngine,
    memory: Memory,

    pub fn tick(self: *Self, now: i64) !ConsolidationResult?;
};
```

- [ ] Implement periodic consolidation job (every 30 minutes)
- [ ] Add conversation batch collection from memory
- [ ] Create cron job entry
- [ ] Add health check endpoint

**3.2 Configuration**
```zig
pub const ConsolidationSchedule = struct {
    enabled: bool = false,
    interval_minutes: u32 = 30,
    min_conversations: usize = 10,
    auto_approve_positive: bool = true,
    auto_approve_improvement: bool = false,
};
```

---

### Phase 4: Safeguards & Rollback

**4.1 Feedback Loop Detection**
```zig
pub const FeedbackLoopDetector = struct {
    recent_rewards: std.ArrayList(f32),
    window_size: usize = 100,
    threshold: f32 = -0.3, // Average reward below this = potential loop

    pub fn addReward(self: *Self, reward: f32) !bool {
        // Returns true if feedback loop detected
    }
};
```

- [ ] Track recent reward averages
- [ ] Detect negative spiral patterns
- [ ] Auto-pause consolidation on loop detection
- [ ] Alert on anomalous patterns

**4.2 Rollback Mechanism**
```zig
pub const PatternRollback = struct {
    pub fn getLastApproved(_: PatternStore) ![]ExtractedPattern
    pub fn rollback(_: PatternStore, to_timestamp: i64) !void
    pub fn createSnapshot(_: PatternStore) !i64
};
```

- [ ] Snapshot pattern database before bulk approval
- [ ] Time-based rollback functionality
- [ ] Rollback reason tracking
- [ ] Confirmation prompts for destructive actions

---

### Phase 5: Training Pipeline

**5.1 Training Data Export**
```zig
pub const TrainingDataExporter = struct {
    pub fn exportPatterns(
        _: Self,
        patterns: []ExtractedPattern,
        format: enum { jsonl, csv, mlx }
    ) ![]u8
};
```

- [ ] Export approved patterns as training samples
- [ ] Format: JSONL for MLX, CSV for analysis
- [ ] Include state/action/reward tuples
- [ ] Add metadata (timestamp, conversation_id)

**5.2 MLX Integration (Future)**
- [ ] Define training data schema for MLX
- [ ] Create batch conversion utility
- [ ] Implement incremental training hooks
- [ ] Model versioning

---

### Phase 6: Agent Integration

**6.1 Memory-to-Consolidation Bridge**
```zig
// In agent/root.zig or new file
pub const AgentConsolidator = struct {
    pub fn collectConversations(
        agent: *Agent,
        since: i64,
        limit: usize
    ) ![]ConversationBatch
};
```

- [ ] Collect recent conversations from agent memory
- [ ] Filter by quality/length
- [ ] Anonymize sensitive data before consolidation
- [ ] Respect user privacy settings

**6.2 Pattern Application**
- [ ] Load approved patterns into agent context
- [ ] Inject patterns into system prompt
- [ ] Prioritize by recency and confidence
- [ ] Pattern expiry (old patterns fade)

---

### Phase 7: CLI & Monitoring

**7.1 Consolidation Commands**
```bash
nc tools consolidation status        # Show pending patterns
nc tools consolidation approve <id>  # Approve a pattern
nc tools consolidation reject <id>   # Reject a pattern
nc tools consolidation run           # Trigger manual consolidation
nc tools consolidation export        # Export training data
nc tools consolidation rollback      # Rollback to snapshot
```

- [ ] Implement CLI tool commands
- [ ] Add interactive approval UI
- [ ] Pattern statistics dashboard
- [ ] Export functionality

**7.2 Observability**
```zig
pub const ConsolidationMetrics = struct {
    patterns_extracted: usize,
    patterns_approved: usize,
    patterns_rejected: usize,
    average_confidence: f32,
    average_reward: f32,
    feedback_loop_detected: bool,
};
```

- [ ] Metrics endpoint
- [ ] Log pattern extraction events
- [ ] Alert on suspicious patterns
- [ ] Performance monitoring

---

### Phase 8: Documentation & Examples

**8.1 Documentation**
- [ ] User guide for consolidation workflow
- [ ] Pattern approval best practices
- [ ] Configuration reference
- [ ] API documentation

**8.2 Examples**
- [ ] End-to-end consolidation example
- [ ] Custom callback implementation
- [ ] Training pipeline setup
- [ ] Rollback scenarios

---

## 📊 Priority Matrix

| Phase | Priority | Dependencies | Est. Effort |
|-------|----------|--------------|-------------|
| 1. Provider Integration | **HIGH** | None | 2-3 days |
| 2. Persistence Layer | **HIGH** | None | 2-3 days |
| 3. Scheduler Integration | MEDIUM | 1, 2 | 1-2 days |
| 4. Safeguards & Rollback | **HIGH** | 2 | 2-3 days |
| 5. Training Pipeline | LOW | 2, 4 | 1-2 days |
| 6. Agent Integration | MEDIUM | 1, 2 | 2-3 days |
| 7. CLI & Monitoring | MEDIUM | 2, 4 | 2-3 days |
| 8. Documentation | LOW | All | 1-2 days |

**Total Estimated Effort: 13-21 days**

---

## 🎯 Quick Start (MVP)

For a minimal viable consolidation system:

1. **Provider Integration** (Phase 1)
2. **Persistence Layer** (Phase 2 - basic CRUD only)
3. **Manual Consolidation** (skip scheduler, use CLI trigger)
4. **Basic Approval** (CLI commands only)

**MVP Estimation: 4-6 days**

This gives you:
- ✅ Pattern extraction via LLM
- ✅ Pattern storage in SQLite
- ✅ Manual approval workflow
- ✅ Training data export

---

## 🔐 Security Considerations

- [ ] Sanitize conversation data before sending to LLM
- [ ] Redact PII/secrets in consolidation prompts
- [ ] Encrypt sensitive patterns at rest
- [ ] Audit log for all pattern approvals
- [ ] Rate limiting for consolidation jobs
- [ ] Input validation for pattern rewards (-1.0 to 1.0)

---

## 🧪 Testing Strategy

- [ ] Unit tests for all new modules
- [ ] Integration tests with mock LLM
- [ ] End-to-end tests with real provider
- [ ] Stress tests (large conversation batches)
- [ ] Failure mode tests (API failures, DB errors)
- [ ] Regression tests for feedback loop detection

---

## 📖 References

- [vibe-paper always-on-rl](https://github.com/Kampouse/vibe-paper/tree/main/always-on-rl) - Original inspiration
- `src/memory/lifecycle/summarizer.zig` - Existing summarization infrastructure
- `src/providers/helpers.zig` - LLM completion utilities
- `src/cron.zig` - Scheduler integration

---

## 🚀 Usage Example

```zig
const std = @import("std");
const consolidation = @import("memory/lifecycle/consolidation.zig");

// Define LLM callback
fn myLlmCallback(allocator: std.mem.Allocator, prompt: []const u8) anyerror![]const u8 {
    // Use providers.helpers.completeWithSystem or similar
    return completeWithSystem(allocator, cfg,
        "You are a conversation analyst. Extract actionable patterns.",
        prompt
    );
}

// Configure and run
const config = consolidation.ConsolidationConfig{
    .llm_callback = myLlmCallback,
    .min_confidence = 0.7,
    .human_approval_negative = true,
};

var engine = consolidation.ConsolidationEngine.init(allocator, config);
defer engine.deinit();

// Prepare conversation batches
const batches = &[_]consolidation.ConversationBatch{
    // ... your conversations here
};

// Extract patterns
const result = try engine.processBatch(batches);
defer result.deinit(allocator);

// Process patterns
for (result.patterns) |pattern| {
    std.log.info("Pattern: {s} (reward: {d:.1}, confidence: {d:.1})",
        .{pattern.description, pattern.reward, pattern.confidence}
    );
}
```

---

*This plan is a living document. Update as implementation progresses.*
