--- Pure table-merge helpers for cosmic.quicksand.Box.
---
--- Keeps policy composition as plain data: mixins, overlays, and
--- per-environment overrides all go through `merge(...)` and yield a
--- new policy table. No syscalls, no side effects.
---
--- Field classes:
---   scalar   hostname, cwd, uid, gid, log_level, ...
---   list     fs.ro, fs.rw, fs.exec, env.keep, proc.keep_caps
---   map      net.allow, env.set
---
--- Merge rules:
---   scalar  later wins; nil is a no-op.
---   list    concat in order, then de-duplicate by value (first seen wins).
---   map     shallow key-by-key merge, later wins per key.
---
--- The schema below names every mergeable field and its class. Unknown
--- keys are treated as scalars, which is the right default for
--- forward-compatible additions (e.g. new string/bool fields).
local types = require("cosmic.quicksand.types")

local record Schema
  lists: {string: boolean}
  maps: {string: boolean}
end

local schema: Schema = {
  lists = {
    ["fs.ro"] = true,
    ["fs.rw"] = true,
    ["fs.exec"] = true,
    ["env.keep"] = true,
    -- Absent from the schema, keep_caps fell into the recursive branch and
    -- merged BY INDEX: {A,B} over {C} yielded {C,B}, silently retaining a
    -- capability the overlay never granted.
    ["proc.keep_caps"] = true,
  },
  maps = {
    ["net.allow"] = true,
    ["env.set"] = true,
  },
}

local function concat_unique(a: {any} | nil, b: {any} | nil): {any}
  local out: {any} = {}
  local seen: {any: boolean} = {}
  -- Iterate the two lists separately: ipairs on a literal {a, b}
  -- stops at the first nil, which would silently drop `b` when `a` is
  -- nil.
  if a then
    for _, v in ipairs(a) do
      if not seen[v] then
        seen[v] = true
        table.insert(out, v)
      end
    end
  end
  if b then
    for _, v in ipairs(b) do
      if not seen[v] then
        seen[v] = true
        table.insert(out, v)
      end
    end
  end
  return out
end

local function merge_map<K, V>(a: {K: V} | nil, b: {K: V} | nil): {K: V}
  local out: {K: V} = {}
  if a then for k, v in pairs(a) do out[k] = v end end
  if b then for k, v in pairs(b) do out[k] = v end end
  return out
end

-- Merge child tables at a given dotted path prefix (e.g. "fs", "net").
-- Recurses one level: within a section, per-field rules apply via schema.
local merge_section: function(string, {string: any}, {string: any}): {string: any}
merge_section = function(prefix: string, a: {string: any}, b: {string: any}): {string: any}
  local out: {string: any} = {}
  local keys: {string: boolean} = {}
  if a then for k in pairs(a) do keys[k] = true end end
  if b then for k in pairs(b) do keys[k] = true end end
  for k in pairs(keys) do
    local path = prefix == "" and k or (prefix .. "." .. k)
    -- Explicit nil-checked indexing: `a and a[k] or nil` collapses a
    -- stored `false` to nil, silently re-enabling a security opt-out
    -- (e.g. net.proxy_env = false, pid_ns = false).
    local av: any
    if a then av = a[k] end
    local bv: any
    if b then bv = b[k] end
    if schema.lists[path] then
      out[k] = concat_unique(av is {any} and av or nil, bv is {any} and bv or nil)
    elseif schema.maps[path] then
      out[k] = merge_map(av is {any: any} and av or nil,
        bv is {any: any} and bv or nil)
    elseif av is {string: any} or bv is {string: any} then
      -- Nested section like `fs`, `net`, `env`, `proc`. Recursing
      -- even when one side is nil guarantees the caller's tables are
      -- never shared into the output.
      out[k] = merge_section(path,
        av is {string: any} and av or {},
        bv is {string: any} and bv or {})
    else
      -- Scalar: later wins; nil is a no-op.
      if bv ~= nil then
        out[k] = bv
      else
        out[k] = av
      end
    end
  end
  return out
end

--- Merge any number of policy tables left-to-right.
--- The last argument wins scalar conflicts; list fields concat and
--- de-duplicate; map fields merge per key. Returns a fresh table.
---
--- The walk underneath is schema-driven and deliberately dynamic --
--- unknown keys merge as scalars -- so it runs over `{string: any}`.
--- Teal refuses both halves of that bridge on its own: `pairs` over a
--- record with fields of differing types is an error, a record is not
--- a valid map argument, and a map does not satisfy a record return.
--- The two casts here are that boundary and nothing else.
--- @param ... BoxOptions policy tables; nil entries are skipped
--- @return BoxOptions merged policy
local function merge(...: types.BoxOptions): types.BoxOptions
  local n = select("#", ...)
  local acc: {string: any} = {}
  for i = 1, n do
    local t = select(i, ...)
    if t then
      acc = merge_section("", acc, t as {string: any}) -- cast: record inspected as map
    end
  end
  return acc as types.BoxOptions -- cast: dynamic walk rebuilt as the record it walked
end

local record BoxMergeModule
  merge: function(...: types.BoxOptions): types.BoxOptions
end

local M: BoxMergeModule = {
  merge = merge,
}

return M
