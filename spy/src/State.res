// Central state store

open Types
open EventParser

let make = (): appState => {
  events: [],
  entities: Js.Dict.empty(),
  selectedIdx: -1,
  connected: false,
  paused: false,
  following: true,
  filter: "",
  errFilter: false,
  showSearch: false,
  showHelp: false,
  dossierTab: SummaryTab,
  hideHeartbeats: true,
  startTime: Js.Date.now(),
  nextIdx: 0,
}

let addEvents = (s: appState, incoming: array<spyEvent>): unit => {
  incoming->Array.forEach(e => {
    s.nextIdx = s.nextIdx + 1
    e._idx = s.nextIdx - 1
  })
  s.events = Array.concat(s.events, incoming)

  incoming->Array.forEach(e => {
    let name = switch (e.provider, e.model) {
    | (Some(p), Some(m)) => p ++ "/" ++ m
    | (Some(p), _) => p
    | (_, Some(m)) => m
    | _ => "unknown"
    }
    switch Js.Dict.get(s.entities, name) {
    | Some(ent) =>
      ent.events = Array.concat(ent.events, [e])
      ent.lastSeen = e.ts
      if e.kind === ErrorEvent { ent.errorCount = ent.errorCount + 1 }
      if e.ok === Some(true) { ent.successCount = ent.successCount + 1 }
    | None =>
      Js.Dict.set(s.entities, name, {
        name,
        events: [e],
        firstSeen: e.ts,
        lastSeen: e.ts,
        errorCount: e.kind === ErrorEvent ? 1 : 0,
        successCount: e.ok === Some(true) ? 1 : 0,
      })
    }
  })
}

let filtered = (s: appState): array<spyEvent> => {
  s.events->Array.filter(e => {
    let hideOk = s.hideHeartbeats && e.kind === HeartbeatTick
    let matchErr = s.errFilter && e.kind !== ErrorEvent
    let matchFilter = if s.filter === "" { true } else {
      let q = s.filter->Js.String.toLowerCase
      let kindStr = e.kind->kindToString->Js.String.toLowerCase
      let prov = e.provider->Option.getWithDefault("")
      let mod = e.model->Option.getWithDefault("")
      let det = e.detail->Option.getWithDefault("")
      kindStr->String.includes(q) ||
      prov->Js.String.toLowerCase->String.includes(q) ||
      mod->Js.String.toLowerCase->String.includes(q) ||
      det->Js.String.toLowerCase->String.includes(q)
    }
    !hideOk && !matchErr && matchFilter
  })
}

let selectEvent = (s: appState, idx: int): unit => {
  s.selectedIdx = idx
}

let clearFeed = (s: appState): unit => {
  s.events = []
  s.entities = Js.Dict.empty()
  s.selectedIdx = -1
  s.nextIdx = 0
}

let selectedEvent = (s: appState): option<spyEvent> => {
  s.events->Array.find(e => e._idx === s.selectedIdx)
}
