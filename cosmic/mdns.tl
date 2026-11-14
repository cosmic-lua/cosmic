--- Finding services on the local network: the client side of DNS-SD (RFC 6763) over multicast
--- DNS (RFC 6762). [`Mdns.browse`] asks which instances of a service type, or of several, the
--- network has and says where each is, and [`Mdns.resolve`] asks for the addresses of a host of
--- the `local` domain. Nothing here answers a question or publishes a service.
---
---     local printers = assert(Mdns.browse("_ipp._tcp", { timeout_ns = Clock.seconds(2) }))
---     for _, printer in ipairs(printers) do
---       print(printer.name, printer.host, printer.port, printer.ipv4[1])
---     end
---
--- A device is often known by more than one service type. One search asks for several, from one
--- socket and in as few messages as their names fit, and says of each instance which it is one
--- of. With `settle_ns` it ends that long after the first instance is whole, which is right for
--- asking one machine: the search does not wait its whole time for the types the machine lacks.
---
---     local types = { "_ipp._tcp", "_http._tcp" }
---     local found = assert(Mdns.browse(types, { settle_ns = Clock.ms(500) }))
---     for _, instance in ipairs(found) do print(instance.service, instance.name) end
---
--- A search sends its questions to the multicast group, again after `retry_ns` and then after
--- gaps that double, and listens until `timeout_ns` has passed. An answer may leave records
--- out: an instance named with no SRV or TXT record, or a host with no address. The search asks
--- for what is missing a tenth of a second after it learned the name, and then after the same
--- doubling gaps, three times at most for one name it holds: for the SRV record of an instance,
--- then for its TXT record, and for the addresses of its host. [`Mdns.resolve`] has no question
--- but the one for its host's addresses, which it so asks three times and no more.
---
--- There are two ways to listen ([`Mdns.Listen`]).
---
--- "unicast", the default, asks from a port of its own. A responder answers a question that
--- comes from another port than 5353 to that port alone, and repeats the question's id (RFC
--- 6762 section 6.7), which the search draws anew each time and holds every answer to. It needs
--- no membership of the group and no share of port 5353, so it works beside the system's own
--- responder and where a group cannot be joined, and it is right for a search made once. A
--- responder that does not repeat the id, or that leaves such a question unanswered, gives it
--- no instance.
---
--- "group" binds port 5353, shared, and joins the group, as a full member of the protocol does.
--- It hears the answers every responder sends to the group, those to another program's question
--- among them, and it is the way to use for a responder "unicast" hears nothing from. It fails
--- where a program holds port 5353 without sharing it.
---
--- A question leaves by every interface that is up, carries multicast, is no loopback and has
--- an IPv4 address, as [`Net.interfaces`] lists them, or by those `via` names. Where the
--- interfaces cannot be listed, as in a sandbox on Linux, or none is such a one, it leaves by
--- the interface the system chooses. An interface that refuses the question is passed over
--- while another takes it. Questions go over IPv4 alone; a host's IPv6 addresses are those its
--- answers over IPv4 give.
---
--- Every datagram is taken as hostile. These are ignored: one over 9000 bytes, one that is no DNS
--- message, a query, a response with an error or to another kind of query, one that comes from
--- another port than the one asked at and, listening by "unicast", one that does not repeat the
--- question's id. Of a response only the records about a name the search asked about are read. A
--- pointer at a service asked for, whose target is one label before that service's name, makes an
--- instance of it: a pointer at one of the services asked for that leads to a name of another of
--- them makes none. An instance two of them name, as a sub-type and its service do, is listed
--- once, as one of the service whose pointer came first. The SRV and TXT records of an instance
--- so made are its own, and the address records of a host one of those SRV records names are that
--- host's. No other record is read, and none of a class other than the internet's, whose data
--- [`Dns.decode`] leaves unread. A record whose time to live is 0 says the record is going away,
--- and is ignored. Of two SRV or two TXT records for one instance the first stands. A TXT record
--- of more than 128 strings, or of more than 1300 bytes with a byte for the length of each, is
--- ignored whole: RFC 6763 section 6.2 holds a service to 1300, and part of a record would read
--- as the whole of another. An instance that sends no other TXT record is listed with no TXT
--- strings, and is never whole as `limit` and `found` count it.
---
--- That is all that is checked of who answers. The id keeps out an answer sent blind to a search
--- that listens by "unicast"; listening by "group", any machine that can send a datagram to the
--- port can answer. Either way a machine of the network that hears the question can answer it
--- with anything: an instance that is not there, or, for a host an instance's SRV record names,
--- addresses of its own choosing, which are taken from whoever sends them. Whether an answer
--- came from the local link is not checked. What a search answers says where to try, not whom
--- to trust.
---
--- A search holds a bounded amount, whatever the count of service types it asks for, which is 32
--- at most: `limit` and every figure below are for all of them together. It holds `limit`
--- instances with an SRV record (256 by default, 4096 at most) and, until it has that many, 64
--- more that were named and still wait for theirs. When 64 wait a new name is taken only if its
--- SRV record comes in the same message, so names that lead nowhere do not keep out an instance
--- that says where it is. A name is forgotten once the last of its three questions has had its
--- time, which is a tenth of a second and seven times `retry_ns` after it was named: later than a
--- search of the default 3 seconds and 1 second lasts, so it makes room only in a longer search
--- or one that asks again sooner. For each instance a search holds its names, the TXT record
--- above with the keys and values read from it, and 16 addresses of each family: 12 KiB at most,
--- and so 4 MiB for the 320 instances of the default limit and 49 MiB for those of the largest.
--- Past the repeats of its own questions, one for each service type, a search asks 4 * (`limit` +
--- 64) questions in all, 1280 by default. That is a total, not a share for each name: an instance
--- may draw three questions for its TXT record and six for its addresses, and names that come,
--- are forgotten and come again can spend all of it, after which a missing record is not asked
--- for.
---
--- A search with `txt_only` lists, too, the instances whose TXT record came and whose SRV record
--- did not. Each is one of the 64 names that wait, and holds its place to the end of the search
--- where another name gives its up, so the search holds no more than without it: `limit`
--- instances with an SRV record and 64 without, of which it now lists those with a TXT record,
--- `limit` + 64 instances at most and 12 KiB for each. Once 64 names are so kept, a name is
--- taken only with its SRV record in the same message, to the end of the search: a machine that
--- names 64 instances with a TXT record each keeps every other instance of that kind out. A name
--- with neither record draws a question for each of them, three times, out of the same total.
---
--- In a task of [`Poll.run`] a search waits through the run, so the other tasks go on: it also
--- lets them run after every 16 datagrams, however fast those come. A cancelled task's search
--- ends with nil and [`Poll.CANCELLED`], and answers no list: a failure carries no value. What
--- it had found is given to `found`, which a cancelled browse calls, before it ends, with each
--- instance that has its SRV record and was not given yet, so a caller that may cancel a search
--- and wants what it found passes `found`. Anywhere else a search holds the thread until it
--- ends, and ends with nil and "interrupted" when a [`cosmic.signal`] guard catches a signal.

local Clock = require("cosmic.clock")
local Dns = require("cosmic.dns")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Rand = require("cosmic.rand")

local record Mdns
  --- How a search listens for its answers.
  enum Listen
    --- From a port the system chooses, which every answer comes back to with the id of its
    --- question: no group is joined and port 5353 is not bound.
    "unicast"
    --- At the port asked, shared with the other programs bound to it, as a member of the group:
    --- answers sent to the group are heard, whoever asked.
    "group"
  end

  --- One instance of a service, as [`Mdns.browse`] answers it.
  record Instance
    --- The name of the instance, as a person reads it: any UTF-8, with dots and spaces as they
    --- are.
    name: string
    --- The whole DNS name of the instance, as [`Dns.name`] writes it, a dot inside a label
    --- escaped: `Front Desk\. Printer._ipp._tcp.local`. [`Dns.labels`] reads it back.
    fullname: string
    --- The service type the instance is one of, as [`Mdns.browse`] was given it: `_ipp._tcp`
    --- where that was asked, `_ipp._tcp.local` where that was. Of a sub-type asked for it is the
    --- sub-type, where `fullname` ends in the name of the service.
    service: string
    --- The name of the host the instance is at, as `printer.local`; "" for an instance with no
    --- SRV record, which only a search with `txt_only` lists.
    host: string
    --- The port of the service at that host; 0 for an instance with no SRV record.
    port: integer
    --- The IPv4 addresses of the host, in the order they came; none where no answer gave one.
    ipv4: {string}
    --- The IPv6 addresses of the host, in the order they came. A link-local one (`fe80::`) comes
    --- without its zone, which is the interface the answer came by.
    ipv6: {string}
    --- The strings of the instance's TXT record, as they came; none where no answer gave a
    --- record the search keeps.
    txt: {string}
    --- The strings of `txt` read as keys and values by [`Dns.attributes`].
    attributes: {string: string}
    --- The address the datagram with the instance's SRV record came from, or with its TXT
    --- record for an instance with no SRV record: the responder that answers for it, which is its
    --- host unless another machine answers on its behalf. The interface it came by is not known.
    from: string
  end

  --- What a search takes. A field out of range raises, naming the field.
  record Options
    --- How long the search lasts at most, in nanoseconds, from 0; 3 seconds when nil.
    timeout_ns?: integer
    --- How long after the first question the second is sent, in nanoseconds, from 1
    --- millisecond; 1 second when nil. Each gap after is twice the one before.
    retry_ns?: integer
    --- How the search listens; "unicast" when nil.
    listen?: Listen
    --- The interfaces the questions leave by and, listening by "group", the group is joined on:
    --- one IPv4 address of each. When nil, every interface fit for it, or the system's choice
    --- (see [`cosmic.mdns`]); an empty list is the system's choice too.
    via?: {string}
    --- The numeric IPv4 address asked; the group of multicast DNS, 224.0.0.251, when nil.
    --- Listening by "unicast", the address of one machine asks that machine alone, and `via` is
    --- not read.
    address?: string
    --- The port asked, from 1 to 65535, which "group" also binds and every answer comes from;
    --- 5353 when nil.
    port?: integer
    --- For [`Mdns.browse`]: the most instances the search answers, of all the service types it
    --- asks together, from 1 to 4096; 256 when nil. An SRV record that would make one more is
    --- ignored, and the search ends early once that many are whole, as `found` has it.
    --- [`Mdns.resolve`] holds it to the same range and reads nothing else of it.
    limit?: integer
    --- For [`Mdns.browse`]: how long the search goes on after the first instance is whole, as
    --- `found` has it, in nanoseconds, from 0; when nil it goes on to `timeout_ns` or `limit`. The
    --- time is counted once, from that first instance, and is for the rest of what a responder
    --- has to say: 0 ends the search with the datagram that made the instance whole.
    --- [`Mdns.resolve`] holds it to its range and reads nothing else of it.
    settle_ns?: integer
    --- For [`Mdns.browse`]: true lists the instances with a TXT record and no SRV record too,
    --- which the search leaves out when nil or false. Some service types have no other kind:
    --- `_device-info._tcp` says a machine's model in a TXT record and has no SRV record. Such an
    --- instance has "" for its host, 0 for its port and no address, is never whole and is given to
    --- `found` as the search ends. It has no place of `limit`: it is one of the 64 names that
    --- wait for an SRV record, so a search lists 64 of them at most, past its `limit` ([`cosmic.mdns`]
    --- has the bound).
    txt_only?: boolean
    --- For [`Mdns.browse`]: called with each instance of the list once, in the task of the
    --- search. It is called as soon as the instance is whole, which is when its SRV record, its
    --- TXT record and an address of its host are known, or as the search ends for one whose SRV
    --- record alone came, or whose only TXT record is one a search does not keep. A search that
    --- ends cancelled calls it so too, in the cancelled task, where a wait answers
    --- [`Poll.CANCELLED`] at once. An address that comes later is in the list the search answers,
    --- not in what was given here. What it raises, the search raises.
    found?: function(Instance)
  end
end

--- The group of multicast DNS over IPv4 and its port.
local GROUP <const> = "224.0.0.251"
local PORT <const> = 5353

--- The bytes a multicast DNS message holds at most (RFC 6762 section 17). A longer datagram is
--- not read.
local MAX_MESSAGE <const> = 9000

--- The instances with an SRV record a search holds by default, and the most a caller may ask
--- for: what a search holds, and the count of questions it may ask, grow with it.
local DEFAULT_LIMIT <const> = 256
local MAX_LIMIT <const> = 4096

--- The instances a search holds that were named and have no SRV record yet.
local MAX_WAITING <const> = 64

--- The service types one browse asks for. Each is a question in every repeat, so the count holds
--- what a search sends however long a list it is given.
local MAX_SERVICES <const> = 32

--- The strings of a TXT record a search keeps, and their bytes with one for each length. Without
--- the first, a message of empty strings would make an instance hold an array of thousands.
local MAX_TXT_STRINGS <const> = 128
local MAX_TXT_BYTES <const> = 1300

--- The addresses of one family kept for a host.
local MAX_ADDRESSES <const> = 16

--- How many times a search asks for the records one name lacks, and how many such questions it
--- asks in all for each instance it may hold: an SRV, a TXT and two address questions.
local FOLLOW_UPS <const> = 3
local QUESTIONS_EACH <const> = 4

--- How long a search waits for the records of a name to come by themselves before it asks for
--- them, since a responder often sends them in the next datagram. It is also how long
--- [`Mdns.resolve`] waits for more addresses after the first.
local SETTLE_NS <const> = Clock.ms(100)

--- The bytes of questions put in one message, which keeps it within one frame of an Ethernet.
local QUESTION_BYTES <const> = 1200

--- The hops a multicast DNS datagram is sent with: a receiver may drop one that arrives with
--- fewer, as proof it came from another network (RFC 6762 section 11).
local HOPS <const> = 255

--- The datagrams a search in a task reads before it lets the run's other tasks have a turn: a
--- wait that always finds a datagram ready never gives them one.
local YIELD_AFTER <const> = 16

--- An instance as a search assembles it.
local record Entry
  name: string
  fullname: string
  --- The service type it is one of, as the caller wrote it.
  service: string
  --- Whoever sent the record that named it, then its TXT record while it has no SRV record, then
  --- its SRV record.
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

--- A service type a browse asks about.
local record Service
  --- The type as the caller wrote it.
  written: string
  --- The name its pointers are asked at.
  name: string
  --- The labels its instances' names end in, in lower case.
  suffix: {string}
end

--- One search: its socket, what it asks and what it has learned.
local record Hunt
  socket: Net.Datagram
  to: Net.Address
  --- The port asked at, which an answer comes from.
  port: integer
  --- The interfaces a question leaves by; none for the system's choice.
  vias: {string}
  --- The id of every question, and whether an answer must repeat it.
  id: integer
  unicast: boolean
  timeout_ns: integer
  retry_ns: integer
  limit: integer
  found?: function(Mdns.Instance)
  --- Whether an instance with a TXT record and no SRV record is kept and listed.
  txt_only: boolean
  --- What a browse asks about, by the name its pointers are asked at in lower case, and those
  --- names as they are asked, in the order given; none for a resolve.
  services: {string: Service}
  pointers: {string}
  --- Instances by their whole name in lower case, and those names in the order they came.
  instances: mut {string: Entry}
  order: mut {string}
  --- How many instances have their SRV record, and how many wait for it.
  mut placed: integer
  mut waiting: integer
  --- Hosts by name in lower case, and those names in the order they came.
  hosts: mut {string: Host}
  host_order: mut {string}
  --- The questions the search may still ask for missing records.
  mut questions_left: integer
end

--- Whether the IPv4 `address` is a multicast group.
local function is_group(address: string): boolean
  local first = tonumber(address:match("^(%d+)%.") or "", 10)
  return first ~= nil and first >= 224 and first <= 239
end

--- One IPv4 address of each interface a question is to leave by; none where the system does not
--- list them.
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

--- The search `opts` describes, its socket bound and, for "group", joined; nil and why where the
--- socket cannot be made so. Raises for a field out of range, at the caller of the function that
--- calls this.
local function open(opts: Mdns.Options): Hunt?, string
  Poll.checked_ns(opts.timeout_ns, "mdns", "timeout_ns", 3)
  Poll.checked_ns(opts.retry_ns, "mdns", "retry_ns", 3)
  Poll.checked_ns(opts.settle_ns, "mdns", "settle_ns", 3)
  local retry_ns = opts.retry_ns or Clock.seconds(1)
  if retry_ns < Clock.ms(1) then error("mdns: retry_ns must be 1 millisecond or more", 3) end
  local port = opts.port or PORT
  if math.type(port) ~= "integer" or port < 1 or port > 65535 then
    error("mdns: port must be an integer from 1 to 65535", 3)
  end
  local limit = opts.limit or DEFAULT_LIMIT
  if math.type(limit) ~= "integer" or limit < 1 or limit > MAX_LIMIT then
    error("mdns: limit must be an integer from 1 to " .. tostring(MAX_LIMIT), 3)
  end
  local address = opts.address or GROUP
  local grouped = opts.listen == "group"
  local id = 0
  if not grouped then
    -- One that cannot be guessed tells an answer from a datagram sent blind to the port.
    local drawn, why = Rand.entropy(2)
    if drawn == nil then return nil, why end
    id = string.unpack(">I2", drawn)
  end
  local bound = Net.udp("0.0.0.0", if grouped then port else 0 end)
  local socket, why = Net.datagram(bound, { shared = grouped })
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
    port = port,
    vias = vias,
    id = id,
    unicast = not grouped,
    timeout_ns = opts.timeout_ns or Clock.seconds(3),
    retry_ns = retry_ns,
    limit = limit,
    found = opts.found,
    txt_only = opts.txt_only == true,
    services = {},
    pointers = {},
    instances = {},
    order = {},
    placed = 0,
    waiting = 0,
    hosts = {},
    host_order = {},
    -- Within an integer whatever the limit, which is MAX_LIMIT at most.
    questions_left = QUESTIONS_EACH * (limit + MAX_WAITING),
  }, ""
end

--- Sends one message of `questions` by each interface of the search: true where one took it,
--- else false and why the last did not.
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

--- Sends `questions`, a message's worth at a time: true where every message was sent by some
--- interface.
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

--- A question for the records of type `rtype` at `name`. It never asks for an answer by unicast:
--- a question from a port of the search's own is answered there without the bit, and with it a
--- responder may answer as it does a member of the group, with no id to tell the answer by.
local function question(name: string, rtype: integer): Dns.Question
  return { name = name, type = rtype, class = Dns.IN, unicast_response = false }
end

--- The name of the instance of `service` whose whole name is `name`, its first label, or nil for
--- a name that is not one label before the name of the service.
local function instance_name(service: Service, name: string): string?
  local labels, _ = Dns.labels(name)
  if labels == nil or #labels ~= #service.suffix + 1 then return nil end
  for i, want in ipairs(service.suffix) do
    local label = labels[i + 1]
    if label == nil or label:lower() ~= want then return nil end
  end
  return labels[1]
end

--- Makes `name` a host the search takes addresses of.
local function host_for(hunt: Hunt, name: string, ask_at: integer)
  local key = name:lower()
  if hunt.hosts[key] ~= nil then return end
  hunt.hosts[key] = { name = name, ipv4 = {}, ipv6 = {}, asks = 0, ask_at = ask_at }
  hunt.host_order[#hunt.host_order + 1] = key
end

--- Gives `entry` the host and port of `srv`, which `from` sent: true unless the search holds as
--- many instances with a host as it may.
local function place(hunt: Hunt, entry: Entry, srv: Dns.Srv, from: string, now: integer): boolean
  if hunt.placed >= hunt.limit then return false end
  entry.host, entry.port, entry.from = srv.target, srv.port, from
  -- Its TXT record is asked for as its SRV record was, from the start.
  entry.asks, entry.ask_at = 0, now + SETTLE_NS
  hunt.placed = hunt.placed + 1
  host_for(hunt, srv.target, now + SETTLE_NS)
  return true
end

--- Adds `address` to `list` unless it is there or the list is full.
local function add_address(list: mut {string}, address: string)
  if #list >= MAX_ADDRESSES then return end
  for _, held in ipairs(list) do
    if held == address then return end
  end
  list[#list + 1] = address
end

--- Whether a search keeps the TXT record of the strings `txt`.
local function txt_fits(txt: {string}): boolean
  if #txt > MAX_TXT_STRINGS then return false end
  local bytes = #txt
  for _, text in ipairs(txt) do bytes = bytes + #text end
  return bytes <= MAX_TXT_BYTES
end

--- Reads one datagram into the search. Only a pointer at a service asked for makes an instance,
--- so that a browse for a sub-type holds no instance of the service that lacks it, and only an
--- SRV record of an instance makes a host. The pointers of a message are read before its SRV and
--- TXT records, and those before its addresses, so that a message says who a record is about
--- wherever in it the record stands.
local function hear(hunt: Hunt, packet: Net.Packet, now: integer)
  -- TODO: drop a datagram that did not arrive with 255 hops, the proof that it came from the
  -- local link (RFC 6762 section 11), once Net.Datagram's receive answers the hops a datagram
  -- arrived with.
  if #packet.data > MAX_MESSAGE or packet.address.port ~= hunt.port then return end
  local message, _ = Dns.decode(packet.data)
  if message == nil or not message.response or message.opcode ~= 0 or message.rcode ~= 0 then
    return
  end
  if hunt.unicast and message.id ~= hunt.id then return end
  local from = packet.address.host or ""
  local records: mut {Dns.Record} = {}
  -- The first SRV record of the message at each name, which says an instance named in the
  -- same message is no name that leads nowhere.
  local placing: mut {string: Dns.Srv} = {}
  for _, section in ipairs({ message.answers, message.additionals }) do
    for _, record in ipairs(section) do
      local srv = record.srv
      if record.ttl > 0 then
        records[#records + 1] = record
        local key = record.name:lower()
        if srv ~= nil and srv.target ~= "." and placing[key] == nil then placing[key] = srv end
      end
    end
  end
  for _, record in ipairs(records) do
    local target = record.target
    local service = if record.type == Dns.PTR then hunt.services[record.name:lower()] else nil end
    if service ~= nil and target ~= nil then
      local key = target:lower()
      local name = if hunt.instances[key] == nil then instance_name(service, target) else nil end
      local srv = placing[key]
      -- A search that has all the instances it may answer takes no new name: none could be given
      -- a host, and each would draw questions for nothing.
      if name ~= nil and hunt.placed < hunt.limit then
        local entry: Entry = { name = name, fullname = target, service = service.written, from = from,
          port = 0, told = false, asks = 0, ask_at = now + SETTLE_NS }
        local held = srv ~= nil and place(hunt, entry, srv, from, now)
        if not held and hunt.waiting < MAX_WAITING then
          hunt.waiting = hunt.waiting + 1
          held = true
        end
        if held then
          hunt.instances[key] = entry
          hunt.order[#hunt.order + 1] = key
        end
      end
    end
  end
  for _, record in ipairs(records) do
    local srv, txt = record.srv, record.txt
    local entry = hunt.instances[record.name:lower()]
    if entry ~= nil and srv ~= nil and srv.target ~= "." and entry.host == nil then
      if place(hunt, entry, srv, from, now) then hunt.waiting = hunt.waiting - 1 end
    elseif entry ~= nil and txt ~= nil and entry.txt == nil and txt_fits(txt) then
      entry.txt = txt
      if entry.host == nil then entry.from = from end
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

--- Whether the search keeps and lists `entry` though its SRV record did not come: it has its TXT
--- record, and the search was asked for such instances.
local function kept_without_srv(hunt: Hunt, entry: Entry): boolean
  return hunt.txt_only and entry.host == nil and entry.txt ~= nil
end

--- `entry` as a caller is given it, with lists of its own; nil for one the search does not list:
--- its SRV record did not come, and it is not kept without.
local function instance_of(hunt: Hunt, entry: Entry): Mdns.Instance?
  local host = host_of(hunt, entry)
  if host == nil and not kept_without_srv(hunt, entry) then return nil end
  local txt = entry.txt or {}
  local ipv4: {string} = if host ~= nil then host.ipv4 else {} end
  local ipv6: {string} = if host ~= nil then host.ipv6 else {} end
  return {
    name = entry.name,
    fullname = entry.fullname,
    service = entry.service,
    host = if host ~= nil then host.name else "" end,
    port = entry.port,
    ipv4 = table.move(ipv4, 1, #ipv4, 1, {}),
    ipv6 = table.move(ipv6, 1, #ipv6, 1, {}),
    txt = txt,
    attributes = Dns.attributes(txt),
    from = entry.from,
  }
end

--- Calls `found` with each instance it was not called with yet, of those that are whole or, with
--- `all`, of those the search lists, and answers how many instances are whole.
local function tell(hunt: Hunt, all: boolean): integer
  local whole = 0
  for _, key in ipairs(hunt.order) do
    local entry = hunt.instances[key]
    if entry ~= nil then
      local host = host_of(hunt, entry)
      local is_whole = host ~= nil and entry.txt ~= nil and #host.ipv4 + #host.ipv6 > 0
      if is_whole then whole = whole + 1 end
      local found = hunt.found
      if found ~= nil and not entry.told and (is_whole or all) then
        local instance = instance_of(hunt, entry)
        if instance ~= nil then
          entry.told = true
          found(instance)
        end
      end
    end
  end
  return whole
end

--- When the records `asks` questions have not brought are asked for next: after gaps that double
--- from the search's own.
local function next_ask(hunt: Hunt, now: integer, asks: integer): integer
  return now + hunt.retry_ns * (1 << (asks - 1))
end

--- Forgets each instance that has no SRV record once the last question for it has had its time,
--- so that it makes room for another name, and every one of them once the search holds all the
--- instances it may answer. One the search keeps without an SRV record is never forgotten.
local function forget_unanswered(hunt: Hunt, now: integer)
  for at = #hunt.order, 1, -1 do
    local key = hunt.order[at]
    local entry = if key ~= nil then hunt.instances[key] else nil end
    if key ~= nil and entry ~= nil and entry.host == nil and not kept_without_srv(hunt, entry) and
        (hunt.placed >= hunt.limit or (entry.asks >= FOLLOW_UPS and entry.ask_at <= now)) then
      hunt.instances[key] = nil
      table.remove(hunt.order, at)
      hunt.waiting = hunt.waiting - 1
    end
  end
end

--- Adds `asked` to `due` while the search may still ask for missing records.
local function follow_up(hunt: Hunt, due: mut {Dns.Question}, asked: Dns.Question)
  if hunt.questions_left <= 0 then return end
  hunt.questions_left = hunt.questions_left - 1
  due[#due + 1] = asked
end

--- Adds to `due` the questions for the records each name still lacks and is due to be asked for
--- at `now`, and answers when the next of them is due, or `wake` where that is sooner.
local function follow_ups(hunt: Hunt, now: integer, due: mut {Dns.Question}, wake: integer): integer
  forget_unanswered(hunt, now)
  for _, key in ipairs(hunt.order) do
    local entry = hunt.instances[key]
    if entry ~= nil and (entry.host == nil or entry.txt == nil) then
      if entry.asks < FOLLOW_UPS and entry.ask_at <= now then
        -- The TXT record of a name with no SRV record says nothing of use to a search that lists
        -- no such instance, and a name that leads nowhere would draw two questions for one.
        if entry.host == nil then follow_up(hunt, due, question(entry.fullname, Dns.SRV)) end
        if entry.txt == nil and (entry.host ~= nil or hunt.txt_only) then
          follow_up(hunt, due, question(entry.fullname, Dns.TXT))
        end
        entry.asks = entry.asks + 1
        entry.ask_at = next_ask(hunt, now, entry.asks)
      end
      -- After the last question too, for one that is then forgotten.
      if entry.asks < FOLLOW_UPS or (entry.host == nil and not kept_without_srv(hunt, entry)) then
        wake = math.min(wake, entry.ask_at)
      end
    end
  end
  for _, key in ipairs(hunt.host_order) do
    local host = hunt.hosts[key]
    if host ~= nil and #host.ipv4 + #host.ipv6 == 0 and host.asks < FOLLOW_UPS then
      if host.ask_at <= now then
        follow_up(hunt, due, question(host.name, Dns.A))
        follow_up(hunt, due, question(host.name, Dns.AAAA))
        host.asks = host.asks + 1
        host.ask_at = next_ask(hunt, now, host.asks)
      end
      if host.asks < FOLLOW_UPS then wake = math.min(wake, host.ask_at) end
    end
  end
  return wake
end

--- Asks and listens until the search's time has passed or `done` says, after a datagram, that it
--- may end, with how long from then. False and why where the first questions could not be sent
--- or a wait failed.
local function run(hunt: Hunt, done: function(): integer?): boolean, string
  local now = Clock.monotonic_ns()
  local deadline = now + hunt.timeout_ns
  local next_query, gap = now, hunt.retry_ns
  local asked = false
  local heard = 0
  while now < deadline do
    local due: mut {Dns.Question} = {}
    local wake = deadline
    if #hunt.pointers > 0 then
      if now >= next_query then
        for _, name in ipairs(hunt.pointers) do
          local pointers = question(name, Dns.PTR)
          due[#due + 1] = pointers
        end
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
      heard = heard + 1
      if heard >= YIELD_AFTER and Poll.in_task() then
        heard = 0
        local went_on, cancelled = Poll.delay(0)
        if not went_on then return false, cancelled end
        now = Clock.monotonic_ns()
      end
    elseif why ~= Poll.TIMEOUT then
      return false, why
    end
  end
  return true, ""
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
  if kind == nil or application == nil or (count ~= 2 and count ~= 4) or
      application:sub(1, 1) ~= "_" or (kind:lower() ~= "_tcp" and kind:lower() ~= "_udp") or
      (count == 4 and (sub == nil or sub:lower() ~= "_sub")) then
    return nil, ("mdns: '%s' is no service type: one is written as _http._tcp or, for a " ..
      "sub-type, _printer._sub._http._tcp, with .local after it or not"):format(service)
  end
  labels[#labels + 1] = "local"
  local name, trouble = Dns.name(labels)
  if name == nil then return nil, trouble end
  return { written = service, name = name, suffix = { application:lower(), kind:lower(), "local" } }, ""
end

--- The instances of `service` on the local network that answer within `opts.timeout_ns`, in the
--- order they were first named; none where nothing answers. `service` is a service type as
--- DNS-SD writes it, `_http._tcp` or `_ipp._tcp.local`: the name of the application's protocol,
--- then `_tcp` or `_udp` (`_udp` for all that is not TCP), then `.local` or nothing, since the
--- domain is always `local`. A sub-type is `_printer._sub._http._tcp`, and answers the instances
--- of `_http._tcp` that declare it. The case of ASCII letters means nothing.
---
--- `service` is also a list of such types, 1 to 32 of them, which one search asks for: every
--- type in each repeat of its questions, from one socket, in as few messages as hold them. The
--- list it answers holds the instances of them all, in the order they were first named, each
--- with the type it is one of in its `service`. A type written twice is asked for once and named
--- as it was first written.
---
--- The list holds each instance whose SRV record came, so each has its host and port; one that
--- was only named is left out, and so is one with a TXT record and no SRV record unless
--- `opts.txt_only` asks for those. Its TXT strings and its host's addresses are there where they
--- came too, and the search asks for them when an answer leaves them out. The search ends early
--- once `opts.limit` instances have all three: a limit of 1 answers the first instance found.
--- It ends `opts.settle_ns` after the first instance has all three, where that is given.
--- `opts.found` is called with each instance of the list as it becomes known.
---
--- Nil and why where the search cannot be made: a `service` that is no service type, or a list
--- with one that is none, with no type or with more than 32, a socket that cannot be bound, which
--- says the address and port first, a group that cannot be joined on any interface, which says
--- the group first, a question no interface takes, or a wait that failed, with [`Poll.CANCELLED`]
--- for a cancelled task, whose search has called `opts.found` with each instance that has its SRV
--- record. The socket is closed however the search ends. Raises for an option out of range.
function Mdns.browse(service: string | {string}, opts?: Mdns.Options): {Mdns.Instance}?, string
  local written: {string}
  if service is string then written = { service } else written = service end
  if #written == 0 then return nil, "mdns: no service type was asked for" end
  if #written > MAX_SERVICES then
    return nil, ("mdns: the list of service types holds %d, more than the %d one search asks for"):format(
      #written, MAX_SERVICES)
  end
  local services: mut {string: Service} = {}
  local pointers: mut {string} = {}
  for _, one in ipairs(written) do
    local asked, unnamed = service_of(one)
    if asked == nil then return nil, unnamed end
    local key = asked.name:lower()
    if services[key] == nil then
      services[key] = asked
      pointers[#pointers + 1] = asked.name
    end
  end
  local options = opts or {}
  local opened, why = open(options)
  if opened == nil then return nil, why end
  local hunt: Hunt = { ...opened, services = services, pointers = pointers }
  local _socket <close> = hunt.socket
  local settle_ns = options.settle_ns
  local ran, trouble = run(hunt, function(): integer?
    local whole = tell(hunt, false)
    if whole >= hunt.limit then return 0 end
    -- Said again after each later datagram, which moves no end: `run` keeps the soonest.
    if settle_ns == nil or whole == 0 then return nil end
    return settle_ns
  end)
  if not ran then
    -- A failure answers no list, so `found` is the one way out for what a cancelled search held.
    if trouble == Poll.CANCELLED then tell(hunt, true) end
    return nil, trouble
  end
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
--- `opts.timeout_ns`: its IPv4 addresses, then its IPv6 ones, each in the order they came, and
--- none where nothing answers. The search ends a tenth of a second after the first address,
--- which is time for the host's other addresses to come. The question is asked three times at
--- most: at once, after `opts.retry_ns` and after twice that again. `opts.found` is not read,
--- and `opts.limit` only to hold it to its range.
---
--- Nil and why for a `name` that is not one of the `local` domain, and where the search cannot
--- be made, as [`Mdns.browse`] says. Raises for an option out of range.
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
  local key = asked:lower()
  local asked_now = Clock.monotonic_ns()
  hunt.hosts[key] = { name = asked, ipv4 = ipv4, ipv6 = ipv6, asks = 0, ask_at = asked_now }
  hunt.host_order[1] = key
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
