--- [`Child.start`]'s `policy` and the user its child runs as for a root
--- caller (cosmic/child.tl): a user of a range of its own, never root, the
--- files it cannot use mounted idmapped or refused. The kernel's own verdict
--- on live children: the child is a stand-in (build/stand_in.tl), a static
--- program that does what its script says.
---
--- A root caller's paths need a root that holds CAP_SETUID, CAP_SETGID,
--- CAP_SETFCAP and CAP_SYS_ADMIN and a user namespace mapping the ids a
--- sandbox's user is chosen from (`requires` asks for `nest`), and a worker
--- that is root itself, which no sandboxed worker is, and none of CI's
--- runners: where the worker is not root each test skips (Test.skip). They
--- run in a run that is not sandboxed, as root
--- (`COSMIC_TEST_SANDBOX=0 cosmic test`).
-- TODO: run the root caller's tests in CI, where they are skipped today,
-- once a leg runs the suite as root (doc/roadmap.md's root leg): until then
-- only a developer's or an agent's run as root checks them.
-- TODO: require `root`, and that the worker is, once a CI leg promises
-- `root` (ci/cosmic_ci/capabilities.tl; build/tree_checks.tl refuses a
-- name no leg promises) and a requirement names the worker's user: `root`
-- is the runner's, and a root run that sandboxes its workers starts each as
-- a user of its own, so it would pass `root` and still skip every test here.
-- TODO: test the refusal of an idmapped mount by a file system that gives
-- none (an overlay, a network file system), once a test can make one:
-- core/syscalls_tool_test.tl checks only a caller that may not map, and
-- the mount's message names no file system.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local searchable = require("build.searchable")
local stand_in = require("build.stand_in")

--- The temporary directory. `nests`: a policy's isolation makes a root of
--- its own, which a worker held by a Landlock ruleset cannot.
Test.policy{
  promises = { "nest" },
  env = { "TMPDIR" },
  requires = { "nest" },
}

--- Whether `why`, a start's failure, is the platform or the host giving no
--- Landlock, seccomp, user namespace or idmapped mount (a container's
--- runtime may refuse one on a file system that supports it).
local function unsandboxable(why: string): boolean
  for _, word in ipairs({ "Landlock", "seccomp", "not implemented", "namespace", "own /proc",
      "root could not be built", "an idmapped mount of " }) do
    if why:find(word, 1, true) then return true end
  end
  return false
end

--- What a script left and how its program ended.
local record Outcome
  code: integer
  said: string
end

--- Runs `script` in `program` under `policy`, starting in `cwd`: its output
--- and how it ended. Skips the test, returning nil, where the host gives
--- no sandbox; fails the test where the start is refused for another
--- reason, which `refused` is told.
local function under(program: string, policy: Sandbox.Policy, cwd: string, script: string): Outcome
  local result, why = Child.run({ program, script },
    { policy = policy, cwd = cwd, stdout = "capture", stderr = "stdout" })
  if result == nil then
    assert(unsandboxable(why), "the start was refused: " .. why)
    Test.skip(why)
    return nil
  end
  return { code = result.code or -1, said = result.stdout or "" }
end

--- Why a start under `policy` is refused, "" for none.
local function refused(program: string, policy: Sandbox.Policy, cwd: string): string
  local handle, why = Child.start({ program, "print hi" }, { policy = policy, cwd = cwd })
  if handle ~= nil then
    local _, _ = handle:wait()
    return ""
  end
  -- A refusal of the policy itself is the answer; the host's is a skip.
  if unsandboxable(why) and not why:find("^child: start: sandbox: ") then
    Test.skip(why)
  end
  return why
end

--- A permission mode written in octal.
local function octal(text: string): integer
  return assert(math.tointeger(tonumber(text, 8)))
end

--- The user ids a `Uid:` line of /proc/self/status lists, a stand-in's
--- answer to `status-field Uid`: real, effective, saved and filesystem.
local function uids(said: string): {integer}
  local found: {integer} = {}
  for number in said:gmatch("%d+") do
    found[#found + 1] = assert(math.tointeger(tonumber(number)))
  end
  return found
end

--- The program, a working directory and a directory every user may search.
local record Place
  probe: string
  work: string
end

--- Builds the stand-in and a working directory in `tmp`, opened to
--- everyone as a sandbox's own user needs it of the host's tree, whatever
--- the umask they were made under.
local function placed(tmp: string): Place
  searchable.open(tmp)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(sys.chmod(probe, octal("755")))
  searchable.open(Fs.dirname(probe))
  local work = assert(Fs.mkdirs(tmp .. "/work") and tmp .. "/work")
  assert(sys.chmod(work, octal("755")))
  return { probe = probe, work = work }
end

--- Whether this worker is root, as a root caller's tests need: skips the
--- test where it is not, which is every sandboxed worker's case.
local function as_root(): boolean
  if sys.getuid() ~= 0 then
    Test.skip("this worker is not root: a root run sandboxes its workers as users of their own")
    return false
  end
  return true
end

--- The pool a root caller's users are chosen from: [`Sandbox.user_id`]'s
--- first id and last for this process's own maps.
local function pool(): integer, integer
  local uid_map = assert(Fs.read("/proc/self/uid_map"))
  local gid_map = assert(Fs.read("/proc/self/gid_map"))
  local first = assert(Sandbox.user_id(uid_map, gid_map, 0))
  return first, first + 4095
end

local function test_a_root_caller_runs_its_child_as_a_user_of_a_range_of_its_own(tmp: string)
  if not as_root() then return end
  local at = placed(tmp)
  local first, last = pool()
  for _, isolate in ipairs({ { "proc" }, { "file" } }) do
    local ran = under(at.probe, { isolate = isolate, grants = { { path = at.probe, letters = "rx" },
      { path = at.work, letters = "r" } } }, at.work, "status-field Uid; status-field Gid")
    if ran == nil then return end
    assert(ran.code == 0, ran.said)
    local ids = uids(ran.said)
    assert(#ids == 8, ran.said)
    for _, id in ipairs(ids) do
      assert(id ~= 0 and id >= first and id <= last, "isolate " .. #isolate .. ": " .. ran.said)
    end
    assert(ids[1] == ids[5], ran.said)
  end
end

--- A root caller's policy that makes no namespace gives root up for its
--- user directly, in this process's own user namespace, so it starts
--- where a container masks /proc, whose procfs of a sandbox's own is
--- refused: that refusal fails this test rather than skipping it.
local function test_a_root_caller_s_policy_with_no_namespace_drops_to_a_pool_user(tmp: string)
  if not as_root() then return end
  local at = placed(tmp)
  searchable.share(at.work)
  local first, last = pool()
  local result, why = Child.run({ at.probe,
    "status-field Uid; status-field Gid; cat /proc/self/uid_map; create made x" },
    { policy = { grants = { { path = at.probe, letters = "rx" }, { path = at.work, letters = "rwc" },
      { path = "/proc", letters = "r" } } },
      cwd = at.work, stdout = "capture", stderr = "stdout" })
  if result == nil then
    if why:find("own /proc", 1, true) == nil and unsandboxable(why) then
      Test.skip(why)
      return
    end
    error("the start was refused: " .. why)
  end
  local said = result.stdout or ""
  assert(result.code == 0, said)
  local ids = uids(said:match("^(.-\n.-\n)") or "")
  assert(#ids == 8, said)
  for _, id in ipairs(ids) do
    assert(id ~= 0 and id >= first and id <= last, said)
  end
  assert(ids[1] == ids[5], said)
  -- No user namespace of its own: it has this process's maps.
  local own_map = assert(Fs.read("/proc/self/uid_map"))
  assert(said:find(own_map, 1, true) ~= nil, "a user namespace of its own: " .. said)
  local made = assert(sys.stat(at.work .. "/made"))
  assert(made.uid == ids[1] and made.gid == ids[5], "made is " .. made.uid .. ":" .. made.gid)
end

--- A user a root caller names is the same every start and owns what it
--- owns on the host: a directory of its own, closed to everyone else, is
--- its to read and write without `isolate` "file", and what one start
--- makes the next one changes.
local function test_a_root_caller_s_named_user_owns_its_files_from_start_to_start(tmp: string)
  if not as_root() then return end
  local at = placed(tmp)
  local named = 4242
  local dir = tmp .. "/theirs"
  assert(Fs.mkdirs(dir) and Fs.write(dir .. "/inside", "secret\n"))
  assert(sys.chown(dir, named, named) and sys.chown(dir .. "/inside", named, named))
  assert(sys.chmod(dir, octal("700")) and sys.chmod(dir .. "/inside", octal("600")))
  local policy: Sandbox.Policy = { user = named, grants = { { path = at.probe, letters = "rx" },
    { path = dir, letters = "rwc" }, { path = "/proc", letters = "r" } } }
  for round = 1, 2 do
    local result, why = Child.run({ at.probe, "status-field Uid; cat " .. dir .. "/inside; " ..
        "append " .. dir .. "/made " .. round }, { policy = policy, cwd = at.work, stdout = "capture",
          stderr = "stdout" })
    assert(result ~= nil, "the start was refused: " .. tostring(why))
    local said = result.stdout or ""
    assert(result.code == 0, said)
    local ids = uids(said:match("^(.-\n)") or "")
    assert(#ids == 4 and ids[1] == named and ids[4] == named, said)
    assert(said:find("secret", 1, true), said)
  end
  local text = Fs.read(dir .. "/made")
  assert(text == "1\n2\n", tostring(text))
  local made = assert(sys.stat(dir .. "/made"))
  assert(made.uid == named and made.gid == named, made.uid .. ":" .. made.gid)
end

local function test_a_root_caller_may_not_name_a_user_of_the_pool(tmp: string)
  if not as_root() then return end
  local at = placed(tmp)
  local first = pool()
  local why = refused(at.probe, { user = first + 7, grants = { { path = at.probe, letters = "rx" } } },
    at.work)
  assert(why:find("^child: start: sandbox: user ") and why:find("of the pool", 1, true), why)
end

local function test_a_root_caller_s_named_user_and_group_hold_under_isolation(tmp: string)
  if not as_root() then return end
  local at = placed(tmp)
  local ran = under(at.probe, { isolate = { "proc" }, user = 4242, group = 4343, grants = {
    { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" } } }, at.work,
    "status-field Uid; status-field Gid")
  if ran == nil then return end
  assert(ran.code == 0, ran.said)
  local ids = uids(ran.said)
  assert(#ids == 8 and ids[1] == 4242 and ids[4] == 4242 and ids[5] == 4343 and ids[8] == 4343,
    ran.said)
end

local function test_a_root_caller_s_concurrent_sandboxes_run_as_different_users(tmp: string)
  if not as_root() then return end
  local at = placed(tmp)
  local policy: Sandbox.Policy = { isolate = { "proc" }, grants = { { path = at.probe, letters = "rx" },
    { path = at.work, letters = "r" } } }
  local running: {Child.Handle} = {}
  for i = 1, 3 do
    local handle, why = Child.start({ at.probe, "status-field Uid; sleep 300" },
      { policy = policy, cwd = at.work, stdout = "capture", stderr = "stdout" })
    if handle == nil then
      Test.skip(why)
      return
    end
    running[i] = handle
  end
  local seen: {integer:boolean} = {}
  for _, handle in ipairs(running) do
    local result = assert(handle:wait())
    local id = uids(result.stdout or "")[1]
    assert(id ~= nil and id ~= 0 and not seen[id], tostring(id))
    seen[id] = true
  end
end

local function test_a_root_caller_s_tmp_is_its_child_s_to_write(tmp: string)
  if not as_root() then return end
  local at = placed(tmp)
  local ran = under(at.probe, { isolate = { "proc" }, tmp = true, grants = {
    { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" } } }, at.work,
    "create $TMPDIR/made x && cat $TMPDIR/made")
  if ran == nil then return end
  assert(ran.code == 0 and ran.said == "x\n", ran.code .. ": " .. ran.said)
end

local function test_a_root_caller_s_grant_open_to_everyone_is_used_as_it_is(tmp: string)
  if not as_root() then return end
  local at = placed(tmp)
  assert(Fs.write(at.work .. "/data", "open\n"))
  assert(sys.chmod(at.work .. "/data", octal("644")))
  local ran = under(at.probe, { isolate = { "proc" }, grants = { { path = at.probe, letters = "rx" },
    { path = at.work, letters = "r" } } }, at.work, "cat data")
  if ran == nil then return end
  assert(ran.code == 0 and ran.said == "open\n", ran.said)
end

--- A directory only its owner may use, holding a file, in `tmp`.
local function closed(tmp: string, name: string): string
  local dir = tmp .. "/" .. name
  assert(Fs.mkdirs(dir))
  assert(Fs.write(dir .. "/inside", "secret\n"))
  assert(sys.chmod(dir, octal("700")))
  return dir
end

--- Under `isolate` "file" a named user's grant of another owner's closed
--- tree is mounted so that owner's files are its own; its own files there
--- show as the owner's, written and read as their mode lets everyone --
--- their own group shows as the owner's, which the user is not in -- and
--- stay its own on the host; a third user's are read as their mode lets
--- everyone and never written.
local function test_a_root_caller_s_named_user_meets_its_own_files_as_the_owner_s_through_an_idmap(tmp: string)
  if not as_root() then return end
  local at = placed(tmp)
  local dir = closed(tmp, "theirs")
  assert(sys.chown(dir, 2000, 2000) and sys.chown(dir .. "/inside", 2000, 2000))
  local function owned(name: string, owner: integer, mode: string)
    assert(Fs.write(dir .. "/" .. name, name .. "\n") and sys.chown(dir .. "/" .. name, owner, owner))
    assert(sys.chmod(dir .. "/" .. name, octal(mode)))
  end
  owned("open", 4242, "666")
  owned("shut", 4242, "600")
  owned("grouped", 4242, "660")
  owned("third", 3000, "666")
  local policy: Sandbox.Policy = { isolate = { "file" }, user = 4242, grants = {
    { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" },
    { path = dir, letters = "rw" } } }
  local ran = under(at.probe, policy, at.work, "cat " .. dir .. "/inside; append " .. dir ..
      "/open more; cat " .. dir .. "/open; cat " .. dir .. "/third")
  if ran == nil then return end
  assert(ran.code == 0 and ran.said == "secret\nopen\nmore\nthird\n", ran.code .. ": " .. ran.said)
  local open = assert(sys.stat(dir .. "/open"))
  assert(open.uid == 4242 and open.gid == 4242, "open is " .. open.uid .. ":" .. open.gid)
  local shut = under(at.probe, policy, at.work, "cat " .. dir .. "/shut")
  assert(shut ~= nil and shut.code ~= 0 and shut.said:find("Permission denied", 1, true), shut.said)
  local grouped = under(at.probe, policy, at.work, "cat " .. dir .. "/grouped")
  assert(grouped ~= nil and grouped.code ~= 0 and grouped.said:find("Permission denied", 1, true),
    grouped.said)
  local third = under(at.probe, policy, at.work, "append " .. dir .. "/third more")
  assert(third ~= nil and third.code ~= 0 and third.said:find("Permission denied", 1, true), third.said)
end

local function test_a_root_caller_s_closed_grant_is_idmapped_under_isolate_file(tmp: string)
  if not as_root() then return end
  local at = placed(tmp)
  local dir = closed(tmp, "closed")
  local before = assert(sys.stat(dir))
  local ran = under(at.probe, { isolate = { "file" }, grants = {
    { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" },
    { path = dir, letters = "rwc" } } }, at.work,
    "cat " .. dir .. "/inside; create " .. dir .. "/made y; cat " .. dir .. "/made")
  if ran == nil then return end
  assert(ran.code == 0 and ran.said == "secret\ny\n", ran.code .. ": " .. ran.said)
  -- What it made is the owner's on the host, not the sandbox's user's.
  local made = assert(sys.stat(dir .. "/made"))
  assert(made.uid == before.uid and made.gid == before.gid,
    "owned by " .. made.uid .. ":" .. made.gid .. ", not " .. before.uid .. ":" .. before.gid)
  assert(before.mode == assert(sys.stat(dir)).mode)
end

local function test_a_root_caller_s_closed_read_only_grant_is_idmapped_and_stays_read_only(tmp: string)
  if not as_root() then return end
  local at = placed(tmp)
  local dir = closed(tmp, "closed")
  local ran = under(at.probe, { isolate = { "file" }, grants = {
    { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" },
    { path = dir, letters = "r" } } }, at.work,
    "cat " .. dir .. "/inside; create " .. dir .. "/made y")
  if ran == nil then return end
  assert(ran.code == 1 and ran.said:find("secret", 1, true), ran.code .. ": " .. ran.said)
  assert(not Fs.exists(dir .. "/made"))
end

local function test_a_root_caller_s_closed_grant_fails_naming_it_without_isolate_file(tmp: string)
  if not as_root() then return end
  local at = placed(tmp)
  local dir = closed(tmp, "closed")
  for _, letters in ipairs({ "r", "rwc" }) do
    local why = refused(at.probe, { isolate = { "proc" }, grants = {
      { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" },
      { path = dir, letters = letters } } }, at.work)
    assert(why:find("^child: start: sandbox: grant ") and why:find(dir, 1, true), why)
    assert(why:find("isolate \"file\"", 1, true) and why:find("owned by user", 1, true), why)
  end
end

local function test_a_root_caller_s_grant_no_one_may_use_fails_naming_it(tmp: string)
  if not as_root() then return end
  local at = placed(tmp)
  local locked = tmp .. "/locked"
  assert(Fs.write(locked, "x"))
  assert(sys.chmod(locked, octal("200")))
  for _, isolate in ipairs({ { "proc" }, { "file" } }) do
    local why = refused(at.probe, { isolate = isolate, grants = {
      { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" },
      { path = locked, letters = "r" } } }, at.work)
    assert(why:find("^child: start: sandbox: grant ") and why:find(locked, 1, true), why)
    assert(why:find("does not give its owner the right to read", 1, true), why)
  end
end

local function test_a_root_caller_s_directory_above_a_grant_it_cannot_search_fails_naming_it(tmp: string)
  if not as_root() then return end
  local at = placed(tmp)
  local shut = tmp .. "/shut"
  assert(Fs.mkdirs(shut .. "/in"))
  assert(sys.chmod(shut .. "/in", octal("755")))
  assert(sys.chmod(shut, octal("700")))
  local why = refused(at.probe, { isolate = { "proc" }, grants = {
    { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" },
    { path = shut .. "/in", letters = "r" } } }, at.work)
  assert(why:find(shut, 1, true) and why:find("search", 1, true), why)
  -- Under isolate file the root holds the grant without walking to it.
  local ran = under(at.probe, { isolate = { "file" }, grants = {
    { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" },
    { path = shut .. "/in", letters = "r" } } }, at.work, "ls " .. shut .. "/in")
  if ran == nil then return end
  assert(ran.code == 0, ran.said)
end

local function test_a_root_caller_s_tmp_beneath_a_directory_it_cannot_search_fails_naming_tmpdir(tmp: string)
  if not as_root() then return end
  local at = placed(tmp)
  -- TMPDIR is this test's own directory, which the start makes `tmp`'s in.
  local tmpdir = assert(sys.getenv("TMPDIR"))
  assert(sys.chmod(tmpdir, octal("700")))
  local grants: {Sandbox.Grant} = { { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" } }
  local why = refused(at.probe, { isolate = { "proc" }, tmp = true, grants = grants }, at.work)
  assert(why:find("^child: start: sandbox: tmp makes its directory in TMPDIR", 1) and
      why:find(tmpdir, 1, true) and why:find("isolate", 1, true), why)
  -- Under isolate file /tmp is the sandbox's own tmpfs, whatever TMPDIR is.
  local ran = under(at.probe, { isolate = { "file" }, tmp = true, grants = grants }, at.work,
    "create /tmp/made z")
  if ran == nil then return end
  assert(ran.code == 0, ran.said)
end
