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

local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local ChildPolicy = require("build.child_policy_fixture")

--- The temporary directory. `nests`: a policy's isolation makes a root of
--- its own, which a worker held by a Landlock ruleset cannot.
Test.policy{
  promises = { "nest" },
  env = { "TMPDIR" },
  requires = { "nest" },
}

--- The user ids a `Uid:` line of /proc/self/status lists, a stand-in's
--- answer to `status-field Uid`: real, effective, saved and filesystem.
local function uids(said: string): {integer}
  local found: mut {integer} = {}
  for number in said:gmatch("%d+") do
    found[#found + 1] = assert(math.tointeger(tonumber(number)))
  end
  return found
end

local function test_a_caller_that_is_not_root_runs_its_child_as_itself(tmp: string)
  if sys.getuid() == 0 then
    Test.skip("this process is root, which meets the other users of a root caller")
    return
  end
  local at = ChildPolicy.placed(tmp)
  local ran = ChildPolicy.under(at.probe, { isolate = { "proc" },
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
  local at = ChildPolicy.placed(tmp)
  local grants: {Sandbox.Grant} = { { path = at.probe, letters = "rx" }, { path = "/proc", letters = "r" } }
  local ran = ChildPolicy.under(at.probe, { user = sys.getuid(), grants = grants }, at.work, "status-field Uid")
  if ran == nil then return end
  assert(ran.code == 0, ran.said)
  local ids = uids(ran.said)
  assert(#ids == 4 and ids[1] == sys.getuid(), ran.said)
  local mine = ChildPolicy.under(at.probe, { user = sys.getuid(), group = sys.getgid(), grants = grants },
    at.work, "status-field Uid")
  if mine == nil then return end
  assert(mine.code == 0, mine.said)
  local why = ChildPolicy.refused(at.probe, { user = sys.getuid() + 1, grants = grants }, at.work)
  assert(why:find("^child: start: sandbox: user ") and why:find("only a root caller", 1, true), why)
  why = ChildPolicy.refused(at.probe, { user = sys.getuid(), group = sys.getgid() + 1, grants = grants }, at.work)
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
local function started_under(at: ChildPolicy.Place, limit: integer, wanted: integer): integer, string
  local ran = ChildPolicy.under(at.probe, { isolate = { "proc" }, promises = { "fork" },
    grants = { { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" } },
    limits = { processes = limit } }, at.work,
    "start-count " .. tostring(wanted) .. " " .. at.probe .. " sleep-forever")
  if ran == nil then return -1, "" end
  assert(ran.code == 0, ran.said)
  local count, rest = ran.said:match("^started (%d+)(.*)\n$")
  assert(count ~= nil, ran.said)
  return assert(math.tointeger(tonumber(count))), rest
end

local function test_processes_holds_the_whole_sandbox_to_a_count(tmp: string)
  local at = ChildPolicy.placed(tmp)
  local limit = 6
  local count, rest = started_under(at, limit, 20)
  if count < 0 then return end
  -- The program is one of the processes counted; the sandbox's init is
  -- another where it is in the same user namespace, which it is not for a
  -- root caller's program, which makes one of its own beneath.
  assert(count >= limit - 2 and count <= limit - 1, tostring(count) .. rest)
  assert(rest:find("Resource temporarily unavailable", 1, true), rest)
end

local function test_isolate_brings_a_default_count_of_4096_and_a_policy_s_own_is_exact(tmp: string)
  local at = ChildPolicy.placed(tmp)
  local grants: {Sandbox.Grant} = { { path = at.probe, letters = "rx" }, { path = at.work, letters = "r" } }
  local ran = ChildPolicy.under(at.probe, { isolate = { "proc" }, grants = grants }, at.work, "rlimit nproc")
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
  local given = ChildPolicy.under(at.probe, { isolate = { "file" }, grants = grants, limits = { processes = 77 } },
    at.work, "rlimit nproc")
  if given == nil then return end
  if kernel_counts() then
    assert(given.code == 0 and given.said == "nproc 77 77\n", given.said)
  end
  -- None without isolation: the caller's own.
  local none = ChildPolicy.under(at.probe, { grants = grants }, at.work, "rlimit nproc")
  if none == nil then return end
  assert(none.code == 0 and tonumber(none.said:match("^nproc (%d+)")) == assert(sys.getrlimit(sys.RLIMIT_NPROC)).soft,
    none.said)
end
