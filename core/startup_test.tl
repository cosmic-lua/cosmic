--- core/startup.c's adoption of a portable launch: the core the
--- launcher executes checks what it was handed before any Lua runs, and
--- a cache entry it hashed is stamped so later launches need not hash it
--- again. A test runs its own launches, in processes of its own; a host
--- program has no launcher, so there is nothing here for it to check.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")
local observations = require("build.filesystem_observations")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

local function environment(): {string:string}
  local env = Env.all()
  env.COSMIC_PORTABLE_STARTUP_TEST_READY = nil
  env.COSMIC_PORTABLE_STARTUP_TEST_GO = nil
  return env
end

--- The core refuses an artifact it cannot name absolutely, before it
--- reads anything from it, and says why.
local function test_a_relative_artifact_path_is_refused()
  local relaunch = Proc.relaunch()
  if relaunch == nil or #relaunch.argv < 3 then return end
  local argv = { relaunch.argv[1], relaunch.argv[2], "relative/artifact" }
  local env = environment()
  for name, value in pairs(relaunch.env) do env[name] = value end
  local r = assert(Child.run(argv, { env = env, fds = relaunch.fds,
    stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
  assert(r.code == 2, "exit " .. tostring(r.code))
  assert((assert(r.stderr)):find("cosmic: portable artifact path is not absolute",
    1, true), tostring(r.stderr))
end

--- Launches this artifact with `cache` as its cache leaf.
local function launch(program: string, cache: string, dir: string)
  local env = environment()
  env.COSMIC_PORTABLE_CACHE = cache
  local r = assert(Child.run({ program, "ok.tl" }, { env = env, cwd = dir,
    stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
  assert(r.ok and r.stdout == "ok\n", tostring(r.stderr))
end

local function stamps(cache: string): integer
  local count = 0
  for _, name in ipairs((assert(Fs.list(cache)))) do
    if name:sub(1, 10) == ".verified-" then count = count + 1 end
  end
  return count
end

--- A cache entry is hashed on its first launch, and stamped by the first
--- launch a second or more after it was written, so none after that
--- hashes it again. Whether the first launch itself stamps depends on
--- how long extracting and hashing took, so only the settled launch is
--- held to it.
local function test_a_fresh_cache_entry_is_stamped_once_it_settles(tmp: string)
  if Proc.relaunch() == nil then return end
  local program = assert(Proc.executable())
  local cache = tmp .. "/cache"
  assert(Fs.write(tmp .. "/ok.tl", "return function(): integer print('ok') return 0 end\n"))
  launch(program, cache, tmp)
  assert(Time.sleep_ns(1100000000))
  launch(program, cache, tmp)
  assert(stamps(cache) == 1, "a settled entry is stamped")
end
