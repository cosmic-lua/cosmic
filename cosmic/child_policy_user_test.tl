--- [`Child.start`]'s `policy` and the user its child runs as, and the
--- processes it may start (cosmic/child.tl): a caller that is not root meets
--- one user, itself, and `limits.processes` is the count of the sandbox's
--- user namespace. The kernel's own verdict on live children: the child is a
--- stand-in (build/stand_in.tl), a static program that does what its script
--- says. They need a sandbox that nests (`requires`): where the platform has
--- none they are not applicable, and where this host gives no user
--- namespace, Landlock or seccomp each skips itself (Test.skip). The tests
--- of a root caller are in cosmic/child_policy_root_user_test.tl; the
--- refusals of `limits.processes` that come before a child are in
--- cosmic/child_policy_anywhere_test.tl.

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

local function test_a_caller_that_is_not_root_runs_its_child_as_itself(tmp: string)
  if sys.getuid() == 0 then
    Test.skip("this process is root, which meets the other users of a root caller")
    return
  end
  local at = placed(tmp)
  local ran = under(at.probe, { isolate = { "proc" },
    grants = { { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" } } },
    at.work, "status-field Uid")
  if ran == nil then return end
  assert(ran.code == 0, ran.said)
  local ids = uids(ran.said)
  assert(#ids == 4 and ids[1] == sys.getuid() and ids[2] == sys.getuid(), ran.said)
end

local function test_a_caller_that_is_not_root_may_name_only_itself(tmp: string)
  if sys.getuid() == 0 then
    Test.skip("this process is root, which meets the other users of a root caller")
    return
  end
  local at = placed(tmp)
  local grants: {Sandbox.Grant} = { { path = at.probe, letters = "rx" }, { path = "/proc", letters = "r" } }
  local ran = under(at.probe, { user = sys.getuid(), grants = grants }, at.work, "status-field Uid")
  if ran == nil then return end
  assert(ran.code == 0, ran.said)
  local ids = uids(ran.said)
  assert(#ids == 4 and ids[1] == sys.getuid(), ran.said)
  local mine = under(at.probe, { user = sys.getuid(), group = sys.getgid(), grants = grants },
    at.work, "status-field Uid")
  if mine == nil then return end
  assert(mine.code == 0, mine.said)
  local why = refused(at.probe, { user = sys.getuid() + 1, grants = grants }, at.work)
  assert(why:find("^child: start: sandbox: user ") and why:find("only a root caller", 1, true), why)
  why = refused(at.probe, { user = sys.getuid(), group = sys.getgid() + 1, grants = grants }, at.work)
  assert(why:find("only a root caller", 1, true), why)
end

--- Whether the kernel counts a user namespace's processes apart from its
--- creator's, as a start under `processes` takes it to.
local function kernel_counts(): boolean
  return Sandbox.counts_per_namespace(assert(sys.uname()).release)
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
