--- The policy of each of `cosmic test`'s workers wherever they are
--- sandboxed: each starts under a [`cosmic.sandbox`] policy by
--- [`Child.start`], as the design's test phase has it: a policy of its own
--- that names the tree at /tree, the scratch directory with `rwxc`, the
--- store at o/cosmic.db, the core, and what the module declares, with
--- `isolate` "file" and a /proc of the sandbox's own. Where nothing the
--- module declares puts a directory of the host in the root
--- ([`test_sandbox.Plan`]'s `own_scratch`), the scratch directory is not a
--- bind of the host's either but a directory the worker makes in the
--- sandbox's own /tmp (`tmp`, with "/tmp" granted `rwxc`): a root of files
--- alone and a tmpfs of its own, which holds a unix socket the worker makes
--- below Landlock ABI 9, and, for a worker that declares `nests` and so has
--- no ruleset, at any ABI (core/syscalls.c's `root_shows_no_socket`). The paths are
--- [`test_sandbox.plan`]'s; this module turns them into grants and the rest of the
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
--- - a host cache and the scratch directory (where that is the host's) are
---   `rwxc` grants, and the
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
-- report) granted only to the start, as a step after the policy path
-- became the default (#2621's doc/plans/sandbox.md): today the worker is
-- held from its first instruction by the whole policy it is started
-- under, which is all that it and its test may reach.

local Sandbox = require("cosmic.sandbox")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local test_inputs = require("build.test_inputs")
local test_sandbox = require("build.test_sandbox")

local record test_policy
end

--- The promises every worker is started with: all that a test may make
--- but `nest` ([`worker_promises`]).
-- TODO: hold a worker by the promises its module declares
-- ([`Test.policy`]'s `promises`) rather than all but `nest`, once the
-- tests declare them (step (e) of the plan, which replaces [`Test.needs`]
-- with [`Test.policy`]): until then no test can say what it makes, and the
-- filter refuses only what no test is meant to.
local base_promises <const>: {Sandbox.Promise} = { "fattr", "fork", "jit" }

--- The devices a worker is given, as the policy's letters have them: the
--- bit bucket, zeros and `/dev/full` (a write there fails with ENOSPC) are
--- written as well as read; entropy only read.
local devices <const>: {string:string} = {
  ["/dev/null"] = "rw", ["/dev/zero"] = "rw", ["/dev/full"] = "rw", ["/dev/urandom"] = "r",
}

--- Why this process cannot start a worker under a policy, or "": a program
--- of a policy never runs as root, so a process that is root -- the
--- host's, or a sandbox's own, which maps root alone -- must map a user of
--- its own for it, which takes CAP_SETUID, CAP_SETGID and CAP_SETFCAP in
--- effect ([`confine.may_map_ids`]). Where it lacks them every start would
--- fail, so a run there runs its workers unsandboxed ([`build.test_sandbox_probe`]).
--- @return why, "" for nothing
function test_policy.unmet(): string
  if sys.getuid() ~= 0 or confine.may_map_ids() then return "" end
  return "this process is root without CAP_SETUID, CAP_SETGID and CAP_SETFCAP in effect, " ..
    "so it cannot map the user a worker under a policy runs as (never root)"
end

--- The promises of a worker: `base_promises`, and `nest` where its module
--- declares `nests`, whose tests build roots of their own.
local function worker_promises(nests: boolean): {Sandbox.Promise}
  local out: {Sandbox.Promise} = {}
  for _, promise in ipairs(base_promises) do out[#out + 1] = promise end
  if nests then out[#out + 1] = "nest" end
  return out
end

--- The most descriptors a worker's policy lets it hold open, where the
--- runner's own hard limit is higher.
local MOST_OPEN_FILES <const> = 1048576

--- The fields of the policy of a worker of `effective` that name no path:
--- what is the same wherever the tree is and whatever is declared beside it
--- ([`test_policy.worker`] adds the paths).
local function shape(effective: test_inputs.Effective): Sandbox.Policy
  local loopback: {string} = {}
  for address in pairs(effective.network) do loopback[#loopback + 1] = address end
  table.sort(loopback)
  -- A policy's descriptors default to 1024, soft and hard, where a default
  -- sandbox's worker has the runner's limits: a test that holds more open
  -- is given the runner's hard limit, as both, since the core sets the two
  -- alike and a worker cannot raise its soft one past it. The limit is no
  -- part of a key, as the runner's own, which a default worker inherits,
  -- is none.
  local limits: Sandbox.Limits = {}
  local held, _ = sys.getrlimit(sys.RLIMIT_NOFILE)
  if held ~= nil then limits.open_files = math.min(held.hard, MOST_OPEN_FILES) end
  return {
    profiles = effective.system and { "system" } or nil,
    isolate = { "file" },
    promises = worker_promises(effective.nests),
    loopback = loopback,
    limits = limits,
  }
end

--- Why a worker of `effective` cannot be started under a policy, or "":
--- what its module declares that no policy says, naming the field. A
--- refusal fails its tests.
--- @param effective what the module declares, as the runner resolved it
--- @return why, "" for nothing
-- TODO: delete this refusal, and the `"*"` that [`Test.needs`] still takes,
-- once the four unsandboxed fixtures under ci/fixtures name the variables
-- they read (each carries the TODO saying why it cannot yet), and the two
-- tests that declare one on purpose are reworked (build/test_policy_tool_test.tl's
-- wildcard_test.tl and build/test_isolation_tool_test.tl's hooks_test.tl,
-- snippets of the wildcard itself): a policy has no wildcard. It waits on
-- step (e) of the sandbox plan, which deletes [`Test.needs`].
local function refusal(effective: test_inputs.Effective): string
  if effective.env["*"] then
    return 'env "*": the policy path names each variable a worker is given, and a policy ' ..
      'has no wildcard; name the variables the module reads'
  end
  return ""
end

--- The part of every worker's policy that is the same for all of them and
--- that a verdict's key holds: the isolation, the promises every worker
--- has, as text, whatever its module declares. A change to either is a
--- change to what every worker is held to, so it names the runtime the key holds ([`build.test`]'s `runtime`); what
--- a module declares is in its key already, by `effective`.
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
--- `plan` ([`test_sandbox.plan`]). Nil and why where the module declares what a policy cannot say
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
  -- A worker whose root shows no directory of the host has its scratch
  -- directory in the sandbox's own /tmp, which `tmp` makes, granted
  -- `rwxc` as the host's directory is: its test may run what it writes.
  if plan.own_scratch then
    policy.tmp = true
    grants[#grants + 1] = { path = "/tmp", letters = "rwxc" }
  end
  policy.grants = grants
  return policy, ""
end

--- The paths `policy` lets a worker run, as its profiles resolve: those of
--- its grants with `x`.
--- @param policy the policy of a worker
--- @return the paths, in the policy's order, nil and why where it does not merge
--- @return why, where it does not
function test_policy.runs(policy: Sandbox.Policy): {string} | nil, string
  local merged, why = Sandbox.merge(policy)
  if merged == nil then return nil, why end
  local out: {string} = {}
  for _, grant in ipairs(merged.grants) do
    if grant.letters:find("x", 1, true) then out[#out + 1] = grant.path end
  end
  return out, ""
end

return test_policy
