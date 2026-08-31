--- Per-section enforcement: applies one fs/sys/net/scope section
--- through its mechanism and builds the `Section` the facade's Report
--- carries for it. Internal shard under cosmic/sandbox/, split out
--- purely to keep cosmic/sandbox/init.tl under the file-length cap —
--- plan.tl already holds the parallel "policy -> mechanism options"
--- mapping; this holds the mirror "mechanism result -> Section" side.
local cosmo = require("cosmo")
local landlock = require("cosmic.sandbox.landlock")
local pledge = require("cosmic.sandbox.pledge")
local unveil = require("cosmic.sandbox.unveil")
local plan = require("cosmic.sandbox.plan")

local type Fs = plan.Fs
local type Net = plan.Net
local type Scope = plan.Scope

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

local record SectionModule
  type Section = Section
  fs_mechanism: function(): string
  fs_available: function(): boolean
  landlock_missing: function(stripped: integer, abi_version: integer): string
  unsupported_text: function(name: string): string
  apply_fs: function(fs: Fs, no_new_privs: boolean): Section | nil, string
  apply_sys: function(promises: string, exec_promises: string): Section | nil, string
  apply_net: function(net: Net, no_new_privs: boolean): Section | nil, string
  apply_scope: function(scope: Scope, no_new_privs: boolean): Section | nil, string
  one_section: function(requested: boolean, ok: boolean, mechanism: string, abi: integer,
  name: string, apply_fn: function(): Section | nil, string): Section | nil, string
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

-- Render which of the strippable Landlock rights are set in `stripped`,
-- plus the ABI that stripped them. Used both for a real degraded
-- Section's `missing` and for strict's pre-enforcement refusal message,
-- so the wording matches whichever path produced it.
local function landlock_missing(stripped: integer, abi_version: integer): string
  if stripped == 0 then return "" end
  local names: {string} = {}
  if stripped & landlock.REFER ~= 0 then names[#names + 1] = "REFER" end
  if stripped & landlock.TRUNCATE ~= 0 then names[#names + 1] = "TRUNCATE" end
  if stripped & landlock.IOCTL_DEV ~= 0 then names[#names + 1] = "IOCTL_DEV" end
  if stripped & landlock.RESOLVE_UNIX ~= 0 then names[#names + 1] = "RESOLVE_UNIX" end
  return table.concat(names, ", ") .. " unsupported on this kernel (Landlock ABI "
  .. tostring(abi_version) .. ")"
end

--- Human text for a section this host cannot enforce at all — used
--- both for the fail-closed error and for a best_effort "skipped"
--- Section's `missing`.
local function unsupported_text(name: string): string
  if name == "fs" then
    return "fs unsupported on this host"
    .. " (needs Landlock on Linux, or unveil on OpenBSD)"
  end
  if name == "net" then
    return "net unsupported on this host (needs Linux Landlock ABI >= 4; this kernel is ABI " .. tostring(landlock.abi() or 0) .. ")"
  end
  if name == "scope" then
    return "scope unsupported on this host (needs Linux Landlock ABI >= 6; this kernel is ABI " .. tostring(landlock.abi() or 0) .. ")"
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
local function apply_sys(promises: string, exec_promises: string): Section | nil, string
  local ok, err = pledge.apply(promises, {exec = exec_promises})
  if not ok then return nil, err end
  return {state = "full", mechanism = "pledge", abi = 0, missing = ""}
end

-- Apply the net section via landlock. ABI 4 is a hard gate, not a bitmask like fs's, so success is always "full".
local function apply_net(net: Net, no_new_privs: boolean): Section | nil, string
  local enf, err = landlock.restrict(plan.for_landlock_net(net, no_new_privs))
  if not enf then return nil, err end
  return {state = "full", mechanism = "landlock", abi = enf.abi, missing = ""}
end

-- Apply the scope section via landlock. ABI 6 is a hard gate, not a bitmask like fs's, so success is always "full".
local function apply_scope(scope: Scope, no_new_privs: boolean): Section | nil, string
  local enf, err = landlock.restrict(plan.for_landlock_scope(scope, no_new_privs))
  if not enf then return nil, err end
  return {state = "full", mechanism = "landlock", abi = enf.abi, missing = ""}
end

-- One section's apply-or-skip, shared by fs/sys/net/scope: not requested
-- is a no-op; not enforceable builds the "skipped" Section the fail-closed
-- check above already let through under best_effort; else apply_fn runs.
local function one_section(requested: boolean, ok: boolean, mechanism: string, abi: integer, name: string, apply_fn: function(): Section | nil, string): Section | nil, string
  if not requested then return nil end
  if not ok then return {state = "skipped", mechanism = mechanism, abi = abi, missing = unsupported_text(name)} end
  local sec, err = apply_fn()
  if not sec then return nil, "sandbox: " .. name .. ": " .. tostring(err) end
  return sec
end

local M: SectionModule = {
  fs_mechanism = fs_mechanism,
  fs_available = fs_available,
  landlock_missing = landlock_missing,
  unsupported_text = unsupported_text,
  apply_fs = apply_fs,
  apply_sys = apply_sys,
  apply_net = apply_net,
  apply_scope = apply_scope,
  one_section = one_section,
}

return M
