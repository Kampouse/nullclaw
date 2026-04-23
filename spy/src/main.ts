// ═══ MAIN — Entry Point ═══
import { S } from './state';
import { $, esc, fmtTime, fmtUptime } from './utils';
import { selectEvent, rerenderFeed, clearFeed, appendEvents } from './feed';
import { openDossier, closeDossier, switchTab } from './dossier';
import { connectPolling, pollStatus, showContext } from './polling';
import { switchView, pollTrace, initTraceTooltip, initTraceClickHandlers } from './trace';
import type { SpyEvent, DossierTab } from './types';
import './style.css';

const feed = $('feed') as HTMLElement;
const contextStrip = $('context-strip') as HTMLElement;

// ═══ KEYBOARD NAVIGATION ═══
document.addEventListener('keydown', (e: KeyboardEvent) => {
  if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;

  const visibleEvents = Array.from(feed.querySelectorAll('.event:not([style*="display: none"])'));

  switch (e.key) {
    case 'j':
    case 'ArrowDown': {
      e.preventDefault();
      if (visibleEvents.length === 0) break;
      const next = S.selectedIdx < 0 ? 0 : (() => {
        const cur = visibleEvents.findIndex(el => parseInt(el.dataset.idx || '') === S.selectedIdx);
        return cur < visibleEvents.length - 1 ? parseInt(visibleEvents[cur + 1].dataset.idx || '') : S.selectedIdx;
      })();
      selectEvent(next);
      break;
    }
    case 'k':
    case 'ArrowUp': {
      e.preventDefault();
      if (visibleEvents.length === 0) break;
      const prev = S.selectedIdx < 0 ? 0 : (() => {
        const cur = visibleEvents.findIndex(el => parseInt(el.dataset.idx || '') === S.selectedIdx);
        return cur > 0 ? parseInt(visibleEvents[cur - 1].dataset.idx || '') : S.selectedIdx;
      })();
      selectEvent(prev);
      break;
    }
    case 'Enter':
      if (S.selectedIdx >= 0) openDossier(S.selectedIdx);
      break;
    case 'Escape': {
      const helpOverlay = $('help-overlay') as HTMLElement;
      const searchOverlay = $('search-overlay') as HTMLElement;
      if (helpOverlay && helpOverlay.style.display === 'flex') {
        helpOverlay.style.display = 'none';
      } else if (searchOverlay && searchOverlay.classList.contains('visible')) {
        searchOverlay.classList.remove('visible');
      } else if (contextStrip && !contextStrip.classList.contains('collapsed')) {
        contextStrip.classList.add('collapsed');
      } else if (S.zoomedEvent) {
        closeDossier();
      }
      break;
    }
    case '/': {
      e.preventDefault();
      const searchOverlay = $('search-overlay') as HTMLElement;
      const searchInput = $('search-input') as HTMLInputElement;
      if (searchOverlay) searchOverlay.classList.add('visible');
      if (searchInput) { searchInput.value = S.filter; searchInput.focus(); }
      break;
    }
    case '.': {
      e.preventDefault();
      S.paused = !S.paused;
      feed.classList.toggle('paused', S.paused);
      const btnPause = $('btn-pause') as HTMLElement;
      if (btnPause) { btnPause.classList.toggle('active', S.paused); btnPause.textContent = S.paused ? '▶' : '⏸'; }
      break;
    }
    case 'f':
    case 'F': {
      e.preventDefault();
      S.following = !S.following;
      const btnFollow = $('btn-follow') as HTMLElement;
      if (btnFollow) { btnFollow.classList.toggle('active', S.following); }
      if (S.following) feed.scrollTop = feed.scrollHeight;
      break;
    }
    case 'c':
    case 'C':
      e.preventDefault();
      clearFeed();
      break;
    case 'h':
      S.showHeartbeats = !S.showHeartbeats;
      rerenderFeed();
      break;
    case 'Tab':
      e.preventDefault();
      if (S.zoomedEvent) {
        const tabs: DossierTab[] = ['overview', 'graph', 'timeline', 'context', 'files'];
        const ci = tabs.indexOf(S.activeTab);
        switchTab(tabs[(ci + 1) % tabs.length]);
      }
      break;
    case '?': {
      e.preventDefault();
      const helpOverlay = $('help-overlay') as HTMLElement;
      if (helpOverlay) helpOverlay.style.display = helpOverlay.style.display === 'flex' ? 'none' : 'flex';
      break;
    }
  }
});

// ═══ FILTER (debounced) ═══
let _filterTimer: ReturnType<typeof setTimeout> | null = null;
const filterEl = $('filter') as HTMLInputElement;
filterEl?.addEventListener('input', (e) => {
  S.filter = (e.target as HTMLInputElement).value;
  if (_filterTimer) clearTimeout(_filterTimer);
  _filterTimer = setTimeout(() => rerenderFeed(), 150);
});

// ═══ SEARCH ═══
const searchInput = $('search-input') as HTMLInputElement;
searchInput?.addEventListener('input', (e) => {
  const q = (e.target as HTMLInputElement).value.toLowerCase();
  const results = $('search-results') as HTMLElement;
  if (!results) return;
  if (q.length < 2) { results.innerHTML = ''; return; }

  const matches = S.events.filter(ev => {
    const searchable = [ev.type, ev.provider || '', ev.model || '', ev.detail || ''].join(' ').toLowerCase();
    return searchable.includes(q);
  }).slice(-20).reverse();

  results.innerHTML = matches.map(ev =>
    `<div class="search-result" data-idx="${ev._idx}">
      <span class="sr-time">${fmtTime(ev.ts)}</span>
      <span class="sr-body">${esc(ev.type)} ${(ev.model || ev.provider || '').slice(0, 40)} ${ev.detail ? esc(ev.detail.slice(0, 50)) : ''}</span>
    </div>`
  ).join('');

  results.querySelectorAll('.search-result').forEach(el => {
    el.addEventListener('click', () => {
      selectEvent(parseInt(el.dataset.idx || '0'));
      const searchOverlay = $('search-overlay') as HTMLElement;
      if (searchOverlay) searchOverlay.classList.remove('visible');
    });
  });
});

// ═══ BUTTONS ═══
($('btn-pause') as HTMLElement)?.addEventListener('click', () => {
  S.paused = !S.paused;
  feed.classList.toggle('paused', S.paused);
  const btnPause = $('btn-pause') as HTMLElement;
  if (btnPause) { btnPause.classList.toggle('active', S.paused); btnPause.textContent = S.paused ? '▶' : '⏸'; }
});

($('btn-follow') as HTMLElement)?.addEventListener('click', () => {
  S.following = !S.following;
  const btnFollow = $('btn-follow') as HTMLElement;
  if (btnFollow) { btnFollow.classList.toggle('active', S.following); }
  if (S.following) feed.scrollTop = feed.scrollHeight;
});

($('btn-clear') as HTMLElement)?.addEventListener('click', clearFeed);
($('context-close') as HTMLElement)?.addEventListener('click', () => contextStrip?.classList.add('collapsed'));
($('dossier-close') as HTMLElement)?.addEventListener('click', closeDossier);

const helpClose = $('help-close') as HTMLElement;
helpClose?.addEventListener('click', () => { const h = $('help-overlay') as HTMLElement; if (h) h.style.display = 'none'; });

const helpOverlay = $('help-overlay') as HTMLElement;
helpOverlay?.addEventListener('click', (e) => { if (e.target === helpOverlay) helpOverlay.style.display = 'none'; });

($('err-badge') as HTMLElement)?.addEventListener('click', () => {
  S.errFilter = !S.errFilter;
  const filterInput = $('filter') as HTMLInputElement;
  if (filterInput) filterInput.value = '';
  S.filter = '';
  const errBadge = $('err-badge') as HTMLElement;
  if (errBadge) {
    errBadge.style.background = S.errFilter ? 'var(--red)' : '';
    errBadge.style.borderRadius = S.errFilter ? '2px' : '';
    errBadge.style.color = S.errFilter ? 'var(--bg)' : 'var(--red)';
    errBadge.title = S.errFilter ? 'Showing errors only (click to show all)' : 'Filter errors';
  }
  rerenderFeed();
});

// ═══ EXPORT ═══
($('export-btn') as HTMLElement)?.addEventListener('click', () => {
  const blob = new Blob([JSON.stringify(S.events, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `nullclaw-events-${Date.now()}.json`;
  a.click();
  URL.revokeObjectURL(url);
});

// ═══ VIEW TABS ═══
document.querySelectorAll('.vtab').forEach(tab => {
  tab.addEventListener('click', () => switchView((tab as HTMLElement).dataset.view as 'feed' | 'trace'));
});

// ═══ DOSSIER TABS ═══
document.querySelectorAll('.dtab').forEach(tab => {
  tab.addEventListener('click', () => switchTab((tab as HTMLElement).dataset.tab as DossierTab));
});

// ═══ EVENT DELEGATION — dossier-content ═══
const dossierContent = $('dossier-content') as HTMLElement;
dossierContent?.addEventListener('click', (e) => {
  const relEntity = (e.target as HTMLElement).closest('.rel-entity');
  if (relEntity) {
    const name = (relEntity as HTMLElement).dataset.name;
    if (name) {
      const ent = S.entities[name];
      if (ent && ent.events.length > 0) openDossier(ent.events[ent.events.length - 1]._idx!);
    }
    return;
  }
  const dtEvent = (e.target as HTMLElement).closest('.dt-event');
  if (dtEvent) {
    selectEvent(parseInt((dtEvent as HTMLElement).dataset.idx || '0'));
    return;
  }
  const copyBtn = (e.target as HTMLElement).closest('.copy-btn');
  if (copyBtn) {
    const type = (copyBtn as HTMLElement).dataset.copy;
    let text = '';
    if (type === 'raw') {
      text = document.getElementById('raw-json')?.textContent || '';
    } else if (type === 'context') {
      text = $('dossier-content')?.textContent || '';
    }
    if (text) {
      navigator.clipboard.writeText(text).then(() => {
        copyBtn.textContent = 'OK';
        setTimeout(() => { copyBtn.textContent = 'COPY'; }, 1200);
      });
    }
    return;
  }
});

// ═══ DEMO MODE ═══
function loadMockData(): void {
  const now = Date.now() * 1e6;
  const base = now - 120_000_000_000;
  const mockEvents: SpyEvent[] = [
    { ts: base, type: 'agent_start', provider: 'ollama-cloud', model: 'qwen3-coder-next:cloud' },
    { ts: base + 100_000_000, type: 'llm_request', provider: 'ollama-cloud', model: 'qwen3-coder-next:cloud', v1: 42, content: '[{"r":"system","c":"You are NullClaw, a Zig-based AI agent..."},{"r":"user","c":"What is 2+2?"}]' },
    { ts: base + 2_500_000_000, type: 'llm_response', provider: 'ollama-cloud', model: 'qwen3-coder-next:cloud', v1: 2400, ok: true, content: '{"r":"The answer is 4.","t":[]}' },
    { ts: base + 2_600_000_000, type: 'turn_complete' },
    { ts: base + 15_000_000_000, type: 'llm_request', provider: 'anthropic', model: 'claude-sonnet-4', v1: 67, content: '[{"r":"system","c":"You are NullClaw, a Zig-based AI agent with tool access..."},{"r":"user","c":"List files in /tmp"},{"r":"assistant","c":"I\'ll list the files for you."}]' },
    { ts: base + 16_200_000_000, type: 'llm_response', provider: 'anthropic', model: 'claude-sonnet-4', v1: 1200, ok: true, content: '{"r":"I will run ls to check the tmp directory.","t":[{"n":"shell","a":"ls -la /tmp | head -20"}]}' },
    { ts: base + 16_300_000_000, type: 'tool_call_start', model: 'shell' },
    { ts: base + 18_500_000_000, type: 'tool_call', model: 'shell', v1: 2200, ok: true, detail: 'ls -la /tmp | head -20' },
    { ts: base + 19_000_000_000, type: 'llm_request', provider: 'anthropic', model: 'claude-sonnet-4', v1: 89, content: '[{"r":"system","c":"You are NullClaw..."},{"r":"user","c":"List files in /tmp"},{"r":"assistant","c":"I\'ll list the files..."},{"r":"tool","c":"ls -la /tmp | head -20\\ntotal 48\\ndrwxrwxrwt  12 root root 4096 ..."}]' },
    { ts: base + 20_800_000_000, type: 'llm_response', provider: 'anthropic', model: 'claude-sonnet-4', v1: 1800, ok: true, content: '{"r":"I can see the files. Let me check the gateway code now.","t":[{"n":"file_read","a":"src/gateway.zig lines 2677-2690"}]}' },
    { ts: base + 20_900_000_000, type: 'tool_call_start', model: 'file_read' },
    { ts: base + 21_100_000_000, type: 'tool_call', model: 'file_read', v1: 180, ok: true, detail: 'src/gateway.zig lines 2677-2690', content: '[{"r":"system","c":"You are NullClaw..."},{"r":"user","c":"List files in /tmp"},{"r":"assistant","c":"Found the files."},{"r":"tool","c":"ls -la /tmp..."},{"r":"tool","c":"src/gateway.zig lines 2677-2690..."}]' },
    { ts: base + 21_500_000_000, type: 'llm_request', provider: 'anthropic', model: 'claude-sonnet-4', v1: 112 },
    { ts: base + 23_900_000_000, type: 'llm_response', provider: 'anthropic', model: 'claude-sonnet-4', v1: 2400, ok: true, content: '{"r":"Found the issue. Writing the fix now.","t":[{"n":"file_write","a":"src/observability/event_tap.zig"}]}' },
    { ts: base + 24_000_000_000, type: 'tool_call_start', model: 'file_write' },
    { ts: base + 24_300_000_000, type: 'tool_call', model: 'file_write', v1: 280, ok: true, detail: 'src/observability/event_tap.zig' },
    { ts: base + 24_700_000_000, type: 'turn_complete' },
    { ts: base + 35_000_000_000, type: 'channel_message', provider: 'telegram', model: 'inbound', content: '[{"r":"system","c":"You are NullClaw..."},{"r":"user","c":"Fix the build and run tests"},{"r":"assistant","c":"Running zig build test..."}]' },
    { ts: base + 36_000_000_000, type: 'llm_request', provider: 'anthropic', model: 'claude-sonnet-4', v1: 55 },
    { ts: base + 37_500_000_000, type: 'llm_response', provider: 'anthropic', model: 'claude-sonnet-4', v1: 1500, ok: true, content: '{"r":"Running the test suite to verify everything passes.","t":[{"n":"shell","a":"zig build test"}]}' },
    { ts: base + 37_600_000_000, type: 'tool_call_start', model: 'shell' },
    { ts: base + 39_200_000_000, type: 'tool_call', model: 'shell', v1: 1600, ok: true, detail: 'zig build test -> 4758 pass', content: '[{"r":"system","c":"You are NullClaw..."},{"r":"user","c":"Fix the build and run tests"},{"r":"assistant","c":"Tests pass. Patching gateway..."}]' },
    { ts: base + 39_500_000_000, type: 'llm_request', provider: 'anthropic', model: 'claude-sonnet-4', v1: 98 },
    { ts: base + 41_000_000_000, type: 'llm_response', provider: 'anthropic', model: 'claude-sonnet-4', v1: 1500, ok: true, content: '{"r":"All tests pass. Applying the patch to gateway.zig now.","t":[{"n":"patch","a":"gateway.zig: replaced SSE loop"}]}' },
    { ts: base + 41_100_000_000, type: 'tool_call_start', model: 'patch' },
    { ts: base + 41_400_000_000, type: 'tool_call', model: 'patch', v1: 350, ok: true, detail: 'gateway.zig: replaced SSE loop' },
    { ts: base + 41_800_000_000, type: 'turn_complete' },
    { ts: base + 41_900_000_000, type: 'channel_message', provider: 'telegram', model: 'outbound', content: '[{"r":"system","c":"You are NullClaw..."},{"r":"user","c":"What is the weather?"}]' },
    { ts: base + 55_000_000_000, type: 'llm_request', provider: 'openrouter', model: 'gpt-4o', v1: 38 },
    { ts: base + 56_200_000_000, type: 'llm_response', provider: 'openrouter', model: 'gpt-4o', v1: 1200, ok: false, detail: 'rate limit exceeded: 429', content: '{"r":"","t":[]}' },
    { ts: base + 56_300_000_000, type: 'tool_call_start', model: 'shell' },
    { ts: base + 57_800_000_000, type: 'tool_call', model: 'shell', v1: 1500, ok: true, detail: 'make restart -> Done' },
    { ts: base + 58_200_000_000, type: 'turn_complete' },
    { ts: base + 70_000_000_000, type: 'heartbeat_tick' },
    { ts: base + 80_000_000_000, type: 'llm_request', provider: 'anthropic', model: 'claude-sonnet-4', v1: 71 },
    { ts: base + 82_100_000_000, type: 'llm_response', provider: 'anthropic', model: 'claude-sonnet-4', v1: 2100, ok: true, content: '{"r":"Searching for Zig 0.16 migration patterns.","t":[{"n":"web_search","a":"zig 0.16 migration guide"}]}' },
    { ts: base + 82_200_000_000, type: 'tool_call_start', model: 'web_search' },
    { ts: base + 84_500_000_000, type: 'tool_call', model: 'web_search', v1: 2300, ok: true, detail: 'zig 0.16 migration guide' },
    { ts: base + 85_000_000_000, type: 'llm_request', provider: 'anthropic', model: 'claude-sonnet-4', v1: 95 },
    { ts: base + 87_200_000_000, type: 'llm_response', provider: 'anthropic', model: 'claude-sonnet-4', v1: 2200, ok: true },
    { ts: base + 87_300_000_000, type: 'turn_complete' },
    { ts: base + 87_400_000_000, type: 'agent_end', v1: 51_400_000_000, v2: 4820 },
    { ts: base + 95_000_000_000, type: 'err', provider: 'memory', detail: 'sqlite: database is locked' },
    { ts: base + 96_100_000_000, type: 'heartbeat_tick' },
    { ts: base + 100_000_000_000, type: 'agent_start', provider: 'ollama-cloud', model: 'qwen3-coder-next:cloud' },
    { ts: base + 100_000_000_000, type: 'llm_request', provider: 'ollama-cloud', model: 'qwen3-coder-next:cloud', v1: 200 },
    { ts: base + 102_000_000_000, type: 'llm_response', provider: 'ollama-cloud', model: 'qwen3-coder-next:cloud', v1: 2000, ok: true, content: '{"r":"Checking for remaining TODOs and FIXMEs in the codebase.","t":[{"n":"shell","a":"grep TODO src/"},{"n":"shell","a":"grep FIXME src/"},{"n":"shell","a":"grep HACK src/"}]}' },
    { ts: base + 102_100_000_000, type: 'tool_call_start', model: 'shell' },
    { ts: base + 103_600_000_000, type: 'tool_call', model: 'shell', v1: 1500, ok: true, detail: 'grep TODO src/ -> 14 matches' },
    { ts: base + 104_000_000_000, type: 'tool_call_start', model: 'shell' },
    { ts: base + 105_200_000_000, type: 'tool_call', model: 'shell', v1: 1200, ok: true, detail: 'grep FIXME src/ -> 3' },
    { ts: base + 105_500_000_000, type: 'tool_call_start', model: 'shell' },
    { ts: base + 106_800_000_000, type: 'tool_call', model: 'shell', v1: 1300, ok: true, detail: 'grep HACK src/ -> 7' },
    { ts: base + 107_000_000_000, type: 'tool_iterations_exhausted', v1: 90 },
    { ts: base + 107_100_000_000, type: 'turn_complete' },
    { ts: base + 107_200_000_000, type: 'agent_end', v1: 7_200_000_000, v2: 810 },
  ];
  appendEvents(mockEvents);
  openDossier(Math.floor(mockEvents.length * 0.6));
}

// ═══ INIT ═══
const urlParams = new URLSearchParams(window.location.search);
if (urlParams.has('demo')) {
  const conn = $('connecting');
  if (conn) conn.remove();
  S.connected = true;
  const dot = $('sse-dot');
  if (dot) dot.className = 'status-dot ok';
  loadMockData();
} else {
  connectPolling();
}

pollStatus();
setInterval(pollStatus, 5000);

initTraceTooltip();
initTraceClickHandlers();
pollTrace();
setInterval(pollTrace, 1000);

setInterval(() => {
  if (S.status && S.status.uptime_ns) {
    const uptimeEl = $('uptime');
    if (uptimeEl) uptimeEl.textContent = fmtUptime(S.status.uptime_ns + (Date.now() - S.startTime) * 1e6);
  }
}, 1000);
