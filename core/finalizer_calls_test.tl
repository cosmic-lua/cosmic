--- Where the patched VM runs a finalizer: at a Lua function's call of a Lua function, or of a C function that the
--- checker does not count as running no code of the program (patch/lua/19-finalizers-at-calls-gc.txt and
--- 31-finalizers-at-c-calls-run-call.txt), never inside a collection. Each chunk below arms finalizable tables, then loops
--- over calls of C functions alone, allocating enough to finish collections, and reads the count of finalizers that ran
--- before it calls anything else.
local Test = require("cosmic.test")

Test.policy{}

--- Runs `body` after arming 1000 finalizable tables, and answers how many finalizers ran in it: the arming loop's own calls
--- of `setmetatable` may run some, which are not counted.
local function finalized_during(body: string): integer
  local chunk = assert(load([[
    local ran = 0
    local mt = { __gc = function() ran = ran + 1 end }
    for _ = 1, 1000 do setmetatable({}, mt) end
    local before = ran
    ]] .. body .. [[
    local seen = ran - before
    return seen
  ]], "=finalizer_calls", "t"))
  local seen = chunk()
  assert(seen is integer, "the chunk answered no count")
  return seen
end

local function test_a_loop_of_calls_of_a_c_function_runs_the_pending_finalizers()
  -- `setmetatable` runs code of the program (a `__gc` it is given), so its call may run a finalizer: a loop of nothing
  -- else gives back the memory of what it made.
  local seen = finalized_during([[for _ = 1, 200000 do setmetatable({}, mt) end]])
  assert(seen > 0, "no finalizer ran in a loop of setmetatable calls")
end

local function test_a_loop_of_calls_the_checker_counts_inert_runs_none()
  -- `string.rep` and `math.max` run no code of the program, so no finalizer runs at their calls, however much they
  -- allocate (lang/check.tl's [`Tests.inert_callee`]).
  local seen = finalized_during([[
    for i = 1, 200000 do local s = string.rep("x", 64 + i % 7); s = string.rep(s, 2); math.max(i, 1) end
  ]])
  assert(seen == 0, tostring(seen) .. " finalizers ran at calls of inert C functions")
end
