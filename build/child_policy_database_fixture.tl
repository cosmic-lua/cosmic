--- What the tests of a sealed program (cosmic/child_policy_database_test.tl
--- and cosmic/child_policy_database_sandboxed_test.tl) share: a database
--- sealed by [`Store.seal`] whose main is a fixture module of the test's, and
--- the reading of what that program prints.

local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Proc = require("cosmic.proc")

local record child_policy_database_fixture
end

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
--- @param tmp the test's directory
--- @param path where the sealed database is written
--- @return the names of the modules it holds
function child_policy_database_fixture.seal(tmp: string, path: string): {string}
  attach(tmp)
  local names = Store.closure({ "fixture.main" })
  assert(Store.seal(names, path, { main = "fixture.main" }))
  return names
end

--- The core to start bare, or nil where this process has none to relaunch
--- (a host program, which a bare core is not).
--- @return the core's path, or nil where this process has none to relaunch
function child_policy_database_fixture.core_path(): string | nil
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil then return nil end
  return relaunch.argv[1]
end

--- The program's output as the lines `name<TAB>value` it prints.
--- @param output what the program printed
--- @return its fields by name
function child_policy_database_fixture.fields(output: string): {string:string}
  local out: {string:string} = {}
  for line in output:gmatch("([^\n]*)\n") do
    local name, value = line:match("^([^\t]+)\t(.*)$")
    if name ~= nil then out[name] = value end
  end
  return out
end

return child_policy_database_fixture
