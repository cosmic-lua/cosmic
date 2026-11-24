--- [`Tls.client`] over [`Net.connect`] and [`Net.Conn`]'s `start_tls`,
--- against [`Net.serve`]'s TLS listeners in the same run: what a client
--- verifies (the chain, a DNS name, an IP address, a pin), what it
--- takes where it verifies nothing, what the handshake settled as each
--- side sees it, and STARTTLS from both sides. The fixtures are
--- testdata/tls's; its README says how they were made.

local Array = require("cosmic.array")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local Tls = require("cosmic.tls")

Test.policy{ loopback = { "127.0.0.1" }, promises = { "fork" }, grants = { { path = "testdata/tls", letters = "r" } } }

--- The fixture `name` of testdata/tls.
local function fixture(name: string): string
  return (assert(Fs.read("testdata/tls/" .. name)))
end

local A <const>: Tls.Pair = { cert = fixture("a.pem"), key = fixture("a.key") }
local B <const>: Tls.Pair = { cert = fixture("b.pem"), key = fixture("b.key") }

--- A client that trusts testdata/tls's CA alone, with `opts` besides.
local function trusting(opts?: Tls.ClientOptions): Tls.Client
  local o: Tls.ClientOptions = opts or {}
  return (assert(Tls.client({
    roots = "none", ca = fixture("ca.pem"), alpn = o.alpn, pin = o.pin, verify = o.verify,
    identity = o.identity,
  })))
end

--- Serves `pair` over TLS at a port of 127.0.0.1, with ALPN offering
--- "h2" and "http/1.1", each connection answered with the version and
--- ALPN protocol its handshake settled and then what it sent, until it
--- ends; runs `body` with the port in a task of the server's run, and
--- stops the server once it returns.
local function served(pair: Tls.Pair, body: function(port: integer))
  assert(Net.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    tls = Tls.certs(Tls.static({ pair }), { alpn = { "h2", "http/1.1" } }),
    on_error = function(_: string) end,
    serve = function(conn: Net.Conn)
      if not conn:handshake() then return end
      local info = assert(conn:tls())
      local _, _ = conn:write(info.version .. " " .. (info.alpn or "-") .. " " .. (info.server_name or "-") .. "\n")
      while true do
        local data, _ = conn:read()
        if data == nil then return end
        local _, _ = conn:write(data)
      end
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local ok, trouble: boolean, any = pcall(body, assert(Array.at(addresses, 1).port))
      server:stop()
      assert(ok, tostring(trouble))
    end,
  })
end

--- What the server says first, and then `said` echoed, over `conn`.
local function round_trip(conn: Net.Conn, said: string): string
  assert(conn:write(said))
  local got = ""
  while not got:find(said, 1, true) do
    local data, why = conn:read()
    assert(data ~= nil, "read: " .. why)
    got = got .. data
  end
  return got
end

local function test_a_client_verifies_the_chain_and_the_name()
  served(A, function(port: integer)
    local conn <close> = assert(Net.connect(Net.tcp("127.0.0.1", port),
      { tls = trusting({ alpn = { "http/1.1" } }), server_name = "localhost" }))
    local said = round_trip(conn, "hello\n")
    assert(said == "TLSv1.3 http/1.1 localhost\nhello\n", said)
    local info = assert(conn:tls())
    assert(info.version == "TLSv1.3" and info.alpn == "http/1.1" and info.server_name == "localhost")
    local peer = assert(info.peer)
    assert(peer.verified, "verified")
    assert(peer.subject == "CN=localhost", peer.subject)
    assert(peer.issuer == "CN=cosmic test CA", peer.issuer)
    assert(#peer.names == 2 and peer.names[1] == "localhost" and peer.names[2] == "*.a.test")
    assert(#peer.addresses == 0 and #peer.uris == 0 and #peer.emails == 0)
    assert(peer.not_before_ns == 1767225600 * 1000000000, tostring(peer.not_before_ns))
    assert(peer.not_after_ns == 4922899200 * 1000000000, tostring(peer.not_after_ns))
    assert(#peer.sha256 == 64 and #peer.der > 0)
    assert(peer.pin:find("^sha256//") ~= nil and #peer.pin == 52, peer.pin)
  end)
end

local function test_a_wildcard_name_verifies_and_another_does_not()
  served(A, function(port: integer)
    local conn <close> = assert(Net.connect(Net.tcp("127.0.0.1", port),
      { tls = trusting(), server_name = "www.a.test" }))
    assert(round_trip(conn, "x") == "TLSv1.3 - www.a.test\nx")
    local none, why = Net.connect(Net.tcp("127.0.0.1", port), { tls = trusting(), server_name = "b.test" })
    assert(none == nil and tostring(why):find("is not trusted", 1, true) ~= nil and
        tostring(why):find("does not match", 1, true) ~= nil, why)
  end)
end

local function test_an_ip_address_is_verified_against_the_certificates_own()
  served(B, function(port: integer)
    -- No name: the address's host is verified against b.pem's IP SAN.
    local conn <close> = assert(Net.connect(Net.tcp("127.0.0.1", port), { tls = trusting() }))
    -- An address is sent as no name, so the server saw none.
    assert(round_trip(conn, "x") == "TLSv1.3 - -\nx")
    local info = assert(conn:tls())
    local peer = assert(info.peer)
    assert(info.server_name == "127.0.0.1" and peer.addresses[1] == "127.0.0.1" and peer.names[1] == "b.test")
  end)
  served(A, function(port: integer)
    local none, why = Net.connect(Net.tcp("127.0.0.1", port), { tls = trusting() })
    assert(none == nil and tostring(why):find("does not match", 1, true) ~= nil, why)
  end)
end

local function test_a_chain_to_no_trusted_root_is_refused()
  served(A, function(port: integer)
    -- b.pem signed a.pem no more than any root did.
    local client = assert(Tls.client({ roots = "none", ca = fixture("b.pem") }))
    local none, why = Net.connect(Net.tcp("127.0.0.1", port), { tls = client, server_name = "localhost" })
    assert(none == nil and tostring(why):find("^127%.0%.0%.1:%d+: tls: the peer's certificate is not trusted: ") ~= nil and
        tostring(why):find("not correctly signed", 1, true) ~= nil and tostring(why):find("opts.roots", 1, true) ~= nil, why)
  end)
end

local function test_a_client_that_verifies_nothing_takes_what_it_is_given()
  served(A, function(port: integer)
    local client = assert(Tls.client({ verify = false }))
    local conn <close> = assert(Net.connect(Net.tcp("127.0.0.1", port), { tls = client }))
    assert(round_trip(conn, "x") == "TLSv1.3 - -\nx")
    local peer = assert(assert(conn:tls()).peer)
    assert(not peer.verified and peer.subject == "CN=localhost")
  end)
end

local function test_a_pin_is_held_to_with_or_without_a_chain()
  served(A, function(port: integer)
    local plain = assert(Net.connect(Net.tcp("127.0.0.1", port), { tls = trusting(), server_name = "localhost" }))
    local pin = assert(assert(plain:tls()).peer).pin
    assert(plain:close())
    local other = "sha256//" .. string.rep("A", 43) .. "="
    local pinned <close> = assert(Net.connect(Net.tcp("127.0.0.1", port),
      { tls = assert(Tls.client({ verify = false, pin = { other, pin } })) }))
    assert(round_trip(pinned, "x") == "TLSv1.3 - -\nx")
    local none, why = Net.connect(Net.tcp("127.0.0.1", port),
      { tls = trusting({ pin = other }), server_name = "localhost" })
    assert(none == nil and tostring(why):find("the server's key is none of the pinned ones: it is " .. pin, 1, true) ~= nil, why)
  end)
end

local function test_starttls_secures_a_connection_from_both_sides()
  local certs = Tls.certs(Tls.static({ A }))
  assert(Net.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    serve = function(conn: Net.Conn)
      local asked, _ = Stream.read_exact(conn, 9)
      if asked ~= "STARTTLS\n" then return end
      assert(conn:write("GO\n"))
      assert(conn:serve_tls(certs))
      local info = assert(conn:tls())
      assert(conn:write("secured " .. info.version .. " " .. tostring(info.server_name) .. "\n"))
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local ok, trouble: boolean, any = pcall(function()
        local conn <close> = assert(Net.connect(Array.at(addresses, 1)))
        assert(conn:tls() == nil)
        assert(conn:write("STARTTLS\n"))
        assert(assert(Stream.read_exact(conn, 3)) == "GO\n")
        assert(conn:start_tls(trusting(), "localhost"))
        local said = assert(conn:read())
        assert(said == "secured TLSv1.3 localhost\n", said)
        assert(assert(assert(conn:tls()).peer).verified)
        Test.raises(function() local _, _ = conn:start_tls(trusting(), "localhost") end, "already over TLS")
      end)
      server:stop()
      assert(ok, tostring(trouble))
    end,
  })
end

local function test_a_failed_start_tls_leaves_the_connection_of_no_use()
  served(A, function(port: integer)
    local conn <close> = assert(Net.connect(Net.tcp("127.0.0.1", port)))
    local ok, why = conn:start_tls(trusting(), "elsewhere.test")
    assert(not ok and why:find("is not trusted", 1, true) ~= nil, why)
    local data, again = conn:read()
    assert(data == nil and again == why, again)
    local wrote, still = conn:write("x")
    assert(not wrote and still == why, still)
  end)
end

local function test_a_client_that_verifies_needs_a_name()
  served(A, function(port: integer)
    local conn <close> = assert(Net.connect(Net.tcp("127.0.0.1", port)))
    local ok, why = conn:start_tls(trusting())
    assert(not ok and why:find("needs a server name", 1, true) ~= nil, why)
    local none, long = Net.connect(Net.tcp("127.0.0.1", port), { tls = trusting(), server_name = string.rep("a", 256) })
    assert(none == nil and tostring(long):find("1 to 255 bytes", 1, true) ~= nil, long)
  end)
end

local function test_client_refuses_options_out_of_range()
  Test.raises(function() local _, _ = Tls.client({ pin = "x" }) end, "opts.pin[1] must be sha256//")
  Test.raises(function() local _, _ = Tls.client({ pin = {} }) end, "opts.pin must hold a pin")
  Test.raises(function() local _, _ = Tls.client({ roots = "most" }) end, "tls: opts.roots must be")
  -- Raised at the caller, which the message names.
  local raised, said: boolean, any = pcall(function()
    local _, _ = Tls.client({ roots = "most" })
  end)
  assert(not raised and tostring(said):find("tls_client_test", 1, true) ~= nil, tostring(said))
  Test.raises(function() local _, _ = Tls.client({ verify = false, ca = "x" }) end, "take no verify = false")
  Test.raises(function()
    local _, _ = Net.connect(Net.tcp("127.0.0.1", 1), { server_name = "x" })
  end, "there is no opts.tls")
  Test.raises(function() local _, _ = Tls.client({ alpn = { "" } }) end, "1 to 255 bytes")
  Test.raises(function()
    local _, _ = Tls.client({ alpn = { "a", "b", "c", "d", "e", "f", "g", "h", "i" } })
  end, "at most 8 protocols")
  local none, why = Tls.client({ roots = "none", ca = "not a certificate" })
  assert(none == nil and why:find("^tls: opts.ca: ") ~= nil, why)
  local mismatched, wrong = Tls.client({ verify = false, identity = { cert = A.cert, key = B.key } })
  assert(mismatched == nil and wrong:find("the identity's key, which is not the certificate's", 1, true) ~= nil, wrong)
  assert(Tls.client({ verify = false, identity = A }))
end

--- A TLS listener whose certificates are gone closes what it accepts
--- rather than serve it in the clear.
local function test_a_tls_listener_with_no_configuration_serves_nothing_in_the_clear()
  local certs = Tls.certs(Tls.static({ A }))
  local troubles: mut {string} = {}
  local served_plain = false
  assert(Net.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    tls = certs,
    on_error = function(trouble: string) troubles[#troubles + 1] = trouble end,
    serve = function(conn: Net.Conn)
      served_plain = true
      local _, _ = conn:write("plain\n")
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local ok, trouble: boolean, any = pcall(function()
        certs.current = nil
        local conn <close> = assert(Net.connect(Net.tcp("127.0.0.1", assert(Array.at(addresses, 1).port))))
        local data, _ = conn:read()
        assert(data == nil, tostring(data))
      end)
      server:stop()
      assert(ok, tostring(trouble))
    end,
  })
  assert(not served_plain)
  local said = table.concat(troubles, "\n")
  assert(#troubles == 1 and said:find("no certificates are loaded", 1, true) ~= nil, said)
end

--- A TLS client that closes is gone to the server at once, though the
--- close_notify it sent first is still unread; while it is there and
--- quiet, it is not.
local function test_a_tls_client_that_closes_is_gone()
  local seen = { before = true, after = false }
  local closed_ns, seen_ns = 0, 0
  assert(Net.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    tls = Tls.certs(Tls.static({ A })),
    on_error = function(_: string) end,
    serve = function(conn: Net.Conn)
      if not conn:handshake() then return end
      assert(conn:write("hi\n"))
      assert(Clock.sleep(Clock.ms(100)))
      seen.before = conn:gone()
      local until_ns = Clock.monotonic_ns() + Clock.seconds(3)
      while Clock.monotonic_ns() < until_ns do
        if conn:gone() then
          seen.after, seen_ns = true, Clock.monotonic_ns()
          return
        end
        assert(Clock.sleep(Clock.ms(10)))
      end
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local conn = assert(Net.connect(Net.tcp("127.0.0.1", assert(Array.at(addresses, 1).port)),
        { tls = trusting(), server_name = "localhost" }))
      assert(conn:read() == "hi\n")
      assert(Clock.sleep(Clock.ms(200)))
      closed_ns = Clock.monotonic_ns()
      assert(conn:close())
      local until_ns = closed_ns + Clock.seconds(2)
      while not seen.after and Clock.monotonic_ns() < until_ns do
        assert(Clock.sleep(Clock.ms(10)))
      end
      server:stop()
    end,
  })
  assert(not seen.before, "a quiet client read as gone")
  assert(seen.after, "the server never saw the client go")
  assert(seen_ns - closed_ns < Clock.seconds(1), tostring(seen_ns - closed_ns))
end
