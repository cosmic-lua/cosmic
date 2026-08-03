--- Pure table-merge helpers for cosmic.quicksand.Box.
---
--- Keeps policy composition as plain data: mixins, overlays, and
--- per-environment overrides all go through `merge(...)` and yield a
--- new policy table. No syscalls, no side effects.
---
--- Field classes:
---   scalar   hostname, cwd, uid, gid, pledge, log_level, ...
---   list     fs.ro, fs.rw, fs.exec, env.keep
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
  },
  maps = {
    ["net.allow"] = true,
    ["env.set"] = true,
  },
}

local function concat_unique(a: {any}, b: {any}): {any}
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

local function merge_map<K, V>(a: {K: V}, b: {K: V}): {K: V}
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
      out[k] = concat_unique(av as {any}, bv as {any}) -- cast: from any
    elseif schema.maps[path] then
      out[k] = merge_map(av as {any: any}, bv as {any: any}) -- cast: from any
    elseif type(av) == "table" or type(bv) == "table" then
      -- Nested section like `fs`, `net`, `env`, `proc`. Recursing
      -- even when one side is nil guarantees the caller's tables are
      -- never shared into the output.
      out[k] = merge_section(path,
        (av as {string: any}) or {}, -- cast: from any
        (bv as {string: any}) or {}) -- cast: from any
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
--- @param ... {string: any} policy tables; nil entries are skipped
--- @return {string: any} merged policy
local function merge(...: {string: any}): {string: any}
  local n = select("#", ...)
  local acc: {string: any} = {}
  for i = 1, n do
    local t = select(i, ...)
    if t then
      acc = merge_section("", acc, t)
    end
  end
  return acc
end

local record BoxMergeModule
  merge: function(...: {string: any}): {string: any}
end

local M: BoxMergeModule = {
  merge = merge,
}

return M
