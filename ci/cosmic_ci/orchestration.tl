local ContextEnv = require("cosmic_ci.context")
local Env = require("cosmic.env")
local Fixture = require("cosmic_ci.fixture")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local Hash = require("cosmic.hash")
local LauncherSetup = require("cosmic_ci.launcher_setup")
local ProductSetup = require("cosmic_ci.product_setup")
local Archive = require("cosmic.archive")
local Child = require("cosmic.child")
local Proc = require("cosmic.proc")
local Runner = require("cosmic_ci.runner")
local RunNames = require("cosmic_ci.run_names")
local RuntimeSetup = require("cosmic_ci.runtime_setup")
local State = require("cosmic_ci.state")
local SuiteOutput = require("cosmic_ci.suite_output")
local Time = require("cosmic.time")
local Plural = require("cosmic_ci.plural")

local record Orchestration
  stands: function(env: {string:string}): boolean
  harness_moved: function(root: string, base: string): boolean, string
  test_words: function(env: {string:string}): {string}
  shares: function(env: {string:string})
  sandboxed_fixtures: {string:boolean}
  fixture: function(env: {string:string}, tmpdir: string, compiles: string,
    verdicts?: string): {string:string}
  fixture_run: function(source: string, env: {string:string}, tmpdir: string,
    compiles: string): {string:string}
  forget_run: function(env: {string:string})
  suite_run: function(extra?: {string:string}): {string}, {string:string}
  suite_verdicts: function(env: {string:string}, name: string): string
  darwin_modules: function(text: string): {string}
  darwin_words: function(words: {string}, modules: {string}): {string} | nil
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
-- image names itself (COSMIC_SYSTEM_ID, .github/scripts/leg-host-id.sh),
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
local git_timeout_ms <const> = 60 * 1000

--- Runs git in the checkout at `root`, never asking for credentials
--- (GIT_TERMINAL_PROMPT=0) and ended past `git_timeout_ms`: what it
--- printed, or nil and why it failed, its own stderr among it.
local function git(root: string, words: {string}): string | nil, string
  local argv = { "/usr/bin/env", "git", "-C", root }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local env = Env.all()
  env.GIT_TERMINAL_PROMPT = "0"
  local result, trouble = Child.run(argv, { env = env, stdout = "capture",
    stderr = "capture", timeout_ms = git_timeout_ms })
  if result == nil then return nil, "git " .. words[1] .. ": " .. trouble end
  if result.timed_out then
    return nil, "git " .. words[1] .. ": timed out after " .. (git_timeout_ms // 1000) .. " s"
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
    Fs.put(Fs.stderr, "merge queue: " .. (moved and "every suite runs every test (--all): "
      or "suites stand on verdicts: ") .. why .. "\n")
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
  if extra then for k, v in pairs(extra) do all[k] = v end end
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
  -- Where the leg has no sandbox but stands on verdicts all the same
  -- (COSMIC_CI_DECLARED_KEYS, the macOS leg), every operation is given
  -- COSMIC_TEST_KEY=declared, which only the pinned driver's `cosmic
  -- test` reads, for the fixtures it runs: without it, that release keys
  -- each test by what it was seen to read, which no other checkout
  -- shares. The tree's own tool, which runs the leg's suites, keys every
  -- unsandboxed run by declaration and reads it nowhere. A fixture's run
  -- takes it back out ([`Orchestration.fixture`]), and a test's own
  -- `cosmic test` is not given it (`test.worker_environment`).
  -- TODO: drop COSMIC_TEST_KEY here, and from [`Orchestration.fixture`] and
  -- orchestration_test.tl, once ci/cosmic-driver.pin names a release
  -- that keys every unsandboxed run by declaration (plan 4.2's PR 3).
  if all.COSMIC_CI_DECLARED_KEYS == "1" then all.COSMIC_TEST_KEY = "declared" end
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
    if name:sub(1, #prefix) == prefix then return true end
  end
  return false
end

--- Removes from `env`, a gating suite's, every variable that names the
--- run ([`names_the_run`]). A test that reads the whole environment
--- (`env = {"*"}`) is keyed by every variable its worker is given, so
--- one that moves each run (GITHUB_RUN_ID, GITHUB_SHA, RUNNER_NAME,
--- COSMIC_CI_SCOPE, ...) would keep such a test from standing on any
--- earlier run's verdict. No tree test reads one, so none is given one,
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
--- It is not the other suites' file. The portable artifact carries the
--- cores o/bin/cosmic does, from o/core (`ProductSetup`), so a test that
--- does not run the program (`tool`) may key the same under either: the
--- same runtime identity, and the same identity of what runs that core
--- (build/declared_key.tl's `launcher_identity`) wherever the two
--- artifacts' launchers and manifests are. In one file, the portable
--- suite would stand on the local suite's verdicts of minutes earlier
--- and run nothing under the portable build. Apart, it runs each such
--- test itself and stands only on earlier portable runs', whose keys
--- move with its launcher, cores and manifest as with anything else a
--- test is given.
---
--- Nor is it the checked suite's (`checked`): the local suite's rows
--- would crowd the checked suite's toward the file's bound, and the
--- checked suite's census (`--census`) counts only its own suite's rows
--- when the file is its own.
function Orchestration.suite_verdicts(env: {string:string}, name: string): string
  local shared = env.COSMIC_VERDICT_CACHE or ""
  if shared:sub(1, 1) ~= "/" then return "0" end
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
      stood = figures.stood, every = figures.every, assumed = figures.assumed,
      shared = figures.shared, failed = figures.failed,
      elapsed_ms = figures.elapsed_ms, sandbox = figures.sandbox,
      parts = figures.parts, held = figures.held })
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
local product_test_timeout_ms <const> = 60000
local format_test_timeout_ms <const> = 300000
-- The sandboxed fixtures (`sandboxed_fixtures`) take 6 to 28 s where
-- they run, under ci/run-local on a loaded four-core host (launcher 6 s,
-- runtime 10 s, identity 28 s), and 4 to 6 s where their verdicts stand;
-- each bound is several times that.
local launcher_test_timeout_ms <const> = 60000
local launcher_noexec_test_timeout_ms <const> = 60000
local self_rebuild_test_timeout_ms <const> = 180000
-- Each self-rebuild test rebuilds the tool (about 20 s, several at once),
-- past the runner's default 30 s per test on a loaded machine.
local self_rebuild_per_test_timeout_s <const> = "120"
-- Each fixed-point test rebuilds the product twice from a fresh tree, and
-- the compiler's cases -- the compiler's own, its identity redefined, and
-- that redefined with the fingerprint -- each compile the whole tree
-- about twice over (80 s alone on four cores; the sixth case, the last of
-- these, adds about 20 to 30 s to the fixture), so each runs apart from
-- the self-rebuild file's.
local fixed_point_test_timeout_ms <const> = 300000
--- The whole suite on the checked core: see [`checked_suite`]'s comment
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
local runtime_test_timeout_ms <const> = 90000
-- The sandbox probe starts six trivial children; its bound is the
-- tree's own load, which a booted tree has already paid.
local sandbox_probe_timeout_ms <const> = 60000
local identity_test_timeout_ms <const> = 120000
-- The identity suite takes 21-30 s whole on macOS, and 35 s at worst, past
-- the runner's default 30 s per test. Its focused-embed step takes 21 s of
-- that alone and is a test of its own. The two run at once on a runner of
-- two or more processors, so both near this bound still end inside the
-- whole file's.
local identity_per_test_timeout_s <const> = "60"
-- The checked cosmic's first file in the tree after the checked build
-- ([`checked_suite`]). A boot names the analyzer as the tool it writes
-- does (build/importer.tl's `tree_code`), so that file builds nothing
-- again: 0.3-0.7 s here. A reparse of every source would take 30-35 s by
-- the checked cosmic under ci/run-local on a 4-core host, once 41 s.
-- TODO: lower this bound once CI's own runs show the step's time
-- without that reparse; it is still sized for it.
local checked_compile_timeout_ms <const> = 300000

-- A whole `cosmic test` run of every test, sandboxed, takes about 96 s of
-- tests on a four-core runner (1872 tests), after a build of up to 25 s
-- where the tree is compiled cold (the portable suite, macOS) and up to
-- 10 s writing the closure stores: about 130 s whole. The run's own
-- bound is about twice that. Each test gets far less than the whole run,
-- so a test that hangs is ended and named by the runner, not hidden under
-- a cancelled run.
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

--- The fixtures (ci/fixtures/<name>_test.tl) whose workers run
--- sandboxed, where the leg sandboxes its suites, and whose verdicts are
--- shared (`fixture`). Each declares with [`Test.needs`] every path it
--- reads by the variable that says where it is -- the product
--- (COSMIC_FIXTURE_PRODUCT), the runtime setup's directory
--- (COSMIC_FIXTURE_RUNTIME), the launcher contract's
--- (COSMIC_FIXTURE_LAUNCHER) or the format decoders'
--- (COSMIC_FIXTURE_FORMAT) -- so its key holds what each holds, not
--- where it is. Each is tied to the parts of the product the leg attests
--- ([`phase_attest`]) that it exercises: the product's `prefix`, its
--- launcher, manifest and cores, which [`fixture_test`] gives it, and
--- the content-keyed artifacts it runs, each by its bytes, so no fixture
--- stands on a verdict another launcher, core or artifact reached
--- (orchestration_test.tl holds each to the prefix). `product` checks
--- the whole product, and declares every file of it; the rest run
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
--- compile it cold, with zig's caches and the host's toolchain, and
--- `launcher_noexec` needs the host's own noexec mount
--- (launcher_noexec_test.tl's TODO).
Orchestration.sandboxed_fixtures = {
  product = true, runtime = true, launcher = true, identity = true,
}

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
--- what the tool built from it compiles again (fixed_point_test,
--- self_rebuild_test), it must compile and parse.
function Orchestration.fixture(env: {string:string}, tmpdir: string,
    compiles: string, verdicts?: string): {string:string}
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
  -- (COSMIC_VERDICT_CACHE=0); it declares the whole environment it reads.
  env.COSMIC_TEST_KEY = nil
  return env
end

--- The environment the fixture ci/fixtures/<source>_test.tl runs in,
--- made of `env`, the operation's (`environment`, its COSMIC_FIXTURE_*
--- among it), by `fixture`: one of `sandboxed_fixtures` keeps its
--- verdicts in `fixtures.db` beside the file COSMIC_VERDICT_CACHE of
--- `env` names ([`suite_verdicts`]), and must be given the product its
--- verdicts are keyed by (COSMIC_FIXTURE_PRODUCT); any other shares none.
function Orchestration.fixture_run(source: string, env: {string:string}, tmpdir: string,
    compiles: string): {string:string}
  local sandboxed = Orchestration.sandboxed_fixtures[source] == true
  assert(not sandboxed or (env.COSMIC_FIXTURE_PRODUCT or "") ~= "",
    "a sandboxed fixture is given the product its verdict is keyed by: " .. source)
  local verdicts: string | nil = nil
  if sandboxed then verdicts = Orchestration.suite_verdicts(env, "fixtures") end
  return Orchestration.fixture(env, tmpdir, compiles, verdicts)
end

local function fixture_test(c: Context, work: string, name: string,
    source: string, timeout_ms: integer, extra: {string:string}): integer
  assert(name:match("^[%w-]+$"), "invalid fixture test name")
  assert(source:match("^[%w_]+$"), "invalid fixture test source")
  local project = fixture_project(c, work)
  local diagnostics = work .. "/fixture-test-diagnostics/" .. name
  mkdir(diagnostics); mkdir(diagnostics .. "/tmp")
  local out, err = diagnostics .. "/test.out", diagnostics .. "/test.err"
  -- No --census: a fixture's run holds too few tests for its key parts
  -- to say much, and an unsandboxed one's are keyed by nothing.
  local status = logged(c, "fixture: " .. name,
    { assert(Proc.executable()), "test",
      "fixtures/" .. source .. "_test.tl" }, out, err, timeout_ms, project,
    Orchestration.fixture_run(source, environment(extra), diagnostics .. "/tmp",
      work .. "/fixture-compiles.db"))
  record_suite(c, "fixture " .. name, status, out)
  return status
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
  -- The checked core keeps its debug information but names no path of
  -- the run that built it (build.zig's `debug_dir` and the generated
  -- map's `-g0`). The checked suite's verdicts are keyed by the core's
  -- image, its debug sections left out (build/core_image.tl). A core
  -- that names the tree root (per commit in CI, place-tree.sh) or the
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
  local cache = c.root .. "/o/zig-cache/"
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
    "Store.meta('host'), Store.meta('host_image'))" }, context, 30000)
  if s ~= 0 then return s end
  assert(read(context) == "portable-v1\t" .. target .. "\t" .. digest .. "\n",
    "checked artifact did not execute the checked raw core: " .. read(context))
  -- The suite on the checked core takes three to six minutes. Most of
  -- what it checks is the same on every platform, so the workflow runs
  -- it once, in a job of its own on linux-x86_64's host (ci.yml's
  -- `checked`: phases `boot`, `checked-build` and this one), beside the
  -- legs rather than after one of them; every leg sets
  -- COSMIC_CI_CHECKED_SUITE=skip, and still builds and verifies the
  -- checked core above, which its fixtures use.
  -- TODO: the core's platform-conditional C (__APPLE__, __aarch64__ in
  -- core/syscalls.c, executable.c, ...) is not run under the sanitizer
  -- off linux-x86_64: a leg that skips the suite runs the checked cosmic
  -- only on a chunk (`-e`, above), not on a file in the tree, whose
  -- build (staging it, writing SQLite) is the one real code it would run
  -- there. A checked run of only the tests that enter that C, on the legs
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
  -- The bound is about twice what the suite takes: 271 s whole (248 to
  -- 285 over six main runs of September 2026) for 1948 tests on a 4-core
  -- host, each worker sandboxed, the checked core running each test about
  -- 2.9 times slower than the release core does.
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
    COSMIC_VERDICT_CACHE = Orchestration.suite_verdicts(Env.all(), "checked") })
  table.insert(checked_words, 2, "--census")
  for _, word in ipairs(checked_words) do
    checked_argv[#checked_argv + 1] = word
  end
  s = logged(c, "checked suite", checked_argv,
    diagnostics .. "/checked-test.out", diagnostics .. "/checked-test.err",
    checked_suite_timeout_ms, c.root, checked_environment)
  record_suite(c, "checked", s, diagnostics .. "/checked-test.out")
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
  -- Its key parts said, as the checked suite's are, for its row.
  table.insert(words, 2, "--census")
  local argv: {string} = { executable }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local status = logged(c, name .. " suite", argv, out, err,
    suite_timeout_ms, c.root, values)
  record_suite(c, name, status, out)
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

--- The candidate's cores and boot, on a fresh checkout: the `build`
--- phase without its native suite. It is all the `boot` phase runs, for
--- a job that runs no native suite (ci.yml's `checked`).
local function boot(p: PlatformContext): integer
  local c = p.operation
  local root = p.root
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
    local path = (line:gsub("#.*$", "")):match("^%s*(.-)%s*$")
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

--- The darwin suite ([`darwin_words`]), on the macOS leg alone, on the
--- tree `boot` built, in the native suite's environment, with a row of
--- its own, "darwin", which says the listed modules ran. A phase of its
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
  values.COSMIC_TEST_TIMEOUT = suite_test_timeout_s
  local argv: {string} = { p.root .. "/o/bin/cosmic" }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  mkdir(p.local_diagnostics)
  local out = p.local_diagnostics .. "/darwin-test.out"
  local status = logged(c, "darwin suite", argv, out,
    p.local_diagnostics .. "/darwin-test.err", suite_timeout_ms, c.root, values)
  record_suite(c, "darwin", status, out)
  if status ~= 0 then
    Fs.put(Fs.stderr, "darwin suite: failed (status " .. status .. ")\n")
  end
  return status
end

--- The native suite, on the tree `boot` built: the `build` phase
--- without its boot, which ci.yml's legs run apart so that what comes
--- between (the verdicts of the merge queue's run ahead) waits on
--- nothing the boot does.
local function phase_local_suite(p: PlatformContext): integer
  return suite(p.operation, "local", p.root .. "/o/bin/cosmic", p.local_diagnostics)
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
  write(decoder, read(root .. "/o/portable-fixture/format/format-test-" .. p.target))
  return step(c, "format decoder mode", function(): boolean, string
    return Fs.chmod(decoder, 0x1ed)
  end)
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

--- The format check's command, below: `fix --check .`, or, where
--- COSMIC_CI_FORMAT_CHANGED names a file, one path a line, of what
--- changed since the tree's base on main, which passed the whole tree's
--- check (.github/scripts/changed-paths.sh, on a light run), `fix
--- --check --changed` of those paths, which lays out only them yet makes
--- every check spanning files over the whole tree, and lays out all of
--- it where a path named is part of what checks each file. A file that
--- cannot be read checks the whole tree.
local function format_command(root: string): {string}
  local command = { root .. "/o/bin/cosmic", "fix", "--check" }
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
    COSMIC_FIXTURE_FORMAT = contract .. "/format",
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
    attempt = c.attempt, root = fresh, driver = c.driver, phase = c.phase }
  local s = 0
  -- The suite reruns the local suite's tests under the portable build,
  -- whose artifact carries the cores o/bin/cosmic does (`ProductSetup`);
  -- each leg's launcher, runtime and identity fixtures still run the
  -- portable product's launcher (phase_fixtures). So a gating run runs
  -- it on the two x86-64 legs, a glibc host and a musl one, and the
  -- others set COSMIC_CI_PORTABLE_SUITE=skip; the scheduled run and a
  -- manual one keep it on every leg (ci.yml). A leg that skips it still
  -- checks the artifact unchanged since assemble (attest), and its
  -- portable.db keeps what was restored whole, since the run reached
  -- none of it (cosmic_ci/verdicts.tl).
  if Env.get("COSMIC_CI_PORTABLE_SUITE") == "skip" then
    Fs.put(Fs.stderr, "portable suite: skipped on this leg " ..
      "(COSMIC_CI_PORTABLE_SUITE=skip)\n")
  else
    -- Where the other suites stand on verdicts (`stands`), it stands on
    -- its own ([`suite_verdicts`]), never on the local suite's;
    -- elsewhere it runs every test, as they do.
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
    s = fixture_test(c, work, "self-rebuild-regression", "self_rebuild",
      self_rebuild_test_timeout_ms, {
      COSMIC_FIXTURE_SOURCE = source,
      COSMIC_FIXTURE_RUNTIME = runtime,
      COSMIC_TEST_TIMEOUT = self_rebuild_per_test_timeout_s,
    }); if s ~= 0 then return s end
  end
  -- The fixed-point regression is the slowest fixture on every leg
  -- (about 90 to 180 s: each of its six tests rebuilds the product twice
  -- from a fresh tree, and three compile the tree twice over), and what
  -- it checks, that the compiler compiles itself to itself, is the same
  -- on every platform. So a gating run runs it on one leg, and the
  -- others set COSMIC_CI_FIXED_POINT=skip; the scheduled run keeps it on
  -- every leg (ci.yml).
  if Env.get("COSMIC_CI_FIXED_POINT") == "skip" then
    Fs.put(Fs.stderr, "fixture: fixed-point-regression: skipped on this leg " ..
      "(COSMIC_CI_FIXED_POINT=skip)\n")
  else
    s = fixture_test(c, work, "fixed-point-regression", "fixed_point",
      fixed_point_test_timeout_ms, {
      COSMIC_FIXTURE_SOURCE = source,
      COSMIC_FIXTURE_PRODUCT = product,
      COSMIC_TEST_TIMEOUT = fixed_point_per_test_timeout_s,
    }); if s ~= 0 then return s end
  end
  s = fixture_test(c, work, "self-driven-regression", "self_driven",
    self_driven_test_timeout_ms, {
    COSMIC_FIXTURE_SOURCE = source,
    COSMIC_FIXTURE_PRODUCT = product,
    COSMIC_TEST_TIMEOUT = self_driven_per_test_timeout_s,
  }); if s ~= 0 then return s end
  s = fixture_test(c, work, "runtime-regression", "runtime",
    runtime_test_timeout_ms, {
    COSMIC_FIXTURE_PRODUCT = product,
    COSMIC_FIXTURE_RUNTIME = runtime,
  }); if s ~= 0 then return s end
  s = fixture_test(c, work, "launcher-regression", "launcher",
    launcher_test_timeout_ms, {
    COSMIC_FIXTURE_PRODUCT = product,
    COSMIC_FIXTURE_LAUNCHER = contract .. "/launcher",
    COSMIC_FIXTURE_TARGET = target,
  }); if s ~= 0 then return s end
  s = fixture_test(c, work, "launcher-noexec-regression", "launcher_noexec",
    launcher_noexec_test_timeout_ms, {
    COSMIC_FIXTURE_LAUNCHER = contract .. "/launcher",
    COSMIC_FIXTURE_TARGET = target,
  }); if s ~= 0 then return s end
  s = fixture_test(c, work, "identity-regression", "identity",
    identity_test_timeout_ms, {
    COSMIC_FIXTURE_PRODUCT = product,
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
  elseif phase == "boot" then return boot(p)
  elseif phase == "local-suite" then return phase_local_suite(p)
  elseif phase == "local-boundary" then return phase_local_boundary(p)
  elseif phase == "darwin-suite" then return phase_darwin_suite(p)
  elseif phase == "format" then return format_check(p)
  elseif phase == "checked-build" then return phase_checked_build(p)
  -- Assemble's checked core, verified and (COSMIC_CI_CHECKED_SUITE) its
  -- suite run, alone, on a checked build already there: assemble's, or
  -- `checked-build`'s.
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
  assert(expected and count == expected, "expected " .. Plural.count(expected, "product") .. ", found " .. count)
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
    attempt = ctx.attempt, root = ctx.root, driver = assert(Fs.absolute(assert(a[0]))),
    phase = phase }
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
