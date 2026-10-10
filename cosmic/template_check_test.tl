--- What a compiled template does under Teal's checker and when run: each
--- template below is a `page.tmpl` in a project of its own in the temporary
--- directory, built with [`importer.compile`] (so a warning is a refusal,
--- as for any module of the tree), and then loaded and called. An error
--- names the template's own line.
---
--- The generated source is built as the build makes it, against the real
--- [`cosmic.html`]. Its types are checked, and what it renders is made by
--- the core's own escapers and `href`.

local Fs = require("cosmic.fs")
local Html = require("cosmic.html")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

local DATA <const> = [[
local html = require("cosmic.html")
local record data
  record Item
    name: string
    n: integer
  end
  record User
    name: string
  end
  record Page
    title: string
    cls: string
    n: integer
    url: string
    h: html.SafeHtml
    a: html.SafeAttr
    u: html.SafeUrl
    items: {Item}
    user: User
    flag: boolean
    list: {string}
    ["end"]: string
    ["type"]: string
    ["record"]: string
    ["enum"]: string
    ["global"]: string
    ["is"]: string
    ["as"]: string
    ["where"]: string
    ["function"]: string
    ["interface"]: string
    ["local"]: string
    ["nil"]: string
    ["self"]: string
    ["_"]: string
    ["d"]: string
    ["parts"]: string
    ["render"]: string
    ["table"]: string
  end
end
return data
]]

local FMT <const> = [[
local html = require("cosmic.html")
local record fmt
  upper: function(s: string): string
  bracket: function(s: string): string
  markup: function(s: string): html.SafeHtml
  attr: function(s: string): html.SafeAttr
  url: function(s: string): html.SafeUrl
  ["end"]: function(s: string): string
end
function fmt.upper(s: string): string
  return s:upper()
end
function fmt.bracket(s: string): string
  return "[" .. s .. "]"
end
function fmt.markup(s: string): html.SafeHtml
  return html.trust(s)
end
function fmt.attr(s: string): html.SafeAttr
  return html.trust_attr(s)
end
function fmt.url(s: string): html.SafeUrl
  return html.href(s)
end
fmt["end"] = fmt.bracket
return fmt
]]

local UTIL <const> = [[
local record util
  upper: function(s: string): string
end
function util.upper(s: string): string
  return s:upper()
end
return util
]]

--- Builds the project of `files` (paths to text) in the directory `case`
--- of `tmp`: the Lua of every module (by path), or nil and what refused.
local function build(tmp: string, case: string, files: {string: string}): {string: string} | nil, string
  local root = tmp .. "/" .. case
  assert(Fs.mkdirs(root))
  for name, text in pairs(files) do
    local dir = name:match("^(.*)/[^/]*$")
    if dir ~= nil then
      assert(Fs.mkdirs(root .. "/" .. dir))
    end
    assert(Fs.write(root .. "/" .. name, text))
  end
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return nil, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, false)
  if staged == nil then
    local _, _ = work.close(handle)
    return nil, stage_trouble
  end
  local result, trouble = importer.compile(handle, built, "template-check-test")
  local _, _ = work.close(handle)
  if result == nil then
    return nil, trouble
  end
  local lua: {string: string} = {}
  for _, m in ipairs(result.modules) do
    lua[m.path] = m.lua
  end
  return lua, ""
end

--- Builds `template` as the module `page`, beside `data` and `fmt`.
local function project(tmp: string, case: string, template: string): {string: string} | nil, string
  return build(tmp, case, { ["data.tl"] = DATA, ["fmt.tl"] = FMT, ["util/string.tl"] = UTIL,
    ["page.tmpl"] = template })
end

--- `s` as the core's `escape_attr` makes it in a document.
local function esc_attr(s: string): string
  return Html.raw_attr(Html.escape_attr(s))
end

--- The module `path` of `lua`, loaded against the real [`cosmic.html`].
local function load_module(lua: {string: string}, path: string): any
  local loaded: {string: any} = {}
  local function req(name: string): any
    if name == "cosmic.html" then
      return Html
    end
    if loaded[name] == nil then
      local source = assert(lua[name], "no module " .. name)
      local env: {string: any} = setmetatable({}, { __index = _G })
      env.require = req
      local chunk = assert(load(source, "=" .. name, "t", env))
      loaded[name] = chunk()
    end
    return loaded[name]
  end
  return req(path)
end

--- What a compiled template exports.
local record Loaded
  render: function({string: any}): any
end

--- What `template` renders to for `page`.
local function render(tmp: string, case: string, template: string, page: {string: any}): string
  local lua, trouble = project(tmp, case, template)
  assert(lua ~= nil, trouble)
  local mod = load_module(lua, "page")
  assert(mod is Loaded, "page exports no render")
  local out = mod.render(page)
  if out is Html.SafeHtml then
    return Html.raw(out)
  end
  assert(out is string, "render answered a " .. type(out))
  return out
end

--- What building `template` refuses with, which it must.
local function refused(tmp: string, case: string, template: string): string
  local lua, trouble = project(tmp, case, template)
  assert(lua == nil, "built")
  return trouble
end

local HEAD <const> = "{{type Page from data}}\n"

local function test_the_checker_counts_a_warning_as_a_refusal_here(tmp: string)
  local lua, trouble = build(tmp, "warning", { ["x.tl"] = "local unused = 1\nreturn {}\n" })
  assert(lua == nil and trouble:find("unused", 1, true), tostring(trouble))
end

local function test_a_type_error_in_a_text_template_is_on_the_templates_line(tmp: string)
  local template = "{{type Page from data}}{{mode text}}\nfine {{.title}}\n\nbad {{.items}}\n"
  local trouble = refused(tmp, "text-error", template)
  assert(trouble:find("page.tmpl:4:", 1, true), trouble)
  assert(trouble:find("string | number", 1, true), trouble)
  local multi = refused(tmp, "multi", "{{type Page from data}}{{mode text}}\n{{.title\n  | fmt.upper}}\n{{.items}}")
  assert(multi:find("page.tmpl:4:", 1, true) and not multi:find("page.tmpl:2:", 1, true), multi)
end

local function test_a_slot_takes_what_its_place_accepts(tmp: string)
  local ok, why = project(tmp, "accepts", HEAD .. [[
<h1 class="{{.cls}}" title='{{.a}}'>{{.title}} {{.n}} {{.h}} {{.cls | fmt.upper}}</h1>
<a href="{{.url}}">{{.user.name}}</a><a href="{{.u}}"></a><a href="{{.url | fmt.bracket}}">x</a>
{{range .items}}<i title="{{.n}}">{{.name}}</i>{{end}}
{{range .items}}<i title="{{.n}}">{{.name}}</i>{{else}}<i title="{{.title}}">{{.h}}</i>{{end}}
{{if .flag}}{{.h}}{{else if .title}}a{{else}}b{{end}}
{{with .user}}{{.name}}{{end}}{{with .user}}x{{else}}{{.title}}{{end}}
]])
  assert(ok ~= nil, why)
end

local WRONG <const>: {{string}} = {
  { "<p>{{.a}}</p>", "SafeAttr" },
  { "<p>{{.u}}</p>", "SafeUrl" },
  { "<p>{{.items}}</p>", "{Item}" },
  { "<p>{{.flag}}</p>", "boolean" },
  { "<p title=\"{{.h}}\">", "SafeHtml" },
  { "<p title=\"{{.u}}\">", "SafeUrl" },
  { "<p title=\"{{.items}}\">", "{Item}" },
  { "<a href=\"{{.h}}\">", "SafeHtml" },
  { "<a href=\"{{.a}}\">", "SafeAttr" },
  { "<a href=\"{{.n}}\">", "integer" },
  { "<a href=\"{{.items}}\">", "{Item}" },
  { "<p>{{.nope}}</p>", "nope" },
  { "<p>{{.user.nmae}}</p>", "nmae" },
}

local function test_a_slot_given_what_its_place_refuses_is_a_type_error_on_its_line(tmp: string)
  for index, case in ipairs(WRONG) do
    local trouble = refused(tmp, "wrong" .. index, HEAD .. "ok\n" .. case[1])
    assert(trouble:find("page.tmpl:3:", 1, true), case[1] .. ": " .. trouble)
    assert(trouble:find(case[2], 1, true), case[1] .. ": " .. trouble)
  end
end

local function test_nested_blocks_build_without_a_warning_or_a_repeated_name(tmp: string)
  local lua, trouble = project(tmp, "nested", HEAD .. [[
{{range .items}}
  {{if .name}}{{with .name}}{{.}}{{end}}{{end}}
  {{.n}}
  {{range .name}}x{{end}}
{{end}}
{{with .user}}{{end}}{{range .list}}{{range .}}{{end}}{{end}}
]])
  assert(lua == nil, "ranged over a string and a string")
  assert(trouble:find("page.tmpl:5:", 1, true), trouble)
  local clean, why = project(tmp, "nested-clean", HEAD .. [[
{{range .items}}
  {{if .name}}{{with .name}}{{.}}{{end}}{{end}}
  {{.n}}
{{end}}
{{with .user}}{{end}}{{range .list}}x{{end}}
]])
  assert(clean ~= nil, why)
end

local function test_a_template_with_no_action_builds_without_a_warning(tmp: string)
  local lua, trouble = project(tmp, "plain", HEAD .. "<p>hi</p>")
  assert(lua ~= nil, trouble)
  local text, why = project(tmp, "plain-text", "{{type Page from data}}{{mode text}}hi")
  assert(text ~= nil, why)
end

local function test_a_field_named_like_a_word_of_the_language_is_reached(tmp: string)
  local names = { "end", "type", "record", "enum", "global", "is", "as", "where", "function", "interface",
    "local", "nil", "self", "_", "d", "parts", "render", "table" }
  local actions: {string} = {}
  for _, name in ipairs(names) do
    actions[#actions + 1] = "{{." .. name .. "}}"
  end
  local lua, trouble = project(tmp, "words", HEAD .. table.concat(actions, " ") .. "{{.end | fmt.end}}")
  assert(lua ~= nil, trouble)
end

local function test_text_mode_renders_what_it_is_given(tmp: string)
  local page: {string: any} = { title = "<b> & \"q\"", n = 3, items = { { name = "a", n = 1 }, { name = "b", n = 2 } },
    flag = false, user = { name = "u" }, list = {} }
  local out = render(tmp, "text-run", [[
{{type Page from data}}{{mode text}}
{{.title}} {{.n}} {{.title | fmt.upper}}
{{range .items -}}
  {{.name}}={{.n}};
{{- end}}
{{if .flag}}yes{{else if .user}}user {{.user.name}}{{else}}no{{end}}
{{with .user}}{{.name}}{{else}}none{{end}}
]], page)
  assert(out == "\n<b> & \"q\" 3 <B> & \"Q\"\na=1;b=2;\nuser u\nu\n", out)
  page.flag = true
  page.user = nil
  local again = render(tmp, "text-run2", [[
{{type Page from data}}{{mode text}}{{if .flag}}yes{{else}}no{{end}}{{with .user}}{{.name}}{{else}} none{{end}}]], page)
  assert(again == "yes none", again)
end

local function test_html_mode_escapes_by_place(tmp: string)
  local page: {string: any} = { title = "<i>&", cls = "a\"b'c", n = 7, url = "javascript:alert(1)",
    h = Html.trust("<b>x</b>"), a = Html.escape_attr("q&r"), u = Html.href("/x"), user = { name = "<u>" },
    items = { { name = "p", n = 1 }, { name = "<q>", n = 2 } } }
  local out = render(tmp, "html-run", HEAD .. [[
<h1 class="{{.cls}}" title='{{.a}}'>{{.title}} {{.n}} {{.h}}</h1>
<a href="{{.url}}">{{.user.name}}</a> <a href='{{.u}}'></a>
{{range .items}}<i title="{{.n}}">{{.name}}</i>{{end}}
]], page)
  assert(out == '\n<h1 class="a&#34;b&#39;c" title=\'q&#38;r\'>&lt;i&gt;&amp; 7 <b>x</b></h1>\n' ..
      '<a href="' .. esc_attr("about:invalid") .. '">&lt;u&gt;</a> <a href=\'' .. esc_attr("/x") .. '\'></a>\n' ..
      '<i title="1">p</i><i title="2">&lt;q&gt;</i>\n', out)
  page.url = "/a?x=1&y=2"
  local second = render(tmp, "html-run2", HEAD .. '<a href="{{.url}}">', page)
  assert(second == '\n<a href="' .. esc_attr("/a?x=1&y=2") .. '">', second)
  local text = render(tmp, "html-run3", HEAD .. '<title>{{.title}}</title><textarea>{{.n}}</textarea>', page)
  assert(text == "\n<title>&lt;i&gt;&amp;</title><textarea>7</textarea>", text)
end

local function test_a_module_named_like_a_global_is_not_the_global(tmp: string)
  local page: {string: any} = { title = "abc" }
  local out = render(tmp, "global", "{{type Page from data}}{{mode text}}{{.title | util.string.upper}}", page)
  assert(out == "ABC", out)
end

local function test_a_block_inside_and_after_svg_builds(tmp: string)
  local lua, trouble = project(tmp, "svg", HEAD ..
      '<svg>{{if .flag}}<g class="{{.cls}}"></g>{{end}}</svg>{{if .flag}}<p title="{{.cls}}">{{.title}}</p>{{end}}' ..
      '<title>{{.title}}</title>')
  assert(lua ~= nil, trouble)
end

local function test_a_title_takes_no_markup(tmp: string)
  local trouble = refused(tmp, "title", HEAD .. "<title>{{.h}}</title>")
  assert(trouble:find("SafeHtml", 1, true) and trouble:find("page.tmpl:2:", 1, true), trouble)
  local area = refused(tmp, "area", HEAD .. "<textarea>{{.h}}</textarea>")
  assert(area:find("page.tmpl:2:", 1, true), area)
end

local function test_a_range_over_strings_and_a_with_over_an_optional_field(tmp: string)
  local page: {string: any} = { list = { "a", "<" }, user = { name = "u&" } }
  local out = render(tmp, "range-strings", HEAD .. "{{range .list}}[{{.}}]{{end}}" ..
      "{{with .user}}<b>{{.name}}</b>{{else}}none{{end}}", page)
  assert(out == "\n[a][&lt;]<b>u&amp;</b>", out)
  page.user = nil
  local none = render(tmp, "with-nil", HEAD .. "{{with .user}}<b>{{.name}}</b>{{else}}none{{end}}", page)
  assert(none == "\nnone", none)
end

local function test_a_stage_answering_a_safe_type_fits_the_slot_that_takes_it(tmp: string)
  local page: {string: any} = { title = "/a<b" }
  local out = render(tmp, "stages", HEAD ..
      '<p>{{.title | fmt.markup}}</p><i title="{{.title | fmt.attr}}"></i><a href="{{.title | fmt.url}}">x</a>', page)
  assert(out == "\n<p>/a<b</p><i title=\"/a<b\"></i><a href=\"" .. esc_attr("/a<b") .. "\">x</a>", out)
  for index, wrong in ipairs({ "<p>{{.title | fmt.attr}}</p>", "<i title=\"{{.title | fmt.markup}}\">",
      "<a href=\"{{.title | fmt.attr}}\">", "<a href=\"{{.title | fmt.markup}}\">",
      "<i title=\"{{.title | fmt.url}}\">", "<p>{{.title | fmt.url}}</p>" }) do
    local trouble = refused(tmp, "stage-wrong" .. index, HEAD .. wrong)
    assert(trouble:find("page.tmpl:2:", 1, true) and trouble:find("Safe", 1, true), wrong .. ": " .. trouble)
  end
end

local function test_a_crlf_template_goes_through_the_checker_and_keeps_its_line_ends(tmp: string)
  local page: {string: any} = { title = "t" }
  local out = render(tmp, "crlf", "{{type Page from data}}\r\n<p>\r\n{{.title}}\r\n</p>\r\n", page)
  assert(out == "\r\n<p>\r\nt\r\n</p>\r\n", out)
  local text = render(tmp, "crlf-text", "{{type Page from data}}{{mode text}}\r\na\r\n{{- .title}}\r\n", page)
  assert(text == "\r\nat\r\n", text)
  local trouble = refused(tmp, "crlf-error", "{{type Page from data}}{{mode text}}\r\na\r\n{{.items}}\r\n")
  assert(trouble:find("page.tmpl:3:", 1, true), trouble)
end

local function test_a_repeated_attribute_is_judged_each_time(tmp: string)
  local page: {string: any} = { url = "javascript:x" }
  local out = render(tmp, "dup", HEAD .. '<a href="x" href="{{.url}}">', page)
  assert(out == '\n<a href="x" href="' .. esc_attr("about:invalid") .. '">', out)
end

--- A stage that counts its calls, and one that answers the count.
local COUNTER <const> = [[
local record counter
  calls: integer
  each: function(l: {string}): {string}
  count: function(s: string): string
end
counter.calls = 0
function counter.each(l: {string}): {string}
  counter.calls = counter.calls + 1
  return l
end
function counter.count(_: string): string
  return tostring(counter.calls)
end
return counter
]]

local function test_a_range_runs_its_else_when_the_list_is_empty_and_reads_the_list_once(tmp: string)
  local lua, trouble = build(tmp, "range-else", { ["data.tl"] = DATA, ["counter.tl"] = COUNTER,
    ["page.tmpl"] = HEAD .. "<ul>{{range .list | counter.each}}<li>{{.}}</li>{{else}}<p>{{.title}}</p>{{end}}</ul>" ..
      "{{.title | counter.count}}" })
  assert(lua ~= nil, trouble)
  local full = load_module(lua, "page")
  assert(full is Loaded, "page exports no render")
  local listed = full.render({ list = { "a", "<" }, title = "none" })
  assert(listed is Html.SafeHtml and Html.raw(listed) == "\n<ul><li>a</li><li>&lt;</li></ul>1", tostring(listed))
  local empty = load_module(lua, "page")
  assert(empty is Loaded, "page exports no render")
  local none = empty.render({ list = {}, title = "<none>" })
  assert(none is Html.SafeHtml and Html.raw(none) == "\n<ul><p>&lt;none&gt;</p></ul>1", tostring(none))
end

local function test_a_range_else_reads_the_enclosing_dot(tmp: string)
  local lua, trouble = project(tmp, "else-dot", HEAD ..
      "{{range .items}}{{.name}};{{else}}{{range .list}}{{.}}{{else}}{{.title}}{{end}}{{end}}")
  assert(lua ~= nil, trouble)
  local mod = load_module(lua, "page")
  assert(mod is Loaded, "page exports no render")
  for _, case in ipairs({
      { { items = { { name = "a", n = 1 }, { name = "b", n = 2 } } } as {string: any}, "\na;b;" },
      { { items = {}, list = { "x", "y" } } as {string: any}, "\nxy" },
      { { items = {}, list = {}, title = "t<" } as {string: any}, "\nt&lt;" },
  } as {{any}}) do
    local out = mod.render(case[1] as {string: any})
    assert(out is Html.SafeHtml and Html.raw(out) == case[2], tostring(case[2]))
  end
  local wrong = refused(tmp, "else-dot-wrong", HEAD .. "{{range .items}}{{.name}}\n{{else}}{{.name}}{{end}}")
  assert(wrong:find("page.tmpl:3:", 1, true) and wrong:find("name", 1, true), wrong)
end
