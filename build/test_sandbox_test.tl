--- `cosmic test`'s sandboxed worker (build/test_sandbox.tl): what a
--- worker is given, and how what it reports is put back where the host
--- has it. A worker's whole plan, which reads the program it gives, and
--- what a test run with the switch on sees, end to end, are in
--- build/test_sandbox_tool_test.tl.

local Fs = require("cosmic.fs")
local test_inputs = require("build.test_inputs")
local test_sandbox = require("build.test_sandbox")
local test_sandbox_probe = require("build.test_sandbox_probe")

--- An `Effective` holding `files` of the tree and nothing else declared.
local function effective(files: {string}): test_inputs.Effective
  local out: test_inputs.Effective = { files = {}, reads = {}, host = {}, env = {}, network = {},
    tool = false, store = false }
  for _, file in ipairs(files) do out.files[file] = true end
  return out
end

--- A worker's environment is the pinned variables and the ones its
--- module declares, as the runner's view has them; and TMPDIR is its
--- scratch directory, [`test_sandbox.scratch`], whatever the host's.
local function test_a_worker_is_given_only_the_variables_it_may_read()
  local view = { PATH = "/bin", DECLARED = "d", UNDECLARED = "u", TMPDIR = "/elsewhere",
    COSMIC_SANDBOX = "must" }
  local inputs = effective({})
  inputs.env = { PATH = true, TMPDIR = true, DECLARED = true }
  local env = test_sandbox.environment(view, inputs)
  assert(env.PATH == "/bin" and env.DECLARED == "d" and env.UNDECLARED == nil)
  assert(env.TMPDIR == test_sandbox.scratch)
  assert(env.COSMIC_SANDBOX == nil, "only what is pinned or declared is given")
end

--- Run unsandboxed, a worker that declares the `bootstrap` cache has
--- the host's cores, not the sandbox's own, whose path no host has: a
--- compiler build/c/init.tl confines to them would not start.
local function test_an_unenforced_worker_has_the_hosts_cores()
  local inputs = effective({})
  inputs.caches = { "bootstrap" }
  local sandboxed = test_sandbox.environment({ PATH = "/bin" }, inputs)
  assert(sandboxed.COSMIC_PORTABLE_CACHE ~= nil)
  local env = test_sandbox.unenforced_environment({ PATH = "/bin" }, inputs, "/host/scratch", "/host/tree")
  assert(env.TMPDIR == "/host/scratch" and env.COSMIC_PORTABLE_CACHE == nil,
    tostring(env.COSMIC_PORTABLE_CACHE))
  local named = test_sandbox.unenforced_environment({ COSMIC_PORTABLE_CACHE = "/host/cores" },
    inputs, "/host/scratch", "/host/tree")
  assert(named.COSMIC_PORTABLE_CACHE == "/host/cores", tostring(named.COSMIC_PORTABLE_CACHE))
end

--- A failure to start a sandbox where the kernel refuses a user
--- namespace is said plainly, naming why; any other is as it was.
local function test_a_refused_user_namespace_is_said_plainly()
  local none = test_sandbox.refusal("start: No space left on device")
  assert(none:find("allows no user namespaces", 1, true) and
      none:find("No space left on device", 1, true), none)
  for _, errno in ipairs({ "Operation not permitted", "Permission denied" }) do
    local refused = test_sandbox.refusal("start: " .. errno)
    assert(refused:find("refuses this user a user namespace", 1, true), refused)
    -- A Landlock domain, which a test worker's process may be held by,
    -- refuses a mount EPERM alone.
    assert((refused:find("held by a Landlock ruleset: declare the promise \"nest\" in the " ..
        "starting test's Test.policy", 1, true) ~= nil) == (errno == "Operation not permitted"),
      refused)
  end
  assert(test_sandbox.refusal("start: Bad address") == "start: Bad address")
end

--- A worker that may write where this program is -- the cores a
--- portable cosmic extracts, in the `bootstrap` cache -- cannot be kept
--- from running it, by its name or through a link; one that writes
--- elsewhere can.
local function test_a_worker_that_writes_where_the_program_is_cannot_be_held(tmp: string)
  local cores = tmp .. "/cache/cores"
  assert(Fs.mkdirs(cores))
  assert(Fs.write(cores .. "/core", "c"))
  assert(Fs.symlink(cores .. "/core", tmp .. "/link"))
  assert(test_sandbox.forbiddable({ tmp .. "/elsewhere" }, { cores .. "/core" }))
  assert(test_sandbox.forbiddable({}, { cores .. "/core" }))
  assert(not test_sandbox.forbiddable({ tmp .. "/cache" }, { cores .. "/core" }))
  assert(not test_sandbox.forbiddable({ tmp .. "/cache" }, { tmp .. "/link" }))
end

local function test_only_a_granted_noexec_capability_supplies_its_environment()
  local inputs = effective({})
  inputs.env = { COSMIC_TEST_NOEXEC = true, TMPDIR = true }
  local host = { COSMIC_TEST_NOEXEC = "/forged", TMPDIR = "/host" }
  assert(test_sandbox.environment(host, inputs).COSMIC_TEST_NOEXEC == nil)
  inputs.noexec = true
  assert(test_sandbox.environment(host, inputs).COSMIC_TEST_NOEXEC == nil)
  inputs.noexec_ready = true
  local granted = test_sandbox.environment(host, inputs)
  assert(granted.COSMIC_TEST_NOEXEC == "/noexec")
  assert(granted.TMPDIR == test_sandbox.scratch)
  assert(test_sandbox.unenforced_view(host, inputs).COSMIC_TEST_NOEXEC == nil)
  assert(test_sandbox.unenforced_environment(host, inputs, "/scratch", "/tree").COSMIC_TEST_NOEXEC == nil)
end

local function test_noexec_does_not_probe_an_ordinary_or_unsandboxed_worker()
  local inputs = effective({})
  local known: {string:string} = {}
  test_sandbox_probe.resolve_noexec(inputs, true, known)
  assert(not inputs.noexec_ready and next(known) == nil)
  inputs.noexec = true
  test_sandbox_probe.resolve_noexec(inputs, false, known)
  assert(not inputs.noexec_ready and next(known) == nil)
  assert(inputs.noexec_trouble:find("requires a Linux filesystem sandbox", 1, true))
end
