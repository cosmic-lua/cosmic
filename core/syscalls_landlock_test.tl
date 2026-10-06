--- The raw process table's Landlock calls (core/process.h's
--- `landlock_ruleset` and `landlock_restrict_execute`, and `spawn`'s
--- `ruleset`) on a live child, as core/syscalls_test.tl states the rest of
--- the table. They need a kernel with Landlock, which no other platform
--- has: where the platform lacks one the refusal is
--- core/syscalls_test.tl's, and where this Linux host refuses it the tests
--- are not run (`requires`) or, where only the call can tell, skipped
--- (Test.skip).

local Net = require("cosmic.net")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local unix_socket = require("build.unix_socket")
local type raw_process = require("cosmic.internal.process")
local stand_in = require("build.stand_in")
local Clock = require("cosmic.clock")
-- Required, so the module whose loader is handed the raw table is of this
-- test's import closure, and the store has it to hand it from.
local type _ = require("cosmic.child")

--- /proc and loopback, as core/syscalls_test.tl declares them: the child
--- connects to a listener of this process's on loopback.
Test.policy{
  grants = { { path = "/proc", letters = "r" } },
  loopback = { "127.0.0.1" },
  requires = { "landlock" },
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

--- A child held to a ruleset reads and runs only what it names, and what
--- it starts is held too; the process that made the ruleset is not.
local function test_a_landlock_ruleset_holds_a_child_to_what_it_names(tmp: string)
  local inside, outside = tmp .. "/in", tmp .. "/out"
  assert(sys.mkdir(inside, 0x1c0) and sys.mkdir(outside, 0x1c0))
  local written = create(inside .. "/f")
  assert(sys.write(written, "in") == 2)
  sys.close(written)
  written = create(outside .. "/f")
  assert(sys.write(written, "out") == 3)
  sys.close(written)
  local probe = probe_in(tmp)
  local reads: {string} = { inside, probe }
  local ruleset, trouble, errno = process.landlock_ruleset(reads, {})
  if ruleset == nil then
    -- Not built in, turned off, or refused by a filter (a container's
    -- seccomp profile): what only the call can tell.
    assert(errno == sys.ENOSYS or errno == sys.EOPNOTSUPP or errno == sys.EPERM, trouble)
    Test.skip("the kernel gives no Landlock ruleset: " .. tostring(trouble))
  end
  local output = create(tmp .. "/said")
  local pid = assert(process.spawn(probe, { probe,
    "cat in/f; print; run " .. probe .. " cat out/f || print refused; " ..
      "append in/g x || print unwritten" },
    nil, tmp, nil, output, output, false, nil, { ruleset = ruleset }))
  sys.close(ruleset)
  local status = assert(process.waitpid(pid, false))
  assert(status.code == 0, tostring(status.code))
  local said = assert(sys.pread(output, 4096, 0))
  sys.close(output)
  assert(said:find("^in\n") and said:find("refused\n", 1, true) and
      said:find("unwritten\n", 1, true), said)
  assert(not said:find("\nout\n", 1, true), said)
  local mine = assert(sys.open(outside .. "/f", sys.O_RDONLY))
  assert(sys.read(mine, 16) == "out")
  sys.close(mine)
  -- A directory given to write is written; a ruleset whose descriptor is
  -- the one just above the child's own -- where the exec status goes --
  -- still holds it.
  assert(sys.mkdir(tmp .. "/w", 0x1c0))
  local writing = assert(process.landlock_ruleset(reads, { tmp .. "/w" }))
  local report = create(tmp .. "/report")
  -- A free descriptor from 4 to 10, the child's own ending below it.
  local free = 10
  while free > 4 and sys.fstat(free) ~= nil do free = free - 1 end
  assert(sys.fstat(free) == nil, "no descriptor from 4 to 10 is free")
  assert(sys.dup2(writing, free))
  sys.close(writing)
  local own = tostring(free - 1)
  local wrote = assert(process.spawn(probe, { probe,
    "append w/f w && write-fd " .. own .. " w-written; append in/h x || write-fd " .. own .. " held" },
    nil, tmp, nil, nil, nil, false, { [free - 1] = report }, { ruleset = free }))
  sys.close(free)
  assert(assert(process.waitpid(wrote, false)).code == 0)
  local reported = assert(sys.pread(report, 4096, 0))
  sys.close(report)
  assert(reported == "w-written\nheld\n", reported)
  local fd = assert(sys.open(tmp .. "/w/f", sys.O_RDONLY))
  assert(sys.read(fd, 16) == "w\n")
  sys.close(fd)
  local bad, bad_trouble = process.landlock_ruleset({ tmp .. "/nowhere" }, {})
  assert(bad == nil and bad_trouble ~= "", "a path that is not there refuses the ruleset")
end

--- Runs a child held to a ruleset of its own program alone, whose `script`
--- connects to the listener `listen` makes at `tmp`/s, and checks it did.
local function connects_through_a_ruleset(tmp: string, listen: function(string): Net.Listener,
                                          script: function(Net.Listener, string): string)
  local probe = probe_in(tmp)
  local socket = tmp .. "/s"
  local listener = listen(socket)
  local ruleset, trouble = process.landlock_ruleset({ probe }, {})
  if ruleset == nil then
    assert(listener:close())
    Test.skip("the kernel gives no Landlock ruleset: " .. tostring(trouble))
  end
  local output = create(tmp .. "/said")
  local pid = assert(process.spawn(probe, { probe, script(listener, socket) },
    nil, tmp, nil, output, output, false, nil, { ruleset = ruleset }))
  sys.close(ruleset)
  local status = assert(process.waitpid(pid, false))
  local said = assert(sys.pread(output, 4096, 0))
  sys.close(output)
  assert(status.code == 0 and said == "connected\n", said)
  assert(assert(listener:accept()):close())
  assert(listener:close())
end

--- A ruleset holds files and not the network, on every kernel: a child
--- held to one reaches a listener of this process's over TCP on
--- loopback, as one held to none does.
local function test_a_landlock_ruleset_leaves_a_child_its_loopback(tmp: string)
  connects_through_a_ruleset(tmp, function(_socket: string): Net.Listener
    return (assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = Clock.seconds(5) })))
  end, function(listener: Net.Listener, _socket: string): string
    return "connect-tcp 127.0.0.1 " .. tostring(listener.address.port)
  end)
end

--- The same over a unix socket file.
local function test_a_landlock_ruleset_leaves_a_child_its_unix_socket(tmp: string)
  if unix_socket.skipped(tmp) then return end
  connects_through_a_ruleset(tmp, function(socket: string): Net.Listener
    return (assert(Net.listen(Net.unix(socket), { timeout_ns = Clock.seconds(5) })))
  end, function(_listener: Net.Listener, socket: string): string
    return "connect " .. socket
  end)
end

--- A process held to running what is beneath some paths runs a program
--- beneath them and no other -- one written after the hold included --
--- and what it starts is held too; it still reads and writes as before.
--- The hold is for good, so it is taken last: this test's worker ends
--- with the test.
local function test_a_process_held_to_running_some_paths_runs_nothing_else(tmp: string)
  -- The program beneath a path given, and a copy of it beneath none.
  local built = probe_in(tmp)
  local probe, elsewhere = tmp .. "/bin/probe", tmp .. "/elsewhere/run"
  assert(sys.mkdir(tmp .. "/bin", 0x1c0) and sys.mkdir(tmp .. "/elsewhere", 0x1c0))
  assert(stand_in.place(built, probe))
  assert(stand_in.place(built, elsewhere))
  local function status_of(path: string, argv: {string}): integer | string
    local pid, trouble = process.spawn(path, argv, nil, tmp, nil, nil, nil, false)
    if pid == nil then return trouble end
    return assert(process.waitpid(pid, false)).code
  end
  assert(status_of(elsewhere, { elsewhere, "exit 0" }) == 0, "the copy runs before the hold")
  -- Beneath a path given, a file may still move to another directory.
  local given = tmp .. "/given"
  assert(sys.mkdir(given, 0x1c0) and sys.mkdir(given .. "/a", 0x1c0) and
      sys.mkdir(given .. "/b", 0x1c0))
  sys.close(create(given .. "/a/f"))
  local held, trouble, errno = process.landlock_restrict_execute({ tmp .. "/bin", given })
  if not held then
    assert(errno == sys.ENOSYS or errno == sys.EOPNOTSUPP or errno == sys.EPERM, trouble)
    Test.skip("the kernel gives no Landlock: " .. tostring(trouble))
  end
  assert(status_of(probe, { probe, "exit 3" }) == 3, "a program beneath them runs")
  assert(status_of(elsewhere, { elsewhere, "exit 0" }) ~= 0, "a program elsewhere ran")
  -- What it starts is held too: the program may not run the copy.
  assert(status_of(probe, { probe, "run " .. elsewhere .. " || exit 7" }) == 7)
  assert(sys.rename(given .. "/a/f", given .. "/b/f"))
  -- So may one in a directory made after the hold, beneath none -- but
  -- not into one where it could be run, which it could not before.
  local later = tmp .. "/later"
  assert(sys.mkdir(later, 0x1c0) and sys.mkdir(later .. "/a", 0x1c0))
  sys.close(create(later .. "/f"))
  assert(sys.rename(later .. "/f", later .. "/a/f"))
  local moved, _, moved_errno = sys.rename(later .. "/a/f", given .. "/a/f")
  assert(not moved and moved_errno == sys.EXDEV, "a file moved to where it could be run")
  -- Reading and writing are as they were.
  local written = create(tmp .. "/after")
  assert(sys.write(written, "w") == 1)
  sys.close(written)
  local reading = assert(sys.open(elsewhere, sys.O_RDONLY))
  assert(sys.read(reading, 4) == "\x7fELF")
  sys.close(reading)
  local bad, _ = pcall(process.landlock_restrict_execute, { 1 } as {string})
  assert(not bad, "a path that is no string is refused")
end
