--- The portable launcher's core cache: a cache entry the core hashed is
--- stamped so later launches need not hash it again. A test runs its own
--- launches, through the launcher, in processes of its own; a host
--- program has no launcher, so there is nothing here for it to check.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

--- The program itself, which its tests start through its launcher, and
--- the system's programs the launcher runs: `sh`, and the `uname`,
--- `id`, `stat`, `mkdir`, `mktemp`, `dd`, `head`, `wc`, `sha256sum` (or
--- `shasum`), `chmod`, `ln` and `rm` it calls (build/launcher.tl). A
--- portable artifact is a `#!/bin/sh` script by design
--- (build/artifact_test.tl), and what is checked here is what that
--- script does, so no start past it will do: this module needs the
--- system for good.
-- TODO: name those programs rather than the whole of the system's
-- paths, once a declaration can name a program (`processes` by name,
-- which the sandbox resolves, with what its loader reads), as
-- build/todos_git_test.tl's git waits to be named.
Test.needs{ tool = true, system = true }

local function environment(): {string:string}
  local env = this_program.environment()
  env.COSMIC_PORTABLE_STARTUP_TEST_READY = nil
  env.COSMIC_PORTABLE_STARTUP_TEST_GO = nil
  return env
end

--- Launches this artifact with `cache` as its cache leaf.
local function launch(program: string, cache: string, dir: string)
  local env = environment()
  env.COSMIC_PORTABLE_CACHE = cache
  local r = assert(Child.run({ program, "ok.tl" }, { env = env, cwd = dir,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
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
  assert(Clock.sleep_ns(1100000000))
  launch(program, cache, tmp)
  assert(stamps(cache) == 1, "a settled entry is stamped")
end
