--- Stream sockets: listen at an address, accept a connection there, or
--- connect to one, and read and write it as a [`cosmic.stream`] Reader
--- and Writer.
---
---     local server <close> = assert(Net.listen(Net.unix(dir .. "/app.sock")))
---     local conn <close> = assert(server:accept())
---     local lines = Stream.lines(conn) -- holds what it read past a line
---     local line = lines:read()
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
--- most the object's `timeout_ns` (no limit by default), failing with
--- "timed out", and ends with "interrupted", within a tenth of a second,
--- when the innermost open [`Child.guard`] catches SIGINT or SIGTERM, as
--- [`cosmic.http`]'s do.
---
--- In a task of [`Poll.run`] ([`cosmic.poll`]), a wait to connect, to
--- accept, to read or to write waits through the run, so its other
--- tasks go on meanwhile: a server serves each connection in a task of
--- its own. A cancelled task's wait there fails "cancelled", and a
--- signal does not end one. Anywhere else a wait holds the thread until
--- it ends.
---
--- [`Net.serve`] is that server, for any protocol: a function of a
--- connection, run for each one accepted at any of its listeners, whose
--- failure closes that connection alone. With [`ServeSpec.workers`] it
--- serves in that many processes of this same program, started again
--- with its own arguments, which take connections from the listeners it
--- hands them.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local Proc = require("cosmic.proc")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")
local errors = require("cosmic.internal.errors")

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
    --- another's lock held 10 seconds; "interrupted" for a signal the
    --- innermost open [`Child.guard`] caught; and a directory or a link
    --- at its name fails too. In a task of [`Poll.run`], the wait for
    --- the lock waits through the run, so reclaims of one path in tasks
    --- of one run take turns as those of two processes do -- but over
    --- NFS or SMB, where a lock may be the process's own rather than its
    --- open file's, and then none waits for another of the same process.
    --- A task cancelled in that wait fails "cancelled". A relative path
    --- is read from the working directory at each step, which another
    --- task may change while one waits. A path ending in "/" fails "Is
    --- a directory", and an empty path raises, as it does without
    --- `reclaim`. A "tcp" address raises: a port holds no file to take
    --- over.
    reclaim: boolean
    --- How long `accept` waits, in nanoseconds, from 0; nil for no
    --- limit. The connections it accepts start with the same.
    timeout_ns: integer
    --- How many connections may wait to be accepted (64 by default).
    --- A unix connection past it fails at once rather than waiting (see
    --- [`ConnectOptions.timeout_ns`]).
    backlog: integer
  end

  record ConnectOptions
    --- How long connecting, and then any one read or write, waits, in
    --- nanoseconds, from 0; nil for no limit. A TCP connection is
    --- waited on until made or refused. Connecting to a unix one waits
    --- for nothing: a listener whose backlog is full fails it at once,
    --- "Resource temporarily unavailable (the listener is busy: its
    --- backlog is full)" on Linux and "Connection refused" on macOS,
    --- which cannot tell a busy listener from none. A caller that would
    --- wait for room connects again.
    timeout_ns: integer
  end

  --- A socket listening at an address, answered by [`Net.listen`].
  record Listener
    --- Where it listens.
    address: Address
    --- How long `accept` waits by default; nil for no limit.
    timeout_ns: integer
    --- The next connection, waiting for one as long as `timeout_ns`
    --- (this call's, or the listener's); nil and "timed out",
    --- "interrupted", "cancelled" (in a task of [`Poll.run`]), or why not.
    accept: function(Listener, timeout_ns?: integer): Conn | nil, string
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
    timeout_ns: integer
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

  --- What [`Net.serve`] serves, and how. A field of the wrong shape, or
  --- one not named here, raises, naming it.
  record ServeSpec
    --- Where to listen, one address or more: each is listened at, and
    --- each listener closed, by the server, which so owns every socket
    --- file it makes and removes it on stopping.
    listeners: {Address}
    --- The protocol: run once for each connection accepted, in a task of
    --- its own, which closes the connection once it returns or raises.
    --- What it raises goes to [`ServeSpec.on_error`], and the server goes
    --- on.
    serve: function(conn: Conn)
    --- What a server takes on at most.
    record Limits
      --- The most connections open at once, from 1; nil for no limit.
      --- At the limit no listener accepts: a connection that comes waits
      --- in its listener's backlog until one open closes, and a unix one
      --- past the backlog fails at once (see
      --- [`ConnectOptions.timeout_ns`]). With
      --- [`ServeSpec.workers`], each worker's limit: a connection one
      --- worker at its limit leaves waiting is taken by another.
      connections: integer
    end
    --- Bounds on what the server takes on; nil for none.
    limits: Limits
    --- Each connection's `timeout_ns`: how long any one read or write of
    --- it waits, from 0; nil for no limit.
    timeout_ns: integer
    --- On stopping, how long open connections have to finish, from 0,
    --- before they are closed and their tasks killed
    --- ([`Poll.Task.kill`]); nil to wait for every one.
    grace_ns: integer
    --- Called once every listener listens, in a task of the server's
    --- run, with where each listens -- a port the kernel chose for one
    --- at port 0 included -- in the order of `listeners`, and the
    --- server, to stop it by. It may spawn tasks of its own there, which
    --- [`Net.serve`] waits for too. What it raises, [`Net.serve`] raises,
    --- having closed every listener.
    on_ready: function(addresses: {Address}, server: Server)
    --- Given what the protocol raised for a connection, with its stack,
    --- or why a listener failed to accept; nil to write each to stderr.
    --- What it raises, [`Net.serve`] raises, having closed every listener
    --- and connection, as an error in [`Poll.run`] ends it.
    on_error: function(trouble: string)
    --- How many processes serve, from 0; nil or 0 serves in this one.
    ---
    --- From 1, this process -- the supervisor -- listens at every
    --- listener, then starts that many workers: this same program,
    --- started again ([`Proc.relaunch`]) with the arguments it was
    --- started with ([`Proc.arguments`]), in the directory it started
    --- in, with this process's environment. Its stdin is /dev/null, so
    --- a program read from stdin cannot be started so; its stdout and
    --- stderr are this process's; and it runs in a process group of
    --- its own, so a terminal's ^C reaches the supervisor alone, which
    --- stops the workers. Each worker is handed, from descriptor 3 on,
    --- a lifeline -- a socket whose peer the supervisor holds -- and
    --- then the listeners, in the order of `listeners`, and
    --- `COSMIC_NET_WORKER` naming them: "<supervisor pid>:3:4,5". The
    --- supervisor accepts nothing itself. [`on_ready`] is called in it
    --- once every worker has started, and its [`Server.stop`], or SIGINT
    --- or SIGTERM, closes its listeners -- removing each socket file, so
    --- a client that comes after is refused -- and sends each worker
    --- SIGTERM, which a worker stops on as a server in one process
    --- does. A second signal is sent on to each worker, ending its
    --- grace. A worker still running `grace_ns` and a second more after
    --- the stop is sent SIGKILL. [`Net.serve`] returns once every worker
    --- has exited.
    ---
    --- A worker that exits before the stop is reported to [`on_error`],
    --- with how it ended, and not started again; once none is left,
    --- the server stops, and [`Net.serve`] returns false, "every worker
    --- exited before the server stopped". A worker whose supervisor is
    --- gone -- ended any way, SIGKILL included, which closes its end of
    --- the lifeline -- stops as at SIGTERM, and, where `grace_ns` bounds
    --- its drain, exits, status 1, if it is still draining a second
    --- past it.
    ---
    --- A worker is a process started with `COSMIC_NET_WORKER`. The
    --- runtime takes the variable out of the environment as it starts,
    --- so no process a worker starts inherits it. The worker's first
    --- [`Net.serve`] fails, touching no descriptor, where the variable
    --- is malformed or names a supervisor that is not the process's
    --- parent -- one gone before the worker started, or a value set by
    --- hand -- rather than serve on its own, or supervise workers of its
    --- own at the same addresses. That first [`Net.serve`], whatever call
    --- that is, serves the descriptors it names in place of listening,
    --- whatever `workers` says there, and never calls [`on_ready`]. Its
    --- spec must name the listeners the supervisor's did -- a program
    --- reaches the same call with the same arguments -- and each
    --- descriptor must be a listening stream socket of the address's
    --- kind, at its port unless that is 0, or at its path; neither a
    --- TCP host nor, for a path too long to bind whole, its directory is
    --- compared. One that is not fails [`Net.serve`], naming it, and is
    --- left open, as not known to be the worker's to close. A worker's
    --- listeners close without removing their socket files, which are
    --- the supervisor's.
    workers: integer
  end

  --- A server [`Net.serve`] runs, handed to its [`ServeSpec.on_ready`].
  record Server
    --- Where each listener listens, as [`ServeSpec.on_ready`] was given.
    addresses: {Address}
    --- Stops the server, from any task of its run: every listener is
    --- closed at once, and [`Net.serve`] returns once every task of its
    --- run has ended, the connections still open after `grace_ns`
    --- closed and their tasks killed. Stopping a server that is stopping
    --- does nothing.
    stop: function(Server)
  end
end

local DEFAULT_READ <const> = 64 * 1024
local DEFAULT_BACKLOG <const> = 64
local MS <const> = Time.ms(1)

--- The address of the socket file at `path`.
function Net.unix(path: string): Net.Address
  return { kind = "unix", path = path }
end

--- The address of TCP `port` at `host`, a numeric IPv4 or IPv6 address.
function Net.tcp(host: string, port: integer): Net.Address
  return { kind = "tcp", host = host, port = port }
end

--- `timeout_ns` as the raw calls take it, in milliseconds, rounded up so
--- a timeout of any length is never none, or -1 for no limit; raising on
--- one no wait can last, so a field set wrong is named where it is read.
local function milliseconds(timeout_ns: integer | nil): integer
  if timeout_ns == nil then return -1 end
  assert(math.type(timeout_ns) == "integer" and timeout_ns >= 0 and timeout_ns <= Poll.MOST_NS,
    "timeout_ns must be nil or a whole number of nanoseconds from 0 to " .. Poll.MOST_NS)
  return Time.ceil(timeout_ns, MS)
end

--- What a failed call says: its own words for a deadline or a signal,
--- the bound a name too long ran past, what a host must be, and why a
--- unix listener answered EAGAIN, which errno's words leave unsaid.
local function said(trouble: string, errno: integer, address?: Net.Address): string
  if errno == raw.ETIMEDOUT then return "timed out" end
  if errno == raw.EINTR then return "interrupted" end
  if errno == raw.ENAMETOOLONG then
    return trouble .. " (a socket file's own name may be at most " ..
      raw.SOCKET_NAME_MAX .. " bytes here)"
  end
  if errno == raw.EAGAIN and address ~= nil and address.kind == "unix" then
    return trouble .. " (the listener is busy: its backlog is full)"
  end
  if errno == raw.EINVAL and address ~= nil and address.kind == "tcp" then
    return trouble .. " (not a numeric IPv4 or IPv6 address: a name is not looked up, " ..
      "nor an IPv6 scope read)"
  end
  return trouble
end

local function waited(fd: integer, writable: boolean, timeout_ns: integer | nil): boolean, string
  local ms = milliseconds(timeout_ns)
  if Poll.in_task() then
    local ready, why: boolean, string
    if writable then
      ready, why = Poll.writable(fd, timeout_ns)
    else
      ready, why = Poll.readable(fd, timeout_ns)
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
local function new_conn(socket: raw_socket.Socket, timeout_ns: integer | nil): Net.Conn
  local fd = socket:fd()
  local open = true
  -- Each direction's sticky failure: once a read or a write fails for
  -- good, every later one of it says so.
  local read_failure, write_failure = "", ""
  local conn: Net.Conn
  conn = {
    timeout_ns = timeout_ns,
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
        local ready, waiting = waited(fd, false, conn.timeout_ns)
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
        local sent, why, errno = raw.send(fd, data, from)
        if sent ~= nil then
          from = from + sent
        elseif errno ~= raw.EAGAIN then
          write_failure = why
          return false, why
        else
          local ready, waiting = waited(fd, true, conn.timeout_ns)
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
      -- macOS answers ENOTCONN once the peer has gone. A first close
      -- then answers ENOTCONN there, and stays so: the core cannot tell
      -- a connection that went away from a socket never connected,
      -- which only this caller knows it had.
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

--- A listener and its descriptor, which [`Net.serve`] waits on itself
--- so as to take a connection only while under its limit.
local record Opened
  listener: Net.Listener
  fd: integer
end

local listener_mt: metatable<Net.Listener> = {
  __close = function(self: Net.Listener)
    local _, _ = self:close()
  end,
}

--- The listener over `socket`, at `address`.
local function new_listener(socket: raw_socket.Socket, address: Net.Address,
    timeout_ns: integer | nil): Opened
  local fd = socket:fd()
  local open = true
  local listener: Net.Listener
  listener = {
    address = address,
    timeout_ns = timeout_ns,
    accept = function(_self: Net.Listener, wait_ns?: integer): Net.Conn | nil, string
      if not open then return nil, "listener is closed" end
      wait_ns = wait_ns or listener.timeout_ns
      while true do
        local connection, why, errno = raw.accept(fd)
        if connection ~= nil then return new_conn(connection, listener.timeout_ns), "" end
        if errno ~= raw.EAGAIN then return nil, why end
        local ready, waiting = waited(fd, false, wait_ns)
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
  return { listener = setmetatable(listener, listener_mt), fd = fd }
end

--- `address` as the raw table reads one.
local function raw_address(address: Net.Address): raw_socket.Address
  return { kind = address.kind, path = address.path, host = address.host, port = address.port }
end

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

--- A socket connected to `address`, waiting at most `timeout_ns`: in a
--- task of [`Poll.run`], through the run; anywhere else, holding the
--- thread.
local function connection(address: Net.Address, timeout_ns: integer | nil): Attempt
  local ms = milliseconds(timeout_ns)
  if not Poll.in_task() then
    local socket, trouble, errno = raw.connect(raw_address(address), ms)
    return { socket = socket, trouble = trouble, errno = errno }
  end
  local socket, trouble, errno = raw.start(raw_address(address))
  if socket == nil then return { trouble = trouble, errno = errno } end
  local holder: Connecting = { socket = socket }
  local held <close> = setmetatable(holder, connecting_mt)
  local ready, why = Poll.writable(socket:fd(), timeout_ns)
  if not ready then return { trouble = why, errno = 0 } end
  local made, refused, number = raw.connected(socket:fd())
  if not made then return { trouble = refused, errno = number } end
  held.socket = nil
  return { socket = socket }
end

--- How long `reclaim` waits for another's lock, which each holds for
--- two binds with a unix connect and an unlink between, none of which
--- waits: far past that, the holder is stuck.
local LOCK_NS <const> = Time.seconds(10)

--- The longest a reclaim in a task sleeps before it asks for another's
--- lock again, as core's `flock` does out of one.
local LOCK_PAUSE_NS <const> = Time.ms(100)

--- An exclusive lock on the file `fd` is open on, waiting at most
--- LOCK_NS for another's: in a task of [`Poll.run`], through the run,
--- since the task holding the other may be one of this run's, which a
--- wait holding the thread would keep from releasing it; anywhere
--- else, holding the thread. False and why not otherwise.
local function locked(fd: integer): boolean, string
  if not Poll.in_task() then
    local ok, trouble, errno = sys.flock(fd, "exclusive", Time.ceil(LOCK_NS, MS))
    if not ok then return false, said(trouble, errno) end
    return true, ""
  end
  local deadline = Time.monotonic_ns() + LOCK_NS
  local pause = MS
  while true do
    -- Asked once, which answers "timed out" where another holds the
    -- lock, or "interrupted" where a guard has caught a signal.
    local ok, trouble, errno = sys.flock(fd, "exclusive", 0)
    if ok then return true, "" end
    local left = deadline - Time.monotonic_ns()
    if errno ~= raw.ETIMEDOUT or left <= 0 then return false, said(trouble, errno) end
    local paused, why = Poll.delay(math.min(pause, left))
    if not paused then return false, why end
    pause = math.min(pause * 2, LOCK_PAUSE_NS)
  end
end

--- The lock `reclaim` holds, released when it goes out of scope,
--- whether the listen returns or raises; `fd` is -1 once handed on.
local record ReclaimLock
  fd: integer
  metamethod __close: function(ReclaimLock)
end

local reclaim_lock_mt: metatable<ReclaimLock> = {
  __close = function(self: ReclaimLock)
    if self.fd >= 0 then local _, _ = sys.close(self.fd) end
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
  -- Held while the lock is waited for, which in a task a run torn down
  -- ends where it waits, closing only what is held so.
  local opening: ReclaimLock = { fd = fd }
  local pending <close> = setmetatable(opening, reclaim_lock_mt)
  local ok, trouble = locked(fd)
  if not ok then return nil, name .. ": " .. trouble end
  pending.fd = -1
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
  if st.kind ~= "socket" then return "" end
  -- A unix connect answers at once, so this waits for nothing: a live
  -- listener whose backlog is full answers EAGAIN on Linux, left alone,
  -- and ECONNREFUSED on macOS, taken over (see ListenOptions.reclaim).
  local probe, _, errno = raw.connect(raw_address(address), 0)
  if probe ~= nil then
    local _, _ = probe:close()
    return ""
  end
  if errno == raw.ECONNREFUSED then return "refused" end
  return errno == sys.ENOENT and "gone" or ""
end

--- A unix listener at `address`; with `reclaim`, taking over a socket
--- file left behind, under the lock the caller holds.
local function listened(address: Net.Address, backlog: integer, timeout_ns: integer | nil,
    reclaim: boolean): Opened | nil, string
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
  return new_listener(socket, { kind = address.kind, path = address.path }, timeout_ns), ""
end

--- What [`Net.listen`] opens, with its descriptor; it raises at `level`
--- above its caller.
local function listening(address: Net.Address, opts: Net.ListenOptions,
    level: integer): Opened | nil, string
  local backlog = opts.backlog or DEFAULT_BACKLOG
  if backlog < 1 then error("backlog must be at least 1", level + 1) end
  milliseconds(opts.timeout_ns)
  if address.kind == "tcp" then
    assert(not opts.reclaim, "reclaim takes a unix address")
    local socket, trouble, errno = raw.listen(raw_address(address), backlog)
    if socket == nil then return nil, named(address) .. ": " .. said(trouble, errno, address) end
    local bound, why = raw.bound(socket:fd())
    if bound == nil then
      local _, _ = socket:close()
      return nil, named(address) .. ": " .. why
    end
    return new_listener(socket, Net.tcp(bound.host, bound.port), opts.timeout_ns), ""
  end
  if not opts.reclaim then return listened(address, backlog, opts.timeout_ns, false) end
  if address.path == "" then
    error("bad argument #1 to 'listen' (path must not be empty)", level + 1)
  end
  if address.path:sub(-1) == "/" then return nil, named(address) .. ": Is a directory" end
  local lock <close>, locking = reclaim_lock(address)
  if lock == nil then return nil, locking end
  return listened(address, backlog, opts.timeout_ns, true)
end

--- Listens at `address`. A unix one makes its socket file, and fails
--- where the path is already there -- a socket file left behind by a
--- listener that did not close included -- rather than take the name
--- from whatever holds it, unless `reclaim` takes a socket file left
--- behind by a listener that is gone. A TCP one fails "Address in use" at a port
--- another listens at; its `address` names the port it has.
--- A unix path too long to bind whole is bound from its directory,
--- and raises where the process cannot return to its working directory
--- after.
function Net.listen(address: Net.Address, opts?: Net.ListenOptions): Net.Listener | nil, string
  local opened, why = listening(address, opts or {}, 2)
  if opened == nil then return nil, why end
  return opened.listener, ""
end

--- Connects to `address`. A unix one fails "No such file or directory"
--- where there is no socket file and "Connection refused" where nothing
--- listens at it, and fails at once at a listener whose backlog is
--- full (see [`ConnectOptions.timeout_ns`]). A TCP one waits
--- for the connection to be made, and fails "Connection refused" where
--- nothing listens at the port.
--- A unix path too long to connect to whole is connected to from its
--- directory, and raises where the process cannot return to its working
--- directory after.
function Net.connect(address: Net.Address, opts?: Net.ConnectOptions): Net.Conn | nil, string
  local timeout_ns = opts ~= nil and opts.timeout_ns or nil
  local attempt = connection(address, timeout_ns)
  if attempt.socket == nil then
    return nil, named(address) .. ": " .. said(attempt.trouble, attempt.errno, address)
  end
  return new_conn(attempt.socket, timeout_ns), ""
end

local pair_mt: metatable<Net.Pair> = {
  __close = function(self: Net.Pair)
    local _, _ = self.first:close()
    local _, _ = self.second:close()
  end,
}

--- Two connections to each other and to nothing else: for plumbing
--- within a process -- a task of [`Poll.run`] at each end -- and for
--- tests. Each waits with no limit until its `timeout_ns` is set.
function Net.pair(): Net.Pair | nil, string
  local ends, trouble = raw.pair()
  if ends == nil then return nil, trouble end
  local pair: Net.Pair = { first = new_conn(ends.first, nil), second = new_conn(ends.second, nil) }
  setmetatable(pair, pair_mt)
  return pair, ""
end

--- The fields a [`Net.ServeSpec`] may hold, so a misspelt one raises
--- rather than being ignored.
local SPEC_FIELDS <const>: {string: boolean} = {
  listeners = true, serve = true, limits = true, timeout_ns = true, grace_ns = true,
  on_ready = true, on_error = true, workers = true,
}

--- The variable naming a worker's listeners: see [`ServeSpec.workers`].
local WORKER_VARIABLE <const> = "COSMIC_NET_WORKER"

--- The first descriptor a worker is handed, its lifeline, and the last
--- of the listeners that follow it: [`Proc.relaunch`] hands the program
--- its artifact and core as the two above.
local FIRST_HANDED <const> = 3
local LAST_HANDED <const> = 253

--- Raises for the spec's `field`, at the caller of [`Net.serve`].
local function spec_error(field: string, must: string)
  error("Net.serve: spec." .. field .. " must be " .. must, 4)
end

--- Why `ns` is no number of nanoseconds a wait can last, or "".
local function ns_trouble(ns: any): string
  if ns == nil or (ns is integer and ns >= 0 and ns <= Poll.MOST_NS) then return "" end
  return "nil or an integer from 0 to " .. Poll.MOST_NS
end

--- Why `address` is no [`Net.Address`] a listener can take, or "".
local function address_trouble(address: any): string
  if not address is {any: any} then return "an address, from Net.unix or Net.tcp" end
  local kind, path, host, port = address.kind, address.path, address.host, address.port
  if kind == "unix" then
    if path is string and path ~= "" then return "" end
    return "a unix address whose path is a non-empty string"
  end
  if kind == "tcp" then
    if host is string and port is integer and port >= 0 and port <= 65535 then return "" end
    return "a tcp address whose host is a string and port an integer from 0 to 65535"
  end
  return "an address, from Net.unix or Net.tcp"
end

--- Raises, naming the field, where `spec` is no [`Net.ServeSpec`].
local function checked_spec(spec: any)
  if not spec is {any: any} then error("Net.serve takes a spec table", 3) end
  for key in pairs(spec) do
    if not (key is string and SPEC_FIELDS[key]) then
      error("Net.serve: spec has no field " .. tostring(key), 3)
    end
  end
  local listeners = spec.listeners
  if not listeners is {any} or #listeners == 0 then
    spec_error("listeners", "a list of one address or more")
  end
  if listeners is {any} then
    for i, address in ipairs(listeners) do
      local trouble = address_trouble(address)
      if trouble ~= "" then spec_error("listeners[" .. i .. "]", trouble) end
    end
  end
  if type(spec.serve) ~= "function" then spec_error("serve", "a function of a connection") end
  local limits = spec.limits
  if limits ~= nil then
    if not limits is {any: any} then
      spec_error("limits", "a table")
    else
      for key in pairs(limits) do
        if key ~= "connections" then
          error("Net.serve: spec.limits has no field " .. tostring(key), 3)
        end
      end
      local most = limits.connections
      if most ~= nil and not (most is integer and most >= 1) then
        spec_error("limits.connections", "nil or an integer from 1")
      end
    end
  end
  for _, field in ipairs({ "timeout_ns", "grace_ns" }) do
    local trouble = ns_trouble(spec[field])
    if trouble ~= "" then spec_error(field, trouble) end
  end
  for _, field in ipairs({ "on_ready", "on_error" }) do
    local fn = spec[field]
    if fn ~= nil and type(fn) ~= "function" then spec_error(field, "nil or a function") end
  end
  local workers = spec.workers
  if workers ~= nil and not (workers is integer and workers >= 0) then
    spec_error("workers", "nil or an integer from 0")
  end
  if workers is integer and workers >= 1 and listeners is {any} and
      #listeners > LAST_HANDED - FIRST_HANDED then
    spec_error("listeners", "a list no longer than " .. (LAST_HANDED - FIRST_HANDED) ..
      " with workers, which are handed a descriptor for each")
  end
end

--- A listener a server accepts at, and the task accepting there while
--- there is one: none at the server's limit, or once it stops.
local record Accepting
  listener: Net.Listener
  fd: integer
  task: Poll.Task
  --- The errno the last accept failed with, reported once until another
  --- answer comes; 0 after one that did not fail.
  failing: integer
end

--- A server's state for the length of its run. Closing it closes every
--- listener and connection, so a run that raises -- [`on_ready`] or
--- [`on_error`] did -- leaves no socket file behind, and no connection
--- to a task that never started open.
local record Serving
  spec: Net.ServeSpec
  --- The most connections open at once.
  most: integer
  open: integer
  stopping: boolean
  accepts: {Accepting}
  --- Each connection open, by the task serving it.
  conns: {Poll.Task: Net.Conn}
  --- Waits, from [`on_ready`]'s end, for `stop` to cancel it.
  waiter: Poll.Task
  --- Holds SIGINT and SIGTERM for the run.
  guard: Child.Guard
  --- Waits on `guard`: its first signal stops the server, and the next
  --- ends the grace.
  watcher: Poll.Task
  --- Waits out the grace while the server drains.
  grace: Poll.Task
  --- Set once a signal has ended the grace.
  hurried: boolean
  --- Set once a signal `guard` caught has stopped the server: only
  --- then has the server acted on what the guard holds.
  signalled: boolean
  --- In a worker, the descriptor its supervisor holds the other end of,
  --- until it is closed; nil elsewhere.
  lifeline: integer
  --- In a worker, waits for its supervisor to be gone.
  orphaned: Poll.Task
  metamethod __close: function(Serving)
end

local serving_mt: metatable<Serving> = {
  __close = function(self: Serving)
    for _, accepting in ipairs(self.accepts) do local _, _ = accepting.listener:close() end
    for _, conn in pairs(self.conns) do local _, _ = conn:close() end
    if self.lifeline ~= nil then
      Poll.closing(self.lifeline)
      local _, _ = sys.close(self.lifeline)
      self.lifeline = nil
    end
    -- Closed, so a signal caught is delivered as it would be without
    -- the server's guard: this runs as the run raises, or after
    -- `serving` has closed or released the guard itself, when closing
    -- again does nothing.
    if self.guard ~= nil then local _, _ = self.guard:close() end
  end,
}

--- How long a listener waits after an accept failed -- out of
--- descriptors, say -- before it tries again, so a failure that lasts is
--- not retried, and reported, without pause.
local ACCEPT_PAUSE_NS <const> = Time.ms(100)

--- Gives `trouble` to `spec`'s [`ServeSpec.on_error`], or stderr.
local function reported(spec: Net.ServeSpec, trouble: string)
  if spec.on_error ~= nil then
    spec.on_error(trouble)
    return
  end
  local _, _ = Fs.put(Fs.stderr, "Net.serve: " .. trouble .. "\n")
end

local function report(s: Serving, trouble: string)
  reported(s.spec, trouble)
end

--- What a protocol raised, with the stack it raised from, which is gone
--- once xpcall returns.
local function traced(err: any): string
  return errors.trace(tostring(err), 2)
end

local resume_accepting: function(s: Serving)

--- Serves `conn` in a task of its own, counted open until the protocol
--- is done with it.
local function serve_conn(s: Serving, conn: Net.Conn)
  s.open = s.open + 1
  conn.timeout_ns = s.spec.timeout_ns
  local task: Poll.Task
  task = Poll.spawn(function()
    local held <close> = conn
    local ok, trouble: boolean, any = xpcall(s.spec.serve, traced, held)
    local _, _ = held:close()
    s.open = s.open - 1
    s.conns[task] = nil
    resume_accepting(s)
    if not ok then report(s, tostring(trouble)) end
  end)
  s.conns[task] = conn
end

--- Accepts at `a` while the server is under its limit and not stopping.
--- The limit is checked before each accept with no wait between, so a
--- connection past it is never taken, only left in the backlog.
local function accept_loop(s: Serving, a: Accepting)
  while not s.stopping and s.open < s.most do
    local socket, why, errno = raw.accept(a.fd)
    if socket ~= nil then
      a.failing = 0
      serve_conn(s, new_conn(socket, nil))
    elseif errno == raw.EAGAIN then
      a.failing = 0
      -- `stop` cancels this wait, as it does the pause below.
      local _, _ = Poll.readable(a.fd)
    else
      -- raw.accept has retried EINTR and passed over a pending
      -- connection that failed, so this failure is the listener's.
      if errno ~= a.failing then
        a.failing = errno
        report(s, "accepting at " .. named(a.listener.address) .. ": " .. why)
      end
      local _, _ = Poll.delay(ACCEPT_PAUSE_NS)
    end
  end
  a.task = nil
end

resume_accepting = function(s: Serving)
  if s.stopping or s.open >= s.most then return end
  for _, a in ipairs(s.accepts) do
    if a.task == nil then a.task = Poll.spawn(function() accept_loop(s, a) end) end
  end
end

--- Waits for every connection open to finish. The tasks of those left
--- once `grace_ns` has passed, or a signal has ended the grace, are
--- killed where they wait, their connections closed first.
local function drain(s: Serving)
  if not s.hurried then
    local grace = s.spec.grace_ns
    local deadline = grace ~= nil and Time.monotonic_ns() + grace or nil
    -- A task of its own, so a signal can end the grace by cancelling it.
    s.grace = Poll.spawn(function()
      while true do
        local task = next(s.conns)
        if task == nil then return end
        local left: integer = nil
        if deadline ~= nil then left = math.max(deadline - Time.monotonic_ns(), 0) end
        local ended, _ = task:join(left)
        if not ended then return end
      end
    end)
    local _, _ = s.grace:join()
  end
  local left: {Poll.Task} = {}
  for task in pairs(s.conns) do left[#left + 1] = task end
  for _, task in ipairs(left) do
    -- Closed before the kill, so a `<close>` handler that reads or
    -- writes it fails at once rather than wait; and done here, as a
    -- killed task is not resumed to do what serve_conn does after the
    -- protocol returns.
    local _, _ = s.conns[task]:close()
    local killed, trouble: boolean, any = pcall(task.kill, task)
    s.conns[task] = nil
    s.open = s.open - 1
    -- Without its stack: the handler raised as its coroutine closed,
    -- past any handler that could have traced it.
    if not killed then report(s, tostring(trouble)) end
  end
end

--- Stops `s`, as [`Server.stop`] does.
local function stop(s: Serving)
  if s.stopping then return end
  s.stopping = true
  for _, a in ipairs(s.accepts) do
    local closed, why = a.listener:close()
    if not closed then report(s, why) end
    if a.task ~= nil then a.task:cancel() end
  end
  if s.waiter ~= nil then s.waiter:cancel() end
end

--- Stops `s` at the first signal its guard takes, and ends its grace at
--- the next, until the task is cancelled.
local function watch(s: Serving)
  while true do
    local signal, _ = s.guard:wait()
    if signal == 0 then return end
    if not s.stopping then
      s.signalled = true
      stop(s)
    else
      s.hurried = true
      if s.grace ~= nil then s.grace:cancel() end
    end
  end
end

--- How long past `grace_ns` a stopped worker has to exit before it is
--- ended -- sent SIGKILL by its supervisor, or, where the supervisor is
--- gone, exiting itself: its drain ends at `grace_ns`, unless a
--- protocol holds the thread, and it then exits.
local KILL_MARGIN_NS <const> = Time.seconds(1)

--- What a worker is handed, as COSMIC_NET_WORKER names it past the
--- supervisor's pid: the descriptor whose peer the supervisor holds,
--- and each listener's, in the order of `spec.listeners`.
local record Handed
  lifeline: integer
  listeners: {integer}
end

--- The listener over `fd`, a worker's descriptor handed for
--- `listeners[i]`, `address`; nil and why it is not one. `fd` itself is
--- closed once it is known to be that listener, which the new one
--- holds a descriptor of its own on, and left alone otherwise: a
--- descriptor that is not it is not known to be the worker's to close.
local function adopted(fd: integer, address: Net.Address, i: integer): Opened | nil, string
  local handed = "descriptor " .. fd .. ", handed for listeners[" .. i .. "] (" ..
    named(address) .. ")"
  local socket, trouble = raw.adopt(fd, address.kind)
  if socket == nil then return nil, handed .. ": " .. trouble end
  local bound, why = raw.bound(socket:fd())
  if bound == nil then
    local _, _ = socket:close()
    return nil, handed .. ": " .. why
  end
  local at: Net.Address
  if address.kind == "tcp" then
    -- The host is not compared: one address has several spellings.
    if address.port ~= 0 and bound.port ~= address.port then
      local _, _ = socket:close()
      return nil, handed .. ": it listens at port " .. bound.port
    end
    at = Net.tcp(bound.host, bound.port)
  else
    -- A path too long to bind whole was bound from its directory, and
    -- the socket knows its file's own name alone, not the directory.
    local path = address.path
    local own = #path > raw.SOCKET_NAME_MAX and path:match("[^/]*$") or path
    if bound.path ~= own then
      local _, _ = socket:close()
      return nil, handed .. ": it listens at " ..
        (bound.path == "" and "no path" or string.format("%q", bound.path))
    end
    at = Net.unix(path)
  end
  local _, _ = sys.close(fd)
  return new_listener(socket, at, nil), ""
end

--- Stops a worker's server once its supervisor is gone -- the other end
--- of `s.lifeline` closed, by its exit or its death -- as a signal
--- would; and, where `grace_ns` bounds the drain, exits the process
--- once the drain has run KILL_MARGIN_NS past it, as the supervisor
--- would have killed it.
local function watch_supervisor(s: Serving)
  local gone, _ = Poll.readable(s.lifeline)
  if not gone then return end
  stop(s)
  local grace = s.spec.grace_ns
  if grace == nil then return end
  -- Over more than one delay where `grace` is near Poll.MOST_NS, the most
  -- one takes.
  local deadline = Time.monotonic_ns() + grace + KILL_MARGIN_NS
  repeat
    local outlasted, _ = Poll.delay(math.min(math.max(deadline - Time.monotonic_ns(), 0),
      Poll.MOST_NS))
    if not outlasted then return end
  until Time.monotonic_ns() >= deadline
  local _, _ = Fs.put(Fs.stderr, "Net.serve: the supervisor is gone, and connections are " ..
    "still open " .. Time.format_duration({ ns = KILL_MARGIN_NS }) ..
    " past grace_ns: exiting\n")
  Proc.exit(1)
end

--- The body of [`Net.serve`]'s run: in a worker, over the descriptors
--- `handed` it; else over listeners of its own.
local function serving(spec: Net.ServeSpec, handed: Handed | nil): boolean, string
  local state: Serving = {
    spec = spec, most = spec.limits and spec.limits.connections or math.maxinteger,
    open = 0, stopping = false, accepts = {}, conns = {}, hurried = false,
    signalled = false,
  }
  local s <close> = setmetatable(state, serving_mt)
  local guard, guard_trouble = Child.guard()
  if guard == nil then return false, "signal guard: " .. guard_trouble end
  s.guard = guard
  local addresses: {Net.Address} = {}
  for i, address in ipairs(spec.listeners) do
    local opened, trouble: Opened, string
    if handed ~= nil then
      opened, trouble = adopted(handed.listeners[i], address, i)
    else
      opened, trouble = listening(address, {}, 1)
    end
    if opened == nil then return false, trouble end
    s.accepts[i] = { listener = opened.listener, fd = opened.fd, failing = 0 }
    addresses[i] = opened.listener.address
  end
  local server: Net.Server = {
    addresses = addresses,
    stop = function(_self: Net.Server) stop(s) end,
  }
  resume_accepting(s)
  s.watcher = Poll.spawn(function() watch(s) end)
  if handed ~= nil then
    s.lifeline = handed.lifeline
    s.orphaned = Poll.spawn(function() watch_supervisor(s) end)
  elseif spec.on_ready ~= nil then
    spec.on_ready(addresses, server)
  end
  if not s.stopping then
    s.waiter = Poll.spawn(function()
      while not s.stopping do local _, _ = Poll.delay(Poll.MOST_NS) end
    end)
    local _, _ = s.waiter:join()
  end
  drain(s)
  s.watcher:cancel()
  if s.orphaned ~= nil then s.orphaned:cancel() end
  -- Released where a signal stopped the server, which has acted on it;
  -- closed otherwise, so one caught in a drain that `stop` began is
  -- delivered as it would be without this guard.
  local restore_trouble: string
  if s.signalled then
    local _, trouble = guard:release()
    restore_trouble = trouble
  else
    local _, trouble = guard:close()
    restore_trouble = trouble
  end
  if restore_trouble ~= "" then return false, "signal restore: " .. restore_trouble end
  return true, ""
end

--- A supervisor's state for the length of its run. Closing it closes
--- every listener and ends every worker still running, so a run that
--- raises -- [`on_ready`] or [`on_error`] did -- leaves neither behind.
local record Supervising
  spec: Net.ServeSpec
  listeners: {Net.Listener}
  --- The end of each worker's lifeline this process holds: closed, by
  --- this process's exit or death included, it stops every worker.
  lifeline: raw_socket.Socket
  --- Each worker not yet reaped, by its pid.
  workers: {integer: Child.Handle}
  --- How many `workers` holds.
  running: integer
  stopping: boolean
  --- Set once the workers still running past the stop were sent SIGKILL.
  killing: boolean
  --- Why the server failed, "" while it has not.
  failure: string
  --- Waits, from [`on_ready`]'s end, for `stop` to cancel it.
  waiter: Poll.Task
  --- Reaps the workers that exit before the stop.
  monitor: Poll.Task
  --- Holds SIGINT and SIGTERM for the run.
  guard: Child.Guard
  --- Waits on `guard`: its first signal stops the server, and each
  --- after is sent on to the workers.
  watcher: Poll.Task
  --- Set once a signal `guard` caught has stopped the server.
  signalled: boolean
  metamethod __close: function(Supervising)
end

local supervising_mt: metatable<Supervising> = {
  __close = function(self: Supervising)
    for _, listener in ipairs(self.listeners) do local _, _ = listener:close() end
    for _, handle in pairs(self.workers) do local _, _ = handle:close() end
    if self.lifeline ~= nil then local _, _ = self.lifeline:close() end
    if self.guard ~= nil then local _, _ = self.guard:close() end
  end,
}

--- Sends `signal` to every worker still running, and each process of
--- its group. One reaped already -- a wait of another handle collects
--- every child that has exited -- is passed over.
local function signal_workers(s: Supervising, signal: integer)
  for pid, _ in pairs(s.workers) do
    local sent, why, errno = sys.kill(-pid, signal)
    if not sent and errno ~= sys.ESRCH then
      reported(s.spec, "signalling worker " .. pid .. ": " .. why)
    end
  end
end

--- Stops `s`, as [`Server.stop`] does.
local function stop_supervising(s: Supervising)
  if s.stopping then return end
  s.stopping = true
  for _, listener in ipairs(s.listeners) do
    local closed, why = listener:close()
    if not closed then reported(s.spec, why) end
  end
  signal_workers(s, sys.SIGTERM)
  if s.waiter ~= nil then s.waiter:cancel() end
  if s.monitor ~= nil then s.monitor:cancel() end
end

--- How a worker's `result` says it ended.
local function ended(result: Child.Result): string
  if result.signal ~= nil then return "ended by signal " .. result.signal end
  return "exited with status " .. tostring(result.code)
end

--- Reaps every worker that has exited, reporting one that exited before
--- the stop or was killed for outlasting it.
local function reap(s: Supervising)
  -- A settle can wait through the run, in which another task may reap
  -- the same worker: each is taken from a list made first, and counted
  -- off by the task that finds it still there.
  local listed: {integer: Child.Handle} = {}
  for pid, handle in pairs(s.workers) do listed[pid] = handle end
  for pid, handle in pairs(listed) do
    local answer, why = handle:try_wait()
    local trouble = ""
    if s.workers[pid] ~= handle then
      answer = { finished = false }
    elseif answer == nil then
      trouble = "worker " .. pid .. ": " .. why
      local _, _ = handle:close()
    elseif answer.finished and s.killing and answer.result.signal == sys.SIGKILL then
      trouble = "worker " .. pid .. " was still running " ..
        Time.format_duration({ ns = KILL_MARGIN_NS }) .. " past grace_ns after the stop, and was killed"
    elseif answer.finished and not s.stopping then
      trouble = "worker " .. pid .. " " .. ended(answer.result)
    end
    if answer == nil or answer.finished then
      s.workers[pid] = nil
      s.running = s.running - 1
    end
    if trouble ~= "" then reported(s.spec, trouble) end
  end
end

--- Waits through the run for the first of the workers still running to
--- exit, at most `timeout_ns` nanoseconds (no limit when nil), or for
--- the task to be cancelled. A worker whose settling failed -- its group
--- would not empty -- is reported and passed over, as [`reap`] does.
local function await_worker(s: Supervising, timeout_ns?: integer)
  local handles: {Child.Handle} = {}
  for _, handle in pairs(s.workers) do handles[#handles + 1] = handle end
  local done, trouble = Child.wait_any(handles, timeout_ns)
  if done ~= nil and trouble ~= "" and s.workers[done.pid] == done then
    s.workers[done.pid] = nil
    s.running = s.running - 1
    reported(s.spec, "worker " .. done.pid .. ": " .. trouble)
  end
end

--- Reaps the workers until the stop, and stops the server once none is
--- left.
local function monitor(s: Supervising)
  while not s.stopping do
    reap(s)
    if s.running == 0 then
      s.failure = "every worker exited before the server stopped"
      stop_supervising(s)
      return
    end
    await_worker(s)
  end
end

--- Stops `s` at the first signal its guard takes, and sends each after
--- on to its workers, until the task is cancelled.
local function watch_supervising(s: Supervising)
  while true do
    local signal, _ = s.guard:wait()
    if signal == 0 then return end
    if not s.stopping then
      s.signalled = true
      stop_supervising(s)
    else
      signal_workers(s, signal)
    end
  end
end

--- Waits for every worker to exit once `s` has stopped, sending SIGKILL
--- to those still running `grace_ns` and KILL_MARGIN_NS after.
local function wind_down(s: Supervising)
  local grace = s.spec.grace_ns
  local deadline = grace ~= nil and Time.monotonic_ns() + grace + KILL_MARGIN_NS or nil
  while true do
    reap(s)
    if s.running == 0 then return end
    if deadline ~= nil and not s.killing and Time.monotonic_ns() >= deadline then
      s.killing = true
      signal_workers(s, sys.SIGKILL)
    end
    -- Held to what a wait takes: `grace_ns` may be Poll.MOST_NS, and the
    -- margin past it then runs out over a second wait.
    local left: integer
    if deadline ~= nil and not s.killing then
      left = math.min(math.max(deadline - Time.monotonic_ns(), 0), Poll.MOST_NS)
    end
    await_worker(s, left)
  end
end

--- How to start a worker: its command line and options.
local record WorkerStart
  argv: {string}
  options: Child.Options
end

--- How to start a worker handed `lifeline` and `fds`, each listener's
--- descriptor in order: this program again, with its arguments, in the
--- directory it started in, and this process's environment with the
--- variable naming them. Nil and why where this program has no artifact
--- to start again ([`Proc.relaunch`]).
local function worker_start(lifeline: integer, fds: {integer}): WorkerStart | nil, string
  local relaunch, trouble = Proc.relaunch()
  if relaunch == nil then return nil, "this program cannot be started again: " .. trouble end
  local argv: {string} = {}
  for _, word in ipairs(relaunch.argv) do argv[#argv + 1] = word end
  for _, word in ipairs(Proc.arguments()) do argv[#argv + 1] = word end
  local env = Env.all()
  for name, value in pairs(relaunch.env) do env[name] = value end
  local handed: {integer: integer | string} = {}
  for number, fd in pairs(relaunch.fds) do handed[number] = fd end
  handed[FIRST_HANDED] = lifeline
  local numbers: {string} = {}
  for i, fd in ipairs(fds) do
    handed[FIRST_HANDED + i] = fd
    numbers[i] = tostring(FIRST_HANDED + i)
  end
  env[WORKER_VARIABLE] = sys.getpid() .. ":" .. FIRST_HANDED .. ":" .. table.concat(numbers, ",")
  return {
    argv = argv,
    options = { env = env, fds = handed, stdin = "null", cwd = relaunch.cwd },
  }, ""
end

--- The body of [`Net.serve`]'s run with [`ServeSpec.workers`].
local function supervising(spec: Net.ServeSpec): boolean, string
  local state: Supervising = {
    spec = spec, listeners = {}, workers = {}, running = 0, stopping = false,
    killing = false, failure = "", signalled = false,
  }
  local s <close> = setmetatable(state, supervising_mt)
  local guard, guard_trouble = Child.guard()
  if guard == nil then return false, "signal guard: " .. guard_trouble end
  s.guard = guard
  local addresses: {Net.Address} = {}
  local fds: {integer} = {}
  for i, address in ipairs(spec.listeners) do
    local opened, trouble = listening(address, {}, 1)
    if opened == nil then return false, trouble end
    s.listeners[i] = opened.listener
    fds[i] = opened.fd
    addresses[i] = opened.listener.address
  end
  local ends, pair_trouble = raw.pair()
  if ends == nil then return false, "starting a worker: " .. pair_trouble end
  s.lifeline = ends.first
  local handed <close> = ends.second
  local start, start_trouble = worker_start(handed:fd(), fds)
  if start == nil then return false, "starting a worker: " .. start_trouble end
  for i = 1, spec.workers do
    local handle, trouble = Child.start(start.argv, start.options)
    if handle == nil then return false, "starting worker " .. i .. ": " .. trouble end
    s.workers[handle.pid] = handle
    s.running = s.running + 1
  end
  -- Only the workers hold this end now, so the one this process holds
  -- reads as closed to them once it closes.
  local _, _ = handed:close()
  local server: Net.Server = {
    addresses = addresses,
    stop = function(_self: Net.Server) stop_supervising(s) end,
  }
  s.watcher = Poll.spawn(function() watch_supervising(s) end)
  s.monitor = Poll.spawn(function() monitor(s) end)
  if spec.on_ready ~= nil then spec.on_ready(addresses, server) end
  if not s.stopping then
    s.waiter = Poll.spawn(function()
      while not s.stopping do local _, _ = Poll.delay(Poll.MOST_NS) end
    end)
    local _, _ = s.waiter:join()
  end
  wind_down(s)
  s.watcher:cancel()
  local restore_trouble: string
  if s.signalled then
    local _, trouble = guard:release()
    restore_trouble = trouble
  else
    local _, trouble = guard:close()
    restore_trouble = trouble
  end
  if restore_trouble ~= "" then return false, "signal restore: " .. restore_trouble end
  if s.failure ~= "" then return false, s.failure end
  return true, ""
end

--- A descriptor `word` names, from FIRST_HANDED to LAST_HANDED; nil for
--- none.
local function descriptor_named(word: string): integer | nil
  local fd = word:match("^%d+$") and math.tointeger(tonumber(word)) or nil
  if fd == nil or fd < FIRST_HANDED or fd > LAST_HANDED then return nil end
  return fd
end

--- What `found`, [`WORKER_VARIABLE`] as the runtime took it, hands a
--- worker of `count` listeners; nil and why it hands nothing: it is
--- malformed, or names a supervisor that is not this process's parent
--- -- one gone before the worker started, or a value set by hand --
--- where serving as a server of its own would take the supervisor's
--- place, or become one.
local function handed_descriptors(found: raw_socket.Handed, count: integer): Handed | nil, string
  local value = found.value
  local malformed = WORKER_VARIABLE .. " must name the supervisor's pid, a descriptor " ..
    "and then one for each listener, each from " .. FIRST_HANDED .. " to " .. LAST_HANDED ..
    " and each once, as \"<pid>:3:4,5\", not " .. string.format("%q", value)
  local pid, first, rest = value:match("^(%d+):([^:]*):(.*)$")
  if pid == nil then return nil, malformed end
  if math.tointeger(tonumber(pid)) ~= found.parent then
    return nil, WORKER_VARIABLE .. " names supervisor " .. pid .. ", not this process's parent " ..
      found.parent .. ": its supervisor is gone, or it was set by another"
  end
  local lifeline = descriptor_named(first)
  if lifeline == nil then return nil, malformed end
  local seen: {integer: boolean} = { [lifeline] = true }
  local fds: {integer} = {}
  for word in (rest .. ","):gmatch("([^,]*),") do
    local fd = descriptor_named(word)
    if fd == nil or seen[fd] then return nil, malformed end
    seen[fd] = true
    fds[#fds + 1] = fd
  end
  if #fds ~= count then
    return nil, WORKER_VARIABLE .. " must name a descriptor for each listener: it names " ..
      #fds .. ", and the spec has " .. count
  end
  return { lifeline = lifeline, listeners = fds }, ""
end

--- Serves `spec.serve` at each of `spec.listeners`, each connection in a
--- task of its own, in a [`Poll.run`] of its own: so it cannot be called
--- in a task of another. It returns true once [`Server.stop`] has been
--- called, or a signal has stopped it, and every task of the run has
--- ended -- each connection's, and any [`ServeSpec.on_ready`] spawned
--- -- and false and why, having called nothing, where a listener cannot
--- listen or its signal guard cannot be opened, or, having served,
--- where the guard cannot restore the dispositions it found. What
--- [`ServeSpec.on_ready`] or [`ServeSpec.on_error`] raises, it raises,
--- having closed every listener and connection.
---
--- One connection's failure is its own: what its protocol raises is
--- given to [`ServeSpec.on_error`], the connection is closed, and the
--- rest are served on. A connection still open `grace_ns` after the
--- stop is closed, and its task killed where it waits
--- ([`Poll.Task.kill`]): the protocol is not resumed, but its `<close>`
--- variables are closed -- where a read or write of the connection
--- fails at once, and any other wait raises -- and what one of them
--- raises is reported the same way, without its stack.
--- A protocol that loops without waiting -- calling read after
--- "connection is closed", which fails without waiting, or computing
--- without end -- cannot be killed: it holds the thread, and so every
--- task of the run and Net.serve's return, until it waits.
---
--- With [`ServeSpec.workers`], this process supervises workers that
--- serve, as that field says, and the connections, protocols and
--- signals below are each worker's.
---
--- SIGINT and SIGTERM stop the server as [`Server.stop`] does: it holds
--- a [`Child.guard`] for its run, and the first signal of either kind
--- stops it. One more while it drains ends `grace_ns` at once, the
--- connections still open killed and closed. Where a signal stopped
--- it, the guard is released, not closed, so Net.serve returns true
--- without the signal delivered again; a caller that would know of it,
--- or die of it, holds a [`Child.guard`] of its own around the call,
--- which sees it too. A signal the server did not stop on, one in a
--- drain [`Server.stop`] began, is delivered again as the guard closes,
--- as it would be without it; so is any signal caught where a listener
--- cannot listen or [`ServeSpec.on_ready`] or [`ServeSpec.on_error`]
--- raises. A
--- [`Child.run`] in a protocol holds a guard inside the server's, so a
--- signal ends its child as it would anywhere, and a run begun after
--- the signal runs to its end. A wait that holds the thread rather than
--- waiting through the run ([`Http.get`]'s, `h:wait` on a child a
--- protocol started) reads the server's guard, and ends at a signal.
function Net.serve(spec: Net.ServeSpec): boolean, string
  checked_spec(spec)
  if Poll.in_task() then
    error("Net.serve runs a Poll.run of its own, and cannot be called in a task of another", 2)
  end
  local found = raw.handed()
  local handed: Handed = nil
  if found ~= nil then
    local fds, trouble = handed_descriptors(found, #spec.listeners)
    if fds == nil then return false, trouble end
    handed = fds
  end
  local ok, why = true, ""
  Poll.run(function()
    if handed == nil and (spec.workers or 0) >= 1 then
      ok, why = supervising(spec)
    else
      ok, why = serving(spec, handed)
    end
  end)
  if not ok then return false, why end
  return true, ""
end

return Net
