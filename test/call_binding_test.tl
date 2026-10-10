--- Proves patch/tl's 40: a call whose expected result type refuses what
--- its arguments bind to a type variable is checked again with the
--- arguments first. `setmetatable(t, mt)` is `function<T>(T, metatable<T>):
--- T`, so a `return` in a function returning `R | nil` or an interface `R`
--- implements used to fix T to that return type and refuse the metatable
--- of `R`. A call the arguments still refuse stays refused.
---
--- Each fixture is a single file in its own fresh subdirectory, since
--- [`build.importer`] compiles every `.tl` file under a root together.

local Fs = require("cosmic.fs")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Compiles `source` as the one module of a fresh fixture project:
--- true, or false and what the compile refused.
local function compiles(tmp: string, case: string, source: string): boolean, string
  local root = tmp .. "/" .. case
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/probe.tl", source))
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return false, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, false)
  if staged == nil then
    work.close(handle)
    return false, stage_trouble
  end
  local result, trouble = importer.compile(handle, built, "call-binding-test")
  work.close(handle)
  if result == nil then
    return false, trouble
  end
  return true, ""
end

local prelude = [[
local interface Named
  name: string
end
local record Thing is Named
  name: string
end
local thing_mt: metatable<Thing> = { __index = Thing }
local record Other
  id: integer
end
local other_mt: metatable<Other> = {}
print(other_mt)
]]

local function test_a_constructor_may_return_its_record_or_nil(tmp: string)
  local ok, trouble = compiles(tmp, "optional", prelude .. [[
local function open(t: Thing): Thing | nil, string
  return setmetatable(t, thing_mt), ""
end
local function fresh(): Thing | nil, string
  return setmetatable({}, thing_mt), ""
end
print(open, fresh)
]])
  assert(ok, "setmetatable's result is a Thing, which a Thing | nil return takes, but: " ..
      tostring(trouble))
end

local function test_a_constructor_may_return_an_interface_its_record_implements(tmp: string)
  local ok, trouble = compiles(tmp, "interface", prelude .. [[
local function named(t: Thing): Named
  return setmetatable(t, thing_mt)
end
print(named)
]])
  assert(ok, "setmetatable's result is a Thing, which a Named return takes, but: " ..
      tostring(trouble))
end

--- Whether the compile was refused with `text` among its errors.
local function refused(ok: boolean, trouble: string, text: string): boolean
  return not ok and trouble:find(text, 1, true) ~= nil
end

local function test_a_wrong_metatable_is_still_refused(tmp: string)
  local ok, trouble = compiles(tmp, "wrong", prelude .. [[
local function open(t: Thing): Thing | nil, string
  return setmetatable(t, other_mt), ""
end
print(open)
]])
  assert(refused(ok, trouble, "argument 2: type parameter <T>: "),
    "a metatable of Other does not fit a Thing, but: " .. tostring(trouble))
  ok, trouble = compiles(tmp, "wrong-interface", prelude .. [[
local function named(t: Thing): Named
  return setmetatable(t, other_mt)
end
print(named)
]])
  assert(refused(ok, trouble, "argument 2: type parameter <T>: "),
    "a metatable of Other does not fit a Thing, but: " .. tostring(trouble))
end

local function test_a_result_the_return_type_refuses_is_still_refused(tmp: string)
  local ok, _trouble = compiles(tmp, "result", prelude .. [[
local function open(o: Other): Thing | nil, string
  return setmetatable(o, other_mt), ""
end
print(open)
]])
  assert(not ok, "an Other is no Thing | nil, but the compile passed")
end

local function test_a_refused_call_is_reported_as_the_first_order_found_it(tmp: string)
  local ok, trouble = compiles(tmp, "report", prelude .. [[
local function open(o: Other): Thing | nil, string
  return setmetatable(o, thing_mt), ""
end
print(open)
]])
  assert(refused(ok, trouble, "argument 1: got Other, expected Thing | nil"),
    "the arguments-first retry leaves the first order's report, but: " .. tostring(trouble))
  assert(not refused(ok, trouble, "in return value"),
    "the retry's own errors are not added, but: " .. tostring(trouble))
end

-- A table literal as the first argument is typed from the expected result
-- before the call is checked, so an interface return types it as the
-- interface and the metatable of its record then disagrees.
-- TODO: accept `return setmetatable({ ... }, thing_mt)` in a function
-- returning an interface Thing implements: it waits on the checker typing a
-- call's table-literal argument after the call's type variables are bound,
-- which patch/tl/40's retry cannot do once the literal has its type.
local function test_a_table_literal_for_an_interface_return_is_still_refused(tmp: string)
  local ok, trouble = compiles(tmp, "literal-interface", prelude .. [[
local function named(): Named
  return setmetatable({ name = "a" }, thing_mt)
end
print(named)
]])
  assert(refused(ok, trouble, "Thing is not a Named"),
    "known limit: a literal takes the interface's type first, but: " .. tostring(trouble))
end
