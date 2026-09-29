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
--- path, is the one there is so far. A connection is one object for
--- both directions; `shutdown("write")` tells the peer the end of what
--- was sent while its answer is still read.
---
--- Every wait -- to accept, to read, to write -- lasts at most the
--- object's `timeout_ms` (no limit by default), failing with "timed
--- out", and ends at once with "interrupted" when an open `Child.guard`
--- catches SIGINT or SIGTERM, as `cosmic.http`'s do. One connection is
--- served at a time: nothing here waits on several at once.

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
  --- How an `Address` is read: "unix", a socket file named by `path`.
  enum Kind
    "unix"
  end

  --- Where a socket is.
  record Address
    kind: Kind
    --- For "unix": the socket file's path. The platform bounds it (107
    --- bytes on Linux, 103 on macOS); a longer one fails, "File name
    --- too long", rather than naming another file.
    path: string
  end

  record Options
    --- How long any one wait may last, in milliseconds; nil for no
    --- limit. A listener's connections start with its own.
    timeout_ms: integer
    --- `listen` only: how many connections may wait to be accepted
    --- (64 by default).
    backlog: integer
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
    --- How long a `read` or a `write` waits; nil for no limit.
    timeout_ms: integer
    --- What has arrived, at most `max` bytes (64 KiB by default), once
    --- something has; nil and "" once the peer has ended what it sends;
    --- nil and "timed out", "interrupted" or why not, every read after.
    read: function(Conn, max?: integer): string | nil, string
    --- Sends all of `data`, waiting as the peer takes it; false and
    --- "timed out", "interrupted" or why not, every write after.
    write: function(Conn, data: string): boolean, string
    --- Ends one direction, or both: after "write" the peer reads the
    --- end of what was sent, and this side can still read its answer.
    shutdown: function(Conn, how: string): boolean, string
    --- Closes the connection. Safe to call more than once.
    close: function(Conn): boolean, string
    --- The same as `close`: nothing sent can be taken back.
    abort: function(Conn): boolean, string
    metamethod __close: function(Conn)
  end
end

local DEFAULT_READ <const> = 64 * 1024
local DEFAULT_BACKLOG <const> = 64

--- The address of the socket file at `path`.
function Net.unix(path: string): Net.Address
  return { kind = "unix", path = path }
end

--- What a failed wait says: its own words for a deadline or a signal.
local function waited(fd: integer, writable: boolean, timeout_ms: integer | nil): boolean, string
  local ok, trouble, errno = raw.wait(fd, writable, timeout_ms or -1)
  if ok then return true, "" end
  if errno == raw.ETIMEDOUT then return false, "timed out" end
  if errno == raw.EINTR then return false, "interrupted" end
  return false, trouble
end

local conn_mt: metatable<Net.Conn> = {
  __close = function(self: Net.Conn)
    local _, _ = self:close()
  end,
  __gc = function(self: Net.Conn)
    local _, _ = self:close()
  end,
}

--- The connection over `fd`, which it owns from here on.
local function new_conn(fd: integer, timeout_ms: integer | nil): Net.Conn
  local open = true
  -- Sticky: once a read or a write fails, every later one says so.
  local failure = ""
  local function usable(): boolean, string
    if not open then return false, "connection is closed" end
    if failure ~= "" then return false, failure end
    return true, ""
  end
  local conn: Net.Conn
  conn = {
    timeout_ms = timeout_ms,
    read = function(_self: Net.Conn, max?: integer): string | nil, string
      assert(max == nil or max > 0, "max must be positive")
      local ok, trouble = usable()
      if not ok then return nil, trouble end
      while true do
        local data, why, errno = sys.read(fd, max or DEFAULT_READ)
        if data == "" then return nil, "" end
        if data ~= nil then return data, "" end
        if errno ~= raw.EAGAIN then
          failure = why
          return nil, why
        end
        local ready, waiting = waited(fd, false, conn.timeout_ms)
        if not ready then
          failure = waiting
          return nil, waiting
        end
      end
    end,
    write = function(_self: Net.Conn, data: string): boolean, string
      local ok, trouble = usable()
      if not ok then return false, trouble end
      local from = 1
      while from <= #data do
        local sent, why, errno = raw.send(fd, from == 1 and data or data:sub(from))
        if sent ~= nil then
          from = from + sent
        elseif errno ~= raw.EAGAIN then
          failure = why
          return false, why
        else
          local ready, waiting = waited(fd, true, conn.timeout_ms)
          if not ready then
            failure = waiting
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
    close = function(_self: Net.Conn): boolean, string
      if not open then return true, "" end
      open = false
      local ok, why = sys.close(fd)
      if not ok then return false, why end
      return true, ""
    end,
    abort = function(self: Net.Conn): boolean, string
      return self:close()
    end,
  }
  return setmetatable(conn, conn_mt)
end

local listener_mt: metatable<Net.Listener> = {
  __close = function(self: Net.Listener)
    local _, _ = self:close()
  end,
  __gc = function(self: Net.Listener)
    local _, _ = self:close()
  end,
}

--- The listener over `fd`, which it owns from here on, at `address`;
--- `made` is the socket file it made there, as `lstat` saw it once
--- made, which `close` removes only while the name is still that file.
local function new_listener(fd: integer, address: Net.Address, made: sys.Stat | nil,
    timeout_ms: integer | nil): Net.Listener
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
      local ok, why = sys.close(fd)
      if made ~= nil then
        local now, _ = sys.lstat(address.path)
        if now ~= nil and now.ino == made.ino and now.dev == made.dev then
          local removed, trouble = sys.unlink(address.path)
          if not removed and ok then return false, address.path .. ": " .. trouble end
        end
      end
      if not ok then return false, why end
      return true, ""
    end,
  }
  return setmetatable(listener, listener_mt)
end

--- What `address` is called in a failure.
local function named(address: Net.Address): string
  return address.path
end

--- `address` as the raw table reads one.
local function raw_address(address: Net.Address): raw_socket.Address
  return { kind = address.kind, path = address.path }
end

--- Listens at `address`. A unix one makes its socket file, and fails
--- where the path is already there -- a socket file left behind by a
--- listener that did not close included -- rather than take the name
--- from whatever holds it.
function Net.listen(address: Net.Address, opts?: Net.Options): Net.Listener | nil, string
  opts = opts or {}
  local backlog = opts.backlog or DEFAULT_BACKLOG
  assert(backlog >= 1, "backlog must be at least 1")
  local fd, trouble = raw.listen(raw_address(address), backlog)
  if fd == nil then return nil, named(address) .. ": " .. trouble end
  -- A name another process takes between the bind and this is not the
  -- file made, and `close` leaves it be.
  local made, _ = sys.lstat(address.path)
  return new_listener(fd, { kind = address.kind, path = address.path }, made, opts.timeout_ms), ""
end

--- Connects to `address`. A unix one connects at once or fails: "No
--- such file or directory" where there is no socket file, "Connection
--- refused" where nothing listens at it.
function Net.connect(address: Net.Address, opts?: Net.Options): Net.Conn | nil, string
  local fd, trouble = raw.connect(raw_address(address))
  if fd == nil then return nil, named(address) .. ": " .. trouble end
  return new_conn(fd, opts ~= nil and opts.timeout_ms or nil), ""
end

return Net
