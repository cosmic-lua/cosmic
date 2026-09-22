local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")

local function environment(extra?: {string:string}): {string:string}
  local values = Env.all()
  if extra then for name, value in pairs(extra) do values[name] = value end end
  return values
end

local function call(argv: {string}, cwd: string, output: string,
    extra?: {string:string}, timeout?: integer): Child.Result
  local fd = assert(Fs.open_write(output))
  local result, trouble = Child.run(argv, {
    cwd = cwd, env = environment(extra), stdout = fd, stderr = fd,
    process_group = true, timeout_ms = timeout or 5000,
  })
  assert(Fs.close(fd))
  return assert(result, trouble)
end

--- The candidate checkout root: this test's cwd is `<checkout>/ci`, so
--- its parent is the checkout the self-check runs against.
local function checkout_root(): string
  local cwd = assert(Fs.absolute("."))
  return assert(cwd:match("^(.*)/[^/]+$"), cwd .. ": no parent directory")
end

local function pin(path: string, commit: string, digest: string)
  assert(Fs.write(path, commit .. "\n" ..
    "https://github.com/cosmic-lua/cosmic/releases/download/next-" ..
    commit .. "/cosmic\n" .. digest .. "\n"))
end

local function seeded_bootstrap(tmp: string): string, string
  local program = assert(Proc.executable())
  local digest = Hash.hex_sha256(assert(Fs.read(program)))
  local cache, runner = tmp .. "/cache", tmp .. "/runner"
  assert(Fs.mkdirs(cache))
  assert(Fs.write(cache .. "/cosmic-" .. digest, assert(Fs.read(program))))
  local pin_path = tmp .. "/local.pin"
  pin(pin_path, string.rep("a", 40), digest)
  local result = call({ "/bin/sh", checkout_root() .. "/ci/bootstrap-driver.sh",
      pin_path, cache, runner }, tmp, tmp .. "/bootstrap.out")
  assert(result.ok, assert(Fs.read(tmp .. "/bootstrap.out")))
  return runner, digest
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
  local cache, fake = tmp .. "/cache", tmp .. "/fake bin"
  assert(Fs.mkdirs(cache) and Fs.mkdirs(fake))
  local commit, digest = string.rep("b", 40), string.rep("0", 64)
  local pin_path = tmp .. "/bad.pin"
  pin(pin_path, commit, digest)
  assert(Fs.write(cache .. "/cosmic-" .. digest, "bad cache"))
  assert(Fs.write(tmp .. "/download", "bad download"))
  assert(Fs.write(fake .. "/curl", [[#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then output=$2; shift 2; else shift; fi
done
cp "$DOWNLOAD_SOURCE" "$output"
]]))
  assert(call({ "/bin/chmod", "755", fake .. "/curl" }, tmp,
    tmp .. "/chmod.out").ok)
  local result = call({ "/bin/sh", checkout_root() .. "/ci/bootstrap-driver.sh",
      pin_path, cache, tmp .. "/runner" }, tmp,
    tmp .. "/bad.out", { PATH = fake .. ":" .. assert(Env.get("PATH")),
      DOWNLOAD_SOURCE = tmp .. "/download" })
  assert(not result.ok and not Fs.exists(tmp .. "/runner"),
    "corrupt replacement was accepted")
end

local function test_bootstrap_replaces_a_corrupt_cache_from_a_verified_download(tmp: string)
  local program = assert(Proc.executable())
  local digest = Hash.hex_sha256(assert(Fs.read(program)))
  local cache, fake = tmp .. "/cache", tmp .. "/fake bin"
  assert(Fs.mkdirs(cache) and Fs.mkdirs(fake))
  assert(Fs.write(cache .. "/cosmic-" .. digest, "corrupt"))
  assert(Fs.write(fake .. "/curl", [[#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then output=$2; shift 2; else shift; fi
done
cp "$DOWNLOAD_SOURCE" "$output"
]]))
  assert(call({ "/bin/chmod", "755", fake .. "/curl" }, tmp,
    tmp .. "/chmod.out").ok)
  local pin_path = tmp .. "/download.pin"
  pin(pin_path, string.rep("d", 40), digest)
  local result = call({ "/bin/sh", checkout_root() .. "/ci/bootstrap-driver.sh",
      pin_path, cache, tmp .. "/runner" }, tmp,
    tmp .. "/download.out", { PATH = fake .. ":" .. assert(Env.get("PATH")),
      DOWNLOAD_SOURCE = program })
  assert(result.ok, assert(Fs.read(tmp .. "/download.out")))
  assert(Hash.hex_sha256(assert(Fs.read(tmp .. "/runner"))) == digest,
    "downloaded runner changed after verification")
end

local function test_bootstrap_rejects_hostile_destinations(tmp: string)
  local program = assert(Proc.executable())
  local digest = Hash.hex_sha256(assert(Fs.read(program)))
  local cache = tmp .. "/cache"
  assert(Fs.mkdirs(cache))
  assert(Fs.write(cache .. "/cosmic-" .. digest, assert(Fs.read(program))))
  local pin_path = tmp .. "/local.pin"
  pin(pin_path, string.rep("c", 40), digest)
  local script = checkout_root() .. "/ci/bootstrap-driver.sh"

  assert(Fs.write(tmp .. "/existing-runner", "already here"))
  local existing = call({ "/bin/sh", script, pin_path, cache,
      tmp .. "/existing-runner" }, tmp, tmp .. "/existing.out")
  assert(not existing.ok, "existing runner was accepted")

  assert(call({ "/bin/ln", "-s", tmp .. "/target", tmp .. "/runner-link" },
    tmp, tmp .. "/ln.out").ok)
  local linked = call({ "/bin/sh", script, pin_path, cache, tmp .. "/runner-link" },
    tmp, tmp .. "/linked.out")
  assert(not linked.ok, "symlink runner was accepted")
end

local function test_driver_records_success_failures_timeout_and_interruption(tmp: string)
  local runner = seeded_bootstrap(tmp)
  local project = driver_project(tmp)
  local candidate = checkout_root()
  local driver, db = project .. "/cosmic_ci/driver.tl", tmp .. "/operations.db"
  local function run(phase: string, timeout: string, argv: {string}): Child.Result
    local command = { runner, driver, "run", db, "worker", "run-1", "1",
      phase, candidate, timeout }
    for _, value in ipairs(argv) do command[#command + 1] = value end
    return call(command, project, tmp .. "/" .. phase .. ".out", nil, 5000)
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
  local command = { runner, driver, "run", db, "worker", "run-1", "1",
    "interrupted", candidate, "30000", "/bin/sh", "-c",
    "printf ready > \"$1\"; sleep 30", "sh", ready }
  local fd = assert(Fs.open_write(tmp .. "/interrupted.out"))
  local child = assert(Child.start(command, { cwd = project, env = environment(),
    stdout = fd, stderr = fd, process_group = true, timeout_ms = 35000 }))
  for _ = 1, 200 do
    if Fs.exists(ready) then break end
    Time.sleep_ns(10 * 1000 * 1000)
  end
  assert(Fs.exists(ready), "interrupted operation never started")
  assert(child:stop())
  local stopped = assert(child:wait(5000))
  assert(Fs.close(fd))
  assert(not stopped.ok, "interrupted driver succeeded")

  local report = tmp .. "/report.md"
  assert(call({ runner, driver, "report", db, report }, project,
    tmp .. "/report.out").ok)
  local text = assert(Fs.read(report))
  for _, row in ipairs({ "| worker | run-1 | 1 | success | success |",
      "| worker | run-1 | 1 | nonzero | exit |",
      "| worker | run-1 | 1 | start-failure | start-error |",
      "| worker | run-1 | 1 | timeout | timeout |",
      "| worker | run-1 | 1 | interrupted | incomplete |" }) do
    assert(text:find(row, 1, true), "report omitted " .. row)
  end

  local sentinel, link = project .. "/sentinel.db", tmp .. "/database-link"
  assert(Fs.write(sentinel, assert(Fs.read(db))))
  local before = Hash.hex_sha256(assert(Fs.read(sentinel)))
  assert(call({ "/bin/ln", "-s", sentinel, link }, tmp, tmp .. "/db-ln.out").ok)
  local linked = call({ runner, driver, "run", link, "worker", "run-1", "1",
      "symlink-db", candidate, "1000", "/bin/sh", "-c", "exit 0" }, project,
    tmp .. "/symlink-db.out")
  assert(not linked.ok, "symlink operation database was accepted")
  assert(Hash.hex_sha256(assert(Fs.read(sentinel))) == before,
    "rejected symlink changed its target")
end
