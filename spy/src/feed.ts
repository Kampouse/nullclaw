// ═══ FEED RENDERING ═══
import { S } from './state';
import { $, esc, fmtTime, fmtDuration } from './utils';
import { TYPE_ICONS } from './icons';
import { trackEntity, trackFileOps } from './entities';
import { openDossier } from './dossier';
import type { SpyEvent } from './types';

export function renderEvent(ev: SpyEvent, idx: number): HTMLDivElement {
  const div = document.createElement('div');
  div.className = 'event';
  div.dataset.type = ev.type;
  div.dataset.idx = String(idx);

  if (ev.type === 'tool_call' || ev.type === 'llm_response') {
    div.classList.add(ev.ok ? 'ev-ok' : 'ev-fail');
  }
  if (idx === S.selectedIdx) div.classList.add('selected');
  if (S.zoomedEvent && S.zoomedEvent._idx === idx) div.classList.add('zoomed');

  if (S.filter || S.errFilter) {
    if (S.errFilter && ev.type !== 'err' && ev.ok !== false) {
      div.style.display = 'none';
    } else if (S.filter) {
      const searchable = [ev.type, ev.provider || '', ev.model || '', ev.detail || ''].join(' ').toLowerCase();
      if (!searchable.includes(S.filter.toLowerCase())) {
        div.style.display = 'none';
      }
    }
  }
  if (ev.type === 'heartbeat_tick' && !S.showHeartbeats) {
    div.style.display = 'none';
  }

  const icon = TYPE_ICONS[ev.type] || '·';
  const time = fmtTime(ev.ts);

  let name = '', detail = '', metric = '';
  switch (ev.type) {
    case 'llm_request':
      name = (ev.provider || '') + '/' + (ev.model || '');
      detail = ev.v1 ? String(ev.v1) + ' msgs' : '';
      break;
    case 'llm_response':
      name = (ev.provider || '') + '/' + (ev.model || '');
      metric = fmtDuration(ev.v1 || 0);
      if (ev.detail) metric += ' ' + ev.detail.slice(0, 30);
      break;
    case 'tool_call_start':
      name = ev.model || ev.provider || 'tool';
      break;
    case 'tool_call':
      name = ev.model || ev.provider || 'tool';
      metric = fmtDuration(ev.v1 || 0);
      metric += ev.ok ? ' ✓' : ' ✗';
      break;
    case 'agent_start':
      name = (ev.provider || '') + ' ' + (ev.model || '');
      break;
    case 'agent_end':
      name = 'agent';
      metric = fmtDuration(ev.v1 || 0);
      break;
    case 'channel_message':
      name = (ev.provider || '') + ':' + (ev.model || '');
      detail = ev.detail ? ev.detail.slice(0, 60) : '';
      break;
    case 'err':
      name = ev.provider || 'error';
      detail = ev.detail || '';
      break;
    case 'heartbeat_tick':
      name = 'heartbeat';
      break;
    case 'turn_complete':
      name = 'turn complete';
      break;
    case 'tool_iterations_exhausted':
      name = 'iterations exhausted';
      metric = (ev.v1 || 0) + ' iters';
      break;
  }

  div.innerHTML = `
    <span class="ev-time">${time}</span>
    <span class="ev-type">${icon}</span>
    <span class="ev-body">
      <span class="ev-name">${esc(name)}</span>
      ${detail ? `<span class="ev-detail">${esc(detail)}</span>` : ''}
    </span>
    ${metric ? `<span class="ev-metric ${ev.type === 'tool_call' ? (ev.ok ? 'ok' : 'fail') : ''}">${esc(metric)}</span>` : ''}
  `;

  div.addEventListener('click', () => openDossier(idx));

  return div;
}

export function updateLiveState(): void {
  const feed = $('feed');
  if (!feed) return;
  const last = S.events[S.events.length - 1];
  const wasLive = S.liveTurn;
  S.liveTurn = !!(last && last.type !== 'turn_complete' && last.type !== 'agent_end' && last.type !== 'heartbeat_tick');
  if (wasLive !== S.liveTurn) {
    feed.querySelectorAll('.event.live').forEach(el => el.classList.remove('live'));
    if (S.liveTurn) {
      const lastEl = feed.querySelector(`.event[data-idx="${last._idx}"]`);
      if (lastEl) lastEl.classList.add('live');
    }
  } else if (S.liveTurn) {
    feed.querySelectorAll('.event.live').forEach(el => el.classList.remove('live'));
    const lastEl = feed.querySelector(`.event[data-idx="${last._idx}"]`);
    if (lastEl) lastEl.classList.add('live');
  }
}

export function updateErrorBadge(): void {
  const errCount = S.events.filter(e => e.type === 'err' || e.ok === false).length;
  const badge = $('err-badge');
  const count = $('err-count');
  if (errCount > 0 && badge && count) {
    badge.style.display = 'inline';
    badge.style.color = 'var(--red)';
    count.textContent = String(errCount);
  } else if (badge) {
    badge.style.display = 'none';
  }
}

export function appendEvents(newEvents: SpyEvent[]): void {
  const feed = $('feed');
  const hadConnecting = $('connecting');
  if (hadConnecting) hadConnecting.remove();

  const frag = document.createDocumentFragment();
  newEvents.forEach((ev) => {
    const idx = S.events.length;
    ev._idx = idx;
    S.events.push(ev);
    trackEntity(ev);
    trackFileOps(ev);
    frag.appendChild(renderEvent(ev, idx));
  });

  feed?.appendChild(frag);
  const eventCount = $('event-count');
  if (eventCount) eventCount.textContent = String(S.events.length);

  updateLiveState();
  updateErrorBadge();

  if (S.following && !S.paused && feed) {
    feed.scrollTop = feed.scrollHeight;
  }
}

export function rerenderFeed(): void {
  const feed = $('feed');
  if (!feed) return;
  const scrollTop = feed.scrollTop;
  const frag = document.createDocumentFragment();
  let sessionNum = 0;
  let sessionEvents = 0;
  let sessionStartTs = 0;
  S.events.forEach((ev, idx) => {
    if (ev.type === 'agent_start') {
      if (sessionNum > 0 && sessionEvents > 0) {
        const prevHdr = frag.querySelector(`.session-hdr[data-session="${sessionNum}"]`);
        if (prevHdr) {
          const span = (ev.ts - sessionStartTs) / 1e6;
          const statsEl = prevHdr.querySelector('.session-stats');
          if (statsEl) statsEl.textContent = `${sessionEvents} events · ${fmtDuration(span)}`;
        }
      }
      sessionNum++;
      sessionEvents = 0;
      sessionStartTs = ev.ts;
      const hdr = document.createElement('div');
      hdr.className = 'session-hdr';
      hdr.dataset.session = String(sessionNum);
      hdr.innerHTML = `<span style="color:var(--text-dim);font-size:9px;letter-spacing:1px">SESSION ${sessionNum}</span> <span class="session-stats" style="color:var(--text-dim);font-size:9px"></span>`;
      hdr.addEventListener('click', () => {
        hdr.classList.toggle('collapsed');
        feed.querySelectorAll(`.event[data-session="${sessionNum}"]`).forEach(el => {
          el.style.display = hdr.classList.contains('collapsed') ? 'none' : '';
        });
      });
      frag.appendChild(hdr);
    }
    if (sessionNum > 0) sessionEvents++;
    const row = renderEvent(ev, idx);
    if (sessionNum > 0) row.dataset.session = String(sessionNum);
    frag.appendChild(row);
  });
  if (sessionNum > 0) {
    const lastHdr = frag.querySelector(`.session-hdr[data-session="${sessionNum}"]`);
    if (lastHdr && sessionEvents > 0) {
      const lastEv = S.events[S.events.length - 1];
      const span = lastEv ? (lastEv.ts - sessionStartTs) / 1e6 : 0;
      const statsEl = lastHdr.querySelector('.session-stats');
      if (statsEl) statsEl.textContent = `${sessionEvents} events · ${fmtDuration(span)}`;
    }
  }
  feed.innerHTML = '';
  feed.appendChild(frag);
  feed.scrollTop = scrollTop;
}

export function selectEvent(idx: number): void {
  const feed = $('feed');
  if (!feed) return;
  const prev = feed.querySelector('.event.selected');
  if (prev) prev.classList.remove('selected');
  S.selectedIdx = idx;
  const el = feed.querySelector(`.event[data-idx="${idx}"]`);
  if (el) {
    el.classList.add('selected');
    el.scrollIntoView({ block: 'nearest' });
  }
}

export function clearFeed(): void {
  const feed = $('feed');
  S.events = [];
  S.sincePos = null;
  S.selectedIdx = -1;
  S.entities = {};
  S.fileOps = {};
  S.activeFile = null;
  if (feed) feed.innerHTML = '';
  const eventCount = $('event-count');
  if (eventCount) eventCount.textContent = '0';
}
