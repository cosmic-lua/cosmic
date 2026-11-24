--- [`Sandbox.restrict`] (cosmic/sandbox/init.tl) on a live process: the kernel's
--- own verdict on the Landlock ruleset, the seccomp filter and the rlimits
--- it makes of a policy. Restricting is for good, so every case restricts a
--- child of this program (`cosmic -e`, started past its launcher), which
--- prints what it could and could not do and ends; the test reads that.
--- Every case needs a sandbox (`requires`): where the platform gives none
--- they are not applicable, and where this host's kernel refuses Landlock
--- or seccomp a child that reports it skips its case (Test.skip). What a
--- restriction refuses before anything holds the process, which needs no
--- sandbox, is cosmic/sandbox_restrict_refusal_test.tl's.

-- The child loads these from the store, which holds this test's closure alone.
local _net = require("cosmic.net")
local _proc = require("cosmic.proc")
local _sandbox = require("cosmic.sandbox")
local _store = require("cosmic.store")
local Child = require("cosmic.child")
local sys = require("cosmic.sys")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local stand_in = require("build.stand_in")
local Restrict = require("build.sandbox_restrict_fixture")

--- The program is this one, which a test starts only with `tool`; its
--- temporary directory is the test's own.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  env = { "TMPDIR" },
  requires = { "sandbox" },
}

local DENIED <const> = "Permission denied"

--- Lua source that restricts to `policy` (Lua source of a table), says
--- `restrict=<ok> <why>`, and goes on only where it held.
local function restricted(policy: string, rest: string): string
  return string.format([[
local restricted, restricted_why = Sandbox.restrict(%s)
if not restricted and restricted_why:find("Landlock is not available here", 1, true) ~= nil then
  say("skip", restricted_why)
  return 0
end
say("restrict", restricted, restricted_why)
if not restricted then return 0 end
%s
]], policy, rest)
end

local function test_a_granted_path_is_read_and_its_sibling_is_not(tmp: string)
  assert(Fs.mkdirs(tmp .. "/ro"))
  assert(Fs.mkdirs(tmp .. "/other"))
  assert(Fs.write(tmp .. "/ro/a", "alpha"))
  assert(Fs.write(tmp .. "/other/b", "beta"))
  local said = Restrict.in_child(restricted(
    string.format("{ grants = { { path = %q, letters = \"r\" } } }", tmp .. "/ro"),
    string.format([[
say("granted", reads(%q))
say("sibling", reads(%q))
say("create", writes(%q))
say("overwrite", writes(%q))
]], tmp .. "/ro/a", tmp .. "/other/b", tmp .. "/ro/new", tmp .. "/ro/a")))
  assert(said.lines["restrict"] == "true ", said.raw)
  assert(said.lines["granted"] == "alpha", said.raw)
  assert(said.lines["sibling"] == "denied: " .. DENIED, said.raw)
  -- Read alone is not write, whether to make a file or to change one.
  assert(said.lines["create"] == "denied: " .. DENIED, said.raw)
  assert(said.lines["overwrite"] == "denied: " .. DENIED, said.raw)
end

local function test_w_and_c_give_writing_and_creating(tmp: string)
  assert(Fs.mkdirs(tmp .. "/rw"))
  assert(Fs.write(tmp .. "/rw/f", "x"))
  local said = Restrict.in_child(restricted(
    string.format("{ grants = { { path = %q, letters = \"rwc\" } } }", tmp .. "/rw"),
    string.format([[
say("overwrite", writes(%q))
say("create", writes(%q))
]], tmp .. "/rw/f", tmp .. "/rw/made")))
  assert(said.lines["overwrite"] == "wrote" and said.lines["create"] == "wrote", said.raw)
  do
    assert(assert(Fs.status(tmp .. "/rw/made")).exists)
  end
end

local function test_the_filter_refuses_a_socket_and_a_process(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local said = Restrict.in_child(restricted(
    string.format("{ grants = { { path = %q, letters = \"rx\" } } }", probe),
    string.format([[
local conn, why = Net.connect(Net.tcp("127.0.0.1", 9))
say("socket", conn ~= nil, why)
local started, trouble = Child.start({ %q, "print hi" }, { timeout_ns = Child.FOREVER, process_group = false })
say("fork", started ~= nil, trouble)
]], probe)))
  -- Not "Connection refused", which a socket the filter let through would meet.
  assert(assert(said.lines["socket"]):find("^false") and assert(said.lines["socket"]):find("Operation not permitted", 1, true),
    said.raw)
  assert(assert(said.lines["fork"]):find("^false") and assert(said.lines["fork"]):find("Operation not permitted", 1, true),
    said.raw)
end

--- Grants with no `x` run no program: the exec filter refuses it (EPERM)
--- before Landlock would (EACCES), so the text says which layer held. A
--- process forked after the restriction inherits both.
local function test_grants_with_no_x_run_no_program(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local said = Restrict.in_child(restricted(
    string.format("{ grants = { { path = %q, letters = \"r\" } }, promises = { \"fork\" } }", probe),
    string.format([[
local ran, trouble = Child.run({ %q, "print hi" }, { timeout_ns = Child.FOREVER, process_group = false, stdout = "capture" })
if ran ~= nil then say("child", ran.ok, ran.stdout) else say("child", false, trouble) end
local why = require("cosmic.proc").exec({ %q, "print replaced" })
say("exec", why)
]], probe, probe)))
  -- The exec failed, so this process went on to say so, and was not replaced.
  assert(said.raw:find("replaced", 1, true) == nil, said.raw)
  assert(assert(said.lines["exec"]):find("Operation not permitted", 1, true),
    said.raw)
  assert(assert(said.lines["child"]):find("^false"), said.raw)
end

--- A later restriction that grants `x` does not lift the filter an
--- earlier one with no `x` added: the kernel holds every layer.
local function test_a_later_x_grant_runs_no_program_after_none(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local said = Restrict.in_child(restricted(
    string.format("{ grants = { { path = %q, letters = \"r\" } } }", probe),
    string.format([[
local again, again_why = Sandbox.restrict({ grants = { { path = %q, letters = "rx" } } })
say("again", again, again_why)
local why = require("cosmic.proc").exec({ %q, "print replaced" })
say("exec", why)
]], probe, probe)))
  assert(said.raw:find("replaced", 1, true) == nil, said.raw)
  assert(assert(said.lines["again"]):find("^true"), said.raw)
  assert(assert(said.lines["exec"]):find("Operation not permitted", 1, true), said.raw)
end

local function test_the_fork_promise_lets_a_process_start(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local said = Restrict.in_child(restricted(
    string.format("{ grants = { { path = %q, letters = \"rx\" } }, promises = { \"fork\" } }", probe),
    string.format([[
local result, trouble = Child.run({ %q, "print hi" }, { timeout_ns = Child.FOREVER, process_group = false, stdout = "capture" })
if result ~= nil then say("fork", result.ok, result.stdout) else say("fork", false, trouble) end
]], probe)))
  assert(assert(said.lines["fork"]):find("^true"), said.raw)
end

--- Landlock's signal scope (ABI 6) is what lets the filter's signal calls
--- take any pid: a process the sandbox forks signals itself and what it
--- forked, and nothing outside the sandbox. Below ABI 6 the filter keeps
--- the calls to the pid it was built for.
local function test_the_signal_scope_lets_a_forked_process_signal_what_is_inside(tmp: string)
  local abi, _ = require("cosmic.internal.process").landlock_abi()
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local sibling = assert(Child.start({ probe, "sleep-forever" }, { timeout_ns = Child.FOREVER, process_group = false }))
  local said = Restrict.in_child(restricted(
    string.format("{ grants = { { path = %q, letters = \"rx\" } }, promises = { \"fork\" } }", probe),
    string.format([[
local own, _ = Child.run({ %q, "signal TERM" }, { timeout_ns = Child.FOREVER, process_group = false, stdout = "capture", stderr = "stdout" })
if own ~= nil then say("self", own.signal, own.code, own.stdout) else say("self", nil, nil, nil) end
local held = assert(Child.start({ %q, "sleep-forever" }, { timeout_ns = Child.FOREVER, process_group = false }))
local ended, kill_why = sys.kill(held.pid, sys.SIGKILL)
say("child", ended, kill_why)
local waited, _ = held:wait()
if waited ~= nil then say("reaped", waited.signal) else say("reaped", nil) end
local mine, mine_why = sys.kill(sys.getpid(), 0)
say("pid", mine, mine_why)
local outside, outside_why = sys.kill(%d, sys.SIGKILL)
say("sibling", outside, outside_why)
local parent, parent_why = sys.kill(%d, 0)
say("parent", parent, parent_why)
]], probe, probe, sibling.pid, sys.getpid())))
  local alive = sys.kill(sibling.pid, 0)
  local _, _ = sibling:stop(sys.SIGKILL)
  assert(sibling:wait())
  local refused = "^false.*Operation not permitted"
  assert(assert(said.lines["pid"]):find("^true"), said.raw)
  -- Never a process outside it, whichever ABI: the kernel's, or the filter's.
  assert(alive, "the sibling outside the sandbox was signalled: " .. said.raw)
  assert(assert(said.lines["sibling"]):find(refused), said.raw)
  assert(assert(said.lines["parent"]):find(refused), said.raw)
  if abi ~= nil and abi >= 6 then
    assert(said.lines["self"] == tostring(sys.SIGTERM) .. " nil ", said.raw)
    assert(assert(said.lines["child"]):find("^true"), said.raw)
    assert(said.lines["reaped"] == tostring(sys.SIGKILL), said.raw)
  else
    assert(assert(said.lines["self"]):find("not permitted", 1, true), said.raw)
    assert(assert(said.lines["child"]):find(refused), said.raw)
  end
end

local function test_limits_lower_what_the_process_may_spend()
  local said = Restrict.in_child(restricted("{ limits = { open_files = 24, cpu_seconds = 100 } }", [[
say("nofile", limit(sys.RLIMIT_NOFILE))
say("cpu", limit(sys.RLIMIT_CPU))
say("core", limit(sys.RLIMIT_CORE))
local held = 0
while sys.dup(0) ~= nil do held = held + 1 end
say("dups", held <= 24)
]]))
  assert(said.lines["nofile"] == "24 24" and said.lines["cpu"] == "100 100", said.raw)
  -- No core dump unless the policy says so.
  assert(said.lines["core"] == "0 0", said.raw)
  assert(said.lines["dups"] == "true", said.raw)
end

local function test_a_limit_is_never_raised()
  -- The child starts at a lower limit than the default 1024, which stays.
  local said = Restrict.in_child([[
assert(sys.setrlimit(sys.RLIMIT_NOFILE, 64, 64))
]] .. restricted("{}", [[
say("nofile", limit(sys.RLIMIT_NOFILE))
]]))
  assert(said.lines["nofile"] == "64 64", said.raw)
end

local function test_restricting_again_narrows(tmp: string)
  assert(Fs.mkdirs(tmp .. "/a"))
  assert(Fs.mkdirs(tmp .. "/b"))
  assert(Fs.mkdirs(tmp .. "/c"))
  assert(Fs.write(tmp .. "/a/f", "a"))
  assert(Fs.write(tmp .. "/b/f", "b"))
  assert(Fs.write(tmp .. "/c/f", "c"))
  local first = string.format("{ grants = { { path = %q, letters = \"r\" }, { path = %q, letters = \"r\" } }, " ..
      "limits = { cpu_seconds = 100 } }", tmp .. "/a", tmp .. "/b")
  local said = Restrict.in_child(restricted(first, string.format([[
say("a", reads(%q))
say("b", reads(%q))
say("c", reads(%q))
local second, second_why = Sandbox.restrict({ grants = { { path = %q, letters = "r" }, { path = %q, letters = "r" } },
  limits = { cpu_seconds = 100 } })
say("second", second, second_why)
say("a2", reads(%q))
say("b2", reads(%q))
say("c2", reads(%q))
]], tmp .. "/a/f", tmp .. "/b/f", tmp .. "/c/f", tmp .. "/a", tmp .. "/c", tmp .. "/a/f", tmp .. "/b/f",
    tmp .. "/c/f")))
  assert(said.lines["a"] == "a" and said.lines["b"] == "b" and said.lines["c"] == "denied: " .. DENIED, said.raw)
  assert(said.lines["second"] == "true ", said.raw)
  -- A path the second names and the first did not stays refused: the
  -- process is held to what both grant, and what the second drops goes.
  assert(said.lines["a2"] == "a", said.raw)
  assert(said.lines["b2"] == "denied: " .. DENIED, said.raw)
  assert(said.lines["c2"] == "denied: " .. DENIED, said.raw)
end

--- A limit a later restriction lowers asks for setrlimit, which the first
--- filter allows where the process cannot raise a hard limit.
local function test_a_later_limit_is_lowered_under_the_filter()
  local said = Restrict.in_child(restricted("{}", [[
local second, second_why = Sandbox.restrict({ limits = { cpu_seconds = 5 } })
say("second", second, second_why)
say("cpu", limit(sys.RLIMIT_CPU))
]]))
  assert(said.lines["second"] == "true " and said.lines["cpu"] == "5 5", said.raw)
end

--- Every restriction lowers a limit, however many are stacked: a later one
--- reads no capability once an earlier filter refuses it, and takes the
--- earlier filter's allowing setrlimit as proof it holds none.
local function test_stacked_restrictions_each_lower_a_limit()
  local said = Restrict.in_child(restricted("{ limits = { cpu_seconds = 100 } }", [[
local seconds = { 50, 25, 10 }
for i, n in ipairs(seconds) do
  local next_ok, next_why = Sandbox.restrict({ limits = { cpu_seconds = n } })
  say("r" .. tostring(i), next_ok, next_why)
  say("cpu" .. tostring(i), limit(sys.RLIMIT_CPU))
end
]]))
  for i, n in ipairs({ 50, 25, 10 }) do
    assert(said.lines["r" .. tostring(i)] == "true " and said.lines["cpu" .. tostring(i)] == tostring(n) .. " " .. tostring(n), said.raw)
  end
end

--- The filter a restriction makes lets the process lower its own limits where
--- it cannot raise a hard limit (its capabilities lack CAP_SYS_RESOURCE, which
--- the kernel asks for it), and the kernel keeps the rest: a hard limit is not
--- raised again. Where the process holds the capability its limits are its
--- own to raise, and the filter refuses them.
local function test_the_filter_lets_a_process_lower_its_own_limits_unless_it_can_raise_one()
  local said = Restrict.in_child([[
local fd = assert(sys.open("/proc/self/status", sys.O_RDONLY))
local status = assert(sys.read(fd, 8192))
sys.close(fd)
local prm = assert(math.tointeger(tonumber(assert(status:match("CapPrm:%s*(%x+)")), 16)))
say("capable", (prm >> 24) & 1 == 1)
]] .. restricted("{}", [[
local lowered, lowered_why = sys.setrlimit(sys.RLIMIT_CPU, 5, 5)
say("lowered", lowered, lowered_why)
say("cpu", limit(sys.RLIMIT_CPU))
local raised, raised_why = sys.setrlimit(sys.RLIMIT_CPU, 50, 50)
say("raised", raised, raised_why)
]]))
  if said.lines["capable"] == "true" then
    assert(assert(said.lines["lowered"]):find("^false Operation not permitted"), said.raw)
    return
  end
  assert(said.lines["lowered"] == "true nil", said.raw)
  assert(said.lines["cpu"] == "5 5", said.raw)
  assert(assert(said.lines["raised"]):find("^false Operation not permitted"), said.raw)
end

--- The slot of one of the three /proc handles a restriction keeps (the
--- threads, the descriptors, the children) is closed and a file the
--- program may write put in it: the next restriction must not trust the
--- number, whichever it is.
local function replaced_handle(tmp: string, which: integer)
  assert(Fs.mkdirs(tmp .. "/rw"))
  assert(Fs.write(tmp .. "/rw/f", "x"))
  local said = Restrict.in_child(string.format([[
local before: mut {integer:boolean} = {}
for n = 3, 80 do
  if sys.fd_flags(n) ~= nil then before[n] = true end
end
say("first", Sandbox.restrict({ grants = { { path = %q, letters = "rw" } } }))
local new: mut {integer} = {}
for n = 3, 80 do
  if sys.fd_flags(n) ~= nil and before[n] == nil then new[#new + 1] = n end
end
local slot = assert(new[%d])
say("slots", #new)
assert(sys.close(slot))
local fd = assert(sys.open(%q, sys.O_RDWR))
say("reused", fd == slot)
say("second", Sandbox.restrict({}))
say("write", writes(%q))
]], tmp .. "/rw", which, tmp .. "/rw/f", tmp .. "/rw/f"))
  assert(said.lines["first"] == "true " and said.lines["slots"] == "3" and said.lines["reused"] == "true", said.raw)
  -- Refused, naming the descriptor or failing closed; never accepted.
  assert(assert(said.lines["second"]):find("^false sandbox: restrict: "), said.raw)
end

local function test_a_replaced_threads_handle_is_not_trusted(tmp: string)
  replaced_handle(tmp, 1)
end

local function test_a_replaced_descriptors_handle_is_not_trusted(tmp: string)
  replaced_handle(tmp, 2)
end

local function test_a_replaced_children_handle_is_not_trusted(tmp: string)
  replaced_handle(tmp, 3)
end

local function test_a_named_descriptor_is_kept_and_the_path_it_was_opened_by_is_not(tmp: string)
  assert(Fs.write(tmp .. "/f", "held"))
  local said = Restrict.in_child(string.format([[
local fd = assert(sys.open(%q, sys.O_RDONLY))
local named, trouble = Sandbox.restrict({}, { fds = { fd } })
say("named", named, trouble)
-- Reached whatever the grants say; the path is not.
say("through", sys.read(fd, 10))
say("after", reads(%q))
]], tmp .. "/f", tmp .. "/f"))
  assert(said.lines["named"] == "true ", said.raw)
  assert(said.lines["through"] == "held", said.raw)
  assert(said.lines["after"] == "denied: " .. DENIED, said.raw)
end

local function test_a_child_reaped_does_not_refuse(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local said = Restrict.in_child(string.format([[
local running = assert(Child.start({ %q, "sleep-forever" }, { timeout_ns = Child.FOREVER, process_group = false }))
assert(running:close())
local after, trouble = Sandbox.restrict({})
say("reaped", after, trouble)
]], probe))
  assert(said.lines["reaped"] == "true ", said.raw)
end

local function test_a_policy_is_merged_first_so_profiles_resolve()
  local said = Restrict.in_child(restricted("{ profiles = { \"system\" } }", ""))
  assert(said.lines["restrict"] == "true ", said.raw)
end
