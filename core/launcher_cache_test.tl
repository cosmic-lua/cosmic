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
-- which the sandbox resolves, with what its loader reads).
Test.policy{ profiles = { "system", "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

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

--- Skips the test where this program has no artifact to relaunch, as a
--- native start has not.
local function relaunch_or_skip()
  if Proc.relaunch() == nil then
    Test.skip("a native start has no artifact to launch from a cache")
  end
end

--- A cache entry is hashed on its first launch, and stamped by the first
--- launch a second or more after it was written, so none after that
--- hashes it again. Whether the first launch itself stamps depends on
--- how long extracting and hashing took, so only the settled launch is
--- held to it.
local function test_a_fresh_cache_entry_is_stamped_once_it_settles(tmp: string)
  relaunch_or_skip()
  local program = assert(Proc.executable())
  local cache = tmp .. "/cache"
  assert(Fs.write(tmp .. "/ok.tl", "return function(): integer print('ok') return 0 end\n"))
  launch(program, cache, tmp)
  assert(Clock.sleep_ns(1100000000))
  launch(program, cache, tmp)
  assert(stamps(cache) == 1, "a settled entry is stamped")
end

--- Launches with a cache leaf of `mode` made first, answering the launch's
--- result and what it said. A launch that is refused exits 126.
local function launch_with_mode(program: string, tmp: string, name: string, mode: integer): Child.Result, string
  local cache = tmp .. "/" .. name
  assert(Fs.mkdirs(cache))
  assert(Fs.chmod(cache, mode))
  assert(Fs.write(tmp .. "/ok.tl", "return function(): integer print('ok') return 0 end\n"))
  local env: mut {string:string} = {}
  for key, value in pairs(environment()) do env[key] = value end
  env["COSMIC_PORTABLE_CACHE"] = cache
  local r = assert(Child.run({ program, "ok.tl" }, { env = env, cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  -- The test's directory is removed afterwards, by a user who cannot list
  -- a leaf its owner took every bit from.
  assert(Fs.chmod(cache, 0x1c0))
  return r, r.stderr or ""
end

--- A leaf only its owner can write is accepted whatever its group and
--- others can read: a group that cannot change the leaf cannot plant a
--- core in it, and every entry is checked as it is used.
local function test_a_leaf_its_group_can_read_is_accepted(tmp: string)
  relaunch_or_skip()
  local program = assert(Proc.executable())
  local r, err = launch_with_mode(program, tmp, "group-read", 0x1e8)
  assert(r.ok and r.stdout == "ok\n", err)
end

--- A leaf group or others can write is refused, naming the remedy.
local function test_a_leaf_group_or_others_can_write_is_refused(tmp: string)
  relaunch_or_skip()
  local program = assert(Proc.executable())
  local modes: {string:integer} = { ["0770"] = 0x1f8, ["0777"] = 0x1ff, ["0702"] = 0x1c2 }
  for name, mode in pairs(modes) do
    local r, err = launch_with_mode(program, tmp, "writable-" .. name, mode)
    assert(not r.ok and r.code == 126, name .. " was not refused: " .. err)
    assert(err:find("writable by group or others", 1, true) ~= nil and
        err:find("chmod go-w", 1, true) ~= nil,
      name .. " was refused without its remedy: " .. err)
  end
end

--- The owner's bits alone choose writable or read-only: 0500 still runs a
--- cache that holds its core, and an owner that cannot write and read is
--- refused.
local function test_a_leaf_is_judged_by_its_owner_bits(tmp: string)
  relaunch_or_skip()
  local program = assert(Proc.executable())
  local cache = tmp .. "/owner"
  assert(Fs.write(tmp .. "/ok.tl", "return function(): integer print('ok') return 0 end\n"))
  launch(program, cache, tmp)
  assert(Fs.chmod(cache, 0x140))
  launch(program, cache, tmp)
  assert(Fs.chmod(cache, 0x1c0))
  local r, err = launch_with_mode(program, tmp, "owner-none", 0x0)
  assert(not r.ok and r.code == 126 and err:find("owner needs mode 7 or 5", 1, true) ~= nil, err)
end

-- TODO: run the setgid cases here, and delete this skip, once a promise
-- lets a test that declares it set the special bits (core/promises.c's
-- `fattr` refuses them for good); ci/fixtures/launcher_test.tl holds them
-- meanwhile.

--- A leaf made under a setgid parent can carry the bit and a readable
--- group (2750), and is accepted; one a group can write (2770) is not.
local function test_a_setgid_leaf_is_judged_without_the_bit(tmp: string)
  relaunch_or_skip()
  local program = assert(Proc.executable())
  local probe = tmp .. "/probe"
  assert(Fs.mkdirs(probe))
  local set, why = Fs.chmod(probe, 0x5e8)
  if not set then
    assert(why:find("not permitted", 1, true) ~= nil, why)
    Test.skip("the worker's filter refuses a mode with a setgid bit: `fattr` never allows one")
    return
  end
  local r, err = launch_with_mode(program, tmp, "setgid-group-read", 0x5e8)
  assert(r.ok and r.stdout == "ok\n", err)
  local w, werr = launch_with_mode(program, tmp, "setgid-group-write", 0x5f8)
  assert(not w.ok and w.code == 126 and werr:find("writable by group or others", 1, true) ~= nil, werr)
end
