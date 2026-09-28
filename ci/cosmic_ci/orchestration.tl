local ContextEnv = require("cosmic_ci.context")
local Env = require("cosmic.env")
local Fixture = require("cosmic_ci.fixture")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local Hash = require("cosmic.hash")
local LauncherSetup = require("cosmic_ci.launcher_setup")
local ProductSetup = require("cosmic_ci.product_setup")
local Archive = require("cosmic.archive")
local Proc = require("cosmic.proc")
local Runner = require("cosmic_ci.runner")
local RuntimeSetup = require("cosmic_ci.runtime_setup")
local State = require("cosmic_ci.state")
local Time = require("cosmic.time")

local record Orchestration
  stands: function(env: {string:string}): boolean
  test_words: function(env: {string:string}): {string}
  shares: function(env: {string:string})
  fixture: function(env: {string:string}, tmpdir: string): {string:string}
  forget_run: function(env: {string:string})
  suite_run: function(extra?: {string:string}): {string}, {string:string}
  portable_verdicts: function(env: {string:string}): string
end

local function mkdir(path: string) assert(Fs.mkdirs(path)) end

local exists = Predicate.exists
local is_dir = Predicate.is_dir
local function read(path: string): string return (assert(Fs.read(path))) end
local function hash(path: string): string return Hash.hex_sha256(read(path)) end
local function write(path: string, data: string) assert(Fs.write(path, data)) end
--- The events whose run a suite may stand on verdicts in (`stands`): a
--- push, main's or a branch's, and the merge queue's run, which restores main's
--- verdicts (ci.yml's "restore test verdicts") and so runs only what its
--- merge moved from what main's last run reached. A manual run and
--- main's scheduled one are the backstop, running every test.
local standing_events: {string:boolean} = { push = true, merge_group = true }

--- Whether a suite stands on the verdicts its tests' declared inputs
--- key (build/declared_key.tl), this leg's earlier runs' among them
--- (COSMIC_VERDICT_CACHE, which ci.yml restores per leg), in `env`: on a
--- leg whose workers are sandboxed, and required to be
--- (COSMIC_CI_REQUIRE_SANDBOX=1) -- the Linux legs -- or keyed by what
--- they declare without a sandbox (COSMIC_CI_DECLARED_KEYS=1, which
--- `environment` makes COSMIC_TEST_KEY=declared) -- the macOS leg --
--- in a run of an event of `standing_events` (COSMIC_CI_EVENT): a push,
--- main's as much as another branch's, or the merge queue's; each
--- restores the newest cache of its leg, host and host features
--- (ci.yml's "name the leg's host"). Nothing holds a macOS worker to
--- its declaration, but a Linux leg's sandbox holds the same test,
--- under the same declaration and closure, which its key holds, so a
--- declaration that lies fails there before it merges; what reads
--- something only on macOS is the gap (build/test.tl's `launch`). A
--- manual run and main's scheduled one run every test (`--all`) and
--- stand on nothing another run reached (COSMIC_TEST_NO_SHARED=1). So
--- no gating run runs every test: a pass a key does not answer for --
--- a test that turns on the clock, or a flaky one -- is caught only by
--- main's scheduled run, the next day, whose failure GitHub tells only
--- whoever last edited its cron line (the TODO on ci.yml's
--- `schedule`).
-- TODO: share a Linux leg's verdicts across its runners only once the
-- key holds what a host's package database does not say (the TODO on
-- build/declared_key.tl's `system_identity`): today they are keyed by
-- the leg's container as ci.yml names it (COSMIC_HOST_ID: the image
-- reference, a hash of .github/scripts/leg-container.sh and the seccomp
-- profile, which hold every option and host setting it starts with, and
-- the engine's version), but a change inside an image under the same
-- reference, or on the runner beneath it, is not. The macOS leg's
-- image names itself (COSMIC_SYSTEM_ID, .github/scripts/leg-host-id.sh),
-- which every module given the system's paths is keyed by.
function Orchestration.stands(env: {string:string}): boolean
  return (env.COSMIC_CI_REQUIRE_SANDBOX == "1" or env.COSMIC_CI_DECLARED_KEYS == "1") and
    standing_events[env.COSMIC_CI_EVENT or ""] == true
end

--- Sets `env` for a suite that stands on nothing another run reached
--- (COSMIC_TEST_NO_SHARED=1) where it does not stand on verdicts
--- (`stands`).
function Orchestration.shares(env: {string:string})
  if not Orchestration.stands(env) then env.COSMIC_TEST_NO_SHARED = "1" end
end

--- A suite's `cosmic test` words in `env`: `--all` where it stands on
--- nothing (`stands`).
function Orchestration.test_words(env: {string:string}): {string}
  if Orchestration.stands(env) then return { "test" } end
  return { "test", "--all" }
end

--- The environment every operation runs in: the driver's own, with
--- FUZZ_ITERS=0, so a suite checks each fuzz property's corpus of kept
--- failures but draws no inputs of its own. Drawing is fuzz.yml's, each
--- night with a seed of its own: a check that gates a change answers the
--- same on every run, and one that searches runs where a find blocks
--- nobody's merge. A gating suite's is then rid of what names the run
--- (`suite_run`, `forget_run`).
local function environment(extra?: {string:string}): {string:string}
  local all = Env.all()
  all.FUZZ_ITERS = "0"
  if extra then for k, v in pairs(extra) do all[k] = v end end
  -- What follows is decided on the leg's environment, `extra`
  -- included, which may name the leg itself (`suite_run`, a test's).
  -- Where it does not stand on verdicts (`stands`), a suite stands on
  -- none another run reached, only on what it runs itself.
  Orchestration.shares(all)
  -- Where the leg is given what spawn's sandbox needs, every suite runs
  -- each worker sandboxed (build/test_sandbox.tl), as `cosmic test`
  -- does by default wherever it can, and fails where it cannot rather
  -- than run them unsandboxed; and every build.confine `confine` of a
  -- test is a `must_confine` there (COSMIC_SANDBOX=must,
  -- build/confine.tl), so a process a test confines
  -- runs confined or fails the test, never unconfined, and the sandbox
  -- tests of core/syscalls_test.tl cannot pass unchecked. The mode
  -- also runs every test no key can hold, as --all does; a sandboxed
  -- run has none.
  if all.COSMIC_CI_REQUIRE_SANDBOX == "1" then
    all.COSMIC_TEST_SANDBOX = "1"
    all.COSMIC_SANDBOX = "must"
  end
  -- Where the leg has no sandbox but stands on verdicts all the same
  -- (COSMIC_CI_DECLARED_KEYS, the macOS leg), every operation is given
  -- COSMIC_TEST_KEY=declared, which only `cosmic test` reads: each
  -- suite keys each test by what it declares (build/test.tl's
  -- `key_mode`), which a Linux leg's sandbox enforces, rather than by
  -- what it was seen to read, which no other checkout shares. A
  -- fixture's run takes it back out (`Orchestration.fixture`), and a
  -- test's own `cosmic test` is not given it (`test.worker_environment`).
  if all.COSMIC_CI_DECLARED_KEYS == "1" then all.COSMIC_TEST_KEY = "declared" end
  return all
end

--- Variables that name this run, its runner or its container rather than
--- anything a test is given: systemd's per-unit ones where a runner is a
--- service, CI, and the container's HOSTNAME (its ID, new every job).
local run_only: {string:boolean} = {
  CI = true, INVOCATION_ID = true, JOURNAL_STREAM = true, HOSTNAME = true,
}

--- Whether `name` says which run, runner or job this is, or is a switch
--- the driver alone reads: GitHub's (GITHUB_*, RUNNER_*, ACTIONS_*),
--- `run_only`'s, and the driver's COSMIC_CI_* but
--- COSMIC_CI_REQUIRE_SANDBOX, which a test reads
--- (build/sandboxed_verdicts_test.tl).
local function names_the_run(name: string): boolean
  if name == "COSMIC_CI_REQUIRE_SANDBOX" then return false end
  return run_only[name] or name:sub(1, 7) == "GITHUB_" or
    name:sub(1, 7) == "RUNNER_" or name:sub(1, 8) == "ACTIONS_" or
    name:sub(1, 10) == "COSMIC_CI_"
end

--- Removes from `env`, a gating suite's, every variable that names the
--- run (`names_the_run`). A test that reads the whole environment
--- (`env = {"*"}`) is keyed by every variable its worker is given, so
--- one that moves each run (GITHUB_RUN_ID, GITHUB_SHA, RUNNER_NAME,
--- COSMIC_CI_SCOPE, ...) would keep such a test from standing on any
--- earlier run's verdict. No tree test reads one, so none is given one,
--- and what a key holds is still what the worker gets. The driver
--- decides what the suite does (`stands`, `test_words`, `shares`) before
--- this, from the environment it was given.
function Orchestration.forget_run(env: {string:string})
  local names: {string} = {}
  for name in pairs(env) do
    if names_the_run(name) then names[#names + 1] = name end
  end
  for _, name in ipairs(names) do env[name] = nil end
end

--- A gating suite's `cosmic test` words and environment, `extra` added
--- to `environment()`'s: `--all` and nothing shared where it stands on
--- no verdict (`stands`, `shares`), decided on the driver's own
--- environment, which then forgets the run (`forget_run`).
function Orchestration.suite_run(extra?: {string:string}): {string}, {string:string}
  local values = environment(extra)
  local words = Orchestration.test_words(values)
  Orchestration.forget_run(values)
  return words, values
end

--- The shared verdict cache (COSMIC_VERDICT_CACHE) the portable suite
--- keeps and stands on, given `env`, the driver's: `portable.db` beside
--- the one `env` names -- in the directory ci.yml's verdict cache saves
--- and restores, so it rides along -- or "0", none, where `env` names
--- no absolute path or turns the cache off.
---
--- Not the other suites' file: the portable artifact carries the cores
--- o/bin/cosmic does, from o/core (`ProductSetup`), so a test that does
--- not run the program (`tool`) may key the same under either -- the
--- same runtime identity, and what runs that core
--- (build/declared_key.tl's `launcher_identity`) the same wherever the
--- two artifacts' launchers and manifests are -- and the portable suite
--- would stand on the local suite's verdicts of minutes earlier,
--- running nothing under the portable build. Apart, it runs each such
--- test itself and stands only on earlier portable runs', whose keys
--- move with its launcher, cores and manifest as with anything else a
--- test is given.
function Orchestration.portable_verdicts(env: {string:string}): string
  local shared = env.COSMIC_VERDICT_CACHE or ""
  if shared:sub(1, 1) ~= "/" then return "0" end
  return shared:match("^(.*)/[^/]*$") .. "/portable.db"
end

local record Context
  db: string
  worker: string
  run: string
  attempt: string
  root: string
  driver: string
end

--- The environment variable `name`, or nil when it is unset or empty.
local function named(name: string): string | nil
  local value = Env.get(name)
  if value == "" then return nil end
  return value
end

local function operation(c: Context, phase: string, command: {string},
    timeout: integer, cwd?: string, env?: {string:string}, output?: string,
    error_output?: string): integer
  local runner: Runner.Context = { database = c.db, worker = c.worker,
    run = c.run, attempt = c.attempt, candidate = c.root }
  local child_environment: {string:string}
  if env then child_environment = env else child_environment = environment() end
  -- bin/zig shares one project cache among checkouts unless told otherwise
  -- (build/zig.tl). A candidate uses the zig-cache under
  -- COSMIC_ZIG_CACHE_SEED where CI restored it, else keeps its own under
  -- o/, which the build phase seeds. zig keys what it compiles by its
  -- own cache's path too, and CI puts the checkout at a path of the commit's
  -- own (.github/scripts/place-tree.sh), so a cache under o/ would never
  -- be reused there: CI saves the seed's as it stands.
  if (child_environment.COSMIC_ZIG_CACHE or "") == "" then
    local seed = named("COSMIC_ZIG_CACHE_SEED")
    child_environment.COSMIC_ZIG_CACHE = seed and seed .. "/zig-cache" or c.root .. "/o/zig-cache"
  end
  -- The driver boots the candidate itself; a tool that finds its core
  -- stale is a fault to report, not one to boot past (build/reboot.tl).
  if not child_environment.COSMIC_AUTO_BOOT then
    child_environment.COSMIC_AUTO_BOOT = "0"
  end
  return Runner.operation(runner, phase, { argv = command, cwd = cwd or c.root,
    env = child_environment, timeout_ms = timeout,
    output = output, error = error_output }).code
end

-- Work done in this process, recorded as an operation as a command is.
local function step(c: Context, phase: string,
    work: function(): boolean, string): integer
  local runner: Runner.Context = { database = c.db, worker = c.worker,
    run = c.run, attempt = c.attempt, candidate = c.root }
  return Runner.step(runner, phase, work).code
end

local function checked(c: Context, phase: string, command: {string},
    timeout?: integer, cwd?: string, env?: {string:string}): integer
  return operation(c, phase, command, timeout or 0, cwd, env)
end

local function logged(c: Context, phase: string, command: {string}, out: string,
    err: string, timeout: integer, cwd?: string, env?: {string:string}): integer
  local status = operation(c, phase, command, timeout, cwd, env, out, err)
  local replay_ok = Env.get("COSMIC_CI_SELFTEST_REPLAY_FAILURE") ~= "true"
  if replay_ok then
    replay_ok = Fs.put(Fs.stdout, read(out)) and Fs.put(Fs.stderr, read(err))
  end
  if not replay_ok then Fs.put(Fs.stderr, "could not replay retained output\n") end
  if status ~= 0 then return status end
  assert(replay_ok, "could not replay retained output")
  return status
end

local function capture_small(c: Context, phase: string, command: {string},
    path: string, timeout: integer, cwd?: string): integer
  return operation(c, phase, command, timeout, cwd, environment(), path)
end

-- Whole-project guards include compilation and test-runner overhead. The
-- direct children inside them have the shorter bounds defined by fixture.tl.
local product_test_timeout_ms <const> = 60000
local format_test_timeout_ms <const> = 300000
local launcher_test_timeout_ms <const> = 180000
local self_rebuild_test_timeout_ms <const> = 180000
-- Each self-rebuild test rebuilds the tool (about 20 s, several at once),
-- past the runner's default 30 s per test on a loaded machine.
local self_rebuild_per_test_timeout_s <const> = "120"
-- Each fixed-point test rebuilds the product twice from a fresh tree, and
-- the compiler's case compiles the whole tree about twice over (80 s
-- alone on four cores), so each runs apart from the self-rebuild file's.
local fixed_point_test_timeout_ms <const> = 300000
--- The whole suite on the checked core: see `checked_suite`'s comment
--- for what it takes.
local checked_suite_timeout_ms <const> = 600000
local fixed_point_per_test_timeout_s <const> = "240"
-- A boot the product drives from another path compiles no C again (it
-- compiles from copies in zig's cache, build.zig's `Own`), only the tree:
-- about 110 s for the whole fixture in a local run on four cores, loaded.
-- TODO: lower these bounds once CI's own runs show the fixture's time
-- without the core's C compile they were sized for (about 110 s of it).
local self_driven_test_timeout_ms <const> = 600000
local self_driven_per_test_timeout_s <const> = "480"
local runtime_test_timeout_ms <const> = 180000
-- The sandbox probe starts six trivial children; its bound is the
-- tree's own load, which a booted tree has already paid.
local sandbox_probe_timeout_ms <const> = 60000
local identity_test_timeout_ms <const> = 120000
-- The identity suite took 21-30 s whole on macOS, and 35 s once, when its
-- one test then ran past the runner's default 30 s per test (run
-- 36345675442); its focused-embed step took 21 s of that alone, and is a
-- test of its own now. The two run at once on a runner of two or more
-- processors, so both near this bound still end inside the whole file's.
local identity_per_test_timeout_s <const> = "60"
-- The checked cosmic's first file in the tree after the checked build
-- (`checked_suite`). A boot names the analyzer as the tool it writes
-- does (build/importer.tl's `tree_code`), so that file builds nothing
-- again: 0.3-0.7 s here, where it was a reparse of every source, 30-35 s
-- by the checked cosmic under ci/run-local on a 4-core host, once 41 s.
-- TODO: lower this bound once CI's own runs show the step's time
-- without that reparse; it is still sized for it.
local checked_compile_timeout_ms <const> = 300000

-- A whole `cosmic test` run of every test, sandboxed, takes about 96 s of
-- tests on a four-core runner (1872 tests), after a build of up to 25 s
-- where the tree is compiled cold (the portable suite, macOS) and up to
-- 10 s writing the closure stores: about 130 s whole. The merge queue's
-- run hit the old 120 s bound on linux-x86_64 and macOS (run
-- 36306898411). Each test gets far less than the whole run, so a test
-- that hangs is ended and named by the runner, not hidden under a
-- cancelled run; the run's own bound is about twice the whole.
local suite_timeout_ms <const> = 270000
local suite_test_timeout_s <const> = "10"

local function copy_flat_tl_dir(source: string, destination: string)
  local names: {string} = {}
  for _, name in ipairs((assert(Fs.list(source)))) do
    assert(name:match("%.tl$") and
      assert(Fs.stat(source .. "/" .. name)).kind == "file",
      "invalid fixture source entry: " .. name)
    names[#names + 1] = name
  end
  mkdir(destination)
  for _, name in ipairs(names) do
    write(destination .. "/" .. name, read(source .. "/" .. name))
  end
end

local function fixture_project(c: Context, work: string): string
  local project = work .. "/fixture-project"
  local driver_namespace = Fs.dirname(c.driver)
  local fixtures_source = Fs.dirname(driver_namespace) .. "/fixtures"
  assert(Fs.remove_tree(project))
  copy_flat_tl_dir(driver_namespace, project .. "/cosmic_ci")
  copy_flat_tl_dir(fixtures_source, project .. "/fixtures")
  return project
end

--- `env`, an operation's environment, made a fixture's `cosmic test`'s:
--- its temporary files under `tmpdir`, its workers unsandboxed, and no
--- verdict but one it reaches itself. A fixture reads the candidate and
--- its products where variables of `env` say (COSMIC_FIXTURE_*), which
--- no verdict's key holds, so a verdict another run reached -- of
--- another commit's products, in a leg's restored cache
--- (COSMIC_VERDICT_CACHE) -- would stand for this one's: a fixture
--- neither reads nor writes the shared verdicts, whatever the event.
--- Nor can a verdict of its own stand: its project, and the o/ under
--- it, is made afresh for each run (`fixture_project`), and it names the
--- file it runs, so none is assumed. Nor does it share the compiles
--- and parses every checkout keeps (COSMIC_BUILD_CACHE): a fixture that
--- checks what a fresh tree compiles, and what the tool built from it
--- compiles again (fixed_point_test, self_rebuild_test), must compile
--- and parse it, not take the boot's work back.
function Orchestration.fixture(env: {string:string}, tmpdir: string): {string:string}
  env.TMPDIR = tmpdir
  -- Unsandboxed: a fixture reads and runs the candidate and its
  -- products where the host has them, which its environment names
  -- (COSMIC_FIXTURE_*), and a sandboxed worker would be given none of.
  -- TODO: run the fixtures sandboxed, each declaring the paths it reads
  -- by the variable that says where they are (`Test.needs` host
  -- "$COSMIC_FIXTURE_ROOT/...", _PRODUCT, _RUNTIME: the tree side is
  -- done), once ci/cosmic-driver.pin names a release that carries host
  -- paths a variable names and knows `system`, which each fixture that
  -- starts the system's programs (/usr/bin/env, sh) then declares: a
  -- sandboxed worker is given none of them otherwise.
  env.COSMIC_TEST_SANDBOX = "0"
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_BUILD_CACHE = "0"
  env.COSMIC_TEST_NO_SHARED = "1"
  -- Nor is it keyed by what it declares, on a leg whose suites are
  -- (COSMIC_CI_DECLARED_KEYS): it shares no verdict for a key to name,
  -- and what it declares is not yet what it reads (the TODO above).
  env.COSMIC_TEST_KEY = nil
  return env
end

local function fixture_test(c: Context, work: string, name: string,
    source: string, timeout_ms: integer, extra: {string:string}): integer
  assert(name:match("^[%w-]+$"), "invalid fixture test name")
  assert(source:match("^[%w_]+$"), "invalid fixture test source")
  local project = fixture_project(c, work)
  local diagnostics = work .. "/fixture-test-diagnostics/" .. name
  mkdir(diagnostics); mkdir(diagnostics .. "/tmp")
  local out, err = diagnostics .. "/test.out", diagnostics .. "/test.err"
  return logged(c, "fixture: " .. name,
    { assert(Proc.executable()), "test",
      "fixtures/" .. source .. "_test.tl" }, out, err, timeout_ms, project,
    Orchestration.fixture(environment(extra), diagnostics .. "/tmp"))
end

--- The checked core, verified on every leg -- its manifest entry in the
--- checked artifact, read by `decoder` (the contract's
--- format-test-<target>), its range, and that the artifact runs it --
--- and its whole suite run where COSMIC_CI_CHECKED_SUITE is not `skip`.
local function checked_suite(c: Context, target: string, work: string,
    decoder: string): integer
  local sanitized = c.root .. "/o/sanitized"
  local targets_path = sanitized .. "/targets.tsv"
  local target_id: string | nil = nil
  local checked_target: string | nil = nil
  local target_records = read(targets_path)
  for line in target_records:gmatch("[^\n]+") do
    local id, configuration, name =
      line:match("^(%d+)\t(%d+)\t([^\t]+)\t[^\t]+")
    if configuration == "2" and name == "sanitized" then
      assert(not target_id, "multiple sanitized target records"); target_id = id
    end
  end
  for line in target_records:gmatch("[^\n]+") do
    local id, configuration, name, target_name =
      line:match("^(%d+)\t(%d+)\t([^\t]+)\t([^\t]+)")
    if id == target_id and configuration == "1" and name == "release" then
      assert(not checked_target, "multiple checked target records")
      checked_target = target_name
    end
  end
  assert(target_id and checked_target == target, "checked target mapping differs")
  local cosmic = sanitized .. "/bin/cosmic"
  local core = sanitized .. "/cosmic-core"
  local entry = work .. "/checked-entry.txt"
  -- The checked artifact's manifest entry, as the contract's decoder
  -- reads it (as ci/fixtures/product_test.tl reads the product's).
  local s = capture_small(c, "checked manifest entry",
    { decoder, "--inspect", cosmic }, entry, 30000)
  if s ~= 0 then return s end
  local found = Fixture.entry(Fixture.inspection(entry),
    assert(math.tointeger(tonumber(target_id))), 2)
  assert(found, "checked manifest entry is missing: " .. read(entry))
  local offset, length, digest = found.offset, found.length, found.digest
  assert(offset % 16384 == 0,
    "checked manifest entry is unaligned: " .. read(entry))
  local artifact = read(cosmic); local raw = read(core)
  assert(length == #raw and #digest == 64, "checked core length/digest invalid")
  local extracted = artifact:sub(offset + 1, offset + length)
  assert(#extracted == length and Hash.hex_sha256(extracted) == digest and
    extracted == raw, "checked core range differs")
  write(work .. "/checked.core", extracted)
  local expected = offset .. "\t" .. length .. "\t" .. digest .. "\n"
  -- That the checked artifact runs the checked core: its runtime
  -- context as a chunk run with no tree around it (`cosmic -e`) sees it,
  -- which builds and writes nothing.
  local context = work .. "/checked-context.txt"
  s = capture_small(c, "checked runtime context", { cosmic, "-e",
    "local Store = require('cosmic.store'); print(Store.meta('runtime_context'), " ..
    "Store.meta('host'), Store.meta('host_image'))" }, context, 30000)
  if s ~= 0 then return s end
  assert(read(context) == "portable-v1\t" .. target .. "\t" .. digest .. "\n",
    "checked artifact did not execute the checked raw core: " .. read(context))
  -- The suite on the checked core costs a leg two to three minutes. Most
  -- of what it checks is the same on every platform, so the workflow runs
  -- it on one leg, and the others set COSMIC_CI_CHECKED_SUITE=skip; the
  -- checked core is still built and verified above, and the fixtures
  -- still use it.
  -- TODO: the core's platform-conditional C (__APPLE__, __aarch64__ in
  -- core/syscalls.c, executable.c, ...) is not run under the sanitizer
  -- off linux-x86_64: a leg that skips the suite runs the checked cosmic
  -- only on a chunk (`-e`, above), no longer on a file in the tree, whose
  -- build (staging it, writing SQLite) was the one real code it ran
  -- there. A checked run of only the tests that enter that C, on the legs
  -- that skip the whole suite, would cover it for seconds.
  if Env.get("COSMIC_CI_CHECKED_SUITE") == "skip" then
    Fs.put(Fs.stderr, "checked suite: skipped on this leg " ..
      "(COSMIC_CI_CHECKED_SUITE=skip)\n")
    return 0
  end
  -- The checked cosmic's first file in the tree, `tool.tl entry`, whose
  -- entry must be the decoder's, under a bound of its own in case it
  -- builds the tree again, so the suite's bound below times the suite.
  local compiled = work .. "/checked-compile.txt"
  s = capture_small(c, "checked tool entry", { cosmic,
    c.root .. "/test/portable/tool.tl", "entry", cosmic, target_id, "2" },
    compiled, checked_compile_timeout_ms)
  if s ~= 0 then return s end
  assert(read(compiled) == expected,
    "the checked cosmic reads another manifest entry: " .. read(compiled))
  local diagnostics = work .. "/checked-diagnostics"; mkdir(diagnostics)
  -- c.root/o is not cleared: the sanitized binary's runtime identity
  -- differs from the release one's, so no release verdict can stand.
  -- Bounded at about twice what it takes: 271 s whole (248 to 285 over
  -- six main runs of September 2026) for 1948 tests on a 4-core host,
  -- each worker sandboxed, the checked core running each test about
  -- 2.9 times slower than the release core does; and some 30 s more
  -- once the sandbox's own tests built a stand-in program each (#2269).
  -- Its earlier bounds each timed out as the suite grew past them: 180 s,
  -- set for 1400 tests unsandboxed, once every worker was sandboxed;
  -- 320 s, set at twice 157 s for 1869 tests, at 1948 (36358276275) and
  -- at 1967. The suite stands on no verdict from an earlier run
  -- (0 stood in every run seen), though its key is meant to let it:
  -- --all where it stands on no verdict (`stands`): CI answers for
  -- every test then, whatever o/ holds.
  -- TODO: find what part of the checked suite's key moves between runs
  -- (the checked core's bytes across CI's per-commit tree paths, or a
  -- run-dependent input to its program identity), so that a commit that
  -- moves neither the core nor the runner stands on the last run's
  -- verdicts here as the local suite does; the census line that would
  -- say (build/test.tl, "none under the keys this run reached") is
  -- suppressed where the local suite already ran in this checkout.
  local checked_argv: {string} = { cosmic }
  local checked_words, checked_environment = Orchestration.suite_run()
  for _, word in ipairs(checked_words) do
    checked_argv[#checked_argv + 1] = word
  end
  s = logged(c, "checked suite", checked_argv,
    diagnostics .. "/checked-test.out", diagnostics .. "/checked-test.err",
    checked_suite_timeout_ms, c.root, checked_environment)
  write(diagnostics .. "/checked-test.status", tostring(s) .. "\n")
  -- The suite's per-test times and verdicts (its `runs` rows), which
  -- the workflow uploads with the diagnostics when the leg fails: what
  -- a timeout here leaves to read, since the suite's output names no
  -- times, and what says which tests the checked core runs slowest.
  if exists(c.root .. "/o/build.db") then
    write(diagnostics .. "/build.db", read(c.root .. "/o/build.db"))
  end
  return s
end

local function snapshot(c: Context, diagnostics: string, label: string,
    cosmic: string): integer
  assert(label:match("^[%w-]+$"), "invalid snapshot label")
  local candidate = assert(Fs.absolute(c.root))
  local destination = assert(Fs.absolute(diagnostics))
  assert(destination ~= candidate and
    destination:sub(1, #candidate + 1) ~= candidate .. "/",
    "snapshot path must be outside candidate checkout")
  local out = destination .. "/" .. label
  assert(not exists(out), "snapshot already exists: " .. out); mkdir(out)
  write(out .. "/build.db", read(c.root .. "/o/build.db"))
  if exists(c.root .. "/o/build.db-journal") then
    write(out .. "/build.db-journal", read(c.root .. "/o/build.db-journal"))
  end
  local hashes = hash(out .. "/build.db") .. "  build.db\n"
  if exists(out .. "/build.db-journal") then
    hashes = hashes .. hash(out .. "/build.db-journal") .. "  build.db-journal\n"
  end
  write(out .. "/hashes.sha256", hashes)
  local temporary_root = Env.get_or("TMPDIR", "/tmp")
  State.external_path(temporary_root .. "/probe", c.root)
  local inspect = assert(Fs.mkdtemp("cosmic-work-db-integrity-"))
  local called, answer = pcall(function(): integer
    write(inspect .. "/build.db", read(out .. "/build.db"))
    if exists(out .. "/build.db-journal") then
      write(inspect .. "/build.db-journal", read(out .. "/build.db-journal"))
    end
    write(inspect .. "/work_db_integrity.tl",
      read(c.root .. "/ci/testdata/portable/work_db_integrity.tl"))
    return logged(c, label .. " integrity",
      { cosmic, "work_db_integrity.tl", "--recover-copy", "build.db" },
      out .. "/integrity.out", out .. "/integrity.err", 30000, inspect)
  end)
  local removed, remove_trouble = Fs.remove_tree(inspect)
  assert(removed and not exists(inspect),
    "could not remove disposable integrity directory: " ..
    tostring(remove_trouble))
  if not called then error(answer) end
  return answer
end

--- One suite of `c`'s candidate, run by `executable`, `env` added to
--- its environment.
local function suite(c: Context, name: string, executable: string,
    diagnostics: string, env?: {string:string}): integer
  mkdir(diagnostics)
  local out = diagnostics .. "/" .. name .. "-test.out"
  local err = diagnostics .. "/" .. name .. "-test.err"
  local words, values = Orchestration.suite_run(env)
  values.COSMIC_TEST_TIMEOUT = suite_test_timeout_s
  local argv: {string} = { executable }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local status = logged(c, name .. " suite", argv, out, err,
    suite_timeout_ms, c.root, values)
  write(diagnostics .. "/" .. name .. "-test.status", tostring(status) .. "\n")
  local snap_called, snap_answer = pcall(snapshot, c, diagnostics,
    name .. "-immediate", executable)
  local snapshot_status = snap_called and snap_answer or 1
  if not snap_called then Fs.put(Fs.stderr, tostring(snap_answer) .. "\n") end
  if status == 124 then Fs.put(Fs.stderr, name .. " suite: timed out (status 124)\n")
  elseif status ~= 0 then Fs.put(Fs.stderr,
name .. " suite: failed (status " .. status .. ")\n") end
  if status ~= 0 then return status end
  if snapshot_status ~= 0 then return snapshot_status end
  return 0
end

local function archive(c: Context, destination: string): integer
  assert(not exists(destination), "archive destination already exists: " .. destination)
  mkdir(destination)
  local tar = destination .. ".tar"
  local status = checked(c, "tracked source archive",
    { "/usr/bin/env", "git", "-C", c.root, "archive", "--output", tar, "HEAD" })
  if status ~= 0 then return status end
  status = step(c, "tracked source extract", function(): boolean, string
    local written, trouble = Archive.extract(tar, destination,
      { links = "create" })
    return written ~= nil, trouble
  end)
  assert(not exists(destination .. "/o"), "tracked source archive holds o/")
  return status
end

local targets: {string:boolean} = {
 ["x86_64-linux-musl"] = true, ["aarch64-linux-musl"] = true, ["aarch64-macos"] = true }

local record PlatformContext
  trailing: string | nil
  operation: Context
  root: string
  target: string
  work: string
  product: string
  contract: string
  runtime: string
  local_diagnostics: string
  portable_diagnostics: string
  fresh: string
end

local function phase_build(p: PlatformContext): integer
  local c = p.operation
  local root = p.root
  local local_d = p.local_diagnostics
  assert(not exists(root .. "/o"), "build requires fresh checkout without o")
  -- zig's caches are used where CI restored them: its global cache
  -- (COSMIC_ZIG_GLOBAL_CACHE, build/zig.tl) and the project cache, the
  -- zig-cache under COSMIC_ZIG_CACHE_SEED (see `operation`). Only a
  -- local run's is copied into o/, from the project cache
  -- COSMIC_ZIG_CACHE_FROM names, a developer's shared one.
  local seed = named("COSMIC_ZIG_CACHE_SEED")
  local from = named("COSMIC_ZIG_CACHE_FROM")
  local cache = seed and seed .. "/zig-cache" or from
  -- A cache named but absent costs a cold compile of vendor/ and core/
  -- (minutes) and fails nothing, so say so where the log shows it.
  if cache and not is_dir(cache) then
    Fs.put(Fs.stderr, "build: no zig-cache at " .. cache ..
      "; compiling from nothing\n")
  end
  if not seed and from and is_dir(from) then
    mkdir(root .. "/o")
    local copied = step(c, "restore zig-cache", function(): boolean, string
      return Fs.copy_tree(from, root .. "/o/zig-cache")
    end)
    if copied ~= 0 then return copied end
  end
  local s = checked(c, "core build and boot", { root .. "/bin/zig", "build", "cores", "boot" }, 0)
  if s ~= 0 then return s end
  return suite(c, "local", root .. "/o/bin/cosmic", local_d)
end

local function phase_local_boundary(p: PlatformContext): integer
  local c = p.operation
  local root = p.root
  local local_d = p.local_diagnostics
  local s = snapshot(c, local_d, "local-boundary", root .. "/o/bin/cosmic"); if s ~= 0 then return s end
  assert(read(local_d .. "/local-immediate/hashes.sha256") == read(local_d .. "/local-boundary/hashes.sha256"), "local database changed across boundary"); return 0
end

--- What the candidate's own sandbox (core/process.h's `Sandbox`) can
--- hold a child to on this worker, part by part, as
--- build/sandbox_probe.tl finds it, written to the run's summary: whether
--- a test run here could be confined to its declared inputs at all.
--- Where COSMIC_CI_REQUIRE_SANDBOX=1 it fails when a part a confined test
--- needs did not hold: ci.yml gives each Linux leg what the sandbox needs
--- and sets it there, so a refusal means the leg lost it. Elsewhere (a
--- ci/run-local on a host that refuses a namespace) it only reports.
--- The report goes to the summary either way.
local function phase_sandbox(p: PlatformContext): integer
  local c = p.operation
  local report = p.work .. "/sandbox-probe.md"
  local s = capture_small(c, "sandbox probe", { p.root .. "/o/bin/cosmic",
    "build/sandbox_probe.tl" }, report, sandbox_probe_timeout_ms)
  if s ~= 0 then return s end
  local said = read(report)
  ContextEnv.summarize("## Sandbox probe (" .. c.worker .. ")\n\n" .. said .. "\n")
  assert(Fs.put(Fs.stdout, said))
  local refused = said:match("Confinement: %*%*unavailable%*%*[^\n]*")
  if refused and named("COSMIC_CI_REQUIRE_SANDBOX") == "1" then
    assert(Fs.put(Fs.stderr, "sandbox: this worker cannot confine a test: " .. refused .. "\n"))
    return 1
  end
  return 0
end

--- The tree's format check, which `fix --check` also builds and
--- type-checks it for: the first thing assemble does, and all a branch
--- push's light run does after the native suite (see ci.yml's
--- COSMIC_CI_SCOPE). A tree formats and type-checks the same on every
--- platform, so the workflow runs it on one leg, and the others set
--- COSMIC_CI_FORMAT=skip, as COSMIC_CI_CHECKED_SUITE does the checked
--- suite.
local function format_check(p: PlatformContext): integer
  assert(exists(p.local_diagnostics .. "/local-boundary/hashes.sha256"),
    "no local-boundary snapshot; run the local-boundary phase first")
  if Env.get("COSMIC_CI_FORMAT") == "skip" then
    Fs.put(Fs.stderr, "format check: skipped on this leg " ..
      "(COSMIC_CI_FORMAT=skip)\n")
    return 0
  end
  return checked(p.operation, "format check",
    { p.root .. "/o/bin/cosmic", "fix", "--check", "." })
end

local function phase_assemble(p: PlatformContext): integer
  local c = p.operation
  local root = p.root
  local target = p.target
  local work = p.work
  local product = p.product
  local contract = p.contract
  local runtime = p.runtime
  local portable_d = p.portable_diagnostics
  local fresh = p.fresh
  local s = format_check(p)
  if s ~= 0 then return s end
  s = checked(c, "codesign verification",
    { root .. "/bin/verify-codesign",
      root .. "/o/core/aarch64-macos/cosmic-core" })
  if s ~= 0 then return s end
  assert(ProductSetup.build(root, product, work .. "/product-setup") == product,
    "product setup returned the wrong product")
  write(work .. "/cosmic.before.sha256", hash(product .. "/cosmic") .. "\n")
  write(work .. "/product.before.sha256", read(product .. "/hashes.sha256"))
  s = fixture_test(c, work, "format-contract", "format",
    format_test_timeout_ms, {
    COSMIC_FIXTURE_ROOT = root,
    COSMIC_FIXTURE_FORMAT = contract .. "/format",
    COSMIC_FIXTURE_TARGET = target,
  })
  if s ~= 0 then return s end
  assert(LauncherSetup.build(root, contract .. "/launcher", target,
    work .. "/launcher-setup") == contract .. "/launcher",
    "launcher setup returned the wrong output")
  s = checked(c, "checked build", { root .. "/bin/zig", "build", "sanitized" })
  if s ~= 0 then return s end
  s = checked_suite(c, target, work, contract .. "/format/format-test-" .. target)
  if s ~= 0 then return s end
  s = checked(c, "hook-core build", { root .. "/bin/zig", "build", "portable-hook-cores", "--prefix", work .. "/prebuilt" }); if s ~= 0 then return s end
  mkdir(work .. "/prebuilt/portable-fixture/sanitized")
  write(work .. "/prebuilt/portable-fixture/sanitized/cosmic-core", read(root .. "/o/sanitized/cosmic-core"))
  assert(RuntimeSetup.build(root, work .. "/prebuilt", product .. "/cosmic",
    product .. "/cosmic.db", runtime, work .. "/runtime-setup") == runtime,
    "runtime setup returned the wrong output")
  s = fixture_test(c, work, "product-verification", "product",
    product_test_timeout_ms, {
    COSMIC_FIXTURE_PRODUCT = product,
    COSMIC_FIXTURE_TARGET = target,
    COSMIC_FIXTURE_DECODER = contract .. "/format/format-test-" .. target,
    COSMIC_FIXTURE_CODESIGN = target == "aarch64-macos" and "true" or "false",
  }); if s ~= 0 then return s end
  s = checked(c, "selected format mutation", { contract .. "/format/format-test-" .. target, contract .. "/format/program" }); if s ~= 0 then return s end
  s = archive(c, fresh); if s ~= 0 then return s end
  mkdir(portable_d); write(portable_d .. "/cosmic-portable", read(product .. "/cosmic"));
  s = step(c, "portable executable mode", function(): boolean, string
    return Fs.chmod(portable_d .. "/cosmic-portable", 0x1ed)
  end)
  if s ~= 0 then return s end
  write(portable_d .. "/portable-artifact.before.sha256", hash(portable_d .. "/cosmic-portable") .. "\n"); return 0
end

local function phase_portable(p: PlatformContext): integer
  local c = p.operation
  local portable_d = p.portable_diagnostics
  local fresh = p.fresh
  local executable = portable_d .. "/cosmic-portable"
  local portable_context: Context = { db = c.db, worker = c.worker, run = c.run,
    attempt = c.attempt, root = fresh, driver = c.driver }
  -- Where the other suites stand on verdicts (`stands`), it stands on
  -- its own (`portable_verdicts`), never on the local suite's;
  -- elsewhere it runs every test, as they do.
  local s = suite(portable_context, "portable", executable, portable_d,
    { COSMIC_PORTABLE_CACHE = portable_d .. "/portable-full-suite-cache",
      COSMIC_VERDICT_CACHE = Orchestration.portable_verdicts(Env.all()) })
  local hash_called, hash_error = pcall(function(): boolean
    write(portable_d .. "/portable-artifact.after.sha256", hash(executable) .. "\n")
    assert(read(portable_d .. "/portable-artifact.before.sha256") ==
      read(portable_d .. "/portable-artifact.after.sha256"),
      "portable artifact changed")
    return true
  end)
  if not hash_called then Fs.put(Fs.stderr, tostring(hash_error) .. "\n") end
  if s ~= 0 then return s end
  if not hash_called then return 1 end
  return s
end

local function phase_portable_boundary(p: PlatformContext): integer
  local c = p.operation
  local portable_d = p.portable_diagnostics
  local fresh = p.fresh
  local portable_context: Context = { db = c.db, worker = c.worker, run = c.run,
    attempt = c.attempt, root = fresh, driver = c.driver }
  local s = snapshot(portable_context, portable_d, "portable-boundary",
    portable_d .. "/cosmic-portable"); if s ~= 0 then return s end
  if p.trailing == "success" then
    assert(read(portable_d .. "/portable-immediate/hashes.sha256") == read(portable_d .. "/portable-boundary/hashes.sha256"), "portable database changed across boundary")
    local executable = portable_d .. "/cosmic-portable"
    local cache = portable_d .. "/portable-full-suite-cache"
    local locked = step(portable_context, "portable cache read-only mode",
      function(): boolean, string return Fs.chmod(cache, 0x140) end)
    if locked ~= 0 then return locked end
    local help = checked(portable_context, "read-only cache execution",
      { executable, "help" }, 30000, fresh, environment({ COSMIC_PORTABLE_CACHE = cache }))
    local restored = step(portable_context, "portable cache restore mode",
      function(): boolean, string return Fs.chmod(cache, 0x1c0) end)
    if help ~= 0 then return help end
    if restored ~= 0 then return restored end
  end
  return 0
end

local function phase_fixtures(p: PlatformContext): integer
  local c = p.operation
  local root = p.root
  local target = p.target
  local work = p.work
  local product = p.product
  local contract = p.contract
  local runtime = p.runtime
  local s = fixture_test(c, work, "self-rebuild-regression", "self_rebuild",
    self_rebuild_test_timeout_ms, {
    COSMIC_FIXTURE_ROOT = root,
    COSMIC_FIXTURE_RUNTIME = runtime,
    COSMIC_TEST_TIMEOUT = self_rebuild_per_test_timeout_s,
  }); if s ~= 0 then return s end
  -- The fixed-point regression is the slowest fixture on every leg (70
  -- to 150 s: each of its tests rebuilds the product twice from a fresh
  -- tree), and what it checks -- that the compiler compiles itself to
  -- itself -- is the same on every platform, so a gating run runs it on
  -- one leg, and the others set COSMIC_CI_FIXED_POINT=skip; the
  -- scheduled run keeps it on every leg (ci.yml).
  if Env.get("COSMIC_CI_FIXED_POINT") == "skip" then
    Fs.put(Fs.stderr, "fixture: fixed-point-regression: skipped on this leg " ..
      "(COSMIC_CI_FIXED_POINT=skip)\n")
  else
    s = fixture_test(c, work, "fixed-point-regression", "fixed_point",
      fixed_point_test_timeout_ms, {
      COSMIC_FIXTURE_ROOT = root,
      COSMIC_FIXTURE_PRODUCT = product,
      COSMIC_TEST_TIMEOUT = fixed_point_per_test_timeout_s,
    }); if s ~= 0 then return s end
  end
  s = fixture_test(c, work, "self-driven-regression", "self_driven",
    self_driven_test_timeout_ms, {
    COSMIC_FIXTURE_ROOT = root,
    COSMIC_FIXTURE_PRODUCT = product,
    COSMIC_TEST_TIMEOUT = self_driven_per_test_timeout_s,
  }); if s ~= 0 then return s end
  s = fixture_test(c, work, "runtime-regression", "runtime",
    runtime_test_timeout_ms, {
    COSMIC_FIXTURE_ROOT = root,
    COSMIC_FIXTURE_RUNTIME = runtime,
  }); if s ~= 0 then return s end
  s = fixture_test(c, work, "launcher-regression", "launcher",
    launcher_test_timeout_ms, {
    COSMIC_FIXTURE_LAUNCHER = contract .. "/launcher/launcher.test",
    COSMIC_FIXTURE_LAUNCHER_SOCKET = contract ..
      "/launcher/payloads/socket-" .. target,
    COSMIC_FIXTURE_TARGET = target,
  }); if s ~= 0 then return s end
  s = fixture_test(c, work, "identity-regression", "identity",
    identity_test_timeout_ms, {
    COSMIC_FIXTURE_ROOT = root,
    COSMIC_FIXTURE_RUNTIME = runtime,
    COSMIC_TEST_TIMEOUT = identity_per_test_timeout_s,
  }); if s ~= 0 then return s end
  -- The product fixture ran on these bytes in assemble
  -- (product-verification); run again on the same bytes and inputs, it
  -- would check nothing more than that none of them moved since.
  local changed = ProductSetup.changed(product,
    read(work .. "/product.before.sha256"))
  assert(changed == nil, "product mutated by fixtures: " .. tostring(changed))
  assert(hash(product .. "/cosmic") .. "\n" == read(work .. "/cosmic.before.sha256"), "product mutated by fixtures"); return 0
end

local function phase_attest(p: PlatformContext): integer
  local work = p.work
  local product = p.product
  local portable_d = p.portable_diagnostics
  local before = read(work .. "/cosmic.before.sha256"); local digest = hash(product .. "/cosmic") .. "\n"
  assert(before == digest and before == read(portable_d .. "/portable-artifact.before.sha256") and before == read(portable_d .. "/portable-artifact.after.sha256"), "executed artifact attestation differs")
  write(product .. "/executed-cosmic.sha256", digest:sub(1, 64) .. "  cosmic\n"); write(product .. "/expected-platforms", assert(p.trailing) .. "\n"); return 0
end

local function platform_impl(phase: string, p: PlatformContext): integer
  assert(targets[p.target], "unsupported target"); mkdir(p.work)
  if phase == "build" then return phase_build(p)
  elseif phase == "local-boundary" then return phase_local_boundary(p)
  elseif phase == "format" then return format_check(p)
  -- Assemble's checked core, verified and (COSMIC_CI_CHECKED_SUITE) its
  -- suite run, alone, on a checked build already there.
  elseif phase == "checked" then
    return checked_suite(p.operation, p.target, p.work,
      p.contract .. "/format/format-test-" .. p.target)
  elseif phase == "sandbox" then return phase_sandbox(p)
  elseif phase == "assemble" then return phase_assemble(p)
  elseif phase == "portable" then return phase_portable(p)
  elseif phase == "portable-boundary" then return phase_portable_boundary(p)
  elseif phase == "fixtures" then return phase_fixtures(p)
  elseif phase == "attest" then return phase_attest(p)
  end
  error("unknown platform phase: " .. phase)
end

local function provenance_impl(c: Context, products: string): integer
  local entries = assert(Fs.list(products)); local count = 0; local expected: integer|nil = nil; local baseline: string|nil = nil
  for _, name in ipairs(entries) do if name:match("^portable%-product%-.+") then
      local p = products .. "/" .. name; local att = p .. "/executed-cosmic.sha256"; local exp = p .. "/expected-platforms"
      assert(exists(att) and exists(exp) and exists(p .. "/cosmic"), "incomplete product: " .. p)
      local line = read(att); local digest = line:match("^([0-9a-f]+)  cosmic\n$"); assert(digest and #digest == 64, "invalid attestation: " .. att)
      assert(hash(p .. "/cosmic") == digest, "changed artifact: " .. p)
      local n = math.tointeger(assert(tonumber(read(exp)))); assert(n and n > 0, "invalid expected count")
      if expected then assert(expected == n, "inconsistent expected count") else expected = n end
      if baseline then assert(baseline == digest, "worker artifact hashes differ") else baseline = digest end
      count = count + 1
    end end
  assert(expected and count == expected, "expected " .. tostring(expected) .. " products, found " .. count)
  return step(c, "provenance comparison", function(): boolean, string
    return true
  end)
end

local function logical(c: Context, phase: string,
    action: function(): integer): integer
  local started = Time.monotonic_ns()
  local database = State.external_path(c.db, c.root)
  local id = State.start(database, c.worker, c.run, c.attempt, phase, started)
  local called, answer = pcall(action)
  local code = called and answer or 1
  local status = code == 0 and "success" or (called and "exit" or "error")
  local detail: string | nil = nil
  if not called then detail = tostring(answer) end
  local finished = Time.monotonic_ns()
  State.complete(database, id, c.worker, c.run, c.attempt, phase, finished,
    finished - started, status, code, nil, 0, detail)
  if detail then Fs.put(Fs.stderr, detail .. "\n") end
  return code
end

function Orchestration.platform(a: {string}): integer
  local phase = assert(a[1], "usage: driver.tl platform PHASE [ARG]")
  local ctx = ContextEnv.read()
  local target = ContextEnv.target()
  local c: Context = { db = ctx.db, worker = ctx.worker, run = ctx.run,
    attempt = ctx.attempt, root = ctx.root, driver = assert(Fs.absolute(assert(a[0]))) }
  local p: PlatformContext = { trailing = a[2], operation = c, root = ctx.root,
    target = target, work = ctx.work, product = ctx.work .. "/product",
    contract = ctx.work .. "/contract", runtime = ctx.work .. "/runtime",
    local_diagnostics = ctx.work .. "/local-diagnostics",
    portable_diagnostics = ctx.work .. "/portable-diagnostics",
    fresh = ctx.work .. "/portable-source" }
  return logical(c, "platform: " .. phase, function(): integer
    return platform_impl(phase, p)
  end)
end

function Orchestration.provenance(a: {string}): integer
  local ctx = ContextEnv.read()
  local c: Context = { db = ctx.db, worker = ctx.worker, run = ctx.run,
    attempt = ctx.attempt, root = ctx.root, driver = assert(Fs.absolute(assert(a[0]))) }
  return logical(c, "provenance", function(): integer
    return provenance_impl(c, ctx.products)
  end)
end

return Orchestration
