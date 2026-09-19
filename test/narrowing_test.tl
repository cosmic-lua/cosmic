--- Proves the two groups of narrowing patch/tl adds past 06: a bare
--- variable narrows across a statement-form `assert(x, ...)`
--- (07-assert-narrows.txt), and `x.field` on a plain-variable base
--- narrows the same way a bare variable already does -- truthy read,
--- `assert`, `== nil` / `~= nil`, and the early-return shape --
--- through the fact-key mechanism 08 through 14 add. Each positive
--- case is paired with a negative one proving the narrow is dropped
--- on a write, and one proving a chained base (`a.b.field`, whose
--- base is itself a field access rather than a bare variable) is
--- never narrowed at all.
---
--- Every fixture is a single file in its own fresh subdirectory,
--- rather than several files sharing one `tmp`, because `build.
--- importer` compiles every `.tl` file it finds under a root
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
  local env, env_trouble = teal.environment_for(built, handle)
  if env == nil then
    work.close(handle)
    return false, env_trouble
  end
  local result, trouble = importer.compile(handle, built, env, "narrowing-test")
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
