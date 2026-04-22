// Event types matching the Zig event_tap ObserverEvent

type eventKind =
  | AgentStart
  | AgentEnd
  | LlmRequest
  | LlmResponse
  | ToolCallStart
  | ToolCall
  | ToolIterationsExhausted
  | TurnComplete
  | ChannelMessage
  | HeartbeatTick
  | ErrorEvent

type spyEvent = {
  mutable ts: float,
  mutable kind: eventKind,
  mutable provider: option<string>,
  mutable model: option<string>,
  mutable v1: option<float>,
  mutable v2: option<float>,
  mutable ok: option<bool>,
  mutable detail: option<string>,
  mutable content: option<string>,
  mutable _idx: int,
}

type entity = {
  name: string,
  mutable events: array<spyEvent>,
  firstSeen: float,
  mutable lastSeen: float,
  mutable errorCount: int,
  mutable successCount: int,
}

type dossierTab =
  | SummaryTab
  | ContextTab
  | RawTab

type appState = {
  mutable events: array<spyEvent>,
  mutable entities: Js.Dict.t<entity>,
  mutable selectedIdx: int,
  mutable connected: bool,
  mutable paused: bool,
  mutable following: bool,
  mutable filter: string,
  mutable errFilter: bool,
  mutable showSearch: bool,
  mutable showHelp: bool,
  mutable dossierTab: dossierTab,
  mutable hideHeartbeats: bool,
  mutable startTime: float,
  mutable nextIdx: int,
}

type statusInfo = {
  uptime_ns: float,
}
