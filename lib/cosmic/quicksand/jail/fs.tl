--- Pure translator: Jail `fs` policy → `cosmic.landlock.RestrictOpts`.
---
--- Keeps the fs → landlock mapping in one place so the Jail orchestrator
--- stays clear of access-mask juggling. No syscalls; the result is fed
--- into `landlock.restrict{}` in the jailed child.
---
--- Policy shape (input):
---   fs = {
---     ro   = { ... },  -- read + exec on listed paths
---     rw   = { ... },  -- read + write on listed paths
---     exec = { ... },  -- read + exec on listed paths (emphasis only)
---     deny = { ... },  -- informational; landlock is allowlist-default,
---                      -- so any path not listed in ro/rw/exec is denied
---                      -- already. Recorded verbatim for diagnostics.
---   }
---
--- A nil or empty policy produces an empty `rules` list, which — when
--- fed to landlock.restrict — denies everything. Callers that want
--- "no sandboxing" should skip landlock entirely rather than calling
--- plan_landlock with nil.
local landlock = require("cosmic.landlock")

local record FsOpts
  ro: {string}
  rw: {string}
  exec: {string}
  deny: {string}
end

local record Rule
  path: string
  access: integer
end

local record RestrictOpts
  handled: integer
  rules: {Rule}
  no_new_privs: boolean
end

-- Add rules for every path in `paths` with the given access mask. The
-- first path wins if the same path appears in multiple groups (e.g.
-- listed in both `ro` and `rw`), since landlock ORs access masks per
-- inode anyway — but we de-duplicate explicitly to keep the rules list
-- small and predictable.
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

--- Translate an fs policy to a RestrictOpts suitable for
--- `cosmic.landlock.restrict`. Pure: no syscalls, no side effects.
---
--- `no_new_privs` is set to true so landlock applies even without
--- CAP_SYS_ADMIN. Callers that want to orchestrate no_new_privs
--- themselves can overwrite it on the returned table.
---
--- @param fs FsOpts nil treated as empty (deny-all)
--- @return RestrictOpts
local function plan_landlock(fs: FsOpts): RestrictOpts
  local rules: {Rule} = {}
  local seen: {string: integer} = {}
  add_rules(rules, seen, fs and fs.ro or nil, landlock.READ | landlock.EXEC)
  add_rules(rules, seen, fs and fs.rw or nil, landlock.RW)
  add_rules(rules, seen, fs and fs.exec or nil, landlock.READ | landlock.EXEC)
  return {
    handled = landlock.ALL,
    rules = rules,
    no_new_privs = true,
  }
end

local record JailFsModule
  plan_landlock: function(fs: FsOpts): RestrictOpts
end

local M: JailFsModule = {
  plan_landlock = plan_landlock,
}

return M
