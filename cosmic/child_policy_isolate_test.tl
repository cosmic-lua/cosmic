--- [`Child.start`]'s `policy` with isolation (cosmic/child.tl): `isolate`
--- "file", a root of the child's own holding only what is granted, and
--- "proc", a pid namespace and a /proc of its own; `loopback` and `u`
--- grants, which give it a network namespace of its own. The kernel's own
--- verdict on live children: the child is a stand-in (build/stand_in.tl),
--- a static program that does what its script says, so a refusal shows as a
--- command that fails. A host that gives no user namespace, Landlock or
--- seccomp, and every platform but Linux, skips the tests that start a child
--- (Test.skip); the refusals that come before a child do not.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local String = require("cosmic.string")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local searchable = require("build.searchable")
local stand_in = require("build.stand_in")
local unix_socket = require("build.unix_socket")
local type raw_process = require("cosmic.internal.process")

--- The temporary directory, and a loopback address for the host's own
--- listener the child must not reach. `nests`: a policy's isolation makes
--- a root of its own, which a worker held by a Landlock ruleset cannot.
Test.needs{ env = { "TMPDIR" }, nests = true, network = { "127.0.0.1" } }

--- Whether `why`, a start's failure, is the platform or the host giving no
--- Landlock, seccomp or user namespace.
local function unsandboxable(why: string): boolean
  for _, word in ipairs({ "Landlock", "seccomp", "not implemented", "namespace", "own /proc",
      "root could not be built" }) do
    if why:find(word, 1, true) then return true end
  end
  return false
end

--- What a script left and how its program ended.
local record Outcome
  code: integer
  said: string
end

--- Runs `script` in `program` under `policy`, starting in `cwd`: its output
--- (stderr beside stdout) and how it ended. Skips the test, returning nil,
--- where the host gives no sandbox; fails the test where the start is
--- refused for another reason.
local function under(program: string, policy: Sandbox.Policy, cwd: string, script: string): Outcome
  local result, why = Child.run({ program, script },
    { policy = policy, cwd = cwd, stdout = "capture", stderr = "stdout" })
  if result == nil then
    assert(unsandboxable(why), "the start was refused: " .. why)
    if confine.sandbox_platform() then Test.skip(why) end
    return nil
  end
  return { code = result.code or -1, said = result.stdout or "" }
end

--- A program, a directory to run in and its grants: the program's file,
--- which the child needs to run, and the directory, which its start needs.
local record Place
  probe: string
  work: string
  grants: {Sandbox.Grant}
  --- The program alone, to run in `home`, its directory: no grant of a
  --- directory, which a `u` grant below Landlock ABI 9 allows none beside it.
  bare: {Sandbox.Grant}
  home: string
end

--- Builds the stand-in and a working directory holding `ro/a` and, beside
--- it, `other/b`, which nothing grants.
local function placed(tmp: string): Place
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  local work = assert(Fs.mkdirs(tmp .. "/work") and tmp .. "/work")
  assert(Fs.mkdirs(work .. "/ro") and Fs.mkdirs(tmp .. "/other"))
  assert(Fs.write(work .. "/ro/a", "alpha\n") and Fs.write(tmp .. "/other/b", "beta\n"))
  return { probe = probe, work = work,
    grants = { { path = probe, letters = "rx" }, { path = work, letters = "r" } },
    bare = { { path = probe, letters = "rx" } }, home = Fs.dirname(probe) }
end

--- A copy of `grants` with `more` after them.
local function with(grants: {Sandbox.Grant}, ...: Sandbox.Grant): {Sandbox.Grant}
  local out: {Sandbox.Grant} = {}
  for _, grant in ipairs(grants) do out[#out + 1] = grant end
  for _, grant in ipairs({ ... }) do out[#out + 1] = grant end
  return out
end

--- The pids /proc lists, from `ls /proc`'s lines.
local function pids(listing: string): {integer}
  local found: {integer} = {}
  for line in listing:gmatch("[^\n]+") do
    local number = tonumber(line)
    if number ~= nil then found[#found + 1] = math.tointeger(number) end
  end
  return found
end

--- The mount at `point` in a /proc/self/mountinfo `text`: its options, its
--- file system's type and that file system's own options, or nil.
local function mount_at(text: string, point: string): {string} | nil
  for line in text:gmatch("[^\n]+") do
    local left, right = line:match("^(.-) %- (.*)$")
    if left ~= nil then
      local fields: {string} = {}
      for word in left:gmatch("%S+") do fields[#fields + 1] = word end
      if fields[5] == point then
        local rest: {string} = {}
        for word in right:gmatch("%S+") do rest[#rest + 1] = word end
        return { fields[6], rest[1], rest[3] }
      end
    end
  end
  return nil
end

local function test_isolate_file_gives_a_root_of_only_what_is_granted(tmp: string)
  local at = placed(tmp)
  local policy: Sandbox.Policy = { isolate = { "file" }, grants = at.grants }
  local read = under(at.probe, policy, at.work, "cat ro/a")
  if read == nil then return end
  assert(read.code == 0 and read.said == "alpha\n", read.code .. ": " .. read.said)
  -- What is not granted is not there: not refused, absent.
  local other = under(at.probe, policy, at.work, "cat " .. tmp .. "/other/b")
  assert(other.code == 1 and other.said:find("No such file or directory", 1, true), other.said)
  assert(not other.said:find("Permission denied", 1, true), other.said)
  local host = under(at.probe, policy, at.work, "present /etc")
  assert(host.code == 1 and host.said:find("not there", 1, true), host.said)
  -- A grant read-only is not written.
  local blind = under(at.probe, policy, at.work, "create ro/new x")
  assert(blind.code == 1 and (blind.said:find("denied", 1, true) or
    blind.said:find("Read-only", 1, true)), blind.said)
  -- The directories the grants stand in exist, to reach them, and are
  -- not themselves granted: Landlock refuses listing one.
  local listed = under(at.probe, policy, at.work, "ls /tmp")
  assert(listed.code == 1 and listed.said:find("Permission denied", 1, true), listed.said)
end

local function test_isolate_file_has_a_proc_of_its_own_holding_its_own_processes(tmp: string)
  local at = placed(tmp)
  local policy: Sandbox.Policy = { isolate = { "file" }, grants = at.grants }
  local listed = under(at.probe, policy, at.work, "ls /proc")
  if listed == nil then return end
  assert(listed.code == 0, listed.said)
  -- Its init is pid 1 and the program, the child's own, pid 2; no other.
  local found = pids(listed.said)
  assert(#found == 2 and found[1] == 1 and found[2] == 2, listed.said)
  local own = under(at.probe, policy, at.work, "status-field Pid")
  assert(own.code == 0 and own.said:find("^Pid:%s+2\n"), own.said)
  -- The host's /proc/sys and the like are not in a procfs of this pid space.
  local sys_dir = under(at.probe, policy, at.work, "present /proc/sys")
  assert(sys_dir.code == 1, sys_dir.said)
  -- It reads its own /proc, as a program expects (Landlock's rule on it).
  local mounts = under(at.probe, policy, at.work, "cat /proc/self/mountinfo")
  assert(mounts.code == 0 and mount_at(mounts.said, "/proc") ~= nil, mounts.said)
end

local function test_a_grant_with_from_appears_at_its_name_and_the_host_path_does_not(tmp: string)
  local at = placed(tmp)
  assert(Fs.mkdirs(tmp .. "/hostdata") and Fs.write(tmp .. "/hostdata/c", "gamma\n"))
  local policy: Sandbox.Policy = { isolate = { "file" },
    grants = with(at.grants, { path = "/data", letters = "r", from = tmp .. "/hostdata" }) }
  local read = under(at.probe, policy, at.work, "cat /data/c")
  if read == nil then return end
  assert(read.code == 0 and read.said == "gamma\n", read.code .. ": " .. read.said)
  local host = under(at.probe, policy, at.work, "cat " .. tmp .. "/hostdata/c")
  assert(host.code == 1 and host.said:find("No such file or directory", 1, true), host.said)
  -- The mount point is the sandbox's own: the host has no /data made.
  local made = Fs.stat("/data")
  assert(made == nil)
end

local function test_a_writable_grant_is_mounted_noexec_unless_it_is_granted_x(tmp: string)
  local at = placed(tmp)
  for _, dir in ipairs({ "rwc", "rwcx", "r" }) do
    assert(Fs.mkdirs(tmp .. "/g" .. dir))
  end
  local policy: Sandbox.Policy = { isolate = { "file" }, grants = with(at.grants,
    { path = tmp .. "/grwc", letters = "rwc" }, { path = tmp .. "/grwcx", letters = "rwcx" },
    { path = tmp .. "/gr", letters = "r" }) }
  local mounts = under(at.probe, policy, at.work, "cat /proc/self/mountinfo")
  if mounts == nil then return end
  assert(mounts.code == 0, mounts.said)
  local function options(name: string): string
    local real = assert(sys.realpath(tmp .. "/" .. name))
    local held = mount_at(mounts.said, real)
    assert(held ~= nil, name .. " is not mounted: " .. mounts.said)
    return held[1]
  end
  assert(options("grwc"):find("noexec", 1, true) and options("grwc"):find("rw", 1, true))
  assert(not options("grwcx"):find("noexec", 1, true), options("grwcx"))
  assert(options("grwcx"):find("rw", 1, true))
  -- A read-only grant may still be mapped executable, a library's way.
  assert(not options("gr"):find("noexec", 1, true) and options("gr"):find("ro", 1, true))
  -- It writes where it may.
  local wrote = under(at.probe, policy, at.work, "create " .. tmp .. "/grwc/n x && cat " ..
      tmp .. "/grwc/n")
  assert(wrote.code == 0 and wrote.said == "x\n", wrote.said)
end

local function test_tmp_under_isolate_file_is_a_tmpfs_of_the_sandboxs_own(tmp: string)
  local at = placed(tmp)
  local policy: Sandbox.Policy = { isolate = { "file" }, tmp = true, grants = at.grants }
  local mounts = under(at.probe, policy, at.work, "cat /proc/self/mountinfo")
  if mounts == nil then return end
  local held = mount_at(mounts.said, "/tmp")
  assert(held ~= nil, mounts.said)
  assert(held[2] == "tmpfs" and held[1]:find("noexec", 1, true), held[1])
  assert(held[3]:find("size=262144k", 1, true), held[3])
  local used = under(at.probe, policy, at.work,
    "env-of TMPDIR && create /tmp/n x && cat /tmp/n && ls /tmp")
  assert(used.code == 0 and used.said:find("^TMPDIR=/tmp\nx\n") and used.said:find("\nn\n"),
    used.said)
  -- Nothing of it is on the host: a tmpfs of the sandbox's own.
  local mine = Fs.list(tmp)
  assert(mine ~= nil)
  for _, name in ipairs(mine) do assert(not name:find("cosmic-sandbox-", 1, true), name) end
  -- Without tmp, no /tmp.
  policy.tmp = false
  local gone = under(at.probe, policy, at.work, "present /tmp/n")
  assert(gone.code == 1, gone.said)
end

local function test_a_grant_of_tmp_with_x_makes_the_sandboxs_own_tmp_executable(tmp: string)
  local at = placed(tmp)
  local script = "mkdirs /tmp/mine && copy " .. at.probe .. " /tmp/mine/p && chmod /tmp/mine/p 755 " ..
    "&& env-of TMPDIR && run /tmp/mine/p print"
  local plain: Sandbox.Policy = { isolate = { "file" }, tmp = true, set_env = { TMPDIR = "/tmp/mine" },
    promises = { "fattr", "fork" }, grants = at.grants }
  local refused = under(at.probe, plain, at.work, script)
  if refused == nil then return end
  -- No letters of its own: noexec, and a TMPDIR beneath /tmp that set_env names stays.
  assert(refused.code ~= 0 and refused.said:find("TMPDIR=/tmp/mine\n", 1, true), refused.said)
  local run_here: Sandbox.Policy = { isolate = { "file" }, tmp = true, set_env = { TMPDIR = "/tmp/mine" },
    promises = { "fattr", "fork" }, grants = with(at.grants, { path = "/tmp", letters = "rwxc" }) }
  local mounts = under(at.probe, run_here, at.work, "cat /proc/self/mountinfo")
  local held = mount_at(mounts.said, "/tmp")
  assert(held ~= nil and held[2] == "tmpfs" and not held[1]:find("noexec", 1, true), mounts.said)
  local ran = under(at.probe, run_here, at.work, script)
  assert(ran.code == 0 and ran.said:find("^TMPDIR=/tmp/mine\n"), ran.said)
  -- A TMPDIR outside /tmp is /tmp, as it was.
  local elsewhere: Sandbox.Policy = { isolate = { "file" }, tmp = true, set_env = { TMPDIR = "/var/x" },
    grants = at.grants }
  local named = under(at.probe, elsewhere, at.work, "env-of TMPDIR")
  assert(named.said == "TMPDIR=/tmp\n", named.said)
  -- /tmp has no other letters than the two.
  local odd: Sandbox.Policy = { isolate = { "file" }, tmp = true,
    grants = with(at.grants, { path = "/tmp", letters = "r" }) }
  local why = select(2, Child.run({ at.probe, "print x" }, { policy = odd, cwd = at.work }))
  assert(tostring(why):find("sandbox's own /tmp, which tmp makes", 1, true), tostring(why))
end

local function test_isolate_proc_alone_has_its_own_proc_and_the_hosts_files_by_grants(tmp: string)
  local at = placed(tmp)
  local policy: Sandbox.Policy = { isolate = { "proc" },
    grants = with(at.grants, { path = tmp .. "/other", letters = "r" }) }
  local listed = under(at.probe, policy, at.work, "ls /proc")
  if listed == nil then return end
  local found = pids(listed.said)
  assert(listed.code == 0 and #found == 2 and found[1] == 1 and found[2] == 2, listed.said)
  -- The host's filesystem, held by the grants and not hidden by a root.
  local granted = under(at.probe, policy, at.work, "cat " .. tmp .. "/other/b")
  assert(granted.code == 0 and granted.said == "beta\n", granted.said)
  local ungranted = under(at.probe, { isolate = { "proc" }, grants = at.grants }, at.work,
    "cat " .. tmp .. "/other/b")
  assert(ungranted.code == 1 and ungranted.said:find("Permission denied", 1, true), ungranted.said)
  -- tmp is a host directory here, as without isolate.
  policy.tmp = true
  local made = under(at.probe, policy, at.work, "env-of TMPDIR")
  assert(made.code == 0 and made.said:find("^TMPDIR=/", 1) and not made.said:find("^TMPDIR=/tmp\n"),
    made.said)
end

local function test_loopback_gives_a_network_of_its_own_the_host_does_not_share(tmp: string)
  local at = placed(tmp)
  local host = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = 1000000000 }))
  local port = host.address.port
  -- Nothing is vacuous: the test itself reaches that listener.
  local probe_conn = assert(Net.connect(Net.tcp("127.0.0.1", port)))
  assert(probe_conn:close())
  local policy: Sandbox.Policy = { loopback = { "127.0.0.1" }, grants = at.grants }
  -- The child binds, connects and accepts on its own loopback ...
  local inside = under(at.probe, policy, at.work, "loopback-tcp 127.0.0.1")
  if inside == nil then
    assert(host:close())
    return
  end
  assert(inside.code == 0 and inside.said == "connected\n", inside.said)
  -- ... and cannot reach the host's, whose port it names.
  local across = under(at.probe, policy, at.work, "connect-tcp 127.0.0.1 " .. port)
  assert(across.said ~= "connected\n" and across.said:find("refused", 1, true), across.said)
  assert(host:close())
  -- With isolate file as well.
  local rooted = under(at.probe, { loopback = { "127.0.0.1" }, isolate = { "file" },
    grants = at.grants }, at.work, "loopback-tcp 127.0.0.1")
  assert(rooted.code == 0 and rooted.said == "connected\n", rooted.said)
end

local function test_inet_sockets_stay_refused_without_loopback(tmp: string)
  local at = placed(tmp)
  local plain = under(at.probe, { grants = at.grants }, at.work, "loopback-tcp 127.0.0.1")
  if plain == nil then return end
  assert(plain.said ~= "connected\n" and plain.said:find("not permitted", 1, true), plain.said)
  -- A unix grant gives the network namespace and unix sockets, not inet ones.
  local socket = tmp .. "/inet.sock"
  if unix_socket.skipped(tmp) then return end
  local server = assert(Net.listen(Net.unix(socket), { timeout_ns = 1000000000 }))
  local unix = under(at.probe, { isolate = { "file" },
    grants = with(at.bare, { path = socket, letters = "u" }) }, at.home,
    "loopback-tcp 127.0.0.1")
  assert(server:close())
  assert(unix ~= nil and unix.said ~= "connected\n" and unix.said:find("not permitted", 1, true),
    unix and unix.said)
end

local function test_a_u_grant_under_isolate_file_reaches_the_socket_bound_into_the_root(tmp: string)
  local at = placed(tmp)
  local socket = tmp .. "/s.sock"
  if unix_socket.skipped(tmp) then return end
  local server = assert(Net.listen(Net.unix(socket), { timeout_ns = 1000000000 }))
  local policy: Sandbox.Policy = { isolate = { "file" },
    grants = with(at.bare, { path = socket, letters = "u" }) }
  local reached = under(at.probe, policy, at.home, "connect " .. socket)
  if reached == nil then
    assert(server:close())
    return
  end
  assert(reached.code == 0 and reached.said == "connected\n", reached.said)
  -- Not granted, the socket is not in the root at all, nor may it make one.
  local without = under(at.probe, { isolate = { "file" }, grants = at.bare }, at.home,
    "connect " .. socket)
  assert(without.said ~= "connected\n" and without.said:find("not permitted", 1, true), without.said)
  assert(server:close())
end

--- A `u` grant reaches the one socket it names. Below Landlock ABI 9 the root
--- cannot tell it from another socket a granted directory holds, and the filter
--- lets the program connect to any: the start is refused. At ABI 9 or more
--- Landlock holds it, and the other socket is out of reach.
local function test_a_u_grant_beside_a_directory_of_sockets_is_refused_or_held(tmp: string)
  local at = placed(tmp)
  assert(Fs.mkdirs(tmp .. "/socks"))
  if unix_socket.skipped(tmp) then return end
  local granted = assert(Net.listen(Net.unix(tmp .. "/socks/s.sock"), { timeout_ns = 1000000000 }))
  local other = assert(Net.listen(Net.unix(tmp .. "/socks/s2.sock"), { timeout_ns = 1000000000 }))
  local policy: Sandbox.Policy = { isolate = { "file" }, grants = with(at.bare,
    { path = tmp .. "/socks", letters = "r" }, { path = tmp .. "/socks/s.sock", letters = "u" }) }
  local result, why = Child.run({ at.probe, "connect " .. tmp .. "/socks/s2.sock" },
    { policy = policy, cwd = at.home, stdout = "capture", stderr = "stdout" })
  if result == nil then
    if why:find("ABI 9", 1, true) then
      assert(why:find("beside a directory", 1, true), why)
    else
      assert(unsandboxable(why), why)
      assert(granted:close() and other:close())
      if confine.sandbox_platform() then Test.skip(why) end
      return
    end
  else
    -- Landlock ABI 9: the socket the grant does not name is refused.
    assert(result.stdout ~= "connected\n", result.stdout)
  end
  assert(granted:close() and other:close())
end

--- A grant of a file that is no socket stands beside a `u` one at any ABI.
local function test_a_u_grant_beside_files_alone_is_met(tmp: string)
  local at = placed(tmp)
  local socket = tmp .. "/solo.sock"
  if unix_socket.skipped(tmp) then return end
  local server = assert(Net.listen(Net.unix(socket), { timeout_ns = 1000000000 }))
  local result = under(at.probe, { isolate = { "file" }, grants = with(at.bare,
    { path = at.probe, letters = "r" }, { path = socket, letters = "u" }) }, at.home,
    "connect " .. socket)
  assert(server:close())
  if result == nil then return end
  assert(result.code == 0 and result.said == "connected\n", result.said)
end

local type Searcher = function(string): any, any

--- The Landlock ABI of this kernel, nil where there is none: from the raw
--- table the store's searcher hands [`cosmic.child`]'s loader.
local function landlock_abi(): integer | nil, string, integer
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then
      return (extra as raw_process).landlock_abi() -- cast: the table core/process.h declares
    end
  end
  error("cosmic.child is handed no raw table")
end

--- A root of files and its own /tmp alone shows no socket of the host's, so
--- the program makes one there with no `u` grant, at any ABI; a directory of
--- the host beside it takes that below ABI 9, and its own network namespace
--- (`loopback`) goes with it at any.
local function test_a_root_of_files_and_its_own_tmp_makes_unix_sockets_without_u(tmp: string)
  local at = placed(tmp)
  if unix_socket.skipped(tmp) then return end
  local script = "loopback-unix /tmp/own.sock"
  local alone = under(at.probe, { isolate = { "file" }, tmp = true, loopback = { "127.0.0.1" },
    grants = at.bare }, at.home, script)
  if alone == nil then return end
  assert(alone.code == 0 and alone.said == "connected\n", alone.said)
  local isolated = under(at.probe, { isolate = { "file" }, tmp = true, grants = at.bare }, at.home, script)
  assert(isolated ~= nil and isolated.said:find("not permitted", 1, true), "no network of its own: " ..
      tostring(isolated and isolated.said))
  local abi, _ = landlock_abi()
  local shown = under(at.probe, { isolate = { "file" }, tmp = true, loopback = { "127.0.0.1" },
    grants = at.grants }, at.work, script)
  assert(shown ~= nil, "started")
  if abi ~= nil and abi < 9 then
    assert(shown.said:find("not permitted", 1, true), "a directory shown, below ABI 9: " .. shown.said)
  else
    assert(shown.said == "connected\n", shown.said)
  end
end

--- The sandbox's own /tmp is no directory of the host's: a `u` grant stands
--- beside it at any ABI, and the program makes a socket of its own there.
local function test_a_u_grant_beside_the_sandboxs_own_tmp_is_met(tmp: string)
  local at = placed(tmp)
  local socket = tmp .. "/beside-tmp.sock"
  if unix_socket.skipped(tmp) then return end
  local server = assert(Net.listen(Net.unix(socket), { timeout_ns = 1000000000 }))
  local policy: Sandbox.Policy = { isolate = { "file" }, tmp = true, grants = with(at.bare,
    { path = socket, letters = "u" }) }
  local granted = under(at.probe, policy, at.home, "connect " .. socket)
  local own = under(at.probe, policy, at.home, "loopback-unix /tmp/own.sock")
  assert(server:close())
  if granted == nil or own == nil then return end
  assert(granted.code == 0 and granted.said == "connected\n", granted.said)
  assert(own.code == 0 and own.said == "connected\n", own.said)
end

--- Under `isolate` file /dev holds what is granted: the "system" profile's
--- devices work, and a device it does not grant is not there.
local function test_the_system_profiles_devices_are_in_the_root(tmp: string)
  local at = placed(tmp)
  local policy: Sandbox.Policy = { isolate = { "file" }, profiles = { "system" },
    grants = with(at.grants) }
  local null = under(at.probe, policy, at.work, "cat /dev/null && present /dev/zero")
  if null == nil then return end
  assert(null.code == 0 and null.said == "", null.said)
  local tty = under(at.probe, policy, at.work, "present /dev/tty")
  assert(tty.code == 1 and tty.said:find("not there", 1, true), tty.said)
end

--- A step of building the root that fails for a reason of its own says so,
--- rather than blaming user namespaces: a name placed beneath a link in a
--- directory bound from the host (core/syscalls.c's make_target) is ELOOP.
local function test_a_root_that_cannot_be_built_says_which_step_failed(tmp: string)
  local at = placed(tmp)
  assert(Fs.mkdirs(tmp .. "/linked") and Fs.mkdirs(tmp .. "/under"))
  assert(Fs.symlink(".", tmp .. "/linked/l"))
  local policy: Sandbox.Policy = { isolate = { "file" }, grants = with(at.bare,
    { path = "/x", letters = "r", from = tmp .. "/linked" },
    { path = "/x/l/y", letters = "r", from = tmp .. "/under" }) }
  local result, why = Child.run({ at.probe, "print hi" }, { policy = policy, cwd = at.home })
  assert(result == nil)
  if not why:find("root could not be built", 1, true) then
    assert(unsandboxable(why), why)
    if confine.sandbox_platform() then Test.skip(why) end
    return
  end
  assert(why:find("Symbolic link loop", 1, true) and why:find("step of making", 1, true), why)
  assert(not why:find("user namespace", 1, true), why)
end

local function test_from_needs_isolate_file_and_what_is_not_met_stays_refused(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  local function refused(policy: Sandbox.Policy): string
    local handle, why = Child.start({ probe, "print hi" }, { policy = policy })
    assert(handle == nil)
    return why
  end
  local from = refused({ grants = { { path = probe, letters = "rx" },
    { path = "/data", letters = "r", from = tmp } } })
  assert(from:find("from", 1, true) and from:find("isolate", 1, true) and from:find("file", 1, true), from)
  assert(refused({ connect = { "example.com:443" } }):find("connect", 1, true))
  assert(refused({ promises = { "nest" } }):find("nest", 1, true))
  local counted = refused({ limits = { processes = 4 } })
  assert(counted:find("limits.processes", 1, true) and counted:find("isolate", 1, true), counted)
  -- /tmp is the sandbox's own where tmp asks for it.
  local clash = refused({ isolate = { "file" }, tmp = true, grants = {
    { path = probe, letters = "rx" }, { path = "/tmp", letters = "r" } } })
  assert(clash:find("/tmp", 1, true) and clash:find("tmp", 1, true), clash)
  local proc = refused({ isolate = { "file" }, grants = {
    { path = probe, letters = "rx" }, { path = "/proc", letters = "r", from = tmp } } })
  assert(proc:find("/proc", 1, true) and proc:find("from", 1, true), proc)
end

local function test_a_directory_nothing_grants_cannot_be_started_in_under_isolate_file(tmp: string)
  local at = placed(tmp)
  local result, why = Child.run({ at.probe, "print hi" }, { cwd = tmp .. "/other",
    policy = { isolate = { "file" }, grants = at.grants } })
  assert(result == nil)
  if unsandboxable(why) then
    if confine.sandbox_platform() then Test.skip(why) end
    return
  end
  assert(why:find("must be at, beneath or above a grant", 1, true), why)
end

local function test_a_refused_namespace_fails_naming_the_remedy(tmp: string)
  -- Inside a child held by a policy without `nest`, the filter refuses the
  -- namespace a start of its own makes: the failure says what to allow.
  local at = placed(tmp)
  -- Where it writes the root it builds, which its start asks of TMPDIR.
  local scratch = tmp .. "/scratch"
  assert(Fs.mkdirs(scratch))
  searchable.share(scratch)
  local policy: Sandbox.Policy = { promises = { "fork" }, set_env = { TMPDIR = scratch },
    grants = with(at.grants, { path = scratch, letters = "rwc" }) }
  local ran = under(at.probe, policy, at.work, "start-isolated " .. at.probe)
  if ran == nil then return end
  assert(ran.code == 0, ran.said)
  assert(ran.said:find("namespace was refused", 1, true) and
      ran.said:find("unprivileged user namespaces", 1, true), ran.said)
  assert(ran.said:find("kernel.unprivileged_userns_clone", 1, true) and
      ran.said:find("kernel.apparmor_restrict_unprivileged_userns", 1, true), ran.said)
  assert(String.starts_with(ran.said, "child: start: ") or ran.said:find("start: ", 1, true), ran.said)
end
