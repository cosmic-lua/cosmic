--- A worker reports before shutdown. A finalizer that exits nonzero must
--- fail the run and leave no passing verdict for its next run to stand on.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local function test_a_shutdown_failure_never_stands_as_a_passing_verdict(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/shutdown_test.tl", [[
local Proc = require("cosmic.proc")
local Fs = require("cosmic.fs")
local record shutdown
  guard: {string:boolean}
end
shutdown.guard = setmetatable({}, {
  __gc = function()
    assert(Fs.put(2, "shutdown diagnostic\n"))
    Proc.exit(7)
  end,
})
local function test_passes_before_shutdown()
  assert(shutdown.guard ~= nil)
end
]]))
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  env.COSMIC_SANDBOX, env.COSMIC_CI_REQUIRE_SANDBOX = nil, nil
  env.COSMIC_TEST_ALL, env.COSMIC_TEST_NO_SHARED = nil, nil
  env.COSMIC_VERDICT_CACHE = tmp .. "/verdicts.db"
  for _ = 1, 2 do
    local start = this_program.program({ "test" }, {
      cwd = root, env = env, stdout = "capture", stderr = "stdout", timeout_ns = Clock.seconds(60),
    })
    local result = assert(Child.run(start.argv, start.options))
    local output = result.stdout or ""
    assert(not result.timed_out, output)
    assert(result.code == 1, output)
    assert(output:find("FAIL  shutdown_test test_passes_before_shutdown", 1, true), output)
    assert(output:find("exited with status 7 after it reported", 1, true), output)
    assert(output:find("shutdown diagnostic", 1, true), output)
    assert(not output:find("test: PASS", 1, true), output)
  end
end
