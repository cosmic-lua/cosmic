local Dns = require("cosmic.dns")

--- A response with nothing in it, to put records in.
local function empty(): Dns.Message
  return { ...Dns.reply(Dns.query("example.com", Dns.A, 0x1234)), authoritative = true }
end

--- The header of a message with these counts and nothing else set.
local function header(questions: integer, answers: integer): string
  return "\x00\x00\x00\x00\x00" .. string.char(questions) .. "\x00" .. string.char(answers) .. "\x00\x00\x00\x00"
end

--- A message that asks one question, about the name whose bytes on the wire are `name`.
local function asking(name: string): string
  return header(1, 0) .. name .. "\x00\x01\x00\x01"
end

--- A message of one answer of the internet class, with this type and data, about the root.
local function answering(rtype: integer, rdata: string): string
  return header(0, 1) .. "\x00\x00" .. string.char(rtype) .. "\x00\x01\x00\x00\x00\x00\x00" .. string.char(#rdata) ..
    rdata
end

local function refused(data: string)
  local message, why = Dns.decode(data)
  assert(message == nil and why ~= "", ("%q was read"):format(data))
end

local function unwritable(message: Dns.Message)
  local bytes, why = Dns.encode(message)
  assert(bytes == nil and why ~= "")
end

--- The bytes of `message`, which has them.
local function written(message: Dns.Message): string
  local bytes = assert(Dns.encode(message))
  return bytes
end

--- The one answer of the message in `data`.
local function answer_of(data: string): Dns.Record
  local message = assert(Dns.decode(data))
  assert(#message.answers == 1)
  return assert(message.answers[1])
end

--- The text of a name and the labels it stands for.
local record Named
  text: string
  labels: {string}
end

local function test_a_name_reads_back_as_its_labels()
  local names: {Named} = {
    { text = ".", labels = {} },
    { text = "example.com", labels = { "example", "com" } },
    { text = "a\\.b.c\\\\d", labels = { "a.b", "c\\d" } },
    { text = "caf\xc3\xa9.\xff\x80", labels = { "caf\xc3\xa9", "\xff\x80" } },
    { text = "\\000\\031\\127.\\\\000", labels = { "\x00\x1f\x7f", "\\000" } },
    { text = "My Web Site._http._tcp.local", labels = { "My Web Site", "_http", "_tcp", "local" } },
    { text = "1.\\.\\..\\\\", labels = { "1", "..", "\\" } },
  }
  for _, named in ipairs(names) do
    local text = assert(Dns.name(named.labels))
    assert(text == named.text, text)
    local labels = assert(Dns.labels(named.text))
    assert(table.concat(labels, "\0|") == table.concat(named.labels, "\0|") and #labels == #named.labels, named.text)
  end
end

local function test_labels_reads_every_escape()
  local spelled: {string: string} = {
    ["\\065\\.\\a.com."] = "A.a|com",
    ["example.com."] = "example|com",
    ["\\255\\000"] = "\xff\x00",
    ["a\\0461"] = "a.1",
    [""] = "",
  }
  for text, want in pairs(spelled) do
    assert(table.concat(assert(Dns.labels(text)), "|") == want, text)
  end
  for _, text in ipairs({ "a..b", ".a", "..", "a\\", "a\\1", "a\\12", "a\\256", "a\\12x" }) do
    local labels, why = Dns.labels(text)
    assert(labels == nil and why ~= "", text)
  end
end

local function test_a_label_holds_63_bytes_and_a_name_255()
  local full = ("a"):rep(63)
  assert(Dns.name({ full }) == full and #assert(Dns.labels(full)) == 1)
  local long, long_why = Dns.name({ full .. "a" })
  assert(long == nil and long_why ~= "")
  local split, split_why = Dns.labels(full .. "a.com")
  assert(split == nil and split_why ~= "")
  local empty_label, empty_why = Dns.name({ "a", "" })
  assert(empty_label == nil and empty_why ~= "")

  -- Three labels of 63 bytes and one of 61 are 255 bytes with their lengths and the root's.
  local most = assert(Dns.name({ full, full, full, ("b"):rep(61) }))
  local over, over_why = Dns.name({ full, full, full, ("b"):rep(62) })
  assert(over == nil and over_why ~= "")
  local over_text, over_text_why = Dns.labels(most .. "b")
  assert(over_text == nil and over_text_why ~= "")

  local wire = assert(Dns.encode(Dns.query(most, Dns.A, 0)))
  assert(#wire == 12 + 255 + 4)
  assert(assert(assert(Dns.decode(wire)).questions[1]).name == most)
  unwritable(Dns.query(most .. "b", Dns.A, 0))
  unwritable(Dns.query(full .. "a.com", Dns.A, 0))
  unwritable(Dns.query("a..com", Dns.A, 0))

  local label = "\x3f" .. full
  refused(asking(label .. label .. label .. "\x3e" .. ("b"):rep(62) .. "\x00"))
  refused(asking("\x40" .. full .. "a\x00"))
  -- A name within the limit where it stands is over it with what its pointer adds.
  local message = header(2, 0) .. label .. label .. label .. "\x3d" .. ("b"):rep(61) .. "\x00\x00\x01\x00\x01"
  assert(Dns.decode(message .. "\xc0\x0c\x00\x01\x00\x01"))
  refused(message .. "\x01c\xc0\x0c\x00\x01\x00\x01")
end

local function test_a_query_is_these_bytes()
  local wire = assert(Dns.encode(Dns.query("example.com", Dns.A, 0x1234)))
  assert(wire == "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" .. "\x07example\x03com\x00" .. "\x00\x01\x00\x01")
  local back = assert(Dns.decode(wire))
  assert(back.id == 0x1234 and not back.response and back.opcode == 0 and back.recursion_desired and back.rcode == 0)
  assert(#back.questions == 1 and #back.answers == 0 and #back.authorities == 0 and #back.additionals == 0)
  local question = assert(back.questions[1])
  assert(question.name == "example.com" and question.type == Dns.A and question.class == Dns.IN)
  assert(not question.unicast_response)
end

--- The questions a multicast DNS browser sends: no recursion, an id of 0, and the unicast-response bit, which
--- is the top bit of the class.
local function test_a_multicast_query_is_these_bytes()
  local query: Dns.Message = {
    ...Dns.query("_http._tcp.local", Dns.PTR, 0),
    recursion_desired = false,
    questions = {
      { name = "_http._tcp.local", type = Dns.PTR, class = Dns.IN, unicast_response = true },
      { name = "My\\.Printer._ipp._tcp.local", type = Dns.ANY, class = Dns.IN, unicast_response = false },
    },
  }
  local wire = assert(Dns.encode(query))
  assert(wire == "\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00" ..
      "\x05_http\x04_tcp\x05local\x00" .. "\x00\x0c\x80\x01" ..
      "\x0aMy.Printer\x04_ipp\x04_tcp\x05local\x00" .. "\x00\xff\x00\x01")
  local back = assert(Dns.decode(wire))
  local first, second = assert(back.questions[1]), assert(back.questions[2])
  assert(first.unicast_response and first.class == Dns.IN and first.type == Dns.PTR)
  assert(not second.unicast_response and second.name == "My\\.Printer._ipp._tcp.local" and second.type == Dns.ANY)
  assert(Dns.encode(back) == wire)
end

--- The names of RFC 1035 section 4.1.4, compressed as it compresses them: F.ISI.ARPA whole, FOO.F.ISI.ARPA as a
--- label and a pointer to it, ARPA as a pointer into it, and the root. The RFC draws them at offsets 20, 40, 64
--- and 92 of a message it does not show; here they are the names of a question and three records, so the first
--- is at offset 12 and its ARPA at 18.
local function test_the_names_of_rfc_1035_decompress()
  local nothing = "\x00\x63\x00\x01\x00\x00\x00\x00\x00\x00"
  local message = assert(Dns.decode(header(1, 3) .. "\x01F\x03ISI\x04ARPA\x00" .. "\x00\x01\x00\x01" ..
      "\x03FOO\xc0\x0c" .. nothing .. "\xc0\x12" .. nothing .. "\x00" .. nothing))
  assert(assert(message.questions[1]).name == "F.ISI.ARPA")
  assert(assert(message.answers[1]).name == "FOO.F.ISI.ARPA")
  assert(assert(message.answers[2]).name == "ARPA")
  assert(assert(message.answers[3]).name == ".")
end

--- A response with a record of every type this module reads, each name written in full.
local FULL <const> = "\x12\x34\x85\x00\x00\x01\x00\x07\x00\x02\x00\x01" ..
  "\x07example\x03com\x00" .. "\x00\x01\x00\x01" ..
  "\x07example\x03com\x00" .. "\x00\x01\x00\x01\x00\x00\x01\x2c\x00\x04" .. "\xc0\x00\x02\x01" ..
  "\x07example\x03com\x00" .. "\x00\x1c\x00\x01\x00\x00\x01\x2c\x00\x10" ..
  "\x20\x01\x0d\xb8\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01" ..
  "\x07example\x03com\x00" .. "\x00\x05\x00\x01\x00\x00\x01\x2c\x00\x11" .. "\x03www\x07example\x03com\x00" ..
  "\x07example\x03com\x00" .. "\x00\x0f\x00\x01\x00\x00\x01\x2c\x00\x14" .. "\x00\x0a\x04mail\x07example\x03com\x00" ..
  "\x07example\x03com\x00" .. "\x00\x10\x00\x01\x00\x00\x01\x2c\x00\x10" .. "\x0bv=spf1 -all\x00\x02\xff\x00" ..
  "\x05_http\x04_tcp\x07example\x03com\x00" .. "\x00\x0c\x00\x01\x00\x00\x01\x2c\x00\x24" ..
  "\x0bMy.Web\\Site\x05_http\x04_tcp\x07example\x03com\x00" ..
  "\x0bMy.Web\\Site\x05_http\x04_tcp\x07example\x03com\x00" .. "\x00\x21\x00\x01\x00\x00\x00\x78\x00\x17" ..
  "\x00\x01\x00\x02\x1f\x90\x03www\x07example\x03com\x00" ..
  "\x07example\x03com\x00" .. "\x00\x02\x00\x01\x00\x01\x51\x80\x00\x11" .. "\x03ns1\x07example\x03com\x00" ..
  "\x07example\x03com\x00" .. "\x00\x06\x00\x01\x00\x00\x0e\x10\x00\x3e" ..
  "\x03ns1\x07example\x03com\x00" .. "\x0bhost.master\x07example\x03com\x00" ..
  "\x78\xa3\xf1\x75\x00\x00\x1c\x20\x00\x00\x03\x84\x00\x12\x75\x00\xff\xff\xff\xff" ..
  "\x03ns1\x07example\x03com\x00" .. "\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04" .. "\xc6\x33\x64\x07"

--- The same response as a compressing server writes it: every name after the first is a pointer or ends in one.
local COMPRESSED <const> = "\x12\x34\x85\x00\x00\x01\x00\x07\x00\x02\x00\x01" ..
  "\x07example\x03com\x00" .. "\x00\x01\x00\x01" ..
  "\xc0\x0c" .. "\x00\x01\x00\x01\x00\x00\x01\x2c\x00\x04" .. "\xc0\x00\x02\x01" ..
  "\xc0\x0c" .. "\x00\x1c\x00\x01\x00\x00\x01\x2c\x00\x10" ..
  "\x20\x01\x0d\xb8\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01" ..
  "\xc0\x0c" .. "\x00\x05\x00\x01\x00\x00\x01\x2c\x00\x06" .. "\x03www\xc0\x0c" ..
  "\xc0\x0c" .. "\x00\x0f\x00\x01\x00\x00\x01\x2c\x00\x09" .. "\x00\x0a\x04mail\xc0\x0c" ..
  "\xc0\x0c" .. "\x00\x10\x00\x01\x00\x00\x01\x2c\x00\x10" .. "\x0bv=spf1 -all\x00\x02\xff\x00" ..
  "\x05_http\x04_tcp\xc0\x0c" .. "\x00\x0c\x00\x01\x00\x00\x01\x2c\x00\x0e" .. "\x0bMy.Web\\Site\xc0\x8c" ..
  "\xc0\xa3" .. "\x00\x21\x00\x01\x00\x00\x00\x78\x00\x17" .. "\x00\x01\x00\x02\x1f\x90\x03www\x07example\x03com\x00" ..
  "\xc0\x0c" .. "\x00\x02\x00\x01\x00\x01\x51\x80\x00\x06" .. "\x03ns1\xc0\x0c" ..
  "\xc0\x0c" .. "\x00\x06\x00\x01\x00\x00\x0e\x10\x00\x24" .. "\xc0\xe0" .. "\x0bhost.master\xc0\x0c" ..
  "\x78\xa3\xf1\x75\x00\x00\x1c\x20\x00\x00\x03\x84\x00\x12\x75\x00\xff\xff\xff\xff" ..
  "\xc0\xe0" .. "\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04" .. "\xc6\x33\x64\x07"

--- The message [`FULL`] and [`COMPRESSED`] hold, each record made from the field of its type.
local function every_type(): Dns.Message
  local function at(name: string, ttl: integer, rtype: integer): Dns.Record
    return { name = name, type = rtype, class = Dns.IN, cache_flush = false, ttl = ttl }
  end
  local instance = "My\\.Web\\\\Site._http._tcp.example.com"
  return {
    ...empty(),
    answers = {
      { ...at("example.com", 300, Dns.A), address = "192.0.2.1" },
      { ...at("example.com", 300, Dns.AAAA), address = "2001:db8::1" },
      { ...at("example.com", 300, Dns.CNAME), target = "www.example.com" },
      { ...at("example.com", 300, Dns.MX), mx = { preference = 10, exchange = "mail.example.com" } },
      { ...at("example.com", 300, Dns.TXT), txt = { "v=spf1 -all", "", "\xff\x00" } },
      { ...at("_http._tcp.example.com", 300, Dns.PTR), target = instance },
      { ...at(instance, 120, Dns.SRV), srv = { priority = 1, weight = 2, port = 8080, target = "www.example.com" } },
    },
    authorities = {
      { ...at("example.com", 86400, Dns.NS), target = "ns1.example.com" },
      {
        ...at("example.com", 3600, Dns.SOA),
        soa = {
          mname = "ns1.example.com",
          rname = "host\\.master.example.com",
          serial = 2024010101,
          refresh = 7200,
          retry = 900,
          expire = 1209600,
          minimum = 4294967295,
        },
      },
    },
    additionals = { { ...at("ns1.example.com", 60, Dns.A), address = "198.51.100.7" } },
  }
end

local function test_every_type_is_written_from_its_field()
  assert(Dns.encode(every_type()) == FULL)
end

local function test_every_type_is_read_into_its_field()
  local message = assert(Dns.decode(FULL))
  assert(message.id == 0x1234 and message.response and message.authoritative and message.recursion_desired)
  assert(not message.truncated and not message.recursion_available and message.rcode == 0)
  assert(#message.answers == 7 and #message.authorities == 2 and #message.additionals == 1)
  local function answer(i: integer, rtype: integer): Dns.Record
    local record = assert(message.answers[i])
    assert(record.type == rtype and record.class == Dns.IN and not record.cache_flush)
    return record
  end
  local a = answer(1, Dns.A)
  assert(a.address == "192.0.2.1" and a.rdata == "\xc0\x00\x02\x01" and a.ttl == 300 and a.name == "example.com")
  assert(a.target == nil and a.mx == nil and a.txt == nil and a.srv == nil and a.soa == nil)
  assert(answer(2, Dns.AAAA).address == "2001:db8::1")
  assert(answer(3, Dns.CNAME).target == "www.example.com")
  local mx = assert(answer(4, Dns.MX).mx)
  assert(mx.preference == 10 and mx.exchange == "mail.example.com")
  local txt = assert(answer(5, Dns.TXT).txt)
  assert(#txt == 3 and txt[1] == "v=spf1 -all" and txt[2] == "" and txt[3] == "\xff\x00")
  assert(answer(6, Dns.PTR).target == "My\\.Web\\\\Site._http._tcp.example.com")
  local service = answer(7, Dns.SRV)
  local srv = assert(service.srv)
  assert(service.name == "My\\.Web\\\\Site._http._tcp.example.com" and service.ttl == 120)
  assert(srv.priority == 1 and srv.weight == 2 and srv.port == 8080 and srv.target == "www.example.com")
  local ns, start = assert(message.authorities[1]), assert(message.authorities[2])
  assert(ns.type == Dns.NS and ns.target == "ns1.example.com" and ns.ttl == 86400)
  local soa = assert(start.soa)
  assert(start.type == Dns.SOA and soa.mname == "ns1.example.com" and soa.rname == "host\\.master.example.com")
  assert(soa.serial == 2024010101 and soa.refresh == 7200 and soa.retry == 900 and soa.expire == 1209600)
  assert(soa.minimum == 4294967295)
  assert(assert(message.additionals[1]).address == "198.51.100.7")
  assert(Dns.encode(message) == FULL)
end

--- What a compressed message holds is what the same message holds in full, so writing it back gives the full one.
local function test_a_compressed_response_reads_as_the_full_one()
  local message = assert(Dns.decode(COMPRESSED))
  assert(Dns.encode(message) == FULL)
  local cname, soa = assert(message.answers[3]), assert(message.authorities[2])
  assert(cname.target == "www.example.com" and cname.rdata == "\x03www\xc0\x0c")
  assert(assert(soa.soa).rname == "host\\.master.example.com")
  assert(assert(message.answers[7]).name == "My\\.Web\\\\Site._http._tcp.example.com")
end

local function test_an_ipv6_address_is_the_text_of_rfc_5952()
  local addresses: {string: string} = {
    ["2001:db8::1"] = "\x20\x01\x0d\xb8\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01",
    ["::"] = ("\x00"):rep(16),
    ["::1"] = ("\x00"):rep(15) .. "\x01",
    ["1::"] = "\x00\x01" .. ("\x00"):rep(14),
    -- One zero group is written, not shortened.
    ["2001:db8:0:1:1:1:1:1"] = "\x20\x01\x0d\xb8\x00\x00\x00\x01\x00\x01\x00\x01\x00\x01\x00\x01",
    ["1:2:3:4:5:6:7:0"] = "\x00\x01\x00\x02\x00\x03\x00\x04\x00\x05\x00\x06\x00\x07\x00\x00",
    -- The longest run of zeros is shortened, and the first of two as long.
    ["2001:0:0:1::1"] = "\x20\x01\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x01",
    ["2001:db8::1:0:0:1"] = "\x20\x01\x0d\xb8\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x01",
    ["fe80::1:0:0:0"] = "\xfe\x80\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00",
    ["::ffff:192.0.2.1"] = ("\x00"):rep(10) .. "\xff\xff\xc0\x00\x02\x01",
    ["64:ff9b::c000:221"] = "\x00\x64\xff\x9b" .. ("\x00"):rep(8) .. "\xc0\x00\x02\x21",
    ["abcd:ef01:2345:6789:abcd:ef01:2345:6789"] = "\xab\xcd\xef\x01\x23\x45\x67\x89\xab\xcd\xef\x01\x23\x45\x67\x89",
  }
  for text, bytes in pairs(addresses) do
    local read = answer_of(answering(Dns.AAAA, bytes))
    assert(read.address == text, read.address)
    local again = answer_of(written({ ...empty(), answers = { { ...read, rdata = nil } } }))
    assert(again.rdata == bytes, text)
  end
end

local function address_record(rtype: integer, address: string): Dns.Message
  return {
    ...empty(),
    answers = { { name = ".", type = rtype, class = Dns.IN, cache_flush = false, ttl = 0, address = address } },
  }
end

local function test_an_address_is_written_from_any_spelling_and_refused_when_it_is_none()
  local mapped = ("\x00"):rep(10) .. "\xff\xff\xc0\x00\x02\x01"
  local spellings: {string: string} = {
    ["2001:DB8:0:0:0:0:0:1"] = "\x20\x01\x0d\xb8\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01",
    ["2001:0db8::0001"] = "\x20\x01\x0d\xb8\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01",
    ["::FFFF:192.0.2.1"] = mapped,
    ["0:0:0:0:0:ffff:c000:201"] = mapped,
    ["0:0:0:0:0:ffff:192.0.2.1"] = mapped,
    ["1:2:3:4:5:6:7::"] = "\x00\x01\x00\x02\x00\x03\x00\x04\x00\x05\x00\x06\x00\x07\x00\x00",
    ["::2:3:4:5:6:7:8"] = "\x00\x00\x00\x02\x00\x03\x00\x04\x00\x05\x00\x06\x00\x07\x00\x08",
  }
  for text, bytes in pairs(spellings) do
    assert(answer_of(written(address_record(Dns.AAAA, text))).rdata == bytes, text)
  end
  for _, text in ipairs({ "", ":", "::g", "1::2::3", "1:::2", ":1::2", "1::2:", "12345::", "1:2:3:4:5:6:7",
      "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7::8", "1.2.3.4::", "::1.2.3", "::01.2.3.4", "1:2:3:4:5:6:7:1.2.3.4",
      "192.0.2.1", "2001:db8::1%eth0", " ::1" }) do
    unwritable(address_record(Dns.AAAA, text))
  end
  assert(answer_of(written(address_record(Dns.A, "0.10.200.255"))).rdata == "\x00\x0a\xc8\xff")
  for _, text in ipairs({ "", "1.2.3", "1.2.3.4.5", "256.1.1.1", "01.2.3.4", "1.2.3.", "a.b.c.d", "1.2.3.4 ", "::1",
      "1..3.4", "1111.2.3.4" }) do
    unwritable(address_record(Dns.A, text))
  end
end

local function test_txt_strings_keep_their_bytes_and_order()
  local read = answer_of(answering(Dns.TXT, "\x03a=1\x00\x04\x00\xff=\x80\x03a=2"))
  local txt = assert(read.txt)
  assert(#txt == 4 and txt[1] == "a=1" and txt[2] == "" and txt[3] == "\x00\xff=\x80" and txt[4] == "a=2")
  -- Data of no bytes is not what RFC 1035 allows, and RFC 6763 section 6.1 has it read as one empty string.
  local none = assert(answer_of(answering(Dns.TXT, "")).txt)
  assert(#none == 1 and none[1] == "")
  local function writing(strings: {string}): Dns.Message
    return {
      ...empty(),
      answers = { { name = ".", type = Dns.TXT, class = Dns.IN, cache_flush = false, ttl = 0, txt = strings } },
    }
  end
  assert(answer_of(written(writing({}))).rdata == "\x00")
  local longest = ("x"):rep(255)
  assert(answer_of(written(writing({ longest, "y" }))).rdata == "\xff" .. longest .. "\x01y")
  unwritable(writing({ "y", longest .. "x" }))
  refused(answering(Dns.TXT, "\x04a=1"))
  refused(answering(Dns.TXT, "\x03a=1\x01"))
end

--- The first of a key given twice stands (RFC 6763 section 6.4), whatever the case of either.
local function test_attributes_reads_keys_and_values()
  local attributes = Dns.attributes({ "Key=A", "flag", "=no", "", "kEY=B", "empty=", "a=b=c", "bin=\x00\xff", "FLAG=x" })
  assert(attributes["key"] == "A" and attributes["flag"] == "" and attributes["empty"] == "")
  assert(attributes["a"] == "b=c" and attributes["bin"] == "\x00\xff")
  assert(attributes["Key"] == nil and attributes[""] == nil and attributes["FLAG"] == nil)
  local count = 0
  for _ in pairs(attributes) do
    count = count + 1
  end
  assert(count == 5)
end

local function test_a_record_with_no_field_of_its_type_is_its_rdata()
  local unknown: Dns.Record = { name = "example.com", type = 65280, class = Dns.IN, cache_flush = false, ttl = 7,
    rdata = "\x00\xc0\x0c raw" }
  -- Another class gives the data of a type another shape: an A record of the Chaos class holds no four bytes.
  local chaos: Dns.Record = { name = "example.com", type = Dns.A, class = 3, cache_flush = false, ttl = 7,
    rdata = "\x01a\x00\x12\x34", address = "192.0.2.1" }
  local opaque: Dns.Record = { name = "example.com", type = Dns.MX, class = Dns.IN, cache_flush = false, ttl = 7,
    rdata = "\x00\x05\x00" }
  local wire = assert(Dns.encode({ ...empty(), answers = { unknown, chaos, opaque } }))
  local message = assert(Dns.decode(wire))
  local first, second, third = assert(message.answers[1]), assert(message.answers[2]), assert(message.answers[3])
  assert(first.type == 65280 and first.rdata == "\x00\xc0\x0c raw" and first.ttl == 7)
  assert(first.address == nil and first.target == nil and first.txt == nil)
  assert(second.class == 3 and second.rdata == "\x01a\x00\x12\x34" and second.address == nil)
  assert(assert(third.mx).preference == 5 and assert(third.mx).exchange == ".")
  assert(Dns.encode(message) == wire)
  unwritable({
    ...empty(),
    answers = { { name = "example.com", type = Dns.A, class = Dns.IN, cache_flush = false, ttl = 7 } },
  })
  -- The field of another type is not this record's data.
  unwritable({
    ...empty(),
    answers = { { name = "example.com", type = Dns.A, class = Dns.IN, cache_flush = false, ttl = 7, target = "a" } },
  })
  -- A field wins over the rdata beside it, so a decoded record with a field changed is written as changed.
  local moved = answer_of(written({
    ...empty(),
    answers = { { ...answer_of(answering(Dns.A, "\x0a\x00\x00\x01")), address = "10.0.0.2" } },
  }))
  assert(moved.rdata == "\x0a\x00\x00\x02")
end

--- Each bit and number of the header, alone, as the 16 bits it is on the wire.
local function test_the_header_is_its_fields()
  local base = Dns.query(".", Dns.NS, 0xffff)
  local words: {integer: Dns.Message} = {
    [0x0100] = base,
    [0x8000] = { ...base, response = true, recursion_desired = false },
    [0x0400] = { ...base, authoritative = true, recursion_desired = false },
    [0x0200] = { ...base, truncated = true, recursion_desired = false },
    [0x0080] = { ...base, recursion_available = true, recursion_desired = false },
    [0x0020] = { ...base, authentic_data = true, recursion_desired = false },
    [0x0010] = { ...base, checking_disabled = true, recursion_desired = false },
    [0x7800] = { ...base, opcode = 15, recursion_desired = false },
    [0x2800] = { ...base, opcode = 5, recursion_desired = false },
    [0x000f] = { ...base, rcode = 15, recursion_desired = false },
    [0x8183] = { ...base, response = true, recursion_available = true, rcode = 3 },
  }
  for word, message in pairs(words) do
    local wire = assert(Dns.encode(message))
    assert(wire:sub(1, 4) == "\xff\xff" .. string.char(word >> 8, word & 0xff), ("%04x"):format(word))
    local back = assert(Dns.decode(wire))
    assert(back.id == 0xffff and back.response == message.response and back.opcode == message.opcode)
    assert(back.authoritative == message.authoritative and back.truncated == message.truncated)
    assert(back.recursion_desired == message.recursion_desired)
    assert(back.recursion_available == message.recursion_available and back.rcode == message.rcode)
    assert(back.authentic_data == message.authentic_data and back.checking_disabled == message.checking_disabled)
  end
  -- The reserved bit is read as nothing.
  local reserved = assert(Dns.decode("\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00"))
  assert(Dns.encode(reserved) == ("\x00"):rep(12))
  for _, message in ipairs({ { ...base, id = 65536 }, { ...base, id = -1 }, { ...base, opcode = 16 },
      { ...base, rcode = 16 }, { ...base, rcode = -1 } }) do
    unwritable(message)
  end
end

--- The top bit of a record's class is multicast DNS's cache-flush bit, and is no part of `class`.
local function test_the_top_bit_of_a_class_is_not_the_class()
  local flushed: Dns.Record = { name = "host.local", type = Dns.A, class = Dns.IN, cache_flush = true, ttl = 120,
    address = "10.0.0.42" }
  local wire = assert(Dns.encode({ ...empty(), questions = {}, answers = { flushed } }))
  assert(wire:sub(13) == "\x04host\x05local\x00" .. "\x00\x01\x80\x01\x00\x00\x00\x78\x00\x04" .. "\x0a\x00\x00\x2a")
  local back = answer_of(wire)
  assert(back.cache_flush and back.class == Dns.IN and back.address == "10.0.0.42")
  unwritable({ ...empty(), answers = { { ...flushed, class = 0x8001 } } })
  unwritable({
    ...empty(),
    questions = { { name = "host.local", type = Dns.A, class = 0x8001, unicast_response = false } },
  })
end

local function test_reply_repeats_what_a_response_repeats()
  local query: Dns.Message = { ...Dns.query("example.com", Dns.MX, 77), opcode = 2, checking_disabled = true }
  local reply = Dns.reply(query)
  assert(reply.id == 77 and reply.response and reply.opcode == 2 and reply.recursion_desired)
  assert(reply.checking_disabled and not reply.authoritative and not reply.recursion_available and reply.rcode == 0)
  assert(#reply.questions == 1 and assert(reply.questions[1]).name == "example.com")
  assert(#reply.answers == 0 and #reply.authorities == 0 and #reply.additionals == 0)
end

local function test_encode_refuses_what_does_not_fit()
  local function record(fields: Dns.Record): Dns.Message
    return { ...empty(), additionals = { fields } }
  end
  local base: Dns.Record = { name = "a", type = 99, class = Dns.IN, cache_flush = false, ttl = 0, rdata = "" }
  assert(Dns.encode(record(base)))
  assert(Dns.encode(record({ ...base, type = 65535, class = 32767, ttl = 4294967295, rdata = ("x"):rep(65000) })))
  for _, fields in ipairs({
      { ...base, type = 65536 },
      { ...base, type = -1 },
      { ...base, class = 32768 },
      { ...base, ttl = 4294967296 },
      { ...base, ttl = -1 },
      { ...base, name = "a..b" },
      { ...base, name = ("a"):rep(64) },
      { ...base, rdata = ("x"):rep(65536) },
      -- Within a record's limit and past the message's.
      { ...base, rdata = ("x"):rep(65535) },
      { ...base, type = Dns.CNAME, target = "a\\" },
      { ...base, type = Dns.MX, mx = { preference = 65536, exchange = "a" } },
      { ...base, type = Dns.MX, mx = { preference = 1, exchange = ("a"):rep(64) } },
      { ...base, type = Dns.SRV, srv = { priority = 0, weight = 0, port = 65536, target = "a" } },
      { ...base, type = Dns.SRV, srv = { priority = 0, weight = -1, port = 1, target = "a" } },
      { ...base, type = Dns.SRV, srv = { priority = 0, weight = 0, port = 1, target = "a..b" } },
      { ...base, type = Dns.SOA,
          soa = { mname = "a", rname = "b", serial = 4294967296, refresh = 0, retry = 0, expire = 0, minimum = 0 } },
      { ...base, type = Dns.SOA,
          soa = { mname = "a", rname = "b\\9", serial = 0, refresh = 0, retry = 0, expire = 0, minimum = 0 } },
  }) do
    unwritable(record(fields))
  end
  unwritable({ ...empty(), questions = { { name = "a", type = 65536, class = Dns.IN, unicast_response = false } } })
end

--- A pointer leads back, before the labels it follows, so none leads to itself, forward, or round a loop.
local function test_a_pointer_that_does_not_lead_back_is_refused()
  for _, name in ipairs({
      "\xc0\x0c", -- to itself
      "\xc0\x0e\xc0\x0c", -- forward to one that leads back to it
      "\x01a\xc0\x0c", -- back to the label before it
      "\xc0\x0d", -- into itself
      "\xc0\x10\x00", -- forward, to a root that is there
      "\xc0\x7f", -- past the end
      "\xc0\x00", -- into the header
      "\xc0\x0b", -- into the header's last byte
      "\xff\xff",
  }) do
    refused(asking(name))
  end
  -- The second question's pointer leads to the first's, which leads to its name: two jumps, each further back.
  local chained = assert(Dns.decode(header(3, 0) .. "\x01a\x00\x00\x01\x00\x01" .. "\x01b\xc0\x0c\x00\x01\x00\x01" ..
      "\x01c\xc0\x13\x00\x01\x00\x01"))
  assert(assert(chained.questions[3]).name == "c.b.a")
end

--- A chain of pointers costs a read of each for every name behind it, so a name follows 127 at most.
local function test_a_name_follows_a_bounded_chain_of_pointers()
  local function chain(count: integer): string
    local parts: mut {string} = { "\x00\x00\x00\x00\x00\x00", string.char(count >> 8, count & 0xff), "\x00\x00\x00\x00",
      "\x01a\x00", "\x00\x63\x00\x01\x00\x00\x00\x00\x00\x00" }
    for i = 2, count do
      -- Record i's name is a pointer to that of the record before: the first is at offset 12 and takes 13
      -- bytes, each after it 12.
      local target = if i == 2 then 12 else 25 + 12 * (i - 3) end
      local record = string.char(0xc0 | target >> 8, target & 0xff) .. "\x00\x63\x00\x01\x00\x00\x00\x00\x00\x00"
      parts[#parts + 1] = record
    end
    return table.concat(parts)
  end
  local most = assert(Dns.decode(chain(128)))
  assert(#most.answers == 128 and assert(most.answers[128]).name == "a")
  refused(chain(129))
end

local function test_a_malformed_message_is_refused()
  refused("")
  refused(("\x00"):rep(11))
  -- Reserved bits where a label's length is.
  refused(asking("\x40a\x00"))
  refused(asking("\x80a\x00"))
  -- A label, a question, a record and its data that the bytes end inside.
  refused(header(1, 0) .. "\x03ab")
  refused(header(1, 0) .. "\x01a\x00\x00\x01\x00")
  refused(header(0, 1) .. "\x00\x00\x01\x00\x01\x00\x00\x00\x00\x00")
  refused(header(0, 1) .. "\x00\x00\x63\x00\x01\x00\x00\x00\x00\x00\x05abcd")
  -- Bytes after the last record.
  refused(asking("\x01a\x00") .. "\x00")
  refused(header(0, 0) .. "\x00")
  -- Data that is not the shape of its type.
  refused(answering(Dns.A, "\x0a\x00\x00"))
  refused(answering(Dns.A, "\x0a\x00\x00\x01\x02"))
  refused(answering(Dns.AAAA, ("\x00"):rep(15)))
  refused(answering(Dns.AAAA, ("\x00"):rep(4)))
  refused(answering(Dns.PTR, "\x03foo\x00x"))
  refused(answering(Dns.PTR, ""))
  refused(answering(Dns.NS, "\x03fo"))
  refused(answering(Dns.CNAME, "\xc0\x30"))
  refused(answering(Dns.MX, "\x00\x0a"))
  refused(answering(Dns.MX, "\x00\x0a\x01a\x00\x00"))
  refused(answering(Dns.SRV, "\x00\x0a\x00"))
  refused(answering(Dns.SRV, "\x00\x00\x00\x00\x00\x50\x01a"))
  refused(answering(Dns.SOA, "\x00\x00" .. ("\x00"):rep(19)))
  refused(answering(Dns.SOA, "\x00\x00" .. ("\x00"):rep(21)))
  assert(answer_of(answering(Dns.SOA, "\x00\x00" .. ("\x00"):rep(20))).soa)
  -- A name in a record's data that ends in the record after it.
  refused(header(0, 2) .. "\x00\x00\x0c\x00\x01\x00\x00\x00\x00\x00\x02\x01a" ..
      "\x00\x00\x63\x00\x01\x00\x00\x00\x00\x00\x00")
end

--- A header that counts what the bytes cannot hold is refused by its counts, with no record read.
local function test_lying_counts_are_refused()
  refused("\x00\x00\x00\x00\xff\xff\xff\xff\xff\xff\xff\xff")
  refused("\x00\x00\x00\x00\x00\x00\xff\xff\x00\x00\x00\x00")
  refused(header(2, 0) .. "\x00\x00\x01\x00\x01")
  refused(header(1, 1) .. "\x00\x00\x01\x00\x01")
  refused(header(1, 0))
  refused(header(1, 0) .. "\x00\x00\x01\x00")
  assert(#assert(Dns.decode(header(1, 0) .. "\x00\x00\x01\x00\x01")).questions == 1)
  -- Fewer counted than are there.
  refused(header(0, 0) .. "\x00\x00\x01\x00\x01")
end

--- No cut and no changed byte makes decode raise, or answer nil without a reason.
local function test_decode_never_raises()
  for length = 0, #COMPRESSED - 1 do
    refused(COMPRESSED:sub(1, length))
  end
  for length = 0, #FULL - 1 do
    refused(FULL:sub(1, length))
  end
  local state = 1
  local function random(limit: integer): integer
    state = (state * 6364136223846793005 + 1442695040888963407) & 0x7fffffffffffffff
    return (state >> 33) % limit
  end
  local read = 0
  for _ = 1, 4000 do
    local at = 1 + random(#COMPRESSED)
    local changed = COMPRESSED:sub(1, at - 1) .. string.char(random(256)) .. COMPRESSED:sub(at + 1)
    local message, why = Dns.decode(changed)
    assert((message == nil) ~= (why == ""))
    if message ~= nil then
      read = read + 1
      -- What decode gives, encode takes: every name and number in it fits.
      assert(Dns.decode(written(message)))
    end
  end
  assert(read > 400 and read < 4000, tostring(read))
end
