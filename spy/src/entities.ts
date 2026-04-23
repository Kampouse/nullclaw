// ═══ ENTITY TRACKING ═══
import { S } from './state';
import { esc } from './utils';
import type { SpyEvent, FileOp, FileOpType, ExtractedEntity, EntityType } from './types';

const OP_MAP: Record<string, FileOpType> = {
  file_read: 'read', file_write: 'write', file_edit: 'patch', file_append: 'append',
};

export function extractFileOps(ev: SpyEvent): FileOp[] {
  if (ev.type !== 'llm_response' || !ev.content) return [];
  let parsed: { t?: Array<{ n?: string; a?: string }> };
  try { parsed = JSON.parse(ev.content); } catch { return []; }
  const tools = Array.isArray(parsed?.t) ? parsed.t : [];
  const ops: FileOp[] = [];
  for (const tc of tools) {
    const name = tc.n || '';
    const argsStr = tc.a || '';
    let args: { path?: string; command?: string };
    try { args = JSON.parse(argsStr); } catch { continue; }
    if (name in OP_MAP && args.path) {
      ops.push({ path: args.path, op: OP_MAP[name], tool: name, ts: ev.ts, _evIdx: ev._idx ?? 0 });
    }
    if (name === 'git_operations') {
      ops.push({ path: args.command || args.path || 'git', op: 'git', tool: name, ts: ev.ts, _evIdx: ev._idx ?? 0 });
    }
  }
  return ops;
}

export function trackFileOps(ev: SpyEvent): void {
  const ops = extractFileOps(ev);
  for (const op of ops) {
    if (!S.fileOps[op.path]) S.fileOps[op.path] = [];
    S.fileOps[op.path].push(op);
    if (!S.entities[op.path]) {
      S.entities[op.path] = { type: 'file', events: [], related: {} };
    }
    S.entities[op.path].fileOps = S.entities[op.path].fileOps || [];
    S.entities[op.path].fileOps.push(op);
    if (S.entities[op.path].type !== 'file') S.entities[op.path].type = 'file';
  }
}

export function getFilePrimaryOp(path: string): FileOpType {
  const ops = S.fileOps[path];
  if (!ops || ops.length === 0) return 'read';
  const priority: FileOpType[] = ['write', 'patch', 'git', 'append', 'read'];
  const opCounts: Partial<Record<FileOpType, number>> = {};
  for (const op of ops) opCounts[op.op] = (opCounts[op.op] || 0) + 1;
  for (const p of priority) {
    if (opCounts[p]) return p;
  }
  return ops[ops.length - 1].op;
}

export function extractEntities(ev: SpyEvent): ExtractedEntity[] {
  const ents: ExtractedEntity[] = [];
  if (ev.provider) ents.push({ name: ev.provider, type: 'provider' });
  if (ev.model && ev.type !== 'llm_request' && ev.type !== 'llm_response') {
    ents.push({ name: ev.model, type: 'tool' });
  } else if (ev.model) {
    ents.push({ name: ev.model, type: 'model' });
  }
  if (ev.detail && ev.model !== 'file_read' && ev.model !== 'file_write' && ev.model !== 'file_edit' && ev.model !== 'file_append') {
    const fileMatch = ev.detail.match(/[\w.\/\-]+\.\w{1,5}/g);
    if (fileMatch) {
      for (const f of fileMatch) {
        if (f.includes('.') && f.length > 3 && !f.startsWith('http')) {
          ents.push({ name: f, type: 'file' });
        }
      }
    }
  }
  if (ev.type === 'llm_response' && ev.content) {
    const ops = extractFileOps(ev);
    for (const op of ops) {
      if (op.op !== 'git' && !ents.some(e => e.name === op.path)) {
        ents.push({ name: op.path, type: 'file', op: op.op });
      }
    }
  }
  return ents;
}

export function trackEntity(ev: SpyEvent): void {
  const ents = extractEntities(ev);
  for (const e of ents) {
    if (!S.entities[e.name]) {
      S.entities[e.name] = { type: e.type, events: [], related: {} };
    }
    S.entities[e.name].events.push(ev);
    for (const other of ents) {
      if (other.name !== e.name) {
        S.entities[e.name].related[other.name] = (S.entities[e.name].related[other.name] || 0) + 1;
      }
    }
  }
}
