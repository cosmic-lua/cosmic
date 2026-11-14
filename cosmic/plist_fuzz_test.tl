--- Fuzz properties for [`cosmic.plist`], whose decoders take the bytes anyone sends: neither raises, each
--- answers a value or a reason and never both, and what one reads is written in both forms and read again as
--- the same bytes. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Plist = require("cosmic.plist")

--- Text a string or a key may hold: ASCII, what takes UTF-16, what XML escapes, and what XML cannot carry.
local TEXTS <const>: {string} = { "", "a", "key", "CF$UID", "$null", "h\u{E9}", "\u{1F600}", "<&>", "a\rb", "\r\n", " \t\n",
  "]]>", "\0", "a\1", "\u{FFFE}", "\u{FFFF}", "\u{FFFD}", ("x"):rep(15), ("\u{E9}"):rep(15) }

local INTEGERS <const>: {integer} = { 0, 1, -1, 255, 256, 65535, 65536, 4294967295, 4294967296, math.maxinteger,
  math.mininteger }

local REALS <const>: {number} = { 0.0, -0.0, 1.0, -1.5, 0.1, 1e100, 5e-324, 1e16, 1e15, 0.0001, 0.00001, math.huge,
  -math.huge, 0.0 / 0.0 }

--- Dates of whole seconds and not, within the years XML holds and outside them, and ones a last bit apart.
local DATES <const>: {number} = { 0.0, 978307200.0, 1794659696.5, -0.5, -62135596800.0, 253402300799.0, 253402300800.0,
  -62135596801.0, 1e300, 2.0 ^ -60, 0.1, 978307200.1 }

--- A value of any kind, with arrays and dicts down to `depth` more levels.
local function gen_value(src: Fuzz.Source, depth: integer): Plist.Value
  local kind = src:int(1, if depth > 0 then 12 else 8 end)
  if kind == 1 then
    return Plist.boolean(src:int(0, 1) == 1)
  elseif kind == 2 then
    return Plist.integer(Fuzz.pick(src, INTEGERS), src:int(0, 3) == 0)
  elseif kind == 3 then
    return Plist.real(Fuzz.pick(src, REALS))
  elseif kind == 4 or kind == 5 then
    return Plist.string(Fuzz.pick(src, TEXTS))
  elseif kind == 6 then
    return Plist.data(Fuzz.bytes(src, 20))
  elseif kind == 7 then
    return Plist.date(Fuzz.pick(src, DATES))
  elseif kind == 8 then
    return Plist.uid(Fuzz.pick(src, { 0, 1, 255, 256, 65536, 4294967296, math.maxinteger }))
  elseif kind == 9 or kind == 10 then
    local items: mut {Plist.Value} = {}
    while Fuzz.more(src, #items, 5) do
      -- One table at two places, now and then: one object in the binary form.
      local item = if #items > 0 and src:int(0, 4) == 0 then assert(items[1]) else gen_value(src, depth - 1) end
      items[#items + 1] = item
    end
    return Plist.array(items)
  end
  local entries: mut {Plist.Entry} = {}
  while Fuzz.more(src, #entries, 4) do
    -- Each key once: its place in the dict sets it apart from a key drawn before.
    local key = Fuzz.pick(src, TEXTS) .. (if #entries == 0 then "" else tostring(#entries) end)
    local entry: Plist.Entry = { key = key, value = gen_value(src, depth - 1) }
    entries[#entries + 1] = entry
  end
  return Plist.dict(entries)
end

--- A value as the binary form's bytes.
local function gen_binary(src: Fuzz.Source): string
  local bytes = assert(Plist.encode(gen_value(src, 3)))
  return bytes
end

--- Objects of the binary form, whole and cut short, of every type and of none.
local OBJECTS <const>: {string} = { "\x00", "\x08", "\x09", "\x10\x07", "\x11\x01\x00", "\x13\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF",
  "\x14\0\0\0\0\0\0\0\0\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF", "\x14\0\0\0\0\0\0\0\1\0\0\0\0\0\0\0\0", "\x22\x3F\xC0\0\0",
  "\x23\x3F\xF8\0\0\0\0\0\0", "\x33\x41\xB8\x45\xA8\xC0\0\0\0", "\x33\x7F\xF8\0\0\0\0\0\0", "\x40", "\x42\x00\xFF", "\x4F\x10\x01z",
  "\x4F\x13\x7F\xFF\xFF\xFF\xFF\xFF\xFF\xFF", "\x51k", "\x52CF", "\x51\x80", "\x61\x00k", "\x61\xD8\x3D", "\x62\xD8\x3D\xDE\x00",
  "\x80\x07", "\x87\x80\0\0\0\0\0\0\0", "\xC0", "\x70", "\x1F" }

--- A binary property list whose frame is sound and whose objects are any: scalars from `OBJECTS`, and arrays
--- and dicts that refer to any object, themselves and objects that are not there included.
local function gen_objects(src: Fuzz.Source): string
  local count = src:int(1, 10)
  local parts: mut {string} = { "bplist00" }
  local offsets: mut {integer} = {}
  local at = 8
  for _ = 1, count do
    local kind = src:int(0, 5)
    local object: string
    if kind <= 2 then
      object = Fuzz.pick(src, OBJECTS)
    else
      local refs: mut {string} = {}
      local length = src:int(0, 3)
      for _ = 1, if kind == 5 then length * 2 else length end do
        local ref = string.char(src:int(0, count))
        refs[#refs + 1] = ref
      end
      object = string.char((if kind == 5 then 0xD0 else 0xA0 end) | length) .. table.concat(refs)
    end
    offsets[#offsets + 1] = at
    parts[#parts + 1] = object
    at = at + #object
  end
  for _, offset in ipairs(offsets) do
    local packed = string.char(offset & 0xFF)
    parts[#parts + 1] = packed
  end
  local trailer = string.pack(">I5BBBi8i8i8", 0, 0, 1, 1, count, src:int(0, count - 1), at)
  parts[#parts + 1] = trailer
  return table.concat(parts)
end

--- An array that holds a dict whose value is the array.
local CYCLE <const> = "bplist00\xA2\x01\x02\x09\xD1\x03\x00\x51k\x08\x0B\x0C\x0F" ..
  string.pack(">I5BBBi8i8i8", 0, 0, 1, 1, 4, 0, 17)

--- Pieces an XML property list is strung from, well-formed and not.
local PIECES <const>: {string} = { "<dict>", "</dict>", "<array>", "</array>", "<array/>", "<dict/>", "<key>k</key>", "<key>j</key>",
  "<key>CF$UID</key>", "<key/>", "<string>s</string>", "<string/>", "<string>a&#13;b&amp;</string>", "<integer>7</integer>",
  "<integer>-1</integer>", "<integer>0xff</integer>", "<integer>18446744073709551615</integer>",
  "<integer>18446744073709551616</integer>", "<integer>x</integer>", "<real>1.5</real>", "<real>nan</real>", "<real>-inf</real>",
  "<real>-0.0</real>", "<real>1e400</real>", "<real>x</real>", "<true/>", "<false/>", "<true>x</true>",
  "<date>2026-11-14T12:34:56Z</date>", "<date>0001-01-01T00:00:00Z</date>", "<date>2021-02-29T00:00:00Z</date>",
  "<data>aGVsbG8=</data>", "<data>\n\taGVs\n\tbG8=\n</data>", "<data>!</data>", "<set/>", "text", " ", "\n\t", "<!-- note -->",
  "<![CDATA[<x>]]>", "&e;", "<", "\0" }

--- An XML document: a prolog or none, a `plist` root or another, and pieces inside it.
local function gen_document(src: Fuzz.Source): string
  local parts: mut {string} = {}
  if src:int(0, 3) == 0 then parts[#parts + 1] = '<?xml version="1.0" encoding="UTF-8"?>\n' end
  if src:int(0, 5) == 0 then parts[#parts + 1] = '<!DOCTYPE plist [<!ENTITY e "entity">]>' end
  local root = if src:int(0, 9) == 0 then "array" else "plist" end
  parts[#parts + 1] = "<" .. root .. ">"
  local closers: mut {string} = {}
  while Fuzz.more(src, #parts, 24) do
    local piece = Fuzz.pick(src, PIECES)
    -- An opening tag is closed in its turn more often than not, so that documents nest and still read.
    if (piece == "<dict>" or piece == "<array>") and src:int(0, 5) ~= 0 then
      closers[#closers + 1] = "</" .. piece:sub(2)
    elseif #closers > 0 and src:int(0, 2) == 0 then
      piece = assert(table.remove(closers))
    end
    parts[#parts + 1] = piece
  end
  for i = #closers, 1, -1 do
    local closer = assert(closers[i])
    parts[#parts + 1] = closer
  end
  parts[#parts + 1] = "</" .. root .. ">"
  return table.concat(parts)
end

--- Checks what holds of any value a decoder read: it is written in the binary form, which reads and is
--- written again as the same bytes. In the XML form it is written, or refused with a reason, as a control
--- character or a date past the years XML holds is; what is written reads and is written again as the same
--- text. Answers that text, or "" where XML refused the value.
local function written_both_ways(value: Plist.Value): boolean, string, string
  local binary, binary_why = Plist.encode(value)
  if binary == nil then return false, "what was read is not written: " .. binary_why, "" end
  local again, again_why = Plist.decode(binary)
  if again == nil then return false, "what was written is not read: " .. again_why, "" end
  local twice, twice_why = Plist.encode(again)
  if twice ~= binary then
    return false, "written twice, the binary form differs: " .. twice_why, ""
  end
  local text, text_why = Plist.encode(value, { form = "xml" })
  if text == nil then
    if text_why == "" then return false, "XML refused the value without a reason", "" end
    Fuzz.label("XML cannot hold it")
    return true, "", ""
  end
  Fuzz.label("XML holds it")
  local from_text, from_why = Plist.decode(text)
  if from_text == nil then
    return false, "the XML that was written is not read: " .. from_why .. "\n" .. text, ""
  end
  local text_twice, text_twice_why = Plist.encode(from_text, { form = "xml" })
  if text_twice ~= text then
    return false, "written twice, the XML form differs: " .. text_twice_why .. "\n" .. text .. "\n" .. (text_twice or ""), ""
  end
  return true, "", text
end

local function test_binary_decode_is_total_and_what_it_reads_is_written_back(tmp: string)
  Fuzz.run({
    name = "plist binary decode",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local kind = src:int(0, 6)
      if kind == 0 then return "bplist00" .. Fuzz.bytes(src, 64) end
      if kind == 1 then return Fuzz.mutate(src, CYCLE, 1) end
      if kind <= 3 then return Fuzz.mutate(src, gen_objects(src), 2) end
      return Fuzz.mutate(src, gen_binary(src), 3)
    end,
    check = function(input: string): boolean, string
      local value, why = Plist.decode(input)
      if value == nil then
        if why:sub(1, 7) ~= "plist: " then
          return false, "refused without a reason of the module's: " .. why
        end
        Fuzz.label("refused")
        if why:find("holds itself", 1, true) ~= nil then Fuzz.label("refused a cycle") end
        return true, ""
      end
      if why ~= "" then return false, "read with a reason: " .. why end
      Fuzz.label("read")
      if value.kind == "array" or value.kind == "dict" then Fuzz.label("read a container") end
      local ok, trouble = written_both_ways(value)
      return ok, trouble
    end,
    requires = { "refused", "refused a cycle", "read", "read a container", "XML holds it" },
    shares = { refused = 0.1, read = 0.1 },
  })
end

local function test_xml_decode_is_total_and_what_it_reads_is_written_back(tmp: string)
  Fuzz.run({
    name = "plist xml decode",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local kind = src:int(0, 3)
      if kind == 0 then return Fuzz.mutate(src, gen_document(src), 2) end
      if kind <= 2 then
        -- An array of a value, as this module writes it, so that a share of the inputs are whole documents.
        local text = Plist.encode(Plist.array({ gen_value(src, 3) }), { form = "xml" })
        if text ~= nil then return Fuzz.mutate(src, text, 1) end
      end
      return gen_document(src)
    end,
    check = function(input: string): boolean, string
      local value, why = Plist.decode(input)
      if value == nil then
        if why:sub(1, 7) ~= "plist: " then
          return false, "refused without a reason of the module's: " .. why
        end
        Fuzz.label("refused")
        return true, ""
      end
      if why ~= "" then return false, "read with a reason: " .. why end
      Fuzz.label("read")
      if value.kind == "array" or value.kind == "dict" then Fuzz.label("read a container") end
      local ok, trouble, text = written_both_ways(value)
      if not ok then return false, trouble end
      -- XML's own text holds nothing XML cannot, and the binary form carries all of it: by way of binary,
      -- the same XML is written.
      if text == "" then return false, "what XML held is not written to XML" end
      local binary = assert(Plist.encode(value))
      local by_binary, by_why = Plist.encode(assert(Plist.decode(binary)), { form = "xml" })
      if by_binary ~= text then
        return false, "by way of the binary form, the XML differs: " .. by_why
      end
      return true, ""
    end,
    requires = { "refused", "read", "read a container" },
    shares = { refused = 0.1, read = 0.05 },
  })
end

local function test_a_written_value_is_read_as_written(tmp: string)
  Fuzz.run({
    name = "plist encode round trip",
    dir = tmp,
    gen = gen_binary,
    check = function(input: string): boolean, string
      local value, why = Plist.decode(input)
      if value == nil then return false, "what was written is not read: " .. why end
      local bytes, encode_why = Plist.encode(value)
      if bytes ~= input then return false, "read and written again, it differs: " .. encode_why end
      local ok, trouble = written_both_ways(value)
      return ok, trouble
    end,
    requires = { "XML holds it", "XML cannot hold it" },
  })
end
