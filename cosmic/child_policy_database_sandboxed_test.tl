--- A program sealed by [`Store.seal`] under a sandbox: started by
--- [`Child.start`] under a policy whose `database` it is, which grants the
--- child that file and its core and nothing of this program's own file, and
--- under `nest`, where it starts children of its own on the same database.
--- The sealed set holds a fixture module of the test's, as the program's
--- main. They need a sandbox the host gives (`requires`): where the platform
--- has none they are not applicable, and where this host refuses one the
--- test skips (Test.skip). The program started on the core directly, which
--- needs none, is in cosmic/child_policy_database_test.tl.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sandbox = require("cosmic.sandbox")
local PolicyJson = require("cosmic.policy")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local fixture = require("build.child_policy_database_fixture")
local searchable = require("build.searchable")

--- [`Store.seal`] reads the rows of every module it carries through
--- [`Store.databases()`], which a worker without the store is not given
--- (the grant of o/cosmic.db). The core is started past its launcher
--- (the grant of o/bin). The sealed program under `nest` builds a root of its
--- own, which a worker held by Landlock cannot ("nest").
-- TODO: declare `relaunch` and drop the `core_path() == nil` returns of
-- these tests once build/host_requires.tl has the name (its own TODO): a
-- host program, which has no core to start bare, is not told apart from a
-- failure to reopen the program until Proc.relaunch can say which.
Test.policy{
  profiles = { "cosmic" },
  promises = { "nest" },
  grants = {
    { path = "o/bin", letters = "rx" },
    { path = "o/cosmic.db", letters = "r" },
  },
  requires = { "sandbox" },
}

--- Whether `why`, a start's failure, is the host giving no sandbox.
local function unsandboxable(why: string): boolean
  for _, word in ipairs({ "Landlock", "seccomp", "not implemented", "namespace", "own /proc" }) do
    if why:find(word, 1, true) then return true end
  end
  return false
end

--- Ends the test where a host that gives the sandbox refuses a namespace of
--- its own, or the write of its ids (AppArmor's restriction): `errno` is
--- "ok" or what the step answered. Any other failure fails the test.
local function refuse_or_skip(what: string, errno: string)
  if errno == "ok" then return end
  if errno == tostring(sys.EPERM) or errno == tostring(sys.EACCES) then
    Test.skip(what .. " was refused here (errno " .. errno .. ")")
  end
  assert(false, what .. " failed: " .. errno)
end

--- Under a policy the program is the core and the file the policy names:
--- the child runs the sealed main, finds no module outside the set, cannot
--- read this program's own file, and starts again as the same core on the
--- same database.
local function test_a_policy_runs_a_sealed_database_under_a_sandbox(tmp: string)
  if fixture.core_path() == nil then
    Test.skip("there is no core of this program to give a database")
    return
  end
  local path = tmp .. "/sealed.db"
  fixture.seal(tmp, path)
  local executable = assert(Proc.executable())
  local result, why = Child.run({ executable, executable }, { policy = { database = { path = path } },
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  if result == nil then
    assert(unsandboxable(why), "the start was refused: " .. why)
    Test.skip(why)
    return
  end
  assert(result.ok, "exit " .. tostring(result.code) .. ": " .. tostring(result.stderr))
  local out = fixture.fields(assert(result.stdout))
  assert(out.main == "fixture.main", tostring(out.main))
  assert(out.outside == "false", "a module outside the sealed set loaded")
  assert(out.own_file == "false", "the child read this program's own file")
  local real = assert(out.relaunch):match("^[^|]+|%-%-database|(.*)$")
  assert(real ~= nil and real:sub(-#"/sealed.db") == "/sealed.db", tostring(out.relaunch))
end

--- Only this program runs on a database: another one is refused before
--- anything starts, as is a grant that reaches this program's own file,
--- which holds modules the database leaves out.
local function test_a_database_policy_refuses_another_program_and_this_ones_own_file(tmp: string)
  if fixture.core_path() == nil then
    Test.skip("there is no core of this program to give a database")
    return
  end
  local path = tmp .. "/sealed.db"
  fixture.seal(tmp, path)
  local executable = assert(Proc.executable())
  local other, why = Child.start({ "/bin/sh", "-c", "true" }, { policy = { database = { path = path } } })
  assert(other == nil and why:find("is not this program", 1, true), tostring(why))
  local file, file_why = Child.start({ executable, "x" }, { policy = { database = { path = path },
    grants = { { path = executable, letters = "r" } } } })
  assert(file == nil and file_why:find("own file", 1, true), tostring(file_why))
  local above, above_why = Child.start({ executable, "x" }, { policy = { database = { path = path },
    grants = { { path = assert(executable:match("^(.*)/[^/]+$")), letters = "r" } } } })
  assert(above == nil and above_why:find("own file", 1, true), tostring(above_why))
  -- The profile that grants the program's file is left out beside a
  -- database, so it refuses nothing.
  local profiled, profile_why = Child.run({ executable, executable },
    { policy = { database = { path = path }, profiles = { "cosmic" } }, stdout = "capture",
      stderr = "capture", timeout_ns = Clock.seconds(30) })
  if profiled == nil then
    assert(unsandboxable(profile_why), tostring(profile_why))
  else
    assert(profiled.ok, tostring(profiled.stderr))
  end
end

--- A policy decoded from text names the database by its digest, and the
--- start holds the file to it: one changed since the text was read is
--- refused, not run.
local function test_a_decoded_policy_refuses_a_database_that_changed_since(tmp: string)
  if fixture.core_path() == nil then
    Test.skip("there is no core of this program to give a database")
    return
  end
  local path = tmp .. "/sealed.db"
  fixture.seal(tmp, path)
  local merged = assert(Sandbox.merge({ database = { path = path } }))
  local policy = assert(PolicyJson.decode(PolicyJson.encode(merged)))
  local executable = assert(Proc.executable())
  local bytes = assert(Fs.read(path))
  assert(Fs.write(path, bytes .. "x"))
  local started, why = Child.start({ executable, executable }, { policy = policy })
  assert(started == nil and why:find("has changed since", 1, true), tostring(why))
end

--- A sealed program run under `nest` by `mode` (see the probe in `MAIN`) with
--- `policy` beside the database: what it printed, or nil where the host gives
--- no sandbox (skipped). The database is writable by anyone, so that only the
--- mount can refuse a write, whoever the program runs as.
local function under_nest(tmp: string, mode: string, policy: Sandbox.Policy): {string:string} | nil
  local path = tmp .. "/sealed.db"
  fixture.seal(tmp, path)
  assert(Fs.chmod(path, tonumber("666", 8)))
  -- Where a start of the child's own builds the root it makes.
  searchable.open(tmp)
  local scratch = tmp .. "/scratch"
  assert(Fs.mkdirs(scratch))
  searchable.share(scratch)
  policy.database = policy.database or { path = path }
  policy.isolate = { "file" }
  policy.promises = { "fork", "nest" }
  policy.set_env = { TMPDIR = scratch }
  policy.grants = policy.grants or {}
  table.insert(policy.grants, { path = scratch, letters = "rwc" })
  local executable = assert(Proc.executable())
  local result, why = Child.run({ executable, executable, mode, scratch },
    { policy = policy, cwd = tmp, stdout = "capture", stderr = "capture",
      timeout_ns = Clock.seconds(60) })
  if result == nil then
    assert(unsandboxable(why), "the start was refused: " .. why)
    Test.skip(why)
    return nil
  end
  assert(result.ok, "exit " .. tostring(result.code) .. ": " .. tostring(result.stderr))
  return fixture.fields(assert(result.stdout))
end

--- EROFS: what a write to a read-only mount fails with, which no permission
--- (the database is writable by anyone) can be mistaken for.
local EROFS <const> = "30"

--- What a probe in `out` (under `prefix`) found of the core and database: it
--- held descriptors into them, and none opened for writing, by path or not.
local function assert_unwritable(out: {string:string}, prefix: string)
  local held = tonumber(out[prefix .. "fds_into_them"])
  assert(held ~= nil and held > 0, prefix .. "the probe found no descriptor of the core or database")
  assert(out[prefix .. "db_write"] == EROFS, prefix .. "db: " .. tostring(out[prefix .. "db_write"]))
  assert(out[prefix .. "core_write"] ~= "ok", prefix .. "core opened for writing")
  assert(out[prefix .. "exe_write"] ~= "ok", prefix .. "/proc/self/exe opened for writing")
  for name, value in pairs(out) do
    if name:sub(1, #prefix + 9) == prefix .. "fd_write_" then
      assert(value ~= "ok", name .. ": a descriptor of the core or database reopened for writing")
    end
  end
end

--- A sealed program under `nest` holds a core and a database that it can
--- start children on and cannot write, by path or through /proc/self/fd:
--- the child confines a grandchild on the same database, which runs the
--- sealed main, and neither writes either file.
local function test_a_sealed_program_under_nest_confines_children_of_its_own(tmp: string)
  if fixture.core_path() == nil then
    Test.skip("there is no core of this program to give a database")
    return
  end
  local out = under_nest(tmp, "child", {})
  if out == nil then return end
  assert(out.main == "fixture.main", tostring(out.main))
  assert(out.own_file == "false", "the child read this program's own file")
  assert(out.grand_refused == nil, tostring(out.grand_refused))
  -- The grandchild is the sealed main again, on the same database.
  assert(out.grand_code == "0", tostring(out.grand_code) .. ": " .. tostring(out.grand_stderr))
  assert(out.g_main == "fixture.main", tostring(out.g_main))
  assert(out.g_outside == "false", "a module outside the sealed set loaded in the grandchild")
  assert(out.g_relaunch ~= nil and out.g_relaunch:find("|--database|", 1, true),
    tostring(out.g_relaunch))
  assert_unwritable(out, "")
  assert_unwritable(out, "g_")
end

--- A process started on a database, whatever its policy named, takes the
--- `nest` promise for a child of its own that names no `database`: the child
--- is on this process's core and database, bound read-only all the same.
local function test_a_sealed_program_under_nest_starts_a_nest_child_with_no_database(tmp: string)
  if fixture.core_path() == nil then
    Test.skip("there is no core of this program to give a database")
    return
  end
  local out = under_nest(tmp, "relay", {})
  if out == nil then return end
  assert(out.grand_refused == nil, tostring(out.grand_refused))
  assert(out.grand_code == "0", tostring(out.grand_code) .. ": " .. tostring(out.grand_stderr))
  assert(out.g_main == "fixture.main", tostring(out.g_main))
  assert_unwritable(out, "")
  assert_unwritable(out, "g_")
end

--- A policy's own grant of the database, writable, is one of the root's
--- binds like the program's: the read-only bind of the database the program
--- is given, which comes after, is the one the child sees.
local function test_a_policy_grant_of_the_database_does_not_make_it_writable(tmp: string)
  if fixture.core_path() == nil then
    Test.skip("there is no core of this program to give a database")
    return
  end
  local path = tmp .. "/sealed.db"
  local out = under_nest(tmp, "child", { grants = { { path = path, letters = "rwc" } } })
  if out == nil then return end
  assert_unwritable(out, "")
  assert_unwritable(out, "g_")
end

--- Remounting the database writable fails in a user namespace the child makes
--- of its own: the bind is read-only, and the kernel locks that for a mount
--- seen from a namespace below its owner's.
local function test_a_nest_child_cannot_remount_the_database_writable(tmp: string)
  if fixture.core_path() == nil then
    Test.skip("there is no core of this program to give a database")
    return
  end
  local out = under_nest(tmp, "remount", {})
  if out == nil then return end
  refuse_or_skip("unshare of a user and mount namespace", out.unshare)
  refuse_or_skip("the write of its ids", out.mapped)
  assert(out.remount == tostring(sys.EPERM), "the database was remounted writable: " ..
      tostring(out.remount) .. " " .. tostring(out.remount_why))
end
