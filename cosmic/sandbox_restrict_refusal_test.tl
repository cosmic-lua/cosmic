--- What [`Sandbox.restrict`] (cosmic/sandbox/init.tl) refuses on a live
--- process before anything holds it: a field only a child can be held to,
--- a descriptor open and not named or named and not open, a child not
--- waited for, a grant of a path that is not there. Each case restricts a
--- child of this program (build/sandbox_restrict_fixture.tl); one whose
--- every restriction is refused ends unrestricted, reporting the C it
--- entered (the checks of core/syscalls.c's `restrict_self`) to the
--- test's coverage.
--- They need no Landlock, which comes after them, and run wherever the
--- kernel lists a process's children (`requires`), which the checks read;
--- what a restriction holds is cosmic/sandbox_restrict_test.tl's.

local Fs = require("cosmic.fs")
local build_paths = require("build.paths")
local confine = require("build.confine")
-- The child loads these from the store, which holds this test's closure alone.
local _net = require("cosmic.net")
local _sandbox = require("cosmic.sandbox")
local _store = require("cosmic.store")
local Test = require("cosmic.test")
local stand_in = require("build.stand_in")
local Restrict = require("build.sandbox_restrict_fixture")

--- The program is this one, which a test starts only with `tool`; its
--- temporary directory is the test's own; and /proc, which the checks read.
Test.policy{
  profiles = { "cosmic", "proc" },
  grants = { { path = "o/bin", letters = "rx" } },
  env = { "TMPDIR" },
  requires = { "path:/proc/thread-self/children" },
}

--- A policy for each field a process cannot be held to, with the name
--- its failure gives.
--- A policy written out as the source [`Sandbox.restrict`] is called with, and the words its failure holds.
local record Refusal
  policy: string
  says: string
end

local REFUSED <const>: {Refusal} = {
  { policy = "{ isolate = { \"file\" } }", says = "isolate \"file\"" },
  { policy = "{ isolate = { \"proc\" } }", says = "isolate \"proc\"" },
  { policy = "{ connect = { \"example.com:443\" } }", says = "connect \"example.com:443\"" },
  { policy = "{ loopback = { \"127.0.0.2\" } }", says = "loopback \"127.0.0.2\"" },
  { policy = "{ promises = { \"nest\" } }", says = "promises \"nest\"" },
  { policy = "{ grants = { { path = \"/\", letters = \"ru\" } } }", says = "grant \"/\" has u" },
  { policy = "{ grants = { { path = \"/\", letters = \"r\", from = \"/srv\" } } }", says = "grant \"/\" has from" },
  { policy = "{ env = { \"HOME\" } }", says = "env \"HOME\"" },
  { policy = "{ set_env = { MODE = \"x\" } }", says = "set_env \"MODE\"" },
  { policy = "{ tmp = true }", says = "tmp is" },
  { policy = "{ limits = { processes = 4 } }", says = "limits.processes" },
  { policy = "{ user = 4294967000 }", says = "user 4294967000" },
  { policy = "{ profiles = { \"nonesuch\" } }", says = "nonesuch" },
}

--- The child of a case that restricts nothing ends unrestricted, so it
--- still reports the C it entered to the test's coverage; one that is held
--- cannot write there. These cases hold that every refusal leaves the
--- process as it was: a file no policy granted reads still, and a limit
--- set past a refusal is not set.
local function test_every_refusal_holds_nothing(tmp: string)
  assert(Fs.write(tmp .. "/free", "free") and Fs.write(tmp .. "/held", "held"))
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local lines: mut {string} = {}
  for i, case in ipairs(REFUSED) do
    lines[#lines + 1] = string.format("say(%q, Sandbox.restrict(%s))", "case" .. tostring(i), case.policy)
  end
  local said = Restrict.in_child(table.concat(lines, "\n") .. "\n" .. string.format([[
-- What the kernel's side refuses: an open descriptor, one fds names that is
-- not open, a grant of a path that is not there (after its limit is planned),
-- and a child not yet waited for.
local nofile_before = limit(sys.RLIMIT_NOFILE)
local fd = assert(sys.open(%q, sys.O_RDONLY))
say("fd", fd)
say("unnamed", Sandbox.restrict({}))
say("absent_fd", Sandbox.restrict({}, { fds = { fd, 40 } }))
assert(sys.close(fd))
say("missing", Sandbox.restrict({ grants = { { path = %q, letters = "r" } },
  limits = { cpu_seconds = 7 } }))
local running = assert(Child.start({ %q, "sleep-forever" }, { process_group = false }))
say("child", Sandbox.restrict({}))
assert(running:close())
say("cpu", limit(sys.RLIMIT_CPU):sub(1, 2) ~= "7 ")
say("nofile", limit(sys.RLIMIT_NOFILE) == nofile_before)
say("with_limits", Sandbox.restrict({ isolate = { "file" }, grants = { { path = "/", letters = "r" } },
  limits = { cpu_seconds = 9, open_files = 12 } }))
say("cpu_after", limit(sys.RLIMIT_CPU):sub(1, 2) ~= "9 ")
say("nofile_after", limit(sys.RLIMIT_NOFILE) == nofile_before)
say("free", reads(%q))
]], tmp .. "/held", tmp .. "/absent", probe, tmp .. "/free"))
  for i, case in ipairs(REFUSED) do
    local answer = said.lines["case" .. tostring(i)] or ""
    assert(answer:find("^false sandbox: ") and answer:find(case.says, 1, true),
      case.policy .. " -> " .. answer)
  end
  local fd = assert(said.lines["fd"])
  assert(said.lines["unnamed"] == "false sandbox: restrict: descriptor " .. fd ..
      " is open and not named in fds: close it, or name it to keep it", said.raw)
  assert(assert(said.lines["absent_fd"]):find("descriptor 40, which fds names, is not open", 1, true), said.raw)
  -- Its checks passed and its limit was planned, so what holds a process was
  -- asked: a ruleset refuses the grant of a path that is not there, and a
  -- kernel with no Landlock refuses the restriction itself. The child's
  -- answer is this process's, whose filter it inherits.
  local missing = assert(said.lines["missing"])
  local abi, _ = confine.landlock_abi()
  if abi ~= nil then
    assert(missing:find("^false sandbox: restrict: grant .*absent: No such file"), said.raw)
  else
    -- ENOSYS where the kernel has none built in; another errno where it is
    -- left out of lsm= or a container's filter refuses it.
    assert(missing == "false sandbox: restrict: this system cannot hold a process: it needs Landlock and " ..
        "seccomp, which only Linux gives, or Seatbelt, which macOS does" or
        missing:find("^false sandbox: restrict: Landlock is not available here") ~= nil, said.raw)
  end
  assert(assert(said.lines["child"]):find("^false sandbox: restrict: this process has a child, pid %d+, not waited for"),
    said.raw)
  assert(said.lines["cpu"] == "true" and said.lines["free"] == "free", said.raw)
  -- A refusal that comes with limits and grants sets no limit and holds nothing.
  assert(said.lines["nofile"] == "true" and said.lines["nofile_after"] == "true", said.raw)
  assert(assert(said.lines["with_limits"]):find("^false sandbox: restrict: isolate", 1) ~= nil and
      said.lines["cpu_after"] == "true", said.raw)
end

local function test_a_writable_descriptor_on_a_store_database_is_the_programs_own(tmp: string)
  local said = Restrict.in_child(string.format([[
-- A database of the store's own kind, attached: the store holds it read-only.
local original = %q
local copy = %q .. "/copy.db"
local source = assert(sys.open(original, sys.O_RDONLY))
local target = assert(sys.open(copy, sys.O_WRONLY | sys.O_CREAT, 420))
while true do
  local chunk = sys.read(source, 65536)
  if chunk == nil or chunk == "" then break end
  assert(sys.write(target, chunk))
end
sys.close(source) sys.close(target)
assert(Store.attach(copy, { unchecked_bytecode = true }))
local mine = assert(sys.open(copy, sys.O_RDWR))
say("mine", mine)
say("refused", Sandbox.restrict({}))
say("named", Sandbox.restrict({}, { fds = { mine } }))
]], build_paths.resolve(".").projection, tmp))
  assert(said.lines["refused"] == "false sandbox: restrict: descriptor " .. assert(said.lines["mine"]) ..
      " is open and not named in fds: close it, or name it to keep it", said.raw)
end

local function test_fds_names_a_descriptor_above_2()
  local said = Restrict.in_child([[
say("low", Sandbox.restrict({}, { fds = { 1 } }))
]])
  assert(assert(said.lines["low"]):find("^false sandbox: restrict: fds names 1, which is not a descriptor above 2"),
    said.raw)
end
