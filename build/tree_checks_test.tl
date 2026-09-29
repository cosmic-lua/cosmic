--- `build.tree_checks` on fixture trees, each built to a projection by
--- the build's own code (`build.docs_fixture`): every check refuses a
--- tree with the defect it is for planted in it, and passes the same
--- tree without it.

local fixture = require("build.docs_fixture")
local tree_checks = require("build.tree_checks")

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
  assert(#found == 1 and found[1]:find("^build/thing%.tl:4: build%.thing%.alone: nothing outside")
    ~= nil, table.concat(found, "\n"))
  assert(#tree_checks.exports(db, { ["build.thing.alone"] = "kept for a reason" }) == 0)
  found = tree_checks.exports(db, { ["build.thing.alone"] = "kept for a reason",
    ["build.thing.used"] = "no longer needed" })
  assert(#found == 1 and found[1]:find("^build%.thing%.used: allowed, but") ~= nil,
    table.concat(found, "\n"))
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
  assert(#found == 1 and found[1]:find("^`cosmic docs which` answers nothing first, not Proc.find")
    ~= nil, table.concat(found, "\n"))
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
  assert(#found == 1 and found[1]:find("^`cosmic docs unions_and_their_members` answers nothing")
    ~= nil, table.concat(found, "\n"))
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

--- Only the public standard library's files are held to earn no note.
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
  assert(#found == 1 and found[1]:find("^`thing`'s guide is \"a missing heading\", which is no `## ` heading")
    ~= nil, table.concat(found, "\n"))
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
  assert(#found == 2 and found[1]:find("^`thing`'s tests name build%.gone_test, which is no test module")
    ~= nil and found[2]:find("name build%.thing, which is no test module") ~= nil,
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
  assert(#found == 1 and found[1]:find("^`thing` names no test module in `tests`, as string literals")
    ~= nil, table.concat(found, "\n"))

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

--- Every check runs, each line named by its check: a projection with
--- none of the tree's own anchors, stand-ins, docs or quieted records
--- fails each check that expects them.
local function test_a_run_names_each_check(dir: string)
  local db = fixture.database(dir, {
    ["build/thing.tl"] = source("local record thing", "end", "return thing"),
  })
  local seen: {string: boolean} = {}
  for _, line in ipairs(tree_checks.run(db, "")) do
    seen[line:match("^([^:]+): ") or line] = true
  end
  for _, name in ipairs({ "exports", "doc anchors", "compiler readers", "stand-ins",
                          "docs queries", "quieted" }) do
    assert(seen[name], name .. " reported nothing on a projection that has none of the tree")
  end
end
