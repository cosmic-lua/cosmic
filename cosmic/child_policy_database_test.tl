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
local this_program = require("build.this_program")

--- [`Store.seal`] reads the rows of every module it carries through
--- [`Store.databases()`], which a worker without the store is not given
--- (the grant of o/cosmic.db). The core is started past its launcher
--- (the grant of o/bin).
Test.policy{
  profiles = { "cosmic" },
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
local function say(name, value) print(name .. "\t" .. tostring(value)) end
return function(args)
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
  for _, name in ipairs({ "cosmic.fs", "cosmic.proc", "cosmic.store" }) do
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
