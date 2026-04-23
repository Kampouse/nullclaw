// ═══ TYPE DEFINITIONS ═══

export type EventType =
  | 'agent_start' | 'agent_end'
  | 'llm_request' | 'llm_response'
  | 'tool_call_start' | 'tool_call'
  | 'channel_message'
  | 'heartbeat_tick'
  | 'err'
  | 'turn_complete'
  | 'tool_iterations_exhausted'
  | 'http_request';

export type FileOpType = 'read' | 'write' | 'patch' | 'append' | 'git';

export interface SpyEvent {
  type: EventType;
  ts: number;           // nanoseconds
  provider?: string;
  model?: string;
  v1?: number;          // duration_ms or msg_count
  v2?: number;          // secondary metric
  flag?: boolean;       // success flag (alt name for ok)
  ok?: boolean;
  detail?: string;
  content?: string;
  session?: string;
  // Runtime-only (assigned client-side)
  _idx?: number;        // index in S.events
  _feedIdx?: number;    // cross-ref to S.events index (trace events)
  _tidx?: number;       // trace index
}

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
  events: SpyEvent[];
  related: Record<string, number>;
  fileOps?: FileOp[];
}

export interface ExtractedEntity {
  name: string;
  type: EntityType;
  op?: FileOpType;
}

export interface TraceSession {
  events: SpyEvent[];
}

export type TraceFilter = 'llm' | 'tool' | 'http' | 'err' | 'msg' | null;
export type ActiveView = 'feed' | 'trace';
export type DossierTab = 'overview' | 'graph' | 'timeline' | 'context' | 'files';

export interface HealthCheck {
  status: string;
  [key: string]: unknown;
}

export interface StatusResponse {
  uptime_ns: number;
  health?: Record<string, HealthCheck>;
  context_window?: number;
  [key: string]: unknown;
}

export interface SpyState {
  events: SpyEvent[];
  sincePos: number | null;
  selectedIdx: number;
  zoomedEvent: SpyEvent | null;
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
  traceSessions: Record<string, SpyEvent[]>;
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
  events: SpyEvent[];
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
