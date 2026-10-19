--- Tests of [`lang.warnings`] and what [`lang.check`] reports with them: the unused and unread names of the fork's
--- `unused` and `unread` warnings, the `hint` ones, the catalog, and the type report by node id. The fork's own
--- warnings for the same programs are compared in [`build/warnings_fork_test.tl`].
local Ast = require("lang.ast")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")
-- The new grammar tests a type of the checker by its tag, which leaves this import unused once translated: it names the type the
-- asserts below test for.
local _fn_type: Types.Fn | nil = nil
local Warnings = require("lang.warnings")

Test.policy{}

--- The warnings of `source` as `code line:column name`, one string each, in source order.
local function found(source: string, modules?: {string: string}): {string}
  local run = Programs.run(source, modules)
  assert(#run.before == 0, table.concat(run.before, " ") .. " in\n" .. source)
  local out: {string} = {}
  for _, w in ipairs(run.result.warnings) do
    out[#out + 1] = tostring(w.code) .. " " .. tostring(w.y) .. ":" .. tostring(w.x)
  end
  return out
end

local function same(got: {string}, want: {string}, source: string)
  assert(table.concat(got, ", ") == table.concat(want, ", "),
    "wanted [" .. table.concat(want, ", ") .. "], got [" .. table.concat(got, ", ") .. "] in\n" .. source)
end

local function test_a_name_nothing_reads_is_unused_by_what_it_declares()
  local source = "local x = 1\nlocal function f(a: integer, b: integer): integer\n  return b\nend\nlocal function g() end\n" ..
    "local record R\nend\nlocal type T = integer\nlocal enum E\n  \"a\"\nend\nlocal fn = function() end\nreturn f(1, 2)\n"
  same(found(source), {
    "unused_variable 1:7", "unused_argument 2:18", "unused_function 5:16", "unused_type 6:14", "unused_type 8:12",
    "unused_type 9:12", "unused_function 12:7",
  }, source)
end

local function test_a_name_that_is_read_assigned_or_named_as_a_type_is_used()
  local source = "local record R\n  n: integer\nend\nlocal a = 1\nlocal b = a + 1\nlocal c: R = { n = b }\nlocal d: integer = 0\n" ..
    "d = c.n\nlocal function use(x: integer): integer\n  return x\nend\nlocal e = use(d)\nreturn e\n"
  -- `d` is written and read; `R` is only named as a type; `use` is called.
  same(found(source), {}, source)
end

local function test_a_name_that_begins_with_an_underscore_and_self_are_exempt()
  local source = "local _x = 1\nlocal _ = 2\nlocal function f(_a: integer, _: integer) end\nreturn f(1, 2)\n"
  same(found(source), {}, source)
end

local function test_a_name_assigned_and_never_read_is_unread_and_not_unused()
  local source = "local x = 1\nx = 2\nlocal function f(a: integer)\n  a = 3\nend\nreturn f(1)\n"
  same(found(source), { "unread 1:7", "unread 3:18" }, source)
  local run = Programs.run(source)
  local first = run.result.warnings[1]
  assert(first ~= nil and first.kind == "unread" and first.msg == "variable x (of type integer) is never read", first and first.msg or "")
end

local function test_a_function_only_its_own_body_calls_is_unused()
  local source = "local function count(n: integer): integer\n  if n == 0 then\n    return 0\n  end\n  return count(n - 1)\nend\n" ..
    "local function down(n: integer): integer\n  if n == 0 then\n    return 0\n  end\n  return down(n - 1)\nend\nreturn down(3)\n"
  same(found(source), { "unused_function 1:16" }, source)
end

local function test_a_type_declared_inside_another_is_named_through_it_and_never_unused()
  local source = "local record Outer\n  record Inner\n    n: integer\n  end\n  held: integer\nend\nlocal o: Outer = nil\nreturn o\n"
  local run = Programs.run(source)
  assert(#run.before == 0)
  local inner = false
  for _, v in ipairs(run.scoped.list) do
    if v.name == "Inner" then
      inner = v.nested and #v.reads == 0
    end
  end
  assert(inner, "Inner is a nested type nothing reads by its own name")
  for _, w in ipairs(run.result.warnings) do
    assert(not tostring(w.msg):find("Inner", 1, true), w.msg)
  end
end

local function test_a_test_that_cannot_fail_by_the_types_is_no_warning_for_the_types_may_only_claim_it()
  -- A value narrowed through a test the checker refuses (`is_on_record` on an `any`) is a record for it, and the test of its
  -- field that tells a bare array from a node is live. Deleting it, as a "dead branch" would say, breaks `classify({1, 2})`.
  local source = "local record N\n  kind: string\nend\nlocal function classify(value: any): boolean\n  if not (value is N) then\n" ..
    "    return false\n  end\n  local kind = value.kind\n  if kind is string then\n    return true\n  end\n  return false\nend\n" ..
    "return classify\n"
  local run = Programs.run(source)
  assert(Programs.codes(run):find("is_on_record", 1, true) ~= nil, Programs.codes(run))
  for _, w in ipairs(run.result.warnings) do
    assert(tostring(w.kind) ~= "branch", w.msg)
  end
  -- The guard of an exported function's argument: the type says a string, the caller may not.
  local guard = "local function resolve(name: string): string\n  if not (name is string) then\n    error(\"name must be a string\")\n  end\n" ..
    "  return name\nend\nreturn resolve\n"
  same(found(guard), {}, guard)
  local plain = "local function f(x: integer): integer\n  if x is integer then\n    return 1\n  end\n  return 2\nend\nreturn f(1)\n"
  same(found(plain), {}, plain)
end

local RECORD <const> = "local record R\n  n: integer\n  get: function(self: R): integer\n  twice: function(self: R, k: integer): integer\n" ..
  "  make: function(n: integer): R\nend\n" ..
  "local function new(): R\n  return { n = 1, get = function(self: R): integer return self.n end, " ..
  "twice = function(self: R, k: integer): integer return self.n * k end, make = function(_n: integer): R return new() end }\nend\n" ..
  "local r = new()\n"

local function test_a_method_called_with_a_dot_and_its_receiver_is_a_hint()
  local source = RECORD .. "local a = r.get(r)\nlocal b = r.twice(r, 3)\nlocal c = r:get()\nlocal d = r.make(3)\nreturn a + b + c + d.n\n"
  same(found(source), { "method_dot 11:11", "method_dot 12:11" }, source)
  local run = Programs.run(source)
  local w = run.result.warnings[2]
  assert(w ~= nil and w.kind == "hint" and w.fix == "write `r:twice(3)` and pass the receiver once", w and w.fix or "")
end

local function test_a_method_given_another_receiver_or_none_is_no_hint_and_a_declaration_value_is_not_a_receiver()
  local source = RECORD .. "local other = new()\nlocal a = r.get(other)\nreturn a\n"
  -- another value of the declaration's type is passed: the receiver is not named twice, and the call is no hint
  same(found(source), {}, source)
  local record_source = "local record S\n  m: integer\nend\n" .. RECORD .. "local s: S = { m = 1 }\nlocal bad = r.get(s)\nreturn bad\n"
  local run = Programs.run(record_source)
  assert(Programs.codes(run):find("not_assignable", 1, true) ~= nil, Programs.codes(run))
  for _, w in ipairs(run.result.warnings) do
    assert(w.kind ~= "hint", w.msg)
  end
end

local function test_a_receiver_that_is_a_call_or_an_index_is_no_hint_for_two_calls_are_not_one()
  local source = RECORD .. "local function mk(): R\n  return new()\nend\nlocal list: {R} = { r }\nlocal a = mk().get(mk())\n" ..
    "local b = list[1].get(list[1])\nreturn a + b\n"
  same(found(source), {}, source)
end

local function test_a_receiver_that_is_a_name_or_the_fields_of_one_is_a_hint()
  local both = "local record Holder\n  get: function(self: Holder): integer\nend\nlocal record Box\n  held: Holder\nend\n" ..
    "local function make(): Holder\n  return { get = function(self: Holder): integer return 1 end }\nend\n" ..
    "local b: Box = { held = make() }\nlocal n = b.held.get(b.held)\nreturn n\n"
  same(found(both), { "method_dot 11:11" }, both)
  local run = Programs.run(both)
  local w = run.result.warnings[1]
  assert(w ~= nil)
  assert(w.fix == "write `b.held:get()` and pass the receiver once", w.fix)
end

local function test_the_type_report_gives_the_overload_a_call_took_for_its_callee()
  local source = "More.run(function(a: string, b: string): string\n  return a\nend)\nMore.run(function(a: string): string\n  return a\nend)\n" ..
    "More.run(function(): string\n  return \"x\"\nend)\n"
  local run = Programs.run(source)
  assert(Programs.codes(run) == "", Programs.codes(run))
  local wanted: {integer} = {}
  for _, s in ipairs(run.chunk.body.stats) do
    local call: Ast.CallExp | nil = nil
    if s is Ast.CallStat then
      call = s.call
    end
    if call ~= nil and call is Ast.Call then
      local callee = run.result.types[call.callee.id]
      assert(callee ~= nil and callee is Types.Fn, "the callee has a function type")
      local param = callee.params[1]
      assert(param ~= nil)
      local taken = param.type
      assert(taken is Types.Fn)
      wanted[#wanted + 1] = #taken.params
    end
  end
  assert(table.concat(wanted, ",") == "2,1,0", table.concat(wanted, ","))
end

local function test_every_code_has_one_row_of_the_kind_it_reports()
  assert(#Warnings.codes == #Warnings.catalog)
  local seen: {string: boolean} = {}
  for i, row in ipairs(Warnings.catalog) do
    assert(row.code == Warnings.codes[i], tostring(row.code))
    assert(seen[tostring(row.code)] == nil, "twice: " .. tostring(row.code))
    seen[tostring(row.code)] = true
    assert(Warnings.kind_of(row.code) == row.kind, tostring(row.code))
    assert(row.rule ~= "" and row.why ~= "" and row.fix ~= "", tostring(row.code))
  end
  local kinds: {string: boolean} = {}
  for _, row in ipairs(Warnings.catalog) do
    kinds[tostring(row.kind)] = true
  end
  assert(kinds["unused"] == true and kinds["unread"] == true and kinds["hint"] == true and kinds["branch"] == nil)
end

local function test_a_warning_is_no_error_and_the_warnings_are_in_source_order()
  local source = "local late = 1\nlocal function f(a: integer, b: integer): integer\n  return 1\nend\nlocal x: integer = 3.5\nreturn f(1, 2)\n"
  local run = Programs.run(source)
  assert(Programs.codes(run):find("not_assignable", 1, true) ~= nil, Programs.codes(run))
  local previous = -1
  assert(#run.result.warnings == 4)
  for _, w in ipairs(run.result.warnings) do
    assert(w.offset > previous and w.filename ~= "", w.msg)
    previous = w.offset
  end
end

--- The value of the `index`th local statement of the program `run` and the checker's result.
local function value_of(run: Programs.Run, index: integer): Ast.Exp
  local seen = 0
  for _, s in ipairs(run.chunk.body.stats) do
    if s is Ast.Local then
      seen = seen + 1
      if seen == index then
        local value = s.values[1]
        assert(value ~= nil)
        return value
      end
    end
  end
  error("no local statement " .. tostring(index))
end

local function test_the_type_report_gives_the_type_of_each_expression_by_the_id_of_its_node()
  local run = Programs.run("local a = 1\nlocal b = \"s\"\nlocal c = a + 2\n")
  local binary = value_of(run, 3)
  assert(binary is Ast.Binary)
  local t = run.result.types[binary.id]
  assert(t ~= nil and t.tag == "integer", "a + 2")
  local left = run.result.types[binary.left.id]
  assert(left ~= nil and left.tag == "integer", "a")
  local text = run.result.types[value_of(run, 2).id]
  assert(text ~= nil and text.tag == "string", "\"s\"")
end

local function test_the_type_report_covers_chains_calls_and_the_values_of_a_call_that_answers_lists()
  local source = "local record R\n  names: {string}\nend\nlocal function two(): integer, string\n  return 1, \"a\"\nend\n" ..
    "local r: R = { names = {} }\nlocal n, s = two()\nlocal count = #r.names\n"
  local run = Programs.run(source)
  assert(#run.before == 0 and #run.errors == 0, Programs.codes(run))
  local types = run.result.types
  local called = types[value_of(run, 2).id]
  assert(called ~= nil and called.tag == "integer", "the first value of the call")
  local measured = value_of(run, 3)
  assert(types[measured.id] ~= nil and types[measured.id].tag == "integer", "#r.names")
  assert(measured is Ast.Unary)
  local names = types[measured.operand.id]
  assert(names ~= nil and names.tag == "array", "r.names")
  local object = measured.operand
  assert(object is Ast.Field)
  local record = types[object.object.id]
  assert(record ~= nil and record.tag == "named", "r")
end
