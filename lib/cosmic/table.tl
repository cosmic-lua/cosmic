--- Table utilities.
--- Deep operations (copy, merge, structural equality) for nested
--- tables, and the classic list transforms (map, filter, reduce) with
--- generic types. All functions are pure: inputs are never mutated,
--- and the deep operations return results that share no tables with
--- their arguments. All functions are infallible.
---
--- The module name collides with Lua's `table` global; bind it as
--- `tbl` (the convention used throughout this codebase, like `str`
--- for cosmic.string) so the stdlib stays reachable.
---
--- Example usage:
---   local tbl = require("cosmic.table")
---   local copy = tbl.deep_copy(config)
---   local merged = tbl.deep_merge(defaults, overrides)
---   local squares = tbl.map({1, 2, 3}, function(n: number): number
---     return n * n
---   end)
---
--- Deep-operation semantics, frozen here so they never re-open:
--- deep_copy copies table keys and values recursively and preserves
--- shared references and cycles within the input; metatables are NOT
--- copied or attached — the result is plain tables. deep_eq compares
--- structurally (same key sets, deep-equal values); table-valued keys
--- are matched by identity, not structure. deep_merge recurses where
--- both sides hold tables and lets the override win otherwise —
--- array-like tables therefore merge by index like any other key
--- (an override list does not truncate a longer base list).
---
--- Reserved names: keys, values, contains, invert, and group_by are
--- reserved for a post-stable battery. Do not reuse these names for
--- anything else.

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
local function deep_copy(value: any): any
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
local function deep_eq(a: any, b: any): boolean
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
local function deep_merge(base: {any: any}, override: {any: any}): {any: any}
  return merge_impl(base, override)
end

--- Transform each element of a list, returning a new list of the
--- results in the same order. The input is not mutated.
--- @param list {T} The input list
--- @param fn function(T): U Transform applied to each element
--- @return {U} A new list of transformed elements
local function map<T, U>(list: {T}, fn: function(T): U): {U}
  local out: {U} = {}
  for i, v in ipairs(list) do
    out[i] = fn(v)
  end
  return out
end

--- Keep the elements of a list for which the predicate returns true,
--- preserving order. The input is not mutated.
--- @param list {T} The input list
--- @param fn function(T): boolean Predicate deciding which elements stay
--- @return {T} A new list of the elements that passed
local function filter<T>(list: {T}, fn: function(T): boolean): {T}
  local out: {T} = {}
  for _, v in ipairs(list) do
    if fn(v) then
      out[#out + 1] = v
    end
  end
  return out
end

--- Fold a list into a single value, left to right, starting from
--- init. An empty list returns init unchanged.
--- @param list {T} The input list
--- @param fn function(A, T): A Combiner of the accumulator and each element
--- @param init A The initial accumulator value
--- @return A The final accumulator
local function reduce<T, A>(list: {T}, fn: function(A, T): A, init: A): A
  local acc = init
  for _, v in ipairs(list) do
    acc = fn(acc, v)
  end
  return acc
end

local record TableModule
  deep_copy: function(value: any): any
  deep_eq: function(a: any, b: any): boolean
  deep_merge: function(base: {any: any}, override: {any: any}): {any: any}
  map: function<T, U>(list: {T}, fn: function(T): U): {U}
  filter: function<T>(list: {T}, fn: function(T): boolean): {T}
  reduce: function<T, A>(list: {T}, fn: function(A, T): A, init: A): A
end

local M: TableModule = {
  deep_copy = deep_copy,
  deep_eq = deep_eq,
  deep_merge = deep_merge,
  map = map,
  filter = filter,
  reduce = reduce,
}

return M
