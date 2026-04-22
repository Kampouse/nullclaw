// NullClaw Spy Dashboard — Main Entry

open Types
open State

let s = make()
let client = SseClient.make()

let onEvents = (events: array<spyEvent>) => {
  if !s.paused {
    State.addEvents(s, events)
    EventFeed.render(s)
    if s.selectedIdx >= 0 { EventFeed.renderDossier(s) }
  }
}

SseClient.start(client, onEvents, "")

let updateDot = (cls: string) => SpyDom.setCls("sse-dot", cls)

external fetchNow: string => Js.Promise.t<_> = "fetch"
@send external respJson: _ => Js.Promise.t<Js.Json.t> = "json"

let pollStatus = () => {
  let p = fetchNow("/api/status")
  let p2 = Js.Promise.then_(resp => {
    let p3 = Js.Promise.then_(_ => {
      s.connected = true
      updateDot("status-dot ok")
      Js.Promise.resolve()
    }, respJson(resp))
    p3
  }, p)
  let p4 = Js.Promise.catch(_ => {
    s.connected = false
    updateDot("status-dot err")
    Js.Promise.resolve()
  }, p2)
  p4->ignore
}

Js.Global.setTimeout(() => pollStatus(), 0)->ignore
Js.Global.setInterval(() => pollStatus(), 5000)->ignore

let openDossier = (idx: int) => {
  State.selectEvent(s, idx)
  SpyDom.removeClass("dossier", "collapsed")
  EventFeed.render(s)
  EventFeed.renderDossier(s)
}

let closeDossier = () => {
  SpyDom.addClass("dossier", "collapsed")
  s.selectedIdx = -1
  EventFeed.render(s)
}

let closeSearch = () => {
  s.showSearch = false
  SpyDom.removeClass("search-overlay", "visible")
}

let closeHelp = () => {
  s.showHelp = false
  SpyDom.removeClass("help-overlay", "visible")
}

// Toolbar buttons
SpyDom.onClick("btn-pause", () => {
  s.paused = !s.paused
  SpyDom.toggleClass("btn-pause", "active")
})

SpyDom.onClick("btn-follow", () => {
  s.following = !s.following
  SpyDom.toggleClass("btn-follow", "active")
})

SpyDom.onClick("btn-clear", () => {
  State.clearFeed(s)
  EventFeed.render(s)
})

SpyDom.onClick("btn-search", () => {
  s.showSearch = true
  SpyDom.addClass("search-overlay", "visible")
})

SpyDom.onClick("btn-help", () => {
  s.showHelp = true
  SpyDom.addClass("help-overlay", "visible")
})

SpyDom.onClick("dossier-close", () => closeDossier())

SpyDom.onClick("err-badge", () => {
  s.errFilter = !s.errFilter
  s.filter = ""
  EventFeed.render(s)
})

SpyDom.onClick("btn-export", () => {
  // Export disabled — Blob API not available in ReScript v12 core
  ()
})

// Dossier tabs — use IDs from HTML
SpyDom.onClick("dossier-tab-summary", () => {
  s.dossierTab = SummaryTab
  EventFeed.renderDossier(s)
})
SpyDom.onClick("dossier-tab-context", () => {
  s.dossierTab = ContextTab
  EventFeed.renderDossier(s)
})
SpyDom.onClick("dossier-tab-raw", () => {
  s.dossierTab = RawTab
  EventFeed.renderDossier(s)
})

// Demo mode check
external hasDemo: unit => bool = "spyHasDemo"
if hasDemo() {
  s.connected = true
  updateDot("status-dot ok")

  let now = Js.Date.now() *. 1e6
  let b = now -. 120_000_000_000.0

  let mk = (ts, typ, prov, mod, v1, v2, ok, det) => {
    let d = Js.Dict.empty()
    d->Js.Dict.set("ts", Js.Json.number(ts))
    d->Js.Dict.set("type", Js.Json.string(typ))
    switch prov { | Some(p) => d->Js.Dict.set("provider", Js.Json.string(p)) | None => () }
    switch mod { | Some(m) => d->Js.Dict.set("model", Js.Json.string(m)) | None => () }
    switch v1 { | Some(v) => d->Js.Dict.set("v1", Js.Json.number(v)) | None => () }
    switch v2 { | Some(v) => d->Js.Dict.set("v2", Js.Json.number(v)) | None => () }
    switch ok { | Some(v) => d->Js.Dict.set("ok", Js.Json.boolean(v)) | None => () }
    switch det { | Some(v) => d->Js.Dict.set("detail", Js.Json.string(v)) | None => () }
    Js.Json.object_(d)
  }

  let mockData = [
    mk(b, "agent_start", Some("anthropic"), Some("claude-sonnet-4"), None, None, None, None),
    mk(b +. 1e9, "llm_request", Some("anthropic"), Some("claude-sonnet-4"), Some(42.0), None, None, None),
    mk(b +. 2.5e9, "llm_response", Some("anthropic"), Some("claude-sonnet-4"), Some(2400.0), None, Some(true), None),
    mk(b +. 2.6e9, "turn_complete", None, None, None, None, None, None),
    mk(b +. 16.2e9, "llm_response", Some("anthropic"), Some("claude-sonnet-4"), Some(1200.0), None, Some(true), Some("Running ls")),
    mk(b +. 16.3e9, "tool_call_start", None, Some("shell"), None, None, None, None),
    mk(b +. 18.5e9, "tool_call", None, Some("shell"), Some(2200.0), None, Some(true), Some("ls -la /tmp")),
    mk(b +. 70e9, "heartbeat_tick", None, None, None, None, None, None),
    mk(b +. 95e9, "err", Some("memory"), None, None, None, None, Some("sqlite: database is locked")),
    mk(b +. 100e9, "agent_start", Some("ollama-cloud"), Some("qwen3-coder"), None, None, None, None),
    mk(b +. 107e9, "tool_iterations_exhausted", None, None, Some(90.0), None, None, None),
    mk(b +. 107.2e9, "agent_end", None, None, Some(7.2e9), Some(810.0), None, None),
  ]

  let parsed = mockData->Array.mapWithIndex((json, i) => EventParser.parseEvent(json, i))
  State.addEvents(s, parsed)
  EventFeed.render(s)
}
