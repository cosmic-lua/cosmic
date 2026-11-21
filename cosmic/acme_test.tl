--- Proves [`cosmic.acme`] against a fake ACME server in this file: every
--- request it sends is a JWS whose signature, nonce and URL the server
--- checks, and the certificate signing request it finalizes with is
--- read back and its signature checked.

local Acme = require("cosmic.acme")
local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Sign = require("cosmic.sign")

local BASE <const> = "https://acme.test"

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

--- What a CSR says: the public key (a P-256 point, or a DER
--- RSAPublicKey), the DNS names, and whether its signature verifies
--- under that key.
local record Request
  public: string
  names: {string}
  common_name: string
  verified: boolean
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
    names = names,
    common_name = common_name,
    verified = Sign.p256_verify(public, info.whole, signature),
  }
end

-- The fake server.

local record Challenge
  type: string
  token: string
  mut status: string
end

local record Authorization
  domain: string
  wildcard: boolean
  mut status: string
  challenges: {Challenge}
end

local record Server
  mut request: Acme.Request
  --- The JWK of the one account, once it exists.
  mut account: {string: Json.Value}?
  nonces: mut {string: boolean}
  mut next_nonce: integer
  --- Requests to refuse with badNonce before taking one.
  mut refuse_nonces: integer
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
  --- The certificate body.
  mut chain: string
  --- What each http-01 token starts with.
  mut token_prefix: string
end

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
    chain = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n",
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
    return {
      identifier = { type = "dns", value = a.domain },
      status = a.status,
      wildcard = a.wildcard,
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
  local function verify(url: string, body: string): {string: Json.Value}?, string?, Http.Body?
    local jws = assert(Json.decode_object(body))
    local protected_text = text(jws["protected"])
    local payload_text = text(jws["payload"])
    local header = assert(Json.decode_object((assert(Codec.unbase64url(protected_text)))))
    assert(text(header["url"]) == url, "the protected url is the request's")
    local n = text(header["nonce"])
    if server.refuse_nonces > 0 then
      server.refuse_nonces = server.refuse_nonces - 1
      server.nonces[n] = nil
      return nil, nil, problem(400, "badNonce", "stale")
    end
    if server.nonces[n] ~= true then return nil, nil, problem(400, "badNonce", "unknown nonce") end
    server.nonces[n] = nil
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
    if jwk == nil then return nil, nil, problem(400, "accountDoesNotExist", "no account") end
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
      return nil, nil, problem(400, "malformed", "bad signature")
    end
    if payload_text == "" then return {}, "", nil end
    return assert(Json.decode_object((assert(Codec.unbase64url(payload_text))))), payload_text, nil
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
    local payload, payload_text, refused = verify(url, assert(opts.body))
    local issued = nonce()
    local fresh: mut {string: string} = { ["replay-nonce"] = issued }
    if refused ~= nil then
      local headers: mut {string: string} = { ["replay-nonce"] = issued }
      for k, v in pairs(refused.headers) do headers[k] = v end
      return { status = refused.status, body = refused.body, headers = headers }
    end
    assert(payload ~= nil and payload_text ~= nil)
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
      return { status = 200, headers = { ["content-type"] = "application/pem-certificate-chain",
        ["replay-nonce"] = issued },
        body = server.chain }
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

local function client_of(server: Server, key?: Acme.Key): Acme.Client
  return Acme.client({
    directory = BASE .. "/directory",
    key = key or Acme.p256_key(Sign.p256_secret()),
    request = server.request,
    pause = no_pause,
  })
end

local function test_issue_answers_the_chain_after_an_http_01_challenge()
  local server = new_server()
  local client = client_of(server)
  assert(client:account({ contact = { "mailto:ops@example.com" }, terms_agreed = true }) == BASE .. "/acct/1")
  local presented: mut {string: string} = {}
  local cleaned = 0
  local certificate_key = Acme.p256_key(Sign.p256_secret())
  local chain, why = client:issue({ "example.com", "www.example.com" }, {
    key = certificate_key,
    present = function(c: Acme.Challenge): boolean, string
      assert(c.type == "http-01")
      assert(c.path == "/.well-known/acme-challenge/" .. c.token)
      assert(c.key_authorization == c.token .. "." .. client.thumbprint)
      presented[c.domain] = c.key_authorization
      return true, ""
    end,
    cleanup = function(_c: Acme.Challenge) cleaned = cleaned + 1 end,
  })
  assert(chain ~= nil, why)
  assert(chain:find("BEGIN CERTIFICATE", 1, true) ~= nil)
  assert(presented["example.com"] == "http-token-example_com." .. client.thumbprint)
  assert(presented["www.example.com"] ~= nil and cleaned == 2)
  local csr = read_csr(server.csr)
  assert(csr.verified, "the request's signature verifies under its own key")
  assert(csr.common_name == "example.com")
  assert(#csr.names == 2 and csr.names[1] == "example.com" and csr.names[2] == "www.example.com")
  local x = assert(Codec.unbase64url(assert(certificate_key.jwk["x"])))
  assert(csr.public:sub(2, 33) == x, "the request carries the certificate key, not the account key")
end

local function test_issue_answers_a_dns_01_challenge_for_a_wildcard()
  local server = new_server()
  local client = client_of(server)
  local records: mut {string: string} = {}
  local chain, why = client:issue({ "*.example.com" }, {
    key = Acme.p256_key(Sign.p256_secret()),
    challenge = "dns-01",
    present = function(c: Acme.Challenge): boolean, string
      assert(c.type == "dns-01" and c.domain == "example.com")
      assert(c.dns_value == Codec.base64url(Hash.sha256(c.key_authorization)))
      records[c.dns_name] = c.dns_value
      return true, ""
    end,
  })
  assert(chain ~= nil, why)
  assert(records["_acme-challenge.example.com"] ~= nil)
  assert(assert(read_csr(server.csr).names[1]) == "*.example.com")
end

local function test_a_wildcard_has_no_http_01_challenge()
  local server = new_server()
  local chain, why = client_of(server):issue({ "*.example.com" }, {
    key = Acme.p256_key(Sign.p256_secret()),
    present = function(_c: Acme.Challenge): boolean, string return true, "" end,
  })
  assert(chain == nil and why == "acme: the server offers no http-01 challenge for example.com", why)
end

local function test_an_invalid_challenge_stops_the_issue_and_says_so()
  local server = new_server()
  server.settle = "invalid"
  local cleaned = false
  local chain, why = client_of(server):issue({ "example.com" }, {
    key = Acme.p256_key(Sign.p256_secret()),
    present = function(_c: Acme.Challenge): boolean, string return true, "" end,
    cleanup = function(_c: Acme.Challenge) cleaned = true end,
  })
  assert(chain == nil and cleaned)
  assert(why == "acme: the authorization of example.com is invalid (Timeout during connect)", why)
end

local function test_a_present_that_fails_stops_the_issue()
  local server = new_server()
  local chain, why = client_of(server):issue({ "example.com" }, {
    key = Acme.p256_key(Sign.p256_secret()),
    present = function(_c: Acme.Challenge): boolean, string return false, "no web server" end,
  })
  assert(chain == nil and why == "acme: present: no web server", why)
end

local function test_a_bad_nonce_is_sent_again_once_with_the_fresh_one()
  local server = new_server()
  server.refuse_nonces = 1
  local client = client_of(server)
  assert(client:account({ terms_agreed = true }) == BASE .. "/acct/1")
  local posts = 0
  for _, line in ipairs(server.log) do
    if line == "POST /acct" then posts = posts + 1 end
  end
  assert(posts == 2, "sent twice")
  server.refuse_nonces = 2
  local account_less = client_of(server)
  local url, why = account_less:account()
  assert(url == nil and why == "acme: newAccount: badNonce (HTTP 400): stale", why)
end

local function test_a_request_before_the_account_says_to_make_one()
  local order, why = client_of(new_server()):order({ "example.com" })
  assert(order == nil and why == "acme: newOrder needs an account first: call client:account()", why)
end

local function test_an_account_url_given_skips_the_lookup()
  local server = new_server()
  local key = Acme.p256_key(Sign.p256_secret())
  assert(client_of(server, key):account() == BASE .. "/acct/1")
  local before = #server.log
  local again = Acme.client({
    directory = BASE .. "/directory", key = key, account = BASE .. "/acct/1",
    request = server.request, pause = no_pause,
  })
  assert(again:account() == BASE .. "/acct/1" and #server.log == before)
  assert(again:order({ "example.com" }) ~= nil)
end

local function test_the_directory_is_read_once_and_names_the_terms()
  local server = new_server()
  local client = client_of(server)
  local directory = assert(client:directory())
  assert(directory["terms"] == BASE .. "/terms" and directory["newOrder"] == BASE .. "/order")
  assert(client:directory() == directory)
  local reads = 0
  for _, line in ipairs(server.log) do
    if line == "GET /directory" then reads = reads + 1 end
  end
  assert(reads == 1)
end

local function test_a_wait_that_runs_out_says_what_is_still_pending()
  local server = new_server()
  server.polls_left = 1000
  local client = Acme.client({
    directory = BASE .. "/directory", key = Acme.p256_key(Sign.p256_secret()),
    request = server.request, pause = no_pause, wait = { timeout_ns = 1, interval_ns = 1 },
  })
  assert(client:account())
  local order = assert(client:order({ "example.com" }))
  local authorization = assert(client:authorization(assert(order.authorizations[1])))
  assert(client:respond(assert(authorization.challenges[1])))
  local status, why = client:wait(authorization.url)
  assert(status == nil and why == "acme: " .. authorization.url .. " is still processing after the wait", why)
end

local function test_a_transport_failure_names_the_step()
  local client = Acme.client({
    directory = BASE .. "/directory", key = Acme.p256_key(Sign.p256_secret()),
    request = function(_m: string, _u: string, _o: Http.Options): Http.Body?, string
      return nil, "connection refused"
    end,
  })
  local url, why = client:account()
  assert(url == nil and why == "acme: directory: connection refused", why)
end

local function test_the_thumbprint_is_the_digest_of_the_canonical_jwk()
  local key = Acme.p256_key(Sign.p256_secret())
  local jwk: mut {string: Json.Value} = {}
  for k, v in pairs(key.jwk) do jwk[k] = v end
  local encoded = assert(Json.encode(jwk))
  local canonical = assert(Json.canonical(encoded))
  assert(canonical:sub(1, 22) == '{"crv":"P-256","kty":"', canonical)
  assert(Acme.thumbprint(key) == Codec.base64url(Hash.sha256(canonical)))
end

local function test_a_csr_with_many_names_takes_long_lengths()
  local key = Acme.p256_key(Sign.p256_secret())
  local names: mut {string} = {}
  for i = 1, 40 do names[i] = "host-" .. tostring(i) .. ".example.com" end
  names[1] = string.rep("a", 63) .. ".example.com"
  local csr = read_csr((assert(Acme.csr(key, names))))
  assert(csr.verified and #csr.names == 40)
  assert(csr.common_name == "", "a first name past 64 characters is no common name")
end

local function test_a_csr_refuses_no_names_and_a_name_that_is_no_dns_name()
  local key = Acme.p256_key(Sign.p256_secret())
  local csr, why = Acme.csr(key, {})
  assert(csr == nil and why == "acme: a certificate request needs a name", why)
  for _, name in ipairs({ "", "a b.example", "example.com\0", "*.", "x/y" }) do
    local refused, trouble = Acme.csr(key, { name })
    assert(refused == nil and trouble == ("acme: %q is not a DNS name"):format(name), trouble)
  end
end

local function test_a_p256_key_signs_jws_as_es256()
  local secret = Sign.p256_secret()
  local key = Acme.p256_key(secret)
  local public = Sign.p256_public(secret)
  assert(key.alg == "ES256" and key.jwk["kty"] == "EC" and key.jwk["crv"] == "P-256")
  assert(assert(Codec.unbase64url(assert(key.jwk["y"]))) == public:sub(34, 65))
  assert(Sign.p256_verify(public, "m", key.sign("m")))
end

local function test_an_rsa_key_signs_jws_as_rs256()
  local secret = Sign.rsa_secret()
  local key = Acme.rsa_key(secret)
  local public = Sign.rsa_public(secret)
  assert(key.alg == "RS256" and key.jwk["kty"] == "RSA" and key.jwk["e"] == "AQAB")
  local n = assert(Codec.unbase64url(assert(key.jwk["n"])))
  assert(#n == 256 and (n:byte(1) or 0) >= 0x80, "n is the 2048-bit modulus, with no zero in front")
  assert(rsa_public(n, "\1\0\1") == public)
  assert(Sign.rsa_verify(public, "m", key.sign("m")))
  assert(key.x509_sign("m") == key.sign("m"))
end

--- RFC 7638 section 3.1: the thumbprint of its RSA key, from the members
--- `e`, `kty` and `n` in that order.
local function test_an_rsa_thumbprint_matches_rfc_7638()
  local key: Acme.Key = {
    alg = "RS256",
    jwk = {
      e = "AQAB",
      kty = "RSA",
      n = "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4" ..
        "n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0z" ..
        "gdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csF" ..
        "Cur-kEgU8awapJzKnqDKgw",
    },
    spki = "",
    signature_algorithm = "",
    sign = function(_message: string): string return "" end,
    x509_sign = function(_message: string): string return "" end,
  }
  assert(Acme.thumbprint(key) == "NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs", Acme.thumbprint(key))
end

local function test_issue_takes_rsa_account_and_certificate_keys()
  local server = new_server()
  local client = client_of(server, Acme.rsa_key(Sign.rsa_secret()))
  assert(client:account({ terms_agreed = true }) == BASE .. "/acct/1")
  local secret = Sign.rsa_secret()
  local chain, why = client:issue({ "example.com" }, {
    key = Acme.rsa_key(secret),
    present = function(c: Acme.Challenge): boolean, string
      assert(c.key_authorization == c.token .. "." .. client.thumbprint)
      return true, ""
    end,
  })
  assert(chain ~= nil, why)
  local csr = read_csr(server.csr)
  assert(csr.verified, "the request's RSA signature verifies under its own key")
  assert(csr.public == Sign.rsa_public(secret), "the request carries the certificate key")
  assert(#csr.names == 1 and csr.names[1] == "example.com")
end

local function test_an_rsa_certificate_key_may_sign_for_a_p256_account()
  local server = new_server()
  local client = client_of(server)
  local chain, why = client:issue({ "example.com" }, {
    key = Acme.rsa_key(Sign.rsa_secret()),
    present = function(_c: Acme.Challenge): boolean, string return true, "" end,
  })
  assert(chain ~= nil, why)
  assert(read_csr(server.csr).verified)
end

local function test_an_rsa_key_raises_on_a_bad_secret()
  local made, why = pcall(Acme.rsa_key, "not a key")
  assert(not made and tostring(why):find("sign: not an RSA secret", 1, true) ~= nil, tostring(why))
end

local function test_a_finalize_that_is_still_processing_is_waited_out()
  local server = new_server()
  server.finalize_slowly = true
  local slept: mut {integer} = {}
  local client = Acme.client({
    directory = BASE .. "/directory", key = Acme.p256_key(Sign.p256_secret()), request = server.request,
    pause = function(ns: integer): boolean, string
      table.insert(slept, ns)
      return true, ""
    end,
  })
  local chain, why = client:issue({ "example.com" }, {
    key = Acme.p256_key(Sign.p256_secret()),
    present = function(_c: Acme.Challenge): boolean, string return true, "" end,
  })
  assert(chain ~= nil, why)
  -- The processing authorization asked for three seconds.
  assert(slept[1] == 3 * 1000000000, tostring(slept[1]))
end

local function test_the_account_payload_says_what_the_caller_agreed_to()
  local server = new_server()
  local key = Acme.p256_key(Sign.p256_secret())
  local missing, why = client_of(server, key):account({ only_existing = true })
  assert(missing == nil and why == "acme: newAccount: accountDoesNotExist (HTTP 400): no account for this key", why)
  assert(client_of(server, key):account({ contact = { "mailto:a@example.com" }, terms_agreed = true }))
  local made = assert(server.accounts[2])
  assert(made["termsOfServiceAgreed"] == true and made["onlyReturnExisting"] == nil)
  local contact = assert(Json.to_array(made["contact"]))
  assert(#contact == 1 and contact[1] == "mailto:a@example.com")
  assert(client_of(server, key):account({ only_existing = true }) == BASE .. "/acct/1", "found, not made")
end

local function test_the_certificate_key_must_not_be_the_account_key()
  local key = Acme.p256_key(Sign.p256_secret())
  local chain, why = client_of(new_server(), key):issue({ "example.com" }, {
    key = key,
    present = function(_c: Acme.Challenge): boolean, string return true, "" end,
  })
  assert(chain == nil and why == "acme: the certificate's key is the account's; use another", why)
end

local function test_a_body_that_is_no_pem_certificate_is_refused()
  local server = new_server()
  server.chain = "<html>oops</html>"
  local chain, why = client_of(server):issue({ "example.com" }, {
    key = Acme.p256_key(Sign.p256_secret()),
    present = function(_c: Acme.Challenge): boolean, string return true, "" end,
  })
  assert(chain == nil and why == "acme: certificate: the server sent no PEM certificate", why)
end

local function test_a_token_that_is_not_base64url_is_never_presented()
  local server = new_server()
  server.token_prefix = "../"
  local presented = false
  local chain, why = client_of(server):issue({ "example.com" }, {
    key = Acme.p256_key(Sign.p256_secret()),
    present = function(_c: Acme.Challenge): boolean, string
      presented = true
      return true, ""
    end,
  })
  assert(chain == nil and not presented)
  assert(why == "acme: the server's token for example.com is not base64url", why)
end
