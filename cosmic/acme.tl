--- An ACME client (RFC 8555): it asks a certificate authority such as
--- Let's Encrypt for a certificate, proving control of each name by a
--- challenge, and returns the certificate chain as PEM.
---
---     local Failure = require("cosmic.failure")
---     local served: {string: string} = {} -- what a web server on port 80 serves
---     local account = Key.generate("p256")
---     local client = Acme.client({ directory = Acme.LETS_ENCRYPT_STAGING, key = account })
---     assert(client:account({ contact = { "mailto:ops@example.com" }, terms_agreed = true }))
---     local chain = assert(client:issue({ "example.com", "www.example.com" }, {
---       key = Key.generate("p256"),
---       challenge = "http-01",
---       present = function(c: Acme.Challenge): (true) | (nil, Failure)
---         served[c.path] = c.key_authorization
---         return true
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
--- An account key and a certificate key are each a [`Key.Secret`] of
--- [`cosmic.key`], P-256 or RSA: RSA for a server or a client of the
--- certificate that takes RSA alone. Let's Encrypt takes no Ed25519
--- key, so none is taken here. Keep the account key's secret: the
--- account is that key, and a lost one means a new account. Use another
--- key for the certificate. A key's `pem` is its secret as a web server
--- reads one, and [`Key.read`] reads it back, or a key OpenSSL wrote.
---
--- Every fallible function returns a value or `nil` and a `Failure`,
--- whose text opens `acme: `. A problem document the server sends (RFC 8555
--- section 6.7) is named in the why by its type and detail. A request
--- the server refuses for a stale nonce (`badNonce`) is sent again once
--- with the fresh nonce it handed back, as section 6.5 asks.
---
--- Every URL the client sends to, the directory's and each one the
--- server names, is https, and no redirect is followed.
--- [`Acme.Client.issue`] refuses an authorization of a name it did not
--- ask for, and a chain whose leaf does not certify the certificate's
--- key for exactly the names asked for.

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
local Failure = require("cosmic.failure")
local Codec = require("cosmic.codec")
local Der = require("cosmic.internal.der")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Key = require("cosmic.key")
local String = require("cosmic.string")
local Fs = require("cosmic.fs")
local Tls = require("cosmic.tls")
local sys = require("cosmic.sys")
-- Only the types: a handler is a function and a reply a table, so a
-- program that issues alone does not load the server.
local type Server = require("cosmic.http.server")

local record Acme
  --- The kinds of challenge [`Acme.Client.issue`] can complete.
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
    --- The server's token for the challenge: base64url, as RFC 8555
    --- section 8.1 holds it to. A challenge with any other token is
    --- refused where it is read, so `path` and `dns_name` hold no other
    --- byte.
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
    --- The identifier's value, a DNS name, with no `*.`. An
    --- authorization for an identifier of another type, or a value that
    --- is no DNS name, is refused where it is read.
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
    key: Key.Secret
    --- The challenge type to complete, "http-01" when nil.
    challenge?: ChallengeType
    --- Publishes a challenge's response before the server checks it:
    --- true, or nil and why, which stops the issue. The server checks
    --- as soon as this returns, so it returns only once the response is
    --- reachable: a dns-01 record has spread to the zone's servers.
    present: function(challenge: Challenge): (true) | (nil, Failure)
    --- Withdraws what `present` published, once the authorization is
    --- settled either way. Whether it worked is not checked.
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
  type Request = function(method: string, url: string, opts: Http.RequestOptions): Http.Body?, string

  --- What [`Acme.client`] takes.
  record ClientOptions
    --- The directory URL, such as [`Acme.LETS_ENCRYPT`].
    directory: string
    --- The account's key.
    key: Key.Secret
    --- The account's URL, when it is already known: it skips the
    --- lookup [`Acme.Client.account`] does.
    account?: string
    --- Sends a request: [`Http.request`] when nil. A test hands its own.
    request?: Request
    --- Pauses between polls, for nanoseconds: [`Clock.sleep`] when
    --- nil. A test hands one that returns at once.
    pause?: function(ns: integer): (true) | (nil, Failure)
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
    --- `challenge.dns_value` in the zone. Returns true only once the
    --- zone's servers respond with it, or nil and why, which stops the
    --- issue.
    present: function(challenge: Challenge): (true) | (nil, Failure)
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
    --- [`Key.read`] or [`Key.generate`] made. A new P-256 key for each
    --- certificate when nil.
    key?: Key.Secret
    --- Hooks that complete dns-01 in place of http-01.
    dns?: DnsHooks
    --- As [`Acme.ClientOptions.request`].
    request?: Request
    --- As [`Acme.ClientOptions.pause`].
    pause?: function(ns: integer): (true) | (nil, Failure)
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
    --- A handler for a server's `handle` that handles the http-01 checks
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
    directory: function(self: Client): ({string: string}) | (nil, Failure)
    --- The account's URL, created (or, with `only_existing`, found)
    --- under the client's key, and kept for every later request. For a
    --- key with an account already, it returns that account.
    account: function(self: Client, opts?: AccountOptions): (string) | (nil, Failure)
    --- A new order for the DNS names `names`.
    order: function(self: Client, names: {string}): (Order) | (nil, Failure)
    --- The order at `url`, read again.
    get_order: function(self: Client, url: string): (Order) | (nil, Failure)
    --- The authorization at `url`.
    authorization: function(self: Client, url: string): (Authorization) | (nil, Failure)
    --- Tells the server to check the challenge: true, or nil and why.
    respond: function(self: Client, challenge: Challenge): (true) | (nil, Failure)
    --- Polls the order or authorization at `url` until its status is
    --- not "pending" or "processing", and returns that status. Nil and
    --- why when the time runs out.
    wait: function(self: Client, url: string, opts?: WaitOptions): (string) | (nil, Failure)
    --- Sends the DER certificate signing request `csr` to the order's
    --- `finalize` URL, and returns the order as it stands after.
    finalize: function(self: Client, order: Order, csr: string): (Order) | (nil, Failure)
    --- The certificate chain at `url`, as PEM.
    certificate: function(self: Client, url: string): (string) | (nil, Failure)
    --- A certificate for the DNS names `names` under `opts.key`: the
    --- whole flow, as the module's doc says. Returns the chain as PEM,
    --- once its leaf is found to certify `opts.key` for exactly `names`.
    issue: function(self: Client, names: {string}, opts: IssueOptions): (string) | (nil, Failure)
  end
end

Acme.LETS_ENCRYPT = "https://acme-v02.api.letsencrypt.org/directory"
Acme.LETS_ENCRYPT_STAGING = "https://acme-staging-v02.api.letsencrypt.org/directory"

local der, der_sequence, der_unsigned, der_oid, der_bits = Der.element, Der.sequence, Der.unsigned, Der.oid, Der.bits
local der_elements, der_sequence_of = Der.elements, Der.sequence_of
local DER_NULL <const> = Der.NULL

local OID_ECDSA_SHA256 <const> = "1.2.840.10045.4.3.2"
local OID_RSA_SHA256 <const> = "1.2.840.113549.1.1.11"
local OID_COMMON_NAME <const> = "2.5.4.3"
local OID_EXTENSION_REQUEST <const> = "1.2.840.113549.1.9.14"
local OID_SUBJECT_ALT_NAME <const> = "2.5.29.17"

--- The JWS algorithm of a key of each algorithm ACME servers take: an
--- Ed25519 key is none of them.
local JWS_ALGS <const>: {string: string} = { p256 = "ES256", rsa = "RS256" }

--- The DER AlgorithmIdentifier of the X.509 signature `key` makes:
--- ecdsa-with-SHA256 for P-256, sha256WithRSAEncryption for RSA.
local function x509_algorithm(key: Key.Secret): string
  if key.alg == "p256" then return der_sequence(der_oid(OID_ECDSA_SHA256)) end
  return der_sequence(der_oid(OID_RSA_SHA256), DER_NULL)
end

--- The X.509 signature of `message` under `key`: for ECDSA, the DER
--- SEQUENCE of R and S; for RSA, the PKCS #1 v1.5 signature as it is.
local function x509_sign(key: Key.Secret, message: string): string
  local signature = key:sign(message)
  if key.alg ~= "p256" then return signature end
  return der_sequence(der_unsigned(signature:sub(1, 32)), der_unsigned(signature:sub(33, 64)))
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
--- no names, a key that is neither P-256 nor RSA, or a name that is not
--- dot-separated labels of 1 to 63 letters, digits and inner hyphens
--- after an optional `*.`.
---
---     local csr = assert(Acme.csr(Key.generate("p256"), { "example.com" }))
function Acme.csr(key: Key.Secret, names: {string}): (string) | (nil, Failure)
  if JWS_ALGS[key.alg] == nil then
    return nil, Failure.new(("acme: a certificate's key is P-256 or RSA, not %s: CAs issue no other"):format(key.alg))
  end
  if #names == 0 then return nil, Failure.new("acme: a certificate request needs a name") end
  local alt: mut {string} = {}
  for i, name in ipairs(names) do
    if not valid_name(name) then
      return nil, Failure.new(("acme: %q is not a DNS name"):format(name))
    end
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
  local info = der_sequence(der_unsigned("\0"), subject, key.public:spki(), attributes)
  return der_sequence(info, x509_algorithm(key), der_bits(x509_sign(key, info)))
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
local function problem(body: Http.Body, doing: string): Failure
  local object, _ = Json.decode_object(body.body)
  if object ~= nil and field(object, "type") ~= "" then
    local kind = field(object, "type"):gsub("^urn:ietf:params:acme:error:", "")
    local detail = field(object, "detail")
    return Failure.new(("acme: %s: %s (HTTP %d): %s"):format(doing, kind, body.status, detail))
  end
  return Failure.new(("acme: %s: HTTP %d"):format(doing, body.status))
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
  local value = String.trim(text)
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

--- The challenge `object` of an authorization of `domain`, or nil and
--- why its token is not base64url.
local function read_challenge(thumbprint: string, domain: string,
                              object: {string: Json.Value}): (Acme.Challenge) | (nil, Failure)
  local token = field(object, "token")
  -- RFC 8555 section 8.1 holds a token to base64url; any other byte
  -- would reach a caller's path or record name.
  if token:find("^[%w_%-]+$") == nil then
    return nil, Failure.new(("acme: the server's token for %s is not base64url"):format(domain))
  end
  local problem_object = object_at(object, "error")
  local key_authorization = token .. "." .. thumbprint
  local challenge: Acme.Challenge = {
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
  return challenge
end

--- The authorization `object` read from `url`, or nil and why its
--- identifier is not a DNS name (RFC 8555 section 7.1.4: of type "dns",
--- a wildcard's with no `*.`) or a challenge's token is not base64url.
local function read_authorization(thumbprint: string, url: string,
                                  object: {string: Json.Value}): (Acme.Authorization) | (nil, Failure)
  local identifier = object_at(object, "identifier")
  local kind = if identifier ~= nil then field(identifier, "type") else "" end
  local domain = if identifier ~= nil then field(identifier, "value") else "" end
  if kind ~= "dns" or domain:sub(1, 2) == "*." or not valid_name(domain) then
    return nil, Failure.new(("acme: the authorization at %s is not for a DNS name"):format(url))
  end
  local challenges: mut {Acme.Challenge} = {}
  for _, challenge in ipairs(objects_at(object, "challenges")) do
    local read, why = read_challenge(thumbprint, domain, challenge)
    if read == nil then return nil, why end
    challenges[#challenges + 1] = read
  end
  local authorization: Acme.Authorization = {
    url = url,
    status = field(object, "status"),
    domain = domain,
    wildcard = object["wildcard"] == true,
    challenges = challenges,
  }
  return authorization
end

--- Whether `url` is an https URL with a host. Every URL the client
--- sends to is one, so a request and its JWS never go in the clear.
local function is_https(url: string): boolean
  return url:sub(1, 8):lower() == "https://" and url:find("^[^/?#]", 9) ~= nil
end

--- `text`, which the server sent, quoted for a why of one line.
local function quoted(text: string): string
  -- Bounded too: a server's string can be of any length.
  local cut = if #text > 200 then text:sub(1, 200) .. "..." else text end
  return (("%q"):format(cut):gsub("\\\n", "\\n"))
end

--- The why of a request to `url` refused for not being https.
local function not_https(doing: string, url: string): Failure
  return Failure.new(("acme: %s: %s is not an https URL"):format(doing, quoted(url)))
end

--- What [`leaf_of`] reads of a certificate.
local record Leaf
  --- Its subject alternative names, each a DNS name.
  names: {string}
  --- The DER SubjectPublicKeyInfo it certifies.
  spki: string
end

--- What the first certificate of the PEM `chain` certifies (RFC 5280
--- section 4.1); nil and why where it cannot be read, or where a
--- subject alternative name is of another kind than a DNS name.
local function leaf_of(chain: string): (Leaf) | (nil, Failure)
  local body = chain:match("%-%-%-%-%-BEGIN CERTIFICATE%-%-%-%-%-(.-)%-%-%-%-%-END CERTIFICATE%-%-%-%-%-")
  if body == nil then return nil, Failure.new("acme: the issued certificate cannot be read") end
  local der_bytes, _ = Codec.unbase64((body:gsub("%s", "")))
  local parts = if der_bytes == nil then nil else der_sequence_of(der_bytes) end
  local tbs = if parts == nil then nil else parts[1] end
  local fields = if tbs == nil or tbs.tag ~= 0x30 then nil else der_elements(tbs.content) end
  local first = if fields == nil then nil else fields[1] end
  if fields == nil or first == nil then
    return nil, Failure.new("acme: the issued certificate cannot be read")
  end
  -- The version, [0], is there in a v3 certificate alone; the public key
  -- follows the serial, signature, issuer, validity and subject.
  local at = if first.tag == 0xa0 then 7 else 6 end
  local spki = fields[at]
  if spki == nil or spki.tag ~= 0x30 then
    return nil, Failure.new("acme: the issued certificate names no public key")
  end
  local names: mut {string} = {}
  for i = at + 1, #fields do
    local extensions = assert(fields[i])
    local listed = if extensions.tag == 0xa3 then der_elements(extensions.content) else nil end
    local sequence = if listed == nil then nil else listed[1] end
    local none: {Der.Element} = {}
    local each = if sequence == nil then none else der_elements(sequence.content) or none end
    for _, extension in ipairs(each) do
      local members = der_elements(extension.content) or {}
      local oid, value = members[1], members[#members]
      if oid ~= nil and value ~= nil and value.tag == 0x04 and
          der(oid.tag, oid.content) == der_oid(OID_SUBJECT_ALT_NAME) then
        local general = der_sequence_of(value.content)
        if general == nil then
          return nil, Failure.new("acme: the issued certificate's names cannot be read")
        end
        for _, name in ipairs(general) do
          if name.tag ~= 0x82 then
            return nil, Failure.new("acme: the issued certificate names more than DNS names")
          end
          names[#names + 1] = name.content
        end
      end
    end
  end
  local leaf: Leaf = { names = names, spki = der(spki.tag, spki.content) }
  return leaf
end

--- Whether the leaf of the PEM `chain` certifies `key` for exactly the
--- DNS names `names`: true, or nil and why.
local function leaf_matches(chain: string, key: Key.Secret, names: {string}): (true) | (nil, Failure)
  local leaf, why = leaf_of(chain)
  if leaf == nil then return nil, why end
  if leaf.spki ~= key.public:spki() then
    return nil, Failure.new("acme: the issued certificate is not for the certificate's key")
  end
  local function set_of(list: {string}): {string}
    local seen: mut {string: boolean} = {}
    local out: mut {string} = {}
    for _, name in ipairs(list) do
      local lower = name:lower()
      if seen[lower] ~= true then
        seen[lower] = true
        out[#out + 1] = lower
      end
    end
    table.sort(out)
    return out
  end
  local got, asked = table.concat(set_of(leaf.names), " "), table.concat(set_of(names), " ")
  if got ~= asked then
    return nil, Failure.new(("acme: the issued certificate names %s, not the names asked for, %s"):format(quoted(got),
      quoted(asked)))
  end
  return true
end

--- How long one request to the server may take.
local REQUEST_TIMEOUT <const> = Clock.minutes(1)

local function default_request(method: string, url: string, opts: Http.RequestOptions): Http.Body?, string
  local body, why = Http.request(method, url, opts)
  if body == nil then return nil, tostring(why) end
  return body, ""
end

--- A session with the ACME server whose directory is `opts.directory`,
--- under the account key `opts.key`. It sends nothing until a method
--- needs it. Raises on a directory that is not a string, or a key that
--- is no P-256 or RSA [`Key.Secret`].
---
---     local client = Acme.client({ directory = Acme.LETS_ENCRYPT, key = Key.generate("p256") })
function Acme.client(opts: Acme.ClientOptions): Acme.Client
  if type(opts.directory) ~= "string" then
    error("acme: opts.directory is the directory's URL", 2)
  end
  local key = opts.key
  local jws_alg = JWS_ALGS[key.alg]
  if jws_alg == nil then
    error(("acme: opts.key is a P-256 or RSA key, not %s: Let's Encrypt takes no other"):format(key.alg), 2)
  end
  local request: Acme.Request = opts.request or default_request
  -- In a task of Poll.run the other tasks go on meanwhile.
  local pause_for = opts.pause or function(ns: integer): (true) | (nil, Failure)
    local paused, why = Clock.sleep(ns)
    if not paused then return nil, why end
    return true
  end
  local thumbprint = key.public:thumbprint()
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

  local function read_directory(): ({string: string}) | (nil, Failure)
    local have = directory
    if have ~= nil then return have end
    if not is_https(opts.directory) then return nil, not_https("directory", opts.directory) end
    -- No redirect is followed, here or anywhere: it could lead off https.
    local body, why = request("GET", opts.directory, { timeout_ns = REQUEST_TIMEOUT, follow = false })
    if body == nil then return nil, Failure.new("acme: directory: " .. why) end
    if body.status // 100 ~= 2 then return nil, problem(body, "directory") end
    local object, trouble = Json.decode_object(body.body)
    if object == nil then return nil, Failure.within(trouble, "acme: directory") end
    local found: mut {string: string} = {}
    for name, value in pairs(object) do
      if value is string then found[name] = value end
    end
    local meta = object_at(object, "meta")
    if meta ~= nil and field(meta, "termsOfService") ~= "" then
      found["terms"] = field(meta, "termsOfService")
    end
    directory = found
    return found
  end

  local function resource(name: string): (string) | (nil, Failure)
    local found, why = read_directory()
    if found == nil then return nil, why end
    local url = found[name]
    if url == nil then return nil, Failure.new(("acme: the directory names no %s"):format(name)) end
    if not is_https(url) then return nil, not_https(name, url) end
    return url
  end

  local function fresh_nonce(): (string) | (nil, Failure)
    local have = nonce
    if have ~= nil then
      nonce = nil
      return have
    end
    local url, why = resource("newNonce")
    if url == nil then return nil, why end
    local body, trouble = request("HEAD", url, { timeout_ns = REQUEST_TIMEOUT, follow = false })
    if body == nil then return nil, Failure.new("acme: newNonce: " .. trouble) end
    local got = body.headers["replay-nonce"]
    if got == nil or got == "" then
      return nil, Failure.new("acme: newNonce answered no Replay-Nonce")
    end
    return got
  end

  --- Sends `payload` (nil for POST-as-GET) to `url` as a JWS signed by
  --- the account key, under its account URL or, with `with_jwk`, its
  --- JWK. A badNonce refusal is sent again once, and a 429 again after
  --- its Retry-After while the 429s' waits stay within
  --- `rate_limit_wait_ns` (each counted as 100 ms at the least).
  local function post(url: string, payload: {string: Json.Value}?, doing: string,
                      with_jwk?: boolean): (Http.Body) | (nil, Failure)
    if not is_https(url) then return nil, not_https(doing, url) end
    local encoded = ""
    if payload ~= nil then
      local text, why = Json.encode(payload)
      if text == nil then return nil, Failure.within(why, "acme") end
      encoded = Codec.base64url(text)
    end
    local nonce_retried = false
    local rate_waited = 0
    while true do
      local fresh, why = fresh_nonce()
      if fresh == nil then return nil, why end
      local header: mut {string: Json.Value} = { alg = jws_alg, nonce = fresh, url = url }
      if with_jwk == true then
        local jwk: mut {string: Json.Value} = {}
        for name, value in pairs(key.public:jwk()) do jwk[name] = value end
        header["jwk"] = jwk
      else
        local kid = account_url
        if kid == nil then
          return nil, Failure.new(("acme: %s needs an account first: call client:account()"):format(doing))
        end
        header["kid"] = kid
      end
      local protected = Codec.base64url((assert(Json.encode(header))))
      local signature = Codec.base64url(key:sign(protected .. "." .. encoded))
      local body_text = assert(Json.encode({ protected = protected, payload = encoded, signature = signature }))
      local body, trouble = request("POST", url, {
        timeout_ns = REQUEST_TIMEOUT,
        follow = false,
        headers = { ["Content-Type"] = "application/jose+json" },
        body = body_text,
      })
      if body == nil then return nil, Failure.new(("acme: %s: %s"):format(doing, trouble)) end
      keep(body)
      if not nonce_retried and is_bad_nonce(body) then
        nonce_retried = true
      elseif body.status == 429 then
        local asked = rate_limit_wait(body)
        local wait = if asked ~= nil then math.max(asked, RATE_WAIT_LEAST) else nil end
        if wait == nil or wait > rate_limit_most - rate_waited then
          local said = if asked ~= nil then (" (it asks for %d s)"):format((asked + Clock.seconds(1) - 1) // Clock.seconds(1)) else "" end
          return nil, Failure.new(tostring(problem(body, doing)) .. said)
        end
        rate_waited = rate_waited + wait
        local paused, interrupted = pause_for(wait)
        if not paused then return nil, Failure.within(interrupted, "acme: " .. doing) end
      else
        return body
      end
    end
  end

  --- `post`, then the response's JSON object, when its status is 2xx.
  local function post_object(url: string, payload: {string: Json.Value}?, doing: string,
                             with_jwk?: boolean): ({string: Json.Value}, Http.Body) | (nil, nil, Failure)
    local body, why = post(url, payload, doing, with_jwk)
    if body == nil then return nil, nil, why end
    if body.status // 100 ~= 2 then return nil, nil, problem(body, doing) end
    local object, trouble = Json.decode_object(body.body)
    if object == nil then return nil, nil, Failure.within(trouble, "acme: " .. doing) end
    return object, body
  end

  local client: Acme.Client = {
    thumbprint = thumbprint,

    directory = function(_self: Acme.Client): ({string: string}) | (nil, Failure)
      return read_directory()
    end,

    account = function(_self: Acme.Client, account_opts?: Acme.AccountOptions): (string) | (nil, Failure)
      local have = account_url
      if have ~= nil then return have end
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
        return nil, Failure.new("acme: newAccount answered no Location")
      end
      if not is_https(location) then return nil, not_https("newAccount", location) end
      account_url = location
      return location
    end,

    order = function(_self: Acme.Client, names: {string}): (Acme.Order) | (nil, Failure)
      if #names == 0 then return nil, Failure.new("acme: an order needs a name") end
      local identifiers: mut {Json.Value} = {}
      for i, name in ipairs(names) do
        if not valid_name(name) then
          return nil, Failure.new(("acme: %q is not a DNS name"):format(name))
        end
        identifiers[i] = { type = "dns", value = name }
      end
      local url, why = resource("newOrder")
      if url == nil then return nil, why end
      local object, body, trouble = post_object(url, { identifiers = identifiers }, "newOrder")
      if object == nil then
        local refused = assert(trouble, "a refused post says why")
        return nil, refused
      end
      local location = body.headers["location"]
      if location == nil or location == "" then
        return nil, Failure.new("acme: newOrder answered no Location")
      end
      if not is_https(location) then return nil, not_https("newOrder", location) end
      return read_order(location, object)
    end,

    get_order = function(_self: Acme.Client, url: string): (Acme.Order) | (nil, Failure)
      local object, _, why = post_object(url, nil, "order")
      if object == nil then return nil, why end
      return read_order(url, object)
    end,

    authorization = function(_self: Acme.Client, url: string): (Acme.Authorization) | (nil, Failure)
      local object, _, why = post_object(url, nil, "authorization")
      if object == nil then return nil, why end
      return read_authorization(thumbprint, url, object)
    end,

    respond = function(_self: Acme.Client, challenge: Acme.Challenge): (true) | (nil, Failure)
      local object, _, why = post_object(challenge.url, {}, "challenge")
      if object == nil then return nil, why end
      return true
    end,

    wait = function(_self: Acme.Client, url: string, wait_opts?: Acme.WaitOptions): (string) | (nil, Failure)
      local w = wait_opts or opts.wait or {}
      local timeout = w.timeout_ns or Clock.minutes(2)
      local interval = w.interval_ns or Clock.seconds(2)
      local started = Clock.monotonic_ns()
      while true do
        local object, body, why = post_object(url, nil, "poll")
        if object == nil then
          local refused = assert(why, "a refused post says why")
          return nil, refused
        end
        local status = field(object, "status")
        if status ~= "pending" and status ~= "processing" then return status end
        local left = timeout - (Clock.monotonic_ns() - started)
        if left <= 0 then
          return nil, Failure.new(("acme: %s is still %s after the wait"):format(url, status))
        end
        -- A Retry-After of 0 would poll without a pause.
        local pause = math.min(math.max(retry_after(body) or interval, Clock.ms(100)), left)
        local slept, trouble = pause_for(pause)
        if not slept then return nil, Failure.within(trouble, "acme: poll") end
      end
    end,

    finalize = function(_self: Acme.Client, order: Acme.Order, csr: string): (Acme.Order) | (nil, Failure)
      local object, _, why = post_object(order.finalize, { csr = Codec.base64url(csr) }, "finalize")
      if object == nil then return nil, why end
      return read_order(order.url, object)
    end,

    certificate = function(_self: Acme.Client, url: string): (string) | (nil, Failure)
      local body, why = post(url, nil, "certificate")
      if body == nil then return nil, why end
      if body.status // 100 ~= 2 then return nil, problem(body, "certificate") end
      if body.body:find("-----BEGIN CERTIFICATE-----", 1, true) == nil then
        return nil, Failure.new("acme: certificate: the server sent no PEM certificate")
      end
      return body.body
    end,

    issue = function(self: Acme.Client, names: {string}, issue_opts: Acme.IssueOptions): (string) | (nil, Failure)
      local kind = issue_opts.challenge or "http-01"
      local csr, bad = Acme.csr(issue_opts.key, names)
      if csr == nil then return nil, bad end
      if issue_opts.key.public:spki() == key.public:spki() then
        return nil, Failure.new("acme: the certificate's key is the account's; use another")
      end
      local account, why = self:account()
      if account == nil then return nil, why end
      local order, trouble = self:order(names)
      if order == nil then return nil, trouble end
      local asked: mut {string: boolean} = {}
      for _, name in ipairs(names) do asked[name:lower()] = true end
      for _, url in ipairs(order.authorizations) do
        local authorization, failed = self:authorization(url)
        if authorization == nil then return nil, failed end
        -- A wildcard's authorization is of its base domain, marked
        -- `wildcard` (RFC 8555 section 7.1.3). One for a name not asked
        -- for would have the caller publish a challenge of the server's
        -- choosing.
        local prefix = if authorization.wildcard then "*." else "" end
        local named = prefix .. authorization.domain
        if asked[named:lower()] ~= true then
          return nil, Failure.new(("acme: the server asks to authorize %s, which was not asked for"):format(named))
        end
        if authorization.status ~= "valid" and authorization.status ~= "pending" then
          return nil, Failure.new(("acme: the authorization of %s is %s"):format(authorization.domain, authorization.status))
        end
        if authorization.status == "pending" then
          local chosen: Acme.Challenge? = nil
          for _, challenge in ipairs(authorization.challenges) do
            if challenge.type == kind then chosen = challenge end
          end
          if chosen == nil then
            return nil, Failure.new(("acme: the server offers no %s challenge for %s"):format(kind, authorization.domain))
          end
          local presented, refused = issue_opts.present(chosen)
          if not presented then return nil, Failure.within(refused, "acme: present") end
          local responded, problem_text = self:respond(chosen)
          local status: string? = nil
          local waited: Failure? = problem_text
          if responded then
            local polled, polled_why = self:wait(url)
            status, waited = polled, polled_why
          end
          if issue_opts.cleanup ~= nil then issue_opts.cleanup(chosen) end
          if status == nil then
            local unwaited = assert(waited, "a wait that gave no status says why")
            return nil, unwaited
          end
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
            return nil, Failure.new(("acme: the authorization of %s is %s%s"):format(authorization.domain, status,
              if detail ~= "" then " (" .. detail .. ")" else "" end))
          end
        end
      end
      local ready, not_ready = self:wait(order.url)
      if ready == nil then return nil, not_ready end
      if ready ~= "ready" and ready ~= "valid" then
        return nil, Failure.new(("acme: the order is %s"):format(ready))
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
            return nil, Failure.new(("acme: the finalized order is %s"):format(status))
          end
        end
      end
      if settled.certificate == nil then
        local read, lost = self:get_order(order.url)
        if read == nil then return nil, lost end
        settled = read
      end
      local certificate = settled.certificate
      if certificate == nil then
        return nil, Failure.new("acme: the valid order names no certificate")
      end
      local chain, lost = self:certificate(certificate)
      if chain == nil then return nil, lost end
      -- Checked before it is handed back, as a caller puts it in place of
      -- the certificate it serves.
      local matches, mismatch = leaf_matches(chain, issue_opts.key, names)
      if not matches then return nil, mismatch end
      return chain
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
local function account_key(path: string): (Key.Secret) | (nil, Failure)
  local key = Key.generate("p256")
  -- Created exclusively, with no look first: a key there, made by another
  -- process however lately, is an account, read and never written over.
  local fd, refused, number = sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_EXCL, OWNER_FILE)
  if fd == nil and number == sys.EEXIST then
    local text, unread = Fs.read(path)
    if text == nil then return nil, Failure.new("acme: " .. tostring(unread)) end
    local kept, bad = Key.read(text)
    if kept == nil then return nil, Failure.within(bad, "acme: " .. path) end
    if JWS_ALGS[kept.alg] == nil then
      return nil, Failure.new(("acme: %s: an account key is P-256 or RSA, not %s"):format(path, kept.alg))
    end
    return kept
  end
  -- TODO: write the key to a temporary file and link(2) it to `path`, so
  -- a crash mid-write leaves no cut key there, once cosmic.sys carries
  -- link (build/acme.tl's create waits on the same).
  if fd == nil then return nil, Failure.new("acme: " .. path .. ": " .. refused) end
  local wrote, unwritten = Fs.put(fd, key:pem())
  local closed, unclosed = Fs.close(fd)
  if not wrote or not closed then
    local _, _ = Fs.remove(path)
    local cause = assert(if wrote then unclosed else unwritten end, "a failed write or close says why")
    return nil, Failure.new("acme: " .. path .. ": " .. tostring(cause))
  end
  return key
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
--- its `handler` handles the CA's http-01 check on the server's
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
  if opts.key ~= nil and JWS_ALGS[opts.key.alg] == nil then
    error(("acme: auto's opts.key is a P-256 or RSA key, not %s: CAs issue no other"):format(opts.key.alg), 2)
  end
  local names: {string} = { table.unpack(opts.names) }
  local dir = opts.dir
  local pending: mut {string: string} = {}
  local client: Acme.Client? = nil
  local dns = opts.dns

  local function issued(): (Tls.Pair) | (nil, Failure)
    local made, unmade = Fs.mkdirs(dir, OWNER_DIR)
    if not made then return nil, Failure.new("acme: " .. tostring(unmade)) end
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
    local key = opts.key or Key.generate("p256")
    local chain, why = session:issue(names, {
      key = key,
      challenge = if dns ~= nil then "dns-01" else "http-01" end,
      present = function(c: Acme.Challenge): (true) | (nil, Failure)
        if dns ~= nil then return dns.present(c) end
        pending[c.path] = c.key_authorization
        return true
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
    local pair: Tls.Pair = { cert = chain, key = key:pem() }
    -- One file, written whole, so a reader never sees a chain with
    -- another's key.
    local wrote, unwritten = Fs.write(dir .. "/certificate.pem", chain .. pair.key, OWNER_FILE)
    if not wrote then return nil, Failure.new("acme: " .. tostring(unwritten)) end
    return pair
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
    if pair == nil then return nil, tostring(why) end
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
