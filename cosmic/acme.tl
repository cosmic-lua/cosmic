--- An ACME client (RFC 8555): it asks a certificate authority such as
--- Let's Encrypt for a certificate, proving control of each name by a
--- challenge, and answers the certificate chain as PEM.
---
---     local served: {string: string} = {} -- what a web server on port 80 answers
---     local account = Acme.p256_key(Sign.p256_secret())
---     local client = Acme.client({ directory = Acme.LETS_ENCRYPT_STAGING, key = account })
---     assert(client:account({ contact = { "mailto:ops@example.com" }, terms_agreed = true }))
---     local chain = assert(client:issue({ "example.com", "www.example.com" }, {
---       key = Acme.p256_key(Sign.p256_secret()),
---       challenge = "http-01",
---       present = function(c: Acme.Challenge): boolean, string
---         served[c.path] = c.key_authorization
---         return true, ""
---       end,
---     }))
---
--- [`Acme.Client.issue`] runs the whole flow: it places an order, has
--- `present` publish each challenge's response, tells the server to
--- check it, waits for the order to be ready, sends a certificate
--- signing request ([`Acme.csr`]) and fetches the chain. Each step is a
--- method of its own too, for a caller that drives the flow itself.
---
--- Two challenges are here. For "http-01", `present` serves
--- `key_authorization` as the body of `http://<name>/<path>` on port
--- 80. For "dns-01", `present` puts `dns_value` in a TXT record named
--- `dns_name`; a wildcard name (`*.example.com`) takes only dns-01.
---
--- [`Acme.auto`] does all of it for a server: it keeps a certificate in a
--- directory and renews it, serving the http-01 check on the server's
--- own `clear` listener, so a server gets HTTPS from a public CA with no
--- other program, and [`cosmic.web`]'s serve takes one as `acme`. In a task of
--- [`Poll.run`] every request and pause of a client waits through the
--- run, so the server goes on meanwhile.
---
--- An account key and a certificate key are each an [`Acme.Key`]:
--- [`Acme.p256_key`] makes one from a [`Sign.p256_secret`], and
--- [`Acme.rsa_key`] from a [`Sign.rsa_secret`], for a server or a
--- client of the certificate that takes RSA alone. Keep the account
--- key's secret: the account is that key, and a lost one means a new
--- account. Use another key for the certificate. A key's `pem` is its
--- secret as a web server reads one, and [`Acme.read_key`] reads it
--- back, or a key OpenSSL wrote.
---
--- Every fallible function answers `value, ""` or `nil, why`, the why
--- opening `acme: `. A problem document the server sends (RFC 8555
--- section 6.7) is named in the why by its type and detail. A request
--- the server refuses for a stale nonce (`badNonce`) is sent again once
--- with the fresh nonce it handed back, as section 6.5 asks.

-- TODO: tls-alpn-01 for Acme.auto, which needs a TLS configuration chosen
-- by ALPN in cosmic.tls; several certificates (sets of names, or an RSA
-- chain beside the ECDSA one) in one Acme.auto; renewal information
-- (RFC 9773) to time Acme.auto's renewals; a lock on Acme.auto's dir for
-- processes that share it. Each once a caller needs one.

-- TODO: wait out a 429 on the directory's GET and newNonce's HEAD too,
-- as a signed request's is, once a server limits those: each is sent
-- once a client, or once a request, and Let's Encrypt limits neither.

-- TODO: tls-alpn-01 for a caller of the client, the alternate chains a `Link: rel="alternate"`
-- names, key rollover, account deactivation, revocation, External
-- Account Binding and renewal information (RFC 9773), once a caller
-- needs one.

local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Sign = require("cosmic.sign")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local Tls = require("cosmic.tls")
-- Only the types: a handler is a function and a reply a table, so a
-- program that issues alone does not load the server.
local type Server = require("cosmic.http.server")

local record Acme
  --- A key that signs ACME requests (as the account's key) or a
  --- certificate signing request (as the certificate's key).
  record Key
    --- The JWS algorithm the key signs with, as RFC 7518 names it:
    --- "ES256" or "RS256".
    alg: string
    --- The public key as a JSON Web Key (RFC 7517), its members in hand
    --- for a thumbprint: `crv`, `kty`, `x` and `y` for an EC key, `e`,
    --- `kty` and `n` for an RSA key.
    jwk: {string: string}
    --- The DER SubjectPublicKeyInfo of the public key (RFC 5280).
    spki: string
    --- The DER AlgorithmIdentifier of the X.509 signature the key makes.
    signature_algorithm: string
    --- The JWS signature of `message`: for ES256, R then S; for RS256,
    --- the PKCS #1 v1.5 signature.
    sign: function(message: string): string
    --- The X.509 signature of `message`: for ECDSA, the DER SEQUENCE of R
    --- and S; for RSA, the PKCS #1 v1.5 signature as it is.
    x509_sign: function(message: string): string
    --- The private key as PEM, the form a web server reads a certificate's
    --- key in and [`Acme.read_key`] reads back: "EC PRIVATE KEY" (SEC 1)
    --- for P-256, "RSA PRIVATE KEY" (PKCS #1) for RSA. It holds the
    --- secret: write it to a file only its owner reads, and never log or
    --- print a key whole.
    pem?: string
  end

  --- The kinds of challenge [`Acme.Client.issue`] can answer.
  enum ChallengeType
    "http-01"
    "dns-01"
  end

  --- One challenge of an authorization, with what proves it.
  record Challenge
    --- "http-01", "dns-01", or another type the server offers.
    type: string
    --- The challenge's URL, which [`Acme.Client.respond`] posts to.
    url: string
    --- "pending", "processing", "valid" or "invalid".
    status: string
    --- The server's token for the challenge.
    token: string
    --- The name the challenge proves control of, with no `*.`.
    domain: string
    --- The token and the account key's thumbprint, joined by a dot
    --- (RFC 8555 section 8.1).
    key_authorization: string
    --- For http-01: the path to serve `key_authorization` at,
    --- `/.well-known/acme-challenge/<token>`.
    path: string
    --- For dns-01: the TXT record's name, `_acme-challenge.<domain>`.
    dns_name: string
    --- For dns-01: the TXT record's value, the base64url SHA-256 of
    --- `key_authorization`.
    dns_value: string
    --- The detail of the problem the server found, once the challenge is
    --- invalid; "" before.
    error: string
  end

  --- An authorization: what the account must prove for one identifier.
  record Authorization
    --- The authorization's URL.
    url: string
    --- "pending", "valid", "invalid", "deactivated", "expired" or "revoked".
    status: string
    --- The identifier's value, a DNS name, with no `*.`.
    domain: string
    --- Whether the order asked for `*.<domain>`.
    wildcard: boolean
    --- The challenges the server offers, any one of which proves it.
    challenges: {Challenge}
  end

  --- An order for a certificate.
  record Order
    --- The order's URL.
    url: string
    --- "pending", "ready", "processing", "valid" or "invalid".
    status: string
    --- The DNS names the order is for, as asked.
    names: {string}
    --- The URLs of the order's authorizations.
    authorizations: {string}
    --- The URL [`Acme.Client.finalize`] posts the request to.
    finalize: string
    --- The certificate's URL, once the order is valid.
    certificate?: string
  end

  --- What [`Acme.Client.account`] sends.
  record AccountOptions
    --- Contact URLs, such as `mailto:ops@example.com`.
    contact?: {string}
    --- Whether the caller agrees to the server's terms of service, which
    --- `terms` names once the directory is read.
    terms_agreed?: boolean
    --- Whether only an existing account is looked up, none created.
    only_existing?: boolean
  end

  --- What [`Acme.Client.issue`] takes.
  record IssueOptions
    --- The certificate's key: its public key goes in the request.
    key: Key
    --- The challenge type to answer, "http-01" when nil.
    challenge?: ChallengeType
    --- Publishes a challenge's response before the server checks it:
    --- true, or false and why, which stops the issue. The server checks
    --- as soon as this returns, so it returns only once the response is
    --- reachable: a dns-01 record has spread to the zone's servers.
    present: function(challenge: Challenge): boolean, string
    --- Withdraws what `present` published, once the authorization is
    --- settled either way. Its answer is not checked.
    cleanup?: function(challenge: Challenge)
  end

  --- How [`Acme.Client.wait`] waits.
  record WaitOptions
    --- The longest wait in all, in nanoseconds: 2 minutes when nil.
    timeout_ns?: integer
    --- The wait between polls when the server names none in a
    --- `Retry-After`, in nanoseconds: 2 seconds when nil.
    interval_ns?: integer
  end

  --- The transport [`Acme.ClientOptions.request`] names: what
  --- [`Http.request`] is.
  type Request = function(method: string, url: string, opts: Http.Options): Http.Body?, string

  --- What [`Acme.client`] takes.
  record ClientOptions
    --- The directory URL, such as [`Acme.LETS_ENCRYPT`].
    directory: string
    --- The account's key.
    key: Key
    --- The account's URL, when it is already known: it skips the
    --- lookup [`Acme.Client.account`] does.
    account?: string
    --- Sends a request: [`Http.request`] when nil. A test hands its own.
    request?: Request
    --- Pauses between polls, for nanoseconds: [`Clock.sleep_ns`] when
    --- nil. A test hands one that returns at once.
    pause?: function(ns: integer): boolean, string
    --- [`Acme.Client.wait`]'s options for every wait [`Acme.Client.issue`]
    --- makes.
    wait?: WaitOptions
    --- The longest `Retry-After` of a 429 (`rateLimited`) the client
    --- waits out before it sends the request again, in nanoseconds: 1
    --- minute when nil, 0 for none. A longer one fails the request,
    --- saying how long the server asked for.
    rate_limit_wait_ns?: integer
  end

  --- What [`Acme.AutoOptions.dns`] takes: dns-01 in place of http-01.
  record DnsHooks
    --- Puts the TXT record `challenge.dns_name` with the value
    --- `challenge.dns_value` in the zone, and returns only once the
    --- zone's servers answer it: true, or false and why, which stops
    --- the issue.
    present: function(challenge: Challenge): boolean, string
    --- Removes it, once the authorization is settled either way.
    cleanup?: function(challenge: Challenge)
  end

  --- What [`Acme.auto`] takes.
  record AutoOptions
    --- The DNS names the certificate is for, the first its subject. A
    --- wildcard (`*.example.com`) needs `dns`.
    names: {string}
    --- The directory the account key and the certificate are kept in,
    --- made with mode 0700 where missing: `account.pem`, the account's
    --- key, made on the first issue; and `certificate.pem`, the chain
    --- and its key. A restart serves the certificate kept there and asks
    --- the CA for nothing, which matters: Let's Encrypt issues only a
    --- few certificates a week for one set of names.
    dir: string
    --- Agreement to the CA's terms of service, which an account needs.
    terms_agreed: boolean
    --- Contact URLs for the account, such as `mailto:ops@example.com`.
    contact?: {string}
    --- The directory URL: [`Acme.LETS_ENCRYPT`] when nil.
    directory?: string
    --- The certificate's key, the same at every renewal: one that
    --- [`Acme.read_key`] or [`Acme.p256_key`] made, with its `pem`. A new
    --- P-256 key for each certificate when nil.
    key?: Key
    --- Answers dns-01 through these hooks in place of http-01.
    dns?: DnsHooks
    --- As [`Acme.ClientOptions.request`].
    request?: Request
    --- As [`Acme.ClientOptions.pause`].
    pause?: function(ns: integer): boolean, string
    --- As [`Acme.ClientOptions.wait`].
    wait?: WaitOptions
    --- As [`Acme.ClientOptions.rate_limit_wait_ns`].
    rate_limit_wait_ns?: integer
  end

  --- A certificate from an ACME CA kept current for a server, from
  --- [`Acme.auto`].
  record Auto
    --- The certificate, for a server's `tls`: each load serves the one
    --- kept in `dir` while it is valid as long as the load asks, and
    --- issues a new one otherwise.
    certs: Tls.Certs
    --- The response an http-01 check of this server asks for at
    --- `path`, while one is pending; nil otherwise.
    answer: function(self: Auto, path: string): string?
    --- A handler for a server's `handle` that answers the http-01 checks
    --- of the requests that came in the clear and redirects their
    --- others to HTTPS (308), handing every request over TLS to `after`
    --- (404 when nil).
    handler: function(self: Auto, after?: function(req: Server.Request): Server.Reply): function(req: Server.Request): Server.Reply
  end

  --- Let's Encrypt's production directory.
  LETS_ENCRYPT: string
  --- Let's Encrypt's staging directory: untrusted certificates, higher limits.
  LETS_ENCRYPT_STAGING: string

  --- A session with one ACME server under one account key, from
  --- [`Acme.client`].
  record Client
    --- The account key's thumbprint (RFC 7638), base64url.
    thumbprint: string

    --- The server's directory, read once and kept: each resource's
    --- name (`newNonce`, `newAccount`, `newOrder`, ...) to its URL, and
    --- `terms` for the terms of service when the server has one.
    directory: function(self: Client): {string: string}?, string
    --- The account's URL, created (or, with `only_existing`, found)
    --- under the client's key, and kept for every later request. A key
    --- with an account already answers that account.
    account: function(self: Client, opts?: AccountOptions): string?, string
    --- A new order for the DNS names `names`.
    order: function(self: Client, names: {string}): Order?, string
    --- The order at `url`, read again.
    get_order: function(self: Client, url: string): Order?, string
    --- The authorization at `url`.
    authorization: function(self: Client, url: string): Authorization?, string
    --- Tells the server to check the challenge: true, or false and why.
    respond: function(self: Client, challenge: Challenge): boolean, string
    --- Polls the order or authorization at `url` until its status is
    --- not "pending" or "processing", and answers that status. Nil and
    --- why when the time runs out.
    wait: function(self: Client, url: string, opts?: WaitOptions): string?, string
    --- Sends the DER certificate signing request `csr` to the order's
    --- `finalize` URL, and answers the order as it stands after.
    finalize: function(self: Client, order: Order, csr: string): Order?, string
    --- The certificate chain at `url`, as PEM.
    certificate: function(self: Client, url: string): string?, string
    --- A certificate for the DNS names `names` under `opts.key`: the
    --- whole flow, as the module's doc says. Answers the chain as PEM.
    issue: function(self: Client, names: {string}, opts: IssueOptions): string?, string
  end
end

Acme.LETS_ENCRYPT = "https://acme-v02.api.letsencrypt.org/directory"
Acme.LETS_ENCRYPT_STAGING = "https://acme-staging-v02.api.letsencrypt.org/directory"

-- DER, as much of it as a certificate signing request needs.

local function der_length(n: integer): string
  if n < 0x80 then return string.char(n) end
  local bytes: mut {string} = {}
  while n > 0 do
    table.insert(bytes, 1, string.char(n & 0xff))
    n = n >> 8
  end
  return string.char(0x80 | #bytes) .. table.concat(bytes)
end

local function der(tag: integer, content: string): string
  return string.char(tag) .. der_length(#content) .. content
end

local function der_sequence(...: string): string
  return der(0x30, table.concat({ ... }))
end

--- The DER INTEGER of the unsigned big-endian `bytes`.
local function der_unsigned(bytes: string): string
  local first = bytes:find("[^\0]")
  local trimmed = if first == nil then "\0" else bytes:sub(first) end
  if (trimmed:byte(1) or 0) >= 0x80 then trimmed = "\0" .. trimmed end
  return der(0x02, trimmed)
end

local function der_oid(dotted: string): string
  local arcs: mut {integer} = {}
  for arc in dotted:gmatch("%d+") do arcs[#arcs + 1] = math.tointeger(tonumber(arc)) or 0 end
  local out: mut {string} = { string.char(40 * (arcs[1] or 0) + (arcs[2] or 0)) }
  for i = 3, #arcs do
    local arc = arcs[i] or 0
    local digits: mut {string} = { string.char(arc & 0x7f) }
    arc = arc >> 7
    while arc > 0 do
      table.insert(digits, 1, string.char(0x80 | (arc & 0x7f)))
      arc = arc >> 7
    end
    out[#out + 1] = table.concat(digits)
  end
  return der(0x06, table.concat(out))
end

local function der_bits(bytes: string): string
  return der(0x03, "\0" .. bytes)
end

local DER_NULL <const> = "\5\0"

--- One element of a DER SEQUENCE: its tag and its content.
local record Element
  tag: integer
  content: string
  --- The index after the element in what it was read from.
  after: integer
end

--- The element at `at` of the DER `bytes`, or nil where it is cut short
--- or its length is indefinite or of more than four bytes. It reads BER's
--- longer spellings of a length too, and a tag of one byte alone.
local function der_read(bytes: string, at: integer): Element?
  local tag, first = bytes:byte(at, at + 1)
  if tag == nil or first == nil or first == 0x80 or first > 0x84 then return nil end
  local length, start = first, at + 2
  if first > 0x80 then
    length = 0
    for i = 1, first & 0x7f do length = (length << 8) | (bytes:byte(at + 1 + i) or 0) end
    start = at + 2 + (first & 0x7f)
  end
  if start + length - 1 > #bytes then return nil end
  return { tag = tag, content = bytes:sub(start, start + length - 1), after = start + length }
end

--- The elements of the constructed content `content`, or nil where one
--- is cut short.
local function der_elements(content: string): {Element}?
  local out: mut {Element} = {}
  local at = 1
  while at <= #content do
    local element = der_read(content, at)
    if element == nil then return nil end
    out[#out + 1] = element
    at = element.after
  end
  return out
end

--- The elements of the DER SEQUENCE that is the whole of `der_bytes`,
--- or nil.
local function der_sequence_of(der_bytes: string): {Element}?
  local element = der_read(der_bytes, 1)
  if element == nil or element.tag ~= 0x30 or element.after ~= #der_bytes + 1 then return nil end
  return der_elements(element.content)
end

--- The PEM of the DER `der` under `label` (RFC 7468): base64 in lines of
--- 64 characters between the BEGIN and END lines.
local function pem(label: string, der_bytes: string): string
  local text = Codec.base64(der_bytes)
  local lines: mut {string} = { "-----BEGIN " .. label .. "-----" }
  for i = 1, #text, 64 do lines[#lines + 1] = text:sub(i, i + 63) end
  lines[#lines + 1] = "-----END " .. label .. "-----"
  return table.concat(lines, "\n") .. "\n"
end

local OID_EC_PUBLIC_KEY <const> = "1.2.840.10045.2.1"
local OID_P256 <const> = "1.2.840.10045.3.1.7"
local OID_ECDSA_SHA256 <const> = "1.2.840.10045.4.3.2"
local OID_RSA_ENCRYPTION <const> = "1.2.840.113549.1.1.1"
local OID_RSA_SHA256 <const> = "1.2.840.113549.1.1.11"
local OID_COMMON_NAME <const> = "2.5.4.3"
local OID_EXTENSION_REQUEST <const> = "1.2.840.113549.1.9.14"
local OID_SUBJECT_ALT_NAME <const> = "2.5.29.17"

--- An [`Acme.Key`] over the P-256 `secret`, a [`Sign.p256_secret`]: it
--- signs JWS as ES256 and X.509 as ecdsa-with-SHA256. Raises on a secret
--- [`Sign.p256_public`] refuses.
---
---     local key = Acme.p256_key(Sign.p256_secret())
---     assert(key.alg == "ES256" and key.jwk.crv == "P-256")
function Acme.p256_key(secret: string): Acme.Key
  local public = Sign.p256_public(secret)
  return {
    alg = "ES256",
    jwk = {
      crv = "P-256",
      kty = "EC",
      x = Codec.base64url(public:sub(2, 33)),
      y = Codec.base64url(public:sub(34, 65)),
    },
    spki = der_sequence(der_sequence(der_oid(OID_EC_PUBLIC_KEY), der_oid(OID_P256)), der_bits(public)),
    signature_algorithm = der_sequence(der_oid(OID_ECDSA_SHA256)),
    pem = pem("EC PRIVATE KEY", der_sequence(der_unsigned("\1"), der(0x04, secret),
      der(0xa0, der_oid(OID_P256)), der(0xa1, der_bits(public)))),
    sign = function(message: string): string
      return Sign.p256(secret, message)
    end,
    x509_sign = function(message: string): string
      local signature = Sign.p256(secret, message)
      return der_sequence(der_unsigned(signature:sub(1, 32)), der_unsigned(signature:sub(33, 64)))
    end,
  }
end

--- An [`Acme.Key`] over the RSA `secret`, a [`Sign.rsa_secret`] (a DER
--- RSAPrivateKey of 2048 to 4096 bits): it signs JWS as RS256 and X.509
--- as sha256WithRSAEncryption. Raises on a secret [`Sign.rsa_public`]
--- refuses.
---
---     local key = Acme.rsa_key(Sign.rsa_secret())
---     assert(key.alg == "RS256" and key.jwk.e == "AQAB")
function Acme.rsa_key(secret: string): Acme.Key
  local public = Sign.rsa_public(secret)
  -- An RSAPublicKey is the SEQUENCE of the INTEGERs n and e, each
  -- positive: a JWK spells each without the zero a DER INTEGER leads with.
  local numbers = assert(der_sequence_of(public), "an RSAPublicKey is a SEQUENCE")
  local n, e = assert(numbers[1], "n").content, assert(numbers[2], "e").content
  return {
    alg = "RS256",
    jwk = {
      e = Codec.base64url((e:gsub("^\0+", ""))),
      kty = "RSA",
      n = Codec.base64url((n:gsub("^\0+", ""))),
    },
    spki = der_sequence(der_sequence(der_oid(OID_RSA_ENCRYPTION), DER_NULL), der_bits(public)),
    signature_algorithm = der_sequence(der_oid(OID_RSA_SHA256), DER_NULL),
    pem = pem("RSA PRIVATE KEY", secret),
    sign = function(message: string): string
      return Sign.rsa(secret, message)
    end,
    x509_sign = function(message: string): string
      return Sign.rsa(secret, message)
    end,
  }
end

--- A failure of [`cosmic.sign`]'s, raised as `sign: why`, as this
--- module's.
local function sign_refusal(raised: any): string
  local message = tostring(raised)
  return "acme: " .. (message:match("sign: (.*)$") or message)
end

--- The P-256 secret of the DER ECPrivateKey `der_bytes` (SEC 1 section
--- C.4) whose curve, where it or `curve` names one, is P-256, or nil and
--- why.
local function sec1_secret(der_bytes: string, curve?: string): string?, string
  local parts = der_sequence_of(der_bytes)
  local version = if parts == nil then nil else parts[1] end
  local secret = if parts == nil then nil else parts[2] end
  if parts == nil or version == nil or version.tag ~= 0x02 or version.content ~= "\1" or
      secret == nil or secret.tag ~= 0x04 or #secret.content == 0 then
    return nil, "acme: not an EC private key: no SEC 1 ECPrivateKey"
  end
  local named = curve
  for i = 3, #parts do
    local part = assert(parts[i])
    if part.tag == 0xa0 then named = part.content end
  end
  if named ~= nil and named ~= der_oid(OID_P256) then
    return nil, "acme: an EC key is on P-256, not another curve"
  end
  if #secret.content > 32 then return nil, "acme: a P-256 secret is 32 bytes at most" end
  return string.rep("\0", 32 - #secret.content) .. secret.content, ""
end

--- The [`Acme.Key`] over the P-256 `secret`, or nil and why it is out
--- of range.
local function p256_of(secret: string): Acme.Key?, string
  local readable, why = pcall(Sign.p256_public, secret)
  if not readable then return nil, sign_refusal(why) end
  return Acme.p256_key(secret), ""
end

--- The [`Acme.Key`] over the DER RSAPrivateKey `secret`, or nil and why
--- it is refused.
local function rsa_of(secret: string): Acme.Key?, string
  local readable, why = pcall(Sign.rsa_public, secret)
  if not readable then return nil, sign_refusal(why) end
  return Acme.rsa_key(secret), ""
end

--- The key of the DER PrivateKeyInfo `der_bytes` (RFC 5208), P-256 or
--- RSA, or nil and why.
local function pkcs8_key(der_bytes: string): Acme.Key?, string
  local parts = der_sequence_of(der_bytes)
  local version = if parts == nil then nil else parts[1] end
  local algorithm = if parts == nil then nil else parts[2] end
  local inner = if parts == nil then nil else parts[3] end
  if version == nil or version.tag ~= 0x02 or (version.content ~= "\0" and version.content ~= "\1") or
      algorithm == nil or algorithm.tag ~= 0x30 or
      inner == nil or inner.tag ~= 0x04 then
    return nil, "acme: not a private key: no PKCS #8 PrivateKeyInfo"
  end
  local identifiers = der_elements(algorithm.content)
  local oid = if identifiers == nil then nil else identifiers[1] end
  local parameters = if identifiers == nil then nil else identifiers[2] end
  local oid_der = if oid == nil then "" else der(oid.tag, oid.content) end
  if oid_der == der_oid(OID_RSA_ENCRYPTION) then return rsa_of(inner.content) end
  if oid_der == der_oid(OID_EC_PUBLIC_KEY) then
    local curve = if parameters == nil then nil else der(parameters.tag, parameters.content) end
    local secret, why = sec1_secret(inner.content, curve)
    if secret == nil then return nil, why end
    return p256_of(secret)
  end
  return nil, "acme: a private key is P-256 or RSA, not another algorithm"
end

--- The labels of the PEM blocks [`Acme.read_key`] reads.
local KEY_LABELS <const>: {string: boolean} = {
  ["EC PRIVATE KEY"] = true, ["RSA PRIVATE KEY"] = true, ["PRIVATE KEY"] = true,
}

--- The [`Acme.Key`] in the PEM `text`, as [`Acme.Key`]'s `pem` writes it
--- or as OpenSSL does: "EC PRIVATE KEY" (SEC 1) on P-256, "RSA PRIVATE
--- KEY" (PKCS #1), or "PRIVATE KEY" (PKCS #8) holding either. Text
--- around the block is skipped, an "EC PARAMETERS" block in front
--- included; the first key block decides. Nil and why for text with no such block, a block whose
--- base64 or DER is broken, a key on another curve or of another
--- algorithm, a P-256 secret out of range, or an RSA key of fewer than
--- 2048 bits or more than 4096. An encrypted key ("ENCRYPTED PRIVATE
--- KEY", or a block with a `Proc-Type` header) is not read: decrypt it
--- first (`openssl pkey -in key.pem -out plain.pem`).
---
---     local key = assert(Acme.read_key(assert(Fs.read("account.pem"))))
function Acme.read_key(text: string): Acme.Key?, string
  for label, body in text:gmatch("%-%-%-%-%-BEGIN ([%u ]+)%-%-%-%-%-(.-)%-%-%-%-%-END %1%-%-%-%-%-") do
    if label == "ENCRYPTED PRIVATE KEY" then
      return nil, "acme: the key is encrypted: decrypt it first"
    end
    if KEY_LABELS[label] == true then
      if body:find("Proc-Type:", 1, true) ~= nil then
        return nil, "acme: the key is encrypted: decrypt it first"
      end
      local der_bytes, undecoded = Codec.unbase64((body:gsub("%s", "")))
      if der_bytes == nil then
        return nil, "acme: the " .. label .. " block is not base64: " .. undecoded
      end
      if label == "PRIVATE KEY" then return pkcs8_key(der_bytes) end
      if label == "RSA PRIVATE KEY" then return rsa_of(der_bytes) end
      local secret, why = sec1_secret(der_bytes)
      if secret == nil then return nil, why end
      return p256_of(secret)
    end
  end
  return nil, "acme: no private key in the text: no EC, RSA or PKCS #8 PRIVATE KEY block"
end

--- The thumbprint of `key`'s JWK (RFC 7638): the base64url SHA-256 of
--- its members in the order of their names, with no space.
---
---     local key = Acme.p256_key(Sign.p256_secret())
---     assert(#Acme.thumbprint(key) == 43)
function Acme.thumbprint(key: Acme.Key): string
  local members: mut {string} = {}
  for name, value in pairs(key.jwk) do
    members[#members + 1] = Json.quote(name) .. ":" .. Json.quote(value)
  end
  table.sort(members)
  return Codec.base64url(Hash.sha256("{" .. table.concat(members, ",") .. "}"))
end

--- A name a certificate can carry: letters, digits, hyphens and dots,
--- with an optional `*.` in front.
local function valid_name(name: string): boolean
  local bare = if name:sub(1, 2) == "*." then name:sub(3) else name end
  if #bare == 0 or #bare > 253 then return false end
  for label in (bare .. "."):gmatch("([^.]*)%.") do
    if #label == 0 or #label > 63 or label:find("^%w[%w%-]*$") == nil or label:sub(-1) == "-" then
      return false
    end
  end
  return true
end

--- The DER certificate signing request (PKCS #10, RFC 2986) for the DNS
--- names `names` under `key`: the first name is the subject's common
--- name when it fits one (64 characters at most), and every name is a
--- subjectAltName, as ACME asks (RFC 8555 section 7.4). Nil and why for
--- no names, or a name that is not dot-separated labels of 1 to 63
--- letters, digits and inner hyphens after an optional `*.`.
---
---     local csr = assert(Acme.csr(Acme.p256_key(Sign.p256_secret()), { "example.com" }))
function Acme.csr(key: Acme.Key, names: {string}): string?, string
  if #names == 0 then return nil, "acme: a certificate request needs a name" end
  local alt: mut {string} = {}
  for i, name in ipairs(names) do
    if not valid_name(name) then return nil, ("acme: %q is not a DNS name"):format(name) end
    alt[i] = der(0x82, name)
  end
  local first = names[1] or ""
  local subject = if #first <= 64
    then der_sequence(der(0x31, der_sequence(der_oid(OID_COMMON_NAME), der(0x0c, first))))
    else der_sequence()
    end
  local extensions = der_sequence(der_sequence(der_oid(OID_SUBJECT_ALT_NAME),
    der(0x04, der(0x30, table.concat(alt)))))
  local attributes = der(0xa0, der_sequence(der_oid(OID_EXTENSION_REQUEST), der(0x31, extensions)))
  local info = der_sequence(der_unsigned("\0"), subject, key.spki, attributes)
  return der_sequence(info, key.signature_algorithm, der_bits(key.x509_sign(info))), ""
end

-- The protocol.

local function field(object: {string: Json.Value}, name: string): string
  local value = object[name]
  if value is string then return value end
  return ""
end

--- The member `name` of `object` as an object, or nil.
local function object_at(object: {string: Json.Value}, name: string): {string: Json.Value}?
  local value = object[name]
  if value == nil then return nil end
  local found, _ = Json.to_object(value)
  return found
end

--- The member `name` of `object` as an array of objects; an item that
--- is no object is left out.
local function objects_at(object: {string: Json.Value}, name: string): {{string: Json.Value}}
  local out: mut {{string: Json.Value}} = {}
  local value = object[name]
  if value == nil then return out end
  local items, _ = Json.to_array(value)
  for _, item in ipairs(items or {}) do
    local found, _ = Json.to_object(item)
    if found ~= nil then out[#out + 1] = found end
  end
  return out
end

--- The member `name` of `object` as an array of strings; an item that
--- is no string is left out.
local function strings(object: {string: Json.Value}, name: string): {string}
  local out: mut {string} = {}
  local value = object[name]
  if value == nil then return out end
  local items, _ = Json.to_array(value)
  for _, item in ipairs(items or {}) do
    if item is string then out[#out + 1] = item end
  end
  return out
end

--- The why of a response that is not what was asked: its problem
--- document's type and detail when it has one, else its status.
local function problem(body: Http.Body, doing: string): string
  local object, _ = Json.decode_object(body.body)
  if object ~= nil and field(object, "type") ~= "" then
    local kind = field(object, "type"):gsub("^urn:ietf:params:acme:error:", "")
    local detail = field(object, "detail")
    return ("acme: %s: %s (HTTP %d): %s"):format(doing, kind, body.status, detail)
  end
  return ("acme: %s: HTTP %d"):format(doing, body.status)
end

local function is_bad_nonce(body: Http.Body): boolean
  if body.status ~= 400 then return false end
  local object, _ = Json.decode_object(body.body)
  return object ~= nil and field(object, "type") == "urn:ietf:params:acme:error:badNonce"
end

--- How long a `Retry-After` header asks to wait, in nanoseconds, or nil
--- for none this reads (a number of seconds).
local function retry_after(body: Http.Body): integer?
  local value = body.headers["retry-after"]
  local seconds = value and math.tointeger(tonumber(value))
  if seconds == nil or seconds < 0 then return nil end
  -- A day bounds what a server can ask, and keeps the product in range.
  return Clock.seconds(math.min(seconds, 86400))
end

--- How long a 429's `Retry-After` asks to wait, in nanoseconds, uncapped
--- (but by what an integer holds): delta-seconds or an HTTP date, a date
--- in the past 0; nil for none, or one that reads as neither.
local function rate_limit_wait(body: Http.Body): integer?
  local text = body.headers["retry-after"]
  if text == nil then return nil end
  local value = text:match("^[ \t]*(.-)[ \t]*$") or ""
  if value:find("^%d+$") ~= nil then
    local digits = value:gsub("^0+(%d)", "%1")
    if #digits > 9 then return math.maxinteger end
    return Clock.seconds(math.tointeger(tonumber(digits)) or 0)
  end
  -- Loaded here alone: cosmic.time brings in cosmic.fs.
  local Time = require("cosmic.time")
  local at, _ = Time.parse_http(value)
  if at == nil then return nil end
  return math.max(at - Clock.now_ns(), 0)
end

--- The shortest wait a 429 counts for, so one asking for none is not sent
--- again without end.
local RATE_WAIT_LEAST <const> = Clock.ms(100)

local function read_order(url: string, object: {string: Json.Value}): Acme.Order
  local names: mut {string} = {}
  for _, identifier in ipairs(objects_at(object, "identifiers")) do
    names[#names + 1] = field(identifier, "value")
  end
  local certificate = field(object, "certificate")
  return {
    url = url,
    status = field(object, "status"),
    names = names,
    authorizations = strings(object, "authorizations"),
    finalize = field(object, "finalize"),
    certificate = if certificate == "" then nil else certificate end,
  }
end

local function read_challenge(thumbprint: string, domain: string, object: {string: Json.Value}): Acme.Challenge
  local token = field(object, "token")
  local problem_object = object_at(object, "error")
  local key_authorization = token .. "." .. thumbprint
  return {
    type = field(object, "type"),
    url = field(object, "url"),
    status = field(object, "status"),
    token = token,
    domain = domain,
    key_authorization = key_authorization,
    path = "/.well-known/acme-challenge/" .. token,
    dns_name = "_acme-challenge." .. domain,
    dns_value = Codec.base64url(Hash.sha256(key_authorization)),
    error = if problem_object ~= nil then field(problem_object, "detail") else "" end,
  }
end

local function read_authorization(thumbprint: string, url: string, object: {string: Json.Value}): Acme.Authorization
  local identifier = object_at(object, "identifier")
  local domain = if identifier ~= nil then field(identifier, "value") else "" end
  local challenges: mut {Acme.Challenge} = {}
  for _, challenge in ipairs(objects_at(object, "challenges")) do
    challenges[#challenges + 1] = read_challenge(thumbprint, domain, challenge)
  end
  return {
    url = url,
    status = field(object, "status"),
    domain = domain,
    wildcard = object["wildcard"] == true,
    challenges = challenges,
  }
end

--- How long one request to the server may take.
local REQUEST_TIMEOUT <const> = Clock.minutes(1)

local function default_request(method: string, url: string, opts: Http.Options): Http.Body?, string
  return Http.request(method, url, opts)
end

--- A session with the ACME server whose directory is `opts.directory`,
--- under the account key `opts.key`. It sends nothing until a method
--- needs it. Raises on a directory that is not a string, or a key that
--- is no [`Acme.Key`].
---
---     local client = Acme.client({ directory = Acme.LETS_ENCRYPT, key = Acme.p256_key(secret) })
function Acme.client(opts: Acme.ClientOptions): Acme.Client
  if type(opts.directory) ~= "string" then
    error("acme: opts.directory is the directory's URL", 2)
  end
  if type(opts.key) ~= "table" or type(opts.key.sign) ~= "function" then
    error("acme: opts.key is an Acme.Key, as Acme.p256_key or Acme.rsa_key makes", 2)
  end
  local key = opts.key
  local request: Acme.Request = opts.request or default_request
  -- In a task of Poll.run the other tasks go on meanwhile.
  local pause_for = opts.pause or function(ns: integer): boolean, string
    if Poll.in_task() then return Poll.delay(ns) end
    return Clock.sleep_ns(ns)
  end
  local thumbprint = Acme.thumbprint(key)
  local rate_limit_most = opts.rate_limit_wait_ns or Clock.minutes(1)
  if math.type(rate_limit_most) ~= "integer" or rate_limit_most < 0 then
    error("acme: opts.rate_limit_wait_ns must be an integer of at least 0", 2)
  end
  local directory: {string: string}? = nil
  local account_url: string? = opts.account
  local nonce: string? = nil

  --- Keeps the nonce a response hands back.
  local function keep(body: Http.Body)
    local fresh = body.headers["replay-nonce"]
    if fresh ~= nil and fresh ~= "" then nonce = fresh end
  end

  local function read_directory(): {string: string}?, string
    local have = directory
    if have ~= nil then return have, "" end
    local body, why = request("GET", opts.directory, { timeout_ns = REQUEST_TIMEOUT })
    if body == nil then return nil, "acme: directory: " .. why end
    if body.status // 100 ~= 2 then return nil, problem(body, "directory") end
    local object, trouble = Json.decode_object(body.body)
    if object == nil then return nil, "acme: directory: " .. trouble end
    local found: mut {string: string} = {}
    for name, value in pairs(object) do
      if value is string then found[name] = value end
    end
    local meta = object_at(object, "meta")
    if meta ~= nil and field(meta, "termsOfService") ~= "" then
      found["terms"] = field(meta, "termsOfService")
    end
    directory = found
    return found, ""
  end

  local function resource(name: string): string?, string
    local found, why = read_directory()
    if found == nil then return nil, why end
    local url = found[name]
    if url == nil then return nil, ("acme: the directory names no %s"):format(name) end
    return url, ""
  end

  local function fresh_nonce(): string?, string
    local have = nonce
    if have ~= nil then
      nonce = nil
      return have, ""
    end
    local url, why = resource("newNonce")
    if url == nil then return nil, why end
    local body, trouble = request("HEAD", url, { timeout_ns = REQUEST_TIMEOUT })
    if body == nil then return nil, "acme: newNonce: " .. trouble end
    local got = body.headers["replay-nonce"]
    if got == nil or got == "" then return nil, "acme: newNonce answered no Replay-Nonce" end
    return got, ""
  end

  --- Sends `payload` (nil for POST-as-GET) to `url` as a JWS signed by
  --- the account key, under its account URL or, with `with_jwk`, its
  --- JWK. A badNonce refusal is sent again once, and a 429 again after
  --- its Retry-After while the 429s' waits stay within
  --- `rate_limit_wait_ns` (each counted as 100 ms at the least).
  local function post(url: string, payload: {string: Json.Value}?, doing: string,
                      with_jwk?: boolean): Http.Body?, string
    local encoded = ""
    if payload ~= nil then
      local text, why = Json.encode(payload)
      if text == nil then return nil, "acme: " .. why end
      encoded = Codec.base64url(text)
    end
    local nonce_retried = false
    local rate_waited = 0
    while true do
      local fresh, why = fresh_nonce()
      if fresh == nil then return nil, why end
      local header: mut {string: Json.Value} = { alg = key.alg, nonce = fresh, url = url }
      if with_jwk == true then
        local jwk: mut {string: Json.Value} = {}
        for name, value in pairs(key.jwk) do jwk[name] = value end
        header["jwk"] = jwk
      else
        local kid = account_url
        if kid == nil then
          return nil, ("acme: %s needs an account first: call client:account()"):format(doing)
        end
        header["kid"] = kid
      end
      local protected = Codec.base64url((assert(Json.encode(header))))
      local signature = Codec.base64url(key.sign(protected .. "." .. encoded))
      local body_text = assert(Json.encode({ protected = protected, payload = encoded, signature = signature }))
      local body, trouble = request("POST", url, {
        timeout_ns = REQUEST_TIMEOUT,
        headers = { ["Content-Type"] = "application/jose+json" },
        body = body_text,
      })
      if body == nil then return nil, ("acme: %s: %s"):format(doing, trouble) end
      keep(body)
      if not nonce_retried and is_bad_nonce(body) then
        nonce_retried = true
      elseif body.status == 429 then
        local asked = rate_limit_wait(body)
        local wait = if asked ~= nil then math.max(asked, RATE_WAIT_LEAST) else nil end
        if wait == nil or wait > rate_limit_most - rate_waited then
          local said = if asked ~= nil then (" (it asks for %d s)"):format((asked + Clock.seconds(1) - 1) // Clock.seconds(1)) else "" end
          return nil, problem(body, doing) .. said
        end
        rate_waited = rate_waited + wait
        local paused, interrupted = pause_for(wait)
        if not paused then return nil, ("acme: %s: %s"):format(doing, interrupted) end
      else
        return body, ""
      end
    end
  end

  --- `post`, then the response's JSON object, when its status is 2xx.
  local function post_object(url: string, payload: {string: Json.Value}?, doing: string,
                             with_jwk?: boolean): {string: Json.Value}?, Http.Body?, string
    local body, why = post(url, payload, doing, with_jwk)
    if body == nil then return nil, nil, why end
    if body.status // 100 ~= 2 then return nil, nil, problem(body, doing) end
    local object, trouble = Json.decode_object(body.body)
    if object == nil then return nil, nil, ("acme: %s: %s"):format(doing, trouble) end
    return object, body, ""
  end

  local client: Acme.Client = {
    thumbprint = thumbprint,

    directory = function(_self: Acme.Client): {string: string}?, string
      return read_directory()
    end,

    account = function(_self: Acme.Client, account_opts?: Acme.AccountOptions): string?, string
      local have = account_url
      if have ~= nil then return have, "" end
      local url, why = resource("newAccount")
      if url == nil then return nil, why end
      local o = account_opts or {}
      local payload: mut {string: Json.Value} = {}
      local contact = o.contact
      if contact ~= nil then
        local listed: mut {Json.Value} = {}
        for i, address in ipairs(contact) do listed[i] = address end
        payload["contact"] = Json.array(listed)
      end
      if o.terms_agreed == true then payload["termsOfServiceAgreed"] = true end
      if o.only_existing == true then payload["onlyReturnExisting"] = true end
      local body, trouble = post(url, payload, "newAccount", true)
      if body == nil then return nil, trouble end
      if body.status // 100 ~= 2 then return nil, problem(body, "newAccount") end
      local location = body.headers["location"]
      if location == nil or location == "" then
        return nil, "acme: newAccount answered no Location"
      end
      account_url = location
      return location, ""
    end,

    order = function(_self: Acme.Client, names: {string}): Acme.Order?, string
      if #names == 0 then return nil, "acme: an order needs a name" end
      local identifiers: mut {Json.Value} = {}
      for i, name in ipairs(names) do
        if not valid_name(name) then return nil, ("acme: %q is not a DNS name"):format(name) end
        identifiers[i] = { type = "dns", value = name }
      end
      local url, why = resource("newOrder")
      if url == nil then return nil, why end
      local object, body, trouble = post_object(url, { identifiers = identifiers }, "newOrder")
      if object == nil or body == nil then return nil, trouble end
      local location = body.headers["location"]
      if location == nil or location == "" then
        return nil, "acme: newOrder answered no Location"
      end
      return read_order(location, object), ""
    end,

    get_order = function(_self: Acme.Client, url: string): Acme.Order?, string
      local object, _, why = post_object(url, nil, "order")
      if object == nil then return nil, why end
      return read_order(url, object), ""
    end,

    authorization = function(_self: Acme.Client, url: string): Acme.Authorization?, string
      local object, _, why = post_object(url, nil, "authorization")
      if object == nil then return nil, why end
      return read_authorization(thumbprint, url, object), ""
    end,

    respond = function(_self: Acme.Client, challenge: Acme.Challenge): boolean, string
      local object, _, why = post_object(challenge.url, {}, "challenge")
      if object == nil then return false, why end
      return true, ""
    end,

    wait = function(_self: Acme.Client, url: string, wait_opts?: Acme.WaitOptions): string?, string
      local w = wait_opts or opts.wait or {}
      local timeout = w.timeout_ns or Clock.minutes(2)
      local interval = w.interval_ns or Clock.seconds(2)
      local started = Clock.monotonic_ns()
      while true do
        local object, body, why = post_object(url, nil, "poll")
        if object == nil or body == nil then return nil, why end
        local status = field(object, "status")
        if status ~= "pending" and status ~= "processing" then return status, "" end
        local left = timeout - (Clock.monotonic_ns() - started)
        if left <= 0 then
          return nil, ("acme: %s is still %s after the wait"):format(url, status)
        end
        -- A Retry-After of 0 would poll without a pause.
        local pause = math.min(math.max(retry_after(body) or interval, Clock.ms(100)), left)
        local slept, trouble = pause_for(pause)
        if not slept then return nil, "acme: poll: " .. trouble end
      end
    end,

    finalize = function(_self: Acme.Client, order: Acme.Order, csr: string): Acme.Order?, string
      local object, _, why = post_object(order.finalize, { csr = Codec.base64url(csr) }, "finalize")
      if object == nil then return nil, why end
      return read_order(order.url, object), ""
    end,

    certificate = function(_self: Acme.Client, url: string): string?, string
      local body, why = post(url, nil, "certificate")
      if body == nil then return nil, why end
      if body.status // 100 ~= 2 then return nil, problem(body, "certificate") end
      if body.body:find("-----BEGIN CERTIFICATE-----", 1, true) == nil then
        return nil, "acme: certificate: the server sent no PEM certificate"
      end
      return body.body, ""
    end,

    issue = function(self: Acme.Client, names: {string}, issue_opts: Acme.IssueOptions): string?, string
      local kind = issue_opts.challenge or "http-01"
      local csr, bad = Acme.csr(issue_opts.key, names)
      if csr == nil then return nil, bad end
      if issue_opts.key.spki == key.spki then
        return nil, "acme: the certificate's key is the account's; use another"
      end
      local _, why = self:account()
      if why ~= "" then return nil, why end
      local order, trouble = self:order(names)
      if order == nil then return nil, trouble end
      for _, url in ipairs(order.authorizations) do
        local authorization, failed = self:authorization(url)
        if authorization == nil then return nil, failed end
        if authorization.status ~= "valid" and authorization.status ~= "pending" then
          return nil, ("acme: the authorization of %s is %s"):format(authorization.domain, authorization.status)
        end
        if authorization.status == "pending" then
          local chosen: Acme.Challenge? = nil
          for _, challenge in ipairs(authorization.challenges) do
            if challenge.type == kind then chosen = challenge end
          end
          if chosen == nil then
            return nil, ("acme: the server offers no %s challenge for %s"):format(kind, authorization.domain)
          end
          -- RFC 8555 section 8.1 holds a token to base64url; any other
          -- byte would reach the caller's path or record name.
          if chosen.token:find("^[%w_%-]+$") == nil then
            return nil, ("acme: the server's token for %s is not base64url"):format(authorization.domain)
          end
          local presented, refused = issue_opts.present(chosen)
          if not presented then return nil, "acme: present: " .. refused end
          local responded, problem_text = self:respond(chosen)
          local status: string? = nil
          local waited = problem_text
          if responded then status, waited = self:wait(url) end
          if issue_opts.cleanup ~= nil then issue_opts.cleanup(chosen) end
          if status == nil then return nil, waited end
          if status ~= "valid" then
            local settled, _ = self:authorization(url)
            local detail = ""
            if settled ~= nil then
              for _, challenge in ipairs(settled.challenges) do
                if challenge.type == kind then
                  detail = if challenge.error ~= "" then challenge.error else challenge.status end
                end
              end
            end
            return nil, ("acme: the authorization of %s is %s%s"):format(authorization.domain, status,
              if detail ~= "" then " (" .. detail .. ")" else "" end)
          end
        end
      end
      local ready, not_ready = self:wait(order.url)
      if ready == nil then return nil, not_ready end
      if ready ~= "ready" and ready ~= "valid" then
        return nil, ("acme: the order is %s"):format(ready)
      end
      -- An order already valid (an earlier issue finalized it) is not
      -- finalized again: the server would refuse it as not ready.
      local settled = order
      if ready == "ready" then
        local finalized, refused = self:finalize(order, csr)
        if finalized == nil then return nil, refused end
        settled = finalized
        if finalized.status ~= "valid" then
          local status, slow = self:wait(order.url)
          if status == nil then return nil, slow end
          if status ~= "valid" then
            return nil, ("acme: the finalized order is %s"):format(status)
          end
        end
      end
      if settled.certificate == nil then
        local read, lost = self:get_order(order.url)
        if read == nil then return nil, lost end
        settled = read
      end
      local certificate = settled.certificate
      if certificate == nil then return nil, "acme: the valid order names no certificate" end
      return self:certificate(certificate)
    end,
  }
  return client
end

--- Mode 0700, for a directory only its owner enters.
local OWNER_DIR <const> = 0x1c0
--- Mode 0600, for a file only its owner reads.
local OWNER_FILE <const> = 0x180

--- The certificate's chain and key out of the one file `text` keeps
--- them in, the chain first.
local function pair_in(text: string): Tls.Pair?
  local key_at = text:find("-----BEGIN [%u ]*PRIVATE KEY-----")
  if key_at == nil or key_at == 1 then return nil end
  return { cert = text:sub(1, key_at - 1), key = text:sub(key_at) }
end

--- Whether the leaf of `pair` names each of `names` and stays valid
--- `min_validity_ns` more (a minute when nil).
local function fresh(pair: Tls.Pair, names: {string}, min_validity_ns?: integer): boolean
  local leaf, _ = Tls.leaf(pair.cert)
  if leaf == nil then return false end
  local named: mut {string: boolean} = {}
  for _, name in ipairs(leaf.names) do named[name:lower()] = true end
  for _, name in ipairs(names) do
    if named[name:lower()] ~= true then return false end
  end
  return leaf.not_after_ns - Clock.now_ns() >= (min_validity_ns or Clock.minutes(1))
end

--- The account key kept at `path`, made and written there (mode 0600)
--- where there is none.
local function account_key(path: string): Acme.Key?, string
  local there, why = Fs.exists(path)
  if there == nil then return nil, "acme: " .. why end
  if there then
    local text, unread = Fs.read(path)
    if text == nil then return nil, "acme: " .. unread end
    local key, bad = Acme.read_key(text)
    if key == nil then return nil, "acme: " .. path .. ": " .. bad end
    return key, ""
  end
  local key = Acme.p256_key(Sign.p256_secret())
  local wrote, unwritten = Fs.write(path, assert(key.pem), OWNER_FILE)
  if not wrote then return nil, "acme: " .. unwritten end
  return key, ""
end

--- The host of a Host header, its port and an IPv6 address's brackets
--- kept; nil for none, or one with a byte no host has.
local function host_of(header?: string): string?
  if header == nil then return nil end
  local host = header:match("^(%[[%x:.]+%])") or header:match("^([%w.-]+)")
  if host == nil then return nil end
  local rest = header:sub(#host + 1)
  if rest ~= "" and rest:match("^:%d+$") == nil then return nil end
  return host
end

--- A certificate for `opts.names` from an ACME CA, kept in `opts.dir`
--- and renewed, for a server: its `certs` is the server's `tls`, and
--- its `handler` answers the CA's http-01 check on the server's
--- `clear` listener, which is port 80 for a public CA.
---
---     local auto = Acme.auto({ names = { "example.com" }, dir = "/var/lib/app/acme",
---       terms_agreed = true, contact = { "mailto:ops@example.com" } })
---     assert(Server.serve{
---       listeners = { Net.tcp("0.0.0.0", 443) }, clear = { Net.tcp("0.0.0.0", 80) },
---       tls = auto.certs, handle = auto:handler(app),
---     })
---
--- The server listens before it first loads the certificate, and its
--- `clear` listener serves the check while the CA makes it, so a first
--- start with an empty `dir` issues one in place. A certificate is
--- renewed a third of its life before it expires, as [`cosmic.tls`]
--- says. A restart takes the certificate in `dir` where it names
--- every one of `names`; a change of `names` issues another. One
--- process at a time uses a `dir`. Raises on options out of shape.
function Acme.auto(opts: Acme.AutoOptions): Acme.Auto
  if type(opts.names) ~= "table" or #opts.names == 0 then
    error("acme: auto's opts.names is a list of one DNS name or more", 2)
  end
  if type(opts.dir) ~= "string" or opts.dir == "" then
    error("acme: auto's opts.dir is the directory to keep the certificate in", 2)
  end
  if opts.key ~= nil and opts.key.pem == nil then
    error("acme: auto's opts.key needs its pem, as Acme.read_key and Acme.p256_key make it", 2)
  end
  local names: {string} = { table.unpack(opts.names) }
  local dir = opts.dir
  local pending: mut {string: string} = {}
  local client: Acme.Client? = nil
  local dns = opts.dns

  local function issued(): Tls.Pair?, string
    local made, unmade = Fs.mkdirs(dir, OWNER_DIR)
    if not made then return nil, "acme: " .. unmade end
    local session = client
    if session == nil then
      local key, why = account_key(dir .. "/account.pem")
      if key == nil then return nil, why end
      session = Acme.client({
        directory = opts.directory or Acme.LETS_ENCRYPT, key = key,
        request = opts.request, pause = opts.pause, wait = opts.wait,
        rate_limit_wait_ns = opts.rate_limit_wait_ns,
      })
      client = session
    end
    local account, refused = session:account({ contact = opts.contact, terms_agreed = opts.terms_agreed })
    if account == nil then return nil, refused end
    local key = opts.key or Acme.p256_key(Sign.p256_secret())
    local chain, why = session:issue(names, {
      key = key,
      challenge = if dns ~= nil then "dns-01" else "http-01" end,
      present = function(c: Acme.Challenge): boolean, string
        if dns ~= nil then return dns.present(c) end
        pending[c.path] = c.key_authorization
        return true, ""
      end,
      cleanup = function(c: Acme.Challenge)
        if dns ~= nil then
          local cleanup = dns.cleanup
          if cleanup ~= nil then cleanup(c) end
          return
        end
        pending[c.path] = nil
      end,
    })
    if chain == nil then return nil, why end
    local pair: Tls.Pair = { cert = chain, key = assert(key.pem) }
    -- One file, written whole, so a reader never sees a chain with
    -- another's key.
    local wrote, unwritten = Fs.write(dir .. "/certificate.pem", chain .. pair.key, OWNER_FILE)
    if not wrote then return nil, "acme: " .. unwritten end
    return pair, ""
  end

  local function source(min_validity_ns?: integer): {Tls.Pair}?, string
    local text, _ = Fs.read(dir .. "/certificate.pem")
    if text ~= nil then
      local kept = pair_in(text)
      -- Loaded on its own first, so a key that is not the chain's, or
      -- one that cannot be read, is issued again rather than refused.
      if kept ~= nil and fresh(kept, names, min_validity_ns) then
        local usable, _ = Tls.certs(Tls.static({ kept })):load()
        if usable then return { kept }, "" end
      end
    end
    local pair, why = issued()
    if pair == nil then return nil, why end
    return { pair }, ""
  end

  local auto: Acme.Auto = {
    certs = Tls.certs(source),
    answer = function(_self: Acme.Auto, path: string): string?
      return pending[path]
    end,
    handler = function(self: Acme.Auto, after?: function(req: Server.Request): Server.Reply): function(req: Server.Request): Server.Reply
      return function(req: Server.Request): Server.Reply
        if req.tls == nil then
          local answer = self:answer(req.path)
          if answer ~= nil then
            return { status = 200, headers = { ["Content-Type"] = "text/plain" }, body = answer }
          end
          -- The HTTPS port is 443 whatever port this request came to.
          local host = host_of(req.headers["host"])
          if host == nil or req.path:sub(1, 1) ~= "/" then
            return { status = 400, body = "no host and path to redirect to\n" }
          end
          local query = if req.query ~= "" then "?" .. req.query else "" end
          return { status = 308, headers = { Location = "https://" .. host .. req.path .. query } }
        end
        if after ~= nil then return after(req) end
        return { status = 404 }
      end
    end,
  }
  return auto
end

return Acme
