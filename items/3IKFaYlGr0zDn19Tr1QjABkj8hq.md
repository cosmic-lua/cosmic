Design reworked from the original Go-`text/template` capture. The reflective
runtime engine is **dropped**: templates compile to Teal source and the existing
checker does the checking. Sizing is still above one session — see the seam at
the end — but the design below is decided.

## Change

Add `cosmic/template/`, a directory module (precedent: `cosmic/fs/`,
`cosmic/doc/`, `cosmic/flags/`, `cosmic/sqlite/`) that turns template text into
**Teal source**. It has no template engine, no runtime, and no reflection: it is a
text-to-text transform, and every guarantee comes from compiling its output.

### Why not a runtime engine

Go's `text/template` walks an `any` by reflection. Teal has no reflection, so a
port would index `any` at every field access — a cast factory inside the standard
library, against a G3 win condition of zero `as` casts (445 across 132 files today,
ratcheted per PR by `_build/casts.tl`). Compiling to Teal moves every one of those
checks to the compiler: `{{.user.nmae}}` is a build-time type error.

### The data type is named, not inferred

A template's first action is required:

```
{{type Page from myapp.page}}
```

The generator emits `local page = require("myapp.page")` and types the render
function's parameter `page.Page`. Inference was rejected on a measurement, not on
taste — Teal records are **nominal**, so a generated record is a type nothing can
satisfy:

```
$ cosmic --check types nominal.tl     # record Page{title} -> function(Generated{title})
nominal.tl:11:14: error: argument 1: Page is not a Generated
$ cosmic --check types iface.tl       # record Page{title} -> function(interface Data{title})
iface.tl:11:14: error: got Page, expected interface Data
```

An inferred record would force every call site to rebuild its data as a fresh
literal, and two templates over one `Page` would demand two incompatible records.

### Grammar

Field paths use the record's **actual field names**, unchanged — no Go-style
capitalisation rule, so `{{.body}}` and `{{.user.name}}` are what D20's snake_case
records already spell.

```
{{type <Record> from <import.path>}}   required, first action
{{mode html}}                          optional, default text
{{.field}} {{.a.b}}                    field access
{{if <pipeline>}} … {{else}} … {{end}}
{{range <pipeline>}} … {{end}}         rebinds dot to the element
{{with <pipeline>}} … {{end}}          rescopes dot
{{<pipeline> | <import.path>}}         pipeline stages, left to right
```

**There is no `{{template}}` action.** A compiled template module exports
`render(d: T)`, so composition is just a pipeline stage naming it — one rule
instead of two, and typed.

### Pipelines are ordinary function calls

`{{.body | cosmic.html.safe}}` emits `local html = require("cosmic.html")` and
`html.safe(d.body)`. No `Funcs` registry: a registry is a runtime mechanism for
resolving names the compiler already resolves better, and it cannot check arity or
types. Any function reachable by import path works, with no registration.

### HTML mode: types enforce escaping, not a context scanner

`cosmic/html.tl` gains a nominal type and two constructors. Its current exports are
exactly `escape` and `unescape` (`M: HtmlModule = {escape = escape, unescape =
unescape}`), and **both keep their present signatures** — no break, D10 untouched:

```teal
local record SafeHtml
  raw: string
end
safe(s: string): SafeHtml      -- escapes, then wraps
trusted(s: string): SafeHtml   -- wraps WITHOUT escaping; the explicit hatch for
                               -- already-rendered markup, and the only way in
```

In `mode html` the generator binds every interpolation through that type, so a raw
string cannot reach the output:

```teal
local v3: html.SafeHtml = html.safe(d.body)   -- ok
local v4: html.SafeHtml = d.body              -- error: got string, expected SafeHtml
```

Measured, on exactly this shape:

```
$ cosmic --check types safe.tl
safe.tl:12:12: error: argument 1: got string, expected SafeHtml
```

`render` returns `SafeHtml` in html mode and `string` in text mode, which is what
makes composition safe: a nested template's output is already the right type.

The cost, stated: one table allocation per interpolation, because a nominal type in
Teal needs a record. Text mode allocates nothing extra. If `_perf` later shows this
matters for a serving path, the alternative is a `{SafeHtml}` accumulator with one
concat — the representation is private to `cosmic.html` and can change without
touching templates.

**Nothing is escaped implicitly.** A missing escaper is a compile error naming the
line, never silent output — which is the same bargain D10 already describes as
"honest types make breakage loud".

### Files

- `cosmic/template/types.tl` — AST records.
- `cosmic/template/lex.tl` — tokens: literal text runs, actions, delimiters.
- `cosmic/template/parse.tl` — AST; errors as `nil, string` with template line and
  column.
- `cosmic/template/codegen.tl` — AST to Teal source. Emits `-- <name>:<line>`
  comments before each interpolation so a type error in generated code points back
  at the template line that caused it.
- `cosmic/template/init.tl` — public API:
  `compile(src: string, name: string): string | nil, string`, returning Teal module
  source. `name` is used only for the source-mapping comments.
- `cosmic/html.tl` — add `SafeHtml`, `safe`, `trusted`; leave `escape`/`unescape`
  alone.
- `cosmic/template/*_test.tl`, and `cosmic/template_example.tl` with `Example_*`.

Every file under the 500-line cap; a lexer/parser/codegen split is what keeps them
there.

### Gates specific to this change

Two ratchet-worthy properties, as tests in the diff rather than sidecar bullets:

- A generated module **type-checks** against a fixture data module.
- An html-mode template interpolating a raw `string` **fails** to type-check. This
  is the whole safety claim; a test that only checks the happy path proves nothing.

### Sizing seam

Lexer, parser, codegen, the `cosmic.html` additions and their tests are past the
~400-line smell threshold. The clean cut is `lex`+`parse`+`types` (internal, no
public API, nothing user-facing to misuse) landing before `codegen`+`init`+the html
additions. Splitting there preserves the invariant that no release ever carries an
HTML mode without escaping, because nothing renders until the second half lands.

## Non-goals

- **No runtime template engine.** Templates known only at run time are not served
  by this item.
- **No reflection, no `Funcs` registry, no runtime name resolution.**
- **No `*.tmpl` build convention.** Build-time use is an ordinary user `*_gen.tl`
  calling `compile`. The convention is its own item.
- **No URL, JavaScript or CSS contexts.** HTML text context only; the rest is its
  own item.
- **No context scanner.** Escaping is a type obligation, not an inferred property
  of surrounding markup.
