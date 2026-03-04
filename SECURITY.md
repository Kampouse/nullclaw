# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in nullclaw, please report it responsibly:

1. **Do not** open a public issue
2. Use [GitHub private vulnerability reporting](https://github.com/nullclaw/nullclaw/security/advisories/new)

We will respond within 48 hours and work on a fix promptly.

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest release | Yes |
| Older releases | No |

---

# Gork P2P Agent Collaboration Security

## Overview

The Gork P2P agent collaboration system enables autonomous AI agents to discover peers, verify reputation, send messages, and execute tasks across a decentralized network with NEAR blockchain trust verification.

## Security Architecture

### Input Validation

All inputs are validated before processing:

- **Agent IDs**: `[a-zA-Z0-9._-]+`, max 64 characters
- **Capabilities**: `[a-zA-Z0-9_-]+`, max 128 characters
- **Messages**: Printable ASCII + UTF-8, max 10KB
- **Binary Paths**: No directory traversal (`..`), must be regular files

### Reputation System

- **min_reputation**: 50 (default) - Minimum reputation to interact
- **block_below_reputation**: 20 (default) - Block agents below this threshold
- All reputation checks logged as audit events

### Circuit Breaker Pattern

Prevents cascading failures from misbehaving peers:

- Opens after 5 consecutive failures
- Stays open for 60 seconds
- Tests recovery with 3 probe requests in half-open state

### Rate Limiting

Per-agent request limits to prevent abuse:

- **Default**: 100 requests per minute per agent
- **Window**: 60 second sliding window
- **Cleanup**: Automatic after 1000 entries

### Binary Verification

**Status**: Partially Implemented (SHA-256 hash computation, Ed25519 pending)

- Detects `.sig` file alongside binary
- Computes SHA-256 hash for manual verification
- Full Ed25519 verification pending Zig 0.15.2 API stabilization

### Replay Attack Protection

**Status**: ✅ Implemented

- **Timestamp validation**: Messages older than `max_message_age_secs` (default: 300s) are rejected
- **Seen-message cache**: SHA-256 based deduplication prevents processing duplicate messages
- **Thread-safe cache**: Mutex-protected cache with automatic cleanup of expired entries
- **Configurable limits**: `seen_message_cache_size` controls memory usage (default: 10000 entries)
- **Audit logging**: All replay attack attempts logged as `SECURITY_VIOLATION` events

Configuration options:
```json
{
  "gork": {
    "enable_replay_protection": true,
    "max_message_age_secs": 300,
    "seen_message_cache_size": 10000
  }
}
```

### Audit Logging

All security events are logged with format: `AUDIT: <EVENT_TYPE> <details>`

Event types:
- `DAEMON_STARTED`: Daemon process started
- `DAEMON_STOPPED`: Daemon process stopped
- `MESSAGE_SENT`: Message sent to peer
- `MESSAGE_RECEIVED`: Message received from peer
- `AGENT_DISCOVERED`: Peer discovered via capability search
- `INVALID_INPUT`: Input validation failed
- `SUSPICIOUS_ACTIVITY`: Abnormal behavior detected
- `SECURITY_VIOLATION`: Security policy violation

### Metrics Collection

Security-relevant metrics available via `{"action": "metrics"}`:

- `messages_sent/failed`: Message success/failure rates
- `reputation_checks`: Reputation verification count
- `security_violations`: Security event count
- `circuit_breaker_trips`: Circuit breaker openings
- `queue_size/max`: Message queue utilization

## Configuration Security

### Required Settings

```json
{
  "gork": {
    "enabled": true,
    "binary_path": "/path/to/gork-agent",
    "account_id": "your-agent.near",
    "min_reputation": 50,
    "block_below_reputation": 20
  }
}
```

### Validation Rules

| Error | Condition |
|-------|-----------|
| `MissingGorkBinaryPath` | `binary_path` empty when enabled |
| `MissingGorkAccountId` | `account_id` null when enabled |
| `GorkTimeoutTooLarge` | `max_process_timeout_secs > 300` |
| `InvalidReputationThreshold` | `block_below_reputation >= min_reputation` |

## Threat Mitigation

| Threat | Mitigation | Status |
|--------|-----------|--------|
| Message flooding | Per-agent rate limiting (100 req/min) | ✅ |
| Replay attacks | Timestamp validation + seen-message cache | ✅ |
| Sybil attacks | NEAR blockchain identity | ✅ |
| Directory traversal | Path validation, no `..` allowed | ✅ |
| Buffer overflows | Length limits on all inputs | ✅ |
| Resource exhaustion | Circuit breaker + queue limits | ✅ |
| Binary tampering | SHA-256 hash logging | ⚠️ Ed25519 pending |

## Operational Security

### Environment Variables

- `GORK_PUBLIC_KEY`: Ed25519 public key for binary verification (optional)

### File Permissions

```bash
chmod 755 /usr/local/bin/gork-agent        # Executable binary
chmod 644 /usr/local/bin/gork-agent.sig      # Signature file
chmod 700 ~/.nullclaw/                      # Config directory
chmod 600 ~/.nullclaw/config.json           # Config file
```

### Monitoring Recommendations

Alert on:
- Security violations > 10/hour
- Circuit breaker trips > 5/hour
- Queue size > 800 messages
- Failed message rate > 10%

## Security Best Practices

### For Operators

1. Keep `gork-agent` updated with security patches
2. Review audit logs regularly for suspicious activity
3. Configure appropriate rate limits for your environment
4. Enable binary verification when `GORK_PUBLIC_KEY` is available
5. Run gork-agent in isolated network when possible

### For Developers

1. Always validate untrusted inputs
2. Never expose internal details in error messages
3. Log all security-relevant events
4. Run tests before committing: `zig test src/gork_test.zig`
5. Peer review all security-related changes

## Testing

Security tests are located in `src/gork_test.zig`:

```bash
# Run all Gork security tests
zig test src/gork_test.zig

# Run specific test category
zig test src/gork_test.zig --test-filter "validateAgentId"
zig test src/gork_test.zig --test-filter "RateLimiter"
zig test src/gork_test.zig --test-filter "CircuitBreaker"
```

## Implementation Details

### Key Files

- `src/gork_hybrid.zig`: Core hybrid system with security features
- `src/gork_daemon.zig`: libp2p daemon implementation
- `src/gork_poller.zig`: Fallback poller with rate limiting
- `src/tools/gork.zig`: Tool interface for agents

### Security Constants

```zig
pub const MAX_AGENT_ID_LEN = 64;
pub const MAX_MESSAGE_LEN = 1024 * 10; // 10KB
pub const MAX_CAPABILITY_LEN = 128;
pub const MAX_BINARY_PATH_LEN = 256;
pub const DEFAULT_PROCESS_TIMEOUT_MS = 30000; // 30 seconds
```

## References

- Implementation: `src/gork_hybrid.zig`
- Tests: `src/gork_test.zig`
- Integration: `src/tools/gork.zig`

