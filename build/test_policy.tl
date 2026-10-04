--- The policy path of `cosmic test`'s workers: with `COSMIC_TEST_POLICY=1`
--- (`--policy`), each sandboxed worker starts under a [`cosmic.sandbox`]
--- policy by [`Child.start`] instead of the sandbox [`build.test_sandbox`]
--- plans for it, as the design's test phase has it: a policy of its own
--- that names the tree at /tree, the scratch directory with `rwxc`, the
--- store at o/cosmic.db, the core, and what the module declares, with
--- `isolate` "file" and a /proc of the sandbox's own. The paths are
--- [`test_sandbox.plan`]'s, taken as it plans them for the policy
--- (`policy`); this module turns them into grants and the rest of the
--- declaration into the policy's other fields, or refuses the module,
--- naming the field, where the policy has nothing to say it with. A module
--- never runs less confined than it declares: what is refused fails its
--- tests.
---
--- What the declaration becomes:
---
--- - `reads` and the closure's files are `r` grants at /tree, the core and
---   the program `rx`, o/bin `rx` for `tool`, the store at o/cosmic.db a
---   grant by `from`, and a `host` path a grant at its own name;
--- - `system` is the profile "system", whose paths are the policy's, not
---   `/etc` whole;
--- - a host cache and the scratch directory are `rwxc` grants, and the
---   private noexec scratch `noexec` asks for is a writable grant without
---   `x`, at /noexec;
--- - `nests` is the promise "nest", `network` is `loopback`, and the
---   variables a worker is given are its `set_env`, the policy being the
---   whole of its environment ([`worker.invocation`] sets it);
--- - `lua` and `standalone` say what the worker holds the processes of
---   its test to (a hold of the store, not of the sandbox) and need no
---   field.
---
--- Refused: `env = { "*" }`, which no policy holds (it names each variable).
-- TODO: let a worker hold itself with [`Sandbox.restrict`] to what its
-- module declares, with the runner's own reads (the store, the core, the
-- report) granted only to the start, once the policy path is the default
-- (step (c) of the sandbox plan, doc/plans/sandbox.md): today the worker
-- is held from its first instruction by the whole policy it is started
-- under, which is all that it and its test may reach.

local type Sandbox = require("cosmic.sandbox")
local test_inputs = require("build.test_inputs")
local test_sandbox = require("build.test_sandbox")

local record test_policy
  --- The variable that turns the policy path on.
  switch: string
end

test_policy.switch = "COSMIC_TEST_POLICY"

--- The promises every worker is started with: all that a test may make
--- but `nest` ([`worker_promises`]).
-- TODO: hold a worker by the promises its module declares
-- ([`Test.policy`]'s `promises`) rather than all but `nest`, once the
-- tests declare them (step (d) of the sandbox plan, which puts the filter
-- on every worker and bumps the epoch): until then no test can say what it
-- makes, and the filter refuses only what no test is meant to.
-- TODO: let a worker signal the processes it starts, once Landlock's signal
-- scope holds a sandbox's signals to itself (the TODO at core/promises.c's
-- RULE_PID_SELF): the filter refuses a `kill` of any pid but the worker's
-- own, so a test that ends what it started (a [`Child.Handle`] closed, a stop,
-- a timeout) fails under the policy path with "still has members after
-- SIGKILL". A boot, and step (d), are what lift it.
-- TODO: grant the scratch directory `u`, so a test may bind a unix socket
-- there, once the kernels the suite runs on give Landlock ABI 9
-- (cosmic/child.tl's `unix_unheld`): below it a `u` grant beside another
-- directory fails the start, and without one the filter refuses the
-- socket, so a test of a unix socket fails EPERM under the policy path.
local base_promises <const>: {Sandbox.Promise} = { "fattr", "fork", "jit" }

--- The devices a worker is given, as the policy's letters have them: the
--- bit bucket, zeros and `/dev/full` (a write there fails with ENOSPC) are
--- written as well as read; entropy only read.
local devices <const>: {string:string} = {
  ["/dev/null"] = "rw", ["/dev/zero"] = "rw", ["/dev/full"] = "rw", ["/dev/urandom"] = "r",
}

--- What `COSMIC_TEST_POLICY` asks for: true for "1", false for unset, empty
--- or "0". Any other value is an error, so a misspelt one never passes for
--- either.
--- @param value the variable's value, nil where it is unset
--- @return whether the policy path is asked for, nil on an error
--- @return why, on an error
function test_policy.requested(value: string | nil): boolean | nil, string
  if value == nil or value == "" or value == "0" then return false, "" end
  if value == "1" then return true, "" end
  return nil, string.format("%s is %q: set it to 1 to run workers under a policy, 0 or leave " ..
      "it unset for the sandbox they have by default", test_policy.switch, value)
end

--- The promises of a worker: `base_promises`, and `nest` where its module
--- declares `nests`, whose tests build roots of their own.
local function worker_promises(nests: boolean): {Sandbox.Promise}
  local out: {Sandbox.Promise} = {}
  for _, promise in ipairs(base_promises) do out[#out + 1] = promise end
  if nests then out[#out + 1] = "nest" end
  return out
end

--- The fields of the policy of a worker of `effective` that name no path:
--- what is the same wherever the tree is and whatever is declared beside it
--- ([`test_policy.worker`] adds the paths).
local function shape(effective: test_inputs.Effective): Sandbox.Policy
  local loopback: {string} = {}
  for address in pairs(effective.network) do loopback[#loopback + 1] = address end
  table.sort(loopback)
  return {
    profiles = effective.system and { "system" } or nil,
    isolate = { "file" },
    promises = worker_promises(effective.nests),
    loopback = loopback,
  }
end

--- Why a worker of `effective` cannot be started under a policy, or "":
--- what its module declares that no policy says, naming the field.
--- @param effective what the module declares, as the runner resolved it
--- @return why, "" for nothing
-- TODO: delete this refusal, and the `"*"` that [`Test.needs`] still takes,
-- once the four unsandboxed fixtures under ci/fixtures name the variables
-- they read (each carries the TODO saying why it cannot yet) and the policy
-- path is the default (step (c) of the sandbox plan): a policy has no
-- wildcard.
-- TODO: start the worker of a module that declares `nests` without the
-- descriptors of its core and artifact that [`Proc.relaunch`] hands it,
-- once a worker can find them by path (or the nest promise can hand a
-- read-only descriptor its holder cannot reopen): [`Child.start`] refuses a
-- file open for reading alone to a nest child, so each such module fails
-- under the policy path, naming the descriptor.
local function refusal(effective: test_inputs.Effective): string
  if effective.env["*"] then
    return 'env "*": the policy path names each variable a worker is given, and a policy ' ..
      'has no wildcard; name the variables the module reads'
  end
  return ""
end

--- The part of every worker's policy that is the same for all of them and
--- that a verdict's key holds: the isolation and the promises every worker
--- has, as text, whatever its module declares. A change to either is a
--- change to what every worker is held to, so it names the runtime the
--- key holds ([`build.test`]'s `runtime`); what a module declares is in its
--- key already, by `effective`.
--- @return the text
function test_policy.common(): string
  return "isolate file\npromises " .. table.concat(worker_promises(false), " ")
end

--- The letters a read of the plan at host path `path` is granted: `rx` for
--- what the plan says is run (`runs`), what a device allows, else `r`.
local function letters_of(path: string, inside: string, runs: {string:boolean}): string
  if devices[inside] ~= nil then return devices[inside] end
  if runs[path] then return "rx" end
  return "r"
end

--- The policy a worker of `effective` is started under, from the paths of
--- `plan` (made for the policy, [`test_sandbox.plan`]'s `policy`). Nil and why where the module declares what a policy cannot say
--- (`refusal`). It has no `set_env`: the worker's environment is whole
--- only once what starts it is added ([`worker.invocation`]).
--- @param plan the worker's paths
--- @param effective what its module declares
--- @return the policy, nil where it is refused
--- @return why it is refused
function test_policy.worker(plan: test_sandbox.Plan,
                            effective: test_inputs.Effective): Sandbox.Policy | nil, string
  local refused = refusal(effective)
  if refused ~= "" then return nil, refused end
  local policy = shape(effective)
  local unveil = plan.sandbox.unveil
  local at = unveil.at or {}
  local grants: {Sandbox.Grant} = {}
  for _, path in ipairs(unveil.reads) do
    local inside = at[path] or path
    grants[#grants + 1] = { path = inside, from = at[path] ~= nil and path or nil,
      letters = letters_of(path, inside, plan.runs) }
  end
  local scratch: string = nil
  for _, path in ipairs(unveil.writes) do
    local inside = at[path] or path
    grants[#grants + 1] = { path = inside, from = at[path] ~= nil and path or nil, letters = "rwxc" }
    scratch = scratch or path
  end
  -- The private noexec scratch: a writable grant without `x`, which the
  -- root of `isolate` "file" mounts noexec ([`build.test`]'s `launch` makes
  -- the directory it is bound from).
  if effective.noexec_ready and scratch ~= nil then
    grants[#grants + 1] = { path = "/noexec", from = scratch .. "/noexec", letters = "rwc" }
  end
  policy.grants = grants
  return policy, ""
end

return test_policy
