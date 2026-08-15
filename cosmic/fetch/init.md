# fetch

 Structured HTTP fetch with retry, streaming, and honest error channels.
 Wraps cosmo.Fetch/FetchStream in the house failure shape: a Response
 exists only when a response arrived, so every field on it is real —
 transport failures return `nil, Error` (fetch's own structured
 error record) instead of a record of lying nils. An HTTP error
 status is a RESPONSE (check `resp.status` or `resp:is_success()`),
 not a failure.

## Types

### Error

 A fetch failure: the module's own structured error, returned in
 slot 2 (`Response | nil, Error` — still two slots).
 `message` is the human detail with no classification prefix;
 `kind` is the typed field callers branch on (`err.kind ==
 "timeout"`, or a caller-owned `< total >` policy table over
 ErrorKind, which the compiler keeps exhaustive). `tostring(err)`
 renders `"<kind>: <detail>"` via the attached metatable — the same
 string slot 2 carried when it was text — and `..` on an Error is
 deliberately a compile error (no __concat is declared; see
 cosmic.errors).

```teal
local record Error
  kind: ErrorKind
end
```

### Response

 An HTTP response. Exists only when a response arrived, so status,
 headers and url are always real. `body` is set by fetch and the
 verb helpers (and download, which writes the payload to disk and
 carries ""); `reader` is set by stream() instead — the two entry
 points share every other field.

```teal
local record Response
  status: integer
  --  Response headers: lowercase names; repeated headers joined ", "
  --  (RFC 9110 §5.3), so every value is a plain string.
  headers: {string: string}
  --  Response headers with every value: lowercase names, values in
  --  arrival order. Use for repeatable headers like Set-Cookie.
  raw_headers: {string: {string}}
  --  Buffered response body (fetch/verbs/download; nil from stream()).
  body: string
  --  Streaming body reader (stream() only; nil elsewhere).
  reader: Body
  --  Effective URL of the final request, after any redirects.
  url: string
  --  True when status is 2xx.
  is_success: function(self: Response): boolean
  --  Decode the buffered body as JSON (nil + error on bad JSON).
  json: function(self: Response): any, string
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
  max_response_bytes: integer
  --  Per-socket-operation timeout in milliseconds (connect, each
  --  read/write, TLS handshake) — NOT a whole-request deadline. 0 or nil
  --  keeps the 60-second default; there is no "infinite" option.
  --  (Durations are integer milliseconds with the unit in the name,
  --  house-wide.)
  timeout_ms: integer
  --  Total number of attempts (1 = no retry, default 1). Clamped to >= 1:
  --  0 or negative would otherwise skip the fetch loop and return nothing.
  max_attempts: integer
  --  Base backoff delay in milliseconds (default 500). Attempt n waits a
  --  uniformly random ("full jitter") delay in
  --  [0, min(max_delay_ms, base_delay_ms * 2^(n-1))].
  base_delay_ms: integer
  --  Backoff delay cap in milliseconds (default 30000).
  max_delay_ms: integer
  --  Policy consulted between attempts — after every attempt EXCEPT
  --  the last, since there is nothing to decide once no attempt
  --  remains. With the default max_attempts of 1 it is never called
  --  at all. Receives the Response (nil on a failure) and the Error
  --  (nil when a response arrived); return true to retry. When nil,
  --  the default policy retries transport errors (dns/connect/timeout)
  --  and 429/502/503/504 responses, for idempotent methods only.
  --  It is a policy, not a notification: do not reach for it to
  --  observe failures, because the failure that ends the call is
  --  exactly the one it does not see.
  should_retry: function(Response, Error): boolean
end
```

### FetchModule

```teal
local record FetchModule
  fetch: function(url: string, opts?: Options): Response | nil, Error
  --  GET/POST/PUT/DELETE conveniences: fetch with the method forced.
  get: function(url: string, opts?: Options): Response | nil, Error
  post: function(url: string, opts?: Options): Response | nil, Error
  put: function(url: string, opts?: Options): Response | nil, Error
  delete: function(url: string, opts?: Options): Response | nil, Error
  --  Stream a URL to a file. The file is written only for a 2xx
  --  response (created/truncated, then removed again on a mid-stream
  --  failure); a non-2xx response returns its Response with a bounded
  --  diagnostic body and writes nothing. The Response carries body = ""
  --  on success; a local file failure returns nil, Error with kind
  --  "io" (it is not a request failure).
  download: function(url: string, path: string, opts?: Options): Response | nil, Error
  stream: function(url: string, opts?: Options): Response | nil, Error
end
```

### Part

 One part of a multipart/form-data request body (see Options.multipart).

alias of `cosmic.fetch.extras.Part` — field and method table: `cosmic --docs cosmic.fetch.extras.Part`

### Body

 Streaming body reader (see cosmic.fetch.body): read(n?)/read_until/
 lines over the stream contract.

alias of `cosmic.fetch.body.Body` — field and method table: `cosmic --docs cosmic.fetch.body.Body`

## Functions

### fetch

```teal
function fetch(url: string, opts?: Options): Response | nil, Error
```

 Fetch a URL. A Response arrives only when a response did — an HTTP
 error status is a Response (check resp.status or resp:is_success());
 a transport or validation failure is `nil, Error` — branch on the
 typed `err.kind`, render with `tostring(err)` ("timeout: ...").

**Parameters:**

- `url` (string) - URL to fetch
- `opts` (Options) - optional fetch options (retry, headers, redirects, ...)

**Returns:**

- Response - | nil The response, or nil on failure
- Error - The structured failure (kind + message)

### stream

```teal
function stream(url: string, opts?: Options): Response | nil, Error
```

 Open a streaming HTTP request.
 Unlike fetch, returns immediately with resp.reader for incremental
 body access (resp.body is nil). Takes the same options as fetch
 except the retry fields (max_attempts, base_delay_ms, max_delay_ms,
 should_retry), which do not apply to streams.

**Parameters:**

- `url` (string) - URL to fetch
- `opts` (Options) - optional fetch options

**Returns:**

- Response - | nil The response (reader set, body nil), or nil on failure
- Error - The structured failure (kind + message)
