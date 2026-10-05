--- Whether this host can run a test worker sandboxed (`available`).
--- `cosmic test` asks once a run, before it starts a worker
--- ([`build.test`]'s `sandbox_here`). This is not build/sandbox_probe.tl,
--- CI's report of what spawn's sandbox can hold a child to on a host.
---
--- A failure is one of two kinds, which `available` tells apart: a limit of
--- the host (no sandbox on this platform, a root that cannot map a user, a
--- kernel that refuses a user namespace or lacks Landlock), where the run
--- goes on unsandboxed, and any other (a policy that cannot be made, a start
--- that fails otherwise, an exit, a timeout), which is a defect in the
--- probe or the harness and fails the run, never passing as an unsandboxed
--- one.
---
--- It is no part of the test harness (build/harness_epoch.tl): it decides
--- whether a run is sandboxed, not what a sandboxed worker is given
--- ([`build.test_sandbox`]'s `plan`) nor how one is judged, and a wrong
--- answer fails loudly, never passes:
---
--- - Answered wrongly yes, every worker is started under its policy
---   ([`build.test_policy`]) and holds itself by [`confine.forbid_running`].
---   Where the host can do neither, the start or the worker fails, and each
---   test with it, naming why.
--- - Answered wrongly no, the run is unsandboxed. A run held to the
---   sandbox (`COSMIC_TEST_SANDBOX=1`) fails. Any other keys its verdicts
---   as unsandboxed, by what each test declares but apart from a
---   sandboxed run's, so no sandboxed run's key finds them, as on a host
---   that cannot sandbox.
---
--- So its code is left out of the harness's digests. cosmic.child, which
--- starts the probe, is in them alone, since it applies every worker's
--- sandbox ([`build.test`]'s `harness_alone`).

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local confine = require("build.confine")
local test_inputs = require("build.test_inputs")
local test_policy = require("build.test_policy")
local test_sandbox = require("build.test_sandbox")
local Clock = require("cosmic.clock")

local record test_sandbox_probe
  --- What a probe found: whether it can, why not (`why`, "" for it can),
  --- and whether the failure is a defect, no limit of the host (`broken`).
  record Answer
    ok: boolean
    why: string
    broken: boolean
  end
end

--- A fresh directory to probe the sandbox in (`available`), removed by
--- the caller.
function test_sandbox_probe.directory(): string | nil, string
  local made, trouble = Fs.mkdtemp("cosmic-sandbox-probe-")
  if made == nil then return nil, trouble end
  return Fs.absolute(made)
end

--- How long a probe's child may run, in the nanoseconds a wait takes.
local probe_timeout_ns <const> = Clock.seconds(30)

--- The policy of a worker that has the least one is given -- /proc, the
--- devices and the program, none of the system's own paths -- offline, and
--- `scratch` to write at the name a worker has it, with `environment` its
--- whole environment: the policy of a worker that declares nothing
--- ([`test_policy.worker`]), whose program (`program`, the core a start
--- names) is run.
local function least_policy(program: string, scratch: string,
                            environment: {string:string}): Sandbox.Policy | nil, string
  local reads: {string} = {}
  for _, path in ipairs(confine.worker_unveil(scratch, nil, scratch).reads) do
    -- A policy's sandbox has a /proc of its own.
    if path ~= "/proc" then reads[#reads + 1] = path end
  end
  local effective: test_inputs.Effective = {
    files = {}, reads = {}, host = {}, env = {}, network = {}, tool = false, store = false,
  }
  local plan: test_sandbox.Plan = {
    sandbox = { unveil = { reads = reads, writes = { scratch },
      at = { [scratch] = test_sandbox.scratch } }, offline = true },
    env = environment, over = 0, trouble = "", runs = { [program] = true },
    own_scratch = false, why_shared = "",
  }
  local policy, why = test_policy.worker(plan, effective)
  if policy == nil then return nil, why end
  policy.set_env = environment
  return policy, ""
end

--- The words by which a failure names what a host may lack of a sandbox: a
--- user namespace (ENOSPC, EPERM, EACCES, EINVAL), a syscall (ENOSYS), or
--- the parts of a policy's start that need them.
local host_limits <const>: {string} = {
  "No space left on device", "Operation not permitted", "Permission denied",
  "Invalid argument", "Function not implemented", "not implemented", "Landlock",
  "seccomp", "namespace", "own /proc", "root could not be built",
}

--- Whether `trouble` names a limit of the host rather than a defect.
local function host_limit(trouble: string): boolean
  for _, word in ipairs(host_limits) do
    if trouble:find(word, 1, true) then return true end
  end
  return false
end

--- Runs `argv`, this program started again with `fds`, under `policy`,
--- and waits for it. False and why where it cannot be started, ends
--- otherwise than by exiting 0, or takes longer than the bound, and
--- whether that is a defect (`broken`) rather than a limit of the host.
local function ran_under(argv: {string}, fds: {integer:integer | string},
                         policy: Sandbox.Policy): test_sandbox_probe.Answer
  local given: {integer:integer | string} = {}
  for number, fd in pairs(fds) do given[number] = fd end
  -- Started and waited for, not [`Child.run`], which would take the one
  -- signal guard a caller running tests in-process may hold.
  -- No group of its own to end, nor strays to adopt: its sandbox gives
  -- it a pid namespace of its own, which ends when it does.
  local handle, trouble = Child.start(argv, { policy = policy, fds = given, cwd = "/",
    stdin = "null", stdout = "capture", stderr = "stdout", process_group = false })
  if handle == nil then
    return { ok = false, why = test_sandbox.refusal(trouble), broken = not host_limit(trouble) }
  end
  -- Past the bound, `wait` ends it, and its pid namespace with it;
  -- `close` makes sure of it if the wait failed.
  local result, wait_trouble = handle:wait(probe_timeout_ns)
  if result == nil then
    local _, _ = handle:close()
    return { ok = false, why = wait_trouble, broken = true }
  end
  if result.timed_out then
    return { ok = false, why = "a sandboxed start of this program took 30 s", broken = true }
  end
  if not result.ok then
    local said = (result.stdout or ""):gsub("%s+$", "")
    return { ok = false, broken = not host_limit(said), why = "a sandboxed start of this program " ..
        (result.signal ~= nil and ("was killed by signal " .. tostring(result.signal)) or
          ("exited " .. tostring(result.code))) .. (said ~= "" and (": " .. said) or "") }
  end
  return { ok = true, why = "", broken = false }
end

--- Whether this host can run a worker sandboxed: `argv`, this program
--- started again with `env` and `fds`, runs a chunk that holds itself
--- to running anything but this program, as a worker whose test does not
--- declare `tool` does ([`confine.forbid_running`]), under the policy of a
--- worker that declares nothing, in `scratch`. False and why where it
--- cannot: no worker then runs sandboxed, and no verdict is keyed by its
--- declared inputs. The third answer is whether the failure is a defect,
--- not a limit of the host: the run then fails.
--- @return what it found
function test_sandbox_probe.available(argv: {string}, env: {string:string}, fds: {integer:integer},
                                      scratch: string): test_sandbox_probe.Answer
  if not confine.sandbox_platform() then
    return { ok = false, why = "this platform has no sandbox to give a worker", broken = false }
  end
  local unmet = test_policy.unmet()
  if unmet ~= "" then return { ok = false, why = unmet, broken = false } end
  local policy, why = least_policy(argv[1], scratch, env)
  if policy == nil then return { ok = false, why = why, broken = true } end
  local command: {string} = {}
  for i, word in ipairs(argv) do command[i] = word end
  -- As a worker whose test does not declare `tool` holds itself
  -- ([`confine.forbid_running`]): where it cannot, no worker is
  -- sandboxed, since what such a test would run no key holds.
  command[#command + 1] = "-e"
  command[#command + 1] = "local o = require('build.confine') " ..
    "local ok, why = o.forbid_running(o.itself(), { " .. string.format("%q", argv[1]) ..
    " }) if not ok then error(why) end"
  return ran_under(command, fds, policy)
end

--- Where a worker has a private scratch directory that is no `x` grant
--- (`noexec`), at the name a policy gives it.
local noexec_place <const> = "/noexec"

--- Whether a worker given a writable grant without `x` at /noexec can
--- write a file there and not run it, which is what a module that
--- declares `noexec` asks of its private scratch: this program, started
--- again as `available` starts it, under the policy of a worker that
--- declares nothing and that grant. False and why where it cannot.
local function noexec_works(): boolean, string
  local unmet = test_policy.unmet()
  if unmet ~= "" then return false, unmet end
  local launched, _ = Proc.relaunch()
  local start: Proc.Relaunch = launched
  if start == nil then
    local executable, trouble = Proc.executable()
    if executable == nil then return false, trouble end
    start = { argv = { executable }, env = {}, fds = {} }
  end
  local directory, directory_trouble = test_sandbox_probe.directory()
  if directory == nil then return false, directory_trouble end
  local policy, why = least_policy(start.argv[1], directory, start.env)
  if policy == nil then
    local _, _ = Fs.remove_tree(directory)
    return false, why
  end
  local made, made_trouble = Fs.mkdirs(directory .. "/noexec")
  if not made then
    local _, _ = Fs.remove_tree(directory)
    return false, made_trouble
  end
  local grants = policy.grants or {}
  grants[#grants + 1] = { path = noexec_place, from = directory .. "/noexec", letters = "rwc" }
  policy.grants = grants
  local command: {string} = {}
  for i, word in ipairs(start.argv) do command[i] = word end
  command[#command + 1] = "-e"
  command[#command + 1] = [[
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local path = "/noexec/probe"
local bytes = assert(Fs.read("/proc/self/exe"))
assert(Fs.write(path, bytes, 0x1c0))
assert(Fs.read(path) == bytes)
local ok, trouble, errno = sys.execve(path, { path, "-e", "os.exit(97)" }, {})
assert(not ok and errno == sys.EACCES, trouble)
]]
  local answer = ran_under(command, start.fds, policy)
  local _, _ = Fs.remove_tree(directory)
  if not answer.ok then return false, answer.why end
  return true, ""
end

--- Resolves a requested noexec scratch grant before the worker is keyed:
--- `effective.noexec_ready`, and `noexec_trouble` where it is not. The
--- probe runs once a run, its answer kept in `known`.
function test_sandbox_probe.resolve_noexec(effective: test_inputs.Effective, sandboxed: boolean,
                                           known: {string:string})
  effective.noexec_ready, effective.noexec_trouble = false, ""
  if not effective.noexec then return end
  if not sandboxed then
    effective.noexec_trouble = "noexec scratch requires a Linux filesystem sandbox"
    return
  end
  local trouble = known.worker
  if trouble == nil then
    local ok, why = noexec_works()
    trouble = ok and "" or "noexec scratch is unavailable: " .. why
    known.worker = trouble
  end
  effective.noexec_ready, effective.noexec_trouble = trouble == "", trouble
end

return test_sandbox_probe
