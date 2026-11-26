--- The portable launcher's core cache: a cache entry the core hashed is
--- stamped so later launches need not hash it again. A test runs its own
--- launches, through the launcher, in processes of its own; a host
--- program has no launcher, so there is nothing here for it to check.
--- The warm start of a stamped entry is core/launcher_cache_warm_test.tl's.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local launcher_cache_fixture = require("build.launcher_cache_fixture")
local sys = require("cosmic.sys")

--- The program itself, which its tests start through its launcher, and
--- the host's programs the launcher runs: `sh`, and the `uname`, `id`,
--- `stat`, `mkdir`, `mktemp`, `dd`, `head`, `sha256sum`, `chmod`,
--- `ln`, `rm` and `rmdir` it calls, and the kernel's names of the OS and
--- machine it reads in uname's place (build/launcher.tl;
--- build/launcher_test.tl holds what this module grants to what the
--- launcher's text runs), each granted
--- where a host has it, under /bin or /usr/bin: a grant of a path a host
--- lacks gives nothing. The `shasum` it falls back to is macOS's, where no
--- worker is sandboxed. A portable artifact is a `#!/bin/sh` script by
--- design (build/artifact_test.tl), and what is checked here is what
--- that script does, so no start past it will do.
Test.policy{ profiles = { "cosmic" }, grants = {
  { path = "/bin/sh", letters = "r" }, { path = "/usr/bin/sh", letters = "r" },
  { path = "/bin/uname", letters = "r" }, { path = "/usr/bin/uname", letters = "r" },
  { path = "/bin/mkdir", letters = "r" }, { path = "/usr/bin/mkdir", letters = "r" },
  { path = "/bin/stat", letters = "r" }, { path = "/usr/bin/stat", letters = "r" },
  { path = "/bin/mktemp", letters = "r" }, { path = "/usr/bin/mktemp", letters = "r" },
  { path = "/bin/head", letters = "r" }, { path = "/usr/bin/head", letters = "r" },
  { path = "/bin/rm", letters = "r" }, { path = "/usr/bin/rm", letters = "r" },
  { path = "/bin/dd", letters = "r" }, { path = "/usr/bin/dd", letters = "r" },
  { path = "/bin/chmod", letters = "r" }, { path = "/usr/bin/chmod", letters = "r" },
  { path = "/bin/id", letters = "r" }, { path = "/usr/bin/id", letters = "r" },
  { path = "/bin/ln", letters = "r" }, { path = "/usr/bin/ln", letters = "r" },
  { path = "/bin/rmdir", letters = "r" }, { path = "/usr/bin/rmdir", letters = "r" },
  { path = "/bin/sha256sum", letters = "r" }, { path = "/usr/bin/sha256sum", letters = "r" },
  { path = "/proc/sys/kernel/ostype", letters = "r" }, { path = "/proc/sys/kernel/arch", letters = "r" },
  { path = "o/bin", letters = "rx" } } }

local environment = launcher_cache_fixture.environment
local name_leaf = launcher_cache_fixture.name_leaf
local launch = launcher_cache_fixture.launch
local stamps = launcher_cache_fixture.stamps
local relaunch_or_skip = launcher_cache_fixture.relaunch_or_skip
local entry_of = launcher_cache_fixture.entry_of

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
  assert(Clock.sleep(1100000000))
  launch(program, cache, tmp)
  assert(stamps(cache) == 1, "a settled entry is stamped")
end

--- Launches with a cache leaf of `mode` made first, returning the launch's
--- result and what it said. A launch that is refused exits 126.
local function launch_with_mode(program: string, tmp: string, name: string, mode: integer): Child.Result, string
  local cache = tmp .. "/" .. name
  assert(Fs.mkdirs(cache))
  assert(Fs.chmod(cache, mode))
  assert(Fs.write(tmp .. "/ok.tl", "return function(): integer print('ok') return 0 end\n"))
  local env: mut {string:string} = {}
  for key, value in pairs(environment()) do env[key] = value end
  name_leaf(env, cache)
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
    assert(why.errno == sys.EPERM, tostring(why))
    Test.skip("the worker's filter refuses a mode with a setgid bit: `fattr` never allows one")
    return
  end
  local r, err = launch_with_mode(program, tmp, "setgid-group-read", 0x5e8)
  assert(r.ok and r.stdout == "ok\n", err)
  local w, werr = launch_with_mode(program, tmp, "setgid-group-write", 0x5f8)
  assert(not w.ok and w.code == 126 and werr:find("writable by group or others", 1, true) ~= nil, werr)
end

--- Startup checks an entry's mode itself, so a start with no launcher before it, as [`Proc.relaunch`] starts one,
--- refuses and removes an entry that is not mode 0500, on every host. The entry here is 0555, the mode of root's
--- shared copies, in a leaf that is not root's, so startup's check for root's copies (`roots_entry`, core/startup.c)
--- runs and says no. This is the one test that enters that check off Linux, where the stamped tests are n/a. The next
--- launch extracts it again.
local function test_a_direct_start_of_an_entry_of_another_mode_removes_it(tmp: string)
  relaunch_or_skip()
  local program = assert(Proc.executable())
  local cache = tmp .. "/cache"
  assert(Fs.write(tmp .. "/ok.tl", "return function(): integer print('ok') return 0 end\n"))
  launch(program, cache, tmp)
  if assert(assert(Fs.status(entry_of(cache))).stat).uid == 0 then
    Test.skip("startup takes a 0555 entry of root's")
  end
  assert(Fs.write(tmp .. "/again.tl", [[
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
return function(): integer
  local again = assert(Proc.relaunch())
  assert(Fs.chmod(assert(again.argv[1]), 0x16d))
  local argv: mut {string} = {}
  for _, word in ipairs(again.argv) do argv[#argv + 1] = word end
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = "print('ran')"
  local r = assert(Child.run(argv, { env = again.env, fds = again.fds, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(30) }))
  local _, _ = Fs.put(Fs.stdout, tostring(r.code) .. "\n" .. (r.stdout or "") .. (r.stderr or ""))
  return 0
end
]]))
  local env = environment()
  name_leaf(env, cache)
  local r = assert(Child.run({ program, "again.tl" }, { env = env, cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  local out = r.stdout or ""
  assert(r.ok and out:find("is not mode 0500 (mode 555); removed it", 1, true) ~= nil and
      out:sub(1, 2) ~= "0\n" and out:find("\nran\n", 1, true) == nil, out .. tostring(r.stderr))
  for _, name in ipairs((assert(Fs.list(cache)))) do
    assert(name:sub(1, 5) ~= "core-", "the refused entry is left: " .. name)
  end
  launch(program, cache, tmp)
end
