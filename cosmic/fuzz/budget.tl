--- Per-check instruction budgets, including active coverage collection.
local DEFAULT_BUDGET = 50000000

--- What the Lua budget hook throws. Raised with level 0, so a caught
--- value equal to this string IS a budget failure, not a property throw.
local BUDGET_MESSAGE = "cosmic.fuzz: instruction budget exceeded"

--- What the C collector's own budget hook (cosmo.cov.budget) throws.
local COLLECTOR_BUDGET_MESSAGE = "cosmo.cov: instruction budget exceeded"

--- The runtime's C instruction-budget/line-hit collector. Type-only:
--- the generated declaration is the one description of the binding.
local type CCov = require("cosmo.cov")

--- Detected through package.preload, as cosmic/coverage/init.tl's
--- find_ccov does, so a runtime without the binding never requires it.
--- @return CCov | nil The C collector, or nil on a runtime without one
local function find_ccov(): CCov | nil
  if package.preload["cosmo.cov"] == nil then
    return nil
  end
  local req = require as function(string): any -- cast: bypass static module resolution
  return req("cosmo.cov") as CCov -- cast: dynamic require returns any
end

local ccov: CCov | nil = find_ccov()

--- Which mechanism last armed the budget, so disarm_budget clears the
--- right one. nil when neither is currently armed.
local armed_via: string = nil

--- Arm the instruction budget: the collector's own budget first (it
--- succeeds exactly when collection is running on this thread), else
--- the VM hook, when the VM's one hook slot is free.
--- @param budget integer VM instructions until the budget fails the call
--- @return boolean True when a budget was armed
local function arm_budget(budget: integer): boolean
  if ccov and ccov.budget(budget) then
    armed_via = "collector"
    return true
  end
  if debug.gethook() ~= nil then
    return false
  end
  debug.sethook(function() error(BUDGET_MESSAGE, 0) end, "", budget) -- throws: hook interrupts checked callback
  armed_via = "hook"
  return true
end

--- Turn the armed budget off, whichever mechanism armed it. tl's
--- sethook declaration has no argless clearing form; an empty mask
--- with no count is the same off state.
local function disarm_budget()
  if armed_via == "collector" and ccov then
    ccov.budget(0)
  else
    debug.sethook(function() end, "")
  end
  armed_via = nil
end

local record Attempt
  held: boolean
  kind: string
  message: string
end

local function attempt(
    check: function(input: string): boolean, string,
    input: string,
    budget: integer
  ): Attempt
  local armed = arm_budget(budget)
  local ok, held, why = pcall(check, input)
  if armed then
    disarm_budget()
  end
  if not ok then
    local thrown = tostring(held)
    if thrown == BUDGET_MESSAGE or thrown == COLLECTOR_BUDGET_MESSAGE then
      return {held = false, kind = "budget", message = ("budget=%d exceeded"):format(budget)}
    end
    return {held = false, kind = "throw", message = "threw: " .. thrown}
  end
  if not held then
    return {held = false, kind = "assertion", message = tostring(why or "no detail")}
  end
  return {held = true, kind = "", message = ""}
end

return {attempt = attempt, default = DEFAULT_BUDGET}
