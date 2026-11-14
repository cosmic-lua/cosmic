--- Fuzz properties for [`cosmic.dns`], whose decoder takes the bytes anyone sends: it never raises, it answers a
--- message or a reason and never both, and what it accepts is written back and read again as the same message.
--- A name's text reads back as its labels, whatever their bytes. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).

local Dns = require("cosmic.dns")
local Fuzz = require("build.fuzz")

--- Bytes a name's text singles out, and ones that pass through it.
local LABEL_BYTES <const> = ".\\0129 a\x00\x1f\x7f\x80\xff"

local function gen_label(src: Fuzz.Source, max: integer): string
  local out: mut {string} = {}
  while Fuzz.more(src, #out, max) do
    local at = src:int(0, #LABEL_BYTES)
    local byte = if at == 0 then string.char(src:int(0, 255)) else LABEL_BYTES:sub(at, at) end
    out[#out + 1] = byte
  end
  if #out == 0 then return "a" end
  return table.concat(out)
end

local function gen_labels(src: Fuzz.Source): {string}
  local labels: mut {string} = {}
  while Fuzz.more(src, #labels, 6) do
    local label = gen_label(src, 12)
    labels[#labels + 1] = label
  end
  return labels
end

--- A name that is one: of a few short labels of any bytes.
local function gen_name(src: Fuzz.Source): string
  local name = assert(Dns.name(gen_labels(src)))
  return name
end

local function gen_record(src: Fuzz.Source): Dns.Record
  local kind = src:int(0, 10)
  local base: Dns.Record = { name = gen_name(src), type = 65280 + kind, class = Dns.IN, cache_flush = src:int(0, 1) == 1,
    ttl = src:int(0, 4294967295) }
  if kind == 1 then
    return { ...base, type = Dns.A, address = ("%d.%d.0.255"):format(src:int(0, 255), src:int(0, 255)) }
  elseif kind == 2 then
    local groups = { "0", "0", "1", "ffff", "0", "0", "0", "abc" }
    return { ...base, type = Dns.AAAA, address = table.concat(groups, ":", src:int(2, 8)) .. "::" }
  elseif kind == 3 then
    return { ...base, type = Fuzz.pick(src, { Dns.NS, Dns.CNAME, Dns.PTR }), target = gen_name(src) }
  elseif kind == 4 then
    return { ...base, type = Dns.MX, mx = { preference = src:int(0, 65535), exchange = gen_name(src) } }
  elseif kind == 5 then
    local txt: mut {string} = {}
    while Fuzz.more(src, #txt, 4) do
      local text = Fuzz.bytes(src, 20)
      txt[#txt + 1] = text
    end
    return { ...base, type = Dns.TXT, txt = txt }
  elseif kind == 6 then
    return {
      ...base,
      type = Dns.SRV,
      srv = { priority = src:int(0, 65535), weight = src:int(0, 65535), port = src:int(0, 65535), target = gen_name(src) },
    }
  elseif kind == 7 then
    return {
      ...base,
      type = Dns.SOA,
      soa = {
        mname = gen_name(src),
        rname = gen_name(src),
        serial = src:int(0, 4294967295),
        refresh = src:int(0, 4294967295),
        retry = src:int(0, 4294967295),
        expire = src:int(0, 4294967295),
        minimum = src:int(0, 4294967295),
      },
    }
  elseif kind == 8 then
    -- A class other than the internet's, whose data is read as no type's.
    return { ...base, type = Dns.A, class = src:int(2, 32767), rdata = Fuzz.bytes(src, 12) }
  end
  return { ...base, rdata = Fuzz.bytes(src, 12) }
end

local function gen_records(src: Fuzz.Source): {Dns.Record}
  local records: mut {Dns.Record} = {}
  while Fuzz.more(src, #records, 3) do
    local record = gen_record(src)
    records[#records + 1] = record
  end
  return records
end

--- A message of any header and a few questions and records, as [`Dns.encode`] writes it.
local function gen_message(src: Fuzz.Source): string
  local questions: mut {Dns.Question} = {}
  while Fuzz.more(src, #questions, 2) do
    local question: Dns.Question = { name = gen_name(src), type = src:int(0, 65535), class = src:int(0, 32767),
      unicast_response = src:int(0, 1) == 1 }
    questions[#questions + 1] = question
  end
  local message: Dns.Message = {
    id = src:int(0, 65535),
    response = src:int(0, 1) == 1,
    opcode = src:int(0, 15),
    authoritative = src:int(0, 1) == 1,
    truncated = src:int(0, 1) == 1,
    recursion_desired = src:int(0, 1) == 1,
    recursion_available = src:int(0, 1) == 1,
    authentic_data = src:int(0, 1) == 1,
    checking_disabled = src:int(0, 1) == 1,
    rcode = src:int(0, 15),
    questions = questions,
    answers = gen_records(src),
    authorities = gen_records(src),
    additionals = gen_records(src),
  }
  local bytes = assert(Dns.encode(message))
  return bytes
end

--- A response a compressing server wrote: a pointer for the name of each record, into its data and out of it.
local COMPRESSED <const> = "\x12\x34\x85\x00\x00\x01\x00\x03\x00\x01\x00\x01" ..
  "\x07example\x03com\x00\x00\x01\x00\x01" ..
  "\xc0\x0c\x00\x05\x00\x01\x00\x00\x01\x2c\x00\x06\x03www\xc0\x0c" ..
  "\xc0\x29\x00\x0f\x00\x01\x00\x00\x01\x2c\x00\x09\x00\x0a\x04mail\xc0\x0c" ..
  "\xc0\x29\x00\x21\x80\x01\x00\x00\x00\x78\x00\x08\x00\x01\x00\x02\x1f\x90\xc0\x3d" ..
  "\xc0\x0c\x00\x06\x00\x01\x00\x00\x0e\x10\x00\x21\x03ns1\xc0\x0c\x04host\xc0\x0c" ..
  "\x78\xa3\xf1\x75\x00\x00\x1c\x20\x00\x00\x03\x84\x00\x12\x75\x00\x00\x00\x01\x2c" ..
  "\xc0\x64\x00\x1c\x00\x01\x00\x00\x00\x3c\x00\x10\x20\x01\x0d\xb8\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01"

local function test_decode_is_total_and_what_it_reads_is_written_back(tmp: string)
  Fuzz.run({
    name = "dns decode",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local kind = src:int(0, 3)
      if kind == 0 then return Fuzz.bytes(src, 64) end
      return Fuzz.mutate(src, if kind == 1 then COMPRESSED else gen_message(src) end, 3)
    end,
    check = function(input: string): boolean, string
      local message, why = Dns.decode(input)
      if message == nil then
        if why == "" then return false, "refused without a reason" end
        Fuzz.label("refused")
        return true, ""
      end
      if why ~= "" then return false, "read with a reason: " .. why end
      Fuzz.label("read")
      if #message.answers + #message.authorities + #message.additionals > 0 then
        Fuzz.label("read a record")
      end
      -- Every name and number of a message that was read fits, so it is written, and what is written holds the
      -- same message: reading and writing it again changes no byte.
      local bytes, encode_why = Dns.encode(message)
      if bytes == nil then return false, "what was read is not written: " .. encode_why end
      local again, again_why = Dns.decode(bytes)
      if again == nil then return false, "what was written is not read: " .. again_why end
      if #again.questions ~= #message.questions or #again.answers ~= #message.answers or
          #again.authorities ~= #message.authorities or #again.additionals ~= #message.additionals then
        return false, "a question or a record was lost"
      end
      local twice, twice_why = Dns.encode(again)
      if twice ~= bytes then return false, "written twice, it differs: " .. twice_why end
      return true, ""
    end,
    requires = { "refused", "read", "read a record" },
    shares = { refused = 0.1, read = 0.1 },
  })
end

local function test_an_encoded_message_is_read_as_written(tmp: string)
  Fuzz.run({
    name = "dns encode round trip",
    dir = tmp,
    gen = gen_message,
    check = function(input: string): boolean, string
      local message, why = Dns.decode(input)
      if message == nil then return false, "what was written is not read: " .. why end
      local bytes, encode_why = Dns.encode(message)
      if bytes ~= input then return false, "read and written again, it differs: " .. encode_why end
      return true, ""
    end,
  })
end

local function test_a_name_reads_back_as_its_labels(tmp: string)
  Fuzz.run({
    name = "dns name round trip",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local labels: mut {string} = {}
      while Fuzz.more(src, #labels, 8) do
        local label = gen_label(src, 70)
        labels[#labels + 1] = label
      end
      return Fuzz.pack(labels)
    end,
    check = function(input: string): boolean, string
      local labels = Fuzz.unpack(input)
      local size = 1
      local fits = true
      for _, label in ipairs(labels) do
        size = size + 1 + #label
        fits = fits and #label <= 63
      end
      fits = fits and size <= 255
      local name, why = Dns.name(labels)
      if name == nil then
        if fits then return false, "a name that fits was refused: " .. why end
        Fuzz.label("too long")
        return true, ""
      end
      if not fits then return false, "a name that does not fit has the text " .. name end
      Fuzz.label("named")
      local back, back_why = Dns.labels(name)
      if back == nil then return false, ("the text %q is not read: %s"):format(name, back_why) end
      if #back ~= #labels or table.concat(back, "\0.") ~= table.concat(labels, "\0.") then
        return false, ("the text %q reads as other labels"):format(name)
      end
      return true, ""
    end,
    requires = { "named", "too long" },
  })
end

local function test_labels_is_total(tmp: string)
  Fuzz.run({
    name = "dns labels",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local parts: mut {string} = {}
      while Fuzz.more(src, #parts, 6) do
        local part = gen_label(src, 8)
        parts[#parts + 1] = part
      end
      return table.concat(parts, Fuzz.pick(src, { ".", "", "\\" }))
    end,
    check = function(input: string): boolean, string
      local labels, why = Dns.labels(input)
      if labels == nil then
        if why == "" then return false, "refused without a reason" end
        Fuzz.label("refused")
        return true, ""
      end
      if why ~= "" then return false, "read with a reason: " .. why end
      Fuzz.label("read")
      -- What was read is a name: it has a text, and the text reads as the same labels.
      local name, name_why = Dns.name(labels)
      if name == nil then return false, "labels that were read have no text: " .. name_why end
      local back = Dns.labels(name)
      if back == nil or table.concat(back, "\0.") ~= table.concat(labels, "\0.") then
        return false, ("%q read, written as %q, reads as other labels"):format(input, name)
      end
      return true, ""
    end,
    requires = { "refused", "read" },
  })
end
