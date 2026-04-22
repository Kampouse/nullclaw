// Event parsing from JSON

open Types

let kindFromString = (s: string): eventKind => {
  switch s {
  | "agent_start" => AgentStart
  | "agent_end" => AgentEnd
  | "llm_request" => LlmRequest
  | "llm_response" => LlmResponse
  | "tool_call_start" => ToolCallStart
  | "tool_call" => ToolCall
  | "tool_iterations_exhausted" => ToolIterationsExhausted
  | "turn_complete" => TurnComplete
  | "channel_message" => ChannelMessage
  | "heartbeat_tick" => HeartbeatTick
  | "err" => ErrorEvent
  | _ => ErrorEvent
  }
}

let kindToString = (k: eventKind): string => {
  switch k {
  | AgentStart => "agent_start"
  | AgentEnd => "agent_end"
  | LlmRequest => "llm_request"
  | LlmResponse => "llm_response"
  | ToolCallStart => "tool_call_start"
  | ToolCall => "tool_call"
  | ToolIterationsExhausted => "tool_iterations_exhausted"
  | TurnComplete => "turn_complete"
  | ChannelMessage => "channel_message"
  | HeartbeatTick => "heartbeat_tick"
  | ErrorEvent => "err"
  }
}

let kindColor = (k: eventKind): string => {
  switch k {
  | AgentStart => "var(--green)"
  | AgentEnd => "var(--text-dim)"
  | LlmRequest => "var(--blue)"
  | LlmResponse => "var(--blue)"
  | ToolCallStart => "var(--cyan)"
  | ToolCall => "var(--cyan)"
  | ToolIterationsExhausted => "var(--amber)"
  | TurnComplete => "var(--text-dim)"
  | ChannelMessage => "var(--purple)"
  | HeartbeatTick => "var(--text-dim)"
  | ErrorEvent => "var(--red)"
  }
}

let kindLabel = (k: eventKind): string => {
  switch k {
  | AgentStart => "AGT+"
  | AgentEnd => "AGT-"
  | LlmRequest => "LLM>"
  | LlmResponse => "LLM<"
  | ToolCallStart => "TOOL~"
  | ToolCall => "TOOL="
  | ToolIterationsExhausted => "MAX!"
  | TurnComplete => "TURN."
  | ChannelMessage => "CH"
  | HeartbeatTick => "TICK"
  | ErrorEvent => "ERR!"
  }
}

let parseEvent = (json: Js.Json.t, idx: int): spyEvent => {
  let obj = json->Js.Json.decodeObject->Option.getWithDefault(Js.Dict.empty())
  let get = (key: string): option<string> =>
    Js.Dict.get(obj, key)->Option.flatMap(Js.Json.decodeString)

  let getFloat = (key: string): option<float> =>
    Js.Dict.get(obj, key)->Option.flatMap(Js.Json.decodeNumber)

  let getBool = (key: string): option<bool> =>
    Js.Dict.get(obj, key)->Option.flatMap(Js.Json.decodeBoolean)

  let kindStr = get("type")->Option.getWithDefault("err")

  {
    ts: getFloat("ts")->Option.getWithDefault(0.0),
    kind: kindFromString(kindStr),
    provider: get("provider"),
    model: get("model"),
    v1: getFloat("v1"),
    v2: getFloat("v2"),
    ok: getBool("ok"),
    detail: get("detail"),
    content: get("content"),
    _idx: idx,
  }
}
