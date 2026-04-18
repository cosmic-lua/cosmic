-- type declarations for cosmo.sandbox.proxy
--
-- Raw cosmo.sandbox.proxy surface. cosmic.quicksand.proxy wraps this
-- with typed ProxyRule / Auth records and cosmic's value,string error
-- shape. Callers should prefer cosmic.quicksand.proxy over these.

-- handle:stop() is idempotent and escalates to SIGKILL after a
-- timeout (default 5000ms). handle:alive() is a non-blocking
-- liveness check that reaps the child on observed exit.
local record Handle
  pid: integer
  port: integer
  stop: function(self: Handle, timeout_ms?: integer)
  alive: function(self: Handle): boolean
end

local record proxy
  _VERSION: string

  --- Forks, listens, reports the bound port back via a pipe to the
  --- parent, and returns a Handle. The child runs serve_forever().
  --- opts mirrors the listen() schema plus an optional upstream_ns
  --- fd, resolve_timeout_ms, and on_log sink. Raises on invalid
  --- allowed_hosts rules (unknown type, missing required fields).
  start: function(opts: any): Handle, any

  --- Allocate a listener in the current process (no fork). Returns an
  --- object the caller drives with serve_forever() / serve_once().
  new: function(opts: any): any, any
end

return proxy
