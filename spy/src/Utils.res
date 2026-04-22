// Formatting utilities — ReScript v12

@val external mkDate: float => Js.Date.t = "Date"

let pad2 = (i: int): string => {
  let s = Int.toString(i)
  if i < 10 { "0" ++ s } else { s }
}

let intOfFloat = (f: float): int => {
  let s = Float.toString(Math.floor(f))
  switch Int.fromString(s) {
  | Some(i) => i
  | None => 0
  }
}

let fmtTime = (ns: float): string => {
  let ms = ns /. 1_000_000.0
  let d = mkDate(ms)
  pad2(intOfFloat(d->Js.Date.getHours)) ++ ":" ++
  pad2(intOfFloat(d->Js.Date.getMinutes)) ++ ":" ++
  pad2(intOfFloat(d->Js.Date.getSeconds))
}

let fmtDuration = (ns: float): string => {
  let ms = ns /. 1_000_000.0
  if ms < 1000.0 {
    intOfFloat(ms)->Int.toString ++ "ms"
  } else if ms < 60_000.0 {
    intOfFloat(ms /. 1000.0)->Int.toString ++ "s"
  } else {
    let mins = intOfFloat(ms /. 60_000.0)
    let secs = intOfFloat((ms -. float(mins) *. 60_000.0) /. 1000.0)
    Int.toString(mins) ++ "m" ++ Int.toString(secs) ++ "s"
  }
}

let fmtUptime = (ns: float): string => {
  let s = ns /. 1_000_000_000.0
  if s < 60.0 {
    intOfFloat(s)->Int.toString ++ "s"
  } else if s < 3600.0 {
    let mins = intOfFloat(s /. 60.0)
    let secs = intOfFloat(s -. float(mins) *. 60.0)
    Int.toString(mins) ++ "m " ++ Int.toString(secs) ++ "s"
  } else {
    let hrs = intOfFloat(s /. 3600.0)
    let mins = intOfFloat((s -. float(hrs) *. 3600.0) /. 60.0)
    Int.toString(hrs) ++ "h " ++ Int.toString(mins) ++ "m"
  }
}

let fmtTokens = (v: option<float>): string => {
  switch v {
  | None => "-"
  | Some(n) =>
    if n < 1000.0 {
      intOfFloat(n)->Int.toString
    } else {
      let r = Js.Math.round((n /. 1000.0) *. 10.0) /. 10.0
      Float.toString(r) ++ "k"
    }
  }
}

let esc = (s: string): string => {
  s
  -> Js.String.replace("&", "&amp;")
  -> Js.String.replace("<", "&lt;")
  -> Js.String.replace(">", "&gt;")
  -> Js.String.replace("\"", "&quot;")
}
