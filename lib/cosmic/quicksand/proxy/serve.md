# serve

 Listener, per-connection handler, and logging for the
 cosmic.quicksand.proxy egress proxy.

 new() builds a Server from ProxyOptions; listen() binds it;
 serve_forever() runs the accept loop, forking one worker per
 connection so each worker can setns() into the upstream namespace
 without affecting the others. Most callers should use
 cosmic.quicksand.proxy.start() instead, which forks the whole
 server into a sidecar child and returns a handle.

## Types

### Logger

 Leveled event logger. Each method takes an event name and a flat
 field table.

```teal
local record Logger
  info: function(ev: string, fields: {string: any})
  debug: function(ev: string, fields: {string: any})
  warn: function(ev: string, fields: {string: any})
end
```

### Server

 A bound (or bindable) proxy server. Methods are closures over the
 server's internal state.

```teal
local record Server
  port: function(): integer
  listen: function(): integer | nil, string
  accept: function(): integer | nil, string
  handle: function(client_fd: integer)
  serve_forever: function()
end
```

### ProxyRule

 A single allowlist rule. `type` nil means pass-through
 (allowed, no header injection). Fields not relevant to the
 chosen type are ignored.

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

### ServeModule

```teal
local record ServeModule
  new: function(opts: ProxyOptions): Server | nil, string
end
```

## Functions

### new

```teal
function new(opts: ServeModule.ProxyOptions): Server | nil, string
```

 Build a Server from ProxyOptions. Does not bind; call listen()
 (or hand the Server to serve_forever(), which listens lazily).
 Returns nil + error when the log sink can't be opened. Rule
 validation is the caller's job (proxy.start validates before
 forking); unvalidated rule tables here behave as pass-through.
