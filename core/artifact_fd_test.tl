--- The descriptor a portable start retains on its artifact -- through
--- which core/vfs.c reads the database the program carries -- is no
--- Lua program's: every binding that takes a descriptor refuses it
--- (core/check.h's `cosmic_checkfd`), and so does an open that would
--- reach it through /proc/<pid>/fd or /dev/fd. Without that a test
--- would read every module the program carries, past every key.
---
--- The worker that runs these is itself such a start (`cosmic test`
--- relaunches this program), so each test here has the descriptor to
--- try; where it runs from no portable artifact, there is none, and
--- each returns unchecked.

local sys = require("cosmic.sys")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local gen_syscalls = require("build.gen_syscalls")
local _child = require("cosmic.child")
local _net = require("cosmic.net")

--- The binding headers, read for which of their bindings take a
--- descriptor.
-- Declared for the program's descriptor, which only a worker that runs the
-- whole program holds: one on a sealed database has none, so each test here
-- would skip, and no test would enter the bindings it tries.
Test.policy{
  grants = {
    { path = "core/syscalls.h", letters = "r" },
    { path = "core/process.h", letters = "r" },
    { path = "core/socket.h", letters = "r" },
    { path = "o/cosmic.db", letters = "r" },
  },
}

local process = require("cosmic.internal.process")
local socket = require("cosmic.internal.socket")

--- The descriptor this process retains on its artifact, or nil for a
--- start from none: the one [`Proc.relaunch`] hands a child as its own.
local function artifact_fd(): integer?
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil then return nil end
  local slot = math.tointeger(tonumber(relaunch.env["COSMIC_PORTABLE_ARTIFACT_FD"]))
  local fd = slot ~= nil and relaunch.fds[slot] or nil -- checked: and_ternary
  -- A held (sandboxed) worker of a portable run has the descriptor; one
  -- on a sealed database does not, and would check nothing.
  if fd == nil and relaunch.argv[2] == "--database" then
    error("this worker runs on a sealed database, which has no artifact descriptor to try")
  end
  return fd
end

--- The retained artifact descriptor, skipping the test where this start
--- retains none (a host program, or a native start).
local function artifact_fd_or_skip(): integer
  local fd = artifact_fd()
  if fd == nil then Test.skip("this start retains no portable artifact descriptor") end
  local held = assert(fd, "Test.skip ends the test where this start retains no descriptor")
  return held
end

--- Asserts calling `fn` raises, naming the artifact's descriptor.
local function refused(what: string, fn: function())
  local ok, why = pcall(fn)
  assert(not ok, what .. " took the artifact's retained descriptor")
  assert(tostring(why):find("retained artifact descriptor", 1, true) ~= nil,
    what .. " raised for another reason: " .. tostring(why))
end

--- Each binding that takes a descriptor, as a call that puts `fd` at
--- argument `at`, one of the positions its declaration names a
--- descriptor (build.gen_syscalls's `descriptor`). Each call is refused before it does
--- anything, so the other arguments need only be well formed.
local cases: {string: function(at: integer, fd: integer)} = {
  close = function(_: integer, fd: integer) sys.close(fd) end,
  read = function(_: integer, fd: integer) sys.read(fd, 1) end,
  pread = function(_: integer, fd: integer) sys.pread(fd, 1, 0) end,
  write = function(_: integer, fd: integer) sys.write(fd, "") end,
  lseek = function(_: integer, fd: integer) sys.lseek(fd, 0, sys.SEEK_CUR) end,
  fstat = function(_: integer, fd: integer) sys.fstat(fd) end,
  dup = function(_: integer, fd: integer) sys.dup(fd) end,
  dup2 = function(at: integer, fd: integer)
    if at == 1 then sys.dup2(fd, 0) else sys.dup2(0, fd) end
  end,
  fd_flags = function(_: integer, fd: integer) sys.fd_flags(fd) end,
  isatty = function(_: integer, fd: integer) sys.isatty(fd) end,
  ttyname = function(_: integer, fd: integer) sys.ttyname(fd) end,
  tcgetattr = function(_: integer, fd: integer) sys.tcgetattr(fd) end,
  -- The descriptor is checked before the opaque terminal state's length.
  tcsetattr = function(_: integer, fd: integer) sys.tcsetattr(fd, "") end,
  tcraw = function(_: integer, fd: integer) sys.tcraw(fd) end,
  tcflush = function(_: integer, fd: integer) sys.tcflush(fd) end,
  winsize = function(_: integer, fd: integer) sys.winsize(fd) end,
  setwinsize = function(_: integer, fd: integer) sys.setwinsize(fd, 24, 80) end,
  controlling_terminal = function(_: integer, fd: integer) sys.controlling_terminal(fd) end,
  fsync = function(_: integer, fd: integer) sys.fsync(fd) end,
  full_fsync = function(_: integer, fd: integer) sys.full_fsync(fd) end,
  ftruncate = function(_: integer, fd: integer) sys.ftruncate(fd, 0) end,
  flock = function(_: integer, fd: integer) sys.flock(fd, "exclusive") end,
  flock_kind = function(_: integer, fd: integer) sys.flock_kind(fd) end,
  set_nonblocking = function(_: integer, fd: integer) sys.set_nonblocking(fd, false) end,
  fd_status = function(_: integer, fd: integer) sys.fd_status(fd) end,
  connector_start = function(_: integer, fd: integer)
    process.connector_start({ { host = "127.0.0.1", port = 1 } }, fd, 1, nil)
  end,
  connector_filter = function(at: integer, fd: integer)
    if at == 3 then
      process.connector_filter("x86_64", { { base = 128, slots = 1, length = 16 } }, fd, 0)
    else
      process.connector_filter("x86_64", { { base = 128, slots = 1, length = 16 } }, 0, fd)
    end
  end,
  accept = function(_: integer, fd: integer) socket.accept(fd) end,
  adopt = function(_: integer, fd: integer) socket.adopt(fd) end,
  send = function(_: integer, fd: integer) socket.send(fd, "") end,
  sendfds = function(at: integer, fd: integer)
    if at == 1 then socket.sendfds(fd, { 0 }) else socket.sendfds(0, { fd }) end
  end,
  recvfds = function(_: integer, fd: integer) socket.recvfds(fd, 1) end,
  sendto = function(_: integer, fd: integer)
    socket.sendto(fd, "", { kind = "udp", host = "127.0.0.1", port = 1 })
  end,
  recvfrom = function(_: integer, fd: integer) socket.recvfrom(fd, 1) end,
  bound = function(_: integer, fd: integer) socket.bound(fd) end,
  peer = function(_: integer, fd: integer) socket.peer(fd) end,
  connected = function(_: integer, fd: integer) socket.connected(fd) end,
  shutdown = function(_: integer, fd: integer) socket.shutdown(fd, "both") end,
  wait = function(_: integer, fd: integer) socket.wait(fd, false, 0) end,
  poll = function(_: integer, fd: integer) sys.poll({ fd }, { sys.POLLIN }, 0) end,
  restrict_self = function(_: integer, fd: integer)
    process.restrict_self({ grants = {}, promises = {}, rlimits = {} }, { fd })
  end,
  spawn = function(at: integer, fd: integer)
    -- The argument at `at` is `fd` (inside a table at 9, the fds map), every other optional one nil.
    local program, argv = "/nonexistent/program", { "program" }
    if at == 5 then
      process.spawn(program, argv, nil, nil, fd)
    elseif at == 6 then
      process.spawn(program, argv, nil, nil, nil, fd)
    elseif at == 7 then
      process.spawn(program, argv, nil, nil, nil, nil, fd)
    elseif at == 9 then
      process.spawn(program, argv, nil, nil, nil, nil, nil, false, { [3] = fd })
    else
      error("spawn takes no descriptor at argument " .. tostring(at))
    end
  end,
}

--- The bindings whose parameters `descriptor` names but that are
--- no descriptors of this process, as build/c/rules.tl exempts them.
local not_descriptors: {string: boolean} = {
  relaunch = true, -- the numbers the child is to see its descriptors as
}

--- Every binding core/syscalls.h, core/process.h and core/socket.h declare to take a
--- descriptor refuses the artifact's at each such argument -- and one
--- declared from here on fails this test until it has a case above.
local function test_every_descriptor_argument_refuses_the_artifact_descriptor()
  local fd = artifact_fd_or_skip()
  local missing: mut {string} = {}
  local tried = 0
  for _, derivation in ipairs(gen_syscalls.targets) do
    local header = assert(Fs.read(derivation.target.header))
    local found = assert(gen_syscalls.read(header))
    for _, call in ipairs(found.calls) do
      for at, parameter in ipairs(call.parameters) do
        if gen_syscalls.descriptor(parameter) and
            not_descriptors[call.name] ~= true then
          local case = cases[call.name]
          if case == nil then
            missing[#missing + 1] = call.name
          else
            refused(call.name .. "'s argument " .. tostring(at), function() case(at, fd) end)
            tried = tried + 1
          end
        end
      end
    end
  end
  assert(#missing == 0, "bindings that take a descriptor with no case here: " ..
      table.concat(missing, ", "))
  assert(tried >= 18, "only " .. tostring(tried) .. " descriptor arguments were tried")
end

--- A lookup's `supply`, a method the table walk above does not reach,
--- refuses the artifact's descriptor as the socket for a parked connect.
local function test_a_lookup_refuses_the_retained_artifact_as_a_supplied_socket(tmp: string)
  local fd = artifact_fd_or_skip()
  if assert(sys.uname()).sysname ~= "Linux" then
    Test.skip("a lookup through a connector is Linux only")
  end
  local hosts = tmp .. "/hosts"
  assert(Fs.write(hosts, ""))
  local lookup <close> = assert(socket.lookup("artifact.example.test", 1000, nil, hosts,
    { { host = "127.0.0.1", port = 53, index = 1 } }))
  local _, _, _, _, wants = lookup:step(nil, nil)
  assert(#wants == 1)
  local want = assert(wants[1], "the lookup wants one socket")
  refused("Lookup:supply", function() lookup:supply(want.id, fd, nil) end)
end

local function test_a_descriptor_batch_refuses_the_retained_artifact_as_payload()
  local fd = artifact_fd_or_skip()
  refused("a descriptor batch payload", function() socket.sendfds(0, { fd }) end)
end

--- A sandbox's ruleset is a descriptor too, and refused.
local function test_a_ruleset_that_is_the_artifact_descriptor_is_refused()
  local fd = artifact_fd_or_skip()
  refused("spawn's ruleset", function()
    process.spawn("/nonexistent/program", { "program" }, nil, nil, nil, nil, nil, false, nil, { ruleset = fd })
  end)
end

--- The artifact's descriptor is handed on only as [`Proc.relaunch`] hands
--- it: as the descriptor the child's environment names its artifact's
--- -- elsewhere in the map, or with no such environment, it is refused
--- -- and only by a process that may still run this program: a
--- sandboxed worker whose module does not declare `tool`, as this one
--- does not, is held from running it (build/confine.tl's
--- `forbid_running`), and refused it even so. That a relaunch's own map
--- is taken, every start of this program through [`build.this_program`]
--- shows -- core/syscalls_test.tl hands one to [`process.spawn`] itself,
--- a `#!` line and `setsid` among them -- and every worker `cosmic test`
--- starts.
local function test_spawn_hands_the_artifact_descriptor_on_only_to_a_relaunch()
  local fd = artifact_fd_or_skip()
  local relaunch = assert(Proc.relaunch())
  local core = assert(relaunch.argv[1])
  local env: mut {string: string} = {}
  for name, value in pairs(relaunch.env) do env[name] = value end
  local slot = math.tointeger(tonumber(env["COSMIC_PORTABLE_ARTIFACT_FD"])) as integer -- checked: cast_refused
  refused("a map to another slot", function()
    process.spawn(core, { core }, env, nil, nil, nil, nil, false, { [slot - 1] = fd })
  end)
  refused("a map with no environment", function()
    process.spawn(core, { core }, nil, nil, nil, nil, nil, false, { [slot] = fd })
  end)
  if sys.getcwd() == "/tree" then
    refused("a relaunch's map, held from running the program", function()
      process.spawn(core, { core }, env, nil, nil, nil, nil, false, { [slot] = fd })
    end)
  end
end

--- An open that reaches the artifact through a descriptor link --
--- /proc/self/fd/<it>, /dev/fd/<it>, or a link to either -- is refused
--- as a permission; one of any other descriptor still opens.
local function test_an_open_through_the_artifact_descriptor_is_refused(tmp: string)
  local fd = artifact_fd_or_skip()
  local plain = tmp .. "/plain"
  assert(Fs.write(plain, "text"))
  local other = assert(sys.open(plain, sys.O_RDONLY))
  for _, dir in ipairs({ "/proc/self/fd/", "/dev/fd/" }) do
    if sys.stat(dir .. tostring(other)) ~= nil then
      -- As given, spelled otherwise, through a link to it or to its
      -- directory: each refused, EACCES.
      local link, directory = tmp .. "/link", tmp .. "/directory"
      sys.unlink(link)
      sys.unlink(directory)
      assert(sys.symlink(dir .. tostring(fd), link))
      assert(sys.symlink(dir:sub(1, -2), directory))
      for _, name in ipairs({ dir .. tostring(fd), "/" .. dir .. tostring(fd), "/." .. dir .. tostring(fd), link,
          directory .. "/" .. tostring(fd) }) do
        local opened, trouble, errno = sys.open(name, sys.O_RDONLY)
        if opened ~= nil then sys.close(opened) end
        assert(opened == nil and errno == sys.EACCES, name .. " opened the artifact: " ..
            tostring(opened) .. " " .. tostring(trouble))
      end
      -- Through a thread's own descriptors, by name and relative to its
      -- directory.
      local pid = tostring(sys.getpid())
      if dir == "/proc/self/fd/" then
        for _, name in ipairs({ "/proc/thread-self/fd/" .. tostring(fd),
            "/proc/" .. pid .. "/task/" .. pid .. "/fd/" .. tostring(fd) }) do
          if sys.stat(name) ~= nil then
            local opened, trouble, errno = sys.open(name, sys.O_RDONLY)
            if opened ~= nil then sys.close(opened) end
            assert(opened == nil and errno == sys.EACCES, name .. " opened the artifact: " ..
                tostring(opened) .. " " .. tostring(trouble))
          end
        end
        local here, _ = sys.getcwd()
        if sys.chdir("/proc/" .. pid .. "/task/" .. pid) then
          local task, _, task_errno = sys.open("fd/" .. tostring(fd), sys.O_RDONLY)
          if task ~= nil then sys.close(task) end
          assert(sys.chdir(assert(here)))
          assert(task == nil and task_errno == sys.EACCES,
            "a name relative to a task opened the artifact")
        end
      end
      local moved, _ = sys.getcwd()
      if sys.chdir(dir) then
        local relative, _, relative_errno = sys.open(tostring(fd), sys.O_RDONLY)
        if relative ~= nil then sys.close(relative) end
        assert(sys.chdir(assert(moved)))
        assert(relative == nil and relative_errno == sys.EACCES,
          "a name relative to " .. dir .. " opened the artifact")
      end
      local again = assert(sys.open(dir .. tostring(other), sys.O_RDONLY))
      assert(sys.read(again, 16) == "text")
      assert(sys.close(again))
    end
  end
  assert(sys.close(other))
end

--- A call that would change the program through a descriptor link --
--- an open to write, chmod -- is tried in core/artifact_fd_tool_test.tl,
--- on a child whose artifact is a copy, so a regression damages only
--- the copy.

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
  assert(sys.set_nonblocking(fd, true))
  assert((assert(sys.fd_status(fd))) & sys.O_NONBLOCK ~= 0)
  assert(#assert(sys.poll({ fd }, { sys.POLLIN }, 0)) == 1)
  assert(sys.close(copy))
  assert(sys.close(fd))
end

--- A sandboxed worker whose test does not declare `tool`, as this one's
--- does not, has no name to read the program by: only its core, which
--- carries no database (build/confine.tl's `worker_unveil`).
local function test_a_worker_that_is_not_a_tool_cannot_open_the_program()
  artifact_fd_or_skip()
  if sys.getcwd() ~= "/tree" then Test.skip("this worker's root is not the sandbox's /tree") end
  local program = assert(Proc.executable())
  local opened, _ = sys.open(program, sys.O_RDONLY)
  assert(opened == nil, "a worker that is not a tool opened " .. program)
end

--- `path` as a `file:` URI's path: every byte but an unreserved one or a
--- slash percent-escaped.
local function escaped(path: string): string
  return (path:gsub("[^%w/%-%._~]", function(c: string): string
    return string.format("%%%02X", (assert(c:byte(), "a matched byte")))
  end))
end

--- The program's database opens through core/vfs.c once, at start: a
--- later connection naming the program's path through that VFS -- raw
--- SQL's ATTACH, which reads a `file:` URI's `vfs=` on a connection
--- opened for URIs, as an immutable one is -- is refused every time, so
--- a test reads no module past build/test_worker.tl's hold on the
--- store. An ordinary database still attaches on the same connection.
local function test_the_program_s_database_cannot_be_reopened(tmp: string)
  artifact_fd_or_skip()
  local program = assert(Proc.executable())
  local path = tmp .. "/plain.db"
  local writer = assert(Sqlite.open(path, { writable = true }))
  assert(writer:exec("CREATE TABLE t (v TEXT)"))
  assert(writer:close())
  local db = assert(Sqlite.open(path, { immutable = true }))
  local uri = "file:" .. escaped(program) .. "?vfs=cosmic&mode=ro&immutable=1"
  for _ = 1, 2 do
    local ok, trouble = db:exec("ATTACH '" .. uri .. "' AS program")
    assert(not ok, "reopened the program's database through " .. uri)
    assert(trouble ~= nil and trouble ~= "", "a refusal says why") -- checked: compare_disjoint
  end
  assert(db:exec("ATTACH 'file:" .. escaped(path) .. "?mode=ro' AS ordinary"))
  assert(db:exec("SELECT count(*) FROM ordinary.t"))
  assert(db:close())
end
