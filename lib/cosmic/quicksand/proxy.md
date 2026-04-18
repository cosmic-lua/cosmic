# proxy

 Allowlist HTTP CONNECT + plain-HTTP proxy for sandboxed egress.

 Typed wrapper over cosmo.sandbox.proxy. The proxy binds inside a
 child's network namespace (the only thing the sandboxed workload
 can reach) and dials upstream in a different namespace, so a
 netns-isolated child can reach a narrow set of approved hosts and
 nothing else.

 start(opts) forks the listener into a child process and returns a
 ProxyHandle with the bound pid and port. handle:stop() sends
 SIGTERM (escalating to SIGKILL after a timeout) and reaps the
 child; handle:alive() is a non-blocking liveness check.

 Rule schema (allowed_hosts):

   {
     ["api.example.com:443"]     = {},                  -- pass-through
     ["*.githubusercontent.com"] = {},                  -- any port
     ["internal.example.com:80"] = { type = "bearer",
                                     token = "..." },   -- inject header
     ["legacy.example.com:80"]   = { type = "basic",
                                     username = "u",
                                     password = "p" },
     ["api.example.com:80"]      = { type = "header",
                                     header_name = "x-api-key",
                                     header_value = "..." },
   }

 Host specs: `host`, `host:port`, `host:*`, `*.suffix`, `*.suffix:port`.
 An empty rule table is pass-through (allow, no header injection).
 Header injection happens on plain HTTP only; CONNECT is opaque.

## Types

### ProxyRule

 A single allowlist rule. `type` nil means pass-through (allowed,
 no header injection). Fields not relevant to the chosen type are
 ignored. Unknown `type` values behave as pass-through.

```teal
local record ProxyRule
  type: string
  token: string
  username: string
  password: string
  header_name: string
  header_value: string
end
```

### ProxyOptions

 Options for start() / new().

```teal
local record ProxyOptions
  bind_ip: integer
  bind_port: integer
  allowed_hosts: {string: ProxyRule}
  upstream_ns_fd: integer
  log_level: string
  log_format: string
  log_file: string
  accept_backlog: integer
  resolve_timeout_ms: integer
  on_log: function({string: any})
end
```

### ProxyHandle

 Returned by start(). `stop()` sends SIGTERM and reaps the
 listener, escalating to SIGKILL after `timeout_ms` (default 5000).
 It is idempotent: once the child has been reaped, subsequent calls
 are no-ops. `alive()` is a non-blocking liveness check.

```teal
local record ProxyHandle
  pid: integer
  port: integer
  stop: function(self: ProxyHandle, timeout_ms?: integer)
  alive: function(self: ProxyHandle): boolean
end
```

### ProxyModule

```teal
local record ProxyModule
  start: function(opts: ProxyOptions): ProxyHandle, string
end
```

## Functions

### start

```teal
function start(opts: ProxyOptions): ProxyHandle, string
```

 Fork a proxy listener into a child process. The parent blocks
 until the child has bound and listened, so handle.port is valid
 immediately on return.

**Parameters:**

- `opts` (ProxyOptions) - allowlist + binding + logging config

**Returns:**

- ProxyHandle? - handle with pid, port, stop(), alive()
- string? - error message on failure
