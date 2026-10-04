--- `spawn`'s `grants` (core/process.h) on a live child: the kernel's own
--- verdict on the Landlock ruleset `grants_ruleset` (core/syscalls.c)
--- builds from each grant's descriptor. The child is a stand-in
--- (build/stand_in.tl), which does what its script says, so a path the
--- ruleset refuses shows as a command that fails, with the errno Landlock
--- answers. A host whose kernel gives no Landlock skips them
--- (Test.skip).

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Test = require("cosmic.test")
local unix_socket = require("build.unix_socket")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local stand_in = require("build.stand_in")
local type raw_process = require("cosmic.internal.process")
-- Required, so the module whose loader is handed the raw table is of this
-- test's import closure, and the store has it to hand it from.
local type _ = require("cosmic.child")

--- A listener's socket is a unix one in the test's own directory; the
--- loopback is for the connections to a port nothing listens on, which a
--- child with no grants must find refused. Nothing else is read beyond the
--- closure.
Test.needs{ network = { "127.0.0.1" } }

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
  --- Why the start was refused, when it was.
  refused: string
  errno: integer
end

--- Starts `program` with `script` under `grants`, in `tmp`'s directory:
--- its output and how it ended, or, when the start fails, why.
local function start(tmp: string, program: string, grants: {raw_process.Grant}, script: string,
                     promises?: {string}): Outcome
  local path = tmp .. "/said"
  local output = assert(sys.open(path, sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420))
  local pid, trouble, number = process.spawn(program, { program, script }, nil, nil, nil, output,
    output, false, nil, { grants = grants, promises = promises })
  if pid == nil then
    sys.close(output)
    return { code = -1, signal = -1, said = "", refused = trouble, errno = number }
  end
  local status = assert(process.waitpid(pid, false))
  sys.close(output)
  return { code = status.code, signal = status.signal, said = (Fs.read(path)) or "" }
end

--- Whether `outcome` is a start refused for want of a sandbox: no Landlock
--- on this kernel, or none on this platform (ENOSYS).
local function unsandboxable(outcome: Outcome): boolean
  return outcome.refused ~= nil and (outcome.errno == sys.ENOSYS or
    outcome.refused:find("Landlock is not available", 1, true) ~= nil)
end

--- The kernel's Landlock ABI, or nil, having skipped the test, where it
--- gives none.
local function abi_or_skip(): integer
  local abi, trouble = process.landlock_abi()
  if abi == nil then
    if confine.sandbox_platform() then Test.skip("no Landlock here: " .. tostring(trouble)) end
    return nil
  end
  return abi
end

--- The same, held to the grants of `program` itself (`rx`, which a
--- child needs to run at all) and `more`. Skips the test where the host
--- gives no Landlock, returning true.
local function under(tmp: string, program: string, more: {raw_process.Grant}, script: string): Outcome, boolean
  local grants: {raw_process.Grant} = { { path = program, access = "rx" } }
  for _, grant in ipairs(more) do grants[#grants + 1] = grant end
  local outcome = start(tmp, program, grants, script)
  if unsandboxable(outcome) then
    if confine.sandbox_platform() then Test.skip(outcome.refused) end
    return outcome, true
  end
  assert(outcome.refused == nil, "the start was refused: " .. tostring(outcome.refused))
  return outcome, false
end

local DENIED <const> = "Permission denied"

local function test_a_granted_path_is_read_and_its_sibling_is_not(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(Fs.mkdirs(tmp .. "/ro") and Fs.mkdirs(tmp .. "/other"))
  assert(Fs.write(tmp .. "/ro/a", "alpha\n") and Fs.write(tmp .. "/other/b", "beta\n"))
  local read, skipped = under(tmp, probe, { { path = tmp .. "/ro", access = "r" } },
    "cat " .. tmp .. "/ro/a; ls " .. tmp .. "/ro")
  if skipped then return end
  assert(read.code == 0 and read.said == "alpha\na\n", read.code .. ": " .. read.said)
  local sibling = under(tmp, probe, { { path = tmp .. "/ro", access = "r" } },
    "cat " .. tmp .. "/other/b")
  assert(sibling.code == 1 and sibling.said:find(DENIED, 1, true), "refused: " .. sibling.said)
  local listing = under(tmp, probe, { { path = tmp .. "/ro", access = "r" } }, "ls " .. tmp .. "/other")
  assert(listing.code == 1 and listing.said:find(DENIED, 1, true), "refused: " .. listing.said)
  -- A grant on one file reaches that file and not its sibling.
  local file = under(tmp, probe, { { path = tmp .. "/ro/a", access = "r" } },
    "cat " .. tmp .. "/ro/a")
  assert(file.code == 0 and file.said == "alpha\n", file.said)
  local beside = under(tmp, probe, { { path = tmp .. "/other/b", access = "r" } },
    "cat " .. tmp .. "/ro/a")
  assert(beside.code == 1 and beside.said:find(DENIED, 1, true), beside.said)
  -- Without `r`, a write grant does not read.
  local blind = under(tmp, probe, { { path = tmp .. "/ro/a", access = "w" } },
    "cat " .. tmp .. "/ro/a")
  assert(blind.code == 1 and blind.said:find(DENIED, 1, true), blind.said)
end

local function test_a_write_needs_w_and_a_truncate_too(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local file = tmp .. "/f"
  assert(Fs.write(file, "kept"))
  local without, skipped = under(tmp, probe, { { path = file, access = "r" } },
    "writable " .. file)
  if skipped then return end
  assert(without.code == 1 and without.said:find(DENIED, 1, true), "refused: " .. without.said)
  local blocked = under(tmp, probe, { { path = file, access = "r" } }, "truncate " .. file)
  assert(blocked.code == 1 and blocked.said:find(DENIED, 1, true), "refused: " .. blocked.said)
  assert(Fs.read(file) == "kept")
  local with = under(tmp, probe, { { path = file, access = "w" } },
    "writable " .. file .. " && truncate " .. file)
  assert(with.code == 0, with.said)
  assert(Fs.read(file) == "")
  -- `w` writes what is there; it makes nothing, in a directory it is given.
  assert(Fs.mkdirs(tmp .. "/d"))
  local made = under(tmp, probe, { { path = tmp .. "/d", access = "rw" } },
    "create " .. tmp .. "/d/new x")
  assert(made.code == 1 and made.said:find(DENIED, 1, true), "refused: " .. made.said)
end

local function test_c_creates_and_removes_where_granted_and_nowhere_else(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(Fs.mkdirs(tmp .. "/open") and Fs.mkdirs(tmp .. "/shut"))
  assert(Fs.write(tmp .. "/shut/old", "x"))
  local grants: {raw_process.Grant} = { { path = tmp .. "/open", access = "cw" } }
  local made, skipped = under(tmp, probe, grants,
    "create " .. tmp .. "/open/new hello; mkdirs " .. tmp .. "/open/sub/deeper; mkfifo " ..
      tmp .. "/open/fifo; rename " .. tmp .. "/open/new " .. tmp .. "/open/renamed; rm " ..
      tmp .. "/open/renamed; rmdir " .. tmp .. "/open/sub/deeper")
  if skipped then return end
  assert(made.code == 0, "created and removed: " .. made.said)
  assert(not Fs.exists(tmp .. "/open/new") and not Fs.exists(tmp .. "/open/renamed"))
  assert(Fs.exists(tmp .. "/open/fifo") and Fs.is_dir(tmp .. "/open/sub"))
  for _, script in ipairs({
      "create " .. tmp .. "/shut/new x", "mkdirs " .. tmp .. "/shut/sub", "rm " .. tmp .. "/shut/old",
      "mkfifo " .. tmp .. "/shut/fifo",
  }) do
    local refused = under(tmp, probe, grants, script)
    assert(refused.code == 1 and refused.said:find(DENIED, 1, true), script .. ": " .. refused.said)
  end
  assert(Fs.exists(tmp .. "/shut/old") and not Fs.exists(tmp .. "/shut/new"))
end

local function test_a_rename_between_grants_needs_c_on_both(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(Fs.mkdirs(tmp .. "/a") and Fs.mkdirs(tmp .. "/b") and Fs.mkdirs(tmp .. "/c"))
  assert(Fs.write(tmp .. "/a/f", "x") and Fs.write(tmp .. "/a/g", "y"))
  local both: {raw_process.Grant} = { { path = tmp .. "/a", access = "c" }, { path = tmp .. "/b", access = "c" } }
  local moved, skipped = under(tmp, probe, both, "rename " .. tmp .. "/a/f " .. tmp .. "/b/f")
  if skipped then return end
  assert(moved.code == 0, "renamed: " .. moved.said)
  assert(Fs.exists(tmp .. "/b/f") and not Fs.exists(tmp .. "/a/f"))
  -- Into a directory granted to read alone: refused, as any creation there is.
  local read_only: {raw_process.Grant} = { { path = tmp .. "/a", access = "c" }, { path = tmp .. "/c", access = "r" } }
  local refused = under(tmp, probe, read_only, "rename " .. tmp .. "/a/g " .. tmp .. "/c/g")
  assert(refused.code == 1 and refused.said:find(DENIED, 1, true), "refused: " .. refused.said)
  -- A file may not move to where it would gain rights it has not where it is
  -- (no read in a, one in b): Landlock answers EXDEV.
  local more: {raw_process.Grant} = { { path = tmp .. "/a", access = "c" }, { path = tmp .. "/b", access = "rc" } }
  local gained = under(tmp, probe, more, "rename " .. tmp .. "/a/g " .. tmp .. "/b/g")
  assert(gained.code == 1 and gained.said:find("Cross-device link", 1, true), "EXDEV: " .. gained.said)
  assert(Fs.exists(tmp .. "/a/g"))
end

local function test_x_runs_a_granted_program_and_no_other(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(Fs.mkdirs(tmp .. "/bin"))
  local other = assert(stand_in.build(tmp .. "/bin/other"))
  local script = "run " .. other .. " print inner"
  local without, skipped = under(tmp, probe, { { path = other, access = "r" } }, script)
  if skipped then return end
  assert(without.code == 127 and without.said == "", "not run: " .. without.code .. " " .. without.said)
  local with = under(tmp, probe, { { path = other, access = "rx" } }, script)
  assert(with.code == 0 and with.said == "inner\n", "run: " .. with.code .. " " .. with.said)
end

local function test_a_grant_that_does_not_exist_fails_the_start_naming_it(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local missing = tmp .. "/missing"
  local outcome = start(tmp, probe, { { path = probe, access = "rx" }, { path = missing, access = "r" } },
    "print never")
  if unsandboxable(outcome) then
    if confine.sandbox_platform() then Test.skip(outcome.refused) end
    return
  end
  assert(outcome.refused ~= nil and outcome.refused:find(missing, 1, true), "names the path: " .. tostring(outcome.refused))
  assert(outcome.errno == sys.ENOENT, "ENOENT: " .. tostring(outcome.errno))
  assert(outcome.said == "")
end

local function test_a_link_is_followed_to_its_target(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(Fs.mkdirs(tmp .. "/real") and Fs.write(tmp .. "/real/a", "alpha\n"))
  assert(sys.symlink(tmp .. "/real", tmp .. "/link"))
  local through, skipped = under(tmp, probe, { { path = tmp .. "/link", access = "r" } },
    "cat " .. tmp .. "/real/a")
  if skipped then return end
  assert(through.code == 0 and through.said == "alpha\n", through.said)
end

local function test_a_degenerate_grant_raises(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local function raises(grants: any, extra?: {string:any}): boolean
    local sandbox: {string:any} = { grants = grants }
    for key, value in pairs(extra or {}) do sandbox[key] = value end
    return not pcall(process.spawn, probe, { probe }, nil, nil, nil, nil, nil, false, nil,
      sandbox as raw_process.Sandbox)
  end
  assert(raises({ { path = probe, access = "rq" } }), "a letter that is none")
  assert(raises({ { path = probe, access = "" } }), "no letters")
  assert(raises({ { path = probe, access = "R" } }), "letters are lowercase")
  assert(raises({ { path = "", access = "r" } }), "an empty path")
  assert(raises({ { access = "r" } }), "no path")
  assert(raises({ { path = probe } }), "no access")
  assert(raises({ { path = 1, access = "r" } }), "a path that is no string")
  assert(raises({ probe }), "a grant that is no table")
  assert(raises("r"), "grants that are no list")
  assert(raises({ { path = "a\0b", access = "r" } }), "a path with a NUL")
  assert(raises({ { path = probe, access = "r" } }, { ruleset = 0 }), "a ruleset beside grants")
end

local function test_the_landlock_abi_is_a_version_or_a_refusal(_tmp: string)
  local abi, trouble, number = process.landlock_abi()
  if abi == nil then
    assert(type(trouble) == "string" and math.type(number) == "integer", "a failure says why")
    return
  end
  assert(math.type(abi) == "integer" and abi >= 1, "a version: " .. tostring(abi))
end

local function test_u_connects_to_a_granted_socket_where_the_kernel_can_hold_it(tmp: string)
  local abi = abi_or_skip()
  if abi == nil or unix_socket.skipped(tmp) then return end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(Fs.mkdirs(tmp .. "/s"))
  local socket = tmp .. "/s/sock"
  local _listener <close> = assert(Net.listen(Net.unix(socket), { timeout_ns = Clock.seconds(5) }))
  local script = "connect " .. socket
  local grants: {raw_process.Grant} = { { path = probe, access = "rx" }, { path = socket, access = "u" } }
  local with = start(tmp, probe, grants, script)
  if abi < 9 then
    -- Below ABI 9 the start fails, naming the ABI that is needed and the one given.
    assert(with.refused ~= nil and with.errno == sys.EOPNOTSUPP, "EOPNOTSUPP: " .. tostring(with.refused))
    assert(with.refused:find("Landlock ABI 9 is needed", 1, true) and
        with.refused:find("this kernel gives " .. abi, 1, true), with.refused)
    return
  end
  assert(with.refused == nil, "the start was refused: " .. tostring(with.refused))
  assert(with.code == 0 and with.said == "connected\n", "connects: " .. with.said)
  local without = under(tmp, probe, { { path = tmp .. "/s", access = "r" } }, script)
  assert(without.said:find(DENIED, 1, true), "refused: " .. without.said)
end

local function test_the_child_is_held_to_no_tcp_where_the_kernel_can(tmp: string)
  local abi = abi_or_skip()
  if abi == nil then return end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local tcp = under(tmp, probe, {}, "connect-tcp 127.0.0.1 9")
  -- ABI 4 refuses a connect outright, whatever the port, and no grant gives
  -- one; below it the connection reaches the stack and is refused as nothing
  -- listens there.
  if abi >= 4 then
    assert(tcp.said:find(DENIED, 1, true), "held: " .. tcp.said)
  else
    assert(tcp.said:find("refused", 1, true), "unheld: " .. tcp.said)
  end
  local plain = assert(sys.open(tmp .. "/plain", sys.O_CREAT | sys.O_RDWR, 420))
  local pid = assert(process.spawn(probe, { probe, "connect-tcp 127.0.0.1 9" }, nil, nil, nil, plain,
    plain, false))
  assert(assert(process.waitpid(pid, false)).code == 0)
  sys.close(plain)
  assert(assert(Fs.read(tmp .. "/plain")):find("refused", 1, true), "unheld, it reaches the stack")
end

local function test_a_signal_to_a_process_outside_is_refused_where_the_kernel_scopes_it(tmp: string)
  local abi = abi_or_skip()
  if abi == nil then return end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local sleeper = assert(process.spawn(probe, { probe, "sleep-forever" }, nil, nil, nil, nil, nil,
    false))
  local sent = under(tmp, probe, {}, "signal KILL " .. sleeper)
  sys.kill(sleeper, sys.SIGKILL)
  assert(assert(process.waitpid(sleeper, false)).signal == sys.SIGKILL)
  if abi >= 6 then
    assert(sent.code == 1 and sent.said:find("not permitted", 1, true), "scoped: " .. sent.said)
  else
    -- Nothing scopes a signal below ABI 6: the child's kill lands.
    assert(sent.code == 0, "sent: " .. sent.said)
  end
end

--- Starts `program` with `script` held to `grants` and the `fork` promise,
--- whose filter takes the scope of the ruleset the grants make: the grants
--- are `program` itself (`rx`) and `tmp`, which the script may write.
local function forking(tmp: string, program: string, script: string): Outcome, boolean
  local outcome = start(tmp, program, { { path = program, access = "rx" },
    { path = tmp, access = "rwcx" } }, script, { "fork" })
  if unsandboxable(outcome) then
    if confine.sandbox_platform() then Test.skip(outcome.refused) end
    return outcome, true
  end
  assert(outcome.refused == nil, "the start was refused: " .. tostring(outcome.refused))
  return outcome, false
end

--- Ends the process whose pid file `path` holds, if there is one: a
--- grandchild a refused signal left running.
local function end_left_by(path: string)
  local held = Fs.read(path)
  local pid = held and math.tointeger(held:match("^(%d+)"))
  if pid ~= nil then sys.kill(pid, sys.SIGKILL) end
end

local function test_a_forked_process_signals_itself_where_the_kernel_scopes_signals(tmp: string)
  local abi = abi_or_skip()
  if abi == nil then return end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  -- The grandchild's pid is not the one the filter was built for.
  local own, skipped = forking(tmp, probe, "run " .. probe .. " signal TERM")
  if skipped then return end
  if abi >= 6 then
    assert(own.code == 128 + sys.SIGTERM, "its own signal lands: " .. own.code .. " " .. own.said)
  else
    assert(own.code == 1 and own.said:find("not permitted", 1, true),
      "below ABI 6 the filter keeps it to the starting pid: " .. own.code .. " " .. own.said)
  end
end

local function test_a_process_signals_what_it_forked_where_the_kernel_scopes_signals(tmp: string)
  local abi = abi_or_skip()
  if abi == nil then return end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local pidfile = tmp .. "/grandchild.pid"
  local grandchild = tmp .. "/grandchild"
  assert(stand_in.place(probe, grandchild, "write-pid " .. pidfile .. "\nsleep-forever"))
  local killed, skipped = forking(tmp, probe, "start " .. grandchild .. "; wait-for " .. pidfile ..
      "; signal KILL @" .. pidfile)
  if skipped then return end
  end_left_by(pidfile)
  if abi >= 6 then
    assert(killed.code == 0, "its child is its to signal: " .. killed.code .. " " .. killed.said)
  else
    assert(killed.code == 1 and killed.said:find("not permitted", 1, true),
      "below ABI 6 the filter refuses it: " .. killed.code .. " " .. killed.said)
  end
end

local function test_a_signal_outside_the_domain_is_refused_though_the_filter_lets_it_pass(tmp: string)
  local abi = abi_or_skip()
  if abi == nil then return end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local sleeper = assert(process.spawn(probe, { probe, "sleep-forever" }, nil, nil, nil, nil, nil,
    false))
  local sent, skipped = forking(tmp, probe, "signal KILL " .. sleeper)
  local alive = sys.kill(sleeper, 0)
  sys.kill(sleeper, sys.SIGKILL)
  assert(assert(process.waitpid(sleeper, false)).signal == sys.SIGKILL)
  if skipped then return end
  -- Above ABI 6 the filter takes any pid and Landlock's EPERM is the answer;
  -- below, the filter's own is.
  assert(sent.code == 1 and sent.said:find("not permitted", 1, true), "refused: " .. sent.said)
  assert(alive, "the process outside the sandbox was not signalled")
end

--- No grants, no Landlock domain, so no scope: the filter keeps its signal
--- calls to the starting pid, on every ABI.
local function test_promises_without_grants_keep_the_filter_to_the_starting_pid(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local path = tmp .. "/said"
  local output = assert(sys.open(path, sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420))
  local pid, why = process.spawn(probe, { probe, "run " .. probe .. " signal TERM" }, nil, nil, nil,
    output, output, false, nil, { promises = { "fork" } })
  if pid == nil then
    sys.close(output)
    if confine.sandbox_platform() then
      Test.skip("the kernel gives no seccomp filter: " .. tostring(why))
    end
    return
  end
  local status = assert(process.waitpid(pid, false))
  sys.close(output)
  local said = Fs.read(path) or ""
  assert(status.code == 1 and said:find("not permitted", 1, true),
    "its own pid only: " .. status.code .. " " .. said)
end

--- A ruleset the caller made says nothing of what it scopes, so the filter
--- keeps its signal calls to the starting pid beside one.
local function test_a_ruleset_descriptor_keeps_the_filter_to_the_starting_pid(tmp: string)
  local abi = abi_or_skip()
  if abi == nil then return end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local ruleset, trouble = process.landlock_ruleset({ probe }, { tmp })
  if ruleset == nil then
    if confine.sandbox_platform() then Test.skip("no ruleset: " .. tostring(trouble)) end
    return
  end
  local path = tmp .. "/said"
  local output = assert(sys.open(path, sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420))
  local pid, why = process.spawn(probe, { probe, "run " .. probe .. " signal TERM" }, nil, nil, nil,
    output, output, false, nil, { ruleset = ruleset, promises = { "fork" } })
  sys.close(ruleset)
  assert(pid ~= nil, tostring(why))
  local status = assert(process.waitpid(pid, false))
  sys.close(output)
  local said = Fs.read(path) or ""
  assert(status.code == 1 and said:find("not permitted", 1, true),
    "its own pid only: " .. status.code .. " " .. said)
end

local function test_no_grants_grant_nothing_and_the_program_needs_its_own(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local none = start(tmp, probe, {}, "print never")
  if unsandboxable(none) then
    if confine.sandbox_platform() then Test.skip(none.refused) end
    return
  end
  -- Held to nothing, the child cannot run its own program: the start fails, and says why.
  assert(none.refused ~= nil and none.errno == sys.EACCES, "EACCES: " .. tostring(none.refused))
  assert(none.refused:find("`rx` grant", 1, true), none.refused)
  local read_only = start(tmp, probe, { { path = probe, access = "r" } }, "print never")
  assert(read_only.errno == sys.EACCES, "execute is its own letter: " .. tostring(read_only.refused))
end

local function test_c_on_a_file_grants_nothing(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local file = tmp .. "/f"
  assert(Fs.write(file, "kept\n"))
  -- A file takes no creation right, so the grant adds no rule: the start goes on and
  -- the file is as ungranted as if it were not named.
  local read, skipped = under(tmp, probe, { { path = file, access = "c" } }, "cat " .. file)
  if skipped then return end
  assert(read.code == 1 and read.said:find(DENIED, 1, true), "not read: " .. read.said)
  local removed = under(tmp, probe, { { path = file, access = "c" } }, "rm " .. file)
  assert(removed.code == 1 and removed.said:find(DENIED, 1, true), "not removed: " .. removed.said)
  assert(Fs.read(file) == "kept\n")
end
