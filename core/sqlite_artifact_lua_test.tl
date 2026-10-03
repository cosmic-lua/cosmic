--- Collector reentry runs outside the worker's coverage hook.
local Child = require("cosmic.child")
local Test = require("cosmic.test")
local Time = require("cosmic.time")
local fixture = require("build.sql_artifact_fixture")
local this_program = require("build.this_program")

Test.needs{ lua = true }

local function test_first_artifact_type_survives_constructor_reentry_from_finalizers(tmp: string)
  local path = fixture.write(tmp, "a", "one")
  local script = [[
local Sqlite = require("cosmic.sqlite")
collectgarbage("collect")
collectgarbage("stop")
local inner = {}
local during = false
local markers = {}
for i = 1, 100 do
  markers[i] = setmetatable({}, { __gc = function()
    if during then inner[#inner + 1] = assert(Sqlite.artifact(%q)) end
  end })
end
markers = nil
collectgarbage("incremental")
collectgarbage("param", "pause", 0)
collectgarbage("param", "stepmul", 100)
collectgarbage("param", "stepsize", 1)
collectgarbage("restart")
during = true
local outer = assert(Sqlite.artifact(%q))
during = false
assert(#inner > 0, "no constructor finalizer reentered")
for _, a in ipairs(inner) do
  local db = assert(a:open())
  assert(db:exec("SELECT * FROM modules"))
  assert(db:close())
  assert(a:close())
end
assert(outer:close())
collectgarbage("collect")
]]
  local command = this_program.program({ "-e", script:format(path, path) }, {
    stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(10) })
  local result = assert(Child.run(command.argv, command.options))
  assert(result.ok, result.stderr)
end
