--- `build.tree_checks`' `exports` on fixture trees: which exports earn
--- their place, and when an allowance goes stale. The tree's own
--- exports are held to it by `cosmic fix --check .`, not here.

local Sqlite = require("cosmic.sqlite")
local fixture = require("build.docs_fixture")
local tree_checks = require("build.tree_checks")

--- What `tree_checks.exports` finds in `db` against `excused`: the
--- exports it refuses, as `<file>:<line>: <module>.<member>`, and the
--- allowances it finds stale, by name.
local function judged(db: Sqlite.Handle, excused: {string: string}): {string}, {string}
  local refused, stale: {string}, {string} = {}, {}
  for _, line in ipairs(tree_checks.exports(db, excused)) do
    local export = line:match("^(%S+:%d+: %S+): nothing outside")
    local allowance = line:match("^(%S+): allowed, but")
    if export ~= nil then
      refused[#refused + 1] = export
    elseif allowance ~= nil then
      stale[#stale + 1] = allowance
    else
      error("not a line of the exports check: " .. line)
    end
  end
  return refused, stale
end

--- Lines as one source file's text.
local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- A tree of one private module, `build/thing.tl`, whose exports are
--- used as `callers` says: each entry a file's path and its source.
local function tree(callers: {string: string}): {string: string}
  local files: {string: string} = {
    ["build/thing.tl"] = source(
      "local record thing",
      "  record Box",
      "    open: function(Box)",
      "  end",
      "  Name: Box",
      "  limit: integer",
      "end",
      "",
      "function thing.used() end",
      "function thing.tested() end",
      "function thing.alone() end",
      "thing.limit = 3",
      "",
      "return thing"),
  }
  for path, text in pairs(callers) do files[path] = text end
  return files
end

--- An export only its own module or a test uses is flagged; one another
--- module calls is not, nor a type or a nested record's field.
local function test_an_export_only_a_test_calls_is_flagged(dir: string)
  local db = fixture.database(dir, tree({
    ["build/user.tl"] = source(
      "local thing = require(\"build.thing\")",
      "thing.used()",
      "return {}"),
    ["build/thing_test.tl"] = source(
      "local thing = require(\"build.thing\")",
      "local function test_it()",
      "  thing.tested()",
      "end"),
  }))
  local refused, stale = judged(db, {})
  assert(table.concat(refused, "\n") ==
    "build/thing.tl:6: build.thing.limit\n" ..
    "build/thing.tl:10: build.thing.tested\n" ..
    "build/thing.tl:11: build.thing.alone", table.concat(refused, "\n"))
  assert(#stale == 0)
end

--- An allowance excuses the export it names, and one that names an
--- export something now uses is stale.
local function test_an_allowance_excuses_and_goes_stale(dir: string)
  local db = fixture.database(dir, tree({
    ["build/user.tl"] = source(
      "local thing = require(\"build.thing\")",
      "thing.used()",
      "thing.limit = thing.limit + 1",
      "return {}"),
  }))
  local refused, stale = judged(db, {
    ["build.thing.tested"] = "tested directly",
    ["build.thing.alone"] = "kept for a reason",
    ["build.thing.used"] = "no longer needed",
  })
  assert(#refused == 0, table.concat(refused, "\n"))
  assert(table.concat(stale, " ") == "build.thing.used", table.concat(stale, " "))
end

--- A module only tests import is test support: a use from another
--- module's test earns its exports, one from its own test does not.
local function test_a_test_earns_the_exports_of_test_support(dir: string)
  local db = fixture.database(dir, tree({
    ["build/thing_test.tl"] = source(
      "local thing = require(\"build.thing\")",
      "local function test_it()",
      "  thing.tested()",
      "end"),
    ["build/other_test.tl"] = source(
      "local thing = require(\"build.thing\")",
      "local function test_it()",
      "  thing.used()",
      "  thing.alone()",
      "  local _ = thing.limit",
      "end"),
  }))
  local refused = judged(db, {})
  assert(table.concat(refused, "\n") == "build/thing.tl:10: build.thing.tested",
    table.concat(refused, "\n"))
end

--- A program -- a module whose record exports `main` or `run` -- may
--- export a step its own tests call; another module's test does not
--- earn one. `main` itself needs no caller: `cosmic <file>` calls it.
local function test_a_program_exports_steps_its_own_tests_call(dir: string)
  local db = fixture.database(dir, {
    ["build/prog.tl"] = source(
      "local record prog",
      "end",
      "function prog.step() end",
      "function prog.topic() end",
      "function prog.other() end",
      "function prog.run() end",
      "function prog.main() end",
      "return prog"),
    ["build/user.tl"] = source(
      "local prog = require(\"build.prog\")",
      "prog.run()",
      "return {}"),
    ["build/prog_test.tl"] = source(
      "local prog = require(\"build.prog\")",
      "local function test_it()",
      "  prog.step()",
      "end"),
    ["build/prog_topic_test.tl"] = source(
      "local prog = require(\"build.prog\")",
      "local function test_it()",
      "  prog.topic()",
      "end"),
    ["build/elsewhere_test.tl"] = source(
      "local prog = require(\"build.prog\")",
      "local function test_it()",
      "  prog.other()",
      "end"),
  })
  local refused = judged(db, {})
  assert(table.concat(refused, "\n") == "build/prog.tl:5: build.prog.other",
    table.concat(refused, "\n"))
end

--- A program's topic test is its own, but a sibling module's test is
--- not, though its name starts the same way.
local function test_a_sibling_module_test_is_not_a_program_topic(dir: string)
  local db = fixture.database(dir, {
    ["build/prog.tl"] = source(
      "local record prog",
      "end",
      "function prog.step() end",
      "function prog.run() end",
      "return prog"),
    ["build/prog_worker.tl"] = source(
      "local prog = require(\"build.prog\")",
      "prog.run()",
      "return {}"),
    ["build/prog_worker_test.tl"] = source(
      "local prog = require(\"build.prog\")",
      "local worker = require(\"build.prog_worker\")",
      "local function test_it()",
      "  prog.step()",
      "  local _ = worker",
      "end"),
  })
  local refused = judged(db, {})
  assert(table.concat(refused, "\n") == "build/prog.tl:3: build.prog.step",
    table.concat(refused, "\n"))
end

--- A public module with `run` is no program: what only its own test
--- calls still needs a caller or a worked example.
local function test_a_public_module_with_run_still_needs_an_example(dir: string)
  local db = fixture.database(dir, {
    ["cosmic/thing.tl"] = source(
      "local record Thing",
      "end",
      "function Thing.step() end",
      "function Thing.run() end",
      "return Thing"),
    ["cosmic/thing_example.tl"] = source(
      "local Thing = require(\"cosmic.thing\")",
      "local Example = {}",
      "function Example.run()",
      "  Thing.run()",
      "end",
      "return Example"),
    ["cosmic/thing_test.tl"] = source(
      "local Thing = require(\"cosmic.thing\")",
      "local function test_it()",
      "  Thing.step()",
      "end"),
  })
  local refused = judged(db, {})
  assert(table.concat(refused, "\n") == "cosmic/thing.tl:3: cosmic.thing.step",
    table.concat(refused, "\n"))
end

--- A public export is earned by a worked example as by any caller; a
--- test alone does not earn it.
local function test_a_worked_example_earns_a_public_export(dir: string)
  local db = fixture.database(dir, {
    ["cosmic/thing.tl"] = source(
      "local record Thing",
      "end",
      "function Thing.shown() end",
      "function Thing.hidden() end",
      "return Thing"),
    ["cosmic/thing_example.tl"] = source(
      "local Thing = require(\"cosmic.thing\")",
      "local Example = {}",
      "function Example.shown()",
      "  Thing.shown()",
      "end",
      "return Example"),
    ["cosmic/thing_test.tl"] = source(
      "local Thing = require(\"cosmic.thing\")",
      "local function test_it()",
      "  Thing.hidden()",
      "end"),
    ["build/user.tl"] = source(
      "local Thing = require(\"cosmic.thing\")",
      "return Thing"),
  })
  local refused = judged(db, {})
  assert(table.concat(refused, "\n") == "cosmic/thing.tl:4: cosmic.thing.hidden",
    table.concat(refused, "\n"))
end
