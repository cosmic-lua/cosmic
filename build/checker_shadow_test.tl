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

-- The old narrowing holds a field fact under the name of the place (`t.a`),
-- so it survives a new variable of the name `t`: a `local t = s`, a `for`
-- variable, a `local t` of an inner `do` (after which it reads the outer
-- `t.a` as narrowed even where the fact was dropped), a redeclaration after
-- an early return, and a local that shadows a global. That is unsound, and the
-- facts, keyed by variable, hold none. Each program is pinned as the
-- mismatches it gives; the `r05` one gives two, because the old narrowing
-- takes the narrowed `t.r` for the new `t` and builds no guard for the test
-- of it, so the facts have no guard to narrow by either.
-- TODO: pin all of these to no mismatch once the old narrowing keys field
-- facts by variable, the fix on main that makes a new variable of a name
-- drop the fields narrowed under it.
local old_field_facts: {{string}} = {
  { "r01", [[
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
    "7:13 t.a: shadow none, old integer (inferred at :5:7)" },
  { "r03", [[
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
    "8:16 t.a: shadow none, old integer (inferred at :6:7)" },
  { "r05", [[
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
    "8:9 t.r: shadow none, old R (inferred at :6:10)", "9:15 t.r: shadow none, old R (inferred at :6:10)" },
  { "u01", [[
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
    "7:11 t.a: shadow none, old integer (inferred at :5:3)" },
  { "u05", [[
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
    "7:14 GR.a: shadow none, old integer (inferred at :5:8)" },
  { "u06", [[
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
    "8:14 t.a: shadow none, old integer (inferred at :5:7)" },
}

local function test_old_narrowing_keeps_field_facts_of_a_name_across_variables()
  for _, case in ipairs(old_field_facts) do
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

local function test_no_read_is_compared_when_the_log_is_not_set()
  local env = verdicts.environment(checker())
  local code = checker().gen("local x: integer | nil = 1\nif x then print(x) end\n", env, nil, "tl")
  assert(code ~= nil and env.shadow_reads == nil and env.shadow_mismatches == nil)
end

-- The two disagreements the old narrowing is to blame for, each pinned as
-- the one mismatch it gives, so that fixing the old narrowing fails the test
-- and takes the pin away. Neither is a fault of the shadow: the facts are
-- the model's.

--- An assignment inside a test of the place itself leaves the narrowing
--- outside it: after `ch = "z"`, `ch` is still `"'" | "!"` to the old
--- narrowing, which is wrong. The facts widen it.
-- TODO: pin this to no mismatch once the old narrowing widens a place an
-- inner test of it re-narrowed, which a PR of its own makes before the PR
-- that switches reads to the facts.
local function test_old_narrowing_keeps_a_place_assigned_under_its_own_test()
  local found = mismatches("assigned.tl", [[
local function f(src: string): integer
  local ch = src:sub(1, 1)
  if ch == "'" or ch == "!" then
    if ch == "'" then
      ch = "z"
    end
    local n: integer = ch
  end
  return 1
end
return f
]])
  assert(#found == 1 and found[1]:find("ch: shadow string, old", 1, true) ~= nil, table.concat(found, "\n"))
end

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
  assert(#found >= 1, "the old narrowing no longer widens the localized variable")
  for _, line in ipairs(found) do
    assert(line:find("x1: shadow integer", 1, true) ~= nil, line)
  end
end
