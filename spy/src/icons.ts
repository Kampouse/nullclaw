// ═══ EVENT TYPE ICONS & FILE OP CONSTANTS ═══
import type { EventType, FileOpType } from './types';

export const TYPE_ICONS: Record<EventType | string, string> = {
  agent_start: '▶', agent_end: '■',
  llm_request: '◈', llm_response: '◇',
  tool_call_start: '▸', tool_call: '●',
  channel_message: '◉',
  heartbeat_tick: '·',
  err: '✖',
  turn_complete: '↵',
  tool_iterations_exhausted: '⚠',
  http_request: '⇄',
};

export const OP_COLORS: Record<FileOpType, string> = {
  read: '#4a9eff', write: '#3dd68c', patch: '#f0a030', append: '#4ac0e8', git: '#a070f0',
};

export const OP_ICONS: Record<FileOpType, string> = {
  read: 'R', write: 'W', patch: 'P', append: 'A', git: 'G',
};
