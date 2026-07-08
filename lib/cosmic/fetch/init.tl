--- Structured HTTP fetch with retry, streaming, and honest error channels.
--- Wraps cosmo.Fetch/FetchStream with structured results so errors, the
--- effective URL, and the machine-readable failure kind are never discarded.

local cosmo = require("cosmo")
local fetch_headers = require("cosmic.fetch.headers")
local time = require("cosmic.time")

--- Machine-readable failure category, from the C fetch error channel.
--- nil on wrapper-side validation failures (bad URL, bad header).
local enum ErrorKind
  "dns"
  "connect"
  "tls"
  "timeout"
  "proxy"
  "protocol"
  "too_large"
  "blocked"
end

--- Result from a fetch operation.
local record Result
  ok: boolean
  status: integer
  --- Response headers: lowercase names; repeated headers joined ", "
  --- (RFC 9110 §5.3), so every value is a plain string.
  headers: {string: string}
  --- Response headers with every value: lowercase names, values in
  --- arrival order. Use for repeatable headers like Set-Cookie.
  raw_headers: {string: {string}}
  body: string
  --- Effective URL of the final request, after any redirects.
  url: string
  error: string
  error_kind: ErrorKind
  --- True when ok and status is 2xx.
  is_success: function(self: Result): boolean
end

--- Options for fetch requests.
local record Options
  --- HTTP method (default "GET").
  method: string
  --- Request body to send (for POST, PUT, PATCH).
  body: string
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
  maxresponse: integer
  --- Per-socket-operation timeout in seconds (connect, each read/write,
  --- TLS handshake) — NOT a whole-request deadline. 0 or nil keeps the
  --- 60-second default; there is no "infinite" option.
  timeout: number
  --- Total number of attempts (1 = no retry, default 1).
  max_attempts: integer
  --- Base backoff delay in seconds (default 0.5). Attempt n waits a
  --- uniformly random ("full jitter") delay in
  --- [0, min(max_delay, base_delay * 2^(n-1))].
  base_delay: number
  --- Backoff delay cap in seconds (default 30).
  max_delay: number
  --- Predicate consulted after every attempt (success or failure).
  --- Return true to retry. When nil, the default policy retries
  --- transport errors (dns/connect/timeout) and 429/502/503/504
  --- responses, for idempotent methods only.
  should_retry: function(Result): boolean
end

--- Streaming reader for incremental body access.
--- Supports Lua 5.4's to-be-closed via __close metamethod.
local record Reader
  read: function(self: Reader): string | nil, string
  close: function(self: Reader): boolean
  closed: function(self: Reader): boolean
  lines: function(self: Reader): function(): string | nil, string
end

--- Result from a streaming fetch operation.
local record StreamResult
  ok: boolean
  status: integer
  headers: {string: string}
  raw_headers: {string: {string}}
  reader: Reader
  --- Effective URL of the final request, after any redirects.
  url: string
  error: string
  error_kind: ErrorKind
  --- True when ok and status is 2xx.
  is_success: function(self: StreamResult): boolean
end

-- Shared is_success helper, attached via metatable so successful and
-- failed results alike answer the 2xx question without carrying a field.
local result_mt = {
  __index = {
    is_success = function(self: Result): boolean
      return self.ok and self.status ~= nil
      and self.status >= 200 and self.status < 300
    end,
  },
}

local function validate_url(url: string): string
  if url == "" then
    return "empty URL"
  end
  local scheme = url:match("^([a-zA-Z][a-zA-Z0-9+%-.]*)://")
  if not scheme then
    return "unsupported URL scheme: (none)"
  end
  scheme = scheme:lower()
  if scheme ~= "http" and scheme ~= "https" then
    return "unsupported URL scheme: " .. scheme
  end
  return nil
end

-- True when s carries a CR, LF, or NUL. One character-class scan instead
-- of three separate plain-text searches over the same string.
local function has_forbidden_byte(s: string): boolean
  return s:find("[\r\n\0]") ~= nil
end

--- Reject header names or values that carry a CR, LF, or NUL. HTTP headers
--- are CRLF-delimited, so an embedded CR/LF in a name or value smuggles
--- additional header lines (or a body) past cosmo.Fetch — a request-splitting
--- / header-injection vector (audit §2.3). The error names the offending
--- header but never echoes the raw control bytes back.
--- @param headers {string: string} request headers, or nil
--- @return string? error message, or nil when every header is safe
local function validate_headers(headers: {string: string}): string
  if not headers then
    return nil
  end
  for name, value in pairs(headers) do
    if name == "" then
      return "invalid header name: must not be empty"
    end
    if has_forbidden_byte(name) then
      return "invalid header name: must not contain CR, LF, or NUL"
    end
    if value ~= nil and has_forbidden_byte(value) then
      return "invalid value for header '" .. name .. "': must not contain CR, LF, or NUL"
    end
  end
  return nil
end

--- Project the transport-relevant Options fields onto a fresh typed
--- cosmo.FetchOptions, shallow-copying headers so no attempt can observe
--- another attempt's table (the C layer no longer mutates its options,
--- but the copy keeps that a C-layer detail). Retry-loop fields stay
--- wrapper-side.
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
    maxresponse = opts.maxresponse,
    timeout = opts.timeout,
    maxredirects = opts.max_redirects,
    allowprivate = opts.allow_private,
  }
  if opts.follow_redirects ~= nil then
    fo.followredirect = opts.follow_redirects
  end
  return fo
end

local function fail(err: any, kind: any): Result
  return setmetatable({
      ok = false,
      error = tostring(err or "unknown error"),
      error_kind = kind as ErrorKind,
    } as Result, result_mt) as Result
end

local function do_fetch(url: string, opts?: Options): Result
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

  local headers, raw_headers = fetch_headers.normalize(headers_or_err as {string: any})
  return setmetatable({
      ok = true,
      status = status as integer,
      headers = headers,
      raw_headers = raw_headers,
      body = body_or_kind,
      url = final_url,
    } as Result, result_mt) as Result
end

local IDEMPOTENT: {string: boolean} = {
  GET = true, HEAD = true, OPTIONS = true, PUT = true, DELETE = true, TRACE = true,
}
local RETRYABLE_KIND: {string: boolean} = {dns = true, connect = true, timeout = true}
local RETRYABLE_STATUS: {integer: boolean} = {[429] = true, [502] = true, [503] = true, [504] = true}

--- Default retry policy: transport blips (dns/connect/timeout) and
--- 429/502/503/504 responses are retried, but only for idempotent methods.
--- Validation failures (no error_kind) and tls/blocked/protocol/proxy/
--- too_large failures are never retried.
local function default_should_retry(result: Result, method: string): boolean
  if not IDEMPOTENT[method] then
    return false
  end
  if not result.ok then
    return RETRYABLE_KIND[result.error_kind] or false
  end
  return RETRYABLE_STATUS[result.status] or false
end

local function backoff(attempt: integer, base_delay: number, max_delay: number)
  -- Full jitter: uniform in [0, min(max_delay, base_delay * 2^(attempt-1))].
  local delay = math.random() * math.min(max_delay, base_delay * 2 ^ (attempt - 1))
  local secs = math.floor(delay)
  time.sleep(secs, math.floor((delay - secs) * 1e9))
end

--- Fetch a URL and return a structured result.
--- @param url string URL to fetch
--- @param opts Options optional fetch options (retry, headers, redirects, ...)
--- @return Result fetch result with ok, status, headers, body, url, or error
local function Fetch(url: string, opts?: Options): Result
  local max_attempts = (opts and opts.max_attempts) or 1
  local base_delay = (opts and opts.base_delay) or 0.5
  local max_delay = (opts and opts.max_delay) or 30
  local should_retry = opts and opts.should_retry
  local method = string.upper((opts and opts.method) or "GET")

  local result: Result
  for attempt = 1, max_attempts do
    result = do_fetch(url, opts)
    if attempt == max_attempts then
      break
    end
    local retry: boolean
    if should_retry then
      retry = should_retry(result)
    else
      retry = default_should_retry(result, method)
    end
    if not retry then
      break
    end
    backoff(attempt, base_delay, max_delay)
  end
  return result
end

--- Create a reader wrapping a raw stream reader.
--- @param raw_reader cosmo.StreamReader The raw reader from FetchStream
--- @return Reader wrapped reader with lines() support
local function make_reader(raw_reader: cosmo.StreamReader): Reader
  local is_closed = false
  local reader: Reader = {}

  --- Read the next chunk from the stream.
  --- @return string | nil chunk, or nil on EOF or failure
  --- @return string error message on failure (nil on clean EOF)
  function reader:read(): string | nil, string
    if is_closed then
      return nil, "reader closed"
    end
    local chunk, err = raw_reader:read()
    if err then
      return nil, err
    end
    return chunk
  end

  --- Close the reader. Idempotent.
  --- @return boolean always true
  function reader:close(): boolean
    if not is_closed then
      raw_reader:close()
      is_closed = true
    end
    return true
  end

  --- Returns true if the reader has been closed.
  --- @return boolean closed state
  function reader:closed(): boolean
    return is_closed
  end

  --- Return an iterator that yields complete lines.
  --- Buffers partial lines across chunks until a newline is received.
  --- On clean EOF a final unterminated line is yielded, then nil. On a
  --- read error (reset, truncation, TLS failure) the iterator yields
  --- nil plus the error message once — the buffered partial line is
  --- truncated data and is discarded — then plain nil forever.
  --- @return function iterator yielding lines without trailing newline
  function reader:lines(): function(): string | nil, string
    -- Scan-position index into buffer: `pos` is the first unread byte.
    -- Advancing it instead of slicing off each returned line, and dropping
    -- the consumed prefix only when we must read more, keeps the whole loop
    -- linear in the byte count (audit §7.2 P1).
    local buffer = ""
    local pos = 1
    local done = false
    local pending_err: string = nil

    return function(): string | nil, string
      while true do
        local newline_pos = buffer:find("\n", pos, true)
        if newline_pos then
          local line = buffer:sub(pos, newline_pos - 1)
          pos = newline_pos + 1
          return line
        end

        if pending_err then
          local err = pending_err
          pending_err = nil
          done = true
          return nil, err
        end

        if done then
          -- Clean EOF with a final unterminated line still buffered:
          -- yield it once.
          if pos <= #buffer then
            local remaining = buffer:sub(pos)
            pos = #buffer + 1
            return remaining
          end
          return nil
        end

        -- No newline in the unread region; we need more data. Compact away
        -- the already-returned prefix first so the buffer stays bounded and
        -- the concat below copies only the unread tail, not the whole buffer.
        if pos > 1 then
          buffer = buffer:sub(pos)
          pos = 1
        end
        local chunk, err = self:read()
        if err then
          -- The buffered tail has no newline: it is truncated data, not a
          -- line. Drop it and surface the error on the next iteration.
          pending_err = err
          buffer = ""
          pos = 1
        elseif not chunk then
          done = true
        else
          buffer = buffer .. chunk
        end
      end
    end
  end

  return setmetatable(reader, {
      __close = function(self: Reader) self:close() end
    }) as Reader
end

local function stream_fail(err: any, kind: any): StreamResult
  return setmetatable({
      ok = false,
      error = tostring(err or "unknown error"),
      error_kind = kind as ErrorKind,
    } as StreamResult, result_mt) as StreamResult
end

--- Open a streaming HTTP request.
--- Unlike Fetch, returns immediately with a reader for incremental body
--- access. Takes the same options as Fetch except the retry fields
--- (max_attempts, base_delay, max_delay, should_retry), which do not
--- apply to streams.
--- @param url string URL to fetch
--- @param opts Options optional fetch options
--- @return StreamResult with reader for incremental body access
local function stream(url: string, opts?: Options): StreamResult
  local verr = validate_url(url)
  if verr then
    return stream_fail(verr, nil)
  end
  local herr = opts and validate_headers(opts.headers)
  if herr then
    return stream_fail(herr, nil)
  end

  local status, headers_or_err, reader_or_kind, final_url = cosmo.FetchStream(url, to_fetch_options(opts))
  if not status then
    return stream_fail(headers_or_err, reader_or_kind)
  end

  local headers, raw_headers = fetch_headers.normalize(headers_or_err as {string: any})
  return setmetatable({
      ok = true,
      status = status as integer,
      headers = headers,
      raw_headers = raw_headers,
      reader = make_reader(reader_or_kind as cosmo.StreamReader),
      url = final_url,
    } as StreamResult, result_mt) as StreamResult
end

--- Build a unix domain socket proxy URL from a socket path.
--- @param path string Absolute path to the unix domain socket
--- @return string | nil proxy URL in unix:// format
--- @return string? Error message if path is invalid
local function unix_proxy(path: string): string | nil, string
  if not path or path == "" then
    return nil, "empty socket path"
  end
  if path:sub(1, 1) ~= "/" then
    return nil, "socket path must be absolute"
  end
  if path:match("/%.%./") or path:match("/%.%.$") or path:match("/%./") or path:match("/%.$") then
    return nil, "socket path must not contain . or .. segments"
  end
  -- unix(7) sockaddr_un sun_path is typically 108 bytes
  if #path >= 108 then
    return nil, "socket path too long"
  end
  return "unix://" .. path
end

local record FetchModule
  fetch: function(url: string, opts?: Options): Result
  stream: function(url: string, opts?: Options): StreamResult
  unix_proxy: function(path: string): string | nil, string
  type ErrorKind = ErrorKind
  Options: Options
  Result: Result
  Reader: Reader
  StreamResult: StreamResult
end

local M: FetchModule = {
  fetch = Fetch,
  stream = stream,
  unix_proxy = unix_proxy,
}

return M
