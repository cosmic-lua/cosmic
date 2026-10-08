--- The relay's process with a `direct` config ([`cosmic.relay.main`]), as
--- macOS's start runs it: it listens itself, at a port of 127.0.0.1 the
--- kernel chooses that its `ready` line names, one port for both protocols
--- behind the config's token, and connects itself. It runs here as this
--- program, standalone, unconfined: what holds it on macOS is
--- cosmic/child_relay_seatbelt_test.tl's.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local RelayConfig = require("cosmic.relay.config")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local this_program = require("build.this_program")
local _ = require("build.standalone")
local _ = require("cosmic.relay.main")

--- The program itself, which runs the relay; its servers and its listener
--- are on the loopback.
Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" } }

--- The relay's main, as a standalone script runs it.
local SCRIPT <const> = [[
return require("cosmic.relay.main")
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

--- A connection to the relay at `port`.
local function dial(port: integer): Net.Conn
  local conn = assert(Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = Clock.seconds(10) }))
  conn:set_timeout(Clock.seconds(10))
  return conn
end

--- The relay serves both protocols at the one port it says, to a granted
--- server alone, and only with its token; it ends, status 0, once its
--- standard input does.
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
    local started = this_program.program({ "--standalone", script }, { stdin = "stream", stdout = "stream",
      stderr = "capture", timeout_ns = Clock.seconds(60) })
    local relay <close> = assert(Child.start(started.argv, started.options))
    local feed, lines = assert(relay.stdin_stream), Stream.lines(assert(relay.stdout_stream))
    assert(feed:write(RelayConfig.encode({ grants = { "127.0.0.1:" .. granted }, own_addresses = {},
      log = "null", direct = true, token = TOKEN }) .. "\n"))
    assert(lines:read() == "opened")
    local ready = assert(lines:read())
    local port = math.tointeger(tonumber(ready:match("^ready (%d+)$") or ""))
    assert(port ~= nil and port ~= granted and port ~= ungranted, ready)
    local auth = "Proxy-Authorization: Basic " .. Codec.base64("cosmic:" .. TOKEN) .. "\r\n"
    local function connect(target: string, header: string): string, string
      local conn = dial(port)
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
    assert(feed:close())
    local result = assert(relay:wait(Clock.seconds(20)))
    assert(result.code == 0, "exit " .. tostring(result.code) .. ": " .. tostring(result.stderr))
    serving:cancel()
    assert(server:close())
    assert(other:close())
  end)
end
