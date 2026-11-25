--- The modules a snippet may require, as the built binary lists them from its own docs, and its agent's prompt shows
--- them: what a test's store, holding its import closure alone, cannot show.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local SCRIPT <const> = [[
local Host = require("cosmic.agent.host")
local Prompt = require("cosmic.agent.prompt")
local Tools = require("cosmic.agent.tools")
local modules = Host.modules()
local built = Prompt.build("/w", {}, { tools = { Tools.find(Tools.all(), "run")! } })
print(modules)
print("--")
print(built:find("<cosmic_modules>\n", 1, true) ~= nil and built:find(modules, 1, true) ~= nil)
]]

local function test_the_binary_lists_its_own_modules_and_its_prompt_shows_them(tmp: string)
  local started = this_program.program({ "-e", SCRIPT }, { cwd = tmp, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(20) })
  local result = assert(Child.run(started.argv, started.options))
  local out = result.stdout or ""
  assert(result.code == 0, result.stderr)
  local modules, shown = out:match("^(.-)\n%-%-\n(%a+)\n$")
  assert(modules ~= nil and shown == "true", out)
  local seen: mut {string: boolean} = {}
  local count = 0
  for name in modules:gmatch("cosmic%.([%w_]+)") do
    seen[name] = true
    count = count + 1
  end
  -- The binary's own: every module a snippet may require, but the agent's own and tooling's.
  assert(count > 40 and seen["csv"] == true and seen["fs"] == true and seen["json"] == true, modules)
  assert(seen["agent"] == nil and seen["test"] == nil and seen["store"] == nil, modules)
end
