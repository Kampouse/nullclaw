// SSE/Polling client

open Types
open EventParser

type pollState = {
  mutable sincePos: option<float>,
  mutable connected: bool,
  mutable stopped: bool,
}

let make = (): pollState => {
  sincePos: None,
  connected: false,
  stopped: false,
}

external httpFetch: string => Js.Promise.t<_> = "fetch"
@send external respJson: _ => Js.Promise.t<Js.Json.t> = "json"

let start = (state: pollState, onEvents: array<spyEvent> => unit, base: string) => {
  let rec poll = () => {
    if state.stopped { () } else {
      let url = switch state.sincePos {
      | Some(s) => base ++ "/api/events?since=" ++ Float.toString(s)
      | None => base ++ "/api/events"
      }
      let p = httpFetch(url)
      let p2 = Js.Promise.then_(resp => {
        let p3 = Js.Promise.then_(json => {
          let events = json->Js.Json.decodeArray->Option.getWithDefault([])
          let parsed = events->Array.mapWithIndex((e, i) => parseEvent(e, i))
          let len = Array.length(events)
          if len > 0 {
            switch parsed[len - 1] {
            | Some(last) => state.sincePos = Some(last.ts)
            | None => ()
            }
            onEvents(parsed)
          }
          state.connected = true
          Js.Promise.resolve()
        }, respJson(resp))
        p3
      }, p)
      let p4 = Js.Promise.catch(_ => {
        state.connected = false
        Js.Promise.resolve()
      }, p2)
      Js.Promise.then_(_ => {
        Js.Global.setTimeout(() => poll(), 500)->ignore
        Js.Promise.resolve()
      }, p4)->ignore
    }
  }
  poll()
}

let stop = (state: pollState) => {
  state.stopped = true
  state.connected = false
}
