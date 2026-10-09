--- The plan a worker is given under a policy (build/test_policy.tl and
--- build/test_sandbox.tl), made and read without starting a worker: what it
--- leaves to the policy, how it is rebound to another scratch directory,
--- and when the worker has a scratch directory of its own. One case starts
--- this program, so these declare `tool`. They need no sandbox, so they run
--- wherever the program does; the runs under a policy are in
--- `test_policy_tool_test.tl`.

-- TODO: move the dots test and the nesting-artifact test below, which return
-- silently where the run is not a portable artifact, to a module that
-- declares `requires = { "portable" }` (build/host_names.tl names it), so such
-- a run counts them not applicable. It waits on a fixture module that shares
-- `effective`, [`scratch_in`] and `holds` with this one, which both modules need.

local type Sandbox = require("cosmic.sandbox")
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")
local Test = require("cosmic.test")
local test_inputs = require("build.test_inputs")
local test_policy = require("build.test_policy")
local test_sandbox = require("build.test_sandbox")
local this_program = require("build.this_program")
local build_paths = require("build.paths")

--- The program itself, which the case that starts it runs.
Test.policy{
  profiles = { "cosmic", "system" },
  grants = { { path = "o/bin", letters = "rx" } },
}

--- `root`'s build directory ([`build.paths`]), made, with `root` made
--- first where it is not there yet.
local function build_dir(root: string): string
  assert(Fs.mkdirs(root))
  return (assert(build_paths.prepare(root)))
end

--- An `Effective` holding `files` of the tree and nothing else declared.
local function effective(files: {string}): test_inputs.Effective
  local out: test_inputs.Effective = { files = {}, reads = {}, host = {}, env = {}, network = {},
    tool = false, store = false }
  for _, file in ipairs(files) do out.files[file] = true end
  return out
end

--- Makes `tmp`/scratch, a scratch directory laid out as build.test's
--- `scratch` lays one out -- `real`, and `tmp` a link to it -- and
--- answers it.
local function scratch_in(tmp: string): string
  local scratch = tmp .. "/scratch"
  assert(Fs.mkdirs(scratch .. "/real"))
  assert(Fs.symlink("real", scratch .. "/tmp"))
  return scratch
end

--- Whether `list` holds `value`.
local function holds(list: {string}, value: string): boolean
  for _, each in ipairs(list) do
    if each == value then return true end
  end
  return false
end

--- A plan leaves to the policy what a policy has of its own: no /proc of the
--- host's, which the sandbox replaces with its own, and no system paths,
--- which the profile "system" gives; the program and its core are the
--- reads that are run, and a worker that declares `tool` runs o/bin.
local function test_a_plan_for_the_policy_leaves_the_system_and_proc_to_the_policy(tmp: string)
  local root, scratch = tmp .. "/root", scratch_in(tmp)
  assert(Fs.mkdirs(build_dir(root) .. "/bin"))
  assert(Fs.write(build_dir(root) .. "/cosmic.db", "x"))
  local inputs = effective({})
  inputs.system, inputs.tool = true, true
  inputs.host = { "/proc", "/dev/urandom" }
  local policy = test_sandbox.plan(root, scratch, inputs, {})
  assert(policy.trouble == "", policy.trouble)
  local reads = policy.sandbox.unveil.reads
  assert(not holds(reads, "/proc") and not holds(reads, "/usr") and not holds(reads, "/etc"),
    table.concat(reads, " "))
  assert(holds(reads, "/dev/urandom") and holds(reads, "/dev/null"))
  assert(policy.sandbox.user == nil, "a policy chooses the user")
  assert(policy.runs[build_dir(root) .. "/bin"] == true)
end

--- The plan of one module made once a run is rebound to the scratch
--- directory of each later worker ([`test_sandbox.rebind`]): the plan made
--- afresh for that directory, whatever the scratch directory is the
--- plan's path of, and a copy that shares nothing with the first.
local function test_a_plan_rebound_to_another_scratch_is_the_plan_made_for_it(tmp: string)
  local root = tmp .. "/root"
  assert(Fs.mkdirs(build_dir(root) .. "/bin"))
  assert(Fs.write(build_dir(root) .. "/cosmic.db", "x"))
  assert(Fs.write(root .. "/a.tl", "x"))
  for _, own in ipairs({ true, false }) do
    local inputs = effective({ "a.tl" })
    -- A cache the module declares makes its scratch directory a bind of the host's.
    if not own then inputs.tool = true end
    local suffix = tostring(own)
    local first, second = scratch_in(tmp .. "/one" .. suffix), scratch_in(tmp .. "/two" .. suffix)
    local made = test_sandbox.plan(root, first, inputs, {})
    assert(made.trouble == "", made.trouble)
    local rebound = test_sandbox.rebind(made, first, second, inputs)
    local fresh = test_sandbox.plan(root, second, inputs, {})
    assert(rebound.trouble == "" and rebound.own_scratch == fresh.own_scratch)
    local function same(a: {string}, b: {string}, what: string)
      assert(table.concat(a, " ") == table.concat(b, " "), what .. ": " .. table.concat(a, " ") ..
          " is not " .. table.concat(b, " "))
    end
    same(rebound.sandbox.unveil.reads, fresh.sandbox.unveil.reads, "reads")
    same(rebound.sandbox.unveil.writes, fresh.sandbox.unveil.writes, "writes")
    for path, inside in pairs(fresh.sandbox.unveil.at) do
      assert(rebound.sandbox.unveil.at[path] == inside, path)
    end
    for path in pairs(rebound.sandbox.unveil.at) do
      assert(fresh.sandbox.unveil.at[path] ~= nil, path)
    end
    for path in pairs(fresh.runs) do assert(rebound.runs[path], path) end
    assert(not holds(rebound.sandbox.unveil.writes, first))
    -- Changing the copy leaves the plan it came from alone.
    table.insert(rebound.sandbox.unveil.reads, "/changed")
    rebound.env.CHANGED = "yes"
    assert(not holds(made.sandbox.unveil.reads, "/changed") and made.env.CHANGED == nil)
  end
end

--- A tree tested by a tool of another tree (ci/, run by ../o/bin/cosmic) is
--- started by a name with ".." in it: [`Proc.executable`] keeps it as given,
--- and so does the artifact path of the relaunch. A grant may not name
--- "..", so the plan names the program, and the artifact a worker that
--- nests or declares `lua` with `store` reads, where it resolves, and tells
--- the worker that name.
local function test_a_program_started_by_a_name_with_dots_is_granted_where_it_is(tmp: string)
  local script = [[
local Sandbox = require("cosmic.sandbox")
local sys = require("cosmic.sys")
local test_policy = require("build.test_policy")
local test_sandbox = require("build.test_sandbox")
local root, scratch = sys.getenv("ROOT"), sys.getenv("SCRATCH")
local artifact = sys.getenv("ARTIFACT")
local function declared(more)
  local inputs = { files = {}, reads = {}, host = {}, env = {}, network = {},
    tool = false, store = false, system = true }
  for name, value in pairs(more) do inputs[name] = value end
  return inputs
end
local function holds(list, value)
  for _, each in ipairs(list) do if each == value then return true end end
  return false
end
for _, case in ipairs({
  { name = "tool", inputs = declared({ tool = true }) },
  { name = "nests store", inputs = declared({ nests = true, store = true }) },
  { name = "lua store", inputs = declared({ lua = true, store = true }) },
}) do
  local plan = test_sandbox.plan(root, scratch, case.inputs, {}, nil)
  local policy = test_policy.worker(plan, case.inputs)
  local ok, trouble = Sandbox.check(policy)
  assert(ok, case.name .. ": " .. tostring(trouble))
  if case.name ~= "tool" then
    local unveil = plan.sandbox.unveil
    assert(plan.program == artifact, case.name .. " is told " .. tostring(plan.program))
    assert(holds(unveil.reads, artifact), case.name)
  end
  print("ok")
end
]]
  local launched = Proc.relaunch()
  if launched == nil or launched.argv[2] ~= "--artifact" then
    Test.skip("this program is no portable artifact")
    return
  end
  assert(Fs.mkdirs(tmp .. "/beside/ci"))
  assert(Fs.symlink(launched.argv[3], tmp .. "/beside/cosmic"))
  local started = this_program.program({ "-e", script })
  local root, scratch = tmp .. "/beside/ci", scratch_in(tmp)
  local env = started.options.env or {}
  env.ROOT, env.SCRATCH, env.PATH = root, scratch, "/usr/bin:/bin"
  env.ARTIFACT = launched.argv[3]
  started.options.env, started.options.stdout, started.options.stderr = env, "capture", "capture"
  started.options.timeout_ns = Time.seconds(60)
  -- The launcher names the artifact by where it was started from: $PWD/$0.
  started.argv = { "../cosmic", "-e", script }
  started.options.cwd = tmp .. "/beside/ci"
  started.options.fds = nil
  local result, trouble = Child.run(started.argv, started.options)
  assert(result ~= nil, tostring(trouble))
  assert(result.code == 0, tostring(result.stderr) .. tostring(result.stdout))
  assert(tostring(result.stdout):find("^ok\nok\nok\n$"), tostring(result.stdout) .. tostring(result.stderr))
end

--- A worker whose module declares `nests` has no descriptor of the program
--- handed it and so would read the artifact by its path, which holds every
--- module of the tree: a plan for the policy grants the real one only where
--- the module declares `store` (keyed on the whole projection), `tool` has
--- o/bin anyway, and any other runs on a sealed database
--- ([`build.test`]'s `sealed_for`) and is given no artifact at all.
local function test_a_plan_for_a_nesting_worker_grants_the_artifact_only_with_store(tmp: string)
  local launched = Proc.relaunch()
  if launched == nil or launched.argv[2] ~= "--artifact" then
    Test.skip("this program is no portable artifact")
    return
  end
  local artifact = launched.argv[3]
  local root, scratch = tmp .. "/root", scratch_in(tmp)
  assert(Fs.mkdirs(build_dir(root) .. "/bin"))
  assert(Fs.write(build_dir(root) .. "/cosmic.db", "x"))
  local bare = effective({})
  bare.nests = true
  local storing = effective({})
  storing.nests, storing.store = true, true
  local plain = test_sandbox.plan(root, scratch, bare, {})
  local with = test_sandbox.plan(root, scratch, storing, {})
  assert(with.trouble == "", with.trouble)
  assert(holds(with.sandbox.unveil.reads, artifact), table.concat(with.sandbox.unveil.reads, " "))
  assert(not with.runs[artifact], "the artifact is read, not run")
  assert(not holds(plain.sandbox.unveil.reads, artifact),
    table.concat(plain.sandbox.unveil.reads, " "))
  assert(test_policy.worker(plain, bare) ~= nil)
  assert(test_policy.worker(with, storing) ~= nil)
end

--- A worker whose module declares nothing that puts a directory of the host
--- in its root -- no `system`, `tool`, host cache or `noexec`, no
--- directory among its `reads` or `host` -- has its scratch directory in the
--- sandbox's own /tmp, and so a root of files alone: its policy has `tmp`, "/tmp"
--- granted `rwxc` and no grant of a host directory, and its plan binds none.
--- Any of those declarations gives the plan the host's directory, and says which.
local function test_a_plan_gives_a_scratch_of_its_own_only_where_no_host_directory_is_declared(tmp: string)
  local root, scratch = tmp .. "/root", scratch_in(tmp)
  assert(Fs.mkdirs(build_dir(root) .. "/bin"))
  assert(Fs.mkdirs(root .. "/data"))
  assert(Fs.write(build_dir(root) .. "/cosmic.db", "x"))
  assert(Fs.write(root .. "/file.txt", "x"))
  local function planned(inputs: test_inputs.Effective): test_sandbox.Plan
    local made = test_sandbox.plan(root, scratch, inputs, {})
    assert(made.trouble == "", made.trouble)
    return made
  end
  local bare = effective({})
  local own = planned(bare)
  assert(own.own_scratch and own.why_shared == "", own.why_shared)
  assert(#own.sandbox.unveil.writes == 0 and own.sandbox.unveil.at[scratch] == nil)
  local policy = assert(test_policy.worker(own, bare))
  assert(policy.tmp == true)
  local tmp_grant: Sandbox.Grant = nil
  for _, grant in ipairs(policy.grants) do
    assert(grant.from == nil or grant.from ~= scratch, "a bind of the host's scratch directory")
    if grant.path == "/tmp" then tmp_grant = grant end
  end
  assert(tmp_grant ~= nil and tmp_grant.letters == "rwxc")
  -- A module that nests has no Landlock ruleset, and its root alone holds its
  -- sockets: a scratch directory of its own too.
  local nests = effective({})
  nests.nests = true
  assert(planned(nests).own_scratch)
  -- A file read is no directory.
  local file = effective({})
  file.reads = { "file.txt" }
  assert(planned(file).own_scratch)
  -- Each declaration that puts a directory in the root keeps the host's.
  local function shared(change: function(test_inputs.Effective), word: string)
    local inputs = effective({})
    change(inputs)
    local made = planned(inputs)
    assert(not made.own_scratch and made.why_shared:find(word, 1, true), word .. ": " .. made.why_shared)
    assert(made.sandbox.unveil.writes[1] == scratch)
    local held = assert(test_policy.worker(made, inputs))
    assert(held.tmp == nil, word)
  end
  shared(function(inputs: test_inputs.Effective) inputs.system = true end, "`system`")
  shared(function(inputs: test_inputs.Effective) inputs.tool = true end, "`tool`")
  shared(function(inputs: test_inputs.Effective) inputs.reads = { "data" } end, root .. "/data")
  shared(function(inputs: test_inputs.Effective) inputs.host = { "/dev" } end, "/dev")
end
