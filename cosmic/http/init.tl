--- HTTP and HTTPS requests, typed: HTTP and HTTPS only, with no cookies,
--- no HTTP/2 and no compressed transfer-encoding.
---
---     local got = assert(Http.get("https://example.com/"))
---     print(got.status, got.body)
---     local put = assert(Http.request("PUT", "https://example.com/item",
---       { headers = { ["Content-Type"] = "text/plain" }, body = "new" }))
---     local ok, trouble = Http.download(
---       "https://example.com/big.zip", "big.zip", { sha256 = "..." })
---
--- [`Http.open`] blocks until the final response's headers have arrived
--- (following every redirect `opts.follow` allows) and hands back a
--- [`Response`] whose body is read a chunk at a time -- a
--- [`cosmic.stream`] Reader, so [`Stream.copy`], [`Stream.transform`] and the
--- rest take it as they take a file; [`Http.request`] reads the whole
--- body for the common case, with any method ([`Http.get`] for a GET),
--- and [`Http.download`] streams it straight to a file, verifying a
--- checksum while it goes.
---
--- [`Http.serve`] is the other side: an HTTP/1.1 server over
--- [`Net.serve`], calling a handler with each [`Request`], its body a
--- Reader, and writing the [`Reply`] it answers. [`Http.range`] and
--- [`Http.none_match`] read a request's Range and If-None-Match for it.
---
---     assert(Http.serve{
---       listeners = { Net.tcp("127.0.0.1", 8080) },
---       handle = function(req: Http.Request): Http.Reply
---         return { status = 200, body = "you asked for " .. req.path .. "\n" }
---       end,
---     })

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
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

local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local errors = require("cosmic.internal.errors")
local wire = require("cosmic.http.wire")

local record Http
  --- One request. `follow` defaults to true, `max_redirects` to 10;
  --- a followed 303, or a 301/302 after a POST, turns the request
  --- into a GET, as RFC 9110 says. `method` is case-sensitive, as
  --- HTTP's are, and defaults to GET, or POST when there is a `body`;
  --- [`Http.request`] takes the method as its first argument instead,
  --- and [`Http.get`] sends GET and no body.
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
  --- `sha256`, `sha512` and `cancelled` are read only by
  --- [`Http.download_result`] and [`Http.download`].
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
    --- Download only: the expected sha256 and sha512, as hex. Each
    --- given is computed while the body is written and must match, or the
    --- download fails naming the algorithm, the digest wanted and the one
    --- got, leaving no file.
    sha256: string
    --- Download only: see `sha256`.
    sha512: string
    --- Download only: asked before each chunk is read and once
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
  interface Response is Stream.Reader
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

  --- The outcome of a download, classified where it succeeds or fails.
  enum DownloadKind
    "downloaded"
    "http_status"
    "digest_mismatch"
    "failed"
  end

  --- One completed [`Http.download_result`] operation. `reason` is empty
  --- on success. This operation adds no caller URL to a failure's reason;
  --- underlying transport diagnostics are passed through, not redacted.
  record DownloadResult
    --- Success, HTTP rejection, checksum mismatch, or another failure.
    kind: DownloadKind
    --- Empty on success; otherwise the human reason, without an added URL.
    reason: string
    --- Present only for `http_status`: the rejected response's status.
    status: integer | nil
    --- Present only for `digest_mismatch`: the checked algorithm.
    algorithm: Hash.Algorithm | nil
    --- The supplied checksum, lowercased; an empty option requests no check.
    expected: string | nil
    --- The computed digest as lower-case hex.
    actual: string | nil
  end

  --- What [`Http.request`] and [`Http.get`] return: a status, a whole
  --- body, and headers, bundled into one value since a public fallible
  --- function here returns exactly `(value, string)`.
  record Body
    --- The final response's HTTP status code, after any redirect taken.
    status: integer
    --- The whole body, as bytes.
    body: string
    --- The response headers, keyed by lower-case name, as [`Response.headers`].
    headers: {string:string}
  end

  --- One request [`Http.serve`] hands its handler. Its head is read
  --- whole; its body is not read yet.
  record Request
    --- The method, case-sensitive: "GET", "PUT". A HEAD is passed on as
    --- itself: answer it as GET, and the server sends the head the GET's
    --- reply has, its Content-Length (or `Transfer-Encoding: chunked`)
    --- included, and no body; or, without the bytes, give the size alone,
    --- with no body: `{ status = 200, headers = { ["Content-Length"] =
    --- tostring(size) } }`.
    method: string
    --- The request target as sent: "/items/a%20b?full=1".
    target: string
    --- The target's path, still %-escaped -- [`Url.segments`] decodes
    --- it -- or an absolute-form target's ("/" when it names none), or
    --- "*" for `OPTIONS *`.
    path: string
    --- What follows the target's first "?", still escaped; "" when none.
    query: string
    --- "HTTP/1.1" or "HTTP/1.0".
    version: string
    --- The headers, by lowercased name; a name sent more than once has
    --- its values joined with ", ". For an absolute-form target, `host`
    --- is the target's host and port, whatever Host said.
    headers: {string:string}
    --- The body, read as it arrives: a Content-Length's bytes, or a
    --- chunked body decoded, and nothing for a request with neither.
    --- [`Stream.read_all`] reads it whole, for the common case; it
    --- holds at most `limits.body_bytes`. A read past that fails, and
    --- the server answers 413 in place of the handler's reply (so a
    --- handler may simply `assert` the read); a chunked body
    --- malformed fails the same way, answered 400. A body the handler
    --- leaves unread is read and dropped after its reply, the
    --- connection closed instead where it fails. Closing it does
    --- nothing more than end the handler's reads.
    body: Stream.Reader
    --- The Content-Length: the body's size, 0 for a request with no
    --- body, nil for a chunked one.
    length: integer
  end

  --- What a handler answers. The server writes `Date`,
  --- `Content-Length` (or `Transfer-Encoding: chunked`) and
  --- `Connection` itself. A handler may give `Content-Length` too, as
  --- `length` or a header: it must be the body's size, and the server
  --- writes it once. A reply naming `Date`, `Connection` or
  --- `Transfer-Encoding`, a header holding CR, LF or NUL, a
  --- Content-Length that is no digits, past 18 of them, named twice in
  --- different cases, other than `length`, given a 204, or not the
  --- body's size, a body for a 204 or 304, or anything but such a
  --- record, is answered 500 instead and reported to
  --- [`Http.ServeSpec.on_error`].
  record Reply
    --- The status, from 200 to 999: the server sends `100 Continue`
    --- itself, and no other 1xx.
    status: integer
    --- Headers, name to value, written as given, but for a
    --- `Content-Length` (any case of the name), which is the body's size
    --- as `length` is: digits, equal to a string body's length, and
    --- naming the size of a Reader body. Without a body (nil or "") it
    --- is 0, but in a reply to HEAD, where it is the size of the body a
    --- GET would get, sent with no bytes; and in a 304, where RFC 9110
    --- 8.6 has it the size of a 200's body, and it is passed on
    --- unchecked. A 204 has none.
    headers: {string:string}
    --- nil for none, the bytes, or a Reader, which the server reads to
    --- its end (or to `length`) as it writes and then closes, read or
    --- not.
    body: string | Stream.Reader
    --- The body's size in bytes, as a `Content-Length` header gives it:
    --- the two, given both, must agree. A Reader without either goes
    --- chunked, or, to an HTTP/1.0 client, until the connection closes.
    length: integer
    --- Close the connection after this reply.
    close: boolean
  end

  --- What [`Http.serve`] serves, and how. A field of the wrong shape, or
  --- one not named here, raises, naming it.
  record ServeSpec
    --- Where to listen, as [`Net.ServeSpec.listeners`].
    listeners: {Net.Address}
    --- Answers one request, in the connection's task: see [`Http.serve`].
    handle: function(Request): Reply
    --- What a server takes on at most; a field left nil has its default.
    record Limits
      --- The most connections open at once (256).
      connections: integer
      --- The most bytes of a request's head (64 KiB), past which it is
      --- answered 431, and of the head with a chunked body's chunk
      --- extensions and trailers, past which 413.
      head_bytes: integer
      --- The most bytes of a request's body (1 MiB); past it, 413.
      body_bytes: integer
    end
    --- Bounds on what the server takes on; nil for every default.
    limits: Limits
    --- How long any one read or write of a connection waits once a
    --- request's head is in -- the body's reads, the reply's writes
    --- -- (30 seconds); see [`Net.ServeSpec.timeout_ns`].
    timeout_ns: integer
    --- As [`Net.ServeSpec.grace_ns`]: how long requests in flight have
    --- to finish once the server stops; nil to wait for every one.
    grace_ns: integer
    --- How long a connection waits for the first byte of a request, its
    --- first or the next after a reply, before it is closed (5 seconds).
    idle_ns: integer
    --- How long a request's head may take to arrive whole, from its
    --- first byte (30 seconds): past it, 408 and the connection closed,
    --- so a client sending a head a byte at a time holds a connection
    --- no longer.
    head_ns: integer
    --- As [`Net.ServeSpec.on_ready`].
    on_ready: function(addresses: {Net.Address}, server: Net.Server)
    --- Given what a handler raised, with its stack, or why its reply
    --- could not be sent; nil to write each to stderr. See
    --- [`Net.ServeSpec.on_error`].
    on_error: function(trouble: string)
  end

  --- What a Range header asks of a representation, as [`Http.range`]
  --- reads it: all of it, one span of its bytes, or none.
  enum RangeKind
    "whole"
    "span"
    "unsatisfiable"
  end

  --- One Range header read against a representation's size: see
  --- [`Http.range`].
  record Range
    --- "whole" for a 200 with every byte, "span" for a 206 with the
    --- bytes from `first` to `last`, "unsatisfiable" for a 416.
    kind: RangeKind
    --- The span's first byte, counted from 0; set only for "span".
    first: integer
    --- The span's last byte, counted from 0 and sent with it; set only
    --- for "span".
    last: integer
  end
end

local MS <const> = Time.ms(1)
local SECOND <const> = Time.seconds(1)

-- How an object of this module is made: see the note on objects in
-- cosmic/stream.tl.

--- The Response over a curl handle, which it owns.
local record CurlResponse is Http.Response
  handle: raw_http.Handle
  closed: boolean
  read: function(CurlResponse, max_bytes?: integer): string | nil, string
  close: function(CurlResponse): boolean, string
  sent: function(CurlResponse): string
end

local curl_response_mt: metatable<CurlResponse> = {
  __index = CurlResponse,
  __close = function(self: CurlResponse)
    local _, _ = self:close()
  end,
}

function CurlResponse:read(max_bytes?: integer): string | nil, string
  if self.closed then return nil, "http: the response is closed" end
  return self.handle:read(max_bytes)
end

function CurlResponse:close(): boolean, string
  self.closed = true
  self.handle:close()
  return true, ""
end

function CurlResponse:sent(): string
  return self.handle:sent()
end

--- The Response over a handle whose final headers are known.
local function respond(handle: raw_http.Handle): Http.Response
  local response: CurlResponse = setmetatable({
    status = handle:status(),
    headers = handle:headers(),
    url = handle:url(),
    handle = handle,
    closed = false,
  }, curl_response_mt)
  return response
end

--- The level `error` raises a refusal of `opts` at from [`counted`]:
--- past [`raw_options`], the local function that called it ([`opened`]
--- or [`downloading`]) and the public entry point that called that
--- itself, at the entry point's caller. No call on that path is a tail
--- call, which would leave no level of its own.
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
--- `method`, when given, stands in for `opts.method`.
local function raw_options(opts: Http.Options | nil, method?: string): raw_http.Options | nil
  if opts == nil then
    return method ~= nil and { method = method } or nil
  end
  return {
    method = method or opts.method,
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

--- Every byte a URL never holds literally, to its escape: a space, a
--- control byte, a byte past ASCII, and `"` `<` `>` `\` `^` `` ` `` `{`
--- `|` `}` -- the bytes Python requests' requote_uri escapes. Every
--- reserved byte and `%` are left out: what they mean is the caller's.
local escape_unsafe: {string:string} = {}
do
  for byte = 0, 255 do
    local ch = string.char(byte)
    if byte <= 32 or byte >= 127 or ('"<>\\^`{|}'):find(ch, 1, true) then
      escape_unsafe[ch] = ("%%%02X"):format(byte)
    end
  end
end

--- `url` as curl is handed it, or nil and why: past its scheme and
--- authority, each `%` not followed by two hex digits is written `%25`,
--- as requests writes one, and each byte `escape_unsafe` holds is
--- escaped, so a URL holding none of them is sent as written and one
--- escaped already is not escaped again. A space or control byte in the
--- authority is refused, naming it: a host takes no escape, and curl
--- would refuse it as "Malformed input to a URL function". A URL with
--- no scheme is read as curl reads it, its authority from the start.
local function sendable(url: string): string | nil, string
  local _, scheme_end = url:find("^[A-Za-z][A-Za-z0-9+.-]*://")
  local rest = url:find("[/?#]", (scheme_end or 0) + 1) or #url + 1
  local at = url:sub(1, rest - 1):find("[\0-\32\127]")
  if at ~= nil then
    local byte = url:byte(at)
    local what = byte == 32 and "a space" or byte == 0 and "a NUL" or ("control byte 0x%02x"):format(byte)
    return nil, ("http: the URL holds %s at byte %d, in its host or user info, where it cannot be sent; " ..
      "a user name or password goes in through Url.escape"):format(what, at)
  end
  local tail = url:sub(rest)
  local percents = tail:gsub("()%%", function(percent: integer): string
    return tail:find("^%x%x", percent + 1) and "%" or "%25"
  end)
  local escaped = percents:gsub('[\0-\32\127-\255"<>\\^`{|}]', escape_unsafe)
  return url:sub(1, rest - 1) .. escaped, ""
end

--- [`Http.open`]'s work, which each public entry point that opens
--- calls itself (`CALLER`); `method`, when given, stands in for
--- `opts.method`.
local function opened(url: string, opts: Http.Options | nil, method: string | nil): Http.Response | nil, string
  local sent, refused = sendable(url)
  if sent == nil then
    return nil, refused
  end
  url = sent
  local handle, trouble = http.open(url, raw_options(opts, method))
  if handle == nil then
    return nil, trouble
  end
  return respond(handle), ""
end

--- `response`'s whole body, read and closed, as [`Http.Body`].
local function whole(response: Http.Response): Http.Body | nil, string
  local body, read_trouble = Stream.read_all(response)
  local _, _ = response:close()
  if body == nil then
    return nil, read_trouble
  end
  return { status = response.status, body = body, headers = response.headers }, ""
end

--- Opens `url`, blocking until the final response's headers arrive.
--- The body is not read yet -- call `response:read(max_bytes)` until it
--- returns `nil, ""` for a clean end, or use [`Http.request`] (or
--- [`Http.get`]) to read it all at once.
---
--- Past its host, `url` is sent with each byte a URL never holds
--- literally written as `%` and two uppercase hex digits -- a space,
--- a control byte, a byte past ASCII (UTF-8's, so "é" goes as `%C3%A9`),
--- and `"` `<` `>` `\` `^` `` ` `` `{` `|` `}`, as Python requests
--- escapes them -- and a `%` not followed by two hex digits as `%25`.
--- Everything else goes as written: an escape already there, so an
--- escaped URL is not escaped twice, and every reserved byte (`/` `?`
--- `#` `&` `=` `+` `:` `@` `;` `,` `$` `!` `'` `(` `)` `*` `[` `]`), whose
--- meaning in the URL is the caller's. So a name meant literally that
--- may hold a reserved byte or a `%` (a file named "50% off?.txt") goes
--- in through [`Url.escape`], a path segment or query value at a time.
--- A space or control byte in the host or user info fails, naming
--- the byte.
function Http.open(url: string, opts?: Http.Options): Http.Response | nil, string
  local response, trouble = opened(url, opts, nil)
  if response == nil then
    return nil, trouble
  end
  return response, ""
end

--- Sends a GET for `url` and reads the whole body: [`Http.request`]
--- with "GET", `url` escaped as [`Http.open`] escapes it. Fails on a
--- connection or protocol error the same way [`Http.open`] does; a
--- non-2xx status is not itself a failure here -- check
--- `result.status`. An `opts.method` other than "GET", or an
--- `opts.body`, raises, naming [`Http.request`], which sends any method
--- and a body.
function Http.get(url: string, opts?: Http.Options): Http.Body | nil, string
  if opts ~= nil and opts.method ~= nil and opts.method ~= "GET" then
    error(("http: Http.get sends a GET, not %q; send another method with Http.request(method, url, opts)"):
       format(opts.method), 2)
  end
  if opts ~= nil and opts.body ~= nil then
    error("http: Http.get sends no body; send one with Http.request(method, url, { body = ... })", 2)
  end
  local response, trouble = opened(url, opts, nil)
  if response == nil then
    return nil, trouble
  end
  return whole(response)
end

--- Sends `method` to `url`, with `opts.body` when given, and reads the
--- whole response: its status, headers and body. `method` is
--- case-sensitive, as HTTP's are ("PUT", "DELETE", "PATCH", ...);
--- [`Http.open`] is the same request with its body read a chunk at a
--- time, and escapes `url` as this does. Fails on a connection or
--- protocol error the same way [`Http.open`] does; a non-2xx status is
--- not itself a failure here -- check `result.status`. A body goes
--- with the `Content-Type` its headers name, or
--- `application/x-www-form-urlencoded` without one, as curl sends it.
---
---     local put = assert(Http.request("PUT", "https://example.com/items/1",
---       { headers = { ["Content-Type"] = "application/json" }, body = '{"n":1}' }))
---     local gone = assert(Http.request("DELETE", "https://example.com/items/1"))
---     print(put.status, gone.status)
---
--- An empty `method`, an `opts.method` that differs from it, or an
--- `opts.body` with "GET" or "HEAD" raises: the request would not be
--- the one asked for.
function Http.request(method: string, url: string, opts?: Http.Options): Http.Body | nil, string
  if method == nil or method == "" then
    error("http: Http.request's method is empty; name one, as \"GET\" or \"PUT\"", 2)
  end
  if opts ~= nil and opts.method ~= nil and opts.method ~= method then
    error(("http: Http.request was given %q and opts.method %q; leave opts.method out"):
       format(method, opts.method), 2)
  end
  -- core/http.c's set_method drops a body sent with HEAD, and sends one
  -- with GET as a POST (its TODO says when that changes).
  if opts ~= nil and opts.body ~= nil and (method == "GET" or method == "HEAD") then
    error(("http: Http.request sends no body with %s"):format(method), 2)
  end
  local response, trouble = opened(url, opts, method)
  if response == nil then
    return nil, trouble
  end
  return whole(response)
end

--- A Reader over a Response that fails with "interrupted" once
--- `cancelled` answers true.
local record CancellableReader is Stream.Reader
  response: Http.Response
  cancelled: function(): boolean
  read: function(CancellableReader, max_bytes?: integer): string | nil, string
  close: function(CancellableReader): boolean, string
end

local cancellable_reader_mt: metatable<CancellableReader> = { __index = CancellableReader }

function CancellableReader:read(max_bytes?: integer): string | nil, string
  if self.cancelled() then return nil, "interrupted" end
  local chunk, why = self.response:read(max_bytes)
  if chunk ~= nil then return chunk, "" end
  if why == "" and self.cancelled() then return nil, "interrupted" end
  return nil, why
end

function CancellableReader:close(): boolean, string
  return self.response:close()
end

--- `response` as a Reader that fails with "interrupted" once `cancelled`
--- answers true: asked before each read and once more at the end of the
--- body, so a body that came whole is still refused after a cancel.
local function cancellable(response: Http.Response, cancelled: function(): boolean): Stream.Reader
  local reader: CancellableReader = setmetatable({
    response = response, cancelled = cancelled,
  }, cancellable_reader_mt)
  return reader
end

-- Own both resources while user cancellation code may raise: a failed
-- call must not leave a staged file waiting for garbage collection.
local record PendingDownload
  response: Http.Response
  file: Stream.FileWriter
  metamethod __close: function(PendingDownload)
end

local pending_mt: metatable<PendingDownload> = {
  __close = function(self: PendingDownload)
    if self.response ~= nil then local _, _ = self.response:close() end
    if self.file ~= nil then local _, _ = self.file:abort() end
  end,
}

--- [`Http.download_result`]'s work, which each public entry point that
--- downloads calls itself (`CALLER`).
local function downloading(url: string, path: string,
                           opts: Http.Options | nil): Http.DownloadResult
  opts = opts or {}
  local given: {{Hash.Algorithm, string}} = {
    { "sha256", opts.sha256 or "" },
    { "sha512", opts.sha512 or "" },
  }
  local checks: {{Hash.Algorithm, string, Stream.Hashing}} = {}
  for _, pair in ipairs(given) do
    local algorithm, wanted = pair[1], pair[2]
    if wanted ~= "" then
      local hashing, trouble = Stream.hashing(algorithm)
      if hashing == nil then return { kind = "failed", reason = trouble } end
      checks[#checks + 1] = { algorithm, wanted:lower(), hashing }
    end
  end
  local pending <close>: PendingDownload = setmetatable({}, pending_mt)
  -- `opts` is checked here, so a refusal is raised at `CALLER`; the open
  -- goes through [`Http.open`], which finds nothing more to refuse.
  local _ = raw_options(opts)
  local response, open_trouble = Http.open(url, opts)
  pending.response = response
  if response == nil then return { kind = "failed", reason = open_trouble } end
  if response.status < 200 or response.status >= 300 then
    return { kind = "http_status", status = response.status, reason = "HTTP " .. tostring(response.status) }
  end
  local file, create_trouble = Stream.create(path)
  pending.file = file
  if file == nil then
    return { kind = "failed", reason = create_trouble }
  end
  local sink: Stream.Writer = file
  for _, check in ipairs(checks) do sink = Stream.tee(sink, check[3]) end
  local source: Stream.Reader = response
  if opts.cancelled ~= nil then source = cancellable(response, opts.cancelled) end
  local copied, trouble = Stream.copy(source, sink)
  local _, _ = response:close()
  pending.response = nil
  if copied == nil then
    return { kind = "failed", reason = trouble }
  end
  for _, check in ipairs(checks) do
    local digest, digest_trouble = check[3]:digest()
    if digest == nil then
      return { kind = "failed", reason = digest_trouble }
    end
    local hex = Codec.hex(digest)
    if hex ~= check[2] then
      return { kind = "digest_mismatch", algorithm = check[1], expected = check[2], actual = hex,
      reason = path .. ": " .. check[1] .. " mismatch: want " .. check[2] .. ", got " .. hex }
    end
  end
  local committed, commit_trouble = file:sync()
  if committed then committed, commit_trouble = file:close() end
  if not committed then
    return { kind = "failed", reason = commit_trouble }
  end
  pending.file = nil
  return { kind = "downloaded", reason = "" }
end

--- Downloads `url` to `path`, streaming
--- to a fresh temporary file beside it ([`Stream.create`]'s, so two
--- downloads never share one and a planted symlink is never followed)
--- and renaming into place only once the transfer is complete, synced to
--- disk and, when `opts.sha256` or `opts.sha512` is given, verified: a
--- reader never sees a partial file at the final name. Fails on a
--- non-2xx status (a redirect `opts.follow` already took does not count)
--- or a checksum mismatch, and removes the temporary file on every
--- failure, `opts.cancelled` answering true ("interrupted", as a
--- caught signal says it) included.
--- Returns a classified outcome; [`Http.download`] gives the same operation
--- as a boolean and reason, including the caller URL on an HTTP rejection.
function Http.download_result(url: string, path: string, opts?: Http.Options): Http.DownloadResult
  local result = downloading(url, path, opts)
  return result
end

--- Downloads as `curl -fLo` or `wget` would: [`Http.download_result`]'s
--- streaming, verified and atomic download as
--- `true, ""`, or `false` and a reason. An HTTP rejection's reason starts
--- with `url`; a checksum mismatch names `path`, the algorithm and both
--- digests. Other failures retain their underlying reason.
function Http.download(url: string, path: string, opts?: Http.Options): boolean, string
  local result = downloading(url, path, opts)
  if result.kind == "downloaded" then return true, "" end
  if result.kind == "http_status" then
    return false, url .. ": HTTP " .. tostring(result.status)
  end
  if result.kind == "digest_mismatch" then
    return false, path .. ": " .. assert(result.algorithm) .. " mismatch: want " .. assert(result.expected) ..
      ", got " .. assert(result.actual)
  end
  return false, result.reason
end

--- Whether the TLS stack reads `der` as one X.509 certificate, as it
--- reads each CA root this binary trusts: true and "", or false and its
--- reason. A certificate it cannot read is one it would never trust, so
--- a set of roots is worth checking with this before a binary carries
--- it. Raises when there was no memory to read it.
function Http.check_certificate(der: string): boolean, string
  return http.check_certificate(der)
end

-- The server. Each connection is a task of [`Net.serve`]'s, reading one
-- request after another from a [`wire.Input`] over it, so the bytes of a
-- pipelined request read with the one before stay for it.

local KIB <const> = 1024

--- How long a closing connection is read, and what it sends dropped,
--- after a reply that left part of the request unread, so the client
--- reads the reply before the close: closed with bytes unread, a TCP
--- connection resets, and the reset can reach the client first.
local LINGER_NS <const> = Time.seconds(1)
local LINGER_BYTES <const> = 256 * KIB

local SPEC_FIELDS <const>: {string:boolean} = {
  listeners = true, handle = true, limits = true, timeout_ns = true, grace_ns = true,
  idle_ns = true, head_ns = true, on_ready = true, on_error = true,
}

local LIMIT_FIELDS <const>: {string:boolean} = {
  connections = true, head_bytes = true, body_bytes = true,
}

local REPLY_FIELDS <const>: {string:boolean} = {
  status = true, headers = true, body = true, length = true, close = true,
}

--- Raises for the spec's `field`, at the caller of [`Http.serve`].
local function spec_error(field: string, must: string)
  error("http: spec." .. field .. " must be " .. must, 4)
end

--- Raises, naming the field, where `spec` is no [`Http.ServeSpec`]; an
--- address [`Net.serve`] checks itself.
local function checked_spec(spec: any)
  if not spec is {any: any} then error("http: serve takes a spec table", 3) end
  for key in pairs(spec) do
    if not (key is string and SPEC_FIELDS[key]) then
      error("http: spec has no field " .. tostring(key), 3)
    end
  end
  local listeners = spec.listeners
  if not listeners is {any} or #listeners == 0 then
    spec_error("listeners", "a list of one address or more")
  end
  if type(spec.handle) ~= "function" then spec_error("handle", "a function of a request") end
  local limits = spec.limits
  if limits ~= nil then
    if not limits is {any: any} then
      spec_error("limits", "a table")
    else
      for key, value in pairs(limits) do
        if not (key is string and LIMIT_FIELDS[key]) then
          error("http: spec.limits has no field " .. tostring(key), 3)
        end
        if not (value is integer and value >= 1) then
          spec_error("limits." .. tostring(key), "nil or an integer from 1")
        end
      end
    end
  end
  for _, field in ipairs({ "timeout_ns", "grace_ns", "idle_ns", "head_ns" }) do
    Poll.checked_ns(spec[field], "http", "spec." .. field, 3)
  end
  for _, field in ipairs({ "on_ready", "on_error" }) do
    local fn = spec[field]
    if fn ~= nil and type(fn) ~= "function" then spec_error(field, "nil or a function") end
  end
end

--- A connection read under a deadline: each read waits at most `each`,
--- and none past `deadline`, a [`Time.monotonic_ns`] reading (nil for
--- none).
local record Timed is Stream.Reader
  conn: Net.Conn
  each: integer
  deadline: integer
  read: function(Timed, max_bytes?: integer): string | nil, string
  close: function(Timed): boolean, string
end

local timed_mt: metatable<Timed> = { __index = Timed }

function Timed:read(max_bytes?: integer): string | nil, string
  local wait = self.each
  if self.deadline ~= nil then
    local left = self.deadline - Time.monotonic_ns()
    if left <= 0 then return nil, Poll.TIMEOUT end
    if wait == nil or left < wait then wait = left end
  end
  self.conn:set_timeout(wait)
  return self.conn:read(max_bytes)
end

--- The connection is the server's to close.
function Timed:close(): boolean, string
  return true, ""
end

--- A server's state for the length of its run.
local record Serving
  spec: Http.ServeSpec
  limits: wire.Limits
  timeout_ns: integer
  idle_ns: integer
  head_ns: integer
  stopping: boolean
  --- Each connection waiting for its next request's first byte, which
  --- stopping closes at once.
  idle: {Net.Conn: boolean}
end

--- Gives `trouble` to the spec's [`Http.ServeSpec.on_error`], or stderr.
local function report(s: Serving, trouble: string)
  if s.spec.on_error ~= nil then
    s.spec.on_error(trouble)
    return
  end
  local _, _ = Fs.put(Fs.stderr, trouble .. "\n")
end

--- What a handler raised, with the stack it raised from.
local function traced(err: any): string
  return errors.trace(tostring(err), 2)
end

--- Sends the server's own reply of `status` to the request `head` (nil
--- where there is none), saying `why` in its body, and closes after it.
local function answer(s: Serving, conn: Net.Conn, head: wire.Head | nil, status: integer, why: string)
  local text = ("%d %s"):format(status, wire.reason(status))
  if why ~= "" then text = text .. ": " .. why end
  conn:set_timeout(s.timeout_ns)
  local _ = wire.send(conn, {
    status = status, headers = { ["Content-Type"] = "text/plain; charset=utf-8" },
    body = text .. "\n", close = true, method = head ~= nil and head.method or "GET",
    version = head ~= nil and head.version or "HTTP/1.1", date = Time.format_http(Time.now_ns()),
  })
end

--- Ends what `conn` sends and reads what it still sends, dropping it,
--- for at most `LINGER_NS` and `LINGER_BYTES`, so the reply just written
--- reaches the client before the close.
local function linger(conn: Net.Conn)
  local _, _ = conn:shutdown("write")
  local deadline = Time.monotonic_ns() + LINGER_NS
  local dropped = 0
  while dropped < LINGER_BYTES do
    local left = deadline - Time.monotonic_ns()
    if left <= 0 then return end
    conn:set_timeout(left)
    local piece, _ = conn:read()
    if piece == nil then return end
    dropped = dropped + #piece
  end
end

--- Why `reply`, what a handler answered, is no reply the server can
--- send, or "".
local function reply_trouble(reply: any): string
  if not reply is {any: any} then
    return "the handler answered " .. type(reply) .. ", not an Http.Reply"
  end
  for key in pairs(reply) do
    if not (key is string and REPLY_FIELDS[key]) then
      return "the reply has no field " .. tostring(key)
    end
  end
  local status = reply.status
  if not (status is integer and status >= 200 and status <= 999) then
    return "the reply's status must be an integer from 200 to 999"
  end
  local headers = reply.headers
  if headers ~= nil then
    if not headers is {any: any} then return "the reply's headers must be a table" end
    for name, value in pairs(headers) do
      if not (name is string and value is string) then
        return "the reply's headers must map names to strings"
      end
    end
  end
  local body = reply.body
  if body ~= nil and not body is string and
      not (body is {any: any} and type(body.read) == "function" and type(body.close) == "function") then
    return "the reply's body must be nil, a string or a Stream.Reader"
  end
  local length, close = reply.length, reply.close
  if length ~= nil and not length is integer then
    return "the reply's length must be an integer"
  end
  if close ~= nil and not close is boolean then
    return "the reply's close must be a boolean"
  end
  return ""
end

--- Closes the Reader body of `reply`, what a handler answered, where it
--- has one the server will not send: checked as it runs, since the
--- handler's answer is a [`Reply`] only by its declaration.
local function drop_body(reply: Http.Reply)
  if type(reply) ~= "table" then return end
  local body = reply.body
  if type(body) == "table" and not body is string and type(body.close) == "function" then
    -- Protected: a close that raised once, in the reply's send, may again.
    local _, _ = pcall(body.close, body)
  end
end

--- Serves the request `head` read from `input`: calls the handler and
--- writes its reply, or the server's own. True where the connection
--- stays open for the next request.
local function exchange(s: Serving, conn: Net.Conn, input: wire.Input, head: wire.Head): boolean
  -- Whether `100 Continue` went, and whether the final head has: an
  -- interim reply after it would be read as the final reply's body.
  local continued, replied = false, false
  local function go_on()
    if head.continue and not continued and not replied then
      continued = true
      conn:set_timeout(s.timeout_ns)
      local _, _ = conn:write("HTTP/1.1 100 Continue\r\n\r\n")
    end
  end
  local body = wire.body(input, head, s.limits, go_on)
  local request: Http.Request = {
    method = head.method, target = head.target, path = head.path, query = head.query,
    version = head.version, headers = head.headers, body = body, length = head.length,
  }
  local reply: Http.Reply = nil
  local ok, raised: boolean, any = xpcall(function() reply = s.spec.handle(request) end, traced)
  -- A body that failed is answered for, whatever the handler made of
  -- it: its raise, or its reply, followed from the failed read.
  local state = body.state
  if state == "over" or state == "bad" or state == "failed" then
    if ok then drop_body(reply) end
    if state ~= "failed" then
      answer(s, conn, head, state == "over" and 413 or 400, (body.failure:gsub("^http: ", "")))
      linger(conn)
    elseif body.failure == Poll.TIMEOUT then
      answer(s, conn, head, 408, "the body came slower than timeout_ns")
      linger(conn)
    end
    return false
  end
  local where = head.method .. " " .. head.target
  if not ok then
    report(s, "http: " .. where .. ": " .. tostring(raised))
    answer(s, conn, head, 500, "")
    if body.state == "open" then linger(conn) end
    return false
  end
  local trouble = reply_trouble(reply)
  if trouble == "" then
    trouble = wire.check({ status = reply.status, headers = reply.headers, body = reply.body,
      length = reply.length, method = head.method })
  end
  if trouble ~= "" then
    drop_body(reply)
    report(s, "http: " .. where .. ": " .. trouble)
    answer(s, conn, head, 500, "")
    if body.state == "open" then linger(conn) end
    return false
  end
  local close = reply.close == true or head.close or s.stopping or reply.status >= 400
  -- A client still waiting for `100 Continue` sends its body only once
  -- told to, or not at all. A Reader reply may read the request's body
  -- as it goes, so the client is told now; after another, what follows
  -- on the connection is unknown, and it closes.
  if head.continue and not continued and body.state == "open" then
    local given = reply.body
    local sends_body = head.method ~= "HEAD" and reply.status ~= 204 and reply.status ~= 304
    if given ~= nil and not given is string and sends_body and not close then go_on() else close = true end
  end
  replied = true
  conn:set_timeout(s.timeout_ns)
  local sent: wire.Sent = nil
  local sending, raised_sending: boolean, any = xpcall(function()
    sent = wire.send(conn, {
      status = reply.status, headers = reply.headers, body = reply.body, length = reply.length,
      close = close, method = head.method, version = head.version,
      date = Time.format_http(Time.now_ns()),
    })
  end, traced)
  if not sending then
    -- A Reader body that raised: the reply is cut short.
    drop_body(reply)
    report(s, "http: " .. where .. ": the reply's body: " .. tostring(raised_sending))
    return false
  end
  local failed = body.state ~= "open" and body.state ~= "done"
  if sent.body_failure ~= "" and not failed then
    report(s, "http: " .. where .. ": the reply's body: " .. sent.body_failure)
  end
  if sent.close then
    if sent.write_failure == "" and body.state == "open" then linger(conn) end
    return false
  end
  -- A reply Reader that read the request's body may have ended cleanly
  -- where the body failed: what follows it on the connection is no
  -- request to read.
  if failed then
    if body.state ~= "failed" then linger(conn) end
    return false
  end
  -- What of the body the handler left is dropped, so the next request
  -- starts where this one ends.
  if body.state == "open" and not body:drain() then
    linger(conn)
    return false
  end
  return true
end

--- Serves `conn`, one request after another, until it closes, fails,
--- or idles past `idle_ns`.
-- TODO: bound a request's body as head_ns bounds its head, with a
-- `body_ns` from the head's end (the reads' deadline, as Timed's is for
-- the head): today only timeout_ns, each read's, holds it, so a client
-- sending a body a byte a read holds its connection, and a stop with
-- no grace_ns, for as long as the body lasts.
local function serve_conn(s: Serving, conn: Net.Conn)
  local timed: Timed = setmetatable({ conn = conn, each = s.timeout_ns }, timed_mt)
  local input = wire.input(timed)
  while true do
    if not wire.buffered(input) then
      if s.stopping then return end
      s.idle[conn] = true
      timed.deadline = Time.monotonic_ns() + s.idle_ns
      local ok, _ = wire.fill(input)
      s.idle[conn] = nil
      if not ok then return end
    end
    timed.deadline = Time.monotonic_ns() + s.head_ns
    local read = wire.read_head(input, s.limits)
    timed.deadline = nil
    local head = read.head
    if head == nil then
      if read.status ~= 0 then
        answer(s, conn, nil, read.status, read.why)
        linger(conn)
      elseif read.why == Poll.TIMEOUT then
        answer(s, conn, nil, 408, "the head took longer than head_ns")
      end
      return
    end
    if not exchange(s, conn, input, head) then return end
  end
end

--- Serves HTTP/1.1 at each of `spec.listeners`, calling `spec.handle`
--- for each request, until the server stops: [`Net.serve`], whose
--- connections, signals and stopping it shares, speaking HTTP. It
--- answers as [`Net.serve`] does, and raises for a spec of the wrong
--- shape, naming the field.
---
---     assert(Http.serve{
---       listeners = { Net.tcp("127.0.0.1", 8080) },
---       handle = function(req: Http.Request): Http.Reply
---         if req.method ~= "GET" then return { status = 405 } end
---         return { status = 200, headers = { ["Content-Type"] = "text/plain" },
---           body = "hello\n" }
---       end,
---     })
---
--- A connection serves one request after another (keep-alive), and
--- answers requests pipelined on it in order; it closes after a reply
--- to HTTP/1.0, to `Connection: close`, with `Reply.close`, with a 4xx or
--- 5xx status, and once the server is stopping. It closes once idle
--- for `idle_ns` too, and at once when the server stops: a request in
--- flight then finishes, answered with `Connection: close`.
---
--- The server refuses for the handler what HTTP/1.1 (RFC 9112) says to:
--- a malformed request line or header, no Host or more than one in
--- HTTP/1.1, a request holding both Content-Length and
--- Transfer-Encoding, or a transfer coding other than a last chunked
--- (400, or 501 for a coding it does not decode); a version but 1.0 or
--- 1.1 (505); a head past `limits.head_bytes` (431); a head slower than
--- `head_ns` (408), or a body read slower than `timeout_ns` (408); a
--- body past `limits.body_bytes` (413, at once where the Content-Length
--- says so, before a client waiting with `Expect: 100-continue` sends
--- it); any other expectation (417). A client sending that expectation
--- is sent `100 Continue` when the handler first reads the body.
---
--- A handler that raises, or answers what [`Reply`] refuses, is
--- answered 500, and what it raised, with its stack, or why its reply
--- was refused, goes to [`Http.ServeSpec.on_error`]. A HEAD's reply is the
--- GET's head, its framing headers with it, and no body: a handler
--- answers HEAD as it would GET, and a Reader body is closed unread; or
--- it gives the size alone, as a `Content-Length` header and no body (see
--- [`Http.Request.method`]).
---
--- Every handler runs in the task of its connection, and the server
--- serves the next only while one waits on the run: a read of
--- `req.body`, a [`cosmic.net`] wait, [`Poll.delay`]. A handler that
--- blocks the thread -- [`Http.get`] to another server, a
--- [`cosmic.sqlite`] query, a long computation -- stalls every
--- connection until it returns.
-- TODO: drive curl's multi handle from Poll.run's loop (a socket and
-- timer callback per handle, waited on as a Net.Conn's descriptor is),
-- so Http.open, Http.get and Http.request in a handler wait through the
-- run rather than holding every connection.
function Http.serve(spec: Http.ServeSpec): boolean, string
  checked_spec(spec)
  if Poll.in_task() then
    error("http: serve runs a Poll.run of its own, and cannot be called in a task of another", 2)
  end
  local limits = spec.limits or {}
  local s: Serving = {
    spec = spec,
    limits = { head_bytes = limits.head_bytes or 64 * KIB, body_bytes = limits.body_bytes or 1024 * KIB },
    timeout_ns = spec.timeout_ns or Time.seconds(30),
    idle_ns = spec.idle_ns or Time.seconds(5),
    head_ns = spec.head_ns or Time.seconds(30),
    stopping = false,
    idle = {},
  }
  return Net.serve{
    listeners = spec.listeners,
    serve = function(conn: Net.Conn) serve_conn(s, conn) end,
    limits = { connections = limits.connections or 256 },
    timeout_ns = s.timeout_ns,
    grace_ns = spec.grace_ns,
    on_ready = spec.on_ready,
    on_stop = function(_server: Net.Server)
      s.stopping = true
      local idle: {Net.Conn} = {}
      for conn in pairs(s.idle) do idle[#idle + 1] = conn end
      for _, conn in ipairs(idle) do local _, _ = conn:close() end
    end,
    on_error = spec.on_error,
  }
end

-- What a handler reads of a request's Range and If-None-Match, as RFC
-- 9110 sections 13 and 14 say.

--- Whether byte `b` is a space or a tab, RFC 9110's OWS; nil, past
--- the text's end, is not.
local function ows(b: integer | nil): boolean
  return b == 32 or b == 9
end

--- `text` from `from` to `to`, without the spaces and tabs at either
--- end. Scanned a byte at a time: a pattern anchored at `$` would retry
--- at every position of an inner run of them.
local function stripped(text: string, from: integer, to: integer): string
  while from <= to and ows(text:byte(from)) do from = from + 1 end
  while to >= from and ows(text:byte(to)) do to = to - 1 end
  return text:sub(from, to)
end

--- Decimal `digits` without the zeros that lead them, but the last.
local function significant(digits: string): string
  local from = 1
  while from < #digits and digits:byte(from) == 48 do from = from + 1 end
  return digits:sub(from)
end

--- Whether the count in [`significant`] digits `a` is less than `b`'s.
local function fewer(a: string, b: string): boolean
  if #a ~= #b then return #a < #b end
  return a < b
end

local MOST <const> = tostring(math.maxinteger)

--- The count in [`significant`] `digits`, or math.maxinteger where it
--- is more: no size is, so a count compared with a size or clamped to
--- one comes out the same either way.
local function count(digits: string): integer
  if fewer(MOST, digits) then return math.maxinteger end
  return math.tointeger(tonumber(digits))
end

--- Reads the Range `header` of a GET (nil where it sent none) against
--- a representation of `size` bytes, as RFC 9110 section 14 says. A
--- handler of [`Http.serve`] answers what it says:
---
--- - "span": 206 with `Content-Range: bytes <first>-<last>/<size>` and
---   the `last - first + 1` bytes from `first`;
--- - "unsatisfiable": 416 with `Content-Range: bytes */<size>`;
--- - "whole": 200 with every byte, as though no Range were sent.
---
---     local r = Http.range(req.headers["range"], #data)
---     if r.kind == "span" then
---       return { status = 206, body = data:sub(r.first + 1, r.last + 1),
---         headers = { ["Content-Range"] = ("bytes %d-%d/%d"):format(r.first, r.last, #data) } }
---     end
---
--- One range is served, in each of its forms: `bytes=a-b` (`b` past
--- the end taken as the last byte), `bytes=a-` (from `a` on) and
--- `bytes=-n` (the last `n`, or every byte where there are fewer). The
--- unit is "bytes" in any case; a comma-separated list may hold empty
--- elements and spaces or tabs beside its commas, but none between
--- `=` and the range, nor within it. A server may ignore Range, and
--- this one does, answering "whole", for any other unit, a range the
--- RFC holds invalid (`b` before `a`) or that is none (a sign, a
--- space), and more than one range: it writes no
--- `multipart/byteranges`. A valid range holding none of the bytes --
--- `a` at or past `size`, or `-0` -- is "unsatisfiable". `bytes=-n`
--- of an empty representation is "whole": the RFC holds it
--- satisfiable, so no 416, yet a 206 would have no bytes to carry. A count past the largest integer is read as that integer,
--- which no size passes, so it is answered as the count it is.
---
--- Range concerns only GET, and a server ignores it for every other
--- method; a handler that honors If-Range passes nil where its
--- validator does not match. A `size` that is no integer from 0
--- raises.
function Http.range(header: string | nil, size: integer): Http.Range
  if not (math.type(size) == "integer" and size >= 0) then
    error("http: Http.range's size must be an integer from 0", 2)
  end
  local unranged: Http.Range = { kind = "whole" }
  if header == nil then return unranged end
  local value = stripped(header, 1, #header)
  local equals = value:find("=", 1, true)
  if equals == nil or value:sub(1, equals - 1):lower() ~= "bytes" or ows(value:byte(equals + 1)) then
    return unranged
  end
  local spec: string = nil
  local from = equals + 1
  while true do
    local comma = value:find(",", from, true)
    local element = stripped(value, from, comma ~= nil and comma - 1 or #value)
    if element ~= "" then
      if spec ~= nil then return unranged end
      spec = element
    end
    if comma == nil then break end
    from = comma + 1
  end
  if spec == nil then return unranged end
  local first_digits, last_digits = spec:match("^([0-9]+)%-([0-9]*)$")
  if first_digits ~= nil then
    local first_count, last_count = significant(first_digits), significant(last_digits)
    if last_digits ~= "" and fewer(last_count, first_count) then return unranged end
    local first = count(first_count)
    if first >= size then return { kind = "unsatisfiable" } end
    local last = size - 1
    if last_digits ~= "" then last = math.min(count(last_count), last) end
    return { kind = "span", first = first, last = last }
  end
  local suffix = spec:match("^%-([0-9]+)$")
  if suffix == nil then return unranged end
  local n = count(significant(suffix))
  if n == 0 then return { kind = "unsatisfiable" } end
  if size == 0 then return unranged end
  return { kind = "span", first = size - math.min(n, size), last = size - 1 }
end

--- Where the entity tag that starts at `at` in `text` ends, and its
--- opaque tag, quotes and all, which a weak comparison compares; nil
--- where none starts there.
local function entity_tag(text: string, at: integer): integer, string
  local from = at
  if text:sub(at, at + 1) == "W/" then from = at + 2 end
  local _, last = text:find('^"[!\x23-\x7e\x80-\xff]*"', from)
  if last == nil then return nil, nil end
  return last, text:sub(from, last)
end

--- Whether the If-None-Match `header` (nil where none was sent) names
--- `etag`, the entity tag the server sends for the representation
--- (`"v1"`, or `W/"v1"` for a weak one), as RFC 9110 section 13.1.2
--- says: `*` names any, and a list names each tag in it, compared
--- weakly -- `W/"v1"` and `"v1"` name the same. Where it does, the
--- request's condition fails, and a handler answers a GET or HEAD 304
--- Not Modified, with the ETag and no body, and any other method 412.
---
---     local etag = '"' .. version .. '"'
---     if Http.none_match(req.headers["if-none-match"], etag) then
---       return { status = 304, headers = { ETag = etag } }
---     end
---
--- `*` names a representation that exists, so a handler asks only of
--- one it has. A list element that is no entity tag names nothing, and
--- the rest are still read. An `etag` that is no entity tag raises.
function Http.none_match(header: string | nil, etag: string): boolean
  local own_last, own = entity_tag(etag, 1)
  if own_last ~= #etag then
    error(("http: Http.none_match's etag %q is no entity tag, as \"v1\" or W/\"v1\""):format(etag), 2)
  end
  if header == nil then return false end
  local value = stripped(header, 1, #header)
  if value == "*" then return true end
  local at = 1
  while at <= #value do
    local b = value:byte(at)
    if b == 44 or ows(b) then
      at = at + 1
    else
      local last, opaque = entity_tag(value, at)
      local after = last ~= nil and last + 1 or at
      while ows(value:byte(after)) do after = after + 1 end
      if last ~= nil and (after > #value or value:byte(after) == 44) then
        if opaque == own then return true end
      else
        -- What is no entity tag runs to the next comma.
        after = value:find(",", after, true) or #value + 1
      end
      at = after
    end
  end
  return false
end

return Http
