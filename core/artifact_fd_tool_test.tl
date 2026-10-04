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
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local Clock = require("cosmic.clock")

Test.needs{ tool = true }

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
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil then return end
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
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil or sys.getcwd() ~= "/tree" then return end
  local slot = math.tointeger(tonumber(relaunch.env.COSMIC_PORTABLE_ARTIFACT_FD)) as integer
  local artifact = sys.stat("/proc/self/fd/" .. relaunch.fds[slot])
  local own = sys.stat("/tree/o/bin/cosmic")
  if artifact == nil or own == nil or artifact.dev ~= own.dev or artifact.ino ~= own.ino then
    return -- another program runs the tree's tests: it keeps its own name
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
    assert(out:find(what .. " " .. sys.EACCES .. "\n", 1, true) ~= nil,
      what .. " was not refused:\n" .. out)
  end
end

--- What the flipping child runs: a link at `LINK` swapped, again and
--- again, between a plain file and the artifact's descriptor link, each
--- time by a rename of a fresh link over it, until `STOP` is there,
--- and then left leading to the plain file. It says "flipping" once it
--- has swapped the link both ways.
local flipper <const> = [==[
local sys = require("cosmic.sys")
local link, plain, through, stop = LINK, PLAIN, THROUGH, STOP
local spare = link .. ".next"
local i = 0
while true do
  i = i + 1
  if i % 64 == 0 and sys.stat(stop) ~= nil then break end
  sys.unlink(spare)
  assert(sys.symlink(i % 2 == 0 and plain or through, spare))
  assert(sys.rename(spare, link))
  if i == 2 then print("flipping") end
end
-- Left leading to the plain file, where what the run read is judged.
sys.unlink(spare)
assert(sys.symlink(plain, spare))
assert(sys.rename(spare, link))
]==]

--- What the calling child runs: a chmod, and an open that truncates,
--- of the link as it flips, each many times, counting what each did.
--- It starts once the flipper is flipping, and goes on past `least`
--- calls until each call has met both ends, for up to `bound_ns`: on a
--- busy or single processor the flipper may not run while `least` calls
--- are made. The bound stays under the run's timeout, and that under
--- CI's 10 s per-test deadline, so an end never met fails the
--- assertions below rather than the clock.
--- The chmod keeps the owner's access: a walk that meets a link as a
--- rename replaces it can end at the link's directory (Linux 6.18
--- does, a few times in 100000), which it changes too.
local caller <const> = [==[
local Clock = require("cosmic.clock")
local sys = require("cosmic.sys")
local link, stop = LINK, STOP
local counts = { chmod = { done = 0, refused = 0 }, truncate = { done = 0, refused = 0 } }
local function said(what, ok, errno)
  if type(ok) == "number" then sys.close(ok) end
  local count = counts[what]
  if ok == nil or ok == false then
    if errno == sys.EACCES then count.refused = count.refused + 1 end
  else
    count.done = count.done + 1
  end
end
local function met()
  for _, count in pairs(counts) do
    if count.done == 0 or count.refused == 0 then return false end
  end
  return true
end
local least <const>, bound_ns <const> = 20000, 5 * 1000000000
local deadline, i = Clock.monotonic_ns() + bound_ns, 0
while i < least or (not met() and Clock.monotonic_ns() < deadline) do
  i = i + 1
  local ok, _, errno = sys.chmod(link, 448)
  said("chmod", ok, errno)
  local fd, _, open_errno = sys.open(link, sys.O_WRONLY | sys.O_TRUNC)
  said("truncate", fd, open_errno)
end
assert(sys.close(assert(sys.open(stop, sys.O_CREAT | sys.O_WRONLY, 420))))
for _, what in ipairs({ "chmod", "truncate" }) do
  print(what .. " " .. counts[what].done .. " " .. counts[what].refused)
end
]==]

--- `script` with each `NAME` in `values` put as the string literal of
--- its value.
local function filled(script: string, values: {string:string}): string
  return (script:gsub("%u+", function(name: string): string
    local value = values[name]
    return value ~= nil and string.format("%q", value) or name
  end))
end

--- Says the running test is skipped, and answers true, where a seccomp
--- filter holds this process (/proc/self/status says "Seccomp: 2"): it
--- answers openat2 ENOSYS, so the core walks a path by hand to find
--- whether it names the artifact through a descriptor link, a check a link
--- swapped between the walk and the call defeats
--- (core/syscalls_fs.c's `artifact_through_descriptor`).
-- TODO: hold this case under the policy path, and delete the skip, once
-- the core's artifact check no longer needs openat2 under the filter
-- (core/promises.c answers it ENOSYS, and a filter cannot read openat2's
-- mode struct to allow it safely), so the check is not a walk by hand
-- that a swapped link races.
local function filtered(): boolean
  local status = Fs.read("/proc/self/status")
  if status == nil or status:match("\nSeccomp:%s*(%d+)") ~= "2" then return false end
  Test.skip("a seccomp filter answers openat2 ENOSYS, so the core's check of a path against " ..
      "the artifact is a walk by hand that a swapped link races")
  return true
end

--- A link swapped between the check that refuses the artifact's
--- descriptor and the call that acts changes nothing either: a chmod
--- acts on the file the check held (core/syscalls_fs.c's
--- `probe_file`), and an open that truncates truncates only once the
--- file it opened is judged. The link flips, in another process,
--- between a plain file and /proc/self/fd/<the artifact>, while the
--- child calls through it; both ends are met, and the artifact -- a copy
--- the test made -- keeps its bytes and mode.
local function test_a_link_swapped_after_the_check_changes_nothing(tmp: string)
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil then return end
  if filtered() then return end
  local slot = math.tointeger(tonumber(relaunch.env.COSMIC_PORTABLE_ARTIFACT_FD)) as integer
  local through = "/proc/self/fd/" .. slot
  if sys.stat(through) == nil then return end -- the race is Linux's
  local core_slot = math.tointeger(tonumber(relaunch.env.COSMIC_PORTABLE_CORE_FD)) as integer
  local copy = tmp .. "/artifact"
  assert(Fs.write(copy, (assert(Fs.read((assert(Proc.executable())))))))
  assert(sys.chmod(copy, 493))
  local before = assert(sys.stat(copy))
  local digest = Hash.hex_sha256((assert(Fs.read(copy))))
  local plain, link, stop = tmp .. "/plain", tmp .. "/link", tmp .. "/stop"
  assert(Fs.write(plain, "text"))
  assert(sys.symlink(plain, link))
  local values = { LINK = link, PLAIN = plain, THROUGH = through, STOP = stop }
  local env: {string: string} = {}
  for name, value in pairs(relaunch.env) do env[name] = value end
  local opened = assert(sys.open(copy, sys.O_RDONLY))
  local fds = { [slot] = opened, [core_slot] = relaunch.fds[core_slot] }
  local flipping = assert(Child.start({ relaunch.argv[1], "--artifact", copy, "-e",
    filled(flipper, values) }, { env = env, fds = fds, stdin = "stream", stdout = "stream",
      stderr = "capture" }))
  local said = Stream.lines(assert(flipping.stdout_stream)):read()
  if said ~= "flipping" then
    local ended, why = flipping:wait(Clock.seconds(2))
    error("the flipper did not start: " .. tostring(said) .. "\n" ..
        (ended ~= nil and tostring(ended.stderr) or why))
  end
  local result = assert(Child.run({ relaunch.argv[1], "--artifact", copy, "-e",
    filled(caller, values) }, { env = env, fds = fds, stdout = "capture", stderr = "capture",
      timeout_ns = Clock.seconds(7) }))
  if not Fs.exists(stop) then assert(Fs.write(stop, "")) end
  local flipped = assert(flipping:wait())
  assert(sys.close(opened))
  assert(result.ok, tostring(result.stderr))
  assert(flipped.ok, tostring(flipped.stderr))
  local after = assert(sys.stat(copy))
  local out = tostring(result.stdout)
  assert(Hash.hex_sha256((assert(Fs.read(copy)))) == digest and after.size == before.size,
    "a truncation through a swapped link reached the artifact:\n" .. out)
  assert(after.mode == before.mode, "a chmod through a swapped link reached the artifact:\n" .. out)
  for _, what in ipairs({ "chmod", "truncate" }) do
    local done, refused = out:match(what .. " (%d+) (%d+)\n")
    assert(done ~= nil and tonumber(done) > 0 and tonumber(refused) > 0,
      what .. " did not meet both ends of the link:\n" .. out)
  end
end
