--- The portable launcher's warm start: a stamped cache entry runs with no
--- program but the shell, and startup checks what the shell cannot see.
--- The module requires Linux, whose launcher's cold path runs other
--- programs. The cache's cold path is core/launcher_cache_test.tl's.
---
--- TODO: hold macOS's warm start (the entry run by name, the Library/Caches
--- leaf, bash 3.2's test) to these tests once a macOS worker runs them: the
--- stamp's launches and the fixture's `name_leaf` know Linux's paths and
--- tools alone.

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
  { path = "o/bin", letters = "rx" } },
  requires = { "os:linux" } }

local environment = launcher_cache_fixture.environment
local name_leaf = launcher_cache_fixture.name_leaf
local launch = launcher_cache_fixture.launch
local stamps = launcher_cache_fixture.stamps
local relaunch_or_skip = launcher_cache_fixture.relaunch_or_skip
local entry_of = launcher_cache_fixture.entry_of

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

--- The default cache leaf under HOME of a warm entry, stamped.
local function stamped_cache(tmp: string): (string, string)
  relaunch_or_skip()
  local program = assert(Proc.executable())
  local cache = tmp .. "/home/.cache/cosmic/cores"
  assert(Fs.write(tmp .. "/ok.tl", "return function(): integer print('ok') return 0 end\n"))
  launch(program, cache, tmp)
  assert(Clock.sleep(1100000000))
  launch(program, cache, tmp)
  assert(stamps(cache) == 1, "a settled entry is stamped")
  return program, cache
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

--- An entry of 0555, as root's shared copies are, is refused and removed in a leaf that is not root's: the mode
--- stands only where root alone writes both.
local function test_an_entry_of_root_shared_mode_in_a_users_leaf_is_removed(tmp: string)
  local program, cache = stamped_cache(tmp)
  local entry = entry_of(cache)
  if assert(assert(Fs.status(entry)).stat).uid == 0 then
    Test.skip("root's leaf takes 0555 entries")
  end
  assert(Fs.chmod(entry, 0x16d))
  local r = launch_bare(program, cache, tmp)
  local err = r.stderr or ""
  assert(not r.ok and err:find("is not mode 0500 (mode 555); removed it", 1, true) ~= nil, err)
  assert(not assert(Fs.status(entry)).exists, "the refused entry is left")
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
