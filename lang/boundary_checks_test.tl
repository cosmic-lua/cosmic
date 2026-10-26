--- Tests of [`lang.boundary_checks`] and of the list of typed parameters the checker keeps ([`Check.Checked.boundaries`]):
--- which parameters are listed, what each is named for, and the statement written for a function. What the code generator
--- does with the statements is in [`lang.codegen_test`]; the run end to end in [`build.boundary_hook_tool_test`].
local BoundaryChecks = require("lang.boundary_checks")
local Boundaries = require("lang.boundaries")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{}

--- The rows of `source` as `<owner>.<parameter>=<kinds>`, in order.
local function listed(source: string): string
  local run = Programs.run(source)
  assert(Programs.codes(run) == "", Programs.codes(run))
  local out: mut {string} = {}
  for _, row in ipairs(run.result.boundaries) do
    assert(row.role == "parameter")
    out[#out + 1] = row.owner .. "." .. row.name .. "=" .. Boundaries.spec(Boundaries.kinds(row.type))
  end
  return table.concat(out, " ")
end

local function test_each_typed_parameter_of_a_function_is_listed_with_the_kinds_its_type_admits()
  assert(listed(table.concat({
    "local function f(a: integer, b: string?, c?: boolean, d: {string}): integer",
    "  return a",
    "end",
    "",
  }, "\n")) == "f.a=integer f.b=string|nil f.c=boolean|nil f.d=table")
end

local function test_a_variadic_parameter_self_and_an_any_parameter_are_not_listed()
  assert(listed(table.concat({
    "local record R",
    "  n: integer",
    "end",
    "local function g(a: any, ...: integer) end",
    "function R.m(self: R, by: integer) end",
    "",
  }, "\n")) == "R.m.by=integer")
end

local function test_the_owner_is_the_name_the_program_calls_the_function_by()
  assert(listed(table.concat({
    "local record R",
    "end",
    "local class C",
    "  function add(self: C, by: integer) end",
    "end",
    "function R.make(n: integer) end",
    "local run = function(s: string) end",
    "",
  }, "\n")) == "C.add.by=integer R.make.n=integer function.s=string")
end

local function test_a_function_with_no_checked_parameter_has_no_statement()
  local source = "local function g(a: any, ...: integer) end\nlocal function h(x: integer) end\n"
  local run = Programs.run(source)
  local checks = BoundaryChecks.of(run.result.boundaries, source, "t.tl")
  local rows = run.result.boundaries
  assert(#rows == 1)
  local row = assert(rows[1])
  assert(checks[row.id] == 'if __cosmic_tc then __cosmic_tc(2, "p;t.tl:2;h;x=integer", x) end', tostring(checks[row.id]))
  local count = 0
  for _ in pairs(checks) do
    count = count + 1
  end
  assert(count == 1)
end

local function test_a_semicolon_in_a_file_name_does_not_split_the_spec()
  local source = "local function h(x: integer) end\n"
  local run = Programs.run(source)
  local checks = BoundaryChecks.of(run.result.boundaries, source, "a;b.tl")
  local row = assert(run.result.boundaries[1])
  assert(checks[row.id] == 'if __cosmic_tc then __cosmic_tc(2, "p;a,b.tl:1;h;x=integer", x) end', tostring(checks[row.id]))
end

local function test_a_boundary_row_is_kept_once_whatever_the_number_of_passes()
  local source = table.concat({
    "local function outer(a: integer)",
    "  for _ = 1, 2 do",
    "    local inner = function(b: string) end",
    "    inner(\"s\")",
    "  end",
    "end",
    "",
  }, "\n")
  assert(listed(source) == "outer.a=integer function.b=string")
end
