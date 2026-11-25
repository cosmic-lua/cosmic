--- HTTP and HTTPS requests, typed: HTTP and HTTPS only, with no cookies,
--- no HTTP/2 and no compressed transfer-encoding. A compressed body
--- (`Content-Encoding`: zstd, gzip or deflate) is asked for and decoded
--- only when `opts.decompress` says so.
---
---     local got = assert(Http.get("https://example.com/", { timeout_ns = Clock.seconds(30) }))
---     if got.status // 100 ~= 2 then error("HTTP " .. got.status .. ": " .. got.body) end
---     local put = assert(Http.request("PUT", "https://example.com/item",
---       { timeout_ns = Clock.seconds(30), headers = { ["Content-Type"] = "text/plain" }, body = "new" }))
---     local ok, trouble = Http.download(
---       "https://example.com/big.zip", "big.zip", { timeout_ns = Clock.minutes(10), digests = { ["sha256"] = "..." } })
---
--- Every request states `timeout_ns`, how long the whole of it may take
--- ([`Http.FOREVER`] for a stream meant to run until it is closed): a
--- request left to wait for good is a fault no one sees.
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
--- A proxy that the environment names (`http_proxy`, `https_proxy`,
--- `all_proxy`, `no_proxy`) is used as curl uses it, with one exception.
--- A request to this machine (127/8, ::1, localhost and the names under
--- it) skips a proxy that is not on this machine, so the request and a
--- token in its headers do not leave the machine. With `follow`, the
--- redirects after it go direct too. A proxy on loopback, such as a
--- sandbox's relay, is kept.
---
--- To call a rate-limited API in a loop, with [`Http.Options.retry`] and
--- [`Http.Options.pace`], see [the rate-limit guide](../../doc/guides/http-pacing.md).
---
--- In a task of [`Poll.run`] -- a server's handler, say -- a request waits
--- through the run, as [`cosmic.net`] waits: the other tasks go on
--- while it waits for the server, so a handler that calls another
--- service stalls no other connection, and a request to this program's
--- own server gets its response. A cancelled task's request ends with
--- [`Poll.CANCELLED`], and, as in [`cosmic.net`], a signal does not end
--- one. Anywhere else a request holds the thread until the response comes,
--- or a signal the innermost [`Signal.guard`] caught ends it.
---
--- The server is [`cosmic.http.server`], apart from this client so that a
--- program that only fetches does not carry the networking stack a
--- server needs.

local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Compress = require("cosmic.compress")
local Failure = require("cosmic.failure")
local Hash = require("cosmic.hash")
local Innermost = require("cosmic.internal.innermost_guard")
local Poll = require("cosmic.poll")

-- The raw module behind this one lives under the reserved
-- `cosmic.internal.` namespace, which only cosmic's own tree may require
-- (see cosmic/store.tl for why).
local type raw_http = require("cosmic.internal.http")

local http = require("cosmic.internal.http")
local Trust = require("cosmic.internal.trust")

local Stream = require("cosmic.stream")
local String = require("cosmic.string")
-- Only the type here: the networking stack loads where a failure over a
-- socket needs it, so a program that only fetches over the network does
-- not load it.
local type Net = require("cosmic.net")

--- The longest one wait through a run for the shared transfers lasts
--- before they are pumped again, as the core's own wait does.
local PUMP_MOST_NS <const> = 1000000000

--- In a task of [`Poll.run`]: waits through the run, the other tasks
--- going on, until a shared transfer has something to do or curl's
--- timers come due, and then does it. False and [`Poll.CANCELLED`]
--- once the task is cancelled, or false and the failure of curl's
--- multi handle.
local function pump(): boolean, string
  local fds, events, ms = http.pump_fds()
  local wait = if ms < 0 then PUMP_MOST_NS else math.min(ms * 1000000, PUMP_MOST_NS) end
  if #fds > 0 then
    local _, why = Poll.ready(fds, events, wait)
    if why ~= nil and why.kind == "cancelled" then return false, why.message end
  else
    -- A wait of 0 too, so a loop of pumps lets the other tasks run.
    local waited, why = Clock.sleep(wait)
    if not waited then return false, why.message end
  end
  local pumped, why = http.pump()
  if pumped == nil then return false, why end
  return true, ""
end

--- The [`Failure`] for the words a request's failure gave: kind
--- "timeout" for [`Poll.TIMEOUT`], "cancelled" for [`Poll.CANCELLED`] and
--- for "interrupted" (a signal a [`Signal.guard`] caught), else "other".
local function failure_of(why: string): Failure
  if why == Poll.TIMEOUT then return Failure.timeout(why) end
  if why == Poll.CANCELLED or why == "interrupted" then return Failure.cancelled(why) end
  return Failure.new(why)
end

--- The body of a curl handle, which it owns.
local class HandleReader is Stream.Reader
  handle: raw_http.Handle
  mut closed: boolean

  function read(self, max_bytes?: integer): (string | false) | (nil, Failure)
    if self.closed then return nil, failure_of("http: the response is closed") end
    if Poll.in_task() then
      while self.handle:waiting() do
        local pumped, why = pump()
        if not pumped then return nil, failure_of(why) end
        -- Another task may close the response while this one waits.
        if self.closed then return nil, failure_of("http: the response is closed") end
      end
    end
    local chunk, why = self.handle:read(max_bytes)
    if chunk == nil then
      if why == "" then return false end
      return nil, failure_of(why)
    end
    return chunk
  end

  function close(self): (true) | (false, Failure)
    self.closed = true
    self.handle:close()
    return true
  end
end

--- The class behind [`Http.Response`], the type [`Http.open`] returns.
local class Response is Stream.Reader
  --- The final response's HTTP status code, after any redirect taken.
  status: integer
  --- The response's headers, keyed by lowercased name.
  headers: {string:string}
  --- The effective URL, after every redirect taken, with no userinfo:
  --- a user name or password in the request's URL or a redirect's is
  --- left out.
  url: string
  --- Internal: where `read` takes the body from, the handle's or a decoder over it.
  --- No caller reads or writes it.
  mut body: Stream.Reader
  --- Internal: the curl handle the response owns. No caller reads or writes it.
  handle: raw_http.Handle
  --- Internal: present only on a response whose body is decoded (see `opts.decompress`).
  --- No caller reads or writes it.
  mut skip?: function(Response, n: integer): (true) | (false, Failure) -- declared: interface_disagrees

  --- The next chunk of the body, as [`Stream.Reader`] reads it; decoded
  --- when `opts.decompress` asked for it.
  function read(self, max_bytes?: integer): (string | false) | (nil, Failure)
    return self.body:read(max_bytes)
  end

  --- Releases the body, each decoder freeing its codec and closing the
  --- reader beneath it, down to the handle.
  function close(self): (true) | (false, Failure)
    return self.body:close()
  end

  function __close(self)
    local _, _ = self:close()
  end

  --- What curl wrote to the connection; for tests with a `script`.
  --- Raises after `close`.
  function sent(self): string
    return self.handle:sent()
  end
end

--- The Response over a handle whose final headers are known.
local function respond(handle: raw_http.Handle): Response
  local body: HandleReader = { handle = handle, closed = false, skip = nil }
  local response: Response = {
    status = handle:status(),
    headers = handle:headers(),
    url = handle:url(),
    handle = handle,
    body = body,
    skip = nil,
  }
  return response
end

local record Http
  --- When and how long [`Http.Options.retry`] sends a request again.
  record Retry
    --- The most requests sent in all, the first included: at least 1.
    attempts: integer
    --- The statuses that are sent again, `{429, 503}` by default. At
    --- least one, each an integer from 100 to 599.
    statuses?: {integer}
    --- How long to wait before the first retry, in nanoseconds; 1
    --- second by default. Each retry waits twice as long as the one
    --- before, up to `max_wait_ns`.
    backoff_ns?: integer
    --- The longest one wait, in nanoseconds; 60 seconds by default.
    --- Also the longest `Retry-After` that is waited out.
    max_wait_ns?: integer
  end

  --- Spaces requests out: made by [`Http.pacer`], passed as
  --- [`Http.Options.pace`]. Its state is private to the module.
  interface Pacer
    --- The least time between the starts of two requests it lets through,
    --- in nanoseconds.
    interval_ns: integer
  end

  --- One request. `follow` defaults to true, `max_redirects` to 10;
  --- a followed 303, or a 301/302 after a POST, turns the request
  --- into a GET, as RFC 9110 says. `method` is case-sensitive, as
  --- HTTP's are, and defaults to GET, or POST when there is a `body`;
  --- [`Http.request`] takes the method as its first argument instead,
  --- and [`Http.get`] sends GET and no body.
  ---
  --- `redirect_protocols`, a list of "http" and "https", names the
  --- schemes a redirect may lead to (the start URL's own is not limited
  --- by it): `{"https"}` refuses a redirect to http, and the redirect
  --- refused fails the request. By default it is `{"https"}` for a URL
  --- that starts with https, so such a request never falls back to
  --- plaintext, and both for one that starts with http;
  --- `{"http", "https"}` lets an https request follow a redirect to
  --- http. An empty list or any other entry raises (`follow = false`
  --- is how to take no redirect).
  ---
  --- A redirect to another origin (another scheme, host or port than
  --- the URL it redirects from) drops every header of `headers` from that hop
  --- and every later one, a hop back to the first origin included, but
  --- Accept, Accept-Encoding, Accept-Language, Cache-Control,
  --- Content-Length, Content-Type, Range, User-Agent and each If-*, in
  --- any case: any other might be a credential (Authorization, Cookie,
  --- X-Api-Key, Signature and whatever an API names). A caller who must
  --- send one to the new origin passes `follow = false` and follows
  --- `Location` itself. A redirect to another origin that would send the
  --- request's body again -- a 307 or 308, or a 301 or 302 after a
  --- method other than POST -- fails the request instead: a body is the
  --- caller's for the origin it named (a token form, a client secret).
  ---
  --- [`Http.request`] and [`Http.get`] read at most `max_bytes` of the
  --- body (16 MiB by default; `math.maxinteger` lifts it): a longer one
  --- fails the request, unread past the limit, and one whose
  --- Content-Length says it is longer fails before any of it is read.
  --- With `decompress` the limit counts the decoded bytes.
  --- [`Http.open`] and the downloads take no `max_bytes`: their caller
  --- reads the body a chunk at a time. A response's headers are bounded
  --- by curl: 300 KiB in one response, and twenty times that across the
  --- redirects of one request, past which it fails.
  ---
  --- While the innermost open [`Signal.guard`] has caught SIGINT or SIGTERM, an
  --- open still waiting for its response fails with "interrupted", and
  --- so does a body's `read` that has no data to give. The signal stays
  --- the guard's to read.
  ---
  --- A connection not made within `connect_timeout_ns` (default 30
  --- seconds) fails, and so does a transfer that moves fewer than
  --- `low_speed_bytes` (default 1) per second for `low_speed_ns`
  --- (default 60 seconds) straight; 0 turns either check off.
  --- `timeout_ns` bounds the whole request, and every request states
  --- it ([`Http.FOREVER`] for no bound): one without it raises. The
  --- transfer counts them in milliseconds, and `low_speed_ns` in whole
  --- seconds, each rounded up, so no span but 0 is read as none.
  --- `digests` is read only by [`Http.download_result`] and
  --- [`Http.download`], and so is `cancelled` but for the waits of
  --- `retry`, which it ends too.
  ---
  --- `via`, a unix address ([`Net.unix`]), sends the request over the
  --- socket file at its path instead of the network. The URL still gives
  --- the request line and the Host header, so `http://docker/containers/json`
  --- over `Net.unix("/var/run/docker.sock")` asks for `/containers/json` of
  --- host `docker`; its scheme must be http or https, and no name is
  --- resolved. A proxy is never used. Only kind "unix" is taken: any
  --- other address raises, naming `via`; an empty `path` returns `nil, err`.
  --- The path must fit the system's `sun_path` (104 bytes on macOS, 108
  --- on Linux), or the request fails; a sandboxed process also needs
  --- the socket permitted, as [`Net.connect`] to a unix address does.
  --- With `via`, `follow` defaults to false, since a `Location` names a
  --- host the socket may not serve; `follow = true` follows redirects, each
  --- one through the same socket, wherever its URL points.
  ---
  --- `script` is for tests: instead of connecting anywhere, the Nth
  --- connection curl opens (one request each) reads `script[N]` as the
  --- server's whole reply, and the `sent` of a [`Http.Response`] returns what curl wrote.
  --- Over https that reply is the server's side of the TLS handshake,
  --- which a canned one cannot complete, but it can carry a certificate
  --- to see how it is verified.
  ---
  --- `roots`, `ca` and `pin` choose whom an https server, and an https
  --- proxy, is trusted as. `roots` names the CA roots: "minimal"
  --- ([`Http.minimal_roots`]), "mozilla", every root this binary carries
  --- (Mozilla's root store), "none", or a list of roots this binary
  --- carries by the SHA-256 of their DER, as hex (a `:` between bytes is
  --- taken, as Mozilla's store prints them). With no `roots` a request
  --- trusts [`Http.default_roots`]: "minimal", unless `COSMIC_CA_ROOTS`
  --- or `cosmic build --roots` says "mozilla". The certificates
  --- $SSL_CERT_FILE names are trusted with any of these but "none".
  --- `ca`, PEM (one certificate or more) or one DER certificate, is
  --- trusted besides them, and alone with "none": it is how a private
  --- CA, or one server's own certificate, is pinned in code. A request
  --- that chooses roots this way never reuses a connection or a TLS
  --- session verified against other roots.
  --- `pin`, one `sha256//<base64>` or a list of them, is a public key
  --- pin: the server's key must hash to one of them
  --- ([`Http.public_key_pin`] makes one from a certificate), or the
  --- request fails. A `ca` the TLS stack cannot read, or a choice that
  --- leaves nothing to trust, returns `nil, err`.
  ---
  --- `retry` sends the request again when the response's status is one
  --- of `retry.statuses` (429 and 503 by default) and attempts are left:
  --- the response is closed unread and the whole request goes again,
  --- body and all, whatever its method, since those statuses say the
  --- server did not act on it. [`Http.open`], [`Http.get`],
  --- [`Http.request`], [`Http.download`] and [`Http.download_result`]
  --- all do it. The wait before a retry is the response's `Retry-After`
  --- when it has one this module reads (a number of seconds, or an HTTP
  --- date, a date in the past being no wait), else `retry.backoff_ns`,
  --- doubled with each retry and capped at `retry.max_wait_ns`. A
  --- `Retry-After` longer than `max_wait_ns` is not waited out: that
  --- response is returned as it is. So is the last response when the
  --- attempts run out, as a non-2xx status is not a failure here. A
  --- request that fails (`nil` and why) is not retried. While the
  --- innermost open [`Signal.guard`] catches SIGINT or SIGTERM during a
  --- wait, the wait ends and the call fails with "interrupted"; so does
  --- `cancelled` returning true before or during one.
  ---
  --- `pace`, a [`Http.pacer`], spaces requests out: each request sent
  --- with it, every `retry` attempt included, first waits until the
  --- pacer's `interval_ns` has passed since the last request that pacer
  --- let start, then marks its own start. The pacer is the caller's to
  --- share: one passed to many calls spaces all of them, and across hosts
  --- if the caller passes it so; one per rate-limited API is the expected
  --- use. A `retry`'s own wait counts toward the interval, so a retried
  --- request waits the longer of the two, not their sum. A request
  --- that fails to connect still counts as a start. Each call and each
  --- retry attempt is paced, not each redirect hop followed inside one
  --- open (curl follows them there). A caller who needs every hop paced
  --- passes `follow = false` and follows `Location` itself, as the
  --- [pacing guide](../../doc/guides/http-pacing.md#every-redirect-hop)
  --- shows. The same entry points as `retry` pace. The wait ends as a
  --- retry's does: the call fails with "interrupted" when the innermost open
  --- [`Signal.guard`] catches SIGINT or SIGTERM during it, or `cancelled`
  --- returns true before or during it.
  ---
  --- An option of the wrong shape is a bug, and [`Http.open`] raises
  --- for it, naming the option: a value of the wrong Lua type (the
  --- integers take no numeric strings), a number with a fraction, or
  --- one out of range. Every integer must be at least 0;
  --- `max_redirects` is at most 32767 and `low_speed_ns` at most
  --- 65535 seconds. A `retry` raises the same way, naming
  --- `opts.retry.attempts` and the like: attempts below 1, statuses not
  --- a list of one or more integers from 100 to 599, or a span below 0.
  --- So does a `pace` that [`Http.pacer`] did not make, naming `opts.pace`.
  --- A value of the right shape that cannot be sent as given is data,
  --- returned as `nil, err`: a method that is no HTTP token, a header
  --- name or value holding CR, LF or NUL (or a name that is empty or
  --- holds ':'), a URL holding NUL or one curl rejects.
  -- TODO: once ci/cosmic-driver.pin names a release that has such types,
  -- split these options by call, so `method` is Http.open's alone, `body`
  -- is absent from Http.get's type and the download fields from the rest:
  -- ci/cosmic_ci/github_api.tl sets `method` for Http.open, and
  -- build/zig_fetch.tl types a download's options as Http.Options, on the
  -- pinned release.
  record Options
    --- The HTTP method, case-sensitive; GET, or POST when there is a `body`.
    method?: string
    --- Request headers, name to value. A request sends `User-Agent: cosmic`
    --- unless a header here names its own `User-Agent`, in any case; an
    --- empty one sends none.
    headers?: {string:string}
    --- The request body, sent whole.
    body?: string
    --- Whether to follow redirects; true by default, false with `via`.
    follow?: boolean
    --- The most redirects followed, 10 by default.
    max_redirects?: integer
    --- The schemes a redirect may lead to: "https" alone by default
    --- for an https URL, "http" and "https" for an http one.
    redirect_protocols?: {string}
    --- [`Http.request`] and [`Http.get`] only: the most bytes of the body
    --- they read, 16 MiB by default.
    max_bytes?: integer
    --- A unix address to send the request over in place of the network.
    via?: Net.Address
    --- How long connecting may take, in nanoseconds; 30 seconds by default.
    connect_timeout_ns?: integer
    --- How long the whole request may take, in nanoseconds, above 0;
    --- [`Http.FOREVER`] for no limit. Every request states it, so that
    --- none waits for good unseen.
    timeout_ns: integer
    --- The transfer rate, in bytes per second, under which a request
    --- is too slow; 1 by default and 0 turns the check off.
    low_speed_bytes?: integer
    --- How long it may stay under `low_speed_bytes`, in nanoseconds; 60
    --- seconds by default.
    low_speed_ns?: integer
    --- Whether curl logs the transfer to standard error.
    verbose?: boolean
    --- Whether to ask for a compressed body and decode it: the request
    --- carries `Accept-Encoding: zstd, gzip, deflate` unless `headers`
    --- names an Accept-Encoding of its own, and the body is read through
    --- each coding the response's `Content-Encoding` names, the last
    --- first. `deflate` is read as zlib (RFC 9110) or, as servers also
    --- send it, raw deflate; `identity` is no coding. A coding none of
    --- these names fails the open (nil and why, the response closed);
    --- corrupt data, or bytes after the compressed data, fail the read,
    --- naming the coding. `headers` stay as the server
    --- sent them, so a Content-Length counts the bytes before decoding;
    --- a download's `digests` are of the bytes after it.
    --- False by default, so a body comes as the server sent it.
    decompress?: boolean
    --- Tests only: canned replies, one per connection, in place of the
    --- network. Every entry must be a string. With `retry`, an attempt
    --- reads on from the entry after the last connection the one before
    --- it opened, a followed redirect's included.
    script?: {string}
    --- The retry policy: see above. None by default, so a response of
    --- any status is returned at once.
    retry?: Retry
    --- The pacer that spaces requests out: see above. None by default.
    pace?: Pacer
    --- The CA roots to trust: "minimal", "mozilla", "none", or a list of
    --- the SHA-256 digests of roots this binary carries; when nil,
    --- [`Http.default_roots`].
    roots?: string | {string}
    --- Certificates to trust besides `roots`: PEM, or one DER.
    ca?: string
    --- Public key pins, `sha256//<base64>`, one of which the server's
    --- key must match.
    pin?: string | {string}
    --- Download only: the digests the body must have, as hex in either
    --- case, by algorithm: any [`Hash.Algorithm`], as
    --- `{ ["sha256"] = "..." }`. Each is computed while the body is
    --- written and must match, or the download fails naming the
    --- algorithm, the digest wanted and the one got, leaving no file. An
    --- empty digest raises.
    digests?: {Hash.Algorithm:string}
    --- Download only: asked before each chunk is read and once
    --- more when the body is complete, before it is renamed into place;
    --- when it returns true the download stops, removes its temporary
    --- file, never creates `path`, and fails with "interrupted", the
    --- word a caught signal's failure says. It is how a caller holding
    --- a [`Signal.guard`] ends a download on SIGINT while data keeps
    --- coming, which the guard alone ends only at a wait for it.
    -- TODO: drop `cancelled` once cosmic.internal.http's `open` and
    -- `read` check the innermost Signal.guard whenever they are called, not
    -- only while they wait for data, so a guard alone ends a download
    -- whose body never makes them wait: the C waits do not read the
    -- guard when data is already there.
    cancelled?: function(): boolean
  end

  --- An open response, and a [`cosmic.stream`] Reader of its body.
  --- `status`, `headers` and `url` (the effective URL, after every
  --- redirect taken) are already known when [`Http.open`] returns them;
  --- `read` pulls the body a chunk at a time, `false` at its clean
  --- end and the same [`Failure`] again after a failure. `headers` is keyed
  --- by lowercased name, and a name the response repeats has its
  --- values joined with ", " (RFC 9110 5.3) -- Set-Cookie's, which may
  --- hold commas themselves, with "\n" instead. `close` always
  --- succeeds and is idempotent, a `<close>` variable closes the
  --- response when it goes out of scope, and a `read` after either
  --- fails. `sent` after close raises.
  type Response = Response

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
    status?: integer
    --- Present only for `digest_mismatch`: the checked algorithm.
    algorithm?: Hash.Algorithm
    --- The supplied checksum, lowercased; an empty option requests no check.
    expected?: string
    --- The computed digest as lower-case hex.
    actual?: string
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

  --- The [`Http.Options.timeout_ns`] of a request meant to run until it is
  --- closed (a stream of events): no limit on the whole request. The
  --- connect limit and the stall guard (`low_speed_bytes`) still hold.
  FOREVER: integer
end

Http.FOREVER = -1

--- The roots `opts.roots = "minimal"` trusts: those of the CAs that
--- issue for most of the web (Let's Encrypt, DigiCert, Sectigo,
--- GlobalSign, Google, Amazon, Microsoft), by the SHA-256 of each
--- root's DER as lower-case hex, in a list of the caller's own. Only
--- those this binary carries are trusted, so a root Mozilla withdraws,
--- and a refreshed binary drops, is not trusted for being listed here.
function Http.minimal_roots(): {string}
  return Trust.minimal_roots()
end

local MS <const> = Clock.ms(1)
local SECOND <const> = Clock.seconds(1)

-- How an object of this module is made: see the note on objects in
-- cosmic/stream.tl.

--- The codings [`Http.Options.decompress`] asks for, best first.
local ACCEPTED <const> = "zstd, gzip, deflate"

--- Whether `head` begins a zlib stream (RFC 1950):
--- deflate's method, and a header that is a multiple of 31.
local function zlib_header(head: string): boolean
  local cmf, flg = head:byte(1, 2)
  if cmf == nil or flg == nil then return false end -- a lone byte: raw refuses it at finish
  return cmf & 0x0f == 8 and (cmf * 256 + flg) % 31 == 0
end

--- Moves `reader` forward `n` bytes by reading and discarding them:
--- false and a Failure when it fails or ends first.
local function discard(reader: Stream.Reader, n: integer): (true) | (false, Failure)
  local left = n
  while left > 0 do
    local chunk, trouble = reader:read(math.min(left, 65536))
    if chunk == nil then return false, trouble end
    if chunk == false then
      return false, Failure.new("http: truncated body while skipping")
    end
    left = left - #chunk
  end
  return true
end

--- A Reader of `source` decoded from `coding` ("zstd", "gzip",
--- "x-gzip" or "deflate"). Its codec is made from the first bytes, so
--- a body with none (a HEAD's, a 204's, a 304's) is empty, not a
--- truncated stream.
local class DecodingReader is Stream.Reader
  source: Stream.Reader
  coding: string
  mut codec?: Compress.Stream
  --- Bytes held until there are two, to tell zlib from raw deflate.
  mut head: string
  mut ended: boolean
  --- The failure every read returns after the first, its kind kept.
  mut failed?: Failure
  skip?: function(DecodingReader, n: integer): (true) | (false, Failure)

  --- Fails the reader for good, as every Reader here does after an error.
  function fail(self, why: string): Failure
    local failed = Failure.new(("http: cannot decode the %s body: %s"):format(self.coding, why))
    self.failed = failed
    local _, _ = self.source:close()
    return failed
  end

  --- The codec for the reader's coding, made from `head`, the body's
  --- first bytes.
  function start(self, head: string): (Compress.Stream) | (nil, Failure)
    if self.coding == "zstd" then return Compress.decoder("zstd") end
    if self.coding == "deflate" then
      return Compress.decoder(if zlib_header(head) then "zlib" else "raw" end)
    end
    return Compress.decoder("gzip")
  end

  --- What the codec gives for `chunk`: its output, possibly "".
  function feed(self, chunk: string, max_bytes: integer?): (string) | (nil, Failure)
    local codec = self.codec
    if codec == nil then
      self.head = self.head .. chunk
      if #self.head < 2 and not self.ended then return "" end
      local made, trouble = self:start(self.head)
      if made == nil then return nil, self:fail(tostring(trouble)) end
      codec = made
      self.codec = made
      chunk, self.head = self.head, ""
    end
    local out, trouble = codec:update(chunk, max_bytes)
    if out == nil then return nil, self:fail(trouble) end
    return out
  end

  function read(self, max_bytes?: integer): (string | false) | (nil, Failure)
    local failed = self.failed
    if failed ~= nil then return nil, failed end
    while true do
      local codec = self.codec
      if codec ~= nil and codec:pending() then
        local out, trouble = self:feed("", max_bytes)
        if out == nil then return nil, trouble end
        if out ~= "" then return out end
      elseif self.ended then
        return false
      else
        local chunk, why = self.source:read()
        if chunk == nil then
          self.failed = why
          return nil, why
        end
        if chunk == false then
          self.ended = true
          if codec == nil and self.head == "" then return false end
          -- A lone byte is too short for any coding: the codec it starts
          -- refuses it at finish, as it does any truncated body.
          if codec == nil then
            local out, trouble = self:feed("", max_bytes)
            if out == nil then return nil, trouble end
            codec = self.codec
          end
          if codec == nil then return nil, self:fail("no codec") end
          local last, trouble = codec:finish()
          if last == nil then return nil, self:fail(trouble) end
          if codec:rest() ~= "" then
            return nil, self:fail("bytes follow the compressed data")
          end
          if last ~= "" then return last end
          return false
        end
        local out, trouble = self:feed(chunk, max_bytes)
        if out == nil then return nil, trouble end
        if out ~= "" then return out end
      end
    end
  end

  function close(self): (true) | (false, Failure)
    local codec = self.codec
    if codec ~= nil then
      -- Frees the decoder now, not at collection.
      do local _ <close> = codec end
      self.codec = nil
    end
    return self.source:close()
  end
end

local function skip_decoding(self: DecodingReader, n: integer): (true) | (false, Failure)
  return discard(self, n)
end

local function skip_decoded(self: Response, n: integer): (true) | (false, Failure)
  return discard(self.body, n)
end

--- `response` with its body decoded from each coding its
--- Content-Encoding names, or nil and why when one is none this reads
--- (the response is closed then). `response` itself when it names none.
local function decoded(response: Response): Response?, string
  local named = response.headers["content-encoding"]
  if named == nil then return response, "" end
  local codings: mut {string} = {}
  for listed in named:gmatch("[^,]+") do
    local coding = String.trim(listed):lower()
    if coding ~= "identity" and coding ~= "" then
      if coding ~= "zstd" and coding ~= "gzip" and coding ~= "x-gzip" and coding ~= "deflate" then
        local _, _ = response:close()
        return nil, ("http: cannot decode a body of Content-Encoding %q"):format(coding)
      end
      codings[#codings + 1] = coding
    end
  end
  if #codings == 0 then return response, "" end
  local body: Stream.Reader = response.body
  for i = #codings, 1, -1 do
    local coding = codings[i]
    if coding ~= nil then
      local reader: DecodingReader = {
        source = body, coding = coding, codec = nil, head = "", ended = false, failed = nil,
        skip = skip_decoding,
      }
      body = reader
    end
  end
  response.body = body
  response.skip = skip_decoded
  return response, ""
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
--- refusals do, for what is outside 0 to `most_ns`.
local function counted(ns: integer?, unit: integer, most_ns: integer,
                       name: string): integer?
  if ns == nil then return nil end
  if ns < 0 or ns > most_ns then
    error(("http: opts.%s must be between 0 and %d"):format(name, most_ns), CALLER)
  end
  return Clock.ceil(ns, unit)
end

--- The roots a request that names none trusts, "minimal" or "mozilla":
--- `COSMIC_CA_ROOTS` when it is set, else what `cosmic build --roots`
--- recorded in this executable, else "minimal". Nil and a [`Failure`]
--- when either names anything else.
function Http.default_roots(): (string) | (nil, Failure)
  local roots, why = Trust.default_roots("http")
  if roots == nil then return nil, Failure.new(why) end
  return roots
end

--- `opts.pin` as curl takes it, `;` between pins, or nil for none.
--- Raises at `CALLER` for one of the wrong shape: each pin is
--- `sha256//` and the base64 of 32 bytes, as [`Http.public_key_pin`]
--- makes it.
local function pin_of(opts: Http.Options): string?
  local pin = opts.pin
  if pin == nil then return nil end
  local pins: {string}
  if type(pin) == "string" then
    pins = { pin }
  elseif type(pin) == "table" then
    pins = pin
  else
    error("http: opts.pin must be a string or a list of them", CALLER)
  end
  if #pins == 0 then
    error("http: opts.pin must hold a pin", CALLER)
  end
  for i = 1, #pins do
    local one = pins[i]
    if type(one) ~= "string" or #one ~= 52 or not one:match("^sha256//[%w+/]+=$") then
      error(("http: opts.pin[%d] must be sha256// and the base64 of 32 bytes, as Http.public_key_pin makes"):
          format(i), CALLER)
    end
  end
  return table.concat(pins, ";")
end

--- A retry policy with its defaults filled in.
local record Policy
  attempts: integer
  statuses: {integer:boolean}
  backoff_ns: integer
  max_wait_ns: integer
end

--- `value`, a span of `opts.retry` called `name`, or `default` when nil;
--- raises at `level` for one that is no integer or is below 0.
local function span_of(value: integer?, name: string, default: integer, level: integer): integer
  if value == nil then return default end
  if math.type(value) ~= "integer" or value < 0 then
    error(("http: opts.retry.%s must be an integer of at least 0"):format(name), level + 1)
  end
  return value
end

--- `opts.retry` as a [`Policy`], or nil when there is none. Raises, naming
--- the option, for one of the wrong shape, at `level` (`CALLER` when the
--- caller is one function below [`raw_options`], which is where the
--- shape is checked).
local function retry_of(opts: Http.Options, level: integer): Policy?
  local given = opts.retry
  if given == nil then return nil end
  if type(given) ~= "table" then error("http: opts.retry must be a table", level) end
  local attempts = given.attempts
  if math.type(attempts) ~= "integer" or attempts < 1 then
    error("http: opts.retry.attempts must be an integer of at least 1", level)
  end
  local statuses: mut {integer:boolean} = {}
  local listed = given.statuses
  if listed == nil then
    statuses[429], statuses[503] = true, true
  else
    local bad = "http: opts.retry.statuses must be a list of one or more integers from 100 to 599"
    if type(listed) ~= "table" or #listed == 0 then error(bad, level) end
    for index = 1, #listed do
      local status = listed[index]
      if status == nil or math.type(status) ~= "integer" or status < 100 or status > 599 then
        error(bad, level)
      end
      statuses[status] = true
    end
  end
  local backoff = span_of(given.backoff_ns, "backoff_ns", SECOND, level)
  local max_wait = span_of(given.max_wait_ns, "max_wait_ns", 60 * SECOND, level)
  return { attempts = attempts, statuses = statuses, backoff_ns = backoff, max_wait_ns = max_wait }
end

-- The pacer [`Http.pacer`] makes. Its state is fields no caller is told
-- of: when its last request started, once one has.
local class PacerObject is Http.Pacer
  interval_ns: integer
  mut started: boolean
  mut last_ns: integer
end

local function new_pacer(interval_ns: integer): PacerObject
  local made: PacerObject = { interval_ns = interval_ns, started = false, last_ns = 0 }
  return made
end

--- A pacer that spaces requests `interval_ns` apart, to pass as
--- [`Http.Options.pace`] with each request. Nothing is shared behind it:
--- a pacer waits on the requests sent through itself alone, so make one
--- per rate-limited API and pass it to every call to that API.
---
--- A loop over items makes one pacer before it and passes it, with a
--- `retry`, to each call: `local api = Http.pacer(Clock.ms(250))`, then
--- `Http.get(base .. id, { timeout_ns = Clock.seconds(30), pace = api, retry = { attempts = 3 } })`.
---
--- A call and each of its retry attempts is one request to a pacer; the
--- redirect hops followed inside one open are not paced; to pace each,
--- pass `follow = false` and follow `Location` by hand
--- ([guide](../../doc/guides/http-pacing.md#every-redirect-hop)). A
--- request that fails to connect still counts as a start, since the
--- attempt loads the API. The first request through a pacer does not
--- wait. Raises, naming `interval_ns`, for one that is not an integer of
--- at least 0.
function Http.pacer(interval_ns: integer): Http.Pacer
  if math.type(interval_ns) ~= "integer" or interval_ns < 0 then
    error("http: pacer interval_ns must be an integer of at least 0", 2)
  end
  return new_pacer(interval_ns)
end

--- `opts.pace` as the PacerObject it is, or nil when there is none. Raises at
--- `level`, naming the option, for a value [`Http.pacer`] did not make.
local function pace_of(opts: Http.Options, level: integer): PacerObject?
  local given = opts.pace
  if given == nil then return nil end
  if given is PacerObject then return given end
  error("http: opts.pace must be made by Http.pacer", level)
end

--- Whether `value` is nil: of what the types say is there, which a Lua
--- caller may leave out.
local function absent(value: any): boolean
  return value == nil
end

--- `opts` as the raw module reads them: its spans in the milliseconds
--- (and, for `low_speed_ns`, the seconds) it counts them in, its `pin`
--- as curl takes it, and, with `trusting`, the `ca_blob` of the roots it
--- chooses ([`Trust.chosen`], [`Trust.pem`]); or nil and why when those cannot
--- be made. `method`, when given, stands in for `opts.method`. `first`,
--- when given, is the entry of `opts.script` the request starts at.
local function raw_options(given: Http.Options, method?: string,
                           trusting?: boolean, first?: integer): raw_http.Options?, string
  local opts: Http.Options = given
  if absent(opts.timeout_ns) or opts.timeout_ns == 0 then
    error("http: opts.timeout_ns is required: how long the whole request may take, in nanoseconds, above 0, " ..
        "or Http.FOREVER",
      CALLER - 1)
  end
  local via = opts.via
  local follow = opts.follow
  if via ~= nil then
    if via.kind ~= "unix" or type(via.path) ~= "string" then
      -- One level nearer than `counted`'s, raised from here directly.
      error("http: opts.via must be a unix address, as Net.unix builds one", CALLER - 1)
    end
    -- A redirect's Location names a host the socket may not serve.
    if follow == nil then follow = false end
  end
  -- Only to raise at `CALLER`, which no deeper call can; [`opened`] reads
  -- the policy it uses.
  local _ = retry_of(opts, CALLER)
  local _ = pace_of(opts, CALLER)
  local trust, untold = Trust.chosen(opts.roots, opts.ca, "http", CALLER - 1)
  if untold ~= "" then
    return nil, untold
  end
  local blob: string? = nil
  if trusting == true and trust ~= nil then
    local made, why = Trust.pem(trust, "http")
    if made == nil then
      return nil, why
    end
    blob = made
  end
  local headers = opts.headers
  -- A `headers` of the wrong shape goes on as it came, for the raw
  -- module to refuse.
  if opts.decompress == true and (headers == nil or type(headers) == "table") then
    local named = false
    local copy: mut {string:string} = {}
    for name, value in pairs(headers or {}) do
      copy[name] = value
      if type(name) == "string" and name:lower() == "accept-encoding" then named = true end
    end
    if not named then copy["Accept-Encoding"] = ACCEPTED end
    headers = copy
  end
  local script = opts.script
  if first ~= nil and script ~= nil then script = { table.unpack(script, first) } end
  -- FOREVER is no limit. Counted here: an `if` expression in the literal
  -- would add a call level, and a refusal would not be raised at `CALLER`.
  local whole_ms: integer? = nil
  if opts.timeout_ns ~= Http.FOREVER then
    whole_ms = counted(opts.timeout_ns, MS, math.maxinteger, "timeout_ns")
  end
  return { -- checked: literal_shape
    unix_socket = via and via.path,
    method = method or opts.method,
    headers = headers,
    body = opts.body,
    follow = follow,
    max_redirects = opts.max_redirects,
    redirect_protocols = opts.redirect_protocols,
    connect_timeout_ms = counted(opts.connect_timeout_ns, MS, math.maxinteger, "connect_timeout_ns"),
    timeout_ms = whole_ms,
    low_speed_bytes = opts.low_speed_bytes,
    low_speed_seconds = counted(opts.low_speed_ns, SECOND, 65535 * SECOND, "low_speed_ns"),
    verbose = opts.verbose,
    script = script,
    pin = pin_of(opts),
    ca_blob = blob,
    -- In a task the run waits for the headers ([`opened`]), not curl.
    wait = not Poll.in_task(),
  }, ""
end

--- Every byte a URL never holds literally, to its escape: a space, a
--- control byte, a byte past ASCII, and `"` `<` `>` `\` `^` `` ` `` `{`
--- `|` `}` -- the bytes Python requests' requote_uri escapes. Every
--- reserved byte and `%` are left out: what they mean is the caller's.
local escape_unsafe: mut {string:string} = {}
do
  for byte = 0, 255 do
    local ch = string.char(byte)
    if byte <= 32 or byte >= 127 or ('"<>\\^`{|}'):find(ch, 1, true) ~= nil then
      escape_unsafe[ch] = ("%%%02X"):format(byte)
    end
  end
end

--- `url` as curl is handed it, or nil and why: past its scheme and
--- authority, each `%` not followed by two hex digits is written `%25`
--- (requests, finding one, writes every `%` so; this keeps the escapes
--- around it), and each byte `escape_unsafe` holds is escaped, so a URL
--- holding none of them is sent as written and one escaped already is
--- not escaped again. A space or control byte in the authority is
--- refused, naming it: a host takes no escape, and curl would refuse it
--- as "Malformed input to a URL function". The scheme is read as curl
--- reads it, with any number of slashes after its `:`, and a URL with
--- none starts with its authority.
local function sendable(url: string): string?, string
  local _, scheme_end = url:find("^[A-Za-z][A-Za-z0-9+.-]*:/*")
  local rest = url:find("[/?#]", (scheme_end or 0) + 1) or #url + 1
  local at = url:sub(1, rest - 1):find("[\0-\32\127]")
  if at ~= nil then
    local byte = url:byte(at)
    if byte == nil then return nil, "http: the URL holds a control byte" end
    local what = if byte == 32 then "a space" elseif byte == 0 then "a NUL" else ("control byte 0x%02x"):format(byte) end
    local user_end = url:find("@", at, true)
    if user_end ~= nil and user_end < rest then
      return nil, ("http: the URL holds %s at byte %d, in its user info; " ..
        "a user name or password goes in through Url.escape"):format(what, at)
    end
    return nil, ("http: the URL holds %s at byte %d, in its host, which holds none"):format(what, at)
  end
  local tail = url:sub(rest)
  local percents = tail:gsub("()%%", function(percent: integer): string
    return if tail:find("^%x%x", percent + 1) then "%" else "%25" end
  end)
  local escaped = percents:gsub('[\0-\32\127-\255"<>\\^`{|}]', escape_unsafe)
  return url:sub(1, rest - 1) .. escaped, ""
end

--- `trouble`, a failure of opening a request sent over `via`, as the
--- socket's own: where curl could not connect (`code`, the raw module's
--- name for the failure), its message names the URL's `host:port` (the
--- origin, never connected to) and not why, so the path is connected to
--- once more, as [`Net.connect`] does, for its reason. Any other failure,
--- and a path that connects this time, keep `trouble`.
local function socket_trouble(via: Net.Address, trouble: string, code: string?): string
  if code ~= "couldnt_connect" then
    return trouble
  end
  local Sockets = require("cosmic.net")
  local conn, why = Sockets.connect(via)
  if conn ~= nil then
    local _, _ = conn:close()
    return trouble
  end
  -- Its failure reads "path: reason" already.
  return "cannot connect to unix socket " .. tostring(why)
end

--- How long a `Retry-After` header value asks to wait, in nanoseconds, or
--- nil when it is neither delta-seconds nor an HTTP date. A date in the
--- past is 0. The date reader is loaded here, for cosmic.time brings in
--- cosmic.fs, which a program that never sees a dated header does not need.
local function retry_after(text: string): integer?
  local value = String.trim(text)
  if value:find("^%d+$") then
    local digits = value:gsub("^0+(%d)", "%1")
    -- Nine digits is more seconds than any `max_wait_ns` a nanosecond
    -- count holds, and keeps the product below from overflowing.
    if #digits > 9 then return math.maxinteger end
    return (math.tointeger(tonumber(digits)) or 0) * SECOND
  end
  local Time = require("cosmic.time")
  local at, _ = Time.parse_http(value)
  if at == nil then return nil end
  return math.max(at - Clock.now_ns(), 0)
end

--- How long to wait before retry number `retry` (1 for the first) of a
--- response with `headers`: its `Retry-After` when it has one that
--- reads, which may exceed `policy.max_wait_ns`, else the backoff.
local function retry_wait(headers: {string:string}, retry: integer, policy: Policy): integer
  local text = headers["retry-after"]
  if text ~= nil then
    local asked = retry_after(text)
    if asked ~= nil then return asked end
  end
  local wait = policy.backoff_ns
  for _ = 2, retry do
    if wait > policy.max_wait_ns // 2 then return policy.max_wait_ns end
    wait = wait * 2
  end
  return math.min(wait, policy.max_wait_ns)
end

-- The longest stretch a wait sleeps before asking the guard again.
local PAUSE_SLICE <const> = 100 * MS

--- Waits `ns`, in slices: true and "" once it has, or false and
--- "interrupted" as soon as the innermost open [`Signal.guard`] catches a
--- signal or closes during it, or `cancelled` returns true, asked before
--- the wait and after each slice. A signal caught before the wait began
--- is not one: the stamp is taken when it starts. In a task the other
--- tasks go on meanwhile, and a cancelled task's pause returns false and
--- [`Poll.CANCELLED`].
local function pause(ns: integer, cancelled: (function(): boolean)?): boolean, string
  if cancelled ~= nil and cancelled() then return false, "interrupted" end
  local guard = Innermost.active()
  local stamp = 0
  if guard ~= nil then
    local _ = guard:cancelled()
    stamp = guard.state.read
  end
  local began = Clock.monotonic_ns()
  local in_task = Poll.in_task()
  while true do
    local left = ns - (Clock.monotonic_ns() - began)
    if left <= 0 then return true, "" end
    local slice = math.min(left, PAUSE_SLICE)
    -- A task's wait ends early when the task is cancelled. A sleep of the
    -- thread resumes through signals, and ends early only where the system
    -- refuses it, which ends the pause.
    local slept, why = Clock.sleep(slice)
    if not slept and in_task then return false, why.message end
    if guard ~= nil then
      local _ = guard:cancelled()
      if guard.state.closed or guard.state.read ~= stamp then return false, "interrupted" end
    end
    if cancelled ~= nil and cancelled() then return false, "interrupted" end
    if not slept then return true, "" end
  end
end

--- Waits out what is left of `pacer`'s interval since its last start, ending
--- as [`pause`] does, then marks now as its start. False and why, and no
--- start marked, when the wait was cut short.
local function take_turn(pacer: PacerObject, cancelled: (function(): boolean)?): boolean, string
  if pacer.started then
    local left = pacer.interval_ns - (Clock.monotonic_ns() - pacer.last_ns)
    if left > 0 then
      local waited, why = pause(left, cancelled)
      if not waited then return false, why end
    end
  end
  pacer.started, pacer.last_ns = true, Clock.monotonic_ns()
  return true, ""
end

--- Raises, blaming the caller of a public entry point, where `opts` is
--- missing: a Lua caller is not type-checked. [`raw_options`] holds its
--- `timeout_ns`.
local function stated(opts: Http.Options)
  if absent(opts) then
    error("http: opts is required, with timeout_ns: how long the whole request may take", 3)
  end
end

--- [`Http.open`]'s work, which each public entry point that opens
--- calls itself (`CALLER`); `method`, when given, stands in for
--- `opts.method`.
local function opened(url: string, opts: Http.Options, method: string?): Response?, string
  local sent, refused = sendable(url)
  if sent == nil then
    return nil, refused
  end
  url = sent
  local raw, unmade = raw_options(opts, method, true)
  if raw == nil then
    return nil, unmade
  end
  local policy = retry_of(opts, CALLER - 1)
  local pacer = pace_of(opts, CALLER - 1)
  local cancelled = opts.cancelled
  local attempt = 1
  -- The entry of `opts.script` the attempt starts at: every open starts
  -- its script over, so each is handed the entries after the last
  -- connection of the one before.
  local first = 1
  while true do
    if pacer ~= nil then
      local turned, why = take_turn(pacer, cancelled)
      if not turned then return nil, why end
    end
    local handle, trouble, code = http.open(url, raw)
    if handle ~= nil and raw.wait == false then
      -- Opened with `wait = false`: the run waits for the final headers.
      local waited, why = true, ""
      while waited and not handle:ready() do waited, why = pump() end
      if not waited then
        handle:close()
        handle, trouble, code = nil, why, nil
      else
        local settled, failure, failed = handle:settled()
        if settled == nil then
          handle:close()
          handle, trouble, code = nil, failure, failed
        end
      end
    end
    if handle == nil then
      if opts.via ~= nil then
        return nil, socket_trouble(opts.via, trouble, code)
      end
      return nil, trouble
    end
    local again = false
    if policy ~= nil and attempt < policy.attempts and policy.statuses[handle:status()] == true then
      local wait = retry_wait(handle:headers(), attempt, policy)
      if wait <= policy.max_wait_ns then
        first = first + handle:connections()
        handle:close()
        if wait > 0 or cancelled ~= nil then
          local waited, why = pause(wait, cancelled)
          if not waited then return nil, why end
        end
        again = true
      end
    end
    if not again then
      if opts.decompress == true then return decoded(respond(handle)) end
      return respond(handle), ""
    end
    attempt = attempt + 1
    if opts.script ~= nil then
      raw, unmade = raw_options(opts, method, true, first)
      if raw == nil then return nil, unmade end
    end
  end
end

--- The most bytes of a body [`Http.request`] and [`Http.get`] read
--- when `opts.max_bytes` is not given.
local DEFAULT_MAX_BYTES <const> = 16 << 20

--- `opts.max_bytes`, or the default; raises at the caller of the public
--- entry point for one that is no integer of at least 0.
local function body_limit(opts: Http.Options): integer
  local given = opts.max_bytes
  if given == nil then return DEFAULT_MAX_BYTES end
  if math.type(given) ~= "integer" or given < 0 then
    error("http: opts.max_bytes must be an integer of at least 0", 3)
  end
  return given
end

--- Why a body longer than `limit` is refused.
local function over(limit: integer): string
  return "http: the body is longer than opts.max_bytes, " .. String.counted(limit, "byte")
end

--- `response`'s whole body, read and closed, as [`Http.Body`]; nil and
--- why for one longer than `limit` bytes, read no further than the byte
--- past it. `encoded` says the body is decoded from a Content-Encoding,
--- whose Content-Length counts the bytes before decoding. The
--- Content-Length of a response to `method` HEAD, or of a 1xx, 204 or
--- 304, names a body that is never sent (RFC 9110 8.6), so it refuses
--- nothing.
local function whole(response: Response, limit: integer, encoded: boolean, method: string): Http.Body?, string
  local status = response.status
  local bodiless = method == "HEAD" or status // 100 == 1 or status == 204 or status == 304
  local length = math.tointeger(tonumber(response.headers["content-length"] or ""))
  if not encoded and not bodiless and length ~= nil and length > limit then
    local _, _ = response:close()
    return nil, over(limit)
  end
  local parts: mut {string} = {}
  local got = 0
  while true do
    local left = limit - got
    local want = 65536
    if left < want then want = left + 1 end
    local chunk, trouble = response:read(want)
    if chunk == nil then
      local _, _ = response:close()
      return nil, tostring(trouble)
    end
    if chunk == false then
      local _, _ = response:close()
      break
    end
    got = got + #chunk
    if got > limit then
      local _, _ = response:close()
      return nil, over(limit)
    end
    parts[#parts + 1] = chunk
  end
  return { status = response.status, body = table.concat(parts), headers = response.headers }, ""
end

--- Opens `url`, blocking until the final response's headers arrive.
--- The body is not read yet -- call `response:read(max_bytes)` until it
--- returns `false` for a clean end, or use [`Http.request`] (or
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
--- the byte; a user name or password goes in through [`Url.escape`].
--- A failure is nil and a [`Failure`]: of kind "cancelled" when a caught
--- signal or `opts.cancelled` stopped it, "timeout" when the wait of a
--- [`Poll`] task ran out ([`Poll.TIMEOUT`]), else "other". A transfer past `opts.timeout_ns` is
--- "other" for now, its message curl's ("Operation timed out after ...").
function Http.open(url: string, opts: Http.Options): (Response) | (nil, Failure)
  stated(opts)
  local response, trouble = opened(url, opts, nil)
  if response == nil then
    return nil, failure_of(trouble)
  end
  return response
end

--- Sends a GET for `url` and reads the whole body: [`Http.request`]
--- with "GET", `url` escaped as [`Http.open`] escapes it. Fails on a
--- connection or protocol error the same way [`Http.open`] does; a
--- non-2xx status is not itself a failure here -- check
--- `result.status`. An `opts.method` other than "GET", or an
--- `opts.body`, raises, naming [`Http.request`], which sends any method
--- and a body.
function Http.get(url: string, opts: Http.Options): (Http.Body) | (nil, Failure)
  stated(opts)
  local method = opts.method
  if method ~= nil and method ~= "GET" then
    error(("http: Http.get sends a GET, not %q; send another method with Http.request(method, url, opts)"):
        format(method), 2)
  end
  if opts.body ~= nil then
    error("http: Http.get sends no body; send one with Http.request(method, url, { timeout_ns = ..., body = ... })", 2)
  end
  local limit = body_limit(opts)
  local response, trouble = opened(url, opts, nil)
  if response == nil then
    return nil, failure_of(trouble)
  end
  local body, why = whole(response, limit, opts.decompress == true, "GET")
  if body == nil then return nil, failure_of(why) end
  return body
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
---       { timeout_ns = Clock.seconds(30), headers = { ["Content-Type"] = "application/json" }, body = '{"n":1}' }))
---     local gone = assert(Http.request("DELETE", "https://example.com/items/1", { timeout_ns = Clock.seconds(30) }))
---     print(put.status, gone.status)
---
--- An empty `method`, an `opts.method` that differs from it, or an
--- `opts.body` with "GET" or "HEAD" raises: the request would not be
--- the one asked for.
function Http.request(method: string, url: string, opts: Http.Options): (Http.Body) | (nil, Failure)
  stated(opts)
  if method == nil or method == "" then -- checked: compare_disjoint
    error("http: Http.request's method is empty; name one, as \"GET\" or \"PUT\"", 2)
  end
  local given = opts.method
  if given ~= nil and given ~= method then
    error(("http: Http.request was given %q and opts.method %q; leave opts.method out"):
        format(method, given), 2)
  end
  -- core/http.c's set_method drops a body sent with HEAD, and sends one
  -- with GET as a POST (its TODO says when that changes).
  if opts.body ~= nil and (method == "GET" or method == "HEAD") then
    error(("http: Http.request sends no body with %s"):format(method), 2)
  end
  local limit = body_limit(opts)
  local response, trouble = opened(url, opts, method)
  if response == nil then
    return nil, failure_of(trouble)
  end
  local body, why = whole(response, limit, opts.decompress == true, method)
  if body == nil then return nil, failure_of(why) end
  return body
end

--- A Reader over a Response that fails with "interrupted" once
--- `cancelled` returns true.
local class CancellableReader is Stream.Reader
  response: Response
  cancelled: function(): boolean

  function read(self, max_bytes?: integer): (string | false) | (nil, Failure)
    if self.cancelled() then return nil, failure_of("interrupted") end
    local chunk, why = self.response:read(max_bytes)
    if chunk == nil then return nil, why end
    if chunk == false and self.cancelled() then return nil, failure_of("interrupted") end
    return chunk
  end

  function close(self): (true) | (false, Failure)
    return self.response:close()
  end
end

--- `response` as a Reader that fails with "interrupted" once `cancelled`
--- returns true: asked before each read and once more at the end of the
--- body, so a body that came whole is still refused after a cancel.
local function cancellable(response: Response, cancelled: function(): boolean): Stream.Reader
  local reader: CancellableReader = {
    response = response, cancelled = cancelled, skip = nil,
  }
  return reader
end

-- Own both resources while user cancellation code may raise: a failed
-- call must not leave a staged file waiting for garbage collection.
local class PendingDownload
  mut response?: Response
  mut file?: Stream.FileWriter

  function __close(self)
    local response = self.response
    if response ~= nil then local _, _ = response:close() end
    local file = self.file
    if file ~= nil then local _, _ = file:abort() end
  end
end

--- An algorithm and the hex digest a download must have by it.
local record Given
  algorithm: Hash.Algorithm
  wanted: string
end

--- The level of a download's public entry point's caller, from
--- [`wanted_digests`], which `downloading` calls first.
local DIGESTS_CALLER <const> = 4

--- Every [`Hash.Algorithm`], ranked in the order a download checks
--- them, so the first mismatch reported is the same each time: sha256,
--- sha512 and sha3-256 first.
local DIGEST_RANKS <const>: {string:integer} = {
  ["sha256"] = 1, ["sha512"] = 2, ["sha3-256"] = 3, ["md5"] = 4, ["sha1"] = 5,
  ["sha224"] = 6, ["sha384"] = 7, ["sha3-224"] = 8, ["sha3-384"] = 9, ["sha3-512"] = 10,
}

--- The digests a download is held to, from `opts.digests`, in
--- [`DIGEST_RANKS`]' order. Raises, blaming the public entry point's
--- caller, on an empty digest or an algorithm [`Hash`] does not know.
local function wanted_digests(opts: Http.Options): {Given}
  local by: mut {Hash.Algorithm:string} = {}
  for algorithm, hex in pairs(opts.digests or {}) do
    if DIGEST_RANKS[algorithm] == nil then
      error(("http: opts.digests names %s, which is no Hash.Algorithm"):format(tostring(algorithm)), DIGESTS_CALLER)
    end
    if hex == "" then
      error(("http: opts.digests[%q] must be a digest in hex, not empty"):format(algorithm), DIGESTS_CALLER)
    end
    by[algorithm] = hex:lower()
  end
  local out: mut {Given} = {}
  for algorithm, hex in pairs(by) do out[#out + 1] = { algorithm = algorithm, wanted = hex } end
  table.sort(out, function(a: Given, b: Given): boolean
    return assert(DIGEST_RANKS[a.algorithm]) < assert(DIGEST_RANKS[b.algorithm])
  end)
  return out
end

--- [`Http.download_result`]'s work, which each public entry point that
--- downloads calls itself (`CALLER`).
local function downloading(url: string, path: string,
                           opts: Http.Options): Http.DownloadResult
  local record Check
    algorithm: Hash.Algorithm
    hex: string
    hashing: Stream.Hashing
  end
  local given: {Given} = wanted_digests(opts)
  local checks: mut {Check} = {}
  for _, pair in ipairs(given) do
    local hashing, trouble = Stream.hashing(pair.algorithm)
    if hashing == nil then return { kind = "failed", reason = tostring(trouble) } end
    checks[#checks + 1] = { algorithm = pair.algorithm, hex = pair.wanted, hashing = hashing }
  end
  local pending <close>: PendingDownload = { response = nil, file = nil }
  -- `opts` is checked here, so a refusal is raised at `CALLER`; the open
  -- goes through [`Http.open`], which finds nothing more to refuse.
  local _, _ = raw_options(opts)
  local response, open_trouble = Http.open(url, opts)
  pending.response = response
  if response == nil then return { kind = "failed", reason = tostring(open_trouble) } end
  if response.status < 200 or response.status >= 300 then
    return { kind = "http_status", status = response.status, reason = "HTTP " .. tostring(response.status) }
  end
  local file, create_trouble = Stream.create(path)
  pending.file = file
  if file == nil then
    return { kind = "failed", reason = tostring(create_trouble) }
  end
  local sink: Stream.Writer = file
  for _, check in ipairs(checks) do sink = Stream.tee(sink, check.hashing) end
  local source: Stream.Reader = response
  local cancelled = opts.cancelled
  if cancelled ~= nil then source = cancellable(response, cancelled) end
  local copied, trouble = Stream.copy(source, sink)
  local _, _ = response:close()
  pending.response = nil
  if copied == nil then
    return { kind = "failed", reason = tostring(trouble) }
  end
  for _, check in ipairs(checks) do
    local digest, digest_trouble = check.hashing:digest()
    if digest == nil then
      return { kind = "failed", reason = digest_trouble }
    end
    local hex = Codec.hex(digest)
    if hex ~= check.hex then
      return { kind = "digest_mismatch", algorithm = check.algorithm, expected = check.hex, actual = hex,
        reason = path .. ": " .. check.algorithm .. " mismatch: want " .. check.hex .. ", got " .. hex }
    end
  end
  local committed, commit_trouble = file:sync()
  if committed then committed, commit_trouble = file:close() end
  if not committed then
    return { kind = "failed", reason = tostring(commit_trouble) }
  end
  pending.file = nil
  return { kind = "downloaded", reason = "" }
end

--- Downloads `url` to `path`, streaming
--- to a fresh temporary file beside it ([`Stream.create`]'s, so two
--- downloads never share one and a planted symlink is never followed)
--- and renaming into place only once the transfer is complete, synced to
--- disk and, when `opts.digests` is
--- given, verified: a reader never sees a partial file at the final name. Fails on a
--- non-2xx status (a redirect `opts.follow` already took does not count)
--- or a checksum mismatch, and removes the temporary file on every
--- failure, `opts.cancelled` returning true ("interrupted", as a
--- caught signal says it) included.
--- Returns a classified outcome; [`Http.download`] gives the same operation
--- as a boolean and reason, including the caller URL on an HTTP rejection.
function Http.download_result(url: string, path: string, opts: Http.Options): Http.DownloadResult
  stated(opts)
  local result = downloading(url, path, opts)
  return result
end

--- Downloads as `curl -fLo` or `wget` would: [`Http.download_result`]'s
--- streaming, verified and atomic download as `true`, or `false` and a
--- [`Failure`]. An HTTP rejection is of kind "library", its `code` the
--- status and its message `url: HTTP 404`; a checksum mismatch's path is
--- `path` and its message names the algorithm and both digests. Other
--- failures keep their words, of kind "cancelled" where a signal or
--- `opts.cancelled` stopped it, as [`Http.open`] gives them.
---
--- TODO: drop [`Http.download_result`] once ci/cosmic-driver.pin names a
--- release with this shape: ci/ and the bootstrap's files read its record
--- on the pinned release too.
function Http.download(url: string, path: string, opts: Http.Options): (true) | (false, Failure)
  stated(opts)
  local result = downloading(url, path, opts)
  if result.kind == "downloaded" then return true end
  local status = result.status
  if result.kind == "http_status" and status ~= nil then
    return false, Failure.coded(url .. ": HTTP " .. tostring(status), status)
  end
  if result.kind == "digest_mismatch" then
    return false, Failure.new(assert(result.algorithm) .. " mismatch: want " .. assert(result.expected) ..
        ", got " .. assert(result.actual), path)
  end
  return false, failure_of(result.reason)
end

--- Whether the TLS stack reads `der` as one X.509 certificate, as it
--- reads each CA root this binary trusts: true, or false and a
--- [`Failure`]. A certificate it cannot read is one it would never
--- trust, so a set of roots is worth checking with this before a binary
--- carries it. Raises when there was no memory to read it.
function Http.check_certificate(der: string): (true) | (false, Failure)
  local ok, why = http.check_certificate(der)
  if not ok then return false, Failure.new(why) end
  return true
end

--- The public key pin of `cert`, one certificate as PEM or DER, as
--- `opts.pin` and curl's `--pinnedpubkey` take it: `sha256//` and the
--- base64 of the SHA-256 of its SubjectPublicKeyInfo. Nil and a
--- [`Failure`] when the TLS stack cannot read `cert` as exactly one
--- certificate. Raises when there was no memory to read it.
---
---     local pin = assert(Http.public_key_pin(assert(Fs.read("server.pem"))))
---     local got = assert(Http.get("https://internal.example/", { timeout_ns = Clock.seconds(30), pin = pin }))
function Http.public_key_pin(cert: string): (string) | (nil, Failure)
  local spki, why = http.public_key(cert)
  if spki == nil then
    return nil, Failure.new(why)
  end
  return "sha256//" .. Codec.base64(Hash.sha256(spki))
end

return Http
