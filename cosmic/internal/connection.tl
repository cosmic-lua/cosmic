--- The types of a connection and of a connector, which [`cosmic.net`]
--- re-exports as [`Net.Conn`], [`Net.ConnectOptions`] and [`Net.Connector`].
--- They are declared here, below [`cosmic.net`], so that the native
--- connector's client ([`cosmic.internal.connector`]) can answer a
--- [`Net.Connector`] without requiring cosmic.net. The client is required
--- by cosmic.child, which cosmic.net requires: naming cosmic.net's types
--- from it would be an import cycle.

local type Stream = require("cosmic.stream")
local type raw_socket = require("cosmic.internal.socket")

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
    --- wait for room connects again. A [`Connector.connect`] waits
    --- `min(timeout_ns, ceiling)` to connect instead, the ceiling being
    --- [`ConnectorOptions.timeout_ns`], and a nil `timeout_ns` waits the
    --- ceiling; the connection's reads and writes wait `timeout_ns` as here.
    timeout_ns: integer
  end

  --- A connection, answered by `accept` and [`Net.connect`]: a
  --- [`Stream.Reader`] of what the peer sends and a [`Stream.Writer`] to
  --- it.
  interface Conn is Stream.Reader, Stream.Writer
    --- Sets how long a `read` or a `write` waits, in nanoseconds, from 0;
    --- nil for no limit. A connection starts with the `timeout_ns` it
    --- was made with: [`Net.connect`]'s, or its listener's or server's.
    --- A value no wait can last raises, naming `timeout_ns`, at the
    --- caller.
    set_timeout: function(Conn, timeout_ns: integer | nil)
    --- What has arrived, at most `max_bytes` bytes (64 KiB by default), once
    --- something has; nil and "" once the peer has ended what it sends.
    --- nil and [`Poll.TIMEOUT`], "interrupted" or "cancelled" (in a task of
    --- [`Poll.run`]) takes nothing, and a later read may still answer; nil
    --- and any other failure is every read's after. A failed read leaves
    --- writing be. A `max_bytes` below 1 raises.
    read: function(Conn, max_bytes?: integer): string | nil, string
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

  --- Connects to numeric TCP addresses through the sandbox's native
  --- connector process, answered by [`Net.connector`]: a process confined
  --- to the endpoints it was given and, if so made, to a public list,
  --- which connects a socket and passes it back over a private stream.
  --- Tasks of a [`Poll.run`] share one: its process makes many
  --- connections at once (64), answering each as it is made, so a connect
  --- that hangs holds up no other. A connector with endpoints and a public
  --- list keeps 16 of those for each kind of request against the other, so
  --- a flood of one never keeps the other waiting.
  interface Connector
    --- Connects to `address`, a [`Net.tcp`] one: the connection, or nil
    --- and why ([`Poll.TIMEOUT`], "Connection refused", the connector's
    --- own refusal of an address it has no authority for, ...). An address
    --- the connector's endpoints hold, by host and port (a numeric host in
    --- any spelling of it; an endpoint at port 0 holds any nonzero port),
    --- is reached through them; any other only by a public connector (see
    --- [`Net.connector`]), unless its process refuses the address
    --- ("net: ... is refused by the connector's deny list"). The connect
    --- waits `min(opts.timeout_ns, ceiling)` (see
    --- [`ConnectorOptions.timeout_ns`]), and its answer a second more;
    --- `opts.timeout_ns` also sets the connection's later read and write
    --- wait, as [`Net.connect`] does. A request past the process's
    --- capacity waits for room within its wait; one given up on still
    --- counts until the process answers it. A connector whose process
    --- ended, or whose stream fell out of step, fails every request
    --- waiting on it, and is started again for the next, unless the
    --- relay's starter handed it over (a relay's connectors are not started
    --- again). An `address` that is no tcp
    --- [`Net.Address`], or a `timeout_ns` that is no integer from 0, raises.
    connect: function(Connector, address: Address, opts?: ConnectOptions): Conn | nil, string
    --- Whether the connector serves no request any more: it is closed, or
    --- its process, one the relay's starter handed over, has ended or its
    --- stream fell out of step, so it cannot be started again.
    ended: function(Connector): boolean
    --- Ends the connector process and reaps it: the connections it made
    --- are theirs and stay open. Safe to call more than once; a connector
    --- dropped unclosed is ended when it is collected.
    close: function(Connector): boolean, string
    metamethod __close: function(Connector)
  end
end

return Connection
