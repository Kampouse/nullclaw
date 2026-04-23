// ═══ TYPE DEFINITIONS ═══
// Wire types (EventType, SpyEvent) are auto-generated from schema.json.
// App-only types (SpyState, Entity, etc.) live here.

export type { EventType, SpyEvent } from './generated/types';
export type { EventsResponse, TraceResponse, HealthCheck, StatusResponse } from './generated/api';

// ═══ APP-ONLY TYPES ═══

export type FileOpType = 'read' | 'write' | 'patch' | 'append' | 'git';

export interface FileOp {
  path: string;
  op: FileOpType;
  tool: string;
  ts: number;
  _evIdx: number;
}

export type EntityType = 'provider' | 'model' | 'tool' | 'file' | 'event' | 'channel' | 'error' | 'err';

export interface Entity {
  type: EntityType;
  events: import('./generated/types').SpyEvent[];
  related: Record<string, number>;
  fileOps?: FileOp[];
}

export interface ExtractedEntity {
  name: string;
  type: EntityType;
  op?: FileOpType;
}

export interface TraceSession {
  events: import('./generated/types').SpyEvent[];
}

export type TraceFilter = 'llm' | 'tool' | 'http' | 'err' | 'msg' | null;
export type ActiveView = 'feed' | 'trace';
export type DossierTab = 'overview' | 'graph' | 'timeline' | 'context' | 'files';

export interface SpyState {
  events: import('./generated/types').SpyEvent[];
  sincePos: number | null;
  selectedIdx: number;
  zoomedEvent: import('./generated/types').SpyEvent | null;
  paused: boolean;
  following: boolean;
  connected: boolean;
  filter: string;
  activeTab: DossierTab;
  entities: Record<string, Entity>;
  status: StatusResponse | null;
  sseRetries: number;
  startTime: number;
  graphAnimId: number | null;
  liveTurn: boolean;
  errFilter: boolean;
  showHeartbeats: boolean;
  // trace view
  activeView: ActiveView;
  traceSessions: Record<string, import('./generated/types').SpyEvent[]>;
  traceSincePos: number | null;
  traceFilter: TraceFilter;
  activeSession: string | null;
  traceDirty: boolean;
  // file activity tracking
  fileOps: Record<string, FileOp[]>;
  activeFile: string | null;
  // polling internals
  pollBackoff?: number;
  pollSkips?: number;
}

export interface ToolCallInfo {
  name: string;
  startTs: number;
  duration?: number;
  ok?: boolean;
  detail?: string;
}

export interface TurnResponse {
  text: string | null;
  tools: Array<{ n?: string; name?: string; a?: string; arguments?: string }> | null;
}

export interface TurnData {
  id: number;
  startTs: number;
  endTs?: number;
  provider?: string;
  model?: string;
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
  toolCalls: ToolCallInfo[];
  errors: string[];
  completed: boolean;
  messages: Array<{ r: string; c: string }>;
  responses: TurnResponse[];
  events: import('./generated/types').SpyEvent[];
}

export interface ToolStat {
  ok: number;
  fail: number;
  totalMs: number;
}

export interface GraphNode {
  id: string;
  type: EntityType;
  label: string;
  weight: number;
  x: number;
  y: number;
  vx: number;
  vy: number;
}

export interface GraphEdge {
  s: number;
  t: number;
  w: number;
}
