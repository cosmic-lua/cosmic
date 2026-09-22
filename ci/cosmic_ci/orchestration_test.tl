local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Fixture = require("cosmic_ci.fixture")

--- The candidate checkout root: this test's cwd is `<checkout>/ci`, so
--- its parent is the checkout the self-check runs against.
local function checkout_root(): string
  local cwd = assert(Fs.absolute("."))
  return assert(cwd:match("^(.*)/[^/]+$"), cwd .. ": no parent directory")
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

local function append(base: {string}, values: {string}): {string}
  local out: {string} = {}
  for _, value in ipairs(base) do out[#out + 1] = value end
  for _, value in ipairs(values) do out[#out + 1] = value end
  return out
end

local function test_provenance_failures_are_durable(tmp: string)
  local base, project = command(tmp)
  local candidate, products, state = tmp .. "/candidate", tmp .. "/products", tmp .. "/state"
  assert(Fs.mkdirs(candidate) and Fs.mkdirs(products) and Fs.mkdirs(state))
  assert(Fs.write(candidate .. "/AGENTS.md", "fixture\n"))
  for _, name in ipairs({ "a", "b" }) do
    local product = products .. "/portable-product-" .. name
    assert(Fs.mkdirs(product) and Fs.write(product .. "/cosmic", "bytes"))
    local digest = Hash.hex_sha256("bytes")
    assert(Fs.write(product .. "/executed-cosmic.sha256", digest .. "  cosmic\n") and
      Fs.write(product .. "/expected-platforms", "2\n"))
  end
  local good = append(base, { "provenance", state .. "/good.db", "worker", "run",
    "1", candidate, products })
  assert(Fixture.call("good-provenance", good, project, tmp .. "/logs").result.ok)
  assert(Fs.write(products .. "/portable-product-b/cosmic", "changed"))
  local bad = append(base, { "provenance", state .. "/bad.db", "worker", "run",
    "1", candidate, products })
  assert(not Fixture.call("bad-provenance", bad, project, tmp .. "/logs").result.ok)
  local report = append(base, { "report", state .. "/bad.db", state .. "/bad.md" })
  assert(Fixture.call("report", report, project, tmp .. "/logs").result.ok)
  assert(assert(Fs.read(state .. "/bad.md")):find(
    "| worker | run | 1 | provenance | error |", 1, true))
  local product = products .. "/portable-product-b"
  assert(Fs.write(product .. "/cosmic", "bytes") and
    Fs.write(product .. "/executed-cosmic.sha256", "corrupt\n"))
  local corrupt = append(base, { "provenance", state .. "/corrupt.db", "worker",
    "run", "1", candidate, products })
  assert(not Fixture.call("corrupt-attestation", corrupt, project,
    tmp .. "/logs").result.ok)
  assert(assert(Child.run({ "/bin/rm", product .. "/executed-cosmic.sha256" })).ok)
  local missing = append(base, { "provenance", state .. "/missing.db", "worker",
    "run", "1", candidate, products })
  assert(not Fixture.call("missing-attestation", missing, project,
    tmp .. "/logs").result.ok)
end

local function test_platform_protects_paths_and_retains_primary_failure(tmp: string)
  local base, project = command(tmp)
  local fake, work, seed = tmp .. "/fake", tmp .. "/platform", tmp .. "/seed"
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
printf not-a-database > o/build.db
cat > o/bin/cosmic <<'INNER'
#!/bin/sh
if [ "${1-}" = work_db_integrity.tl ]; then mkdir -p o; exit 0; fi
i=0; while [ "$i" -lt 20000 ]; do printf 'large retained output %s\n' "$i"; i=$((i + 1)); done
exit 23
INNER
chmod 755 o/bin/cosmic
]], 493)
  local protected = append(base, { "platform", "build", tmp .. "/path.db", "worker",
    "run", "1", fake, "x86_64-linux-musl", fake .. "/inside" })
  assert(not Fixture.call("protected", protected, project, tmp .. "/logs").result.ok)
  assert(not Fs.exists(fake .. "/inside"))
  local build = append(base, { "platform", "build", work .. "/operations.db",
    "worker", "run", "1", fake, "x86_64-linux-musl", work })
  local outcome = Fixture.call("build", build, project, tmp .. "/logs", {
    COSMIC_ZIG_CACHE_SEED = seed, COSMIC_CI_SELFTEST_REPLAY_FAILURE = "true",
    TMPDIR = tmp .. "/temporary",
  }, 10000)
  assert(outcome.result.code == 23, "suite failure was not primary")
  assert(assert(Fs.stat(work .. "/local-diagnostics/local-test.out")).size > 100000)
  assert(assert(Fs.read(work .. "/local-diagnostics/local-test.status")):find("23", 1, true))
  assert(Fs.is_dir(fake .. "/o/zig-cache") and Fs.is_dir(fake .. "/o/zig-global"))
  assert(not Fs.exists(fake .. "/o/poison"))
  assert(#assert(Fs.list(tmp .. "/temporary")) == 0,
    "snapshot inspection directory was retained")
end
