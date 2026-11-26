--- [`Web.serve`] through the daemon's Serve: an app in a child of this
--- program listens at a private unix socket and files a Funnel site
--- that passes every path to it; the stand-in daemon here takes the
--- configuration, sends a request to the socket as tailscaled would,
--- with the headers that say who asked, and stops the app, which takes
--- the site down and removes its socket.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Net = require("cosmic.net")
local Server = require("cosmic.http.server")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
-- The app's modules, so that its run in a child finds them.
local type _Tailscale = require("cosmic.tailscale")
local type _Web = require("cosmic.web")
local _ = require("build.standalone")
local type Failure = require("cosmic.failure")

Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" }, requires = { "unix_socket" } }

local STATUS <const> = [[{
  "Version": "1.90.0", "BackendState": "Running", "TailscaleIPs": ["100.64.0.1"],
  "Self": {"ID": "nSELF", "HostName": "box", "DNSName": "box.tail1234.ts.net.", "OS": "linux",
    "UserID": 42, "TailscaleIPs": ["100.64.0.1"], "Online": true, "Active": false,
    "ExitNode": false, "ExitNodeOption": false, "Relay": "", "CurAddr": "",
    "LastSeen": "0001-01-01T00:00:00Z"},
  "MagicDNSSuffix": "tail1234.ts.net", "CertDomains": ["box.tail1234.ts.net"]
}]]

--- The app: who asked, by the headers Serve sends, and whether Funnel
--- brought the request.
local APP <const> = [[
local Tailscale = require("cosmic.tailscale")
local Web = require("cosmic.web")
return function(argv: {string}): integer
  local ts = assert(Tailscale.connect({ port = math.tointeger(tonumber(argv[1])), token = "t" }))
  local app = Web.app{
    middleware = { Web.tailnet({ required = false }) },
    routes = {
      Web.get("/", function(req: Web.Request): Web.Response
        local who = Web.who(req).tailnet
        local admin = who ~= nil and who.caps["example.com/cap/admin"] ~= nil
        return Web.text((if who ~= nil then who.login_name else "nobody" end) .. " admin=" .. tostring(admin) ..
          " funnel=" .. tostring(Web.tailnet_funnel(req)))
      end),
    },
  }
  local ok, why = Web.serve(app, { tailnet = { via = "funnel", client = ts, caps = { "example.com/cap/admin" } } })
  print("served " .. tostring(ok) .. " " .. why)
  return 0
end
]]

--- The stand-in's state.
local record Daemon
  mut config: mut {string: Json.Value}
  --- The streams open now.
  mut open: integer
  --- The socket the app's site passes requests to, once it is filed.
  mut socket: string
  --- What it saw, a line each.
  mut lines: mut {string}
  --- What the app sent back for a request the daemon passed on
  --- before its reply to the configuration, as a daemon may.
  mut early: string
  --- Refuse the configuration, as a daemon whose policy forbids Funnel.
  refuse: boolean
end

--- The stream a foreground configuration is filed under: its end
--- drops the configuration.
local class Watch is Stream.Reader
  daemon: Daemon
  mut started: boolean
  mut ended: boolean
  skip?: function(Watch, integer): (true) | (false, Failure)

  function read(self, _max_bytes?: integer): (string | false) | (nil, Failure)
    if not self.started then
      self.started = true
      return '{"Version":"1.90.0","State":6,"SessionID":"s1"}\n'
    end
    local _, _ = Clock.sleep(Clock.ms(20))
    return "\n"
  end

  function close(self): (true) | (false, Failure)
    if self.ended then return true end
    self.ended = true
    self.daemon.open = self.daemon.open - 1
    self.daemon.config = {}
    self.daemon.lines[#self.daemon.lines + 1] = "dropped"
    return true
  end
end

--- The response at `path` of the app's socket to a request with `headers`.
local function asked(path: string, headers: string): string
  local conn <close> = assert(Net.connect(Net.unix(path), { timeout_ns = Clock.seconds(5) }))
  assert(conn:write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n" .. headers .. "\r\n"))
  local got: mut {string} = {}
  while true do
    local chunk, why = conn:read()
    assert(chunk ~= nil, tostring(why))
    if chunk == false then
      break
    end
    got[#got + 1] = chunk
  end
  local reply = table.concat(got)
  return (reply:match("\r\n\r\n(.*)$") or reply)
end

local function answer(d: Daemon, req: Server.Request): Server.Reply
  local target = req.target
  if target == "/localapi/v0/status" then return { status = 200, body = STATUS } end
  if target == "/localapi/v0/watch-ipn-bus?mask=18" then
    d.open = d.open + 1
    local watch: Watch = { daemon = d, started = false, ended = false, skip = nil }
    return { status = 200, body = watch }
  end
  if target == "/localapi/v0/serve-config" and req.method == "GET" then
    return { status = 200, headers = { ["Etag"] = '"1"' }, body = assert(Json.encode(d.config)) }
  end
  if target == "/localapi/v0/serve-config" and req.method == "POST" then
    local text = assert(Stream.read_all(req.body))
    local config = assert(Json.decode_object(text))
    local stored: mut {string: Json.Value} = {}
    for name, value in pairs(config) do stored[name] = value end
    d.config = stored
    local proxy = text:match('"Proxy":"unix:([^"]+)"') or ""
    local shown = text:gsub('unix:[^"]+', "unix:SOCKET")
    d.lines[#d.lines + 1] = shown
    if d.refuse then
      d.socket = proxy
      return { status = 403, body = "Funnel not available\n" }
    end
    -- Asked before d.socket is set, so the test reads its response
    -- only once it is in.
    d.early = asked(proxy, "Tailscale-User-Login: rene@example.com\r\n" ..
        'Tailscale-App-Capabilities: {"example.com/cap/admin":[{}]}\r\n')
    d.socket = proxy
    return { status = 200 }
  end
  return { status = 404, body = "404 page not found\n" }
end

--- The app files a Funnel site whose one handler is its own private
--- socket and passes on the capabilities named; a request through it
--- names who asked, even one the daemon passes on before it replies to
--- the configuration; one Funnel brought names nobody; and once the app
--- stops, the site is down and the socket's directory is gone.
local function test_an_app_through_funnel_is_served_from_a_private_socket(tmp: string)
  local script = tmp .. "/app.tl"
  assert(Fs.write(script, APP))
  local d: Daemon = { config = {}, open = 0, socket = "", lines = {}, early = "", refuse = false }
  local said: mut {string} = {}
  local function note(line: string) said[#said + 1] = line end
  assert(Server.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    on_stop = function(_: Net.Server) end,
    handle = function(req: Server.Request): Server.Reply return answer(d, req) end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local port = tostring(assert(addresses[1]).port)
      local started = Test.cosmic({ "--standalone", script, port },
        { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
      local child <close> = assert(Child.start(started.argv, started.options))
      local deadline = Clock.monotonic_ns() + Clock.seconds(20)
      while d.socket == "" and Clock.monotonic_ns() < deadline do
        local now = assert(child:try_wait())
        local result = now.result
        if result ~= nil then
          error("the app ended before it filed its site: " .. tostring(result.code) .. " " ..
              tostring(result.stdout) .. " " .. tostring(result.stderr))
        end
        local _, _ = Clock.sleep(Clock.ms(20))
      end
      assert(d.socket ~= "", "the app never filed its site: " .. table.concat(d.lines, "; "))
      local info = assert(Fs.stat(Fs.dirname(d.socket)))
      note(string.format("%o", info.mode & 511))
      note(d.early)
      note(asked(d.socket, "Tailscale-User-Login: rene@example.com\r\n" ..
          'Tailscale-App-Capabilities: {"example.com/cap/admin":[{}]}\r\n'))
      note(asked(d.socket, "Tailscale-Funnel-Request: ?1\r\n"))
      assert(child:stop())
      local result = assert(child:wait(Clock.seconds(30)))
      note((tostring(result.stdout):gsub("%s+$", "")))
      while d.open > 0 and Clock.monotonic_ns() < deadline do
        local _, _ = Clock.sleep(Clock.ms(20))
      end
      note(tostring(not assert(Fs.status(Fs.dirname(d.socket))).exists))
      server:stop()
    end,
  })
  assert(table.concat(said, "\n") == table.concat({
    "700",
    "rene@example.com admin=true funnel=false",
    "rene@example.com admin=true funnel=false",
    "nobody admin=false funnel=true",
    "served true",
    "true",
  }, "\n"), table.concat(said, "\n"))
  local filed = '{"Foreground":{"s1":{"AllowFunnel":{"box.tail1234.ts.net:443":true},' ..
    '"TCP":{"443":{"HTTPS":true}},"Web":{"box.tail1234.ts.net:443":{"Handlers":{"/":' ..
    '{"AcceptAppCaps":["example.com/cap/admin"],"Proxy":"unix:SOCKET"}}}}}}}'
  assert(table.concat(d.lines, "; ") == filed .. "; dropped", table.concat(d.lines, "; "))
end

--- A daemon that refuses the configuration fails the serve, saying why,
--- and the socket's directory is gone.
local function test_a_refused_configuration_fails_the_serve_and_leaves_nothing(tmp: string)
  local script = tmp .. "/app.tl"
  assert(Fs.write(script, APP))
  local d: Daemon = { config = {}, open = 0, socket = "", lines = {}, early = "", refuse = true }
  local said: mut {string} = {}
  assert(Server.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    on_stop = function(_: Net.Server) end,
    handle = function(req: Server.Request): Server.Reply return answer(d, req) end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local port = tostring(assert(addresses[1]).port)
      local started = Test.cosmic({ "--standalone", script, port },
        { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
      local child <close> = assert(Child.start(started.argv, started.options))
      local result = assert(child:wait(Clock.seconds(30)))
      local out = tostring(result.stdout):gsub("%s+$", "")
      said[#said + 1] = out
      local gone = d.socket ~= "" and not assert(Fs.status(Fs.dirname(d.socket))).exists
      local shown = tostring(gone)
      said[#said + 1] = shown
      server:stop()
    end,
  })
  assert(table.concat(said, "\n") ==
      "served false web: tailnet: tailscale: serve-config: Funnel not available (status 403)\ntrue",
    table.concat(said, "\n"))
end
