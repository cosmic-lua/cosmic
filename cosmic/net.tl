--- Stream sockets: listen at an address, accept a connection there, or
--- connect to one, and read and write it as a `cosmic.stream` Reader
--- and Writer.
---
---     local server <close> = assert(Net.listen(Net.unix(dir .. "/app.sock")))
---     local conn <close> = assert(server:accept())
---     local line = Stream.lines(conn):read()
---
--- An address is a record whose `kind` says how the rest of it is read,
--- so every call takes every kind: "unix", a socket file named by a
--- path, or "tcp", a port of a host's numeric address.
---
---     local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
---     local port = server.address.port -- the one the kernel chose
---
--- A connection is one object for
--- both directions; `shutdown("write")` tells the peer the end of what
--- was sent while its answer is still read, and `writer()` is a Writer
--- whose `close` does just that, for a wrapper that closes what it
--- wraps.
---
--- Every wait -- to connect, to accept, to read, to write -- lasts at
--- most the object's `timeout_ms` (no limit by default), failing with
--- "timed out", and ends with "interrupted", within a tenth of a second,
--- when an open `Child.guard` catches SIGINT or SIGTERM, as
--- `cosmic.http`'s do. One connection is served at a time: nothing here
--- waits on several at once.

local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")

--- The raw module behind this one lives under the reserved
--- `cosmic.internal.` namespace and arrives as the second argument
--- `require` passes this chunk's loader, as cosmic/http.tl's does.
local type raw_socket = require("cosmic.internal.socket")

local extra: any = select(2, ...)
local raw: raw_socket
if type(extra) == "table" then
  raw = extra as raw_socket
else
  raw = require("cosmic.internal.socket")
end

local record Net
  --- How an `Address` is read: "unix", a socket file named by `path`,
  --- or "tcp", a `port` of a `host`.
  enum Kind
    "unix"
    "tcp"
  end

  --- Where a socket is.
  record Address
    kind: Kind
    --- For "unix": the socket file's path, of any length a path may
    --- have. The platform bounds the file's own name, past the last "/"
    --- (107 bytes on Linux, 103 on macOS); a longer one fails, "Filename
    --- too long", naming the bound, rather than naming another file.
    path: string
    --- For "tcp": the host's numeric IPv4 or IPv6 address ("127.0.0.1",
    --- "::1"). A name is not looked up, nor an IPv6 scope ("%lo") read:
    --- either fails "Invalid argument".
    host: string
    --- For "tcp": the port, from 0 to 65535. A listener at 0 is at a
    --- port the kernel chose, which its `address` names.
    port: integer
  end

  record ListenOptions
    --- For "unix": take over a socket file a listener left behind -- one
    --- that exited without `close`, killed or crashed -- rather than
    --- fail "Address in use" there, as a daemon restarting at its
    --- control socket does. The path is taken over only where it is a
    --- socket file and connecting to it is refused: a live listener's
    --- file, or any other file, is left alone, and a live listener sees
    --- the connection that asked, which sends nothing. Refused is not
    --- always gone: macOS refuses a live listener whose backlog is full
    --- as it refuses a dead one, and every platform refuses a socket
    --- bound but not yet listening -- another `listen` in its moment
    --- between the two, as when two start at once -- so theirs is taken
    --- over too; and one that binds there between the check and the
    --- removal loses its file.
    reclaim: boolean
    --- How long `accept` waits, in milliseconds, from 0; nil for no
    --- limit. The connections it accepts start with the same.
    timeout_ms: integer
    --- How many connections may wait to be accepted (64 by default).
    backlog: integer
  end

  record ConnectOptions
    --- How long connecting, and then any one read or write, waits, in
    --- milliseconds, from 0; nil for no limit. A TCP connection is
    --- waited on until made or refused. A unix listener whose
    --- backlog is full is waited on for room on Linux; macOS refuses the
    --- connection at once, "Connection refused", as though nothing
    --- listened.
    timeout_ms: integer
  end

  --- A socket listening at an address, answered by `Net.listen`.
  record Listener
    --- Where it listens.
    address: Address
    --- How long `accept` waits by default; nil for no limit.
    timeout_ms: integer
    --- The next connection, waiting for one as long as `timeout_ms`
    --- (this call's, or the listener's); nil and "timed out",
    --- "interrupted", or why not.
    accept: function(Listener, timeout_ms?: integer): Conn | nil, string
    --- Stops listening. A unix listener removes its socket file too,
    --- unless another file has taken the name since. Safe to call more
    --- than once.
    close: function(Listener): boolean, string
    metamethod __close: function(Listener)
  end

  --- A connection, answered by `accept` and `Net.connect`: a
  --- `Stream.Reader` of what the peer sends and a `Stream.Writer` to
  --- it.
  record Conn is Stream.Reader, Stream.Writer
    --- How long a `read` or a `write` waits, from 0; nil for no limit.
    timeout_ms: integer
    --- What has arrived, at most `max` bytes (64 KiB by default), once
    --- something has; nil and "" once the peer has ended what it sends.
    --- nil and "timed out" or "interrupted" takes nothing, and a later
    --- read may still answer; nil and any other failure is every read's
    --- after. A failed read leaves writing be.
    read: function(Conn, max?: integer): string | nil, string
    --- Sends all of `data`, waiting as the peer takes it. False and
    --- "timed out", "interrupted" or why not may leave part of it sent,
    --- so it is every write's after; reading is left be.
    write: function(Conn, data: string): boolean, string
    --- Ends one direction, or both: after "write" the peer reads the
    --- end of what was sent, and this side can still read its answer.
    shutdown: function(Conn, how: string): boolean, string
    --- A Writer to the peer whose `close` is `shutdown("write")`,
    --- leaving the answer to read here -- for a wrapper that closes
    --- the Writer it wraps (`Stream.transform_writer`, `Stream.tee`)
    --- -- and whose `abort` closes the connection.
    writer: function(Conn): Stream.Writer
    --- Closes the connection. Safe to call more than once.
    close: function(Conn): boolean, string
    --- The same as `close`: nothing sent can be taken back.
    abort: function(Conn): boolean, string
    metamethod __close: function(Conn)
  end
end

local DEFAULT_READ <const> = 64 * 1024
local DEFAULT_BACKLOG <const> = 64
local MOST_MS <const> = 0x7fffffff

--- The address of the socket file at `path`.
function Net.unix(path: string): Net.Address
  return { kind = "unix", path = path }
end

--- The address of TCP `port` at `host`, a numeric IPv4 or IPv6 address.
function Net.tcp(host: string, port: integer): Net.Address
  return { kind = "tcp", host = host, port = port }
end

--- `timeout_ms` as the raw calls take it, raising on one no wait can
--- last, so a field set wrong is named where it is read.
local function milliseconds(timeout_ms: integer | nil): integer
  if timeout_ms == nil then return -1 end
  assert(math.type(timeout_ms) == "integer" and timeout_ms >= 0 and timeout_ms <= MOST_MS,
    "timeout_ms must be nil or a whole number of milliseconds from 0 to " .. MOST_MS)
  return timeout_ms
end

--- What a failed call says: its own words for a deadline or a signal,
--- the bound a name too long ran past, and what a host must be.
local function said(trouble: string, errno: integer, address?: Net.Address): string
  if errno == raw.ETIMEDOUT then return "timed out" end
  if errno == raw.EINTR then return "interrupted" end
  if errno == raw.ENAMETOOLONG then
    return trouble .. " (a socket file's own name may be at most " ..
      raw.SOCKET_NAME_MAX .. " bytes here)"
  end
  if errno == raw.EINVAL and address ~= nil and address.kind == "tcp" then
    return trouble .. " (not a numeric IPv4 or IPv6 address: a name is not looked up, " ..
      "nor an IPv6 scope read)"
  end
  return trouble
end

local function waited(fd: integer, writable: boolean, timeout_ms: integer | nil): boolean, string
  local ok, trouble, errno = raw.wait(fd, writable, milliseconds(timeout_ms))
  if ok then return true, "" end
  return false, said(trouble, errno)
end

-- A connection or a listener dropped unclosed needs no __gc: its
-- socket, which only its closures hold, is closed by the collector.
local conn_mt: metatable<Net.Conn> = {
  __close = function(self: Net.Conn)
    local _, _ = self:close()
  end,
}

--- The connection over `socket`.
local function new_conn(socket: raw_socket.Socket, timeout_ms: integer | nil): Net.Conn
  local fd = socket:fd()
  local open = true
  -- Each direction's sticky failure: once a read or a write fails for
  -- good, every later one of it says so.
  local read_failure, write_failure = "", ""
  local conn: Net.Conn
  conn = {
    timeout_ms = timeout_ms,
    read = function(_self: Net.Conn, max?: integer): string | nil, string
      assert(max == nil or max > 0, "max must be positive")
      if not open then return nil, "connection is closed" end
      if read_failure ~= "" then return nil, read_failure end
      while true do
        local data, why, errno = sys.read(fd, max or DEFAULT_READ)
        if data == "" then return nil, "" end
        if data ~= nil then return data, "" end
        if errno ~= raw.EAGAIN then
          read_failure = why
          return nil, why
        end
        -- Nothing was taken: a deadline or a signal leaves the next
        -- read to try again.
        local ready, waiting = waited(fd, false, conn.timeout_ms)
        if not ready then return nil, waiting end
      end
    end,
    write = function(_self: Net.Conn, data: string): boolean, string
      if not open then return false, "connection is closed" end
      if write_failure ~= "" then return false, write_failure end
      local from = 1
      while from <= #data do
        local sent, why, errno = raw.send(fd, from == 1 and data or data:sub(from))
        if sent ~= nil then
          from = from + sent
        elseif errno ~= raw.EAGAIN then
          write_failure = why
          return false, why
        else
          local ready, waiting = waited(fd, true, conn.timeout_ms)
          if not ready then
            write_failure = waiting
            return false, waiting
          end
        end
      end
      return true, ""
    end,
    shutdown = function(_self: Net.Conn, how: string): boolean, string
      assert(how == "read" or how == "write" or how == "both",
        "how must be \"read\", \"write\" or \"both\"")
      if not open then return false, "connection is closed" end
      local ok, why = raw.shutdown(fd, how)
      if not ok then return false, why end
      return true, ""
    end,
    writer = function(self: Net.Conn): Stream.Writer
      -- Once ended, a second close asks nothing of the socket, which
      -- macOS answers ENOTCONN once the peer has gone.
      local ended = false
      return {
        write = function(_w: Stream.Writer, data: string): boolean, string
          if ended then return false, "writer is closed" end
          return self:write(data)
        end,
        close = function(_w: Stream.Writer): boolean, string
          if ended or not open then return true, "" end
          ended = true
          return self:shutdown("write")
        end,
        abort = function(_w: Stream.Writer): boolean, string
          return self:close()
        end,
      }
    end,
    close = function(_self: Net.Conn): boolean, string
      if not open then return true, "" end
      open = false
      local ok, why = socket:close()
      if not ok then return false, why end
      return true, ""
    end,
    abort = function(self: Net.Conn): boolean, string
      return self:close()
    end,
  }
  return setmetatable(conn, conn_mt)
end

--- What `address` is called in a failure: its path, or its host and
--- port, an IPv6 host in brackets.
local function named(address: Net.Address): string
  if address.kind ~= "tcp" then return address.path end
  local host = address.host
  if host:find(":", 1, true) then host = "[" .. host .. "]" end
  return host .. ":" .. tostring(address.port)
end

local listener_mt: metatable<Net.Listener> = {
  __close = function(self: Net.Listener)
    local _, _ = self:close()
  end,
}

--- The listener over `socket`, at `address`.
local function new_listener(socket: raw_socket.Socket, address: Net.Address,
    timeout_ms: integer | nil): Net.Listener
  local fd = socket:fd()
  local open = true
  local listener: Net.Listener
  listener = {
    address = address,
    timeout_ms = timeout_ms,
    accept = function(_self: Net.Listener, wait_ms?: integer): Net.Conn | nil, string
      if not open then return nil, "listener is closed" end
      wait_ms = wait_ms or listener.timeout_ms
      while true do
        local connection, why, errno = raw.accept(fd)
        if connection ~= nil then return new_conn(connection, listener.timeout_ms), "" end
        if errno ~= raw.EAGAIN then return nil, why end
        local ready, waiting = waited(fd, false, wait_ms)
        if not ready then return nil, waiting end
      end
    end,
    close = function(_self: Net.Listener): boolean, string
      if not open then return true, "" end
      open = false
      local ok, why = socket:close()
      if not ok then return false, named(address) .. ": " .. why end
      return true, ""
    end,
  }
  return setmetatable(listener, listener_mt)
end

--- `address` as the raw table reads one.
local function raw_address(address: Net.Address): raw_socket.Address
  return { kind = address.kind, path = address.path, host = address.host, port = address.port }
end

--- How long `left_behind` waits to connect: a live listener on Linux
--- whose backlog is full keeps a connection waiting for room, which
--- then times out rather than being refused.
local PROBE_MS <const> = 1000

--- The type bits of a socket file (S_IFSOCK) in `Stat.mode`, the same
--- on Linux and macOS.
local SOCKET_TYPE <const> = 0xC000

--- What `reclaim` finds at `address`'s path, which a bind found taken,
--- read from the working directory the bind was: "refused", a socket
--- file connecting to which is refused, to take over; "gone", nothing
--- there any longer, to bind again; or "", anything else, to leave
--- alone.
-- TODO: take a lock beside the path (a file of its own, held while
-- the check, the removal and the bind run) so two `reclaim`s starting
-- at once cannot each take the other's socket for one left behind,
-- once cosmic.sys carries flock.
local function left_behind(address: Net.Address): string
  local st, _, lstat_errno = sys.lstat(address.path)
  if st == nil then return lstat_errno == sys.ENOENT and "gone" or "" end
  if st.mode & 0xF000 ~= SOCKET_TYPE then return "" end
  local probe, _, errno = raw.connect(raw_address(address), PROBE_MS)
  if probe ~= nil then
    local _, _ = probe:close()
    return ""
  end
  if errno == raw.ECONNREFUSED then return "refused" end
  return errno == sys.ENOENT and "gone" or ""
end

--- Listens at `address`. A unix one makes its socket file, and fails
--- where the path is already there -- a socket file left behind by a
--- listener that did not close included -- rather than take the name
--- from whatever holds it, unless `reclaim` takes a socket file left
--- behind by a listener that is gone. A TCP one fails "Address in use" at a port
--- another listens at; its `address` names the port it has.
function Net.listen(address: Net.Address, opts?: Net.ListenOptions): Net.Listener | nil, string
  opts = opts or {}
  local backlog = opts.backlog or DEFAULT_BACKLOG
  assert(backlog >= 1, "backlog must be at least 1")
  milliseconds(opts.timeout_ms)
  if address.kind == "tcp" then
    local socket, trouble, errno = raw.listen(raw_address(address), backlog)
    if socket == nil then return nil, named(address) .. ": " .. said(trouble, errno, address) end
    local bound, why = raw.bound(socket:fd())
    if bound == nil then
      local _, _ = socket:close()
      return nil, named(address) .. ": " .. why
    end
    return new_listener(socket, Net.tcp(bound.host, bound.port), opts.timeout_ms), ""
  end
  local socket, trouble, errno = raw.listen(raw_address(address), backlog)
  if socket == nil and errno == raw.EADDRINUSE and opts.reclaim then
    local found = left_behind(address)
    if found == "refused" then
      local removed, why, number = sys.unlink(address.path)
      if not removed and number ~= sys.ENOENT then
        return nil, named(address) .. ": " .. why
      end
    end
    if found ~= "" then socket, trouble, errno = raw.listen(raw_address(address), backlog) end
  end
  if socket == nil then return nil, named(address) .. ": " .. said(trouble, errno) end
  return new_listener(socket, { kind = address.kind, path = address.path }, opts.timeout_ms), ""
end

--- Connects to `address`. A unix one fails "No such file or directory"
--- where there is no socket file and "Connection refused" where nothing
--- listens at it, and waits for room at a listener whose backlog is
--- full (on Linux; see `ConnectOptions.timeout_ms`). A TCP one waits
--- for the connection to be made, and fails "Connection refused" where
--- nothing listens at the port.
function Net.connect(address: Net.Address, opts?: Net.ConnectOptions): Net.Conn | nil, string
  local timeout_ms = opts ~= nil and opts.timeout_ms or nil
  local socket, trouble, errno = raw.connect(raw_address(address), milliseconds(timeout_ms))
  if socket == nil then return nil, named(address) .. ": " .. said(trouble, errno, address) end
  return new_conn(socket, timeout_ms), ""
end

return Net
