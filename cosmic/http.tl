--- HTTP and HTTPS, typed, over core/http.c's curl/c-ares/mbedtls
--- binding: HTTP/HTTPS only, no cookies, no HTTP/2, no compressed
--- transfer-encoding (no zlib vendored).
---
---     local got = assert(Http.get("https://example.com/"))
---     print(got.status, got.body)
---     local ok, trouble = Http.download(
---       "https://example.com/big.zip", "big.zip", { sha256 = "..." })
---
--- `Http.open` blocks until the final response's headers have arrived
--- (following every redirect `opts.follow` allows) and hands back a
--- `Response` whose body is read a chunk at a time; `Http.get` reads
--- the whole body for the common case, and `Http.download` streams it
--- straight to a file, verifying a checksum while it goes.
---
--- The raw module behind this one lives under the reserved
--- `cosmic.internal.` namespace, which never satisfies an ordinary
--- `require` for any caller -- see cosmic/store.tl for why -- and
--- arrives instead as the second argument `require` passes this
--- chunk's own loader, present because this module was itself loaded,
--- trusted, from the binary's own tree. Boot mode falls back to
--- requiring it by name, which only boot's own preload answers.
local type raw_http = require("cosmic.internal.http")

local extra: any = select(2, ...)
local http: raw_http
if type(extra) == "table" then
  http = extra as raw_http
else
  http = require("cosmic.internal.http")
end

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local sys = require("cosmic.sys")

local record Http
  --- One request. `follow` defaults to true, `max_redirects` to 10;
  --- a followed 303, or a 301/302 after a POST, turns the request
  --- into a GET, as RFC 9110 says. `method` is case-sensitive, as
  --- HTTP's are, and defaults to GET, or POST when there is a `body`.
  ---
  --- A connection not made within `connect_timeout_ms` (default
  --- 30000) fails, and so does a transfer that moves fewer than
  --- `low_speed_bytes` (default 1) per second for `low_speed_seconds`
  --- (default 60) straight; 0 turns either check off. `timeout_ms`
  --- bounds the whole request and has no default. `sha256` is read
  --- only by `Http.download`.
  ---
  --- `script` is for tests: instead of connecting anywhere, the Nth
  --- connection curl opens (plain http only, one request each) reads
  --- `script[N]` as the server's whole reply, and `Response:sent`
  --- returns what curl wrote.
  ---
  --- An option of the wrong shape is a bug, and `Http.open` raises
  --- for it, naming the option: a value of the wrong Lua type (the
  --- integers take no numeric strings), a number with a fraction, or
  --- one out of range. Every integer must be at least 0;
  --- `max_redirects` is at most 32767 and `low_speed_seconds` at most
  --- 65535. A value of the right shape that cannot be sent as given
  --- is data, returned as `nil, err`: a method that is no HTTP token,
  --- a header name or value holding CR, LF or NUL (or a name that is
  --- empty or holds ':'), a URL holding NUL or one curl rejects.
  record Options is raw_http.Options
    method: string
    headers: {string:string}
    body: string
    follow: boolean
    max_redirects: integer
    connect_timeout_ms: integer
    timeout_ms: integer
    low_speed_bytes: integer
    low_speed_seconds: integer
    verbose: boolean
    script: {string}
    -- Http.download only: the expected sha256, as lowercase hex.
    sha256: string
  end

  --- An open response. `status`, `headers` and `url` (the effective
  --- URL, after every redirect taken) are already known when
  --- `Http.open` returns them; `read` pulls the body a chunk at a
  --- time. `headers` is keyed by lowercased name, and a name the
  --- response repeats has its values joined with ", " (RFC 9110
  --- 5.3) -- Set-Cookie's, which may hold commas themselves, with
  --- "\n" instead. `close` is idempotent, and a `<close>` variable
  --- closes the response when it goes out of scope; a method called
  --- on the raw handle after close raises.
  record Response
    metamethod __close: function(Response)
    status: integer
    headers: {string:string}
    url: string
    read: function(Response, max?: integer): string | nil, string
    close: function(Response)
    sent: function(Response): string
  end

  --- What `Http.get` returns: a status, a whole body, and headers,
  --- bundled into one value since a public fallible function here
  --- returns exactly `(value, string)`.
  record Body
    status: integer
    body: string
    headers: {string:string}
  end
end

local response_mt: metatable<Http.Response> = {
  __close = function(self: Http.Response)
    self:close()
  end,
}

--- Opens `url`, blocking until the final response's headers arrive.
--- The body is not read yet -- call `response:read(max)` until it
--- returns `nil, ""` for a clean end, or use `Http.get` to read it
--- all at once.
function Http.open(url: string, opts?: Http.Options): Http.Response | nil, string
  local handle, trouble = http.open(url, opts)
  if handle == nil then
    return nil, trouble
  end
  local response: Http.Response = {
    status = handle:status(),
    headers = handle:headers(),
    url = handle:url(),
    read = function(_self: Http.Response, max?: integer): string | nil, string
      return handle:read(max)
    end,
    close = function(_self: Http.Response)
      handle:close()
    end,
    sent = function(_self: Http.Response): string
      return handle:sent()
    end,
  }
  setmetatable(response, response_mt)
  return response, ""
end

--- `Http.open`, then the whole body read at once. Fails on a
--- connection or protocol error the same way `Http.open` does; a
--- non-2xx status is not itself a failure here -- check `result.status`.
function Http.get(url: string, opts?: Http.Options): Http.Body | nil, string
  local response, trouble = Http.open(url, opts)
  if response == nil then
    return nil, trouble
  end
  local parts: {string} = {}
  while true do
    local chunk, read_trouble = response:read()
    if chunk == nil then
      response:close()
      if read_trouble ~= "" then
        return nil, read_trouble
      end
      break
    end
    parts[#parts + 1] = chunk
  end
  return { status = response.status, body = table.concat(parts),
    headers = response.headers }, ""
end

--- Copies `response`'s body to `fd`, feeding `hasher` (when there is
--- one) as it goes.
local function copy_body(response: Http.Response, fd: integer, hasher: Hash.Hasher): boolean, string
  while true do
    local chunk, trouble = response:read()
    if chunk == nil then
      if trouble ~= "" then return false, trouble end
      return true, ""
    end
    if hasher ~= nil then
      hasher:update(chunk)
    end
    local put, put_trouble = Fs.put(fd, chunk)
    if not put then
      return false, put_trouble
    end
  end
end

--- Downloads `url` to `path`, as `curl -fLo` or `wget` would, streaming
--- to a fresh temporary file beside it -- created exclusively, so two
--- downloads never share one and a planted symlink is never followed --
--- and renaming into place only once the transfer is complete, synced to
--- disk and, when `opts.sha256` is given, verified -- a reader never sees
--- a partial file at the final name. Fails on a non-2xx status (a
--- redirect `opts.follow` already took does not count) or a checksum
--- mismatch, and removes the temporary file on every failure.
function Http.download(url: string, path: string, opts?: Http.Options): boolean, string
  local want = opts ~= nil and opts.sha256 or ""
  local hasher: Hash.Hasher = nil
  if want ~= "" then
    local made, hasher_trouble = Hash.hasher("sha256")
    if made == nil then
      return false, hasher_trouble
    end
    hasher = made
  end
  local response, open_trouble = Http.open(url, opts)
  if response == nil then
    return false, open_trouble
  end
  if response.status < 200 or response.status >= 300 then
    response:close()
    return false, url .. ": HTTP " .. tostring(response.status)
  end

  local temporary, open_write_trouble = sys.open_temporary(path, 0x1a4)
  if temporary == nil then
    response:close()
    return false, path .. ": " .. open_write_trouble
  end
  local part, fd = temporary.path, temporary.fd
  local ok, trouble = copy_body(response, fd, hasher)
  response:close()
  if ok then
    ok, trouble = Fs.fsync(fd)
  end
  local closed, close_trouble = Fs.close(fd)
  if ok and not closed then
    ok, trouble = false, close_trouble
  end
  if ok and hasher ~= nil then
    local digest, digest_trouble = hasher:digest()
    if digest == nil then
      ok, trouble = false, digest_trouble
    elseif Hash.hex(digest) ~= want:lower() then
      ok, trouble = false, path .. ": sha256 mismatch: want " .. want ..
        ", got " .. Hash.hex(digest)
    end
  end
  if ok then
    ok, trouble = Fs.rename(part, path)
  end
  if not ok then
    local _, _ = Fs.remove(part)
    return false, trouble
  end
  return true, ""
end

return Http
