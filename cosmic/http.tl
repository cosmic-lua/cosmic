--- HTTP and HTTPS requests, typed: HTTP and HTTPS only, with no cookies,
--- no HTTP/2 and no compressed transfer-encoding.
---
---     local got = assert(Http.get("https://example.com/"))
---     print(got.status, got.body)
---     local ok, trouble = Http.download(
---       "https://example.com/big.zip", "big.zip", { sha256 = "..." })
---
--- [`Http.open`] blocks until the final response's headers have arrived
--- (following every redirect `opts.follow` allows) and hands back a
--- [`Response`] whose body is read a chunk at a time -- a
--- [`cosmic.stream`] Reader, so [`Stream.copy`], [`Stream.transform`] and the
--- rest take it as they take a file; [`Http.get`] reads the whole body
--- for the common case, and [`Http.download`] streams it straight to a
--- file, verifying a checksum while it goes.

local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")

-- The raw module behind this one lives under the reserved
-- `cosmic.internal.` namespace, which an ordinary `require` never
-- satisfies (see cosmic/store.tl for why). It arrives instead as the
-- second argument the loader passes this chunk, present because this
-- module was itself loaded, trusted, from the binary's own tree. Boot
-- mode falls back to requiring it by name, which only boot's own
-- preload answers.
local type raw_http = require("cosmic.internal.http")
local Time = require("cosmic.time")

local extra: any = select(2, ...)
local http: raw_http
if type(extra) == "table" then
  http = extra as raw_http
else
  http = require("cosmic.internal.http")
end

local Stream = require("cosmic.stream")

local record Http
  --- One request. `follow` defaults to true, `max_redirects` to 10;
  --- a followed 303, or a 301/302 after a POST, turns the request
  --- into a GET, as RFC 9110 says. `method` is case-sensitive, as
  --- HTTP's are, and defaults to GET, or POST when there is a `body`.
  ---
  --- `redirect_protocols`, a list of "http" and "https", names the
  --- schemes a redirect may lead to (default both; the start URL's own
  --- is not limited by it): `{"https"}` refuses a redirect to http, so
  --- a request that started over https never falls back to plaintext,
  --- and the redirect refused fails the request. An empty list or any
  --- other entry raises (`follow = false` is how to take no redirect).
  ---
  --- While the innermost open [`Child.guard`] has caught SIGINT or SIGTERM, an
  --- open still waiting for its response fails with "interrupted", and
  --- so does a body's `read` that has no data to give. The signal stays
  --- the guard's to read.
  ---
  --- A connection not made within `connect_timeout_ns` (default 30
  --- seconds) fails, and so does a transfer that moves fewer than
  --- `low_speed_bytes` (default 1) per second for `low_speed_ns`
  --- (default 60 seconds) straight; 0 turns either check off.
  --- `timeout_ns` bounds the whole request and has no default. The
  --- transfer counts them in milliseconds, and `low_speed_ns` in whole
  --- seconds, each rounded up, so no span but 0 is read as none.
  --- `sha256`, `sha512` and `cancelled` are read only by [`Http.download`].
  ---
  --- `script` is for tests: instead of connecting anywhere, the Nth
  --- connection curl opens (one request each) reads `script[N]` as the
  --- server's whole reply, and [`Response:sent`] returns what curl wrote.
  --- Over https that reply is the server's side of the TLS handshake,
  --- which a canned one cannot complete, but it can carry a certificate
  --- to see how it is verified.
  ---
  --- An option of the wrong shape is a bug, and [`Http.open`] raises
  --- for it, naming the option: a value of the wrong Lua type (the
  --- integers take no numeric strings), a number with a fraction, or
  --- one out of range. Every integer must be at least 0;
  --- `max_redirects` is at most 32767 and `low_speed_ns` at most
  --- 65535 seconds. A value of the right shape that cannot be sent as given
  --- is data, returned as `nil, err`: a method that is no HTTP token,
  --- a header name or value holding CR, LF or NUL (or a name that is
  --- empty or holds ':'), a URL holding NUL or one curl rejects.
  record Options
    --- The HTTP method, case-sensitive; GET, or POST when there is a `body`.
    method: string
    --- Request headers, name to value.
    headers: {string:string}
    --- The request body, sent whole.
    body: string
    --- Whether to follow redirects; true by default.
    follow: boolean
    --- The most redirects followed, 10 by default.
    max_redirects: integer
    --- The schemes a redirect may lead to, "http" and "https" by default.
    redirect_protocols: {string}
    --- How long connecting may take, in nanoseconds; 30 seconds by default.
    connect_timeout_ns: integer
    --- How long the whole request may take, in nanoseconds; no limit by default.
    timeout_ns: integer
    --- The transfer rate, in bytes per second, under which a request
    --- is too slow; 1 by default and 0 turns the check off.
    low_speed_bytes: integer
    --- How long it may stay under `low_speed_bytes`, in nanoseconds; 60
    --- seconds by default.
    low_speed_ns: integer
    --- Whether curl logs the transfer to standard error.
    verbose: boolean
    --- Tests only: canned replies, one per connection, in place of the
    --- network. Every entry must be a string.
    script: {string}
    --- Http.download only: the expected sha256 and sha512, as hex. Each
    --- given is computed while the body is written and must match, or the
    --- download fails naming the algorithm, the digest wanted and the one
    --- got, leaving no file.
    sha256: string
    --- Http.download only: see `sha256`.
    sha512: string
    --- Http.download only: asked before each chunk is read and once
    --- more when the body is complete, before it is renamed into place;
    --- when it answers true the download stops, removes its temporary
    --- file, never creates `path`, and fails with "interrupted", the
    --- word a caught signal's failure says. It is how a caller holding
    --- a [`Child.guard`] ends a download on SIGINT while data keeps
    --- coming, which the guard alone ends only at a wait for it.
    -- TODO: drop `cancelled` once cosmic.internal.http's `open` and
    -- `read` check the innermost Child.guard whenever they are called, not
    -- only while they wait for data, so a guard alone ends a download
    -- whose body never makes them wait: the C waits do not read the
    -- guard when data is already there.
    cancelled: function(): boolean
  end

  --- An open response, and a [`cosmic.stream`] Reader of its body.
  --- `status`, `headers` and `url` (the effective URL, after every
  --- redirect taken) are already known when [`Http.open`] returns them;
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
    --- The final response's HTTP status code, after any redirect taken.
    status: integer
    --- The response's headers, keyed by lowercased name.
    headers: {string:string}
    --- The effective URL, after every redirect taken.
    url: string
    --- What curl wrote to the connection; for tests with a `script`.
    --- Raises after `close`.
    sent: function(Response): string
  end

  --- What [`Http.get`] returns: a status, a whole body, and headers,
  --- bundled into one value since a public fallible function here
  --- returns exactly `(value, string)`.
  record Body
    --- The final response's HTTP status code, after any redirect taken.
    status: integer
    --- The whole body, as bytes.
    body: string
    --- The response headers, keyed by lower-case name, as [`Response.headers`].
    headers: {string:string}
  end
end

local MS <const> = Time.ms(1)
local SECOND <const> = Time.seconds(1)

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
    read = function(_self: Stream.Reader, max_bytes?: integer): string | nil, string
      if closed then return nil, "http: the response is closed" end
      return handle:read(max_bytes)
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

--- The level `error` raises a refusal of `opts` at from [`counted`],
--- past [`raw_options`], [`opened`] and the public entry point that called
--- that: the entry point's caller. So every entry point calls
--- [`opened`] itself, and not as a tail call, which would leave no level
--- of its own.
local CALLER <const> = 5

--- `ns` as the count of `unit` nanoseconds the raw module takes, rounded
--- up so that a span above 0 is never the 0 that curl reads as no limit;
--- nil stays nil, the raw module's default. Raises at the caller of the
--- public entry point (`CALLER`), naming `name` as the raw module's own
--- refusals do, for what is no integer from 0 to `most_ns`.
local function counted(ns: integer | nil, unit: integer, most_ns: integer,
    name: string): integer | nil
  if ns == nil then return nil end
  if math.type(ns) ~= "integer" then
    error(("http: opts.%s must be an integer"):format(name), CALLER)
  end
  if ns < 0 or ns > most_ns then
    error(("http: opts.%s must be between 0 and %d"):format(name, most_ns), CALLER)
  end
  return Time.ceil(ns, unit)
end

--- `opts` as the raw module reads them: its spans in the milliseconds
--- (and, for `low_speed_ns`, the seconds) it counts them in.
local function raw_options(opts: Http.Options | nil): raw_http.Options | nil
  if opts == nil then return nil end
  return {
    method = opts.method,
    headers = opts.headers,
    body = opts.body,
    follow = opts.follow,
    max_redirects = opts.max_redirects,
    redirect_protocols = opts.redirect_protocols,
    connect_timeout_ms = counted(opts.connect_timeout_ns, MS, math.maxinteger, "connect_timeout_ns"),
    timeout_ms = counted(opts.timeout_ns, MS, math.maxinteger, "timeout_ns"),
    low_speed_bytes = opts.low_speed_bytes,
    low_speed_seconds = counted(opts.low_speed_ns, SECOND, 65535 * SECOND, "low_speed_ns"),
    verbose = opts.verbose,
    script = opts.script,
  }
end

--- [`Http.open`]'s work, which each public entry point calls itself, so
--- that a refusal of `opts` is raised at its caller (`CALLER`).
local function opened(url: string, opts: Http.Options | nil): Http.Response | nil, string
  local handle, trouble = http.open(url, raw_options(opts))
  if handle == nil then
    return nil, trouble
  end
  return respond(handle), ""
end

--- Opens `url`, blocking until the final response's headers arrive.
--- The body is not read yet -- call `response:read(max_bytes)` until it
--- returns `nil, ""` for a clean end, or use [`Http.get`] to read it
--- all at once.
function Http.open(url: string, opts?: Http.Options): Http.Response | nil, string
  local response, trouble = opened(url, opts)
  if response == nil then
    return nil, trouble
  end
  return response, ""
end

--- [`Http.open`], then the whole body read at once. Fails on a
--- connection or protocol error the same way [`Http.open`] does; a
--- non-2xx status is not itself a failure here -- check `result.status`.
function Http.get(url: string, opts?: Http.Options): Http.Body | nil, string
  local response, trouble = opened(url, opts)
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

--- `response` as a Reader that fails with "interrupted" once `cancelled`
--- answers true: asked before each read and once more at the end of the
--- body, so a body that came whole is still refused after a cancel.
local function cancellable(response: Http.Response, cancelled: function(): boolean): Stream.Reader
  local reader: Stream.Reader = {}
  reader.read = function(_self: Stream.Reader, max_bytes?: integer): string | nil, string
    if cancelled() then return nil, "interrupted" end
    local chunk, why = response:read(max_bytes)
    if chunk ~= nil then return chunk, "" end
    if why == "" and cancelled() then return nil, "interrupted" end
    return nil, why
  end
  reader.close = function(_self: Stream.Reader): boolean, string
    return response:close()
  end
  return reader
end

--- Downloads `url` to `path`, as `curl -fLo` or `wget` would, streaming
--- to a fresh temporary file beside it ([`Stream.create`]'s, so two
--- downloads never share one and a planted symlink is never followed)
--- and renaming into place only once the transfer is complete, synced to
--- disk and, when `opts.sha256` or `opts.sha512` is given, verified: a
--- reader never sees a partial file at the final name. Fails on a
--- non-2xx status (a redirect `opts.follow` already took does not count)
--- or a checksum mismatch, and removes the temporary file on every
--- failure, `opts.cancelled` answering true ("interrupted", as a
--- caught signal says it) included.
function Http.download(url: string, path: string, opts?: Http.Options): boolean, string
  opts = opts or {}
  local given: {{Hash.Algorithm, string}} = {
    { "sha256", opts.sha256 or "" },
    { "sha512", opts.sha512 or "" },
  }
  local checks: {{string, string, Stream.Hashing}} = {}
  for _, pair in ipairs(given) do
    local algorithm, wanted = pair[1], pair[2]
    if wanted ~= "" then
      local hashing, trouble = Stream.hashing(algorithm)
      if hashing == nil then return false, trouble end
      checks[#checks + 1] = { algorithm, wanted:lower(), hashing }
    end
  end
  local response, open_trouble = opened(url, opts)
  if response == nil then return false, open_trouble end
  if response.status < 200 or response.status >= 300 then
    local _, _ = response:close()
    return false, url .. ": HTTP " .. tostring(response.status)
  end
  local file, create_trouble = Stream.create(path)
  if file == nil then
    local _, _ = response:close()
    return false, create_trouble
  end
  local sink: Stream.Writer = file
  for _, check in ipairs(checks) do sink = Stream.tee(sink, check[3]) end
  local source: Stream.Reader = response
  if opts.cancelled ~= nil then source = cancellable(response, opts.cancelled) end
  local copied, trouble = Stream.copy(source, sink)
  local _, _ = response:close()
  local committed = copied ~= nil
  for _, check in ipairs(committed and checks or {}) do
    local digest, digest_trouble = check[3]:digest()
    local hex = digest ~= nil and Codec.hex(digest) or ""
    if hex ~= check[2] then
      committed = false
      trouble = digest ~= nil and path .. ": " .. check[1] .. " mismatch: want " .. check[2] ..
        ", got " .. hex or digest_trouble
      break
    end
  end
  if committed then committed, trouble = file:sync() end
  if committed then committed, trouble = file:close() end
  if not committed then
    local _, _ = file:abort()
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
