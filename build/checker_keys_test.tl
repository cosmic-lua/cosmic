--- `Variable.key` of the checker (checker/tl.tl): every binding has one, and
--- every entry that stands for a binding, a narrowing or a widening of it
--- among them, holds the key of that binding. The checker records
--- `name=key` for each variable it finds ([`Env.key_trace`]); the programs
--- here read their names so that the trace says which binding each was.
local Test = require("cosmic.test")
local teal = require("build.teal")
local verdicts = require("build.checker_verdicts")

Test.policy{}

--- The keys the checker found `name` under while checking `source`, in the
--- order it found them, and every entry of the trace.
local function keys_of(source: string, name: string): {string}, {string}
  local built = assert(teal.load(true))
  local env = verdicts.environment(built)
  local trace: {string} = {}
  env.key_trace = trace
  local code, result = built.gen(source, env, nil, "tl")
  assert(code ~= nil and #result.syntax_errors == 0, "the program did not parse")
  assert(#result.type_errors == 0, result.type_errors[1] ~= nil and result.type_errors[1].msg or "")
  local keys: {string} = {}
  for _, entry in ipairs(trace) do
    local found, key = entry:match("^(.-)=(.*)$")
    if found == name then
      keys[#keys + 1] = key
    end
  end
  return keys, trace
end

--- The different keys among `keys`.
local function distinct(keys: {string}): {string}
  local seen: {string:boolean} = {}
  local out: {string} = {}
  for _, key in ipairs(keys) do
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = key
    end
  end
  return out
end

--- Asserts the keys are `count` reads of one binding, a key that is a counter.
local function one_binding(keys: {string}, count: integer, what: string)
  assert(#keys >= count, what .. ": read " .. #keys .. " times, not " .. count)
  for _, key in ipairs(keys) do
    assert(key == keys[1], what .. ": keys " .. table.concat(keys, ","))
    assert(key ~= "nil" and key ~= "", what .. ": no key")
  end
end

local function test_every_kind_of_binding_has_a_key()
  local source = [[
local record R
  n: integer
end
function R.method(self: R): integer
  return self.n
end
global gl: integer = 1
local function lf(): integer
  return 1
end
local function f(param: integer | nil, ...: integer): integer
  local total = 0
  for i = 1, 3 do
    total = total + i
  end
  for k, v in ipairs({ 1, 2 }) do
    total = total + k + v
  end
  for _, w in pairs({ a = 1 }) do
    total = total + w
  end
  local va = ...
  return total + gl + lf() + va + (param or 0)
end
local inner: R = { n = 1 }
return f(R.method(inner))
]]
  local _, trace = keys_of(source, "")
  local names: {string} = { "self", "gl", "lf", "param", "i", "k", "v", "w", "total", "va", "f", "inner", "R" }
  for _, name in ipairs(names) do
    local keys = keys_of(source, name)
    assert(#keys > 0, name .. " was never found")
    for _, key in ipairs(keys) do
      assert(key ~= "nil" and key ~= "", name .. " has no key")
    end
  end
  for _, entry in ipairs(trace) do
    assert(not entry:find("=nil$"), "a variable without a key: " .. entry)
  end
end

local function test_a_binding_keeps_its_key_where_it_is_narrowed()
  local keys = keys_of([[
local function f(p: integer | nil): integer
  local before = p
  if p ~= nil then
    return p + 1
  end
  return before or 0
end
return f(1)
]], "p")
  one_binding(keys, 3, "p")
end

local function test_a_binding_keeps_its_key_where_it_is_widened()
  local keys = keys_of([[
local function f(p: integer | nil): integer
  if p ~= nil then
    p = nil
  end
  local a = p
  return a or 0
end
return f(1)
]], "p")
  one_binding(keys, 3, "p")
end

local function test_a_binding_narrowed_in_a_scope_of_its_own_keeps_its_key()
  local keys = keys_of([[
local function f(p: integer | nil): integer
  while p == nil do
    p = 1
  end
  for _ = 1, 2 do
    if p ~= nil then
      local q = p
      p = nil
      p = q
    end
  end
  return p or 0
end
return f(nil)
]], "p")
  one_binding(keys, 5, "p")
end

local function test_a_localized_variable_has_a_key_of_its_own()
  local keys = keys_of([[
local x: integer | nil = 1
local function f(): integer
  local y = x
  local x = x
  if x ~= nil then
    return x + 1
  end
  return y or 0
end
return f()
]], "x")
  -- The outer binding, read before the localized one and by its initializer,
  -- and the localized one, read after: two keys, the later reads one.
  assert(#distinct(keys) == 2, table.concat(keys, ","))
  assert(keys[#keys] == keys[#keys - 1] and keys[#keys] ~= keys[1], table.concat(keys, ","))
end

local function test_a_shadowing_local_has_a_key_of_its_own()
  local keys = keys_of([[
local a = 1
do
  local a = 2
  a = a + 1
end
return a
]], "a")
  assert(#distinct(keys) == 2, table.concat(keys, ","))
  assert(keys[1] ~= keys[2] and keys[2] == keys[3] and keys[1] == keys[4], table.concat(keys, ","))
end

local function test_an_inferred_empty_table_keeps_its_key()
  local keys = keys_of([[
local t = {}
t.a = 1
local u = {}
u[1] = 2
return t.a + u[1]
]], "t")
  one_binding(keys, 2, "t")
  local others = keys_of([[
local u = {}
u[1] = 2
return u[1]
]], "u")
  one_binding(others, 2, "u")
end
