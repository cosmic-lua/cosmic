--- The `__cosmic_tc` hook of the test worker ([`worker.install_checks`]) fails a call at the first parameter of the
--- standard library that meets a kind its declaration refuses, and only that: a parameter declared elsewhere, and the
--- other kinds of boundary, are recorded and let through. The checks are crossed by hand with [`worker.cross`], as the
--- Lua of a checked function crosses them, so the test fails nothing of its own.
local Test = require("cosmic.test")
local worker = require("build.test_worker")

Test.policy{}

--- The spec of a one-parameter check declared at `place`, which admits `kinds`.
local function parameter(place: string, kinds: string): string
  return "p;" .. place .. ";Fake.f;x=" .. kinds
end

--- One value across the check `spec`.
local function cross(spec: string, value: any)
  worker.cross(spec, value)
end

--- No value across the check `spec`.
local function cross_nothing(spec: string)
  worker.cross(spec, nil)
end

local function met_since(before: integer): {worker.Violation}
  local met = worker.violations()
  local out: mut {worker.Violation} = {}
  for i = before + 1, #met do
    local each = met[i]
    if each ~= nil then out[#out + 1] = each end
  end
  return out
end

local function test_a_library_parameter_of_another_kind_fails_the_call_at_its_first_violation()
  worker.install_checks()
  local before = #worker.violations()
  local spec = parameter("cosmic/boundary_hook_fake.tl:3", "integer")
  worker.cross(spec, 1)
  local ok, why = pcall(cross, spec, "text")
  assert(not ok)
  local said = tostring(why)
  assert(said:find("parameter violated at ", 1, true) == 1, said)
  assert(said:find("parameter x of Fake.f (cosmic/boundary_hook_fake.tl:3) is string, declared integer", 1,
    true) ~= nil, said)
  local met = met_since(before)
  assert(#met == 1 and assert(met[1]).kind == "parameter" and assert(met[1]).actual == "string")
  -- The row is kept and counted again, and the call fails again.
  local again, _ = pcall(cross, spec, "text")
  assert(not again)
  assert(assert(met_since(before)[1]).count == 2)
end

local function test_a_nil_the_declaration_refuses_fails_and_one_it_admits_does_not()
  worker.install_checks()
  cross_nothing(parameter("cosmic/boundary_hook_fake.tl:5", "integer|nil"))
  Test.raises(function() cross_nothing(parameter("cosmic/boundary_hook_fake.tl:6", "integer")) end, "is nil, declared integer")
end

local function test_a_float_for_an_integer_and_a_missing_argument_fail()
  worker.install_checks()
  local ok, why = pcall(function()
    cross(parameter("cosmic/boundary_hook_fake.tl:7", "integer"), 1.5)
  end)
  assert(not ok and tostring(why):find("is float, declared integer", 1, true) ~= nil, tostring(why))
  cross(parameter("cosmic/boundary_hook_fake.tl:8", "number"), 1)
  cross(parameter("cosmic/boundary_hook_fake.tl:8", "number"), 2.5)
  local second = "p;cosmic/boundary_hook_fake.tl:10;Fake.g;a=string;b=integer"
  local passed, trouble = pcall(function() worker.cross(second, "text", 3) end)
  assert(passed, tostring(trouble))
  local refused, reason = pcall(function() worker.cross(second, "text", "3") end)
  assert(not refused and tostring(reason):find("parameter b of Fake.g", 1, true) ~= nil, tostring(reason))
  local lacking, missing = pcall(function() worker.cross(second, "text") end)
  assert(not lacking and tostring(missing):find("parameter b of Fake.g", 1, true) ~= nil and
      tostring(missing):find("is absent", 1, true) ~= nil, tostring(missing))
end

local function test_a_parameter_declared_outside_the_library_is_recorded_and_passes()
  worker.install_checks()
  local before = #worker.violations()
  worker.cross(parameter("build/boundary_hook_fake.tl:3", "integer"), "text")
  local met = met_since(before)
  assert(#met == 1 and assert(met[1]).kind == "parameter")
end

local function test_a_field_declared_in_the_library_is_recorded_and_passes()
  worker.install_checks()
  local before = #worker.violations()
  worker.cross("f;cosmic/boundary_hook_fake.tl:9;field;integer", "text")
  local met = met_since(before)
  assert(#met == 1 and assert(met[1]).kind == "field")
end
