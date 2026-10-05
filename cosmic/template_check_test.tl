--- What a compiled template does under Teal's checker and when run: the
--- generated source of each template below is built, in a project of its
--- own in the temporary directory, with [`importer.compile`] (so a warning
--- is a refusal, as for any module of the tree), and then loaded and
--- called. An error names the template's own line.
---
--- `cosmic.html` is not on the tree's path yet, so the generated source's
--- `require("cosmic.html")` is pointed at `stubhtml`, a declaration of
--- the same names with userdata records as the real module's types, and a
--- Lua stand-in for it at run time.
--- TODO: once `cosmic.html` (with `href`) is in the tree, build the
--- generated source as it is and drop the stand-in.

local Fs = require("cosmic.fs")
local Template = require("cosmic.template")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

local STUB <const> = [[
local record html
  record SafeHtml userdata end
  record SafeAttr userdata end
  record SafeUrl userdata end
  escape: function(string): SafeHtml
  escape_attr: function(string): SafeAttr
  href: function(string): SafeUrl
  trust: function(string): SafeHtml
  raw: function(SafeHtml): string
  raw: function(SafeAttr): string
  raw: function(SafeUrl): string
end
return html
]]

local DATA <const> = [[
local stubhtml = require("stubhtml")
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
    h: stubhtml.SafeHtml
    a: stubhtml.SafeAttr
    u: stubhtml.SafeUrl
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
local record fmt
  upper: function(s: string): string
  bracket: function(s: string): string
  ["end"]: function(s: string): string
end
function fmt.upper(s: string): string
  return s:upper()
end
function fmt.bracket(s: string): string
  return "[" .. s .. "]"
end
fmt["end"] = fmt.bracket
return fmt
]]

--- Builds the project of `files` (paths to text) in the directory `case`
--- of `tmp`: the Lua of every module (by path), or nil and what refused.
local function build(tmp: string, case: string, files: {string: string}): {string: string} | nil, string
  local root = tmp .. "/" .. case
  assert(Fs.mkdirs(root))
  for name, text in pairs(files) do
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
  local out, why = Template.compile(template, "page.tmpl")
  if out == nil then
    return nil, why
  end
  local source = out:gsub('require%("cosmic%.html"%)', 'require("stubhtml")')
  return build(tmp, case, { ["stubhtml.d.tl"] = STUB, ["data.tl"] = DATA, ["fmt.tl"] = FMT,
    ["page.tl"] = source })
end

local function esc(s: string): string
  return (s:gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;",
    ["'"] = "&#39;" }))
end

--- The stand-in for `cosmic.html`: a safe value is a table holding its text.
local record Html
  escape: function(string): {string: string}
  escape_attr: function(string): {string: string}
  href: function(string): {string: string}
  trust: function(string): {string: string}
  raw: function({string: string}): string
end

local STAND_IN <const>: Html = {
  escape = function(s: string): {string: string} return { s = esc(s) } end,
  escape_attr = function(s: string): {string: string} return { s = esc(s) } end,
  href = function(s: string): {string: string}
    return { s = s:lower():find("^javascript:") and "about:invalid" or s }
  end,
  trust = function(s: string): {string: string} return { s = s } end,
  raw = function(v: {string: string}): string return v.s end,
}

--- The module `path` of `lua`, loaded with the stand-in for `cosmic.html`.
local function load_module(lua: {string: string}, path: string): any
  local loaded: {string: any} = {}
  local function req(name: string): any
    if name == "stubhtml" then
      return STAND_IN
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
  if out is {string: string} then
    return out.s
  end
  assert(out is string, "render answered a " .. type(out))
  return out
end

--- What building `template` refuses with, which it must. It is built
--- twice and the second refusal answered: when the checker compiles the
--- module that declares a type in the same run that finds the mismatch,
--- it reports the mismatch where that type was declared, in the wrong
--- file; with the module's compile cached, as it is the second time, it
--- reports the slot.
--- TODO: once the checker names the slot on a cold compile too (it names
--- the declaration of the field's type), take the first refusal.
local function refused(tmp: string, case: string, template: string): string
  local first, cold = project(tmp, case, template)
  assert(first == nil, "built: " .. tostring(cold))
  local lua, trouble = project(tmp, case, template)
  assert(lua == nil, "built the second time")
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
  assert(trouble:find("page.tl:4:", 1, true), trouble)
  assert(trouble:find("string | number", 1, true), trouble)
  local multi = refused(tmp, "multi", "{{type Page from data}}{{mode text}}\n{{.title\n  | fmt.upper}}\n{{.items}}")
  assert(multi:find("page.tl:4:", 1, true) and not multi:find("page.tl:2:", 1, true), multi)
end

local function test_a_slot_takes_what_its_place_accepts(tmp: string)
  local lua, trouble = project(tmp, "accepts", HEAD .. [[
<h1 class="{{.cls}}" title='{{.a}}'>{{.title}} {{.n}} {{.h}} {{.cls | fmt.upper}}</h1>
<a href="{{.url}}">{{.user.name}}</a><a href="{{.u}}"></a><a href=" {{.url | fmt.bracket}}">x</a>
{{range .items}}<i title="{{.n}}">{{.name}}</i>{{else}}{{end}}
]])
  assert(lua == nil and trouble:find("{{else}} in a {{range}}", 1, true), tostring(trouble))
  local ok, why = project(tmp, "accepts", HEAD .. [[
<h1 class="{{.cls}}" title='{{.a}}'>{{.title}} {{.n}} {{.h}} {{.cls | fmt.upper}}</h1>
<a href="{{.url}}">{{.user.name}}</a><a href="{{.u}}"></a><a href="{{.url | fmt.bracket}}">x</a>
{{range .items}}<i title="{{.n}}">{{.name}}</i>{{end}}
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
    assert(trouble:find("page.tl:3:", 1, true), case[1] .. ": " .. trouble)
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
  assert(trouble:find("page.tl:5:", 1, true), trouble)
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
    h = STAND_IN.trust("<b>x</b>"), a = STAND_IN.escape_attr("q&r"), u = STAND_IN.href("/x"), user = { name = "<u>" },
    items = { { name = "p", n = 1 }, { name = "<q>", n = 2 } } }
  local out = render(tmp, "html-run", HEAD .. [[
<h1 class="{{.cls}}" title='{{.a}}'>{{.title}} {{.n}} {{.h}}</h1>
<a href="{{.url}}">{{.user.name}}</a> <a href='{{.u}}'></a>
{{range .items}}<i title="{{.n}}">{{.name}}</i>{{end}}
]], page)
  assert(out == '\n<h1 class="a&quot;b&#39;c" title=\'q&amp;r\'>&lt;i&gt;&amp; 7 <b>x</b></h1>\n' ..
      '<a href="about:invalid">&lt;u&gt;</a> <a href=\'/x\'></a>\n' ..
      '<i title="1">p</i><i title="2">&lt;q&gt;</i>\n', out)
  page.url = "/a?x=1&y=2"
  local second = render(tmp, "html-run2", HEAD .. '<a href="{{.url}}">', page)
  assert(second == '\n<a href="/a?x=1&amp;y=2">', second)
end
