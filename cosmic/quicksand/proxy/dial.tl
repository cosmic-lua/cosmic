--- Upstream dialing for the cosmic.quicksand.proxy egress proxy:
--- bounded DNS resolution and cross-namespace TCP connects with SSRF
--- protection.
---
--- The proxy listens inside a child network namespace and dials
--- upstream in a different one (typically the parent's); dial() joins
--- the upstream namespace with setns() first, so it must run in a
--- per-connection fork where the namespace switch can't leak into
--- other connections.
local unix = require("cosmo.unix")
local cosmo = require("cosmo")
local errno = require("cosmic.errno")

--- Resolve `host` to an IPv4 integer. Literal IPs parse immediately;
--- hostnames go through cosmo.ResolveIp, which uses the system
--- resolver in the *current* netns — call after setns() to the
--- upstream namespace.
---
--- When `timeout_ms` is non-nil the lookup is bounded by the C
--- binding's own deadline (cosmopolitan#199): past it, ResolveIp
--- disowns its worker and returns a "DNS lookup timed out" error, so
--- a hostile or tarpitting resolver can't wedge a per-connection
--- worker past its budget. Literal IPs never wait.
---
--- @param host string hostname or literal IPv4
--- @param timeout_ms integer? resolution deadline (nil = unbounded)
--- @param resolver function? test seam returning (ip, err); called
---   without a deadline — bounded lookups are the C binding's job
--- @return integer? IPv4 address as an integer
--- @return string? error message on failure
local function resolve(host: string, timeout_ms: integer,
    resolver: function(string): integer, any): integer | nil, string
  local ip = cosmo.ParseIp(host)
  if ip and ip ~= -1 then return ip end
  if resolver then
    local resolved, rerr = resolver(host)
    if not resolved then return nil, errno.wrap(rerr, "resolve") end
    return resolved
  end
  local resolved, rerr = cosmo.ResolveIp(host, timeout_ms)
  if not resolved then return nil, rerr end
  return resolved
end

--- Open a TCP connection to (host, port) in the namespace identified
--- by `upstream_ns_fd`, falling back to the current namespace when
--- the fd is nil. `resolve_timeout_ms` (optional) bounds DNS
--- resolution per dial.
---
--- Non-public IPs are refused after resolution to prevent SSRF: this
--- covers loopback (127/8), link-local (169.254/16) including the
--- cloud metadata endpoint, RFC1918, CGNAT (100.64/10), 0.0.0.0/8,
--- and other reserved ranges — on both CONNECT and plain-HTTP paths.
---
--- The upstream socket is SOCK_CLOEXEC so it can't leak into an
--- exec'd child via an accidental fork/exec ordering change.
---
--- @param host string hostname or literal IPv4
--- @param port integer TCP port
--- @param upstream_ns_fd integer? netns fd to dial in (nil = current)
--- @param resolve_timeout_ms integer? per-dial DNS deadline
--- @return integer? connected socket fd
--- @return string? error message on failure
local function dial(host: string, port: integer, upstream_ns_fd: integer,
    resolve_timeout_ms: integer): integer | nil, string
  if upstream_ns_fd then
    local ok, err = unix.setns(upstream_ns_fd, unix.CLONE_NEWNET)
    if not ok then return nil, errno.wrap(err, "setns") end
  end
  local ip, rerr = resolve(host, resolve_timeout_ms, nil)
  if not ip then return nil, rerr end
  if not cosmo.IsPublicIp(ip) then
    return nil, "request to private network blocked (SSRF protection)"
  end
  local sk, serr = unix.socket(unix.AF_INET,
    (unix.SOCK_STREAM) | (unix.SOCK_CLOEXEC), 0)
  if not sk then return nil, errno.wrap(serr, "socket") end
  local skfd = sk
  local ok, cerr = unix.connect(skfd, ip, port)
  if not ok then
    unix.close(skfd)
    return nil, errno.wrap(cerr, "connect")
  end
  return skfd
end

local record DialModule
  resolve: function(string, integer, function(string): (integer, any)):
  integer | nil, string
  dial: function(string, integer, integer, integer): integer | nil, string
end

local M: DialModule = {
  resolve = resolve,
  dial = dial,
}

return M
