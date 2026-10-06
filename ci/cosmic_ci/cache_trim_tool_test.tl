local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

-- These tests start this program, which a worker on a sealed database does
-- not have whole.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- Exercise redelivery in a separate driver: its default SIGTERM action
--- must happen after the owned snapshot and sidecars have been removed.
local function test_cancellation_cleans_snapshot_before_driver_redelivery(tmp: string)
  local project = tmp .. "/project"
  assert(Fs.mkdirs(project))
  local here = assert(Fs.absolute("."))
  assert(assert(Child.run({ "/bin/cp", "-R", here .. "/cosmic_ci", project })).ok)
  local restored, ready, output = tmp .. "/restored.db", tmp .. "/ready", tmp .. "/output"
  for _, suffix in ipairs({ "", "-wal", "-shm" }) do
    assert(Fs.write(restored .. suffix, "owned"))
  end
  local script = ([=[
local Child = require("cosmic.child")
local Compiles = require("cosmic_ci.compiles")
local actual = Child.run
Child.run = function(_argv: {string}, options?: Child.Options): Child.Result | nil, string
  return actual({ "/bin/sh", "-c", %q }, options)
end
Compiles.command({ "1", %q }, { COSMIC_BUILD_CACHE = %q, GITHUB_OUTPUT = %q })
error("the original signal was swallowed")
]=]):format("echo ready > '" .. ready .. "'; sleep 30", restored, tmp .. "/cache.db", output)
  assert(Fs.write(project .. "/cancel.tl", script))
  local handle <close> = assert(Child.start({ assert(Proc.executable()), project .. "/cancel.tl" },
    { cwd = project, env = Env.all(), stdout = "capture", stderr = "capture" }))
  local deadline = Clock.monotonic_ns() + Clock.seconds(30)
  while Fs.read(ready) == nil and Clock.monotonic_ns() < deadline do
    Clock.sleep_ns(Clock.ms(10))
  end
  assert(Fs.read(ready) ~= nil, "maintenance child did not enter its guarded wait")
  assert(handle:stop(sys.SIGTERM))
  local result = assert(handle:wait(Clock.seconds(10)))
  assert(result.signal == sys.SIGTERM, (result.stderr or "") .. tostring(result.code))
  for _, suffix in ipairs({ "", "-wal", "-shm" }) do
    assert(Fs.stat(restored .. suffix) == nil, "snapshot remained at signal redelivery")
  end
  assert(Fs.stat(output) == nil, "cancelled maintenance published a save key")
end

local function test_wrapper_maintenance_does_not_build_a_broken_candidate(tmp: string)
  local project, candidate = tmp .. "/driver", tmp .. "/broken-candidate"
  assert(Fs.mkdirs(project) and Fs.mkdirs(candidate .. "/build"))
  local here = assert(Fs.absolute("."))
  assert(assert(Child.run({ "/bin/cp", "-R", here .. "/cosmic_ci", project })).ok)
  assert(Fs.write(candidate .. "/cosmic.tl", "invalid candidate source"))
  assert(Fs.write(candidate .. "/build/boot.tl", "invalid bootstrap source"))
  local script = ([=[
local Compiles = require("cosmic_ci.compiles")
local Env = require("cosmic.env")
local sys = require("cosmic.sys")
assert(sys.chdir(%q))
local original = Env.all
Env.all = function(): {string:string}
  local env = original()
  env.COSMIC_TREE = %q
  return env
end
for _ = 1, 2 do
  local code, _, err = Compiles.command({ "1" }, { COSMIC_BUILD_CACHE = %q })
  assert(code == 0 and err == "", err)
end
]=]):format(candidate, candidate .. "/does-not-exist", candidate .. "/missing/cache.db")
  assert(Fs.write(project .. "/check.tl", script))
  local result = assert(Child.run({ assert(Proc.executable()), project .. "/check.tl" },
    { cwd = project, env = Env.all(), stdout = "capture", stderr = "capture" }))
  assert(result.ok, (result.stdout or "") .. (result.stderr or ""))
  assert(Fs.stat(candidate .. "/o") == nil and Fs.stat(candidate .. "/missing") == nil)
end
