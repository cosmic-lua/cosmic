--- Typed templates, compiled to Teal. `compile` turns a template into the
--- source of a module that exports `render(d: Type): Result`; there is no
--- engine at run time, and everything a template promises is the type
--- checker's, about that source.
---
---     local Template = require("cosmic.template")
---     local source = assert(Template.compile("{{type Page from site.page}}\n<p>{{.title}}</p>\n", "page.tmpl"))
---     -- Teal source: `render(d: page.Page): html.SafeHtml`, with line 2 of
---     -- the module being line 2 of the template
---
--- A template (every action is `{{ ... }}`, all else is literal text):
---
---     {{type Page from site.page}}      the record the template is given,
---                                       exported as `Page` by `site.page`
---     {{mode text}}                     optional, next: `html` is the default
---     {{use htmx}}                      optional, beside `mode`: read the attributes of htmx
---     <h1>{{.title}}</h1>               a value: fields from dot, `.` for dot
---     {{$.title}}  {{$}}                fields from `$`, the record itself
---     {{.when | site.fmt.date}}         then each stage `| module.path.func`
---     {{if .admin}}..{{else if .user}}..{{else}}..{{end}}
---     {{range .items}}<li>{{.name}}</li>{{end}}   dot is each element
---     {{range .items}}..{{else}}none{{end}}       `none` when there is no element
---     {{range $x := .items}}{{$x.name}}{{end}}    `$x` is each element, as dot is
---     {{range $i, $x := .items}}{{$i}}{{end}}     `$i` its index: 1, 2, ...
---     {{with .owner}}{{.name}}{{else}}nobody{{end}}  dot is the value, if truthy
---     {{"{{"}}                          literal text: writes {{
---
--- A name in a field path is a field of the record: a typo is a type
--- error, not an empty hole. The record's module is required for its types
--- alone, so a declaration file (`.d.tl`) may export it and its body does
--- not run, unless a stage reads it too. It must return the record type
--- itself, as a `.d.tl` or `local record M ... end return M` does: one that
--- returns a value is refused on the `{{type}}`'s line, saying so.
---
--- A stage is a function by import path, whose module the generated
--- source requires; composing one template in another is a stage naming
--- its `render`. A stage answers exactly one value, wherever it stands:
--- one declared to answer a fixed number of values above one is a type
--- error on the template's line, so a function that can fail (`nil,
--- reason`) is wrapped by the caller into a stage that answers a value.
--- Truthiness is Lua's: only `nil` and `false` are false, not `""` or `0`.
---
--- A value starts from dot, from `$` or from a variable. `range` and `with`
--- make dot the element or the value, so `$` is how a block reaches the
--- record `render` is given: `$` is that record everywhere, so
--- `{{range .items}}{{.name}} of {{$.title}}{{end}}` needs no copy of the
--- title in each item. A range may bind its element to a variable
--- (`{{range $x := .items}}`), or its index and its element
--- (`{{range $i, $x := .items}}`); the index is an `integer` counted from
--- 1, as `ipairs` counts. A variable is seen in the range's body and in
--- everything nested in it, `with` and other ranges included, so an
--- inner range reaches each enclosing element and index by its name:
--- `{{range $r := .rows}}{{range $c := $.cols}}{{$r.name}}/{{$c}}{{end}}{{end}}`.
--- It is not seen in the range's `{{else}}`, which runs when there is no
--- element, nor after its `{{end}}`. A variable used where it is not seen,
--- or misspelled, is refused with its line and column; one bound where a
--- variable of its name is already seen is refused too, so a name means
--- one value wherever it stands. A field after a variable is checked as
--- one after dot is. `with` binds no variable.
---
--- `{{-` drops the whitespace before an action (newlines too) and `-}}`
--- the whitespace after it; each needs a space inside it.
---
--- In `html` mode, which returns a [`cosmic.html`] `SafeHtml`, a value is
--- escaped by where it lands in the markup around it, which the compiler
--- follows with the tokenizer a browser uses. As text, a slot takes a
--- string, a number or a `SafeHtml` (strings are escaped, a `SafeHtml` is
--- taken as it is). In `<title>` and `<textarea>`, whose text is never
--- markup, and in text inside `<svg>`, `<math>` or `<select>`, where the
--- browser reads markup by other rules than those a `SafeHtml` was checked
--- by (in `<svg>`, an `<img onerror>` inside a `<title>` is a live
--- element), it takes a string or a number. In a quoted attribute value,
--- a slot takes a string, a number or a `SafeAttr`; in a quoted URL
--- attribute value (`href`, `src`, `action` and the like), a slot that
--- begins the value takes a string (checked by [`html.href`], which allows
--- a web or mail link or a relative reference and else answers
--- `about:invalid`) or a `SafeUrl`; a slot after literal text is one piece
--- of the URL (`href="/items/{{.id}}"`, `href="/s?q={{.q}}"`) and takes a
--- string, a number or a `SafeUrlPart`, escaped by [`html.url_part`] so
--- that it is a path segment, a query name or value or a fragment and
--- nothing else. The text before such a slot must fix where the URL goes:
--- begin with `/`, `.`, `?` or `#`, or with `http:`, `https:` or `mailto:`
--- and a path (a slot in a host is refused), or be a relative path that
--- reaches a `/`, `?` or `#` first (`href="java{{.x}}"` is refused); it
--- must not end in a dot segment or the start of a `%2e` (`.`, `%2e`, `%`
--- or `%2` alone in its segment: a value could make `..`, which a browser
--- climbs by: `/.{{.x}}` is refused, `/v1.{{.x}}` is not); it must not
--- hold an `&` before the first `?` or `#` (a browser reads `&sol;` as `/`
--- before it parses the URL: write `/` literally); and after a whole-URL
--- slot it needs a `?` or `#` in the text first. Another type is
--- a type error naming the template's line. Where there is no escaping to
--- be had the template is refused, with its line and column: after `<`, in
--- a tag or attribute name, in an unquoted value, in a comment, in an
--- `on...` or `style` attribute, in `hx-on*`, `hx-vars` or `hx-trigger` (htmx runs them as script)
--- or the legacy `hx-ws` (a socket URL after `connect:`),
--- in `hx-vals`, `hx-headers` or `hx-request` unless the template says
--- `{{use htmx}}` (they are JSON that htmx may run), in `<script>` or `<style>`, and a few like them
--- (cosmic/template/markup.tl lists them). An `html` template must also end in plain text, since its
--- `SafeHtml` can go into another's text slot. `{{mode text}}` returns a
--- `string` and escapes nothing, for anything that is not HTML; a slot
--- there takes a string or a number.
---
--- `{{` always starts an action. To write it as text, write an action
--- that is one double-quoted string, as Go's templates do: its bytes are
--- literal text, so `{{"{{"}}` writes `{{` and `{{"{{.name}}"}}` writes
--- `{{.name}}`. `\"` and `\\` are its only escapes, it is on one line,
--- and it takes no stage and stands in no condition. It is text, not a
--- slot: `html` mode escapes nothing in it and reads it as markup, as it
--- does the text around it.
---
--- `{{use htmx}}`, in the header after `{{type}}` and in either order with
--- `{{mode}}`, reads the attributes of htmx, with or without a `data-`
--- prefix and in any case (the dialect's table is [`dialect/htmx.tl`], written
--- against htmx 2.0.11). `hx-get`, `hx-post`, `hx-put`, `hx-patch`,
--- `hx-delete`, `hx-push-url`, `hx-replace-url`, `sse-connect` and
--- `ws-connect` are URLs, a slot as in `href` (a whole one, or a part after
--- literal text); but a string given whole must be a same-origin reference
--- ([`html.local_href`]: no scheme, no `//host`, else `about:invalid`) and
--- only a `SafeUrl` can name another origin, since htmx swaps what the URL
--- answers into the page. `hx-vals`, `hx-headers` and `hx-request` take a
--- [`html.SafeJson`] as the whole value (`hx-vals='{{.vals}}'`), entity
--- escaped for either quote, with nothing before or after the slot: JSON
--- text cannot begin with the `js:` that makes htmx run it. A selector
--- attribute (`hx-target`, `hx-select`, `hx-select-oob`, `hx-include`,
--- `hx-indicator`, `hx-disabled-elt`, `hx-sync`, `hx-swap`, `hx-swap-oob`
--- and `hx-target-*` of the response-targets extension) takes a slot only
--- inside an identifier after `#` or `.` (`hx-target="#row-{{.id}}"`), a
--- string or a number escaped by [`html.escape_css_attr`] as CSS identifier
--- text; a slot anywhere else in a selector (`[data-id='{{.id}}']`) is
--- refused. `hx-swap`, `hx-ext`, `hx-disable`, `hx-boost` and `hx-params`
--- take no slot: their values change what htmx does for a whole subtree, so
--- they are the author's text. Other `hx-*` attributes (`hx-confirm`,
--- `hx-prompt`, ...) are plain attributes. `hx-trigger` stays refused: its
--- `[filter]` is script. A dialect is a name in the
--- header, never inferred from the attributes in the text. [`Template.compile`]
--- takes a registry of other dialects as its `options`.
---
--- Other attributes that frameworks read as code (`x-on:`, `@click`,
--- `ng-*`) are not recognised; a slot in any attribute whose name begins
--- with `on` is refused (a literal `onclick="..."` compiles), and so is a
--- slot in `hx-on*`, `hx-vars`, `hx-trigger` and `hx-ws`, with or without `{{use
--- htmx}}` and a `data-` prefix, and in `hx-vals`, `hx-headers` and
--- `hx-request` without `{{use htmx}}`.
---
--- `{{range}}` and `{{with}}` take one `{{else}}` but no `{{else if}}`:
--- nest an `{{if}}`. A range's `{{else}}` runs when the list has no first
--- element, and dot there is what it is outside the range; the list is
--- read once. It is the way to say "none": `{{if .items}}` is true of an
--- empty list, which is a table.
---
--- Line N of the template is line N of the source, so a type error reads
--- as `page.tmpl:12: ...`.
---
--- Slots in `<script>`, `<style>`, and `on...` and `style` attributes stay
--- refused: they are what a JavaScript and a CSS escaper with a type of
--- its own would earn (doc/roadmap.md), not a gap a stopgap here would
--- close.

local codegen = require("cosmic.template.codegen")
local context = require("cosmic.template.context")
local dialect = require("cosmic.template.dialect")
local parse = require("cosmic.template.parse")
local types = require("cosmic.template.types")

local record Template
  --- The attribute vocabulary of a dialect, as data: see
  --- [`cosmic/template/dialect/htmx.tl`] for one.
  type Dialect = types.Def

  --- What `compile` may be given beyond the template.
  record Options
    --- The dialects `{{use name}}` may name, in place of the built-in ones
    --- (`htmx`): each is the data [`dialect/htmx.tl`] holds. The built-in ones where absent.
    dialects: {string: Template.Dialect}?
  end
end

--- Compiles a template to the source of a Teal module that exports
--- `render`, requiring [`cosmic.html`] in an `html` template, the record's
--- module (for its types alone, unless a stage reads it), and each stage's.
--- @param src string The template source
--- @param name string The template's name (its file), which heads each reason
--- @param options? Template.Options Dialects other than the built-in ones
--- @return string|nil The module source, with line N the template's line N
--- @return string The reason, as `name:line:col: ...`, when the template is refused
function Template.compile(src: string, name: string, options?: Template.Options): string?, string
  local registry = options ~= nil and options.dialects or dialect.registry
  local template, why = parse.parse(src, name, registry)
  if template == nil then
    return nil, why
  end
  local attributes, conflict = dialect.resolve(template.dialects, registry)
  if attributes == nil then
    return nil, name .. ":" .. tostring(template.line) .. ":1: " .. conflict
  end
  local _, newlines = src:gsub("\n", "")
  local end_col = #src - (src:match(".*()\n") or 0) + 1
  local placed, reason = context.annotate(template, name, newlines + 1, end_col, attributes)
  if not placed then
    return nil, reason
  end
  return codegen.generate(template), ""
end

return Template
