// ═══ AUTO-GENERATED from schema.json — do not edit manually ═══
// Run: npx tsx spy/scripts/gen-types.ts

/** Event type tag — matches TapEventType enum in Zig. */
export type EventType = 'agent_start'
  | 'llm_request'
  | 'llm_response'
  | 'agent_end'
  | 'tool_call_start'
  | 'tool_call'
  | 'tool_iterations_exhausted'
  | 'turn_complete'
  | 'channel_message'
  | 'heartbeat_tick'
  | 'err'
  | 'http_request';

/**
 * Wire format for a single event from /api/events and /api/trace.
 * Fields are optional because readSinceJson() omits zero/false/empty values.
 */

export interface SpyEvent {
  ts: number;  // Nanosecond timestamp from util.nanoTimestamp()
  type: EventType;  // Enum tag name via @tagName()
  session?: number;  // Wyhash of session key. Omitted when 0 (no session).
  provider?: string;  // Provider or channel name, JSON-escaped, truncated to 64 bytes
  model?: string;  // Model name or tool name, JSON-escaped, truncated to 64 bytes
  v1?: number;  // Primary numeric: duration_ms, messages_count, status_code, iterations
  v2?: number;  // Secondary numeric: tokens_used, exit_code, duration_ms
  ok?: boolean;  // Success flag. Only emitted as true -- never false (omitted when false).
  detail?: string;  // Optional detail string, JSON-escaped, truncated to 512 bytes
  content?: string;  // Message snapshots (llm_request), response preview + tool calls (llm_response). JSON-escaped, truncated to 8192 bytes.
  // Runtime-only (assigned client-side, not in JSON)
  _idx?: number;
  _feedIdx?: number;
  _tidx?: number;
}
