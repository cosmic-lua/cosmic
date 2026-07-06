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
--- otherwise the lookup goes through `resolver` (default
--- cosmo.ResolveIp, which uses the system resolver in the *current*
--- netns — call after setns() to the upstream namespace).
---
--- When `timeout_ms` is non-nil the lookup runs in a forked helper
--- and the parent polls the result pipe; past the deadline the helper
--- is SIGKILL'd and (nil, "resolve timeout") is returned, so a
--- hostile or tarpitting resolver can't wedge a per-connection worker
--- past its budget. Literal IPs skip the fork entirely.
---
--- @param host string hostname or literal IPv4
--- @param timeout_ms integer? resolution deadline (nil = unbounded)
--- @param resolver function? test seam returning (ip, err); defaults
---   to cosmo.ResolveIp
--- @return integer? IPv4 address as an integer
--- @return string? error message on failure
local function resolve(host: string, timeout_ms: integer,
    resolver: function(string): integer, any): integer | nil, string
  local ip = cosmo.ParseIp(host)
  if ip and ip ~= -1 then return ip as integer end
  if not resolver then
    resolver = cosmo.ResolveIp as function(string): integer, any
  end
  if not timeout_ms then
    local resolved, rerr = resolver(host)
    if not resolved then return nil, errno.str(rerr, "resolve") end
    return resolved
  end
  local r, w = unix.pipe()
  if not r then return nil, errno.str(w, "pipe") end
  local rfd = r as integer
  local wfd = w as integer
  local pid, ferr = unix.fork()
  if not pid then
    unix.close(rfd)
    unix.close(wfd)
    return nil, errno.str(ferr, "fork")
  end
  if pid == 0 then
    unix.close(rfd)
    local resolved, rerr = resolver(host)
    if resolved then
      unix.write(wfd, "O" .. string.pack("<i8", resolved))
    else
      unix.write(wfd, "E" .. tostring(rerr or "resolve failed"))
    end
    unix.close(wfd)
    unix.exit(0)
  end
  unix.close(wfd)
  local fds: {number: number} = {}
  fds[rfd] = unix.POLLIN
  local ready = unix.poll(fds, timeout_ms)
  if not ready or not (ready as {number: number})[rfd] then
    pcall(unix.kill, pid, unix.SIGKILL)
    pcall(unix.wait, pid)
    unix.close(rfd)
    return nil, "resolve timeout"
  end
  -- Drain the pipe. The helper writes at most 9 bytes (1 status byte
  -- + 8-byte packed int) on success, or "E" + a short error string.
  local data = (unix.read(rfd, 4096) or "") as string
  unix.close(rfd)
  pcall(unix.wait, pid)
  local tag = data:sub(1, 1)
  if tag == "O" and #data >= 9 then
    return (string.unpack("<i8", data, 2)) as integer
  end
  if tag == "E" then
    return nil, data:sub(2)
  end
  return nil, "resolve failed"
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
    if not ok then return nil, errno.str(err, "setns") end
  end
  local ip, rerr = resolve(host, resolve_timeout_ms, nil)
  if not ip then return nil, rerr end
  if not cosmo.IsPublicIp(ip) then
    return nil, "request to private network blocked (SSRF protection)"
  end
  local sk, serr = unix.socket(unix.AF_INET,
    (unix.SOCK_STREAM as integer) | (unix.SOCK_CLOEXEC as integer), 0)
  if not sk then return nil, errno.str(serr, "socket") end
  local skfd = sk as integer
  local ok, cerr = unix.connect(skfd, ip, port)
  if not ok then
    unix.close(skfd)
    return nil, errno.str(cerr, "connect")
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
