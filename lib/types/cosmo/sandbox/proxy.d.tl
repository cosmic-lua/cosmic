-- type declarations for cosmo.sandbox.proxy
--
-- Raw cosmo.sandbox.proxy surface. cosmic.quicksand.proxy wraps this
-- with typed ProxyRule / Auth records and cosmic's value,string error
-- shape. Callers should prefer cosmic.quicksand.proxy over these.

local record proxy
  _VERSION: string

  --- Forks, listens, reports the bound port back via a pipe to the
  --- parent, and returns { pid, port, stop }. The child runs
  --- serve_forever(). opts mirrors the listen() schema plus an
  --- optional upstream_ns fd.
  start: function(opts: any): any, string

  --- Allocate a listener in the current process (no fork). Returns an
  --- object the caller drives with serve_forever() / serve_once().
  new: function(opts: any): any, string
end

return proxy
