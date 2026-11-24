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

local function environment(): mut {string:string}
  local env = this_program.environment()
  env["COSMIC_PORTABLE_STARTUP_TEST_READY"] = nil
  env["COSMIC_PORTABLE_STARTUP_TEST_GO"] = nil
  return env
end

--- Names `cache` to a launch in `env`: a leaf that ends in /.cache/cosmic/cores as the default one under HOME, the
--- only leaf a warm start takes (build/launcher.tl), and any other by COSMIC_PORTABLE_CACHE.
local function name_leaf(env: mut {string:string}, cache: string)
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
local function launch(program: string, cache: string, dir: string)
  local env = environment()
  name_leaf(env, cache)
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
  local relaunched, _ = Proc.relaunch()
  if relaunched == nil then
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
  assert(Clock.sleep(1100000000))
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

--- Launches this artifact with `cache` as its cache leaf, `extra` added to its environment, and a PATH that finds
--- `uname` alone, so a launch that runs any other program (`stat`, `sha256sum`) fails. A warm start runs none: where
--- the kernel names the machine (outside a sandbox, whose /proc has no sys/), not even `uname`.
local function launch_bare(program: string, cache: string, dir: string, extra?: {string:string}): Child.Result
  local bare = dir .. "/only-uname"
  if not assert(Fs.status(bare)).exists then
    assert(Fs.mkdirs(bare))
    local uname = if assert(Fs.status("/bin/uname")).exists then "/bin/uname" else "/usr/bin/uname" end
    assert(Fs.symlink(uname, bare .. "/uname"))
  end
  local env = environment()
  name_leaf(env, cache)
  env["PATH"] = bare
  for name, value in pairs(extra or {}) do env[name] = value end
  return (assert(Child.run({ program, "ok.tl" }, { env = env, cwd = dir,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })))
end

--- The default cache leaf under HOME of a warm entry, stamped: skipped off Linux, whose launcher's cold path runs other programs.
-- TODO: hold macOS's warm start (the entry run by name, the Library/Caches leaf, bash 3.2's test) to these tests once
-- a macOS worker runs them: the stamp's launches and [`name_leaf`] know Linux's paths and tools alone.
local function stamped_cache(tmp: string): (string, string)
  relaunch_or_skip()
  local names = sys.uname()
  if names == nil or names.sysname ~= "Linux" then
    Test.skip("the stamp's launches use Linux's tools")
  end
  local program = assert(Proc.executable())
  local cache = tmp .. "/home/.cache/cosmic/cores"
  assert(Fs.write(tmp .. "/ok.tl", "return function(): integer print('ok') return 0 end\n"))
  launch(program, cache, tmp)
  assert(Clock.sleep(1100000000))
  launch(program, cache, tmp)
  assert(stamps(cache) == 1, "a settled entry is stamped")
  return program, cache
end

--- The entry of `cache`: its one core.
local function entry_of(cache: string): string
  for _, name in ipairs((assert(Fs.list(cache)))) do
    if name:sub(1, 5) == "core-" then return cache .. "/" .. name end
  end
  error("the cache holds no core")
end

--- A warm start of a stamped entry runs no program but the shell, and `uname` where the kernel does not name the
--- machine.
local function test_a_warm_start_runs_no_program(tmp: string)
  local program, cache = stamped_cache(tmp)
  local r = launch_bare(program, cache, tmp)
  assert(r.ok and r.stdout == "ok\n", tostring(r.stderr))
end

--- What a warm start's shell cannot see, startup checks: a sticky leaf group or others can write is refused with
--- its remedy, though the shell ran no `stat` to see it.
local function test_a_warm_start_refuses_a_leaf_others_can_write(tmp: string)
  local program, cache = stamped_cache(tmp)
  assert(Fs.chmod(cache, 0x3f8))
  local r = launch_bare(program, cache, tmp)
  assert(Fs.chmod(cache, 0x3c0))
  local err = r.stderr or ""
  assert(not r.ok and err:find("writable by group or others", 1, true) ~= nil and
      err:find("chmod go-w", 1, true) ~= nil, err)
end

--- A sticky leaf other than the default one under HOME takes the full path, which reads its mode, as no builtin
--- can see whether another user can write the leaf and add a hard link to a file this user owns.
local function test_a_named_leaf_never_starts_warm(tmp: string)
  local program, cache = stamped_cache(tmp)
  local home = assert(cache:match("^(.*)/%.cache/cosmic/cores$"))
  local spelled = launch_bare(program, cache, tmp, { XDG_CACHE_HOME = home .. "/.cache" })
  assert(spelled.ok and spelled.stdout == "ok\n", "XDG_CACHE_HOME=$HOME/.cache did not start warm: " ..
      tostring(spelled.stderr))
  assert(Fs.mkdirs(tmp .. "/xdg/cosmic"))
  assert(Fs.rename(cache, tmp .. "/xdg/cosmic/cores"))
  local other = launch_bare(program, cache, tmp, { XDG_CACHE_HOME = tmp .. "/xdg" })
  assert(not other.ok and (other.stderr or ""):find("cannot inspect cache leaf", 1, true) ~= nil,
    "a leaf XDG_CACHE_HOME names started warm: " .. tostring(other.stderr))
  local named = tmp .. "/named"
  assert(Fs.rename(tmp .. "/xdg/cosmic/cores", named))
  local r = launch_bare(program, named, tmp)
  assert(not r.ok and (r.stderr or ""):find("cannot inspect cache leaf", 1, true) ~= nil,
    "a named leaf started warm: " .. tostring(r.stderr))
end

--- The default leaf with no sticky bit takes the full path, which gives it the bit, so the next start is warm.
local function test_a_leaf_with_no_sticky_bit_is_given_one(tmp: string)
  local program, cache = stamped_cache(tmp)
  assert(Fs.chmod(cache, 0x1c0))
  local cold = launch_bare(program, cache, tmp)
  assert(not cold.ok and (cold.stderr or ""):find("cannot inspect cache leaf", 1, true) ~= nil,
    "a leaf with no sticky bit started warm: " .. tostring(cold.stderr))
  launch(program, cache, tmp)
  assert(assert(sys.stat(cache)).mode & 0xfff == 0x3c0, "the leaf was not given the sticky bit")
  local warm = launch_bare(program, cache, tmp)
  assert(warm.ok and warm.stdout == "ok\n", tostring(warm.stderr))
end

--- An entry that is no longer mode 0500 is refused by startup and removed with its stamp, so the next launch
--- extracts it again and runs.
local function test_a_warm_start_removes_an_entry_of_another_mode(tmp: string)
  local program, cache = stamped_cache(tmp)
  local entry = entry_of(cache)
  assert(Fs.chmod(entry, 0x1c0))
  local r = launch_bare(program, cache, tmp)
  local err = r.stderr or ""
  assert(not r.ok and err:find("is not mode 0500 (mode 700); removed it", 1, true) ~= nil, err)
  assert(not assert(Fs.status(entry)).exists and stamps(cache) == 0, "the refused entry or its stamp is left")
  launch(program, cache, tmp)
end

--- An entry this user cannot run (0600, as a copy that dropped the bit leaves it) is not taken by the warm start,
--- whose exec would fail on it each time: the launcher's full path repairs it, and the launch runs.
local function test_an_entry_with_no_run_bit_is_repaired(tmp: string)
  local program, cache = stamped_cache(tmp)
  local entry = entry_of(cache)
  assert(Fs.chmod(entry, 0x180))
  local env = environment()
  name_leaf(env, cache)
  local r = assert(Child.run({ program, "ok.tl" }, { env = env, cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(r.ok and r.stdout == "ok\n" and (r.stderr or ""):find("mode is not 0500; repairing", 1, true) ~= nil,
    tostring(r.stderr))
end

--- Writes `bytes` over the entry `entry`, leaving it mode 0500 as the launcher made it, with the modification time
--- it had, so it is no newer than its stamp.
local function overwrite(entry: string, bytes: string)
  local mtime = assert(sys.lstat(entry)).mtime
  assert(Fs.chmod(entry, 0x1c0))
  assert(Fs.write(entry, bytes, 0x1c0))
  assert(Fs.chmod(entry, 0x140))
  assert(Fs.set_mtime(entry, mtime))
end

--- A stamped entry damaged in place with its old modification time, shorter than its core or of its length, reaches
--- the warm start, is refused by startup and removed with its stamp, so the next launch extracts it again and runs.
--- (One damaged with a later time takes the launcher's full path, which repairs it: ci/fixtures/runtime_test.tl.)
local function test_a_warm_start_removes_a_damaged_entry(tmp: string)
  local program, cache = stamped_cache(tmp)
  local entry = entry_of(cache)
  local bytes = assert(Fs.read(entry))
  local record Damage
    bytes: string
    says: string
  end
  local damages: {Damage} = {
    { bytes = bytes:sub(1, #bytes - 1), says = "length differs from the manifest; removed it" },
    { bytes = bytes:sub(1, #bytes - 1) .. (if bytes:sub(-1) == "x" then "y" else "x" end),
      says = "digest differs from the manifest; removed it" },
  }
  for _, damage in ipairs(damages) do
    overwrite(entry, damage.bytes)
    local r = launch_bare(program, cache, tmp)
    local err = r.stderr or ""
    assert(not r.ok and err:find(damage.says, 1, true) ~= nil, err)
    assert(not assert(Fs.status(entry)).exists and stamps(cache) == 0, "the damaged entry or its stamp is left")
    launch(program, cache, tmp)
    assert(Clock.sleep(1100000000))
    launch(program, cache, tmp)
    assert(stamps(cache) == 1, "the extracted entry is stamped again")
  end
end

--- The launcher tells startup it hashed the entry it hands over (COSMIC_PORTABLE_CORE_HASHED) only where it did:
--- one the environment gives a warm start, which hashed nothing, is not taken, and a damaged entry is still found.
local function test_a_hashed_word_from_the_environment_is_not_taken(tmp: string)
  local program, cache = stamped_cache(tmp)
  local entry = entry_of(cache)
  local bytes = assert(Fs.read(entry))
  overwrite(entry, bytes:sub(1, #bytes - 1) .. (if bytes:sub(-1) == "x" then "y" else "x" end))
  local r = launch_bare(program, cache, tmp, { COSMIC_PORTABLE_CORE_HASHED = "1" })
  local err = r.stderr or ""
  assert(not r.ok and err:find("digest differs from the manifest; removed it", 1, true) ~= nil, err)
end

--- Startup takes the launcher's word that it hashed the entry only from a start the launcher made, with its
--- descriptors: a start by path, which no launcher made, is refused with the word, as is any word but "1".
local function test_a_hashed_word_is_taken_only_from_a_launcher(tmp: string)
  local program, cache = stamped_cache(tmp)
  assert(Fs.write(tmp .. "/word.tl", [[
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local function start(env: {string:string}, fds: {integer:integer}, word: string): string
  local copy: mut {string:string} = {}
  for key, value in pairs(env) do copy[key] = value end
  copy["COSMIC_PORTABLE_CORE_HASHED"] = word
  local again = assert(Proc.relaunch())
  local argv: mut {string} = {}
  for _, part in ipairs(again.argv) do argv[#argv + 1] = part end
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = "print('ran')"
  local r = assert(Child.run(argv, { env = copy, fds = fds, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(30) }))
  return tostring(r.code) .. ":" .. (r.stdout or "") .. (r.stderr or "")
end
return function(): integer
  local again = assert(Proc.relaunch())
  local by_path: mut {string:string} = {}
  for key, value in pairs(again.env) do by_path[key] = value end
  by_path["COSMIC_PORTABLE_ARTIFACT_FD"] = nil
  by_path["COSMIC_PORTABLE_CORE_FD"] = nil
  local _, _ = Fs.put(Fs.stdout, start(by_path, {}, "1") .. "\n--\n" .. start(again.env, again.fds, "2"))
  return 0
end
]]))
  local env = environment()
  name_leaf(env, cache)
  local r = assert(Child.run({ program, "word.tl" }, { env = env, cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  local out = r.stdout or ""
  assert(r.ok and out:find("hashed field names no handed core", 1, true) ~= nil and
      out:find("hashed field is invalid", 1, true) ~= nil and out:find("ran\n", 1, true) == nil,
    out .. tostring(r.stderr))
end

--- An entry written since its stamp, newer than it, is not taken by the warm start: the launcher's full path hashes
--- it and repairs it in the same launch, which runs.
local function test_an_entry_newer_than_its_stamp_is_repaired(tmp: string)
  local program, cache = stamped_cache(tmp)
  local entry = entry_of(cache)
  local bytes = assert(Fs.read(entry))
  local stamp = cache .. "/.verified-" .. assert(entry:match("[^/]+$"))
  overwrite(entry, bytes:sub(1, #bytes - 1) .. (if bytes:sub(-1) == "x" then "y" else "x" end))
  assert(Fs.set_mtime(entry, assert(sys.lstat(stamp)).mtime + 1))
  local env = environment()
  name_leaf(env, cache)
  local r = assert(Child.run({ program, "ok.tl" }, { env = env, cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(r.ok and r.stdout == "ok\n" and (r.stderr or ""):find("digest differs; repairing", 1, true) ~= nil,
    tostring(r.stderr))
  assert(assert(Fs.read(entry)) == bytes, "the repair did not restore the entry")
end

--- Startup checks an entry's mode itself, so a start with no launcher before it, as [`Proc.relaunch`] starts one,
--- refuses and removes an entry that is not mode 0500, on every host. The next launch extracts it again.
local function test_a_direct_start_of_an_entry_of_another_mode_removes_it(tmp: string)
  relaunch_or_skip()
  local program = assert(Proc.executable())
  local cache = tmp .. "/cache"
  assert(Fs.write(tmp .. "/ok.tl", "return function(): integer print('ok') return 0 end\n"))
  launch(program, cache, tmp)
  assert(Fs.write(tmp .. "/again.tl", [[
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
return function(): integer
  local again = assert(Proc.relaunch())
  assert(Fs.chmod(assert(again.argv[1]), 0x1c0))
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
  assert(r.ok and out:find("is not mode 0500 (mode 700); removed it", 1, true) ~= nil and
      out:sub(1, 2) ~= "0\n" and out:find("\nran\n", 1, true) == nil, out .. tostring(r.stderr))
  for _, name in ipairs((assert(Fs.list(cache)))) do
    assert(name:sub(1, 5) ~= "core-", "the refused entry is left: " .. name)
  end
  launch(program, cache, tmp)
end
