--- An interface that lists another has its members ([`lang.check`], [`lang.declarations`]): the fields it leaves out are
--- those of the interfaces it lists, and of those they list, with the arguments put in and the receiver replaced by
--- the interface itself. A reader of a value of it finds them, a value of it is below each of them, and two listed
--- interfaces that declare one name differently are refused where the interface lists them. A record or class declares
--- every field it lists, so it needs none of this.
local Declarations = require("lang.declarations")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{}

--- What the first error says, or "" for none.
local function first_msg(r: Programs.Run): string
  local e = r.errors[1]
  if e == nil then
    return ""
  end
  return e.msg
end

--- Checks that `source` has exactly the errors `codes` (space separated) and that the first says `msg`.
local function refused(source: string, codes: string, msg?: string)
  local r = Programs.run(source)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. source)
  assert(Programs.codes(r) == codes, "wanted " .. codes .. ", got " .. Programs.codes(r) .. " in\n" .. source .. "\n" ..
      first_msg(r))
  if msg ~= nil then
    assert(first_msg(r):find(msg, 1, true) ~= nil, first_msg(r) .. "\nwanted " .. msg)
  end
end

--- Checks that the declarations of `source` have exactly the errors `codes`, and that the first says `msg`. Answers the
--- first error.
local function declared_wrong(source: string, codes: string, msg: string): Declarations.Error
  local r = Programs.run(source)
  local got = ""
  for _, e in ipairs(r.lowered.errors) do
    got = got .. (if got == "" then "" else " " end) .. e.code
  end
  assert(got == codes, got .. " in\n" .. source)
  local first = assert(r.lowered.errors[1])
  assert(first.msg:find(msg, 1, true) ~= nil, first.msg .. "\nwanted " .. msg)
  return first
end

--- Checks that `source` has no error.
local function accepted(source: string)
  local r = Programs.run(source)
  assert(#r.before == 0 and #r.errors == 0, table.concat(r.before, " ") .. first_msg(r) .. " in\n" .. source)
end

local CHAIN <const> = [[
local interface Writer
  write: function(Writer, string): integer
  mut open: boolean
  name: string
  again: function(Writer): Writer
end
local interface Collector is Writer
  result: function(Collector): string
end
local interface Counted is Collector
  count: function(Counted): integer
end
]]

-- lookup ----------------------------------------------------------------------------------------------------

local function test_a_field_and_a_method_of_the_interface_listed_are_found()
  accepted(CHAIN .. "local function f(c: Collector): string\n  c:write('x')\n  return c.name .. c:result()\nend\nprint(f)\n")
end

local function test_a_member_of_an_interface_two_listings_up_is_found()
  accepted(CHAIN .. "local function f(c: Counted): integer\n  c:write('x')\n  c.open = false\n  return #c.name + c:count()\nend\nprint(f)\n")
end

local function test_a_name_no_interface_of_the_chain_declares_is_still_unknown()
  refused(CHAIN .. "local function f(c: Counted)\n  c:flush()\nend\nprint(f)\n", "field_unknown", "`Counted` has no field `flush`")
end

local function test_the_call_is_typed_by_the_inherited_method()
  refused(CHAIN .. "local function f(c: Collector): string\n  return c:write('x')\nend\nprint(f)\n", "not_assignable")
  refused(CHAIN .. "local function f(c: Collector)\n  c:write(3)\nend\nprint(f)\n", "not_assignable")
  accepted(CHAIN .. "local function f(c: Collector): integer\n  return c:write('x')\nend\nprint(f)\n")
end

local function test_the_receiver_of_an_inherited_method_is_the_interface_that_has_it()
  -- `again` answers a Writer in Writer, and the call on a Collector answers that Writer: only the receiver is replaced.
  accepted(CHAIN .. "local function f(c: Collector): Writer\n  return c:again()\nend\nprint(f)\n")
  refused(CHAIN .. "local function f(c: Collector): Collector\n  return c:again()\nend\nprint(f)\n", "not_assignable")
end

local function test_the_arguments_of_the_interface_listed_are_put_in()
  local head = "local interface Source<T>\n  last: T\n  next: function(Source<T>): T?\nend\nlocal interface Names is Source<string>\nend\n" ..
    "local interface Tagged<U> is Source<{U}>\nend\n"
  accepted(head .. "local function f(n: Names): string\n  local s: string? = n:next()\n  return n.last .. (s or '')\nend\nprint(f)\n")
  refused(head .. "local function f(n: Names): integer\n  return n.last\nend\nprint(f)\n", "not_assignable")
  accepted(head .. "local function f(t: Tagged<integer>): {integer}\n  return t.last\nend\nprint(f)\n")
end

local function test_a_field_that_is_mut_in_the_interface_listed_is_written_and_a_fixed_one_is_not()
  accepted(CHAIN .. "local function f(c: Collector)\n  c.open = true\nend\nprint(f)\n")
  refused(CHAIN .. "local function f(c: Collector)\n  c.name = 'x'\nend\nprint(f)\n", "field_fixed")
end

local function test_an_interface_that_repeats_a_field_has_its_own_and_one_that_does_not_has_the_listed()
  accepted("local interface A\n  n: integer\nend\nlocal interface B is A\n  n: integer\nend\n" ..
      "local function f(b: B): integer\n  return b.n\nend\nprint(f)\n")
end

local function test_a_diamond_of_listings_has_each_field_once()
  accepted("local interface A\n  n: integer\nend\nlocal interface B is A\nend\nlocal interface C is A\nend\n" ..
      "local interface D is B, C\nend\nlocal function f(d: D): integer\n  return d.n\nend\nprint(f)\n")
end

local function test_a_member_of_several_interfaces_listed_is_found_in_each()
  accepted("local interface A\n  n: integer\nend\nlocal interface B\n  s: string\nend\nlocal interface C is A, B\nend\n" ..
      "local function f(c: C): string\n  return c.s .. tostring(c.n)\nend\nprint(f)\n")
end

-- assignability -----------------------------------------------------------------------------------------------

local function test_a_value_of_the_interface_is_below_each_interface_it_lists_and_not_the_other_way()
  accepted(CHAIN .. "local function f(c: Counted)\n  local k: Collector = c\n  local w: Writer = c\n  print(k, w)\nend\nprint(f)\n")
  refused(CHAIN .. "local function f(w: Writer)\n  local k: Collector = w\n  print(k)\nend\nprint(f)\n", "not_assignable",
    "`w` is `Writer`, where `Collector` is wanted")
  refused(CHAIN .. "local function f(k: Collector)\n  local c: Counted = k\n  print(c)\nend\nprint(f)\n", "not_assignable")
end

-- conflicts -------------------------------------------------------------------------------------------------

local function test_two_listed_interfaces_that_declare_a_name_differently_are_refused_with_a_fix()
  local head = "local interface A\n  n: integer\nend\nlocal interface B\n  n: string\nend\n"
  local e = declared_wrong(head .. "local interface C is A, B\nend\n", "interface_disagrees",
    "`C` lists `A` and `B`, which declare `n` differently, as `integer` and `string`")
  assert(e.fix:find("change `B.n` to `integer` to match `A.n`, or change `A.n` to match it, or list only one of the two in `C`", 1,
    true) ~= nil, e.fix)
  assert(e.msg:find("so `C.n` has no single type", 1, true) ~= nil, e.msg)
  declared_wrong("local interface A\n  n: integer\nend\nlocal interface B\n  mut n: integer\nend\n" ..
      "local interface C is A, B\nend\n", "interface_disagrees", "`integer` and `mut integer`")
  -- declaring the name in C agrees with one, and the other is the one that disagrees
  declared_wrong(head .. "local interface C is A, B\n  n: integer\nend\n", "interface_disagrees",
    "`C.n` is `integer`, but `B` declares it as `string`")
end

local function test_a_conflict_is_said_where_it_starts_and_not_again_by_the_interfaces_below_it()
  local head = "local interface A\n  n: integer\nend\nlocal interface B is A\n  n: string\nend\n"
  declared_wrong(head .. "local interface C is B\nend\n", "interface_disagrees", "`B.n` is `string`, but `A` declares it as `integer`")
end

local function test_a_cycle_of_listings_is_refused_and_a_lookup_through_it_ends()
  local source = "local interface A is B\n  n: integer\nend\nlocal interface B is A\nend\n" ..
    "local function f(b: B): integer\n  return b.n\nend\nprint(f)\n"
  declared_wrong(source, "super_cycle", "lists")
  assert(#Programs.run(source).errors <= 1)
  declared_wrong("local interface A is A\nend\nlocal function f(a: A)\n  print(a.n)\nend\nprint(f)\n", "super_cycle", "lists itself")
end

local function test_a_class_that_leaves_out_a_field_of_the_chain_is_still_refused()
  declared_wrong(CHAIN .. "local class Buf is Counted\n  mut open: boolean\n  name: string\nend\n",
    "interface_disagrees interface_disagrees interface_disagrees interface_disagrees", "`Buf` lists")
end

local function test_two_listed_interfaces_that_differ_only_in_omittability_are_refused()
  declared_wrong("local interface A\n  n: integer?\nend\nlocal interface B\n  n?: integer\nend\nlocal interface C is A, B\nend\n",
    "interface_disagrees", "`integer?` and `integer? (omittable)`")
end

-- a method is called, not read -------------------------------------------------------------------------------

local function test_an_inherited_method_read_as_a_value_is_refused_as_the_interface_s_own_is()
  refused(CHAIN .. "local function f(c: Collector)\n  local g = c.write\n  print(g)\nend\nprint(f)\n", "interface_method_value",
    "reads the method `write` of the interface `Collector` as a value")
  refused(CHAIN .. "local function f<T is Collector>(v: T)\n  local g = v.write\n  print(g)\nend\nprint(f)\n",
    "interface_method_value")
end

local OPTIONAL <const> = [[
local interface P
  cb?: function(P): string
end
local interface C is P
end
local class K1 is C
  tag: string
  cb?: function(K1): string
end
local class K2 is C
  cb?: function(K2): string
end
local k1: K1 = { tag = "t1", cb = function(self: K1): string return self.tag end }
local k2: K2 = { cb = function(self: K2): string return "k2" end }
]]

local function test_an_optional_method_read_as_a_value_is_refused_through_the_interface_and_through_the_one_listing_it()
  -- read as a value and called with another implementer, `cb` of one class would run on the other and answer nil
  local through_child = OPTIONAL .. "local function f(a: C, b: C)\n  local g = a.cb\n  if g then\n    print(g(b))\n  end\nend\nf(k1, k2)\n"
  refused(through_child, "interface_method_value", "reads the method `cb` of the interface `C` as a value")
  refused(OPTIONAL .. "local function f(a: P, b: P)\n  local g = a.cb\n  if g then\n    print(g(b))\n  end\nend\nf(k1, k2)\n",
    "interface_method_value", "of the interface `P`")
  assert(not Programs.execute(through_child, false).ran, "a refused program is not run")
end

local function test_whether_an_optional_method_is_there_may_be_asked_through_the_interface_and_the_one_listing_it()
  for _, who in ipairs({ "C", "P" }) do
    local head = OPTIONAL .. "local function f(a: " .. who .. "): boolean\n"
    accepted(head .. "  return a.cb ~= nil\nend\nprint(f)\n")
    accepted(head .. "  return nil == a.cb\nend\nprint(f)\n")
    accepted(head .. "  if a.cb then\n    return true\n  end\n  return false\nend\nprint(f)\n")
    accepted(head .. "  if not a.cb then\n    return false\n  end\n  return true\nend\nprint(f)\n")
  end
end

local function test_an_optional_method_is_called_where_a_test_showed_it_is_there_and_not_elsewhere()
  local head = OPTIONAL .. "local function f(a: C): string\n"
  accepted(head .. "  if a.cb ~= nil then\n    return a:cb()\n  end\n  return \"none\"\nend\nprint(f)\n")
  accepted(head .. "  if a.cb then\n    return a:cb()\n  end\n  return \"none\"\nend\nprint(f)\n")
  -- the fact is the place `a.cb`'s: another receiver, and what follows the test, have none
  refused(head .. "  if a.cb ~= nil then\n    return \"x\"\n  end\n  return a:cb()\nend\nprint(f)\n", "not_callable")
  refused(head .. "  return a:cb()\nend\nprint(f)\n", "nil_not_allowed")
  refused(OPTIONAL .. "local function f(a: C, b: C): string\n  if a.cb ~= nil then\n    return b:cb()\n  end\n  return \"\"\nend\nprint(f)\n",
    "nil_not_allowed")
end

local function test_the_fix_of_an_optional_method_read_as_a_value_is_a_test_then_a_call_which_is_accepted()
  local source = OPTIONAL .. "local function f(a: C): boolean\n  local g = a.cb\n  return g ~= nil\nend\nprint(f)\n"
  refused(source, "interface_method_value")
  local r = Programs.run(source)
  local e = assert(r.errors[1])
  assert(e.fix == "test that it is there, then call it: `if a.cb ~= nil then a:cb(...) end`", e.fix)
  -- a plain method keeps the plain fix
  local plain = Programs.run(CHAIN .. "local function f(c: Collector)\n  local g = c.write\n  print(g)\nend\nprint(f)\n")
  local plain_error = assert(plain.errors[1])
  assert(plain_error.fix == "call it as `c:write(...)`", plain_error.fix)
end

-- run -------------------------------------------------------------------------------------------------------

local function test_the_call_of_an_inherited_method_on_a_value_of_the_interface_runs()
  local source = CHAIN .. [[
local class Buf is Counted
  mut open: boolean
  name: string
  parts: mut {string}
  function write(self, s: string): integer
    self.parts[#self.parts + 1] = s
    return #s
  end
  function again(self): Writer
    return self
  end
  function result(self): string
    return table.concat(self.parts)
  end
  function count(self): integer
    return #self.parts
  end
end
local b: Buf = { open = true, name = "buf", parts = {} }
local c: Collector = b
local k: Counted = b
print(c:write("ab"), c:again():write("cde"), k:count(), c:result(), c.name, c.open)
c.open = false
print(k.open, k:result())
]]
  local done = Programs.execute(source, false)
  assert(done.ran and done.fault == nil, tostring(done.fault) .. table.concat(done.run.before, "; ") .. Programs.codes(done.run) .. first_msg(done.run) .. "\n" .. done.lua)
  assert(#done.printed == 2, table.concat(done.printed, "|"))
  assert(done.printed[1] == "2\t3\t2\tabcde\tbuf\ttrue", done.printed[1])
  assert(done.printed[2] == "false\tabcde", done.printed[2])
  assert(done.lua:find(":write(", 1, true) ~= nil and done.lua:find("c.open = false", 1, true) ~= nil, done.lua)
end

local function test_an_optional_method_called_after_the_test_runs_on_each_implementer_s_own_value()
  local source = OPTIONAL .. [[
local class K3 is C
  cb?: function(K3): string
end
local k3: K3 = { cb = nil }
local function f(a: C)
  if a.cb ~= nil then
    print(a:cb())
  else
    print("none")
  end
end
f(k1)
f(k2)
f(k3)
]]
  local done = Programs.execute(source, false)
  assert(done.ran and done.fault == nil, tostring(done.fault) .. table.concat(done.run.before, "; ") .. Programs.codes(done.run) ..
      first_msg(done.run) .. "\n" .. done.lua)
  assert(table.concat(done.printed, "|") == "t1|k2|none", table.concat(done.printed, "|"))
end
