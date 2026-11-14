--- Worked examples for [`cosmic.dns`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Codec = require("cosmic.codec")
local Dns = require("cosmic.dns")

local record Example end

--- A query for a host's IPv4 address, as the bytes to send a server. The id is 0x1234 here so that the bytes
--- are the same each run: a real query draws one that cannot be guessed.
function Example.query()
  local query = Dns.query("example.com", Dns.A, 0x1234)
  local bytes = assert(Dns.encode(query))
  print(Codec.hex(bytes))
  assert(Codec.hex(bytes) == "12340100000100000000000007" .. Codec.hex("example") .. "03" .. Codec.hex("com") ..
      "0000010001")
end

--- A multicast DNS question: an id of 0, no recursion, any type, and the bit that asks for the answer by unicast.
function Example.multicast_query()
  local query: Dns.Message = {
    ...Dns.query("printer.local", Dns.ANY, 0),
    recursion_desired = false,
    questions = { { name = "printer.local", type = Dns.ANY, class = Dns.IN, unicast_response = true } },
  }
  local bytes = assert(Dns.encode(query))
  local back = assert(Dns.decode(bytes))
  local question = assert(back.questions[1])
  print(question.name, question.type, question.unicast_response)
  assert(question.name == "printer.local" and question.type == Dns.ANY and question.unicast_response)
end

--- A response as a server sends it, with the name of its answer compressed to a pointer at the question's:
--- decode follows the pointer, and reads the data of each record by its type.
function Example.decode()
  local bytes = "\x12\x34\x81\x80\x00\x01\x00\x02\x00\x00\x00\x00" ..
    "\x07example\x03com\x00\x00\x01\x00\x01" ..
    "\xc0\x0c\x00\x01\x00\x01\x00\x00\x0e\x10\x00\x04\xc0\x00\x02\x01" ..
    "\xc0\x0c\x00\x1c\x00\x01\x00\x00\x0e\x10\x00\x10\x20\x01\x0d\xb8" .. ("\x00"):rep(11) .. "\x01"
  local response = assert(Dns.decode(bytes))
  assert(response.response and response.id == 0x1234 and response.rcode == 0)
  for _, answer in ipairs(response.answers) do
    if answer.type == Dns.A or answer.type == Dns.AAAA then
      print(answer.name, answer.ttl, answer.address)
    end
  end
  assert(assert(response.answers[1]).address == "192.0.2.1")
  assert(assert(response.answers[2]).address == "2001:db8::1")
end

--- Bytes that are no message are a failure to handle, never a raise: here the header counts an answer that the
--- bytes do not hold.
function Example.decode_refuses()
  local message, why = Dns.decode("\x00\x00\x81\x80\x00\x00\x00\x01\x00\x00\x00\x00")
  print(why)
  assert(message == nil and why ~= "")
end

--- A server's answer to a query: [`Dns.reply`] repeats what a response repeats, and each record is written from
--- the field of its type, so no caller assembles the bytes of a record's data. A record that is read holds the
--- same field.
function Example.reply()
  local asked = assert(Dns.encode(Dns.query("example.com", Dns.ANY, 7)))
  local query = assert(Dns.decode(asked))
  local function at(name: string, rtype: integer): Dns.Record
    return { name = name, type = rtype, class = Dns.IN, cache_flush = false, ttl = 3600 }
  end
  local response: Dns.Message = {
    ...Dns.reply(query),
    authoritative = true,
    answers = {
      { ...at("example.com", Dns.A), address = "192.0.2.1" },
      { ...at("example.com", Dns.AAAA), address = "2001:db8::1" },
      { ...at("example.com", Dns.MX), mx = { preference = 10, exchange = "mail.example.com" } },
      { ...at("example.com", Dns.TXT), txt = { "v=spf1 -all" } },
      { ...at("www.example.com", Dns.CNAME), target = "example.com" },
      { ...at("1.2.0.192.in-addr.arpa", Dns.PTR), target = "example.com" },
      {
        ...at("_imaps._tcp.example.com", Dns.SRV),
        srv = { priority = 0, weight = 1, port = 993, target = "mail.example.com" },
      },
    },
    authorities = {
      { ...at("example.com", Dns.NS), target = "ns1.example.com" },
      {
        ...at("example.com", Dns.SOA),
        soa = {
          mname = "ns1.example.com",
          rname = "hostmaster.example.com",
          serial = 2024010101,
          refresh = 7200,
          retry = 900,
          expire = 1209600,
          minimum = 300,
        },
      },
    },
  }
  local bytes = assert(Dns.encode(response))
  local read = assert(Dns.decode(bytes))
  assert(read.id == 7 and read.response and read.authoritative and #read.questions == 1)
  local lines: mut {string} = {}
  for _, section in ipairs({ read.answers, read.authorities }) do
    for _, record in ipairs(section) do
      local mx, txt, srv, soa = record.mx, record.txt, record.srv, record.soa
      local data = record.address or record.target or ""
      if mx ~= nil then data = ("%d %s"):format(mx.preference, mx.exchange) end
      if txt ~= nil then data = table.concat(txt, " | ") end
      if srv ~= nil then
        data = ("%d %d %d %s"):format(srv.priority, srv.weight, srv.port, srv.target)
      end
      if soa ~= nil then data = ("%s %s %d"):format(soa.mname, soa.rname, soa.serial) end
      local line = record.name .. " " .. data
      lines[#lines + 1] = line
    end
  end
  print(table.concat(lines, "\n"))
  assert(lines[3] == "example.com 10 mail.example.com")
  assert(lines[7] == "_imaps._tcp.example.com 0 1 993 mail.example.com")
  assert(lines[9] == "example.com ns1.example.com hostmaster.example.com 2024010101")
end

--- A record of a type this module has no field for is its `rdata`, read and written as it is. Type 99 is one.
function Example.rdata()
  local spf: Dns.Record = { name = "example.com", type = 99, class = Dns.IN, cache_flush = false, ttl = 60,
    rdata = "\x0bv=spf1 -all" }
  local response: Dns.Message = { ...Dns.reply(Dns.query("example.com", 99, 1)), answers = { spf } }
  local bytes = assert(Dns.encode(response))
  local read = assert(assert(Dns.decode(bytes)).answers[1])
  print(read.type, Codec.hex(assert(read.rdata)))
  assert(read.type == 99 and read.rdata == "\x0bv=spf1 -all" and read.txt == nil)
end

--- A label may hold a dot, as the name of a service's instance often does. The text of the name escapes it, so
--- the labels read back as they were.
function Example.name()
  local name = assert(Dns.name({ "Front Desk. Printer", "_ipp", "_tcp", "local" }))
  print(name)
  assert(name == "Front Desk\\. Printer._ipp._tcp.local")
  local labels = assert(Dns.labels(name))
  assert(#labels == 4 and labels[1] == "Front Desk. Printer" and labels[4] == "local")
end

--- A name that is no name is refused with the reason, here a label over 63 bytes.
function Example.labels_refuses()
  local labels, why = Dns.labels(("a"):rep(64) .. ".example.com")
  print(why)
  assert(labels == nil and why ~= "")
end

--- The strings of a TXT record as the keys and values a service describes itself with (RFC 6763): keys in
--- lower case, the first of a key given twice, and "" for a key with no `=`.
function Example.attributes()
  local attributes = Dns.attributes({ "txtvers=1", "Color=T", "Duplex", "color=F" })
  print(attributes["txtvers"], attributes["color"], attributes["duplex"] == "")
  assert(attributes["txtvers"] == "1" and attributes["color"] == "T" and attributes["duplex"] == "")
end

return Example
