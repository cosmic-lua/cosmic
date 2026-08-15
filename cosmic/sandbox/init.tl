--- One-call, fail-closed in-process sandbox: the one door.
---
--- cosmic ships two public containment modules: this one (in-process
--- self-restriction) and `cosmic.quicksand` (out-of-process boxes).
--- The mechanisms behind this facade — landlock (Linux), unveil
--- (OpenBSD), pledge (both) — are internal shards under
--- cosmic/sandbox/; the facade takes a single declarative policy,
--- picks the right mechanism per OS, and applies the sections in the
--- only order that works (fs before sys — a pledged process may no
--- longer be allowed to install a filesystem sandbox).
---
---     local sandbox = require("cosmic.sandbox")
---     assert(sandbox.apply{
---       fs = { exec = { "/usr" }, ro = { "/etc" }, rw = { "/tmp" } },
---       sys = { promises = "stdio rpath wpath" },
---     })
---
--- Fail-closed: a section that cannot be enforced on this host makes
--- `apply` return `nil, "sandbox: ... unsupported on this host"`
--- before anything is applied, unless `best_effort = true` opts into
--- skipping unenforceable sections — in which case the returned
--- Availability record reports which sections actually enforced.
--- `availability()` reports what this host can enforce;
--- `is_available()` is the boolean shorthand.
---
--- Applying is irreversible and process-wide; policies can only be
--- narrowed by further calls. `cosmic.quicksand` consumes the same
--- `fs`/`sys` schemas for its boxed workloads.
local cosmo = require("cosmo")
local cosmo_path = require("cosmo.path")
local landlock = require("cosmic.sandbox.landlock")
local pledge = require("cosmic.sandbox.pledge")
local unveil = require("cosmic.sandbox.unveil")
local plan = require("cosmic.sandbox.plan")

--- Filesystem policy; the record (ro/rw/exec allowlists plus
--- `optional`) is defined in cosmic.sandbox.plan beside its mapping.
local type Fs = plan.Fs

--- System-call policy: pledge promise groups as a space-separated
--- string (the internal pledge shard's `Promise` enum names every
--- valid token). `exec_promises` optionally sets the promises children
--- keep after execve — named to avoid reading as a path list beside
--- fs.exec.
local record Sys
  promises: string
  exec_promises: string
end

--- A full sandbox policy. Each section is optional but at least one
--- must be present. `best_effort = true` skips sections this host
--- cannot enforce instead of failing closed. `no_new_privs` and
--- `handled` tune the Linux fs mechanism: no_new_privs defaults true
--- so the restrict works unprivileged; handled narrows which access
--- categories the sandbox controls (default: all of them).
local record Options
  fs: Fs
  sys: Sys
  best_effort: boolean
  no_new_privs: boolean
  handled: integer
end

--- Per-section enforcement report: `fs` (landlock on Linux, unveil on
--- OpenBSD) and `sys` (pledge). `availability()` returns what this
--- host *can* enforce; a successful `apply` returns what it *did*
--- enforce, so a `best_effort` caller can see exactly which sections
--- were skipped instead of flying blind.
local record Availability
  fs: boolean
  sys: boolean
end

local record SandboxModule
  type Fs = Fs
  type Sys = Sys
  type Options = Options
  type Availability = Availability
  apply: function(opts: Options): Availability | nil, string
  availability: function(): Availability
  is_available: function(): boolean
  validate: function(opts: Options): boolean, string
  merge: function(...: Options): Options
end

-- Promise-name set for pre-enforcement validation, built from the
-- runtime mirror of the pledge Promise enum.
local valid_promise: {string: boolean} = {}
for _, p in ipairs(pledge.PROMISES) do
  valid_promise[p] = true
end

--- True when this host can enforce an fs section: landlock on Linux,
--- unveil natively on OpenBSD. (On Linux the libc backs unveil with
--- landlock too; the facade uses the landlock shard directly there.)
local function fs_available(): boolean
  local host = cosmo.GetHostOs()
  if host == "LINUX" then
    return landlock.available()
  end
  return unveil.available()
end

--- Report what this host can enforce, per section. Sections requested
--- in `apply` beyond this fail closed (or are skipped under
--- `best_effort`).
---
--- @return Availability per-section enforceability
local function availability(): Availability
  return {
    fs = fs_available(),
    sys = pledge.available(),
  }
end

--- True when every section this facade fronts is enforceable here —
--- the one boolean predicate covering the whole family. For
--- per-section answers use availability().
---
--- @return boolean True when both fs and sys can be enforced
local function is_available(): boolean
  local a = availability()
  return a.fs and a.sys
end

--- Drop rules naming absent paths from one group. Only called under
--- fs.optional: landlock rules are OPENED, so a missing path otherwise
--- fails the whole restrict — and an optional policy prefers a
--- narrower sandbox over none.
local function present_only(paths: {string}): {string}
  if not paths then return nil end
  local out: {string} = {}
  for _, p in ipairs(paths) do
    if cosmo_path.exists(p) then
      out[#out + 1] = p
    end
  end
  return out
end

local function effective_fs(fs: Fs): Fs
  if not fs or not fs.optional then return fs end
  return {
    ro = present_only(fs.ro),
    rw = present_only(fs.rw),
    exec = present_only(fs.exec),
    optional = true,
  }
end

-- The unveil equivalents of the landlock group masks: ro exposes read
-- only, exec exposes read + execute, rw exposes read + write +
-- create/remove.
local function apply_fs_unveil(fs: Fs): boolean, string
  local groups: {{{string}, unveil.Perm}} = {
    {fs.ro, "r"},
    {fs.rw, "rwc"},
    {fs.exec, "rx"},
  }
  for _, g in ipairs(groups) do
    for _, p in ipairs(g[1] or {}) do
      local ok, err = unveil.allow(p, g[2])
      if not ok then return false, err end
    end
  end
  return unveil.commit()
end

local function apply_fs(fs: Fs, no_new_privs: boolean, handled: integer): boolean, string
  if cosmo.GetHostOs() == "LINUX" then
    return landlock.restrict(plan.for_landlock(fs, no_new_privs, handled))
  end
  return apply_fs_unveil(fs)
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

local function check_policy(opts: Options): string
  if opts == nil or (opts.fs == nil and opts.sys == nil) then
    return "sandbox: policy must set fs and/or sys"
  end
  local fs = opts.fs
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
  local sys = opts.sys
  if sys then
    if type(sys) ~= "table" then
      return "sandbox: sys must be a table"
    end
    if (sys as {string: any}).exec ~= nil then -- cast: record to map probe
      return "sandbox: sys.exec does not exist: the key is"
      .. " sys.exec_promises (#989 renamed it) — silently dropping the"
      .. " old spelling would run exec'd children with no promises"
    end
    local perr = check_promises(sys.promises, "sys.promises")
    if perr then return perr end
    perr = check_promises(sys.exec_promises, "sys.exec_promises")
    if perr then return perr end
  end
  return nil
end

--- Validate a policy's structure without enforcing anything: section
--- shapes, path-list types, and promise tokens. `apply` runs this
--- itself; it is exported so a policy carried across a process
--- boundary (e.g. cosmic.quicksand) can be rejected at construction
--- time instead of dying post-fork.
---
--- @param opts Options the policy to check
--- @return boolean True when structurally valid
--- @return string? Error message on failure
local function validate(opts: Options): boolean, string
  local verr = check_policy(opts)
  if verr then return false, verr end
  return true
end

local function merged_list(a: {string}, b: {string}): {string}
  if a == nil and b == nil then return nil end
  local out: {string} = {}
  local seen: {string: boolean} = {}
  for _, list in ipairs({a or {}, b or {}}) do
    for _, p in ipairs(list) do
      if not seen[p] then
        seen[p] = true
        out[#out + 1] = p
      end
    end
  end
  return out
end

--- Compose policies left-to-right, mirroring quicksand's Box merge:
--- fs path lists concat and dedupe; scalars (best_effort,
--- no_new_privs, handled, fs.optional, the sys strings) take the later
--- value when set. Returns a fresh Options suitable for apply(); nil
--- arguments are skipped.
---
--- @param ... Options policies to merge, left to right
--- @return Options the merged policy
local function merge(...: Options): Options
  local out: Options = {}
  for i = 1, select("#", ...) do
    local o = select(i, ...)
    if o then
      if o.fs then
        local base: Fs = out.fs or {}
        out.fs = {
          ro = merged_list(base.ro, o.fs.ro),
          rw = merged_list(base.rw, o.fs.rw),
          exec = merged_list(base.exec, o.fs.exec),
          optional = o.fs.optional == nil and base.optional or o.fs.optional,
        }
      end
      if o.sys then
        local sbase: Sys = out.sys or {}
        out.sys = {
          promises = o.sys.promises or sbase.promises,
          exec_promises = o.sys.exec_promises or sbase.exec_promises,
        }
      end
      if o.best_effort ~= nil then out.best_effort = o.best_effort end
      if o.no_new_privs ~= nil then out.no_new_privs = o.no_new_privs end
      if o.handled ~= nil then out.handled = o.handled end
    end
  end
  return out
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
--- @param opts Options fs and/or sys sections plus tuning flags
--- @return Availability? What was enforced, on success
--- @return string? Error message on failure
local function apply(opts: Options): Availability | nil, string
  local verr = check_policy(opts)
  if verr then return nil, verr end
  local do_fs = opts.fs ~= nil
  local do_sys = opts.sys ~= nil
  if do_fs and not fs_available() then
    if not opts.best_effort then
      return nil, "sandbox: fs unsupported on this host"
      .. " (needs Landlock on Linux, or unveil on OpenBSD)"
    end
    do_fs = false
  end
  if do_sys and not pledge.available() then
    if not opts.best_effort then
      return nil, "sandbox: sys unsupported on this host"
      .. " (needs pledge: Linux seccomp, or OpenBSD)"
    end
    do_sys = false
  end
  if do_fs then
    local ok, err = apply_fs(effective_fs(opts.fs),
      opts.no_new_privs ~= false, opts.handled)
    if not ok then return nil, "sandbox: fs: " .. tostring(err) end
  end
  if do_sys then
    local ok, err = pledge.apply(opts.sys.promises,
      {exec = opts.sys.exec_promises})
    if not ok then return nil, "sandbox: sys: " .. tostring(err) end
  end
  return {fs = do_fs, sys = do_sys}
end

local M: SandboxModule = {
  apply = apply,
  availability = availability,
  is_available = is_available,
  validate = validate,
  merge = merge,
}

return M
