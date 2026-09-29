--- A recording of what a test was refused (build.refusals): each read
--- that failed as a sandbox fails one it does not show, noted where it
--- names; a listing, a read of the store and a database opened, whatever
--- each answered; a variable not set; a program that could not start,
--- and the interpreter its first line names -- and nothing that was
--- read.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local refusals = require("build.refusals")
local sys = require("cosmic.sys")
local type observations = require("build.filesystem_observations")

--- The variable the recording is to find unset, declared so no audit
--- names its read: declared and unset, the key holds that it is unset;
--- and the loopback a request is sent to, which no server answers.
Test.needs{ env = { "COSMIC_REFUSALS_TEST_UNSET" }, network = { "127.0.0.1" } }

--- Whether `found` holds an observation of `kind` of `path`.
local function holds(found: {observations.Observation}, kind: string, path: string): boolean
  for _, each in ipairs(found) do
    if each.kind == kind and each.path == path then return true end
  end
  return false
end

local function test_a_refused_read_is_noted_and_a_read_is_not(tmp: string)
  local store = tmp .. "/o/cosmic.db"
  assert(Fs.write(tmp .. "/here.txt", "here\n"))
  local open, stat = sys.open, sys.stat
  -- The test's own directory stands for the tree.
  local recording = refusals.start(tmp)
  assert(sys.open ~= open and sys.stat ~= stat, "the recording stands in for the calls")
  assert(Fs.read(tmp .. "/here.txt") == "here\n")
  assert(Fs.read(tmp .. "/missing.txt") == nil)
  assert(sys.stat(tmp .. "/here.txt/beneath") == nil)
  assert(sys.lstat(tmp .. "/gone") == nil)
  assert(not sys.access(tmp .. "/gone too", 0))
  -- A listing, whatever it answers; the store, whatever it answers.
  assert(sys.readdir(tmp) ~= nil)
  -- One outside the tree, which a sandbox gives whole or not at all.
  local _, _ = sys.readdir("/")
  assert(Fs.mkdirs(tmp .. "/o"))
  assert(Fs.write(store, ""))
  assert(sys.stat(store) ~= nil)
  assert(sys.stat(store) ~= nil)
  -- Relative, where it names from the working directory.
  local here = assert(sys.getcwd())
  assert(sys.stat("refusals-test-not-there") == nil)
  -- A variable not set, and one set.
  assert(Env.get("COSMIC_REFUSALS_TEST_UNSET") == nil)
  local found = recording.stop()
  assert(sys.open == open and sys.stat == stat, "stopped, the calls are put back")
  assert(not holds(found, "o", tmp .. "/here.txt"), "a read that found its file is none")
  assert(holds(found, "o", tmp .. "/missing.txt"))
  assert(holds(found, "s", tmp .. "/here.txt/beneath"))
  assert(holds(found, "l", tmp .. "/gone"))
  assert(holds(found, "s", tmp .. "/gone too"))
  assert(holds(found, "d", tmp))
  assert(not holds(found, "d", "/"), "a listing outside the tree is none")
  assert(holds(found, "s", store))
  local stores = 0
  for _, each in ipairs(found) do
    if each.kind == "s" and each.path == store then stores = stores + 1 end
  end
  assert(stores == 1, "each refusal once")
  assert(holds(found, "s", (here == "/" and "" or here) .. "/refusals-test-not-there"))
  assert(holds(found, "e", "COSMIC_REFUSALS_TEST_UNSET"))
  -- Stopped, it notes nothing more.
  assert(Fs.read(tmp .. "/after.txt") == nil)
  assert(not holds(found, "o", tmp .. "/after.txt"))
end

--- A program that could not start is noted, and so is the interpreter
--- a script's first line names, which a sandbox refuses as it refuses
--- the script.
local function test_a_start_refused_notes_the_program_and_its_interpreter(tmp: string)
  local script = tmp .. "/script"
  assert(Fs.write(script, "#!/refusals-test/interpreter\n"))
  assert(sys.chmod(script, 0x1ed))
  local recording = refusals.start(tmp)
  local ran, _ = Child.run({ script })
  local found = recording.stop()
  assert(ran == nil or not ran.ok, "a script whose interpreter is not there does not run")
  assert(holds(found, "y", script))
  assert(holds(found, "y", "/refusals-test/interpreter"))
end

--- A database `cosmic.sqlite` opens is noted, whatever it answered: it
--- is read in C, past the syscall table.
local function test_a_database_opened_is_noted(tmp: string)
  local path = tmp .. "/data.db"
  local recording = refusals.start(tmp)
  local db = assert(Sqlite.open(path, true))
  db:close()
  local found = recording.stop()
  assert(holds(found, "o", path))
end

--- A request is noted by its URL, whatever it answered, but one that
--- connects nowhere: a scripted one, or one of a scheme curl is not let
--- speak.
local function test_a_request_is_noted_unless_it_connects_nowhere(tmp: string)
  local recording = refusals.start(tmp)
  local _, _ = Http.open("http://127.0.0.1:1/refused", { timeout_ms = 2000 })
  local scripted, _ = Http.get("http://scripted.test/", {
    script = { "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" } })
  local _, _ = Http.open("ftp://127.0.0.1:1/never")
  local found = recording.stop()
  assert(scripted ~= nil and scripted.body == "ok")
  assert(holds(found, "x", "http://127.0.0.1:1/refused"))
  assert(not holds(found, "x", "http://scripted.test/"))
  assert(not holds(found, "x", "ftp://127.0.0.1:1/never"))
end

--- The calls of `cosmic.sys`, by name, as a test that hands one what
--- it refuses reaches them.
local function calls(value: any): {string:any}
  if value is {string:any} then return value end
  return {}
end

--- What `stat` raises for a missing path, and `open` for a path with
--- no flags, each a line.
local function refused_argument(): string
  local held = calls(sys)
  local stat, open = held.stat, held.open
  if not stat is function(...: any): any... or not open is function(...: any): any... then
    return "no stat or open"
  end
  local _, stat_why = pcall(function(): any
    local answer = stat()
    return answer
  end)
  local _, open_why = pcall(function(): any
    local answer = open("refusals-test-no-flags")
    return answer
  end)
  return tostring(stat_why) .. "\n" .. tostring(open_why)
end

--- A call handed what it refuses raises as it would with no recording,
--- naming itself and where it was called: a missing path, which its
--- stand-in hands on as it is, and a missing flag after a path, which it
--- records the call of.
local function test_a_refused_argument_is_named_as_without_a_recording(tmp: string)
  local without = refused_argument()
  local recording = refusals.start(tmp)
  local with = refused_argument()
  local _ = recording.stop()
  assert(with == without, with .. "\n" .. without)
  assert(without:find("refusals_test:%d+: bad argument #1 to 'stat'"), without)
  assert(without:find("refusals_test:%d+: bad argument #2 to 'open'"), without)
end
