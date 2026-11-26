--- HTTPS from [`Server.serve`] and [`Web.serve`] with `tls`, to
--- [`cosmic.http`]'s client in a child of this program, which trusts
--- testdata/tls's CA: the pair a client's name chooses, ECDSA and RSA
--- keys alike, what the handshake settled as the handler sees it, and a
--- client in the clear refused without stopping the server. The last
--- test asks a stand-in tailscaled, over TCP, where `tailnet` serves.

local Array = require("cosmic.array")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Server = require("cosmic.http.server")
local Test = require("cosmic.test")
local Tailnet = require("cosmic.web.tailnet")
local Tailscale = require("cosmic.tailscale")
local Tls = require("cosmic.tls")
local Web = require("cosmic.web")
local _ = require("build.standalone")
--- What the client script requires, as in cosmic/http_tool_test.tl.
local type _ = require("cosmic.http")
local type Stream = require("cosmic.stream")

--- The next chunk of `reader`: raises where it ended or failed.
local function chunk_of(reader: Stream.Reader, max_bytes?: integer): string
  local chunk, why = reader:read(max_bytes)
  if chunk == nil then error(tostring(why), 2) end
  if chunk == false then error("the stream ended", 2) end
  return chunk
end

Test.policy{
  profiles = { "cosmic" }, loopback = { "127.0.0.1" },
  grants = { { path = "testdata/tls", letters = "r" } },
}

--- The fixture `name` of testdata/tls.
local function fixture(name: string): string
  return (assert(Fs.read("testdata/tls/" .. name)))
end

local A <const>: Tls.Pair = { cert = fixture("a.pem"), key = fixture("a.key") }
local B <const>: Tls.Pair = { cert = fixture("b.pem"), key = fixture("b.key") }

--- A client that GETs each URL after the first argument, the CA's file,
--- trusting the CA alone, and prints a line for each: the status and
--- the body, or "failed: " and why.
local CLIENT <const> = [[
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
return function(argv: {string}): integer
  local ca = assert(Fs.read(argv[1] or ""))
  local said: mut {string} = {}
  for i = 2, #argv do
    local got, why = Http.get(argv[i] or "", { ca = ca, roots = "none", timeout_ns = 20000000000 })
    said[#said + 1] = if got ~= nil then tostring(got.status) .. " " .. got.body else "failed: " .. tostring(why) end
  end
  local _, _ = Fs.put(Fs.stdout, table.concat(said, "\n"))
  return 0
end
]]

--- Runs the client script against the server at `port` of 127.0.0.1,
--- for each of `hosts` ("localhost" or "127.0.0.1"), and returns what
--- it printed.
local function fetched(tmp: string, port: integer, hosts: {string}): string
  local script = tmp .. "/client.tl"
  assert(Fs.write(script, CLIENT))
  assert(Fs.write(tmp .. "/ca.pem", fixture("ca.pem")))
  local argv: mut {string} = { "--standalone", script, tmp .. "/ca.pem" }
  for _, host in ipairs(hosts) do
    argv[#argv + 1] = "https://" .. host .. ":" .. tostring(port) .. "/"
  end
  local started = Test.cosmic(argv, { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(90) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 0, tostring(result.code) .. " " .. tostring(result.stderr))
  return assert(result.stdout)
end

--- The version the handshake settled and the name the client asked
--- for, as a handler sees them.
local function settled(req: Server.Request): Server.Reply
  local tls = req.tls
  if tls == nil then return { status = 500, body = "in the clear" } end
  return { status = 200, body = tls.version .. " " .. (tls.server_name or "-") }
end

--- A client naming `localhost` is served the second pair, the one whose
--- leaf names it (ECDSA), though the first (RSA) would suit it too; an
--- RSA pair alone serves a client of 127.0.0.1, which its leaf names
--- as an IP address.
local function test_the_name_a_client_asks_for_chooses_the_pair_and_an_rsa_key_serves(tmp: string)
  local record Case
    served: {Tls.Pair}
    host: string
  end
  local cases: {Case} = { { served = { B, A }, host = "localhost" }, { served = { B }, host = "127.0.0.1" } }
  local said: mut {string} = {}
  for _, case in ipairs(cases) do
    assert(Server.serve{
      listeners = { Net.tcp("127.0.0.1", 0) },
      tls = Tls.certs(Tls.static(case.served)),
      handle = settled,
      on_ready = function(addresses: {Net.Address}, server: Net.Server)
        local got = fetched(tmp, assert(Array.at(addresses, 1).port), { case.host })
        said[#said + 1] = got
        server:stop()
      end,
    })
  end
  local got = table.concat(said, "\n")
  -- cosmic.http names an IP address as the host too, which RFC 6066
  -- does not have it do, and no leaf names as a DNS name.
  assert(got == "200 TLSv1.3 localhost\n200 TLSv1.3 127.0.0.1", got)
end

--- With the one pair, a client of 127.0.0.1 is served it too, and
--- refuses it, as its leaf does not name the address; a client in the
--- clear gets no response, and the server serves the next client all
--- the same.
local function test_the_first_pair_is_served_without_a_name_and_a_clear_client_is_refused(tmp: string)
  local said = ""
  local clear = ""
  assert(Server.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    tls = Tls.certs(Tls.static({ A })),
    handle = settled,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local port = assert(Array.at(addresses, 1).port)
      local conn <close> = assert(Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = Clock.seconds(20) }))
      assert(conn:write("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"))
      local got, why = conn:read()
      clear = tostring(got) .. " " .. tostring(why)
      said = fetched(tmp, port, { "127.0.0.1", "localhost" })
      server:stop()
    end,
  })
  -- The server's alert, or nothing: never an HTTP reply.
  assert(clear:find("HTTP/", 1, true) == nil, clear)
  assert(said:find("^failed: [^\n]*CN[^\n]*\n200 TLSv1.3 localhost$") ~= nil, said)
end

--- A source that fails fails the serve before it listens, saying why.
local function test_a_source_that_fails_fails_the_serve()
  local ok, why = Server.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    tls = Tls.certs(function(_?: integer): {Tls.Pair}?, string return nil, "no certificate yet" end),
    handle = settled,
    on_ready = function(_: {Net.Address}, server: Net.Server) server:stop() end,
  }
  assert(not ok and tostring(why) == "no certificate yet", tostring(why))
end

--- [`Web.serve`] with `tls` serves the app over HTTPS, and a request's
--- scheme says so.
local function test_web_serve_with_tls_says_its_scheme_is_https(tmp: string)
  local app = Web.app{ routes = { Web.get("/", function(req: Web.Request): Web.Response
    return Web.text(req.scheme)
  end) } }
  local said = ""
  assert(Web.serve(app, {
    listeners = { Net.tcp("127.0.0.1", 0) },
    tls = Tls.certs(Tls.static({ A })),
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      said = fetched(tmp, assert(Array.at(addresses, 1).port), { "localhost" })
      server:stop()
    end,
  }))
  assert(said == "200 https", said)
end

--- A stand-in daemon's status: a node at 127.0.0.1 named `localhost`,
--- in `state`.
local function status_of(state: string): string
  return '{"Version": "1.90.0", "BackendState": "' .. state .. '", "TailscaleIPs": ["127.0.0.1"], ' ..
    '"Self": {"ID": "nSELF", "HostName": "box", "DNSName": "localhost.", "OS": "linux", "UserID": 42, ' ..
    '"TailscaleIPs": ["127.0.0.1"], "Online": true, "Active": false, "ExitNode": false, ' ..
    '"ExitNodeOption": false, "Relay": "", "CurAddr": "", "LastSeen": "0001-01-01T00:00:00Z"}, ' ..
    '"Health": null, "MagicDNSSuffix": "ts.net", "CurrentTailnet": {"Name": "example.com", ' ..
    '"MagicDNSSuffix": "ts.net", "MagicDNSEnabled": true}, "CertDomains": ["localhost"], "Peer": {}, "User": {}}'
end

--- Where [`Web.serve`]'s `tailnet` serves: each of the node's addresses
--- at the port, with the certificate of its first name, which the
--- daemon is asked for once the certificates load; a renewal asks for
--- leaves valid long enough. A node not running serves nowhere.
local function test_tailnet_serving_listens_at_the_nodes_addresses_with_its_certificate()
  local pair = A.key .. A.cert
  local state = "Running"
  local asked: mut {string} = {}
  local said: mut {string} = {}
  assert(Server.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    on_stop = function(_: Net.Server) end,
    handle = function(req: Server.Request): Server.Reply
      asked[#asked + 1] = req.target
      if req.target == "/localapi/v0/status" then
        return { status = 200, body = status_of(state) }
      end
      if req.target:match("^/localapi/v0/cert/localhost%?type=pair") ~= nil then
        return { status = 200, body = pair }
      end
      return { status = 404, body = "no\n" }
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local ts = assert(Tailscale.connect({ port = assert(Array.at(addresses, 1).port), token = "t",
        timeout_ns = Clock.seconds(5) }))
      local reached = assert(Tailnet.serving({ client = ts, port = 0 }))
      local listener = Array.at(reached.listeners, 1)
      local where = tostring(#reached.listeners) .. " " .. tostring(listener.host) .. ":" .. tostring(listener.port)
      said[#said + 1] = where
      local certs = assert(reached.certs)
      assert(certs:load())
      local name = Array.at(certs:leaves(), 1).names[1] or ""
      said[#said + 1] = name
      -- The client's own source, with no name: it asks the status first.
      local own = ts:certs()
      assert(own:load(Clock.hours(24)))
      state = "Stopped"
      local _, refused = Tailnet.serving({ client = ts })
      local why = tostring(refused)
      said[#said + 1] = why
      server:stop()
    end,
  })
  local got = table.concat(said, "|")
  assert(got == "1 127.0.0.1:0|localhost|web: tailnet: the node is not running (Stopped)", got)
  local targets = table.concat(asked, " ")
  assert(targets == "/localapi/v0/status /localapi/v0/cert/localhost?type=pair /localapi/v0/status " ..
      "/localapi/v0/cert/localhost?type=pair&min_validity=86400s /localapi/v0/status", targets)
end

--- A client that sends a handshake a byte at a time is closed once the
--- connection's idle time is out, however steadily its bytes come: the
--- wait for a record bounds the whole read, not each byte.
local function test_a_handshake_sent_a_byte_at_a_time_is_cut_off()
  local lasted = 0
  assert(Server.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    tls = Tls.certs(Tls.static({ A })),
    idle_ns = Clock.ms(500),
    handle = settled,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local port = assert(Array.at(addresses, 1).port)
      local conn <close> = assert(Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = Clock.seconds(5) }))
      local started = Clock.monotonic_ns()
      -- A handshake record's header, saying 512 bytes follow.
      assert(conn:write("\x16\x03\x01\x02\x00"))
      for _ = 1, 40 do
        local _, _ = Clock.sleep(Clock.ms(100))
        local _, _ = conn:write("\x01")
        conn:set_timeout(Clock.ms(1))
        local got, why = conn:read()
        if got ~= nil or why.kind ~= "timeout" then break end
      end
      lasted = Clock.monotonic_ns() - started
      server:stop()
    end,
  })
  assert(lasted < Clock.seconds(2), "the dripping client was held " .. tostring(lasted // 1000000) .. " ms")
end

--- A peer that never finishes its hello is closed at `handshake_ns`
--- unserved, though the server sets no `timeout_ns`: a read's limit
--- would hold it for ever.
local function test_a_stalled_handshake_is_closed_unserved()
  local served = false
  local lasted = 0
  local ended = ""
  assert(Net.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    tls = Tls.certs(Tls.static({ A })),
    handshake_ns = Clock.ms(300),
    serve = function(_: Net.Conn) served = true end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local port = assert(Array.at(addresses, 1).port)
      local conn <close> = assert(Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = Clock.seconds(10) }))
      local started = Clock.monotonic_ns()
      -- A handshake record's header, saying 512 bytes follow, and no more.
      assert(conn:write("\x16\x03\x01\x02\x00"))
      local got, why = conn:read()
      lasted = Clock.monotonic_ns() - started
      ended = tostring(got) .. " " .. tostring(why)
      server:stop()
    end,
  })
  assert(not served, "a connection with no handshake was served")
  assert(lasted < Clock.seconds(5), "the stalled client was held " .. tostring(lasted // 1000000) .. " ms: " .. ended)
end

--- A protocol of [`Net.serve`] that handshakes before it reads knows what
--- the handshake settled, and a connection in the clear has no
--- `tls`.
local function test_a_protocol_handshakes_first_and_reads_what_it_settled(tmp: string)
  local said = ""
  assert(Net.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    tls = Tls.certs(Tls.static({ A }), { alpn = { "http/1.1" } }),
    timeout_ns = Clock.seconds(20),
    serve = function(conn: Net.Conn)
      assert(conn:handshake())
      local info = assert(conn:tls())
      local body = info.version .. " " .. (info.alpn or "-") .. " " .. (info.server_name or "-")
      local head = ""
      while not head:find("\r\n\r\n", 1, true) do head = head .. chunk_of(conn) end
      assert(conn:write("HTTP/1.1 200 OK\r\nContent-Length: " .. tostring(#body) .. "\r\nConnection: close\r\n\r\n" .. body))
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      said = fetched(tmp, assert(Array.at(addresses, 1).port), { "localhost" })
      server:stop()
    end,
  })
  assert(said == "200 TLSv1.3 http/1.1 localhost", said)
end
