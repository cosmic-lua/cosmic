local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")

local function environment(extra?: {string:string}): {string:string}
  local values = Env.all()
  if extra then for name, value in pairs(extra) do values[name] = value end end
  return values
end

--- How long a spawned driver.tl may take. It compiles every cosmic_ci
--- module before it does anything, alongside the other self-tests, and on a
--- CI runner that alone has taken over 2 s: a few seconds is too little.
local driver_timeout = 60000

local function call(argv: {string}, cwd: string, output: string,
    extra?: {string:string}, timeout?: integer): Child.Result
  local fd = assert(Fs.open_write(output))
  local result, trouble = Child.run(argv, {
    cwd = cwd, env = environment(extra), stdout = fd, stderr = fd,
    process_group = true, timeout_ms = timeout or 5000,
  })
  assert(Fs.close(fd))
  return (assert(result, trouble))
end

--- The candidate checkout root: this test's cwd is `<checkout>/ci`, so
--- its parent is the checkout the self-check runs against.
local function checkout_root(): string
  local cwd = assert(Fs.absolute("."))
  return (assert(cwd:match("^(.*)/[^/]+$"), cwd .. ": no parent directory"))
end

local function pin(path: string, commit: string, digest: string)
  assert(Fs.write(path, commit .. "\n" ..
    "https://github.com/cosmic-lua/cosmic/releases/download/next-" ..
    commit .. "/cosmic\n" .. digest .. "\n"))
end

--- A checkout of its own at `tmp/root` for bin/cosmic-bootstrap, which
--- reads the pin beside it: the candidate's script, and a pin naming
--- `digest`. Its cache is `tmp/xdg/cosmic/bootstrap`.
local function bootstrap_root(tmp: string, commit: string, digest: string): string, string
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/bin") and Fs.mkdirs(root .. "/ci"))
  assert(Fs.write(root .. "/bin/cosmic-bootstrap",
    (assert(Fs.read(checkout_root() .. "/bin/cosmic-bootstrap"))), 0x1ed))
  pin(root .. "/ci/cosmic-driver.pin", commit, digest)
  local cache = tmp .. "/xdg/cosmic/bootstrap"
  assert(Fs.mkdirs(cache))
  return root, cache
end

--- Runs bin/cosmic-bootstrap under `root` as CI does, re-verifying its
--- cache, with `extra` in its environment.
local function bootstrap(tmp: string, root: string, output: string,
    extra?: {string:string}): Child.Result
  local env: {string:string} = { XDG_CACHE_HOME = tmp .. "/xdg", COSMIC_BOOTSTRAP_VERIFY = "1" }
  if extra then for name, value in pairs(extra) do env[name] = value end end
  return call({ "/bin/sh", root .. "/bin/cosmic-bootstrap" }, tmp, output, env)
end

--- A curl on a PATH of its own that writes `$DOWNLOAD_SOURCE` wherever
--- it is asked to, whatever URL it is given -- unless `$FAIL_ONCE`
--- names a file that is there, when it removes that file, leaves a
--- scrap of a transfer at the output and fails, as a dropped
--- connection would. Each call appends a line to `$CALLS` when set.
local function fake_curl(tmp: string): string
  local fake = tmp .. "/fake bin"
  assert(Fs.mkdirs(fake))
  assert(Fs.write(fake .. "/curl", [[#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then output=$2; shift 2; else shift; fi
done
[ -z "${CALLS:-}" ] || echo call >> "$CALLS"
if [ -n "${FAIL_ONCE:-}" ] && [ -e "$FAIL_ONCE" ]; then
  rm -f "$FAIL_ONCE"
  printf scrap > "$output"
  exit 56
fi
cp "$DOWNLOAD_SOURCE" "$output"
]], 0x1ed))
  return fake .. ":" .. assert(Env.get("PATH"))
end

local function seeded_bootstrap(tmp: string): string, string
  local program = assert(Proc.executable())
  local digest = Hash.hex_sha256((assert(Fs.read(program))))
  local root, cache = bootstrap_root(tmp, string.rep("a", 40), digest)
  assert(Fs.write(cache .. "/cosmic-" .. digest, (assert(Fs.read(program))), 0x1ed))
  local result = bootstrap(tmp, root, tmp .. "/bootstrap.out")
  local out = assert(Fs.read(tmp .. "/bootstrap.out"))
  assert(result.ok, out)
  local runner = out:gsub("\n$", "")
  assert(runner == cache .. "/cosmic-" .. digest, out)
  return runner, digest
end

--- The driver reads its context (GITHUB_WORKSPACE, GITHUB_RUN_ID,
--- GITHUB_RUN_ATTEMPT, RUNNER_TEMP, COSMIC_WORKER) from the environment.
--- In CI the self-check runs inside a job where all of these are already
--- set to the real job's values, so a spawned driver.tl that inherited
--- them would write into that job's own $RUNNER_TEMP/cosmic-ci or append
--- to its real step summary; every test builds this context explicitly
--- and passes it as `call`'s extra env instead.
local function driver_context(candidate: string, runner_temp: string,
    extra?: {string:string}): {string:string}
  local env: {string:string} = {
    GITHUB_WORKSPACE = candidate,
    GITHUB_RUN_ID = "run-1",
    GITHUB_RUN_ATTEMPT = "1",
    RUNNER_TEMP = runner_temp,
    COSMIC_WORKER = "worker",
  }
  if extra then for name, value in pairs(extra) do env[name] = value end end
  return env
end

--- The self-check holds a write transaction on `ci/o/build.db` while
--- tests run, so a test that spawns the host on `driver.tl` must never
--- give it project root `ci/` -- it copies the namespace into its own
--- tmp project first, the way `orchestration_test.tl`'s `command()`
--- does for the same reason.
local function driver_project(tmp: string): string
  local project = tmp .. "/project"
  assert(Fs.mkdirs(project))
  assert(assert(Child.run({ "/bin/cp", "-R",
    Fs.absolute(".") .. "/cosmic_ci", project })).ok)
  return project
end

local function test_bootstrap_rejects_corrupt_cache_and_download(tmp: string)
  local digest = string.rep("0", 64)
  local root, cache = bootstrap_root(tmp, string.rep("b", 40), digest)
  local cached = cache .. "/cosmic-" .. digest
  assert(Fs.write(cached, "bad cache", 0x1ed))
  assert(Fs.write(tmp .. "/download", "bad download"))
  -- One attempt: a retry would only pause and fetch the same bad bytes.
  local result = bootstrap(tmp, root, tmp .. "/bad.out",
    { PATH = fake_curl(tmp), DOWNLOAD_SOURCE = tmp .. "/download",
      COSMIC_BOOTSTRAP_ATTEMPTS = "1" })
  assert(not result.ok and Fs.exists(cached) == false,
    "corrupt replacement was accepted")
end

--- A download that fails partway is tried again from an empty file, and
--- the second, whole one is verified and kept; nothing partial is left.
local function test_bootstrap_retries_a_failed_download(tmp: string)
  local program = assert(Proc.executable())
  local digest = Hash.hex_sha256((assert(Fs.read(program))))
  local root, cache = bootstrap_root(tmp, string.rep("e", 40), digest)
  assert(Fs.write(tmp .. "/fail-once", ""))
  local result = bootstrap(tmp, root, tmp .. "/retry.out",
    { PATH = fake_curl(tmp), DOWNLOAD_SOURCE = program, FAIL_ONCE = tmp .. "/fail-once",
      CALLS = tmp .. "/calls", COSMIC_BOOTSTRAP_ATTEMPTS = "2" })
  local out = assert(Fs.read(tmp .. "/retry.out"))
  assert(result.ok, out)
  assert(out:find("retrying", 1, true) ~= nil, out)
  assert(assert(Fs.read(tmp .. "/calls")) == "call\ncall\n")
  assert(Hash.hex_sha256((assert(Fs.read(cache .. "/cosmic-" .. digest)))) == digest)
  local names = assert(Fs.list(cache))
  assert(#names == 1, "a partial download was left: " .. table.concat(names, " "))
end

--- Every attempt failing fails the script, saying how many it made.
local function test_bootstrap_gives_up_after_its_attempts(tmp: string)
  local digest = string.rep("0", 64)
  local root, cache = bootstrap_root(tmp, string.rep("f", 40), digest)
  assert(Fs.write(tmp .. "/fail-once", ""))
  local result = bootstrap(tmp, root, tmp .. "/gave-up.out",
    { PATH = fake_curl(tmp), DOWNLOAD_SOURCE = tmp .. "/missing",
      FAIL_ONCE = tmp .. "/fail-once", CALLS = tmp .. "/calls",
      COSMIC_BOOTSTRAP_ATTEMPTS = "2" })
  local out = assert(Fs.read(tmp .. "/gave-up.out"))
  assert(not result.ok, out)
  assert(out:find("after 2 attempts", 1, true) ~= nil, out)
  assert(assert(Fs.read(tmp .. "/calls")) == "call\ncall\n")
  assert(#assert(Fs.list(cache)) == 0, "a partial download was left")
end

local function test_bootstrap_replaces_a_corrupt_cache_from_a_verified_download(tmp: string)
  local program = assert(Proc.executable())
  local digest = Hash.hex_sha256((assert(Fs.read(program))))
  local root, cache = bootstrap_root(tmp, string.rep("d", 40), digest)
  local cached = cache .. "/cosmic-" .. digest
  assert(Fs.write(cached, "corrupt", 0x1ed))
  local result = bootstrap(tmp, root, tmp .. "/download.out",
    { PATH = fake_curl(tmp), DOWNLOAD_SOURCE = program })
  assert(result.ok, assert(Fs.read(tmp .. "/download.out")))
  assert(Hash.hex_sha256((assert(Fs.read(cached)))) == digest,
    "downloaded driver changed after verification")
end

--- A link at the cache's name is never followed: even one to the right
--- bytes is replaced by a verified download of its own.
local function test_bootstrap_replaces_a_linked_cache_entry(tmp: string)
  local program = assert(Proc.executable())
  local digest = Hash.hex_sha256((assert(Fs.read(program))))
  local root, cache = bootstrap_root(tmp, string.rep("c", 40), digest)
  local cached = cache .. "/cosmic-" .. digest
  assert(Fs.symlink(program, cached))
  local result = bootstrap(tmp, root, tmp .. "/linked.out",
    { PATH = fake_curl(tmp), DOWNLOAD_SOURCE = program })
  assert(result.ok, assert(Fs.read(tmp .. "/linked.out")))
  assert(Fs.readlink(cached) == nil, "a linked cache entry was kept")
  assert(Hash.hex_sha256((assert(Fs.read(cached)))) == digest)
end

local function test_driver_records_success_failures_timeout_and_interruption(tmp: string)
  local runner = seeded_bootstrap(tmp)
  local project = driver_project(tmp)
  local candidate = checkout_root()
  local driver = project .. "/cosmic_ci/driver.tl"
  -- RUNNER_TEMP always exists in CI; Context.read() resolves its scratch
  -- directory as an external path before creating anything under it, which
  -- requires RUNNER_TEMP itself to already be there.
  local runner_temp = tmp .. "/runner-temp"
  assert(Fs.mkdirs(runner_temp))
  local ctx_env = driver_context(candidate, runner_temp)
  local function run(phase: string, timeout: string, argv: {string}): Child.Result
    local command = { runner, driver, "run", phase, timeout }
    for _, value in ipairs(argv) do command[#command + 1] = value end
    return call(command, project, tmp .. "/" .. phase .. ".out", ctx_env,
      driver_timeout)
  end
  local spaced = tmp .. "/path with spaces"
  assert(run("success", "1000", { "/bin/sh", "-c",
    "test \"$PWD\" = \"$1\"; printf ok > \"$2\"", "sh",
    candidate, spaced }).ok)
  assert(assert(Fs.read(spaced)) == "ok", "success child lost cwd or spaced argv")
  assert(run("nonzero", "1000", { "/bin/sh", "-c", "exit 23" }).code == 23)
  assert(run("start-failure", "1000", { "/definitely/not/a/command" }).code == 1)
  assert(run("timeout", "20", { "/bin/sh", "-c", "sleep 30" }).code == 124)

  local ready = tmp .. "/ready"
  local command = { runner, driver, "run", "interrupted", "30000", "/bin/sh", "-c",
    "printf ready > \"$1\"; sleep 30", "sh", ready }
  local fd = assert(Fs.open_write(tmp .. "/interrupted.out"))
  local child = assert(Child.start(command, { cwd = project, env = environment(ctx_env),
    stdout = fd, stderr = fd, process_group = true, timeout_ms = 35000 }))
  for _ = 1, driver_timeout // 20 do
    if Predicate.exists(ready) then break end
    Time.sleep_ns(10 * 1000 * 1000)
  end
  assert(Predicate.exists(ready), "interrupted operation never started")
  assert(child:stop())
  local stopped = assert(child:wait(5000))
  assert(Fs.close(fd))
  assert(not stopped.ok, "interrupted driver succeeded")

  local summary = tmp .. "/summary.md"
  assert(call({ runner, driver, "summarize" }, project, tmp .. "/summarize.out",
    driver_context(candidate, runner_temp, { GITHUB_STEP_SUMMARY = summary }),
    driver_timeout).ok)
  local text = assert(Fs.read(summary))
  for _, row in ipairs({ "| worker | run-1 | 1 | success | success |",
      "| worker | run-1 | 1 | nonzero | exit |",
      "| worker | run-1 | 1 | start-failure | start-error |",
      "| worker | run-1 | 1 | timeout | timeout |",
      "| worker | run-1 | 1 | interrupted | incomplete |" }) do
    assert(text:find(row, 1, true), "summary omitted " .. row)
  end

  -- Inside the candidate, so the boundary check fires on the resolved
  -- target, but under its gitignored ci/o so a regression can only
  -- ever touch a throwaway file.
  local sentinel = candidate .. "/ci/o/sentinel.db"
  assert(Fs.mkdirs(candidate .. "/ci/o") and Fs.write(sentinel, "sentinel"))
  local before = Hash.hex_sha256((assert(Fs.read(sentinel))))
  local symlink_runner_temp = tmp .. "/symlink-runner-temp"
  assert(Fs.mkdirs(symlink_runner_temp .. "/cosmic-ci"))
  assert(call({ "/bin/ln", "-s", sentinel,
    symlink_runner_temp .. "/cosmic-ci/operations.db" }, tmp, tmp .. "/db-ln.out").ok)
  local linked = call({ runner, driver, "run", "symlink-db", "1000",
      "/bin/sh", "-c", "exit 0" }, project, tmp .. "/symlink-db.out",
    driver_context(candidate, symlink_runner_temp), driver_timeout)
  assert(not linked.ok, "symlink operation database was accepted")
  assert(Hash.hex_sha256((assert(Fs.read(sentinel)))) == before,
    "rejected symlink changed its target")
end

-- `summarize` runs `if: always()`, including after a failed checkout or a
-- failed self-check, so it must work from RUNNER_TEMP and
-- GITHUB_STEP_SUMMARY alone -- no GITHUB_WORKSPACE, COSMIC_WORKER, or any
-- of the rest of the full context `run`/`platform`/`provenance` need.
local function test_summarize_reports_unavailable_database(tmp: string)
  local runner = seeded_bootstrap(tmp)
  local project = driver_project(tmp)
  local driver = project .. "/cosmic_ci/driver.tl"
  local summary = tmp .. "/summary.md"
  local result = call({ runner, driver, "summarize" }, project,
    tmp .. "/summarize.out",
    { RUNNER_TEMP = tmp .. "/runner-temp", GITHUB_STEP_SUMMARY = summary },
    driver_timeout)
  assert(result.ok, "summarize failed for a missing operation database: " ..
    (Fs.read(tmp .. "/summarize.out") or "<no output>"))
  local text = assert(Fs.read(summary))
  assert(text:find("## Cosmic CI operations", 1, true) and
    text:find("unavailable", 1, true), "summary omitted the unavailable-database line")
end
