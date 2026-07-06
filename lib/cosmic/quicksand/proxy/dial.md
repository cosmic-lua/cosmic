# dial

 Upstream dialing for the cosmic.quicksand.proxy egress proxy:
 bounded DNS resolution and cross-namespace TCP connects with SSRF
 protection.

 The proxy listens inside a child network namespace and dials
 upstream in a different one (typically the parent's); dial() joins
 the upstream namespace with setns() first, so it must run in a
 per-connection fork where the namespace switch can't leak into
 other connections.

## Types

### DialModule

```teal
local record DialModule
  resolve: function(string, integer, function(string): (integer, any)):
  dial: function(string, integer, integer, integer): integer | nil, string
end
```

## Functions

### resolve

```teal
function resolve(host: string, timeout_ms: integer,
    resolver: function(string): integer, any): integer | nil, string
```

 Resolve `host` to an IPv4 integer. Literal IPs parse immediately;
 otherwise the lookup goes through `resolver` (default
 cosmo.ResolveIp, which uses the system resolver in the *current*
 netns — call after setns() to the upstream namespace).
 When `timeout_ms` is non-nil the lookup runs in a forked helper
 and the parent polls the result pipe; past the deadline the helper
 is SIGKILL'd and (nil, "resolve timeout") is returned, so a
 hostile or tarpitting resolver can't wedge a per-connection worker
 past its budget. Literal IPs skip the fork entirely.
   to cosmo.ResolveIp

**Parameters:**

- `host` (string) - hostname or literal IPv4
- `timeout_ms` (integer?) - resolution deadline (nil = unbounded)
- `resolver` (function?) - test seam returning (ip, err); defaults

**Returns:**

- integer? - IPv4 address as an integer
- string? - error message on failure

### dial

```teal
function dial(host: string, port: integer, upstream_ns_fd: integer,
    resolve_timeout_ms: integer): integer | nil, string
```

 Open a TCP connection to (host, port) in the namespace identified
 by `upstream_ns_fd`, falling back to the current namespace when
 the fd is nil. `resolve_timeout_ms` (optional) bounds DNS
 resolution per dial.
 Non-public IPs are refused after resolution to prevent SSRF: this
 covers loopback (127/8), link-local (169.254/16) including the
 cloud metadata endpoint, RFC1918, CGNAT (100.64/10), 0.0.0.0/8,
 and other reserved ranges — on both CONNECT and plain-HTTP paths.
 The upstream socket is SOCK_CLOEXEC so it can't leak into an
 exec'd child via an accidental fork/exec ordering change.

**Parameters:**

- `host` (string) - hostname or literal IPv4
- `port` (integer) - TCP port
- `upstream_ns_fd` (integer?) - netns fd to dial in (nil = current)
- `resolve_timeout_ms` (integer?) - per-dial DNS deadline

**Returns:**

- integer? - connected socket fd
- string? - error message on failure
