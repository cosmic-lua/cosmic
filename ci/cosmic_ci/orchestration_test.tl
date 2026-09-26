local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Fixture = require("cosmic_ci.fixture")

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

--- The sandbox phase fails where the probe says a confined test's parts
--- did not all hold, and passes where they did, writing the report to
--- the summary either way.
local function test_the_sandbox_phase_fails_where_confinement_is_unavailable(tmp: string)
  local base, project = command(tmp)
  for _, case in ipairs({
    { name = "unavailable", said = "Confinement: **unavailable** (unveil).", ok = false },
    { name = "available", said = "Confinement: available.", ok = true },
  }) do
    local fake = tmp .. "/" .. case.name
    local runner_temp = fake .. "-runner-temp"
    assert(Fs.mkdirs(fake .. "/o/bin") and Fs.mkdirs(runner_temp))
    assert(Fs.write(fake .. "/AGENTS.md", "fixture\n"))
    Fixture.write(fake .. "/o/bin/cosmic", "#!/bin/sh\nprintf '| Part |\\n\\n" ..
      case.said .. "\\n'\n", 493)
    local summary = runner_temp .. "/summary.md"
    local outcome = Fixture.call("sandbox-" .. case.name, append(base, { "platform", "sandbox" }),
      project, tmp .. "/logs", context(fake, runner_temp, {
        TARGET = "x86_64-linux-musl", GITHUB_STEP_SUMMARY = summary,
      }))
    assert(outcome.result.ok == case.ok, "the sandbox phase answered " ..
      tostring(outcome.result.ok) .. " where the probe said " .. case.said)
    Fixture.contains(summary, case.said)
    if not case.ok then Fixture.contains(outcome.err, "cannot confine a test") end
  end
end
