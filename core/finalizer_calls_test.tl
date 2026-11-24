--- Where the patched VM runs a finalizer: at a Lua function's call of a Lua function, or of a C function that the
--- checker does not count as running no code of the program (patch/lua/19-finalizers-at-calls-gc.txt and
--- 31-finalizers-at-c-calls-run-call.txt), never inside a collection. Each chunk below arms finalizable tables, then loops
--- over calls of C functions alone, allocating enough to finish collections, and reads the count of finalizers that ran
--- before it calls anything else.
local Test = require("cosmic.test")

Test.policy{}

--- Runs `body` after arming 1000 finalizable tables, and returns how many finalizers ran in it: the arming loop's own calls
--- of `setmetatable` may run some, which are not counted.
local function finalized_during(body: string): integer
  local chunk = assert(load([[
    local random = (...).random
    local ran = 0
    local mt = { __gc = function() ran = ran + 1 end }
    for _ = 1, 1000 do setmetatable({}, mt) end
    local before = ran
    ]] .. body .. [[
    local seen = ran - before
    return seen
  ]], "=finalizer_calls", "t"))
  -- `math` is given for `math.random`, which the environment `load` gives a chunk leaves out.
  local seen = chunk(math)
  assert(seen is integer, "the chunk returned no count")
  return seen
end

local function test_a_loop_of_calls_of_a_c_function_runs_the_pending_finalizers()
  -- `setmetatable` runs code of the program (a `__gc` it is given), so its call may run a finalizer: a loop of nothing
  -- else gives back the memory of what it made.
  local seen = finalized_during([[for _ = 1, 200000 do setmetatable({}, mt) end]])
  assert(seen > 0, "no finalizer ran in a loop of setmetatable calls")
end

local function test_a_loop_of_calls_the_checker_counts_inert_runs_none()
  -- `string.rep` (also as a method), `math.max` and `math.random` (a C closure) run no code of the
  -- program, so no finalizer runs at their calls, however much they
  -- allocate (lang/check.tl's [`Tests.inert_callee`]).
  local seen = finalized_during([[
    for i = 1, 200000 do
      local s = string.rep("x", 64 + i % 7); s = s:rep(2); math.max(i, random(3))
    end
  ]])
  assert(seen == 0, tostring(seen) .. " finalizers ran at calls of inert C functions")
end

local function test_a_loop_of_calls_of_a_value_whose_call_is_a_c_function_runs_them()
  local seen = finalized_during([[
    local inner = setmetatable({}, { __call = rawequal })
    local callable = setmetatable({}, { __call = inner })
    for _ = 1, 200000 do local s = string.rep("x", 100); callable(s); inner(s) end
  ]])
  assert(seen > 0, "no finalizer ran in a loop of calls of a value whose __call is rawequal")
end

local function test_a_generic_for_over_a_c_iterator_runs_them()
  -- `next` is the iterator, called at each step; the body calls only inert functions.
  local seen = finalized_during([[
    local t = {}
    for i = 1, 200000 do t[i] = true end
    for _ in next, t do local s = string.rep("x", 100); s = s:upper() end
  ]])
  assert(seen > 0, "no finalizer ran in a generic for over next")
end
