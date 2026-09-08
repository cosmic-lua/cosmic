--- Configurable boundaries for proven direct imports.
---
--- The service never treats missing provenance as permission. Direct immutable
--- require bindings are checked against the policy; dynamic or modified import
--- bindings make the result incomplete with an explicit reason.
local bindings_mod = require("cosmic.ast.bindings")
local node_mod = require("cosmic.ast.node")

local type Bindings = bindings_mod.Bindings
local type BindingId = bindings_mod.BindingId
local type Node = node_mod.Node

local record Policy
  --- Allowed exact module names or namespace prefixes (`cosmic.ast` includes
  --- `cosmic.ast.source`). Nil means allow unless denied; an empty list allows none.
  allow: {string} | nil
  --- Denied exact module names or namespace prefixes. Deny takes precedence.
  deny: {string} | nil
end

local record Violation
  binding_id: BindingId
  declaration: Node
  module: string
  message: string
end

local record Unknown
  binding_id: BindingId
  declaration: Node
  reason: string
end

local record Result
  violations: {Violation}
  unknown: {Unknown}
  complete: boolean
end

local function matches(module: string, prefix: string): boolean
  return module == prefix or module:sub(1, #prefix + 1) == prefix .. "."
end

local function matches_any(module: string, prefixes: {string}): boolean
  for _, prefix in ipairs(prefixes) do
    if matches(module, prefix) then
      return true
    end
  end
  return false
end

--- Check every direct-import binding whose provenance analysis discovered.
--- `complete=false` means at least one import-shaped binding was dynamic,
--- reassigned, mutated, or ambiguously paired with declaration values.
local function check(bindings: Bindings, policy: Policy): Result
  local result: Result = {violations = {}, unknown = {}, complete = true}
  for _, binding in ipairs(bindings.all) do
    if binding.is_import then
      local module = binding.origin
      if not module then
        result.complete = false
        table.insert(result.unknown, {
            binding_id = binding.id,
            declaration = binding.declaration,
            reason = binding.origin_reason or "import origin is unknown",
          })
      else
        local denied = policy.deny and matches_any(module, policy.deny) or false
        local allowed = policy.allow == nil or matches_any(module, policy.allow)
        if denied or not allowed then
          table.insert(result.violations, {
              binding_id = binding.id,
              declaration = binding.declaration,
              module = module,
              message = "import of '" .. module .. "' crosses the configured boundary",
            })
        end
      end
    end
  end
  return result
end

local record ImportsModule
  type Policy = Policy
  type Violation = Violation
  type Unknown = Unknown
  type Result = Result
  check: function(Bindings, Policy): Result
end

local M: ImportsModule = {check = check}

return M
