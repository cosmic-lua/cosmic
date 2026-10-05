--- The checks over cosmic's whole tree, which no one module's test can
--- make: every export earned, no two doc anchors sharing a name, every
--- reader of the compiler's identity named, every familiar command
--- finding what stands in for it, every docs query a compile advertises
--- answered, every quieted method one a module declares, every
--- declaration's requires declared, every verb's spec listed and
--- readable, no public doc citing the build or carrying a TODO, and no
--- literal plural after a number. Each asks the tree's projection,
--- `o/cosmic.db`, which holds every module's docs, uses, imports,
--- examples and source.
---
--- A test reads its own module's closure and no more (the rule the
--- suite's `store` declaration is kept to), so these are not tests.
--- `cosmic fix` runs them when it covers all of cosmic's own tree
--- (`cosmic fix --check .`, which CI runs), after building the
--- projection afresh (`projection`), and each line a check answers
--- fails the run. A `cosmic fix` of some paths does not run them, and a
--- tree that does not build fails them all.
---
--- Each check takes the projection and, optionally, what it holds the
--- tree to (`allowed`, the anchors expected, ...), which defaults to the
--- tree's own, so its test can hand it a fixture database and a list of
--- its own.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local closure_store = require("build.closure_store")
local contracts = require("build.contracts")
local declared_key = require("build.declared_key")
local ast = require("build.ast")
local docs = require("build.docs")
local docs_checks = require("build.docs_checks")
local link_text = require("build.link_text")
local importer = require("build.importer")
local shared_compiles = require("build.shared_compiles")
local symbols = require("build.symbols")
local work = require("build.work")
local writer = require("build.writer")
local type compiler = require("build.compiler")
local String = require("cosmic.string")

local type Node = ast.Node

local record tree_checks
  --- What [`plurals`] finds in one text of a file, read off a parse made
  --- before the checks ran ([`plurals_in`]).
  record Plurals
    --- The text the sites were found in.
    source: string
    sites: {{string}}
  end
end

--- The exports kept although nothing outside their module but a test
--- uses them, by `<module>.<member>`, and why each is kept.
local allowed: {string: string} = {}

allowed["cosmic.sandbox.restrict"] = "tested directly: it holds the process that calls it " ..
  "for good, so a worked example would hold the run that shows it; the test restricts " ..
  "a child of this program, and the harness holds its workers with it once the " ..
  "design's test phase lands (the TODO at build.confine's forbid_running)"
allowed["cosmic.test.needs_of"] = "tested directly: the worker's translation of a policy, " ..
  "which the build's own reading of one (build.analyzer, which cannot require this " ..
  "module) is held to by cosmic/test_policy_test.tl"
allowed["build.c.layout.same"] = "tested directly: whether two layouts are one " ..
  "token stream is the rule `cosmic fix` holds a C rewrite to, and the test " ..
  "states it on sources too small to be a file"
for _, name in ipairs({ "sleep_ns", "ceil" }) do
  allowed["cosmic.time." .. name] = "the old name of cosmic.clock's " .. name .. ", kept " ..
    "for programs outside the tree that call it; in the tree only its own tests do"
end
-- TODO: drop these entries once [`Test.policy`]'s `requires` reads the table
-- (the runner's use of build.host_requires, the next step of the host
-- requirements design).
for _, name in ipairs({ "names", "parse", "class", "new", "answer" }) do
  allowed["build.host_requires." .. name] = "the table of what a test may require of its " ..
    "host, which no runner path reads yet; its test does"
end
allowed["build.flow.bare"] = "the subset build/workflows_test.tl holds " ..
  "workflows to takes a bare key by the same rule the layout writes one by"
allowed["build.flow.problems"] = "the subset build/workflows_test.tl holds " ..
  "the workflows to, which the layout is also held to"
allowed["build.flow.comments"] = "what the fuzz test holds a layout to keep"
allowed["build.analyzer.analyze"] = "a convenience the tests call, a parse and " ..
  "analysis_of; every caller outside them calls analysis_of on a parse it has"
for _, name in ipairs({ "parse", "render", "scalar", "from", "write", "value", "get", "set", "update" }) do
  allowed["build.flow." .. name] = "the API a program generates or edits a workflow " ..
    "through, which no program in the tree does yet; its test and the workflows' own do"
end
allowed["build.verb_list.entries"] = "what build/verb_list_test.tl holds each verb's spec name to"
allowed["build.identity.compiler_modules"] = "what build/importer_test.tl holds the tree to, " ..
  "walked over the running binary's modules: every module build.importer requires is " ..
  "in the compiler's identity or left out of it with a reason"
allowed["build.identity.writer_modules"] = "what build/importer_test.tl holds the tree to, " ..
  "walked over the running binary's modules: what build.writer reaches is in the " ..
  "writer's identity, the compiler's, or neither with a reason"
allowed["build.identity.writer_left_out"] = "what build/importer_test.tl holds to the " ..
  "requires of the writer's roots"
allowed["build.reboot.carries_tree_code"] = "what build/reboot_test.tl holds to " ..
  "the modules a tree holds and the binary carries"
allowed["build.declared_key.preimage"] = "what build/declared_key_fuzz_test.tl " ..
  "holds to distinct specs spelling apart, before a key hashes it"
allowed["build.declared_key.dispatched"] = "what build/dispatched_features_test.tl " ..
  "holds the tree's CPU dispatch sites to: the features a key holds are the ones they read"
allowed["build.declared_key.system_sources"] = "what build/host_features_test.tl " ..
  "holds .github/scripts/host-features.sh to: it reads a macOS host's system where a key does"
allowed["build.coverage.lines.executable"] = "tested directly: the test compares " ..
  "what executable_cached keeps against what this computes afresh"
allowed["build.confine.confine"] = "a test's own declaration: " ..
  "what the processes a test starts need, which only a test makes"
allowed["build.confine.must_confine"] = "a test's own declaration: " ..
  "what the processes a test starts need, with no fallback, which only a test makes"
allowed["build.confine.unsandboxed_reason"] = "a test's own skip reason: the line " ..
  "of a nested run's output that says no worker was sandboxed"
allowed["build.fix.spill.message"] = "tested directly: the test writes a refusal " ..
  "line in the checker's own words"
allowed["build.fix.spill.sites"] = "tested directly: the test hands it refusal " ..
  "text without a compile"
for _, name in ipairs({ "key", "open", "close", "look", "settle", "analyzers", "requires",
    "look_parse" }) do
  allowed["build.shared_compiles." .. name] = "tested directly: build/shared_compiles_test.tl, " ..
    "build/shared_parses_test.tl and build/importer_test.tl read and write the cache file " ..
    "itself, to see what a build shared and what a salt does to a key"
end
allowed["build.importer.analyzer_modules"] = "tested directly: the test holds the " ..
  "list to every module the analysis requires"
allowed["build.importer.analyzer_identity"] = "tested directly: the test names " ..
  "the analyzer of a projection it wrote as the binary would, which no " ..
  "running binary but the tree's own carries"
allowed["build.importer.tree_code"] = "tested directly: the test holds what a " ..
  "boot names its analyzer by to what the tool it writes names it by, around a " ..
  "derive run as a boot runs it, which no binary under the suite otherwise does"
allowed["build.harness_epoch.acknowledged"] = "the digest of each module of the " ..
  "harness a person last acknowledged, which only its test reads: a record of a choice, " ..
  "which the key leaves to `epoch`"
allowed["build.harness_epoch.retired"] = "every token the harness's epoch held " ..
  "before, which only its test reads: it holds the epoch's count to one past them, so " ..
  "each bump draws a token of its own"
allowed["build.harness_epoch.library"] = "the standard-library modules the harness " ..
  "may reach, each with its reason, which only its test reads: a rule the test holds " ..
  "the harness's digests to, not code the harness runs"
allowed["build.test_inputs.lua_loads"] = "what build/lua_children_test.tl holds " ..
  "a child's `-e` to loading no more than, as the artifact a `lua` module's children " ..
  "run carries them"
allowed["build.test_inputs.standalone_loads"] = "what build/lua_standalone_test.tl " ..
  "holds a child's `--standalone` to loading no more than, beside `lua_loads`, as the " ..
  "artifact a module that requires build.standalone's children run carries them"
allowed["build.closure_store.loaded_beside"] = "what build/lua_standalone_test.tl " ..
  "holds a closure store to carrying beside a module of its closure, which a `lua` " ..
  "module's children run from"
allowed["build.test.value_imports"] = "tested directly: the harness's test reads, " ..
  "by it, what each module the harness runs requires by value, as `key_code` walks it"
allowed["build.test.type_only_imports"] = "tested directly: the harness's test holds " ..
  "it to the edges `value_imports` leaves out; `run` reads it through the projection"
allowed["build.importer.prune_references"] = "tested directly: the test asks " ..
  "SQLite for the statement's plan, which must read `compiled` once rather " ..
  "than probe it per row, and no behaviour tells the two apart"
allowed["build.reboot.auto_boot"] = "tested directly: the test hands it an " ..
  "environment rather than setting COSMIC_AUTO_BOOT on the whole run"
allowed["build.reboot.boot_into"] = "tested directly: the test runs it on a tree " ..
  "whose bin/zig is a stand-in, which no stale tool can reach"
allowed["build.reboot.compiler_moved"] = "tested directly: the test hands it " ..
  "identities, where a stale tool's compiler can only be had by building one"
allowed["build.reboot.rebuild_failed"] = "tested directly: the test runs it on a " ..
  "tree whose bin/zig is a stand-in, which no stale tool can reach"
allowed["build.reboot.own_tool"] = "tested directly: the test hands it the path " ..
  "a tool was started as, which the running one cannot change"
allowed["build.writer.signature"] = "tested directly: the test signs a database " ..
  "as an older binary would"

--- Every export the projection `db` holds that nothing earns, as
--- `<file>:<line>: <module>.<member>`, sorted.
---
--- An export earns its place (doc/design.md, principle 5) by a use
--- outside its own module that is not a test. For the standard library
--- that use may be a worked example (`cosmic/<module>_example.tl`) or a
--- guide under doc/guides, each of which is compiled and run like any
--- other code, so an export no program calls is kept only when a
--- runnable example shows it. An export only its own tests call is made
--- local -- the test goes through the public entry -- or is named in
--- `allowed` with the reason it is tested directly. A use is one the
--- build found, through a `require` alias ([`build.analyzer`]) or a
--- value's checked type ([`build.receivers`]).
---
--- What counts as an export: a function or a value field of a module's
--- returned record, in a module whose file is in `build/`, `cmd/` or
--- `eval/`, or in `cosmic/` outside `cosmic/internal/`. Left out:
---
--- - a record, enum or type the module declares, and a field naming
---   one (`Module: Module`, a type's CamelCase name): a type is a
---   shape its members' uses already account for;
--- - a nested record's own fields (`Writer.add_file`): the shape of
---   a value the module hands out, which its caller reads or fills in
---   through that value;
--- - `main`, which `cosmic <file>` and `cosmic --standalone` call on a
---   module that returns a record carrying one, and a module that
---   returns a function ([`build/boot.tl`]), which its loader calls;
--- - a declaration file (`*.d.tl`) and [`cosmic.sys`], whose members are
---   declared in C ([`core/syscalls.h`]), not in Teal.
---
--- What earns one: a use from another module that is not a `*_test.tl`;
--- for a module only tests import ([`build/docs_fixture.tl`], test
--- support), a use from a test other than the module's own; and for a
--- program in `build/`, `cmd/` or `eval/` -- a module whose record
--- exports `main`, `run` or `spec` (a verb's entry,
--- build/verb_spec.tl), which fetches, execs or reads the working
--- tree and prints -- a use from its own tests, which drive each step
--- directly on a fixture. A module's own tests are `<module>_test`,
--- `<module>_<topic>_test` and the tests in its directory when it is
--- one (`build/fix/`), except the test of another module: `<x>_test`
--- where `<x>` is itself a module ([`build.test_worker_test`] is not
--- [`build.test`]'s). A public `cosmic/` module is never a program here:
--- what its tests call still needs a caller or an example.
-- TODO: the check is not transitive: an export used only by another
-- export that is itself allowed, or itself unused, counts as earned.
-- Walk the uses from what is earned outright once a use records the
-- function it sits in, not only its module and line.
-- TODO: [`cosmic.sys`] is left out, so a constant or binding in
-- core/syscalls.h that nothing uses (`EISDIR`, `SIGUSR1`)
-- is never flagged; hold its members to the same rule once the check
-- can tell a binding the Teal layer wraps from one nothing reaches.
-- TODO: hold a private build/ function's optional parameter to the same
-- standard -- one no call passes, tests included, is dropped -- once
-- `refs` records how many arguments each call passes; build/ast/node.tl's
-- `lang?`, build/c/rules.tl's `declared?` and build/artifact.tl's
-- `selected_configuration?` on `test_prefix` were found by hand.
local function unearned(db: Sqlite.Handle): {string} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
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
      "AND (u.from_file NOT GLOB '*_test.tl' " ..
      "OR (u.from_module <> d.module || '_test' AND NOT EXISTS (SELECT 1 FROM imports i " ..
      "WHERE i.requires = d.module AND i.path NOT GLOB '*_test')) " ..
      "OR (d.file NOT GLOB 'cosmic/*' " ..
      "AND (u.from_module GLOB d.module || '_*' OR u.from_module GLOB d.module || '.*') " ..
      "AND (substr(u.from_module, 1, length(u.from_module) - 5) = d.module " ..
      "OR NOT EXISTS (SELECT 1 FROM imports j " ..
      "WHERE j.path = substr(u.from_module, 1, length(u.from_module) - 5) " ..
      "OR j.requires = substr(u.from_module, 1, length(u.from_module) - 5))) " ..
      "AND EXISTS (SELECT 1 FROM docs p WHERE p.module = d.module AND p.exported = 1 " ..
      "AND p.symbol IN ('main', 'run', 'spec'))))) " ..
      "ORDER BY d.file, d.line")
  if rows == nil then
    return nil, trouble
  end
  local out: {string} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = row[1]
  end
  return out
end

--- Every export of `db` that nothing earns (see `unearned`) and
--- `excused`, by default `allowed`, does not name, as `<file>:<line>:
--- <module>.<member>: ...`, and then each name in `excused` that
--- nothing unearned answers to any more: an allowance outlives the
--- reason for it when the export is used or gone.
function tree_checks.exports(db: Sqlite.Handle, excused?: {string: string}): {string}
  excused = excused or allowed
  local lines, trouble = unearned(db)
  if lines == nil then
    return { "reading the exports: " .. trouble }
  end
  local found: {string: boolean} = {}
  local out: {string} = {}
  for _, line in ipairs(lines) do
    local name = line:match(": ([^ ]+)$")
    found[name] = true
    if excused[name] == nil then
      out[#out + 1] = line .. ": nothing outside its module uses it but a test -- " ..
        "make it local, or name it in build/tree_checks.tl's `allowed` with why"
    end
  end
  local stale: {string} = {}
  for name in pairs(excused) do
    if not found[name] then
      stale[#stale + 1] = name .. ": allowed, but now used or gone -- remove its allowance"
    end
  end
  table.sort(stale)
  for _, line in ipairs(stale) do out[#out + 1] = line end
  return out
end

--- One row of the public catalog, as `anchors` reads it.
local record Row
  module: string
  symbol: string
  kind: string
  signature: string
  text: string
  file: string
  line: string
end

--- Whether `signature` names the type `name` as a whole word.
local function mentions(signature: string, name: string): boolean
  return signature:find("%f[%w_]" .. name .. "%f[^%w_]") ~= nil
end

--- The records the tree's doc anchors are known to be, as
--- `<module> <record>`: each must still be taken for one, so a change
--- to what counts as an anchor cannot leave the check vacuous.
local anchors_expected: {string} = { "cosmic.cli Cli", "cosmic.layout Layout",
  "cosmic.entrypoint Entrypoint", "cosmic.errno Errno" }

--- Every pair of doc anchors in `db` that share a bare name, as
--- `<file>:<line>: <module> <symbol> and <module> <symbol>: ...`,
--- sorted, and then each of `expected` (by default the tree's own
--- anchors) that is no longer taken for one.
---
--- Every name `cosmic docs <name>` resolves to a doc anchor answers
--- with that one anchor (doc/design.md, principle 8). A bare name
--- matches every symbol ending in it -- `cosmic docs read` lists each
--- `X.read`, by design -- so a real member that shares an anchor's name
--- ([`Proc.Relaunch.argv`] beside [`Entrypoint.argv`]) is listed beside it
--- as any two members are. What is refused is two anchors sharing one:
--- a reader asking for the verb `test` would also be shown the layout
--- rule for test files.
---
--- A doc anchor is a record of a public `cosmic/` module that exists to
--- be looked up, not passed around: every field of it is a documented
--- `string` (`test: string` in [`cosmic.cli`]'s `Cli`), and no function
--- or method in the public catalog takes or returns it. [`cosmic.shape`]'s
--- `Failure` has only strings too, but `failures` hands it out, so its
--- fields are an API's, not anchors.
function tree_checks.anchors(db: Sqlite.Handle, expected?: {string}): {string}
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT module, symbol, kind, signature, text, file, line FROM docs WHERE " ..
      symbols.public_only("module", true) .. " ORDER BY module, id")
  if rows == nil then
    return { "reading the public catalog: " .. trouble }
  end
  local all: {Row} = {}
  for _, r in ipairs(rows) do
    all[#all + 1] = { module = r[1], symbol = r[2], kind = r[3], signature = r[4],
      text = r[5], file = r[6], line = r[7] }
  end
  -- What takes or returns a value: a function, a method, or a field
  -- whose type is a function.
  local callable: {string} = {}
  for _, r in ipairs(all) do
    if r.kind == "function" or r.kind == "method" or
        (r.kind == "field" and r.signature:find("function", 1, true) ~= nil) then
      callable[#callable + 1] = r.signature
    end
  end
  local by_name: {string: {Row}} = {}
  local found: {string: boolean} = {}
  for _, owner in ipairs(all) do
    if owner.kind == "record" then
      local prefix = owner.symbol .. "."
      local fields: {Row} = {}
      local anchor = true
      for _, r in ipairs(all) do
        if r.module == owner.module and String.starts_with(r.symbol, prefix) and
            r.symbol:find(".", #prefix + 1, true) == nil then
          local name = r.symbol:sub(#prefix + 1)
          fields[#fields + 1] = r
          if r.kind ~= "field" or r.signature ~= name .. ": string" or r.text == "" then
            anchor = false
          end
        end
      end
      for _, signature in ipairs(callable) do
        if mentions(signature, owner.symbol) then anchor = false end
      end
      if anchor then
        found[owner.module .. " " .. owner.symbol] = true
        for _, r in ipairs(fields) do
          local name = r.symbol:sub(#prefix + 1)
          local list = by_name[name] or {}
          list[#list + 1] = r
          by_name[name] = list
        end
      end
    end
  end
  local out: {string} = {}
  for name, list in pairs(by_name) do
    for i = 2, #list do
      local first, other = list[1], list[i]
      out[#out + 1] = string.format(
        "%s:%s: %s %s and %s %s: `cosmic docs %s` answers both -- rename one",
        other.file, other.line, first.module, first.symbol, other.module, other.symbol, name)
    end
  end
  table.sort(out)
  for _, name in ipairs(expected or anchors_expected) do
    if not found[name] then
      out[#out + 1] = name .. " is no longer taken for a doc anchor"
    end
  end
  return out
end

--- Whether `line` reads the compiler's identity, or a `meta` row by a
--- name no reader can see: [`Store.meta`] called with anything but a
--- string.
local function reads(line: string): boolean
  for _, name in ipairs({ "compiler", "compiled_by" }) do
    for _, quote in ipairs({ '"', "'" }) do
      if line:find("meta%(%s*" .. quote .. name .. quote .. "%s*%)") ~= nil then return true end
    end
  end
  return line:find("Store%.meta%(%s*[^\"'%s]") ~= nil and line:find("^%s*function ") == nil
end

--- Each module of `db` that reads the compiler's identity through
--- [`Store.meta`] and `named` (by default [`build.declared_key`]'s
--- [`compiler_readers`]) does not name, and then each it names that no
--- longer reads it.
---
--- A closure store carries no such row ([`build.closure_store`]), so a
--- worker's read of it is answered by the running tool, and only a
--- test whose closure holds a named reader is keyed by the tool's
--- identity. A reader the list misses would leave a verdict standing
--- that turned on a compiler no key held.
function tree_checks.compiler_readers(db: Sqlite.Handle, named?: {string}): {string}
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT path, CAST(inflate(source) AS TEXT) FROM modules ORDER BY path")
  if rows == nil then
    return { "reading the modules' sources: " .. trouble }
  end
  local found: {string: boolean} = {}
  for _, row in ipairs(rows) do
    for line in String.lines(row[2]) do
      if reads(line) then
        found[row[1]] = true
        break
      end
    end
  end
  local listed: {string: boolean} = {}
  for _, name in ipairs(named or declared_key.compiler_readers) do listed[name] = true end
  local missing, stale: {string}, {string} = {}, {}
  for name in pairs(found) do
    if not listed[name] then
      missing[#missing + 1] = name .. " reads the compiler's identity, but " ..
        "build/key_parts.tl's `compiler_readers` does not name it, so no key " ..
        "of a test that runs it holds it"
    end
  end
  for name in pairs(listed) do
    if not found[name] then
      stale[#stale + 1] = name .. " is named in build/key_parts.tl's " ..
        "`compiler_readers`, but no longer reads the compiler's identity -- remove it"
    end
  end
  table.sort(missing)
  table.sort(stale)
  for _, line in ipairs(stale) do missing[#missing + 1] = line end
  return missing
end

--- What a newcomer types first, and the function that stands in for it.
local stand_ins_expected: {{string}} = {
  { "which", "Proc.find" },
  { "command -v", "Proc.find" },
  { "Proc.which", "Proc.find" },
  { "cp -R", "Fs.copy_tree" },
  { "mkdir -p", "Fs.mkdirs" },
  { "rm -rf", "Fs.remove_tree" },
  { "unlink", "Fs.remove" },
  { "ls", "Fs.list" },
  { "find type", "Fs.walk" },
  { "mktemp", "Fs.mkdtemp" },
  { "realpath", "Fs.absolute" },
  { "mv", "Fs.rename" },
  { "ln -s", "Fs.symlink" },
  { "touch", "Fs.set_mtime" },
  { "nproc", "Proc.cpu_count" },
  { "isatty", "Proc.is_tty" },
  { "getpid", "Proc.pid" },
  { "curl", "Http.download" },
  { "wget", "Http.download" },
  { "tar -x", "Archive.extract" },
  { "unzip", "Archive.extract" },
  { "sha256sum", "Hash.hex_sha256" },
  { "sleep", "Clock.sleep_ns" },
  { "getentropy", "Rand.entropy" },
  { "getenv", "Env.get" },
  { "urandom", "Rand.entropy" },
}

--- Each of `cases` (by default the tree's own), a command or call and
--- the function that stands in for it, that `cosmic docs <command>`,
--- looked up the way a project sees the standard library in `db`, does
--- not answer with that function first, after any raw [`cosmic.sys`]
--- binding of that name. What a newcomer types first is the command or
--- call they would have used elsewhere, so a doc comment that stops
--- naming its command is caught here, not by the next person who writes
--- the function again.
function tree_checks.stand_ins(db: Sqlite.Handle, cases?: {{string}}): {string}
  local looked, trouble = docs.view({ db }, { true })
  if looked == nil then
    return { "reading the docs: " .. trouble }
  end
  local out: {string} = {}
  for _, case in ipairs(cases or stand_ins_expected) do
    local found, lookup_trouble = docs.lookup(looked, case[1])
    local first = "nothing"
    if found == nil then
      first = "nothing (" .. lookup_trouble .. ")"
    else
      -- A raw binding of the same name may come first; what stands in
      -- for it must come right after.
      for _, entry in ipairs(found) do
        if entry.module ~= "cosmic.sys" then
          first = entry.source_symbol
          break
        end
      end
    end
    if first ~= case[2] then
      out[#out + 1] = "`cosmic docs " .. case[1] .. "` answers " .. first .. " first, not " ..
        case[2] .. " -- name the command in " .. case[2] .. "'s doc comment"
    end
  end
  return out
end

--- The worked examples a reader is pointed to or expected to find by a
--- compile's failure: every one [`build.importer`] advertises, and the
--- guide to a type's shape, which no hint names but a malformed type's
--- diagnostic leaves its reader to look up.
local function queries_expected(): {string}
  local out: {string} = {}
  for _, query in pairs(importer.diagnostic_queries) do out[#out + 1] = query end
  out[#out + 1] = "enums_arrays_maps_tuples"
  table.sort(out)
  return out
end

--- Each of `wanted` (by default what a compile's failure points to) that
--- `cosmic docs` does not answer from `db`.
function tree_checks.queries(db: Sqlite.Handle, wanted?: {string}): {string}
  local looked, trouble = docs.view({ db }, { true })
  if looked == nil then
    return { "reading the docs: " .. trouble }
  end
  local out: {string} = {}
  for _, query in ipairs(wanted or queries_expected()) do
    local found, lookup_trouble = docs.lookup(looked, query)
    if found == nil then
      out[#out + 1] = "`cosmic docs " .. query .. "`: " .. lookup_trouble
    elseif #found == 0 then
      out[#out + 1] = "`cosmic docs " .. query .. "` answers nothing, though a " ..
        "compile's failure points its reader there"
    end
  end
  return out
end

--- Each of `names` (by default [`build.contracts`]' `quieted`), as
--- `<module> <symbol>`, that no module of `db` declares.
function tree_checks.quieted(db: Sqlite.Handle, names?: {string}): {string}
  local out: {string} = {}
  for _, name in ipairs(names or contracts.quieted_names()) do
    local module, symbol = name:match("^(%S+) (%S+)$")
    local rows, trouble = Sqlite.text_rows(db,
      "SELECT 1 FROM docs WHERE module = ?1 AND symbol = ?2 LIMIT 1",
      { { text = module or "" }, { text = symbol or "" } })
    if rows == nil then
      return { "reading the docs: " .. trouble }
    end
    if #rows == 0 then
      out[#out + 1] = name .. " is quieted in build/contracts.tl, but no module " ..
        "declares it -- remove it"
    end
  end
  return out
end

--- Each declaration of `db` that requires a name no declaration of `db`
--- answers for, as `<declaration> requires <name>`: a closure store
--- follows a declaration's requires among declarations alone
--- ([`build.closure_store`]'s `declared`), so a module one required would
--- be neither carried nor in the store's address.
function tree_checks.declarations(db: Sqlite.Handle): {string}
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT path, CAST(inflate(source) AS TEXT) FROM decls ORDER BY path")
  if rows == nil then
    return { "reading the declarations: " .. trouble }
  end
  local declared: {string:boolean} = {}
  for _, row in ipairs(rows) do declared[row[1]] = true end
  local out: {string} = {}
  for _, row in ipairs(rows) do
    for _, name in ipairs(closure_store.required_by(row[2])) do
      if not declared[name] then
        out[#out + 1] = row[1] .. " requires " .. name .. ", which is no declaration: " ..
          "a closure store follows a declaration's requires among declarations alone " ..
          "(build/closure_store.tl's `declared`), so declare what it needs of " .. name ..
          " in a declaration, or teach the store to follow a module"
      end
    end
  end
  return out
end

--- Whether `path`, relative to the tree's root, is a source of the
--- public standard library: `cosmic/` outside `cosmic/internal/`. A
--- note [`build.fix.near`] makes on one fails the whole tree's check: the
--- standard library as it stands earns no note against itself, so a
--- note on a file is about what that file adds.
function tree_checks.standard(path: string): boolean
  while path:sub(1, 2) == "./" do path = path:sub(3) end
  return path:sub(1, 7) == "cosmic/" and path:sub(1, 16) ~= "cosmic/internal/"
end

--- Builds the tree at `root`, cosmic's own, into its projection,
--- `o/cosmic.db`, as `cosmic test` does before any test reads it, and
--- opens it. `cosmic fix` rebuilds the tool it runs as when that is
--- stale, but not the projection, which holds what the tool does not
--- carry (its tests and examples among it). A module the build refuses
--- is a failure: the checks would read a projection without it.
function tree_checks.projection(root: string, built: compiler): Sqlite.Handle | nil, string
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return nil, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, true)
  if staged == nil then
    local _, _ = work.close(handle)
    return nil, stage_trouble
  end
  local result, compile_trouble = importer.compile(handle, built,
    Store.meta("compiler") or "", false, shared_compiles.for_build())
  if result == nil then
    local _, _ = work.close(handle)
    return nil, compile_trouble
  end
  if #result.refused > 0 then
    local _, _ = work.close(handle)
    return nil, "the tree does not build:\n" .. table.concat(result.refused, "\n")
  end
  local path = root .. "/o/cosmic.db"
  local written, write_trouble = writer.write_result(handle, path, result)
  local closed, close_trouble = work.close(handle)
  if not written then
    return nil, write_trouble
  end
  if not closed then
    return nil, close_trouble
  end
  return Sqlite.open(path)
end

--- A spec table's top-level fields as its source writes them: `name`,
--- `guide` and the like as string literals, `tests` as a list of them.
--- A field of another shape (a variable, a long string, a list with a
--- non-literal in it) is `nonliteral`.
local record Fields
  strings: {string:string}
  lists: {string:{string}}
  nonliteral: {string:boolean}
end

--- The value of the string literal that opens at `at` (a quote) and the
--- index after its closing quote.
local function scan_string(text: string, at: integer): string, integer
  local quote = text:sub(at, at)
  local named: {string:string} = { n = "\n", t = "\t" }
  local out: {string} = {}
  local i = at + 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == quote then
      return table.concat(out), i + 1
    elseif c == "\\" then
      local after = text:sub(i + 1, i + 1)
      out[#out + 1] = named[after] or after
      i = i + 2
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out), i
end

--- One token of a spec's source: a string literal (`kind` "str", its
--- `value` unescaped), a long string ("long"), a name ("word") or a mark
--- ("mark"), one character.
local record Token
  kind: string
  value: string
end

--- The tokens of the table that opens at the first `{` of `text` from
--- `start`, through its closing brace. Comments are skipped, and a string's
--- braces and quotes stay its own.
local function tokens_of(text: string, start: integer): {Token}
  local out: {Token} = {}
  local i = text:find("{", start, true)
  if i == nil then return out end
  local depth = 0
  while i <= #text do
    local c = text:sub(i, i)
    if text:sub(i, i + 1) == "--" then
      i = text:find("\n", i, true) or #text + 1
    elseif c == "\"" or c == "'" then
      local value, after = scan_string(text, i)
      out[#out + 1] = { kind = "str", value = value }
      i = after
    elseif text:match("^%[=*%[", i) ~= nil then
      local level = text:match("^%[(=*)%[", i)
      local close = text:find("]" .. level .. "]", i, true)
      out[#out + 1] = { kind = "long", value = "" }
      i = close ~= nil and close + #level + 2 or #text + 1
    elseif c:match("[%a_]") then
      local word = text:match("^[%w_]+", i)
      out[#out + 1] = { kind = "word", value = word }
      i = i + #word
    else
      if c == "{" then depth = depth + 1 end
      if c == "}" then depth = depth - 1 end
      if not c:match("%s") then out[#out + 1] = { kind = "mark", value = c } end
      i = i + 1
      if depth == 0 then break end
    end
  end
  return out
end

--- The top-level fields of the spec table that opens after `start` in
--- `text`. The projection holds a table's signature and docs but not its
--- values ([`build.docs`]), so a spec's fields are read from its source, as
--- literals; a first occurrence of a name wins, and a `name = "..."` that
--- a function body inside the table writes at its own top level would be
--- taken for a field (a spec's `run` is one line that calls another
--- function, so none does).
local function spec_fields(text: string, start: integer): Fields
  local fields: Fields = { strings = {}, lists = {}, nonliteral = {} }
  local tokens = tokens_of(text, start)
  local depth = 0
  local i = 1
  while i <= #tokens do
    local token = tokens[i]
    if token.kind == "mark" and token.value == "{" then
      depth = depth + 1
    elseif token.kind == "mark" and token.value == "}" then
      depth = depth - 1
    elseif depth == 1 and token.kind == "word" and tokens[i + 1] ~= nil and
        tokens[i + 1].value == "=" and tokens[i + 1].kind == "mark" and
        tokens[i + 2] ~= nil and tokens[i + 2].value ~= "=" then
      local name, value = token.value, tokens[i + 2]
      if value.kind == "str" then
        if fields.strings[name] == nil then fields.strings[name] = value.value end
        i = i + 2
      elseif value.kind == "mark" and value.value == "{" then
        local list: {string} = {}
        local j = i + 3
        while tokens[j] ~= nil and not (tokens[j].kind == "mark" and tokens[j].value == "}") do
          if tokens[j].kind == "str" then
            list[#list + 1] = tokens[j].value
          elseif not (tokens[j].kind == "mark" and (tokens[j].value == "," or tokens[j].value == ";")) then
            fields.nonliteral[name] = true
          end
          j = j + 1
        end
        if fields.lists[name] == nil then fields.lists[name] = list end
        i = j
      elseif value.kind == "long" or value.kind == "word" then
        fields.nonliteral[name] = true
        i = i + 2
      end
    end
    i = i + 1
  end
  return fields
end

--- Each verb's registration (build/verb_spec.tl) that its module leaves
--- short:
---
--- - a module of `db` that assigns a `spec` but that build/verb_list.tl
---   does not require, so nothing dispatches to it;
--- - a listed verb whose module has no spec assigned as a table literal
---   to `<x>.spec` or `<x>.<y>_spec` at the start of a line, which
---   nothing here could then read;
--- - a `guide` that names no `## ` heading of `quickstart` (the text of
---   doc/guides/quickstart.md) whose section mentions `cosmic <name>`,
---   nor gives a reason ("none: ...");
--- - `tests` that is empty or names a module that is no test of `db`.
---
--- A spec is read from its module's source, where `name`, `guide` and
--- `tests` must be literals ([`spec_fields`]): the listing module cannot be
--- loaded here (it reaches [`build.fix`], which runs this), and the
--- projection holds no table's values, so there is no row to read
--- instead. The limit is decided: a spec built any other way (a local
--- table exported afterward, fields computed) is refused as a listed verb
--- with no spec here, not passed over. `help`, which dispatch assigns to a
--- local and no list holds, is not read. A verb's `Cli` prose is held by
--- build/verbs_store_test.tl, and a bare verb's `passthrough` by
--- build/verb_list_test.tl.
---
--- With no `quickstart` (its file unread, which `fix` has reported), the
--- guides are not held to it.
function tree_checks.verbs(db: Sqlite.Handle, quickstart: string | nil): {string}
  local out: {string} = {}
  local required, trouble = Sqlite.text_rows(db,
    "SELECT requires FROM imports WHERE path = 'build.verb_list'")
  if required == nil then
    return { "reading the imports: " .. trouble }
  end
  local listed: {string:boolean} = {}
  for _, row in ipairs(required) do listed[row[1]] = true end
  local modules, module_trouble = Sqlite.text_rows(db,
    "SELECT path, kind, CAST(inflate(source) AS TEXT) FROM modules ORDER BY path")
  if modules == nil then
    return { "reading the modules: " .. module_trouble }
  end
  local kinds: {string:string} = {}
  local texts: {string:string} = {}
  for _, row in ipairs(modules) do
    kinds[row[1]] = row[2]
    texts[row[1]] = row[3]
  end

  -- Each `## ` heading of the quickstart, outside a fenced block, and the
  -- text of its section.
  local sections: {string:string} = {}
  local current: string | nil = nil
  local fenced = false
  for line in String.lines(quickstart or "") do
    if line:match("^```") then fenced = not fenced end
    local heading = not fenced and line:match("^## (.+)$") or nil
    if heading ~= nil then
      current = heading
      sections[heading] = sections[heading] or ""
    elseif current ~= nil then
      sections[current] = sections[current] .. line .. "\n"
    end
  end

  -- The spec each listed entry loads, `require("<module>").<field>`, so a
  -- listed verb whose spec cannot be read is not passed over.
  local expected: {string:{string}} = {}
  for entry_module, field in (texts["build.verb_list"] or ""):gmatch(
      "require%(\"([%w_.]+)\"%)%.([%w_]*spec)") do
    expected[entry_module] = expected[entry_module] or {}
    table.insert(expected[entry_module], field)
  end
  local found_fields: {string:{string:boolean}} = {}

  for _, row in ipairs(modules) do
    if row[2] ~= "test" then
      local assigned = 0
      local at = 1
      while true do
        local first, last, field = row[3]:find("\n[%w_]+%.([%w_]*spec) = {", at)
        if first == nil then break end
        at = last + 1
        if field == "spec" or field:match("^[%w_]*_spec$") ~= nil then
          assigned = assigned + 1
          found_fields[row[1]] = found_fields[row[1]] or {}
          found_fields[row[1]][field] = true
          local spec = spec_fields(row[3], last)
          local name = spec.strings.name or "?"
          if not listed[row[1]] then
            out[#out + 1] = "`" .. name .. "` (" .. row[1] .. ") assigns a `spec` but " ..
              "build/verb_list.tl does not list its module, so no verb dispatches to it -- " ..
              "list it there"
          end
          local guide = spec.strings.guide
          if guide == nil then
            out[#out + 1] = "`" .. name .. "` has no guide as a string literal: name its `## ` " ..
              "heading in doc/guides/quickstart.md, or \"none: <why>\""
          elseif guide:sub(1, 5) == "none:" then
            if guide:sub(6):match("^%s*$") then
              out[#out + 1] = "`" .. name .. "` has no guide and gives no reason after \"none:\""
            end
          elseif quickstart ~= nil then
            local section = sections[guide]
            if section == nil then
              out[#out + 1] = "`" .. name .. "`'s guide is \"" .. guide .. "\", which is no `## ` " ..
                "heading of doc/guides/quickstart.md -- name one, or \"none: <why>\""
            elseif not section:find("cosmic " .. name, 1, true) then
              out[#out + 1] = "`" .. name .. "`'s guide is \"" .. guide .. "\", whose section " ..
                "never mentions `cosmic " .. name .. "` -- name the section that does, or " ..
                "\"none: <why>\""
            end
          end
          local tests = spec.lists.tests
          if tests == nil or #tests == 0 or spec.nonliteral.tests then
            out[#out + 1] = "`" .. name .. "` names no test module in `tests`, as string literals"
          end
          for _, test in ipairs(tests or {}) do
            if kinds[test] ~= "test" then
              out[#out + 1] = "`" .. name .. "`'s tests name " .. test ..
                ", which is no test module of the tree"
            end
          end
        end
      end
    end
  end
  local unread: {string} = {}
  for entry_module, fields in pairs(expected) do
    for _, field in ipairs(fields) do
      if not (found_fields[entry_module] or {})[field] then
        unread[#unread + 1] = "build/verb_list.tl loads `" .. entry_module .. "`'s `" .. field ..
          "`, but that module assigns no `<x>." .. field .. " = {` table literal at the start " ..
          "of a line, which is how a spec is read here"
      end
    end
  end
  table.sort(unread)
  for _, line in ipairs(unread) do out[#out + 1] = line end
  return out
end

--- Every `doc/guides/*.md` is either a user guide, which the binary
--- carries ([`symbols.guides`]), or one named in [`symbols.internal_guides`]
--- with its reason. A guide in neither would silently not ship.
function tree_checks.guides(db: Sqlite.Handle): {string}
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT path FROM modules WHERE path GLOB 'doc.guides.*' ORDER BY path")
  if rows == nil then
    return { "reading the guides: " .. trouble }
  end
  local known: {string: boolean} = {}
  for _, name in ipairs(symbols.guides) do known[name] = true end
  for name in pairs(symbols.internal_guides) do known[name] = true end
  local out: {string} = {}
  for _, row in ipairs(rows) do
    local name = row[1]:sub(#"doc.guides." + 1)
    if not known[name] then
      out[#out + 1] = "doc/guides/" .. name .. ".md is in neither `symbols.guides` nor " ..
        "`symbols.internal_guides` (build/symbols.tl): name it in one, so it ships or " ..
        "is left out on purpose"
    end
  end
  return out
end

--- The public doc text that may cite an implementation path, by
--- `<module> <symbol> <rule>` (`doc_rules`' name; `(module)` for a
--- module's own doc), and why each stays.
local doc_exempt: {string: string} = {}

doc_exempt["cosmic.cli Cli.todos todo"] = "`cosmic todos` lists the tree's " ..
  "`TODO:` comments: the marker is the verb's subject"

--- The rules a public doc is held to: a name, the Lua pattern that
--- finds a candidate, whether the candidate breaks the rule (given the
--- text around it and the tree's module names), and what to do instead.
local record DocRule
  name: string
  pattern: string
  breaks: function(before: string, hit: string, after: string, modules: {string: boolean}): boolean
  fix: string
end

--- The `build.<name>` modules whose name is also a file a reader knows:
--- `build.zig` is zig's build script, not build/zig.tl.
local FILE_NAMES: {string: boolean} = { zig = true }

--- Whether `hit`, a `build.<name>` found in prose, names a module of the
--- tree (or a package under one): [`build.this_program`], not "the build."
local function names_a_module(hit: string, modules: {string: boolean}): boolean
  local name = hit:match("^build%.([%w_.]*[%w_])")
  if name ~= nil and FILE_NAMES[name] then return false end
  while name ~= nil and name ~= "" do
    if modules["build." .. name] then return true end
    name = name:match("^(.*)%.[^.]*$")
  end
  return false
end

local doc_rules: {DocRule} = {
  { name = "todo", pattern = "TODO:", fix = "move the TODO to a `--` comment where the better fix would go",
    breaks = function(_b: string, _h: string, _a: string, _m: {string: boolean}): boolean
      return true
    end },
  { name = "path", pattern = "%f[%w_]build/", fix = "say what a caller needs, not where the build keeps it",
    breaks = function(_b: string, _h: string, _a: string, _m: {string: boolean}): boolean
      return true
    end },
  { name = "path", pattern = "%f[%w_]build%.[%w_]+[%w_.]*", fix = "say what a caller needs, not which build module does it",
    breaks = function(before: string, hit: string, _a: string, modules: {string: boolean}): boolean
      return before ~= "/" and before ~= "." and names_a_module(hit, modules)
    end },
  { name = "path", pattern = "%f[%w_]core/", fix = "say what a caller needs, not which C file does it",
    breaks = function(_b: string, _h: string, _a: string, _m: {string: boolean}): boolean
      return true
    end },
  { name = "path", pattern = "cosmic%.internal%f[^%w_]",
    fix = "say what a caller needs, not which internal module does it",
    breaks = function(_b: string, _h: string, _a: string, _m: {string: boolean}): boolean
      return true
    end },
  { name = "path", pattern = "cosmic/internal/", fix = "say what a caller needs, not which internal module does it",
    breaks = function(_b: string, _h: string, _a: string, _m: {string: boolean}): boolean
      return true
    end },
  { name = "path", pattern = "%f[%w_]vendor/", fix = "say what a caller needs, not which vendored tree does it",
    breaks = function(_b: string, _h: string, _a: string, _m: {string: boolean}): boolean
      return true
    end },
  -- A C file's name: a word of three letters or more and `.c` or `.h`,
  -- not a system header in angle brackets nor the tail of a dotted name.
  { name = "path", pattern = "%f[%w_][%l_][%l_][%l_]+%.[ch]%f[^%w_]",
    fix = "say what a caller needs, not which C file does it",
    breaks = function(before: string, _h: string, after: string, _m: {string: boolean}): boolean
      return before ~= "<" and before ~= "." and after ~= ">" and after ~= "."
    end },
}

--- Every `---` doc text that a public source shows in `db` (see
--- `symbols.shown_docs`: a public module's, [`core/syscalls.h`]'s, which
--- is [`cosmic.sys`], and the shipped user guides'), and every `--` run
--- adjacent to a declaration, which `cosmic docs` folds into its doc
--- text, that carries a `TODO:` or cites an implementation path, one
--- line per hit as `<file>:<line>: <module> <symbol>: ...` with the
--- fix, and then each name in `excused` (by default `doc_exempt`) that
--- nothing answers to any more.
---
--- A doc is what `cosmic docs` shows a caller ([`link_text.unlinked`]:
--- no definition a code span's link reads), in a binary that carries
--- neither the build nor the C. A TODO belongs in a `--` comment set
--- off from the doc by a blank line (AGENTS.md); a path or a `build.`
--- module is a fact about the implementation, which the doc says as
--- what a caller can rely on. The paths refused are `build/`, a
--- `build.<module>` the tree has, `core/`, `cosmic.internal`,
--- `cosmic/internal/`, `vendor/` and a C file's name (`foo.c`, not a
--- header in angle brackets). `build.zig` is a file name, not a module.
function tree_checks.public_docs(db: Sqlite.Handle, excused?: {string: string}): {string}
  excused = excused or doc_exempt
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT d.module, d.symbol, d.text, d.file, d.line FROM docs d WHERE " ..
      symbols.shown_docs("d", true) .. " AND d.text <> '' ORDER BY d.file, d.line, d.id")
  if rows == nil then
    return { "reading the public docs: " .. trouble }
  end
  local names, names_trouble = Sqlite.text_rows(db, "SELECT path FROM modules")
  if names == nil then
    return { "reading the modules: " .. names_trouble }
  end
  local modules: {string: boolean} = {}
  for _, row in ipairs(names) do modules[row[1]] = true end
  local out: {string} = {}
  local found: {string: boolean} = {}
  for _, row in ipairs(rows) do
    local text = " " .. link_text.unlinked(row[3]) .. " "
    local seen: {string: boolean} = {}
    for _, rule in ipairs(doc_rules) do
      local at = 1
      while true do
        local from, to = text:find(rule.pattern, at)
        if from == nil then break end
        at = to + 1
        local hit = text:sub(from, to)
        -- The whole word around the match, for the finding.
        local start, stop = from, to
        while start > 1 and not text:sub(start - 1, start - 1):match("%s") do start = start - 1 end
        while stop < #text and not text:sub(stop + 1, stop + 1):match("%s") do stop = stop + 1 end
        local word = text:sub(start, stop)
        local before, after = text:sub(from - 1, from - 1), text:sub(to + 1, to + 1)
        if rule.breaks(before, hit, after, modules) then
          local key = row[1] .. " " .. (row[2] ~= "" and row[2] or "(module)") .. " " .. rule.name
          found[key] = true
          if excused[key] == nil and not seen[word] then
            seen[word] = true
            out[#out + 1] = row[4] .. ":" .. row[5] .. ": " .. row[1] .. " " ..
              (row[2] ~= "" and row[2] or "(module)") .. ": its doc text has `" .. word ..
              "` (" .. rule.name .. " rule) -- " .. rule.fix
          end
        end
      end
    end
  end
  local stale: {string} = {}
  for key in pairs(excused) do
    if not found[key] then
      stale[#stale + 1] = key .. ": exempt, but its doc no longer breaks the rule -- " ..
        "remove the exemption"
    end
  end
  table.sort(stale)
  for _, line in ipairs(stale) do out[#out + 1] = line end
  return out
end

--- The literal plurals after a number that may stay, by
--- `<file>:<noun>`, and why each does. An entry masks every place in
--- that file that puts `<noun>` after a number, so the reason holds for
--- all of them.
local plural_exempt: {string: string} = {}

plural_exempt["build/vendor.tl:files"] = "runs on the bootstrap release " ..
  "(bin/vendor), which cannot require build.plural"
plural_exempt["build/confine.tl:paths"] = "a count above the unveil limit, so never 1; " ..
  "every worker loads build.confine, and none loads build.plural"
plural_exempt["build/fetch.tl:digests"] = "\"name different sha256 digests\": two differ, so never 1"
plural_exempt["build/test.tl:seconds"] = "the limit is math.maxinteger // 1000, never 1"
plural_exempt["build/test.tl:tables"] = "a label before its value (\"tables <digest>\"), not a count"
plural_exempt["cosmic/net.tl:bytes"] = "SOCKET_NAME_MAX is the platform's sun_path size, never 1"
plural_exempt["build/patch.tl:matches"] = "runs on the bootstrap release " ..
  "(bin/vendor applies patches), which cannot require build.plural"
plural_exempt["build/zig_fetch.tl:attempts"] = "runs on the bootstrap release " ..
  "(bin/zig), which cannot require build.plural"

--- Words after a number that are verbs or particles, not nouns:
--- `at byte %d needs`, `n .. " and files"`.
local NOT_NOUNS: {string: boolean} = {}
for word in ([[does needs names leaves takes lacks gives holds reads starts ends makes returns
  wants uses sets means comes always perhaps sometimes towards whereas afterwards
  is was are were has have had must cannot can not no will would and or but in on at of to for
  by from with the a an as if than that which when while so then after before until once now
  also only never still both either]]):gmatch("%S+") do
  NOT_NOUNS[word] = true
end

--- The words before a `%d` that make it a position or a name, not a
--- count: `at byte %d`, `line %d`.
local LABELS: {string: boolean} = {}
for word in ([[byte offset line column index position transition version entry step char
  character field row type code number errno signal exit status port pid]]):gmatch("%S+") do
  LABELS[word] = true
end

--- The nouns a count is taken of, which a plural after a bare name
--- (`n .. " files"`) must be one of: a name in front of any other plural
--- is as likely a subject in front of its verb (`name .. " lists"`).
local UNITS: {string: boolean} = {}
for word in ([[bytes files lines rows tests modules entries paths words comments sources targets
  builds attempts assets products releases digests digits seconds minutes hours milliseconds values
  fields stores compilers verbs components patches tables keys columns caches databases
  instructions inputs iters draws tries arguments errors failures directories members
  functions symbols steps bits chunks pieces sites hits results workers processes
  threads children hosts addresses tokens labels parts jobs items]]):gmatch("%S+") do
  UNITS[word] = true
end

--- Whether `word` reads as a plural noun: lowercase, an `s` at its end,
--- and none of the words that end so and are not.
local function is_plural_noun(word: string): boolean
  return #word >= 4 and word:match("^%l+$") ~= nil and word:sub(-1) == "s" and
    not word:match("ss$") and not word:match("[iu]s$") and not NOT_NOUNS[word]
end

--- The plural noun `text` leads with, after one space: its first word,
--- or its second when the first is not a particle or verb (` closure
--- stores`); nil when it leads with neither.
local function plural_after_space(text: string, counted: boolean): string | nil
  local first, rest = text:match("^ (%a+)(.*)$")
  if first == nil then return nil end
  if is_plural_noun(first) then
    if counted or UNITS[first] then return first end
    return nil
  end
  if not first:match("^%l+$") or NOT_NOUNS[first] then return nil end
  local second = rest:match("^ (%l+)%f[^%a]")
  if second ~= nil and is_plural_noun(second) and (counted or UNITS[second]) then return second end
  return nil
end

--- The plural noun the format `text` puts after a `%d` (`%d files`),
--- and where in `text` the number is, for each place it does. A `%d`
--- that follows a label (`at byte %d`) or a noun followed by `=` is a
--- name, not a count.
local function format_plurals(text: string): {string}
  local found: {string} = {}
  local at = 1
  while true do
    local first, last = string.find(text, "%d ", at, true)
    if first == nil then break end
    at = last
    local noun = plural_after_space(text:sub(last, last + 60), true)
    local label = text:sub(math.max(1, first - 12), first - 1):match("(%l+) $")
    if noun ~= nil and not LABELS[label or ""] then
      local after = text:sub(last + 1):match("^.-" .. noun .. "(.?)")
      if after ~= "=" then found[#found + 1] = noun end
    end
  end
  return found
end

--- Whether `node` is a number by its shape: a length, `tostring(...)`, a
--- literal, or arithmetic (parenthesized or not).
local function counted(node: Node): boolean
  local inner = node
  if node.kind == "paren" and node.e1 ~= nil then inner = node.e1 end
  local info = inner.op
  if inner.kind == "integer" or inner.kind == "number" then return true end
  if inner.kind ~= "op" or info == nil then return false end
  if info.op == "#" then return true end
  if info.op == "@funcall" then
    local callee = inner.e1
    return callee ~= nil and callee.tk == "tostring"
  end
  return info.op == "+" or info.op == "-" or info.op == "*" or info.op == "//" or
    info.op == "%" or info.op == "/"
end

--- Whether `node` is a `..`.
local function is_concat(node: Node): boolean
  local info = node.op
  return node.kind == "op" and info ~= nil and info.op == ".."
end

--- The literal string a concatenation starts with, whether its
--- operand is that string or a chain of `..` that begins with one.
local function leading_literal(node: Node): string | nil
  if node.kind == "string" then return node.conststr end
  if is_concat(node) and node.e1 ~= nil then return leading_literal(node.e1) end
  return nil
end

--- Every literal plural noun `source` puts after a number, as
--- `{line, noun, snippet, fix}`: after a value that is not provably a
--- string, by `..` (`#rows .. " tests"`, `tostring(n) .. " files"`,
--- `(a - b) .. " rows"`, any name, field or call), or after a `%d` in a
--- literal.
local function sites_in(parsed: ast.Parsed): {{string}}
  local sites: {{string}} = {}
  ast.walk(parsed.node, function(node: Node)
    local left, right = node.e1, node.e2
    if is_concat(node) and left ~= nil and right ~= nil and left.kind ~= "string" and
        not is_concat(left) then
      local literal = leading_literal(right)
      local noun = literal ~= nil and plural_after_space(literal, counted(left)) or nil
      if literal ~= nil and noun ~= nil then
        sites[#sites + 1] = { tostring(right.y), noun, "... .. \"" .. literal:sub(1, 24),
          "write `plural.count(n, singular)` (with the plural as a third argument when it is " ..
            "not the singular and an `s`)" }
      end
    elseif node.kind == "string" and node.conststr ~= nil and node.conststr:find("%%d ") then
      for _, noun in ipairs(format_plurals(node.conststr)) do
        sites[#sites + 1] = { tostring(node.y), noun, "%d " .. noun,
          "print `plural.noun(n, singular)` beside the number" }
      end
    end
  end)
  return sites
end

--- [`sites_in`] of `source`, parsed by `built`.
local function plural_sites(built: compiler, source: string, file: string):
    {{string}} | nil, string
  local parsed, trouble = ast.parse(built, source, file)
  if parsed == nil then return nil, trouble end
  return sites_in(parsed)
end

--- What [`plurals`] finds in `source`, the text of `file` (its path from
--- the tree's root), read off `parsed`, a parse of it already made, so
--- the checks need not parse it again; nil for a file they do not read.
function tree_checks.plurals_in(file: string, source: string, parsed: ast.Parsed):
    tree_checks.Plurals | nil
  if not file:match("%.tl$") or file:match("_test%.tl$") or file:match("%.d%.tl$") or
      not (file:match("^build/") or file:match("^cmd/") or file:match("^cosmic/") or
          file:match("^ci/cosmic_ci/")) then
    return nil
  end
  return { source = source, sites = sites_in(parsed) }
end

--- Every place in the Teal sources under `build/`, `cmd/` and
--- `cosmic/` of `db` (a test's excepted), and in `extra` (`{file,
--- source}` pairs, [`ci_sources`]'s), that puts a literal plural noun
--- after a number, as `<file>:<line>: ...` with the fix, and then each
--- name in `excused` (by default `plural_exempt`) that nothing answers
--- to any more. `built` parses the sources.
---
--- The two spellings refused are a value that is not provably a string
--- joined to a literal by `..` (`#rows .. " tests"`, `tostring(n) ..
--- " files"`, `(a - b) .. " rows"`, `count .. " closure stores"`), and a
--- `%d` in a literal followed by one (`"%d files"`). Either prints "1
--- tests"; `plural.count(n, "test")` is right for every count, and
--- [`plural.noun`] when the line prints the number itself. The noun is
--- the first word of the literal after its space, or the second when
--- the first is not a verb or particle; a value in front of a verb
--- (`name .. " needs"`) is passed over, and a count spelled by a name
--- in front of a plural that is right for it (a count that cannot be 1)
--- goes in `plural_exempt` with the reason.
--- @param read what [`plurals_in`] found before the checks, by file: a
---   file whose text is the one read there is not parsed again
function tree_checks.plurals(db: Sqlite.Handle, built: compiler, extra?: {{string}},
                             excused?: {string: string}, read?: {string: tree_checks.Plurals}):
    {string}
  excused = excused or plural_exempt
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT file, CAST(inflate(source) AS TEXT) FROM modules WHERE kind <> 'test' " ..
      "AND file GLOB '*.tl' AND file NOT GLOB '*.d.tl' AND (file GLOB 'build/*' " ..
      "OR file GLOB 'cmd/*' OR file GLOB 'cosmic/*') ORDER BY file")
  if rows == nil then
    return { "reading the sources: " .. trouble }
  end
  local sources: {{string}} = {}
  for _, row in ipairs(rows) do sources[#sources + 1] = row end
  for _, row in ipairs(extra or {}) do sources[#sources + 1] = row end
  local out: {string} = {}
  local found: {string: boolean} = {}
  for _, row in ipairs(sources) do
    local known = read ~= nil and read[row[1]] or nil
    local sites, parse_trouble: {{string}}, string
    if known ~= nil and known.source == row[2] then
      sites = known.sites
    else
      sites, parse_trouble = plural_sites(built, row[2], row[1])
    end
    if sites == nil then
      out[#out + 1] = row[1] .. ": cannot read it to check its plurals: " .. parse_trouble
    else
      for _, site in ipairs(sites) do
        local key = row[1] .. ":" .. site[2]
        found[key] = true
        if excused[key] == nil then
          out[#out + 1] = row[1] .. ":" .. site[1] .. ": `" .. site[3] ..
            "` puts the literal plural `" .. site[2] .. "` after a number, which reads \"1 " ..
            site[2] .. "\" -- " .. site[4]
        end
      end
    end
  end
  local stale: {string} = {}
  for key in pairs(excused) do
    if not found[key] then
      stale[#stale + 1] = key .. ": exempt, but nothing there writes a literal plural " ..
        "after a number any more -- remove the exemption"
    end
  end
  table.sort(stale)
  for _, tail in ipairs(stale) do out[#out + 1] = tail end
  return out
end

--- The Teal sources of `ci/` under `root`, out of the projection (ci is
--- a tree of its own), as `{file, source}` pairs: every module of
--- `ci/cosmic_ci` that is not a test.
function tree_checks.ci_sources(root: string): {{string}}
  local out: {{string}} = {}
  local listed, _ = Fs.walk(root .. "/ci/cosmic_ci")
  for _, name in ipairs(listed or {}) do
    if name:match("%.tl$") and not name:match("_test%.tl$") then
      local text, _ = Fs.read(root .. "/ci/cosmic_ci/" .. name)
      if text ~= nil then out[#out + 1] = { "ci/cosmic_ci/" .. name, text } end
    end
  end
  table.sort(out, function(a: {string}, b: {string}): boolean return a[1] < b[1] end)
  return out
end

--- Every check over the projection `db`, each line one failure,
--- prefixed with the check's name; none when the tree passes them all.
--- The plurals are checked when `built`, the compiler that parses the
--- sources, is given, with `extra` sources besides the projection's.
--- @param carried the database a release binary carries of `db`
---   ([`build.docs_checks`]' `carried`), which the checks of what `cosmic
---   docs` shows read; `db` itself when not given
--- @param help what `cosmic help` prints ([`build.help_source`]' `texts`),
---   whose references are checked with the docs'; none when not given
--- @param read the plurals already found in files' texts, as [`plurals`]
---   takes them
function tree_checks.run(db: Sqlite.Handle, quickstart: string | nil, built?: compiler,
                         extra?: {{string}}, carried?: Sqlite.Handle, help?: {string: string},
                         read?: {string: tree_checks.Plurals}): {string}
  local out: {string} = {}
  local plurals: {string} = {}
  if built ~= nil then plurals = tree_checks.plurals(db, built, extra, nil, read) end
  for _, check in ipairs({
      { name = "exports", lines = tree_checks.exports(db) },
      { name = "doc anchors", lines = tree_checks.anchors(db) },
      { name = "compiler readers", lines = tree_checks.compiler_readers(db) },
      { name = "stand-ins", lines = tree_checks.stand_ins(db) },
      { name = "docs queries", lines = tree_checks.queries(db) },
      { name = "quieted", lines = tree_checks.quieted(db) },
      { name = "declarations", lines = tree_checks.declarations(db) },
      { name = "verbs", lines = tree_checks.verbs(db, quickstart) },
      { name = "guides", lines = tree_checks.guides(db) },
      { name = "rendered docs", lines = docs_checks.rendered(carried or db) },
      { name = "doc references", lines = docs_checks.references(carried or db, help) },
      { name = "public docs", lines = tree_checks.public_docs(db) },
      { name = "plurals", lines = plurals },
  }) do
    for _, line in ipairs(check.lines) do
      out[#out + 1] = check.name .. ": " .. line
    end
  end
  return out
end

return tree_checks
