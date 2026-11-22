--- The tailnet middleware of cosmic.web: who a request comes from, as a stand-in whois
--- says, and what the middleware answers for each kind of answer.

local Array = require("cosmic.array")
local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local Server = require("cosmic.http.server")
local Tailscale = require("cosmic.tailscale")
local Test = require("cosmic.test")
local Web = require("cosmic.web")

--- The last test serves a stand-in daemon on a socket file.
Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" }, requires = { "unix_socket" } }

--- A user's node, which the policy grants `example.com/cap/admin`.
local WILL <const>: Tailscale.WhoIs = {
  node = { id = 7, stable_id = "nA", name = "laptop.tail1234.ts.net", host_name = "laptop", os = "macOS",
    user_id = 42, addresses = { "100.64.0.2" }, tags = {} },
  user = { id = 42, login_name = "will@example.com", display_name = "Will" },
  tagged = false,
  caps = { ["example.com/cap/admin"] = { { level = "all" } } },
  own = false,
}

--- A tagged node, granted nothing.
local DB <const>: Tailscale.WhoIs = {
  node = { id = 8, stable_id = "nB", name = "db.tail1234.ts.net", host_name = "db", os = "linux", user_id = 9,
    addresses = { "100.64.0.3" }, tags = { "tag:db" } },
  user = { id = 9, login_name = "tagged-devices", display_name = "Tagged Devices" },
  tagged = true,
  caps = {},
  own = false,
}

--- What a stand-in whois was asked, and the lines the app's sink took.
local record Seen
  mut asked: mut {string}
  mut lines: mut {string}
end

--- A whois that knows WILL and DB, this node at 100.64.0.1 (WILL's own
--- node), fails for 100.64.0.99, and says any
--- other address is no peer's, noting each address it is asked.
local function stand_in(seen: Seen): function(string): Tailscale.WhoIsResult
  return function(address: string): Tailscale.WhoIsResult
    seen.asked[#seen.asked + 1] = address
    if address == "100.64.0.2" then
      return { kind = "found", whois = WILL, reason = "", status = 200 }
    end
    if address == "100.64.0.3" then
      return { kind = "found", whois = DB, reason = "", status = 200 }
    end
    if address == "100.64.0.1" then
      return { kind = "found", whois = { ...WILL, own = true }, reason = "", status = 200 }
    end
    if address == "100.64.0.99" then
      return { kind = "failed", reason = "tailscale: connect: refused", status = 0 }
    end
    return { kind = "not_a_peer", reason = "tailscale: no node has the address " .. address, status = 404 }
  end
end

--- An app behind [`Web.tailnet`] given `opts`, whose `/` says who asked
--- and whose `/admin` needs `example.com/cap/admin`.
local function app_of(seen: Seen, opts: Web.TailnetOptions): Web.App
  return Web.app{
    sink = { line = function(_self: Web.Sink, text: string) seen.lines[#seen.lines + 1] = text end },
    middleware = { Web.tailnet(opts) },
    routes = {
      Web.get("/", function(req: Web.Request): Web.Response
        local who = Web.tailnet_identity(req)
        if who == nil then return Web.text("nobody") end
        local node = who.node
        return Web.text(who.login_name .. " " .. who.display_name .. " " .. who.source .. " " ..
            (if node ~= nil then node.name else "-" end) .. " tagged=" .. tostring(who.tagged))
      end),
      Web.get("/admin", function(_: Web.Request): Web.Response
        return Web.text("the switches")
      end, { middleware = { Web.require_cap("example.com/cap/admin") } }),
    },
  }
end

local function new_seen(): Seen
  return { asked = {}, lines = {} }
end

--- A peer the daemon knows is its user and node, and a capability the
--- policy grants opens what needs it; a node without it is refused.
local function test_a_peer_is_its_user_and_a_capability_opens_what_needs_it()
  local seen = new_seen()
  local client = Web.test_client(app_of(seen, { whois = stand_in(seen) }))
  local will = Net.tcp("100.64.0.2", 50123)
  local home = client:get("/", { peer = will })
  assert(home.status == 200 and home.body == "will@example.com Will whois laptop.tail1234.ts.net tagged=false",
    home.body)
  local admin = client:get("/admin", { peer = will })
  assert(admin.status == 200 and admin.body == "the switches", admin.body)
  local db = Net.tcp("100.64.0.3", 40000)
  local tagged = client:get("/", { peer = db })
  assert(tagged.body == "tagged-devices Tagged Devices whois db.tail1234.ts.net tagged=true", tagged.body)
  local refused = client:get("/admin", { peer = db })
  assert(refused.status == 403, tostring(refused.status))
  assert(refused.body:find("example.com/cap/admin", 1, true) ~= nil, refused.body)
end

--- An address that is no peer's is refused, unless `required` is false;
--- then the request goes on with no identity, and a capability it needs
--- is still refused.
local function test_a_stranger_is_refused_unless_identity_is_optional()
  local seen = new_seen()
  local stranger = Net.tcp("192.0.2.7", 1)
  local strict = Web.test_client(app_of(seen, { whois = stand_in(seen) }))
  assert(strict:get("/", { peer = stranger }).status == 403)
  local open = Web.test_client(app_of(seen, { whois = stand_in(seen), required = false }))
  local home = open:get("/", { peer = stranger })
  assert(home.status == 200 and home.body == "nobody", home.body)
  assert(open:get("/admin", { peer = stranger }).status == 403)
end

--- A daemon that cannot be asked admits nobody: 503, why on the app's
--- sink, and a failure is not kept, so the next request asks again.
local function test_a_daemon_that_fails_answers_503_and_is_asked_again()
  local seen = new_seen()
  local client = Web.test_client(app_of(seen, { whois = stand_in(seen) }))
  local peer = Net.tcp("100.64.0.99", 1)
  local first = client:get("/", { peer = peer })
  assert(first.status == 503, tostring(first.status))
  assert(first.body:find("refused", 1, true) == nil, "the reason stays off the wire: " .. first.body)
  assert(client:get("/", { peer = peer }).status == 503)
  assert(#seen.asked == 2, table.concat(seen.asked, ","))
  assert(Array.at(seen.lines, 1) == "tailnet: tailscale: connect: refused", tostring(seen.lines[1]))
end

--- An answer is kept for its address, whatever the port, for `cache_ns`;
--- with 0 every request asks.
local function test_an_answer_is_kept_per_address()
  local seen = new_seen()
  local client = Web.test_client(app_of(seen, { whois = stand_in(seen) }))
  assert(client:get("/", { peer = Net.tcp("100.64.0.2", 1) }).status == 200)
  assert(client:get("/", { peer = Net.tcp("100.64.0.2", 2) }).status == 200)
  assert(client:get("/", { peer = Net.tcp("192.0.2.7", 1) }).status == 403)
  assert(client:get("/", { peer = Net.tcp("192.0.2.7", 2) }).status == 403)
  assert(table.concat(seen.asked, ",") == "100.64.0.2,192.0.2.7", table.concat(seen.asked, ","))
  local fresh = new_seen()
  local uncached = Web.test_client(app_of(fresh, { whois = stand_in(fresh), cache_ns = 0 }))
  assert(uncached:get("/", { peer = Net.tcp("100.64.0.2", 1) }).status == 200)
  assert(uncached:get("/", { peer = Net.tcp("100.64.0.2", 1) }).status == 200)
  assert(#fresh.asked == 2, table.concat(fresh.asked, ","))
  local ok, why = pcall(Web.tailnet, { cache_ns = -1 })
  assert(not ok and tostring(why):find("cache_ns", 1, true) ~= nil, tostring(why))
end

--- Behind `tailscale serve` the loopback peer's headers name who asked,
--- an encoded name decoded, but grant no capabilities, which a client
--- could have sent itself; without them a loopback request is nobody's,
--- as one through Funnel is.
local function test_serve_headers_name_who_asked_from_the_loopback_alone()
  local seen = new_seen()
  local client = Web.test_client(app_of(seen, { whois = stand_in(seen), serve = true }))
  local headers = {
    ["Tailscale-User-Login"] = "rene@example.com",
    ["Tailscale-User-Name"] = "=?utf-8?q?Ren=C3=A9_Doe?=",
    ["Tailscale-App-Capabilities"] = '{"example.com/cap/admin":[{}]}',
  }
  local loopback = Net.tcp("127.0.0.1", 50000)
  local home = client:get("/", { peer = loopback, headers = headers })
  assert(home.body == "rene@example.com René Doe serve - tagged=false", home.body)
  assert(client:get("/admin", { peer = loopback, headers = headers }).status == 403)
  assert(client:get("/", { peer = Net.tcp("::1", 50000), headers = headers }).status == 200)
  local funnel = client:get("/", { peer = loopback })
  assert(funnel.status == 403, tostring(funnel.status))
  -- From another address the headers are anyone's to send: whois decides.
  local forged = client:get("/", { peer = Net.tcp("192.0.2.7", 1), headers = headers })
  assert(forged.status == 403, tostring(forged.status))
  assert(table.concat(seen.asked, ",") == "192.0.2.7", table.concat(seen.asked, ","))
end

--- At the socket Web.serve opened for Serve, the daemon's headers name
--- who asked, with or without `serve`; one that Funnel brought has
--- none, and is marked so. At any other unix socket they name nobody,
--- and nobody is asked.
local function test_serve_headers_name_who_asked_at_the_apps_own_socket()
  local seen = new_seen()
  local own = Net.unix("/run/app/s")
  local client_side = Net.unix("")
  local who = { ["Tailscale-User-Login"] = "rene@example.com", ["Tailscale-User-Name"] = "Rene" }
  local app = app_of(seen, { whois = stand_in(seen) })
  app.serve_socket = "/run/app/s"
  local client = Web.test_client(app)
  local home = client:get("/", { peer = client_side, listener = own, headers = who })
  assert(home.body == "rene@example.com Rene serve - tagged=false", home.body)
  -- A capability counts only where the daemon was told to forward it.
  local granted = { ["Tailscale-User-Login"] = "rene@example.com",
    ["Tailscale-App-Capabilities"] = '{"example.com/cap/admin":[{}]}' }
  assert(client:get("/admin", { peer = client_side, listener = own, headers = granted }).status == 403)
  app.serve_caps = { "example.com/cap/admin" }
  assert(client:get("/admin", { peer = client_side, listener = own, headers = granted }).status == 200)
  app.serve_caps = nil
  local other = client:get("/", { peer = client_side, listener = Net.unix("/run/app/admin"), headers = who })
  assert(other.status == 403, tostring(other.status))
  -- Without a socket of its own the app trusts no unix socket, `serve` or not.
  local plain = Web.test_client(app_of(seen, { whois = stand_in(seen), serve = true }))
  assert(plain:get("/", { peer = client_side, listener = own, headers = who }).status == 403)
  local open = Web.app{
    middleware = { Web.tailnet({ whois = stand_in(seen), serve = true, required = false }) },
    routes = {
      Web.get("/", function(req: Web.Request): Web.Response
        return Web.text(tostring(Web.tailnet_funnel(req)) .. " " .. tostring(Web.tailnet_identity(req) ~= nil))
      end),
    },
  }
  open.serve_socket = "/run/app/s"
  local public = Web.test_client(open)
  local funneled = public:get("/", { peer = client_side, listener = own,
    headers = { ["Tailscale-Funnel-Request"] = "?1", ["Tailscale-User-Login"] = "forged@example.com" } })
  assert(funneled.body == "true false", funneled.body)
  assert(public:get("/", { peer = client_side, listener = own, headers = who }).body == "false true")
  -- Funnel is told on the loopback too, where `serve` trusts it.
  assert(public:get("/", { peer = Net.tcp("127.0.0.1", 50000),
    headers = { ["Tailscale-Funnel-Request"] = "?1" } }).body == "true false")
  assert(#seen.asked == 0, table.concat(seen.asked, ","))
end

--- The daemon names this node's owner in its headers for a request from
--- this node's own address, which any process here can make: where its
--- X-Forwarded-For is that address the request has no identity, and
--- where the daemon cannot be asked about it the answer is 503, at the
--- app's socket and on the loopback alike.
local function test_serve_headers_name_nobody_for_a_request_from_this_node()
  local seen = new_seen()
  local app = app_of(seen, { whois = stand_in(seen), serve = true })
  app.serve_socket = "/run/app/s"
  local client = Web.test_client(app)
  local function from(forwarded: string, peer: Net.Address, listener?: Net.Address): integer
    return client:get("/", { peer = peer, listener = listener, headers = {
      ["Tailscale-User-Login"] = "will@example.com", ["X-Forwarded-For"] = forwarded } }).status
  end
  local socket, side, loopback = Net.unix("/run/app/s"), Net.unix(""), Net.tcp("127.0.0.1", 50000)
  assert(from("100.64.0.2", side, socket) == 200, "a peer's request")
  assert(from("100.64.0.1", side, socket) == 403, "this node's own request")
  assert(from("100.64.0.99", side, socket) == 503, "a daemon that cannot be asked")
  assert(#seen.lines == 1 and assert(seen.lines[1]):find("refused", 1, true) ~= nil, table.concat(seen.lines, "|"))
  assert(from("100.64.0.2", loopback) == 200)
  assert(from("100.64.0.1", loopback) == 403)
  assert(from("192.0.2.7, 100.64.0.1", side, socket) == 403, "the last entry is the daemon's")
  assert(from("::ffff:100.64.0.1", side, socket) == 403, "a mapped address")
  assert(table.concat(seen.asked, ",") == "100.64.0.2,100.64.0.1,100.64.0.99", table.concat(seen.asked, ","))
end

--- Without `serve` the headers are never read: a loopback peer is asked
--- about as any other.
local function test_serve_headers_are_ignored_unless_asked_for()
  local seen = new_seen()
  local client = Web.test_client(app_of(seen, { whois = stand_in(seen) }))
  local reply = client:get("/", { peer = Net.tcp("127.0.0.1", 50000),
    headers = { ["Tailscale-User-Login"] = "rene@example.com" } })
  assert(reply.status == 403, tostring(reply.status))
  assert(table.concat(seen.asked, ",") == "127.0.0.1", table.concat(seen.asked, ","))
end

--- Serving through Serve refuses what cannot be served before it asks
--- any daemon.
local function test_serving_through_serve_refuses_options_out_of_range()
  local Tailnet = require("cosmic.web.tailnet")
  Test.raises(function() local _, _ = Tailnet.serving({ via = "serve", port = 0 }) end, "from 1 to 65535")
  Test.raises(function() local _, _ = Tailnet.serving({ via = "funnel", port = 8080 }) end, "443, 8443 and 10000")
  Test.raises(function() local _, _ = Tailnet.serving({ caps = { "example.com/cap/admin" } }) end, "needs via serve")
end

--- A capability of an empty name is a caller's bug.
local function test_require_cap_refuses_an_empty_name()
  local ok, why = pcall(Web.require_cap, "")
  assert(not ok and tostring(why):find("capability", 1, true) ~= nil, tostring(why))
end

--- The middleware over a real client: a stand-in daemon on a socket,
--- served by the same run that serves the request, which the whois waits
--- in as a task.
local function test_the_middleware_asks_a_daemon_in_the_requests_own_run(tmp: string)
  local said: mut {string} = {}
  local function daemon(req: Server.Request): Server.Reply
    if req.target == "/localapi/v0/status?peers=false" then
      return { status = 200, body = '{"Version": "1.90.0", "BackendState": "Running", "MagicDNSSuffix": "", ' ..
          '"Self": {"ID": "nSELF", "HostName": "box", "DNSName": "box.tail1234.ts.net.", "OS": "linux", ' ..
          '"UserID": 42, "TailscaleIPs": ["100.64.0.1"], "Online": true, "Active": false, "ExitNode": false, ' ..
          '"ExitNodeOption": false, "Relay": "", "CurAddr": "", "LastSeen": "0001-01-01T00:00:00Z"}}' }
    end
    if req.target == "/localapi/v0/whois?addr=100.64.0.1" then
      return { status = 200, body = '{"Node": {"ID": 1, "StableID": "nSELF", "Name": "box.tail1234.ts.net.", ' ..
          '"User": 42, "Addresses": ["100.64.0.1/32"]}, "UserProfile": {"ID": 42, "LoginName": "will@example.com", ' ..
          '"DisplayName": "Will"}, "CapMap": {"example.com/cap/admin": null}}' }
    end
    if req.target == "/localapi/v0/whois?addr=100.64.0.2" then
      return { status = 200, body = '{"Node": {"ID": 7, "StableID": "nA", "Name": "laptop.tail1234.ts.net.", ' ..
          '"User": 42, "Addresses": ["100.64.0.2/32"]}, "UserProfile": {"ID": 42, "LoginName": "will@example.com", ' ..
          '"DisplayName": "Will"}, "CapMap": {"example.com/cap/admin": null}}' }
    end
    return { status = 404, body = "no match\n" }
  end
  assert(Server.serve{
    listeners = { Net.unix(tmp .. "/ts.sock") },
    on_stop = function(_: Net.Server) end,
    handle = daemon,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local ts = assert(Tailscale.connect({ socket = assert(Array.at(addresses, 1).path),
        timeout_ns = Clock.seconds(5) }))
      local seen = new_seen()
      local client = Web.test_client(app_of(seen, {
        whois = function(address: string): Tailscale.WhoIsResult return ts:whois_result(address) end,
      }))
      local peer = Net.tcp("100.64.0.2", 50123)
      local home = client:get("/", { peer = peer }).body
      local admin = tostring(client:get("/admin", { peer = peer }).status)
      local stranger = tostring(client:get("/", { peer = Net.tcp("192.0.2.7", 1) }).status)
      -- The node's own address: a process here, which the owner's
      -- identity does not name.
      local here = tostring(client:get("/", { peer = Net.tcp("100.64.0.1", 50124) }).status)
      said[#said + 1] = home .. "|" .. admin .. "|" .. stranger .. "|" .. here
      server:stop()
    end,
  })
  local got = table.concat(said, "|")
  assert(got == "will@example.com Will whois laptop.tail1234.ts.net tagged=false|200|403|403", got)
end

--- A peer that a listener on `::` names in IPv6 (`::ffff:100.64.0.2`) is
--- asked about as its IPv4 address, and so is a loopback one behind
--- `serve`; a header naming another address moves nothing, with or
--- without `trusted_proxy`.
local function test_a_mapped_peer_is_its_ipv4_address_and_headers_move_nothing()
  local seen = new_seen()
  local client = Web.test_client(app_of(seen, { whois = stand_in(seen), serve = true }))
  local mapped = client:get("/", { peer = Net.tcp("::ffff:100.64.0.2", 1) })
  assert(mapped.status == 200 and mapped.body:match("^will@example.com ") ~= nil, mapped.body)
  local served = client:get("/", { peer = Net.tcp("::ffff:127.0.0.1", 1),
    headers = { ["Tailscale-User-Login"] = "rene@example.com" } })
  assert(served.body == "rene@example.com rene@example.com serve - tagged=false", served.body)
  local proxied = Web.test_client(Web.app{
    sink = { line = function(_self: Web.Sink, _text: string) end },
    trusted_proxy = { "192.0.2.9" },
    middleware = { Web.tailnet({ whois = stand_in(seen) }) },
    routes = { Web.get("/", function(_: Web.Request): Web.Response return Web.text("in") end) },
  })
  local forwarded = proxied:get("/", { peer = Net.tcp("192.0.2.9", 1),
    headers = { ["X-Forwarded-For"] = "100.64.0.2" } })
  assert(forwarded.status == 403, tostring(forwarded.status))
  assert(table.concat(seen.asked, ",") == "100.64.0.2,192.0.2.9", table.concat(seen.asked, ","))
end

--- Addresses off the tailnet, however many, never push a peer's answer
--- out of the cache.
local function test_strangers_do_not_push_a_peer_out_of_the_cache()
  local seen = new_seen()
  local client = Web.test_client(app_of(seen, { whois = stand_in(seen) }))
  local will = Net.tcp("100.64.0.2", 1)
  assert(client:get("/", { peer = will }).status == 200)
  for i = 1, 4100 do
    local host = string.format("192.0.%d.%d", i // 256, i % 256)
    assert(client:get("/", { peer = Net.tcp(host, 1) }).status == 403)
  end
  assert(client:get("/", { peer = will }).status == 200)
  local peer_asks = 0
  for _, address in ipairs(seen.asked) do
    if address == "100.64.0.2" then peer_asks = peer_asks + 1 end
  end
  assert(peer_asks == 1, tostring(peer_asks))
end

--- A name Go splits into several encoded words joins whole, and a
--- capability whose value is no array is not granted.
local function test_an_encoded_name_of_several_words_joins_and_a_bad_grant_grants_nothing()
  local seen = new_seen()
  local app = app_of(seen, { whois = stand_in(seen) })
  app.serve_socket = "/run/app/s"
  app.serve_caps = { "example.com/cap/admin" }
  local client = Web.test_client(app)
  local peer, listener = Net.unix(""), Net.unix("/run/app/s")
  local reply = client:get("/admin", { peer = peer, listener = listener, headers = {
    ["Tailscale-User-Login"] = "rene@example.com",
    ["Tailscale-User-Name"] = "=?utf-8?q?Ren=C3=A9?= =?utf-8?q?_Doe?=",
    ["Tailscale-App-Capabilities"] = '{"example.com/cap/admin": 5}',
  } })
  assert(reply.status == 403, tostring(reply.status))
  local home = client:get("/", { peer = peer, listener = listener, headers = {
    ["Tailscale-User-Login"] = "rene@example.com",
    ["Tailscale-User-Name"] = "=?utf-8?q?Ren=C3=A9?= =?utf-8?q?_Doe?=",
  } })
  assert(home.body == "rene@example.com René Doe serve - tagged=false", home.body)
end
