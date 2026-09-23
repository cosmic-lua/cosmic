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

local record Http
  --- One request. `follow` defaults to true, `max_redirects` to 10.
  --- `timeout_ms` bounds the whole request; there is no default (a
  --- slow-but-alive transfer never times out on its own -- pair it
  --- with `low_speed_bytes`/`low_speed_seconds` to catch that
  --- instead). `sha256` is read only by `Http.download`.
  record Options
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
    -- Http.download only: the expected sha256, as lowercase hex.
    sha256: string
  end

  --- An open response. `status`, `headers` (lowercased names, last
  --- one wins), and `url` (the effective URL, after every redirect
  --- taken) are already known when `Http.open` returns them; `read`
  --- pulls the body a chunk at a time.
  record Response
    status: integer
    headers: {string:string}
    url: string
    read: function(Response, max?: integer): string | nil, string
    close: function(Response)
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

--- Opens `url`, blocking until the final response's headers arrive.
--- The body is not read yet -- call `response:read(max)` until it
--- returns `nil, ""` for a clean end, or use `Http.get` to read it
--- all at once.
function Http.open(url: string, opts?: Http.Options): Http.Response | nil, string
  local handle, trouble = http.open(url, opts as raw_http.Options)
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
  }
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

--- Downloads `url` to `path`, streaming to `path .. ".part"` and
--- renaming into place only once the transfer is complete (and, when
--- `opts.sha256` is given, verified) -- a reader never sees a partial
--- file at the final name. Fails on a non-2xx status (a redirect
--- `opts.follow` already took does not count) or a checksum mismatch,
--- and removes the `.part` file either way.
function Http.download(url: string, path: string, opts?: Http.Options): boolean, string
  local response, open_trouble = Http.open(url, opts)
  if response == nil then
    return false, open_trouble
  end
  if response.status < 200 or response.status >= 300 then
    response:close()
    return false, url .. ": HTTP " .. tostring(response.status)
  end

  local part = path .. ".part"
  local fd, open_write_trouble = Fs.open_write(part)
  if fd == nil then
    response:close()
    return false, open_write_trouble
  end

  while true do
    local chunk, read_trouble = response:read()
    if chunk == nil then
      response:close()
      if read_trouble ~= "" then
        Fs.close(fd)
        Fs.remove(part)
        return false, read_trouble
      end
      break
    end
    local put, put_trouble = Fs.put(fd, chunk)
    if not put then
      response:close()
      Fs.close(fd)
      Fs.remove(part)
      return false, put_trouble
    end
  end
  Fs.close(fd)

  if opts ~= nil and opts.sha256 ~= nil and opts.sha256 ~= "" then
    local data, read_all_trouble = Fs.read(part)
    if data == nil then
      Fs.remove(part)
      return false, read_all_trouble
    end
    local got = Hash.hex_sha256(data)
    if got ~= opts.sha256:lower() then
      Fs.remove(part)
      return false, path .. ": sha256 mismatch: want " .. opts.sha256 ..
        ", got " .. got
    end
  end

  local renamed, rename_trouble = Fs.rename(part, path)
  if not renamed then
    Fs.remove(part)
    return false, rename_trouble
  end
  return true, ""
end

return Http
