--- `cosmic test` under a policy (build/test_policy.tl), end to end: a
--- `cosmic test` run on a suite of its own starts each worker under a
--- [`cosmic.sandbox`] policy, a test that reads what it declares passes and
--- one that reads what it does not fails, and the verdicts are kept apart
--- from those of a run with no sandbox (`COSMIC_TEST_SANDBOX=0`). These cases
--- declare `tool`, since they start this program, and `nests`, since the
--- workers of that run build roots of their own in this test's, whose
--- mounts the kernel refuses under the Landlock ruleset that holds every
--- other worker (build/test_worker.tl's `Hold`). Where this host cannot
--- sandbox the workers of that run, the case is skipped
--- (Test.skip); off Linux, which has no sandbox to give, it returns
--- at once.

local type Sandbox = require("cosmic.sandbox")
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")
local Test = require("cosmic.test")
local confine = require("build.confine")
local test_inputs = require("build.test_inputs")
local test_policy = require("build.test_policy")
local test_sandbox = require("build.test_sandbox")
local this_program = require("build.this_program")

--- What a worker's plan gives it of the host, the program it runs, roots of
--- their own for the workers it starts (`nests`), and the variables the
--- runs read, which hold them to sandboxing and to a path.
Test.policy{
  profiles = { "cosmic", "system" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "/dev/urandom", letters = "r" }, { path = "/proc", letters = "r" } },
  promises = { "nest" },
  env = { "COSMIC_SANDBOX", "COSMIC_TEST_SANDBOX" },
}

--- Whether this platform has no sandbox to give, which leaves a case
--- nothing to check: off Linux a policy holds no worker, whatever the
--- run's words.
local function no_sandbox_here(): boolean
  return not confine.sandbox_platform()
end

--- Whether the run that printed `text` held none of its workers, or could
--- not start them under a policy for what this host refuses of one -- a
--- Landlock ruleset, a seccomp filter, a namespace, a /proc of its own, a
--- root it cannot build; if so, the running test is skipped
--- ([`Test.skip`]), since a case of a sandboxed run then has nothing to check.
--- The workers nest in this test's own sandbox, which a host may refuse:
--- the kernel lets root nest one only two deep (core/syscalls.c's
--- `map_ids`). CI's unprivileged runners nest them.
local function unsandboxed(text: string): boolean
  if text:find("no worker can be sandboxed here", 1, true) then
    if confine.sandbox_platform() then Test.skip(confine.unsandboxed_reason(text)) end
    return true
  end
  local why = text:match("could not be supervised: (child: start: [^\n]*)")
  if why == nil then return false end
  for _, word in ipairs({ "Landlock", "seccomp", "namespace", "own /proc", "root could not be built",
      "not implemented" }) do
    if why:find(word, 1, true) then
      if confine.sandbox_platform() then
        Test.skip("a policy's start in this test's own sandbox: " .. why)
      end
      return true
    end
  end
  return false
end

--- An `Effective` holding `files` of the tree and nothing else declared.
local function effective(files: {string}): test_inputs.Effective
  local out: test_inputs.Effective = { files = {}, reads = {}, host = {}, env = {}, network = {},
    tool = false, store = false }
  for _, file in ipairs(files) do out.files[file] = true end
  return out
end

--- Runs `cosmic test` with `words` on `root` with `env`, answering what it
--- printed and whether it passed.
local function run(root: string, output: string, env: {string:string},
                   words: {string}): string, boolean
  local fd = assert(Fs.open_write(output))
  local argv: {string} = { "test" }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local started = this_program.program(argv, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true,
    timeout_ns = Time.seconds(90),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil, tostring(trouble) .. text)
  return text, result.ok
end

--- The environment of a run on a tree of its own: this program's, with no
--- shared verdicts, and nothing of this run's choice of sandbox.
local function environment(): {string:string}
  local env = this_program.environment()
  -- The seccomp filters this worker has, which each worker of a run it
  -- starts inherits.
  local status = assert((Fs.read("/proc/self/status")))
  env.BASELINE_FILTERS = status:match("Seccomp_filters:\t(%d+)") or "0"
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  env.COSMIC_TEST_SANDBOX = nil
  return env
end

--- Whether `list` holds `value`.
local function holds(list: {string}, value: string): boolean
  for _, each in ipairs(list) do
    if each == value then return true end
  end
  return false
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

--- A plan leaves to the policy what a policy has of its own: no /proc of the
--- host's, which the sandbox replaces with its own, and no system paths,
--- which the profile "system" gives; the program and its core are the
--- reads that are run, and a worker that declares `tool` runs o/bin.
local function test_a_plan_for_the_policy_leaves_the_system_and_proc_to_the_policy(tmp: string)
  local root, scratch = tmp .. "/root", scratch_in(tmp)
  assert(Fs.mkdirs(root .. "/o/bin"))
  assert(Fs.write(root .. "/o/cosmic.db", "x"))
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
  assert(policy.runs[root .. "/o/bin"] == true)
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
  if launched == nil or launched.argv[2] ~= "--artifact" then return end
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
  if launched == nil or launched.argv[2] ~= "--artifact" then return end
  local artifact = launched.argv[3]
  local root, scratch = tmp .. "/root", scratch_in(tmp)
  assert(Fs.mkdirs(root .. "/o/bin"))
  assert(Fs.write(root .. "/o/cosmic.db", "x"))
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

--- A suite of two modules and a program-less tree: `held_test.tl`, whose
--- first test reads what it declares and is held as the policy path holds a
--- worker -- a filter on its system calls, a Landlock ruleset that refuses
--- even the listing of a directory above what it declares, no root -- and whose second reads a file it does not declare and so
--- fails; and `plain_test.tl`, which passes sandboxed or not.
local function suite_tree(root: string)
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/data.txt", "declared"))
  assert(Fs.write(root .. "/suite/secret.txt", "undeclared"))
  assert(Fs.write(root .. "/suite/held_test.tl", [[
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.policy {
  grants = { { path = "suite/data.txt", letters = "r" } },
  env = { "BASELINE_FILTERS" },
}

local function test_a_declared_read_is_held_as_a_policy_holds_it()
  assert(Fs.read("suite/data.txt") == "declared")
  local status = assert(Fs.read("/proc/self/status"))
  -- One filter beyond the ones inherited, which a container's runtime may
  -- have installed on every process.
  local filters = math.tointeger(status:match("Seccomp_filters:\t(%d+)"))
  local baseline = math.tointeger(sys.getenv("BASELINE_FILTERS"))
  assert(filters == baseline + 1, "no filter holds this worker: " .. tostring(filters) ..
    " filters, " .. tostring(baseline) .. " inherited")
  -- The directory is in the root of the sandbox, for what is granted in it
  -- is, and a ruleset that grants no read of it refuses its listing.
  local listed, _, errno = sys.readdir("suite")
  assert(listed == nil and errno == sys.EACCES, "no Landlock ruleset holds this worker")
  assert(sys.getuid() ~= 0, "this worker is root")
end

local function test_an_undeclared_read_fails()
  local data, why = Fs.read("suite/secret.txt")
  assert(data == "undeclared", tostring(why))
end
]]))
  assert(Fs.write(root .. "/suite/plain_test.tl", [[
local function test_passes_sandboxed_or_not()
  assert(1 + 1 == 2)
end
]]))
end

--- Whether the summary of a run started here says its workers were sandboxed
--- under a policy.
local function names_policy_path(text: string): boolean
  return text:find("; sandboxed, under a policy", 1, true) ~= nil
end

--- End to end, under the policy: a test that reads what it declares passes,
--- a filter and Landlock hold its worker, and one that reads a file it does
--- not declare fails -- the file is not there to read. Run unsandboxed
--- (`COSMIC_TEST_SANDBOX=0`), the same module is held by no filter and no
--- ruleset, and its rerun hints say so.
local function test_a_run_under_a_policy_passes_what_is_declared_and_fails_what_is_not(tmp: string)
  if no_sandbox_here() then return end
  local root = tmp .. "/root"
  suite_tree(root)
  local env = environment()
  local text, ok = run(root, tmp .. "/policy", env,
    { "--all", "suite/held_test.tl" })
  if unsandboxed(text) then return end
  assert(not ok, text)
  assert(names_policy_path(text), text)
  assert(text:find("1 of 2 failed", 1, true), text)
  assert(text:find("FAIL  suite.held_test test_an_undeclared_read_fails", 1, true), text)
  assert(text:find("suite/secret.txt: No such file or directory", 1, true) and
      text:find("rerun: cosmic test suite/held_test.tl:", 1, true), text)
  assert(not text:find("test_a_declared_read_is_held_as_a_policy_holds_it", 1, true), text)
  -- Unsandboxed, no filter and no ruleset hold it: the policy is what held
  -- it above.
  env.COSMIC_TEST_SANDBOX = "0"
  local plain, plain_ok = run(root, tmp .. "/plain", env, { "--all", "suite/held_test.tl" })
  assert(not plain_ok and plain:find("; unsandboxed (COSMIC_TEST_SANDBOX=0)", 1, true), plain)
  assert(plain:find("test_a_declared_read_is_held_as_a_policy_holds_it", 1, true) and
      plain:find("no filter holds this worker", 1, true), plain)
  assert(plain:find("rerun: COSMIC_TEST_SANDBOX=0 cosmic test suite/held_test.tl:", 1, true), plain)
end

--- A worker whose module declares nothing that puts a directory of the host
--- in its root -- no `system`, `tool`, host cache or `noexec`, no
--- directory among its `reads` or `host` -- has its scratch directory in the
--- sandbox's own /tmp, and so a root of files alone: its policy has `tmp`, "/tmp"
--- granted `rwxc` and no grant of a host directory, and its plan binds none.
--- Any of those declarations gives the plan the host's directory, and says which.
local function test_a_plan_gives_a_scratch_of_its_own_only_where_no_host_directory_is_declared(tmp: string)
  local root, scratch = tmp .. "/root", scratch_in(tmp)
  assert(Fs.mkdirs(root .. "/o/bin"))
  assert(Fs.mkdirs(root .. "/data"))
  assert(Fs.write(root .. "/o/cosmic.db", "x"))
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

--- A module that declares neither `tool` nor `nests` is kept from running the
--- program its worker was started from, though the policy granted it to
--- start the worker: it is refused.
local function test_a_module_without_tool_is_refused_the_program_under_a_policy(tmp: string)
  if no_sandbox_here() then return end
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/forbid_test.tl", [[
local Child = require("cosmic.child")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")

Test.policy {}

local function test_the_program_is_refused()
  local launched = assert(Proc.relaunch())
  local result, why = Child.run({ launched.argv[1], "-e", "return" })
  assert(result == nil and tostring(why):find("Permission denied", 1, true), tostring(why))
end
]]))
  local env = environment()
  local text, ok = run(root, tmp .. "/forbid", env, { "--all", "suite/forbid_test.tl" })
  if unsandboxed(text) then return end
  assert(ok, text)
end

--- End to end: a worker that declares nothing that puts a directory of the
--- host in its root has its directory at the padded name in a tmpfs of its own,
--- `tmp` a link to `real` there, TMPDIR naming it, and a root of files and that
--- tmpfs alone. The runner has no directory for it, so a failure says that, not
--- a path that does not exist. (Its unix socket is build/test_own_scratch_test.tl's:
--- a worker of this module declares `nests`, so it makes none, and neither does
--- any it starts.)
local function test_a_worker_with_no_host_directory_has_a_scratch_of_its_own(tmp: string)
  if no_sandbox_here() or test_policy.unmet() ~= "" then return end
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/own_test.tl", [[
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.policy {}

local function test_the_directory_is_its_own_at_the_padded_name(tmp: string)
  local scratch = assert(sys.getenv("TMPDIR"))
  assert(#scratch == 80 and scratch:find("/", 8, true) == nil and scratch:find("-", 1, true), scratch)
  assert(tmp == scratch .. "/tmp", tmp)
  local link = assert(sys.lstat(tmp))
  assert(link.kind == "link" and assert(sys.readlink(tmp)) == "real")
  assert(assert(sys.lstat(scratch .. "/real")).kind == "dir")
  -- Its root holds files and its own /tmp: no mount of a directory but them.
  local table_text = assert(Fs.read("/proc/self/mountinfo"))
  local seen_tmp = false
  for line in table_text:gmatch("[^\n]+") do
    local point = line:match("^%S+ %S+ %S+ %S+ (%S+)")
    if point == "/tmp" then
      seen_tmp = true
      assert(line:find(" - tmpfs ", 1, true), line)
    elseif point ~= "/" and point ~= "/proc" and not line:find(" - proc ", 1, true) then
      local there = assert(sys.stat(point))
      assert(there.kind ~= "dir", "a directory of the host: " .. point)
    end
  end
  assert(seen_tmp)
end

local function test_a_failure_says_where_its_directory_went()
  assert(false, "failed on purpose")
end
]]))
  local env = environment()
  local text, ok = run(root, tmp .. "/own", env, { "--all", "suite/own_test.tl" })
  if unsandboxed(text) then return end
  assert(not ok, text)
  assert(names_policy_path(text), text)
  assert(text:find("1 of 2 failed", 1, true), text)
  assert(text:find("failed on purpose", 1, true), text)
  assert(text:find("its directory was a tmpfs of its worker's own, gone with it", 1, true), text)
  assert(not text:find("its directory is kept:", 1, true), text)
  -- Run unsandboxed, the host keeps it.
  env.COSMIC_TEST_SANDBOX = "0"
  local old, old_ok = run(root, tmp .. "/old", env, { "--all", "suite/own_test.tl" })
  assert(not old_ok and old:find("its directory is kept: ", 1, true), old)
end

--- A module that declares `nests` starts and passes under the policy: its
--- worker is handed no read-only descriptor of the program, which a start
--- that promises `nest` refuses, and opens the program itself.
local function test_a_nesting_module_starts_under_a_policy(tmp: string)
  if no_sandbox_here() then return end
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/nest_test.tl", [[
local Test = require("cosmic.test")

Test.policy { grants = { { path = "o/cosmic.db", letters = "r" } }, promises = { "nest" } }

local function test_a_worker_that_nests_runs()
  assert(1 + 1 == 2)
end
]]))
  local env = environment()
  local text, ok = run(root, tmp .. "/nest", env, { "--all", "suite/nest_test.tl" })
  if unsandboxed(text) then return end
  assert(ok, text)
  assert(not text:find("SKIP", 1, true), text)
  assert(not text:find("retains of its own", 1, true), text)
end

--- A pass under the policy does not stand for a run with no sandbox, nor
--- its pass for a run under the policy: each keeps its own verdicts, in
--- one tree's working database, while each stands for a rerun of itself.
local function test_the_verdicts_of_a_sandboxed_and_an_unsandboxed_run_stand_apart(tmp: string)
  if no_sandbox_here() then return end
  local root = tmp .. "/root"
  suite_tree(root)
  local env = environment()
  local step = 0
  local function said(sandboxed: boolean, wanted: string): string
    step = step + 1
    env.COSMIC_TEST_SANDBOX = not sandboxed and "0" or nil
    local text, ok = run(root, tmp .. "/run" .. step, env, { "suite/plain_test.tl" })
    assert(ok and text:find(wanted, 1, true), step .. ": " .. text)
    return text
  end
  local first = said(true, "1 ran, 0 stood")
  if unsandboxed(first) then return end
  said(true, "0 ran, 1 stood")
  said(false, "1 ran, 0 stood")
  said(false, "0 ran, 1 stood")
  said(true, "0 ran, 1 stood")
end

--- A worker whose module does not declare `tool` may not run this program
--- again, though the core is granted `x` for the worker to start from: its test's start of the core is refused;
--- a module that declares `tool` starts it.
local function test_a_worker_that_is_not_a_tool_cannot_run_the_core_again(tmp: string)
  if no_sandbox_here() then return end
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/suite"))
  local body = [[
local Child = require("cosmic.child")
local Proc = require("cosmic.proc")
%s

local function test_runs_the_core()
  local launched, _ = Proc.relaunch()
  if launched == nil then return end
  local result, why = Child.run({ launched.argv[1], "-e", "" }, { process_group = false,
    stdout = "capture", stderr = "stdout" })
  assert(result ~= nil, tostring(why))
end
]]
  assert(Fs.write(root .. "/suite/plain_exec_test.tl", string.format(body, "")))
  assert(Fs.write(root .. "/suite/tool_exec_test.tl", string.format(body,
    'local Test = require("cosmic.test")\n\nTest.policy { profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }\n')))
  local env = environment()
  local text, ok = run(root, tmp .. "/exec", env, { "--all" })
  if unsandboxed(text) then return end
  assert(not ok and text:find("1 of 2 failed", 1, true), text)
  assert(text:find("FAIL  suite.plain_exec_test test_runs_the_core", 1, true), text)
  assert(text:find("Permission denied", 1, true), text)
  assert(not text:find("FAIL  suite.tool_exec_test", 1, true), text)
end

--- A probe that fails for no limit of the host fails the run, naming it,
--- rather than letting its workers run unsandboxed and pass having
--- confined nothing: here the directory the probe tries the sandbox in
--- cannot be made, since TMPDIR names none.
local function test_a_broken_probe_fails_the_run_rather_than_going_unsandboxed(tmp: string)
  if no_sandbox_here() then return end
  local root = tmp .. "/root"
  suite_tree(root)
  local env = environment()
  env.TMPDIR = tmp .. "/no/such/directory"
  local text, ok = run(root, tmp .. "/broken", env, { "--all", "suite/plain_test.tl" })
  assert(not ok, text)
  assert(text:find("the probe of whether workers can be sandboxed failed: " ..
      "a directory to try it in", 1, true), text)
  assert(not text:find("unsandboxed", 1, true), text)
end
