--- A `.tmpl` file is a module the build makes ([`build.derivation`]): its
--- import path is its path's, a refusal and a type error name the file's
--- own line, and an edit to it makes the module again. Each test writes a
--- small project into the temporary directory and compiles it with
--- [`importer.compile`], as the build does for any project.

local Fs = require("cosmic.fs")
local Html = require("cosmic.html")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")
local profile_page = require("test.profile_page")
local sample = require("test.profile_page_sample")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

local DATA <const> = [[
local html = require("cosmic.html")
local record data
  record Page
    title: string
    h: html.SafeHtml
    url: string
  end
end
return data
]]

--- Writes `files` (paths to text) under `root`.
local function write(root: string, files: {string: string})
  for name, text in pairs(files) do
    local dir = name:match("^(.*)/[^/]*$")
    if dir ~= nil then
      assert(Fs.mkdirs(root .. "/" .. dir))
    end
    assert(Fs.write(root .. "/" .. name, text))
  end
end

--- Stages and compiles the project at `root`: the Lua of each module by
--- import path, or nil and what refused.
local function compile(root: string): {string: string} | nil, string
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return nil, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, false)
  if staged == nil then
    local _, _ = work.close(handle)
    return nil, stage_trouble
  end
  local result, trouble = importer.compile(handle, built, "template-build-test")
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

--- Writes `files` to the fresh project `case` of `tmp` and compiles it.
local function project(tmp: string, case: string, files: {string: string}): {string: string} | nil, string
  local root = tmp .. "/" .. case
  assert(Fs.mkdirs(root))
  write(root, files)
  return compile(root)
end

--- The module `path` of `lua`, run against the real [`cosmic.html`].
local function load_module(lua: {string: string}, path: string): any
  local loaded: {string: any} = {}
  local function req(name: string): any
    if name == "cosmic.html" then
      return Html
    end
    if loaded[name] == nil then
      local env: {string: any} = setmetatable({}, { __index = _G })
      env.require = req
      local chunk = assert(load(assert(lua[name], "no module " .. name), "=" .. name, "t", env))
      loaded[name] = chunk()
    end
    return loaded[name]
  end
  return req(path)
end

local record Loaded
  render: function({string: any}): any
end

--- What module `path` of `lua` renders `page` to.
local function rendered(lua: {string: string}, path: string, page: {string: any}): string
  local mod = load_module(lua, path)
  assert(mod is Loaded, path .. " exports no render")
  return Html.raw(mod.render(page) as Html.SafeHtml)
end

local HEAD <const> = "{{type Page from data}}\n"

local function test_a_template_and_its_data_build_and_render(tmp: string)
  local lua, trouble = project(tmp, "ok", { ["data.tl"] = DATA,
    ["page.tmpl"] = HEAD .. '<h1>{{.title}}</h1>{{.h}}<a href="{{.url}}">x</a>\n' })
  assert(lua ~= nil, trouble)
  local out = rendered(lua, "page", { title = "a<b", h = Html.trust("<i>"), url = "/x" })
  assert(out == '\n<h1>a&lt;b</h1><i><a href="' .. Html.raw_attr(Html.escape_attr("/x")) .. '">x</a>\n', out)
end

local function test_a_slot_of_the_wrong_safe_type_is_an_error_on_the_templates_line(tmp: string)
  local lua, trouble = project(tmp, "wrong", { ["data.tl"] = DATA,
    ["page.tmpl"] = HEAD .. "<p>fine</p>\n<a href=\"{{.h}}\">x</a>\n" })
  assert(lua == nil, "built a SafeHtml into a URL")
  assert(trouble:find("page.tmpl:3:", 1, true), trouble)
  assert(trouble:find("SafeHtml", 1, true), trouble)
  assert(not trouble:find("page.tl", 1, true), trouble)
end

local function test_a_template_refused_names_its_line_and_column(tmp: string)
  local lua, trouble = project(tmp, "syntax", { ["data.tl"] = DATA,
    ["page.tmpl"] = HEAD .. "<a href={{.url}}>x</a>\n" })
  assert(lua == nil, "built an unquoted slot")
  assert(trouble:find("page.tmpl:2:9:", 1, true), trouble)
end

local function test_an_init_template_is_its_directory_and_a_sibling_is_a_member(tmp: string)
  local lua, trouble = project(tmp, "dirs", {
    ["pages/data.tl"] = DATA,
    ["pages/init.tmpl"] = "{{type Page from pages.data}}{{mode text}}index {{.title}}",
    ["pages/home.tmpl"] = "{{type Page from pages.data}}{{mode text}}home {{.title}}",
    ["main.tl"] = 'local index = require("pages")\nreturn index\n',
  })
  assert(lua ~= nil, trouble)
  local mod = load_module(lua, "pages")
  assert(mod is Loaded, "pages exports no render")
  assert(mod.render({ title = "t" }) == "index t")
  local home = load_module(lua, "pages.home")
  assert(home is Loaded, "pages.home exports no render")
  assert(home.render({ title = "t" }) == "home t")
end

local function test_a_template_beside_an_init_template_is_private_to_its_directory(tmp: string)
  local lua, trouble = project(tmp, "private", {
    ["pages/data.tl"] = DATA,
    ["pages/init.tmpl"] = "{{type Page from pages.data}}{{mode text}}index",
    ["pages/home.tmpl"] = "{{type Page from pages.data}}{{mode text}}home",
    ["main.tl"] = 'local home = require("pages.home")\nreturn home\n',
  })
  assert(lua == nil, "required a member of a closed directory")
  assert(trouble:find("pages.home is private to pages/", 1, true), trouble)
end

local function test_a_template_and_a_teal_file_at_one_import_path_are_refused(tmp: string)
  local lua, trouble = project(tmp, "twice", { ["data.tl"] = DATA,
    ["page.tmpl"] = HEAD .. "x", ["page.tl"] = "return {}\n" })
  assert(lua == nil, "built two files at one import path")
  assert(trouble:find("page.tmpl", 1, true) and trouble:find("page.tl", 1, true) and
      trouble:find("import path 'page'", 1, true), trouble)
  local dir, dir_trouble = project(tmp, "twice-dir", { ["data.tl"] = DATA,
    ["pages/init.tmpl"] = HEAD .. "x", ["pages.tl"] = "return {}\n" })
  assert(dir == nil and dir_trouble:find("import path 'pages'", 1, true), tostring(dir_trouble))
end

local function test_editing_a_template_makes_its_module_again(tmp: string)
  local root = tmp .. "/edit"
  assert(Fs.mkdirs(root))
  write(root, { ["data.tl"] = DATA, ["page.tmpl"] = "{{type Page from data}}{{mode text}}one {{.title}}" })
  local first, first_trouble = compile(root)
  assert(first ~= nil, first_trouble)
  local once = load_module(first, "page")
  assert(once is Loaded and once.render({ title = "t" }) == "one t")
  write(root, { ["page.tmpl"] = "{{type Page from data}}{{mode text}}two {{.title}}!" })
  local second, second_trouble = compile(root)
  assert(second ~= nil, second_trouble)
  local mod = load_module(second, "page")
  assert(mod is Loaded)
  assert(mod.render({ title = "t" }) == "two t!", tostring(mod.render({ title = "t" })))
  write(root, { ["page.tmpl"] = "{{type Page from data}}{{mode text}}{{.nope}}" })
  local third, third_trouble = compile(root)
  assert(third == nil and third_trouble:find("page.tmpl:1:", 1, true), tostring(third_trouble))
end

local function test_the_template_compiler_is_part_of_what_a_derivation_is_keyed_by()
  local modules = assert(importer.analyzer_modules())
  local named: {string: boolean} = {}
  for _, name in ipairs(modules) do named[name] = true end
  for _, name in ipairs({ "cosmic.template", "cosmic.template.codegen", "cosmic.template.parse" }) do
    assert(named[name], name .. " is not in the analyzer's identity: " .. table.concat(modules, ", "))
  end
end

--- What the checker said about the field a template's slot reads, built
--- from nothing: a project with nothing cached.
local function test_a_cold_build_names_the_slot_not_the_declaration(tmp: string)
  local lua, trouble = project(tmp, "cold", { ["data.tl"] = DATA,
    ["page.tmpl"] = HEAD .. "ok\n<p>{{.h}}</p><a href=\"{{.h}}\">x</a>\n" })
  assert(lua == nil, "built a SafeHtml into a URL")
  assert(trouble:find("page.tmpl:3:", 1, true), trouble)
  assert(not trouble:find("data.tl", 1, true), trouble)
end

local function test_a_template_of_the_tree_is_a_module_the_tree_requires()
  local out = Html.raw(profile_page.render(sample.profile("Ada <3", "javascript:alert(1)")))
  assert(out:find("<h1>Ada &lt;3</h1>", 1, true), out)
  assert(out:find(Html.raw_attr(Html.escape_attr("about:invalid")), 1, true), out)
  assert(out:find(Html.raw_attr(Html.escape_attr("/home")), 1, true), out)
  assert(not out:find("javascript", 1, true), out)
end
