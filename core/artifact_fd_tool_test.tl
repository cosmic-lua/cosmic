--- The program's artifact from a `tool`'s side: a test that declares
--- `tool` is given the program at its own name, and opens it there;
--- and a call that would change the artifact through a descriptor link
--- is refused before it changes anything. Its own module, since a
--- `tool` test runs again on every edit to the tree.

local sys = require("cosmic.sys")
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")

Test.needs{ tool = true }

--- Only a name that reaches the program through one of its descriptors
--- is refused (core/syscalls_fs.c's `artifact_through_descriptor`,
--- whose walk refusing descriptor links finds it by its own name).
local function test_a_tool_opens_the_program_by_its_own_name()
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil then return end
  local program = assert(Proc.executable())
  local fd, trouble = sys.open(program, sys.O_RDONLY)
  assert(fd ~= nil, "a tool could not open " .. program .. ": " .. tostring(trouble))
  assert(sys.read(fd, 2) == "#!")
  assert(sys.close(fd))
end

--- What the child runs: each call that would change its artifact
--- through /proc/self/fd/<it> or /dev/fd/<it>, and what it answered.
--- Each is tried so that, were it let through, it would change what it
--- could -- the child's artifact is a copy the test made.
local probe <const> = [==[
local sys = require("cosmic.sys")
local relaunch = assert(require("cosmic.proc").relaunch())
local fd = relaunch.fds[math.tointeger(tonumber(relaunch.env.COSMIC_PORTABLE_ARTIFACT_FD))]
local link = "/proc/self/fd/" .. fd
if sys.stat(link) == nil then link = "/dev/fd/" .. fd end
local function said(what, ok, _, errno)
  if type(ok) == "number" then sys.close(ok) end
  print(what .. " " .. ((ok == nil or ok == false) and tostring(errno) or "done"))
end
said("write", sys.open(link, sys.O_WRONLY | sys.O_APPEND))
if sys.stat(link) ~= nil then
  local fd2 = sys.open(link, sys.O_WRONLY | sys.O_APPEND)
  if fd2 then sys.write(fd2, "x") sys.close(fd2) end
end
said("read-write", sys.open(link, sys.O_RDWR))
said("create", sys.open(link, sys.O_CREAT | sys.O_WRONLY, 420))
said("truncate", sys.open(link, sys.O_WRONLY | sys.O_TRUNC))
said("chmod", sys.chmod(link, 384))
said("utimensat", sys.utimensat(link, 1, 0, 1, 0))
]==]

--- Each is refused, EACCES, and the file is as it was: its bytes, mode
--- and modification time. On Linux the times of /proc/self/fd/<n> are
--- the link's own, which a change leaves the file's alone; on macOS,
--- whose /dev/fd/<n> is no link, it is refused.
local function test_a_change_through_the_artifact_descriptor_changes_nothing(tmp: string)
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil then return end
  local copy = tmp .. "/artifact"
  assert(Fs.write(copy, (assert(Fs.read((assert(Proc.executable())))))))
  assert(sys.chmod(copy, 493))
  local before = assert(sys.stat(copy))
  local digest = Hash.hex_sha256((assert(Fs.read(copy))))
  local slot = math.tointeger(tonumber(relaunch.env.COSMIC_PORTABLE_ARTIFACT_FD)) as integer
  local core_slot = math.tointeger(tonumber(relaunch.env.COSMIC_PORTABLE_CORE_FD)) as integer
  local opened = assert(sys.open(copy, sys.O_RDONLY))
  local env: {string: string} = {}
  for name, value in pairs(relaunch.env) do env[name] = value end
  local result = assert(Child.run({ relaunch.argv[1], "--artifact", copy, "-e", probe }, {
    env = env, fds = { [slot] = opened, [core_slot] = relaunch.fds[core_slot] },
    stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
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
    assert(out:find(what .. " " .. sys.EACCES .. "\n", 1, true) ~= nil,
      what .. " was not refused:\n" .. out)
  end
end
