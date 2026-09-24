--- Every export earns its place (doc/design.md, principle 5): a member
--- of a module's returned record in `build/`, `cmd/`, `eval/` or the
--- public `cosmic/` has a use outside its own module that is not a
--- test. For the standard library that use may be a worked example
--- (`cosmic/<module>_example.tl`) or a guide under doc/guides, each of
--- which is compiled and run like any other code, so an export no
--- program calls is kept only when a runnable example shows it. An
--- export only its own tests call is made local -- the test goes
--- through the public entry -- or is named in `allowed` with the reason
--- it is tested directly.
---
--- It is a whole-tree question, so it is asked of the whole tree's
--- shipped database, `o/cosmic.db`: its `docs` table holds every
--- export and its `uses` table every use the build found, through a
--- `require` alias (`build.positions`) or a value's checked type
--- (`build.receivers`).

local Sqlite = require("cosmic.sqlite")
local fixture = require("build.docs_fixture")

--- The exports kept although nothing outside their module but a test
--- uses them, by `<module>.<member>`, and why each is kept.
local allowed: {string: string} = {}

--- A script `cosmic --standalone` runs (see its opening comment): its
--- `main` fetches, execs or reads the machine, so its test drives each
--- step directly, offline.
local script <const> = "tested directly: a standalone script whose main " ..
  "fetches, execs or reads the machine; the test drives this step offline"

for _, name in ipairs({
  "build.actionlint.read_pin", "build.actionlint.host", "build.actionlint.asset",
  "build.actionlint.url", "build.actionlint.args", "build.actionlint.names_files",
  "build.actionlint.repo_root", "build.actionlint.ensure_installed",
  "build.actionlint.exec_status",
  "build.zig.read_pin", "build.zig.host", "build.zig.repo_root", "build.zig.build_jobs",
  "build.zig.build_args", "build.zig.sweep", "build.zig.sources", "build.zig.fetch",
  "build.zig.ensure_installed", "build.zig.resolve", "build.zig.global_cache",
  "build.zig.project_cache", "build.zig.exec_status", "build.zig.snapshot",
  "build.zig.changed", "build.zig.race_report", "build.zig.child_status", "build.zig.run",
  "build.vendor.read_pin", "build.vendor.is_direct_rewrite", "build.vendor.repo_root",
  "build.vendor.all_names", "build.vendor.matches", "build.vendor.fetch",
  "build.verify_codesign.verify",
  "eval.arena.prompt", "eval.arena.lay",
  "eval.check.notes.status", "eval.check.notes.failed_in_cosmic",
  "eval.check.notes.built_notes", "eval.check.notes.reset_evidence",
  "eval.check.notes.evidence", "eval.check.notes.grade",
  "eval.summarize.paths", "eval.summarize.report",
}) do
  allowed[name] = script
end

--- A step of a `cosmic <verb>`, whose own entry (`run`) reads the
--- working tree and prints: the test calls the step on a fixture.
local verb_step <const> = "tested directly: a step of a cosmic verb whose run " ..
  "reads the working tree and prints; the test calls the step on a fixture"

for _, name in ipairs({
  "build.docs.lookup", "build.docs.uses", "build.docs.render",
  "build.embed.database", "build.embed.tree",
  "build.fix.source", "build.fix.chosen", "build.fix.notes",
  "build.sql.options_given", "build.sql.source", "build.sql.open", "build.sql.query",
  "build.standalone.compile",
  "build.test.matches", "build.test.verdict_key", "build.test.keyable",
  "build.test.worker_environment",
  "build.todos.parse_blame", "build.todos.list", "build.todos.date",
  "build.todos.render", "build.todos.search",
}) do
  allowed[name] = verb_step
end

allowed["build.c.layout.same"] = "tested directly: whether two layouts are one " ..
  "token stream is the rule `cosmic fix` holds a C rewrite to, and the test " ..
  "states it on sources too small to be a file"
allowed["build.coverage.lines.executable"] = "tested directly: the test compares " ..
  "what executable_cached keeps against what this computes afresh"
allowed["build.fix.spill.message"] = "tested directly: the test writes a refusal " ..
  "line in the checker's own words"
allowed["build.fix.spill.sites"] = "tested directly: the test hands it refusal " ..
  "text without a compile"
allowed["build.importer.analyzer_modules"] = "tested directly: the test holds the " ..
  "list to every module the analysis requires"
allowed["build.test_worker.encode"] = "tested directly: the test checks that a " ..
  "report survives the trip through descriptor 3"
allowed["build.writer.signature"] = "tested directly: the test signs a database " ..
  "as an older binary would"
-- TODO: make build.contracts' `exempt`, `parsing` and `quiet` local once
-- #2086 merges; this change leaves build/contracts.tl alone so as not to
-- conflict with it.
allowed["build.contracts.exempt"] = "waits on #2086, which edits build/contracts.tl"
allowed["build.contracts.parsing"] = "waits on #2086, which edits build/contracts.tl"
allowed["build.contracts.quiet"] = "waits on #2086, which edits build/contracts.tl"

--- Every export the tree's database `db` holds that nothing earns, as
--- `<file>:<line>: <module>.<member>`, sorted.
---
--- What counts as an export: a function or a value field of a module's
--- returned record, in a module whose file is in `build/`, `cmd/` or
--- `eval/`, or in `cosmic/` outside `cosmic/internal/`. Left out:
---
--- - a record, enum or type the module declares, and a field naming
---   one (`Module: Module`, a type's CamelCase name): a type is a
---   shape its members' uses already account for;
--- - a nested record's own fields (`ZipWriter.add_file`): the shape of
---   a value the module hands out, which its caller reads or fills in
---   through that value;
--- - `main`, which `cosmic <file>` and `cosmic --standalone` call on a
---   module that returns a record carrying one, and a module that
---   returns a function (`build/boot.tl`), which its loader calls;
--- - a declaration file (`*.d.tl`) and `cosmic.sys`, whose members are
---   declared in C (`core/syscalls.h`), not in Teal.
---
--- What earns one: a use from another module that is not a `*_test.tl`,
--- or, for a module only tests import (`build/docs_fixture.tl`, test
--- support), a use from a test other than the module's own.
-- TODO: `cosmic.sys` is left out, so a constant or binding in
-- core/syscalls.h that nothing uses (`EISDIR`, `SIGUSR1`, `POLLNVAL`)
-- is never flagged; hold its members to the same rule once the check
-- can tell a binding the Teal layer wraps from one nothing reaches.
-- TODO: hold a private build/ function's optional parameter to the same
-- standard -- one no call passes, tests included, is dropped -- once
-- `refs` records how many arguments each call passes; build/ast/node.tl's
-- `lang?`, build/c/rules.tl's `declared?` and build/artifact.tl's
-- `selected_configuration?` on `test_prefix` were found by hand.
local function unearned(db: Sqlite.Handle): {string}
  local rows = assert(Sqlite.text_rows(db,
    "SELECT d.file || ':' || d.line || ': ' || d.module || '.' || d.symbol " ..
    "FROM docs d " ..
    "WHERE d.exported = 1 AND d.symbol <> '' AND instr(d.symbol, '.') = 0 " ..
    "AND d.kind IN ('function', 'method', 'field') " ..
    "AND d.signature NOT GLOB 'type *' AND d.symbol NOT GLOB '[A-Z]*[a-z]*' " ..
    "AND d.symbol <> 'main' " ..
    "AND NOT (d.kind = 'function' AND d.symbol = d.source_symbol) " ..
    "AND (d.file GLOB 'build/*' OR d.file GLOB 'cmd/*' OR d.file GLOB 'eval/*' " ..
    "OR (d.file GLOB 'cosmic/*' AND d.file NOT GLOB 'cosmic/internal/*')) " ..
    "AND d.file GLOB '*.tl' AND d.file NOT GLOB '*.d.tl' " ..
    "AND NOT EXISTS (SELECT 1 FROM uses u " ..
    "WHERE u.module = d.module AND u.symbol = d.symbol " ..
    "AND u.from_module <> d.module " ..
    "AND (u.from_file NOT GLOB '*_test.tl' OR (u.from_module <> d.module || '_test' " ..
    "AND NOT EXISTS (SELECT 1 FROM imports i " ..
    "WHERE i.requires = d.module AND i.path NOT GLOB '*_test')))) " ..
    "ORDER BY d.file, d.line"))
  local out: {string} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = row[1]
  end
  return out
end

--- What `unearned` finds that `excused` does not name, and each name in
--- `excused` that `unearned` no longer finds: an allowance outlives
--- the reason for it when the export is used or gone.
local function judged(db: Sqlite.Handle, excused: {string: string}): {string}, {string}
  local found: {string: boolean} = {}
  local refused: {string} = {}
  for _, line in ipairs(unearned(db)) do
    local name = line:match(": ([^ ]+)$")
    found[name] = true
    if excused[name] == nil then
      refused[#refused + 1] = line
    end
  end
  local stale: {string} = {}
  for name in pairs(excused) do
    if not found[name] then
      stale[#stale + 1] = name
    end
  end
  table.sort(stale)
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
      "function thing.main() end",
      "thing.limit = 3",
      "",
      "return thing"),
  }
  for path, text in pairs(callers) do files[path] = text end
  return files
end

--- An export only its own module or a test uses is flagged; one another
--- module calls is not, nor a type, a nested record's field or `main`.
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

--- The tree's own exports, read from the database the build wrote
--- before any test runs: every one is earned or allowed, and every
--- allowance still excuses something.
local function test_every_export_in_the_tree_earns_its_place()
  local db = assert(Sqlite.open("o/cosmic.db", false))
  local refused, stale = judged(db, allowed)
  assert(db:close())
  assert(#refused == 0, "exports nothing outside their module uses but a test -- " ..
    "make each local, or name it in build/exports_test.tl's `allowed` with why:\n" ..
    table.concat(refused, "\n"))
  assert(#stale == 0, "allowances for exports now used or gone -- remove them:\n" ..
    table.concat(stale, "\n"))
end
