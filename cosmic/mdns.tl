--- Finding services on the local network: the client side of DNS-SD (RFC 6763) over multicast
--- DNS (RFC 6762). [`Mdns.browse`] asks which instances of a service type, or of several, the
--- network has and says where each is, and [`Mdns.resolve`] asks for the addresses of a host of
--- the `local` domain. [`Mdns.responder`] is the other side: it answers the questions about
--- the instances it is given.
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
--- interfaces cannot be listed, as in a sandbox with no network, or none is such a one, it leaves by
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
--- where another name gives up its own, so the search holds no more than without it: `limit`
--- instances with an SRV record and 64 without, of which it now lists those with a TXT record,
--- `limit` + 64 instances at most and 12 KiB for each. They are those named before the search
--- held `limit` instances with an SRV record, after which it takes no new name. Once 64 names
--- are so kept, a name is taken only with its SRV record in the same message, to the end of the
--- search: a machine that names 64 instances with a TXT record each keeps every other instance
--- of that kind out. A name with neither record draws a question for each of them, three times,
--- out of the same total.
---
--- In a task of [`Poll.run`] a search waits through the run, so the other tasks go on: it also
--- lets them run after every 16 datagrams, however fast those come. A cancelled task's search
--- ends with nil and [`Poll.CANCELLED`], and answers no list: a failure carries no value. What
--- it had found is given to `found`, which a cancelled browse calls, before it ends, with each
--- instance it would have listed and had not given yet, so a caller that may cancel a search
--- and wants what it found passes `found`. Anywhere else a search holds the thread until it
--- ends, and ends with nil and "interrupted" when a [`cosmic.signal`] guard catches a signal.
---
--- A responder ([`Mdns.responder`]) publishes instances by answering for them:
---
---     local responder <close> = assert(Mdns.responder({
---       { service = "_http._tcp", name = "Front Desk", host = "desk.local", port = 8080,
---         ipv4 = { "192.0.2.7" }, txt = { "path=/" } },
---     }))
---     assert(responder:serve())
---
--- It binds port 5353, shared, joins the group, and answers the PTR question at the service type
--- of an instance, the SRV and TXT questions at the instance's name, the A and AAAA questions at
--- its host's, and a question for any type at each, with the records the question did not ask
--- for beside those it did. A question from port 5353 is answered to the group, with the id 0
--- and no question, as one member answers another. A question from any other port is from a
--- program that is no member, and is answered to that port alone, with its id and its questions
--- repeated and no time to live over 10 seconds (RFC 6762 section 6.7): that is what a search
--- listening by "unicast" asks. A member's question that asks for its answer by unicast is
--- answered to the group all the same. Answers go by IPv4 alone, and to the group by every
--- interface the responder joined it on. The responder holds 64 instances at most, each with
--- what a search keeps of one, and answers a query with one message for each instance the query
--- asks about, none over 9000 bytes, though one may be longer than a frame of an Ethernet
--- carries whole. It reads a query as a search reads an answer: one over 9000 bytes, one that
--- is no DNS message, a response and a query of another kind are ignored, and whether a query
--- came from the local link is not checked, so any machine that can reach the port draws an
--- answer.
---
--- Answering is all it does of a publisher's part. It does not probe for its names before it
--- uses them, announce its records, say goodbye as it stops or settle a conflict with another
--- responder that answers for the same name (RFC 6762 sections 8 to 10), so the names it is
--- given must be the caller's to use. It does not leave out an answer the question lists as
--- known (section 7.1), wait before it answers a question others may answer too (section 6),
--- or say that a record it could have does not exist (section 6.1), and it publishes no
--- sub-type.

local Clock = require("cosmic.clock")
local Dns = require("cosmic.dns")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Rand = require("cosmic.rand")

--- A responder, as [`Mdns.responder`] answers one: it holds its socket, bound and a member of
--- the group, from when it is made, and answers questions while `serve` runs. A class, so a
--- `<close>` local holds one.
local class MdnsResponder
  --- Where it is bound: every address of the machine, at the port asked for or, for port 0,
  --- the one the system chose.
  address: Net.Address
  --- Internal: the socket. No caller reads it.
  socket: Net.Datagram
  --- Internal: answers the queries that reach the socket until a wait fails.
  answering: function(): boolean, string
  --- Internal: set by `close`.
  mut closed: boolean

  --- Answers the questions that come about the responder's instances, until `close`: true once
  --- it is closed, from another task or before the call. False and why where a wait fails
  --- first: [`Poll.CANCELLED`] in a cancelled task, "interrupted" where a [`cosmic.signal`] guard
  --- catches a signal. In a task of [`Poll.run`] the other tasks go on meanwhile, and have a turn
  --- after every 16 datagrams however fast those come; anywhere else it holds the thread. An
  --- answer the system does not take is dropped, as the network drops one.
  function serve(self): boolean, string
    local _, why = self.answering()
    if self.closed then return true, "" end
    return false, why
  end

  --- Closes the socket, which leaves the group and ends `serve`. Safe to call more than once.
  function close(self): boolean, string
    self.closed = true
    return self.socket:close()
  end

  function __close(self)
    local _, _ = self:close()
  end
end

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
    --- wait for an SRV record, so a search lists 64 of them at most, past its `limit`
    --- ([`cosmic.mdns`] has the bound). A search that holds `limit` instances with an SRV record
    --- takes no new name, so it lists those of them that were named before then.
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

  --- One instance of a service, as [`Mdns.responder`] publishes it.
  record Published
    --- The service type, as [`Mdns.browse`] takes one: `_http._tcp`, with `.local` after it or
    --- not. A sub-type is refused.
    service: string
    --- The name of the instance, as a person reads it: one label of 1 to 63 bytes, any UTF-8.
    name: string
    --- The name of the host the instance is at, of the `local` domain: `printer.local`.
    host: string
    --- The port of the service at that host, from 0 to 65535.
    port: integer
    --- The IPv4 addresses of the host, numeric, 16 at most; none when nil.
    ipv4?: {string}
    --- The IPv6 addresses of the host, numeric, 16 at most; none when nil.
    ipv6?: {string}
    --- The strings of the TXT record, `key=value` each by DNS-SD's convention: 128 strings and
    --- 1300 bytes at most, with a byte for the length of each. No strings when nil, which is a
    --- record of one empty string.
    txt?: {string}
  end

  --- What [`Mdns.responder`] takes. A field out of range raises, naming the field.
  record ResponderOptions
    --- The IPv4 multicast group joined and answered to; that of multicast DNS, 224.0.0.251,
    --- when nil.
    address?: string
    --- The port bound, shared, from 0 to 65535; 5353 when nil. A question from this port is a
    --- member's, and any other is answered by unicast. 0 is a port the system chooses, which
    --- the responder's `address` then says: no searcher asks there unless told to, so it is for
    --- a test.
    port?: integer
    --- The interfaces the group is joined on and its answers leave by: one IPv4 address of
    --- each. When nil, every interface fit for it, or the system's choice, as for a search (see
    --- [`cosmic.mdns`]); an empty list is the system's choice too.
    via?: {string}
  end

  --- A responder that answers for the instances it was given.
  type Responder = MdnsResponder
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

--- The instances a responder publishes: a query that asks about them all draws a message for
--- each.
local MAX_PUBLISHED <const> = 64

--- The seconds a responder's records live: those that name a host or hold its address, which
--- change when the host does, and the others (RFC 6762 section 10). A record sent to a program
--- that is no member of the group lives no longer than the last (section 6.7).
local HOST_TTL <const> = 120
local OTHER_TTL <const> = 4500
local LEGACY_TTL <const> = 10

--- The class of a question that asks for the records of any class.
local ANY_CLASS <const> = 255

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

--- Joins `group` on each interface of `vias`, or on the system's choice where there is none: true
--- where one joined, else false and why the last did not.
local function join(socket: Net.Datagram, group: string, vias: {string}): boolean, string
  if #vias == 0 then return socket:join(group) end
  local joined, trouble = false, ""
  for _, via in ipairs(vias) do
    local ok, refused = socket:join(group, via)
    if ok then joined = true else trouble = refused end
  end
  if joined then return true, "" end
  return false, trouble
end

--- Sends `bytes` to `to` by each interface of `vias`, or by the system's choice where there is
--- none: true where one took it, else false and why the last did not.
local function send_by(socket: Net.Datagram, vias: {string}, bytes: string, to: Net.Address): boolean, string
  if #vias == 0 then return socket:send(bytes, to) end
  local sent, trouble = false, ""
  for _, via in ipairs(vias) do
    local ok, refused = socket:set_multicast({ via = via })
    if ok then ok, refused = socket:send(bytes, to) end
    if ok then sent = true else trouble = refused end
  end
  if sent then return true, "" end
  return false, trouble
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
  if ready and grouped then ready, trouble = join(socket, address, vias) end
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
  return send_by(hunt.socket, hunt.vias, bytes, hunt.to)
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
--- for a cancelled task, whose search has called `opts.found` with each instance it would have
--- listed. The socket is closed however the search ends. Raises for an option out of range.
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

--- The name of the host `name` as [`Dns.name`] writes it, or nil and why `name` is no host of the
--- `local` domain.
local function local_host(name: string): string?, string
  local labels, why = Dns.labels(name)
  if labels == nil then return nil, why end
  local last = labels[#labels]
  if #labels < 2 or last == nil or last:lower() ~= "local" then
    return nil, ("mdns: '%s' is no host of the local domain, as printer.local is"):format(name)
  end
  return Dns.name(labels)
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
  local asked, unnamed = local_host(name)
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

--- An instance as a responder holds it: its names in lower case, as a question's is compared,
--- and its records as a member of the group is sent them. `addresses` is its host's, one list
--- shared by every instance at the host.
local record Publication
  --- The name its pointer is at, the instance's whole name and its host's.
  service: string
  instance: string
  host: string
  pointer: Dns.Record
  srv: Dns.Record
  txt: Dns.Record
  addresses: {Dns.Record}
end

--- A record of a responder's at `name` that lives `ttl` seconds. All but a pointer are the only
--- record of their name and type, which the cache-flush bit says (RFC 6762 section 10.2).
local function published_at(name: string, rtype: integer, ttl: integer): Dns.Record
  return { name = name, type = rtype, class = Dns.IN, cache_flush = rtype ~= Dns.PTR, ttl = ttl }
end

--- What a responder holds for `given`, or nil and why it publishes no such instance. `hosts` is
--- the address records of each host by its name in lower case, which this adds the instance's
--- to: every instance of a host answers with all the host's addresses, since an address record
--- says it is the only one of its name and type but for those sent with it.
local function publication(given: Mdns.Published, hosts: mut {string: mut {Dns.Record}}): Publication?, string
  local service, unnamed = service_of(given.service)
  if service == nil then return nil, unnamed end
  local labels, unread = Dns.labels(service.name)
  if labels == nil then return nil, unread end
  if #labels ~= #service.suffix then
    return nil, ("mdns: '%s' is a sub-type, which a responder does not publish"):format(given.service)
  end
  local whole: mut {string} = { given.name }
  for _, label in ipairs(labels) do whole[#whole + 1] = label end
  local instance, misnamed = Dns.name(whole)
  if instance == nil then
    return nil, ("mdns: the instance name '%s': %s"):format(given.name, misnamed)
  end
  local host, elsewhere = local_host(given.host)
  if host == nil then return nil, elsewhere end
  if math.type(given.port) ~= "integer" or given.port < 0 or given.port > 65535 then
    return nil, ("mdns: the port of '%s' must be an integer from 0 to 65535"):format(given.name)
  end
  local strings = given.txt or {}
  if not txt_fits(strings) then
    return nil, ("mdns: the TXT record of '%s' is past what a search keeps of one"):format(given.name)
  end
  local addresses: mut {Dns.Record} = hosts[host:lower()] or {}
  hosts[host:lower()] = addresses
  -- Adds the host's addresses of `list` that it lacks, of the family `rtype` is of: false where
  -- that would be more than a responder publishes.
  local function add(rtype: integer, list: {string}): boolean
    for _, address in ipairs(list) do
      local known, of_family = false, 0
      for _, record in ipairs(addresses) do
        if record.type == rtype then
          of_family = of_family + 1
          known = known or record.address == address
        end
      end
      if not known and of_family >= MAX_ADDRESSES then return false end
      if not known then
        local record: Dns.Record = { ...published_at(host, rtype, HOST_TTL), address = address }
        addresses[#addresses + 1] = record
      end
    end
    return true
  end
  if not add(Dns.A, given.ipv4 or {}) or not add(Dns.AAAA, given.ipv6 or {}) then
    return nil, ("mdns: '%s' has more addresses of a family than the %d a responder publishes"):format(
      given.host, MAX_ADDRESSES)
  end
  return {
    service = service.name:lower(),
    instance = instance:lower(),
    host = host:lower(),
    pointer = { ...published_at(service.name, Dns.PTR, OTHER_TTL), target = instance },
    srv = { ...published_at(instance, Dns.SRV, HOST_TTL),
      srv = { priority = 0, weight = 0, port = given.port, target = host } },
    txt = { ...published_at(instance, Dns.TXT, OTHER_TTL), txt = strings },
    addresses = addresses,
  }, ""
end

--- Why a responder cannot answer for `held`, published as `name`, or "": its records are written
--- once here, so that an address that is none is refused as the responder is made and not at
--- each answer, and so that the answer has room beside them for the questions it repeats.
local function unanswerable(held: Publication, name: string): string
  local records: mut {Dns.Record} = { held.pointer, held.srv, held.txt }
  for _, record in ipairs(held.addresses) do records[#records + 1] = record end
  local bytes, unwritten = Dns.encode({ ...Dns.query(".", Dns.PTR, 0), questions = {}, answers = records })
  if bytes == nil then return ("mdns: the instance '%s': %s"):format(name, unwritten) end
  if #bytes > MAX_MESSAGE - QUESTION_BYTES then
    return ("mdns: the records of '%s' are longer than one answer of a responder holds"):format(name)
  end
  return ""
end

--- `record` as it is sent: to a member of the group as it is held, and to a program that is none
--- with no cache to flush and a short life.
local function sent_as(record: Dns.Record, legacy: boolean): Dns.Record
  if not legacy then return record end
  return { ...record, cache_flush = false, ttl = math.min(record.ttl, LEGACY_TTL) }
end

--- The messages that answer `query` for `published`, as bytes: one for each instance the query
--- asks about, with the records asked for as answers and, beside a pointer or an SRV record,
--- those a searcher asks for next as additionals. An address two instances share is an answer
--- once. `legacy` is whether the query came from a program that is no member of the group.
local function replies(published: {Publication}, query: Dns.Message, legacy: boolean): {string}
  local out: mut {string} = {}
  local told: mut {string: boolean} = {}
  for _, held in ipairs(published) do
    local ptr, srv, txt, a, aaaa = false, false, false, false, false
    for _, asked in ipairs(query.questions) do
      if asked.class == Dns.IN or asked.class == ANY_CLASS then
        local name, any = asked.name:lower(), asked.type == Dns.ANY
        if name == held.service then ptr = ptr or any or asked.type == Dns.PTR end
        if name == held.instance then
          srv = srv or any or asked.type == Dns.SRV
          txt = txt or any or asked.type == Dns.TXT
        end
        if name == held.host then
          a = a or any or asked.type == Dns.A
          aaaa = aaaa or any or asked.type == Dns.AAAA
        end
      end
    end
    local answers: mut {Dns.Record} = {}
    local additionals: mut {Dns.Record} = {}
    local function put(record: Dns.Record, asked: boolean, beside: boolean)
      local shaped = sent_as(record, legacy)
      if asked then
        answers[#answers + 1] = shaped
      elseif beside then
        additionals[#additionals + 1] = shaped
      end
    end
    put(held.pointer, ptr, false)
    put(held.srv, srv, ptr)
    put(held.txt, txt, ptr)
    for _, record in ipairs(held.addresses) do
      local asked = if record.type == Dns.A then a else aaaa end
      local key = ("%s %d %s"):format(held.host, record.type, record.address or "")
      if asked and told[key] == true then
        asked = false
      elseif asked then
        told[key] = true
      end
      put(record, asked, ptr or srv)
    end
    if #answers > 0 then
      local message: Dns.Message = { ...Dns.reply(query), authoritative = true, answers = answers,
        additionals = additionals }
      if not legacy then
        message = { ...message, id = 0, recursion_desired = false, questions = {} }
      end
      local bytes, _ = Dns.encode(message)
      -- Over the size only for the questions a query of a program that is no member has it
      -- repeat: such an answer is not sent.
      if bytes ~= nil and #bytes <= MAX_MESSAGE then out[#out + 1] = bytes end
    end
  end
  return out
end

--- Answers the queries that reach `socket`, bound at `port`, for `published`, to `group` by
--- `vias` or to the sender, until a wait fails: false and why.
local function respond(socket: Net.Datagram, port: integer, group: Net.Address, vias: {string},
                       published: {Publication}): boolean, string
  local heard = 0
  while true do
    local packet, why = socket:receive()
    if packet == nil then return false, why end
    -- TODO: drop a query that did not arrive with 255 hops, the proof that it came from the local
    -- link (RFC 6762 section 11), once Net.Datagram's receive answers the hops a datagram arrived
    -- with: until then a machine past the link that reaches the port draws an answer, sent to
    -- the address it gives as its own.
    local query, _ = Dns.decode(packet.data)
    if query ~= nil and #packet.data <= MAX_MESSAGE and not query.response and query.opcode == 0 then
      -- A question from another port is from a program that is no member of the group.
      local legacy = packet.address.port ~= port
      for _, bytes in ipairs(replies(published, query, legacy)) do
        if legacy then
          local _, _ = socket:send(bytes, packet.address)
        else
          local _, _ = send_by(socket, vias, bytes, group)
        end
      end
    end
    heard = heard + 1
    if heard >= YIELD_AFTER and Poll.in_task() then
      heard = 0
      local went_on, cancelled = Poll.delay(0)
      if not went_on then return false, cancelled end
    end
  end
end

--- A responder that publishes `instances`, 1 to 64 of them: its socket bound at `opts.port`,
--- shared, and a member of the group on the interfaces `opts.via` names, ready for `serve` to
--- answer the questions about them ([`cosmic.mdns`] says which, and what a responder leaves
--- undone). Two instances may be at one host; where they give it different addresses, the host
--- has them all, and each of its instances is answered for with them all. The names are the
--- caller's to use: no other responder is asked whether it answers for them.
---
--- Nil and why where it cannot be made: no instance or more than 64, an instance whose service
--- is no service type or is a sub-type, whose name is no label, whose host is not one of the
--- `local` domain, whose port is out of range, with an address that is none, with a TXT record
--- past what a search keeps, with the same name and service as another, or whose records are
--- longer than one answer holds; a host given more than 16 addresses of a family by its
--- instances together; a socket that cannot be bound, which says the address and port first, as where a
--- program holds the port without sharing it; or a group that cannot be joined on any
--- interface, which says the group first. Raises for an option out of range.
function Mdns.responder(instances: {Mdns.Published}, opts?: Mdns.ResponderOptions): Mdns.Responder?, string
  local options = opts or {}
  local port = options.port or PORT
  if math.type(port) ~= "integer" or port < 0 or port > 65535 then
    error("mdns: port must be an integer from 0 to 65535", 2)
  end
  local address = options.address or GROUP
  if not is_group(address) then error("mdns: address must be an IPv4 multicast group", 2) end
  if #instances == 0 then return nil, "mdns: a responder publishes one instance at least" end
  if #instances > MAX_PUBLISHED then
    return nil, ("mdns: the list of instances holds %d, more than the %d a responder publishes"):format(
      #instances, MAX_PUBLISHED)
  end
  local published: mut {Publication} = {}
  local names: mut {string: boolean} = {}
  local hosts: mut {string: mut {Dns.Record}} = {}
  for _, given in ipairs(instances) do
    local held, why = publication(given, hosts)
    if held == nil then return nil, why end
    if names[held.instance] == true then
      return nil, ("mdns: the instance '%s' of %s is given twice"):format(given.name, given.service)
    end
    names[held.instance] = true
    published[#published + 1] = held
  end
  -- Once every instance is read: a host has the addresses of them all.
  for at, held in ipairs(published) do
    local given = instances[at]
    local why = unanswerable(held, if given ~= nil then given.name else "" end)
    if why ~= "" then return nil, why end
  end
  local socket, why = Net.datagram(Net.udp("0.0.0.0", port), { shared = true })
  if socket == nil then return nil, why end
  local vias = options.via or default_vias()
  local ready, trouble = socket:set_multicast({ hops = HOPS })
  if ready then ready, trouble = join(socket, address, vias) end
  if not ready then
    local _, _ = socket:close()
    return nil, trouble
  end
  local bound = socket.address.port or port
  local group = Net.udp(address, bound)
  local made: MdnsResponder = {
    address = socket.address,
    socket = socket,
    closed = false,
    answering = function(): boolean, string
      return respond(socket, bound, group, vias, published)
    end,
  }
  return made, ""
end

return Mdns
