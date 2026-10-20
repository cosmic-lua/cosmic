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

--- A slot after literal text in a URL attribute is one piece of the URL,
--- escaped by [`html.url_part`] (so a value cannot add a `/`, `?` or `:`);
--- the text before it must fix where the URL goes, so `java{{.x}}` and a
--- slot in a host are refused, and so is any slot in an attribute htmx
--- runs as script.
function Example.url_parts()
  local source = assert(Template.compile([[
{{type Page from site.page}}
<a href="/items/{{.id}}?q={{.query}}">{{.title}}</a>
]], "link.tmpl"))
  assert(source:find("_part(v)", 1, true) and not source:find("_url(v)", 1, true))
  local java, scheme = Template.compile('{{type Page from site.page}}\n<a href="java{{.x}}">x</a>\n', "link.tmpl")
  assert(java == nil)
  assert(scheme:find("link.tmpl:2:", 1, true) and scheme:find("fixes where the URL goes", 1, true), scheme)
  local on, script = Template.compile('{{type Page from site.page}}\n<a hx-on:click="{{.x}}">x</a>\n', "link.tmpl")
  assert(on == nil)
  assert(script:find("would be script", 1, true), script)
end

--- `{{use htmx}}`, in the header beside `{{mode}}`, reads the attributes of
--- htmx: a request URL is a same-origin reference or a part after text, a
--- selector slot stands inside an identifier after `#` or `.`, and
--- `hx-vals`, `hx-headers` and `hx-request` take a `SafeJson` as the whole
--- value. A slot in `hx-trigger` (a filter is script) is refused, as `hx-on`
--- is without `{{use}}`.
function Example.htmx()
  local source = assert(Template.compile([[
{{type Row from site.row}}
{{use htmx}}
<tr id="row-{{.id}}"><td><button hx-delete="/items/{{.id}}" hx-target="#row-{{.id}}"
  hx-vals='{{.vals}}' hx-get="{{.back}}">Delete</button></td></tr>
]], "row.tmpl"))
  assert(source:find("render(d: row.Row): html.SafeHtml", 1, true))
  assert(source:find("local v: html.SafeJson = d.vals", 1, true))
  assert(source:find("_sel(v)", 1, true) and source:find("_part(v)", 1, true) and source:find("_lurl(v)", 1, true))
  local plain, why = Template.compile('{{type Row from site.row}}\n<b hx-vals=\'{{.vals}}\'>x</b>\n', "row.tmpl")
  assert(plain == nil)
  assert(why:find("{{use htmx}}", 1, true), why)
  local trigger, trigger_why = Template.compile(
    '{{type Row from site.row}}{{use htmx}}\n<b hx-trigger="click[{{.f}}]">x</b>\n', "row.tmpl")
  assert(trigger == nil)
  assert(trigger_why:find("'[filter]'", 1, true), trigger_why)
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
