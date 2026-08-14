--- Structured HTTP fetch with retry, streaming, and honest error channels.
--- Wraps cosmo.Fetch/FetchStream in the house failure shape: a Response
--- exists only when a response arrived, so every field on it is real —
--- transport failures return `nil, Error` (fetch's own structured
--- error record, D24) instead of a record of lying nils. An HTTP error
--- status is a RESPONSE (check `resp.status` or `resp:is_success()`),
--- not a failure.

local cosmo = require("cosmo")
local failure = require("cosmic.failure")
local fetch_headers = require("cosmic.fetch.headers")
local fetch_body = require("cosmic.fetch.body")
local fetch_extras = require("cosmic.fetch.extras")
local json_mod = require("cosmic.json")
local time = require("cosmic.time")

local validate_url = fetch_extras.validate_url
local validate_headers = fetch_extras.validate_headers

--- One part of a multipart/form-data request body (see Options.multipart).
local type Part = fetch_extras.Part

--- Streaming body reader (see cosmic.fetch.body): read(n?)/read_until/
--- lines over the stream contract.
local type Body = fetch_body.Body

--- Machine-readable failure category. The transport kinds come from
--- the C fetch error channel; "invalid_request" is the wrapper's own
--- kind for requests that never reached the transport (bad URL, bad
--- header, conflicting body options), and "io" is download's kind for
--- local file failures (open/write/close on the destination path).
local enum ErrorKind
  "dns"
  "connect"
  "tls"
  "timeout"
  "proxy"
  "protocol"
  "too_large"
  "blocked"
  "invalid_request"
  "io"
end

--- A fetch failure: the module's own structured error, returned in
--- slot 2 (`Response | nil, Error` — still two slots, D20 rule 11).
--- `message` is the human detail with no classification prefix;
--- `kind` is the typed field callers branch on (`err.kind ==
--- "timeout"`, or a caller-owned `< total >` policy table over
--- ErrorKind, which the compiler keeps exhaustive). `tostring(err)`
--- renders `"<kind>: <detail>"` via the attached metatable — the same
--- string slot 2 carried when it was text — and `..` on an Error is
--- deliberately a compile error (no __concat is declared; see D24 and
--- cosmic.failure).
local record Error is failure.Failure
  kind: ErrorKind
end

--- An HTTP response. Exists only when a response arrived, so status,
--- headers and url are always real. `body` is set by fetch and the
--- verb helpers (and download, which writes the payload to disk and
--- carries ""); `reader` is set by stream() instead — the two entry
--- points share every other field.
local record Response
  status: integer
  --- Response headers: lowercase names; repeated headers joined ", "
  --- (RFC 9110 §5.3), so every value is a plain string.
  headers: {string: string}
  --- Response headers with every value: lowercase names, values in
  --- arrival order. Use for repeatable headers like Set-Cookie.
  raw_headers: {string: {string}}
  --- Buffered response body (fetch/verbs/download; nil from stream()).
  body: string
  --- Streaming body reader (stream() only; nil elsewhere).
  reader: Body
  --- Effective URL of the final request, after any redirects.
  url: string
  --- True when status is 2xx.
  is_success: function(self: Response): boolean
  --- Decode the buffered body as JSON (nil + error on bad JSON).
  json: function(self: Response): any, string
end

--- Options for fetch requests.
local record Options
  --- HTTP method (default "GET"; "POST" when json/form/multipart/body
  --- is set and no method is given).
  method: string
  --- Request body to send (for POST, PUT, PATCH).
  body: string
  --- Query parameters appended to the URL, percent-encoded, keys sorted.
  query: {string: string}
  --- JSON request body: encoded with cosmic.json, Content-Type set to
  --- application/json unless the caller supplied one. At most one of
  --- body/json/form/multipart may be set.
  json: any
  --- Form request body (application/x-www-form-urlencoded, keys sorted).
  form: {string: string}
  --- multipart/form-data request body parts (random boundary).
  multipart: {Part}
  --- HTTP headers to send with the request.
  headers: {string: string}
  --- Follow 3xx redirects (default true).
  follow_redirects: boolean
  --- Maximum redirect hops when following redirects (default 5).
  max_redirects: integer
  --- Allow requests to loopback/private addresses, disabling the SSRF
  --- guard for every hop of the redirect chain (default false).
  allow_private: boolean
  --- HTTP proxy URL.
  proxy: string
  --- Maximum response body size in bytes.
  max_response_bytes: integer
  --- Per-socket-operation timeout in milliseconds (connect, each
  --- read/write, TLS handshake) — NOT a whole-request deadline. 0 or nil
  --- keeps the 60-second default; there is no "infinite" option.
  --- (Durations are integer milliseconds with the unit in the name,
  --- house-wide.)
  timeout_ms: integer
  --- Total number of attempts (1 = no retry, default 1). Clamped to >= 1:
  --- 0 or negative would otherwise skip the fetch loop and return nothing.
  max_attempts: integer
  --- Base backoff delay in milliseconds (default 500). Attempt n waits a
  --- uniformly random ("full jitter") delay in
  --- [0, min(max_delay_ms, base_delay_ms * 2^(n-1))].
  base_delay_ms: integer
  --- Backoff delay cap in milliseconds (default 30000).
  max_delay_ms: integer
  --- Policy consulted between attempts — after every attempt EXCEPT
  --- the last, since there is nothing to decide once no attempt
  --- remains. With the default max_attempts of 1 it is never called
  --- at all. Receives the Response (nil on a failure) and the Error
  --- (nil when a response arrived); return true to retry. When nil,
  --- the default policy retries transport errors (dns/connect/timeout)
  --- and 429/502/503/504 responses, for idempotent methods only.
  ---
  --- It is a policy, not a notification: do not reach for it to
  --- observe failures, because the failure that ends the call is
  --- exactly the one it does not see.
  should_retry: function(Response, Error): boolean
end

-- Shared helpers, attached via metatable so every Response answers the
-- 2xx question and decodes JSON without carrying fields.
local response_mt = {
  __index = {
    is_success = function(self: Response): boolean
      return self.status ~= nil and self.status >= 200 and self.status < 300
    end,
    json = function(self: Response): any, string
      if not self.body or self.body == "" then
        return nil, "empty body"
      end
      return json_mod.decode(self.body)
    end,
  },
}

-- validate_url/validate_headers and the request-body builders live in
-- cosmic.fetch.extras (this file is at the 500-line cap).

--- Project the transport-relevant Options fields onto a fresh typed
--- cosmo.FetchOptions, shallow-copying headers so no attempt can observe
--- another attempt's table — whether the C layer mutates its options
--- stays a C-layer detail. Retry-loop fields stay wrapper-side.
--- @param opts Options? wrapper options, or nil
--- @return cosmo.FetchOptions? options for cosmo.Fetch/FetchStream, or nil
local function to_fetch_options(opts?: Options): cosmo.FetchOptions
  if not opts then
    return nil
  end
  local headers: {string: string} = nil
  if opts.headers then
    headers = {}
    for name, value in pairs(opts.headers) do
      headers[name] = value
    end
  end
  local fo: cosmo.FetchOptions = {
    method = opts.method,
    body = opts.body,
    headers = headers,
    proxy = opts.proxy,
    maxresponse = opts.max_response_bytes,
    -- the binding speaks seconds; the wrapper's unit is ms
    timeout = opts.timeout_ms and opts.timeout_ms / 1000 or nil,
    maxredirects = opts.max_redirects,
    allowprivate = opts.allow_private,
  }
  if opts.follow_redirects ~= nil then
    fo.followredirect = opts.follow_redirects
  end
  return fo
end

-- Every Error goes through fail(), which attaches this metatable, so
-- tostring(err) always renders the classified form. Declared-but-
-- unattached metamethods are the one hole the type system leaves open
-- (a bare Error literal would type-check and then print a table
-- address); the constructor discipline below plus its test line are
-- what close it.
local error_mt = {
  __tostring = function(e: Error): string
    return e.kind .. ": " .. e.message
  end,
}

--- Build the failure pair. kind defaults to "invalid_request" — the
--- wrapper's own kind for requests that never reached the transport.
--- The message stays clean; the classification is the typed kind
--- field, and tostring(err) reunites them for rendering.
local function fail(err: any, kind: string): Response | nil, Error
  local detail = tostring(err or "unknown error")
  local k = (kind or "invalid_request") as ErrorKind -- cast: enum superset of binding string
  local e: Error = {message = detail, kind = k}
  return nil, setmetatable(e, error_mt as metatable < Error >) -- cast: metatable shape
end

local function make_response(fields: {string: any}): Response
  return setmetatable(fields as Response, response_mt) as Response -- cast: table seeded as record
end

local function do_fetch(url: string, opts?: Options): Response | nil, Error
  local verr = validate_url(url)
  if verr then
    return fail(verr, nil)
  end
  local herr = opts and validate_headers(opts.headers)
  if herr then
    return fail(herr, nil)
  end

  local status, headers_or_err, body_or_kind, final_url = cosmo.Fetch(url, to_fetch_options(opts))
  if not status then
    return fail(headers_or_err, body_or_kind)
  end

  -- cast: from any
  local headers, raw_headers = fetch_headers.normalize(headers_or_err as {string: any})
  return make_response({
      status = status as integer, -- cast: dual-shape binding return
      headers = headers,
      raw_headers = raw_headers,
      body = body_or_kind,
      url = final_url,
    })
end

local IDEMPOTENT: {string: boolean} = {
  GET = true, HEAD = true, OPTIONS = true, PUT = true, DELETE = true, TRACE = true,
}
-- <total>: every ErrorKind must take an explicit retry-or-not position;
-- adding a kind without deciding is a compile error.
local RETRYABLE_KIND < total >: {ErrorKind: boolean} = {
  dns = true,
  connect = true,
  tls = false,
  timeout = true,
  proxy = false,
  protocol = false,
  too_large = false,
  blocked = false,
  invalid_request = false,
  io = false,
}
local RETRYABLE_STATUS: {integer: boolean} = {[429] = true, [502] = true, [503] = true, [504] = true}

--- Default retry policy: transport blips (dns/connect/timeout) and
--- 429/502/503/504 responses are retried, but only for idempotent methods.
--- invalid_request/tls/blocked/protocol/proxy/too_large failures are
--- never retried.
local function default_should_retry(resp: Response, errobj: Error, method: string): boolean
  if not IDEMPOTENT[method] then
    return false
  end
  if errobj then
    return RETRYABLE_KIND[errobj.kind] or false
  end
  return RETRYABLE_STATUS[resp.status] or false
end

local function backoff(attempt: integer, base_delay_ms: integer, max_delay_ms: integer)
  -- Full jitter: uniform in [0, min(max_delay_ms, base_delay_ms * 2^(attempt-1))].
  -- Durations are integer milliseconds (D20 rule 2); floor the jitter.
  local _ok, _err = time.sleep_ms(math.floor(
      math.random() * math.min(max_delay_ms, base_delay_ms * 2 ^ (attempt - 1))))
end

--- Fetch a URL. A Response arrives only when a response did — an HTTP
--- error status is a Response (check resp.status or resp:is_success());
--- a transport or validation failure is `nil, Error` — branch on the
--- typed `err.kind`, render with `tostring(err)` ("timeout: ...").
--- @param url string URL to fetch
--- @param opts Options optional fetch options (retry, headers, redirects, ...)
--- @return Response | nil The response, or nil on failure
--- @return Error The structured failure (kind + message)
local function Fetch(url: string, opts?: Options): Response | nil, Error
  -- Expand query/json/form/multipart first: prepare may set the method
  -- (body options default to POST), which the retry policy inspects.
  local purl, popts, perr = fetch_extras.prepare(url, opts)
  if perr then
    return fail(perr, nil)
  end
  url = purl
  opts = popts
  local max_attempts = (opts and opts.max_attempts) or 1; if max_attempts < 1 then max_attempts = 1 end
  local base_delay_ms = (opts and opts.base_delay_ms) or 500
  local max_delay_ms = (opts and opts.max_delay_ms) or 30000
  local should_retry = opts and opts.should_retry
  local method = string.upper((opts and opts.method) or "GET")

  local resp: Response
  local errobj: Error
  for attempt = 1, max_attempts do
    resp, errobj = do_fetch(url, opts)
    if attempt == max_attempts then
      break
    end
    local retry: boolean
    if should_retry then
      retry = should_retry(resp, errobj)
    else
      retry = default_should_retry(resp, errobj, method)
    end
    if not retry then
      break
    end
    backoff(attempt, base_delay_ms, max_delay_ms)
  end
  return resp, errobj
end

--- Open a streaming HTTP request.
--- Unlike fetch, returns immediately with resp.reader for incremental
--- body access (resp.body is nil). Takes the same options as fetch
--- except the retry fields (max_attempts, base_delay_ms, max_delay_ms,
--- should_retry), which do not apply to streams.
--- @param url string URL to fetch
--- @param opts Options optional fetch options
--- @return Response | nil The response (reader set, body nil), or nil on failure
--- @return Error The structured failure (kind + message)
local function stream(url: string, opts?: Options): Response | nil, Error
  local purl, popts, perr = fetch_extras.prepare(url, opts)
  if perr then
    return fail(perr, nil)
  end
  url = purl
  opts = popts
  local verr = validate_url(url)
  if verr then
    return fail(verr, nil)
  end
  local herr = opts and validate_headers(opts.headers)
  if herr then
    return fail(herr, nil)
  end

  local status, headers_or_err, reader_or_kind, final_url = cosmo.FetchStream(url, to_fetch_options(opts))
  if not status then
    -- kind mirrors fail()'s: FetchStream's dual-shape third return is
    -- statically StreamReader (it carries the kind string on failure).
    -- cast: dual-shape binding return
    return fail(headers_or_err, reader_or_kind as string)
  end

  -- cast: from any
  local headers, raw_headers = fetch_headers.normalize(headers_or_err as {string: any})
  return make_response({
      status = status,
      headers = headers,
      raw_headers = raw_headers,
      reader = fetch_body.make_body(reader_or_kind),
      url = final_url,
    })
end

-- Verb helpers/download come from fetch_extras.make; it receives the
-- response constructor and the failure builder so download's
-- synthesized results carry the same shapes.
local made = fetch_extras.make(
  Fetch as (function(string, any): (any, any)), -- cast: function shape
  stream as (function(string, any): (any, any)), -- cast: function shape
  function(t: any): any
    return make_response(t as {string: any}) -- cast: from any
  end,
  function(message: string): (any, any)
    -- download's local-file failures are fetch's own two-way case:
    -- kind "io", same Error shape as every transport failure.
    return fail(message, "io")
  end)

local record FetchModule
  fetch: function(url: string, opts?: Options): Response | nil, Error
  --- GET/POST/PUT/DELETE conveniences: fetch with the method forced.
  get: function(url: string, opts?: Options): Response | nil, Error
  post: function(url: string, opts?: Options): Response | nil, Error
  put: function(url: string, opts?: Options): Response | nil, Error
  delete: function(url: string, opts?: Options): Response | nil, Error
  --- Stream a URL to a file. The file is written only for a 2xx
  --- response (created/truncated, then removed again on a mid-stream
  --- failure); a non-2xx response returns its Response with a bounded
  --- diagnostic body and writes nothing. The Response carries body = ""
  --- on success; a local file failure returns nil, Error with kind
  --- "io" (it is not a request failure).
  download: function(url: string, path: string, opts?: Options): Response | nil, Error
  stream: function(url: string, opts?: Options): Response | nil, Error
  type ErrorKind = ErrorKind
  --- Type aliases, not runtime values: a `Response: Response` field
  --- spelling would declare phantom fields that are nil at runtime.
  type Options = Options
  type Part = Part
  type Response = Response
  type Error = Error
  type Body = Body
end

local M: FetchModule = {
  fetch = Fetch,
  -- cast: function shape
  get = made.get as (function(string, Options): (Response | nil, Error)),
  -- cast: function shape
  post = made.post as (function(string, Options): (Response | nil, Error)),
  -- cast: function shape
  put = made.put as (function(string, Options): (Response | nil, Error)),
  -- cast: function shape
  delete = made.delete as (function(string, Options): (Response | nil, Error)),
  -- cast: function shape
  download = made.download as (function(string, string, Options): (Response | nil, Error)),
  stream = stream,
}

return M
