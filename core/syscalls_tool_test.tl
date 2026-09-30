--- The cases of core/syscalls_test.tl that start this very program, or
--- read it -- a confined child's end with the program that started it,
--- an offline child's loopback, and the executable's own path -- and
--- those that confine a child in a root of its own (unveiling), which
--- only a worker that declares `nests` can (see `Test.needs` below).

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local type raw_process = require("cosmic.internal.process")
local confine = require("build.confine")
local this_program = require("build.this_program")
local stand_in = require("build.stand_in")
local sandbox_skip = require("build.sandbox_skip")

-- TODO: declare /proc for Linux alone once a declaration can name a
-- host path per platform (a `host` entry for Linux and one for macOS):
-- macOS has no /proc, so there this declares a path that is not there,
-- which gives and keys nothing but says what the tests need wrongly.
--- What these cases are tested on: /proc, the whole environment, which
--- this program started again inherits, and the program itself, which they start and read; and `nests`, since the
--- unveiling cases give a child a root of its own, which a worker held
--- by a Landlock ruleset cannot (build.confine's `forbid_running`).
Test.needs{
  host = { "/proc" },
  env = { "*" },
  tool = true,
  nests = true,
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

--- The descriptors `this_program.program` hands its child, as
--- `process.spawn` takes them: each a descriptor of this process, as
--- the relaunch's are, and none "capture", which only `cosmic.child`
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

--- Says a sandbox test is skipped (`Test.skip`) where this Linux host
--- refuses the sandbox it is about (build.sandbox_skip), as core/syscalls_test.tl's
--- `unsandboxable` does, as it returns early: the run counts it skipped
--- rather than passed, and a run held to sandboxing (COSMIC_SANDBOX=must
--- among them) fails it.
local function unsandboxable(what: string, trouble: string)
  sandbox_skip.refused("the kernel gives no " .. what .. ": " .. tostring(trouble))
end

--- A stand-in program built under `tmp` (build/stand_in.tl).
local function probe_in(tmp: string): string
  return (assert(stand_in.build(tmp .. "/stand-in")))
end

--- What a confined `probe` is given to read: itself, and /proc and
--- /dev/null where this host has them.
local function probe_reads(probe: string): {string}
  local reads: {string} = { probe }
  for _, path in ipairs({ "/proc", "/dev/null" }) do
    if sys.stat(path) ~= nil then reads[#reads + 1] = path end
  end
  return reads
end

--- Opens `path` for writing, creating it, and returns the descriptor.
local function create(path: string): integer
  local fd, trouble = sys.open(path, sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420)
  assert(fd ~= nil, trouble)
  return fd
end

--- What a chunk of this program's starts a confined child with: the
--- raw process table, and the paths it reads, from `...`, colon-joined,
--- the program first.
local chunk_preamble <const> = [==[
local sys = require("cosmic.sys")
local process
for _, searcher in ipairs(package.searchers) do
  local loader, extra = searcher("cosmic.child")
  if type(loader) == "function" and type(extra) == "table" then process = extra end
end
local reads = {}
for path in (...):gmatch("[^:]+") do reads[#reads + 1] = path end
]==]

--- A confined child ends when the process that started it does, killed
--- or ended by a signal from a terminal, not left running on its own:
--- its init ends with its parent, and its namespace with the init. This
--- process takes the orphans, as a subreaper, so no one but the kernel
--- ends them: `cosmic test`'s runner, a subreaper itself, would end any
--- that reached it as strays, and pass this with the init's end undone.
local function test_a_confined_child_ends_with_its_parent(tmp: string)
  local probe = probe_in(tmp)
  local adopting = process.subreaper()
  if not adopting then return end -- no subreaper to be (not Linux)
  local report = create(tmp .. "/parent")
  local started = this_program.program({ "-e", chunk_preamble .. [==[
local pid, trouble = process.spawn(reads[1], { reads[1], "sleep 30000" }, nil, "/", nil,
  nil, nil, false, nil, { unveil = { reads = reads }, offline = true })
print(pid or "refused " .. trouble)
sys.nanosleep(30 * 1000000000)
]==], table.concat(probe_reads(probe), ":") })
  local parent = assert(process.spawn(started.argv[1], started.argv, started.options.env, tmp,
    nil, report, report, false,
    spawn_fds(started)))
  local said = ""
  local by = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) + 30 * 1000000000
  while not said:find("\n") and assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) < by do
    assert(sys.nanosleep(10 * 1000000))
    said = assert(sys.pread(report, 4096, 0))
  end
  sys.close(report)
  assert(sys.kill(parent, sys.SIGKILL))
  assert(process.waitpid(parent, false))
  if said:find("^refused ") then
    unsandboxable("unveiling", said)
    return
  end
  local child = assert(math.tointeger(tonumber(said:match("^(%d+)\n"))), said)
  -- This process adopted it: it ends by the kernel's SIGKILL, its
  -- namespace's end, within seconds, where it would sleep on for 30.
  local ended: raw_process.ChildStatus | nil = nil
  by = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) + 5 * 1000000000
  while ended == nil and assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) < by do
    local status = assert(process.waitpid(child, true))
    if status.pid == child then ended = status else assert(sys.nanosleep(10 * 1000000)) end
  end
  if ended == nil then assert(sys.kill(child, sys.SIGKILL)) end
  -- The rest it adopted: the init, ended with its parent.
  by = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) + 5 * 1000000000
  while assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) < by do
    local status = process.waitpid(-1, true)
    if status == nil then break end
    if status.pid == 0 then assert(sys.nanosleep(10 * 1000000)) end
  end
  assert(ended ~= nil, "the confined child outlived its parent")
  assert(ended.signal == sys.SIGKILL, "ended by " .. tostring(ended.signal))
end

--- An offline child's loopback is up, as a host's is: the kernel gives
--- lo its 127.0.0.1 only when lo comes up, so the child's own routing
--- table (/proc/self/net is the reader's network namespace) holds that
--- address as a local route; and a connection to a closed port there is
--- refused, as the host's would be, not unreachable. The child is this
--- program, reading and connecting.
local function test_an_offline_child_s_loopback_is_up(tmp: string)
  local report = create(tmp .. "/report")
  local started = this_program.program({ "-e",
    "local t = assert(require('cosmic.fs').read('/proc/self/net/fib_trie')) " ..
    "print(t:find('127.0.0.1', 1, true) and 'up' or 'down') " ..
    "local Net = require('cosmic.net') " ..
    "print(select(2, Net.connect(Net.tcp('127.0.0.1', 1), { timeout_ms = 5000 })))" })
  local pid, trouble, errno = process.spawn(started.argv[1], started.argv, started.options.env,
    tmp, nil, report, report, false,
    spawn_fds(started),
    { offline = true })
  if pid == nil then
    sys.close(report)
    unsandboxable("network namespace", trouble)
    assert(errno == sys.ENOSYS or errno == sys.EPERM or errno == sys.EACCES or
      errno == sys.EINVAL or errno == sys.ENOSPC, trouble)
    return
  end
  local status = assert(process.waitpid(pid, false))
  local said = assert(sys.pread(report, 4096, 0))
  sys.close(report)
  assert(status.code == 0 and said == "up\n127.0.0.1:1: Connection refused\n", said)
end

local function test_executable_is_a_file()
  local path = assert(sys.executable())
  assert(path:sub(1, 1) == "/", "the executable's path is absolute")
  assert(assert(sys.stat(path)).kind == "file")
end

--- An unveiled child has a root of its own holding only the paths it was
--- given, at their own names once resolved: a path outside them is not
--- there to stat, one given to read is read-only -- but /proc, a procfs
--- of its own pid namespace, whose processes' entries it may write, and
--- which has no /proc/sys; or, where the kernel refuses one, the host's,
--- read-only whole -- one given to write is written, it keeps no capability, and an offline one
--- has no network but a loopback. An empty unveiling leaves it nothing,
--- not even a program to run. Where unprivileged namespaces are refused,
--- spawning one says so.
local function test_an_unveiled_child_has_only_what_it_was_given(tmp: string)
  local probe = probe_in(tmp)
  local inside, outside, out = tmp .. "/in", tmp .. "/out", tmp .. "/w"
  for _, dir in ipairs({ inside, outside, out }) do assert(sys.mkdir(dir, 0x1c0)) end
  local written = create(inside .. "/f")
  assert(sys.write(written, "in") == 2)
  sys.close(written)
  sys.close(create(outside .. "/f"))
  assert(sys.symlink(inside, tmp .. "/link"))
  -- Given through a link, a path is had under the name it resolves to and,
  -- as a link to that, under the name given; a file can be given as well
  -- as a directory: /dev/null alone of /dev, and the program alone of
  -- the directory it is in.
  local reads: {string} = { tmp .. "/link" }
  for _, path in ipairs(probe_reads(probe)) do reads[#reads + 1] = path end
  local report = create(tmp .. "/report")
  local pid, trouble, errno = process.spawn(probe, { probe,
    "cat link/f; print; present out/f && print outside-seen || print outside-absent; " ..
    "cat " .. assert(sys.realpath(inside)) .. "/f; print; " ..
    "write link/g x || print read-only; write w/f w && cat w/f; status-field CapEff; " ..
    "present /proc/self/net/dev && grep-count /proc/self/net/dev : || print 1" },
    nil, tmp, nil, report, report, false, nil,
    { unveil = { reads = reads, writes = { out } }, offline = true })
  if pid == nil then
    sys.close(report)
    unsandboxable("unveiling", trouble)
    assert(errno == sys.ENOSYS or errno == sys.EPERM or errno == sys.EACCES or
      errno == sys.EINVAL or errno == sys.ENOSPC, trouble)
    return
  end
  assert(assert(process.waitpid(pid, false)).code == 0)
  local said = assert(sys.pread(report, 4096, 0))
  sys.close(report)
  assert(said == "in\noutside-absent\nin\nread-only\nw\n" ..
    "CapEff:\t0000000000000000\n1\n", said)
  -- The parent is not held.
  assert(sys.stat(outside .. "/f") ~= nil)
  -- With /proc, /dev/fd leads into it; a directory made above a given
  -- path has the mode of the one it stands for, as a cache that checks
  -- its own directory's mode needs.
  local private = tmp .. "/private"
  assert(sys.mkdir(private, 0x1c0))
  assert(sys.mkdir(private .. "/inner", 0x1ed))
  local mirrored: {string} = { "/proc", private .. "/inner" }
  for _, path in ipairs(reads) do mirrored[#mirrored + 1] = path end
  -- Whether a file is writable, by opening it to append, which writes
  -- nothing (`writable`), not by its mode, which says nothing of the mount.
  local second = create(tmp .. "/second")
  local again = assert(process.spawn(probe, { probe,
    "present /dev/fd/0 && print fd; mode " .. assert(sys.realpath(private)) ..
    "; ls /tmp; write /tmp/f t && cat /tmp/f; " ..
    "present /proc/sys && print host-proc || print own-proc; " ..
    "writable /proc/self/uid_map && print own-writable || print own-read-only; " ..
    "writable /proc/sys/vm/swappiness || print sys-read-only" },
    nil, "/", nil, second, second, false, nil,
    { unveil = { reads = mirrored }, offline = true }))
  assert(assert(process.waitpid(again, false)).code == 0)
  local seen = assert(sys.pread(second, 4096, 0))
  sys.close(second)
  -- And a /tmp of its own, empty but for the paths given beneath the
  -- host's, which it can write to; /proc its own, whose processes'
  -- entries it writes, so it can confine a child in turn; or, where the
  -- kernel refuses it one, the host's, read-only whole.
  -- And a /tmp of its own, empty but for the paths given beneath the
  -- host's -- each at the name it resolves to, and, given through a
  -- link, the link -- which it can write to; /proc its own, whose
  -- processes' entries it writes, so it can confine a child in turn;
  -- or, where the kernel refuses it one, the host's, read-only whole.
  local under_tmp: {string:boolean} = {}
  for _, path in ipairs(mirrored) do
    for _, name in ipairs({ path, (assert(sys.realpath(path))) }) do
      local top = name:match("^/tmp/([^/]+)")
      if top ~= nil then under_tmp[top] = true end
    end
  end
  local listed: {string} = {}
  for name in pairs(under_tmp) do listed[#listed + 1] = name .. "\n" end
  table.sort(listed)
  local common = "fd\n700\n" .. table.concat(listed) .. "t\n"
  local own = confine.own_proc_given()
  assert(seen == common .. (own and "own-proc\nown-writable\n" or "host-proc\nown-read-only\n") ..
    "sys-read-only\n", seen)
  local nothing, _, nothing_errno = process.spawn(probe, { probe }, nil, tmp,
    nil, nil, nil, false, nil, { unveil = { reads = {}, writes = {} } })
  assert(nothing == nil and nothing_errno == sys.ENOENT, "an empty unveiling leaves no program")
  assert(not pcall(process.spawn, probe, { probe }, nil, nil, nil, nil, nil, false, nil,
    { unveil = { reads = { "relative" } } }), "an unveiled path must be absolute")
end

--- Starts `probe` on `script`, confined to `probe_reads`, offline unless
--- `online`, in /, with `output` its standard output and error: its pid,
--- or nil where the kernel will not confine it, which skips the test
--- (`unsandboxable`).
local function start_confined(probe: string, script: string, output: integer,
                              online?: boolean): integer | nil
  local pid, trouble, errno = process.spawn(probe, { probe, script }, nil, "/", nil,
    output, output, false, nil,
    { unveil = { reads = probe_reads(probe) }, offline = not online })
  if pid ~= nil then return pid end
  unsandboxable("unveiling", trouble)
  assert(errno == sys.ENOSYS or errno == sys.EPERM or errno == sys.EACCES or
    errno == sys.EINVAL or errno == sys.ENOSPC, trouble)
  return nil
end

--- Runs `script` as `start_confined` starts it, its output in `tmp`: its
--- status and what it printed, or nil where the kernel will not confine
--- it.
local function run_confined(tmp: string, probe: string, script: string,
                            online?: boolean): raw_process.ChildStatus | nil, string
  local report = create(tmp .. "/report")
  local pid = start_confined(probe, script, report, online)
  local status: raw_process.ChildStatus | nil = nil
  if pid ~= nil then status = assert(process.waitpid(pid, false)) end
  local said = assert(sys.pread(report, 65536, 0))
  sys.close(report)
  return status, said
end

--- Of /proc/self's `file`, uid_map or gid_map, whether it maps `id`.
local function maps_here(file: string, id: integer): boolean
  local fd = sys.open("/proc/self/" .. file, sys.O_RDONLY)
  if fd == nil then return false end
  local text = sys.read(fd, 65536) or ""
  sys.close(fd)
  for line in text:gmatch("[^\n]+") do
    local inside, _, count = line:match("^%s*(%d+)%s+(%d+)%s+(%d+)")
    local first, many = math.tointeger(tonumber(inside)), math.tointeger(tonumber(count))
    if first ~= nil and many ~= nil and id >= first and id < first + many then return true end
  end
  return false
end

--- Whether this process may start a child as `id`: root, holding
--- CAP_SETGID, CAP_SETUID and CAP_SETFCAP in effect, in a namespace
--- that maps root and `id` (core/process.h's `Sandbox.user`). A host
--- with no /proc (macOS) has no user namespace to map it in: never.
local function may_run_as(id: integer): boolean
  local fd = sys.open("/proc/self/status", sys.O_RDONLY)
  if fd == nil then return false end
  local status = assert(sys.read(fd, 65536))
  sys.close(fd)
  local caps = status:match("\nCapEff:%s+(%x+)") or "0"
  local low = math.tointeger(tonumber(caps:sub(-8), 16)) or 0
  return status:match("\nUid:%s+%d+%s+(%d+)") == "0" and (low >> 6) & 1 == 1 and
    (low >> 7) & 1 == 1 and (low >> 31) & 1 == 1 and maps_here("uid_map", 0) and
    maps_here("uid_map", id) and maps_here("gid_map", 0) and maps_here("gid_map", id)
end

--- A child given a `user` and `group` runs as them -- with no
--- supplementary group, whatever this process has, no capability in
--- effect, in a user namespace that maps that user alone, so root's
--- files are the overflow id's there, and on a root every mount of
--- which is nosuid, so a setuid-root program runs as it does -- as an
--- unprivileged caller's child does, where this process may map them
--- (`may_run_as`): root, as a run of this test unsandboxed as root is.
--- This process stays as dumpable as it was, though the child shares
--- its memory while its ids change. A caller that may not map them --
--- one not root, as a sandboxed worker, which runs as a user of its own
--- where the runner is root (build.test_sandbox's `runs_as`), or root in
--- a namespace that maps root alone -- is refused EPERM. Neither is 0,
--- each needs the other, and neither is given without `unveil`.
local function test_an_unveiled_child_runs_as_the_user_given(tmp: string)
  local probe = probe_in(tmp)
  local reads = probe_reads(probe)
  local user = sys.getuid() == 65533 and 65531 or 65533
  for _, sandbox in ipairs({
    { unveil = { reads = reads, writes = {} }, user = 0, group = user },
    { unveil = { reads = reads, writes = {} }, user = user },
    { offline = true, user = user, group = user },
  } as {raw_process.Sandbox}) do
    assert(not pcall(process.spawn, probe, { probe }, nil, nil, nil, nil, nil, false, nil,
      sandbox), "a user is refused unless given with its group and unveil, and not as root")
  end
  local root = may_run_as(user)
  -- A setuid-root copy of the probe, where this process may make one.
  local setuid = tmp .. "/setuid-probe"
  assert(stand_in.place(probe, setuid))
  if root then
    assert(sys.chown(setuid, 0, 0))
    assert(sys.chmod(setuid, 0x9ed)) -- 04755
  end
  reads[#reads + 1] = setuid
  local report = create(tmp .. "/report")
  -- Undumpable while it starts the child, where it may map the user:
  -- a caller not root that is undumpable could not open its child's
  -- maps (they are root's then), whether it gives a user or not.
  local was: integer = nil
  if root then
    was = assert(sys.dumpable())
    assert(sys.dumpable(0) == 0)
  end
  local pid, trouble, errno = process.spawn(probe, { probe,
    "status-field Uid; status-field Gid; status-field Groups; status-field CapEff; " ..
    "print uid_map; cat /proc/self/uid_map; print mountinfo; cat /proc/self/mountinfo; " ..
    "print setuid; run " .. setuid .. " status-field Uid" },
    nil, "/", nil, report, report, false, nil,
    { unveil = { reads = reads, writes = {} }, offline = true, user = user, group = user })
  if was ~= nil then
    local held = assert(sys.dumpable())
    assert(sys.dumpable(was) == was)
    assert(held == 0, "the caller was left dumpable: " .. tostring(held))
  end
  if pid == nil then
    sys.close(report)
    assert(not root, "root, mapping " .. tostring(user) .. ", refused it: " .. trouble)
    if errno ~= sys.EPERM then unsandboxable("unveiling", trouble) end
    return
  end
  local status = assert(process.waitpid(pid, false))
  local said = assert(sys.pread(report, 65536, 0))
  sys.close(report)
  assert(status.code == 0, said)
  local id = tostring(user)
  local ids = id .. "%s+" .. id .. "%s+" .. id .. "%s+" .. id
  assert(said:find("^Uid:%s+" .. ids) and said:find("\nGid:%s+" .. ids), said)
  assert(said:find("\nGroups:[ \t]*\n") and said:find("\nCapEff:%s+0+\n"), said)
  local uid_map = assert(said:match("\nuid_map\n(.-)\nmountinfo\n"), said)
  assert(uid_map:match("^%s*" .. id .. "%s+" .. id .. "%s+1%s*$"),
    "its namespace maps more than its user: " .. uid_map)
  local mountinfo = assert(said:match("\nmountinfo\n(.-)\nsetuid\n"), said)
  for line in mountinfo:gmatch("[^\n]+") do
    local options = line:match("^%S+ %S+ %S+ %S+ %S+ (%S+)")
    assert(options ~= nil and ("," .. options .. ","):find(",nosuid,", 1, true),
      "a mount of its root is not nosuid: " .. line)
  end
  assert(said:match("\nsetuid\nUid:%s+" .. ids), "a setuid-root program ran as root: " .. said)
end

--- A path given with a name in `at` is bound there, and not at its own
--- name: a tree given at /tree is read, and written where given to
--- write, at /tree alone, so what a child sees of it names nothing of
--- where the host keeps it -- its working directory there answers
--- /tree -- and a directory bound at /tmp is its /tmp, which it has none
--- of its own beside. A name that is not absolute and plain, is /, or
--- is given for a path not unveiled, is refused.
local function test_an_unveiled_path_is_bound_at_the_name_given(tmp: string)
  local probe = probe_in(tmp)
  local reads = probe_reads(probe)
  local tree, scratch = tmp .. "/checkout", tmp .. "/scratch"
  for _, dir in ipairs({ tree, tree .. "/sub", scratch }) do assert(sys.mkdir(dir, 0x1c0)) end
  local written = create(tree .. "/sub/f")
  assert(sys.write(written, "in") == 2)
  sys.close(written)
  local real_tree = assert(sys.realpath(tree))
  local given: {string} = { tree }
  for _, path in ipairs(reads) do given[#given + 1] = path end
  -- The program is bound at a name of its own: its own, beneath this
  -- test's directory, would be beneath /tmp too, where `scratch` is.
  local report = create(tmp .. "/report")
  local pid, trouble, errno = process.spawn("/probe", { "/probe",
    "cat sub/f; print; cwd; present " .. real_tree .. " && print own-name || print no-own-name; " ..
    "write /tmp/g w && print tmp-written; write sub/g x || print tree-read-only" },
    nil, "/tree", nil, report, report, false, nil,
    { unveil = { reads = given, writes = { scratch },
      at = { [tree] = "/tree", [scratch] = "/tmp", [probe] = "/probe" } }, offline = true })
  if pid == nil then
    sys.close(report)
    unsandboxable("unveiling", trouble)
    assert(errno == sys.ENOSYS or errno == sys.EPERM or errno == sys.EACCES or
      errno == sys.EINVAL or errno == sys.ENOSPC, trouble)
    return
  end
  assert(assert(process.waitpid(pid, false)).code == 0)
  local said = assert(sys.pread(report, 4096, 0))
  sys.close(report)
  assert(said == "in\n/tree\nno-own-name\ntmp-written\ntree-read-only\n", said)
  -- What it wrote at /tmp is in the directory bound there.
  local fd = assert(sys.open(scratch .. "/g", sys.O_RDONLY))
  assert(sys.read(fd, 16) == "w\n")
  sys.close(fd)
  for _, bad in ipairs({ "relative", "/", "/a/../b", "/a/" }) do
    assert(not pcall(process.spawn, probe, { probe }, nil, nil, nil, nil, nil, false, nil,
      { unveil = { reads = { tree }, at = { [tree] = bad } } }), "bound at " .. bad)
  end
  assert(not pcall(process.spawn, probe, { probe }, nil, nil, nil, nil, nil, false, nil,
    { unveil = { reads = { tree }, at = { [scratch] = "/tmp" } } }), "at a path not unveiled")
  -- A name placed beneath a path bound from the host goes through no
  -- link there: one leading out, or climbing, refuses the start rather
  -- than make a file where the link leads.
  local victim = tmp .. "/victim"
  assert(sys.mkdir(victim, 0x1c0))
  assert(sys.symlink(victim, tree .. "/out"))
  assert(sys.symlink("../victim", tree .. "/up"))
  for _, placed in ipairs({ "/tree/out/new.txt", "/tree/up/new.txt", "/tree/out" }) do
    local escaped, _, escaped_errno = process.spawn(probe, { probe }, nil, "/",
      nil, nil, nil, false, nil, { unveil = { reads = { tree, tree .. "/sub/f", table.unpack(reads) },
        at = { [tree] = "/tree", [tree .. "/sub/f"] = placed } }, offline = true })
    if escaped ~= nil then process.waitpid(escaped, false) end
    assert(escaped == nil, "placed through a link at " .. placed)
    if sys.errno_name(escaped_errno) ~= "ELOOP" then
      unsandboxable("unveiling", sys.errno_name(escaped_errno))
      assert(escaped_errno == sys.ENOSYS or escaped_errno == sys.EPERM or
        escaped_errno == sys.EACCES or escaped_errno == sys.EINVAL or
        escaped_errno == sys.ENOSPC, tostring(escaped_errno))
    end
  end
  assert(sys.stat(victim .. "/new.txt") == nil, "a file was made through the link")
  -- Two paths bound at one name, or a name beneath the old root's, are
  -- refused as arguments.
  assert(not pcall(process.spawn, probe, { probe }, nil, nil, nil, nil, nil, false, nil,
    { unveil = { reads = { tree, scratch }, at = { [tree] = "/x", [scratch] = "/x" } } }))
  assert(not pcall(process.spawn, probe, { probe }, nil, nil, nil, nil, nil, false, nil,
    { unveil = { reads = { tree }, at = { [tree] = "/.old/x" } } }))
  -- The host's /proc bound through `at` -- here at /proc itself, so the
  -- child has no procfs of its own there, only the host's -- is the
  -- host's state, and mounted read-only, given to write as it may be:
  -- the stand-in, a native program, finds itself in it, and its own pid
  -- there is the host's, not the 2 its own namespace gives it.
  local without_proc: {string} = {}
  for _, path in ipairs(reads) do
    if path ~= "/proc" then without_proc[#without_proc + 1] = path end
  end
  local proc_report = create(tmp .. "/proc-report")
  local proc_pid = process.spawn(probe, { probe, "status-field Pid; cat /proc/self/mountinfo" },
    nil, "/", nil, proc_report, proc_report, false, nil,
    { unveil = { reads = without_proc, writes = { "/proc" }, at = { ["/proc"] = "/proc" } },
      offline = true })
  if proc_pid ~= nil then
    local proc_status = assert(process.waitpid(proc_pid, false))
    local proc_said = assert(sys.pread(proc_report, 1 << 20, 0))
    assert(proc_status.code == 0, proc_said)
    local own_pid = assert(proc_said:match("^Pid:%s*(%d+)\n"), proc_said)
    assert(own_pid ~= "2", "a procfs of its own at /proc: " .. proc_said)
    assert(proc_said:find(" /proc ro[, ]") ~= nil, proc_said)
  else
    -- It started above, so it starts here, as it would anywhere.
    error("the host's /proc could not be bound through at")
  end
  sys.close(proc_report)
end

--- An unveiled child is pid 2 of a pid namespace of its own, beneath the
--- sandbox's init, pid 1: it cannot signal a process outside it, of its
--- own user as it may be -- here a stand-in of this process's, which it
--- tries to kill -- and its /proc, a procfs of that namespace, lists
--- its init, itself and what it starts, and nothing else; where the
--- kernel refuses a procfs of its own (a container masking parts of its
--- /proc), it is the host's, which shows the host's processes, though
--- it cannot signal them.
local function test_an_unveiled_child_sees_and_signals_only_its_own_processes(tmp: string)
  local probe = probe_in(tmp)
  local outside = assert(process.spawn(probe, { probe, "sleep 30000" }, nil, nil, nil,
    nil, nil, false))
  local status, said = run_confined(tmp, probe, "status-field Pid; signal KILL " ..
    tostring(outside) .. " && print killed || print spared; present /proc/" ..
    tostring(outside) .. " && print seen || print unseen; cat /proc/1/comm; ls /proc")
  -- Still running, not a zombie, which a signal of 0 would find too.
  local alive = assert(process.waitpid(outside, true)).pid == 0
  if alive then
    assert(sys.kill(outside, sys.SIGKILL))
    assert(process.waitpid(outside, false))
  end
  if status == nil then return end
  assert(status.code == 0, said)
  assert(alive, "the confined child killed a process outside it: " .. said)
  local lines: {string} = {}
  for line in said:gmatch("[^\n]+") do lines[#lines + 1] = line end
  assert(lines[1]:match("^Pid:%s*2$") and lines[2] == "spared", said)
  if lines[4] ~= "cosmic-init" then
    assert(not confine.own_proc_given(), "no procfs of its own: " .. said)
    return -- the host's /proc
  end
  assert(lines[3] == "unseen", said)
  local listed: {integer:boolean} = {}
  for i = 5, #lines do
    local entry = lines[i]
    local number = math.tointeger(tonumber(entry))
    if number ~= nil then
      listed[number] = true
      assert(number <= 8, "a process not its own in its /proc: " .. said)
    else
      assert(entry == "self" or entry == "thread-self", "more than its processes: " .. said)
    end
  end
  assert(listed[1] and listed[2], said)
end

--- An unveiled child's status is its program's, as an unconfined one's
--- is -- its exit code, a signal it sent itself, one from outside it
--- does not catch -- which it would not be as its pid namespace's pid 1,
--- to which a signal it does not catch is not delivered. When it ends,
--- what it left running in its namespace ends too: a sleep started in
--- the background holding its output open lets that pipe end at once.
--- And an orphan in it is the init's to reap, left no zombie -- which
--- only a procfs of its own shows, listing its init and itself and no
--- more: where the kernel refuses one, its /proc is the host's, whose
--- zombies are not its namespace's, and that is not checked.
local function test_an_unveiled_child_s_status_is_its_program_s(tmp: string)
  local probe = probe_in(tmp)
  local exited = run_confined(tmp, probe, "exit 7")
  if exited == nil then return end
  assert(exited.code == 7 and exited.signal == -1)
  -- Its init is gone with it once the wait answers: no child of this
  -- process is one any more, and none is left a zombie.
  assert(#process.sandbox_inits() == 0, "an init outlived the wait for its program")
  local children = sys.open("/proc/thread-self/children", sys.O_RDONLY)
  if children ~= nil then
    local listed = sys.read(children, 65536) or ""
    sys.close(children)
    for number in listed:gmatch("%d+") do
      local comm = sys.open("/proc/" .. number .. "/comm", sys.O_RDONLY)
      if comm ~= nil then
        local name = sys.read(comm, 64)
        sys.close(comm)
        assert(name ~= "cosmic-init\n", "an init is still a child: " .. number)
      end
    end
  end
  local own = assert(run_confined(tmp, probe, "signal TERM; exit 3"))
  assert(own.code == -1 and own.signal == sys.SIGTERM, "a signal of its own: " .. own.code)
  local quiet = create(tmp .. "/quiet")
  local sleeping = assert(start_confined(probe, "sleep 30000", quiet))
  sys.close(quiet)
  assert(sys.kill(sleeping, sys.SIGTERM))
  local ended = assert(process.waitpid(sleeping, false))
  assert(ended.code == -1 and ended.signal == sys.SIGTERM,
    "a signal from outside: " .. tostring(ended.code))
  local ends = assert(process.pipe())
  local left = assert(start_confined(probe, "start " .. probe .. " sleep 30000; print started",
    ends.writer))
  sys.close(ends.writer)
  assert(assert(process.waitpid(left, false)).code == 0)
  assert(process.set_nonblocking(ends.reader, true))
  local read = ""
  local closed = false
  local by = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) + 10 * 1000000000
  while not closed and assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) < by do
    assert(process.poll({ ends.reader }, { process.POLLIN }, 100))
    local data, _, errno = sys.read(ends.reader, 4096)
    if data == "" then closed = true
    elseif data ~= nil then read = read .. data
    else assert(errno == sys.EAGAIN, "read: " .. tostring(errno)) end
  end
  sys.close(ends.reader)
  assert(read == "started\n" and closed, "what it left running outlived it: " .. read)
  -- One it runs starts one more, which outlives it: an orphan.
  local status, said = run_confined(tmp, probe, "run " .. probe .. " start " .. probe ..
    " sleep 100; sleep 1000; cat /proc/1/comm; ls /proc")
  assert(status ~= nil and status.code == 0, said)
  -- Only a procfs of its own shows its namespace's processes alone: its
  -- init and itself, and no orphan, reaped or not.
  if confine.own_proc_given() then
    local processes: {string} = {}
    for line in said:gmatch("[^\n]+") do
      if line:match("^%d+$") or line == "cosmic-init" then processes[#processes + 1] = line end
    end
    table.sort(processes)
    assert(table.concat(processes, " ") == "1 2 cosmic-init", said)
  end
end

--- The files of a confined child's /proc it may open to write, each its
--- own processes' alone or its own session's, as /proc/<pid>/<name> or
--- /proc/<pid>/task/<tid>/<name>:
local own_writable: {string:string} = {
  -- A user namespace's maps and its setgroups, written once by a
  -- process mapping the namespace it made: how it confines one of its own.
  uid_map = "maps its own user namespace", gid_map = "maps its own user namespace",
  projid_map = "maps its own user namespace", setgroups = "its own user namespace's",
  -- What the kernel does to the process itself.
  oom_adj = "its own OOM score", oom_score_adj = "its own OOM score",
  coredump_filter = "what of its own memory a core dump holds",
  clear_refs = "its own pages' referenced bits", sched = "its own scheduling statistics",
  timerslack_ns = "its own timer slack", comm = "its own name",
  mem = "its own memory, which only a process that may ptrace it opens",
  timens_offsets = "the time namespace its own children would start in",
  ["fail-nth"] = "fault injection in its own calls",
  ["make-it-fail"] = "fault injection in its own calls",
  -- Its session's: one of the sandbox's own, since the program and its
  -- init each start one (core/syscalls.c's `run_program`).
  autogroup = "its own session's autogroup",
  -- Its audit login id: its own process's, but one the host's audit log
  -- names it by, which the kernel lets it set while it is unset (and
  -- only with CAP_AUDIT_CONTROL once set) -- a gap core/syscalls.c's
  -- `place_proc` leaves a TODO for.
  loginuid = "its own, though the host's audit log reads it",
}

--- A confined child can change no state of the host's through its /proc:
--- walking the whole of it, every file that opens to write -- appending,
--- which writes nothing -- is one of its own processes' (`own_writable`,
--- or the security module's attributes of the process, attr/*), and none
--- is outside a process's directory, since its /proc is a procfs of its
--- own pid namespace, holding nothing of the host's. Where the kernel
--- refuses it one, its /proc is the host's, read-only whole, and nothing
--- opens -- but a device a container's runtime bound over an entry
--- (/dev/null, masking /proc/kcore and the like), which a read-only mount
--- does not hold, and which is no file of the host's state: a listing
--- takes it for the file it hides, so each is looked at again, where it
--- leads (`find-writable`).
local function test_a_confined_child_can_write_no_host_state_through_its_proc(tmp: string)
  local probe = probe_in(tmp)
  -- Offline and online: an online child's /proc/<pid>/net is its
  -- parent's network namespace's.
  for _, online in ipairs({ false, true }) do
    local status, said = run_confined(tmp, probe, "find-writable /proc; print done", online)
    if status == nil then return end
    assert(status.code == 0 and said:sub(-5) == "done\n", said)
    local own = confine.own_proc_given()
    local opened = 0
    for path in said:gmatch("([^\n]+)\n") do
      if path ~= "done" then
        opened = opened + 1
        assert(own, "a file of the host's /proc opens to write: " .. path)
        local rest = path:match("^/proc/[%w-]+/task/%d+/(.+)$") or
          path:match("^/proc/%d+/(.+)$") or path:match("^/proc/self/(.+)$") or
          path:match("^/proc/thread%-self/(.+)$")
        assert(rest ~= nil, "a file outside a process's directory opens to write: " .. path)
        assert(own_writable[rest] ~= nil or rest:match("^attr/") ~= nil,
          "a file not the process's own opens to write: " .. path)
      end
    end
    -- Its own maps, at least, where it can confine one of its own.
    assert(not own or opened > 0, said)
  end
end

--- /proc given to write is no more the host's to change than given to
--- read: a procfs of the child's own is writable, and holds no /proc/sys;
--- where the kernel refuses one, the host's is bound read-only all the
--- same, and so is a path beneath it given to write -- where this
--- process has one: in a sandbox of its own (a sandboxed `cosmic test`
--- worker's), its /proc has no /proc/sys to give.
local function test_proc_given_to_write_changes_nothing_of_the_host_s(tmp: string)
  local probe = probe_in(tmp)
  local without: {string} = {}
  for _, path in ipairs(probe_reads(probe)) do
    if path ~= "/proc" then without[#without + 1] = path end
  end
  local writes: {string} = { "/proc" }
  if sys.stat("/proc/sys/kernel") ~= nil then writes[2] = "/proc/sys/kernel" end
  local report = create(tmp .. "/written")
  local pid, trouble, errno = process.spawn(probe, { probe,
    "writable /proc/sys/vm/swappiness && print sys-writable || print sys-read-only; " ..
    "writable /proc/sys/kernel/hostname && print name-writable || print name-read-only" },
    nil, "/", nil, report, report, false, nil,
    { unveil = { reads = without, writes = writes }, offline = true })
  if pid == nil then
    sys.close(report)
    unsandboxable("unveiling", trouble)
    assert(errno == sys.ENOSYS or errno == sys.EPERM or errno == sys.EACCES or
      errno == sys.EINVAL or errno == sys.ENOSPC, trouble)
    return
  end
  assert(assert(process.waitpid(pid, false)).code == 0)
  local said = assert(sys.pread(report, 4096, 0))
  sys.close(report)
  assert(said == "sys-read-only\nname-read-only\n", said)
end

--- Starting and waiting for a confined child costs milliseconds, not the
--- second `waitpid` gives a sandbox's init to end once its program has
--- (core/syscalls.c's `end_sandbox_init`): a run of `cosmic test` that
--- confines each of its processes, as build/shared_verdicts_tool_test.tl's
--- nested runs do, would pay that second for every one. Each of a few
--- runs of a confined program that exits at once takes well under half
--- a second, and leaves no init behind.
local function test_a_confined_child_is_started_and_waited_for_quickly(tmp: string)
  local probe = probe_in(tmp)
  local slowest = 0
  for _ = 1, 5 do
    local started = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC))
    local status = run_confined(tmp, probe, "exit 0")
    if status == nil then return end
    local took = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) - started
    assert(status.code == 0)
    assert(#process.sandbox_inits() == 0, "an init outlived the wait for its program")
    if took > slowest then slowest = took end
  end
  assert(slowest < 500 * 1000000, "a confined start and wait took " ..
    tostring(slowest // 1000000) .. " ms")
end
