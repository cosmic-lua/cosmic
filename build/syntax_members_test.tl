--- Tests of [`build.syntax_members`]: what a source declares each type to have, and which types it names no rows for.
local Members = require("build.syntax_members")
local Node = require("build.syntax_node")
local Test = require("cosmic.test")

Test.policy{}

--- The rows `source` gives, as `owner|name|kind|scope|type`, one a line.
local function rows_of(source: string): string
  local chunk, why = Node.parse(source, "m.tl")
  local out: mut {string} = {}
  for _, row in ipairs(Members.found((assert(chunk, why)))) do
    out[#out + 1] = row.owner .. "|" .. row.name .. "|" .. row.kind .. "|" .. row.scope .. "|" .. row.type
  end
  return table.concat(out, "\n")
end

local function test_a_function_field_taking_the_record_first_is_held_by_the_values_unless_a_statement_gives_the_table_it()
  local text = table.concat({
    "local record R",
    "  held: function(self: R): integer",
    "  given: function(self: R): integer",
    "  other: function(x: integer): integer",
    "end",
    "function R.given(self: R): integer return 1 end",
    "return R",
    "",
  }, "\n")
  assert(rows_of(text) == table.concat({
    "R||record|both|",
    "R|held|field|instance|function(self: R): integer",
    "R|given|field|both|function(self: R): integer",
    "R|other|field|both|function(x: integer): integer",
  }, "\n"), rows_of(text))
  -- An assignment `R.held = ...` gives the table that name too.
  local assigned = text:gsub("return R", "R.held = function(self: R): integer return 2 end\nreturn R")
  assert(rows_of(assigned):find("R|held|field|both|", 1, true) ~= nil, rows_of(assigned))
end

local function test_the_absent_rule_holds_a_nested_record_to_the_statements_of_the_top_alone()
  local text = table.concat({
    "local record R",
    "  record Inner",
    "    f: function(self: R.Inner): integer",
    "  end",
    "end",
    "function R.f(): integer return 1 end",
    "return R",
    "",
  }, "\n")
  assert(rows_of(text):find("R.Inner|f|field|instance|", 1, true) ~= nil, rows_of(text))
end

local function test_a_class_without_type_parameters_has_its_functions_as_methods_of_its_values_and_a_generic_one_has_not()
  local plain = rows_of("local class C\n  n: integer\nend\nfunction C.make(): C return { n = 0 } end\nreturn C\n")
  assert(plain:find("C|make|function|value|function(): C", 1, true) ~= nil and
      plain:find("C|make|method|instance|function(): C", 1, true) ~= nil, plain)
  local generic = rows_of("local class Box<T>\n  v: T\nend\nfunction Box.make(): Box<integer> return { v = 1 } end\nreturn Box\n")
  assert(generic:find("Box|make|function|value|", 1, true) ~= nil and generic:find("Box|make|method|", 1, true) == nil, generic)
end

local function test_a_function_the_checker_refuses_to_give_a_class_is_no_row()
  -- `x` is a field of the class (`repeated_field`) and `__index` is a name Lua reads (`class_metamethod`).
  local text = table.concat({
    "local class C",
    "  x: integer",
    "end",
    "function C.x(): integer return 1 end",
    "function C.__index(): integer return 1 end",
    "function C.ok(): integer return 1 end",
    "return C",
    "",
  }, "\n")
  local got = rows_of(text)
  assert(got:find("C|x|function", 1, true) == nil and got:find("__index", 1, true) == nil, got)
  assert(got:find("C|ok|function|value|", 1, true) ~= nil, got)
end

local function test_only_the_first_of_a_name_a_function_gives_the_table_of_a_type_is_a_row()
  local got = rows_of("local record R\nend\nfunction R.f(): integer return 1 end\nfunction R.f(): string return '' end\nreturn R\n")
  assert(got == "R||record|both|\nR|f|function|value|function(): integer", got)
end

local function test_a_name_declared_twice_at_the_top_has_no_rows_and_neither_has_a_type_in_a_block()
  local twice = rows_of("local record R\n  n: integer\nend\nlocal record R\n  other: integer\nend\nfunction R.f() end\nreturn R\n")
  assert(twice == "", twice)
  local block = rows_of("local record S\n  n: integer\nend\ndo\n  local record T\n    m: integer\n  end\nend\nreturn S\n")
  assert(block == "S||record|both|\nS|n|field|both|integer", block)
  -- A name an alias or an import takes is another declaration of it.
  local alias = rows_of("local record R\nend\nlocal type R = integer\nreturn R\n")
  assert(alias == "", alias)
end
