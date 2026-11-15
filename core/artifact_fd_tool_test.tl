--- The program's artifact from a `tool`'s side: a test that declares
--- `tool` is given the program at its own name, and opens it there;
--- and a call that would change the artifact through a descriptor link
--- is refused before it changes anything. Its own module, since a
--- `tool` test runs again on every edit to the tree. The same race under
--- a policy, which only Landlock holds, is
--- core/artifact_fd_policy_tool_test.tl's.

local sys = require("cosmic.sys")
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local Clock = require("cosmic.clock")
local _net = require("cosmic.net")
local test_child = require("build.test_child")
local ArtifactFd = require("build.artifact_fd_fixture")
local unix_socket = require("build.unix_socket")
local type raw_socket = require("cosmic.internal.socket")

Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" },
  grants = { { path = "o/bin", letters = "rx" } } }

local socket = require("cosmic.internal.socket")

--- The child of the test below, run in a copy of the artifact: it sends the file in `args[2]` over the channel in `args[1]`.
test_child.register("send_file", function(args: {string}): integer
  local channel, file = math.tointeger(args[1]), math.tointeger(args[2])
  assert(channel ~= nil and file ~= nil, "the slots are integers")
  assert(socket.sendfds(channel, { file }))
  return 0
end)

--- The program's own path names a file, which a `tool` test, given the
--- program at its own name, can stat.
local function test_executable_is_a_file()
  local path = assert(sys.executable())
  assert(path:sub(1, 1) == "/", "the executable's path is absolute")
  assert(assert(sys.stat(path)).kind == "file")
end

--- Only a name that reaches the program through one of its descriptors
--- is refused (core/syscalls_fs.c's `artifact_through_descriptor`,
--- whose walk refusing descriptor links finds it by its own name).
local function test_a_tool_opens_the_program_by_its_own_name()
  ArtifactFd.relaunch_or_skip()
  local program = assert(Proc.executable())
  local fd, trouble = sys.open(program, sys.O_RDONLY)
  assert(fd ~= nil, "a tool could not open " .. program .. ": " .. tostring(trouble))
  assert(sys.read(fd, 2) == "#!")
  assert(sys.close(fd))
end

--- Sandboxed, where the program is the tree's own o/bin/cosmic -- the
--- file /tree/o/bin/cosmic is the artifact this worker runs -- the
--- worker has it there, as it has the rest of the tree, and by no name
--- of the host's: [`Proc.executable()`] answers /tree/o/bin/cosmic, and
--- so does a relaunch, which starts it again there
--- (build/test_sandbox.tl's `program_name`).
local function test_a_tool_has_the_tree_s_own_program_in_the_tree()
  local relaunch = ArtifactFd.relaunch_or_skip()
  if sys.getcwd() ~= "/tree" then Test.skip("this worker's root is not the sandbox's /tree") end
  local slot = ArtifactFd.slot_of(relaunch, "COSMIC_PORTABLE_ARTIFACT_FD")
  local artifact = sys.stat("/proc/self/fd/" .. tostring(ArtifactFd.fd_of(relaunch, slot)))
  local own = sys.stat("/tree/o/bin/cosmic")
  if artifact == nil or own == nil or artifact.dev ~= own.dev or artifact.ino ~= own.ino then
    Test.skip("another program runs the tree's tests: it keeps its own name")
    return
  end
  local executable, _ = Proc.executable()
  assert(executable == "/tree/o/bin/cosmic", tostring(executable))
  assert(relaunch.argv[3] == "/tree/o/bin/cosmic", relaunch.argv[3])
end

--- What the child runs: each call that would change its artifact
--- through /proc/self/fd/<it> or /dev/fd/<it>, and what it answered.
--- Each is tried so that, were it let through, it would change what it
--- could -- the child's artifact is a copy the test made.
local probe <const> = [==[
local sys = require("cosmic.sys")
local relaunch = assert(require("cosmic.proc").relaunch())
local fd = assert(relaunch.fds[assert(math.tointeger(tonumber(relaunch.env["COSMIC_PORTABLE_ARTIFACT_FD"])))])
local link = "/proc/self/fd/" .. tostring(fd)
if sys.stat(link) == nil then link = "/dev/fd/" .. tostring(fd) end
local function said(what: string, ok: (integer | boolean)?, errno: integer)
  if ok is integer then sys.close(ok) end
  print(what .. " " .. (if ok == nil or ok == false then tostring(errno) else "done" end))
end
local written, _, written_errno = sys.open(link, sys.O_WRONLY | sys.O_APPEND)
said("write", written, written_errno)
if sys.stat(link) ~= nil then
  local fd2 = sys.open(link, sys.O_WRONLY | sys.O_APPEND)
  if fd2 ~= nil then
    sys.write(fd2, "x")
    sys.close(fd2)
  end
end
local read_write, _, read_write_errno = sys.open(link, sys.O_RDWR)
said("read-write", read_write, read_write_errno)
local created, _, created_errno = sys.open(link, sys.O_CREAT | sys.O_WRONLY, 420)
said("create", created, created_errno)
local truncated, _, truncated_errno = sys.open(link, sys.O_WRONLY | sys.O_TRUNC)
said("truncate", truncated, truncated_errno)
local chmodded, _, chmod_errno = sys.chmod(link, 384)
said("chmod", chmodded, chmod_errno)
local touched, _, touch_errno = sys.utimensat(link, 1, 0, 1, 0)
said("utimensat", touched, touch_errno)
]==]

--- Each is refused, EACCES, and the file is as it was: its bytes, mode
--- and modification time. On Linux the times of /proc/self/fd/<n> are
--- the link's own, which a change leaves the file's alone; on macOS,
--- whose /dev/fd/<n> is no link, it is refused.
local function test_a_change_through_the_artifact_descriptor_changes_nothing(tmp: string)
  local relaunch = ArtifactFd.relaunch_or_skip()
  local copy = tmp .. "/artifact"
  assert(Fs.write(copy, (assert(Fs.read((assert(Proc.executable())))))))
  assert(sys.chmod(copy, 493))
  local before = assert(sys.stat(copy))
  local digest = Hash.hex_sha256((assert(Fs.read(copy))))
  local slot = ArtifactFd.slot_of(relaunch, "COSMIC_PORTABLE_ARTIFACT_FD")
  local core_slot = ArtifactFd.slot_of(relaunch, "COSMIC_PORTABLE_CORE_FD")
  local opened = assert(sys.open(copy, sys.O_RDONLY))
  local env: mut {string: string} = {}
  for name, value in pairs(relaunch.env) do env[name] = value end
  local result = assert(Child.run({ ArtifactFd.program_of(relaunch), "--artifact", copy, "-e", probe }, {
    env = env, fds = { [slot] = opened, [core_slot] = ArtifactFd.fd_of(relaunch, core_slot) },
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(sys.close(opened))
  assert(result.ok, tostring(result.stderr))
  local after = assert(sys.stat(copy))
  assert(Hash.hex_sha256((assert(Fs.read(copy)))) == digest and after.size == before.size,
    "a change through the descriptor wrote the artifact:\n" .. tostring(result.stdout))
  assert(after.mode == before.mode and after.mtime == before.mtime and
      after.mtime_ns == before.mtime_ns, "a change through the descriptor reached the " ..
      "artifact's mode or times:\n" .. tostring(result.stdout))
  local out = tostring(result.stdout)
  for _, what in ipairs({ "write", "read-write", "create", "truncate", "chmod" }) do
    assert(out:find(what .. " " .. tostring(sys.EACCES) .. "\n", 1, true) ~= nil,
      what .. " was not refused:\n" .. out)
  end
end

--- The artifact reached by names alone is let through, however they
--- spell it: a relative link, a link to its directory, a "..", a "//".
--- The walk (core/syscalls_fs.c's `walk_without_descriptor_links`)
--- follows each.
local function test_the_artifact_reached_by_names_is_not_refused(tmp: string)
  local relaunch = ArtifactFd.relaunch_or_skip()
  local slot = ArtifactFd.slot_of(relaunch, "COSMIC_PORTABLE_ARTIFACT_FD")
  local core_slot = ArtifactFd.slot_of(relaunch, "COSMIC_PORTABLE_CORE_FD")
  local copy = tmp .. "/artifact"
  assert(Fs.write(copy, (assert(Fs.read((assert(Proc.executable())))))))
  assert(sys.chmod(copy, 493))
  assert(sys.mkdir(tmp .. "/sub"))
  assert(sys.symlink("artifact", tmp .. "/alias"))
  assert(sys.symlink("../alias", tmp .. "/sub/again"))
  assert(sys.symlink(tmp, tmp .. "/sub/home"))
  local names = { copy, tmp .. "/alias", tmp .. "/sub/again", tmp .. "/sub/../artifact",
    tmp .. "//artifact", tmp .. "/sub/home/artifact", tmp .. "/sub/home/alias" }
  local script = { 'local sys = require("cosmic.sys")' }
  for _, name in ipairs(names) do
    script[#script + 1] = string.format("do local fd, _, e = sys.open(%q, sys.O_RDONLY) " ..
        "print(if fd ~= nil then 'open' else tostring(e) end) if fd ~= nil then sys.close(fd) end end", name)
  end
  local env: mut {string: string} = {}
  for name, value in pairs(relaunch.env) do env[name] = value end
  local opened = assert(sys.open(copy, sys.O_RDONLY))
  local result = assert(Child.run({ ArtifactFd.program_of(relaunch), "--artifact", copy, "-e",
    table.concat(script, "\n") }, { env = env, fds = { [slot] = opened,
      [core_slot] = ArtifactFd.fd_of(relaunch, core_slot) }, stdout = "capture", stderr = "capture",
      timeout_ns = Clock.seconds(30) }))
  assert(sys.close(opened))
  assert(result.ok, tostring(result.stderr))
  assert(tostring(result.stdout) == string.rep("open\n", #names), tostring(result.stdout))
end

local function test_a_link_swapped_after_the_check_changes_nothing(tmp: string)
  ArtifactFd.swapped_link_changes_nothing(tmp)
end

--- The source number alone does not protect rights: another open of
--- this same file, and the receiver's duplicate, have different numbers.
local function test_descriptor_passing_refuses_an_open_alias_of_the_artifact()
  local artifact = assert(Proc.executable())
  local fd = assert(sys.open(artifact, sys.O_RDONLY))
  local ok, why = pcall(socket.sendfds, 0, { fd })
  assert(sys.close(fd))
  assert(not ok and tostring(why):find("retained artifact descriptor", 1, true) ~= nil,
    "an artifact alias was not refused: " .. tostring(why))
end

local function test_descriptor_receive_refuses_and_closes_an_artifact_alias(tmp: string)
  unix_socket.skip_if_refused(tmp)
  local address: raw_socket.Address = { kind = "unix", path = tmp .. "/artifact-rights.sock" }
  local listener <close> = assert(socket.listen(address, 1))
  local sender <close> = assert(socket.connect(address, 5000))
  local receiver <close> = assert(socket.accept(listener:fd()))
  local file = assert(sys.open((assert(Proc.executable())), sys.O_RDONLY))
  local relaunch = assert(Proc.relaunch())
  local copy = tmp .. "/sender-artifact"
  assert(Fs.write(copy, (assert(Fs.read((assert(Proc.executable())))))))
  assert(sys.chmod(copy, 493))
  local copy_fd = assert(sys.open(copy, sys.O_RDONLY))
  local env: mut {string: string} = {}
  for name, value in pairs(relaunch.env) do env[name] = value end
  local fds: mut {integer: integer} = {}
  for target, source in pairs(relaunch.fds) do fds[target] = source end
  local slot = math.tointeger(tonumber(env["COSMIC_PORTABLE_ARTIFACT_FD"])) as integer -- checked: cast_refused
  fds[slot] = copy_fd
  local file_slot = 3
  while fds[file_slot] ~= nil do file_slot = file_slot + 1 end
  local channel_slot = file_slot + 1
  while fds[channel_slot] ~= nil do channel_slot = channel_slot + 1 end
  assert(channel_slot <= 255, "the relaunch contract leaves no two fixture slots")
  fds[file_slot], fds[channel_slot] = file, sender:fd()
  -- A start on a copied artifact retains a different inode. It can
  -- send this ordinary file; the original receiver must judge it again.
  local words = test_child.words(tmp, "core.artifact_fd_tool_test", "send_file",
    { tostring(channel_slot), tostring(file_slot) })
  local argv: mut {string} = { ArtifactFd.program_of(relaunch), "--artifact", copy }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local child = assert(Child.start(argv,
    { env = env, fds = fds, stdout = "capture", stderr = "capture" }))
  assert(sys.close(file))
  assert(sys.close(copy_fd))
  local result = assert(child:wait(Clock.seconds(5)))
  assert(result.ok, tostring(result.stderr))
  assert(socket.wait(receiver:fd(), false, 5000))
  local before_fd = assert(sys.open(tmp .. "/probe", sys.O_CREAT | sys.O_RDWR, 420))
  assert(sys.close(before_fd))
  local ok, why = pcall(socket.recvfds, receiver:fd(), 1)
  assert(not ok and tostring(why):find("retained artifact descriptor", 1, true) ~= nil,
    "a received artifact alias was not refused: " .. tostring(why))
  collectgarbage("collect")
  local after = assert(sys.open(tmp .. "/probe", sys.O_RDWR))
  assert(sys.close(after))
  assert(after == before_fd, "refusing a received artifact alias leaked its descriptor")
end
