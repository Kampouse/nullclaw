// Renders the event feed

open Types
open State
open Utils
open EventParser

let renderEvent = (s: appState, e: spyEvent): string => {
  let color = kindColor(e.kind)
  let label = kindLabel(e.kind)
  let selected = e._idx === s.selectedIdx
  let timeStr = fmtTime(e.ts)
  let prov = e.provider->Option.getWithDefault("")
  let detail = e.detail->Option.getWithDefault("")->esc
  let tokens = e.v1->fmtTokens
  let latency = switch e.v2 {
  | Some(v) => fmtDuration(v)
  | None => ""
  }
  let cls = if selected { " selected" } else { "" }

  `<div class="event-row${cls}" data-idx="${Int.toString(e._idx)}">
    <span class="time">${timeStr}</span>
    <span class="kind" style="color:${color}">${label}</span>
    <span class="provider">${prov->esc}</span>
    <span class="detail">${detail}</span>
    <span class="tokens">${tokens}</span>
    <span class="latency">${latency}</span>
  </div>`
}

let render = (s: appState): unit => {
  let visible = filtered(s)
  let count = Array.length(visible)
  let sliced = if count > 100 {
    visible->Array.sliceToEnd(~start=count - 100)
  } else {
    visible
  }
  let html = sliced->Array.map(e => renderEvent(s, e))->Array.joinWith("")
  SpyDom.setHtml("feed", html)
  SpyDom.setHtml("event-count", Int.toString(Array.length(s.events)))
  if s.following { SpyDom.scrollBottom("feed") }
}

let renderDossier = (s: appState): unit => {
  switch selectedEvent(s) {
  | None => SpyDom.setHtml("dossier-content", "<div style='color:var(--text-dim);text-align:center;padding:40px'>Select an event</div>")
  | Some(e) =>
    let content = switch s.dossierTab {
    | SummaryTab =>
      let rows = [
        ("Time", fmtTime(e.ts)),
        ("Kind", kindToString(e.kind)),
        ("Provider", e.provider->Option.getWithDefault("-")),
        ("Model", e.model->Option.getWithDefault("-")),
        ("Tokens", e.v1->fmtTokens),
        ("Duration", switch e.v2 { | Some(v) => fmtDuration(v) | None => "-" }),
        ("Success", switch e.ok { | Some(true) => "Yes" | Some(false) => "No" | None => "-" }),
        ("Detail", e.detail->Option.getWithDefault("-")->esc),
      ]
      rows->Array.map(((k, v)) => `<div style='display:flex;gap:12px;padding:3px 0'><span style='color:var(--text-dim);min-width:70px'>${k}</span><span>${v}</span></div>`)->Array.joinWith("")
    | ContextTab =>
      switch e.content {
      | Some(c) => `<pre style='font-size:11px;white-space:pre-wrap;word-break:break-all;color:var(--text)'>${c->esc}</pre>`
      | None => "<div style='color:var(--text-dim)'>No context</div>"
      }
    | RawTab =>
      `<pre style='font-size:11px;white-space:pre-wrap;word-break:break-all;color:var(--text)'>${Js.Json.stringifyAny(e)->Option.getWithDefault("{}")->esc}</pre>`
    }
    SpyDom.setHtml("dossier-content", content)
  }
}
