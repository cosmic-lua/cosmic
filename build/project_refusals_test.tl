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

-- The raw tables are plain modules, and this check is all that keeps a project from requiring one: a `require` that is
-- not a literal call is a way to name a module the check cannot read, whatever carries it.
local function test_require_is_not_reached_by_a_value_a_table_or_a_loaded_chunk()
  -- read as a value or by a computed name, it does not parse: the build follows a require only where it is called on a literal
  for _, source in ipairs({
      "local r = require\nreturn r(\"cosmic.internal.process\")\n",
      "local t = { r = require }\nreturn t.r(\"cosmic.internal.process\")\n",
      "local r = select(1, require)\nreturn r(\"cosmic.internal.process\")\n",
      "local env = { require = require }\nreturn load(\"return require('cosmic.internal.process')\", \"=x\", \"t\", env)\n",
  }) do
    local chunk, why = Node.parse(source, "p.tl")
    assert(chunk == nil and why:find("read as a value", 1, true) ~= nil, source .. "\n" .. tostring(why))
  end
  local computed, why = Node.parse("local ok, p = pcall(require, \"cosmic.\" .. \"internal.process\")\nreturn ok, p\n", "p.tl")
  assert(computed == nil and why:find("names its module by an expression", 1, true) ~= nil, tostring(why))
  refused("return _G[\"require\"]\n", 1, "`_G`")
  -- the chunk `load` builds with no environment has no `require` to call (core/load_env_test.tl holds that)
  accepted("local f = load(\"return require('cosmic.internal.process')\")\nreturn f\n")
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

local STORE = "local Store = require(\"cosmic.store\")\n"

-- The store loads the bytecode of a database it is handed as it finds it, which nothing checks: a project that attaches a
-- database of its own making runs types the checker never read.
local function test_attach_without_the_unchecked_bytecode_option_is_refused()
  refused(STORE .. "local ok = Store.attach(\"x.db\")\nreturn ok\n", 2, "unchecked_bytecode = true")
  refused(STORE .. "local ok = Store.attach(\"x.db\", {})\nreturn ok\n", 2, "unchecked_bytecode = true")
  refused(STORE .. "local ok = Store.attach(\"x.db\", { unchecked_bytecode = false })\nreturn ok\n", 2, "unchecked_bytecode")
  refused(STORE .. "local o = { unchecked_bytecode = true }\nlocal ok = Store.attach(\"x.db\", o)\nreturn ok\n", 3, "literal table")
  refused(STORE .. "local ok = Store.attach(\"x.db\", { [\"unchecked_bytecode\"] = true })\nreturn ok\n", 2, "literal table")
  refused("local ok, Store = pcall(require, \"cosmic.store\")\nlocal a = Store.attach(\"x.db\")\nreturn ok, a\n", 2, "attach")
  refused("local a = require(\"cosmic.store\").attach(\"x.db\")\nreturn a\n", 1, "attach")
  refused("local a = require(\"cosmic/store\").attach(\"x.db\")\nreturn a\n", 1, "attach")
  refused(STORE .. "local ok = Store[\"attach\"](\"x.db\")\nreturn ok\n", 2, "attach")
end

local function test_attach_with_the_option_says_that_it_takes_unchecked_bytecode()
  accepted(STORE .. "local ok = Store.attach(\"x.db\", { unchecked_bytecode = true })\nreturn ok\n")
  accepted("local ok, Store = pcall(require, \"cosmic.store\")\nreturn ok, Store.attach(\"x.db\", { unchecked_bytecode = true })\n")
  accepted(STORE .. "return Store[\"attach\"](\"x.db\", { unchecked_bytecode = true })\n")
  accepted("return require(\"cosmic.store\").attach(\"x.db\", { unchecked_bytecode = true })\n")
end

local function test_seal_with_an_extra_module_is_refused()
  refused(STORE .. "local d = Store.seal({}, \"x.db\", { extra = { name = \"main\" } })\nreturn d\n", 2, "`seal`")
  refused(STORE .. "local d = Store.seal({}, \"x.db\", { unchecked_bytecode = true, extra = e })\nreturn d\n", 2, "`seal`")
  -- options the check cannot read may carry one
  refused(STORE .. "local o = { main = \"m\" }\nlocal d = Store.seal({ \"m\" }, \"x.db\", o)\nreturn d\n", 3, "`seal`")
  refused(STORE .. "local d = Store.seal({ \"m\" }, \"x.db\", { [\"extra\"] = e })\nreturn d\n", 2, "`seal`")
  refused(STORE .. "local d = Store.seal(table.unpack(args))\nreturn d\n", 2, "`seal`")
  accepted(STORE .. "local d = Store.seal({ \"cosmic.json\" })\nreturn d\n")
  accepted(STORE .. "local d = Store.seal({ \"cosmic.json\" }, \"x.db\")\nreturn d\n")
  accepted(STORE .. "local d = Store.seal({ \"cosmic.json\" }, \"x.db\", { main = \"cosmic.json\" })\nreturn d\n")
  accepted(STORE .. "local d = Store.seal(table.unpack(args), \"x.db\")\nreturn d\n")
end

-- The two functions are refused as values the way `package` is: an alias, a field of a table and an argument all call them
-- by a name this check does not follow.
local function test_attach_and_seal_are_not_reached_as_values_or_through_the_module_as_one()
  refused(STORE .. "local a = Store.attach\nreturn a\n", 2, "used as a value")
  refused(STORE .. "local s = Store.seal\nreturn s\n", 2, "used as a value")
  refused(STORE .. "local t = { attach = Store.attach }\nreturn t\n", 2, "used as a value")
  refused(STORE .. "local ok = pcall(Store.attach, \"x.db\")\nreturn ok\n", 2, "used as a value")
  refused(STORE .. "local ok = pcall(Store.seal, { \"m\" }, \"x.db\", e)\nreturn ok\n", 2, "used as a value")
  refused(STORE .. "local k = \"attach\"\nlocal a = Store[k]\nreturn a\n", 3, "used as a value")
  refused(STORE .. "local ok = Store:attach(\"x.db\")\nreturn ok\n", 2, "used as a value")
  refused(STORE .. "local S = Store\nreturn S\n", 2, "used as a value")
  refused(STORE .. "local t = { store = Store }\nreturn t\n", 2, "used as a value")
  refused(STORE .. "return Store\n", 2, "used as a value")
  refused(STORE .. "local function use(s: any)\n  return s\nend\nreturn use(Store)\n", 5, "used as a value")
  refused("return require(\"cosmic.store\")\n", 1, "used as a value")
  refused("return pcall(require, \"cosmic.store\")\n", 1, "used as a value")
  refused(STORE .. "Store = nil\n", 2, "used as a value")
end

local function test_the_other_fields_of_the_store_are_used_as_they_are_written()
  accepted(STORE .. "local names = Store.closure({ \"cosmic.json\" })\nreturn names\n")
  accepted(STORE .. "local f = Store.alone\nreturn f\n")
  accepted(STORE .. "local b = Store.bytecode(\"cosmic.json\")\nreturn b\n")
  accepted(STORE .. "local type E = Store.Extra\nlocal e: E = nil as E\nreturn e\n")
  -- a local of another name or a field of that name is no use of the module's functions
  accepted("local t = { attach = 1 }\nreturn t.attach\n")
  accepted("local function attach(path: string): string\n  return path\nend\nreturn attach(\"x\")\n")
  accepted("local Store = { attach = 1 }\nreturn Store.attach\n")
  accepted("local type S = require(\"cosmic.store\")\nreturn 1\n")
  accepted("local Fs = require(\"cosmic.fs\")\nreturn Fs.attach\n")
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

--- The reproduction: a checked project attaches a database it made, whose bytecode says what the checker did not read.
--- The build refuses it, and does not hold the same program once it says the bytecode is unchecked.
local function test_a_project_that_attaches_a_database_is_refused_unless_it_says_the_bytecode_is_unchecked()
  local project = Pipeline.project({ prelude = "do\nend\n", stdlib = "do\nend\n" })
  local silent = "local Store = require(\"cosmic.store\")\nlocal ok = Store.attach(\"foreign.db\")\nreturn ok\n"
  local code, why = Pipeline.lone("p.tl", silent, project)
  assert(code == nil and why:find("unchecked_bytecode = true", 1, true) ~= nil, tostring(why))
  local aliased = "local Store = require(\"cosmic.store\")\nlocal attach = Store.attach\nreturn attach\n"
  local _, aliased_why = Pipeline.lone("p.tl", aliased, project)
  assert(aliased_why:find("used as a value", 1, true) ~= nil, tostring(aliased_why))
  local said = "local Store = require(\"cosmic.store\")\n" ..
    "local ok = Store.attach(\"foreign.db\", { unchecked_bytecode = true })\nreturn ok\n"
  -- (this project declares no globals, so it fails to build for want of `require`, but not by this check)
  local _, said_why = Pipeline.lone("p.tl", said, project)
  assert(said_why:find("unchecked_bytecode", 1, true) == nil and said_why:find("used as a value", 1, true) == nil, said_why)
end
