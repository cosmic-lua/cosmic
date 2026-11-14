--- Worked examples for [`cosmic.plist`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Codec = require("cosmic.codec")
local Plist = require("cosmic.plist")

local record Example end

--- An application's `Info.plist`, as XML: decode reads it, and [`Plist.get`] finds a key's value, whose
--- `kind` says which field holds it.
function Example.decode()
  local text = [[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Notes</string>
	<key>LSMinimumSystemVersion</key>
	<real>14.5</real>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
]]
  local info = assert(Plist.decode(text))
  local name = assert(Plist.get(info, "CFBundleName"))
  print(name.kind, name.text)
  assert(name.kind == "string" and name.text == "Notes")
  assert(assert(Plist.get(info, "NSHighResolutionCapable")).boolean == true)
  assert(Plist.get(info, "CFBundleVersion") == nil)
end

--- The same call reads the binary form. Here an array of an integer and a string, as `plutil -convert
--- binary1` or Python's `plistlib` writes it: two objects, the offset of each, and a trailer.
function Example.decode_binary()
  local bytes = assert(Codec.unhex("62706c6973743030a201021007526869080b0d" ..
      "0000000000000101000000000000000300000000000000000000000000000010"))
  local value = assert(Plist.decode(bytes))
  local items = assert(value.items)
  local number, text = assert(items[1]), assert(items[2])
  print(number.integer, text.text)
  assert(number.kind == "integer" and number.integer == 7 and text.text == "hi")
end

--- Bytes that are no property list are a failure to handle, never a raise. Here a binary one whose array
--- refers to itself, and XML whose integer is not one: the reason names the object, or the keys that lead
--- to the element.
function Example.decode_refuses()
  local cycle = "bplist00" .. "\xA1\x00" .. "\x08" .. ("\0"):rep(6) .. "\x01\x01" ..
    string.pack(">I8I8I8", 1, 0, 10)
  local value, why = Plist.decode(cycle)
  assert(value == nil)
  print(why) -- plist: object 0 holds itself
  local none, xml_why = Plist.decode("<plist><dict><key>port</key><integer>http</integer></dict></plist>")
  assert(none == nil)
  print(xml_why) -- plist: not an integer from -2^63 to 2^64 - 1 (at port)
end

--- A value is built with the function named for each kind, a dict from entries in the order they are to
--- stay in, and encode writes it: the binary form unless told the XML one. Read back, it is the same value.
function Example.encode()
  local settings = Plist.dict({
    { key = "name", value = Plist.string("backup") },
    { key = "enabled", value = Plist.boolean(true) },
    { key = "hosts", value = Plist.array({ Plist.string("a.example"), Plist.string("b.example") }) },
    { key = "retries", value = Plist.integer(3) },
    { key = "timeout", value = Plist.real(2.5) },
  })
  local binary = assert(Plist.encode(settings))
  assert(binary:sub(1, 8) == "bplist00")
  local xml = assert(Plist.encode(settings, { form = "xml" }))
  print(xml)
  local back = assert(Plist.decode(xml))
  local entries = assert(back.entries)
  assert(#entries == 5 and assert(entries[1]).key == "name" and assert(entries[5]).value.real == 2.5)
  assert(assert(Plist.encode(back)) == binary)
end

--- With `sort_keys` a dict is written in the order of its keys, whatever order it holds them in, so two
--- programs that build the same dict write the same bytes.
function Example.encode_sorted()
  local one = Plist.dict({ { key = "b", value = Plist.integer(2) }, { key = "a", value = Plist.integer(1) } })
  local other = Plist.dict({ { key = "a", value = Plist.integer(1) }, { key = "b", value = Plist.integer(2) } })
  assert(Plist.encode(one) ~= Plist.encode(other))
  assert(Plist.encode(one, { sort_keys = true }) == Plist.encode(other, { sort_keys = true }))
end

--- Text and bytes are two types, and so are an integer and a real: each is written as what it is, and read
--- back as it. An integer past a signed 64 bits is its bits, marked `unsigned`.
function Example.kinds()
  local value = Plist.array({ Plist.string("caf\u{E9}"), Plist.data("\xCA\xFE"), Plist.integer(1), Plist.real(1),
    Plist.integer(-1, true) })
  local xml = assert(Plist.encode(value, { form = "xml" }))
  assert(xml:find("<string>caf\u{E9}</string>", 1, true) ~= nil and xml:find("yv4=", 1, true) ~= nil)
  assert(xml:find("<integer>1</integer>", 1, true) ~= nil and xml:find("<real>1.0</real>", 1, true) ~= nil)
  assert(xml:find("<integer>18446744073709551615</integer>", 1, true) ~= nil)
  local items = assert(assert(Plist.decode(xml)).items)
  local kinds: mut {string} = {}
  for _, item in ipairs(items) do kinds[#kinds + 1] = item.kind end
  print(table.concat(kinds, " ")) -- string data integer real integer
  assert(table.concat(kinds, " ") == "string data integer real integer")
  assert(assert(items[5]).unsigned == true and assert(items[5]).integer == -1)
end

--- A date is seconds from 1970, as `os.time` counts them. The binary form keeps a fraction of a second and
--- the XML form drops it.
function Example.date()
  local moon = Plist.date(-14182940 + 0.25)
  local binary = assert(Plist.encode(moon))
  assert(assert(Plist.decode(binary)).date == -14182939.75)
  local xml = assert(Plist.encode(moon, { form = "xml" }))
  assert(xml:find("<date>1969-07-20T20:17:40Z</date>", 1, true) ~= nil)
  assert(assert(Plist.decode(xml)).date == -14182940.0)
end

--- A keyed archive (NSKeyedArchiver) is a property list whose `$objects` refer to one another by UID. Here
--- the archive of one string: the root is the UID 1, which is the place of the string in `$objects`, from 0.
--- A UID has no XML element, so it passes through XML as the dict Apple's tools write for it.
function Example.uid()
  local archive = Plist.dict({
    { key = "$archiver", value = Plist.string("NSKeyedArchiver") },
    { key = "$top", value = Plist.dict({ { key = "root", value = Plist.uid(1) } }) },
    { key = "$objects", value = Plist.array({ Plist.string("$null"), Plist.string("hello") }) },
  })
  local binary = assert(Plist.encode(archive))
  local back = assert(Plist.decode(binary))
  local root = assert(Plist.get(assert(Plist.get(back, "$top")), "root"))
  assert(root.kind == "uid")
  local objects = assert(assert(Plist.get(back, "$objects")).items)
  local object = assert(objects[assert(root.uid) + 1])
  print(object.text) -- hello
  assert(object.text == "hello")
  local xml = assert(Plist.encode(archive, { form = "xml" }))
  assert(xml:find("<key>CF$UID</key>\n\t\t\t<integer>1</integer>", 1, true) ~= nil)
  local from_xml = assert(Plist.get(assert(Plist.get(assert(Plist.decode(xml)), "$top")), "root"))
  assert(from_xml.kind == "uid" and from_xml.uid == 1)
end

--- A file is written back in the form it was read in: [`Plist.form`] says which that is, from the first bytes.
function Example.form()
  local function rewritten(bytes: string): string
    local form = assert(Plist.form(bytes))
    local value = assert(Plist.decode(bytes))
    local out = assert(Plist.encode(value, { form = form }))
    return out
  end
  local binary = assert(Plist.encode(Plist.string("x")))
  local xml = assert(Plist.encode(Plist.string("x"), { form = "xml" }))
  assert(Plist.form(binary) == "binary" and Plist.form(xml) == "xml" and Plist.form("{ a = 1; }") == nil)
  assert(rewritten(binary) == binary and rewritten(xml) == xml)
end

return Example
