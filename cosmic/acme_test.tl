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
local Key = require("cosmic.key")
local Json = require("cosmic.json")
local Sign = require("cosmic.sign")
local acme_fixture = require("build.acme_fixture")
local rsa_fixture = require("build.rsa_fixture")

local BASE <const> = acme_fixture.BASE
local type Server = acme_fixture.Server
local new_server = acme_fixture.new_server
local no_pause = acme_fixture.no_pause
local read_csr = acme_fixture.read_csr

local function client_of(server: Server, key?: Key.Secret): Acme.Client
  return Acme.client({
    directory = BASE .. "/directory",
    key = key or Key.generate("p256"),
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
  local certificate_key = Key.generate("p256")
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
  local x = assert(Codec.unbase64url(assert(certificate_key.public:jwk()["x"])))
  assert(csr.public:sub(2, 33) == x, "the request carries the certificate key, not the account key")
end

local function test_issue_answers_a_dns_01_challenge_for_a_wildcard()
  local server = new_server()
  local client = client_of(server)
  local records: mut {string: string} = {}
  local chain, why = client:issue({ "*.example.com" }, {
    key = Key.generate("p256"),
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
    key = Key.generate("p256"),
    present = function(_c: Acme.Challenge): boolean, string return true, "" end,
  })
  assert(chain == nil and why == "acme: the server offers no http-01 challenge for example.com", why)
end

local function test_an_invalid_challenge_stops_the_issue_and_says_so()
  local server = new_server()
  server.settle = "invalid"
  local cleaned = false
  local chain, why = client_of(server):issue({ "example.com" }, {
    key = Key.generate("p256"),
    present = function(_c: Acme.Challenge): boolean, string return true, "" end,
    cleanup = function(_c: Acme.Challenge) cleaned = true end,
  })
  assert(chain == nil and cleaned)
  assert(why == "acme: the authorization of example.com is invalid (Timeout during connect)", why)
end

local function test_a_present_that_fails_stops_the_issue()
  local server = new_server()
  local chain, why = client_of(server):issue({ "example.com" }, {
    key = Key.generate("p256"),
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
  local key = Key.generate("p256")
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
    directory = BASE .. "/directory", key = Key.generate("p256"),
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
    directory = BASE .. "/directory", key = Key.generate("p256"),
    request = function(_m: string, _u: string, _o: Http.Options): Http.Body?, string
      return nil, "connection refused"
    end,
  })
  local url, why = client:account()
  assert(url == nil and why == "acme: directory: connection refused", why)
end

local function test_the_thumbprint_is_the_digest_of_the_canonical_jwk()
  local key = Key.generate("p256")
  local jwk: mut {string: Json.Value} = {}
  for k, v in pairs(key.public:jwk()) do jwk[k] = v end
  local encoded = assert(Json.encode(jwk))
  local canonical = assert(Json.canonical(encoded))
  assert(canonical:sub(1, 22) == '{"crv":"P-256","kty":"', canonical)
  assert(key.public:thumbprint() == Codec.base64url(Hash.sha256(canonical)))
end

local function test_a_csr_with_many_names_takes_long_lengths()
  local key = Key.generate("p256")
  local names: mut {string} = {}
  for i = 1, 40 do names[i] = "host-" .. tostring(i) .. ".example.com" end
  names[1] = string.rep("a", 63) .. ".example.com"
  local csr = read_csr((assert(Acme.csr(key, names))))
  assert(csr.verified and #csr.names == 40)
  assert(csr.common_name == "", "a first name past 64 characters is no common name")
end

local function test_a_csr_refuses_no_names_and_a_name_that_is_no_dns_name()
  local key = Key.generate("p256")
  local csr, why = Acme.csr(key, {})
  assert(csr == nil and why == "acme: a certificate request needs a name", why)
  for _, name in ipairs({ "", "a b.example", "example.com\0", "*.", "x/y", "bad..com", ".example.com",
      "example.com.", "-a.example", "a-.example", "*.*.example", string.rep("a", 64) .. ".example" }) do
    local refused, trouble = Acme.csr(key, { name })
    assert(refused == nil and trouble == ("acme: %q is not a DNS name"):format(name), trouble)
  end
end

local function test_an_ed25519_key_is_refused_as_account_and_as_certificate_key()
  local key = Key.generate("ed25519")
  local made, why = pcall(Acme.client, { directory = BASE .. "/directory", key = key })
  assert(not made and tostring(why):find("acme: opts.key is a P-256 or RSA key, not ed25519", 1, true) ~= nil,
    tostring(why))
  local csr, trouble = Acme.csr(key, { "example.com" })
  assert(csr == nil and trouble:find("acme: a certificate's key is P-256 or RSA, not ed25519", 1, true) ~= nil, trouble)
end

local function test_issue_takes_rsa_account_and_certificate_keys()
  local server = new_server()
  local client = client_of(server, assert(Key.secret("rsa", rsa_fixture.FIRST)))
  assert(client:account({ terms_agreed = true }) == BASE .. "/acct/1")
  local secret = rsa_fixture.SECOND
  local chain, why = client:issue({ "example.com" }, {
    key = assert(Key.secret("rsa", secret)),
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
    key = assert(Key.secret("rsa", rsa_fixture.FIRST)),
    present = function(_c: Acme.Challenge): boolean, string return true, "" end,
  })
  assert(chain ~= nil, why)
  assert(read_csr(server.csr).verified)
end

local function test_a_finalize_that_is_still_processing_is_waited_out()
  local server = new_server()
  server.finalize_slowly = true
  local slept: mut {integer} = {}
  local client = Acme.client({
    directory = BASE .. "/directory", key = Key.generate("p256"), request = server.request,
    pause = function(ns: integer): boolean, string
      table.insert(slept, ns)
      return true, ""
    end,
  })
  local chain, why = client:issue({ "example.com" }, {
    key = Key.generate("p256"),
    present = function(_c: Acme.Challenge): boolean, string return true, "" end,
  })
  assert(chain ~= nil, why)
  -- The processing authorization asked for three seconds.
  assert(slept[1] == 3 * 1000000000, tostring(slept[1]))
end

local function test_the_account_payload_says_what_the_caller_agreed_to()
  local server = new_server()
  local key = Key.generate("p256")
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
  local key = Key.generate("p256")
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
    key = Key.generate("p256"),
    present = function(_c: Acme.Challenge): boolean, string return true, "" end,
  })
  assert(chain == nil and why == "acme: certificate: the server sent no PEM certificate", why)
end

local function test_a_token_that_is_not_base64url_is_never_presented()
  local server = new_server()
  server.token_prefix = "../"
  local presented = false
  local chain, why = client_of(server):issue({ "example.com" }, {
    key = Key.generate("p256"),
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
    directory = BASE .. "/directory", key = Key.generate("p256"),
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
    directory = BASE .. "/directory", key = Key.generate("p256"),
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
    directory = BASE .. "/directory", key = Key.generate("p256"),
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
    directory = BASE .. "/directory", key = Key.generate("p256"),
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
    directory = BASE .. "/directory", key = Key.generate("p256"),
    request = server.request,
    pause = function(_ns: integer): boolean, string return false, "cancelled" end,
  }):account({ terms_agreed = true })
  assert(url == nil and why == "acme: newAccount: cancelled", why)
end

local function test_a_bad_rate_limit_wait_raises()
  local ok, why = pcall(Acme.client, {
    directory = BASE .. "/directory", key = Key.generate("p256"), rate_limit_wait_ns = -1,
  })
  assert(not ok and tostring(why):find("rate_limit_wait_ns", 1, true) ~= nil, tostring(why))
end

--- A present that only counts its calls.
local record Counted
  mut presented: integer
end

local function issue_counted(server: Server, names: {string}, challenge?: Acme.ChallengeType): string?, string, integer
  local counted: Counted = { presented = 0 }
  local chain, why = client_of(server):issue(names, {
    key = Key.generate("p256"),
    challenge = challenge,
    present = function(_c: Acme.Challenge): boolean, string
      counted.presented = counted.presented + 1
      return true, ""
    end,
  })
  return chain, why, counted.presented
end

local function test_an_authorization_of_a_name_not_asked_for_is_never_presented()
  local cases: {{string}} = {
    -- asked for, then the identifier's type, value and wildcard shown, and the why
    { "example.com", "dns", "evil.example", "", "acme: the server asks to authorize evil.example, which was not asked for" },
    { "example.com", "dns", "example.com", "wildcard",
      "acme: the server asks to authorize *.example.com, which was not asked for" },
    { "*.example.com", "dns", "example.com", "",
      "acme: the server asks to authorize example.com, which was not asked for" },
    { "example.com", "ip", "example.com", "", "is not for a DNS name" },
    { "example.com", "dns", "", "", "is not for a DNS name" },
    { "*.example.com", "dns", "*.example.com", "wildcard", "is not for a DNS name" },
    { "example.com", "dns", "example.com evil.example", "", "is not for a DNS name" },
  }
  for _, case in ipairs(cases) do
    local asked, kind, value = assert(case[1]), assert(case[2]), assert(case[3])
    local wildcard, expected = case[4] == "wildcard", assert(case[5])
    local server = new_server()
    server.shown = function(_domain: string, _wildcard: boolean): acme_fixture.Identifier
      return { type = kind, value = value, wildcard = wildcard }
    end
    local challenge: Acme.ChallengeType = if asked:sub(1, 2) == "*." then "dns-01" else "http-01" end
    local chain, why, presented = issue_counted(server, { asked }, challenge)
    assert(chain == nil and presented == 0, value)
    assert(why:find(expected, 1, true) ~= nil, why)
  end
  -- A name asked for in another case, and a wildcard's base domain, are taken.
  local server = new_server()
  server.shown = function(domain: string, wildcard: boolean): acme_fixture.Identifier
    return { type = "dns", value = domain:upper(), wildcard = wildcard }
  end
  local chain, why = issue_counted(server, { "*.example.com" }, "dns-01")
  assert(chain ~= nil, why)
end

local function test_every_url_is_https_and_no_redirect_is_followed()
  -- The resource whose answer names its URLs as http, and the step refused.
  local cases: {{string}} = {
    { "/directory", "acme: newAccount: \"http://acme.test/acct\" is not an https URL" },
    { "/directory nonce", "acme: newNonce: \"http://acme.test/nonce\" is not an https URL" },
    { "/acct", "acme: newAccount: \"http://acme.test/acct/1\" is not an https URL" },
    { "/order", "acme: newOrder: \"http://acme.test/orders/1\" is not an https URL" },
    { "/authz/1", "acme: challenge: \"http://acme.test/chall/1/1\" is not an https URL" },
    { "/finalize/1", "acme: certificate: \"http://acme.test/cert/1\" is not an https URL" },
  }
  for _, case in ipairs(cases) do
    local resource, expected = assert(case[1]), assert(case[2])
    local server = new_server()
    local followed = false
    local client = Acme.client({
      directory = BASE .. "/directory", key = Key.generate("p256"), pause = no_pause,
      request = function(method: string, url: string, o: Http.Options): Http.Body?, string
        assert(url:sub(1, 8) == "https://", "sent to " .. url)
        if o.follow ~= false then followed = true end
        local body = assert(server.request(method, url, o))
        -- "/directory nonce" makes newNonce's URL alone http.
        local at = assert(resource:match("^%S+"))
        local only = resource:match(" (%S+)$") or ""
        if url ~= BASE .. at then return body, "" end
        local plain = if only == "" then "https://" else BASE .. "/" .. only end
        local function down(text: string): string
          return (text:gsub(plain:gsub("%p", "%%%0"), (plain:gsub("^https", "http"))))
        end
        local headers: mut {string: string} = {}
        for k, v in pairs(body.headers) do headers[k] = down(v) end
        return { status = body.status, headers = headers, body = down(body.body) }, ""
      end,
    })
    local chain, why = client:issue({ "example.com" }, {
      key = Key.generate("p256"),
      present = function(_c: Acme.Challenge): boolean, string return true, "" end,
    })
    assert(chain == nil and why == expected, why)
    assert(not followed, "a request followed redirects")
  end
  local server = new_server()
  local plain = Acme.client({
    directory = "http://acme.test/directory", key = Key.generate("p256"), request = server.request,
  })
  local url, why = plain:account()
  assert(url == nil and why == "acme: directory: \"http://acme.test/directory\" is not an https URL", why)
  assert(#server.log == 0, "nothing is sent")
end

local function test_a_chain_not_for_the_key_and_the_names_asked_for_is_refused()
  local other = Key.generate("p256")
  local cases: {{string}} = {
    { "key", "acme: the issued certificate is not for the certificate's key" },
    { "fewer", "acme: the issued certificate names \"example.com\", not the names asked for, " ..
        "\"example.com www.example.com\"" },
    { "more", "acme: the issued certificate names \"evil.example example.com www.example.com\", " ..
        "not the names asked for, \"example.com www.example.com\"" },
    { "broken", "acme: the issued certificate cannot be read" },
    { "newline", "acme: the issued certificate names \"a\\nb.example\", not the names asked for, " ..
        "\"example.com www.example.com\"" },
  }
  for _, case in ipairs(cases) do
    local kind, expected = assert(case[1]), assert(case[2])
    local server = new_server()
    if kind == "key" then server.leaf_spki = other.public:spki() end
    if kind == "fewer" then server.leaf_names = { "example.com" } end
    if kind == "more" then
      server.leaf_names = { "www.example.com", "example.com", "evil.example" }
    end
    if kind == "newline" then server.leaf_names = { "a\nb.example" } end
    if kind == "broken" then
      server.chain = "-----BEGIN CERTIFICATE-----\nMAA=\n-----END CERTIFICATE-----\n"
    end
    local chain, why = issue_counted(server, { "example.com", "www.example.com" })
    assert(chain == nil and why == expected, why)
  end
  -- The names are a set, in any order and case.
  local server = new_server()
  server.leaf_names = { "WWW.example.com", "example.com", "example.com" }
  local chain, why = issue_counted(server, { "example.com", "www.example.com" })
  assert(chain ~= nil, why)
end

local function test_an_authorization_read_alone_refuses_a_token_that_is_not_base64url()
  local server = new_server()
  server.token_prefix = "../"
  local client = client_of(server)
  assert(client:account())
  local order = assert(client:order({ "example.com" }))
  local authorization, why = client:authorization(assert(order.authorizations[1]))
  assert(authorization == nil and why == "acme: the server's token for example.com is not base64url", why)
end
