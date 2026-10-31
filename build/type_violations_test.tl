--- A checked run fails for a parameter declared under cosmic/ that the hook met, even where a `pcall` swallowed the raise.
local Test = require("cosmic.test")
local TypeViolations = require("build.type_violations")
local worker = require("build.test_worker")

Test.policy{}

local function row(kind: string, target: string): TypeViolations.Row
  return { kind = kind, at = "cosmic/a_test.tl:3", target = target, declared = "string", actual = "table",
    test = "cosmic.a_test test_f" }
end

local function test_the_first_library_parameter_is_named_with_its_place_and_test()
  local line = TypeViolations.library({ row("parameter", "parameter x of F (build/f.tl:1)"),
    row("parameter", "parameter y of A.f (cosmic/a.tl:9)"), row("parameter", "parameter z of A.g (cosmic/a.tl:20)") })
  assert(line == "type violation: cosmic/a_test.tl:3: parameter y of A.f (cosmic/a.tl:9) declared string, got table " ..
      "(met by cosmic.a_test test_f)", line)
end

local function test_a_row_that_is_no_library_parameter_fails_nothing()
  assert(TypeViolations.library({}) == "")
  assert(TypeViolations.library({ row("parameter", "parameter x of F (build/f.tl:1)"),
    row("field", "field y (cosmic/a.tl:9)"), row("return", "return value 1 (cosmic/a.tl:9)"),
    row("fact", "x") }) == "")
end

--- A call whose raise is swallowed, as the library's own `pcall` swallows one.
local function protected(spec: string)
  local ok, _ = pcall(function() worker.cross(spec, "text") end)
  assert(ok == false)
end

local function test_a_violation_a_pcall_swallowed_is_still_a_row_the_run_fails_for()
  worker.install_checks()
  local before = #worker.violations()
  protected("p;cosmic/type_violations_fake.tl:2;Fake.f;x=integer")
  local rows: mut {TypeViolations.Row} = {}
  for i = before + 1, #worker.violations() do
    local met = assert(worker.violations()[i])
    rows[#rows + 1] = { kind = met.kind, at = met.at, target = met.target, declared = met.declared,
      actual = met.actual, test = "build.type_violations_test test_f" }
  end
  assert(#rows == 1, tostring(#rows))
  -- The fixture's own file is skipped, so this suite's run does not fail for it; the same row at a real file is not.
  assert(TypeViolations.library(rows) == "")
  local line = TypeViolations.library({ row("parameter", "parameter x of Fake.f (cosmic/type_violations_real.tl:2)") })
  assert(line:find("parameter x of Fake.f (cosmic/type_violations_real.tl:2) declared string, got table", 1, true) ~= nil,
    line)
end

local function test_only_the_listed_fixtures_of_their_own_test_are_exempt()
  local function met(file: string, test: string): TypeViolations.Row
    return { kind = "parameter", at = "cosmic/a_test.tl:3", target = "parameter x of Fake.f (" .. file .. ":2)",
      declared = "integer", actual = "string", test = test }
  end
  assert(TypeViolations.library({ met("cosmic/boundary_hook_fake.tl", "build.boundary_hook_test test_f") }) == "")
  assert(TypeViolations.library({ met("cosmic/x_fake.tl", "build.boundary_hook_test test_f") }) ~= "")
  assert(TypeViolations.library({ met("cosmic/boundary_hook_fake.tl", "cosmic.fs_test test_f") }) ~= "")
  assert(TypeViolations.library({ met("cosmic/boundary_hook_fake.tl", "build.boundary_hook_test_extra test_f") }) ~= "")
end
