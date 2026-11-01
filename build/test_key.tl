--- The part of `cosmic test` that makes a verdict's key, looks a verdict
--- up under it, and gives a worker what it runs on: the key's inputs
--- gathered once for a run ([`test_key.gather`]), a test's key
--- ([`declared_of`]) and the lookup of its verdict ([`test_key.lookup`]),
--- what a verdict kept for it is ([`test_key.keep`]), the stores and sealed
--- databases a worker is given and a key holds, its sandbox's plan and
--- environment, hold and policy and the command that starts it
--- ([`test_key.prepare`]), and the digests of the harness itself
--- ([`test_key.harness`]). The runner, [`build.test`], schedules the
--- workers, keeps the history and the coverage and says the summary; it
--- calls this for each of those and makes no key.
---
--- This module is the one build/harness_epoch.tl holds of the runner, alone
--- (`key_own`): no key holds its code, which the epoch stands for, so an
--- edit to it fails build/harness_epoch_test.tl until the edit is
--- acknowledged or the epoch bumped, and an edit to the runner moves
--- nothing. What is the runner's and what is this module's is decided by
--- that rule: code that computes a key, looks a verdict up or keeps one,
--- or decides what a worker is given is here; where a part could be
--- either, it is here. The types they share are [`build.test_state`]'s.
---
--- Held alone, its requires are not walked: what it reaches beyond the
--- modules the harness holds is outside build/harness_epoch.tl's `library`
--- rule (the TODO at `key_roots`).

-- TODO: name this module where the comments of build/test_policy.tl,
-- build/test_sandbox.tl, build/closure_store.tl, build/schema.tl,
-- build/artifact.tl and cosmic/store.tl still name build.test for what
-- moved here (`launch`, `scratch`, [`worker_environment`], [`sealed_for`],
-- `store_writer`, [`sweep_stores`], [`base_name`], `erased_require`, `harness`),
-- with the next edit to each that runs every test again anyway: the
-- runtime every key holds is made from the digests of the first two, a
-- store's address from the source of the next two, and the core's identity
-- from the last two, so a comment edit in any of them moves every key or
-- every store address, which this move leaves alone.

local type Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local testing = require("cosmic.internal.testing")
local Fs = require("cosmic.fs")
local build_paths = require("build.paths")
local Proc = require("cosmic.proc")
local type Sandbox = require("cosmic.sandbox")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local sys = require("cosmic.sys")
local analysis_schema = require("build.analysis_schema")
local importer = require("build.importer")
local type Module = importer.Module
local GrammarMode = require("build.grammar_mode")
local plural = require("build.plural")
local rebuild_lock = require("build.rebuild_lock")
local schema = require("build.schema")
local closure_store = require("build.closure_store")
local confine = require("build.confine")
local shared_compiles = require("build.shared_compiles")
local shared_verdicts = require("build.shared_verdicts")
local test_inputs = require("build.test_inputs")
local test_policy = require("build.test_policy")
local test_sandbox = require("build.test_sandbox")
local test_sandbox_probe = require("build.test_sandbox_probe")
local declared_key = require("build.declared_key")
local artifact = require("build.artifact")
local hashing = require("build.digest")
local harness_epoch = require("build.harness_epoch")
local host_names = require("build.host_names")
local host_requires = require("build.host_requires")
local host_caches = require("build.caches")
local worker = require("build.test_worker")
local log = require("build.logger").log
local bind = require("build.bind")
local type State = require("build.test_state")

local record test_key
  --- What of the running binary a run holds of the code a worker runs,
  --- or that writes what it is given ([`binary_harness`]).
  record Harness
    --- A digest of each module of the test harness by its name, source
    --- and bytecode ([`test_key.harness`]): what a worker runs, and the code
    --- that makes and reads its key. build/harness_epoch.tl's
    --- `acknowledged` records them, one to a line between blank ones, so
    --- two changes to different modules of the harness merge cleanly. No
    --- key holds them; each holds the epoch in their place.
    modules: {string:string}
    --- The modules `modules` holds, and those of them the harness runs
    --- -- what every worker loads and `harness_own` -- whose requires
    --- build/harness_epoch_test.tl holds to `names`.
    names: {string}
    runs: {string}
    --- The digest of the code that writes a closure store, which salts
    --- each store's address ([`build.closure_store`]'s `address`).
    store_salt: string
    --- The set of the names of the modules the binary carries, which
    --- [`worker.judge`] holds what a worker loaded to.
    carried: {string:boolean}
  end

  --- What [`test_key.prepare`] made of a job: the command that starts its
  --- worker, or none and why it cannot be started.
  record Prepared
    command: worker.Command?
    --- Why there is no command: the failure the runner records for the test.
    trouble: string
    --- Whether the test is refused for it (its `host` paths cannot be
    --- given, its sandbox's plan is refused) rather than failed.
    refused: boolean
    --- For a worker its module's `noexec` leaves no way to start: why the
    --- host cannot check the test, which the runner records as a skip.
    unavailable: string?
  end

  --- The compiler identities the running binary names
  --- ([`test_key.compiler_identity`]).
  record Compiler
    --- The identity a tree is compiled with.
    tool: string
    --- The identity of what compiled the tree's modules.
    compiled_by: string
  end

  --- The runtime the running binary is: its identity as [`Store.meta`] names
  --- it, and `runtime`, what every key holds of the runtime before the
  --- run's sandbox adds its own part.
  record Runtime
    identity: string
    runtime: string
  end

  --- What [`test_key.begin`] sets of the run's key.
  record Begin
    --- The runtime every key holds ([`Runtime`], as the sandbox's choice
    --- left it).
    runtime: string
    --- Whether each worker runs sandboxed.
    sandbox: boolean
    --- The harness's epoch ([`test_key.epoch_of`]) and the timeout each
    --- worker runs under, which every key holds.
    epoch: string
    timeout_ns: integer
    --- What the binary carries of the harness ([`test_key.binary_harness`]).
    harness: Harness
    --- Whether the tree is cosmic's own.
    own_tree: boolean
  end

  --- What [`test_key.gather`] reads of the run, which the runner has made
  --- by the time every test is keyed.
  record Gather
    --- The working database, and its path for what is said of it.
    records: Sqlite.Handle
    records_path: string
    --- Every module of the tree, and those the run selected.
    modules: {Module}
    selected: {Module}
    --- The projection the closure stores are derived from, the tree's root
    --- and whether it is cosmic's own.
    database: string
    root: string
    own_tree: boolean
    --- The binary's runtime identity, and the compiler's, which the tree is
    --- compiled with and by ([`test_key.compiler_identity`]), under the
    --- checker the run uses (`grammar`), with run-time checks or without.
    identity: string
    tool: string
    compiled_by: string
    grammar: GrammarMode.Mode
    checks: boolean
  end

  --- What the run does with a test once it is keyed ([`test_key.lookup`]).
  enum Outcome
    "run"
    "stand"
    "share"
  end

  --- What a lookup of a test's verdict found ([`test_key.lookup`]).
  record Lookup
    --- The test's key, or nil for one that has none: it reaches a network
    --- beyond loopback, or reads a link out of the tree, so it runs every
    --- time.
    key: string?
    --- The verdict this checkout holds under it, and the one another
    --- checkout reached under it ([`build.shared_verdicts`]), if either.
    own: Verdict?
    elsewhere: shared_verdicts.Found?
    --- Whether the shared verdicts were asked.
    asked: boolean
    --- What the run does with the test: "run" it, "stand" on this
    --- checkout's own passing verdict, or "share" another checkout's.
    outcome: Outcome
  end

  --- How a finished job's worker was judged ([`test_key.judge`]), with what
  --- its verdict turns on: whether it passed, and whether it checked.
  record Judged
    --- What its worker reported, nil where there is no report to go by.
    report: worker.Report?
    --- Whether it passed: a worker's pass that made no call to `assert`
    --- is a failure under a held run.
    passed: boolean
    message: string
    --- Why it checked nothing, where it passed having said so
    --- ([`Test.skip`], or a host that cannot check it), else "": the first
    --- line of what it gave.
    skipped: string
    --- Whether it passed, and was not skipped, without one call to
    --- `assert` ([`worker.Judgement.unchecked`]).
    unchecked: boolean
    --- What it said it deliberately did not check for, "" for none.
    deliberate: string
    --- Whether it checked something: neither skipped nor unchecked. A
    --- verdict is kept only of a test that did ([`test_key.keep`]).
    checked: boolean
  end
end

local type Recording = State.Recording
local type Job = State.Job
local type Unmet = State.Unmet
local type Sealing = State.Sealing
local type Verdict = State.Verdict
local type Harness = test_key.Harness
local type Compiler = test_key.Compiler
local type Prepared = test_key.Prepared
local type Runtime = test_key.Runtime
local type Begin = test_key.Begin
local type Gather = test_key.Gather
local type Outcome = test_key.Outcome
local type Lookup = test_key.Lookup
local type Judged = test_key.Judged

local text = bind.text

-- Key material -- the tool's identity salting a compile, a checkout's
-- id -- is hashed through build.digest, as build.declared_key's is, not
-- cosmic.hash: a key's value turns on no library module outside the
-- harness (`harness`).
local hex_sha256 = hashing.hex_sha256

--- Every verdict ever reached, by key.
function test_key.known_verdicts(handle: Sqlite.Handle): {string:Verdict}?, string
  local rows, trouble = Sqlite.text_rows(handle,
    "SELECT key, passed, run_at_ns, elapsed_ns FROM verdicts")
  if rows == nil then
    return nil, trouble
  end
  local out: mut {string:Verdict} = {}
  for _, row in ipairs(rows) do
    out[row:text(1)] = {
      passed = row:text(2) == "1",
      run_at_ns = math.tointeger(tonumber(row:text(3)) or 0) or 0,
      elapsed_ns = math.tointeger(tonumber(row:text(4)) or 0) or 0,
    }
  end
  return out, ""
end

--- Records one verdict under its key, as relied on by this run.
function test_key.record_verdict(handle: Sqlite.Handle, key: string, passed: boolean,
                                 run_at_ns: integer, run: integer,
                                 elapsed: integer): boolean, string
  return Sqlite.run(handle,
    "INSERT OR REPLACE INTO verdicts (key, passed, run_at_ns, seen, elapsed_ns) " ..
      "VALUES (?1, ?2, ?3, ?4, ?5)",
    { text(key), { integer = if passed then 1 else 0 end }, { integer = run_at_ns },
      { integer = run }, { integer = elapsed } })
end

--- The environment every worker this process starts has
--- ([`test_key.worker_environment`]), which is what a test's read of a
--- variable answers and so what its key holds: defined beside it.
local worker_view: function(): {string:string}

--- What a lookup made inside [`Store.alone`], which hands nothing back,
--- found: the value, or why there is none.
local record Looked<T>
  mut value?: T
  mut trouble: string
end

--- The digest of the zones and CA roots the running binary's own
--- database carries ([`schema.tables_digest`]), searched alone so no
--- attached database stands in for it.
local function binary_tables(): string?, string
  local looked: Looked<Sqlite.Rows> = { trouble = "the running binary has no database" }
  Store.alone(function()
    local databases = Store.databases()
    local binary = databases[#databases]
    if binary ~= nil then
      local has_web, web_trouble = Sqlite.text_rows(binary,
        "SELECT 1 FROM sqlite_master WHERE name = 'web_assets'")
      if has_web == nil then
        looked.trouble = web_trouble
      else
        -- A binary from before the table has no assets to key on.
        looked.value, looked.trouble = Sqlite.text_rows(binary, schema.tables_digest("", #has_web > 0))
      end
    end
  end)
  local rows = looked.value
  if rows == nil then return nil, looked.trouble end
  return rows[1]:text(1), ""
end

--- The modules of the harness beside what every worker loads
--- ([`build.test_worker`]'s [`worker.loads`]): build.test_sandbox and the
--- tree modules it requires, build.test_policy, build.caches and
--- build.zig_caches. build.test_sandbox makes the plan of a worker's
--- sandbox (`plan`): what it binds, unveils and holds, and the
--- environment it gives. build.test_policy turns that plan into the
--- policy a worker is started under.
--- build.caches says where each declared host cache is bound from and
--- makes it; build.zig_caches does so for zig's.
---
--- What else of the runner shapes a worker is the worker's own module's,
--- which [`worker.loads`] names: its command line and start options, and
--- how its report is read into a verdict ([`worker.invocation`],
--- [`worker.judge`]). The runner ([`build.test`]) passes it only what a key
--- holds by itself (the test's declaration, its closure's names, which
--- the store's address holds, whether it may run this program
--- ([`Spec.runs_tool`]), and its timeout) or what [`key_code`] holds (the
--- names of the tree's modules, which decide what a worker refuses a
--- `require` of).
---
--- None of it is keyed by its code: the epoch stands for it
--- (build/harness_epoch.tl), and an edit to it fails
--- build/harness_epoch_test.tl until the epoch is bumped or the edit
--- acknowledged. That test also fails where a module here or in
--- [`worker.loads`] requires one of the tree the harness does not name.
-- TODO: key the sandbox's plan as data -- its unveils and binds, with
-- the tree, the scratch directory and the host caches named relative to
-- what they stand for, and its environment -- rather than leaving it to
-- the epoch, once the caches' binds name no host location:
-- then a change to a hold or a bind moves every key it touches by
-- itself, where today it moves none unless someone bumps the epoch by
-- hand.
local harness_own <const>: {string} = { "build.test_sandbox", "build.test_policy",
  "build.caches", "build.zig_caches" }

--- The modules of the harness held alone, by their own source and
--- bytecode, their requires not walked: cosmic.child, whose `start`
--- turns a worker's policy into what spawn holds it to -- the
--- unveils, the binds, offline -- so an edit
--- that weakened it would pass a test that reads what it does not
--- declare, and keep and share the pass. What it requires (cosmic.time,
--- cosmic.stream and the rest) applies no sandbox, and stays out. The
--- exceptions are cosmic.sandbox and cosmic.sandbox.policy, held alone
--- too: the policy layer's `merge` (and the profiles it joins, "system"'s
--- paths among them) and `check`, which cosmic.sandbox answers under its
--- own name, and cosmic.sandbox's `loaders`, `reach` and `user_id`, decide
--- what a worker started under a policy may reach, and
--- [`test_policy.runs`] merges a policy through them. Their other requires
--- are not walked, and none of those decides a grant: cosmic.sandbox.seatbelt
--- compiles a profile only on macOS, where no worker is sandboxed, so it
--- is not held (build/harness_epoch_test.tl's `unheld_split` says so too).
-- TODO: move the translation of a worker's policy into spawn's
-- options into build.confine, which the harness holds already, and
-- drop cosmic.child from here and from build/harness_epoch.tl's
-- `library`, once cosmic.child's `start` takes spawn's sandbox as it is
-- (the TODO above its `raw.spawn` call, which would offer the rest of
-- it): today only cosmic.child reaches spawn for the runner.
local harness_alone <const>: {string} = { "cosmic.child", "cosmic.sandbox",
  "cosmic.sandbox.policy" }

--- The code that makes a key and looks a verdict up under one:
--- build.test_key itself, held alone, and the closure of the key's
--- computation ([`build.declared_key`]) and of the shared verdicts'
--- ([`build.shared_verdicts`]), and of what the host answers a module's
--- requirements ([`build.host_requires`]), which a key holds, as the
--- `imports` table has it.
--- What this module decides of a worker's hold is part of it: which
--- names of the tree a `require` refuses (`tree_names`).
---
--- A key is looked up by its value, but that is not enough. A version
--- of this code that maps some inputs to the key another version
--- computes for other inputs (a digest that misses a rewrite, say)
--- keeps a verdict under that key, in build.db and in the verdicts
--- every checkout shares, which would stand after a fix. So a fix to it
--- bumps the epoch (build/harness_epoch.tl), which every key holds.
--- Every version of it is in the harness's digests, which
--- build/harness_epoch_test.tl holds to what was acknowledged: an edit
--- to any of it, a comment's too, fails that test until someone says
--- whether it can move a verdict.
-- TODO: walk build.test_key as `key_roots` are, so what it requires is
-- held and bound by build/harness_epoch.tl's `library` rule, once it takes
-- what it needs of build.importer, build.closure_store, build.schema,
-- cosmic.store and cosmic.clock from the modules the harness holds or
-- from raw bindings: held alone, as build.test was whole, what it requires
-- beyond [`key_code`] is outside the rule.
local key_roots <const>: {string} = { "build.declared_key", "build.shared_verdicts",
  "build.host_requires" }
local key_own <const>: {string} = { "build.test_key" }

--- The module that holds the epoch and the acknowledged digests, which
--- the digests leave out: it would hold itself.
local epoch_module <const> = "build.harness_epoch"

--- The code that writes a closure store: build.closure_store's and the
--- schema it writes it by ([`build.schema`]).
---
--- The store's address holds the rows it carries by their digests
--- ([`closure_store.basis`]), but not which of them, nor which tables,
--- that code copies: a table added to what it copies would move no
--- address. The projection's writer ([`build.writer`]) is none of this
--- code. What it writes reaches a store only through rows and orderings
--- the basis digests: each module's columns, its source's stored bytes
--- among them, and its own docs, catalog and examples in their order,
--- while build.closure_store orders them across modules itself. So an
--- edit to the writer that writes the same rows moves no address, and
--- one that writes others moves only the addresses of the closures that
--- carry them.
---
--- The salt holds the code that writes a closure store with all it
--- requires ([`store_code`]), each module by its source and bytecode.
--- It salts where a store is, not what a key holds of it: what
--- build.closure_store writes passes through cosmic.sqlite, cosmic.fs
--- and cosmic.hash, and an edit to one of them (how a blob is bound, a
--- pragma set) can change a store's bytes while every row's digest
--- stays, so an edit to any of that code writes every store again, at
--- a new address. A key holds each store by its bytes
--- ([`declared_key.store_digest`]), so only an edit that changes them
--- -- not a comment in build/schema.tl -- runs a test again.
local store_writer <const>: {string} = { "build.closure_store", "build.schema" }

--- The names `roots` and `own` hold: each root and every module it
--- requires, directly or not, by `imports` (the names each module
--- requires), and each of `own` alone.
local function closure_of(roots: {string}, own: {string},
                          imports: {string:{string}}): {string}
  local seen: mut {string:boolean} = {}
  local names: mut {string} = {}
  local stack: mut {string} = {}
  for _, name in ipairs(own) do
    seen[name] = true
    names[#names + 1] = name
  end
  for _, name in ipairs(roots) do stack[#stack + 1] = name end
  while #stack > 0 do
    local name = table.remove(stack)
    if seen[name] ~= true then
      seen[name] = true
      names[#names + 1] = name
      for _, required in ipairs(imports[name] or {}) do stack[#stack + 1] = required end
    end
  end
  return names
end

-- The `imports` rows whose importer is a module or main with no
-- occurrence of the required name in its bytecode: Teal erased the
-- require, so the edge is by type alone. [`test_key.value_imports`] keeps
-- the rows this does not match and [`test_key.type_only_imports`] the rows
-- it does, so the two cannot drift apart.
local erased_require = "(SELECT 1 FROM modules m WHERE m.path = i.path " ..
  "AND m.kind IN ('module', 'main') " ..
  "AND instr(inflate(m.bytecode), CAST(i.requires AS BLOB)) = 0)"

--- The `imports` rows of `db` a module makes by value, by importer: an
--- edge is kept unless the importer's bytecode lacks the name it
--- requires as a string constant. Teal erases a `local type` require,
--- and what the imported type does at run time -- an `is` against a
--- record's `where`, an enum's test -- is compiled into the importer's
--- bytecode, which the harness's digests hold. Any other spelling of a
--- require (`require"x"`, one split across lines, one inside a
--- function) leaves the name in the bytecode, and so does a name that
--- is only a string there: the test errs toward following an edge.
function test_key.value_imports(db: Sqlite.Handle): {string:{string}}?, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT i.path, i.requires FROM imports i WHERE NOT EXISTS " .. erased_require)
  if rows == nil then return nil, trouble end
  local out: mut {string:mut {string}} = {}
  for _, row in ipairs(rows) do
    local list = out[row:text(1)] or {}
    out[row:text(1)] = list
    table.insert(list, row:text(2))
  end
  return out, ""
end

--- The `imports` rows of `db` a module makes by type alone, as sets by
--- importer: the complement of [`test_key.value_imports`], and no other
--- rows. A test's closure leaves these edges out
--- ([`build.test_inputs`]'s `closure`): an importer that requires a
--- module only to name its types runs without loading it, so an edit to
--- it that leaves the importer's bytecode as it was moves no key, and a
--- test importing the importer is not run again for it.
function test_key.type_only_imports(db: Sqlite.Handle): {string:{string:boolean}}?, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT i.path, i.requires FROM imports i WHERE EXISTS " .. erased_require)
  if rows == nil then return nil, trouble end
  local out: mut {string:mut {string:boolean}} = {}
  for _, row in ipairs(rows) do
    local set = out[row:text(1)] or {}
    out[row:text(1)] = set
    set[row:text(2)] = true
  end
  return out, ""
end

--- [`test_key.type_only_imports`] of the projection at `path`.
local function projection_type_only(path: string): {string:{string:boolean}}?, string
  local opened, trouble = Sqlite.open(path)
  if opened == nil then return nil, path .. ": " .. trouble end
  local db: Sqlite.Handle = opened
  local found, found_trouble = test_key.type_only_imports(db)
  local _, _ = db:close()
  if found == nil then return nil, found_trouble end
  return found, ""
end

--- The names `key_roots` and `key_own` hold ([`closure_of`]), over the
--- requires each module makes by value ([`test_key.value_imports`]).
local function key_code(by_value: {string:{string}}): {string}
  return closure_of(key_roots, key_own, by_value)
end

--- The names `store_writer` holds, with what they require ([`closure_of`]).
local function store_code(imports: {string:{string}}): {string}
  return closure_of(store_writer, {}, imports)
end

--- The digests of the test harness's modules and that of the code that
--- writes a closure store ([`Harness`]), over the modules `db` holds, by
--- their `modules` and `imports` rows. `db` is the running binary's
--- database ([`binary_harness`], which fills in `carried`), or the
--- projection, o/cosmic.db, which build/harness_epoch_test.tl reads.
---
--- Each module of the harness is held by its name, its source's hash and
--- its bytecode's, a digest to each (`modules`). That covers what a
--- worker loads, `harness_own`, `harness_alone` and [`key_code`], but not
--- build.harness_epoch, which records the digests. Each digest is the
--- same wherever the tree is, and a compiler that makes other bytecode
--- of the same source moves it as an edit does. The salt holds each
--- module of the store's writer the same way ([`store_code`]), as the
--- store's bytes follow from both. Nil and why where a module either
--- names is none `db` carries, which the digests or the salt would
--- otherwise leave out unnoticed.
function test_key.harness(db: Sqlite.Handle): Harness?, string
  local modules, trouble = Sqlite.text_rows(db,
    "SELECT path, source_hash, lower(hex(sha256(inflate(bytecode)))) FROM modules " ..
      "WHERE kind IN ('module', 'main')")
  if modules == nil then return nil, trouble end
  local imported, imports_trouble = Sqlite.text_rows(db, "SELECT path, requires FROM imports")
  if imported == nil then return nil, imports_trouble end
  local sources: mut {string:string} = {}
  local compiled: mut {string:string} = {}
  local carried: mut {string:boolean} = {}
  for _, row in ipairs(modules) do
    sources[row:text(1)] = row:text(2)
    compiled[row:text(1)] = row:text(2) .. " " .. row:text(3)
    carried[row:text(1)] = true
  end
  local imports: mut {string:{string}} = {}
  for _, row in ipairs(imported) do
    local list = imports[row:text(1)] or {}
    imports[row:text(1)] = list
    local second = row:text(2)
    list[#list + 1] = second
  end
  local names: mut {string} = {}
  local runs: mut {string} = {}
  for _, list in ipairs({ worker.loads, harness_own }) do
    for _, name in ipairs(list) do runs[#runs + 1] = name end
  end
  local by_value, value_trouble = test_key.value_imports(db)
  if by_value == nil then return nil, value_trouble end
  for _, list in ipairs({ worker.loads, harness_own, harness_alone, key_code(by_value) }) do
    for _, name in ipairs(list) do
      if sources[name] == nil then
        return nil, name .. ", which a worker runs or which makes or reads a key, " ..
          "is no module the binary carries"
      end
      if name ~= epoch_module then names[#names + 1] = name end
    end
  end
  local each: mut {string:string} = {}
  for _, name in ipairs(names) do each[name] = declared_key.harness({ name }, compiled) end
  local salted = store_code(imports)
  for _, name in ipairs(salted) do
    if compiled[name] == nil then
      return nil, name .. ", which writes a closure store, is no module the binary carries"
    end
  end
  return { modules = each, names = names, runs = runs,
    store_salt = declared_key.harness(salted, compiled), carried = carried }, ""
end

--- What of the running binary a run holds of the code a worker runs
--- ([`Harness`]), searched alone so no attached database stands in for
--- it. What a worker runs is what every worker loads ([`worker.loads`]),
--- which [`worker.judge`] holds each worker to, and `harness_own`; no
--- `imports` closure of it is walked, which would follow the requires
--- a worker never runs: Teal erases a `local type` one, and what an
--- imported type does at run time (an `is` against a record's `where`,
--- an enum's test) is compiled into the importer's bytecode. None of it
--- is keyed by what it is: the epoch stands for it
--- (build/harness_epoch.tl).
function test_key.binary_harness(): Harness?, string
  local looked: Looked<Harness> = { trouble = "the running binary has no database" }
  Store.alone(function()
    local databases = Store.databases()
    local binary = databases[#databases]
    if binary == nil then return end
    looked.value, looked.trouble = test_key.harness(binary)
  end)
  local harness = looked.value
  if harness == nil then return nil, looked.trouble end
  return harness, ""
end

--- The harness's epoch every key holds (build/harness_epoch.tl), or
--- the one COSMIC_TEST_HARNESS_EPOCH names in its place, for a test
--- alone, which stands in for a bump without a binary of its own
--- (build/sandboxed_verdicts_test.tl): a count, a dash and hex digits,
--- as the file's is, so the census and key-parts lines, which say it
--- as one word, stay parseable. Nil and why for another.
function test_key.epoch_of(): string?, string
  local named = Env.read("COSMIC_TEST_HARNESS_EPOCH") or ""
  if named == "" then return harness_epoch.epoch, "" end
  if not named:match("^%d+%-%x+$") then
    return nil, string.format("COSMIC_TEST_HARNESS_EPOCH is %q, not a count, a dash and " ..
        "hex digits, as build/harness_epoch.tl's `epoch` is", named)
  end
  return named, ""
end

--- The word the census and key-parts lines say a key's harness parts
--- as (`cosmic test --census`): its epoch and the workers' timeout, one
--- word, which ci/cosmic_ci/report.tl compares whole, so a bump from
--- the same count says a moved harness.
function test_key.harness_word(epoch: string, timeout_ns: integer): string
  return string.format("e%s-t%d", epoch, timeout_ns)
end

--- The environment the workers of `m`'s tests are given, which a
--- variable they read is keyed by: what a sandbox gives one
--- ([`test_sandbox.environment`]), TMPDIR its scratch directory; one
--- unsandboxed has the host's cores cache in place of the sandbox's own
--- ([`test_sandbox.unenforced_view`]), as it is given.
local function view_of(rec: Recording, m: Module): {string:string}
  local view = rec.views[m.path]
  if view == nil then
    local effective = rec.effective[m.path]
    view = rec.sandbox and test_sandbox.environment(worker_view(), effective) or
      test_sandbox.unenforced_view(worker_view(), effective)
    rec.views[m.path] = view
  end
  return view
end

--- Where the tree is, for a `host` path that must not be it, beneath
--- it or above it ([`test_inputs.resolved`]): its path and where that
--- resolves.
local function tree_roots(rec: Recording): {string}
  return { rec.root, confine.resolution(rec.root) }
end

--- Why `m`'s `host` paths cannot all be given to its workers
--- ([`test_inputs.resolved`]): "" where they can. Every test of such a
--- module fails before its worker starts, sandboxed or not.
local function unresolved(rec: Recording, m: Module): string
  local effective = if rec.effective ~= nil then rec.effective[m.path] else nil end
  if effective ~= nil then return effective.unresolved or "" end
  local inputs = m.inputs
  for _, declared in ipairs(if inputs ~= nil then inputs.host else {} end) do
    local path, trouble = test_inputs.resolved(declared, tree_roots(rec))
    if path == nil then return trouble end
  end
  return ""
end

--- Where the host caches `m` declares are ([`build.caches`]), as every
--- worker's environment locates them: what its test may read and write
--- that no key holds.
local function caches_of(rec: Recording, m: Module): {string}
  local found = rec.caches[m.path]
  if found == nil then
    local declared = m.inputs
    found = if declared ~= nil then host_caches.all(declared.caches, rec.root, worker_view()) else {} end
    rec.caches[m.path] = found
  end
  return found
end

--- Stops using the shared verdicts for the rest of the run, saying why
--- once: a cache that cannot answer -- corrupt, or another format's --
--- costs the run nothing but what it would have saved.
local function drop_shared(rec: Recording, trouble: string)
  local shared = rec.shared
  if shared == nil then return end
  local path = shared.path
  shared_verdicts.close(shared)
  rec.shared = nil
  -- TODO: retire broken caches automatically once cache-wide lifetime
  -- ownership and identity checks can exclude concurrent users and replacements.
  log:complain("test: shared verdicts: " .. path .. ": " .. trouble ..
      "; running without them")
end

--- The program running the tests, which `tool` declares, found the first
--- time a key or a hold needs it.
local function tool_of(rec: Recording): {string}
  local tool = rec.tool
  if tool == nil then
    tool = confine.itself()
    rec.tool = tool
  end
  return tool
end

--- The digests of the tree's files the run keys by, which
--- the runner's `gather_key_inputs` takes before any test is keyed.
function test_key.digests_of(rec: Recording): declared_key.Digests
  return (assert(rec.digests, "test: no key is made before the inputs of the keys are gathered"))
end
local digests_of = test_key.digests_of

--- The projection the closure stores are derived from, which the run
--- sets before it keys any test ([`Recording.projection`]).
local function projection_of(rec: Recording): string
  return (assert(rec.projection, "test: no store is made before the run has its projection"))
end

--- Counts the time since `started` as spent keying ([`declared_key.Digests`]'s
--- `spent_ns`).
local function charge_keying(rec: Recording, started: integer)
  local digests = digests_of(rec)
  digests.spent_ns = digests.spent_ns + (Clock.monotonic_ns() - started)
end

--- Whether a sandboxed worker of `m`'s tests can be kept from running
--- this program where its module does not declare `tool`
--- ([`confine.forbid_running`]): not where it may write a directory
--- the program is in ([`test_sandbox.forbiddable`]), since a core another
--- cosmic extracts there after the worker holds itself could not be
--- run. The cores a portable cosmic extracts, where the program's own
--- core is, are none of them: a worker that declares the `bootstrap`
--- cache has cores of its own ([`test_sandbox.cache_writes`]). Such a
--- worker is keyed as if it declared `tool` instead.
local function can_forbid(rec: Recording, m: Module): boolean
  local found = rec.forbiddable[m.path]
  if found ~= nil then return found end
  found = test_sandbox.forbiddable(test_sandbox.cache_writes(rec.effective[m.path],
    worker_view()), tool_of(rec))
  rec.forbiddable[m.path] = found
  return found
end

--- Whether a worker of `m`'s tests runs on a sealed database of its
--- closure ([`sealed_for`]): the program's core on that database
--- (`core --database`) with nothing of the program's file, so what the
--- worker and every process it starts reads of the program is what its
--- key holds -- its closure's store and the modules every worker loads. It
--- is so wherever the worker is given a closure's store and runs
--- not this program (`tool`), and this program is a portable artifact
--- whose database and core there are to take; a worker that confines
--- processes in roots of its own (`nests`) is sealed too, its policy
--- carrying `nest` beside the `database`. Its key holds the
--- core in place of the launcher ([`declared_of`]), which no such worker
--- runs. Every other worker runs the program.
function test_key.seals(rec: Recording, m: Module): boolean
  local effective = rec.effective[m.path]
  if rec.launcher == nil or rec.stores == nil or rec.stores[m.path] == nil or
      effective == nil or effective.store or effective.tool then
    return false
  end
  local launched, _ = Proc.relaunch()
  return launched ~= nil and launched.argv[2] == "--artifact" and launched.argv[3] ~= nil
end
local seals = test_key.seals

--- How a sandboxed worker of `m`'s tests stands to running this
--- program: "declared" where its module declares `tool`; "sealed" where
--- it declares `lua` or `nests` and runs on a sealed database of its
--- closure ([`sealed_for`]), which it may run the core on but which holds no
--- more of the program than its closure, so its key holds no more;
--- "forbidden" where it is kept from running it ([`can_forbid`]), and
--- "allowed" where it is not -- its module declares `nests` or `lua` and
--- runs the program whole, or it cannot be -- which its key holds as if
--- its module declared `tool` ([`Spec.runs_tool`]). Its key and its command
--- line ([`hold_of`]) both take it from here.
local enum ToolUse
  "declared"
  "sealed"
  "forbidden"
  "allowed"
end

local function tool_use(rec: Recording, m: Module): ToolUse
  local effective = rec.effective[m.path]
  if effective.tool then return "declared" end
  if effective.lua == true or effective.nests == true then
    return if seals(rec, m) then "sealed" else "allowed" end
  end
  return if can_forbid(rec, m) then "forbidden" else "allowed" end
end

--- How a worker of `m`'s tests is held by a Landlock ruleset
--- ([`worker.Hold`]): not at all unsandboxed, nor where its module declares
--- `nests`, which lets its tests confine a process in a root of its own;
--- to running anything but this program where it may not run it
--- ([`tool_use`]); and otherwise to running anything, which holds it to
--- making no root of its own, since the kernel refuses every mount under
--- a ruleset.
local function hold_of(rec: Recording, m: Module): worker.Hold
  if not rec.sandbox or rec.effective[m.path].nests == true then return "none" end
  return if tool_use(rec, m) == "forbidden" then "forbid" else "mounts" end
end

--- Whether a worker of `m`'s tests can read the compiler's identity,
--- which it reads from the running tool ([`declared_key.reads_compiler`]):
--- not one given the whole projection, which carries its own and is
--- keyed by its contents; nor one whose closure holds a reader only by
--- what `lua` adds to it ([`test_inputs.compiler_sought`]).
local function reads_compiler(rec: Recording, m: Module): boolean
  if rec.stores[m.path] == nil then return false end
  return declared_key.reads_compiler(test_inputs.compiler_sought(rec.closures[m.path] or {},
    rec.effective[m.path].lua))
end

--- The digest of the modules of the program's own database that the tree
--- lacks -- the standard library, in a project's tree -- by path, source
--- hash, bytecode, stub and the edges the checker follows from it
--- (`decl_imports`), which a sealed database carries whole
--- ([`sealed_fill`]) and so a key of a worker on one holds
--- ([`declared_of`]). Worked out once a run needs it, from the program's
--- own database, which sealing nothing reads; "unread" where it cannot be.
local function extras_digest(rec: Recording): string
  local extras = rec.extras
  if extras ~= nil then return extras end
  local databases = Store.databases()
  local query = "SELECT path, lower(hex(source_hash)), lower(hex(sha256(inflate(bytecode)))), " ..
    "coalesce((SELECT group_concat(requires, ' ' ORDER BY requires) FROM decl_imports d " ..
    "WHERE d.path = modules.path), '')"
  -- With its stub ([`sealed_fill`] carries it), where the program has
  -- them: a program from before `stubs` has no such table to read.
  local rows, _ = Sqlite.text_rows(databases[#databases], query ..
      ", coalesce((SELECT lower(hex(sha256(source))) FROM stubs s WHERE s.path = modules.path), '') " ..
      "FROM modules ORDER BY path")
  if rows == nil then
    rows, _ = Sqlite.text_rows(databases[#databases], query .. " FROM modules ORDER BY path")
  end
  local digest = "unread"
  if rows ~= nil then
    local in_tree: mut {string:boolean} = {}
    for _, name in ipairs(rec.tree_names) do in_tree[name] = true end
    local lines: mut {string} = {}
    for _, row in ipairs(rows) do
      if in_tree[row:text(1)] ~= true then
        lines[#lines + 1] = table.concat(row:texts(), "\0")
      end
    end
    digest = hex_sha256(table.concat(lines, "\n"))
  end
  rec.extras = digest
  return digest
end

--- The digest of the store `m`'s workers are given, which its key holds
--- (defined with the stores, below).
local store_digest: function(rec: Recording, m: Module): string?, string

--- The program a test that runs this program runs
--- ([`Recording.program`]), worked out the first time a key holds it.
--- Digesting the program reads every row its database carries, some
--- 0.2 s, which a run none of whose tests runs it need not spend.
function test_key.program_of(rec: Recording): string
  local program = rec.program
  if program == nil then
    program = declared_key.program_identity(digests_of(rec), tool_of(rec))
    rec.program = program
  end
  return program
end
local program_of = test_key.program_of

--- A sandboxed test's key, over its declared inputs as they are now
--- ([`build.declared_key`]): nil for one that reads a link out of the
--- tree, which no key holds, said once in `rec.unkeyed`.
---
--- A key holds a file of the tree by its contents, and none of what a
--- stat says of it but what its declared inputs' digests do, so a
--- verdict one checkout reached stands in another of the same content.
--- The rule that makes that sound: a test must not depend on the times,
--- inode, device, link count or owner of a file it did not make. One
--- that needs them makes its own files in its temporary directory and
--- sets them -- `utimensat` for the times, a fresh file for a new inode
--- -- so they are the same in every checkout.
-- TODO: enforce the rule in the worker, which holds only `require` to its
-- closure today: have `stat`, `lstat` and `fstat` of a path of the tree
-- answer fixed times and inode there, once core/syscalls_fs.c's stat takes a
-- hold from build.test_worker (C, and a boot):
-- today a test that leans on a file of the tree's times sees what its
-- checkout gave it, and stands on a sibling's verdict where they differ.
local function declared_of(rec: Recording, m: Module, id: string, host?: string): string?
  local effective = rec.effective[m.path]
  local runs_tool = tool_use(rec, m) == "allowed"
  local store, store_trouble = store_digest(rec, m)
  if store == nil and store_trouble ~= "" then
    rec.unkeyed[m.path] = store_trouble
    return nil
  end
  local key, why = declared_key.compute(digests_of(rec), {
    id = id, group = m.path, module_key = assert(m.graph_key), runtime = rec.runtime,
    compiler = reads_compiler(rec, m) and rec.compiler or "",
    host = host or rec.host,
    system = rec.system,
    epoch = rec.epoch, timeout_ns = rec.timeout_ns,
    -- Held only where the key holds the program ([`declared_key.compute`]).
    program = (effective.tool or runs_tool) and program_of(rec) or nil,
    launcher = if seals(rec, m) then (assert(rec.core) .. "\0" .. extras_digest(rec)) else rec.launcher end,
    declaration = test_inputs.canonical(m.inputs), effective = effective,
    requires = rec.answered[m.path],
    environment = view_of(rec, m), runs_tool = runs_tool,
    closure_store = store,
    -- Unsandboxed, its worker sees the tree where it is (`launch`).
    tree = not rec.sandbox and rec.root or nil,
  })
  if key == nil then rec.unkeyed[m.path] = why end
  return key
end

--- The set of the names of `m`'s import closure (`closures`), made
--- once a run.
local function closure_set(rec: Recording, m: Module): {string:boolean}
  local set = rec.closure_sets[m.path]
  if set == nil then
    set = {}
    for _, name in ipairs(rec.closures[m.path] or {}) do set[name] = true end
    rec.closure_sets[m.path] = set
  end
  return set
end

--- What of this process's environment says how it was started and
--- nothing a test is given: the marker a tool that rebuilt itself sets
--- for the process it re-enters ([`build.reboot`]), which a run started
--- after a rebuild holds and one started fresh does not, and the
--- directory the invoking shell was in before its last `cd`, and the
--- command it last ran (`_`, which a shell sets to the program it
--- starts: /usr/bin/timeout for `timeout 30 cosmic test`). Kept, each
--- would enter the key of a test that declares it, and such a test would
--- run again after a rebuild, a `cd`, or a run started another way. So too
--- the shell's depth (`SHLVL`): a run from a script, rather than a
--- terminal, would run such a test again.
local launch_only: {string:boolean} = { COSMIC_REBOOTED = true, OLDPWD = true, SHLVL = true, _ = true }

--- The environment a worker starts with: this process's, less
---
--- - the private startup hooks (`COSMIC_PORTABLE_STARTUP_TEST_*`), which
---   pause one startup of a fixture runtime for a handshake and belong to
---   this process's own launch, not to every worker it starts;
--- - what `launch_only` names; and
--- - COSMIC_TEST_NO_SHARED, COSMIC_TEST_FOREIGN_FEATURES and COSMIC_TEST_BAIL;
--- - COSMIC_TEST_CHECK_TYPES and COSMIC_TEST_TYPES, which ask for a checked
---   run and tell its workers to report one;
---
--- and with the shared verdict cache off (`COSMIC_VERDICT_CACHE=0`) and
--- the shared compiles too (`COSMIC_BUILD_CACHE=0`).
function test_key.worker_environment(environment: {string:string}): {string:string}
  local out: mut {string:string} = {}
  for name, value in pairs(environment) do
    if name:sub(1, 29) ~= "COSMIC_PORTABLE_STARTUP_TEST_" and launch_only[name] ~= true then
      out[name] = value
    end
  end
  -- A run of `cosmic test` a test starts neither reads nor writes the
  -- verdicts every checkout shares, unless the test names a cache of
  -- its own.
  shared_verdicts.turn_off(out)
  -- Nor the compiles and parses every checkout shares: a build a test
  -- starts compiles and parses what it does, and reaches no file
  -- outside what the test declares, unless the test names a cache of
  -- its own.
  shared_compiles.turn_off(out)
  -- Nor does it take this run's choice not to stand on them: a test
  -- that runs `cosmic test` says for itself what that run does.
  out.COSMIC_TEST_NO_SHARED = nil
  out["COSMIC_TEST_FOREIGN_FEATURES"] = nil
  out.COSMIC_TEST_BAIL = nil
  -- Nor whether this run compiles its tree with run-time checks, and its
  -- workers report them: a `cosmic test` a test starts compiles its tree
  -- as that run is told.
  out.COSMIC_TEST_CHECK_TYPES = nil
  out.COSMIC_TEST_TYPES = nil
  out.COSMIC_TEST_NOEXEC = nil
  out.COSMIC_TEST_PARENT = nil
  -- Nor a rebuild lock handed to this run (build.rebuild_lock): what a
  -- test starts holds none of this run's.
  return rebuild_lock.unhanded(out)
end

-- Read once, since this process never changes its own environment.
local worker_view_memo: mut {{string:string}} = {}
function test_key.worker_view(): {string:string}
  if worker_view_memo[1] == nil then
    worker_view_memo[1] = test_key.worker_environment(Env.all())
  end
  return worker_view_memo[1]
end
worker_view = test_key.worker_view

--- A fresh scratch directory for one test, resolved (so nothing in
--- its own path is a link, even where the system temp directory is
--- one), holding `real`, an empty directory, and `tmp`, a link to it
--- by the relative name `real`: the test is handed `<scratch>/tmp`.
--- The worker makes `children` there for the coverage its test's
--- processes report.
--- Removing the scratch directory with [`Fs.remove_tree`] removes the
--- link without following it, and the real directory beside it.
-- TODO: keep the link, which a sandboxed worker sees in [`test_sandbox.scratch`] as an
-- unsandboxed one sees it under the host's temporary directory: it
-- stands in for macOS's /var on every host, and does not depend on
-- where the checkout is. Drop it only once a case of its own on the
-- macOS leg catches a path resolved on one side of a comparison and not
-- the other, which the link catches on every leg today.
function test_key.scratch(): string?, string
  -- Padded so the scratch directory's path is as long on this host as
  -- a sandbox's is, and as macOS's is ([`test_sandbox.scratch_length`]),
  -- past the temporary directory's resolved path and mkdtemp's six.
  local base, base_trouble = Fs.absolute(Env.read("TMPDIR") or "/tmp")
  if base == nil then return nil, base_trouble end
  local separator = if base:sub(-1) == "/" then 0 else 1 end
  local made, trouble = Fs.mkdtemp(test_sandbox.padded("cosmic-test-",
    test_sandbox.scratch_length - #base - separator - 6))
  if made == nil then return nil, trouble end
  local scratch, absolute_trouble = Fs.absolute(made)
  if scratch == nil then
    local _, _ = Fs.remove_tree(made)
    return nil, absolute_trouble
  end
  local ok, why = Fs.mkdirs(scratch .. "/real")
  if ok then ok, why = Fs.symlink("real", scratch .. "/tmp") end
  if not ok then
    local _, _ = Fs.remove_tree(scratch)
    return nil, why
  end
  return scratch, ""
end

--- Where the tree at `root` keeps the stores of its test modules'
--- import closures, each named by its address ([`build.closure_store`]'s
--- `address`).
local function stores_directory(root: string): string
  return build_paths.resolve(root).stores
end

--- The name in the stores directory of the store of no module
--- ([`Recording.base_store`]), at `address`: apart from the closures'
--- stores, which this run's counts and a test's listing of them leave it
--- out of.
local function base_name(address: string): string
  return "base-" .. address .. ".db"
end

--- The address of the closure store of each test and example module of
--- `modules` that does not declare `store`, by path, over the
--- projection `rec.projection` ([`closure_store.basis`]): every one the tree
--- has, selected or not, so a run that selects some leaves the others'
--- stores, and [`sweep_stores`] takes out only what no module names.
local function address_stores(rec: Recording, modules: {Module},
                              by_path: {string:Module},
                              declarations: {string:string}): boolean, string
  local basis, trouble = closure_store.basis(projection_of(rec))
  if basis == nil then return false, trouble end
  rec.basis = basis
  -- The code that writes a store, and the core that runs it -- SQLite
  -- and its bindings -- whose bytes it follows from too: so one address
  -- names one store's bytes wherever it is written, which a digest kept
  -- by address relies on ([`address_digest`]).
  local salt = hex_sha256(rec.store_salt .. "\0" .. assert(rec.store_runtime))
  rec.base_store = closure_store.address(basis, {}, salt)
  for _, m in ipairs(modules) do
    local declared = m.inputs
    if (m.kind == "test" or m.kind == "example") and
        not (declared ~= nil and declared.store) then
      local names = rec.closures[m.path] or
        test_inputs.modules(m, by_path, declarations, rec.type_only)
      rec.closures[m.path] = names
      rec.stores[m.path] = closure_store.address(basis, names, salt)
    end
  end
  return true, ""
end

--- Takes out of the stores directory every entry no module of this run
--- names ([`address_stores`]): a closure edited since, or a module gone,
--- leaves a store nothing will ask for again, and one cut short (a
--- `.building` file) is written again from the start. A failure to
--- take one out costs only room, and is said once.
local function sweep_stores(rec: Recording)
  local directory = stores_directory(rec.root)
  local named: mut {string:boolean} = {}
  for _, address in pairs(rec.stores) do named[address .. ".db"] = true end
  named[base_name(assert(rec.base_store))] = true
  local listed, _ = Fs.list(directory)
  for _, entry in ipairs(listed or {}) do
    -- One kept aside for a report ([`mismatch_path`]) stays until removed.
    if named[entry] ~= true and not entry:match("%.mismatch%.db$") then
      local gone, trouble = Fs.remove(directory .. "/" .. entry)
      if not gone then
        log:complain("test: " .. directory .. "/" .. entry .. ": " .. trouble)
        return
      end
    end
  end
end

--- The database the closure stores of this run are extracted with: the
--- projection's `uses` keyed by the module that makes them
--- ([`closure_store.extract`]), made on the first store written, so a
--- run that stands on every store makes none, and removed when the run
--- ends ([`drop_extraction`]). Apart from the stores directory, whose
--- every other entry [`sweep_stores`] takes out. Nil and why where it
--- could not be made.
local function extraction_for(rec: Recording): string?, string
  local extraction = rec.extraction
  if extraction ~= nil then return extraction, "" end
  local path = build_paths.resolve(rec.root).uses
  local made, trouble = closure_store.extract(projection_of(rec), path)
  if not made then return nil, "the index of the uses by source module: " .. trouble end
  rec.extraction = path
  return path, ""
end

--- Removes the database [`extraction_for`] made, if it made one.
local function drop_extraction(rec: Recording)
  local extraction = rec.extraction
  if extraction == nil then return end
  local _, _ = Fs.remove(extraction)
  rec.extraction = nil
end

--- The path of the closure store at `address`, of the import closure
--- `names`, made from the projection where it is not there yet --
--- written aside and moved into place, so a store there is whole; nil
--- and why where it could not be made. `base` names the store of no
--- module ([`base_name`]), which the counts of stores written leave out.
local function store_at(rec: Recording, address: string, names: {string},
                        base?: boolean): string?, string
  local path = rec.built[address]
  if path ~= nil then return path, "" end
  local directory = stores_directory(rec.root)
  path = directory .. "/" .. (base and base_name(address) or (address .. ".db"))
  local there, _ = sys.stat(path)
  if there == nil then
    local made, trouble = Fs.mkdirs(directory)
    if not made then return nil, directory .. ": " .. trouble end
    local started = Clock.monotonic_ns()
    local extraction, extraction_trouble = extraction_for(rec)
    if extraction == nil then return nil, extraction_trouble end
    local written, write_trouble = closure_store.write(projection_of(rec), path, names, assert(rec.basis),
      extraction)
    if not written then return nil, "the store of its closure: " .. write_trouble end
    if base ~= true then
      rec.writing_ns = rec.writing_ns + (Clock.monotonic_ns() - started)
      local wrote, _ = sys.stat(path)
      rec.written = rec.written + 1
      rec.written_bytes = rec.written_bytes + (wrote ~= nil and wrote.size or 0)
    end
  end
  rec.built[address] = path
  return path, ""
end

--- The path of the closure store a worker of `m`'s tests is given
--- ([`store_at`]), or nil where `m` declares `store` and is given the
--- whole projection; nil and why where it could not be made.
local function given_store(rec: Recording, m: Module): string?, string
  local address = rec.stores ~= nil and rec.stores[m.path] or nil
  if address == nil then return nil, "" end
  return store_at(rec, address, rec.closures[m.path])
end

--- The tables of a sealed database as the core reads them
--- (core/store.c), the columns of build/schema.tl's: [`Store.seal`]'s,
--- which writes the same from the store's search order, restated here
--- since a closure's modules are rows of its store, which the runner's own
--- search order does not carry (the tree's tests are in none of the
--- program's databases). Beside those, `stubs`, which a checker the worker runs reads
--- and a sealed program has no use for.
local sealed_schema <const>: {string} = {
  "PRAGMA page_size = 4096",
  "PRAGMA auto_vacuum = 0",
  "PRAGMA encoding = 'UTF-8'",
  "CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID",
  "CREATE TABLE modules (path TEXT PRIMARY KEY NOT NULL, file TEXT NOT NULL, " ..
    "kind TEXT NOT NULL, source_hash BLOB NOT NULL, key BLOB NOT NULL, " ..
    "bytecode BLOB NOT NULL, tests TEXT NOT NULL, source BLOB NOT NULL)",
  "CREATE TABLE imports (path TEXT NOT NULL, requires TEXT NOT NULL, " ..
    "PRIMARY KEY (path, requires)) WITHOUT ROWID",
  "CREATE TABLE decl_imports (path TEXT NOT NULL, requires TEXT NOT NULL, " ..
    "PRIMARY KEY (path, requires)) WITHOUT ROWID",
  "CREATE TABLE decls (path TEXT PRIMARY KEY, source BLOB NOT NULL) WITHOUT ROWID",
  "CREATE TABLE stubs (path TEXT PRIMARY KEY, source BLOB NOT NULL) WITHOUT ROWID",
  "CREATE TABLE zoneinfo (name TEXT PRIMARY KEY, data BLOB NOT NULL)",
  "CREATE TABLE web_assets (name TEXT PRIMARY KEY NOT NULL, data BLOB NOT NULL, " ..
    "sha256 TEXT NOT NULL, sha384 TEXT NOT NULL, version TEXT NOT NULL) WITHOUT ROWID",
  "CREATE TABLE ca_roots (sha256 BLOB NOT NULL, label TEXT NOT NULL, der BLOB NOT NULL, " ..
    "distrust_after TEXT NOT NULL)",
  "CREATE TABLE ca_revoked (kind TEXT NOT NULL, name BLOB NOT NULL, value BLOB NOT NULL)",
}

--- The statements [`write_sealed`] runs to fill a sealed database from
--- `closure` (a worker's closure store), `program` (the program's own
--- database) and `whole` (the projection the store was written from), with
--- `temp.extra` the program's modules that go along: what every worker loads
--- and every module the tree lacks (the standard library, in a project's
--- tree), which a worker's key holds by their digest ([`extras_digest`]).
--- The key and the tests of a module are left empty (the compile's, and the
--- tree's own). Each module's and declaration's `decl_imports` rows, which
--- [`build.plans`] reads of a standard-library module a project's
--- compile resolves, come from where its own row does: the closure's,
--- which its store's digest holds, else the program's, which the key holds
--- as it holds the module ([`extras_digest`], or `epoch` for what every
--- worker loads). A standard-library module's stub (build.stub), which
--- a checker the worker runs reads in place of its source, comes from
--- where its row does too. The time zones, CA roots and web assets go only
--- where the set holds the module that reads them, as [`Store.seal`] does:
--- they are most of a small database's bytes.
-- TODO: carry only the standard library a closure requires, in a project's
-- tree, once the projection's `imports` rows record the requires of its
-- modules that name no module of the tree (today they are edges within the
-- tree alone, so what a closure requires of the library is not known without
-- parsing every module's source): every worker of a project's tree reads
-- the whole of the program's library through [`Store.bytecode`] and the
-- rest, as the artifact of a closure it replaced carried it.
local sealed_fill <const>: {string} = {
  "INSERT OR IGNORE INTO temp.extra SELECT path FROM program.modules WHERE path NOT IN " ..
    "(SELECT path FROM whole.modules)",
  "INSERT INTO main.modules SELECT path, file, kind, source_hash, X'', bytecode, '', source " ..
    "FROM closure.modules ORDER BY path",
  "INSERT OR IGNORE INTO main.modules SELECT path, file, kind, source_hash, X'', bytecode, '', " ..
    "source FROM program.modules WHERE path IN temp.extra ORDER BY path",
  "INSERT INTO main.decls SELECT path, source FROM closure.decls ORDER BY path",
  "INSERT INTO main.stubs SELECT path, source FROM closure.stubs ORDER BY path",
  "INSERT OR IGNORE INTO main.stubs SELECT path, source FROM program.stubs " ..
    "WHERE path IN temp.extra AND path NOT IN (SELECT path FROM closure.modules) ORDER BY path",
  "INSERT OR IGNORE INTO main.imports SELECT path, requires FROM closure.imports " ..
    "WHERE path IN (SELECT path FROM main.modules) AND requires IN " ..
    "(SELECT path FROM main.modules) ORDER BY path, requires",
  "INSERT OR IGNORE INTO main.imports SELECT path, requires FROM program.imports " ..
    "WHERE path IN temp.extra AND requires IN (SELECT path FROM main.modules) " ..
    "ORDER BY path, requires",
  "INSERT INTO main.decl_imports SELECT path, requires FROM closure.decl_imports " ..
    "ORDER BY path, requires",
  "INSERT INTO main.decl_imports SELECT path, requires FROM program.decl_imports " ..
    "WHERE path IN temp.extra AND path NOT IN (SELECT path FROM closure.decl_imports) " ..
    "ORDER BY path, requires",
  "INSERT INTO main.zoneinfo SELECT name, data FROM program.zoneinfo WHERE EXISTS " ..
    "(SELECT 1 FROM main.modules WHERE path = 'cosmic.time') ORDER BY name",
  "INSERT INTO main.web_assets SELECT name, data, sha256, sha384, version FROM " ..
    "program.web_assets WHERE EXISTS (SELECT 1 FROM main.modules WHERE path = " ..
    "'cosmic.web.htmx') ORDER BY name",
  "INSERT INTO main.ca_roots SELECT sha256, label, der, distrust_after FROM program.ca_roots WHERE EXISTS " ..
    "(SELECT 1 FROM main.modules WHERE path = 'cosmic.http') ORDER BY sha256",
  "INSERT INTO main.ca_revoked SELECT kind, name, value FROM program.ca_revoked WHERE EXISTS " ..
    "(SELECT 1 FROM main.modules WHERE path = 'cosmic.http') ORDER BY rowid",
}

--- What sealing the databases of this run's workers is made from
--- ([`Sealing`]), made the first time one is wanted: this program's own
--- database, taken from its artifact and written in a directory of the
--- run's own that the user a worker runs as can read (a root runner's
--- workers run as a user of their own, which the 0700 directory
--- [`Fs.mkdtemp`] makes is shut to; its parents are the temporary
--- directory's, which must be open to that user too: the start says if
--- not). Nil and why where there is none, said once.
local function sealing_for(rec: Recording): Sealing?, string
  local sealing = rec.sealing
  if sealing ~= nil then return sealing, "" end
  local sealing_trouble = rec.sealing_trouble
  if sealing_trouble ~= nil then return nil, sealing_trouble end
  local function refuse(why: string): nil, string
    rec.sealing_trouble = why
    return nil, why
  end
  local launched, _ = Proc.relaunch()
  if launched == nil or launched.argv[2] ~= "--artifact" or launched.argv[3] == nil then
    return refuse("this program is no portable artifact to take its database from")
  end
  local bytes, read_trouble = Fs.read(launched.argv[3])
  if bytes == nil then return refuse(launched.argv[3] .. ": " .. read_trouble) end
  local parts, split_trouble = artifact.split(bytes)
  if parts == nil then return refuse(launched.argv[3] .. ": " .. split_trouble) end
  if parts.host then
    return refuse(launched.argv[3] .. ": a host program has no database to seal from")
  end
  local database = parts.database
  -- A root runner's workers run as a user of their own, which must be
  -- able to search every directory above the database: the temporary
  -- directory's, or /tmp's where that is shut to it (a test's own
  -- directory, 0700, is where a nested run's temporary directory is); said
  -- once if neither is, not as an opaque refusal of every worker's start.
  local must_reach = rec.sandbox and sys.getuid() == 0
  --- The first directory above `path` that other users cannot search, as
  --- a sentence, or "".
  local function shut_above(path: string): string
    if not must_reach then return "" end
    local above = Fs.dirname(path)
    while above ~= "/" and above ~= "." do
      local there, _ = sys.stat(above)
      if there ~= nil and there.mode & 1 == 0 then
        return above .. " is not searchable by other users (mode " ..
          string.format("%o", there.mode & 0x1ff) .. "), so the user a worker runs as " ..
          "cannot reach its sealed database below it: open it, or set TMPDIR to a " ..
          "directory that is open"
      end
      above = Fs.dirname(above)
    end
    return ""
  end
  local made, made_trouble = Fs.mkdtemp("sealed-")
  if made == nil then return refuse("a directory for the sealed databases: " .. made_trouble) end
  local real, real_trouble = sys.realpath(made)
  if real == nil then
    local _, _ = Fs.remove_tree(made)
    return refuse(made .. ": " .. real_trouble)
  end
  local directory: string = real
  local shut = shut_above(directory)
  if shut ~= "" then
    local _, _ = Fs.remove_tree(directory)
    -- /tmp's own, under a name no other run has.
    local elsewhere = string.format("/tmp/cosmic-sealed-%d-%d", sys.getpid(), Clock.monotonic_ns())
    local ok, mkdir_trouble = sys.mkdir(elsewhere, tonumber("755", 8))
    if not ok then return refuse(shut .. " (nor /tmp: " .. tostring(mkdir_trouble) .. ")") end
    directory = elsewhere
    shut = shut_above(directory)
    if shut ~= "" then
      local _, _ = Fs.remove_tree(directory)
      return refuse(shut)
    end
  end
  local function fail(why: string): nil, string
    local _, _ = Fs.remove_tree(directory)
    return refuse(why)
  end
  local opened, open_trouble = sys.chmod(directory, tonumber("755", 8))
  if not opened then return fail(directory .. ": " .. tostring(open_trouble)) end
  local path = directory .. "/program.db"
  local written, write_trouble = Fs.write(path, database)
  if not written then return fail(write_trouble) end
  rec.sealing = { directory = directory, program = path }
  return rec.sealing, ""
end

--- Takes out the directory of this run's sealed databases, once no worker
--- runs on one.
function test_key.drop_sealing(rec: Recording)
  local sealing = rec.sealing
  if sealing == nil then return end
  rec.sealing, rec.sealed = nil, {}
  local gone, trouble = Fs.remove_tree(sealing.directory)
  if not gone then log:complain("test: " .. sealing.directory .. ": " .. trouble) end
end

--- Writes the sealed database of the closure store at `store`, which was
--- written from the projection `whole`, to `out`: [`sealed_fill`]'s
--- statements over them and the program's own database (`sealing`), the
--- modules every worker loads ([`worker.loads`]) going along, and the meta
--- rows the core on a database reads: the digest of this core, which it
--- checks, the runtime's basis and image, the compiler's identity where
--- the worker's key holds it (`with_compiler`), and the module that
--- runs. Written aside and moved into place, so one at `out` is whole.
local function write_sealed(sealing: Sealing, store: string, whole: string, out: string,
                            with_compiler: boolean): boolean, string
  local core = Store.meta("host_image")
  local basis = Store.meta("runtime_basis")
  if core == nil or core == "" or basis == nil or basis == "" then
    return false, "this process has no core digest or runtime basis to record"
  end
  local meta: mut {{string}} = { { "core_sha256", core }, { "main", "cmd.cosmic.main" },
    { "runtime_basis", basis } }
  for _, key in ipairs(if with_compiler then { "image_hash", "compiler", "compiled_by" } else
      { "image_hash" } end) do
    local value = Store.meta(key)
    if value ~= nil then meta[#meta + 1] = { key, value } end
  end
  local aside = out .. ".building"
  local _, _ = Fs.remove(aside)
  local opened, open_trouble = Sqlite.open(aside, { writable = true })
  if opened == nil then return false, aside .. ": " .. open_trouble end
  local db: Sqlite.Handle = opened
  local function fill(): boolean, string
    -- Written aside and moved into place whole, or not at all: a journal
    -- and a sync per commit would only cost time.
    for _, pragma in ipairs({ "PRAGMA journal_mode = OFF", "PRAGMA synchronous = OFF" }) do
      local ok, why = db:exec(pragma)
      if not ok then return false, why end
    end
    for _, statement in ipairs(sealed_schema) do
      local ok, why = db:exec(statement)
      if not ok then return false, why end
    end
    for _, attached in ipairs({ { "closure", store }, { "program", sealing.program },
        { "whole", whole } }) do
      local ok, why = Sqlite.run(db, "ATTACH DATABASE ?1 AS " .. attached[1],
        { { text = attached[2] } })
      if not ok then return false, why end
    end
    local filled, fill_trouble = Sqlite.transact(db, function(): boolean, string
      local ok, why = db:exec("CREATE TEMP TABLE extra (path TEXT PRIMARY KEY)")
      if not ok then return false, why end
      for _, name in ipairs(worker.loads) do
        local inserted, insert_trouble = Sqlite.run(db,
          "INSERT OR IGNORE INTO temp.extra (path) VALUES (?1)", { { text = name } })
        if not inserted then return false, insert_trouble end
      end
      -- A program from before `web_assets` or `stubs` has no such table to
      -- carry.
      local held, held_trouble = Sqlite.text_rows(db,
        "SELECT name FROM program.sqlite_master WHERE name IN ('web_assets', 'stubs')")
      if held == nil then return false, held_trouble end
      local absent: mut {string:boolean} = { web_assets = true, stubs = true }
      for _, row in ipairs(held) do absent[row:text(1)] = nil end
      for _, statement in ipairs(sealed_fill) do
        local reads = statement:match("program%.([%w_]+)")
        if reads == nil or absent[reads] ~= true then
          local done, done_trouble = db:exec(statement)
          if not done then return false, done_trouble end
        end
      end
      for _, pair in ipairs(meta) do
        local inserted, insert_trouble = Sqlite.run(db,
          "INSERT INTO main.meta (key, value) VALUES (?1, ?2)",
          { { text = pair[1] }, { text = pair[2] } })
        if not inserted then return false, insert_trouble end
      end
      return true, ""
    end)
    local _, _ = db:exec("DETACH closure")
    local _, _ = db:exec("DETACH program")
    local _, _ = db:exec("DETACH whole")
    if not filled then return false, fill_trouble end
    return true, ""
  end
  local filled, fill_trouble = fill()
  local _, _ = db:close()
  if not filled then
    local _, _ = Fs.remove(aside)
    return false, fill_trouble
  end
  local readable, chmod_trouble = sys.chmod(aside, tonumber("644", 8))
  if not readable then
    local _, _ = Fs.remove(aside)
    return false, aside .. ": " .. tostring(chmod_trouble)
  end
  local moved, move_trouble = Fs.rename(aside, out)
  if not moved then
    local _, _ = Fs.remove(aside)
    return false, move_trouble
  end
  return true, ""
end

--- The path of the sealed database a worker of `m`'s tests runs on, made
--- where it is not there yet in the run's directory ([`sealing_for`]), once
--- per closure store however many modules share it: the modules of its
--- closure store, as its key holds it by its bytes, and the program's own
--- rows of what every worker loads and of what the tree lacks (the
--- standard library's, in a project's tree), which its key holds by the
--- harness's epoch and the runtime's identity. Nothing else of the
--- program goes along, so no `Store` read, searcher or `require` of a
--- worker or of a process it starts reaches a module its key does not hold.
--- Nil where `m`'s worker is not sealed ([`seals`]), and nil and why where
--- its database could not be made.
local function sealed_for(rec: Recording, m: Module): string?, string
  if not seals(rec, m) then return nil, "" end
  local with_compiler = reads_compiler(rec, m)
  -- A worker whose key holds the compiler's identity reads it, so its
  -- database holds it: another file than a closure's that does not.
  local name = rec.stores[m.path] .. (if with_compiler then "-compiler" else "" end)
  local kept = rec.sealed[name]
  if kept ~= nil then return kept, "" end
  local started = Clock.monotonic_ns()
  local sealing, sealing_trouble = sealing_for(rec)
  if sealing == nil then return nil, "its sealed database: " .. sealing_trouble end
  local store, store_trouble = given_store(rec, m)
  if store == nil then return nil, store_trouble end
  local path = sealing.directory .. "/" .. name .. ".db"
  local written, trouble = write_sealed(sealing, store, projection_of(rec), path, with_compiler)
  if not written then return nil, "its sealed database: " .. trouble end
  local wrote, stat_trouble = sys.stat(path)
  if wrote == nil then return nil, "its sealed database: " .. path .. ": " .. stat_trouble end
  rec.sealed_written = rec.sealed_written + 1
  rec.sealed_bytes = rec.sealed_bytes + wrote.size
  rec.sealed_ns = rec.sealed_ns + (Clock.monotonic_ns() - started)
  rec.sealed[name] = path
  return path, ""
end

--- Where a store whose bytes did not match another write of its
--- address is kept aside for a report: beside the stores, which
--- [`sweep_stores`] leaves it.
local function mismatch_path(rec: Recording, address: string): string
  return stores_directory(rec.root) .. "/" .. address .. ".mismatch.db"
end

--- Records, as an error of the run, that the store at `path`, written
--- for `address`, digests to `digest` where another write of the
--- address digested to `kept`, which `where` says where it is, or was
--- kept. The one at `path` is kept aside ([`mismatch_path`]), moved there
--- where `move` says it is this run's own copy, else copied, since a
--- worker may be given it.
local function mismatched(rec: Recording, address: string, path: string, digest: string,
                          kept: string, where: string, move: boolean)
  local aside = mismatch_path(rec, address)
  local saved, trouble: boolean, string = false, ""
  if move then
    saved, trouble = Fs.rename(path, aside)
  else
    local data, read_trouble = Fs.read(path)
    if data == nil then
      trouble = read_trouble
    else
      saved, trouble = Fs.write(aside, data)
    end
  end
  rec.errors[#rec.errors + 1] = "the closure store at address " .. address .. " was written " ..
    "with bytes whose digest is " .. digest .. ", but " .. where .. " has " .. kept ..
    ": a store's bytes must follow from its address alone (build.closure_store's " ..
    "`address`), and these do not. " .. (if saved then ("This run's is kept at " .. aside) else
      ("This run's could not be kept aside (" .. trouble .. ")") end) .. "; report it with the " ..
    "other, and both digests, and remove it once reported. The next run keeps " .. digest ..
    " for the address in the shared verdicts, in place of " .. kept .. "."
end

--- The digest the shared verdicts keep for the store at `address`, as a
--- run that wrote it kept it, looked up once a run ([`Recording.store_kept`]);
--- nil for none, or where the run has no shared verdicts.
local function shared_digest(rec: Recording, address: string): string?
  local kept = rec.store_kept[address]
  if kept == nil then
    kept = ""
    local shared = rec.shared
    if shared ~= nil then
      local found, trouble = shared_verdicts.store_digest(shared, address)
      if found == nil and trouble ~= "" then drop_shared(rec, trouble) end
      kept = found or ""
    end
    rec.store_kept[address] = kept
  end
  if kept == "" then return nil end
  return kept
end

--- The digest of the bytes of the closure store at `address`, of the
--- import closure `names` (`base` for the store of no module,
--- [`store_at`]): what a key holds of the store, not the address that
--- says where it is.
---
--- A store this checkout has is digested as it is
--- ([`declared_key.store_digest`]). One it has not is taken, where it
--- can be, from the digest a run that wrote it kept by its address in
--- the shared verdicts ([`shared_verdicts.store_digest`]), so a fresh
--- checkout that stands on verdicts writes no store; else it is written
--- and digested. That is sound because the address digests all a
--- store's bytes follow from ([`address_stores`]), and
--- build/closure_store_test.tl holds two writes of it to the same
--- bytes. And it is checked: a test that runs is given its store as
--- written, which its key is computed again from once it ends, so a
--- verdict is kept only under the digest of what it was given; a store
--- this checkout has or writes whose bytes differ from what the shared
--- verdicts keep of its address is an error of the run (`mismatched`),
--- and so is one sampled each run that writes none ([`verify_sample`]).
--- Nil and why where it could not be written.
local function address_digest(rec: Recording, address: string, names: {string},
                              base: boolean): string?, string
  local started = Clock.monotonic_ns()
  rec.store_names[address] = names
  rec.store_bases[address] = base
  local path = stores_directory(rec.root) .. "/" .. (base and base_name(address) or
    (address .. ".db"))
  local digest: string? = nil
  local there, _ = sys.stat(path)
  if rec.built[address] == nil and there == nil then
    digest = rec.store_digests[address]
    if digest == nil and rec.consult_shared then digest = shared_digest(rec, address) end
  end
  if digest == nil then
    charge_keying(rec, started)
    local made, trouble = store_at(rec, address, names, base)
    if made == nil then return nil, trouble end
    started = Clock.monotonic_ns()
    digest = declared_key.store_digest(digests_of(rec), made)
    -- Held to what this run took for it, else to what the shared
    -- verdicts keep, whether this run wrote it or found it here.
    local took = rec.store_digests[address]
    local kept, where = took, "the digest this run took for it"
    if kept == nil then
      kept = shared_digest(rec, address)
      local shared = rec.shared
      where = if shared ~= nil then ("the shared verdicts at " .. shared.path) else "" end
    end
    if kept ~= nil and kept ~= digest and rec.store_mismatched[address] ~= true then
      rec.store_mismatched[address] = true
      mismatched(rec, address, made, digest, kept, where, false)
    end
  end
  rec.store_digests[address] = digest
  local owed_stores = assert(rec.owed.stores)
  owed_stores[address] = digest
  charge_keying(rec, started)
  return digest, ""
end

--- Writes one store of this run again, aside, and holds its bytes to
--- the digest the run keyed its tests by: a run that wrote no store
--- would otherwise never see a write, and so never a store whose bytes
--- do not follow from its address. The store is chosen by the run's
--- number among those it keyed, so runs take each in turn; one costs
--- tens of milliseconds, counted with the keys'. A mismatch is an error
--- of the run (`mismatched`); no file is left but one kept aside.
local function verify_sample(rec: Recording)
  if rec.written > 0 then return end
  local addresses: mut {string} = {}
  for address in pairs(rec.store_digests) do addresses[#addresses + 1] = address end
  if #addresses == 0 then return end
  table.sort(addresses)
  local started = Clock.monotonic_ns()
  local address = addresses[(rec.run or 0) % #addresses + 1]
  local path = stores_directory(rec.root) .. "/" .. address .. ".verify.db"
  local made, _ = Fs.mkdirs(stores_directory(rec.root))
  local written, trouble = false, "no stores directory"
  if made then
    local extraction, extraction_trouble = extraction_for(rec)
    if extraction == nil then
      written, trouble = false, extraction_trouble
    else
      written, trouble = closure_store.write(projection_of(rec), path, rec.store_names[address],
        assert(rec.basis), extraction)
    end
  end
  if not written then
    rec.errors[#rec.errors + 1] = "the closure store at address " .. address ..
      ", written again to check it: " .. trouble
  else
    local data, read_trouble = Fs.read(path)
    local digest = data ~= nil and hex_sha256(data) or ("unreadable: " .. read_trouble)
    local kept = rec.store_digests[address]
    if digest ~= kept and not rec.store_mismatched[address] then
      rec.store_mismatched[address] = true
      local other = stores_directory(rec.root) .. "/" .. (rec.store_bases[address] and
        base_name(address) or (address .. ".db"))
      local there, _ = sys.stat(other)
      mismatched(rec, address, path, digest, kept, there ~= nil and other or
          "the store this run keyed its tests by", true)
    end
  end
  local _, _ = Fs.remove(path)
  charge_keying(rec, started)
end

--- The digest of the bytes of the closure store a worker of `m`'s tests
--- is given ([`address_digest`]), which its key holds. Nil where `m`
--- declares `store`; nil and why where it could not be made.
store_digest = function(rec: Recording, m: Module): string?, string
  local address = rec.stores ~= nil and rec.stores[m.path] or nil
  if address == nil then return nil, "" end
  return address_digest(rec, address, rec.closures[m.path], false)
end

--- The digest of the bytes of the store of no module (`base_store`),
--- which every closure store holds alike: what the census names as the
--- key part `store`, which moves where every store's bytes move -- the
--- schema a store is laid out by, or the SQLite that writes it -- but
--- not for a comment in the code that writes it. "" where it could
--- not be made.
function test_key.base_store_digest(rec: Recording): string
  local digest, _ = address_digest(rec, assert(rec.base_store), {}, true)
  return digest or ""
end

--- The policy `job`'s worker is started under ([`build.test_policy`]), from
--- the plan of its paths (`job.plan`). Its environment is added by
--- [`worker.invocation`], which gives a policy's `set_env` the whole of the
--- worker's. Nil and why where its directory cannot be made.
local function policy_of(rec: Recording, job: Job): Sandbox.Policy?, string
  local effective = rec.effective[job.m.path]
  local policy = test_policy.worker(assert(job.plan), effective)
  if effective.noexec_ready == true then
    local made, made_trouble = Fs.mkdirs(assert(job.scratch) .. "/noexec")
    if not made then return nil, "its private noexec scratch: " .. made_trouble end
  end
  return policy, ""
end

--- Which absence a module reports when it has several, the worst first.
local UNMET_RANK <const>: {string:integer} = { refused = 3, na = 2, skipped = 1 }

--- The names a module requires of its host, as its policy declares them
--- ([`host_names.check`]), sorted.
local function requirements_of(m: Module): {string}
  local names: mut {string} = {}
  local declared = m.inputs
  if declared == nil then return names end
  for _, name in ipairs(declared.requires) do names[#names + 1] = name end
  table.sort(names)
  return names
end

--- Asks the host, once, for every requirement the modules declare
--- ([`host_requires`]), before any worker starts, and decides each module:
--- where all are present, it runs, and its key holds each answer
--- (`rec.answered`); otherwise none of its tests is started (`rec.unmet`),
--- as one whose name breaks the table's rules fails (`refused`), one a
--- platform never has is not applicable (`na`), and one this host lacks is
--- skipped. A `held` run (COSMIC_TEST_SANDBOX=1, COSMIC_SANDBOX=must,
--- COSMIC_CI_REQUIRE_SANDBOX=1) holds the sandbox, and fails a module for
--- an n/a or a skip of a requirement its leg promises (`promises`, the
--- leg's name `leg`), naming the requirement and the leg; an absence of
--- one it does not promise fails nothing. `sandbox` answers whether a
--- worker can be sandboxed here, which a requirement of it asks. The host
--- asked, or nil where no module requires anything.
function test_key.ask_host(rec: Recording, modules: {Module},
                           sandbox: function(): host_requires.Sandbox, held: boolean,
                           promises: {string}, leg: string): host_requires.Host?
  local host: host_requires.Host? = nil
  for _, m in ipairs(modules) do
    local names = requirements_of(m)
    if #names > 0 then
      if host == nil then
        -- COSMIC_TEST_PLATFORM=other, for a test of this runner alone, stands in
        -- for a platform without Linux's requirements or a portable artifact on
        -- a host that has them: it makes modules not applicable, which keeps
        -- no verdict and fails no run.
        local linux: boolean? = nil
        local portable = Store.meta("runtime_context") == "portable-v1"
        local checked = testing.configuration == "sanitized"
        local function host_only(): boolean
          local prefix, _ = artifact.trusted_prefix()
          return prefix == nil or artifact.host_only(prefix)
        end
        if Env.read("COSMIC_TEST_PLATFORM") == "other" then
          linux, portable, checked = false, false, false
        end
        host = host_requires.new({
          portable = portable,
          checked = checked,
          host_only = host_only,
          linux = linux,
          sandbox = sandbox,
        })
      end
      local probed = assert(host)
      local asked, answers = pcall(host_requires.answer, probed, names)
      local found: {host_requires.Answer} = {}
      if asked then
        found = answers
      else
        -- A probe that cannot tell (a file it may not read) is no answer: the
        -- modules that name it fail, saying why, and the run goes on.
        rec.unmet[m.path] = { kind = "refused", why = "the probe of what it requires of the host " ..
            "failed: " .. tostring(answers) }
      end
      local present: mut {string:string} = {}
      local unmet: Unmet?
      for _, answer in ipairs(found) do
        if answer.kind == "present" then
          present[answer.name] = answer.key
        else
          local said = "requires " .. answer.name .. ": " .. answer.why
          local kind = answer.kind
          if held and kind ~= "refused" and host_names.promised(promises, answer.name) then
            said = said .. " (" .. (if leg == "" then "this run" else "the leg " .. leg end) ..
              " promises " .. answer.name .. ", and a held run fails what its leg promised)"
            kind = "refused"
          end
          if unmet == nil or UNMET_RANK[kind] > UNMET_RANK[unmet.kind] then
            unmet = { kind = kind, why = said }
          end
        end
      end
      if rec.unmet[m.path] ~= nil then
        unmet = nil
      elseif unmet ~= nil then
        rec.unmet[m.path] = unmet
      else
        rec.answered[m.path] = present
      end
    end
  end
  return host
end

--- What every test's key is made of, read once before any test is
--- keyed: each selected module's closure and declarations, the stores
--- of the closures, and the host, system and launcher identities, then
--- frozen. Nil where it is, or why it cannot be: the runner stops with the
--- reason.
function test_key.gather(rec: Recording, from: Gather): string?
  local records, records_path, selected_modules = from.records, from.records_path, from.selected
  local identity = from.identity
  local by_path: mut {string:Module} = {}
  for _, m in ipairs(from.modules) do by_path[m.path] = m end
  local declaration_rows, declaration_trouble = Sqlite.text_rows(records,
    "SELECT path, file FROM inputs WHERE " .. analysis_schema.declaration("kind"))
  if declaration_rows == nil then return records_path .. ": " .. declaration_trouble end
  local declarations: mut {string:string} = {}
  for _, row in ipairs(declaration_rows) do declarations[row:text(1)] = row:text(2) end
  for path in pairs(by_path) do rec.tree_names[#rec.tree_names + 1] = path end
  table.sort(rec.tree_names)
  -- A module the binary carries that is no module of the tree -- in a
  -- project's tree, the standard library's -- is no key's either way
  -- (the TODO above build.test_worker's `refusal`): a worker may load
  -- one.
  for name in pairs(rec.carried) do
    if by_path[name] == nil then rec.carried[name] = nil end
  end
  local type_only, type_only_trouble = projection_type_only(from.database)
  if type_only == nil then return type_only_trouble end
  rec.type_only = type_only
  for _, m in ipairs(selected_modules) do
    rec.closures[m.path] = test_inputs.modules(m, by_path, declarations, type_only)
  end
  local noexec_probes: {string:string} = {}
  for _, m in ipairs(selected_modules) do
    local effective = test_inputs.effective(m, by_path, declarations, type_only)
    effective.cache_paths = caches_of(rec, m)
    test_inputs.resolve(effective, tree_roots(rec))
    test_sandbox_probe.resolve_noexec(effective, rec.sandbox, noexec_probes)
    rec.effective[m.path] = effective
  end
  -- What an earlier run hashed, so a key reads none of it again
  -- ([`build.declared_key`]).
  local remembered, remembered_trouble = Sqlite.text_rows(records,
    "SELECT path, signature, sha256 FROM digests")
  if remembered == nil then return records_path .. ": " .. remembered_trouble end
  local earlier: mut {{string}} = {}
  for _, row in ipairs(remembered) do earlier[#earlier + 1] = row:texts() end
  rec.digests = declared_key.digests(from.root, earlier)
  -- A core that carries debug information, as the checked core does,
  -- is keyed by its image (build.core_image): its DWARF names the
  -- directory musl was first built in, which moves between CI runs,
  -- and no test's verdict turns on it. A release core, stripped, keys
  -- as the binary names it.
  local host_image = Store.meta("host_image")
  local store_runtime = identity
  if host_image ~= nil and String.starts_with(rec.runtime, identity) then
    store_runtime = declared_key.runtime_identity(digests_of(rec), identity, host_image,
      Store.meta("runtime_basis") or "")
    rec.runtime = store_runtime .. rec.runtime:sub(#identity + 1)
  end
  rec.core = store_runtime
  -- A core that writes stores otherwise a test stands in for, in a tree
  -- not cosmic's own, so it can see the core move every store's address
  -- (build/sandboxed_verdicts_test.tl): mixed into the stores' salt
  -- alone, never in its place.
  local store_core = Env.read("COSMIC_TEST_STORE_RUNTIME")
  if not from.own_tree and store_core ~= nil and store_core ~= "" then
    store_runtime = hex_sha256(store_runtime .. "\0" .. store_core)
  end
  rec.store_runtime = store_runtime
  -- The store of each test module's closure, by its address, salted with
  -- the core above, and none that no module names any longer.
  rec.projection = from.database
  local addressed, address_trouble = address_stores(rec, from.modules, by_path, declarations)
  if not addressed then
    return "test: the stores of the test modules' closures: " .. address_trouble
  end
  sweep_stores(rec)
  -- The compiler a checked run's modules were compiled by
  -- ([`importer.compile`]'s `checks`).
  local compiled_with = GrammarMode.tool(from.tool, from.grammar)
  if from.checks then
    compiled_with = importer.checked_tool(compiled_with, from.grammar == "new")
  end
  rec.compiler = compiled_with .. " " .. from.compiled_by
  local split = declared_key.host_split(digests_of(rec))
  rec.host, rec.host_rest = split.identity, split.rest
  -- What the system's paths hold is walked only for a run that holds
  -- a module given them, whose key alone holds it: half a second of
  -- /usr's entries otherwise spent for nothing.
  local holds_system = false
  for _, m in ipairs(selected_modules) do
    local effective = rec.effective[m.path]
    if effective ~= nil and effective.system == true then holds_system = true end
  end
  rec.system = declared_key.system_identity(digests_of(rec), nil, holds_system)
  tool_of(rec)
  -- The runtime identity holds the core an artifact selects, not the
  -- launcher and manifest that selected it, which a test that does
  -- not run the program is keyed by nowhere else.
  local executable, _ = Proc.executable()
  if Store.meta("runtime_context") == "portable-v1" and executable ~= nil then
    rec.launcher = declared_key.launcher_identity(digests_of(rec), executable)
  end
  -- Every test is keyed before any starts: one look at each input
  -- serves them all.
  declared_key.freeze(digests_of(rec))
  return nil
end

--- The compiler identities the running binary names: the one a tree is
--- compiled with (`tool`) and the one that compiled it (`compiled_by`),
--- which a verdict's key holds where its closure reads them
--- ([`declared_key.reads_compiler`]).
---
--- A compiler a test stands in for, in a tree not cosmic's own (`own_tree`
--- false), so it can see a compiler of another identity that makes the same
--- bytecode move only the keys of a closure that reads it, without a
--- binary of its own (build/sandboxed_verdicts_test.tl): the tree is
--- compiled under it, and the run keys by it.
function test_key.compiler_identity(own_tree: boolean): Compiler
  local tool = Store.meta("compiler") or ""
  local compiled_by = Store.meta("compiled_by") or ""
  local compiler_salt = Env.read("COSMIC_TEST_COMPILER_SALT")
  if not own_tree and compiler_salt ~= nil and compiler_salt ~= "" then
    tool = hex_sha256(tool .. "\0" .. compiler_salt)
    compiled_by = tool
  end
  return { tool = tool, compiled_by = compiled_by }
end

--- The runtime of the running binary ([`Runtime`]), or nil and why where
--- the binary names none or its data tables cannot be digested.
---
--- Every verdict is keyed on the data tables the binary carries too
--- ([`schema.tables_digest`]): `cosmic refresh` replaces its zones and
--- roots without moving its runtime identity, and a test that read one
--- could fail on the refreshed binary. Every test, not only one that
--- read a table: that read goes through `Store`'s own connection, which
--- no observation sees, and a refresh is rare enough that running
--- everything once after one costs little. Computed here from the
--- binary's own rows rather than taken from anything it records of
--- them, which a refresh or a writer that did not know to update it
--- would leave stale.
function test_key.runtime_of(): Runtime?, string
  local identity = Store.meta("runtime") or ""
  if identity == "" then
    return nil, "the running binary names no runtime identity"
  end
  local tables, tables_trouble = binary_tables()
  if tables == nil then
    return nil, "the running binary's data tables: " .. tables_trouble
  end
  return { identity = identity, runtime = identity .. " tables " .. tables }, ""
end

--- `runtime` with the part a sandboxed run adds: whether it is held to
--- confining what it starts ([`confine.must_confine`]), which a test's
--- verdict turns on, and the code that makes a worker's policy. The
--- runtime holds what every worker's policy has alike, the isolation and
--- the promises ([`test_policy.common`]), and that code (`made`, the
--- digests of the harness's modules), so an edit to a grant runs the
--- tests again without a bump of the epoch. A verdict so reached is kept
--- apart from one reached without a sandbox, by a runtime of its own, so
--- neither stands for the other.
function test_key.sandboxed_runtime(runtime: string, made: {string:string}, must: boolean): string
  return runtime .. " sandboxed" .. (if must then " must" else "" end) .. " policy " ..
    hashing.hex_sha256(test_policy.common() .. "\0" ..
        (made["build.test_policy"] or "") .. "\0" .. (made["build.test_sandbox"] or ""))
end

--- `runtime` for a run whose workers are not sandboxed: the pinned
--- COSMIC_TEST_SANDBOX and the " sandboxed" mark of the other already
--- tell these verdicts from a sandboxed run's; the tag says so in the key
--- itself (build/declared_unenforced_test.tl).
function test_key.declared_runtime(runtime: string, must: boolean): string
  return runtime .. " declared" .. (if must then " must" else "" end)
end

--- Sets what every key of the run holds of the harness and the runtime
--- on its recording: the runtime, whether workers are sandboxed, the
--- epoch, the timeout, the salt of the stores' addresses and the modules
--- a worker's loads are held to.
---
--- An edit to the code that writes a closure store a test stands in
--- for, in a tree not cosmic's own, so it can see one that writes the
--- same bytes move no key without a binary of its own
--- (build/sandboxed_verdicts_test.tl): mixed into the salt, never in
--- its place, so one address still names one store's bytes.
function test_key.begin(rec: Recording, from: Begin)
  rec.runtime = from.runtime
  rec.sandbox = from.sandbox
  rec.epoch = from.epoch
  rec.timeout_ns = from.timeout_ns
  rec.store_salt = from.harness.store_salt
  rec.carried = from.harness.carried
  local store_salt = Env.read("COSMIC_TEST_STORE_SALT")
  if not from.own_tree and store_salt ~= nil and store_salt ~= "" then
    rec.store_salt = hex_sha256(rec.store_salt .. "\0" .. store_salt)
  end
end

--- The identities of the other hosts, of this host's rest but for its
--- features (`rec.host_rest`), whose verdicts the shared cache holds
--- ([`shared_verdicts.hosts_like`]), looked up once a run. A cache that
--- cannot say names none.
local function foreign_hosts(rec: Recording): {string}
  local hosts = rec.foreign_hosts
  if hosts == nil then
    hosts = {}
    local shared = rec.shared
    if shared ~= nil then
      local found, trouble = shared_verdicts.hosts_like(shared, assert(rec.host_rest), assert(rec.host))
      if found == nil then drop_shared(rec, trouble) else hosts = found end
    end
    rec.foreign_hosts = hosts
  end
  return hosts
end

--- Keys the test `id` of `m` and looks its verdict up. A test is keyed by
--- what it is given, and runs unless a verdict under that key passed, here
--- (`verdicts`, by key) or in another checkout -- or it is `forced`, by
--- --all or COSMIC_TEST_ALL, or reaches a network beyond loopback, which no
--- key holds. A checked run is forced too: a verdict that stands runs no
--- worker, and a worker is what reports. None is assumed. The shared
--- verdicts are asked only where the run `consult`s them and nothing here
--- answers.
---
--- Where the run `accept_foreign`s, a test no verdict answers for under
--- this host's key is looked up under the key it would have had on each
--- other host the cache names of this host's rest but for its features,
--- the identity that host stamped its rows with: the same key in every
--- other input, as this host works each out, so the row is the test's
--- verdict of this tree, closure, epoch and runtime, reached on a host
--- of other features. The key found is then the lookup's, and the row
--- stays under it: no row is made under this host's key, so a run that
--- does not accept them finds none. The hosts are tried in sorted
--- order and the first row found answers: a pass on any like host
--- stands even if another like host failed the same key, as a failing
--- row is deleted, not kept as a mark. That failure is its own run's,
--- which fails CI there.
function test_key.lookup(rec: Recording, m: Module, id: string,
                         verdicts: {string:Verdict}, forced: boolean?,
                         consult: boolean?): Lookup
  local force: boolean = forced == true or rec.checks
  local key = declared_of(rec, m, id)
  local own = key ~= nil and verdicts[key] or nil
  local elsewhere: shared_verdicts.Found? = nil
  local asked = false
  local rec_shared = rec.shared
  if key ~= nil and not force and own == nil and consult == true and rec_shared ~= nil then
    local answer, trouble = shared_verdicts.declared(rec_shared, key)
    if answer == nil and trouble ~= "" then drop_shared(rec, trouble) end
    elsewhere = answer
    asked = true
    if answer == nil and rec.accept_foreign then
      -- Under another host's key, every other input as this host keys it.
      for _, other in ipairs(foreign_hosts(rec)) do
        local foreign = declared_of(rec, m, id, other)
        local seen: shared_verdicts.Found? = nil
        local seen_trouble = ""
        if foreign ~= nil and rec.shared ~= nil then
          seen, seen_trouble = shared_verdicts.declared(rec.shared, foreign)
          if seen == nil and seen_trouble ~= "" then drop_shared(rec, seen_trouble) end
        end
        if seen ~= nil then
          key, elsewhere = foreign, seen
          break
        end
      end
    end
  end
  local outcome: Outcome = "share"
  if key == nil or force or (own ~= nil and not own.passed) or
      (own == nil and elsewhere == nil) then
    outcome = "run"
  elseif own ~= nil then
    outcome = "stand"
  end
  return { key = key, own = own, elsewhere = elsewhere, asked = asked, outcome = outcome }
end

--- The job of a test whose `found` lookup says to run it. It is keyed by
--- what the lookup keyed it by, and no other key: its verdict is kept
--- under that ([`test_key.keep`]).
function test_key.job_of(found: Lookup, m: Module, name: string, id: string): Job
  assert(found.outcome == "run", "a job is made of a lookup that says to run it")
  return { m = m, name = name, id = id, declared = found.key }
end

--- Keeps, as this run's own, the passing verdict this checkout held under
--- the key of a test whose `found` lookup says it stands. True where it
--- did, or false and why.
function test_key.stand_verdict(rec: Recording, found: Lookup): boolean, string
  assert(found.outcome == "stand", "a verdict stands only where its lookup says so")
  local key, stood = assert(found.key), assert(found.own)
  rec.owed.used[#rec.owed.used + 1] = key
  return test_key.record_verdict(rec.records, key, true, stood.run_at_ns, rec.run,
    stood.elapsed_ns)
end

--- Keeps, as this run's own, the passing verdict another checkout reached
--- under the key of a test whose `found` lookup says to share it, so a
--- later run of this checkout stands on it without the shared cache. True
--- where it did, or false and why.
function test_key.share_verdict(rec: Recording, found: Lookup): boolean, string
  assert(found.outcome == "share", "a verdict is shared only where its lookup says so")
  local key, elsewhere = assert(found.key), assert(found.elsewhere)
  rec.owed.used[#rec.owed.used + 1] = key
  return test_key.record_verdict(rec.records, key, true, rec.run_at_ns, rec.run,
    elsewhere.elapsed_ns)
end

--- How a finished job's worker is judged ([`build.test_worker`]'s
--- `judge`): what it reported, or the failure that says why there is no
--- report to go by (`trouble`, the `result` of its process, `refused` where
--- its test was refused before it started); a test whose host cannot check
--- it (`unavailable`, with why) is a pass that checked nothing. A key
--- holds what a worker runs by [`worker.loads`] and the test's closure, so
--- a worker that ran a module of the tree the tool carries beyond both
--- fails its test.
---
--- A pass the test said it could not check ([`Test.skip`]) is a skip, and
--- one that made no call to `assert` is unchecked, which a held run fails
--- (an example, `*_example.tl`, shows how code is used and is not held to
--- it: it passes by running). Neither is kept as a verdict, pass or fail,
--- so it runs again on the next run -- and on a host that can check it,
--- whose key differs, as its own.
function test_key.judge(rec: Recording, job: Job, result: Child.Result?,
                        trouble: string, refused: boolean?,
                        unavailable: string?): Judged
  local judgement: worker.Judgement
  if unavailable ~= nil then
    judgement = { passed = true, skipped = unavailable, message = "" }
  else
    judgement = worker.judge({
      result = result, trouble = trouble, timeout_ns = rec.timeout_ns,
      sandboxed = rec.sandbox, refused = refused == true,
      carried = rec.carried,
      closure = closure_set(rec, job.m),
    })
  end
  local passed, message = judgement.passed, judgement.message
  local skipped = ""
  if passed and judgement.skipped ~= nil then skipped = judgement.skipped end
  if skipped ~= "" then
    -- A reason may carry what a failed start printed: the report lists
    -- one line each.
    skipped = skipped:match("^[^\n]+") or "the host refused what the test is about"
    message = "skipped: " .. skipped
  end
  local unchecked = passed and judgement.unchecked == true and job.m.kind == "test"
  if unchecked and rec.held then
    passed = false
    message = "made no call to assert, so its pass shows only that it did not raise" ..
      " (a held run fails that)\n  to fix: assert what it exists to show, a helper that" ..
      " checks through error or pcall calling assert; where this host cannot check it," ..
      " declare `requires` or call Test.skip(reason)"
  end
  return { report = judgement.report, passed = passed, message = message, skipped = skipped,
    unchecked = unchecked, deliberate = judgement.deliberate or "",
    checked = skipped == "" and not unchecked }
end

--- Whether the test `id` of `m` still reaches `key`, the one it was
--- keyed by before it started: its declared inputs must be as they were,
--- or the verdict describes no one state of them, and is not kept.
local function holds(rec: Recording, m: Module, id: string,
                     key: string?): boolean
  return key ~= nil and declared_of(rec, m, id) == key
end

--- Keeps what one finished `job` reached under its key (`job.declared`,
--- [`test_key.job_of`]; nil for one with none, which is kept under none and
--- runs every time), as it was `judged`: `judged.passed` is what its
--- verdict is, `judged.checked` whether it checked something, and the
--- worker's report, which a pass kept for the shared verdicts needs.
--- `elapsed` is its time. A verdict is kept only for a test that checked,
--- under a key it still reaches: its declared inputs must be as they were
--- before it started ([`holds`]), or the verdict describes no one state of
--- them. One that failed with its inputs moved while it ran describes no
--- one state of them, but may be of the one it started from, and a pass
--- kept under that key would stand for it: gone.
function test_key.keep(rec: Recording, job: Job, judged: Judged, elapsed: integer)
  local id, key = job.id, job.declared
  local passed, checked = judged.passed, judged.checked
  local held = holds(rec, job.m, id, key)
  if key ~= nil and held and checked then
    local saved, save_trouble = test_key.record_verdict(rec.records, key, passed,
      rec.run_at_ns, rec.run, elapsed)
    if not saved then
      rec.errors[#rec.errors + 1] = id .. ": verdict: " .. save_trouble
    end
  elseif key ~= nil and not passed then
    -- Its inputs moved while it ran, so the failure is of no one state
    -- of them -- but it may be of the one it started from, and a pass
    -- kept under that key would stand for it: gone.
    local saved, save_trouble = Sqlite.run(rec.records, "DELETE FROM verdicts WHERE key = ?1",
      { text(key) })
    if not saved then
      rec.errors[#rec.errors + 1] = id .. ": verdict: " .. save_trouble
    end
  end
  -- A pass another run shared under its key goes too where it failed.
  if key ~= nil and not passed then
    rec.owed.failed[#rec.owed.failed + 1] = key
  elseif passed and checked and held and judged.report ~= nil then
    rec.owed.kept[#rec.owed.kept + 1] = { key = key, test = id, hits = rec.by_test[id],
      elapsed_ns = elapsed }
  end
end

--- Ends the keying of a run: writes one store again to hold it to the
--- digest the run keyed its tests by ([`verify_sample`]), takes out the
--- database the stores were extracted with, and lets each key look at its
--- inputs again, since a verdict is kept only under a key its inputs still
--- reach once its test has run.
function test_key.close_keying(rec: Recording)
  verify_sample(rec)
  drop_extraction(rec)
  declared_key.thaw(digests_of(rec))
end

--- Keeps in the working database `records` what a sandboxed run hashed,
--- for the next to look up by `lstat`: a run of the `whole` tree keeps
--- only what it looked at, and one of some of it adds to what the rest
--- looked at before. True where it did, or false and why.
function test_key.persist_digests(records: Sqlite.Handle, rec: Recording,
                                  whole: boolean?): boolean, string
  local digests = rec.digests
  if digests ~= nil and digests.read > 0 then
    local kept, keep_trouble = true, ""
    if whole == true then kept, keep_trouble = records:exec("DELETE FROM digests") end
    for _, row in ipairs(kept and declared_key.kept(digests) or {}) do
      if kept then
        kept, keep_trouble = Sqlite.run(records,
          "INSERT OR REPLACE INTO digests (path, signature, sha256) VALUES (?1, ?2, ?3)",
          { text(row[1]), text(row[2]), text(row[3]) })
      end
    end
    if not kept then return false, keep_trouble end
  end
  return true, ""
end

--- A worker that could not be started ([`test_key.prepare`]).
local function cannot(trouble: string, refused: boolean, unavailable: string?): Prepared
  return { command = nil, trouble = trouble, refused = refused, unavailable = unavailable }
end

--- What a job's worker is given, and the command that starts it: its
--- directory, the sandbox's plan of its paths and environment, how it is
--- held, the policy it is started under and the sealed database it runs
--- on, as [`worker.invocation`] takes them. The program it starts is
--- [`worker.program`]'s and its deadline the run's timeout, which every
--- key holds (`rec.timeout_ns`). The job's `started_ns` is set before it is
--- called, since a failure is reckoned from it.
function test_key.prepare(rec: Recording, job: Job): Prepared
  local start, start_trouble = worker.program()
  if start == nil then
    return cannot("the test runner cannot find itself: " .. start_trouble, false, nil)
  end
  local scratch, tmp_trouble = test_key.scratch()
  if scratch == nil then
    return cannot("could not make a temporary directory: " .. tmp_trouble, false, nil)
  end
  job.scratch = scratch
  local tmp = scratch .. "/tmp"
  job.tmp = tmp
  -- Sandboxed, the worker has the tree at /tree, where it runs, and
  -- its scratch directory at [`test_sandbox.scratch`].
  local env: {string:string} = worker_view()
  local root, inside, cwd: string, string, string = rec.root, scratch, nil
  local declares_trouble = unresolved(rec, job.m)
  if declares_trouble ~= "" then
    return cannot(declares_trouble, true, nil)
  end
  local effective = rec.effective[job.m.path]
  if effective.noexec == true and effective.noexec_ready ~= true then
    return cannot("", false, effective.noexec_trouble)
  end
  -- The store its worker attaches ([`worker.Invocation`]'s `store`).
  local attached: string? = nil
  -- The sealed database of its closure its worker runs on ([`sealed_for`]):
  -- nil for none.
  local sealed: string? = nil
  local sealed_trouble = ""
  if rec.sandbox then
    local store, store_trouble = given_store(rec, job.m)
    if store == nil and store_trouble ~= "" then
      return cannot(store_trouble, false, nil)
    end
    -- A worker that runs on a sealed database is given no artifact: it
    -- starts the core on that database, which grants the file itself.
    sealed, sealed_trouble = sealed_for(rec, job.m)
    if sealed == nil and sealed_trouble ~= "" then
      return cannot(sealed_trouble, false, nil)
    end
    if sealed == nil and rec.effective[job.m.path].lua == true and not rec.effective[job.m.path].store and
        not rec.effective[job.m.path].tool then
      local launched, _ = Proc.relaunch()
      local why = if (launched == nil or launched.argv[2] ~= "--artifact" or launched.argv[3] == nil) then
        "this program is no portable artifact to take its database from" else
        "it is given no closure store to seal" end
      return cannot("its module declares lua, so what its tests start runs a sealed " ..
          "database of its closure, which cannot be made: " .. why, false, nil)
    end
    local kept = rec.plans[job.m.path]
    local plan: test_sandbox.Plan
    if kept ~= nil then
      plan = test_sandbox.rebind(kept.plan, kept.scratch, scratch, effective)
    else
      plan = test_sandbox.plan(rec.root, scratch, effective, worker_view(), store,
        rec.projection)
      if plan.trouble == "" then rec.plans[job.m.path] = { plan = plan, scratch = scratch } end
    end
    if plan.over > 0 then
      return cannot("its sandbox would give it " .. plural.count(plan.over, "path") ..
          " more than the most one holds", false, nil)
    end
    if plan.trouble ~= "" then
      return cannot(plan.trouble, true, nil)
    end
    job.plan = plan
    -- Where its sandbox gives it the store, whichever that is.
    attached = build_paths.under(test_sandbox.output).projection
    if plan.own_scratch then
      -- Its worker makes its directory in a tmpfs of its own, where no
      -- host directory is in its root: the runner keeps none, and nothing
      -- is left of it once the worker ends.
      local gone, gone_trouble = Fs.remove_tree(scratch)
      if not gone then
        return cannot("could not remove its unused directory " .. scratch .. ": " ..
            gone_trouble, false, nil)
      end
      job.scratch, job.tmp, job.own_scratch = nil, nil, true
    end
    env = plan.env
    -- The worker starts in the root of its sandbox, which has no tree to
    -- start in until the worker enters it ([`worker.run`]).
    root, inside, cwd = test_sandbox.tree, test_sandbox.scratch, "/"
  else
    -- Unsandboxed, the worker is given the environment its key holds
    -- (the pinned variables, its declared ones and the host's cores
    -- cache: [`view_of`]) with TMPDIR its scratch directory, as a sandbox gives it at
    -- [`test_sandbox.scratch`]. The key names that, not this path, which
    -- is new every run. Nothing holds it to the rest of what it declares.
    --
    -- It sees the tree where it is, not at /tree, so its key holds that
    -- path ([`declared_of`], [`declared_key.Spec`]'s `tree`): a verdict
    -- that turns on it stands only in a checkout at the same path. No
    -- host this runs on can give it the tree at a fixed path instead:
    -- a bind mount needs the user namespace a sandbox would have had,
    -- and a link at a fixed name is resolved by `getcwd` and `realpath`
    -- to the tree's own path.
    --
    -- A test that declares loopback addresses is keyed as offline, as
    -- a sandbox runs it, but here runs online, in the host's network
    -- namespace: a reach past loopback goes unnoticed here, and a Linux
    -- leg's sandbox, which runs it offline, is what fails it.
    --
    -- It attaches the store of its closure, as a sandbox gives it at its
    -- build directory's cosmic.db ([`given_store`]), and runs the core on the sealed
    -- database of its closure ([`sealed_for`]); nothing keeps it from the
    -- program's own file, which only a sandbox hides.
    -- TODO: hand that store on to what the test starts, once a cosmic
    -- run can be told which store to read in place of its tree's
    -- projection (a variable build.tree_root reads): today a process
    -- the test starts, which a sandbox would give the closure store in
    -- place of the projection, reads the whole projection, which its key holds
    -- only by the closure store's bytes; a Linux leg's sandbox
    -- enforces what macOS trusts.
    local store, store_trouble = given_store(rec, job.m)
    if store == nil and store_trouble ~= "" then
      return cannot(store_trouble, false, nil)
    end
    attached = store or rec.projection
    -- Unsandboxed too it starts the core on the sealed database of its
    -- closure, so what it and its starts read of the program is what its
    -- key holds; only a sandbox keeps it from the program's own file.
    sealed, sealed_trouble = sealed_for(rec, job.m)
    if sealed == nil and sealed_trouble ~= "" then
      return cannot(sealed_trouble, false, nil)
    end
    local homed, home_trouble = test_sandbox.unenforced_home(rec.root, scratch)
    if not homed then
      return cannot(home_trouble, false, nil)
    end
    env = test_sandbox.unenforced_environment(worker_view(), rec.effective[job.m.path], scratch,
      rec.root)
  end
  local started_ns = Clock.monotonic_ns()
  job.started_ns = started_ns
  job.deadline_ns = started_ns + rec.timeout_ns
  -- Sandboxed, a worker whose module does not declare `tool` may not
  -- run this program ([`confine.forbid_running`]): what it would run
  -- is no input of its test's key; and one whose module does not
  -- declare `nests` may not make a root of its own ([`hold_of`]), which
  -- every process it starts learns from its environment
  -- ([`confine.held_variable`]).
  local declared = job.m.inputs
  local hold = hold_of(rec, job.m)
  if rec.sandbox then
    local given: mut {string:string} = {}
    for name, value in pairs(env) do given[name] = value end
    given[confine.held_variable] = hold ~= "none" and job.m.path or nil
    env = given
  end
  -- The grants hold the worker from its first instruction, but the core it
  -- is started from must be run to start it, so a worker whose module does
  -- not declare `tool` still puts up the ruleset that forbids it running
  -- the program again ([`worker.run`]'s `forbid_running`).
  local policy: Sandbox.Policy? = nil
  local runs: {string} = {}
  if rec.sandbox then
    -- A worker that may run the program has nothing to forbid: the ruleset
    -- the policy puts up already refuses it every mount.
    if hold == "mounts" then hold = "none" end
    local made, made_trouble = policy_of(rec, job)
    if made == nil then
      return cannot(made_trouble, true, nil)
    end
    policy = made
    policy.database = if sealed ~= nil then { path = sealed } else nil end
    if hold == "forbid" then
      local ran, ran_trouble = test_policy.runs(policy)
      if ran == nil then
        return cannot(ran_trouble, true, nil)
      end
      runs = ran
    end
  end
  -- A worker on a sealed database starts as the core on it, with no
  -- launcher, artifact or descriptor of the program's: a sandboxed one by
  -- this program's name, which its policy's `database` makes the core
  -- ([`Child.start`]); an unsandboxed one by the core itself.
  local started = start
  if sealed ~= nil then
    if rec.sandbox then
      local executable, executable_trouble = Proc.executable()
      if executable == nil then
        return cannot("this program's name: " .. executable_trouble, false, nil)
      end
      started = { argv = { executable }, env = {}, fds = {} }
    else
      started = { argv = { start.argv[1], "--database", sealed }, env = {}, fds = {} }
    end
  end
  local plan = job.plan
  local command = worker.invocation({
    start = started, env = env, root = root, cwd = cwd, module_path = job.m.path,
    name = job.name, scratch = inside, own_scratch = job.own_scratch, needs = test_inputs.canonical(declared), hold = hold,
    store = attached, closure = rec.closures[job.m.path], tree = rec.tree_names,
    policy = policy, runs = runs, checks = rec.checks,
    program = plan ~= nil and plan.program or nil,
  })
  return { command = command, trouble = "", refused = false, unavailable = nil }
end

return test_key
