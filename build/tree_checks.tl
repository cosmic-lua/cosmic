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
--- literal plural after a number, no test returning early (a skip is [`Test.skip`]), every file under ci/testdata
--- type-checking standalone, and every `.tl` file scoping, lowering and checking in the new checker's grammar but for
--- what the markers hold. Each asks the tree's projection,
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

local type tree_standing = require("build.tree")
local build_paths = require("build.paths")
local Fs = require("cosmic.fs")
local Shape = require("cosmic.shape")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local check_memo = require("build.check_memo")
local CodeWalk = require("build.code_walk")
-- Declares what text this module reads ([`build.code_walk`]'s `markers`): the docs, uses and places of the projection it checks.
local _ = require("build.reads.all")
local closure_store = require("build.closure_store")
local ContractRules = require("build.contract_rules")
local key_parts = require("build.key_parts")
local docs = require("build.docs")
local docs_checks = require("build.docs_checks")
local ErrorRender = require("build.error_render")
local GrammarMode = require("build.grammar_mode")
local Pipeline = require("build.pipeline")
local link_text = require("build.link_text")
local host_names = require("build.host_names")
local identity = require("build.identity")
local importer = require("build.importer")
local refusals = require("build.refusals")
local Ast = require("lang.ast")
local Check = require("lang.check")
local Ceilings = require("build.ceilings")
local Markers = require("build.markers")
local Report = require("build.syntax_report")
local SyntaxContracts = require("build.syntax_contracts")
local Declarations = require("lang.declarations")
local Driver = require("build.driver")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local PipelineCheck = require("build.pipeline_check")
local PluralSites = require("build.plural_sites")
local ShapeKey = require("build.shape_key")
local Scopes = require("lang.scopes")
local SyntaxNode = require("build.syntax_node")
local TestClones = require("build.test_clones")
local TestReturns = require("build.test_returns")
local ScopesCover = require("lang.scopes_cover")
local Warnings = require("lang.warnings")
local TreeProgram = require("build.tree_program")
local shared_compiles = require("build.shared_compiles")
local symbols = require("build.symbols")
local work = require("build.work")
local writer = require("build.writer")
local String = require("cosmic.string")
local Hash = require("cosmic.hash")
local artifact = require("build.artifact")

--- Element `position` of `list`, a position taken from its bounds or from the rows a producer in this file made.
local function nth<T>(list: {T}, position: integer): T
  return (assert(list[position], "a position is within the list"))
end

--- The value kept under `key` in `map`, a key taken from `map` or set before it is read.
local function lookup_in<K, V>(map: {K: V}, key: K): V
  return (assert(map[key], "the key is one of the map's"))
end

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
local allowed: mut {string: string} = {}

allowed["build.c.bootstrap_cosmic"] = "the bootstrap cosmic a check's compiler runs on, fetched unconfined " ..
  "where it is not cached; the module's toolchain calls it, and a test holds it to saying why where it cannot be had"
allowed["build.c.own_caches"] = "the environment c.check gives a confined compiler, with every cache it writes in " ..
  "the check's own directory, which a test holds to the cores among them: the host's fail a check where they are cold"
allowed["build.compile_fanout.meminfo"] = "text a test gives in place of the host's /proc/meminfo: a sandbox's /proc has " ..
  "none, and no test is to depend on what its host has free"
allowed["build.dataset.read"] = "the reader load_text composes and falls back on, tested directly " ..
  "over each format's text, and with load the reference load_text's fuzz property is held to"

allowed["cosmic.hash.file"] = "the raw-digest form of hex_file, which is its only caller outside tests"

allowed["build.importer.due"] = "when a compile says a refusal ahead of its report; the compile loop asks it of the " ..
  "clock, and build/importer_test.tl of times it chooses"

allowed["build.searchable.share"] = "opens one file or directory to every user for the tests of a policy's child; build/child_policy_fixture.tl imports the module for `open`, so the tests' own uses no longer earn `share`"

allowed["build.shared_verdicts.rows_kept"] = "the bound a file of a checked run's verdicts keeps, which the file's name decides; the settle of the same module applies it, and a test holds the names to it"
allowed["build.test_key.requirements"] = "the names a module requires of its host, `loopback` derived from its declared addresses, which `ask_host` asks and a test holds to the derivation"
allowed["build.test_key.met_nothing"] = "whether a checked run's report holds a violation, which `judge` asks and a test holds to the report's two clauses (a row, and rows that went unrecorded)"
allowed["build.work.lock_holder_in"] = "the reading of /proc/locks `holding` names a lock's holder by, which a test " ..
  "holds to lines a sandboxed worker's /proc cannot show it"
allowed["build.work.holder_line"] = "what `holding` says of what it read of the host, which a test holds to hosts " ..
  "a sandboxed worker cannot be"
allowed["build.work.waiting_line"] = "the line a run waiting for the working database's write lock says, which " ..
  "only a run another holds the lock against reaches; its test holds the wording without a second process"
allowed["build.memprobe.enabled"] = "the switch `COSMIC_MEMPROBE` sets for a run, which a test turns on to read the line a mark writes"

allowed["build.type_watch.skip_reason"] = "the reason `during` skips with, which a test reads for a checked and a plain run " ..
  "since a skipping test cannot show it"

allowed["build.memprobe.sink"] = "where a mark writes its line, which a test takes in place of standard error"
allowed["build.dataset.load"] = "the loader load_text composes and falls back on, tested directly " ..
  "over rows a test builds, whose keys no file need hold"

allowed["cosmic.http.public_key_pin"] = "public API: how a program makes the pin `opts.pin` holds a " ..
  "server's key to; cosmic's own fetches choose roots, not pins"

allowed["cosmic.http.default_roots"] = "public API: the roots a request naming none trusts, for a " ..
  "program to say which it runs with"

allowed["cosmic.http.minimal_roots"] = "public API: the roots `opts.roots = \"minimal\"` names, for a " ..
  "program to read or start a list of its own from"

local function allow(names: {string}, why: string)
  for _, name in ipairs(names) do
    allowed[name] = why
  end
end

allow({
  "build.syntax_analyzer.analyze",
  "build.syntax_match.matches", "build.syntax_match.text",
}, "a reader of the syntax tree (build/syntax_*.tl) that the build reaches through its callers (`analysis_of`, " ..
    "`docs`, the pipeline's derive) and that its tests call directly, to say what one read of a source gives")

allow({
  "build.error_catalog.rows", "build.error_catalog.check", "build.error_catalog.problems",
  "build.error_catalog.text", "build.error_catalog.emitted", "build.error_render.lines",
  "build.error_render.complain",
}, "the checker's error reporting (build/error_catalog.tl, build/error_render.tl), which the compile prints and writes " ..
    "through `insert` and `line`, and whose parts its tests call directly")

allow({ "build.seed.compile", "build.seed.program" }, "the two things the bridge asks of the seed (core/bridge.lua, which is " ..
    "Lua and loads the seed's Lua by name), which no Teal calls")

allow({ "build.plans.full_keys" }, "the keys made of nothing kept, which build/dependency_keys_test.tl holds " ..
    "the keys `dependency_keys` keeps to, edit by edit")
allow({
  "build.syntax_receivers.blind", "build.syntax_rewrite.find_all", "build.doctest.blocks", "build.grammar_mode.refusal_of",
  "build.plural_sites.lines", "build.coverage.syntax_lines.executable", "build.withheld.package_fields",
  "build.syntax_contracts.rules", "build.syntax_receivers.known",
}, "tested directly: a reader whose callers outside its module take it through a composed reader (`references`, `rewrite`, " ..
    "`generate`, `mode`, `sites`, `lines`, `globals`), each tested over sources or tables of its own")

allow({ "build.todos.run" }, "the verb's run, which a test calls with a tree and a `reboot.Seen` to run it " ..
    "as that tree's own tool would; the verb's spec calls it with the command line alone")

allow({ "build.pipeline.over" }, "the build's compile with the new checker: a build over given sources, which the " ..
    "pipeline's own tests are the callers of")

allow({ "build.pipeline.project" }, "tested directly: the options of a project given the texts of the declarations (a worker's " ..
    "store holds none of the tool's)")

allowed["cosmic.net.nameservers"] = "the public way to list the system's DNS servers for " ..
  "callers outside this tree; tested directly over a resolv.conf"

allowed["cosmic.internal.relay_config.parse_addresses"] = "tested directly: the reading of Linux's " ..
  "interface tables over fixture text, which host_addresses makes of the host's own"
for _, name in ipairs({ "plan", "name_servers", "upstream_addresses", "resolved_upstream", "table", "public",
    "loopback_listeners" }) do
  allowed["cosmic.internal.relay_start." .. name] = "tested directly: a step of `handover` and " ..
    "`direct_handover`, which are composed from it, each tested over fixtures of its own"
end
for _, name in ipairs({ "dropped_violations", "most_kept", "fact", "cross" }) do
  allowed["build.test_worker." .. name] = "the seam that lets a test run the hook a checked run's Lua calls " ..
    "in its own process, over Lua it compiled with the checks, and read what the hook met; " ..
    "`run` calls them for a worker"
end
allowed["cosmic.sandbox.policy.system_profile"] = "the seam that lets a test draw the " ..
  "other host's \"system\" profile; rules.profile calls it with this host's"
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
  "which the build's own reading of one (build.syntax_analyzer, which cannot require this " ..
  "module) is held to by cosmic/test_policy_test.tl"
allowed["build.assertions.lua_assert"] = "tested directly: Lua's own `assert`, kept " ..
  "for build/assertions_test.tl to hold the counting one to, case by case, so a Lua " ..
  "upgrade that changes luaB_assert fails there rather than drifting"
allowed["build.c.layout.same"] = "tested directly: whether two layouts are one " ..
  "token stream is the rule `cosmic fix` holds a C rewrite to, and the test " ..
  "states it on sources too small to be a file"
for _, name in ipairs({ "names", "class" }) do
  allowed["build.host_names." .. name] = "tested directly: the table's own reading, which " ..
    "`parse` and `check`, the only calls outside the module, are made of"
end
allowed["build.flow.bare"] = "the subset build/workflows_test.tl holds " ..
  "workflows to takes a bare key by the same rule the layout writes one by"
allowed["build.flow.problems"] = "the subset build/workflows_test.tl holds " ..
  "the workflows to, which the layout is also held to"
allowed["build.flow.comments"] = "what the fuzz test holds a layout to keep"
for _, name in ipairs({ "parse", "render", "scalar", "from", "write", "value", "get", "set", "update" }) do
  allowed["build.flow." .. name] = "the API a program generates or edits a workflow " ..
    "through, which no program in the tree does yet; its test and the workflows' own do"
end
for _, name in ipairs({ "captures_mark", "bare_shapes" }) do
  allowed["build.check_draws." .. name] = "the checker's fuzz generators and the line " ..
    "that marks a program the checker must refuse, and the bare prologue of the shapes, which " ..
    "lang/check_flow_fuzz_test.tl and lang/check_total_fuzz_test.tl draw their inputs from"
end
for _, name in ipairs({ "pack", "unpack" }) do
  allowed["build.fuzz." .. name] = "the fuzz tests' inputs of several fields; only tests " ..
    "pack them"
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
allowed["build.test_key.sealed_meta"] = "what build/sealed_meta_test.tl holds the rows of a " ..
  "sealed database to: the value of a row its worker reads, the marker of one it does not, and a " ..
  "refusal where the process has no value to hand on"
allowed["build.reboot.carries_tree_code"] = "what build/reboot_test.tl holds to " ..
  "the modules a tree holds and the binary carries"
allowed["build.declared_key.preimage"] = "what build/declared_key_fuzz_test.tl " ..
  "holds to distinct specs spelling apart, before a key hashes it"
allowed["build.dispatch_sites.sites"] = "what build/dispatched_features_test.tl " ..
  "holds the tree's CPU dispatch sites to"
allowed["build.declared_key.dispatched"] = "what build/dispatched_features_test.tl " ..
  "holds the tree's CPU dispatch sites to: the features a key holds are the ones they read"
allowed["build.declared_key.system_sources"] = "what build/host_features_test.tl " ..
  "holds ci/testdata/host_features to: a key names each recorded host as ci/cosmic_ci/host_id.tl does"
allowed["build.declared_key.host_identity"] = "what build/declared_key_test.tl " ..
  "holds the host's identity to, the first of the `host_split` the harness keys by"
allowed["build.shared_verdicts.host_of"] = "what build/shared_verdicts_test.tl " ..
  "holds the parts a row names its host by to"
allowed["build.confine.confine"] = "a test's own declaration: " ..
  "what the processes a test starts need, which only a test makes"
allowed["build.confine.must_confine"] = "a test's own declaration: " ..
  "what the processes a test starts need, with no fallback, which only a test makes"
for _, name in ipairs({ "key", "open", "close", "look", "settle", "analyzers", "requires",
    "look_parse" }) do
  allowed["build.shared_compiles." .. name] = "tested directly: build/shared_compiles_test.tl, " ..
    "build/shared_parses_test.tl and build/importer_test.tl read and write the cache file " ..
    "itself, to see what a build shared and what a salt does to a key"
end
allowed["build.importer.analyzer_modules"] = "tested directly: the test holds the " ..
  "list to every module the analysis requires"
allowed["build.lsp.reentry"] = "tested directly: the test hands it checks that answer stale " ..
  "or fresh, since a real exec into a rebuilt tool replaces the test's own process"
allowed["build.importer.tree_code"] = "tested directly: the test holds what a " ..
  "boot names its analyzer by to what the tool it writes names it by, around a " ..
  "derive run as a boot runs it, which no binary under the suite otherwise does"
allowed["build.test_key.harness_part"] = "tested directly: build/harness_epoch_test.tl holds " ..
  "that an edit to a harness module's code moves it and one to its comments does not"
allowed["build.harness_epoch.retired"] = "every token the harness's epoch held " ..
  "before, which only its test reads: it holds the epoch's count to one past them, so " ..
  "each bump draws a token of its own"
allowed["build.harness_epoch.library"] = "the standard-library modules the harness " ..
  "may reach, each with its reason, which only its test reads: a rule the test holds " ..
  "the harness's digests to, not code the harness runs"
allowed["build.test_child.run"] = "what the chunk of `words` calls in the child, by name, from text the test " ..
  "hands `cosmic -e`: no file of the tree calls it"
allowed["build.test_inputs.lua_loads"] = "what build/lua_children_test.tl holds " ..
  "a child's `-e` to loading no more than, as the artifact a `lua` module's children " ..
  "run carries them"
allowed["build.test_inputs.standalone_loads"] = "what build/lua_standalone_test.tl " ..
  "holds a child's `--standalone` to loading no more than, beside `lua_loads`, as the " ..
  "artifact a module that requires build.standalone's children run carries them"
allow({ "build.test_key.worker_environment", "build.test_key.scratch" },
  "tested directly: the tests hand them what the running binary alone gives the runner -- " ..
    "a tree's or a fixture's modules, an environment with no startup hook of its own, a " ..
    "directory made as a worker is given one")
allowed["build.test_key.program_database"] = "tested directly: the test holds it to the ranges it reads of a file " ..
  "laid out as an artifact, which a run that seals reads only of the running program"
allowed["build.test_key.value_imports"] = "tested directly: the harness's test reads, " ..
  "by it, what each module the harness runs requires by value, as `key_code` walks it"
allowed["build.test_key.type_only_imports"] = "tested directly: the harness's test holds " ..
  "it to the edges `value_imports` leaves out; `run` reads it through the projection"
allowed["build.importer.prune_references"] = "tested directly: the test asks " ..
  "SQLite for the statement's plan, which must read `compiled` once rather " ..
  "than probe it per row, and no behaviour tells the two apart"
allowed["build.reboot.auto_boot"] = "tested directly: the test hands it an " ..
  "environment rather than setting COSMIC_AUTO_BOOT on the whole run"
allowed["build.reboot.boot_into"] = "tested directly: the test runs it on a tree " ..
  "whose bin/zig is a stand-in, which no stale tool can reach"
allow({ "build.reboot.boot_command" }, "tested directly: the test hands it each kind of tool, " ..
    "where the running one is only one of them")
allowed["build.reboot.compiler_moved"] = "tested directly: the test hands it " ..
  "identities, where a stale tool's compiler can only be had by building one"
allowed["build.reboot.rebuild_failed"] = "tested directly: the test runs it on a " ..
  "tree whose bin/zig is a stand-in, which no stale tool can reach"
allowed["build.tree.standing_of"] = "tested directly: the test hands it a tool that records no checkout, " ..
  "as a release does, which the running binary never lacks"
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
--- build found, through a `require` alias ([`build.syntax_analyzer`]) or a
--- value's checked type ([`build.syntax_receivers`]).
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
-- `refs` records how many arguments each call passes; build/c/rules.tl's
-- `declared?` and build/artifact.tl's `selected_configuration?` on `test_prefix` were found by hand.
local function unearned(db: Sqlite.Handle): {string}?, string
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
  local out: mut {string} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = row:text(1)
  end
  return out, ""
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
  local found: mut {string: boolean} = {}
  local out: mut {string} = {}
  for _, line in ipairs(lines) do
    local name = line:match(": ([^ ]+)$")
    if name ~= nil then found[name] = true end
    if name == nil or excused[name] == nil then
      out[#out + 1] = line .. ": nothing outside its module uses it but a test -- " ..
        "make it local, or name it in build/tree_checks.tl's `allowed` with why"
    end
  end
  local stale: mut {string} = {}
  for name in pairs(excused) do
    if found[name] ~= true then
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
local function returned_record(source: string): string?
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
local function record_body(source: string, record: string): string?
  local from = source:find("\nlocal record " .. record .. "%f[^%w_]")
  if from == nil then return nil end
  local to = source:find("\nend\n", from, true)
  return source:sub(from, to or #source)
end

--- Whether the returned record `record` (with `body`, its text) has the
--- type `name` as a member: `type Any = Name` or a nested declaration in
--- its body, or an assignment `record.Name = ...` beside it. Where the body
--- cannot be found the whole of `source` stands in for it.
local function member_type(source: string, record: string?, body: string?,
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
  local text: mut {string:string} = {}
  for _, row in ipairs(sources) do text[row:text(1)] = row:text(2) end
  local by_module: mut {string:Sqlite.Rows} = {}
  local order: mut {string} = {}
  for _, row in ipairs(rows) do
    if by_module[row:text(1)] == nil then
      by_module[row:text(1)] = {}
      order[#order + 1] = row:text(1)
    end
    table.insert(by_module[row:text(1)], row) -- checked: overload_none -- untyped: call
  end
  local out: mut {string} = {}
  for _, module in ipairs(order) do
    local members = assert(by_module[module], "every module of the order has its rows")
    local source = text[module] or ""
    local record = returned_record(source)
    local body = if record ~= nil then record_body(source, record) else nil end
    local tops: mut {string:Sqlite.Row} = {}
    for _, row in ipairs(members) do
      if row:text(2) ~= "" and not row:text(2):find("[.:]") and row:text(2) ~= record and
          (row:text(3) == "record" or row:text(3) == "enum" or row:text(3) == "interface" or
              row:text(3) == "type") then
        tops[row:text(2)] = row
      end
    end
    local reached: mut {string:boolean} = {}
    local pending: mut {string} = {}
    local function names_in(signature: string)
      for name in pairs(tops) do
        if reached[name] ~= true and signature:find("%f[%w_.]" .. name .. "%f[^%w_]") ~= nil then
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
    local unnamed: mut {string} = {}
    for name in pairs(reached) do
      if not member_type(source, record, body, name) then unnamed[#unnamed + 1] = name end
    end
    table.sort(unnamed)
    for _, name in ipairs(unnamed) do
      local row = assert(tops[name], "a reached name is one of the tops")
      local owner = record or module:match("[^.]+$") or module
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
--- a reader asking for `test` would also be shown the layout
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
  local all: mut {Row} = {}
  for _, r in ipairs(rows) do
    all[#all + 1] = { module = r:text(1), symbol = r:text(2), kind = r:text(3), signature = r:text(4),
      text = r:text(5), file = r:text(6), line = r:text(7) }
  end
  -- What takes or returns a value: a function, a method, or a field
  -- whose type is a function.
  local callable: mut {string} = {}
  for _, r in ipairs(all) do
    if r.kind == "function" or r.kind == "method" or
        (r.kind == "field" and r.signature:find("function", 1, true) ~= nil) then
      callable[#callable + 1] = r.signature
    end
  end
  local by_name: mut {string: mut {Row}} = {}
  local found: mut {string: boolean} = {}
  for _, owner in ipairs(all) do
    if owner.kind == "record" then
      local prefix = owner.symbol .. "."
      local fields: mut {Row} = {}
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
  local out: mut {string} = {}
  for name, list in pairs(by_name) do
    for i = 2, #list do
      local first, other = nth(list, 1), nth(list, i)
      out[#out + 1] = string.format(
        "%s:%s: %s %s and %s %s: `cosmic docs %s` answers both -- rename one",
        other.file, other.line, first.module, first.symbol, other.module, other.symbol, name)
    end
  end
  table.sort(out)
  for _, name in ipairs(expected or anchors_expected) do
    if found[name] ~= true then
      out[#out + 1] = name .. " is no longer taken for a doc anchor"
    end
  end
  return out
end

--- Whether `line` reads one of the `meta` rows `entry.keys` by its quoted
--- name, as [`Store.meta`] takes it (or a function of the module that
--- passes it on, `meta_of`); or reads a row by a name no reader can see:
--- [`Store.meta`] called with anything but a string, or with a string and
--- more (`"image_" .. rest`); or takes [`Store.meta`] as a value, in code,
--- (after an `=`, a `,` or a `(`), where an alias or a callback would read
--- any row. A declaration of the
--- function is none of these.
---
-- TODO: see a read of a row in SQL over a handle [`Store.databases`] answers,
-- which a scan of lines cannot tell from one over any other database, once
-- the checker answers which module opens a handle from the store's databases.
-- Until then the store's loud refusal ([`Store.meta`] raises for a withheld
-- row) is the backstop for a read by name; a query of the handle finds no row.
local function reads(line: string, entry: key_parts.MetaReaders): boolean
  if line:find("^%s*function ") ~= nil then return false end
  for _, name in ipairs(entry.keys) do
    for _, quote in ipairs({ '"', "'" }) do
      for _, call in ipairs({ "meta", "meta_of" }) do
        if line:find(call .. "%(%s*" .. quote .. name .. quote) ~= nil then return true end
      end
    end
  end
  if line:find("Store%.meta%(%s*[^\"'%s]") ~= nil then return true end
  if line:find("Store%.meta%(%s*[\"'][^\"']*[\"']%s*%.%.") ~= nil then return true end
  if line:find("^%s*%-%-") == nil then
    local at = 1
    while true do
      local first, last = line:find("Store%.meta", at, false)
      if first == nil or last == nil then break end
      local rest = line:sub(last + 1)
      local before = line:sub(1, first - 1)
      if rest:find("^%s*%(") == nil and rest:find("^[%w_\"'`]") == nil and
          before:find("[=,(]%s*$") ~= nil and before:find("==%s*$") == nil then
        return true
      end
      at = last + 1
    end
  end
  return false
end

--- Each module of `db` that reads a row of the group `group` of
--- [`build.key_parts`]' [`meta_readers`] (`compiler`, `image_hash`) through
--- [`Store.meta`] and `named` (by default the group's `readers` and
--- `carriers`) does not name, and then each it names that no longer reads
--- one.
---
--- A worker is given such a row only where its closure holds a reader the
--- map names ([`build.key_parts`]'s `reads_meta`): the compiler's identity
--- is answered by the running tool and held in the key of that test alone,
--- and a closure store carries `image_hash` for it alone. A reader the map
--- misses would leave a verdict standing that turned on a value no key
--- held, or be given no row.
function tree_checks.meta_readers(db: Sqlite.Handle, group: string, named?: {string}): {string}
  local entry = key_parts.meta_group(group)
  if entry == nil then
    return { group .. " is no group of build/key_parts.tl's `meta_readers`" }
  end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT path, CAST(inflate(source) AS TEXT) FROM modules ORDER BY path")
  if rows == nil then
    return { "reading the modules' sources: " .. trouble }
  end
  local found: mut {string: boolean} = {}
  for _, row in ipairs(rows) do
    for line in String.lines(row:text(2)) do
      if reads(line, entry) then
        found[row:text(1)] = true
        break
      end
    end
  end
  local listed: mut {string: boolean} = {}
  local names: mut {string} = {}
  if named ~= nil then
    for _, name in ipairs(named) do names[#names + 1] = name end
  else
    for _, name in ipairs(entry.readers) do names[#names + 1] = name end
    for _, name in ipairs(entry.carriers) do names[#names + 1] = name end
  end
  for _, name in ipairs(names) do listed[name] = true end
  local what = table.concat(entry.keys, "/")
  local missing, stale: mut {string}, mut {string} = {}, {}
  for name in pairs(found) do
    if listed[name] ~= true then
      missing[#missing + 1] = name .. " reads the meta row " .. what .. ", but " ..
        "build/key_parts.tl's `meta_readers." .. group .. "` does not name it, so no key " ..
        "of a test that runs it holds it"
    end
  end
  for name in pairs(listed) do
    if found[name] ~= true then
      stale[#stale + 1] = name .. " is named in build/key_parts.tl's " ..
        "`meta_readers." .. group .. "`, but no longer reads the meta row " .. what .. " -- remove it"
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
  local out: mut {string} = {}
  local found: mut {string: boolean} = {}
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
  local stale: mut {string} = {}
  for file in pairs(excused) do
    if found[file] ~= true then
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
  local out: mut {string} = {}
  for _, case in ipairs(cases or stand_ins_expected) do
    local query, wanted = case[1], case[2]
    if query == nil or wanted == nil then
      out[#out + 1] = "a stand-in case is the query a newcomer types and the function that stands in for it"
    else
      local found, lookup_trouble = docs.lookup(looked, query)
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
      if first ~= wanted then
        out[#out + 1] = "`cosmic docs " .. query .. "` answers " .. first .. " first, not " ..
          wanted .. " -- name the command in " .. wanted .. "'s doc comment"
      end
    end
  end
  return out
end

--- The worked examples a reader is pointed to or expected to find by a
--- compile's failure: every one [`build.error_render`] advertises, and the
--- guide to a type's shape, which no hint names but a malformed type's
--- diagnostic leaves its reader to look up.
local function queries_expected(): {string}
  local out: mut {string} = {}
  out[#out + 1] = ErrorRender.queries.arguments
  out[#out + 1] = ErrorRender.queries.record_key
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
  local out: mut {string} = {}
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

--- Each of `names` (by default [`build.contract_rules`]' `quiet_entries`), as
--- `<module> <symbol>`, that no module of `db` declares.
function tree_checks.quieted(db: Sqlite.Handle, names?: {string}): {string}
  local out: mut {string} = {}
  for _, name in ipairs(names or ContractRules.quieted_names()) do
    local module, symbol = name:match("^(%S+) (%S+)$")
    local rows, trouble = Sqlite.text_rows(db,
      "SELECT 1 FROM docs WHERE module = ?1 AND symbol = ?2 LIMIT 1",
      { { text = module or "" }, { text = symbol or "" } })
    if rows == nil then
      return { "reading the docs: " .. trouble }
    end
    if #rows == 0 then
      out[#out + 1] = name .. " is quieted in build/contract_rules.tl, but no module " ..
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
--- ...`; by default also each module that requires one only a few may
--- ([`tree_checks.requirers`]).
function tree_checks.restricted(db: Sqlite.Handle, rules?: {string: Restriction}): {string}
  local out: mut {string} = {}
  local names: mut {string} = {}
  for name in pairs(rules or restricted) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local rule = assert((rules or restricted)[name], "a name listed is one of the rules")
    local module, symbol = name:match("^(%S+) (%S+)$")
    local rows, trouble = Sqlite.text_rows(db,
      "SELECT from_file, line FROM uses WHERE module = ?1 AND symbol = ?2 " ..
        "ORDER BY from_file, line",
      { { text = module or "" }, { text = symbol or "" } })
    if rows == nil then
      return { "reading the uses: " .. trouble }
    end
    local allowed_here: mut {string: boolean} = {}
    for _, file in ipairs(rule.files) do allowed_here[file] = true end
    for _, row in ipairs(rows) do
      if allowed_here[row:text(1)] ~= true then
        out[#out + 1] = row:text(1) .. ":" .. row:text(2) .. ": " .. name .. " is used outside " ..
          table.concat(rule.files, ", ") .. ": " .. rule.why
      end
    end
  end
  if rules == nil then
    for _, line in ipairs(tree_checks.requirers(db)) do out[#out + 1] = line end
  end
  return out
end

--- The modules only a few may require, by module: the loader of a module by a name got at run time is no edge of the
--- build, so a module that holds it can load what no key, closure or carried program holds. Who may require it, not who
--- calls it, is what is kept, so an alias of it in another module matters nothing.
local requirers: {string: Restriction} = {
  ["build.load_module"] = {
    files = { "build.dispatch", "build.test_worker", "build.load_module_test" },
    why = "only the tool's entry and the test worker load a module by a name they get at run " ..
      "time, which is no edge of the build: any other module requires what it needs by a " ..
      "literal name, `require(\"cosmic.fs\")`, or picks from a table of such requires",
  },
  ["cosmic.internal.globals"] = {
    files = { "build.fuzz", "build.load_module",
      "build.sandbox", "build.sealed_worker_test", "build.standalone",
      "build.test_closure_diagnostic_test", "build.test_closure_test", "build.test_worker_test", "build.type_watch", "core.load_env_test", "core.surface_test",
      "cosmic.coverage_test", "cosmic.flags_test", "test.coverage_cache_test" },
    why = "only the modules that run a program or a hook as a chunk of Lua text take the globals whole, as its " ..
      "environment: it holds `require`, which a chunk loads modules the build does not see by; any other module " ..
      "passes the chunk the few names it needs",
  },
}

--- Each module of `db` (by its `decl_imports`, which hold a core module's name too) that requires a module of `rules` (by default [`requirers`]) and is not one that rule names, as
--- `<module>: requires <name>, which only <modules> may require: <why>`.
function tree_checks.requirers(db: Sqlite.Handle, rules?: {string: Restriction}): {string}
  local out: mut {string} = {}
  for name, rule in pairs(rules or requirers) do
    local rows, trouble = Sqlite.text_rows(db,
      "SELECT path FROM decl_imports WHERE requires = ?1 ORDER BY path", { { text = name } })
    if rows == nil then
      return { "reading the imports: " .. trouble }
    end
    local allowed_here: mut {string: boolean} = {}
    for _, module in ipairs(rule.files) do allowed_here[module] = true end
    for _, row in ipairs(rows) do
      if allowed_here[row:text(1)] ~= true then
        out[#out + 1] = row:text(1) .. ": requires " .. name .. ", which only " .. table.concat(rule.files, ", ") ..
          " may require: " .. rule.why
      end
    end
  end
  table.sort(out)
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
  local declared: mut {string:boolean} = {}
  for _, row in ipairs(rows) do declared[row:text(1)] = true end
  local out: mut {string} = {}
  for _, row in ipairs(rows) do
    for _, name in ipairs(closure_store.required_by(row:text(2))) do
      if declared[name] ~= true then
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
function tree_checks.requirements(build: Sqlite.Handle): {string:{string}}?, string
  local rows, trouble = Sqlite.text_rows(build,
    "SELECT i.path, t.value FROM test_inputs t JOIN inputs i ON i.source_hash = t.source_hash " ..
      "WHERE t.field = 'requires' ORDER BY i.path, t.ordinal")
  if rows == nil then return nil, "reading the declared requirements: " .. trouble end
  local out: mut {string:mut {string}} = {}
  for _, row in ipairs(rows) do
    local names = out[row:text(1)] or {}
    out[row:text(1)] = names
    local second = row:text(2)
    names[#names + 1] = second
  end
  return out, ""
end

--- The test modules that run a program the portable launcher starts, or
--- open the store, or require a portable host, by the module's path:
--- the ones whose key holds the launcher, as the working database `build`
--- (`build.db`) holds their declarations. Every other worker runs
--- sealed ([`build.test_key`]'s `seals`).
--- @param build the working database
--- @return the module paths, as a set
function tree_checks.unsealed(build: Sqlite.Handle): {string:boolean}?, string
  local rows, trouble = Sqlite.text_rows(build,
    "SELECT DISTINCT i.path FROM test_inputs t JOIN inputs i ON i.source_hash = t.source_hash " ..
      "WHERE t.field IN ('tool', 'store') OR (t.field = 'requires' AND t.value = 'portable')")
  if rows == nil then return nil, "reading the unsealed modules: " .. trouble end
  local out: mut {string:boolean} = {}
  for _, row in ipairs(rows) do out[row:text(1)] = true end
  return out, ""
end

--- The sealed test modules that name the portable launcher's contract
--- -- `COSMIC_PORTABLE_*` or the `--artifact` argument -- though their
--- worker never sees it, each with the reason it is no reader of it.
--- Every other one is a finding of [`sealed_launch`].
local launcher_allowed: mut {string: string} = {}
launcher_allowed["build.caches_test"] = "names COSMIC_PORTABLE_CACHE as a key of the " ..
  "environment it hands a pure function of the cache variables"
launcher_allowed["build.c.rules_test"] = "names COSMIC_PORTABLE_CACHE in the environment it hands " ..
  "c.own_caches, a pure function, and reads none from its own process"
launcher_allowed["build.declared_key_test"] = "names COSMIC_PORTABLE_CACHE as a variable of the " ..
  "environment a spec it keys holds, and reads none from its own process"
launcher_allowed["build.launcher_test"] = "renders the launcher's text with build.launcher and runs " ..
  "it in a child of its own, with COSMIC_PORTABLE_TEST_CPUINFO named in the child's environment"
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
  local out: mut {string} = {}
  local seen: mut {string: boolean} = {}
  for _, row in ipairs(rows) do
    local named = false
    for line in String.lines(row:text(2)) do
      if line:find("^%s*%-%-") == nil and
          (line:find("COSMIC_PORTABLE_", 1, true) ~= nil or line:find('"--artifact', 1, true) ~= nil) then
        named = true
        break
      end
    end
    if named and unsealed[row:text(1)] ~= true then
      seen[row:text(1)] = true
      if allowed_here[row:text(1)] == nil then
        out[#out + 1] = row:text(1) .. " names the portable launcher's contract, but its worker runs " ..
          "sealed and never sees the launcher: declare `tool` or `store`, or " ..
          "`requires = { \"portable\" }`, or excuse it in build/tree_checks.tl's `launcher_allowed`"
      end
    end
  end
  local stale: mut {string} = {}
  for name in pairs(allowed_here) do
    if seen[name] ~= true then
      stale[#stale + 1] = name .. " is excused in build/tree_checks.tl's `launcher_allowed`, but " ..
        "no longer names the portable launcher's contract in a sealed test -- remove it"
    end
  end
  table.sort(stale)
  for _, line in ipairs(stale) do out[#out + 1] = line end
  return out
end

--- What ci/cosmic_ci/capabilities.json holds.
local record Capabilities
  legs: {string:{string}}
end

local CAPABILITIES <const>: Shape.Typed<Capabilities> = Shape.record_of("Capabilities")

--- The requirements each CI leg promises, as ci/cosmic_ci/capabilities.json
--- under `root` lists them. ci is a tree of its own, whose modules the
--- tree cannot require: the file is JSON, read alone.
--- @param root the tree's root
--- @return the names a leg promises, by the leg's name
function tree_checks.legs(root: string): {string:{string}}?, string
  local path = root .. "/ci/cosmic_ci/capabilities.json"
  local text, read_trouble = Fs.read(path)
  if text == nil then return nil, read_trouble end
  local capabilities, shape_trouble = Shape.decode_into(text, CAPABILITIES.spec)
  if capabilities == nil then return nil, path .. ": " .. shape_trouble end
  return capabilities.legs, ""
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
  local out: mut {string} = {}
  local leg_names: mut {string} = {}
  for leg in pairs(legs) do leg_names[#leg_names + 1] = leg end
  table.sort(leg_names)
  local all: mut {string} = {}
  for _, leg in ipairs(leg_names) do
    for _, name in ipairs(lookup_in(legs, leg)) do
      local spec, why = host_names.parse(name)
      if spec == nil then
        out[#out + 1] = string.format("leg %s promises %q, which is refused: %s", leg, name, why)
      else
        all[#all + 1] = name
      end
    end
  end
  local modules: mut {string} = {}
  for module in pairs(declared) do modules[#modules + 1] = module end
  table.sort(modules)
  for _, module in ipairs(modules) do
    for _, name in ipairs(lookup_in(declared, module)) do
      if not host_names.promised(all, name) then
        out[#out + 1] = string.format("%s requires %s, which no CI leg promises " ..
            "(ci/cosmic_ci/capabilities.json): it would be n/a or skipped on every leg and run " ..
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
---
--- The tree is compiled with the new checker, as `cosmic test` compiles it.
function tree_checks.projection(root: string, standing: tree_standing.Standing): Sqlite.Handle?, string
  local handle, open_trouble = work.open(root, nil, "fix")
  if handle == nil then
    return nil, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, standing)
  if staged == nil then
    local _, _ = work.close(handle)
    return nil, stage_trouble
  end
  local result, compile_trouble = importer.compile(handle,
    GrammarMode.tool(Store.meta("compiler") or ""), false, shared_compiles.for_build())
  if result == nil then
    local _, _ = work.close(handle)
    return nil, compile_trouble
  end
  local refused = result.refused
  if #refused > 0 then
    local _, _ = work.close(handle)
    return nil, "the tree does not build:\n" .. refusals.text(refused, result.refusal_roots or {})
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
  strings: mut {string:string}
  lists: mut {string:{string}}
  nonliteral: mut {string:boolean}
end

--- The value of the string literal that opens at `at` (a quote) and the
--- index after its closing quote.
local function scan_string(text: string, at: integer): string, integer
  local quote = text:sub(at, at)
  local named: {string:string} = { n = "\n", t = "\t" }
  local out: mut {string} = {}
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
  local out: mut {Token} = {}
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
      local level = assert(text:match("^%[(=*)%[", i), "the branch tested this pattern")
      local close = text:find("]" .. level .. "]", i, true)
      out[#out + 1] = { kind = "long", value = "" }
      i = if close ~= nil then close + #level + 2 else #text + 1 end
    elseif c:match("[%a_]") then
      local word = assert(text:match("^[%w_]+", i), "the branch tested a character this pattern starts with")
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
    local token = nth(tokens, i)
    local after, third = tokens[i + 1], tokens[i + 2]
    if token.kind == "mark" and token.value == "{" then
      depth = depth + 1
    elseif token.kind == "mark" and token.value == "}" then
      depth = depth - 1
    elseif depth == 1 and token.kind == "word" and after ~= nil and
        after.value == "=" and after.kind == "mark" and
        third ~= nil and third.value ~= "=" then
      local name, value = token.value, third
      if value.kind == "str" then
        if fields.strings[name] == nil then fields.strings[name] = value.value end
        i = i + 2
      elseif value.kind == "mark" and value.value == "{" then
        local list: mut {string} = {}
        local j = i + 3
        local item = tokens[j]
        while item ~= nil and not (item.kind == "mark" and item.value == "}") do
          if item.kind == "str" then
            list[#list + 1] = item.value
          elseif not (item.kind == "mark" and (item.value == "," or item.value == ";")) then
            fields.nonliteral[name] = true
          end
          j = j + 1
          item = tokens[j]
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
function tree_checks.verbs(db: Sqlite.Handle, quickstart: string?): {string}
  local out: mut {string} = {}
  local required, trouble = Sqlite.text_rows(db,
    "SELECT requires FROM imports WHERE path = 'build.verb_list'")
  if required == nil then
    return { "reading the imports: " .. trouble }
  end
  local listed: mut {string:boolean} = {}
  for _, row in ipairs(required) do listed[row:text(1)] = true end
  local modules, module_trouble = Sqlite.text_rows(db,
    "SELECT path, kind, CAST(inflate(source) AS TEXT) FROM modules ORDER BY path")
  if modules == nil then
    return { "reading the modules: " .. module_trouble }
  end
  local kinds: mut {string:string} = {}
  local texts: mut {string:string} = {}
  for _, row in ipairs(modules) do
    kinds[row:text(1)] = row:text(2)
    texts[row:text(1)] = row:text(3)
  end

  -- Each `## ` heading of the quickstart, outside a fenced block, and the
  -- text of its section.
  local sections: mut {string:string} = {}
  local current: string? = nil
  local fenced = false
  for line in String.lines(quickstart or "") do
    if line:match("^```") then fenced = not fenced end
    local heading = if not fenced then line:match("^## (.+)$") else nil end
    if heading ~= nil then
      current = heading
      sections[heading] = sections[heading] or ""
    elseif current ~= nil then
      sections[current] = (sections[current] or "") .. line .. "\n"
    end
  end

  -- The spec each listed entry loads, `require("<module>").<field>`, so a
  -- listed verb whose spec cannot be read is not passed over.
  local expected: mut {string:{string}} = {}
  for entry_module, field in (texts["build.verb_list"] or ""):gmatch(
      "require%(\"([%w_.]+)\"%)%.([%w_]*spec)") do
    expected[entry_module] = expected[entry_module] or {}
    table.insert(expected[entry_module], field) -- checked: overload_none -- untyped: call
  end
  local found_fields: mut {string:mut {string:boolean}} = {}

  for _, row in ipairs(modules) do
    if row:text(2) ~= "test" then
      local assigned = 0
      local at = 1
      while true do
        local first, last, field = row:text(3):find("\n[%w_]+%.([%w_]*spec) = {", at)
        if first == nil or last == nil or field == nil then break end
        at = last + 1
        if field == "spec" or field:match("^[%w_]*_spec$") ~= nil then
          assigned = assigned + 1
          local own_fields = found_fields[row:text(1)] or {}
          found_fields[row:text(1)] = own_fields
          own_fields[field] = true
          local spec = spec_fields(row:text(3), last)
          local name = spec.strings.name or "?" -- checked: map_field
          if listed[row:text(1)] ~= true then
            out[#out + 1] = "`" .. name .. "` (" .. row:text(1) .. ") assigns a `spec` but " ..
              "build/verb_list.tl does not list its module, so no verb dispatches to it -- " ..
              "list it there"
          end
          local guide = spec.strings.guide -- checked: map_field
          if guide == nil then
            out[#out + 1] = "`" .. name .. "` has no guide as a string literal: name its `## ` " ..
              "heading in doc/guides/quickstart.md, or \"none: <why>\""
          elseif guide:sub(1, 5) == "none:" then -- untyped: call
            if guide:sub(6):match("^%s*$") then -- untyped: call*2
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
          local tests = spec.lists.tests -- checked: map_field
          if tests == nil or #tests == 0 or spec.nonliteral.tests then -- checked: map_field
            out[#out + 1] = "`" .. name .. "` names no test module in `tests`, as string literals"
          end
          for _, test in ipairs(tests or {}) do -- checked: literal_needs_type
            if kinds[test] ~= "test" then
              out[#out + 1] = "`" .. name .. "`'s tests name " .. test ..
                ", which is no test module of the tree"
            end
          end
        end
      end
    end
  end
  local unread: mut {string} = {}
  for entry_module, fields in pairs(expected) do
    for _, field in ipairs(fields) do
      if (found_fields[entry_module] or {})[field] ~= true then
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

--- The public doc text that may cite an implementation path, by
--- `<module> <symbol> <rule>` (`doc_rules`' name; `(module)` for a
--- module's own doc), and why each stays.
local doc_exempt: mut {string: string} = {}

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
  if name ~= nil and FILE_NAMES[name] == true then return false end
  while name ~= nil and name ~= "" do
    if modules["build." .. name] == true then return true end
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
  local modules: mut {string: boolean} = {}
  for _, row in ipairs(names) do modules[row:text(1)] = true end
  local out: mut {string} = {}
  local found: mut {string: boolean} = {}
  for _, row in ipairs(rows) do
    local text = " " .. link_text.unlinked(row:text(3)) .. " "
    local seen: mut {string: boolean} = {}
    for _, rule in ipairs(doc_rules) do
      local at = 1
      while true do
        local from, to = text:find(rule.pattern, at)
        if from == nil or to == nil then break end
        at = to + 1
        local hit = text:sub(from, to)
        -- The whole word around the match, for the finding.
        local start, stop = from, to
        while start > 1 and not text:sub(start - 1, start - 1):match("%s") do start = start - 1 end
        while stop < #text and not text:sub(stop + 1, stop + 1):match("%s") do stop = stop + 1 end
        local word = text:sub(start, stop)
        local before, after = text:sub(from - 1, from - 1), text:sub(to + 1, to + 1)
        if rule.breaks(before, hit, after, modules) then
          local key = row:text(1) .. " " .. (if row:text(2) ~= "" then row:text(2) else "(module)" end) .. " " .. rule.name
          found[key] = true
          if excused[key] == nil and seen[word] ~= true then
            seen[word] = true
            out[#out + 1] = row:text(4) .. ":" .. row:text(5) .. ": " .. row:text(1) .. " " ..
              (if row:text(2) ~= "" then row:text(2) else "(module)" end) .. ": its doc text has `" .. word ..
              "` (" .. rule.name .. " rule) -- " .. rule.fix
          end
        end
      end
    end
  end
  local stale: mut {string} = {}
  for key in pairs(excused) do
    if found[key] ~= true then
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
local plural_exempt: mut {string: string} = {}

plural_exempt["build/vendor.tl:files"] = "runs on the bootstrap release " ..
  "(bin/vendor), which cannot require build.plural"
plural_exempt["build/confine.tl:paths"] = "a count above the unveil limit, so never 1; " ..
  "every worker loads build.confine, and none loads build.plural"
plural_exempt["build/fetch.tl:digests"] = "\"name different sha256 digests\": two differ, so never 1"
plural_exempt["build/test.tl:seconds"] = "the limit is math.maxinteger // 1000, never 1"
plural_exempt["build/test_key.tl:tables"] = "a label before its value (\"tables <digest>\"), not a count"
plural_exempt["cosmic/net.tl:bytes"] = "SOCKET_NAME_MAX is the platform's sun_path size, never 1"
plural_exempt["build/patch.tl:matches"] = "runs on the bootstrap release " ..
  "(bin/vendor applies patches), which cannot require build.plural"
plural_exempt["build/zig_fetch.tl:attempts"] = "runs on the bootstrap release " ..
  "(bin/zig), which cannot require build.plural"

--- [`PluralSites.of_chunk`] of `source`, parsed as the new checker reads it.
local function plural_sites(source: string, file: string): {{string}}?, string
  local chunk, trouble = SyntaxNode.parse(source, file)
  if chunk == nil then return nil, trouble end
  return PluralSites.of_chunk(chunk), ""
end

--- Whether the plural check reads `file`, a path from the tree's root: a Teal source under `build/`, `cmd/`, `cosmic/` or
--- `ci/cosmic_ci/` that is no test or declaration file.
local function plural_file(file: string): boolean
  return file:match("%.tl$") ~= nil and file:match("_test%.tl$") == nil and file:match("%.d%.tl$") == nil and
    (file:match("^build/") ~= nil or file:match("^cmd/") ~= nil or file:match("^cosmic/") ~= nil or
      file:match("^ci/cosmic_ci/") ~= nil)
end

--- What [`plurals`] finds in `source`, the text of `file` (its path from the tree's root), parsed here so that the checks
--- need not parse it again; nil for a file they do not read, and for one that cannot be read, which [`plurals`] then says.
function tree_checks.plurals_in(file: string, source: string): tree_checks.Plurals?
  if not plural_file(file) then return nil end
  local sites, _ = plural_sites(source, file)
  if sites == nil then return nil end
  return { source = source, sites = sites }
end

--- Every place in the Teal sources under `build/`, `cmd/` and
--- `cosmic/` of `db` (a test's excepted), and in `extra` (`{file,
--- source}` pairs, [`ci_sources`]'s), that puts a literal plural noun
--- after a number, as `<file>:<line>: ...` with the fix, and then each
--- name in `excused` (by default `plural_exempt`) that nothing answers
--- to any more.
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
function tree_checks.plurals(db: Sqlite.Handle, extra?: {{string}}, excused?: {string: string},
                             read?: {string: tree_checks.Plurals}): {string}
  excused = excused or plural_exempt
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT file, CAST(inflate(source) AS TEXT) FROM modules WHERE kind <> 'test' " ..
      "AND file GLOB '*.tl' AND file NOT GLOB '*.d.tl' AND (file GLOB 'build/*' " ..
      "OR file GLOB 'cmd/*' OR file GLOB 'cosmic/*') ORDER BY file")
  if rows == nil then
    return { "reading the sources: " .. trouble }
  end
  local sources: mut {{string}} = {}
  for _, row in ipairs(rows) do sources[#sources + 1] = { row:text(1), row:text(2) } end
  for _, row in ipairs(extra or {}) do sources[#sources + 1] = row end
  local out: mut {string} = {}
  local found: mut {string: boolean} = {}
  for _, row in ipairs(sources) do
    local file_name, source_text = row[1], row[2]
    local kept = if read ~= nil and file_name ~= nil then read[file_name] else nil end
    local sites: {{string}}?
    local parse_trouble: string?
    if file_name == nil or source_text == nil then
      out[#out + 1] = "a source to check for plurals is a file's path and its text"
      sites = {}
    elseif kept ~= nil and kept.source == source_text then
      sites = kept.sites
    else
      sites, parse_trouble = plural_sites(source_text, file_name)
    end
    if sites == nil then
      out[#out + 1] = (file_name or "?") .. ": cannot read it to check its plurals: " .. (parse_trouble or "")
    else
      for _, site in ipairs(sites) do
        local line, noun, literal, fix = site[1], site[2], site[3], site[4]
        if file_name ~= nil and line ~= nil and noun ~= nil and literal ~= nil and fix ~= nil then
          local key = file_name .. ":" .. noun
          found[key] = true
          if excused[key] == nil then
            out[#out + 1] = file_name .. ":" .. line .. ": `" .. literal ..
              "` puts the literal plural `" .. noun .. "` after a number, which reads \"1 " ..
              noun .. "\" -- " .. fix
          end
        end
      end
    end
  end
  local stale: mut {string} = {}
  for key in pairs(excused) do
    if found[key] ~= true then
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
  local out: mut {{string}} = {}
  local listed, _ = Fs.walk(root .. "/ci/cosmic_ci")
  for _, name in ipairs(listed or {}) do
    if name:match("%.tl$") ~= nil and name:match("_test%.tl$") == nil then
      local text, _ = Fs.read(root .. "/ci/cosmic_ci/" .. name)
      if text ~= nil then out[#out + 1] = { "ci/cosmic_ci/" .. name, text } end
    end
  end
  table.sort(out, function(a: {string}, b: {string}): boolean return nth(a, 1) < nth(b, 1) end)
  return out
end

--- The sink of `marking`, if it has one.
local function sink_of(marking: Ceilings.Marking?): Ceilings.Sink?
  if marking == nil then
    return nil
  end
  return marking.sink
end

--- The lines that tell what `judged`, the markers of `file` against its findings, found: the findings no marker holds, then
--- each marker that holds what the line lacks, which `cosmic fix` removes. They go to `sink` as well, where it is given.
local function told_marks(file: string, judged: Ceilings.Judged, sink: Ceilings.Sink?): {string}
  local told: mut {string} = {}
  for _, line in ipairs(judged.lines) do
    told[#told + 1] = line
  end
  -- A caller that mends the stale markers does not tell them.
  if sink == nil or sink.mend ~= true then
    for _, spot in ipairs(judged.stale) do
      local line = file .. ":" .. tostring(spot.line) .. ": its marker holds " .. String.counted(spot.count, "finding") ..
        " of " .. spot.code .. " that the line no longer has; `cosmic fix` removes the marker"
      told[#told + 1] = line
    end
  end
  if sink ~= nil then
    for _, spot in ipairs(judged.unmarked) do
      sink.unmarked[#sink.unmarked + 1] = spot
    end
    for _, spot in ipairs(judged.stale) do
      sink.stale[#sink.stale + 1] = spot
    end
  end
  return told
end

--- Whether `line`, a finding of the new checker, is a warning of an unused name: it ends its message with the code.
local function unused_warning(line: string): boolean
  for _, code in ipairs(Warnings.codes) do
    if Warnings.kind_of(code) == "unused" and line:find("(" .. code .. "): ", 1, true) ~= nil then
      return true
    end
  end
  return false
end

--- The Teal under `ci/testdata` that fails to type-check in the new checker ([`build.pipeline`]), one line per complaint.
--- No leg runs these with `--standalone`: they are copied into fixture directories and run there, `cmd/*/main.tl` as
--- modules of a project the candidate builds, `retained_probe.tl` and `work_db_integrity.tl` as files, and
--- `runtime_test.tl` by `cosmic test`. Each requires `cosmic.*` modules alone and is held to a build's own strictness,
--- which a file alone is checked under ([`Pipeline.alone`]: the declarations the tool carries, and no marker), so a
--- refusal that would otherwise be met only when a leg runs it is met here; `cosmic fix --check` in `ci/` only parses
--- them. Each is read as written, and every finding of the checker is told: no marker or count holds one. A test module's
--- unused functions are no complaint (a test runner calls them); any other file's unused locals are.
function tree_checks.ci_testdata(root: string): {string}
  local out: mut {string} = {}
  local options, options_trouble = Pipeline.alone()
  if options == nil then return { options_trouble } end
  local listed, _ = Fs.walk(root .. "/ci/testdata")
  local names: mut {string} = {}
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
      -- Checked under its path below `ci/testdata`, which the build leaves out of a tree as no module of it (any
      -- `testdata/` directory), and told under its own.
      local testy = name:match("_test%.tl$") ~= nil
      local made = Pipeline.checked_alone(name, source, options, testy)
      local findings: mut {Ceilings.Finding} = {}
      local codes: mut {string} = {}
      local seen: mut {string: boolean} = {}
      for _, line in ipairs(made.lines) do
        if not (testy and unused_warning(line)) then
          local y, x, msg, code, fix = line:match("^[^:]+:(%d+):(%d+): (.-) %(([%a_]+)%): (.*)$")
          if code == nil or msg == nil or fix == nil then
            -- The checker's own count of a code ("2 errors of x in its bodies") is told again, by the markers, below.
            -- TODO: take the findings of [`Pipeline.checked_alone`] as the spots of [`build.ceilings.marked`] and not parse its
            -- prose here, once it answers them beside its lines; a changed wording tells a count twice, which fails closed.
            if line:match("^[^:]+: %d+ errors? of [%a_]+ in its %a+ on line %d+; follow the fix above$") == nil then
              out[#out + 1] = if line:sub(1, #name + 1) == name .. ":" then file .. line:sub(#name + 1) else line end
            end
          else
            findings[#findings + 1] = { code = code, y = math.tointeger(tonumber(y)) or 0,
              x = math.tointeger(tonumber(x)) or 0, msg = msg, fix = fix }
            if seen[code] ~= true then
              seen[code] = true
              codes[#codes + 1] = code
            end
          end
        end
      end
      for _, line in ipairs(Ceilings.marked("checked", file, "", findings, codes, "bodies", true).lines) do
        out[#out + 1] = line
      end
      if made.code == nil and #made.lines == 0 then
        out[#out + 1] = file .. ": the compiler refused it"
      end
    end
  end
  return out
end

--- Every `.tl` file under `root` as `{file, source}` pairs, read from disk: the modules and tests, the declaration files
--- of a tree. The projection is not read, as it holds no declaration file. `vendor/`, the hidden directories,
--- `o/` (never read) and `ci/` hold none the tree owns: `ci/` is a project of its own, whose modules are named from its own
--- root and checked there (`cosmic fix --check` run in `ci/`, which build/ci_check_test.tl runs). The declarations of the globals ([`lang/prelude.d.tl`],
--- [`lang/stdlib.d.tl`]) are left out: they are the globals of every build ([`build.tree_program`]), no module of it.
local function sources_of(root: string): {{string}}?, string
  local listed, trouble = Fs.walk(root, function(relative: string, name: string, kind: Fs.Kind): boolean
    return kind == "dir" and (name:sub(1, 1) == "." or relative == "vendor" or relative == "o" or
      identity.is_foreign_tree(relative))
  end)
  if listed == nil then
    return nil, trouble
  end
  local out: mut {{string}} = {}
  for _, file in ipairs(listed) do
    if file:match("%.tl$") ~= nil and file ~= "lang/prelude.d.tl" and file ~= "lang/stdlib.d.tl" then
      local text, read_trouble = Fs.read(root .. "/" .. file)
      if text == nil then
        return nil, read_trouble
      end
      out[#out + 1] = { file, text }
    end
  end
  return out, ""
end

--- What scoping one file found.
local record ScopeOutcome
  --- Why the scopes are not consistent with the tree ([`lang.scopes_cover`]), "" where they are.
  mut consistent: string
  errors: mut {Scopes.Error}
end

--- The scope builder's codes by name.
local scope_codes: mut {string: Scopes.Code} = {}
for _, code in ipairs(Scopes.codes) do
  scope_codes[code] = code
end

--- The outcome a memo kept, or nil where it kept none or it does not read.
local function kept_scopes(text: string, file: string): ScopeOutcome?
  local outcome: ScopeOutcome = { consistent = "", errors = {} }
  for _, fields in ipairs(check_memo.decode(text)) do
    local consistent = fields[2]
    if fields[1] == "C" and #fields == 2 and consistent ~= nil then
      outcome.consistent = consistent
    elseif fields[1] == "E" and #fields == 6 then
      local code_name, msg, fix = fields[2], fields[5], fields[6]
      local code = scope_codes[code_name]
      local y, x = math.tointeger(tonumber(fields[3])), math.tointeger(tonumber(fields[4]))
      if code == nil or y == nil or x == nil then
        return nil
      end
      outcome.errors[#outcome.errors + 1] = {
        filename = file, code = code, y = y, x = x, offset = 0, length = 0, msg = msg, fix = fix,
      }
    else
      return nil
    end
  end
  return outcome
end

--- The outcome of scoping `source`, from `memo` where it holds it under `salt`.
local function scope_outcome(file: string, source: string, declared: {string: Scopes.Global}, memo: Sqlite.Handle?,
                             salt: string): ScopeOutcome
  local dialect: Ast.Dialect = if file:match("%.d%.tl$") then "decl" else "tl" end
  local key = ""
  if memo ~= nil then
    key = check_memo.key(salt, dialect, source)
    local text = check_memo.get(memo, "scoped", key)
    local kept = if text ~= nil then kept_scopes(text, file) else nil end
    if kept ~= nil then
      return kept
    end
  end
  local parsed = Parser.parse(Lexer.lex(source, file), file, dialect)
  local scoped = Scopes.build(parsed.chunk, file, declared)
  local ok, reason = ScopesCover.check(parsed.chunk, scoped, declared)
  local outcome: ScopeOutcome = { consistent = if ok then "" else reason end, errors = scoped.errors } -- checked: view_as_mut
  if memo ~= nil then
    local rows: mut {{string}} = { { "C", outcome.consistent } }
    for _, e in ipairs(scoped.errors) do
      rows[#rows + 1] = { "E", e.code, tostring(e.y), tostring(e.x), e.msg, e.fix }
    end
    check_memo.put(memo, "scoped", key, check_memo.encode(rows))
  end
  return outcome
end

--- What [`tree_checks.share_checks`] read of the tool, inside [`Store.alone`].
local record Coded
  mut code: string?
  mut trouble: string
end

--- Shares the rows of this process's memoed checks with the host's other checkouts ([`build.check_memo`]), under the
--- code this tool checks with: the bytecode of the modules `cosmic fix` loads, read from the tool's own database and
--- not a projection attached ahead of it, and every byte of the tool ahead of that database. Answers whether they are
--- shared, and why not where the tool could not be read or the shared file not opened; a run that shares none by
--- its environment answers false and "".
function tree_checks.share_checks(): boolean, string
  local path = check_memo.shared_path()
  if path == nil then return check_memo.share(nil) end
  local head, head_trouble = artifact.trusted_prefix()
  if head == nil then
    local _, _ = check_memo.share(nil)
    return false, head_trouble
  end
  local core = Hash.hex_sha256(head)
  local coded: Coded = { code = nil, trouble = "" }
  Store.alone(function()
    coded.code, coded.trouble = check_memo.code_of({ requires = Store.requires, bytecode = Store.bytecode,
      holds = Store.holds, core = core })
  end)
  local code = coded.code
  if code == nil then
    local _, _ = check_memo.share(nil)
    return false, coded.trouble
  end
  return check_memo.share(path, { code = code })
end

--- Every `.tl` file of the tree, scoped ([`lang.scopes`]) in the new checker's grammar: the names it resolves must agree
--- with the tree ([`lang.scopes_cover`]), and its errors are the ones its markers hold ([`build.ceilings`]), no more: an error
--- with no marker on its line is listed with its place and fix, and a marker that holds more than its line has is stale.
--- The sources are the `.tl` files under `root` ([`sources_of`]).
function tree_checks.scoped(root: string, memo?: Sqlite.Handle, marking?: Ceilings.Marking): {string}
  local files, trouble = sources_of(root)
  if files == nil then
    return { "reading the sources: " .. trouble }
  end
  local out: mut {string} = {}
  local given = TreeProgram.tree_globals(root)
  local declared = Driver.globals(given.sources, given.adjust)
  local salt = check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl",
    "lang/scopes_cover.tl", "lang/truthy.tl", "lang/prelude.d.tl", "lang/stdlib.d.tl",
    "build/check_memo.tl", "build/driver.tl", "build/tree_checks.tl", "build/tree_program.tl" },
    "scoped 4")
  if memo ~= nil then
    local _, _ = check_memo.prepare(memo, "scoped")
  end
  for _, row in ipairs(files) do
    local file, source = nth(row, 1), nth(row, 2)
    local outcome = scope_outcome(file, source, declared, memo, salt)
    if outcome.consistent ~= "" then
      out[#out + 1] = file .. ": its scopes are not consistent with its tree: " .. outcome.consistent
    end
    local findings: mut {Ceilings.Finding} = {}
    for _, e in ipairs(outcome.errors) do
      findings[#findings + 1] = { code = e.code, y = e.y, x = e.x, msg = e.msg, fix = e.fix }
    end
    for _, line in ipairs(told_marks(file, Ceilings.marked("scoped", file, source, findings, Scopes.codes, "scopes"),
        sink_of(marking))) do
      out[#out + 1] = line
    end
  end
  if memo ~= nil then
    check_memo.finish(memo, "scoped")
  end
  return out
end

--- An error of the new checker's lowering or checking of a file, as a check lists it.
local type Finding = Ceilings.Finding

--- What lowering or checking one file found: its errors.
local record DeclareOutcome
  errors: mut {Finding}
  --- Whether the stage could not judge the file (it does not parse, or the stage does not check that kind of file): its
  --- markers are neither held nor stale, and are left as they are.
  mut unjudged?: boolean
end

--- The outcome a memo kept, or nil where it kept none or it does not read; a code is read only if it is one of `codes`.
local function kept_findings(text: string, codes: {string}): DeclareOutcome?
  local known: mut {string: boolean} = {}
  for _, code in ipairs(codes) do
    known[code] = true
  end
  local outcome: DeclareOutcome = { errors = {} }
  for _, fields in ipairs(check_memo.decode(text)) do
    local code, msg, fix = fields[2], fields[5], fields[6]
    if fields[1] == "E" and #fields == 6 then
      local y, x = math.tointeger(tonumber(fields[3])), math.tointeger(tonumber(fields[4]))
      if code == nil or msg == nil or fix == nil or known[code] ~= true or y == nil or x == nil then
        return nil
      end
      outcome.errors[#outcome.errors + 1] = { code = code, y = y, x = x, msg = msg, fix = fix }
    elseif fields[1] == "U" then
      outcome.unjudged = true
    elseif fields[1] ~= "N" then
      return nil
    end
  end
  return outcome
end

local function kept_declarations(text: string, _file: string): DeclareOutcome?
  return kept_findings(text, Declarations.codes)
end

--- What a memo holds for an outcome.
local function kept_rows(outcome: DeclareOutcome): {{string}}
  local kept: mut {{string}} = { { if outcome.unjudged == true then "U" else "N" end } }
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
  mut key: string
end

--- The modules a source requires by a literal name, as `require("m")` or `pcall(require, "m")`: the parser's own
--- reading of the file `file`. A file that does not parse is read by its text, a name in a comment or a string counting
--- too, which costs a key that moves for no reason and never a missed edge.
local function required_modules(source: string, file: string): {string}
  local chunk, _ = SyntaxNode.parse(source, file)
  if chunk ~= nil then
    return SyntaxNode.requires(chunk)
  end
  local out: mut {string} = {}
  local seen: mut {string: boolean} = {}
  for _, name in source:gmatch("require%s*[%(,]?%s*([\"'])([%w_%.%-]+)%1") do
    if seen[name] ~= true then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  return out
end

--- The files of the tree the new checker lowers: every `.tl` file but those of a `testdata` directory, which hold programs for
--- other projects.
local record Tree
  rows: {DeclareFile}
  --- Each file by its module, the name of its whole path ([`Driver.index`]): `ci/`, a project of its own, is no part of the tree.
  by_module: {string: DeclareFile}
  --- The same files as the sources a build is given ([`build.driver`]).
  index: Driver.Index
end

--- Where the digests of the sources the checks of other files read ([`ShapeKey`]) are kept, and the salt of the code that
--- makes them: a memo ([`build.check_memo`]) of the run, which has none in a test that gives it none.
local record Shaping
  memo: Sqlite.Handle?
  salt: string
end

--- The salt of the digests of [`ShapeKey`], from the code that makes them.
local function shaping_of(root: string, memo: Sqlite.Handle?): Shaping
  return { memo = memo, salt = check_memo.salt(root, { "lang/lexer.tl", "build/shape_key.tl", "build/check_memo.tl" }, "shape 1") }
end

--- The files of `files` that a lowering covers, each with the key its answer is kept under: `salt`, its dialect and
--- its source and the sources of every module it requires, however far. `written` are the sources the build writes from
--- other files ([`TreeProgram.derived_of`]), which count as files of the tree, named for the file each comes from.
local function tree_of(given: {{string}}, salt: string, bindings?: {{string}}, written?: {{string}},
                       shaping?: Shaping): Tree
  local files = TreeProgram.joined(given, written or {}).files
  local derived: mut {string: boolean} = {}
  for _, entry in ipairs(bindings or {}) do
    files[#files + 1] = entry -- checked: view_written
    derived[nth(entry, 1)] = true
  end
  -- No complaint of [`build.source_parse`]'s `declared` here: a `.d.tl` beside a `.tl`, or one that names no kind, is refused when the tree is built ([`Pipeline.build`]), which the
  -- checks that read this index follow, and the files given are a tree that built.
  local index = TreeProgram.index(files, {})
  local tree: Tree = { rows = {}, by_module = {}, index = index }
  local rows, by_module = tree.rows, tree.by_module
  local hashes: mut {string: string} = {}
  -- What the files that require a module read of it, by module: its digest where it has one ([`ShapeKey`]), else its text.
  local read: mut {string: string} = {}
  local store: Sqlite.Handle? = nil
  local opened = if shaping ~= nil then shaping.memo else nil end
  if opened ~= nil then
    local prepared, _ = check_memo.prepare(opened, "shape")
    if prepared then
      store = opened
    end
  end
  local row_of: mut {Driver.Source: DeclareFile} = {}
  for _, source in ipairs(index.sources) do
    -- A declaration derived from a header is no file of the tree: its text is in the salt of the checks that read it.
    if derived[source.filename] ~= true then
      local row: DeclareFile = {
        file = source.filename, source = source.text, module = source.module, dialect = source.dialect,
        imports = required_modules(source.text, source.filename), key = "",
      }
      rows[#rows + 1] = row -- checked: view_written
      row_of[source] = row
      -- A module given as two files (`x.tl` and `x/init.tl`) is read from the first; the key holds both texts.
      local exact = Hash.hex_sha256(source.text)
      hashes[row.module] = (hashes[row.module] or "") .. exact
      -- A source the build mends or writes from another file is read as its text says, comments and all.
      local held = exact
      if shaping ~= nil and source.dialect == "tl" and source.pinned == "" then
        local key = check_memo.key(shaping.salt, "shape", source.text)
        local kept = if store ~= nil then check_memo.get(store, "shape", key) else nil end
        local digest = kept or ShapeKey.digest(source.text, source.filename)
        if kept == nil and store ~= nil then
          check_memo.put(store, "shape", key, digest)
        end
        held = "s" .. digest
      end
      read[row.module] = (read[row.module] or "") .. held
    end
  end
  if store ~= nil then
    check_memo.finish(store, "shape")
  end
  for name, source in pairs(index.by_module) do
    local row = row_of[source]
    if row ~= nil then
      by_module[name] = row -- checked: view_written
    end
  end
  -- The key of a file is its source and the sources of every module it requires, however far.
  for _, row in ipairs(rows) do
    local reached: mut {string: boolean} = { [row.module] = true }
    local stack: mut {string} = {}
    for _, m in ipairs(row.imports) do
      stack[#stack + 1] = m
    end
    while #stack > 0 do
      local m = stack[#stack]
      stack[#stack] = nil
      local dep = by_module[m]
      if dep ~= nil and reached[dep.module] ~= true then
        reached[dep.module] = true
        for _, next_module in ipairs(dep.imports) do
          stack[#stack + 1] = next_module
        end
      end
    end
    local names: mut {string} = {}
    for m in pairs(reached) do
      names[#names + 1] = m
    end
    table.sort(names)
    local parts: mut {string} = {}
    for _, m in ipairs(names) do
      -- The file itself is read in full; the modules it requires as the checks of it read them.
      parts[#parts + 1] = m .. "=" .. (m == row.module and hashes[m] or read[m]) -- checked: and_ternary
    end
    -- The files of a cycle of requires reach the same modules: the file itself tells their keys apart.
    row.key = check_memo.key(salt, row.dialect, row.module .. "\n" .. table.concat(parts, "\n"))
  end
  return tree
end

--- A build ([`build.driver`]) over the tree at `root`: its prelude and the standard library's declarations as its
--- globals, the files of `tree` as its modules ([`build.tree_program`]).
local function tree_build(root: string, tree: Tree, types?: boolean, stubs?: {string: Driver.Source}): Driver.Build
  local globals = TreeProgram.tree_globals(root)
  return TreeProgram.build(tree.index, globals, types, stubs)
end

--- Asks `build` for the result of each module of `rows` (with its bodies checked where `bodies`), and gives
--- `seen` each row with the result of its module, one module's syntax held at a time ([`TreeProgram.stream`]). With `spliced`
--- the calls of [`Shape.record_of`] of each module are resolved before it is lowered, as the pipeline resolves them.
local function streamed(build: Driver.Build, tree: Tree, rows: {DeclareFile}, bodies: boolean, spliced: boolean,
                        seen: function(row: DeclareFile, result: Driver.Outcome?))
  local rows_of: mut {string: mut {DeclareFile}} = {}
  local names: mut {string} = {}
  for _, row in ipairs(rows) do
    local held = rows_of[row.module]
    local list = held or {}
    if held == nil then
      rows_of[row.module] = list
      names[#names + 1] = row.module
    end
    list[#list + 1] = row
  end
  local _ = TreeProgram.stream(build, tree.index, names, spliced, function(module: string)
    local result = build:result(module, bodies)
    local group = rows_of[module]
    if group ~= nil then
      for _, row in ipairs(group) do
        seen(row, result)
      end
    end
  end)
end

--- The errors of `list` as a check lists them.
local function findings_of(list: {Driver.Problem}): {Finding}
  local out: mut {Finding} = {}
  for _, e in ipairs(list) do
    out[#out + 1] = { code = e.code, y = e.y, x = e.x, msg = e.msg, fix = e.fix }
  end
  return out
end

--- The files of `tree` whose answer `memo` does not hold, with the answers it does.
local function kept_outcomes(memo: Sqlite.Handle?, kind: string, tree: Tree,
                             read: function(text: string, file: string): DeclareOutcome?
): {string: DeclareOutcome}, {DeclareFile}
  local outcomes: mut {string: DeclareOutcome} = {}
  local missed: mut {DeclareFile} = {}
  for _, row in ipairs(tree.rows) do
    local text = if memo ~= nil then check_memo.get(memo, kind, row.key) else nil end
    local kept = if text ~= nil then read(text, row.file) else nil end
    if kept ~= nil then
      outcomes[row.file] = kept
    else
      missed[#missed + 1] = row
    end
  end
  return outcomes, missed
end

--- The lines that list the errors no marker holds ([`build.ceilings.marked`]): the errors of each code of each file are held to the
--- markers of their lines, an error with none is listed with its place and fix, and a marker that holds more than its line
--- has is stale. `what` says what the errors are of in the message.
local function held_by_markers(tree: Tree, outcomes: {string: DeclareOutcome}, stage: Ceilings.Stage, codes: {string},
                               what: string, marking: Ceilings.Marking?): {string}
  local out: mut {string} = {}
  for _, row in ipairs(tree.rows) do
    local outcome = lookup_in(outcomes, row.file)
    -- A file the stage could not judge keeps its markers: neither held nor stale.
    if outcome.unjudged ~= true then
      for _, line in ipairs(told_marks(row.file, Ceilings.marked(stage, row.file, row.source, outcome.errors, codes, what),
          sink_of(marking))) do
        out[#out + 1] = line
      end
    end
  end
  return out
end

--- Every `.tl` file of the tree, its declarations and annotations lowered ([`lang.declarations`]) in the new
--- checker's grammar, but for the files of a `testdata` directory, and counting nothing of a file that does not parse:
--- the errors are the ones its markers hold ([`build.ceilings`]), no more: one with no marker on its line is listed with its
--- place and fix, and a marker that holds more than its line has is stale. The declaration files [`lang/prelude.d.tl`] and [`lang/stdlib.d.tl`] declare the
--- globals; every other file imports the modules it names from the whole tree, so the answer for a file is
--- kept in `memo` under the sources of every module it requires, directly or not.
function tree_checks.declared(root: string, memo?: Sqlite.Handle, marking?: Ceilings.Marking): {string}
  local files, trouble = sources_of(root)
  if files == nil then
    return { "reading the sources: " .. trouble }
  end
  local salt = check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl",
    "lang/truthy.tl", "lang/types.tl", "lang/relation.tl", "lang/declarations.tl", "lang/prelude.d.tl", "lang/stdlib.d.tl", "build/check_memo.tl", "build/driver.tl",
    "build/tree_checks.tl", "build/tree_program.tl", "build/gen_syscalls.tl", "core/syscalls.h",
    "core/process.h", "core/socket.h" }, "declared 6")
  local written, written_why = TreeProgram.derived_of(root)
  if written == nil then
    return { "reading the derived sources: " .. written_why }
  end
  local tree = tree_of(files, salt, TreeProgram.bindings_of(root), written, shaping_of(root, memo))
  if memo ~= nil then
    local _, _ = check_memo.prepare(memo, "declared")
  end
  local outcomes, missed = kept_outcomes(memo, "declared", tree, kept_declarations)
  if #missed > 0 then
    local build = tree_build(root, tree)
    streamed(build, tree, missed, false, false, function(row: DeclareFile, result: Driver.Outcome?)
      local outcome: DeclareOutcome = { errors = {}, unjudged = true }
      if result ~= nil and not result.broken then
        outcome = { errors = findings_of(result.declared) } -- checked: view_as_mut
      end
      outcomes[row.file] = outcome -- checked: view_written
      if memo ~= nil then
        check_memo.put(memo, "declared", row.key, check_memo.encode(kept_rows(outcome)))
      end
    end)
  end
  if memo ~= nil then
    check_memo.finish(memo, "declared")
  end
  return held_by_markers(tree, outcomes, "declared", Declarations.codes, "declarations", marking)
end

local function kept_checks(text: string, _file: string): DeclareOutcome?
  return kept_findings(text, Check.codes)
end

--- Every `.tl` file of the tree, lowered as [`declared`] has it and then checked
--- ([`lang.check`]): every expression and statement of its bodies typed, without flow. The files left out are those
--- of [`declared`], the declaration files (which have no bodies) and the files that do not parse. The
--- errors are the ones its markers hold ([`build.ceilings`]), no more: one with no marker on its line is listed with its place
--- and fix, and a marker that holds more than its line has is stale. The answer for a file is kept in `memo` under the sources of every module it requires,
--- directly or not, and of the checker. `phases`, when given, gets the nanoseconds spent parsing and scoping
--- (`prepare`), lowering (`lower`) and checking (`check`) the files the memo lacked.
function tree_checks.checked(root: string, memo?: Sqlite.Handle, phases?: {string: integer},
                             marking?: Ceilings.Marking): {string}
  local files, trouble = sources_of(root)
  if files == nil then
    return { "reading the sources: " .. trouble }
  end
  local salt = check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl",
    "lang/truthy.tl", "lang/types.tl", "lang/relation.tl", "lang/declarations.tl", "lang/check.tl",
    "lang/flow.tl", "lang/check_codes.tl", "lang/warnings.tl", "lang/prelude.d.tl", "lang/stdlib.d.tl", "build/check_memo.tl", "build/driver.tl", "build/tree_checks.tl", "build/tree_program.tl",
    "build/syntax_shape_specs.tl", "build/syntax_record_calls.tl", "build/syntax_protobuf_specs.tl", "build/syntax_record_splices.tl", "build/gen_syscalls.tl", "core/syscalls.h", "core/process.h",
    "core/socket.h" }, "checked 6")
  local written, written_why = TreeProgram.derived_of(root)
  if written == nil then
    return { "reading the derived sources: " .. written_why }
  end
  local tree = tree_of(files, salt, TreeProgram.bindings_of(root), written, shaping_of(root, memo))
  if memo ~= nil then
    local _, _ = check_memo.prepare(memo, "checked")
  end
  local outcomes, missed = kept_outcomes(memo, "checked", tree, kept_checks)
  local problems: {string} = {}
  if #missed > 0 then
    local build = tree_build(root, tree)
    streamed(build, tree, missed, true, true, function(row: DeclareFile, result: Driver.Outcome?)
      local outcome: DeclareOutcome = { errors = {}, unjudged = true }
      if result ~= nil and row.dialect == "tl" and not result.broken then
        outcome = { errors = findings_of(result.bodies) } -- checked: view_as_mut
      end
      outcomes[row.file] = outcome -- checked: view_written
      if memo ~= nil then
        check_memo.put(memo, "checked", row.key, check_memo.encode(kept_rows(outcome)))
      end
    end)
    problems = build.problems
    if phases ~= nil then
      phases.check = build.timing.check -- checked: map_field
      phases.prepare = build.timing.prepare -- checked: map_field
      phases.lower = build.timing.lower -- checked: map_field
    end
  end
  if memo ~= nil then
    check_memo.finish(memo, "checked")
  end
  local out = held_by_markers(tree, outcomes, "checked", Check.codes, "bodies", marking)
  for _, problem in ipairs(problems) do
    table.insert(out, 1, problem) -- checked: overload_none -- untyped: call
  end
  return out
end

--- Whether the build's own pipeline ([`build.pipeline`]) holds each module of the tree as the checks of the tree do, and
--- names the modules it refuses for more than a count ([`build.pipeline_check`] has the rules). `memo` keeps the answer for
--- a module under the key `checked` keeps its own.
function tree_checks.pipeline(root: string, build_db: Sqlite.Handle, memo?: Sqlite.Handle):
    {string}
  local files, trouble = sources_of(root)
  if files == nil then
    return { "reading the sources: " .. trouble }
  end
  local written, written_why = TreeProgram.derived_of(root)
  if written == nil then
    return { "reading the derived sources: " .. written_why }
  end
  local salt = check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl",
    "lang/types.tl", "lang/relation.tl", "lang/declarations.tl", "lang/check.tl", "lang/flow.tl",
    "lang/check_codes.tl", "lang/warnings.tl", "lang/prelude.d.tl", "lang/stdlib.d.tl",
    "build/check_memo.tl", "build/driver.tl", "build/tree_checks.tl", "build/tree_program.tl",
    "build/syntax_shape_specs.tl", "build/syntax_record_calls.tl", "build/syntax_protobuf_specs.tl", "build/syntax_record_splices.tl", "build/pipeline.tl", "build/pipeline_check.tl",
    "build/gen_syscalls.tl", "build/compile_grammar.tl", "build/main_locals.tl", "build/lua_tail.tl", "lang/codegen.tl", "lang/truthy.tl", "lang/fact_wraps.tl",
    "lang/boundaries.tl", "lang/boundary_checks.tl",
    "core/syscalls.h", "core/process.h", "core/socket.h" }, "pipeline 4")
  local tree = tree_of(files, salt, TreeProgram.bindings_of(root), written, shaping_of(root, memo))
  return PipelineCheck.compare(root, build_db, memo, #tree.rows, function(index: integer): PipelineCheck.Row
    local row = assert(tree.rows[index])
    return { file = row.file, module = row.module, dialect = row.dialect, key = row.key }
  end, tree_checks.declared(root, memo), tree_checks.checked(root, memo))
end

--- The files that may read `package`, tests apart: the table that holds the loaded modules, the searchers that find them, `preload`,
--- `searchpath`, `loadlib` and the search paths. A module that reads them can load a module by a name it computes, which
--- the build does not see as an edge, so `require`, the one way the build follows, is the only way the rest load one.
local packagers: {string: string} = {
  ["build/link_resolve.tl"] = "refuses a step into `package.loaded` or `package.preload` when it resolves a name",
  ["build/removed_fix.tl"] = "reads the catalog from `package.loaded`",
  ["build/sandbox.tl"] = "asks whether the core preloads a module",
  ["build/test_worker.tl"] = "holds `require` to a test's closure through the searchers and `package.loaded`",
  ["cosmic/store.tl"] = "reads the store's searcher",
}

--- Each read of `package` in a file of the tree that is not one of `files` (by default [`packagers`]), as
--- `<file>:<line>: reads \`package\`...`: a name `package` that is no field (`t.package`, `s:package()`, `{ package = 1 }`, a field `package: T` declared),
--- so that an alias (`local p = package`), an index (`package["searchers"]`) and each field are all found.
function tree_checks.package_readers(root: string, files?: {string: string}): {string}
  local sources, trouble = sources_of(root)
  if sources == nil then
    return { "reading the sources: " .. trouble }
  end
  local permitted = files or packagers
  local out: mut {string} = {}
  for _, entry in ipairs(sources) do
    local file, text = entry[1], entry[2]
    -- A test is exempt: the worker holds it to its closure, so a test that reads `package` can load nothing the build
    -- does not follow, and it is no module a program carries.
    if file ~= nil and text ~= nil and permitted[file] == nil and file:match("_test%.tl$") == nil and
        text:find("package", 1, true) ~= nil then
      local tokens = Lexer.lex(text, file).tokens
      for i, word in ipairs(tokens.text) do
        if word == "package" and tokens.kind[i] == "identifier" then
          local before, after = tokens.text[i - 1], tokens.text[i + 1]
          local is_field = before == "." or before == ":" or after == ":" or
            ((before == "{" or before == ",") and after == "=")
          if not is_field then
            out[#out + 1] = file .. ":" .. tostring(tokens.y[i]) .. ": reads `package`, which only the files " ..
              "build/tree_checks.tl's `packagers` names may: a module loads what it needs by `require` of a " ..
              "literal name, which the build follows, and not through the searchers or the table of loaded modules"
          end
        end
      end
    end
  end
  return out
end

--- The files that turn text into a chunk, tests apart: `load` and the names of its family, which build a function from
--- Lua text. What such a chunk is handed is what it can reach, and a chunk of text no checker read reaches the
--- library with the checks the library would otherwise rely on being dead. So each file here loads text the build
--- itself wrote or a constant, and the reason says which; a file that loads other text is a path by which unchecked Lua
--- reaches `cosmic.*`, and is not added without the owner's say.
local loaders: {string: string} = {
  ["build/child_policy_database_fixture.tl"] = "the main of a fixture program, a constant chunk of the test support",
  ["build/database_start_fixture.tl"] = "the modules of a fixture database, compiled by the build and loaded to test a start",
  ["build/fuzz/init.tl"] = "the constant chunk `return __cosmic_tc`, the hook a checked run defines",
  ["build/load_module.tl"] = "the named loader: the constant chunk `return require((...))`",
  ["build/lua_tail.tl"] = "the Lua the compiler wrote, loaded in an environment of its own to dump its bytecode or to probe its locals",
  ["build/sandbox.tl"] = "the script the checker compiled ([`build.standalone`]'s `code`), as the main of a sealed program",
  ["build/standalone.tl"] = "the Lua the checker compiled from a file or a `-e` chunk, or kept from such a compile",
  ["build/test_worker.tl"] = "the constant chunk that reads a value's metatable in the form the compiler writes",
  ["build/type_watch.tl"] = "the constant chunk `return __cosmic_tc`, the hook a checked run defines",
  ["cosmic/errors_example.tl"] = "shows what a chunk built by `load` does with a method that is missing",
  ["cosmic/removed_example.tl"] = "shows what a chunk built by `load` is told of a removed name",
  ["lang/check_programs.tl"] = "the Lua the checker wrote of the programs it is tested on",
}

--- Each use of `load`, `loadfile`, `dofile` or `loadstring` as a name in a file of the tree that is not one of `files`
--- (by default [`loaders`]) and is no test, as `<file>:<line>: ...`: a name that is no field (`t.load`, `s:load()`, a field
--- `load: T` declared) and no function being defined, so that a call, an alias and an argument are all found.
function tree_checks.text_loaders(root: string, files?: {string: string}): {string}
  local sources, trouble = sources_of(root)
  if sources == nil then
    return { "reading the sources: " .. trouble }
  end
  local permitted = files or loaders
  local named: {string: boolean} = { load = true, loadfile = true, dofile = true, loadstring = true }
  local out: mut {string} = {}
  for _, entry in ipairs(sources) do
    local file, text = entry[1], entry[2]
    if file ~= nil and text ~= nil and permitted[file] == nil and file:match("_test%.tl$") == nil and
        file:match("%.tl$") ~= nil and (text:find("load", 1, true) ~= nil or text:find("dofile", 1, true) ~= nil) then
      local tokens = Lexer.lex(text, file).tokens
      local told = "which only the files build/tree_checks.tl's `loaders` names may: a function built from text is a " ..
        "path by which Lua no checker read reaches `cosmic.*`; load a module by `require` of a literal name"
      for i, word in ipairs(tokens.text) do
        local before, after = tokens.text[i - 1], tokens.text[i + 1]
        if named[word] == true and tokens.kind[i] == "identifier" then
          -- A field of the globals table is the function itself, whatever the receiver is called.
          local receiver = tokens.text[i - 2]
          local is_field = before == "." or before == ":" or after == ":" or before == "function" or
            ((before == "{" or before == ",") and after == "=")
          if before == "." and (receiver == "_G" or receiver == "_ENV") then is_field = false end
          if not is_field then
            out[#out + 1] = file .. ":" .. tostring(tokens.y[i]) .. ": uses `" .. word .. "`, " .. told
          end
        elseif (word == "_G" or word == "_ENV") and tokens.kind[i] == "identifier" then
          -- `_G["load"]` and `rawget(_G, "load")` name it by a string.
          local by_string = false
          if (after == "[" or after == ",") and tokens.kind[i + 2] == "string" then
            local value = tokens.value[i + 2]
            by_string = value ~= nil and named[value] == true
          end
          if by_string then
            out[#out + 1] = file .. ":" .. tostring(tokens.y[i]) .. ": uses a function of the globals by its name, " .. told
          end
        end
      end
    end
  end
  return out
end

--- Each early return of a test in a `*_test.tl` file of the tree under `root` ([`TestReturns`]), as `<file>:<line>:
--- <test> returns early ...`. A test that cannot check its subject here declares `requires` or calls `Test.skip(reason)`
--- (doc/testing.md, "skipping"); a `return` passes having checked nothing.
function tree_checks.test_returns(root: string): {string}
  local sources, trouble = sources_of(root)
  if sources == nil then
    return { "reading the sources: " .. trouble }
  end
  local out: mut {string} = {}
  for _, entry in ipairs(sources) do
    local file, text = entry[1], entry[2]
    if file ~= nil and text ~= nil and file:match("_test%.tl$") ~= nil and text:find("return", 1, true) ~= nil then
      local chunk, parse_trouble = SyntaxNode.parse(text, file)
      if chunk == nil then
        out[#out + 1] = file .. ": cannot read it to check its early returns: " .. parse_trouble
      else
        for _, site in ipairs(TestReturns.of_chunk(chunk)) do
          out[#out + 1] = file .. ":" .. tostring(site[1]) .. ": " .. tostring(site[2]) .. " returns early (`" ..
            tostring(site[3]) .. "`), which passes having checked nothing: declare `requires`, or call " ..
            "`Test.skip(reason)` (doc/testing.md, \"skipping\"), after which nothing runs"
        end
      end
    end
  end
  return out
end

-- TODO: once the helpers copied between files below `CLONE_TOKENS` are moved into shared fixtures, lower it to 30.

--- The fewest tokens a helper has for [`test_clones`] to compare it. Copies ran from about 30 tokens to a screen: below
--- about 30 a wrapper that two files write alike is no copy of the other, and 70 is the lowest where the copies the tree
--- held were few enough for one change to move (a process runner, a project writer).
local CLONE_TOKENS = 70

--- A helper [`test_clones`] has read: where it is.
local record CloneSite
  file: string
  line: integer
  name: string
end

--- Each top-level `local function` that is no test, of a `*_test.tl` or `*_fixture.tl` file under `root`, written
--- token for token as one in another such file ([`TestClones`]), as `<file>:<line>: <name> is ...`, one for each
--- set of copies. A copy is fixed in one place: a helper goes into a shared fixture (build/test_support_fixture.tl,
--- build/test_sandbox_fixture.tl, build/child_policy_fixture.tl ...), and each file requires it.
function tree_checks.test_clones(root: string, threshold?: integer): {string}
  local sources, trouble = sources_of(root)
  if sources == nil then
    return { "reading the sources: " .. trouble }
  end
  local least = threshold or CLONE_TOKENS
  local out: mut {string} = {}
  -- Only the files that are tests or fixtures take part, on both sides of a pair. A helper is read only where its head
  -- ([`TestClones`]'s `scan`) is another file's too.
  local scans: mut {string: TestClones.Scan} = {}
  local texts: mut {string: string} = {}
  local candidates: mut {string} = {}
  local in_files: mut {string: mut {string: boolean}} = {}
  for _, entry in ipairs(sources) do
    local file, text = entry[1], entry[2]
    if file ~= nil and text ~= nil and text:find("local function", 1, true) ~= nil and
        (file:match("_test%.tl$") ~= nil or file:match("_fixture%.tl$") ~= nil) then
      local scan = TestClones.scan(text)
      scans[file] = scan
      texts[file] = text
      candidates[#candidates + 1] = file
      for _, head in ipairs(scan.heads) do
        local files: mut {string: boolean} = in_files[head.key] or {}
        in_files[head.key] = files
        files[file] = true
      end
    end
  end
  -- The lines where a file's real top-level helpers begin, parsed whole once and only for a file a finding is made of:
  -- a head in a long string that holds Teal source is no helper.
  local real: mut {string: {string: boolean}} = {}
  local function is_real(file: string, line: integer): boolean, string
    local lines = real[file]
    if lines == nil then
      local chunk, parse_trouble = SyntaxNode.parse(assert(texts[file]), file)
      if chunk == nil then
        return false, parse_trouble
      end
      local found: mut {string: boolean} = {}
      for _, top in ipairs(chunk.body.stats) do
        if top.kind == "LocalFunction" then
          found[tostring(SyntaxNode.span(chunk, top).y)] = true
        end
      end
      real[file] = found
      lines = found
    end
    return lines[tostring(line)] == true, ""
  end
  local groups: mut {string: mut {CloneSite}} = {}
  local order: mut {string} = {}
  local unreadable: mut {string} = {}
  for _, file in ipairs(candidates) do
    local scan = assert(scans[file])
    for _, head in ipairs(scan.heads) do
      local files = assert(in_files[head.key])
      local count = 0
      for _ in pairs(files) do count = count + 1 end
      if count >= 2 then
        local helper, cut_trouble = TestClones.read(scan, head, file)
        if helper == nil then
          local genuine, parse_trouble = is_real(file, head.line)
          if parse_trouble ~= "" then
            out[#out + 1] = file .. ": cannot read it to check its helpers: " .. parse_trouble
          elseif genuine then
            unreadable[#unreadable + 1] = file .. ":" .. tostring(head.line) .. ": cannot read " .. head.name ..
              " to check it is no copy: " .. cut_trouble
          end
        elseif helper.size >= least then
          local group: mut {CloneSite} = groups[helper.body] or {}
          if groups[helper.body] == nil then
            groups[helper.body] = group
            order[#order + 1] = helper.body
          end
          group[#group + 1] = { file = file, line = helper.line, name = helper.name }
        end
      end
    end
  end
  for _, line in ipairs(unreadable) do out[#out + 1] = line end
  for _, body in ipairs(order) do
    local group = assert(groups[body])
    local files: mut {string: boolean} = {}
    local distinct = 0
    local sites: mut {CloneSite} = {}
    local checked = #group >= 2
    for _, site in ipairs(group) do
      local genuine = false
      if checked then
        local real_here, parse_trouble = is_real(site.file, site.line)
        genuine = real_here
        if parse_trouble ~= "" then
          out[#out + 1] = site.file .. ": cannot read it to check its helpers: " .. parse_trouble
        end
      end
      if genuine then
        if files[site.file] ~= true then
          files[site.file] = true
          distinct = distinct + 1
        end
        sites[#sites + 1] = site
      end
    end
    if distinct >= 2 then
      local first = assert(sites[1])
      local others: mut {string} = {}
      for i = 2, #sites do
        local site = assert(sites[i])
        others[#others + 1] = site.file .. ":" .. tostring(site.line) .. " (" .. site.name .. ")"
      end
      out[#out + 1] = first.file .. ":" .. tostring(first.line) .. ": " .. first.name ..
        " is copied token for token in " .. table.concat(others, ", ") .. ": move it into a shared fixture " ..
        "(build/test_support_fixture.tl, build/test_sandbox_fixture.tl, build/child_policy_fixture.tl ...) that " ..
        "each requires"
    end
  end
  return out
end

--- What [`tree_checks.markers`] found: the lines that refuse, and the markers each file holds of each code, which the ratchet
--- holds to the merge base ([`build.ceilings_base`]).
local record Marked
  mut lines: mut {string}
  --- File to code to the count of findings its markers hold.
  mut counts: mut {string: {string: integer}}
end

--- The markers of the tree at `root`: the counts of each file's markers by `<stage> <code>`, the ratchet's side of the tree.
function tree_checks.markers(root: string): Marked
  local out: Marked = { lines = {}, counts = {} }
  local files, trouble = sources_of(root)
  if files == nil then
    out.lines[1] = "reading the sources: " .. trouble
    return out
  end
  for _, entry in ipairs(files) do
    local file, source = nth(entry, 1), nth(entry, 2)
    if Markers.mentions(source) then
      local held = Markers.counts(source, file)
      if next(held) ~= nil then
        out.counts[file] = held
      end
    end
  end
  return out
end

--- The calls the new checker gave no function, which no rule of the discipline judged ([`build.syntax_contracts`]'s
--- `untyped`), held by the markers at the lines of the calls (`-- untyped: call`): a call with no marker on its line is listed,
--- as the build itself refuses it ([`build.pipeline`]'s `generate`), and a marker that holds more than its line has is stale. The count is the port's alone, over the program the pipeline reads ([`build.tree_program`],
--- its calls of [`Shape.record_of`] resolved). The answer for a
--- file is kept in `memo` under its source and those of every module it requires, and of the checker.
function tree_checks.untyped(root: string, memo?: Sqlite.Handle, marking?: Ceilings.Marking): {string}
  local files, trouble = sources_of(root)
  if files == nil then
    return { "reading the sources: " .. trouble }
  end
  local written, written_why = TreeProgram.derived_of(root)
  if written == nil then
    return { "reading the derived sources: " .. written_why }
  end
  local salt = check_memo.salt(root, { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl",
    "lang/truthy.tl", "lang/types.tl", "lang/relation.tl", "lang/declarations.tl", "lang/check.tl", "lang/flow.tl",
    "lang/check_codes.tl", "lang/warnings.tl", "lang/prelude.d.tl", "lang/stdlib.d.tl",
    "build/check_memo.tl", "build/driver.tl", "build/syntax_node.tl", "build/syntax_report.tl",
    "build/syntax_receivers.tl", "build/syntax_contracts.tl", "build/contract_rules.tl", "build/tree_checks.tl",
    "build/tree_program.tl", "build/gen_syscalls.tl", "core/syscalls.h", "core/process.h", "core/socket.h" }, "untyped 2")
  local tree = tree_of(files, salt, TreeProgram.bindings_of(root), written, shaping_of(root, memo))
  if memo ~= nil then
    local _, _ = check_memo.prepare(memo, "untyped")
  end
  local found: mut {string: integer} = {}
  -- The line of each of those calls, by file, for the markers.
  local at: mut {string: {integer}} = {}
  local missed: mut {DeclareFile} = {}
  for _, row in ipairs(tree.rows) do
    if row.dialect ~= "tl" or not SyntaxContracts.applies(row.file) then
      -- Not held to the discipline: nothing is counted of it.
    else
      local count: integer? = nil
      if memo ~= nil then
        local text = check_memo.get(memo, "untyped", row.key)
        if text ~= nil then
          local kept = check_memo.decode(text)[1]
          if kept ~= nil then
            count = math.tointeger(tonumber(kept[1]))
            local lines: mut {integer} = {}
            for i = 2, #kept do
              lines[#lines + 1] = math.tointeger(tonumber(kept[i])) or 0
            end
            at[row.file] = lines
          end
        end
      end
      if count ~= nil then
        found[row.file] = count
      else
        missed[#missed + 1] = row
      end
    end
  end
  if #missed > 0 then
    local build = tree_build(root, tree, true)
    streamed(build, tree, missed, true, true, function(row: DeclareFile, result: Driver.Outcome?)
      local subject: Report.Subject? = nil
      if result ~= nil then subject = Report.of(build.program, result) end
      if subject == nil then
        -- A module the checker kept no report of is refused elsewhere ([`checked`]).
        return
      end
      local read = SyntaxContracts.check(subject, nil, SyntaxContracts.declared_in(tree.index))
      local count = read.untyped
      found[row.file] = count
      at[row.file] = read.untyped_lines
      if memo ~= nil then
        local kept: mut {string} = { tostring(count) }
        for _, line in ipairs(read.untyped_lines) do kept[#kept + 1] = tostring(line) end
        check_memo.put(memo, "untyped", row.key, check_memo.encode({ kept }))
      end
    end)
  end
  if memo ~= nil then
    check_memo.finish(memo, "untyped")
  end
  local out: mut {string} = {}
  for _, row in ipairs(tree.rows) do
    -- A file this check does not count has no findings and its markers are not judged: they may be of a check that did not run.
    local lines = at[row.file]
    if lines ~= nil then
      local findings: mut {Ceilings.Finding} = {}
      for _, line in ipairs(lines) do
        findings[#findings + 1] = { code = Ceilings.untyped_code, y = line, x = 1, msg = Ceilings.untyped_message,
          fix = Ceilings.untyped_fix }
      end
      for _, line in ipairs(told_marks(row.file, Ceilings.marked("untyped", row.file, row.source, findings,
          { Ceilings.untyped_code }, "calls"), sink_of(marking))) do
        out[#out + 1] = line
      end
    end
  end
  return out
end

--- The tables of text-derived rows that a pure store ([`build.closure_store`]) leaves out, so a query of one fails there.
--- `stubs` is not among them: a pure store keeps those of the modules a test names, and the module it lacks fails by name.
local text_tables <const>: {string:boolean} = {
  docs = true, uses = true, links = true, examples = true, catalog = true, places = true,
}

--- The string literals of the Teal `source`, comments left out and a run of literals joined by `..` as one, so a statement
--- built in pieces reads whole. A `--` inside a literal is part of it.
local function literal_runs(source: string): {string}
  local runs: mut {string} = {}
  local current = ""
  local open = false
  local joining = false
  local function flush()
    if open then
      local run = current
      runs[#runs + 1] = run
    end
    current, open, joining = "", false, false
  end
  local function add(literal: string)
    if open and not joining then flush() end
    current, open, joining = current .. literal, true, false
  end
  local at, size = 1, #source
  while at <= size do
    local c = source:sub(at, at)
    local long_open = source:match("^%[(=*)%[", at)
    if source:sub(at, at + 1) == "--" then
      local comment_open = source:match("^%-%-%[(=*)%[", at)
      local ends = "\n"
      if comment_open ~= nil then ends = "]" .. comment_open .. "]" end
      local _, to = source:find(ends, at, true)
      at = (to or size) + 1
    elseif c == '"' or c == "'" then
      local parts: mut {string} = {}
      at = at + 1
      while at <= size and source:sub(at, at) ~= c do
        local d = source:sub(at, at)
        if d == "\\" then
          parts[#parts + 1] = source:sub(at + 1, at + 1)
          at = at + 2
        else
          parts[#parts + 1] = d
          at = at + 1
        end
      end
      at = at + 1
      add(table.concat(parts))
    elseif long_open ~= nil then
      local start = at + #long_open + 2
      local from, to = source:find("]" .. long_open .. "]", start, true)
      add(source:sub(start, (from or size + 1) - 1))
      at = (to or size) + 1
    elseif c == "." and source:sub(at + 1, at + 1) == "." then
      if open and not joining then joining = true else flush() end
      at = at + 2
    elseif c:find("%s") ~= nil then
      at = at + 1
    else
      flush()
      at = at + 1
    end
  end
  flush()
  return runs
end

--- The word of a table in a `FROM` or `JOIN` item, without its schema (`main.catalog`) or `_fts` (the full-text table of
--- one), and only its first word: `docs d` is `docs`.
local function table_of(item: string): string
  local name = item:match("^%s*([%w_%.]+)") or ""
  name = name:gsub("^[%w_]+%.", "")
  name = name:gsub("_fts$", "")
  return name
end

--- Whether one SQL fragment `run` reads a table of [`text_tables`]: it follows a `FROM` (and a comma-separated list after it)
--- or a `JOIN`. A fragment is SQL when it holds `select`, or `from` a table is followed by a clause (`where`, `join`,
--- `order`, ...): prose that says "Read from links" is neither.
local function reads_text_table(run: string): boolean
  local lowered = run:lower()
  local sql = lowered:find("%f[%w_]select%f[^%w_]") ~= nil
  local clauses <const> = { "where", "join", "on", "order", "group", "limit", "left", "inner", "union", "having" }
  local at = 1
  while true do
    local _, to = lowered:find("%f[%w_]from%s+", at)
    local _, joined = lowered:find("%f[%w_]join%s+", at)
    local found = to
    local after_join = false
    if joined ~= nil and (found == nil or joined < found) then found, after_join = joined, true end
    if found == nil then return false end
    local rest = lowered:sub(found + 1)
    local cut = #rest + 1
    local ended = false
    for _, clause in ipairs(clauses) do
      local from = rest:find("%f[%w_]" .. clause .. "%f[^%w_]")
      if from ~= nil and from < cut then cut, ended = from, true end
    end
    local close = rest:find("[;%)]")
    if close ~= nil and close < cut then cut, ended = close, true end
    local list = rest:sub(1, cut - 1)
    if sql or ended then
      local items: mut {string} = { list }
      if not after_join then
        items = {}
        for item in (list .. ","):gmatch("([^,]*),") do items[#items + 1] = item end
      end
      for _, item in ipairs(items) do
        if text_tables[table_of(item)] == true then return true end
      end
    end
    at = found + 1
  end
end

--- Whether `source` runs SQL that reads text a pure store withholds: a table of [`text_tables`], or the source of a module or
--- a declaration (`modules` or `decls` read beside a `source` column). A statement whose table is built at run time
--- (`"FROM " .. name`) is not seen.
local function queries_text(source: string): boolean
  for _, run in ipairs(literal_runs(source)) do
    if reads_text_table(run) then return true end
    local lowered = run:lower()
    if lowered:find("%f[%w_]source%f[^%w_]") ~= nil and
        (lowered:find("from%s+modules%f[^%w_]") ~= nil or lowered:find("from%s+decls%f[^%w_]") ~= nil) then
      return true
    end
  end
  return false
end

--- The readers of text that need no declaration, each with why: a reader that is given a handle on the projection or the
--- working database and not the store a test is given, or whose read fails loudly in the pure store. Each
--- is a module that would otherwise be refused by [`tree_checks.text_readers`].
local text_read_allowed <const>: {string:string} = {
  ["build.checker_declarations"] = "reads the declarations of the globals and the standard library, which a closure store adds for a closure that holds this module ([`build.closure_store`]'s `declared_beside`), so its read is never short",
  ["build.plans"] = "asks the stub or source of a standard-library module a compile names; the pure store holds the stubs a test names and fails for the rest ([`Store.withheld`])",
  ["build.stamp"] = "hashes each declaration's source into what binds a tool's stamps to its rows; a store a test is given carries no stamp, and where it withholds a source the binding is not the stamps' and none is answered",
  ["build.standard_text"] = "serves the stub or source of a standard-library module; the pure store holds the stubs a test names and fails for the rest ([`Store.withheld`])",
  ["build.closure_store"] = "reads the projection it writes the stores of, which a test is never given and which no test's store holds",
  ["build.perf"] = "a standalone script a release program runs; its SQL is the argument of a `cosmic sql` it starts and times against a project's own store, not a read of the store a test is given, and it cannot require a module of the tree it benchmarks",
  ["build.writer"] = "writes the projection from the working database it is handed, whose tables a test's store never holds",
  ["build.symbols"] = "words a hint of a refusal from the docs and examples of the databases it is handed; in a pure store those tables are absent and it raises ([`build.symbols`]'s `refuse_withheld`)",
  ["cosmic.errors"] = "asks the catalog for the guidance on an error; a pure store has no catalog and the lookup raises there ([`Errors.guidance_in`]); a standard-library module, which cannot require a module of the build",
}

-- TODO: see a table named at run time (`"FROM " .. name`), which a scan of literals cannot, once the checker answers
-- the value a string expression holds.

--- Each module of `db` that is no test and reads module text without declaring it, as `<module> reads text (<how>) and
--- requires none of build.reads.*`.
---
--- This is a lint, not what makes the pure store sound: a read of text the pure store withholds fails there (a source
--- is withheld, a table is absent), so a reader the lint misses fails the test that reaches it and is declared then. The lint finds
--- most readers early. A module declares what it reads by requiring one of [`build.code_walk`]'s `markers` by value (a
--- `local type` require is erased), which a test's closure follows ([`build.closure_store`]'s pure store keeps what the
--- closure declares); `excusing` (by default [`text_read_allowed`]) excuses a reader with a reason. The reads taken as
--- text: [`Store.source`] and [`Store.withheld`], which answer a module's source; and SQL that reads a table of
--- [`text_tables`] or the source of a module, in any module that names it (a handle handed on is read by whoever
--- queries it). A module that runs a statement it is handed (`cosmic sql`) cannot be told apart by what it names, and
--- declares [`build.reads.all`] by hand.
function tree_checks.text_readers(db: Sqlite.Handle, excusing?: {string:string}): {string}
  local excused = excusing or text_read_allowed
  local imported, imported_trouble = Sqlite.text_rows(db, "SELECT path, requires FROM imports ORDER BY path, requires")
  if imported == nil then return { "reading the imports: " .. imported_trouble } end
  local modules, trouble = Sqlite.text_rows(db,
    "SELECT path, CAST(inflate(source) AS TEXT) FROM modules WHERE kind NOT IN ('test', 'example') ORDER BY path")
  if modules == nil then return { "reading the modules: " .. trouble } end
  local source_of: mut {string:string} = {}
  for _, row in ipairs(modules) do source_of[row:text(1)] = row:text(2) end
  local called, called_trouble = Sqlite.text_rows(db,
    "SELECT DISTINCT from_module, symbol FROM uses WHERE module = 'cosmic.store' " ..
      "AND symbol IN ('source', 'withheld') ORDER BY from_module, symbol")
  if called == nil then return { "reading the uses: " .. called_trouble } end
  local how: mut {string:string} = {}
  for _, row in ipairs(called) do
    local path = row:text(1)
    if source_of[path] ~= nil and path ~= "cosmic.store" and how[path] == nil then
      how[path] = "Store." .. row:text(2)
    end
  end
  for path, source in pairs(source_of) do
    if how[path] == nil and path ~= "cosmic.store" and queries_text(source) then
      how[path] = "SQL of a text table"
    end
  end
  local out: mut {string} = {}
  for path, symbol in pairs(how) do
    local declared = CodeWalk.markers[path] ~= nil or excused[path] ~= nil
    for _, row in ipairs(imported) do
      local required = row:text(2)
      -- A `local type` require is erased, and a test's closure leaves the edge out.
      if row:text(1) == path and CodeWalk.markers[required] ~= nil and
          (source_of[path] or ""):find("local%s+type%s+[%w_]+%s*=%s*require%s*%(?%s*[\"']" ..
                (required:gsub("%.", "%%.")) .. "[\"']") == nil then
        declared = true
      end
    end
    if not declared then
      out[#out + 1] = path .. " reads text (" .. symbol .. ") and requires none of build.reads.*: require the one that " ..
        "names what it reads (build/reads/), `all` where nothing narrower is true"
    end
  end
  table.sort(out)
  return out
end

--- Every check over the projection `db`, each line one failure,
--- prefixed with the check's name; none when the tree passes them all.
--- The plurals are checked with `extra` sources besides the projection's.
--- @param carried the database a release binary carries of `db`
---   ([`build.docs_checks`]' `carried`), which the checks of what `cosmic
---   docs` shows read; `db` itself when not given
--- @param help what `cosmic help` prints ([`build.help_source`]' `texts`),
---   whose references are checked with the docs'; none when not given
--- @param read the plurals already found in files' texts, as [`plurals`]
---   takes them
function tree_checks.run(db: Sqlite.Handle, quickstart: string?, extra?: {{string}}, carried?: Sqlite.Handle,
                         help?: {string: string}, read?: {string: tree_checks.Plurals}): {string}
  local out: mut {string} = {}
  local plurals = tree_checks.plurals(db, extra, nil, read)
  for _, line in ipairs(tree_checks.text_readers(db)) do
    out[#out + 1] = "text readers: " .. line
  end
  for _, line in ipairs(tree_checks.meta_readers(db, "image_hash")) do
    out[#out + 1] = "image_hash readers: " .. line
  end
  for _, check in ipairs({
      { name = "exports", lines = tree_checks.exports(db) }, -- checked: arms_differ
      { name = "unnamed types", lines = tree_checks.unnamed_types(db) }, -- checked: arms_differ
      { name = "doc anchors", lines = tree_checks.anchors(db) }, -- checked: arms_differ
      { name = "compiler readers", lines = tree_checks.meta_readers(db, "compiler") }, -- checked: arms_differ
      { name = "build directory", lines = tree_checks.build_directory(db) }, -- checked: arms_differ
      { name = "stand-ins", lines = tree_checks.stand_ins(db) }, -- checked: arms_differ
      { name = "docs queries", lines = tree_checks.queries(db) }, -- checked: arms_differ
      { name = "quieted", lines = tree_checks.quieted(db) }, -- checked: arms_differ
      { name = "restricted", lines = tree_checks.restricted(db) }, -- checked: arms_differ
      { name = "declarations", lines = tree_checks.declarations(db) }, -- checked: arms_differ
      { name = "verbs", lines = tree_checks.verbs(db, quickstart) }, -- checked: arms_differ
      { name = "rendered docs", lines = docs_checks.rendered(carried or db) }, -- checked: arms_differ
      { name = "doc references", lines = docs_checks.references(carried or db, help) }, -- checked: arms_differ
      { name = "public docs", lines = tree_checks.public_docs(db) }, -- checked: arms_differ
      { name = "plurals", lines = plurals }, -- checked: arms_differ
  }) do
    for _, line in ipairs(check.lines) do
      out[#out + 1] = check.name .. ": " .. line
    end
  end
  return out
end

return tree_checks
