--- Proves the narrowing that patch/tl adds. A bare variable narrows
--- across a statement-form `assert(x, ...)` (07-assert-narrows.txt).
--- `x.field` on a plain-variable base narrows as a bare variable does
--- -- truthy read, `assert`, `== nil` / `~= nil`, and the early-return
--- shape -- through the fact-key mechanism of 08 through 14. Each such
--- positive case has a negative one proving a write drops the narrow,
--- and one proving a chained base (`a.b.field`, whose base is itself a
--- field access rather than a bare variable) is never narrowed.
---
--- Further: `a or b` drops a's nil (20-or-drops-nil.txt); an `if` with
--- no `else` does not end the block holding it (21); and a guard
--- ending in `break`, `goto` or `error(...)` narrows below it as one
--- ending in `return` does (22 through 25), each with a case proving
--- the narrow stays out of code that control falling through can reach.
---
--- A bare variable on the left of `and` narrows in its right operand,
--- as a guard's does in its block (35), but not past it and not for a
--- union with a boolean member. `type(x) == "<name>"` narrows x as
--- `x is T` does (36a through 36g) -- only for a variable, only for
--- the standard `type` (the global or a `<const>` local holding it, as
--- for `error`), and a name type() never answers is refused.
---
--- Every fixture is a single file in its own fresh subdirectory,
--- rather than several files sharing one `tmp`, because
--- [`build.importer`] compiles every `.tl` file it finds under a root
--- together: two independent fixtures sharing a root would fail or
--- pass as one unit rather than on their own.

local Fs = require("cosmic.fs")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")

--- Builds the single-file fixture `source` at a fresh subdirectory of
--- `tmp` and reports whether the tree compiled.
local function try_build(tmp: string, name: string, source: string): boolean, string
  local root = tmp .. "/" .. name
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/probe.tl", source))
  local built, load_trouble = teal.load()
  if built == nil then
    return false, load_trouble
  end
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return false, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, false)
  if staged == nil then
    work.close(handle)
    return false, stage_trouble
  end
  local result, trouble = importer.compile(handle, built, "narrowing-test")
  work.close(handle)
  if result == nil then
    return false, trouble
  end
  return true, ""
end

local record_prelude = [[
local record R
   x: number
end
local record Holder
   field: R | nil
end
]]

local function test_assert_narrows_bare_variable(tmp: string)
  local ok, trouble = try_build(tmp, "assert-bare", [[
local record R
   x: number
end

local function get(): R | nil
   return nil
end

local function use(): number
   local r = get()
   assert(r, "msg")
   return r.x
end

print(use())
]])
  assert(ok, "assert(r, \"msg\") on a plain variable of a nil union " ..
    "should narrow it, but: " .. tostring(trouble))
end

local function test_truthy_record_field_narrows(tmp: string)
  local ok, trouble = try_build(tmp, "field-truthy", record_prelude .. [[
local function use(h: Holder): number
   if h.field then
      return h.field.x
   end
   return 0
end

print(use({ field = { x = 1 } }))
]])
  assert(ok, "if h.field then ... should narrow h.field, but: " ..
    tostring(trouble))
end

local function test_assert_record_field_narrows(tmp: string)
  local ok, trouble = try_build(tmp, "field-assert", record_prelude .. [[
local function use(h: Holder): number
   assert(h.field)
   return h.field.x
end

print(use({ field = { x = 1 } }))
]])
  assert(ok, "assert(h.field) should narrow h.field, but: " ..
    tostring(trouble))
end

local function test_eq_nil_record_field_narrows(tmp: string)
  local ok, trouble = try_build(tmp, "field-eq-nil", record_prelude .. [[
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
]])
  assert(ok, "h.field == nil / ~= nil should narrow h.field, but: " ..
    tostring(trouble))
end

local function test_early_return_record_field_narrows(tmp: string)
  local ok, trouble = try_build(tmp, "field-early-return", record_prelude .. [[
local function use(h: Holder): number
   if not h.field then
      return 0
   end
   return h.field.x
end

print(use({ field = { x = 1 } }))
]])
  assert(ok, "if not h.field then return end should narrow h.field " ..
    "below the guard, but: " .. tostring(trouble))
end

local function test_record_field_narrow_chains_through_base(tmp: string)
  local ok, trouble = try_build(tmp, "field-chain", [[
local record R
   x: number
end
local record Sub
   field: R
end
local record Outer
   sub: Sub | nil
end

local function use(o: Outer): number
   if o.sub then
      return o.sub.field.x
   end
   return 0
end

print(use({ sub = { field = { x = 1 } } }))
]])
  assert(ok, "guarding o.sub should let o.sub.field see the narrow " ..
    "through o.sub's own return value, but: " .. tostring(trouble))
end

local function test_record_field_narrow_invalidated_by_field_write(tmp: string)
  local ok, _ = try_build(tmp, "field-invalidate-field", record_prelude .. [[
local function use(h: Holder): number
   if h.field then
      h.field = nil
      return h.field.x
   end
   return 0
end
]])
  assert(not ok, "writing h.field after guarding it should drop the " ..
    "narrow, requiring the guard again")
end

local function test_record_field_narrow_invalidated_by_base_write(tmp: string)
  local ok, _ = try_build(tmp, "field-invalidate-base", record_prelude .. [[
local function use(h: Holder, other: Holder): number
   if h.field then
      h = other
      return h.field.x
   end
   return 0
end
]])
  assert(not ok, "reassigning h after guarding h.field should drop the " ..
    "narrow, requiring the guard again")
end

local function test_record_field_narrow_does_not_chain_through_field_base(tmp: string)
  local ok, _ = try_build(tmp, "field-no-chain", [[
local record R
   x: number
end
local record Sub
   field: R | nil
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
]])
  assert(not ok, "o.sub.field's base, o.sub, is itself a field access " ..
    "rather than a bare variable, so guarding o.sub.field must never " ..
    "narrow it")
end

local entry_prelude = [[
local record Entry
   size: integer
end

local function next_entry(): Entry | nil, string
   return nil, "done"
end
]]

local list_prelude = [[
local function list(_dir: string): {string} | nil, string
   return nil, "no such directory"
end
]]

--- Whether a refused build was refused for indexing a nil union, the
--- one refusal every negative case below is about: any other one --
--- an unused local, say -- would pass them for the wrong reason.
local function refused_nil_index(ok: boolean, trouble: string): boolean
  return not ok and trouble:find("cannot index key 'size'", 1, true) ~= nil
end

local function test_or_drops_the_left_nil(tmp: string)
  local ok, trouble = try_build(tmp, "or-drops-nil", entry_prelude .. list_prelude .. [[
local names = list("x") or {}
for _, name in ipairs(names) do print(name) end

local declared: {string} = list("x") or {}
print(#declared)

local e = next_entry() or { size = 0 }
print(e.size)
]])
  assert(ok, "`list(dir) or {}` cannot be nil, so it should be {string}, " ..
    "but: " .. tostring(trouble))
end

local function test_or_takes_one_value_of_a_call(tmp: string)
  local ok, trouble = try_build(tmp, "or-one-value", list_prelude .. [[
local function count(names: {string}): integer
   return #names
end
print(count(list("x") or {}))
]])
  assert(ok, "`f() or {}` is one value -- f's first, without its nil -- " ..
    "so it fills a one-argument call, but: " .. tostring(trouble))
end

-- Both sides one record type, into a declared union: `a`'s nil-less
-- type must unite with `b`'s as the same type, not as two tables.
local function test_or_of_two_fields_of_one_record_type(tmp: string)
  local ok, trouble = try_build(tmp, "or-same-record", [[
local record Node
   left: Node | nil
   right: Node | nil
end
local function pick(n: Node): Node | nil
   local at: Node | nil = n.left or n.right
   return at
end
print(pick({}))
]])
  assert(ok, "`n.left or n.right` into a `Node | nil` is one Node, but: " .. tostring(trouble))
end

local function test_or_nil_keeps_the_nil(tmp: string)
  local ok, trouble = try_build(tmp, "or-nil-keeps", entry_prelude .. [[
local e = next_entry() or nil
print(e.size)
]])
  assert(refused_nil_index(ok, trouble), "`x or nil` can still be nil, so indexing it must be refused")
end

local function test_or_keeps_the_right_nil(tmp: string)
  local ok, trouble = try_build(tmp, "or-right-nil", entry_prelude .. [[
local e = next_entry() or next_entry()
print(e.size)
]])
  assert(refused_nil_index(ok, trouble), "`a or b` with b a nil union can still be nil")
end

local function test_break_narrows_below_the_guard(tmp: string)
  local ok, trouble = try_build(tmp, "break-narrows", entry_prelude .. [[
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
]])
  assert(ok, "a guard ending in break should narrow below it, as one " ..
    "ending in return does, but: " .. tostring(trouble))
end

local function test_break_narrow_stays_in_the_loop(tmp: string)
  local ok, trouble = try_build(tmp, "break-stays", entry_prelude .. [[
local e = next_entry()
while true do
   if e == nil then break end
   print(e.size)
   break
end
print(e.size)
]])
  assert(refused_nil_index(ok, trouble), "the break leaves the loop with e nil, so the narrow " ..
    "must not reach the code after it")
end

local function test_break_on_one_path_does_not_narrow(tmp: string)
  local ok, trouble = try_build(tmp, "break-one-path", entry_prelude .. [[
local function flag(): boolean return true end
for _ = 1, 3 do
   local e = next_entry()
   if e == nil then
      if flag() then break end
   end
   print(e.size)
end
]])
  assert(refused_nil_index(ok, trouble), "a guard that falls through when its inner branch does " ..
    "not break must not narrow")
end

local function test_return_on_one_path_does_not_narrow(tmp: string)
  local ok, trouble = try_build(tmp, "return-one-path", entry_prelude .. [[
local function flag(): boolean return true end
local function use()
   local e = next_entry()
   if e == nil then
      if flag() then return end
   end
   print(e.size)
end
use()
]])
  assert(refused_nil_index(ok, trouble), "an inner if with no else can " ..
    "fall through, so the outer guard must not narrow")
end

local function test_goto_narrows_below_the_guard(tmp: string)
  local ok, trouble = try_build(tmp, "goto-narrows", entry_prelude .. [[
for _ = 1, 3 do
   local e = next_entry()
   if e == nil then
      goto continue
   end
   print(e.size)
   ::continue::
end
]])
  assert(ok, "a guard ending in goto should narrow below it, but: " ..
    tostring(trouble))
end

local function test_goto_narrow_ends_at_a_label(tmp: string)
  local ok, trouble = try_build(tmp, "goto-label", entry_prelude .. [[
local e = next_entry()
do
   if e == nil then goto skip end
   print(e.size)
   ::skip::
   print(e.size)
end
]])
  assert(refused_nil_index(ok, trouble), "a label is reached by the goto with e nil, so the " ..
    "narrow must not reach the code after it")
end

local function test_error_narrows_below_the_guard(tmp: string)
  local ok, trouble = try_build(tmp, "error-narrows", entry_prelude .. [[
local e, trouble = next_entry()
if e == nil then
   error(trouble)
end
print(e.size)
]])
  assert(ok, "a guard ending in error(...) should narrow below it, but: " ..
    tostring(trouble))
end

local function test_a_local_error_does_not_narrow(tmp: string)
  local ok, trouble = try_build(tmp, "error-local", entry_prelude .. [[
local function error(message: string)
   print(message)
end
local e, trouble = next_entry()
if e == nil then
   error(trouble)
end
print(e.size)
]])
  assert(refused_nil_index(ok, trouble), "a local function named error returns, so calling it " ..
    "must not narrow")
end

--- Whether a refused build was refused for indexing `key`, the refusal
--- a negative case below is about.
local function refused_index(ok: boolean, trouble: string, key: string): boolean
  return not ok and trouble:find("cannot index key '" .. key .. "'", 1, true) ~= nil
end

local function test_and_narrows_its_right_operand(tmp: string)
  local ok, trouble = try_build(tmp, "and-narrows", entry_prelude .. [[
local e = next_entry()
if e and e.size > 0 then print(e.size) end
local size = e and e.size
local grown = e and e.size > 0 and e.size + 1
while e and e.size > 0 do e = next_entry() end
print(size, grown)
]])
  assert(ok, "`e and e.size` reads e.size only when e is truthy, so not nil, but: " ..
    tostring(trouble))
end

local function test_and_narrow_stays_in_its_right_operand(tmp: string)
  local ok, trouble = try_build(tmp, "and-stays", entry_prelude .. [[
local e = next_entry()
local size = e and e.size
print(size, e.size)
]])
  assert(refused_nil_index(ok, trouble), "after `e and e.size` e can still be nil")
end

local function test_and_keeps_a_boolean_union(tmp: string)
  local ok, trouble = try_build(tmp, "and-boolean", [[
local record Entry
   size: integer
end
local function next_entry(): Entry | boolean | nil
   return nil
end
local e = next_entry()
print(e and e.size)
]])
  assert(refused_nil_index(ok, trouble), "a truthy Entry | boolean | nil is Entry or true, " ..
    "so `e and e.size` must stay refused")
end

local function test_type_test_narrows_any(tmp: string)
  local ok, trouble = try_build(tmp, "type-any", [[
local function upper(v: any): string
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
]])
  assert(ok, "type(v) == \"string\" should narrow an any to string as `v is string` " ..
    "does, but: " .. tostring(trouble))
end

local function test_type_test_narrows_a_union_to_its_members(tmp: string)
  local ok, trouble = try_build(tmp, "type-union", [[
local function count(v: string | {string} | nil): integer
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
]])
  assert(ok, "type() should narrow a union to the members it answers for, " ..
    "and its negation to the rest, but: " .. tostring(trouble))
end

local function test_type_test_negation_keeps_the_other_members(tmp: string)
  local ok, trouble = try_build(tmp, "type-negation", [[
local function count(v: string | {string}): integer
   if type(v) == "string" then return #v end
   return #v:upper()
end
print(count("a"))
]])
  assert(refused_index(ok, trouble, "upper"), "past `type(v) == \"string\"` v is the table")
end

local function test_a_local_type_does_not_narrow(tmp: string)
  local ok, trouble = try_build(tmp, "type-local", [[
local function type(_: any): string
   return "string"
end
local function upper(v: any): string
   if type(v) == "string" then return v:upper() end
   return ""
end
print(upper(1))
]])
  assert(refused_index(ok, trouble, "upper"), "a local function named type answers anything, " ..
    "so a test of it must not narrow")
end

local function test_another_name_for_type_does_not_narrow(tmp: string)
  local ok, trouble = try_build(tmp, "type-alias", [[
local kind = type
local function upper(v: any): string
   if kind(v) == "string" then return v:upper() end
   return ""
end
print(upper(1))
]])
  assert(refused_index(ok, trouble, "upper"), "a variable holding type is not trusted to keep " ..
    "holding it, so a test of it must not narrow")
end

local function test_type_test_of_a_field_does_not_narrow(tmp: string)
  local ok, trouble = try_build(tmp, "type-field", [[
local record Holder
   v: any
end
local function upper(h: Holder): string
   if type(h.v) == "string" then return h.v:upper() end
   return ""
end
print(upper({}))
]])
  assert(refused_index(ok, trouble, "upper"), "`is` narrows only a variable, and so does type()")
end

local function test_type_test_no_member_answers_is_a_plain_check(tmp: string)
  local ok, trouble = try_build(tmp, "type-mismatch", [[
local function check(n: number, s: string): integer
   if type(n) ~= "number" then error("n") end
   if type(s) == "table" then return 1 end
   if type(n) == "string" then return 2 end
   return 0
end
print(check(1, "a"))
]])
  assert(ok, "a type() test no member answers to stays a runtime check, " ..
    "not an error, but: " .. tostring(trouble))
end

local function test_type_never_answers_a_typo(tmp: string)
  local ok, trouble = try_build(tmp, "type-typo", [[
local function check(v: any): string
   if type(v) == "strnig" then return "x" end
   return ""
end
print(check(1))
]])
  assert(not ok and trouble:find("type() never answers \"strnig\"", 1, true) ~= nil,
    "type() never answers \"strnig\", so the test is a typo, but: " .. tostring(trouble))
end

local function test_a_reassignable_local_type_does_not_narrow(tmp: string)
  local ok, trouble = try_build(tmp, "type-localized", [[
local type = type
type = function(_: any): string return "string" end
local function upper(v: any): string
   if type(v) == "string" then return v:upper() end
   return ""
end
print(upper(1))
]])
  assert(refused_index(ok, trouble, "upper"), "`local type = type` can be assigned " ..
    "another function, so a test of it must not narrow")
end

local function test_a_reassignable_local_error_does_not_narrow(tmp: string)
  local ok, trouble = try_build(tmp, "error-localized", entry_prelude .. [[
local error = error
local e = next_entry()
if e == nil then error("x") end
print(e.size)
]])
  assert(refused_nil_index(ok, trouble), "`local error = error` can be assigned " ..
    "a function that returns, so calling it must not narrow")
end

local function test_type_test_with_an_interface_member_does_not_narrow(tmp: string)
  local ok, trouble = try_build(tmp, "type-interface", [[
local interface Sized
   n: integer
end
local function size(v: Sized | string): integer
   if type(v) ~= "table" then return 0 end
   return v.n
end
print(size("a"))
]])
  assert(refused_index(ok, trouble, "n"), "a userdata record may implement an interface, " ..
    "so type() telling a table says nothing of it")
end
