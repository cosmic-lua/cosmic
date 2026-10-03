--- Operation sequences whose later draws depend on earlier operations.
--- Generation and checking each start with a fresh model; shrinking
--- replays the generator, so removing an operation rebuilds its dependents.
local Fuzz = require("build.fuzz")
local Strategy = require("build.fuzz_strategy")

local record Stateful
end

--- A bounded list that rebuilds its model for every generation or replay.
--- `advance` models an operation's effect, including an expected refusal.
--- The caller's `draw` decides whether to choose valid or invalid actions.
function Stateful.sequence<S, O>(fresh: function(): S,
    draw: function(Fuzz.Source, S): O, advance: function(S, O),
    max: integer): Strategy.Gen<{O}>
  return function(src: Fuzz.Source): {O}
    local state = fresh()
    return Strategy.list(function(source: Fuzz.Source): O
      local operation = draw(source, state)
      advance(state, operation)
      return operation
    end, max)(src)
  end
end

--- Applies each operation and checks the invariant after it, including
--- expected refusals. A failure includes the operation prefix that led
--- to it. `step` returns false only for a mismatch, not an expected error.
--- The caller owns setup and cleanup and must supply a fresh state.
function Stateful.check<S, O>(operations: {O}, state: S,
    step: function(S, O): boolean, string, invariant: function(S): boolean, string,
    describe: function(O): string): boolean, string
  local trace: {string} = {}
  local held, why = invariant(state)
  if not held then return false, why .. "\n  before any operation" end
  for i, operation in ipairs(operations) do
    trace[#trace + 1] = ("  %d. %s"):format(i, describe(operation))
    held, why = step(state, operation)
    if held then held, why = invariant(state) end
    if not held then return false, why .. "\n" .. table.concat(trace, "\n") end
  end
  return true, ""
end

return Stateful
