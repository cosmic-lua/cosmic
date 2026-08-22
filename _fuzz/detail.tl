--- Internals shared by _fuzz.driver and _fuzz.corpus.
--- A leaf module: it imports nothing from either, which is what lets
--- corpus.tl reach these bodies while driver.tl requires corpus.tl.
--- Nothing here is declared twice — the budget message a caught throw
--- is compared against, the integer-env reader every FUZZ_* knob goes
--- through, and the formatter that turns one pcall result into the
--- suffix a failure message ends with.

local env = require("cosmic.env")

--- What the budget hook throws. Raised with level 0, so a caught value
--- equal to this string IS a budget failure, not a property throw.
local BUDGET_MESSAGE = "_fuzz.driver: instruction budget exceeded"

--- Read an integer from the environment, falling back when unset or
--- unparseable.
--- @param name string The environment variable to read
--- @param fallback integer The value to use when it is absent or not a number
--- @return integer The parsed value, or `fallback`
local function env_integer(name: string, fallback: integer): integer
  local raw = env.get(name)
  if not raw then
    return fallback
  end
  local parsed = tonumber(raw)
  if not parsed then
    return fallback
  end
  return math.floor(parsed)
end

--- Turn one pcall of a property into the suffix its failure message
--- ends with: the budget report when the hook threw, the thrown text
--- when anything else did, and what the property itself reported when
--- it merely returned false.
--- @param ok boolean The pcall status
--- @param held any What the property returned, or the thrown value
--- @param detail any What the property reported alongside a false return
--- @param budget integer The VM-instruction budget in force
--- @return string The failure suffix
local function detail_of(ok: boolean, held: any, detail: any, budget: integer): string
  if ok then
    return tostring(detail or "no detail")
  end
  local thrown = tostring(held)
  if thrown == BUDGET_MESSAGE then
    return ("budget=%d exceeded"):format(budget)
  end
  return "threw: " .. thrown
end

local record DetailModule
  BUDGET_MESSAGE: string
  env_integer: function(name: string, fallback: integer): integer
  detail_of: function(ok: boolean, held: any, detail: any, budget: integer): string
end

local M: DetailModule = {
  BUDGET_MESSAGE = BUDGET_MESSAGE,
  env_integer = env_integer,
  detail_of = detail_of,
}

return M
