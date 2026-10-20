--- [`build.tree_checks`] on fixture trees, each built to a projection by
--- the build's own code ([`build.docs_fixture`]): every check refuses a
--- tree with the defect it is for planted in it, and passes the same
--- tree without it.

local Ceilings = require("build.ceilings")
local Contracts = require("build.contracts")
local Declarations = require("lang.declarations")
local Receivers = require("build.syntax_receivers")
local Report = require("build.syntax_report")
local SyntaxContracts = require("build.syntax_contracts")
local SyntaxStub = require("build.syntax_stub")
local Typed = require("build.syntax_typed")
local Driver = require("build.driver")
local Fs = require("cosmic.fs")
local GrammarMode = require("build.grammar_mode")
local Sqlite = require("cosmic.sqlite")
local fixture = require("build.docs_fixture")
local rebuild = require("build.rebuild")
local schema = require("build.schema")
local symbols = require("build.symbols")
local ast = require("build.ast")
local stub = require("build.stub")
local teal = require("build.teal")
local Test = require("cosmic.test")
local tree_checks = require("build.tree_checks")
local writer = require("build.writer")

Test.policy{
  grants = {
    { path = "build/ceilings.txt", letters = "r" }, { path = "core/syscalls.h", letters = "r" }, { path = "core/process.h", letters = "r" },
    { path = "core/socket.h", letters = "r" }, { path = "checker/stdlib.d.tl", letters = "r" },
    { path = "checker/tl.tl", letters = "r" },
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
        "local record Handle",
        "end",
        "",
        "local record Thing",
        "  type Opts = Options",
        "  type Handle = Handle",
        exported and "  type Where = Where" or "",
        exported and "  type Made = Made" or "",
        exported and "  type Alias = Gone" or "",
        "end",
        "",
        "function Thing.run(options: Options) end",
        "function Thing.make(): Made end",
        "function Handle:go(gone: Gone) end",
        "return Thing"),
    })
  end
  local found = tree_checks.unnamed_types(tree(false))
  local text = table.concat(found, "\n")
  assert(#found == 3, text)
  assert(found[1]:find("^cosmic/thing%.tl:8: cosmic%.thing: Gone is named .* add `type Gone = Gone` " ..
      "to Thing, so a caller can write Thing%.Gone") ~= nil, text)
  assert(found[2]:find("^cosmic/thing%.tl:5: cosmic%.thing: Made is named") ~= nil, text)
  assert(found[3]:find("^cosmic/thing%.tl:1: cosmic%.thing: Where is named") ~= nil, text)
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
  assert(#all == 2 and all[1]:text(1) == "cosmic.fs" and all[2]:text(1) == "cosmic.internal.shared",
    #all .. " modules")
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
      "local Store = require(\"cosmic.store\")",
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
  assert(found[1]:find("^build/spells%.tl:2: spells the build directory") ~= nil, found[1])
  assert(found[2]:find("^build/spells%.tl:3: ") ~= nil, found[2])
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
  assert(found[1]:find("^cosmic%.log Logger%.shout is quieted") ~= nil, found[1])
  assert(found[2]:find("^cosmic%.gone Gone is quieted") ~= nil, found[2])
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
  local rules = { ["build.probe has"] = { files = { "build/asker.tl" }, why = "ask the host" } }
  local found = tree_checks.restricted(db, rules)
  assert(#found == 1, table.concat(found, "\n"))
  assert(found[1]:find("^build/other_test%.tl:%d+: build%.probe has is used outside build/asker%.tl: ask the host") ~=
      nil, found[1])
  rules["build.probe has"].files = { "build/asker.tl", "build/other_test.tl" }
  found = tree_checks.restricted(db, rules)
  assert(#found == 0, table.concat(found, "\n"))
end

--- A declaration that requires only declarations, in any spelling a
--- closure store follows, passes; one that requires a module is refused.
local function test_a_declaration_that_requires_a_module_is_refused(dir: string)
  local db = fixture.database(dir, {
    ["build/base.d.tl"] = source("local record base", "  x: integer", "end", "return base"),
    ["build/quoted.d.tl"] = source(
      "local type base = require 'build.base'",
      "local record quoted",
      "  b: base",
      "end",
      "return quoted"),
    ["build/long.d.tl"] = source(
      "local type base = require [[build.base]]",
      "local record long",
      "  b: base",
      "end",
      "return long"),
  })
  local found = tree_checks.declarations(db)
  assert(#found == 0, table.concat(found, "\n"))
  db = fixture.database(dir, {
    ["build/thing.tl"] = source("local record thing", "  x: integer", "end", "return thing"),
    ["build/raw.d.tl"] = source(
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
    local files: {string:string} = {
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
      nil and found[2]:find("name build%.thing, which is no test module") ~= nil,
    table.concat(found, "\n"))
end

--- A spec is read as the source writes it, in any layout of literals, and
--- what cannot be read is refused rather than passed over: a guide that is
--- no string literal, a listed verb whose spec is no table literal, a
--- test named by a variable.
local function test_a_spec_is_read_in_any_layout_of_literals(dir: string)
  local quickstart = "## a thing\n\n`cosmic thing` does it.\n"
  local function found_with(thing: string, extra?: {string:string}): {string}
    local files: {string:string} = {
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
  assert(found[1]:find("b_test requires proc, which no CI leg promises", 1, true), found[1])
  assert(found[2]:find("b_test requires root, which no CI leg promises", 1, true), found[2])
  assert(#tree_checks.promises({ ["a_test"] = { "nest" } }, legs) == 0)
  assert(#tree_checks.promises({}, legs) == 0)
  local refused = tree_checks.promises({}, { linux = { "nope" } })
  assert(#refused == 1 and refused[1]:find("leg linux promises \"nope\", which is refused", 1, true), refused[1])
end

--- The legs are read out of ci/cosmic_ci/capabilities.tl as data, and a file
--- that returns no `legs` of lists of names is refused.
local function test_the_legs_are_read_from_the_capabilities_file(dir: string)
  assert(Fs.mkdirs(dir .. "/ci/cosmic_ci"))
  local path = dir .. "/ci/cosmic_ci/capabilities.tl"
  assert(Fs.write(path, 'local linux = { "sandbox", "nest" }\nreturn { legs = { x = linux, y = {} } }\n'))
  local legs = assert(tree_checks.legs(dir))
  assert(#legs.x == 2 and legs.x[2] == "nest" and #legs.y == 0)
  for _, bad in ipairs({ "return {}", "return { legs = { x = 1 } }", "error('no')", "return {" }) do
    assert(Fs.write(path, bad))
    local found, why = tree_checks.legs(dir)
    assert(found == nil and why:find("capabilities.tl", 1, true) ~= nil, bad .. ": " .. tostring(why))
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
  assert(#found["m.a_test"] == 2 and found["m.a_test"][1] == "nest" and found["m.a_test"][2] == "proc")
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
  assert(found["m.a_test"] and found["m.b_test"] and found["m.c_test"])
  assert(not found["m.d_test"] and not found["m.e_test"])
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
  assert(found[1]:find("^build%.argv_test names the portable launcher's contract") ~= nil, found[1])
  assert(found[2]:find("^build%.reads_test names the portable launcher's contract") ~= nil, found[2])
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
  local seen: {string: boolean} = {}
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
  assert(found[2]:find("^cosmic/thing%.tl:7: .*`TODO:` %(todo rule%).*`%-%-` comment") ~= nil, text)
  assert(found[3]:find("^cosmic/thing%.tl:9: .*`core/thing%.c`") ~= nil, text)
  assert(found[4]:find("^cosmic/thing%.tl:9: .*`cosmic%.internal%.thing%.`") ~= nil, text)
  assert(found[5]:find("^cosmic/thing%.tl:11: .*`build%.thing`") ~= nil, text)
  assert(found[6]:find("^cosmic/thing%.tl:11: .*`vendor/thing,`") ~= nil, text)
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
  local built = assert(teal.load())
  local found = tree_checks.plurals(db, built, {}, {})
  local text = table.concat(found, "\n")
  assert(#found == 5, text)
  assert(found[1]:find("^build/count%.tl:4: .*`tests`.*plural%.count") ~= nil, text)
  assert(found[2]:find("^build/count%.tl:8: .*`files`") ~= nil, text)
  assert(found[3]:find("^build/count%.tl:11: .*`tests`.*plural%.noun") ~= nil, text)
  assert(found[4]:find("^build/count%.tl:14: .*`rows`") ~= nil, text)
  assert(found[5]:find("^build/count%.tl:17: .*`stores`") ~= nil, text)
  found = tree_checks.plurals(db, built, { { "ci/x.tl", "return #arg .. \" arguments\"\n" } }, {
    ["build/count.tl:tests"] = "always many", ["build/count.tl:files"] = "always many",
    ["build/count.tl:rows"] = "always many", ["build/count.tl:stores"] = "always many",
    ["build/fine.tl:tests"] = "unneeded" })
  assert(#found == 2 and found[1]:find("^ci/x%.tl:1: .*`arguments`") ~= nil and
      found[2]:find("^build/fine%.tl:tests: exempt, but nothing") ~= nil, table.concat(found, "\n"))
end

--- The plurals a parse already found stand for a file's only while its
--- text is the one parsed: a file whose text has moved since is parsed
--- again, and a file the check does not read is found nothing in.
local function test_plurals_found_before_stand_for_the_same_text(dir: string)
  local text = source("local n = 2", "return n .. \" tests\"")
  local db = fixture.database(dir, {
    ["build/count.tl"] = text,
    ["build/moved.tl"] = source("local n = 2", "return n .. \" rows\""),
  })
  local built = assert(teal.load())
  local parsed = assert(ast.parse(built, text, "build/count.tl"))
  assert(tree_checks.plurals_in("build/count_test.tl", text, parsed) == nil)
  assert(tree_checks.plurals_in("examples/count.tl", text, parsed) == nil)
  local read: {string: tree_checks.Plurals} = {
    ["build/count.tl"] = assert(tree_checks.plurals_in("build/count.tl", text, parsed)),
    -- What was found in an older text of the file, which no longer stands.
    ["build/moved.tl"] = { source = "return 1\n", sites = {} },
  }
  assert(#read["build/count.tl"].sites == 1)
  -- A site the parse did not find is reported, so the check took it.
  read["build/count.tl"].sites[1][2] = "kept"
  local found = tree_checks.plurals(db, built, {}, {}, read)
  local all = table.concat(found, "\n")
  assert(#found == 2, all)
  assert(found[1]:find("^build/count%.tl:2: .*`kept`") ~= nil, all)
  assert(found[2]:find("^build/moved%.tl:2: .*`rows`") ~= nil, all)
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
  local names: {string} = {}
  for _, row in ipairs(found) do names[#names + 1] = row[1] .. "=" .. row[2]:gsub("\n", "") end
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
  local found = tree_checks.ci_testdata(dir .. "/tree", (assert(teal.load())))
  local all = table.concat(found, "\n")
  assert(found[1] ~= nil and found[1]:find("^ci/testdata/sub/bad%.tl:1:") ~= nil, all)
  assert(all:find("ci/testdata/sub/foreign.tl", 1, true) ~= nil, all)
  assert(all:find("good_test", 1, true) == nil, all)
  assert(all:find("ci/testdata/sub/loose.tl:1:", 1, true) ~= nil, all)
  assert(#tree_checks.ci_testdata(dir .. "/nowhere", (assert(teal.load()))) == 0)
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
  local found = tree_checks.ci_testdata(dir .. "/tree", (assert(teal.load())))
  local all = table.concat(found, "\n")
  assert(all:find("zz_test", 1, true) == nil, all)
  assert(all:find("ci/testdata/sub/label.tl:2:", 1, true) ~= nil, all)
end

--- A form the new checker's grammar cuts is refused past its pin, each with
--- its place and the lexer's fix; the sources are the `.tl` files under the
--- root, `vendor/`, `o/` and hidden directories apart. A pin the tree no longer meets is told to fall.
local function test_a_cut_form_of_the_new_grammar_past_its_pin_is_refused_with_its_fix(dir: string)
  local root = dir .. "/lexroot"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/ok.tl", source("local x = 1", "return x")))
  assert(Fs.write(root .. "/build/jumps.tl", source(
    "for i = 1, 3 do",
    "  goto continue",
    "  ::continue::",
    "end",
    "return 1")))
  assert(Fs.mkdirs(root .. "/checker"))
  assert(Fs.mkdirs(root .. "/vendor"))
  assert(Fs.mkdirs(root .. "/o"))
  assert(Fs.mkdirs(root .. "/.hidden"))
  assert(Fs.write(root .. "/checker/decls.d.tl", "--[[ one ]]\nreturn 1\n"))
  assert(Fs.write(root .. "/vendor/v.tl", "goto x\n"))
  assert(Fs.write(root .. "/o/stale.tl", "goto x\n"))
  assert(Fs.write(root .. "/.hidden/h.tl", "goto x\n"))
  local found = table.concat(tree_checks.lexed(root, {}), "\n")
  assert(found:find("build/jumps.tl:2:3: `goto continue` is not in the grammar (label_or_goto): write `continue`",
    1, true), found)
  assert(found:find("build/jumps.tl:3:3: the label `::continue::` is not in the grammar (label_or_goto): delete the label",
    1, true), found)
  assert(found:find("build/jumps.tl: 2 errors of label_or_goto, pinned 0; remove the form", 1, true), found)
  assert(found:find("checker/decls.d.tl:1:1: long comments are not in the grammar (long_comment): write line comments",
    1, true), found)
  assert(not found:find("ok.tl", 1, true) and not found:find("vendor", 1, true) and not found:find("stale", 1, true) and
      not found:find("hidden", 1, true), found)
  local pins: {string: integer} = { ["build/jumps.tl label_or_goto"] = 2, ["checker/decls.d.tl long_comment"] = 1 }
  assert(#tree_checks.lexed(root, pins) == 0)
  pins["build/jumps.tl label_or_goto"] = 3
  pins["build/gone.tl semicolon"] = 1
  local fallen = tree_checks.lexed(root, pins)
  assert(#fallen == 2 and fallen[1] == "build/gone.tl semicolon: pinned 1 but 0 found; lower the pin in " ..
      "build/ceilings.txt's [lexed]" and fallen[2]:find("build/jumps.tl label_or_goto: pinned 3 but 2 found", 1, true),
    table.concat(fallen, "\n"))
end

--- The pins the tree is held to are the grammar draft's counts for what it
--- cuts, apart from the fork's own [`checker/tl.tl`].
local function test_the_tree_is_held_to_the_cut_forms_the_grammar_draft_counts(dir: string)
  local ceilings = assert(Ceilings.read("."))
  local stale = tree_checks.lexed(dir, Ceilings.of(ceilings, "lexed"))
  local totals: {string: integer} = {}
  for _, line in ipairs(stale) do
    local file, code, count = line:match("^(%S+) (%S+): pinned (%d+) but")
    assert(file ~= nil, line)
    if file ~= "checker/tl.tl" then
      totals[code] = (totals[code] or 0) + assert(math.tointeger(tonumber(count)))
    end
  end
  assert(totals["label_or_goto"] == 10 and totals["semicolon"] == 1 and totals["long_comment"] == 27 and
      totals["digit_separator"] == 4 and totals["hex_float"] == nil)
end

--- A form the translator leaves is refused past its pin, with its place and
--- the parser's fix; the fork's file is not read; a pin the tree no longer
--- meets, and a ceiling above the methods moved above a name they read, are
--- told to fall.
local function test_a_form_the_translator_leaves_is_refused_past_its_pin_with_its_fix(dir: string)
  local root = dir .. "/translateroot"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/checker"))
  assert(Fs.mkdirs(root .. "/vendor"))
  assert(Fs.write(root .. "/build/ok.tl", source("local a: string | nil", "local n = a ~= nil and 1 or 2", "return n")))
  assert(Fs.write(root .. "/build/tuple.tl", source("local a: {{string, integer}}", "return a")))
  assert(Fs.write(root .. "/checker/tl.tl", source("local a: {{string, integer}}", "return a")))
  assert(Fs.write(root .. "/vendor/v.tl", source("local a: {{string, integer}}", "return a")))
  local found = table.concat(tree_checks.translated(root, {}, 0), "\n")
  assert(found:find("build/tuple.tl:1:", 1, true) and found:find("(tuple_type)", 1, true) and
      found:find("build/tuple.tl: 1 error of tuple_type after translation, pinned 0", 1, true),
    found)
  assert(not found:find("ok.tl", 1, true) and not found:find("checker/tl.tl", 1, true) and
      not found:find("vendor", 1, true), found)
  local pins: {string: integer} = { ["build/tuple.tl tuple_type"] = 1 }
  assert(#tree_checks.translated(root, pins, 0) == 0)
  pins["build/tuple.tl tuple_type"] = 2
  pins["build/gone.tl tuple_type"] = 1
  local fallen = tree_checks.translated(root, pins, 0)
  assert(#fallen == 2 and fallen[1] == "build/gone.tl tuple_type: pinned 1 but 0 found; lower the pin in " ..
      "build/ceilings.txt's [translated]" and
      fallen[2]:find("build/tuple.tl tuple_type: pinned 2 but 1 found", 1, true), table.concat(fallen, "\n"))
end

--- A method that moved into its class above a local it reads is counted
--- against the ceiling, each listed with its place; a translation that moved
--- a line without a class is refused.
local function test_a_method_moved_above_a_name_it_reads_is_counted_against_the_ceiling(dir: string)
  local root = dir .. "/translatehazard"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/moved.tl", source(
    "local function one(): integer",
    "  return 1",
    "end",
    "local record R",
    "  n: integer",
    "end",
    "local helper = one()",
    "function R:f(): integer",
    "  return self.n + helper",
    "end",
    "return R")))
  local pins: {string: integer} = {}
  local over = table.concat(tree_checks.translated(root, pins, 0), "\n")
  assert(over:find("build/moved.tl:8: R:f reads helper", 1, true) and
      over:find("methods moved into a class that read or give something else: 1, ceiling 0", 1, true), over)
  assert(#tree_checks.translated(root, pins, 1) == 0)
  local under = tree_checks.translated(root, pins, 2)
  assert(#under == 1 and under[1]:find("lower the [hazards] ceiling in build/ceilings.txt", 1, true), table.concat(under, "\n"))
end

--- A file that has not changed is not read again: its findings come from the
--- memo. A change to the file or to the code that translates it is a miss.
local function test_a_memo_answers_for_a_file_that_has_not_changed_and_misses_when_it_or_the_code_does(dir: string)
  local root = dir .. "/translatememo"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/lang"))
  assert(Fs.write(root .. "/lang/translate.tl", "-- one\n"))
  assert(Fs.write(root .. "/build/tuple.tl", source("local a: {{string, integer}}", "return a")))
  local memo = assert(Sqlite.memory())
  local plain = table.concat(tree_checks.translated(root, {}, 0), "\n")
  assert(plain:find("(tuple_type)", 1, true), plain)
  assert(table.concat(tree_checks.translated(root, {}, 0, memo), "\n") == plain)
  local count = assert(Sqlite.rows(memo, "SELECT count(*) FROM check_memo WHERE kind = 'translated'"))
  assert(count[1]:integer(1) == 2, "the two files")
  -- Plant another answer under the key: a run that finds it did not translate.
  local planted = "M\t0\t1\t1\nE\tbare_function\t7\t9\tplanted\twrite it"
  assert(Sqlite.run(memo, "UPDATE check_memo SET value = ?1", { { text = planted } }))
  local hit = table.concat(tree_checks.translated(root, {}, 0, memo), "\n")
  assert(hit:find("build/tuple.tl:7:9: planted (bare_function)", 1, true) and not hit:find("tuple_type", 1, true), hit)
  -- The code that translates changed: the salt moves, the file is translated again.
  assert(Fs.write(root .. "/lang/translate.tl", "-- two\n"))
  assert(table.concat(tree_checks.translated(root, {}, 0, memo), "\n") == plain)
  -- The file changed: its key moves, and the rows of the old one are dropped.
  assert(Fs.write(root .. "/build/tuple.tl", source("local a: {{string, string}}", "return a")))
  local edited = table.concat(tree_checks.translated(root, {}, 0, memo), "\n")
  assert(edited:find("build/tuple.tl:1:", 1, true) and edited:find("(tuple_type)", 1, true), edited)
  count = assert(Sqlite.rows(memo, "SELECT count(*) FROM check_memo WHERE kind = 'translated'"))
  assert(count[1]:integer(1) == 2, "the old key of the edited file is dropped")
  assert(memo:close())
end

--- The lexer check keeps its findings the same way.
local function test_a_memo_answers_the_lexer_check_for_a_file_that_has_not_changed(dir: string)
  local root = dir .. "/lexmemo"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/jumps.tl", source("for i = 1, 3 do", "  goto continue", "  ::continue::", "end", "return 1")))
  local memo = assert(Sqlite.memory())
  local plain = table.concat(tree_checks.lexed(root, {}), "\n")
  assert(plain:find("(label_or_goto)", 1, true), plain)
  assert(table.concat(tree_checks.lexed(root, {}, memo), "\n") == plain)
  assert(Sqlite.run(memo, "UPDATE check_memo SET value = 'C\tplanted'"))
  local hit = table.concat(tree_checks.lexed(root, {}, memo), "\n")
  assert(hit:find("build/jumps.tl: its tokens do not tile it: planted", 1, true), hit)
  assert(memo:close())
end

--- A field given `mut` in a record that extends an interface of another file
--- counts against the ceiling only when that interface, or one it extends,
--- declares the field.
local function test_a_mut_on_a_record_counts_only_when_the_interface_of_another_file_declares_the_field(dir: string)
  local root = dir .. "/translateface"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/face.tl", source(
    "local interface Base",
    "  size: integer",
    "end",
    "local interface Face is Base",
    "  name: string",
    "end",
    "return Face")))
  assert(Fs.write(root .. "/build/user.tl", source(
    "local Face = require(\"build.face\")",
    "local record Shape is Face",
    "  size: integer",
    "  name: string",
    "  own: integer",
    "end",
    "local function set(s: Shape)",
    "  s.size = 1",
    "  s.name = \"x\"",
    "  s.own = 2",
    "end",
    "return set")))
  local pins: {string: integer} = {}
  local over = table.concat(tree_checks.translated(root, pins, 0), "\n")
  assert(over:find("build/user.tl:3: Shape:size is given mut, which the interface declares: Face", 1, true) and
      over:find("Shape:name", 1, true) and not over:find("Shape:own", 1, true), over)
  assert(#tree_checks.translated(root, pins, 2) == 0)
end

--- A name the scope builder cannot resolve, and a declaration that hides one, are refused past
--- their pins with the place, the message and the fix; the globals are the ones the tree's
--- declaration file declares; the fork's file is not read; a pin above what the tree has is
--- told to fall.
local function test_a_name_the_scope_builder_cannot_resolve_is_refused_past_its_pin_with_its_fix(dir: string)
  local root = dir .. "/scoperoot"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/checker"))
  assert(Fs.mkdirs(root .. "/vendor"))
  assert(Fs.write(root .. "/checker/stdlib.d.tl", source("global print: integer")))
  assert(Fs.write(root .. "/build/ok.tl", source("local x = 1", "print(x)", "return x")))
  assert(Fs.write(root .. "/build/bad.tl", source("local x = 1", "local x = 2", "print(y)", "return x")))
  assert(Fs.write(root .. "/checker/tl.tl", source("print(unknown_to_the_fork)")))
  assert(Fs.write(root .. "/vendor/v.tl", source("print(unknown_to_vendor)")))
  local found = table.concat(tree_checks.scoped(root, {}), "\n")
  assert(found:find("build/bad.tl:2:7: variable `x` shadows the variable `x` declared at 1:7 (shadows): to change the existing", 1, true) and
      found:find("build/bad.tl:3:7: `y` is not declared (unknown_variable): declare it with `local y = ...`", 1, true) and
      found:find("build/bad.tl: 1 error of shadows in its scopes, pinned 0; follow the fix above rather than raise the pin", 1, true),
    found)
  assert(not found:find("ok.tl", 1, true) and not found:find("checker/tl.tl", 1, true) and
      not found:find("vendor", 1, true) and not found:find("print", 1, true), found)
  local pins: {string: integer} = { ["build/bad.tl shadows"] = 1, ["build/bad.tl unknown_variable"] = 1 }
  assert(#tree_checks.scoped(root, pins) == 0)
  pins["build/bad.tl shadows"] = 2
  pins["build/gone.tl shadows"] = 1
  local fallen = tree_checks.scoped(root, pins)
  assert(#fallen == 2 and fallen[1] == "build/bad.tl shadows: pinned 2 but 1 found; lower the pin in " ..
      "build/ceilings.txt's [scoped]" and
      fallen[2] == "build/gone.tl shadows: pinned 1 but 0 found; lower the pin in build/ceilings.txt's [scoped]",
    table.concat(fallen, "\n"))
end

--- A declaration the lowering refuses is listed past its pin with the place, the message and the fix; a
--- module imported by a literal name is found, with the name below `ci/`'s own root; the fork's file is
--- not read; a pin above what the tree has is told to fall.
local function test_a_declaration_the_lowering_refuses_is_refused_past_its_pin_with_its_fix(dir: string)
  local root = dir .. "/declareroot"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/ci/cosmic_ci"))
  assert(Fs.mkdirs(root .. "/checker"))
  assert(Fs.write(root .. "/checker/tl.tl", source("local x: {string | nil}")))
  assert(Fs.write(root .. "/ci/cosmic_ci/shape.tl", source("local record Shape", "  n: integer", "end", "return Shape")))
  assert(Fs.write(root .. "/build/ok.tl", source("local type Shape = require(\"cosmic_ci.shape\")", "local x: Shape", "return x")))
  assert(Fs.write(root .. "/build/bad.tl", source("local type Shape = require(\"cosmic_ci.shape\")",
    "local x: {Shape: string?}", "local y: {number: integer}", "return x")))
  local found = table.concat(tree_checks.declared(root, {}), "\n")
  assert(found:find("build/bad.tl:3:11: a map is keyed by `integer`, not `number`", 1, true) and
      found:find("(float_key): key by `integer`", 1, true) and
      found:find("build/bad.tl: 1 error of float_key in its declarations, pinned 0; follow the fix above rather than raise the pin", 1, true),
    found)
  assert(found:find("array_of_optional", 1, true), found)
  assert(not found:find("ok.tl", 1, true) and not found:find("checker/tl.tl", 1, true), found)
  local pins: {string: integer} = { ["build/bad.tl float_key"] = 1, ["build/bad.tl array_of_optional"] = 1 }
  assert(#tree_checks.declared(root, pins) == 0)
  pins["build/bad.tl float_key"] = 2
  pins["build/gone.tl key_type"] = 1
  local fallen = tree_checks.declared(root, pins)
  assert(#fallen == 2 and fallen[1] == "build/bad.tl float_key: pinned 2 but 1 found; lower the pin in " ..
      "build/ceilings.txt's [declared]" and
      fallen[2] == "build/gone.tl key_type: pinned 1 but 0 found; lower the pin in build/ceilings.txt's [declared]",
    table.concat(fallen, "\n"))
end

--- Files that require each other reach the same modules, and keep their own answers.
local function test_files_that_require_each_other_keep_their_own_answers_in_the_memo(dir: string)
  local root = dir .. "/declarecycle"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/a.tl", source("local b = require(\"build.b\")", "local x: {number: integer}", "return b")))
  assert(Fs.write(root .. "/build/b.tl", source("local a = require(\"build.a\")", "local y: {any: integer}", "return a")))
  local memo = assert(Sqlite.memory())
  local plain = table.concat(tree_checks.declared(root, {}, memo), "\n")
  assert(plain:find("build/a.tl:2:", 1, true) and plain:find("build/b.tl:2:", 1, true), plain)
  assert(table.concat(tree_checks.declared(root, {}, memo), "\n") == plain)
  assert(memo:close())
end

--- A file whose translation does not parse is lowered for the files that import it and counts nothing of its own
--- (the `translated` check holds the forms that break it), and the files of a `testdata` directory are not read.
local function test_a_file_that_does_not_parse_and_a_testdata_file_count_no_errors_of_their_own(dir: string)
  local root = dir .. "/declarebroken"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/eval/testdata"))
  assert(Fs.write(root .. "/build/broken.tl", source("local record R", "  n: integer", "end", "local t: {{string, integer}}",
    "local x: {number: integer}", "return R")))
  assert(Fs.write(root .. "/build/user.tl", source("local type R = require(\"build.broken\")", "local y: R", "local z: {R: integer}", "return y")))
  assert(Fs.write(root .. "/eval/testdata/t.tl", source("local x: {number: integer}", "return x")))
  assert(Fs.write(root .. "/eval/testdata/u.tl", source("local type Gone = require(\"gone\")", "local g: Gone", "return g")))
  assert(#tree_checks.declared(root, {}) == 0, table.concat(tree_checks.declared(root, {}), "\n"))
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
  local plain = table.concat(tree_checks.declared(root, {}), "\n")
  assert(plain:find("build/top.tl:2:", 1, true) and plain:find("build/alone.tl:1:", 1, true), plain)
  assert(table.concat(tree_checks.declared(root, {}, memo), "\n") == plain)
  local count = assert(Sqlite.rows(memo, "SELECT count(*) FROM check_memo WHERE kind = 'declared'"))
  assert(count[1]:integer(1) == 5, "the four files and the code")
  -- Plant another answer under every key: a run that finds it did not lower.
  assert(Sqlite.run(memo, "UPDATE check_memo SET value = ?1", { { text = "N\nE\tkey_type\t7\t9\tplanted\tdo it" } }))
  local hit = table.concat(tree_checks.declared(root, {}, memo), "\n")
  assert(hit:find("build/top.tl:7:9: planted (key_type): do it", 1, true) and not hit:find("float_key", 1, true), hit)
  -- A module far below changed: the files that require it, through others, are lowered again; one that does not is not.
  assert(Fs.write(root .. "/build/base.tl", source("local record Base", "  m: integer", "end", "return Base")))
  local again = table.concat(tree_checks.declared(root, {}, memo), "\n")
  assert(again:find("build/top.tl:2:", 1, true) and again:find("build/mid.tl", 1, true) == nil, again)
  assert(again:find("build/alone.tl:7:9: planted", 1, true), again)
  assert(memo:close())
end

--- Each file whose code or declarations decide what the check finds is in the memo's salt: a change to any of
--- them misses.
local function test_a_change_to_the_code_or_the_declarations_the_declaration_check_reads_misses_the_memo(dir: string)
  local root = dir .. "/declaresalt"
  local salted: {string} = { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl", "lang/translate.tl",
    "lang/types.tl", "lang/relation.tl", "lang/declarations.tl", "checker/stdlib.d.tl", "checker/tl.tl", "build/teal.tl",
    "build/check_memo.tl", "build/tree_checks.tl" }
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/lang"))
  assert(Fs.mkdirs(root .. "/checker"))
  for _, path in ipairs(salted) do
    assert(Fs.write(root .. "/" .. path, "-- one\n"))
  end
  assert(Fs.write(root .. "/build/bad.tl", source("local x: {number: integer}", "return x")))
  local memo = assert(Sqlite.memory())
  local plain = table.concat(tree_checks.declared(root, {}, memo), "\n")
  assert(plain:find("(float_key)", 1, true), plain)
  for _, path in ipairs(salted) do
    assert(Sqlite.run(memo, "UPDATE check_memo SET value = ?1", { { text = "N\nE\tkey_type\t7\t9\tplanted\tdo it" } }))
    local hit = table.concat(tree_checks.declared(root, {}, memo), "\n")
    assert(hit:find("planted", 1, true), path .. " moved the key by itself: " .. hit)
    assert(Fs.write(root .. "/" .. path, "-- two " .. path .. "\n"))
    local missed = table.concat(tree_checks.declared(root, {}, memo), "\n")
    assert(missed:find("(float_key)", 1, true) and not missed:find("planted", 1, true), path .. " is not in the salt: " .. missed)
  end
  assert(memo:close())
end

--- A mistake in a body is listed past its pin with the place, the message and the fix, in a file that imports the
--- declarations it uses; the fork's file, a declaration file, a file whose translation does not parse and the files of
--- a `testdata` directory are not checked; a pin above what the tree has is told to fall.
local function test_a_mistake_in_a_body_is_refused_past_its_pin_with_its_fix(dir: string)
  local root = dir .. "/checkroot"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/checker"))
  assert(Fs.mkdirs(root .. "/eval/testdata"))
  assert(Fs.write(root .. "/checker/tl.tl", source("local n: integer = 3.5")))
  assert(Fs.write(root .. "/build/shape.tl", source("local record Shape", "  n: integer", "end", "return Shape")))
  assert(Fs.write(root .. "/build/ok.tl", source("local Shape = require(\"build.shape\")", "local s: Shape = { n = 1 }")))
  assert(Fs.write(root .. "/build/bad.tl", source("local Shape = require(\"build.shape\")", "local s: Shape = { n = 1.5 }",
    "local t: integer = 3.5")))
  assert(Fs.write(root .. "/build/broken.tl", source("local t: {{string, integer}}", "local u: integer = 3.5", "return t")))
  assert(Fs.write(root .. "/build/types.d.tl", source("global record Gone", "  n: integer", "end")))
  assert(Fs.write(root .. "/eval/testdata/t.tl", source("local u: integer = 3.5", "return u")))
  local found = table.concat(tree_checks.checked(root, {}), "\n")
  assert(found:find("build/bad.tl:2:24: `1.5` is `number`, where `integer` is wanted as the field `n` of `Shape`", 1, true) and
      found:find("(not_assignable): convert with `math.tointeger(1.5)` or `math.floor(1.5)`", 1, true) and
      found:find("build/bad.tl:3:20:", 1, true) and
      found:find("build/bad.tl: 2 errors of not_assignable in its bodies, pinned 0; follow the fix above rather than raise the pin", 1, true),
    found)
  assert(not found:find("ok.tl", 1, true) and not found:find("checker/tl.tl", 1, true) and not found:find("broken.tl", 1, true) and
      not found:find("testdata", 1, true), found)
  local pins: {string: integer} = { ["build/bad.tl not_assignable"] = 2 }
  assert(#tree_checks.checked(root, pins) == 0, table.concat(tree_checks.checked(root, pins), "\n"))
  pins["build/bad.tl not_assignable"] = 3
  pins["build/gone.tl nil_not_allowed"] = 1
  local fallen = tree_checks.checked(root, pins)
  assert(#fallen == 2 and fallen[1] == "build/bad.tl not_assignable: pinned 3 but 2 found; lower the pin in " ..
      "build/ceilings.txt's [checked]" and
      fallen[2] == "build/gone.tl nil_not_allowed: pinned 1 but 0 found; lower the pin in build/ceilings.txt's [checked]",
    table.concat(fallen, "\n"))
end

--- The phases of a check that lowered files are timed, and a run the memo answers times none.
local function test_the_phases_of_a_check_are_timed_for_the_files_the_memo_lacked(dir: string)
  local root = dir .. "/checkphases"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/a.tl", source("local n: integer = 3.5")))
  local memo = assert(Sqlite.memory())
  local phases: {string: integer} = {}
  local first = table.concat(tree_checks.checked(root, {}, memo, phases), "\n")
  assert(phases.prepare > 0 and phases.lower > 0 and phases.check > 0, first)
  local again: {string: integer} = {}
  assert(table.concat(tree_checks.checked(root, {}, memo, again), "\n") == first)
  assert(again.check == nil)
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
  local plain = table.concat(tree_checks.checked(root, {}, memo), "\n")
  assert(plain:find("build/top.tl:2:", 1, true) and plain:find("build/alone.tl:1:", 1, true), plain)
  local count = assert(Sqlite.rows(memo, "SELECT count(*) FROM check_memo WHERE kind = 'checked'"))
  assert(count[1]:integer(1) == 3, "the three files: " .. count[1]:integer(1))
  assert(Sqlite.run(memo, "UPDATE check_memo SET value = ?1", { { text = "N\nE\tnil_not_allowed\t7\t9\tplanted\tdo it" } }))
  local hit = table.concat(tree_checks.checked(root, {}, memo), "\n")
  assert(hit:find("build/top.tl:7:9: planted (nil_not_allowed): do it", 1, true) and not hit:find("not_assignable", 1, true), hit)
  assert(Fs.write(root .. "/build/base.tl", source("local record Base", "  n: integer", "  m: integer", "end", "return Base")))
  local again = table.concat(tree_checks.checked(root, {}, memo), "\n")
  assert(again:find("build/top.tl:2:", 1, true) and again:find("not_assignable", 1, true), again)
  assert(again:find("build/alone.tl:7:9: planted", 1, true), again)
  assert(memo:close())
end

--- Each file whose code or declarations decide what the check finds is in the memo's salt.
local function test_a_change_to_the_code_or_the_declarations_the_body_check_reads_misses_the_memo(dir: string)
  local root = dir .. "/checksalt"
  local salted: {string} = { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl", "lang/translate.tl",
    "lang/types.tl", "lang/relation.tl", "lang/declarations.tl", "lang/check.tl", "lang/check_codes.tl",
    "checker/stdlib.d.tl", "checker/tl.tl", "build/teal.tl", "build/check_memo.tl", "build/tree_checks.tl" }
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/lang"))
  assert(Fs.mkdirs(root .. "/checker"))
  for _, path in ipairs(salted) do
    assert(Fs.write(root .. "/" .. path, "-- one\n"))
  end
  assert(Fs.write(root .. "/build/bad.tl", source("local x: integer = 1.5")))
  local memo = assert(Sqlite.memory())
  local plain = table.concat(tree_checks.checked(root, {}, memo), "\n")
  assert(plain:find("(not_assignable)", 1, true), plain)
  for _, path in ipairs(salted) do
    assert(Sqlite.run(memo, "UPDATE check_memo SET value = ?1", { { text = "N\nE\tnil_not_allowed\t7\t9\tplanted\tdo it" } }))
    local hit = table.concat(tree_checks.checked(root, {}, memo), "\n")
    assert(hit:find("planted", 1, true), path .. " moved the key by itself: " .. hit)
    assert(Fs.write(root .. "/" .. path, "-- two " .. path .. "\n"))
    local missed = table.concat(tree_checks.checked(root, {}, memo), "\n")
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
  assert(Fs.mkdirs(root .. "/checker"))
  assert(Fs.write(root .. "/lang/scopes.tl", "-- one\n"))
  assert(Fs.write(root .. "/checker/stdlib.d.tl", source("global print: integer")))
  assert(Fs.write(root .. "/build/bad.tl", source("print(y)", "return 1")))
  local memo = assert(Sqlite.memory())
  local plain = table.concat(tree_checks.scoped(root, {}), "\n")
  assert(plain:find("(unknown_variable)", 1, true), plain)
  assert(table.concat(tree_checks.scoped(root, {}, memo), "\n") == plain)
  local count = assert(Sqlite.rows(memo, "SELECT count(*) FROM check_memo WHERE kind = 'scoped'"))
  assert(count[1]:integer(1) == 3, "the three files")
  -- Plant another answer under the key: a run that finds it did not scope.
  local planted = "C\t\nE\tshadows\t7\t9\tplanted\tdo it"
  assert(Sqlite.run(memo, "UPDATE check_memo SET value = ?1", { { text = planted } }))
  local hit = table.concat(tree_checks.scoped(root, {}, memo), "\n")
  assert(hit:find("build/bad.tl:7:9: planted (shadows): do it", 1, true) and not hit:find("unknown_variable", 1, true), hit)
  -- The code that scopes changed: the salt moves, the file is scoped again.
  assert(Fs.write(root .. "/lang/scopes.tl", "-- two\n"))
  assert(table.concat(tree_checks.scoped(root, {}, memo), "\n") == plain)
  assert(memo:close())
end

--- A file whose Lua the generator writes as the fork does passes, and so does one with a class made the way the tree
--- makes it, which is compared apart from its class; the test of a class by its metatable, which the fork writes as a
--- test for a table, leaves a line the fork writes, refused past its pin with the first line that differs; a pin the
--- file no longer needs, and a file the check leaves out (the fork's, a declaration file, one whose translation does
--- not parse), are not counted.
local function test_the_lua_of_a_file_is_held_to_the_forks_but_for_its_pins(dir: string)
  local root = dir .. "/generated"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/checker"))
  assert(Fs.write(root .. "/build/ok.tl", source(
    "local a: string | nil = nil",
    "for i = 1, 3 do",
    "  if i == 2 then goto continue end",
    "  print(i)",
    "  ::continue::",
    "end",
    "return a")))
  assert(Fs.write(root .. "/build/pattern.tl", source(
    "local record Counter",
    "  n: integer",
    "  bump: function(Counter): integer",
    "end",
    "local counter_mt: metatable<Counter> = { __index = Counter }",
    "function Counter:bump(): integer",
    "  self.n = self.n + 1",
    "  return self.n",
    "end",
    "local function make(): Counter",
    "  return setmetatable({ n = 0 }, counter_mt)",
    "end",
    "local function twice(): integer",
    "  local c = make()",
    "  return c:bump() + c:bump()",
    "end",
    "return twice")))
  assert(Fs.write(root .. "/build/classy.tl", source(
    "local record R",
    "  n: integer",
    "end",
    "function R:bump()",
    "  self.n = self.n + 1",
    "end",
    "local function owns(v: any): boolean",
    "  return v is R",
    "end",
    "return owns")))
  assert(Fs.write(root .. "/build/tuple.tl", source("local a: {{string, integer}}", "return a")))
  assert(Fs.write(root .. "/build/types.d.tl", source("global record G", "end")))
  assert(Fs.write(root .. "/checker/tl.tl", source(
    "local record R",
    "end",
    "function R:m() end",
    "return R")))
  local found = tree_checks.generated(root, {})
  local joined = table.concat(found, "\n")
  assert(#found == 2, joined)
  assert(found[1]:find("^build/classy%.tl:%d+: the Lua differs from the fork's: .*@v == R .*type%(v%) == \"table\"", 1), joined)
  local differ = assert(math.tointeger(tonumber(found[2]:match("^build/classy%.tl: (%d+) lines? differ from the fork's Lua, pinned 0"))), joined)
  assert(differ > 0)
  local pins: {string: integer} = { ["build/classy.tl"] = differ }
  assert(#tree_checks.generated(root, pins) == 0)
  pins["build/classy.tl"] = differ + 2
  pins["build/ok.tl"] = 1
  local fallen = tree_checks.generated(root, pins)
  assert(#fallen == 2 and fallen[1] == "build/classy.tl: pinned " .. differ + 2 .. " lines but " .. differ ..
      " differ; lower the pin in build/ceilings.txt's [generated]" and
      fallen[2] == "build/ok.tl: pinned 1 line but 0 differ; lower the pin in build/ceilings.txt's [generated]",
    table.concat(fallen, "\n"))
end

--- A file that has not changed is not generated again, and the fork's Lua for it is kept apart: a change to
--- the generator runs the fork on no file.
local function test_a_memo_answers_the_generator_check_and_keeps_the_forks_lua_for_a_change_of_the_generator(dir: string)
  local root = dir .. "/generatememo"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/lang"))
  assert(Fs.write(root .. "/lang/codegen.tl", "-- one\n"))
  assert(Fs.write(root .. "/build/classy.tl", source(
    "local record R",
    "end",
    "function R:bump() end",
    "local function owns(v: any): boolean",
    "  return v is R",
    "end",
    "return owns")))
  local memo = assert(Sqlite.memory())
  local plain = table.concat(tree_checks.generated(root, {}), "\n")
  assert(plain:find("@v == R", 1, true), plain)
  assert(table.concat(tree_checks.generated(root, {}, memo), "\n") == plain)
  local count = assert(Sqlite.rows(memo, "SELECT count(*) FROM check_memo WHERE kind = 'generated'"))
  assert(count[1]:integer(1) == 4, "the fork's Lua and the answer, for each of the two files")
  -- Plant another answer under the key: a run that finds it did not generate.
  local planted = "D\t3\t7\tmine\ttheirs\nE\tclass_nested_refused\t7\t9\tplanted\tdo it"
  assert(Sqlite.run(memo, "UPDATE check_memo SET value = ?1 WHERE value LIKE '%@v == R%'", { { text = planted } }))
  local hit = table.concat(tree_checks.generated(root, {}, memo), "\n")
  assert(hit:find("build/classy.tl:7:9: planted (class_nested_refused): do it", 1, true) and
      hit:find("build/classy.tl:7: the Lua differs from the fork's: mine | theirs", 1, true), hit)
  -- Lua that does not load is refused, whatever the fork wrote.
  local invalid = "D\t0\t0\t\t\nI\t[string \"x\"]:1: planted"
  assert(Sqlite.run(memo, "UPDATE check_memo SET value = ?1 WHERE value LIKE '%class_nested_refused%'", { { text = invalid } }))
  local unloadable = table.concat(tree_checks.generated(root, {}, memo), "\n")
  assert(unloadable:find("build/classy.tl: the Lua the generator wrote does not load: [string \"x\"]:1: planted", 1, true),
    unloadable)
  -- The generator changed: the answer is made again, from the fork's Lua the memo kept.
  assert(Sqlite.run(memo, "UPDATE check_memo SET value = 'L-- planted\n' WHERE value LIKE 'L%local R%'"))
  assert(Fs.write(root .. "/lang/codegen.tl", "-- two\n"))
  local again = table.concat(tree_checks.generated(root, {}, memo), "\n")
  assert(again:find("the Lua differs from the fork's: ", 1, true) and again:find("| -- planted", 1, true),
    "the fork's Lua is the one the memo kept: " .. again)
  assert(not again:find("planted (class_nested_refused)", 1, true), again)
  assert(memo:close())
end

--- A file's refusal by the tree's checks of this root, over `pins` for each stage.
local function refused_by_the_tree(root: string, file: string, scoped: {string: integer}, translated: {string: integer},
                                   declared: {string: integer}): boolean
  for _, found in ipairs({ tree_checks.scoped(root, scoped), tree_checks.translated(root, translated, 99),
      tree_checks.declared(root, declared), tree_checks.checked(root, {}) }) do
    for _, line in ipairs(found) do
      if line:find(file, 1, true) == 1 then
        return true
      end
    end
  end
  return false
end

--- The refusal of a compile through the driver for the same file, over the same pins.
local function refused_by_the_driver(root: string, file: string, ceilings: Ceilings.Table): boolean
  local entries: {{string}} = {}
  for _, name in ipairs({ "hazard", "broken", "bad", "fine" }) do
    local text = assert(Fs.read(root .. "/build/" .. name .. ".tl"))
    entries[#entries + 1] = { "build/" .. name .. ".tl", tostring(text) }
  end
  local build = Driver.new({ globals = {}, adjust = nil, external = {}, types = false })
  build:provide(Driver.files(Driver.index(entries, true, function(_file: string): boolean
    return false
  end)))
  local names = { "build.hazard", "build.broken", "build.bad", "build.fine" }
  build:lower(names)
  local result = assert(build:result("build." .. file:match("build/(%w+)%.tl$"), true))
  return #build:held(result, ceilings) > 0
end

--- The tree's checks and a compile through the driver refuse the same files over the same ceilings, a file of the fork's Teal
--- whose translation moves a method above a name it reads (counted in `[hazards]`, not `[scoped]`) and one whose translation
--- does not parse (`[translated]`) among them.
local function test_the_tree_checks_and_the_drivers_held_give_one_verdict_over_the_same_ceilings(dir: string)
  local root = dir .. "/oneverdict"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/hazard.tl", source("local record R", "  n: integer", "end", "local helper = 1",
    "function R:f(): integer", "  return self.n + helper", "end", "return R")))
  assert(Fs.write(root .. "/build/broken.tl", source("local t: {{string, integer}}", "return t")))
  assert(Fs.write(root .. "/build/bad.tl", source("local x: {number: integer}", "return x")))
  assert(Fs.write(root .. "/build/fine.tl", source("local record Fine", "  n: integer", "end", "return Fine")))
  local text = "[translated]\nbuild/broken.tl tuple_type 1\n[declared]\nbuild/bad.tl float_key 1\n"
  local pinned = assert(Ceilings.parse(text))
  local none = assert(Ceilings.parse(""))
  for _, file in ipairs({ "build/hazard.tl", "build/broken.tl", "build/bad.tl", "build/fine.tl" }) do
    local held = refused_by_the_tree(root, file, Ceilings.of(pinned, "scoped"), Ceilings.of(pinned, "translated"),
      Ceilings.of(pinned, "declared"))
    assert(held == refused_by_the_driver(root, file, pinned), file .. " over the ceilings: the tree says " .. tostring(held))
    local open = refused_by_the_tree(root, file, {}, {}, {})
    assert(open == refused_by_the_driver(root, file, none), file .. " over none: the tree says " .. tostring(open))
  end
  assert(not refused_by_the_tree(root, "build/hazard.tl", {}, {}, {}))
  assert(refused_by_the_tree(root, "build/broken.tl", {}, {}, {}) and refused_by_the_tree(root, "build/bad.tl", {}, {}, {}))
end

--- A `.d.tl` edited under a warm memo changes the answer for the modules that read it.
local function test_an_edit_of_the_declaration_of_a_module_given_as_declaration_and_source_misses_the_memo(dir: string)
  local root = dir .. "/declpair"
  assert(Fs.mkdirs(root .. "/p"))
  assert(Fs.mkdirs(root .. "/q"))
  assert(Fs.write(root .. "/p/foo.d.tl", source("local record Box", "  s: string", "end", "return Box")))
  assert(Fs.write(root .. "/p/foo.tl", source("local record Box", "  n: integer", "end", "return Box")))
  assert(Fs.write(root .. "/q/use.tl", source("local Box = require(\"foo\")", "local b: Box = { s = \"x\" }", "return b")))
  local memo = assert(Sqlite.memory())
  assert(#tree_checks.checked(root, {}, memo) == 0, table.concat(tree_checks.checked(root, {}), "\n"))
  assert(Fs.write(root .. "/p/foo.d.tl", source("local record Box", "  s: integer", "end", "return Box")))
  local again = table.concat(tree_checks.checked(root, {}, memo), "\n")
  assert(again:find("q/use.tl:2:", 1, true), again)
  assert(again == table.concat(tree_checks.checked(root, {}), "\n"), "a warm memo and a cold run agree")
  assert(memo:close())
end

--- The ceilings a check reads from the tree are refused when one names a file the tree lacks: no run could lower it.
local function test_a_ceiling_for_a_file_that_is_gone_is_refused_when_a_check_reads_the_trees_ceilings(dir: string)
  local root = dir .. "/deadceiling"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/there.tl", source("local x: integer = 1", "return x")))
  assert(Fs.write(root .. "/build/ceilings.txt", "[checked]\nbuild/there.tl nil_not_allowed 1\nbuild/gone.tl nil_not_allowed 1\n"))
  local found = tree_checks.checked(root)
  assert(#found == 1, table.concat(found, "\n"))
  assert(found[1]:find("holds ceilings for files that are gone", 1, true) ~= nil, found[1])
  assert(found[1]:find("build/gone.tl nil_not_allowed: pinned in [checked]", 1, true) ~= nil, found[1])
  assert(Fs.write(root .. "/build/ceilings.txt", "[checked]\nbuild/there.tl nil_not_allowed 1\n"))
  local fine = tree_checks.checked(root)
  assert(#fine == 1, table.concat(fine, "\n"))
  assert(fine[1] == "build/there.tl nil_not_allowed: pinned 1 but 0 found; lower the pin in build/ceilings.txt's [checked]", fine[1])
end

--- A file the fork's readers and their ports read alike passes, and so does one with a class made the way the tree makes
--- it; a file the check cannot compare (its translation does not parse, a declaration file, the fork's own) is left
--- out; a pin for a file that agrees is told to lower; and a reader that answers otherwise is named, refused past its pin.
local function test_the_readers_of_a_file_are_held_to_the_forks_but_for_their_pins(dir: string)
  local root = dir .. "/read"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/checker"))
  assert(Fs.write(root .. "/build/ok.tl", source(
    'local Fs = require("cosmic.fs")',
    "local record M",
    "  n: integer",
    "end",
    "function M.read(path: string): string | nil",
    "  local text = Fs.read(path)",
    "  return text",
    "end",
    "return M")))
  assert(Fs.write(root .. "/build/classy.tl", source(
    "local record R",
    "  n: integer",
    "  bump: function(R)",
    "end",
    "function R:bump()",
    "  self.n = self.n + 1",
    "end",
    "return R")))
  assert(Fs.write(root .. "/build/tuple.tl", source("local a: {{string, integer}}", "return a")))
  assert(Fs.write(root .. "/build/types.d.tl", source("global record G", "end")))
  assert(Fs.write(root .. "/checker/tl.tl", source("global record R", "end")))
  assert(#tree_checks.read(root, {}) == 0, table.concat(tree_checks.read(root, {}), "\n"))
  local fallen = tree_checks.read(root, { ["build/ok.tl"] = 1 })
  assert(#fallen == 1 and fallen[1] == "build/ok.tl: pinned 1 but 0 found; lower the pin in build/ceilings.txt's [read]",
    table.concat(fallen, "\n"))
  local made = stub.made
  stub.made = function(parsed: ast.Parsed, every?: boolean): stub.Made
    local right = made(parsed, every)
    return { text = right.text, pruned = not right.pruned }
  end
  local ok, raised = pcall(function(): string
    local found = tree_checks.read(root, {})
    local joined = table.concat(found, "\n")
    assert(joined:find("build/ok.tl: stub: pruned false against true", 1, true) ~= nil and
        joined:find("build/ok.tl: 1 reader differs from the fork's, pinned 0", 1, true) ~= nil and
        joined:find("build/classy.tl: stub: pruned", 1, true) ~= nil, joined)
    assert(joined:find("tuple.tl", 1, true) == nil and joined:find("types.d.tl", 1, true) == nil, joined)
    assert(#tree_checks.read(root, { ["build/ok.tl"] = 1, ["build/classy.tl"] = 1 }) == 0)
    return ""
  end)
  stub.made = made
  assert(ok, raised)
end

--- A file that has not changed is not read again: the memo answers, and a change to a reader reads the file again.
local function test_a_memo_answers_the_reader_check_until_a_reader_changes(dir: string)
  local root = dir .. "/readmemo"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/syntax_stub.tl", "-- one\n"))
  assert(Fs.write(root .. "/build/ok.tl", source("local x = 1", "return x")))
  local memo = assert(Sqlite.memory())
  assert(#tree_checks.read(root, {}, memo) == 0)
  local count = assert(Sqlite.rows(memo, "SELECT count(*) FROM check_memo WHERE kind = 'read'"))
  assert(count[1]:integer(1) == 2, "the file and the reader, each once")
  -- Plant another answer under the keys: a run that finds it did not read.
  assert(Sqlite.run(memo, "UPDATE check_memo SET value = 'D\tstub: planted'"))
  local hit = table.concat(tree_checks.read(root, {}, memo), "\n")
  assert(hit:find("build/ok.tl: stub: planted", 1, true) ~= nil, hit)
  -- A reader changed: the salt moves, and the file is read again.
  assert(Fs.write(root .. "/build/syntax_stub.tl", "-- two\n"))
  assert(#tree_checks.read(root, {}, memo) == 0)
  assert(memo:close())
end

--- A dimension of the analysis that compared no row over a tree of some size is a comparison of nothing with nothing,
--- and is named; a memo keeps how many rows each file compared, so that a warm run says what a cold one does.
local function test_a_dimension_of_the_analysis_that_compared_nothing_is_named_cold_and_warm(dir: string)
  local root = dir .. "/readempty"
  assert(Fs.mkdirs(root .. "/build"))
  for index = 1, 12 do
    assert(Fs.write(root .. "/build/small" .. index .. ".tl", source("local x = " .. index, "return x")))
  end
  local memo = assert(Sqlite.memory())
  local cold = tree_checks.read(root, {}, memo)
  local warm = tree_checks.read(root, {}, memo)
  assert(table.concat(cold, "\n") == table.concat(warm, "\n"), table.concat(warm, "\n"))
  -- The rows every file has are compared; the ones it has none of are named.
  local joined = table.concat(cold, "\n")
  assert(joined:find("analyzer tests: no row compared in 12 files", 1, true) ~= nil, joined)
  -- A file's export and policy rows count only where they say something: these files return a name and declare no policy.
  assert(joined:find("analyzer docs: no row compared", 1, true) ~= nil and
      joined:find("analyzer inputs: no row compared", 1, true) ~= nil and
      joined:find("analyzer export: no row compared", 1, true) == nil, joined)
  -- One file with a row of each kind is enough.
  assert(Fs.write(root .. "/build/rich_test.tl", source(
    'local Test = require("cosmic.test")',
    'local Fs = require("cosmic.fs")',
    'Test.policy{ env = { "HOME" } }',
    "--- Opens: see [`open`] and [`Fs.read`].",
    "local function open(path: string): nil, string",
    '  return nil, "the path is empty"',
    "end",
    "local function test_it() assert(Fs.read(\"x\") == nil) end",
    "function Example.open() assert(Fs.read(\"x\") == nil) end",
    "return open")))
  local rich = tree_checks.read(root, {}, memo)
  assert(#rich == 0, table.concat(rich, "\n"))
  assert(table.concat(tree_checks.read(root, {}, memo), "\n") == "")
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

--- What the fork's build wrote of that tree.
local function typed_fork(): Typed.Fork
  return { files = {
    ["cosmic/m.tl"] = { kind = "module", refused = false, refs = {} },
    ["build/use.tl"] = { kind = "module", refused = false, refs = { { module = "cosmic.m", member = "Item.n", line = 3 } } },
  } }
end

--- A tree the fork's build and the port read alike passes, and a difference in each dimension is named: the uses of a
--- record's fields, whether the discipline holds, which files it holds, and whether a standard-library module's stub types it
--- as its source; a pin for a file that agrees is told to lower.
local function test_a_tree_read_through_the_checkers_types_is_held_to_what_the_forks_build_wrote_of_it(dir: string)
  local root = dir .. "/typed"
  typed_tree(root)
  local counts: {string: integer} = {}
  local clean = tree_checks.typed(root, {}, nil, typed_fork(), counts)
  assert(#clean == 0, table.concat(clean, "\n"))
  assert(counts["typed refs"] == 1 and counts["contracts"] == 2 and counts["stub"] == 1 and counts["kind"] == 2, "counts")
  assert(counts["files compared"] == 2 and counts["rule exports"] == 1)
  local fork = typed_fork()
  fork.files["build/use.tl"].refs = {}
  local port_finds = table.concat(tree_checks.typed(root, {}, nil, fork), "\n")
  assert(port_finds:find("build/use.tl: typed refs: the port finds cosmic.m Item.n:3 and the fork does not", 1, true) ~= nil and
      port_finds:find("build/use.tl: 1 difference from the fork's build, pinned 0", 1, true) ~= nil, port_finds)
  assert(#tree_checks.typed(root, { ["build/use.tl"] = 1 }, nil, fork) == 0)
  local fallen = tree_checks.typed(root, { ["build/use.tl"] = 1 }, nil, typed_fork())
  assert(#fallen == 1 and fallen[1] == "build/use.tl: pinned 1 but 0 found; lower the pin in build/ceilings.txt's [typed]",
    table.concat(fallen, "\n"))
  fork = typed_fork()
  fork.files["build/use.tl"].refused = true
  fork.files["cosmic/m.tl"].kind = "test"
  local refused = table.concat(tree_checks.typed(root, {}, nil, fork), "\n")
  assert(refused:find("build/use.tl: contracts: the fork refuses it and the port finds nothing to refuse", 1, true) ~= nil and
      refused:find("cosmic/m.tl: kind: the build staged it as test, the port reads it as module", 1, true) ~= nil, refused)
  assert(tree_checks.typed(root, {}, nil, nil)[1]:find("no compile of the tree to compare with", 1, true) ~= nil)
end

--- The answer for a file is kept under its source, the sources of what it requires and the places the fork found a use at.
local function test_a_memo_answers_the_typed_check_until_the_tree_or_the_forks_rows_change(dir: string)
  local root = dir .. "/typedmemo"
  typed_tree(root)
  local memo = assert(Sqlite.memory())
  assert(#tree_checks.typed(root, {}, memo, typed_fork()) == 0)
  local count = assert(Sqlite.rows(memo, "SELECT count(*) FROM check_memo WHERE kind = 'typed'"))
  assert(count[1]:integer(1) == 2, "each file once")
  -- Plant a use under the keys: a run that finds it did not read.
  assert(Sqlite.run(memo, "UPDATE check_memo SET value = 'A\t1\nR\tcosmic.m\tItem.n\t9'"))
  local hit = table.concat(tree_checks.typed(root, {}, memo, typed_fork()), "\n")
  assert(hit:find("typed refs: the port finds cosmic.m Item.n:9", 1, true) ~= nil, hit)
  -- Another row of the fork's moves the key of that file: it is read again.
  local fork = typed_fork()
  fork.files["build/use.tl"].refs = { { module = "cosmic.m", member = "Item.n", line = 3 }, { module = "cosmic.m", member = "Item.n", line = 2 } }
  local again = table.concat(tree_checks.typed(root, {}, memo, fork), "\n")
  assert(again:find("the fork finds cosmic.m Item.n:2 and the port does not", 1, true) ~= nil, again)
  assert(memo:close())
end

--- A dimension that compared no row over a tree of some size, and a rule that judged no place in it, are named.
local function test_a_dimension_of_the_typed_check_that_compared_nothing_is_named(dir: string)
  local root = dir .. "/typedempty"
  assert(Fs.mkdirs(root .. "/build"))
  local fork: Typed.Fork = { files = {} }
  for index = 1, 12 do
    assert(Fs.write(root .. "/build/small" .. index .. ".tl", source("local x = " .. index, "return x")))
    fork.files["build/small" .. index .. ".tl"] = { kind = "module", refused = false, refs = {} }
  end
  local joined = table.concat(tree_checks.typed(root, {}, nil, fork), "\n")
  assert(joined:find("typed refs: no row compared in 12 files", 1, true) ~= nil and
      joined:find("stub: no row compared in 12 files", 1, true) ~= nil and
      joined:find("contracts used: no row compared in 12 files", 1, true) ~= nil and
      joined:find("contracts: the rule calls judged no place in 12 files", 1, true) ~= nil, joined)
  assert(joined:find("kind: no row compared", 1, true) == nil and joined:find("contracts: no row compared", 1, true) == nil, joined)
end

--- Each dimension reports a difference when its reader answers otherwise: a reader planted with another answer is named by
--- the dimension's name.
local function test_every_dimension_of_the_typed_comparison_reports_a_difference_in_its_reader(dir: string)
  local root = dir .. "/typedplant"
  typed_tree(root)
  assert(#tree_checks.typed(root, {}, nil, typed_fork()) == 0)
  local function planted(patch: function(): function(), wanted: string)
    local restore = patch()
    local ok, raised = pcall(function(): string
      local found = table.concat(tree_checks.typed(root, {}, nil, typed_fork()), "\n")
      assert(found:find(wanted, 1, true) ~= nil, "wanted " .. wanted .. " in:\n" .. found)
      return ""
    end)
    restore()
    assert(ok, raised)
  end
  local references = Receivers.references
  planted(function(): function()
    Receivers.references = function(subject: Report.Subject): {Receivers.Reference}
      local found = references(subject)
      found[#found + 1] = { module = "cosmic.m", member = "Item.planted", line = 99 }
      return found
    end
    return function() Receivers.references = references end
  end, "build/use.tl: typed refs: the port finds cosmic.m Item.planted:99")
  local check = SyntaxContracts.check
  planted(function(): function()
    SyntaxContracts.check = function(subject: Report.Subject, given?: Contracts.Exemptions): SyntaxContracts.Result
      local made = check(subject, given)
      made.problems[#made.problems + 1] = "x.tl:1: planted"
      return made
    end
    return function() SyntaxContracts.check = check end
  end, "contracts: the fork holds it and the port finds 1: x.tl:1: planted")
  planted(function(): function()
    SyntaxContracts.check = function(subject: Report.Subject, given?: Contracts.Exemptions): SyntaxContracts.Result
      local made = check(subject, given)
      made.used[#made.used + 1] = "casts cosmic/m.tl:planted"
      return made
    end
    return function() SyntaxContracts.check = check end
  end, "contracts used: the exemptions the fork needs")
  local difference = SyntaxStub.difference
  planted(function(): function()
    SyntaxStub.difference = function(_source: Declarations.Program, _stubbed: Declarations.Program, _module: string): string | nil
      return "planted"
    end
    return function() SyntaxStub.difference = difference end
  end, "cosmic/m.tl: stub: the fork holds it and the port finds: the stub a project's checker reads in its place types it differently")
  local kind_of = SyntaxContracts.kind_of
  planted(function(): function()
    SyntaxContracts.kind_of = function(_file: string): string
      return "test"
    end
    return function() SyntaxContracts.kind_of = kind_of end
  end, "kind: the build staged it as module, the port reads it as test")
end

--- A pin of `[typed]` covers the uses the port finds and the fork loses, and nothing else: a use only the fork finds is told
--- whatever the pin.
local function test_a_pin_of_the_typed_check_covers_only_the_uses_the_port_finds_and_the_fork_loses(dir: string)
  local root = dir .. "/typedpin"
  typed_tree(root)
  local fork = typed_fork()
  fork.files["build/use.tl"].refs = { { module = "cosmic.m", member = "Item.n", line = 3 }, { module = "cosmic.m", member = "Item.m", line = 2 } }
  local found = table.concat(tree_checks.typed(root, { ["build/use.tl"] = 5 }, nil, fork), "\n")
  assert(found:find("the fork finds cosmic.m Item.m:2 and the port does not", 1, true) ~= nil and
      found:find("1 difference from the fork's build that no pin covers", 1, true) ~= nil, found)
end

--- The calls the checker gave no function are held to a ceiling that only falls.
local function test_a_call_the_checker_could_type_no_function_for_is_held_to_its_ceiling(dir: string)
  local root = dir .. "/typeduntyped"
  typed_tree(root)
  assert(Fs.write(root .. "/build/open.tl", source("local x = missing(2)", "local y = x.field(1)", "return y")))
  local fork = typed_fork()
  fork.files["build/open.tl"] = { kind = "module", refused = false, refs = {} }
  local found = table.concat(tree_checks.typed(root, {}, nil, fork), "\n")
  assert(found:find("build/open.tl: 2 calls the checker gave no function, which no rule of the discipline judged, pinned 0", 1, true) ~=
      nil, found)
  assert(#tree_checks.typed(root, {}, nil, fork, nil, { ["build/open.tl"] = 2 }) == 0)
  local fallen = tree_checks.typed(root, {}, nil, fork, nil, { ["build/open.tl"] = 3 })
  assert(#fallen == 1 and fallen[1] == "build/open.tl: pinned 3 but 2 found; lower the pin in build/ceilings.txt's [untyped]",
    table.concat(fallen, "\n"))
end

--- A tree with the headers of the bindings of C declares them from the headers (as the build derives them), so a call of one is
--- judged; a tree without them leaves the bindings untyped.
local function test_the_bindings_of_c_are_typed_where_the_tree_has_their_headers(dir: string)
  local root = dir .. "/typedbindings"
  typed_tree(root)
  local user = source("local sys = require(\"cosmic.sys\")", "sys.unlink(\"x\")", "return {}")
  assert(Fs.write(root .. "/build/uses_sys.tl", user))
  local fork = typed_fork()
  fork.files["build/uses_sys.tl"] = { kind = "module", refused = false, refs = {} }
  assert(#tree_checks.typed(root, {}, nil, fork, nil, { ["build/uses_sys.tl"] = 1 }) == 0, "untyped: no header, no judgment")
  assert(Fs.mkdirs(root .. "/core"))
  for _, header in ipairs({ "core/syscalls.h", "core/process.h", "core/socket.h" }) do
    assert(Fs.write(root .. "/" .. header, (assert(Fs.read(header)))))
  end
  local found = table.concat(tree_checks.typed(root, {}, nil, fork, nil, {}), "\n")
  assert(found:find("build/uses_sys.tl: contracts: the fork holds it and the port finds 1: build/uses_sys.tl:2: sys.unlink: " ..
      "its failure is ignored", 1, true) ~= nil, found)
end

--- The projection the tree checks build is the one a lookup of the same mode reads ([`writer.other_code`]): in the new
--- mode `cosmic docs` and the link check of `cosmic fix --check .` leave out one the fork's compiler wrote, and answer
--- from the standard library alone, so every link to the tree's own modules would fail.
local function test_the_projection_of_the_tree_checks_is_written_in_the_mode_asked(tmp: string)
  local modes: {GrammarMode.Mode} = { "teal", "new" }
  for _, mode in ipairs(modes) do
    local root = tmp .. "/" .. mode
    assert(Fs.mkdirs(root .. "/core"))
    assert(Fs.write(root .. "/core/.keep", ""))
    assert(Fs.mkdirs(root .. "/build"))
    assert(Fs.write(root .. "/build/ceilings.txt", ""))
    assert(Fs.write(root .. "/build/importer.tl", "local record importer\nend\n\nreturn importer\n"))
    assert(Fs.mkdirs(root .. "/checker"))
    assert(Fs.write(root .. "/checker/stdlib.d.tl", (assert(Fs.read("checker/stdlib.d.tl")))))
    assert(Fs.write(root .. "/checker/tl.tl", (assert(Fs.read("checker/tl.tl")))))
    assert(Fs.write(root .. "/things.tl", "--- Opens.\nlocal function open(): integer\n  return 1\nend\n\nreturn open\n"))
    local db = assert(tree_checks.projection(root, (assert(teal.load())), mode))
    local own, trouble = writer.other_code(db, rebuild.compiled_by(mode))
    assert(own == nil and trouble == "", mode .. ": " .. tostring(own) .. trouble)
    local other: GrammarMode.Mode = mode == "new" and "teal" or "new"
    assert(writer.other_code(db, rebuild.compiled_by(other)) ~= nil, mode .. ": read as " .. other)
    assert(db:close())
  end
end
