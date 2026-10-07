--- [`Sandbox.restrict`] on macOS (cosmic/sandbox/init.tl), which holds the
--- running process by a Seatbelt profile ([`Seatbelt.compile`]) applied in
--- it (core/syscalls.c's `restrict_self`). Restricting is for good, so every
--- case restricts a child of this program (`cosmic -e`, started past its
--- launcher), which prints what it could and could not do and ends; the
--- test reads that. macOS alone has Seatbelt, and no `requires` name stands
--- for it, so every case calls [`Test.skip`] on any other host, where
--- Landlock and seccomp hold the process (cosmic/sandbox_restrict_test.tl).

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
-- The child loads these from the store; cosmic.csv is the one it loads
-- only after it is restricted.
local _csv = require("cosmic.csv")
local _sandbox = require("cosmic.sandbox")
local _sqlite = require("cosmic.sqlite")
local _store = require("cosmic.store")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")

--- The program is this one, which a test starts only with `tool`; its
--- temporary directory is the test's own.
Test.policy{
  profiles = { "cosmic", "system" },
  grants = { { path = "o/bin", letters = "rx" } },
  env = { "HOME", "TMPDIR" },
}

--- What a restriction of a process a profile holds already answers.
local HELD <const> = "false sandbox: restrict: this process is held by a Seatbelt profile " ..
  "already, one it applied or was started under: macOS applies one profile to a process " ..
  "and refuses a second"

--- What a refused path answers under Seatbelt: EPERM.
local DENIED <const> = "Operation not permitted"

--- Ends the test where Seatbelt does not hold a process.
local function macos_only()
  if assert(sys.uname()).sysname ~= "Darwin" then
    Test.skip("Seatbelt holds a process on macOS alone")
  end
end

--- What the child runs first: the modules it uses, loaded before it is
--- restricted, and the helpers that report. `say(name, ...)` prints
--- `name=` and its values; `reads(path)` is what a file holds or why it
--- cannot be read.
local PRELUDE <const> = [[
local sys = require("cosmic.sys")
local Sandbox = require("cosmic.sandbox")
local Child = require("cosmic.child")
local Store = require("cosmic.store")
local function say(name, ...)
  local words = {}
  for i = 1, select("#", ...) do words[i] = tostring((select(i, ...))) end
  print(name .. "=" .. table.concat(words, " "))
end
local function reads(path)
  local fd, why = sys.open(path, sys.O_RDONLY)
  if fd == nil then return "denied: " .. why end
  local data = sys.read(fd, 100)
  sys.close(fd)
  return data
end
]]

--- What a child said: its lines, `name=value`, by name, and all of it.
local record Said
  lines: {string:string}
  raw: string
end

--- Runs `chunk`, after `PRELUDE`, in a child of this program, and answers
--- what it printed, once it has ended well.
local function in_child(chunk: string): Said
  local started = this_program.program({ "-e", PRELUDE .. chunk }, {
    env = this_program.environment(), stdout = "capture", stderr = "stdout",
    timeout_ns = Clock.seconds(60) })
  local result = assert(Child.run(started.argv, started.options))
  local said: Said = { lines = {}, raw = result.stdout or "" }
  for line in said.raw:gmatch("[^\n]+") do
    local name, value = line:match("^([%w_]+)=(.*)$")
    if name ~= nil then said.lines[name] = value end
  end
  assert(result.code == 0, "the child ended " .. tostring(result.code) .. ": " .. said.raw)
  return said
end

local function test_a_granted_file_is_read_and_another_is_refused(tmp: string)
  macos_only()
  assert(Fs.mkdirs(tmp .. "/granted") and Fs.mkdirs(tmp .. "/other"))
  assert(Fs.write(tmp .. "/granted/a", "alpha") and Fs.write(tmp .. "/other/b", "beta"))
  local said = in_child(string.format([[
say("restrict", Sandbox.restrict({ grants = { { path = %q, letters = "r" } } }))
say("granted", reads(%q))
say("other", reads(%q))
]], tmp .. "/granted", tmp .. "/granted/a", tmp .. "/other/b"))
  assert(said.lines.restrict == "true ", said.raw)
  assert(said.lines.granted == "alpha", said.raw)
  assert(said.lines.other == "denied: " .. DENIED, said.raw)
end

local function test_the_store_loads_a_module_after_the_restriction()
  macos_only()
  local said = in_child([[
say("before", package.loaded["cosmic.csv"] == nil)
say("restrict", Sandbox.restrict({}))
local loaded, csv = pcall(require, "cosmic.csv")
say("loaded", loaded, type(csv) == "table" and csv.parse("a,b")[1][2] or csv)
]])
  assert(said.lines.before == "true" and said.lines.restrict == "true ", said.raw)
  assert(said.lines.loaded == "true b", said.raw)
end

local function test_a_second_restriction_is_refused()
  macos_only()
  local said = in_child([[
say("first", Sandbox.restrict({}))
say("second", Sandbox.restrict({}))
]])
  assert(said.lines.first == "true ", said.raw)
  assert(said.lines.second == HELD, said.raw)
end

local function test_a_child_under_a_policy_is_refused_after_the_restriction()
  macos_only()
  local said = in_child([[
say("restrict", Sandbox.restrict({ profiles = { "system" } }))
local started, why = Child.start({ "/bin/cat" }, { policy = { profiles = { "system" } },
  stdin = "null" })
say("policy", started ~= nil, why)
]])
  assert(said.lines.restrict == "true ", said.raw)
  assert(said.lines.policy:find("^false ") and said.lines.policy:find(
    "this process is held by a Seatbelt profile, one it applied (Sandbox.restrict)", 1, true), said.raw)
end

--- Every refusal comes before anything is applied: each child here is
--- refused and never restricted, so a later restriction still holds, and a
--- file no grant names is still read until then.
local function test_what_cannot_be_held_is_refused_before_anything_is_applied(tmp: string)
  macos_only()
  assert(Fs.write(tmp .. "/free", "free") and Fs.write(tmp .. "/held", "held"))
  local said = in_child(string.format([[
say("nest", Sandbox.restrict({ promises = { "nest" } }))
say("free", reads(%q))
local fd = assert(sys.open(%q, sys.O_RDONLY))
say("fd", fd)
say("unnamed", Sandbox.restrict({}))
assert(sys.close(fd))
local running = assert(Child.start({ "/bin/sleep", "30" }, { process_group = false }))
say("child", Sandbox.restrict({}))
assert(running:close())
say("still", reads(%q))
]], tmp .. "/free", tmp .. "/held", tmp .. "/free"))
  assert(said.lines.nest:find("^false sandbox: restrict: promises \"nest\""), said.raw)
  assert(said.lines.free == "free" and said.lines.still == "free", said.raw)
  assert(said.lines.unnamed == "false sandbox: restrict: descriptor " .. said.lines.fd ..
      " is open and not named in fds: close it, or name it to keep it", said.raw)
  assert(said.lines.child:find("^false sandbox: restrict: this process has a child, pid %d+, not waited for"),
    said.raw)
end

local function test_a_named_descriptor_is_kept_and_its_path_is_not(tmp: string)
  macos_only()
  assert(Fs.write(tmp .. "/f", "held"))
  local said = in_child(string.format([[
local fd = assert(sys.open(%q, sys.O_RDONLY))
say("named", Sandbox.restrict({}, { fds = { fd } }))
say("through", sys.read(fd, 10))
say("after", reads(%q))
]], tmp .. "/f", tmp .. "/f"))
  assert(said.lines.named == "true ", said.raw)
  assert(said.lines.through == "held", said.raw)
  assert(said.lines.after == "denied: " .. DENIED, said.raw)
end

--- A database in WAL mode, attached and searched first, keeps its log
--- open for writing: the restriction is refused, on every platform, before
--- anything is applied, and the store still reads it.
local function test_an_attached_database_in_wal_mode_refuses_the_restriction(tmp: string)
  local said = in_child(string.format([[
local Sqlite = require("cosmic.sqlite")
local copy = %q .. "/copy.db"
local source = assert(sys.open("o/cosmic.db", sys.O_RDONLY))
local target = assert(sys.open(copy, sys.O_WRONLY | sys.O_CREAT, 420))
while true do
  local chunk = sys.read(source, 65536)
  if chunk == nil or chunk == "" then break end
  assert(sys.write(target, chunk))
end
sys.close(source) sys.close(target)
local db = assert(Sqlite.open(copy, { writable = true }))
say("mode", assert(Sqlite.text_rows(db, "PRAGMA journal_mode=WAL"))[1][1])
assert(db:close())
assert(Store.attach(copy))
say("restrict", Sandbox.restrict({}))
local loaded, csv = pcall(require, "cosmic.csv")
say("loaded", loaded, type(csv) == "table" and csv.parse("a,b")[1][2] or csv)
]], tmp))
  assert(said.lines.mode == "wal", said.raw)
  assert(said.lines.restrict:find("^false sandbox: restrict: the store's database .*copy%.db " ..
      "is in WAL mode"), said.raw)
  assert(said.lines.loaded == "true b", said.raw)
end

--- A process a policy's profile holds, started by [`Child.start`], is
--- refused a restriction before any limit of it is lowered.
local function test_a_child_under_a_policy_is_refused_a_restriction()
  macos_only()
  local chunk = [[
local sys = require("cosmic.sys")
local Sandbox = require("cosmic.sandbox")
local before = sys.getrlimit(sys.RLIMIT_NOFILE).soft
local ok, why = Sandbox.restrict({ limits = { open_files = 17 } })
print(tostring(ok) .. " " .. why)
print(sys.getrlimit(sys.RLIMIT_NOFILE).soft == before)
]]
  local result, why = Child.run({ (assert(Proc.executable())), "-e", chunk }, {
    policy = { profiles = { "cosmic", "system" } }, stdout = "capture", stderr = "capture",
    stdin = "null", timeout_ns = Clock.seconds(60) })
  assert(result, why)
  assert(result.ok and result.stdout == HELD .. "\ntrue\n",
    string.format("%q %q", result.stdout or "", result.stderr or ""))
end

--- A program started without a policy after the restriction is held by
--- the process's own profile.
local function test_a_child_started_without_a_policy_is_held_by_the_profile(tmp: string)
  macos_only()
  assert(Fs.write(tmp .. "/granted", "granted-bytes") and Fs.write(tmp .. "/other", "other-bytes"))
  local said = in_child(string.format([[
say("restrict", Sandbox.restrict({ profiles = { "system" }, promises = { "fork" },
  grants = { { path = %q, letters = "r" } } }))
local granted = Child.run({ "/bin/cat", %q }, { stdout = "capture", stderr = "capture" })
say("granted", granted and granted.ok, granted and granted.stdout)
local other = Child.run({ "/bin/cat", %q }, { stdout = "capture", stderr = "capture" })
say("other", other and other.ok, other and other.stdout, other and other.stderr)
]], tmp .. "/granted", tmp .. "/granted", tmp .. "/other"))
  assert(said.lines.restrict == "true ", said.raw)
  assert(said.lines.granted == "true granted-bytes", said.raw)
  assert(said.lines.other:find("^false ") and said.lines.other:find(DENIED, 1, true) and
      not said.lines.other:find("other-bytes", 1, true), said.raw)
end

--- A policy with no limits is given a child's defaults: 1024 open files and
--- no core dump, each only ever lowered.
local function test_a_child_s_default_limits_hold_the_process()
  macos_only()
  local said = in_child([[
local nofile = sys.getrlimit(sys.RLIMIT_NOFILE)
say("before", nofile.soft >= 1024 and nofile.hard >= 1024)
say("restrict", Sandbox.restrict({}))
nofile = sys.getrlimit(sys.RLIMIT_NOFILE)
local core = sys.getrlimit(sys.RLIMIT_CORE)
say("nofile", nofile.soft, nofile.hard)
say("core", core.soft, core.hard)
]])
  assert(said.lines.restrict == "true ", said.raw)
  if said.lines.before == "true" then
    assert(said.lines.nofile == "1024 1024", said.raw)
  end
  assert(said.lines.core == "0 0", said.raw)
end
