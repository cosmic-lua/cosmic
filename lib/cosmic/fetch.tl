--- Structured HTTP fetch with optional retry.
--- Wraps cosmo.Fetch with structured results to prevent accidentally discarding errors.

local cosmo = require("cosmo")
local unix = require("cosmo.unix")

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
      unix.nanosleep(math.min(max_delay, 2 ^ attempt), 0)
    end
  end

  return result
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
  Opts: Opts
  Result: Result
end

local M: fetch = {
  Fetch = Fetch,
}

return M
