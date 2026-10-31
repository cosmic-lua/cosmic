local BuildPaths = require("cosmic_ci.build_paths")
local Capabilities = require("cosmic_ci.capabilities")
local Clock = require("cosmic.clock")
local ContextEnv = require("cosmic_ci.context")
local Env = require("cosmic.env")
local Fixture = require("cosmic_ci.fixture")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local Hash = require("cosmic.hash")
local HostId = require("cosmic_ci.host_id")
local LauncherSetup = require("cosmic_ci.launcher_setup")
local Maps = require("cosmic_ci.maps")
local ProductSetup = require("cosmic_ci.product_setup")
local Archive = require("cosmic.archive")
local ArtifactRow = require("cosmic_ci.artifact_row")
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
  against_a_base: function(env: {string:string}): boolean
  --- What [`harness_moved`] answered: whether build/harness_epoch.tl differs, and why.
  record Moved
    moved: boolean
    why: string
  end
  --- A gating suite's `cosmic test` words and its environment.
  record SuiteRun
    words: {string}
    env: {string:string}
  end
  --- How many lanes of fixtures, high and low, the environment asks for; nil where it asks none.
  record Lanes
    high?: integer
    low?: integer
  end
  harness_moved: function(root: string, base: string): Moved
  stale_rows: function(path: string, features: string): integer?, string
  gather_bound: function(stale: integer): integer
  test_words: function(env: {string:string}): {string}
  shares: function(env: {string:string}): {string:string}
  sandboxed_fixtures: function(): {string:boolean}
  noexec_fixture: function(target: string): boolean
  fixture: function(env: {string:string}, tmpdir: string, compiles: string,
    verdicts?: string): {string:string}
  fixture_run: function(source: string, env: {string:string}, tmpdir: string,
    compiles: string): {string:string}
  fixture_project: function(driver: string, work: string, group?: string): string
  forget_run: function(env: {string:string}): {string:string}
  suite_run: function(extra?: {string:string}): SuiteRun
  suite_verdicts: function(env: {string:string}, name: string): string
  darwin_modules: function(text: string): {string}
  darwin_words: function(words: {string}, modules: {string}): {string}?
  native_ran_every: function(text: string, code: integer): boolean
  replay: function(out: string, err: string, to_out?: integer, to_err?: integer): boolean
  fixture_lanes: function(env: {string:string}, cpus: integer): Lanes
  run_groups: function(high: Orchestration.Group, low: {Orchestration.Group},
    lanes: boolean): integer
end

local function mkdir(path: string) assert(Fs.mkdirs(path)) end

local exists = Predicate.exists
local is_dir = Predicate.is_dir
local function read(path: string): string return (assert(Fs.read(path))) end

--- The file at `path`, "" where there is none.
local function read_or_empty(path: string): string
  if exists(path) then return read(path) end
  return ""
end
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
--- reads something only on macOS is the gap (build/test_key.tl's `prepare`).
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
--- build/harness_epoch.tl from the queue's base, nor does a branch push's
--- that runs the queue's scope (ci.yml's `scope` job, which names the
--- main commit the branch grew from as COSMIC_CI_BASE_SHA, [`against_a_base`]):
--- it is the queue's decision, made on the branch (COSMIC_CI_HARNESS_MOVED,
--- which `environment` sets by [`harness_moved`] where the driver's
--- environment does not). No key holds the harness's code, only the
--- epoch that file records (build/declared_key.tl), so a harness change
--- marked there as one that moves no verdict would otherwise land on
--- verdicts it may have moved. Such a run runs every test, as main's
--- scheduled run does, so the change is gated on a run that stands on
--- nothing. Where the driver cannot tell whether the file moved, it takes
--- it as moved.
---
--- A run that gathers the shares of a suite (COSMIC_CI_GATHER=1, which
--- the checked suite phase gives ci.yml's `checked` job) always stands, in every
--- event and where the change moves the harness: it is the whole suite on
--- the verdicts the shares kept, in a cache that holds nothing of main's
--- (ci.yml merges them into it and only looks main's up), and each share
--- ran its tests, every one of them where it stands on nothing. It is no
--- `--all`, which would run them again, and no `--no-shared`, which would
--- leave the shares' rows unread. What it adds is only what a whole run
--- answers: that some test enters each C function, which the rows carry.
function Orchestration.stands(env: {string:string}): boolean
  if env["COSMIC_CI_GATHER"] == "1" then return true end
  if Orchestration.against_a_base(env) and env["COSMIC_CI_HARNESS_MOVED"] ~= "0" then
    return false
  end
  return (env["COSMIC_CI_REQUIRE_SANDBOX"] == "1" or env["COSMIC_CI_DECLARED_KEYS"] == "1") and
    standing_events[env["COSMIC_CI_EVENT"] or ""] == true
end

--- Whether the run's change is held against a base commit
--- (COSMIC_CI_BASE_SHA): the merge queue's, always, or a branch push's,
--- which ci.yml gives one only where it runs the queue's scope for the
--- change (its `scope` job; `unknown` where it could not name the base,
--- which [`harness_moved`] takes as moved). A push to main, the scheduled
--- and a manual run name none.
function Orchestration.against_a_base(env: {string:string}): boolean
  local event = env["COSMIC_CI_EVENT"]
  return event == "merge_group" or (event == "push" and (env["COSMIC_CI_BASE_SHA"] or "") ~= "")
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
local function git(root: string, words: {string}): string?, string
  local argv = { "/usr/bin/env", "git", "-C", root }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local env = Maps.with(Env.all(), { GIT_TERMINAL_PROMPT = "0" })
  local result, trouble = Child.run(argv, { env = env, stdout = "capture",
    stderr = "capture", timeout_ns = git_timeout_ns })
  if result == nil then return nil, "git " .. assert(words[1]) .. ": " .. trouble end
  if result.timed_out then
    return nil, "git " .. assert(words[1]) .. ": timed out after " .. tostring((git_timeout_ns // Clock.seconds(1))) .. " s"
  end
  if not result.ok then
    return nil, "git " .. assert(words[1]) .. ": exit " .. tostring(result.code) .. ": " ..
      ((result.stderr or ""):gsub("%s+$", ""))
  end
  return result.stdout or "", ""
end

--- The git object `revision:path` names in the checkout at `root`, or
--- nil and why where there is none: no such commit here, or no such
--- file in it.
local function blob(root: string, revision: string, path: string): string?, string
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
function Orchestration.harness_moved(root: string, base: string): Orchestration.Moved
  if root == "" then return { moved = true, why = "no checkout named (GITHUB_WORKSPACE)" } end
  if not base:match("^%x+$") then
    return { moved = true, why = "no merge queue base named (COSMIC_CI_BASE_SHA=" .. base .. ")" }
  end
  local now, now_trouble = blob(root, "HEAD", epoch_file)
  if now == nil then
    return { moved = true, why = "cannot read HEAD's " .. epoch_file .. ": " .. now_trouble }
  end
  local was, was_trouble = blob(root, base, epoch_file)
  if was == nil then
    local _, fetch_trouble = git(root, { "fetch", "--quiet", "--no-tags", "--depth=1",
      "origin", base })
    was, was_trouble = blob(root, base, epoch_file)
    if was == nil then
      return { moved = true, why = "cannot read " .. base .. "'s " .. epoch_file .. ": " .. was_trouble ..
          (if fetch_trouble ~= "" then ("; " .. fetch_trouble) else "" end) }
    end
  end
  if was ~= now then
    return { moved = true, why = epoch_file .. " differs from " .. base .. "'s" }
  end
  return { moved = false, why = epoch_file .. " is " .. base .. "'s" }
end

--- What [`harness_moved`] answered of each checkout and base, asked once
--- a driver run: every operation's environment asks it.
local moved_by_base: mut {string:boolean} = {}

--- COSMIC_CI_HARNESS_MOVED for `env`, a merge-queue run's, where it
--- does not say already: "1" where its change moves
--- build/harness_epoch.tl ([`harness_moved`], of the checkout
--- GITHUB_WORKSPACE names against COSMIC_CI_BASE_SHA), else "0".
local function decide_harness(env: {string:string}): {string:string}
  if not Orchestration.against_a_base(env) or env["COSMIC_CI_HARNESS_MOVED"] ~= nil then
    return env
  end
  local root, base = env["GITHUB_WORKSPACE"] or "", env["COSMIC_CI_BASE_SHA"] or ""
  local asked = root .. "\0" .. base
  if moved_by_base[asked] == nil then
    local judged = Orchestration.harness_moved(root, base)
    local moved, why = judged.moved, judged.why
    moved_by_base[asked] = moved
    local gathering = env["COSMIC_CI_GATHER"] == "1"
    local said = "suites stand on verdicts: "
    if moved and gathering then
      said = "the gathering run stands on the shares' verdicts, where every test ran (--all): "
    elseif moved then
      said = "every suite runs every test (--all): "
    end
    local where = "branch push: "
    if env["COSMIC_CI_EVENT"] == "merge_group" then where = "merge queue: " end
    local _, _ = Fs.put(Fs.stderr, where .. said .. why .. "\n")
  end
  local flag = "0"
  if moved_by_base[asked] == true then flag = "1" end
  return Maps.with(env, { COSMIC_CI_HARNESS_MOVED = flag })
end

--- Sets `env` for a suite that stands on nothing another run reached
--- (COSMIC_TEST_NO_SHARED=1) where it does not stand on verdicts
--- (`stands`).
function Orchestration.shares(env: {string:string}): {string:string}
  if not Orchestration.stands(env) then return Maps.with(env, { COSMIC_TEST_NO_SHARED = "1" }) end
  return env
end

--- A suite's `cosmic test` words in `env`: `--all` where it stands on
--- nothing (`stands`), and `--bail` in a merge-queue run, which has
--- failed once any test fails and gains nothing from the rest of the
--- suite. Every other event runs every test and reports them all. The
--- suites run the tree's own tool, which parses the flag, never the
--- pinned release the driver itself runs on.
function Orchestration.test_words(env: {string:string}): {string}
  local words: mut {string} = { "test" }
  if not Orchestration.stands(env) then words[#words + 1] = "--all" end
  if env["COSMIC_CI_EVENT"] == "merge_group" then words[#words + 1] = "--bail" end
  return words
end

--- Sets `env`, a suite's, to the requirements the leg it runs on
--- promises (ci/cosmic_ci/capabilities.json): COSMIC_TEST_PROMISES, their list, and
--- COSMIC_TEST_LEG, the leg's name, which a held `cosmic test` fails a
--- module for lacking. The leg is COSMIC_WORKER's; a worker that is no
--- leg's (the provenance join, fuzz.yml) promises nothing, and a
--- variable the environment already sets is the caller's.
function Orchestration.promise(env: {string:string}): {string:string}
  local worker = env["COSMIC_WORKER"] or ""
  local promised = Capabilities.legs()[worker]
  if promised == nil or env["COSMIC_TEST_PROMISES"] ~= nil then return env end
  return Maps.with(env, { COSMIC_TEST_PROMISES = table.concat(promised, ","), COSMIC_TEST_LEG = worker })
end

--- The environment every operation runs in: the driver's own, with
--- FUZZ_ITERS=0, so a suite checks each fuzz property's corpus of kept
--- failures but draws no inputs of its own. Drawing is fuzz.yml's, each
--- night with a seed of its own: a check that gates a change answers the
--- same on every run, and one that searches runs where a find blocks
--- nobody's merge. [`suite_run`] then removes what names the run from a
--- gating suite's copy ([`forget_run`]).
local function environment(extra?: {string:string}): {string:string}
  local all = Maps.with(Maps.with(Env.all(), { FUZZ_ITERS = "0" }), extra or {})
  -- What follows is decided on the leg's environment, `extra`
  -- included, which may name the leg itself ([`suite_run`], a test's).
  -- A merge-queue run that moves the harness's epoch file stands on
  -- nothing (`stands`).
  all = decide_harness(all)
  -- Where it does not stand on verdicts (`stands`), a suite stands on
  -- none another run reached, only on what it runs itself.
  all = Orchestration.shares(all)
  -- Where the leg is given what spawn's sandbox needs, every suite runs
  -- each worker sandboxed (build/test_sandbox.tl), as `cosmic test`
  -- does by default wherever it can, and fails where it cannot rather
  -- than run them unsandboxed. Every build.confine `confine` of a test
  -- is a `must_confine` there (COSMIC_SANDBOX=must, build/confine.tl),
  -- so a process a test confines runs confined or fails the test, and
  -- the sandbox tests of core/syscalls_test.tl cannot pass unchecked.
  -- The mode also runs every test no key can hold, as --all does; a
  -- sandboxed run has none.
  if all["COSMIC_CI_REQUIRE_SANDBOX"] == "1" then
    all = Maps.with(all, { COSMIC_TEST_SANDBOX = "1", COSMIC_SANDBOX = "must" })
  end
  return Orchestration.promise(all)
end

--- Whether `name` says which run, runner or job this is, or is a switch
--- the driver alone reads ([`cosmic_ci.run_names`], run_names.json).
local function names_the_run(name: string): boolean
  local listed = RunNames.names()
  for _, kept in ipairs(listed.kept) do
    if name == kept then return false end
  end
  for _, exact in ipairs(listed.exact) do
    if name == exact then return true end
  end
  for _, prefix in ipairs(listed.prefixes) do
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
function Orchestration.forget_run(env: {string:string}): {string:string}
  local names: mut {string} = {}
  for name in pairs(env) do
    if names_the_run(name) then names[#names + 1] = name end
  end
  return Maps.without(env, names)
end

--- A gating suite's `cosmic test` words and environment, `extra` added
--- to [`environment()`]'s: `--all` and nothing shared where it stands on
--- no verdict (`stands`, `shares`), decided on the driver's own
--- environment, which then forgets the run ([`forget_run`]).
function Orchestration.suite_run(extra?: {string:string}): Orchestration.SuiteRun
  local values = environment(extra)
  local words = Orchestration.test_words(values)
  return { words = words, env = Orchestration.forget_run(values) }
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
--- artifact (build/test_key.tl's `seals`); its key holds the core and the
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
  local shared = env["COSMIC_VERDICT_CACHE"] or ""
  if shared:sub(1, 1) ~= "/" then return "0" end
  if name == "portable" then return shared end
  return assert(shared:match("^(.*)/[^/]*$")) .. "/" .. name .. ".db"
end

--- `words`, a suite's `cosmic test` line, with `--census` after `test`, for the key parts its row says.
local function with_census(words: {string}, shard?: string): {string}
  local out: mut {string} = {}
  for at, word in ipairs(words) do
    out[#out + 1] = word
    if at == 1 then out[#out + 1] = "--census" end
  end
  if shard then
    out[#out + 1] = "--shard"
    out[#out + 1] = shard
  end
  return out
end

local record Context
  db: string
  worker: string
  run: string
  attempt: string
  root: string
  driver: string
  --- The platform phase running (`platform`'s PHASE), which a suite's
  --- row names; nil outside a platform phase.
  phase?: string
end

--- The environment variable `name`, or nil when it is unset or empty.
local function named(name: string): string?
  local value = Env.get(name)
  if value == "" then return nil end
  return value
end

local function request_for(c: Context, command: {string}, timeout: integer,
                           cwd?: string, env?: {string:string}, output?: string,
                           error_output?: string): Runner.Context, Runner.Request
  local runner: Runner.Context = { database = c.db, worker = c.worker,
    run = c.run, attempt = c.attempt, candidate = c.root }
  local child_environment: mut {string:string} = {}
  for name, value in pairs(env or environment()) do child_environment[name] = value end
  -- bin/zig shares one project cache among checkouts unless told otherwise
  -- (build/zig.tl). A candidate uses the zig-cache under
  -- COSMIC_ZIG_CACHE_SEED where CI restored it, else keeps its own in
  -- its build directory, which the build phase seeds. zig keys what it
  -- compiles by its own cache's path too, and CI puts the checkout at a
  -- path of the commit's own (ci/cosmic_ci/place_tree.tl), whose build
  -- directory is new with it, so a cache there would never be reused:
  -- CI saves the seed's as it stands.
  if (child_environment["COSMIC_ZIG_CACHE"] or "") == "" then
    local seed = named("COSMIC_ZIG_CACHE_SEED")
    child_environment["COSMIC_ZIG_CACHE"] = if seed then seed .. "/zig-cache" else BuildPaths.directory(c.root, child_environment) .. "/zig-cache" end
  end
  -- The driver boots the candidate itself; a tool that finds its core
  -- stale is a fault to report, not one to boot past (build/reboot.tl).
  if not child_environment["COSMIC_AUTO_BOOT"] then
    child_environment["COSMIC_AUTO_BOOT"] = "0"
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
    local out_ok, _ = Fs.put(to_out or Fs.stdout, read(out))
    replay_ok = out_ok
    if replay_ok then
      local err_ok, _ = Fs.put(to_err or Fs.stderr, read(err))
      replay_ok = err_ok
    end
  end
  if not replay_ok then
    local _, _ = Fs.put(Fs.stderr, "could not replay retained output\n")
  end
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
    local said = read_or_empty(out)
    local reading = SuiteOutput.read(said, code)
    local figures, status = reading.figures, reading.status
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
    local _, _ = Fs.put(Fs.stderr, name .. " suite: row not recorded: " .. tostring(trouble) .. "\n")
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
-- The sandboxed fixtures ([`sandboxed_fixtures`]) take 6 to 28 s where
-- they run, under ci/run-local on a loaded four-core host (launcher 6 s,
-- runtime 10 s, identity 28 s), and 4 to 6 s where their verdicts stand;
-- each bound is several times that.
local launcher_test_timeout_ns <const> = Clock.seconds(60)
local launcher_noexec_test_timeout_ns <const> = Clock.seconds(60)
local self_rebuild_test_timeout_ns <const> = Clock.seconds(600)
-- A self-rebuild test rebuilds the tool: the docs verb's from a cold
-- compile of the whole tree, 140 to 180 s on four cores (the tree has
-- doubled since this was first measured at 50 to 90 s), past the
-- runner's default 30 s per test; the rest from the leg's compiles
-- ([`seed_compiles`]), in seconds. The bound is above the case's own
-- (`rebuild_timeout_ns` in fixtures/self_rebuild_test.tl, 270 s).
local self_rebuild_per_test_timeout_s <const> = "300"
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
--- for what it takes. Sized from the merge queue's runs of 17 to 19 October 2026: the 7800 tests took 800 to 1114 s in
--- 14 of its 36 completed runs and over 1200 s in one, a change that adds 45 tests (15 s of test time in 2900 s
--- locally, where the suite took 1714 s on this branch and 1873 s on main, on four cores). It bounds the suite run whole in
--- one job, which no ci.yml job does now (`checked_shard_timeout_ns`, `checked_gather_timeout_ns`) and ci/run-local's
--- assemble does.
local checked_suite_timeout_ns <const> = Clock.seconds(1500)
--- One share of the checked suite, of the N ci.yml's `checked-shard` job
--- runs (COSMIC_CI_CHECKED_SHARD, `I/N`), each on a runner of its own.
--- build/test.tl's `dealt` deals the tests in turn, so a share holds a Nth
--- of them and, the slow ones being spread across the modules, about a
--- Nth of the time. The whole suite takes 1096 s where no verdict stands
--- and 1504 s in the slowest of the merge queue's runs of 23 October 2026
--- (past `checked_suite_timeout_ns`), which a share of four takes in 274
--- and 376 s. The bound is 600 s, 1.6 times the slowest share seen, where
--- the whole suite's was no more than the slowest run itself, and 2.2
--- times a share of the run where nothing stood. It is the share's own,
--- not the whole suite's divided by four: the share restores its verdicts,
--- builds and checks the checked core as the whole suite's job did, and
--- gains nothing from another share's time.
local checked_shard_timeout_ns <const> = Clock.seconds(600)
--- The checked suite's gathering run (COSMIC_CI_CHECKED_SUITE=gather,
--- ci.yml's `checked` job): the whole suite on the verdicts the shares
--- kept, where every test stands, so that only what a whole run answers is
--- left to check (that some test enters each C function). A test that
--- stands starts no worker: the time is the harness's, reading the rows
--- and keying the tests, and the few tests that keep no verdict (187 of
--- 8200 in a local run, 34 s in all on the release core where all the rest
--- stood), some three times that on the checked core.
---
--- That holds only for the rows whose key this host reaches. A share that
--- ran on a host of other host features (build/declared_key.tl's
--- `host_features`: the processor features a core dispatches on, and the
--- kernel's release and version, which a sandboxed verdict can depend on,
--- so they are rightly in the key) keeps rows this run cannot stand on,
--- and the run runs those tests again, one after another. Run 40495570639
--- of cosmic-lua/cosmic#3263 read 5751 rows under one host's features and
--- 1914 under another's, and ran 2046 tests in the 300 s this bound was,
--- at some 330 a minute, and timed out; the run that moved the harness
--- epoch and found 7665 of 7801 rows standing took 167 s in all.
---
--- So the bound is the base time, 300 s, that run's share of the harness'
--- time with room, and a time for each row [`stale_rows`] counts under
--- other host features: `gather_row_ns`, 0.3 s, some 1.7 times the 0.18 s a
--- test took there, and capped by `checked_gather_cap_ns`.
local checked_gather_timeout_ns <const> = Clock.seconds(300)
--- What a test the gathering run runs again may take of its bound, on
--- average: 1.7 times the 0.18 s of run 40495570639's pace.
local gather_row_ns <const> = Clock.ms(300)
--- The most the gathering run is given, whatever it must run again: 13
--- minutes, which leaves ci.yml's `checked` job, whose 20 minutes
--- build/workflows_test.tl holds it to, the five or so of its boot,
--- checked build and merge before the step and its steps after (a whole
--- suite run, which takes 1096 s where no verdict stands, fits in no
--- gather). A run that needs more ends here, with the line
--- [`gather_budget`] said, not at the job's timeout without one.
local checked_gather_cap_ns <const> = Clock.seconds(780)

--- How many rows the verdict cache at `path` holds that a host of
--- `features` ([`HostId.features`]) cannot stand on: those stamped with
--- other key parts, or none (build/shared_verdicts.tl's `parts`, whose
--- first is "host features <digest>"), but for those that name the
--- identity of their host and its rest but for the features ("host
--- identity", "host rest"), which the gathering run looks up under their
--- own host's key (build/test_key.tl's `lookup`). Nil and why where `path` is no
--- cache of this format, which a gathering run then bounds as one with
--- nothing to run again.
-- TODO: count only the rows whose rest is this host's ("host rest"), once
-- the driver can name this host's rest: build/declared_key.tl's
-- `host_split` is the tree's, which the pinned release the driver runs on
-- cannot call, and ci/cosmic_ci/host_id.tl names only the features. Today
-- a row of another rest (another image, user or sandbox) is counted as
-- one to look up, which no key of this host reaches, so those tests run
-- again beyond the time given.
function Orchestration.stale_rows(path: string, features: string): integer?, string
  if features:match("^%x+$") == nil then
    return nil, "host features " .. features .. " are no digest"
  end
  local db, open_trouble = Sqlite.open(path)
  if db == nil then return nil, path .. ": " .. open_trouble end
  local rows, trouble = Sqlite.text_rows(db, "SELECT COUNT(*) FROM declared_v1 " ..
      "WHERE parts NOT LIKE 'host features " .. features .. ",%' AND NOT " ..
      "(parts LIKE '%, host identity %' AND parts LIKE '%, host rest %')")
  local _, _ = db:close()
  if rows == nil then return nil, path .. ": " .. trouble end
  local first = rows[1]
  if first == nil then return nil, path .. ": no count" end
  return math.tointeger(tonumber(first:text(1)) or -1), ""
end

--- The time the gathering run is given when `stale` rows of the shares'
--- verdicts are under other host features: the base, and a
--- `gather_row_ns` for each, up to `checked_gather_cap_ns`.
function Orchestration.gather_bound(stale: integer): integer
  local bound = checked_gather_timeout_ns + stale * gather_row_ns
  if bound > checked_gather_cap_ns then return checked_gather_cap_ns end
  return bound
end
-- Each test's bound on the checked core: the release suites' (below)
-- scaled by how much slower the checked core runs a test, about 2.9
-- times over the suite and 5.5 times for a compile-heavy module
-- (build/shape_specs_test.tl, about 3 s a test on the release core, past
-- the runner's default 30 s on CI's checked job when no verdict stood),
-- and doubled for a loaded runner.
local checked_suite_test_timeout_s <const> = "120"

--- One share of the whole suite on a checked run ([`phase_checked_narrowing`]),
--- of the N ci.yml's `checked-narrowing` job runs (COSMIC_CI_NARROWING_SHARD,
--- `I/N`, two), each on a runner of its own; a test 120 s at most, as on the
--- checked core. The whole run took 510 s on four processors locally and 726
--- to 861 s on CI's runner (the merge queue's runs of 23 October 2026), which
--- a share of two takes in some half, 363 to 431 s, build/test.tl's `dealt`
--- spreading the slow tests as it does the checked suite's. The bound is 900
--- s, 2.1 times the slowest share expected, where the whole run's 1800 s was
--- 2.1 times its slowest: the share's own, not the whole's divided by two, as
--- it restores nothing a neighbour's time could spare.
-- TODO: lower this bound once CI's own runs of a share show its elapsed time.
local checked_narrowing_timeout_ns <const> = Clock.seconds(900)
local checked_narrowing_test_timeout_s <const> = "120"

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

-- A whole `cosmic test` run of every test, sandboxed (about 4750 tests
-- in October 2026), is what a change to core/ runs, as no verdict stands
-- for it, and what a merge-queue run that moves build/harness_epoch.tl
-- runs (`stands`): 12 of the 22 queue runs on October 9. Its time follows
-- the runner more than the tree. On alpine-x86_64 each whole suite took
-- 192 to 309 s on runners where the driver's own tests took 73 to 120 s;
-- on one where they took 135 s (37991854997), the local suite took 385 s
-- and the portable suite, the step after it, ran past 450 s, the bound
-- then. The bound is 1.6 times that, the slowest run seen, as #2834 sized
-- it: were both of a leg's suites to take it whole, the leg would end in
-- about 36 of the job's 45 minutes. Each test gets far less than the
-- whole run, so a test that hangs is ended and named by the runner, not
-- hidden under a cancelled run.
-- TODO: the suite's growth, and a slow runner, against this bound go
-- unseen until a run meets it: warn from `suite` when a run uses over 75%
-- of the bound, or run the whole suite on a schedule and report its
-- elapsed time against it.
local suite_timeout_ns <const> = Clock.seconds(720)
local suite_test_timeout_s <const> = "10"

--- Copies the files of `source` (modules, and where `data` the JSON
--- files beside them that the modules read) to `destination`.
local function copy_flat_dir(source: string, destination: string, data: boolean)
  local names: mut {string} = {}
  for _, name in ipairs((assert(Fs.list(source)))) do
    assert((name:match("%.tl$") ~= nil or (data and name:match("%.json$") ~= nil)) and
        assert(Fs.stat(source .. "/" .. name)).kind == "file",
      "invalid fixture source entry: " .. name)
    names[#names + 1] = name
  end
  mkdir(destination)
  for _, name in ipairs(names) do
    write(destination .. "/" .. name, read(source .. "/" .. name))
  end
end

--- The fixture project beneath `work`, made afresh from the namespace of
--- `driver` (cosmic_ci/driver.tl) and the fixtures beside it: the shared one, or
--- where `group` is given (a fixture's source name) the group's own, so
--- groups running at once never remove one another's. Its build
--- directory goes with it ([`BuildPaths.driven`]): that is outside the
--- project, named by its path, so the fixture before at the same path
--- would otherwise leave its build and what [`place`] put there.
function Orchestration.fixture_project(driver: string, work: string, group?: string): string
  local project = work .. "/fixture-project" .. (if group then "-" .. group else "" end)
  local driver_namespace = Fs.dirname(driver)
  local fixtures_source = Fs.dirname(driver_namespace) .. "/fixtures"
  assert(Fs.remove_tree(project))
  copy_flat_dir(driver_namespace, project .. "/cosmic_ci", true)
  copy_flat_dir(fixtures_source, project .. "/fixtures", false)
  assert(Fs.remove_tree(BuildPaths.driven(project)))
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
local SANDBOXED_FIXTURES <const>: {string:boolean} = {
  product = true, runtime = true, launcher = true, launcher_noexec = true, identity = true, performance = true,
}

function Orchestration.sandboxed_fixtures(): {string:boolean}
  return SANDBOXED_FIXTURES
end

--- Only the Linux legs can supply the launcher's private noexec grant.
--- Omission elsewhere is no passing noexec verdict.
function Orchestration.noexec_fixture(target: string): boolean
  return target == "x86_64-linux-musl" or target == "aarch64-linux-musl"
end

--- `env`, an operation's environment, made a fixture's `cosmic test`'s:
--- its temporary files under `tmpdir`.
---
--- Given `verdicts`, a fixture of [`sandboxed_fixtures`]: its workers run
--- as the leg's suites' do -- sandboxed where the leg requires it
--- (COSMIC_CI_REQUIRE_SANDBOX, `environment`), keyed by what they declare
--- where it keys by declaration (COSMIC_CI_DECLARED_KEYS) -- and it
--- stands on and keeps the verdicts of the file `verdicts` names,
--- `fixtures.db` beside the leg's `verdicts.db` ([`suite_verdicts`]),
--- which ci.yml restores and saves with them, and stands on none another
--- run reached where the leg's suites do not (`stands`). Its project is
--- made afresh each run ([`Orchestration.fixture_project`]), so what stands is only what
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
--- event. Nor can a verdict of its own stand: its project, and its
--- build directory, is made afresh for each run, and it names the file it
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
  local made = Maps.with(env, { TMPDIR = tmpdir, COSMIC_BUILD_CACHE = compiles })
  if verdicts ~= nil then
    return Orchestration.shares(Maps.with(made, { COSMIC_VERDICT_CACHE = verdicts }))
  end
  -- Nor is it keyed by what it declares, on a leg whose suites are
  -- (COSMIC_CI_DECLARED_KEYS), by the pinned driver: it shares no verdict
  -- for a key to name. A release that keys every unsandboxed run by
  -- declaration keys it so anyway, and it shares nothing all the same
  -- (COSMIC_VERDICT_CACHE=0); it names each variable it reads.
  return Maps.with(made, { COSMIC_TEST_SANDBOX = "0", COSMIC_VERDICT_CACHE = "0", COSMIC_TEST_NO_SHARED = "1" })
end

--- The environment the fixture ci/fixtures/<source>_test.tl runs in,
--- made of `env`, the operation's (`environment`, its COSMIC_FIXTURE_*
--- among it), by `fixture`: one of [`sandboxed_fixtures`] keeps its
--- verdicts in `fixtures.db` beside the file COSMIC_VERDICT_CACHE of
--- `env` names ([`suite_verdicts`]), and must be given the product its
--- verdicts are keyed by what it declares of what [`fixture_test`] placed; any other shares none.
function Orchestration.fixture_run(source: string, env: {string:string}, tmpdir: string,
                                   compiles: string): {string:string}
  local sandboxed = SANDBOXED_FIXTURES[source] == true
  local verdicts: string? = nil
  if sandboxed then verdicts = Orchestration.suite_verdicts(env, "fixtures") end
  return Orchestration.fixture(env, tmpdir, compiles, verdicts)
end

--- What a sandboxed fixture reads of a setup's output, `from` (the
--- product, the runtime setup's directory, the launcher contract's, the
--- format decoders', the performance inputs), placed at `kind` under
--- `fixtures` of the build directory of the project it runs in: the fixture declares each path
--- it reads there with [`Test.policy`], a grant, so its
--- key holds what each holds, not where the leg keeps it. Only `only`, the
--- names beneath `from` it reads, are copied where it is given: a fixture
--- that reads the product's `prefix` alone is not given the product's
--- `cosmic` and `cosmic.db` to copy.
local record Placement
  kind: string
  from: string
  only?: {string}
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
    local only = placement.only
    if only == nil then
      assert(Fs.copy_tree(placement.from, where))
    else
      for _, name in ipairs(only) do
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
  placements?: {Placement}
  --- Work done in this process just before the fixture starts.
  setup?: function()
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

--- What a fixture group has prepared, once it has started.
local record FixtureHeld
  mut prepared?: Prepared
end

--- Makes the fixture `spec`'s project (a group's own where `group` is
--- given, [`Orchestration.fixture_project`]), places its inputs and its diagnostics
--- directory, and says what to run: `jobs` workers where given, else the
--- runner's default of one per processor.
local function prepare_fixture(c: Context, work: string, spec: FixtureSpec,
                               group?: string, jobs?: integer): Prepared
  local name, source = spec.name, spec.source
  assert(name:match("^[%w-]+$"), "invalid fixture test name")
  assert(source:match("^[%w_]+$"), "invalid fixture test source")
  local setup = spec.setup
  if setup then setup() end
  local project = Orchestration.fixture_project(c.driver, work, group)
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
  -- The preparation, once the group has started.
  local held: FixtureHeld = {}
  return {
    name = spec.name,
    run = function(): integer return fixture_run_spec(c, work, spec) end,
    start = function(): Runner.Running
      local made = prepare_fixture(c, work, spec, spec.source, jobs)
      held.prepared = made
      local runner, request = request_for(c, made.command, spec.timeout_ns,
        made.project, made.env, made.out, made.err)
      return Runner.spawn(runner, "fixture: " .. spec.name, request)
    end,
    finish = function(outcome: Runner.Outcome): integer
      local made = assert(held.prepared, "fixture group finished before it started")
      local replay_ok = replay(made.out, made.err)
      if outcome.code == 0 then
        assert(replay_ok, "could not replay retained output")
      end
      record_suite(c, "fixture " .. spec.name, outcome.code, made.out)
      return outcome.code
    end,
    abandon = function(_: Runner.Outcome)
      local begun = held.prepared
      if begun ~= nil then replay(begun.out, begun.err) end
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

--- The gathering run's bound ([`Orchestration.gather_bound`]) over the
--- cache at `path` merged from the shares, with a line on standard error
--- when rows of it stand on another host's features: that those tests run
--- again here, how many, and how long the run is given, so a step that
--- ends at its bound is read for what it was given.
local function gather_budget(path: string): integer
  local features = HostId.features(HostId.live(Env.all()))
  local stale, trouble = Orchestration.stale_rows(path, features)
  if stale == nil then
    local _, _ = Fs.put(Fs.stderr, "checked suite: gathering bound: no count of the shares' rows under " ..
        "other host features (" .. trouble .. "); the base bound\n")
    return Orchestration.gather_bound(0)
  end
  local bound = Orchestration.gather_bound(stale)
  if stale > 0 then
    local capped = ""
    if bound == checked_gather_cap_ns then capped = ", the most it is ever given" end
    local _, _ = Fs.put(Fs.stderr, "checked suite: " .. Plural.count(stale, "row") ..
        " of the shares' verdicts are under host features other than this host's (" .. features ..
        "): their tests run again here, one after another, so the gathering run is given " ..
        tostring(bound // Clock.seconds(1)) .. " s" .. capped .. "\n")
  end
  return bound
end

--- The checked core, verified on every leg -- its manifest entry in the
--- checked artifact, read by `decoder` (the contract's
--- format-test-<target>), its range, and that the artifact runs it --
--- and its whole suite run where COSMIC_CI_CHECKED_SUITE is not `skip`.
local function checked_suite(c: Context, target: string, work: string,
                             decoder: string): integer
  local sanitized = BuildPaths.directory(c.root) .. "/sanitized"
  local targets_path = sanitized .. "/targets.tsv"
  local target_id: string? = nil
  local checked_target: string? = nil
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
  -- checkout's own zig cache (run-local's, in its build directory, whose vendored
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
  local expected = tostring(offset) .. "\t" .. tostring(length) .. "\t" .. digest .. "\n"
  -- That the checked artifact runs the checked core: its runtime
  -- context as a chunk run with no tree around it (`cosmic -e`) sees it,
  -- which builds and writes nothing.
  local context = work .. "/checked-context.txt"
  s = capture_small(c, "checked runtime context", { cosmic, "-e",
    "local Store = require('cosmic.store') print(Store.meta('runtime_context'), " ..
      "Store.meta('host'), Store.meta('host_image'))" }, context, Clock.seconds(30))
  if s ~= 0 then return s end
  assert(read(context) == "portable-v1\t" .. target .. "\t" .. digest .. "\n",
    "checked artifact did not execute the checked raw core: " .. read(context))
  -- The suite on the checked core takes twenty minutes where nothing
  -- stands. Most of what it checks is the same on every platform, so the
  -- workflow runs it once, on linux-x86_64's host, beside the legs
  -- rather than after one of them, and in shares (ci.yml's
  -- `checked-shard`, each a share of the tests,
  -- COSMIC_CI_CHECKED_SHARD=I/N: phases `boot`, `checked-build` and this
  -- one) that a job gathers (`checked`, COSMIC_CI_CHECKED_SUITE=gather)
  -- on the verdicts the shares kept: the whole suite, every test
  -- standing. Every leg sets
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
    local _, _ = Fs.put(Fs.stderr, "checked suite: skipped on this leg " ..
        "(COSMIC_CI_CHECKED_SUITE=skip)\n")
    -- Such a leg keeps none of the suite's verdicts either, which the job
    -- that runs it keeps in a cache entry of its own. A file left in the
    -- leg's cache, none of whose rows a run reaches, would ride along
    -- whole in every save (cosmic_ci/verdicts.tl).
    local stale = Orchestration.suite_verdicts(Env.all(), "checked")
    if stale ~= "0" and exists(stale) then
      local removed, trouble = Fs.remove(stale)
      local _, _ = Fs.put(Fs.stderr, if removed then ("checked suite: removed this leg's " .. stale .. "\n") else
        ("checked suite: could not remove " .. stale .. ": " .. tostring(trouble) .. "\n") end)
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
  -- The bound is a little over a third above what the suite takes when
  -- no verdict stands: 271 s whole (248 to 285 over six main runs of
  -- September 2026) for 1948 tests on a 4-core host, each worker
  -- sandboxed, the checked core running each test about 2.9 times slower
  -- than the release core does; 3709 tests took 395 s locally on four
  -- cores in October 2026, and more than 600 s on CI's, in the merge
  -- queue; 7800 tests took 800 to 1114 s there, and 1700 to 1900 s on
  -- four cores here (see `checked_suite_timeout_ns`).
  -- Where its key holds, it stands on the last run's verdicts as the
  -- local suite does: a commit that moves neither the core nor the
  -- runner keys the checked core by the same digest, since its image
  -- names no path of the run (asserted above), and its debug sections,
  -- where musl's units still name one, are no part of the key
  -- (build/core_image.tl). It keeps its verdicts in checked.db
  -- ([`suite_verdicts`]), and says which key parts a run that stands on
  -- none reached (`--census`, build/test.tl).
  -- --all where it stands on no verdict (`stands`): CI answers for
  -- every test then, whatever its build directory holds.
  local checked_argv: mut {string} = { cosmic }
  local gathering = Env.get("COSMIC_CI_CHECKED_SUITE") == "gather"
  local share = named("COSMIC_CI_CHECKED_SHARD")
  local checked_run = Orchestration.suite_run({
    COSMIC_VERDICT_CACHE = Orchestration.suite_verdicts(Env.all(), "checked"),
    COSMIC_TEST_TIMEOUT = checked_suite_test_timeout_s,
    COSMIC_CI_GATHER = if gathering then "1" else "" end,
    -- The gathering run's tool also looks a test up under the key of
    -- a host of other features that kept its row (build/test_key.tl's
    -- `lookup`), the shares' alone being what its cache holds.
    COSMIC_TEST_FOREIGN_FEATURES = if gathering then "1" else "" end })
  local checked_environment = checked_run.env
  local checked_words = with_census(checked_run.words)
  local shard_words: {string} = if share ~= nil then { "--shard", share } else {} end
  for _, words in ipairs({ checked_words, shard_words }) do
    for _, word in ipairs(words) do
      checked_argv[#checked_argv + 1] = word
    end
  end
  -- One share of the tests, where ci.yml's `checked-shard` job runs
  -- the suite in several: a share checks no C function, which only a
  -- whole run answers, and `gather` does.
  local bound = checked_suite_timeout_ns
  if share ~= nil then
    bound = checked_shard_timeout_ns
  elseif gathering then
    bound = gather_budget(Orchestration.suite_verdicts(Env.all(), "checked"))
  end
  s = logged(c, "checked suite", checked_argv,
    diagnostics .. "/checked-test.out", diagnostics .. "/checked-test.err",
    bound, c.root, checked_environment)
  record_suite(c, "checked", s, diagnostics .. "/checked-test.out")
  write(diagnostics .. "/checked-test.status", tostring(s) .. "\n")
  -- The suite's per-test times and verdicts (its `runs` rows), which
  -- the workflow uploads with the diagnostics when the leg fails: what
  -- a timeout here leaves to read, since the suite's output names no
  -- times, and what says which tests the checked core runs slowest.
  -- With its write-ahead log, which holds what a run committed and has
  -- not yet copied into the file.
  for _, name in ipairs({ "build.db", "build.db-wal" }) do
    if exists(BuildPaths.directory(c.root) .. "/" .. name) then
      write(diagnostics .. "/" .. name, read(BuildPaths.directory(c.root) .. "/" .. name))
    end
  end
  return s
end

--- The status of a snapshot, kept where the function that takes it under `pcall` can set it.
local record Snapped
  mut status: integer
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
  -- The file, and beside it what SQLite reads with it: a rollback
  -- journal, or the write-ahead log the working database is kept in
  -- (build/work.tl), which holds the commits not yet copied into the file.
  local sidecars <const> = { "build.db-journal", "build.db-wal" }
  write(out .. "/build.db", read(BuildPaths.directory(c.root) .. "/build.db"))
  for _, name in ipairs(sidecars) do
    if exists(BuildPaths.directory(c.root) .. "/" .. name) then
      write(out .. "/" .. name, read(BuildPaths.directory(c.root) .. "/" .. name))
    end
  end
  local hashes = hash(out .. "/build.db") .. "  build.db\n"
  for _, name in ipairs(sidecars) do
    if exists(out .. "/" .. name) then
      hashes = hashes .. hash(out .. "/" .. name) .. "  " .. name .. "\n"
    end
  end
  write(out .. "/hashes.sha256", hashes)
  local temporary_root = Env.get_or("TMPDIR", "/tmp")
  State.external_path(temporary_root .. "/probe", c.root)
  local inspect = assert(Fs.mkdtemp("cosmic-work-db-integrity-"))
  local integrity: Snapped = { status = 1 }
  local called, answer = pcall(function()
    write(inspect .. "/build.db", read(out .. "/build.db"))
    for _, name in ipairs(sidecars) do
      if exists(out .. "/" .. name) then
        write(inspect .. "/" .. name, read(out .. "/" .. name))
      end
    end
    write(inspect .. "/work_db_integrity.tl",
      read(c.root .. "/ci/testdata/portable/work_db_integrity.tl"))
    integrity.status = logged(c, label .. " integrity",
      { cosmic, "work_db_integrity.tl", "--recover-copy", "build.db" },
      out .. "/integrity.out", out .. "/integrity.err", Clock.seconds(30), inspect)
  end)
  local removed, remove_trouble = Fs.remove_tree(inspect)
  assert(removed and not exists(inspect),
    "could not remove disposable integrity directory: " ..
      tostring(remove_trouble))
  if not called then error(answer) end
  return integrity.status
end

--- One suite of `c`'s candidate, run by `executable`, `env` added to
--- its environment.
local function suite(c: Context, name: string, executable: string,
                     diagnostics: string, env?: {string:string}, shard?: string): integer
  mkdir(diagnostics)
  local out = diagnostics .. "/" .. name .. "-test.out"
  local err = diagnostics .. "/" .. name .. "-test.err"
  local run = Orchestration.suite_run(env)
  local values = Maps.with(run.env, { COSMIC_TEST_TIMEOUT = suite_test_timeout_s })
  -- Its key parts said, as the checked suite's are, for its row.
  local words = with_census(run.words, shard)
  local argv: mut {string} = { executable }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local status = logged(c, name .. " suite", argv, out, err,
    suite_timeout_ns, c.root, values)
  record_suite(c, name, status, out)
  write(diagnostics .. "/" .. name .. "-test.status", tostring(status) .. "\n")
  local snapped: Snapped = { status = 1 }
  local snap_called, snap_answer = pcall(function()
    snapped.status = snapshot(c, diagnostics, name .. "-immediate", executable)
  end)
  local snapshot_status = snapped.status
  if not snap_called then
    local _, _ = Fs.put(Fs.stderr, tostring(snap_answer) .. "\n")
  end
  if status == 124 then
    local _, _ = Fs.put(Fs.stderr, name .. " suite: timed out (status 124)\n")
  elseif status ~= 0 then
    local _, _ = Fs.put(Fs.stderr,
      name .. " suite: failed (status " .. tostring(status) .. ")\n")
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
      { links = "create", filter = function(_path: string): boolean return true end })
    if written == nil then return false, trouble end
    return true, ""
  end)
  assert(not exists(destination .. "/o"), "tracked source archive holds o/")
  return status
end

local targets: {string:boolean} = {
  ["x86_64-linux-musl"] = true, ["aarch64-linux-musl"] = true, ["aarch64-macos"] = true }

local record PlatformContext
  trailing?: string
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
--- a job that runs no native suite (ci.yml's `checked`, `checked-shard`,
--- `checked-narrowing` and `format`).
local function boot(p: PlatformContext): integer
  local c = p.operation
  local root = p.root
  assert(not exists(BuildPaths.directory(root) .. "/build.db"), "build requires fresh working database")
  -- zig's caches are used where CI restored them: its global cache
  -- (COSMIC_ZIG_GLOBAL_CACHE, build/zig.tl) and the project cache, the
  -- zig-cache under COSMIC_ZIG_CACHE_SEED (see `operation`). Only a
  -- local run's is copied into the build directory, from the project cache
  -- COSMIC_ZIG_CACHE_FROM names, a developer's shared one.
  local seed = named("COSMIC_ZIG_CACHE_SEED")
  local from = named("COSMIC_ZIG_CACHE_FROM")
  local cache = if seed then seed .. "/zig-cache" else from end
  -- A cache named but absent costs a cold compile of vendor/ and core/
  -- (minutes) and fails nothing, so say so where the log shows it.
  if cache ~= nil and not is_dir(cache) then
    local _, _ = Fs.put(Fs.stderr, "build: no zig-cache at " .. cache ..
        "; compiling from nothing\n")
  end
  if seed == nil and from ~= nil and is_dir(from) then
    local source: string = from
    mkdir(BuildPaths.directory(root))
    local copied = step(c, "restore zig-cache", function(): boolean, string
      return Fs.copy_tree(source, BuildPaths.directory(root) .. "/zig-cache")
    end)
    if copied ~= 0 then return copied end
  end
  -- A restore or a copy gives every file of zig's caches a new inode,
  -- which zig 0.17 reads as a changed C source (cosmic_ci/zig_restat.tl).
  if cache then
    local project = seed and cache or BuildPaths.directory(root) .. "/zig-cache"
    local restat = ZigRestat.run(root, project, named("COSMIC_ZIG_GLOBAL_CACHE"))
    local _, _ = Fs.put(Fs.stderr, restat.out .. restat.err)
  end
  -- Every core: what CI verifies is the tool that carries them all, the one
  -- a release is made of; a bare `boot` writes a tool of the host's core alone.
  return checked(c, "core build and boot", { root .. "/bin/zig", "build", "cores", "boot", "-Dboot-cores=all" }, 0)
end

--- The list, in the checkout, of the test modules whose code takes a
--- path only macOS takes, each with why.
local darwin_list <const> = "ci/darwin-tests.txt"

--- The test modules `text`, a darwin list's, names: one path a line,
--- with what a `#` starts and blank lines left out.
function Orchestration.darwin_modules(text: string): {string}
  local modules: mut {string} = {}
  for line in text:gmatch("[^\n]+") do
    local path = String.trim((line:gsub("#.*$", "")))
    if path ~= "" then modules[#modules + 1] = path end
  end
  return modules
end

--- The `cosmic test` words of the darwin suite, given `words`, the
--- native suite's ([`test_words`]), and `modules`, the darwin list's
--- ([`darwin_modules`]): `--all` over those modules where the native
--- suite stands on verdicts, so none of them stands on one, with its
--- `--bail` where it has one. A verdict
--- keyed by declarations stands on macOS for the key a Linux leg
--- reached, whose run never took the macOS branch its code has. Nil on
--- a run of every test already (the scheduled run, the backstop).
function Orchestration.darwin_words(words: {string}, modules: {string}): {string}?
  if #modules == 0 then return nil end
  for _, word in ipairs(words) do
    if word == "--all" then return nil end
  end
  local out: mut {string} = { "test", "--all", "--census" }
  for _, word in ipairs(words) do
    if word == "--bail" then out[#out + 1] = word end
  end
  for _, module in ipairs(modules) do out[#out + 1] = module end
  return out
end

--- Whether the native suite whose stdout is `text` and exit status
--- `code` passed having run every test of the tree, none standing on a
--- verdict, as after a core change or a moved harness epoch: then it ran
--- each listed module on this leg already. Not where it ran a share
--- (its summary names one) or chose no test at all.
function Orchestration.native_ran_every(text: string, code: integer): boolean
  local reading = SuiteOutput.read(text, code)
  local figures, status = reading.figures, reading.status
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
    local _, _ = Fs.put(Fs.stderr, "darwin suite: cannot read " .. darwin_list .. ": " ..
        tostring(trouble) .. "\n")
    return 1
  end
  local darwin_run = Orchestration.suite_run()
  local words = Orchestration.darwin_words(darwin_run.words, Orchestration.darwin_modules(listed))
  if words == nil then return 0 end
  local native = p.local_diagnostics .. "/local-test"
  if (Env.get("COSMIC_CI_SHARD") or "") == "" and exists(native .. ".out") and
      exists(native .. ".status") then
    local code = math.tointeger(tonumber((read(native .. ".status"):gsub("%s+$", ""))))
    if code ~= nil and Orchestration.native_ran_every(read(native .. ".out"), code) then
      local _, _ = Fs.put(Fs.stderr, "darwin suite: the native suite ran every test here, none " ..
          "standing, so the listed modules ran on this leg already\n")
      return 0
    end
  end
  local values = Maps.with(darwin_run.env, { COSMIC_TEST_TIMEOUT = suite_test_timeout_s })
  local argv: mut {string} = { BuildPaths.directory(p.root) .. "/bin/cosmic" }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  mkdir(p.local_diagnostics)
  local out = p.local_diagnostics .. "/darwin-test.out"
  local status = logged(c, "darwin suite", argv, out,
    p.local_diagnostics .. "/darwin-test.err", suite_timeout_ns, c.root, values)
  record_suite(c, "darwin", status, out)
  if status ~= 0 then
    local _, _ = Fs.put(Fs.stderr, "darwin suite: failed (status " .. tostring(status) .. ")\n")
  end
  return status
end

--- The test files under cosmic/, build/, core/ and eval/ that watch the
--- declared types of the standard library and of the modules beside those
--- tests (`*declared_types_test.tl`, which a later directory's change adds files
--- to without touching CI), by their path in the checkout.
function Orchestration.declared_types_files(root: string): {string}
  local files: mut {string} = {}
  for _, directory in ipairs({ "cosmic", "build", "core", "eval" }) do
    local walked, _ = Fs.walk(root .. "/" .. directory)
    local found = walked or {}
    for _, relative in ipairs(found) do
      if relative:find("declared_types_test%.tl$") ~= nil then
        files[#files + 1] = directory .. "/" .. relative
      end
    end
  end
  table.sort(files)
  return files
end

--- The lines of a checked run's output that report a skip for want of a checked run: the run carried no checks.
--- A skip for want of boundary checks in the compile (build/type_watch.tl's `skip_reason`) is not one.
-- TODO: once build/type_watch.tl's `during` no longer skips a checked run for want of boundary checks, count every
-- skip here.
function Orchestration.unchecked_skips(output: string): {string}
  local found: mut {string} = {}
  for line in output:gmatch("[^\n]+") do
    if line:find("test: SKIP", 1, true) ~= nil and line:find("boundary checks are not compiled in", 1, true) == nil then
      found[#found + 1] = line
    end
  end
  return found
end

--- The declared-types tests on a checked run (`cosmic test
--- --check-types`), on the linux-x86_64 leg alone: they skip in any
--- other run. They skip in a checked run too until the compile writes the boundary checks
--- (build/type_watch.tl). After `local-boundary`, as a checked run writes a working
--- database of its own beside the tree's.
local function phase_declared_types(p: PlatformContext): integer
  if p.target ~= "x86_64-linux-musl" then return 0 end
  local c = p.operation
  local files = Orchestration.declared_types_files(c.root)
  if #files == 0 then
    local _, _ = Fs.put(Fs.stderr, "declared types: no cosmic/, build/, core/ or eval/ *declared_types_test.tl file\n")
    return 1
  end
  local argv: mut {string} = { BuildPaths.directory(p.root) .. "/bin/cosmic", "test", "--check-types" }
  for _, file in ipairs(files) do argv[#argv + 1] = file end
  mkdir(p.local_diagnostics)
  local out = p.local_diagnostics .. "/declared-types-test.out"
  local values = Maps.with(Orchestration.suite_run().env, { COSMIC_TEST_TIMEOUT = suite_test_timeout_s })
  local status = logged(c, "declared types", argv, out,
    p.local_diagnostics .. "/declared-types-test.err", suite_timeout_ns, c.root, values)
  -- A test that skipped asked nothing of the checks: the run was not checked.
  if status == 0 and #Orchestration.unchecked_skips(read(out)) > 0 then
    local _, _ = Fs.put(Fs.stderr, "declared types: a test skipped, so the run carried no checks\n")
    return 1
  end
  return status
end

--- `values`, the environment of a suite on the release core, without the promise of `checked`. The checked job's leg
--- promises it, the sanitized core's instruments, which a run on the release core lacks: a held run would fail every test
--- that requires it, where it should find it not applicable. The `checked` phase runs those on the core that has them.
local function release_promises(values: {string:string}): {string:string}
  local promised: mut {string} = {}
  for name in (values["COSMIC_TEST_PROMISES"] or ""):gmatch("[^,]+") do
    if name ~= "checked" then promised[#promised + 1] = name end
  end
  return Maps.with(values, { COSMIC_TEST_PROMISES = table.concat(promised, ",") })
end

--- The whole suite on a checked run (`cosmic test --check-types`), on the
--- linux-x86_64 target alone: each read the checker narrowed by a test is
--- written as a check of the test's fact, and a test that meets a read
--- whose fact is false fails there ("fact violated at <file>:<y>:<x>",
--- doc/testing.md's "checked narrowing"). It runs every test, since a
--- checked run stands on no verdict. ci.yml runs it in the `checked-narrowing`
--- jobs, after `boot`, each a share of the tests where COSMIC_CI_NARROWING_SHARD
--- names one (`I/N`, `--shard`). A share makes no check that some test enters
--- each C function, which only a whole run does (build/test.tl); that check
--- is held on this core by the linux-x86_64 leg's whole native suite in every
--- full run, since a checked run enters no C function a plain one does not:
--- the tests that run differently in a checked run only skip there
--- (build/type_watch.tl's `checked`), and the ones that need it
--- (`TypeWatch.during`) skip in every run until the compile writes the checks
--- of returns and fields. The leg's declared-types step ([`phase_declared_types`])
--- runs chosen files and makes no such check either.
--- Once build/type_watch.tl's `during` stops skipping a checked run, that holds no
--- longer (the TODO there).
local function phase_checked_narrowing(p: PlatformContext): integer
  if p.target ~= "x86_64-linux-musl" then return 0 end
  local c = p.operation
  local argv: mut {string} = { BuildPaths.directory(p.root) .. "/bin/cosmic", "test", "--check-types" }
  local share = named("COSMIC_CI_NARROWING_SHARD")
  if share ~= nil then
    argv[#argv + 1] = "--shard"
    argv[#argv + 1] = share
  end
  mkdir(p.local_diagnostics)
  local out = p.local_diagnostics .. "/checked-narrowing-test.out"
  local values = release_promises(Maps.with(Orchestration.suite_run().env,
    { COSMIC_TEST_TIMEOUT = checked_narrowing_test_timeout_s }))
  local status = logged(c, "checked narrowing", argv, out,
    p.local_diagnostics .. "/checked-narrowing-test.err", checked_narrowing_timeout_ns, c.root, values)
  -- A run that prints no "run-time types" line (the summary of a checked
  -- run) was not one: its modules carried no checks.
  if status == 0 and read(out):find("test: run-time types:", 1, true) == nil then
    local _, _ = Fs.put(Fs.stderr, "checked narrowing: the run reported nothing of the checks, so it carried none\n")
    return 1
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
--- does not run first (ci.yml's `checked-shard` and `checked` jobs): the checked build, and
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
  if (refused and named("COSMIC_CI_REQUIRE_SANDBOX") == "1") == true then
    assert(Fs.put(Fs.stderr, "sandbox: this worker cannot confine a test: " .. assert(refused) .. "\n"))
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
  local text: string? = nil
  if listed ~= "" then
    local found, trouble = Fs.read(listed)
    text = found
    if found == nil then
      local _, _ = Fs.put(Fs.stderr, "format check: the whole tree, since what changed is not known: " ..
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
--- light run it is a phase of its own in ci.yml's `format` job, which
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
    local _, _ = Fs.put(Fs.stderr, "format check: skipped on this leg " ..
        "(COSMIC_CI_FORMAT=skip)\n")
    return 0
  end
  -- The check's memo (build/check_memo.tl), where COSMIC_CI_CHECK_MEMO
  -- names a directory that holds one from an earlier run: put where the
  -- check reads it, as the build directory is new each run, so that the
  -- files it holds a row of cost the check nothing. A run that passed
  -- leaves its own there, for ci.yml's `format` job to save. The memo
  -- only ever speeds the check: a copy that fails is none.
  local kept = named("COSMIC_CI_CHECK_MEMO")
  local memo = BuildPaths.directory(p.root) .. "/translate-check.db"
  if kept ~= nil and exists(kept .. "/translate-check.db") and not exists(memo) then
    local copied, trouble = pcall(function()
      mkdir(Fs.dirname(memo))
      write(memo, read(kept .. "/translate-check.db"))
    end)
    if not copied then
      local _, _ = Fs.put(Fs.stderr, "format check: no memo taken from " .. kept .. ": " .. tostring(trouble) .. "\n")
      local _, _ = Fs.remove(memo)
    end
  end
  local status = checked(p.operation, "format check", format_command(p.root))
  if kept ~= nil and status == 0 and exists(memo) then
    local copied, trouble = pcall(function()
      mkdir(kept)
      write(kept .. "/translate-check.db", read(memo))
    end)
    if not copied then
      local _, _ = Fs.put(Fs.stderr, "format check: the memo is not kept in " .. kept .. ": " .. tostring(trouble) .. "\n")
    end
  end
  return status
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
      COSMIC_FIXTURE_BUILD = BuildPaths.directory(root),
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
      COSMIC_FIXTURE_CODESIGN = if target == "aarch64-macos" then "true" else "false" end,
    }, { { kind = "product", from = product },
      { kind = "format", from = contract .. "/format" } })
  if s ~= 0 then return s end
  s = checked(c, "selected format mutation", { contract .. "/format/format-test-" .. target, contract .. "/format/program" })
  if s ~= 0 then return s end
  s = archive(c, fresh)
  if s ~= 0 then return s end
  mkdir(portable_d)
  -- The suite runs this tool on `fresh`, a copy of the tree at another path than the checkout the product was built
  -- in, so the tool is put there as one built from `fresh` (the product but for that row; [`phase_attest`] holds it).
  write(portable_d .. "/cosmic-portable", ArtifactRow.with(read(product .. "/cosmic"),
    portable_d .. "/retarget.db", (assert(sys.realpath(fresh)))))
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
    local _, _ = Fs.put(Fs.stderr, "portable suite: skipped on this leg " ..
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
  if not hash_called then
    local _, _ = Fs.put(Fs.stderr, tostring(hash_error) .. "\n")
  end
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
    local _, _ = Fs.put(Fs.stderr, "portable boundary: skipped on this leg " ..
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
--- `p.fresh`, where the portable suite has built since): the
--- tree a fixture that boots or rebuilds one copies
--- (COSMIC_FIXTURE_SOURCE, [`Fixture.source_tree`]), the one the product
--- was booted from.
local function fixture_source(p: PlatformContext, destination: string): integer
  return step(p.operation, "fixture source extract", function(): boolean, string
    assert(Fs.remove_tree(destination))
    mkdir(destination)
    local written, trouble = Archive.extract(p.fresh .. ".tar", destination,
      { links = "create", filter = function(_path: string): boolean return true end })
    if written == nil then return false, trouble end
    return true, ""
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
  local source = env["COSMIC_BUILD_CACHE"] or ""
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
  local held: {sys.Kind} = { "dir", "file" }
  for _, kind in ipairs(held) do
    local path = source
    if kind == "dir" then path = Fs.dirname(source) end
    -- A link to the directory is followed, as shared_compiles' `private`
    -- follows it; one to the file is not.
    local st, stat_trouble: sys.Stat?, string = nil, ""
    if kind == "file" then
      st, stat_trouble = sys.lstat(path)
    else
      st, stat_trouble = sys.stat(path)
    end
    if st == nil then return false, path .. ": " .. stat_trouble end
    if st.kind ~= kind then
      return false, path .. ": not a " .. (if kind == "dir" then "directory" else kind end)
    end
    if st.uid ~= sys.getuid() then return false, path .. ": owned by another user" end
    if st.mode & 0x12 ~= 0 then
      return false, path .. ": writable by its group or others"
    end
  end
  if exists(destination) then
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
function Orchestration.fixture_lanes(env: {string:string}, cpus: integer): Orchestration.Lanes
  if env["COSMIC_CI_FIXTURE_BUDGET"] ~= "run" or cpus < 2 then return {} end
  return { high = cpus - 1, low = 1 }
end

--- Where the lanes of [`Orchestration.run_groups`] stand: the last group's
--- status and the index of the next low group to start.
local record Progress
  mut status: integer
  mut next_low: integer
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
  local active: mut {Runner.Running} = {}
  local owner: mut {Runner.Running:Orchestration.Group} = {}
  local in_low: mut {Runner.Running:boolean} = {}
  local function begin(group: Orchestration.Group, is_low: boolean)
    local running = group.start()
    active[#active + 1] = running
    owner[running] = group
    in_low[running] = is_low
  end
  local run: Progress = { status = 0, next_low = 1 }
  local ran, failure = pcall(function(): boolean
    begin(high, false)
    local first = low[1]
    if first ~= nil then
      begin(first, true)
      run.next_low = 2
    end
    while #active > 0 and run.status == 0 do
      local done = Runner.wait_any(active)
      for index, running in ipairs(active) do
        if running == done then
          table.remove(active, index)
          break
        end
      end
      local group = owner[done]
      run.status = assert(group).finish(Runner.reap(done))
      local following = low[run.next_low]
      if run.status == 0 and in_low[done] == true and following ~= nil then
        run.next_low = run.next_low + 1
        begin(following, true)
      end
    end
    return true
  end)
  for _, running in ipairs(active) do
    local outcome = Runner.stop(running)
    local abandoned, trouble = pcall(function(): boolean
      assert(owner[running]).abandon(outcome)
      return true
    end)
    if not abandoned and ran then ran, failure = false, trouble end
  end
  if not ran then error(failure, 0) end
  return run.status
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
    local _, _ = Fs.put(Fs.stderr, "fixture: self-rebuild-regression: skipped on this leg " ..
        "(COSMIC_CI_SELF_REBUILD=skip)\n")
  else
    local compiles = work .. "/self-rebuild-compiles.db"
    s = step(c, "self-rebuild compiles seed", function(): boolean, string
      if exists(compiles) then assert(Fs.remove(compiles)) end
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
    local _, _ = Fs.put(Fs.stderr, "fixture: fixed-point-regression: skipped on this leg " ..
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
  local lanes = Orchestration.fixture_lanes(Env.all(), Proc.cpu_count())
  local high_jobs, low_jobs = lanes.high, lanes.low
  local launcher_placements: {Placement} = {
    { kind = "product", from = product, only = { "prefix" } },
    { kind = "launcher", from = contract .. "/launcher" } }
  local high = fixture_group(c, work, { name = "self-driven-regression",
    source = "self_driven", timeout_ns = self_driven_test_timeout_ns, extra = {
      COSMIC_FIXTURE_SOURCE = source,
      COSMIC_FIXTURE_PRODUCT = product,
      COSMIC_TEST_TIMEOUT = self_driven_per_test_timeout_s,
    } }, high_jobs)
  local low: mut {Orchestration.Group} = {}
  local function add(spec: FixtureSpec)
    table.insert(low, fixture_group(c, work, spec, low_jobs))
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
  assert(before == digest, "executed artifact attestation differs")
  -- The suite ran the product put there as built from the tree it ran on ([`phase_assemble`]): the same bytes but
  -- for the row that says so.
  local executed = read(portable_d .. "/portable-artifact.before.sha256")
  assert(executed == read(portable_d .. "/portable-artifact.after.sha256"), "executed artifact attestation differs")
  assert(hash(portable_d .. "/cosmic-portable") .. "\n" == executed, "executed artifact attestation differs")
  -- What the lanes agree on, and what is attested and released, is the tool minus the row that names the checkout
  -- it was built in, which differs from a runner to a runner.
  local without = portable_d .. "/attest.db"
  local attested = Hash.hex_sha256(ArtifactRow.with(read(product .. "/cosmic"), without, nil))
  assert(Hash.hex_sha256(ArtifactRow.with(read(portable_d .. "/cosmic-portable"), without, nil)) == attested,
    "executed artifact attestation differs")
  write(product .. "/executed-cosmic.sha256", attested .. "  cosmic\n")
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
  elseif phase == "declared-types" then
    return phase_declared_types(p)
  elseif phase == "checked-narrowing" then
    return phase_checked_narrowing(p)
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
  local expected: integer? = nil
  local baseline: string? = nil
  for _, name in ipairs(entries) do
    if name:match("^portable%-product%-.+") then
      local p = products .. "/" .. name
      local att = p .. "/executed-cosmic.sha256"
      local exp = p .. "/expected-platforms"
      assert(exists(att) and exists(exp) and exists(p .. "/cosmic"), "incomplete product: " .. p)
      local line = read(att)
      local digest = line:match("^([0-9a-f]+)  cosmic\n$")
      assert(digest and #digest == 64, "invalid attestation: " .. att)
      assert(Hash.hex_sha256(ArtifactRow.with(read(p .. "/cosmic"), p .. "/provenance.db", nil)) == digest,
        "changed artifact: " .. p)
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
  assert(expected ~= nil, "no product to compare")
  assert(count == expected, "expected " .. Plural.count(expected, "product") .. ", found " .. tostring(count))
  return step(c, "provenance comparison", function(): boolean, string
    return true, ""
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
    attempt = ctx.attempt, root = ctx.root, driver = assert(Fs.absolute(assert(arg[0]))),
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

function Orchestration.provenance(_a: {string}): integer
  local ctx = ContextEnv.read()
  local c: Context = { db = ctx.db, worker = ctx.worker, run = ctx.run,
    attempt = ctx.attempt, root = ctx.root, driver = assert(Fs.absolute(assert(arg[0]))) }
  return run_phase(c, "provenance", function(): integer
    return provenance_impl(c, ctx.products)
  end)
end

return Orchestration
