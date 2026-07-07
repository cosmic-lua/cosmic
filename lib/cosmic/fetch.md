# fetch

 Structured HTTP fetch with retry, streaming, and honest error channels.
 Wraps cosmo.Fetch/FetchStream with structured results so errors, the
 effective URL, and the machine-readable failure kind are never discarded.

## Types

### Result

 Result from a fetch operation.

```teal
local record Result
  ok: boolean
  status: integer
  --  Response headers: lowercase names; repeated headers joined ", "
  --  (RFC 9110 §5.3), so every value is a plain string.
  headers: {string: string}
  --  Response headers with every value: lowercase names, values in
  --  arrival order. Use for repeatable headers like Set-Cookie.
  raw_headers: {string: {string}}
  body: string
  --  Effective URL of the final request, after any redirects.
  url: string
  error: string
  error_kind: ErrorKind
  --  True when ok and status is 2xx.
  is_success: function(self: Result): boolean
end
```

### Opts

 Options for fetch requests.

```teal
local record Opts
  --  HTTP method (default "GET").
  method: string
  --  Request body to send (for POST, PUT, PATCH).
  body: string
  --  HTTP headers to send with the request.
  headers: {string: string}
  --  Follow 3xx redirects (default true).
  follow_redirects: boolean
  --  Maximum redirect hops when following redirects (default 5).
  max_redirects: integer
  --  Allow requests to loopback/private addresses, disabling the SSRF
  --  guard for every hop of the redirect chain (default false).
  allow_private: boolean
  --  HTTP proxy URL.
  proxy: string
  --  Maximum response body size in bytes.
  maxresponse: integer
  --  Per-socket-operation timeout in seconds (connect, each read/write,
  --  TLS handshake) — NOT a whole-request deadline. 0 or nil keeps the
  --  60-second default; there is no "infinite" option.
  timeout: number
  --  Total number of attempts (1 = no retry, default 1).
  max_attempts: integer
  --  Base backoff delay in seconds (default 0.5). Attempt n waits a
  --  uniformly random ("full jitter") delay in
  --  [0, min(max_delay, base_delay * 2^(n-1))].
  base_delay: number
  --  Backoff delay cap in seconds (default 30).
  max_delay: number
  --  Predicate consulted after every attempt (success or failure).
  --  Return true to retry. When nil, the default policy retries
  --  transport errors (dns/connect/timeout) and 429/502/503/504
  --  responses, for idempotent methods only.
  should_retry: function(Result): boolean
end
```

### Reader

 Streaming reader for incremental body access.
 Supports Lua 5.4's to-be-closed via __close metamethod.

```teal
local record Reader
  read: function(self: Reader): string | nil, string
  close: function(self: Reader): boolean
  closed: function(self: Reader): boolean
  lines: function(self: Reader): function(): string | nil, string
end
```

### StreamResult

 Result from a streaming fetch operation.

```teal
local record StreamResult
  ok: boolean
  status: integer
  headers: {string: string}
  raw_headers: {string: {string}}
  reader: Reader
  --  Effective URL of the final request, after any redirects.
  url: string
  error: string
  error_kind: ErrorKind
  --  True when ok and status is 2xx.
  is_success: function(self: StreamResult): boolean
end
```

### fetch

```teal
local record fetch
  Fetch: function(url: string, opts?: Opts): Result
  stream: function(url: string, opts?: Opts): StreamResult
  unix_proxy: function(path: string): string | nil, string
  Opts: Opts
  Result: Result
  Reader: Reader
  StreamResult: StreamResult
end
```

## Functions

### reader:read

```teal
function reader:read(): string | nil, string
```

 Read the next chunk from the stream.

**Returns:**

- string - | nil chunk, or nil on EOF or failure
- string - error message on failure (nil on clean EOF)

### reader:close

```teal
function reader:close(): boolean
```

 Close the reader. Idempotent.

**Returns:**

- boolean - always true

### reader:closed

```teal
function reader:closed(): boolean
```

 Returns true if the reader has been closed.

**Returns:**

- boolean - closed state
