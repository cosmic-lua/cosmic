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
  --- How an `Address` is read: "unix", a socket file named by `path`.
  enum Kind
    "unix"
  end

  --- Where a socket is.
  record Address
    kind: Kind
    --- For "unix": the socket file's path, of any length a path may
    --- have. The platform bounds the file's own name, past the last "/"
    --- (107 bytes on Linux, 103 on macOS); a longer one fails, "Filename
    --- too long", naming the bound, rather than naming another file.
    path: string
  end

  record ListenOptions
    --- How long `accept` waits, in milliseconds, from 0; nil for no
    --- limit. The connections it accepts start with the same.
    timeout_ms: integer
    --- How many connections may wait to be accepted (64 by default).
    backlog: integer
  end

  record ConnectOptions
    --- How long connecting, and then any one read or write, waits, in
    --- milliseconds, from 0; nil for no limit. A unix listener whose
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

--- `timeout_ms` as the raw calls take it, raising on one no wait can
--- last, so a field set wrong is named where it is read.
local function milliseconds(timeout_ms: integer | nil): integer
  if timeout_ms == nil then return -1 end
  assert(math.type(timeout_ms) == "integer" and timeout_ms >= 0 and timeout_ms <= MOST_MS,
    "timeout_ms must be nil or a whole number of milliseconds from 0 to " .. MOST_MS)
  return timeout_ms
end

--- What a failed call says: its own words for a deadline or a signal,
--- and the bound a name too long ran past.
local function said(trouble: string, errno: integer): string
  if errno == raw.ETIMEDOUT then return "timed out" end
  if errno == raw.EINTR then return "interrupted" end
  if errno == raw.ENAMETOOLONG then
    return trouble .. " (a socket file's own name may be at most " ..
      raw.SOCKET_NAME_MAX .. " bytes here)"
  end
  return trouble
end

local function waited(fd: integer, writable: boolean, timeout_ms: integer | nil): boolean, string
  local ok, trouble, errno = raw.wait(fd, writable, milliseconds(timeout_ms))
  if ok then return true, "" end
  return false, said(trouble, errno)
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

--- The listener over `fd`, which it owns from here on, at `address`.
--- `made` is the socket file it made there, at `absolute` -- its path
--- whatever directory the process moves to -- which `close` removes
--- only while the name is still that file.
local function new_listener(fd: integer, address: Net.Address, absolute: string,
    made: sys.Stat, timeout_ms: integer | nil): Net.Listener
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
      local now, _ = sys.lstat(absolute)
      if now ~= nil and now.ino == made.ino and now.dev == made.dev then
        local removed, trouble = sys.unlink(absolute)
        if not removed and ok then return false, address.path .. ": " .. trouble end
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
function Net.listen(address: Net.Address, opts?: Net.ListenOptions): Net.Listener | nil, string
  opts = opts or {}
  local backlog = opts.backlog or DEFAULT_BACKLOG
  assert(backlog >= 1, "backlog must be at least 1")
  milliseconds(opts.timeout_ms)
  local absolute = address.path
  if absolute:sub(1, 1) ~= "/" then
    local cwd, cwd_trouble = sys.getcwd()
    if cwd == nil then return nil, named(address) .. ": " .. cwd_trouble end
    absolute = cwd .. "/" .. absolute
  end
  local fd, trouble, errno = raw.listen(raw_address(address), backlog)
  if fd == nil then return nil, named(address) .. ": " .. said(trouble, errno) end
  -- The socket file the bind made, to remove at close. A process that
  -- replaces the name in the moment since would have its file taken
  -- for this one's, and removed at close.
  -- TODO: bind at a short temporary name beside the path, lstat that,
  -- and link it to the path (EEXIST where the name is taken, never
  -- replacing it) before removing the temporary name, so the file
  -- recorded is the one bound.
  local made, why = sys.lstat(absolute)
  if made == nil or made.kind ~= "other" then
    local _, _ = sys.close(fd)
    return nil, named(address) .. ": " ..
      (made == nil and why or "the socket file made was replaced")
  end
  return new_listener(fd, { kind = address.kind, path = address.path }, absolute, made,
    opts.timeout_ms), ""
end

--- Connects to `address`. A unix one fails "No such file or directory"
--- where there is no socket file and "Connection refused" where nothing
--- listens at it, and waits for room at a listener whose backlog is
--- full (on Linux; see `ConnectOptions.timeout_ms`).
function Net.connect(address: Net.Address, opts?: Net.ConnectOptions): Net.Conn | nil, string
  local timeout_ms = opts ~= nil and opts.timeout_ms or nil
  local fd, trouble, errno = raw.connect(raw_address(address), milliseconds(timeout_ms))
  if fd == nil then return nil, named(address) .. ": " .. said(trouble, errno) end
  return new_conn(fd, timeout_ms), ""
end

return Net
