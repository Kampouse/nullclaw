// ═══ STATE ═══
import type { SpyState } from './types';

export const S: SpyState = {
  events: [],
  sincePos: null,
  selectedIdx: -1,
  zoomedEvent: null,
  paused: false,
  following: true,
  connected: false,
  filter: '',
  activeTab: 'overview',
  entities: {},
  status: null,
  sseRetries: 0,
  startTime: Date.now(),
  graphAnimId: null,
  liveTurn: false,
  errFilter: false,
  showHeartbeats: false,
  // trace view
  activeView: 'feed',
  traceSessions: {},
  traceSincePos: null,
  traceFilter: null,
  activeSession: null,
  traceDirty: false,
  // file activity tracking
  fileOps: {},
  activeFile: null,
};
