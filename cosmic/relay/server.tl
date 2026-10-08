--- The sandbox relay's serving core (the sandbox plan, #2621, "The relay
--- and the terminal"): the program's only way out, an HTTP CONNECT and a
--- SOCKS5 listener whose requests it matches against the policy's `connect`
--- grants, resolves, checks and connects, and then carries bytes for. It
--- runs in the tasks of one [`Poll.run`] and holds no host socket of its
--- own that is not yet connected: a connection leaves through the
--- `connector` it is given, which is handed only addresses the relay has
--- checked.
---
--- Each connection is decided in this order, and the decision is one line
--- on the relay's log, naming the remedy of a refusal
--- ("not granted: --connect api.github.com:443"):
---
--- 1. The request is read by [`cosmic.relay.wire`]'s readers. Within the
---    `head` timeout and `header_bytes`, or it is refused saying so.
--- 2. A host that is a name must be named by a grant of `host:port`, or of
---    `*:port`, `host:*` or `*:*`; the host matches exactly, as the reader
---    wrote it (lower case, no trailing dot): a grant opens no subdomain,
---    for the policy's grammar has no wildcard but a whole host or port.
---    A host that is an IP address is refused unless a grant names that
---    address and port literally ([`cosmic.relay.address`]'s `granted`),
---    whatever the address is. Nothing is resolved before this passes.
--- 3. A name is resolved once, right now, with no cache, within the
---    `resolve` timeout, and the answers
---    [`cosmic.relay.address`]'s `permitted` allows are the only ones
---    connected to, tried in the order received (step 4): never another.
---    A loopback, private or metadata answer is allowed only by a literal
---    grant of that address.
--- 4. The `connector` connects the first of them that answers, one after
---    another within the one `connect` timeout, each given an equal share
---    of what is left, so with several addresses a slow but working first
---    one gets only its share (the `connect` timeout divided by their
---    number); the program is told of one failure, naming every address
---    tried, only when all failed, and its status is the last failure's.
--- 5. The program is told it has succeeded, and the first bytes it sends
---    are read as a TLS ClientHello when they are one: a hello that
---    carries Encrypted Client Hello or encrypted SNI, one whose server
---    name differs from the requested host, one that is malformed, and one
---    with no server name on a TLS port (443 and 853, or `tls_ports`)
---    close the connection, with a TLS alert, and log why. Bytes that are
---    not TLS pass: ssh on port 22 and every other protocol, on any port.
---    A client that does not send first (a server that speaks first, like
---    ssh and SMTP) is not waited for. A protocol that upgrades to TLS
---    after its own greeting (STARTTLS) is not seen, and a hello after
---    the first bytes is not read.
--- 6. Bytes are carried both ways until both sides have ended what they
---    send, one side fails, or no byte moves in either direction for the
---    `idle` timeout. A side that ends is passed on to the other as a
---    half-close.
---
--- Behind an upstream proxy ([`Relay.Upstream`], from [`Relay.upstream`]),
--- steps 2 and 5 are the same and steps 3 and 4 connect to the upstream
--- instead -- at the addresses its starter resolved once
--- ([`Relay.Upstream.addresses`]), or its host resolved for the
--- connection where it gave none, its answers checked and connected
--- through the connector -- and ask it to CONNECT: the upstream resolves the
--- name, so the address checks do not apply to what it reaches, which the
--- relay says once, at its start. The upstream's own address is the one the
--- caller's `https_proxy` names, so it needs no grant (a proxy on loopback or
--- a private network is the usual one), and a program that asks for that
--- address by IP is refused as any other literal. A `*` host grant would let
--- a name such as `internal.corp` reach what the upstream's own network
--- resolves it to, which this relay cannot see: `localhost` and `*.localhost`
--- are refused in this mode, and the rest is the upstream's to refuse.
---
--- Caps, each refused with its own reason in the program's reply: the
--- connections open at once (`connections`), the bytes of a request
--- (`header_bytes`) and the connections the relay serves in all
--- (`total`). A connection past the first is still read as far as its
--- request, to be answered, but at most [`Relay.Limits.connections`] more
--- than the cap are accepted: the listeners wait beyond that.
---
--- Name resolution waits through the run ([`Net.resolve`] in a task), so
--- only the connection resolving waits for its answer, at most the
--- `resolve` timeout; the others, their deadlines and the stop go on.
---
--- The relay asks for no credentials unless its spec carries a `token`, as
--- the listeners of a sandbox whose network is its own need none. With one,
--- it is the first thing every connection is held to, before the grants:
--- a CONNECT carries it as the password of a Basic `Proxy-Authorization`
--- (any user name), and a SOCKS5 client as the password of RFC 1929's
--- username and password (any user name), the only method it selects. A
--- connection that does not is refused (407, or a failed authentication
--- and a close) and logged as one short line that never holds a credential;
--- it is no flow. A connection counts against `connections`, `total` and
--- the stats only once it has authenticated; until then it counts against
--- [`Relay.Limits.pre_auth`] alone, which the `auth` timeout bounds in time,
--- so a program that opens connections and never authenticates cannot
--- spend what an authenticated one is given. Authenticating has a wait of
--- its own, the `auth` timeout (3 seconds, from the connection's first read
--- to the credential, the `head` wait starting after it). A process that can
--- reach the listener can still fill the pre-auth slots and keep them
--- filled, each held for at most the `auth` timeout, and so delay a
--- connection that arrives meanwhile by about that long: the relay bounds
--- the harm, and cannot tell that process from the program. The user name
--- is any value: a SOCKS5 one must be 1 to 255 bytes (RFC 1929) and an empty
--- one is refused; `cosmic sandbox connect` sends "cosmic" for an empty one.
--- macOS's start draws one for each sandbox, whose relay listens on the
--- host's loopback ([`cosmic.relay.main`]).
---
--- A `mixed` listener serves both protocols at its port: a connection whose
--- first byte is 5, SOCKS5's version, is read as SOCKS5, and any other as
--- an HTTP CONNECT, whose method begins with a letter. That byte is read
--- within the wait of the reader it chooses, and is the reader's first.
---
---     local server = Relay.start({
---       http = http_listener, socks = socks_listener,
---       grants = { "api.github.com:443" },
---       connector = connect_through_the_connector,
---     })
---     server:wait()

local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Log = require("cosmic.log")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Address = require("cosmic.relay.address")
local Config = require("cosmic.relay.config")
local Wire = require("cosmic.relay.wire")
local Grant = require("cosmic.relay.grant")
local String = require("cosmic.string")

local record Relay
  --- Connects to the numeric `address` and `port` the relay has checked,
  --- waiting at most `timeout_ns`: the connection, or nil and why
  --- ("Connection refused", [`Poll.TIMEOUT`], ...). The sandbox's is
  --- the native connector ([`Net.connector`]), which connects nothing but the
  --- numeric endpoint it is given: its [`Net.Connector.as_function`] is one.
  type Connector = function(address: string, port: integer, timeout_ns: integer): Net.Conn | nil, string

  --- How long each wait may last, in nanoseconds; a nil field takes its
  --- default.
  record Timeouts
    --- A name's lookup (5 seconds).
    resolve: integer
    --- A connection's making, and an upstream's CONNECT (10 seconds).
    connect: integer
    --- No byte in either direction of a tunnel (5 minutes).
    idle: integer
    --- A request, and a ClientHello that has begun, to be read whole (10
    --- seconds): a program that dribbles one is not held.
    head: integer
    --- With a [`Spec.token`], the whole of authenticating: a CONNECT's head
    --- with its credential, a SOCKS5 greeting with its username and password
    --- (3 seconds). The `head` wait starts only after it.
    auth: integer
  end

  --- What the relay takes on at most; a nil field takes its default.
  record Limits
    --- Connections open at once (64).
    connections: integer
    --- Bytes of a request head (16384, the most [`cosmic.relay.wire`] reads).
    header_bytes: integer
    --- Connections served in all, the relay's life being the sandbox's
    --- (100000).
    total: integer
    --- With a [`Spec.token`], connections open at once that have not yet
    --- authenticated (64): the listeners wait while that many are, and each
    --- is ended by the `auth` timeout at the latest. Unused without one.
    pre_auth: integer
  end


  --- The proxy a caller's `https_proxy` names, and the hosts `no_proxy`
  --- says to reach directly ([`cosmic.relay.config`]'s [`Upstream`]).
  type Upstream = Config.Upstream

  --- The connectors a relay was handed by its starter, which
  --- [`Relay.handed`] makes one [`Connector`] of. A field left nil is a
  --- connector not handed.
  record Handed
    --- The connector whose table holds the addresses a grant names
    --- literally and the upstream's, which `table` lists in its order.
    table_connector: Net.Connector
    --- Its table.
    table: {Net.Endpoint}
    --- A public connector ([`Net.connector`]'s `public`), for an address
    --- no table holds: one a granted name resolved to.
    public_connector: Net.Connector
    --- Told why the first time a request finds a connector has ended,
    --- once for each: nothing it reaches can be reached again, as no
    --- connector is started anew. The relay's process ends then
    --- ([`cosmic.relay.main`]). Nil to fail each such request alone.
    lost: function(why: string)
  end

  --- What a relay serves, and how.
  record Spec
    --- The listener that takes HTTP CONNECT requests, already bound; nil
    --- for none.
    http: Net.Listener
    --- The listener that takes SOCKS5 requests, already bound; nil for
    --- none.
    socks: Net.Listener
    --- Listeners that take both, each connection read as its first byte
    --- says (a relay on the host's loopback holds one port on 127.0.0.1
    --- and ::1); nil or empty for none. One of the three is needed.
    mixed: {Net.Listener}
    --- The policy's `connect` targets, `host:port`.
    grants: {string}
    --- How a connection is made.
    connector: Connector
    --- The resolver's options ([`Net.ResolveOptions`]): `servers`,
    --- `hosts_file` and `connector`, which are the trusted caller's own.
    --- The sandbox's relay resolves through a connector of the name
    --- servers alone, over TCP ([`cosmic.sandbox.relay`]). Its `timeout_ns`
    --- is [`Timeouts.resolve`]'s.
    resolve: Net.ResolveOptions
    --- Why no name can be resolved, or nil: set, every name fails with it
    --- (502, "host_unreachable") and nothing is asked, while an address a
    --- grant names literally is still connected.
    unresolved: string
    --- The host's own addresses, which the relay refuses to connect to
    --- ([`cosmic.relay.address`]'s `own_addresses`).
    own_addresses: {string}
    --- The proxy to connect through, or nil to connect directly.
    upstream: Upstream
    --- The ports that carry TLS (443 and 853 by default): a hello on one
    --- must name its server.
    tls_ports: {integer}
    --- The waits' lengths.
    timeouts: Timeouts
    --- The caps.
    limits: Limits
    --- Where decision lines go, one call each; nil for stderr.
    log: function(line: string)
    --- The per-sandbox token every connection must present, 16 to 255 bytes
    --- with no control byte (255 is the most RFC 1929 carries), or nil to ask
    --- for none. A caller draws 128 bits or more from a secure source and
    --- writes them in a printable form (hex, base64url): a guess is bounded
    --- by nothing but the token's entropy.
    token: string
    --- Told why, once, the first time a lookup fails through a `resolve`
    --- connector that has ended: no name can be resolved again, as no
    --- connector is started anew. The relay's process ends then
    --- ([`cosmic.relay.main`]). Nil to fail each such lookup alone.
    lost: function(why: string)
  end

  --- What a running relay has done.
  record Stats
    --- Connections open now. With a [`Spec.token`], only those that have
    --- authenticated.
    open: integer
    --- Connections accepted in all. With a [`Spec.token`], only those that
    --- have authenticated.
    accepted: integer
    --- Connections refused, for any reason, those that failed to
    --- authenticate included.
    refused: integer
  end

  --- A running relay, answered by [`Relay.start`].
  record Serving
    --- Closes the listeners and every open connection, and ends every
    --- task of the relay once they have noticed.
    stop: function(Serving)
    --- Waits for every task of the relay to end: the listeners' (which
    --- end at `stop`) and then the connections'.
    wait: function(Serving)
    --- What it has done so far.
    stats: function(Serving): Stats
  end
end

local DEFAULT_TIMEOUTS <const>: Relay.Timeouts = {
  resolve = Clock.seconds(5), connect = Clock.seconds(10), idle = Clock.minutes(5), head = Clock.seconds(10),
  auth = Clock.seconds(3),
}
local DEFAULT_LIMITS <const>: Relay.Limits = { connections = 64, header_bytes = 16384, total = 100000, pre_auth = 64 }
local DEFAULT_TLS_PORTS <const>: {integer} = { 443, 853 }

--- How many connections past `connections` are accepted to be refused
--- by name; the listeners wait beyond that.
local REFUSING <const> = 16

--- The most bytes of a log line.
local MAX_LOG <const> = 600

--- The most bytes read at once.
local CHUNK <const> = 16384

--- A fatal TLS handshake_failure alert, the answer to a hello the relay
--- refuses.
local TLS_ALERT <const> = "\21\3\3\0\2\2\40"

--- `text` in lower case.
local function lower(text: string): string
  return (text:gsub("%u", string.lower))
end

--- A decimal `port`, or nil.
local function number_of(text: string): integer | nil
  if not text:find("^[1-9]%d*$") or #text > 5 then return nil end
  local port = math.tointeger(tonumber(text))
  if port == nil or port < 1 or port > 65535 then return nil end
  return port
end

--- `ns` in words: whole seconds, or milliseconds below one.
local function span(ns: integer): string
  if ns >= Clock.seconds(1) then
    return String.counted(ns // Clock.seconds(1), "second")
  end
  return String.counted(ns // Clock.ms(1), "millisecond")
end

--- One grant of a name, as the relay matches it.
local record NameGrant
  --- The host, as a request's is written, or "*".
  host: string
  --- The port, 0 for any.
  port: integer
end

--- The grants that match names, and a note for each that opens nothing.
--- A grant a policy validated ([`cosmic.relay.grant`]) has none; a relay
--- started on its own configuration may be given one.
local function name_grants(grants: {string}): {NameGrant}, {string}
  local names: {NameGrant} = {}
  local notes: {string} = {}
  for _, grant in ipairs(grants) do
    local parsed, why = Grant.parse(grant)
    if parsed == nil then
      notes[#notes + 1] = ("grant \"%s\" opens nothing: %s"):format(grant, why)
    elseif parsed.kind == "any" or parsed.kind == "name" then
      -- An address is matched literally, by [`Address.granted`].
      names[#names + 1] = { host = parsed.host, port = parsed.port }
    end
  end
  return names, notes
end

--- Whether `names` grant the name `host` on `port`.
local function name_granted(names: {NameGrant}, host: string, port: integer): boolean
  for _, grant in ipairs(names) do
    if (grant.host == "*" or grant.host == host) and (grant.port == 0 or grant.port == port) then
      return true
    end
  end
  return false
end

--- `host:port`, an IPv6 host in brackets.
local function target(host: string, port: integer): string
  if host:find(":", 1, true) then host = "[" .. host .. "]" end
  return host .. ":" .. port
end

--- The name servers `servers`, each at its port, as the "udp" addresses
--- [`Net.ResolveOptions.servers`] takes: the list a lookup through a
--- connector of exactly those servers asks.
--- @param servers {Net.Endpoint} The connector's table
--- @return {Net.Address} The same servers
function Relay.udp_servers(servers: {Net.Endpoint}): {Net.Address}
  local out: {Net.Address} = {}
  for i, server in ipairs(servers) do out[i] = Net.udp(server.host, server.port) end
  return out
end

--- The requests of `connector` (`name` in a refusal), each asked with
--- its own `timeout_ns`: the connector makes several connections at
--- once, so a connect that hangs holds up no other. Once it has ended, a
--- request fails saying so, and `lost`, where given, is told so the first
--- time.
local function served_by(connector: Net.Connector, name: string, lost: function(string) | nil):
    function(endpoint: integer | string, port: integer, timeout_ns: integer): Net.Conn | nil, string
  local told = false
  --- Tells `lost`, the first time, that the connector has ended.
  local function ended(): string
    local why = "relay: the " .. name .. " connector has ended"
    if lost ~= nil and not told then
      told = true
      lost(why)
    end
    return why
  end
  return function(endpoint: integer | string, port: integer, timeout_ns: integer): Net.Conn | nil, string
    if connector:ended() then return nil, ended() end
    -- A connect raises only for arguments it refuses, which this module's
    -- own are not.
    local conn, why = connector:connect(endpoint, port, timeout_ns)
    if conn ~= nil then return conn, "" end
    -- The connector ended under the request: why it did is the request's.
    if connector:ended() then ended() end
    return nil, why
  end
end

--- The [`Connector`] of the connectors a relay's starter handed it
--- ([`cosmic.sandbox.relay`]): an address and port the table holds is asked
--- of the table connector, by its place in the table, and any other of
--- the public connector, which refuses what its deny list does; with
--- neither, the connection fails, naming the address. Each makes several
--- connections at once, so a connect that hangs holds up no other. Once
--- one has ended, a connection it would make fails saying so, and
--- `handed.lost` is told. A `handed` with no connector, a table connector
--- without its table, or a `lost` that is no function raises.
--- @param handed Relay.Handed The connectors
--- @return Relay.Connector What [`Relay.Spec.connector`] takes
function Relay.handed(handed: Relay.Handed): Relay.Connector
  if type(handed) ~= "table" or (handed.table_connector == nil and handed.public_connector == nil) then
    error("relay: handed needs a table connector or a public one", 2)
  end
  if handed.table_connector ~= nil and type(handed.table) ~= "table" then
    error("relay: handed.table must list the table connector's endpoints", 2)
  end
  if handed.lost ~= nil and type(handed.lost) ~= "function" then
    error("relay: handed.lost must be a function", 2)
  end
  local rows: {string} = {}
  local ports: {integer} = {}
  for i, entry in ipairs(handed.table or {}) do
    local bytes = Address.parse(entry.host)
    if bytes == nil then error("relay: handed.table[" .. i .. "] is not a numeric endpoint", 2) end
    rows[i], ports[i] = table.concat(bytes, "."), entry.port
  end
  local in_table = handed.table_connector ~= nil and served_by(handed.table_connector, "table", handed.lost) or nil
  local public = handed.public_connector ~= nil and served_by(handed.public_connector, "public", handed.lost) or nil
  return function(address: string, port: integer, timeout_ns: integer): Net.Conn | nil, string
    local bytes = Address.parse(address)
    if bytes == nil then return nil, "relay: " .. address .. " is not a numeric address" end
    if in_table ~= nil then
      local row = table.concat(bytes, ".")
      for i = 1, #rows do
        if rows[i] == row and (ports[i] == 0 or ports[i] == port) then
          return in_table(i, port, timeout_ns)
        end
      end
    end
    if public ~= nil then return public(address, port, timeout_ns) end
    return nil, "relay: " .. target(address, port) .. " is in no table of the connectors the relay was handed"
  end
end

--- The upstream a caller's `https_proxy` and `no_proxy` name, or nil for
--- none, as the relay's starter reads them ([`relay_config.upstream`]).
---
---     local upstream = assert(Relay.upstream({ https_proxy = "http://proxy.example:3128" }))
--- @param env {string:string} The caller's environment
--- @return Relay.Upstream|nil The upstream, nil for none
--- @return string Why the variable cannot be used, "" otherwise
function Relay.upstream(env: {string:string}): Relay.Upstream | nil, string
  return Config.upstream(env)
end

--- Whether `no_proxy` says to reach `host` on `port` directly.
local function bypasses(no_proxy: {string}, host: string, port: integer): boolean
  for _, listed in ipairs(no_proxy) do
    local entry = lower(listed)
    if entry == "*" then return true end
    local name, at = entry:match("^(.-):(%d+)$")
    if name ~= nil and not entry:find("::", 1, true) and not entry:find("^%[") then
      if tonumber(at) ~= port then goto next end
      entry = name
    end
    entry = entry:gsub("^%*?%.", "")
    if host == entry or (host:sub(-#entry - 1) == "." .. entry) then return true end
    ::next::
  end
  return false
end

--- The state of one running relay.
local record Running
  spec: Relay.Spec
  names: {NameGrant}
  own: {{integer}}
  timeouts: Relay.Timeouts
  limits: Relay.Limits
  tls_ports: {integer: boolean}
  log: function(line: string)
  --- The SHA-256 of the spec's token, or nil where it has none.
  token_digest: string
  stopping: boolean
  --- Connections that have not authenticated yet, where there is a token.
  pending: integer
  open: integer
  accepted: integer
  refused: integer
  next_id: integer
  --- The connections open, by id, to be closed at stop.
  live: {integer: {Net.Conn}}
  tasks: {integer: Poll.Task}
  acceptors: {Poll.Task}
  --- The lookups in progress, each a task of its own that `stop` cancels,
  --- so a connection waiting for a name does not hold the stop back.
  lookups: {Poll.Task: boolean}
  --- Whether `spec.lost` has been told the name servers' connector ended.
  told_lost: boolean
end

--- One connection's request and what has been decided of it.
local record Request
  id: integer
  --- "connect" or "socks5".
  protocol: string
  client: Net.Conn
  host: string
  kind: Wire.Kind
  port: integer
  --- The bytes the program sent after its request.
  leftover: string
end

--- Why a connection is refused, and what the program is told.
local record Refusal
  --- The reason, which names the remedy.
  reason: string
  --- The HTTP status of the CONNECT reply.
  http: integer
  --- The SOCKS5 reply code.
  socks: Wire.SocksReply
end

local function refusal(reason: string, http: integer, socks: Wire.SocksReply): Refusal
  return { reason = reason, http = http, socks = socks }
end

--- Whether `given` is the token, compared in constant time: both are
--- hashed to a fixed length, and every byte of the digests is compared.
local function is_token(run: Running, given: string): boolean
  local have = Hash.sha256(given)
  local want = run.token_digest
  local diff = #have ~ #want
  for i = 1, #want do
    diff = diff | (have:byte(i) ~ want:byte(i))
  end
  return diff == 0
end

--- The password of a Basic `Proxy-Authorization` value, or nil and why not
--- (a reason that holds none of the value).
local function basic_password(authorization: string | nil): string | nil, string
  if authorization == nil then return nil, "no Proxy-Authorization" end
  local scheme, rest = authorization:match("^(%S+)%s+(.-)%s*$")
  if scheme == nil or lower(scheme) ~= "basic" then
    return nil, "Proxy-Authorization is not Basic"
  end
  local decoded, _ = Codec.unbase64(rest)
  if decoded == nil then return nil, "Proxy-Authorization is not base64" end
  local password = decoded:match("^[^:]*:(.*)$")
  if password == nil then return nil, "Proxy-Authorization is not user:password" end
  return password, ""
end

--- How a failure of connecting is told to the program.
local function connect_failure(address: string, why: string): Refusal
  local text = ("could not connect to %s: %s"):format(address, why)
  local lowered = lower(why)
  if why == Poll.TIMEOUT or lowered:find("timed out", 1, true) then
    return refusal(text, 504, "ttl_expired")
  elseif lowered:find("refused", 1, true) then
    return refusal(text, 502, "refused")
  elseif lowered:find("unreachable", 1, true) then
    return refusal(text, 502, "network_unreachable")
  end
  return refusal(text, 502, "host_unreachable")
end

--- `conn`'s read within `deadline`: the bytes, or nil and why ("" at the end).
local function read_before(conn: Net.Conn, deadline: integer, most: integer): string | nil, string
  local left = deadline - Clock.monotonic_ns()
  if left <= 0 then return nil, Poll.TIMEOUT end
  conn:set_timeout(left)
  return conn:read(most)
end

--- Sends `text` to `conn`, waiting at most `ns`.
local function send(conn: Net.Conn, text: string, ns: integer): boolean
  conn:set_timeout(ns)
  local ok, _ = conn:write(text)
  return ok
end

--- Ends a refused connection after its reply: the program's side is
--- shut and what it still sends read for a moment, so that the reply
--- is not lost to a reset that unread bytes make.
local function close_refused(conn: Net.Conn)
  local _, _ = conn:shutdown("write")
  conn:set_timeout(Clock.ms(200))
  for _ = 1, 2 do
    local data, _ = conn:read(CHUNK)
    if data == nil then break end
  end
  local _, _ = conn:close()
end

--- The first wait of a connection, from its first read: with a token, the
--- head or greeting and its credential are one wait, the auth timeout's.
local function first_wait(run: Running): integer
  return run.token_digest ~= nil and run.timeouts.auth or run.timeouts.head
end

--- The request of a CONNECT connection, or a refusal to answer it with.
--- `first` is what was read of it already, within the wait that ends at
--- `deadline`.
local function read_connect(run: Running, conn: Net.Conn, first: string, deadline: integer): Wire.Connect, string
  local reader = Wire.connect_reader()
  local limit = first_wait(run)
  local cap = run.limits.header_bytes
  local all = ""
  local pending = first
  while true do
    local data, why: string, string
    if pending ~= "" then
      data, why, pending = pending, "", ""
    else
      data, why = read_before(conn, deadline, CHUNK)
    end
    if data == nil then
      if why == Poll.TIMEOUT then
        return { status = "refused", consumed = 0, http_status = 408,
          reason = ("%s not received within %s"):format(run.token_digest ~= nil and "request and credential" or "request",
            span(limit)) }, ""
      end
      return { status = "refused", consumed = 0, http_status = 0, reason = "the program closed before its request was whole" }, ""
    end
    all = all .. data
    local answer = reader:feed(data)
    if answer.status == "refused" then return answer, "" end
    if answer.status == "done" then
      if answer.consumed > cap then
        return { status = "refused", consumed = 0, http_status = 431,
          reason = ("request head longer than %s (the relay's cap)"):format(String.counted(cap, "byte")) }, ""
      end
      return answer, all:sub(answer.consumed + 1)
    end
    if #all >= cap then
      return { status = "refused", consumed = 0, http_status = 431,
        reason = ("request head longer than %s (the relay's cap)"):format(String.counted(cap, "byte")) }, ""
    end
  end
end

--- A SOCKS5 request: what it asked, and the bytes after it; or why not.
local record Socks
  status: Wire.Status
  reason: string
  reply: Wire.SocksReply
  host: string
  kind: Wire.Kind
  port: integer
  leftover: string
  --- Whether the program should be answered at all.
  answer: boolean
end

--- The request of a SOCKS5 connection, or a refusal. `first` is what was
--- read of it already, within the wait that ends at `deadline`; with a
--- token, the request's own wait, the head timeout's, starts once the
--- credential has passed.
local function read_socks(run: Running, conn: Net.Conn, authenticated: function(), first: string,
                          deadline: integer): Socks
  local tokened = run.token_digest ~= nil
  local limit = first_wait(run)
  local authing = tokened
  local cap = run.limits.header_bytes
  local function early(why: string, reply: Wire.SocksReply, answer: boolean): Socks
    return { status = "refused", reason = why, reply = reply, answer = answer, host = "", kind = "name", port = 0, leftover = "" }
  end
  local function timed_out(): Socks
    return early(("%s not received within %s"):format(
      authing and "greeting and credential" or "request", span(limit)),
      "ttl_expired", false)
  end
  local greeting = Wire.socks_greeting_reader(run.token_digest ~= nil)
  local all = ""
  local greeted: Wire.SocksGreeting
  local pending = first
  while true do
    local data, why: string, string
    if pending ~= "" then
      data, why, pending = pending, "", ""
    else
      data, why = read_before(conn, deadline, CHUNK)
    end
    if data == nil then
      if why == Poll.TIMEOUT then return timed_out() end
      return early("the program closed before its request was whole", "failure", false)
    end
    all = all .. data
    greeted = greeting:feed(data)
    if greeted.status ~= "more" then break end
    if #all >= cap then return early("greeting longer than the relay's cap", "failure", false) end
  end
  if greeted.status == "refused" then
    if greeted.method == 255 then
      local _ = send(conn, Wire.socks_method_reply(255), run.timeouts.head)
    end
    return early(greeted.reason, "failure", false)
  end
  -- Whatever the greeting reader chose, a relay with a token serves nothing
  -- but a client that has sent it.
  if tokened and greeted.method ~= 2 then
    local _ = send(conn, Wire.socks_method_reply(255), run.timeouts.head)
    return early("not authenticated: the relay takes only username/password authentication", "failure", false)
  end
  if not send(conn, Wire.socks_method_reply(greeted.method), run.timeouts.head) then
    return early("the program closed before its request was whole", "failure", false)
  end
  local rest = all:sub(greeted.consumed + 1)
  if tokened then
    local auth = Wire.socks_auth_reader()
    local given: Wire.SocksAuth
    local fed = ""
    while true do
      local data: string
      if rest ~= "" then
        data, rest = rest, ""
      else
        local got, why = read_before(conn, deadline, CHUNK)
        if got == nil then
          if why == Poll.TIMEOUT then return timed_out() end
          return early("the program closed before its request was whole", "failure", false)
        end
        data = got
      end
      fed = fed .. data
      given = auth:feed(data)
      if given.status ~= "more" then
        -- What follows the message is the request's.
        rest = fed:sub(given.consumed + 1)
        break
      end
    end
    if given.status == "refused" then
      local _ = send(conn, Wire.socks_auth_reply(false), run.timeouts.head)
      return early("not authenticated: " .. given.reason, "failure", false)
    end
    if not is_token(run, given.password) then
      local _ = send(conn, Wire.socks_auth_reply(false), run.timeouts.head)
      return early("not authenticated: the password is not the sandbox's token", "failure", false)
    end
    if not send(conn, Wire.socks_auth_reply(true), run.timeouts.head) then
      return early("the program closed before its request was whole", "failure", false)
    end
    authenticated()
    limit = run.timeouts.head
    authing = false
    deadline = Clock.monotonic_ns() + limit
  end
  local request = Wire.socks_request_reader()
  local held = ""
  while true do
    local data: string
    if rest ~= "" then
      data, rest = rest, ""
    else
      local got, why = read_before(conn, deadline, CHUNK)
      if got == nil then
        if why == Poll.TIMEOUT then return timed_out() end
        return early("the program closed before its request was whole", "failure", false)
      end
      data = got
    end
    held = held .. data
    local answer = request:feed(data)
    if answer.status == "refused" then return early(answer.reason, answer.reply, true) end
    if answer.status == "done" then
      return { status = "done", reason = "", reply = "succeeded", host = answer.host, kind = answer.kind,
        port = answer.port, leftover = held:sub(answer.consumed + 1), answer = true }
    end
    if #held >= cap then return early("request longer than the relay's cap", "failure", true) end
  end
end

--- The addresses chosen, in the order to try them, or the refusal that
--- says why none was.
local record Found
  addresses: {string}
  refused: Refusal
end

--- Resolves `name` once, and every address the checks allow, in order.
local function address_of(run: Running, name: string, kind: Wire.Kind, port: integer, trusted?: boolean): Found
  local shown = target(name, port)
  if kind ~= "name" then
    return { addresses = { name } }
  end
  local answers: {Address.Answer} = {}
  local resolved_once = trusted and run.spec.upstream.addresses or nil
  if resolved_once ~= nil then
    -- The upstream's addresses, which its starter resolved: no lookup.
    for i, address in ipairs(resolved_once) do
      answers[i] = { address = address, family = address:find(":", 1, true) and "ipv6" or "ipv4" }
    end
  else
    -- A numeric host, as an upstream proxy's may be, answers itself.
    if run.spec.unresolved ~= nil and Address.parse(name) == nil then
      return { addresses = {}, refused = refusal(("could not resolve %s: %s"):format(name, run.spec.unresolved), 502,
        "host_unreachable") }
    end
    local opts: Net.ResolveOptions = { timeout_ns = run.timeouts.resolve }
    if run.spec.resolve ~= nil then
      opts.servers, opts.hosts_file = run.spec.resolve.servers, run.spec.resolve.hosts_file
      opts.connector = run.spec.resolve.connector
    end
    -- A connection between `stop` setting this and its cancellation must
    -- not start a lookup `stop` has already passed over.
    if run.stopping then
      return { addresses = {}, refused = refusal(("could not resolve %s: the relay is stopping"):format(name), 502,
        "host_unreachable") }
    end
    local found: {Net.Resolved} | nil
    local why: string
    local lookup = Poll.spawn(function()
      found, why = Net.resolve(name, opts)
    end)
    run.lookups[lookup] = true
    local joined, joined_why = lookup:join()
    run.lookups[lookup] = nil
    if not joined then
      -- This connection's task was cancelled, or the lookup was at stop.
      lookup:cancel()
      found, why = nil, joined_why
    elseif found == nil and why == nil then
      -- Ended without an answer, which a cancel or a stop does not do.
      why = "the lookup ended without an answer"
    end
    if found == nil and opts.connector ~= nil and opts.connector:ended() and run.spec.lost ~= nil and
        not run.told_lost then
      run.told_lost = true
      run.spec.lost("relay: the name servers' connector has ended")
    end
    if found == nil then
      if why == Poll.TIMEOUT then
        return { addresses = {}, refused = refusal(("resolving %s timed out after %s"):format(name,
          span(run.timeouts.resolve)), 504, "ttl_expired") }
      end
      return { addresses = {}, refused = refusal(("could not resolve %s: %s"):format(name, why), 502, "host_unreachable") }
    end
    for i, resolved in ipairs(found) do
      answers[i] = { address = resolved.address, family = resolved.family }
    end
  end
  local grants = run.spec.grants
  if trusted then
    -- The upstream's address is the one the caller's own https_proxy names: the
    -- relay may connect to it (a proxy on loopback or a private network is the
    -- usual one) without the program being granted it, which would let the
    -- program ask the proxy for any host. Every answer of its name is trusted
    -- so, and tried in order; the decision line names the one connected to;
    -- the metadata and unspecified classes are not excepted,
    -- since the caller, not the sandbox, chose this name.
    grants = {}
    for i, grant in ipairs(run.spec.grants) do grants[i] = grant end
    for _, answer in ipairs(answers) do grants[#grants + 1] = target(answer.address, port) end
  end
  local chosen, trouble = Address.permitted(answers, port, grants, run.own)
  if chosen == nil then
    return { addresses = {}, refused = refusal(("%s: %s"):format(shown, trouble), 403, "not_allowed") }
  end
  local addresses: {string} = {}
  for i, answer in ipairs(chosen) do addresses[i] = answer.address end
  return { addresses = addresses }
end

--- A connection made, with the address it was made to, or the refusal
--- that says why none could be.
local record Connected
  conn: Net.Conn
  address: string
  refused: Refusal
end

--- Connects to the first of `addresses` on `port` that answers, trying
--- them in order within `deadline`: each attempt is given an equal share of
--- the time left, the first of the connect timeout, so one that hangs
--- leaves the rest theirs. `label` names the destination in a failure
--- ("the upstream proxy " for one that is, else "") and `name` its host.
--- When all fail, one refusal names every address and why, with the
--- status of the last.
local function connect_any(run: Running, addresses: {string}, port: integer, deadline: integer,
                           label: string, name: string): Connected
  local failures: {string} = {}
  local last: Refusal
  for i, address in ipairs(addresses) do
    local left = i == 1 and run.timeouts.connect or deadline - Clock.monotonic_ns()
    if left <= 0 then
      failures[#failures + 1] = ("%s: %s"):format(target(address, port), "no time left")
      last = connect_failure(label .. target(address, port), Poll.TIMEOUT)
      break
    end
    local conn, trouble = run.spec.connector(address, port, math.max(1, left // (#addresses - i + 1)))
    if conn ~= nil then return { conn = conn, address = address } end
    failures[#failures + 1] = ("%s: %s"):format(target(address, port), trouble)
    last = connect_failure(label .. target(address, port), trouble)
  end
  if #addresses == 1 then return { refused = last } end
  return { refused = refusal(("could not connect to %s%s: none of its addresses answered (%s)"):format(label,
    target(name, port), table.concat(failures, "; ")), last.http, last.socks) }
end

--- The part of a CONNECT through an upstream the relay reads: its status
--- line and head, cut to `most` bytes. Nil and why when it is no
--- success; else the bytes after the head.
local function upstream_connect(conn: Net.Conn, request: string, deadline: integer, ns: integer): string | nil, string
  if not send(conn, request, ns) then
    return nil, "the upstream proxy closed before it was asked"
  end
  local head = ""
  while true do
    local data, why = read_before(conn, deadline, CHUNK)
    if data == nil then
      if why == Poll.TIMEOUT then return nil, "the upstream proxy did not answer in time" end
      return nil, "the upstream proxy closed without answering"
    end
    head = head .. data
    local ends = head:find("\r\n\r\n", 1, true)
    if ends ~= nil then
      local code = head:match("^HTTP/1%.[01] (%d%d%d)")
      if code == nil then return nil, "the upstream proxy did not answer with an HTTP status" end
      if code:sub(1, 1) ~= "2" then
        local line = (head:match("^[^\r\n]*") or ""):gsub("[^\32-\126]", "?"):sub(1, 80)
        local hint = ""
        if code == "407" then hint = " (set https_proxy with user:password@ for it)" end
        return nil, ("the upstream proxy refused the CONNECT: %s%s"):format(line, hint)
      end
      return head:sub(ends + 4), ""
    end
    if #head > 16384 then return nil, "the upstream proxy's answer is longer than 16384 bytes" end
  end
end

--- What the relay does with the first bytes the program sends.
local record Sniff
  reader: Wire.HelloReader
  --- The requested host.
  host: string
  kind: Wire.Kind
  --- Whether a hello with no name is refused.
  strict: boolean
  --- The bytes held until the hello is decided.
  held: string
  --- When a hello begun must be whole, from the program's first byte; 0
  --- until it has sent one.
  deadline: integer
end

--- Whether the hello `seen` is allowed to the requested host, and why not.
local function judged(sniff: Sniff, seen: Wire.Hello, requested: string): boolean, string
  if seen.status == "not_tls" then return true, "" end
  if seen.status == "malformed" then
    return false, "refused a malformed TLS ClientHello: " .. seen.reason
  end
  if seen.status == "encrypted_sni" then
    return false, ("refused a ClientHello with an encrypted server name (ECH or ESNI), which the relay cannot match " ..
      "to %s: turn Encrypted Client Hello off in the client"):format(requested)
  end
  if seen.status == "no_sni" then
    if sniff.strict and sniff.kind == "name" then
      return false, ("refused a ClientHello with no server name on a TLS port: the relay matches it to %s, so " ..
        "the client must send SNI"):format(requested)
    end
    return true, ""
  end
  if sniff.kind ~= "name" then
    return false, ("refused a ClientHello naming %s for a connection to the address %s: " ..
      "connect by name and grant --connect %s"):format(seen.name, requested, seen.name .. ":<port>")
  end
  if seen.name ~= sniff.host then
    return false, ("refused a ClientHello naming %s for a connection to %s: connect to %s by name, " ..
      "and grant --connect %s:<port>"):format(seen.name, requested, seen.name, seen.name)
  end
  return true, ""
end

--- Carries bytes between `client` and `far` until the connection ends;
--- `first` is what `far` sent already, and `sniff` the check on what
--- the client sends first. Answers why it ended.
local function tunnel(run: Running, req: Request, client: Net.Conn, far: Net.Conn, first: string,
                      sniff: Sniff | nil): string
  local idle = run.timeouts.idle
  local ended = ""
  local stamp = Clock.monotonic_ns()
  local function end_with(why: string)
    if ended == "" then
      ended = why
      local _, _ = client:close()
      local _, _ = far:close()
    end
  end
  --- Pumps `from` to `to`; `check` is the sniff, for the client's side.
  local function pump(from: Net.Conn, to: Net.Conn, pending: string, check: Sniff | nil, name: string)
    local function pass(data: string): boolean
      stamp = Clock.monotonic_ns()
      if not send(to, data, idle) then
        end_with(name .. ": the other side stopped taking bytes")
        return false
      end
      return true
    end
    local function take(data: string): boolean
      if check == nil then return pass(data) end
      -- The hello's time starts at the program's first byte: a client that
      -- waits for a server that speaks first is not on the clock.
      if check.deadline == 0 then check.deadline = Clock.monotonic_ns() + run.timeouts.head end
      check.held = check.held .. data
      local seen = check.reader:feed(data)
      if seen.status == "more" then return true end
      local ok, why = judged(check, seen, target(req.host, req.port))
      if not ok then
        run.log(("#%d %s %s: %s"):format(req.id, req.protocol, target(req.host, req.port), why))
        run.refused = run.refused + 1
        local _ = send(client, TLS_ALERT, Clock.seconds(1))
        end_with("refused by the hello check")
        return false
      end
      local held = check.held
      check = nil
      return pass(held)
    end
    if pending ~= "" and not take(pending) then return end
    while ended == "" do
      local left = idle - (Clock.monotonic_ns() - stamp)
      local hello_late = false
      if check ~= nil and check.deadline ~= 0 then
        local remaining = check.deadline - Clock.monotonic_ns()
        if remaining < left then left, hello_late = remaining, true end
      end
      if left <= 0 then
        if hello_late then
          run.log(("#%d %s %s: refused a ClientHello not complete within %s"):format(req.id, req.protocol,
            target(req.host, req.port), span(run.timeouts.head)))
          run.refused = run.refused + 1
          local _ = send(client, TLS_ALERT, Clock.seconds(1))
          end_with("hello timed out")
        else
          end_with(("idle for %s"):format(span(idle)))
        end
        return
      end
      from:set_timeout(left)
      local data, why = from:read(CHUNK)
      if ended ~= "" then return end
      if data == nil then
        if why == "" then
          -- The side has ended what it sends: the other hears it as a half-close.
          local _, _ = to:shutdown("write")
          return
        elseif why ~= Poll.TIMEOUT then
          end_with(name .. ": " .. why)
          return
        end
      elseif not take(data) then
        return
      end
    end
  end
  local down = Poll.spawn(function() pump(far, client, first, nil, "from the far side") end)
  pump(client, far, req.leftover, sniff, "from the program")
  local _, _ = down:join()
  if ended == "" then
    ended = "both sides ended"
  elseif not ended:find("hello", 1, true) then
    -- A refused hello has its own line; any other early end gets this one.
    run.log(("#%d %s %s: closed: %s"):format(req.id, req.protocol, target(req.host, req.port), ended))
  end
  local _, _ = client:close()
  local _, _ = far:close()
  return ended
end

--- Why a connection that arrives now is refused outright, or "".
local function over_cap(run: Running): string
  if run.accepted > run.limits.total then
    return ("connection budget spent: this sandbox's relay serves at most %s"):format(String.counted(run.limits.total, "connection"))
  end
  if run.open > run.limits.connections then
    return ("too many open connections: at most %d at once"):format(run.limits.connections)
  end
  return ""
end

--- Where one connection stands in the relay's counts.
local record Slot
  --- Whether it is in the count of connections not yet authenticated.
  pre_auth: boolean
  --- Whether it is in the counts of open and accepted connections.
  admitted: boolean
end

--- Moves the connection of `slot` into the counts of open and accepted
--- connections, from the pre-auth count where it was; answers why it is
--- refused outright, or "".
local function admit(run: Running, slot: Slot): string
  if slot.pre_auth then
    run.pending = run.pending - 1
    slot.pre_auth = false
  end
  slot.admitted = true
  run.open = run.open + 1
  run.accepted = run.accepted + 1
  return over_cap(run)
end

--- Serves one accepted connection. `over` is why it is refused outright, or
--- "" when it is counted already; nil where it is counted once it has
--- authenticated.
local function serve_connection(run: Running, protocol: string, client: Net.Conn, id: integer, slot: Slot,
                                over: string | nil)
  local req: Request = { id = id, protocol = protocol, client = client, host = "", kind = "name", port = 0, leftover = "" }
  local function reject(why: Refusal, replied: boolean)
    run.refused = run.refused + 1
    local at = req.host ~= "" and (" " .. target(req.host, req.port)) or ""
    run.log(("#%d %s%s: refused: %s"):format(id, protocol, at, why.reason))
    if replied then
      if protocol == "connect" then
        local phrase = why.http == 407 and "Proxy Authentication Required" or why.reason
        local _ = send(client, Wire.connect_refusal(why.http, phrase), run.timeouts.head)
      else
        local _ = send(client, Wire.socks_reply(why.socks), run.timeouts.head)
      end
    end
    close_refused(client)
  end
  local function authenticated()
    if over == nil then over = admit(run, slot) end
  end
  local reading_until = Clock.monotonic_ns() + first_wait(run)
  local sniffed = ""
  if protocol == "mixed" then
    local data, why = read_before(client, reading_until, 1)
    if data == nil or data == "" then
      run.refused = run.refused + 1
      run.log(("#%d mixed: refused: %s"):format(id, why == Poll.TIMEOUT and
          ("nothing received within %s"):format(span(first_wait(run))) or
          "the program closed before its request was whole"))
      close_refused(client)
      return
    end
    sniffed = data
    protocol = sniffed:byte(1) == 5 and "socks5" or "connect"
    req.protocol = protocol
  end
  if protocol == "connect" then
    local head, rest = read_connect(run, client, sniffed, reading_until)
    if head.status == "refused" then
      reject(refusal(head.reason, head.http_status == 0 and 400 or head.http_status, "failure"), head.http_status ~= 0)
      return
    end
    if run.token_digest ~= nil then
      local password, why = basic_password(head.authorization)
      if password == nil or not is_token(run, password) then
        reject(refusal("not authenticated: " .. (why ~= "" and why or "the password is not the sandbox's token"),
          407, "failure"), true)
        return
      end
      authenticated()
    end
    req.host, req.kind, req.port, req.leftover = head.host, head.kind, head.port, rest
  else
    local asked = read_socks(run, client, authenticated, sniffed, reading_until)
    if asked.status == "refused" then
      reject(refusal(asked.reason, 400, asked.reply), asked.answer)
      return
    end
    req.host, req.kind, req.port, req.leftover = asked.host, asked.kind, asked.port, asked.leftover
  end
  local shown = target(req.host, req.port)
  if over == nil then
    -- A relay with a token has admitted nothing that did not authenticate.
    reject(refusal("not authenticated", 407, "failure"), true)
    return
  end
  if over ~= "" then
    reject(refusal(over, 503, "failure"), true)
    return
  end
  -- Step 2: the grants, before anything is resolved.
  local through = run.spec.upstream
  if through ~= nil and (bypasses(through.no_proxy, req.host, req.port)) then through = nil end
  if req.kind == "name" then
    if not name_granted(run.names, req.host, req.port) then
      reject(refusal("not granted: --connect " .. shown, 403, "not_allowed"), true)
      return
    end
  elseif not Address.granted(req.host, req.port, run.spec.grants) then
    reject(refusal(("not granted: --connect %s (a request by IP address needs that address granted literally)"):
        format(shown), 403, "not_allowed"), true)
    return
  end
  if through ~= nil and req.kind == "name" and (req.host == "localhost" or req.host:sub(-10) == ".localhost") then
    reject(refusal(("%s is not relayed through the upstream proxy: it would name the proxy's own host, not the " ..
      "sandbox's"):format(shown), 403, "not_allowed"), true)
    return
  end
  -- Steps 3 and 4.
  local far: Net.Conn
  local first = ""
  local how: string
  if through == nil then
    local found = address_of(run, req.host, req.kind, req.port)
    if found.refused ~= nil then
      reject(found.refused, true)
      return
    end
    local made = connect_any(run, found.addresses, req.port, Clock.monotonic_ns() + run.timeouts.connect, "",
      req.host)
    if made.refused ~= nil then
      reject(made.refused, true)
      return
    end
    local conn, address = made.conn, made.address
    run.live[id] = { client, conn }
    far, how = conn, "via " .. target(address, req.port)
  else
    local up = through
    local found = address_of(run, up.host, "name", up.port, true)
    if found.refused ~= nil then
      reject(found.refused, true)
      return
    end
    local deadline = Clock.monotonic_ns() + run.timeouts.connect
    local made = connect_any(run, found.addresses, up.port, deadline, "the upstream proxy ", up.host)
    if made.refused ~= nil then
      reject(made.refused, true)
      return
    end
    local conn, address = made.conn, made.address
    run.live[id] = { client, conn }
    local ask = ("CONNECT %s HTTP/1.1\r\nHost: %s\r\n%s\r\n"):format(shown, shown,
      up.authorization ~= nil and ("Proxy-Authorization: " .. up.authorization .. "\r\n") or "")
    local rest, bad = upstream_connect(conn, ask, deadline, run.timeouts.connect)
    if rest == nil then
      local _, _ = conn:close()
      reject(refusal(bad, 502, "failure"), true)
      return
    end
    far, first = conn, rest
    how = ("through the upstream proxy %s, which resolves %s"):format(target(address, up.port), req.host)
  end
  -- Step 5. A connection made after `stop` is closed, not served.
  if run.stopping then
    local _, _ = far:close()
    return
  end
  local ok = send(client, protocol == "connect" and Wire.connect_ok() or Wire.socks_reply("succeeded"), run.timeouts.head)
  if not ok then
    run.log(("#%d %s %s: the program went away before the reply"):format(id, protocol, shown))
    local _, _ = far:close()
    local _, _ = client:close()
    return
  end
  run.log(("#%d %s %s: allowed %s"):format(id, protocol, shown, how))
  local sniff: Sniff = {
    reader = Wire.hello_reader(), host = req.host, kind = req.kind, strict = run.tls_ports[req.port] == true,
    held = "", deadline = 0,
  }
  tunnel(run, req, client, far, first, sniff)
end

--- Takes the connections of `listener`, each in a task of its own.
local function accept_loop(run: Running, listener: Net.Listener, protocol: string)
  while not run.stopping do
    if run.open >= run.limits.connections + REFUSING or
        (run.token_digest ~= nil and run.pending >= run.limits.pre_auth) then
      local ok, _ = Poll.delay(Clock.ms(20))
      if not ok then return end
    else
      local conn, why = listener:accept()
      if conn == nil then
        if run.stopping or why == Poll.CANCELLED then return end
        run.log("accept failed: " .. why)
        local ok, _ = Poll.delay(Clock.ms(50))
        if not ok then return end
      else
        run.next_id = run.next_id + 1
        local id = run.next_id
        local slot: Slot = { pre_auth = false, admitted = false }
        local over: string | nil
        if run.token_digest ~= nil then
          slot.pre_auth = true
          run.pending = run.pending + 1
        else
          over = admit(run, slot)
        end
        run.live[id] = { conn }
        run.tasks[id] = Poll.spawn(function()
          local ok, trouble = pcall(function(): boolean
            serve_connection(run, protocol, conn, id, slot, over)
            return true
          end)
          if not ok then
            run.log(("#%d %s: internal error: %s"):format(id, protocol, tostring(trouble)))
          end
          local _, _ = conn:close()
          local held = run.live[id]
          if held ~= nil then
            for _, c in ipairs(held) do local _, _ = c:close() end
          end
          run.live[id] = nil
          run.tasks[id] = nil
          if slot.pre_auth then
            run.pending = run.pending - 1
          elseif slot.admitted then
            run.open = run.open - 1
          end
        end)
      end
    end
  end
end

--- Raises, naming the field, where `up` is no usable upstream.
local function checked_upstream(up: Relay.Upstream)
  if type(up) ~= "table" then error("relay: spec.upstream must be a table", 3) end
  if type(up.host) ~= "string" or up.host == "" or up.host:find("[%c%s]") then
    error("relay: spec.upstream.host must be a host name or address", 3)
  end
  if number_of(tostring(up.port)) == nil or math.type(up.port) ~= "integer" then
    error("relay: spec.upstream.port must be a port from 1 to 65535", 3)
  end
  if up.authorization ~= nil and (type(up.authorization) ~= "string" or up.authorization:find("[%c]")) then
    error("relay: spec.upstream.authorization must be a header value with no control bytes", 3)
  end
  if type(up.no_proxy) ~= "table" then
    error("relay: spec.upstream.no_proxy must be a list of strings", 3)
  end
  for _, entry in ipairs(up.no_proxy) do
    if type(entry) ~= "string" then
      error("relay: spec.upstream.no_proxy must be a list of strings", 3)
    end
  end
  if up.addresses ~= nil then
    if type(up.addresses) ~= "table" or #up.addresses == 0 then
      error("relay: spec.upstream.addresses must be a list of one numeric address or more", 3)
    end
    for _, address in ipairs(up.addresses) do
      if Address.parse(address) == nil then
        error("relay: spec.upstream.addresses must hold numeric addresses", 3)
      end
    end
  end
end

--- `given`, or `default` where it is nil; raises where it is no integer from 1.
local function chosen(given: integer | nil, default: integer, name: string): integer
  if given == nil then return default end
  if math.type(given) ~= "integer" or given < 1 then
    error(("relay: %s must be an integer from 1"):format(name), 3)
  end
  return given
end

--- Starts serving `spec`'s listeners in the calling task's run, and
--- returns once they are taken. [`Child.start`] runs it for a policy's
--- `connect`, in a process of its own ([`cosmic.relay.main`]) whose
--- listeners the sandbox bound in the program's network. Raises where the spec is no spec: no
--- listener or `connector`, a grant that is no string, a timeout or limit
--- that is no positive integer, an own address that is no address.
--- @param spec Relay.Spec What to serve
--- @return Relay.Serving The running relay
function Relay.start(spec: Relay.Spec): Relay.Serving
  if type(spec) ~= "table" then error("relay: start takes a spec table", 2) end
  if spec.mixed ~= nil and type(spec.mixed) ~= "table" then
    error("relay: spec.mixed must be a list of listeners", 2)
  end
  if spec.http == nil and spec.socks == nil and #(spec.mixed or {}) == 0 then
    error("relay: spec needs an http, a socks or a mixed listener", 2)
  end
  if type(spec.connector) ~= "function" then
    error("relay: spec.connector must be a function", 2)
  end
  if type(spec.grants) ~= "table" then
    error("relay: spec.grants must be a list of host:port", 2)
  end
  for _, grant in ipairs(spec.grants) do
    if type(grant) ~= "string" then error("relay: spec.grants must hold strings", 2) end
  end
  local function table_or_nil(value: any, field: string)
    if value ~= nil and type(value) ~= "table" then
      error(("relay: spec.%s must be a table"):format(field), 3)
    end
  end
  table_or_nil(spec.timeouts, "timeouts")
  table_or_nil(spec.limits, "limits")
  table_or_nil(spec.resolve, "resolve")
  if spec.unresolved ~= nil and type(spec.unresolved) ~= "string" then
    error("relay: spec.unresolved must be a string", 2)
  end
  table_or_nil(spec.own_addresses, "own_addresses")
  table_or_nil(spec.tls_ports, "tls_ports")
  if spec.lost ~= nil and type(spec.lost) ~= "function" then
    error("relay: spec.lost must be a function", 2)
  end
  if spec.upstream ~= nil then checked_upstream(spec.upstream) end
  if not Poll.in_task() then error("relay: start runs in a task of Poll.run", 2) end
  if spec.token ~= nil and (type(spec.token) ~= "string" or #spec.token < 16 or #spec.token > 255 or
      spec.token:find("[%c\127]")) then
    error("relay: spec.token must be a string of 16 to 255 bytes with no control byte (draw 128 bits or more)", 2)
  end
  local given_timeouts: Relay.Timeouts = spec.timeouts or {}
  local given_limits: Relay.Limits = spec.limits or {}
  local timeouts: Relay.Timeouts = {
    resolve = chosen(given_timeouts.resolve, DEFAULT_TIMEOUTS.resolve, "timeouts.resolve"),
    connect = chosen(given_timeouts.connect, DEFAULT_TIMEOUTS.connect, "timeouts.connect"),
    idle = chosen(given_timeouts.idle, DEFAULT_TIMEOUTS.idle, "timeouts.idle"),
    head = chosen(given_timeouts.head, DEFAULT_TIMEOUTS.head, "timeouts.head"),
    auth = chosen(given_timeouts.auth, DEFAULT_TIMEOUTS.auth, "timeouts.auth"),
  }
  local limits: Relay.Limits = {
    connections = chosen(given_limits.connections, DEFAULT_LIMITS.connections, "limits.connections"),
    header_bytes = chosen(given_limits.header_bytes, DEFAULT_LIMITS.header_bytes, "limits.header_bytes"),
    total = chosen(given_limits.total, DEFAULT_LIMITS.total, "limits.total"),
    pre_auth = chosen(given_limits.pre_auth, DEFAULT_LIMITS.pre_auth, "limits.pre_auth"),
  }
  local tls: {integer: boolean} = {}
  for _, port in ipairs(spec.tls_ports or DEFAULT_TLS_PORTS) do
    if math.type(port) ~= "integer" or port < 1 or port > 65535 then
      error("relay: spec.tls_ports must hold ports from 1 to 65535", 2)
    end
    tls[port] = true
  end
  local logger = Log.new("relay")
  local names, notes = name_grants(spec.grants)
  local run: Running = {
    spec = spec, names = names, own = Address.own_addresses(spec.own_addresses or {}), timeouts = timeouts,
    limits = limits, tls_ports = tls, token_digest = spec.token ~= nil and Hash.sha256(spec.token) or nil,
    log = function(line: string)
      -- A line carries what the program chose (a refused version, a resolver's
      -- words), so it is cut to a length and its control bytes shown as "?".
      local clean = line:gsub("[%c\127-\255]", "?"):sub(1, MAX_LOG)
      if spec.log ~= nil then
        spec.log(clean)
      else
        local _, _ = logger:complain(clean)
      end
    end,
    stopping = false, told_lost = false, pending = 0, open = 0, accepted = 0, refused = 0, next_id = 0, live = {}, tasks = {}, acceptors = {}, lookups = {},
  }
  for _, note in ipairs(notes) do run.log(note) end
  if spec.unresolved ~= nil then
    run.log("no name is resolved, so only an address a grant names is reached: " .. spec.unresolved)
  end
  if spec.upstream ~= nil then
    local up = spec.upstream
    run.log(("upstream proxy %s: it resolves the names it is asked for, so the relay's address checks do " ..
      "not apply to what it reaches; names are still matched against the grants, and the proxy's own " ..
      "address is the one the caller's https_proxy names, so the relay connects to it without the program being granted it"):format(target(up.host, up.port)))
  end
  local function listen(listener: Net.Listener | nil, protocol: string)
    if listener ~= nil then
      run.acceptors[#run.acceptors + 1] = Poll.spawn(function()
        accept_loop(run, listener, protocol)
      end)
    end
  end
  listen(spec.http, "connect")
  listen(spec.socks, "socks5")
  for _, listener in ipairs(spec.mixed or {}) do listen(listener, "mixed") end
  local server: Relay.Serving = {
    stop = function(_: Relay.Serving)
      run.stopping = true
      for _, task in ipairs(run.acceptors) do task:cancel() end
      for lookup in pairs(run.lookups) do lookup:cancel() end
      for _, conns in pairs(run.live) do
        for _, conn in ipairs(conns) do local _, _ = conn:close() end
      end
    end,
    wait = function(_: Relay.Serving)
      for _, task in ipairs(run.acceptors) do local _, _ = task:join() end
      while true do
        local pending: Poll.Task | nil = nil
        for _, task in pairs(run.tasks) do
          pending = task
          break
        end
        if pending == nil then return end
        local _, _ = pending:join()
      end
    end,
    stats = function(_: Relay.Serving): Relay.Stats
      return { open = run.open, accepted = run.accepted, refused = run.refused }
    end,
  }
  return server
end

return Relay
