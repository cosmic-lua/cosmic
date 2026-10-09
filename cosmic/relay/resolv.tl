--- The name servers the system's resolver configuration names, as
--- numeric endpoints a connector's table takes: what [`Net.resolve`]
--- asks through a connector when its caller names none, and what the
--- relay's starter hands the relay a connector of; and the loop that
--- runs a lookup, which [`Net.resolve`] and the relay's starter share.
--- A member of cosmic.relay, reached outside it as [`cosmic.relay`]'s
--- `nameservers` and `lookup`.

local Clock = require("cosmic.clock")
local Poll = require("cosmic.poll")
local relay_address = require("cosmic.relay.address")

--- The raw socket module, cosmic.net's too: it arrives as the second
--- argument `require` passes this chunk's loader.
local type raw_socket = require("cosmic.internal.socket")
local type raw_process = require("cosmic.internal.process")

local extra: any = select(2, ...)
local raw: raw_socket
if type(extra) == "table" then
  raw = extra as raw_socket
else
  raw = require("cosmic.internal.socket")
end

local record resolv
  --- One address a name resolves to ([`Net.Resolved`]).
  type Resolved = raw_socket.Resolved

  --- What [`resolv.lookup`] is asked.
  record Request
    --- The most the lookup takes, nil for no limit beyond c-ares's own.
    timeout_ns: integer
    --- Name servers to ask in place of the system's, as c-ares writes them.
    servers: string
    --- A hosts file to read in place of the system's.
    hosts: string
    --- The name servers to ask through a connector, in place of `servers`:
    --- each connect to one is made by `connect`.
    through: {raw_socket.ThroughServer}
    --- Makes the connection to the entry `index` of the connector's table
    --- at `port` by `deadline` (a monotonic time in nanoseconds, nil for
    --- none): the connected socket, or nil and why ([`Poll.TIMEOUT`] where
    --- the connector's wait ran out, and [`Poll.CANCELLED`] where the task
    --- was cancelled). It waits in a task of a run through the run, so the
    --- others go on.
    connect: function(index: integer, port: integer, deadline: integer | nil): resolv.Connection | nil, string
  end

  --- A connected socket `connect` made, for the lookup to copy.
  record Connection
    --- The socket's descriptor.
    fd: integer
    --- Closes what holds the socket, once the lookup has taken its copy.
    release: function()
  end

  --- One numeric endpoint of a connector's table: a numeric `host` and a
  --- `port` ([`Net.Endpoint`]).
  type Endpoint = raw_process.ConnectorEndpoint
end

--- One entry of c-ares's server list: the numeric host and the TCP port,
--- or nil for an entry of none of the list's forms or a link-local server
--- written with its interface (a "%" and its name), which a connector's
--- endpoint cannot carry.
local function nameserver_of(entry: string): resolv.Endpoint | nil
  local host, port, rest: string, string, string
  local uri = entry:match("^dns://(.*)$")
  if uri ~= nil then
    local tcp = uri:match("[?&]tcpport=(%d+)")
    host, port, rest = uri:match("^%[([%x:%.]+)%]:(%d+)(.*)$")
    if host == nil then host, port, rest = uri:match("^([%d%.]+):(%d+)(.*)$") end
    if rest ~= nil and rest:sub(1, 1) == "?" then rest = "" end
    port = tcp or port
  else
    host, port, rest = entry:match("^%[([%x:%.]+)%]:(%d+)(.*)$")
    if host == nil then host, port, rest = entry:match("^([%d%.]+):(%d+)(.*)$") end
  end
  if host == nil or rest ~= "" then return nil end
  local number = math.tointeger(tonumber(port))
  if number == nil or number < 1 or number > 65535 or relay_address.parse(host) == nil then
    return nil
  end
  return { host = host, port = number }
end

--- The name servers the system's configuration names, as [`Net.resolve`]
--- reads it (resolv.conf; on macOS, the system's DNS configuration alone,
--- which `resolv_conf` does not replace), each a numeric endpoint at its TCP port, 53 for every server
--- resolv.conf names: the table of a connector for
--- [`Net.ResolveOptions.connector`] that reaches nothing else. With none
--- configured, the resolver's default, 127.0.0.1 at 53. A link-local
--- server written with its interface is left out, as no connector reaches
--- one; where every server is, the answer is nil and why.
--- Nil and why where they cannot be listed: the system's words where the
--- configuration cannot be read.
--- @param resolv_conf string|nil A resolv.conf to read in place of the system's
--- @return {Endpoint}|nil The servers
--- @return string Why there are none, "" otherwise
-- TODO: reach a link-local name server (fe80::1%eth0) through a connector
-- once a connector's endpoint carries an interface: it is left out today.
function resolv.nameservers(resolv_conf?: string): {resolv.Endpoint} | nil, string
  local listed, trouble = raw.nameservers(resolv_conf)
  if listed == nil then return nil, trouble end
  local servers: {resolv.Endpoint} = {}
  local skipped = ""
  for entry in listed:gmatch("[^,]+") do
    local server = nameserver_of(entry)
    if server ~= nil then
      servers[#servers + 1] = server
    elseif entry:find("%", 1, true) ~= nil then
      skipped = "net: the name server " .. entry .. " is scoped to an interface, which a connector cannot reach"
    else
      return nil, "net: the resolver lists a server as " .. entry
    end
  end
  if #servers == 0 then
    return nil, skipped ~= "" and skipped or "net: the resolver lists no name server"
  end
  return servers, ""
end

--- What a lookup that failed with `errno` says, `trouble` being the
--- core's words.
local function said(trouble: string, errno: integer): string
  if errno == raw.ETIMEDOUT then return Poll.TIMEOUT end
  if errno == raw.EINTR then return "interrupted" end
  return trouble
end

--- Runs the lookup of [`resolv.lookup`].
local function run(name: string, request: resolv.Request): {raw_socket.Resolved} | nil, string
  local timeout_ns = request.timeout_ns
  local deadline = timeout_ns ~= nil and Clock.monotonic_ns() + timeout_ns or nil
  local lookup, why, errno = raw.lookup(name, Poll.milliseconds(timeout_ns), request.servers, request.hosts,
    request.through)
  if lookup == nil then return nil, said(why, errno) end
  local _closing <close> = lookup
  local in_task = Poll.in_task()
  local ready_fds, ready_events: {integer}, {integer}
  while true do
    local done, fds, events, timer_ms, wants = lookup:step(ready_fds, ready_events)
    ready_fds, ready_events = nil, nil
    if done then
      local found, trouble, number = lookup:result()
      if found == nil then return nil, said(trouble, number) end
      return found, ""
    end
    for _, want in ipairs(wants) do
      local connection, trouble = request.connect(want.index, want.port, deadline)
      if connection ~= nil then
        local _, _ = lookup:supply(want.id, connection.fd, nil)
        connection.release()
      else
        if trouble == Poll.CANCELLED then return nil, trouble end
        local _, _ = lookup:supply(want.id, nil, trouble == Poll.TIMEOUT and raw.ETIMEDOUT or 0)
      end
    end
    if #wants == 0 then
      local left = deadline ~= nil and deadline - Clock.monotonic_ns() or nil
      if left ~= nil and left <= 0 then return nil, Poll.TIMEOUT end
      local wait_ns = left
      local timer_ns = timer_ms >= 0 and Clock.ms(timer_ms) or Clock.ms(100)
      if wait_ns == nil or timer_ns < wait_ns then wait_ns = timer_ns end
      if in_task then
        if #fds == 0 then
          local waited, because = Poll.delay(wait_ns)
          if not waited then return nil, because end
        else
          local answers, because = Poll.ready(fds, events, wait_ns)
          if answers ~= nil then
            ready_fds, ready_events = fds, answers
          elseif because == Poll.CANCELLED then
            return nil, because
          end
        end
      else
        local waited, because, number = lookup:wait(Poll.milliseconds(wait_ns))
        if not waited then return nil, said(because, number) end
      end
    end
  end
end

--- Looks `name` up as the system's resolver would, or through the
--- connector `request.connect` reaches, running the lookup c-ares keeps
--- ([`raw_socket.Lookup`]) to its end. In a task of [`Poll.run`] every
--- wait goes through the run, so only that task waits for the lookup, up
--- to `request.timeout_ns`; anywhere else it holds the thread, and a
--- signal an open [`Child.guard`] catches ends it. The lookup, and every
--- socket c-ares holds for it, is closed however the call ends, a task
--- cancelled in its wait included.
--- @param name string The host name or numeric address
--- @param request resolv.Request What to ask
--- @return {raw_socket.Resolved}|nil Every address, at least one
--- @return string What went wrong, when there are none: [`Poll.TIMEOUT`]
--- where the time ran out, "interrupted" where a guard caught a signal,
--- [`Poll.CANCELLED`] for a task cancelled, "name not found", "name has no
--- address", "name server failed", "Invalid argument", or the system's
--- words ("Connection refused" where every server refuses)
function resolv.lookup(name: string, request: resolv.Request): {raw_socket.Resolved} | nil, string
  return run(name, request)
end

return resolv
