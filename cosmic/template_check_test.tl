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

local built = assert(teal.load())

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
  record Leaf
    x: string
  end
  record Mid
    c: string
    e: Leaf | nil
  end
  record Outer
    b: Mid | nil
    c: string
    s: string | nil
  end
  record Page
    title: string
    cls: string
    n: integer
    url: string
    h: html.SafeHtml
    a: html.SafeAttr
    u: html.SafeUrl
    p: html.SafeUrlPart
    j: html.SafeJson
    items: {Item}
    user: User
    owner: User | nil
    nest: Outer | nil
    error: string | nil
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
  pair: function(s: string): string, string
  join: function(s: string, sep?: string): string
  spread: function(s: string): string...
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
function fmt.pair(s: string): string, string
  return s, "second"
end
function fmt.spread(s: string): string...
  return s, "second"
end
function fmt.join(s: string, sep?: string): string
  return s .. "|" .. (sep or "none")
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
<a href="/i/{{.title}}/{{.n}}?{{.p}}&q={{.cls}}#{{.p}}">x</a>
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

local function test_a_part_slot_given_what_its_place_refuses_is_a_type_error_on_its_line(tmp: string)
  -- One build: each wrong slot is its own error, on its own line. A
  -- whole URL is not a part, nor is attribute or markup text.
  local trouble = refused(tmp, "wrong-part", HEAD .. "ok\n<a href=\"/a/{{.u}}\">\n<a href=\"/a/{{.h}}\">\n" ..
      "<a href=\"/a/{{.items}}\">\n<a href=\"/a/{{.a}}\">\n")
  for line, want in pairs({ [3] = "SafeUrl", [4] = "SafeHtml", [5] = "{Item}", [6] = "SafeAttr" }) do
    local at = trouble:find("page.tmpl:" .. line .. ":", 1, true)
    assert(at ~= nil, "no error on line " .. line .. ": " .. trouble)
    assert(trouble:find(want, at, true), "line " .. line .. " is not " .. want .. ": " .. trouble)
  end
end

local USE <const> = "{{type Page from data}}{{use htmx}}\n"

local function test_a_json_slot_takes_only_a_safejson_and_a_selector_slot_a_string_or_a_number(tmp: string)
  local ok, why = project(tmp, "htmx-accepts", USE ..
      "<a hx-vals='{{.j}}' hx-target=\"#a-{{.title}}-{{.n}}\" hx-get=\"{{.u}}\" hx-post=\"{{.url}}\">x</a>\n")
  assert(ok ~= nil, why)
  -- One build: each wrong slot is its own error, on its own line.
  local trouble = refused(tmp, "htmx-wrong", USE .. "ok\n<a hx-vals='{{.title}}'>\n<a hx-headers=\"{{.items}}\">\n" ..
      "<a hx-request='{{.url}}'>\n<a hx-vals='{{.a}}'>\n<a hx-target=\"#{{.u}}\">\n<a hx-target=\"#{{.items}}\">\n" ..
      "<a hx-target=\"#{{.a}}\">\n<a hx-get=\"{{.n}}\">\n<a hx-get=\"{{.p}}\">\n<a hx-get=\"/x/{{.u}}\">\n")
  for line, want in pairs({ [3] = "SafeJson", [4] = "SafeJson", [5] = "SafeJson", [6] = "SafeJson",
      [7] = "SafeUrl", [8] = "{Item}", [9] = "SafeAttr", [10] = "integer", [11] = "SafeUrlPart", [12] = "SafeUrl" }) do
    local at = trouble:find("page.tmpl:" .. line .. ":", 1, true)
    assert(at ~= nil, "no error on line " .. line .. ": " .. trouble)
    assert(trouble:find(want, at, true), "line " .. line .. " is not " .. want .. ": " .. trouble)
  end
  -- Not a type error: the same templates without the dialect read as plain attributes.
  assert(project(tmp, "htmx-plain", HEAD .. "<a title='{{.title}}'>\n"))
end

local function test_a_json_slot_renders_attribute_safe_json_for_either_quote(tmp: string)
  local json = assert(Html.json({ id = 7, kind = "<b>\"q\" & 'a'</b>", ["js:x"] = { "javascript:" } }))
  local page: {string: any} = { j = json }
  local text = Html.raw_json(json)
  for _, quote in ipairs({ '"', "'" }) do
    local out = render(tmp, "json-" .. (quote == '"' and "dq" or "sq"), USE ..
        "<a hx-vals=" .. quote .. "{{.j}}" .. quote .. " hx-headers=" .. quote .. "{{.j}}" .. quote .. ">", page)
    local value = out:match("hx%-vals=" .. quote .. "([^" .. quote .. "]*)" .. quote)
    assert(value ~= nil and not value:find("[<>]") and not value:find(quote, 1, true), out)
    local read = value:gsub("&(%a+);", { quot = '"', amp = "&", lt = "<", gt = ">" }):gsub("&#39;", "'")
    assert(read == text, out)
    assert(out:find("hx%-headers=" .. quote .. value:gsub("%p", "%%%0") .. quote), out)
  end
end

--- The value of the attribute `name` in `out`, as a browser reads it.
local function attribute(out: string, name: string): string
  local value = out:match(name:gsub("%p", "%%%0") .. "=[\"']([^\"']*)[\"']")
  assert(value ~= nil, "no " .. name .. " in " .. out)
  local named: {string: string} = { quot = '"', amp = "&", lt = "<", gt = ">" }
  return (value:gsub("&#(%d+);", function(n: string): string
    return string.char(tonumber(n) as integer)
  end):gsub("&(%a+);", named))
end

local function test_a_request_url_slot_is_checked_as_a_same_origin_reference(tmp: string)
  local template = USE .. "<a hx-get=\"{{.url}}\" href=\"{{.url}}\" hx-push-url=\"{{.u}}\">"
  local cases: {{string}} = {
    { "/items/7?x=1", "/items/7?x=1" },
    { "items", "items" },
    { "true", "true" },
    { "//evil.example/x", "about:invalid" },
    { "\\\\evil.example", "about:invalid" },
    { "https://evil.example/x", "about:invalid" },
    { "javascript:alert(1)", "about:invalid" },
    { "java\tscript:alert(1)", "about:invalid" },
    { " /x", "about:invalid" },
    { "mailto:a@b.example", "about:invalid" },
  }
  for index, case in ipairs(cases) do
    local out = render(tmp, "local-" .. index, template, { url = case[1], u = Html.trust_url("https://example.com/a") })
    assert(attribute(out, "hx-get") == case[2], case[1] .. ": " .. out)
    -- A SafeUrl is the author's: it passes as it is.
    assert(attribute(out, "hx-push-url") == "https://example.com/a", out)
  end
  -- An href beside it still lets a web URL through: only hx-get is local.
  local out = render(tmp, "local-href", template, { url = "https://ok.example/", u = Html.trust_url("/p") })
  assert(attribute(out, "hx-get") == "about:invalid" and attribute(out, "href") == "https://ok.example/", out)
end

local function test_a_url_part_in_an_htmx_attribute_is_escaped_as_in_an_href(tmp: string)
  local out = render(tmp, "htmx-part", USE .. "<a hx-delete=\"/i/{{.title}}/{{.n}}?q={{.cls}}\">",
    { title = "a/b ?#", n = 7, cls = "x&y=z" })
  assert(attribute(out, "hx-delete") == "/i/a%2Fb%20%3F%23/7?q=x%26y%3Dz", out)
end

local function test_a_selector_slot_is_escaped_as_css_identifier_text(tmp: string)
  local out = render(tmp, "selector", USE ..
      "<a hx-target=\"#row-{{.title}}\" hx-select='.c-{{.cls}} p' hx-sync=\"#f-{{.n}}:abort\">",
    { title = "x, body", n = 12, cls = "a'b\"c>d" })
  assert(attribute(out, "hx-target") == "#row-x\\2c \\20 body", out)
  assert(attribute(out, "hx-select") == ".c-a\\27 b\\22 c\\3e d p", out)
  -- A number is over-escaped at the start of its text, which selects the same.
  assert(attribute(out, "hx-sync") == "#f-\\31 2:abort", out)
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

--- A field that may be nil is tested by an `{{if}}` and read in its arm: the
--- test narrows only a local, so the arm reads what the test bound. It builds,
--- and renders as it would if the field were read each time.
local function test_a_tested_optional_field_is_read_inside_its_arm_as_a_local(tmp: string)
  local template = HEAD .. "{{if .error}}<p>{{.error}}</p>{{end}}" ..
    "{{if .flag}}F{{else if .error}}<i>{{.error}}</i>{{else if .owner}}{{.owner.name}}{{else}}none{{end}}" ..
    "{{if .owner}}{{if .owner}}{{.owner.name}}{{end}}{{end}}"
  local function shown(case: string, page: {string: any}): string
    return (render(tmp, case, template, page):gsub("^%s+", ""))
  end
  local both = shown("optional-both", { error = "<b>", owner = { name = "n" }, flag = false })
  assert(both == "<p>&lt;b&gt;</p><i>&lt;b&gt;</i>n", both)
  assert(shown("optional-owner", { owner = { name = "o" } }) == "oo", "owner")
  assert(shown("optional-none", {}) == "none", "none")
  assert(shown("optional-flag", { flag = true, error = "e" }) == "<p>e</p>F", "flag")
end

--- A test inside a test of a prefix of its path: each path is bound to its own
--- local, and a read of a path reads the local of the longest prefix bound.
local function test_guards_on_nested_prefixes_build_and_render(tmp: string)
  local function shown(case: string, template: string, page: {string: any}): string
    return (render(tmp, case, HEAD .. template, page):gsub("^%s+", ""))
  end
  local full = { nest = { b = { c = "B", e = { x = "X" } }, c = "C", s = "S" } }
  -- Two deep, and a sibling path read inside the inner block.
  local two = "{{if .nest}}{{if .nest.b}}{{.nest.b.c}}{{.nest.c}}{{end}}{{end}}"
  assert(shown("nest-two", two, full) == "BC", "two")
  assert(shown("nest-two-nob", two, { nest = { c = "C" } }) == "", "two, no b")
  assert(shown("nest-two-none", two, {}) == "", "two, none")
  -- Three deep.
  local three = "{{if .nest}}{{if .nest.b}}{{if .nest.b.e}}{{.nest.b.e.x}}{{end}}{{end}}{{end}}"
  assert(shown("nest-three", three, full) == "X", "three")
  assert(shown("nest-three-noe", three, { nest = { b = { c = "B" }, c = "C" } }) == "", "three, no e")
  -- The tested path read again under the same name.
  local same = "{{if .nest}}{{if .nest.s}}{{.nest.s}}{{end}}{{end}}"
  assert(shown("nest-same", same, full) == "S", "same")
  assert(shown("nest-same-nos", same, { nest = { c = "C" } }) == "", "same, no s")
  -- An inner test of a path already bound, with an `else`.
  local twice = "{{if .nest}}{{if .nest}}x{{else}}y{{end}}{{if .nest.s}}{{.nest.s}}{{else}}-{{end}}{{end}}"
  assert(shown("nest-twice", twice, full) == "xS", "twice")
  assert(shown("nest-twice-nos", twice, { nest = { c = "C" } }) == "x-", "twice, no s")
  -- In an arm of a chain, and a range over a bound path's field.
  local chain = "{{if .flag}}F{{else if .nest}}{{if .nest.b}}{{.nest.b.c}}{{else}}-{{end}}{{.nest.c}}{{else}}none{{end}}"
  assert(shown("nest-chain", chain, full) == "BC", "chain")
  assert(shown("nest-chain-nob", chain, { nest = { c = "C" } }) == "-C", "chain, no b")
  assert(shown("nest-chain-none", chain, {}) == "none", "chain, none")
end

--- A chain of many arms builds: it is flat, so what the checker nests grows
--- with none of them.
local function test_a_chain_of_three_hundred_arms_builds_and_renders(tmp: string)
  local arms: {string} = { "{{if .flag}}F" }
  for arm = 1, 300 do
    arms[#arms + 1] = (arm % 2 == 0 and "{{else if .error}}e" or "{{else if .owner}}o") .. arm
  end
  arms[#arms + 1] = "{{else}}none{{end}}"
  local template = HEAD .. table.concat(arms)
  assert((render(tmp, "arms-none", template, {}):gsub("^%s+", "")) == "none", "none")
  assert((render(tmp, "arms-flag", template, { flag = true }):gsub("^%s+", "")) == "F", "flag")
  assert((render(tmp, "arms-owner", template, { owner = { name = "n" } }):gsub("^%s+", "")) == "o1", "owner")
  assert((render(tmp, "arms-error", template, { error = "x" }):gsub("^%s+", "")) == "e2", "error")
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
    p = assert(Html.url_query({ { "a b", "c&d" }, { "e", ".." } })),
    items = { { name = "p", n = 1 }, { name = "<q>", n = 2 } } }
  local out = render(tmp, "html-run", HEAD .. [[
<h1 class="{{.cls}}" title='{{.a}}'>{{.title}} {{.n}} {{.h}}</h1>
<a href="{{.url}}">{{.user.name}}</a> <a href='{{.u}}'></a>
<a href="/i/{{.title}}/{{.n}}?{{.p}}&q={{.cls}}">x</a><a href='mailto:{{.title}}'>y</a>
{{range .items}}<i title="{{.n}}">{{.name}}</i>{{end}}
]], page)
  assert(out == '\n<h1 class="a&#34;b&#39;c" title=\'q&#38;r\'>&lt;i&gt;&amp; 7 <b>x</b></h1>\n' ..
      '<a href="' .. esc_attr("about:invalid") .. '">&lt;u&gt;</a> <a href=\'' .. esc_attr("/x") .. '\'></a>\n' ..
      '<a href="/i/%3Ci%3E%26/7?a%20b=c%26d&amp;e=..&q=a%22b%27c">x</a>' ..
      '<a href=\'mailto:%3Ci%3E%26\'>y</a>\n' ..
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

--- A template that holds an `<img onerror>` in the RCDATA of a `<title>`,
--- as its own checks allow.
local TITLED <const> = HEAD .. '<title><img src=x onerror="{{.title}}"></title>'

local function test_markup_from_another_template_is_a_type_error_inside_svg_math_and_select(tmp: string)
  -- In `<svg>` a `<title>` is an integration point, so the `<img>` in it
  -- would be an element whose `onerror` runs; in `<select>` a classic
  -- parser reads it so too.
  for index, outer in ipairs({ "<svg>{{. | inner.render}}</svg>", "<math>{{. | inner.render}}</math>",
      "<select>{{. | inner.render}}</select>", "<svg><g>{{.h}}</g></svg>" }) do
    local lua, trouble = build(tmp, "foreign" .. index, { ["data.tl"] = DATA, ["inner.tmpl"] = TITLED,
      ["page.tmpl"] = HEAD .. "ok\n" .. outer })
    assert(lua == nil, outer .. ": built")
    assert(trouble:find("page.tmpl:3:", 1, true) and trouble:find("SafeHtml", 1, true), outer .. ": " .. trouble)
  end
  local page: {string: any} = { title = "<b>&", n = 2 }
  local out = render(tmp, "foreign-text", HEAD ..
      "<svg><text>{{.title}} {{.n}}</text></svg><math>{{.title}}</math><select><option>{{.title}}</option></select>",
    page)
  assert(out == "\n<svg><text>&lt;b&gt;&amp; 2</text></svg><math>&lt;b&gt;&amp;</math>" ..
      "<select><option>&lt;b&gt;&amp;</option></select>", out)
end

local function test_markup_from_another_template_goes_into_text_outside_svg_math_and_select(tmp: string)
  local lua, trouble = build(tmp, "composed", { ["data.tl"] = DATA, ["inner.tmpl"] = TITLED,
    ["page.tmpl"] = HEAD .. "<p>{{. | inner.render}}</p><svg></svg><select></select>{{. | inner.render}}" })
  assert(lua ~= nil, trouble)
  local mod = load_module(lua, "page")
  assert(mod is Loaded, "page exports no render")
  local made = mod.render({ title = "a\"b" })
  assert(made is Html.SafeHtml, "render answered a " .. type(made))
  local inner = '\n<title><img src=x onerror="a&quot;b"></title>'
  assert(Html.raw(made) == "\n<p>" .. inner .. "</p><svg></svg><select></select>" .. inner, Html.raw(made))
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

local function test_a_block_that_adds_a_bare_attribute_renders_it_only_when_its_condition_holds(tmp: string)
  local lua, trouble = project(tmp, "bare", HEAD ..
      '<input type="checkbox"{{if .flag}} checked{{end}} name="a"><input{{if .flag}} disabled{{end}}>\n' ..
      '<option {{if .flag}}selected {{end}}value="{{.cls}}">x</option><br{{if .flag}} hidden{{end}}/>\n' ..
      '<input{{if .flag}} required{{else}} readonly{{end}} name="b">')
  assert(lua ~= nil, trouble)
  local mod = load_module(lua, "page")
  assert(mod is Loaded, "page exports no render")
  local on_made = mod.render({ flag = true, cls = "c\"" })
  assert(on_made is Html.SafeHtml, "render answered a " .. type(on_made))
  local on = Html.raw(on_made)
  assert(on == '\n<input type="checkbox" checked name="a"><input disabled>\n' ..
      '<option selected value="c&#34;">x</option><br hidden/>\n<input required name="b">', on)
  local off_made = mod.render({ flag = false, cls = "c\"" })
  assert(off_made is Html.SafeHtml, "render answered a " .. type(off_made))
  local off = Html.raw(off_made)
  assert(off == '\n<input type="checkbox" name="a"><input>\n' ..
      '<option value="c&#34;">x</option><br/>\n<input readonly name="b">', off)
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

local function test_a_stage_answering_more_than_one_value_is_refused_in_every_position(tmp: string)
  for index, action in ipairs({ "{{.title | fmt.pair}}", "{{.title | fmt.pair | fmt.join}}",
      "{{.title | fmt.pair | fmt.upper}}", "{{if .title | fmt.pair}}x{{end}}",
      "{{with .title | fmt.pair}}{{.}}{{end}}", "{{range .title | fmt.pair}}x{{end}}" }) do
    local trouble = refused(tmp, "pair-" .. index, "{{type Page from data}}{{mode text}}\nfine\n" .. action)
    assert(trouble:find("page.tmpl:3:", 1, true), action .. ": " .. trouble)
    assert(trouble:find("wrong number of arguments", 1, true), action .. ": " .. trouble)
  end
end

--- The checker lets a stage declared to answer `string...` through, so
--- what holds it to one value at run time is the generated code.
local function test_a_stage_is_given_one_value_when_the_one_before_answers_more(tmp: string)
  local out = render(tmp, "spread",
    "{{type Page from data}}{{mode text}}{{.title | fmt.spread | fmt.join}} {{.title | fmt.upper | fmt.join}}",
    { title = "a" })
  assert(out == "a|none A|none", out)
end

--- What the module built from `template` renders for each page of `pages`.
local function renders(tmp: string, case: string, template: string, pages: {{string: any}}): {string}
  local lua, trouble = project(tmp, case, template)
  assert(lua ~= nil, trouble)
  local mod = load_module(lua, "page")
  assert(mod is Loaded, "page exports no render")
  local outs: {string} = {}
  for _, page in ipairs(pages) do
    local out = mod.render(page)
    if out is Html.SafeHtml then
      outs[#outs + 1] = Html.raw(out)
    else
      assert(out is string, "render answered a " .. type(out))
      outs[#outs + 1] = out
    end
  end
  return outs
end

local function test_an_item_loop_reads_the_root_and_a_1_based_index(tmp: string)
  local page: {string: any} = { title = "<t>", items = { { name = "a", n = 1 }, { name = "b&", n = 2 } } }
  local out = render(tmp, "root-index", HEAD ..
      "{{range $i, $x := .items}}<p title=\"{{$.title}}\">{{$i}}:{{$x.name}}/{{.n}} of {{$.title}}</p>{{end}}", page)
  local title = esc_attr("<t>")
  assert(out == '\n<p title="' .. title .. '">1:a/1 of &lt;t&gt;</p><p title="' .. title .. '">2:b&amp;/2 of &lt;t&gt;</p>',
    out)
end

local function test_the_index_is_an_integer_to_the_checker(tmp: string)
  local trouble = refused(tmp, "index-integer", HEAD .. "ok\n{{range $i, $x := .items}}{{$i | fmt.upper}}{{end}}")
  assert(trouble:find("page.tmpl:3:", 1, true) and trouble:find("integer", 1, true), trouble)
end

local function test_nested_ranges_read_the_outer_element_index_and_root(tmp: string)
  local page: {string: any} = { title = "T", items = { { name = "a", n = 1 }, { name = "b", n = 2 } },
    list = { "x", "y" } }
  local out = render(tmp, "nested-bindings", "{{type Page from data}}{{mode text}}" ..
      "{{range $i, $x := .items}}{{range $j, $s := $.list}}{{$i}}.{{$j}}={{$x.name}}{{$s}}{{.}}{{$.title}} {{end}}{{end}}",
    page)
  assert(out == "1.1=axxT 1.2=ayyT 2.1=bxxT 2.2=byyT ", out)
end

local function test_with_keeps_the_root_and_the_enclosing_bindings(tmp: string)
  local outs = renders(tmp, "with-bindings", "{{type Page from data}}{{mode text}}" ..
      "{{range $i, $x := .items}}{{with $.user}}{{.name}}{{$x.name}}{{$i}}{{$.title}}{{else}}-{{$x.n}}{{end}};{{end}}", {
        { title = "T", user = { name = "u" }, items = { { name = "a", n = 1 }, { name = "b", n = 2 } } },
        { title = "T", items = { { name = "a", n = 1 } } },
      })
  assert(outs[1] == "ua1T;ub2T;", outs[1])
  assert(outs[2] == "-1;", outs[2])
end

local function test_a_misspelled_field_after_a_variable_is_a_type_error_on_its_line(tmp: string)
  local trouble = refused(tmp, "binding-typo", HEAD .. "{{range $x := .items}}\n{{$x.nmae}}{{end}}")
  assert(trouble:find("page.tmpl:3:", 1, true) and trouble:find("nmae", 1, true), trouble)
  local root = refused(tmp, "root-typo", HEAD .. "{{range .items}}\n\n{{$.titel}}{{end}}")
  assert(root:find("page.tmpl:4:", 1, true) and root:find("titel", 1, true), root)
end

local function test_a_binding_named_like_a_generated_name_or_a_module_builds_and_renders(tmp: string)
  local names = { "html", "d", "d1", "v", "parts", "render", "_one", "_text", "T", "fmt", "data", "end", "table" }
  local body: {string} = {}
  for _, name in ipairs(names) do
    body[#body + 1] = "{{range $i, $" .. name .. " := .items}}{{$" .. name .. ".name | fmt.upper}}{{$i}}{{end}}"
  end
  local out = render(tmp, "binding-names", HEAD .. table.concat(body) .. "{{.title | fmt.bracket}}",
    { title = "t", items = { { name = "a", n = 1 } } })
  assert(out == "\n" .. string.rep("A1", #names) .. "[t]", out)
end

local function test_a_range_with_bindings_reads_its_list_once(tmp: string)
  local lua, trouble = build(tmp, "bindings-once", { ["data.tl"] = DATA, ["counter.tl"] = COUNTER,
    ["page.tmpl"] = "{{type Page from data}}{{mode text}}" ..
      "{{range $i, $s := .list | counter.each}}{{$i}}{{$s}}{{else}}none{{end}}|" ..
      "{{range $i, $s := .list | counter.each}}{{$i}}{{$s}}{{end}}|" ..
      "{{with $.list | counter.each}}{{range $s := .}}{{$s}}{{end}}{{end}}|{{.title | counter.count}}" })
  assert(lua ~= nil, trouble)
  local mod = load_module(lua, "page")
  assert(mod is Loaded, "page exports no render")
  local out = mod.render({ list = { "a", "b" }, title = "" })
  assert(out == "1a2b|1a2b|ab|3", tostring(out))
end
