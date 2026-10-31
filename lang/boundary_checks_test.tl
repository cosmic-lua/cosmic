--- Tests of [`lang.boundary_checks`] and of the list of typed parameters the checker keeps ([`Check.Checked.boundaries`]):
--- which parameters are listed, what each is named for, and the statement written for a function. What the code generator
--- does with the statements is in [`lang.codegen_test`]; the run end to end in [`build.boundary_hook_tool_test`].
local BoundaryChecks = require("lang.boundary_checks")
local Boundaries = require("lang.boundaries")
local Hash = require("cosmic.hash")
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
  assert(checks[row.id] == 'if __cosmic_tc and __cosmic_mt(x) ~= "integer" then __cosmic_tc(2, "p;t.tl:2;h;x=integer", x) end', tostring(checks[row.id]))
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
  assert(checks[row.id] == 'if __cosmic_tc and __cosmic_mt(x) ~= "integer" then __cosmic_tc(2, "p;a,b.tl:1;h;x=integer", x) end', tostring(checks[row.id]))
end

local function test_a_parameter_the_program_gives_no_type_is_not_a_declaration()
  local source = table.concat({
    "local function each(items: {string}, visit: function(string, integer))",
    "end",
    "each({ \"a\" }, function(s, i) end)",
    "",
  }, "\n")
  assert(listed(source) == "each.items=table each.visit=function")
end

local function test_two_parameters_of_one_name_are_not_passed_on()
  local source = "local function h(_: string, _: integer, x: integer) end\n"
  local run = Programs.run(source)
  local checks = BoundaryChecks.of(run.result.boundaries, source, "t.tl")
  local row = assert(run.result.boundaries[1])
  assert(checks[row.id] == 'if __cosmic_tc and __cosmic_mt(x) ~= "integer" then __cosmic_tc(2, "p;t.tl:1;h;x=integer", x) end', tostring(checks[row.id]))
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

local ALL_KINDS <const>: {string} = { "integer", "number", "string", "boolean", "table", "function", "userdata", "nil" }

-- Values of every kind the hook tells apart, as the text of the expressions that make them: a float that is whole, a
-- userdata and a thread among them, and the nil that is no value but a parameter's absence.
local SAMPLES <const>: {string} = {
  "1", "0", "-3", "1.5", "2.0", "'s'", "''", "true", "false", "{}", "function() end", "hasher",
  "coroutine.create(function() end)", "nil",
}

-- The statement's test is the hook's own: for every set of kinds a parameter may be declared with and every kind of
-- value, the test is true exactly where the worker's hook would record a violation (a value none of the kinds admits;
-- "integer" admits no float, whole or not). [`build.boundary_hook_tool_test`] and [`lang.boundaries_fuzz_test`] hold the
-- hook itself to the same kinds; this test plants no row of its own in a checked run's report.
local function test_the_inline_test_is_true_exactly_where_the_hook_records_a_violation()
  local hasher = assert(Hash.hasher("sha256"))
  local cases = 0
  for mask = 1, (1 << #ALL_KINDS) - 1 do
    local list: mut {string} = {}
    local number, integer = false, false
    for i, kind in ipairs(ALL_KINDS) do
      if mask & (1 << (i - 1)) ~= 0 then
        list[#list + 1] = kind
        number = number or kind == "number"
        integer = integer or kind == "integer"
      end
    end
    -- "integer" is left out of a list that holds "number" ([`Boundaries.Kinds`]).
    if not (number and integer) then
      local test = BoundaryChecks.mismatch("x", list)
      for _, expression in ipairs(SAMPLES) do
        local source = "local f, hasher = ... local __cosmic_ty, __cosmic_mt = type, math.type local x = " .. expression ..
          " f(x, " .. test .. ")"
        local feed = assert(load(source, "=sample"))
        feed(function(value: any, answer: boolean)
          -- What the hook admits ([`build.test_worker`]'s): a value of one of the kinds, "integer" for a number that
          -- `math.type` says is one.
          local admitted = false
          for _, kind in ipairs(list) do
            if kind == "integer" then
              admitted = admitted or math.type(value) == "integer"
            else
              admitted = admitted or type(value) == kind
            end
          end
          assert(answer == not admitted, source .. " on " .. expression .. ": admitted is " .. tostring(admitted))
        end, hasher)
        cases = cases + 1
      end
    end
  end
  assert(cases > 1000, tostring(cases))
  -- No kind admits no value.
  assert(BoundaryChecks.mismatch("x", {}) == "true")
end
