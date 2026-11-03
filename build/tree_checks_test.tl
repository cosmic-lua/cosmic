--- [`build.tree_checks`] on fixture trees, each built to a projection by
--- the build's own code ([`build.docs_fixture`]): every check refuses a
--- tree with the defect it is for planted in it, and passes the same
--- tree without it.

local Driver = require("build.driver")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local fixture = require("build.docs_fixture")
local rebuild = require("build.rebuild")
local schema = require("build.schema")
local symbols = require("build.symbols")
local Test = require("cosmic.test")
local Tree = require("build.tree")
local tree_checks = require("build.tree_checks")
local writer = require("build.writer")
local support = require("build.test_support_fixture")

Test.policy{
  grants = {
    { path = "core/syscalls.h", letters = "r" }, { path = "core/process.h", letters = "r" },
    { path = "core/socket.h", letters = "r" }, { path = "lang/stdlib.d.tl", letters = "r" },
    { path = "lang/prelude.d.tl", letters = "r" },
  },
}

--- Lines as one source file's text.
local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- An export another module calls earns its place; one nothing calls is
--- refused until an allowance names it, and an allowance for one that
--- is used is stale.
local function test_an_unearned_export_and_a_stale_allowance_are_refused(dir: string)
  local db = fixture.database(dir, {
    ["build/thing.tl"] = source(
      "local record thing",
      "end",
      "function thing.used() end",
      "function thing.alone() end",
      "return thing"),
    ["build/user.tl"] = source(
      "local thing = require(\"build.thing\")",
      "thing.used()",
      "return {}"),
  })
  local found = tree_checks.exports(db, {})
  assert(#found == 1 and found[1]:find("^build/thing%.tl:4: build%.thing%.alone: nothing outside") ~=
      nil, table.concat(found, "\n"))
  assert(#tree_checks.exports(db, { ["build.thing.alone"] = "kept for a reason" }) == 0)
  found = tree_checks.exports(db, { ["build.thing.alone"] = "kept for a reason",
    ["build.thing.used"] = "no longer needed" })
  assert(#found == 1 and found[1]:find("^build%.thing%.used: allowed, but") ~= nil,
    table.concat(found, "\n"))
end

--- A type the API names must itself be a member of the returned record:
--- one left local is refused, naming the module and the line, whether it
--- is reached directly, through a field of an exported type, as a return
--- value only, or through a method declared outside its record; the same
--- types exported (one under another name) pass.
local function test_a_type_the_api_names_but_does_not_export_is_refused(dir: string)
  local function tree(exported: boolean): Sqlite.Handle
    return fixture.database(dir, {
      ["cosmic/thing.tl"] = source(
        "local enum Where",
        "  \"here\"",
        "end",
        "",
        "local record Made",
        "end",
        "",
        "local record Gone",
        "end",
        "",
        "local record Options",
        "  place: Where",
        "end",
        "",
        "local class Handle",
        "  function go(self, gone: Gone) end",
        "end",
        "",
        "local record Thing",
        "  type Opts = Options",
        "  type Handle = Handle",
        if exported then "  type Where = Where" else "" end,
        if exported then "  type Made = Made" else "" end,
        if exported then "  type Alias = Gone" else "" end,
        "end",
        "",
        "function Thing.run(options: Options) end",
        "function Thing.make(): Made end",
        "return Thing"),
    })
  end
  local found = tree_checks.unnamed_types(tree(false))
  local text = table.concat(found, "\n")
  assert(#found == 3, text)
  assert(found[1]:find("^cosmic/thing%.tl:8: cosmic%.thing: Gone is named .* add `type Gone = Gone` " ..
      "to Thing, so a caller can write Thing%.Gone") ~= nil, text)
  assert(support.nth(found, 2):find("^cosmic/thing%.tl:5: cosmic%.thing: Made is named") ~= nil, text)
  assert(support.nth(found, 3):find("^cosmic/thing%.tl:1: cosmic%.thing: Where is named") ~= nil, text)
  found = tree_checks.unnamed_types(tree(true))
  assert(#found == 0, table.concat(found, "\n"))
end

--- A Teal module of `cosmic/internal/` is held to the rule a public one
--- is: an export no other module calls is flagged, one a `cosmic/` module
--- calls is earned, and a raw declaration beside them is left out.
local function test_an_unused_export_of_an_internal_module_is_flagged(dir: string)
  local db = fixture.database(dir, {
    ["cosmic/internal/shared.tl"] = source(
      "local record shared",
      "end",
      "function shared.used() end",
      "function shared.alone() end",
      "return shared"),
    ["cosmic/internal/raw.d.tl"] = source(
      "--- @kind binding",
      "local record raw",
      "  poke: function()",
      "end",
      "return raw"),
    ["cosmic/user.tl"] = source(
      "local shared = require(\"cosmic.internal.shared\")",
      "shared.used()",
      "return {}"),
  })
  local found = tree_checks.exports(db, {})
  assert(#found == 1 and found[1]:find("^cosmic/internal/shared%.tl:4: " ..
      "cosmic%.internal%.shared%.alone: nothing outside") ~= nil, table.concat(found, "\n"))
end

--- A Teal module of `cosmic/internal/` has rows in the projection but is
--- not in the public documentation set, as no raw table is.
local function test_an_internal_module_is_absent_from_the_public_docs(dir: string)
  local db = fixture.database(dir, {
    ["cosmic/internal/shared.tl"] = source(
      "local record shared",
      "end",
      "--- Does the shared thing.",
      "function shared.used() end",
      "return shared"),
    ["cosmic/fs.tl"] = source(
      "local record fs",
      "end",
      "--- Does the public thing.",
      "function fs.read() end",
      "return fs"),
  })
  local all = assert(Sqlite.text_rows(db, "SELECT DISTINCT module FROM docs ORDER BY module"))
  local public = assert(Sqlite.text_rows(db, "SELECT DISTINCT module FROM docs WHERE " ..
      symbols.public_only("module", true) .. " ORDER BY module"))
  assert(#all == 2 and all[1]:text(1) == "cosmic.fs" and support.nth(all, 2):text(1) == "cosmic.internal.shared",
    tostring(#all) .. " modules")
  assert(#public == 1 and public[1]:text(1) == "cosmic.fs")
  assert(symbols.is_public_module("cosmic.fs"))
  assert(not symbols.is_public_module("cosmic.internal.shared"))
end

--- A module that exports `spec` is a verb's entry, as one that exports
--- `run` or `main` is a program's: what only its own test calls is
--- excused. One exporting none of the three is still refused.
local function test_a_module_exporting_spec_is_a_program_entry(dir: string)
  local function tree(entry: string, field: string): {string: string}
    return {
      ["build/verb.tl"] = source(
        "local record verb",
        "  --- the entry",
        "  " .. field .. ": {string: string}",
        "end",
        "function verb.step() end",
        entry,
        "return verb"),
      ["build/lister.tl"] = source(
        "local verb = require(\"build.verb\")",
        "return { entry = verb." .. field .. " }"),
      ["build/verb_test.tl"] = source(
        "local verb = require(\"build.verb\")",
        "local function test_step()",
        "  verb.step()",
        "end"),
    }
  end
  local with_spec = fixture.database(dir, tree("verb.spec = { name = \"verb\" }", "spec"))
  local found = tree_checks.exports(with_spec, {})
  assert(#found == 0, table.concat(found, "\n"))
  local without = fixture.database(dir, tree("verb.other = { name = \"verb\" }", "other"))
  found = tree_checks.exports(without, {})
  assert(#found >= 1 and found[1]:find("build%.verb%.step: nothing outside") ~= nil,
    table.concat(found, "\n"))
end

--- An anchor module of one documented string field, `field`.
local function anchor(name: string, field: string): string
  return source(
    "--- Doc anchors.",
    "local record " .. name,
    "  --- what " .. field .. " means here",
    "  " .. field .. ": string",
    "end",
    "local value: " .. name .. " = { " .. field .. " = \"" .. field .. "\" }",
    "return value")
end

--- Two anchors sharing a name are refused, and an anchor expected that
--- is no longer one; anchors of names of their own pass.
local function test_anchors_sharing_a_name_are_refused(dir: string)
  local expected = { "cosmic.verbs Verbs", "cosmic.shapes Shapes" }
  local shared = fixture.database(dir, {
    ["cosmic/verbs.tl"] = anchor("Verbs", "test"),
    ["cosmic/shapes.tl"] = anchor("Shapes", "test"),
  })
  local found = tree_checks.anchors(shared, expected)
  assert(#found == 1 and found[1]:find("`cosmic docs test` answers both", 1, true) ~= nil,
    table.concat(found, "\n"))
  local apart = fixture.database(dir, {
    ["cosmic/verbs.tl"] = anchor("Verbs", "test"),
    ["cosmic/shapes.tl"] = anchor("Shapes", "tests"),
  })
  found = tree_checks.anchors(apart, expected)
  assert(#found == 0, table.concat(found, "\n"))
  found = tree_checks.anchors(apart, { "cosmic.verbs Verbs", "cosmic.gone Gone" })
  assert(#found == 1 and found[1] == "cosmic.gone Gone is no longer taken for a doc anchor",
    table.concat(found, "\n"))
end

--- A module that reads the compiler's identity is refused until the
--- list names it; spelled apart, so this module's own source reads
--- nothing.
local function test_an_unnamed_reader_of_the_compiler_is_refused(dir: string)
  local db = fixture.database(dir, {
    ["build/reader.tl"] = source(
      "local Store = require(\"build.load_module\")",
      "local tool = Store.meta" .. "(\"compiler\")",
      "return { tool = tool }"),
  })
  local found = tree_checks.compiler_readers(db, {})
  assert(#found == 1 and found[1]:find("^build%.reader reads the compiler's identity") ~= nil,
    table.concat(found, "\n"))
  found = tree_checks.compiler_readers(db, { "build.reader" })
  assert(#found == 0, table.concat(found, "\n"))
end

--- A module that joins a path to `/o` spells the build directory by hand
--- and is refused until an excuse names its file; a comment that does is
--- not, nor a test, and an excuse for a file that no longer does is stale.
--- The joins are spelled apart, so this module's own source holds none.
local function test_a_build_directory_spelled_by_hand_is_refused(dir: string)
  local join = ".. \"/o"
  local db = fixture.database(dir, {
    ["build/spells.tl"] = source(
      "local root = \"/r\"",
      "local out = root " .. join .. "\"",
      "local tool = root " .. join .. "/bin/cosmic\"",
      "return { out = out, tool = tool }"),
    ["build/says.tl"] = source(
      "-- root " .. join .. "\" is where it was",
      "local outer = \"/r\" .. \"/other\"",
      "return { outer = outer }"),
    ["build/spells_test.tl"] = source(
      "local out = \"/r\" " .. join .. "\"",
      "assert(out)"),
  })
  local found = tree_checks.build_directory(db, {})
  assert(#found == 2, table.concat(found, "\n"))
  assert(support.nth(found, 1):find("^build/spells%.tl:2: spells the build directory") ~= nil, found[1])
  assert(support.nth(found, 2):find("^build/spells%.tl:3: ") ~= nil, found[2])
  assert(#tree_checks.build_directory(db, { ["build/spells.tl"] = "kept" }) == 0)
  found = tree_checks.build_directory(db, { ["build/spells.tl"] = "kept", ["build/says.tl"] = "gone" })
  assert(#found == 1 and found[1]:find("^build/says%.tl: excused") ~= nil, table.concat(found, "\n"))
end

--- A function whose doc comment names the command it stands in for is
--- what `cosmic docs <command>` answers first; one whose doc comment
--- stopped naming it is refused.
local function test_a_stand_in_that_stops_naming_its_command_is_refused(dir: string)
  local function proc(doc: string): string
    return source(
      "local record Proc",
      "end",
      "",
      "--- " .. doc,
      "function Proc.find(name: string): string",
      "  return name",
      "end",
      "",
      "return Proc")
  end
  local cases = { { "which", "Proc.find" } }
  local named = fixture.database(dir, {
    ["cosmic/proc.tl"] = proc("Where a program would run from, as `which` finds it."),
  })
  local found = tree_checks.stand_ins(named, cases)
  assert(#found == 0, table.concat(found, "\n"))
  local unnamed = fixture.database(dir, {
    ["cosmic/proc.tl"] = proc("Where a program would run from."),
  })
  found = tree_checks.stand_ins(unnamed, cases)
  assert(#found == 1 and found[1]:find("^`cosmic docs which` answers nothing first, not Proc.find") ~=
      nil, table.concat(found, "\n"))
end

--- A query a compile's failure points to is answered by a worked
--- example of that name; one no example answers is refused.
local function test_a_query_no_example_answers_is_refused(dir: string)
  local db = fixture.database(dir, {
    ["cosmic/thing.tl"] = source(
      "local record Thing",
      "end",
      "--- Does the thing.",
      "function Thing.run() end",
      "return Thing"),
    ["cosmic/thing_example.tl"] = source(
      "local Thing = require(\"cosmic.thing\")",
      "local Example = {}",
      "function Example.records_and_their_fields()",
      "  Thing.run()",
      "end",
      "return Example"),
  })
  local found = tree_checks.queries(db, { "records_and_their_fields" })
  assert(#found == 0, table.concat(found, "\n"))
  found = tree_checks.queries(db, { "records_and_their_fields", "unions_and_their_members" })
  assert(#found == 1 and found[1]:find("^`cosmic docs unions_and_their_members` answers nothing") ~=
      nil, table.concat(found, "\n"))
end

--- A quieted method its record declares passes; one it lacks, or a
--- record no module declares, is refused.
local function test_a_quieted_method_no_record_declares_is_refused(dir: string)
  local db = fixture.database(dir, {
    ["cosmic/log.tl"] = source(
      "local record Log",
      "  record Logger",
      "    --- Writes a line.",
      "    say: function(Logger, string)",
      "  end",
      "end",
      "return Log"),
  })
  local found = tree_checks.quieted(db, { "cosmic.log Logger", "cosmic.log Logger.say" })
  assert(#found == 0, table.concat(found, "\n"))
  found = tree_checks.quieted(db, { "cosmic.log Logger.shout", "cosmic.gone Gone" })
  assert(#found == 2, table.concat(found, "\n"))
  assert(support.nth(found, 1):find("^cosmic%.log Logger%.shout is quieted") ~= nil, found[1])
  assert(support.nth(found, 2):find("^cosmic%.gone Gone is quieted") ~= nil, found[2])
end

--- A member kept to a few files passes in them and is refused anywhere
--- else, a test included.
local function test_a_restricted_member_used_outside_its_files_is_refused(dir: string)
  local db = fixture.database(dir, {
    ["build/probe.tl"] = source(
      "local record probe",
      "end",
      "--- Whether the host has it.",
      "function probe.has(): boolean return true end",
      "return probe"),
    ["build/asker.tl"] = source(
      'local probe = require("build.probe")',
      "local record asker",
      "end",
      "function asker.ask(): boolean return probe.has() end",
      "return asker"),
    ["build/other_test.tl"] = source(
      'local probe = require("build.probe")',
      "local function test_asks()",
      "  assert(probe.has())",
      "end"),
  })
  local rules = { ["build.probe has"] = { files = { "build/asker.tl" }, why = "ask the host" } } -- checked: arms_differ
  local found = tree_checks.restricted(db, rules)
  assert(#found == 1, table.concat(found, "\n"))
  assert(support.nth(found, 1):find("^build/other_test%.tl:%d+: build%.probe has is used outside build/asker%.tl: ask the host") ~=
      nil, found[1])
  rules["build.probe has"].files = { "build/asker.tl", "build/other_test.tl" }
  found = tree_checks.restricted(db, rules)
  assert(#found == 0, table.concat(found, "\n"))
end

--- The loader of a module by a name computed at run time is kept to the tool's entry and the test worker by who may
--- require it: a module that holds it under an alias or reads `load` off it by a key is refused all the same.
local function test_a_module_requiring_the_loader_outside_the_entry_and_the_worker_is_refused(dir: string)
  local db = fixture.database(dir, {
    ["build/load_module.tl"] = source(
      "local record loader",
      "end",
      "--- Loads a module by a name got at run time.",
      "function loader.load(name: string): any return name end",
      "return loader"),
    ["build/dispatch.tl"] = source(
      'local loader = require("build.load_module")',
      "local record dispatch",
      "end",
      'function dispatch.run(): any return loader.load("x") end',
      "return dispatch"),
    ["build/plugin.tl"] = source(
      'local loader = require("build.load_module")',
      "local record plugin",
      "end",
      'function plugin.run(): any return loader["load"]("x") end',
      "return plugin"),
    ["build/aliased.tl"] = source(
      'local loader = require("build.load_module")',
      "local alias = loader",
      "local record aliased",
      "end",
      'function aliased.run(): any return alias.load("x") end',
      "return aliased"),
    ["build/probing.tl"] = source(
      'local found, _ = pcall(require, "build.load_module")',
      "local record probing",
      "end",
      "function probing.run(): boolean return found end",
      "return probing"),
  })
  local found = tree_checks.requirers(db)
  assert(#found == 3, table.concat(found, "\n"))
  local line = assert(found[1])
  assert(line:find("^build%.aliased: requires build%.load_module, which only build%.dispatch, build%.test_worker, " ..
      "build%.load_module_test may require: ") ~= nil, line)
  assert(line:find("require(\"cosmic.fs\")", 1, true) ~= nil, line)
  local all = table.concat(found, "\n")
  assert(all:find("\nbuild%.plugin: requires") ~= nil and all:find("\nbuild%.probing: requires") ~= nil, all)
end

--- A module that reads the store's text (its sources, or its text-derived tables) without requiring one of the
--- `build.reads.*` modules by value is refused, naming it; requiring one by value passes, and requiring one by type
--- alone does not, since a test's closure leaves that edge out. A test, and a module that only reads rows no text
--- table holds, are none.
local function test_a_module_reading_store_text_without_declaring_it_is_refused(dir: string)
  local function reads(name: string, body: string, requires?: string): {string}
    return { name, source(
      'local Store = require("cosmic.store")',
      requires or "",
      "local record reader",
      "end",
      body,
      "return reader") }
  end
  local files: mut {string:string} = {
    ["build/reads/all.tl"] = source("--- @public", "local record all", "end", "return all"),
    ["build/reads/pipeline.tl"] = source("--- @public", "local record pipeline", "end", "return pipeline"),
  }
  local cases = {
    reads("build/undeclared.tl", "function reader.run(): string? local s, _ = Store.source(\"x\") return s end"),
    reads("build/declared.tl", "function reader.run(): string? local s, _ = Store.source(\"x\") return s end",
      'local _ = require("build.reads.all")'),
    reads("build/typed.tl", "function reader.run(): string? local s, _ = Store.source(\"x\") return s end",
      'local type _ = require("build.reads.all")'),
    reads("build/withheld.tl", "function reader.run(): string? local w, _ = Store.withheld(\"x\") return w end"),
    reads("build/queries.tl",
      'function reader.run(): string local _ = Store.databases() return "SELECT symbol FROM docs" end'),
    reads("build/counts.tl", "function reader.run(): integer return #Store.databases() end"),
  }
  for _, case in ipairs(cases) do
    local path, text = case[1], case[2]
    if path ~= nil and text ~= nil then files[path] = text end
  end
  local db = fixture.database(dir, files)
  local found = tree_checks.text_readers(db)
  local joined = table.concat(found, "\n")
  for _, name in ipairs({ "build.undeclared", "build.typed", "build.withheld", "build.queries" }) do
    assert(joined:find(name .. " reads text", 1, true) ~= nil, name .. " is refused: " .. joined)
  end
  for _, name in ipairs({ "build.declared", "build.counts" }) do
    assert(joined:find(name .. " reads", 1, true) == nil, name .. " is not: " .. joined)
  end
end

--- A module outside the list that reads `package` is refused, whether it indexes it, reads a field or holds it under
--- another name; a field called `package`, a table key and text are no read; a test is not held to the list.
local function test_a_module_reading_package_outside_the_list_is_refused(dir: string)
  local function put(file: string, text: string)
    assert(Fs.mkdirs(dir .. "/build"))
    assert(Fs.write(dir .. "/" .. file, text))
  end
  put("build/allowed.tl", "local x = package.searchers\nreturn x\n")
  put("build/alias.tl", "local p = package\nreturn p\n")
  put("build/indexed.tl", "local s = package[\"searchers\"]\nreturn s\n")
  put("build/searchers.tl", "local s = package.searchers\nreturn s\n")
  put("build/preload.tl", "local s = package.preload\nreturn s\n")
  put("build/searchpath.tl", "local s = package.searchpath\nreturn s\n")
  put("build/loadlib.tl", "local s = package.loadlib\nreturn s\n")
  put("build/path.tl", "package.cpath = \"\"\npackage.path = \"\"\n")
  put("build/loaded.tl", "local s = package.loaded\nreturn s\n")
  put("build/fine.tl", "local t = { package = 1 }\n-- package.searchers\nlocal s = \"package.loaded\"\nreturn t.package, s\n")
  put("build/record.tl", "local record R\n  package: string\nend\nreturn R\n")
  put("build/probe_test.tl", "local s = package.searchers\nreturn s\n")
  local found = tree_checks.package_readers(dir, { ["build/allowed.tl"] = "needs it" })
  local files: mut {string} = {}
  for _, line in ipairs(found) do
    files[#files + 1] = line:match("^([^:]+):%d+: reads `package`") or line
  end
  table.sort(files)
  assert(table.concat(files, " ") == "build/alias.tl build/indexed.tl build/loaded.tl build/loadlib.tl build/path.tl " ..
      "build/path.tl build/preload.tl build/searchers.tl build/searchpath.tl", table.concat(found, "\n"))
end

--- A file that builds a function from text is refused unless the list names it: the call, an alias and an argument are
--- found; a field of that name, a function defined by it, a string and a test are not.
local function test_a_module_building_a_chunk_from_text_outside_the_list_is_refused(dir: string)
  local function put(file: string, text: string)
    assert(Fs.mkdirs(dir .. "/build"))
    assert(Fs.write(dir .. "/" .. file, text))
  end
  put("build/allowed.tl", "local f = load(\"return 1\")\nreturn f\n")
  put("build/called.tl", "local f = load(\"return 1\", \"=x\", \"t\", {})\nreturn f\n")
  put("build/aliased.tl", "local l = load\nreturn l\n")
  put("build/passed.tl", "local ok = pcall(load, \"return 1\")\nreturn ok\n")
  put("build/file.tl", "local f = loadfile(\"x.lua\")\nreturn f\n")
  put("build/dofiled.tl", "dofile(\"x.lua\")\n")
  put("build/globals_field.tl", "local f = _G.load(\"return 1\")\nreturn f\n")
  put("build/globals_index.tl", "local f = _G[\"load\"]\nreturn f\n")
  put("build/globals_rawget.tl", "local f = rawget(_G, \"loadfile\")\nreturn f\n")
  put("build/fine.tl", "local t = { load = 1 }\nlocal s = \"load(x)\"\n-- load(x)\n" ..
      "local record R\n  load: function(): integer\nend\nfunction R.load(): integer return 1 end\n" ..
      "return t.load, s, R.load()\n")
  put("build/probe_test.tl", "local f = load(\"return 1\")\nreturn f\n")
  local found = tree_checks.text_loaders(dir, { ["build/allowed.tl"] = "builds a chunk" })
  local files: mut {string} = {}
  for _, line in ipairs(found) do
    files[#files + 1] = line:match("^([^:]+):%d+: uses ") or line
  end
  table.sort(files)
  assert(table.concat(files, " ") == "build/aliased.tl build/called.tl build/dofiled.tl build/file.tl build/globals_field.tl " ..
      "build/globals_index.tl build/globals_rawget.tl build/passed.tl",
    table.concat(found, "\n"))
end

--- A test that returns early from its own body is refused with its file, line and name; a skip, a return in a branch that
--- asserts, and a module that is no test are not.
local function test_a_test_returning_early_is_refused(dir: string)
  local function put(file: string, text: string)
    assert(Fs.mkdirs(dir .. "/" .. (file:match("^(.*)/[^/]*$") or ".")))
    assert(Fs.write(dir .. "/" .. file, text))
  end
  put("build/guard_test.tl", "local function test_guarded()\n  local x = nil\n  if x == nil then return end\n  assert(x)\nend\n")
  put("build/bare_test.tl", "local function test_bare()\n  assert(true)\n  return\nend\n")
  put("build/skips_test.tl", "local Test = require(\"cosmic.test\")\nlocal function test_skips()\n" ..
      "  if nothing() then\n    Test.skip(\"no\")\n    return\n  end\n  assert(true)\nend\n")
  put("build/arm_test.tl", "local function test_arm()\n  if nothing() then\n    assert(true)\n    return\n  end\n  assert(false)\nend\n")
  put("build/helper.tl", "local function test_not_a_test_file()\n  if nothing() then return end\nend\n")
  local found = tree_checks.test_returns(dir)
  assert(#found == 2, table.concat(found, "\n"))
  assert(found[1]:find("^build/bare_test.tl:3: test_bare returns early %(`return`%)"), found[1])
  assert(found[2]:find("^build/guard_test.tl:3: test_guarded returns early %(`if ... then return end`%)"), found[2])
end

--- A helper written token for token in two files, one a test or a fixture, is refused with both files and lines,
--- whatever its comments and layout; one renamed inside, too short, in two files that are neither, twice in one file, or
--- a test itself is not.
local function test_a_helper_copied_between_test_files_is_refused(dir: string)
  local function put(file: string, text: string)
    assert(Fs.write(dir .. "/" .. file, text))
  end
  local function swap(text: string, from: string, to: string): string
    return (text:gsub(from, to))
  end
  local function helper(name: string, tail: string): string
    return source(
      "local function " .. name .. "(first: string, second: string): string",
      "  local out: {string} = {}",
      "  out[#out + 1] = first",
      "  out[#out + 1] = second",
      "  return table.concat(out, \"" .. tail .. "\")",
      "end")
  end
  local body = helper("join", "/")
  assert(Fs.mkdirs(dir .. "/build"))
  put("build/a_test.tl", "local x = 1\n\n" .. body)
  -- Comments and the line breaks around the helper are no part of it.
  put("build/b_fixture.tl", "-- Joins.\n" .. swap(body, "  out%[#out %+ 1%] = first", "  -- first\n  out[#out + 1] = first"))
  -- A name inside differs, so it is another helper.
  put("build/renamed_test.tl", swap(body, "second", "other"))
  put("build/literal_test.tl", helper("join", "-"))
  put("build/short_test.tl", "local function f(a: string): string\n  return a\nend\n")
  put("build/short_other_test.tl", "local function f(a: string): string\n  return a\nend\n")
  local library = helper("library", "|")
  put("build/lib.tl", library)
  put("build/lib_other.tl", library)
  -- A plain script is no side of a pair, though the other side is a test.
  put("build/script.tl", body)
  local twice = helper("twice", ";")
  put("build/twice_test.tl", twice .. "\n" .. swap(twice, "twice", "again"))
  put("build/tests_test.tl", helper("test_join", ","))
  put("build/tests_other_test.tl", helper("test_join", ","))
  local found = tree_checks.test_clones(dir, 20)
  assert(#found == 1, table.concat(found, "\n"))
  assert(found[1]:find("^build/a_test.tl:3: join is copied token for token in build/b_fixture.tl:2 %(join%): " ..
      "move it into a shared fixture"), found[1])
  assert(found[1]:find("build/test_support_fixture.tl", 1, true) ~= nil, found[1])
  found = tree_checks.test_clones(dir, 80)
  assert(#found == 0, table.concat(found, "\n"))
end

--- Two fixtures that copy each other are refused though no test file holds either.
local function test_a_copy_between_fixtures_is_refused(dir: string)
  local body = source(
    "local function join(first: string, second: string): string",
    "  local out: {string} = {}",
    "  out[#out + 1] = first",
    "  out[#out + 1] = second",
    "  return table.concat(out, \"/\")",
    "end")
  assert(Fs.mkdirs(dir .. "/build"))
  assert(Fs.write(dir .. "/build/one_fixture.tl", body))
  assert(Fs.write(dir .. "/build/two_fixture.tl", body))
  local found = tree_checks.test_clones(dir, 20)
  assert(#found == 1, table.concat(found, "\n"))
  assert(found[1]:find("^build/one_fixture.tl:1: join is copied token for token in build/two_fixture.tl:1"), found[1])
end

--- Two files that embed the same snippet of Teal in a string, with a `local function` at the left margin in it, hold no
--- helper of it: nothing is found, though the heads match and one of them is unreadable.
local function test_a_snippet_in_a_string_is_no_helper(dir: string)
  local function put(file: string, text: string)
    assert(Fs.write(dir .. "/" .. file, text))
  end
  local text = source(
    "local function writes(root: string)",
    "  assert(Fs.write(root .. \"/a.tl\", [[",
    "local function inner(first: string, second: string): string",
    "  local out: {string} = {}",
    "  out[#out + 1] = first",
    "  out[#out + 1] = second",
    "  return table.concat(out, \"/\")",
    "end",
    "local function broken(a: string): string",
    "  return a +",
    "end",
    "]]))",
    "  assert(Fs.write(root .. \"/b.tl\", \"x\"))",
    "end")
  assert(Fs.mkdirs(dir .. "/build"))
  put("build/first_test.tl", (text:gsub("writes", "first")))
  put("build/second_test.tl", (text:gsub("\"x\"", "\"y\"")))
  local found = tree_checks.test_clones(dir, 5)
  assert(#found == 0, table.concat(found, "\n"))
end

--- A helper that writes Teal source in a long string, with `end` lines of its own, and one written on a line are read
--- whole, so their copies are found.
local function test_a_helper_holding_a_string_of_source_or_on_one_line_is_found(dir: string)
  local function put(file: string, text: string)
    assert(Fs.write(dir .. "/" .. file, text))
  end
  local body = source(
    "local function writes(root: string)",
    "  assert(Fs.write(root .. \"/a.tl\", [[",
    "  local function inner()",
    "    return 1",
    "end",
    "]]))",
    "  assert(Fs.write(root .. \"/b.tl\", \"x\"))",
    "end",
    "local function one(a: string): string return a .. a .. a end")
  assert(Fs.mkdirs(dir .. "/build"))
  put("build/a_test.tl", body)
  put("build/b_test.tl", body)
  local found = tree_checks.test_clones(dir, 5)
  assert(#found == 2, table.concat(found, "\n"))
  assert(found[1]:find("^build/a_test.tl:1: writes is copied token for token in build/b_test.tl:1 %(writes%)"), found[1])
  assert(found[2]:find("^build/a_test.tl:9: one is copied token for token in build/b_test.tl:9 %(one%)"), found[2])
end

--- A declaration that requires only declarations passes; one that requires a module is refused.
local function test_a_declaration_that_requires_a_module_is_refused(dir: string)
  local db = fixture.database(dir, {
    ["build/base.d.tl"] = source("--- @kind binding", "local record base", "  x: integer", "end", "return base"),
  })
  local found = tree_checks.declarations(db)
  assert(#found == 0, table.concat(found, "\n"))
  db = fixture.database(dir, {
    ["build/thing.tl"] = source("local record thing", "  x: integer", "end", "return thing"),
    ["build/raw.d.tl"] = source(
      "--- @kind binding",
      "local type thing = require(\"build.thing\")",
      "local record raw",
      "  t: thing",
      "end",
      "return raw"),
  })
  found = tree_checks.declarations(db)
  assert(#found == 1 and found[1]:find("^build%.raw requires build%.thing, which is no " ..
      "declaration") ~= nil, table.concat(found, "\n"))
end

--- The files held to earn no note are the public standard library's:
--- `cosmic/` outside `cosmic/internal/`.
local function test_the_standard_library_is_the_public_cosmic_tree()
  assert(tree_checks.standard("cosmic/fs.tl"))
  assert(tree_checks.standard("./cosmic/child/group.tl"))
  assert(not tree_checks.standard("cosmic/internal/buffer.tl"))
  assert(not tree_checks.standard("build/fix/init.tl"))
  assert(not tree_checks.standard("ci/cosmic/thing.tl"))
end

--- A module assigning a spec of a verb `name` whose guide and tests are as
--- given (`tests` as the source's own list).
local function verb(name: string, guide: string, tests: string): string
  return source("local m = {}", "m.spec = {", "  name = \"" .. name .. "\",",
    "  guide = \"" .. guide .. "\",", "  tests = { " .. tests .. " },", "}", "return m")
end

--- A verb is held to its whole registration: its module listed, its
--- guide a heading of the quickstart (or a reason), its tests modules of
--- the tree. Each defect is named with its verb; the tree without any
--- passes.
local function test_a_verb_is_held_to_its_registration(dir: string)
  local quickstart = "# quickstart\n\n## a thing\n\n`cosmic thing` does it.\n\n## a stray\n\nnothing\n\n```\n## in a fence\n```\n"
  local function found_with(thing: string, extra?: {string:string}): {string}
    local files: mut {string:string} = {
      ["build/verb_list.tl"] = source("local thing = require(\"build.thing\")", "return {}"),
      ["build/thing.tl"] = thing,
      ["build/thing_test.tl"] = source("return {}"),
    }
    for path, text in pairs(extra or {}) do files[path] = text end
    return tree_checks.verbs(fixture.database(dir, files), quickstart)
  end
  local ok = "\"build.thing_test\""
  local found = found_with(verb("thing", "a thing", ok))
  assert(#found == 0, table.concat(found, "\n"))
  found = found_with(verb("thing", "none: a maintainer's verb", ok))
  assert(#found == 0, table.concat(found, "\n"))

  found = found_with(verb("thing", "a thing", ok), { ["build/spare.tl"] = verb("spare", "none: a spare", ok) })
  assert(#found == 1 and found[1]:find("^`spare` %(build%.spare%) assigns a `spec` but " ..
      "build/verb_list%.tl does not list its module") ~= nil, table.concat(found, "\n"))
  found = found_with(verb("thing", "a missing heading", ok))
  assert(#found == 1 and found[1]:find("^`thing`'s guide is \"a missing heading\", which is no `## ` heading") ~=
      nil, table.concat(found, "\n"))
  found = found_with(verb("thing", "none: ", ok))
  assert(#found == 1 and found[1]:find("^`thing` has no guide and gives no reason") ~= nil,
    table.concat(found, "\n"))
  found = found_with(verb("thing", "a thing", ""))
  assert(#found == 1 and found[1]:find("^`thing` names no test module in `tests`") ~= nil,
    table.concat(found, "\n"))
  found = found_with(verb("thing", "a stray", ok))
  assert(#found == 1 and found[1]:find("whose section never mentions `cosmic thing`", 1, true) ~= nil,
    table.concat(found, "\n"))
  found = found_with(verb("thing", "in a fence", ok))
  assert(#found == 1 and found[1]:find("is no `## ` heading", 1, true) ~= nil, table.concat(found, "\n"))
  found = found_with(verb("thing", "a thing", "\"build.gone_test\", \"build.thing\", " .. ok))
  assert(#found == 2 and found[1]:find("^`thing`'s tests name build%.gone_test, which is no test module") ~=
      nil and support.nth(found, 2):find("name build%.thing, which is no test module") ~= nil,
    table.concat(found, "\n"))
end

--- A spec is read as the source writes it, in any layout of literals, and
--- what cannot be read is refused rather than passed over: a guide that is
--- no string literal, a listed verb whose spec is no table literal, a
--- test named by a variable.
local function test_a_spec_is_read_in_any_layout_of_literals(dir: string)
  local quickstart = "## a thing\n\n`cosmic thing` does it.\n"
  local function found_with(thing: string, extra?: {string:string}): {string}
    local files: mut {string:string} = {
      ["build/verb_list.tl"] = source(
        "local record list end",
        "local x = { load = function() return require(\"build.thing\").spec end }",
        "return {}"),
      ["build/thing.tl"] = thing,
      ["build/thing_test.tl"] = source("return {}"),
    }
    for path, text in pairs(extra or {}) do files[path] = text end
    return tree_checks.verbs(fixture.database(dir, files), quickstart)
  end
  local function spec(...: string): string
    return source("local m = {}", "m.spec = {", table.concat({ ... }, "\n"), "}", "return m")
  end

  local found = found_with(spec(
    "  name = \"thing\", -- \"a } stray\", { \"build.gone_test\"",
    "  guide = \"a thing\",",
    "  tests = {",
    "    -- the module below is checked, and this one's braces } are not",
    "    \"build.thing_test\", -- \"build.gone_test\"",
    "  },",
    "  takes = \"a \\\"quoted\\\" } brace\","))
  assert(#found == 0, table.concat(found, "\n"))

  found = found_with(spec("  name = \"thing\",", "  guide = \"a \\\"thing\\\"\",",
    "  tests = { \"build.thing_test\" },"))
  assert(#found == 1 and found[1]:find("guide is \"a \"thing\"\"", 1, true) ~= nil,
    table.concat(found, "\n"))

  found = found_with(spec("  name = \"thing\",", "  tests = { \"build.thing_test\" },"))
  assert(#found == 1 and found[1]:find("^`thing` has no guide as a string literal") ~= nil,
    table.concat(found, "\n"))
  found = found_with(spec("  name = \"thing\",", "  guide = [[a thing]],",
    "  tests = { \"build.thing_test\" },"))
  assert(#found == 1 and found[1]:find("^`thing` has no guide as a string literal") ~= nil,
    table.concat(found, "\n"))
  found = found_with(spec("  name = \"thing\",", "  guide = \"a thing\",",
    "  tests = { \"build.thing_test\", other },"))
  assert(#found == 1 and found[1]:find("^`thing` names no test module in `tests`, as string literals") ~=
      nil, table.concat(found, "\n"))

  -- A spec exported from a local is no literal the check reads: refused
  -- as a listed verb with none.
  found = found_with(source("local m = {}", "local s = { name = \"thing\" }", "m.spec = s", "return m"))
  assert(#found == 1 and found[1]:find("loads `build.thing`'s `spec`", 1, true) ~= nil,
    table.concat(found, "\n"))

  -- What only looks like a spec is none: a name that merely ends in
  -- "spec", and a line inside a comment.
  found = found_with(spec("  name = \"thing\",", "  guide = \"a thing\",",
    "  tests = { \"build.thing_test\" },"), {
      ["build/other.tl"] = source("local m = {}", "m.respec = { name = \"other\" }",
        "--- m.spec = { name = \"other\" }", "return m"),
    })
  assert(#found == 0, table.concat(found, "\n"))

  -- Its guide is not held to a quickstart that could not be read.
  local files = {
    ["build/verb_list.tl"] = source("return { require(\"build.thing\").spec }"),
    ["build/thing.tl"] = spec("  name = \"thing\",", "  guide = \"a missing heading\",",
      "  tests = { \"build.thing_test\" },"),
    ["build/thing_test.tl"] = source("return {}"),
  }
  found = tree_checks.verbs(fixture.database(dir, files), nil)
  assert(#found == 0, table.concat(found, "\n"))
end

--- A requirement a test module declares that no CI leg promises is
--- refused, naming the module and the name: it would be n/a or skipped on
--- every leg and run nowhere. A name a leg promises, a Landlock version
--- below one it promises, and a module that declares none are not; a leg
--- promising a name the table refuses is.
local function test_a_requirement_no_leg_promises_is_refused()
  local legs: {string:{string}} = {
    ["linux"] = { "sandbox", "landlock:3", "nest" },
    ["mac"] = {},
  }
  local declared: {string:{string}} = {
    ["a_test"] = { "nest", "landlock:2" },
    ["b_test"] = { "proc", "root" },
  }
  local found = tree_checks.promises(declared, legs)
  assert(#found == 2, table.concat(found, "\n"))
  assert(support.nth(found, 1):find("b_test requires proc, which no CI leg promises", 1, true), found[1])
  assert(support.nth(found, 2):find("b_test requires root, which no CI leg promises", 1, true), found[2])
  assert(#tree_checks.promises({ ["a_test"] = { "nest" } }, legs) == 0)
  assert(#tree_checks.promises({}, legs) == 0)
  local refused = tree_checks.promises({}, { linux = { "nope" } })
  assert(#refused == 1 and refused[1]:find("leg linux promises \"nope\", which is refused", 1, true) ~= nil, refused[1])
end

--- The legs are read out of ci/cosmic_ci/capabilities.json, and a file
--- that holds no `legs` of lists of names is refused.
local function test_the_legs_are_read_from_the_capabilities_file(dir: string)
  assert(Fs.mkdirs(dir .. "/ci/cosmic_ci"))
  local path = dir .. "/ci/cosmic_ci/capabilities.json"
  assert(Fs.write(path, '{"legs": {"x": ["sandbox", "nest"], "y": []}}'))
  local legs = assert(tree_checks.legs(dir))
  assert(#legs.x == 2 and legs.x[2] == "nest" and #legs.y == 0) -- checked: map_field*3
  for _, bad in ipairs({ "{}", '{"legs": {"x": 1}}', "not json", "{" }) do
    assert(Fs.write(path, bad))
    local found, why = tree_checks.legs(dir)
    assert(found == nil and why:find("capabilities.json", 1, true) ~= nil, bad .. ": " .. tostring(why))
  end
end

--- The requirements a module declares are read from the working
--- database's `test_inputs` by the module that holds the source, in the
--- order written, and a module declaring none is not listed.
local function test_the_declared_requirements_are_read_by_module()
  local db = assert(Sqlite.open(":memory:", { writable = true }))
  assert(db:exec("CREATE TABLE inputs (path TEXT, source_hash TEXT)"))
  assert(db:exec("CREATE TABLE test_inputs (source_hash TEXT, ordinal INTEGER, field TEXT, value TEXT)"))
  assert(db:exec("INSERT INTO inputs VALUES ('m.a_test', 'h1'), ('m.b_test', 'h2')"))
  assert(db:exec("INSERT INTO test_inputs VALUES ('h1', 1, 'line', '3'), ('h1', 2, 'requires', 'nest'), " ..
      "('h1', 3, 'requires', 'proc'), ('h2', 1, 'host', '/proc')"))
  local found = assert(tree_checks.requirements(db))
  local needs = found["m.a_test"]
  assert(needs, "m.a_test has requirements")
  assert(#needs == 2 and needs[1] == "nest" and needs[2] == "proc")
  assert(found["m.b_test"] == nil)
  local _, _ = db:close()
end

--- A test that declares `tool` or `store`, or `requires` "portable", is
--- the portable launcher's to read; the unsealed modules are those.
local function test_the_unsealed_modules_are_those_declaring_a_launcher_reader()
  local db = assert(Sqlite.open(":memory:", { writable = true }))
  assert(db:exec("CREATE TABLE inputs (path TEXT, source_hash TEXT)"))
  assert(db:exec("CREATE TABLE test_inputs (source_hash TEXT, ordinal INTEGER, field TEXT, value TEXT)"))
  assert(db:exec("INSERT INTO inputs VALUES ('m.a_test', 'h1'), ('m.b_test', 'h2'), " ..
      "('m.c_test', 'h3'), ('m.d_test', 'h4'), ('m.e_test', 'h5')"))
  assert(db:exec("INSERT INTO test_inputs VALUES ('h1', 1, 'tool', 'true'), ('h2', 1, 'store', 'true'), " ..
      "('h3', 1, 'requires', 'portable'), ('h4', 1, 'requires', 'proc'), ('h5', 1, 'nests', 'true')"))
  local found = assert(tree_checks.unsealed(db))
  assert(found["m.a_test"] == true and found["m.b_test"] == true and found["m.c_test"] == true)
  assert(found["m.d_test"] ~= true and found["m.e_test"] ~= true)
  local _, _ = db:close()
end

--- A sealed test that names the launcher's contract is refused until
--- something keys it by the launcher (it declares it) or an allowance
--- says it reads none, and an allowance for a test that no longer names
--- it is stale. A comment and a call to Proc.relaunch are no mention.
local function test_a_sealed_test_naming_the_launcher_is_refused(dir: string)
  local db = fixture.database(dir, {
    ["build/reads_test.tl"] = source("local env = os.getenv(\"COSMIC_PORTABLE_ARTIFACT_FD\")"),
    ["build/argv_test.tl"] = source("local on = argv[2] == \"--artifact\""),
    ["build/declared_test.tl"] = source("local fd = os.getenv(\"COSMIC_PORTABLE_CORE_FD\")"),
    ["build/quiet_test.tl"] = source("-- COSMIC_PORTABLE_CORE_FD, said in a comment",
      "local launched = Proc.relaunch()"),
  })
  local found = tree_checks.sealed_launch(db, { ["build.declared_test"] = true }, {})
  assert(#found == 2, table.concat(found, "\n"))
  assert(support.nth(found, 1):find("^build%.argv_test names the portable launcher's contract") ~= nil, found[1])
  assert(support.nth(found, 2):find("^build%.reads_test names the portable launcher's contract") ~= nil, found[2])
  found = tree_checks.sealed_launch(db, { ["build.declared_test"] = true },
    { ["build.argv_test"] = "a made-up start", ["build.reads_test"] = "text only",
      ["build.quiet_test"] = "wrongly excused" })
  assert(#found == 1 and found[1]:find("^build%.quiet_test is excused") ~= nil, table.concat(found, "\n"))
end

--- Every check runs, each line named by its check: a projection with
--- none of the tree's own anchors, stand-ins, docs or quieted records
--- fails each check that expects them, and a public member with no doc
--- comment fails the rendered docs.
local function test_a_run_names_each_check(dir: string)
  local db = fixture.database(dir, {
    ["build/thing.tl"] = source("local record thing", "end", "return thing"),
    ["cosmic/bare.tl"] = source("--- Bare.", "local record Bare", "end",
      "function Bare.go()", "end", "return Bare"),
  })
  local seen: mut {string: boolean} = {}
  for _, line in ipairs(tree_checks.run(db, "")) do
    seen[line:match("^([^:]+): ") or line] = true
  end
  for _, name in ipairs({ "exports", "doc anchors", "compiler readers", "stand-ins",
      "docs queries", "quieted", "rendered docs", "doc references" }) do
    assert(seen[name], name .. " reported nothing on a projection that has none of the tree")
  end
end

--- A public `---` doc that carries a TODO or cites the build, the C or an
--- internal module is refused with the rule and the fix; a `--` comment
--- may hold both, a private symbol's doc is not shown, nor is a code
--- span's definition, and an exemption whose doc no longer breaks the
--- rule is stale.
local function test_a_public_doc_naming_internals_is_refused(dir: string)
  local db = fixture.database(dir, {
    ["cosmic/thing.tl"] = source(
      "--- Things.",
      "local record thing",
      "end",
      "--- Does it, as build/thing.tl does.",
      "function thing.a() end",
      "--- Does it. TODO: do more.",
      "function thing.b() end",
      "--- Does it through core/thing.c and cosmic.internal.thing.",
      "function thing.c() end",
      "--- Does it as build.thing does, or vendor/thing, not build.zig.",
      "function thing.d() end",
      "--- Does it plainly (127.a.b.c, <errno.h>, e.g. `o/build.db`, and the build.then it did).",
      "function thing.e() end",
      "-- TODO: do more, as build/thing.tl does.",
      "",
      "function thing.f() end",
      "--- Private, in core/thing.c.",
      "local function g() end",
      "return thing"),
    ["build/thing.tl"] = source("local record thing", "end", "return thing"),
    ["build/zig.tl"] = source("local record zig", "end", "return zig"),
  })
  local found = tree_checks.public_docs(db, {})
  local text = table.concat(found, "\n")
  assert(#found == 6, text)
  assert(found[1]:find("^cosmic/thing%.tl:5: cosmic%.thing a: .*`build/thing%.tl`.*%(path rule%) %-%- say what a caller needs") ~=
      nil, text)
  assert(support.nth(found, 2):find("^cosmic/thing%.tl:7: .*`TODO:` %(todo rule%).*`%-%-` comment") ~= nil, text)
  assert(support.nth(found, 3):find("^cosmic/thing%.tl:9: .*`core/thing%.c`") ~= nil, text)
  assert(support.nth(found, 4):find("^cosmic/thing%.tl:9: .*`cosmic%.internal%.thing%.`") ~= nil, text)
  assert(support.nth(found, 5):find("^cosmic/thing%.tl:11: .*`build%.thing`") ~= nil, text)
  assert(support.nth(found, 6):find("^cosmic/thing%.tl:11: .*`vendor/thing,`") ~= nil, text)
  local excused = {
    ["cosmic.thing a path"] = "a",
    ["cosmic.thing b todo"] = "b",
    ["cosmic.thing c path"] = "c",
    ["cosmic.thing d path"] = "d",
    ["cosmic.thing e path"] = "unneeded",
  }
  found = tree_checks.public_docs(db, excused)
  assert(#found == 1 and found[1]:find("^cosmic.thing e path: exempt, but") ~= nil,
    table.concat(found, "\n"))
  local clean = fixture.database(dir, {
    ["cosmic/thing.tl"] = source(
      "--- Things.",
      "local record thing",
      "end",
      "--- Does it, and says what a caller needs, as [`thing.b`] does.",
      "---",
      "--- [`thing.b`]: ../core/thing.c",
      "function thing.a() end",
      "--- Does it.",
      "function thing.b() end",
      "return thing"),
    ["build/internal.tl"] = source(
      "--- Cites core/thing.c, TODO: freely.",
      "local record internal",
      "end",
      "return internal"),
  })
  found = tree_checks.public_docs(clean, {})
  assert(#found == 0, table.concat(found, "\n"))
end

--- The checkers that read the sources for the plurals.
--- A literal plural after a number is refused -- joined by `..` to a
--- length, `tostring(...)` or a literal, or after a `%d` -- with the fix;
--- [`plural.count`], a verb after a number, a label (`at byte %d`), a
--- comment and a test source pass, and an exemption nothing needs is stale.
local function test_a_literal_plural_after_a_number_is_refused(dir: string)
  local db = fixture.database(dir, {
    ["build/count.tl"] = source(
      "local record count",
      "end",
      "function count.a(rows: {string}): string",
      "  return #rows .. \" tests\"",
      "end",
      "function count.b(n: integer): string",
      "  return \"has \" .. tostring(n) ..",
      "    \" files in it\"",
      "end",
      "function count.c(n: integer): string",
      "  return (\"%d of %d tests\"):format(n, n)",
      "end",
      "function count.d(a: integer, b: integer): string",
      "  return (a - b) .. \" rows\"",
      "end",
      "function count.e(stores: integer): string",
      "  return stores .. \" closure stores\"",
      "end",
      "return count"),
    ["build/fine.tl"] = source(
      "local plural = { count = function(n: integer, s: string): string return s end }",
      "local record fine",
      "end",
      "function fine.a(rows: {string}, at: integer, name: string): string",
      "  -- #rows .. \" tests\" in a comment",
      "  return plural.count(#rows, \"test\") .. name .. \" is here\" ..",
      "    (\"at byte %d needs\"):format(at) .. (\"%d of %s\"):format(at, name) ..",
      "    (\"iters=%d\"):format(at) .. #rows .. \" is the count\" .. name .. \" needs it\"",
      "end",
      "return fine"),
    ["build/fine_test.tl"] = source(
      "local function test_x(rows: {string})",
      "  local _ = #rows .. \" tests\"",
      "end"),
  })
  local found = tree_checks.plurals(db, {}, {})
  local text = table.concat(found, "\n")
  assert(#found == 5, text)
  assert(found[1]:find("^build/count%.tl:4: .*`tests`.*plural%.count") ~= nil, text)
  assert(support.nth(found, 2):find("^build/count%.tl:8: .*`files`") ~= nil, text)
  assert(support.nth(found, 3):find("^build/count%.tl:11: .*`tests`.*plural%.noun") ~= nil, text)
  assert(support.nth(found, 4):find("^build/count%.tl:14: .*`rows`") ~= nil, text)
  assert(support.nth(found, 5):find("^build/count%.tl:17: .*`stores`") ~= nil, text)
  found = tree_checks.plurals(db, { { "ci/x.tl", "return #arg .. \" arguments\"\n" } }, {
    ["build/count.tl:tests"] = "always many", ["build/count.tl:files"] = "always many",
    ["build/count.tl:rows"] = "always many", ["build/count.tl:stores"] = "always many",
    ["build/fine.tl:tests"] = "unneeded" })
  assert(#found == 2 and found[1]:find("^ci/x%.tl:1: .*`arguments`") ~= nil and
      support.nth(found, 2):find("^build/fine%.tl:tests: exempt, but nothing") ~= nil, table.concat(found, "\n"))
  -- A source with an optional type is read as written.
  local newer = { { "ci/cosmic_ci/x.tl", "local function f(rows: {string}, x: string?): string\n" ..
      "  return #rows .. \" tests\"\nend\nreturn f\n" } }
  local second = tree_checks.plurals(db, newer, {})
  local last = assert(second[#second])
  assert(last:find("^ci/cosmic_ci/x%.tl:2: .*`tests`") ~= nil, table.concat(second, "\n"))
end

--- The plurals found before the checks stand for a file's only while its text is the one read: a file whose text has moved
--- since is read again, a file the check does not read is found nothing in, and a source that does not parse is found
--- nothing in and is named by the check.
local function test_plurals_found_before_stand_for_the_same_text(dir: string)
  local text = source("local n = 2", "return n .. \" tests\"")
  local db = fixture.database(dir, {
    ["build/count.tl"] = text,
    ["build/moved.tl"] = source("local n = 2", "return n .. \" rows\""),
  })
  assert(tree_checks.plurals_in("build/count_test.tl", text) == nil)
  assert(tree_checks.plurals_in("examples/count.tl", text) == nil)
  assert(tree_checks.plurals_in("build/count.tl", "if x then\n") == nil)
  local counted = assert(tree_checks.plurals_in("build/count.tl", text))
  assert(counted.source == text and #counted.sites == 1)
  local site = assert(counted.sites[1])
  assert(site[1] == "2" and site[2] == "tests", table.concat(site, "|"))
  local edited: mut {string} = {}
  for at, part in ipairs(site) do edited[#edited + 1] = if at == 2 then "kept" else part end end
  local kept: tree_checks.Plurals = { source = counted.source, sites = { edited } }
  local read: {string: tree_checks.Plurals} = {
    ["build/count.tl"] = kept,
    ["build/moved.tl"] = { source = "return 1\n", sites = {} },
  }
  local found = tree_checks.plurals(db, {}, {}, read)
  local all = table.concat(found, "\n")
  assert(#found == 2, all)
  assert(assert(found[1]):find("^build/count%.tl:2: .*`kept`") ~= nil, all)
  assert(assert(found[2]):find("^build/moved%.tl:2: .*`rows`") ~= nil, all)
  local unread = tree_checks.plurals(db, { { "ci/cosmic_ci/bad.tl", "if x then\n" } }, {})
  assert(assert(unread[#unread]):find("^ci/cosmic_ci/bad%.tl: cannot read it to check its plurals: ") ~= nil,
    table.concat(unread, "\n"))
end

--- The `ci/` sources the plural check reads are the modules of
--- `ci/cosmic_ci`, tests left out; `ci/fixtures` are all tests.
local function test_ci_sources_are_the_non_test_modules_of_cosmic_ci(dir: string)
  local base = dir .. "/tree/ci/cosmic_ci"
  assert(Fs.mkdirs(base .. "/sub"))
  assert(Fs.write(base .. "/b.tl", "return 2\n"))
  assert(Fs.write(base .. "/a.tl", "return 1\n"))
  assert(Fs.write(base .. "/a_test.tl", "return 3\n"))
  assert(Fs.write(base .. "/sub/c.tl", "return 4\n"))
  assert(Fs.write(base .. "/notes.md", "no\n"))
  local found = tree_checks.ci_sources(dir .. "/tree")
  local names: mut {string} = {}
  for _, row in ipairs(found) do
    names[#names + 1] = support.nth(row, 1) .. "=" .. support.nth(row, 2):gsub("\n", "")
  end
  assert(table.concat(names, ",") == "ci/cosmic_ci/a.tl=return 1,ci/cosmic_ci/b.tl=return 2,ci/cosmic_ci/sub/c.tl=return 4",
    table.concat(names, ","))
  assert(#tree_checks.ci_sources(dir .. "/nowhere") == 0)
end

--- A file under `ci/testdata` that does not type-check is named with its
--- line; a test module is not refused for functions nothing calls, any other file for an unused one.
local function test_ci_testdata_type_errors_are_named(dir: string)
  local base = dir .. "/tree/ci/testdata/sub"
  assert(Fs.mkdirs(base))
  assert(Fs.write(base .. "/good_test.tl", "local function test_x()\n  assert(true)\nend\n"))
  assert(Fs.write(base .. "/bad.tl", "local x: integer = \"s\"\nreturn x\n"))
  assert(Fs.write(base .. "/loose.tl", "local function helper() end\nreturn 1\n"))
  assert(Fs.write(base .. "/foreign.tl", "local m = require(\"cosmic_ci.nowhere\")\nreturn m\n"))
  local found = tree_checks.ci_testdata(dir .. "/tree")
  local all = table.concat(found, "\n")
  assert(found[1] ~= nil and support.nth(found, 1):find("^ci/testdata/sub/bad%.tl:1:") ~= nil, all)
  assert(all:find("ci/testdata/sub/foreign.tl", 1, true) ~= nil, all)
  assert(all:find("good_test", 1, true) == nil, all)
  assert(all:find("ci/testdata/sub/loose.tl:1:", 1, true) ~= nil, all)
  assert(#tree_checks.ci_testdata(dir .. "/nowhere") == 0)
end

--- A guide under doc/guides that is neither a user guide nor named
--- internal would silently not ship: the check names it.
local function test_a_guide_in_neither_list_is_refused()
  local db = assert(Sqlite.memory())
  for _, statement in ipairs(schema.create("")) do
    assert(db:exec(statement))
  end
  for _, module in ipairs({ "doc.guides.quickstart", "doc.guides.portable-runtime" }) do
    assert(Sqlite.run(db,
      "INSERT INTO modules (path, file, kind, source_hash, key, source, bytecode, tests) " ..
        "VALUES (?1, ?1, 'test', '', '', '', '', '')", { { text = module } }))
  end
  local found = tree_checks.guides(db)
  assert(#found == 0, table.concat(found, "\n"))
  assert(Sqlite.run(db,
    "INSERT INTO modules (path, file, kind, source_hash, key, source, bytecode, tests) " ..
      "VALUES ('doc.guides.newcomer', 'f', 'test', '', '', '', '', '')"))
  found = tree_checks.guides(db)
  assert(#found == 1 and found[1]:find("^doc/guides/newcomer%.md is in neither") ~= nil,
    table.concat(found, "\n"))
end

--- An unused local is as unused as an unused import: a test module under
--- `ci/testdata` is not refused for one, and any other file is.
local function test_an_unused_local_in_ci_testdata_follows_the_unused_rule(dir: string)
  local base = dir .. "/tree/ci/testdata/sub"
  assert(Fs.mkdirs(base))
  assert(Fs.write(base .. "/zz_test.tl", "local function test_x()\n  local lonely = 1\n  assert(true)\nend\n"))
  assert(Fs.write(base .. "/label.tl", "do\n  local lonely = 1\nend\nreturn 1\n"))
  local found = tree_checks.ci_testdata(dir .. "/tree")
  local all = table.concat(found, "\n")
  assert(all:find("zz_test", 1, true) == nil, all)
  assert(all:find("ci/testdata/sub/label.tl:2:", 1, true) ~= nil, all)
end

--- A name the scope builder cannot resolve, and a declaration that hides one, are refused past
--- their pins with the place, the message and the fix; the globals are the ones the tree's
--- declaration file declares; the fork's files are not read; a pin above what the tree has is
--- told to fall.
local function test_a_name_the_scope_builder_cannot_resolve_is_refused_with_its_fix_and_a_marker_holds_neither_closed_code(dir: string)
  local root = dir .. "/scoperoot"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/lang"))
  assert(Fs.mkdirs(root .. "/vendor"))
  assert(Fs.write(root .. "/lang/stdlib.d.tl", source("global print: integer")))
  assert(Fs.write(root .. "/build/ok.tl", source("local x = 1", "print(x)", "return x")))
  assert(Fs.write(root .. "/build/bad.tl", source("local x = 1", "local x = 2", "print(y)", "return x")))
  assert(Fs.write(root .. "/vendor/v.tl", source("print(unknown_to_vendor)")))
  local found = table.concat(tree_checks.scoped(root), "\n")
  assert(found:find("build/bad.tl:2:7: variable `x` shadows the variable `x` declared at 1:7 (shadows): to change the existing", 1, true) and
      found:find("build/bad.tl:3:7: `y` is not declared (unknown_variable): declare it with `local y = ...`", 1, true) and
      found:find("build/bad.tl: 1 error of shadows in its scopes on line 2, marked 0; follow the fix above rather than add a marker",
        1, true),
    found)
  assert(not found:find("ok.tl", 1, true) and not found:find("lang/stdlib.d.tl", 1, true) and
      not found:find("vendor", 1, true) and not found:find("print", 1, true), found)
  -- both codes are closed: no marker holds them, and a marker on their lines is refused for it
  assert(Fs.write(root .. "/build/bad.tl", source("local x = 1", "local x = 2 -- scoped: shadows", "print(y) -- scoped: unknown_variable",
    "return x")))
  local marked = table.concat(tree_checks.scoped(root), "\n")
  assert(marked:find("build/bad.tl:2: shadows is closed", 1, true) and marked:find("build/bad.tl:3: unknown_variable is closed", 1, true) and
      marked:find("(shadows)", 1, true) and marked:find("(unknown_variable)", 1, true), marked)
end

--- A declaration the lowering refuses is listed with the place, the message and the fix, unless a marker holds it; a
--- module imported by a literal name is found; a pin above what the
--- tree has is told to fall.
local function test_a_declaration_the_lowering_refuses_is_refused_with_its_fix_and_held_by_its_marker(dir: string)
  local root = dir .. "/declareroot"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shape.tl", source("local record Shape", "  n: integer", "end", "return Shape")))
  assert(Fs.write(root .. "/build/ok.tl", source("local type Shape = require(\"lib.shape\")", "local x: Shape", "return x")))
  assert(Fs.write(root .. "/build/bad.tl", source("local type Shape = require(\"lib.shape\")",
    "local x: {Shape: string?}", "local y: {number: integer}", "local z: {string?}", "return x")))
  local found = table.concat(tree_checks.declared(root), "\n")
  assert(found:find("build/bad.tl:3:11: a map is keyed by `integer`, not `number`", 1, true) and
      found:find("(float_key): key by `integer`", 1, true) and
      found:find("build/bad.tl: 1 error of float_key in its declarations on line 3, marked 0; follow the fix above rather than add a marker",
        1, true),
    found)
  assert(found:find("array_of_optional", 1, true), found)
  assert(not found:find("ok.tl", 1, true), found)
  local held = source("local type Shape = require(\"lib.shape\")", "local x: {Shape: string?} -- declared: array_of_optional",
    "local y: {number: integer} -- declared: float_key", "local z: {string?} -- declared: array_of_optional", "return x")
  assert(Fs.write(root .. "/build/bad.tl", held))
  local only = tree_checks.declared(root)
  assert(#only == 0, table.concat(only, "\n"))
  -- a marker whose finding is gone is stale, and one for the wrong code holds nothing
  assert(Fs.write(root .. "/build/bad.tl", (held:gsub("{string%?} %-%- declared: array_of_optional", "{string} -- declared: array_of_optional"))))
  local stale = table.concat(tree_checks.declared(root), "\n")
  assert(stale:find("build/bad.tl:4: its marker holds 1 finding of array_of_optional that the line no longer has", 1, true), stale)
  assert(Fs.write(root .. "/build/bad.tl", (held:gsub("declared: float_key", "declared: key_type"))))
  local wrong = table.concat(tree_checks.declared(root), "\n")
  assert(wrong:find("(float_key)", 1, true) and wrong:find("its marker holds 1 finding of key_type", 1, true), wrong)
end

--- `ci/` is a project of its own: its modules are named from its own root and checked there, so the tree's checks read none of
--- its files, whatever they hold, and a file of the tree that requires into it by the name `ci/` gives it is refused.
local function test_the_trees_checks_read_no_file_of_ci_and_refuse_a_require_into_it(dir: string)
  local root = dir .. "/foreigner"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/ci/cosmic_ci"))
  assert(Fs.write(root .. "/ci/cosmic_ci/shape.tl", source("local record Shape", "  n: integer", "end", "return Shape")))
  assert(Fs.write(root .. "/ci/cosmic_ci/bad.tl", source("print(unknown_to_the_tree)", "local n: integer = \"s\"", "return n")))
  assert(Fs.write(root .. "/build/into.tl", source("local Shape = require(\"cosmic_ci.shape\")", "return Shape")))
  assert(Fs.write(root .. "/build/whole.tl", source("local Shape = require(\"ci.cosmic_ci.shape\")", "return Shape")))
  local found = table.concat(tree_checks.checked(root), "\n")
  assert(found:find("build/into.tl:1:", 1, true) and found:find("the project has no module `cosmic_ci.shape`", 1, true) and
      found:find("(require_unknown)", 1, true), found)
  assert(found:find("build/whole.tl:1:", 1, true) and found:find("the project has no module `ci.cosmic_ci.shape`", 1, true), found)
  assert(found:find("ci/cosmic_ci/bad.tl", 1, true) == nil, found)
  assert(table.concat(tree_checks.scoped(root), "\n"):find("ci/", 1, true) == nil)
  assert(table.concat(tree_checks.declared(root), "\n"):find("ci/", 1, true) == nil)
end

--- Files that require each other reach the same modules, and keep their own answers.
local function test_files_that_require_each_other_keep_their_own_answers_in_the_memo(dir: string)
  local root = dir .. "/declarecycle"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/a.tl", source("local b = require(\"build.b\")", "local x: {number: integer}", "return b")))
  assert(Fs.write(root .. "/build/b.tl", source("local a = require(\"build.a\")", "local y: {any: integer}", "return a")))
  local memo = assert(Sqlite.memory())
  local plain = table.concat(tree_checks.declared(root, memo), "\n")
  assert(plain:find("build/a.tl:2:", 1, true) and plain:find("build/b.tl:2:", 1, true), plain)
  assert(table.concat(tree_checks.declared(root, memo), "\n") == plain)
  assert(memo:close())
end

--- A file whose translation does not parse is lowered for the files that import it and counts nothing of its own
--- and the files of a `testdata` directory are not read.
local function test_a_file_that_does_not_parse_and_a_testdata_file_count_no_errors_of_their_own(dir: string)
  local root = dir .. "/declarebroken"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/eval/testdata"))
  assert(Fs.write(root .. "/build/broken.tl", source("local record R", "  n: integer", "end", "local t: {{string, integer}}",
    "local x: {number: integer}", "return R")))
  assert(Fs.write(root .. "/build/user.tl", source("local type R = require(\"build.broken\")", "local y: R", "local z: {R: integer}", "return y")))
  assert(Fs.write(root .. "/eval/testdata/t.tl", source("local x: {number: integer}", "return x")))
  assert(Fs.write(root .. "/eval/testdata/u.tl", source("local type Gone = require(\"gone\")", "local g: Gone", "return g")))
  assert(#tree_checks.declared(root) == 0, table.concat(tree_checks.declared(root), "\n"))
end

--- The answer for a file is kept under the sources of every module it requires: a change to a module it
--- imports, however far, misses; an unrelated file does not.
local function test_a_memo_answers_the_declaration_check_until_a_module_a_file_requires_changes(dir: string)
  local root = dir .. "/declarememo"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/lang"))
  assert(Fs.write(root .. "/lang/declarations.tl", "-- one\n"))
  assert(Fs.write(root .. "/build/base.tl", source("local record Base", "  n: integer", "end", "return Base")))
  assert(Fs.write(root .. "/build/mid.tl", source("local type Base = require(\"build.base\")", "local record Mid", "  b: Base", "end", "return Mid")))
  assert(Fs.write(root .. "/build/top.tl", source("local type Mid = require(\"build.mid\")", "local x: {number: Mid}", "return x")))
  assert(Fs.write(root .. "/build/alone.tl", source("local x: {number: integer}", "return x")))
  local memo = assert(Sqlite.memory())
  local plain = table.concat(tree_checks.declared(root), "\n")
  assert(plain:find("build/top.tl:2:", 1, true) and plain:find("build/alone.tl:1:", 1, true), plain)
  assert(table.concat(tree_checks.declared(root, memo), "\n") == plain)
  local count = assert(Sqlite.rows(memo, "SELECT count(*) FROM check_memo WHERE kind = 'declared'"))
  assert(support.nth(count, 1):integer(1) == 5, "the four files and the code")
  -- Plant another answer under every key: a run that finds it did not lower.
  assert(Sqlite.run(memo, "UPDATE check_memo SET value = ?1 WHERE kind = 'declared'", { { text = "N\nE\tkey_type\t7\t9\tplanted\tdo it" } }))
  local hit = table.concat(tree_checks.declared(root, memo), "\n")
  assert(hit:find("build/top.tl:7:9: planted (key_type): do it", 1, true) and not hit:find("float_key", 1, true), hit)
  -- A module far below changed: the files that require it, through others, are lowered again; one that does not is not.
  assert(Fs.write(root .. "/build/base.tl", source("local record Base", "  m: integer", "end", "return Base")))
  local again = table.concat(tree_checks.declared(root, memo), "\n")
  assert(again:find("build/top.tl:2:", 1, true) and again:find("build/mid.tl", 1, true) == nil, again)
  assert(again:find("build/alone.tl:7:9: planted", 1, true), again)
  assert(memo:close())
end

--- What a file reads of a module it requires is its tokens, not its comments or its blank lines: an edit to either of a
--- module misses the module's own answer alone, and an edit to a token misses the files that require it as well.
local function test_a_comment_in_a_module_misses_its_own_answer_and_no_other_file_of_the_declaration_check(dir: string)
  local root = dir .. "/declareshape"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/base.tl", source("local record Base", "  n: integer", "end", "return Base")))
  assert(Fs.write(root .. "/build/mid.tl", source("local type Base = require(\"build.base\")", "local record Mid", "  b: Base", "end", "return Mid")))
  assert(Fs.write(root .. "/build/top.tl", source("local type Mid = require(\"build.mid\")", "local x: {number: Mid}", "return x")))
  local memo = assert(Sqlite.memory())
  local plain = table.concat(tree_checks.declared(root, memo), "\n")
  assert(plain:find("build/top.tl:2:", 1, true), plain)
  assert(Sqlite.run(memo, "UPDATE check_memo SET value = ?1 WHERE kind = 'declared'", { { text = "N\nE\tkey_type\t7\t9\tplanted\tdo it" } }))
  -- A comment, a doc comment and blank lines in the module far below: only its own file is lowered again.
  assert(Fs.write(root .. "/build/base.tl", source("-- a comment", "local record Base", "  --- the count", "  n: integer -- here", "end", "", "", "return Base")))
  local commented = table.concat(tree_checks.declared(root, memo), "\n")
  assert(commented:find("build/top.tl:7:9: planted", 1, true) and commented:find("build/mid.tl:7:9: planted", 1, true), commented)
  assert(commented:find("build/base.tl", 1, true) == nil, "the module itself was answered from the memo: " .. commented)
  -- A token of it changed: the files that require it, through another, are lowered again.
  assert(Fs.write(root .. "/build/base.tl", source("local record Base", "  m: integer", "end", "return Base")))
  local changed = table.concat(tree_checks.declared(root, memo), "\n")
  assert(changed:find("build/top.tl:2:", 1, true) and not changed:find("planted", 1, true), changed)
  assert(memo:close())
end

--- Each file whose code or declarations decide what the check finds is in the memo's salt: a change to any of
--- them misses.
local function test_a_change_to_the_code_or_the_declarations_the_declaration_check_reads_misses_the_memo(dir: string)
  local root = dir .. "/declaresalt"
  local salted: {string} = { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl", "lang/truthy.tl",
    "lang/types.tl", "lang/relation.tl", "lang/declarations.tl", "lang/prelude.d.tl", "lang/stdlib.d.tl",
    "build/check_memo.tl", "build/tree_checks.tl" }
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/lang"))
  for _, path in ipairs(salted) do
    assert(Fs.write(root .. "/" .. path, "-- one\n"))
  end
  assert(Fs.write(root .. "/build/bad.tl", source("local x: {number: integer}", "return x")))
  local memo = assert(Sqlite.memory())
  local plain = table.concat(tree_checks.declared(root, memo), "\n")
  assert(plain:find("(float_key)", 1, true), plain)
  for _, path in ipairs(salted) do
    assert(Sqlite.run(memo, "UPDATE check_memo SET value = ?1", { { text = "N\nE\tkey_type\t7\t9\tplanted\tdo it" } }))
    local hit = table.concat(tree_checks.declared(root, memo), "\n")
    assert(hit:find("planted", 1, true), path .. " moved the key by itself: " .. hit)
    assert(Fs.write(root .. "/" .. path, "-- two " .. path .. "\n"))
    local missed = table.concat(tree_checks.declared(root, memo), "\n")
    assert(missed:find("(float_key)", 1, true) and not missed:find("planted", 1, true), path .. " is not in the salt: " .. missed)
  end
  assert(memo:close())
end

--- A mistake in a body is listed with the place, the message and the fix, unless a marker holds it, in a file that imports the
--- declarations it uses; the fork's file, a declaration file, a file whose translation does not parse and the files of
--- a `testdata` directory are not checked; a marker above what the tree has is stale.
local function test_a_mistake_in_a_body_is_refused_with_its_fix_and_held_by_its_marker(dir: string)
  local root = dir .. "/checkroot"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/eval/testdata"))
  assert(Fs.write(root .. "/build/shape.tl", source("local record Shape", "  n: integer", "end", "return Shape")))
  assert(Fs.write(root .. "/build/ok.tl", source("local Shape = require(\"build.shape\")", "local s: Shape = { n = 1 }")))
  assert(Fs.write(root .. "/build/bad.tl", source("local Shape = require(\"build.shape\")", "local s: Shape = { n = 1.5 }",
    "local t: integer = 3.5")))
  assert(Fs.write(root .. "/build/broken.tl", source("local t: {{string, integer}}", "local u: integer = 3.5", "return t")))
  assert(Fs.write(root .. "/build/types.d.tl", source("global record Gone", "  n: integer", "end")))
  assert(Fs.write(root .. "/eval/testdata/t.tl", source("local u: integer = 3.5", "return u")))
  local found = table.concat(tree_checks.checked(root), "\n")
  assert(found:find("build/bad.tl:2:24: `1.5` is `number`, where `integer` is wanted as the field `n` of `Shape`", 1, true) and
      found:find("(not_assignable): convert with `math.tointeger(1.5)` or `math.floor(1.5)`", 1, true) and
      found:find("build/bad.tl:3:20:", 1, true) and
      found:find("build/bad.tl: 1 error of not_assignable in its bodies on line 3, marked 0; follow the fix above rather than add a marker",
        1, true),
    found)
  assert(not found:find("ok.tl", 1, true) and not found:find("broken.tl", 1, true) and
      not found:find("testdata", 1, true), found)
  assert(Fs.write(root .. "/build/bad.tl", source("local Shape = require(\"build.shape\")",
    "local s: Shape = { n = 1.5 } -- checked: not_assignable", "local t: integer = 3.5 -- checked: not_assignable")))
  local held = tree_checks.checked(root)
  assert(#held == 0, table.concat(held, "\n"))
  -- the count of a marker is the findings it holds: one more is stale, one less leaves the line refused
  assert(Fs.write(root .. "/build/bad.tl", source("local Shape = require(\"build.shape\")",
    "local s: Shape = { n = 1.5 } -- checked: not_assignable*2", "local t: integer = 3.5")))
  local both = table.concat(tree_checks.checked(root), "\n")
  assert(both:find("build/bad.tl:2: its marker holds 1 finding of not_assignable", 1, true) and
      both:find("1 error of not_assignable in its bodies on line 3, marked 0", 1, true), both)
end

--- The phases of a check that lowered files are timed, and a run the memo answers times none.
local function test_the_phases_of_a_check_are_timed_for_the_files_the_memo_lacked(dir: string)
  local root = dir .. "/checkphases"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/a.tl", source("local n: integer = 3.5")))
  local memo = assert(Sqlite.memory())
  local phases: {string: integer} = {}
  local first = table.concat(tree_checks.checked(root, memo, phases), "\n")
  assert(phases.prepare > 0 and phases.lower > 0 and phases.check > 0, first) -- checked: map_field*3
  local again: {string: integer} = {}
  assert(table.concat(tree_checks.checked(root, memo, again), "\n") == first)
  assert(again.check == nil) -- checked: map_field
  assert(memo:close())
end

--- The answer for a file is kept under the sources of every module it requires and of the checker: a change to a
--- module it imports, however far, or to the checker misses; an unrelated file does not.
local function test_a_memo_answers_the_body_check_until_a_module_a_file_requires_or_the_checker_changes(dir: string)
  local root = dir .. "/checkmemo"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/lang"))
  assert(Fs.write(root .. "/build/base.tl", source("local record Base", "  n: integer", "end", "return Base")))
  assert(Fs.write(root .. "/build/top.tl", source("local Base = require(\"build.base\")", "local b: Base = { n = 1.5 }")))
  assert(Fs.write(root .. "/build/alone.tl", source("local x: integer = 1.5")))
  local memo = assert(Sqlite.memory())
  local plain = table.concat(tree_checks.checked(root, memo), "\n")
  assert(plain:find("build/top.tl:2:", 1, true) and plain:find("build/alone.tl:1:", 1, true), plain)
  local count = assert(Sqlite.rows(memo, "SELECT count(*) FROM check_memo WHERE kind = 'checked'"))
  assert(support.nth(count, 1):integer(1) == 3, "the three files: " .. tostring(support.nth(count, 1):integer(1)))
  assert(Sqlite.run(memo, "UPDATE check_memo SET value = ?1 WHERE kind = 'checked'", { { text = "N\nE\tnil_not_allowed\t7\t9\tplanted\tdo it" } }))
  local hit = table.concat(tree_checks.checked(root, memo), "\n")
  assert(hit:find("build/top.tl:7:9: planted (nil_not_allowed): do it", 1, true) and not hit:find("not_assignable", 1, true), hit)
  assert(Fs.write(root .. "/build/base.tl", source("local record Base", "  n: integer", "  m: integer", "end", "return Base")))
  local again = table.concat(tree_checks.checked(root, memo), "\n")
  assert(again:find("build/top.tl:2:", 1, true) and again:find("not_assignable", 1, true), again)
  assert(again:find("build/alone.tl:7:9: planted", 1, true), again)
  assert(memo:close())
end

--- Each file whose code or declarations decide what the check finds is in the memo's salt.
local function test_a_change_to_the_code_or_the_declarations_the_body_check_reads_misses_the_memo(dir: string)
  local root = dir .. "/checksalt"
  local salted: {string} = { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl", "lang/truthy.tl",
    "lang/types.tl", "lang/relation.tl", "lang/declarations.tl", "lang/check.tl", "lang/check_codes.tl",
    "lang/prelude.d.tl", "lang/stdlib.d.tl", "build/check_memo.tl", "build/tree_checks.tl" }
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/lang"))
  for _, path in ipairs(salted) do
    assert(Fs.write(root .. "/" .. path, "-- one\n"))
  end
  assert(Fs.write(root .. "/build/bad.tl", source("local x: integer = 1.5")))
  local memo = assert(Sqlite.memory())
  local plain = table.concat(tree_checks.checked(root, memo), "\n")
  assert(plain:find("(not_assignable)", 1, true), plain)
  for _, path in ipairs(salted) do
    assert(Sqlite.run(memo, "UPDATE check_memo SET value = ?1", { { text = "N\nE\tnil_not_allowed\t7\t9\tplanted\tdo it" } }))
    local hit = table.concat(tree_checks.checked(root, memo), "\n")
    assert(hit:find("planted", 1, true), path .. " moved the key by itself: " .. hit)
    assert(Fs.write(root .. "/" .. path, "-- two " .. path .. "\n"))
    local missed = table.concat(tree_checks.checked(root, memo), "\n")
    assert(missed:find("(not_assignable)", 1, true) and not missed:find("planted", 1, true), path .. " is not in the salt: " .. missed)
  end
  assert(memo:close())
end

--- A file that has not changed is not scoped again: its findings come from the memo. A change to
--- the file, the declarations or the code that scopes it is a miss.
local function test_a_memo_answers_the_scope_check_for_a_file_that_has_not_changed(dir: string)
  local root = dir .. "/scopememo"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/lang"))
  assert(Fs.write(root .. "/lang/scopes.tl", "-- one\n"))
  assert(Fs.write(root .. "/lang/stdlib.d.tl", source("global print: integer")))
  assert(Fs.write(root .. "/build/bad.tl", source("print(y)", "return 1")))
  local memo = assert(Sqlite.memory())
  local plain = table.concat(tree_checks.scoped(root), "\n")
  assert(plain:find("(unknown_variable)", 1, true), plain)
  assert(table.concat(tree_checks.scoped(root, memo), "\n") == plain)
  local count = assert(Sqlite.rows(memo, "SELECT count(*) FROM check_memo WHERE kind = 'scoped'"))
  assert(support.nth(count, 1):integer(1) == 2, "the two files")
  -- Plant another answer under the key: a run that finds it did not scope.
  local planted = "C\t\nE\tshadows\t7\t9\tplanted\tdo it"
  assert(Sqlite.run(memo, "UPDATE check_memo SET value = ?1", { { text = planted } }))
  local hit = table.concat(tree_checks.scoped(root, memo), "\n")
  assert(hit:find("build/bad.tl:7:9: planted (shadows): do it", 1, true) and not hit:find("unknown_variable", 1, true), hit)
  -- The code that scopes changed: the salt moves, the file is scoped again.
  assert(Fs.write(root .. "/lang/scopes.tl", "-- two\n"))
  assert(table.concat(tree_checks.scoped(root, memo), "\n") == plain)
  assert(memo:close())
end

--- A file's refusal by the tree's checks of this root.
local function refused_by_the_tree(root: string, file: string): boolean
  for _, found in ipairs({ tree_checks.scoped(root), tree_checks.declared(root), tree_checks.checked(root) }) do
    for _, line in ipairs(found) do
      if line:find(file, 1, true) == 1 then
        return true
      end
    end
  end
  return false
end

--- The refusal of a compile through the driver for the same file.
local function refused_by_the_driver(root: string, file: string): boolean
  local entries: mut {{string}} = {}
  for _, name in ipairs({ "bad", "fine" }) do
    local text = assert(Fs.read(root .. "/build/" .. name .. ".tl"))
    entries[#entries + 1] = { "build/" .. name .. ".tl", tostring(text) }
  end
  local build = Driver.new({ globals = {}, adjust = nil, external = {}, types = false })
  build:provide(Driver.files(Driver.index(entries, function(_file: string): boolean
    return false
  end)))
  local names = { "build.bad", "build.fine" }
  build:lower(names)
  local name = assert(file:match("build/(%w+)%.tl$"), "a file is a build module")
  local result = assert(build:result("build." .. name, true))
  return #build:held(result, true) > 0
end

--- The tree's checks and a compile through the driver refuse the same files over the same markers. (A file that does not
--- parse is refused when `cosmic fix` reads it, before any stage.)
local function test_the_tree_checks_and_the_drivers_held_give_one_verdict_over_the_same_markers(dir: string)
  local root = dir .. "/oneverdict"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/bad.tl", source("local x: {number: integer}", "return x")))
  assert(Fs.write(root .. "/build/fine.tl", source("local record Fine", "  n: integer", "end", "return Fine")))
  for _, file in ipairs({ "build/bad.tl", "build/fine.tl" }) do
    local open = refused_by_the_tree(root, file)
    assert(open == refused_by_the_driver(root, file), file .. " with no marker: the tree says " .. tostring(open))
  end
  assert(refused_by_the_tree(root, "build/bad.tl") and not refused_by_the_tree(root, "build/fine.tl"))
  -- the marker holds the finding in both
  assert(Fs.write(root .. "/build/bad.tl", source("local x: {number: integer} -- declared: float_key", "return x")))
  for _, file in ipairs({ "build/bad.tl", "build/fine.tl" }) do
    local held = refused_by_the_tree(root, file)
    assert(held == refused_by_the_driver(root, file), file .. " with its marker: the tree says " .. tostring(held))
    assert(not held, file)
  end
end

--- A `.d.tl` edited under a warm memo changes the answer for the modules that read it.
local function test_an_edit_of_the_declaration_of_a_module_given_as_declaration_and_source_misses_the_memo(dir: string)
  local root = dir .. "/declpair"
  assert(Fs.mkdirs(root .. "/p"))
  assert(Fs.mkdirs(root .. "/q"))
  assert(Fs.write(root .. "/p/foo.d.tl", source("local record Box", "  s: string", "end", "return Box")))
  assert(Fs.write(root .. "/p/foo.tl", source("local record Box", "  n: integer", "end", "return Box")))
  assert(Fs.write(root .. "/q/use.tl", source("local Box = require(\"p.foo\")", "local b: Box = { s = \"x\" }", "return b")))
  local memo = assert(Sqlite.memory())
  assert(#tree_checks.checked(root, memo) == 0, table.concat(tree_checks.checked(root), "\n"))
  assert(Fs.write(root .. "/p/foo.d.tl", source("local record Box", "  s: integer", "end", "return Box")))
  local again = table.concat(tree_checks.checked(root, memo), "\n")
  assert(again:find("q/use.tl:2:", 1, true), again)
  assert(again == table.concat(tree_checks.checked(root), "\n"), "a warm memo and a cold run agree")
  assert(memo:close())
end

--- A tree for `typed`: a standard-library module with a record nested in its own, and a module that reads a field of it.
local function typed_tree(root: string)
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/cosmic"))
  assert(Fs.write(root .. "/cosmic/m.tl", source(
    "local record M",
    "  record Item",
    "    n: integer",
    "  end",
    "  make: function(): Item",
    "end",
    "function M.make(): M.Item",
    "  return { n = 1 }",
    "end",
    "return M")))
  assert(Fs.write(root .. "/build/use.tl", source(
    'local M = require("cosmic.m")',
    "local item = M.make()",
    "local n = item.n",
    "return n")))
end

--- The calls the checker gave no function are held by the markers at their lines.
local function test_a_call_the_checker_could_type_no_function_for_is_held_by_its_marker(dir: string)
  local root = dir .. "/typeduntyped"
  typed_tree(root)
  assert(Fs.write(root .. "/build/open.tl", source("local x = missing(2)", "local y = x.field(1)", "return y")))
  local found = table.concat(tree_checks.untyped(root), "\n")
  assert(found:find("build/open.tl: 1 error of call in its calls on line 1, marked 0; follow the fix above rather than add a marker",
    1, true) ~= nil and found:find("build/open.tl: 1 error of call in its calls on line 2, marked 0", 1, true) ~= nil, found)
  assert(Fs.write(root .. "/build/open.tl", source("local x = missing(2) -- untyped: call",
    "local y = x.field(1) -- untyped: call", "return y")))
  assert(#tree_checks.untyped(root) == 0, table.concat(tree_checks.untyped(root), "\n"))
  -- a marker above what the line has is stale, and a line with none is refused
  assert(Fs.write(root .. "/build/open.tl", source("local x = missing(2) -- untyped: call*2", "local y = x.field(1)", "return y")))
  local stale = table.concat(tree_checks.untyped(root), "\n")
  assert(stale:find("build/open.tl:1: its marker holds 1 finding of call that the line no longer has", 1, true) and
      stale:find("on line 2, marked 0", 1, true), stale)
end

--- A tree with the headers of the bindings of C declares them from the headers (as the build derives them), so a call of one is
--- typed; a tree without them leaves the bindings untyped, and the calls of them are held by a marker.
local function test_the_bindings_of_c_are_typed_where_the_tree_has_their_headers(dir: string)
  local root = dir .. "/typedbindings"
  typed_tree(root)
  local user = source("local sys = require(\"cosmic.sys\")", "sys.unlink(\"x\") -- untyped: call", "return {}")
  assert(Fs.write(root .. "/build/uses_sys.tl", user))
  assert(#tree_checks.untyped(root) == 0, "untyped: no header, no judgment")
  assert(Fs.mkdirs(root .. "/core"))
  for _, header in ipairs({ "core/syscalls.h", "core/process.h", "core/socket.h" }) do
    assert(Fs.write(root .. "/" .. header, (assert(Fs.read(header)))))
  end
  -- with the headers the call is typed, so its marker is stale
  local found = table.concat(tree_checks.untyped(root), "\n")
  assert(found:find("build/uses_sys.tl:2: its marker holds 1 finding of call that the line no longer has", 1, true) ~= nil, found)
end

--- The projection the tree checks build is the one a lookup reads ([`writer.other_code`]): in the one mode there is, it is
--- written by the code that reads it, so `cosmic docs` and the link check of `cosmic fix --check .` find the tree's own
--- modules in it.
local function test_the_projection_of_the_tree_checks_is_written_by_the_code_that_reads_it(tmp: string)
  local root = tmp .. "/new"
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.write(root .. "/core/.keep", ""))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/importer.tl", "local record importer\nend\n\nreturn importer\n"))
  assert(Fs.mkdirs(root .. "/lang"))
  assert(Fs.write(root .. "/lang/stdlib.d.tl", (assert(Fs.read("lang/stdlib.d.tl")))))
  assert(Fs.write(root .. "/lang/prelude.d.tl", (assert(Fs.read("lang/prelude.d.tl")))))
  assert(Fs.write(root .. "/things.tl", "--- Opens.\nlocal function open(): integer\n  return 1\nend\n\nreturn open\n"))
  local db = assert(tree_checks.projection(root, (assert(Tree.standing(root, (assert(Tree.built_from(root))))))))
  local own, trouble = writer.other_code(db, rebuild.compiled_by())
  assert(own == nil and trouble == "", tostring(own) .. trouble)
  assert(db:close())
end
