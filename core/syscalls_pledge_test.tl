--- The raw process table's `pledge` (core/process.h's [`Sandbox.pledge`]) on
--- a live child: the seccomp filter it holds a child and what it starts
--- to, as core/syscalls_test.tl states the rest of the table. They need a
--- kernel that gives a seccomp filter, which Linux alone does: where the
--- platform has none the refusal is core/syscalls_test.tl's, and where this
--- Linux host refuses it the tests are not run (`requires`) or, where only
--- the call can tell, skipped (Test.skip).

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local unix_socket = require("build.unix_socket")
local type raw_process = require("cosmic.internal.process")
local stand_in = require("build.stand_in")
-- Required, so the module whose loader is handed the raw table is of this
-- test's import closure, and the store has it to hand it from.
local type _ = require("cosmic.child")

--- /proc, which the first test reads for its own filter, and loopback, as
--- core/syscalls_test.tl declares them.
-- These tests need a seccomp filter alone, which `sandbox` asks for with
-- more (core/promises_system_test.tl's TODO names the narrower requirement).
Test.policy{
  profiles = { "proc" },
  loopback = { "127.0.0.1" },
  requires = { "sandbox" },
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

--- A stand-in program built under `tmp` (build/stand_in.tl), which runs
--- the script its first argument holds: a static executable that reads
--- only itself, so one confined needs nothing of the system's own.
local function probe_in(tmp: string): string
  return (assert(stand_in.build(tmp .. "/stand-in")))
end

--- Opens `path` for writing, creating it, and returns the descriptor.
local function create(path: string): integer
  local fd, trouble = sys.open(path, sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420)
  assert(fd ~= nil, trouble)
  return fd
end

--- A pledged child runs under a seccomp filter, and so does what it
--- starts; an unpledged one runs as this process does (under a filter
--- of its own when a container gives it one).
local function test_a_pledge_holds_a_child_and_what_it_starts(tmp: string)
  local probe = probe_in(tmp)
  --- What the child and a grandchild of it report of their filters, with
  --- one blank for each run of space; skips the test where `sandbox` is
  --- refused, as the kernel gives no such pledge.
  local function filtered(sandbox: raw_process.Sandbox | nil): string
    local output = create(tmp .. "/status")
    local pid, trouble, errno = process.spawn(probe, { probe,
      "status-field Seccomp; run " .. probe .. " status-field Seccomp" },
      nil, nil, nil, output, output, false, nil, sandbox)
    if pid == nil then
      sys.close(output)
      assert(errno == sys.ENOSYS, trouble)
      Test.skip("the kernel gives no pledge: " .. tostring(trouble))
    end
    assert(assert(process.waitpid(pid, false)).code == 0)
    local said = assert(sys.pread(output, 4096, 0))
    sys.close(output)
    return (said:gsub("%s+", " "))
  end
  local status_file = assert(sys.open("/proc/self/status", sys.O_RDONLY))
  local own = assert(sys.read(status_file, 65536)):match("Seccomp:%s*(%d)")
  sys.close(status_file)
  local plain = filtered(nil)
  assert(plain == "Seccomp: " .. own .. " Seccomp: " .. own .. " ", plain)
  assert(filtered({ pledge = {} }) == "Seccomp: 2 Seccomp: 2 ")
  assert(filtered({ pledge = { "unix", "inet" } }) == "Seccomp: 2 Seccomp: 2 ")
end

--- A socket of a family not promised is refused (EPERM), where one promised
--- is made and then refused its connection: a unix connect to a path that is
--- not there says so only with "unix" promised.
local function test_a_pledge_without_unix_refuses_a_unix_connect(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local probe = probe_in(tmp)
  local function connected(promises: {string}): string
    local output = create(tmp .. "/connect")
    local pid, trouble = process.spawn(probe, { probe, "connect " .. tmp .. "/none.sock" },
      nil, nil, nil, output, output, false, nil, { pledge = promises })
    if pid == nil then
      sys.close(output)
      Test.skip("the kernel gives no pledge: " .. tostring(trouble))
    end
    assert(assert(process.waitpid(pid, false)).code == 0)
    local said = assert(sys.pread(output, 4096, 0))
    sys.close(output)
    return said
  end
  local socket = tmp .. "/none.sock: "
  local unpromised = connected({})
  assert(unpromised == socket .. "Operation not permitted\n", unpromised)
  local promised = connected({ "unix" })
  assert(promised == socket .. "No such file or directory\n", promised)
end
