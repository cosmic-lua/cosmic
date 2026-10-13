--- The checker's shadow facts (`self.facts`, checker/facts.tl) beside the
--- narrowing that decides every verdict: with [`Env.shadow_mismatches`] set,
--- every read of a local or a field compares the type the facts give with
--- the type the narrowing gave, and a disagreement is recorded. These tests
--- run the programs that put narrowing at risk with the comparison on and
--- hold the disagreements to none.
---
--- This is the gate of step 7a's shadow mode: when a read switches to the
--- facts, this test is what says the facts were right. A disagreement that
--- the old narrowing is to blame for is not allowed: it is pinned as the
--- exact mismatch it gives, with a TODO naming the fix of the old narrowing
--- it waits on, until that fix merges and the pin goes.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local programs = require("build.checker_programs")
local teal = require("build.teal")
local verdicts = require("build.checker_verdicts")
local type compiler = require("build.compiler")

Test.policy{ grants = {
  { path = "testdata/fuzz/checker-total", letters = "r" },
  { path = "testdata/fuzz/checker-sound", letters = "r" },
} }

local built = { value = nil as compiler | nil }

--- The tree's checker, loaded once.
local function checker(): compiler
  if built.value == nil then
    built.value = assert(teal.load(true))
  end
  return built.value
end

--- The disagreements of `text` checked as a program of its own, and how
--- many reads were compared.
local function mismatches(file: string, text: string): {string}, integer, integer
  local env = verdicts.environment(checker())
  local found: {string} = {}
  env.shadow_mismatches = found
  local ok, why = pcall(checker().gen, text, env, nil, "tl")
  assert(ok, file .. ": the checker raised: " .. tostring(why))
  local out: {string} = {}
  for _, line in ipairs(found) do
    out[#out + 1] = file .. ":" .. line
  end
  return out, env.shadow_reads or 0, env.shadow_field_reads or 0
end

--- The programs the checks below draw their cases from: one narrowing shape
--- each, written so that a mirror point of the shadow (a guard, an
--- assignment, a call, a branch that leaves, a loop, a function body, a
--- label) is the only thing that keeps the two apart.
local cases: {string:string} = {
  guard = [[
local record R
  f: string | nil
end
local function g(r: R, x: string | nil): string
  if x then return x end
  if r.f then return r.f end
  return ""
end
return g
]],
  early_return = [[
local function g(x: string | nil): integer
  if x == nil then
    return 0
  end
  return #x
end
return g
]],
  call_drops_field = [[
local record R
  a: integer | nil
end
local function maybe(): integer | nil return nil end
local function g(r: R): integer
  if r.a == nil then return 0 end
  maybe()
  return r.a or 0
end
return g
]],
  call_in_condition_before_elseif = [[
local record R
  b: integer | nil
end
local s: R = { b = 2 }
local function maybe(): integer | nil
  return nil
end
if s.b ~= nil then
  if maybe() and s.b == nil then
  elseif s.b == nil then
  end
end
]],
  field_write_through_reference = [[
local record R
  a: integer | nil
end
local function g(r: R, q: R): integer
  if r.a == nil then return 0 end
  q.a = nil
  return r.a or 0
end
return g
]],
  assignment_widens = [[
local function g(x: integer | nil): integer
  if x == nil then x = 1 end
  local y: integer | nil = nil
  if x > 0 then y = x end
  return y or 0
end
return g
]],
  branch_assigns = [[
local function g(c: boolean, x: integer | nil): integer
  if x == nil then return 0 end
  if c then x = nil end
  return x or 0
end
return g
]],
  function_declaration_widens_locals = [[
local record R
  a: integer | nil
end
local function g(r: R, x: integer | nil): integer
  if x == nil then return 0 end
  if r.a == nil then return 0 end
  local function inner(): integer return r.a or 0 end
  return x + inner()
end
return g
]],
  function_body_keeps_fixed_local = [[
local function g(x: integer | nil): (function(): integer)
  if x == nil then
    return function(): integer return 0 end
  end
  return function(): integer return x + 1 end
end
return g
]],
  loop_assigned_local = [[
local function g(n: integer, x: integer | nil): integer
  if x == nil then return 0 end
  local total = 0
  for i = 1, n do
    total = total + x
    if i == 2 then x = nil; x = 1 end
  end
  while x ~= nil and total < 10 do
    total = total + x
    x = nil
  end
  return total
end
return g
]],
  loop_break_and_continue = [[
local function maybe(): integer | nil return nil end
local function g(n: integer): integer
  local total = 0
  for i = 1, n do
    local v = maybe()
    if v == nil then goto continue end
    total = total + v
    if total > 10 then break end
    ::continue::
  end
  return total
end
return g
]],
  never_call = [[
local function g(x: integer | nil): integer
  if x == nil then
    error("no x")
  end
  return x
end
return g
]],
  and_or = [[
local record R
  a: integer | nil
end
local function g(r: R, x: string | nil): integer
  local n = x and #x or 0
  return (r.a and r.a + 1) or n
end
return g
]],
  assert_call = [[
local function g(x: string | nil): integer
  assert(x)
  return #x
end
return g
]],
  local_x_is_x = [[
local function g(x: string | nil): integer
  if x == nil then return 0 end
  local x = x
  return #x
end
return g
]],
  local_x_is_x_carries_fields = [[
local record R
  a: integer | nil
end
local function g(t: R): integer
  if t.a then
    local t = t
    return t.a + 1
  end
  return 0
end
return g
]],
  new_variable_of_a_name = [[
local record R
  a: integer | nil
end
local function g(t: R, s: R): integer
  if t.a then
    local t = s
    return t.a + 1
  end
  return 0
end
return g
]],
  for_variable_of_a_name = [[
local record R
  a: integer | nil
end
local function g(t: R, rs: {R}): integer
  local n = 0
  if t.a then
    for _, t in ipairs(rs) do
      n = n + t.a
    end
  end
  return n
end
return g
]],
  deep_field_new_variable = [[
local record R
  a: integer | nil
  r: R | nil
end
local function g(t: R, s: R): integer
  if t.r and t.r.a then
    local t = s
    if t.r then
      return t.r.a + 1
    end
  end
  return 0
end
return g
]],
  redeclared_after_early_return = [[
local record R
  a: integer | nil
end
local function g(t: R, s: R): integer
  if not t.a then return 0 end
  local t = s
  return t.a + 1
end
return g
]],
  local_shadows_global_field = [[
global record GR
  a: integer | nil
end
local function g(): integer
  if GR.a then
    local GR = { a = nil as integer | nil }
    return GR.a or 0
  end
  return 0
end
return g
]],
  call_after_inner_scope = [[
local record R
   a: number | nil
end
local function maybe() end
local function f(q: R, p: R): number
  if q.a then
    do
      local q = p
      print(q)
    end
    maybe()
    return q.a + 1
  end
  return 0
end
print(f)
]],
  alias_inner_scope = [[
local record R
   a: number | nil
end
local function f(q: R, p: R): number
  if q.a then
    local outer = q
    if p then
      local q = p
      print(q)
    end
    outer.a = nil
    return q.a + 1
  end
  return 0
end
print(f)
]],
  method_after_inner_scope = [[
local record R
   a: number | nil
   ab: number | nil
   r: R | nil
   metamethod __add: function(R, R): R
   m: function(R)
end
local function maybe(): number | nil return nil end
local function f(q: R, p: R): number
  if q.a then
    do local q = p print(q) end
    p:m()
    return q.a + 1
  end
  return 0
end
print(f, maybe)
]],
  metamethod_after_inner_scope = [[
local record R
   a: number | nil
   ab: number | nil
   r: R | nil
   metamethod __add: function(R, R): R
   m: function(R)
end
local function maybe(): number | nil return nil end
local function f(q: R, p: R): number
  if q.a then
    do local q = p print(q) end
    local s = p + p
    return q.a + 1 + (s.a or 0)
  end
  return 0
end
print(f, maybe)
]],
  string_index_write_after_inner_scope = [[
local record R
   a: number | nil
   ab: number | nil
   r: R | nil
   metamethod __add: function(R, R): R
   m: function(R)
end
local function maybe(): number | nil return nil end
local function f(q: R, p: R): number
  if q.a then
    do local q = p print(q) end
    local o = q
    o["a"] = nil
    return q.a + 1
  end
  return 0
end
print(f, maybe)
]],
  index_write_after_inner_scope = [[
local record R
   a: number | nil
   ab: number | nil
   r: R | nil
   metamethod __add: function(R, R): R
   m: function(R)
end
local function maybe(): number | nil return nil end
local function f(q: R, p: R, k: string): number
  if q.a then
    do local q = p print(q) end
    local m = q as {string:any}
    m[k] = nil
    return q.a + 1
  end
  return 0
end
print(f, maybe)
]],
  closure_write_after_inner_scope = [[
local record R
   a: number | nil
   ab: number | nil
   r: R | nil
   metamethod __add: function(R, R): R
   m: function(R)
end
local function maybe(): number | nil return nil end
local function f(q: R, p: R): number
  if q.a then
    do local q = p print(q) end
    local clear = function() q.a = nil end
    clear()
    return q.a + 1
  end
  return 0
end
print(f, maybe)
]],
  loop_call_after_inner_scope = [[
local record R
   a: number | nil
   ab: number | nil
   r: R | nil
   metamethod __add: function(R, R): R
   m: function(R)
end
local function maybe(): number | nil return nil end
local function f(q: R, p: R): number
  if q.a then
    for _, q in ipairs({p}) do print(q) end
    maybe()
    return q.a + 1
  end
  return 0
end
print(f, maybe)
]],
  else_call_after_binding = [[
local record R
   a: number | nil
   ab: number | nil
   r: R | nil
   metamethod __add: function(R, R): R
   m: function(R)
end
local function maybe(): number | nil return nil end
local function f(q: R, p: R, c: boolean): number
  if q.a then
    if c then
      local q = p
      print(q)
    else
      maybe()
      return q.a + 1
    end
  end
  return 0
end
print(f, maybe)
]],
  nested_field_after_inner_scope = [[
local record R
   a: number | nil
   ab: number | nil
   r: R | nil
   metamethod __add: function(R, R): R
   m: function(R)
end
local function maybe(): number | nil return nil end
local function f(q: R, p: R): number
  if q.r and q.r.a then
    do local q = p print(q) end
    local o = q.r
    o.a = nil
    return q.r.a + 1
  end
  return 0
end
print(f, maybe)
]],
  two_fields_call_after_inner_scope = [[
local record R
  a: number | nil
end
local function maybe() end
local function f(q: R, p: R): number
  if q.a then
    do local q = p print(q) end
    maybe()
    return (q.a or 0) + 1
  end
  return 0
end
local function g(q: R, p: R, s: R): number
  if q.a and s.a then
    do local q = p print(q) end
    maybe()
    return (q.a or 0) + 1
  end
  return 0
end
print(f, g)
]],
  field_prefix_not_dropped = [[
local record R
   a: number | nil
   ab: number | nil
   r: R | nil
   metamethod __add: function(R, R): R
   m: function(R)
end
local function maybe(): number | nil return nil end
local function f(q: R): number
  if q.a and q.ab then
    q.a = 1
    return q.ab + 1
  end
  return 0
end
print(f, maybe)
]],
  shadowed_name = [[
local function g(x: string | nil): integer
  if x == nil then return 0 end
  do
    local x: integer | nil = nil
    if x then return x end
  end
  return #x
end
return g
]],
}

local function test_each_narrowing_shape_agrees_with_the_facts()
  local names: {string} = {}
  for name in pairs(cases) do
    names[#names + 1] = name
  end
  table.sort(names)
  local reads, fields = 0, 0
  for _, name in ipairs(names) do
    local found, n, f = mismatches(name, cases[name])
    reads = reads + n
    fields = fields + f
    assert(#found == 0, table.concat(found, "\n"))
  end
  assert(reads > 0, "no read was compared")
  -- A positive control: the shapes read fields (`r.a`, `r.f`, `t.a`), and a
  -- comparison of those that was skipped would leave this at none.
  assert(fields >= 8, "only " .. tostring(fields) .. " field reads were compared")
end

-- The old narrowing drops, for good, the field facts of a name where a new
-- plain variable of the name is declared (not `local t = t`), and not
-- when that variable's scope ends. The facts are keyed by variable and keep
-- the outer `t.a` for the code that reads it again: after the inner scope
-- ends, after a loop whose variable is a new `t`, and in the `else` beside
-- the branch that declared it. Each program is pinned as the one mismatch it
-- gives: the old narrowing is the more conservative, and the facts are right.
-- TODO: pin these to no mismatch once the reads switch to the facts (step 7a's
-- PR 3), which gives the outer fact back where the old narrowing dropped it
-- and moves the verdict of each program, which is triaged there.
local old_drops_more: {{string}} = {
  { "after_inner_scope", [[
local record R
  a: integer | nil
end
local function g(t: R): integer
  if t.a then
    do
      local t: R = { a = nil }
      print(t.a)
    end
    return t.a + 1
  end
  return 0
end
return g
]],
    "10:13 t.a: shadow integer (inferred at :5:7), old none" },
  { "loop_after_binding", [[
local record R
  a: integer | nil
end
local function g(t: R, rs: {R}): integer
  local n = 0
  if t.a then
    for _, t in ipairs(rs) do
      n = n + 1
    end
    return t.a + n
  end
  return n
end
return g
]],
    "10:13 t.a: shadow integer (inferred at :6:7), old none" },
  { "sibling_else", [[
local record R
  a: integer | nil
end
local function g(t: R, s: R, c: boolean): integer
  if t.a then
    if c then
      local t = s
      print(t)
    else
      return t.a + 1
    end
  end
  return 0
end
return g
]],
    "10:15 t.a: shadow integer (inferred at :5:7), old none" },
}

local function test_old_narrowing_drops_field_facts_the_facts_keep()
  for _, case in ipairs(old_drops_more) do
    local name, text = case[1], case[2]
    local found, _, fields = mismatches(name .. ".tl", text)
    assert(fields > 0, name .. ": no field read was compared")
    local expected: {string} = {}
    for i = 3, #case do
      expected[#expected + 1] = name .. ".tl:" .. case[i]
    end
    assert(table.concat(found, "\n") == table.concat(expected, "\n"),
      name .. ": " .. table.concat(found, "\n"))
  end
end

--- The files of the fuzz corpora.
local function corpus(directory: string): {string:string}
  local out: {string:string} = {}
  local names = assert(Fs.walk(directory))
  for _, relative in ipairs(names) do
    local text = Fs.read(directory .. "/" .. relative)
    if text ~= nil then
      out[directory .. "/" .. relative] = text
    end
  end
  return out
end

local function test_the_fuzz_corpora_agree_with_the_facts()
  local reads = 0
  local checked = 0
  for _, directory in ipairs({ "testdata/fuzz/checker-total", "testdata/fuzz/checker-sound" }) do
    local files = corpus(directory)
    local names: {string} = {}
    for name in pairs(files) do
      names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
      local found, n = mismatches(name, files[name])
      reads = reads + n
      checked = checked + 1
      assert(#found == 0, table.concat(found, "\n"))
    end
  end
  assert(checked > 0 and reads > 0, "no corpus read was compared")
end

local function test_drawn_programs_agree_with_the_facts()
  local reads = 0
  for _, kind in ipairs({ "total", "sound" }) do
    for seed = 1, 2 do
      for n, text in ipairs(programs.drawn(kind, seed, 15)) do
        local found, count = mismatches(kind .. "-" .. seed .. "-" .. n, text)
        reads = reads + count
        assert(#found == 0, table.concat(found, "\n"))
      end
    end
  end
  assert(reads > 0, "no drawn read was compared")
end

local function test_reads_are_compared_when_the_log_is_set()
  local env = verdicts.environment(checker())
  local found: {string} = {}
  env.shadow_mismatches = found
  local code = checker().gen("local x: integer | nil = 1\nif x then print(x) end\n", env, nil, "tl")
  assert(code ~= nil and (env.shadow_reads or 0) >= 2 and #found == 0)
end

--- With the log unset the checker keeps no shadow: nothing is counted or
--- compared, and what it says is what it says with the log set.
local function test_the_shadow_is_not_kept_when_the_log_is_not_set()
  local text = [[
local record R
  a: integer | nil
end
local function g(r: R, x: integer | nil): integer
  if r.a == nil or x == nil then return 0 end
  local function inner(): integer return 1 end
  return r.a + x + inner()
end
return g
]]
  local off = verdicts.environment(checker())
  local _, off_result = checker().gen(text, off, nil, "tl")
  assert(off.shadow_reads == nil and off.shadow_field_reads == nil and off.shadow_mismatches == nil)
  local on = verdicts.environment(checker())
  on.shadow_mismatches = {}
  local _, on_result = checker().gen(text, on, nil, "tl")
  assert((on.shadow_reads or 0) > 0 and (on.shadow_field_reads or 0) > 0)
  assert(#off_result.type_errors == #on_result.type_errors and #off_result.warnings == #on_result.warnings)
end

-- A disagreement the old narrowing is to blame for, pinned as the mismatch
-- it gives, so that fixing the old narrowing fails the test and takes the pin
-- away. It is no fault of the shadow: the facts are the model's.

--- The old narrowing widens by name, and `local x = x` is a name of two
--- variables: a widening of the outer one reaches the inner one (to a type
--- it was not declared with), and spares the outer one when the inner one
--- is in the way. The facts are keyed by variable.
-- TODO: pin this to no mismatch once the old narrowing is deleted (the PR that
-- removes `specialize_var` and `widen_in_scope`), or the reads switch to the
-- facts and the verdict this moves is triaged.
local function test_old_narrowing_widens_the_wrong_variable_of_a_localized_name()
  local found = mismatches("localized.tl", [[
local function f(x1: integer | nil): integer
  if x1 then
    local x1 = x1
    local function p() end
    p()
    if type(x1) == "number" then
      return 1
    end
  end
  return 0
end
return f
]])
  assert(table.concat(found, "\n") == table.concat({
    "localized.tl:6:13 x1: shadow integer (inferred at :2:6), old integer | nil",
    "localized.tl:6:17 x1: shadow integer (inferred at :2:6), old integer | nil",
  }, "\n"), table.concat(found, "\n"))
end
