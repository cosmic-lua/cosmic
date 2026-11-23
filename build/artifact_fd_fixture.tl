--- What the tests of the program's artifact from a `tool`'s side share
--- (core/artifact_fd_tool_test.tl, core/artifact_fd_policy_tool_test.tl):
--- the relaunch a test starts the program again by, and a link swapped,
--- in another process, between the check that refuses the artifact's
--- descriptor and the call that acts. Test support.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")

local record artifact_fd_fixture
end

--- The program a relaunch starts again.
--- @param relaunch the relaunch
--- @return its program
function artifact_fd_fixture.program_of(relaunch: Proc.Relaunch): string
  local program = assert(relaunch.argv[1], "a relaunch names its program")
  return program
end

--- This start's relaunch, skipping the test where it has none (a host
--- program, which no start of the core relaunches).
--- @return the relaunch
function artifact_fd_fixture.relaunch_or_skip(): Proc.Relaunch
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil then Test.skip("this program has no relaunch to try") end
  local found = assert(relaunch, "Test.skip ends the test where there is no relaunch")
  return found
end

--- The descriptor a relaunch hands its child in `slot`.
--- @param relaunch the relaunch
--- @param slot the descriptor's number in the child
--- @return the descriptor here
function artifact_fd_fixture.fd_of(relaunch: Proc.Relaunch, slot: integer): integer
  local fd = assert(relaunch.fds[slot], "a relaunch hands a descriptor in slot " .. tostring(slot))
  return fd
end

--- The slot a relaunch's environment names in `name`
--- (COSMIC_PORTABLE_ARTIFACT_FD, COSMIC_PORTABLE_CORE_FD).
--- @param relaunch the relaunch
--- @param name the variable
--- @return the descriptor's number in the child
function artifact_fd_fixture.slot_of(relaunch: Proc.Relaunch, name: string): integer
  local slot = assert(math.tointeger(tonumber(relaunch.env[name])), "a relaunch names a slot in " .. name)
  return slot
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
  assert(sys.symlink(if i % 2 == 0 then plain else through end, spare))
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
local counts: mut {string:integer} = {
  ["chmod done"] = 0, ["chmod refused"] = 0, ["truncate done"] = 0, ["truncate refused"] = 0,
}
local function said(what: string, ok: (integer | boolean)?, errno: integer)
  if ok is integer then sys.close(ok) end
  if ok == nil or ok == false then
    if errno == sys.EACCES then counts[what .. " refused"] = assert(counts[what .. " refused"]) + 1 end
  else
    counts[what .. " done"] = assert(counts[what .. " done"]) + 1
  end
end
local function met(): boolean
  for _, what in ipairs({ "chmod", "truncate" }) do
    if counts[what .. " done"] == 0 or counts[what .. " refused"] == 0 then return false end
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
local made = assert(sys.open(stop, sys.O_CREAT | sys.O_WRONLY, 420))
sys.close(made)
for _, what in ipairs({ "chmod", "truncate" }) do
  print(what .. " " .. tostring(counts[what .. " done"]) .. " " .. tostring(counts[what .. " refused"]))
end
]==]

--- `script` with each `NAME` in `values` put as the string literal of
--- its value.
local function filled(script: string, values: {string:string}): string
  return (script:gsub("%u+", function(name: string): string
    local value = values[name]
    return if value ~= nil then string.format("%q", value) else name end
  end))
end

--- A link swapped between the check that refuses the artifact's
--- descriptor and the call that acts changes nothing either: a chmod
--- acts on the file the check held (core/syscalls_fs.c's
--- `probe_file`), and an open that truncates truncates only once the
--- file it opened is judged. The link flips, in another process,
--- between a plain file and /proc/self/fd/<the artifact>, while the
--- child calls through it; both ends are met, and the artifact -- a copy
--- the test made -- keeps its bytes and mode.
--- @param tmp the test's temporary directory
--- @param policy the policy the calling child runs under, nil for none
function artifact_fd_fixture.swapped_link_changes_nothing(tmp: string, policy?: Sandbox.Policy)
  local relaunch = artifact_fd_fixture.relaunch_or_skip()
  local slot = artifact_fd_fixture.slot_of(relaunch, "COSMIC_PORTABLE_ARTIFACT_FD")
  local through = "/proc/self/fd/" .. tostring(slot)
  local linked, _ = sys.stat(through)
  if linked == nil then
    Test.skip("the race is Linux's: this host has no /proc/self/fd")
  end
  local core_slot = artifact_fd_fixture.slot_of(relaunch, "COSMIC_PORTABLE_CORE_FD")
  local copy = tmp .. "/artifact"
  assert(Fs.write(copy, (assert(Fs.read((assert(Proc.executable())))))))
  assert(sys.chmod(copy, 493))
  local before = assert(sys.stat(copy))
  local digest = Hash.hex_sha256((assert(Fs.read(copy))))
  local plain, link, stop = tmp .. "/plain", tmp .. "/link", tmp .. "/stop"
  assert(Fs.write(plain, "text"))
  assert(sys.symlink(plain, link))
  local values = { LINK = link, PLAIN = plain, THROUGH = through, STOP = stop }
  local env: mut {string: string} = {}
  for name, value in pairs(relaunch.env) do env[name] = value end
  local held: Sandbox.Policy? = if policy ~= nil then { ...policy, set_env = env } else nil end
  local opened = assert(sys.open(copy, sys.O_RDONLY))
  local fds = { [slot] = opened, [core_slot] = artifact_fd_fixture.fd_of(relaunch, core_slot) }
  local flipping = assert(Child.start({ artifact_fd_fixture.program_of(relaunch), "--artifact", copy, "-e",
    filled(flipper, values) }, { timeout_ns = Child.FOREVER, env = env, fds = fds, stdin = "stream", stdout = "stream",
      stderr = "capture" }))
  local said, _ = Stream.lines(assert(flipping.stdout_stream)):read()
  if said ~= "flipping" then
    local ended, why = flipping:wait(Clock.seconds(2))
    error("the flipper did not start: " .. tostring(said) .. "\n" ..
        (if ended ~= nil then tostring(ended.stderr) else why end))
  end
  local result = assert(Child.run({ artifact_fd_fixture.program_of(relaunch), "--artifact", copy, "-e",
    filled(caller, values) }, { env = if held == nil then env else nil end, fds = fds, stdout = "capture",
      stderr = "capture", policy = held, timeout_ns = Clock.seconds(7) }))
  local stopped_status, _ = Fs.status(stop)
  local stopped = stopped_status ~= nil and stopped_status.exists
  if stopped ~= true then assert(Fs.write(stop, "")) end
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
    local met_done, met_refused = tonumber(done), tonumber(refused)
    assert(met_done ~= nil and met_done > 0 and met_refused ~= nil and met_refused > 0,
      what .. " did not meet both ends of the link:\n" .. out)
  end
end

return artifact_fd_fixture
