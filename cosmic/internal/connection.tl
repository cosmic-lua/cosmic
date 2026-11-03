--- The types of a connection, which [`cosmic.net`] re-exports as
--- [`Net.Conn`] and [`Net.ConnectOptions`]. They are declared here, below
--- [`cosmic.net`], so that the native connector's client
--- ([`cosmic.internal.connector`]) can answer a connection without
--- requiring cosmic.net. The client is required by cosmic.child, which
--- cosmic.net requires: naming cosmic.net's types from it would be an
--- import cycle.

local Poll = require("cosmic.poll")
local sys = require("cosmic.sys")
local type Stream = require("cosmic.stream")
local type raw_socket = require("cosmic.internal.socket")

local raw = require("cosmic.internal.socket")

local DEFAULT_READ <const> = 64 * 1024

--- Waits for `fd` to be readable, or writable, at most `timeout_ns`, which
--- the caller has held to what a wait can last: in a
--- task of a run, through it; anywhere else, in the raw wait, which
--- also ends at a signal the innermost [`Signal.guard`] caught.
local function waited(fd: integer, writable: boolean, timeout_ns: integer?): boolean, string
  -- TODO: wait through Poll.wait alone, and in `connection` too, once
  -- cosmic.poll has what the raw wait outside a task has: a core binding
  -- that gives it the core's cosmic_signal_caught (only core/socket.c's
  -- waits and sys.flock read it today), a fourth shared answer word for
  -- a wait a signal interrupted, and a loop in Poll.wait outside a task
  -- that polls in slices to look for one. A Conn's read and write are
  -- then Stream.from_fd and Stream.to_fd (see the TODO at SocketConn:read
  -- in this file).
  if Poll.in_task() then
    return Poll.wait(fd, if writable then sys.POLLOUT else sys.POLLIN end, timeout_ns)
  end
  local ok, trouble, errno = raw.wait(fd, writable, Poll.milliseconds(timeout_ns))
  if ok then return true, "" end
  if errno == raw.ETIMEDOUT then return false, Poll.TIMEOUT end
  if errno == raw.EINTR then return false, "interrupted" end
  return false, trouble
end

--- Which direction of a connection [`SocketConn.shutdown`] ends.
local enum Shutdown
  "read"
  "write"
  "both"
end

-- What a connection is to a caller that reads and writes it: a class implements
-- one interface, so the two are listed together here.
local interface Duplex is Stream.Reader, Stream.Writer
end

--- A connection, answered by `accept` and [`Net.connect`]: a
--- [`Stream.Reader`] of what the peer sends and a [`Stream.Writer`] to
--- it. A class, so a `<close>` local holds one. One dropped unclosed
--- needs no __gc: its socket, which only the connection holds, is closed
--- by the collector.
local class SocketConn is Duplex
  --- Internal: the socket, its descriptor and whether it is open. No caller reads or writes them.
  socket: raw_socket.Socket
  --- Internal: see `socket`.
  fd: integer
  --- Internal: see `socket`.
  mut open: boolean
  --- Internal: set by [`set_timeout`], and read by each wait, so a change reaches a
  --- wait the next read or write starts. Nil for no limit. No caller reads or writes it.
  mut limit?: integer
  --- Internal: each direction's sticky failure, "" until one: once a read or a
  --- write fails for good, every later one of it says so. No caller reads or writes them.
  mut read_failure: string
  --- Internal: see `read_failure`.
  mut write_failure: string
  --- Never present: [`Stream.skip`] reads and discards a connection's bytes.
  skip?: function(SocketConn, n: integer): boolean, string

  --- Sets how long a `read` or a `write` waits, in nanoseconds, from 0;
  --- nil for no limit. A connection starts with the `timeout_ns` it
  --- was made with: [`Net.connect`]'s, or its listener's or server's.
  --- A value no wait can last raises, naming `timeout_ns`, at the
  --- caller.
  function set_timeout(self, wait_ns: integer?)
    Poll.checked_ns(wait_ns, "net", "timeout_ns", 2)
    self.limit = wait_ns
  end

  -- TODO: make a Conn's `read` and `write` the Reader and Writer
  -- Stream.from_fd and Stream.to_fd answer over the socket
  -- ({ nonblocking = true, timeout_ns }), collapsing the write loop here into
  -- theirs, once the TODO in `waited` is done: a wait outside a task here
  -- ends at a signal a Signal.guard caught ("interrupted", which net_test's
  -- cases hold), which Poll.wait cannot see. Their `wait` option could
  -- carry `waited`, but `write` also sends through raw.send, which never
  -- raises SIGPIPE where sys.write may, and reads the timeout [`set_timeout`]
  -- changes on every call, which an option fixes when the object is made.
  --- What has arrived, at most `max_bytes` bytes (64 KiB by default), once
  --- something has; nil and "" once the peer has ended what it sends.
  --- nil and [`Poll.TIMEOUT`], "interrupted" or "cancelled" (in a task of
  --- [`Poll.run`]) takes nothing, and a later read may still answer; nil
  --- and any other failure is every read's after. A failed read leaves
  --- writing be. A `max_bytes` below 1 raises.
  function read(self, max_bytes?: integer): string?, string
    if max_bytes ~= nil and max_bytes <= 0 then
      error("net: read's max_bytes must be positive", 2)
    end
    if not self.open then return nil, "net: the connection is closed" end
    if self.read_failure ~= "" then return nil, self.read_failure end
    local fd = self.fd
    while true do
      local data, why, errno = sys.read(fd, max_bytes or DEFAULT_READ)
      if data == "" then return nil, "" end
      if data ~= nil then return data, "" end
      if errno ~= raw.EAGAIN then
        self.read_failure = why
        return nil, why
      end
      -- Nothing was taken: a deadline or a signal leaves the next
      -- read to try again.
      local ready, waiting = waited(fd, false, self.limit)
      if not ready then return nil, waiting end
      -- Another task may have closed the connection while this one
      -- waited in a run, and its descriptor gone to another socket.
      if not self.open then return nil, "net: the connection is closed" end
    end
  end

  --- Sends all of `data`, waiting as the peer takes it. False and
  --- [`Poll.TIMEOUT`], "interrupted", "cancelled" (in a task of [`Poll.run`])
  --- or why not may leave part of it sent,
  --- so it is every write's after; reading is left be.
  function write(self, data: string): boolean, string
    if not self.open then return false, "net: the connection is closed" end
    if self.write_failure ~= "" then return false, self.write_failure end
    local fd = self.fd
    local from = 1
    while from <= #data do
      local sent, why, errno = raw.send(fd, data, from)
      if sent ~= nil then
        from = from + sent
      elseif errno ~= raw.EAGAIN then
        self.write_failure = why
        return false, why
      else
        local ready, waiting = waited(fd, true, self.limit)
        if not ready then
          self.write_failure = waiting
          return false, waiting
        end
        if not self.open then return false, "net: the connection is closed" end
      end
    end
    return true, ""
  end

  --- Where the peer is: its numeric TCP address, as the kernel names it
  --- (an IPv4 client of a dual-stack listener may be an IPv4-mapped
  --- IPv6 one). Nil and why where it has none to give: a unix
  --- connection (EAFNOSUPPORT), a peer that has reset the connection
  --- (ENOTCONN on Linux, EINVAL on macOS), or a connection already
  --- closed.
  -- TODO: answer a unix connection's peer too, once core/socket.c's
  -- `peer` does (its Address needs a path, which an unbound client
  -- has none of).
  function peer(self): raw_socket.Address?, string
    if not self.open then return nil, "net: the connection is closed" end
    local address, why = raw.peer(self.fd)
    if address == nil then return nil, why end
    return address, ""
  end

  --- Ends one direction, or both: after "write" the peer reads the
  --- end of what was sent, and this side can still read its answer.
  --- A `how` that is none of "read", "write" and "both" is refused where
  --- it is written; a caller the checker does not read raises.
  function shutdown(self, how: Shutdown): boolean, string
    -- The type refuses a wrong `how` in checked code; this is for a caller
    -- the checker does not read.
    if how ~= "read" and how ~= "write" and how ~= "both" then
      error("net: how must be \"read\", \"write\" or \"both\"", 2)
    end
    if not self.open then return false, "net: the connection is closed" end
    local ok, why = raw.shutdown(self.fd, how)
    if not ok then return false, why end
    return true, ""
  end

  --- Closes the connection. Safe to call more than once.
  function close(self): boolean, string
    if not self.open then return true, "" end
    self.open = false
    Poll.closing(self.fd)
    local ok, why = self.socket:close()
    if not ok then return false, why end
    return true, ""
  end

  --- The same as `close`: nothing sent can be taken back.
  function abort(self): boolean, string
    return self:close()
  end

  function __close(self)
    local _, _ = self:close()
  end
end

local record Connection
  type Address = raw_socket.Address

  record ConnectOptions
    --- How long connecting, and then any one read or write, waits, in
    --- nanoseconds, from 0; nil for no limit. A TCP connection is
    --- waited on until made or refused. Connecting to a unix one waits
    --- for nothing: a listener whose backlog is full fails it at once,
    --- "Resource temporarily unavailable (the listener is busy: its
    --- backlog is full)" on Linux and "Connection refused" on macOS,
    --- which cannot tell a busy listener from none. A caller that would
    --- wait for room connects again. A [`Net.Connector`]'s `connect` waits
    --- `min(timeout_ns, ceiling)` to connect instead, the ceiling being
    --- [`ConnectorOptions.timeout_ns`], and a nil `timeout_ns` waits the
    --- ceiling; the connection's reads and writes wait `timeout_ns` as here.
    timeout_ns?: integer
  end

  --- Which direction of a connection [`SocketConn.shutdown`] ends.
  type Shutdown = Shutdown

  --- A connection, answered by `accept` and [`Net.connect`]: a
  --- [`Stream.Reader`] of what the peer sends and a [`Stream.Writer`] to
  --- it. A class, so a `<close>` local holds one.
  type Conn = SocketConn

  --- The connection over `socket`, waiting `timeout_ns` on its reads and writes.
  new: function(socket: raw_socket.Socket, timeout_ns: integer?): Conn

  --- Waits for `fd` to be readable, or writable, at most `timeout_ns`.
  waited: function(fd: integer, writable: boolean, timeout_ns: integer?): boolean, string
end

function Connection.new(socket: raw_socket.Socket, timeout_ns: integer?): SocketConn
  local conn: SocketConn = {
    socket = socket, fd = socket:fd(), open = true, limit = timeout_ns,
    read_failure = "", write_failure = "", skip = nil }
  return conn
end

function Connection.waited(fd: integer, writable: boolean, timeout_ns: integer?): boolean, string
  return waited(fd, writable, timeout_ns)
end

return Connection
