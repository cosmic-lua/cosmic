--- [`cosmic.mdns`] on the loopback. A search against a stand-in responder, for the answers no
--- real one gives: instances assembled from whole and partial answers, what a hostile answer
--- cannot do, the limits of a search, and both ways to listen. And [`Mdns.responder`], asked by a
--- search and by queries written by hand.

local Clock = require("cosmic.clock")
local Dns = require("cosmic.dns")
local Mdns = require("cosmic.mdns")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")

--- Every search asks a responder bound on the worker's own loopback.
Test.policy{ loopback = { "127.0.0.1" } }

local LOOPBACK <const> = "127.0.0.1"
local HTTP <const> = "_http._tcp.local"
local IPP <const> = "_ipp._tcp.local"

--- What a responder sends back for one query: whole datagrams, in order.
local type Reply = function(query: Dns.Message): {string}

--- The same for a responder that reads the datagram the query came in.
local type ReplyTo = function(query: Dns.Message, packet: Net.Packet): {string}

--- A record of type `rtype` at `name` that lives two minutes.
local function at(name: string, rtype: integer): Dns.Record
  return { name = name, type = rtype, class = Dns.IN, cache_flush = false, ttl = 120 }
end

--- The whole name of the instance `instance` of `service`.
local function fullname(instance: string, service: string): string
  local labels: mut {string} = { instance }
  for _, label in ipairs((assert(Dns.labels(service)))) do labels[#labels + 1] = label end
  return (assert(Dns.name(labels)))
end

local function pointer(service: string, instance: string): Dns.Record
  return { ...at(service, Dns.PTR), target = fullname(instance, service) }
end

local function srv(name: string, host: string, port: integer): Dns.Record
  return { ...at(name, Dns.SRV), srv = { priority = 0, weight = 0, port = port, target = host } }
end

local function txt(name: string, strings: {string}): Dns.Record
  return { ...at(name, Dns.TXT), txt = strings }
end

local function a(host: string, address: string): Dns.Record
  return { ...at(host, Dns.A), address = address }
end

local function aaaa(host: string, address: string): Dns.Record
  return { ...at(host, Dns.AAAA), address = address }
end

--- The response to `query` that holds `answers` and `additionals`, as bytes.
local function response(query: Dns.Message, answers: {Dns.Record}, additionals?: {Dns.Record}): string
  local message: Dns.Message = { ...Dns.reply(query), authoritative = true, answers = answers,
    additionals = additionals or {} }
  return (assert(Dns.encode(message)))
end

--- Whether `query` asks for the records of type `rtype` at `name`, whatever the case of either
--- name.
local function asks(query: Dns.Message, name: string, rtype: integer): boolean
  for _, question in ipairs(query.questions) do
    if question.type == rtype and question.name:lower() == name:lower() then return true end
  end
  return false
end

--- The four records that say all of the instance `instance` of `service` at `host`.
local function described(service: string, instance: string, host: string, port: integer, address: string):
    {Dns.Record}
  local name = fullname(instance, service)
  return { pointer(service, instance), srv(name, host, port), txt(name, { "path=/" }), a(host, address) }
end

--- Runs `body` beside a responder on the loopback that answers each query with what `reply` gives
--- for it and the datagram it came in, to the address the query came from. `body` is given the
--- options that make a search ask that responder alone: a time limit no passing test reaches, so
--- that a test ends by its `limit` or fails by its own.
local function serving_packets(reply: ReplyTo, body: function(opts: Mdns.Options))
  Poll.run(function()
    local device <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
    local responder = Poll.spawn(function()
      while true do
        local packet = device:receive()
        if packet == nil then return end
        local query = Dns.decode(packet.data)
        if query ~= nil then
          for _, bytes in ipairs(reply(query, packet)) do
            assert(device:send(bytes, packet.address))
          end
        end
      end
    end)
    body({ address = LOOPBACK, port = assert(device.address.port), timeout_ns = Clock.seconds(10),
      retry_ns = Clock.ms(200) })
    assert(device:close())
    assert(responder:join())
  end)
end

local function serving(reply: Reply, body: function(opts: Mdns.Options))
  serving_packets(function(query: Dns.Message, _: Net.Packet): {string} return reply(query) end, body)
end

--- The group the responders of these tests join on the loopback: one of a site's own.
local PUBLISHED_AT <const> = "239.255.53.20"

--- Runs `body` beside a responder that publishes `instances` on the loopback, at a port the system
--- chose. `body` is given the options that make a search ask it from a port of the search's own,
--- those that make one ask it as a member of its group, and where it is bound. The responder
--- serves until it is closed, which `serve` answers as true.
local function publishing(instances: {Mdns.Published},
                          body: function(unicast: Mdns.Options, grouped: Mdns.Options, port: integer))
  Poll.run(function()
    local responder <close> = assert(Mdns.responder(instances, { address = PUBLISHED_AT, port = 0,
      via = { LOOPBACK } }))
    local port = assert(responder.address.port)
    local served, why = false, "never ran"
    local answering = Poll.spawn(function()
      served, why = responder:serve()
    end)
    body({ address = LOOPBACK, port = port, timeout_ns = Clock.seconds(10), retry_ns = Clock.ms(200) },
      { listen = "group", address = PUBLISHED_AT, port = port, via = { LOOPBACK }, timeout_ns = Clock.seconds(10),
        retry_ns = Clock.ms(200) }, port)
    assert(responder:close())
    assert(answering:join())
    assert(served, why)
  end)
end

local function test_an_instance_is_assembled_from_one_packet()
  local name = fullname("Printer", HTTP)
  local questions: mut {Dns.Message} = {}
  local function reply(query: Dns.Message): {string}
    questions[#questions + 1] = query
    if not asks(query, HTTP, Dns.PTR) then return {} end
    return {
      response(query, { pointer(HTTP, "Printer") }, {
        srv(name, "printer.local", 631),
        txt(name, { "txtvers=1", "Path=/print" }),
        a("printer.local", "192.0.2.7"),
        aaaa("printer.local", "2001:db8::7"),
      }),
    }
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse("_http._tcp", { ...opts, limit = 1 }))
    assert(#found == 1, tostring(#found))
    local instance = assert(found[1])
    assert(instance.name == "Printer" and instance.fullname == name, instance.fullname)
    assert(instance.host == "printer.local" and instance.port == 631)
    assert(#instance.ipv4 == 1 and instance.ipv4[1] == "192.0.2.7")
    assert(#instance.ipv6 == 1 and instance.ipv6[1] == "2001:db8::7")
    assert(#instance.txt == 2 and instance.txt[2] == "Path=/print")
    assert(instance.attributes["txtvers"] == "1" and instance.attributes["path"] == "/print")
    assert(instance.from == LOOPBACK, instance.from)
  end)
  -- A multicast DNS question, with nothing that asks a responder to answer as it would a member of
  -- the group.
  local query = assert(questions[1])
  local question = assert(query.questions[1])
  assert(not query.response and not query.recursion_desired and #query.questions == 1)
  assert(question.name == HTTP and question.type == Dns.PTR and question.class == Dns.IN)
  assert(not question.unicast_response)
end

local function test_a_service_is_named_with_or_without_its_domain_in_any_case()
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    -- A responder may answer in another case than it was asked in.
    return { response(query, described("_HTTP._TCP.LOCAL", "Printer", "PRINTER.local", 80, "192.0.2.7")) }
  end
  serving(reply, function(opts: Mdns.Options)
    for _, service in ipairs({ "_http._tcp", "_http._tcp.local", "_http._tcp.local.", "_HTTP._Tcp.Local" }) do
      local found = assert(Mdns.browse(service, { ...opts, limit = 1 }))
      local instance = assert(found[1], service)
      assert(instance.name == "Printer" and instance.host == "PRINTER.local" and instance.ipv4[1] == "192.0.2.7")
    end
  end)
end

local function test_a_sub_type_answers_the_instances_of_its_service()
  local sub = "_printer._sub._http._tcp.local"
  local function reply(query: Dns.Message): {string}
    if not asks(query, sub, Dns.PTR) then return {} end
    local name, second = fullname("Printer", HTTP), fullname("Second", HTTP)
    return {
      -- With the records of an instance of the service that does not declare the sub-type. Were it
      -- taken, the search would be full before the second printer came.
      response(query, { { ...at(sub, Dns.PTR), target = name } }, {
        srv(fullname("Plain", HTTP), "plain.local", 81),
        txt(fullname("Plain", HTTP), {}),
        a("plain.local", "192.0.2.8"),
        pointer(HTTP, "Plain"),
        srv(name, "printer.local", 80),
        txt(name, {}),
        a("printer.local", "192.0.2.7"),
      }),
      response(query, { { ...at(sub, Dns.PTR), target = second }, srv(second, "second.local", 82),
        txt(second, {}), a("second.local", "192.0.2.9") }),
    }
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse("_printer._sub._http._tcp", { ...opts, limit = 2 }))
    assert(#found == 2, tostring(#found))
    local instance = assert(found[1])
    assert(instance.fullname == fullname("Printer", HTTP) and instance.port == 80)
    assert(assert(found[2]).name == "Second")
  end)
end

local function test_what_is_no_service_type_is_refused_with_the_reason()
  for _, service in ipairs({ "", "http", "_http", "_http._tcp.example", "http._tcp", "_http._sctp", "a.._tcp",
      "_a._b._http._tcp", "printer._http._tcp.local" }) do
    local found, why = Mdns.browse(service, { timeout_ns = 0 })
    assert(found == nil and why ~= "", service)
  end
end

local function test_an_option_out_of_range_raises_naming_it()
  Test.raises(function() Mdns.browse("_http._tcp", { timeout_ns = -1 }) end, "mdns: timeout_ns must be")
  Test.raises(function() Mdns.browse("_http._tcp", { retry_ns = 0 }) end, "mdns: retry_ns must be")
  Test.raises(function() Mdns.browse("_http._tcp", { settle_ns = -1 }) end, "mdns: settle_ns must be")
  Test.raises(function() Mdns.resolve("printer.local", { settle_ns = -1 }) end, "mdns: settle_ns must be")
  Test.raises(function() Mdns.browse("_http._tcp", { port = 0 }) end, "mdns: port must be")
  Test.raises(function() Mdns.browse("_http._tcp", { port = 65536 }) end, "mdns: port must be")
  Test.raises(function() Mdns.browse("_http._tcp", { limit = 0 }) end, "mdns: limit must be")
  Test.raises(function() Mdns.browse("_http._tcp", { limit = 4097 }) end, "mdns: limit must be")
  Test.raises(function() Mdns.browse("_http._tcp", { limit = 1 << 61 }) end, "mdns: limit must be")
  Test.raises(function() Mdns.resolve("printer.local", { limit = 4097 }) end, "mdns: limit must be")
  Test.raises(function() Mdns.resolve("printer.local", { port = 0 }) end, "mdns: port must be")
end

local function test_records_that_come_before_the_one_they_depend_on_are_asked_for_again()
  local name = fullname("Printer", HTTP)
  local pointers, asked_srv, asked_txt, asked_a = 0, 0, 0, 0
  local function reply(query: Dns.Message): {string}
    local out: mut {string} = {}
    if asks(query, HTTP, Dns.PTR) then
      pointers = pointers + 1
      -- Once only, and back to front: the address before the SRV record that names its host, and
      -- both and the TXT record before the pointer that names the instance. None of the three is
      -- kept.
      if pointers > 1 then return {} end
      local records = described(HTTP, "Printer", "printer.local", 8080, "192.0.2.7")
      for i = #records, 1, -1 do
        local bytes = response(query, { assert(records[i]) })
        out[#out + 1] = bytes
      end
    end
    -- Each is sent again only to the question that asks for it.
    if asks(query, name, Dns.SRV) then
      asked_srv = asked_srv + 1
      local bytes = response(query, { srv(name, "printer.local", 8080) })
      out[#out + 1] = bytes
    end
    if asks(query, name, Dns.TXT) then
      asked_txt = asked_txt + 1
      local bytes = response(query, { txt(name, { "path=/" }) })
      out[#out + 1] = bytes
    end
    if asks(query, "printer.local", Dns.A) then
      asked_a = asked_a + 1
      local bytes = response(query, { a("printer.local", "192.0.2.7") })
      out[#out + 1] = bytes
    end
    return out
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 1 }))
    local instance = assert(found[1])
    assert(instance.port == 8080 and instance.txt[1] == "path=/" and instance.ipv4[1] == "192.0.2.7")
  end)
  assert(asked_srv >= 1 and asked_txt >= 1 and asked_a >= 1, ("%d %d %d"):format(asked_srv, asked_txt, asked_a))
end

local function test_records_an_answer_leaves_out_are_asked_for()
  local name = fullname("Printer", HTTP)
  local asked: mut {string: integer} = {}
  local function count(what: string)
    asked[what] = (asked[what] or 0) + 1
  end
  local function reply(query: Dns.Message): {string}
    local out: mut {string} = {}
    local function answer(what: string, record: Dns.Record)
      count(what)
      local bytes = response(query, { record })
      out[#out + 1] = bytes
    end
    if asks(query, HTTP, Dns.PTR) then answer("ptr", pointer(HTTP, "Printer")) end
    if asks(query, name, Dns.SRV) then answer("srv", srv(name, "printer.local", 631)) end
    if asks(query, name, Dns.TXT) then answer("txt", txt(name, { "a=1" })) end
    if asks(query, "printer.local", Dns.A) then answer("a", a("printer.local", "192.0.2.7")) end
    if asks(query, "printer.local", Dns.AAAA) then
      answer("aaaa", aaaa("printer.local", "fe80::7"))
    end
    return out
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 1 }))
    local instance = assert(found[1])
    assert(instance.host == "printer.local" and instance.port == 631 and instance.attributes["a"] == "1")
    assert(#instance.ipv4 + #instance.ipv6 >= 1)
  end)
  for _, what in ipairs({ "ptr", "srv", "txt", "a", "aaaa" }) do
    local times = asked[what] or 0
    assert(times >= 1, what .. " was never asked for")
  end
end

local function test_a_record_that_never_comes_is_asked_for_three_times_at_most()
  local name = fullname("Printer", HTTP)
  local address_questions, txt_questions = 0, 0
  local function reply(query: Dns.Message): {string}
    if asks(query, "printer.local", Dns.A) then address_questions = address_questions + 1 end
    if asks(query, name, Dns.TXT) then txt_questions = txt_questions + 1 end
    if not asks(query, HTTP, Dns.PTR) then return {} end
    return { response(query, { pointer(HTTP, "Printer"), srv(name, "printer.local", 631) }) }
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, timeout_ns = Clock.ms(900), retry_ns = Clock.ms(20) }))
    -- Its SRV record came, so it is listed, with no TXT string and no address.
    local instance = assert(found[1])
    assert(#found == 1 and instance.host == "printer.local" and #instance.txt == 0)
    assert(#instance.ipv4 == 0 and #instance.ipv6 == 0)
  end)
  -- Each asked for 100 ms after the SRV record, then 20 ms and 40 ms later; the 900 ms have room
  -- for more.
  assert(address_questions >= 1 and address_questions <= 3, tostring(address_questions))
  assert(txt_questions >= 1 and txt_questions <= 3, tostring(txt_questions))
end

local function test_an_instance_name_keeps_its_dots_spaces_and_letters()
  local instance_name = "Caf\xc3\xa9 2.0 \xe2\x80\x94 B\xc3\xbcro. Drucker"
  publishing({
    { service = "_http._tcp", name = instance_name, host = "drucker.local", port = 80, ipv4 = { "192.0.2.9" } },
  }, function(opts: Mdns.Options, _: Mdns.Options, _: integer)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 1 }))
    local instance = assert(found[1])
    assert(instance.name == instance_name, instance.name)
    assert(instance.fullname == "Caf\xc3\xa9 2\\.0 \xe2\x80\x94 B\xc3\xbcro\\. Drucker._http._tcp.local",
      instance.fullname)
    local labels = assert(Dns.labels(instance.fullname))
    assert(#labels == 4 and labels[1] == instance_name)
    assert(instance.host == "drucker.local" and instance.ipv4[1] == "192.0.2.9")
  end)
end

local function test_several_instances_are_listed_in_the_order_they_were_named()
  -- Two of them at one host, and each in a packet of its own, as a responder answers.
  publishing({
    { service = "_http._tcp", name = "First", host = "one.local", port = 80, ipv4 = { "192.0.2.1" } },
    { service = "_http._tcp", name = "Second", host = "one.local", port = 8080, ipv4 = { "192.0.2.1" } },
    { service = "_http._tcp", name = "Third", host = "three.local", port = 80, ipv4 = { "192.0.2.3" } },
  }, function(opts: Mdns.Options, _: Mdns.Options, _: integer)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 3 }))
    assert(#found == 3, tostring(#found))
    local first, second, third = assert(found[1]), assert(found[2]), assert(found[3])
    assert(first.name == "First" and first.port == 80 and first.ipv4[1] == "192.0.2.1")
    assert(second.name == "Second" and second.port == 8080 and second.host == "one.local")
    assert(#second.ipv4 == 1 and second.ipv4[1] == "192.0.2.1")
    assert(third.name == "Third" and third.host == "three.local" and third.ipv4[1] == "192.0.2.3")
  end)
end

--- Outside a run, where the search holds the thread: the questions wait in the silent socket's
--- buffer.
local function test_a_search_nothing_answers_ends_at_its_time_limit_having_asked_again()
  local silent <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
  local started = Clock.monotonic_ns()
  local found = assert(Mdns.browse(HTTP, { address = LOOPBACK, port = assert(silent.address.port),
    timeout_ns = Clock.ms(400), retry_ns = Clock.ms(50) }))
  local elapsed = Clock.monotonic_ns() - started
  assert(#found == 0)
  assert(elapsed >= Clock.ms(400) and elapsed < Clock.seconds(10), tostring(elapsed))
  local questions = 0
  while true do
    local packet = silent:receive(0)
    if packet == nil then break end
    assert(asks(assert(Dns.decode(packet.data)), HTTP, Dns.PTR))
    questions = questions + 1
  end
  -- At 0, 50, 150 and 350 ms where nothing delays the search.
  assert(questions >= 2 and questions <= 4, tostring(questions))
end

local function test_a_time_limit_of_nothing_asks_nothing()
  local silent <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
  local found = assert(Mdns.browse(HTTP, { address = LOOPBACK, port = assert(silent.address.port), timeout_ns = 0 }))
  assert(#found == 0)
  local packet, why = silent:receive(0)
  assert(packet == nil and why == Poll.TIMEOUT, why)
end

--- Datagrams that must add nothing to a browse for `_http._tcp`, as answers to `query`.
local function hostile(query: Dns.Message): {string}
  local name = fullname("Evil", HTTP)
  local whole = described(HTTP, "Evil", "evil.local", 666, "192.0.2.66")
  local forged: Dns.Message = { ...Dns.reply(query), answers = whole }
  local other = "_other._tcp.local"
  -- Just over the 9000 bytes a search reads, and no more: macOS sends no datagram over 9216 bytes
  -- unless told to (net.inet.udp.maxdgram).
  local padding: mut {Dns.Record} = {}
  local oversize = ""
  while #oversize <= 9000 do
    local record = txt(name, { ("x"):rep(60) })
    padding[#padding + 1] = record
    oversize = assert(Dns.encode({ ...forged, additionals = padding }))
  end
  assert(#oversize <= 9216, tostring(#oversize))
  local past: mut {Dns.Record} = {}
  for i, record in ipairs(whole) do
    past[i] = { ...record, ttl = 0 }
  end
  return {
    "",
    "\0",
    ("\xff"):rep(600),
    -- A message cut short.
    response(query, whole):sub(1, 40),
    -- A query that carries records.
    (assert(Dns.encode({ ...forged, response = false }))),
    -- A response to another question, which is what a datagram sent blind to the port is.
    (assert(Dns.encode({ ...forged, id = (query.id + 1) & 0xffff }))),
    (assert(Dns.encode({ ...forged, rcode = 3 }))),
    (assert(Dns.encode({ ...forged, opcode = 4 }))),
    -- Over the 9000 bytes of a multicast DNS message.
    oversize,
    response(query, past),
    -- Of another class than the internet's, where the data of a record means something else.
    response(query, { pointer(HTTP, "Evil"), { ...at("evil.local", Dns.A), class = 3, rdata = "\xc0\x00\x02\x42" } }),
    response(query, { { ...at(HTTP, Dns.PTR), class = 3, rdata = "\4Evil\5_http\4_tcp\5local\0" } }),
    -- The records of an instance of another service.
    response(query, described(other, "Evil", "evil.local", 666, "192.0.2.66")),
    -- Pointers at the service asked for that lead out of it.
    response(query, {
      { ...at(HTTP, Dns.PTR), target = fullname("Evil", other) },
      { ...at(HTTP, Dns.PTR), target = "evil.example.com" },
      { ...at(HTTP, Dns.PTR), target = "a.b._http._tcp.local" },
      { ...at(HTTP, Dns.PTR), target = HTTP },
      { ...at(HTTP, Dns.PTR), target = "Evil._http._tcp.example" },
      { ...at(HTTP, Dns.PTR), target = "Evil._http._tcp.local.example" },
      srv(fullname("Evil", other), "evil.local", 666),
      srv("evil.example.com", "evil.local", 666),
      srv("a.b._http._tcp.local", "evil.local", 666),
      srv("Evil._http._tcp.local.example", "evil.local", 666),
      txt(fullname("Evil", other), { "a=1" }),
      -- An address for a host no SRV record of the service names, and for the real instance's name.
      a("evil.local", "192.0.2.66"),
      a(fullname("Real", HTTP), "192.0.2.66"),
    }),
    -- A pointer at another service that leads into the one asked for, and SRV and TXT records of an
    -- instance no pointer at the service gave.
    response(query, {
      { ...at(other, Dns.PTR), target = fullname("Other", HTTP) },
      srv(fullname("Other", HTTP), "evil.local", 666),
      txt(fullname("Other", HTTP), { "a=1" }),
      srv(fullname("Unnamed", HTTP), "evil.local", 666),
      txt(fullname("Unnamed", HTTP), { "a=1" }),
      a("evil.local", "192.0.2.66"),
    }),
    -- A service that says it is not offered.
    response(query, { pointer(HTTP, "Absent"), srv(fullname("Absent", HTTP), ".", 0) }),
  }
end

--- The search ends at its limit of two, which the last datagram fills: every hostile datagram
--- before it was read, and one that made an instance would have taken the place of a real one.
local function test_hostile_answers_add_no_instance_and_change_nothing_of_a_real_one()
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    local out: mut {string} = {}
    local before = hostile(query)
    table.move(before, 1, #before, 1, out)
    local real = response(query, described(HTTP, "Real", "real.local", 80, "192.0.2.1"))
    out[#out + 1] = real
    -- After the real one: of two SRV or TXT records the first stands.
    local late = response(query, {
      srv(fullname("Real", HTTP), "evil.local", 666),
      txt(fullname("Real", HTTP), { "path=/evil" }),
      a("evil.local", "192.0.2.66"),
    })
    out[#out + 1] = late
    local after = hostile(query)
    table.move(after, 1, #after, #out + 1, out)
    local last = response(query, described(HTTP, "Last", "last.local", 82, "192.0.2.2"))
    out[#out + 1] = last
    return out
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 2 }))
    assert(#found == 2, tostring(#found))
    local instance = assert(found[1])
    assert(instance.name == "Real" and instance.host == "real.local" and instance.port == 80)
    assert(#instance.ipv4 == 1 and instance.ipv4[1] == "192.0.2.1" and #instance.ipv6 == 0)
    assert(#instance.txt == 1 and instance.attributes["path"] == "/")
    assert(assert(found[2]).name == "Last")
  end)
end

local function test_a_flood_of_instances_and_addresses_stops_at_the_bounds()
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    local out: mut {string} = {}
    -- Sixty instances, ten to a packet, and with the first ten sixty addresses of each family for
    -- one host.
    for packet = 0, 5 do
      local records: mut {Dns.Record} = {}
      for n = 100, if packet == 0 then 159 else 99 end do
        local four, six = a("host1.local", "198.51.100." .. tostring(n)), aaaa("host1.local", ("2001:db8::%x"):format(n))
        records[#records + 1] = four
        records[#records + 1] = six
      end
      for i = 1, 10 do
        local n = packet * 10 + i
        local host = ("host%d.local"):format(n)
        for _, record in ipairs(described(HTTP, ("Instance %d"):format(n), host, n, "192.0.2." .. tostring(n))) do
          records[#records + 1] = record
        end
      end
      local bytes = response(query, records)
      out[#out + 1] = bytes
    end
    return out
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 4 }))
    assert(#found == 4, tostring(#found))
    for i, instance in ipairs(found) do
      assert(instance.name == ("Instance %d"):format(i) and instance.port == i, instance.name)
    end
    local first = assert(found[1])
    -- The addresses stand before the SRV record that names their host, in the one message.
    assert(#first.ipv4 == 16 and first.ipv4[1] == "198.51.100.100" and first.ipv4[16] == "198.51.100.115")
    assert(#first.ipv6 == 16 and first.ipv6[16] == "2001:db8::73")
  end)
end

local function test_a_txt_record_of_odd_strings_is_kept_as_it_came()
  local name, bare = fullname("Odd", HTTP), fullname("Bare", HTTP)
  local strings = { "", "=no key", "flag", "k=v=w", "K=second", "bin=\0\xff=", ("long=" .. ("x"):rep(250)) }
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    return {
      response(query, { pointer(HTTP, "Odd"), srv(name, "odd.local", 80), txt(name, strings),
        a("odd.local", "192.0.2.1") }),
      -- A TXT record of no strings is read as one empty string.
      response(query, { pointer(HTTP, "Bare"), srv(bare, "odd.local", 81), txt(bare, {}) }),
    }
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 2 }))
    local odd, plain = assert(found[1]), assert(found[2])
    assert(#odd.txt == #strings)
    for i, text in ipairs(strings) do assert(odd.txt[i] == text, tostring(i)) end
    local keys = 0
    for _ in pairs(odd.attributes) do keys = keys + 1 end
    assert(keys == 4, tostring(keys))
    assert(odd.attributes["flag"] == "" and odd.attributes["k"] == "v=w" and odd.attributes["bin"] == "\0\xff=")
    assert(odd.attributes["long"] == ("x"):rep(250))
    assert(#plain.txt == 1 and plain.txt[1] == "" and next(plain.attributes) == nil)
  end)
end

local function test_found_is_called_once_for_each_instance_of_the_list()
  local late = fullname("Late", HTTP)
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    return {
      -- Named with its SRV record, and no address for its host however often it is asked for.
      response(query, { pointer(HTTP, "Late"), srv(late, "late.local", 81) }),
      -- Named and nothing more: no host, so not in the list.
      response(query, { pointer(HTTP, "Nameless") }),
      response(query, described(HTTP, "Whole", "whole.local", 80, "192.0.2.1")),
    }
  end
  serving(reply, function(opts: Mdns.Options)
    local told: mut {Mdns.Instance} = {}
    local returned = false
    local found = assert(Mdns.browse(HTTP, {
      ...opts,
      timeout_ns = Clock.ms(300),
      found = function(instance: Mdns.Instance)
        assert(not returned)
        told[#told + 1] = instance
      end,
    }))
    returned = true
    -- The whole one as soon as it was whole, the other as the search ended.
    assert(#told == 2, tostring(#told))
    local first, second = assert(told[1]), assert(told[2])
    assert(first.name == "Whole" and first.ipv4[1] == "192.0.2.1" and first.attributes["path"] == "/")
    assert(second.name == "Late" and second.host == "late.local" and #second.ipv4 == 0 and #second.txt == 0)
    assert(#found == 2 and assert(found[1]).name == "Late" and assert(found[2]).name == "Whole")
  end)
end

local function test_what_found_raises_the_search_raises()
  publishing({
    { service = "_http._tcp", name = "Whole", host = "whole.local", port = 80, ipv4 = { "192.0.2.1" } },
  }, function(opts: Mdns.Options, _: Mdns.Options, _: integer)
    local why = Test.raises(function()
      Mdns.browse(HTTP, { ...opts, found = function(_: Mdns.Instance) error("no more", 0) end })
    end, "no more")
    assert(why == "no more", why)
  end)
end

local function test_a_cancelled_tasks_search_ends_at_once_with_cancelled()
  Poll.run(function()
    local silent <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
    local started = Clock.monotonic_ns()
    local found: {Mdns.Instance}?
    local why = "never ran"
    local search = Poll.spawn(function()
      found, why = Mdns.browse(HTTP, { address = LOOPBACK, port = assert(silent.address.port),
        timeout_ns = Clock.seconds(20) })
    end)
    -- Long enough for the search to be waiting for an answer.
    assert(Poll.delay(Clock.ms(50)))
    search:cancel()
    assert(search:join(Clock.seconds(10)))
    assert(found == nil and why == Poll.CANCELLED, why)
    assert(Clock.monotonic_ns() - started < Clock.seconds(10))
  end)
end

local function test_other_tasks_go_on_while_a_search_waits()
  Poll.run(function()
    local silent <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
    local ticks = 0
    local ticking = true
    local ticker = Poll.spawn(function()
      while ticking do
        ticks = ticks + 1
        assert(Poll.delay(Clock.ms(10)))
      end
    end)
    local found = assert(Mdns.browse(HTTP, { address = LOOPBACK, port = assert(silent.address.port),
      timeout_ns = Clock.ms(200) }))
    ticking = false
    assert(ticker:join())
    assert(#found == 0 and ticks >= 3, tostring(ticks))
  end)
end

--- Runs `body` beside a responder that is a member of `group` on the loopback, at a port the kernel
--- chose, and sends what `reply` gives for each query to the group from that port, as a responder
--- sends from port 5353. `body` is given the options that make a search listen as a member of the
--- same group.
local function serving_group(group: string, reply: Reply, body: function(opts: Mdns.Options))
  Poll.run(function()
    local device <close> = assert(Net.datagram(Net.udp(group, 0), { shared = true }))
    local port = assert(device.address.port)
    assert(device:join(group, LOOPBACK))
    local out <close> = assert(Net.datagram(Net.udp(LOOPBACK, port), { shared = true }))
    assert(out:set_multicast({ via = LOOPBACK, hops = 1, loop = true }))
    local responder = Poll.spawn(function()
      while true do
        local packet = device:receive()
        if packet == nil then return end
        local query = Dns.decode(packet.data)
        -- The group carries the responder's own answers back to it.
        if query ~= nil and not query.response then
          for _, bytes in ipairs(reply(query)) do assert(out:send(bytes, Net.udp(group, port))) end
        end
      end
    end)
    body({ listen = "group", address = group, port = port, via = { LOOPBACK }, timeout_ns = Clock.seconds(10),
      retry_ns = Clock.ms(200) })
    assert(device:close())
    assert(responder:join())
  end)
end

--- An announcement of `records`, as a responder sends one to the group: no question and the id 0.
local function announcement(query: Dns.Message, records: {Dns.Record}): string
  local message: Dns.Message = { ...Dns.reply(query), id = 0, questions = {}, authoritative = true,
    answers = records }
  return (assert(Dns.encode(message)))
end

local function test_listening_by_group_hears_the_answers_sent_to_the_group()
  local questions: mut {Dns.Message} = {}
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    questions[#questions + 1] = query
    return { announcement(query, described(HTTP, "Printer", "printer.local", 631, "192.0.2.7")) }
  end
  serving_group("239.255.53.1", reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 1 }))
    local instance = assert(found[1])
    assert(instance.name == "Printer" and instance.port == 631 and instance.ipv4[1] == "192.0.2.7")
    assert(instance.from == LOOPBACK, instance.from)
  end)
  -- A member asks with the id of multicast DNS and wants its answer at the group.
  local query = assert(questions[1])
  assert(query.id == 0 and not assert(query.questions[1]).unicast_response)
end

--- 192.0.2.0/24 is for documentation: no interface has an address of it, so the group is not joined
--- there and no question leaves by it.
local function test_an_interface_that_refuses_is_passed_over_while_another_takes_the_question()
  Poll.run(function()
    local group = "239.255.53.4"
    local responder <close> = assert(Mdns.responder({
      { service = "_http._tcp", name = "Printer", host = "printer.local", port = 631, ipv4 = { "192.0.2.7" } },
    }, { address = group, port = 0, via = { "192.0.2.77", LOOPBACK, "192.0.2.78" } }))
    local answering = Poll.spawn(function() assert(responder:serve()) end)
    local found = assert(Mdns.browse(HTTP, { listen = "group", address = group, port = assert(responder.address.port),
      via = { "192.0.2.77", LOOPBACK, "192.0.2.78" }, limit = 1, timeout_ns = Clock.seconds(10),
      retry_ns = Clock.ms(200) }))
    assert(assert(found[1]).name == "Printer")
    assert(responder:close())
    assert(answering:join())
  end)
end

--- A port the kernel just gave out and nothing holds any more.
local function free_port(): integer
  local taken <close> = assert(Net.datagram(Net.udp("0.0.0.0", 0)))
  return (assert(taken.address.port))
end

--- Whether nothing holds `port`: a socket that does not share binds it only then, since a search's
--- own shares.
local function is_free(port: integer): boolean
  local alone, _ = Net.datagram(Net.udp("0.0.0.0", port))
  if alone == nil then return false end
  assert(alone:close())
  return true
end

--- Answers each question that reaches `device` twice: first from `elsewhere`, another port, with records
--- that lie, then from `from` with the true ones, both sent to `to`, or to whoever asked.
local function answering_twice(device: Net.Datagram, elsewhere: Net.Datagram, from: Net.Datagram, to?: Net.Address)
  while true do
    local packet = device:receive()
    if packet == nil then return end
    local query = assert(Dns.decode(packet.data))
    if not query.response then
      -- The id is right: only where it comes from tells the first from the second.
      local forged = response(query, described(HTTP, "Elsewhere", "printer.local", 666, "192.0.2.66"))
      assert(elsewhere:send(forged, to or packet.address))
      local real = response(query, described(HTTP, "Printer", "printer.local", 631, "192.0.2.7"))
      assert(from:send(real, to or packet.address))
    end
  end
end

local function test_a_response_from_another_port_than_the_one_asked_is_ignored()
  Poll.run(function()
    local device <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
    local elsewhere <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
    local responder = Poll.spawn(function() answering_twice(device, elsewhere, device) end)
    local opts: Mdns.Options = { address = LOOPBACK, port = assert(device.address.port),
      timeout_ns = Clock.seconds(10) }
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 1 }))
    assert(#found == 1 and assert(found[1]).name == "Printer", assert(found[1]).name)
    local addresses = assert(Mdns.resolve("printer.local", opts))
    assert(#addresses == 1 and assert(addresses[1]).address == "192.0.2.7", tostring(#addresses))
    assert(device:close())
    assert(responder:join())
  end)
end

local function test_listening_by_group_a_response_from_another_port_is_ignored()
  local group = "239.255.53.8"
  Poll.run(function()
    local device <close> = assert(Net.datagram(Net.udp(group, 0), { shared = true }))
    local port = assert(device.address.port)
    assert(device:join(group, LOOPBACK))
    local out <close> = assert(Net.datagram(Net.udp(LOOPBACK, port), { shared = true }))
    local elsewhere <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
    assert(out:set_multicast({ via = LOOPBACK, hops = 1, loop = true }))
    assert(elsewhere:set_multicast({ via = LOOPBACK, hops = 1, loop = true }))
    local responder = Poll.spawn(function()
      answering_twice(device, elsewhere, out, Net.udp(group, port))
    end)
    local found = assert(Mdns.browse(HTTP, { listen = "group", address = group, port = port, via = { LOOPBACK },
      limit = 1, timeout_ns = Clock.seconds(10) }))
    assert(device:close())
    assert(responder:join())
    assert(#found == 1 and assert(found[1]).name == "Printer", assert(found[1]).name)
  end)
end

--- The port is free, so the socket is bound and it is the join that fails: its reason says the
--- group first, where a socket that cannot be bound says the address and port. The socket is closed
--- again.
local function test_listening_by_group_fails_where_the_group_cannot_be_joined()
  local port = free_port()
  -- No group at all.
  local unjoined, why = Mdns.browse(HTTP, { listen = "group", address = LOOPBACK, port = port, timeout_ns = 0 })
  assert(unjoined == nil and why:find(LOOPBACK .. ": ", 1, true) == 1, why)
  assert(is_free(port))
  -- 192.0.2.0/24 is for documentation: no interface has an address of it.
  local group = "239.255.53.2"
  local nowhere, nowhere_why = Mdns.browse(HTTP, { listen = "group", address = group,
    via = { "192.0.2.77" }, port = port, timeout_ns = 0 })
  assert(nowhere == nil and nowhere_why:find(group .. ": ", 1, true) == 1, nowhere_why)
  assert(is_free(port))
end

local function test_listening_by_group_fails_where_the_port_is_held_unshared()
  local holder <close> = assert(Net.datagram(Net.udp("0.0.0.0", 0)))
  local port = assert(holder.address.port)
  local found, why = Mdns.browse(HTTP, { listen = "group", address = "239.255.53.5", via = { LOOPBACK },
    port = port, timeout_ns = 0 })
  assert(found == nil and why:find("0.0.0.0:" .. tostring(port) .. ": ", 1, true) == 1, why)
end

--- Listening by "unicast" the search's socket shares its port with none, so the port is free again only
--- once that socket is closed.
local function test_the_socket_is_closed_when_found_raises()
  Poll.run(function()
    local device <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
    local asked_from = 0
    local responder = Poll.spawn(function()
      while true do
        local packet = device:receive()
        if packet == nil then return end
        local query = assert(Dns.decode(packet.data))
        asked_from = assert(packet.address.port)
        assert(device:send(response(query, described(HTTP, "Printer", "printer.local", 631, "192.0.2.7")),
          packet.address))
      end
    end)
    local free_meanwhile = true
    Test.raises(function()
      Mdns.browse(HTTP, { address = LOOPBACK, port = assert(device.address.port), timeout_ns = Clock.seconds(10),
        found = function(_: Mdns.Instance)
          free_meanwhile = is_free(asked_from)
          error("no more", 0)
        end })
    end, "no more")
    assert(device:close())
    assert(responder:join())
    -- Held while the search went on, so the check can tell, and not after.
    assert(asked_from > 0 and not free_meanwhile and is_free(asked_from))
  end)
end

local function test_the_socket_is_closed_when_the_search_is_cancelled()
  local port = free_port()
  Poll.run(function()
    local why = "never ran"
    local search = Poll.spawn(function()
      local _found: {Mdns.Instance}?
      _found, why = Mdns.browse(HTTP, { listen = "group", address = "239.255.53.7", via = { LOOPBACK },
        port = port, timeout_ns = Clock.seconds(20) })
    end)
    assert(Poll.delay(Clock.ms(50)))
    assert(not is_free(port))
    search:cancel()
    assert(search:join(Clock.seconds(10)))
    assert(why == Poll.CANCELLED, why)
    assert(is_free(port))
  end)
end

local function test_a_hosts_addresses_are_resolved_and_the_search_ends_soon_after()
  local questions: mut {Dns.Message} = {}
  local function reply(query: Dns.Message): {string}
    questions[#questions + 1] = query
    local out: mut {string} = {}
    if asks(query, "Printer.local", Dns.AAAA) then
      local bytes = response(query, { aaaa("printer.local", "2001:db8::7"), a("other.local", "192.0.2.66") })
      out[#out + 1] = bytes
    end
    if asks(query, "printer.local", Dns.A) then
      local bytes = response(query, { a("PRINTER.LOCAL", "192.0.2.7"), a("printer.local", "192.0.2.8") })
      out[#out + 1] = bytes
    end
    return out
  end
  serving(reply, function(opts: Mdns.Options)
    local started = Clock.monotonic_ns()
    local addresses = assert(Mdns.resolve("printer.local.", opts))
    assert(Clock.monotonic_ns() - started < Clock.seconds(9))
    assert(#addresses == 3, tostring(#addresses))
    local first, second, third = assert(addresses[1]), assert(addresses[2]), assert(addresses[3])
    assert(first.address == "192.0.2.7" and first.family == "ipv4")
    assert(second.address == "192.0.2.8" and second.family == "ipv4")
    assert(third.address == "2001:db8::7" and third.family == "ipv6")
  end)
  local query = assert(questions[1])
  assert(#query.questions == 2 and asks(query, "printer.local", Dns.A) and asks(query, "printer.local", Dns.AAAA))
  assert(not assert(query.questions[1]).unicast_response)
end

local function test_a_host_nothing_answers_for_resolves_to_no_address()
  local silent <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
  local addresses = assert(Mdns.resolve("nobody.local", { address = LOOPBACK, port = assert(silent.address.port),
    timeout_ns = Clock.ms(200), retry_ns = Clock.ms(20) }))
  assert(#addresses == 0)
  local questions = 0
  while true do
    local packet = silent:receive(0)
    if packet == nil then break end
    questions = questions + 1
  end
  -- At 0, 20 and 60 ms, and no more in the time left.
  assert(questions >= 1 and questions <= 3, tostring(questions))
end

local function test_a_name_outside_the_local_domain_is_not_resolved()
  for _, name in ipairs({ "printer.example.com", "local", "printer", "", "a..local" }) do
    local addresses, why = Mdns.resolve(name, { timeout_ns = 0 })
    assert(addresses == nil and why ~= "", name)
  end
end

--- A group asked with no `via`: the interfaces are those the system lists, or its own choice where
--- it lists none, as a sandboxed worker's does not. With no time to search in, nothing is sent by
--- any of them.
local function test_a_search_with_no_via_is_made_whether_or_not_the_interfaces_are_listed()
  local found = assert(Mdns.browse(HTTP, { address = "239.255.53.3", port = 5399, timeout_ns = 0 }))
  assert(#found == 0)
end

--- The strings of a TXT record that is `bytes` long with a byte for the length of each: `count` of
--- them, the first ones as long as a string may be.
local function strings_of(count: integer, bytes: integer): {string}
  local out: mut {string} = {}
  local left = bytes - count
  for i = 1, count do
    local length = math.min(left, 255)
    out[i] = ("x"):rep(length)
    left = left - length
  end
  assert(left == 0, "the strings hold the bytes")
  return out
end

--- Each name's first TXT record is past what a search keeps, by one string or by one byte, and is
--- not kept in part: the record that answers the question for it is the one the instance has.
local function test_a_txt_record_past_the_cap_is_ignored_whole()
  local many, long, fits = fullname("Many", HTTP), fullname("Long", HTTP), fullname("Fits", HTTP)
  local function reply(query: Dns.Message): {string}
    local out: mut {string} = {}
    if asks(query, HTTP, Dns.PTR) then
      local bytes = response(query, {
        pointer(HTTP, "Many"), srv(many, "txt.local", 1), txt(many, strings_of(129, 129)),
        pointer(HTTP, "Long"), srv(long, "txt.local", 2), txt(long, strings_of(6, 1301)),
        pointer(HTTP, "Fits"), srv(fits, "txt.local", 3), txt(fits, strings_of(128, 1300)),
        a("txt.local", "192.0.2.1"),
      })
      out[#out + 1] = bytes
    end
    if asks(query, many, Dns.TXT) then
      local bytes = response(query, { txt(many, { "ok=1" }) })
      out[#out + 1] = bytes
    end
    if asks(query, long, Dns.TXT) then
      local bytes = response(query, { txt(long, { "ok=2" }) })
      out[#out + 1] = bytes
    end
    return out
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 3 }))
    assert(#found == 3, tostring(#found))
    local first, second, third = assert(found[1]), assert(found[2]), assert(found[3])
    assert(#first.txt == 1 and first.txt[1] == "ok=1", tostring(#first.txt))
    assert(#second.txt == 1 and second.txt[1] == "ok=2", tostring(#second.txt))
    assert(#third.txt == 128 and #assert(third.txt[1]) == 255, tostring(#third.txt))
  end)
end

--- Sixteen instances, each with as much as a search keeps for one: a name and a host name of long
--- labels, a TXT record of 128 strings with a key each in 1300 bytes, and 16 addresses of each
--- family. The module's doc says 12 KiB an instance at most.
local function test_what_a_search_keeps_for_an_instance_is_within_the_bound_it_states()
  local count = 16
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    local out: mut {string} = {}
    for n = 1, count do
      local instance = ("%02d"):format(n) .. ("i"):rep(61)
      local host = ("%02d"):format(n) .. ("h"):rep(58) .. "." .. ("h"):rep(60) .. ".local"
      local strings: mut {string} = {}
      for i = 1, 128 do strings[i] = ("k%03d=xxxx"):format(i) end
      local records: mut {Dns.Record} = { pointer(HTTP, instance), srv(fullname(instance, HTTP), host, n),
        txt(fullname(instance, HTTP), strings) }
      for i = 1, 16 do
        local four, six = a(host, ("198.51.%d.%d"):format(n, i)), aaaa(host, ("2001:db8:%x::%x"):format(n, i))
        records[#records + 1] = four
        records[#records + 1] = six
      end
      local bytes = response(query, records)
      out[#out + 1] = bytes
    end
    return out
  end
  serving(reply, function(opts: Mdns.Options)
    collectgarbage()
    collectgarbage()
    local before = collectgarbage("count")
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = count }))
    collectgarbage()
    collectgarbage()
    local kept = collectgarbage("count") - before
    assert(#found == count, tostring(#found))
    local last = assert(found[count])
    assert(#last.txt == 128 and #last.ipv4 == 16 and #last.ipv6 == 16 and last.attributes["k128"] == "xxxx")
    assert(kept < 12 * count, ("%.0f kilobytes for %d instances"):format(kept, count))
  end)
end

--- Pointers at the service asked for that lead to `count` names from `first` on, which nothing
--- describes.
local function pointers_to_nothing(first: integer, count: integer): {Dns.Record}
  local out: mut {Dns.Record} = {}
  for n = first, first + count - 1 do
    local record = pointer(HTTP, ("Nothing %d"):format(n))
    out[#out + 1] = record
  end
  return out
end

--- Three hundred and twenty names that never get an SRV record come first. The 64 a search lets
--- wait are taken, and the real instance, whose SRV record comes with its pointer, is held all the
--- same.
local function test_a_flood_of_pointers_to_nothing_keeps_no_real_instance_out()
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    local out: mut {string} = {}
    for packet = 0, 7 do
      local bytes = response(query, pointers_to_nothing(packet * 40, 40))
      out[#out + 1] = bytes
    end
    local real = response(query, described(HTTP, "Real", "real.local", 80, "192.0.2.1"))
    out[#out + 1] = real
    return out
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 1 }))
    assert(#found == 1 and assert(found[1]).name == "Real")
  end)
end

--- What a flood's questions asked: how many for a missing record, and of how many names.
local record Asked
  mut questions: integer
  mut distinct: integer
end

--- Answers every question for the service with 320 pointers to nothing, counting in `asked` the
--- questions for anything else.
local function flood_counting(asked: Asked): Reply
  local names: mut {string: boolean} = {}
  return function(query: Dns.Message): {string}
    for _, question in ipairs(query.questions) do
      if question.type ~= Dns.PTR then
        asked.questions = asked.questions + 1
        if names[question.name] == nil then
          names[question.name] = true
          asked.distinct = asked.distinct + 1
        end
      end
    end
    if not asks(query, HTTP, Dns.PTR) then return {} end
    local out: mut {string} = {}
    for packet = 0, 7 do
      local bytes = response(query, pointers_to_nothing(packet * 40, 40))
      out[#out + 1] = bytes
    end
    return out
  end
end

--- Of the 320 names of a flood, a search asks about the 64 it lets wait and no other. The search
--- ends before a name has been asked for three times, so none is forgotten and none takes
--- another's place, however slow the host: a name is asked for once, a tenth of a second after it
--- comes, and again only after `retry_ns`, which is longer than the search.
local function test_a_flood_of_pointers_to_nothing_has_64_names_asked_about()
  local asked: Asked = { questions = 0, distinct = 0 }
  serving(flood_counting(asked), function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 2, timeout_ns = Clock.seconds(1),
      retry_ns = Clock.seconds(5) }))
    assert(#found == 0)
  end)
  assert(asked.distinct >= 1 and asked.distinct <= 64, tostring(asked.distinct))
  assert(asked.questions == asked.distinct, tostring(asked.questions))
end

--- The same flood with every repeat of the question, and time for each name to be asked for three
--- times and forgotten, more than once. Which names take the places of those forgotten depends on
--- when each datagram is read, so only the total is held: the questions asked for missing records
--- are four for each instance the search may hold, 4 * (2 + 64), however many names were asked
--- about.
local function test_a_flood_of_pointers_to_nothing_draws_a_bounded_number_of_questions()
  local asked: Asked = { questions = 0, distinct = 0 }
  serving(flood_counting(asked), function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 2, timeout_ns = Clock.ms(700),
      retry_ns = Clock.ms(20) }))
    assert(#found == 0)
  end)
  assert(asked.questions >= 1 and asked.questions <= 4 * (2 + 64), tostring(asked.questions))
  assert(asked.distinct <= asked.questions, tostring(asked.distinct))
end

--- A hundred and twenty datagrams wait in the search's socket, then the real answer. A search that
--- read them all in one turn would give the other task no turn between the last sent and the
--- instance found.
local function test_another_task_has_its_turns_while_a_search_reads_a_flood()
  local ticks, ticks_when_sent, ticks_when_found = 0, -1, -1
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) or ticks_when_sent >= 0 then return {} end
    local out: mut {string} = {}
    for i = 1, 120 do out[i] = "x" end
    local real = response(query, described(HTTP, "Real", "real.local", 80, "192.0.2.1"))
    out[#out + 1] = real
    ticks_when_sent = ticks
    return out
  end
  serving(reply, function(opts: Mdns.Options)
    local ticking = true
    local ticker = Poll.spawn(function()
      while ticking do
        ticks = ticks + 1
        assert(Poll.delay(0))
      end
    end)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 1, found = function(_: Mdns.Instance)
      ticks_when_found = ticks
    end }))
    ticking = false
    assert(ticker:join())
    assert(#found == 1 and ticks_when_sent >= 0 and ticks_when_found >= 0)
    -- A turn for every 16 datagrams read is 7 of them.
    assert(ticks_when_found - ticks_when_sent >= 4, ("%d then %d"):format(ticks_when_sent, ticks_when_found))
  end)
end

--- The time limit alone: a search whose socket is filled again at every turn it gives away still ends on
--- time. That it gives turns away is the test above; the flooder here would have them without.
local function test_a_flood_that_never_stops_does_not_outlast_the_time_limit()
  Poll.run(function()
    local device <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
    local flooding = true
    local sent = 0
    local flooder = Poll.spawn(function()
      local packet = assert(device:receive())
      while flooding do
        for _ = 1, 50 do assert(device:send("x", packet.address)) end
        sent = sent + 50
        assert(Poll.delay(0))
      end
    end)
    local started = Clock.monotonic_ns()
    local found = assert(Mdns.browse(HTTP, { address = LOOPBACK, port = assert(device.address.port),
      timeout_ns = Clock.ms(200) }))
    local elapsed = Clock.monotonic_ns() - started
    flooding = false
    assert(flooder:join())
    assert(#found == 0 and sent >= 50, tostring(sent))
    assert(elapsed >= Clock.ms(200) and elapsed < Clock.seconds(10), tostring(elapsed))
  end)
end

--- Sixty-four names that lead nowhere take every place a search has for a name that waits, so the
--- real instance, which is named with no SRV record, has none. They are forgotten once their
--- questions have had their time, and it is taken the next time it is named.
local function test_names_that_wait_in_vain_are_forgotten_and_make_room()
  local alone = fullname("Alone", HTTP)
  local pointers = 0
  local function reply(query: Dns.Message): {string}
    local out: mut {string} = {}
    if asks(query, HTTP, Dns.PTR) then
      pointers = pointers + 1
      local named = pointer(HTTP, "Alone")
      local records: {Dns.Record} = { named }
      if pointers == 1 then
        local flood: mut {Dns.Record} = {}
        for _, record in ipairs(pointers_to_nothing(0, 64)) do flood[#flood + 1] = record end
        flood[#flood + 1] = named
        records = flood
      end
      local bytes = response(query, records)
      out[#out + 1] = bytes
    end
    if asks(query, alone, Dns.SRV) then
      local bytes = response(query, { srv(alone, "alone.local", 80), txt(alone, {}), a("alone.local", "192.0.2.1") })
      out[#out + 1] = bytes
    end
    return out
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 1, timeout_ns = Clock.seconds(5),
      retry_ns = Clock.ms(20) }))
    assert(#found == 1 and assert(found[1]).name == "Alone")
  end)
  assert(pointers >= 2, tostring(pointers))
end

--- The largest limit there is: the count of questions a search may ask is worked out from it, and the
--- records an answer left out are still asked for.
local function test_a_search_at_the_largest_limit_still_asks_for_what_is_missing()
  local name = fullname("Printer", HTTP)
  local function reply(query: Dns.Message): {string}
    local out: mut {string} = {}
    if asks(query, HTTP, Dns.PTR) then
      local bytes = response(query, { pointer(HTTP, "Printer") })
      out[#out + 1] = bytes
    end
    if asks(query, name, Dns.SRV) then
      local bytes = response(query, { srv(name, "printer.local", 631), txt(name, {}) })
      out[#out + 1] = bytes
    end
    if asks(query, "printer.local", Dns.A) then
      local bytes = response(query, { a("printer.local", "192.0.2.7") })
      out[#out + 1] = bytes
    end
    return out
  end
  serving(reply, function(opts: Mdns.Options)
    local seen = false
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 4096, timeout_ns = Clock.seconds(2),
      found = function(instance: Mdns.Instance)
        seen = #instance.ipv4 == 1
      end }))
    assert(#found == 1 and assert(found[1]).ipv4[1] == "192.0.2.7" and seen)
  end)
end

--- The one instance the search may answer has its place, with no TXT record and no address, so the search
--- goes on. The names that come after can never be given a host: none is held, and none is asked about.
local function test_a_search_that_holds_its_limit_takes_and_asks_for_no_new_name()
  local name = fullname("Real", HTTP)
  local asked_for_nothing = 0
  local function reply(query: Dns.Message): {string}
    for _, question in ipairs(query.questions) do
      if question.name:find("Nothing", 1, true) ~= nil then
        asked_for_nothing = asked_for_nothing + 1
      end
    end
    if not asks(query, HTTP, Dns.PTR) then return {} end
    return {
      -- Named before the real one has its place, in the one message, and after.
      response(query, { pointer(HTTP, "Nothing 0"), pointer(HTTP, "Real"), srv(name, "real.local", 80) }),
      response(query, pointers_to_nothing(1, 40)),
    }
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 1, timeout_ns = Clock.ms(500),
      retry_ns = Clock.ms(50) }))
    assert(#found == 1 and assert(found[1]).name == "Real")
  end)
  assert(asked_for_nothing == 0, tostring(asked_for_nothing))
end

--- One datagram holds the question for each type, and every datagram of the search comes from one
--- port: one socket asks for them all.
local function test_several_service_types_are_asked_in_one_message_from_one_socket()
  local questions: mut {Dns.Message} = {}
  local ports: mut {integer: boolean} = {}
  local function reply(query: Dns.Message, packet: Net.Packet): {string}
    questions[#questions + 1] = query
    ports[assert(packet.address.port)] = true
    local out: mut {string} = {}
    if asks(query, HTTP, Dns.PTR) then
      local bytes = response(query, described(HTTP, "Web", "one.local", 80, "192.0.2.1"))
      out[#out + 1] = bytes
    end
    if asks(query, IPP, Dns.PTR) then
      local bytes = response(query, described(IPP, "Printer", "two.local", 631, "192.0.2.2"))
      out[#out + 1] = bytes
    end
    return out
  end
  serving_packets(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse({ "_http._tcp", "_IPP._tcp.local" }, { ...opts, limit = 2 }))
    assert(#found == 2, tostring(#found))
    local first, second = assert(found[1]), assert(found[2])
    assert(first.name == "Web" and first.service == "_http._tcp" and first.port == 80, first.service)
    assert(second.name == "Printer" and second.service == "_IPP._tcp.local", second.service)
    assert(second.fullname == fullname("Printer", IPP) and second.ipv4[1] == "192.0.2.2", second.fullname)
  end)
  local query = assert(questions[1])
  assert(#query.questions == 2 and asks(query, HTTP, Dns.PTR) and asks(query, IPP, Dns.PTR))
  local asked_from = 0
  for _ in pairs(ports) do asked_from = asked_from + 1 end
  assert(asked_from == 1, tostring(asked_from))
end

--- The sub-type `n` of 32 whose names are near a hundred bytes each, and the service it is of.
local function long_type(n: integer): string, string
  local service = ("_%s%02d._tcp.local"):format(("a"):rep(12), n)
  return ("_%s%02d._sub.%s"):format(("s"):rep(58), n, service), service
end

--- Thirty-two types are over three thousand bytes of questions, which go in several messages, none
--- longer than a frame of an Ethernet carries. Only the last type has an instance, so the search
--- ends having asked for every one.
local function test_the_most_service_types_are_asked_in_messages_of_a_frames_size()
  local types: mut {string} = {}
  for n = 1, 32 do
    local sub, _ = long_type(n)
    types[#types + 1] = sub
  end
  local last, service = long_type(32)
  local name = fullname("Printer", service)
  local asked: mut {string: boolean} = {}
  local longest, most = 0, 0
  local function reply(query: Dns.Message, packet: Net.Packet): {string}
    longest = math.max(longest, #packet.data)
    most = math.max(most, #query.questions)
    for _, question in ipairs(query.questions) do
      if question.type == Dns.PTR then asked[question.name:lower()] = true end
    end
    if not asks(query, last, Dns.PTR) then return {} end
    return { response(query, { { ...at(last, Dns.PTR), target = name }, srv(name, "printer.local", 631),
      txt(name, {}), a("printer.local", "192.0.2.7") }) }
  end
  serving_packets(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(types, { ...opts, limit = 1 }))
    local instance = assert(found[1])
    assert(#found == 1 and instance.service == last and instance.fullname == name, instance.service)
  end)
  for _, one in ipairs(types) do assert(asked[one] == true, one) end
  assert(most > 1 and longest > 0 and longest <= 1500, ("%d questions, %d bytes"):format(most, longest))
end

local function test_a_list_that_is_no_list_of_service_types_is_refused_with_the_reason()
  local none: {string} = {}
  local many: mut {string} = {}
  for n = 1, 33 do many[n] = ("_t%d._tcp"):format(n) end
  for at_case, list in ipairs({ none, many, { "_http._tcp", "http" } }) do
    local found, why = Mdns.browse(list, { timeout_ns = 0 })
    assert(found == nil and why:find("mdns: ", 1, true) == 1, tostring(at_case) .. ": " .. why)
  end
  -- Thirty-two are taken: the search is made, with no time to ask in.
  table.remove(many)
  local silent <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
  assert(#assert(Mdns.browse(many, { address = LOOPBACK, port = assert(silent.address.port), timeout_ns = 0 })) == 0)
end

local function test_a_service_type_written_twice_is_asked_for_once()
  local questions: mut {Dns.Message} = {}
  local function reply(query: Dns.Message): {string}
    questions[#questions + 1] = query
    if not asks(query, HTTP, Dns.PTR) then return {} end
    return { response(query, described(HTTP, "Web", "one.local", 80, "192.0.2.1")) }
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse({ "_http._tcp", "_HTTP._tcp.local.", "_http._tcp" }, { ...opts, limit = 2,
      settle_ns = 0 }))
    assert(#found == 1 and assert(found[1]).service == "_http._tcp", tostring(#found))
  end)
  assert(#assert(questions[1]).questions == 1)
end

--- Both types are asked for, and a pointer at one leads to a name of the other with all its
--- records. Were it taken, it would have a place of the two before the printer came.
local function test_a_pointer_at_one_service_asked_for_makes_no_instance_of_another()
  local crossed = fullname("Crossed", IPP)
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    return {
      response(query, { { ...at(HTTP, Dns.PTR), target = crossed }, srv(crossed, "evil.local", 666),
        txt(crossed, { "a=1" }), a("evil.local", "192.0.2.66") }),
      response(query, described(HTTP, "Web", "one.local", 80, "192.0.2.1")),
      response(query, described(IPP, "Printer", "two.local", 631, "192.0.2.2")),
    }
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse({ HTTP, IPP }, { ...opts, limit = 2 }))
    assert(#found == 2, tostring(#found))
    local first, second = assert(found[1]), assert(found[2])
    assert(first.name == "Web" and first.service == HTTP and second.name == "Printer" and second.service == IPP)
  end)
end

--- A sub-type and its service both name the printer. It has one place of the two, as one of the
--- type whose pointer came first, or the second instance would not be in the list.
local function test_an_instance_two_service_types_name_is_listed_once()
  local sub = "_printer._sub._http._tcp"
  local name = fullname("Printer", HTTP)
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    return {
      response(query, { pointer(HTTP, "Printer") }),
      response(query, { { ...at(sub .. ".local", Dns.PTR), target = name }, srv(name, "printer.local", 80),
        txt(name, {}), a("printer.local", "192.0.2.7") }),
      response(query, described(HTTP, "Second", "second.local", 82, "192.0.2.9")),
    }
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse({ sub, "_http._tcp" }, { ...opts, limit = 2 }))
    assert(#found == 2, tostring(#found))
    local first, second = assert(found[1]), assert(found[2])
    assert(first.name == "Printer" and first.service == "_http._tcp" and first.port == 80, first.service)
    assert(second.name == "Second" and second.service == "_http._tcp")
  end)
end

--- Nothing answers for the second type. Without `settle_ns` the search would wait its ten seconds
--- for it.
local function test_settle_ns_ends_the_search_after_the_first_whole_instance()
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    return { response(query, described(HTTP, "Only", "only.local", 80, "192.0.2.1")) }
  end
  serving(reply, function(opts: Mdns.Options)
    local started = Clock.monotonic_ns()
    local found = assert(Mdns.browse({ HTTP, IPP }, { ...opts, settle_ns = Clock.ms(50) }))
    assert(Clock.monotonic_ns() - started < Clock.seconds(9))
    assert(#found == 1 and assert(found[1]).name == "Only", tostring(#found))
  end)
end

--- The instance is named with its SRV record, and its TXT record and address come only to the
--- questions for them. A search that counted from the name or the SRV record would end, with no
--- time to settle in, before either came.
local function test_settle_ns_counts_from_an_instance_that_is_whole()
  local name = fullname("Printer", HTTP)
  local function reply(query: Dns.Message): {string}
    local out: mut {string} = {}
    if asks(query, HTTP, Dns.PTR) then
      local bytes = response(query, { pointer(HTTP, "Printer"), srv(name, "printer.local", 631) })
      out[#out + 1] = bytes
    end
    if asks(query, name, Dns.TXT) then
      local bytes = response(query, { txt(name, { "a=1" }) })
      out[#out + 1] = bytes
    end
    if asks(query, "printer.local", Dns.A) then
      local bytes = response(query, { a("printer.local", "192.0.2.7") })
      out[#out + 1] = bytes
    end
    return out
  end
  serving(reply, function(opts: Mdns.Options)
    local started = Clock.monotonic_ns()
    local found = assert(Mdns.browse(HTTP, { ...opts, settle_ns = 0 }))
    assert(Clock.monotonic_ns() - started < Clock.seconds(9))
    local instance = assert(found[1])
    assert(#found == 1 and instance.attributes["a"] == "1" and instance.ipv4[1] == "192.0.2.7")
  end)
end

--- The second instance comes only to a repeat of the question, after the first is whole: a search
--- that ended at the first whole instance, not `settle_ns` after it, would answer one.
local function test_a_search_goes_on_through_settle_ns()
  local pointers = 0
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    pointers = pointers + 1
    if pointers == 1 then
      return { response(query, described(HTTP, "First", "one.local", 80, "192.0.2.1")) }
    end
    return { response(query, described(HTTP, "Second", "two.local", 80, "192.0.2.2")) }
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 2, settle_ns = Clock.seconds(30) }))
    assert(#found == 2 and assert(found[2]).name == "Second", tostring(#found))
  end)
end

--- A cancelled search answers no list, so what it held reaches the caller through `found`: the
--- whole instance when it was whole, and as the search ends the one whose SRV record alone came.
local function test_a_cancelled_search_gives_found_what_it_held()
  local late = fullname("Late", HTTP)
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    return {
      response(query, { pointer(HTTP, "Late"), srv(late, "late.local", 81) }),
      response(query, { pointer(HTTP, "Nameless") }),
      response(query, described(HTTP, "Whole", "whole.local", 80, "192.0.2.1")),
    }
  end
  serving(reply, function(opts: Mdns.Options)
    local told: mut {Mdns.Instance} = {}
    local found: {Mdns.Instance}?
    local why = "never ran"
    local search = Poll.spawn(function()
      found, why = Mdns.browse(HTTP, { ...opts, timeout_ns = Clock.seconds(25),
        found = function(instance: Mdns.Instance)
          told[#told + 1] = instance
        end })
    end)
    while #told == 0 do assert(Poll.delay(Clock.ms(5))) end
    search:cancel()
    assert(search:join(Clock.seconds(10)))
    assert(found == nil and why == Poll.CANCELLED, why)
    assert(#told == 2, tostring(#told))
    local first, second = assert(told[1]), assert(told[2])
    assert(first.name == "Whole" and first.ipv4[1] == "192.0.2.1")
    assert(second.name == "Late" and second.host == "late.local" and second.port == 81 and #second.ipv4 == 0)
  end)
end

local INFO <const> = "_device-info._tcp.local"

--- A service type whose instances have a TXT record and no SRV record. The search ends at its
--- limit of one, which the web server fills: the other instance has no place of it.
local function test_txt_only_lists_an_instance_with_no_srv_record()
  local name = fullname("Desk", INFO)
  local function reply(query: Dns.Message): {string}
    if not asks(query, INFO, Dns.PTR) then return {} end
    return {
      response(query, { pointer(INFO, "Desk"), txt(name, { "model=Mac14,2" }) }),
      response(query, described(HTTP, "Web", "one.local", 80, "192.0.2.1")),
    }
  end
  serving(reply, function(opts: Mdns.Options)
    local told: mut {string} = {}
    local found = assert(Mdns.browse({ INFO, HTTP }, { ...opts, limit = 1, txt_only = true,
      found = function(instance: Mdns.Instance)
        told[#told + 1] = instance.name
      end }))
    assert(#found == 2, tostring(#found))
    local desk, web = assert(found[1]), assert(found[2])
    assert(desk.name == "Desk" and desk.fullname == name and desk.service == INFO, desk.fullname)
    assert(desk.host == "" and desk.port == 0 and #desk.ipv4 == 0 and #desk.ipv6 == 0, desk.host)
    assert(#desk.txt == 1 and desk.attributes["model"] == "Mac14,2" and desk.from == LOOPBACK, desk.from)
    assert(web.name == "Web" and web.host == "one.local")
    -- The whole one when it was whole, the other as the search ended.
    assert(#told == 2 and told[1] == "Web" and told[2] == "Desk", table.concat(told, " "))
    local plain = assert(Mdns.browse({ INFO, HTTP }, { ...opts, limit = 1 }))
    assert(#plain == 1 and assert(plain[1]).name == "Web", tostring(#plain))
  end)
end

--- The instance is named and nothing more, so its records are asked for: its TXT record comes,
--- its SRV record never. The web server that ends the search is sent only once the TXT record has
--- been.
local function test_txt_only_asks_for_the_txt_record_of_a_name_with_no_srv_record()
  local name = fullname("Desk", INFO)
  local answered = false
  local function reply(query: Dns.Message): {string}
    local out: mut {string} = {}
    if asks(query, INFO, Dns.PTR) then
      local bytes = response(query, { pointer(INFO, "Desk") })
      out[#out + 1] = bytes
      if answered then
        local last = response(query, described(HTTP, "Web", "one.local", 80, "192.0.2.1"))
        out[#out + 1] = last
      end
    end
    if asks(query, name, Dns.TXT) then
      answered = true
      local bytes = response(query, { txt(name, { "model=Mac14,2" }) })
      out[#out + 1] = bytes
    end
    return out
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse({ INFO, HTTP }, { ...opts, limit = 1, txt_only = true, retry_ns = Clock.ms(20) }))
    assert(#found == 2, tostring(#found))
    assert(assert(found[1]).attributes["model"] == "Mac14,2" and assert(found[2]).name == "Web")
  end)
end

--- A name that waits in vain is forgotten once its third question for an SRV record has had its
--- time, four times `retry_ns`. One kept for its TXT record is not: it is in the list of a search
--- that went on past that time. The responder ends the search at the second repeat of the
--- question that comes after that third question, and a repeat is sent eight times `retry_ns` or
--- more after the one before it by then, whatever the host's speed.
local function test_txt_only_keeps_an_instance_past_the_time_a_name_is_forgotten_at()
  local name = fullname("Desk", INFO)
  local srv_questions, repeats_after = 0, 0
  local function reply(query: Dns.Message): {string}
    local third = false
    if asks(query, name, Dns.SRV) then
      srv_questions = srv_questions + 1
      third = srv_questions == 3
    end
    if not asks(query, INFO, Dns.PTR) then return {} end
    if srv_questions >= 3 and not third then repeats_after = repeats_after + 1 end
    if repeats_after >= 2 then
      return { response(query, described(HTTP, "Web", "one.local", 80, "192.0.2.1")) }
    end
    if srv_questions > 0 then return {} end
    return { response(query, { pointer(INFO, "Desk"), txt(name, { "model=Mac14,2" }) }) }
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse({ INFO, HTTP }, { ...opts, limit = 1, txt_only = true, retry_ns = Clock.ms(20) }))
    assert(#found == 2 and assert(found[1]).name == "Desk" and assert(found[2]).name == "Web", tostring(#found))
  end)
  assert(srv_questions == 3, tostring(srv_questions))
end

--- A hundred names with a TXT record and no SRV record, then a real instance. Sixty-four are
--- kept, the places a search has for names that wait, and the real one has its place of the
--- limit all the same.
local function test_txt_only_keeps_64_instances_with_no_srv_record_at_most()
  local function reply(query: Dns.Message): {string}
    if not asks(query, INFO, Dns.PTR) then return {} end
    local out: mut {string} = {}
    for packet = 0, 3 do
      local records: mut {Dns.Record} = {}
      for n = packet * 25 + 1, packet * 25 + 25 do
        local named = pointer(INFO, ("Desk %d"):format(n))
        local model = txt(fullname(("Desk %d"):format(n), INFO), { "model=" .. tostring(n) })
        records[#records + 1] = named
        records[#records + 1] = model
      end
      local bytes = response(query, records)
      out[#out + 1] = bytes
    end
    local real = response(query, described(HTTP, "Web", "one.local", 80, "192.0.2.1"))
    out[#out + 1] = real
    return out
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse({ INFO, HTTP }, { ...opts, limit = 1, txt_only = true }))
    assert(#found == 65, tostring(#found))
    for n = 1, 64 do
      local desk = assert(found[n])
      assert(desk.name == ("Desk %d"):format(n) and desk.host == "" and desk.attributes["model"] == tostring(n), desk.name)
    end
    assert(assert(found[65]).name == "Web")
  end)
end

--- The SRV record comes after the TXT record, to the question for it: the instance is then one
--- with a host, as in a search that does not keep the others.
local function test_txt_only_gives_an_instance_its_host_when_its_srv_record_comes()
  local name = fullname("Web", HTTP)
  local function reply(query: Dns.Message): {string}
    local out: mut {string} = {}
    if asks(query, HTTP, Dns.PTR) then
      local bytes = response(query, { pointer(HTTP, "Web"), txt(name, { "path=/" }) })
      out[#out + 1] = bytes
    end
    if asks(query, name, Dns.SRV) then
      local bytes = response(query, { srv(name, "one.local", 80), a("one.local", "192.0.2.1") })
      out[#out + 1] = bytes
    end
    return out
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 1, txt_only = true }))
    local web = assert(found[1])
    assert(#found == 1 and web.host == "one.local" and web.port == 80 and web.ipv4[1] == "192.0.2.1", web.host)
    assert(web.attributes["path"] == "/")
  end)
end

--- A printer and a web server at one host, and a second printer at another.
local function three_published(): {Mdns.Published}
  return {
    { service = "_ipp._tcp", name = "Front Desk. Printer", host = "desk.local", port = 631,
      ipv4 = { "192.0.2.7" }, ipv6 = { "2001:db8::7" }, txt = { "txtvers=1", "Color=T" } },
    { service = "_http._tcp.local", name = "Web", host = "Desk.local", port = 8080, ipv4 = { "192.0.2.7" } },
    { service = "_ipp._tcp", name = "Second", host = "second.local", port = 631, ipv4 = { "192.0.2.9" } },
  }
end

--- A question for the records of type `rtype` at `name`.
local function asking(name: string, rtype: integer): Dns.Question
  return { name = name, type = rtype, class = Dns.IN, unicast_response = false }
end

--- Sends the query of `questions` and `id` from `socket` to `to`.
local function send_query(socket: Net.Datagram, to: Net.Address, id: integer, questions: {Dns.Question})
  local query: Dns.Message = { ...Dns.query(".", Dns.PTR, id), recursion_desired = false, questions = questions }
  assert(socket:send(assert(Dns.encode(query)), to))
end

--- The next response that reaches `socket`: a member of a group hears its own queries too. A
--- responder that never answers fails the test here, by a wait no passing test comes near.
local function next_response(socket: Net.Datagram): Dns.Message
  while true do
    local packet = assert(socket:receive(Clock.seconds(20)))
    local message = assert(Dns.decode(packet.data))
    if message.response then return message end
  end
end

--- The record of type `rtype` among `records`.
local function of_type(records: {Dns.Record}, rtype: integer): Dns.Record
  for _, record in ipairs(records) do
    if record.type == rtype then return record end
  end
  error("no record of type " .. tostring(rtype))
end

local function test_a_responder_answers_a_search_made_from_a_port_of_its_own()
  publishing(three_published(), function(unicast: Mdns.Options, _: Mdns.Options, _: integer)
    local found = assert(Mdns.browse({ "_ipp._tcp", "_http._tcp" }, { ...unicast, limit = 3 }))
    assert(#found == 3, tostring(#found))
    local desk, web, second = assert(found[1]), assert(found[2]), assert(found[3])
    assert(desk.name == "Front Desk. Printer" and desk.service == "_ipp._tcp", desk.name)
    assert(desk.fullname == "Front Desk\\. Printer._ipp._tcp.local", desk.fullname)
    assert(desk.host == "desk.local" and desk.port == 631 and desk.from == LOOPBACK, desk.host)
    assert(#desk.ipv4 == 1 and desk.ipv4[1] == "192.0.2.7" and #desk.ipv6 == 1 and desk.ipv6[1] == "2001:db8::7")
    assert(#desk.txt == 2 and desk.attributes["txtvers"] == "1" and desk.attributes["color"] == "T")
    assert(web.name == "Web" and web.service == "_http._tcp" and web.port == 8080 and web.host == "desk.local")
    assert(#web.ipv4 == 1 and #web.txt == 1 and web.txt[1] == "", tostring(#web.txt))
    assert(second.name == "Second" and second.host == "second.local" and second.ipv4[1] == "192.0.2.9")
    local addresses = assert(Mdns.resolve("desk.local", unicast))
    assert(#addresses == 2, tostring(#addresses))
    assert(assert(addresses[1]).address == "192.0.2.7" and assert(addresses[2]).address == "2001:db8::7")
  end)
end

local function test_a_responder_answers_a_member_of_its_group_at_the_group()
  publishing(three_published(), function(_: Mdns.Options, grouped: Mdns.Options, _: integer)
    local found = assert(Mdns.browse("_ipp._tcp", { ...grouped, limit = 2 }))
    assert(#found == 2, tostring(#found))
    local desk = assert(found[1])
    assert(desk.name == "Front Desk. Printer" and desk.port == 631 and desk.ipv4[1] == "192.0.2.7")
    assert(desk.attributes["color"] == "T" and assert(found[2]).name == "Second")
    local addresses = assert(Mdns.resolve("second.local", grouped))
    assert(#addresses == 1 and assert(addresses[1]).address == "192.0.2.9", tostring(#addresses))
  end)
end

--- To a program that is no member: its id and question back, the records it will ask for next
--- beside the pointer, and nothing it would keep long or flush a cache for.
local function test_a_responder_answers_another_port_with_the_id_the_question_and_short_lives()
  publishing(three_published(), function(_: Mdns.Options, _: Mdns.Options, port: integer)
    local asker <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
    send_query(asker, Net.udp(LOOPBACK, port), 0x1234, { asking("_HTTP._tcp.local", Dns.PTR) })
    local reply = next_response(asker)
    assert(reply.id == 0x1234 and reply.authoritative and reply.rcode == 0)
    assert(#reply.questions == 1 and assert(reply.questions[1]).name == "_HTTP._tcp.local")
    assert(#reply.answers == 1 and #reply.additionals == 3, ("%d %d"):format(#reply.answers, #reply.additionals))
    local pointed = assert(reply.answers[1])
    assert(pointed.type == Dns.PTR and pointed.target == "Web._http._tcp.local", pointed.target)
    local where = assert(of_type(reply.additionals, Dns.SRV).srv)
    assert(where.port == 8080 and where.target == "Desk.local", where.target)
    assert(of_type(reply.additionals, Dns.A).address == "192.0.2.7")
    assert(of_type(reply.additionals, Dns.TXT).name == "Web._http._tcp.local")
    for _, section in ipairs({ reply.answers, reply.additionals }) do
      for _, record in ipairs(section) do
        assert(record.ttl >= 1 and record.ttl <= 10 and not record.cache_flush, tostring(record.ttl))
      end
    end
  end)
end

--- To a member: the id 0 and no question, each record with the life RFC 6762 gives it, and the
--- bit that says a record is the only one of its name and type on all but the pointer.
local function test_a_responder_answers_a_member_with_no_question_and_whole_lives()
  publishing(three_published(), function(_: Mdns.Options, _: Mdns.Options, port: integer)
    local member <close> = assert(Net.datagram(Net.udp("0.0.0.0", port), { shared = true }))
    assert(member:join(PUBLISHED_AT, LOOPBACK))
    assert(member:set_multicast({ via = LOOPBACK, hops = 1, loop = true }))
    send_query(member, Net.udp(PUBLISHED_AT, port), 0, { asking("_http._tcp.local", Dns.PTR) })
    local reply = next_response(member)
    assert(reply.id == 0 and reply.authoritative and #reply.questions == 0, tostring(#reply.questions))
    assert(#reply.answers == 1 and #reply.additionals == 3, ("%d %d"):format(#reply.answers, #reply.additionals))
    local pointed = assert(reply.answers[1])
    assert(pointed.type == Dns.PTR and pointed.ttl == 4500 and not pointed.cache_flush, tostring(pointed.ttl))
    local where, text, address = of_type(reply.additionals, Dns.SRV), of_type(reply.additionals, Dns.TXT),
      of_type(reply.additionals, Dns.A)
    assert(where.ttl == 120 and where.cache_flush and text.ttl == 4500 and text.cache_flush)
    assert(address.ttl == 120 and address.cache_flush and address.address == "192.0.2.7")
  end)
end

--- What each question draws, asked one at a time from a port of the asker's own, where the
--- answers come back in the order of the questions. A question the responder has no answer to
--- draws nothing, so the answer after it is the next question's.
local function test_a_responder_answers_each_question_with_the_records_it_asks_for()
  publishing(three_published(), function(_: Mdns.Options, _: Mdns.Options, port: integer)
    local asker <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
    local to = Net.udp(LOOPBACK, port)
    local desk = "Front Desk\\. Printer._ipp._tcp.local"
    local function ask(id: integer, name: string, rtype: integer): Dns.Message
      send_query(asker, to, id, { asking(name, rtype) })
      local reply = next_response(asker)
      assert(reply.id == id, ("the answer to %d came for %d"):format(reply.id, id))
      return reply
    end
    local located = ask(1, desk:upper(), Dns.SRV)
    assert(#located.answers == 1 and assert(assert(located.answers[1]).srv).target == "desk.local")
    assert(#located.additionals == 2 and of_type(located.additionals, Dns.AAAA).address == "2001:db8::7")
    local text = ask(2, desk, Dns.TXT)
    assert(#text.answers == 1 and #text.additionals == 0 and #assert(assert(text.answers[1]).txt) == 2)
    local both = ask(3, desk, Dns.ANY)
    assert(#both.answers == 2 and #both.additionals == 2, tostring(#both.answers))
    local four = ask(4, "DESK.local", Dns.A)
    assert(#four.answers == 1 and #four.additionals == 0 and assert(four.answers[1]).address == "192.0.2.7")
    local every = ask(5, "desk.local", Dns.ANY)
    assert(#every.answers == 2 and #every.additionals == 0, tostring(#every.answers))
    -- No answer: an address of a family the host has none of, a name and a service it does not
    -- publish, a type it does not answer, and a question of another class.
    send_query(asker, to, 6, { asking("second.local", Dns.AAAA) })
    send_query(asker, to, 7, { asking("other.local", Dns.A), asking("_other._tcp.local", Dns.PTR),
      asking("Nobody._ipp._tcp.local", Dns.SRV), asking(desk, Dns.A), asking("desk.local", Dns.TXT) })
    send_query(asker, to, 8, { { ...asking("_ipp._tcp.local", Dns.PTR), class = 3 } })
    local six = ask(9, "second.local", Dns.A)
    assert(#six.answers == 1 and assert(six.answers[1]).address == "192.0.2.9")
  end)
end

--- Two instances are at the host, each published with its address, and a question for the host's
--- addresses is answered with the address once. A pointer question for a type of two instances
--- draws a message for each.
local function test_a_responder_answers_once_for_an_address_two_instances_share()
  publishing(three_published(), function(_: Mdns.Options, _: Mdns.Options, port: integer)
    local asker <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
    local to = Net.udp(LOOPBACK, port)
    send_query(asker, to, 1, { asking("desk.local", Dns.A) })
    send_query(asker, to, 2, { asking("_ipp._tcp.local", Dns.PTR) })
    local addressed = next_response(asker)
    assert(addressed.id == 1 and #addressed.answers == 1, tostring(#addressed.answers))
    local first, second = next_response(asker), next_response(asker)
    assert(first.id == 2 and assert(first.answers[1]).target == "Front Desk\\. Printer._ipp._tcp.local")
    assert(second.id == 2 and assert(second.answers[1]).target == "Second._ipp._tcp.local")
  end)
end

--- Datagrams a responder must not answer, each of which would draw the printer's records were it
--- read as a query for them: the answer that comes is the one to the real query after them.
local function test_a_responder_ignores_what_is_no_query()
  publishing(three_published(), function(_: Mdns.Options, _: Mdns.Options, port: integer)
    local asker <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
    local to = Net.udp(LOOPBACK, port)
    local query: Dns.Message = { ...Dns.query(".", Dns.PTR, 1), recursion_desired = false,
      questions = { asking("_ipp._tcp.local", Dns.PTR) } }
    local padding: mut {Dns.Question} = { asking("_ipp._tcp.local", Dns.PTR) }
    local oversize = ""
    while #oversize <= 9000 do
      local one = asking(("x"):rep(60) .. ".local", Dns.A)
      padding[#padding + 1] = one
      oversize = assert(Dns.encode({ ...query, questions = padding }))
    end
    -- macOS sends no datagram over 9216 bytes unless told to.
    assert(#oversize <= 9216, tostring(#oversize))
    for _, bytes in ipairs({
        "",
        "\0",
        ("\xff"):rep(600),
        (assert(Dns.encode(query))):sub(1, 20),
        -- A response that carries the question, as the responder's own answers come back to it.
        (assert(Dns.encode({ ...query, response = true }))),
        (assert(Dns.encode({ ...query, opcode = 4 }))),
        oversize,
    }) do
      assert(asker:send(bytes, to))
    end
    send_query(asker, to, 2, { asking("_http._tcp.local", Dns.PTR) })
    local reply = next_response(asker)
    assert(reply.id == 2 and assert(reply.answers[1]).target == "Web._http._tcp.local", tostring(reply.id))
  end)
end

local function test_a_responder_publishes_64_instances_and_no_more()
  local many: mut {Mdns.Published} = {}
  for n = 1, 64 do
    local one: Mdns.Published = { service = "_http._tcp", name = ("Web %d"):format(n),
      host = ("web%d.local"):format(n), port = n, ipv4 = { "192.0.2." .. tostring(n) } }
    many[#many + 1] = one
  end
  publishing(many, function(unicast: Mdns.Options, _: Mdns.Options, _: integer)
    local found = assert(Mdns.browse("_http._tcp", { ...unicast, limit = 64 }))
    assert(#found == 64, tostring(#found))
    for n, instance in ipairs(found) do
      assert(instance.name == ("Web %d"):format(n) and instance.port == n and #instance.ipv4 == 1, instance.name)
    end
  end)
  local over: Mdns.Published = { service = "_http._tcp", name = "Web 65", host = "web65.local", port = 65 }
  many[#many + 1] = over
  local responder, why = Mdns.responder(many, { address = PUBLISHED_AT, port = 0, via = { LOOPBACK } })
  assert(responder == nil and why:find("mdns: ", 1, true) == 1, why)
end

local function test_what_a_responder_cannot_publish_is_refused_with_the_reason()
  local good: Mdns.Published = { service = "_http._tcp", name = "Web", host = "web.local", port = 80,
    ipv4 = { "192.0.2.1" } }
  local addresses: mut {string} = {}
  for n = 1, 17 do addresses[#addresses + 1] = "192.0.2." .. tostring(n) end
  local cases: {string: {Mdns.Published}} = {
    ["no instance"] = {},
    ["no service type"] = { { ...good, service = "http" } },
    ["a sub-type"] = { { ...good, service = "_printer._sub._http._tcp" } },
    ["an empty name"] = { { ...good, name = "" } },
    ["a name over a label"] = { { ...good, name = ("n"):rep(64) } },
    ["a host of another domain"] = { { ...good, host = "web.example.com" } },
    ["a port out of range"] = { { ...good, port = 65536 } },
    ["an address that is none"] = { { ...good, ipv4 = { "192.0.2.256" } } },
    ["an address of the other family"] = { { ...good, ipv6 = { "192.0.2.1" } } },
    ["too many addresses"] = { { ...good, ipv4 = addresses } },
    ["a TXT record past the cap"] = { { ...good, txt = strings_of(6, 1301) } },
    ["an instance given twice"] = { good, { ...good, name = "WEB", service = "_HTTP._tcp.local", port = 81 } },
  }
  local tried = 0
  for what, instances in pairs(cases) do
    local responder, why = Mdns.responder(instances, { address = PUBLISHED_AT, port = 0, via = { LOOPBACK } })
    assert(responder == nil and why ~= "", what)
    tried = tried + 1
  end
  assert(tried == 12, tostring(tried))
  Test.raises(function() Mdns.responder({ good }, { port = -1 }) end, "mdns: port must be")
  Test.raises(function() Mdns.responder({ good }, { port = 65536 }) end, "mdns: port must be")
  Test.raises(function() Mdns.responder({ good }, { address = LOOPBACK }) end, "mdns: address must be")
end

--- The port is free, so the socket is bound and it is the join that fails, with the group first
--- in its reason, and the socket is closed again. A port held unshared fails the bind, with the
--- address and port first.
local function test_a_responder_fails_where_its_group_or_its_port_cannot_be_had()
  local good: {Mdns.Published} = { { service = "_http._tcp", name = "Web", host = "web.local", port = 80 } }
  local port = free_port()
  -- 192.0.2.0/24 is for documentation: no interface has an address of it.
  local nowhere, why = Mdns.responder(good, { address = PUBLISHED_AT, port = port, via = { "192.0.2.77" } })
  assert(nowhere == nil and why:find(PUBLISHED_AT .. ": ", 1, true) == 1, why)
  assert(is_free(port))
  local holder <close> = assert(Net.datagram(Net.udp("0.0.0.0", 0)))
  local held = assert(holder.address.port)
  local unbound, unbound_why = Mdns.responder(good, { address = PUBLISHED_AT, port = held, via = { LOOPBACK } })
  assert(unbound == nil and unbound_why:find("0.0.0.0:" .. tostring(held) .. ": ", 1, true) == 1, unbound_why)
end

local function test_a_cancelled_tasks_responder_ends_with_cancelled_and_a_closed_one_with_true()
  local good: {Mdns.Published} = { { service = "_http._tcp", name = "Web", host = "web.local", port = 80 } }
  Poll.run(function()
    local responder <close> = assert(Mdns.responder(good, { address = PUBLISHED_AT, port = 0, via = { LOOPBACK } }))
    local served, why = true, "never ran"
    local started = false
    local answering = Poll.spawn(function()
      started = true
      served, why = responder:serve()
    end)
    while not started do assert(Poll.delay(Clock.ms(1))) end
    answering:cancel()
    assert(answering:join(Clock.seconds(10)))
    assert(not served and why == Poll.CANCELLED, why)
    -- Still open: a cancelled wait closes nothing, and another task may serve it.
    local asker <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
    local again = Poll.spawn(function()
      served, why = responder:serve()
    end)
    send_query(asker, Net.udp(LOOPBACK, assert(responder.address.port)), 7, { asking("_http._tcp.local", Dns.PTR) })
    assert(next_response(asker).id == 7)
    assert(responder:close() and responder:close())
    assert(again:join(Clock.seconds(10)))
    assert(served, why)
    local after, after_why = responder:serve()
    assert(after and after_why == "", after_why)
  end)
end
