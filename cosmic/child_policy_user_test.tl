--- [`Child.start`]'s `policy` and the user its child runs as, and the
--- processes it may start (cosmic/child.tl): never root, a user of its
--- own for a root caller with the files it cannot use mounted idmapped or
--- refused, and `limits.processes` as the count of the sandbox's user
--- namespace. The kernel's own verdict on live children: the child is a
--- stand-in (build/stand_in.tl), a static program that does what its
--- script says.
---
--- A caller that is not root meets one user, itself; the paths a root
--- caller takes need a root that holds CAP_SETUID, CAP_SETGID, CAP_SETFCAP
--- and CAP_SYS_ADMIN and a user namespace mapping the ids a sandbox's user
--- is chosen from, which no sandboxed worker is, and none of CI's
--- runners: those tests return silently where this process is not root,
--- as a host program missing from the host does, and are skipped where it
--- is root and cannot map (build.sandbox_skip). They run in a run that
--- is not sandboxed, as root (`COSMIC_TEST_SANDBOX=0 cosmic test`).
-- TODO: run the root caller's tests in CI, where they return silently
-- today, once a leg runs the suite as root (doc/roadmap.md's root leg):
-- until then only a developer's or an agent's run as root checks them.
-- TODO: test the refusal of an idmapped mount by a file system that gives
-- none (an overlay, a network file system), once a test can make one:
-- core/syscalls_tool_test.tl checks only a caller that may not map, and
-- the mount's message names no file system.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local sandbox_skip = require("build.sandbox_skip")
local searchable = require("build.searchable")
local stand_in = require("build.stand_in")

--- The temporary directory. `nests`: a policy's isolation makes a root of
--- its own, which a worker held by a Landlock ruleset cannot.
Test.needs{ env = { "TMPDIR" }, nests = true }

--- Whether `why`, a start's failure, is the platform or the host giving no
--- Landlock, seccomp or user namespace.
local function unsandboxable(why: string): boolean
  for _, word in ipairs({ "Landlock", "seccomp", "not implemented", "namespace", "own /proc",
      "root could not be built" }) do
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
    sandbox_skip.refused(why)
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
    sandbox_skip.refused(why)
  end
  return why
end

--- Whether the kernel counts a user namespace's processes apart from its
--- creator's, as a start under `processes` takes it to.
local function kernel_counts(): boolean
  return Sandbox.counts_per_namespace(assert(sys.uname()).release)
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

--- Whether this process is root and may map the user a root caller's
--- sandbox runs as, from outside (build.confine's `may_map_ids`). False
--- where it is not root, which has nothing to check, and, with the test
--- skipped, where it is root and cannot.
local function root_that_maps(): boolean
  if sys.getuid() ~= 0 then return false end
  if confine.may_map_ids() then return true end
  sandbox_skip.refused("this process is root without CAP_SETUID, CAP_SETGID and CAP_SETFCAP in " ..
      "effect, so it cannot map the user a sandbox runs as")
  return false
end

--- The program, a working directory and a directory every user may search.
local record Place
  probe: string
  work: string
end

--- Builds the stand-in and a working directory in `tmp`, opened to
--- everyone as a sandbox's own user needs it of the host's tree.
local function placed(tmp: string): Place
  searchable.open(tmp)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local work = assert(Fs.mkdirs(tmp .. "/work") and tmp .. "/work")
  assert(sys.chmod(work, octal("755")))
  return { probe = probe, work = work }
end

local function test_a_caller_that_is_not_root_runs_its_child_as_itself(tmp: string)
  if sys.getuid() == 0 then return end
  local at = placed(tmp)
  local ran = under(at.probe, { isolate = { "proc" },
    grants = { { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" } } },
    at.work, "status-field Uid")
  if ran == nil then return end
  assert(ran.code == 0, ran.said)
  local ids = uids(ran.said)
  assert(#ids == 4 and ids[1] == sys.getuid() and ids[2] == sys.getuid(), ran.said)
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
  if not root_that_maps() then return end
  local at = placed(tmp)
  local first, last = pool()
  for _, isolate in ipairs({ { "proc" }, { "file" }, {} }) do
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

--- A root caller with no isolation needs none of it: the child runs as a
--- user of the pool dropped to, not mapped through a user namespace, so
--- the start needs no procfs of its own and works where a container masks
--- /proc. Until the start drops privs instead of mapping them, this fails
--- naming the sandbox's own /proc -- which is the bug, not the host, so
--- unlike `under` this does not skip that refusal.
local function test_a_root_caller_without_isolation_drops_to_a_pool_user(tmp: string)
  if not root_that_maps() then return end
  local at = placed(tmp)
  local first, last = pool()
  -- The child runs as its user and makes a file in the work directory, so
  -- both are opened to everyone: the probe the builder wrote under a
  -- restrictive umask, the work directory as `reached_by` asks of a root
  -- caller's grants.
  assert(sys.chmod(at.probe, octal("755")))
  searchable.open(Fs.dirname(at.probe))
  searchable.share(at.work)
  local handle, why = Child.start({ at.probe, "create made x" },
    { policy = { grants = { { path = at.probe, letters = "rx" },
      { path = at.work, letters = "rwc" } } },
      cwd = at.work, stdout = "capture", stderr = "stdout" })
  assert(handle ~= nil, "the start was refused: " .. tostring(why))
  local result = assert(handle:wait())
  assert(result.code == 0, tostring(result.stdout))
  -- What the child made is its user's on the host: a user of the pool,
  -- never root.
  local made = assert(sys.stat(at.work .. "/made"))
  assert(made.uid ~= 0 and made.uid >= first and made.uid <= last and made.gid == made.uid,
    "made is owned by " .. made.uid .. ":" .. made.gid .. ", not a user of the pool")
end

local function test_a_root_caller_s_concurrent_sandboxes_run_as_different_users(tmp: string)
  if not root_that_maps() then return end
  local at = placed(tmp)
  local policy: Sandbox.Policy = { isolate = { "proc" }, grants = { { path = at.probe, letters = "rx" },
    { path = at.work, letters = "r" } } }
  local running: {Child.Handle} = {}
  for i = 1, 3 do
    local handle, why = Child.start({ at.probe, "status-field Uid; sleep 300" },
      { policy = policy, cwd = at.work, stdout = "capture", stderr = "stdout" })
    if handle == nil then
      sandbox_skip.refused(why)
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
  if not root_that_maps() then return end
  local at = placed(tmp)
  local ran = under(at.probe, { isolate = { "proc" }, tmp = true, grants = {
    { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" } } }, at.work,
    "create $TMPDIR/made x && cat $TMPDIR/made")
  if ran == nil then return end
  assert(ran.code == 0 and ran.said == "x\n", ran.code .. ": " .. ran.said)
end

local function test_a_root_caller_s_grant_open_to_everyone_is_used_as_it_is(tmp: string)
  if not root_that_maps() then return end
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

local function test_a_root_caller_s_closed_grant_is_idmapped_under_isolate_file(tmp: string)
  if not root_that_maps() then return end
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
  if not root_that_maps() then return end
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
  if not root_that_maps() then return end
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
  if not root_that_maps() then return end
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
  if not root_that_maps() then return end
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

local function test_a_root_caller_that_cannot_map_a_user_fails_naming_why()
  if sys.getuid() ~= 0 or confine.may_map_ids() then return end
  local why = refused("/bin/true", { isolate = { "proc" } }, "/")
  assert(why:find("never runs as root", 1, true) and why:find("CAP_SETFCAP", 1, true), why)
end

--- The processes of a limit `limit` a stand-in could start, under
--- `isolate` proc: how many it started before the kernel refused one, and
--- the refusal.
local function started_under(at: Place, limit: integer, wanted: integer): integer, string
  local ran = under(at.probe, { isolate = { "proc" }, promises = { "fork" },
    grants = { { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" } },
    limits = { processes = limit } }, at.work,
    "start-count " .. wanted .. " " .. at.probe .. " sleep-forever")
  if ran == nil then return -1, "" end
  assert(ran.code == 0, ran.said)
  local count, rest = ran.said:match("^started (%d+)(.*)\n$")
  assert(count ~= nil, ran.said)
  return assert(math.tointeger(tonumber(count))), rest
end

local function test_processes_holds_the_whole_sandbox_to_a_count(tmp: string)
  local at = placed(tmp)
  local limit = 6
  local count, rest = started_under(at, limit, 20)
  if count < 0 then return end
  -- The program is one of the processes counted; the sandbox's init is
  -- another where it is in the same user namespace, which it is not for a
  -- root caller's program, which makes one of its own beneath.
  assert(count >= limit - 2 and count <= limit - 1, count .. rest)
  assert(rest:find("Resource temporarily unavailable", 1, true), rest)
end

local function test_isolate_brings_a_default_count_of_4096_and_a_policy_s_own_is_exact(tmp: string)
  local at = placed(tmp)
  local grants: {Sandbox.Grant} = { { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" } }
  local ran = under(at.probe, { isolate = { "proc" }, grants = grants }, at.work, "rlimit nproc")
  if ran == nil then return end
  assert(ran.code == 0, ran.said)
  local hard = assert(sys.getrlimit(sys.RLIMIT_NPROC)).hard
  local soft, limit = ran.said:match("^nproc (%d+) (%d+)\n$")
  assert(soft ~= nil, ran.said)
  if kernel_counts() then
    -- Lowered to this process's hard limit where that is lower.
    local expected = math.min(4096, hard)
    assert(tonumber(soft) == expected and tonumber(limit) == expected, ran.said)
  else
    assert(tonumber(soft) == assert(sys.getrlimit(sys.RLIMIT_NPROC)).soft, ran.said)
  end
  local given = under(at.probe, { isolate = { "file" }, grants = grants, limits = { processes = 77 } },
    at.work, "rlimit nproc")
  if given == nil then return end
  if kernel_counts() then
    assert(given.code == 0 and given.said == "nproc 77 77\n", given.said)
  end
  -- None without isolation: the caller's own.
  local none = under(at.probe, { grants = grants }, at.work, "rlimit nproc")
  if none == nil then return end
  assert(none.code == 0 and tonumber(none.said:match("^nproc (%d+)")) == assert(sys.getrlimit(sys.RLIMIT_NPROC)).soft,
    none.said)
end

local function test_processes_without_isolation_fails_naming_what_it_needs(tmp: string)
  local at = placed(tmp)
  local why = refused(at.probe, { grants = { { path = at.probe, letters = "rx" } },
    limits = { processes = 8 } }, at.work)
  assert(why:find("^child: start: sandbox: limits.processes") and why:find("isolate", 1, true), why)
end

local function test_processes_above_the_callers_hard_limit_fails_naming_it(tmp: string)
  local at = placed(tmp)
  local hard = assert(sys.getrlimit(sys.RLIMIT_NPROC)).hard
  if hard == math.maxinteger then return end
  local why = refused(at.probe, { isolate = { "proc" }, grants = {
    { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" } },
    limits = { processes = hard + 1 } }, at.work)
  if kernel_counts() then
    assert(why:find("hard limit on processes", 1, true), why)
  else
    assert(why:find("Linux 5.17", 1, true), why)
  end
end

local function test_a_root_caller_s_tmp_beneath_a_directory_it_cannot_search_fails_naming_tmpdir(tmp: string)
  if not root_that_maps() then return end
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
