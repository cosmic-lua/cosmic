--- A confined child's session, from core/syscalls_test.tl's sandbox
--- tests: the one of them that starts a host program, setsid, to run in
--- a session of its own, and so the one that needs the system's paths.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local confine = require("build.confine")
local this_program = require("build.this_program")
local stand_in = require("build.stand_in")
local test_child = require("build.test_child")

-- TODO: start the session with cosmic once cosmic.sys carries setsid,
-- rather than the host's setsid program, and fold this module back into
-- core/syscalls_test.tl, which then needs no `system`.
--- What the session is tested on: /proc, the program itself, which it
--- starts again, and the host's setsid program, beneath the system's
--- own paths.
Test.policy{
  profiles = { "system", "cosmic", "proc" },
  grants = { { path = "o/bin", letters = "rx" } },
}

local type raw_process = require("cosmic.internal.process")
local process = require("cosmic.internal.process")

local function create(path: string): integer
  local fd, trouble = sys.open(path, sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420)
  assert(fd ~= nil, trouble)
  return fd
end

--- The descriptors [`this_program.program`] hands its child, as
--- [`process.spawn`] takes them: each a descriptor of this process, as
--- the relaunch's are, and none "capture", which only [`cosmic.child`]
--- reads.
local function spawn_fds(started: this_program.Program): {integer:integer}
  local fds: mut {integer:integer} = {}
  for number, fd in pairs(started.options.fds or {}) do
    if fd is integer then
      fds[number] = fd
    else
      error("descriptor " .. tostring(number) .. " is " .. fd .. ", which spawn cannot hand on")
    end
  end
  return fds
end

--- The setsid program where this host has one, or nil.
local function setsid_program(): string?
  for _, path in ipairs({ "/usr/bin/setsid", "/bin/setsid", "/usr/sbin/setsid" }) do
    if sys.stat(path) ~= nil then return path end
  end
  return nil
end

--- Runs the child `name` of this module, with `args` after it, in this program, in a session of
--- its own (`setsid`), in `tmp`: what it printed, or nil where the host
--- has no setsid program.
local function in_own_session(tmp: string, name: string, args: {string}): string?
  local setsid = setsid_program()
  if setsid == nil then return nil end
  local report = create(tmp .. "/session")
  local started = this_program.program(test_child.words(tmp, "core.syscalls_session_test", name, args))
  local argv: mut {string} = { setsid }
  for _, word in ipairs(started.argv) do argv[#argv + 1] = word end
  local pid = assert(process.spawn(setsid, argv, started.options.env, tmp, nil, report, report,
    false, spawn_fds(started)))
  local status = assert(process.waitpid(pid, false))
  local said = assert(sys.pread(report, 65536, 0))
  sys.close(report)
  assert(status.code == 0, said)
  return said
end

--- Reads `path` whole, or "" where it cannot be.
local function read(path: string): string
  local fd = sys.open(path, sys.O_RDONLY)
  if fd == nil then return "" end
  local text = sys.read(fd, 4096) or ""
  sys.close(fd)
  return text
end

--- The child that starts a confined child with the paths it reads, its one word, colon-joined,
--- the program first: the child's autogroup is its own session's, not its parent's.
test_child.register("autogroup", function(args: {string}): integer
  local reads: mut {string} = {}
  for path in (args[1] or ""):gmatch("[^:]+") do reads[#reads + 1] = path end
  local program = assert(reads[1])
  local before = read("/proc/self/autogroup")
  local sandbox: raw_process.Sandbox = { unveil = { reads = reads }, offline = true }
  local pid, trouble = process.spawn(program, { program,
    "append /proc/1/autogroup 19 && print init-set || print init-kept; sleep 200; " ..
      "append /proc/self/autogroup 19; cat /proc/self/autogroup" },
    nil, "/", nil, nil, nil, false, nil, sandbox)
  if pid == nil then
    print("refused " .. tostring(trouble))
    return 0
  end
  process.waitpid(pid, false)
  if before == read("/proc/self/autogroup") then print("kept") else print("changed: " .. before) end
  return 0
end)

--- A confined child's autogroup is its own session's, not its parent's:
--- the nice it sets through its init's /proc/1/autogroup, and then
--- through /proc/self/autogroup, leaves its parent's session's as it
--- was. The init's is written first, and its own a fifth of a second
--- later: without CAP_SYS_ADMIN the kernel lets autogroups be reniced
--- once a tenth of a second, the whole system over (EAGAIN). /proc/1 is
--- open to the child only where it runs as root (its init is
--- undumpable, so owned by the namespace's root), so that half is
--- checked only in a run as root -- not CI's, which runs unprivileged,
--- nor ci/run-local's, as nobody. Run in a session of this test's own,
--- so a failure changes nothing of the runner's. The child is a
--- stand-in program (build/stand_in.tl), given only itself, /proc and
--- /dev/null. Where the kernel has no autogroup, or the host no setsid
--- program, there is nothing to check.
local function test_a_confined_child_s_autogroup_is_not_its_parent_s(tmp: string)
  if sys.stat("/proc/self/autogroup") == nil then Test.skip("this kernel has no autogroup") end
  if setsid_program() == nil then Test.skip("this host has no setsid program") end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local reads: mut {string} = { probe }
  for _, path in ipairs({ "/proc", "/dev/null" }) do
    if sys.stat(path) ~= nil then reads[#reads + 1] = path end
  end
  local said = in_own_session(tmp, "autogroup", { table.concat(reads, ":") })
  if said == nil or said:find("^refused ") ~= nil then return end
  -- It set its own, where its /proc is its own and so writable, and, as
  -- root, its init's.
  assert(said:find("kept\n$") ~= nil, said)
  local own = confine.own_proc_given()
  assert(not own or said:find(" nice 19\n", 1, true) ~= nil, said)
  assert(not own or sys.getuid() ~= 0 or said:find("init-set\n", 1, true) ~= nil, said)
end
