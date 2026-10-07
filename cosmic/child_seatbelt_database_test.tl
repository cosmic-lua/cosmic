--- A program sealed by [`Store.seal`], started by [`Child.start`] under a
--- policy whose `database` it is on macOS, where Seatbelt holds the child:
--- the profile grants the core `rx` and the database `r` and nothing of this
--- program's own file. The sealed set holds a fixture module of the test's
--- as the program's main. macOS alone has Seatbelt, so every test calls
--- [`Test.skip`] on any other host (cosmic/child_policy_database_sandboxed_test.tl
--- is Linux's).

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local fixture = require("build.child_policy_database_fixture")

--- [`Store.seal`] reads the rows of every module it carries through
--- [`Store.databases()`], which a worker without the store is not given
--- (the grant of o/cosmic.db); the core is started past its launcher (the
--- grant of o/bin). The system's own paths are what the child's core and
--- loader are read and run from.
Test.policy{
  profiles = { "cosmic", "system" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "o/cosmic.db", letters = "r" } },
  env = { "TMPDIR" },
}

--- Ends the test where Seatbelt does not hold a child.
local function macos_only()
  if assert(sys.uname()).sysname ~= "Darwin" then
    Test.skip("Seatbelt holds a child on macOS alone")
  end
end

--- What Seatbelt denied lately, as the system's log names it, which says
--- what a profile lacks. Empty where the log cannot be read.
local function denials(): string
  local result = Child.run({ "/usr/bin/log", "show", "--last", "1m", "--style", "compact",
    "--predicate", "eventMessage CONTAINS \"Sandbox: \"" },
    { stdout = "capture", stderr = "capture", stdin = "null", timeout_ns = Clock.seconds(60) })
  if result == nil then return "" end
  local lines: {string} = {}
  for line in (result.stdout or ""):gmatch("[^\n]+") do lines[#lines + 1] = line end
  return "\nlog: " .. table.concat(lines, "\n", math.max(1, #lines - 60), #lines)
end

--- The sealed program under `policy`, which names the database: what it
--- printed, as its fields; the program is told this program's own file.
local function ran_sealed(path: string, extra?: {string}): Child.Result
  local executable = assert(Proc.executable())
  local argv: {string} = { executable, executable }
  for _, word in ipairs(extra or {}) do argv[#argv + 1] = word end
  local result, why = Child.run(argv, { policy = { profiles = { "system" }, database = path },
    stdout = "capture", stderr = "capture", stdin = "null", timeout_ns = Clock.seconds(60) })
  assert(result, why)
  if not result.ok then
    assert(false, "code " .. tostring(result.code) .. ", signal " .. tostring(result.signal) ..
        ", stdout " .. string.format("%q", result.stdout or "") ..
        ", stderr " .. string.format("%q", result.stderr or "") .. denials())
  end
  return result
end

--- The child is the core on the sealed file: it runs the main the database
--- names, finds the modules sealed in it (the main itself, and what it
--- requires), none outside the set, and cannot read this program's own file.
local function test_a_sealed_database_runs_its_main_and_requires_its_modules(tmp: string)
  macos_only()
  local path = tmp .. "/sealed.db"
  fixture.seal(tmp, path)
  local out = fixture.fields(assert(ran_sealed(path).stdout))
  assert(out.main == "fixture.main", tostring(out.main))
  assert(out.context == "database-v1", tostring(out.context))
  assert(out.databases == "1", tostring(out.databases))
  assert(out.outside == "false", "a module outside the sealed set loaded")
  assert(out.own_file == "false", "this program's own file was read")
  local core = assert(sys.realpath(assert(Proc.relaunch()).argv[1]))
  assert(out.relaunch == core .. "|--database|" .. assert(sys.realpath(path)), tostring(out.relaunch))
end

--- The database is granted to read, and no more: the core opens it read-only
--- and immutable, so it needs no `-wal`, `-shm` or lock, and no file beside it.
local function test_the_child_may_read_the_database_and_write_nothing_beside_it(tmp: string)
  macos_only()
  local path = tmp .. "/sealed.db"
  fixture.seal(tmp, path)
  local before = assert(Fs.list(tmp))
  table.sort(before)
  ran_sealed(path)
  local after = assert(Fs.list(tmp))
  table.sort(after)
  assert(table.concat(after, "\n") == table.concat(before, "\n"),
    "the child left files beside the database: " .. table.concat(after, " "))
end

--- A database that is not there fails the start, naming it.
local function test_a_database_that_is_not_there_fails_the_start(tmp: string)
  macos_only()
  local executable = assert(Proc.executable())
  local result, why = Child.run({ executable, executable }, { policy = { profiles = { "system" },
    database = tmp .. "/absent.db" }, stdout = "capture", stderr = "capture" })
  assert(result == nil and why:find("absent.db", 1, true), tostring(why))
end
