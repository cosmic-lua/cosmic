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
--- Full schema in `BoxOpts` below.
---
--- The capability probe is loaded lazily to avoid a require cycle with
--- cosmic.quicksand (which re-exports Box from its umbrella). The
--- fork / exec orchestration lives in cosmic.quicksand.box.run and is
--- required on demand from `run()` so construction stays cheap.
local box_merge = require("cosmic.quicksand.box.merge")

local record CapsModule
  capabilities: function(): {string: boolean}
end

local function caps(): {string: boolean}
  local qs = require("cosmic.quicksand") as CapsModule
  return qs.capabilities()
end

--- A single allowlist rule for `net.allow`. Mirrors
--- cosmic.quicksand.proxy.ProxyRule — empty table = pass-through.
local record NetRule
  type: string
  token: string
  username: string
  password: string
  header_name: string
  header_value: string
end

local record NetOpts
  proxy_env: boolean -- set HTTP(S)_PROXY in the child env
  allow: {string: NetRule}
  log_level: string -- "quiet" | "info" | "debug"
  resolve_timeout_ms: integer -- per-dial DNS budget; <=0 opts out
end

local record FsOpts
  ro: {string}
  rw: {string}
  exec: {string}
  deny: {string}
end

local record ProcOpts
  no_new_privs: boolean
  uid: integer
  gid: integer
  pledge: string
end

local record EnvOpts
  keep: {string}
  set: {string: string}
end

--- Full box policy. Every field is optional; omitting a section skips
--- that subsystem. Scalars default to nil (i.e. no policy); list fields
--- default to empty.
local record BoxOpts
  hostname: string
  fs: FsOpts
  net: NetOpts
  proc: ProcOpts
  env: EnvOpts
  cwd: string
  pid_ns: boolean -- set false to opt out of CLONE_NEWPID isolation
end

--- Box instance. `run(argv)` returns an integer exit code on success
--- or nil + error on failure. `close()` releases any parent-held
--- resources; idempotent and safe to call after `run`.
local record Box
  opts: BoxOpts
  _closed: boolean
  run: function(self: Box, argv: {string}): integer, string
  close: function(self: Box): boolean
end

-- Validate structural shape only — we cannot test syscall-level
-- feasibility here; that is the job of run()'s capability preflight.
local function validate(opts: BoxOpts): boolean, string
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
  end
  local net = opts.net
  if net and net.allow ~= nil and type(net.allow) ~= "table" then
    return false, "net.allow must be a table"
  end
  local fs = opts.fs
  if fs then
    for _, name in ipairs({"ro", "rw", "exec", "deny"}) do
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
local function preflight(opts: BoxOpts): boolean, string
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
    if fs and fs.deny and not has_fs then
      return false, "quicksand: fs.deny requires at least one of fs.ro, fs.rw, or fs.exec (deny is informational; landlock is allowlist-based)"
    end
    if has_fs and not c.landlock then
      return false, "quicksand: landlock unavailable (fs policy requested)"
    end
    if opts.proc and opts.proc.pledge and not c.pledge then
      return false, "quicksand: pledge unavailable"
    end
  end
  return true
end

local record RunModule
  run: function(opts: {string: any}, argv: {string}): integer, string
end

local function run(self: Box, argv: {string}): integer, string
  if self._closed then
    return nil, "quicksand: box already closed"
  end
  if type(argv) ~= "table" or #argv == 0 then
    return nil, "quicksand: run(argv) requires a non-empty argv"
  end
  local ok, err = preflight(self.opts)
  if not ok then return nil, err end
  local rm = require("cosmic.quicksand.box.run") as RunModule
  return rm.run(self.opts as {string: any}, argv)
end

local function close(self: Box): boolean
  if self._closed then return true end
  self._closed = true
  return true
end

--- Build a Box from an options table. Validates structural shape; a
--- bad `opts` returns nil + error without touching syscalls.
---
--- @param opts BoxOpts? policy (all fields optional)
--- @return Box? box instance on success
--- @return string? error message on failure
local function new(opts?: BoxOpts): Box, string
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
--- (fs.ro, fs.rw, fs.exec, fs.deny, env.keep): concat + dedupe. Maps
--- (net.allow, env.set): per-key later wins. Returns a fresh table
--- suitable for `Box.new`.
---
--- @param ... BoxOpts policy tables; nil entries are skipped
--- @return BoxOpts merged policy
local function merge(...: BoxOpts): BoxOpts
  return box_merge.merge(...) as BoxOpts
end

local record BoxModule
  new: function(opts?: BoxOpts): Box, string
  merge: function(...: BoxOpts): BoxOpts
end

local M: BoxModule = {
  new = new,
  merge = merge,
}

return M
