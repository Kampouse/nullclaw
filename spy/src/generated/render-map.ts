// ═══ AUTO-GENERATED from schema.json — do not edit manually ═══
// Run: npx tsx spy/scripts/gen-types.ts

import type { EventType, SpyEvent } from './types';

/** What each JSON field means for a given event type. */
export const FIELD_SEMANTICS: Record<EventType, Record<string, string>> = {
  'agent_start': {
    'provider': 'provider name',
    'model': 'model name',
  },
  'llm_request': {
    'provider': 'provider name',
    'model': 'model name',
    'v1': 'messages_count',
    'content': 'messages_snapshot',
  },
  'llm_response': {
    'provider': 'provider name',
    'model': 'model name',
    'v1': 'duration_ms',
    'ok': 'success',
    'detail': 'error_message',
    'content': 'response + tool_calls',
  },
  'agent_end': {
    'v1': 'duration_ms',
    'v2': 'tokens_used',
  },
  'tool_call_start': {
    'model': 'tool name',
  },
  'tool_call': {
    'model': 'tool name',
    'v1': 'duration_ms',
    'ok': 'success',
    'detail': 'tool output',
  },
  'tool_iterations_exhausted': {},
  'turn_complete': {},
  'channel_message': {
    'provider': 'channel platform',
    'model': 'channel name',
    'detail': 'message preview',
  },
  'heartbeat_tick': {},
  'err': {
    'provider': 'source component',
    'detail': 'error message',
  },
  'http_request': {
    'provider': 'source label',
    'model': 'HTTP method',
    'v1': 'status code',
    'v2': 'duration_ms',
    'ok': 'success',
    'detail': 'URL',
  },
} as const;

/** Event type → category for grouping. */
export const EVENT_CATEGORIES: Record<EventType, string> = {
  'agent_start': 'agent',
  'llm_request': 'llm',
  'llm_response': 'llm',
  'agent_end': 'agent',
  'tool_call_start': 'tool',
  'tool_call': 'tool',
  'tool_iterations_exhausted': 'tool',
  'turn_complete': 'dim',
  'channel_message': 'msg',
  'heartbeat_tick': 'dim',
  'err': 'err',
  'http_request': 'http',
} as const;

/** Which JSON field holds duration (ms) for each event type, if any. */
export const DURATION_FIELD: Record<EventType, string | null> = {
  'agent_start': null,
  'llm_request': null,
  'llm_response': 'v1',
  'agent_end': 'v1',
  'tool_call_start': null,
  'tool_call': 'v1',
  'tool_iterations_exhausted': null,
  'turn_complete': null,
  'channel_message': null,
  'heartbeat_tick': null,
  'err': null,
  'http_request': 'v2',
} as const;

/** Event types that may carry a content payload. */
export const HAS_CONTENT: ReadonlySet<EventType> = new Set([
  'llm_request',
  'llm_response',
  'channel_message',
  'err',
  'http_request',
]);
