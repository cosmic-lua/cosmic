--- Structured HTTP fetch with optional retry.
--- Wraps cosmo.Fetch with structured results to prevent accidentally discarding errors.

local cosmo = require("cosmo")
local time = require("cosmic.time")

--- Result from a fetch operation.
local record Result
  ok: boolean
  status: number
  headers: {string: string}
  body: string
  error: string
end

--- Options for fetch requests.
local record Opts
  --- HTTP method (default "GET").
  method: string
  --- Request body to send (for POST, PUT, PATCH).
  body: string
  --- HTTP headers to send with the request.
  headers: {string: string}
  --- HTTP proxy URL.
  proxy: string
  --- Maximum response body size in bytes.
  maxresponse: number
  --- Total number of attempts (1 = no retry, default 1).
  --- Retries only occur when result.ok is true and should_retry returns true.
  max_attempts: number
  --- Maximum backoff delay in seconds (default 30).
  --- Backoff is exponential: 2^attempt seconds, capped at this value.
  max_delay: number
  --- Predicate called after each successful HTTP response to decide retry.
  --- Return true to retry (e.g. on status 429 or 503). If nil, no retries.
  should_retry: function(Result): boolean
  --- Request timeout in seconds. If nil, no timeout is applied.
  timeout: number
end

--- Streaming reader for incremental body access.
--- Supports Lua 5.4's to-be-closed via __close metamethod.
local record Reader
  read: function(self: Reader): string, string
  close: function(self: Reader): boolean
  closed: function(self: Reader): boolean
  lines: function(self: Reader): function(): string
end

--- Result from a streaming fetch operation.
local record StreamResult
  ok: boolean
  status: number
  headers: {string: string}
  reader: Reader
  error: string
end

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

local function do_fetch(url: string, opts?: Opts): Result
  local verr = validate_url(url)
  if verr then
    return {ok = false, error = verr}
  end
  local herr = opts and validate_headers(opts.headers)
  if herr then
    return {ok = false, error = herr}
  end

  local status: number
  local headers_or_err: {string: string} | string
  local body: string

  status, headers_or_err, body = cosmo.Fetch(url, opts as {string: any})

  if not status then
    return {ok = false, error = tostring(headers_or_err or "unknown error")}
  end

  return {
    ok = true,
    status = status,
    headers = headers_or_err as {string: string},
    body = body,
  }
end

--- Fetch a URL and return structured result.
--- @param url string URL to fetch
--- @param opts Opts optional fetch options (retry, headers, etc.)
--- @return Result fetch result with ok, status, headers, body, or error
local function Fetch(url: string, opts?: Opts): Result
  local max_attempts = (opts and opts.max_attempts) or 1
  local max_delay = (opts and opts.max_delay) or 30
  local should_retry = opts and opts.should_retry

  local result: Result
  for attempt = 1, max_attempts do
    result = do_fetch(url, opts)

    if not result.ok or not should_retry or not should_retry(result) then
      return result
    end

    if attempt < max_attempts then
      time.sleep(math.min(max_delay, 2 ^ attempt))
    end
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
  --- @return string chunk or nil on EOF
  --- @return string error message on failure
  function reader:read(): string, string
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
  --- @return function iterator yielding lines without trailing newline
  function reader:lines(): function(): string
    -- Scan-position index into buffer: `pos` is the first unread byte.
    -- Advancing it instead of slicing off each returned line, and dropping
    -- the consumed prefix only when we must read more, keeps the whole loop
    -- linear in the byte count. The previous buffer:sub()-per-line and
    -- buffer..chunk-per-chunk both re-copied the entire buffer, making line
    -- iteration O(n²) in the body size (audit §7.2 P1).
    local buffer = ""
    local pos = 1
    local done = false

    return function(): string
      while true do
        local newline_pos = buffer:find("\n", pos, true)
        if newline_pos then
          local line = buffer:sub(pos, newline_pos - 1)
          pos = newline_pos + 1
          return line
        end

        if done then
          -- EOF with a final unterminated line still buffered: yield it once.
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
        local chunk = self:read()
        if not chunk then
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

--- Open a streaming HTTP request.
--- Unlike Fetch, returns immediately with a reader for incremental body access.
--- @param url string URL to fetch
--- @param opts Opts optional fetch options
--- @return StreamResult with reader for incremental body access
local function stream(url: string, opts?: Opts): StreamResult
  local verr = validate_url(url)
  if verr then
    return {ok = false, error = verr}
  end
  local herr = opts and validate_headers(opts.headers)
  if herr then
    return {ok = false, error = herr}
  end

  local status: number
  local headers_or_err: {string: string} | string
  local raw_reader: cosmo.StreamReader

  status, headers_or_err, raw_reader = cosmo.FetchStream(url, opts as {string: any})

  if not status then
    return {ok = false, error = tostring(headers_or_err or "unknown error")}
  end

  return {
    ok = true,
    status = status,
    headers = headers_or_err as {string: string},
    reader = make_reader(raw_reader),
  }
end

--- Report whether the streaming fetch primitive is available in this build.
--- When false, stream() cannot be used; callers should fall back to Fetch().
--- @return boolean true if fetch.stream() is supported
local function has_stream(): boolean
  return cosmo.FetchStream ~= nil
end

--- Build a unix domain socket proxy URL from a socket path.
--- @param path string Absolute path to the unix domain socket
--- @return string proxy URL in unix:// format
--- @return string? Error message if path is invalid
local function unix_proxy(path: string): string, string
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

local M: fetch = {
  Fetch = Fetch,
  stream = stream,
  has_stream = has_stream,
  unix_proxy = unix_proxy,
}

return M
