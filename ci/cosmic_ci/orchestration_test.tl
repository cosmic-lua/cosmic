local BuildPaths = require("cosmic_ci.build_paths")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local Hash = require("cosmic.hash")
local CiWorkflow = require("cosmic_ci.ci_workflow")
local Proc = require("cosmic.proc")
local Shape = require("cosmic.shape")
local Fixture = require("cosmic_ci.fixture")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local State = require("cosmic_ci.state")
local Test = require("cosmic.test")

-- The driver's namespace, which `command` copies into a project of its
-- own with the system's `cp` (and `git` and `sh` run the fixtures); the
-- fixture modules, whose sources [`code_of`] reads; the one testdata
-- file a fixture checkout takes a copy of; and the workflow the tests
-- read of the checkout around ci/.
Test.policy{
  profiles = { "cosmic", "system" },
  grants = {
    { path = "cosmic_ci/", letters = "r" },
    { path = "fixtures/", letters = "r" },
    { path = "o/bin", letters = "rx" },
    { path = "testdata/portable/work_db_integrity.tl", letters = "r" },
    { path = "/parent/.github/workflows/ci.yml", letters = "r" },
  },
}

--- One case of a test that runs the driver over a fixture: a named
--- scenario and what it is to answer, one record for each test that
--- tables them.
local record SandboxCase
  name: string
  said: string
  require: string
  ok: boolean
end
local record StandsCase
  event: string
  stands: boolean
end
local record FormatCase
  name: string
  switch: string
  ok: boolean
  ran: boolean
end
local record BoundaryCase
  name: string
  immediate: boolean
  boundary: boolean
  ran: boolean
end
local record NativeCase
  name: string
  broken: boolean
end
local record PortableCase
  event: string
  words: string
  shared: boolean
end
local record ShareAttestationCase
  name: string
  shares: string
  --- The share job's artifact: absent where it uploaded none.
  upload: boolean
  --- Its attestation text, else the legs' digest's.
  attestation?: string
  --- Its bytes: another build's where true.
  changed?: boolean
  --- The shares the alpine leg and the job name.
  leg_half?: string
  half?: string
  ok: boolean
end
local record AttestCase
  name: string
  total: string
  shares: string
  --- The share the portable phase recorded.
  ran?: string
  expected?: string
end
local record PortableShareCase
  name: string
  shard: string
  words: string
end
local record DarwinCase
  name: string
  target: string
  event: string
  sandbox: string
  ran: string
  suites: string
  ok: boolean
  stood: integer
end
local record ChecksCase
  name: string
  target: string
  report: boolean
  status: integer
  ok: boolean
  ran?: string
  --- The compile wrote no check (the summary says 0 fact wraps), though the run is checked.
  empty?: boolean
  share?: string
  --- Added to the run's environment: what a job that restores verdicts sets.
  env?: {string:string}
end

--- `Orchestration.harness_moved`, its answer as two values.
local function harness_moved(root: string, base: string): boolean, string
  local Orchestration = require("cosmic_ci.orchestration")
  local judged = Orchestration.harness_moved(root, base)
  return judged.moved, judged.why
end

--- `Orchestration.suite_run`, its answer as two values.
local function suite_run(extra?: {string:string}): {string}, {string:string}
  local Orchestration = require("cosmic_ci.orchestration")
  local run = Orchestration.suite_run(extra)
  return run.words, run.env
end

--- `Orchestration.fixture_lanes`, the two lanes as two values.
local function fixture_lanes(env: {string:string}, cpus: integer): integer?, integer?
  local Orchestration = require("cosmic_ci.orchestration")
  local lanes = Orchestration.fixture_lanes(env, cpus)
  return lanes.high, lanes.low
end

--- The self-check holds a write transaction on `ci/`'s `build.db` while
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

--- Synthetic candidates keep their selected physical output layout. The resolver is a script the pinned release runs
--- in the new grammar, as it is in the tree.
local function build_resolver(root: string)
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/paths.tl", "local Fs = require(\"cosmic.fs\")\nlocal record Paths\n  main: function(argv: {string}): integer\nend\nfunction Paths.main(argv: {string}): integer\n  assert(Fs.put(Fs.stdout, assert(argv[1]) .. \"/o\\n\"))\n  return 0\nend\nreturn Paths\n"))
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
  if Fs.exists(candidate .. "/AGENTS.md") == true then build_resolver(candidate) end
  local env: mut {string:string} = {
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
  if extra then
    for name, value in pairs(extra) do env[name] = value end
  end
  return env
end

local function append(base: {string}, values: {string}): {string}
  local out: mut {string} = {}
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
  -- The lanes' tools differ in the checkout each was built in, and agree on the rest.
  for _, name in ipairs({ "a", "b" }) do
    local product = template .. "/portable-product-" .. name
    assert(Fs.mkdirs(product))
    assert(Fs.write(product .. "/cosmic", Fixture.synthetic(tmp .. "/lane.db", "/runner-" .. name .. "/cosmic")))
    local digest = Hash.hex_sha256(Fixture.stripped(product .. "/cosmic", tmp .. "/lane.db"))
    assert(Fs.write(product .. "/executed-cosmic.sha256", digest .. "  cosmic\n") and
        Fs.write(product .. "/expected-platforms", "2\n"))
  end

  -- Each scenario gets its own RUNNER_TEMP: the operations database and
  -- the products directory both live under it.
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
    Fixture.synthetic(tmp .. "/lane.db", "/runner-b/cosmic", "changed")))
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

  -- No product to compare is told so, rather than counted in a message
  -- built before the check.
  local empty_runner_temp = tmp .. "/empty-runner-temp"
  assert(Fs.mkdirs(empty_runner_temp .. "/cosmic-ci/products"))
  local empty = Fixture.call("empty-provenance", append(base, { "provenance" }), project,
    tmp .. "/logs", context(candidate, empty_runner_temp))
  assert(not empty.result.ok)
  assert(assert(Fs.read(empty.err)):find("no product to compare", 1, true) ~= nil)

  local missing_runner_temp = seeded_runner_temp("missing")
  assert(Fs.remove(
    missing_runner_temp .. "/cosmic-ci/products/portable-product-b/executed-cosmic.sha256"))
  assert(not Fixture.call("missing-attestation", append(base, { "provenance" }), project,
    tmp .. "/logs", context(candidate, missing_runner_temp)).result.ok)
end

--- The job that runs another share of a leg's portable suite uploads the
--- bytes it ran with their attestation (`portable-share-<job>`), which
--- the join hashes and holds to the legs' digest: as many as it is told to
--- expect (COSMIC_CI_PORTABLE_SHARES) must be there, and together with the
--- leg they must name each share of the suite exactly once.
local function test_provenance_holds_a_portable_share_to_the_legs_bytes(tmp: string)
  local base, project = command(tmp)
  local candidate = tmp .. "/candidate"
  assert(Fs.mkdirs(candidate))
  assert(Fs.write(candidate .. "/AGENTS.md", "fixture\n"))
  local template = tmp .. "/products-template"
  assert(Fs.mkdirs(template))
  local digest = ""
  for _, name in ipairs({ "a", "b" }) do
    local product = template .. "/portable-product-" .. name
    assert(Fs.mkdirs(product))
    assert(Fs.write(product .. "/cosmic", Fixture.synthetic(tmp .. "/lane.db", "/runner-" .. name .. "/cosmic")))
    digest = Hash.hex_sha256(Fixture.stripped(product .. "/cosmic", tmp .. "/lane.db"))
    assert(Fs.write(product .. "/executed-cosmic.sha256", digest .. "  cosmic\n") and
        Fs.write(product .. "/expected-platforms", "2\n"))
  end
  local good = digest .. "  cosmic\n"
  local cases: {ShareAttestationCase} = {
    { name = "same", shares = "1", upload = true, leg_half = "1/2", half = "2/2", ok = true },
    { name = "none-expected", shares = "0", upload = false, ok = true },
    { name = "different", shares = "1", upload = true, attestation = string.rep("0", 64) .. "  cosmic\n",
      leg_half = "1/2", half = "2/2", ok = false },
    { name = "corrupt", shares = "1", upload = true, attestation = "corrupt\n", leg_half = "1/2", half = "2/2", ok = false },
    { name = "bytes-disagree", shares = "1", upload = true, attestation = good, changed = true,
      leg_half = "1/2", half = "2/2", ok = false },
    { name = "missing", shares = "1", upload = false, leg_half = "1/2", ok = false },
    { name = "unexpected", shares = "0", upload = true, half = "2/2", ok = false },
    { name = "duplicate-half", shares = "1", upload = true, leg_half = "1/2", half = "1/2", ok = false },
    { name = "missing-half", shares = "1", upload = true, half = "2/2", ok = false },
    { name = "unnamed-half", shares = "1", upload = true, leg_half = "1/2", ok = false },
    { name = "other-count", shares = "1", upload = true, leg_half = "1/3", half = "2/3", ok = false },
  }
  for _, case in ipairs(cases) do
    local runner_temp = tmp .. "/" .. case.name .. "-runner-temp"
    assert(Fs.mkdirs(runner_temp .. "/cosmic-ci"))
    assert(assert(Child.run({ "/bin/cp", "-R", template, runner_temp .. "/cosmic-ci/products" })).ok)
    local products = runner_temp .. "/cosmic-ci/products"
    if case.leg_half ~= nil then
      assert(Fs.write(products .. "/portable-product-a/portable-share", case.leg_half .. "\n"))
    end
    if case.upload then
      local dir = products .. "/portable-share-s"
      assert(Fs.mkdirs(dir))
      assert(Fs.write(dir .. "/cosmic", Fixture.synthetic(tmp .. "/lane.db", "/runner-s/cosmic",
        if case.changed == true then "changed" else nil end)))
      assert(Fs.write(dir .. "/executed-cosmic.sha256", case.attestation or good))
      if case.half ~= nil then assert(Fs.write(dir .. "/portable-share", case.half .. "\n")) end
    end
    local outcome = Fixture.call("share-" .. case.name, append(base, { "provenance" }), project,
      tmp .. "/logs", context(candidate, runner_temp, { COSMIC_CI_PORTABLE_SHARES = case.shares }))
    assert(outcome.result.ok == case.ok, case.name .. ": the join answered " ..
        tostring(outcome.result.ok) .. ": " .. Fixture.read(outcome.err))
  end
end

--- The legs' `attest` writes the number of products to expect, the job
--- count (`strategy.job-total`) less the jobs that run a share of a
--- leg's portable suite and upload none (COSMIC_CI_PORTABLE_SHARES), so
--- that prerelease.yml still finds its four lanes.
local function test_attest_expects_the_products_without_the_share_jobs(tmp: string)
  local base, project = command(tmp)
  local cases: {AttestCase} = {
    { name = "whole", total = "4", shares = "", expected = "4\n" },
    { name = "shared", total = "5", shares = "1", ran = "2/2\n", expected = "4\n" },
    { name = "all-shares", total = "5", shares = "5" },
  }
  for _, case in ipairs(cases) do
    local fake = tmp .. "/attest-" .. case.name
    local runner_temp = fake .. "-runner-temp"
    local work = runner_temp .. "/cosmic-ci/platform"
    local product = work .. "/product"
    local diagnostics = work .. "/portable-diagnostics"
    assert(Fs.mkdirs(fake) and Fs.mkdirs(product) and Fs.mkdirs(diagnostics))
    assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
    local built = Fixture.synthetic(tmp .. "/attest.db", "/runner/cosmic")
    local portable = Fixture.synthetic(tmp .. "/attest.db", "/fresh/cosmic")
    local digest = Hash.hex_sha256(built) .. "\n"
    local executed = Hash.hex_sha256(portable) .. "\n"
    assert(Fs.write(product .. "/cosmic", built) and Fs.write(work .. "/cosmic.before.sha256", digest))
    assert(Fs.write(diagnostics .. "/cosmic-portable", portable) and
        Fs.write(diagnostics .. "/portable-artifact.before.sha256", executed) and
        Fs.write(diagnostics .. "/portable-artifact.after.sha256", executed))
    if case.ran ~= nil then assert(Fs.write(diagnostics .. "/portable-share", case.ran)) end
    local outcome = Fixture.call("attest-" .. case.name, append(base, { "platform", "attest", case.total }),
      project, tmp .. "/logs", context(fake, runner_temp, {
        TARGET = "x86_64-linux-musl", COSMIC_CI_PORTABLE_SHARES = case.shares,
      }))
    assert(outcome.result.ok == (case.expected ~= nil), case.name .. ": attest answered " ..
        tostring(outcome.result.ok) .. ": " .. Fixture.read(outcome.err))
    if case.expected ~= nil then
      assert(Fs.read(product .. "/expected-platforms") == case.expected, case.name .. ": expected " ..
          tostring((Fs.read(product .. "/expected-platforms"))))
      assert(Fs.read(product .. "/portable-share") == (case.ran or "none\n"), case.name .. ": the share attested is " ..
          tostring((Fs.read(product .. "/portable-share"))))
    end
  end
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
  Fixture.copy("testdata/portable/work_db_integrity.tl",
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

  -- The work directory is derived from RUNNER_TEMP, so pointing
  -- RUNNER_TEMP inside the candidate exercises the "work directory inside
  -- the candidate is refused" protection. RUNNER_TEMP itself always
  -- exists in CI, so the test creates it too. The refusal must leave it
  -- exactly as empty as it found it: nothing, not even the scratch
  -- directory, is created before the boundary check runs.
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
    }), Clock.seconds(20))
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
  local cases: {SandboxCase} = {
    { name = "unavailable", said = "Confinement: **unavailable** (unveil).", require = "1", ok = false },
    { name = "available", said = "Confinement: available.", require = "1", ok = true },
    { name = "unrequired", said = "Confinement: **unavailable** (unveil).", require = "", ok = true },
  }
  for _, case in ipairs(cases) do
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
    Fixture.contains(summary, if case.require == "1" then "switch=1 mode=must." else "switch= mode=." end)
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
    local plain = if event == "merge_group" then "test --bail" else "test" end
    assert(Orchestration.stands(linux) and words(linux) == plain, event)
    local mac = { COSMIC_CI_REQUIRE_SANDBOX = "0", COSMIC_CI_DECLARED_KEYS = "1",
      COSMIC_CI_EVENT = event, COSMIC_CI_HARNESS_MOVED = "0" }
    assert(Orchestration.stands(mac) and words(mac) == plain, "macOS " .. event)
    local neither = { COSMIC_CI_REQUIRE_SANDBOX = "0", COSMIC_CI_DECLARED_KEYS = "0",
      COSMIC_CI_EVENT = event }
    assert(not Orchestration.stands(neither) and words(neither) == (plain:gsub("test", "test --all", 1)),
      "a leg that neither sandboxes nor keys by declarations, " .. event)
  end
  for _, event in ipairs({ "workflow_dispatch", "schedule", "pull_request", "" }) do
    for _, leg in ipairs({ "COSMIC_CI_REQUIRE_SANDBOX", "COSMIC_CI_DECLARED_KEYS" }) do
      local env: mut {string:string} = {}
      env[leg] = "1"
      env["COSMIC_CI_EVENT"] = event
      assert(not Orchestration.stands(env) and words(env) == "test --all", leg .. " " .. event)
    end
  end
  assert(not Orchestration.stands({}), "run-local, and any run that names no event")
  -- Standing, it may stand on what another run reached; else not.
  local queued: {string:string} = { COSMIC_CI_REQUIRE_SANDBOX = "1", COSMIC_CI_EVENT = "merge_group",
    COSMIC_CI_HARNESS_MOVED = "0" }
  queued = Orchestration.shares(queued)
  assert(queued["COSMIC_TEST_NO_SHARED"] == nil, "the merge queue")
  local scheduled: {string:string} = { COSMIC_CI_REQUIRE_SANDBOX = "1", COSMIC_CI_EVENT = "schedule" }
  scheduled = Orchestration.shares(scheduled)
  assert(scheduled["COSMIC_TEST_NO_SHARED"] == "1", "main's scheduled run")
  -- A merge queue run whose change moves the harness's epoch file, or
  -- that cannot tell, stands on nothing; a push's is not asked.
  for _, moved in ipairs({ "1", "" }) do
    local harness: mut {string:string} = { COSMIC_CI_REQUIRE_SANDBOX = "1",
      COSMIC_CI_EVENT = "merge_group" }
    if moved ~= "" then harness["COSMIC_CI_HARNESS_MOVED"] = moved end
    assert(not Orchestration.stands(harness) and words(harness) == "test --all --bail",
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
--- what it checks ([`harness_moved`]): a change that leaves it runs what
--- its keys moved, one that moves it every test ([`suite_run`]), and one
--- whose base it cannot read or that names none every test too.
local function test_a_merge_queue_run_that_moves_the_epoch_runs_every_test(tmp: string)
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
  assert(not harness_moved(root, assert(base)), "a change that leaves the file")
  local function queued(sha: string): string
    local words = suite_run({ COSMIC_CI_EVENT = "merge_group",
      COSMIC_CI_REQUIRE_SANDBOX = "1", GITHUB_WORKSPACE = root, COSMIC_CI_BASE_SHA = sha })
    return table.concat(words, " ")
  end
  assert(queued(assert(base)) == "test --bail", "a merge queue run that leaves the epoch ran --all")
  assert(Fs.write(root .. "/build/harness_epoch.tl", "epoch 2\n"))
  git(root, { "commit", "--quiet", "-am", "bump" })
  assert(harness_moved(root, assert(base)), "a change that moves the file")
  -- Asked of another checkout, as the answer is kept by checkout and base.
  local moved = tmp .. "/moved"
  git(tmp, { "clone", "--quiet", root, moved })
  assert(queued(assert(base)) == "test --bail", "the first answer was not kept")
  local words = suite_run({ COSMIC_CI_EVENT = "merge_group",
    COSMIC_CI_REQUIRE_SANDBOX = "1", GITHUB_WORKSPACE = moved, COSMIC_CI_BASE_SHA = base })
  assert(table.concat(words, " ") == "test --all --bail", "a merge queue run that moves the epoch")
  -- A base it cannot read, or none, is taken as a move.
  local unread, why = harness_moved(root, string.rep("0", 40))
  assert(unread and why:find("git ", 1, true) ~= nil, "a base that is no commit: " .. why)
  assert(harness_moved(root, ""), "no base")
  assert(harness_moved(tmp .. "/none", assert(base)), "no checkout")
  -- ci.yml names the base, and checks out the merge's parent with it.
  local text = assert(Fs.read(Test.parent(".github/workflows/ci.yml")))
  local platform = assert(CiWorkflow.parse(text).jobs["platform"])
  local env = assert(platform.env)
  assert(env["COSMIC_CI_BASE_SHA"] == "${{ github.event.merge_group.base_sha || needs.scope.outputs.base }}",
    "ci.yml's platform job names no merge queue base: " .. tostring(env["COSMIC_CI_BASE_SHA"]))
end

--- A branch push that runs the queue's scope (ci.yml's `scope` job gives
--- it its merge base with main as COSMIC_CI_BASE_SHA) decides the harness
--- as the queue does, so a change that moves build/harness_epoch.tl runs
--- every test on the branch, and one that leaves it stands on verdicts,
--- as the queue's run of it will. A base it could not name (`unknown`)
--- is a move. A push naming none (main's, or a light branch run's) is
--- not asked, and is never `--bail`ed: only the queue's run is.
local function test_a_full_branch_push_decides_the_harness_as_the_merge_queue_does(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  local root = tmp .. "/checkout"
  assert(Fs.mkdirs(root .. "/build"))
  git(root, { "init", "--quiet" })
  assert(Fs.write(root .. "/build/harness_epoch.tl", "epoch 1\n"))
  git(root, { "add", "." })
  git(root, { "commit", "--quiet", "-m", "main" })
  local base = assert(git(root, { "rev-parse", "HEAD" }):match("^(%x+)"))
  assert(Fs.write(root .. "/README", "branch\n"))
  git(root, { "add", "." })
  git(root, { "commit", "--quiet", "-m", "branch, harness untouched" })
  assert(Orchestration.against_a_base({ COSMIC_CI_EVENT = "push", COSMIC_CI_BASE_SHA = base }))
  assert(Orchestration.against_a_base({ COSMIC_CI_EVENT = "merge_group" }))
  for _, event in ipairs({ "push", "schedule", "workflow_dispatch", "" }) do
    assert(not Orchestration.against_a_base({ COSMIC_CI_EVENT = event, COSMIC_CI_BASE_SHA = "" }), event)
  end
  assert(not Orchestration.against_a_base({ COSMIC_CI_EVENT = "schedule", COSMIC_CI_BASE_SHA = base }))
  local unasked: {string:string} = { COSMIC_CI_EVENT = "push", COSMIC_CI_REQUIRE_SANDBOX = "1",
    GITHUB_WORKSPACE = root }
  assert(table.concat(Orchestration.suite_run(unasked).words, " ") == "test" and unasked["COSMIC_CI_HARNESS_MOVED"] == nil,
    "a push naming no base is asked")
  local left = Orchestration.suite_run({ COSMIC_CI_EVENT = "push", COSMIC_CI_REQUIRE_SANDBOX = "1",
    GITHUB_WORKSPACE = root, COSMIC_CI_BASE_SHA = base }).words
  assert(table.concat(left, " ") == "test", "a branch push that leaves the epoch ran --all")
  assert(Fs.write(root .. "/build/harness_epoch.tl", "epoch 2\n"))
  git(root, { "commit", "--quiet", "-am", "bump" })
  -- Asked of another checkout: the answer is kept by checkout and base.
  local moved = tmp .. "/moved"
  git(tmp, { "clone", "--quiet", root, moved })
  local words = Orchestration.suite_run({ COSMIC_CI_EVENT = "push", COSMIC_CI_REQUIRE_SANDBOX = "1",
    GITHUB_WORKSPACE = moved, COSMIC_CI_BASE_SHA = base }).words
  assert(table.concat(words, " ") == "test --all", "a branch push that moves the epoch: " .. table.concat(words, " "))
  local unknown = Orchestration.suite_run({ COSMIC_CI_EVENT = "push", COSMIC_CI_REQUIRE_SANDBOX = "1",
    GITHUB_WORKSPACE = moved, COSMIC_CI_BASE_SHA = "unknown" }).words
  assert(table.concat(unknown, " ") == "test --all", "a base the scope job could not name stands on verdicts")
end

--- The portable suite keeps its verdicts in the native suite's file,
--- the one the driver names, and none where the driver names no
--- absolute path or turns the cache off.
local function test_the_portable_suite_shares_the_native_suites_verdicts()
  local Orchestration = require("cosmic_ci.orchestration")
  for shared, portable in pairs({
      ["/runner/_temp/verdicts/verdicts.db"] = "/runner/_temp/verdicts/verdicts.db",
      ["/verdicts.db"] = "/verdicts.db",
      ["0"] = "0", [""] = "0", ["verdicts.db"] = "0",
  }) do
    local said = Orchestration.suite_verdicts({ COSMIC_VERDICT_CACHE = shared }, "portable")
    assert(said == portable, shared .. ": " .. said)
  end
  assert(Orchestration.suite_verdicts({}, "portable") == "0", "unset")
end

--- The checked suite keeps a file of its own, apart from the local and
--- portable suites' shared one.
local function test_the_checked_suite_keeps_verdicts_of_its_own()
  local Orchestration = require("cosmic_ci.orchestration")
  local shared = { COSMIC_VERDICT_CACHE = "/runner/_temp/verdicts/verdicts.db" }
  assert(Orchestration.suite_verdicts(shared, "checked") ==
      "/runner/_temp/verdicts/checked.db")
  assert(Orchestration.suite_verdicts({ COSMIC_VERDICT_CACHE = "0" }, "checked") == "0")
end

--- A fixture outside `sandboxed_fixtures` reads inputs its environment
--- names (COSMIC_FIXTURE_*), which no verdict's key holds, so it stands
--- on no verdict another run reached, and keeps none for one, even in a
--- Linux branch push's run, where every other suite shares them. Its
--- compiles are the file the leg's fixtures share with one another
--- alone, not the leg's cache, which ci.yml saves.
local function test_an_unsandboxed_fixture_neither_reads_nor_writes_shared_verdicts(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  local env: {string:string} = { COSMIC_CI_REQUIRE_SANDBOX = "1", COSMIC_CI_EVENT = "push",
    COSMIC_TEST_SANDBOX = "1", COSMIC_VERDICT_CACHE = tmp .. "/verdicts.db",
    COSMIC_BUILD_CACHE = tmp .. "/build.db", COSMIC_FIXTURE_SOURCE = tmp .. "/source" }
  env = Orchestration.shares(env)
  assert(env["COSMIC_TEST_NO_SHARED"] == nil, "a Linux push's suite stands on shared verdicts")
  local fixture = Orchestration.fixture(env, tmp .. "/tmp", tmp .. "/fixture-compiles.db")
  assert(fixture["COSMIC_VERDICT_CACHE"] == "0", "the fixture may keep shared verdicts")
  assert(fixture["COSMIC_BUILD_CACHE"] == tmp .. "/fixture-compiles.db",
    "the fixture shares the leg's compiles, not its fixtures' own")
  assert(fixture["COSMIC_TEST_NO_SHARED"] == "1", "the fixture may stand on shared verdicts")
  assert(fixture["COSMIC_TEST_SANDBOX"] == "0" and fixture["TMPDIR"] == tmp .. "/tmp")
  assert(fixture["COSMIC_FIXTURE_SOURCE"] == tmp .. "/source")
end

--- The self-rebuild fixture's seed is a copy of the leg's compiles,
--- where COSMIC_BUILD_CACHE names them or, unnamed, in the cache
--- directory, rows still in the WAL among them; a leg that keeps none
--- (`0`, or no file) is refused rather than seeded with nothing, as is
--- one a build would refuse to read (a relative path, a file others may
--- write), and a seed already there is never written over.
local function test_the_self_rebuild_seed_copies_the_legs_compiles(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  local function cache_at(path: string): Sqlite.Handle
    assert(Fs.mkdirs(Fs.dirname(path)))
    local db = assert(Sqlite.open(path, { writable = true }))
    assert(db:exec("PRAGMA journal_mode = WAL"))
    assert(db:exec("CREATE TABLE compiles (key TEXT); INSERT INTO compiles VALUES ('" ..
        path .. "')"))
    return db
  end
  local function seeded_from(path: string): string
    local db = assert(Sqlite.open(path))
    local rows = assert(Sqlite.text_rows(db, "SELECT key FROM compiles"))
    assert(db:close())
    assert(#rows == 1, path .. ": " .. tostring(#rows) .. " rows")
    return assert(rows[1]):text(1)
  end

  local named = tmp .. "/named/cache.db"
  -- Left open while it is copied, so its row is in the WAL alone.
  local named_db = cache_at(named)
  assert(Fs.exists(named .. "-wal"), "the cache's row is not in its WAL")
  assert(Orchestration.seed_compiles({ COSMIC_BUILD_CACHE = named }, tmp .. "/one.db"))
  assert(seeded_from(tmp .. "/one.db") == named)
  local again, again_trouble = Orchestration.seed_compiles({ COSMIC_BUILD_CACHE = named },
    tmp .. "/one.db")
  assert(not again and again_trouble:find("already exists", 1, true) ~= nil, again_trouble)
  assert(named_db:close())

  local default = tmp .. "/xdg/cosmic/build/cache.db"
  assert(cache_at(default):close())
  assert(Orchestration.seed_compiles({ XDG_CACHE_HOME = tmp .. "/xdg" }, tmp .. "/two.db"))
  assert(seeded_from(tmp .. "/two.db") == default)

  local off, off_trouble = Orchestration.seed_compiles({ COSMIC_BUILD_CACHE = "0" },
    tmp .. "/three.db")
  assert(not off and off_trouble:find("COSMIC_BUILD_CACHE=0", 1, true) ~= nil, off_trouble)
  local missing, missing_trouble = Orchestration.seed_compiles(
    { COSMIC_BUILD_CACHE = tmp .. "/missing.db" }, tmp .. "/four.db")
  assert(not missing and missing_trouble:find(tmp .. "/missing.db", 1, true) ~= nil, missing_trouble)
  local relative, relative_trouble = Orchestration.seed_compiles(
    { COSMIC_BUILD_CACHE = "named/cache.db" }, tmp .. "/five.db")
  assert(not relative and relative_trouble:find("absolute", 1, true) ~= nil, relative_trouble)
  assert(Fs.chmod(default, 0x1b4))
  local shared, shared_trouble = Orchestration.seed_compiles(
    { COSMIC_BUILD_CACHE = default }, tmp .. "/six.db")
  assert(not shared and shared_trouble:find("writable by its group", 1, true) ~= nil, shared_trouble)
  local a_dir, a_dir_trouble = Orchestration.seed_compiles(
    { COSMIC_BUILD_CACHE = tmp .. "/named" }, tmp .. "/seven.db")
  assert(not a_dir and a_dir_trouble:find("/named: not a file", 1, true) ~= nil, a_dir_trouble)
  local under_file, under_file_trouble = Orchestration.seed_compiles(
    { COSMIC_BUILD_CACHE = default .. "/cache.db" }, tmp .. "/eight.db")
  assert(not under_file and under_file_trouble:find("cache.db: not a directory", 1, true) ~= nil,
    under_file_trouble)
  for _, name in ipairs({ "three", "four", "five", "six", "seven", "eight" }) do
    assert(Fs.exists(tmp .. "/" .. name .. ".db") ~= true, name)
  end
end

--- A fixture of `sandboxed_fixtures` runs as the leg's suites do: its
--- workers sandboxed where the leg's are, and its verdicts kept in
--- `fixtures.db` beside the leg's `verdicts.db`, which it stands on
--- where the suites stand on theirs -- a push's run -- and not on a
--- manual one's.
local function test_a_sandboxed_fixture_keeps_verdicts_beside_the_legs(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  local fixtures = Orchestration.suite_verdicts({ COSMIC_VERDICT_CACHE = tmp .. "/v/verdicts.db" },
    "fixtures")
  assert(fixtures == tmp .. "/v/fixtures.db", fixtures)
  local cases: {StandsCase} = { { event = "push", stands = true },
    { event = "workflow_dispatch", stands = false } }
  for _, case in ipairs(cases) do
    local env: {string:string} = { COSMIC_CI_REQUIRE_SANDBOX = "1", COSMIC_CI_EVENT = case.event,
      COSMIC_TEST_SANDBOX = "1", COSMIC_SANDBOX = "must",
      COSMIC_VERDICT_CACHE = tmp .. "/v/verdicts.db", COSMIC_BUILD_CACHE = tmp .. "/build.db" }
    local fixture = Orchestration.fixture(env, tmp .. "/tmp", tmp .. "/fixture-compiles.db",
      fixtures)
    assert(fixture["COSMIC_VERDICT_CACHE"] == fixtures, "the fixture keeps its verdicts apart")
    assert(fixture["COSMIC_TEST_SANDBOX"] == "1" and fixture["COSMIC_SANDBOX"] == "must",
      "the fixture's workers are sandboxed where the leg's are")
    assert((fixture["COSMIC_TEST_NO_SHARED"] == nil) == case.stands, case.event)
    assert(fixture["COSMIC_BUILD_CACHE"] == tmp .. "/fixture-compiles.db")
  end
end

--- What `fixture_run` gives a fixture, on a Linux leg (its suites
--- sandboxed and required to be) and on macOS's (keyed by declaration,
--- no sandbox): one of `sandboxed_fixtures` runs as the leg's suites do
--- and keeps its verdicts in fixtures.db; any other runs unsandboxed and
--- shares none.
local function test_fixture_run_shares_only_a_sandboxed_fixtures_verdicts(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  local legs: {string:{string:string}} = {
    linux = { COSMIC_CI_REQUIRE_SANDBOX = "1", COSMIC_TEST_SANDBOX = "1", COSMIC_SANDBOX = "must" },
    macos = { COSMIC_CI_DECLARED_KEYS = "1" },
  }
  for leg, values in pairs(legs) do
    local function env(): {string:string}
      local out: mut {string:string} = { COSMIC_CI_EVENT = "push",
        COSMIC_VERDICT_CACHE = tmp .. "/v/verdicts.db" }
      for name, value in pairs(values) do out[name] = value end
      return out
    end
    local sandboxed = Orchestration.fixture_run("runtime", env(), tmp .. "/tmp", tmp .. "/c.db")
    assert(sandboxed["COSMIC_VERDICT_CACHE"] == tmp .. "/v/fixtures.db", leg .. ": " ..
        tostring(sandboxed["COSMIC_VERDICT_CACHE"]))
    assert(sandboxed["COSMIC_TEST_NO_SHARED"] == nil, leg .. ": a push's fixture stands on nothing")
    assert(sandboxed["COSMIC_TEST_SANDBOX"] == values["COSMIC_TEST_SANDBOX"],
      leg .. ": the fixture's workers are not held as the leg's are")
    local plain = Orchestration.fixture_run("self_driven", env(), tmp .. "/tmp", tmp .. "/c.db")
    assert(plain["COSMIC_VERDICT_CACHE"] == "0" and plain["COSMIC_TEST_NO_SHARED"] == "1" and
        plain["COSMIC_TEST_SANDBOX"] == "0",
      leg .. ": an unsandboxed fixture shares verdicts")
  end
end

--- The source of the fixture module `source` with its comments taken
--- out, so a path commented out of a declaration is none of it.
local function code_of(source: string): string
  local text = Fixture.read("fixtures/" .. source .. "_test.tl")
  return (text:gsub("%-%-[^\n]*", ""))
end

--- The tree paths the declaration of the fixture module `source` reads: the
--- grants of its [`Test.policy`].
local function declared_reads(source: string): {string:boolean}
  local code = code_of(source)
  local out: mut {string:boolean} = {}
  local policy = assert(code:match("\nTest%.policy%s*%(?%s*(%b{})"), source .. ": no Test.policy")
  local grants = assert(policy:match("grants%s*=%s*(%b{})"), source .. ": no grants")
  for path in grants:gmatch('path%s*=%s*"([^"]*)"') do out[path] = true end
  return out
end

--- A sandboxed fixture's verdict is shared across runs and commits, so
--- its key must hold the parts of the product it exercises: each
--- normally declares the product's `prefix` -- its launcher, manifest and cores --
--- at the path the driver placed it, which keys the verdict by those
--- bytes, and no other launcher's or core's verdict stands for it; and
--- `product`, which checks the whole product, declares each of its
--- files, while no other declares the product's `cosmic` or `cosmic.db`,
--- which it does not run. The performance fixture instead declares its
--- entire candidate program and controller source: it exercises the carried
--- database too. Each
--- unsandboxed one names each variable it and its children read
--- ([`Fixture.inherited`] and the COSMIC_FIXTURE_* it requires) and
--- declares nothing else but `tool` where it needs it: nothing holds it
--- to a declaration, and it shares no verdict for one to key, but a
--- release that keys every unsandboxed run by declaration gives its
--- worker only the variables it declares. Any fixture that asks
--- cosmic_ci.build_paths for a directory starts the running program on the
--- candidate's build/paths.tl, and so declares `tool`: a worker run on
--- its closure alone lacks that resolver's modules.
local function test_every_sandboxed_fixture_is_keyed_by_the_product(tmp: string)
  local _ = tmp
  local Orchestration = require("cosmic_ci.orchestration")
  local names: mut {string} = {}
  for _, entry in ipairs((assert(Fs.list("fixtures")))) do
    local name = entry:match("^(.*)_test%.tl$")
    if name then names[#names + 1] = name end
  end
  table.sort(names)
  local sandboxed = 0
  for _, name in ipairs(names) do
    local code = code_of(name)
    if code:find("BuildPaths.", 1, true) then
      local policy = assert(code:match("\nTest%.policy%s*%(?%s*(%b{})"), name .. ": no Test.policy")
      assert(policy:find('profiles = { "cosmic" }', 1, true) and
          policy:find('{ path = "o/bin", letters = "rx" }', 1, true),
        name .. ": a fixture that starts the running program on build/paths.tl does not declare tool")
    end
    if Orchestration.sandboxed_fixtures()[name] == true then
      sandboxed = sandboxed + 1
      local host = declared_reads(name)
      if name == "performance" then
        assert(host["o/fixtures/performance/program"] == true and
            host["o/fixtures/performance/perf.tl"] == true,
          "performance fixture must key the full candidate and controller source")
      else
        assert(host["o/fixtures/product/prefix"],
          name .. ": a sandboxed fixture's key does not hold the product's prefix")
      end
      if name ~= "product" then
        for _, whole in ipairs({ "cosmic", "cosmic.db" }) do
          assert(host["o/fixtures/product/" .. whole] ~= true,
            name .. ": a sandboxed fixture that does not check the whole product declares its " ..
              whole .. ", which moves with every edit to the tool's code")
        end
      end
    else
      -- Each variable the fixture requires of the driver (COSMIC_FIXTURE_*,
      -- by its own [`Fixture.required`] or by [`Fixture.source_tree`]), and each
      -- its children inherit, is named, and no other: never the whole
      -- environment.
      local policy = code:match("\nTest%.policy%s*%(?%s*(%b{})")
      assert(policy ~= nil, name .. ": an unsandboxed fixture declares no Test.policy")
      local env = assert(policy:match("env%s*=%s*(%b{})"), name .. ": no env")
      local declared: mut {string:boolean} = {}
      for variable in env:gmatch('"([^"]*)"') do
        assert(variable ~= "*" and variable:match("^[%a][%w_]*$") ~= nil,
          name .. ": an unsandboxed fixture declares the variable " .. variable)
        declared[variable] = true
      end
      local wanted: mut {string:boolean} = {}
      for _, variable in ipairs(Fixture.inherited()) do wanted[variable] = true end
      for variable in code:gmatch('Fixture%.required%("([A-Z_]+)"%)') do wanted[variable] = true end
      if code:find("Fixture.source_tree(", 1, true) then wanted["COSMIC_FIXTURE_SOURCE"] = true end
      for variable in pairs(wanted) do
        assert(declared[variable], name .. ": an unsandboxed fixture does not declare " ..
            variable .. ", which it or its children read")
      end
      for variable in pairs(declared) do
        assert(wanted[variable], name .. ": an unsandboxed fixture declares " .. variable ..
            ", which neither it nor its children read")
      end
    end
  end
  local whole = declared_reads("product")
  for _, part in ipairs({ "cosmic", "hashes.sha256", "prefix", "manifest", "apps/hello",
      "apps/second", "cosmic.db", "targets.tsv" }) do
    assert(whole["o/fixtures/product/" .. part],
      "product: the fixture that checks the whole product does not declare " .. part)
  end
  local listed = 0
  for _ in pairs(Orchestration.sandboxed_fixtures()) do listed = listed + 1 end
  assert(sandboxed == listed and listed > 0, "a sandboxed fixture has no module")
end

--- COSMIC_CI_FORMAT=skip skips the format check on a leg, as ci.yml
--- sets on every leg but one; any other value runs it.
local function test_the_format_check_runs_unless_the_leg_skips_it(tmp: string)
  local base, project = command(tmp)
  local cases: {FormatCase} = {
    { name = "skip", switch = "skip", ok = true, ran = false },
    { name = "run", switch = "run", ok = false, ran = true },
    { name = "unset", switch = "", ok = false, ran = true },
  }
  for _, case in ipairs(cases) do
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

--- COSMIC_CI_FORMAT_CHANGED names a file of the paths a light run
--- changed, one a line: the check lays out only those (`--changed`,
--- after a `--`, so a path is never an option), none where none
--- changed; a file that cannot be read checks the whole tree.
local function test_the_format_check_lays_out_only_the_paths_changed(tmp: string)
  local base, project = command(tmp)
  local listed = tmp .. "/changed-paths"
  assert(Fs.write(listed, "cosmic/fs.tl\ndoc/a b.md\n"))
  local empty = tmp .. "/changed-none"
  assert(Fs.write(empty, ""))
  for _, case in ipairs({
      { name = "listed", changed = listed, ran = "fix --check --changed -- cosmic/fs.tl doc/a b.md" },
      { name = "none", changed = empty, ran = "fix --check --changed --" },
      { name = "unread", changed = tmp .. "/no-such-list", ran = "fix --check ." },
      { name = "unset", changed = "", ran = "fix --check ." },
  }) do
    local fake = tmp .. "/format-changed-" .. assert(case["name"])
    local runner_temp = fake .. "-runner-temp"
    assert(Fs.mkdirs(fake .. "/o/bin") and Fs.mkdirs(runner_temp))
    assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
    Fixture.write(fake .. "/o/bin/cosmic", "#!/bin/sh\nprintf '%s' \"$*\" > \"$0.ran\"\nexit 0\n", 493)
    local outcome = Fixture.call("format-changed-" .. assert(case["name"]), append(base, { "platform", "format" }),
      project, tmp .. "/logs", context(fake, runner_temp, {
        TARGET = "x86_64-linux-musl", COSMIC_CI_FORMAT = "run",
        COSMIC_CI_FORMAT_CHANGED = assert(case["changed"]),
      }))
    assert(outcome.result.ok, assert(case["name"]) .. ": the format phase failed")
    local ran = Fs.read(fake .. "/o/bin/cosmic.ran")
    assert(ran == case["ran"], assert(case["name"]) .. ": the check ran " .. tostring(ran))
  end
end

--- COSMIC_CI_CHECK_MEMO names a directory that holds the check's memo
--- (build/check_memo.tl, `translate-check.db` in the build directory)
--- of an earlier run: the check finds it where it reads it, in the
--- build directory, which is new each run, and a check that passed
--- leaves its own there. Where none is there, or the check fails, it
--- leaves nothing, and a memo already in the build directory is not
--- written over.
local function test_the_format_check_takes_and_leaves_its_memo(tmp: string)
  local base, project = command(tmp)
  local record Case
    name: string
    held?: string
    exit: integer
    saw: string
    left: string
  end
  local cases: {Case} = {
    { name = "taken", held = "old", exit = 0, saw = "old", left = "new" },
    { name = "none", exit = 0, saw = "", left = "new" },
    { name = "failed", held = "old", exit = 1, saw = "old", left = "old" },
  }
  for _, case in ipairs(cases) do
    local fake = tmp .. "/format-memo-" .. case.name
    local runner_temp = fake .. "-runner-temp"
    local memo = runner_temp .. "/check-memo"
    assert(Fs.mkdirs(fake .. "/o/bin") and Fs.mkdirs(memo))
    local held = case.held
    if held then assert(Fs.write(memo .. "/translate-check.db", held)) end
    assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
    -- The check says what memo it found, and leaves one.
    Fixture.write(fake .. "/o/bin/cosmic", "#!/bin/sh\nd=$(dirname \"$0\")/..\n" ..
        "cat \"$d/translate-check.db\" > \"$0.saw\" 2>/dev/null || : > \"$0.saw\"\n" ..
        "printf new > \"$d/translate-check.db\"\nexit " .. tostring(case.exit) .. "\n", 493)
    local outcome = Fixture.call("format-memo-" .. case.name, append(base, { "platform", "format" }),
      project, tmp .. "/logs", context(fake, runner_temp, {
        TARGET = "x86_64-linux-musl", COSMIC_CI_FORMAT = "run", COSMIC_CI_CHECK_MEMO = memo,
      }))
    assert(outcome.result.ok == (case.exit == 0), case.name .. ": the format phase answered " ..
        tostring(outcome.result.ok))
    local saw = Fs.read(fake .. "/o/bin/cosmic.saw")
    assert(saw == case.saw, case.name .. ": the check found the memo " .. tostring(saw))
    local left = Fs.read(memo .. "/translate-check.db")
    assert(left == case.left, case.name .. ": the memo left is " .. tostring(left))
  end
end

--- The format check keeps a native suite's boundary: where the suite
--- ran (its immediate snapshot is there) it runs only after the
--- boundary was checked. A job that ran no suite (ci.yml's `checked`,
--- on a light run) has neither snapshot, and the check runs.
local function test_the_format_check_waits_on_a_suites_boundary_alone(tmp: string)
  local base, project = command(tmp)
  local cases: {BoundaryCase} = {
    { name = "no-suite", immediate = false, boundary = false, ran = true },
    { name = "suite-unbounded", immediate = true, boundary = false, ran = false },
    { name = "suite-bounded", immediate = true, boundary = true, ran = true },
  }
  for _, case in ipairs(cases) do
    local fake = tmp .. "/format-boundary-" .. case.name
    local runner_temp = fake .. "-runner-temp"
    local diagnostics = runner_temp .. "/cosmic-ci/platform/local-diagnostics"
    assert(Fs.mkdirs(fake .. "/o/bin") and Fs.mkdirs(diagnostics))
    local kept: mut {string} = {}
    if case.immediate then kept[#kept + 1] = "local-immediate" end
    if case.boundary then kept[#kept + 1] = "local-boundary" end
    for _, snapshot in ipairs(kept) do
      assert(Fs.mkdirs(diagnostics .. "/" .. snapshot))
      assert(Fs.write(diagnostics .. "/" .. snapshot .. "/hashes.sha256", ""))
    end
    assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
    Fixture.write(fake .. "/o/bin/cosmic", "#!/bin/sh\nprintf '%s' \"$*\" > \"$0.ran\"\nexit 0\n", 493)
    local outcome = Fixture.call("format-boundary-" .. case.name, append(base, { "platform", "format" }),
      project, tmp .. "/logs", context(fake, runner_temp, {
        TARGET = "x86_64-linux-musl", COSMIC_CI_FORMAT = "run",
      }))
    assert(outcome.result.ok == case.ran, case.name .. ": the format phase answered " ..
        tostring(outcome.result.ok))
    local ran = Fs.read(fake .. "/o/bin/cosmic.ran")
    assert((ran ~= nil) == case.ran, case.name .. ": the check ran: " .. tostring(ran))
  end
end

--- Every leg verifies its checked artifact (the manifest entry of its
--- checked core, as the contract's decoder reads it, and that the
--- artifact runs that core) without running a release cosmic: the
--- checked build leaves the tree's database as the tools find it, so
--- there is no rebuild to pay. Only the leg that runs the checked suite
--- (COSMIC_CI_CHECKED_SUITE) runs the checked cosmic on a file in the
--- tree, whose entry must agree with the decoder's. A leg that skips it
--- keeps none of its verdicts: a `checked.db` beside the leg's verdict
--- cache is the checked job's, and goes.
local function test_only_a_leg_that_runs_the_checked_suite_runs_the_checked_cosmic_in_the_tree(tmp: string)
  local base, project = command(tmp)
  local core = "the checked core"
  local digest = Hash.hex_sha256(core)
  local target = "x86_64-linux-musl"
  local right = "16384 " .. tostring(#core) .. " " .. digest
  local wrong = "16384 " .. tostring(#core) .. " " .. string.rep("0", 64)
  local function entry(fields: string): string
    return "printf '%s\\t%s\\t%s\\n' " .. fields .. "\n"
  end
  local function candidate(name: string, host_image: string,
                           checked: string, candidate_target: string): string, string
    local fake = tmp .. "/checked-" .. name
    local runner_temp = fake .. "-runner-temp"
    local format = runner_temp .. "/cosmic-ci/platform/contract/format"
    assert(Fs.mkdirs(fake .. "/o/bin") and Fs.mkdirs(fake .. "/o/sanitized/bin"))
    assert(Fs.mkdirs(format))
    assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
    assert(Fs.write(fake .. "/o/sanitized/targets.tsv",
      "1\t1\trelease\t" .. candidate_target .. "\tLinux\tx86_64\n" ..
        "1\t2\tsanitized\tsanitized-" .. candidate_target .. "\tLinux\tx86_64\n"))
    assert(Fs.write(fake .. "/o/sanitized/cosmic-core", core))
    -- The release cosmic, which fails if run.
    Fixture.write(fake .. "/o/bin/cosmic", "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$0.ran\"\n" ..
        "exit 9\n", 493)
    -- The contract's decoder, which reads the checked artifact's entry.
    Fixture.write(format .. "/format-test-" .. candidate_target, "#!/bin/sh\n" ..
        "case \"$1 $2\" in '--inspect '*/o/sanitized/bin/cosmic) ;; *) exit 9 ;; esac\n" ..
        "printf '%s\\n' 'prefix 32768 manifest 28672 4096 database 32768 0 entries 2' " ..
        "'entry 1 1 1 0 16384 1 " .. string.rep("1", 64) .. " 1 " .. string.rep("1", 64) .. "' " ..
        "'entry 1 2 1 0 16384 " .. tostring(#core) .. " " .. digest .. " " .. tostring(#core) .. " " ..
        digest .. "'\n", 493)
    -- The checked artifact: a script that answers each run as the tool
    -- would, `tool.tl entry` with `checked`, its core at the first
    -- aligned offset past it. Its `-e` answers only a chunk that prints
    -- the three keys, in order.
    local script = "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$0.ran\"\n" ..
      "if [ \"$1\" = -e ]; then case \"$2\" in " ..
      "*\"print(Store.meta('runtime_context'), Store.meta('host'), Store.meta('host_image'))\"*) ;; " ..
      "*) exit 9 ;; esac\n" ..
      "printf '%s\\t%s\\t%s\\n' portable-v1 " .. candidate_target .. " " .. host_image .. "; exit 0; fi\n" ..
      "if [ \"$1\" = test ]; then " ..
      "if [ \"" .. candidate_target .. "\" = aarch64-macos ]; then " ..
      "[ \"$2 $3\" = '--all core/socket_sigpipe_checked_test.tl' ] || exit 9; fi\n" ..
      "printf '%s\\n' \"$*|${COSMIC_TEST_NO_SHARED-unset}\" >> \"$0.argv\"\n" ..
      "printf '%s\\n' " ..
      "'test: key parts: host features 01, host 02, system , runtime 04, compiler 05, harness 06' " ..
      "'test: 7 tests passed in 2 modules; 3 ran, 4 stood, 55 ms; sandboxed'; exit 0; fi\n" ..
      entry(checked) .. "exit 0\n"
    Fixture.write(fake .. "/o/sanitized/bin/cosmic",
      script .. string.rep("#", 16384 - #script) .. core, 493)
    return fake, runner_temp
  end
  local record Case
    name: string
    target: string
    switch: string
    image: string
    checked: string
    ok: boolean
    ran: string
    removed: boolean
    share?: string
    event?: string
    argv?: string
  end
  local cases: {Case} = {
    { name = "skip", target = target, switch = "skip", image = digest, checked = right,
      ok = true, ran = "-e\n", removed = true },
    { name = "macos-skip", switch = "skip", image = digest, checked = right,
      target = "aarch64-macos", ok = true, ran = "-e\ntest\n", removed = true },
    { name = "run", target = target, switch = "run", image = digest, checked = right,
      ok = true, ran = "-e\n/tool.tl\ntest\n", removed = false, argv = "test --census --all|1\n" },
    -- A share of the suite, which ci.yml's `checked-shard` jobs run: the
    -- same run of the share's tests alone.
    { name = "share", target = target, switch = "run", image = digest, checked = right,
      ok = true, ran = "-e\n/tool.tl\ntest\n", removed = false, share = "2/4",
      argv = "test --census --all --shard 2/4|1\n" },
    -- The gathering run of `checked`: the whole suite, standing on the
    -- verdicts the shares kept, in a run that stands on nothing as in
    -- one that stands (the sandboxed push), and no share of it.
    { name = "gather", target = target, switch = "gather", image = digest, checked = right,
      ok = true, ran = "-e\n/tool.tl\ntest\n", removed = false, argv = "test --census|unset\n" },
    { name = "gather-standing", target = target, switch = "gather", image = digest, checked = right,
      ok = true, ran = "-e\n/tool.tl\ntest\n", removed = false, argv = "test --census|unset\n",
      event = "push" },
    { name = "another-core", target = target, switch = "skip", image = string.rep("0", 64),
      checked = right, ok = false, ran = "-e\n", removed = false },
    { name = "checked-disagrees", target = target, switch = "run", image = digest,
      checked = wrong, ok = false, ran = "-e\n/tool.tl\n", removed = false },
  }
  for _, case in ipairs(cases) do
    local selected_target = case.target
    local fake, runner_temp = candidate(case.name, case.image, case.checked, selected_target)
    local verdicts = runner_temp .. "/verdicts"
    assert(Fs.mkdirs(verdicts))
    assert(Fs.write(verdicts .. "/verdicts.db", "native\n"))
    assert(Fs.write(verdicts .. "/checked.db", "checked\n"))
    local outcome = Fixture.call("checked-" .. case.name, append(base, { "platform", "checked" }),
      project, tmp .. "/logs", context(fake, runner_temp, {
        TARGET = selected_target, COSMIC_CI_CHECKED_SUITE = case.switch,
        COSMIC_CI_CHECKED_SHARD = case.share or "",
        COSMIC_CI_EVENT = case.event or "",
        COSMIC_CI_REQUIRE_SANDBOX = if case.event then "1" else "" end,
        COSMIC_VERDICT_CACHE = verdicts .. "/verdicts.db",
      }))
    assert(outcome.result.ok == case.ok, case.name .. ": the checked phase answered " ..
        tostring(outcome.result.ok) .. ": " .. Fixture.read(outcome.err))
    assert(Fs.read(verdicts .. "/verdicts.db") == "native\n", case.name .. ": the native verdicts moved")
    assert((Fs.read(verdicts .. "/checked.db") == nil) == case.removed,
      case.name .. ": the checked verdicts were " .. (if case.removed then "kept" else "removed" end))
    local ran = Fs.read(fake .. "/o/sanitized/bin/cosmic.ran")
    if ran then ran = ran:gsub("[^\n]*/test/portable/tool%.tl", "/tool.tl") end
    assert(ran == case.ran, case.name .. ": the checked cosmic ran: " .. tostring(ran))
    local released = Fs.read(fake .. "/o/bin/cosmic.ran")
    assert(released == nil, case.name .. ": the release cosmic ran: " .. tostring(released))
    if case.argv ~= nil then
      local argv = Fs.read(fake .. "/o/sanitized/bin/cosmic.argv")
      assert(argv == case.argv, case.name .. ": the suite ran as: " .. tostring(argv))
    end
    -- The suite that ran wrote its row, with what its output said.
    local db = assert(Sqlite.open(runner_temp .. "/cosmic-ci/operations.db"))
    local rows = State.suite_rows(db)
    assert(db:close())
    if case.argv ~= nil then
      assert(#rows == 1, case.name .. ": " .. tostring(#rows) .. " suite rows")
      local row = rows[1]
      assert(assert(row).worker == "worker" and row.phase == "checked" and row.suite == "checked")
      assert(row.status == "pass" and row.exit_code == 0 and row.tests == 7)
      assert(row.ran == 3 and row.stood == 4 and row.elapsed_ms == 55)
      local parts = assert(row.parts)
      assert(parts["runtime"] == "04" and parts["harness"] == "06" and parts["system"] == "")
    else
      assert(#rows == 0, case.name .. ": a suite that did not run wrote a row")
    end
  end
end

--- ci.yml's `checked` job runs the checked suite apart from every leg:
--- `boot` builds the cores and boots, and runs no native suite;
--- `checked-build` then builds the checked core and the target's format
--- decoder, and lays the decoder out where assemble's format-contract
--- fixture would, in the contract, for the `checked` phase to read.
local function test_the_checked_job_boots_and_builds_what_the_checked_phase_reads(tmp: string)
  local base, project = command(tmp)
  local target = "x86_64-linux-musl"
  local fake = tmp .. "/checked-job"
  local runner_temp = fake .. "-runner-temp"
  assert(Fs.mkdirs(fake .. "/bin") and Fs.mkdirs(runner_temp))
  assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
  -- bin/zig logs each build, and leaves what it names.
  Fixture.write(fake .. "/bin/zig", "#!/bin/sh\nmkdir -p o\nprintf '%s\\n' \"$*\" >> o/zig.ran\n" ..
      "case \"$*\" in\n" ..
      "'build cores boot -Dboot-cores=all') mkdir -p o/bin && printf '#!/bin/sh\\necho ran >> \"$0.ran\"\\n' > o/bin/cosmic && " ..
      "chmod 755 o/bin/cosmic ;;\n" ..
      "'build sanitized') mkdir -p o/sanitized/bin ;;\n" ..
      "'build portable-format-" .. target .. "') mkdir -p o/portable-fixture/format && " ..
      "printf decoder > o/portable-fixture/format/format-test-" .. target .. " ;;\n" ..
      "*) exit 9 ;;\nesac\n", 493)
  local env = context(fake, runner_temp, { TARGET = target })
  for _, phase in ipairs({ "boot", "checked-build" }) do
    local outcome = Fixture.call("checked-job-" .. phase, append(base, { "platform", phase }),
      project, tmp .. "/logs", env)
    assert(outcome.result.ok, phase .. " failed: " .. Fixture.read(outcome.err))
  end
  assert(Fs.read(fake .. "/o/zig.ran") == "build cores boot -Dboot-cores=all\nbuild sanitized\n" ..
      "build portable-format-" .. target .. "\n", tostring((Fs.read(fake .. "/o/zig.ran"))))
  assert(Fs.read(fake .. "/o/bin/cosmic.ran") == nil, "boot ran the native suite")
  local decoder = runner_temp .. "/cosmic-ci/platform/contract/format/format-test-" .. target
  assert(Fs.read(decoder) == "decoder", "the decoder is not where the checked phase reads it")
  local st = assert(Fs.stat(decoder))
  assert(st.mode & 0x49 == 0x49, "the decoder is not executable: " .. tostring(st.mode))
  local db = assert(Sqlite.open(runner_temp .. "/cosmic-ci/operations.db"))
  assert(#State.suite_rows(db) == 0, "a suite ran")
  assert(db:close())
  -- Again on the same work directory, it refuses to lay over a decoder.
  local again = Fixture.call("checked-job-again", append(base, { "platform", "checked-build" }),
    project, tmp .. "/logs", env)
  assert(not again.result.ok, "checked-build laid a decoder over another")
end

--- The native suite (`build`) writes its row, with what its output
--- said; where the row cannot be written -- here an operations database
--- whose suite_runs table has another shape -- the suite's own status
--- still decides the phase, which passes, and says so on stderr.
local function test_the_native_suite_writes_its_row_and_a_lost_row_fails_nothing(tmp: string)
  local base, project = command(tmp)
  local cases: {NativeCase} = { { name = "rows", broken = false }, { name = "broken", broken = true } }
  for _, case in ipairs(cases) do
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
        "'test: 9 tests passed in 2 modules; 5 ran, 4 stood, 77 ms; sandboxed'; fi\nexit 0\nEOF\n" ..
        "chmod 755 o/bin/cosmic\n", 493)
    local database = runner_temp .. "/cosmic-ci/operations.db"
    if case.broken then
      local db = assert(Sqlite.open(database, { writable = true }))
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
      assert(assert(count[1]):text(1) == "0", case.name .. ": " .. assert(count[1]):text(1) .. " rows")
      assert(err:find("local suite: row not recorded", 1, true), err)
    else
      local rows = State.suite_rows(db)
      assert(#rows == 1, case.name .. ": " .. tostring(#rows) .. " suite rows")
      local row = rows[1]
      assert(assert(row).suite == "local" and row.phase == "build" and row.status == "pass")
      assert(row.exit_code == 0 and row.tests == 9 and row.ran == 5 and row.stood == 4)
      assert(row.elapsed_ms == 77 and row.sandbox == "sandboxed")
      local parts = assert(row.parts)
      assert(parts["runtime"] == "04" and parts["harness"] == "06")
    end
    local phases = assert(Sqlite.text_rows(db, "SELECT phase, status FROM operation_events " ..
        "WHERE event = 'complete' AND phase IN ('local suite', 'platform: build') ORDER BY id"))
    assert(#phases == 2 and assert(phases[1]):text(2) == "success" and assert(phases[2]):text(2) == "success",
      case.name .. ": the phases did not succeed")
    assert(db:close())
  end
end

--- ci.yml's platform legs on a full run, by name: each of the `name`
--- list a full run takes, with the values of every `include` entry
--- that names it or names no leg, a later one's over an earlier one's
--- (build/workflows_test.tl expands the matrix as GitHub does, for a
--- light run too).
local function full_run_legs(platform: CiWorkflow.Job): {string: {string: string}}
  local matrix = assert(assert(platform.strategy).matrix)
  local full = assert(assert(matrix.name):match("&& '(%[.-%])' ||"), "the legs' names are no scope's choice")
  local legs: mut {string: {string: string}} = {}
  local names, why: {string}?, string = Shape.decode_into(full, Shape.list(Shape.string))
  assert(names ~= nil, why)
  for _, name in ipairs(names) do
    local leg: mut {string: string} = { name = name }
    for _, entry in ipairs(assert(matrix.include)) do
      if entry["name"] == nil or entry["name"] == name then
        for key, value in pairs(entry) do
          if value is string then leg[key] = value end
        end
      end
    end
    legs[name] = leg
  end
  return legs
end

--- The checked core's suite runs on no leg of ci.yml's platform job
--- (COSMIC_CI_CHECKED_SUITE=skip) but in jobs of its own, beside the
--- legs: `checked-shard`, a share of it each (COSMIC_CI_CHECKED_SHARD),
--- and `checked`, which gathers them, the whole suite standing on the
--- verdicts they kept; the whole suite on a checked run (`checked-narrowing`)
--- runs in another. Each runs the phases that build what it reads: run
--- after a leg's own suites, the suite would make that leg the run's
--- longest. The format check, which answers the same on every leg, runs
--- on one, in a full run's assemble; a branch push's light run makes it
--- in the `format` job after its boot, off the legs' path.
local function test_the_checked_suite_runs_in_jobs_of_its_own_and_the_format_check_on_one_leg()
  local text = assert(Fs.read(Test.parent(".github/workflows/ci.yml")))
  local jobs = CiWorkflow.parse(text).jobs
  local platform = assert(jobs["platform"])
  local legs = full_run_legs(platform)
  local env = assert(platform.env)
  assert(env["COSMIC_CI_CHECKED_SUITE"] == "skip", "a leg runs the checked suite: " ..
      tostring(env["COSMIC_CI_CHECKED_SUITE"]))
  local format = assert(env["COSMIC_CI_FORMAT"], "ci.yml's platform job sets no COSMIC_CI_FORMAT")
  local one = format:match("^%${{ matrix%.name == '([%w_-]+)' && 'run' || 'skip' }}$")
  assert(one and legs[one], "COSMIC_CI_FORMAT runs on no one leg of the matrix: " .. format)
  local function env_of(job: CiWorkflow.Job): {string: string}
    return assert(job.env)
  end
  local function phases_of(job: CiWorkflow.Job): string
    local phases: mut {string} = {}
    for _, step in ipairs(assert(job.steps)) do
      local run = step.run
      local phase: string?
      if run ~= nil then phase = run:match("driver%.tl platform ([%w-]+)$") end
      if phase ~= nil then phases[#phases + 1] = phase end
      if phase == "performance-checked" then
        assert(step["if"] == "env.COSMIC_CI_SCOPE == 'full'", "the performance fixture runs outside the full scope")
      end
    end
    return table.concat(phases, " ")
  end
  local checked = assert(jobs["checked"], "ci.yml has no checked job")
  assert(env_of(checked)["COSMIC_CI_CHECKED_SUITE"] == "gather",
    "the checked job does not gather the checked suite")
  assert(phases_of(checked) == "boot checked-build checked performance-checked",
    "the checked job runs the phases " .. phases_of(checked))
  local shard = assert(jobs["checked-shard"], "ci.yml has no job that runs a share of the checked suite")
  local senv = env_of(shard)
  local share = senv["COSMIC_CI_CHECKED_SHARD"]
  assert(senv["COSMIC_CI_CHECKED_SUITE"] == "run" and share ~= nil and
      share:match("^%${{ matrix%.part }}/%${{ strategy%.job%-total }}$") ~= nil,
    "a share does not run a share of the checked suite")
  assert(phases_of(shard) == "boot checked-build checked", "a share runs the phases " .. phases_of(shard))
  local narrowing = assert(jobs["checked-narrowing"], "ci.yml has no checked narrowing job")
  assert(phases_of(narrowing) == "boot checked-narrowing",
    "the checked narrowing job runs the phases " .. phases_of(narrowing))
  local narrowing_share = env_of(narrowing)["COSMIC_CI_NARROWING_SHARD"]
  assert(narrowing_share ~= nil and
      narrowing_share:match("^%${{ matrix%.part }}/%${{ strategy%.job%-total }}$") ~= nil,
    "a checked narrowing job does not run a share of the suite")
  local light = assert(jobs["format"], "ci.yml has no format job")
  assert(phases_of(light) == "boot format", "the format job runs the phases " .. phases_of(light))
end

--- ci.yml's platform job's legs, by name, and its environment.
local function platform_legs_and_env(): {string: {string: string}}, {string: string}
  local text = assert(Fs.read(Test.parent(".github/workflows/ci.yml")))
  local platform = assert(CiWorkflow.parse(text).jobs["platform"])
  return full_run_legs(platform), assert(platform.env)
end

--- The fixed-point regression, the slowest fixture on every leg, runs
--- on no gating run (COSMIC_CI_FIXED_POINT), only on the scheduled one.
local function test_the_fixed_point_fixture_runs_only_on_the_scheduled_run()
  local _, env = platform_legs_and_env()
  local value = assert(env["COSMIC_CI_FIXED_POINT"], "ci.yml's platform job sets no COSMIC_CI_FIXED_POINT")
  assert(value == "${{ github.event_name == 'schedule' && 'run' || 'skip' }}",
    "the fixed-point fixture runs on more than the scheduled run, or not on it: " .. value)
end

--- The self-rebuild regression runs on two legs of a gating run
--- (COSMIC_CI_SELF_REBUILD), one of them macOS, whose file system
--- renames, unlinks and locks unlike Linux's, and on every leg of the
--- scheduled run.
local function test_the_self_rebuild_fixture_runs_on_two_legs_and_on_every_scheduled_one()
  local legs, env = platform_legs_and_env()
  local value = assert(env["COSMIC_CI_SELF_REBUILD"], "ci.yml's platform job sets no COSMIC_CI_SELF_REBUILD")
  local one, two = value:match("^%${{ %(matrix%.name == '([%w_-]+)' || " ..
      "matrix%.name == '([%w_-]+)' || github%.event_name == 'schedule'%) && 'run' || 'skip' }}$")
  assert(one ~= nil and two ~= nil and one ~= two and legs[one] ~= nil and legs[two] ~= nil,
    "the self-rebuild fixture runs on no two legs of the matrix, " ..
      "or not on every leg of the scheduled run: " .. value)
  assert(assert(assert(legs[one])["runner"]):sub(1, 5) == "macos" or assert(assert(legs[two])["runner"]):sub(1, 5) == "macos",
    "the self-rebuild fixture runs on no macOS leg of a gating run: " .. value)
end

--- The portable suite runs on the two x86-64 legs of a push to main
--- (COSMIC_CI_PORTABLE_SUITE), a glibc host and a musl one, on the musl
--- one alone in the merge queue, whose glibc leg builds the same bytes
--- (and in a branch push that runs the full scope, as the queue does),
--- and on every leg of the scheduled run and a manual one.
local function test_the_portable_suite_runs_on_two_legs_and_on_every_scheduled_one()
  local legs, env = platform_legs_and_env()
  local value = assert(env["COSMIC_CI_PORTABLE_SUITE"], "ci.yml's platform job sets no COSMIC_CI_PORTABLE_SUITE")
  local one, two = value:match("^%${{ %(%(matrix%.name == '([%w_-]+)' && " ..
      "github%.event_name != 'merge_group' && %(github%.event_name != 'push' || " ..
      "github%.ref == 'refs/heads/main'%)%) || " ..
      "matrix%.name == '([%w_-]+)' || github%.event_name == 'schedule' || " ..
      "github%.event_name == 'workflow_dispatch'%) && 'run' || 'skip' }}$")
  assert(one ~= nil and two ~= nil and one ~= two and legs[one] ~= nil and legs[two] ~= nil,
    "the portable suite runs on no two legs of a push to main, on more than " ..
      "one of the merge queue, or not on every leg of the scheduled and a manual run: " .. value)
  assert(assert(assert(legs[one])["target"]):sub(1, 7) == "x86_64-" and assert(assert(legs[two])["target"]):sub(1, 7) == "x86_64-",
    "the portable suite runs on a leg of a gating run that is no x86-64 one: " .. value)
  -- Both Linux legs, the queue's in the Alpine (musl) image, the other
  -- not (glibc).
  assert(assert(legs[one])["image"] ~= "" and assert(assert(legs[one])["image"]):find("alpine", 1, true) == nil and
      assert(assert(legs[two])["image"]):find("alpine", 1, true) ~= nil,
    "the portable suite's gating legs are not a glibc host and, in the queue too, a musl one: " .. value)
end

--- A leg that skips the portable suite (COSMIC_CI_PORTABLE_SUITE=skip)
--- starts no suite and says so, still records the artifact's digest
--- that attest compares, and its boundary, with no suite's database or
--- cache to hold, passes.
local function test_a_leg_that_skips_the_portable_suite_still_attests(tmp: string)
  local base, project = command(tmp)
  local fake = tmp .. "/portable-skip"
  local runner_temp = fake .. "-runner-temp"
  local work = runner_temp .. "/cosmic-ci/platform"
  local diagnostics = work .. "/portable-diagnostics"
  assert(Fs.mkdirs(fake) and Fs.mkdirs(diagnostics) and
      Fs.mkdirs(work .. "/portable-source"))
  assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
  local executable = diagnostics .. "/cosmic-portable"
  local seen = fake .. "-seen"
  Fixture.write(executable, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$SEEN\"\nexit 0\n", 493)
  local digest = Hash.hex_sha256((assert(Fs.read(executable)))) .. "\n"
  assert(Fs.write(diagnostics .. "/portable-artifact.before.sha256", digest))
  for _, phase in ipairs({ "portable", "portable-boundary" }) do
    local outcome = Fixture.call("portable-skip-" .. phase,
      append(base, { "platform", phase, "success" }), project, tmp .. "/logs",
      context(fake, runner_temp, {
        TARGET = "x86_64-linux-musl", SEEN = seen, COSMIC_CI_EVENT = "merge_group",
        COSMIC_CI_PORTABLE_SUITE = "skip",
        COSMIC_VERDICT_CACHE = runner_temp .. "/verdicts/verdicts.db",
        XDG_CACHE_HOME = tmp .. "/cache",
      }))
    local err = Fixture.read(outcome.err)
    assert(outcome.result.ok, phase .. ": failed: " .. err)
    assert(err:find(": skipped on this leg (COSMIC_CI_PORTABLE_SUITE=skip)", 1, true) ~= nil,
      phase .. ": " .. err)
  end
  assert(Fs.read(seen) == nil, "a skipped portable suite ran the artifact: " ..
      tostring((Fs.read(seen))))
  assert(Fs.read(diagnostics .. "/portable-artifact.after.sha256") == digest,
    "a skipped portable suite recorded no digest for attest")
  assert(Fs.read(diagnostics .. "/portable-immediate/hashes.sha256") == nil and
      Fs.read(diagnostics .. "/portable-boundary/hashes.sha256") == nil,
    "a skipped portable suite snapshotted a database")
end

--- A gating suite's workers are given none of what names the run --
--- GitHub's GITHUB_*, RUNNER_* and ACTIONS_*, CI, systemd's per-unit
--- variables, the container's HOSTNAME, the driver's own COSMIC_CI_*
--- switches -- so a test that declares a variable among them is keyed the
--- same from run to run and can stand on an earlier run's verdict. The rest reaches them: PATH, HOME, the proxy
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
  local env: mut {string:string} = {}
  for line in (assert(Fs.read(seen .. ".env"))):gmatch("[^\n]+") do
    local name, value = line:match("^([^=]+)=(.*)$")
    if name ~= nil and value ~= nil then env[name] = value end
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
  assert(env["PATH"] ~= nil and env["PATH"] ~= "", "PATH did not reach the suite")
  assert(env["COSMIC_TEST_NO_SHARED"] == nil, "a Linux push's suite stands on shared verdicts")
  assert(Fs.read(seen .. ".words") == "test --census\n", "a Linux push's suite ran --all")
end

--- A branch push's linux-x86_64 legs each run a share of the native
--- suite, the one COSMIC_CI_SHARD names (`--shard`), which the suite
--- itself is not given; where it names none, the whole suite runs.
local function test_a_shard_leg_runs_its_share_of_the_native_suite(tmp: string)
  local base, project = command(tmp)
  for _, case in ipairs({
      { name = "second", shard = "2/2", words = "test --census --shard 2/2\n" },
      { name = "whole", shard = "", words = "test --census\n" },
  }) do
    local fake = tmp .. "/shard-" .. assert(case["name"])
    assert(Fs.mkdirs(fake .. "/bin") and Fs.mkdirs(fake .. "/ci/testdata/portable"))
    assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
    assert(Fs.write(fake .. "/ci/testdata/portable/work_db_integrity.tl", "\n"))
    local seen = fake .. "-seen"
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
    local runner_temp = fake .. "-runner-temp"
    assert(Fs.mkdirs(runner_temp))
    local outcome = Fixture.call("shard-" .. assert(case["name"]), append(base, { "platform", "build" }),
      project, tmp .. "/logs", context(fake, runner_temp, {
        TARGET = "x86_64-linux-musl", SEEN = seen,
        COSMIC_CI_SCOPE = "light", COSMIC_CI_EVENT = "push",
        COSMIC_CI_CHECKED_SUITE = "skip", COSMIC_CI_REQUIRE_SANDBOX = "1",
        COSMIC_CI_SHARD = assert(case["shard"]), XDG_CACHE_HOME = tmp .. "/cache",
      }))
    assert(outcome.result.ok, assert(case["name"]) .. ": the build failed: " .. Fixture.read(outcome.err))
    local words = assert(Fs.read(seen .. ".words"))
    assert(words == case["words"], assert(case["name"]) .. ": the suite ran " .. words)
    local env = assert(Fs.read(seen .. ".env"))
    assert(not env:find("COSMIC_CI_SHARD", 1, true), assert(case["name"]) .. ": the suite was given the share")
  end
end

--- The portable suite stands on verdicts where the other suites do --
--- a Linux leg's push or merge queue run -- on the local suite's file
--- ([`cosmic_ci.orchestration.suite_verdicts`]); where
--- they do not (main's scheduled run), it runs every test.
local function test_the_portable_suite_stands_on_the_local_suites_verdicts(tmp: string)
  local base, project = command(tmp)
  local cases: {PortableCase} = {
    { event = "merge_group", words = "test --census --bail\n", shared = false },
    { event = "push", words = "test --census\n", shared = false },
    { event = "schedule", words = "test --census --all\n", shared = true },
  }
  for _, case in ipairs(cases) do
    local fake = tmp .. "/portable-" .. case.event
    local runner_temp = fake .. "-runner-temp"
    local work = runner_temp .. "/cosmic-ci/platform"
    local diagnostics = work .. "/portable-diagnostics"
    local fresh = work .. "/portable-source"
    assert(Fs.mkdirs(fake) and Fs.mkdirs(diagnostics) and
        Fs.mkdirs(fresh .. "/o") and Fs.mkdirs(fresh .. "/ci/testdata/portable"))
    assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
    build_resolver(fresh)
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
        -- As on a leg that runs it, whatever the leg running this test sets.
        COSMIC_CI_PORTABLE_SUITE = "run",
        COSMIC_VERDICT_CACHE = runner_temp .. "/verdicts/verdicts.db",
        XDG_CACHE_HOME = tmp .. "/cache",
      }))
    assert(outcome.result.ok, case.event .. ": the portable phase failed: " ..
        Fixture.read(outcome.err))
    assert(Fs.read(seen .. ".words") == case.words, case.event .. ": " ..
        tostring((Fs.read(seen .. ".words"))))
    local env: mut {string:string} = {}
    for line in (assert(Fs.read(seen .. ".env"))):gmatch("[^\n]+") do
      local name, value = line:match("^([^=]+)=(.*)$")
      if name ~= nil and value ~= nil then env[name] = value end
    end
    assert(env["COSMIC_VERDICT_CACHE"] == runner_temp .. "/verdicts/verdicts.db",
      case.event .. ": " .. tostring(env["COSMIC_VERDICT_CACHE"]))
    assert((env["COSMIC_TEST_NO_SHARED"] == "1") == case.shared,
      case.event .. ": COSMIC_TEST_NO_SHARED=" .. tostring(env["COSMIC_TEST_NO_SHARED"]))
  end
end

--- The job that runs the second half of alpine-x86_64's portable suite
--- is told its share (COSMIC_CI_PORTABLE_SHARD) and runs only that
--- share's tests (`--shard`), which the suite itself is not given; where
--- none is named, the whole suite runs.
local function test_a_portable_share_runs_its_share_of_the_portable_suite(tmp: string)
  local base, project = command(tmp)
  local cases: {PortableShareCase} = {
    { name = "first", shard = "1/2", words = "test --census --shard 1/2\n" },
    { name = "second", shard = "2/2", words = "test --census --shard 2/2\n" },
    { name = "whole", shard = "", words = "test --census\n" },
  }
  for _, case in ipairs(cases) do
    local fake = tmp .. "/portable-share-" .. case.name
    local runner_temp = fake .. "-runner-temp"
    local work = runner_temp .. "/cosmic-ci/platform"
    local diagnostics = work .. "/portable-diagnostics"
    local fresh = work .. "/portable-source"
    assert(Fs.mkdirs(fake) and Fs.mkdirs(diagnostics) and
        Fs.mkdirs(fresh .. "/o") and Fs.mkdirs(fresh .. "/ci/testdata/portable"))
    assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
    build_resolver(fresh)
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
    local outcome = Fixture.call("portable-share-" .. case.name,
      append(base, { "platform", "portable" }), project, tmp .. "/logs",
      context(fake, runner_temp, {
        TARGET = "x86_64-linux-musl", SEEN = seen,
        COSMIC_CI_EVENT = "push", COSMIC_CI_REQUIRE_SANDBOX = "1",
        COSMIC_CI_HARNESS_MOVED = "0", COSMIC_CI_PORTABLE_SUITE = "run",
        COSMIC_CI_PORTABLE_SHARD = case.shard,
        COSMIC_VERDICT_CACHE = runner_temp .. "/verdicts/verdicts.db",
        XDG_CACHE_HOME = tmp .. "/cache",
      }))
    assert(outcome.result.ok, case.name .. ": the portable phase failed: " .. Fixture.read(outcome.err))
    local words = assert(Fs.read(seen .. ".words"))
    assert(words == case.words, case.name .. ": the suite ran " .. words)
    assert(Fs.read(diagnostics .. "/portable-share") == (if case.shard == "" then "whole" else case.shard end) .. "\n",
      case.name .. ": the share recorded is " .. tostring((Fs.read(diagnostics .. "/portable-share"))))
    local env = assert(Fs.read(seen .. ".env"))
    assert(not env:find("COSMIC_CI_PORTABLE_SHARD", 1, true), case.name .. ": the suite was given the share")
  end
end

--- The checked suite and the others alike ([`suite_run`]): the words are
--- decided on the driver's environment, then what names the run is
--- forgotten and the rest is kept.
local function test_a_suite_run_forgets_the_run_after_deciding_its_words()
  local words, env = suite_run({
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
  assert(env["COSMIC_CI_REQUIRE_SANDBOX"] == "1" and env["HOME"] == "/home/runner" and
      env["COSMIC_WORKER"] == "w" and env["FUZZ_ITERS"] == "0")
  local all, all_env = suite_run({
    COSMIC_CI_EVENT = "schedule", COSMIC_CI_REQUIRE_SANDBOX = "1" })
  assert(table.concat(all, " ") == "test --all" and
      all_env["COSMIC_TEST_NO_SHARED"] == "1", "main's scheduled run")
end

--- The macOS leg's suites stand on shared verdicts in pushes and the
--- merge queue, keyed by each test's declarations. Scheduled runs and
--- unsandboxed fixtures stand on none.
local function test_the_macos_leg_stands_on_verdicts_keyed_by_declarations(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  for _, event in ipairs({ "push", "merge_group" }) do
    local words, env = suite_run({
      COSMIC_CI_EVENT = event, COSMIC_CI_REQUIRE_SANDBOX = "0", COSMIC_CI_HARNESS_MOVED = "0",
      COSMIC_CI_DECLARED_KEYS = "1", COSMIC_TEST_SANDBOX = "" })
    assert(table.concat(words, " ") == (if event == "merge_group" then "test --bail" else "test" end),
      event .. ": the macOS leg ran --all")
    assert(env["COSMIC_TEST_NO_SHARED"] == nil, event .. ": the macOS leg stands on no shared verdict")
    assert(env["COSMIC_CI_DECLARED_KEYS"] == nil, event .. ": the suite was given the driver's switch")
    assert((env["COSMIC_TEST_SANDBOX"] or "") == "" and env["COSMIC_SANDBOX"] ~= "must",
      event .. ": the macOS leg's suite was held to a sandbox")
  end
  local all, scheduled = suite_run({ COSMIC_CI_EVENT = "schedule",
    COSMIC_CI_REQUIRE_SANDBOX = "0", COSMIC_CI_DECLARED_KEYS = "1" })
  assert(table.concat(all, " ") == "test --all" and scheduled["COSMIC_TEST_NO_SHARED"] == "1",
    "the macOS leg's scheduled run")
  local _, pushed = suite_run({ COSMIC_CI_EVENT = "push",
    COSMIC_CI_REQUIRE_SANDBOX = "0", COSMIC_CI_DECLARED_KEYS = "1" })
  local fixture = Orchestration.fixture(pushed, tmp .. "/tmp", tmp .. "/fixture-compiles.db")
  assert(fixture["COSMIC_TEST_NO_SHARED"] == "1" and fixture["COSMIC_VERDICT_CACHE"] == "0")
end

--- A darwin list names one path a line; a comment, on a line of its
--- own or after a path, names nothing. That the list names test modules
--- of the tree, each once, the tree's own build/ci_tree_test.tl holds.
local function test_a_darwin_list_names_a_path_a_line()
  local Orchestration = require("cosmic_ci.orchestration")
  local parsed = Orchestration.darwin_modules("# why\n\n  a_test.tl  # because\n#b_test.tl\n")
  assert(#parsed == 1 and parsed[1] == "a_test.tl", table.concat(parsed, ","))
end

--- A skip for want of boundary checks in the compile is no sign that the run was not checked; any other skip is.
local function test_only_a_skip_for_want_of_a_checked_run_fails_the_declared_types_phase()
  local Orchestration = require("cosmic_ci.orchestration")
  local checked = "test: SKIP  m t: boundary checks are not compiled in: x\ntest: 1 tests passed\n"
  assert(#Orchestration.unchecked_skips(checked) == 0)
  local plain = checked .. "test: SKIP  m u: run with --check-types: only a checked run carries the type checks\n"
  local found = Orchestration.unchecked_skips(plain)
  assert(#found == 1 and assert(found[1]):find("run with --check-types", 1, true) ~= nil, table.concat(found, "|"))
end

--- The declared-types tests ci.yml runs on a checked run are every
--- `*declared_types_test.tl` under cosmic/, build/, core/ and eval/,
--- wherever it sits, and none elsewhere.
local function test_the_declared_types_tests_are_found_by_name(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  assert(Fs.mkdirs(tmp .. "/cosmic/web"))
  assert(Fs.mkdirs(tmp .. "/build/c"))
  assert(Fs.mkdirs(tmp .. "/core"))
  assert(Fs.mkdirs(tmp .. "/eval"))
  assert(Fs.mkdirs(tmp .. "/ci"))
  assert(Fs.write(tmp .. "/cosmic/a_declared_types_test.tl", ""))
  assert(Fs.write(tmp .. "/cosmic/web/declared_types_test.tl", ""))
  assert(Fs.write(tmp .. "/cosmic/other_test.tl", ""))
  assert(Fs.write(tmp .. "/build/importer_declared_types_test.tl", ""))
  assert(Fs.write(tmp .. "/build/c/declared_types_test.tl", ""))
  assert(Fs.write(tmp .. "/build/c/rules_test.tl", ""))
  assert(Fs.write(tmp .. "/core/syscalls_declared_types_test.tl", ""))
  assert(Fs.write(tmp .. "/eval/declared_types_test.tl", ""))
  assert(Fs.write(tmp .. "/eval/round_test.tl", ""))
  assert(Fs.write(tmp .. "/ci/declared_types_test.tl", ""))
  local files = Orchestration.declared_types_files(tmp)
  assert(table.concat(files, ",") == "build/c/declared_types_test.tl,build/importer_declared_types_test.tl," ..
      "core/syscalls_declared_types_test.tl,cosmic/a_declared_types_test.tl," ..
      "cosmic/web/declared_types_test.tl,eval/declared_types_test.tl", table.concat(files, ","))
end

--- The darwin list runs where the native suite stands on verdicts:
--- `--all` over the listed modules, so none of them stands on one. A
--- run of every test already (the scheduled run's `--all`) runs them.
local function test_the_darwin_list_runs_where_the_native_suite_stands()
  local Orchestration = require("cosmic_ci.orchestration")
  local modules = { "core/a_test.tl", "build/b_test.tl" }
  local words = Orchestration.darwin_words({ "test" }, modules)
  assert(words ~= nil and table.concat(words, " ") ==
      "test --all --census core/a_test.tl build/b_test.tl", tostring(words and
          table.concat(words, " ")))
  local queued = Orchestration.darwin_words({ "test", "--bail" }, modules)
  assert(queued ~= nil and table.concat(queued, " ") ==
      "test --all --census --bail core/a_test.tl build/b_test.tl", "the merge queue's darwin suite")
  assert(Orchestration.darwin_words({ "test", "--all" }, modules) == nil,
    "a run of every test ran the darwin list again")
  assert(Orchestration.darwin_words({ "test" }, {}) == nil)
end

--- A listed module does not stand in the darwin suite: in a project
--- whose one test stood on its verdict, keyed by declarations as the
--- macOS leg's suite is, the darwin suite's words run it again.
local function test_a_listed_module_runs_where_it_would_stand(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  local host = assert(Proc.executable())
  local project = tmp .. "/darwin-project"
  assert(Fs.mkdirs(project))
  assert(Fs.write(project .. "/a_test.tl", "local function test_a()\n  assert(true)\nend\n"))
  assert(Fs.write(project .. "/b_test.tl", "local function test_b()\n  assert(true)\nend\n"))
  local env = Fixture.environment({ COSMIC_TEST_SANDBOX = "0",
    COSMIC_VERDICT_CACHE = "0", COSMIC_TEST_ALL = "", COSMIC_TEST_NO_SHARED = "",
    COSMIC_SANDBOX = "", TMPDIR = tmp })
  local function run(label: string, words: {string}): string
    local outcome = Fixture.call_with_environment(label, append({ host }, words), project,
      tmp .. "/logs", env)
    local out = Fixture.read(outcome.out)
    assert(outcome.result.ok, label .. ": " .. out .. Fixture.read(outcome.err))
    return out
  end
  run("darwin-first", { "test" })
  local again = run("darwin-again", { "test" })
  assert(again:find("0 ran, 2 stood", 1, true), "the tests did not stand: " .. again)
  local words = assert(Orchestration.darwin_words({ "test" }, { "a_test.tl" }))
  local listed = run("darwin-listed", words)
  assert(listed:find("1 ran, 0 stood", 1, true), "the listed module stood: " .. listed)
end

--- The darwin suite is a phase of its own (`darwin-suite`, after
--- `local-boundary`), which on the macOS leg, where it stands on
--- verdicts, runs the listed modules with a row of its own, "darwin",
--- and fails where they fail. The scheduled run's native suite, `--all`,
--- runs them already, as does a native suite where none stood (a core
--- change's), and a Linux leg has none: there it does nothing.
local function test_the_darwin_suite_runs_on_the_macos_legs_gating_runs_alone(tmp: string)
  local base, project = command(tmp)
  local darwin = "test --all --census core/a_test.tl build/b_test.tl"
  local cases: {DarwinCase} = {
    { name = "macos-push", target = "aarch64-macos", event = "push", sandbox = "0",
      ran = "test --census\n" .. darwin .. "\n", suites = "local darwin", ok = true,
      stood = 3 },
    { name = "macos-failing", target = "aarch64-macos", event = "push", sandbox = "0",
      ran = "test --census\n" .. darwin .. "\n", suites = "local darwin", ok = false,
      stood = 3 },
    { name = "macos-none-stood", target = "aarch64-macos", event = "push", sandbox = "0",
      ran = "test --census\n", suites = "local", ok = true, stood = 0 },
    { name = "macos-schedule", target = "aarch64-macos", event = "schedule", sandbox = "0",
      ran = "test --census --all\n", suites = "local", ok = true, stood = 0 },
    { name = "linux-push", target = "x86_64-linux-musl", event = "push", sandbox = "1",
      ran = "test --census\n", suites = "local", ok = true, stood = 3 },
  }
  for _, case in ipairs(cases) do
    local fake = tmp .. "/" .. case.name
    local runner_temp = fake .. "-runner-temp"
    assert(Fs.mkdirs(fake .. "/bin") and Fs.mkdirs(fake .. "/ci/testdata/portable"))
    assert(Fs.mkdirs(runner_temp .. "/cosmic-ci"))
    assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
    assert(Fs.write(fake .. "/ci/testdata/portable/work_db_integrity.tl", "\n"))
    assert(Fs.write(fake .. "/ci/darwin-tests.txt",
      "# why\ncore/a_test.tl\n\nbuild/b_test.tl # and why\n"))
    -- bin/zig's boot leaves a cosmic that logs each command line and
    -- says a suite's figures: the native suite's with the case's stood
    -- count, and a failure, in the failing case, for the darwin suite's
    -- line.
    local failing = if case.ok then "" else
      "if [ \"$*\" = '" .. darwin .. "' ]; then printf '%s\\n' " ..
        "'test: 1 of 2 tests failed, 0 infrastructure errors, 5 ms; unsandboxed'; exit 1; fi\n" end
    Fixture.write(fake .. "/bin/zig", "#!/bin/sh\nmkdir -p o/bin\nprintf db > o/build.db\n" ..
        "cat > o/bin/cosmic <<'EOF'\n#!/bin/sh\n" ..
        "if [ \"$1\" = test ]; then printf '%s\\n' \"$*\" >> \"$0.ran\"; fi\n" .. failing ..
        "case \"$*\" in 'test --census'*) printf '%s\\n' " ..
        "'test: " .. tostring(2 + case.stood) .. " tests passed in 2 modules; 2 ran, " .. tostring(case.stood) ..
        " stood, 5 ms; unsandboxed'; exit 0;; esac\n" ..
        "if [ \"$1\" = test ]; then printf '%s\\n' " ..
        "'test: 2 tests passed in 2 modules; 2 ran, 0 stood, 5 ms; unsandboxed'; fi\nexit 0\nEOF\n" ..
        "chmod 755 o/bin/cosmic\n", 493)
    local env = context(fake, runner_temp, { TARGET = case.target,
      TMPDIR = tmp, COSMIC_CI_EVENT = case.event, COSMIC_CI_HARNESS_MOVED = "0",
      COSMIC_CI_REQUIRE_SANDBOX = case.sandbox,
      COSMIC_CI_DECLARED_KEYS = if case.sandbox == "1" then "0" else "1" end })
    for _, phase in ipairs({ "build", "local-boundary", "darwin-suite" }) do
      local outcome = Fixture.call("darwin-" .. case.name .. "-" .. phase,
        append(base, { "platform", phase }), project, tmp .. "/logs", env)
      local err = Fixture.read(outcome.err)
      local ok = case.ok or phase ~= "darwin-suite"
      assert(outcome.result.ok == ok, case.name .. ": " .. phase .. ": " .. err)
    end
    local ran = Fs.read(fake .. "/o/bin/cosmic.ran")
    assert(ran == case.ran, case.name .. ": " .. tostring(ran))
    local db = assert(Sqlite.open(runner_temp .. "/cosmic-ci/operations.db"))
    local names: mut {string} = {}
    for _, row in ipairs(State.suite_rows(db)) do
      names[#names + 1] = row.suite
      local passed = case.ok or row.suite ~= "darwin"
      assert(row.status == (if passed then "pass" else "fail" end), case.name .. ": " .. row.suite ..
          ": " .. tostring(row.status))
      local stood = if row.suite == "local" then case.stood else 0 end
      assert(not passed or (row.ran == 2 and row.stood == stood), case.name .. ": " .. row.suite)
    end
    assert(db:close())
    assert(table.concat(names, " ") == case.suites, case.name .. ": " .. table.concat(names, " "))
  end
end

--- What the checked job's leg promises and `checked`, which the run's core
--- does not have: the phase leaves that one out.
local narrowing_promised <const> = "all_cores,sandbox,landlock,userns,nest,own_proc,proc,unix_socket,path:/bin/sh," ..
  "path:/bin/cat,path:/proc/thread-self/children,path:/usr/bin/env,path:/etc/passwd"

--- Runs the `checked-narrowing` phase of a fixture checkout for each of
--- `cases` and holds what the fixture's tool was run as, and whether the
--- phase failed, to the case.
local function run_narrowing_cases(tmp: string, cases: {ChecksCase})
  local base, project = command(tmp)
  for _, case in ipairs(cases) do
    local fake = tmp .. "/" .. case.name
    local runner_temp = fake .. "-runner-temp"
    assert(Fs.mkdirs(fake .. "/bin") and Fs.mkdirs(fake .. "/ci/testdata/portable"))
    assert(Fs.mkdirs(runner_temp .. "/cosmic-ci"))
    assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
    -- bin/zig's boot leaves a cosmic that logs the command line and the
    -- test timeout it was given, and says what a checked run does.
    local written = if case.empty == true then "0 fact wraps and 0 parameter checks" else
      "12 fact wraps and 7 parameter checks" end
    local summary = if case.report then
      "printf '%s\\n' 'test: run-time types: 0 violations, 0 distinct, at 0 places' " ..
        "'test: run-time types: " .. written .. " written in the compile; 0 tests stood on checked verdicts'\n" else "" end
    Fixture.write(fake .. "/bin/zig", "#!/bin/sh\nmkdir -p o/bin\nprintf db > o/build.db\n" ..
        "cat > o/bin/cosmic <<'EOF'\n#!/bin/sh\n" ..
        "if [ \"$1\" = test ]; then printf '%s %s %s %s\\n' \"$*\" \"$COSMIC_TEST_TIMEOUT\" \"$COSMIC_TEST_PROMISES\" \"${COSMIC_VERDICT_CACHE:--}\" >> \"$0.ran\"; fi\n" ..
        summary .. "exit " .. tostring(case.status) .. "\nEOF\n" ..
        "chmod 755 o/bin/cosmic\n", 493)
    local given: mut {string:string} = { TARGET = case.target, TMPDIR = tmp,
      COSMIC_WORKER = "linux-x86_64-checked", COSMIC_CI_NARROWING_SHARD = case.share or "",
      COSMIC_CI_EVENT = "push", COSMIC_CI_HARNESS_MOVED = "0" }
    for name, value in pairs(case.env or {}) do given[name] = (value:gsub("@", tmp)) end
    local env = context(fake, runner_temp, given)
    for _, phase in ipairs({ "boot", "checked-narrowing" }) do
      local outcome = Fixture.call("checked-narrowing-" .. case.name .. "-" .. phase,
        append(base, { "platform", phase }), project, tmp .. "/logs", env)
      local ok = phase == "boot" or case.ok
      assert(outcome.result.ok == ok, case.name .. ": " .. phase .. ": " .. Fixture.read(outcome.err))
    end
    local ran = Fs.read(fake .. "/o/bin/cosmic.ran")
    assert(ran == case.ran, case.name .. ": " .. tostring(ran))
  end
end

--- The `checked-narrowing` phase runs the whole suite on a checked run
--- (`test --check-types`, no module named) on the linux-x86_64 leg, or the
--- share of it COSMIC_CI_NARROWING_SHARD names (`--shard I/N`, which the jobs
--- of ci.yml's `checked-narrowing` matrix set), with the checked run's test
--- timeout, fails where that run fails or reports nothing of its checks, and
--- does nothing on another target.
local function test_the_checked_narrowing_phase_runs_the_whole_suite_checked_on_linux_x86_64(tmp: string)
  local promised = narrowing_promised
  local cases: {ChecksCase} = {
    -- A run that requires no sandbox stands on nothing: every test runs, and the cache variable names no file here.
    { name = "linux", target = "x86_64-linux-musl", report = true, status = 0, ok = true,
      ran = "test --check-types --census --all 120 " .. promised .. " 0\n" },
    { name = "linux-share", target = "x86_64-linux-musl", report = true, status = 0, ok = true,
      share = "2/2", ran = "test --check-types --census --all --shard 2/2 120 " .. promised .. " 0\n" },
    { name = "linux-share-failing", target = "x86_64-linux-musl", report = true, status = 1, ok = false,
      share = "1/2", ran = "test --check-types --census --all --shard 1/2 120 " .. promised .. " 0\n" },
    { name = "linux-failing", target = "x86_64-linux-musl", report = true, status = 1, ok = false,
      ran = "test --check-types --census --all 120 " .. promised .. " 0\n" },
    { name = "linux-unchecked", target = "x86_64-linux-musl", report = false, status = 0, ok = false,
      ran = "test --check-types --census --all 120 " .. promised .. " 0\n" },
    { name = "linux-empty", target = "x86_64-linux-musl", report = true, status = 0, ok = false, empty = true,
      ran = "test --check-types --census --all 120 " .. promised .. " 0\n" },
    { name = "linux-aarch64", target = "aarch64-linux-musl", report = true, status = 0, ok = true,
      ran = nil },
  }
  run_narrowing_cases(tmp, cases)
end

--- The phase stands on `narrowing.db`, beside the file COSMIC_VERDICT_CACHE
--- names, where the job may stand on verdicts (it requires the sandbox):
--- a share and a merge-queue run both, the queue's also stopping at the
--- first failure, and every test where the queue's change moves the
--- harness.
local function test_the_checked_narrowing_phase_stands_on_a_verdict_file_of_its_own(tmp: string)
  local promised = narrowing_promised
  local cases: {ChecksCase} = {
    -- A job that restores verdicts (ci.yml's names the file and requires the sandbox) stands on them in
    -- `narrowing.db`, beside the file it names; the merge queue's run also stops at its first failure.
    { name = "linux-standing", target = "x86_64-linux-musl", report = true, status = 0, ok = true,
      share = "1/2", env = { COSMIC_CI_REQUIRE_SANDBOX = "1", COSMIC_VERDICT_CACHE = "@/verdicts/verdicts.db" },
      ran = "test --check-types --census --shard 1/2 120 " .. promised .. " " .. tmp .. "/verdicts/narrowing.db\n" },
    { name = "linux-queue", target = "x86_64-linux-musl", report = true, status = 0, ok = true, share = "2/2",
      env = { COSMIC_CI_REQUIRE_SANDBOX = "1", COSMIC_CI_EVENT = "merge_group", COSMIC_CI_HARNESS_MOVED = "0",
        COSMIC_VERDICT_CACHE = "@/verdicts/verdicts.db" },
      ran = "test --check-types --census --bail --shard 2/2 120 " .. promised .. " " .. tmp .. "/verdicts/narrowing.db\n" },
    -- A queue run whose change moves the harness runs every test, standing on none.
    { name = "linux-queue-moved", target = "x86_64-linux-musl", report = true, status = 0, ok = true,
      env = { COSMIC_CI_REQUIRE_SANDBOX = "1", COSMIC_CI_EVENT = "merge_group", COSMIC_CI_HARNESS_MOVED = "1",
        COSMIC_VERDICT_CACHE = "@/verdicts/verdicts.db" },
      ran = "test --check-types --census --all --bail 120 " .. promised .. " " .. tmp .. "/verdicts/narrowing.db\n" },
  }
  run_narrowing_cases(tmp, cases)
end

--- A native suite that passed with none standing ran every test it
--- chose; one where any stood, that failed, or that the driver ended
--- did not, nor did one that said no summary or ran a share.
local function test_a_native_suite_ran_every_test_where_none_stood()
  local Orchestration = require("cosmic_ci.orchestration")
  local function line(ran: integer, stood: integer): string
    return string.format("test: %d tests passed in 3 modules; %d ran, %d stood, 5 ms; unsandboxed\n",
      ran + stood, ran, stood)
  end
  assert(Orchestration.native_ran_every(line(4, 0), 0))
  assert(not Orchestration.native_ran_every(line(4, 1), 0))
  assert(not Orchestration.native_ran_every(line(4, 0), 1))
  assert(not Orchestration.native_ran_every(line(4, 0), 124))
  assert(not Orchestration.native_ran_every("", 0))
  assert(not Orchestration.native_ran_every(
    "test: 4 tests passed in 3 modules; 4 ran, 0 stood, 5 ms; unsandboxed; shard 1 of 2\n", 0))
  assert(not Orchestration.native_ran_every(
    "test: 1 of 4 tests failed, 0 infrastructure errors, 5 ms; unsandboxed\n", 1))
end

--- The noexec launcher uses the same keyed product contract as the
--- ordinary launcher, adding only a requested private mount grant.
local function test_noexec_launcher_declares_its_grant_and_keeps_keyed_verdicts(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  assert(Orchestration.sandboxed_fixtures()["launcher_noexec"])
  local source = code_of("launcher_noexec")
  assert(source:find('{ path = "/noexec", letters = "rwc" }', 1, true) and
      source:find('profiles = { "system" }', 1, true))
  assert(source:find('Env.get("COSMIC_TEST_NOEXEC")', 1, true))
  assert(not source:find("COSMIC_PORTABLE_NOEXEC_ROOT", 1, true) and
      not source:find("/dev/shm", 1, true), "noexec fixture discovers host scratch")
  for _, target in ipairs({ "x86_64-linux-musl", "aarch64-linux-musl" }) do
    assert(Orchestration.noexec_fixture(target), target .. ": no noexec fixture scheduled")
    local env = Orchestration.fixture_run("launcher_noexec", {
      COSMIC_CI_EVENT = "push", COSMIC_CI_REQUIRE_SANDBOX = "1",
      COSMIC_TEST_SANDBOX = "1", COSMIC_SANDBOX = "must",
      COSMIC_FIXTURE_TARGET = target,
      COSMIC_VERDICT_CACHE = tmp .. "/verdicts.db",
    }, tmp .. "/tmp", tmp .. "/compiles.db")
    assert(env["COSMIC_TEST_SANDBOX"] == "1" and env["COSMIC_SANDBOX"] == "must")
    assert(env["COSMIC_VERDICT_CACHE"] == tmp .. "/fixtures.db" and env["COSMIC_TEST_NO_SHARED"] == nil)
  end
  for _, target in ipairs({ "aarch64-macos", "x86_64-windows", "", "unknown" }) do
    assert(not Orchestration.noexec_fixture(target), target .. ": unsupported noexec fixture scheduled")
  end
end

--- A suite on a leg is given the requirements the leg promises
--- (ci/cosmic_ci/capabilities.json) and its name, so a held `cosmic test`
--- fails a module for lacking one; a worker that is no leg's is given
--- none, and a list the caller set is left alone.
local function test_a_leg_is_given_the_requirements_it_promises()
  local Orchestration = require("cosmic_ci.orchestration")
  local linux: {string:string} = { COSMIC_WORKER = "linux-x86_64-shard" }
  linux = Orchestration.promise(linux)
  assert(linux["COSMIC_TEST_LEG"] == "linux-x86_64-shard")
  assert(("," .. assert(linux["COSMIC_TEST_PROMISES"]) .. ","):find(",nest,", 1, true), linux["COSMIC_TEST_PROMISES"])
  local mac: {string:string} = { COSMIC_WORKER = "macos-aarch64" }
  mac = Orchestration.promise(mac)
  assert(mac["COSMIC_TEST_LEG"] == "macos-aarch64")
  local given = "," .. assert(mac["COSMIC_TEST_PROMISES"]) .. ","
  assert(given:find(",path:/bin/sh,", 1, true) and given:find(",path:/usr/bin/env,", 1, true),
    mac["COSMIC_TEST_PROMISES"])
  assert(not given:find(",sandbox,", 1, true) and not given:find(",nest,", 1, true),
    mac["COSMIC_TEST_PROMISES"])
  for _, worker in ipairs({ "provenance", "fuzz", "" }) do
    local other: {string:string} = { COSMIC_WORKER = worker }
    other = Orchestration.promise(other)
    assert(other["COSMIC_TEST_PROMISES"] == nil and other["COSMIC_TEST_LEG"] == nil, worker)
  end
  local chosen: {string:string} = { COSMIC_WORKER = "linux-x86_64", COSMIC_TEST_PROMISES = "proc" }
  chosen = Orchestration.promise(chosen)
  assert(chosen["COSMIC_TEST_PROMISES"] == "proc" and chosen["COSMIC_TEST_LEG"] == nil)
end

--- A fixture runner is given its leg's promises as a candidate
--- suite is, Unix sockets among them.
local function test_a_fixture_is_given_its_legs_promises(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  for _, source in ipairs({ "format", "runtime" }) do
    local env: {string:string} = {
      COSMIC_WORKER = "linux-x86_64-checked", COSMIC_CI_EVENT = "push",
      COSMIC_TEST_SANDBOX = "1", COSMIC_SANDBOX = "must",
      COSMIC_VERDICT_CACHE = tmp .. "/verdicts.db",
    }
    env = Orchestration.promise(env)
    local candidate = "," .. assert(env["COSMIC_TEST_PROMISES"]) .. ","
    assert(candidate:find(",unix_socket,", 1, true), candidate)
    local fixture = Orchestration.fixture_run(source, env, tmp .. "/tmp", tmp .. "/c.db")
    local given = "," .. assert(fixture["COSMIC_TEST_PROMISES"]) .. ","
    assert(given == candidate, "the fixture changed its leg's promises: " .. given)
    assert(fixture["COSMIC_TEST_LEG"] == "linux-x86_64-checked")
    assert(fixture["COSMIC_SANDBOX"] == "must", "fixture confinement is no longer held")
    assert(fixture["COSMIC_TEST_SANDBOX"] == (if source == "runtime" then "1" else "0" end))
  end
  local words, candidate = suite_run({ COSMIC_WORKER = "linux-x86_64-checked" })
  assert(words[1] == "test")
  assert(("," .. assert(candidate["COSMIC_TEST_PROMISES"]) .. ","):find(",unix_socket,", 1, true),
    candidate["COSMIC_TEST_PROMISES"])
  local unknown = Orchestration.fixture_run("format", {
    COSMIC_TEST_PROMISES = "proc, unix_socket ,future_requirement,checked",
  }, tmp .. "/tmp", tmp .. "/c.db")
  assert(unknown["COSMIC_TEST_PROMISES"] == "proc, unix_socket ,future_requirement,checked",
    "the fixture changed the promises it was given")
end

--- A fixture's figures reach the job's log, each line with the fixture's
--- name, in the order of their files, and a fixture with none says nothing.
local function test_a_fixtures_figures_are_said_with_its_name(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  local directory = tmp .. "/figures"
  assert(Fs.mkdirs(directory))
  assert(Fs.write(directory .. "/b.figure", "second: 2 ms\n"))
  assert(Fs.write(directory .. "/a.figure", "first: 1 ms\nfirst again: 3 ms\n"))
  assert(Fs.write(directory .. "/notes.txt", "not a figure\n"))
  local sink = assert(Fs.open_write(tmp .. "/sink"))
  local said = Orchestration.say_figures("some-regression", directory, sink)
  assert(Fs.close(sink))
  assert(said == 3, "said " .. tostring(said))
  assert(assert(Fs.read(tmp .. "/sink")) ==
      "some-regression: first: 1 ms\nsome-regression: first again: 3 ms\nsome-regression: second: 2 ms\n")
  assert(Orchestration.say_figures("none", tmp .. "/absent") == 0)
  assert(Fs.mkdirs(tmp .. "/empty"))
  assert(Orchestration.say_figures("none", tmp .. "/empty") == 0)
end

--- A fixture project made again at the same path starts with no build
--- directory: that is outside the project, named by its path, and what
--- the fixture before had placed there would refuse the next placement.
local function test_a_fixture_project_made_again_has_no_build_left(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  local driver = tmp .. "/ci/cosmic_ci/driver.tl"
  assert(Fs.mkdirs(tmp .. "/ci/cosmic_ci") and Fs.mkdirs(tmp .. "/ci/fixtures"))
  assert(Fs.write(driver, "return 0\n"))
  assert(Fs.write(tmp .. "/ci/fixtures/a_test.tl", "\n"))
  local project = Orchestration.fixture_project(driver, tmp .. "/work")
  local placed = BuildPaths.driven(project) .. "/fixtures/launcher"
  assert(Fs.mkdirs(placed) and Fs.write(placed .. "/file", "earlier"))
  assert(Orchestration.fixture_project(driver, tmp .. "/work") == project)
  assert(Fs.read(project .. "/fixtures/a_test.tl") == "\n")
  assert(Fs.exists(placed) ~= true, "the earlier fixture's placement was kept")
end

--- The fixture project holds the driver namespace's JSON data beside its
--- modules (the capabilities and run names the driver reads), and refuses
--- any other file there.
local function test_a_fixture_project_takes_the_drivers_json_data(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  local driver = tmp .. "/ci/cosmic_ci/driver.tl"
  assert(Fs.mkdirs(tmp .. "/ci/cosmic_ci") and Fs.mkdirs(tmp .. "/ci/fixtures"))
  assert(Fs.write(driver, "return 0\n"))
  assert(Fs.write(tmp .. "/ci/cosmic_ci/capabilities.json", "{}\n"))
  assert(Fs.write(tmp .. "/ci/cosmic_ci/run_names.json", "{}\n"))
  local project = Orchestration.fixture_project(driver, tmp .. "/work")
  assert(Fs.read(project .. "/cosmic_ci/capabilities.json") == "{}\n")
  assert(Fs.read(project .. "/cosmic_ci/run_names.json") == "{}\n")
  assert(Fs.write(tmp .. "/ci/fixtures/data.json", "{}\n"))
  local called, _ = pcall(Orchestration.fixture_project, driver, tmp .. "/work")
  assert(not called, "a JSON file among the fixtures was copied")
end

local type Orch = require("cosmic_ci.orchestration")

--- A bound for a group that should end at once: only a hang reaches it.
local lane_hang_guard = Clock.seconds(20)

--- Groups of `/bin/sh` scripts for `Orchestration.run_groups`, whose log
--- goes to `sink` when it ends, with an `events` list of how each ended.
local record LaneRig
  events: {string}
  sink: integer
  group: function(name: string, script: string, timeout_ns?: integer): Orch.Group
  serial: function(name: string, status: integer): Orch.Group
end

local function lane_rig(tmp: string): LaneRig
  local Orchestration = require("cosmic_ci.orchestration")
  local Runner = require("cosmic_ci.runner")
  local candidate, state = tmp .. "/candidate", tmp .. "/state"
  assert(Fs.mkdirs(candidate) and Fs.mkdirs(state) and Fs.mkdirs(tmp .. "/logs"))
  local c: Runner.Context = { database = state .. "/operations.db", worker = "worker",
    run = "run", attempt = "1", candidate = candidate }
  local events: mut {string} = {}
  local sink = assert(Fs.open_write(tmp .. "/sink"))
  local function group(name: string, script: string, timeout_ns?: integer): Orch.Group
    local out, err = tmp .. "/logs/" .. name .. ".out", tmp .. "/logs/" .. name .. ".err"
    return {
      name = name,
      run = function(): integer
        events[#events + 1] = "run:" .. name
        return 0
      end,
      start = function(): Runner.Running
        events[#events + 1] = "start:" .. name
        return Runner.spawn(c, name, { argv = { "/bin/sh", "-c", script }, cwd = candidate,
          output = out, error = err, timeout_ns = timeout_ns or lane_hang_guard })
      end,
      finish = function(outcome: Runner.Outcome): integer
        events[#events + 1] = "finish:" .. name .. ":" .. outcome.status
        assert(Orchestration.replay(out, err, sink, sink))
        return outcome.code
      end,
      abandon = function(outcome: Runner.Outcome)
        events[#events + 1] = "abandon:" .. name .. ":" .. outcome.status
        assert(Orchestration.replay(out, err, sink, sink))
      end,
    }
  end
  local function serial(name: string, status: integer): Orch.Group
    local made = group(name, "exit 0")
    return {
      name = name,
      run = function(): integer
        events[#events + 1] = "run:" .. name
        return status
      end,
      start = made.start,
      finish = made.finish,
      abandon = made.abandon,
    }
  end
  return { events = events, sink = sink, group = group, serial = serial }
end

local function gone(pid: integer): boolean
  return not sys.kill(pid, 0)
end

local function pid_of(path: string): integer
  local waited = Clock.monotonic_ns()
  while not Predicate.exists(path) and Clock.monotonic_ns() - waited < lane_hang_guard do
    Clock.sleep_ns(Clock.ms(10))
  end
  return assert(math.tointeger(tonumber((assert(Fs.read(path)):gsub("%s", "")))))
end

local function test_a_failing_group_stops_the_other_lane_and_starts_nothing_after(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  for _, high_fails in ipairs({ false, true }) do
    local dir = tmp .. (if high_fails then "/high" else "/low" end)
    local rig = lane_rig(dir)
    local hang = "echo $$ > " .. dir .. "/hung.pid; (sleep 30) & wait"
    local fail = "sleep 0.3; exit 7"
    local high_command, first_command = hang, fail
    if high_fails then high_command, first_command = fail, hang end
    local high = rig.group("high", high_command)
    local first = rig.group("first", first_command)
    local after = rig.group("after", "touch " .. dir .. "/after.ran")
    local started = Clock.monotonic_ns()
    local status = Orchestration.run_groups(high, { first, after }, true)
    assert(status == 7, "the failing group's status was not returned: " .. tostring(status))
    assert(Clock.monotonic_ns() - started < Clock.seconds(10), "the hung group was waited out")
    assert(gone(pid_of(dir .. "/hung.pid")), "the other lane's group was left running")
    assert(not Predicate.exists(dir .. "/after.ran") and
        not table.concat(rig.events, " "):find("start:after", 1, true),
      "a group started after a failure")
    local hung = if high_fails then "first" else "high" end
    local failed = if high_fails then "high" else "first" end
    local text = table.concat(rig.events, " ")
    assert(text:find("finish:" .. failed .. ":exit", 1, true) and
        text:find("abandon:" .. hung .. ":cancelled", 1, true),
      "the stopped group was not reaped and reported: " .. text)
  end
end

local function test_a_hung_group_meets_its_own_timeout_beside_a_running_lane(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  local rig = lane_rig(tmp)
  local high = rig.group("high", "sleep 30", Clock.ms(300))
  local long = rig.group("long", "sleep 30")
  local started = Clock.monotonic_ns()
  local status = Orchestration.run_groups(high, { long }, true)
  assert(status == 124, "a timeout was not the group's status: " .. tostring(status))
  assert(Clock.monotonic_ns() - started < Clock.seconds(10),
    "the hung group ran past its own timeout")
  local text = table.concat(rig.events, " ")
  assert(text:find("finish:high:timeout", 1, true) and
      text:find("abandon:long:cancelled", 1, true), text)
  -- The low lane's group is bound by its own timeout as well, and it is
  -- not lengthened for sharing the budget.
  local rig_low = lane_rig(tmp .. "/low")
  local quick = rig_low.group("high", "sleep 30")
  local slow = rig_low.group("slow", "sleep 30", Clock.ms(300))
  assert(Orchestration.run_groups(quick, { slow }, true) == 124)
  assert(table.concat(rig_low.events, " "):find("finish:slow:timeout", 1, true))
end

local function test_group_logs_are_replayed_whole_and_in_the_order_the_groups_end(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  local rig = lane_rig(tmp)
  local high = rig.group("high", "echo h1; sleep 1.5; echo h2; echo e1 >&2")
  local one = rig.group("one", "echo a1; sleep 0.1; echo a2")
  local two = rig.group("two", "echo b1; sleep 0.1; echo b2")
  assert(Orchestration.run_groups(high, { one, two }, true) == 0)
  assert(Fs.close(rig.sink))
  assert(assert(Fs.read(tmp .. "/sink")) == "a1\na2\nb1\nb2\nh1\nh2\ne1\n",
    "logs were interleaved or out of order: " .. assert(Fs.read(tmp .. "/sink")))
  assert(table.concat(rig.events, " ") == "start:high start:one finish:one:success " ..
      "start:two finish:two:success finish:high:success", table.concat(rig.events, " "))
end

local function test_without_lanes_the_groups_run_one_after_another_as_before(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  local rig = lane_rig(tmp)
  local status = Orchestration.run_groups(rig.serial("high", 0),
    { rig.serial("a", 0), rig.serial("b", 3), rig.serial("c", 0) }, false)
  assert(status == 3 and table.concat(rig.events, " ") == "run:high run:a run:b",
    "the serial path changed: " .. table.concat(rig.events, " "))
  local ok = lane_rig(tmp .. "/ok")
  assert(Orchestration.run_groups(ok.serial("high", 0), { ok.serial("a", 0) }, false) == 0)
  assert(table.concat(ok.events, " ") == "run:high run:a")
  assert(not table.concat(rig.events, " "):find("start:", 1, true), "the serial path spawned a group")
end

local function test_the_lanes_are_off_unless_asked_for_and_never_exceed_the_processors()
  assert(fixture_lanes({}, 8) == nil)
  assert(fixture_lanes({ COSMIC_CI_FIXTURE_BUDGET = "skip" }, 8) == nil)
  assert(fixture_lanes({ COSMIC_CI_FIXTURE_BUDGET = "run" }, 1) == nil,
    "one processor was shared by two lanes")
  for cpus = 2, 64 do
    local high, low = fixture_lanes({ COSMIC_CI_FIXTURE_BUDGET = "run" }, cpus)
    assert(high ~= nil and low ~= nil and low == 1 and high >= 1 and high + low == cpus,
      "the lanes' workers are not the processors at " .. tostring(cpus))
  end
end

local function test_only_the_two_linux_legs_ask_for_the_fixture_lanes()
  local legs, env = platform_legs_and_env()
  local value = assert(env["COSMIC_CI_FIXTURE_BUDGET"], "ci.yml's platform job sets no COSMIC_CI_FIXTURE_BUDGET")
  local one, two = value:match("^%${{ %(matrix%.name == '([%w_-]+)' || " ..
      "matrix%.name == '([%w_-]+)'%) && 'run' || 'skip' }}$")
  assert(one and two and legs[one] and legs[two] and
      ((one == "linux-aarch64" and two == "alpine-x86_64") or
        (two == "linux-aarch64" and one == "alpine-x86_64")),
    "the fixture lanes run on other legs than linux-aarch64 and alpine-x86_64: " .. value)
end

--- A cache of `declared_v1`'s shape holding a row under each of `parts`
--- (build/shared_verdicts.tl stamps them as "host features X, host Y").
local function stamped_cache(path: string, parts: {string})
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("CREATE TABLE declared_v1 (key TEXT PRIMARY KEY, test TEXT NOT NULL, " ..
      "hits BLOB NOT NULL, elapsed_ns INTEGER NOT NULL, used_ns INTEGER NOT NULL, " ..
      "origin TEXT NOT NULL, parts TEXT NOT NULL DEFAULT '')"))
  for at, named in ipairs(parts) do
    assert(Sqlite.run(db, "INSERT INTO declared_v1 VALUES (?1, 't.tl test', zeroblob(1), 1, 1, 'o', ?2)",
      { { text = "k" .. tostring(at) }, { text = named } }))
  end
  assert(db:close())
end

local function test_the_gathering_run_counts_the_rows_it_cannot_stand_on(tmp: string)
  local Orchestration = require("cosmic_ci.orchestration")
  local path = tmp .. "/checked.db"
  stamped_cache(path, {
    "host features aaaa, host h1", "host features aaaa, host h1",
    "host features bbbb, host h1", "host features aaaaaaaa, host h1", "", "host features bbbb",
    -- Another host's rows that name their identity and rest are looked up
    -- under its key, not run again; one that names only one of them is.
    "host features bbbb, host h1, host identity 01, host rest 02",
    "host features bbbb, host h1, host identity 01",
  })
  -- Only the exact digest and its comma count as this host's: a longer
  -- digest that starts with it, rows of no parts and rows of other
  -- features are all run again here.
  assert(Orchestration.stale_rows(path, "aaaa") == 5)
  assert(Orchestration.stale_rows(path, "bbbb") == 5)
  assert(Orchestration.stale_rows(path, "cccc") == 7)
  local count, why = Orchestration.stale_rows(path, "aaaa' OR '1")
  assert(count == nil and why:find("no digest", 1, true) ~= nil, why)
  assert(Fs.write(tmp .. "/text.db", "checked\n"))
  count, why = Orchestration.stale_rows(tmp .. "/text.db", "aaaa")
  assert(count == nil and why ~= "", "a file that is no cache was counted")
end

local function test_the_gathering_run_is_given_a_time_for_each_row_it_runs_again()
  local Orchestration = require("cosmic_ci.orchestration")
  local base = Orchestration.gather_bound(0)
  assert(base == Clock.seconds(300), "the gathering run's base moved")
  -- Run 40495570639 of #3263 ran 2046 tests again at about 330 a
  -- minute (370 s), on top of the 150 s the rest took (167 s in all
  -- for 136 rows run again).
  local needed = Clock.seconds(150) + 2046 * (Clock.seconds(60) // 330)
  assert(Orchestration.gather_bound(2046) > needed,
    "2046 rows run again at the pace seen do not fit their bound")
  assert(Orchestration.gather_bound(100) > base and Orchestration.gather_bound(100) < Orchestration.gather_bound(2046))
  assert(Orchestration.gather_bound(1000000) == Clock.seconds(780), "the bound has no cap")
end
