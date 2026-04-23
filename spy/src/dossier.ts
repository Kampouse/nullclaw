// ═══ DOSSIER PANEL ═══
import { S } from './state';
import { $, esc, fmtTime, fmtDuration } from './utils';
import { TYPE_ICONS, OP_COLORS, OP_ICONS } from './icons';
import { extractEntities, getFilePrimaryOp } from './entities';
import { selectEvent } from './feed';
import type {
  SpyEvent, ExtractedEntity, Entity, ToolStat,
  GraphNode, GraphEdge, TurnData, TurnResponse, ToolCallInfo, DossierTab, EntityType, FileOpType,
} from './types';

const TRIVIAL_TYPES: Set<string> = new Set(['heartbeat_tick', 'turn_complete']);

export function openDossier(idx: number): void {
  const ev = S.events[idx];
  if (!ev || TRIVIAL_TYPES.has(ev.type)) return;

  S.zoomedEvent = ev;
  const main = $('main');
  const feed = $('feed');
  if (main) main.classList.add('dossier-open');

  if (feed) {
    feed.querySelectorAll('.event.zoomed').forEach(e => e.classList.remove('zoomed'));
    const el = feed.querySelector(`.event[data-idx="${idx}"]`);
    if (el) el.classList.add('zoomed');
  }

  const ents = extractEntities(ev);
  const primary: ExtractedEntity = ents[0] || { name: ev.type, type: 'event' };

  const nameEl = $('entity-name');
  const typeEl = $('entity-type');
  const de = $('dossier-empty');
  if (nameEl) nameEl.textContent = primary.name;
  if (typeEl) typeEl.textContent = primary.type.toUpperCase();
  if (de) de.style.display = 'none';

  switchTab('overview');
  renderDossierOverview(primary, ev);
}

export function closeDossier(): void {
  S.zoomedEvent = null;
  const main = $('main');
  const feed = $('feed');
  const contextStrip = $('context-strip');
  if (main) main.classList.remove('dossier-open');
  if (feed) feed.querySelectorAll('.event.zoomed').forEach(e => e.classList.remove('zoomed'));
  if (contextStrip) contextStrip.classList.add('collapsed');
}

export function switchTab(tab: DossierTab): void {
  if (S.graphAnimId && S.activeTab === 'graph' && tab !== 'graph') {
    cancelAnimationFrame(S.graphAnimId);
    S.graphAnimId = null;
  }

  S.activeTab = tab;
  document.querySelectorAll('.dtab').forEach(t => t.classList.toggle('active', t.dataset.tab === tab));

  if (!S.zoomedEvent) return;
  const ev = S.zoomedEvent;
  const ents = extractEntities(ev);
  const primary: ExtractedEntity = ents[0] || { name: ev.type, type: 'event' };

  switch (tab) {
    case 'overview': renderDossierOverview(primary, ev); break;
    case 'graph': renderDossierGraph(primary); break;
    case 'timeline': renderDossierTimeline(primary); break;
    case 'context': renderDossierContext(primary); break;
    case 'files': renderDossierFiles(primary); break;
  }
}

// ═══ OVERVIEW TAB ═══
export function renderDossierOverview(primary: ExtractedEntity, ev: SpyEvent): void {
  const content = $('dossier-content');
  if (!content) return;
  const entityData: Entity | undefined = S.entities[primary.name];

  let statsHtml = `<div class="entity-stats">
    <div class="stat-card"><div class="stat-label">EVENTS</div><div class="stat-value">${entityData ? entityData.events.length : 1}</div></div>
    <div class="stat-card"><div class="stat-label">TYPE</div><div class="stat-value" style="font-size:12px">${primary.type}</div></div>`;

  if (entityData) {
    const relCount = Object.keys(entityData.related).length;
    statsHtml += `<div class="stat-card"><div class="stat-label">RELATED</div><div class="stat-value">${relCount}</div></div>`;

    const first = entityData.events[0];
    const last = entityData.events[entityData.events.length - 1];
    if (first && last) {
      const span = (last.ts - first.ts) / 1e6;
      statsHtml += `<div class="stat-card"><div class="stat-label">SPAN</div><div class="stat-value" style="font-size:11px">${fmtDuration(span)}</div></div>`;
    }
  }
  statsHtml += '</div>';

  // Tool performance summary
  const toolEvs = S.events.filter(e => e.type === 'tool_call');
  const toolStats: Record<string, ToolStat> = {};
  toolEvs.forEach(e => {
    const name = e.model || e.provider || 'unknown';
    if (!toolStats[name]) toolStats[name] = { ok: 0, fail: 0, totalMs: 0 };
    if (e.ok === false) toolStats[name].fail++;
    else toolStats[name].ok++;
    toolStats[name].totalMs += (e.v1 || 0);
  });
  const toolEntries = Object.entries(toolStats).sort((a, b) => (b[1].ok + b[1].fail) - (a[1].ok + a[1].fail)).slice(0, 8);
  if (toolEntries.length > 0) {
    statsHtml += `<div class="dossier-section" style="margin-top:10px"><div class="section-title">TOOLS</div>`;
    toolEntries.forEach(([name, s]) => {
      const total = s.ok + s.fail;
      const pct = total > 0 ? Math.round(s.ok / total * 100) : 100;
      const avgMs = total > 0 ? Math.round(s.totalMs / total) : 0;
      const color = pct === 100 ? 'var(--green)' : pct >= 80 ? 'var(--amber)' : 'var(--red)';
      statsHtml += `<div style="display:flex;justify-content:space-between;padding:2px 0;font-size:10px;border-bottom:1px solid var(--border)">
        <span style="color:var(--cyan)">${esc(name)}</span>
        <span><span style="color:${color}">${s.ok}/${total}</span> <span style="color:var(--text-dim)">${pct}%</span> <span style="color:var(--text-dim)">${fmtDuration(avgMs)}</span></span>
      </div>`;
    });
    statsHtml += '</div>';
  }

  let detailHtml = '';
  if (ev.detail) {
    detailHtml = `<div class="dossier-section">
      <div class="section-title">DETAIL</div>
      <div style="color:var(--text);font-size:11px;white-space:pre-wrap;word-break:break-all;padding:4px 0">${esc(ev.detail)}</div>
    </div>`;
  }

  let relatedHtml = '';
  if (entityData && Object.keys(entityData.related).length > 0) {
    const sorted = Object.entries(entityData.related).sort((a, b) => b[1] - a[1]).slice(0, 8);
    relatedHtml = `<div class="dossier-section">
      <div class="section-title">RELATED ENTITIES</div>
      ${sorted.map(([name, count]) => {
        const relType = S.entities[name] ? S.entities[name].type : '?';
        const color: Record<string, string> = { provider: 'var(--purple)', tool: 'var(--cyan)', file: 'var(--green)', model: 'var(--blue)' };
        return `<div style="display:flex;justify-content:space-between;padding:2px 0;cursor:pointer;border-bottom:1px solid var(--border)" class="rel-entity" data-name="${esc(name)}">
          <span style="color:${color[relType] || 'var(--text-dim)'}">${esc(name)}</span>
          <span style="color:var(--text-dim)">${count}×</span>
        </div>`;
      }).join('')}
    </div>`;
  }

  let rawHtml = `<div class="dossier-section">
    <div class="section-title" style="display:flex;justify-content:space-between;align-items:center">RAW <span class="copy-btn" data-copy="raw" style="color:var(--text-dim);font-size:9px;cursor:pointer;letter-spacing:0">COPY</span></div>
    <pre id="raw-json" style="color:var(--text-dim);font-size:10px;overflow-x:auto;white-space:pre-wrap">${esc(JSON.stringify(ev, null, 2))}</pre>
  </div>`;

  content.innerHTML = statsHtml + detailHtml + relatedHtml + rawHtml;
}

// ═══ GRAPH TAB ═══
const TYPE_COL: Record<EntityType, string> = {
  provider: '#a070f0', model: '#4a9eff', tool: '#4ac0e8', file: '#3dd68c',
  channel: '#f060c0', error: '#f05050', err: '#f05050', event: '#8888aa',
};

function col(t: EntityType): string {
  return TYPE_COL[t] || '#8888aa';
}

function nodeCol(n: GraphNode): string {
  if (n.type === 'file' && S.fileOps[n.id]) {
    return OP_COLORS[getFilePrimaryOp(n.id)] || '#3dd68c';
  }
  return TYPE_COL[n.type] || '#8888aa';
}

function nodeRadius(n: GraphNode): number {
  if (n.type === 'file' && S.fileOps[n.id]) {
    const ops = S.fileOps[n.id];
    return 6 + Math.min(ops.length, 30) * 0.7;
  }
  return 5 + Math.min(n.weight, 30) * 0.6;
}

export function renderDossierGraph(primary: ExtractedEntity): void {
  if (S.graphAnimId) { cancelAnimationFrame(S.graphAnimId); S.graphAnimId = null; }

  const content = $('dossier-content');
  if (!content) return;
  const allNames = Object.keys(S.entities);
  if (allNames.length === 0) {
    content.innerHTML = '<div class="empty-state"><div class="icon">◎</div><div>No entities tracked yet</div></div>';
    return;
  }

  const nodes: GraphNode[] = [];
  const edges: GraphEdge[] = [];
  const nmap: Record<string, number> = {};

  allNames.forEach(name => {
    const e = S.entities[name];
    if (!e || e.events.length === 0) return;
    nmap[name] = nodes.length;
    nodes.push({ id: name, type: e.type, label: name.split('/').pop(), weight: e.events.length, x: 0, y: 0, vx: 0, vy: 0 });
  });

  allNames.forEach(name => {
    const e = S.entities[name];
    if (!e) return;
    Object.entries(e.related).forEach(([rn, cnt]) => {
      if (nmap[name] === undefined || nmap[rn] === undefined) return;
      const dup = edges.find(ed => (ed.s === nmap[name] && ed.t === nmap[rn]) || (ed.s === nmap[rn] && ed.t === nmap[name]));
      if (!dup) edges.push({ s: nmap[name], t: nmap[rn], w: cnt });
    });
  });

  if (nodes.length === 0) {
    content.innerHTML = '<div class="empty-state"><div class="icon">◎</div><div>No entities tracked yet</div></div>';
    return;
  }

  content.innerHTML = '<div id="palantir-graph"><canvas id="pg-canvas"></canvas><div id="pg-tooltip" class="pg-tooltip"></div></div>';
  const wrap = $('palantir-graph') as HTMLDivElement;
  const canvas = $('pg-canvas') as HTMLCanvasElement;
  const tip = $('pg-tooltip') as HTMLDivElement;
  const ctx = canvas.getContext('2d')!;

  const dpr = window.devicePixelRatio || 1;
  function resize(): { w: number; h: number } {
    const r = wrap.getBoundingClientRect();
    canvas.width = r.width * dpr; canvas.height = r.height * dpr;
    canvas.style.width = r.width + 'px'; canvas.style.height = r.height + 'px';
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    return { w: r.width, h: r.height };
  }
  const { w: cw, h: ch } = resize();
  const cx = cw / 2, cy = ch / 2;

  nodes.forEach((n, i) => {
    const a = (i / nodes.length) * Math.PI * 2 - Math.PI / 2;
    const r = 60 + Math.random() * 80;
    n.x = cx + Math.cos(a) * r; n.y = cy + Math.sin(a) * r;
  });

  let cam = { x: 0, y: 0, z: 1 }, dragging = false, dragStart = { x: 0, y: 0 }, camStart = { x: 0, y: 0 };
  function w2s(wx: number, wy: number) { return { x: (wx - cx) * cam.z + cx + cam.x, y: (wy - cy) * cam.z + cy + cam.y }; }
  function s2w(sx: number, sy: number) { return { x: (sx - cx - cam.x) / cam.z + cx, y: (sy - cy - cam.y) / cam.z + cy }; }

  canvas.addEventListener('wheel', e => { e.preventDefault(); cam.z *= e.deltaY < 0 ? 1.12 : 0.89; cam.z = Math.max(0.3, Math.min(4, cam.z)); }, { passive: false });
  canvas.addEventListener('mousedown', e => { if (e.button === 0) { dragging = true; dragStart = { x: e.clientX, y: e.clientY }; camStart = { ...cam }; } });
  window.addEventListener('mousemove', e => { if (dragging) { cam.x = camStart.x + (e.clientX - dragStart.x); cam.y = camStart.y + (e.clientY - dragStart.y); } });
  window.addEventListener('mouseup', () => { dragging = false; });

  let hovered: GraphNode | null = null;
  canvas.addEventListener('mousemove', e => {
    if (dragging) { tip.style.display = 'none'; return; }
    const rect = canvas.getBoundingClientRect();
    const mp = s2w(e.clientX - rect.left, e.clientY - rect.top);
    hovered = null;
    for (let i = nodes.length - 1; i >= 0; i--) {
      const n = nodes[i];
      const nr = nodeRadius(n);
      const dx = mp.x - n.x, dy = mp.y - n.y;
      if (dx * dx + dy * dy < (nr + 6) * (nr + 6)) { hovered = n; break; }
    }
    if (hovered) {
      let tipHtml = '<b style="color:' + nodeCol(hovered) + '">' + esc(hovered.id) + '</b><br><span style="color:#888">' + hovered.type + '</span> &middot; ' + hovered.weight + ' events';
      if (hovered.type === 'file' && S.fileOps[hovered.id]) {
        const ops = S.fileOps[hovered.id];
        const counts: Partial<Record<FileOpType, number>> = {};
        for (const op of ops) counts[op.op] = (counts[op.op] || 0) + 1;
        const breakdown = Object.entries(counts).map(([op, cnt]) => cnt + ' ' + op + (cnt! > 1 ? 's' : '')).join(', ');
        tipHtml += '<br><span style="color:#666;font-size:10px">' + breakdown + '</span>';
      }
      tip.innerHTML = tipHtml;
      tip.style.display = 'block';
      tip.style.left = (e.clientX - canvas.getBoundingClientRect().left + 14) + 'px';
      tip.style.top = (e.clientY - canvas.getBoundingClientRect().top - 10) + 'px';
      canvas.style.cursor = 'pointer';
    } else {
      tip.style.display = 'none';
      canvas.style.cursor = dragging ? 'grabbing' : 'grab';
    }
  });
  canvas.addEventListener('click', () => {
    if (hovered) {
      const ent = S.entities[hovered.id];
      if (ent && ent.events.length > 0) openDossier(ent.events[ent.events.length - 1]._idx!);
    }
  });
  canvas.addEventListener('mouseleave', () => { tip.style.display = 'none'; hovered = null; });

  let simSteps = 0;
  function simulate(): void {
    const repK = 2800, attrK = 0.008, centerK = 0.01, damp = 0.88;
    for (let i = 0; i < nodes.length; i++) {
      const a = nodes[i];
      for (let j = i + 1; j < nodes.length; j++) {
        const b = nodes[j];
        let dx = a.x - b.x, dy = a.y - b.y;
        let d2 = dx * dx + dy * dy;
        if (d2 < 1) d2 = 1;
        const f = repK / d2;
        const d = Math.sqrt(d2);
        const fx = (dx / d) * f, fy = (dy / d) * f;
        a.vx += fx; a.vy += fy; b.vx -= fx; b.vy -= fy;
      }
      a.vx += (cx - a.x) * centerK;
      a.vy += (cy - a.y) * centerK;
    }
    edges.forEach(e => {
      const a = nodes[e.s], b = nodes[e.t];
      let dx = b.x - a.x, dy = b.y - a.y;
      const d = Math.sqrt(dx * dx + dy * dy) || 1;
      const ideal = 80 + (20 - Math.min(e.w, 20)) * 2;
      const f = (d - ideal) * attrK * Math.min(e.w, 10);
      const fx = (dx / d) * f, fy = (dy / d) * f;
      a.vx += fx; a.vy += fy; b.vx -= fx; b.vy -= fy;
    });
    nodes.forEach(n => { n.vx *= damp; n.vy *= damp; n.x += n.vx; n.y += n.vy; });
    simSteps++;
  }

  const startTime = Date.now();
  function draw(): void {
    ctx.clearRect(0, 0, cw, ch);

    ctx.fillStyle = 'rgba(74,192,232,0.04)';
    const gs = 30;
    for (let gx = 0; gx < cw; gx += gs) for (let gy = 0; gy < ch; gy += gs) { ctx.beginPath(); ctx.arc(gx, gy, 0.6, 0, Math.PI * 2); ctx.fill(); }

    const t = (Date.now() - startTime) * 0.001;

    edges.forEach(e => {
      const a = nodes[e.s], b = nodes[e.t];
      const sa = w2s(a.x, a.y), sb = w2s(b.x, b.y);
      const isHl = hovered && (hovered.id === a.id || hovered.id === b.id);
      const alpha = isHl ? 0.5 : 0.12;
      const width = isHl ? 1.5 + e.w * 0.3 : 0.5 + e.w * 0.15;
      const grad = ctx.createLinearGradient(sa.x, sa.y, sb.x, sb.y);
      grad.addColorStop(0, nodeCol(a));
      grad.addColorStop(1, nodeCol(b));
      ctx.beginPath(); ctx.moveTo(sa.x, sa.y); ctx.lineTo(sb.x, sb.y);
      ctx.strokeStyle = grad; ctx.globalAlpha = alpha; ctx.lineWidth = width * cam.z; ctx.stroke();
      ctx.globalAlpha = 1;

      if (e.w >= 3 || isHl) {
        const pp = ((t * 0.4 + e.s * 0.3) % 1);
        const px = sa.x + (sb.x - sa.x) * pp, py = sa.y + (sb.y - sa.y) * pp;
        const pg = ctx.createRadialGradient(px, py, 0, px, py, 3 * cam.z);
        pg.addColorStop(0, 'rgba(255,255,255,0.6)');
        pg.addColorStop(1, 'rgba(255,255,255,0)');
        ctx.fillStyle = pg; ctx.beginPath(); ctx.arc(px, py, 3 * cam.z, 0, Math.PI * 2); ctx.fill();
      }
    });

    nodes.forEach(n => {
      const sp = w2s(n.x, n.y);
      const r = nodeRadius(n) * cam.z;
      const c = nodeCol(n);
      const isPrimary = primary && n.id === primary.name;
      const isHov = hovered && hovered.id === n.id;
      const isRel = hovered && edges.some(ed => (nodes[ed.s].id === hovered.id && nodes[ed.t].id === n.id) || (nodes[ed.t].id === hovered.id && nodes[ed.s].id === n.id));
      const dimmed = hovered && !isPrimary && !isHov && !isRel;

      if (isPrimary || isHov) {
        const gr = r * 3;
        const glow = ctx.createRadialGradient(sp.x, sp.y, r * 0.5, sp.x, sp.y, gr);
        glow.addColorStop(0, c + '40'); glow.addColorStop(0.5, c + '15'); glow.addColorStop(1, c + '00');
        ctx.fillStyle = glow; ctx.beginPath(); ctx.arc(sp.x, sp.y, gr, 0, Math.PI * 2); ctx.fill();
      }

      ctx.globalAlpha = dimmed ? 0.2 : 1;
      const ng = ctx.createRadialGradient(sp.x - r * 0.3, sp.y - r * 0.3, 0, sp.x, sp.y, r);
      ng.addColorStop(0, c + 'ee'); ng.addColorStop(1, c + '88');
      ctx.fillStyle = ng; ctx.beginPath(); ctx.arc(sp.x, sp.y, r, 0, Math.PI * 2); ctx.fill();
      ctx.strokeStyle = isPrimary ? '#ffffff' : isHov ? c : c + '66';
      ctx.lineWidth = isPrimary ? 2 : isHov ? 1.5 : 0.8;
      ctx.stroke();
      ctx.globalAlpha = 1;

      const showLabel = cam.z > 0.5 || isPrimary || isHov || n.weight > 5;
      if (showLabel) {
        ctx.font = (isPrimary ? 'bold ' : '') + Math.max(9, 10 * cam.z) + 'px "SF Mono","Fira Code",monospace';
        ctx.textAlign = 'center';
        ctx.fillStyle = dimmed ? 'rgba(200,204,216,0.2)' : isPrimary ? '#ffffff' : isHov ? '#e8ecf4' : 'rgba(200,204,216,0.75)';
        ctx.fillText(n.label, sp.x, sp.y + r + 12 * cam.z);
      }

      if (n.type === 'file' && S.fileOps[n.id] && (cam.z > 0.4 || isPrimary || isHov)) {
        const op = getFilePrimaryOp(n.id);
        const badge = OP_ICONS[op] || '?';
        const badgeSize = Math.max(7, 9 * cam.z);
        ctx.font = 'bold ' + badgeSize + 'px "SF Mono",monospace';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        const bw = badgeSize + 4, bh = badgeSize + 2;
        ctx.fillStyle = 'rgba(0,0,0,0.6)';
        ctx.fillRect(sp.x + r * 0.5 - bw / 2, sp.y - r * 0.5 - bh / 2, bw, bh);
        ctx.fillStyle = dimmed ? (c + '40') : c;
        ctx.fillText(badge, sp.x + r * 0.5, sp.y - r * 0.5 + 1);
        ctx.textBaseline = 'alphabetic';
      }
    });

    const ly = ch - 14;
    ctx.font = '9px "SF Mono",monospace'; ctx.textAlign = 'left';
    const types = [...new Set(nodes.map(n => n.type))];
    let lx = 10;
    types.forEach(tp => {
      const c = TYPE_COL[tp as EntityType] || '#8888aa';
      ctx.fillStyle = c; ctx.beginPath(); ctx.arc(lx + 4, ly, 3, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = '#555a6e'; ctx.fillText(tp, lx + 10, ly + 3);
      lx += ctx.measureText(tp).width + 22;
    });
    const fileNodes = nodes.filter(n => n.type === 'file' && S.fileOps[n.id]);
    if (fileNodes.length > 0) {
      ctx.fillStyle = '#333848';
      ctx.fillText('|', lx, ly + 3);
      lx += 10;
      for (const [op, oc] of Object.entries(OP_COLORS)) {
        const hasOp = fileNodes.some(n => getFilePrimaryOp(n.id) === op);
        if (!hasOp) continue;
        ctx.fillStyle = oc; ctx.beginPath(); ctx.arc(lx + 4, ly, 3, 0, Math.PI * 2); ctx.fill();
        ctx.fillStyle = '#555a6e'; ctx.fillText(OP_ICONS[op as FileOpType] + '=' + op, lx + 10, ly + 3);
        lx += ctx.measureText(OP_ICONS[op as FileOpType] + '=' + op).width + 22;
      }
    }
    ctx.fillStyle = '#333848'; ctx.textAlign = 'right';
    ctx.fillText(nodes.length + ' entities \u00b7 ' + edges.length + ' links', cw - 10, ly + 3);
  }

  function loop(): void { if (simSteps < 300) simulate(); draw(); S.graphAnimId = requestAnimationFrame(loop); }
  loop();
}

// ═══ TIMELINE TAB ═══
export function renderDossierTimeline(primary: ExtractedEntity): void {
  const content = $('dossier-content');
  if (!content) return;
  const entityData = S.entities[primary.name];
  if (!entityData) {
    content.innerHTML = '<div class="empty-state"><div class="icon">◷</div><div>No timeline data</div></div>';
    return;
  }

  const events = entityData.events.slice(-50).reverse();
  let html = `<div class="dossier-section"><div class="section-title">TIMELINE (${entityData.events.length} total)</div><div class="dossier-timeline">`;

  events.forEach(ev => {
    const icon = TYPE_ICONS[ev.type] || '·';
    let body = ev.type;
    if (ev.detail) body += ': ' + ev.detail.slice(0, 80);
    if (ev.v1 && (ev.type === 'tool_call' || ev.type === 'llm_response')) body += ' ' + fmtDuration(ev.v1);

    html += `<div class="dt-event" data-idx="${ev._idx}">
      <span class="dt-time">${fmtTime(ev.ts)}</span>
      <span class="dt-icon" style="color:var(--cyan)">${icon}</span>
      <span class="dt-body">${esc(body)}</span>
    </div>`;
  });

  html += '</div></div>';
  content.innerHTML = html;
}

// ═══ CONTEXT TAB ═══
export function renderDossierContext(primary: ExtractedEntity): void {
  const content = $('dossier-content');
  if (!content) return;

  const zoomedIdx = S.zoomedEvent ? S.zoomedEvent._idx : -1;
  let sessionStartIdx = 0;
  let sessionEndIdx = S.events.length - 1;
  for (let i = zoomedIdx; i >= 0; i--) {
    if (S.events[i].type === 'agent_start') { sessionStartIdx = i; break; }
  }
  for (let i = zoomedIdx; i < S.events.length; i++) {
    if (S.events[i].type === 'agent_end') { sessionEndIdx = i; break; }
  }
  const sessionEvents = S.events.slice(sessionStartIdx, sessionEndIdx + 1);

  const turns: TurnData[] = [];
  let currentTurn: TurnData | null = null;

  sessionEvents.forEach(ev => {
    if (ev.type === 'agent_start' || ev.type === 'channel_message') {
      if (currentTurn) turns.push(currentTurn);
      currentTurn = {
        id: turns.length + 1, startTs: ev.ts,
        provider: ev.provider, model: ev.model,
        inputTokens: 0, outputTokens: 0, totalTokens: 0,
        toolCalls: [], errors: [], completed: false,
        messages: [], responses: [], events: [ev],
      };
    } else if (ev.type === 'llm_request' && currentTurn) {
      currentTurn.provider = ev.provider || currentTurn.provider;
      currentTurn.model = ev.model || currentTurn.model;
      currentTurn.inputTokens += ev.v1 || 0;
      if (ev.content) {
        try { currentTurn.messages = JSON.parse(ev.content); } catch { /* skip */ }
      }
      currentTurn.events.push(ev);
    } else if (ev.type === 'llm_response' && currentTurn) {
      currentTurn.outputTokens += ev.v1 || 0;
      currentTurn.totalTokens = currentTurn.inputTokens + currentTurn.outputTokens;
      if (ev.ok === false) currentTurn.errors.push(ev.detail || 'LLM error');
      let respText: string | null = null;
      let respTools: TurnResponse['tools'] = null;
      if (ev.content) {
        try {
          const parsed = JSON.parse(ev.content);
          if (parsed && typeof parsed === 'object') {
            if (Array.isArray(parsed.t)) respTools = parsed.t;
            if (typeof parsed.r === 'string' && parsed.r.length > 0) respText = parsed.r;
          } else if (typeof parsed === 'string') {
            respText = parsed;
          } else {
            respText = ev.content;
          }
        } catch {
          respText = ev.content;
        }
      }
      currentTurn.responses.push({ text: respText, tools: respTools });
      currentTurn.events.push(ev);
    } else if (ev.type === 'tool_call_start' && currentTurn) {
      currentTurn.toolCalls.push({ name: ev.model || ev.provider || 'tool', startTs: ev.ts });
      currentTurn.events.push(ev);
    } else if (ev.type === 'tool_call' && currentTurn) {
      const tc = currentTurn.toolCalls[currentTurn.toolCalls.length - 1];
      if (tc) { tc.duration = ev.v1 || 0; tc.ok = ev.ok; tc.detail = ev.detail || ''; }
      if (ev.ok === false) currentTurn.errors.push((ev.detail || 'tool error').slice(0, 60));
      currentTurn.events.push(ev);
    } else if (ev.type === 'turn_complete' && currentTurn) {
      currentTurn.completed = true; currentTurn.endTs = ev.ts;
      currentTurn.events.push(ev); turns.push(currentTurn); currentTurn = null;
    } else if (ev.type === 'agent_end' && currentTurn) {
      currentTurn.endTs = ev.ts; turns.push(currentTurn); currentTurn = null;
    } else if (ev.type === 'err' && currentTurn) {
      currentTurn.errors.push((ev.detail || ev.provider || 'error').slice(0, 80));
      currentTurn.events.push(ev);
    } else if (currentTurn) {
      currentTurn.events.push(ev);
    }
  });
  if (currentTurn) turns.push(currentTurn);

  let totalInput = 0, totalOutput = 0;
  turns.forEach(t => { totalInput += t.inputTokens; totalOutput += t.outputTokens; });
  const totalTokens = totalInput + totalOutput;
  const ctxWindow = 200000;

  let activeTurnIdx = -1;
  turns.forEach((t, i) => { if (t.events.some(e => e._idx === zoomedIdx)) activeTurnIdx = i; });

  if (turns.length === 0) {
    content.innerHTML = '<div style="color:var(--text-dim);font-family:var(--mono);font-size:10px;padding:20px">no turns intercepted</div>';
    return;
  }

  const usedPct = Math.min(100, (totalTokens / ctxWindow) * 100);
  const inputPct = totalTokens > 0 ? (totalInput / totalTokens) * 100 : 0;
  const outputPct = totalTokens > 0 ? (totalOutput / totalTokens) * 100 : 0;

  let html = `<div class="ctx-bar-container">
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px">
      <span style="color:var(--text-dim);font-size:9px;letter-spacing:1px">CONTEXT</span>
      <span class="copy-btn" data-copy="context" style="color:var(--text-dim);font-size:9px;cursor:pointer;letter-spacing:0">COPY</span>
    </div>
    <div class="ctx-bar">
      <div class="ctx-bar-fill ctx-input" style="width:${inputPct}%"></div>
      <div class="ctx-bar-fill ctx-output" style="width:${outputPct}%"></div>
    </div>
    <div class="ctx-bar-labels">
      <span></span>
      <span class="ctx-bar-tokens">${totalTokens.toLocaleString()} tok · ${usedPct.toFixed(1)}%</span>
    </div>
  </div>`;

  const totalTools = turns.reduce((s, t) => s + t.toolCalls.length, 0);
  const totalErrs = turns.reduce((s, t) => s + t.errors.length, 0);
  html += `<div class="ctx-summary">
    <span><span class="val">${turns.length}</span> turns</span>
    <span><span class="val">${totalInput.toLocaleString()}</span> in</span>
    <span><span class="val">${totalOutput.toLocaleString()}</span> out</span>
    <span><span class="val">${totalTools}</span> tools</span>
    ${totalErrs ? `<span style="color:var(--red)"><span class="val">${totalErrs}</span> err</span>` : ''}
  </div>`;

  const latencies = sessionEvents.filter(e => e.type === 'llm_response' && e.v1 && e.v1 > 0).map(e => e.v1!);
  if (latencies.length > 1) {
    const sorted = [...latencies].sort((a, b) => a - b);
    const p50 = sorted[Math.floor(sorted.length * 0.5)];
    const p95 = sorted[Math.floor(sorted.length * 0.95)];
    const avg = Math.round(latencies.reduce((s, v) => s + v, 0) / latencies.length);
    const maxL = Math.max(...latencies);
    html += `<div class="ctx-summary" style="margin-top:8px">
      <span>p50 <span class="val">${fmtDuration(p50)}</span></span>
      <span>p95 <span class="val">${fmtDuration(p95)}</span></span>
      <span>avg <span class="val">${fmtDuration(avg)}</span></span>
      <span>n <span class="val">${latencies.length}</span></span>
    </div>`;
    const w = 200, h = 24, pad = 2;
    const pts = latencies.slice(-30).map((v, i) => {
      const x = pad + (i / Math.max(29, latencies.length - 30 + 1)) * (w - pad * 2);
      const y = h - pad - (v / maxL) * (h - pad * 2);
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    }).join(' ');
    html += `<svg width="${w}" height="${h}" style="display:block;margin-top:4px;opacity:0.6">
      <polyline points="${pts}" fill="none" stroke="var(--purple)" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
    </svg>`;
  }

  html += '<div class="ctx-turns">';
  turns.forEach((turn, i) => {
    const isActive = i === activeTurnIdx;
    const turnColor = turn.errors.length ? 'var(--red)' : turn.completed ? 'var(--green)' : 'var(--amber)';
    const shortModel = (turn.model || turn.provider || '?').split('/').pop();
    const msgCount = turn.messages.length;

    html += `<div class="ctx-turn ${isActive ? 'ctx-turn-active' : ''}" data-turn="${i}">
      <div class="ctx-turn-header">
        <span class="ctx-turn-num" style="color:${turnColor}">${String(turn.id).padStart(2, '0')}</span>
        <span class="ctx-turn-model">${esc(shortModel || '?')}</span>
        <span class="ctx-turn-time">${fmtTime(turn.startTs)}</span>
        <span class="ctx-turn-tokens">${turn.inputTokens}+${turn.outputTokens}=${turn.totalTokens}</span>
      </div>`;

    if (msgCount > 0) {
      html += '<div class="ctx-turn-messages">';
      turn.messages.forEach(msg => {
        const role = msg.r || 'unknown';
        const body = msg.c || '';
        const truncated = body.length > 300;
        const preview = truncated ? body.slice(0, 300) : body;
        html += `<div class="ctx-msg" title="click to expand">
          <div class="ctx-msg-role role-${role}">${esc(role.toUpperCase())}</div>
          <div class="ctx-msg-body">${esc(preview)}</div>
          ${truncated ? '<div class="ctx-msg-truncated">...</div>' : ''}
        </div>`;
      });
      html += '</div>';
    }

    if (turn.responses.length > 0) {
      turn.responses.forEach((resp) => {
        if (resp.text) {
          const truncated = resp.text.length > 300;
          const preview = truncated ? resp.text.slice(0, 300) : resp.text;
          html += `<div class="ctx-turn-response" title="click to expand">
            <div class="ctx-msg-body">${esc(preview)}</div>
            ${truncated ? '<div class="ctx-msg-truncated">...</div>' : ''}
          </div>`;
        }
        const tools = Array.isArray(resp.tools) ? resp.tools : [];
        if (tools.length > 0) {
          tools.forEach(tc => {
            const name = tc.n || tc.name || 'tool';
            const args = tc.a || tc.arguments || '';
            const argsStr = typeof args === 'string' ? args : JSON.stringify(args);
            const truncated = argsStr.length > 200;
            const preview = truncated ? argsStr.slice(0, 200) : argsStr;
            html += `<div class="ctx-msg" title="click to expand">
              <div class="ctx-msg-role role-tool">CALL ${esc(name)}</div>
              <div class="ctx-msg-body">${esc(preview)}</div>
              ${truncated ? '<div class="ctx-msg-truncated">...</div>' : ''}
            </div>`;
          });
        }
      });
    } else if (turn.toolCalls.length > 0) {
      html += '<div class="ctx-turn-tools">';
      turn.toolCalls.forEach(tc => {
        const cls = tc.ok === false ? 'ctx-tool-tag err' : 'ctx-tool-tag';
        html += `<span class="${cls}">${esc(tc.name)}${tc.ok === false ? ' ✗' : ''}</span>`;
      });
      html += '</div>';
    }

    if (turn.errors.length > 0) {
      html += '<div class="ctx-turn-errors">';
      turn.errors.forEach(err => { html += `<div class="ctx-error">${esc(err)}</div>`; });
      html += '</div>';
    }

    html += '</div>';
  });
  html += '</div>';
  content.innerHTML = html;

  content.querySelectorAll('.ctx-turn').forEach(el => {
    el.addEventListener('click', (e) => {
      if (e.target.closest('.ctx-msg') || e.target.closest('.ctx-turn-response')) return;
      const turnIdx = parseInt((el as HTMLElement).dataset.turn || '0');
      const turn = turns[turnIdx];
      if (turn && turn.events.length > 0) selectEvent(turn.events[0]._idx!);
    });
  });

  content.querySelectorAll('.ctx-msg, .ctx-turn-response').forEach(el => {
    el.addEventListener('click', (e) => { e.stopPropagation(); el.classList.toggle('expanded'); });
  });
}

// ═══ FILES TAB ═══
export function renderDossierFiles(_primary: ExtractedEntity): void {
  const content = $('dossier-content');
  if (!content) return;
  const paths = Object.keys(S.fileOps);
  if (paths.length === 0) {
    content.innerHTML = '<div class="empty-state"><div class="icon">◇</div><div>No file activity tracked</div><div class="hint">file operations will appear here as the agent reads/writes files</div></div>';
    return;
  }
  const sorted = paths.map(path => {
    const ops = S.fileOps[path];
    const lastOp = ops[ops.length - 1];
    const counts: Partial<Record<FileOpType, number>> = {};
    for (const op of ops) counts[op.op] = (counts[op.op] || 0) + 1;
    return { path, ops, lastOp, counts, totalOps: ops.length, primaryOp: getFilePrimaryOp(path) };
  }).sort((a, b) => b.lastOp.ts - a.lastOp.ts);

  let html = `<div class="dossier-section"><div class="section-title">FILE ACTIVITY (${sorted.length} files)</div>`;
  html += '<div style="overflow:auto;max-height:calc(100vh - 180px)"><table class="file-table"><thead><tr>';
  html += '<th>FILE</th><th>OPS</th><th>LAST</th><th>WHEN</th><th>STATUS</th>';
  html += '</tr></thead><tbody>';

  for (const f of sorted) {
    const basename = f.path.split('/').pop();
    const dir = f.path.includes('/') ? f.path.substring(0, f.path.lastIndexOf('/') + 1) : '';
    const opBreakdown = Object.entries(f.counts).map(([op, cnt]) => `${OP_ICONS[op as FileOpType] || op}${cnt}`).join(' ');
    const lastOpLabel = OP_ICONS[f.lastOp.op] || f.lastOp.op;
    const timeStr = fmtTime(f.lastOp.ts);
    const statusClass = 'st-' + f.primaryOp;
    const statusLabel = f.primaryOp.toUpperCase();

    html += `<tr class="file-row" data-path="${esc(f.path)}">`;
    html += `<td class="ft-path" title="${esc(f.path)}"><span style="color:var(--text-dim)">${esc(dir)}</span>${esc(basename || '')}</td>`;
    html += `<td class="ft-ops">${opBreakdown}</td>`;
    html += `<td class="ft-last">${lastOpLabel}</td>`;
    html += `<td class="ft-time">${timeStr}</td>`;
    html += `<td class="ft-status ${statusClass}">${statusLabel}</td>`;
    html += '</tr>';
  }

  html += '</tbody></table></div></div>';
  content.innerHTML = html;
}

export function openFileInGraph(path: string): void {
  const ent = S.entities[path];
  if (ent && ent.events.length > 0) {
    openDossier(ent.events[ent.events.length - 1]._idx!);
    switchTab('graph');
  }
}
