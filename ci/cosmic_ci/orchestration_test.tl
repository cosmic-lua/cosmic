local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local Fixture = require("cosmic_ci.fixture")
local Sqlite = require("cosmic.sqlite")
local State = require("cosmic_ci.state")

--- The candidate checkout root: this test's cwd is `<checkout>/ci`, so
--- its parent is the checkout the self-check runs against.
local function checkout_root(): string
  local cwd = assert(Fs.absolute("."))
  return (assert(cwd:match("^(.*)/[^/]+$"), cwd .. ": no parent directory"))
end

--- The self-check holds a write transaction on `ci/o/build.db` while
--- tests run, so `driver.tl` must never run with project root `ci/`
--- itself: this copies the namespace into its own tmp project first.
local function command(tmp: string): {string}, string
  local host = assert(Proc.executable())
  local here = assert(Fs.absolute("."))
  local project = tmp .. "/driver-project"
  assert(Fs.mkdirs(project))
  assert(assert(Child.run({ "/bin/cp", "-R", here .. "/cosmic_ci",
    here .. "/fixtures", project })).ok)
  return { host, project .. "/cosmic_ci/driver.tl" }, project
end

--- The driver reads its context (GITHUB_WORKSPACE, GITHUB_RUN_ID,
--- GITHUB_RUN_ATTEMPT, RUNNER_TEMP, COSMIC_WORKER, TARGET) from the
--- environment. In CI the self-check runs inside a job where all of these
--- are already set to the real job's values, so a spawned driver.tl that
--- inherited them would write into that job's own $RUNNER_TEMP/cosmic-ci
--- or append to its real step summary; every test builds this context
--- explicitly and passes it as Fixture.call's extra env instead.
local function context(candidate: string, runner_temp: string,
    extra?: {string:string}): {string:string}
  local env: {string:string} = {
    GITHUB_WORKSPACE = candidate,
    GITHUB_RUN_ID = "run",
    GITHUB_RUN_ATTEMPT = "1",
    RUNNER_TEMP = runner_temp,
    COSMIC_WORKER = "worker",
    -- A developer's own caches are none of a test's: the driver would
    -- build in the one these name, not the test's own.
    COSMIC_ZIG_CACHE = "",
    COSMIC_ZIG_CACHE_SEED = "",
    COSMIC_ZIG_CACHE_FROM = "",
  }
  if extra then for name, value in pairs(extra) do env[name] = value end end
  return env
end

local function append(base: {string}, values: {string}): {string}
  local out: {string} = {}
  for _, value in ipairs(base) do out[#out + 1] = value end
  for _, value in ipairs(values) do out[#out + 1] = value end
  return out
end

local function test_provenance_failures_are_durable(tmp: string)
  local base, project = command(tmp)
  local candidate = tmp .. "/candidate"
  assert(Fs.mkdirs(candidate))
  assert(Fs.write(candidate .. "/AGENTS.md", "fixture\n"))
  local template = tmp .. "/products-template"
  assert(Fs.mkdirs(template))
  for _, name in ipairs({ "a", "b" }) do
    local product = template .. "/portable-product-" .. name
    assert(Fs.mkdirs(product) and Fs.write(product .. "/cosmic", "bytes"))
    local digest = Hash.hex_sha256("bytes")
    assert(Fs.write(product .. "/executed-cosmic.sha256", digest .. "  cosmic\n") and
      Fs.write(product .. "/expected-platforms", "2\n"))
  end

  -- Each scenario gets its own RUNNER_TEMP: the operations database and
  -- the products directory both live under it now, so a distinct scenario
  -- needs a distinct RUNNER_TEMP the way it used to need a distinct DB path.
  local function seeded_runner_temp(name: string): string
    local runner_temp = tmp .. "/" .. name .. "-runner-temp"
    assert(Fs.mkdirs(runner_temp .. "/cosmic-ci"))
    assert(assert(Child.run({ "/bin/cp", "-R", template,
      runner_temp .. "/cosmic-ci/products" })).ok)
    return runner_temp
  end

  local good_runner_temp = seeded_runner_temp("good")
  assert(Fixture.call("good-provenance", append(base, { "provenance" }), project,
    tmp .. "/logs", context(candidate, good_runner_temp)).result.ok)

  local bad_runner_temp = seeded_runner_temp("bad")
  assert(Fs.write(bad_runner_temp .. "/cosmic-ci/products/portable-product-b/cosmic",
    "changed"))
  assert(not Fixture.call("bad-provenance", append(base, { "provenance" }), project,
    tmp .. "/logs", context(candidate, bad_runner_temp)).result.ok)

  local summary = tmp .. "/bad-summary.md"
  assert(Fixture.call("summarize", append(base, { "summarize" }), project,
    tmp .. "/logs", context(candidate, bad_runner_temp,
      { GITHUB_STEP_SUMMARY = summary })).result.ok)
  assert(assert(Fs.read(summary)):find(
    "| worker | run | 1 | provenance | error |", 1, true))

  local corrupt_runner_temp = seeded_runner_temp("corrupt")
  assert(Fs.write(
    corrupt_runner_temp .. "/cosmic-ci/products/portable-product-b/executed-cosmic.sha256",
    "corrupt\n"))
  assert(not Fixture.call("corrupt-attestation", append(base, { "provenance" }), project,
    tmp .. "/logs", context(candidate, corrupt_runner_temp)).result.ok)

  local missing_runner_temp = seeded_runner_temp("missing")
  assert(Fs.remove(
    missing_runner_temp .. "/cosmic-ci/products/portable-product-b/executed-cosmic.sha256"))
  assert(not Fixture.call("missing-attestation", append(base, { "provenance" }), project,
    tmp .. "/logs", context(candidate, missing_runner_temp)).result.ok)
end

local function test_platform_requires_cosmic_worker(tmp: string)
  local base, project = command(tmp)
  local candidate = tmp .. "/candidate"
  local runner_temp = tmp .. "/runner-temp"
  assert(Fs.mkdirs(candidate) and Fs.write(candidate .. "/AGENTS.md", "fixture\n"))
  assert(Fs.mkdirs(runner_temp))
  local env = context(candidate, runner_temp,
    { TARGET = "x86_64-linux-musl", COSMIC_WORKER = "" })
  local outcome = Fixture.call("missing-worker",
    append(base, { "platform", "build" }), project, tmp .. "/logs", env)
  assert(not outcome.result.ok, "platform accepted a missing COSMIC_WORKER")
  Fixture.contains(outcome.err, "COSMIC_WORKER")
end

local function test_platform_protects_paths_and_retains_primary_failure(tmp: string)
  local base, project = command(tmp)
  local fake, seed = tmp .. "/fake", tmp .. "/seed"
  assert(Fs.mkdirs(fake .. "/bin") and
    Fs.mkdirs(fake .. "/ci/testdata/portable") and
    Fs.mkdirs(seed .. "/zig-cache") and Fs.mkdirs(seed .. "/zig-global") and
    Fs.mkdirs(tmp .. "/temporary"))
  assert(Fs.write(seed .. "/build.db", "poison"))
  assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
  Fixture.copy(checkout_root() .. "/ci/testdata/portable/work_db_integrity.tl",
    fake .. "/ci/testdata/portable/work_db_integrity.tl")
  Fixture.write(fake .. "/bin/zig", [[#!/bin/sh
set -eu
test ! -e o/build.db
mkdir -p o/bin
printf '%s' "$COSMIC_ZIG_CACHE" > o/zig-cache-named
printf not-a-database > o/build.db
cat > o/bin/cosmic <<'INNER'
#!/bin/sh
if [ "${1-}" = work_db_integrity.tl ]; then mkdir -p o; exit 0; fi
i=0; while [ "$i" -lt 20000 ]; do printf 'large retained output %s\n' "$i"; i=$((i + 1)); done
exit 23
INNER
chmod 755 o/bin/cosmic
]], 493)

  -- The work directory is derived from RUNNER_TEMP rather than typed as a
  -- CLI argument now, so pointing RUNNER_TEMP inside the candidate exercises
  -- the same "work directory inside the candidate is refused" protection.
  -- RUNNER_TEMP itself always exists in CI, so the test creates it too, and
  -- the refusal must leave it exactly as empty as it found it: nothing --
  -- not even the scratch directory -- gets created before the boundary
  -- check runs.
  local protected_runner_temp = fake .. "/inside-runner-temp"
  assert(Fs.mkdirs(protected_runner_temp))
  local protected = append(base, { "platform", "build" })
  assert(not Fixture.call("protected", protected, project, tmp .. "/logs",
    context(fake, protected_runner_temp, { TARGET = "x86_64-linux-musl" })).result.ok)
  assert(#assert(Fs.list(protected_runner_temp)) == 0,
    "refused RUNNER_TEMP was not left empty")

  local build_runner_temp = tmp .. "/build-runner-temp"
  assert(Fs.mkdirs(build_runner_temp))
  local work = build_runner_temp .. "/cosmic-ci/platform"
  local build = append(base, { "platform", "build" })
  local outcome = Fixture.call("build", build, project, tmp .. "/logs",
    context(fake, build_runner_temp, {
      TARGET = "x86_64-linux-musl",
      COSMIC_ZIG_CACHE_SEED = seed, COSMIC_CI_SELFTEST_REPLAY_FAILURE = "true",
      TMPDIR = tmp .. "/temporary",
    }), 10000)
  assert(outcome.result.code == 23, "suite failure was not primary")
  assert(assert(Fs.stat(work .. "/local-diagnostics/local-test.out")).size > 100000)
  assert(assert(Fs.read(work .. "/local-diagnostics/local-test.status")):find("23", 1, true))
  -- Neither of zig's caches is copied into o/: bin/zig uses both where
  -- they were restored, the project cache under the seed
  -- (COSMIC_ZIG_CACHE) and the global one (COSMIC_ZIG_GLOBAL_CACHE).
  assert(Fs.read(fake .. "/o/zig-cache-named") == seed .. "/zig-cache",
    "the project cache was not used where it was restored")
  assert(not Predicate.is_dir(fake .. "/o/zig-cache"), "project cache was copied into o/")
  assert(not Predicate.is_dir(fake .. "/o/zig-global"), "global cache was copied into o/")
  assert(Fs.exists(fake .. "/o/poison") == false)
  assert(#assert(Fs.list(tmp .. "/temporary")) == 0,
    "snapshot inspection directory was retained")
end

--- A local run names a project cache to start from
--- (COSMIC_ZIG_CACHE_FROM), a developer's shared one: the build copies
--- it into o/ and builds with the copy, leaving the one it came from as
--- it was.
local function test_a_local_build_copies_the_project_cache_into_o(tmp: string)
  local base, project = command(tmp)
  local fake, from = tmp .. "/fake", tmp .. "/from"
  assert(Fs.mkdirs(fake .. "/bin") and Fs.mkdirs(from .. "/o"))
  assert(Fs.write(from .. "/o/entry", "compiled"))
  assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
  Fixture.write(fake .. "/bin/zig", [[#!/bin/sh
printf '%s' "$COSMIC_ZIG_CACHE" > "$COSMIC_ZIG_CACHE/named"
exit 9
]], 493)
  local runner_temp = tmp .. "/runner-temp"
  assert(Fs.mkdirs(runner_temp))
  -- Under CI the job's own seed is inherited: an empty one names none.
  local outcome = Fixture.call("local-build", append(base, { "platform", "build" }),
    project, tmp .. "/logs", context(fake, runner_temp, {
      TARGET = "x86_64-linux-musl", COSMIC_ZIG_CACHE_FROM = from,
      COSMIC_ZIG_CACHE_SEED = "",
    }))
  assert(not outcome.result.ok, "the build passed a failed bin/zig")
  local copy = assert(Fs.absolute(fake)) .. "/o/zig-cache"
  assert(Fs.read(copy .. "/o/entry") == "compiled", "the project cache was not copied into o/")
  assert(Fs.read(copy .. "/named") == copy, "the build did not use the copy")
  assert(Fs.exists(from .. "/named") == false, "the build wrote the cache it copied")
end

--- Where COSMIC_CI_REQUIRE_SANDBOX=1 (ci.yml's Linux legs), the sandbox
--- phase fails where the probe says a confined test's parts did not all
--- hold, and passes where they did; without it (a local run) it passes
--- either way. It writes the report to the summary in every case. Like
--- every operation on such a leg, the probe runs with each `cosmic test`
--- worker required sandboxed (COSMIC_TEST_SANDBOX=1) and each confine
--- of a test held to confining (COSMIC_SANDBOX=must), and without
--- either where the leg does not require it.
local function test_the_sandbox_phase_fails_where_confinement_is_unavailable(tmp: string)
  local base, project = command(tmp)
  for _, case in ipairs({
    { name = "unavailable", said = "Confinement: **unavailable** (unveil).", require = "1", ok = false },
    { name = "available", said = "Confinement: available.", require = "1", ok = true },
    { name = "unrequired", said = "Confinement: **unavailable** (unveil).", require = "", ok = true },
  }) do
    local fake = tmp .. "/" .. case.name
    local runner_temp = fake .. "-runner-temp"
    assert(Fs.mkdirs(fake .. "/o/bin") and Fs.mkdirs(runner_temp))
    assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
    Fixture.write(fake .. "/o/bin/cosmic", "#!/bin/sh\nprintf '| Part |\\n\\n" ..
      case.said .. "\\nswitch=%s mode=%s.\\n' \"$COSMIC_TEST_SANDBOX\" \"$COSMIC_SANDBOX\"\n", 493)
    local summary = runner_temp .. "/summary.md"
    local outcome = Fixture.call("sandbox-" .. case.name, append(base, { "platform", "sandbox" }),
      project, tmp .. "/logs", context(fake, runner_temp, {
        TARGET = "x86_64-linux-musl", GITHUB_STEP_SUMMARY = summary,
        COSMIC_CI_REQUIRE_SANDBOX = case.require,
        -- Unset for the driver, whatever this test's own run was given
        -- (a developer's COSMIC_TEST_SANDBOX=0, or ci.yml's driver
        -- check's; build/test_inputs.tl pins COSMIC_SANDBOX): the leg
        -- sets each, or leaves it.
        COSMIC_TEST_SANDBOX = "", COSMIC_SANDBOX = "",
      }))
    assert(outcome.result.ok == case.ok, "the sandbox phase answered " ..
      tostring(outcome.result.ok) .. " where the probe said " .. case.said)
    Fixture.contains(summary, case.said)
    Fixture.contains(summary, case.require == "1" and "switch=1 mode=must." or "switch= mode=.")
    if not case.ok then Fixture.contains(outcome.err, "cannot confine a test") end
  end
end

--- A suite stands on declared-key verdicts in a push's run and the
--- merge queue's, and nowhere else: on a Linux leg, its workers
--- sandboxed, and required to be, and on the macOS leg, keyed by what
--- they declare with no sandbox (COSMIC_CI_DECLARED_KEYS); a leg that
--- is neither, a manual run and main's scheduled one each run every
--- test.
local function test_a_suite_stands_on_verdicts_in_a_push_or_merge_queue()
  local Orchestration = require("cosmic_ci.orchestration")
  local function words(env: {string:string}): string
    return table.concat(Orchestration.test_words(env), " ")
  end
  for _, event in ipairs({ "push", "merge_group" }) do
    local linux = { COSMIC_CI_REQUIRE_SANDBOX = "1", COSMIC_CI_DECLARED_KEYS = "0",
      COSMIC_CI_EVENT = event, COSMIC_CI_HARNESS_MOVED = "0" }
    assert(Orchestration.stands(linux) and words(linux) == "test", event)
    local mac = { COSMIC_CI_REQUIRE_SANDBOX = "0", COSMIC_CI_DECLARED_KEYS = "1",
      COSMIC_CI_EVENT = event, COSMIC_CI_HARNESS_MOVED = "0" }
    assert(Orchestration.stands(mac) and words(mac) == "test", "macOS " .. event)
    local neither = { COSMIC_CI_REQUIRE_SANDBOX = "0", COSMIC_CI_DECLARED_KEYS = "0",
      COSMIC_CI_EVENT = event }
    assert(not Orchestration.stands(neither) and words(neither) == "test --all",
      "a leg that neither sandboxes nor keys by declarations, " .. event)
  end
  for _, event in ipairs({ "workflow_dispatch", "schedule", "pull_request", "" }) do
    for _, leg in ipairs({ "COSMIC_CI_REQUIRE_SANDBOX", "COSMIC_CI_DECLARED_KEYS" }) do
      local env = { [leg] = "1", COSMIC_CI_EVENT = event }
      assert(not Orchestration.stands(env) and words(env) == "test --all", leg .. " " .. event)
    end
  end
  assert(not Orchestration.stands({}), "run-local, and any run that names no event")
  -- Standing, it may stand on what another run reached; else not.
  local queued: {string:string} = { COSMIC_CI_REQUIRE_SANDBOX = "1", COSMIC_CI_EVENT = "merge_group",
    COSMIC_CI_HARNESS_MOVED = "0" }
  Orchestration.shares(queued)
  assert(queued.COSMIC_TEST_NO_SHARED == nil, "the merge queue")
  local scheduled: {string:string} = { COSMIC_CI_REQUIRE_SANDBOX = "1", COSMIC_CI_EVENT = "schedule" }
  Orchestration.shares(scheduled)
  assert(scheduled.COSMIC_TEST_NO_SHARED == "1", "main's scheduled run")
  -- A merge queue run whose change moves the harness's epoch file, or
  -- that cannot tell, stands on nothing; a push's is not asked.
  for _, moved in ipairs({ "1", "" }) do
    local harness: {string:string} = { COSMIC_CI_REQUIRE_SANDBOX = "1",
      COSMIC_CI_EVENT = "merge_group", COSMIC_CI_HARNESS_MOVED = moved ~= "" and moved or nil }
    assert(not Orchestration.stands(harness) and words(harness) == "test --all",
      "the merge queue, the harness moved: " .. moved)
  end
  assert(Orchestration.stands({ COSMIC_CI_REQUIRE_SANDBOX = "1", COSMIC_CI_EVENT = "push",
    COSMIC_CI_HARNESS_MOVED = "1" }), "a push's run")
end

--- Runs git in `root`, which must succeed, answering what it printed.
local function git(root: string, words: {string}): string
  local argv = { "/usr/bin/env", "git", "-C", root, "-c", "user.name=t",
    "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false" }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local result = assert(Child.run(argv, { stdout = "capture", stderr = "capture" }))
  assert(result.ok, table.concat(words, " ") .. ": " .. tostring(result.stderr))
  return result.stdout or ""
end

--- A merge queue run compares build/harness_epoch.tl at its base with
--- what it checks (`harness_moved`): a change that leaves it runs what
--- its keys moved, one that moves it every test (`suite_run`), and one
--- whose base it cannot read or that names none every test too.
local function test_a_merge_queue_run_that_moves_the_epoch_runs_every_test(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  local root = tmp .. "/checkout"
  assert(Fs.mkdirs(root .. "/build"))
  git(root, { "init", "--quiet" })
  assert(Fs.write(root .. "/build/harness_epoch.tl", "epoch 1\n"))
  assert(Fs.write(root .. "/README", "one\n"))
  git(root, { "add", "." })
  git(root, { "commit", "--quiet", "-m", "base" })
  local base = git(root, { "rev-parse", "HEAD" }):match("^(%x+)")
  assert(Fs.write(root .. "/README", "two\n"))
  git(root, { "commit", "--quiet", "-am", "elsewhere" })
  assert(not Orchestration.harness_moved(root, base), "a change that leaves the file")
  local function queued(sha: string): string
    local words = Orchestration.suite_run({ COSMIC_CI_EVENT = "merge_group",
      COSMIC_CI_REQUIRE_SANDBOX = "1", GITHUB_WORKSPACE = root, COSMIC_CI_BASE_SHA = sha })
    return table.concat(words, " ")
  end
  assert(queued(base) == "test", "a merge queue run that leaves the epoch ran --all")
  assert(Fs.write(root .. "/build/harness_epoch.tl", "epoch 2\n"))
  git(root, { "commit", "--quiet", "-am", "bump" })
  assert(Orchestration.harness_moved(root, base), "a change that moves the file")
  -- Asked of another checkout, as the answer is kept by checkout and base.
  local moved = tmp .. "/moved"
  git(tmp, { "clone", "--quiet", root, moved })
  assert(queued(base) == "test", "the first answer was not kept")
  local words = Orchestration.suite_run({ COSMIC_CI_EVENT = "merge_group",
    COSMIC_CI_REQUIRE_SANDBOX = "1", GITHUB_WORKSPACE = moved, COSMIC_CI_BASE_SHA = base })
  assert(table.concat(words, " ") == "test --all", "a merge queue run that moves the epoch")
  -- A base it cannot read, or none, is taken as a move.
  assert(Orchestration.harness_moved(root, string.rep("0", 40)), "a base that is no commit")
  assert(Orchestration.harness_moved(root, ""), "no base")
  assert(Orchestration.harness_moved(tmp .. "/none", base), "no checkout")
  -- ci.yml names the base, and checks out the merge's parent with it.
  local text = assert(Fs.read(checkout_root() .. "/.github/workflows/ci.yml"))
  local ci = assert(Json.decode_object(text, { json5 = true, hash_comments = true }))
  local platform = (ci.jobs as {string: {string: any}}).platform
  local env = platform.env as {string: string}
  assert(env.COSMIC_CI_BASE_SHA == "${{ github.event.merge_group.base_sha }}",
    "ci.yml's platform job names no merge queue base: " .. tostring(env.COSMIC_CI_BASE_SHA))
end

--- The portable suite keeps its verdicts in a file of its own beside
--- the other suites', in the directory ci.yml caches, and none where
--- the driver names no absolute path or turns the cache off.
local function test_the_portable_suite_keeps_verdicts_of_its_own()
  local Orchestration = require("cosmic_ci.orchestration")
  for shared, portable in pairs({
    ["/runner/_temp/verdicts/verdicts.db"] = "/runner/_temp/verdicts/portable.db",
    ["/verdicts.db"] = "/portable.db",
    ["0"] = "0", [""] = "0", ["verdicts.db"] = "0",
  }) do
    local said = Orchestration.suite_verdicts({ COSMIC_VERDICT_CACHE = shared }, "portable")
    assert(said == portable, shared .. ": " .. said)
  end
  assert(Orchestration.suite_verdicts({}, "portable") == "0", "unset")
end

--- So does the checked suite, apart from both the local suite's and the
--- portable suite's.
local function test_the_checked_suite_keeps_verdicts_of_its_own()
  local Orchestration = require("cosmic_ci.orchestration")
  local shared = { COSMIC_VERDICT_CACHE = "/runner/_temp/verdicts/verdicts.db" }
  assert(Orchestration.suite_verdicts(shared, "checked") ==
    "/runner/_temp/verdicts/checked.db")
  assert(Orchestration.suite_verdicts({ COSMIC_VERDICT_CACHE = "0" }, "checked") == "0")
end

--- A fixture reads inputs its environment names (COSMIC_FIXTURE_*),
--- which no verdict's key holds, so it stands on no verdict another run
--- reached, and keeps none for one, even in a Linux branch push's run,
--- where every other suite shares them. Nor does it share compiles: what
--- a fresh tree compiles is what some fixtures check.
local function test_a_fixture_neither_reads_nor_writes_shared_verdicts(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  local env: {string:string} = { COSMIC_CI_REQUIRE_SANDBOX = "1", COSMIC_CI_EVENT = "push",
    COSMIC_TEST_SANDBOX = "1", COSMIC_VERDICT_CACHE = tmp .. "/verdicts.db",
    COSMIC_BUILD_CACHE = tmp .. "/build.db", COSMIC_FIXTURE_ROOT = tmp .. "/root" }
  Orchestration.shares(env)
  assert(env.COSMIC_TEST_NO_SHARED == nil, "a Linux push's suite stands on shared verdicts")
  local fixture = Orchestration.fixture(env, tmp .. "/tmp")
  assert(fixture.COSMIC_VERDICT_CACHE == "0", "the fixture may keep shared verdicts")
  assert(fixture.COSMIC_BUILD_CACHE == "0", "the fixture may take shared compiles")
  assert(fixture.COSMIC_TEST_NO_SHARED == "1", "the fixture may stand on shared verdicts")
  assert(fixture.COSMIC_TEST_SANDBOX == "0" and fixture.TMPDIR == tmp .. "/tmp")
  assert(fixture.COSMIC_FIXTURE_ROOT == tmp .. "/root")
end

--- COSMIC_CI_FORMAT=skip skips the format check on a leg, as ci.yml
--- sets on every leg but one; any other value runs it.
local function test_the_format_check_runs_unless_the_leg_skips_it(tmp: string)
  local base, project = command(tmp)
  for _, case in ipairs({
    { name = "skip", switch = "skip", ok = true, ran = false },
    { name = "run", switch = "run", ok = false, ran = true },
    { name = "unset", switch = "", ok = false, ran = true },
  }) do
    local fake = tmp .. "/format-" .. case.name
    local runner_temp = fake .. "-runner-temp"
    local boundary = runner_temp .. "/cosmic-ci/platform/local-diagnostics/local-boundary"
    assert(Fs.mkdirs(fake .. "/o/bin") and Fs.mkdirs(boundary))
    assert(Fs.write(boundary .. "/hashes.sha256", ""))
    assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
    Fixture.write(fake .. "/o/bin/cosmic", "#!/bin/sh\nprintf '%s' \"$*\" > \"$0.ran\"\nexit 7\n", 493)
    local outcome = Fixture.call("format-" .. case.name, append(base, { "platform", "format" }),
      project, tmp .. "/logs", context(fake, runner_temp, {
        TARGET = "x86_64-linux-musl", COSMIC_CI_FORMAT = case.switch,
      }))
    assert(outcome.result.ok == case.ok, case.name .. ": the format phase answered " ..
      tostring(outcome.result.ok))
    local ran = Fs.read(fake .. "/o/bin/cosmic.ran")
    assert((ran ~= nil) == case.ran, case.name .. ": the check ran: " .. tostring(ran))
    if case.ran then assert(ran == "fix --check .", ran) end
  end
end

--- Every leg verifies its checked artifact -- the manifest entry of its
--- checked core, as the contract's decoder reads it, and that the
--- artifact runs that core -- and runs no release cosmic to do it: the
--- checked build leaves the tree's database as the tools find it, so
--- there is no rebuild to pay. Only the leg that runs the checked suite
--- (COSMIC_CI_CHECKED_SUITE) runs the checked cosmic on a file in the
--- tree, whose entry must agree with the decoder's.
local function test_only_a_leg_that_runs_the_checked_suite_runs_the_checked_cosmic_in_the_tree(tmp: string)
  local base, project = command(tmp)
  local core = "the checked core"
  local digest = Hash.hex_sha256(core)
  local target = "x86_64-linux-musl"
  local right = "16384 " .. #core .. " " .. digest
  local wrong = "16384 " .. #core .. " " .. string.rep("0", 64)
  local function entry(fields: string): string
    return "printf '%s\\t%s\\t%s\\n' " .. fields .. "\n"
  end
  local function candidate(name: string, host_image: string,
      checked: string): string, string
    local fake = tmp .. "/checked-" .. name
    local runner_temp = fake .. "-runner-temp"
    local format = runner_temp .. "/cosmic-ci/platform/contract/format"
    assert(Fs.mkdirs(fake .. "/o/bin") and Fs.mkdirs(fake .. "/o/sanitized/bin"))
    assert(Fs.mkdirs(format))
    assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
    assert(Fs.write(fake .. "/o/sanitized/targets.tsv",
      "1\t1\trelease\t" .. target .. "\tLinux\tx86_64\n" ..
      "1\t2\tsanitized\tsanitized-" .. target .. "\tLinux\tx86_64\n"))
    assert(Fs.write(fake .. "/o/sanitized/cosmic-core", core))
    -- The release cosmic, which fails if run.
    Fixture.write(fake .. "/o/bin/cosmic", "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$0.ran\"\n" ..
      "exit 9\n", 493)
    -- The contract's decoder, which reads the checked artifact's entry.
    Fixture.write(format .. "/format-test-" .. target, "#!/bin/sh\n" ..
      "case \"$1 $2\" in '--inspect '*/o/sanitized/bin/cosmic) ;; *) exit 9 ;; esac\n" ..
      "printf '%s\\n' 'prefix 32768 manifest 28672 4096 database 32768 0 entries 2' " ..
      "'entry 1 1 16384 1 " .. string.rep("1", 64) .. "' " ..
      "'entry 1 2 16384 " .. #core .. " " .. digest .. "'\n", 493)
    -- The checked artifact: a script that answers each run as the tool
    -- would, `tool.tl entry` with `checked`, its core at the first
    -- aligned offset past it. Its `-e` answers only a chunk that prints
    -- the three keys, in order.
    local script = "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$0.ran\"\n" ..
      "if [ \"$1\" = -e ]; then case \"$2\" in " ..
      "*\"print(Store.meta('runtime_context'), Store.meta('host'), Store.meta('host_image'))\"*) ;; " ..
      "*) exit 9 ;; esac\n" ..
      "printf '%s\\t%s\\t%s\\n' portable-v1 " .. target .. " " .. host_image .. "; exit 0; fi\n" ..
      "if [ \"$1\" = test ]; then printf '%s\\n' " ..
      "'test: key parts: host features 01, host 02, system , runtime 04, compiler 05, harness 06' " ..
      "'test: PASS (7 tests, 2 modules; 3 ran, 4 stood, 55 ms; sandboxed)'; exit 0; fi\n" ..
      entry(checked) .. "exit 0\n"
    Fixture.write(fake .. "/o/sanitized/bin/cosmic",
      script .. string.rep("#", 16384 - #script) .. core, 493)
    return fake, runner_temp
  end
  for _, case in ipairs({
    { name = "skip", switch = "skip", image = digest, checked = right,
      ok = true, ran = "-e\n" },
    { name = "run", switch = "run", image = digest, checked = right,
      ok = true, ran = "-e\n/tool.tl\ntest\n" },
    { name = "another-core", switch = "skip", image = string.rep("0", 64),
      checked = right, ok = false, ran = "-e\n" },
    { name = "checked-disagrees", switch = "run", image = digest,
      checked = wrong, ok = false, ran = "-e\n/tool.tl\n" },
  }) do
    local fake, runner_temp = candidate(case.name, case.image, case.checked)
    local outcome = Fixture.call("checked-" .. case.name, append(base, { "platform", "checked" }),
      project, tmp .. "/logs", context(fake, runner_temp, {
        TARGET = target, COSMIC_CI_CHECKED_SUITE = case.switch,
      }))
    assert(outcome.result.ok == case.ok, case.name .. ": the checked phase answered " ..
      tostring(outcome.result.ok) .. ": " .. Fixture.read(outcome.err))
    local ran = Fs.read(fake .. "/o/sanitized/bin/cosmic.ran")
    if ran then ran = ran:gsub("[^\n]*/test/portable/tool%.tl", "/tool.tl") end
    assert(ran == case.ran, case.name .. ": the checked cosmic ran: " .. tostring(ran))
    local released = Fs.read(fake .. "/o/bin/cosmic.ran")
    assert(released == nil, case.name .. ": the release cosmic ran: " .. tostring(released))
    -- The suite that ran wrote its row, with what its output said.
    local db = assert(Sqlite.open(runner_temp .. "/cosmic-ci/operations.db"))
    local rows = State.suite_rows(db)
    assert(db:close())
    if case.name == "run" then
      assert(#rows == 1, case.name .. ": " .. #rows .. " suite rows")
      local row = rows[1]
      assert(row.worker == "worker" and row.phase == "checked" and row.suite == "checked")
      assert(row.status == "pass" and row.exit_code == 0 and row.tests == 7)
      assert(row.ran == 3 and row.stood == 4 and row.elapsed_ms == 55)
      assert(row.parts.runtime == "04" and row.parts.harness == "06" and row.parts.system == "")
    else
      assert(#rows == 0, case.name .. ": a suite that did not run wrote a row")
    end
  end
end

--- The native suite (`build`) writes its row, with what its output
--- said; where the row cannot be written -- here an operations database
--- whose suite_runs table has another shape -- the suite's own status
--- still decides the phase, which passes, and says so on stderr.
local function test_the_native_suite_writes_its_row_and_a_lost_row_fails_nothing(tmp: string)
  local base, project = command(tmp)
  for _, case in ipairs({ { name = "rows", broken = false }, { name = "broken", broken = true } }) do
    local fake = tmp .. "/native-" .. case.name
    local runner_temp = fake .. "-runner-temp"
    assert(Fs.mkdirs(fake .. "/bin") and Fs.mkdirs(fake .. "/ci/testdata/portable"))
    assert(Fs.mkdirs(runner_temp .. "/cosmic-ci"))
    assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
    assert(Fs.write(fake .. "/ci/testdata/portable/work_db_integrity.tl", "\n"))
    -- bin/zig's boot leaves a cosmic whose suite says its figures, and
    -- which answers the integrity check.
    Fixture.write(fake .. "/bin/zig", "#!/bin/sh\nmkdir -p o/bin\nprintf db > o/build.db\n" ..
      "cat > o/bin/cosmic <<'EOF'\n#!/bin/sh\n" ..
      "if [ \"$1 $2\" = \"test --census\" ]; then printf '%s\\n' " ..
      "'test: key parts: host features 01, host 02, system 03, runtime 04, compiler 05, harness 06' " ..
      "'test: PASS (9 tests, 2 modules; 5 ran, 4 stood, 77 ms; sandboxed)'; fi\nexit 0\nEOF\n" ..
      "chmod 755 o/bin/cosmic\n", 493)
    local database = runner_temp .. "/cosmic-ci/operations.db"
    if case.broken then
      local db = assert(Sqlite.open(database, true))
      assert(db:exec("CREATE TABLE suite_runs (id INTEGER PRIMARY KEY)"))
      assert(db:close())
    end
    local outcome = Fixture.call("native-" .. case.name, append(base, { "platform", "build" }),
      project, tmp .. "/logs", context(fake, runner_temp, { TARGET = "x86_64-linux-musl",
        TMPDIR = tmp }))
    local err = Fixture.read(outcome.err)
    assert(outcome.result.ok, case.name .. ": the build phase failed: " .. err)
    local db = assert(Sqlite.open(database))
    if case.broken then
      local count = assert(Sqlite.text_rows(db, "SELECT COUNT(*) FROM suite_runs"))
      assert(count[1][1] == "0", case.name .. ": " .. count[1][1] .. " rows")
      assert(err:find("local suite: row not recorded", 1, true), err)
    else
      local rows = State.suite_rows(db)
      assert(#rows == 1, case.name .. ": " .. #rows .. " suite rows")
      local row = rows[1]
      assert(row.suite == "local" and row.phase == "build" and row.status == "pass")
      assert(row.exit_code == 0 and row.tests == 9 and row.ran == 5 and row.stood == 4)
      assert(row.elapsed_ms == 77 and row.sandbox == "sandboxed")
      assert(row.parts.runtime == "04" and row.parts.harness == "06")
    end
    local phases = assert(Sqlite.text_rows(db, "SELECT phase, status FROM operation_events " ..
      "WHERE event = 'complete' AND phase IN ('local suite', 'platform: build') ORDER BY id"))
    assert(#phases == 2 and phases[1][2] == "success" and phases[2][2] == "success",
      case.name .. ": the phases did not succeed")
    assert(db:close())
  end
end

--- The checked core's suite and the format check each run on one leg
--- of ci.yml's platform job (COSMIC_CI_CHECKED_SUITE, COSMIC_CI_FORMAT),
--- and not on the same one: the checked suite makes its leg one of the
--- run's longest, and the format check, which answers the same on every
--- leg, would only lengthen it.
local function test_the_checked_suite_and_the_format_check_run_on_different_legs()
  local text = assert(Fs.read(checkout_root() .. "/.github/workflows/ci.yml"))
  local ci = assert(Json.decode_object(text, { json5 = true, hash_comments = true }))
  local platform = (ci.jobs as {string: {string: any}}).platform
  local legs: {string: boolean} = {}
  local strategy = platform.strategy as {string: {string: any}}
  for _, leg in ipairs(strategy.matrix.include as {{string: string}}) do
    legs[leg.name] = true
  end
  local env = platform.env as {string: string}
  local function leg(name: string): string
    local value = assert(env[name], "ci.yml's platform job sets no " .. name)
    local one = value:match("^%${{ matrix%.name == '([%w_-]+)' && 'run' || 'skip' }}$")
    assert(one and legs[one], name .. " runs on no one leg of the matrix: " .. value)
    return one
  end
  local checked, format = leg("COSMIC_CI_CHECKED_SUITE"), leg("COSMIC_CI_FORMAT")
  assert(checked ~= format, "the checked suite and the format check both run on " .. checked)
end

--- The fixed-point regression, the slowest fixture on every leg, runs
--- on one leg of a gating run (COSMIC_CI_FIXED_POINT), not the one the
--- checked suite lengthens, and on every leg of the scheduled run.
local function test_the_fixed_point_fixture_runs_on_one_leg_and_on_every_scheduled_one()
  local text = assert(Fs.read(checkout_root() .. "/.github/workflows/ci.yml"))
  local ci = assert(Json.decode_object(text, { json5 = true, hash_comments = true }))
  local platform = (ci.jobs as {string: {string: any}}).platform
  local legs: {string: boolean} = {}
  local strategy = platform.strategy as {string: {string: any}}
  for _, leg in ipairs(strategy.matrix.include as {{string: string}}) do
    legs[leg.name] = true
  end
  local env = platform.env as {string: string}
  local value = assert(env.COSMIC_CI_FIXED_POINT, "ci.yml's platform job sets no COSMIC_CI_FIXED_POINT")
  local one = value:match("^%${{ %(matrix%.name == '([%w_-]+)' || " ..
    "github%.event_name == 'schedule'%) && 'run' || 'skip' }}$")
  assert(one and legs[one], "the fixed-point fixture runs on no one leg of the matrix, " ..
    "or not on every leg of the scheduled run: " .. value)
  local checked = assert(env.COSMIC_CI_CHECKED_SUITE):match("matrix%.name == '([%w_-]+)'")
  assert(one ~= checked, "the fixed-point fixture and the checked suite both run on " .. one)
end

--- A gating suite's workers are given none of what names the run --
--- GitHub's GITHUB_*, RUNNER_* and ACTIONS_*, CI, systemd's per-unit
--- variables, the container's HOSTNAME, the driver's own COSMIC_CI_*
--- switches -- so a test that reads the whole environment (`env =
--- {"*"}`) is keyed the same from run to run and can stand on an
--- earlier run's verdict. The rest reaches them: PATH, HOME, the proxy
--- and certificate variables, COSMIC_CI_REQUIRE_SANDBOX, which a test
--- reads, and what the driver sets. What the suite does is still decided
--- from the driver's own environment: a Linux push's run stands on
--- verdicts (no --all) though COSMIC_CI_EVENT does not reach the suite.
local function test_a_suite_is_given_nothing_that_names_the_run(tmp: string)
  local base, project = command(tmp)
  local fake = tmp .. "/fake"
  assert(Fs.mkdirs(fake .. "/bin") and Fs.mkdirs(fake .. "/ci/testdata/portable"))
  assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
  assert(Fs.write(fake .. "/ci/testdata/portable/work_db_integrity.tl", "\n"))
  local seen = tmp .. "/seen"
  Fixture.write(fake .. "/bin/zig", [[#!/bin/sh
mkdir -p o/bin
printf 'db' > o/build.db
cat > o/bin/cosmic <<'SCRIPT'
#!/bin/sh
if [ "$1" = test ]; then printf '%s\n' "$*" > "$SEEN.words"; env > "$SEEN.env"; fi
exit 0
SCRIPT
chmod 755 o/bin/cosmic
]], 493)
  local runner_temp = tmp .. "/runner-temp"
  assert(Fs.mkdirs(runner_temp))
  local outcome = Fixture.call("forgets-run", append(base, { "platform", "build" }),
    project, tmp .. "/logs", context(fake, runner_temp, {
      TARGET = "x86_64-linux-musl", SEEN = seen,
      GITHUB_RUN_ID = "36306898411", GITHUB_SHA = "0123abcd",
      GITHUB_STEP_SUMMARY = runner_temp .. "/summary.md",
      RUNNER_NAME = "GitHub Actions 12", RUNNER_TRACKING_ID = "github_1f2e",
      ACTIONS_RUNTIME_TOKEN = "token", CI = "true", INVOCATION_ID = "abc",
      JOURNAL_STREAM = "8:1234", HOSTNAME = "4f1c2d3e5a6b",
      COSMIC_CI_SCOPE = "light", COSMIC_CI_EVENT = "push",
      COSMIC_CI_CHECKED_SUITE = "skip", COSMIC_CI_REQUIRE_SANDBOX = "1",
      HOME = "/home/runner", HTTPS_PROXY = "http://proxy:3128",
      SSL_CERT_FILE = "/etc/ssl/cert.pem", XDG_CACHE_HOME = tmp .. "/cache",
    }))
  assert(outcome.result.ok, "the build failed: " .. Fixture.read(outcome.err))
  local env: {string:string} = {}
  for line in (assert(Fs.read(seen .. ".env"))):gmatch("[^\n]+") do
    local name, value = line:match("^([^=]+)=(.*)$")
    if name then env[name] = value end
  end
  for name in pairs(env) do
    assert(not (name:match("^GITHUB_") or name:match("^RUNNER_") or
      name:match("^ACTIONS_")), "the suite was given " .. name)
    assert(name == "COSMIC_CI_REQUIRE_SANDBOX" or not name:match("^COSMIC_CI_"),
      "the suite was given " .. name)
  end
  for _, name in ipairs({ "CI", "INVOCATION_ID", "JOURNAL_STREAM", "HOSTNAME" }) do
    assert(env[name] == nil, "the suite was given " .. name)
  end
  for name, value in pairs({ COSMIC_CI_REQUIRE_SANDBOX = "1", HOME = "/home/runner",
      HTTPS_PROXY = "http://proxy:3128", SSL_CERT_FILE = "/etc/ssl/cert.pem",
      XDG_CACHE_HOME = tmp .. "/cache", TARGET = "x86_64-linux-musl",
      COSMIC_WORKER = "worker", FUZZ_ITERS = "0", COSMIC_TEST_SANDBOX = "1" }) do
    assert(env[name] == value, name .. " did not reach the suite: " .. tostring(env[name]))
  end
  assert(env.PATH ~= nil and env.PATH ~= "", "PATH did not reach the suite")
  assert(env.COSMIC_TEST_NO_SHARED == nil, "a Linux push's suite stands on shared verdicts")
  assert(Fs.read(seen .. ".words") == "test --census\n", "a Linux push's suite ran --all")
end

--- The portable suite stands on verdicts where the other suites do --
--- a Linux leg's push or merge queue run -- on those of its own file
--- (`Orchestration.suite_verdicts`), never the local suite's; where
--- they do not (main's scheduled run), it runs every test.
local function test_the_portable_suite_stands_on_its_own_verdicts(tmp: string)
  local base, project = command(tmp)
  for _, case in ipairs({
    { event = "merge_group", words = "test --census\n", shared = false },
    { event = "push", words = "test --census\n", shared = false },
    { event = "schedule", words = "test --census --all\n", shared = true },
  }) do
    local fake = tmp .. "/portable-" .. case.event
    local runner_temp = fake .. "-runner-temp"
    local work = runner_temp .. "/cosmic-ci/platform"
    local diagnostics = work .. "/portable-diagnostics"
    local fresh = work .. "/portable-source"
    assert(Fs.mkdirs(fake) and Fs.mkdirs(diagnostics) and
      Fs.mkdirs(fresh .. "/o") and Fs.mkdirs(fresh .. "/ci/testdata/portable"))
    assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
    assert(Fs.write(fresh .. "/o/build.db", "db"))
    assert(Fs.write(fresh .. "/ci/testdata/portable/work_db_integrity.tl", "\n"))
    local executable = diagnostics .. "/cosmic-portable"
    Fixture.write(executable, [[#!/bin/sh
if [ "$1" = test ]; then printf '%s\n' "$*" > "$SEEN.words"; env > "$SEEN.env"; fi
exit 0
]], 493)
    assert(Fs.write(diagnostics .. "/portable-artifact.before.sha256",
      Hash.hex_sha256((assert(Fs.read(executable)))) .. "\n"))
    local seen = fake .. "-seen"
    local outcome = Fixture.call("portable-" .. case.event,
      append(base, { "platform", "portable" }), project, tmp .. "/logs",
      context(fake, runner_temp, {
        TARGET = "x86_64-linux-musl", SEEN = seen,
        COSMIC_CI_EVENT = case.event, COSMIC_CI_REQUIRE_SANDBOX = "1",
        COSMIC_CI_HARNESS_MOVED = "0",
        COSMIC_VERDICT_CACHE = runner_temp .. "/verdicts/verdicts.db",
        XDG_CACHE_HOME = tmp .. "/cache",
      }))
    assert(outcome.result.ok, case.event .. ": the portable phase failed: " ..
      Fixture.read(outcome.err))
    assert(Fs.read(seen .. ".words") == case.words, case.event .. ": " ..
      tostring((Fs.read(seen .. ".words"))))
    local env: {string:string} = {}
    for line in (assert(Fs.read(seen .. ".env"))):gmatch("[^\n]+") do
      local name, value = line:match("^([^=]+)=(.*)$")
      if name then env[name] = value end
    end
    assert(env.COSMIC_VERDICT_CACHE == runner_temp .. "/verdicts/portable.db",
      case.event .. ": " .. tostring(env.COSMIC_VERDICT_CACHE))
    assert((env.COSMIC_TEST_NO_SHARED == "1") == case.shared,
      case.event .. ": COSMIC_TEST_NO_SHARED=" .. tostring(env.COSMIC_TEST_NO_SHARED))
  end
end

--- The checked suite and the others alike (`suite_run`): the words are
--- decided on the driver's environment, then what names the run is
--- forgotten and the rest is kept.
local function test_a_suite_run_forgets_the_run_after_deciding_its_words()
  local Orchestration = require("cosmic_ci.orchestration")
  local words, env = Orchestration.suite_run({
    GITHUB_RUN_ID = "1", RUNNER_NAME = "r", ACTIONS_RUNTIME_TOKEN = "t",
    CI = "true", HOSTNAME = "4f1c", COSMIC_CI_SCOPE = "light",
    COSMIC_CI_EVENT = "push", COSMIC_CI_REQUIRE_SANDBOX = "1",
    HOME = "/home/runner", COSMIC_WORKER = "w",
  })
  assert(table.concat(words, " ") == "test", "a Linux push's run ran --all")
  for _, name in ipairs({ "GITHUB_RUN_ID", "RUNNER_NAME", "ACTIONS_RUNTIME_TOKEN",
      "CI", "HOSTNAME", "COSMIC_CI_SCOPE", "COSMIC_CI_EVENT" }) do
    assert(env[name] == nil, "the suite was given " .. name)
  end
  assert(env.COSMIC_CI_REQUIRE_SANDBOX == "1" and env.HOME == "/home/runner" and
    env.COSMIC_WORKER == "w" and env.FUZZ_ITERS == "0")
  local all, all_env = Orchestration.suite_run({
    COSMIC_CI_EVENT = "schedule", COSMIC_CI_REQUIRE_SANDBOX = "1" })
  assert(table.concat(all, " ") == "test --all" and
    all_env.COSMIC_TEST_NO_SHARED == "1", "main's scheduled run")
end

--- The macOS leg's suites (COSMIC_CI_DECLARED_KEYS=1, no sandbox) stand
--- on shared verdicts in a push's run and the merge queue's, keyed by
--- what each test declares (COSMIC_TEST_KEY=declared): an unsandboxed
--- run keyed by what it read shares none, so without the switch the
--- leg would run every test there. Its scheduled run runs every test
--- and stands on none, and a fixture, which shares no verdict, is keyed
--- as it always was. A Linux leg is given no switch: sandboxed, it keys
--- by declarations already.
local function test_the_macos_leg_stands_on_verdicts_keyed_by_declarations(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  for _, event in ipairs({ "push", "merge_group" }) do
    local words, env = Orchestration.suite_run({
      COSMIC_CI_EVENT = event, COSMIC_CI_REQUIRE_SANDBOX = "0", COSMIC_CI_HARNESS_MOVED = "0",
      COSMIC_CI_DECLARED_KEYS = "1", COSMIC_TEST_SANDBOX = "", COSMIC_TEST_KEY = "" })
    assert(table.concat(words, " ") == "test", event .. ": the macOS leg ran --all")
    assert(env.COSMIC_TEST_NO_SHARED == nil, event .. ": the macOS leg stands on no shared verdict")
    assert(env.COSMIC_TEST_KEY == "declared", event .. ": COSMIC_TEST_KEY=" ..
      tostring(env.COSMIC_TEST_KEY))
    assert(env.COSMIC_CI_DECLARED_KEYS == nil, event .. ": the suite was given the driver's switch")
    assert((env.COSMIC_TEST_SANDBOX or "") == "" and env.COSMIC_SANDBOX ~= "must",
      event .. ": the macOS leg's suite was held to a sandbox")
    local _, linux = Orchestration.suite_run({
      COSMIC_CI_EVENT = event, COSMIC_CI_REQUIRE_SANDBOX = "1",
      COSMIC_CI_DECLARED_KEYS = "0", COSMIC_TEST_KEY = "" })
    assert((linux.COSMIC_TEST_KEY or "") == "", event .. ": a Linux leg was given COSMIC_TEST_KEY")
  end
  local all, scheduled = Orchestration.suite_run({ COSMIC_CI_EVENT = "schedule",
    COSMIC_CI_REQUIRE_SANDBOX = "0", COSMIC_CI_DECLARED_KEYS = "1" })
  assert(table.concat(all, " ") == "test --all" and scheduled.COSMIC_TEST_NO_SHARED == "1",
    "the macOS leg's scheduled run")
  local _, pushed = Orchestration.suite_run({ COSMIC_CI_EVENT = "push",
    COSMIC_CI_REQUIRE_SANDBOX = "0", COSMIC_CI_DECLARED_KEYS = "1" })
  local fixture = Orchestration.fixture(pushed, tmp .. "/tmp")
  assert(fixture.COSMIC_TEST_KEY == nil, "a fixture was keyed by declarations")
  assert(fixture.COSMIC_TEST_NO_SHARED == "1" and fixture.COSMIC_VERDICT_CACHE == "0")
end

--- The files that name a variable a suite forgets, each with the ones
--- it may name, and why: it sets the variable itself, in its own
--- child's environment, or names it only as ci.yml's text, which it
--- reads. Any other such name in them is found as in any other file.
local sets_what_it_reads: {string:{string:boolean}} = {
  ["build/leg_host_id_test.tl"] = { GITHUB_ENV = true, GITHUB_OUTPUT = true },
  ["build/place_tree_test.tl"] = { GITHUB_SHA = true, GITHUB_WORKSPACE = true },
  -- As the platform job's env sets it.
  ["build/workflows_test.tl"] = { COSMIC_CI_DECLARED_KEYS = true },
}

--- No tree source names a variable a gating suite's workers are not
--- given (`Orchestration.forget_run`) but one that sets it itself
--- (`sets_what_it_reads`): a test that read one would find it unset in
--- CI. A new one is kept out of `forget_run` or set by the test.
local function test_no_tree_source_reads_what_a_suite_forgets()
  local Orchestration = require("cosmic_ci.orchestration")
  local root = checkout_root()
  local found: {string} = {}
  for _, dir in ipairs({ "build", "cosmic", "core", "test", "eval", "cmd", "doc" }) do
    for _, path in ipairs((assert(Fs.walk(root .. "/" .. dir)))) do
      local relative = dir .. "/" .. path
      local allowed = sets_what_it_reads[relative] or {}
      if relative:match("%.tl$") or relative:match("%.lua$") or
          relative:match("%.[ch]$") then
        local names: {string:string} = {}
        for name in (assert(Fs.read(root .. "/" .. relative))):gmatch("[%u%d_]+") do
          -- CI is a word of prose too often to tell a read of it.
          if name ~= "CI" then names[name] = name end
        end
        local kept: {string:string} = {}
        for name, value in pairs(names) do kept[name] = value end
        Orchestration.forget_run(kept)
        for name in pairs(names) do
          if kept[name] == nil and not allowed[name] then
            found[#found + 1] = relative .. ": " .. name
          end
        end
      end
    end
  end
  assert(#found == 0, "a tree source names a variable a suite forgets: " ..
    table.concat(found, ", "))
end
