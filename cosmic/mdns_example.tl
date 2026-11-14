--- Worked examples for [`cosmic.mdns`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Clock = require("cosmic.clock")
local Dns = require("cosmic.dns")
local Mdns = require("cosmic.mdns")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")

--- Each example asks a stand-in for a printer on the worker's own loopback, not the network.
Test.policy{ loopback = { "127.0.0.1" } }

local record Example end

--- A record of type `rtype` at `name`, for the stand-in to fill in.
local function at(name: string, rtype: integer): Dns.Record
  return { name = name, type = rtype, class = Dns.IN, cache_flush = false, ttl = 120 }
end

--- All the stand-in has to say, as the response to `query`: a printer named with a dot and a space,
--- at `printer.local`.
local function answer(query: Dns.Message): string
  local name = "Front Desk\\. Printer._ipp._tcp.local"
  local answers: {Dns.Record} = {
    { ...at("_ipp._tcp.local", Dns.PTR), target = name },
    { ...at(name, Dns.SRV), srv = { priority = 0, weight = 0, port = 631, target = "printer.local" } },
    { ...at(name, Dns.TXT), txt = { "txtvers=1", "rp=printers/front", "Color=T" } },
    { ...at("printer.local", Dns.A), address = "192.0.2.7" },
    { ...at("printer.local", Dns.AAAA), address = "2001:db8::7" },
  }
  local message: Dns.Message = { ...Dns.reply(query), authoritative = true, answers = answers }
  return (assert(Dns.encode(message)))
end

--- The stand-in: answers each question that reaches `device`, to whoever asked, until the socket is
--- closed.
local function respond(device: Net.Datagram)
  while true do
    local packet = device:receive()
    if packet == nil then return end
    local query = Dns.decode(packet.data)
    if query ~= nil and not query.response then
      assert(device:send(answer(query), packet.address))
    end
  end
end

--- The printers of the network: [`Mdns.browse`] answers each instance of the service type with
--- where it is. On a real network the call is `Mdns.browse("_ipp._tcp")`, which searches for three
--- seconds. Here `address` and `port` send the question to the stand-in instead, and `limit` ends
--- the search at the first printer.
function Example.browse()
  Poll.run(function()
    local device <close> = assert(Net.datagram(Net.udp("127.0.0.1", 0)))
    Poll.spawn(function() respond(device) end)
    local printers = assert(Mdns.browse("_ipp._tcp", { address = "127.0.0.1", port = assert(device.address.port),
      limit = 1, timeout_ns = Clock.seconds(5) }))
    for _, printer in ipairs(printers) do
      print(printer.name, printer.host, printer.port, printer.ipv4[1], printer.ipv6[1])
      print(printer.fullname, printer.attributes["rp"], printer.from)
    end
    local printer = assert(printers[1])
    assert(printer.name == "Front Desk. Printer" and printer.host == "printer.local" and printer.port == 631)
    assert(printer.ipv4[1] == "192.0.2.7" and printer.ipv6[1] == "2001:db8::7")
    assert(printer.attributes["rp"] == "printers/front" and printer.attributes["color"] == "T")
    assert(printer.txt[3] == "Color=T" and printer.from == "127.0.0.1")
  end)
end

--- Several service types in one search: a device is often known by more than one, and each
--- instance says in `service` which it is one of. The stand-in is a printer and no web server, so
--- nothing answers for `_http._tcp`. `settle_ns` ends the search a tenth of a second after the
--- printer has described itself, where it would wait five seconds for the other type.
function Example.several()
  Poll.run(function()
    local device <close> = assert(Net.datagram(Net.udp("127.0.0.1", 0)))
    Poll.spawn(function() respond(device) end)
    local found = assert(Mdns.browse({ "_ipp._tcp", "_http._tcp" }, { address = "127.0.0.1",
      port = assert(device.address.port), settle_ns = Clock.ms(100), timeout_ns = Clock.seconds(5) }))
    for _, instance in ipairs(found) do print(instance.service, instance.name, instance.port) end
    local printer = assert(found[1])
    assert(#found == 1 and printer.service == "_ipp._tcp" and printer.name == "Front Desk. Printer")
  end)
end

--- Instances as they are found: `found` is called with each while the search goes on, so a program
--- can show the first before the time limit has passed.
function Example.found()
  Poll.run(function()
    local device <close> = assert(Net.datagram(Net.udp("127.0.0.1", 0)))
    Poll.spawn(function() respond(device) end)
    local names: mut {string} = {}
    local printers = assert(Mdns.browse("_ipp._tcp.local", {
      address = "127.0.0.1",
      port = assert(device.address.port),
      limit = 1,
      found = function(printer: Mdns.Instance)
        print("found " .. printer.name)
        names[#names + 1] = printer.name
      end,
    }))
    assert(#printers == 1 and #names == 1 and names[1] == "Front Desk. Printer")
  end)
end

--- The addresses of a host of the `local` domain, IPv4 first: [`Mdns.resolve`] ends soon after the
--- first answer, not at its time limit.
function Example.resolve()
  Poll.run(function()
    local device <close> = assert(Net.datagram(Net.udp("127.0.0.1", 0)))
    Poll.spawn(function() respond(device) end)
    local addresses = assert(Mdns.resolve("printer.local", { address = "127.0.0.1",
      port = assert(device.address.port) }))
    for _, address in ipairs(addresses) do print(address.family, address.address) end
    assert(#addresses == 2 and assert(addresses[1]).address == "192.0.2.7")
    assert(assert(addresses[2]).family == "ipv6")
  end)
end

--- Listening as a member of the group, [`Mdns.Listen`]'s "group": the search binds the port,
--- shared, joins the group on the interfaces `via` names and hears what is sent to the group. Here
--- the group is one of a site's own on the loopback interface, where the stand-in is a member too
--- and sends its answers to the group. On a real network `{ listen = "group" }` is enough: the
--- group of multicast DNS, port 5353 and the machine's interfaces are the defaults.
function Example.group()
  local group, via = "239.255.53.99", "127.0.0.1"
  Poll.run(function()
    local device <close> = assert(Net.datagram(Net.udp(group, 0), { shared = true }))
    local port = assert(device.address.port)
    assert(device:join(group, via))
    -- An answer comes from the port the question was asked at, as a responder's comes from port
    -- 5353.
    local out <close> = assert(Net.datagram(Net.udp(via, port), { shared = true }))
    assert(out:set_multicast({ via = via, hops = 1 }))
    Poll.spawn(function()
      while true do
        local packet = device:receive()
        if packet == nil then return end
        local query = Dns.decode(packet.data)
        -- The group carries the stand-in's own answers back to it.
        if query ~= nil and not query.response then
          assert(out:send(answer(query), Net.udp(group, port)))
        end
      end
    end)
    local printers = assert(Mdns.browse("_ipp._tcp", { listen = "group", address = group, port = port,
      via = { via }, limit = 1, timeout_ns = Clock.seconds(5) }))
    local printer = assert(printers[1])
    print(printer.name, printer.from)
    assert(printer.name == "Front Desk. Printer" and printer.port == 631)
  end)
end

return Example
