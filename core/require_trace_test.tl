--- core/store.c's trace of the modules a process loads: with COSMIC_TRACE_REQUIRE set, each module the searcher finds
--- in a database is said on stderr once it has loaded, indented by how deep it was required, with its times.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")

--- The program itself, which each test starts again with the variable set or not.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- What this program says on stderr running a chunk that loads cosmic.mcp, with COSMIC_TRACE_REQUIRE as `trace` (unset
--- where nil).
local function stderr_of(trace: string?): string
  local env = Test.environment()
  if trace ~= nil then env["COSMIC_TRACE_REQUIRE"] = trace end
  local started = Test.cosmic({ "-e", "local _ = require(\"cosmic.mcp\")" },
    { env = env, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.ok, "the chunk exited " .. tostring(result.code) .. ": " .. tostring(result.stderr))
  return result.stderr or ""
end

--- A traced process names each module it loads, with its times, indented by how deep it was required: cosmic.mcp, which
--- the chunk loads, is said at the top level, and a module some module required is said one level in. (A dev tool
--- first checks whether it is older than its checkout, loading what reads it, so which module first loaded one of mcp's
--- own requires is not asserted.)
local function test_a_traced_process_names_each_module_it_loads()
  local said = stderr_of("1")
  local times = "[%d.]+ ms %([%d.]+ ms its own, [%d.]+ ms reading it%)"
  assert(said:find("\nrequire: cosmic%.mcp " .. times .. "\n") ~= nil, said)
  assert(said:find("\nrequire:   [%w_.]+ " .. times .. "\n") ~= nil, said)
end

--- Unset, empty or "0", the trace says nothing.
local function test_an_untraced_process_says_nothing_of_its_modules()
  for _, trace in ipairs({ "0", "", "unset" }) do
    local said = stderr_of(if trace == "unset" then nil else trace end)
    assert(said:find("require: ", 1, true) == nil, said)
  end
end
