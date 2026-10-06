--- The cases of core/syscalls_tool_test.tl that need no sandbox: what a
--- start refuses as an argument before it makes one, what a platform with
--- no sandbox answers a start that asks for one, and an exit watch, which
--- starts this very program to run a chunk. They run on every platform,
--- as the cases that unveil a child's root are Linux's alone.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local type raw_process = require("cosmic.internal.process")
local this_program = require("build.this_program")
local stand_in = require("build.stand_in")

--- The program itself, which the exit watch starts only to run a chunk
--- (`lua`); and `nests`, since a worker held by a Landlock ruleset is
--- refused a start that unveils a root before the start reads its
--- arguments (build.confine's `forbid_running`), and these cases pass
--- such starts to see them refused. The stand-in they name is built in
--- the test's own directory and never started.
Test.policy{
  profiles = { "cosmic" },
  promises = { "nest" },
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

--- The descriptors [`this_program.program`] hands its child, as
--- [`process.spawn`] takes them: each a descriptor of this process, as
--- the relaunch's are, and none "capture", which only [`cosmic.child`]
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

--- A stand-in program built under `tmp` (build/stand_in.tl).
local function probe_in(tmp: string): string
  return (assert(stand_in.build(tmp .. "/stand-in")))
end

--- Whether `sandbox` is refused as an argument, which raises before any
--- start.
local function raises(probe: string, sandbox: raw_process.Sandbox): boolean
  return not pcall(process.spawn, probe, { probe }, nil, nil, nil, nil, nil, false, nil, sandbox)
end

--- A child's `user` is given with its `group` and `unveil`, and is not
--- root.
local function test_a_user_is_refused_unless_given_with_its_group_and_unveil(tmp: string)
  local probe = probe_in(tmp)
  local user = sys.getuid() == 65533 and 65531 or 65533
  for _, sandbox in ipairs({
      { unveil = { reads = { probe }, writes = {} }, user = 0, group = user },
      { unveil = { reads = { probe }, writes = {} }, user = user },
      { offline = true, user = user, group = user },
  } as {raw_process.Sandbox}) do
    assert(raises(probe, sandbox), "a user is refused unless given with its group and unveil, and not as root")
  end
end

--- A bind given `idmap` is a mistake of the caller's without a user.
local function test_an_idmapped_bind_is_refused_without_a_user(tmp: string)
  local probe = probe_in(tmp)
  assert(sys.mkdir(tmp .. "/closed", 0x1c0))
  local ok, trouble = pcall(process.spawn, probe, { probe }, nil, nil, nil, nil, nil, false, nil,
    { unveil = { reads = { probe }, writes = {}, binds = { { path = tmp .. "/closed", idmap = true } } } })
  assert(not ok and tostring(trouble):find("idmap requires a user", 1, true), tostring(trouble))
end

--- An unveiled path is absolute, and a name it is bound at is plain and
--- absolute, is not /, is given for a path unveiled, and is given once;
--- none is beneath the old root's.
local function test_an_unveiled_path_is_absolute_and_bound_at_a_plain_name(tmp: string)
  local probe = probe_in(tmp)
  local tree, scratch = tmp .. "/checkout", tmp .. "/scratch"
  for _, dir in ipairs({ tree, scratch }) do assert(sys.mkdir(dir, 0x1c0)) end
  assert(raises(probe, { unveil = { reads = { "relative" } } }), "an unveiled path must be absolute")
  for _, bad in ipairs({ "relative", "/", "/a/../b", "/a/" }) do
    assert(raises(probe, { unveil = { reads = { tree }, at = { [tree] = bad } } }), "bound at " .. bad)
  end
  assert(raises(probe, { unveil = { reads = { tree }, at = { [scratch] = "/tmp" } } }),
    "at a path not unveiled")
  assert(raises(probe, { unveil = { reads = { tree, scratch }, at = { [tree] = "/x", [scratch] = "/x" } } }),
    "two paths at one name")
  assert(raises(probe, { unveil = { reads = { tree }, at = { [tree] = "/.old/x" } } }),
    "beneath the old root's")
end

--- Where the platform has no sandbox, a start that asks for one is
--- refused with an errno a refusal answers, and no argument that would be
--- accepted on Linux raises. On Linux, whatever this host refuses of the
--- sandbox, these starts are core/syscalls_tool_test.tl's, which requires
--- one: so this returns there, and only the platforms without one answer.
local function test_a_sandbox_the_platform_lacks_is_refused(tmp: string)
  if assert(sys.uname()).sysname == "Linux" then
    Test.skip("a platform with a sandbox answers this where a test requires one")
  end
  local probe = probe_in(tmp)
  local user = sys.getuid() == 65533 and 65531 or 65533
  local sandboxes: {raw_process.Sandbox} = {
    { offline = true },
    { unveil = { reads = { probe } }, offline = true },
    { unveil = { reads = { probe }, writes = { tmp } }, offline = true },
    { unveil = { reads = { probe, tmp }, at = { [tmp] = "/tree" } }, offline = true },
    { unveil = { reads = { probe }, writes = {} }, offline = true, user = user, group = user },
    { strict = true, user = user, group = user, unveil = { reads = { probe }, writes = {},
      binds = { { path = tmp, idmap = true } } } },
    { proc = true, user = user, group = user },
  }
  for index, sandbox in ipairs(sandboxes) do
    local ok, pid, trouble, errno = pcall(process.spawn, probe, { probe, "print hi" }, nil, tmp, nil,
      nil, nil, false, nil, sandbox)
    assert(ok, "a start of a sandbox the platform lacks is refused, not raised, " .. index .. ": " .. tostring(pid))
    assert(pid == nil and (errno == sys.ENOSYS or errno == sys.EPERM or errno == sys.EACCES or
      errno == sys.EINVAL or errno == sys.ENOSPC), index .. ": " .. tostring(trouble))
  end
  assert(not process.subreaper(), "there is no subreaper to be")
end

--- `exit_watch`'s descriptor is readable once its child has exited, and
--- not before; a pid reaped has none to give. The child is this program, reading its stdin to the
--- end: it exits once this process closes the other end.
local function test_an_exit_watch_is_readable_once_its_child_exits()
  local ok, raised = pcall(process.exit_watch, 0)
  assert(not ok and tostring(raised):find("pid is out of range", 1, true), tostring(raised))
  local ends = assert(process.pipe())
  local started = this_program.program({ "-e",
    'local Fs = require("cosmic.fs") while assert(Fs.take(0, 4096)) ~= "" do end' })
  local pid = process.spawn(started.argv[1], started.argv, started.options.env, nil,
    ends.reader, nil, nil, false, spawn_fds(started))
  sys.close(ends.reader)
  assert(pid, "the child did not start")
  local watch = assert(process.exit_watch(pid))
  assert(assert(sys.poll({ watch }, { sys.POLLIN }, 50))[1] == 0,
    "the watch was readable while its child ran")
  sys.close(ends.writer)
  local ready = assert(sys.poll({ watch }, { sys.POLLIN }, 30000))
  assert(ready[1] & sys.POLLIN ~= 0, "the child's exit left its watch unreadable")
  assert(process.waitpid(pid, false))
  sys.close(watch)
  local none, _, errno = process.exit_watch(pid)
  assert(none == nil and errno == sys.ESRCH, "a reaped child's pid was watched")
end

--- A scratch the start makes noexec is refused beneath a target the root
--- already holds, and with an unveiling that shows all of /.
local function test_noexec_scratch_refuses_conflicting_mount_targets(tmp: string)
  -- Only Linux has a noexec scratch to conflict with: elsewhere the start
  -- is refused ENOSYS before the mounts are checked for conflicts, and no
  -- requirement names Linux alone.
  if assert(sys.uname()).sysname ~= "Linux" then return end
  for _, target in ipairs({ "/noexec", "/noexec/inside" }) do
    local pid, trouble, errno = process.spawn("/missing", { "/missing" }, nil, "/",
      nil, nil, nil, false, nil, { noexec_scratch = true, offline = true,
        unveil = { reads = { tmp }, at = { [tmp] = target } } })
    assert(pid == nil and errno == sys.EINVAL, trouble)
  end
  local pid, trouble, errno = process.spawn("/missing", { "/missing" }, nil, "/",
    nil, nil, nil, false, nil, { noexec_scratch = true, offline = true, unveil = { reads = { "/" } } })
  assert(pid == nil and errno == sys.EINVAL, trouble)
end
