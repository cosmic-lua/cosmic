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
--- A connection is one object for both directions; `shutdown("write")`
--- tells the peer the end of what was sent while its answer is still
--- read.
---
--- Every wait -- to connect, to accept, to read, to write -- lasts at
--- most the object's timeout (no limit by default; [`set_timeout`]
--- changes it), failing with [`Poll.TIMEOUT`], and ends with
--- "interrupted", within a tenth of a second, when the innermost open
--- [`Child.guard`] catches SIGINT or SIGTERM, as [`cosmic.http`]'s do.
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
--- failure closes that connection alone.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
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
  --- Where a socket is, as [`Net.unix`] and [`Net.tcp`] build one: a
  --- `kind` of "unix", with the socket file's `path`, or of "tcp", with
  --- a numeric `host` and a `port`. It is the raw socket module's own
  --- record, so every call takes the one an address is.
  type Address = raw_socket.Address

  record ListenOptions
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
    --- Sets how long `accept` waits by default, in nanoseconds, from 0;
    --- nil for no limit. A value no wait can last raises, naming
    --- `timeout_ns`, at the caller. The connections accepted after start
    --- with the same.
    set_timeout: function(Listener, timeout_ns: integer | nil)
    --- The next connection, waiting for one as long as `timeout_ns`
    --- (this call's, or the listener's); nil and [`Poll.TIMEOUT`],
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
    --- Sets how long a `read` or a `write` waits, in nanoseconds, from 0;
    --- nil for no limit. A connection starts with the `timeout_ns` it
    --- was made with: [`Net.connect`]'s, or its listener's or server's.
    --- A value no wait can last raises, naming `timeout_ns`, at the
    --- caller.
    set_timeout: function(Conn, timeout_ns: integer | nil)
    --- What has arrived, at most `max` bytes (64 KiB by default), once
    --- something has; nil and "" once the peer has ended what it sends.
    --- nil and [`Poll.TIMEOUT`], "interrupted" or "cancelled" (in a task of
    --- [`Poll.run`]) takes nothing, and a later read may still answer; nil
    --- and any other failure is every read's after. A failed read leaves
    --- writing be. A `max` below 1 raises.
    read: function(Conn, max?: integer): string | nil, string
    --- Sends all of `data`, waiting as the peer takes it. False and
    --- [`Poll.TIMEOUT`], "interrupted", "cancelled" (in a task of [`Poll.run`])
    --- or why not may leave part of it sent,
    --- so it is every write's after; reading is left be.
    write: function(Conn, data: string): boolean, string
    --- Ends one direction, or both: after "write" the peer reads the
    --- end of what was sent, and this side can still read its answer.
    --- A `how` that is none of "read", "write" and "both" raises.
    shutdown: function(Conn, how: string): boolean, string
    --- Closes the connection. Safe to call more than once.
    close: function(Conn): boolean, string
    --- The same as `close`: nothing sent can be taken back.
    abort: function(Conn): boolean, string
    metamethod __close: function(Conn)
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
      --- [`ConnectOptions.timeout_ns`]).
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

--- `timeout_ns`, which [`Poll.checked_ns`] has held to what a wait can
--- last, as the raw calls take it: in milliseconds, rounded up so a
--- timeout of any length is never none, or -1 for no limit.
local function milliseconds(timeout_ns: integer | nil): integer
  if timeout_ns == nil then return -1 end
  return Time.ceil(timeout_ns, MS)
end

--- What a failed call says: its own words for a deadline or a signal,
--- the bound a name too long ran past, what a host must be, and why a
--- unix listener answered EAGAIN, which errno's words leave unsaid.
local function said(trouble: string, errno: integer, address?: Net.Address): string
  if errno == raw.ETIMEDOUT then return Poll.TIMEOUT end
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

--- Waits for `fd` to be readable, or writable, at most `timeout_ns`, which
--- the caller has held to what a wait can last: in a
--- task of a run, through it; anywhere else, in the raw wait, which
--- also ends at a signal the innermost [`Child.guard`] caught.
local function waited(fd: integer, writable: boolean, timeout_ns: integer | nil): boolean, string
  -- TODO: wait through Poll.wait alone, and in `connection` too, once
  -- cosmic.poll has what the raw wait outside a task has: a core binding
  -- that gives it the core's cosmic_signal_caught (only core/socket.c's
  -- waits and sys.flock read it today), a fourth shared answer word for
  -- a wait a signal interrupted, and a loop in Poll.wait outside a task
  -- that polls in slices to look for one. A Conn's read and write are
  -- then Stream.from_fd and Stream.to_fd (see the TODO at [`new_conn`]).
  if Poll.in_task() then
    return Poll.wait(fd, writable and sys.POLLOUT or sys.POLLIN, timeout_ns)
  end
  local ok, trouble, errno = raw.wait(fd, writable, milliseconds(timeout_ns))
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

-- TODO: make a Conn's `read` and `write` the Reader and Writer
-- Stream.from_fd and Stream.to_fd answer over the socket
-- ({ nonblocking = true, timeout_ns }), collapsing this write loop into
-- theirs, once the TODO in `waited` is done: a wait outside a task here
-- ends at a signal a Child.guard caught ("interrupted", which net_test's
-- cases hold), which Poll.wait cannot see. Their `wait` option could
-- carry `waited`, but `write` also sends through raw.send, which never
-- raises SIGPIPE where sys.write may, and reads the timeout [`set_timeout`]
-- changes on every call, which an option fixes when the object is made.
--- The connection over `socket`.
local function new_conn(socket: raw_socket.Socket, timeout_ns: integer | nil): Net.Conn
  local fd = socket:fd()
  local open = true
  -- Set by [`set_timeout`], and read by each wait, so a change reaches a
  -- wait the next read or write starts.
  local limit = timeout_ns
  -- Each direction's sticky failure: once a read or a write fails for
  -- good, every later one of it says so.
  local read_failure, write_failure = "", ""
  local conn: Net.Conn
  conn = {
    set_timeout = function(_self: Net.Conn, wait_ns: integer | nil)
      Poll.checked_ns(wait_ns, "timeout_ns", 2)
      limit = wait_ns
    end,
    read = function(_self: Net.Conn, max?: integer): string | nil, string
      if max ~= nil and max <= 0 then error("net: max must be positive", 2) end
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
        local ready, waiting = waited(fd, false, limit)
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
          local ready, waiting = waited(fd, true, limit)
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
      if how ~= "read" and how ~= "write" and how ~= "both" then
        error("net: how must be \"read\", \"write\" or \"both\"", 2)
      end
      if not open then return false, "connection is closed" end
      local ok, why = raw.shutdown(fd, how)
      if not ok then return false, why end
      return true, ""
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
  -- Set by [`set_timeout`], and given to each connection accepted after.
  local limit = timeout_ns
  local listener: Net.Listener
  listener = {
    address = address,
    set_timeout = function(_self: Net.Listener, wait_ns: integer | nil)
      Poll.checked_ns(wait_ns, "timeout_ns", 2)
      limit = wait_ns
    end,
    accept = function(_self: Net.Listener, wait_ns?: integer): Net.Conn | nil, string
      Poll.checked_ns(wait_ns, "timeout_ns", 2)
      if not open then return nil, "listener is closed" end
      wait_ns = wait_ns or limit
      while true do
        local connection, why, errno = raw.accept(fd)
        if connection ~= nil then return new_conn(connection, limit), "" end
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

--- What [`connection`] made: the socket, or, where there is none, what
--- went wrong and its errno, which `said` words. `errno` is 0 for a
--- wait's own [`Poll.TIMEOUT`] or "cancelled" in a task.
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
  -- TODO: connect through raw.start, Poll.wait and raw.connected alone
  -- outside a task too, as `waited`'s TODO says: raw.connect, which
  -- waits in the core and ends at a caught signal, is what that
  -- replaces.
  Poll.checked_ns(timeout_ns, "timeout_ns", 3)
  if not Poll.in_task() then
    local socket, trouble, errno = raw.connect(address, milliseconds(timeout_ns))
    return { socket = socket, trouble = trouble, errno = errno }
  end
  local socket, trouble, errno = raw.start(address)
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

--- Whether `opts` sets `reclaim`, which no listen takes any more: a typed
--- table cannot say so, but a program written for it can.
local function sets_reclaim(opts: any): boolean
  return opts is {string: any} and opts.reclaim ~= nil
end

--- What [`Net.listen`] opens, with its descriptor; it raises at `level`
--- above its caller.
local function listening(address: Net.Address, opts: Net.ListenOptions,
    level: integer): Opened | nil, string
  if sets_reclaim(opts) then
    error("net: ListenOptions.reclaim is gone: remove the socket file a listener left " ..
      "behind (Fs.remove) once connecting to it is refused, then listen", level + 1)
  end
  local backlog = opts.backlog or DEFAULT_BACKLOG
  if backlog < 1 then error("backlog must be at least 1", level + 1) end
  Poll.checked_ns(opts.timeout_ns, "timeout_ns", level + 1)
  local socket, trouble, errno = raw.listen(address, backlog)
  if socket == nil then return nil, named(address) .. ": " .. said(trouble, errno, address) end
  if address.kind ~= "tcp" then
    return new_listener(socket, Net.unix(address.path), opts.timeout_ns), ""
  end
  local bound, why = raw.bound(socket:fd())
  if bound == nil then
    local _, _ = socket:close()
    return nil, named(address) .. ": " .. why
  end
  return new_listener(socket, Net.tcp(bound.host, bound.port), opts.timeout_ns), ""
end

--- Listens at `address`. A unix one makes its socket file, and fails
--- where the path is already there -- a socket file left behind by a
--- listener that did not close included -- rather than take the name
--- from whatever holds it. A TCP one fails "Address in use" at a port
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

--- The fields a [`Net.ServeSpec`] may hold, so a misspelt one raises
--- rather than being ignored.
local SPEC_FIELDS <const>: {string: boolean} = {
  listeners = true, serve = true, limits = true, timeout_ns = true, grace_ns = true,
  on_ready = true, on_error = true,
}

--- A field a spec once held, and what to do instead, so a program that
--- still sets one is told rather than only that the field is unknown.
local REMOVED_FIELDS <const>: {string: string} = {
  workers = "a server runs in one process, which workers = 0 asked for and is now " ..
    "the default, so drop the key; to serve in several, start each " ..
    "(Proc.relaunch gives the command, Child.start runs it), each listening at an " ..
    "address of its own",
}

--- Raises for the spec's `field`, at the caller of [`Net.serve`].
local function spec_error(field: string, must: string)
  error("Net.serve: spec." .. field .. " must be " .. must, 4)
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
      local gone = key is string and REMOVED_FIELDS[key] or nil
      error("Net.serve: spec has no field " .. tostring(key) ..
        (gone ~= nil and ": " .. gone or ""), 3)
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
    Poll.checked_ns(spec[field], "Net.serve: spec." .. field, 3)
  end
  for _, field in ipairs({ "on_ready", "on_error" }) do
    local fn = spec[field]
    if fn ~= nil and type(fn) ~= "function" then spec_error(field, "nil or a function") end
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
  metamethod __close: function(Serving)
end

local serving_mt: metatable<Serving> = {
  __close = function(self: Serving)
    for _, accepting in ipairs(self.accepts) do local _, _ = accepting.listener:close() end
    for _, conn in pairs(self.conns) do local _, _ = conn:close() end
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

--- Gives `trouble` to the spec's [`ServeSpec.on_error`], or stderr.
local function report(s: Serving, trouble: string)
  if s.spec.on_error ~= nil then
    s.spec.on_error(trouble)
    return
  end
  local _, _ = Fs.put(Fs.stderr, "Net.serve: " .. trouble .. "\n")
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
      serve_conn(s, new_conn(socket, s.spec.timeout_ns))
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

--- The body of [`Net.serve`]'s run, over listeners of its own.
local function serving(spec: Net.ServeSpec): boolean, string
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
    local opened, trouble = listening(address, {}, 1)
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
  if spec.on_ready ~= nil then spec.on_ready(addresses, server) end
  if not s.stopping then
    s.waiter = Poll.spawn(function()
      while not s.stopping do local _, _ = Poll.delay(Poll.MOST_NS) end
    end)
    local _, _ = s.waiter:join()
  end
  drain(s)
  s.watcher:cancel()
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
  local ok, why = true, ""
  Poll.run(function() ok, why = serving(spec) end)
  if not ok then return false, why end
  return true, ""
end

return Net
