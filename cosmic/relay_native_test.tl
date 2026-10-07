--- The relay over the sandbox's native connector (core/connector.c): one
--- connector process for each connection, started with the single numeric
--- endpoint the relay has checked, whose connected socket comes back over
--- the control stream.
local Clock = require("cosmic.clock")
local Fixture = require("build.relay_wire_fixture")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Relay = require("cosmic.relay")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local type raw_process = require("cosmic.internal.process")
local type raw_socket = require("cosmic.internal.socket")
local type _ = require("cosmic.child")

Test.policy{ loopback = { "127.0.0.1" }, promises = { "fork" } }

-- TODO: run this on macOS once Seatbelt confines the connector by numeric remote
-- rules (the sandbox plan's phase 8): the connector is Linux x86_64 and aarch64
-- only, and the test skips elsewhere.

-- TODO: move the connector's adapter below into cosmic.net (a [`Net.connect`]
-- through the native connector) once cosmic.net may start one: the raw process
-- table reaches only cosmic.child, cosmic.proc, cosmic.sandbox and build.confine
-- today (core/store.c's raw_modules), so this test takes it as core/connector_test.tl does.
local type Searcher = function(string): any, any

local function table_for(wrapper: string): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then
      return extra
    end
  end
  error("no raw table")
end

local process = table_for("cosmic.child") as raw_process
local socket = table_for("cosmic.net") as raw_socket

--- A connected socket as the relay holds a connection.
local record Held is Net.Conn
  socket: raw_socket.Socket
  fd: integer
  open: boolean
  limit: integer
  set_timeout: function(Held, wait_ns: integer | nil)
  read: function(Held, max_bytes?: integer): string | nil, string
  write: function(Held, data: string): boolean, string
  shutdown: function(Held, how: string): boolean, string
  close: function(Held): boolean, string
  abort: function(Held): boolean, string
end

local held_mt: metatable<Held> = {
  __index = Held,
  __close = function(self: Held)
    local _, _ = self:close()
  end,
}

function Held:set_timeout(wait_ns: integer | nil)
  self.limit = wait_ns
end

function Held:read(max_bytes?: integer): string | nil, string
  if not self.open then
    return nil, "the connection is closed"
  end
  while true do
    local data, why, errno = sys.read(self.fd, max_bytes or 65536)
    if data == "" then
      return nil, ""
    end
    if data ~= nil then
      return data, ""
    end
    if errno ~= socket.EAGAIN then
      return nil, why
    end
    local ready, waiting = Poll.readable(self.fd, self.limit)
    if not ready then
      return nil, waiting
    end
    if not self.open then
      return nil, "the connection is closed"
    end
  end
end

function Held:write(data: string): boolean, string
  local from = 1
  while from <= #data do
    if not self.open then
      return false, "the connection is closed"
    end
    local sent, why, errno = socket.send(self.fd, data, from)
    if sent ~= nil then
      from = from + sent
    elseif errno ~= socket.EAGAIN then
      return false, why
    else
      local ready, waiting = Poll.writable(self.fd, self.limit)
      if not ready then
        return false, waiting
      end
    end
  end
  return true, ""
end

function Held:shutdown(how: string): boolean, string
  if not self.open then
    return false, "the connection is closed"
  end
  local ok, why = socket.shutdown(self.fd, how)
  return ok, why
end

function Held:close(): boolean, string
  if not self.open then
    return true, ""
  end
  self.open = false
  Poll.closing(self.fd)
  local ok, why = self.socket:close()
  return ok, why
end

function Held:abort(): boolean, string
  return self:close()
end

--- Reads exactly `count` bytes of the control stream, waiting for them.
local function control_read(fd: integer, count: integer, deadline: integer): string | nil, string
  local out = ""
  while #out < count do
    local data, why, errno = sys.read(fd, count - #out)
    if data == "" then
      return nil, "the connector ended before it replied"
    elseif data ~= nil then
      out = out .. data
    elseif errno ~= socket.EAGAIN then
      return nil, why
    else
      local ready, waiting = Poll.readable(fd, math.max(0, deadline - Clock.monotonic_ns()))
      if not ready then
        return nil, waiting
      end
    end
  end
  return out, ""
end

--- A relay connector over the native one: starts a connector confined to
--- `address`:`port`, asks it once, and takes the connected socket it passes.
local function native(address: string, port: integer, timeout_ns: integer): Net.Conn | nil, string
  local pair, why = process.connector_pair()
  if pair == nil then
    return nil, why
  end
  local control = pair[1]
  local pid, trouble = process.connector_start({ { host = address, port = port } }, pair[2], timeout_ns // Clock.ms(1))
  assert(sys.close(pair[2]))
  local function done(reason: string): nil, string
    assert(sys.close(control))
    if pid ~= nil then
      local _, _ = process.waitpid(pid, false)
    end
    return nil, reason
  end
  if pid == nil then
    return done(trouble)
  end
  assert(sys.set_nonblocking(control, true))
  assert(sys.write(control, string.pack(">I4I4", 1, port)) == 8)
  local deadline = Clock.monotonic_ns() + timeout_ns + Clock.seconds(1)
  local status, saying = control_read(control, 4, deadline)
  if status == nil then
    return done(saying)
  end
  local errno = string.unpack(">I4", status)
  if errno ~= 0 then
    return done(sys.errno_message(errno))
  end
  local ready, waiting = Poll.readable(control, math.max(0, deadline - Clock.monotonic_ns()))
  if not ready then
    return done(waiting)
  end
  local received, because = socket.recvfds(control, 1)
  if received == nil then
    return done(because)
  end
  assert(sys.close(control))
  local _, _ = process.waitpid(pid, false)
  local connection: Held = setmetatable({
    socket = received[1], fd = received[1]:fd(), open = true, limit = timeout_ns,
  }, held_mt)
  return connection, ""
end

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
    local log: {string} = {}
    local relay = Relay.start({
      http = front, grants = { "127.0.0.1:" .. port, "127.0.0.1:" .. closed },
      connector = function(address: string, to: integer, timeout_ns: integer): Net.Conn | nil, string
        asked = asked + 1
        return native(address, to, timeout_ns)
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
    assert(answer:find("^HTTP/1.1 502 could not connect to 127.0.0.1:" .. closed .. ": Connection refused"), answer)
    local _, _ = refused:close()
    relay:stop()
    relay:wait()
    echoed:cancel()
    local _, _ = listener:close()
    local _, _ = front:close()
    assert(#log == 2 and log[1]:find("allowed via 127.0.0.1:" .. port, 1, true), table.concat(log, "\n"))
    assert(log[2]:find("refused: could not connect to 127.0.0.1:" .. closed .. ": Connection refused", 1, true), log[2])
  end)
end
