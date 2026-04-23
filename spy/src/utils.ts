// ═══ DOM HELPER & FORMAT UTILITIES ═══

export const $ = (id: string): HTMLElement | null => document.getElementById(id);

const _escEl = document.createElement('div');
export function esc(s: string): string {
  _escEl.textContent = s;
  return _escEl.innerHTML;
}

export function fmtTime(ts: number): string {
  const d = new Date(ts / 1e6);
  return d.toTimeString().slice(0, 8);
}

export function fmtDuration(ms: number): string {
  if (ms < 1000) return ms + 'ms';
  if (ms < 60000) return (ms / 1000).toFixed(1) + 's';
  return Math.floor(ms / 60000) + 'm' + Math.floor((ms % 60000) / 1000) + 's';
}

export function fmtUptime(ns: number): string {
  const s = ns / 1e9;
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d > 0) return d + 'd ' + h + 'h ' + m + 'm';
  if (h > 0) return h + 'h ' + m + 'm';
  return m + 'm ' + Math.floor(s % 60) + 's';
}
