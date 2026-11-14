--- [`cosmic.mdns`] against a stand-in responder on the loopback: instances assembled from whole and partial
--- answers, what a hostile answer cannot do, the limits of a search, and both ways to listen.

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

--- What a responder sends back for one query: whole datagrams, in order.
local type Reply = function(query: Dns.Message): {string}

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

--- Whether `query` asks for the records of type `rtype` at `name`, whatever the case of either name.
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

--- Runs `body` beside a responder on the loopback that answers each query with what `reply` gives, to the
--- address the query came from. `body` is given the options that make a search ask that responder alone: a
--- time limit no passing test reaches, so that a test ends by its `limit` or fails by its own.
local function serving(reply: Reply, body: function(opts: Mdns.Options))
  Poll.run(function()
    local device <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
    local responder = Poll.spawn(function()
      while true do
        local packet = device:receive()
        if packet == nil then return end
        local query = Dns.decode(packet.data)
        if query ~= nil then
          for _, bytes in ipairs(reply(query)) do assert(device:send(bytes, packet.address)) end
        end
      end
    end)
    body({ address = LOOPBACK, port = assert(device.address.port), timeout_ns = Clock.seconds(10),
      retry_ns = Clock.ms(200) })
    assert(device:close())
    assert(responder:join())
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
  -- One question was enough, and it is a multicast DNS question that wants its answer by unicast.
  assert(#questions == 1, tostring(#questions))
  local query = assert(questions[1])
  local question = assert(query.questions[1])
  assert(not query.response and not query.recursion_desired and #query.questions == 1)
  assert(question.name == HTTP and question.type == Dns.PTR and question.class == Dns.IN)
  assert(question.unicast_response)
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
    local name = fullname("Printer", HTTP)
    return {
      -- With the records of an instance of the service that does not declare the sub-type.
      response(query, { { ...at(sub, Dns.PTR), target = name } }, {
        srv(fullname("Plain", HTTP), "plain.local", 81),
        txt(fullname("Plain", HTTP), {}),
        a("plain.local", "192.0.2.8"),
        pointer(HTTP, "Plain"),
        srv(name, "printer.local", 80),
        txt(name, {}),
        a("printer.local", "192.0.2.7"),
      }),
    }
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse("_printer._sub._http._tcp", { ...opts, timeout_ns = Clock.ms(300) }))
    local instance = assert(found[1])
    assert(#found == 1 and instance.fullname == fullname("Printer", HTTP) and instance.port == 80)
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
  Test.raises(function() Mdns.browse("_http._tcp", { port = 0 }) end, "mdns: port must be")
  Test.raises(function() Mdns.browse("_http._tcp", { port = 65536 }) end, "mdns: port must be")
  Test.raises(function() Mdns.browse("_http._tcp", { limit = 0 }) end, "mdns: limit must be")
  Test.raises(function() Mdns.resolve("printer.local", { port = 0 }) end, "mdns: port must be")
end

local function test_records_that_come_before_the_one_they_depend_on_are_asked_for_again()
  local queries = 0
  local function reply(query: Dns.Message): {string}
    queries = queries + 1
    if not asks(query, HTTP, Dns.PTR) then return {} end
    local out: mut {string} = {}
    -- Back to front: no record needs the one that says who it is about to come first.
    local records = described(HTTP, "Printer", "printer.local", 8080, "192.0.2.7")
    for i = #records, 1, -1 do
      local bytes = response(query, { assert(records[i]) })
      out[#out + 1] = bytes
    end
    return out
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 1 }))
    local instance = assert(found[1])
    assert(instance.port == 8080 and instance.txt[1] == "path=/")
    assert(instance.ipv4[1] == "192.0.2.7")
  end)
  -- Each record came before the one that says who it is about, so each was asked for again.
  assert(queries >= 2, tostring(queries))
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
  local address_questions, srv_questions = 0, 0
  local function reply(query: Dns.Message): {string}
    if asks(query, "printer.local", Dns.A) then address_questions = address_questions + 1 end
    if asks(query, fullname("Nameless", HTTP), Dns.SRV) then srv_questions = srv_questions + 1 end
    if not asks(query, HTTP, Dns.PTR) then return {} end
    return {
      response(query, { pointer(HTTP, "Printer"), srv(name, "printer.local", 631), txt(name, {}),
        pointer(HTTP, "Nameless") }),
    }
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, timeout_ns = Clock.ms(900), retry_ns = Clock.ms(20) }))
    -- Its SRV record came, so it is listed, with no address.
    local instance = assert(found[1])
    assert(#found == 1 and instance.host == "printer.local" and #instance.ipv4 == 0 and #instance.ipv6 == 0)
  end)
  -- Asked 100 ms after the SRV record, then 20 ms and 40 ms later; the 900 ms have room for many more.
  assert(address_questions >= 1 and address_questions <= 3, tostring(address_questions))
  assert(srv_questions >= 1 and srv_questions <= 3, tostring(srv_questions))
end

local function test_an_instance_name_keeps_its_dots_spaces_and_letters()
  local instance_name = "Caf\xc3\xa9 2.0 \xe2\x80\x94 B\xc3\xbcro. Drucker"
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    return { response(query, described(HTTP, instance_name, "drucker.local", 80, "192.0.2.9")) }
  end
  serving(reply, function(opts: Mdns.Options)
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
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    -- Two of them at one host, and each in a packet of its own.
    return {
      response(query, described(HTTP, "First", "one.local", 80, "192.0.2.1")),
      response(query, described(HTTP, "Second", "one.local", 8080, "192.0.2.1")),
      response(query, described(HTTP, "Third", "three.local", 80, "192.0.2.3")),
    }
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 3 }))
    assert(#found == 3, tostring(#found))
    local first, second, third = assert(found[1]), assert(found[2]), assert(found[3])
    assert(first.name == "First" and first.port == 80 and first.ipv4[1] == "192.0.2.1")
    assert(second.name == "Second" and second.port == 8080 and second.host == "one.local")
    assert(#second.ipv4 == 1 and second.ipv4[1] == "192.0.2.1")
    assert(third.name == "Third" and third.host == "three.local" and third.ipv4[1] == "192.0.2.3")
  end)
end

--- Outside a run, where the search holds the thread: the questions wait in the silent socket's buffer.
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
  local padding: mut {Dns.Record} = {}
  for i = 1, 40 do
    local record = txt(name, { ("x"):rep(250) })
    padding[i] = record
  end
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
    (assert(Dns.encode({ ...forged, additionals = padding }))),
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
    -- A pointer at another service that leads into the one asked for, and SRV and TXT records of an instance no
    -- pointer at the service gave.
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

local function test_hostile_answers_add_no_instance()
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    return hostile(query)
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, timeout_ns = Clock.ms(300) }))
    assert(#found == 0, tostring(#found))
  end)
end

local function test_hostile_answers_change_nothing_of_a_real_instance()
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
    return out
  end
  serving(reply, function(opts: Mdns.Options)
    local found = assert(Mdns.browse(HTTP, { ...opts, timeout_ns = Clock.ms(300) }))
    assert(#found == 1, tostring(#found))
    local instance = assert(found[1])
    assert(instance.name == "Real" and instance.host == "real.local" and instance.port == 80)
    assert(#instance.ipv4 == 1 and instance.ipv4[1] == "192.0.2.1" and #instance.ipv6 == 0)
    assert(#instance.txt == 1 and instance.attributes["path"] == "/")
  end)
end

local function test_a_flood_of_instances_and_addresses_stops_at_the_bounds()
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    local out: mut {string} = {}
    -- Sixty instances, ten to a packet, and with the first ten sixty addresses of each family for one host.
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
    local found = assert(Mdns.browse(HTTP, { ...opts, limit = 4, timeout_ns = Clock.ms(300) }))
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
  local function reply(query: Dns.Message): {string}
    if not asks(query, HTTP, Dns.PTR) then return {} end
    return { response(query, described(HTTP, "Whole", "whole.local", 80, "192.0.2.1")) }
  end
  serving(reply, function(opts: Mdns.Options)
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

--- The group way, with the group joined on the loopback at a port the kernel chose: the responder is a member
--- too, and answers to the group, not to whoever asked.
local function test_listening_by_group_hears_the_answers_sent_to_the_group()
  local group = "239.255.53.1"
  local questions: mut {Dns.Message} = {}
  Poll.run(function()
    local device <close> = assert(Net.datagram(Net.udp(group, 0), { shared = true }))
    local port = assert(device.address.port)
    assert(device:join(group, LOOPBACK))
    local out <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
    assert(out:set_multicast({ via = LOOPBACK, hops = 1, loop = true }))
    local responder = Poll.spawn(function()
      while true do
        local packet = device:receive()
        if packet == nil then return end
        local query = Dns.decode(packet.data)
        -- The group carries the responder's own answers back to it.
        if query ~= nil and not query.response and asks(query, HTTP, Dns.PTR) then
          questions[#questions + 1] = query
          local announced: Dns.Message = { ...Dns.reply(query), questions = {}, authoritative = true,
            answers = described(HTTP, "Printer", "printer.local", 631, "192.0.2.7") }
          assert(out:send(assert(Dns.encode(announced)), Net.udp(group, port)))
        end
      end
    end)
    local found = assert(Mdns.browse(HTTP, { listen = "group", address = group, port = port, via = { LOOPBACK },
      limit = 1, timeout_ns = Clock.seconds(10), retry_ns = Clock.ms(200) }))
    assert(device:close())
    assert(responder:join())
    local instance = assert(found[1])
    assert(instance.name == "Printer" and instance.port == 631 and instance.ipv4[1] == "192.0.2.7")
    assert(instance.from == LOOPBACK, instance.from)
  end)
  -- A member asks with the id of multicast DNS and wants its answer at the group.
  local query = assert(questions[1])
  assert(query.id == 0 and not assert(query.questions[1]).unicast_response)
end

local function test_listening_by_group_fails_where_the_group_cannot_be_joined()
  local unjoined, why = Mdns.browse(HTTP, { listen = "group", address = LOOPBACK, via = { LOOPBACK },
    port = 5399, timeout_ns = 0 })
  assert(unjoined == nil and why ~= "")
  -- 192.0.2.0/24 is for documentation: no interface has an address of it.
  local nowhere, nowhere_why = Mdns.browse(HTTP, { listen = "group", address = "239.255.53.2",
    via = { "192.0.2.77" }, port = 5399, timeout_ns = 0 })
  assert(nowhere == nil and nowhere_why ~= "")
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
  assert(assert(query.questions[1]).unicast_response)
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

--- A group asked with no `via`: the interfaces are those the system lists, or its own choice where it lists
--- none, as a sandboxed worker's does not. With no time to search in, nothing is sent by any of them.
local function test_a_search_with_no_via_is_made_whether_or_not_the_interfaces_are_listed()
  local found = assert(Mdns.browse(HTTP, { address = "239.255.53.3", port = 5399, timeout_ns = 0 }))
  assert(#found == 0)
end
