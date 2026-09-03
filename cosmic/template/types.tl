--- AST and token records shared by the template lexer, parser, and
--- code generator. Internal to `cosmic.template`: a deeper module path
--- is never public API ([`cosmic/doc/visibility.tl`](../doc/visibility.tl)),
--- and nothing here is meant to be required from outside this directory.

--- One lexical token from a template source.
---
--- `kind` is one of:
---   "text"  a run of literal text outside any `{{ }}` action
---   "open"  the `{{` that starts an action
---   "close" the `}}` that ends an action
---   "field" a dotted field path inside an action (`.`, `.body`, `.a.b`)
---   "word"  a bareword inside an action: a keyword, a record name, or
---           a dotted import path (`type`, `from`, `if`, `Page`,
---           `myapp.page`, `cosmic.html.safe`)
---   "pipe"  the `|` that chains a pipeline stage
local record Token
  kind: string
  value: string
  line: integer
  col: integer
end

--- One pipeline stage: a function reached by import path, split into
--- the module `require`d and the function called on it — `cosmic.
--- html.safe` becomes module_path "cosmic.html", func_name "safe".
local record Stage
  import_path: string
  module_path: string
  func_name: string
  line: integer
end

--- A dotted expression: a field path off the current "dot" value, run
--- through zero or more pipeline stages left to right. `path` holds
--- the field names with the leading dot stripped (`.a.b` -> {"a",
--- "b"}); an empty `path` means the pipeline starts from dot itself
--- (`{{.}}`).
local record Pipeline
  path: {string}
  stages: {Stage}
  line: integer
end

--- One parsed template node, tagged by `kind`. Only the fields that
--- kind actually uses are meaningful; the parser always sets every
--- other field to a harmless zero value (`""`, an empty `Pipeline`, an
--- empty `{Node}`) rather than leaving it nil, so a reader dispatching
--- on `kind` never has to narrow:
---   "text"   text
---   "interp" pipeline, ctx
---   "if"     pipeline, body, else_body (empty when there is no {{else}})
---   "range"  pipeline, body
---   "with"   pipeline, body
---
--- `ctx` (an "interp" node only; `""` on every other kind) names the
--- interpolation's escaping context in `{{mode html}}`: "html" (the
--- default, when the action carries no context word), "attr", "url",
--- "js", or "css" — one of the words `{{<ctx> <pipeline>}}` may open
--- with. It is meaningless in `{{mode text}}`, which the parser never
--- lets it appear in.
local record Node
  kind: string
  text: string
  pipeline: Pipeline
  body: {Node}
  else_body: {Node}
  ctx: string
  line: integer
end

--- A fully parsed template: the required type declaration, the
--- optional mode (default "text"), and the body nodes to render in
--- order.
local record Template
  type_name: string
  import_path: string
  mode: string
  body: {Node}
end

local record TypesModule
  type Token = Token
  type Stage = Stage
  type Pipeline = Pipeline
  type Node = Node
  type Template = Template
end

local M: TypesModule = {}
return M
