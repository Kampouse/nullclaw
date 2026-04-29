# Kampouse/nullclaw

A fork of [nullclaw/nullclaw](https://github.com/nullclaw/nullclaw) focused on Nostr-native agent identity, P2P coordination, production-hardened operations, and local-first tooling.

**Upstream:** `v2026.4.17` | **Zig:** 0.16.0 (stable) | **Binary:** ~35 MB (debug) | **265 source files, 188K LOC**

---

## Fork vs Upstream

| | Upstream `nullclaw/nullclaw` | This fork `Kampouse/nullclaw` |
|---|---|---|
| **Upstream base** | `v2026.4.17` | `v2026.3.1` + 94 fork commits |
| **Stars** | 7,359 | — |
| **Source files** | 274 | 265 |
| **LOC** | — | ~188K |
| **Providers** | 23 (Anthropic, Gemini, OpenAI, OpenRouter, Ollama, Claude CLI, Codex CLI, Vertex, Gemini CLI, ...) | 19 (same minus Vertex, Gemini CLI) |
| **Channels** | 38 (Telegram, Discord, Slack, Signal, WhatsApp, Matrix, IRC, Teams, WeChat, Nostr, ...) | 22 (subset — see below) |
| **Tools** | 48 | 51 |
| **Nostr** | Channel adapter only (send/receive via relay) | Full native stack: BIP-340 signing, event construction, relay client, NIP-04, NIP-59 Gift Wrap |
| **P2P agents** | Not available | Gork hybrid system (daemon + polling fallback + QUIC + WebSocket) |
| **Browser automation** | Browserbase (cloud) | BrowserBase + local CDP (Chrome DevTools Protocol) |
| **Tool gating** | Not available | Relevance-based schema gating (reduces per-turn token overhead) |
| **Gateway HTTP** | Fixed 4KB/8KB stack buffers, no timeout, no CORS | Dynamic allocation, Content-Length, partial writes, 30s timeout, 503 guard, CORS, access logging |
| **Error handling** | ~290 silent `catch {}` | 37 critical sites fixed with scoped warn logging |
| **Observability** | `std.log` | Structured JSON logging (Grafana/Loki), request tracing, profiling hooks |
| **Session model** | Standard key-value | Standard + content-addressable git-like sessions (immutable commits, branching) |
| **VM sandbox** | Not available | Local VM execution with heap allocator isolation |
| **Crash handling** | Default Zig panic | Signal-safe crash file writer, panic logging to disk |

### What upstream has that we haven't merged yet

| Feature | Notes |
|---|---|
| A2A protocol (Google v0.3.0) | Agent-to-agent interoperability |
| Control plane (slash commands) | Structured command infrastructure |
| MCP admin | MCP server management CLI |
| Channel probe | Credential validation at startup |
| Inbound debounce | Message deduplication |
| Channel admin | Config CLI for channels |
| Content-addressed file ops | Hashed file read/write/edit |
| Cron gateway | HTTP-triggered cron jobs |
| Vertex AI provider | Google Vertex integration |
| Gemini CLI provider | Gemini CLI integration |
| Teams, WeChat, WeCom, Weixin channels | Enterprise messaging |
| Max channel | MaixCam hardware |
| External channel protocol | Generic external adapter |
| Telegram API refactor | Ingress split architecture |
| Calculator, file delete, hashed file tools | Additional tools |

---

## What This Fork Adds

### Nostr Native Stack

Full Nostr protocol in pure Zig — not just a channel adapter, but a complete signing/relay/event library.

- `src/nostr.zig` — BIP-340 Schnorr signing, bech32 (npub/nsec) encoding with 3 upstream bugfixes, event construction (kinds 0/1/3), relay websocket client, NIP-04 encrypted DMs, NIP-59 Gift Wrap
- `src/tools/nostr.zig` — Agent-facing tool: `post`, `read`, `reply`, `search`, `profile`
- `src/tools/nostr_email.zig` — Sealed email via NIP-59 (kind 1301)

### Gork P2P Agent Coordination

Hybrid daemon + polling for real-time agent-to-agent messaging.

- `src/gork_daemon.zig` — Long-lived P2P message routing daemon
- `src/gork_hybrid.zig` — Real-time daemon with automatic polling fallback
- `src/gork_quic_client.zig` — QUIC transport
- `src/gork_websocket.zig` — WebSocket fallback transport
- `src/tools/gork.zig` — Agent tool for inter-agent messaging

### Browser CDP Tool

Local browser automation via Chrome DevTools Protocol — no cloud dependency.

- `src/tools/browser_cdp.zig` — Navigate, click, type, screenshot, evaluate JS, search
- Integrated into `web_fetch` and `web_search` for browser-based fallback

### Tool Schema Gating

Reduces per-turn token overhead by only sending relevant tool schemas to the LLM.

- `src/tools/gating.zig` — Relevance ranking with lazy promotion (arXiv:2604.21816 pattern)
- Configurable via `tool_gating` config section (enabled, top_k)

### Hardened Gateway HTTP

Replaced fixed-size stack buffers with production-grade handling.

- `readFullRequest` — Content-Length aware, dynamic allocation (replaces 4KB truncation)
- `writeAllSocket` — Partial write loop (replaces single-write truncation)
- 30s request timeout, concurrent eval guard (atomic 503), CORS preflight, access logging

### Crash Handler

Signal-safe panic handler that writes crash info to disk before any stdio that might fail.

- `src/main.zig` — SIGSEGV, SIGABRT, SIGFPE, SIGBUS handlers with crash file persistence

### Reliability & Observability

- 37 critical `catch {}` fixes — Cron saves, session persists, channel replies, HTTP writes now log warnings
- Structured JSON logging (`src/structured_log.zig`) — Grafana/Loki compatible
- Request tracing (`src/trace.zig`) — Span timing for profiling
- Memory/CPU profiling hooks (`src/profiling.zig`)
- Compaction quality — 500→1500 char transcript limit, improved summary prompt

### Session & Infrastructure

- Git-like sessions (`src/session_git.zig`) — Content-addressable, immutable commits, branching
- Worker pool (`src/worker_pool.zig`) — Thread-safe parallel message processing
- VM sandbox (`src/vm/`) — Local code execution with heap allocator isolation
- Direct socket layer (`src/net_socket.zig`) — BSD socket externs bypassing Zig 0.16 I/O races

---

## Build & Run

```bash
# Requires Zig 0.16.0 (stable)
git clone https://github.com/Kampouse/nullclaw.git
cd nullclaw
zig build -Doptimize=ReleaseSmall
```

**Background daemon (recommended):**

```bash
make start    # Start in background, log to ~/.nullclaw/logs/daemon.log
make stop     # Stop
make restart  # Stop, build, start
make status   # Check if running
make logs     # Tail log file
```

Never run the binary directly in foreground — it blocks indefinitely. Always use `make start`.

**Test the gateway:**

```bash
curl -s -X POST http://127.0.0.1:3000/eval \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"test","messages":[{"role":"user","content":"hello"}]}'
```

**Health check:**

```bash
curl -s http://127.0.0.1:3000/health
```

---

## Tool Comparison

| Tool | Upstream | Fork | Notes |
|---|:---:|:---:|---|
| browser | ✓ | ✓ | BrowserBase (cloud) |
| browser_cdp | — | ✓ | Local Chrome DevTools Protocol |
| browser_open | ✓ | ✓ | |
| calculator | ✓ | — | Not yet merged |
| cargo | — | ✓ | Rust project management |
| composio | ✓ | ✓ | |
| cron_* | ✓ | ✓ | (minus cron_gateway) |
| delegate | ✓ | ✓ | Subagent delegation |
| file_append | ✓ | ✓ | |
| file_delete | ✓ | — | Not yet merged |
| file_edit | ✓ | ✓ | |
| file_read | ✓ | ✓ | |
| file_write | ✓ | ✓ | |
| git | ✓ | ✓ | |
| gork | — | ✓ | P2P agent messaging |
| hardware_* | ✓ | ✓ | I2C, SPI, memory, info |
| http_request | ✓ | ✓ | |
| image | ✓ | ✓ | |
| memory_* | ✓ | ✓ | store, recall, list, forget |
| nostr | — | ✓ | Full Nostr protocol |
| nostr_email | — | ✓ | NIP-59 sealed email |
| predict | — | ✓ | Embedding provider |
| process_allocator | — | ✓ | Process memory tracking |
| self_diagnose | — | ✓ | Runtime health check |
| self_update | — | ✓ | Git pull + rebuild |
| shell | ✓ | ✓ | |
| spawn | ✓ | ✓ | |
| vm_exec | — | ✓ | Sandboxed code execution |
| web_fetch | ✓ | ✓ | With CDP fallback |
| web_scrape | — | ✓ | HTML to markdown |
| web_search | ✓ | ✓ | With CDP browser fallback |
| zig_build | — | ✓ | Zig project compilation |

---

## License

MIT — same as upstream [nullclaw/nullclaw](https://github.com/nullclaw/nullclaw).
