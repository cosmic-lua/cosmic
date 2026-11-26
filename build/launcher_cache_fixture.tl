--- What the tests of the portable launcher's core cache share
--- (core/launcher_cache_test.tl, core/launcher_cache_warm_test.tl): the
--- launches they make through the launcher and what they read of the
--- cache leaf. Test support.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")

local record launcher_cache_fixture
end

--- This program's environment, without the startup tests' handshake.
function launcher_cache_fixture.environment(): mut {string:string}
  local env = Test.environment()
  env["COSMIC_PORTABLE_STARTUP_TEST_READY"] = nil
  env["COSMIC_PORTABLE_STARTUP_TEST_GO"] = nil
  return env
end

--- Names `cache` to a launch in `env`: a leaf that ends in /.cache/cosmic/cores as the default one under HOME, the
--- only leaf a warm start takes (build/launcher.tl), and any other by COSMIC_PORTABLE_CACHE.
function launcher_cache_fixture.name_leaf(env: mut {string:string}, cache: string)
  local home = cache:match("^(.*)/%.cache/cosmic/cores$")
  if home ~= nil then
    env["HOME"] = home
    env["COSMIC_PORTABLE_CACHE"] = nil
    env["XDG_CACHE_HOME"] = nil
  else
    env["COSMIC_PORTABLE_CACHE"] = cache
  end
end

--- Launches this artifact with `cache` as its cache leaf.
function launcher_cache_fixture.launch(program: string, cache: string, dir: string)
  local env = launcher_cache_fixture.environment()
  launcher_cache_fixture.name_leaf(env, cache)
  local r = assert(Child.run({ program, "ok.tl" }, { env = env, cwd = dir,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(r.ok and r.stdout == "ok\n", tostring(r.stderr))
end

--- How many entries of `cache` are stamped.
function launcher_cache_fixture.stamps(cache: string): integer
  local count = 0
  for _, name in ipairs((assert(Fs.list(cache)))) do
    if name:sub(1, 10) == ".verified-" then count = count + 1 end
  end
  return count
end

--- Skips the test where this program has no artifact to relaunch, as a
--- native start has not.
function launcher_cache_fixture.relaunch_or_skip()
  local relaunched, _ = Proc.relaunch()
  if relaunched == nil then
    Test.skip("a native start has no artifact to launch from a cache")
  end
end

--- The entry of `cache`: its one core.
function launcher_cache_fixture.entry_of(cache: string): string
  for _, name in ipairs((assert(Fs.list(cache)))) do
    if name:sub(1, 5) == "core-" then return cache .. "/" .. name end
  end
  error("the cache holds no core")
end

return launcher_cache_fixture
