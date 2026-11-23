--- [`Acme.auto`] against the fake ACME server of build/acme_fixture.tl,
--- whose check of an http-01 challenge fetches the response from the
--- server under test, at its `clear` listener, while that server waits
--- for its first certificate. The certificate the fake CA hands back is
--- testdata/tls's `d.pem`, for `localhost` alone and signed by its own
--- key, `a.key`, so the test gives [`Acme.auto`] that key and its client
--- trusts `d.pem` itself.

local Acme = require("cosmic.acme")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Signal = require("cosmic.signal")
local Stream = require("cosmic.stream")
local Tls = require("cosmic.tls")
local sys = require("cosmic.sys")
local Server = require("cosmic.http.server")
local Sign = require("cosmic.sign")
local Test = require("cosmic.test")
local acme_fixture = require("build.acme_fixture")

Test.policy{ loopback = { "127.0.0.1" }, grants = { { path = "testdata/tls", letters = "r" } } }

local BASE <const> = acme_fixture.BASE
local type FakeCa = acme_fixture.Server

--- How long a request here waits for what the server never fails to do.
local WAIT <const> = Clock.seconds(20)

--- The fixture `name` of testdata/tls.
local function fixture(name: string): string
  return (assert(Fs.read("testdata/tls/" .. name)))
end

--- A port of 127.0.0.1 nothing listens at: listened at, then closed.
local function free_port(): integer
  local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  local port = assert(listener.address.port)
  assert(listener:close())
  return port
end

--- A fake CA that issues `d.pem` once its check of each http-01
--- challenge fetches the right response from 127.0.0.1 at `port`.
local function fake_ca(port: integer): FakeCa
  local ca = acme_fixture.new_server()
  ca.chain = fixture("d.pem")
  ca.check = function(_domain: string, token: string): string
    local got = Http.get("http://127.0.0.1:" .. tostring(port) .. "/.well-known/acme-challenge/" .. token,
      { timeout_ns = WAIT })
    if got == nil or got.status ~= 200 then return "invalid" end
    if got.body:sub(1, #token + 1) ~= token .. "." then return "invalid" end
    return "valid"
  end
  return ca
end

--- An Auto for `localhost` in `dir`, issuing from `ca`.
local function auto_of(dir: string, ca: FakeCa, names?: {string}): Acme.Auto
  return Acme.auto({
    names = names or { "localhost" }, dir = dir, terms_agreed = true,
    directory = BASE .. "/directory", request = ca.request, pause = acme_fixture.no_pause,
    key = assert(Acme.read_key(fixture("a.key"))),
  })
end

--- What a server of `auto` answered, once it served: the body over
--- HTTPS, and the clear listener's answer to a plain request.
local record Served
  mut https: string
  mut redirect: string
  mut ready: boolean
end

--- Serves `auto` at a TLS port and the clear port `clear_port` until
--- one HTTPS request and one plain one have been made; answers what
--- they saw, and what [`Server.serve`] answered.
local function serve(auto: Acme.Auto, clear_port: integer): Served, boolean, string
  local served: Served = { https = "", redirect = "", ready = false }
  local ok, why = Server.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    clear = { Net.tcp("127.0.0.1", clear_port) },
    tls = auto.certs,
    handle = auto:handler(function(_req: Server.Request): Server.Reply
      return { status = 200, body = "over tls" }
    end),
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      served.ready = true
      local port = assert(addresses[1]).port
      local got = assert(Http.get("https://localhost:" .. tostring(port) .. "/", { ca = fixture("d.pem"), timeout_ns = WAIT }))
      served.https = got.body
      local plain = assert(Http.get("http://127.0.0.1:" .. tostring(clear_port) .. "/a?b=1",
        { follow = false, timeout_ns = WAIT }))
      served.redirect = tostring(plain.status) .. " " .. tostring(plain.headers["location"])
      server:stop()
    end,
  }
  return served, ok, why
end

local function test_a_first_start_issues_while_the_clear_listener_answers_the_check(tmp: string)
  local dir = tmp .. "/acme"
  local port = free_port()
  local served, ok, why = serve(auto_of(dir, fake_ca(port)), port)
  assert(ok, why)
  assert(served.https == "over tls", served.https)
  assert(served.redirect == "308 https://127.0.0.1/a?b=1", served.redirect)
  local kept = assert(Fs.read(dir .. "/certificate.pem"))
  assert(kept:find("-----BEGIN CERTIFICATE-----", 1, true) == 1 and kept:find("PRIVATE KEY", 1, true) ~= nil)
  assert((assert(Fs.stat(dir .. "/certificate.pem")).mode & 0x1ff) == 0x180)
  assert((assert(Fs.stat(dir .. "/account.pem")).mode & 0x1ff) == 0x180)
  assert((assert(Fs.stat(dir)).mode & 0x1ff) == 0x1c0)
end

local function test_a_restart_serves_the_kept_certificate_and_asks_the_ca_nothing(tmp: string)
  local dir = tmp .. "/acme"
  local port = free_port()
  local _, ok, why = serve(auto_of(dir, fake_ca(port)), port)
  assert(ok, why)
  local silent = acme_fixture.new_server()
  silent.request = function(_m: string, url: string, _o: Http.Options): Http.Body?, string
    error("the CA was asked for " .. url)
  end
  local again = free_port()
  local served, restarted, trouble = serve(auto_of(dir, silent), again)
  assert(restarted, trouble)
  assert(served.https == "over tls", served.https)
end

local function test_a_kept_certificate_that_misses_a_name_is_issued_again(tmp: string)
  local dir = tmp .. "/acme"
  local port = free_port()
  local _, ok, why = serve(auto_of(dir, fake_ca(port)), port)
  assert(ok, why)
  local kept = assert(Fs.read(dir .. "/certificate.pem"))
  -- `d.pem` names localhost alone, not other.test.
  local asked = false
  -- Loaded with no server, so nothing answers a check: the CA passes it.
  local ca = fake_ca(port)
  ca.check = function(_domain: string, _token: string): string return "valid" end
  local request = ca.request
  ca.request = function(m: string, url: string, o: Http.Options): Http.Body?, string
    asked = true
    return request(m, url, o)
  end
  local auto = auto_of(dir, ca, { "localhost", "other.test" })
  local loaded, refused = auto.certs:load()
  assert(asked, "the CA was not asked")
  -- The fake CA hands back `d.pem` all the same, which is refused and
  -- not kept in place of the one there.
  assert(not loaded and refused:find("not the names asked for", 1, true) ~= nil, refused)
  assert(assert(Fs.read(dir .. "/certificate.pem")) == kept, "the kept certificate was written over")
end

local function test_a_check_that_fails_fails_the_serve_before_it_is_ready(tmp: string)
  local dir = tmp .. "/acme"
  local port = free_port()
  local ca = fake_ca(port)
  ca.check = function(_domain: string, _token: string): string return "invalid" end
  local served, ok, why = serve(auto_of(dir, ca), port)
  assert(not ok)
  assert(why:find("invalid", 1, true) ~= nil, why)
  assert(not served.ready, "on_ready ran though no certificate was loaded")
  assert(not assert(Fs.status(dir .. "/certificate.pem")).exists)
end

--- A request as a server hands it over, for the handler alone.
local function request_of(path: string, host?: string, query?: string, tls?: boolean): Server.Request
  local headers: mut {string: string} = {}
  if host ~= nil then headers["host"] = host end
  local req: Server.Request = {
    method = "GET", target = path, path = path, query = query or "", version = "HTTP/1.1",
    headers = headers, body = Stream.from_string(""), length = 0,
    tls = if tls == true then { version = "TLSv1.3" } else nil end,
  }
  return req
end

local function test_the_handler_redirects_in_the_clear_and_hands_tls_on(tmp: string)
  local auto = auto_of(tmp .. "/acme", acme_fixture.new_server())
  local handle = auto:handler(function(_req: Server.Request): Server.Reply
    return { status = 204 }
  end)
  local function location(host?: string): string
    local reply = handle(request_of("/x", host))
    return tostring(reply.status) .. " " .. tostring((reply.headers or {})["Location"])
  end
  assert(location("example.com") == "308 https://example.com/x")
  assert(location("example.com:8080") == "308 https://example.com/x")
  assert(location("[::1]:80") == "308 https://[::1]/x")
  assert(handle(request_of("/x")).status == 400)
  assert(handle(request_of("/x", "a b")).status == 400)
  assert(handle(request_of("/x", "example.com:80x")).status == 400)
  assert(handle(request_of("/x", "example.com", "", true)).status == 204)
  assert(auto:answer("/.well-known/acme-challenge/none") == nil)
  local bare = auto:handler()
  assert(bare(request_of("/x", "example.com", "", true)).status == 404)
end

local function test_auto_refuses_options_out_of_shape()
  local ok, why = pcall(Acme.auto, { names = {}, dir = "d", terms_agreed = true })
  assert(not ok and tostring(why):find("names", 1, true) ~= nil, tostring(why))
  ok, why = pcall(Acme.auto, { names = { "a.test" }, dir = "", terms_agreed = true })
  assert(not ok and tostring(why):find("dir", 1, true) ~= nil, tostring(why))
end

local function test_clear_without_tls_is_refused()
  local ok, why = pcall(function()
    local _, _ = Net.serve({
      listeners = { Net.tcp("127.0.0.1", 0) }, clear = { Net.tcp("127.0.0.1", 0) },
      serve = function(_conn: Net.Conn) end,
    })
  end)
  assert(not ok and tostring(why):find("spec.clear", 1, true) ~= nil, tostring(why))
end

local function test_web_serve_takes_an_auto_as_its_acme(tmp: string)
  local Web = require("cosmic.web")
  local port = free_port()
  local auto = auto_of(tmp .. "/acme", fake_ca(port))
  local app = Web.app{
    routes = { Web.get("/", function(_req: Web.Request): Web.Response
      return Web.text("from the app")
    end) },
  }
  local seen = ""
  assert(Web.serve(app, {
    acme = auto,
    listeners = { Net.tcp("127.0.0.1", 0) },
    clear = { Net.tcp("127.0.0.1", port) },
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local tls_port = assert(addresses[1]).port
      local got = assert(Http.get("https://localhost:" .. tostring(tls_port) .. "/", { ca = fixture("d.pem"), timeout_ns = WAIT }))
      local plain = assert(Http.get("http://127.0.0.1:" .. tostring(port) .. "/", { follow = false, timeout_ns = WAIT }))
      seen = got.body .. " " .. tostring(plain.status)
      server:stop()
    end,
  }))
  assert(seen == "from the app 308", seen)
  local ok, why = pcall(Web.serve, app, { acme = auto, tls = auto.certs })
  assert(not ok and tostring(why):find("one of acme, tls and tailnet", 1, true) ~= nil, tostring(why))
end

local function test_a_kept_certificate_with_another_key_is_issued_again(tmp: string)
  local dir = tmp .. "/acme"
  assert(Fs.mkdirs(dir, 0x1c0))
  assert(Fs.write(dir .. "/certificate.pem", fixture("a.pem") .. fixture("b.key"), 0x180))
  local asked = false
  local ca = fake_ca(free_port())
  ca.check = function(_domain: string, _token: string): string return "valid" end
  local request = ca.request
  ca.request = function(m: string, url: string, o: Http.Options): Http.Body?, string
    asked = true
    return request(m, url, o)
  end
  local loaded, why = auto_of(dir, ca).certs:load()
  assert(loaded, why)
  assert(asked, "the CA was not asked")
end

--- A SIGTERM while the first load waits stops the server cleanly: true,
--- `on_stop` called and `on_ready` not, as for a stop at any other time.
local function test_a_signal_during_the_first_load_is_a_clean_stop()
  local stopped = false
  local ready = false
  local certs = Tls.certs(function(_min?: integer): {Tls.Pair}?, string
    assert(sys.kill(sys.getpid(), sys.SIGTERM))
    local _, _ = Poll.delay(Clock.seconds(30))
    return nil, "the source gave up"
  end)
  -- Released below: the server's guard does not deliver it again.
  local outer <close> = assert(Signal.guard())
  local ok, why = Net.serve{
    listeners = { Net.tcp("127.0.0.1", 0) }, clear = { Net.tcp("127.0.0.1", 0) }, tls = certs,
    serve = function(_conn: Net.Conn) end,
    on_ready = function(_a: {Net.Address}, _s: Net.Server) ready = true end,
    on_stop = function(_s: Net.Server) stopped = true end,
  }
  assert(ok, why)
  assert(stopped and not ready, tostring(stopped) .. " " .. tostring(ready))
  do
    local got, _ = outer:release()
    assert(got == sys.SIGTERM)
  end
end

--- An account key there, made by another process however lately, is
--- the account: read, and never written over.
local function test_an_account_key_there_is_the_account_and_kept(tmp: string)
  local dir = tmp .. "/acme"
  assert(Fs.mkdirs(dir, 0x1c0))
  local account = Acme.p256_key(Sign.p256_secret())
  assert(Fs.write(dir .. "/account.pem", assert(account.pem), 0x180))
  local ca = fake_ca(free_port())
  ca.check = function(_domain: string, _token: string): string return "valid" end
  local loaded, why = auto_of(dir, ca).certs:load()
  assert(loaded, why)
  assert(assert(Fs.read(dir .. "/account.pem")) == account.pem, "the account key was written over")
  local seen = assert(ca.account)
  assert(seen["x"] == account.jwk["x"] and seen["y"] == account.jwk["y"], "another account was made")
end
