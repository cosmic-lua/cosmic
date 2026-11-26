--- [`cosmic.tailscale`] against a stand-in tailscaled: a [`Server.serve`]
--- that responds at the LocalAPI paths with the JSON the daemon writes.
--- Most clients run in a child of this program, as
--- cosmic/http_unix_test.tl's do, since `watch` holds its thread while it
--- waits; the last test asks from the stand-in's own run.

local Array = require("cosmic.array")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Server = require("cosmic.http.server")
local Tailscale = require("cosmic.tailscale")
local Test = require("cosmic.test")
local _ = require("build.standalone")

Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" }, requires = { "unix_socket" } }

local WHOIS <const> = [[{
  "Node": {"ID": 7, "StableID": "nABC1CNTRL", "Name": "laptop.tail1234.ts.net.", "User": 42,
    "Addresses": ["100.64.0.2/32", "fd7a:115c:a1e0::2/128"], "Tags": null,
    "Hostinfo": {"Hostname": "laptop", "OS": "macOS"}, "Key": "nodekey:00"},
  "UserProfile": {"ID": 42, "LoginName": "will@example.com", "DisplayName": "Will",
    "ProfilePicURL": ""},
  "CapMap": {"example.com/cap/admin": [{"level": "all"}], "example.com/cap/read": [], "example.com/cap/ping": null}
}]]

local TAGGED <const> = [[{
  "Node": {"ID": 8, "StableID": "nDEF2CNTRL", "Name": "db.tail1234.ts.net.", "User": 9,
    "Addresses": ["100.64.0.3/32"], "Tags": ["tag:db"]},
  "UserProfile": {"ID": 9, "LoginName": "tagged-devices", "DisplayName": "Tagged Devices"}
}]]

local STATUS <const> = [[{
  "Version": "1.90.0", "BackendState": "Running", "TailscaleIPs": ["100.64.0.1"],
  "Self": {"ID": "nSELF", "HostName": "box", "DNSName": "box.tail1234.ts.net.", "OS": "linux",
    "UserID": 42, "TailscaleIPs": ["100.64.0.1"], "Online": true, "Active": false,
    "ExitNode": false, "ExitNodeOption": false, "Relay": "", "CurAddr": "",
    "LastSeen": "0001-01-01T00:00:00Z"},
  "Health": null, "MagicDNSSuffix": "tail1234.ts.net",
  "CurrentTailnet": {"Name": "example.com", "MagicDNSSuffix": "tail1234.ts.net", "MagicDNSEnabled": true},
  "CertDomains": ["box.tail1234.ts.net"],
  "Peer": {
    "nodekey:bb": {"ID": "nZ", "HostName": "zed", "DNSName": "zed.tail1234.ts.net.", "OS": "linux",
      "UserID": 9, "TailscaleIPs": ["100.64.0.9"], "Tags": ["tag:db"], "Online": false, "Active": false,
      "ExitNode": false, "ExitNodeOption": true, "Relay": "fra", "CurAddr": "",
      "LastSeen": "2026-11-20T10:00:00Z", "KeyExpiry": "2027-01-01T00:00:00Z"},
    "nodekey:aa": {"ID": "nA", "HostName": "alpha", "DNSName": "alpha.tail1234.ts.net.", "OS": "macOS",
      "UserID": 42, "TailscaleIPs": ["100.64.0.2"], "Online": true, "Active": true,
      "ExitNode": false, "ExitNodeOption": false, "Relay": "fra", "CurAddr": "192.0.2.1:41641"}
  },
  "User": {"42": {"ID": 42, "LoginName": "will@example.com", "DisplayName": "Will"},
    "9": {"ID": 9, "LoginName": "tagged-devices", "DisplayName": "Tagged Devices"}}
}]]

local PREFS <const> = [[{"ControlURL": "https://controlplane.tailscale.com", "RouteAll": true,
  "ExitNodeID": "", "CorpDNS": true, "RunSSH": false, "WantRunning": true, "ShieldsUp": false,
  "Hostname": "", "AdvertiseTags": ["tag:web"], "AdvertiseRoutes": null, "OperatorUser": "will"}]]

local PAIR <const> = "-----BEGIN EC PRIVATE KEY-----\nKEY\n-----END EC PRIVATE KEY-----\n" ..
  "-----BEGIN CERTIFICATE-----\nLEAF\n-----END CERTIFICATE-----\n" ..
  "-----BEGIN CERTIFICATE-----\nCHAIN\n-----END CERTIFICATE-----\n"

local EVENTS <const> = '{"Version":"1.90.0","State":5}\n\n{"BrowseToURL":"https://login.example/a"}\n' ..
  '{"LoginFinished":{},"State":6}\n'

--- The requests the stand-in saw, one line each: method, target and the
--- headers that matter.
local record Seen
  mut lines: mut {string}
end

--- The stand-in's response to one LocalAPI request.
local function answer(req: Server.Request): Server.Reply
  local target = req.target
  if target == "/localapi/v0/whois?addr=100.64.0.2%3A443" then
    return { status = 200, body = WHOIS }
  end
  if target == "/localapi/v0/whois?addr=100.64.0.3" or target == "/localapi/v0/whois?addr=%5Bfd7a%3A115c%3Aa1e0%3A%3A3%5D%3A443" then
    return { status = 200, body = TAGGED }
  end
  if target == "/localapi/v0/whois?addr=100.64.0.1%3A80" then
    -- The node's own address, which the status lists.
    return { status = 200, body = WHOIS }
  end
  if target == "/localapi/v0/whois?addr=100.64.0.4" then
    return { status = 403, body = "whois access denied\n" }
  end
  if target == "/localapi/v0/whois?addr=100.64.0.66" then
    return { status = 200, body = '{"Node": {"ID": "seven"}, "UserProfile": {}}' }
  end
  if target:match("^/localapi/v0/whois%?") ~= nil then
    return { status = 404, body = "no match for IP:port\n" }
  end
  if target == "/localapi/v0/status" or target == "/localapi/v0/status?peers=false" then
    return { status = 200, body = STATUS }
  end
  if target == "/localapi/v0/prefs" then return { status = 200, body = PREFS } end
  if target == "/localapi/v0/cert/box.tail1234.ts.net?type=pair" then
    return { status = 200, body = PAIR }
  end
  if target:match("^/localapi/v0/cert/") ~= nil then
    return { status = 403, body = "cert access denied\n" }
  end
  if target == "/localapi/v0/ping?ip=100.64.0.2&type=disco" and req.method == "POST" then
    return { status = 200, body = '{"LatencySeconds": 0.0125, "Endpoint": "192.0.2.1:41641", "DERPRegionCode": ""}' }
  end
  if target == "/localapi/v0/ping?ip=100.64.0.8&type=disco" then
    return { status = 500, body = '{"error":"no matching peer"}\n' }
  end
  if target == "/localapi/v0/ping?ip=100.64.0.9&type=TSMP" then
    return { status = 200, body = '{"Err": "timeout"}' }
  end
  if target == "/localapi/v0/watch-ipn-bus?mask=2" then return { status = 200, body = EVENTS } end
  if target == "/localapi/v0/watch-ipn-bus?mask=16387" then
    return { status = 200, body = '{"State":null,"LoginFinished":null}\n' }
  end
  if target == "/localapi/v0/watch-ipn-bus?mask=0" then
    return { status = 200, body = '{"State":4}\n' }
  end
  return { status = 404, body = "404 page not found\n" }
end

--- Serves the stand-in at `listener` while the program runs `client` as
--- a script, given the listener's path or port as its argument, and
--- returns what the client printed and the requests the stand-in saw.
local function across(tmp: string, listener: Net.Address, client: string): string, {string}
  local script = tmp .. "/client.tl"
  assert(Fs.write(script, client))
  local seen: Seen = { lines = {} }
  local output: mut {string} = {}
  assert(Server.serve{
    listeners = { listener },
    on_stop = function(_: Net.Server) end,
    handle = function(req: Server.Request): Server.Reply
      local h = req.headers
      seen.lines[#seen.lines + 1] = req.method .. " " .. req.target .. " host=" .. (h["host"] or "") ..
        " cap=" .. (h["tailscale-cap"] or "") .. " auth=" .. (h["authorization"] or "")
      return answer(req)
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local address = Array.at(addresses, 1)
      local where = address.path or tostring(address.port)
      local started = Test.cosmic({ "--standalone", script, where },
        { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
      local result = assert(Child.run(started.argv, started.options))
      server:stop()
      assert(result.code == 0, tostring(result.code) .. " " .. tostring(result.stderr))
      output[1] = assert(result.stdout)
    end,
  })
  return assert(output[1], "the server never became ready"), seen.lines
end

--- A client script: `body` runs with `ts`, a client of the stand-in at
--- the socket its argument names, and `say(line)`, which prints a line.
local function over_socket(body: string): string
  return [[
local Fs = require("cosmic.fs")
local Tailscale = require("cosmic.tailscale")
return function(argv: {string}): integer
  local ts = assert(Tailscale.connect({ socket = argv[1] or "" }))
  local function say(line: string) local _, _ = Fs.put(Fs.stdout, line .. "\n") end
]] .. body .. [[
  return 0
end
]]
end

--- A peer's whois names the node, its owner and the capabilities the
--- grants give it, from the JSON the daemon writes, with the request
--- addressed to the host the daemon requires and the capability version.
local function test_whois_answers_the_node_its_user_and_its_capabilities(tmp: string)
  local said, seen = across(tmp, Net.unix(tmp .. "/ts.sock"), over_socket([[
  local function peer(address: string): Tailscale.WhoIs
    local found, why = ts:whois(address)
    assert(found ~= nil, why)
    assert(found ~= false, address .. " is no peer's")
    return found
  end
  local who = peer("100.64.0.2:443")
  say(who.node.name .. " " .. who.node.host_name .. " " .. who.node.os .. " " .. tostring(who.node.id))
  say(table.concat(who.node.addresses, ",") .. " tags=" .. tostring(#who.node.tags) .. " tagged=" .. tostring(who.tagged))
  say(who.user.login_name .. " " .. who.user.display_name .. " " .. tostring(who.user.picture_url) ..
    " own=" .. tostring(who.own))
  local Json = require("cosmic.json")
  local admin = assert(who.caps["example.com/cap/admin"])
  say("admin=" .. assert(Json.encode_any(admin)) .. " read=" .. tostring(#assert(who.caps["example.com/cap/read"])) ..
    " ping=" .. tostring(#assert(who.caps["example.com/cap/ping"])) ..
    " write=" .. tostring(who.caps["example.com/cap/write"]))
  local tagged = peer("100.64.0.3")
  say(tagged.node.name .. " " .. table.concat(tagged.node.tags, ",") .. " tagged=" .. tostring(tagged.tagged) ..
    " " .. tagged.user.login_name .. " host=" .. tagged.node.host_name)
  local six = peer("[fd7a:115c:a1e0::3]:443")
  say(six.node.name)
  say("here own=" .. tostring(peer("100.64.0.1:80").own))
]]))
  assert(said == table.concat({
    "laptop.tail1234.ts.net laptop macOS 7",
    "100.64.0.2,fd7a:115c:a1e0::2 tags=0 tagged=false",
    "will@example.com Will nil own=false",
    'admin=[{"level":"all"}] read=0 ping=0 write=nil',
    "db.tail1234.ts.net tag:db tagged=true tagged-devices host=",
    "db.tail1234.ts.net",
    "here own=true",
    "",
  }, "\n"), said)
  assert(seen[1] == "GET /localapi/v0/whois?addr=100.64.0.2%3A443 host=local-tailscaled.sock cap=130 auth=",
    seen[1])
end

--- An address the daemon knows no node at is false, told apart from a
--- daemon that refuses or cannot be reached, which is nil and a Failure.
local function test_whois_tells_a_stranger_from_a_daemon_that_is_not_there(tmp: string)
  local said, _ = across(tmp, Net.unix(tmp .. "/ts.sock"), over_socket([[
  local stranger, none = ts:whois("192.0.2.7")
  say(tostring(stranger) .. " " .. tostring(none))
  local refused, denied = ts:whois("100.64.0.4")
  say(tostring(refused) .. " " .. tostring(denied))
  local gone = assert(Tailscale.connect({ socket = (argv[1] or "") .. ".none" }))
  local failed, why = gone:whois("100.64.0.2")
  say(tostring(failed) .. " " .. tostring(tostring(why):find("tailscale: ", 1, true) == 1))
]]))
  assert(said == table.concat({
    "false nil",
    "nil tailscale: /localapi/v0/whois: whois access denied",
    "nil true",
    "",
  }, "\n"), said)
end

--- The status lists this node and its peers in order of name, with the
--- users by id, Go's zero time read as none and a null list as empty.
local function test_status_answers_the_node_and_its_peers_in_order(tmp: string)
  local said, _ = across(tmp, Net.unix(tmp .. "/ts.sock"), over_socket([[
  local status = assert(ts:status())
  local me = assert(status.self)
  say(status.version .. " " .. status.backend_state .. " " .. status.tailnet .. " " .. status.magic_dns_suffix ..
    " magic=" .. tostring(status.magic_dns) .. " health=" .. tostring(#status.health))
  say(me.dns_name .. " " .. tostring(me.last_seen) .. " " .. table.concat(status.cert_domains, ","))
  for _, peer in ipairs(status.peers) do
    say(peer.dns_name .. " " .. peer.id .. " online=" .. tostring(peer.online) .. " tags=" ..
      table.concat(peer.tags, ",") .. " direct=" .. peer.direct .. " seen=" .. tostring(peer.last_seen) ..
      " exit=" .. tostring(peer.exit_node_option))
  end
  say(assert(status.users[42]).login_name .. " " .. assert(status.users[9]).login_name)
]]))
  assert(said == table.concat({
    "1.90.0 Running example.com tail1234.ts.net magic=true health=0",
    "box.tail1234.ts.net nil box.tail1234.ts.net",
    "alpha.tail1234.ts.net nA online=true tags= direct=192.0.2.1:41641 seen=nil exit=false",
    "zed.tail1234.ts.net nZ online=false tags=tag:db direct= seen=2026-11-20T10:00:00Z exit=true",
    "will@example.com tagged-devices",
    "",
  }, "\n"), said)
end

--- The preferences come back under the names `tailscale set` uses.
local function test_prefs_answers_the_settings_by_their_command_line_names(tmp: string)
  local said, _ = across(tmp, Net.unix(tmp .. "/ts.sock"), over_socket([[
  local prefs = assert(ts:prefs())
  say(prefs.control_url .. " routes=" .. tostring(prefs.accept_routes) .. " dns=" .. tostring(prefs.accept_dns) ..
    " running=" .. tostring(prefs.want_running) .. " tags=" .. table.concat(prefs.advertise_tags, ",") ..
    " advertised=" .. tostring(#prefs.advertise_routes) .. " operator=" .. prefs.operator)
]]))
  assert(said == "https://controlplane.tailscale.com routes=true dns=true running=true tags=tag:web " ..
      "advertised=0 operator=will\n", said)
end

--- A certificate's reply is the key then the chain; the pair splits it,
--- and a refusal passes on the daemon's reason, as does a name that
--- would leave the path.
local function test_cert_splits_the_key_from_the_chain_and_passes_on_a_refusal(tmp: string)
  local said, seen = across(tmp, Net.unix(tmp .. "/ts.sock"), over_socket([[
  local pair = assert(ts:cert("box.tail1234.ts.net"))
  say(pair.key .. "|" .. pair.cert)
  local _, why = ts:cert("other.tail1234.ts.net")
  say(tostring(why))
  local _, odd = ts:cert("box/../status")
  say(tostring(odd))
]]))
  assert(said == "-----BEGIN EC PRIVATE KEY-----\nKEY\n-----END EC PRIVATE KEY-----\n|" ..
      "-----BEGIN CERTIFICATE-----\nLEAF\n-----END CERTIFICATE-----\n" ..
      "-----BEGIN CERTIFICATE-----\nCHAIN\n-----END CERTIFICATE-----\n\n" ..
      "tailscale: /localapi/v0/cert/other.tail1234.ts.net: cert access denied\n" ..
      'tailscale: cert: no such domain "box/../status"\n', said)
  assert(#seen == 2, table.concat(seen, "\n"))
end

--- A ping that came back returns its time in nanoseconds; one the
--- daemon gave up on fails with the daemon's reason.
local function test_ping_answers_the_round_trip_or_why_none_came(tmp: string)
  local said, seen = across(tmp, Net.unix(tmp .. "/ts.sock"), over_socket([[
  local ping = assert(ts:ping("100.64.0.2"))
  say(tostring(ping.latency_ns) .. " " .. tostring(ping.endpoint) .. " " .. tostring(ping.derp_region))
  local _, why = ts:ping("100.64.0.9", "TSMP")
  say(tostring(why))
  local _, refused = ts:ping("100.64.0.8")
  say(tostring(refused))
]]))
  assert(said == "12500000 192.0.2.1:41641 nil\ntailscale: ping 100.64.0.9: timeout\n" ..
      "tailscale: /localapi/v0/ping: no matching peer\n", said)
  local first = Array.at(seen, 1)
  assert(first:match("^POST ") ~= nil, first)
end

--- The event stream reads one event a line, skipping blank ones, and
--- ends where the daemon's reply does.
local function test_watch_reads_an_event_a_line(tmp: string)
  local said, _ = across(tmp, Net.unix(tmp .. "/ts.sock"), over_socket([[
  local events <close> = assert(ts:watch())
  while true do
    local event, why = events:read()
    if event == nil then
      say("end " .. tostring(why))
      break
    end
    if event == false then
      say("end ")
      break
    end
    say(tostring(event.state) .. " " .. tostring(event.browse_url) .. " " .. tostring(event.login_finished) ..
      " " .. tostring(event.version))
  end
  local engine <close> = assert(ts:watch({ engine = true, initial_status = true }))
  local nulls, nulls_why = engine:read()
  assert(nulls ~= nil, nulls_why)
  assert(nulls ~= false, "the stream ended")
  say(tostring(nulls.state) .. " " .. tostring(nulls.login_finished))
  local bare <close> = assert(ts:watch({ initial_state = false }))
  local first, first_why = bare:read()
  assert(first ~= nil, first_why)
  assert(first ~= false, "the stream ended")
  say(tostring(first.state))
]]))
  assert(said == table.concat({
    "Starting nil false 1.90.0",
    "nil https://login.example/a false nil",
    "Running nil true nil",
    "end ",
    "nil false",
    "Stopped",
    "",
  }, "\n"), said)
end

--- A reply that does not fit the daemon's shape fails with the path of
--- the field, and any path is reachable as bytes.
local function test_a_reply_of_the_wrong_shape_fails_naming_the_field(tmp: string)
  local said, _ = across(tmp, Net.unix(tmp .. "/ts.sock"), over_socket([[
  local bad, why = ts:whois("100.64.0.66")
  say(tostring(bad) .. " " .. tostring(why))
  local missing = assert(ts:get("/localapi/v0/nothing"))
  say(tostring(missing.status) .. " " .. missing.body)
]]))
  assert(said == "nil tailscale: whois: WireWhoIs: $.Node.ID: want integer, got string\n" ..
      "404 404 page not found\n\n", said)
end

--- Over a port, as macOS's app listens, every request carries the token
--- as the password of HTTP basic auth, and the host the daemon requires.
local function test_a_port_sends_its_token_as_basic_auth(tmp: string)
  local said, seen = across(tmp, Net.tcp("127.0.0.1", 0), [[
local Fs = require("cosmic.fs")
local Tailscale = require("cosmic.tailscale")
return function(argv: {string}): integer
  local port = assert(math.tointeger(tonumber(argv[1] or "")))
  local ts = assert(Tailscale.connect({ port = port, token = "abc123" }))
  local status = assert(ts:status())
  local _, _ = Fs.put(Fs.stdout, status.backend_state)
  return 0
end
]])
  assert(said == "Running", said)
  -- base64(":abc123")
  local first = Array.at(seen, 1)
  assert(first:match(" auth=Basic OmFiYzEyMw==$") ~= nil, first)
  assert(first:match(" host=local%-tailscaled%.sock ") ~= nil, first)
end

--- Options that cannot be met together are a caller's bug and raise.
local function test_connect_refuses_options_that_conflict()
  local function connect(opts: Tailscale.Daemon) local _, _ = Tailscale.connect(opts) end
  local ok, why = pcall(connect, { socket = "/s", port = 1 })
  assert(not ok and tostring(why):find("socket or port", 1, true) ~= nil, tostring(why))
  ok, why = pcall(connect, { token = "t" })
  assert(not ok and tostring(why):find("token needs port", 1, true) ~= nil, tostring(why))
  ok, why = pcall(connect, { port = 70000 })
  assert(not ok and tostring(why):find("1 to 65535", 1, true) ~= nil, tostring(why))
  local client, empty = Tailscale.connect({ socket = "" })
  assert(client == nil and tostring(empty) == "tailscale: the socket path is empty", tostring(empty))
end

--- A call waits as a task of the run it is made in, so a server's own
--- handler can ask the daemon while the run goes on: here the stand-in is
--- served by the very run that asks it, which a call that held the thread
--- would never let respond.
local function test_a_call_in_a_task_lets_the_run_answer_it(tmp: string)
  local said: mut {string} = {}
  assert(Server.serve{
    listeners = { Net.unix(tmp .. "/ts.sock") },
    on_stop = function(_: Net.Server) end,
    handle = answer,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local ts = assert(Tailscale.connect({ socket = assert(Array.at(addresses, 1).path), timeout_ns = Clock.seconds(5) }))
      local who, why = ts:whois("100.64.0.2:443")
      local line = if who == nil then tostring(why) elseif who == false then "not a peer" else who.user.login_name end
      said[#said + 1] = line
      server:stop()
    end,
  })
  assert(said[1] == "will@example.com", said[1])
end
