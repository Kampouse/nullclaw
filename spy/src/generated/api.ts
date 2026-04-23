// ═══ AUTO-GENERATED from schema.json — do not edit manually ═══
// Run: npx tsx spy/scripts/gen-types.ts

import type { SpyEvent } from './types';

/** Response from GET /api/events */
export interface EventsResponse {
  pos: number;
  events: SpyEvent[];
}

/** Response from GET /api/trace */
export interface TraceResponse {
  pos: number;
  sessions: Record<string, SpyEvent[]>;
}

/** Health component from /api/status */
export interface HealthCheck {
  status: string;
  error?: string;
}

/** Response from GET /api/status */
export interface StatusResponse {
  health: Record<string, HealthCheck>;
  uptime_ns: number;
  event_tap: { pos: number; ring_size: number } | null;
  version: string;
}

/** Base URL for API calls — set once at init. */
let _baseUrl: string = "";

export function setApiBaseUrl(url: string) { _baseUrl = url; }

/** Fetch events since a position. */
export async function fetchEvents(since: number): Promise<EventsResponse> {
  const r = await fetch(`${_baseUrl}/api/events?since=${since}`);
  if (!r.ok) throw new Error(`events fetch failed: ${r.status}`);
  return r.json();
}

/** Fetch trace sessions since a position, optionally filtered by session hash. */
export async function fetchTrace(since: number, session?: string): Promise<TraceResponse> {
  let url = `${_baseUrl}/api/trace?since=${since}`;
  if (session) url += `&session=${session}`;
  const r = await fetch(url);
  if (!r.ok) throw new Error(`trace fetch failed: ${r.status}`);
  return r.json();
}

/** Fetch gateway status. */
export async function fetchStatus(): Promise<StatusResponse> {
  const r = await fetch(`${_baseUrl}/api/status`);
  if (!r.ok) throw new Error(`status fetch failed: ${r.status}`);
  return r.json();
}
