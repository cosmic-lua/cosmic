--- Proves [`cosmic.acme`] against the fake ACME server of
--- build/acme_fixture.tl: every request it sends is a JWS whose
--- signature, nonce and URL the server checks, and the certificate
--- signing request it finalizes with is read back and its signature
--- checked.

local Acme = require("cosmic.acme")
local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Sign = require("cosmic.sign")
local acme_fixture = require("build.acme_fixture")
local rsa_fixture = require("build.rsa_fixture")

local BASE <const> = acme_fixture.BASE
local type Server = acme_fixture.Server
local new_server = acme_fixture.new_server
local no_pause = acme_fixture.no_pause
local read_csr = acme_fixture.read_csr
local rsa_public = acme_fixture.rsa_public

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
  for _, name in ipairs({ "", "a b.example", "example.com\0", "*.", "x/y", "bad..com", ".example.com",
      "example.com.", "-a.example", "a-.example", "*.*.example", string.rep("a", 64) .. ".example" }) do
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
  local secret = rsa_fixture.FIRST
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
  local client = client_of(server, Acme.rsa_key(rsa_fixture.FIRST))
  assert(client:account({ terms_agreed = true }) == BASE .. "/acct/1")
  local secret = rsa_fixture.SECOND
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
    key = Acme.rsa_key(rsa_fixture.FIRST),
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

local function test_a_429_is_waited_out_by_its_retry_after_and_sent_again()
  local server = new_server()
  server.rate_limited = 2
  server.rate_retry_after = "7"
  local paused: mut {integer} = {}
  local client = Acme.client({
    directory = BASE .. "/directory", key = Acme.p256_key(Sign.p256_secret()),
    request = server.request,
    pause = function(ns: integer): boolean, string
      paused[#paused + 1] = ns
      return true, ""
    end,
  })
  assert(client:account({ terms_agreed = true }) == BASE .. "/acct/1")
  assert(#paused == 2 and paused[1] == 7000000000 and paused[2] == 7000000000, tostring(#paused))
end

local function test_a_429_past_the_most_it_waits_fails_saying_how_long()
  local server = new_server()
  server.rate_limited = 1
  server.rate_retry_after = "3600"
  local url, why = client_of(server):account({ terms_agreed = true })
  assert(url == nil)
  assert(why == "acme: newAccount: rateLimited (HTTP 429): too many new orders (it asks for 3600 s)", why)
  -- The waits add up: two of 40 s pass a minute in all.
  local again = new_server()
  again.rate_limited = 2
  again.rate_retry_after = "40"
  local _, total = client_of(again):account({ terms_agreed = true })
  assert(total:find("it asks for 40 s", 1, true) ~= nil, total)
  -- None waited where the caller takes none, or the server names no time.
  local none = new_server()
  none.rate_limited = 1
  local _, bare = client_of(none):account({ terms_agreed = true })
  assert(bare == "acme: newAccount: rateLimited (HTTP 429): too many new orders", bare)
  local zero = new_server()
  zero.rate_limited = 1
  zero.rate_retry_after = "1"
  local paused = false
  local refused, said = Acme.client({
    directory = BASE .. "/directory", key = Acme.p256_key(Sign.p256_secret()),
    request = zero.request, rate_limit_wait_ns = 0,
    pause = function(_ns: integer): boolean, string
      paused = true
      return true, ""
    end,
  }):account({ terms_agreed = true })
  assert(refused == nil and not paused)
  assert(said:find("it asks for 1 s", 1, true) ~= nil, said)
  -- What the server asks is told whole, past the day a poll is capped at.
  local long = new_server()
  long.rate_limited = 1
  long.rate_retry_after = "999999"
  local _, far = client_of(long):account({ terms_agreed = true })
  assert(far:find("it asks for 999999 s", 1, true) ~= nil, far)
end

local function test_a_429_asking_for_no_wait_counts_a_tenth_of_a_second_each()
  local server = new_server()
  server.rate_limited = 1000
  server.rate_retry_after = "0"
  local paused = 0
  local url, why = Acme.client({
    directory = BASE .. "/directory", key = Acme.p256_key(Sign.p256_secret()),
    request = server.request, rate_limit_wait_ns = Clock.seconds(1),
    pause = function(ns: integer): boolean, string
      assert(ns == Clock.ms(100), tostring(ns))
      paused = paused + 1
      return true, ""
    end,
  }):account({ terms_agreed = true })
  assert(url == nil and why:find("rateLimited", 1, true) ~= nil, why)
  assert(paused == 10, tostring(paused))
end

local function test_a_429_with_an_http_date_waits_until_then()
  local server = new_server()
  server.rate_limited = 1
  -- A date long past waits the least.
  server.rate_retry_after = "Sun, 06 Nov 1994 08:49:37 GMT"
  local waited: mut {integer} = {}
  local client = Acme.client({
    directory = BASE .. "/directory", key = Acme.p256_key(Sign.p256_secret()),
    request = server.request,
    pause = function(ns: integer): boolean, string
      waited[#waited + 1] = ns
      return true, ""
    end,
  })
  assert(client:account({ terms_agreed = true }) == BASE .. "/acct/1")
  assert(#waited == 1 and waited[1] == Clock.ms(100), tostring(waited[1]))
end

local function test_a_pause_that_fails_ends_the_request()
  local server = new_server()
  server.rate_limited = 1
  server.rate_retry_after = "2"
  local url, why = Acme.client({
    directory = BASE .. "/directory", key = Acme.p256_key(Sign.p256_secret()),
    request = server.request,
    pause = function(_ns: integer): boolean, string return false, "cancelled" end,
  }):account({ terms_agreed = true })
  assert(url == nil and why == "acme: newAccount: cancelled", why)
end

local function test_a_bad_rate_limit_wait_raises()
  local ok, why = pcall(Acme.client, {
    directory = BASE .. "/directory", key = Acme.p256_key(Sign.p256_secret()), rate_limit_wait_ns = -1,
  })
  assert(not ok and tostring(why):find("rate_limit_wait_ns", 1, true) ~= nil, tostring(why))
end
