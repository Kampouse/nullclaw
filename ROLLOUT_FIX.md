# Rollout Mode Fix

## Issue
The gateway was running but not processing Telegram messages. The root cause was that `rollout_mode` was set to `"off"` in the configuration.

## Solution
Changed `rollout_mode` from `"off"` to `"on"` in `~/.nullclaw/config.json`:

```json
"reliability": {
  "rollout_mode": "on",  // Changed from "off"
  "circuit_breaker_failures": 5,
  "circuit_breaker_cooldown_ms": 30000,
  "shadow_hybrid_percent": 0,
  "canary_hybrid_percent": 0,
  "fallback_policy": "degrade"
}
```

## Impact
- **Before**: `rollout decide: mode=off decision=keyword_only` (messages not processed)
- **After**: `rollout decide: mode=on decision=hybrid` (messages processed by agent)

## Verification
The gateway now processes Telegram messages with the agent:
- Messages are received and acknowledged
- Agent generates responses using the LLM (minimax-m2.5 via ollama-cloud)
- Rollout system uses hybrid mode (keyword + vector search)

## Note
This configuration file is not tracked in git (it's user-specific), so this change needs to be made manually on each system.
