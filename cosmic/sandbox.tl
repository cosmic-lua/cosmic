--- One-call, fail-closed sandbox facade over unveil, landlock, and
--- pledge.
---
--- cosmic ships three mechanism-level sandbox modules with overlapping
--- stories: `cosmic.landlock` (Linux), `cosmic.unveil` (OpenBSD, or
--- Linux where the libc backs it with landlock), and `cosmic.pledge`
--- (Linux, OpenBSD). This module is the one to reach for unless you
--- need mechanism-specific control: it takes a single declarative
--- policy, picks the right mechanism per OS, and applies the sections
--- in the only order that works (fs before sys — a pledged process may
--- no longer be allowed to install a filesystem sandbox).
---
---     local sandbox = require("cosmic.sandbox")
---     assert(sandbox.apply{
---       fs = { exec = { "/usr" }, ro = { "/etc" }, rw = { "/tmp" } },
---       sys = { promises = "stdio rpath wpath" },
---     })
---
--- Like the mechanism modules, the facade is fail-closed: a section
--- that cannot be enforced on this host makes `apply` return
--- `nil, "sandbox: ... unsupported on this host"` before anything is
--- applied, unless `best_effort = true` opts into skipping unenforceable
--- sections — in which case the returned Availability record reports
--- which sections actually enforced. `available()` reports what this
--- host can enforce.
---
--- Applying is irreversible and process-wide; policies can only be
--- narrowed by further calls. `cosmic.quicksand.Box` consumes the same
--- `fs` schema for its boxed workloads.
local cosmo = require("cosmo")
local landlock = require("cosmic.landlock")
local pledge = require("cosmic.pledge")
local unveil = require("cosmic.unveil")

--- Filesystem policy: path allowlists. Everything not listed is denied
--- once the policy applies. The three groups mean three things: `ro`
--- paths are readable and nothing else — a directory of untrusted
--- input stays non-executable; `exec` paths are readable *and*
--- executable, for binaries and libraries that must run; `rw` paths
--- are readable and writable, including creating and removing entries,
--- but never executable. A path listed in several groups gets the
--- union of their access. A present-but-empty group is a real policy
--- (`fs = { ro = {} }` denies everything); a policy with no group at
--- all is rejected — omit `fs` entirely to skip filesystem policy.
local record Fs
  ro: {string}
  rw: {string}
  exec: {string}
end

--- System-call policy: pledge promise groups as a space-separated
--- string (see cosmic.pledge for the group list; the `Promise` enum
--- there names every valid token). `exec` optionally sets the promises
--- children keep after execve.
local record Sys
  promises: string
  exec: string
end

--- A full sandbox policy. Each section is optional but at least one
--- must be present. `best_effort = true` skips sections this host
--- cannot enforce instead of failing closed.
local record Policy
  fs: Fs
  sys: Sys
  best_effort: boolean
  --- The caller asserts this policy still permits the line-coverage
  --- dump, because `fs` grants that directory. Without it the
  --- mechanism seals coverage before restricting — the safe answer
  --- when nobody knows — and the process reports only what it did
  --- before the sandbox landed.
  keep_coverage: boolean
end

--- Per-section enforcement report: `fs` (landlock on Linux, unveil on
--- OpenBSD) and `sys` (pledge). `available()` returns what this host
--- *can* enforce; a successful `apply` returns what it *did* enforce,
--- so a `best_effort` caller can see exactly which sections were
--- skipped instead of flying blind.
local record Availability
  fs: boolean
  sys: boolean
end

local type Rule = landlock.Rule
local type RestrictOptions = landlock.RestrictOptions

local record SandboxModule
  type Fs = Fs
  type Sys = Sys
  type Policy = Policy
  type Availability = Availability
  apply: function(policy: Policy): Availability | nil, string
  available: function(): Availability
  validate: function(policy: Policy): boolean, string
  plan_landlock: function(fs: Fs, keep_coverage?: boolean): RestrictOptions
end

-- Promise-name set for pre-enforcement validation, built from the
-- runtime mirror of the pledge Promise enum.
local valid_promise: {string: boolean} = {}
for _, p in ipairs(pledge.PROMISES) do
  valid_promise[p] = true
end

--- True when this host can enforce an fs section: landlock on Linux,
--- unveil natively on OpenBSD. (On Linux the libc backs unveil with
--- landlock too; the facade uses cosmic.landlock directly there.)
local function fs_available(): boolean
  local host = cosmo.GetHostOs()
  if host == "LINUX" then
    return landlock.available()
  end
  return unveil.available()
end

--- Report what this host can enforce. Sections requested in `apply`
--- beyond this fail closed (or are skipped under `best_effort`).
---
--- @return Availability per-section enforceability
local function available(): Availability
  return {
    fs = fs_available(),
    sys = pledge.available(),
  }
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

--- Translate an fs policy to `cosmic.landlock.restrict` options. Pure:
--- no syscalls, no side effects — exported so the mapping is
--- inspectable and unit-testable. `no_new_privs` is set so landlock
--- applies without CAP_SYS_ADMIN. An empty or nil policy produces an
--- empty rules list, which denies everything when applied.
---
--- @param fs Fs nil treated as empty (deny-all)
--- @param keep_coverage boolean? Skip the pre-restrict coverage seal
--- @return RestrictOptions options for cosmic.landlock.restrict
local function plan_landlock(fs: Fs, keep_coverage?: boolean): RestrictOptions
  local rules: {Rule} = {}
  local seen: {string: integer} = {}
  add_rules(rules, seen, fs and fs.ro or nil, landlock.READ)
  add_rules(rules, seen, fs and fs.rw or nil, landlock.RW)
  add_rules(rules, seen, fs and fs.exec or nil, landlock.READ | landlock.EXEC)
  return {
    handled = landlock.ALL,
    rules = rules,
    no_new_privs = true,
    keep_coverage = keep_coverage or false,
  }
end

-- The unveil equivalents of the landlock group masks: ro exposes read
-- only, exec exposes read + execute, rw exposes read + write +
-- create/remove.
local function apply_fs_unveil(fs: Fs, keep_coverage?: boolean): boolean, string
  local groups: {{{string}, unveil.Perm}} = {
    {fs.ro, "r"},
    {fs.rw, "rwc"},
    {fs.exec, "rx"},
  }
  local uopts: unveil.UnveilOptions = {keep_coverage = keep_coverage or false}
  for _, g in ipairs(groups) do
    for _, p in ipairs(g[1] or {}) do
      local ok, err = unveil.allow(p, g[2], uopts)
      if not ok then return false, err end
    end
  end
  return unveil.commit(uopts)
end

local function apply_fs(fs: Fs, keep_coverage?: boolean): boolean, string
  if cosmo.GetHostOs() == "LINUX" then
    return landlock.restrict(plan_landlock(fs, keep_coverage))
  end
  return apply_fs_unveil(fs, keep_coverage)
end

-- Structural validation, all before any enforcement. Returns nil when
-- valid, an error string otherwise.
local function check_promises(promises: string, label: string): string
  if promises == nil then return nil end
  if type(promises) ~= "string" then
    return "sandbox: " .. label .. " must be a string"
  end
  for token in promises:gmatch("%S+") do
    if not valid_promise[token] then
      return string.format("sandbox: unknown promise %q in %s", token, label)
    end
  end
  return nil
end

local function check_policy(policy: Policy): string
  if policy == nil or (policy.fs == nil and policy.sys == nil) then
    return "sandbox: policy must set fs and/or sys"
  end
  local fs = policy.fs
  if fs then
    if type(fs) ~= "table" then
      return "sandbox: fs must be a table"
    end
    if (fs as {string: any}).deny ~= nil then -- cast: record to map probe
      return "sandbox: fs.deny does not exist: the fs policy is an"
      .. " allowlist, every path not in ro/rw/exec is already denied"
    end
    for _, name in ipairs({"ro", "rw", "exec"}) do
      local v = (fs as {string: any})[name] -- cast: record to map probe
      if v ~= nil and type(v) ~= "table" then
        return "sandbox: fs." .. name .. " must be a list of paths"
      end
    end
    if fs.ro == nil and fs.rw == nil and fs.exec == nil then
      return "sandbox: fs policy has no groups — pass fs = { ro = {} }"
      .. " to deny everything, or omit fs to skip filesystem policy"
    end
  end
  local sys = policy.sys
  if sys then
    if type(sys) ~= "table" then
      return "sandbox: sys must be a table"
    end
    local perr = check_promises(sys.promises, "sys.promises")
    if perr then return perr end
    perr = check_promises(sys.exec, "sys.exec")
    if perr then return perr end
  end
  return nil
end

--- Validate a policy's structure without enforcing anything: section
--- shapes, path-list types, and promise tokens. `apply` runs this
--- itself; it is exported so a policy carried across a process
--- boundary (e.g. cosmic.quicksand.Box) can be rejected at
--- construction time instead of dying post-fork.
---
--- @param policy Policy the policy to check
--- @return boolean True when structurally valid
--- @return string? Error message on failure
local function validate(policy: Policy): boolean, string
  local verr = check_policy(policy)
  if verr then return false, verr end
  return true
end

--- Apply a sandbox policy to the current process. Irreversible.
---
--- The policy is validated and this host's enforceability checked for
--- every requested section *before* anything is applied, so a failure
--- return means nothing changed. Sections then apply in enforced
--- order: `fs` first (landlock on Linux, unveil on OpenBSD), `sys`
--- (pledge) second — the reverse would let the pledge filter block the
--- filesystem-sandbox syscalls.
---
--- Fail-closed: a requested section this host cannot enforce returns
--- `nil, "sandbox: ... unsupported on this host"`. With
--- `best_effort = true` unenforceable sections are skipped instead —
--- and the return value says so: on success apply returns an
--- Availability record of what was actually enforced, so a
--- best_effort caller can log or refuse when `.fs`/`.sys` came back
--- false rather than believing in a sandbox that is not there.
---
--- @param policy Policy fs and/or sys sections, best_effort flag
--- @return Availability? What was enforced, on success
--- @return string? Error message on failure
local function apply(policy: Policy): Availability | nil, string
  local verr = check_policy(policy)
  if verr then return nil, verr end
  local do_fs = policy.fs ~= nil
  local do_sys = policy.sys ~= nil
  if do_fs and not fs_available() then
    if not policy.best_effort then
      return nil, "sandbox: fs policy unsupported on this host"
      .. " (needs landlock on Linux, or OpenBSD)"
    end
    do_fs = false
  end
  if do_sys and not pledge.available() then
    if not policy.best_effort then
      return nil, "sandbox: sys policy unsupported on this host"
    end
    do_sys = false
  end
  if do_fs then
    local ok, err = apply_fs(policy.fs, policy.keep_coverage)
    if not ok then return nil, "sandbox: fs: " .. tostring(err) end
  end
  if do_sys then
    local ok, err = pledge.apply(policy.sys.promises,
      {exec = policy.sys.exec, keep_coverage = policy.keep_coverage})
    if not ok then return nil, "sandbox: sys: " .. tostring(err) end
  end
  return {fs = do_fs, sys = do_sys}
end

local M: SandboxModule = {
  apply = apply,
  available = available,
  validate = validate,
  plan_landlock = plan_landlock,
}

return M
