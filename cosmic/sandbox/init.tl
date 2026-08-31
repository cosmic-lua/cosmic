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
--- Fail-closed: an unenforceable section makes `apply` return `nil,
--- "sandbox: ... unsupported on this host"` before anything is
--- applied, unless `best_effort = true` skips it instead. Success
--- returns a `Report`: one `Section` per requested section, each
--- saying `state` — `"full"`, `"degraded"` (landlock enforced, but
--- this kernel's ABI stripped some requested rights), or `"skipped"` —
--- plus which mechanism enforced it and what is missing. A
--- best_effort apply that skips EVERY section refuses outright (`nil,
--- "sandbox: nothing enforced (...)"`) unless `allow_unenforced =
--- true` says the caller expects that. `strict = true` goes the other
--- way: any section that would end degraded or skipped is a refusal
--- instead (see [D40](../../docs/decisions/d40-sandbox-enforcement-report.md)).
--- `availability()` reports what this host can enforce, per section;
--- `is_available()` is the boolean shorthand.
---
--- Applying is irreversible and process-wide; policies can only be
--- narrowed by further calls. `cosmic.quicksand` consumes the same
--- `fs`/`sys` schemas for its boxed workloads.
local cosmo = require("cosmo")
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
--- must be present. `best_effort` skips unenforceable sections instead
--- of failing closed; `allow_unenforced` additionally tolerates every
--- section ending up skipped (only meaningful with `best_effort`).
--- `strict` refuses any section that would end degraded or skipped
--- (mutually exclusive with both). `no_new_privs` defaults true so the
--- Linux fs mechanism works unprivileged.
local record Options
  fs: Fs
  sys: Sys
  best_effort: boolean
  allow_unenforced: boolean
  strict: boolean
  no_new_privs: boolean
end

--- What this host can enforce for one section: `mechanism` names the
--- backend ("landlock" | "unveil" | "pledge"); `abi` is its ABI
--- version where that concept exists (0 otherwise).
local record MechanismInfo
  available: boolean
  mechanism: string
  abi: integer
end

--- Per-section enforceability. `.fs.available` / `.sys.available` are
--- the plain booleans most callers want; `.mechanism`/`.abi` say which
--- backend and version back that answer. `is_available()` is the AND.
local record Availability
  fs: MechanismInfo
  sys: MechanismInfo
end

--- One section's enforcement result. `state` is `"full"`, `"degraded"`
--- (landlock enforced, but this kernel's ABI stripped some requested
--- rights), or `"skipped"` (best_effort passed an unenforceable
--- section). `mechanism` names what enforced it; `abi` is its ABI
--- version where meaningful (0 otherwise); `missing` renders what was
--- stripped/skipped, "" when full.
local record Section
  state: string
  mechanism: string
  abi: integer
  missing: string
end

--- Per-section report from a successful apply: `fs`/`sys` are set
--- exactly when requested. Replaces the old two-boolean shape, which
--- could not tell full enforcement from a landlock restrict that
--- silently dropped TRUNCATE/REFER.
local record Report
  fs: Section
  sys: Section
end

local record SandboxModule
  type Fs = Fs
  type Sys = Sys
  type Options = Options
  type Availability = Availability
  type MechanismInfo = MechanismInfo
  type Section = Section
  type Report = Report
  apply: function(opts: Options): Report | nil, string
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

--- Which mechanism enforces `fs` on this host: landlock on Linux,
--- unveil natively on OpenBSD. (On Linux the libc backs unveil with
--- landlock too; the facade uses the landlock shard directly there.)
local function fs_mechanism(): string
  if cosmo.GetHostOs() == "LINUX" then
    return "landlock"
  end
  return "unveil"
end

--- True when this host can enforce an fs section.
local function fs_available(): boolean
  if fs_mechanism() == "landlock" then
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
  local mech = fs_mechanism()
  local fs_abi = 0
  if mech == "landlock" then
    fs_abi = landlock.abi() or 0
  end
  return {
    fs = {available = fs_available(), mechanism = mech, abi = fs_abi},
    sys = {available = pledge.available(), mechanism = "pledge", abi = 0},
  }
end

--- True when every section this facade fronts is enforceable here —
--- the one boolean predicate covering the whole family. For
--- per-section answers use availability().
---
--- @return boolean True when both fs and sys can be enforced
local function is_available(): boolean
  local a = availability()
  return a.fs.available and a.sys.available
end

-- Render which of the (only ever) two strippable Landlock rights are
-- set in `stripped`, plus the ABI that stripped them. Used both for a
-- real degraded Section's `missing` and for strict's pre-enforcement
-- refusal message, so the wording matches whichever path produced it.
local function landlock_missing(stripped: integer, abi_version: integer): string
  if stripped == 0 then return "" end
  local names: {string} = {}
  if stripped & landlock.REFER ~= 0 then names[#names + 1] = "REFER" end
  if stripped & landlock.TRUNCATE ~= 0 then names[#names + 1] = "TRUNCATE" end
  return table.concat(names, ", ") .. " unsupported on this kernel (Landlock ABI "
  .. tostring(abi_version) .. ")"
end

--- Human text for a section this host cannot enforce at all — used
--- both for the fail-closed error and for a best_effort "skipped"
--- Section's `missing`.
local function unsupported_text(section: string): string
  if section == "fs" then
    return "fs unsupported on this host"
    .. " (needs Landlock on Linux, or unveil on OpenBSD)"
  end
  return "sys unsupported on this host"
  .. " (needs pledge: Linux seccomp, or OpenBSD)"
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
  local opts: unveil.Options = {missing_ok = fs.optional == true}
  for _, g in ipairs(groups) do
    for _, p in ipairs(g[1] or {}) do
      local ok, err = unveil.allow(p, g[2], opts)
      if not ok then return false, err end
    end
  end
  return unveil.commit()
end

--- Apply the fs section via this host's mechanism and report what
--- happened. Landlock reports exactly what it enforced (a full-or-
--- degraded Section); unveil has no partial concept, so a successful
--- commit is always "full".
local function apply_fs(fs: Fs, no_new_privs: boolean): Section | nil, string
  if fs_mechanism() == "landlock" then
    local enf, err = landlock.restrict(plan.for_landlock(fs, no_new_privs))
    if not enf then return nil, err end
    return {
      state = enf.stripped ~= 0 and "degraded" or "full",
      mechanism = "landlock",
      abi = enf.abi,
      missing = landlock_missing(enf.stripped, enf.abi),
    }
  end
  local ok, err = apply_fs_unveil(fs)
  if not ok then return nil, err end
  return {state = "full", mechanism = "unveil", abi = 0, missing = ""}
end

--- Apply the sys (pledge) section and report what happened. Pledge has
--- no partial-enforcement concept here, so success is always "full".
local function apply_sys(sys: Sys): Section | nil, string
  local ok, err = pledge.apply(sys.promises, {exec = sys.exec_promises})
  if not ok then return nil, err end
  return {state = "full", mechanism = "pledge", abi = 0, missing = ""}
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
  if opts.strict and opts.best_effort then
    return "sandbox: strict and best_effort are mutually exclusive"
    .. " (strict already refuses any gap, so best_effort's skip never triggers)"
  end
  if opts.strict and opts.allow_unenforced then
    return "sandbox: strict and allow_unenforced are mutually exclusive"
    .. " (strict refuses any single skipped section, so tolerating an"
    .. " all-skipped result is meaningless)"
  end
  if opts.allow_unenforced and not opts.best_effort then
    return "sandbox: allow_unenforced requires best_effort"
    .. " (a section is only ever \"skipped\" when best_effort passed it)"
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
--- allow_unenforced, strict, no_new_privs, fs.optional, the sys
--- strings) take the later value when set. Returns a fresh Options
--- suitable for apply(); nil arguments are skipped.
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
      if o.allow_unenforced ~= nil then out.allow_unenforced = o.allow_unenforced end
      if o.strict ~= nil then out.strict = o.strict end
      if o.no_new_privs ~= nil then out.no_new_privs = o.no_new_privs end
    end
  end
  return out
end

--- Apply a sandbox policy to the current process. Irreversible.
---
--- Validated and checked against this host's enforceability for every
--- requested section *before* anything is applied, so a failure return
--- means nothing changed. Sections then apply in the only order that
--- works: `fs` first (landlock on Linux, unveil on OpenBSD), `sys`
--- (pledge) second — the reverse would let the pledge filter block the
--- filesystem-sandbox syscalls.
---
--- Fail-closed: a requested section this host cannot enforce returns
--- `nil, "sandbox: ... unsupported on this host"`. `best_effort = true`
--- skips such sections instead, and the Report says so per section
--- (`state == "skipped"`) — unless EVERY requested section ends up
--- skipped, in which case apply refuses (`nil, "sandbox: nothing
--- enforced (...)"`) rather than return a report nobody asked to trust
--- as success; `allow_unenforced = true` is the one named opt-in that
--- tolerates that. `strict = true` turns any section that would end
--- "degraded" or "skipped" into a refusal instead, before anything is
--- applied.
---
--- @param opts Options fs and/or sys sections plus tuning flags
--- @return Report? What was enforced, on success
--- @return string? Error message on failure
local function apply(opts: Options): Report | nil, string
  local verr = check_policy(opts)
  if verr then return nil, verr end

  local do_fs = opts.fs ~= nil
  local do_sys = opts.sys ~= nil
  local fs_ok = do_fs and fs_available()
  local sys_ok = do_sys and pledge.available()

  if do_fs and not fs_ok then
    if not opts.best_effort then
      return nil, "sandbox: " .. unsupported_text("fs")
    end
  end
  if do_sys and not sys_ok then
    if not opts.best_effort then
      return nil, "sandbox: " .. unsupported_text("sys")
    end
  end

  -- strict must fail BEFORE anything is applied, so a would-be-degraded
  -- landlock restrict is predicted rather than tried and undone
  -- (enforcement is irreversible): ABI < 2 strips REFER, ABI < 3 also
  -- strips TRUNCATE, from the always-full `ALL` request (R3 dropped the
  -- facade's own `handled` knob, so the running ABI is the only variable).
  if opts.strict and fs_ok and fs_mechanism() == "landlock" then
    local abi_version = landlock.abi() or 0
    local would_strip = 0
    if abi_version < 2 then would_strip = would_strip | landlock.REFER end
    if abi_version < 3 then would_strip = would_strip | landlock.TRUNCATE end
    if would_strip ~= 0 then
      return nil, "sandbox: strict: fs would be enforced in degraded form: "
      .. landlock_missing(would_strip, abi_version)
    end
  end

  local fs_section: Section = nil
  local sys_section: Section = nil

  if do_fs then
    if fs_ok then
      local section, err = apply_fs(opts.fs, opts.no_new_privs ~= false)
      if not section then return nil, "sandbox: fs: " .. tostring(err) end
      fs_section = section
    else
      fs_section = {state = "skipped", mechanism = fs_mechanism(), abi = 0,
        missing = unsupported_text("fs")}
    end
  end

  if do_sys then
    if sys_ok then
      local section, err = apply_sys(opts.sys)
      if not section then return nil, "sandbox: sys: " .. tostring(err) end
      sys_section = section
    else
      sys_section = {state = "skipped", mechanism = "pledge", abi = 0,
        missing = unsupported_text("sys")}
    end
  end

  local fs_skipped = fs_section == nil or fs_section.state == "skipped"
  local sys_skipped = sys_section == nil or sys_section.state == "skipped"
  if fs_skipped and sys_skipped and not opts.allow_unenforced then
    local reasons: {string} = {}
    if fs_section then reasons[#reasons + 1] = "fs: " .. fs_section.missing end
    if sys_section then reasons[#reasons + 1] = "sys: " .. sys_section.missing end
    return nil, "sandbox: nothing enforced (" .. table.concat(reasons, "; ") .. ")"
  end

  return {fs = fs_section, sys = sys_section}
end

local M: SandboxModule = {
  apply = apply,
  availability = availability,
  is_available = is_available,
  validate = validate,
  merge = merge,
}

return M
