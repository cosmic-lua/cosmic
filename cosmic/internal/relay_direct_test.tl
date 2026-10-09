--- The relay's process with a `direct` config ([`cosmic.internal.relay_main`]), as
--- macOS's start runs it: it serves the listening sockets it is handed from
--- descriptor 3, which [`cosmic.internal.relay_start`]'s `loopback_listeners` binds
--- at one port of 127.0.0.1 and ::1, each for both protocols behind the
--- config's token, and connects itself. It runs here as this program,
--- standalone, unconfined: what holds it on macOS is
--- cosmic/child_relay_seatbelt_test.tl's.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local RelayConfig = require("cosmic.internal.relay_config")
local RelayStart = require("cosmic.internal.relay_start")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local this_program = require("build.this_program")
local _ = require("build.standalone")
local _ = require("cosmic.internal.relay_main")

--- The program itself, which runs the relay; its servers and its listener
--- are on the loopback.
Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" } }

--- The relay's main, as a standalone script runs it.
local SCRIPT <const> = [[
return require("cosmic.internal.relay_main")
]]

local TOKEN <const> = string.rep("5a", 32)

--- Reads exactly `count` bytes of `conn`, fewer at its end.
local function read_exact(conn: Net.Conn, count: integer): string
  local out = ""
  while #out < count do
    local data, _ = conn:read(count - #out)
    if data == nil then break end
    out = out .. data
  end
  return out
end

--- A connection to the relay at `port` of `host`, 127.0.0.1 by default.
local function dial(port: integer, host?: string): Net.Conn
  local conn = assert(Net.connect(Net.tcp(host or "127.0.0.1", port), { timeout_ns = Clock.seconds(10) }))
  conn:set_timeout(Clock.seconds(10))
  return conn
end

--- Starts the relay's main on `config`, handed `fds`: the process, a writer of
--- its standard input and the lines of its standard output.
local function relay_started(script: string, fds: {integer:integer}): Child.Handle
  local started = this_program.program({ "--standalone", script }, { stdin = "stream", stdout = "stream",
    stderr = "capture", fds = fds, timeout_ns = Clock.seconds(60) })
  return (assert(Child.start(started.argv, started.options)))
end

--- A relay on the host's loopback must be given its token: one listening
--- where every user of the host reaches it does not start without.
local function test_a_direct_relay_without_a_token_does_not_start(tmp: string)
  local script = tmp .. "/relay.tl"
  assert(Fs.write(script, SCRIPT))
  local loopback = assert(RelayStart.loopback_listeners())
  local fds: {integer:integer} = {}
  for i, socket in ipairs(loopback.sockets) do fds[2 + i] = socket:fd() end
  Poll.run(function()
    local relay <close> = relay_started(script, fds)
    local feed, lines = assert(relay.stdin_stream), Stream.lines(assert(relay.stdout_stream))
    assert(feed:write(RelayConfig.encode({ grants = {}, own_addresses = {}, log = "null", direct = true,
      listeners = #loopback.sockets }) .. "\n"))
    assert(lines:read() == "opened")
    local said = assert(lines:read())
    assert(said:find("^error: a relay on the host's loopback needs its token"), said)
    local result = assert(relay:wait(Clock.seconds(20)))
    assert(result.code == 1, tostring(result.code))
  end)
  for _, socket in ipairs(loopback.sockets) do assert(socket:close()) end
end

--- The relay serves both protocols at the port it is handed, on 127.0.0.1
--- and on ::1 where the host has an IPv6 loopback, to a granted server alone,
--- and only with its token; no other listener can take the port; it ends,
--- status 0, once its standard input does.
local function test_a_direct_relay_listens_itself_and_serves_both_protocols_behind_its_token(tmp: string)
  local script = tmp .. "/relay.tl"
  assert(Fs.write(script, SCRIPT))
  Poll.run(function()
    local server = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local other = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local serving = Poll.spawn(function()
      while true do
        local conn = server:accept()
        if conn == nil then return end
        Poll.spawn(function()
          local data = conn:read(4)
          if data ~= nil then local _, _ = conn:write("echo:" .. data) end
          local _, _ = conn:close()
        end)
      end
    end)
    local granted, ungranted = server.address.port, other.address.port
    local loopback = assert(RelayStart.loopback_listeners())
    local port = loopback.port
    local fds: {integer:integer} = {}
    for i, socket in ipairs(loopback.sockets) do fds[2 + i] = socket:fd() end
    local relay <close> = relay_started(script, fds)
    -- The relay holds the port now; this process's hold goes.
    for _, socket in ipairs(loopback.sockets) do assert(socket:close()) end
    local feed, lines = assert(relay.stdin_stream), Stream.lines(assert(relay.stdout_stream))
    assert(feed:write(RelayConfig.encode({ grants = { "127.0.0.1:" .. granted }, own_addresses = {},
      log = "null", direct = true, token = TOKEN, listeners = #loopback.sockets }) .. "\n"))
    assert(lines:read() == "opened")
    assert(lines:read() == "ready")
    local auth = "Proxy-Authorization: Basic " .. Codec.base64("cosmic:" .. TOKEN) .. "\r\n"
    local function connect(target: string, header: string, host?: string): string, string
      local conn = dial(port, host)
      assert(conn:write("CONNECT " .. target .. " HTTP/1.1\r\nHost: " .. target .. "\r\n" .. header .. "\r\n"))
      local head = ""
      while not head:find("\r\n\r\n", 1, true) do
        local data = conn:read(4096)
        if data == nil then break end
        head = head .. data
      end
      local echoed = ""
      if head:find("^HTTP/1.1 200") then
        assert(conn:write("ping"))
        echoed = read_exact(conn, 9)
      end
      local _, _ = conn:close()
      return head:match("^[^\r]*") or "", echoed
    end
    local status, echoed = connect("127.0.0.1:" .. granted, auth)
    assert(status == "HTTP/1.1 200 Connection established" and echoed == "echo:ping", status)
    assert(connect("127.0.0.1:" .. ungranted, auth):find(" 403 not granted", 1, true))
    assert(connect("127.0.0.1:" .. granted, "") == "HTTP/1.1 407 Proxy Authentication Required")
    local socks = dial(port)
    assert(socks:write("\5\1\2"))
    assert(read_exact(socks, 2) == "\5\2")
    assert(socks:write("\1\6cosmic" .. string.char(#TOKEN) .. TOKEN))
    assert(read_exact(socks, 2) == "\1\0")
    assert(socks:write("\5\1\0\1\127\0\0\1" .. string.pack(">I2", granted)))
    assert(read_exact(socks, 10):byte(2) == 0, "the SOCKS5 request is served")
    assert(socks:write("pong"))
    assert(read_exact(socks, 9) == "echo:pong")
    local _, _ = socks:close()
    -- Where this host has an IPv6 loopback the relay holds its port there
    -- too, serving it as it serves 127.0.0.1; no other listener can take it.
    local v6, _ = Net.listen(Net.tcp("::1", 0))
    assert((v6 ~= nil) == (#loopback.sockets == 2), "::1 is held where the host has it, and only there")
    if v6 ~= nil then
      assert(v6:close())
      local taken, taken_why = Net.listen(Net.tcp("::1", port))
      assert(taken == nil, "another listener took the relay's port on ::1")
      assert(taken_why ~= "")
      local over_v6, echoed_v6 = connect("127.0.0.1:" .. granted, auth, "::1")
      assert(over_v6 == "HTTP/1.1 200 Connection established" and echoed_v6 == "echo:ping", over_v6)
      assert(connect("127.0.0.1:" .. granted, "", "::1") == "HTTP/1.1 407 Proxy Authentication Required")
    end
    local taken_v4, _ = Net.listen(Net.tcp("127.0.0.1", port))
    assert(taken_v4 == nil, "another listener took the relay's port on 127.0.0.1")
    assert(feed:close())
    local result = assert(relay:wait(Clock.seconds(20)))
    assert(result.code == 0, "exit " .. tostring(result.code) .. ": " .. tostring(result.stderr))
    serving:cancel()
    assert(server:close())
    assert(other:close())
  end)
end
