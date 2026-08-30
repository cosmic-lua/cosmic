--- The authenticated GitHub REST core the board's calls are built on:
--- one request function, its error rendering, and the success test.
--- `_work.gh` holds the board-shaped calls; this holds the transport
--- they share. Every call the board makes is a GET — the board reads
--- GitHub and never writes to it — so a request carries no body at
--- all. Auth is a GITHUB_TOKEN (or GH_TOKEN) env var; HTTPS_PROXY is
--- honored, and behind a TLS-intercepting proxy set
--- SSL_USE_SYSTEM_CERTS=1 SSL_CERT_FILE=<bundle> (read by the cosmos
--- TLS root loader).
---
--- The whole fleet shares one account's REST quota (5,000 calls/hour,
--- across every token), so every call here spends it carefully: a GET
--- carries the ETag it was last served (`If-None-Match`) and reuses
--- the cached body on a 304 — which GitHub does not count against the
--- limit at all — and every response's rate-limit headers are read so
--- a caller can back off before a refusal, not just after one. The
--- cache lives under the board checkout's `o/` (`root`, a store's
--- checkout root): untracked, disposable, and best-effort — a cache
--- miss or a write failure here is exactly a cache miss, never a
--- failure the call itself reports. Keyed by request path, one file
--- per (method, path) pair.
local env = require("cosmic.env")
local fetch = require("cosmic.fetch")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local json = require("cosmic.json")
local literal = require("cosmic.literal")
local time = require("cosmic.time")

--- One API exchange that got a response: its status, decoded body,
--- and the response headers it carried (lowercase names) — a caller
--- reads `res.value["message"]` off an error body, or the rate-limit
--- facts straight off `remaining`/`reset`. `remaining`/`reset` are nil
--- when the response carried neither header, never fabricated as 0,
--- which is a real remaining count.
local record ApiResult
  status: integer
  value: any
  headers: {string: string}
  remaining: integer | nil
  reset: integer | nil
end

local API < const > = "https://api.github.com"

--- Where the board's disposable GitHub cache lives, under a store's
--- `o/` — the same directory `--make build` writes into, gitignored
--- on the board branch already.
local CACHE_DIR < const > = "gh-cache"

--- One cached exchange: enough to revalidate (the ETag) and reuse
--- (the body) without a live call. `status` is what was reported
--- when the ETag was minted — reused verbatim on a 304, since GitHub
--- sends none of its own.
local record CacheEntry
  status: integer
  etag: string
  body: string
end

--- The path a request's cache entry lives at: a hash of method+path so
--- an arbitrary request path (any slash, any length) becomes one safe
--- filename.
--- @param root string The store checkout root ("" disables the cache)
--- @param method string HTTP method
--- @param path string Request path
--- @return string The cache entry's path
local function cache_path(root: string, method: string, path: string): string
  local key = hash.sha256_hex(method .. " " .. path)
  return fs.join(root, "o", CACHE_DIR, key .. ".tl")
end

--- Read a request's cached entry. nil means a cache miss — no entry
--- yet, or one that fails to parse (a half-written file, a format
--- this code no longer reads) — never a failure the caller must
--- handle; a miss just means the request goes out with no
--- `If-None-Match`.
--- @param root string The store checkout root ("" disables the cache)
--- @param method string HTTP method
--- @param path string Request path
--- @return CacheEntry | nil The cached entry, nil on a miss
local function read_cache(root: string, method: string, path: string): CacheEntry | nil
  if root == "" then
    return nil
  end
  local t = literal.parse_file(cache_path(root, method, path))
  if t == nil then
    return nil
  end
  local status = t["status"]
  local etag = t["etag"]
  local body = t["body"]
  if status is integer and etag is string and body is string then
    return {status = status, etag = etag, body = body}
  end
  return nil
end

--- Write a request's cache entry. Best-effort: a write failure here
--- (a missing `o/`, a read-only checkout) never fails the call that
--- produced the value to cache — the cache is a speed-up, not a
--- contract, the same posture `cosmic._script_cache` takes.
--- @param root string The store checkout root ("" disables the cache)
--- @param method string HTTP method
--- @param path string Request path
--- @param entry CacheEntry The entry to write
local function write_cache(root: string, method: string, path: string,
    entry: CacheEntry)
  if root == "" then
    return
  end
  -- Fire-and-forget: a write failure here (a missing `o/`, a
  -- read-only checkout) never fails the call that produced the value
  -- to cache — see the header note above.
  local _ok, _err = fs.make_dirs(fs.join(root, "o", CACHE_DIR))
  local _wok, _werr = literal.format_file(cache_path(root, method, path),
    {status = entry.status, etag = entry.etag, body = entry.body})
end

--- Fold a live response against what was cached for this request:
--- a 304 means the body is unchanged, so the cached status and body
--- are what the caller sees, and GitHub does not charge the REST
--- quota for it; any other status is the response as it arrived,
--- cached fresh when it carries an ETag to revalidate against next
--- time. Pure — no fetch, no filesystem — so the 304 path is proven
--- with a fabricated response and no live call at all.
--- @param cached CacheEntry | nil What `read_cache` found, if anything
--- @param status integer The live response's status
--- @param headers {string: string} The live response's headers
--- @param body string The live response's body ("" on a real 304)
--- @return integer Status to report to the caller
--- @return string Body to decode
--- @return CacheEntry | nil A fresh entry to write, nil when nothing to cache
local function reconcile(cached: CacheEntry | nil, status: integer,
    headers: {string: string}, body: string): integer, string, CacheEntry | nil
  if status == 304 and cached ~= nil then
    return cached.status, cached.body, nil
  end
  local fresh: CacheEntry | nil = nil
  if status >= 200 and status < 300 then
    local etag = headers["etag"]
    if etag ~= nil and etag ~= "" then
      fresh = {status = status, etag = etag, body = body}
    end
  end
  return status, body, fresh
end

--- The rate-limit facts a response carried. nil for either one means
--- the response carried no such header — GitHub sends both on every
--- REST response, but a transport-level fake or an unusual response
--- might not.
--- @param headers {string: string} Response headers, lowercase names
--- @return integer | nil Requests remaining in the current hour
--- @return integer | nil UNIX seconds the window resets
local function rate_of(headers: {string: string}): integer | nil, integer | nil
  local remaining = math.tointeger(tonumber(headers["x-ratelimit-remaining"]))
  local reset = math.tointeger(tonumber(headers["x-ratelimit-reset"]))
  return remaining, reset
end

--- Where the most recently observed rate-limit facts are persisted —
--- one file per store, so an optional caller (lane health) can check
--- the quota before spending a call on it, with no request of its
--- own. Same disposable `o/` cache, a fixed name rather than a hash
--- since there is only ever one "most recent" fact to keep.
--- @param root string The store checkout root
--- @return string The rate file's path
local function rate_path(root: string): string
  return fs.join(root, "o", CACHE_DIR, "_ratelimit.tl")
end

--- Persist the rate-limit facts a response carried. Best-effort, like
--- `write_cache`: nothing here can fail the call that read them.
--- @param root string The store checkout root ("" disables the cache)
--- @param remaining integer | nil Requests remaining, nil to skip the write
--- @param reset integer | nil UNIX seconds the window resets
local function write_rate(root: string, remaining: integer | nil,
    reset: integer | nil)
  if root == "" or remaining == nil then
    return
  end
  -- Fire-and-forget, same posture as `write_cache`.
  local _ok, _err = fs.make_dirs(fs.join(root, "o", CACHE_DIR))
  local _wok, _werr = literal.format_file(rate_path(root),
    {remaining = remaining, reset = reset or 0})
end

--- The rate-limit facts the most recent call recorded. nil for either
--- one means none has ever been written (a fresh checkout, one with
--- no `o/` yet) or the file no longer parses — never a failure, an
--- absent fact reads as "unknown," and unknown never blocks an
--- optional read.
--- @param root string The store checkout root ("" disables the cache)
--- @return integer | nil Requests remaining as of the last call
--- @return integer | nil UNIX seconds the window resets
local function read_rate(root: string): integer | nil, integer | nil
  if root == "" then
    return nil, nil
  end
  local t = literal.parse_file(rate_path(root))
  if t == nil then
    return nil, nil
  end
  local remaining = t["remaining"]
  local reset = t["reset"]
  if not (remaining is integer) then
    return nil, nil
  end
  if reset is integer then
    return remaining, reset
  end
  return remaining, nil
end

--- One authenticated REST call. nil only when no response arrived
--- (missing token, transport failure); an HTTP error status is a
--- result — callers branch on res.status.
--- @param method string HTTP method
--- @param path string Path under api.github.com, leading slash
--- @param root string The store checkout root, for the ETag cache
--- and the rate-limit fact ("" disables both — no cache, no history)
--- @return ApiResult | nil The exchange
--- @return string Error message when no response arrived
local function api(method: string, path: string, root: string): ApiResult, string
  local token = env.get("GITHUB_TOKEN") or env.get("GH_TOKEN")
  if token == nil or token == "" then
    return nil, "no GitHub token: set GITHUB_TOKEN (or GH_TOKEN)"
  end
  local cached = method == "GET" and read_cache(root, method, path) or nil
  local headers: {string: string} = {
    ["authorization"] = "Bearer " .. token,
    ["accept"] = "application/vnd.github+json",
    ["x-github-api-version"] = "2022-11-28",
    ["user-agent"] = "cosmic-work-board",
  }
  if cached ~= nil and cached.etag ~= "" then
    headers["if-none-match"] = cached.etag
  end
  local resp, err = fetch.fetch(API .. path, {
      method = method,
      proxy = env.get("HTTPS_PROXY") or env.get("https_proxy"),
      headers = headers,
    })
  if resp == nil then
    return nil, ("%s %s: %s"):format(method, path, tostring(err))
  end
  local remaining, reset = rate_of(resp.headers)
  write_rate(root, remaining, reset)
  local status, body, fresh = reconcile(cached, resp.status, resp.headers,
    resp.body or "")
  if fresh ~= nil then
    write_cache(root, method, path, fresh)
  end
  local value: any = nil
  if #body > 0 then
    value = json.decode(body)
  end
  return {status = status, value = value, headers = resp.headers,
    remaining = remaining, reset = reset}, nil
end

--- Render a non-2xx exchange as an error message, using GitHub's own
--- "message" field when it sent one; a 403 or 429 that carried a
--- reset time names it, so a refusal says when the quota comes back
--- rather than just that it is gone.
--- @param method string HTTP method
--- @param path string Request path
--- @param res ApiResult The exchange
--- @return string The message
local function api_error(method: string, path: string, res: ApiResult): string
  local detail = ""
  local v = res.value
  if v is {string: any} then
    detail = ": " .. tostring(v["message"])
  end
  if (res.status == 403 or res.status == 429) and res.reset ~= nil then
    detail = detail .. (" (rate limit resets %s)"):format(
      time.format_http(res.reset))
  end
  return ("%s %s: HTTP %d%s"):format(method, path, res.status, detail)
end

--- Whether a status is a 2xx.
--- @param status integer HTTP status
--- @return boolean True for 2xx
local function is_success(status: integer): boolean
  return status >= 200 and status < 300
end

local record api_module
  type ApiResult = ApiResult
  type CacheEntry = CacheEntry
  call: function(method: string, path: string, root: string): ApiResult, string
  error_of: function(method: string, path: string, res: ApiResult): string
  is_success: function(status: integer): boolean
  --- Exported for tests only: the pure fold behind the 304 path,
  --- proven with a fabricated response rather than a live call.
  reconcile: function(cached: CacheEntry | nil, status: integer,
  headers: {string: string}, body: string): integer, string, CacheEntry | nil
  rate_of: function(headers: {string: string}): integer | nil, integer | nil
  read_rate: function(root: string): integer | nil, integer | nil
  write_rate: function(root: string, remaining: integer | nil, reset: integer | nil)
  read_cache: function(root: string, method: string, path: string): CacheEntry | nil
  write_cache: function(root: string, method: string, path: string, entry: CacheEntry)
end

local M: api_module = {
  call = api,
  error_of = api_error,
  is_success = is_success,
  reconcile = reconcile,
  rate_of = rate_of,
  read_rate = read_rate,
  write_rate = write_rate,
  read_cache = read_cache,
  write_cache = write_cache,
}

return M
