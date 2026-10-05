--- `cosmic test`'s sandboxed worker (build/test_sandbox.tl) for a module
--- that declares `system`, and a process such a module's test confines
--- (build.confine's `confine`): the cases of
--- build/test_sandbox_test.tl and build/confine_test.tl
--- that look for the system's own paths, which only a worker given them
--- has to give, and so the ones that declare them themselves; and, end
--- to end, what a failure says of a host program a sandboxed test
--- started without them, which only a run whose own workers have them
--- tells from one the host lacks.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local confine = require("build.confine")
local stand_in = require("build.stand_in")
local this_program = require("build.this_program")
local test_inputs = require("build.test_inputs")
local test_policy = require("build.test_policy")
local test_sandbox = require("build.test_sandbox")
local Test = require("cosmic.test")

--- The system's own paths, which the plan and a confined process look
--- for where the host has them, beside what the plan gives every
--- worker; `nests`, since a process it confines has a root of its own,
--- as do the workers of a `cosmic test` it starts; `tool`: the plan
--- finds this program's core, a process confined is given the program,
--- and a case starts it; and the variables that hold a run to sandboxing, which a case
--- whose run sandboxed none of its workers reads to skip
--- (Test.skip).
Test.policy{
  profiles = { "system", "cosmic" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "/dev/urandom", letters = "r" }, { path = "/proc", letters = "r" } },
  promises = { "nest" },
  env = { "COSMIC_SANDBOX", "COSMIC_TEST_SANDBOX" },
}

--- Whether `list` holds `value`.
local function holds(list: {string}, value: string): boolean
  for _, each in ipairs(list) do
    if each == value then return true end
  end
  return false
end

--- A worker whose module declares `system` is given the system's own
--- paths by its policy's profile "system", which is no path of its plan.
local function test_a_module_that_declares_system_is_given_the_system_profile(tmp: string)
  local root, scratch = tmp .. "/root", tmp .. "/scratch"
  -- Laid out as build.test's `scratch` lays one out.
  for _, dir in ipairs({ root .. "/o", scratch .. "/real" }) do assert(Fs.mkdirs(dir)) end
  assert(Fs.symlink("real", scratch .. "/tmp"))
  assert(Fs.write(root .. "/o/cosmic.db", "x"))
  local inputs: test_inputs.Effective = { files = {}, reads = {}, host = {}, env = {},
    network = {}, tool = false, store = false, system = true }
  local plan = test_sandbox.plan(root, scratch, inputs, {})
  assert(plan.trouble == "", plan.trouble)
  assert(not holds(plan.sandbox.unveil.reads, "/usr"))
  local policy = assert(test_policy.worker(plan, inputs))
  assert(holds(policy.profiles or {}, "system"))
end

--- A process a test confines is given the system's own paths beside
--- what the test declared, where its worker has them -- here, since this
--- module declares `system`. Where the kernel cannot confine it, it runs
--- unconfined, and sees /usr all the same.
local function test_a_confined_process_is_given_the_system_s_paths(tmp: string)
  if Fs.exists("/usr") ~= true then return end -- no /usr to give
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local own = tmp .. "/own"
  assert(Fs.mkdirs(own))
  local code: integer = nil
  local ran = confine.call(function()
    confine.confine({ reads = { probe } })
    local r = assert(Child.run({ probe, "present /usr || exit 3" }, { env = {} }))
    confine.confine(nil)
    code = r.code
  end, nil, { own })
  assert(ran.ok, tostring(ran.produced))
  assert(code == 0, "the process did not see /usr: " .. tostring(code))
end

--- End to end: a sandboxed test that starts /bin/sh, or reads /etc,
--- without declaring `system` fails saying that is not in its sandbox and
--- what to declare -- where it checks the start's answer, and where a
--- bare `assert` on it says nothing itself, as for a script whose `#!`
--- names /bin/sh -- and one that declares it runs /bin/sh, its failure
--- its own, saying nothing of the sandbox. A relative path or a URL a
--- failure names is not taken for one the sandbox left out.
local function test_a_host_program_a_sandboxed_test_does_not_declare_is_named(tmp: string)
  -- No /bin/sh to start, or /etc/passwd to read.
  if Fs.exists("/bin/sh") ~= true or Fs.exists("/etc/passwd") ~= true then return end
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/run.sh", "#!/bin/sh\nexit 0\n"))
  assert(Fs.chmod(root .. "/suite/run.sh", 0x1ed))
  assert(Fs.write(root .. "/suite/undeclared_test.tl", [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.needs { reads = { "suite/run.sh" } }

local function test_bare()
  local r = Child.run({ "/bin/sh", "-c", "exit 0" })
  assert(r)
end

local function test_why()
  local r, why = Child.run({ "/bin/sh", "-c", "exit 0" })
  assert(r, why)
end

local function test_script()
  local r = Child.run({ "/tree/suite/run.sh" })
  assert(r)
end

local function test_read()
  assert(Fs.read("/etc/passwd"))
end

local function test_relative()
  assert(Fs.read("suite/data/missing"))
end

local function test_url()
  error("http://example.com/x: No such file or directory")
end
]]))
  assert(Fs.write(root .. "/suite/declared_test.tl", [[
local Child = require("cosmic.child")
local Test = require("cosmic.test")

Test.needs { system = true }

local function test_declared()
  local r = assert(Child.run({ "/bin/sh", "-c", "exit 3" }))
  assert(r.code == 0, "ran|" .. tostring(r.code) .. "|end")
end
]]))
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  env.COSMIC_TEST_SANDBOX = nil
  local output = tmp .. "/out"
  local fd = assert(Fs.open_write(output))
  local started = this_program.program({ "test", "--all" }, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true,
    timeout_ns = Clock.seconds(60),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil and not result.ok, tostring(trouble) .. text)
  if text:find("no worker can be sandboxed here", 1, true) then
    if confine.sandbox_platform() then Test.skip(confine.unsandboxed_reason(text)) end
    return
  end
  --- What the run said of `test`'s failure, up to where it says to rerun it.
  local function failure(test: string): string
    local said = text:match("FAIL  " .. test:gsub("%p", "%%%0") .. "(.-)rerun:")
    assert(said ~= nil, test .. ": " .. text)
    return said
  end
  local start_hint = "/bin/sh is not in this test's sandbox, which has nothing of /bin: " ..
    "a test that starts a host program declares Test.needs { system = true } " ..
    "(see cosmic docs cosmic.test)"
  local bare = failure("suite.undeclared_test test_bare")
  assert(bare:find("assertion failed!\n  " .. start_hint, 1, true), bare)
  local why = failure("suite.undeclared_test test_why")
  assert(why:find("child: start: No such file or directory: " .. start_hint, 1, true), why)
  local _, times = why:gsub(start_hint:gsub("%p", "%%%0"), "")
  assert(times == 1, why)
  local script = failure("suite.undeclared_test test_script")
  assert(script:find("/tree/suite/run.sh is a script /bin/sh runs, and " .. start_hint, 1,
    true), script)
  local read = failure("suite.undeclared_test test_read")
  assert(read:find("/etc/passwd is not in this test's sandbox, which has " ..
      "nothing of /etc: a test that reads the system's own files declares Test.needs " ..
      "{ system = true }", 1, true), read)
  -- Neither the tail of a relative path nor a URL's is a path the
  -- sandbox left out.
  for _, test in ipairs({ "test_relative", "test_url" }) do
    local said = failure("suite.undeclared_test " .. test)
    assert(not said:find("sandbox", 1, true), said)
  end
  local declared = failure("suite.declared_test test_declared")
  assert(declared:find("ran|3|end", 1, true), declared)
  assert(not declared:find("sandbox", 1, true), declared)
end
