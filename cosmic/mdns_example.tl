--- Worked examples for [`cosmic.mdns`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Clock = require("cosmic.clock")
local Mdns = require("cosmic.mdns")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")

--- Each example asks a stand-in for a printer on the worker's own loopback, not the network.
Test.policy{ loopback = { "127.0.0.1" } }

local record Example end

--- The group the stand-in joins on the loopback interface: one of a site's own.
local GROUP <const> = "239.255.53.99"

--- A stand-in for a printer: a responder that publishes one, named with a dot and a space, on the
--- loopback at a port the system chooses, which its `address` says. It answers once `serve` runs.
local function stand_in(): Mdns.Responder
  return (assert(Mdns.responder({
    { service = "_ipp._tcp", name = "Front Desk. Printer", host = "printer.local", port = 631,
      ipv4 = { "192.0.2.7" }, ipv6 = { "2001:db8::7" }, txt = { "txtvers=1", "rp=printers/front", "Color=T" } },
  }, { address = GROUP, port = 0, via = { "127.0.0.1" } })))
end

--- The printers of the network: [`Mdns.browse`] answers each instance of the service type with
--- where it is. On a real network the call is `Mdns.browse("_ipp._tcp")`, which searches for three
--- seconds. Here `address` and `port` send the question to the stand-in instead, and `limit` ends
--- the search at the first printer.
function Example.browse()
  Poll.run(function()
    local device <close> = stand_in()
    Poll.spawn(function() assert(device:serve()) end)
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
    local device <close> = stand_in()
    Poll.spawn(function() assert(device:serve()) end)
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
    local device <close> = stand_in()
    Poll.spawn(function() assert(device:serve()) end)
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
    local device <close> = stand_in()
    Poll.spawn(function() assert(device:serve()) end)
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
--- and answers a member at the group. On a real network `{ listen = "group" }` is enough: the
--- group of multicast DNS, port 5353 and the machine's interfaces are the defaults.
function Example.group()
  Poll.run(function()
    local device <close> = stand_in()
    Poll.spawn(function() assert(device:serve()) end)
    local printers = assert(Mdns.browse("_ipp._tcp", { listen = "group", address = GROUP,
      port = assert(device.address.port), via = { "127.0.0.1" }, limit = 1, timeout_ns = Clock.seconds(5) }))
    local found = assert(printers[1])
    print(found.name, found.from)
    assert(found.name == "Front Desk. Printer" and found.port == 631)
  end)
end

--- Publishing a service: [`Mdns.responder`] binds the port and joins the group, and `serve`
--- answers the questions about the instances until the responder is closed, here by `<close>` as
--- the function ends. On a real network the options are left out, for the group of multicast DNS
--- and port 5353; here the group is one of a site's own on the loopback interface and the port is
--- the system's choice, which a search is told.
function Example.responder()
  Poll.run(function()
    local responder <close> = assert(Mdns.responder({
      { service = "_http._tcp", name = "Notes", host = "notes.local", port = 8080, ipv4 = { "192.0.2.9" },
        txt = { "path=/notes" } },
    }, { address = GROUP, port = 0, via = { "127.0.0.1" } }))
    local serving = Poll.spawn(function() assert(responder:serve()) end)
    local found = assert(Mdns.browse("_http._tcp", { address = "127.0.0.1", port = assert(responder.address.port),
      limit = 1, timeout_ns = Clock.seconds(5) }))
    local notes = assert(found[1])
    print(notes.name, notes.host, notes.port, notes.ipv4[1], notes.attributes["path"])
    assert(notes.name == "Notes" and notes.host == "notes.local" and notes.port == 8080)
    assert(responder:close())
    assert(serving:join())
  end)
end

return Example
