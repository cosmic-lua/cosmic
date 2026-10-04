--- The policy path of `cosmic test`'s workers (build/test_policy.tl): what a
--- worker's declaration becomes in the policy it is started under, and
--- what a policy cannot say is refused, naming the field. The end to end
--- cases, a run of `cosmic test` under the policy, are in
--- build/test_policy_tool_test.tl.

local Sandbox = require("cosmic.sandbox")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local test_inputs = require("build.test_inputs")
local test_policy = require("build.test_policy")
local test_sandbox = require("build.test_sandbox")

--- An `Effective` that declares nothing.
local function effective(): test_inputs.Effective
  return { files = {}, reads = {}, host = {}, env = {}, network = {}, tool = false, store = false }
end

--- The plan of a worker that reads `reads`, writes `writes`, with `at`
--- giving the place a host path has in the sandbox and `runs` the reads
--- that are run.
local function plan_of(reads: {string}, writes: {string}, at: {string:string},
                       runs: {string}): test_sandbox.Plan
  local running: {string:boolean} = {}
  for _, path in ipairs(runs) do running[path] = true end
  return { sandbox = { unveil = { reads = reads, writes = writes, at = at }, offline = true },
    env = {}, over = 0, trouble = "", runs = running }
end

--- The grant of `policy` at `path`, or nil.
local function grant_at(policy: Sandbox.Policy, path: string): Sandbox.Grant | nil
  for _, grant in ipairs(policy.grants) do
    if grant.path == path then return grant end
  end
  return nil
end

--- Whether `list` holds `value`.
local function holds(list: {string}, value: string): boolean
  for _, each in ipairs(list) do
    if each == value then return true end
  end
  return false
end

--- The policy of a worker, or fails the test saying why not.
local function worker_of(plan: test_sandbox.Plan, inputs: test_inputs.Effective): Sandbox.Policy
  local policy, why = test_policy.worker(plan, inputs)
  assert(policy ~= nil, tostring(why))
  return policy
end

--- The switch asks for the policy path with "1", for the old sandbox with
--- "0", and for the default (the policy path where workers are sandboxed)
--- with nothing or ""; any other value is an error naming the variable, so
--- a misspelt one never passes for any of them.
local function test_the_switch_is_one_zero_or_unset()
  assert(test_policy.requested(nil) == "default")
  assert(test_policy.requested("") == "default")
  assert(test_policy.requested("0") == "off")
  assert(test_policy.requested("1") == "on")
  local asked, why = test_policy.requested("yes")
  assert(asked == nil and why:find('COSMIC_TEST_POLICY is "yes"', 1, true), tostring(why))
end

--- A process that is root and may not map a user for a program (a container
--- without CAP_SETFCAP, a sandbox's own root) cannot start a worker under a
--- policy, which never runs as root, and says why; any other can.
local function test_only_a_root_that_may_not_map_cannot_start_a_policy()
  local why = test_policy.unmet()
  if sys.getuid() ~= 0 or confine.may_map_ids() then
    assert(why == "", why)
  else
    assert(why:find("CAP_SETFCAP", 1, true), why)
  end
end

--- What a worker reads of the tree is a read at its name in the sandbox,
--- bound from where the host has it; the core and the program are run;
--- the devices are written where a program takes them to be; its
--- scratch directory and each cache it declares are written, run and
--- created in; and the private noexec scratch is a writable grant without
--- `x`, which the root of `isolate` "file" mounts noexec.
local function test_each_path_of_the_plan_is_a_grant_with_the_letters_it_needs()
  local scratch = "/host/scratch"
  local inputs = effective()
  local plan = plan_of(
    { "/host/core", "/host/tree/a.tl", "/dev/null", "/dev/zero", "/dev/full", "/dev/urandom",
      "/host/etc/passwd" },
    { scratch, "/host/cache" },
    { [scratch] = test_sandbox.scratch, ["/host/tree/a.tl"] = "/tree/a.tl" },
    { "/host/core" })
  local policy = worker_of(plan, inputs)
  local function granted(path: string, letters: string, from?: string)
    local grant = grant_at(policy, path)
    assert(grant ~= nil, path .. " is not granted")
    assert(grant.letters == letters, path .. ": " .. grant.letters .. ", not " .. letters)
    assert(grant.from == from, path .. " from " .. tostring(grant.from))
  end
  granted("/host/core", "rx")
  granted("/tree/a.tl", "r", "/host/tree/a.tl")
  granted("/host/etc/passwd", "r")
  granted("/dev/null", "rw")
  granted("/dev/zero", "rw")
  granted("/dev/full", "rw")
  granted("/dev/urandom", "r")
  granted(test_sandbox.scratch, "rwxc", scratch)
  granted("/host/cache", "rwxc")
  assert(grant_at(policy, "/noexec") == nil, "no noexec scratch unless it is ready")
  inputs.noexec_ready = true
  policy = worker_of(plan, inputs)
  granted("/noexec", "rwc", scratch .. "/noexec")
end

--- A worker is held to the root of its own, a /proc of its own among it
--- (`isolate` "file"), and to the promises every worker has; `nest`
--- only where its module declares `nests`, since it gives up the ruleset
--- that holds the paths. The loopback addresses it declares are its
--- own, in order; the system, a profile.
local function test_the_declaration_beside_the_paths_is_the_policys_other_fields()
  local plan = plan_of({}, { "/host/scratch" }, { ["/host/scratch"] = test_sandbox.scratch }, {})
  local inputs = effective()
  local policy = worker_of(plan, inputs)
  assert(#policy.isolate == 1 and policy.isolate[1] == "file")
  assert(holds(policy.promises, "fork") and holds(policy.promises, "fattr") and
      holds(policy.promises, "jit") and not holds(policy.promises, "nest"),
    table.concat(policy.promises, ","))
  assert(policy.profiles == nil and #policy.loopback == 0)
  inputs.nests, inputs.system, inputs.tool = true, true, true
  inputs.network = { ["127.0.0.3"] = true, ["127.0.0.1"] = true }
  policy = worker_of(plan, inputs)
  assert(holds(policy.promises, "nest"), table.concat(policy.promises, ","))
  assert(#policy.profiles == 1 and policy.profiles[1] == "system")
  assert(table.concat(policy.loopback, " ") == "127.0.0.1 127.0.0.3",
    table.concat(policy.loopback, " "))
  -- Whole, as a start takes it: merging it refuses nothing.
  local merged, why = Sandbox.merge(policy)
  assert(merged ~= nil, tostring(why))
end

--- What a policy has no word for is refused, naming the field, rather than
--- run with less than the module declares: the whole environment, which
--- a policy spells name by name.
local function test_a_wildcard_environment_is_refused_naming_the_field()
  local inputs = effective()
  inputs.env = { ["*"] = true }
  local policy, why = test_policy.worker(plan_of({}, {}, {}, {}), inputs)
  assert(policy == nil and why:find('env "*"', 1, true) and why:find("wildcard", 1, true),
    tostring(why))
  inputs.env = { PATH = true }
  assert(test_policy.worker(plan_of({}, {}, {}, {}), inputs) ~= nil)
end

--- What every worker's policy has alike is text a key's runtime can hold:
--- the same each time, naming the isolation and the promises, and no
--- `nest`, which only a module that declares `nests` has.
local function test_what_every_policy_has_alike_is_text()
  local text = test_policy.common()
  assert(text == test_policy.common())
  assert(text:find("isolate file", 1, true) and text:find("fork", 1, true) and
      not text:find("nest", 1, true), text)
end

--- The paths a policy lets a worker run are those of its grants with `x`,
--- in the policy's order.
local function test_the_paths_a_policy_runs_are_its_grants_with_x()
  local policy: Sandbox.Policy = { grants = {
    { path = "/tree/a", letters = "r" }, { path = "/tree/b", letters = "rx" },
    { path = "/tree/c", letters = "rwxc" } } }
  local runs = assert(test_policy.runs(policy))
  assert(#runs == 2 and runs[1] == "/tree/b" and runs[2] == "/tree/c", table.concat(runs, " "))
end

--- A worker's policy gives it the descriptors the runner may hold, for a
--- test that raises its own limit past a policy's default.
local function test_a_workers_policy_has_the_runners_descriptor_limit()
  local shaped = test_policy.worker(plan_of({}, {}, {}, {}), effective())
  local held = sys.getrlimit(sys.RLIMIT_NOFILE)
  assert(shaped ~= nil and held ~= nil and shaped.limits.open_files == math.min(held.hard, 1048576))
end
