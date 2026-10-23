--- HTTP and HTTPS requests, typed: HTTP and HTTPS only, with no cookies,
--- no HTTP/2 and no compressed transfer-encoding.
---
---     local got = assert(Http.get("https://example.com/"))
---     if got.status // 100 ~= 2 then error("HTTP " .. got.status .. ": " .. got.body) end
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
--- The server is [`cosmic.http.server`], apart from this client so that a
--- program that only fetches does not carry the networking stack a
--- server needs.

local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Env = require("cosmic.env")
local Hash = require("cosmic.hash")
local Store = require("cosmic.store")

-- The raw module behind this one lives under the reserved
-- `cosmic.internal.` namespace, which an ordinary `require` never
-- satisfies (see cosmic/store.tl for why). It arrives instead as the
-- second argument the loader passes this chunk, present because this
-- module was itself loaded, trusted, from the binary's own tree. Boot
-- mode falls back to requiring it by name, which only boot's own
-- preload answers.
local type raw_http = require("cosmic.internal.http")

local extra: any = select(2, ...)
local http: raw_http
if type(extra) == "table" then
  http = extra as raw_http
else
  http = require("cosmic.internal.http")
end

local Stream = require("cosmic.stream")
-- Only the type: cosmic.net is the networking stack a program that
-- only fetches over the network does not carry.
local type Net = require("cosmic.net")

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
  --- While the innermost open [`Signal.guard`] has caught SIGINT or SIGTERM, an
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
  --- `sha256`, `sha512`, `sha3_256` and `cancelled` are read only by
  --- [`Http.download_result`] and [`Http.download`].
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
  --- server's whole reply, and [`Response:sent`] returns what curl wrote.
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
    method?: string
    --- Request headers, name to value.
    headers?: {string:string}
    --- The request body, sent whole.
    body?: string
    --- Whether to follow redirects; true by default, false with `via`.
    follow?: boolean
    --- The most redirects followed, 10 by default.
    max_redirects?: integer
    --- The schemes a redirect may lead to, "http" and "https" by default.
    redirect_protocols?: {string}
    --- A unix address to send the request over in place of the network.
    via?: Net.Address
    --- How long connecting may take, in nanoseconds; 30 seconds by default.
    connect_timeout_ns?: integer
    --- How long the whole request may take, in nanoseconds; no limit by default.
    timeout_ns?: integer
    --- The transfer rate, in bytes per second, under which a request
    --- is too slow; 1 by default and 0 turns the check off.
    low_speed_bytes?: integer
    --- How long it may stay under `low_speed_bytes`, in nanoseconds; 60
    --- seconds by default.
    low_speed_ns?: integer
    --- Whether curl logs the transfer to standard error.
    verbose?: boolean
    --- Tests only: canned replies, one per connection, in place of the
    --- network. Every entry must be a string.
    script?: {string}
    --- The CA roots to trust: "minimal", "mozilla", "none", or a list of
    --- the SHA-256 digests of roots this binary carries; when nil,
    --- [`Http.default_roots`].
    roots?: string | {string}
    --- Certificates to trust besides `roots`: PEM, or one DER.
    ca?: string
    --- Public key pins, `sha256//<base64>`, one of which the server's
    --- key must match.
    pin?: string | {string}
    --- Download only: the expected sha256, sha512 and sha3-256, as hex.
    --- Each given is computed while the body is written and must match,
    --- or the download fails naming the algorithm, the digest wanted and
    --- the one got, leaving no file.
    sha256?: string
    --- Download only: see `sha256`.
    sha512?: string
    --- Download only: see `sha256`; sqlite.org publishes this one alone.
    sha3_256?: string
    --- Download only: asked before each chunk is read and once
    --- more when the body is complete, before it is renamed into place;
    --- when it answers true the download stops, removes its temporary
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

end

--- The roots of `opts.roots = "minimal"`, by the SHA-256 of each root's
--- DER as lower-case hex.
local MINIMAL_ROOTS <const>: {string} = {
  "96bcec06264976f37460779acf28c5a7cfe8a3c0aae11a8ffcee05c0bddf08c6", -- ISRG Root X1
  "69729b8e15a86efc177a57afb7171dfc64add28c2fca8cf1507e34453ccb1470", -- ISRG Root X2
  "cb3ccbb76031e5e0138f8dd39a23f9de47ffc35e43c1144cea27d46a5ab1cb5f", -- DigiCert Global Root G2
  "31ad6648f8104138c738f39ea4320133393e3a18cc02296ef97c2ac9ef6731d0", -- DigiCert Global Root G3
  "018e13f0772532cf809bd1b17281867283fc48c6e13be9c69812854a490c1b05", -- DigiCert TLS ECC P384 Root G5
  "371a00dc0533b3721a7eeb40e8419e70799d2b0a0f2c1d80693165f7cec4ad75", -- DigiCert TLS RSA4096 Root G5
  "e793c9b02fd8aa13e21c31228accb08119643b749c898964b1746d46c3d4cbd2", -- USERTrust RSA Certification Authority
  "4ff460d54b9c86dabfbcfc5712e0400d2bed3fbc4d4fbdaa86e06adcd2a9ad7a", -- USERTrust ECC Certification Authority
  "7bb647a62aeeac88bf257aa522d01ffea395e0ab45c73f93f65654ec38f25a06", -- Sectigo Public Server Authentication Root R46
  "c90f26f0fb1b4018b22227519b5ca2b53e2ca5b3be5cf18efe1bef47380c5383", -- Sectigo Public Server Authentication Root E46
  "cbb522d7b7f127ad6a0113865bdf1cd4102e7d0759af635a7cf4720dc963c53b", -- GlobalSign Root CA - R3
  "2cabeafe37d06ca22aba7391c0033d25982952c453647349763a3ab5ad6ccf69", -- GlobalSign Root CA - R6
  "4fa3126d8d3a11d1c4855a4f807cbad6cf919d3a5a88b03bea2c6372d93c40c9", -- GlobalSign Root R46
  "cbb9c44d84b8043e1050ea31a69f514955d7bfd2e2c6b49301019ad61d9f5058", -- GlobalSign Root E46
  "b085d70b964f191a73e4af0d54ae7a0e07aafdaf9b71dd0862138ab7325a24a2", -- GlobalSign ECC Root CA - R4
  "179fbc148a3dd00fd24ea13458cc43bfa7f59c8182d783a513f6ebec100c8924", -- GlobalSign ECC Root CA - R5
  "d947432abde7b7fa90fc2e6b59101b1280e0e1c7e4e40fa3c6887fff57a7f4cf", -- GTS Root R1
  "34d8a73ee208d9bcdb0d956520934b4e40e69482596e8b6f73c8426b010a6f48", -- GTS Root R3
  "349dfa4058c5e263123b398ae795573c4e1313c83fe68f93556cd5e8031b3c7d", -- GTS Root R4
  "8ecde6884f3d87b1125ba31ac3fcb13d7016de7f57cc904fe1cb97c6ae98196e", -- Amazon Root CA 1
  "1ba5b2aa8c65401a82960118f80bec4f62304d83cec4713a19c39c011ea46db4", -- Amazon Root CA 2
  "18ce6cfe7bf14e60b2e347b8dfe868cb31d02ebb3ada271569f50343b46db3a4", -- Amazon Root CA 3
  "e35d28419ed02025cfa69038cd623962458da5c695fbdea3c22b0bfb25897092", -- Amazon Root CA 4
  "568d6905a2c88708a4b3025190edcfedb1974a606a13c6e5290fcb2ae63edab5", -- Starfield Services Root Certificate Authority - G2
  "c741f70f4b2a8d88bf2e71c14122ef53ef10eba0cfa5e64cfa20f418853073e0", -- Microsoft RSA Root Certificate Authority 2017
  "358df39d764af9e1b766e9c972df352ee15cfac227af6ad1d70e8e4a6edcba02", -- Microsoft ECC Root Certificate Authority 2017
}

--- The roots `opts.roots = "minimal"` trusts: those of the CAs that
--- issue for most of the web (Let's Encrypt, DigiCert, Sectigo,
--- GlobalSign, Google, Amazon, Microsoft), by the SHA-256 of each
--- root's DER as lower-case hex, in a list of the caller's own. Only
--- those this binary carries are trusted, so a root Mozilla withdraws,
--- and a refreshed binary drops, is not trusted for being listed here.
function Http.minimal_roots(): {string}
  return { table.unpack(MINIMAL_ROOTS) }
end

local MS <const> = Clock.ms(1)
local SECOND <const> = Clock.seconds(1)

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
  return Clock.ceil(ns, unit)
end

--- What `opts.roots` and `opts.ca` choose to trust, for [`trusted`] to
--- give curl.
local record Trust
  --- What names the blob these roots make for every request that chooses
  --- them, when one does ("minimal", "none"): nil when `ca` or a list of
  --- digests makes it the request's own.
  key: string | nil
  --- Every carried root, rather than only those `wanted` names.
  all: boolean
  --- Carried roots by the SHA-256 of their DER.
  wanted: {string:boolean}
  --- Whether the certificates $SSL_CERT_FILE names are trusted too.
  extra: boolean
  ca: string | nil
end

--- The roots a request that names none trusts, "minimal" or "mozilla",
--- and "": `COSMIC_CA_ROOTS` when it is set, else what `cosmic build
--- --roots` recorded in this executable, else "minimal". Nil and why
--- when either names anything else.
function Http.default_roots(): string | nil, string
  local chosen = Env.get("COSMIC_CA_ROOTS")
  local from = "COSMIC_CA_ROOTS"
  if chosen == nil or chosen == "" then
    chosen = Store.meta("ca_roots_default")
    from = "this executable's `cosmic build --roots`"
  end
  if chosen == nil or chosen == "" then
    return "minimal", ""
  end
  if chosen ~= "minimal" and chosen ~= "mozilla" then
    return nil, ("http: %s names %q, not minimal or mozilla"):format(from, chosen:sub(1, 40))
  end
  return chosen, ""
end

--- `opts.roots` and `opts.ca` as a [`Trust`], or nil when they leave
--- the trust store core/http.c holds (every carried root) as it is; and
--- "", or why the roots a request naming none trusts cannot be told
--- ([`Http.default_roots`]). Raises at `CALLER` for either of the wrong
--- shape, naming it.
local function trust_of(opts: Http.Options): Trust | nil, string
  local roots = opts.roots
  local ca = opts.ca
  if ca ~= nil and type(ca) ~= "string" then
    error("http: opts.ca must be a string", CALLER)
  end
  if roots == nil then
    local default, why = Http.default_roots()
    if default == nil then
      return nil, why
    end
    roots = default
  end
  local wanted: {string:boolean} = {}
  if roots == "mozilla" then
    if ca == nil then return nil, "" end
    return { key = nil, all = true, wanted = wanted, extra = true, ca = ca }, ""
  elseif roots == "minimal" then
    for _, hex in ipairs(MINIMAL_ROOTS) do
      wanted[assert(Codec.unhex(hex))] = true
    end
    local key: string | nil = nil
    if ca == nil then key = "minimal" end
    return { key = key, all = false, wanted = wanted, extra = true, ca = ca }, ""
  elseif roots == "none" then
    local key: string | nil = nil
    if ca == nil then key = "none" end
    return { key = key, all = false, wanted = wanted, extra = false, ca = ca }, ""
  elseif type(roots) == "table" then
    for i, hex in ipairs(roots) do
      local digest = ""
      if type(hex) == "string" then
        digest = (hex:gsub(":", ""))
      end
      local bytes, _ = Codec.unhex(digest)
      if #digest ~= 64 or bytes == nil then
        error(("http: opts.roots[%d] must be a root's SHA-256, as 64 hex digits"):format(i), CALLER)
      end
      wanted[bytes] = true
    end
    return { key = nil, all = false, wanted = wanted, extra = true, ca = ca }, ""
  end
  error('http: opts.roots must be "minimal", "mozilla", "none" or a list of SHA-256 digests', CALLER)
end

--- `opts.pin` as curl takes it, `;` between pins, or nil for none.
--- Raises at `CALLER` for one of the wrong shape: each pin is
--- `sha256//` and the base64 of 32 bytes, as [`Http.public_key_pin`]
--- makes it.
local function pin_of(opts: Http.Options): string | nil
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

--- `der` as PEM.
local function pem(der: string): string
  local encoded = Codec.base64(der)
  local lines: {string} = { "-----BEGIN CERTIFICATE-----" }
  for at = 1, #encoded, 64 do
    lines[#lines + 1] = encoded:sub(at, at + 63)
  end
  lines[#lines + 1] = "-----END CERTIFICATE-----\n"
  return table.concat(lines, "\n")
end

local BEGIN <const> = "%-%-%-%-%-BEGIN CERTIFICATE%-%-%-%-%-"
local END <const> = "%-%-%-%-%-END CERTIFICATE%-%-%-%-%-"

--- The certificates `text` holds, as DER: each PEM block, or `text`
--- itself when it holds none and is one DER certificate. Nil and why
--- when one is not closed, not base64, or not a certificate the TLS
--- stack reads.
local function certificates(text: string): {string} | nil, string
  if not text:find("-----BEGIN", 1, true) then
    local ok, why = http.check_certificate(text)
    if not ok then return nil, why end
    return { text }, ""
  end
  local _, begun = text:gsub(BEGIN, "")
  local ders: {string} = {}
  for body in text:gmatch(BEGIN .. "(.-)" .. END) do
    local der, why = Codec.unbase64((body:gsub("%s", "")))
    if der == nil then
      return nil, ("certificate %d is not base64: %s"):format(#ders + 1, why)
    end
    local ok, unread = http.check_certificate(der)
    if not ok then
      return nil, ("certificate %d: %s"):format(#ders + 1, unread)
    end
    ders[#ders + 1] = der
  end
  if #ders == 0 then
    return nil, "holds no certificate"
  end
  if #ders ~= begun then
    return nil, ("certificate %d is not closed"):format(#ders + 1)
  end
  return ders, ""
end

--- One carried root, under the SHA-256 of its DER.
local record Carried
  der: string
  digest: string
end

--- The trust store's certificates, read once: the carried roots with
--- their digests, and those $SSL_CERT_FILE named.
local record Held
  carried: {Carried} | nil
  extra: {string}
  --- The blob of each [`Trust`] with a `key`, by it, made once.
  blobs: {string:string}
end
local store: Held = { carried = nil, extra = {}, blobs = {} }

--- The carried roots with their digests, read from the trust store
--- the first time, or nil and why when it cannot be made.
local function carried_roots(): {Carried} | nil, string
  local held = store.carried
  if held ~= nil then
    return held, ""
  end
  local roots, trouble = http.roots()
  if roots == nil then
    return nil, trouble
  end
  local read: {Carried} = {}
  for _, der in ipairs(roots.carried) do
    read[#read + 1] = { der = der, digest = Hash.sha256(der) }
  end
  store.carried = read
  store.extra = roots.extra
  return read, ""
end

--- The PEM of every certificate `trust` names, or nil and why: when the
--- trust store cannot be made, `trust.ca` holds what the TLS stack
--- cannot read, or nothing is left to trust.
local function trusted(trust: Trust): string | nil, string
  local key = trust.key
  if key ~= nil then
    local made = store.blobs[key]
    if made ~= nil then
      return made, ""
    end
  end
  local carried, trouble = carried_roots()
  if carried == nil then
    return nil, trouble
  end
  local pems: {string} = {}
  for _, root in ipairs(carried) do
    if trust.all or trust.wanted[root.digest] == true then
      pems[#pems + 1] = pem(root.der)
    end
  end
  if trust.extra then
    for _, der in ipairs(store.extra) do
      pems[#pems + 1] = pem(der)
    end
  end
  local ca = trust.ca
  if ca ~= nil then
    local ders, why = certificates(ca)
    if ders == nil then
      return nil, "http: opts.ca: " .. why
    end
    for _, der in ipairs(ders) do
      pems[#pems + 1] = pem(der)
    end
  end
  if #pems == 0 then
    return nil, "http: no CA roots to trust: opts.roots names none this binary carries, and opts.ca none"
  end
  local blob = table.concat(pems)
  if key ~= nil then
    store.blobs[key] = blob
  end
  return blob, ""
end

--- `opts` as the raw module reads them: its spans in the milliseconds
--- (and, for `low_speed_ns`, the seconds) it counts them in, its `pin`
--- as curl takes it, and, with `trusting`, the `ca_blob` of the roots it
--- chooses ([`trust_of`], [`trusted`]); or nil and why when those cannot
--- be made. `method`, when given, stands in for `opts.method`.
local function raw_options(given: Http.Options | nil, method?: string,
                           trusting?: boolean): raw_http.Options | nil, string
  local opts: Http.Options = given or {}
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
  local trust, untold = trust_of(opts)
  if untold ~= "" then
    return nil, untold
  end
  local blob: string | nil = nil
  if trusting == true and trust ~= nil then
    local made, why = trusted(trust)
    if made == nil then
      return nil, why
    end
    blob = made
  end
  return {
    unix_socket = via and via.path,
    method = method or opts.method,
    headers = opts.headers,
    body = opts.body,
    follow = follow,
    max_redirects = opts.max_redirects,
    redirect_protocols = opts.redirect_protocols,
    connect_timeout_ms = counted(opts.connect_timeout_ns, MS, math.maxinteger, "connect_timeout_ns"),
    timeout_ms = counted(opts.timeout_ns, MS, math.maxinteger, "timeout_ns"),
    low_speed_bytes = opts.low_speed_bytes,
    low_speed_seconds = counted(opts.low_speed_ns, SECOND, 65535 * SECOND, "low_speed_ns"),
    verbose = opts.verbose,
    script = opts.script,
    pin = pin_of(opts),
    ca_blob = blob,
  }, ""
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
--- authority, each `%` not followed by two hex digits is written `%25`
--- (requests, finding one, writes every `%` so; this keeps the escapes
--- around it), and each byte `escape_unsafe` holds is escaped, so a URL
--- holding none of them is sent as written and one escaped already is
--- not escaped again. A space or control byte in the authority is
--- refused, naming it: a host takes no escape, and curl would refuse it
--- as "Malformed input to a URL function". The scheme is read as curl
--- reads it, with any number of slashes after its `:`, and a URL with
--- none starts with its authority.
local function sendable(url: string): string | nil, string
  local _, scheme_end = url:find("^[A-Za-z][A-Za-z0-9+.-]*:/*")
  local rest = url:find("[/?#]", (scheme_end or 0) + 1) or #url + 1
  local at = url:sub(1, rest - 1):find("[\0-\32\127]")
  if at ~= nil then
    local byte = url:byte(at)
    local what = byte == 32 and "a space" or byte == 0 and "a NUL" or ("control byte 0x%02x"):format(byte)
    local user_end = url:find("@", at, true)
    if user_end ~= nil and user_end < rest then
      return nil, ("http: the URL holds %s at byte %d, in its user info; " ..
        "a user name or password goes in through Url.escape"):format(what, at)
    end
    return nil, ("http: the URL holds %s at byte %d, in its host, which holds none"):format(what, at)
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
  local raw, unmade = raw_options(opts, method, true)
  if raw == nil and unmade ~= "" then
    return nil, unmade
  end
  local handle, trouble = http.open(url, raw)
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
--- the byte; a user name or password goes in through [`Url.escape`].
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
  local method = opts and opts.method
  if method ~= nil and method ~= "GET" then
    error(("http: Http.get sends a GET, not %q; send another method with Http.request(method, url, opts)"):
        format(method), 2)
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
  local given = opts and opts.method
  if given ~= nil and given ~= method then
    error(("http: Http.request was given %q and opts.method %q; leave opts.method out"):
        format(method, given), 2)
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
  response?: Http.Response
  file?: Stream.FileWriter
  metamethod __close: function(PendingDownload)
end

local pending_mt: metatable<PendingDownload> = {
  __close = function(self: PendingDownload)
    local response = self.response
    if response ~= nil then local _, _ = response:close() end
    local file = self.file
    if file ~= nil then local _, _ = file:abort() end
  end,
}

--- [`Http.download_result`]'s work, which each public entry point that
--- downloads calls itself (`CALLER`).
local function downloading(url: string, path: string,
                           opts: Http.Options | nil): Http.DownloadResult
  opts = opts or {}
  local record Given
    algorithm: Hash.Algorithm
    wanted: string
  end
  local record Check
    algorithm: Hash.Algorithm
    hex: string
    hashing: Stream.Hashing
  end
  local given: {Given} = {
    { algorithm = "sha256", wanted = opts.sha256 or "" },
    { algorithm = "sha512", wanted = opts.sha512 or "" },
    { algorithm = "sha3-256", wanted = opts.sha3_256 or "" },
  }
  local checks: {Check} = {}
  for _, pair in ipairs(given) do
    local algorithm, wanted = pair.algorithm, pair.wanted
    if wanted ~= "" then
      local hashing, trouble = Stream.hashing(algorithm)
      if hashing == nil then return { kind = "failed", reason = trouble } end
      checks[#checks + 1] = { algorithm = algorithm, hex = wanted:lower(), hashing = hashing }
    end
  end
  local pending <close>: PendingDownload = setmetatable({}, pending_mt)
  -- `opts` is checked here, so a refusal is raised at `CALLER`; the open
  -- goes through [`Http.open`], which finds nothing more to refuse.
  local _, _ = raw_options(opts)
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
  for _, check in ipairs(checks) do sink = Stream.tee(sink, check.hashing) end
  local source: Stream.Reader = response
  local cancelled = opts.cancelled
  if cancelled ~= nil then source = cancellable(response, cancelled) end
  local copied, trouble = Stream.copy(source, sink)
  local _, _ = response:close()
  pending.response = nil
  if copied == nil then
    return { kind = "failed", reason = trouble }
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
    return { kind = "failed", reason = commit_trouble }
  end
  pending.file = nil
  return { kind = "downloaded", reason = "" }
end

--- Downloads `url` to `path`, streaming
--- to a fresh temporary file beside it ([`Stream.create`]'s, so two
--- downloads never share one and a planted symlink is never followed)
--- and renaming into place only once the transfer is complete, synced to
--- disk and, when `opts.sha256`, `opts.sha512` or `opts.sha3_256` is
--- given, verified: a reader never sees a partial file at the final name. Fails on a
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

--- The public key pin of `cert`, one certificate as PEM or DER, as
--- `opts.pin` and curl's `--pinnedpubkey` take it: `sha256//` and the
--- base64 of the SHA-256 of its SubjectPublicKeyInfo, and "". Nil and
--- why when the TLS stack cannot read `cert` as exactly one
--- certificate. Raises when there was no memory to read it.
---
---     local pin = assert(Http.public_key_pin(assert(Fs.read("server.pem"))))
---     local got = assert(Http.get("https://internal.example/", { pin = pin }))
function Http.public_key_pin(cert: string): string | nil, string
  local spki, why = http.public_key(cert)
  if spki == nil then
    return nil, why
  end
  return "sha256//" .. Codec.base64(Hash.sha256(spki)), ""
end

return Http
