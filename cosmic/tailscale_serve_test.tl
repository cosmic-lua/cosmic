--- [`Client:serve`] of [`cosmic.tailscale`] against a stand-in tailscaled that keeps a serve
--- configuration as the daemon does: read with its ETag, written only
--- where `If-Match` names the one it holds, and a foreground entry
--- dropped once the stream it is filed under ends. The client runs in a
--- child of this program, since a stream holds its thread while it opens.

local Array = require("cosmic.array")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Net = require("cosmic.net")
local Server = require("cosmic.http.server")
local Stream = require("cosmic.stream")
local Tailscale = require("cosmic.tailscale")
local Test = require("cosmic.test")
local _ = require("build.standalone")
local this_program = require("build.this_program")

Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" }, requires = { "unix_socket" } }

local STATUS <const> = [[{
  "Version": "1.90.0", "BackendState": "Running", "TailscaleIPs": ["100.64.0.1"],
  "Self": {"ID": "nSELF", "HostName": "box", "DNSName": "box.tail1234.ts.net.", "OS": "linux",
    "UserID": 42, "TailscaleIPs": ["100.64.0.1"], "Online": true, "Active": false,
    "ExitNode": false, "ExitNodeOption": false, "Relay": "", "CurAddr": "",
    "LastSeen": "0001-01-01T00:00:00Z"},
  "MagicDNSSuffix": "tail1234.ts.net", "CertDomains": ["box.tail1234.ts.net"]
}]]

--- What the node serves for others before the program starts: a site
--- on 8443, put up with `tailscale serve --bg`, and a field this module
--- does not know, which it keeps as it was.
local BACKGROUND <const> = '{"Services":{},"TCP":{"8443":{"HTTPS":true}},' ..
  '"Web":{"box.tail1234.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9000"}}}}}'

--- How the stand-in departs from a daemon that is alone with the client.
local record Quirks
  --- The next write loses to another writer, as though one came between
  --- the client's read and its write; one that `takes` serves that port
  --- under a session of its own.
  mut race?: boolean
  takes?: integer
  --- What the node serves before the client asks; BACKGROUND by default.
  background?: string
  --- An empty configuration reads as `null`, as the daemon writes one
  --- it never had.
  null?: boolean
  --- The first event names no session, as an old daemon's does.
  sessionless?: boolean
  --- What is filed loses `AcceptAppCaps`, as a daemon that predates it
  --- keeps only the fields it knows.
  dated?: boolean
end

--- The stand-in's state.
local record Daemon
  mut config: mut {string: Json.Value}
  mut etag: integer
  mut sessions: integer
  --- The streams open now.
  mut open: integer
  quirks: Quirks
  --- What it saw and did, a line each.
  mut lines: mut {string}
end

--- A stream of the IPN bus: the first event names its session, then a
--- newline every 20 ms, so that a write fails soon after the client
--- goes; its end drops the session's foreground entry.
local class Watch is Stream.Reader
  daemon: Daemon
  session: string
  mut started: boolean
  mut ended: boolean
  skip?: function(Watch, integer): boolean, string

  function read(self, _max_bytes?: integer): string?, string
    if not self.started then
      self.started = true
      if self.daemon.quirks.sessionless == true then
        return '{"Version":"1.90.0","State":6}\n', ""
      end
      return '{"Version":"1.90.0","State":6,"SessionID":"' .. self.session .. '"}\n', ""
    end
    local _, _ = Clock.sleep(Clock.ms(20))
    return "\n", ""
  end

  function close(self): boolean, string
    if self.ended then return true, "" end
    self.ended = true
    local d = self.daemon
    d.open = d.open - 1
    local foreground, _ = Json.to_object(d.config["Foreground"])
    if foreground ~= nil then
      local kept: mut {string: Json.Value} = {}
      local any = false
      for name, entry in pairs(foreground) do
        if name ~= self.session then
          kept[name] = entry
          any = true
        end
      end
      local config: mut {string: Json.Value} = {}
      for name, value in pairs(d.config) do
        if name ~= "Foreground" then config[name] = value end
      end
      if any then config["Foreground"] = kept end
      d.config = config
      d.etag = d.etag + 1
    end
    d.lines[#d.lines + 1] = "ended " .. self.session
    return true, ""
  end
end

local function answer(d: Daemon, req: Server.Request): Server.Reply
  local target = req.target
  if target == "/localapi/v0/status" then return { status = 200, body = STATUS } end
  if target == "/localapi/v0/watch-ipn-bus?mask=18" then
    d.sessions = d.sessions + 1
    d.open = d.open + 1
    local watch: Watch = { daemon = d, session = "s" .. tostring(d.sessions), started = false, ended = false,
      skip = nil }
    return { status = 200, body = watch }
  end
  if target == "/localapi/v0/serve-config" and req.method == "GET" then
    local body = if d.quirks.null == true and next(d.config) == nil then "null" else assert(Json.encode(d.config)) end
    return { status = 200, headers = { ["Etag"] = '"' .. tostring(d.etag) .. '"' }, body = body }
  end
  if target == "/localapi/v0/serve-config" and req.method == "POST" then
    local wanted = req.headers["if-match"] or ""
    d.lines[#d.lines + 1] = "POST if-match=" .. wanted
    local quirks = d.quirks
    if quirks.race == true then
      quirks.race = false
      local takes = quirks.takes
      if takes ~= nil then
        d.config["Foreground"] = { other = { TCP = { [tostring(takes)] = { TCPForward = "127.0.0.1:1" } } } }
      end
      d.etag = d.etag + 1
    end
    if wanted ~= '"' .. tostring(d.etag) .. '"' then
      return { status = 412, body = "etag mismatch\n" }
    end
    local text = assert(Stream.read_all(req.body))
    if quirks.dated == true then
      text = text:gsub('"AcceptAppCaps":%[[^%]]*%],?', ""):gsub(",}", "}")
    end
    local config = assert(Json.decode_object(text))
    local stored: mut {string: Json.Value} = {}
    for name, value in pairs(config) do stored[name] = value end
    d.config = stored
    d.etag = d.etag + 1
    return { status = 200 }
  end
  return { status = 404, body = "404 page not found\n" }
end

--- Serves the stand-in at a socket of `tmp` while a child runs
--- `body` as a script, with `ts` a client of it and `say(line)`, and
--- returns what the child printed and the stand-in's state after.
local function across(tmp: string, body: string, quirks?: Quirks): string, Daemon
  local script = tmp .. "/client.tl"
  assert(Fs.write(script, [[
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Tailscale = require("cosmic.tailscale")
return function(argv: {string}): integer
  local ts = assert(Tailscale.connect({ socket = argv[1] or "" }))
  local function say(line: string) local _, _ = Fs.put(Fs.stdout, line .. "\n") end
  local _ = Json.null
  local _ = Clock.ms
]] .. body .. [[
  return 0
end
]]))
  local background: mut {string: Json.Value} = {}
  local q: Quirks = quirks or {}
  for name, value in pairs((assert(Json.decode_object(q.background or BACKGROUND)))) do
    background[name] = value
  end
  local d: Daemon = { config = background, etag = 1, sessions = 0, open = 0, quirks = q, lines = {} }
  local output: mut {string} = {}
  assert(Server.serve{
    listeners = { Net.unix(tmp .. "/ts.sock") },
    on_stop = function(_: Net.Server) end,
    handle = function(req: Server.Request): Server.Reply return answer(d, req) end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local where = Array.at(addresses, 1).path or ""
      local started = this_program.program({ "--standalone", script, where },
        { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
      local result = assert(Child.run(started.argv, started.options))
      -- The streams end with the child; the stand-in sees each at its
      -- next write.
      local deadline = Clock.monotonic_ns() + Clock.seconds(10)
      while d.open > 0 and Clock.monotonic_ns() < deadline do
        local _, _ = Clock.sleep(Clock.ms(10))
      end
      server:stop()
      assert(result.code == 0, tostring(result.code) .. " " .. tostring(result.stderr))
      output[1] = assert(result.stdout)
    end,
  })
  return assert(output[1], "the server never became ready"), d
end

--- The stand-in's configuration as text, its keys sorted.
local function text_of(config: {string: Json.Value}): string
  return (assert(Json.encode(config)))
end

--- A serve files the program's sites and forwards under its stream,
--- beside what others serve, responds at their URLs, and is gone once
--- the serving is closed; what others serve stays.
local function test_a_serve_is_filed_under_its_stream_and_dropped_with_it(tmp: string)
  local said, d = across(tmp, [[
  local served = assert(ts:serve({
    sites = {
      { funnel = true, handlers = { ["/"] = { proxy = "http://127.0.0.1:8080" }, ["/hi"] = { text = "hello" } } },
      { http = true, port = 8080, handlers = { ["/"] = { path = "/srv/www" } } },
    },
    forwards = { { port = 5432, to = "127.0.0.1:5432", terminate_tls = true } },
  }))
  say(served.session .. " " .. served.domain .. " " .. table.concat(served.urls, " "))
  say(assert(ts:get("/localapi/v0/serve-config")).body)
  assert(served:close())
  -- The stand-in sees the stream end at its next write.
  local deadline = Clock.monotonic_ns() + Clock.seconds(10)
  while Clock.monotonic_ns() < deadline do
    local now = assert(ts:get("/localapi/v0/serve-config")).body
    if now:find("Foreground", 1, true) == nil then
      say(now)
      break
    end
    assert(Clock.sleep(Clock.ms(10)))
  end
]])
  local lines: mut {string} = {}
  for line in said:gmatch("[^\n]+") do lines[#lines + 1] = line end
  assert(lines[1] == "s1 box.tail1234.ts.net https://box.tail1234.ts.net/ http://box.tail1234.ts.net:8080/", lines[1])
  local mine = text_of({
    TCP = { ["443"] = { HTTPS = true }, ["8080"] = { HTTP = true },
      ["5432"] = { TCPForward = "127.0.0.1:5432", TerminateTLS = "box.tail1234.ts.net" } },
    Web = {
      ["box.tail1234.ts.net:443"] = { Handlers = { ["/"] = { Proxy = "http://127.0.0.1:8080" }, ["/hi"] = { Text = "hello" } } },
      ["box.tail1234.ts.net:8080"] = { Handlers = { ["/"] = { Path = "/srv/www" } } },
    },
    AllowFunnel = { ["box.tail1234.ts.net:443"] = true },
  })
  local whole = assert(Json.decode_object(BACKGROUND))
  local with: mut {string: Json.Value} = {}
  for name, value in pairs(whole) do with[name] = value end
  with["Foreground"] = { s1 = assert(Json.decode_object(mine)) }
  assert(lines[2] == text_of(with), lines[2])
  assert(lines[3] == text_of(whole), tostring(lines[3]))
  assert(d.lines[1] == 'POST if-match="1"' and d.lines[2] == "ended s1", table.concat(d.lines, "; "))
end

--- A write that loses to another writer reads the configuration again
--- and files over what that writer left.
local function test_a_serve_that_loses_a_race_reads_again(tmp: string)
  local said, d = across(tmp, [[
  local served <close> = assert(ts:serve({ domain = "box.tail1234.ts.net",
    forwards = { { port = 22, to = "127.0.0.1:22" } } }))
  say(if served.urls[1] == nil then "no sites" else "a site" end)
]], { race = true })
  assert(said == "no sites\n", said)
  assert(table.concat(d.lines, "; ") == 'POST if-match="1"; POST if-match="2"; ended s1', table.concat(d.lines, "; "))
end

--- A port others serve already fails the serve, and ends the stream it
--- opened.
local function test_a_port_others_serve_fails_and_ends_the_stream(tmp: string)
  local said, d = across(tmp, [[
  local served, why = ts:serve({ sites = { { port = 8443, handlers = { ["/"] = { text = "x" } } } } })
  say(tostring(served) .. " " .. why)
]])
  assert(said == "nil tailscale: serve: port 8443 is already served\n", said)
  assert(table.concat(d.lines, "; ") == "ended s1", table.concat(d.lines, "; "))
end

--- A port another program takes between the client's read and its
--- write fails the serve when the client reads again.
local function test_a_port_taken_in_a_race_fails_on_the_second_read(tmp: string)
  local said, d = across(tmp, [[
  local served, why = ts:serve({ domain = "box.tail1234.ts.net", forwards = { { port = 22, to = "127.0.0.1:22" } } })
  say(tostring(served) .. " " .. why)
]], { race = true, takes = 22 })
  assert(said == "nil tailscale: serve: port 22 is already served\n", said)
  assert(table.concat(d.lines, "; ") == 'POST if-match="1"; ended s1', table.concat(d.lines, "; "))
end

--- A daemon that never had a configuration reads one as `null`; the
--- serve files its own all the same.
local function test_a_null_configuration_takes_the_serve(tmp: string)
  local said, d = across(tmp, [[
  local served <close> = assert(ts:serve({ domain = "box.tail1234.ts.net", forwards = { { port = 22, to = "127.0.0.1:22" } } }))
  say(served.session)
]], { background = "{}", null = true })
  assert(said == "s1\n", said)
  assert(table.concat(d.lines, "; ") == 'POST if-match="1"; ended s1', table.concat(d.lines, "; "))
end

--- A daemon whose stream names no session cannot hold a foreground
--- configuration: the serve fails, and writes nothing.
local function test_a_daemon_that_names_no_session_fails_the_serve(tmp: string)
  local said, d = across(tmp, [[
  local served, why = ts:serve({ domain = "box.tail1234.ts.net", forwards = { { port = 22, to = "127.0.0.1:22" } } })
  say(tostring(served) .. " " .. why)
]], { sessionless = true })
  assert(said == "nil tailscale: serve: the daemon names no session: it predates foreground serving\n", said)
  assert(table.concat(d.lines, "; ") == "ended s1", table.concat(d.lines, "; "))
end

--- A daemon that does not keep `AcceptAppCaps` fails a serve that
--- forwards capabilities, and the stream's end takes the entry down.
local function test_a_daemon_that_drops_accept_app_caps_fails_the_serve(tmp: string)
  local said, d = across(tmp, [[
  local served, why = ts:serve({ domain = "box.tail1234.ts.net", sites = { { port = 443,
    handlers = { ["/"] = { proxy = "unix:/tmp/app.sock", accept_caps = { "example.com/cap/admin" } } } } } })
  say(tostring(served) .. " " .. why)
]], { dated = true })
  assert(said == "nil tailscale: serve: the daemon did not keep AcceptAppCaps: it predates forwarding " ..
      "capabilities, and would pass a client's own header on\n", said)
  assert(table.concat(d.lines, "; ") == 'POST if-match="1"; ended s1', table.concat(d.lines, "; "))
end

--- A spec it cannot file raises before the daemon is asked: here
--- there is none.
local function test_serve_refuses_a_spec_it_cannot_file()
  local ts = assert(Tailscale.connect({ socket = "/nonexistent/tailscaled.sock" }))
  local site: Tailscale.ServeHandler = { proxy = "http://127.0.0.1:1" }
  Test.raises(function() local _, _ = ts:serve({ sites = { { handlers = {} } } }) end, "sites[1].handlers is empty")
  Test.raises(function() local _, _ = ts:serve({ domain = "d" }) end, "at least one site or forward")
  Test.raises(function()
    local _, _ = ts:serve({ domain = "d", sites = { { handlers = {} } } })
  end, "sites[1].handlers is empty")
  Test.raises(function()
    local _, _ = ts:serve({ domain = "d", sites = { { handlers = { ["/"] = { proxy = "x", text = "y" } } } } })
  end, "must be an http://")
  Test.raises(function()
    local _, _ = ts:serve({ domain = "d", sites = { { handlers = { ["/"] = { text = "y", path = "/z" } } } } })
  end, "exactly one of proxy, text and path")
  Test.raises(function()
    local _, _ = ts:serve({ domain = "d", sites = { { handlers = { api = site } } } })
  end, "a mount path starts with /")
  Test.raises(function()
    local _, _ = ts:serve({ domain = "d", sites = { { handlers = { ["/"] = site } } },
      forwards = { { port = 443, to = "127.0.0.1:1" } } })
  end, "port 443 is served twice")
  Test.raises(function()
    local _, _ = ts:serve({ domain = "d", forwards = { { port = 70000, to = "127.0.0.1:1" } } })
  end, "forwards[1].port must be 1 to 65535")
  Test.raises(function()
    local _, _ = ts:serve({ domain = "d", forwards = { { port = 22, to = "nowhere" } } })
  end, "forwards[1].to must be host:port")
  Test.raises(function()
    local _, _ = ts:serve({ domain = "d", sites = { { port = 8080, funnel = true, handlers = { ["/"] = site } } } })
  end, "sites[1]: Funnel opens ports 443, 8443 and 10000 only, not 8080")
  Test.raises(function()
    local _, _ = ts:serve({ domain = "d", sites = { { http = true, port = 443, funnel = true, handlers = { ["/"] = site } } } })
  end, "Funnel serves HTTPS only")
  Test.raises(function()
    local _, _ = ts:serve({ domain = "d", forwards = { { port = 443, to = "127.0.0.1:1", funnel = true } } })
  end, "Funnel forwards only what it terminates TLS for")
end
