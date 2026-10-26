local Test = require("cosmic.test")
local LoadModule = require("build.load_module")

Test.policy{}

local function test_load_answers_what_require_answers()
  assert(LoadModule.load("build.load_module") == LoadModule, "load answered another table than require")
end

local function test_load_raises_for_a_module_none_holds()
  local found, _ = pcall(LoadModule.load, "no.such.module")
  assert(not found, "load of a module no database holds answered")
end
