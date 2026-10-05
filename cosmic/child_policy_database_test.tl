--- A program sealed by [`Store.seal`] boots: started on the core directly
--- (`core --database <path>`), and by [`Child.start`] under a policy whose
--- `database` it is, which grants the child that file and its core and
--- nothing of this program's own file. The sealed set holds a fixture
--- module of the test's, as the program's main.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sandbox = require("cosmic.sandbox")
local PolicyJson = require("cosmic.policy")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local confine = require("build.confine")
local searchable = require("build.searchable")
local this_program = require("build.this_program")

--- [`Store.seal`] reads the rows of every module it carries through
--- [`Store.databases()`], which a worker without the store is not given
--- (the grant of o/cosmic.db). The core is started past its launcher
--- (the grant of o/bin). The sealed program under `nest` builds a root of its
--- own, which a worker held by Landlock cannot ("nest"), and one test runs the
--- host's unshare and mount, which "system" gives it.
Test.policy{
  profiles = { "cosmic", "system" },
  promises = { "nest" },
  grants = {
    { path = "o/bin", letters = "rx" },
    { path = "o/cosmic.db", letters = "r" },
  },
}

local function text(value: string): Sqlite.Value
  return { text = value }
end

--- What the sealed program says of itself: its `main`, the context it
--- runs in, whether a module outside the sealed set loads, whether the
--- file named by its first argument (this program's own) reads, and the
--- command that starts it again.
local MAIN <const> = [==[
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local Child = require("cosmic.child")
local sys = require("cosmic.sys")
local function say(name, value) print(name .. "\t" .. tostring(value)) end
-- "ok" where `path` opens for writing, else the errno.
local function writes(path)
  local fd, _, errno = sys.open(path, sys.O_WRONLY)
  if fd ~= nil then sys.close(fd) return "ok" end
  return tostring(errno)
end
-- With a mode (args[2]): what it can write of its core and database, by
-- path and through its own descriptors, and then by mode: "child" starts a
-- child on that database, "relay" one with no database of its policy's
-- (so on the core and database this process runs on), "remount" runs the
-- host's unshare to remount the database writable in a user namespace of
-- its own. args[3] is a directory the root of a child is built in.
local function probe(mode, scratch)
  local core = assert(Proc.executable())
  local db = assert(Proc.relaunch()).argv[3]
  say("db_write", writes(db))
  say("core_write", writes(core))
  say("exe_write", writes("/proc/self/exe"))
  local through = 0
  for n = 0, 63 do
    local target = sys.readlink("/proc/self/fd/" .. n)
    if target == db or target == core then
      through = through + 1
      say("fd_write_" .. n, writes("/proc/self/fd/" .. n))
    end
  end
  say("fds_into_them", through)
  local function below(policy, next_mode)
    local r, why = Child.run({ core, "x", next_mode, scratch }, { policy = policy,
      stdout = "capture", stderr = "capture" })
    if r == nil then say("grand_refused", why) return end
    say("grand_code", r.code)
    say("grand_stderr", r.stderr)
    for line in r.stdout:gmatch("[^\n]+") do print("g_" .. line) end
  end
  if mode == "child" then
    below({ database = db, isolate = { "file" } }, "plain")
  elseif mode == "relay" then
    below({ isolate = { "file" }, promises = { "fork", "nest" }, set_env = { TMPDIR = scratch },
      grants = { { path = scratch, letters = "rwc" }, { path = core, letters = "rx" } } }, "plain")
  elseif mode == "remount" then
    local r, why = Child.run({ "/bin/sh", "-c",
      "unshare -Urm sh -c 'echo ns; mount -o remount,rw,bind " .. db ..
      " 2>&1; echo rc=$?' 2>&1" }, { stdout = "capture", stderr = "stdout" })
    say("remount", r == nil and ("unstarted: " .. tostring(why)) or (r.stdout:gsub("\n", " ")))
  end
end
return function(args)
  if args[2] ~= nil then probe(args[2], args[3]) end
  say("main", Store.meta("main"))
  say("context", Store.meta("runtime_context"))
  say("databases", #Store.databases())
  say("outside", (pcall(require, "cosmic.archive")))
  say("own_file", Fs.read(args[1]) ~= nil)
  say("relaunch", table.concat(assert(Proc.relaunch()).argv, "|"))
  return 0
end
]==]

local attached = false

--- Attaches a database holding `fixture.main`, which requires two modules
--- of the binary, once; a fixture module is never in the binary.
local function attach(tmp: string)
  if attached then return end
  local path = tmp .. "/fixture.db"
  local db = assert(Sqlite.open(path, { writable = true }))
  for _, statement in ipairs({
      "CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID",
      [[CREATE TABLE modules (path TEXT PRIMARY KEY NOT NULL, file TEXT NOT NULL,
      kind TEXT NOT NULL, source_hash BLOB NOT NULL, key BLOB NOT NULL,
      bytecode BLOB NOT NULL, tests TEXT NOT NULL, source BLOB NOT NULL)]],
      [[CREATE TABLE imports (path TEXT NOT NULL, requires TEXT NOT NULL,
      PRIMARY KEY (path, requires)) WITHOUT ROWID]],
  }) do
    assert(db:exec(statement))
  end
  local chunk = assert(load(MAIN, "=fixture.main"))
  assert(Sqlite.run(db, "INSERT INTO modules VALUES ('fixture.main', 'fixture.main.tl', 'main', " ..
      "X'00', X'', ?1, '', X'')", { { blob = string.dump(chunk, true) } }))
  for _, name in ipairs({ "cosmic.fs", "cosmic.proc", "cosmic.store", "cosmic.child" }) do
    assert(Sqlite.run(db, "INSERT INTO imports VALUES ('fixture.main', ?1)", { text(name) }))
  end
  assert(db:close())
  assert(Store.attach(path))
  attached = true
end

--- The program sealed at `path`: the closure of `fixture.main`.
local function seal(tmp: string, path: string): {string}
  attach(tmp)
  local names = Store.closure({ "fixture.main" })
  assert(Store.seal(names, path, { main = "fixture.main" }))
  return names
end

--- The core to start bare, or nil where this process has none to relaunch
--- (a host program, which a bare core is not).
local function core_path(): string | nil
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil then return nil end
  return relaunch.argv[1]
end

--- The program's output as the lines `name<TAB>value` it prints.
local function fields(output: string): {string:string}
  local out: {string:string} = {}
  for line in output:gmatch("([^\n]*)\n") do
    local name, value = line:match("^([^\t]+)\t(.*)$")
    if name ~= nil then out[name] = value end
  end
  return out
end

--- Whether `why`, a start's failure, is the host giving no sandbox.
local function unsandboxable(why: string): boolean
  for _, word in ipairs({ "Landlock", "seccomp", "not implemented", "namespace", "own /proc" }) do
    if why:find(word, 1, true) then return true end
  end
  return false
end

--- The core, started on the sealed file by hand, runs the main it names
--- and holds the sealed modules alone: a module the set leaves out is not
--- found, though this tree has it.
local function test_a_sealed_database_started_on_the_core_runs_its_main(tmp: string)
  local core = core_path()
  if core == nil then return end
  local path = tmp .. "/sealed.db"
  local names = seal(tmp, path)
  for _, name in ipairs(names) do
    assert(name ~= "cosmic.archive", "the fixture's set must leave cosmic.archive out")
  end
  local env = this_program.environment()
  env.COSMIC_PORTABLE_STARTUP_TEST_READY = nil
  env.COSMIC_PORTABLE_STARTUP_TEST_GO = nil
  local r = assert(Child.run({ core, "--database", path, "/nowhere" }, { env = env,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(r.ok, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  local out = fields(assert(r.stdout))
  assert(out.main == "fixture.main", tostring(out.main))
  assert(out.context == "database-v1", tostring(out.context))
  assert(out.databases == "1", tostring(out.databases))
  assert(out.outside == "false", "a module outside the sealed set loaded")
end

--- A database sealed by another core is refused by this one, naming the
--- digest: what `seal` records is the core's own.
local function test_a_database_sealed_for_another_core_does_not_start(tmp: string)
  local core = core_path()
  if core == nil then return end
  local path = tmp .. "/sealed.db"
  seal(tmp, path)
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(Sqlite.run(db, "UPDATE meta SET value = ?1 WHERE key = 'core_sha256'",
    { text(string.rep("0", 64)) }))
  assert(db:close())
  local env = this_program.environment()
  env.COSMIC_PORTABLE_STARTUP_TEST_READY = nil
  env.COSMIC_PORTABLE_STARTUP_TEST_GO = nil
  local r = assert(Child.run({ core, "--database", path }, { env = env,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(not r.ok and tostring(r.stderr):find("core_sha256", 1, true), tostring(r.stderr))
end

--- Under a policy the program is the core and the file the policy names:
--- the child runs the sealed main, finds no module outside the set, cannot
--- read this program's own file, and starts again as the same core on the
--- same database.
local function test_a_policy_runs_a_sealed_database_under_a_sandbox(tmp: string)
  if not confine.sandbox_platform() or core_path() == nil then return end
  local path = tmp .. "/sealed.db"
  seal(tmp, path)
  local executable = assert(Proc.executable())
  local result, why = Child.run({ executable, executable }, { policy = { database = path },
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  if result == nil then
    assert(unsandboxable(why), "the start was refused: " .. why)
    Test.skip(why)
    return
  end
  assert(result.ok, "exit " .. tostring(result.code) .. ": " .. tostring(result.stderr))
  local out = fields(assert(result.stdout))
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
  if not confine.sandbox_platform() or core_path() == nil then return end
  local path = tmp .. "/sealed.db"
  seal(tmp, path)
  local executable = assert(Proc.executable())
  local other, why = Child.start({ "/bin/sh", "-c", "true" }, { policy = { database = path } })
  assert(other == nil and why:find("is not this program", 1, true), tostring(why))
  local file, file_why = Child.start({ executable, "x" }, { policy = { database = path,
    grants = { { path = executable, letters = "r" } } } })
  assert(file == nil and file_why:find("own file", 1, true), tostring(file_why))
  local above, above_why = Child.start({ executable, "x" }, { policy = { database = path,
    grants = { { path = assert(executable:match("^(.*)/[^/]+$")), letters = "r" } } } })
  assert(above == nil and above_why:find("own file", 1, true), tostring(above_why))
  -- The profile that grants the program's file is left out beside a
  -- database, so it refuses nothing.
  local profiled, profile_why = Child.run({ executable, executable },
    { policy = { database = path, profiles = { "cosmic" } }, stdout = "capture",
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
  if not confine.sandbox_platform() or core_path() == nil then return end
  local path = tmp .. "/sealed.db"
  seal(tmp, path)
  local merged = assert(Sandbox.merge({ database = path }))
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
  seal(tmp, path)
  assert(Fs.chmod(path, tonumber("666", 8)))
  -- Where a start of the child's own builds the root it makes.
  searchable.open(tmp)
  local scratch = tmp .. "/scratch"
  assert(Fs.mkdirs(scratch))
  searchable.share(scratch)
  policy.database = policy.database or path
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
  return fields(assert(result.stdout))
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
  if not confine.sandbox_platform() or core_path() == nil then return end
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
  if not confine.sandbox_platform() or core_path() == nil then return end
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
  if not confine.sandbox_platform() or core_path() == nil then return end
  local path = tmp .. "/sealed.db"
  local out = under_nest(tmp, "child", { grants = { { path = path, letters = "rwc" } } })
  if out == nil then return end
  assert_unwritable(out, "")
  assert_unwritable(out, "g_")
end

--- Remounting the database writable fails in a user namespace the child makes
--- of its own: the bind is read-only, and the kernel locks that for a mount
--- seen from a namespace below its owner's. Skipped where the host has no
--- unshare to try it with.
local function test_a_nest_child_cannot_remount_the_database_writable(tmp: string)
  if not confine.sandbox_platform() or core_path() == nil then return end
  local out = under_nest(tmp, "remount", { profiles = { "system" } })
  if out == nil then return end
  local said = tostring(out.remount)
  if not said:find("ns", 1, true) then
    Test.skip("unshare -Urm made no namespace: " .. said)
    return
  end
  assert(said:find("rc=", 1, true) and not said:find("rc=0", 1, true),
    "the database was remounted writable: " .. said)
end
