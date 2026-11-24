--- The types of a connection, which [`cosmic.net`] re-exports as
--- [`Net.Conn`] and [`Net.ConnectOptions`], and the connection over a
--- connected socket that [`Net.connect`] and a listener's `accept`
--- answer.

local Clock = require("cosmic.clock")
local Failure = require("cosmic.failure")
local Poll = require("cosmic.poll")
local Tls = require("cosmic.tls")
local sys = require("cosmic.sys")
local type Stream = require("cosmic.stream")
local type raw_socket = require("cosmic.internal.socket")
local type raw_tls = require("cosmic.internal.tls")

local raw = require("cosmic.internal.socket")
local tls = require("cosmic.internal.tls")

--- The [`Failure`] for the words a read failed with: kind "timeout" for
--- [`Poll.TIMEOUT`], "cancelled" for [`Poll.CANCELLED`] and for
--- "interrupted" (a signal a [`Signal.guard`] caught), else "other".
local function failure_of(why: string): Failure
  if why == Poll.TIMEOUT then return Failure.timeout(why) end
  if why == Poll.CANCELLED or why == "interrupted" then return Failure.cancelled(why) end
  return Failure.new(why)
end

local DEFAULT_READ <const> = 64 * 1024

--- The most a TLS session's read answers: one record's plaintext.
local RECORD_BYTES <const> = 16 * 1024

--- How often [`SocketConn.wait_gone`] asks whether the peer has gone,
--- where the system has no event that says it (macOS).
local GONE_SLICE_NS <const> = Clock.ms(250)

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
    local ready, why = Poll.wait(fd, if writable then sys.POLLOUT else sys.POLLIN end, timeout_ns)
    if not ready then return false, why.message end
    return true, ""
  end
  local ok, trouble, errno = raw.wait(fd, writable, Poll.milliseconds(timeout_ns))
  if ok then return true, "" end
  if errno == raw.ETIMEDOUT then return false, Poll.TIMEOUT end
  if errno == raw.EINTR then return false, "interrupted" end
  return false, trouble
end

--- When a call that waits `limit` (nil for no limit) from now must end.
local function deadline_of(limit: integer?): integer?
  if limit == nil then return nil end
  return Clock.monotonic_ns() + limit
end

--- What is left of a wait that ends at `deadline`, from 0; nil for none.
local function left(deadline: integer?): integer?
  if deadline == nil then return nil end
  return math.max(deadline - Clock.monotonic_ns(), 0)
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
  skip?: function(SocketConn, n: integer): (true) | (false, Failure)
  --- Internal: the TLS session every read and write goes through, on a
  --- connection a TLS listener accepted or [`start_tls`] secured; nil
  --- for one in the clear. No caller reads or writes it.
  mut session?: raw_tls.Session
  --- The address of the listener that accepted it, as the listener
  --- was given it; nil for a connection [`Net.connect`] made.
  mut listener?: raw_socket.Address

  --- Sets how long a `read` or a `write` waits, in nanoseconds, from 0;
  --- nil for no limit. It bounds a whole `write`; and a whole `read` on
  --- a connection a TLS listener accepted, the handshake and every wait
  --- for a record's bytes with it, but each wait of a `read` in the
  --- clear. A connection starts with the `timeout_ns` it
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
  --- something has; `false` once the peer has ended what it sends. Nil
  --- and a [`Failure`] of kind "timeout" or "cancelled" (a caught signal,
  --- or a cancel in a task of [`Poll.run`]) takes nothing, and a later
  --- read may still answer; nil and any other Failure is every read's after. A failed read leaves
  --- writing be. A `max_bytes` below 1 raises.
  function read(self, max_bytes?: integer): (string | false) | (nil, Failure)
    if max_bytes ~= nil and max_bytes <= 0 then
      error("net: read's max_bytes must be positive", 2)
    end
    if not self.open then return nil, failure_of("net: the connection is closed") end
    if self.read_failure ~= "" then return nil, failure_of(self.read_failure) end
    local fd = self.fd
    local session = self.session
    if session ~= nil then
      -- One deadline for the call, however many waits a handshake or a
      -- record takes: a peer sending a byte a wait would hold a read for
      -- ever, and the server's head and idle deadlines with it.
      local deadline = deadline_of(self.limit)
      while true do
        local data, why, stop = session:read(math.min(max_bytes or RECORD_BYTES, RECORD_BYTES))
        if data ~= nil then return data end
        -- TODO: an end with no close_notify (a TCP end alone) is ENDED as
        -- close_notify is, so an HTTP/1.x body read to the connection's end
        -- cannot tell truncation from the end: answer the two apart here,
        -- from core/tls.c, and refuse a body so cut, once #3853 merges.
        if stop == tls.ENDED then return false end
        if stop == tls.FAILED then
          self.read_failure = why
          return nil, failure_of(why)
        end
        local ready, waiting = waited(fd, stop == tls.WRITE, left(deadline))
        if not ready then return nil, failure_of(waiting) end
        if not self.open then return nil, failure_of("net: the connection is closed") end
      end
    end
    while true do
      local data, why, errno = sys.read(fd, max_bytes or DEFAULT_READ)
      if data == "" then return false end
      if data ~= nil then return data end
      if errno ~= raw.EAGAIN then
        self.read_failure = why
        return nil, failure_of(why)
      end
      -- Nothing was taken: a deadline or a signal leaves the next
      -- read to try again.
      local ready, waiting = waited(fd, false, self.limit)
      if not ready then return nil, failure_of(waiting) end
      -- Another task may have closed the connection while this one
      -- waited in a run, and its descriptor gone to another socket.
      if not self.open then return nil, failure_of("net: the connection is closed") end
    end
  end

  --- Sends all of `data`, waiting as the peer takes it. False and a
  --- [`Failure`] (kind "timeout" for a deadline, "cancelled" for
  --- "interrupted" or a task of [`Poll.run`] cancelled) may leave part of it sent,
  --- so it is every write's after; reading is left be.
  function write(self, data: string): (true) | (false, Failure)
    if not self.open then return false, failure_of("net: the connection is closed") end
    if self.write_failure ~= "" then return false, failure_of(self.write_failure) end
    local fd = self.fd
    local from = 1
    local session = self.session
    if session ~= nil then
      local deadline = deadline_of(self.limit)
      while from <= #data do
        local took, why, stop = session:write(data, from)
        if took ~= nil then
          from = from + took
        elseif stop == tls.FAILED or stop == tls.ENDED then
          local trouble = if stop == tls.ENDED then "tls: the peer ended the session" else why end
          self.write_failure = trouble
          return false, failure_of(trouble)
        else
          local ready, waiting = waited(fd, stop == tls.WRITE, left(deadline))
          if not ready then
            self.write_failure = waiting
            return false, failure_of(waiting)
          end
          if not self.open then return false, failure_of("net: the connection is closed") end
        end
      end
      return true
    end
    -- One deadline for the call, as over TLS: a peer that takes a byte
    -- each wait would hold the write for ever.
    local deadline = deadline_of(self.limit)
    while from <= #data do
      local sent, why, errno = raw.send(fd, data, from)
      if sent ~= nil then
        from = from + sent
      elseif errno ~= raw.EAGAIN then
        self.write_failure = why
        return false, failure_of(why)
      else
        local ready, waiting = waited(fd, true, left(deadline))
        if not ready then
          self.write_failure = waiting
          return false, failure_of(waiting)
        end
        if not self.open then return false, failure_of("net: the connection is closed") end
      end
    end
    return true
  end

  --- Completes the TLS handshake of a connection a TLS listener
  --- accepted, or [`start_tls`] or [`serve_tls`] secured, waiting as a
  --- read does; true at once for one in the clear, and for one whose
  --- handshake is done. A read or a write
  --- handshakes first by itself: this is for a caller that would know
  --- what [`tls`] says before it reads. False and why otherwise, which
  --- is every read's and write's after.
  function handshake(self): boolean, string
    local session = self.session
    if session == nil then return true, "" end
    if not self.open then return false, "net: the connection is closed" end
    if self.read_failure ~= "" then return false, self.read_failure end
    local deadline = deadline_of(self.limit)
    while true do
      local done, why, stop = session:handshake()
      if done then return true, "" end
      if stop == tls.FAILED or stop == tls.ENDED then
        local trouble = if stop == tls.ENDED then "tls: the peer left during the handshake" else why end
        self.read_failure = trouble
        self.write_failure = trouble
        return false, trouble
      end
      local ready, waiting = waited(self.fd, stop == tls.WRITE, left(deadline))
      if not ready then return false, waiting end
      if not self.open then return false, "net: the connection is closed" end
    end
  end

  --- What the TLS handshake settled -- the version, the protocol ALPN
  --- chose, the name asked for, the peer's certificate ([`Tls.Info`])
  --- -- on a connection over TLS, once [`handshake`] or a read has
  --- completed it; nil for a connection in the clear, or one closed.
  function tls(self): Tls.Info?
    local session = self.session
    if session == nil or not self.open then return nil end
    return Tls.info(session)
  end

  --- Secures a connection in the clear as the client of a TLS session
  --- of `client`, and completes its handshake, waiting as a read does:
  --- what STARTTLS does once the peer has agreed to it. It asks for
  --- `server_name` (SNI), and, where `client` verifies, the server's
  --- certificate must name it: a DNS name, or an IP address among the
  --- certificate's own. Every read and write after goes through the
  --- session. Bytes the peer sent in the clear after the request to
  --- start TLS were never read here, so they are read as TLS: a buffer
  --- the caller read ahead into ([`Stream.lines`]) must hold none. True,
  --- or false and why: the handshake failed, the chain or name did not
  --- verify, or the key is not pinned. A connection that fails so is
  --- left of no further use but to close. Raises on one already over
  --- TLS.
  function start_tls(self, client: Tls.Client, server_name?: string): boolean, string
    if self.session ~= nil then error("net: the connection is already over TLS", 2) end
    if not self.open then return false, "net: the connection is closed" end
    local session, why = client:session(self.fd, server_name)
    if session == nil then
      self.read_failure = why
      self.write_failure = why
      return false, why
    end
    self.session = session
    local done, failed = self:handshake()
    if not done then
      local trouble = client:explained(failed)
      self.write_failure = trouble
      self.read_failure = trouble
      return false, trouble
    end
    local accepted, refused = client:accepts(Tls.info(session))
    if not accepted then
      self.read_failure = refused
      self.write_failure = refused
      return false, refused
    end
    return true, ""
  end

  --- Secures a connection in the clear as the server of a TLS session,
  --- presenting `certs`'s newest pairs, and completes its handshake,
  --- waiting as a read does: a server's side of STARTTLS. What
  --- [`start_tls`] says of bytes read ahead holds here too. `certs` is
  --- loaded where it is not yet ([`Tls.Certs.load`]), and not renewed
  --- here: a server that holds it renews it. True, or false and why. A
  --- connection that fails so is of no further use but to close. Raises
  --- on one already over TLS.
  function serve_tls(self, certs: Tls.Certs): boolean, string
    if self.session ~= nil then error("net: the connection is already over TLS", 2) end
    if not self.open then return false, "net: the connection is closed" end
    local config = certs:config()
    if config == nil then
      local loaded, why = certs:load()
      if not loaded then return false, why end
      config = assert(certs:config(), "tls: a load that succeeded left no configuration")
    end
    local session, why = tls.session(config, self.fd)
    if session == nil then
      self.read_failure = why
      self.write_failure = why
      return false, why
    end
    self.session = session
    return self:handshake()
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

  --- Whether the peer has gone: it has closed the connection, ended
  --- what it sends ([`shutdown`] "write" at its end) or reset it. True
  --- too for a connection closed here, or whose reading was shut down
  --- here. It reads nothing and waits for nothing, so what the peer
  --- sent before its end is still there to read, and a peer that has
  --- sent more but not ended is not gone. Over TLS it is the
  --- connection's end that is seen: a close_notify with the TCP
  --- connection still open is not.
  function gone(self): boolean
    if not self.open then return true end
    return raw.peer_gone(self.fd)
  end

  --- Waits until the peer has gone, as [`gone`] sees it, at most
  --- `timeout_ns` nanoseconds (no limit when nil): true once it has,
  --- false and a Failure of kind "timeout" once `timeout_ns` passes first,
  --- false and a Failure of kind "cancelled" once the task is cancelled,
  --- or false and a Failure once the connection is closed here, as
  --- [`close`] ends the wait. It reads nothing, so bytes the peer sends
  --- meanwhile neither end the wait nor are lost: they wait for the next
  --- read. In a task the other tasks run meanwhile, a [`read`] or
  --- [`write`] of this connection among them. On Linux the wait is the
  --- kernel's ([`sys.POLLRDHUP`]); where the system has no such event
  --- (macOS) it asks [`gone`] each [`GONE_SLICE_NS`], so the end is seen
  --- within that long.
  function wait_gone(self, timeout_ns?: integer): (true) | (false, Failure)
    Poll.checked_ns(timeout_ns, "net", "timeout_ns", 2)
    local deadline = deadline_of(timeout_ns)
    while true do
      if not self.open then return false, Failure.new("net: the connection is closed") end
      if raw.peer_gone(self.fd) then return true end
      local rest = left(deadline)
      if rest == 0 then return false, Failure.timeout(Poll.TIMEOUT) end
      if sys.POLLRDHUP ~= 0 then
        -- Only the end, a hang-up or an error wakes it: bytes the peer
        -- pipelines behind a request do not.
        local ok, why = Poll.wait(self.fd, sys.POLLRDHUP, rest)
        if not ok then return false, why end
      else
        local slice = if rest ~= nil then math.min(rest, GONE_SLICE_NS) else GONE_SLICE_NS end
        local ok, why = Clock.sleep(slice)
        if not ok then return false, why end
      end
    end
  end

  --- Where this end is: its own numeric TCP address, as the kernel
  --- names it (the accepted end of a dual-stack listener may name an
  --- IPv4 address as an IPv4-mapped IPv6 one). A client's is the
  --- address and port it reaches the peer from. An accepted
  --- connection's is the address the connection came to, one of the
  --- host's own where its listener names the wildcard. Nil and why
  --- where it has none to give: a unix connection, or a connection
  --- already closed.
  -- TODO: answer a unix connection's own address too, once an Address
  -- can say a unix socket bound nowhere, as a client's is: the core
  -- answers one, with a path that is empty.
  function address(self): raw_socket.Address?, string
    if not self.open then return nil, "net: the connection is closed" end
    local address, why = raw.bound(self.fd)
    if address == nil then return nil, why end
    if address.kind ~= "tcp" then return nil, "net: a unix connection has no TCP address" end
    return address, ""
  end

  --- Ends one direction, or both: after "write" the peer reads the
  --- end of what was sent, and this side can still read its answer.
  --- A `how` that is none of "read", "write" and "both" is refused where
  --- it is written; a caller the checker does not read raises.
  function shutdown(self, how: Shutdown): boolean, string
    -- The type refuses a wrong `how` in checked code; this is for a caller
    -- the checker does not read. The test reads `how` as text, which a
    -- wrong value is, so that no narrowing of it is taken as proved.
    local text = tostring(how)
    if text ~= "read" and text ~= "write" and text ~= "both" then
      error("net: how must be \"read\", \"write\" or \"both\"", 2)
    end
    if not self.open then return false, "net: the connection is closed" end
    local session = self.session
    if session ~= nil and how ~= "read" then
      -- The peer reads the end of what was sent from the alert: a TCP
      -- end alone may be an attacker's truncation. Sent if the socket
      -- takes it now; a TLS session is never resumed, so one lost costs
      -- the peer only that certainty.
      local _, _ = session:close_notify()
    end
    local ok, why = raw.shutdown(self.fd, how)
    if not ok then return false, why end
    return true, ""
  end

  --- Closes the connection. Safe to call more than once.
  function close(self): (true) | (false, Failure)
    if not self.open then return true end
    self.open = false
    Poll.closing(self.fd)
    local session = self.session
    if session ~= nil then
      -- As in `shutdown`: sent if the socket takes it at once.
      if self.write_failure == "" then local _, _ = session:close_notify() end
      session:free()
    end
    local ok, why = self.socket:close()
    if not ok then return false, failure_of(why) end
    return true
  end

  --- The same as `close`: nothing sent can be taken back.
  function abort(self): (true) | (false, Failure)
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
    --- waited on until made or refused. One to a listener whose backlog
    --- is full waits for room where the kernel leaves it unanswered
    --- (Linux, macOS 15.8). Where the kernel answers it (macOS 27.2) it
    --- is reset at once instead: connecting fails "Connection reset by
    --- peer", or the connection is made and its first read fails so, a
    --- write "Broken pipe". Connecting to a unix one waits
    --- for nothing: a listener whose backlog is full fails it at once,
    --- "Resource temporarily unavailable (the listener is busy: its
    --- backlog is full)" on Linux and "Connection refused" on macOS,
    --- which cannot tell a busy listener from none. A caller that would
    --- wait for room connects again.
    timeout_ns?: integer
    --- Connects over TLS as this client: once the connection is made,
    --- its handshake is completed before it is answered, within
    --- `timeout_ns` too, as [`Net.Conn`]'s [`start_tls`] does. Nil to connect in
    --- the clear.
    tls?: Tls.Client
    --- The name `tls` asks for (SNI) and verifies the server's
    --- certificate against; nil for the address's host, an IP address,
    --- which is then verified against the certificate's own. A
    --- connection to a unix socket that verifies needs one.
    server_name?: string
  end

  --- Which direction of a connection [`SocketConn.shutdown`] ends.
  type Shutdown = Shutdown

  --- A connection, answered by `accept` and [`Net.connect`]: a
  --- [`Stream.Reader`] of what the peer sends and a [`Stream.Writer`] to
  --- it. A class, so a `<close>` local holds one.
  type Conn = SocketConn

  --- The connection over `socket`, waiting `timeout_ns` on its reads and writes.
  new: function(socket: raw_socket.Socket, timeout_ns: integer?): Conn

  --- The connection over the accepted `socket`, as [`new`]'s, through
  --- a TLS session of `config`, the server's side; nil and why where
  --- the session cannot be set up, the socket closed.
  secured: function(socket: raw_socket.Socket, timeout_ns: integer?, config: raw_tls.Config): Conn?, string

  --- Waits for `fd` to be readable, or writable, at most `timeout_ns`.
  waited: function(fd: integer, writable: boolean, timeout_ns: integer?): boolean, string
end

function Connection.new(socket: raw_socket.Socket, timeout_ns: integer?): SocketConn
  local conn: SocketConn = {
    socket = socket, fd = socket:fd(), open = true, limit = timeout_ns,
    read_failure = "", write_failure = "", skip = nil, session = nil, listener = nil }
  return conn
end

function Connection.secured(socket: raw_socket.Socket, timeout_ns: integer?, config: raw_tls.Config): SocketConn?, string
  local conn = Connection.new(socket, timeout_ns)
  local session, why = tls.session(config, conn.fd)
  if session == nil then
    local _, _ = socket:close()
    return nil, why
  end
  conn.session = session
  return conn, ""
end

function Connection.waited(fd: integer, writable: boolean, timeout_ns: integer?): boolean, string
  return waited(fd, writable, timeout_ns)
end

return Connection
