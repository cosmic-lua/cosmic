--- The descriptor a portable start retains on its artifact -- through
--- which core/vfs.c reads the database the program carries -- is no
--- Lua program's: every binding that takes a descriptor refuses it
--- (core/check.h's `cosmic_checkfd`), and so does an open that would
--- reach it through /proc/<pid>/fd or /dev/fd. Without that a test
--- would read every module the program carries, past
--- build/test_worker.tl's hold on the store and past every key.
---
--- The worker that runs these is itself such a start (`cosmic test`
--- relaunches this program), so each test here has the descriptor to
--- try; where it runs from no portable artifact, there is none, and
--- each returns unchecked.

local sys = require("cosmic.sys")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local gen_syscalls = require("build.gen_syscalls")
local _child = require("cosmic.child")
local type raw_process = require("cosmic.internal.process")

--- The binding headers, read for which of their bindings take a
--- descriptor.
Test.needs{
  reads = { "core/syscalls.h", "core/process.h" },
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

--- The descriptor this process retains on its artifact, or nil for a
--- start from none: the one `Proc.relaunch` hands a child as its own.
local function artifact_fd(): integer | nil
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil then return nil end
  local slot = math.tointeger(tonumber(relaunch.env.COSMIC_PORTABLE_ARTIFACT_FD))
  return slot ~= nil and relaunch.fds[slot] or nil
end

--- Asserts calling `fn` with `...` raises, naming the artifact's
--- descriptor.
local function refused(what: string, fn: any, ...: any)
  local ok, why = pcall(fn as function(any...): (any...), ...)
  assert(not ok, what .. " took the artifact's retained descriptor")
  assert(tostring(why):find("retained artifact descriptor", 1, true) ~= nil,
    what .. " raised for another reason: " .. tostring(why))
end

--- Each binding that takes a descriptor, as the arguments that put `fd`
--- at argument `at`, one of the positions its declaration names a
--- descriptor (build.gen_syscalls's `descriptor`). Each call is refused before it does
--- anything, so the other arguments need only be well formed.
local cases: {string: function(at: integer, fd: integer): {any}} = {
  close = function(_: integer, fd: integer): {any} return { fd } end,
  read = function(_: integer, fd: integer): {any} return { fd, 1 } end,
  pread = function(_: integer, fd: integer): {any} return { fd, 1, 0 } end,
  write = function(_: integer, fd: integer): {any} return { fd, "" } end,
  lseek = function(_: integer, fd: integer): {any} return { fd, 0, sys.SEEK_CUR } end,
  fstat = function(_: integer, fd: integer): {any} return { fd } end,
  dup = function(_: integer, fd: integer): {any} return { fd } end,
  dup2 = function(at: integer, fd: integer): {any}
    if at == 1 then return { fd, 0 } end
    return { 0, fd }
  end,
  fd_flags = function(_: integer, fd: integer): {any} return { fd } end,
  isatty = function(_: integer, fd: integer): {any} return { fd } end,
  fsync = function(_: integer, fd: integer): {any} return { fd } end,
  ftruncate = function(_: integer, fd: integer): {any} return { fd, 0 } end,
  set_nonblocking = function(_: integer, fd: integer): {any} return { fd, false } end,
  poll = function(_: integer, fd: integer): {any} return { { fd }, { process.POLLIN }, 0 } end,
  spawn = function(at: integer, fd: integer): {any}
    local args: {any} = { "/nonexistent/program", { "program" }, nil, nil, nil, nil, nil, false,
      nil, nil }
    if at == 9 then args[9] = { [3] = fd } else args[at] = fd end
    return args
  end,
}

--- The bindings whose parameters `descriptor` names but that are
--- no descriptors of this process, as build/c/rules.tl exempts them.
local not_descriptors: {string: boolean} = {
  relaunch = true, -- the numbers the child is to see its descriptors as
}

--- Every binding core/syscalls.h and core/process.h declare to take a
--- descriptor refuses the artifact's at each such argument -- and one
--- declared from here on fails this test until it has a case above.
local function test_every_descriptor_argument_refuses_the_artifact_descriptor()
  local fd = artifact_fd()
  if fd == nil then return end
  local tables: {string: {string: any}} = {
    ["cosmic.sys"] = sys as {string: any}, -- cast: the table core/syscalls.h declares
    ["cosmic.internal.process"] = process as {string: any}, -- cast: core/process.h's
  }
  local missing: {string} = {}
  local tried = 0
  for _, derivation in ipairs(gen_syscalls.targets) do
    local header = assert(Fs.read(derivation.target.header))
    local found = assert(gen_syscalls.read(header))
    for _, call in ipairs(found.calls) do
      for at, parameter in ipairs(call.parameters) do
        if gen_syscalls.descriptor(parameter) and
            not not_descriptors[call.name] then
          local case = cases[call.name]
          if case == nil then
            missing[#missing + 1] = call.name
          else
            local binding = tables[derivation.path][call.name]
            local args = case(at, fd)
            refused(call.name .. "'s argument " .. at, binding, table.unpack(args, 1, 10))
            tried = tried + 1
          end
        end
      end
    end
  end
  assert(#missing == 0, "bindings that take a descriptor with no case here: " ..
    table.concat(missing, ", "))
  assert(tried >= 18, "only " .. tried .. " descriptor arguments were tried")
end

--- A sandbox's ruleset is a descriptor too, and refused.
local function test_a_ruleset_that_is_the_artifact_descriptor_is_refused()
  local fd = artifact_fd()
  if fd == nil then return end
  refused("spawn's ruleset", process.spawn, "/nonexistent/program", { "program" }, nil, nil,
    nil, nil, nil, false, nil, { ruleset = fd })
end

--- The artifact's descriptor is handed on only as `Proc.relaunch` hands
--- it: as the descriptor the child's environment names its artifact's
--- -- elsewhere in the map, or with no such environment, it is refused
--- -- and only by a process that may still run this program: a
--- sandboxed worker whose module does not declare `tool`, as this one
--- does not, is held from running it (build/confine.tl's
--- `forbid_running`), and refused it even so. That a relaunch's own map
--- is taken, every start of this program through `build.this_program`
--- shows -- core/syscalls_test.tl hands one to `process.spawn` itself,
--- a `#!` line and `setsid` among them -- and every worker `cosmic test`
--- starts.
local function test_spawn_hands_the_artifact_descriptor_on_only_to_a_relaunch()
  local fd = artifact_fd()
  if fd == nil then return end
  local relaunch = assert(Proc.relaunch())
  local core = relaunch.argv[1]
  local env: {string: string} = {}
  for name, value in pairs(relaunch.env) do env[name] = value end
  local slot = math.tointeger(tonumber(env.COSMIC_PORTABLE_ARTIFACT_FD)) as integer
  refused("a map to another slot", process.spawn, core, { core }, env, nil, nil, nil, nil,
    false, { [slot - 1] = fd })
  refused("a map with no environment", process.spawn, core, { core }, nil, nil, nil, nil, nil,
    false, { [slot] = fd })
  if sys.getcwd() == "/tree" then
    refused("a relaunch's map, held from running the program", process.spawn, core, { core },
      env, nil, nil, nil, nil, false, { [slot] = fd })
  end
end

--- An open that reaches the artifact through a descriptor link --
--- /proc/self/fd/<it>, /dev/fd/<it>, or a link to either -- is refused
--- as a permission; one of any other descriptor still opens.
local function test_an_open_through_the_artifact_descriptor_is_refused(tmp: string)
  local fd = artifact_fd()
  if fd == nil then return end
  local plain = tmp .. "/plain"
  assert(Fs.write(plain, "text"))
  local other = assert(sys.open(plain, sys.O_RDONLY))
  for _, dir in ipairs({ "/proc/self/fd/", "/dev/fd/" }) do
    if sys.stat(dir .. other) ~= nil then
      local opened, trouble, errno = sys.open(dir .. fd, sys.O_RDONLY)
      assert(opened == nil and errno == sys.EACCES, dir .. " opened the artifact: " ..
        tostring(opened) .. " " .. tostring(trouble))
      local link = tmp .. "/link"
      sys.unlink(link)
      assert(sys.symlink(dir .. fd, link))
      local linked, _, linked_errno = sys.open(link, sys.O_RDONLY)
      assert(linked == nil and linked_errno == sys.EACCES, "a link to " .. dir ..
        " opened the artifact")
      local again = assert(sys.open(dir .. other, sys.O_RDONLY))
      assert(sys.read(again, 16) == "text")
      assert(sys.close(again))
    end
  end
  assert(sys.close(other))
end

--- A call that would change the program through a descriptor link is
--- refused before it changes anything: an open to write, to truncate
--- or to create, a chmod, a change of its times. Each is tried so that,
--- were it let through, it would change nothing -- an open to write
--- with nothing written, the mode and times it has already -- until
--- the truncation, tried only once an open to write was refused.
local function test_a_change_through_the_artifact_descriptor_changes_nothing()
  local fd = artifact_fd()
  if fd == nil then return end
  local link = "/proc/self/fd/" .. fd
  if sys.stat(link) == nil then link = "/dev/fd/" .. fd end
  local seen = sys.stat(link)
  if seen == nil then return end
  local before: sys.Stat = seen
  local function unchanged(what: string)
    local now = assert(sys.stat(link))
    assert(now.size == before.size and now.mode == before.mode and
      now.mtime == before.mtime and now.mtime_ns == before.mtime_ns and
      now.ino == before.ino, what .. " changed the program")
  end
  local function refused_open(what: string, flags: integer)
    local opened, trouble, errno = sys.open(link, flags, 420)
    if opened ~= nil then sys.close(opened) end
    assert(opened == nil and errno == sys.EACCES, what .. " opened the artifact: " ..
      tostring(opened) .. " " .. tostring(trouble))
    unchanged(what)
  end
  refused_open("an open to write", sys.O_WRONLY)
  refused_open("an open to read and write", sys.O_RDWR)
  refused_open("an open to create", sys.O_CREAT | sys.O_WRONLY)
  refused_open("an open to truncate", sys.O_WRONLY | sys.O_TRUNC)
  local chmodded, _, chmod_errno = sys.chmod(link, before.mode & 4095)
  assert(not chmodded and chmod_errno == sys.EACCES, "chmod reached the artifact")
  unchanged("chmod")
  -- A link's own times, not followed: its target's are not reached.
  local _, _ = sys.utimensat(link, before.mtime, before.mtime_ns, before.mtime,
    before.mtime_ns)
  unchanged("utimensat")
end

--- Every other descriptor is used as before.
local function test_other_descriptors_still_work(tmp: string)
  local path = tmp .. "/file"
  local fd = assert(sys.open(path, sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420))
  assert(sys.write(fd, "hello") == 5)
  assert(sys.lseek(fd, 0, sys.SEEK_SET) == 0)
  assert(sys.read(fd, 16) == "hello")
  assert(sys.pread(fd, 3, 1) == "ell")
  assert(assert(sys.fstat(fd)).size == 5)
  local copy = assert(sys.dup(fd))
  assert(sys.fd_flags(copy) ~= nil)
  assert(sys.dup2(fd, copy))
  assert(sys.fsync(copy))
  assert(sys.ftruncate(copy, 2))
  assert(sys.pread(fd, 16, 0) == "he")
  assert(not sys.isatty(fd))
  assert(process.set_nonblocking(fd, true))
  assert(#assert(process.poll({ fd }, { process.POLLIN }, 0)) == 1)
  assert(sys.close(copy))
  assert(sys.close(fd))
end

--- A sandboxed worker whose test does not declare `tool`, as this one's
--- does not, has no name to read the program by: only its core, which
--- carries no database (build/confine.tl's `worker_unveil`).
local function test_a_worker_that_is_not_a_tool_cannot_open_the_program()
  local program, _ = Proc.executable()
  if program == nil or artifact_fd() == nil or sys.getcwd() ~= "/tree" then return end
  local opened, _ = sys.open(program, sys.O_RDONLY)
  assert(opened == nil, "a worker that is not a tool opened " .. program)
end
