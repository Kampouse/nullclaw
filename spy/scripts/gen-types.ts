#!/usr/bin/env npx tsx
// ═══ Codegen: schema.json → TypeScript ═══
// Reads spy/src/generated/schema.json and writes:
//   - spy/src/generated/types.ts      (EventType union, SpyEvent interface)
//   - spy/src/generated/api.ts        (API endpoint response types + fetch helpers)
//   - spy/src/generated/render-map.ts (event type → icon/label/color/field semantics)
//
// Usage: npx tsx spy/scripts/gen-types.ts

import * as fs from 'fs';
import * as path from 'path';

const ROOT = path.resolve(__dirname, '..');
const SCHEMA = JSON.parse(fs.readFileSync(path.join(ROOT, 'src/generated/schema.json'), 'utf8'));
const OUT_DIR = path.join(ROOT, 'src/generated');

// ── helpers ──

function writeFile(name: string, content: string) {
  const p = path.join(OUT_DIR, name);
  fs.writeFileSync(p, content, 'utf8');
  console.log(`  wrote ${path.relative(ROOT, p)} (${content.length} bytes)`);
}

function tsComment(lines: string[]): string {
  if (lines.length === 0) return '';
  return '/**\n' + lines.map(l => ` * ${l}`).join('\n') + '\n */\n';
}

// ── 1. types.ts ──

function genTypes(): string {
  const eventTypes: string[] = SCHEMA.tap_event_types.values;
  const fields: any[] = SCHEMA.tap_event.fields;

  const lines: string[] = [];
  lines.push('// ═══ AUTO-GENERATED from schema.json — do not edit manually ═══');
  lines.push('// Run: npx tsx spy/scripts/gen-types.ts');
  lines.push('');

  // EventType union
  lines.push('/** Event type tag — matches TapEventType enum in Zig. */');
  lines.push(`export type EventType = ${eventTypes.map(v => `'${v}'`).join('\n  | ')};`);
  lines.push('');

  // SpyEvent interface
  lines.push(tsComment([
    'Wire format for a single event from /api/events and /api/trace.',
    'Fields are optional because readSinceJson() omits zero/false/empty values.',
  ]));
  lines.push('export interface SpyEvent {');
  for (const f of fields) {
    const opt = f.always_emitted ? '' : '?';
    // Special case: the 'type' field should use EventType, not string
    let tsType: string;
    if (f.json_type === 'integer') {
      tsType = 'number';
    } else if (f.json_name === 'type' && f.zig_name === 'event_type') {
      tsType = 'EventType';
    } else {
      tsType = f.json_type;
    }
    const comment = f.description ? `  // ${f.description}` : '';
    lines.push(`  ${f.json_name}${opt}: ${tsType};${comment}`);
  }
  // runtime-only fields (not from JSON, assigned client-side)
  lines.push('  // Runtime-only (assigned client-side, not in JSON)');
  lines.push('  _idx?: number;');
  lines.push('  _feedIdx?: number;');
  lines.push('  _tidx?: number;');
  lines.push('}');
  lines.push('');

  return lines.join('\n');
}

// ── 2. api.ts ──

function genApi(): string {
  const endpoints: any[] = SCHEMA.api_endpoints;
  const lines: string[] = [];

  lines.push('// ═══ AUTO-GENERATED from schema.json — do not edit manually ═══');
  lines.push('// Run: npx tsx spy/scripts/gen-types.ts');
  lines.push('');
  lines.push("import type { SpyEvent } from './types';");
  lines.push('');

  // Events response
  lines.push('/** Response from GET /api/events */');
  lines.push('export interface EventsResponse {');
  lines.push('  pos: number;');
  lines.push('  events: SpyEvent[];');
  lines.push('}');
  lines.push('');

  // Trace response
  lines.push('/** Response from GET /api/trace */');
  lines.push('export interface TraceResponse {');
  lines.push('  pos: number;');
  lines.push('  sessions: Record<string, SpyEvent[]>;');
  lines.push('}');
  lines.push('');

  // Status response
  lines.push('/** Health component from /api/status */');
  lines.push('export interface HealthCheck {');
  lines.push('  status: string;');
  lines.push('  error?: string;');
  lines.push('}');
  lines.push('');
  lines.push('/** Response from GET /api/status */');
  lines.push('export interface StatusResponse {');
  lines.push('  health: Record<string, HealthCheck>;');
  lines.push('  uptime_ns: number;');
  lines.push('  event_tap: { pos: number; ring_size: number } | null;');
  lines.push('  version: string;');
  lines.push('}');
  lines.push('');

  // Fetch helpers
  lines.push('/** Base URL for API calls — set once at init. */');
  lines.push('let _baseUrl: string = "";');
  lines.push('');
  lines.push('export function setApiBaseUrl(url: string) { _baseUrl = url; }');
  lines.push('');
  lines.push('/** Fetch events since a position. */');
  lines.push('export async function fetchEvents(since: number): Promise<EventsResponse> {');
  lines.push("  const r = await fetch(`${_baseUrl}/api/events?since=${since}`);");
  lines.push('  if (!r.ok) throw new Error(`events fetch failed: ${r.status}`);');
  lines.push('  return r.json();');
  lines.push('}');
  lines.push('');
  lines.push('/** Fetch trace sessions since a position, optionally filtered by session hash. */');
  lines.push('export async function fetchTrace(since: number, session?: string): Promise<TraceResponse> {');
  lines.push('  let url = `${_baseUrl}/api/trace?since=${since}`;');
  lines.push('  if (session) url += `&session=${session}`;');
  lines.push('  const r = await fetch(url);');
  lines.push('  if (!r.ok) throw new Error(`trace fetch failed: ${r.status}`);');
  lines.push('  return r.json();');
  lines.push('}');
  lines.push('');
  lines.push('/** Fetch gateway status. */');
  lines.push('export async function fetchStatus(): Promise<StatusResponse> {');
  lines.push("  const r = await fetch(`${_baseUrl}/api/status`);");
  lines.push('  if (!r.ok) throw new Error(`status fetch failed: ${r.status}`);');
  lines.push('  return r.json();');
  lines.push('}');
  lines.push('');

  return lines.join('\n');
}

// ── 3. render-map.ts ──

function genRenderMap(): string {
  const semantics: Record<string, Record<string, string>> = SCHEMA.event_field_semantics.mappings;
  const types: string[] = SCHEMA.tap_event_types.values;

  const lines: string[] = [];

  lines.push('// ═══ AUTO-GENERATED from schema.json — do not edit manually ═══');
  lines.push('// Run: npx tsx spy/scripts/gen-types.ts');
  lines.push('');
  lines.push("import type { EventType, SpyEvent } from './types';");
  lines.push('');

  // Field semantics per event type
  lines.push('/** What each JSON field means for a given event type. */');
  lines.push('export const FIELD_SEMANTICS: Record<EventType, Record<string, string>> = {');
  for (const t of types) {
    const sem = semantics[t] || {};
    const entries = Object.entries(sem);
    if (entries.length === 0) {
      lines.push(`  '${t}': {},`);
    } else {
      lines.push(`  '${t}': {`);
      for (const [key, desc] of entries) {
        lines.push(`    '${key}': '${desc}',`);
      }
      lines.push('  },');
    }
  }
  lines.push('} as const;');
  lines.push('');

  // Event type categories (for filter chips, color coding)
  lines.push('/** Event type → category for grouping. */');
  lines.push('export const EVENT_CATEGORIES: Record<EventType, string> = {');
  const catMap: Record<string, string> = {
    agent_start: 'agent', agent_end: 'agent',
    llm_request: 'llm', llm_response: 'llm',
    tool_call_start: 'tool', tool_call: 'tool', tool_iterations_exhausted: 'tool',
    channel_message: 'msg',
    heartbeat_tick: 'dim', turn_complete: 'dim',
    err: 'err',
    http_request: 'http',
  };
  for (const t of types) {
    lines.push(`  '${t}': '${catMap[t] || 'other'}',`);
  }
  lines.push('} as const;');
  lines.push('');

  // Duration field mapping — which JSON field holds duration for each type
  lines.push('/** Which JSON field holds duration (ms) for each event type, if any. */');
  lines.push('export const DURATION_FIELD: Record<EventType, string | null> = {');
  const durMap: Record<string, string | null> = {
    agent_start: null, llm_request: null,
    llm_response: 'v1', agent_end: 'v1',
    tool_call_start: null, tool_call: 'v1',
    tool_iterations_exhausted: null, turn_complete: null,
    channel_message: null, heartbeat_tick: null,
    err: null, http_request: 'v2',
  };
  for (const t of types) {
    lines.push(`  '${t}': ${durMap[t] === null ? 'null' : `'${durMap[t]}'`},`);
  }
  lines.push('} as const;');
  lines.push('');

  // Content-carrying event types
  lines.push('/** Event types that may carry a content payload. */');
  lines.push('export const HAS_CONTENT: ReadonlySet<EventType> = new Set([');
  const contentTypes = ['llm_request', 'llm_response', 'channel_message', 'err', 'http_request'];
  for (const t of types) {
    if (contentTypes.includes(t)) {
      lines.push(`  '${t}',`);
    }
  }
  lines.push(']);');
  lines.push('');

  return lines.join('\n');
}

// ── main ──

console.log('Generating TypeScript from schema.json...\n');

fs.mkdirSync(OUT_DIR, { recursive: true });
writeFile('types.ts', genTypes());
writeFile('api.ts', genApi());
writeFile('render-map.ts', genRenderMap());

console.log('\nDone.');
