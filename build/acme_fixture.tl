--- The fake ACME server the tests of [`cosmic.acme`] and of `cosmic
--- acme` run against (cosmic/acme_test.tl, build/acme_test.tl): every
--- request it takes is a JWS whose signature, nonce and URL it checks,
--- and a certificate signing request it finalizes with is read back and
--- its signature checked. Test support.

local Acme = require("cosmic.acme")
local Codec = require("cosmic.codec")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
-- The raw signing operations on bytes, which the fixtures build keys of.
local Sign = require("cosmic.internal.sign")

local record acme_fixture
  --- What a CSR says: the public key (a P-256 point, or a DER
  --- RSAPublicKey), the DNS names, and whether its signature verifies
  --- under that key.
  record Csr
    public: string
    --- The DER SubjectPublicKeyInfo, whole.
    spki: string
    names: {string}
    common_name: string
    verified: boolean
  end
  --- An authorization's identifier as the server shows it.
  record Identifier
    type: string
    value: string
    wildcard: boolean
  end
  record Challenge
    type: string
    token: string
    mut status: string
  end
  record Authorization
    domain: string
    wildcard: boolean
    mut status: string
    challenges: {Challenge}
  end
  record Server
    mut request: Acme.Request
    --- The JWK of the one account, once it exists.
    mut account: {string: Json.Value}?
    nonces: mut {string: boolean}
    mut next_nonce: integer
    --- Requests to refuse with badNonce before taking one.
    mut refuse_nonces: integer
    --- Requests to refuse with 429 rateLimited before taking one.
    mut rate_limited: integer
    --- The Retry-After a rateLimited answer sends; none when "".
    mut rate_retry_after: string
    --- Polls of a processing resource before it settles.
    mut polls_left: integer
    --- What a challenge settles as once it is checked.
    mut settle: string
    mut authorizations: mut {Authorization}
    mut order_status: string
    mut csr: string
    log: mut {string}
    --- The newAccount payloads, in order.
    accounts: mut {{string: Json.Value}}
    --- Whether finalize answers "processing", the order valid a poll later.
    mut finalize_slowly: boolean
    --- The Retry-After a processing authorization sends.
    mut retry_after: string
    --- The certificate body; "" for a leaf made from the CSR, which
    --- certifies its key for its names (its signature is not one).
    mut chain: string
    --- The names the made leaf holds in place of the CSR's.
    mut leaf_names?: {string}
    --- The DER SubjectPublicKeyInfo the made leaf holds in place of the
    --- CSR's.
    mut leaf_spki?: string
    --- What an authorization of `domain` (a wildcard's when `wildcard`)
    --- shows as its identifier; nil for "dns", `domain` and `wildcard`.
    mut shown?: function(domain: string, wildcard: boolean): Identifier
    --- What each http-01 token starts with.
    mut token_prefix: string
    --- Checks a challenge as a CA would, once the client responds to it,
    --- and answers what it settles as at once ("valid" or "invalid");
    --- nil to settle it as `settle` after `polls_left` polls.
    mut check?: function(domain: string, token: string): string
  end
  --- The server's base URL; its directory is BASE .. "/directory".
  BASE: string
  read_csr: function(csr: string): Csr
  new_server: function(): Server
  no_pause: function(ns: integer): boolean, string
end

local type Request = acme_fixture.Csr
local type Challenge = acme_fixture.Challenge
local type Server = acme_fixture.Server

local BASE <const> = "https://acme.test"
acme_fixture.BASE = BASE

-- A DER reader, as much as checking a certificate signing request takes.

--- The tag, the content and the index after the element at `at` of `der`.
local function read_der(der: string, at: integer): integer, string, integer
  local tag = assert(der:byte(at), "an element at " .. tostring(at))
  local first = assert(der:byte(at + 1), "a length")
  local length, start = first, at + 2
  if first >= 0x80 then
    length = 0
    for i = 1, first & 0x7f do length = (length << 8) | assert(der:byte(at + 1 + i)) end
    start = at + 2 + (first & 0x7f)
  end
  return tag, der:sub(start, start + length - 1), start + length
end

--- The elements of the constructed content `content`, each its whole
--- encoding, its tag and its content.
local record Element
  tag: integer
  content: string
  whole: string
end

local function elements(content: string): {Element}
  local out: mut {Element} = {}
  local at = 1
  while at <= #content do
    local tag, inner, after = read_der(content, at)
    out[#out + 1] = { tag = tag, content = inner, whole = content:sub(at, after - 1) }
    at = after
  end
  return out
end

--- The 32 big-endian bytes of the DER INTEGER content `content`.
local function fixed(content: string): string
  local trimmed = content:gsub("^\0+", "")
  return string.rep("\0", 32 - #trimmed) .. trimmed
end

--- sha256WithRSAEncryption and rsaEncryption, each with its NULL
--- parameters (RFC 4055 section 5, RFC 3279 section 2.3.1).
local RSA_SHA256 <const> = "\x30\x0d\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x0b\x05\x00"
local RSA_ENCRYPTION <const> = "\x30\x0d\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01\x05\x00"

--- The DER INTEGER of the unsigned big-endian `bytes`, a zero in front
--- where its top bit is set.
local function der_integer(bytes: string): string
  local body = if (bytes:byte(1) or 0) >= 0x80 then "\0" .. bytes else bytes end
  local length = if #body < 0x80 then string.char(#body)
    elseif #body < 0x100 then "\x81" .. string.char(#body)
    else "\x82" .. string.char(#body >> 8, #body & 0xff)
    end
  return "\x02" .. length .. body
end

--- The DER RSAPublicKey of the JWK members `n` and `e`.
local function rsa_public(n: string, e: string): string
  local numbers = der_integer(n) .. der_integer(e)
  return "\x30\x82" .. string.char(#numbers >> 8, #numbers & 0xff) .. numbers
end

local function read_csr(csr: string): Request
  local _, outer, _ = read_der(csr, 1)
  local parts = elements(outer)
  local info, signature_bits = assert(parts[1]), assert(parts[3])
  -- The DER of each identifier, spelled out here rather than built by
  -- the encoder under test: ecdsa-with-SHA256 or sha256WithRSAEncryption,
  -- id-ecPublicKey with prime256v1 or rsaEncryption, extensionRequest
  -- and subjectAltName.
  local algorithm = assert(parts[2]).whole
  local rsa = algorithm == RSA_SHA256
  assert(rsa or algorithm == "\x30\x0a\x06\x08\x2a\x86\x48\xce\x3d\x04\x03\x02", "ecdsa-with-SHA256")
  local fields = elements(info.content)
  assert(assert(fields[1]).whole == "\x02\x01\x00", "version 0")
  assert(assert(fields[4]).tag == 0xa0, "attributes are [0]")
  local subject = assert(fields[2])
  local common_name = ""
  for _, set in ipairs(elements(subject.content)) do
    local attribute = elements(assert(elements(set.content)[1]).content)
    assert(assert(attribute[1]).whole == "\x06\x03\x55\x04\x03", "commonName")
    assert(assert(attribute[2]).tag == 0x0c, "a UTF8String")
    common_name = assert(attribute[2]).content
  end
  local spki = elements(assert(fields[3]).content)
  if rsa then
    assert(assert(spki[1]).whole == RSA_ENCRYPTION, "rsaEncryption")
  else
    assert(assert(spki[1]).whole == "\x30\x13\x06\x07\x2a\x86\x48\xce\x3d\x02\x01" ..
        "\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07", "id-ecPublicKey, prime256v1")
  end
  local public = assert(spki[2]).content:sub(2)
  local spki_whole = assert(fields[3]).whole
  local names: mut {string} = {}
  local attribute = elements(assert(elements(assert(fields[4]).content)[1]).content)
  assert(assert(attribute[1]).whole == "\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x09\x0e", "extensionRequest")
  assert(assert(attribute[2]).tag == 0x31, "a SET of values")
  local extensions = assert(elements(assert(attribute[2]).content)[1])
  for _, extension in ipairs(elements(extensions.content)) do
    local parts_of = elements(extension.content)
    assert(assert(parts_of[1]).whole == "\x06\x03\x55\x1d\x11", "subjectAltName")
    assert(assert(parts_of[2]).tag == 0x04, "an OCTET STRING")
    local value = assert(parts_of[2]).content
    local _, general_names, _ = read_der(value, 1)
    for _, name in ipairs(elements(general_names)) do
      assert(name.tag == 0x82, "a dNSName")
      names[#names + 1] = name.content
    end
  end
  if rsa then
    return {
      public = public,
      spki = spki_whole,
      names = names,
      common_name = common_name,
      verified = Sign.rsa_verify(public, info.whole, signature_bits.content:sub(2)),
    }
  end
  local _, sequence, _ = read_der(signature_bits.content:sub(2), 1)
  local integers = elements(sequence)
  local signature = fixed(assert(integers[1]).content) .. fixed(assert(integers[2]).content)
  return {
    public = public,
    spki = spki_whole,
    names = names,
    common_name = common_name,
    verified = Sign.p256_verify(public, info.whole, signature),
  }
end

--- The DER element of `tag` around `content`, spelled out here rather
--- than built by the encoder under test.
local function tlv(tag: integer, content: string): string
  local n = #content
  local length = if n < 0x80 then string.char(n)
    elseif n < 0x100 then "\x81" .. string.char(n)
    else "\x82" .. string.char(n >> 8, n & 0xff)
    end
  return string.char(tag) .. length .. content
end

--- A PEM certificate of the DER SubjectPublicKeyInfo `spki` for the DNS
--- names `names`: a v3 TBSCertificate with an empty issuer and subject
--- and a subjectAltName, under a signature that is no signature.
local function leaf_for(spki: string, names: {string}): string
  local ecdsa_sha256 = "\x30\x0a\x06\x08\x2a\x86\x48\xce\x3d\x04\x03\x02"
  local general: mut {string} = {}
  for i, name in ipairs(names) do general[i] = tlv(0x82, name) end
  local san = tlv(0x30, "\x06\x03\x55\x1d\x11" .. tlv(0x04, tlv(0x30, table.concat(general))))
  local tbs = tlv(0x30, "\xa0\x03\x02\x01\x02" .. "\x02\x01\x01" .. ecdsa_sha256 .. "\x30\x00" ..
      tlv(0x30, tlv(0x17, "260101000000Z") .. tlv(0x18, "21260101000000Z")) .. "\x30\x00" .. spki ..
      tlv(0xa3, tlv(0x30, san)))
  local der = tlv(0x30, tbs .. ecdsa_sha256 .. tlv(0x03, "\0" .. string.rep("\1", 64)))
  local text = Codec.base64(der)
  local lines: mut {string} = { "-----BEGIN CERTIFICATE-----" }
  for i = 1, #text, 64 do lines[#lines + 1] = text:sub(i, i + 63) end
  lines[#lines + 1] = "-----END CERTIFICATE-----"
  return table.concat(lines, "\n") .. "\n"
end

-- The fake server.

local function reply(status: integer, value: Json.Value, headers?: {string: string}): Http.Body
  local h: mut {string: string} = { ["content-type"] = "application/json" }
  for k, v in pairs(headers or {}) do h[k] = v end
  return { status = status, body = assert(Json.encode(value)), headers = h }
end

local function problem(status: integer, kind: string, detail: string): Http.Body
  return reply(status, { type = "urn:ietf:params:acme:error:" .. kind, detail = detail },
    { ["content-type"] = "application/problem+json" })
end

local function text(value: Json.Value?): string
  if value is string then return value end
  return ""
end

local function new_server(): Server
  local server: Server = {
    request = function(_m: string, _u: string, _o: Http.Options): Http.Body?, string
      return nil, "not yet"
    end,
    account = nil,
    nonces = {},
    next_nonce = 0,
    refuse_nonces = 0,
    rate_limited = 0,
    rate_retry_after = "",
    polls_left = 1,
    settle = "valid",
    authorizations = {},
    order_status = "pending",
    csr = "",
    log = {},
    accounts = {},
    finalize_slowly = false,
    retry_after = "3",
    token_prefix = "",
    chain = "",
  }
  local function nonce(): string
    server.next_nonce = server.next_nonce + 1
    local n = "nonce-" .. tostring(server.next_nonce)
    server.nonces[n] = true
    return n
  end

  local function authorization_json(i: integer): Json.Value
    local a = assert(server.authorizations[i])
    local challenges: mut {Json.Value} = {}
    for j, c in ipairs(a.challenges) do
      local shown: mut {string: Json.Value} = {
        type = c.type, token = c.token, status = c.status,
        url = BASE .. "/chall/" .. tostring(i) .. "/" .. tostring(j),
      }
      if c.status == "invalid" then
        shown["error"] = { type = "urn:ietf:params:acme:error:connection", detail = "Timeout during connect" }
      end
      challenges[#challenges + 1] = shown
    end
    local shown = server.shown
    local identifier: acme_fixture.Identifier = if shown ~= nil then shown(a.domain, a.wildcard)
      else { type = "dns", value = a.domain, wildcard = a.wildcard }
      end
    return {
      identifier = { type = identifier.type, value = identifier.value },
      status = a.status,
      wildcard = identifier.wildcard,
      challenges = Json.array(challenges),
    }
  end

  local function order_json(): Json.Value
    local authorizations: mut {Json.Value} = {}
    local identifiers: mut {Json.Value} = {}
    for i, a in ipairs(server.authorizations) do
      authorizations[i] = BASE .. "/authz/" .. tostring(i)
      local prefix = if a.wildcard then "*." else "" end
      identifiers[i] = { type = "dns", value = prefix .. a.domain }
    end
    local order: mut {string: Json.Value} = {
      status = server.order_status,
      identifiers = Json.array(identifiers),
      authorizations = Json.array(authorizations),
      finalize = BASE .. "/finalize/1",
    }
    if server.order_status == "valid" and not server.finalize_slowly then
      order["certificate"] = BASE .. "/cert/1"
    end
    return order
  end

  --- The payload of a JWS the account (or, for newAccount, the JWK in
  --- it) signed, or a problem.
  --- What a request carried: its payload and the payload's text, or the
  --- problem it is refused with.
  local record Verified
    payload: {string: Json.Value}
    payload_text: string
    refused?: Http.Body
  end

  --- What the JWS `body` posted to `url` carries.
  local function verify(url: string, body: string): Verified
    local jws = assert(Json.decode_object(body))
    local protected_text = text(jws["protected"])
    local payload_text = text(jws["payload"])
    local header = assert(Json.decode_object((assert(Codec.unbase64url(protected_text)))))
    assert(text(header["url"]) == url, "the protected url is the request's")
    local n = text(header["nonce"])
    if server.refuse_nonces > 0 then
      server.refuse_nonces = server.refuse_nonces - 1
      server.nonces[n] = nil
      return { payload = {}, payload_text = "", refused = problem(400, "badNonce", "stale") }
    end
    if server.nonces[n] ~= true then
      return { payload = {}, payload_text = "", refused = problem(400, "badNonce", "unknown nonce") }
    end
    server.nonces[n] = nil
    if server.rate_limited > 0 then
      server.rate_limited = server.rate_limited - 1
      local limited = problem(429, "rateLimited", "too many new orders")
      local headers: mut {string: string} = {}
      for k, v in pairs(limited.headers) do headers[k] = v end
      if server.rate_retry_after ~= "" then headers["retry-after"] = server.rate_retry_after end
      return { payload = {}, payload_text = "", refused = { status = 429, body = limited.body, headers = headers } }
    end
    local jwk: {string: Json.Value}? = nil
    -- RFC 8555 section 6.2: newAccount carries the key, every other
    -- request the account's URL.
    assert((header["jwk"] ~= nil) == (url == BASE .. "/acct"), "jwk on newAccount alone, kid elsewhere")
    if header["jwk"] ~= nil then
      assert(header["kid"] == nil, "jwk and kid together")
      jwk = assert(Json.to_object(header["jwk"]))
    else
      assert(text(header["kid"]) == BASE .. "/acct/1", "kid")
      jwk = server.account
    end
    if jwk == nil then
      return { payload = {}, payload_text = "", refused = problem(400, "accountDoesNotExist", "no account") }
    end
    local signature = assert(Codec.unbase64url(text(jws["signature"])))
    local signed = protected_text .. "." .. payload_text
    local verified = false
    if text(jwk["kty"]) == "RSA" then
      assert(text(header["alg"]) == "RS256", "an RSA key signs as RS256")
      local public = rsa_public(assert(Codec.unbase64url(text(jwk["n"]))), (assert(Codec.unbase64url(text(jwk["e"])))))
      verified = Sign.rsa_verify(public, signed, signature)
    else
      assert(text(header["alg"]) == "ES256", "an EC key signs as ES256")
      local public = "\4" .. assert(Codec.unbase64url(text(jwk["x"]))) .. assert(Codec.unbase64url(text(jwk["y"])))
      verified = Sign.p256_verify(public, signed, signature)
    end
    if not verified then
      return { payload = {}, payload_text = "", refused = problem(400, "malformed", "bad signature") }
    end
    if payload_text == "" then return { payload = {}, payload_text = "" } end
    return { payload = assert(Json.decode_object((assert(Codec.unbase64url(payload_text))))), payload_text = payload_text }
  end

  local function handle(method: string, url: string, opts: Http.Options): Http.Body
    local line = method .. " " .. url:sub(#BASE + 1)
    table.insert(server.log, line)
    if url == BASE .. "/directory" then
      return reply(200, {
        newNonce = BASE .. "/nonce", newAccount = BASE .. "/acct", newOrder = BASE .. "/order",
        meta = { termsOfService = BASE .. "/terms" },
      })
    end
    if url == BASE .. "/nonce" then
      assert(method == "HEAD", "a nonce is asked for with HEAD")
      return { status = 200, body = "", headers = { ["replay-nonce"] = nonce() } }
    end
    assert(method == "POST", "every other request is a POST")
    assert((opts.headers or {})["Content-Type"] == "application/jose+json")
    local verified = verify(url, assert(opts.body))
    local payload, payload_text, refused = verified.payload, verified.payload_text, verified.refused
    local issued = nonce()
    local fresh: mut {string: string} = { ["replay-nonce"] = issued }
    if refused ~= nil then
      local headers: mut {string: string} = { ["replay-nonce"] = issued }
      for k, v in pairs(refused.headers) do headers[k] = v end
      return { status = refused.status, body = refused.body, headers = headers }
    end
    fresh["location"] = BASE .. "/acct/1"
    if url == BASE .. "/acct" then
      table.insert(server.accounts, payload)
      local known = server.account ~= nil
      if payload["onlyReturnExisting"] == true and not known then
        return problem(400, "accountDoesNotExist", "no account for this key")
      end
      local header = assert(Json.decode_object((assert(Codec.unbase64url(text(
        assert(Json.decode_object(assert(opts.body)))["protected"]))))))
      server.account = assert(Json.to_object(header["jwk"]))
      return reply(if known then 200 else 201 end, { status = "valid" }, fresh)
    end
    if url == BASE .. "/order" then
      server.authorizations = {}
      local identifiers = assert(Json.to_array(payload["identifiers"]))
      for _, identifier in ipairs(identifiers) do
        local value = text(assert(Json.to_object(identifier))["value"])
        local wildcard = value:sub(1, 2) == "*."
        local domain = if wildcard then value:sub(3) else value end
        -- A token is base64url, so the domain's dots go.
        local label = (domain:gsub("%.", "_"))
        local challenges: mut {Challenge} = {
          { type = "dns-01", token = "dns-token-" .. label, status = "pending" },
        }
        if not wildcard then
          table.insert(challenges, 1, { type = "http-01", token = server.token_prefix .. "http-token-" .. label,
            status = "pending" })
        end
        server.authorizations[#server.authorizations + 1] = {
          domain = domain, wildcard = wildcard, status = "pending", challenges = challenges,
        }
      end
      server.order_status = "pending"
      fresh["location"] = BASE .. "/orders/1"
      return reply(201, order_json(), fresh)
    end
    local i = math.tointeger(tonumber(url:match("/authz/(%d+)$")))
    if i ~= nil then
      assert(payload_text == "", "POST-as-GET")
      local a = assert(server.authorizations[i])
      if a.status == "processing" then
        server.polls_left = server.polls_left - 1
        if server.polls_left < 0 then
          a.status = server.settle
          for _, c in ipairs(a.challenges) do
            if c.status == "processing" then c.status = server.settle end
          end
          local all = true
          for _, other in ipairs(server.authorizations) do all = all and other.status == "valid" end
          if all then server.order_status = "ready" end
        end
      end
      local shown: Json.Value = authorization_json(i)
      local current = assert(server.authorizations[i]).status
      if current == "processing" then fresh["retry-after"] = server.retry_after end
      return reply(200, shown, fresh)
    end
    local ci, cj = url:match("/chall/(%d+)/(%d+)$")
    if ci ~= nil then
      local a = assert(server.authorizations[math.tointeger(tonumber(ci)) or 0])
      local c = assert(a.challenges[math.tointeger(tonumber(cj)) or 0])
      c.status = "processing"
      a.status = "processing"
      local check = server.check
      if check ~= nil then
        c.status = check(a.domain, c.token)
        a.status = c.status
        local all = true
        for _, other in ipairs(server.authorizations) do all = all and other.status == "valid" end
        if all then server.order_status = "ready" end
      end
      return reply(200, { type = c.type, token = c.token, status = c.status }, fresh)
    end
    if url == BASE .. "/orders/1" then
      -- A slow finalize is valid at the first read after it.
      if server.finalize_slowly and server.order_status == "processing" then
        server.order_status = "valid"
        server.finalize_slowly = false
      end
      return reply(200, order_json(), fresh)
    end
    if url == BASE .. "/finalize/1" then
      if server.order_status ~= "ready" then return problem(403, "orderNotReady", "not ready") end
      server.csr = assert(Codec.unbase64url(text(payload["csr"])))
      -- Let's Encrypt takes a request only for exactly the order's names.
      local asked: mut {string} = {}
      for _, a in ipairs(server.authorizations) do
        local prefix = if a.wildcard then "*." else "" end
        asked[#asked + 1] = prefix .. a.domain
      end
      local named: mut {string} = {}
      for _, name in ipairs(read_csr(server.csr).names) do named[#named + 1] = name end
      table.sort(asked)
      table.sort(named)
      if table.concat(asked, " ") ~= table.concat(named, " ") then
        return problem(400, "badCSR", "names differ from the order's")
      end
      server.order_status = if server.finalize_slowly then "processing" else "valid" end
      return reply(200, order_json(), fresh)
    end
    if url == BASE .. "/cert/1" then
      local chain = server.chain
      if chain == "" then
        local csr = read_csr(server.csr)
        chain = leaf_for(server.leaf_spki or csr.spki, server.leaf_names or csr.names)
      end
      return { status = 200, headers = { ["content-type"] = "application/pem-certificate-chain",
        ["replay-nonce"] = issued },
        body = chain }
    end
    error("no such resource: " .. url)
  end

  server.request = function(method: string, url: string, opts: Http.Options): Http.Body?, string
    return handle(method, url, opts), ""
  end
  return server
end

local function no_pause(_ns: integer): boolean, string
  return true, ""
end

--- What a CSR says, read from its DER.
acme_fixture.read_csr = read_csr
--- A new server, with one order of the names the client asks for.
acme_fixture.new_server = new_server
--- A pause that returns at once.
acme_fixture.no_pause = no_pause

return acme_fixture
