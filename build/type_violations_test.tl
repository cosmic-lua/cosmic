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
      actual = met.actual, test = "t" }
  end
  local line = TypeViolations.library(rows)
  assert(line:find("parameter x of Fake.f (cosmic/type_violations_fake.tl:2) declared integer, got string", 1, true) ~= nil,
    line)
end
