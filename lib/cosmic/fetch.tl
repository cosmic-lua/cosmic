--- Structured HTTP fetch with optional retry.
--- Wraps cosmo.Fetch with structured results to prevent accidentally discarding errors.

local cosmo = require("cosmo")
local time = require("cosmic.time")

--- Result from a fetch operation.
local record Result
  ok: boolean
  status: number
  headers: {string:string}
  body: string
  error: string
end

local record Opts
  headers: {string:string}
  maxresponse: number
  max_attempts: number
  max_delay: number
  should_retry: function(Result): boolean
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
  headers: {string:string}
  reader: Reader
  error: string
end

local function do_fetch(url: string, opts?: Opts): Result
  local status: number
  local headers_or_err: {string:string} | string
  local body: string

  status, headers_or_err, body = cosmo.Fetch(url, opts as {string:any})

  if not status then
    return {ok = false, error = tostring(headers_or_err or "unknown error")}
  end

  return {
    ok = true,
    status = status,
    headers = headers_or_err as {string:string},
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
    local buffer = ""
    local done = false

    return function(): string
      while not done do
        local newline_pos = buffer:find("\n")
        if newline_pos then
          local line = buffer:sub(1, newline_pos - 1)
          buffer = buffer:sub(newline_pos + 1)
          return line
        end

        local chunk = self:read()
        if not chunk then
          done = true
          if #buffer > 0 then
            local remaining = buffer
            buffer = ""
            return remaining
          end
          return nil
        end
        buffer = buffer .. chunk
      end
      return nil
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
  local status: number
  local headers_or_err: {string:string} | string
  local raw_reader: cosmo.StreamReader

  status, headers_or_err, raw_reader = cosmo.FetchStream(url, opts as {string:any})

  if not status then
    return {ok = false, error = tostring(headers_or_err or "unknown error")}
  end

  return {
    ok = true,
    status = status,
    headers = headers_or_err as {string:string},
    reader = make_reader(raw_reader),
  }
end

-- Example_get demonstrates a simple HTTP GET request
local function Example_get()
  local fetch = require("cosmic.fetch")
  local result = fetch.Fetch("https://httpbin.org/get")
  print("status:", result.status)
  print("ok:", result.ok)
  -- Output:
  -- status:	200
  -- ok:	true
end

-- Example_get_json demonstrates fetching and parsing JSON
local function Example_get_json()
  local fetch = require("cosmic.fetch")
  local json = require("cosmic.json")
  local result = fetch.Fetch("https://httpbin.org/json")
  local data = json.decode(result.body) as {string:{string:string}}
  print("title:", data.slideshow.title)
  -- Output:
  -- title:	Sample Slide Show
end

local record fetch
  Fetch: function(url: string, opts?: Opts): Result
  stream: function(url: string, opts?: Opts): StreamResult
  Opts: Opts
  Result: Result
  Reader: Reader
  StreamResult: StreamResult
end

local M: fetch = {
  Fetch = Fetch,
  stream = stream,
}

return M
