--- `cosmic test`'s sandboxed worker (build/test_sandbox.tl), end to end:
--- what a test run with the switch on sees. These start this program, a
--- `cosmic test` run on a suite of their own, so they declare `tool`.
--- They declare `nests` because the workers of that run nest a sandbox in
--- this test's own, each in a root of its own, whose mounts the kernel
--- refuses under the Landlock ruleset that holds every other worker
--- (build/test_worker.tl's `Hold`). Off Linux, which has no sandbox to give,
--- they are not applicable (`requires`); where this host cannot nest the
--- run's workers, the case is skipped (Test.skip). The plan of a worker is
--- in `test_sandbox_tool_test.tl`.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local test_sandbox = require("build.test_sandbox")
local confine = require("build.confine")
local fixture = require("build.test_sandbox_fixture")
local Test = require("cosmic.test")

--- What a worker's plan gives it of the host, the program it runs,
--- roots of their own for the sandboxed workers it starts (`nests`), and
--- the variables the runs set, which choose how their workers are held.
Test.policy{
  profiles = { "cosmic", "proc" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "/dev/urandom", letters = "r" } },
  promises = { "nest" },
  env = { "COSMIC_SANDBOX", "COSMIC_TEST_SANDBOX" },
  requires = { "nest" },
}

--- Runs `cosmic test --all` on `root` with `env`, answering what it
--- printed and whether it passed.
local function run(root: string, output: string, env: {string:string}): string, boolean
  local ran = fixture.run(root, output, env)
  return ran.text, ran.ok
end

local suite_tree = fixture.suite_tree
--- Whether the run that printed `text` sandboxed none of its workers.
local function none_sandboxed(text: string): boolean
  return text:find("no worker can be sandboxed here", 1, true) ~= nil
end

--- Ends the running test as skipped ([`Test.skip`]) where this platform
--- could have sandboxed the workers of the run that printed `text`, which
--- sandboxed none: a case of a sandboxed run then has nothing to check.
--- The workers nest in this test's own sandbox, which a host may refuse:
--- the kernel lets root nest one only two deep (core/syscalls.c's
--- `map_ids`). CI's unprivileged runners nest them.
local function skip_unsandboxed(text: string)
  Test.skip(confine.unsandboxed_reason(text))
end

--- Whether the run that printed `text` sandboxed none of its workers, the
--- running test being skipped first where this platform could have.
local function unsandboxed(text: string): boolean
  if not none_sandboxed(text) then return false end
  skip_unsandboxed(text)
  return true
end

--- Runs `cosmic test` on `root`, with no `--all`, answering what it
--- printed and whether it passed.
local function run_again(root: string, output: string, env: {string:string}): string, boolean
  local fd = assert(Fs.open_write(output))
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true, timeout_ns = Clock.seconds(60),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil, tostring(trouble) .. text)
  return text, result.ok
end

--- End to end: by default, a test's worker runs in /tree, has its own
--- directory under /tmp, reads what its module declares of the tree
--- and nothing else of it, sees nothing of the host it was not given,
--- and reads only the variables it declares -- and so does a process it
--- starts; and the run says it was sandboxed. The same suite with the
--- switch off reads all of the tree and the host, but still only the
--- variables it declares. Required where it can be, the same; a switch that
--- is neither "1", "0" nor unset is refused. The run with the switch off,
--- and a host that gives no sandbox, are `test_sandbox_tool_test.tl`'s.
local function test_a_sandboxed_run_holds_each_worker_to_its_inputs(tmp: string)
  local root, hidden = tmp .. "/root", tmp .. "/hidden"
  suite_tree(tmp, root)
  fixture.view_suite(tmp, root, hidden)
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  env.DECLARED_VAR = "d"
  env.UNDECLARED_VAR = "u"
  local text, ok: string, boolean
  env.COSMIC_TEST_SANDBOX = nil
  text, ok = run(root, tmp .. "/sandboxed", env)
  assert(not ok, text)
  if unsandboxed(text) then return end
  assert(text:find("; sandboxed", 1, true), text)
  local seen = text:match("seen|([^\n]*)|end")
  assert(seen ~= nil, text)
  local fields: {string} = {}
  for field in (seen .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = field end
  assert(fields[1] == "/tree" and fields[2] == test_sandbox.scratch .. "/tmp" and fields[3] == "declared" and
      fields[4] == "nil" and fields[5] == "false" and fields[6] == "d" and fields[7] == "nil" and
      fields[8] == "declared/d/", seen)
  -- Its failure is its own, and says how to run it again as it ran.
  assert(not text:find("does not declare", 1, true), text)
  assert(text:find("rerun: cosmic test suite/view_test.tl:test_view", 1, true), text)
  -- Required where it can be, the same.
  env.COSMIC_TEST_SANDBOX = "1"
  text, ok = run(root, tmp .. "/required", env)
  assert(not ok and text:find("; sandboxed", 1, true), text)
  assert(text:find("rerun: COSMIC_TEST_SANDBOX=1 cosmic test suite/view_test.tl:test_view", 1,
    true), text)
  -- A misspelt switch is refused.
  env.COSMIC_TEST_SANDBOX = "yes"
  text, ok = run(root, tmp .. "/misspelt", env)
  assert(not ok and text:find('COSMIC_TEST_SANDBOX is "yes"', 1, true), text)
end

--- End to end: a sandboxed worker writes a host cache its module
--- declares, where the host has it, and cannot write one it does not
--- declare -- which the runner neither gives nor makes. Where no worker
--- can be sandboxed here, the run says so.
local function test_a_sandboxed_worker_writes_only_the_caches_it_declares(tmp: string)
  local root, xdg = tmp .. "/root", assert(Fs.absolute(tmp)) .. "/xdg"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/cache_test.tl", [[
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.policy { grants = { { path = "/cache/zig", letters = "rwxc" } } }

local function test_write()
  local base = assert(sys.getenv("XDG_CACHE_HOME"))
  local declared, _ = Fs.write(base .. "/cosmic/zig-global/entry", "cached")
  local undeclared, _ = Fs.write(base .. "/cosmic/bootstrap/entry", "cached")
  error("wrote|" .. tostring(declared) .. "|" .. tostring(undeclared) .. "|end")
end
]]))
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  -- The program's cores stay where they are; only the caches move.
  env.COSMIC_PORTABLE_CACHE = env.COSMIC_PORTABLE_CACHE or Fs.cache_dir("cores", { make = false })
  env.XDG_CACHE_HOME = xdg
  env.COSMIC_ZIG_CACHE, env.COSMIC_ZIG_GLOBAL_CACHE = nil, nil
  env.COSMIC_TEST_SANDBOX = nil
  local text, ok = run(root, tmp .. "/out", env)
  assert(not ok, text)
  if unsandboxed(text) then return end
  assert(text:find("wrote|true|false|end", 1, true), text)
  assert(Fs.read(xdg .. "/cosmic/zig-global/entry") == "cached")
  assert(not Fs.exists(xdg .. "/cosmic/bootstrap"))
end

--- End to end: a module that grants a `host` path has its worker given
--- that path there, and nothing beside it.
local function test_a_host_path_is_given_where_it_is_declared(tmp: string)
  local base = assert(Fs.absolute(tmp))
  local root, product = base .. "/root", base .. "/product"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(product))
  assert(Fs.write(product .. "/given.txt", "given"))
  assert(Fs.write(product .. "/sibling.txt", "sibling"))
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  env.COSMIC_TEST_SANDBOX = nil
  fixture.host_test(root, product, product .. "/given.txt")
  env.COSMIC_TEST_SANDBOX = nil
  local text, ok = run(root, tmp .. "/given", env)
  assert(not ok, text)
  if unsandboxed(text) then return end
  assert(text:find("; sandboxed", 1, true), text)
  assert(text:find("read|given|nil|end", 1, true), text)
end

--- The suite the tests below run `cosmic test` on, two modules whose
--- tests start the stand-in, and the first of those runs, which runs both.
--- Answers its root and `said`, which runs again and checks the summary says
--- `wanted` and passes unless `passes` is false. Where the first run was not
--- sandboxed the running test is skipped. Each test makes its own, since a
--- run takes a second and a half and a test is held to its timeout.
local function keyed_suite(tmp: string): string, (function(string, ?boolean): string)
  local root = tmp .. "/root"
  suite_tree(tmp, root)
  assert(Fs.write(root .. "/suite/data.txt", "one"))
  assert(Fs.write(root .. "/suite/unrelated.txt", "one"))
  assert(Fs.write(root .. "/suite/child_test.tl", [[
local Child = require("cosmic.child")
local Test = require("cosmic.test")

Test.policy {
  grants = {
    { path = "suite/data.txt", letters = "r" },
    { path = "suite/later.txt", letters = "r" },
    { path = "bin/probe", letters = "r" },
    { path = "o/cosmic.db", letters = "r" },
  },
}

local function test_child_reads()
  local r = assert(Child.run({ "bin/probe",
    "cat suite/data.txt; cat suite/later.txt || print |absent" },
    { stdout = "capture" }))
  local out = r.stdout or ""
  assert(r.ok and out:find("|absent", 1, true), out)
end
]]))
  assert(Fs.write(root .. "/suite/unstored_test.tl", [[
local Child = require("cosmic.child")
local Test = require("cosmic.test")

Test.policy { grants = { { path = "bin/probe", letters = "r" } } }

local function test_child_reads_the_closure_store()
  assert(assert(Child.run({ "bin/probe", "exit 0" })).ok)
end
]]))
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  -- Sandboxed where it can be, whatever this run's own switch says.
  env.COSMIC_TEST_SANDBOX = nil
  local step = 0
  local function said(wanted: string, passes?: boolean): string
    step = step + 1
    local text, ok = run_again(root, tmp .. "/run" .. step, env)
    assert(ok == (passes ~= false), step .. ": " .. text)
    assert(text:find(wanted, 1, true), step .. ": " .. text)
    return text
  end
  local first = said("2 ran, 0 stood")
  if unsandboxed(first) then return root, said end
  assert(first:find("; sandboxed", 1, true), first)
  return root, said
end

--- End to end: a process a sandboxed test starts is keyed by what its
--- module declares. A change to a file of the tree it does not declare
--- leaves it standing, and none is assumed, nor runs every time. One that
--- does not declare `store` stands too: what it starts can read only the
--- store of its closure, which its key holds.
local function test_a_process_a_sandboxed_test_starts_stands_on_an_undeclared_change(tmp: string)
  local root, said = keyed_suite(tmp)
  -- A file no test declares moved, so this run is also the second of the
  -- same declarations.
  assert(Fs.write(root .. "/suite/unrelated.txt", "two"))
  local again = said("0 ran, 2 stood")
  assert(not again:find("assumed", 1, true) and not again:find("every time", 1, true), again)
end

--- End to end: a change to a file a sandboxed test's module declares runs
--- it again, and the run after that stands.
local function test_a_process_a_sandboxed_test_starts_runs_again_on_a_declared_change(tmp: string)
  local root, said = keyed_suite(tmp)
  assert(Fs.write(root .. "/suite/data.txt", "two"))
  said("1 ran, 1 stood")
  said("0 ran, 2 stood")
end

--- End to end: making a file a sandboxed test's module declares that was
--- not there when it last ran runs it again; what the child reads is
--- there now, and the test fails.
local function test_a_process_a_sandboxed_test_starts_runs_again_on_a_file_made_since(tmp: string)
  local root, said = keyed_suite(tmp)
  assert(Fs.write(root .. "/suite/later.txt", "made"))
  said("FAIL  suite.child_test test_child_reads: ", false)
end

--- A sandboxed run interrupted from the terminal -- SIGINT to its
--- process group -- ends every worker it had running, each in a
--- sandbox of its own, and removes their directories.
local function test_an_interrupted_sandboxed_run_ends_its_workers(tmp: string)
  local root, temp = tmp .. "/root", assert(Fs.absolute(tmp)) .. "/temp"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(temp))
  -- A directory its tests read, which keeps their workers' directories on
  -- the host, where this test finds them: with none in its root a worker
  -- has its directory in a tmpfs of its own (build/test_sandbox.tl's
  -- `own_scratch`).
  assert(Fs.mkdirs(root .. "/keep"))
  assert(Fs.write(root .. "/suite/held_test.tl", [[
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
Test.policy { grants = { { path = "keep", letters = "r" } } }
local function hold(tmp: string)
  assert(Fs.write(tmp .. "/kept", "x"))
  while true do end
end
local function test_first(tmp: string) hold(tmp) end
local function test_second(tmp: string) hold(tmp) end
]]))
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  -- Sandboxed where it can be, whatever this run's own switch says.
  env.COSMIC_TEST_SANDBOX = nil
  env.TMPDIR = temp
  -- Each worker's directory holding the file its test wrote.
  local function held(): integer
    local count = 0
    for _, name in ipairs(Fs.list(temp) or {}) do
      if name:sub(1, 12) == "cosmic-test-" and Fs.exists(temp .. "/" .. name .. "/real/kept") then
        count = count + 1
      end
    end
    return count
  end
  local output = tmp .. "/interrupted.out"
  local fd = assert(Fs.open_write(output))
  local interrupted = this_program.program(
    { "test", "--jobs", "2", "--timeout", "60", "suite/held_test.tl" },
    { cwd = root, env = env, stdout = fd, stderr = fd, process_group = true })
  local runner, trouble = Child.start(interrupted.argv, interrupted.options)
  assert(Fs.close(fd))
  local handle <close> = assert(runner, trouble)
  local deadline = Clock.monotonic_ns() + Clock.seconds(30)
  while held() < 2 do
    assert(Clock.monotonic_ns() < deadline, assert(Fs.read(output)))
    local done, _ = Child.wait_any({ handle }, Clock.ms(50))
    assert(done == nil, "the runner ended before its tests started\n" .. assert(Fs.read(output)))
  end
  local text = assert(Fs.read(output))
  if none_sandboxed(text) then
    -- Unsandboxed here: build/test_isolation_tool_test.tl's case.
    assert(handle:stop(sys.SIGKILL))
    local _, _ = handle:wait(Clock.seconds(30))
    skip_unsandboxed(text)
    return
  end
  assert(text:find("test: sandbox: each worker is held", 1, true), text)
  assert(handle:stop(sys.SIGINT))
  local result = assert(handle:wait(Clock.seconds(30)))
  text = assert(Fs.read(output))
  assert(not result.timed_out and result.signal == sys.SIGINT, text)
  assert(text:find("test: cancelled; every running test was ended", 1, true), text)
  local left: {string} = {}
  for _, name in ipairs((assert(Fs.list(temp)))) do
    if name:sub(1, 12) == "cosmic-test-" then left[#left + 1] = name end
  end
  assert(#left == 0, table.concat(left, ", ") .. "\n" .. text)
end
