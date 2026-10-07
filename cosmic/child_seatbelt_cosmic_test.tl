--- [`Child.start`]'s `policy` starting this program on macOS, where Seatbelt
--- holds the child: it runs as its core by a relaunch, past a launcher that
--- would unpack a core into a cache the profile does not grant. A program
--- that is a sealed database is in cosmic/child_seatbelt_database_test.tl.
--- macOS alone has Seatbelt, and no `requires` name stands for it, so every
--- test calls [`Test.skip`] on any other host
--- (cosmic/child_policy_cosmic_test.tl is Linux's).

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")

--- The temporary directory, this program (which the child runs) and the
--- system's own paths, which its core and loader are read and run from.
Test.policy{
  profiles = { "cosmic", "system" },
  grants = { { path = "o/bin", letters = "rx" } },
  env = { "HOME", "TMPDIR" },
}

--- Ends the test where Seatbelt does not hold a child.
local function macos_only()
  if assert(sys.uname()).sysname ~= "Darwin" then
    Test.skip("Seatbelt holds a child on macOS alone")
  end
end

--- What Seatbelt denied lately, as the system's log names it, which says
--- what a profile lacks. Empty where the log cannot be read.
local function denials(): string
  local result = Child.run({ "/usr/bin/log", "show", "--last", "1m", "--style", "compact",
    "--predicate", "eventMessage CONTAINS \"Sandbox: \"" },
    { stdout = "capture", stderr = "capture", stdin = "null", timeout_ns = Clock.seconds(60) })
  if result == nil then return "" end
  local lines: {string} = {}
  for line in (result.stdout or ""):gmatch("[^\n]+") do lines[#lines + 1] = line end
  return "\nlog: " .. table.concat(lines, "\n", math.max(1, #lines - 60), #lines)
end

--- This program run to its end under `policy` on `-e chunk` and `args`,
--- its output captured.
local function ran(chunk: string, policy: Sandbox.Policy, args?: {string}): Child.Result
  local argv: {string} = { (assert(Proc.executable())), "-e", chunk }
  for _, word in ipairs(args or {}) do argv[#argv + 1] = word end
  local result, why = Child.run(argv, { policy = policy, stdout = "capture", stderr = "capture",
    stdin = "null", timeout_ns = Clock.seconds(60) })
  assert(result, why)
  return result
end

--- `held`, or a failure that says how `result` ended and what was denied.
local function expect(held: boolean, result: Child.Result)
  if held then
    assert(held)
  else
    assert(held, "code " .. tostring(result.code) .. ", signal " .. tostring(result.signal) ..
        ", stdout " .. string.format("%q", result.stdout or "") ..
        ", stderr " .. string.format("%q", result.stderr or "") .. denials())
  end
end

local FS <const> = 'local Fs = require("cosmic.fs") '

local function test_this_program_runs_a_chunk_under_a_policy()
  macos_only()
  local result = ran('print(6 * 7)', { profiles = { "cosmic", "system" } })
  expect(result.ok and result.stdout == "42\n", result)
end

local function test_it_reads_a_granted_file_and_no_other(tmp: string)
  macos_only()
  local granted, other = tmp .. "/granted", tmp .. "/other"
  assert(Fs.write(granted, "granted-bytes"))
  assert(Fs.write(other, "other-bytes"))
  local result = ran(FS .. 'local a, b = ...; local g = Fs.read(a); local o = Fs.read(b) ' ..
      'print(g, o == nil)', { profiles = { "cosmic", "system" },
        grants = { { path = granted, letters = "r" } } }, { granted, other })
  expect(result.ok and result.stdout == "granted-bytes\ttrue\n", result)
  assert(not (result.stdout or ""):find("other-bytes", 1, true), "an ungranted file was read")
end

local function test_nothing_outside_its_grants_is_readable()
  macos_only()
  local home = assert(sys.getenv("HOME"), "HOME is not set")
  local result = ran(FS .. 'local home, hosts = ...; ' ..
      'print(Fs.list(home) == nil, Fs.read(hosts) == nil)',
    { profiles = { "cosmic", "system" } }, { home, "/etc/hosts" })
  expect(result.ok and result.stdout == "true\ttrue\n", result)
end

local function test_tmp_is_a_directory_it_may_write()
  macos_only()
  local result = ran(FS .. 'local dir = require("cosmic.sys").getenv("TMPDIR"); local path = dir .. "/made"; ' ..
      'print(dir, (Fs.write(path, "x")), (Fs.read(path)))', { profiles = { "cosmic", "system" }, tmp = true })
  expect(result.ok, result)
  local dir = (result.stdout or ""):match("^([^\t]+)\ttrue\tx\n$")
  assert(dir ~= nil, "the child's tmp was not writable: " .. string.format("%q", result.stdout or ""))
  -- The directory is the start's, gone with the child.
  assert(sys.stat(dir) == nil, dir .. " outlives the child")
end

--- `tmp` is the one directory the child may write: not the one it is made in,
--- and not a file the policy grants to read.
local function test_tmp_leaves_its_parent_and_a_read_granted_file_unwritable(tmp: string)
  macos_only()
  local granted = tmp .. "/granted"
  assert(Fs.write(granted, "granted-bytes"))
  local result = ran(FS .. 'local sys = require("cosmic.sys") local granted = ... ' ..
      'local dir = sys.getenv("TMPDIR") local parent = Fs.dirname(dir) ' ..
      'print((Fs.write(dir .. "/in", "x")), (Fs.write(parent .. "/beside", "x")), ' ..
      '(Fs.write(granted, "changed")))', { profiles = { "cosmic", "system" }, tmp = true,
        grants = { { path = granted, letters = "r" } } }, { granted })
  expect(result.ok and result.stdout == "true\tfalse\tfalse\n", result)
  assert(Fs.read(granted) == "granted-bytes", "the read-granted file was written")
end

--- Started from a portable artifact (its core on `--artifact`, and the
--- descriptors it is handed), the child is this program again by the same
--- relaunch. A worker that runs on a sealed database has no artifact to
--- hand on, which its relaunch says, so the test skips there.
local function test_a_portable_artifacts_relaunch_runs_under_a_policy()
  macos_only()
  local launched = assert(Proc.relaunch())
  if launched.argv[2] ~= "--artifact" then
    Test.skip("this worker's program is not a portable artifact (it relaunches as " ..
        tostring(launched.argv[2]) .. "): no descriptors to hand on")
  end
  assert(next(launched.fds) ~= nil, "a portable artifact's relaunch hands on no descriptor")
  local result = ran('print(require("cosmic.proc").relaunch().argv[2])', { profiles = { "cosmic", "system" } })
  expect(result.ok and result.stdout == "--artifact\n", result)
end
