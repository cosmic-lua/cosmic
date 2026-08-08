--- The pure fs-policy -> landlock mapping behind cosmic.sandbox.
--- Split from the facade (#989) so the mapping stays inspectable and
--- unit-testable without being public API: cosmic.sandbox.plan is an
--- internal shard, and the facade's apply() is the one door.
local landlock = require("cosmic.sandbox.landlock")

local type Rule = landlock.Rule
local type RestrictOptions = landlock.RestrictOptions

--- The facade's filesystem policy: path allowlists. Everything not
--- listed is denied once the policy applies. `ro` paths are readable
--- and nothing else; `exec` paths are readable *and* executable; `rw`
--- paths are readable and writable (including creating and removing
--- entries) but never executable. A path listed in several groups gets
--- the union of their access. A present-but-empty group is a real
--- policy (`fs = { ro = {} }` denies everything); a policy with no
--- group at all is rejected — omit `fs` entirely to skip filesystem
--- policy. With `optional = true`, rules naming paths that do not
--- exist are dropped instead of failing the whole policy (landlock
--- rules are OPENED, so a missing path otherwise kills the restrict).
local record Fs
  ro: {string}
  rw: {string}
  exec: {string}
  optional: boolean
end

-- Add rules for every path in `paths` with the given access mask,
-- de-duplicating by path: a path listed in several groups gets the
-- union of their masks (landlock ORs per inode anyway; deduping keeps
-- the rules list small and predictable).
local function add_rules(
    out: {Rule},
    seen: {string: integer},
    paths: {string},
    mask: integer
  )
  if not paths then return end
  for _, p in ipairs(paths) do
    local idx = seen[p]
    if idx then
      out[idx].access = out[idx].access | mask
    else
      table.insert(out, {path = p, access = mask})
      seen[p] = #out
    end
  end
end

--- Translate an fs policy to `landlock.restrict` options. Pure: no
--- syscalls, no side effects (the `optional` path filtering happens in
--- the facade, before this runs). `no_new_privs` and `handled` default
--- so landlock applies without CAP_SYS_ADMIN and controls the full
--- current access set; the facade's Options can override both. An
--- empty or nil policy produces an empty rules list, which denies
--- everything when applied.
---
--- @param fs Fs nil treated as empty (deny-all)
--- @param no_new_privs boolean? default true
--- @param handled integer? default landlock.ALL
--- @return RestrictOptions options for landlock.restrict
local function for_landlock(fs: Fs, no_new_privs?: boolean,
    handled?: integer): RestrictOptions
  local rules: {Rule} = {}
  local seen: {string: integer} = {}
  add_rules(rules, seen, fs and fs.ro or nil, landlock.READ)
  add_rules(rules, seen, fs and fs.rw or nil, landlock.RW)
  add_rules(rules, seen, fs and fs.exec or nil, landlock.READ | landlock.EXEC)
  return {
    handled = handled or landlock.ALL,
    rules = rules,
    no_new_privs = no_new_privs ~= false,
  }
end

local record PlanModule
  type Fs = Fs
  for_landlock: function(fs: Fs, no_new_privs?: boolean, handled?: integer): RestrictOptions
end

local M: PlanModule = {
  for_landlock = for_landlock,
}

return M
