--- Whether this host can run a test worker sandboxed (`available`).
--- `cosmic test` asks once a run, before it starts a worker
--- ([`build.test`]'s `sandbox_here`). This is not build/sandbox_probe.tl,
--- CI's report of what spawn's sandbox can hold a child to on a host.
---
--- It is no part of the test harness (build/harness_epoch.tl): it decides
--- whether a run is sandboxed, not what a sandboxed worker is given
--- ([`build.test_sandbox`]'s `plan`) nor how one is judged, and a wrong
--- answer fails loudly, never passes:
---
--- - Answered wrongly yes, every worker is started sandboxed by the plan
---   and holds itself by [`confine.forbid_running`]. Where the host can do
---   neither, the start or the worker fails, and each test with it,
---   naming why.
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
local confine = require("build.confine")
local test_sandbox = require("build.test_sandbox")
local Time = require("cosmic.time")

local record test_sandbox_probe
end

--- Whether this host can run a worker sandboxed: `argv`, this program
--- started again with `env` and `fds`, runs a chunk that holds itself
--- to running anything but this program, as a worker whose test does not
--- declare `tool` does ([`confine.forbid_running`]), held to the
--- least a worker is given -- /proc, the devices and the program, none
--- of the system's own paths -- offline, in `scratch`. False and why
--- where it cannot: no worker then runs sandboxed, and no verdict is
--- keyed by its declared inputs.
function test_sandbox_probe.available(argv: {string}, env: {string:string}, fds: {integer:integer},
                                      scratch: string): boolean, string
  local base = confine.worker_unveil(scratch, nil, scratch)
  local command: {string} = {}
  for i, word in ipairs(argv) do command[i] = word end
  -- As a worker whose test does not declare `tool` holds itself
  -- ([`confine.forbid_running`]): where it cannot, no worker is
  -- sandboxed, since what such a test would run no key holds.
  command[#command + 1] = "-e"
  command[#command + 1] = "local o = require('build.confine') " ..
    "local ok, why = o.forbid_running(o.itself()) if not ok then error(why) end"
  local given: {integer:integer | string} = {}
  for number, fd in pairs(fds) do given[number] = fd end
  -- Started and waited for, not [`Child.run`], which would take the one
  -- signal guard a caller running tests in-process may hold.
  -- No group of its own to end, nor strays to adopt: its sandbox gives
  -- it a pid namespace of its own, which ends when it does.
  local handle, trouble = Child.start(command, { env = env, fds = given,
    cwd = test_sandbox.scratch, stdin = "null", stdout = "capture", stderr = "stdout",
    process_group = false, sandbox = { unveil = { reads = base.reads, writes = { scratch },
      at = { [scratch] = test_sandbox.scratch } }, offline = true } })
  if handle == nil then return false, test_sandbox.refusal(trouble) end
  -- Past the bound, `wait` ends it, and its pid namespace with it;
  -- `close` makes sure of it if the wait failed.
  local result, wait_trouble = handle:wait(Time.seconds(30))
  if result == nil then
    local _, _ = handle:close()
    return false, wait_trouble
  end
  if result.timed_out then return false, "a sandboxed start of this program took 30 s" end
  if not result.ok then
    local said = (result.stdout or ""):gsub("%s+$", "")
    return false, "a sandboxed start of this program " ..
      (result.signal ~= nil and ("was killed by signal " .. tostring(result.signal)) or
        ("exited " .. tostring(result.code))) .. (said ~= "" and (": " .. said) or "")
  end
  return true, ""
end

--- A fresh directory to probe the sandbox in (`available`), removed by
--- the caller.
function test_sandbox_probe.directory(): string | nil, string
  local made, trouble = Fs.mkdtemp("cosmic-sandbox-probe-")
  if made == nil then return nil, trouble end
  return Fs.absolute(made)
end

return test_sandbox_probe
