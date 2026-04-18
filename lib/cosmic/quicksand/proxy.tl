--- Allowlist HTTP CONNECT + plain-HTTP proxy for sandboxed egress.
---
--- Typed wrapper over cosmo.sandbox.proxy. The proxy binds inside a
--- child's network namespace (the only thing the sandboxed workload
--- can reach) and dials upstream in a different namespace, so a
--- netns-isolated child can reach a narrow set of approved hosts and
--- nothing else.
---
--- start(opts) forks the listener into a child process and returns a
--- ProxyHandle with the bound pid and port. handle:stop() sends
--- SIGTERM and reaps the child.
---
--- Rule schema (allowed_hosts):
---
---   {
---     ["api.example.com:443"]     = {},                  -- pass-through
---     ["*.githubusercontent.com"] = {},                  -- any port
---     ["internal.example.com:80"] = { type = "bearer",
---                                     token = "..." },   -- inject header
---     ["legacy.example.com:80"]   = { type = "basic",
---                                     username = "u",
---                                     password = "p" },
---     ["api.example.com:80"]      = { type = "header",
---                                     header_name = "x-api-key",
---                                     header_value = "..." },
---   }
---
--- Host specs: `host`, `host:port`, `host:*`, `*.suffix`, `*.suffix:port`.
--- An empty rule table is pass-through (allow, no header injection).
--- Header injection happens on plain HTTP only; CONNECT is opaque.
local cproxy = require("cosmo.sandbox.proxy")
local Errno = require("cosmic.errno").Errno
local unix = require("cosmo.unix")

local function wrap_err(err: any, fallback: string): string
  if not err then return fallback end
  local e = err as Errno
  if e.doc then return e:doc() end
  return tostring(err)
end

--- A single allowlist rule. `type` nil means pass-through (allowed,
--- no header injection). Fields not relevant to the chosen type are
--- ignored. Unknown `type` values behave as pass-through.
local record ProxyRule
  type: string -- "bearer" | "basic" | "header" | nil
  token: string -- bearer
  username: string -- basic
  password: string -- basic
  header_name: string -- header
  header_value: string -- header
end

--- Options for start() / new().
local record ProxyOptions
  bind_ip: integer -- default cosmo.ParseIp("127.0.0.1")
  bind_port: integer -- default 3128; 0 = ephemeral
  allowed_hosts: {string: ProxyRule}
  upstream_ns_fd: integer -- netns fd to dial in; nil = current ns
  log_level: string -- "quiet" | "info" | "debug" (default "info")
  log_format: string -- "text" | "json"            (default "text")
  log_file: string -- path; default stderr
  accept_backlog: integer -- default 32
  on_log: function({string: any})
end

--- Returned by start(). `stop()` sends SIGTERM to the listener
--- process and reaps it via waitpid.
local record ProxyHandle
  pid: integer
  port: integer
  stop: function(self: ProxyHandle)
end

--- Fork a proxy listener into a child process. The parent blocks
--- until the child has bound and listened, so handle.port is valid
--- immediately on return.
---
--- @param opts ProxyOptions allowlist + binding + logging config
--- @return ProxyHandle? handle with pid, port, stop()
--- @return string? error message on failure
local function start(opts: ProxyOptions): ProxyHandle, string
  local h, err = cproxy.start(opts as any) as(ProxyHandle, any)
  if not h then return nil, wrap_err(err, "proxy.start failed") end
  -- The underlying handle:stop() already does SIGTERM + waitpid.
  -- Wrap it anyway so callers can rely on it being idempotent: after
  -- stop, subsequent calls are no-ops.
  local raw_stop = h.stop
  h.stop = function(self: ProxyHandle)
    if self.pid == 0 then return end
    raw_stop(self)
    -- Belt-and-suspenders: if the raw stop raced a signal delivery
    -- and left the child around, force-reap now.
    local u = unix as {string: any}
    local ukill = u.kill as function(integer, integer): boolean
    local uwait = u.wait as function(integer): integer
    pcall(ukill, self.pid, 9)
    pcall(uwait, self.pid)
    self.pid = 0
  end
  return h
end

local record ProxyModule
  start: function(opts: ProxyOptions): ProxyHandle, string
end

local M: ProxyModule = {
  start = start,
}

return M
