# fetch

 Structured HTTP fetch with optional retry.
 Wraps cosmo.Fetch with structured results to prevent accidentally discarding errors.

## Types

### Result

 Result from a fetch operation.

```teal
local record Result
  ok: boolean
  status: number
  headers: {string: string}
  body: string
  error: string
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
  --  HTTP proxy URL.
  proxy: string
  --  Maximum response body size in bytes.
  maxresponse: number
  --  Total number of attempts (1 = no retry, default 1).
  --  Retries only occur when result.ok is true and should_retry returns true.
  max_attempts: number
  --  Maximum backoff delay in seconds (default 30).
  --  Backoff is exponential: 2^attempt seconds, capped at this value.
  max_delay: number
  --  Predicate called after each successful HTTP response to decide retry.
  --  Return true to retry (e.g. on status 429 or 503). If nil, no retries.
  should_retry: function(Result): boolean
  --  Request timeout in seconds. If nil, no timeout is applied.
  timeout: number
end
```

### Reader

 Streaming reader for incremental body access.
 Supports Lua 5.4's to-be-closed via __close metamethod.

```teal
local record Reader
  read: function(self: Reader): string, string
  close: function(self: Reader): boolean
  closed: function(self: Reader): boolean
  lines: function(self: Reader): function(): string
end
```

### StreamResult

 Result from a streaming fetch operation.

```teal
local record StreamResult
  ok: boolean
  status: number
  headers: {string: string}
  reader: Reader
  error: string
end
```

### fetch

```teal
local record fetch
  Fetch: function(url: string, opts?: Opts): Result
  stream: function(url: string, opts?: Opts): StreamResult
  has_stream: function(): boolean
  unix_proxy: function(path: string): string, string
  Opts: Opts
  Result: Result
  Reader: Reader
  StreamResult: StreamResult
end
```

## Functions

### reader:read

```teal
function reader:read(): string, string
```

 Read the next chunk from the stream.

**Returns:**

- string - chunk or nil on EOF
- string - error message on failure

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
