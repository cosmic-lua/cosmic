local BuildPaths = require("cosmic_ci.build_paths")
local Capabilities = require("cosmic_ci.capabilities")
local Clock = require("cosmic.clock")
local ContextEnv = require("cosmic_ci.context")
local Env = require("cosmic.env")
local Fixture = require("cosmic_ci.fixture")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local Hash = require("cosmic.hash")
local LauncherSetup = require("cosmic_ci.launcher_setup")
local ProductSetup = require("cosmic_ci.product_setup")
local Archive = require("cosmic.archive")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local Child = require("cosmic.child")
local Proc = require("cosmic.proc")
local Runner = require("cosmic_ci.runner")
local RunNames = require("cosmic_ci.run_names")
local RuntimeSetup = require("cosmic_ci.runtime_setup")
local State = require("cosmic_ci.state")
local SuiteOutput = require("cosmic_ci.suite_output")
local ZigRestat = require("cosmic_ci.zig_restat")
local Plural = require("cosmic_ci.plural")
local String = require("cosmic.string")

local record Orchestration
  --- A unit of fixture work for [`run_groups`]. `run` does it whole in this
  --- process, in order with the rest (the serial path). `start` spawns it
  --- ([`Runner.spawn`]) for the lanes; once it has ended `finish` is
  --- given its reaped outcome, replays its retained log whole and records
  --- it, and answers its status; `abandon` is given the outcome of a group
  --- stopped before it ended, and replays what it logged.
  record Group
    name: string
    run: function(): integer
    start: function(): Runner.Running
    finish: function(outcome: Runner.Outcome): integer
    abandon: function(outcome: Runner.Outcome)
  end
  stands: function(env: {string:string}): boolean
  harness_moved: function(root: string, base: string): boolean, string
  test_words: function(env: {string:string}): {string}
  shares: function(env: {string:string})
  sandboxed_fixtures: {string:boolean}
  noexec_fixture: function(target: string): boolean
  fixture: function(env: {string:string}, tmpdir: string, compiles: string,
    verdicts?: string): {string:string}
  fixture_run: function(source: string, env: {string:string}, tmpdir: string,
    compiles: string): {string:string}
  forget_run: function(env: {string:string})
  suite_run: function(extra?: {string:string}): {string}, {string:string}
  suite_verdicts: function(env: {string:string}, name: string): string
  darwin_modules: function(text: string): {string}
  darwin_words: function(words: {string}, modules: {string}): {string} | nil
  native_ran_every: function(text: string, code: integer): boolean
  replay: function(out: string, err: string, to_out?: integer, to_err?: integer): boolean
  fixture_lanes: function(env: {string:string}, cpus: integer): integer | nil, integer | nil
  run_groups: function(high: Orchestration.Group, low: {Orchestration.Group},
    lanes: boolean): integer
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

--- Whether a suite in `env` stands on verdicts other runs reached, keyed
--- by what its tests declare (build/declared_key.tl) and shared through
--- COSMIC_VERDICT_CACHE, which ci.yml restores per leg. It does when
--- both hold:
---
--- The leg keys by declaration. Its workers are sandboxed and required
--- to be (COSMIC_CI_REQUIRE_SANDBOX=1, the Linux legs), or they are keyed
--- by what they declare without a sandbox (COSMIC_CI_DECLARED_KEYS=1, the
--- macOS leg), as every unsandboxed run of the tree's tool is.
--- Nothing holds a macOS worker to its declaration, but a Linux leg's
--- sandbox holds the same test under the same declaration and closure,
--- so a declaration that lies fails there before it merges. Only what
--- reads something only on macOS is the gap (build/test.tl's `launch`).
---
--- The run's event (COSMIC_CI_EVENT) is in `standing_events`: a push,
--- main's as much as another branch's, or the merge queue's. Each
--- restores the newest cache main saved of its leg, host and host
--- features (ci.yml's "name the leg's host").
---
--- A manual run and main's scheduled one run every test (`--all`) and
--- stand on nothing another run reached (COSMIC_TEST_NO_SHARED=1). So no
--- gating run runs every test: a pass a key does not answer for, such as
--- a test that turns on the clock or a flaky one, is caught only by
--- main's scheduled run the next day. When that run fails, GitHub tells
--- only whoever last edited its cron line (the TODO on ci.yml's
--- `schedule`).
-- TODO: share a Linux leg's verdicts across its runners only once the
-- key holds what a host's package database does not say (the TODO on
-- build/declared_key.tl's `system_identity`). Today they are keyed by
-- the leg's container as ci.yml names it (COSMIC_HOST_ID: the image
-- reference, a hash of .github/scripts/leg-container.sh and the seccomp
-- profile, which hold every option and host setting it starts with, and
-- the engine's version). A change inside an image under the same
-- reference, or on the runner beneath it, is not keyed. The macOS leg's
-- image names itself (COSMIC_SYSTEM_ID, host_id.tl),
-- which every module given the system's paths is keyed by.
---
--- A merge-queue run does not stand either where its change moves
--- build/harness_epoch.tl from the queue's base (COSMIC_CI_HARNESS_MOVED,
--- which `environment` sets by [`harness_moved`] where the driver's
--- environment does not). No key holds the harness's code, only the
--- epoch that file records (build/declared_key.tl), so a harness change
--- marked there as one that moves no verdict would otherwise land on
--- verdicts it may have moved. Such a run runs every test, as main's
--- scheduled run does, so the change is gated on a run that stands on
--- nothing. Where the driver cannot tell whether the file moved, it takes
--- it as moved.
function Orchestration.stands(env: {string:string}): boolean
  if env.COSMIC_CI_EVENT == "merge_group" and env.COSMIC_CI_HARNESS_MOVED ~= "0" then
    return false
  end
  return (env.COSMIC_CI_REQUIRE_SANDBOX == "1" or env.COSMIC_CI_DECLARED_KEYS == "1") and
    standing_events[env.COSMIC_CI_EVENT or ""] == true
end

--- The file that records the harness's epoch and the digests last
--- acknowledged of its modules (build/harness_epoch.tl). [`harness_moved`]
--- compares the whole file, not the epoch alone: an acknowledgment
--- without a bump is the case a run of every test is there to check.
local epoch_file <const> = "build/harness_epoch.tl"

--- How long a git command [`harness_moved`] runs may take: a local
--- lookup, or a fetch of one commit.
local git_timeout_ns <const> = Clock.seconds(60)

--- Runs git in the checkout at `root`, never asking for credentials
--- (GIT_TERMINAL_PROMPT=0) and ended past `git_timeout_ns`: what it
--- printed, or nil and why it failed, its own stderr among it.
local function git(root: string, words: {string}): string | nil, string
  local argv = { "/usr/bin/env", "git", "-C", root }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local env = Env.all()
  env.GIT_TERMINAL_PROMPT = "0"
  local result, trouble = Child.run(argv, { env = env, stdout = "capture",
    stderr = "capture", timeout_ns = git_timeout_ns })
  if result == nil then return nil, "git " .. words[1] .. ": " .. trouble end
  if result.timed_out then
    return nil, "git " .. words[1] .. ": timed out after " .. (git_timeout_ns // Clock.seconds(1)) .. " s"
  end
  if not result.ok then
    return nil, "git " .. words[1] .. ": exit " .. tostring(result.code) .. ": " ..
      ((result.stderr or ""):gsub("%s+$", ""))
  end
  return result.stdout or "", ""
end

--- The git object `revision:path` names in the checkout at `root`, or
--- nil and why where there is none: no such commit here, or no such
--- file in it.
local function blob(root: string, revision: string, path: string): string | nil, string
  local out, trouble = git(root, { "rev-parse", "--verify", revision .. ":" .. path })
  if out == nil then return nil, trouble end
  local object = out:match("^(%x+)\n?$")
  if object == nil then return nil, "git rev-parse: no object for " .. revision .. ":" .. path end
  return object, ""
end

--- Whether build/harness_epoch.tl differs between the commit `base`
--- names and HEAD in the checkout at `root`, and why: the merge queue's
--- base commit (ci.yml's COSMIC_CI_BASE_SHA) and the merge it checks. A
--- checkout that lacks the base, a shallow one, fetches that one commit.
--- True where either cannot be read (no base named, no git, a fetch
--- refused or timed out, a file added), which runs every test: the safe
--- side. The why says what failed.
function Orchestration.harness_moved(root: string, base: string): boolean, string
  if root == "" then return true, "no checkout named (GITHUB_WORKSPACE)" end
  if not base:match("^%x+$") then
    return true, "no merge queue base named (COSMIC_CI_BASE_SHA=" .. base .. ")"
  end
  local now, now_trouble = blob(root, "HEAD", epoch_file)
  if now == nil then return true, "cannot read HEAD's " .. epoch_file .. ": " .. now_trouble end
  local was, was_trouble = blob(root, base, epoch_file)
  if was == nil then
    local _, fetch_trouble = git(root, { "fetch", "--quiet", "--no-tags", "--depth=1",
      "origin", base })
    was, was_trouble = blob(root, base, epoch_file)
    if was == nil then
      return true, "cannot read " .. base .. "'s " .. epoch_file .. ": " .. was_trouble ..
        (fetch_trouble ~= "" and ("; " .. fetch_trouble) or "")
    end
  end
  if was ~= now then return true, epoch_file .. " differs from " .. base .. "'s" end
  return false, epoch_file .. " is " .. base .. "'s"
end

--- What [`harness_moved`] answered of each checkout and base, asked once
--- a driver run: every operation's environment asks it.
local moved_by_base: {string:boolean} = {}

--- COSMIC_CI_HARNESS_MOVED for `env`, a merge-queue run's, where it
--- does not say already: "1" where its change moves
--- build/harness_epoch.tl ([`harness_moved`], of the checkout
--- GITHUB_WORKSPACE names against COSMIC_CI_BASE_SHA), else "0".
local function decide_harness(env: {string:string})
  if env.COSMIC_CI_EVENT ~= "merge_group" or env.COSMIC_CI_HARNESS_MOVED ~= nil then return end
  local root, base = env.GITHUB_WORKSPACE or "", env.COSMIC_CI_BASE_SHA or ""
  local asked = root .. "\0" .. base
  if moved_by_base[asked] == nil then
    local moved, why = Orchestration.harness_moved(root, base)
    moved_by_base[asked] = moved
    Fs.put(Fs.stderr, "merge queue: " .. (moved and "every suite runs every test (--all): " or
      "suites stand on verdicts: ") .. why .. "\n")
  end
  env.COSMIC_CI_HARNESS_MOVED = moved_by_base[asked] and "1" or "0"
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

--- Sets `env`, a suite's, to the requirements the leg it runs on
--- promises (ci/cosmic_ci/capabilities.tl): COSMIC_TEST_PROMISES, their list, and
--- COSMIC_TEST_LEG, the leg's name, which a held `cosmic test` fails a
--- module for lacking. The leg is COSMIC_WORKER's; a worker that is no
--- leg's (the provenance join, fuzz.yml) promises nothing, and a
--- variable the environment already sets is the caller's.
function Orchestration.promise(env: {string:string})
  local promised = (Capabilities.legs as {string:{string}})[env.COSMIC_WORKER or ""]
  if promised == nil or env.COSMIC_TEST_PROMISES ~= nil then return end
  env.COSMIC_TEST_PROMISES = table.concat(promised, ",")
  env.COSMIC_TEST_LEG = env.COSMIC_WORKER
end

--- The environment every operation runs in: the driver's own, with
--- FUZZ_ITERS=0, so a suite checks each fuzz property's corpus of kept
--- failures but draws no inputs of its own. Drawing is fuzz.yml's, each
--- night with a seed of its own: a check that gates a change answers the
--- same on every run, and one that searches runs where a find blocks
--- nobody's merge. [`suite_run`] then removes what names the run from a
--- gating suite's copy ([`forget_run`]).
local function environment(extra?: {string:string}): {string:string}
  local all = Env.all()
  all.FUZZ_ITERS = "0"
  if extra then
    for k, v in pairs(extra) do all[k] = v end
  end
  -- What follows is decided on the leg's environment, `extra`
  -- included, which may name the leg itself ([`suite_run`], a test's).
  -- A merge-queue run that moves the harness's epoch file stands on
  -- nothing (`stands`).
  decide_harness(all)
  -- Where it does not stand on verdicts (`stands`), a suite stands on
  -- none another run reached, only on what it runs itself.
  Orchestration.shares(all)
  -- Where the leg is given what spawn's sandbox needs, every suite runs
  -- each worker sandboxed (build/test_sandbox.tl), as `cosmic test`
  -- does by default wherever it can, and fails where it cannot rather
  -- than run them unsandboxed. Every build.confine `confine` of a test
  -- is a `must_confine` there (COSMIC_SANDBOX=must, build/confine.tl),
  -- so a process a test confines runs confined or fails the test, and
  -- the sandbox tests of core/syscalls_test.tl cannot pass unchecked.
  -- The mode also runs every test no key can hold, as --all does; a
  -- sandboxed run has none.
  if all.COSMIC_CI_REQUIRE_SANDBOX == "1" then
    all.COSMIC_TEST_SANDBOX = "1"
    all.COSMIC_SANDBOX = "must"
  end
  Orchestration.promise(all)
  return all
end

--- Whether `name` says which run, runner or job this is, or is a switch
--- the driver alone reads ([`cosmic_ci.run_names`]).
local function names_the_run(name: string): boolean
  for _, kept in ipairs(RunNames.kept) do
    if name == kept then return false end
  end
  for _, exact in ipairs(RunNames.exact) do
    if name == exact then return true end
  end
  for _, prefix in ipairs(RunNames.prefixes) do
    if String.starts_with(name, prefix) then return true end
  end
  return false
end

--- Removes from `env`, a gating suite's, every variable that names the
--- run ([`names_the_run`]). A test is keyed by every variable its worker
--- is given, so one that moves each run (GITHUB_RUN_ID, GITHUB_SHA,
--- RUNNER_NAME, COSMIC_CI_SCOPE, ...) would keep a test that declared it
--- from standing on any earlier run's verdict. No tree test reads one, so none is given one,
--- and what a key holds is still what the worker gets. The driver
--- decides what the suite does (`stands`, [`test_words`], `shares`) before
--- this, from the environment it was given.
function Orchestration.forget_run(env: {string:string})
  local names: {string} = {}
  for name in pairs(env) do
    if names_the_run(name) then names[#names + 1] = name end
  end
  for _, name in ipairs(names) do env[name] = nil end
end

--- A gating suite's `cosmic test` words and environment, `extra` added
--- to [`environment()`]'s: `--all` and nothing shared where it stands on
--- no verdict (`stands`, `shares`), decided on the driver's own
--- environment, which then forgets the run ([`forget_run`]).
function Orchestration.suite_run(extra?: {string:string}): {string}, {string:string}
  local values = environment(extra)
  local words = Orchestration.test_words(values)
  Orchestration.forget_run(values)
  return words, values
end

--- The shared verdict cache (COSMIC_VERDICT_CACHE) the suite `name`
--- keeps and stands on, given `env`, the driver's: `<name>.db` beside
--- the one `env` names, in the directory ci.yml's verdict cache saves
--- and restores, so it rides along. "0", none, where `env` names no
--- absolute path or turns the cache off.
---
--- The portable suite has no file of its own: it keeps the native
--- suite's, `env`'s. The portable artifact carries the cores the tree's
--- tool does, from its build directory's core/ (`ProductSetup`), and a
--- key holds what runs the core wherever a worker is started by a launcher
--- (build/declared_key.tl's `launcher_identity`): a test that runs the
--- program (`tool`) or opens the store (`store`) is keyed by the
--- artifact it ran under, so it reruns under the portable build. A
--- worker run on a sealed database of its closure never sees an
--- artifact (build/test.tl's `seals`); its key holds the core and the
--- sealed inputs in the launcher's place, so the same key under either
--- artifact stands for the same run, and the portable suite stands on
--- the native suite's verdict rather than running the test twice. A
--- test module that reads the launcher or artifact without being
--- unsealed fails `cosmic fix --check .` (build/tree_checks.tl's
--- `sealed_launch`).
---
--- Nor is the checked suite's file either's (`checked`): the local
--- suite's rows would crowd the checked suite's toward the file's bound,
--- and the checked suite's census (`--census`) counts only its own
--- suite's rows when the file is its own.
function Orchestration.suite_verdicts(env: {string:string}, name: string): string
  local shared = env.COSMIC_VERDICT_CACHE or ""
  if shared:sub(1, 1) ~= "/" then return "0" end
  if name == "portable" then return shared end
  return shared:match("^(.*)/[^/]*$") .. "/" .. name .. ".db"
end

local record Context
  db: string
  worker: string
  run: string
  attempt: string
  root: string
  driver: string
  --- The platform phase running (`platform`'s PHASE), which a suite's
  --- row names.
  phase: string
end

--- The environment variable `name`, or nil when it is unset or empty.
local function named(name: string): string | nil
  local value = Env.get(name)
  if value == "" then return nil end
  return value
end

local function request_for(c: Context, command: {string}, timeout: integer,
                           cwd?: string, env?: {string:string}, output?: string,
                           error_output?: string): Runner.Context, Runner.Request
  local runner: Runner.Context = { database = c.db, worker = c.worker,
    run = c.run, attempt = c.attempt, candidate = c.root }
  local child_environment: {string:string}
  if env then child_environment = env else child_environment = environment() end
  -- bin/zig shares one project cache among checkouts unless told otherwise
  -- (build/zig.tl). A candidate uses the zig-cache under
  -- COSMIC_ZIG_CACHE_SEED where CI restored it, else keeps its own under
  -- o/, which the build phase seeds. zig keys what it compiles by its
  -- own cache's path too, and CI puts the checkout at a path of the commit's
  -- own (ci/cosmic_ci/place_tree.tl), so a cache under o/ would never
  -- be reused there: CI saves the seed's as it stands.
  if (child_environment.COSMIC_ZIG_CACHE or "") == "" then
    local seed = named("COSMIC_ZIG_CACHE_SEED")
    child_environment.COSMIC_ZIG_CACHE = seed and seed .. "/zig-cache" or BuildPaths.directory(c.root, child_environment) .. "/zig-cache"
  end
  -- The driver boots the candidate itself; a tool that finds its core
  -- stale is a fault to report, not one to boot past (build/reboot.tl).
  if not child_environment.COSMIC_AUTO_BOOT then
    child_environment.COSMIC_AUTO_BOOT = "0"
  end
  return runner, { argv = command, cwd = cwd or c.root,
    env = child_environment, timeout_ns = timeout,
    output = output, error = error_output }
end

local function operation(c: Context, phase: string, command: {string},
                         timeout: integer, cwd?: string, env?: {string:string}, output?: string,
                         error_output?: string): integer
  local runner, request = request_for(c, command, timeout, cwd, env, output, error_output)
  return Runner.operation(runner, phase, request).code
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

--- Says a retained log whole, stdout then stderr (to `to_out` and `to_err`,
--- the process's own by default), as `logged` does after its command. False,
--- with the trouble said on stderr, when it could not.
function Orchestration.replay(out: string, err: string, to_out?: integer,
                              to_err?: integer): boolean
  local replay_ok = Env.get("COSMIC_CI_SELFTEST_REPLAY_FAILURE") ~= "true"
  if replay_ok then
    replay_ok = Fs.put(to_out or Fs.stdout, read(out)) and
      Fs.put(to_err or Fs.stderr, read(err))
  end
  if not replay_ok then Fs.put(Fs.stderr, "could not replay retained output\n") end
  return replay_ok
end

local replay = Orchestration.replay

local function logged(c: Context, phase: string, command: {string}, out: string,
                      err: string, timeout: integer, cwd?: string, env?: {string:string}): integer
  local status = operation(c, phase, command, timeout, cwd, env, out, err)
  local replay_ok = replay(out, err)
  if status ~= 0 then return status end
  assert(replay_ok, "could not replay retained output")
  return status
end

--- Records the suite `name`'s row (State.suite): how it ended, `code`,
--- and what its stdout, the file `out`, said of it (SuiteOutput). A row
--- that cannot be written is said on stderr and fails nothing: the
--- suite's own status decides the leg.
local function record_suite(c: Context, name: string, code: integer, out: string)
  local called, trouble = pcall(function(): boolean
    local said = exists(out) and read(out) or ""
    local figures, status = SuiteOutput.read(said, code)
    State.suite(State.external_path(c.db, c.root), {
      worker = c.worker, run = c.run, attempt = c.attempt,
      phase = c.phase or "", suite = name,
      status = status, exit_code = code,
      tests = figures.tests, modules = figures.modules, ran = figures.ran,
      stood = figures.stood, every = figures.every,
      shared = figures.shared, failed = figures.failed,
      elapsed_ms = figures.elapsed_ms, sandbox = figures.sandbox,
      parts = figures.parts, held = figures.held })
    -- The skips go to the job's summary page, and fail nothing.
    local skips = SuiteOutput.skip_report(name, said)
    if skips ~= "" then ContextEnv.summarize(skips) end
    return true
  end)
  if not called then
    Fs.put(Fs.stderr, name .. " suite: row not recorded: " .. tostring(trouble) .. "\n")
  end
end

local function capture_small(c: Context, phase: string, command: {string},
                             path: string, timeout: integer, cwd?: string): integer
  return operation(c, phase, command, timeout, cwd, environment(), path)
end

-- Whole-project guards include compilation and test-runner overhead. The
-- direct children inside them have the shorter bounds defined by fixture.tl.
local product_test_timeout_ns <const> = Clock.seconds(60)
local format_test_timeout_ns <const> = Clock.seconds(300)
-- The sandboxed fixtures (`sandboxed_fixtures`) take 6 to 28 s where
-- they run, under ci/run-local on a loaded four-core host (launcher 6 s,
-- runtime 10 s, identity 28 s), and 4 to 6 s where their verdicts stand;
-- each bound is several times that.
local launcher_test_timeout_ns <const> = Clock.seconds(60)
local launcher_noexec_test_timeout_ns <const> = Clock.seconds(60)
local self_rebuild_test_timeout_ns <const> = Clock.seconds(450)
-- A self-rebuild test rebuilds the tool: the docs verb's from a cold
-- compile of the whole tree, 50 to 90 s of one core on a runner, past the
-- runner's default 30 s per test; the rest from the leg's compiles
-- ([`seed_compiles`]), in seconds. The bound is above the case's own
-- (`rebuild_timeout_ns` in fixtures/self_rebuild_test.tl, 150 s).
local self_rebuild_per_test_timeout_s <const> = "180"
-- Each fixed-point test rebuilds the product twice from a fresh tree. The
-- compiler's three cases share no compiles (fixtures/fixed_point_test.tl
-- says why) and compile the whole tree cold about three times, about 43 s
-- of one core each at 11.9 MB of Teal: on a four-core x86-64 host each
-- took 206 to 230 s beside the file's other tests, 213 s alone, 134 s of
-- it the first rebuild. The other four share one file of compiles made
-- afresh each run (COSMIC_FIXTURE_SHARED_COMPILES): the first compiles the
-- tree cold in 90 s, and the rest, started after it, only what their
-- edits move, in 23 to 34 s where cold they took 84 to 96 s. So the file
-- ends about when its last compiler case does: 221 s on four workers
-- (331 s cold) and 301 s on three (398 s cold). That host takes about 1.22
-- times as long as linux-aarch64 (whose run took 271 s cold on October 9),
-- and the x86-64 legs 1.3 to 1.55 times as long as linux-aarch64 on the
-- same work (the self-rebuild file, 83 to 101 s against 65 s), so the
-- slowest leg needs up to 1.27 times this host's time: about 380 s for the
-- file on macOS's three processors, 275 s for a compiler case and 170 s
-- for its first rebuild. The bounds keep 1.5 to 1.6 times that, as #2834
-- did for the suite's: the group's 600 s, a test's 420 s, and a
-- rebuild's 270 s (fixtures/fixed_point_test.tl), which names a hung one.
-- TODO: the compiler cases still compile the whole tree cold, so the
-- file's cost follows the tree (about 5% a day the week of October 3) and
-- these bounds will be passed again: report the group's elapsed time
-- against its bound from [`fixture_run_spec`], so the growth shows before
-- it fails a run.
local fixed_point_test_timeout_ns <const> = Clock.seconds(600)
local fixed_point_per_test_timeout_s <const> = "420"
--- The whole suite on the checked core: see [`checked_suite`]'s comment
--- for what it takes.
local checked_suite_timeout_ns <const> = Clock.seconds(1200)
-- Each test's bound on the checked core: the release suites' (below)
-- scaled by how much slower the checked core runs a test, about 2.9
-- times over the suite and 5.5 times for a compile-heavy module
-- (build/shape_specs_test.tl, about 3 s a test on the release core, past
-- the runner's default 30 s on CI's checked job when no verdict stood),
-- and doubled for a loaded runner.
local checked_suite_test_timeout_s <const> = "120"
-- A boot the product drives from another path compiles no C again (it
-- compiles from copies in zig's cache, build.zig's `Own`), only the tree:
-- about 110 s for the whole fixture in a local run on four cores, loaded.
-- TODO: lower these bounds once CI's own runs show the fixture's time
-- without the core's C compile they were sized for (about 110 s of it).
local self_driven_test_timeout_ns <const> = Clock.seconds(600)
local self_driven_per_test_timeout_s <const> = "480"
local runtime_test_timeout_ns <const> = Clock.seconds(90)
-- The sandbox probe starts six trivial children; its bound is the
-- tree's own load, which a booted tree has already paid.
local sandbox_probe_timeout_ns <const> = Clock.seconds(60)
local identity_test_timeout_ns <const> = Clock.seconds(120)
-- The identity suite builds the primary project, rebuilds it and runs it
-- transported; this bound is well past that, and inside the whole file's.
local identity_per_test_timeout_s <const> = "60"
-- Each performance lifecycle case starts four fixtures and a few checked pairs
-- per phase. CI's ordinary 10 s deadline cut these off on Linux and macOS.
-- Their child is bounded at 45 s, including eight seconds of real source
-- timestamp settlement; allow setup and result inspection
-- around it, and two serial tests plus runner setup in the whole-file bound.
local performance_per_test_timeout_s <const> = "60"
local performance_test_timeout_ns <const> = Clock.seconds(150)
-- The checked cosmic's first file in the tree after the checked build
-- ([`checked_suite`]). A boot names the analyzer as the tool it writes
-- does (build/importer.tl's `tree_code`), so that file builds nothing
-- again: 0.3-0.7 s here. A reparse of every source would take 30-35 s by
-- the checked cosmic under ci/run-local on a 4-core host, once 41 s.
-- TODO: lower this bound once CI's own runs show the step's time
-- without that reparse; it is still sized for it.
local checked_compile_timeout_ns <const> = Clock.seconds(300)

-- A whole `cosmic test` run of every test, sandboxed (about 4500 tests
-- since October 2026), is what a change to core/ runs, as no verdict
-- stands for it. On alpine-x86_64 it took 158 to 272 s whole, by the
-- runner (the build of up to 25 s where the tree is compiled cold, the
-- closure stores, and the tests): 270 s was passed twice in a queue's runs
-- (37630361708, 37632469834). The bound is about 1.6 times the slowest
-- run seen. Each test gets far less than the whole run, so a test that
-- hangs is ended and named by the runner, not hidden under a cancelled run.
-- TODO: a whole run happens only when the core changes, so the suite's
-- growth against this bound goes unseen until an unlucky PR meets it:
-- warn from `suite` when a run uses over 75% of the bound, or run the
-- whole suite on a schedule and report its elapsed time against it.
local suite_timeout_ns <const> = Clock.seconds(450)
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

--- The fixture project beneath `work`, made afresh: the shared one, or
--- where `group` is given (a fixture's source name) the group's own, so
--- groups running at once never remove one another's.
local function fixture_project(c: Context, work: string, group?: string): string
  local project = work .. "/fixture-project" .. (group and "-" .. group or "")
  local driver_namespace = Fs.dirname(c.driver)
  local fixtures_source = Fs.dirname(driver_namespace) .. "/fixtures"
  assert(Fs.remove_tree(project))
  copy_flat_tl_dir(driver_namespace, project .. "/cosmic_ci")
  copy_flat_tl_dir(fixtures_source, project .. "/fixtures")
  return project
end

--- The fixtures (ci/fixtures/<name>_test.tl) whose workers run
--- sandboxed, where the leg sandboxes its suites, and whose verdicts are
--- shared (`fixture`). Each declares with [`Test.policy`] every path it
--- reads of what [`place`] put at o/fixtures/<product|runtime|launcher|
--- format|performance> of its project -- the product, the runtime
--- setup's directory, the launcher contract's, the format decoders' or
--- the performance inputs -- so its key holds what each holds, not
--- where the leg keeps it. Each is tied to the parts of the product the leg attests
--- ([`phase_attest`]) that it exercises: the product's `prefix`, its
--- launcher, manifest and cores, which [`fixture_test`] gives it, and
--- the content-keyed artifacts it runs, each by its bytes, so no fixture
--- stands on a verdict another launcher, core or artifact reached
--- (orchestration_test.tl holds these to the prefix). `performance`
--- instead keys the entire selected program and its controller source, since
--- it exercises carried modules. `product` checks
--- the whole product, and declares every file of it; the other fixtures run
--- artifacts of their own setup, and do not declare the product's
--- `cosmic`, whose database moves with every edit to the tool's code
--- though none of theirs runs it.
---
--- A fixture that declares `system` is keyed by what the system's
--- paths hold, a /bin/sh or uname changed under the same packages
--- moving its key; and on the macOS leg, whose workers no sandbox holds
--- (keyed by declaration all the same), by the fixture project's path, so a
--- verdict that turned on that path stands in no project elsewhere.
---
--- The rest run unsandboxed, as before, and share nothing: `format`,
--- `self_rebuild`, `fixed_point` and `self_driven` write a checkout and
--- compile it cold, with zig's caches and the host's toolchain.
--- `launcher_noexec` declares private noexec scratch and runs on Linux
--- only; the ordinary launcher fixture still runs on every platform.
Orchestration.sandboxed_fixtures = {
  product = true, runtime = true, launcher = true, launcher_noexec = true, identity = true, performance = true,
}

--- Only the Linux legs can supply the launcher's private noexec grant.
--- Omission elsewhere is no passing noexec verdict.
function Orchestration.noexec_fixture(target: string): boolean
  return target == "x86_64-linux-musl" or target == "aarch64-linux-musl"
end

--- `env`, an operation's environment, made a fixture's `cosmic test`'s:
--- its temporary files under `tmpdir`.
---
--- Given `verdicts`, a fixture of `sandboxed_fixtures`: its workers run
--- as the leg's suites' do -- sandboxed where the leg requires it
--- (COSMIC_CI_REQUIRE_SANDBOX, `environment`), keyed by what they declare
--- where it keys by declaration (COSMIC_CI_DECLARED_KEYS) -- and it
--- stands on and keeps the verdicts of the file `verdicts` names,
--- `fixtures.db` beside the leg's `verdicts.db` ([`suite_verdicts`]),
--- which ci.yml restores and saves with them, and stands on none another
--- run reached where the leg's suites do not (`stands`). Its project is
--- made afresh each run ([`fixture_project`]), so what stands is only what
--- the shared file holds, under a key that holds what the fixture
--- declares it reads, the product's prefix among them.
-- TODO: hand a merge-queue run's fixtures.db to the run behind it, as
-- its verdicts.db is (ci.yml's "keep the suite's verdicts for the run
-- behind in the queue", `verdicts-merge`): that upload is made once the
-- native suite passes, before the fixtures run, so the run behind
-- restores main's fixtures.db alone, and a fixture stands there only
-- where neither change ahead moved the product. Wants a second upload
-- after the fixtures, and a wait for it before the run behind's.
---
--- Without, a fixture that writes a checkout or reads the host beyond
--- what a sandbox gives: its workers unsandboxed, and no verdict but one
--- it reaches itself. It reads the candidate and its products where
--- variables of `env` say (COSMIC_FIXTURE_*), which no key of its holds,
--- so it neither reads nor writes the shared verdicts, whatever the
--- event. Nor can a verdict of its own stand: its project, and the o/
--- under it, is made afresh for each run, and it names the file it
--- runs, so none is assumed.
---
--- Its compiles and parses (COSMIC_BUILD_CACHE) are the file `compiles`
--- names, which the leg's fixtures share with one another and with
--- nothing else. Each is a project made afresh of the same sources, so
--- the first to run compiles it and the rest take that work back. It is
--- not the leg's cache, which ci.yml restores and saves
--- (cosmic_ci/compiles.tl), so no fixture's rows are kept from one run
--- to the next, nor the boot's work taken back. A child a fixture starts
--- takes none ([`Fixture.environment`]): what a fresh tree compiles, and
--- what the tool built from it compiles again (fixed_point_test's
--- compiler cases, self_rebuild_test's docs verb), it must compile and
--- parse. The other self-rebuild cases take a copy of the leg's
--- ([`seed_compiles`]), and the other fixed-point cases share a file of
--- their own, made afresh for each run (COSMIC_FIXTURE_SHARED_COMPILES).
function Orchestration.fixture(env: {string:string}, tmpdir: string,
                               compiles: string, verdicts?: string): {string:string}
  -- The outer fixture runner is the pinned driver, whose requirement
  -- table predates Unix socket creation. Candidate suites keep their list.
  -- TODO: pass unix_socket to fixture runners once ci/cosmic-driver.pin names
  -- a release whose build.host_names accepts unix_socket.
  if env.COSMIC_TEST_PROMISES ~= nil then
    local promised: {string} = {}
    for _, name in ipairs(String.split(env.COSMIC_TEST_PROMISES, ",")) do
      if name:match("^%s*(.-)%s*$") ~= "unix_socket" then promised[#promised + 1] = name end
    end
    env.COSMIC_TEST_PROMISES = table.concat(promised, ",")
  end
  env.TMPDIR = tmpdir
  env.COSMIC_BUILD_CACHE = compiles
  if verdicts ~= nil then
    env.COSMIC_VERDICT_CACHE = verdicts
    Orchestration.shares(env)
    return env
  end
  env.COSMIC_TEST_SANDBOX = "0"
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_NO_SHARED = "1"
  -- Nor is it keyed by what it declares, on a leg whose suites are
  -- (COSMIC_CI_DECLARED_KEYS), by the pinned driver: it shares no verdict
  -- for a key to name. A release that keys every unsandboxed run by
  -- declaration keys it so anyway, and it shares nothing all the same
  -- (COSMIC_VERDICT_CACHE=0); it names each variable it reads.
  return env
end

--- The environment the fixture ci/fixtures/<source>_test.tl runs in,
--- made of `env`, the operation's (`environment`, its COSMIC_FIXTURE_*
--- among it), by `fixture`: one of `sandboxed_fixtures` keeps its
--- verdicts in `fixtures.db` beside the file COSMIC_VERDICT_CACHE of
--- `env` names ([`suite_verdicts`]), and must be given the product its
--- verdicts are keyed by what it declares of what [`fixture_test`] placed; any other shares none.
function Orchestration.fixture_run(source: string, env: {string:string}, tmpdir: string,
                                   compiles: string): {string:string}
  local sandboxed = Orchestration.sandboxed_fixtures[source] == true
  local verdicts: string | nil = nil
  if sandboxed then verdicts = Orchestration.suite_verdicts(env, "fixtures") end
  return Orchestration.fixture(env, tmpdir, compiles, verdicts)
end

--- What a sandboxed fixture reads of a setup's output, `from` (the
--- product, the runtime setup's directory, the launcher contract's, the
--- format decoders', the performance inputs), placed at `kind` under
--- o/fixtures of the project it runs in: the fixture declares each path
--- it reads there with [`Test.policy`], a grant, so its
--- key holds what each holds, not where the leg keeps it. Only `only`, the
--- names beneath `from` it reads, are copied where it is given: a fixture
--- that reads the product's `prefix` alone is not given the product's
--- `cosmic` and `cosmic.db` to copy.
local record Placement
  kind: string
  from: string
  only: {string}
end

--- Places each of `placements` in the `fixtures` directory of the
--- build directory the driver builds `project` in ([`Placement`],
--- [`BuildPaths.driven`]), which a fixture declares as `o/fixtures`. A
--- copy, so a fixture is free to run what it is placed without touching
--- the product the leg attests.
local function place(project: string, placements: {Placement})
  for _, placement in ipairs(placements) do
    assert(placement.kind:match("^[%w_]+$"), "invalid fixture placement")
    local where = BuildPaths.driven(project) .. "/fixtures/" .. placement.kind
    assert(Fs.mkdirs(Fs.dirname(where)))
    if placement.only == nil then
      assert(Fs.copy_tree(placement.from, where))
    else
      for _, name in ipairs(placement.only) do
        local target = where .. "/" .. name
        assert(Fs.mkdirs(Fs.dirname(target)))
        local st = assert(Fs.stat(placement.from .. "/" .. name))
        assert(Fs.write(target, read(placement.from .. "/" .. name), st.mode & 0x1ff))
      end
    end
  end
end

local record FixtureSpec
  name: string
  source: string
  timeout_ns: integer
  extra: {string:string}
  placements: {Placement} | nil
  --- Work done in this process just before the fixture starts.
  setup: function() | nil
end

--- What a fixture's `cosmic test` is run with: made afresh by
--- [`prepare_fixture`].
local record Prepared
  project: string
  command: {string}
  env: {string:string}
  out: string
  err: string
end

--- Makes the fixture `spec`'s project (a group's own where `group` is
--- given, [`fixture_project`]), places its inputs and its diagnostics
--- directory, and says what to run: `jobs` workers where given, else the
--- runner's default of one per processor.
local function prepare_fixture(c: Context, work: string, spec: FixtureSpec,
                               group?: string, jobs?: integer): Prepared
  local name, source = spec.name, spec.source
  assert(name:match("^[%w-]+$"), "invalid fixture test name")
  assert(source:match("^[%w_]+$"), "invalid fixture test source")
  if spec.setup then spec.setup() end
  local project = fixture_project(c, work, group)
  place(project, spec.placements or {})
  local diagnostics = work .. "/fixture-test-diagnostics/" .. name
  mkdir(diagnostics)
  mkdir(diagnostics .. "/tmp")
  -- No --census: a fixture's run holds too few tests for its key parts
  -- to say much, and an unsandboxed one's are keyed by nothing.
  local env = environment(spec.extra)
  local command = { assert(Proc.executable()), "test" }
  if jobs then
    command[#command + 1] = "--jobs"
    command[#command + 1] = tostring(jobs)
  end
  command[#command + 1] = "fixtures/" .. source .. "_test.tl"
  return { project = project, command = command,
    out = diagnostics .. "/test.out", err = diagnostics .. "/test.err",
    env = Orchestration.fixture_run(source, env, diagnostics .. "/tmp",
      work .. "/fixture-compiles.db") }
end

local function fixture_run_spec(c: Context, work: string, spec: FixtureSpec): integer
  local prepared = prepare_fixture(c, work, spec)
  local status = logged(c, "fixture: " .. spec.name, prepared.command,
    prepared.out, prepared.err, spec.timeout_ns, prepared.project, prepared.env)
  record_suite(c, "fixture " .. spec.name, status, prepared.out)
  return status
end

local function fixture_test(c: Context, work: string, name: string,
                            source: string, timeout_ns: integer, extra: {string:string},
                            placements?: {Placement}): integer
  return fixture_run_spec(c, work, { name = name, source = source,
    timeout_ns = timeout_ns, extra = extra, placements = placements })
end

--- The fixture `spec` as a [`Orchestration.Group`] for [`run_groups`]. Its
--- project is its own (named for its source), and its `cosmic test` runs
--- `jobs` workers where given. Its log is retained in files and said whole
--- when the group ends, as `logged` says it, so the suite summary a reader
--- or [`record_suite`] parses is unbroken by another group's output.
local function fixture_group(c: Context, work: string, spec: FixtureSpec,
                             jobs?: integer): Orchestration.Group
  local prepared: Prepared | nil = nil
  return {
    name = spec.name,
    run = function(): integer return fixture_run_spec(c, work, spec) end,
    start = function(): Runner.Running
      local made = prepare_fixture(c, work, spec, spec.source, jobs)
      prepared = made
      local runner, request = request_for(c, made.command, spec.timeout_ns,
        made.project, made.env, made.out, made.err)
      return Runner.spawn(runner, "fixture: " .. spec.name, request)
    end,
    finish = function(outcome: Runner.Outcome): integer
      local made = assert(prepared, "fixture group finished before it started")
      local replay_ok = replay(made.out, made.err)
      if outcome.code == 0 then
        assert(replay_ok, "could not replay retained output")
      end
      record_suite(c, "fixture " .. spec.name, outcome.code, made.out)
      return outcome.code
    end,
    abandon = function(_: Runner.Outcome)
      if prepared then replay(prepared.out, prepared.err) end
    end,
  }
end

-- Copy the exact selected candidate and controller into declared external
-- inputs. Full program bytes key this fixture: it exercises carried modules,
-- not only the native prefix. Release and checked runs keep distinct inputs.
local function performance_spec(c: Context, work: string, kind: string, program: string): FixtureSpec
  return {
    name = "performance-" .. kind .. "-regression", source = "performance",
    timeout_ns = performance_test_timeout_ns,
    extra = { COSMIC_TEST_TIMEOUT = performance_per_test_timeout_s },
    placements = { { kind = "performance", from = work .. "/performance-" .. kind .. "-inputs" } },
    setup = function()
      local inputs = work .. "/performance-" .. kind .. "-inputs"
      mkdir(inputs)
      assert(Fs.write(inputs .. "/program", read(program), 0x1ed))
      write(inputs .. "/perf.tl", read(c.root .. "/build/perf.tl"))
    end,
  }
end

local function performance_fixture(c: Context, work: string, kind: string, program: string): integer
  return fixture_run_spec(c, work, performance_spec(c, work, kind, program))
end

--- The checked core, verified on every leg -- its manifest entry in the
--- checked artifact, read by `decoder` (the contract's
--- format-test-<target>), its range, and that the artifact runs it --
--- and its whole suite run where COSMIC_CI_CHECKED_SUITE is not `skip`.
local function checked_suite(c: Context, target: string, work: string,
                             decoder: string): integer
  local sanitized = BuildPaths.directory(c.root) .. "/sanitized"
  local targets_path = sanitized .. "/targets.tsv"
  local target_id: string | nil = nil
  local checked_target: string | nil = nil
  local target_records = read(targets_path)
  for line in target_records:gmatch("[^\n]+") do
    local id, configuration, name =
      line:match("^(%d+)\t(%d+)\t([^\t]+)\t[^\t]+")
    if configuration == "2" and name == "sanitized" then
      assert(not target_id, "multiple sanitized target records")
      target_id = id
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
    { decoder, "--inspect", cosmic }, entry, Clock.seconds(30))
  if s ~= 0 then return s end
  local found = Fixture.entry(Fixture.inspection(entry),
    assert(math.tointeger(tonumber(target_id))), 2)
  assert(found, "checked manifest entry is missing: " .. read(entry))
  local offset, length, digest = found.offset, found.length, found.digest
  assert(offset % 16384 == 0,
    "checked manifest entry is unaligned: " .. read(entry))
  local artifact = read(cosmic)
  local raw = read(core)
  assert(length == #raw and #digest == 64, "checked core length/digest invalid")
  local extracted = artifact:sub(offset + 1, offset + length)
  assert(#extracted == length and Hash.hex_sha256(extracted) == digest and
      extracted == raw, "checked core range differs")
  write(work .. "/checked.core", extracted)
  -- The checked core keeps its debug information but names no path of
  -- the run that built it (build.zig's `debug_dir` and the generated
  -- map's `-g0`). The checked suite's verdicts are keyed by the core's
  -- image, its debug sections left out (build/core_image.tl). A core
  -- that names the tree root (per commit in CI, place_tree.tl) or the
  -- map's zig-cache directory (new on every relink) in what it loads,
  -- such as an assert's __FILE__, would move every key each run and
  -- stand on none. These are plain finds over the core already read
  -- above, some 35 ms for 38 MB. The tree root may be named under the
  -- checkout's own zig cache (run-local's `o/zig-cache`, whose vendored
  -- trees' paths the core's assert strings hold; build.zig's
  -- `debug_dir`), which is no path CI's builds name.
  -- TODO: hold each compile unit's DW_AT_comp_dir to "." here, reading
  -- the core's DWARF, once musl's is (the TODO beside build.zig's
  -- `debug_dir`): a unit naming the bare tree root is today told from
  -- musl's, which names whichever checkout first built libc, by nothing
  -- a find can see, so only a root followed by a path is refused. No
  -- key moves with a unit's comp_dir (the image leaves it out), so what
  -- this would add is only a checked core the same from every checkout.
  local cache = BuildPaths.directory(c.root) .. "/zig-cache/"
  local at = 1
  while true do
    local leak = raw:find(c.root .. "/", at, true)
    if not leak then break end
    assert(raw:sub(leak, leak + #cache - 1) == cache,
      "the checked core names a path under the tree root " .. c.root ..
        ": a compile lacks build.zig's -fdebug-compilation-dir=.")
    at = leak + #cache
  end
  assert(not raw:find("/coverage_map.c", 1, true),
    "the checked core names its generated coverage map's path: " ..
      "the map compiles without build.zig's -g0")
  local expected = offset .. "\t" .. length .. "\t" .. digest .. "\n"
  -- That the checked artifact runs the checked core: its runtime
  -- context as a chunk run with no tree around it (`cosmic -e`) sees it,
  -- which builds and writes nothing.
  local context = work .. "/checked-context.txt"
  s = capture_small(c, "checked runtime context", { cosmic, "-e",
    "local Store = require('cosmic.store'); print(Store.meta('runtime_context'), " ..
      "Store.meta('host'), Store.meta('host_image'))" }, context, Clock.seconds(30))
  if s ~= 0 then return s end
  assert(read(context) == "portable-v1\t" .. target .. "\t" .. digest .. "\n",
    "checked artifact did not execute the checked raw core: " .. read(context))
  -- The suite on the checked core takes three to six minutes. Most of
  -- what it checks is the same on every platform, so the workflow runs
  -- it once, in a job of its own on linux-x86_64's host (ci.yml's
  -- `checked`: phases `boot`, `checked-build` and this one), beside the
  -- legs rather than after one of them; every leg sets
  -- COSMIC_CI_CHECKED_SUITE=skip, and still builds and verifies the
  -- checked core above, which its fixtures use. macOS also runs the
  -- received-channel regressions: SIGPIPE protection on a channel
  -- whose option was cleared, and cleanup of oversized native rights.
  -- TODO: the core's platform-conditional C (__APPLE__, __aarch64__ in
  -- core/syscalls.c, executable.c, ...) is not run under the sanitizer
  -- off linux-x86_64: aside from macOS's received-channel regressions,
  -- a leg that skips the suite runs the checked cosmic only on a chunk
  -- (`-e`, above). A checked run of only the tests that enter that C, on the legs
  -- that skip the whole suite, would cover it for seconds: for macOS,
  -- ci/darwin-tests.txt names them.
  if Env.get("COSMIC_CI_CHECKED_SUITE") == "skip" then
    Fs.put(Fs.stderr, "checked suite: skipped on this leg " ..
        "(COSMIC_CI_CHECKED_SUITE=skip)\n")
    -- Such a leg keeps none of the suite's verdicts either, which the job
    -- that runs it keeps in a cache entry of its own. A file left in the
    -- leg's cache, none of whose rows a run reaches, would ride along
    -- whole in every save (cosmic_ci/verdicts.tl).
    local stale = Orchestration.suite_verdicts(Env.all(), "checked")
    if stale ~= "0" and exists(stale) then
      local removed, trouble = Fs.remove(stale)
      Fs.put(Fs.stderr, removed and ("checked suite: removed this leg's " .. stale .. "\n") or
          ("checked suite: could not remove " .. stale .. ": " .. tostring(trouble) .. "\n"))
    end
    if target == "aarch64-macos" then
      local diagnostics = work .. "/checked-diagnostics"
      mkdir(diagnostics)
      return logged(c, "checked received-channel regressions",
        { cosmic, "test", "--all", "core/socket_sigpipe_checked_test.tl" },
        diagnostics .. "/socket-sigpipe.out", diagnostics .. "/socket-sigpipe.err",
        checked_compile_timeout_ns, c.root, environment({ COSMIC_VERDICT_CACHE = "0" }))
    end
    return 0
  end
  -- The checked cosmic's first file in the tree, `tool.tl entry`, whose
  -- entry must be the decoder's, under a bound of its own in case it
  -- builds the tree again, so the suite's bound below times the suite.
  local compiled = work .. "/checked-compile.txt"
  s = capture_small(c, "checked tool entry", { cosmic,
    c.root .. "/test/portable/tool.tl", "entry", cosmic, target_id, "2" },
    compiled, checked_compile_timeout_ns)
  if s ~= 0 then return s end
  assert(read(compiled) == expected,
    "the checked cosmic reads another manifest entry: " .. read(compiled))
  local diagnostics = work .. "/checked-diagnostics"
  mkdir(diagnostics)
  -- c.root/o is not cleared: the sanitized binary's runtime identity
  -- differs from the release one's, so no release verdict can stand.
  -- The bound is about twice what the suite takes when no verdict
  -- stands: 271 s whole (248 to 285 over six main runs of September 2026)
  -- for 1948 tests on a 4-core host, each worker sandboxed, the checked
  -- core running each test about 2.9 times slower than the release core
  -- does; 3709 tests took 395 s locally on four cores in October 2026,
  -- and more than 600 s on CI's, in the merge queue.
  -- Where its key holds, it stands on the last run's verdicts as the
  -- local suite does: a commit that moves neither the core nor the
  -- runner keys the checked core by the same digest, since its image
  -- names no path of the run (asserted above), and its debug sections,
  -- where musl's units still name one, are no part of the key
  -- (build/core_image.tl). It keeps its verdicts in checked.db
  -- ([`suite_verdicts`]), and says which key parts a run that stands on
  -- none reached (`--census`, build/test.tl).
  -- --all where it stands on no verdict (`stands`): CI answers for
  -- every test then, whatever o/ holds.
  local checked_argv: {string} = { cosmic }
  local checked_words, checked_environment = Orchestration.suite_run({
    COSMIC_VERDICT_CACHE = Orchestration.suite_verdicts(Env.all(), "checked"),
    COSMIC_TEST_TIMEOUT = checked_suite_test_timeout_s })
  table.insert(checked_words, 2, "--census")
  for _, word in ipairs(checked_words) do
    checked_argv[#checked_argv + 1] = word
  end
  s = logged(c, "checked suite", checked_argv,
    diagnostics .. "/checked-test.out", diagnostics .. "/checked-test.err",
    checked_suite_timeout_ns, c.root, checked_environment)
  record_suite(c, "checked", s, diagnostics .. "/checked-test.out")
  write(diagnostics .. "/checked-test.status", tostring(s) .. "\n")
  -- The suite's per-test times and verdicts (its `runs` rows), which
  -- the workflow uploads with the diagnostics when the leg fails: what
  -- a timeout here leaves to read, since the suite's output names no
  -- times, and what says which tests the checked core runs slowest.
  if exists(BuildPaths.directory(c.root) .. "/build.db") then
    write(diagnostics .. "/build.db", read(BuildPaths.directory(c.root) .. "/build.db"))
  end
  return s
end

local function snapshot(c: Context, diagnostics: string, label: string,
                        cosmic: string): integer
  assert(label:match("^[%w-]+$"), "invalid snapshot label")
  local candidate = assert(Fs.absolute(c.root))
  local destination = assert(Fs.absolute(diagnostics))
  assert(destination ~= candidate and
      not String.starts_with(destination, candidate .. "/"),
    "snapshot path must be outside candidate checkout")
  local out = destination .. "/" .. label
  assert(not exists(out), "snapshot already exists: " .. out)
  mkdir(out)
  write(out .. "/build.db", read(BuildPaths.directory(c.root) .. "/build.db"))
  if exists(BuildPaths.directory(c.root) .. "/build.db-journal") then
    write(out .. "/build.db-journal", read(BuildPaths.directory(c.root) .. "/build.db-journal"))
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
      out .. "/integrity.out", out .. "/integrity.err", Clock.seconds(30), inspect)
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
                     diagnostics: string, env?: {string:string}, shard?: string): integer
  mkdir(diagnostics)
  local out = diagnostics .. "/" .. name .. "-test.out"
  local err = diagnostics .. "/" .. name .. "-test.err"
  local words, values = Orchestration.suite_run(env)
  values.COSMIC_TEST_TIMEOUT = suite_test_timeout_s
  -- Its key parts said, as the checked suite's are, for its row.
  table.insert(words, 2, "--census")
  if shard then
    words[#words + 1] = "--shard"
    words[#words + 1] = shard
  end
  local argv: {string} = { executable }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local status = logged(c, name .. " suite", argv, out, err,
    suite_timeout_ns, c.root, values)
  record_suite(c, name, status, out)
  write(diagnostics .. "/" .. name .. "-test.status", tostring(status) .. "\n")
  local snap_called, snap_answer = pcall(snapshot, c, diagnostics,
    name .. "-immediate", executable)
  local snapshot_status = snap_called and snap_answer or 1
  if not snap_called then Fs.put(Fs.stderr, tostring(snap_answer) .. "\n") end
  if status == 124 then
    Fs.put(Fs.stderr, name .. " suite: timed out (status 124)\n")
  elseif status ~= 0 then
    Fs.put(Fs.stderr,
      name .. " suite: failed (status " .. status .. ")\n")
  end
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

--- The candidate's cores and boot, on a fresh checkout: the `build`
--- phase without its native suite. It is all the `boot` phase runs, for
--- a job that runs no native suite (ci.yml's `checked`).
local function boot(p: PlatformContext): integer
  local c = p.operation
  local root = p.root
  assert(not exists(BuildPaths.directory(root) .. "/build.db"), "build requires fresh working database")
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
    mkdir(BuildPaths.directory(root))
    local copied = step(c, "restore zig-cache", function(): boolean, string
      return Fs.copy_tree(from, BuildPaths.directory(root) .. "/zig-cache")
    end)
    if copied ~= 0 then return copied end
  end
  -- A restore or a copy gives every file of zig's caches a new inode,
  -- which zig 0.17 reads as a changed C source (cosmic_ci/zig_restat.tl).
  if cache then
    local project = seed and cache or BuildPaths.directory(root) .. "/zig-cache"
    local _, out, err = ZigRestat.run(root, project, named("COSMIC_ZIG_GLOBAL_CACHE"))
    Fs.put(Fs.stderr, out .. err)
  end
  return checked(c, "core build and boot", { root .. "/bin/zig", "build", "cores", "boot" }, 0)
end

--- The list, in the checkout, of the test modules whose code takes a
--- path only macOS takes, each with why.
local darwin_list <const> = "ci/darwin-tests.txt"

--- The test modules `text`, a darwin list's, names: one path a line,
--- with what a `#` starts and blank lines left out.
function Orchestration.darwin_modules(text: string): {string}
  local modules: {string} = {}
  for line in text:gmatch("[^\n]+") do
    local path = String.trim((line:gsub("#.*$", "")))
    if path ~= "" then modules[#modules + 1] = path end
  end
  return modules
end

--- The `cosmic test` words of the darwin suite, given `words`, the
--- native suite's ([`test_words`]), and `modules`, the darwin list's
--- ([`darwin_modules`]): `--all` over those modules where the native
--- suite stands on verdicts, so none of them stands on one. A verdict
--- keyed by declarations stands on macOS for the key a Linux leg
--- reached, whose run never took the macOS branch its code has. Nil on
--- a run of every test already (the scheduled run, the backstop).
function Orchestration.darwin_words(words: {string}, modules: {string}): {string} | nil
  if #modules == 0 then return nil end
  for _, word in ipairs(words) do
    if word == "--all" then return nil end
  end
  local out: {string} = { "test", "--all", "--census" }
  for _, module in ipairs(modules) do out[#out + 1] = module end
  return out
end

--- Whether the native suite whose stdout is `text` and exit status
--- `code` passed having run every test of the tree, none standing on a
--- verdict, as after a core change or a moved harness epoch: then it ran
--- each listed module on this leg already. Not where it ran a share
--- (its summary names one) or chose no test at all.
function Orchestration.native_ran_every(text: string, code: integer): boolean
  local figures, status = SuiteOutput.read(text, code)
  return status == "pass" and figures.stood == 0 and (figures.ran or 0) > 0 and
    not (figures.sandbox or ""):find("shard", 1, true)
end

--- The darwin suite ([`darwin_words`]), on the macOS leg alone, on the
--- tree `boot` built, in the native suite's environment, with a row of
--- its own, "darwin", which says the listed modules ran -- or nothing,
--- said on stderr, where the native suite ran every test already
--- ([`native_ran_every`]). A phase of its
--- own, after `local-boundary`: it writes the working database, which
--- the boundary holds unchanged since the native suite, and ci.yml
--- keeps the native suite's verdicts for the run behind in the queue
--- before it, so that run waits on none of this.
local function phase_darwin_suite(p: PlatformContext): integer
  if p.target ~= "aarch64-macos" then return 0 end
  local c = p.operation
  local listed, trouble = Fs.read(c.root .. "/" .. darwin_list)
  if listed == nil then
    Fs.put(Fs.stderr, "darwin suite: cannot read " .. darwin_list .. ": " ..
        tostring(trouble) .. "\n")
    return 1
  end
  local suite_words, values = Orchestration.suite_run()
  local words = Orchestration.darwin_words(suite_words, Orchestration.darwin_modules(listed))
  if words == nil then return 0 end
  local native = p.local_diagnostics .. "/local-test"
  if (Env.get("COSMIC_CI_SHARD") or "") == "" and exists(native .. ".out") and
      exists(native .. ".status") then
    local code = math.tointeger(tonumber((read(native .. ".status"):gsub("%s+$", ""))))
    if code ~= nil and Orchestration.native_ran_every(read(native .. ".out"), code) then
      Fs.put(Fs.stderr, "darwin suite: the native suite ran every test here, none " ..
          "standing, so the listed modules ran on this leg already\n")
      return 0
    end
  end
  values.COSMIC_TEST_TIMEOUT = suite_test_timeout_s
  local argv: {string} = { BuildPaths.directory(p.root) .. "/bin/cosmic" }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  mkdir(p.local_diagnostics)
  local out = p.local_diagnostics .. "/darwin-test.out"
  local status = logged(c, "darwin suite", argv, out,
    p.local_diagnostics .. "/darwin-test.err", suite_timeout_ns, c.root, values)
  record_suite(c, "darwin", status, out)
  if status ~= 0 then
    Fs.put(Fs.stderr, "darwin suite: failed (status " .. status .. ")\n")
  end
  return status
end

--- The native suite, on the tree `boot` built: the `build` phase
--- without its boot, which ci.yml's legs run apart so that what comes
--- between (the verdicts of the merge queue's run ahead) waits on
--- nothing the boot does. Where COSMIC_CI_SHARD names a share (`I/N`,
--- a branch push's linux-x86_64 legs), only that share of its tests
--- (`cosmic test --shard`): the leg that runs each other share runs the
--- rest, on the same host.
local function phase_local_suite(p: PlatformContext): integer
  return suite(p.operation, "local", BuildPaths.directory(p.root) .. "/bin/cosmic", p.local_diagnostics,
    nil, named("COSMIC_CI_SHARD"))
end

--- `boot`, then the native suite (`local-suite`): ci/run-local's first
--- phase.
local function phase_build(p: PlatformContext): integer
  local s = boot(p)
  if s ~= 0 then return s end
  return phase_local_suite(p)
end

--- What the `checked` phase reads, on a booted tree, where assemble
--- does not run first (ci.yml's `checked` job): the checked build, and
--- the target's format decoder where the format-contract fixture would
--- leave it in the contract. The decoder is only built here, not
--- checked: that is the fixture's, on every leg.
local function phase_checked_build(p: PlatformContext): integer
  local c = p.operation
  local root = p.root
  local s = checked(c, "checked build", { root .. "/bin/zig", "build", "sanitized" })
  if s ~= 0 then return s end
  s = checked(c, "format decoder build", { root .. "/bin/zig", "build", "portable-format-" .. p.target })
  if s ~= 0 then return s end
  local format = p.contract .. "/format"
  local decoder = format .. "/format-test-" .. p.target
  assert(not exists(decoder), "format decoder already exists: " .. decoder)
  mkdir(format)
  write(decoder, read(BuildPaths.directory(root) .. "/portable-fixture/format/format-test-" .. p.target))
  return step(c, "format decoder mode", function(): boolean, string
    return Fs.chmod(decoder, 0x1ed)
  end)
end

local function phase_local_boundary(p: PlatformContext): integer
  local c = p.operation
  local root = p.root
  local local_d = p.local_diagnostics
  local s = snapshot(c, local_d, "local-boundary", BuildPaths.directory(root) .. "/bin/cosmic")
  if s ~= 0 then return s end
  assert(read(local_d .. "/local-immediate/hashes.sha256") == read(local_d .. "/local-boundary/hashes.sha256"), "local database changed across boundary")
  return 0
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
  local s = capture_small(c, "sandbox probe", { BuildPaths.directory(p.root) .. "/bin/cosmic",
    "build/sandbox_probe.tl" }, report, sandbox_probe_timeout_ns)
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

--- The format check's command, below: `fix --check .`, or, where
--- COSMIC_CI_FORMAT_CHANGED names a file, one path a line, of what
--- changed since the tree's base on main, which passed the whole tree's
--- check (driver.tl changed-paths, on a light run), `fix
--- --check --changed` of those paths, which lays out only them yet makes
--- every check spanning files over the whole tree, and lays out all of
--- it where a path named is part of what checks each file. A file that
--- cannot be read checks the whole tree.
local function format_command(root: string): {string}
  local command = { BuildPaths.directory(root) .. "/bin/cosmic", "fix", "--check" }
  local listed = Env.get("COSMIC_CI_FORMAT_CHANGED") or ""
  local text: string | nil = nil
  if listed ~= "" then
    local found, trouble = Fs.read(listed)
    text = found
    if found == nil then
      Fs.put(Fs.stderr, "format check: the whole tree, since what changed is not known: " ..
          trouble .. "\n")
    end
  end
  if text == nil then
    command[#command + 1] = "."
    return command
  end
  command[#command + 1] = "--changed"
  command[#command + 1] = "--"
  for line in text:gmatch("[^\n]+") do command[#command + 1] = line end
  return command
end

--- The tree's format check (`fix --check .`, which also builds and
--- type-checks the tree). It is the first thing assemble does, where a
--- tree formats and type-checks the same on every platform, so the
--- workflow runs it on one leg, and the others set COSMIC_CI_FORMAT=skip,
--- as COSMIC_CI_CHECKED_SUITE does the checked suite. On a branch push's
--- light run it is a phase of its own in ci.yml's `checked` job, which
--- runs no native suite, off the legs' path.
--- Where a native suite ran, `fix` writes the working database only
--- after its boundary was checked (`local-boundary`); a job that ran
--- none has no boundary to keep.
local function format_check(p: PlatformContext): integer
  if exists(p.local_diagnostics .. "/local-immediate/hashes.sha256") then
    assert(exists(p.local_diagnostics .. "/local-boundary/hashes.sha256"),
      "no local-boundary snapshot; run the local-boundary phase first")
  end
  if Env.get("COSMIC_CI_FORMAT") == "skip" then
    Fs.put(Fs.stderr, "format check: skipped on this leg " ..
        "(COSMIC_CI_FORMAT=skip)\n")
    return 0
  end
  return checked(p.operation, "format check", format_command(p.root))
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
      BuildPaths.directory(root) .. "/core/aarch64-macos/cosmic-core" })
  if s ~= 0 then return s end
  assert(ProductSetup.build(root, product, work .. "/product-setup") == product,
    "product setup returned the wrong product")
  write(work .. "/cosmic.before.sha256", hash(product .. "/cosmic") .. "\n")
  write(work .. "/product.before.sha256", read(product .. "/hashes.sha256"))
  s = fixture_test(c, work, "format-contract", "format",
    format_test_timeout_ns, {
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
  s = checked(c, "hook-core build", { root .. "/bin/zig", "build", "portable-hook-cores", "--prefix", work .. "/prebuilt" })
  if s ~= 0 then return s end
  mkdir(work .. "/prebuilt/portable-fixture/sanitized")
  write(work .. "/prebuilt/portable-fixture/sanitized/cosmic-core", read(BuildPaths.directory(root) .. "/sanitized/cosmic-core"))
  assert(RuntimeSetup.build(root, work .. "/prebuilt", product .. "/cosmic",
    product .. "/cosmic.db", runtime, work .. "/runtime-setup") == runtime,
    "runtime setup returned the wrong output")
  s = fixture_test(c, work, "product-verification", "product",
    product_test_timeout_ns, {
      COSMIC_FIXTURE_TARGET = target,
      COSMIC_FIXTURE_CODESIGN = target == "aarch64-macos" and "true" or "false",
    }, { { kind = "product", from = product },
      { kind = "format", from = contract .. "/format" } })
  if s ~= 0 then return s end
  s = checked(c, "selected format mutation", { contract .. "/format/format-test-" .. target, contract .. "/format/program" })
  if s ~= 0 then return s end
  s = archive(c, fresh)
  if s ~= 0 then return s end
  mkdir(portable_d)
  write(portable_d .. "/cosmic-portable", read(product .. "/cosmic"));
  s = step(c, "portable executable mode", function(): boolean, string
    return Fs.chmod(portable_d .. "/cosmic-portable", 0x1ed)
  end)
  if s ~= 0 then return s end
  write(portable_d .. "/portable-artifact.before.sha256", hash(portable_d .. "/cosmic-portable") .. "\n")
  return 0
end

local function phase_portable(p: PlatformContext): integer
  local c = p.operation
  local portable_d = p.portable_diagnostics
  local fresh = p.fresh
  local executable = portable_d .. "/cosmic-portable"
  local portable_context: Context = { db = c.db, worker = c.worker, run = c.run,
    attempt = c.attempt, root = fresh, driver = c.driver, phase = c.phase }
  local s = 0
  -- The suite reruns the local suite's tests under the portable build,
  -- whose artifact carries the cores the tree's tool does (`ProductSetup`);
  -- each leg's launcher, runtime and identity fixtures still run the
  -- portable product's launcher (phase_fixtures). So a push to main
  -- runs it on the two x86-64 legs, a glibc host and a musl one, the
  -- merge queue on the musl one alone (the glibc leg's bytes are the
  -- same, which provenance holds), and the others set
  -- COSMIC_CI_PORTABLE_SUITE=skip; the scheduled run and a manual one
  -- keep it on every leg (ci.yml). A leg that skips it still
  -- checks the artifact unchanged since assemble (attest).
  if Env.get("COSMIC_CI_PORTABLE_SUITE") == "skip" then
    Fs.put(Fs.stderr, "portable suite: skipped on this leg " ..
        "(COSMIC_CI_PORTABLE_SUITE=skip)\n")
  else
    -- Where the other suites stand on verdicts (`stands`), it stands on
    -- the local suite's ([`suite_verdicts`]): a sealed worker's key is
    -- the same under either artifact, and every other worker's holds
    -- its launcher; elsewhere it runs every test, as they do.
    s = suite(portable_context, "portable", executable, portable_d,
      { COSMIC_PORTABLE_CACHE = portable_d .. "/portable-full-suite-cache",
        COSMIC_VERDICT_CACHE = Orchestration.suite_verdicts(Env.all(), "portable") })
  end
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
    attempt = c.attempt, root = fresh, driver = c.driver, phase = c.phase }
  -- No suite ran (phase_portable), so no database and no cache of its
  -- to hold across the boundary.
  if Env.get("COSMIC_CI_PORTABLE_SUITE") == "skip" then
    Fs.put(Fs.stderr, "portable boundary: skipped on this leg " ..
        "(COSMIC_CI_PORTABLE_SUITE=skip)\n")
    return 0
  end
  local s = snapshot(portable_context, portable_d, "portable-boundary",
    portable_d .. "/cosmic-portable")
  if s ~= 0 then return s end
  if p.trailing == "success" then
    assert(read(portable_d .. "/portable-immediate/hashes.sha256") == read(portable_d .. "/portable-boundary/hashes.sha256"), "portable database changed across boundary")
    local executable = portable_d .. "/cosmic-portable"
    local cache = portable_d .. "/portable-full-suite-cache"
    local locked = step(portable_context, "portable cache read-only mode",
      function(): boolean, string return Fs.chmod(cache, 0x140) end)
    if locked ~= 0 then return locked end
    local help = checked(portable_context, "read-only cache execution",
      { executable, "help" }, Clock.seconds(30), fresh, environment({ COSMIC_PORTABLE_CACHE = cache }))
    local restored = step(portable_context, "portable cache restore mode",
      function(): boolean, string return Fs.chmod(cache, 0x1c0) end)
    if help ~= 0 then return help end
    if restored ~= 0 then return restored end
  end
  return 0
end

--- The candidate's tracked source, unpacked afresh at `destination`
--- from the `git archive` assemble made of it (`archive`, beside
--- `p.fresh`, where the portable suite has written its o/ since): the
--- tree a fixture that boots or rebuilds one copies
--- (COSMIC_FIXTURE_SOURCE, [`Fixture.source_tree`]), the one the product
--- was booted from.
local function fixture_source(p: PlatformContext, destination: string): integer
  return step(p.operation, "fixture source extract", function(): boolean, string
    assert(Fs.remove_tree(destination))
    mkdir(destination)
    local written, trouble = Archive.extract(p.fresh .. ".tar", destination,
      { links = "create" })
    return written ~= nil, trouble
  end)
end

--- Copies the leg's compiles and parses -- `env`'s COSMIC_BUILD_CACHE, or
--- the default file build/shared_compiles.tl names where it names none --
--- to `destination`, which must not exist: the self-rebuild fixture's
--- seed (COSMIC_FIXTURE_COMPILES). The leg's boot compiled the candidate
--- into that file, so a tool it built rebuilding itself from the
--- candidate's tree takes back every module it has not edited. A copy,
--- taken through SQLite since the file is in WAL mode, so the rows the
--- fixture's rebuilds write are never saved with the leg's. A row's
--- bytecode runs, so the file is held to what build/shared_compiles.tl
--- holds it to before a build reads it: an absolute path, a file and
--- no link, it and its directory this user's and writable by no one
--- else. False and why
--- when the leg keeps no such file; a leg whose COSMIC_BUILD_CACHE is
--- `0` keeps none, and is refused rather than left to compile every
--- case cold.
function Orchestration.seed_compiles(env: {string:string},
                                     destination: string): boolean, string
  local source = env.COSMIC_BUILD_CACHE or ""
  if source == "0" then
    return false, "COSMIC_BUILD_CACHE=0: the leg keeps no compiles to seed " ..
      "the self-rebuild fixture with; unset it, or name a file"
  end
  if source == "" then
    local dir, trouble = Fs.cache_dir("build", { environment = env, make = false })
    if dir == nil then return false, trouble end
    source = dir .. "/cache.db"
  end
  if source:sub(1, 1) ~= "/" then
    return false, "COSMIC_BUILD_CACHE names no absolute path: " .. source
  end
  local held: {{string, sys.Kind}} = { { Fs.dirname(source), "dir" }, { source, "file" } }
  for _, pair in ipairs(held) do
    local path, kind = pair[1], pair[2]
    -- A link to the directory is followed, as shared_compiles' `private`
    -- follows it; one to the file is not.
    local st, stat_trouble: sys.Stat, string = nil, ""
    if kind == "file" then
      st, stat_trouble = sys.lstat(path)
    else
      st, stat_trouble = sys.stat(path)
    end
    if st == nil then return false, path .. ": " .. stat_trouble end
    if st.kind ~= kind then
      return false, path .. ": not a " .. (kind == "dir" and "directory" or kind)
    end
    if st.uid ~= sys.getuid() then return false, path .. ": owned by another user" end
    if st.mode & 0x12 ~= 0 then
      return false, path .. ": writable by its group or others"
    end
  end
  if Fs.exists(destination) then
    return false, destination .. ": already exists"
  end
  local db, open_trouble = Sqlite.open(source)
  if db == nil then return false, source .. ": " .. open_trouble end
  local quoted = (destination:gsub("'", "''"))
  local copied, copy_trouble = db:exec("VACUUM INTO '" .. quoted .. "'")
  local _, _ = db:close()
  if not copied then return false, source .. ": " .. copy_trouble end
  return true, ""
end

--- The workers of the two lanes the fixtures run in at once
--- ([`run_groups`]), high and low, when `env` asks for them
--- (COSMIC_CI_FIXTURE_BUDGET=run) and `cpus` allow two: the high lane's
--- `--jobs` is all processors but one, the low lane's one, so together they
--- never claim more workers than processors. Nil when the fixtures run one
--- after another, as they always did.
function Orchestration.fixture_lanes(env: {string:string}, cpus: integer): integer | nil, integer | nil
  if env.COSMIC_CI_FIXTURE_BUDGET ~= "run" or cpus < 2 then return nil, nil end
  return cpus - 1, 1
end

--- Runs `high`, then each of `low`, one after another, and returns the first
--- nonzero status (0 for all well), the rest not started. With `lanes`, `high`
--- runs beside the low groups, which run in turn: whichever of the two
--- lanes' groups ends first is reaped and its log said whole, so output
--- never interleaves. Each group keeps the timeout it was spawned
--- with. A nonzero status, a timeout or an error in either lane stops the
--- other lane's group, process group included, and reaps it
--- ([`Runner.stop`]) before this returns or raises; no group is left
--- running or unobserved, and nothing is started after a failure. The caller
--- does what must follow every group (the product's checks, attest)
--- only on a 0.
function Orchestration.run_groups(high: Orchestration.Group,
                                  low: {Orchestration.Group}, lanes: boolean): integer
  if not lanes then
    local status = high.run()
    if status ~= 0 then return status end
    for _, group in ipairs(low) do
      status = group.run()
      if status ~= 0 then return status end
    end
    return 0
  end
  local active: {Runner.Running} = {}
  local owner: {Runner.Running:Orchestration.Group} = {}
  local in_low: {Runner.Running:boolean} = {}
  local function begin(group: Orchestration.Group, is_low: boolean)
    local running = group.start()
    active[#active + 1] = running
    owner[running] = group
    in_low[running] = is_low
  end
  local status = 0
  local next_low = 1
  local ran, failure = pcall(function(): boolean
    begin(high, false)
    if low[1] then
      begin(low[1], true)
      next_low = 2
    end
    while #active > 0 and status == 0 do
      local done = Runner.wait_any(active)
      for index, running in ipairs(active) do
        if running == done then
          table.remove(active, index)
          break
        end
      end
      local group = owner[done]
      status = group.finish(Runner.reap(done))
      if status == 0 and in_low[done] and low[next_low] then
        local following = low[next_low]
        next_low = next_low + 1
        begin(following, true)
      end
    end
    return true
  end)
  for _, running in ipairs(active) do
    local outcome = Runner.stop(running)
    local abandoned, trouble = pcall(function(): boolean
      owner[running].abandon(outcome)
      return true
    end)
    if not abandoned and ran then ran, failure = false, trouble end
  end
  if not ran then error(failure, 0) end
  return status
end

local function phase_fixtures(p: PlatformContext): integer
  local c = p.operation
  local target = p.target
  local work = p.work
  local product = p.product
  local contract = p.contract
  local runtime = p.runtime
  local source = work .. "/fixture-source"
  local s = fixture_source(p, source)
  if s ~= 0 then return s end
  -- What the self-rebuild regression finds -- a rename, an unlink or a
  -- lock gone wrong under a running tool -- shows on glibc Linux and on
  -- macOS's file system, so a gating run runs it on those two legs, and
  -- the others set COSMIC_CI_SELF_REBUILD=skip; the scheduled run keeps
  -- it on every leg (ci.yml).
  if Env.get("COSMIC_CI_SELF_REBUILD") == "skip" then
    Fs.put(Fs.stderr, "fixture: self-rebuild-regression: skipped on this leg " ..
        "(COSMIC_CI_SELF_REBUILD=skip)\n")
  else
    local compiles = work .. "/self-rebuild-compiles.db"
    s = step(c, "self-rebuild compiles seed", function(): boolean, string
      if Fs.exists(compiles) then assert(Fs.remove(compiles)) end
      return Orchestration.seed_compiles(Env.all(), compiles)
    end)
    if s ~= 0 then return s end
    s = fixture_test(c, work, "self-rebuild-regression", "self_rebuild",
      self_rebuild_test_timeout_ns, {
        COSMIC_FIXTURE_SOURCE = source,
        COSMIC_FIXTURE_RUNTIME = runtime,
        COSMIC_FIXTURE_COMPILES = compiles,
        COSMIC_TEST_TIMEOUT = self_rebuild_per_test_timeout_s,
      })
    if s ~= 0 then return s end
  end
  -- The fixed-point regression is the slowest fixture on every leg
  -- (about 220 to 380 s: `fixed_point_test_timeout_ns` says why), and what
  -- it checks, that the compiler compiles itself to itself, is the same
  -- on every platform. So no gating run runs it (ci.yml sets
  -- COSMIC_CI_FIXED_POINT=skip); main's scheduled run runs it on every
  -- leg.
  if Env.get("COSMIC_CI_FIXED_POINT") == "skip" then
    Fs.put(Fs.stderr, "fixture: fixed-point-regression: skipped on this leg " ..
        "(COSMIC_CI_FIXED_POINT=skip)\n")
  else
    -- The compiles its sharing cases share, made afresh for each run.
    local shared = work .. "/fixed-point-compiles"
    s = step(c, "fixed-point compiles", function(): boolean, string
      return Fs.remove_tree(shared)
    end)
    if s ~= 0 then return s end
    s = fixture_test(c, work, "fixed-point-regression", "fixed_point",
      fixed_point_test_timeout_ns, {
        COSMIC_FIXTURE_SOURCE = source,
        COSMIC_FIXTURE_PRODUCT = product,
        COSMIC_FIXTURE_SHARED_COMPILES = shared .. "/cache.db",
        COSMIC_TEST_TIMEOUT = fixed_point_per_test_timeout_s,
      })
    if s ~= 0 then return s end
  end
  -- What is left is independent of one another: each fixture has a
  -- project of its own ([`fixture_group`]) and reads prepared inputs. Run
  -- one after another, the one-test self-driven fixture leaves the
  -- processors idle beside the small groups' tail (#2778); with
  -- COSMIC_CI_FIXTURE_BUDGET=run it runs beside them in a lane of
  -- processors - 1 workers, and they in one of 1, the total never more
  -- than the processors ([`fixture_lanes`]). Each keeps its own timeout.
  local high_jobs, low_jobs = Orchestration.fixture_lanes(Env.all(), Proc.cpu_count())
  local launcher_placements: {Placement} = {
    { kind = "product", from = product, only = { "prefix" } },
    { kind = "launcher", from = contract .. "/launcher" } }
  local high = fixture_group(c, work, { name = "self-driven-regression",
    source = "self_driven", timeout_ns = self_driven_test_timeout_ns, extra = {
      COSMIC_FIXTURE_SOURCE = source,
      COSMIC_FIXTURE_PRODUCT = product,
      COSMIC_TEST_TIMEOUT = self_driven_per_test_timeout_s,
    } }, high_jobs)
  local low: {Orchestration.Group} = {}
  local function add(spec: FixtureSpec)
    low[#low + 1] = fixture_group(c, work, spec, low_jobs)
  end
  add({ name = "runtime-regression", source = "runtime",
    timeout_ns = runtime_test_timeout_ns, extra = {},
    placements = { { kind = "product", from = product, only = { "prefix" } },
      { kind = "runtime", from = runtime } } })
  add({ name = "launcher-regression", source = "launcher",
    timeout_ns = launcher_test_timeout_ns,
    extra = { COSMIC_FIXTURE_TARGET = target },
    placements = launcher_placements })
  if Orchestration.noexec_fixture(target) then
    add({ name = "launcher-noexec-regression", source = "launcher_noexec",
      timeout_ns = launcher_noexec_test_timeout_ns,
      extra = { COSMIC_FIXTURE_TARGET = target },
      placements = launcher_placements })
  end
  add({ name = "identity-regression", source = "identity",
    timeout_ns = identity_test_timeout_ns,
    extra = { COSMIC_TEST_TIMEOUT = identity_per_test_timeout_s },
    placements = { { kind = "product", from = product, only = { "prefix" } },
      { kind = "runtime", from = runtime } } })
  add(performance_spec(c, work, "release", product .. "/cosmic"))
  s = Orchestration.run_groups(high, low, high_jobs ~= nil)
  if s ~= 0 then return s end
  -- The product fixture ran on these bytes in assemble
  -- (product-verification); run again on the same bytes and inputs, it
  -- would check nothing more than that none of them moved since.
  local changed = ProductSetup.changed(product,
    read(work .. "/product.before.sha256"))
  assert(changed == nil, "product mutated by fixtures: " .. tostring(changed))
  assert(hash(product .. "/cosmic") .. "\n" == read(work .. "/cosmic.before.sha256"), "product mutated by fixtures")
  return 0
end

local function phase_attest(p: PlatformContext): integer
  local work = p.work
  local product = p.product
  local portable_d = p.portable_diagnostics
  local before = read(work .. "/cosmic.before.sha256")
  local digest = hash(product .. "/cosmic") .. "\n"
  assert(before == digest and before == read(portable_d .. "/portable-artifact.before.sha256") and before == read(portable_d .. "/portable-artifact.after.sha256"), "executed artifact attestation differs")
  write(product .. "/executed-cosmic.sha256", digest:sub(1, 64) .. "  cosmic\n")
  write(product .. "/expected-platforms", assert(p.trailing) .. "\n")
  return 0
end

local function platform_impl(phase: string, p: PlatformContext): integer
  assert(targets[p.target], "unsupported target")
  mkdir(p.work)
  if phase == "build" then
    return phase_build(p)
  elseif phase == "boot" then
    return boot(p)
  elseif phase == "local-suite" then
    return phase_local_suite(p)
  elseif phase == "local-boundary" then
    return phase_local_boundary(p)
  elseif phase == "darwin-suite" then
    return phase_darwin_suite(p)
  elseif phase == "format" then
    return format_check(p)
  elseif phase == "checked-build" then
    return phase_checked_build(p)
  -- Assemble's checked core, verified and (COSMIC_CI_CHECKED_SUITE) its
  -- suite run, alone, on a checked build already there: assemble's, or
  -- `checked-build`'s.
  elseif phase == "checked" then
    return checked_suite(p.operation, p.target, p.work,
      p.contract .. "/format/format-test-" .. p.target)
  elseif phase == "performance-checked" then
    return performance_fixture(p.operation, p.work, "checked", BuildPaths.directory(p.root) .. "/sanitized/bin/cosmic")
  elseif phase == "sandbox" then
    return phase_sandbox(p)
  elseif phase == "assemble" then
    return phase_assemble(p)
  elseif phase == "portable" then
    return phase_portable(p)
  elseif phase == "portable-boundary" then
    return phase_portable_boundary(p)
  elseif phase == "fixtures" then
    return phase_fixtures(p)
  elseif phase == "attest" then
    return phase_attest(p)
  end
  error("unknown platform phase: " .. phase)
end

local function provenance_impl(c: Context, products: string): integer
  local entries = assert(Fs.list(products))
  local count = 0
  local expected: integer|nil = nil
  local baseline: string|nil = nil
  for _, name in ipairs(entries) do
    if name:match("^portable%-product%-.+") then
      local p = products .. "/" .. name
      local att = p .. "/executed-cosmic.sha256"
      local exp = p .. "/expected-platforms"
      assert(exists(att) and exists(exp) and exists(p .. "/cosmic"), "incomplete product: " .. p)
      local line = read(att)
      local digest = line:match("^([0-9a-f]+)  cosmic\n$")
      assert(digest and #digest == 64, "invalid attestation: " .. att)
      assert(hash(p .. "/cosmic") == digest, "changed artifact: " .. p)
      local n = math.tointeger(assert(tonumber(read(exp))))
      assert(n and n > 0, "invalid expected count")
      if expected then assert(expected == n, "inconsistent expected count") else expected = n end
      if baseline then
        assert(baseline == digest, "worker artifact hashes differ")
      else
        baseline = digest
      end
      count = count + 1
    end
  end
  assert(expected and count == expected, "expected " .. Plural.count(expected, "product") .. ", found " .. count)
  return step(c, "provenance comparison", function(): boolean, string
    return true
  end)
end

local function run_phase(c: Context, name: string, action: function(): integer): integer
  return Runner.phase({ database = c.db, worker = c.worker, run = c.run,
    attempt = c.attempt, candidate = c.root }, name, action)
end

function Orchestration.platform(a: {string}): integer
  local phase = assert(a[1], "usage: driver.tl platform PHASE [ARG]")
  local ctx = ContextEnv.read()
  local target = ContextEnv.target()
  local c: Context = { db = ctx.db, worker = ctx.worker, run = ctx.run,
    attempt = ctx.attempt, root = ctx.root, driver = assert(Fs.absolute(assert(a[0]))),
    phase = phase }
  local p: PlatformContext = { trailing = a[2], operation = c, root = ctx.root,
    target = target, work = ctx.work, product = ctx.work .. "/product",
    contract = ctx.work .. "/contract", runtime = ctx.work .. "/runtime",
    local_diagnostics = ctx.work .. "/local-diagnostics",
    portable_diagnostics = ctx.work .. "/portable-diagnostics",
    fresh = ctx.work .. "/portable-source" }
  return run_phase(c, "platform: " .. phase, function(): integer
    return platform_impl(phase, p)
  end)
end

function Orchestration.provenance(a: {string}): integer
  local ctx = ContextEnv.read()
  local c: Context = { db = ctx.db, worker = ctx.worker, run = ctx.run,
    attempt = ctx.attempt, root = ctx.root, driver = assert(Fs.absolute(assert(a[0]))) }
  return run_phase(c, "provenance", function(): integer
    return provenance_impl(c, ctx.products)
  end)
end

return Orchestration
