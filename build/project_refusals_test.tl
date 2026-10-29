--- Tests of [`build.project_refusals`]: what a project's program may not say, each case with the near miss that is let through.
--- A `require` by a computed name or with a string for its argument does not parse, so the check meets only the literal call.
local Pipeline = require("build.pipeline")
local ProjectRefusals = require("build.project_refusals")
local Node = require("build.syntax_node")
local Scopes = require("lang.scopes")
local Test = require("cosmic.test")

Test.policy{}

--- What `source` is told, as the lines of the check, with no declared globals: a use of one is a global all the same.
local function told(source: string): {string}
  local chunk, why = Node.parse(source, "p.tl")
  assert(chunk ~= nil, why)
  return ProjectRefusals.check("p.tl", chunk, Scopes.build(chunk, "p.tl", {}))
end

--- That `source` is told exactly once, on `line`, and the line says `words`.
local function refused(source: string, line: integer, words: string)
  local found = told(source)
  assert(#found == 1, source .. "\n" .. table.concat(found, "\n"))
  local only = assert(found[1])
  assert(only:find("^p%.tl:" .. tostring(line) .. ":%d+: ") ~= nil and only:find(words, 1, true) ~= nil, only)
end

--- That `source` is told nothing.
local function accepted(source: string)
  local found = told(source)
  assert(#found == 0, source .. "\n" .. table.concat(found, "\n"))
end

local function test_a_require_of_a_module_under_cosmic_internal_is_refused()
  refused("local g = require(\"cosmic.internal.globals\")\nreturn g\n", 1, "cosmic.internal.globals")
  refused("local ok, g = pcall(require, \"cosmic.internal.globals\")\nreturn ok, g\n", 1, "cosmic.internal.globals")
  refused("\nlocal g = require(\"cosmic/internal/globals\")\nreturn g\n", 2, "cosmic/internal/globals")
  refused("local g = require(\"cosmic.internal\")\nreturn g\n", 1, "cosmic.internal")
end

local function test_a_require_of_a_public_module_or_one_that_only_looks_like_the_internal_ones_is_accepted()
  accepted("local Fs = require(\"cosmic.fs\")\nreturn Fs\n")
  accepted("local ok, Fs = pcall(require, \"cosmic.fs\")\nreturn ok, Fs\n")
  accepted("local x = require(\"cosmic.internals\")\nreturn x\n")
  accepted("local x = require(\"mine.cosmic.internal.thing\")\nreturn x\n")
  accepted("local type T = require(\"cosmic.row\")\nreturn 1\n")
  -- a local of that name is the program's own, and a field is no global
  accepted("local function require(name: string): string\n  return name\nend\nreturn require(\"cosmic.internal.x\")\n")
  accepted("local t = { require = 1 }\nreturn t.require\n")
end

local function test_a_require_by_a_name_the_build_cannot_read_is_refused()
  refused("local ok = pcall(require, \"a\", \"b\")\nreturn ok\n", 1, "one literal module name")
  refused("local ok = pcall(require)\nreturn ok\n", 1, "one literal module name")
end

local function test_debug_is_refused_whatever_the_way_it_is_read()
  refused("local r = debug.getregistry()\nreturn r\n", 1, "`debug`")
  refused("local d = debug\nreturn d\n", 1, "`debug`")
  refused("return debug[\"getupvalue\"]\n", 1, "`debug`")
  -- a local of that name is the program's own, and a field is no global
  accepted("local debug = { trace = 1 }\nreturn debug.trace\n")
  accepted("local t = { debug = 1 }\nreturn t.debug\n")
end

local function test_package_is_refused_whatever_the_way_it_is_read()
  refused("local s = package.searchers\nreturn s\n", 1, "`package`")
  refused("local p = package\nreturn p\n", 1, "`package`")
  refused("return package[\"loaded\"]\n", 1, "`package`")
  refused("package.path = \"\"\n", 1, "`package`")
  refused("local g = _G\nreturn g\n", 1, "`_G`")
  refused("local f = _G.load\nreturn f\n", 1, "`_G`")
  refused("local f = _G[\"load\"]\nreturn f\n", 1, "`_G`")
  refused("local g = _ENV\nreturn g\n", 1, "`_ENV`")
  refused("local x = loadfile(\"x.lua\")\nreturn x\n", 1, "`loadfile`")
  refused("dofile(\"x.lua\")\n", 1, "`dofile`")
end

local function test_a_name_that_is_not_the_global_package_is_accepted()
  accepted("local package = \"name\"\nreturn package\n")
  accepted("local function f(package: string): string\n  return package\nend\nreturn f\n")
  accepted("local t = { package = 1 }\nreturn t.package\n")
  accepted("local s = \"package.loaded\" -- package.searchers\nreturn s\n")
  accepted("local record R\n  package: string\nend\nreturn R\n")
end

local function test_load_with_a_mode_other_than_text_is_refused()
  refused("local f = load(\"return 1\", \"=x\", \"b\", {})\nreturn f\n", 1, "mode")
  refused("local f = load(\"return 1\", \"=x\", \"bt\", {})\nreturn f\n", 1, "mode")
  refused("local m = \"b\"\nlocal f = load(\"return 1\", \"=x\", m, {})\nreturn f\n", 2, "mode")
  refused("local f = load(\"return 1\", \"=x\", nil, {})\nreturn f\n", 1, "mode")
  refused("local f = load(\"return 1\", \"=x\", \"b\")\nreturn f\n", 1, "mode")
  -- a last argument that may be several values supplies a mode and an environment
  refused("local f = load(table.unpack({ \"return 1\", \"=x\", \"b\", {} }))\nreturn f\n", 1, "last argument")
  refused("local function g(...: any)\n  return load(...)\nend\nreturn g\n", 2, "last argument")
  refused("local l = load\nreturn l\n", 1, "as a value")
  refused("local ok = pcall(load, \"return 1\")\nreturn ok\n", 1, "as a value")
end

local function test_load_of_text_is_accepted()
  accepted("local f = load(\"return 1\")\nreturn f\n")
  accepted("local f = load(\"return 1\", \"=x\")\nreturn f\n")
  accepted("local f = load(\"return 1\", \"=x\", \"t\")\nreturn f\n")
  accepted("local f = load(\"return 1\", \"=x\", \"t\", {})\nreturn f\n")
  accepted("local s = \"return 1\"\nlocal f = load(s)\nreturn f\n")
  -- parentheses cut a call to its first value
  accepted("local function text(): string, string\n  return \"return 1\", \"b\"\nend\nlocal f = load((text()))\nreturn f\n")
  accepted("local t = { load = 1 }\nreturn t.load\n")
end

local function test_each_place_is_told_in_source_order_with_its_column()
  local found = told("local a = package\nlocal b = require(\"cosmic.internal.x\")\nlocal c = loadfile\nreturn a, b, c\n")
  assert(#found == 3, table.concat(found, "\n"))
  for i, place in ipairs({ "^p%.tl:1:11: ", "^p%.tl:2:11: ", "^p%.tl:3:11: " }) do
    local line = assert(found[i])
    assert(line:find(place) ~= nil, line)
  end
end

--- The pipeline holds a project to the check and cosmic's own tree to the tree checks alone ([`build.tree_checks`]).
local function test_a_project_is_refused_and_the_tree_is_not_by_this_check()
  local project = Pipeline.project({ prelude = "do\nend\n", stdlib = "do\nend\n" })
  local source = "local g = require(\"cosmic.internal.globals\")\nreturn g\n"
  local code, why = Pipeline.lone("p.tl", source, project)
  assert(code == nil and why:find("is not a module a project may require", 1, true) ~= nil, tostring(why))
  local own: Pipeline.Options = { globals = project.globals, ceilings = project.ceilings, types = true, standard = nil,
    project = nil }
  local _, own_why = Pipeline.lone("p.tl", source, own)
  assert(own_why:find("is not a module a project may require", 1, true) == nil, own_why)
end
