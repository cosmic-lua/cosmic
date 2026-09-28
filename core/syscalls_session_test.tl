--- A confined child's session, from core/syscalls_test.tl's sandbox
--- tests: the one of them that starts a host program, setsid, to run in
--- a session of its own, and so the one that needs the system's paths.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local confine = require("build.confine")
local this_program = require("build.this_program")
local stand_in = require("build.stand_in")

-- TODO: start the session with cosmic once cosmic.sys carries setsid,
-- rather than the host's setsid program, and fold this module back into
-- core/syscalls_test.tl, which then needs no `system`.
--- What the session is tested on: /proc, the whole environment, which
--- this program started again inherits, the program itself, whose core
--- the confined stand-in is built from, and the host's setsid program,
--- beneath the system's own paths.
Test.needs{
  host = { "/proc" },
  env = { "*" },
  tool = true,
  system = true,
}

local type raw_process = require("cosmic.internal.process")
local type Searcher = function(string): any, any

--- The raw process table `require` hands `cosmic.child`'s loader.
local function raw_behind_child(): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then return extra end
  end
  error("cosmic.child is handed no raw table")
end

local process = raw_behind_child() as raw_process -- cast: the table core/process.h declares

local function create(path: string): integer
  local fd, trouble = sys.open(path, sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420)
  assert(fd ~= nil, trouble)
  return fd
end

--- The descriptors `this_program.program` hands its child, as
--- `process.spawn` takes them: each a descriptor of this process, as
--- the relaunch's are, and none "capture", which only `cosmic.child`
--- reads.
local function spawn_fds(started: this_program.Program): {integer:integer}
  local fds: {integer:integer} = {}
  for number, fd in pairs(started.options.fds) do
    if fd is integer then
      fds[number] = fd
    else
      error("descriptor " .. tostring(number) .. " is " .. fd .. ", which spawn cannot hand on")
    end
  end
  return fds
end

--- The setsid program where this host has one, or nil.
local function setsid_program(): string | nil
  for _, path in ipairs({ "/usr/bin/setsid", "/bin/setsid", "/usr/sbin/setsid" }) do
    if sys.stat(path) ~= nil then return path end
  end
  return nil
end

--- Runs `chunk`, with `...` after it, in this program, in a session of
--- its own (`setsid`), in `tmp`: what it printed, or nil where the host
--- has no setsid program.
local function in_own_session(tmp: string, chunk: string, ...: string): string | nil
  local setsid = setsid_program()
  if setsid == nil then return nil end
  local report = create(tmp .. "/session")
  local args: {string} = { "-e", chunk }
  for _, word in ipairs({ ... }) do args[#args + 1] = word end
  local started = this_program.program(args)
  local argv: {string} = { setsid }
  for _, word in ipairs(started.argv) do argv[#argv + 1] = word end
  local pid = assert(process.spawn(setsid, argv, started.options.env, tmp, nil, report, report,
    false, spawn_fds(started)))
  local status = assert(process.waitpid(pid, false))
  local said = assert(sys.pread(report, 65536, 0))
  sys.close(report)
  assert(status.code == 0, said)
  return said
end

--- What a chunk run by `in_own_session` starts a confined child with:
--- the raw process table, and the paths it reads, from `...`,
--- colon-joined, the program first.
local session_preamble <const> = [==[
local sys = require("cosmic.sys")
local process
for _, searcher in ipairs(package.searchers) do
  local loader, extra = searcher("cosmic.child")
  if type(loader) == "function" and type(extra) == "table" then process = extra end
end
local reads = {}
for path in (...):gmatch("[^:]+") do reads[#reads + 1] = path end
local function read(path)
  local fd = sys.open(path, sys.O_RDONLY)
  if fd == nil then return "" end
  local text = sys.read(fd, 4096) or ""
  sys.close(fd)
  return text
end
]==]

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
  if sys.stat("/proc/self/autogroup") == nil or setsid_program() == nil then return end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local reads: {string} = { probe }
  for _, path in ipairs({ "/proc", "/dev/null" }) do
    if sys.stat(path) ~= nil then reads[#reads + 1] = path end
  end
  local said = in_own_session(tmp, session_preamble .. [==[
local before = read("/proc/self/autogroup")
local pid, trouble = process.spawn(reads[1], { reads[1],
  "append /proc/1/autogroup 19 && print init-set || print init-kept; sleep 200; " ..
  "append /proc/self/autogroup 19; cat /proc/self/autogroup" },
  nil, "/", nil, nil, nil, false, nil, { unveil = { reads = reads }, offline = true })
if pid == nil then print("refused " .. trouble) return 0 end
process.waitpid(pid, false)
print(before == read("/proc/self/autogroup") and "kept" or "changed: " .. before)
return 0
]==], table.concat(reads, ":"))
  if said == nil or said:find("^refused ") then return end
  -- It set its own, where its /proc is its own and so writable, and, as
  -- root, its init's.
  assert(said:find("kept\n$") ~= nil, said)
  local own = confine.own_proc_given()
  assert(not own or said:find(" nice 19\n", 1, true) ~= nil, said)
  assert(not own or sys.getuid() ~= 0 or said:find("init-set\n", 1, true) ~= nil, said)
end
