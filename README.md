# Kampouse/nullclaw

A fork of [nullclaw/nullclaw](https://github.com/nullclaw/nullclaw) focused on Nostr-native agent identity, P2P coordination, and production-hardened gateway operations.

**Base:** `v2026.3.1` | **Zig:** 0.16.0 (stable) | **Tests:** 5,008 passing | **25 unique files, 10 unique tools**

---

## Fork Comparison

### At a Glance

| | Upstream `nullclaw/nullclaw` | This fork `Kampouse/nullclaw` |
|---|---|---|
| **Version** | `v2026.4.17` | `v2026.3.1` + 336 commits |
| **Zig files** | 274 | 256 |
| **Lines of code** | — | 180,230 |
| **Providers** | 23 (Anthropic, Gemini, OpenAI, OpenRouter, Ollama, Claude CLI, Codex CLI, Vertex, Gemini CLI) | 19 (same minus Vertex, Gemini CLI) |
| **Channels** | 38 (Telegram, Discord, Slack, Signal, WhatsApp, Matrix, IRC, Line, Lark, QQ, Teams, WeChat/WeCom, Weixin, Max, Email, iMessage, DingTalk, MaixCam, Mattermost, OneBot, Nostr, External) | 22 (same minus Teams, WeChat/WeCom, Weixin, Max, External, Telegram API refactor) |
| **Tools** | 48 | 47 |
| **Nostr** | Channel adapter (send/receive via relay) | Full native stack: BIP-340 signing, event construction, relay client, NIP-04 DM, NIP-59 Gift Wrap, npubEncode (3 bugfixes) |
| **P2P agents** | Not available | Gork hybrid system (daemon + polling fallback + QUIC + WebSocket) |
| **Gateway HTTP** | Fixed 4KB request / 8KB response stack buffers, no timeout, no CORS | Dynamic allocation, Content-Length parsing, partial write handling, 30s timeout, 503 concurrent guard, CORS preflight, access logging |
| **Error handling** | ~290 silent `catch {}` across codebase | 37 critical sites fixed with scoped warn logging |
| **Observability** | `std.log` | Structured JSON logging (Grafana/Loki), request tracing, profiling hooks |
| **Session model** | Standard key-value | Standard + content-addressable git-like sessions (immutable commits, branching) |
| **A2A protocol** | Google A2A v0.3.0 via `a2a.zig` | Not yet merged from upstream |
| **Control plane** | Slash command infrastructure via `control_plane.zig` | Not yet merged from upstream |
| **MCP admin** | MCP server management via `mcp_admin.zig` | Not yet merged from upstream |

### Feature Matrix

| Feature | Upstream | Fork | Notes |
|---|:---:|:---:|---|
| **Nostr signing** (BIP-340 Schnorr) | — | ✓ | Pure Zig, zero deps beyond std crypto |
| **Nostr event construction** (kinds 0/1/3) | — | ✓ | Native, not via relay adapter |
| **Nostr relay client** (subscribe, publish) | ✓ (channel adapter) | ✓ (native library) | Fork version has direct websocket control |
| **Nostr NIP-04** (encrypted DMs) | — | ✓ | Sealed direct messages |
| **Nostr NIP-59** (Gift Wrap) | — | ✓ | Used for sealed email (kind 1301) |
| **Nostr email** (kind 1301) | — | ✓ | Send/receive encrypted emails via relays |
| **P2P agent messaging** | — | ✓ | Gork hybrid daemon + polling |
| **QUIC transport** | — | ✓ | Low-latency P2P connections |
| **WebSocket P2P transport** | — | ✓ | Fallback transport |
| **Gateway dynamic buffers** | — | ✓ | Replaces fixed 4KB/8KB stack buffers |
| **Gateway Content-Length parsing** | — | ✓ | Proper HTTP body reading |
| **Gateway partial write handling** | — | ✓ | `writeAllSocket` loop |
| **Gateway request timeout** | — | ✓ | 30s `SO_RCVTIMEO` |
| **Gateway concurrent eval guard** | — | ✓ | Atomic counter + 503 |
| **Gateway CORS preflight** | — | ✓ | OPTIONS handler with proper headers |
| **Gateway access logging** | — | ✓ | `http METHOD /path -> STATUS (N bytes)` |
| **Structured JSON logging** | — | ✓ | Loki/Grafana compatible |
| **Request tracing** | — | ✓ | Span timing |
| **Memory/CPU profiling** | — | ✓ | Profiling hooks |
| **Self-diagnose tool** | — | ✓ | Runtime health check |
| **Self-update tool** | — | ✓ | Git pull + rebuild |
| **Git-like sessions** | — | ✓ | Content-addressable, immutable commits |
| **Worker pool** | — | ✓ | Thread-safe parallel message processing |
| **Web scraper** (HTML→markdown) | — | ✓ | Embedded, no external APIs |
| **Cargo tool** (Rust) | — | ✓ | Rust project management |
| **Zig build tool** | — | ✓ | Zig project compilation |
| **Error visibility audit** | — | ✓ | 37 critical `catch {}` → warn logging |
| **Compaction quality fix** | — | ✓ | 500→1500 char limit, better prompt |
| **A2A protocol** (Google v0.3.0) | ✓ | — | Not yet merged |
| **Control plane** (slash commands) | ✓ | — | Not yet merged |
| **MCP admin** | ✓ | — | Not yet merged |
| **Channel probe** (credential validation) | ✓ | — | Not yet merged |
| **Inbound debounce** (dedup) | ✓ | — | Not yet merged |
| **Channel admin** (config CLI) | ✓ | — | Not yet merged |
| **Content-addressed file ops** | ✓ | — | Not yet merged |
| **Cron gateway** (HTTP trigger) | ✓ | — | Not yet merged |
| **Vertex AI provider** | ✓ | — | Not yet merged |
| **Gemini CLI provider** | ✓ | — | Not yet merged |
| **Teams channel** | ✓ | — | Not yet merged |
| **WeChat/WeCom/Weixin** | ✓ | — | Not yet merged |
| **Max channel** | ✓ | — | Not yet merged |
| **External channel protocol** | ✓ | — | Not yet merged |
| **Telegram API refactor** (ingress split) | ✓ | — | Not yet merged |
| **Calculator tool** | ✓ | — | Not yet merged |
| **File delete tool** | ✓ | — | Not yet merged |
| **File hashed tools** | ✓ | — | Not yet merged |

### Tool Comparison

| Tool | Upstream | Fork |
|---|:---:|:---:|
| browser | ✓ | ✓ |
| browser_open | ✓ | ✓ |
| calculator | ✓ | — |
| cargo | — | ✓ |
| composio | ✓ | ✓ |
| cron_add | ✓ | ✓ |
| cron_gateway | ✓ | — |
| cron_list | ✓ | ✓ |
| cron_remove | ✓ | ✓ |
| cron_run | ✓ | ✓ |
| cron_runs | ✓ | ✓ |
| cron_update | ✓ | ✓ |
| delegate | ✓ | ✓ |
| file_append | ✓ | ✓ |
| file_common | ✓ | — |
| file_delete | ✓ | — |
| file_edit | ✓ | ✓ |
| file_edit_hashed | ✓ | — |
| file_read | ✓ | ✓ |
| file_read_hashed | ✓ | — |
| file_write | ✓ | ✓ |
| git | ✓ | ✓ |
| gork | — | ✓ |
| hardware_info | ✓ | ✓ |
| hardware_memory | ✓ | ✓ |
| http_request | ✓ | ✓ |
| i2c | ✓ | ✓ |
| image | ✓ | ✓ |
| memory_forget | ✓ | ✓ |
| memory_list | ✓ | ✓ |
| memory_recall | ✓ | ✓ |
| memory_store | ✓ | ✓ |
| message | ✓ | ✓ |
| nostr | — | ✓ |
| nostr_email | — | ✓ |
| path_security | ✓ | ✓ |
| process_allocator | — | ✓ |
| process_util | ✓ | ✓ |
| pushover | ✓ | ✓ |
| schedule | ✓ | ✓ |
| schema | ✓ | ✓ |
| screenshot | ✓ | ✓ |
| self_diagnose | — | ✓ |
| self_update | — | ✓ |
| shell | ✓ | ✓ |
| spawn | ✓ | ✓ |
| spi | ✓ | ✓ |
| test_demo | — | ✓ |
| web_fetch | ✓ | ✓ |
| web_scrape | — | ✓ |
| web_search | ✓ | ✓ |
| zig_build | — | ✓ |

---

## What This Fork Adds

### Nostr Native Stack

Full Nostr protocol in pure Zig — not just a channel adapter, but a complete signing/relay/event library.

- **`src/nostr.zig`** — BIP-340 Schnorr signing, bech32 (npub/nsec) encoding with 3 upstream bugfixes (array sizing, u5 underflow, version byte), event construction for kinds 0/1/3, relay websocket client, NIP-04 encrypted DMs, NIP-59 Gift Wrap
- **`src/tools/nostr.zig`** — Agent-facing tool: `post`, `read`, `reply`, `search`, `profile` actions
- **`src/tools/nostr_email.zig`** — Sealed email via NIP-59 (kind 1301), send and receive through Nostr relays

### Gork P2P Agent Coordination

Hybrid daemon + polling for real-time agent-to-agent messaging.

- **`src/gork_daemon.zig`** — Long-lived P2P message routing daemon
- **`src/gork_hybrid.zig`** — Real-time daemon with automatic polling fallback
- **`src/gork_poller.zig`** — Polling retrieval when daemon is down
- **`src/gork_quic_client.zig`** — QUIC transport
- **`src/gork_websocket.zig`** — WebSocket transport fallback
- **`src/tools/gork.zig`** — Agent tool for inter-agent messaging

### Hardened Gateway HTTP

Replaced fixed-size stack buffers with production-grade handling.

- **`readFullRequest`** — Content-Length aware, dynamic allocation (replaces 4KB truncation)
- **`writeAllSocket`** — Partial write loop (replaces single-write truncation)
- **Dynamic response buffer** — `ArrayListUnmanaged` heap allocation (replaces 8KB stack limit)
- **30s request timeout** — `SO_RCVTIMEO` on client sockets
- **Concurrent eval guard** — Atomic counter, returns 503 when busy
- **CORS preflight** — OPTIONS handler with `Access-Control-*` headers
- **Access logging** — `http METHOD /path -> STATUS (N bytes)` at info level

### Reliability & Observability

- **37 critical `catch {}` fixes** — Cron saves, session persists, channel replies, HTTP writes now log warnings instead of silently failing
- **Structured logging** (`src/structured_log.zig`) — JSON logs for Grafana/Loki
- **Request tracing** (`src/trace.zig`) — Span timing
- **Profiling** (`src/profiling.zig`) — Memory and CPU hooks
- **Compaction quality** — 500→1500 char transcript limit, improved summary prompt

### Session & Infrastructure

- **Git-like sessions** (`src/session_git.zig`) — Content-addressable, immutable commits, branching
- **Worker pool** (`src/worker_pool.zig`) — Thread-safe parallel message processing
- **Direct socket layer** (`src/net_socket.zig`) — BSD socket externs bypassing Zig 0.16 I/O race conditions

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
