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
  --  Decode the response body as JSON (nil + error on bad JSON).
  json: function(self: Result): any, string
end
```

### Options

 Options for fetch requests.

```teal
local record Options
  --  HTTP method (default "GET"; "POST" when json/form/multipart/body
  --  is set and no method is given).
  method: string
  --  Request body to send (for POST, PUT, PATCH).
  body: string
  --  Query parameters appended to the URL, percent-encoded, keys sorted.
  query: {string: string}
  --  JSON request body: encoded with cosmic.json, Content-Type set to
  --  application/json unless the caller supplied one. At most one of
  --  body/json/form/multipart may be set.
  json: any
  --  Form request body (application/x-www-form-urlencoded, keys sorted).
  form: {string: string}
  --  multipart/form-data request body parts (random boundary).
  multipart: {Part}
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
  --  Per-socket-operation timeout in milliseconds (connect, each
  --  read/write, TLS handshake) — NOT a whole-request deadline. 0 or nil
  --  keeps the 60-second default; there is no "infinite" option.
  --  (api-review-6: was `timeout`, in seconds — durations are integer
  --  milliseconds with the unit in the name, house-wide.)
  timeout_ms: integer
  --  Total number of attempts (1 = no retry, default 1). Clamped to >= 1:
  --  0 or negative would otherwise skip the fetch loop and return no Result.
  max_attempts: integer
  --  Base backoff delay in milliseconds (default 500). Attempt n waits a
  --  uniformly random ("full jitter") delay in
  --  [0, min(max_delay_ms, base_delay_ms * 2^(n-1))].
  base_delay_ms: integer
  --  Backoff delay cap in milliseconds (default 30000).
  max_delay_ms: integer
  --  Predicate consulted after every attempt (success or failure).
  --  Return true to retry. When nil, the default policy retries
  --  transport errors (dns/connect/timeout) and 429/502/503/504
  --  responses, for idempotent methods only.
  should_retry: function(Result): boolean
end
```

### Reader

 Streaming reader for incremental body access.
 Conforms to the stream contract (cosmic.stream): read returns the
 next chunk, bare nil at end of stream, or nil + error on failure.
 Chunk sizes are transport-determined; read takes no size argument.

```teal
local record Reader
  __close: function(self: Reader)
  read: function(self: Reader): string | nil, string
  --  Close the reader; boolean, string like every stdlib close.
  close: function(self: Reader): boolean, string
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

### FetchModule

```teal
local record FetchModule
  fetch: function(url: string, opts?: Options): Result
  --  GET/POST/PUT/DELETE conveniences: fetch with the method forced.
  get: function(url: string, opts?: Options): Result
  post: function(url: string, opts?: Options): Result
  put: function(url: string, opts?: Options): Result
  delete: function(url: string, opts?: Options): Result
  --  Stream a URL to a file. The file is written only for a 2xx
  --  response (created/truncated, then removed again on a mid-stream
  --  failure); a non-2xx response returns its status with a bounded
  --  diagnostic body and writes nothing. The result carries body = ""
  --  on success.
  download: function(url: string, path: string, opts?: Options): Result
  stream: function(url: string, opts?: Options): StreamResult
  unix_proxy: function(path: string): string | nil, string
end
```

## Functions

### stream

```teal
function stream(url: string, opts?: Options): StreamResult
```

 Open a streaming HTTP request.
 Unlike Fetch, returns immediately with a reader for incremental body
 access. Takes the same options as Fetch except the retry fields
 (max_attempts, base_delay_ms, max_delay_ms, should_retry), which do not
 apply to streams.

**Parameters:**

- `url` (string) - URL to fetch
- `opts` (Options) - optional fetch options

**Returns:**

- StreamResult - with reader for incremental body access

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
function reader:close(): boolean, string
```

 Close the reader. Idempotent; cannot fail today.

### reader:closed

```teal
function reader:closed(): boolean
```

 Returns true if the reader has been closed.

**Returns:**

- boolean - closed state
