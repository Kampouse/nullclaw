#!/usr/bin/env python3
"""Generate NullClaw Runtime Architecture Excalidraw diagram."""

import json
import uuid
import os

def uid(prefix=""):
    return f"{prefix}{uuid.uuid4().hex[:12]}"

# Color scheme
COLORS = {
    "bg": "#1e1e2e",
    "text": "#e5e5e5",
    "text_sub": "#c0c0c0",
    "channel_fill": "#1a3a4a",
    "channel_stroke": "#22d3ee",
    "runtime_fill": "#1a3a2a",
    "runtime_stroke": "#34d399",
    "agent_fill": "#2d1b69",
    "agent_stroke": "#a78bfa",
    "provider_fill": "#4a3510",
    "provider_stroke": "#fbbf24",
    "tool_fill": "#4a2a10",
    "tool_stroke": "#fb923c",
    "security_fill": "#4a1a2a",
    "security_stroke": "#fb7185",
    "memory_fill": "#1a2a4a",
    "memory_stroke": "#38bdf8",
    "bus_fill": "#1e2530",
    "bus_stroke": "#60a5fa",
    "daemon_fill": "#2a1a3a",
    "daemon_stroke": "#c084fc",
    "config_fill": "#2a2a2a",
    "config_stroke": "#a1a1aa",
}

elements = []
arrows = []

def make_rect(x, y, w, h, fill, stroke, stroke_w=2, dash=None, r=8, shadow=None):
    el = {
        "type": "rectangle",
        "version": 1,
        "versionNonce": int(uid(), 16) & 0x7FFFFFFF,
        "isDeleted": False,
        "id": uid(),
        "fillStyle": "solid",
        "strokeWidth": stroke_w,
        "strokeStyle": "dashed" if dash else "solid",
        "roughness": 0,
        "opacity": 100,
        "angle": 0,
        "x": x,
        "y": y,
        "strokeColor": stroke,
        "backgroundColor": fill,
        "width": w,
        "height": h,
        "seed": int(uid(), 16) & 0x7FFFFFFF,
        "groupIds": [],
        "frameId": None,
        "roundness": {"type": 3},
        "boundElements": [],
        "updated": 1,
        "link": None,
        "locked": False,
    }
    if dash:
        el["dashGap"] = 8
        el["dashOffset"] = 0
        el["dashArrayData"] = [dash]
    if shadow:
        el["shadow"] = True
    return el

def make_text(text, x, y, w, h, size=16, color="#e5e5e5", container_id=None, align="center"):
    el = {
        "type": "text",
        "version": 1,
        "versionNonce": int(uid(), 16) & 0x7FFFFFFF,
        "isDeleted": False,
        "id": uid(),
        "fillStyle": "solid",
        "strokeWidth": 1,
        "strokeStyle": "solid",
        "roughness": 0,
        "opacity": 100,
        "angle": 0,
        "x": x,
        "y": y,
        "strokeColor": color,
        "backgroundColor": "transparent",
        "width": w,
        "height": h,
        "seed": int(uid(), 16) & 0x7FFFFFFF,
        "groupIds": [],
        "frameId": None,
        "roundness": None,
        "boundElements": [],
        "updated": 1,
        "link": None,
        "locked": False,
        "fontSize": size,
        "fontFamily": 3,
        "text": text,
        "textAlign": align,
        "verticalAlign": "middle",
        "containerId": container_id,
        "originalText": text,
        "autoResize": True,
        "lineHeight": 1.25,
    }
    return el

def bind_text_to_shape(shape, text):
    shape["boundElements"].append({"id": text["id"], "type": "text"})
    return shape, text

def make_arrow(fid, tid, color="#60a5fa", pts=None):
    el = {
        "type": "arrow",
        "version": 1,
        "versionNonce": int(uid(), 16) & 0x7FFFFFFF,
        "isDeleted": False,
        "id": uid(),
        "fillStyle": "solid",
        "strokeWidth": 2,
        "strokeStyle": "solid",
        "roughness": 0,
        "opacity": 70,
        "angle": 0,
        "x": 0,
        "y": 0,
        "strokeColor": color,
        "backgroundColor": "transparent",
        "width": 100,
        "height": 100,
        "seed": int(uid(), 16) & 0x7FFFFFFF,
        "groupIds": [],
        "frameId": None,
        "roundness": {"type": 2},
        "boundElements": [],
        "updated": 1,
        "link": None,
        "locked": False,
        "startBinding": {"elementId": fid, "focus": 0, "gap": 5, "fixedPoint": None},
        "endBinding": {"elementId": tid, "focus": 0, "gap": 5, "fixedPoint": None},
        "lastCommittedPoint": None,
        "startArrowhead": None,
        "endArrowhead": "arrow",
        "points": pts or [[0, 0], [100, 0]],
        "elbowed": False,
    }
    arrows.append(el)
    return el["id"]

def add_component(x, y, w, h, label, fill, stroke, size=16):
    shape = make_rect(x, y, w, h, fill, stroke)
    txt = make_text(label, x + 5, y + 5, w - 10, h, size=size, color="#e5e5e5", container_id=shape["id"])
    shape, txt = bind_text_to_shape(shape, txt)
    elements.append(shape)
    elements.append(txt)
    return shape["id"]

def add_group_box(x, y, w, h, title, stroke="#555555", dash=10):
    shape = make_rect(x, y, w, h, "transparent", stroke, stroke_w=1, dash=dash)
    txt = make_text(title, x + 10, y - 24, w - 20, 24, size=18, color=stroke)
    elements.append(shape)
    elements.append(txt)
    return shape["id"]


# ============================================================
# 1. MASSIVE BACKGROUND
# ============================================================
bg = make_rect(-200, -200, 9800, 6200, COLORS["bg"], "#333333", stroke_w=0)
bg["roundness"] = {"type": 3}
elements.append(bg)

# ============================================================
# DAEMON (top bar)
# ============================================================
daemon_box = make_rect(100, 30, 8800, 90, COLORS["daemon_fill"], COLORS["daemon_stroke"], stroke_w=3, r=12)
daemon_txt = make_text(
    "DAEMON — Main Orchestrator  |  spawns: Gateway, Heartbeat, Scheduler, Channel Supervisor, Inbound/Outbound Dispatchers",
    120, 45, 8760, 60, size=20, color="#e5e5e5", container_id=daemon_box["id"]
)
daemon_box, daemon_txt = bind_text_to_shape(daemon_box, daemon_txt)
elements.append(daemon_box)
elements.append(daemon_txt)
DAEMON_ID = daemon_box["id"]

# ============================================================
# LAYER 1 - CHANNELS
# ============================================================
CH_X, CH_Y, CH_W, CH_H = 50, 200, 620, 960
add_group_box(CH_X, CH_Y, CH_W, CH_H, "LAYER 1 — External Channels", stroke=COLORS["channel_stroke"])

ch_items = [
    ("Telegram", "polling bot API"),
    ("Discord", "WebSocket gateway"),
    ("Slack", "Socket Mode"),
    ("Matrix", "long-polling /sync"),
    ("Nostr", "NIP-01 relay"),
    ("WhatsApp", "Cloud API webhooks"),
    ("+ 15 more", "Signal, IRC, iMessage, Email, LINE, QQ..."),
]
ch_ids = []
for i, (name, desc) in enumerate(ch_items):
    cy = CH_Y + 45 + i * 85
    cid = add_component(CH_X + 20, cy, CH_W - 40, 70, f"{name}\n{desc}", COLORS["channel_fill"], COLORS["channel_stroke"], size=15)
    ch_ids.append(cid)

# ============================================================
# LAYER 2 - CHANNEL MANAGER
# ============================================================
CM_X, CM_Y, CM_W, CM_H = 740, 200, 320, 540
add_group_box(CM_X, CM_Y, CM_W, CM_H, "LAYER 2 — Channel Manager", stroke=COLORS["runtime_stroke"])
cm_lifecycle = add_component(CM_X + 15, CM_Y + 45, CM_W - 30, 65, "Centralized Lifecycle", COLORS["runtime_fill"], COLORS["runtime_stroke"], size=16)
cm_supervision = add_component(CM_X + 15, CM_Y + 130, CM_W - 30, 70, "Supervision Loop\nhealth checks + restart", COLORS["runtime_fill"], COLORS["runtime_stroke"], size=15)
cm_threads = add_component(CM_X + 15, CM_Y + 220, CM_W - 30, 70, "Spawns/Monitors\nper-channel threads", COLORS["runtime_fill"], COLORS["runtime_stroke"], size=15)

# ============================================================
# LAYER 3 - HTTP GATEWAY
# ============================================================
GW_X, GW_Y, GW_W, GW_H = 1140, 200, 340, 540
add_group_box(GW_X, GW_Y, GW_W, GW_H, "LAYER 3 — HTTP Gateway", stroke=COLORS["runtime_stroke"])
gw_endpoints = add_component(GW_X + 15, GW_Y + 45, GW_W - 30, 75, "/webhook, /telegram\n/health, /pair, /whatsapp", COLORS["runtime_fill"], COLORS["runtime_stroke"], size=14)
gw_security = add_component(GW_X + 15, GW_Y + 140, GW_W - 30, 65, "Rate Limiting\nIdempotency, Bearer Auth", COLORS["runtime_fill"], COLORS["runtime_stroke"], size=14)
gw_config = add_component(GW_X + 15, GW_Y + 225, GW_W - 30, 65, "TLS, 64KB body limit\n30s timeout", COLORS["runtime_fill"], COLORS["runtime_stroke"], size=14)
pg_id = add_component(GW_X + 15, GW_Y + 320, GW_W - 30, 65, "PairingGuard\none-time codes, bearer tokens", COLORS["security_fill"], COLORS["security_stroke"], size=14)
PAIRINGGUARD_ID = pg_id

# ============================================================
# LAYER 4 - MESSAGE BUS
# ============================================================
BUS_X, BUS_Y, BUS_W, BUS_H = 1560, 200, 320, 540
add_group_box(BUS_X, BUS_Y, BUS_W, BUS_H, "LAYER 4 — Message Bus", stroke=COLORS["bus_stroke"])
inbound_q = add_component(BUS_X + 15, BUS_Y + 45, BUS_W - 30, 85, "Inbound Queue\nBoundedQueue<InboundMsg>(100)\nMutex + Condition", COLORS["bus_fill"], COLORS["bus_stroke"], size=14)
outbound_q = add_component(BUS_X + 15, BUS_Y + 160, BUS_W - 30, 85, "Outbound Queue\nBoundedQueue<OutboundMsg>(100)\nMutex + Condition", COLORS["bus_fill"], COLORS["bus_stroke"], size=14)
bus_signal = add_component(BUS_X + 15, BUS_Y + 275, BUS_W - 30, 60, "Blocking publish/consume\nclose signal", COLORS["bus_fill"], COLORS["bus_stroke"], size=14)
INBOUND_Q_ID = inbound_q
OUTBOUND_Q_ID = outbound_q

# ============================================================
# LAYER 5 - DISPATCHERS
# ============================================================
DISP_X, DISP_Y, DISP_W, DISP_H = 1960, 200, 380, 740
add_group_box(DISP_X, DISP_Y, DISP_W, DISP_H, "LAYER 5 — Dispatchers", stroke=COLORS["runtime_stroke"])
inbound_disp = add_component(DISP_X + 15, DISP_Y + 45, DISP_W - 30, 85, "Inbound Dispatcher (thread)\nconsumes inbound bus\nresolves session key", COLORS["runtime_fill"], COLORS["runtime_stroke"], size=14)
outbound_disp = add_component(DISP_X + 15, DISP_Y + 155, DISP_W - 30, 85, "Outbound Dispatcher (thread)\nconsumes outbound bus\nfinds channel -> send()", COLORS["runtime_fill"], COLORS["runtime_stroke"], size=14)
worker_pool = add_component(DISP_X + 15, DISP_Y + 265, DISP_W - 30, 85, "Worker Pool\ncomptime-generic\nper-session Spinlock hashmap", COLORS["runtime_fill"], COLORS["runtime_stroke"], size=14)
INBOUND_DISP_ID = inbound_disp
OUTBOUND_DISP_ID = outbound_disp

# ============================================================
# LAYER 6 - SESSION MANAGER
# ============================================================
SESS_X, SESS_Y, SESS_W, SESS_H = 2420, 200, 380, 740
add_group_box(SESS_X, SESS_Y, SESS_W, SESS_H, "LAYER 6 — Session Manager", stroke=COLORS["memory_stroke"])
sess_pool = add_component(SESS_X + 15, SESS_Y + 45, SESS_W - 30, 70, "Thread-safe Session Pool\nStringHashMap<Session>", COLORS["memory_fill"], COLORS["memory_stroke"], size=14)
sess_create = add_component(SESS_X + 15, SESS_Y + 135, SESS_W - 30, 70, "getOrCreate(session_key)\n-> Session with Agent", COLORS["memory_fill"], COLORS["memory_stroke"], size=14)
sess_stream = add_component(SESS_X + 15, SESS_Y + 225, SESS_W - 30, 70, "processMessageStreaming()\noptional streaming sink", COLORS["memory_fill"], COLORS["memory_stroke"], size=14)
sess_mgmt = add_component(SESS_X + 15, SESS_Y + 315, SESS_W - 30, 70, "Idle Eviction, Skill Reload\n/new, /reset, /retry", COLORS["memory_fill"], COLORS["memory_stroke"], size=14)
SESSION_MGR_ID = sess_pool

# ============================================================
# LAYER 7 - AGENT CORE
# ============================================================
AGENT_X, AGENT_Y, AGENT_W, AGENT_H = 2880, 200, 460, 740
add_group_box(AGENT_X, AGENT_Y, AGENT_W, AGENT_H, "LAYER 7 — Agent Core (THE MAIN LOOP)", stroke=COLORS["agent_stroke"])
agent_loop = add_component(AGENT_X + 15, AGENT_Y + 45, AGENT_W - 30, 110, "Turn Loop\nbuild system prompt -> provider.chat()\n-> parse tool calls -> execute tools\n-> feed results back -> repeat", COLORS["agent_fill"], COLORS["agent_stroke"], size=14)
agent_limits = add_component(AGENT_X + 15, AGENT_Y + 175, AGENT_W - 30, 65, "Max Tool Iterations\nContext Compaction", COLORS["agent_fill"], COLORS["agent_stroke"], size=14)
agent_prompt = add_component(AGENT_X + 15, AGENT_Y + 260, AGENT_W - 30, 65, "System Prompt Builder\nMemory Enrichment, Skill Loading", COLORS["agent_fill"], COLORS["agent_stroke"], size=14)
AGENT_CORE_ID = agent_loop

# ============================================================
# LAYER 8 - PROVIDER SYSTEM
# ============================================================
PROV_X, PROV_Y, PROV_W, PROV_H = 3420, 200, 560, 740
add_group_box(PROV_X, PROV_Y, PROV_W, PROV_H, "LAYER 8 — Provider System", stroke=COLORS["provider_stroke"])
prov_router = add_component(PROV_X + 15, PROV_Y + 45, PROV_W - 30, 70, "Router Provider\nmulti-model routing via hint: prefix", COLORS["provider_fill"], COLORS["provider_stroke"], size=14)
prov_reliable = add_component(PROV_X + 15, PROV_Y + 135, PROV_W - 30, 70, "Reliable Provider\nretries + fallback + exponential backoff", COLORS["provider_fill"], COLORS["provider_stroke"], size=14)
PROV_ROUTER_ID = prov_router
PROV_RELIABLE_ID = prov_reliable

providers = [
    ("Anthropic", "Claude models"),
    ("OpenAI", "GPT-4o, o1, o3"),
    ("Gemini", "Google models"),
    ("Ollama", "Local models"),
    ("OpenRouter", "Multi-provider"),
    ("Claude CLI", "Anthropic CLI"),
    ("Codex CLI", "OpenAI CLI"),
]
prov_item_ids = []
for i, (name, desc) in enumerate(providers):
    py = PROV_Y + 230 + i * 60
    pid = add_component(PROV_X + 15, py, PROV_W - 30, 48, f"{name} — {desc}", COLORS["provider_fill"], COLORS["provider_stroke"], size=14)
    prov_item_ids.append(pid)

# ============================================================
# LAYER 9 - TOOL SYSTEM
# ============================================================
TOOL_X, TOOL_Y, TOOL_W, TOOL_H = 2880, 1060, 460, 560
add_group_box(TOOL_X, TOOL_Y, TOOL_W, TOOL_H, "LAYER 9 — Tool System", stroke=COLORS["tool_stroke"])
tool_dispatcher = add_component(TOOL_X + 15, TOOL_Y + 45, TOOL_W - 30, 75, "Tool Dispatcher\nparses OpenAI JSON / XML tool tags\nfinds tool by name -> execute()", COLORS["tool_fill"], COLORS["tool_stroke"], size=14)
TOOL_DISP_ID = tool_dispatcher

tools_list = [
    "Shell, File I/O, HTTP, Git",
    "Web Search, Browser, Memory",
    "Cron, Message, Delegate",
    "Hardware, Image, +25 more",
]
tool_item_ids = []
for i, t in enumerate(tools_list):
    ty = TOOL_Y + 140 + i * 60
    tid = add_component(TOOL_X + 15, ty, TOOL_W - 30, 48, f"35+ Tools: {t}", COLORS["tool_fill"], COLORS["tool_stroke"], size=14)
    tool_item_ids.append(tid)

# ============================================================
# LAYER 10 - MEMORY SYSTEM
# ============================================================
MEM_X, MEM_Y, MEM_W, MEM_H = 1560, 1060, 340, 560
add_group_box(MEM_X, MEM_Y, MEM_W, MEM_H, "LAYER 10 — Memory System", stroke=COLORS["memory_stroke"])
mem_storage = add_component(MEM_X + 15, MEM_Y + 45, MEM_W - 30, 65, "Storage Layer\nSQLite / PG / Redis / MD", COLORS["memory_fill"], COLORS["memory_stroke"], size=14)
mem_retrieval = add_component(MEM_X + 15, MEM_Y + 130, MEM_W - 30, 65, "Retrieval\nQMD / RRF / Reranker", COLORS["memory_fill"], COLORS["memory_stroke"], size=14)
mem_vector = add_component(MEM_X + 15, MEM_Y + 215, MEM_W - 30, 65, "Vector\nEmbeddings / Qdrant / PgVector", COLORS["memory_fill"], COLORS["memory_stroke"], size=14)
mem_lifecycle = add_component(MEM_X + 15, MEM_Y + 300, MEM_W - 30, 65, "Lifecycle\ncache / consolidation / snapshot", COLORS["memory_fill"], COLORS["memory_stroke"], size=14)
mem_runtime = add_component(MEM_X + 15, MEM_Y + 385, MEM_W - 30, 55, "MemoryRuntime orchestrator", COLORS["memory_fill"], COLORS["memory_stroke"], size=14)
mem_session = add_component(MEM_X + 15, MEM_Y + 460, MEM_W - 30, 55, "SessionStore (persistence)", COLORS["memory_fill"], COLORS["memory_stroke"], size=14)
MEM_RUNTIME_ID = mem_runtime

# ============================================================
# LAYER 11 - CRON/SCHEDULER
# ============================================================
CRON_X, CRON_Y, CRON_W, CRON_H = 1960, 1060, 380, 380
add_group_box(CRON_X, CRON_Y, CRON_W, CRON_H, "LAYER 11 — Cron/Scheduler", stroke=COLORS["runtime_stroke"])
cron_store = add_component(CRON_X + 15, CRON_Y + 45, CRON_W - 30, 65, "In-memory Job Store\nCron Expression Parser", COLORS["runtime_fill"], COLORS["runtime_stroke"], size=14)
cron_exec = add_component(CRON_X + 15, CRON_Y + 130, CRON_W - 30, 65, "Execution Modes\nShell or Agent-mode", COLORS["runtime_fill"], COLORS["runtime_stroke"], size=14)
cron_delivery = add_component(CRON_X + 15, CRON_Y + 215, CRON_W - 30, 65, "Delivery: none / always\non_error / on_success", COLORS["runtime_fill"], COLORS["runtime_stroke"], size=14)
CRON_ID = cron_store

# ============================================================
# LAYER 12 - SECURITY
# ============================================================
SEC_X, SEC_Y, SEC_W, SEC_H = 50, 1300, 620, 440
add_group_box(SEC_X, SEC_Y, SEC_W, SEC_H, "LAYER 12 — Security", stroke=COLORS["security_stroke"])
sec_policy = add_component(SEC_X + 15, SEC_Y + 45, SEC_W - 30, 70, "SecurityPolicy\ncommand allowlists, path validation\nrisk classification", COLORS["security_fill"], COLORS["security_stroke"], size=14)
sec_sandbox = add_component(SEC_X + 15, SEC_Y + 135, SEC_W - 30, 70, "Sandbox vtable\nLandlock, Firejail, Bubblewrap, Docker", COLORS["security_fill"], COLORS["security_stroke"], size=14)
sec_secrets = add_component(SEC_X + 15, SEC_Y + 225, SEC_W - 30, 60, "SecretStore — ChaCha20-Poly1305 AEAD", COLORS["security_fill"], COLORS["security_stroke"], size=14)
SEC_POLICY_ID = sec_policy

# ============================================================
# LAYER 13 - RUNTIME ADAPTERS
# ============================================================
RT_X, RT_Y, RT_W, RT_H = 740, 1060, 320, 380
add_group_box(RT_X, RT_Y, RT_W, RT_H, "LAYER 13 — Runtime Adapters", stroke=COLORS["runtime_stroke"])
rt_native = add_component(RT_X + 15, RT_Y + 45, RT_W - 30, 60, "Native Runtime\nfull shell/fs/storage", COLORS["runtime_fill"], COLORS["runtime_stroke"], size=14)
rt_docker = add_component(RT_X + 15, RT_Y + 125, RT_W - 30, 60, "Docker Runtime\ncontainer-isolated", COLORS["runtime_fill"], COLORS["runtime_stroke"], size=14)
rt_wasm = add_component(RT_X + 15, RT_Y + 205, RT_W - 30, 60, "Wasm Runtime\nwasmtime sandbox, fuel-limited", COLORS["runtime_fill"], COLORS["runtime_stroke"], size=14)
RT_NATIVE_ID = rt_native

# ============================================================
# LAYER 14 - CONFIG
# ============================================================
CFG_X, CFG_Y, CFG_W, CFG_H = 1140, 1060, 340, 380
add_group_box(CFG_X, CFG_Y, CFG_W, CFG_H, "LAYER 14 — Config", stroke=COLORS["config_stroke"])
cfg_prov = add_component(CFG_X + 15, CFG_Y + 45, CFG_W - 30, 50, "ProviderEntry", COLORS["config_fill"], COLORS["config_stroke"], size=14)
cfg_agent = add_component(CFG_X + 15, CFG_Y + 110, CFG_W - 30, 50, "AgentConfig", COLORS["config_fill"], COLORS["config_stroke"], size=14)
cfg_diag = add_component(CFG_X + 15, CFG_Y + 175, CFG_W - 30, 50, "DiagnosticsConfig", COLORS["config_fill"], COLORS["config_stroke"], size=14)
cfg_auto = add_component(CFG_X + 15, CFG_Y + 240, CFG_W - 30, 50, "AutonomyConfig", COLORS["config_fill"], COLORS["config_stroke"], size=14)
cfg_reliab = add_component(CFG_X + 15, CFG_Y + 305, CFG_W - 30, 50, "ReliabilityConfig, SchedulerConfig", COLORS["config_fill"], COLORS["config_stroke"], size=14)

# ============================================================
# ARROWS
# ============================================================

# 1. Channels -> Channel Manager
for cid in ch_ids:
    make_arrow(cid, cm_lifecycle, COLORS["channel_stroke"])

# 2. Channel Manager -> Gateway
make_arrow(cm_lifecycle, gw_endpoints, COLORS["runtime_stroke"])
make_arrow(cm_threads, gw_endpoints, COLORS["runtime_stroke"])

# 3. Gateway -> Inbound Queue
make_arrow(gw_endpoints, inbound_q, COLORS["runtime_stroke"])

# 4. Channels -> Inbound Queue (direct for polling - just a couple)
make_arrow(ch_ids[0], inbound_q, COLORS["channel_stroke"], [[0, 0], [-30, 0], [-30, -400], [250, -400], [250, 0]])
make_arrow(ch_ids[3], inbound_q, COLORS["channel_stroke"], [[0, 0], [-60, 0], [-60, -300], [230, -300], [230, 0]])

# 5. Inbound Queue -> Inbound Dispatcher
make_arrow(inbound_q, inbound_disp, COLORS["bus_stroke"])

# 6. Inbound Dispatcher -> Session Manager
make_arrow(inbound_disp, sess_pool, COLORS["runtime_stroke"])

# 7. Session Manager -> Agent Core
make_arrow(sess_create, agent_loop, COLORS["memory_stroke"])
make_arrow(sess_stream, agent_loop, COLORS["memory_stroke"])

# 8. Agent Core -> Provider Router
make_arrow(agent_loop, prov_router, COLORS["agent_stroke"])

# 9. Provider Router -> Reliable Provider -> Individual Providers
make_arrow(prov_router, prov_reliable, COLORS["provider_stroke"])
for pid in prov_item_ids:
    make_arrow(prov_reliable, pid, COLORS["provider_stroke"])

# 10. Agent Core -> Tool Dispatcher -> Individual Tools
make_arrow(agent_loop, tool_dispatcher, COLORS["agent_stroke"], [[0, 0], [0, 400], [200, 400], [200, 600], [0, 600]])
for tid in tool_item_ids:
    make_arrow(tool_dispatcher, tid, COLORS["tool_stroke"])

# 11. Agent Core -> Memory Runtime -> Backends
make_arrow(agent_prompt, mem_runtime, COLORS["agent_stroke"], [[0, 0], [-300, 0], [-300, 900], [100, 900], [100, 0]])
make_arrow(mem_runtime, mem_storage, COLORS["memory_stroke"])
make_arrow(mem_runtime, mem_retrieval, COLORS["memory_stroke"])
make_arrow(mem_runtime, mem_vector, COLORS["memory_stroke"])
make_arrow(mem_runtime, mem_lifecycle, COLORS["memory_stroke"])

# 12. Inbound Dispatcher -> Outbound Queue
make_arrow(inbound_disp, outbound_q, COLORS["runtime_stroke"], [[0, 0], [-100, 0], [-100, 100], [0, 100]])

# 13. Outbound Queue -> Outbound Dispatcher
make_arrow(outbound_q, outbound_disp, COLORS["bus_stroke"])

# 14. Outbound Dispatcher -> Channels (use a couple representative)
make_arrow(outbound_disp, ch_ids[1], COLORS["runtime_stroke"], [[0, 0], [-800, 0], [-800, 600], [0, 600]])
make_arrow(outbound_disp, ch_ids[4], COLORS["runtime_stroke"], [[0, 0], [-850, 0], [-850, 700], [0, 700]])

# 15. Cron -> Outbound Queue
make_arrow(cron_store, outbound_q, COLORS["runtime_stroke"], [[0, 0], [0, -350], [-400, -350], [-400, 0]])

# 16. Security Policy -> Tool Dispatcher (validate)
make_arrow(sec_policy, tool_dispatcher, COLORS["security_stroke"], [[0, 0], [400, 0], [400, -150], [700, -150], [700, 0]])

# 17. PairingGuard -> Gateway (auth)
make_arrow(PAIRINGGUARD_ID, gw_security, COLORS["security_stroke"], [[0, 0], [0, -60]])

# 18. Config -> Agent Core, Config -> Provider Router
make_arrow(cfg_agent, agent_prompt, COLORS["config_stroke"], [[0, 0], [200, 0], [200, -350], [500, -350], [500, 0]])
make_arrow(cfg_prov, prov_router, COLORS["config_stroke"], [[0, 0], [300, 0], [300, -450], [600, -450], [600, 0]])

# 19. Runtime Adapters -> Agent Core
make_arrow(RT_NATIVE_ID, agent_limits, COLORS["runtime_stroke"], [[0, 0], [200, 0], [200, -250], [600, -250], [600, 0]])

# 20. Daemon -> Gateway, Daemon -> Cron, Daemon -> Channel Manager, Daemon -> Inbound Dispatcher
make_arrow(DAEMON_ID, gw_endpoints, COLORS["daemon_stroke"], [[0, 0], [0, 250], [400, 250], [400, 100], [0, 100]])
make_arrow(DAEMON_ID, cron_store, COLORS["daemon_stroke"], [[0, 0], [0, 350], [-200, 350], [-200, 200], [0, 200]])
make_arrow(DAEMON_ID, cm_lifecycle, COLORS["daemon_stroke"], [[0, 0], [0, 500], [-700, 500], [-700, 100], [0, 100]])
make_arrow(DAEMON_ID, inbound_disp, COLORS["daemon_stroke"], [[0, 0], [0, 600], [100, 600], [100, 100], [0, 100]])


# ============================================================
# ASSEMBLE FINAL JSON
# ============================================================
all_elements = elements + arrows

app_state = {
    "type": "excalidraw",
    "version": 2,
    "source": "nullclaw-arch-generator",
    "elements": all_elements,
    "appState": {
        "gridSize": None,
        "viewBackgroundColor": COLORS["bg"],
    },
    "files": {}
}

output_path = "/Users/jean/dev/nullclaw/docs/runtime-architecture.excalidraw"
os.makedirs(os.path.dirname(output_path), exist_ok=True)
with open(output_path, "w") as f:
    json.dump(app_state, f, indent=2)

print(f"Generated diagram with {len(all_elements)} elements ({len(elements)} shapes/texts + {len(arrows)} arrows)")
print(f"Saved to: {output_path}")
