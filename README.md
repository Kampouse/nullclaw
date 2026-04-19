# Kampouse/nullclaw

A fork of [nullclaw/nullclaw](https://github.com/nullclaw/nullclaw) with custom infrastructure for Nostr-based agent coordination, P2P messaging, and hardened gateway operations.

**Based on:** `v2026.3.1` (336 commits ahead of upstream `v2026.4.17` branch point)
**Zig:** 0.16.0 (stable) | **Tests:** 5,008 passing

---

## What's Different

### Added: Nostr Native Stack

Full Nostr protocol implementation in pure Zig — zero external dependencies beyond std crypto.

| Component | File | What it does |
|---|---|---|
| **Nostr library** | `src/nostr.zig` | BIP-340 Schnorr signing, event construction (kinds 0/1/3), relay client via websocket, NIP-04 encrypted DMs, NIP-59 gift wrap |
| **Nostr tool** | `src/tools/nostr.zig` | Agent tool: `post`, `read`, `reply`, `search`, `profile` — lets the agent publish notes and interact on Nostr natively |
| **Nostr email** | `src/tools/nostr_email.zig` | Sealed email via NIP-59 Gift Wrap (kind 1301). Send/receive encrypted emails through Nostr relays |
| **npubEncode** | `src/nostr.zig` | Bech32 encoding for public keys. Fixed 3 bugs from upstream: array sizing, u5 underflow, version byte handling |

### Added: Gork P2P Agent Coordination

Hybrid daemon + polling system for real-time agent-to-agent collaboration.

| Component | File | What it does |
|---|---|---|
| **Gork daemon** | `src/gork_daemon.zig` | Long-lived background process for P2P message routing |
| **Gork hybrid** | `src/gork_hybrid.zig` | Combines daemon (real-time) with polling fallback for crash recovery |
| **Gork poller** | `src/gork_poller.zig` | Polling-based message retrieval when daemon is unavailable |
| **Gork QUIC** | `src/gork_quic_client.zig` | QUIC transport for low-latency P2P connections |
| **Gork websocket** | `src/gork_websocket.zig` | WebSocket transport fallback |
| **Gork tool** | `src/tools/gork.zig` | Agent tool for sending messages to other agents |

### Added: Hardened Gateway HTTP Stack

Replaced the upstream's fixed-size stack buffers with a production-grade HTTP handling layer.

| What | Detail |
|---|---|
| **`readFullRequest`** | Content-Length aware reading with dynamic allocation. Replaces single `readSocket` into 4KB buffer that silently truncated POST bodies >3.5KB |
| **`writeAllSocket`** | Partial write loop. Replaces single `writeSocket` that could silently truncate large responses |
| **Dynamic response buffer** | `ArrayListUnmanaged` heap allocation. Replaces 8KB stack buffer that dropped responses >7.5KB |
| **Request timeout** | 30s `SO_RCVTIMEO` on client sockets. Prevents hung connections from blocking the single-threaded accept loop |
| **Concurrent eval guard** | Atomic counter returns 503 when an eval is already in flight. Ready for future threading |
| **CORS preflight** | Handles OPTIONS with proper `Access-Control-*` headers. Enables browser-based clients |
| **Access logging** | Every request logs `http METHOD /path -> STATUS (N bytes)` at info level |

### Added: Observability & Diagnostics

| Component | File | What it does |
|---|---|---|
| **Structured logging** | `src/structured_log.zig` | JSON-formatted logs for Grafana/Loki ingestion |
| **Tracing** | `src/trace.zig`, `src/trace_simple.zig` | Request tracing with span timing |
| **Profiling** | `src/profiling.zig` | Memory and CPU profiling hooks |
| **Self-diagnose** | `src/tools/self_diagnose.zig` | Agent tool: runtime health check |
| **Self-update** | `src/tools/self_update.zig` | Agent tool: git pull + rebuild |
| **Worker pool** | `src/worker_pool.zig` | Thread-safe parallel message processing |

### Added: Session & Infrastructure

| Component | File | What it does |
|---|---|---|
| **Git sessions** | `src/session_git.zig` | Content-addressable session model (each turn = immutable commit, threads = branches) |
| **Async session** | `src/async_session.zig` | Non-blocking session management |
| **Spinlock** | `src/spinlock.zig` | Lock-free synchronization primitive |
| **Direct socket layer** | `src/net_socket.zig` | BSD socket externs bypassing Zig 0.16 I/O subsystem race conditions |
| **Child compat** | `src/child_compat.zig` | Process spawning compatibility layer |

### Added: Extra Tools

| Tool | File | What it does |
|---|---|---|
| **Web scraper** | `src/tools/web_scrape.zig` | Embedded HTML-to-markdown converter, no external APIs |
| **Cargo** | `src/tools/cargo.zig` | Rust project management |
| **Zig build** | `src/tools/zig_build.zig` | Zig project compilation |
| **Process allocator** | `src/tools/process_allocator.zig` | Memory allocation inspection |

### Fixed: Reliability Audit

37 critical `catch {}` error swallows replaced with scoped warn logging across 12 files:

- **Cron saves** (14 sites) — `cron_add`, `cron_remove`, `cron_update`, `cron_run`, `schedule` now log when job persistence fails
- **Session persistence** (4 sites) — `session.zig` now logs when user/assistant messages fail to save
- **Daemon state** (2 sites) — `daemon.zig` now logs when state file writes fail
- **Channel replies** (10 sites) — `gateway.zig` now logs when Telegram, Slack, Line, Lark, QQ reply sends fail
- **File I/O** (4 sites) — `file_write.zig`, `config_mutator.zig` now log mkdir/backup failures
- **HTTP writes** (3 sites) — gateway response sends now logged on failure

### Fixed: Compaction Quality

- Per-message transcript limit raised from 500 → 1500 characters (preserves tool results, npubs, file paths in summaries)
- Summary prompt improved to explicitly preserve identifiers, key facts, and tool output summaries

---

## What's in Upstream but Not Here

The upstream `v2026.4.17` release includes features added after our fork point:

| Feature | Status |
|---|---|
| **A2A protocol** (`a2a.zig`) | Google's Agent-to-Agent protocol v0.3.0 — not yet merged |
| **Control plane** (`control_plane.zig`) | Slash command infrastructure — not yet merged |
| **MCP admin** (`mcp_admin.zig`) | MCP server management CLI — not yet merged |
| **Channel probe** (`channel_probe.zig`) | Credential validation for channels — not yet merged |
| **Inbound debounce** (`inbound_debounce.zig`) | Message deduplication — not yet merged |
| **Channel admin** (`channel_admin.zig`) | Channel configuration CLI — not yet merged |
| **File hashing** (`file_edit_hashed.zig`, `file_read_hashed.zig`) | Content-addressed file ops — not yet merged |
| **Cron gateway** (`cron_gateway.zig`) | HTTP-triggered cron jobs — not yet merged |

---

## Build & Run

```bash
# Requires Zig 0.16.0 (stable)
git clone https://github.com/Kampouse/nullclaw.git
cd nullclaw
zig build -Doptimize=ReleaseSmall
zig build test
```

**Background daemon (recommended):**

```bash
make start    # Start in background (nohup)
make stop     # Stop
make restart  # Stop, build, start
make status   # Check if running
make logs     # Tail log file
```

**Never run the binary directly in foreground** — it blocks indefinitely. Always use `make start`.

**Test the gateway:**

```bash
curl -s -X POST http://127.0.0.1:3000/eval \
  -H 'Content-Type: application/json' \
  -d '{"message":"Say hello","session_id":"test"}'
```

---

## Upstream Comparison

| | Upstream nullclaw | This fork |
|---|---|---|
| **Base** | `v2026.4.17` | `v2026.3.1` + 336 commits |
| **Zig** | 0.16.0 | 0.16.0 |
| **Nostr** | Channel adapter only | Full native stack (sign, post, read, DM, NIP-59) |
| **P2P agents** | Not available | Gork hybrid daemon + polling |
| **Gateway HTTP** | Fixed 4KB/8KB buffers | Dynamic allocation, timeout, CORS, access logs |
| **Error visibility** | ~290 silent `catch {}` | 37 critical sites now log warnings |
| **Observability** | std.log | Structured JSON logging (Loki-compatible) + tracing |
| **A2A protocol** | Available | Not yet merged |
| **Control plane** | Available | Not yet merged |
