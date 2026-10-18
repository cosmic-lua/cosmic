--- The checks over cosmic's whole tree, which no one module's test can
--- make: every export earned, every type an API names a member of its
--- module, no two doc anchors sharing a name, every
--- reader of the compiler's identity named, every familiar command
--- finding what stands in for it, every docs query a compile advertises
--- answered, every quieted method one a module declares, every member
--- kept to a few files used by those alone, every
--- declaration's requires declared, every requirement a test module
--- declares promised by a CI leg, every verb's spec listed and
--- readable, no public doc citing the build or carrying a TODO, no
--- literal plural after a number, every file under ci/testdata
--- type-checking standalone, and every `.tl` file lexing, translating, scoping
--- and generating Lua in the new checker's grammar but for the forms pinned. Each asks the tree's projection,
--- `cosmic.db`, which holds every module's docs, uses, imports,
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

local build_paths = require("build.paths")
local Fs = require("cosmic.fs")
local Shape = require("cosmic.shape")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local check_memo = require("build.check_memo")
local closure_store = require("build.closure_store")
local compile = require("build.compile")
local Cover = require("lang.lexer_cover")
local contracts = require("build.contracts")
local declared_key = require("build.declared_key")
local ast = require("build.ast")
local docs = require("build.docs")
local docs_checks = require("build.docs_checks")
local link_text = require("build.link_text")
local host_names = require("build.host_names")
local importer = require("build.importer")
local Ast = require("lang.ast")
local Check = require("lang.check")
local Ceilings = require("build.ceilings")
local Compared = require("build.syntax_compared")
local Codegen = require("lang.codegen")
local Declarations = require("lang.declarations")
local Driver = require("build.driver")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Scopes = require("lang.scopes")
local ScopesCover = require("lang.scopes_cover")
local teal = require("build.teal")
local Translate = require("lang.translate")
local shared_compiles = require("build.shared_compiles")
local standalone = require("build.standalone")
local symbols = require("build.symbols")
local work = require("build.work")
local writer = require("build.writer")
local type compiler = require("build.compiler")
local String = require("cosmic.string")
local Hash = require("cosmic.hash")

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

allowed["build.dataset.read"] = "the reader load_text composes and falls back on, tested directly " ..
  "over each format's text, and with load the reference load_text's fuzz property is held to"

allowed["build.dataset.load"] = "the loader load_text composes and falls back on, tested directly " ..
  "over rows a test builds, whose keys no file need hold"

-- TODO: drop these allowances as build.analyzer, build.link_text, build.links, build.receivers, build.contracts,
-- build/fix and build/lsp are rewritten to the new syntax tree and call the readers that the tree's checks and tests
-- alone call now (doc/plans/strict-teal.md, "the switch").
local function allow(names: {string}, why: string)
  for _, name in ipairs(names) do
    allowed[name] = why
  end
end

allow({
  "build.coverage.syntax_lines.executable_cached", "build.syntax_derivation.rows_of", "build.syntax_derivation.insert",
  "build.syntax_match.matches", "build.syntax_match.text", "build.syntax_rewrite.rewrite", "build.syntax_scopes.position",
  "build.syntax_scopes.bindings_of", "build.syntax_shape_specs.resolve", "build.syntax_node.children",
  "build.syntax_node.require_sites", "build.syntax_shape_specs.splices", "build.syntax_shape_specs.spliced",
}, "a reader of the new syntax tree (build/syntax_*.tl) that the rewrites of the readers of the fork's tree call; " ..
    "tested directly until they do")

-- TODO: drop these allowances as the build prints its errors and writes the rule behind each code through them
-- (doc/plans/strict-teal.md, "the switch").
allow({
  "build.error_catalog.rows", "build.error_catalog.check", "build.error_catalog.problems",
  "build.error_catalog.text", "build.error_render.queries", "build.error_render.line", "build.error_render.lines",
  "build.error_render.complain",
}, "the new checker's error reporting (build/error_catalog.tl, build/error_render.tl), which the build's wiring calls in " ..
    "place of the fork's; tested directly until then")

allowed["build.ceilings.parse"] = "the text of a ceilings file, which `read` composes with the file it reads; a database filled " ..
  "from the file hands its text here, and the tests read fixtures"

allowed["build.driver.standard"] = "the provider of the `cosmic.*` modules, which the build's wiring gives the binary's own " ..
  "database to read; tested directly over fixture text"

allowed["build.driver.stubs"] = "the provider of modules whose stub text is given, which the build's wiring gives the stubs " ..
  "the projection carries; tested directly over fixture text"

allowed["cosmic.net.nameservers"] = "the public way to list the system's DNS servers for " ..
  "callers outside this tree; tested directly over a resolv.conf"

allowed["cosmic.internal.relay_config.parse_addresses"] = "tested directly: the reading of Linux's " ..
  "interface tables over fixture text, which host_addresses makes of the host's own"
-- TODO: drop these allowances and the next once build.analyzer and build.receivers attribute a
-- call made through a value taken from a module's field (cosmic.child's
-- `local Seatbelt = Rules.Seatbelt`, the relay's starter's [`Relay.Address`])
-- to the module it names: today neither this check nor `cosmic uses` follows
-- one, so `uses Seatbelt.compile` lists none of cosmic.child's calls.
for member, names in pairs({ address = { "deny_cidrs", "granted" }, grant = { "ipv6_text", "name", "port" } }) do
  for _, name in ipairs(names) do
    allowed["cosmic.relay." .. member .. "." .. name] = "called through cosmic.relay's `Address` and " ..
      "`Grant`, the package's one path to them from outside, which the relay's starter, wire and " ..
      "server take; the check reads a call by the module's own name alone"
  end
end
for _, name in ipairs({ "plan", "name_servers", "upstream_addresses", "resolved_upstream", "table", "public",
    "loopback_listeners" }) do
  allowed["cosmic.internal.relay_start." .. name] = "tested directly: a step of `handover` and " ..
    "`direct_handover`, which are composed from it, each tested over fixtures of its own"
end
allowed["cosmic.sandbox.seatbelt.grants"] = "called through cosmic.sandbox's `Seatbelt`, " ..
  "the package's one path to it from outside, which cosmic.child takes; the check reads a " ..
  "call by the module's own name alone"
allowed["cosmic.sandbox.seatbelt.credentials_unmet"] = "called through cosmic.sandbox's `Seatbelt`, " ..
  "as `grants` is"
for _, name in ipairs({ "install_checks", "dropped_violations", "most_kept" }) do
  allowed["build.test_worker." .. name] = "the seam that lets a test run the hook a checked run's Lua calls " ..
    "in its own process, over Lua it compiled with the checks, and read what the hook met; " ..
    "`run` calls them for a worker"
end
allowed["cosmic.sandbox.policy.system_profile"] = "the seam that lets a test draw the " ..
  "other host's \"system\" profile; rules.profile calls it with this host's"
allowed["build.teal.withheld_package"] = "the fields of `package` `strip` takes from the checker, " ..
  "spelled here as `withheld` is; build/teal_catalog_test.tl holds them to the catalog's"
allowed["build.c.variants"] = "the ways the C check dumps a file, written out as build.zig " ..
  "has no form to read them from; build/c/variants_test.tl holds them to it"
allowed["cosmic.net.connector"] = "tested directly: the library's face of the native connector, " ..
  "which ResolveOptions.connector takes; its callers in the tree start the process with " ..
  "cosmic.internal.connector and adopt it there instead"
allowed["cosmic.sandbox.restrict"] = "tested directly: it holds the process that calls it " ..
  "for good, so a worked example would hold the run that shows it; the test restricts " ..
  "a child of this program, and the harness holds its workers with it once the " ..
  "design's test phase lands (the TODO at build.confine's forbid_running)"
allowed["cosmic.test.needs_of"] = "tested directly: the worker's translation of a policy, " ..
  "which the build's own reading of one (build.analyzer, which cannot require this " ..
  "module) is held to by cosmic/test_policy_test.tl"
allowed["build.assertions.lua_assert"] = "tested directly: Lua's own `assert`, kept " ..
  "for build/assertions_test.tl to hold the counting one to, case by case, so a Lua " ..
  "upgrade that changes luaB_assert fails there rather than drifting"
allowed["build.c.layout.same"] = "tested directly: whether two layouts are one " ..
  "token stream is the rule `cosmic fix` holds a C rewrite to, and the test " ..
  "states it on sources too small to be a file"
for _, name in ipairs({ "sleep_ns", "ceil" }) do
  allowed["cosmic.time." .. name] = "the old name of cosmic.clock's " .. name .. ", kept " ..
    "for programs outside the tree that call it; in the tree only its own tests do"
end
for _, name in ipairs({ "names", "class" }) do
  allowed["build.host_names." .. name] = "tested directly: the table's own reading, which " ..
    "`parse` and `check`, the only calls outside the module, are made of"
end
allowed["build.flow.bare"] = "the subset build/workflows_test.tl holds " ..
  "workflows to takes a bare key by the same rule the layout writes one by"
allowed["build.flow.problems"] = "the subset build/workflows_test.tl holds " ..
  "the workflows to, which the layout is also held to"
allowed["build.flow.comments"] = "what the fuzz test holds a layout to keep"
allowed["build.shards.plan"] = "tested directly: the plan for exactly `count` shards, which " ..
  "`best`, the only call outside the module, takes the best of"
allowed["build.analyzer.analyze"] = "a convenience the tests call, a parse and " ..
  "analysis_of; every caller outside them calls analysis_of on a parse it has"
for _, name in ipairs({ "parse", "render", "scalar", "from", "write", "value", "get", "set", "update" }) do
  allowed["build.flow." .. name] = "the API a program generates or edits a workflow " ..
    "through, which no program in the tree does yet; its test and the workflows' own do"
end
for _, name in ipairs({ "well_formed", "any", "captures_mark", "bare_shapes" }) do
  allowed["build.checker_programs." .. name] = "the checker's fuzz generators and the line " ..
    "that marks a program the checker must refuse, and the bare prologue of the shapes, which " ..
    "build/checker_fuzz_test.tl draws " ..
    "its inputs from; the dump of the same programs to files (`drawn`) is the tool's"
end
for _, name in ipairs({ "pack", "unpack" }) do
  allowed["build.fuzz." .. name] = "the fuzz tests' inputs of several fields; only tests " ..
    "pack them, and build.checker_programs, which the verdict tool requires for the " ..
    "generators' draws, makes this module one a non-test module requires"
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
  "holds ci/testdata/host_features to: a key names each recorded host as ci/cosmic_ci/host_id.tl does"
allowed["build.confine.confine"] = "a test's own declaration: " ..
  "what the processes a test starts need, which only a test makes"
allowed["build.confine.must_confine"] = "a test's own declaration: " ..
  "what the processes a test starts need, with no fallback, which only a test makes"
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
allowed["build.lsp.protocol.frames_of"] = "tested directly: the test hands it a " ..
  "stream that answers a byte a read, so a message arrives split at every place it can be"
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
allowed["build.reboot.web_assets"] = "tested directly: the test hands it a database " ..
  "from before the table, which no running binary is"
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
--- `eval/`, or in `cosmic/`, a Teal module of `cosmic/internal/` among
--- them. Left out:
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
--- - a declaration file (`*.d.tl`, as every raw table of
---   `cosmic/internal/`) and [`cosmic.sys`], whose members are
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
      "OR d.file GLOB 'cosmic/*') " ..
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
    out[#out + 1] = row:text(1)
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

--- The name of the record `source` returns, or nil for none: the returned
--- name is the record itself (`return Child`), a record declared beside it
--- (`local module: Module`) or its capitalized form (`return module`).
local function returned_record(source: string): string | nil
  local returned = source:match("\nreturn ([%w_]+)%s*$")
  if returned == nil then return nil end
  local record = source:match("\nlocal " .. returned .. "%s*:%s*([%w_]+)")
  if record == nil then
    if source:find("\nlocal record " .. returned .. "%f[^%w_]") ~= nil then
      record = returned
    else
      record = returned:sub(1, 1):upper() .. returned:sub(2)
    end
  end
  return record
end

--- The text of the declaration of the record `record` in `source`, or nil
--- where it is not declared there.
local function record_body(source: string, record: string): string | nil
  local from = source:find("\nlocal record " .. record .. "%f[^%w_]")
  if from == nil then return nil end
  local to = source:find("\nend\n", from, true)
  return source:sub(from, to or #source)
end

--- Whether the returned record `record` (with `body`, its text) has the
--- type `name` as a member: `type Any = Name` or a nested declaration in
--- its body, or an assignment `record.Name = ...` beside it. Where the body
--- cannot be found the whole of `source` stands in for it.
local function member_type(source: string, record: string | nil, body: string | nil,
                           name: string): boolean
  for line in (body or source):gmatch("[^\n]+") do
    if line:find("^%s+type [%w_]+%s*=%s*" .. name .. "%f[^%w_]") ~= nil or
        line:find("^%s+record " .. name .. "%f[^%w_]") ~= nil or
        line:find("^%s+enum " .. name .. "%f[^%w_]") ~= nil or
        line:find("^%s+interface " .. name .. "%f[^%w_]") ~= nil then
      return true
    end
  end
  if record ~= nil then
    return source:find("\n" .. record .. "%." .. name .. "%s*=") ~= nil
  end
  return false
end

--- Every type a public `cosmic/` module's API names that the module does
--- not export as `Module.Name`, as `<file>:<line>: <module>: <Name> ...`.
---
--- A caller writes `local stream: integer | Child.Stdout`; a type that
--- the module declares `local` and its record does not re-export is
--- listed by `cosmic docs` and named in a type error, but [`Child.Stdout`]
--- is "unknown type". The types reached are those of the module's own
--- top level (a record, enum, interface or type) that a signature of an
--- exported member names, and then those that a member of such a type
--- names, a method declared outside its record included and a member
--- whose name starts with `_` (private by convention) left out. The returned
--- record itself is no member of itself, and `cosmic/internal/` is not
--- asked.
---
--- A member is found by text, not by resolving the name: `type Any = Name`
--- in the returned record's body, a nested declaration there, or
--- `Record.Name = ...`.
function tree_checks.unnamed_types(db: Sqlite.Handle): {string}
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT d.module, d.symbol, d.kind, d.signature, d.file, d.line, d.exported " ..
      "FROM docs d WHERE d.file GLOB 'cosmic/*.tl' " ..
      "AND d.file NOT GLOB 'cosmic/internal/*' AND d.file NOT GLOB '*_test.tl' " ..
      "AND d.file NOT GLOB '*.d.tl' ORDER BY d.module, d.line")
  if rows == nil then
    return { "reading the docs: " .. trouble }
  end
  local sources, why = Sqlite.text_rows(db,
    "SELECT path, CAST(inflate(source) AS TEXT) FROM modules")
  if sources == nil then
    return { "reading the modules: " .. why }
  end
  local text: {string:string} = {}
  for _, row in ipairs(sources) do text[row:text(1)] = row:text(2) end
  local by_module: {string:Sqlite.Rows} = {}
  local order: {string} = {}
  for _, row in ipairs(rows) do
    if by_module[row:text(1)] == nil then
      by_module[row:text(1)] = {}
      order[#order + 1] = row:text(1)
    end
    table.insert(by_module[row:text(1)], row)
  end
  local out: {string} = {}
  for _, module in ipairs(order) do
    local members = by_module[module]
    local source = text[module] or ""
    local record = returned_record(source)
    local body = record ~= nil and record_body(source, record) or nil
    local tops: {string:Sqlite.Row} = {}
    for _, row in ipairs(members) do
      if row:text(2) ~= "" and not row:text(2):find("[.:]") and row:text(2) ~= record and
          (row:text(3) == "record" or row:text(3) == "enum" or row:text(3) == "interface" or
              row:text(3) == "type") then
        tops[row:text(2)] = row
      end
    end
    local reached: {string:boolean} = {}
    local pending: {string} = {}
    local function names_in(signature: string)
      for name in pairs(tops) do
        if not reached[name] and signature:find("%f[%w_.]" .. name .. "%f[^%w_]") ~= nil then
          reached[name] = true
          pending[#pending + 1] = name
        end
      end
    end
    for _, row in ipairs(members) do
      if row:text(7) == "1" and row:text(2) ~= "" and not row:text(2):find("[.:]") and
          (row:text(3) == "function" or row:text(3) == "method" or row:text(3) == "field" or
              row:text(3) == "value") then
        names_in(row:text(4))
      end
    end
    while #pending > 0 do
      local name = pending[#pending]
      pending[#pending] = nil
      for _, row in ipairs(members) do
        local head = row:text(2):sub(1, #name + 1)
        if (head == name .. "." or head == name .. ":") and
            row:text(2):sub(#name + 2, #name + 2) ~= "_" and
            (row:text(3) == "function" or row:text(3) == "method" or row:text(3) == "field") then
          names_in(row:text(4))
        end
      end
    end
    local unnamed: {string} = {}
    for name in pairs(reached) do
      if not member_type(source, record, body, name) then unnamed[#unnamed + 1] = name end
    end
    table.sort(unnamed)
    for _, name in ipairs(unnamed) do
      local row = tops[name]
      local owner = record or module:match("[^.]+$")
      out[#out + 1] = row:text(5) .. ":" .. row:text(6) .. ": " .. module .. ": " .. name ..
        " is named by the API but is no member of the module: add `type " .. name .. " = " ..
        name .. "` to " .. owner .. ", so a caller can write " .. owner .. "." .. name
    end
  end
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
    all[#all + 1] = { module = r:text(1), symbol = r:text(2), kind = r:text(3), signature = r:text(4),
      text = r:text(5), file = r:text(6), line = r:text(7) }
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
    for line in String.lines(row:text(2)) do
      if reads(line) then
        found[row:text(1)] = true
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

--- The files of the tree that may spell a path under the build directory
--- themselves rather than ask [`build.paths`], each with why.
local spelled: {string: string} = {
  ["build/key_parts.tl"] = "names the build directory in a verdict key by the name a " ..
    "declaration gives it, `o` below the tree's marker, wherever the host keeps it",
  ["build/perf.tl"] = "asks a baseline artifact from before build.paths for its build " ..
    "directory, which that artifact can only name by the rule it was built with",
  ["build/identity.tl"] = "skips a checkout-local o/ of a tree of its own (ci/o) from the " ..
    "input walk, by its name in the tree, which a stale one keeps wherever the build " ..
    "directory goes",
  ["eval/check/grade.tl"] = "runs standalone on the cosmic.* modules alone, and grades a " ..
    "project the arena's own cosmic built",
}

--- Whether `line`, code rather than a comment, joins a path to `/o`: a
--- build directory spelled by hand.
local function spells_build_directory(line: string): boolean
  if line:find("^%s*%-%-") ~= nil then return false end
  return line:find("%.%.%s*([\"'])/o%1") ~= nil or line:find("%.%.%s*[\"']/o/") ~= nil
end

--- Each line of a module of `db` but a test that spells a path under the
--- build directory by hand -- `root .. "/o"` -- where `excused` (by
--- default [`spelled`]) does not name its file, as `<file>:<line>: ...`,
--- and then each file `excused` names that no longer does. Only
--- [`build.paths`] says where a build directory is, so boot, the verbs and
--- the rebuild lock cannot come to name different ones.
function tree_checks.build_directory(db: Sqlite.Handle, excused?: {string: string}): {string}
  excused = excused or spelled
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT file, CAST(inflate(source) AS TEXT) FROM modules " ..
      "WHERE file GLOB '*.tl' AND file NOT GLOB '*_test.tl' ORDER BY file")
  if rows == nil then
    return { "reading the modules' sources: " .. trouble }
  end
  local out: {string} = {}
  local found: {string: boolean} = {}
  for _, row in ipairs(rows) do
    local number = 0
    for line in String.lines(row:text(2)) do
      number = number + 1
      if spells_build_directory(line) then
        found[row:text(1)] = true
        if excused[row:text(1)] == nil then
          out[#out + 1] = row:text(1) .. ":" .. tostring(number) .. ": spells the build directory " ..
            "by hand; ask build.paths' `resolve` for it, or for the path under it"
        end
      end
    end
  end
  local stale: {string} = {}
  for file in pairs(excused) do
    if not found[file] then
      stale[#stale + 1] = file .. ": excused in build/tree_checks.tl's `spelled`, but no " ..
        "longer spells the build directory -- remove it"
    end
  end
  table.sort(stale)
  for _, line in ipairs(stale) do out[#out + 1] = line end
  return out
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

--- A member only some files may refer to.
local record Restriction
  --- The files, by path, that may use it.
  files: {string}
  --- What a file outside them does instead.
  why: string
end

--- The members the tree keeps to a few files, by `<module> <member>`: a
--- test that asks whether this platform has a sandbox, in place of
--- declaring `requires` or ending itself with [`Test.skip`], would branch
--- on what it was written to hold the platform to, and pass having checked
--- nothing where the branch goes the other way.
local restricted: {string: Restriction} = {
  ["cosmic.test passed_unchecked"] = {
    files = { "build/fuzz/init.tl" },
    why = "only the fuzz runner may say a pass did not check on purpose: a test that " ..
      "cannot check what it is about skips or declares `requires`, and one that checks " ..
      "asserts",
  },
  ["build.confine sandbox_platform"] = {
    files = { "build/confine.tl", "build/host_requires.tl",
      "build/test_sandbox_probe.tl" },
    why = "only the probe of what the host has asks it: a test declares `requires` " ..
      "(build/host_names.tl) or, where no name stands for what it needs, ends itself " ..
      "with `Test.skip(reason)`",
  },
}

--- Each use in `db` of a member of `rules` (by default [`restricted`])
--- from a file its rule does not name, as `<file>:<line>: <module> <member>
--- ...`.
function tree_checks.restricted(db: Sqlite.Handle, rules?: {string: Restriction}): {string}
  local out: {string} = {}
  local names: {string} = {}
  for name in pairs(rules or restricted) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local rule = (rules or restricted)[name]
    local module, symbol = name:match("^(%S+) (%S+)$")
    local rows, trouble = Sqlite.text_rows(db,
      "SELECT from_file, line FROM uses WHERE module = ?1 AND symbol = ?2 " ..
        "ORDER BY from_file, line",
      { { text = module or "" }, { text = symbol or "" } })
    if rows == nil then
      return { "reading the uses: " .. trouble }
    end
    local allowed_here: {string: boolean} = {}
    for _, file in ipairs(rule.files) do allowed_here[file] = true end
    for _, row in ipairs(rows) do
      if not allowed_here[row:text(1)] then
        out[#out + 1] = row:text(1) .. ":" .. row:text(2) .. ": " .. name .. " is used outside " ..
          table.concat(rule.files, ", ") .. ": " .. rule.why
      end
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
  for _, row in ipairs(rows) do declared[row:text(1)] = true end
  local out: {string} = {}
  for _, row in ipairs(rows) do
    for _, name in ipairs(closure_store.required_by(row:text(2))) do
      if not declared[name] then
        out[#out + 1] = row:text(1) .. " requires " .. name .. ", which is no declaration: " ..
          "a closure store follows a declaration's requires among declarations alone " ..
          "(build/closure_store.tl's `declared`), so declare what it needs of " .. name ..
          " in a declaration, or teach the store to follow a module"
      end
    end
  end
  return out
end

--- The requirements each test module of the tree declares
--- ([`Test.policy`]'s `requires`), by the module's path, as the working
--- database `build` (`build.db`) holds them: the projection has no
--- declarations.
--- @param build the working database
--- @return the names a module declares, for each that declares any
function tree_checks.requirements(build: Sqlite.Handle): {string:{string}} | nil, string
  local rows, trouble = Sqlite.text_rows(build,
    "SELECT i.path, t.value FROM test_inputs t JOIN inputs i ON i.source_hash = t.source_hash " ..
      "WHERE t.field = 'requires' ORDER BY i.path, t.ordinal")
  if rows == nil then return nil, "reading the declared requirements: " .. trouble end
  local out: {string:{string}} = {}
  for _, row in ipairs(rows) do
    local names = out[row:text(1)]
    if names == nil then
      names = {}
      out[row:text(1)] = names
    end
    names[#names + 1] = row:text(2)
  end
  return out
end

--- The test modules that run a program the portable launcher starts, or
--- open the store, or require a portable host, by the module's path:
--- the ones whose key holds the launcher, as the working database `build`
--- (`build.db`) holds their declarations. Every other worker runs
--- sealed ([`build.test`]'s `seals`).
--- @param build the working database
--- @return the module paths, as a set
function tree_checks.unsealed(build: Sqlite.Handle): {string:boolean} | nil, string
  local rows, trouble = Sqlite.text_rows(build,
    "SELECT DISTINCT i.path FROM test_inputs t JOIN inputs i ON i.source_hash = t.source_hash " ..
      "WHERE t.field IN ('tool', 'store') OR (t.field = 'requires' AND t.value = 'portable')")
  if rows == nil then return nil, "reading the unsealed modules: " .. trouble end
  local out: {string:boolean} = {}
  for _, row in ipairs(rows) do out[row:text(1)] = true end
  return out
end

--- The sealed test modules that name the portable launcher's contract
--- -- `COSMIC_PORTABLE_*` or the `--artifact` argument -- though their
--- worker never sees it, each with the reason it is no reader of it.
--- Every other one is a finding of [`sealed_launch`].
local launcher_allowed: {string: string} = {}
launcher_allowed["build.caches_test"] = "names COSMIC_PORTABLE_CACHE as a key of the " ..
  "environment it hands a pure function of the cache variables"
launcher_allowed["build.test_sandbox_test"] = "names COSMIC_PORTABLE_CACHE in the environments " ..
  "it hands the sandbox's pure functions, and reads none from its own process"
launcher_allowed["build.test_worker_test"] = "hands the worker's pure start function a made-up " ..
  "launcher start (\"--artifact\", COSMIC_PORTABLE_*_FD) and reads none from its own process"
launcher_allowed["build.this_program_test"] = "replaces Proc.relaunch with a made-up launcher " ..
  "start and holds this_program's reading of it, not this process's"
launcher_allowed["build.tree_checks_test"] = "plants the names in the fixture sources of the check's " ..
  "own test"
launcher_allowed["build.workflows_test"] = "reads COSMIC_PORTABLE_CACHE in the text of a workflow " ..
  "step, not from its own process"

--- Each module of `db` that is a test of the tree, runs sealed (`unsealed`
--- does not hold it) and names the portable launcher's contract in code
--- -- `COSMIC_PORTABLE_*`, or the `"--artifact"` argument -- and no
--- reason in `excused` (by default the tree's own), then each module
--- `excused` names that does not.
---
--- ci/cosmic_ci/orchestration.tl's `suite_verdicts` lets the portable
--- suite stand on the native suite's verdicts, which is sound while the
--- key of a worker that can see the artifact holds the launcher
--- ([`build.declared_key`]'s `launcher_identity`) and one that cannot
--- (a sealed worker) holds the core in its place. A test that reads
--- the launcher's contract must therefore be keyed by the launcher: it
--- declares `tool` or `store`, or `requires = { "portable" }`, else it
--- would pass under the native build and stand in the portable suite
--- without the artifact it is about (or, run only on the portable
--- build, skip in both). A call to Proc.relaunch is no finding: a
--- sealed worker's description is the sealed start's, the same
--- under either artifact.
--- @param db the tree's projection
--- @param unsealed the modules whose workers run unsealed ([`unsealed`])
--- @param excused the modules that may, with the reason of each
function tree_checks.sealed_launch(db: Sqlite.Handle, unsealed: {string:boolean},
                                   excused?: {string: string}): {string}
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT path, CAST(inflate(source) AS TEXT) FROM modules WHERE path GLOB '*_test' ORDER BY path")
  if rows == nil then return { "reading the modules' sources: " .. trouble } end
  local allowed_here = excused or launcher_allowed
  local out: {string} = {}
  local seen: {string: boolean} = {}
  for _, row in ipairs(rows) do
    local named = false
    for line in String.lines(row:text(2)) do
      if line:find("^%s*%-%-") == nil and
          (line:find("COSMIC_PORTABLE_", 1, true) ~= nil or line:find('"--artifact', 1, true) ~= nil) then
        named = true
        break
      end
    end
    if named and not unsealed[row:text(1)] then
      seen[row:text(1)] = true
      if allowed_here[row:text(1)] == nil then
        out[#out + 1] = row:text(1) .. " names the portable launcher's contract, but its worker runs " ..
          "sealed and never sees the launcher: declare `tool` or `store`, or " ..
          "`requires = { \"portable\" }`, or excuse it in build/tree_checks.tl's `launcher_allowed`"
      end
    end
  end
  local stale: {string} = {}
  for name in pairs(allowed_here) do
    if not seen[name] then
      stale[#stale + 1] = name .. " is excused in build/tree_checks.tl's `launcher_allowed`, but " ..
        "no longer names the portable launcher's contract in a sealed test -- remove it"
    end
  end
  table.sort(stale)
  for _, line in ipairs(stale) do out[#out + 1] = line end
  return out
end

--- What ci/cosmic_ci/capabilities.tl returns.
local record Capabilities
  legs: {string:{string}}
end

local CAPABILITIES_SPEC <const> = Shape.record({ legs = Shape.map(Shape.list(Shape.string)) })

--- The requirements each CI leg promises, as ci/cosmic_ci/capabilities.tl
--- under `root` lists them. ci is a tree of its own, whose modules the
--- tree cannot require: the file is data in text Lua reads, loaded alone.
--- @param root the tree's root
--- @return the names a leg promises, by the leg's name
function tree_checks.legs(root: string): {string:{string}} | nil, string
  local path = root .. "/ci/cosmic_ci/capabilities.tl"
  local text, read_trouble = Fs.read(path)
  if text == nil then return nil, read_trouble end
  local chunk, load_trouble = load(text, "=capabilities.tl", "t", {})
  if chunk == nil then return nil, path .. ": " .. tostring(load_trouble) end
  local ok, loaded = pcall(chunk)
  if not ok then return nil, path .. ": " .. tostring(loaded) end
  local capabilities, shape_trouble: Capabilities | nil, string = Shape.into(loaded, CAPABILITIES_SPEC)
  if capabilities == nil then return nil, path .. ": " .. shape_trouble end
  return capabilities.legs
end

-- TODO: hold the requirements ci/'s own tests and fixtures declare to the
-- same check: it reads the root tree's declarations alone, and ci/ is a
-- tree of its own whose `fix --check` cannot read the leg list's tree.
--- What the CI legs' promises ([`legs`]) and the tree's declared
--- requirements ([`requirements`]) say against each other, one line a
--- finding: a name a leg promises that the table of
--- [`build.host_names`] refuses, and a module requiring a name no leg
--- promises, which would be n/a or skipped on every leg and run nowhere
--- in CI, with no held run to fail for it.
--- @param declared the requirements each test module declares
--- @param legs the names each CI leg promises
--- @return the findings, none when every declared name is promised
function tree_checks.promises(declared: {string:{string}}, legs: {string:{string}}): {string}
  local out: {string} = {}
  local leg_names: {string} = {}
  for leg in pairs(legs) do leg_names[#leg_names + 1] = leg end
  table.sort(leg_names)
  local all: {string} = {}
  for _, leg in ipairs(leg_names) do
    for _, name in ipairs(legs[leg]) do
      local _, why = host_names.parse(name)
      if why ~= nil then
        out[#out + 1] = string.format("leg %s promises %q, which is refused: %s", leg, name, why)
      else
        all[#all + 1] = name
      end
    end
  end
  local modules: {string} = {}
  for module in pairs(declared) do modules[#modules + 1] = module end
  table.sort(modules)
  for _, module in ipairs(modules) do
    for _, name in ipairs(declared[module]) do
      if not host_names.promised(all, name) then
        out[#out + 1] = string.format("%s requires %s, which no CI leg promises " ..
            "(ci/cosmic_ci/capabilities.tl): it would be n/a or skipped on every leg and run " ..
            "nowhere, with no held run to fail for it", module, name)
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
--- `cosmic.db`, as `cosmic test` does before any test reads it, and
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
  local path = build_paths.resolve(root).projection
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
  for _, row in ipairs(required) do listed[row:text(1)] = true end
  local modules, module_trouble = Sqlite.text_rows(db,
    "SELECT path, kind, CAST(inflate(source) AS TEXT) FROM modules ORDER BY path")
  if modules == nil then
    return { "reading the modules: " .. module_trouble }
  end
  local kinds: {string:string} = {}
  local texts: {string:string} = {}
  for _, row in ipairs(modules) do
    kinds[row:text(1)] = row:text(2)
    texts[row:text(1)] = row:text(3)
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
    if row:text(2) ~= "test" then
      local assigned = 0
      local at = 1
      while true do
        local first, last, field = row:text(3):find("\n[%w_]+%.([%w_]*spec) = {", at)
        if first == nil then break end
        at = last + 1
        if field == "spec" or field:match("^[%w_]*_spec$") ~= nil then
          assigned = assigned + 1
          found_fields[row:text(1)] = found_fields[row:text(1)] or {}
          found_fields[row:text(1)][field] = true
          local spec = spec_fields(row:text(3), last)
          local name = spec.strings.name or "?"
          if not listed[row:text(1)] then
            out[#out + 1] = "`" .. name .. "` (" .. row:text(1) .. ") assigns a `spec` but " ..
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
    local name = row:text(1):sub(#"doc.guides." + 1)
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
--- off from the doc by a blank line (doc/writing.md); a path or a `build.`
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
  for _, row in ipairs(names) do modules[row:text(1)] = true end
  local out: {string} = {}
  local found: {string: boolean} = {}
  for _, row in ipairs(rows) do
    local text = " " .. link_text.unlinked(row:text(3)) .. " "
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
          local key = row:text(1) .. " " .. (row:text(2) ~= "" and row:text(2) or "(module)") .. " " .. rule.name
          found[key] = true
          if excused[key] == nil and not seen[word] then
            seen[word] = true
            out[#out + 1] = row:text(4) .. ":" .. row:text(5) .. ": " .. row:text(1) .. " " ..
              (row:text(2) ~= "" and row:text(2) or "(module)") .. ": its doc text has `" .. word ..
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
  local e1 = node.e1
  if node.kind == "paren" and e1 ~= nil then inner = e1 end
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
  local e1 = node.e1
  if is_concat(node) and e1 ~= nil then return leading_literal(e1) end
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
    local conststr = node.conststr
    if is_concat(node) and left ~= nil and right ~= nil and left.kind ~= "string" and
        not is_concat(left) then
      local literal = leading_literal(right)
      local noun = literal ~= nil and plural_after_space(literal, counted(left)) or nil
      if literal ~= nil and noun ~= nil then
        sites[#sites + 1] = { tostring(right.y), noun, "... .. \"" .. literal:sub(1, 24),
          "write `plural.count(n, singular)` (with the plural as a third argument when it is " ..
            "not the singular and an `s`)" }
      end
    elseif node.kind == "string" and conststr ~= nil and conststr:find("%%d ") then
      for _, noun in ipairs(format_plurals(conststr)) do
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
  for _, row in ipairs(rows) do sources[#sources + 1] = { row:text(1), row:text(2) } end
  for _, row in ipairs(extra or {}) do sources[#sources + 1] = row end
  local out: {string} = {}
  local found: {string: boolean} = {}
  for _, row in ipairs(sources) do
    local known = read ~= nil and read[row[1]] or nil
    local sites, parse_trouble: {{string}}, string | nil
    if known ~= nil and known.source == row[2] then
      sites = known.sites
    else
      sites, parse_trouble = plural_sites(built, row[2], row[1])
    end
    if sites == nil then
      out[#out + 1] = row[1] .. ": cannot read it to check its plurals: " .. (parse_trouble or "")
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

--- The Teal under `ci/testdata` that fails to type-check in
--- [`build.standalone`]'s environment, one line per complaint. No leg runs
--- these with `--standalone`: they are copied into fixture directories and
--- run there, `cmd/*/main.tl` as modules of a project the candidate builds,
--- `retained_probe.tl` and `work_db_integrity.tl` as files, and
--- `runtime_test.tl` by `cosmic test`. Each requires `cosmic.*` modules
--- alone and is held to a build's own strictness, which standalone's
--- environment models, so a refusal that would otherwise be met only when
--- a leg runs it is met here; `cosmic fix --check` in `ci/` only parses
--- them. `built` must be a compiler of its own ([`teal.load`]), as
--- [`standalone.environment`] points its search at this binary's sources.
--- A test module's unused functions are no complaint (a test runner
--- calls them); any other file's unused locals are.
function tree_checks.ci_testdata(root: string, built: compiler): {string}
  local out: {string} = {}
  local listed, _ = Fs.walk(root .. "/ci/testdata")
  local names: {string} = {}
  for _, name in ipairs(listed or {}) do
    if name:match("%.tl$") then names[#names + 1] = name end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local file = "ci/testdata/" .. name
    local source, read_trouble = Fs.read(root .. "/" .. file)
    if source == nil then
      out[#out + 1] = read_trouble
    else
      local env, env_trouble = standalone.environment(built)
      if env == nil then
        out[#out + 1] = file .. ": " .. env_trouble
      else
        local code, result = built.gen(source, env, nil, "tl")
        local testy = name:match("_test%.tl$") ~= nil
        local found = 0
        local errors = result and result.syntax_errors or {}
        local typed = result and result.type_errors or {}
        local warned = result and result.warnings or {}
        for _, group in ipairs({ errors, typed, warned }) do
          for _, e in ipairs(group) do
            if group ~= warned or not testy or e.code ~= "unused" then
              found = found + 1
              out[#out + 1] = file .. ":" .. e.y .. ":" .. e.x .. ": " .. e.msg
            end
          end
        end
        if code == nil and found == 0 then
          out[#out + 1] = file .. ": the compiler refused it"
        end
      end
    end
  end
  return out
end

--- The ceilings of `stage` for the tree at `root`: `given` where a caller passes its own, else [`Ceilings.path`]'s.
local function ceilings_for(root: string, stage: Ceilings.Stage, given: {string: integer} | nil): {string: integer} | nil, string
  if given ~= nil then
    return given, ""
  end
  local read, why = Ceilings.read(root)
  if read == nil then
    return nil, why
  end
  local dead = Ceilings.dead(root, read)
  if #dead > 0 then
    return nil, Ceilings.path .. " holds ceilings for files that are gone, which no check would ever lower: " ..
      table.concat(dead, "; ")
  end
  return Ceilings.of(read, stage), ""
end

--- Every `.tl` file under `root` as `{file, source}` pairs, read from disk:
--- the modules and tests, the checker's files, the declaration files and
--- `ci/`'s. The projection is not read, as it holds no declaration file and
--- its [`checker/tl.tl`] is the compiled bridge chunk, not the file. `vendor/`,
--- the hidden directories, `o/` (never read) and `ci/o` hold none the tree
--- owns.
local function lexable(root: string): {{string}} | nil, string
  local listed, trouble = Fs.walk(root, function(relative: string, name: string, kind: Fs.Kind): boolean
    return kind == "dir" and (name:sub(1, 1) == "." or relative == "vendor" or relative == "o" or
      relative == "ci/o")
  end)
  if listed == nil then
    return nil, trouble
  end
  local out: {{string}} = {}
  for _, file in ipairs(listed) do
    if file:match("%.tl$") then
      local text, read_trouble = Fs.read(root .. "/" .. file)
      if text == nil then
        return nil, read_trouble
      end
      out[#out + 1] = { file, text }
    end
  end
  return out
end

--- The `goto` statements among `tokens`, as the errors the grammar gives them.
--- A `goto` is a keyword to the lexer; one that follows `.` or `:`, or is a
--- table key or a member name, is a field name. [`lang.parser`] refuses the
--- statement itself.
local function gotos(tokens: {Lexer.Token}, file: string): {Lexer.Error}
  local out: {Lexer.Error} = {}
  for i, t in ipairs(tokens) do
    if t.kind == "keyword" and t.text == "goto" then
      local before, after, then_ = tokens[i - 1], tokens[i + 1], tokens[i + 2]
      local field = (before ~= nil and (before.kind == "." or before.kind == ":")) or
        (after ~= nil and (after.text == "=" or after.text == ":" or (after.text == "?" and then_ ~= nil and then_.text == ":")))
      if not field then
        local label = after ~= nil and after.y == t.y and (after.kind == "identifier" or after.kind == "keyword") and after.text or nil
        out[#out + 1] = {
          filename = file, code = "label_or_goto", y = t.y, x = t.x, offset = t.offset,
          length = label and after.offset + after.length - t.offset or t.length,
          msg = "`goto" .. (label and " " .. label or "") .. "` is not in the grammar",
          fix = label == "continue" and "write `continue`" or
            "write `continue` to skip the rest of a pass of the loop around it; restructure any other jump with an" ..
            " `if` around the code to skip, or move the code into a function and `return` from it",
        }
      end
    end
  end
  return out
end

--- What lexing one file found: why its tokens do not tile it (empty where they
--- do) and its errors, with the `goto` statements the parser refuses among
--- them, in source order.
local record LexOutcome
  tile: string
  errors: {Lexer.Error}
end

--- The lexer's codes by name.
local lexer_codes: {string: Lexer.Code} = {}
for _, code in ipairs(Lexer.codes) do
  lexer_codes[code] = code
end

--- The outcome a memo kept, or nil where it kept none or it does not read.
local function kept_lex(text: string, file: string): LexOutcome | nil
  local outcome: LexOutcome = { tile = "", errors = {} }
  for _, fields in ipairs(check_memo.decode(text)) do
    if fields[1] == "C" and #fields == 2 then
      outcome.tile = fields[2]
    elseif fields[1] == "E" and #fields == 8 then
      local code = lexer_codes[fields[2]]
      local y, x = math.tointeger(tonumber(fields[3])), math.tointeger(tonumber(fields[4]))
      local offset, length = math.tointeger(tonumber(fields[5])), math.tointeger(tonumber(fields[6]))
      if code == nil or y == nil or x == nil or offset == nil or length == nil then
        return nil
      end
      outcome.errors[#outcome.errors + 1] = {
        filename = file, code = code, y = y, x = x, offset = offset, length = length, msg = fields[7], fix = fields[8],
      }
    else
      return nil
    end
  end
  return outcome
end

--- The outcome of lexing `source`, from `memo` where it holds it under `salt`.
local function lex_outcome(file: string, source: string, memo: Sqlite.Handle | nil, salt: string): LexOutcome
  local key = ""
  if memo ~= nil then
    key = check_memo.key(salt, "tl", source)
    local text = check_memo.get(memo, "lexed", key)
    local kept = text ~= nil and kept_lex(text, file) or nil
    if kept ~= nil then
      return kept
    end
  end
  local lexed = Lexer.lex(source, file)
  local ok, reason = Cover.check(source, lexed)
  local errors: {Lexer.Error} = {}
  for _, e in ipairs(lexed.errors) do
    errors[#errors + 1] = e
  end
  for _, e in ipairs(gotos(lexed.tokens, file)) do
    errors[#errors + 1] = e
  end
  table.sort(errors, function(a: Lexer.Error, b: Lexer.Error): boolean
    return a.offset < b.offset
  end)
  local outcome: LexOutcome = { tile = ok and "" or reason, errors = errors }
  if memo ~= nil then
    local rows: {{string}} = { { "C", outcome.tile } }
    for _, e in ipairs(errors) do
      rows[#rows + 1] = { "E", e.code, tostring(e.y), tostring(e.x), tostring(e.offset), tostring(e.length), e.msg, e.fix }
    end
    check_memo.put(memo, "lexed", key, check_memo.encode(rows))
  end
  return outcome
end

--- Every `.tl` file of the tree, lexed in the new checker's grammar
--- ([`lang.lexer`]): the file's tokens and comments must tile its bytes, and
--- its errors are the cut forms `pinned` (by default the `[lexed]` ceilings of [`build.ceilings`]) counts,
--- no more. A file with more errors of a code than pinned is listed with
--- each, their places and the fix the lexer gives; one with fewer, and a pin
--- for a file with none, is told to lower the pin. The sources are the
--- `.tl` files under `root` ([`lexable`]).
function tree_checks.lexed(root: string, pinned?: {string: integer}, memo?: Sqlite.Handle): {string}
  local ceilings, why = ceilings_for(root, "lexed", pinned)
  if ceilings == nil then
    return { "reading the ceilings: " .. why }
  end
  pinned = ceilings
  local files, trouble = lexable(root)
  if files == nil then
    return { "reading the sources: " .. trouble }
  end
  local out: {string} = {}
  local found: {string: integer} = {}
  local salt = check_memo.salt(root, { "lang/lexer.tl", "lang/lexer_cover.tl", "build/check_memo.tl", "build/tree_checks.tl" },
    "lexed 1")
  if memo ~= nil then
    local _, _ = check_memo.prepare(memo, "lexed")
  end
  for _, row in ipairs(files) do
    local file, source = row[1], row[2]
    local outcome = lex_outcome(file, source, memo, salt)
    if outcome.tile ~= "" then
      out[#out + 1] = file .. ": its tokens do not tile it: " .. outcome.tile
    end
    local by_code: {string: {Lexer.Error}} = {}
    for _, e in ipairs(outcome.errors) do
      local held = by_code[e.code] or {}
      held[#held + 1] = e
      by_code[e.code] = held
    end
    for _, code in ipairs(Lexer.codes) do
      local errors = by_code[code]
      if errors ~= nil then
        local key = file .. " " .. code
        found[key] = #errors
        local limit = pinned[key] or 0
        if #errors > limit then
          for _, e in ipairs(errors) do
            out[#out + 1] = file .. ":" .. e.y .. ":" .. e.x .. ": " .. e.msg .. " (" .. code .. "): " .. e.fix
          end
          out[#out + 1] = file .. ": " .. String.counted(#errors, "error") .. " of " .. code .. ", pinned " .. limit ..
            "; remove the form (the fix above) rather than raise the pin"
        end
      end
    end
  end
  if memo ~= nil then
    check_memo.finish(memo, "lexed")
  end
  local keys: {string} = {}
  for key in pairs(pinned) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local count = found[key] or 0
    if count < pinned[key] then
      out[#out + 1] = key .. ": pinned " .. pinned[key] .. " but " .. count ..
        " found; lower the pin in " .. Ceilings.path .. "'s [lexed]"
    end
  end
  return out
end

--- What translating one file found: the errors its translation still has, the
--- places a rewrite may change meaning, and what the line check needs.
local record TranslateOutcome
  errors: {Parser.Error}
  hazards: {Translate.Hazard}
  --- The interfaces the file declares.
  interfaces: {Translate.Interface}
  --- How many records became classes.
  classes: integer
  --- The line breaks of the file and of its translation.
  lines_before: integer
  lines_after: integer
end

--- A file and what translating it found.
local record Translated
  file: string
  made: TranslateOutcome
end

--- The last component of a dotted name.
local function last_component(dotted: string): string
  return dotted:match("([^%.]+)$") or dotted
end

--- The parser's codes by name.
local parser_codes: {string: Parser.Code} = {}
for _, code in ipairs(Parser.codes) do
  parser_codes[code] = code
end

--- The outcome a memo kept, or nil where it kept none or it does not read.
local function kept_translation(text: string, file: string): TranslateOutcome | nil
  local outcome: TranslateOutcome = {
    errors = {}, hazards = {}, interfaces = {}, classes = 0, lines_before = 0, lines_after = 0,
  }
  local seen_summary = false
  for _, fields in ipairs(check_memo.decode(text)) do
    if fields[1] == "M" and #fields == 4 then
      local classes = math.tointeger(tonumber(fields[2]))
      local before, after = math.tointeger(tonumber(fields[3])), math.tointeger(tonumber(fields[4]))
      if classes == nil or before == nil or after == nil then
        return nil
      end
      outcome.classes, outcome.lines_before, outcome.lines_after = classes, before, after
      seen_summary = true
    elseif fields[1] == "E" and #fields == 6 then
      local code = parser_codes[fields[2]]
      local y, x = math.tointeger(tonumber(fields[3])), math.tointeger(tonumber(fields[4]))
      if code == nil or y == nil or x == nil then
        return nil
      end
      outcome.errors[#outcome.errors + 1] = {
        filename = file, code = code, y = y, x = x, offset = 0, length = 0, msg = fields[5], fix = fields[6],
      }
    elseif fields[1] == "H" and #fields == 6 then
      local y = math.tointeger(tonumber(fields[5]))
      if y == nil then
        return nil
      end
      outcome.hazards[#outcome.hazards + 1] = {
        kind = fields[2], class = fields[3], method = fields[4], y = y, name = fields[6],
      }
    elseif fields[1] == "I" and #fields == 4 then
      local function names(joined: string): {string}
        local list: {string} = {}
        for name in joined:gmatch("[^,]+") do
          list[#list + 1] = name
        end
        return list
      end
      outcome.interfaces[#outcome.interfaces + 1] = { name = fields[2], fields = names(fields[3]), supers = names(fields[4]) }
    else
      return nil
    end
  end
  return seen_summary and outcome or nil
end

--- The outcome of translating `source`, from `memo` where it holds it under `salt`.
local function translate_outcome(file: string, source: string, memo: Sqlite.Handle | nil, salt: string): TranslateOutcome
  local dialect = file:match("%.d%.tl$") and "decl" or "tl"
  local key = ""
  if memo ~= nil then
    key = check_memo.key(salt, dialect, source)
    local text = check_memo.get(memo, "translated", key)
    local kept = text ~= nil and kept_translation(text, file) or nil
    if kept ~= nil then
      return kept
    end
  end
  local made = Translate.translate(source, file)
  local _, before = source:gsub("\n", "")
  local _, after = made.text:gsub("\n", "")
  local outcome: TranslateOutcome = {
    errors = made.errors, hazards = made.hazards, interfaces = made.interfaces, classes = made.counts["class"] or 0,
    lines_before = before, lines_after = after,
  }
  if memo ~= nil then
    local rows: {{string}} = { { "M", tostring(outcome.classes), tostring(before), tostring(after) } }
    for _, e in ipairs(made.errors) do
      rows[#rows + 1] = { "E", e.code, tostring(e.y), tostring(e.x), e.msg, e.fix }
    end
    for _, h in ipairs(made.hazards) do
      rows[#rows + 1] = { "H", h.kind, h.class, h.method, tostring(h.y), h.name }
    end
    for _, i in ipairs(made.interfaces) do
      rows[#rows + 1] = { "I", i.name, table.concat(i.fields, ","), table.concat(i.supers, ",") }
    end
    check_memo.put(memo, "translated", key, check_memo.encode(rows))
  end
  return outcome
end

--- Every `.tl` file of the tree translated to the new checker's grammar
--- ([`lang.translate`]), apart from [`checker/tl.tl`], which the new checker
--- replaces. The translation must parse with the errors `pinned` (by
--- default the `[translated]` ceilings of [`build.ceilings`]) counts and no more; a file with more errors of a
--- code is listed with each, their places and the parser's fix, and a pin the
--- tree no longer meets is told to fall. A translation that is not a
--- respelling keeps the lines of the file where they were unless a method
--- moved into a class, and a respelling that moved one is listed. The
--- methods that moved above a name they read must not exceed `ceiling`
--- (by default the `[hazards]` ceiling of [`build.ceilings`]). The sources are the `.tl` files under
--- `root` ([`lexable`]).
function tree_checks.translated(root: string, pinned?: {string: integer}, ceiling?: integer,
                                memo?: Sqlite.Handle): {string}
  local ceilings, why = ceilings_for(root, "translated", pinned)
  if ceilings == nil then
    return { "reading the ceilings: " .. why }
  end
  pinned = ceilings
  if ceiling == nil then
    local hazards, hazards_why = ceilings_for(root, "hazards", nil)
    if hazards == nil then
      return { "reading the ceilings: " .. hazards_why }
    end
    ceiling = hazards["methods"] or 0
  end
  local files, trouble = lexable(root)
  if files == nil then
    return { "reading the sources: " .. trouble }
  end
  local out: {string} = {}
  local found: {string: integer} = {}
  local hazardous: {string} = {}
  local seen: {string: boolean} = {}
  local salt = check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/translate.tl",
    "build/check_memo.tl", "build/tree_checks.tl" }, "translated 1")
  if memo ~= nil then
    local _, _ = check_memo.prepare(memo, "translated")
  end
  local outcomes: {Translated} = {}
  local declaring: {string: {Translate.Interface}} = {}
  for _, row in ipairs(files) do
    local file, source = row[1], row[2]
    if file ~= "checker/tl.tl" then
      local made = translate_outcome(file, source, memo, salt)
      outcomes[#outcomes + 1] = { file = file, made = made }
      for _, i in ipairs(made.interfaces) do
        local held = declaring[i.name] or {}
        held[#held + 1] = i
        declaring[i.name] = held
      end
    end
  end
  --- Whether an interface of the tree called `name` declares `field`, itself or
  --- through the interfaces it extends.
  local function declares(name: string, field: string, visited: {string: boolean}): boolean
    if visited[name] then
      return false
    end
    visited[name] = true
    for _, i in ipairs(declaring[name] or {}) do
      for _, declared in ipairs(i.fields) do
        if declared == field then
          return true
        end
      end
      for _, super in ipairs(i.supers) do
        if declares(super, field, visited) then
          return true
        end
      end
    end
    return false
  end
  for _, done in ipairs(outcomes) do
    local file, made = done.file, done.made
    local by_code: {string: {Parser.Error}} = {}
    for _, e in ipairs(made.errors) do
      local held = by_code[e.code] or {}
      held[#held + 1] = e
      by_code[e.code] = held
    end
    for _, code in ipairs(Parser.codes) do
      local errors = by_code[code]
      if errors ~= nil then
        local key = file .. " " .. code
        found[key] = #errors
        local limit = pinned[key] or 0
        if #errors > limit then
          for _, e in ipairs(errors) do
            out[#out + 1] = file .. ":" .. e.y .. ":" .. e.x .. ": " .. e.msg .. " (" .. code .. "): " .. e.fix
          end
          out[#out + 1] = file .. ": " .. String.counted(#errors, "error") .. " of " .. code .. " after translation, pinned " ..
            limit .. "; rewrite the form (the fix above) in Teal rather than raise the pin"
        end
      end
    end
    if made.classes == 0 and made.lines_before ~= made.lines_after then
      out[#out + 1] = file .. ": the translation has " .. String.counted(made.lines_after + 1, "line") ..
        " where the file has " .. made.lines_before + 1 .. "; only a method moving into a class changes the lines"
    end
    for _, h in ipairs(made.hazards) do
      local key = file .. " " .. h.class .. ":" .. h.method
      -- A field given `mut` in a record that extends an interface of another
      -- file matters when that interface declares the field.
      local real = h.kind ~= "interface" or declares(last_component(h.name), h.method, {})
      if real and not seen[key] then
        seen[key] = true
        local what = h.kind == "signature" and " differs from its field in " or
          h.kind == "shadow" and " reads another " or
          h.kind == "interface" and " is given mut, which the interface declares: " or " reads "
        hazardous[#hazardous + 1] = file .. ":" .. h.y .. ": " .. h.class .. ":" .. h.method .. what .. h.name
      end
    end
  end
  if memo ~= nil then
    check_memo.finish(memo, "translated")
  end
  local keys: {string} = {}
  for key in pairs(pinned) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local count = found[key] or 0
    if count < pinned[key] then
      out[#out + 1] = key .. ": pinned " .. pinned[key] .. " but " .. count ..
        " found; lower the pin in " .. Ceilings.path .. "'s [translated]"
    end
  end
  if #hazardous > ceiling then
    for _, line in ipairs(hazardous) do
      out[#out + 1] = line
    end
    out[#out + 1] = "methods moved into a class that read or give something else: " .. #hazardous .. ", ceiling " .. ceiling ..
      "; declare the name above its record in Teal rather than raise the ceiling"
  elseif #hazardous < ceiling then
    out[#out + 1] = "methods moved into a class that read or give something else: " .. #hazardous .. ", ceiling " .. ceiling ..
      "; lower the [hazards] ceiling in " .. Ceilings.path
  end
  return out
end

--- What scoping one file found.
local record ScopeOutcome
  --- Why the scopes are not consistent with the tree ([`lang.scopes_cover`]), "" where they are.
  consistent: string
  errors: {Scopes.Error}
end

--- The scope builder's codes by name.
local scope_codes: {string: Scopes.Code} = {}
for _, code in ipairs(Scopes.codes) do
  scope_codes[code] = code
end

--- The outcome a memo kept, or nil where it kept none or it does not read.
local function kept_scopes(text: string, file: string): ScopeOutcome | nil
  local outcome: ScopeOutcome = { consistent = "", errors = {} }
  for _, fields in ipairs(check_memo.decode(text)) do
    if fields[1] == "C" and #fields == 2 then
      outcome.consistent = fields[2]
    elseif fields[1] == "E" and #fields == 6 then
      local code = scope_codes[fields[2]]
      local y, x = math.tointeger(tonumber(fields[3])), math.tointeger(tonumber(fields[4]))
      if code == nil or y == nil or x == nil then
        return nil
      end
      outcome.errors[#outcome.errors + 1] = {
        filename = file, code = code, y = y, x = x, offset = 0, length = 0, msg = fields[5], fix = fields[6],
      }
    else
      return nil
    end
  end
  return outcome
end

--- The outcome of scoping `source`, from `memo` where it holds it under `salt`.
local function scope_outcome(file: string, source: string, declared: {string: Scopes.Global}, memo: Sqlite.Handle | nil,
                             salt: string): ScopeOutcome
  local dialect: Ast.Dialect = file:match("%.d%.tl$") and "decl" or "tl"
  local key = ""
  if memo ~= nil then
    key = check_memo.key(salt, dialect, source)
    local text = check_memo.get(memo, "scoped", key)
    local kept = text ~= nil and kept_scopes(text, file) or nil
    if kept ~= nil then
      return kept
    end
  end
  local parsed = Parser.parse(Lexer.lex(source, file), file, dialect)
  local scoped = Scopes.build(parsed.chunk, file, declared)
  local ok, reason = ScopesCover.check(parsed.chunk, scoped, declared)
  local outcome: ScopeOutcome = { consistent = ok and "" or reason, errors = scoped.errors }
  if memo ~= nil then
    local rows: {{string}} = { { "C", outcome.consistent } }
    for _, e in ipairs(scoped.errors) do
      rows[#rows + 1] = { "E", e.code, tostring(e.y), tostring(e.x), e.msg, e.fix }
    end
    check_memo.put(memo, "scoped", key, check_memo.encode(rows))
  end
  return outcome
end

--- The globals a program may use, as the fork's environment has them: the declarations of the prelude in
--- [`checker/tl.tl`] and of [`checker/stdlib.d.tl`] (`stdlib`, the source the tree holds of it), less the names cosmic's
--- runtime withholds ([`teal.withheld`]), and `_G`, which the checker answers itself. The sources are those a build
--- ([`build.driver`]) lowers first, and the second answer is what it does to the globals they declare.
---
--- TODO: read the globals from the declaration files of the new checker, once it replaces
--- checker/tl.tl, whose prelude is a string that declares `interface userdata is userdata`
--- in a way the new parser reads as the declaration of `interface`.
local function fork_globals(root: string, stdlib: Driver.Source | nil): {Driver.Source},
    function(globals: {string: Scopes.Global})
  local sources: {Driver.Source} = {}
  local tl, _ = Fs.read(root .. "/checker/tl.tl")
  local prelude = tl ~= nil and tl:match("%[=====%[\n(.-)%]=====%]") or nil
  if prelude ~= nil then
    sources[#sources + 1] = Driver.declarations("checker.prelude", "prelude.d.tl", prelude, false, false, {})
  end
  if stdlib ~= nil then
    -- The corrections of [`lang.stdlib_corrections`] are made by the driver, which reports what it could not apply.
    sources[#sources + 1] = Driver.declarations(stdlib.module, stdlib.filename, stdlib.text, true, true, stdlib.aliases)
  end
  local has_prelude = prelude ~= nil
  return sources, function(globals: {string: Scopes.Global})
    if has_prelude then
      -- The prelude declares `interface userdata is userdata`, which the new parser reads as the declaration of
      -- `interface`.
      globals["interface"] = nil
      globals["userdata"] = { space = "type", const = false }
    end
    for _, name in ipairs(teal.withheld) do
      globals[name] = nil
    end
    globals["_G"] = { space = "value", const = false }
  end
end

--- Every `.tl` file of the tree, scoped ([`lang.scopes`]) in the new checker's grammar, apart from
--- [`checker/tl.tl`], which the new checker replaces: the names it resolves must agree with the tree
--- ([`lang.scopes_cover`]), and its errors, which are the fork's `shadows`, `captured_assigned` and
--- `unknown_variable` and the new ones for names and types, are the ones `pinned` (by default
--- the `[scoped]` ceilings of [`build.ceilings`]) counts, no more. A file with more errors of a code than pinned is listed with each,
--- their places and fix; one with fewer, and a pin for a file with none, is told to lower the pin.
--- The sources are the `.tl` files under `root` ([`lexable`]).
--
-- TODO: rewrite the three `not_a_type` sites of the `[scoped]` ceilings (a local that names a type of a module, used as the
-- head of a type) in Teal, or have the translator write the `local type`, once lang/translate.tl reads the scope builder
-- to tell a local used as the head of a type from one that is not.
function tree_checks.scoped(root: string, pinned?: {string: integer}, memo?: Sqlite.Handle): {string}
  local ceilings, why = ceilings_for(root, "scoped", pinned)
  if ceilings == nil then
    return { "reading the ceilings: " .. why }
  end
  pinned = ceilings
  local files, trouble = lexable(root)
  if files == nil then
    return { "reading the sources: " .. trouble }
  end
  local out: {string} = {}
  local found: {string: integer} = {}
  local stdlib: Driver.Source | nil = nil
  for _, row in ipairs(files) do
    local file = row[1]
    local text = row[2]
    if file == "checker/stdlib.d.tl" and text ~= nil then
      stdlib = Driver.source("checker.stdlib", file, text, "decl")
    end
  end
  local sources, adjust = fork_globals(root, stdlib)
  local declared = Driver.globals(sources, adjust)
  local salt = check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl",
    "lang/scopes_cover.tl", "lang/translate.tl", "lang/stdlib_corrections.tl", "checker/stdlib.d.tl", "checker/tl.tl",
    "build/teal.tl", "build/check_memo.tl", "build/driver.tl", "build/tree_checks.tl" },
    "scoped 1")
  if memo ~= nil then
    local _, _ = check_memo.prepare(memo, "scoped")
  end
  for _, row in ipairs(files) do
    local file, source = row[1], row[2]
    if file ~= "checker/tl.tl" then
      local outcome = scope_outcome(file, source, declared, memo, salt)
      if outcome.consistent ~= "" then
        out[#out + 1] = file .. ": its scopes are not consistent with its tree: " .. outcome.consistent
      end
      local by_code: {string: {Scopes.Error}} = {}
      for _, e in ipairs(outcome.errors) do
        local held = by_code[e.code] or {}
        held[#held + 1] = e
        by_code[e.code] = held
      end
      for _, code in ipairs(Scopes.codes) do
        local errors = by_code[code]
        if errors ~= nil then
          local key = file .. " " .. code
          found[key] = #errors
          local limit = pinned[key] or 0
          if #errors > limit then
            for _, e in ipairs(errors) do
              out[#out + 1] = file .. ":" .. e.y .. ":" .. e.x .. ": " .. e.msg .. " (" .. code .. "): " .. e.fix
            end
            out[#out + 1] = file .. ": " .. String.counted(#errors, "error") .. " of " .. code .. " in its scopes, pinned " ..
              limit .. "; follow the fix above rather than raise the pin"
          end
        end
      end
    end
  end
  if memo ~= nil then
    check_memo.finish(memo, "scoped")
  end
  local keys: {string} = {}
  for key in pairs(pinned) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local count = found[key] or 0
    if count < pinned[key] then
      out[#out + 1] = key .. ": pinned " .. pinned[key] .. " but " .. count ..
        " found; lower the pin in " .. Ceilings.path .. "'s [scoped]"
    end
  end
  return out
end

--- An error of the new checker's lowering or checking of a file, as a check lists it.
local type Finding = Ceilings.Finding

--- What lowering or checking one file found: its errors.
local record DeclareOutcome
  errors: {Finding}
end

--- The outcome a memo kept, or nil where it kept none or it does not read; a code is read only if it is one of `codes`.
local function kept_findings(text: string, codes: {string}): DeclareOutcome | nil
  local known: {string: boolean} = {}
  for _, code in ipairs(codes) do
    known[code] = true
  end
  local outcome: DeclareOutcome = { errors = {} }
  for _, fields in ipairs(check_memo.decode(text)) do
    if fields[1] == "E" and #fields == 6 then
      local y, x = math.tointeger(tonumber(fields[3])), math.tointeger(tonumber(fields[4]))
      if not known[fields[2]] or y == nil or x == nil then
        return nil
      end
      outcome.errors[#outcome.errors + 1] = { code = fields[2], y = y, x = x, msg = fields[5], fix = fields[6] }
    elseif fields[1] ~= "N" then
      return nil
    end
  end
  return outcome
end

local function kept_declarations(text: string, _file: string): DeclareOutcome | nil
  return kept_findings(text, Declarations.codes)
end

--- What a memo holds for an outcome.
local function kept_rows(outcome: DeclareOutcome): {{string}}
  local kept: {{string}} = { { "N" } }
  for _, e in ipairs(outcome.errors) do
    kept[#kept + 1] = { "E", e.code, tostring(e.y), tostring(e.x), e.msg, e.fix }
  end
  return kept
end

--- A file of the tree to lower: its module, the modules it requires and what its answer is keyed by.
local record DeclareFile
  file: string
  source: string
  module: string
  dialect: Ast.Dialect
  imports: {string}
  key: string
end

--- The modules a source requires by a literal name.
local function required_modules(source: string): {string}
  local out: {string} = {}
  local seen: {string: boolean} = {}
  for _, name in source:gmatch("require%s*%(?%s*([\"'])([%w_%.%-]+)%1") do
    if not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  return out
end

--- The files of the tree the new checker lowers: every `.tl` file apart from [`checker/tl.tl`], which the new checker
--- replaces, and the files of a `testdata` directory, which hold programs for other projects.
local record Tree
  rows: {DeclareFile}
  --- Each file by its module, and by the name of its path below each directory: a project inside the tree (`ci/`, a
  --- fixture directory) names its modules from its own root.
  by_module: {string: DeclareFile}
  --- The same files as the sources a build is given ([`build.driver`]).
  index: Driver.Index
end

--- The files of `files` that a lowering covers, each with the key its answer is kept under: `salt`, its dialect and
--- its source and the sources of every module it requires, however far.
local function tree_of(files: {{string}}, salt: string): Tree
  local index = Driver.index(files, true, function(file: string): boolean
    -- A directory of testdata holds programs for other projects, whose modules are not in the tree.
    return file == "checker/tl.tl" or file:find("^testdata/") ~= nil or file:find("/testdata/", 1, true) ~= nil
  end)
  local tree: Tree = { rows = {}, by_module = {}, index = index }
  local rows, by_module = tree.rows, tree.by_module
  local hashes: {string: string} = {}
  local row_of: {Driver.Source: DeclareFile} = {}
  for _, source in ipairs(index.sources) do
    local row: DeclareFile = {
      file = source.filename, source = source.text, module = source.module, dialect = source.dialect,
      imports = required_modules(source.text), key = "",
    }
    rows[#rows + 1] = row
    row_of[source] = row
    -- A module given as a declaration and a source is read from the declaration; the key holds both texts.
    hashes[row.module] = (hashes[row.module] or "") .. Hash.hex_sha256(source.text)
  end
  for name, source in pairs(index.by_module) do
    local row = row_of[source]
    if row ~= nil then
      by_module[name] = row
    end
  end
  -- The key of a file is its source and the sources of every module it requires, however far.
  for _, row in ipairs(rows) do
    local reached: {string: boolean} = { [row.module] = true }
    local stack: {string} = {}
    for _, m in ipairs(row.imports) do
      stack[#stack + 1] = m
    end
    while #stack > 0 do
      local m = stack[#stack]
      stack[#stack] = nil
      local dep = by_module[m]
      if dep ~= nil and not reached[dep.module] then
        reached[dep.module] = true
        for _, next_module in ipairs(dep.imports) do
          stack[#stack + 1] = next_module
        end
      end
    end
    local names: {string} = {}
    for m in pairs(reached) do
      names[#names + 1] = m
    end
    table.sort(names)
    local parts: {string} = {}
    for i, m in ipairs(names) do
      parts[i] = m .. "=" .. hashes[m]
    end
    -- The files of a cycle of requires reach the same modules: the file itself tells their keys apart.
    row.key = check_memo.key(salt, row.dialect, row.module .. "\n" .. table.concat(parts, "\n"))
  end
  return tree
end

--- A build ([`build.driver`]) over the tree at `root`: the fork's prelude and the standard library's declarations as its
--- globals, the files of `tree` as its modules.
---
-- TODO: count a broken file's own declaration errors once its `translated` pins reach 0: until then nothing holds
-- what its translation's parse errors hide (44 files when this landed, among them lang/ast.tl and lang/types.tl).
local function tree_build(root: string, tree: Tree): Driver.Build
  local globals, adjust = fork_globals(root, tree.index.by_module["checker.stdlib"])
  local build = Driver.new({
    globals = globals, adjust = adjust, external = { "cosmic.sys", "cosmic.internal.process", "cosmic.internal.socket" },
    types = false,
  })
  build:provide(Driver.files(tree.index))
  return build
end

--- The errors of `list` as a check lists them.
local function findings_of(list: {Driver.Problem}): {Finding}
  local out: {Finding} = {}
  for _, e in ipairs(list) do
    out[#out + 1] = { code = e.code, y = e.y, x = e.x, msg = e.msg, fix = e.fix }
  end
  return out
end

--- The files of `tree` whose answer `memo` does not hold, with the answers it does.
local function kept_outcomes(memo: Sqlite.Handle | nil, kind: string, tree: Tree,
                             read: function(text: string, file: string): DeclareOutcome | nil
): {string: DeclareOutcome}, {DeclareFile}
  local outcomes: {string: DeclareOutcome} = {}
  local missed: {DeclareFile} = {}
  for _, row in ipairs(tree.rows) do
    local text = memo ~= nil and check_memo.get(memo, kind, row.key) or nil
    local kept = text ~= nil and read(text, row.file) or nil
    if kept ~= nil then
      outcomes[row.file] = kept
    else
      missed[#missed + 1] = row
    end
  end
  return outcomes, missed
end

--- The lines that list the errors over their ceilings ([`Ceilings.over`]): the errors of each code of each file are held
--- to `pinned`, a file with more than pinned is listed with each, one with fewer and a pin for a code the file lacks is
--- told to lower the pin. `what` says what the errors are of in the message, and `where` which ceilings to lower.
local function held_to_pins(tree: Tree, outcomes: {string: DeclareOutcome}, codes: {string}, pinned: {string: integer},
                            what: string, where: string): {string}
  local out: {string} = {}
  local found: {string: integer} = {}
  for _, row in ipairs(tree.rows) do
    local outcome = outcomes[row.file]
    local held = Ceilings.over(row.file, outcome.errors, codes, pinned, what)
    for _, line in ipairs(held.lines) do
      out[#out + 1] = line
    end
    for key, n in pairs(held.found) do
      found[key] = n
    end
  end
  for _, line in ipairs(Ceilings.fallen(found, pinned, where)) do
    out[#out + 1] = line
  end
  return out
end

--- Every `.tl` file of the tree, its declarations and annotations lowered ([`lang.declarations`]) in the new
--- checker's grammar from the translated source, apart from [`checker/tl.tl`], which the new checker replaces, and
--- the files of a `testdata` directory, and counting nothing of a file whose translation does not parse:
--- the errors are the ones `pinned` (by default the `[declared]` ceilings of [`build.ceilings`]) counts, no more. A file with more errors of a
--- code than pinned is listed with each, their places and fix; one with fewer, and a pin for a file with none,
--- is told to lower the pin. The declaration files of the checker and the prelude of its fork declare the
--- globals; every other file imports the modules it names from the whole tree, so the answer for a file is
--- kept in `memo` under the sources of every module it requires, directly or not.
function tree_checks.declared(root: string, pinned?: {string: integer}, memo?: Sqlite.Handle): {string}
  local ceilings, why = ceilings_for(root, "declared", pinned)
  if ceilings == nil then
    return { "reading the ceilings: " .. why }
  end
  pinned = ceilings
  local files, trouble = lexable(root)
  if files == nil then
    return { "reading the sources: " .. trouble }
  end
  local salt = check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl",
    "lang/translate.tl", "lang/types.tl", "lang/relation.tl", "lang/declarations.tl", "lang/stdlib_corrections.tl",
    "checker/stdlib.d.tl", "checker/tl.tl", "build/teal.tl", "build/check_memo.tl", "build/driver.tl",
    "build/tree_checks.tl" }, "declared 1")
  local tree = tree_of(files, salt)
  if memo ~= nil then
    local _, _ = check_memo.prepare(memo, "declared")
  end
  local outcomes, missed = kept_outcomes(memo, "declared", tree, kept_declarations)
  local problems: {string} = {}
  if #missed > 0 then
    local build = tree_build(root, tree)
    local names: {string} = {}
    for _, row in ipairs(missed) do
      names[#names + 1] = row.module
    end
    build:lower(names)
    for _, row in ipairs(missed) do
      local result = build:result(row.module, false)
      local outcome: DeclareOutcome = { errors = {} }
      if result ~= nil and not result.broken then
        outcome = { errors = findings_of(result.declared) }
      end
      outcomes[row.file] = outcome
      if memo ~= nil then
        check_memo.put(memo, "declared", row.key, check_memo.encode(kept_rows(outcome)))
      end
    end
    problems = build.problems
  end
  if memo ~= nil then
    check_memo.finish(memo, "declared")
  end
  local out = held_to_pins(tree, outcomes, Declarations.codes, pinned, "declarations",
    Ceilings.path .. "'s [declared]")
  for _, problem in ipairs(problems) do
    table.insert(out, 1, problem)
  end
  return out
end

local function kept_checks(text: string, _file: string): DeclareOutcome | nil
  return kept_findings(text, Check.codes)
end

--- Every `.tl` file of the tree, translated and lowered as [`declared`] has it and then checked
--- ([`lang.check`]): every expression and statement of its bodies typed, without flow. The files left out are those
--- of [`declared`], the declaration files (which have no bodies) and the files whose translation does not parse. The
--- errors are the ones `pinned` (by default the `[checked]` ceilings of [`build.ceilings`]) counts, no more: a file with more errors of a code than
--- pinned is listed with each, their places and fix; one with fewer, and a pin for a file with none, is told to lower
--- the pin. The pins are ceilings that each rewrite and each later piece of the checker
--- lowers, and none is raised, but for a file whose translation did not parse and now does, which is pinned at what it has.
--- The answer for a file is kept in `memo` under the sources of every module it requires,
--- directly or not, and of the checker. `phases`, when given, gets the nanoseconds spent translating, parsing and scoping
--- (`prepare`), lowering (`lower`) and checking (`check`) the files the memo lacked.
function tree_checks.checked(root: string, pinned?: {string: integer}, memo?: Sqlite.Handle,
                             phases?: {string: integer}): {string}
  local ceilings, why = ceilings_for(root, "checked", pinned)
  if ceilings == nil then
    return { "reading the ceilings: " .. why }
  end
  pinned = ceilings
  local files, trouble = lexable(root)
  if files == nil then
    return { "reading the sources: " .. trouble }
  end
  local salt = check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl",
    "lang/translate.tl", "lang/types.tl", "lang/relation.tl", "lang/declarations.tl", "lang/check.tl",
    "lang/flow.tl", "lang/check_codes.tl", "lang/warnings.tl", "lang/stdlib_corrections.tl", "checker/stdlib.d.tl",
    "checker/tl.tl", "build/teal.tl", "build/check_memo.tl", "build/driver.tl", "build/tree_checks.tl" }, "checked 1")
  local tree = tree_of(files, salt)
  if memo ~= nil then
    local _, _ = check_memo.prepare(memo, "checked")
  end
  local outcomes, missed = kept_outcomes(memo, "checked", tree, kept_checks)
  local problems: {string} = {}
  if #missed > 0 then
    local build = tree_build(root, tree)
    local names: {string} = {}
    for _, row in ipairs(missed) do
      names[#names + 1] = row.module
    end
    build:lower(names)
    for _, row in ipairs(missed) do
      local result = build:result(row.module, true)
      local outcome: DeclareOutcome = { errors = {} }
      if result ~= nil and row.dialect == "tl" and not result.broken then
        outcome = { errors = findings_of(result.bodies) }
      end
      outcomes[row.file] = outcome
      if memo ~= nil then
        check_memo.put(memo, "checked", row.key, check_memo.encode(kept_rows(outcome)))
      end
    end
    problems = build.problems
    if phases ~= nil then
      phases.check = build.timing.check
      phases.prepare = build.timing.prepare
      phases.lower = build.timing.lower
    end
  end
  if memo ~= nil then
    check_memo.finish(memo, "checked")
  end
  local out = held_to_pins(tree, outcomes, Check.codes, pinned, "bodies", Ceilings.path .. "'s [checked]")
  for _, problem in ipairs(problems) do
    table.insert(out, 1, problem)
  end
  return out
end

local function lines_of(text: string): {string}
  local out: {string} = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line
  end
  return out
end

--- How many lines `a` and `b` differ by: the lines of either that no ordered match pairs with the other's (the
--- length of a shortest edit script, Myers' greedy search).
local function line_changes(a: {string}, b: {string}): integer
  local lo = 1
  while lo <= #a and lo <= #b and a[lo] == b[lo] do
    lo = lo + 1
  end
  local hi_a, hi_b = #a, #b
  while hi_a >= lo and hi_b >= lo and a[hi_a] == b[hi_b] do
    hi_a, hi_b = hi_a - 1, hi_b - 1
  end
  local n, m = hi_a - lo + 1, hi_b - lo + 1
  if n == 0 or m == 0 then
    return n + m
  end
  local reach: {integer: integer} = { [1] = 0 }
  for d = 0, n + m do
    for k = -d, d, 2 do
      local x: integer
      if k == -d or (k ~= d and reach[k - 1] < reach[k + 1]) then
        x = reach[k + 1]
      else
        x = reach[k - 1] + 1
      end
      local y = x - k
      while x < n and y < m and a[lo + x] == b[lo + y] do
        x, y = x + 1, y + 1
      end
      reach[k] = x
      if x >= n and y >= m then
        return d
      end
    end
  end
  return n + m
end

--- What generating one file found.
local record GenerateOutcome
  --- Why there is nothing to compare, "" where there is: the translation does not parse (`translated` counts
  --- that) or the fork writes no Lua.
  skipped: string
  --- How many lines of the generator's Lua differ from the fork's.
  differ: integer
  --- The first line that differs, with the generator's text of it and the fork's.
  at: integer
  ours: string
  fork: string
  --- What the generator refused.
  errors: {Codegen.Error}
  --- Why the Lua it wrote does not load, "" where it does.
  invalid: string
end

local codegen_codes: {string: Codegen.Code} = {}
for _, code in ipairs(Codegen.codes) do
  codegen_codes[code] = code
end

--- The outcome a memo kept, or nil where it kept none or it does not read.
local function kept_generation(text: string): GenerateOutcome | nil
  local outcome: GenerateOutcome = { skipped = "", differ = 0, at = 0, ours = "", fork = "", errors = {}, invalid = "" }
  for _, fields in ipairs(check_memo.decode(text)) do
    if fields[1] == "S" and #fields == 2 then
      outcome.skipped = fields[2]
    elseif fields[1] == "I" and #fields == 2 then
      outcome.invalid = fields[2]
    elseif fields[1] == "D" and #fields == 5 then
      local differ, at = math.tointeger(tonumber(fields[2])), math.tointeger(tonumber(fields[3]))
      if differ == nil or at == nil then
        return nil
      end
      outcome.differ, outcome.at, outcome.ours, outcome.fork = differ, at, fields[4], fields[5]
    elseif fields[1] == "E" and #fields == 6 then
      local code = codegen_codes[fields[2]]
      local y, x = math.tointeger(tonumber(fields[3])), math.tointeger(tonumber(fields[4]))
      if code == nil or y == nil or x == nil then
        return nil
      end
      outcome.errors[#outcome.errors + 1] = { code = code, y = y, x = x, msg = fields[5], fix = fields[6] }
    else
      return nil
    end
  end
  return outcome
end

--- The fork's compiler, loaded on the first file whose Lua is not in the memo.
local function fork_compiler(held: {compiler}): compiler | nil
  if held[1] == nil then
    local loaded, _ = teal.load()
    if loaded == nil then
      return nil
    end
    held[1] = loaded
  end
  return held[1]
end

--- The Lua the fork writes for `source`, from `memo` where it holds it under `key`; nil and why where it writes none.
local function fork_lua(file: string, source: string, memo: Sqlite.Handle | nil, key: string, held: {compiler}): string | nil, string
  if memo ~= nil then
    local kept = check_memo.get(memo, "generated", key)
    if kept ~= nil then
      if kept:sub(1, 1) == "L" then
        return kept:sub(2), ""
      end
      return nil, kept:sub(2)
    end
  end
  local built = fork_compiler(held)
  if built == nil then
    return nil, "the fork's compiler is not in this binary"
  end
  local lua, why = compile.lua(built, file, source)
  if memo ~= nil then
    check_memo.put(memo, "generated", key, lua ~= nil and "L" .. lua or "N" .. why)
  end
  if lua == nil then
    return nil, why
  end
  return lua, ""
end

--- The outcome of generating `source`, from `memo` where it holds it under `salt`.
local function generate_outcome(file: string, source: string, memo: Sqlite.Handle | nil, salt: string, fork_salt: string,
                                held: {compiler}): GenerateOutcome
  local fork_key = check_memo.key(fork_salt, "tl", source)
  local key = check_memo.key(salt, "tl", source)
  if memo ~= nil then
    local text = check_memo.get(memo, "generated", key)
    local kept = text ~= nil and kept_generation(text) or nil
    if kept ~= nil then
      -- The fork's Lua is kept as long as the file is, so that a change to the generator does not run the fork again.
      local _ = check_memo.get(memo, "generated", fork_key)
      return kept
    end
  end
  local outcome: GenerateOutcome = { skipped = "", differ = 0, at = 0, ours = "", fork = "", errors = {}, invalid = "" }
  local made = Translate.translate(source, file)
  local parsed = Parser.parse(Lexer.lex(made.text, file), file, "tl")
  if #parsed.errors > 0 then
    outcome.skipped = "its translation does not parse"
  else
    local lua, why = fork_lua(file, source, memo, fork_key, held)
    if lua == nil then
      outcome.skipped = "the fork writes no Lua: " .. why
    else
      -- The translator writes an `if` expression only for a value that is never false, which it tells the generator.
      -- The enums are not passed, so `v is E` is the fork's test of the kind, which this oracle compares with the fork's
      -- Lua; the checker's Lua tests the values ([`lang.check`] `enums`).
      --
      -- TODO: once the new checker's Lua is what the build writes, pass [`Check.enums`] here and compare the membership
      -- test with the fork's kind test normalized, or drop this oracle.
      local generated = Codegen.generate(parsed.chunk, Scopes.build(parsed.chunk, file, {}), Translate.never_false)
      outcome.errors = generated.errors
      local loaded, load_why = load(generated.text, "=" .. file, "t", {})
      if loaded == nil then
        outcome.invalid = tostring(load_why)
      end
      -- The reserved form is not the fork's `setmetatable` pattern, so a file with a class is held to the fork's Lua
      -- apart from its classes.
      local ours, fork = Codegen.compared(generated.text), Codegen.compared(lua)
      for _, s in ipairs(parsed.chunk.body.stats) do
        if s is Ast.Class then
          ours = Codegen.without_classes(generated.text, parsed.chunk)
          fork = Codegen.fork_without_classes(lua, parsed.chunk, made.metatables)
          break
        end
      end
      if ours ~= fork then
        local a, b = lines_of(ours), lines_of(fork)
        outcome.differ = line_changes(a, b)
        local at = 1
        while a[at] == b[at] do
          at = at + 1
        end
        outcome.at, outcome.ours, outcome.fork = at, (a[at] or ""):sub(1, 100), (b[at] or ""):sub(1, 100)
      end
    end
  end
  if memo ~= nil then
    local rows: {{string}} = {}
    if outcome.skipped ~= "" then
      rows[1] = { "S", outcome.skipped }
    else
      rows[1] = { "D", tostring(outcome.differ), tostring(outcome.at), outcome.ours, outcome.fork }
    end
    if outcome.invalid ~= "" then
      rows[#rows + 1] = { "I", outcome.invalid }
    end
    for _, e in ipairs(outcome.errors) do
      rows[#rows + 1] = { "E", e.code, tostring(e.y), tostring(e.x), e.msg, e.fix }
    end
    check_memo.put(memo, "generated", key, check_memo.encode(rows))
  end
  return outcome
end

--- Every `.tl` file of the tree, translated ([`lang.translate`]), parsed, scoped and generated ([`lang.codegen`]),
--- and its Lua compared with the fork's for the Teal it started from: the same bytes, once the layout of a
--- `continue` is set aside ([`lang.codegen`]'s `compared`). The fork compiles each file alone with no module served, so its Lua is
--- a function of the file; what it writes from the types of other modules (a `local _ = require("m")` it drops where
--- `m` returns a type, an `is` of an imported enum or userdata) is outside this check. A file with a class is
--- compared apart from its classes (see the `[generated]` ceilings of [`build.ceilings`]), and nothing of the Lua the generator writes for a class is
--- compared here: [`lang.codegen_test`] runs it. A file the check cannot compare
--- (its translation does not parse, which `translated` counts, or the fork writes none) and the fork's own
--- [`checker/tl.tl`] and the declaration files, which have no Lua, are left out. The files that differ are the ones
--- `pinned` (by default the `[generated]` ceilings) names, with how many lines differ: a file with more lines than pinned is listed
--- with its first difference and each refusal of the generator, and one with fewer, and a pin for a file that
--- matches, is told to lower the pin. The Lua the generator writes must also load, whatever the fork writes. The
--- answer for a file is kept in `memo` under its source, the sources of the generator and of everything it reads and
--- the fork's compiler, and the fork's Lua under the file and the compiler alone.
function tree_checks.generated(root: string, pinned?: {string: integer}, memo?: Sqlite.Handle): {string}
  local ceilings, why = ceilings_for(root, "generated", pinned)
  if ceilings == nil then
    return { "reading the ceilings: " .. why }
  end
  pinned = ceilings
  local files, trouble = lexable(root)
  if files == nil then
    return { "reading the sources: " .. trouble }
  end
  local fork_salt = check_memo.salt(root, { "checker/tl.tl", "checker/flow.tl", "checker/narrowing.tl",
    "checker/captures.tl", "checker/facts.tl", "checker/stdlib.d.tl", "build/compile.tl" }, "forked 1")
  local salt = check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl",
    "lang/translate.tl", "lang/codegen.tl", "build/check_memo.tl", "build/tree_checks.tl" }, "generated 1 " .. fork_salt)
  if memo ~= nil then
    local _, _ = check_memo.prepare(memo, "generated")
  end
  local out: {string} = {}
  local found: {string: integer} = {}
  local held: {compiler} = {}
  for _, row in ipairs(files) do
    local file, source = row[1], row[2]
    if file ~= "checker/tl.tl" and not file:match("%.d%.tl$") then
      local outcome = generate_outcome(file, source, memo, salt, fork_salt, held)
      if outcome.invalid ~= "" then
        out[#out + 1] = file .. ": the Lua the generator wrote does not load: " .. outcome.invalid
      end
      if outcome.skipped == "" and outcome.differ > 0 then
        found[file] = outcome.differ
        if outcome.differ > (pinned[file] or 0) then
          for _, e in ipairs(outcome.errors) do
            out[#out + 1] = file .. ":" .. e.y .. ":" .. e.x .. ": " .. e.msg .. " (" .. e.code .. "): " .. e.fix
          end
          out[#out + 1] = file .. ":" .. outcome.at .. ": the Lua differs from the fork's: " .. outcome.ours .. " | " ..
            outcome.fork
          out[#out + 1] = file .. ": " .. String.counted(outcome.differ, "line") .. " differ from the fork's Lua, pinned " ..
            (pinned[file] or 0) .. "; write the Lua the fork writes rather than raise the pin"
        end
      end
    end
  end
  if memo ~= nil then
    check_memo.finish(memo, "generated")
  end
  local keys: {string} = {}
  for key in pairs(pinned) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local count = found[key] or 0
    if count < pinned[key] then
      out[#out + 1] = key .. ": pinned " .. String.counted(pinned[key], "line") .. " but " .. count ..
        " differ; lower the pin in " .. Ceilings.path .. "'s [generated]"
    end
  end
  return out
end

--- The outcome a memo kept, or nil where it kept none or it does not read.
local function kept_reading(text: string): Compared.Outcome | nil
  local outcome: Compared.Outcome = { skipped = "", differences = {} }
  for _, fields in ipairs(check_memo.decode(text)) do
    if fields[1] == "S" and #fields == 2 then
      outcome.skipped = fields[2]
    elseif fields[1] == "D" and #fields == 2 then
      outcome.differences[#outcome.differences + 1] = fields[2]
    else
      return nil
    end
  end
  return outcome
end

--- The outcome of reading `source`, a file named `file`, by both sets of readers, from `memo` where it holds it under `key`;
--- nil and why where the fork's compiler is not in this binary.
local function read_outcome(file: string, source: string, memo: Sqlite.Handle | nil, key: string, held: {compiler}):
    Compared.Outcome | nil, string
  if memo ~= nil then
    local text = check_memo.get(memo, "read", key)
    local kept = text ~= nil and kept_reading(text) or nil
    if kept ~= nil then
      return kept, ""
    end
  end
  local built = fork_compiler(held)
  if built == nil then
    return nil, "the fork's compiler is not in this binary"
  end
  local outcome = Compared.file(built, file, source)
  if memo ~= nil then
    local rows: {{string}} = {}
    if outcome.skipped ~= "" then
      rows[1] = { "S", outcome.skipped }
    end
    for _, line in ipairs(outcome.differences) do
      rows[#rows + 1] = { "D", line }
    end
    check_memo.put(memo, "read", key, check_memo.encode(rows))
  end
  return outcome, ""
end

--- Every `.tl` file of the tree read by the fork's readers ([`build.ast`], [`build.scopes`], [`build.globals`],
--- [`build.stub`], [`build.coverage`]) and by their ports ([`build.syntax_compared`]) over the file translated to the
--- new grammar, and what each reader answers compared: the modules a file requires, the lines of its global
--- declarations, the references through an alias and the names in scope, its stub, its executable lines. A file that
--- differs in more readers than `pinned` (by default the `[read]` ceilings) allows is listed with each reader that
--- differs and how; one that differs in fewer, and a pin for a file that agrees, is told to lower the pin. A file the
--- check cannot compare (the fork or its translation does not parse, which `translated` counts), the fork's own
--- [`checker/tl.tl`] and the declaration files, which the fork's readers do not read, are left out. The answer for a
--- file is kept in `memo` under its source and the sources of every reader and of the fork's parser; the format of what
--- it keeps ([`kept_reading`], [`read_outcome`]) is the label of the salt, bumped when either changes.
function tree_checks.read(root: string, pinned?: {string: integer}, memo?: Sqlite.Handle): {string}
  local ceilings, why = ceilings_for(root, "read", pinned)
  if ceilings == nil then
    return { "reading the ceilings: " .. why }
  end
  pinned = ceilings
  local files, trouble = lexable(root)
  if files == nil then
    return { "reading the sources: " .. trouble }
  end
  local salt = check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl",
    "lang/translate.tl", "build/syntax_compared.tl", "build/syntax_node.tl",
    "build/syntax_match.tl", "build/syntax_rewrite.tl",
    "build/syntax_scopes.tl", "build/syntax_globals.tl",
    "build/syntax_stub.tl", "build/coverage/syntax_lines.tl", "build/ast/init.tl", "build/ast/node.tl", "build/ast/walk.tl",
    "build/ast/match_cast.tl", "build/coverage/init.tl",
    "build/ast/match.tl", "build/ast/rewrite.tl", "build/ast/requires.tl", "build/scopes.tl", "build/globals.tl",
    "build/stub.tl", "build/coverage/lines.tl", "checker/tl.tl", "build/check_memo.tl" }, "read 2")
  if memo ~= nil then
    local _, _ = check_memo.prepare(memo, "read")
  end
  local out: {string} = {}
  local found: {string: integer} = {}
  local held: {compiler} = {}
  for _, row in ipairs(files) do
    local file, source = row[1], row[2]
    if file ~= "checker/tl.tl" and not file:match("%.d%.tl$") then
      local outcome, missing = read_outcome(file, source, memo, check_memo.key(salt, "tl", source), held)
      if outcome == nil then
        return { missing }
      end
      local count = #outcome.differences
      if outcome.skipped == "" and count > 0 then
        found[file] = count
        if count > (pinned[file] or 0) then
          for _, line in ipairs(outcome.differences) do
            out[#out + 1] = file .. ": " .. line
          end
          out[#out + 1] = file .. ": " .. String.counted(count, "reader") .. (count == 1 and " differs" or " differ") ..
            " from the fork's, pinned " .. (pinned[file] or 0) .. "; read what the fork reads rather than raise the pin"
        end
      end
    end
  end
  if memo ~= nil then
    check_memo.finish(memo, "read")
  end
  for _, line in ipairs(Ceilings.fallen(found, pinned, Ceilings.path .. "'s [read]")) do
    out[#out + 1] = line
  end
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
      { name = "unnamed types", lines = tree_checks.unnamed_types(db) },
      { name = "doc anchors", lines = tree_checks.anchors(db) },
      { name = "compiler readers", lines = tree_checks.compiler_readers(db) },
      { name = "build directory", lines = tree_checks.build_directory(db) },
      { name = "stand-ins", lines = tree_checks.stand_ins(db) },
      { name = "docs queries", lines = tree_checks.queries(db) },
      { name = "quieted", lines = tree_checks.quieted(db) },
      { name = "restricted", lines = tree_checks.restricted(db) },
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
