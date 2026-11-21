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
--- An account key and a certificate key are each an [`Acme.Key`]:
--- [`Acme.p256_key`] makes one from a [`Sign.p256_secret`]. Keep the
--- account key's secret: the account is that key, and a lost one means a
--- new account. Use another key for the certificate.
---
--- Every fallible function answers `value, ""` or `nil, why`, the why
--- opening `acme: `. A problem document the server sends (RFC 8555
--- section 6.7) is named in the why by its type and detail. A request
--- the server refuses for a stale nonce (`badNonce`) is sent again once
--- with the fresh nonce it handed back, as section 6.5 asks.

local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Sign = require("cosmic.sign")

local record Acme
  --- A key that signs ACME requests (as the account's key) or a
  --- certificate signing request (as the certificate's key).
  record Key
    --- The JWS algorithm the key signs with, as RFC 7518 names it: "ES256".
    alg: string
    --- The public key as a JSON Web Key (RFC 7517), its members in hand
    --- for a thumbprint: `crv`, `kty`, `x` and `y` for an EC key.
    jwk: {string: string}
    --- The DER SubjectPublicKeyInfo of the public key (RFC 5280).
    spki: string
    --- The DER AlgorithmIdentifier of the X.509 signature the key makes.
    signature_algorithm: string
    --- The JWS signature of `message`: for ES256, R then S.
    sign: function(message: string): string
    --- The X.509 signature of `message`: for ECDSA, the DER SEQUENCE of R
    --- and S.
    x509_sign: function(message: string): string
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
    --- true, or false and why, which stops the issue.
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
    --- Waits between polls: [`Clock.sleep_ns`] when nil.
    sleep?: function(ns: integer): boolean, string
    --- [`Acme.Client.wait`]'s options for every wait [`Acme.Client.issue`]
    --- makes.
    wait?: WaitOptions
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

local OID_EC_PUBLIC_KEY <const> = "1.2.840.10045.2.1"
local OID_P256 <const> = "1.2.840.10045.3.1.7"
local OID_ECDSA_SHA256 <const> = "1.2.840.10045.4.3.2"
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
    sign = function(message: string): string
      return Sign.p256(secret, message)
    end,
    x509_sign = function(message: string): string
      local signature = Sign.p256(secret, message)
      return der_sequence(der_unsigned(signature:sub(1, 32)), der_unsigned(signature:sub(33, 64)))
    end,
  }
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
  return #bare > 0 and #bare <= 253 and bare:find("^[%w%-%.]+$") ~= nil
end

--- The DER certificate signing request (PKCS #10, RFC 2986) for the DNS
--- names `names` under `key`: the first name is the subject's common
--- name when it fits one (64 characters at most), and every name is a
--- subjectAltName, as ACME asks (RFC 8555 section 7.4). Nil and why for
--- no names, or a name that is not letters, digits, hyphens and dots
--- after an optional `*.`.
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
  return Clock.seconds(seconds)
end

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
    error("acme: opts.key is an Acme.Key, as Acme.p256_key makes", 2)
  end
  local key = opts.key
  local request: Acme.Request = opts.request or default_request
  local sleep = opts.sleep or Clock.sleep_ns
  local thumbprint = Acme.thumbprint(key)
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
    local body, why = request("GET", opts.directory, {})
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
    local body, trouble = request("HEAD", url, {})
    if body == nil then return nil, "acme: newNonce: " .. trouble end
    local got = body.headers["replay-nonce"]
    if got == nil or got == "" then return nil, "acme: newNonce answered no Replay-Nonce" end
    return got, ""
  end

  --- Sends `payload` (nil for POST-as-GET) to `url` as a JWS signed by
  --- the account key, under its account URL or, with `with_jwk`, its
  --- JWK. A badNonce refusal is sent again once.
  local function post(url: string, payload: {string: Json.Value}?, doing: string,
                      with_jwk?: boolean): Http.Body?, string
    local encoded = ""
    if payload ~= nil then
      local text, why = Json.encode(payload)
      if text == nil then return nil, "acme: " .. why end
      encoded = Codec.base64url(text)
    end
    for attempt = 1, 2 do
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
        headers = { ["Content-Type"] = "application/jose+json" },
        body = body_text,
      })
      if body == nil then return nil, ("acme: %s: %s"):format(doing, trouble) end
      keep(body)
      if not (attempt == 1 and is_bad_nonce(body)) then return body, "" end
    end
    error("unreachable")
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
        local pause = retry_after(body) or interval
        if Clock.monotonic_ns() - started + pause > timeout then
          return nil, ("acme: %s is still %s after the wait"):format(url, status)
        end
        local slept, trouble = sleep(pause)
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
      local _, why = self:account()
      if why ~= "" then return nil, why end
      local order, trouble = self:order(names)
      if order == nil then return nil, trouble end
      for _, url in ipairs(order.authorizations) do
        local authorization, failed = self:authorization(url)
        if authorization == nil then return nil, failed end
        if authorization.status ~= "valid" then
          local chosen: Acme.Challenge? = nil
          for _, challenge in ipairs(authorization.challenges) do
            if challenge.type == kind then chosen = challenge end
          end
          if chosen == nil then
            return nil, ("acme: the server offers no %s challenge for %s"):format(kind, authorization.domain)
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
                if challenge.type == kind then detail = challenge.status end
              end
            end
            return nil, ("acme: the authorization of %s is %s%s"):format(authorization.domain, status,
              if detail ~= "" then " (challenge " .. detail .. ")" else "" end)
          end
        end
      end
      local ready, not_ready = self:wait(order.url)
      if ready == nil then return nil, not_ready end
      if ready ~= "ready" and ready ~= "valid" then
        return nil, ("acme: the order is %s"):format(ready)
      end
      local finalized, refused = self:finalize(order, csr)
      if finalized == nil then return nil, refused end
      local settled = finalized
      if finalized.status ~= "valid" then
        local status, slow = self:wait(order.url)
        if status == nil then return nil, slow end
        if status ~= "valid" then return nil, ("acme: the finalized order is %s"):format(status) end
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

return Acme
