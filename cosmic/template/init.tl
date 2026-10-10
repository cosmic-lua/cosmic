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
---     <h1>{{.title}}</h1>               a value: fields from dot, `.` for dot
---     {{.when | site.fmt.date}}         then each stage `| module.path.func`
---     {{if .admin}}..{{else if .user}}..{{else}}..{{end}}
---     {{range .items}}<li>{{.name}}</li>{{end}}   dot is each element
---     {{with .owner}}{{.name}}{{else}}nobody{{end}}  dot is the value, if truthy
---
--- A name in a field path is a field of the record: a typo is a type
--- error, not an empty hole. The record's module is required for its types
--- alone, so a declaration file (`.d.tl`) may export it and its body does not
--- run, unless a stage reads it too. A stage is a function by import path,
--- whose module the generated source requires; composing one template in
--- another is a stage naming its `render`. A stage answers exactly one value,
--- wherever it stands: one declared to answer more is a type error on the
--- template's line, so a function that can fail (`nil, reason`) is wrapped by
--- the caller into a stage that answers a value. Truthiness is Lua's: only `nil` and
--- `false` are false, not `""` or `0`.
---
--- `{{-` drops the whitespace before an action (newlines too) and `-}}`
--- the whitespace after it; each needs a space inside it.
---
--- In `html` mode, which returns a [`cosmic.html`] `SafeHtml`, a value is
--- escaped by where it lands in the markup around it, which the compiler
--- follows with the tokenizer a browser uses: as text, a slot takes a
--- string, a number or a `SafeHtml` (strings are escaped, a `SafeHtml` is
--- taken as it is); in a quoted attribute value, a string, a number or a
--- `SafeAttr`; in a quoted URL attribute value (`href`, `src`, `action`
--- and the like, at the start of the value), a string (checked by
--- [`html.href`], which allows a web or mail link or a relative reference
--- and else answers `about:invalid`) or a `SafeUrl`. Another type there is
--- a type error naming the template's line. Where there is no escaping to
--- be had the template is refused, with its line and column: after `<`, in
--- a tag or attribute name, in an unquoted value, in a comment, in an
--- `on...` or `style` attribute, in `<script>` or `<style>`, and a few
--- like them (cosmic/template/markup.tl lists them). An `html` template must
--- also end in plain text, since its `SafeHtml` can go into another's text
--- slot. `{{mode text}}` returns a `string` and escapes nothing, for
--- anything that is not HTML; a slot there takes a string or a number.
---
--- `{{` always starts an action: it cannot be written as literal text
--- (a stage that answers the string is the way). Attributes that
--- frameworks read as code (`hx-*`, `x-on:`, `@click`, `ng-*`) are not
--- recognised; and a slot in any attribute whose name begins with `on`
--- is refused (a literal `onclick="..."` compiles).
---
--- `{{range}}` has no `{{else}}`, and `{{with}}` takes `{{else}}` but no
--- `{{else if}}`: nest an `{{if}}`.
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
local parse = require("cosmic.template.parse")

local record Template
end

--- Compiles a template to the source of a Teal module that exports
--- `render`, requiring [`cosmic.html`] in an `html` template, the record's
--- module (for its types alone, unless a stage reads it), and each stage's.
--- @param src string The template source
--- @param name string The template's name (its file), which heads each reason
--- @return string|nil The module source, with line N the template's line N
--- @return string The reason, as `name:line:col: ...`, when the template is refused
function Template.compile(src: string, name: string): string | nil, string
  local template, why = parse.parse(src, name)
  if template == nil then
    return nil, why
  end
  local _, newlines = src:gsub("\n", "")
  local end_col = #src - (src:match(".*()\n") or 0) + 1
  local placed, reason = context.annotate(template, name, newlines + 1, end_col)
  if not placed then
    return nil, reason
  end
  return codegen.generate(template), ""
end

return Template
