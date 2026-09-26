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
--- `Response` whose body is read a chunk at a time -- a
--- `cosmic.stream` Reader, so `Stream.copy`, `Stream.transform` and the
--- rest take it as they take a file; `Http.get` reads the whole body
--- for the common case, and `Http.download` streams it straight to a
--- file, verifying a checksum while it goes.
---
--- The raw module behind this one lives under the reserved
--- `cosmic.internal.` namespace, which never satisfies an ordinary
--- `require` for any caller -- see cosmic/store.tl for why -- and
--- arrives instead as the second argument `require` passes this
--- chunk's own loader, present because this module was itself loaded,
--- trusted, from the binary's own tree. Boot mode falls back to
--- requiring it by name, which only boot's own preload answers.
local Codec = require("cosmic.codec")
local type raw_http = require("cosmic.internal.http")

local extra: any = select(2, ...)
local http: raw_http
if type(extra) == "table" then
  http = extra as raw_http
else
  http = require("cosmic.internal.http")
end

local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
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
  --- only by `Http.download`, and `body_size` only by `Http.upload`.
  ---
  --- `script` is for tests: instead of connecting anywhere, the Nth
  --- connection curl opens (one request each) reads `script[N]` as the
  --- server's whole reply, and `Response:sent` returns what curl wrote.
  --- Over https that reply is the server's side of the TLS handshake,
  --- which a canned one cannot complete, but it can carry a certificate
  --- to see how it is verified.
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
    body_size: integer
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

  --- An open response, and a `cosmic.stream` Reader of its body.
  --- `status`, `headers` and `url` (the effective URL, after every
  --- redirect taken) are already known when `Http.open` returns them;
  --- `read` pulls the body a chunk at a time, `nil, ""` at its clean
  --- end and the same error again after a failure. `headers` is keyed
  --- by lowercased name, and a name the response repeats has its
  --- values joined with ", " (RFC 9110 5.3) -- Set-Cookie's, which may
  --- hold commas themselves, with "\n" instead. `close` always
  --- succeeds and is idempotent, a `<close>` variable closes the
  --- response when it goes out of scope, and a `read` after either
  --- fails. `sent` after close raises.
  record Response is Stream.Reader
    metamethod __close: function(Response)
    status: integer
    headers: {string:string}
    url: string
    sent: function(Response): string
  end

  --- A request whose body is written a chunk at a time: a
  --- `cosmic.stream` Writer, so `Stream.copy` fills it from a file, a
  --- child's output or another response. Each `write` blocks until curl
  --- has taken the chunk. `close` ends the body and blocks until the
  --- final response's headers arrive, and `response` then hands the
  --- response over, or why there is none; asked before `close`, it
  --- closes first. A `write` fails once the request has, or once the
  --- server has answered before the body was all sent -- `response`
  --- then says what it answered. `abort` gives up on the request.
  record Upload is Stream.Writer
    response: function(Upload): Response | nil, string
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
    local _, _ = self:close()
  end,
}

--- The Response over a handle whose final headers are known.
local function respond(handle: raw_http.Handle): Http.Response
  local closed = false
  local response: Http.Response = {
    status = handle:status(),
    headers = handle:headers(),
    url = handle:url(),
    read = function(_self: Stream.Reader, max?: integer): string | nil, string
      if closed then return nil, "http: the response is closed" end
      return handle:read(max)
    end,
    close = function(_self: Stream.Reader): boolean, string
      closed = true
      handle:close()
      return true, ""
    end,
    sent = function(_self: Http.Response): string
      return handle:sent()
    end,
  }
  setmetatable(response, response_mt)
  return response
end

--- Opens `url`, blocking until the final response's headers arrive.
--- The body is not read yet -- call `response:read(max)` until it
--- returns `nil, ""` for a clean end, or use `Http.get` to read it
--- all at once.
function Http.open(url: string, opts?: Http.Options): Http.Response | nil, string
  local handle, trouble = http.open(url, opts)
  if handle == nil then
    return nil, trouble
  end
  return respond(handle), ""
end

local closed_message <const> = "http: the request body is already closed"

--- Starts a request to `url` whose body is written to the Upload it
--- returns, as a POST unless `opts.method` names another. Its size,
--- when `opts.body_size` gives it, is sent as the Content-Length --
--- a body that then comes out another size fails the request -- and
--- otherwise the body goes chunked. `opts.body` is refused, and a HEAD
--- is `nil, err`, as neither has a body to write. Nothing is sent
--- before the first `write` (or `close`). A redirect that would send
--- the body again (a 307 or 308) fails the request, since what was
--- written cannot be written again.
-- TODO: follow a 307 or 308 with a streamed body by asking the caller
-- for it again (a function answering a fresh Reader, say) behind a
-- CURLOPT_SEEKFUNCTION that rewinds to it, once a caller must upload
-- through such a redirect; curl answers "necessary data rewind was not
-- possible" for one today.
function Http.upload(url: string, opts?: Http.Options): Http.Upload | nil, string
  local started, trouble = http.start(url, opts)
  if started == nil then
    return nil, trouble
  end
  local handle: raw_http.Handle = started
  local closed = false
  local answered: Http.Response
  local failure = ""
  local up: Http.Upload = {}
  up.write = function(_self: Stream.Writer, data: string): boolean, string
    if closed then return false, closed_message end
    return handle:write(data)
  end
  up.close = function(_self: Stream.Writer): boolean, string
    if closed then
      if failure ~= "" then return false, failure end
      return true, ""
    end
    closed = true
    local finished, why = handle:finish()
    if not finished then
      failure = why
      handle:close()
      return false, failure
    end
    answered = respond(handle)
    return true, ""
  end
  up.abort = function(_self: Stream.Writer): boolean, string
    if closed then return true, "" end
    closed = true
    failure = "http: the request was aborted"
    handle:close()
    return true, ""
  end
  up.response = function(self: Http.Upload): Http.Response | nil, string
    if not closed then
      local _, _ = self:close()
    end
    if answered == nil then return nil, failure end
    return answered, ""
  end
  return up, ""
end

--- `Http.open`, then the whole body read at once. Fails on a
--- connection or protocol error the same way `Http.open` does; a
--- non-2xx status is not itself a failure here -- check `result.status`.
function Http.get(url: string, opts?: Http.Options): Http.Body | nil, string
  local response, trouble = Http.open(url, opts)
  if response == nil then
    return nil, trouble
  end
  local body, read_trouble = Stream.read_all(response)
  local _, _ = response:close()
  if body == nil then
    return nil, read_trouble
  end
  return { status = response.status, body = body, headers = response.headers }, ""
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
  local hashing: Stream.Hashing = nil
  if want ~= "" then
    local made, hasher_trouble = Stream.hashing("sha256")
    if made == nil then
      return false, hasher_trouble
    end
    hashing = made
  end
  local response, open_trouble = Http.open(url, opts)
  if response == nil then
    return false, open_trouble
  end
  if response.status < 200 or response.status >= 300 then
    local _, _ = response:close()
    return false, url .. ": HTTP " .. tostring(response.status)
  end

  local temporary, open_write_trouble = sys.open_temporary(path, 0x1a4)
  if temporary == nil then
    local _, _ = response:close()
    return false, path .. ": " .. open_write_trouble
  end
  local part, fd = temporary.path, temporary.fd
  local writer = Stream.to_fd(fd)
  if hashing ~= nil then writer = Stream.tee(writer, hashing) end
  local copied, trouble = Stream.copy(response, writer)
  local _, _ = response:close()
  local ok = copied ~= nil
  if ok then
    ok, trouble = Fs.fsync(fd)
  end
  local closed, close_trouble = Fs.close(fd)
  if ok and not closed then
    ok, trouble = false, close_trouble
  end
  if ok and hashing ~= nil then
    local digest, digest_trouble = hashing:digest()
    if digest == nil then
      ok, trouble = false, digest_trouble
    elseif Codec.hex(digest) ~= want:lower() then
      ok, trouble = false, path .. ": sha256 mismatch: want " .. want ..
        ", got " .. Codec.hex(digest)
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

--- Whether the TLS stack reads `der` as one X.509 certificate, as it
--- reads each CA root this binary trusts: true and "", or false and its
--- reason. A certificate it cannot read is one it would never trust, so
--- a set of roots is worth checking with this before a binary carries
--- it. Raises when there was no memory to read it.
function Http.check_certificate(der: string): boolean, string
  return http.check_certificate(der)
end

return Http
