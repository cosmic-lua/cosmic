--- The types one run of `cosmic test` is carried in, which the code that
--- keys a run's tests ([`build.test_key`]) and the runner ([`build.test`])
--- both read and write: no code, so the module holds no function and
--- is a record of types alone.
---
--- It is required as a type (`local type`), which Teal erases, so
--- neither requires it at run time and it is no module of the harness
--- (build/harness_epoch.tl): the code that makes a key names the
--- fields it reads, and a field the runner adds for its own use moves no
--- digest. A field the key code reads moves it by the edit to that
--- code, which the compiler requires of whoever renames one.

local type Child = require("cosmic.child")
local type Coverage = require("cosmic.coverage")
local type Sqlite = require("cosmic.sqlite")
local type closure_store = require("build.closure_store")
local type declared_key = require("build.declared_key")
local type host_requires = require("build.host_requires")
local type importer = require("build.importer")
local type shared_verdicts = require("build.shared_verdicts")
local type test_inputs = require("build.test_inputs")
local type test_sandbox = require("build.test_sandbox")
local type worker = require("build.test_worker")

local record test_state
  --- One verdict ever reached, by key.
  record Verdict
    passed: boolean
    run_at_ns: integer
    --- How long the run that reached this verdict took, so a test
    --- answered from it still has a duration to give `runs`.
    elapsed_ns: integer
  end

  --- How many tests this run ran, and how many it answered from a
  --- verdict that still stood.
  record Tally
    ran: integer
    cached: integer
    --- Of those that stood, how many on a verdict another checkout
    --- reached ([`build.shared_verdicts`]).
    shared: integer
    --- Of those that ran, how many no key holds, which run every time:
    --- one whose module reaches a network beyond loopback, or reads a
    --- link out of the tree.
    every: integer
    --- Of those that ran, how many passed having said, with
    --- [`Test.skip`], that this host could not check them: no verdict is
    --- kept of one, so each runs every time.
    skipped: integer
    --- Of those that ran, how many passed having made no call to `assert`
    --- ([`worker.Judgement.unchecked`]): no verdict is kept of one
    --- either, and a held run fails it.
    unchecked: integer
    --- Of the tests chosen, how many are not applicable: their module
    --- requires what this platform never has ([`host_requires`]), so none
    --- ran or stood, and no verdict is kept of one. Neither in `ran` nor
    --- in `cached`, but in the run's total.
    na: integer
  end

  --- How a run is bounded, from the command line and the environment.
  record Limits
    --- Each test's deadline, in nanoseconds.
    timeout_ns: integer
    --- How many workers run at once.
    jobs: integer
  end

  --- One test the run has to run: no verdict stands for it.
  record Job
    m: importer.Module
    --- Whether its worker was never started, since a requirement of its
    --- module is absent: it has no key, which is no reason to say it runs
    --- every time.
    unrun?: boolean
    name: string
    id: string
    --- The directory the runner made for the test, holding `real` and
    --- `tmp`, a link to it; removed once the test passes.
    scratch?: string
    tmp?: string
    --- Whether the test's directory is one its worker makes in a tmpfs of its
    --- own ([`test_sandbox.Plan`]'s `own_scratch`), so the runner has none.
    own_scratch?: boolean
    --- How its worker is sandboxed, when it is ([`build.test_sandbox`]).
    plan?: test_sandbox.Plan
    --- Sandboxed, the key its verdict is reached under, over its
    --- declared inputs as they were before it started
    --- ([`build.declared_key`]); nil for one that reaches a network beyond
    --- loopback, or an unsandboxed run's.
    declared?: string
    passed?: boolean
    handle?: Child.Handle
    started_ns?: integer
    deadline_ns?: integer
  end

  --- Why a module's tests are not run on this host: a requirement of its
  --- module ([`host_requires`]) it lacks.
  record Unmet
    --- "na" where the platform never has it, "skipped" where this host lacks
    --- it, "refused" where its name breaks the table's rules.
    kind: host_requires.Kind
    --- The requirement and why, as the report says it.
    why: string
  end

  --- What the sealed databases of a run are made from (`sealing_for`).
  record Sealing
    --- The run's own directory, open to the user a sandboxed worker runs as,
    --- where each sealed database and the program's own are written.
    directory: string
    --- The program's own database, written in `directory`.
    program: string
  end

  --- Everything a finished job's verdict is recorded into.
  record PlanMade
    plan: test_sandbox.Plan
    scratch: string
  end

  --- One test's share of a violation a checked run met.
  record MetViolation
    key: string
    test: string
    count: integer
  end

  record Recording
    records: Sqlite.Handle
    root: string
    -- The binary's runtime identity and the digest of its data tables.
    runtime: string
    run_at_ns: integer
    run: integer
    failures: {string}
    errors: {string}
    --- Each skipped test's id and why ([`Test.skip`], or a requirement of
    --- its module the host lacks), as "<id>: <reason>".
    skips: mut {string}
    --- Each test that passed having made no call to `assert`, by id.
    unchecked: mut {string}
    --- What each test that passed deliberately without checking
    --- ([`Test.passed_unchecked`]) said, one entry per test.
    deliberate: mut {string}
    --- Whether the run is held ([`Run.held`]).
    held: boolean
    --- Each not applicable test's id and why, in the same shape.
    nas: mut {string}
    --- The modules whose requirements ([`host_requires`]) are not all
    --- present on this host, by path, and what each answered: their tests
    --- are not started and have no key.
    unmet: mut {string:Unmet}
    --- What the host answered to each module's requirements, by path, as
    --- its key holds them: each present answer's name and key text. Empty
    --- for a module that requires nothing.
    answered: mut {string:{string:string}}
    --- What each failing test printed, by its id.
    outputs: mut {string:string}
    --- Each failing test's `<file>:<name>` selector, by its id: what
    --- `cosmic test` takes to run that one test again.
    reruns: mut {string:string}
    --- Each failing test's id, by its entry in `failures`: the id is
    --- carried rather than parsed back out of text a path may put
    --- spaces in.
    failed: mut {string:string}
    hits: Coverage.Hits
    --- Each test's own hits, encoded as it finishes. Kept as tables, every
    --- test's lines would stay in memory until the run ends: hundreds of
    --- megabytes.
    by_test: {string: string}
    --- The core's C when the tree is not cosmic's own: its hits are kept
    --- out of every record of the run (see `write_coverage`).
    unowned: Coverage.Hits
    tally: Tally
    --- Whether the run is checked (`--check-types`), and what its workers
    --- reported of the values that crossed a typed boundary as a kind the
    --- declared type does not admit (`take_violations`): each distinct one by
    --- its key, in the order first met, the test that first met it, how many
    --- the workers kept no record of.
    checks: boolean
    --- What a checked run's keys hold beside the bytes ([`declared_key.Spec`]'s `checks`), nil for
    --- an ordinary run.
    mut checks_part?: string
    --- The file of each module of the tree, by its name, which a traceback
    --- names a frame by.
    files: mut {string:string}
    violations: mut {string:worker.Violation}
    violation_order: mut {string}
    violation_tests: mut {string:string}
    violations_dropped: integer
    --- Which test met which violation, and how often (`take_violations`): a
    --- row to each test and distinct violation, in the order met. Where
    --- `violation_tests` names only the first test to meet one.
    --- How many reads of a narrowed place and how many typed parameters the compile of this run wrote a check of
    --- ([`importer.Result`]'s `fact_wraps`), summed over the tree: 0 for an unchecked run.
    fact_wraps: integer
    parameter_checks: integer
    violation_met: mut {MetViolation}
    --- How many violations each test that met any reported, those its worker
    --- kept no record of included, and the seconds it ran.
    violators: mut {string:integer}
    violator_ns: mut {string:integer}
    --- How many jobs `--bail` left unstarted after the first failure
    --- (`run_jobs`). Such a test made no verdict, pass or fail, and is
    --- in no figure of the tally.
    not_run: integer
    --- The verdicts every checkout shares, or nil, and what the run owes
    --- them when it ends.
    shared?: shared_verdicts.Cache
    owed: shared_verdicts.Owed
    --- Each key a verdict of this run stands under, its
    --- shared key, for `owed.used`.
    shared_keys: mut {string:string}
    --- What names this checkout among the rows it shares (`checkout_id`).
    origin: string
    --- Each selected module's effective inputs, by path, and the program
    --- running the tests, which `tool` declares.
    effective: mut {string:test_inputs.Effective}
    tool?: {string}
    --- Whether each worker runs sandboxed ([`build.test_sandbox`]): the
    --- switch does not turn it off and the kernel can. `effective` then
    --- holds every selected module's inputs, and `views` the environment
    --- its workers are given, by module path.
    sandbox: boolean
    --- What reruns one test as this run ran it: the switch as the run was
    --- given it ([`test_sandbox.mode`]), or "" when unset.
    rerun_prefix: string
    views: mut {string:{string:string}}
    --- What keys each verdict ([`build.declared_key`]): the
    --- digests of the tree's files the run has taken, and the compiler's
    --- identity ([`build.identity`]'s `Identities`) as the running tool's `meta`
    --- names it, `compiler` and then `compiled_by`, which a key holds
    --- only where its closure reads it ([`declared_key.reads_compiler`]).
    digests?: declared_key.Digests
    compiler?: string
    --- The host's identity every key holds
    --- ([`declared_key.host_identity`]), what it has installed, which only
    --- the key of a module given the system's paths holds
    --- ([`declared_key.system_identity`]), and why each module whose tests
    --- have no key has none, but for the network, by module path.
    host?: string
    system?: string
    --- The digest of the rest of the host's identity but its features
    --- ([`declared_key.host_split`]), the identities of other hosts of
    --- that rest the shared verdicts name, which `accept_foreign` looks
    --- a verdict up under (`foreign_hosts`, worked out once a run).
    mut host_rest?: string
    mut foreign_hosts?: {string}
    accept_foreign: boolean
    --- The harness's epoch (build/harness_epoch.tl), which every key
    --- holds in place of the harness's code, and the timeout each worker
    --- runs under ([`Limits.timeout_ns`]), which every key holds too: a
    --- pass reached under a longer one need not come under a shorter.
    epoch: string
    timeout_ns: integer
    --- The program a test that runs this program runs
    --- ([`declared_key.program_identity`]), worked out once a key needs
    --- it (`program_of`).
    program?: string
    --- The digest of the code that writes a closure store (`Harness`),
    --- and the set of the modules of the tree the binary carries, which
    --- a worker's loads are held to ([`worker.judge`]).
    store_salt: string
    carried: {string:boolean}
    --- Where an artifact runs the tests (the tree's tool, or a
    --- portable cosmic), what runs its core
    --- ([`declared_key.launcher_identity`]), which every key holds; nil
    --- where a host program does.
    launcher?: string
    unkeyed: mut {string:string}
    --- Whether each module's workers can be kept from running this
    --- program (`can_forbid`), by module path.
    forbiddable: mut {string:boolean}
    --- Where the host caches each module declares are ([`build.caches`]),
    --- by module path, as `caches_of` resolves them.
    caches: {string:{string}}
    --- Each selected module's import closure, by path: the names of its
    --- modules, which its worker holds its `require`s to
    --- ([`test_inputs.modules`], [`build.test_worker`]).
    closures: mut {string:{string}}
    --- The requires a closure does not follow, which make no module a
    --- worker loads (`test.type_only_imports`).
    type_only: {string:{string:boolean}}
    --- The same, each a set of names, made as a verdict needs one
    --- (`closure_set`).
    closure_sets: mut {string:{string:boolean}}
    --- The sandbox plan of the first worker started of each module, by path,
    --- and the scratch directory it was made for: a later worker of the
    --- module takes it rebound to its own ([`test_sandbox.rebind`]).
    plans: mut {string:PlanMade}
    --- A module's hit lines as a `coverage_by_test` row holds them, and the
    --- lines `take_hits` has folded into `hits`, each by the table
    --- [`worker.decode`] shares among the reports that held them. Per run:
    --- a table folded into another run's `hits` is not in this one's.
    spelled: {{integer:boolean}:string}
    folded: {{integer:boolean}:boolean}
    --- Every module of the tree, by path, sorted: what a worker refuses a
    --- `require` of outside its closure ([`build.test_worker`]).
    tree_names: mut {string}
    --- The address of the store of each module's import closure its
    --- workers are given at their build directory's cosmic.db, or attach unsandboxed
    --- ([`build.closure_store`]'s `write`), by path, for every test and
    --- example module of the tree that does not declare `store`; the
    --- projection that store is derived from, its basis, and each store
    --- built or found this run, by address (`store_at`). A key holds a
    --- store by its bytes ([`declared_key.store_digest`]), the address
    --- only where it is and whether it must be written.
    stores: mut {string:string}
    --- What sealing the databases of the workers that run on one needs,
    --- made the first time one is: the directory they are written in, the
    --- program's own database written there (`sealing_for`); the reason
    --- there is none, or nil before it is made.
    sealing?: Sealing
    sealing_trouble?: string
    --- The path of the sealed database of each closure store, by its
    --- address (`sealed_for`).
    sealed: mut {string:string}
    --- How many sealed databases this run wrote, their bytes, and the time
    --- taken (`sealed_for`).
    sealed_written: integer
    sealed_bytes: integer
    sealed_ns: integer
    projection?: string
    --- The path of the projection's `uses` keyed by source module, made
    --- by the first store this run writes (`extraction_for`); nil
    --- until then.
    extraction?: string
    basis?: closure_store.Basis
    built: mut {string:string}
    --- The address of the store of no module, which holds what every
    --- closure store holds alike -- the schema, as the code that writes
    --- it lays it out, and the `meta` rows each keeps -- and which the
    --- census names by its bytes (`base_store_digest`).
    base_store?: string
    --- The digest of the bytes of each store this run keyed a test by, by
    --- address (`address_digest`), and whether it may take one from the
    --- shared verdicts: not under `--no-shared`, which stands on nothing
    --- another checkout kept. And the core the stores' addresses are
    --- salted with: the runtime's identity, less the run's other parts.
    store_digests: mut {string:string}
    consult_shared: boolean
    store_runtime?: string
    --- The identity of the core the run's workers run ([`declared_key.runtime_identity`]),
    --- which the key of a worker on a sealed database holds in place of the
    --- launcher (`seals`).
    core?: string
    --- The digest of the program's modules the tree lacks (`extras_digest`).
    extras?: string
    --- What the shared verdicts keep of each address this run looked up
    --- ("" for none), the closure and kind each address was keyed for, and
    --- the addresses whose bytes it found to differ, said once each.
    store_kept: mut {string:string}
    store_names: mut {string:{string}}
    store_bases: mut {string:boolean}
    store_mismatched: mut {string:boolean}
    --- How many of them this run wrote, their bytes, and the time taken.
    written: integer
    written_bytes: integer
    writing_ns: integer
  end
end

return test_state
