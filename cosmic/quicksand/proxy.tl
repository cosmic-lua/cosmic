--- Allowlist HTTP CONNECT + plain-HTTP proxy for sandboxed egress.
---
--- The proxy binds inside a child's network namespace (the only thing
--- the sandboxed workload can reach) and dials upstream in a
--- different namespace, so a netns-isolated child can reach a narrow
--- set of approved hosts and nothing else. Non-public upstream IPs
--- are refused after DNS resolution (SSRF protection), and per-dial
--- resolution is deadline-bounded so a tarpitting resolver can't
--- wedge a worker.
---
--- start(opts) validates the allowlist, forks the listener into a
--- child process, and returns a ProxyHandle with the bound pid and
--- port. handle:stop() sends SIGTERM (escalating to SIGKILL after a
--- timeout) and reaps the child; handle:alive() is a non-blocking
--- liveness check. Implementation lives in cosmic.quicksand.proxy.*
--- (rules, http, dial, serve); advanced callers needing a non-forking
--- server can use cosmic.quicksand.proxy.serve directly.
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
--- Host specs: `host`, `host:port`, `host:*`, `*.suffix`,
--- `*.suffix:port`. An empty rule table is pass-through (allow, no
--- header injection). Header injection happens on plain HTTP only;
--- CONNECT is opaque. Malformed rules (unknown `type`, missing
--- fields) make start() fail loudly instead of degrading to
--- pass-through.
local unix = require("cosmo.unix")
local rules = require("cosmic.quicksand.proxy.rules")
local serve = require("cosmic.quicksand.proxy.serve")
local errno = require("cosmic.errno")

local type ProxyOptions = serve.ProxyOptions

--- Returned by start(). `stop()` sends SIGTERM and reaps the
--- listener, escalating to SIGKILL after `timeout_ms` (default 5000).
--- It is idempotent: once the child has been reaped, subsequent calls
--- are no-ops. `alive()` is a non-blocking liveness check.
local record ProxyHandle
  pid: integer
  port: integer
  stop: function(self: ProxyHandle, timeout_ms?: integer): boolean
  alive: function(self: ProxyHandle): boolean
end

local function now_ms(): integer
  local s, ns = unix.clock_gettime(unix.CLOCK_MONOTONIC)
  return (s) * 1000 + (ns) // 1000000
end

--- Send SIGTERM and reap the proxy child, escalating to SIGKILL when
--- it hasn't exited within timeout_ms (default 5000) so a hung worker
--- can't wedge the supervisor. Idempotent: once reaped (pid == 0),
--- short-circuits without re-signalling — a reused pid must never
--- receive a stray signal. Always returns true; signal/wait failures
--- are swallowed since the post-condition (child no longer ours) is
--- reached regardless.
local function handle_stop(self: ProxyHandle, timeout_ms?: integer): boolean
  if self.pid == 0 then return true end
  timeout_ms = timeout_ms or 5000
  local pid = self.pid
  pcall(unix.kill, pid, unix.SIGTERM)
  local deadline = now_ms() + timeout_ms
  while true do
    local gone = unix.wait(pid, unix.WNOHANG)
    if gone == pid then
      self.pid = 0
      return true
    end
    if now_ms() >= deadline then break end
    unix.nanosleep(0, 10 * 1000 * 1000)
  end
  pcall(unix.kill, pid, unix.SIGKILL)
  pcall(unix.wait, pid)
  self.pid = 0
  return true
end

--- Non-blocking health check: true while the proxy child is still
--- running, false once it has exited. On observing an exit, reaps
--- the zombie and clears pid to 0 so later calls short-circuit
--- without racing pid reuse.
local function handle_alive(self: ProxyHandle): boolean
  if self.pid == 0 then return false end
  local gone = unix.wait(self.pid, unix.WNOHANG)
  if gone == self.pid then
    self.pid = 0
    return false
  end
  return true
end

--- Fork a proxy listener into a child process. The allowlist is
--- validated before forking, so schema errors surface here. The
--- parent blocks until the child has bound and listened (the bound
--- port comes back over a pipe), so handle.port is valid immediately
--- on return.
---
--- @param opts ProxyOptions allowlist + binding + logging config
--- @return ProxyHandle? handle with pid, port, stop(), alive()
--- @return string? error message on failure
local function start(opts: ProxyOptions): ProxyHandle | nil, string
  opts = opts or {}
  -- cast: widen rule map for validator
  local vok, verr = rules.validate((opts.allowed_hosts or {}) as {string: any})
  if not vok then return nil, verr end
  local r, w = unix.pipe()
  if not r then return nil, errno.wrap(w, "pipe") end
  local rfd = r
  local wfd = w
  local pid, ferr = unix.fork()
  if not pid then
    unix.close(rfd)
    unix.close(wfd)
    return nil, errno.wrap(ferr, "fork")
  end
  if pid == 0 then
    -- Child: listen, report the bound port to the parent, then serve.
    unix.close(rfd)
    local srv, nerr = serve.new(opts)
    if not srv then
      unix.write(wfd, string.pack("<i4", -1))
      unix.close(wfd)
      io.stderr:write("proxy.start: " .. tostring(nerr) .. "\n")
      unix.exit(1)
    end
    -- srv is a `Server | nil` record union; tl 0.24.8 does not narrow
    -- record unions through the nil-check above, so reach the methods
    -- through a map view at the proven non-nil use site.
    local server = srv as {string: any} -- cast: record union after guard
    -- cast: function shape from map view
    local listen_fn = server.listen as function(): (integer | nil, string)
    local port_fn = server.port as function(): integer -- cast: function shape
    local serve_fn = server.serve_forever as function() -- cast: function shape
    local fd, lerr = listen_fn()
    if not fd then
      unix.write(wfd, string.pack("<i4", -1))
      unix.close(wfd)
      io.stderr:write("proxy.start: listen: " .. tostring(lerr) .. "\n")
      unix.exit(1)
    end
    unix.write(wfd, string.pack("<i4", port_fn()))
    unix.close(wfd)
    serve_fn()
    unix.exit(0)
  end
  -- Parent: read the bound port, then return the handle.
  unix.close(wfd)
  local packed = unix.read(rfd, 4)
  unix.close(rfd)
  if not packed or #packed < 4 then
    pcall(unix.kill, pid, unix.SIGTERM)
    pcall(unix.wait, pid)
    return nil, "proxy child failed to report a port"
  end
  local port = (string.unpack("<i4", packed))
  if port < 0 then
    pcall(unix.wait, pid)
    return nil, "proxy child failed to listen"
  end
  local h: ProxyHandle = {pid = pid, port = port}
  h.stop = handle_stop
  h.alive = handle_alive
  return h
end

local record ProxyModule
  type ProxyHandle = ProxyHandle
  type ProxyOptions = ProxyOptions
  type ProxyRule = serve.ProxyRule
  start: function(opts: ProxyOptions): ProxyHandle | nil, string
end

local M: ProxyModule = {
  start = start,
}

return M
