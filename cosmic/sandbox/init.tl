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
local landlock = require("cosmic.sandbox.landlock")
local pledge = require("cosmic.sandbox.pledge")
local plan = require("cosmic.sandbox.plan")
local section = require("cosmic.sandbox.section")

--- Filesystem policy; the record (ro/rw/exec allowlists plus
--- `optional`) is defined in cosmic.sandbox.plan beside its mapping.
local type Fs = plan.Fs

--- Network policy (per-port TCP, Landlock ABI 4+), defined in plan beside its mapping.
local type Net = plan.Net

--- Signal / abstract-UNIX-socket scoping (Landlock ABI 6+), defined in plan beside its mapping.
local type Scope = plan.Scope

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
  net: Net
  scope: Scope
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

--- One section's enforcement result, defined in cosmic.sandbox.section
--- beside the code that builds it.
local type Section = section.Section

--- Per-section report from a successful apply: `fs`/`sys`/`net`/`scope`
--- are set exactly when requested. Replaces the old two-boolean shape,
--- which could not tell full enforcement from a landlock restrict that
--- silently dropped TRUNCATE/REFER.
local record Report
  fs: Section
  sys: Section
  net: Section
  scope: Section
end

local record SandboxModule
  type Fs = Fs
  type Sys = Sys
  type Net = Net
  type Scope = Scope
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

--- Report what this host can enforce, per section. Sections requested
--- in `apply` beyond this fail closed (or are skipped under
--- `best_effort`).
---
--- @return Availability per-section enforceability
local function availability(): Availability
  local mech = section.fs_mechanism()
  local fs_abi = 0
  if mech == "landlock" then
    fs_abi = landlock.abi() or 0
  end
  return {
    fs = {available = section.fs_available(), mechanism = mech, abi = fs_abi},
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
  if opts == nil or (opts.fs == nil and opts.sys == nil and opts.net == nil
    and opts.scope == nil) then
    return "sandbox: policy must set fs, sys, net, and/or scope"
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
  if opts.net then
    local nerr = plan.validate_net(opts.net); if nerr then return nerr end
  end
  if opts.scope then
    local serr = plan.validate_scope(opts.scope); if serr then return serr end
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

local function merged_int_list(a: {integer}, b: {integer}): {integer}
  if a == nil and b == nil then return nil end
  local out: {integer} = {}
  local seen: {integer: boolean} = {}
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
      if o.net then
        local nbase: Net = out.net or {}
        out.net = {
          connect_tcp = merged_int_list(nbase.connect_tcp, o.net.connect_tcp),
          bind_tcp = merged_int_list(nbase.bind_tcp, o.net.bind_tcp),
        }
      end
      if o.scope then
        local scbase: Scope = out.scope or {}
        out.scope = {
          signal = scbase.signal or o.scope.signal,
          abstract_unix = scbase.abstract_unix or o.scope.abstract_unix,
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
--- @param opts Options fs, sys, net, and/or scope sections plus tuning flags
--- @return Report? What was enforced, on success
--- @return string? Error message on failure
local function apply(opts: Options): Report | nil, string
  local verr = check_policy(opts)
  if verr then return nil, verr end

  local do_fs = opts.fs ~= nil
  local do_sys = opts.sys ~= nil
  local do_net = opts.net ~= nil
  local do_scope = opts.scope ~= nil
  local fs_ok = do_fs and section.fs_available()
  local sys_ok = do_sys and pledge.available()
  local net_ok = do_net and landlock.available() and (landlock.abi() or 0) >= 4
  local scope_ok = do_scope and landlock.available() and (landlock.abi() or 0) >= 6

  if do_fs and not fs_ok and not opts.best_effort then return nil, "sandbox: " .. section.unsupported_text("fs") end
  if do_sys and not sys_ok and not opts.best_effort then return nil, "sandbox: " .. section.unsupported_text("sys") end
  if do_net and not net_ok and not opts.best_effort then return nil, "sandbox: " .. section.unsupported_text("net") end
  if do_scope and not scope_ok and not opts.best_effort then return nil, "sandbox: " .. section.unsupported_text("scope") end

  -- strict must fail BEFORE anything is applied, so a would-be-degraded landlock
  -- restrict is predicted rather than tried and undone (enforcement is irreversible):
  -- ABI < 2 strips REFER, ABI < 3 strips TRUNCATE, ABI < 5 strips IOCTL_DEV,
  -- ABI < 9 strips RESOLVE_UNIX from the always-full `ALL` request.
  if opts.strict and fs_ok and section.fs_mechanism() == "landlock" then
    local abi_version = landlock.abi() or 0
    local would_strip = 0
    if abi_version < 2 then would_strip = would_strip | landlock.REFER end
    if abi_version < 3 then would_strip = would_strip | landlock.TRUNCATE end
    if abi_version < 5 then would_strip = would_strip | landlock.IOCTL_DEV end
    if abi_version < 9 then would_strip = would_strip | landlock.RESOLVE_UNIX end
    if would_strip ~= 0 then
      return nil, "sandbox: strict: fs would be enforced in degraded form: "
      .. section.landlock_missing(would_strip, abi_version)
    end
  end

  local fs_section, fs_err = section.one_section(do_fs, fs_ok, section.fs_mechanism(), 0, "fs", function(): Section | nil, string return section.apply_fs(opts.fs, opts.no_new_privs ~= false) end)
  if fs_err then return nil, fs_err end

  local sys_section, sys_err = section.one_section(do_sys, sys_ok, "pledge", 0, "sys", function(): Section | nil, string return section.apply_sys(opts.sys.promises, opts.sys.exec_promises) end)
  if sys_err then return nil, sys_err end

  local net_section, net_err = section.one_section(do_net, net_ok, "landlock", landlock.abi() or 0, "net", function(): Section | nil, string return section.apply_net(opts.net, opts.no_new_privs ~= false) end)
  if net_err then return nil, net_err end

  local scope_section, scope_err = section.one_section(do_scope, scope_ok, "landlock", landlock.abi() or 0, "scope", function(): Section | nil, string return section.apply_scope(opts.scope, opts.no_new_privs ~= false) end)
  if scope_err then return nil, scope_err end

  local function skipped(s: Section | nil): boolean return s == nil or s.state == "skipped" end
  if skipped(fs_section) and skipped(sys_section) and skipped(net_section) and skipped(scope_section)
  and not opts.allow_unenforced then
    local reasons: {string} = {}
    if fs_section then reasons[#reasons + 1] = "fs: " .. fs_section.missing end
    if sys_section then reasons[#reasons + 1] = "sys: " .. sys_section.missing end
    if net_section then reasons[#reasons + 1] = "net: " .. net_section.missing end
    if scope_section then reasons[#reasons + 1] = "scope: " .. scope_section.missing end
    return nil, "sandbox: nothing enforced (" .. table.concat(reasons, "; ") .. ")"
  end

  -- Guarded rather than a plain table constructor: fs_section etc. are Section |
  -- nil (nil exactly when that section was not requested), while Report's
  -- fields are declared non-optional — narrow each one here so an absent
  -- section leaves its field unset, precisely as the table constructor did,
  -- without widening Report's fields for every reader of the exported type.
  local report: Report = {}
  if fs_section then report.fs = fs_section end
  if sys_section then report.sys = sys_section end
  if net_section then report.net = net_section end
  if scope_section then report.scope = scope_section end
  return report
end

local M: SandboxModule = {
  apply = apply,
  availability = availability,
  is_available = is_available,
  validate = validate,
  merge = merge,
}

return M
