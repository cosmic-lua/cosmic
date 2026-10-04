--- `cosmic test` under a policy (build/test_policy.tl), end to end: a
--- `cosmic test` run on a suite of its own with `COSMIC_TEST_POLICY=1`
--- starts each worker under a [`cosmic.sandbox`] policy, a test that reads
--- what it declares passes and one that reads what it does not fails, and
--- the verdicts are kept apart from the default sandbox's. These cases
--- declare `tool`, since they start this program, and `nests`, since the
--- workers of that run build roots of their own in this test's, whose
--- mounts the kernel refuses under the Landlock ruleset that holds every
--- other worker (build/test_worker.tl's `Hold`). Where this host cannot
--- sandbox the workers of that run, the case is skipped
--- ([`sandbox_skip`]); off Linux, which has no sandbox to give, it returns
--- at once.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local confine = require("build.confine")
local sandbox_skip = require("build.sandbox_skip")
local test_inputs = require("build.test_inputs")
local test_sandbox = require("build.test_sandbox")
local this_program = require("build.this_program")

--- What a worker's plan gives it of the host, the program it runs, roots of
--- their own for the workers it starts (`nests`), and the variables the
--- runs read, which hold them to sandboxing and to a path.
Test.needs{
  host = { "/dev/urandom", "/proc" },
  env = { "COSMIC_SANDBOX", "COSMIC_CI_REQUIRE_SANDBOX", "COSMIC_TEST_SANDBOX" },
  tool = true,
  nests = true,
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
--- ([`Test.skip`]), since a case of a held run then has nothing to check.
--- The workers nest in this test's own sandbox, which a host may refuse:
--- the kernel lets root nest one only two deep (core/syscalls.c's
--- `map_ids`). A run held to sandboxing fails the skip; CI's unprivileged
--- runners nest them.
local function unsandboxed(text: string): boolean
  if text:find("no worker can be sandboxed here", 1, true) then
    sandbox_skip.nested(text)
    return true
  end
  local why = text:match("could not be supervised: (child: start: [^\n]*)")
  if why == nil then return false end
  for _, word in ipairs({ "Landlock", "seccomp", "namespace", "own /proc", "root could not be built",
      "not implemented" }) do
    if why:find(word, 1, true) then
      sandbox_skip.refused("a policy's start in this test's own sandbox: " .. why)
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
--- shared verdicts, and nothing of this run's choice of sandbox or policy.
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
  env.COSMIC_TEST_POLICY = nil
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

--- A plan made for the policy gives the paths of the one made for the
--- default sandbox but for what a policy has of its own: no /proc of the
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
  local plain = test_sandbox.plan(root, scratch, inputs, {})
  local policy = test_sandbox.plan(root, scratch, inputs, {}, nil, true)
  assert(policy.trouble == "", policy.trouble)
  local reads = policy.sandbox.unveil.reads
  assert(not holds(reads, "/proc") and not holds(reads, "/usr") and not holds(reads, "/etc"),
    table.concat(reads, " "))
  assert(holds(reads, "/dev/urandom") and holds(reads, "/dev/null"))
  assert(holds(plain.sandbox.unveil.reads, "/usr") or sys.stat("/usr") == nil)
  assert(holds(plain.sandbox.unveil.reads, "/proc") or sys.stat("/proc") == nil)
  assert(policy.sandbox.user == nil and policy.start == nil, "a policy chooses the user")
  assert(policy.runs[root .. "/o/bin"] == true)
end

--- A suite of two modules and a program-less tree: `held_test.tl`, whose
--- first test reads what it declares and is held as a policy holds it --
--- a filter on its system calls, no root, a /proc of its own -- and whose
--- second reads a file it does not declare and so fails; and
--- `plain_test.tl`, which passes under either sandbox.
local function suite_tree(root: string)
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/data.txt", "declared"))
  assert(Fs.write(root .. "/suite/secret.txt", "undeclared"))
  assert(Fs.write(root .. "/suite/held_test.tl", [[
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.needs { reads = { "suite/data.txt" }, env = { "BASELINE_FILTERS" } }

local function test_a_declared_read_is_held_as_a_policy_holds_it()
  assert(Fs.read("suite/data.txt") == "declared")
  local status = assert(Fs.read("/proc/self/status"))
  -- One filter beyond the ones inherited, which a container's runtime may
  -- have installed on every process.
  local filters = math.tointeger(status:match("Seccomp_filters:\t(%d+)"))
  local baseline = math.tointeger(sys.getenv("BASELINE_FILTERS"))
  assert(filters == baseline + 1, "no filter holds this worker: " .. tostring(filters) ..
    " filters, " .. tostring(baseline) .. " inherited")
  assert(sys.getuid() ~= 0, "this worker is root")
end

local function test_an_undeclared_read_fails()
  local data, why = Fs.read("suite/secret.txt")
  assert(data == "undeclared", tostring(why))
end
]]))
  assert(Fs.write(root .. "/suite/plain_test.tl", [[
local function test_passes_under_either()
  assert(1 + 1 == 2)
end
]]))
end

--- End to end, under the policy: a test that reads what it declares passes,
--- a filter holds its worker, and one that reads a file it does not
--- declare fails -- the file is not there to read -- as the default
--- sandbox fails it; the run says it is under a policy. `--policy` is the
--- variable's word on the command line.
local function test_a_run_under_a_policy_passes_what_is_declared_and_fails_what_is_not(tmp: string)
  if no_sandbox_here() then return end
  local root = tmp .. "/root"
  suite_tree(root)
  local env = environment()
  env.COSMIC_TEST_POLICY = "1"
  local text, ok = run(root, tmp .. "/policy", env,
    { "--all", "suite/held_test.tl" })
  if unsandboxed(text) then return end
  assert(not ok, text)
  assert(text:find("under a policy (COSMIC_TEST_POLICY=1)", 1, true), text)
  assert(text:find("1 of 2 failed", 1, true), text)
  assert(text:find("FAIL  suite.held_test test_an_undeclared_read_fails", 1, true), text)
  assert(text:find("suite/secret.txt: No such file or directory", 1, true) and
      text:find("rerun: COSMIC_TEST_POLICY=1 cosmic test suite/held_test.tl:", 1, true), text)
  assert(not text:find("test_a_declared_read_is_held_as_a_policy_holds_it", 1, true), text)
  -- The same, asked for by the option.
  env.COSMIC_TEST_POLICY = nil
  local option, option_ok = run(root, tmp .. "/option", env,
    { "--all", "--policy", "suite/held_test.tl" })
  assert(not option_ok and option:find("1 of 2 failed", 1, true) and
      option:find("under a policy (COSMIC_TEST_POLICY=1)", 1, true), option)
  -- Not asked for, the same test is held by the default sandbox, which
  -- has no filter: the policy is what held it above.
  local plain, plain_ok = run(root, tmp .. "/plain", env, { "--all", "suite/held_test.tl" })
  assert(not plain_ok and not plain:find("under a policy", 1, true), plain)
  assert(plain:find("test_a_declared_read_is_held_as_a_policy_holds_it", 1, true) and
      plain:find("no filter holds this worker", 1, true), plain)
end

--- A pass under the policy does not stand for a run without it, nor the
--- default sandbox's for a run under it: each keeps its own verdicts, in
--- one tree's working database, while each stands for a rerun of itself.
local function test_the_verdicts_of_the_two_paths_stand_apart(tmp: string)
  if no_sandbox_here() then return end
  local root = tmp .. "/root"
  suite_tree(root)
  local env = environment()
  local step = 0
  local function said(policy: boolean, wanted: string): string
    step = step + 1
    env.COSMIC_TEST_POLICY = policy and "1" or nil
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

--- What a policy has no word for fails its tests, naming the field,
--- rather than run them held less than the module declares; a run asked
--- to start workers under a policy where none can be sandboxed fails
--- rather than start them unsandboxed; and a misspelt switch is refused.
local function test_what_the_policy_cannot_say_fails_loudly(tmp: string)
  if no_sandbox_here() then return end
  local root = tmp .. "/root"
  suite_tree(root)
  assert(Fs.write(root .. "/suite/wildcard_test.tl", [[
local Test = require("cosmic.test")

Test.needs { env = { "*" } }

local function test_reads_the_whole_environment()
  assert(true)
end
]]))
  local env = environment()
  env.COSMIC_TEST_POLICY = "1"
  local text, ok = run(root, tmp .. "/wildcard", env, { "--all", "suite/wildcard_test.tl" })
  if unsandboxed(text) then return end
  assert(not ok and text:find('env "*"', 1, true) and text:find("wildcard", 1, true), text)
  assert(not text:find("the test process", 1, true), text)
  env.COSMIC_TEST_SANDBOX = "0"
  local off, off_ok = run(root, tmp .. "/off", env, { "suite/plain_test.tl" })
  assert(not off_ok and off:find("COSMIC_TEST_POLICY=1 (--policy), but no worker can be " ..
      "sandboxed here", 1, true), off)
  env.COSMIC_TEST_SANDBOX = nil
  env.COSMIC_TEST_POLICY = "yes"
  local misspelt, misspelt_ok = run(root, tmp .. "/misspelt", env, { "suite/plain_test.tl" })
  assert(not misspelt_ok and misspelt:find('COSMIC_TEST_POLICY is "yes"', 1, true), misspelt)
end

--- A worker whose module does not declare `tool` may not run this program
--- again, as under the default sandbox, though the core is granted `x` for
--- the worker to start from: its test's start of the core is refused;
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
    'local Test = require("cosmic.test")\n\nTest.needs { tool = true }\n')))
  local env = environment()
  env.COSMIC_TEST_POLICY = "1"
  local text, ok = run(root, tmp .. "/exec", env, { "--all" })
  if unsandboxed(text) then return end
  assert(not ok and text:find("1 of 2 failed", 1, true), text)
  assert(text:find("FAIL  suite.plain_exec_test test_runs_the_core", 1, true), text)
  assert(text:find("Permission denied", 1, true), text)
  assert(not text:find("FAIL  suite.tool_exec_test", 1, true), text)
end
