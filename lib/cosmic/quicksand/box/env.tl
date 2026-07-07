--- Pure env-policy helpers for cosmic.quicksand.Box.
---
--- Given an env policy (`keep` list, `set` map) and the parent
--- environment, return the env dict the boxed workload should see.
---
--- Semantics:
---   keep   list of variable names to inherit from the parent
---          environment. Variables not in keep are dropped.
---   set    map of names to values that override / add to keep.
---
--- Both fields are optional:
---   nil keep  → inherit nothing (empty starting set)
---   nil set   → no overrides
---
--- Nothing here touches real process env — callers apply the result via
--- their own setenv loop after fork, before execve.
local types = require("cosmic.quicksand.types")

local type EnvOptions = types.EnvOptions

local function apply(opts: EnvOptions, parent: {string: string}): {string: string}
  local out: {string: string} = {}
  if opts and opts.keep and parent then
    for _, name in ipairs(opts.keep) do
      local v = parent[name]
      if v ~= nil then
        out[name] = v
      end
    end
  end
  if opts and opts.set then
    for k, v in pairs(opts.set) do
      out[k] = v
    end
  end
  return out
end

--- Render an env dict as an array of "NAME=VALUE" strings, sorted by
--- name for stable output. Useful for execvpe-style APIs and for
--- deterministic diffing in tests.
local function render(env: {string: string}): {string}
  local names: {string} = {}
  for k in pairs(env) do table.insert(names, k) end
  table.sort(names)
  local out: {string} = {}
  for _, k in ipairs(names) do
    table.insert(out, k .. "=" .. env[k])
  end
  return out
end

local record BoxEnvModule
  apply: function(opts: EnvOptions, parent: {string: string}): {string: string}
  render: function(env: {string: string}): {string}
end

local M: BoxEnvModule = {
  apply = apply,
  render = render,
}

return M
