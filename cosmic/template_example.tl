--- Worked examples for [`cosmic.template`], shown by `cosmic docs` and run
--- by `cosmic test`.

local Template = require("cosmic.template")

local Example = {}

--- A template compiles to the source of a Teal module. This one names the
--- record it takes, `Page` from `site.page`, and renders a string; line N
--- of the source is line N of the template.
function Example.compile()
  local source = assert(Template.compile(
    "{{type Page from site.page}}{{mode text}}\nHello, {{.name}}!\n", "greeting.tmpl"))
  print(source)
  -- local page = require("site.page") local function _text(v: string | number): string if v is number then return tostring(v) end return v end local function render(d: page.Page): string local parts: {string} = {} parts[#parts + 1] = "\n"
  -- parts[#parts + 1] = "Hello, " do local v: string | number = d.name parts[#parts + 1] = _text(v) end parts[#parts + 1] = "!\n"
  -- return table.concat(parts) end return {render = render}
  assert(source:find("render(d: page.Page): string", 1, true))
end

--- Without `{{mode text}}` a template is HTML: it returns a [`cosmic.html`]
--- `SafeHtml`, and each slot is escaped for where the markup around it
--- puts it (here text, an attribute value and a URL).
function Example.html()
  local source = assert(Template.compile([[
{{type Page from site.page}}
<a class="{{.kind}}" href="{{.url}}">{{.title}}</a>
]], "link.tmpl"))
  assert(source:find("render(d: page.Page): html.SafeHtml", 1, true))
  assert(source:find("_attr(v)", 1, true) and source:find("_url(v)", 1, true) and source:find("_text(v)", 1, true))
end

--- A slot where no escaping is right is refused, with its line and column.
function Example.refusal()
  local source, why = Template.compile("{{type Page from site.page}}\n<a href={{.url}}>x</a>\n", "link.tmpl")
  assert(source == nil)
  assert(why:find("link.tmpl:2:9:", 1, true) and why:find("unquoted", 1, true), why)
  print(why) -- link.tmpl:2:9: a slot in an unquoted attribute value: quote the value
end

--- Blocks and pipelines: `range` makes each element dot, a stage is a
--- function by import path, and `{{-` and `-}}` drop the whitespace
--- beside them.
function Example.blocks()
  local source = assert(Template.compile([[
{{type Page from site.page}}{{mode text}}
{{range .items -}}
  {{.name | site.fmt.upper}}{{if .last}}.{{else}}, {{end}}
{{- end}}
]], "list.tmpl"))
  assert(source:find('local fmt = require("site.fmt")', 1, true))
  assert(source:find("for _, d1 in ipairs(d.items) do", 1, true))
end

--- `$` is the record `render` is given, wherever it stands, so a loop
--- reaches the page's own fields; `{{range $i, $x := ...}}` binds each
--- element's index (an integer from 1) and the element, which an inner
--- loop reaches by name.
function Example.variables()
  local source = assert(Template.compile([[
{{type Page from site.page}}{{mode text}}
{{range $i, $row := .rows}}{{$i}}. {{$row.name}} in {{$.title}}:
{{range $.cols}}  {{$row.name}}/{{.}}
{{end}}{{end}}
]], "grid.tmpl"))
  assert(source:find("for d2, d1 in ipairs(d.rows) do", 1, true))
  assert(source:find("for _, d3 in ipairs(d.cols) do", 1, true))
end

--- `{{` always starts an action, so literal braces are written as an
--- action that is one string, whose bytes are text: here a help page
--- that shows template syntax.
function Example.literal()
  local source = assert(Template.compile(
    '{{type Page from site.page}}{{mode text}}\nWrite {{"{{.name}}"}} for the name.\n', "help.tmpl"))
  assert(source:find('parts[#parts + 1] = "{{.name}}"', 1, true))
  assert(not source:find("d.name", 1, true))
end

return Example
