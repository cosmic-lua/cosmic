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

local function source_root(): string
  local root = Env.get("COSMIC_CI_SOURCE_ROOT")
  assert(root and root ~= "", "COSMIC_CI_SOURCE_ROOT is required")
  return root
end

local function pin(path: string, commit: string, digest: string)
  assert(Fs.write(path, commit .. "\n" ..
    "https://github.com/cosmic-lua/cosmic/releases/download/next-" ..
    commit .. "/cosmic\n" .. digest .. "\n"))
end

local function seeded_bootstrap(tmp: string): string, string, string
  local program = assert(Proc.executable())
  local digest = Hash.hex_sha256(assert(Fs.read(program)))
  local cache, project, runner = tmp .. "/cache", tmp .. "/project", tmp .. "/runner"
  assert(Fs.mkdirs(cache))
  assert(Fs.write(cache .. "/cosmic-" .. digest, assert(Fs.read(program))))
  local pin_path = tmp .. "/local.pin"
  pin(pin_path, string.rep("a", 40), digest)
  local result = call({ "/bin/sh", source_root() .. "/test/ci/bootstrap-driver.sh",
      pin_path, source_root(), cache, project, runner }, tmp, tmp .. "/bootstrap.out")
  assert(result.ok, assert(Fs.read(tmp .. "/bootstrap.out")))
  return project, runner, digest
end

local function test_bootstrap_verifies_and_copies_declared_trees_verbatim(tmp: string)
  local project, runner, digest = seeded_bootstrap(tmp)
  assert(Hash.hex_sha256(assert(Fs.read(runner))) == digest)
  for _, relative in ipairs({ "cosmic_ci/driver.tl",
      "cosmic_ci/bootstrap_test.tl", "testdata/not_a_test_test.tl" }) do
    local source = source_root() .. "/test/ci/driver/" .. relative
    assert(assert(Fs.read(project .. "/" .. relative)) == assert(Fs.read(source)),
      relative .. " changed while copied")
  end
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
  local result = call({ "/bin/sh", source_root() .. "/test/ci/bootstrap-driver.sh",
      pin_path, source_root(), cache, tmp .. "/project", tmp .. "/runner" }, tmp,
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
  local result = call({ "/bin/sh", source_root() .. "/test/ci/bootstrap-driver.sh",
      pin_path, source_root(), cache, tmp .. "/project", tmp .. "/runner" }, tmp,
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
  local script = source_root() .. "/test/ci/bootstrap-driver.sh"
  assert(Fs.mkdirs(tmp .. "/occupied/cosmic_ci"))
  local occupied = call({ "/bin/sh", script, pin_path, source_root(), cache,
      tmp .. "/occupied", tmp .. "/runner-one" }, tmp, tmp .. "/occupied.out")
  assert(not occupied.ok, "pre-existing namespace was accepted")
  assert(call({ "/bin/ln", "-s", tmp .. "/target", tmp .. "/runner-link" },
    tmp, tmp .. "/ln.out").ok)
  local linked = call({ "/bin/sh", script, pin_path, source_root(), cache,
      tmp .. "/project", tmp .. "/runner-link" }, tmp, tmp .. "/linked.out")
  assert(not linked.ok, "symlink runner was accepted")
  local contained = call({ "/bin/sh", script, pin_path, source_root(),
      source_root() .. "/o/hostile-cache", tmp .. "/other-project",
      tmp .. "/other-runner" }, tmp, tmp .. "/contained.out")
  assert(not contained.ok, "candidate-contained cache was accepted")
  local contained_project = call({ "/bin/sh", script, pin_path, source_root(), cache,
      source_root() .. "/o/hostile-project", tmp .. "/other-runner-two" },
    tmp, tmp .. "/contained-project.out")
  assert(not contained_project.ok, "candidate-contained project was accepted")
  local contained_runner = call({ "/bin/sh", script, pin_path, source_root(), cache,
      tmp .. "/other-project-two", source_root() .. "/o/hostile-runner" },
    tmp, tmp .. "/contained-runner.out")
  assert(not contained_runner.ok, "candidate-contained runner was accepted")
end

local function test_interrupted_source_copy_leaves_no_destination_tree(tmp: string)
  local program = assert(Proc.executable())
  local digest = Hash.hex_sha256(assert(Fs.read(program)))
  local cache, fake = tmp .. "/cache", tmp .. "/fake bin"
  assert(Fs.mkdirs(cache) and Fs.mkdirs(fake))
  assert(Fs.write(cache .. "/cosmic-" .. digest, assert(Fs.read(program))))
  local pin_path = tmp .. "/local.pin"
  pin(pin_path, string.rep("e", 40), digest)
  assert(Fs.write(fake .. "/cp", [[#!/bin/sh
if [ "${1-}" != -R ]; then exec /bin/cp "$@"; fi
destination=
for argument in "$@"; do destination=$argument; done
mkdir -p "$destination/cosmic_ci"
printf partial > "$destination/cosmic_ci/partial"
kill -TERM "$PPID"
sleep 1
exit 1
]]))
  assert(call({ "/bin/chmod", "755", fake .. "/cp" }, tmp,
    tmp .. "/chmod.out").ok)
  local project = tmp .. "/project"
  local result = call({ "/bin/sh", source_root() .. "/test/ci/bootstrap-driver.sh",
      pin_path, source_root(), cache, project, tmp .. "/runner" }, tmp, tmp .. "/copy.out",
    { PATH = fake .. ":" .. assert(Env.get("PATH")) })
  assert(not result.ok, "interrupted source copy succeeded")
  assert(not Fs.exists(project .. "/cosmic_ci") and
    not Fs.exists(project .. "/testdata"),
    "interrupted source copy left a destination tree")
end

local function test_check_entry_rejects_a_prestaged_project(tmp: string)
  local program = assert(Proc.executable())
  local digest = Hash.hex_sha256(assert(Fs.read(program)))
  local cache, project = tmp .. "/cache", tmp .. "/project"
  assert(Fs.mkdirs(cache) and Fs.mkdirs(project .. "/o"))
  assert(Fs.write(cache .. "/cosmic-" .. digest, assert(Fs.read(program))))
  local pin_path = tmp .. "/local.pin"
  pin(pin_path, string.rep("f", 40), digest)
  local sentinel = project .. "/o/build.db"
  assert(Fs.write(sentinel, "prior verdict database"))
  local result = call({ "/bin/sh", source_root() .. "/test/ci/check-driver.sh",
      pin_path, source_root(), cache, project, tmp .. "/runner", source_root() }, tmp,
    tmp .. "/check.out")
  assert(not result.ok, "check entry accepted a pre-staged project")
  assert(assert(Fs.read(sentinel)) == "prior verdict database",
    "rejected project was changed")
end

local function test_driver_records_success_failures_timeout_and_interruption(tmp: string)
  local project, runner = seeded_bootstrap(tmp)
  local driver, db = project .. "/cosmic_ci/driver.tl", tmp .. "/operations.db"
  local function run(phase: string, timeout: string, argv: {string}): Child.Result
    local command = { runner, driver, "run", db, "worker", "run-1", "1",
      phase, source_root(), timeout }
    for _, value in ipairs(argv) do command[#command + 1] = value end
    return call(command, project, tmp .. "/" .. phase .. ".out", nil, 5000)
  end
  local spaced = tmp .. "/path with spaces"
  assert(run("success", "1000", { "/bin/sh", "-c",
    "test \"$PWD\" = \"$1\"; printf ok > \"$2\"", "sh",
    source_root(), spaced }).ok)
  assert(assert(Fs.read(spaced)) == "ok", "success child lost cwd or spaced argv")
  assert(run("nonzero", "1000", { "/bin/sh", "-c", "exit 23" }).code == 23)
  assert(run("start-failure", "1000", { "/definitely/not/a/command" }).code == 1)
  assert(run("timeout", "20", { "/bin/sh", "-c", "sleep 30" }).code == 124)

  local ready = tmp .. "/ready"
  local command = { runner, driver, "run", db, "worker", "run-1", "1",
    "interrupted", source_root(), "30000", "/bin/sh", "-c",
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
      "symlink-db", source_root(), "1000", "/bin/true" }, project,
    tmp .. "/symlink-db.out")
  assert(not linked.ok, "symlink operation database was accepted")
  assert(Hash.hex_sha256(assert(Fs.read(sentinel))) == before,
    "rejected symlink changed its target")
end
