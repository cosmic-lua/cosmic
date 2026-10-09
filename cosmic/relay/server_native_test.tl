--- The relay over the sandbox's native connector (core/connector.c), by
--- `Net.connector`: a public-only connector, whose process connects the
--- numeric endpoint the relay has checked and returns the socket over
--- the control stream.
local Clock = require("cosmic.clock")
local Fixture = require("build.relay_wire_fixture")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Relay = require("cosmic.relay.server")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local type raw_process = require("cosmic.internal.process")
local type _ = require("cosmic.child")

Test.policy{ loopback = { "127.0.0.1" }, promises = { "fork" } }

-- TODO: run this on macOS once Seatbelt confines the connector by numeric remote
-- rules (#2820, the sandbox plan's phase 8): the connector is Linux x86_64 and aarch64
-- only, and the test skips elsewhere.

local type Searcher = function(string): any, any

local function table_for(wrapper: string): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: a loader's extra is the raw table
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then
      return extra
    end
  end
  error("no raw table")
end

local process = table_for("cosmic.child") as raw_process -- cast: core/process.h's table

local function require_native_connector()
  local result, why, number = process.connector_probe({ host = "127.0.0.1", port = 9 }, "pointer")
  if result == nil and (number == sys.ENOSYS or number == sys.EOPNOTSUPP) then
    Test.skip("this host has no native connector confinement: " .. why)
  end
  assert(result == sys.EPERM, "native connector setup failed: " .. (why or ""))
end

--- Reads exactly `count` bytes.
local function read_exact(conn: Net.Conn, count: integer): string
  local out = ""
  while #out < count do
    local data, why = conn:read(count - #out)
    assert(data ~= nil, "the connection ended after " .. #out .. " of " .. count .. " bytes: " .. why)
    out = out .. data
  end
  return out
end

local function test_the_relay_connects_through_the_native_connector()
  require_native_connector()
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local port = listener.address.port
    local echoed = Poll.spawn(function()
      while true do
        local conn = listener:accept()
        if conn == nil then
          return
        end
        Poll.spawn(function()
          while true do
            local data, _ = conn:read()
            if data == nil then
              break
            end
            local _, _ = conn:write(data)
          end
          local _, _ = conn:close()
        end)
      end
    end)
    local front = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    -- A port that was free a moment ago.
    local free = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local closed = free.address.port
    local _, _ = free:close()
    local asked = 0
    local connector = assert(Net.connector({}, { public = { deny = {} } }))
    local log: {string} = {}
    local relay = Relay.start({
      http = front, grants = { "127.0.0.1:" .. port, "127.0.0.1:" .. closed },
      connector = function(address: string, to: integer, timeout_ns: integer): Net.Conn | nil, string
        asked = asked + 1
        return connector:connect(Net.tcp(address, to), { timeout_ns = timeout_ns })
      end,
      log = function(line: string)
        log[#log + 1] = line
      end,
    })
    local function dial(): Net.Conn
      local conn = assert(Net.connect(front.address, { timeout_ns = Clock.seconds(5) }))
      conn:set_timeout(Clock.seconds(5))
      return conn
    end
    local conn = dial()
    assert(conn:write(Fixture.connect("127.0.0.1:" .. port)))
    local head = ""
    while not head:find("\r\n\r\n", 1, true) do
      head = head .. assert(conn:read(1))
    end
    assert(head:find("^HTTP/1.1 200 "), head)
    assert(conn:write("through the connector"))
    assert(read_exact(conn, 21) == "through the connector")
    assert(asked == 1)
    local _, _ = conn:close()
    -- A port nothing listens at: the connector's errno is the reason.
    local refused = dial()
    assert(refused:write(Fixture.connect("127.0.0.1:" .. closed)))
    local answer = ""
    while not answer:find("\r\n\r\n", 1, true) do
      answer = answer .. assert(refused:read(1))
    end
    -- Whatever took the port since, nothing answers a CONNECT there: the reason is the connector's.
    assert(answer:find("^HTTP/1.1 502 could not connect to 127.0.0.1:" .. closed .. ": "), answer)
    local _, _ = refused:close()
    relay:stop()
    relay:wait()
    assert(connector:close())
    echoed:cancel()
    local _, _ = listener:close()
    local _, _ = front:close()
    assert(#log == 2 and log[1]:find("allowed via 127.0.0.1:" .. port, 1, true), table.concat(log, "\n"))
    assert(log[2]:find("refused: could not connect to 127.0.0.1:" .. closed .. ": ", 1, true), log[2])
  end)
end
