--- Declarative box builder.
---
--- Composes the quicksand primitives (netns, proxy, proc) plus
--- cosmic.landlock / cosmic.pledge into a single `box:run(argv)` call
--- that returns an exit code.
---
--- Usage:
---
---     local quicksand = require("cosmic.quicksand")
---     local box = quicksand.Box.new{
---       fs = { ro = { "/usr" }, rw = { "/tmp" } },
---       net = { allow = { ["api.example.com:443"] = {} } },
---       proc = { no_new_privs = true },
---       cwd = "/tmp",
---     }
---     os.exit(assert(box:run({ "/usr/bin/bash", "-c", "make test" })))
---
--- Options are plain tables, composable with `Box.merge(base, over)`.
--- Full schema in `BoxOptions` below.
---
--- The capability probe is loaded lazily to avoid a require cycle with
--- cosmic.quicksand (which re-exports Box from its umbrella). The
--- fork / exec orchestration lives in cosmic.quicksand.box.run and is
--- required on demand from `run()` so construction stays cheap.
local box_merge = require("cosmic.quicksand.box.merge")
local types = require("cosmic.quicksand.types")

--- The policy schema lives in cosmic.quicksand.types (shared with the
--- fork/exec orchestrator and the umbrella); re-exported below so
--- callers can keep writing `Box.BoxOptions` etc.
local type BoxOptions = types.BoxOptions
local type FsOpts = types.FsOpts
local type NetRule = types.NetRule
local type NetRuleType = types.NetRuleType
local type LogLevel = types.LogLevel

local record CapsModule
  capabilities: function(): types.Capabilities
end

local function caps(): types.Capabilities
  local qs = require("cosmic.quicksand") as CapsModule
  return qs.capabilities()
end

--- Box instance. `run(argv)` returns an integer exit code on success
--- or nil + error on failure. `close()` releases any parent-held
--- resources; idempotent and safe to call after `run`.
local record Box
  opts: BoxOptions
  _closed: boolean
  run: function(self: Box, argv: {string}): integer | nil, string
  close: function(self: Box): boolean
end

-- Validate structural shape only — we cannot test syscall-level
-- feasibility here; that is the job of run()'s capability preflight.
local function validate(opts: BoxOptions): boolean, string
  if opts == nil then return true end
  if opts.cwd ~= nil and type(opts.cwd) ~= "string" then
    return false, "cwd must be a string"
  end
  if opts.hostname ~= nil and type(opts.hostname) ~= "string" then
    return false, "hostname must be a string"
  end
  local proc = opts.proc
  if proc then
    if proc.uid ~= nil and type(proc.uid) ~= "number" then
      return false, "proc.uid must be a number"
    end
    if proc.gid ~= nil and type(proc.gid) ~= "number" then
      return false, "proc.gid must be a number"
    end
    if proc.pledge ~= nil and type(proc.pledge) ~= "string" then
      return false, "proc.pledge must be a string"
    end
    if proc.keep_caps ~= nil and type(proc.keep_caps) ~= "table" then
      return false, "proc.keep_caps must be a list of capability names"
    end
  end
  local net = opts.net
  if net and net.allow ~= nil and type(net.allow) ~= "table" then
    return false, "net.allow must be a table"
  end
  local fs = opts.fs
  if fs then
    if (fs as {string: any}).deny ~= nil then
      return false, "fs.deny was removed: the fs policy is an allowlist,"
      .. " every path not in fs.ro/rw/exec is already denied"
    end
    for _, name in ipairs({"ro", "rw", "exec"}) do
      local v = (fs as {string: any})[name]
      if v ~= nil and type(v) ~= "table" then
        return false, "fs." .. name .. " must be a list"
      end
    end
  end
  return true
end

-- Check that every enabled feature can be honored by the host. Returns
-- a specific error naming the first missing capability so callers can
-- distinguish "not on Linux" from "landlock unavailable" etc.
local function preflight(opts: BoxOptions): boolean, string
  local c = caps()
  if not c.linux then
    return false, "quicksand: Linux only"
  end
  if not c.user_ns then
    return false, "quicksand: user namespaces unavailable"
  end
  if opts then
    if opts.net and not c.net_ns then
      return false, "quicksand: network namespaces unavailable"
    end
    if opts.hostname and not c.uts_ns then
      return false, "quicksand: UTS namespace unavailable (hostname requested)"
    end
    local fs = opts.fs
    local has_fs = fs and (fs.ro or fs.rw or fs.exec)
    if has_fs and not c.landlock then
      return false, "quicksand: landlock unavailable (fs policy requested)"
    end
    if opts.proc and opts.proc.pledge and not c.pledge then
      return false, "quicksand: pledge unavailable"
    end
    local pr = opts.proc
    local wants_caps = pr and (pr.drop_caps or (pr.keep_caps and #pr.keep_caps > 0))
    if wants_caps and not c.caps then
      return false, "quicksand: capability bounding-set control unavailable (proc.drop_caps/keep_caps requested)"
    end
  end
  return true
end

local record RunModule
  run: function(opts: BoxOptions, argv: {string}): integer | nil, string
end

local function run(self: Box, argv: {string}): integer | nil, string
  if self._closed then
    return nil, "quicksand: box already closed"
  end
  if type(argv) ~= "table" or #argv == 0 then
    return nil, "quicksand: run(argv) requires a non-empty argv"
  end
  local ok, err = preflight(self.opts)
  if not ok then return nil, err end
  local rm = require("cosmic.quicksand.box.run") as RunModule
  return rm.run(self.opts, argv)
end

local function close(self: Box): boolean
  if self._closed then return true end
  self._closed = true
  return true
end

--- Build a Box from an options table. Validates structural shape; a
--- bad `opts` returns nil + error without touching syscalls.
---
--- @param opts BoxOptions? policy (all fields optional)
--- @return Box? box instance on success
--- @return string? error message on failure
local function new(opts?: BoxOptions): Box | nil, string
  local ok, err = validate(opts)
  if not ok then return nil, err end
  local j: Box = {
    opts = opts or {},
    _closed = false,
    run = run,
    close = close,
  }
  return j
end

--- Compose policy tables left-to-right. Scalars: later wins. Lists
--- (fs.ro, fs.rw, fs.exec, env.keep): concat + dedupe. Maps
--- (net.allow, env.set): per-key later wins. Returns a fresh table
--- suitable for `Box.new`.
---
--- @param ... BoxOptions policy tables; nil entries are skipped
--- @return BoxOptions merged policy
local function merge(...: BoxOptions): BoxOptions
  return box_merge.merge(...) as BoxOptions
end

local record BoxModule
  type Box = Box
  type BoxOptions = BoxOptions
  type FsOpts = FsOpts
  type NetRule = NetRule
  type NetRuleType = NetRuleType
  type LogLevel = LogLevel
  new: function(opts?: BoxOptions): Box | nil, string
  merge: function(...: BoxOptions): BoxOptions
end

local M: BoxModule = {
  new = new,
  merge = merge,
}

return M
