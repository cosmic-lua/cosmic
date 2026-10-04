--- [`Sandbox.restrict`] (cosmic/sandbox.tl) on a live process: the kernel's
--- own verdict on the Landlock ruleset, the seccomp filter and the rlimits
--- it makes of a policy. Restricting is for good, so every case restricts a
--- child of this program (`cosmic -e`, started past its launcher), which
--- prints what it could and could not do and ends; the test reads that.
--- A host whose kernel gives no Landlock or seccomp, and every platform
--- but Linux, skips the cases that need the sandbox (build.sandbox_skip).

local Child = require("cosmic.child")
-- The child loads these from the store, which holds this test's closure alone.
local _net = require("cosmic.net")
local _sandbox = require("cosmic.sandbox")
local _store = require("cosmic.store")
local _sys = require("cosmic.sys")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local Time = require("cosmic.time")
local sandbox_skip = require("build.sandbox_skip")
local stand_in = require("build.stand_in")
local this_program = require("build.this_program")

--- The program is this one, which a test starts only with `tool`; its
--- temporary directory is the test's own.
Test.needs{ tool = true, env = { "TMPDIR" } }

local DENIED <const> = "Permission denied"

--- What the child runs first: the modules it uses, loaded before it is
--- restricted since it may read nothing after, and the helpers that
--- report. `say(name, ...)` prints `name=` and its values; `reads(path)`
--- is what a file holds or why it cannot be read.
local PRELUDE <const> = [[
local sys = require("cosmic.sys")
local Sandbox = require("cosmic.sandbox")
local Child = require("cosmic.child")
local Net = require("cosmic.net")
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
local function writes(path)
  local fd, why = sys.open(path, sys.O_WRONLY | sys.O_CREAT, 420)
  if fd == nil then return "denied: " .. why end
  sys.close(fd)
  return "wrote"
end
]]

--- What a child said: its lines, `name=value`, by name, and how it ended.
local record Said
  code: integer
  lines: {string:string}
  raw: string
end

--- Runs `chunk`, after `PRELUDE`, in a child of this program, and answers
--- what it printed. Skips the test where the child reports `skip=` and
--- why, which it does where the host gives no sandbox.
local function in_child(chunk: string): Said | nil
  local started = this_program.program({ "-e", PRELUDE .. chunk }, {
    env = this_program.environment(), stdout = "capture", stderr = "stdout",
    timeout_ns = Time.seconds(60) })
  local result = assert(Child.run(started.argv, started.options))
  local said: Said = { code = result.code or -1, lines = {}, raw = result.stdout or "" }
  for line in said.raw:gmatch("[^\n]+") do
    local name, value = line:match("^([%w_]+)=(.*)$")
    if name ~= nil then said.lines[name] = value end
  end
  local skip = said.lines.skip
  if skip ~= nil then
    sandbox_skip.refused(skip)
    return nil
  end
  assert(result.code == 0, "the child ended " .. tostring(result.code) .. ": " .. said.raw)
  return said
end

--- Lua source that restricts to `policy` (Lua source of a table), says
--- `restrict=<ok> <why>`, and goes on only where it held.
local function restricted(policy: string, rest: string): string
  return string.format([[
local ok, why = Sandbox.restrict(%s)
if not ok and (why:find("Landlock is not available here", 1, true) or
    why:find("which only Linux gives", 1, true)) then
  say("skip", why)
  os.exit(0)
end
say("restrict", ok, why)
if not ok then os.exit(0) end
%s
]], policy, rest)
end

local function test_a_granted_path_is_read_and_its_sibling_is_not(tmp: string)
  assert(Fs.mkdirs(tmp .. "/ro") and Fs.mkdirs(tmp .. "/other"))
  assert(Fs.write(tmp .. "/ro/a", "alpha") and Fs.write(tmp .. "/other/b", "beta"))
  local said = in_child(restricted(
    string.format("{ grants = { { path = %q, letters = \"r\" } } }", tmp .. "/ro"),
    string.format([[
say("granted", reads(%q))
say("sibling", reads(%q))
say("create", writes(%q))
say("overwrite", writes(%q))
]], tmp .. "/ro/a", tmp .. "/other/b", tmp .. "/ro/new", tmp .. "/ro/a")))
  if said == nil then return end
  assert(said.lines.restrict == "true ", said.raw)
  assert(said.lines.granted == "alpha", said.raw)
  assert(said.lines.sibling == "denied: " .. DENIED, said.raw)
  -- Read alone is not write, whether to make a file or to change one.
  assert(said.lines.create == "denied: " .. DENIED, said.raw)
  assert(said.lines.overwrite == "denied: " .. DENIED, said.raw)
end

local function test_w_and_c_give_writing_and_creating(tmp: string)
  assert(Fs.mkdirs(tmp .. "/rw") and Fs.write(tmp .. "/rw/f", "x"))
  local said = in_child(restricted(
    string.format("{ grants = { { path = %q, letters = \"rwc\" } } }", tmp .. "/rw"),
    string.format([[
say("overwrite", writes(%q))
say("create", writes(%q))
]], tmp .. "/rw/f", tmp .. "/rw/made")))
  if said == nil then return end
  assert(said.lines.overwrite == "wrote" and said.lines.create == "wrote", said.raw)
  assert(Fs.exists(tmp .. "/rw/made"))
end

local function test_the_filter_refuses_a_socket_and_a_process(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local said = in_child(restricted(
    string.format("{ grants = { { path = %q, letters = \"rx\" } } }", probe),
    string.format([[
local conn, why = Net.connect(Net.tcp("127.0.0.1", 9))
say("socket", conn ~= nil, why)
local started, trouble = Child.start({ %q, "print hi" }, { process_group = false })
say("fork", started ~= nil, trouble)
]], probe)))
  if said == nil then return end
  -- Not "Connection refused", which a socket the filter let through would meet.
  assert(said.lines.socket:find("^false") and said.lines.socket:find("Operation not permitted", 1, true),
    said.raw)
  assert(said.lines.fork:find("^false") and said.lines.fork:find("Operation not permitted", 1, true),
    said.raw)
end

local function test_the_fork_promise_lets_a_process_start(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local said = in_child(restricted(
    string.format("{ grants = { { path = %q, letters = \"rx\" } }, promises = { \"fork\" } }", probe),
    string.format([[
local result, trouble = Child.run({ %q, "print hi" }, { process_group = false, stdout = "capture" })
say("fork", result ~= nil and result.ok, result and result.stdout or trouble)
]], probe)))
  if said == nil then return end
  assert(said.lines.fork:find("^true"), said.raw)
end

local function test_limits_lower_what_the_process_may_spend()
  local said = in_child(restricted("{ limits = { open_files = 24, cpu_seconds = 100 } }", [[
local open = sys.getrlimit(sys.RLIMIT_NOFILE)
local cpu = sys.getrlimit(sys.RLIMIT_CPU)
local core = sys.getrlimit(sys.RLIMIT_CORE)
say("nofile", open.soft, open.hard)
say("cpu", cpu.soft, cpu.hard)
say("core", core.soft, core.hard)
local held = 0
while sys.dup(0) ~= nil do held = held + 1 end
say("dups", held <= 24)
]]))
  if said == nil then return end
  assert(said.lines.nofile == "24 24" and said.lines.cpu == "100 100", said.raw)
  -- No core dump unless the policy says so.
  assert(said.lines.core == "0 0", said.raw)
  assert(said.lines.dups == "true", said.raw)
end

local function test_a_limit_is_never_raised()
  -- The child starts at a lower limit than the default 1024, which stays.
  local said = in_child([[
assert(sys.setrlimit(sys.RLIMIT_NOFILE, 64, 64))
]] .. restricted("{}", [[
local open = sys.getrlimit(sys.RLIMIT_NOFILE)
say("nofile", open.soft, open.hard)
]]))
  if said == nil then return end
  assert(said.lines.nofile == "64 64", said.raw)
end

local function test_restricting_again_narrows(tmp: string)
  assert(Fs.mkdirs(tmp .. "/a") and Fs.mkdirs(tmp .. "/b") and Fs.mkdirs(tmp .. "/c"))
  assert(Fs.write(tmp .. "/a/f", "a") and Fs.write(tmp .. "/b/f", "b") and Fs.write(tmp .. "/c/f", "c"))
  local first = string.format("{ grants = { { path = %q, letters = \"r\" }, { path = %q, letters = \"r\" } }, " ..
      "limits = { cpu_seconds = 100 } }", tmp .. "/a", tmp .. "/b")
  local said = in_child(restricted(first, string.format([[
say("a", reads(%q))
say("b", reads(%q))
say("c", reads(%q))
local second, why = Sandbox.restrict({ grants = { { path = %q, letters = "r" }, { path = %q, letters = "r" } },
  limits = { cpu_seconds = 100 } })
say("second", second, why)
say("a2", reads(%q))
say("b2", reads(%q))
say("c2", reads(%q))
]], tmp .. "/a/f", tmp .. "/b/f", tmp .. "/c/f", tmp .. "/a", tmp .. "/c", tmp .. "/a/f", tmp .. "/b/f",
    tmp .. "/c/f")))
  if said == nil then return end
  assert(said.lines.a == "a" and said.lines.b == "b" and said.lines.c == "denied: " .. DENIED, said.raw)
  assert(said.lines.second == "true ", said.raw)
  -- A path the second names and the first did not stays refused: the
  -- process is held to what both grant, and what the second drops goes.
  assert(said.lines.a2 == "a", said.raw)
  assert(said.lines.b2 == "denied: " .. DENIED, said.raw)
  assert(said.lines.c2 == "denied: " .. DENIED, said.raw)
end

local function test_a_later_limit_that_asks_for_setrlimit_fails_under_the_filter()
  local said = in_child(restricted("{}", [[
local second, why = Sandbox.restrict({ limits = { cpu_seconds = 5 } })
say("second", second, why)
]]))
  if said == nil then return end
  assert(said.lines.second:find("^false sandbox: restrict: setrlimit: Operation not permitted"), said.raw)
end

--- A policy for each field a process cannot be held to, with the name
--- its failure gives.
local REFUSED <const>: {{string}} = {
  { "{ isolate = { \"file\" } }", "isolate \"file\"" },
  { "{ isolate = { \"proc\" } }", "isolate \"proc\"" },
  { "{ connect = { \"example.com:443\" } }", "connect \"example.com:443\"" },
  { "{ loopback = { \"127.0.0.2\" } }", "loopback \"127.0.0.2\"" },
  { "{ promises = { \"nest\" } }", "promises \"nest\"" },
  { "{ grants = { { path = \"/\", letters = \"ru\" } } }", "grant \"/\" has u" },
  { "{ grants = { { path = \"/\", letters = \"r\", from = \"/srv\" } } }", "grant \"/\" has from" },
  { "{ env = { \"HOME\" } }", "env \"HOME\"" },
  { "{ set_env = { MODE = \"x\" } }", "set_env \"MODE\"" },
  { "{ tmp = true }", "tmp is" },
  { "{ limits = { processes = 4 } }", "limits.processes" },
  { "{ profiles = { \"nonesuch\" } }", "nonesuch" },
}

--- The child of a case that restricts nothing ends unrestricted, so it
--- still reports the C it entered to the test's coverage; one that is held
--- cannot write there. These cases hold that every refusal leaves the
--- process as it was: a file no policy granted reads still, and a limit
--- set past a refusal is not set.
local function test_every_refusal_holds_nothing(tmp: string)
  assert(Fs.write(tmp .. "/free", "free") and Fs.write(tmp .. "/held", "held"))
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local lines: {string} = {}
  for i, case in ipairs(REFUSED) do
    lines[#lines + 1] = string.format("say(%q, Sandbox.restrict(%s))", "case" .. i, case[1])
  end
  local said = in_child(table.concat(lines, "\n") .. "\n" .. string.format([[
-- What the kernel's side refuses: an open descriptor, one fds names that is
-- not open, a grant of a path that is not there (after its limit is planned),
-- and a child not yet waited for.
local nofile_before = sys.getrlimit(sys.RLIMIT_NOFILE).soft
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
say("cpu", sys.getrlimit(sys.RLIMIT_CPU).soft ~= 7)
say("nofile", sys.getrlimit(sys.RLIMIT_NOFILE).soft == nofile_before)
say("with_limits", Sandbox.restrict({ isolate = { "file" }, grants = { { path = "/", letters = "r" } },
  limits = { cpu_seconds = 9, open_files = 12 } }))
say("cpu_after", sys.getrlimit(sys.RLIMIT_CPU).soft ~= 9)
say("nofile_after", sys.getrlimit(sys.RLIMIT_NOFILE).soft == nofile_before)
say("free", reads(%q))
]], tmp .. "/held", tmp .. "/absent", probe, tmp .. "/free"))
  if said == nil then return end
  for i, case in ipairs(REFUSED) do
    local answer = said.lines["case" .. i] or ""
    assert(answer:find("^false sandbox: ") and answer:find(case[2], 1, true),
      case[1] .. " -> " .. answer)
  end
  local fd = said.lines.fd
  assert(said.lines.unnamed == "false sandbox: restrict: descriptor " .. fd ..
      " is open and not named in fds: close it, or name it to keep it", said.raw)
  assert(said.lines.absent_fd:find("descriptor 40, which fds names, is not open", 1, true), said.raw)
  assert(said.lines.missing:find("^false sandbox: restrict: grant .*absent: No such file"), said.raw)
  assert(said.lines.child:find("^false sandbox: restrict: this process has a child, pid %d+, not waited for"),
    said.raw)
  assert(said.lines.cpu == "true" and said.lines.free == "free", said.raw)
  -- A refusal that comes with limits and grants sets no limit and holds nothing.
  assert(said.lines.nofile == "true" and said.lines.nofile_after == "true", said.raw)
  assert(said.lines.with_limits:find("^false sandbox: restrict: isolate", 1) and
      said.lines.cpu_after == "true", said.raw)
end

--- The slot of one of the three /proc handles a restriction keeps (the
--- threads, the descriptors, the children) is closed and a file the
--- program may write put in it: the next restriction must not trust the
--- number, whichever it is.
local function replaced_handle(tmp: string, which: integer)
  assert(Fs.mkdirs(tmp .. "/rw") and Fs.write(tmp .. "/rw/f", "x"))
  local said = in_child(string.format([[
local before = {}
for n = 3, 80 do if sys.fd_flags(n) then before[n] = true end end
say("first", Sandbox.restrict({ grants = { { path = %q, letters = "rw" } } }))
local new = {}
for n = 3, 80 do if sys.fd_flags(n) and not before[n] then new[#new + 1] = n end end
local slot = new[%d]
say("slots", #new)
assert(sys.close(slot))
local fd = assert(sys.open(%q, sys.O_RDWR))
say("reused", fd == slot)
say("second", Sandbox.restrict({}))
say("write", writes(%q))
]], tmp .. "/rw", which, tmp .. "/rw/f", tmp .. "/rw/f"))
  if said == nil then return end
  assert(said.lines.first == "true " and said.lines.slots == "3" and said.lines.reused == "true", said.raw)
  -- Refused, naming the descriptor or failing closed; never accepted.
  assert(said.lines.second:find("^false sandbox: restrict: "), said.raw)
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

local function test_a_writable_descriptor_on_a_store_database_is_the_programs_own(tmp: string)
  local said = in_child(string.format([[
-- A database of the store's own kind, attached: the store holds it read-only.
local original = "o/cosmic.db"
local copy = %q .. "/copy.db"
local source = assert(sys.open(original, sys.O_RDONLY))
local target = assert(sys.open(copy, sys.O_WRONLY | sys.O_CREAT, 420))
while true do
  local chunk = sys.read(source, 65536)
  if chunk == nil or chunk == "" then break end
  assert(sys.write(target, chunk))
end
sys.close(source) sys.close(target)
assert(Store.attach(copy))
local mine = assert(sys.open(copy, sys.O_RDWR))
say("mine", mine)
say("refused", Sandbox.restrict({}))
say("named", Sandbox.restrict({}, { fds = { mine } }))
]], tmp))
  if said == nil then return end
  assert(said.lines.refused == "false sandbox: restrict: descriptor " .. said.lines.mine ..
      " is open and not named in fds: close it, or name it to keep it", said.raw)
end

local function test_a_named_descriptor_is_kept_and_the_path_it_was_opened_by_is_not(tmp: string)
  assert(Fs.write(tmp .. "/f", "held"))
  local said = in_child(string.format([[
local fd = assert(sys.open(%q, sys.O_RDONLY))
local named, trouble = Sandbox.restrict({}, { fds = { fd } })
say("named", named, trouble)
-- Reached whatever the grants say; the path is not.
say("through", sys.read(fd, 10))
say("after", reads(%q))
]], tmp .. "/f", tmp .. "/f"))
  if said == nil then return end
  assert(said.lines.named == "true ", said.raw)
  assert(said.lines.through == "held", said.raw)
  assert(said.lines.after == "denied: " .. DENIED, said.raw)
end

local function test_fds_names_a_descriptor_above_2()
  local said = in_child([[
say("low", Sandbox.restrict({}, { fds = { 1 } }))
]])
  if said == nil then return end
  assert(said.lines.low:find("^false sandbox: restrict: fds names 1, which is not a descriptor above 2"),
    said.raw)
end

local function test_a_child_reaped_does_not_refuse(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local said = in_child(string.format([[
local running = assert(Child.start({ %q, "sleep-forever" }, { process_group = false }))
assert(running:close())
local after, trouble = Sandbox.restrict({})
say("reaped", after, trouble)
]], probe))
  if said == nil then return end
  assert(said.lines.reaped == "true ", said.raw)
end

local function test_a_policy_is_merged_first_so_profiles_resolve()
  local said = in_child(restricted("{ profiles = { \"system\" } }", ""))
  if said == nil then return end
  assert(said.lines.restrict == "true ", said.raw)
end
