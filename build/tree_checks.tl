--- The checks over cosmic's whole tree, which no one module's test can
--- make: every export earned, no two doc anchors sharing a name, every
--- reader of the compiler's identity named, every familiar command
--- finding what stands in for it, every docs query a compile advertises
--- answered, and every quieted method one a module declares. Each asks
--- the tree's projection, `o/cosmic.db`, which holds every module's
--- docs, uses, imports, examples and source.
---
--- A test reads its own module's closure and no more (the rule the
--- suite's `store` declaration is kept to), so these are not tests:
--- `cosmic fix` runs them when it covers all of cosmic's own tree
--- (`cosmic fix --check .`, which CI runs), after building the
--- projection afresh (`projection`), and each line a check answers
--- fails the run. A `cosmic fix` of some paths does not run them, and a
--- tree that does not build fails them all.
---
--- Each check takes the projection and what it holds the tree to, by
--- default the tree's own (`allowed`, the anchors expected, ...), so its
--- test hands it a fixture database and a list of its own.

local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local contracts = require("build.contracts")
local declared_key = require("build.declared_key")
local docs = require("build.docs")
local importer = require("build.importer")
local shared_compiles = require("build.shared_compiles")
local symbols = require("build.symbols")
local work = require("build.work")
local writer = require("build.writer")
local type compiler = require("build.compiler")

local record tree_checks
end

--- The exports kept although nothing outside their module but a test
--- uses them, by `<module>.<member>`, and why each is kept.
local allowed: {string: string} = {}

allowed["build.c.layout.same"] = "tested directly: whether two layouts are one " ..
  "token stream is the rule `cosmic fix` holds a C rewrite to, and the test " ..
  "states it on sources too small to be a file"
allowed["build.flow.bare"] = "the subset build/workflows_test.tl holds " ..
  "workflows to takes a bare key by the same rule the layout writes one by"
allowed["build.flow.problems"] = "the subset build/workflows_test.tl holds " ..
  "the workflows to, which the layout is also held to"
allowed["build.flow.comments"] = "what the fuzz test holds a layout to keep"
for _, name in ipairs({ "parse", "render", "scalar", "from", "write", "value", "get", "set", "update" }) do
  allowed["build.flow." .. name] = "the API a program generates or edits a workflow " ..
    "through, which no program in the tree does yet; its test and the workflows' own do"
end
allowed["build.work.compiler_modules"] = "what build/importer_test.tl holds the tree to, " ..
  "walked over the running binary's modules: every module build.importer requires is " ..
  "in the compiler's identity or left out of it with a reason"
allowed["build.work.writer_modules"] = "what build/importer_test.tl holds the tree to, " ..
  "walked over the running binary's modules: what build.writer reaches is in the " ..
  "writer's identity, the compiler's, or neither with a reason"
allowed["build.work.writer_left_out"] = "what build/importer_test.tl holds to the " ..
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
allowed["build.this_program.program"] = "how a test starts this very program, " ..
  "which only a test does: build.test_inputs requires the module for the environment " ..
  "it pins, so it is no test support, and build.stand_in no longer starts it"
allowed["build.this_program.environment"] = "the environment a test starts this very " ..
  "program with (`program`), which only a test does"
allowed["build.confine.confine"] = "a test's own declaration: " ..
  "what the processes a test starts need, which only a test makes"
allowed["build.confine.must_confine"] = "a test's own declaration: " ..
  "what the processes a test starts need, with no fallback, which only a test makes"
allowed["build.confine.held_to_sandbox"] = "what a test whose " ..
  "assertion is about a nested run's sandbox asks, to fail where a run held to " ..
  "sandboxing gave that run none, rather than return unchecked"
allowed["build.filesystem_observations.reads_stat_times"] = "a test's own declaration: " ..
  "that its verdict turns on stat's times, which only a test makes"
allowed["build.test_sandbox.refusal"] = "tested directly: the test hands it each errno " ..
  "a host refusing user namespaces answers, which no host running the suite can be made to"
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
allowed["build.harness_epoch.acknowledged"] = "the digest of the harness a " ..
  "person last acknowledged, which only its test reads: a record of a choice, " ..
  "which the key leaves to `epoch`"
allowed["build.importer.prune_references"] = "tested directly: the test asks " ..
  "SQLite for the statement's plan, which must read `compiled` once rather " ..
  "than probe it per row, and no behaviour tells the two apart"
allowed["build.reboot.auto_boot"] = "tested directly: the test hands it an " ..
  "environment rather than setting COSMIC_AUTO_BOOT on the whole run"
allowed["build.reboot.boot_into"] = "tested directly: the test runs it on a tree " ..
  "whose bin/zig is a stand-in, which no stale tool can reach"
allowed["build.reboot.own_tool"] = "tested directly: the test hands it the path " ..
  "a tool was started as, which the running one cannot change"
allowed["build.writer.signature"] = "tested directly: the test signs a database " ..
  "as an older binary would"
allowed["cosmic.http.open"] = "the public way to read a response as it arrives: " ..
  "the tree's own callers read theirs whole, through Http.get and Http.download"

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
--- build found, through a `require` alias (`build.analyzer`) or a
--- value's checked type (`build.receivers`).
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
---   returns a function (`build/boot.tl`), which its loader calls;
--- - a declaration file (`*.d.tl`) and `cosmic.sys`, whose members are
---   declared in C (`core/syscalls.h`), not in Teal.
---
--- What earns one: a use from another module that is not a `*_test.tl`;
--- for a module only tests import (`build/docs_fixture.tl`, test
--- support), a use from a test other than the module's own; and for a
--- program in `build/`, `cmd/` or `eval/` -- a module whose record
--- exports `main` or `run`, which fetches, execs or reads the working
--- tree and prints -- a use from its own tests, which drive each step
--- directly on a fixture. A module's own tests are `<module>_test`,
--- `<module>_<topic>_test` and the tests in its directory when it is
--- one (`build/fix/`), except the test of another module: `<x>_test`
--- where `<x>` is itself a module (`build.test_worker_test` is not
--- `build.test`'s). A public `cosmic/` module is never a program here:
--- what its tests call still needs a caller or an example.
-- TODO: the check is not transitive: an export used only by another
-- export that is itself allowed, or itself unused, counts as earned.
-- Walk the uses from what is earned outright once a use records the
-- function it sits in, not only its module and line.
-- TODO: `cosmic.sys` is left out, so a constant or binding in
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
    "AND p.symbol IN ('main', 'run'))))) " ..
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
--- (`Proc.Relaunch.argv` beside `Entrypoint.argv`) is listed beside it
--- as any two members are. What is refused is two anchors sharing one:
--- a reader asking for the verb `test` was also shown the layout rule
--- for test files.
---
--- A doc anchor is a record of a public `cosmic/` module that exists to
--- be looked up, not passed around: every field of it is a documented
--- `string` (`test: string` in `cosmic.cli`'s `Cli`), and no function
--- or method in the public catalog takes or returns it. `cosmic.shape`'s
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
    if r.kind == "function" or r.kind == "method"
        or (r.kind == "field" and r.signature:find("function", 1, true) ~= nil) then
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
        if r.module == owner.module and r.symbol:sub(1, #prefix) == prefix
            and r.symbol:find(".", #prefix + 1, true) == nil then
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
--- name no reader can see: `Store.meta` called with anything but a
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
--- `Store.meta` and `named` (by default `build.declared_key`'s
--- `compiler_readers`) does not name, and then each it names that no
--- longer reads it.
---
--- A closure store carries no such row (`build.closure_store`), so a
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
    for line in (row[2] .. "\n"):gmatch("([^\n]*)\n") do
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
        "build/declared_key.tl's `compiler_readers` does not name it, so no key " ..
        "of a test that runs it holds it"
    end
  end
  for name in pairs(listed) do
    if not found[name] then
      stale[#stale + 1] = name .. " is named in build/declared_key.tl's " ..
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
  { "sleep", "Time.sleep_ns" },
  { "getentropy", "Rand.entropy" },
  { "getenv", "Env.get" },
  { "urandom", "Rand.entropy" },
}

--- Each of `cases` (by default the tree's own), a command or call and
--- the function that stands in for it, that `cosmic docs <command>`,
--- looked up the way a project sees the standard library in `db`, does
--- not answer with that function first, after any raw `cosmic.sys`
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
--- compile's failure: every one `build.importer` advertises, and the
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

--- Each of `names` (by default `build.contracts`' `quieted`), as
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

--- Whether `path`, relative to the tree's root, is a source of the
--- public standard library: `cosmic/` outside `cosmic/internal/`. A
--- note `build.fix.near` makes on one fails the whole tree's check: the
--- standard library as it stands earns no note against itself, so a
--- note on a file is about what that file adds.
function tree_checks.standard(path: string): boolean
  while path:sub(1, 2) == "./" do path = path:sub(3) end
  return path:sub(1, 7) == "cosmic/" and path:sub(1, 16) ~= "cosmic/internal/"
end

--- Builds the tree at `root`, cosmic's own, into its projection,
--- `o/cosmic.db`, as `cosmic test` does before any test reads it, and
--- opens it: `cosmic fix` rebuilds the tool it runs as when that is
--- stale, but not the projection of what the tool does not carry, its
--- tests and examples among it. A module the build refuses is a
--- failure: the checks would read a projection without it.
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
  return Sqlite.open(path, false)
end

--- Every check over the projection `db`, each line one failure,
--- prefixed with the check's name; none when the tree passes them all.
function tree_checks.run(db: Sqlite.Handle): {string}
  local out: {string} = {}
  for _, check in ipairs({
    { name = "exports", lines = tree_checks.exports(db) },
    { name = "doc anchors", lines = tree_checks.anchors(db) },
    { name = "compiler readers", lines = tree_checks.compiler_readers(db) },
    { name = "stand-ins", lines = tree_checks.stand_ins(db) },
    { name = "docs queries", lines = tree_checks.queries(db) },
    { name = "quieted", lines = tree_checks.quieted(db) },
  }) do
    for _, line in ipairs(check.lines) do
      out[#out + 1] = check.name .. ": " .. line
    end
  end
  return out
end

return tree_checks
