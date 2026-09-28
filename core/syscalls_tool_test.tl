--- The cases of core/syscalls_test.tl that start this very program, or
--- read it: a confined child's end with the program that started it,
--- an offline child's loopback, and the executable's own path.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local type raw_process = require("cosmic.internal.process")
local this_program = require("build.this_program")
local stand_in = require("build.stand_in")

-- TODO: declare /proc for Linux alone once a declaration can name a
-- host path per platform (a `host` entry for Linux and one for macOS):
-- macOS has no /proc, so there this declares a path that is not there,
-- which gives and keys nothing but says what the tests need wrongly.
--- What these cases are tested on: /proc, the whole environment, which
--- this program started again inherits, processes they hold, and the
--- program itself, which they start and read.
Test.needs{
  host = { "/proc" },
  env = { "*" },
  processes = true,
  tool = true,
}

local type Searcher = function(string): any, any

--- The raw table the store's searcher hands `wrapper`'s loader, as
--- `require` would hand it.
local function raw_behind(wrapper: string): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then return extra end
  end
  error(wrapper .. " is handed no raw table")
end

local process = raw_behind("cosmic.child") as raw_process -- cast: the table core/process.h declares

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

--- Whether the run holds this host to confining a process, as
--- core/syscalls_test.tl's `sandbox_required` says: without
--- COSMIC_SANDBOX=must, a case here whose sandbox the kernel refuses
--- returns early, passing unchecked, as that module's cases do.
-- TODO: count each sandbox test that returns early here as skipped, as
-- core/syscalls_test.tl's TODO on `sandbox_required` says, once
-- build/test.tl's tally has a skipped verdict.
local function sandbox_required(): boolean
  return sys.getenv("COSMIC_SANDBOX") == "must"
end

--- A stand-in program built under `tmp` (build/stand_in.tl).
local function probe_in(tmp: string): string
  return (assert(stand_in.build(tmp .. "/stand-in")))
end

--- What a confined `probe` is given to read: itself, and /proc and
--- /dev/null where this host has them.
local function probe_reads(probe: string): {string}
  local reads: {string} = { probe }
  for _, path in ipairs({ "/proc", "/dev/null" }) do
    if sys.stat(path) ~= nil then reads[#reads + 1] = path end
  end
  return reads
end

--- Opens `path` for writing, creating it, and returns the descriptor.
local function create(path: string): integer
  local fd, trouble = sys.open(path, sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420)
  assert(fd ~= nil, trouble)
  return fd
end

--- What a chunk of this program's starts a confined child with: the
--- raw process table, and the paths it reads, from `...`, colon-joined,
--- the program first.
local chunk_preamble <const> = [==[
local sys = require("cosmic.sys")
local process
for _, searcher in ipairs(package.searchers) do
  local loader, extra = searcher("cosmic.child")
  if type(loader) == "function" and type(extra) == "table" then process = extra end
end
local reads = {}
for path in (...):gmatch("[^:]+") do reads[#reads + 1] = path end
]==]

--- A confined child ends when the process that started it does, killed
--- or ended by a signal from a terminal, not left running on its own:
--- its init ends with its parent, and its namespace with the init. This
--- process takes the orphans, as a subreaper, so no one but the kernel
--- ends them: `cosmic test`'s runner, a subreaper itself, would end any
--- that reached it as strays, and pass this with the init's end undone.
local function test_a_confined_child_ends_with_its_parent(tmp: string)
  local probe = probe_in(tmp)
  local adopting = process.subreaper()
  if not adopting then return end -- no subreaper to be (not Linux)
  local report = create(tmp .. "/parent")
  local started = this_program.program({ "-e", chunk_preamble .. [==[
local pid, trouble = process.spawn(reads[1], { reads[1], "sleep 30000" }, nil, "/", nil,
  nil, nil, false, nil, { unveil = { reads = reads }, offline = true })
print(pid or "refused " .. trouble)
sys.nanosleep(30 * 1000000000)
]==], table.concat(probe_reads(probe), ":") })
  local parent = assert(process.spawn(started.argv[1], started.argv, started.options.env, tmp,
    nil, report, report, false,
    spawn_fds(started)))
  local said = ""
  local by = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) + 30 * 1000000000
  while not said:find("\n") and assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) < by do
    assert(sys.nanosleep(10 * 1000000))
    said = assert(sys.pread(report, 4096, 0))
  end
  sys.close(report)
  assert(sys.kill(parent, sys.SIGKILL))
  assert(process.waitpid(parent, false))
  if said:find("^refused ") then
    assert(not sandbox_required(), "COSMIC_SANDBOX=must, but: " .. said)
    return
  end
  local child = assert(math.tointeger(tonumber(said:match("^(%d+)\n"))), said)
  -- This process adopted it: it ends by the kernel's SIGKILL, its
  -- namespace's end, within seconds, where it would sleep on for 30.
  local ended: raw_process.ChildStatus | nil = nil
  by = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) + 5 * 1000000000
  while ended == nil and assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) < by do
    local status = assert(process.waitpid(child, true))
    if status.pid == child then ended = status else assert(sys.nanosleep(10 * 1000000)) end
  end
  if ended == nil then assert(sys.kill(child, sys.SIGKILL)) end
  -- The rest it adopted: the init, ended with its parent.
  by = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) + 5 * 1000000000
  while assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) < by do
    local status = process.waitpid(-1, true)
    if status == nil then break end
    if status.pid == 0 then assert(sys.nanosleep(10 * 1000000)) end
  end
  assert(ended ~= nil, "the confined child outlived its parent")
  assert(ended.signal == sys.SIGKILL, "ended by " .. tostring(ended.signal))
end

--- An offline child's loopback is up, as a host's is: the kernel gives
--- lo its 127.0.0.1 only when lo comes up, so the child's own routing
--- table (/proc/self/net is the reader's network namespace) holds that
--- address as a local route. The child is this program, reading it.
-- TODO: connect to a closed port of 127.0.0.1 and hold the child to
-- ECONNREFUSED, not ENETUNREACH, once cosmic.sys can open a socket or
-- core/http.c answers a failed request with CURLINFO_OS_ERRNO: curl's own
-- message words the two alike.
local function test_an_offline_child_s_loopback_is_up(tmp: string)
  local report = create(tmp .. "/report")
  local started = this_program.program({ "-e",
    "local t = assert(require('cosmic.fs').read('/proc/self/net/fib_trie')) " ..
    "print(t:find('127.0.0.1', 1, true) and 'up' or 'down')" })
  local pid, trouble, errno = process.spawn(started.argv[1], started.argv, started.options.env,
    tmp, nil, report, report, false,
    spawn_fds(started),
    { offline = true })
  if pid == nil then
    sys.close(report)
    assert(not sandbox_required(), "COSMIC_SANDBOX=must, but no network namespace: " .. trouble)
    assert(errno == sys.ENOSYS or errno == sys.EPERM or errno == sys.EACCES or
      errno == sys.EINVAL or errno == sys.ENOSPC, trouble)
    return
  end
  local status = assert(process.waitpid(pid, false))
  local said = assert(sys.pread(report, 4096, 0))
  sys.close(report)
  assert(status.code == 0 and said == "up\n", said)
end

local function test_executable_is_a_file()
  local path = assert(sys.executable())
  assert(path:sub(1, 1) == "/", "the executable's path is absolute")
  assert(assert(sys.stat(path)).kind == "file")
end
