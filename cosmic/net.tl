--- Stream sockets: listen at an address, accept a connection there, or
--- connect to one, and read and write it as a [`cosmic.stream`] Reader
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
--- was sent while its answer is still read, and [`writer()`] is a Writer
--- whose `close` does just that, for a wrapper that closes what it
--- wraps.
---
--- Every wait -- to connect, to accept, to read, to write -- lasts at
--- most the object's `timeout_ms` (no limit by default), failing with
--- "timed out", and ends with "interrupted", within a tenth of a second,
--- when an open [`Child.guard`] catches SIGINT or SIGTERM, as
--- [`cosmic.http`]'s do.
---
--- In a task of [`Poll.run`] ([`cosmic.poll`]), a wait to connect, to
--- accept, to read or to write waits through the run, so its other
--- tasks go on meanwhile: a server serves each connection in a task of
--- its own. A cancelled task's wait there fails "cancelled", and a
--- signal does not end one. Anywhere else a wait holds the thread until
--- it ends.

local Poll = require("cosmic.poll")
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
  --- How an [`Address`] is read: "unix", a socket file named by `path`,
  --- or "tcp", a `port` of a `host`.
  enum Kind
    "unix"
    "tcp"
  end

  --- Where a socket is.
  record Address
    --- Whether the address is a socket file or a host and port.
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
    --- the connection that asked, which sends nothing. Listens that
    --- reclaim take turns: each holds a lock on the file
    --- `path .. ".lock"` from its first bind to its last, so of two
    --- starting at once the second finds the first listening. A listen
    --- without `reclaim` takes no turn, and refused is not always gone:
    --- macOS refuses a live listener whose backlog is full as it refuses
    --- a dead one, and every platform refuses a socket bound but not yet
    --- listening -- a listen without `reclaim` in its moment between the
    --- two -- so theirs is taken over too; and one that binds there
    --- between the check and the removal loses its file. The lock file
    --- stays after the listener closes. Where it cannot be opened or
    --- locked, the listen fails, naming the lock file, rather than
    --- reclaim without it: "Permission denied" for one another user
    --- made (it is made mode 0600, and Linux's fs.protected_regular
    --- refuses another's in a sticky directory such as /tmp) or in a
    --- directory not writable here; "File name too long" for a path
    --- within 5 bytes of the longest a path may be; "timed out" for
    --- another's lock held 10 seconds; "interrupted" for a signal a
    --- [`Child.guard`] caught; and a directory or a link at its name
    --- fails too. A path ending in "/" fails "Is a directory", and an
    --- empty path raises, as it does without `reclaim`.
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

  --- A socket listening at an address, answered by [`Net.listen`].
  record Listener
    --- Where it listens.
    address: Address
    --- How long `accept` waits by default; nil for no limit.
    timeout_ms: integer
    --- The next connection, waiting for one as long as `timeout_ms`
    --- (this call's, or the listener's); nil and "timed out",
    --- "interrupted", "cancelled" (in a task of [`Poll.run`]), or why not.
    accept: function(Listener, timeout_ms?: integer): Conn | nil, string
    --- Stops listening. A unix listener removes its socket file too,
    --- unless another file has taken the name since. Safe to call more
    --- than once.
    close: function(Listener): boolean, string
    metamethod __close: function(Listener)
  end

  --- A connection, answered by `accept` and [`Net.connect`]: a
  --- [`Stream.Reader`] of what the peer sends and a [`Stream.Writer`] to
  --- it.
  record Conn is Stream.Reader, Stream.Writer
    --- How long a `read` or a `write` waits, from 0; nil for no limit.
    timeout_ms: integer
    --- What has arrived, at most `max` bytes (64 KiB by default), once
    --- something has; nil and "" once the peer has ended what it sends.
    --- nil and "timed out", "interrupted" or "cancelled" (in a task of
    --- [`Poll.run`]) takes nothing, and a later read may still answer; nil
    --- and any other failure is every read's after. A failed read leaves
    --- writing be.
    read: function(Conn, max?: integer): string | nil, string
    --- Sends all of `data`, waiting as the peer takes it. False and
    --- "timed out", "interrupted", "cancelled" (in a task of [`Poll.run`])
    --- or why not may leave part of it sent,
    --- so it is every write's after; reading is left be.
    write: function(Conn, data: string): boolean, string
    --- Ends one direction, or both: after "write" the peer reads the
    --- end of what was sent, and this side can still read its answer.
    shutdown: function(Conn, how: string): boolean, string
    --- A Writer to the peer whose `close` is `shutdown("write")`,
    --- leaving the answer to read here -- for a wrapper that closes
    --- the Writer it wraps ([`Stream.transform_writer`], [`Stream.tee`])
    --- -- and whose `abort` closes the connection.
    writer: function(Conn): Stream.Writer
    --- Closes the connection. Safe to call more than once.
    close: function(Conn): boolean, string
    --- The same as `close`: nothing sent can be taken back.
    abort: function(Conn): boolean, string
    --- Where the other end is: a TCP peer's host and port, or a unix
    --- peer's path as its socket was bound, "" for one bound nowhere. A
    --- connection to a unix listener names the listener's path (its
    --- file's own name alone, for a path too long to bind whole); one a
    --- listener accepts from [`Net.connect`], and either end of
    --- [`Net.pair`], names "". nil and "connection is closed", or why
    --- not: a TCP connection its peer has reset may no longer say.
    peer: function(Conn): Address | nil, string
    metamethod __close: function(Conn)
  end

  --- Two connections, each the other's peer, answered by [`Net.pair`].
  record Pair
    --- One end, whose peer is `second`.
    first: Conn
    --- The other end, whose peer is `first`.
    second: Conn
    --- Closes both.
    metamethod __close: function(Pair)
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
  local ms = milliseconds(timeout_ms)
  if Poll.in_task() then
    local ready, why: boolean, string
    if writable then
      ready, why = Poll.writable(fd, timeout_ms)
    else
      ready, why = Poll.readable(fd, timeout_ms)
    end
    if ready then return true, "" end
    -- Poll.TIMEOUT is this module's own "timed out", which
    -- test_in_a_run_waits_time_out_as_they_do_out_of_one holds it to.
    return false, why
  end
  local ok, trouble, errno = raw.wait(fd, writable, ms)
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
        -- Another task may have closed the connection while this one
        -- waited in a run, and its descriptor gone to another socket.
        if not open then return nil, "connection is closed" end
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
          if not open then return false, "connection is closed" end
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
      Poll.closing(fd)
      local ok, why = socket:close()
      if not ok then return false, why end
      return true, ""
    end,
    abort = function(self: Net.Conn): boolean, string
      return self:close()
    end,
    peer = function(_self: Net.Conn): Net.Address | nil, string
      if not open then return nil, "connection is closed" end
      local address, why = raw.peer(fd)
      if address == nil then return nil, why end
      if address.kind == "tcp" then return Net.tcp(address.host, address.port), "" end
      return Net.unix(address.path), ""
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
        if not open then return nil, "listener is closed" end
      end
    end,
    close = function(_self: Net.Listener): boolean, string
      if not open then return true, "" end
      open = false
      Poll.closing(fd)
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

--- The clock a connection in a task waits out its timeout on.
local function now_ms(): integer
  local reading, trouble = sys.clock_gettime(sys.CLOCK_MONOTONIC)
  if reading == nil then error("clock_gettime(CLOCK_MONOTONIC): " .. trouble) end
  return reading // 1000000
end

--- The longest a connection in a task sleeps before it asks a unix
--- listener whose backlog was full again, as core/socket.c's `connect`
--- does out of one.
local ROOM_PAUSE_MS <const> = 100

--- What [`connection`] made: the socket, or, where there is none, what
--- went wrong and its errno, which [`left_behind`] tells apart. `errno`
--- is 0 for a wait's own "timed out" or "cancelled" in a task.
local record Attempt
  socket: raw_socket.Socket
  trouble: string
  errno: integer
end

--- A socket being connected in a task, closed when the task leaves it
--- unclaimed -- a run torn down while it waits included -- rather than
--- left to the collector.
local record Connecting
  socket: raw_socket.Socket
  metamethod __close: function(Connecting)
end

local connecting_mt: metatable<Connecting> = {
  __close = function(self: Connecting)
    if self.socket ~= nil then local _, _ = self.socket:close() end
  end,
}

--- A socket connected to `address`, waiting at most `timeout_ms`: in a
--- task of [`Poll.run`], through the run; anywhere else, holding the
--- thread.
local function connection(address: Net.Address, timeout_ms: integer | nil): Attempt
  local ms = milliseconds(timeout_ms)
  if not Poll.in_task() then
    local socket, trouble, errno = raw.connect(raw_address(address), ms)
    return { socket = socket, trouble = trouble, errno = errno }
  end
  local deadline = timeout_ms ~= nil and now_ms() + timeout_ms or nil
  local pause = 1
  while true do
    local socket, trouble, errno = raw.start(raw_address(address))
    local left: integer = nil
    if deadline ~= nil then left = math.max(deadline - now_ms(), 0) end
    if socket ~= nil then
      local holder: Connecting = { socket = socket }
      local held <close> = setmetatable(holder, connecting_mt)
      local ready, why = Poll.writable(socket:fd(), left)
      if not ready then return { trouble = why, errno = 0 } end
      local made, refused, number = raw.connected(socket:fd())
      if not made then return { trouble = refused, errno = number } end
      held.socket = nil
      return { socket = socket }
    end
    if errno ~= raw.EAGAIN then return { trouble = trouble, errno = errno } end
    -- A unix listener's backlog is full, and writable says nothing of
    -- room there: ask again after a pause, as the wait out of a run does.
    if left == 0 then return { trouble = Poll.TIMEOUT, errno = 0 } end
    local paused, why = Poll.delay(left ~= nil and math.min(pause, left) or pause)
    if not paused then return { trouble = why, errno = 0 } end
    pause = math.min(pause * 2, ROOM_PAUSE_MS)
  end
end

--- How long [`left_behind`] waits to connect: a live listener on Linux
--- whose backlog is full keeps a connection waiting for room, which
--- then times out rather than being refused.
local PROBE_MS <const> = 1000

--- The type bits of a socket file (S_IFSOCK) in [`Stat.mode`], the same
--- on Linux and macOS.
local SOCKET_TYPE <const> = 0xC000

--- How long `reclaim` waits for another's lock, which each holds for
--- a probe and two binds: far past that, the holder is stuck.
local LOCK_MS <const> = 10 * PROBE_MS

--- The lock `reclaim` holds, released when it goes out of scope,
--- whether the listen returns or raises.
local record ReclaimLock
  fd: integer
  metamethod __close: function(ReclaimLock)
end

local reclaim_lock_mt: metatable<ReclaimLock> = {
  __close = function(self: ReclaimLock)
    local _, _ = sys.close(self.fd)
  end,
}

--- The lock `reclaim` takes beside `address`'s path; nil and why not,
--- the lock file named. The lock file is never removed: a reclaim
--- waiting on one removed would then lock a file no longer at the name,
--- while the next reclaim makes and locks another.
local function reclaim_lock(address: Net.Address): ReclaimLock, string
  local name = address.path .. ".lock"
  -- Open for writing, which an exclusive lock over NFS or SMB needs;
  -- O_NONBLOCK so a FIFO at the name opens without waiting for a
  -- writer, O_NOCTTY so a terminal there does not become this
  -- process's.
  local fd, why = sys.open(name,
    sys.O_RDWR | sys.O_CREAT | sys.O_NOFOLLOW | sys.O_NONBLOCK | sys.O_NOCTTY, 0x180)
  if fd == nil then return nil, name .. ": " .. why end
  local ok, trouble, errno = sys.flock(fd, "exclusive", LOCK_MS)
  if not ok then
    local _, _ = sys.close(fd)
    return nil, name .. ": " .. said(trouble, errno)
  end
  local lock: ReclaimLock = { fd = fd }
  return setmetatable(lock, reclaim_lock_mt), ""
end

--- What `reclaim` finds at `address`'s path, which a bind found taken,
--- read from the working directory the bind was: "refused", a socket
--- file connecting to which is refused, to take over; "gone", nothing
--- there any longer, to bind again; or "", anything else, to leave
--- alone.
local function left_behind(address: Net.Address): string
  local st, _, lstat_errno = sys.lstat(address.path)
  if st == nil then return lstat_errno == sys.ENOENT and "gone" or "" end
  if st.mode & 0xF000 ~= SOCKET_TYPE then return "" end
  -- TODO: probe through the run in a task of Poll.run, as a connect
  -- does, once reclaim's lock waits through it: the probe runs under
  -- that lock, and a second reclaim's flock of the same path would hold
  -- the thread -- and with it the task that holds the lock -- for as
  -- long as LOCK_MS. Holding the thread here keeps the lock's hold short.
  local probe, _, errno = raw.connect(raw_address(address), PROBE_MS)
  if probe ~= nil then
    local _, _ = probe:close()
    return ""
  end
  if errno == raw.ECONNREFUSED then return "refused" end
  return errno == sys.ENOENT and "gone" or ""
end

--- A unix listener at `address`; with `reclaim`, taking over a socket
--- file left behind, under the lock the caller holds.
local function listened(address: Net.Address, backlog: integer, timeout_ms: integer | nil,
    reclaim: boolean): Net.Listener | nil, string
  local socket, trouble, errno = raw.listen(raw_address(address), backlog)
  if socket == nil and errno == raw.EADDRINUSE and reclaim then
    local found = left_behind(address)
    if found == "refused" then
      local removed, why, number = sys.unlink(address.path)
      if not removed and number ~= sys.ENOENT then
        trouble, errno = why, number
        found = ""
      end
    end
    if found ~= "" then socket, trouble, errno = raw.listen(raw_address(address), backlog) end
  end
  if socket == nil then return nil, named(address) .. ": " .. said(trouble, errno) end
  return new_listener(socket, { kind = address.kind, path = address.path }, timeout_ms), ""
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
  if not opts.reclaim then return listened(address, backlog, opts.timeout_ms, false) end
  if address.path == "" then error("bad argument #1 to 'listen' (path must not be empty)", 2) end
  if address.path:sub(-1) == "/" then return nil, named(address) .. ": Is a directory" end
  local lock <close>, locking = reclaim_lock(address)
  if lock == nil then return nil, locking end
  return listened(address, backlog, opts.timeout_ms, true)
end

--- Connects to `address`. A unix one fails "No such file or directory"
--- where there is no socket file and "Connection refused" where nothing
--- listens at it, and waits for room at a listener whose backlog is
--- full (on Linux; see [`ConnectOptions.timeout_ms`]). A TCP one waits
--- for the connection to be made, and fails "Connection refused" where
--- nothing listens at the port.
function Net.connect(address: Net.Address, opts?: Net.ConnectOptions): Net.Conn | nil, string
  local timeout_ms = opts ~= nil and opts.timeout_ms or nil
  local attempt = connection(address, timeout_ms)
  if attempt.socket == nil then
    return nil, named(address) .. ": " .. said(attempt.trouble, attempt.errno, address)
  end
  return new_conn(attempt.socket, timeout_ms), ""
end

local pair_mt: metatable<Net.Pair> = {
  __close = function(self: Net.Pair)
    local _, _ = self.first:close()
    local _, _ = self.second:close()
  end,
}

--- Two connections to each other and to nothing else: for plumbing
--- within a process -- a task of [`Poll.run`] at each end -- and for
--- tests. Each waits with no limit until its `timeout_ms` is set.
function Net.pair(): Net.Pair | nil, string
  local ends, trouble = raw.pair()
  if ends == nil then return nil, trouble end
  local pair: Net.Pair = { first = new_conn(ends.first, nil), second = new_conn(ends.second, nil) }
  setmetatable(pair, pair_mt)
  return pair, ""
end

return Net
