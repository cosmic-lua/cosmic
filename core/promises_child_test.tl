--- `spawn`'s `promises` (core/process.h) on a live child: the kernel's own
--- verdict on the filter core/promises.c builds, which core/promises_test.tl
--- can only judge against an interpreter of its own. The child is a stand-in
--- (build/stand_in.tl): this program's own static core, which starts under
--- the basics and does what its script says, so a call the filter refuses
--- shows as a command that fails, with the errno the filter answers.
--- Where the platform has no sandbox they are not applicable and where
--- this host has none they are skipped (`requires`); a container that
--- already filters more than this allows skips each itself (Test.skip).
--- The refusals of what no start could keep, which need no filter, are
--- core/promises_refused_test.tl's.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local stand_in = require("build.stand_in")
local type raw_process = require("cosmic.internal.process")
-- Required, so the module whose loader is handed the raw table is of this
-- test's import closure, and the store has it to hand it from.
local type _ = require("cosmic.child")

--- /proc: the child reads its own status for its filter.
-- These tests need a seccomp filter alone, which `sandbox` asks for with
-- more (core/promises_system_test.tl's TODO names the narrower requirement).
Test.policy{
  grants = { { path = "/proc", letters = "r" } },
  requires = { "sandbox" },
}

local type Searcher = function(string): any, any

--- The raw table the store's searcher hands `wrapper`'s loader.
local function raw_behind(wrapper: string): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then return extra end
  end
  error(wrapper .. " is handed no raw table")
end

local process = raw_behind("cosmic.child") as raw_process -- cast: the table core/process.h declares

--- What a script left on stdout and stderr, and how its program ended.
local record Outcome
  code: integer
  signal: integer
  said: string
end

--- Runs `script` in a stand-in held to `promises`, in a directory of
--- `tmp`'s: its output and how it ended. Skips the test where the kernel
--- gives no seccomp filter, which only the start can tell.
local function under(tmp: string, promises: {string}, script: string, probe?: string): Outcome
  local program = probe or assert(stand_in.build(tmp .. "/stand-in"))
  local path = tmp .. "/said"
  local output = assert(sys.open(path, sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420))
  local pid, trouble = process.spawn(program, { program, script }, nil, nil, nil, output, output,
    false, nil, { promises = promises })
  if pid == nil then
    sys.close(output)
    Test.skip("the kernel gives no seccomp filter: " .. tostring(trouble))
  end
  local status = assert(process.waitpid(pid, false))
  sys.close(output)
  return { code = status.code, signal = status.signal, said = (Fs.read(path)) or "" }
end

local PROMISE_SETS: {{string}} = {
  {}, { "fork" }, { "jit" }, { "fattr" }, { "fork", "jit", "fattr" },
}

local function test_the_static_core_runs_under_the_basics(tmp: string)
  for _, promises in ipairs(PROMISE_SETS) do
    local outcome = under(tmp, promises, "print hello; write " .. tmp .. "/f world; " ..
        "append " .. tmp .. "/f again; cat " .. tmp .. "/f; mkdirs " .. tmp .. "/d/e; " ..
        "mkfifo " .. tmp .. "/fifo; mode " .. tmp .. "/f; ls " .. tmp .. "/d; " ..
        "status-field Seccomp; status-field NoNewPrivs")
    assert(outcome.code == 0, "a core under the basics ends with " .. outcome.code .. ": " .. outcome.said)
    assert(outcome.said:find("hello\nworld\nagain\n", 1, true) == 1, outcome.said)
    assert(outcome.said:find("Seccomp:\t2\nNoNewPrivs:\t1\n", 1, true) ~= nil, outcome.said)
    assert(Fs.exists(tmp .. "/fifo"), "mknod of a fifo is a basic")
    assert(Fs.remove(tmp .. "/f") and Fs.remove(tmp .. "/fifo") and Fs.remove_tree(tmp .. "/d"))
  end
end

local function test_a_signal_to_itself_ends_it_and_to_another_is_refused(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local own = under(tmp, {}, "signal TERM", probe)
  assert(own.signal == sys.SIGTERM, "its own pid is a signal it may send: " .. own.said)
  -- Another process, one of this test's own: the filter answers EPERM, and it lives.
  local sleeper = assert(process.spawn(probe, { probe, "sleep-forever" }, nil, nil, nil, nil, nil,
    false))
  local other = under(tmp, {}, "signal KILL " .. sleeper, probe)
  assert(sys.kill(sleeper, 0), "the other process is still there")
  assert(sys.kill(sleeper, sys.SIGKILL))
  assert(assert(process.waitpid(sleeper, false)).signal == sys.SIGKILL)
  assert(other.code == 1 and other.said:find("not permitted", 1, true) ~= nil,
    "refused with EPERM: " .. other.code .. " " .. other.said)
end

local function test_a_child_forks_only_with_fork(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local without = under(tmp, {}, "run " .. probe .. " print inner", probe)
  assert(without.code == 127 and without.said == "", "a clone is refused: " .. without.code .. " " .. without.said)
  for _, promises in ipairs({ { "fork" }, { "fork", "jit" }, { "fork", "jit", "fattr" } }) do
    local with = under(tmp, promises, "run " .. probe .. " print inner", probe)
    assert(with.code == 0 and with.said == "inner\n", "forks: " .. with.code .. " " .. with.said)
  end
  -- What it starts is held as it is: a grandchild has the filter too.
  local grandchild = under(tmp, { "fork" }, "run " .. probe .. " status-field Seccomp", probe)
  assert(grandchild.code == 0 and grandchild.said == "Seccomp:\t2\n", grandchild.said)
end

local function test_the_mode_of_a_file_changes_only_with_fattr(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local file = tmp .. "/target"
  assert(Fs.write(file, "x", 420))
  local without = under(tmp, { "fork", "jit" }, "chmod " .. file .. " 600", probe)
  assert(without.code == 1 and without.said:find("not permitted", 1, true) ~= nil,
    "chmod is refused: " .. without.code .. " " .. without.said)
  assert(assert(sys.stat(file)).mode & 0xfff == 420)
  local with = under(tmp, { "fattr" }, "chmod " .. file .. " 600", probe)
  assert(with.code == 0, with.said)
  assert(assert(sys.stat(file)).mode & 0xfff == 384)
  -- Never a bit that gives its owner's authority to a program: setuid, setgid, sticky.
  for _, bits in ipairs({ "4755", "2755", "1755" }) do
    local special = under(tmp, { "fattr" }, "chmod " .. file .. " " .. bits, probe)
    assert(special.code == 1 and special.said:find("not permitted", 1, true) ~= nil,
      bits .. " is refused: " .. special.code .. " " .. special.said)
    assert(assert(sys.stat(file)).mode & 0xfff == 384)
  end
end

local function test_no_socket_is_made_but_a_socketpair(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  for _, promises in ipairs(PROMISE_SETS) do
    local inet = under(tmp, promises, "connect-tcp 127.0.0.1 9", probe)
    assert(inet.said:find("not permitted", 1, true) ~= nil, "an inet socket is refused: " .. inet.said)
    local unix = under(tmp, promises, "connect " .. tmp .. "/none.sock", probe)
    assert(unix.said:find("not permitted", 1, true) ~= nil, "a unix socket is refused too: " .. unix.said)
  end
  -- A child given no filter of its own reaches the network stack and fails
  -- on its own, unless this worker is itself held by a filter (as one
  -- under the policy path is), which every process it starts has too.
  local plain = assert(sys.open(tmp .. "/plain", sys.O_CREAT | sys.O_RDWR, 420))
  local pid = assert(process.spawn(probe, { probe, "connect-tcp 127.0.0.1 9" }, nil, nil, nil, plain,
    plain, false))
  assert(assert(process.waitpid(pid, false)).code == 0)
  sys.close(plain)
  local said = assert(Fs.read(tmp .. "/plain"))
  local own = assert(Fs.read("/proc/self/status")):match("\nSeccomp:%s*(%d+)") == "2"
  assert((said:find("not permitted", 1, true) ~= nil) == own,
    (own and "the worker's own filter holds what it starts: " or "unfiltered: ") .. said)
end

--- Whether this process has CAP_SYS_RESOURCE in its permitted set, which
--- a child it starts without a user namespace of its own has too.
local function holds_resource_capability(): boolean
  local status = assert(Fs.read("/proc/self/status"))
  local permitted = assert(status:match("CapPrm:%s*(%x+)"), status)
  return (assert(math.tointeger(tonumber(permitted, 16))) >> 24) & 1 == 1
end

local function test_a_child_that_cannot_raise_a_hard_limit_sets_its_own_limits(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local lowers = under(tmp, {}, "setrlimit nofile 64", probe)
  local raises = under(tmp, {}, "setrlimit nofile 64; setrlimit nofile 128", probe)
  if holds_resource_capability() then
    -- A child that can raise a hard limit keeps the filter's refusal.
    assert(lowers.code == 1 and lowers.said:find("not permitted", 1, true), lowers.said)
    assert(raises.code == 1 and raises.said:find("not permitted", 1, true), raises.said)
    return
  end
  assert(lowers.code == 0 and lowers.said == "set\n", "it lowers its limits: " .. lowers.said)
  -- The first is let through, and the kernel refuses the raised hard limit.
  assert(raises.code == 1 and raises.said:find("set\n", 1, true) == 1 and
      raises.said:find("not permitted", 1, true), "it raises none: " .. raises.said)
  -- Never another's, which the filter holds to the process itself.
  local other = under(tmp, {}, "rlimit nofile", probe)
  assert(other.code == 0, other.said)
end

--- How many seccomp filters `probe` reports when started with `sandbox`:
--- nil when the start is refused.
local function filters(tmp: string, probe: string, sandbox?: raw_process.Sandbox): integer | nil
  local path = tmp .. "/filters"
  local output = assert(sys.open(path, sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420))
  local pid = process.spawn(probe, { probe, "status-field Seccomp_filters" }, nil, nil, nil,
    output, output, false, nil, sandbox)
  if pid == nil then
    sys.close(output)
    return nil
  end
  assert(assert(process.waitpid(pid, false)).code == 0)
  sys.close(output)
  local said = assert(Fs.read(path))
  return math.tointeger(said:match("Seccomp_filters:\t(%d+)")) or error(said)
end

--- A filter beside a pledge: both hold, and the stricter answer stands.
--- Counted from the filters this worker already inherits, which a
--- container's runtime may have installed.
local function test_the_filter_stacks_with_a_pledge(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  under(tmp, {}, "status-field Seccomp", probe) -- skips where the kernel gives no filter
  local inherited = assert(filters(tmp, probe, nil))
  local both = filters(tmp, probe, { promises = {}, pledge = {} })
  if both == nil then Test.skip("the kernel gives no seccomp filter beside a pledge") end
  assert(both == inherited + 2, "filters: " .. inherited .. " inherited, " .. both .. " under both")
end

--- No grants, no Landlock domain, so no scope: the filter keeps its signal
--- calls to the starting pid, on every ABI.
local function test_promises_without_grants_keep_the_filter_to_the_starting_pid(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local outcome = under(tmp, { "fork" }, "run " .. probe .. " signal TERM", probe)
  assert(outcome.code == 1 and outcome.said:find("not permitted", 1, true),
    "its own pid only: " .. outcome.code .. " " .. outcome.said)
end
