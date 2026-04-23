// ═══ POLLING (not SSE — gateway is single-threaded) ═══
import { S } from './state';
import { $ } from './utils';
import { appendEvents } from './feed';
import { openDossier } from './dossier';
import type { StatusResponse } from './types';

export function pollEvents(): void {
  const proto = location.protocol === 'https:' ? 'https' : 'http';
  const url = `${proto}://${location.host}/api/events?since=${S.sincePos !== null ? S.sincePos : 0}`;

  fetch(url).then(res => res.json()).then((data: { pos?: number; events?: unknown[]; error?: string }) => {
    if (data.error) return;
    S.connected = true;
    S.pollBackoff = 0;
    const dot = $('sse-dot');
    if (dot) dot.className = 'status-dot ok';
    const conn = $('connecting');
    if (conn) conn.remove();

    if (data.pos) {
      S.sincePos = data.pos;
    }
    if (data.events && Array.isArray(data.events) && data.events.length > 0) {
      appendEvents(data.events as import('./types').SpyEvent[]);
      if (!S.zoomedEvent) {
        openDossier(S.events.length - 1);
      }
    }
  }).catch((err: Error) => {
    S.connected = false;
    const dot = $('sse-dot');
    if (dot) dot.className = 'status-dot warn';
    console.error('poll error:', err);
  });
}

export function connectPolling(): void {
  S.pollBackoff = 0;
  S.pollSkips = 0;
  pollEvents();
  setInterval(() => {
    if (!S.connected) {
      S.pollSkips = (S.pollSkips || 0) + 1;
      const maxSkip = 1 << Math.min(S.pollBackoff || 0, 5);
      if ((S.pollSkips || 0) < maxSkip) return;
      S.pollSkips = 0;
      S.pollBackoff = (S.pollBackoff || 0) + 1;
    }
    pollEvents();
  }, 1000);
}

// ═══ STATUS POLLING ═══
export async function pollStatus(): Promise<void> {
  try {
    const proto = location.protocol === 'https:' ? 'https' : 'http';
    const res = await fetch(`${proto}://${location.host}/api/status`);
    S.status = (await res.json()) as StatusResponse;
    renderStatus();
  } catch {
    // silent — will retry
  }
}

const MODEL_PRICES: Record<string, { input: number; output: number }> = {
  'claude-sonnet-4': { input: 3, output: 15 },
  'claude-opus-4': { input: 15, output: 75 },
  'gpt-4o': { input: 2.5, output: 10 },
};

function renderStatus(): void {
  if (!S.status) return;

  const uptimeEl = $('uptime');
  if (uptimeEl) {
    const uptimeSec = (S.status.uptime_ns || 0) / 1e9;
    const d = Math.floor(uptimeSec / 86400);
    const h = Math.floor((uptimeSec % 86400) / 3600);
    const m = Math.floor((uptimeSec % 3600) / 60);
    uptimeEl.textContent = d > 0 ? `${d}d ${h}h ${m}m` : h > 0 ? `${h}h ${m}m` : `${m}m`;
  }

  const dot = $('health-status');
  if (S.status.health && dot) {
    const comps = Object.entries(S.status.health);
    const healthy = comps.filter(([, v]) => v.status === 'ok' || v.status === 'healthy').length;
    const total = comps.length;
    dot.textContent = `${healthy}/${total}`;
    dot.style.color = healthy === total ? 'var(--green)' : healthy > 0 ? 'var(--amber)' : 'var(--red)';
  }

  const costLabel = $('cost-label');
  if (costLabel) {
    let totalCost = 0;
    S.events.forEach(e => {
      if (e.type === 'llm_response' && e.model) {
        const shortModel = e.model.split('/').pop();
        const prices = shortModel ? MODEL_PRICES[shortModel] : undefined;
        if (prices && e.v1 && e.v1 > 0) {
          const estOutputTokens = Math.round((e.v1 / 1000) * 100);
          totalCost += (estOutputTokens * prices.output) / 1e6;
        }
      }
    });
    costLabel.textContent = '$' + totalCost.toFixed(4);
  }

  const ctxLabel = $('ctx-label');
  if (ctxLabel) {
    if (S.status.context_window) {
      ctxLabel.textContent = 'CTX ' + S.status.context_window;
    } else {
      const totalIn = S.events.filter(e => e.type === 'llm_request').reduce((s, e) => s + (e.v1 || 0), 0);
      ctxLabel.textContent = '~' + totalIn + ' tok';
    }
  }
}

// ═══ CONTEXT STRIP ═══
export function showContext(ev: import('./types').SpyEvent | null): void {
  const contextStrip = $('context-strip');
  if (!ev || !ev.detail || !contextStrip) return;
  contextStrip.classList.remove('collapsed');
  const title = $('context-title');
  const body = $('context-body');
  if (title) title.textContent = (ev.model || ev.provider || ev.type).toUpperCase();
  if (body) body.textContent = ev.detail;
}
