// ═══ TRACE VIEW ═══
import { S } from './state';
import { $, esc, fmtTime, fmtDuration } from './utils';
import { TYPE_ICONS, OP_COLORS, OP_ICONS } from './icons';
import { extractFileOps } from './entities';
import { openDossier } from './dossier';
import type { SpyEvent, EventType, TraceFilter } from './types';

const TRACE_TYPE_COLORS: Record<EventType | string, string> = {
  llm_request: 'bar-llm', llm_response: 'bar-llm',
  tool_call_start: 'bar-tool', tool_call: 'bar-tool',
  http_request: 'bar-http',
  err: 'bar-err',
  turn_complete: 'bar-dim', heartbeat_tick: 'bar-dim',
  channel_message: 'bar-msg',
  agent_start: 'bar-agent', agent_end: 'bar-agent',
  tool_iterations_exhausted: 'bar-warn',
};

const TRACE_TYPE_FILTERS: Record<string, EventType[]> = {
  llm: ['llm_request', 'llm_response'],
  tool: ['tool_call_start', 'tool_call'],
  http: ['http_request'],
  err: ['err', 'tool_iterations_exhausted'],
  msg: ['channel_message'],
};

export function switchView(view: 'feed' | 'trace'): void {
  S.activeView = view;
  document.querySelectorAll('.vtab').forEach(t => t.classList.toggle('active', t.dataset.view === view));
  const fp = $('feed-panel');
  const tp = $('trace-panel');
  if (view === 'feed') {
    if (fp) fp.style.display = '';
    if (tp) tp.style.display = 'none';
  } else {
    if (fp) fp.style.display = 'none';
    if (tp) tp.style.display = 'flex';
    if (S.traceDirty || Object.keys(S.traceSessions).length === 0) {
      renderTraceView();
      S.traceDirty = false;
    }
  }
}

export function pollTrace(): void {
  const proto = location.protocol === 'https:' ? 'https' : 'http';
  const url = `${proto}://${location.host}/api/trace?since=${S.traceSincePos !== null ? S.traceSincePos : 0}`;
  fetch(url).then(res => res.json()).then((data: { pos?: number; sessions?: Record<string, SpyEvent[]>; error?: string }) => {
    if (data.error) return;
    if (data.pos) S.traceSincePos = data.pos;
    if (data.sessions && typeof data.sessions === 'object') {
      let changed = false;
      for (const [sess, evts] of Object.entries(data.sessions)) {
        if (!S.traceSessions[sess]) S.traceSessions[sess] = [];
        S.traceSessions[sess].push(...evts);
        changed = true;
      }
      if (changed) {
        let tidx = 0;
        for (const evts of Object.values(S.traceSessions)) {
          for (const ev of evts) {
            if (ev._tidx === undefined) {
              ev._tidx = tidx++;
              const match = S.events.find(e => e.ts === ev.ts && e.type === ev.type && e.session === ev.session);
              if (match) ev._feedIdx = match._idx;
            }
          }
        }
        if (S.activeView === 'trace') renderTraceView();
        else S.traceDirty = true;
      }
    }
  }).catch((err: Error) => {
    console.error('trace poll error:', err);
  });
}

function renderTraceView(): void {
  renderTraceSessions();
  renderTraceFilters();
  renderTraceFiles();
  renderTraceWaterfall();
}

function renderTraceFiles(): void {
  const el = $('trace-files');
  if (!el) return;
  const paths = Object.keys(S.fileOps);
  if (paths.length === 0) { el.innerHTML = ''; return; }
  const sorted = paths.sort((a, b) => {
    const aLast = S.fileOps[a][S.fileOps[a].length - 1].ts;
    const bLast = S.fileOps[b][S.fileOps[b].length - 1].ts;
    return bLast - aLast;
  }).slice(0, 30);

  let html = '<span style="color:var(--text-dim);font-size:9px;opacity:0.5;margin-right:4px">FILES</span>';
  for (const path of sorted) {
    const ops = S.fileOps[path];
    const primaryOp = import('./entities').getFilePrimaryOp ? (() => { const m = require('./entities'); return m.getFilePrimaryOp(path); })() : (() => { const { getFilePrimaryOp } = require('./entities'); return getFilePrimaryOp(path); })();
    // use imported function properly
    const { getFilePrimaryOp } = require('./entities');
    const pOp = getFilePrimaryOp(path);
    const opLetter = OP_ICONS[pOp] || '?';
    const count = ops.length;
    const basename = path.split('/').pop();
    const isActive = S.activeFile === path;
    html += `<div class="file-chip op-${pOp} ${isActive ? 'active' : ''}" data-path="${esc(path)}" title="${esc(path)} — ${count} ops">
      <span class="fc-op">${opLetter}</span>${esc(basename || '')}<span class="fc-count">${count}</span>
    </div>`;
  }
  el.innerHTML = html;
}

export function toggleTraceFile(path: string): void {
  S.activeFile = S.activeFile === path ? null : path;
  renderTraceFiles();
  renderTraceWaterfall();
}

function renderTraceSessions(): void {
  const el = $('trace-sessions');
  if (!el) return;
  const sessions = Object.entries(S.traceSessions);
  if (sessions.length === 0) {
    el.innerHTML = '<span style="color:var(--text-dim);font-size:10px;opacity:0.5">no sessions</span>';
    return;
  }
  let html = '';
  html += `<div class="trace-chip ${!S.activeSession ? 'active' : ''}" data-session="">ALL<span class="chip-count">${sessions.reduce((s, [, e]) => s + e.length, 0)}</span></div>`;
  for (const [hash, evts] of sessions) {
    const short = hash.slice(0, 8);
    html += `<div class="trace-chip ${S.activeSession === hash ? 'active' : ''}" data-session="${hash}">${short}<span class="chip-count">${evts.length}</span></div>`;
  }
  el.innerHTML = html;
}

function renderTraceFilters(): void {
  const el = $('trace-filters');
  if (!el) return;
  let html = '<span style="color:var(--text-dim);font-size:9px;opacity:0.5;margin-right:4px">FILTER</span>';
  for (const [key] of Object.entries(TRACE_TYPE_FILTERS)) {
    html += `<div class="tfilter-chip ${S.traceFilter === key ? 'active' : ''}" data-filter="${key}">${key.toUpperCase()}</div>`;
  }
  el.innerHTML = html;
}

function _traceEventLabel(ev: SpyEvent): string {
  switch (ev.type) {
    case 'llm_request': case 'llm_response': return (ev.provider || '') + '/' + (ev.model || '');
    case 'tool_call_start': case 'tool_call': return ev.model || ev.provider || 'tool';
    case 'http_request': return ev.provider || ev.detail || 'http';
    case 'channel_message': return (ev.provider || '') + ':' + (ev.model || '');
    case 'err': return ev.provider || 'error';
    case 'agent_start': return (ev.provider || '') + ' ' + (ev.model || '');
    case 'agent_end': return 'agent';
    case 'turn_complete': return 'turn complete';
    case 'heartbeat_tick': return 'heartbeat';
    case 'tool_iterations_exhausted': return 'iter exhausted';
    default: return ev.type;
  }
}

function _traceEventDuration(ev: SpyEvent): number {
  if (ev.type === 'llm_response' || ev.type === 'tool_call' || ev.type === 'http_request' || ev.type === 'agent_end') {
    return ev.v1 || 0;
  }
  return 0;
}

function _traceEventContent(ev: SpyEvent): string {
  const detail = ev.detail || '';
  const provider = ev.provider || '';
  const model = ev.model || '';
  const v1 = ev.v1 || 0;
  switch (ev.type) {
    case 'tool_call': return ev.content || detail || (model || provider || 'executed');
    case 'tool_call_start': return 'starting...';
    case 'llm_request': return (provider ? provider + ' ' : '') + (model || '') + ' → request';
    case 'llm_response': {
      const tokInfo = v1 > 0 ? v1 + 'ms' : '';
      return [tokInfo, detail].filter(Boolean).join(' · ') || (provider + ' ' + model + ' → response');
    }
    case 'http_request': return detail || (provider || 'request');
    case 'err': return detail || provider || 'error';
    case 'channel_message': return detail || (provider + ':' + model);
    case 'agent_start': return (provider || '') + ' ' + (model || '');
    case 'agent_end': return v1 > 0 ? 'completed in ' + fmtDuration(v1) : 'completed';
    case 'turn_complete': return v1 > 0 ? fmtDuration(v1) : 'done';
    case 'tool_iterations_exhausted': return detail || 'max iterations reached';
    case 'heartbeat_tick': return '';
    default: return detail || '';
  }
}

function _traceTypeShort(ev: SpyEvent): string {
  switch (ev.type) {
    case 'llm_request': case 'llm_response': return 'llm';
    case 'tool_call_start': case 'tool_call': return 'tool';
    case 'http_request': return 'http';
    case 'err': return 'err';
    case 'channel_message': return 'msg';
    case 'agent_start': case 'agent_end': return 'agt';
    case 'turn_complete': return 'turn';
    case 'heartbeat_tick': return 'hb';
    case 'tool_iterations_exhausted': return 'wrn';
    default: return ev.type.slice(0, 4);
  }
}

function _traceTypeColor(ev: SpyEvent): string {
  switch (ev.type) {
    case 'llm_request': case 'llm_response': return 'var(--purple)';
    case 'tool_call_start': case 'tool_call': return 'var(--cyan)';
    case 'http_request': return '#f0a030';
    case 'err': return 'var(--red)';
    case 'channel_message': return 'var(--magenta)';
    case 'agent_start': case 'agent_end': return 'var(--blue)';
    case 'turn_complete': case 'heartbeat_tick': return 'var(--text-dim)';
    case 'tool_iterations_exhausted': return 'var(--amber)';
    default: return 'var(--text-dim)';
  }
}

function renderTraceWaterfall(): void {
  const container = $('trace-waterfall');
  const ruler = $('trace-ruler');
  if (!container) return;

  let allEvents: SpyEvent[] = [];
  const sessions = S.activeSession
    ? { [S.activeSession]: S.traceSessions[S.activeSession] || [] }
    : S.traceSessions;
  for (const [, evts] of Object.entries(sessions)) {
    allEvents.push(...evts);
  }
  if (S.traceFilter && TRACE_TYPE_FILTERS[S.traceFilter]) {
    const allowed = new Set(TRACE_TYPE_FILTERS[S.traceFilter]);
    allEvents = allEvents.filter(e => allowed.has(e.type));
  }
  if (!S.showHeartbeats) allEvents = allEvents.filter(e => e.type !== 'heartbeat_tick');

  if (S.activeFile) {
    const { getFilePrimaryOp: gfp } = require('./entities');
    const filePaths = new Set<number>();
    for (const [path, ops] of Object.entries(S.fileOps)) {
      if (path === S.activeFile) {
        for (const op of ops) { if (op._evIdx !== undefined) filePaths.add(op._evIdx); }
      }
    }
    allEvents = allEvents.filter(e => {
      if (filePaths.has(e._feedIdx ?? -1)) return true;
      if (e.model && ['file_read', 'file_write', 'file_edit', 'file_append'].includes(e.model)) {
        if (e.detail && e.detail.includes(S.activeFile!.split('/').pop() || '')) return true;
      }
      if (e.type === 'llm_response' && e.content) {
        const ops = extractFileOps(e);
        if (ops.some(op => op.path === S.activeFile)) return true;
      }
      return false;
    });
  }

  if (allEvents.length === 0) {
    container.innerHTML = '<div class="trace-empty"><div class="icon">◉</div><div>no trace events</div><div class="hint">waiting for session data from /api/trace</div></div>';
    if (ruler) ruler.innerHTML = '';
    return;
  }

  const minTs = allEvents[0].ts;
  const maxTs = allEvents[allEvents.length - 1].ts;
  const totalMs = Math.max((maxTs - minTs) / 1e6, 1);
  let maxDur = 0;
  for (const ev of allEvents) { const dur = _traceEventDuration(ev); if (dur > maxDur) maxDur = dur; }
  const viewMs = Math.max(totalMs + maxDur * 0.1, 100);

  const rulerMarks = _computeRulerMarks(viewMs);
  if (ruler) {
    let rulerHtml = '';
    for (const ms of rulerMarks) {
      const pct = (ms / viewMs) * 100;
      rulerHtml += `<div class="trace-ruler-mark" style="left:${pct}%">${fmtDuration(ms)}</div>`;
    }
    ruler.innerHTML = rulerHtml;
  }

  let html = '';
  let prevType: EventType | null = null;
  for (const ev of allEvents) {
    const offsetMs = (ev.ts - minTs) / 1e6;
    const dur = _traceEventDuration(ev);
    const barClass = TRACE_TYPE_COLORS[ev.type] || 'bar-dim';
    const icon = TYPE_ICONS[ev.type] || '·';
    const label = _traceEventLabel(ev);
    const timeStr = fmtTime(ev.ts);
    const content = _traceEventContent(ev);
    const typeShort = _traceTypeShort(ev);
    const typeColor = _traceTypeColor(ev);
    const metric = dur > 0 ? fmtDuration(dur) : '';

    let barW: number;
    if (dur > 0) { barW = Math.max(2, Math.min(52, (dur / viewMs) * 52)); }
    else { barW = 2; }

    const breakClass = (prevType !== null && ev.type !== prevType) ? ' type-break' : '';
    prevType = ev.type;

    const selClass = (S.zoomedEvent && S.zoomedEvent._feedIdx === ev._feedIdx) ? ' selected' : '';
    const detail = ev.detail || '';
    const tooltipData = `data-ts="${ev.ts}" data-type="${esc(ev.type)}" data-label="${esc(label)}" data-detail="${esc(detail)}" data-metric="${esc(metric)}" data-ok="${String(ev.ok ?? '')}" data-provider="${esc(ev.provider || '')}" data-model="${esc(ev.model || '')}" data-content="${esc(content)}"`;

    const statusHtml = ev.ok === false
      ? '<span class="tr-status fail">✗</span>'
      : (dur > 0 ? '<span class="tr-status ok">✓</span>' : '');
    const contentClass = (ev.type === 'err') ? 'tr-content err-content' : 'tr-content';
    const contentEsc = content ? esc(content.length > 120 ? content.slice(0, 120) + '…' : content) : '';

    html += `<div class="trace-row${breakClass}${selClass}" ${tooltipData} data-idx="${ev._feedIdx !== undefined ? ev._feedIdx : -1}" style="border-left:2px solid ${typeColor}">`;
    html += `<span class="tr-time">${timeStr}</span>`;
    html += `<span class="tr-icon">${icon}</span>`;
    html += `<span class="tr-type-tag" style="color:${typeColor}">${typeShort}</span>`;
    html += `<span class="tr-label" title="${esc(label)}">${esc(label)}</span>`;
    html += `<span class="tr-dur">${metric}</span>`;
    html += `<span class="tr-bar-cell"><span class="tr-bar-inline ${barClass}" style="width:${barW}px"></span></span>`;
    html += `<span class="${contentClass}">${contentEsc}</span>`;
    html += statusHtml;
    html += `</div>`;
  }
  container.innerHTML = html;
}

function _computeRulerMarks(totalMs: number): number[] {
  const steps = [10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 15000, 30000, 60000, 120000, 300000, 600000];
  let interval = steps[0];
  for (const s of steps) {
    if (totalMs / s <= 20) { interval = s; break; }
    interval = s;
  }
  const marks: number[] = [];
  for (let ms = 0; ms <= totalMs; ms += interval) { marks.push(ms); }
  return marks;
}

let _traceTooltipEl: HTMLDivElement | null = null;
export function initTraceTooltip(): void {
  _traceTooltipEl = document.createElement('div');
  _traceTooltipEl.className = 'trace-tooltip';
  document.body.appendChild(_traceTooltipEl);
  const waterfall = $('trace-waterfall');
  if (!waterfall) return;
  waterfall.addEventListener('mousemove', (e) => {
    const row = (e.target as HTMLElement).closest('.trace-row');
    if (!row || !_traceTooltipEl) { _traceTooltipEl?.classList.remove('visible'); return; }
    const rowEl = row as HTMLElement;
    const ts = rowEl.dataset.ts;
    const type = rowEl.dataset.type;
    const label = rowEl.dataset.label;
    const detail = rowEl.dataset.detail;
    const metric = rowEl.dataset.metric;
    const ok = rowEl.dataset.ok;
    const content = rowEl.dataset.content || '';
    let ttHtml = `<div class="tt-type">${esc(type || '')}</div>`;
    ttHtml += `<div>${esc(label || '')}</div>`;
    if (metric) ttHtml += `<div style="color:var(--text-dim)">${esc(metric)}</div>`;
    if (ok === 'false') ttHtml += `<div style="color:var(--red)">✗ failed</div>`;
    if (content) ttHtml += `<div class="tt-content">${esc(content.length > 300 ? content.slice(0, 300) + '…' : content)}</div>`;
    else if (detail) ttHtml += `<div class="tt-detail">${esc(detail.length > 300 ? detail.slice(0, 300) + '…' : detail)}</div>`;
    ttHtml += `<div class="tt-detail">${ts ? fmtTime(Number(ts)) : ''}</div>`;
    _traceTooltipEl.innerHTML = ttHtml;
    _traceTooltipEl.classList.add('visible');
    _traceTooltipEl.style.left = (e.clientX + 12) + 'px';
    _traceTooltipEl.style.top = (e.clientY + 8) + 'px';
  });
  waterfall.addEventListener('mouseleave', () => { _traceTooltipEl?.classList.remove('visible'); });
}

export function initTraceClickHandlers(): void {
  const sessionsEl = $('trace-sessions');
  const filtersEl = $('trace-filters');
  const filesEl = $('trace-files');
  const waterfallEl = $('trace-waterfall');

  sessionsEl?.addEventListener('click', (e) => {
    const chip = (e.target as HTMLElement).closest('.trace-chip');
    if (!chip) return;
    S.activeSession = (chip as HTMLElement).dataset.session || null;
    renderTraceView();
  });

  filtersEl?.addEventListener('click', (e) => {
    const chip = (e.target as HTMLElement).closest('.tfilter-chip');
    if (!chip) return;
    const filter = (chip as HTMLElement).dataset.filter as TraceFilter;
    S.traceFilter = S.traceFilter === filter ? null : filter;
    renderTraceWaterfall();
  });

  filesEl?.addEventListener('click', (e) => {
    const chip = (e.target as HTMLElement).closest('.file-chip');
    if (!chip) return;
    toggleTraceFile((chip as HTMLElement).dataset.path || '');
  });

  waterfallEl?.addEventListener('click', (e) => {
    const row = (e.target as HTMLElement).closest('.trace-row');
    if (!row) return;
    const idx = parseInt((row as HTMLElement).dataset.idx || '-1');
    if (idx >= 0) openDossier(idx);
  });
}
