--- `cosmic test` under a policy (build/test_policy.tl), end to end: a
--- `cosmic test` run on a suite of its own starts each worker under a
--- [`cosmic.sandbox`] policy, a test that reads what it declares passes and
--- one that reads what it does not fails, and the verdicts are kept apart
--- from those of a run with no sandbox (`COSMIC_TEST_SANDBOX=0`). These cases
--- declare `tool`, since they start this program, and `nests`, since the
--- workers of that run build roots of their own in this test's, whose
--- mounts the kernel refuses under the Landlock ruleset that holds every
--- other worker (build/test_worker.tl's `Hold`). Off Linux, which has no
--- sandbox to give, they are not applicable (`requires`); where this host
--- cannot nest the workers of that run, the case is skipped (Test.skip).
--- The plans a policy is made from, which no worker needs, are in
--- `test_policy_plan_tool_test.tl`.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Time = require("cosmic.time")
local Test = require("cosmic.test")
local confine = require("build.confine")
local this_program = require("build.this_program")

--- What a worker's plan gives it of the host, the program it runs, roots of
--- their own for the workers it starts (`nests`), and the variables the
--- runs read, which hold them to sandboxing and to a path.
Test.policy{
  profiles = { "cosmic", "system", "proc" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "/dev/urandom", letters = "r" } },
  promises = { "nest" },
  env = { "COSMIC_SANDBOX", "COSMIC_TEST_SANDBOX" },
  requires = { "nest" },
}

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
    Test.skip(confine.unsandboxed_reason(text))
    return true
  end
  local why = text:match("could not be supervised: (child: start: [^\n]*)")
  if why == nil then return false end
  for _, word in ipairs({ "Landlock", "seccomp", "namespace", "own /proc", "root could not be built",
      "not implemented" }) do
    if why:find(word, 1, true) then
      Test.skip("a policy's start in this test's own sandbox: " .. why)
      return true
    end
  end
  return false
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

--- A module that declares neither `tool` nor `nests` is kept from running the
--- program its worker was started from, though the policy granted it to
--- start the worker: it is refused.
local function test_a_module_without_tool_is_refused_the_program_under_a_policy(tmp: string)
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
