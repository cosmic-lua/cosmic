--- The raw process table's Landlock hold on what may run (core/process.h's
--- `landlock_restrict_execute`) on a live process, as core/syscalls_test.tl states the rest of
--- the table. They need a kernel with Landlock, which no other platform
--- has: where the platform lacks one the refusal is
--- core/syscalls_test.tl's, and where this Linux host refuses it the tests
--- are not run (`requires`) or, where only the call can tell, skipped
--- (Test.skip).

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local stand_in = require("build.stand_in")
-- Required, so the module whose loader is handed the raw table is of this
-- test's import closure, and the store has it to hand it from.
local type _ = require("cosmic.child")

--- /proc, as core/syscalls_test.tl declares it.
Test.policy{
  profiles = { "proc" },
  requires = { "landlock" },
}

local process = require("cosmic.internal.process")

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
  local bad, _ = pcall(process.landlock_restrict_execute, { 1 } as {string}) -- checked: cast_refused
  assert(not bad, "a path that is no string is refused")
end
