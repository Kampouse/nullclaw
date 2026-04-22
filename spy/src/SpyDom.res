// DOM helpers — ReScript v12

@val external doc: _ = "document"

@send external getById: (_, string) => option<_> = "getElementById"
@send external innerHTML_: (_, string) => unit = "innerHTML"
@send external className_: (_, string) => unit = "className"
@send external textContent_: (_, string) => unit = "textContent"
@send external addEvListener: (_, string, _ => unit) => unit = "addEventListener"
@send external clsAdd: (_, string) => unit = "classList.add"
@send external clsRemove: (_, string) => unit = "classList.remove"
@send external clsToggle: (_, string) => unit = "classList.toggle"
@send external focusEl: (_) => unit = "focus"
@send external scrollTop_: (_) => float = "scrollTop"
@send external setScrollTop_: (_, float) => unit = "scrollTop="
@send external scrollHeight_: (_) => float = "scrollHeight"
@send external clickEl: (_) => unit = "click"
@send external setAttr: (_, string, string) => unit = "setAttribute"

external nullableToOption: option<_> => option<_> = "%identity"

let el = (id: string) => {
  switch getById(doc, id)->nullableToOption {
  | Some(e) => e
  | None => JsError.throwWithMessage("not found: " ++ id)
  }
}

let setHtml = (id, html) => innerHTML_(el(id), html)
let setCls = (id, cls) => className_(el(id), cls)
let on = (id, ev, fn) => addEvListener(el(id), ev, fn)
let onClick = (id, fn) => on(id, "click", _ => fn())
let addClass = (id, c) => clsAdd(el(id), c)
let removeClass = (id, c) => clsRemove(el(id), c)
let toggleClass = (id, c) => clsToggle(el(id), c)
let scrollBottom = (id) => setScrollTop_(el(id), scrollHeight_(el(id)))
