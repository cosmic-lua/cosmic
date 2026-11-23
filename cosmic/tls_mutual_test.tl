--- Mutual TLS: a server whose [`Tls.certs`] asks clients for a
--- certificate ([`Tls.CertsOptions.clients`]), a [`Tls.client`] that
--- presents one (`identity`), what each side sees of the other, and
--- [`Web.require_client_cert`] over HTTPS. The fixtures are
--- testdata/tls's; its README says how they were made.

local Array = require("cosmic.array")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local Tls = require("cosmic.tls")
local Web = require("cosmic.web")

Test.policy{ loopback = { "127.0.0.1" }, grants = { { path = "testdata/tls", letters = "r" } } }

--- The fixture `name` of testdata/tls.
local function fixture(name: string): string
  return (assert(Fs.read("testdata/tls/" .. name)))
end

local A <const>: Tls.Pair = { cert = fixture("a.pem"), key = fixture("a.key") }
local CLIENT <const>: Tls.Pair = { cert = fixture("client.pem"), key = fixture("client.key") }

--- A client that trusts testdata/tls's CA, presenting `identity`.
local function presenting(identity?: Tls.Pair): Tls.Client
  return (assert(Tls.client({ roots = "none", ca = fixture("ca.pem"), identity = identity })))
end

--- The certificates of `A`, asking clients for theirs as `clients` says.
local function asking(clients: Tls.Clients): Tls.Certs
  return Tls.certs(Tls.static({ A }), { clients = clients })
end

--- What the server says of its client: "none", or its subject, URI,
--- email and whether it verified.
local function described(info?: Tls.Info): string
  local peer = if info ~= nil then info.peer else nil end
  if peer == nil then return "none" end
  return peer.subject .. " " .. (peer.uris[1] or "-") .. " " .. (peer.emails[1] or "-") .. " " ..
    tostring(peer.verified)
end

--- Serves `certs` at a port of 127.0.0.1, each connection answered with
--- what the server saw of its client once the handshake is done; runs
--- `body` with the port in a task of the server's run, and stops the
--- server once it returns. What a handshake failed with goes to
--- `failures`.
local function served(certs: Tls.Certs, failures: mut {string}, body: function(port: integer))
  assert(Net.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    tls = certs,
    on_error = function(_: string) end,
    serve = function(conn: Net.Conn)
      local done, why = conn:handshake()
      if not done then
        failures[#failures + 1] = why
        return
      end
      local _, _ = conn:write(described(conn:tls()) .. "\n")
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local ok, trouble: boolean, any = pcall(body, assert(Array.at(addresses, 1).port))
      server:stop()
      assert(ok, tostring(trouble))
    end,
  })
end

--- What the server answers a client of `client` at `port`: its line, or
--- "failed: " and why.
local function answer(port: integer, client: Tls.Client): string
  local conn, why = Net.connect(Net.tcp("127.0.0.1", port), { tls = client, server_name = "localhost" })
  if conn == nil then return "failed: " .. why end
  local said, lost = Stream.read_all(conn)
  local _, _ = conn:close()
  if said == nil then return "failed: " .. tostring(lost) end
  if said == "" then return "failed: the server said nothing" end
  return said
end

local function test_a_required_certificate_is_verified_and_seen_by_the_server()
  local failures: mut {string} = {}
  served(asking({ ca = fixture("client-ca.pem") }), failures, function(port: integer)
    local said = answer(port, presenting(CLIENT))
    assert(said == "CN=cosmic test client spiffe://cosmic.test/client client@cosmic.test true\n", said)
  end)
  assert(#failures == 0, table.concat(failures, "; "))
end

local function test_a_required_certificate_refuses_a_client_without_one()
  local failures: mut {string} = {}
  served(asking({ ca = fixture("client-ca.pem") }), failures, function(port: integer)
    -- TLS 1.3 ends the handshake for the client before the server reads
    -- its certificate: the refusal comes at its first read.
    local said = answer(port, presenting())
    assert(said:find("^failed: ") ~= nil, said)
  end)
  assert(#failures == 1, table.concat(failures, "; "))
end

local function test_a_required_certificate_refuses_one_of_another_ca()
  local failures: mut {string} = {}
  -- The server's own CA, which signed no client certificate here.
  served(asking({ ca = fixture("ca.pem") }), failures, function(port: integer)
    local said = answer(port, presenting(CLIENT))
    assert(said:find("^failed: ") ~= nil, said)
  end)
  assert(#failures == 1 and Array.at(failures, 1):find("is not trusted", 1, true) ~= nil,
    table.concat(failures, "; "))
end

local function test_an_optional_certificate_serves_clients_with_and_without()
  local failures: mut {string} = {}
  served(asking({ ca = fixture("ca.pem"), required = false }), failures, function(port: integer)
    assert(answer(port, presenting()) == "none\n")
    -- Presented but not verified: the session goes on, the peer marked so.
    local said = answer(port, presenting(CLIENT))
    assert(said == "CN=cosmic test client spiffe://cosmic.test/client client@cosmic.test false\n", said)
  end)
  assert(#failures == 0, table.concat(failures, "; "))
end

local function test_a_certificate_not_for_client_authentication_is_refused()
  local failures: mut {string} = {}
  -- a.pem is for serverAuth alone, and signed by ca.pem.
  served(asking({ ca = fixture("ca.pem") }), failures, function(port: integer)
    local said = answer(port, presenting(A))
    assert(said:find("^failed: ") ~= nil, said)
  end)
  assert(#failures == 1 and Array.at(failures, 1):find("extendedKeyUsage", 1, true) ~= nil, table.concat(failures, "; "))
end

local function test_certs_refuses_clients_without_roots()
  Test.raises(function() local _ = Tls.certs(Tls.static({ A }), { clients = { ca = "" } }) end,
    "opts.clients.ca must be")
  local certs = Tls.certs(Tls.static({ A }), { clients = { ca = "not a certificate" } })
  local ok, why = certs:load()
  assert(not ok and why:find("the roots", 1, true) ~= nil, why)
end

--- GET / over HTTPS from a client of `client` to `port`: the status
--- line and the body, or "failed: " and why.
local function fetched(port: integer, client: Tls.Client): string
  local conn, why = Net.connect(Net.tcp("127.0.0.1", port), { tls = client, server_name = "localhost" })
  if conn == nil then return "failed: " .. why end
  assert(conn:write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))
  local said, lost = Stream.read_all(conn)
  local _, _ = conn:close()
  if said == nil then return "failed: " .. tostring(lost) end
  local status = said:match("^HTTP/1%.1 (%d+)") or "?"
  return status .. " " .. (said:match("\r\n\r\n(.*)$") or "")
end

local function test_require_client_cert_admits_the_clients_it_accepts()
  local app = Web.app{
    routes = {
      Web.get("/", function(req: Web.Request): Web.Response
        return Web.text("hello " .. Array.at(assert(Web.client_cert(req)).uris, 1))
      end),
    },
    middleware = { Web.require_client_cert(function(peer: Tls.Peer): boolean
      return peer.uris[1] == "spiffe://cosmic.test/client"
    end) },
  }
  local strict = Web.app{
    routes = { Web.get("/", function(_: Web.Request): Web.Response return Web.text("in") end) },
    middleware = { Web.require_client_cert(function(_: Tls.Peer): boolean return false end) },
  }
  local record Case
    app: Web.App
    who: string
    want: string
    roots: string
  end
  local cases: {Case} = {
    { app = app, who = "client", want = "200 hello spiffe://cosmic.test/client", roots = "client-ca.pem" },
    { app = app, who = "none", want = "403", roots = "client-ca.pem" },
    { app = strict, who = "client", want = "403", roots = "client-ca.pem" },
    -- Presented, and served, but not verified: no certificate to the app.
    { app = app, who = "client", want = "403", roots = "ca.pem" },
  }
  for _, case in ipairs(cases) do
    local served_app, who, want = case.app, case.who, case.want
    assert(Web.serve(served_app, {
      listeners = { Net.tcp("127.0.0.1", 0) },
      tls = asking({ ca = fixture(case.roots), required = false }),
      on_ready = function(addresses: {Net.Address}, server: Net.Server)
        local ok, trouble: boolean, any = pcall(function()
          local identity = if who == "client" then CLIENT else nil end
          local got = fetched(assert(Array.at(addresses, 1).port), presenting(identity))
          assert(got:sub(1, #want) == want, who .. ": " .. got)
        end)
        server:stop()
        assert(ok, tostring(trouble))
      end,
    }))
  end
end
