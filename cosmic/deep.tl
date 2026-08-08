--- Deep table operations.
--- Recursive copy, structural equality, and recursive merge for
--- nested tables (#994: was cosmic.table, whose name collided with
--- Lua's `table` global and whose map/filter/reduce battery read
--- worse under Teal annotations than the loops it replaced). All
--- functions are pure: inputs are never mutated, and results share no
--- tables with their arguments. All functions are infallible.
---
--- Example usage:
---   local deep = require("cosmic.deep")
---   local copy = deep.copy(config)
---   local merged = deep.merge(defaults, overrides)
---   if deep.equal(expected, actual) then ... end
---
--- Semantics, frozen here so they never re-open: copy copies table
--- keys and values recursively and preserves shared references and
--- cycles within the input; metatables are NOT copied or attached —
--- the result is plain tables. equal compares structurally (same key
--- sets, deep-equal values); table-valued keys are matched by
--- identity, not structure. merge recurses where both sides hold
--- tables and lets the override win otherwise — array-like tables
--- therefore merge by index like any other key (an override list does
--- not truncate a longer base list).

--- Recursive copy. seen maps input tables to their copies so shared
--- references stay shared and cycles terminate.
local function copy_impl(v: any, seen: {any: any}): any
  if v is {any: any} then
    local hit = seen[v]
    if hit ~= nil then
      return hit
    end
    local out: {any: any} = {}
    seen[v] = out
    for k, val in pairs(v) do
      out[copy_impl(k, seen)] = copy_impl(val, seen)
    end
    return out
  end
  return v
end

--- Deep-copy a value. Tables are copied recursively (keys included);
--- shared references and cycles in the input are preserved in the
--- copy. Metatables are not copied: the result is plain tables.
--- Non-table values are returned as-is.
--- @param value any The value to copy
--- @return any A copy sharing no tables with the input
local function copy(value: any): any
  return copy_impl(value, {})
end

--- Structural equality. seen maps visited a-tables to the b-table
--- they are being compared against, so cyclic inputs terminate: a
--- pair already under comparison is assumed equal.
local function eq_impl(a: any, b: any, seen: {any: any}): boolean
  if a == b then
    return true
  end
  if a is {any: any} and b is {any: any} then
    if seen[a] == b then
      return true
    end
    seen[a] = b
    local count = 0
    for k, av in pairs(a) do
      count = count + 1
      if not eq_impl(av, b[k], seen) then
        return false
      end
    end
    for _ in pairs(b) do
      count = count - 1
    end
    return count == 0
  end
  return false
end

--- Compare two values for deep structural equality: equal scalars, or
--- tables with the same key sets and deep-equal values. Table-valued
--- keys are matched by identity, not structurally. Handles cyclic
--- inputs without looping.
--- @param a any First value
--- @param b any Second value
--- @return boolean True when a and b are structurally equal
local function equal(a: any, b: any): boolean
  return eq_impl(a, b, {})
end

local function merge_impl(base: {any: any}, override: {any: any}): {any: any}
  local out: {any: any} = {}
  for k, v in pairs(base) do
    out[k] = copy_impl(v, {})
  end
  for k, v in pairs(override) do
    local prev = out[k]
    if prev is {any: any} and v is {any: any} then
      out[k] = merge_impl(prev, v)
    else
      out[k] = copy_impl(v, {})
    end
  end
  return out
end

--- Recursively merge two tables into a new one. Where both sides
--- hold tables the merge recurses; otherwise the override value wins.
--- Neither input is mutated and the result shares no tables with
--- either. Array-like tables merge by index like any other key: an
--- override list replaces base elements position by position but does
--- not truncate a longer base list.
--- @param base {any:any} The base table (defaults)
--- @param override {any:any} The overriding table (wins on conflict)
--- @return {any:any} A new deeply-merged table
local function merge(base: {any: any}, override: {any: any}): {any: any}
  return merge_impl(base, override)
end

local record DeepModule
  copy: function(value: any): any
  equal: function(a: any, b: any): boolean
  merge: function(base: {any: any}, override: {any: any}): {any: any}
end

local M: DeepModule = {
  copy = copy,
  equal = equal,
  merge = merge,
}

return M
