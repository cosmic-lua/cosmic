--- The narrowing programs of the fork's `test/narrowing_test.tl`, in the grammar, checked by the new checker against the real
--- standard library ([`lang/stdlib.d.tl`]): a guard narrows a variable below it when it ends the block (a `return`, a
--- `break`, a `continue`, an `error` or a call of a function that never returns, a block that never falls through), `or`
--- takes the left operand's nil away, `and` narrows its right operand, and `type(x) == "name"` narrows `x` as `x is T`
--- does. Each program is checked, and the codes of its errors (the scope builder's and the parser's first) are the ones
--- wanted: none for a program the rules take.
---
--- The fork narrowed a bare variable and nothing else; the new checker narrows a place (a variable or a field of one) until
--- something writes to it, so the programs that held "a field narrows nothing" are taken here, and the programs that
--- write to the place after the test are refused ([`lang/check_flow_test.tl`] holds the rules). Where a program was changed
--- or a result differs from the fork's, the comment of its test says why.
local Fs = require("cosmic.fs")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{
  grants = { { path = "lang/stdlib.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" } },
}

local type Session = function(source: string, module?: string, modules?: {string: string}): Programs.Run

local record Held
  mut session: Session?
  mut counter: integer
end

local held: Held = { session = nil, counter = 0 }

--- The session over the real standard library, lowered once.
local function session(): Session
  local kept = held.session
  if kept == nil then
    kept = Programs.session((assert(Fs.read("lang/prelude.d.tl"))), (assert(Fs.read("lang/stdlib.d.tl"))))
    held.session = kept
  end
  return kept
end

--- The codes of the errors of `source`, the scope builder's and the parser's first, space separated.
local function codes_of(source: string): string
  held.counter = held.counter + 1
  local r = session()(source, "n" .. tostring(held.counter))
  local all: mut {string} = {}
  for _, code in ipairs(r.before) do
    all[#all + 1] = code
  end
  local after = Programs.codes(r)
  if after ~= "" then
    all[#all + 1] = after
  end
  return table.concat(all, " ")
end

--- Asserts the errors of `source` are the codes `wanted` (none: it is taken).
local function checks(name: string, source: string, wanted: string)
  local got = codes_of(source)
  assert(got == wanted, name .. ": wanted [" .. wanted .. "], got [" .. got .. "] in\n" .. source)
end

--- The entry and the list the programs draw on.
local ENTRY <const> = "local record Entry\n   size: integer\nend\n\nlocal function next_entry(): Entry?, string\n   return nil, \"done\"\nend\n"

local function test_an_assert_narrows_a_variable()
  checks("assert-bare", [==[local record R
   x: number
end

local function get(): R?
   return nil
end

local function use(): number
   local r = get()
   assert(r, "msg")
   return r.x
end

print(use())
]==], "")
end

-- The fork narrowed a bare variable alone and refused a use of `h.field` after a test of it; the new checker narrows a
-- place ([`lang.flow`]) until a write to it or its base, so the same program is taken. Deliberate
-- (doc/plans/new-checker-types.md).
local function test_a_test_of_a_field_narrows_it_like_a_variable()
  checks("field-truthy", [==[local record R
   x: number
end
local record Holder
   field: R?
end

local function use(h: Holder): number
   if h.field then
      return h.field.x
   end
   return 0
end

print(use({ field = { x = 1 } }))
]==], "")
  checks("field-truthy-copy", [==[local record R
   x: number
end
local record Holder
   field: R?
end

local function use(h: Holder): number
   local field = h.field
   if field then
      return field.x
   end
   return 0
end

print(use({ field = { x = 1 } }))
]==], "")
end

-- Deliberate, as above.
local function test_an_assert_narrows_a_field_like_a_variable()
  checks("field-assert", [==[local record R
   x: number
end
local record Holder
   field: R?
end

local function use(h: Holder): number
   assert(h.field)
   return h.field.x
end

print(use({ field = { x = 1 } }))
]==], "")
  checks("field-assert-copy", [==[local record R
   x: number
end
local record Holder
   field: R?
end

local function use(h: Holder): number
   local field = assert(h.field)
   return field.x
end

print(use({ field = { x = 1 } }))
]==], "")
end

-- Deliberate, as above.
local function test_a_comparison_with_nil_narrows_a_field_like_a_variable()
  checks("field-eq-nil", [==[local record R
   x: number
end
local record Holder
   field: R?
end

local function use_eq(h: Holder): number
   if h.field == nil then
      return 0
   end
   return h.field.x
end

local function use_neq(h: Holder): number
   if h.field ~= nil then
      return h.field.x
   end
   return 0
end

print(use_eq({ field = { x = 1 } }))
print(use_neq({ field = { x = 1 } }))
]==], "")
  checks("field-eq-nil-copy", [==[local record R
   x: number
end
local record Holder
   field: R?
end

local function use_eq(h: Holder): number
   local field = h.field
   if field == nil then
      return 0
   end
   return field.x
end

local function use_neq(h: Holder): number
   local field = h.field
   if field ~= nil then
      return field.x
   end
   return 0
end

print(use_eq({ field = { x = 1 } }))
print(use_neq({ field = { x = 1 } }))
]==], "")
end

-- Deliberate, as above.
local function test_an_early_return_narrows_a_field_like_a_variable()
  checks("field-early-return", [==[local record R
   x: number
end
local record Holder
   field: R?
end

local function use(h: Holder): number
   if not h.field then
      return 0
   end
   return h.field.x
end

print(use({ field = { x = 1 } }))
]==], "")
  checks("field-early-return-copy", [==[local record R
   x: number
end
local record Holder
   field: R?
end

local function use(h: Holder): number
   local field = h.field
   if not field then
      return 0
   end
   return field.x
end

print(use({ field = { x = 1 } }))
]==], "")
end

-- Deliberate, as above.
local function test_a_test_of_a_field_narrows_a_chain_through_it()
  checks("field-chain", [==[local record R
   x: number
end
local record Sub
   field: R
end
local record Outer
   sub: Sub?
end

local function use(o: Outer): number
   if o.sub then
      return o.sub.field.x
   end
   return 0
end

print(use({ sub = { field = { x = 1 } } }))
]==], "")
  checks("field-chain-copy", [==[local record R
   x: number
end
local record Sub
   field: R
end
local record Outer
   sub: Sub?
end

local function use(o: Outer): number
   local sub = o.sub
   if sub then
      return sub.field.x
   end
   return 0
end

print(use({ sub = { field = { x = 1 } } }))
]==], "")
end

-- The fork told the write; the new checker refuses the read after it, with `nil_not_allowed`.
local function test_a_write_to_a_field_drops_what_a_test_of_it_showed()
  checks("field-invalidate-field", [==[local record R
   x: number
end
local record Holder
   mut field: R?
end

local function use(h: Holder): number
   if h.field then
      h.field = nil
      return h.field.x
   end
   return 0
end
]==], "nil_not_allowed")
end

-- The new checker names the dropped narrowing (`narrowing_dropped`).
local function test_a_write_to_the_base_drops_what_a_test_of_its_field_showed()
  checks("field-invalidate-base", [==[local record R
   x: number
end
local record Holder
   field: R?
end

local function use(h: Holder, other: Holder): number
   if h.field then
      h = other
      return h.field.x
   end
   return 0
end
]==], "narrowing_dropped")
end

-- Deliberate, as above.
local function test_a_test_of_a_field_of_a_field_narrows_it()
  checks("field-no-chain", [==[local record R
   x: number
end
local record Sub
   field: R?
end
local record Outer
   sub: Sub
end

local function use(o: Outer): number
   if o.sub.field then
      return o.sub.field.x
   end
   return 0
end
]==], "")
end

local function test_or_drops_the_left_nil()
  checks("or-drops-nil", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end

local function list(_dir: string): {string}?, string
   return nil, "no such directory"
end

local names = list("x") or {}
for _, name in ipairs(names) do print(name) end

local declared: {string} = list("x") or {}
print(#declared)

local e = next_entry() or { size = 0 }
print(e.size)
]==], "")
end

local function test_or_takes_one_value_of_a_call()
  checks("or-one-value", [==[local function list(_dir: string): {string}?, string
   return nil, "no such directory"
end

local function count(names: {string}): integer
   return #names
end
print(count(list("x") or {}))
]==], "")
end

local function test_or_of_two_fields_of_one_record_type()
  checks("or-same-record", [==[local record Node
   left: Node?
   right: Node?
end
local function pick(n: Node): Node?
   local at: Node? = n.left or n.right
   return at
end
print(pick({ left = nil, right = nil }))
]==], "")
end

local function test_or_nil_keeps_the_nil()
  checks("or-nil-keeps", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end

local e = next_entry() or nil
print(e.size)
]==], "nil_not_allowed")
end

local function test_or_keeps_the_right_nil()
  checks("or-right-nil", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end

local e = next_entry() or next_entry()
print(e.size)
]==], "nil_not_allowed")
end

local function test_break_narrows_below_the_guard()
  checks("break-narrows", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end

for _ = 1, 3 do
   local e, trouble = next_entry()
   if e == nil then
      print(trouble)
      break
   end
   print(e.size)
end

while true do
   local e = next_entry()
   if not e then break end
   print(e.size)
end
]==], "")
end

local function test_break_narrow_stays_in_the_loop()
  checks("break-stays", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end

local e = next_entry()
while true do
   if e == nil then break end
   print(e.size)
   break
end
print(e.size)
]==], "nil_not_allowed")
end

local function test_break_on_one_path_does_not_narrow()
  checks("break-one-path", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end

local function flag(): boolean return true end
for _ = 1, 3 do
   local e = next_entry()
   if e == nil then
      if flag() then break end
   end
   print(e.size)
end
]==], "nil_not_allowed")
end

local function test_return_on_one_path_does_not_narrow()
  checks("return-one-path", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end

local function flag(): boolean return true end
local function use()
   local e = next_entry()
   if e == nil then
      if flag() then return end
   end
   print(e.size)
end
use()
]==], "nil_not_allowed")
end

-- The grammar has `continue` and no `goto`: the fork's continue was a `goto` to the label that ends the body.
local function test_continue_narrows_below_the_guard()
  checks("goto-narrows", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end

for _ = 1, 3 do
   local e = next_entry()
   if e == nil then
      continue
   end
   print(e.size)

end
]==], "")
end

local function test_error_narrows_below_the_guard()
  checks("error-narrows", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end

local e, trouble = next_entry()
if e == nil then
   error(trouble)
end
print(e.size)
]==], "")
end

-- The new scope builder refuses a local that hides a global (`shadows`), so there is no program in which a local `error`
-- returns and the guard is read.
local function test_a_local_function_named_error_is_refused_as_a_shadow()
  checks("error-local", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end

local function error(message: string)
   print(message)
end
local e, trouble = next_entry()
if e == nil then
   error(trouble)
end
print(e.size)
]==], "shadows nil_not_allowed")
end

-- A condition that may be nil (`e and e.size > 0`) is `condition_type` here; the programs say `e ~= nil and ...`.
local function test_and_narrows_its_right_operand()
  checks("and-narrows", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end

local e = next_entry()
if e ~= nil and e.size > 0 then print(e.size) end
local size = e and e.size
local grown = 0
if e ~= nil and e.size > 0 then grown = e.size + 1 end
while e ~= nil and e.size > 0 do e = next_entry() end
print(size, grown)
]==], "")
end

local function test_and_narrow_stays_in_its_right_operand()
  checks("and-stays", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end

local e = next_entry()
local size = e and e.size
print(size, e.size)
]==], "nil_not_allowed")
end

local function test_and_keeps_a_boolean_union()
  checks("and-boolean", [==[local record Entry
   size: integer
end
local function next_entry(): (Entry | boolean)?
   return nil
end
local e = next_entry()
print(e and e.size)
]==], "condition_type field_unknown")
end

local function test_type_test_narrows_any()
  checks("type-any", [==[local function upper(v: any): string
   if type(v) ~= "string" then return "" end
   return v:upper()
end
local function describe(v: any, w: any): string
   if type(v) == "number" then
      return tostring(v + 1)
   elseif "boolean" == type(v) then
      local b: boolean = v
      return tostring(b)
   end
   if type(w) == "string" and #w > 0 then return w:lower() end
   if not (type(w) == "string") or w == "" then return "" end
   return w
end
local function asserted(v: any): integer
   assert(type(v) == "string")
   return #v
end
local function raised(v: any): integer
   if type(v) ~= "string" then error("not a string") end
   return #v
end
print(upper("a"), describe(1, "b"), asserted("c"), raised("d"))
]==], "")
end

local function test_type_test_narrows_a_union_to_its_members()
  checks("type-union", [==[local function count(v: (string | {string})?): integer
   if type(v) == "table" then return #v end
   if type(v) == "nil" then return 0 end
   return #v:upper()
end
local function whole(v: integer | string): integer
   if type(v) == "number" then
      local i: integer = v
      return i
   end
   return #v
end
print(count("a"), whole(1))
]==], "")
end

local function test_type_test_negation_keeps_the_other_members()
  checks("type-negation", [==[local function count(v: string | {string}): integer
   if type(v) == "string" then return #v end
   return #v:upper()
end
print(count("a"))
]==], "not_indexable")
end

-- As for `error`: `shadows`.
local function test_a_local_function_named_type_is_refused_as_a_shadow()
  checks("type-local", [==[local function type(_: any): string
   return "string"
end
local function upper(v: any): string
   if type(v) == "string" then return v:upper() end
   return ""
end
print(upper(1))
]==], "shadows any_use")
end

local function test_another_name_for_type_does_not_narrow()
  checks("type-alias", [==[local kind = type
local function upper(v: any): string
   if kind(v) == "string" then return v:upper() end
   return ""
end
print(upper(1))
]==], "any_use")
end

-- Deliberate, as for the fields above; `is` of a field narrows too.
local function test_a_type_test_and_an_is_test_narrow_a_field()
  checks("type-field", [==[local record Holder
   v: any
end
local function upper(h: Holder): string
   if type(h.v) == "string" then return h.v:upper() end
   return ""
end
print(upper)
]==], "")
  checks("type-field-copy", [==[local record Holder
   v: any
end
local function upper(h: Holder): string
   local v = h.v
   if type(v) == "string" then return v:upper() end
   return ""
end
print(upper)
]==], "")
  checks("is-field", [==[local record Holder
   v: string | number
end
local function upper(h: Holder): string
   if h.v is string then return h.v:upper() end
   return ""
end
print(upper({ v = "a" }))
]==], "")
end

local function test_a_type_test_no_member_answers_to_is_a_plain_check()
  checks("type-mismatch", [==[local function check(n: number, s: string): integer
   if type(n) ~= "number" then error("n") end
   if type(s) == "table" then return 1 end
   if type(n) == "string" then return 2 end
   return 0
end
print(check(1, "a"))
]==], "")
end

local function test_type_never_answers_a_typo()
  checks("type-typo", [==[local function check(v: any): string
   if type(v) == "strnig" then return "x" end
   return ""
end
print(check(1))
]==], "type_name")
end

local function test_a_local_holding_type_does_not_narrow()
  checks("type-localized", [==[local type = type
type = function(_: any): string return "string" end
local function upper(v: any): string
   if type(v) == "string" then return v:upper() end
   return ""
end
print(upper(1))
]==], "any_use")
end

local function test_a_local_holding_error_narrows()
  checks("error-localized", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end

local error = error
local e = next_entry()
if e == nil then error("x") end
print(e.size)
]==], "")
end

-- Refused by the rule that a function over `any` is no function over a narrower type (`any_use`), not by `may_return`;
-- the fork said "may return, where never".
local function test_a_local_holding_error_cannot_be_given_a_function_that_returns()
  checks("error-reassigned", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end

local error = error
error = print
local e = next_entry()
if e == nil then error("x") end
print(e.size)
]==], "any_use")
end

-- The fork refused: a userdata record may implement an interface. Past `type(v) ~= "table"` the value is a table, so the
-- interface it is is sound to read; deliberate.
local function test_type_test_telling_a_table_narrows_to_the_interface()
  checks("type-interface", [==[local interface Sized
   n: integer
end
local function size(v: Sized | string): integer
   if type(v) ~= "table" then return 0 end
   return v.n
end
print(size("a"))
]==], "")
end

local function test_a_never_function_narrows_below_its_guard()
  checks("never-local-function", [==[local function fail(m: string): never error(m) end
local function guard(x: string?): integer
   if x == nil then fail("no") end
   return x:len()
end
print(guard)
]==], "")
  checks("never-record-field", [==[local record Guard
   die: function(why: string): never
end
local g: Guard = { die = function(why: string): never error(why) end }
local function guard(x: string?): integer
   if x == nil then g.die("no") end
   return x:len()
end
print(guard)
]==], "")
  checks("never-method", [==[local record Guard
   die: function(self: Guard, why: string): never
end
local g: Guard = { die = function(_self: Guard, why: string): never error(why) end }
local function guard(x: string?): integer
   if x == nil then g:die("no") end
   return x:len()
end
print(guard)
]==], "")
  checks("never-generic", [==[local function fail<T>(m: T): never error(m) end
local function guard(x: string?): integer
   if x == nil then fail("no") end
   return x:len()
end
print(guard)
]==], "")
  checks("never-instantiated", [==[local function id<T>(f: T): T return f end
local function raise(m: string): never error(m) end
local fail = id(raise)
local function guard(x: string?): integer
   if x == nil then fail("no") end
   return x:len()
end
print(guard)
]==], "")
  checks("never-recursion", [==[local function fail(m: string): never fail(m) end
local function guard(x: string?): integer
   if x == nil then fail("no") end
   return x:len()
end
print(guard)
]==], "")
end

local function test_what_does_not_end_a_block_keeps_its_guard_open()
  checks("never-open-control", [==[local function fail(m: string) error(m) end
local function guard(x: string?): integer
   if x == nil then fail("no") end
   return x:len()
end
print(guard)
]==], "nil_not_allowed")
  checks("never-open-inner-if", [==[local function fail(m: string): never error(m) end
local function guard(x: string?): integer
   if x == nil then if print then fail("no") end end
   return x:len()
end
print(guard)
]==], "condition_type nil_not_allowed")
  checks("never-open-pcall", [==[local function fail(m: string): never error(m) end
local function guard(x: string?): integer
   if x == nil then pcall(fail, "no") end
   return x:len()
end
print(guard)
]==], "nil_not_allowed")
  checks("never-open-iterator", [==[local function fail(): never error('x') end
local function guard(x: string?): integer
   if x == nil then for _ in fail do end end
   return x:len()
end
print(guard)
]==], "nil_not_allowed")
  checks("never-open-operator", [==[local record V
   __add: function(a: V, b: V): never
end
local v: V
local function guard(x: string?): integer
   if x == nil then local _ = v + v end
   return x:len()
end
print(guard)
]==], "not_assigned operand_type operand_type nil_not_allowed")
end

local function test_an_ending_do_or_endless_loop_narrows_below_the_guard()
  checks("ends-narrow-do", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end
local function use()
   local e = next_entry()
   if e == nil then
      do return end
   end
   print(e.size)
end
use()
]==], "")
  checks("ends-narrow-while", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end
local function use()
   local e = next_entry()
   if e == nil then
      while true do print(1) end
   end
   print(e.size)
end
use()
]==], "")
  checks("ends-narrow-repeat", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end
local function use()
   local e = next_entry()
   if e == nil then
      repeat print(1) until false
   end
   print(e.size)
end
use()
]==], "")
end

local function test_a_do_or_loop_that_can_end_does_not_narrow()
  checks("falls-narrow-do", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end
local function flag(): boolean return true end
local function use()
   local e = next_entry()
   if e == nil then
      do if flag() then return end end
   end
   print(e.size)
end
use()
]==], "nil_not_allowed")
  checks("falls-narrow-while", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end
local function flag(): boolean return true end
local function use()
   local e = next_entry()
   if e == nil then
      while true do if flag() then break end end
   end
   print(e.size)
end
use()
]==], "nil_not_allowed")
  checks("falls-narrow-while-cond", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end
local function flag(): boolean return true end
local function use()
   local e = next_entry()
   if e == nil then
      while flag() do print(1) end
   end
   print(e.size)
end
use()
]==], "nil_not_allowed")
  checks("falls-narrow-repeat", [==[local record Entry
   size: integer
end

local function next_entry(): Entry?, string
   return nil, "done"
end
local function flag(): boolean return true end
local function use()
   local e = next_entry()
   if e == nil then
      repeat do break end until false
   end
   print(e.size)
end
use()
]==], "nil_not_allowed")
end

-- The fork read `goto` as a continue and refused one that was not; the grammar has no `goto` and no label, so both programs
-- of its tests are refused where they are lexed.
local function test_a_goto_and_a_label_are_no_part_of_the_grammar()
  for _, source in ipairs({
      ENTRY .. "local e = next_entry()\ndo\n   if e == nil then goto skip end\n   print(e.size)\n   ::skip::\n   print(e.size)\nend\n",
      ENTRY .. "local function use()\n   local e = next_entry()\n   if e == nil then\n      while true do goto out end\n   end\n   ::out::\n   print(e.size)\nend\nuse()\n",
  }) do
    local got = codes_of(source)
    assert(got:find("label_or_goto", 1, true) ~= nil, "wanted label_or_goto, got [" .. got .. "] in\n" .. source)
  end
end

-- `macroexp` is a Teal form the grammar does not have.
local function test_a_macroexp_is_no_part_of_the_grammar()
  local got = codes_of("local macroexp fail(m: string): never return error(m) end\nprint(fail)\n")
  assert(got ~= "", "a macroexp was taken")
end

local GUARD <const> = "local function guard(x: string?): integer\n   if x == nil then %s end\n   return #x:upper()\nend\nprint(guard)\n"

--- Checks `body` of a guard after requiring `p`, a record of overloaded fields, from a declaration file (the only place an
--- overload is written), against the small library of the tests of the checker.
local function overloaded(body: string, wanted: string)
  local declared: {string: string} = {
    ["pdecl"] = "local record P\n  f: function(string): never\n  f: function(integer): never\n  g: function(string): never\n" ..
      "  g: function(integer): string\nend\nreturn P\n",
  }
  local r = Programs.run("local p = require(\"pdecl\")\n" .. GUARD:format(body), nil, declared)
  assert(#r.before == 0, table.concat(r.before, " "))
  local got = Programs.codes(r)
  assert(got == wanted, body .. ": wanted [" .. wanted .. "], got [" .. got .. "]")
end

-- A call of an overloaded function that never returns ends the block when the overload the call chooses never returns, and
-- not when it returns.
local function test_an_overloaded_function_ends_the_block_by_the_overload_the_call_chooses()
  overloaded('p.f("no")', "")
  overloaded('p.f(1)', "")
  overloaded('p.g("no")', "")
  overloaded('p.g(1)', "nil_not_allowed")
end
