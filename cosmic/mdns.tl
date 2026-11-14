--- Finding services on the local network: the client side of DNS-SD (RFC 6763) over multicast DNS (RFC 6762).
--- [`Mdns.browse`] asks which instances of a service type the network has and says where each is, and
--- [`Mdns.resolve`] asks for the addresses of a host of the `local` domain. Nothing here answers a question or
--- publishes a service.
---
---     local printers = assert(Mdns.browse("_ipp._tcp", { timeout_ns = Clock.seconds(2) }))
---     for _, printer in ipairs(printers) do
---       print(printer.name, printer.host, printer.port, printer.ipv4[1])
---     end
---
--- A search sends its question to the multicast group, again after `retry_ns` and then after gaps that double,
--- and listens until `timeout_ns` has passed. An answer may leave records out: an instance named with no SRV or
--- TXT record, or a host with no address. The search asks for what is missing a tenth of a second after it
--- learned the name, and then after the same doubling gaps, three times at most for one name.
---
--- There are two ways to listen ([`Mdns.Listen`]). "unicast", the default, asks from a port of its own and wants
--- each answer sent back to that port alone. It needs no membership of the group and no share of port 5353, so it
--- works beside the system's own responder and where a group cannot be joined, and it is right for a search made
--- once. "group" binds port 5353, shared, and joins the group, as a full member of the protocol does. It hears
--- the answers every responder sends to the group, those to another program's question among them, while
--- "unicast" hears the answers to its own questions alone. It is the way to try where a responder leaves a
--- question from another port than 5353 unanswered. It fails where a program holds port 5353 without sharing it.
---
--- A question leaves by every interface that is up, carries multicast, is no loopback and has an IPv4 address,
--- as [`Net.interfaces`] lists them, or by those `via` names. Where the interfaces cannot be listed, as in a
--- sandbox on Linux, or none is such a one, it leaves by the interface the system chooses. An interface that
--- refuses the question is passed over while another takes it. Questions go over IPv4 alone; a host's IPv6
--- addresses are those its answers over IPv4 give.
---
--- Every datagram is taken as hostile. One over 9000 bytes, one that is no DNS message, a query, and a response
--- with an error or to another kind of query are ignored. Listening by "unicast", so is a response that does
--- not repeat the question's id, which is drawn anew for each search. Of a response only the records of the internet class about a name the search
--- asked about are read: a pointer at the service asked for whose target is one label before that service's
--- name, the SRV and TXT records of such an instance, and the addresses of a host one of its SRV records
--- names. A record whose time to live is 0 says the record is going away, and is ignored. Of two SRV or two TXT
--- records for one instance the first stands. A search holds `limit` instances at most (256 by default), 16
--- addresses of each family for a host, and for each instance the TXT record of one message, so about 2.5 MiB at
--- the default limit. Nothing says an answer is true: any machine of the network may send one.
---
--- In a task of [`Poll.run`] a search waits through the run, so the other tasks go on, and a cancelled task's
--- search ends with nil and [`Poll.CANCELLED`]. Anywhere else it holds the thread until it ends, and ends with
--- nil and "interrupted" when a [`cosmic.signal`] guard catches a signal.

local Clock = require("cosmic.clock")
local Dns = require("cosmic.dns")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Rand = require("cosmic.rand")

local record Mdns
  --- How a search listens for its answers.
  enum Listen
    --- From a port the system chooses, with each answer asked for by unicast: no group is joined and port
    --- 5353 is not bound.
    "unicast"
    --- At the port asked, shared with the other programs bound to it, as a member of the group: answers sent
    --- to the group are heard, whoever asked.
    "group"
  end

  --- One instance of a service, as [`Mdns.browse`] answers it.
  record Instance
    --- The name of the instance, as a person reads it: any UTF-8, with dots and spaces as they are.
    name: string
    --- The whole DNS name of the instance, as [`Dns.name`] writes it, a dot inside a label escaped:
    --- `Front Desk\. Printer._ipp._tcp.local`. [`Dns.labels`] reads it back.
    fullname: string
    --- The name of the host the instance is at, as `printer.local`.
    host: string
    --- The port of the service at that host.
    port: integer
    --- The IPv4 addresses of the host, in the order they came; none where no answer gave one.
    ipv4: {string}
    --- The IPv6 addresses of the host, in the order they came. A link-local one (`fe80::`) comes without its
    --- zone, which is the interface the answer came by.
    ipv6: {string}
    --- The strings of the instance's TXT record, as they came; none where no answer gave the record.
    txt: {string}
    --- The strings of `txt` read as keys and values by [`Dns.attributes`].
    attributes: {string: string}
    --- The address the datagram with the instance's SRV record came from: the responder that answers for
    --- it, which is its host unless another machine answers on its behalf. The interface it came by is not
    --- known.
    from: string
  end

  --- What a search takes. A field out of range raises, naming the field.
  record Options
    --- How long the search lasts at most, in nanoseconds, from 0; 3 seconds when nil.
    timeout_ns?: integer
    --- How long after the first question the second is sent, in nanoseconds, from 1 millisecond; 1 second
    --- when nil. Each gap after is twice the one before.
    retry_ns?: integer
    --- How the search listens; "unicast" when nil.
    listen?: Listen
    --- The interfaces the questions leave by and, listening by "group", the group is joined on: one IPv4
    --- address of each. When nil, every interface fit for it, or the system's choice (see [`cosmic.mdns`]);
    --- an empty list is the system's choice too.
    via?: {string}
    --- The numeric IPv4 address asked; the group of multicast DNS, 224.0.0.251, when nil. Listening by
    --- "unicast", the address of one machine asks that machine alone, and `via` is not read.
    address?: string
    --- The port asked, from 1 to 65535, which "group" also binds; 5353 when nil.
    port?: integer
    --- For [`Mdns.browse`]: the most instances the search holds, from 1; 256 when nil. An instance named
    --- after that many is ignored, and the search ends early once that many are whole, as `found` has it.
    limit?: integer
    --- For [`Mdns.browse`]: called with each instance of the list once, in the task of the search. It is
    --- called as soon as the instance is whole, which is when its SRV record, its TXT record and an address
    --- of its host are known, or as the search ends for one whose SRV record alone came. An address that
    --- comes later is in the list the search answers, not in what was given here. What it raises, the search
    --- raises.
    found?: function(Instance)
  end
end

--- The group of multicast DNS over IPv4 and its port.
local GROUP <const> = "224.0.0.251"
local PORT <const> = 5353

--- The bytes a multicast DNS message holds at most (RFC 6762 section 17). A longer datagram is not read, which
--- also bounds what one TXT record makes a search hold.
local MAX_MESSAGE <const> = 9000

local DEFAULT_LIMIT <const> = 256

--- The addresses of one family kept for a host.
local MAX_ADDRESSES <const> = 16

--- How many times a search asks for the records one name lacks.
local FOLLOW_UPS <const> = 3

--- How long a search waits for the records of a name to come by themselves before it asks for them, since a
--- responder often sends them in the next datagram. It is also how long [`Mdns.resolve`] waits for more
--- addresses after the first.
local SETTLE_NS <const> = Clock.ms(100)

--- The bytes of questions put in one message, which keeps it within one frame of an Ethernet.
local QUESTION_BYTES <const> = 1200

--- The hops a multicast DNS datagram is sent with: a receiver may drop one that arrives with fewer, as proof it
--- came from another network (RFC 6762 section 11).
local HOPS <const> = 255

--- An instance as a search assembles it.
local record Entry
  name: string
  fullname: string
  --- Whoever sent the record that named it, then whoever sent its SRV record.
  mut from: string
  mut host?: string
  mut port: integer
  mut txt?: {string}
  --- Whether `found` was called with it.
  mut told: boolean
  --- How many times its missing records were asked for, and when they are next.
  mut asks: integer
  mut ask_at: integer
end

--- A host an SRV record named, or the one [`Mdns.resolve`] asks about.
local record Host
  name: string
  ipv4: mut {string}
  ipv6: mut {string}
  mut asks: integer
  mut ask_at: integer
end

--- One search: its socket, what it asks and what it has learned.
local record Hunt
  socket: Net.Datagram
  to: Net.Address
  --- The interfaces a question leaves by; none for the system's choice.
  vias: {string}
  unicast: boolean
  --- The id of every question, which an answer by unicast repeats.
  id: integer
  timeout_ns: integer
  retry_ns: integer
  limit: integer
  found?: function(Mdns.Instance)
  --- The name a browse asks pointers at, in lower case; "" for a resolve.
  service: string
  --- The labels every instance's name ends in, in lower case; none for a resolve.
  suffix: {string}
  --- Instances by their whole name in lower case, and those names in the order they came.
  instances: mut {string: Entry}
  order: mut {string}
  --- Hosts by name in lower case, and those names in the order they came.
  hosts: mut {string: Host}
  host_order: mut {string}
end

--- Whether the IPv4 `address` is a multicast group.
local function is_group(address: string): boolean
  local first = tonumber(address:match("^(%d+)%.") or "", 10)
  return first ~= nil and first >= 224 and first <= 239
end

--- One IPv4 address of each interface a question is to leave by; none where the system does not list them.
local function default_vias(): {string}
  local vias: mut {string} = {}
  local listed, _ = Net.interfaces()
  for _, interface in ipairs(listed or {}) do
    if interface.up and interface.multicast and not interface.loopback then
      for _, address in ipairs(interface.addresses) do
        if address.family == "ipv4" then
          vias[#vias + 1] = address.address
          break
        end
      end
    end
  end
  return vias
end

--- The search `opts` describes, its socket bound and, for "group", joined; nil and why where the socket cannot
--- be made so. Raises for a field out of range, at the caller of the function that calls this.
local function open(opts: Mdns.Options): Hunt?, string
  Poll.checked_ns(opts.timeout_ns, "mdns", "timeout_ns", 3)
  Poll.checked_ns(opts.retry_ns, "mdns", "retry_ns", 3)
  local retry_ns = opts.retry_ns or Clock.seconds(1)
  if retry_ns < Clock.ms(1) then error("mdns: retry_ns must be 1 millisecond or more", 3) end
  local port = opts.port or PORT
  if math.type(port) ~= "integer" or port < 1 or port > 65535 then
    error("mdns: port must be an integer from 1 to 65535", 3)
  end
  local limit = opts.limit or DEFAULT_LIMIT
  if math.type(limit) ~= "integer" or limit < 1 then
    error("mdns: limit must be an integer from 1", 3)
  end
  local address = opts.address or GROUP
  local grouped = opts.listen == "group"
  local id = 0
  if not grouped then
    -- An answer by unicast repeats the id (RFC 6762 section 6.7), so one that cannot be guessed tells it from
    -- a datagram sent blind to the port.
    local drawn, why = Rand.entropy(2)
    if drawn == nil then return nil, why end
    id = string.unpack(">I2", drawn)
  end
  local socket, why = Net.datagram(Net.udp("0.0.0.0", if grouped then port else 0 end), { shared = grouped })
  if socket == nil then return nil, why end
  local vias: {string} = {}
  if is_group(address) then vias = opts.via or default_vias() end
  local ready, trouble = socket:set_multicast({ hops = HOPS })
  if ready and grouped then
    if #vias == 0 then
      ready, trouble = socket:join(address)
    else
      ready = false
      for _, via in ipairs(vias) do
        local joined, refused = socket:join(address, via)
        if joined then ready = true else trouble = refused end
      end
    end
  end
  if not ready then
    local _, _ = socket:close()
    return nil, trouble
  end
  return {
    socket = socket,
    to = Net.udp(address, port),
    vias = vias,
    unicast = not grouped,
    id = id,
    timeout_ns = opts.timeout_ns or Clock.seconds(3),
    retry_ns = retry_ns,
    limit = limit,
    found = opts.found,
    service = "",
    suffix = {},
    instances = {},
    order = {},
    hosts = {},
    host_order = {},
  }, ""
end

--- Sends one message of `questions` by each interface of the search: true where one took it, else false and
--- why the last did not.
local function send(hunt: Hunt, questions: {Dns.Question}): boolean, string
  local message: Dns.Message = { ...Dns.query(".", Dns.PTR, hunt.id), recursion_desired = false,
    questions = questions }
  local bytes, why = Dns.encode(message)
  if bytes == nil then return false, why end
  if #hunt.vias == 0 then return hunt.socket:send(bytes, hunt.to) end
  local sent, trouble = false, ""
  for _, via in ipairs(hunt.vias) do
    local ok, refused = hunt.socket:set_multicast({ via = via })
    if ok then ok, refused = hunt.socket:send(bytes, hunt.to) end
    if ok then sent = true else trouble = refused end
  end
  if sent then return true, "" end
  return false, trouble
end

--- Sends `questions`, a message's worth at a time: true where every message was sent by some interface.
local function ask(hunt: Hunt, questions: {Dns.Question}): boolean, string
  local batch: mut {Dns.Question} = {}
  local size = 0
  local trouble = ""
  for i, question in ipairs(questions) do
    batch[#batch + 1] = question
    size = size + #question.name + 6
    if size >= QUESTION_BYTES or i == #questions then
      local sent, why = send(hunt, batch)
      if not sent then trouble = why end
      batch, size = {}, 0
    end
  end
  if trouble ~= "" then return false, trouble end
  return true, ""
end

--- A question of the search for the records of type `rtype` at `name`.
local function question(hunt: Hunt, name: string, rtype: integer): Dns.Question
  return { name = name, type = rtype, class = Dns.IN, unicast_response = hunt.unicast }
end

--- The instance of the service asked for whose whole name is `name`, which a pointer at the service gave, made
--- where the search does not hold it yet; nil for a name that is not one label before the service's, and for one
--- past the search's limit.
local function entry_for(hunt: Hunt, name: string, from: string, now: integer): Entry?
  local key = name:lower()
  local known = hunt.instances[key]
  if known ~= nil then return known end
  if #hunt.suffix == 0 or #hunt.order >= hunt.limit then return nil end
  local labels, _ = Dns.labels(name)
  if labels == nil or #labels ~= #hunt.suffix + 1 then return nil end
  for i, want in ipairs(hunt.suffix) do
    local label = labels[i + 1]
    if label == nil or label:lower() ~= want then return nil end
  end
  local first = labels[1]
  if first == nil then return nil end
  local entry: Entry = { name = first, fullname = name, from = from, port = 0, told = false, asks = 0,
    ask_at = now + SETTLE_NS }
  hunt.instances[key] = entry
  hunt.order[#hunt.order + 1] = key
  return entry
end

--- Makes `name` a host the search takes addresses of.
local function host_for(hunt: Hunt, name: string, ask_at: integer)
  local key = name:lower()
  if hunt.hosts[key] ~= nil then return end
  hunt.hosts[key] = { name = name, ipv4 = {}, ipv6 = {}, asks = 0, ask_at = ask_at }
  hunt.host_order[#hunt.host_order + 1] = key
end

--- Adds `address` to `list` unless it is there or the list is full.
local function add_address(list: mut {string}, address: string)
  if #list >= MAX_ADDRESSES then return end
  for _, held in ipairs(list) do
    if held == address then return end
  end
  list[#list + 1] = address
end

--- Reads one datagram into the search. Only a pointer at the service asked for makes an instance, so that a
--- browse for a sub-type holds no instance of the service that lacks it, and only an SRV record of an instance
--- makes a host. The pointers of a message are read before its SRV and TXT records, and those before its
--- addresses, so that a message says who a record is about wherever in it the record stands.
local function hear(hunt: Hunt, packet: Net.Packet, now: integer)
  if #packet.data > MAX_MESSAGE then return end
  local message, _ = Dns.decode(packet.data)
  if message == nil or not message.response or message.opcode ~= 0 or message.rcode ~= 0 then
    return
  end
  if hunt.unicast and message.id ~= hunt.id then return end
  local from = packet.address.host or ""
  local records: mut {Dns.Record} = {}
  for _, section in ipairs({ message.answers, message.additionals }) do
    for _, record in ipairs(section) do
      if record.class == Dns.IN and record.ttl > 0 then records[#records + 1] = record end
    end
  end
  for _, record in ipairs(records) do
    local target = record.target
    if record.type == Dns.PTR and target ~= nil and record.name:lower() == hunt.service then
      entry_for(hunt, target, from, now)
    end
  end
  for _, record in ipairs(records) do
    local srv, txt = record.srv, record.txt
    if record.type == Dns.SRV and srv ~= nil and srv.target ~= "." then
      local entry = hunt.instances[record.name:lower()]
      if entry ~= nil and entry.host == nil then
        entry.host, entry.port, entry.from = srv.target, srv.port, from
        host_for(hunt, srv.target, now + SETTLE_NS)
      end
    elseif record.type == Dns.TXT and txt ~= nil then
      local entry = hunt.instances[record.name:lower()]
      if entry ~= nil and entry.txt == nil then entry.txt = txt end
    end
  end
  for _, record in ipairs(records) do
    local address = record.address
    if address ~= nil and (record.type == Dns.A or record.type == Dns.AAAA) then
      local host = hunt.hosts[record.name:lower()]
      if host ~= nil then
        add_address(if record.type == Dns.A then host.ipv4 else host.ipv6 end, address)
      end
    end
  end
end

--- The host of `entry` as the search holds it, where its SRV record came.
local function host_of(hunt: Hunt, entry: Entry): Host?
  local name = entry.host
  if name == nil then return nil end
  return hunt.hosts[name:lower()]
end

--- `entry` as a caller is given it, with lists of its own; nil for one whose SRV record did not come.
local function instance_of(hunt: Hunt, entry: Entry): Mdns.Instance?
  local host = host_of(hunt, entry)
  if host == nil then return nil end
  local txt = entry.txt or {}
  return {
    name = entry.name,
    fullname = entry.fullname,
    host = host.name,
    port = entry.port,
    ipv4 = table.move(host.ipv4, 1, #host.ipv4, 1, {}),
    ipv6 = table.move(host.ipv6, 1, #host.ipv6, 1, {}),
    txt = txt,
    attributes = Dns.attributes(txt),
    from = entry.from,
  }
end

--- Calls `found` with each instance it was not called with yet, of those that are whole or, with `all`, of
--- those that have a host, and answers how many instances are whole.
local function tell(hunt: Hunt, all: boolean): integer
  local whole = 0
  for _, key in ipairs(hunt.order) do
    local entry = hunt.instances[key]
    local host = if entry ~= nil then host_of(hunt, entry) else nil end
    if entry ~= nil and host ~= nil then
      local is_whole = entry.txt ~= nil and #host.ipv4 + #host.ipv6 > 0
      if is_whole then whole = whole + 1 end
      local found = hunt.found
      if found ~= nil and not entry.told and (is_whole or all) then
        entry.told = true
        local instance = instance_of(hunt, entry)
        if instance ~= nil then found(instance) end
      end
    end
  end
  return whole
end

--- When the records `asks` questions have not brought are asked for next: after gaps that double from the
--- search's own.
local function next_ask(hunt: Hunt, now: integer, asks: integer): integer
  return now + hunt.retry_ns * (1 << (asks - 1))
end

--- Adds to `due` the questions for the records each name still lacks and is due to be asked for at `now`, and
--- answers when the next of them is due, or `wake` where that is sooner.
local function follow_ups(hunt: Hunt, now: integer, due: mut {Dns.Question}, wake: integer): integer
  for _, key in ipairs(hunt.order) do
    local entry = hunt.instances[key]
    if entry ~= nil and (entry.host == nil or entry.txt == nil) and entry.asks < FOLLOW_UPS then
      if entry.ask_at <= now then
        local srv, txt = question(hunt, entry.fullname, Dns.SRV), question(hunt, entry.fullname, Dns.TXT)
        if entry.host == nil then due[#due + 1] = srv end
        if entry.txt == nil then due[#due + 1] = txt end
        entry.asks = entry.asks + 1
        entry.ask_at = next_ask(hunt, now, entry.asks)
      end
      if entry.asks < FOLLOW_UPS then wake = math.min(wake, entry.ask_at) end
    end
  end
  for _, key in ipairs(hunt.host_order) do
    local host = hunt.hosts[key]
    if host ~= nil and #host.ipv4 + #host.ipv6 == 0 and host.asks < FOLLOW_UPS then
      if host.ask_at <= now then
        local a, aaaa = question(hunt, host.name, Dns.A), question(hunt, host.name, Dns.AAAA)
        due[#due + 1] = a
        due[#due + 1] = aaaa
        host.asks = host.asks + 1
        host.ask_at = next_ask(hunt, now, host.asks)
      end
      if host.asks < FOLLOW_UPS then wake = math.min(wake, host.ask_at) end
    end
  end
  return wake
end

--- Asks and listens until the search's time has passed or `done` says, after a datagram, that it may end,
--- with how long from then. False and why where the first questions could not be sent or a wait failed.
local function run(hunt: Hunt, done: function(): integer?): boolean, string
  local now = Clock.monotonic_ns()
  local deadline = now + hunt.timeout_ns
  local next_query, gap = now, hunt.retry_ns
  local asked = false
  while now < deadline do
    local due: mut {Dns.Question} = {}
    local wake = deadline
    if hunt.service ~= "" then
      if now >= next_query then
        local pointers = question(hunt, hunt.service, Dns.PTR)
        due[#due + 1] = pointers
        next_query, gap = now + gap, gap * 2
      end
      wake = math.min(wake, next_query)
    end
    wake = follow_ups(hunt, now, due, wake)
    if #due > 0 then
      local sent, why = ask(hunt, due)
      if not sent and not asked then return false, why end
      asked = true
    end
    local packet, why = hunt.socket:receive(math.max(0, wake - now))
    now = Clock.monotonic_ns()
    if packet ~= nil then
      hear(hunt, packet, now)
      local rest = done()
      if rest ~= nil then deadline = math.min(deadline, now + rest) end
    elseif why ~= Poll.TIMEOUT then
      return false, why
    end
  end
  return true, ""
end

--- What a browse asks about.
local record Service
  --- The name its pointers are asked at.
  name: string
  --- The labels its instances' names end in, in lower case.
  suffix: {string}
end

--- What a browse for `service` asks about, or nil and why `service` names no service type.
local function service_of(service: string): Service?, string
  local given, why = Dns.labels(service)
  if given == nil then return nil, why end
  local labels: mut {string} = {}
  for i, label in ipairs(given) do
    if i < #given or label:lower() ~= "local" then labels[#labels + 1] = label end
  end
  local count = #labels
  local kind, application, sub = labels[count], labels[count - 1], labels[2]
  if kind == nil or application == nil or (count ~= 2 and count ~= 4) or application:sub(1, 1) ~= "_" or
      (kind:lower() ~= "_tcp" and kind:lower() ~= "_udp") or
      (count == 4 and (sub == nil or sub:lower() ~= "_sub")) then
    return nil, ("mdns: '%s' is no service type: one is written as _http._tcp or, for a sub-type, " ..
      "_printer._sub._http._tcp, with .local after it or not"):format(service)
  end
  labels[#labels + 1] = "local"
  local name, trouble = Dns.name(labels)
  if name == nil then return nil, trouble end
  return { name = name, suffix = { application:lower(), kind:lower(), "local" } }, ""
end

--- The instances of `service` on the local network that answer within `opts.timeout_ns`, in the order they
--- were first named; none where nothing answers. `service` is a service type as DNS-SD writes it,
--- `_http._tcp` or `_ipp._tcp.local`: the name of the application's protocol, then `_tcp` or `_udp` (`_udp`
--- for all that is not TCP), then `.local` or nothing, since the domain is always `local`. A sub-type is
--- `_printer._sub._http._tcp`, and answers the instances of `_http._tcp` that declare it. The case of ASCII
--- letters means nothing.
---
--- The list holds each instance whose SRV record came, so each has its host and port; one that was only named
--- is left out. Its TXT strings and its host's addresses are there where they came too, and the search asks
--- for them when an answer leaves them out. The search ends early once `opts.limit` instances have all three:
--- a limit of 1 answers the first instance found. `opts.found` is called with each instance of the list as it
--- becomes known.
---
--- Nil and why where the search cannot be made: a `service` that is no service type, a socket that cannot be
--- bound or joined to the group, a question no interface takes, or a wait that failed, with [`Poll.CANCELLED`]
--- for a cancelled task. Raises for an option out of range.
function Mdns.browse(service: string, opts?: Mdns.Options): {Mdns.Instance}?, string
  local asked, unnamed = service_of(service)
  if asked == nil then return nil, unnamed end
  local opened, why = open(opts or {})
  if opened == nil then return nil, why end
  local hunt: Hunt = { ...opened, service = asked.name:lower(), suffix = asked.suffix }
  local _socket <close> = hunt.socket
  local ran, trouble = run(hunt, function(): integer?
    if tell(hunt, false) >= hunt.limit then return 0 end
    return nil
  end)
  if not ran then return nil, trouble end
  tell(hunt, true)
  local instances: mut {Mdns.Instance} = {}
  for _, key in ipairs(hunt.order) do
    local entry = hunt.instances[key]
    local instance = if entry ~= nil then instance_of(hunt, entry) else nil end
    if instance ~= nil then instances[#instances + 1] = instance end
  end
  return instances, ""
end

--- The addresses of the host `name` of the `local` domain, as `printer.local`, that answer within
--- `opts.timeout_ns`: its IPv4 addresses, then its IPv6 ones, each in the order they came, and none where
--- nothing answers. The search ends a tenth of a second after the first address, which is time for the host's
--- other addresses to come. `opts.limit` and `opts.found` are not read.
---
--- Nil and why for a `name` that is not one of the `local` domain, and where the search cannot be made, as
--- [`Mdns.browse`] says. Raises for an option out of range.
function Mdns.resolve(name: string, opts?: Mdns.Options): {Net.Resolved}?, string
  local labels, why = Dns.labels(name)
  if labels == nil then return nil, why end
  local last = labels[#labels]
  if #labels < 2 or last == nil or last:lower() ~= "local" then
    return nil, ("mdns: '%s' is no host of the local domain, as printer.local is"):format(name)
  end
  local asked, unnamed = Dns.name(labels)
  if asked == nil then return nil, unnamed end
  local hunt, unopened = open(opts or {})
  if hunt == nil then return nil, unopened end
  local _socket <close> = hunt.socket
  local ipv4: mut {string} = {}
  local ipv6: mut {string} = {}
  hunt.hosts[asked:lower()] = { name = asked, ipv4 = ipv4, ipv6 = ipv6, asks = 0, ask_at = Clock.monotonic_ns() }
  hunt.host_order[1] = asked:lower()
  local settling = false
  local ran, trouble = run(hunt, function(): integer?
    if settling or #ipv4 + #ipv6 == 0 then return nil end
    settling = true
    return SETTLE_NS
  end)
  if not ran then return nil, trouble end
  local addresses: mut {Net.Resolved} = {}
  for _, address in ipairs(ipv4) do
    addresses[#addresses + 1] = { address = address, family = "ipv4" }
  end
  for _, address in ipairs(ipv6) do
    addresses[#addresses + 1] = { address = address, family = "ipv6" }
  end
  return addresses, ""
end

return Mdns
