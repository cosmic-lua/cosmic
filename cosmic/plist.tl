--- Property lists, in the binary form (`bplist00`) and the XML form: bytes to a [`Plist.Value`] and back.
---
---     local value = assert(Plist.decode(bytes))
---     local name = Plist.get(value, "CFBundleName")
---     local xml = assert(Plist.encode(value, { form = "xml" }))
---
--- [`Plist.decode`] reads either form, told apart by the first bytes, and [`Plist.encode`] writes the form it
--- is asked for, the binary one when it is not told. [`Plist.form`] says which form bytes are in.
---
--- A value is a [`Plist.Value`] and not a plain Lua table, because a table cannot say what a property list
--- says: a dict keeps the order of its keys, text and data are two types, as are an integer and a real, and
--- there are dates and UIDs. `kind` names the type and one field holds what it is. A value is written as a
--- literal, `{ kind = "string", text = "x" }`, or made by the function named for its kind ([`Plist.string`]).
---
--- The types, and what each form holds of them:
---
--- - A boolean, and a string of UTF-8.
--- - An integer from -2^63 to 2^64 - 1. One of 2^63 or more has `unsigned` set and its 64 bits in `integer`.
--- - A real: a double. The binary form's 4-byte reals read as the double they equal.
--- - Data: bytes of any value.
--- - A date: seconds from 2001-01-01T00:00:00Z, with a fraction, which is the double the binary form holds,
---   so that a date read is written back as the same bytes. [`Plist.reference_date`] is that moment in
---   seconds from 1970, to add for the time `os.time` counts, and [`Plist.date`] takes such a time. The XML
---   form holds whole seconds of the years 0001 to 9999: a fraction is dropped when it is written.
--- - An array, and a dict, whose keys are strings and whose entries stay in their order.
--- - A UID, the reference of a keyed archive (NSKeyedArchiver), from 0 to 2^63 - 1. The XML form has no
---   element for one, so it is written there as Apple's tools write it, a dict of the one key `CF$UID` and an
---   integer, and such a dict reads from XML as a UID. A dict of that shape that was not a UID becomes one by
---   passing through XML.
---
--- [`Plist.encode`] lays the bytes out as Python's `plistlib` does, so they can be compared with what it
--- writes for the same value with `sort_keys=False` (`sort_keys` here sorts as it does). In the binary form
--- that is the order of the objects, with equal scalars written once, the width of each integer, length and
--- reference, and a string as ASCII where it is and as UTF-16 otherwise. In the XML form it is the header,
--- the tabs and the lines of base64. Four things differ. Three keep what `plistlib` loses: -0.0 is written
--- apart from 0.0 in the binary form, a carriage return in a string is written as `&#13;` in the XML form,
--- and a UID is written to XML at all. The fourth is a refusal: U+FFFE and U+FFFF, which `plistlib` writes
--- to XML and no XML reader takes.
---
--- [`Plist.decode`] takes bytes from anywhere. It never raises, reads no byte outside what it is given, and
--- its work and memory stay near the size of the input. What it refuses, with nil and why:
---
--- - Binary: a trailer, an offset or a reference that leads outside the bytes or the objects; a length or a
---   count that its bytes could not hold; an array or dict that holds itself; an integer outside the range
---   above (a 16-byte integer inside it is read); a date that is not a number; a UID of 2^63 or more; a null,
---   a set, or any object property lists of this version do not have; a string that is not ASCII or UTF-16
---   as its type says; and a version other than `bplist00`.
--- - XML: text that is not well-formed, as [`cosmic.xml`] reads it (entities within its limits, no external
---   one), a root that is not `plist` with one value, an element that is not a property list's, text between
---   the elements of an array or a dict, an integer, real or date that is not written as one (an integer may
---   be hexadecimal after `0x`), and data that is not base64.
--- - In both: a dict that holds a key twice, since readers disagree about which stands; a key that is not a
---   string; and nesting deeper than `max_depth`.
---
--- In the binary form one object may stand in several places. It is read once, and the [`Plist.Value`] it
--- reads as is the same table at each place. A value is refused when, walked as a tree, it would hold more
--- values than the input has bytes, so that objects shared at every level cannot make a small input a large
--- value. For the same reason the strings and data of a value hold no more bytes than the input has, which
--- objects that overlap, or many offsets that lead to one object, would. A writer that shares arrays and
--- dicts, as `plistlib` does for one list held in many places, can write a file the first limit refuses.
---
--- The limits hold what is read, not what is then written. A string that stands in many places is one
--- object in the binary form and is written at each place in the XML form, so the XML of a value can be far
--- larger than the binary it was read from: `max_bytes` bounds what [`Plist.encode`] writes.

local Codec = require("cosmic.codec")
local Xml = require("cosmic.xml")

local record Plist
  --- The type of a [`Plist.Value`], which names the field that holds it.
  enum Kind
    --- True or false, in `boolean`.
    "boolean"
    --- A whole number, in `integer` and `unsigned`.
    "integer"
    --- A double, in `real`.
    "real"
    --- Text as UTF-8, in `text`.
    "string"
    --- Bytes, in `data`.
    "data"
    --- A moment, in `date`.
    "date"
    --- Values in order, in `items`.
    "array"
    --- Keys and their values in order, in `entries`.
    "dict"
    --- A keyed archive's reference, in `uid`.
    "uid"
  end

  --- The form of a property list's bytes.
  enum Form
    --- `bplist00`: objects, a table of their offsets and a trailer.
    "binary"
    --- An XML document whose root is `plist`.
    "xml"
  end

  --- One value of a property list. The field its `kind` names holds it, and the others are nil.
  record Value
    --- Which type it is.
    kind: Kind
    --- A boolean's value.
    boolean?: boolean
    --- An integer's value. With `unsigned`, the 64 bits of a value of 2^63 or more, which Lua reads as a
    --- negative number: compare it with `math.ult`.
    integer?: integer
    --- Whether `integer` is to be read as unsigned. Absent means it is not.
    unsigned?: boolean
    --- A real's value.
    real?: number
    --- A string's text, as UTF-8.
    text?: string
    --- A data's bytes.
    data?: string
    --- A date, as seconds from 2001-01-01T00:00:00Z: add [`Plist.reference_date`] for seconds from 1970.
    date?: number
    --- An array's values, in order.
    items?: {Value}
    --- A dict's entries, in order.
    entries?: {Entry}
    --- A UID's number, from 0.
    uid?: integer
  end

  --- One entry of a dict.
  record Entry
    --- The entry's key.
    key: string
    --- The entry's value.
    value: Value
  end

  --- What [`Plist.decode`] may be told. Every field is optional.
  record DecodeOptions
    --- How many arrays and dicts may nest, 1 to 1000 (default 64). Outside that range raises.
    max_depth?: integer
  end

  --- What [`Plist.encode`] may be told. Every field is optional.
  record EncodeOptions
    --- The form to write (default "binary").
    form?: Form
    --- Write each dict's entries in the order of their keys' bytes, which is the order of their characters,
    --- and not in the order they are held (default false).
    sort_keys?: boolean
    --- How many arrays and dicts may nest, 1 to 1000 (default 64). Outside that range raises.
    max_depth?: integer
    --- Refuse a value once what is written of it passes this many bytes (default no limit). For writing what
    --- was read from bytes that are not trusted.
    max_bytes?: integer
  end

  --- The seconds from 1970-01-01T00:00:00Z to 2001-01-01T00:00:00Z, from which a property list counts a
  --- date: 978307200.
  reference_date: integer
end

Plist.reference_date = 978307200

local REFERENCE_DATE <const> = 978307200

--- The first and the last second the XML form's four-digit years hold, from 2001.
local FIRST_SECOND <const> = -62135596800 - REFERENCE_DATE
local LAST_SECOND <const> = 253402300799 - REFERENCE_DATE

local DEFAULT_DEPTH <const> = 64
local DEPTH_LIMIT <const> = 1000

--- The bytes before the first object, and the bytes of the trailer.
local HEADER <const> = 8
local TRAILER <const> = 32

--- The real that is not a number, with the bits Python's `float("nan")` has.
local NAN <const>: number = string.unpack(">d", "\x7F\xF8\0\0\0\0\0\0")

--- Adds `piece` to the pieces of what is being written.
local function put(out: mut {string}, piece: string)
  out[#out + 1] = piece
end

--- The `max_depth` an options record asks for, or the default. Raises when it is out of range.
local function depth_of(max_depth: integer?): integer
  if max_depth == nil then return DEFAULT_DEPTH end
  if max_depth < 1 or max_depth > DEPTH_LIMIT then
    error("plist: max_depth is " .. tostring(max_depth) .. ", not 1 to " .. tostring(DEPTH_LIMIT), 3)
  end
  return max_depth
end

--- The days from 1970-01-01 to a date of the proleptic Gregorian calendar.
local function days_from_civil(year: integer, month: integer, day: integer): integer
  local y = if month <= 2 then year - 1 else year end
  local era = y // 400
  local year_of_era = y - era * 400
  local day_of_year = (153 * (if month > 2 then month - 3 else month + 9 end) + 2) // 5 + day - 1
  local day_of_era = year_of_era * 365 + year_of_era // 4 - year_of_era // 100 + day_of_year
  return era * 146097 + day_of_era - 719468
end

--- The year, month and day that many days from 1970-01-01.
local function civil_from_days(days: integer): integer, integer, integer
  local z = days + 719468
  local era = z // 146097
  local day_of_era = z - era * 146097
  local year_of_era = (day_of_era - day_of_era // 1460 + day_of_era // 36524 - day_of_era // 146096) // 365
  local day_of_year = day_of_era - (365 * year_of_era + year_of_era // 4 - year_of_era // 100)
  local shifted = (5 * day_of_year + 2) // 153
  local day = day_of_year - (153 * shifted + 2) // 5 + 1
  local month = if shifted < 10 then shifted + 3 else shifted - 9 end
  local year = year_of_era + era * 400
  return if month <= 2 then year + 1 else year end, month, day
end

local MONTH_DAYS <const>: {integer} = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

--- The seconds from 2001 that an XML date's text names, `YYYY-MM-DDTHH:MM:SSZ`; nil when it is not one.
local function date_of(text: string): number?
  local year_text, month_text, day_text, hour_text, minute_text, second_text =
    text:match("^%s*(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z%s*$")
  local year, month, day = math.tointeger(tonumber(year_text)), math.tointeger(tonumber(month_text)),
    math.tointeger(tonumber(day_text))
  local hour, minute, second = math.tointeger(tonumber(hour_text)), math.tointeger(tonumber(minute_text)),
    math.tointeger(tonumber(second_text))
  if year == nil or month == nil or day == nil or hour == nil or minute == nil or second == nil then
    return nil
  end
  if year < 1 or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59 then
    return nil
  end
  local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
  local longest = if month == 2 and leap then 29 else assert(MONTH_DAYS[month]) end
  if day < 1 or day > longest then return nil end
  return (days_from_civil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second - REFERENCE_DATE) + 0.0
end

--- A date as the XML form writes it, its fraction dropped; nil when its year is not 0001 to 9999.
local function date_text(date: number): string?
  if date ~= date or date < FIRST_SECOND or date >= LAST_SECOND + 1 then return nil end
  local seconds = math.floor(date) + REFERENCE_DATE
  local days = seconds // 86400
  local rest = seconds - days * 86400
  local year, month, day = civil_from_days(days)
  return ("%04d-%02d-%02dT%02d:%02d:%02dZ"):format(year, month, day, rest // 3600, rest % 3600 // 60, rest % 60)
end

--- A real as Python's `repr` writes one: the fewest digits that read back to it, as a decimal from 0.0001 to
--- 10^16 and with an exponent outside that.
local function real_text(real: number): string
  local x = real * 1.0
  if x ~= x then return "nan" end
  if x == math.huge then return "inf" end
  if x == -math.huge then return "-inf" end
  local sign, digits, exponent = "", "0", 0
  for precision = 0, 16 do
    local text = ("%." .. tostring(precision) .. "e"):format(x)
    if tonumber(text) == x then
      local minus, first, rest, power = text:match("^(%-?)(%d)%.?(%d*)e([+-]%d+)$")
      sign = minus or ""
      digits = (first or "0") .. (rest or "")
      exponent = math.tointeger(tonumber(power)) or 0
      break
    end
  end
  if exponent < -4 or exponent >= 16 then
    local fraction = if #digits > 1 then "." .. digits:sub(2) else "" end
    return sign .. digits:sub(1, 1) .. fraction .. ("e%+03d"):format(exponent)
  end
  if exponent < 0 then return sign .. "0." .. ("0"):rep(-exponent - 1) .. digits end
  if #digits <= exponent + 1 then
    return sign .. digits .. ("0"):rep(exponent + 1 - #digits) .. ".0"
  end
  return sign .. digits:sub(1, exponent + 1) .. "." .. digits:sub(exponent + 2)
end

--- The real an XML real's text names: a decimal, with or without an exponent, or `inf`, `infinity` or `nan`
--- in any case. Nil when it is none of them.
local function real_of(text: string): number?
  -- The text less the whitespace around it, each end found in one pass: a lazy match between two runs of
  -- whitespace would try every pair of ends.
  local first = text:find("%S")
  if first == nil then return nil end
  local body = (text:match("^.*%S") or ""):sub(first)
  local sign, word = body:match("^([+-]?)(%a+)$")
  if word ~= nil then
    local lower = word:lower()
    if lower == "nan" then return NAN end
    if lower == "inf" or lower == "infinity" then
      return if sign == "-" then -math.huge else math.huge end
    end
    return nil
  end
  local mantissa, exponent = body:match("^[+-]?([%d.]+)(.*)$")
  if mantissa == nil or exponent == nil then return nil end
  if mantissa:find("^%d+%.?%d*$") == nil and mantissa:find("^%.%d+$") == nil then return nil end
  if exponent ~= "" and exponent:find("^[eE][+-]?%d+$") == nil then return nil end
  -- With an exponent the text reads as a float, so that `-0` keeps its sign.
  local value = tonumber(if exponent == "" then body .. "e0" else body end)
  if value == nil then return nil end
  return value * 1.0
end

--- The integer an XML integer's text names, decimal or hexadecimal after `0x`, with a sign or none; nil when
--- it is not one or is outside -2^63 to 2^64 - 1.
local function integer_of(text: string): Plist.Value?
  local sign, body = text:match("^%s*([+-]?)(%w+)%s*$")
  if sign == nil or body == nil then return nil end
  -- The magnitude, as 64 bits without a sign.
  local magnitude = 0
  local hex = body:match("^0[xX](%x+)$")
  if hex ~= nil then
    local digits = hex:gsub("^0+", "")
    if #digits > 16 then return nil end
    magnitude = math.tointeger(tonumber("0x0" .. digits)) or 0
  else
    if body:find("^%d+$") == nil then return nil end
    local digits = body:gsub("^0+", "")
    if #digits > 20 or #digits == 20 and digits > "18446744073709551615" then return nil end
    for digit in digits:gmatch("%d") do
      magnitude = magnitude * 10 + (math.tointeger(tonumber(digit)) or 0)
    end
  end
  if sign == "-" then
    if magnitude < 0 and magnitude ~= math.mininteger then return nil end
    return { kind = "integer", integer = -magnitude }
  end
  if magnitude < 0 then return { kind = "integer", integer = magnitude, unsigned = true } end
  return { kind = "integer", integer = magnitude }
end

--- An integer's decimal digits, those of its 64 bits without a sign when `unsigned`.
local function integer_text(n: integer, unsigned: boolean): string
  if n >= 0 or not unsigned then return ("%d"):format(n) end
  local tens = (n >> 1) // 5
  return ("%d%d"):format(tens, n - tens * 10)
end

--- Whether `s` is UTF-8 that XML 1.0 can carry: no C0 control but tab, line feed and carriage return, and
--- neither U+FFFE nor U+FFFF.
local function carried(s: string): boolean
  return utf8.len(s) ~= nil and s:find("[\0-\8\11\12\14-\31]") == nil and s:find("\xEF\xBF[\xBE\xBF]") == nil
end

local ESCAPES <const>: {string: string} = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ["\r"] = "&#13;" }

--- `s` as character data. A carriage return is written as a reference, which a reader would otherwise fold
--- into a line feed.
local function escaped(s: string): string
  return (s:gsub("[&<>\r]", ESCAPES))
end

--- The text of a refusal: the place, then why.
local function refuse(index: integer, why: string): string
  return "plist: object " .. tostring(index) .. " " .. why
end

--- A binary object that was read: its value, how many values it holds when walked as a tree, itself
--- included, and how many arrays and dicts nest in it, itself included.
local record Read
  value: Plist.Value
  nodes: integer
  height: integer
end

--- A binary property list being read. Offsets count from 0, as the format's do.
local record Binary
  data: string
  --- The width of an offset and of a reference, in bytes.
  offset_size: integer
  ref_size: integer
  --- How many objects the offset table lists.
  count: integer
  --- Where the offset table begins, which is where the objects end.
  table_at: integer
  max_depth: integer
  --- Each object read so far, by its number. An object referred to from many places is read once, so the
  --- work and the memory of a read stay near the size of the input.
  read: mut {integer: Read}
  --- The arrays and dicts being read, by number: a reference to one is a cycle.
  open: mut {integer: boolean}
  --- Where an object's bytes go on after its marker and length, set by [`length_of`].
  mut pos: integer
  --- The bytes of the strings and data read so far. Objects that overlap, or many offsets that lead to one
  --- object, would make more of them than the input holds.
  mut payload: integer
end

--- The unsigned integer of `size` bytes, 1 to 8, at the 1-based `pos` of `data`, most significant first. One
--- of 8 bytes with its top bit set reads as negative.
local function unsigned_at(data: string, pos: integer, size: integer): integer
  if size == 1 then return (string.unpack("B", data, pos)) end
  if size == 2 then return (string.unpack(">I2", data, pos)) end
  if size == 4 then return (string.unpack(">I4", data, pos)) end
  if size == 8 then return (string.unpack(">i8", data, pos)) end
  local n = 0
  for at = pos, pos + size - 1 do
    local byte: integer = string.unpack("B", data, at)
    n = n << 8 | byte
  end
  return n
end

--- Whether `size` bytes at `pos` lie within the objects.
local function within(b: Binary, pos: integer, size: integer): boolean
  return size <= b.table_at - pos
end

--- Counts `size` more bytes of strings and data as read: "" or why the input cannot hold them.
local function spend(b: Binary, size: integer): string
  if size > #b.data - b.payload then
    return "plist: the strings and data hold more bytes than the input has"
  end
  b.payload = b.payload + size
  return ""
end

--- The length of the object whose marker is at `at`: the marker's low half, or the integer that follows when
--- that half is 15. Sets `b.pos` to the byte after it. Nil and why when it is not there.
local function length_of(b: Binary, index: integer, at: integer, low: integer): integer?, string
  if low < 15 then
    b.pos = at + 1
    return low, ""
  end
  if not within(b, at + 1, 1) then return nil, refuse(index, "ends before its length") end
  local marker: integer = string.unpack("B", b.data, at + 2)
  if marker >> 4 ~= 1 or marker & 15 > 3 then
    return nil, refuse(index, "has a length that is not an integer")
  end
  local size = 1 << (marker & 15)
  if not within(b, at + 2, size) then return nil, refuse(index, "ends before its length") end
  local length = unsigned_at(b.data, at + 3, size)
  if length < 0 then return nil, refuse(index, "is longer than its bytes could hold") end
  b.pos = at + 2 + size
  return length, ""
end

--- The UTF-8 of `units` 16-bit units of big-endian UTF-16 from the 1-based `first`; nil at a surrogate with
--- no partner.
local function from_utf16(data: string, first: integer, units: integer): string?
  local out: mut {string} = {}
  local i = 0
  while i < units do
    local unit: integer = string.unpack(">I2", data, first + 2 * i)
    i = i + 1
    if unit >= 0xD800 and unit <= 0xDBFF then
      if i >= units then return nil end
      local low: integer = string.unpack(">I2", data, first + 2 * i)
      if low < 0xDC00 or low > 0xDFFF then return nil end
      i = i + 1
      unit = 0x10000 + (unit - 0xD800 << 10) + (low - 0xDC00)
    elseif unit >= 0xDC00 and unit <= 0xDFFF then
      return nil
    end
    put(out, utf8.char(unit))
  end
  return table.concat(out)
end

--- `text`, which is UTF-8, as big-endian UTF-16, and how many 16-bit units that is.
local function to_utf16(text: string): string, integer
  local out: mut {string} = {}
  local units = 0
  for _, code in utf8.codes(text) do
    if code < 0x10000 then
      put(out, string.pack(">I2", code))
      units = units + 1
    else
      local rest = code - 0x10000
      put(out, string.pack(">I2I2", 0xD800 | rest >> 10, 0xDC00 | rest & 0x3FF))
      units = units + 2
    end
  end
  return table.concat(out), units
end

--- The object of a type that holds no other, whose marker is at `at`; nil and why.
local function read_scalar(b: Binary, index: integer, at: integer, high: integer, low: integer): Plist.Value?, string
  local data = b.data
  if high == 0x0 then
    if low == 0x8 then return { kind = "boolean", boolean = false }, "" end
    if low == 0x9 then return { kind = "boolean", boolean = true }, "" end
    if low == 0x0 then return nil, refuse(index, "is a null, which no property list holds") end
  elseif high == 0x1 then
    if low > 4 then return nil, refuse(index, "is an integer wider than 16 bytes") end
    local size = 1 << low
    if not within(b, at + 1, size) then return nil, refuse(index, "ends before its integer") end
    if size < 8 then
      local small = unsigned_at(data, at + 2, size)
      return { kind = "integer", integer = small }, ""
    end
    if size == 8 then
      local signed: integer = string.unpack(">i8", data, at + 2)
      return { kind = "integer", integer = signed }, ""
    end
    local upper, lower = string.unpack(">i8i8", data, at + 2)
    if upper == 0 then
      if lower < 0 then return { kind = "integer", integer = lower, unsigned = true }, "" end
      return { kind = "integer", integer = lower }, ""
    end
    if upper == -1 and lower < 0 then return { kind = "integer", integer = lower }, "" end
    return nil, refuse(index, "is an integer outside -2^63 to 2^64 - 1")
  elseif high == 0x2 then
    if low == 2 and within(b, at + 1, 4) then
      local single: number = string.unpack(">f", data, at + 2)
      return { kind = "real", real = single }, ""
    end
    if low == 3 and within(b, at + 1, 8) then
      local double: number = string.unpack(">d", data, at + 2)
      return { kind = "real", real = double }, ""
    end
    return nil, refuse(index, "is a real that is not 4 or 8 bytes within the objects")
  elseif high == 0x3 then
    if low ~= 3 or not within(b, at + 1, 8) then
      return nil, refuse(index, "is a date that is not 8 bytes within the objects")
    end
    local since: number = string.unpack(">d", data, at + 2)
    if since ~= since or since == math.huge or since == -math.huge then
      return nil, refuse(index, "is a date that is not a number")
    end
    return { kind = "date", date = since }, ""
  elseif high == 0x4 or high == 0x5 then
    local length, why = length_of(b, index, at, low)
    if length == nil then return nil, why end
    local pos = b.pos
    if not within(b, pos, length) then
      return nil, refuse(index, "is longer than its bytes could hold")
    end
    local spent = spend(b, length)
    if spent ~= "" then return nil, spent end
    local bytes = data:sub(pos + 1, pos + length)
    if high == 0x4 then return { kind = "data", data = bytes }, "" end
    if bytes:find("[\128-\255]") ~= nil then
      return nil, refuse(index, "is an ASCII string with a byte past 127")
    end
    return { kind = "string", text = bytes }, ""
  elseif high == 0x6 then
    local units, why = length_of(b, index, at, low)
    if units == nil then return nil, why end
    local pos = b.pos
    if units > (b.table_at - pos) // 2 then
      return nil, refuse(index, "is longer than its bytes could hold")
    end
    local spent = spend(b, units * 2)
    if spent ~= "" then return nil, spent end
    local text = from_utf16(data, pos + 1, units)
    if text == nil then return nil, refuse(index, "is a string that is not UTF-16") end
    return { kind = "string", text = text }, ""
  elseif high == 0x8 then
    local size = low + 1
    if size > 8 or not within(b, at + 1, size) then
      return nil, refuse(index, "is a UID that is not 1 to 8 bytes within the objects")
    end
    local uid = unsigned_at(data, at + 2, size)
    if uid < 0 then return nil, refuse(index, "is a UID of 2^63 or more") end
    return { kind = "uid", uid = uid }, ""
  end
  return nil, refuse(index, ("has a marker no property list has (0x%02X)"):format(high << 4 | low))
end

--- The functions that read a binary object, which call each other.
local record Objects end

--- The object `ref` names from inside object `index`, read at `depth`, added to `nodes`: the object, and
--- the count with it. Nil and why when the reference leads nowhere, the object does not read, or the value
--- holds more than the input's bytes could.
local function follow(b: Binary, index: integer, ref: integer, depth: integer, nodes: integer): Read?, string
  if ref < 0 or ref >= b.count then
    return nil, refuse(index, "refers to an object the list does not have")
  end
  local child, why = Objects.read(b, ref, depth)
  if child == nil then return nil, why end
  if child.nodes > #b.data - nodes then
    return nil, "plist: the value holds more values than the input has bytes"
  end
  -- An object read before, at a place less deep, is as deep here as what it holds.
  if depth + child.height > b.max_depth then
    return nil, refuse(ref, "is nested deeper than " .. tostring(b.max_depth))
  end
  return child, ""
end

--- The array or dict whose marker is at `at`, `depth` arrays and dicts inside the top one; nil and why.
local function read_container(b: Binary, index: integer, at: integer, high: integer, low: integer, depth: integer):
    Read?, string
  local length, why = length_of(b, index, at, low)
  if length == nil then return nil, why end
  local pos = b.pos
  local ref_size = b.ref_size
  local refs = if high == 0xA then length else length * 2 end
  if length > (b.table_at - pos) // ref_size or refs > (b.table_at - pos) // ref_size then
    return nil, refuse(index, "holds more than its bytes could")
  end
  if depth >= b.max_depth then
    return nil, refuse(index, "is nested deeper than " .. tostring(b.max_depth))
  end
  local data = b.data
  local nodes, height = 1, 1
  b.open[index] = true
  if high == 0xA then
    local items: mut {Plist.Value} = {}
    for i = 0, length - 1 do
      local ref = unsigned_at(data, pos + i * ref_size + 1, ref_size)
      local child, child_why = follow(b, index, ref, depth + 1, nodes)
      if child == nil then return nil, child_why end
      nodes = nodes + child.nodes
      height = math.max(height, 1 + child.height)
      items[#items + 1] = child.value
    end
    b.open[index] = nil
    return { value = { kind = "array", items = items }, nodes = nodes, height = height }, ""
  end
  local entries: mut {Plist.Entry} = {}
  local seen: mut {string: boolean} = {}
  for i = 0, length - 1 do
    local key_ref = unsigned_at(data, pos + i * ref_size + 1, ref_size)
    local key, key_why = follow(b, index, key_ref, depth + 1, nodes)
    if key == nil then return nil, key_why end
    local text = key.value.text
    if key.value.kind ~= "string" or text == nil then
      return nil, refuse(index, "has a key that is not a string")
    end
    if seen[text] == true then return nil, refuse(index, "holds a key twice") end
    seen[text] = true
    nodes = nodes + key.nodes
    local value_ref = unsigned_at(data, pos + (length + i) * ref_size + 1, ref_size)
    local child, child_why = follow(b, index, value_ref, depth + 1, nodes)
    if child == nil then return nil, child_why end
    nodes = nodes + child.nodes
    height = math.max(height, 1 + child.height)
    entries[#entries + 1] = { key = text, value = child.value }
  end
  b.open[index] = nil
  return { value = { kind = "dict", entries = entries }, nodes = nodes, height = height }, ""
end

--- Object `index`, read once however many places refer to it; nil and why.
function Objects.read(b: Binary, index: integer, depth: integer): Read?, string
  local known = b.read[index]
  if known ~= nil then return known, "" end
  if b.open[index] == true then return nil, refuse(index, "holds itself") end
  local at = unsigned_at(b.data, b.table_at + index * b.offset_size + 1, b.offset_size)
  if at < HEADER or at >= b.table_at then
    return nil, refuse(index, "has an offset outside the objects")
  end
  local marker: integer = string.unpack("B", b.data, at + 1)
  local high, low = marker >> 4, marker & 15
  local made: Read
  if high == 0xA or high == 0xD then
    local container, why = read_container(b, index, at, high, low, depth)
    if container == nil then return nil, why end
    made = container
  else
    local value, why = read_scalar(b, index, at, high, low)
    if value == nil then return nil, why end
    made = { value = value, nodes = 1, height = 0 }
  end
  b.read[index] = made
  return made, ""
end

--- The value of a binary property list, the trailer checked before anything it names is followed.
local function decode_binary(data: string, max_depth: integer): Plist.Value?, string
  if data:sub(7, 8) ~= "00" then
    return nil, "plist: a binary property list of a version other than 00"
  end
  if #data < HEADER + 2 + TRAILER then
    return nil, "plist: too short to hold an object and a trailer"
  end
  local trailer_at = #data - TRAILER
  local offset_size, ref_size, count, top, table_at =
    string.unpack(">BBi8i8i8", data, trailer_at + 7)
  if offset_size < 1 or offset_size > 8 or ref_size < 1 or ref_size > 8 then
    return nil, "plist: the trailer's offsets or references are not 1 to 8 bytes wide"
  end
  if table_at <= HEADER or table_at > trailer_at - offset_size then
    return nil, "plist: the trailer puts the offset table outside the bytes"
  end
  if count < 1 or count > (trailer_at - table_at) // offset_size then
    return nil, "plist: the trailer counts more objects than the offset table could hold"
  end
  if top < 0 or top >= count then
    return nil, "plist: the trailer's top object is not in the list"
  end
  local b: Binary = {
    data = data, offset_size = offset_size, ref_size = ref_size, count = count, table_at = table_at,
    max_depth = max_depth, read = {}, open = {}, pos = 0, payload = 0,
  }
  local made, why = Objects.read(b, top, 0)
  if made == nil then return nil, why end
  return made.value, ""
end

--- An XML property list being read: the limit, and the keys and indexes that lead to the element being
--- read, for a refusal to name.
local record Reading
  max_depth: integer
  path: mut {string}
end

--- The longest place a refusal spells out, in bytes.
local PLACE_BYTES <const> = 96

--- Why an element is refused, naming where it is by the keys and the indexes, from 1, that lead to it.
local function misplaced(r: Reading, why: string): string
  if #r.path == 0 then return "plist: " .. why end
  local place = table.concat(r.path, "/")
  if #place > PLACE_BYTES then
    -- The innermost end of it, begun at a whole character.
    place = "..." .. place:sub(-PLACE_BYTES):gsub("^[\128-\191]+", "")
  end
  return "plist: " .. why .. " (at " .. place .. ")"
end

--- The text an element holds, or nil when it holds an element.
local function text_of(element: Xml.Element): string?
  local parts: mut {string} = {}
  for _, item in ipairs(element.content) do
    if item is string then
      parts[#parts + 1] = item
    else
      return nil
    end
  end
  return table.concat(parts)
end

--- The elements an element holds, or nil when there is text other than whitespace between them.
local function elements_of(element: Xml.Element): {Xml.Element}?
  local out: mut {Xml.Element} = {}
  for _, item in ipairs(element.content) do
    if item is string then
      if item:find("%S") ~= nil then return nil end
    else
      out[#out + 1] = item
    end
  end
  return out
end

--- The elements that hold text and no element.
local SCALARS <const>: {string: boolean} = { string = true, ["true"] = true, ["false"] = true, integer = true,
  real = true, date = true, data = true }

--- The functions that read an XML element, which call each other.
local record Elements end

--- The dict an XML `dict` holds: keys and values in turn. One whose only entry is `CF$UID` with an integer
--- from 0 to 2^63 - 1 is the UID Apple's tools write that way.
local function read_dict(r: Reading, children: {Xml.Element}, depth: integer): Plist.Value?, string
  if #children % 2 ~= 0 then
    return nil, misplaced(r, "a dict does not hold a value for each key")
  end
  local entries: mut {Plist.Entry} = {}
  local seen: mut {string: boolean} = {}
  for i = 1, #children, 2 do
    local key_element, value_element = children[i], children[i + 1]
    if key_element == nil or value_element == nil then
      return nil, misplaced(r, "a dict does not hold a value for each key")
    end
    local key = if key_element.name == "key" then text_of(key_element) else nil end
    if key == nil then
      return nil, misplaced(r, "a dict has <" .. key_element.name .. "> where a key goes")
    end
    if seen[key] == true then return nil, misplaced(r, "a dict holds a key twice") end
    seen[key] = true
    r.path[#r.path + 1] = key
    local value, why = Elements.read(r, value_element, depth + 1)
    if value == nil then return nil, why end
    r.path[#r.path] = nil
    entries[#entries + 1] = { key = key, value = value }
  end
  local only = entries[1]
  if #entries == 1 and only ~= nil and only.key == "CF$UID" then
    local number = only.value.integer
    if only.value.kind == "integer" and number ~= nil and number >= 0 then
      return { kind = "uid", uid = number }, ""
    end
  end
  if depth >= r.max_depth then
    return nil, misplaced(r, "nested deeper than " .. tostring(r.max_depth))
  end
  return { kind = "dict", entries = entries }, ""
end

--- The value `element` is, `depth` arrays and dicts inside the top one; nil and why.
function Elements.read(r: Reading, element: Xml.Element, depth: integer): Plist.Value?, string
  local name = element.name
  if name == "array" or name == "dict" then
    local children = elements_of(element)
    if children == nil then
      return nil, misplaced(r, "text between the elements of <" .. name .. ">")
    end
    -- The dict that spells a UID is no level of nesting: a UID is none in the binary form.
    local first = children[1]
    local second = children[2]
    local spells_uid = name == "dict" and #children == 2 and first ~= nil and first.name == "key" and
      second ~= nil and second.name == "integer" and text_of(first) == "CF$UID"
    if depth >= r.max_depth and not spells_uid then
      return nil, misplaced(r, "nested deeper than " .. tostring(r.max_depth))
    end
    if name == "dict" then return read_dict(r, children, depth) end
    local items: mut {Plist.Value} = {}
    for i, child in ipairs(children) do
      local step = tostring(i)
      r.path[#r.path + 1] = step
      local value, why = Elements.read(r, child, depth + 1)
      if value == nil then return nil, why end
      r.path[#r.path] = nil
      items[#items + 1] = value
    end
    return { kind = "array", items = items }, ""
  end
  if SCALARS[name] ~= true then
    return nil, misplaced(r, "<" .. name .. "> is no element of a property list")
  end
  local text = text_of(element)
  if text == nil then return nil, misplaced(r, "<" .. name .. "> holds an element") end
  if name == "string" then
    return { kind = "string", text = text }, ""
  elseif name == "true" or name == "false" then
    if text:find("%S") ~= nil then return nil, misplaced(r, "<" .. name .. "> holds text") end
    return { kind = "boolean", boolean = name == "true" }, ""
  elseif name == "integer" then
    local value = integer_of(text)
    if value == nil then return nil, misplaced(r, "not an integer from -2^63 to 2^64 - 1") end
    return value, ""
  elseif name == "real" then
    local real = real_of(text)
    if real == nil then return nil, misplaced(r, "not a real") end
    return { kind = "real", real = real }, ""
  elseif name == "date" then
    local date = date_of(text)
    if date == nil then return nil, misplaced(r, "not a date written YYYY-MM-DDTHH:MM:SSZ") end
    return { kind = "date", date = date }, ""
  end
  local bytes, trouble = Codec.unbase64((text:gsub("%s+", "")))
  if bytes == nil then return nil, misplaced(r, "data that is not base64: " .. trouble) end
  return { kind = "data", data = bytes }, ""
end

--- The value of an XML property list.
local function decode_xml(text: string, max_depth: integer): Plist.Value?, string
  local root, trouble = Xml.tree(text)
  if root == nil then return nil, "plist: " .. trouble end
  local r: Reading = { max_depth = max_depth, path = {} }
  if root.name ~= "plist" then
    return nil, "plist: the root element is <" .. root.name .. ">, not <plist>"
  end
  local children = elements_of(root)
  if children == nil then return nil, "plist: text between the elements of <plist>" end
  local only = children[1]
  if #children ~= 1 or only == nil then return nil, "plist: <plist> does not hold one value" end
  return Elements.read(r, only, 0)
end

--- What [`Plist.encode`] writes with, either form.
local record Writing
  sort_keys: boolean
  max_depth: integer
  --- The arrays and dicts being written, which none may hold again.
  open: mut {Plist.Value: boolean}
  --- The bytes at which a value is refused, and those written so far.
  max_bytes: integer
  mut size: integer
end

--- Why what `w` has written is too much, or "".
local function too_much(w: Writing): string
  if w.size <= w.max_bytes then return "" end
  return "plist: the value takes more bytes than max_bytes allows (" .. tostring(w.max_bytes) .. ")"
end

--- A dict's entries in the order they are written, each key checked with `fits`; nil and why when a key
--- does not fit or comes twice.
local function ordered(w: Writing, entries: {Plist.Entry}, fits: function(string): boolean): {Plist.Entry}?, string
  local seen: mut {string: boolean} = {}
  local out: mut {Plist.Entry} = {}
  for _, entry in ipairs(entries) do
    if not fits(entry.key) then return nil, "plist: a key is not text this form can hold" end
    if seen[entry.key] == true then return nil, "plist: a dict holds a key twice" end
    seen[entry.key] = true
    out[#out + 1] = entry
  end
  if w.sort_keys then
    table.sort(out, function(a: Plist.Entry, b: Plist.Entry): boolean return a.key < b.key end)
  end
  return out, ""
end

--- Why a value's own field cannot be written, in either form, or "" when it can.
local function unfit(value: Plist.Value): string
  local kind = value.kind
  if kind == "boolean" then
    if value.boolean == nil then return "plist: a boolean with no `boolean`" end
  elseif kind == "integer" then
    if value.integer == nil then return "plist: an integer with no `integer`" end
  elseif kind == "real" then
    if value.real == nil then return "plist: a real with no `real`" end
  elseif kind == "string" then
    local text = value.text
    if text == nil then return "plist: a string with no `text`" end
    if utf8.len(text) == nil then return "plist: a string is not UTF-8" end
  elseif kind == "data" then
    if value.data == nil then return "plist: a data with no `data`" end
  elseif kind == "date" then
    local date = value.date
    if date == nil then return "plist: a date with no `date`" end
    if date ~= date or date == math.huge or date == -math.huge then
      return "plist: a date is not a number"
    end
  elseif kind == "array" then
    if value.items == nil then return "plist: an array with no `items`" end
  elseif kind == "dict" then
    if value.entries == nil then return "plist: a dict with no `entries`" end
  elseif kind == "uid" then
    local uid = value.uid
    if uid == nil then return "plist: a UID with no `uid`" end
    if uid < 0 then return "plist: a UID is negative" end
  else
    return "plist: a value of no kind"
  end
  return ""
end

--- Opens the array or dict `value`, `depth` arrays and dicts inside the top one: "" or why it cannot be.
local function enter(w: Writing, value: Plist.Value, depth: integer): string
  if w.open[value] == true then return "plist: an array or a dict holds itself" end
  if depth >= w.max_depth then return "plist: nested deeper than " .. tostring(w.max_depth) end
  w.open[value] = true
  return ""
end

local INDENT <const> = "\t"

--- Writes `value` to `out` as the XML form's lines, indented `level` tabs: "" or why it cannot be written.
--- Adds `piece` to what `w` writes, counted.
local function write(w: Writing, out: mut {string}, piece: string)
  w.size = w.size + #piece
  out[#out + 1] = piece
end

local function write_xml(w: Writing, out: mut {string}, value: Plist.Value, level: integer, depth: integer): string
  local why = unfit(value)
  if why == "" then why = too_much(w) end
  if why ~= "" then return why end
  local indent = INDENT:rep(level)
  local kind = value.kind
  if kind == "boolean" then
    write(w, out, indent .. (if value.boolean == true then "<true/>\n" else "<false/>\n" end))
  elseif kind == "integer" then
    write(w, out, indent .. "<integer>" .. integer_text(value.integer or 0, value.unsigned == true) .. "</integer>\n")
  elseif kind == "real" then
    write(w, out, indent .. "<real>" .. real_text(value.real or 0.0) .. "</real>\n")
  elseif kind == "string" then
    local text = value.text or ""
    if not carried(text) then return "plist: a string holds a character XML cannot" end
    write(w, out, indent .. "<string>" .. escaped(text) .. "</string>\n")
  elseif kind == "data" then
    local data = value.data or ""
    -- The lines `plistlib` writes: 76 columns less the indent at 8 columns a tab, and 16 at least.
    local per_line = math.max(16, 76 - 8 * level) // 4 * 3
    write(w, out, indent .. "<data>\n")
    for at = 1, #data, per_line do
      write(w, out, indent .. Codec.base64(data:sub(at, at + per_line - 1)) .. "\n")
    end
    write(w, out, indent .. "</data>\n")
  elseif kind == "date" then
    local text = date_text(value.date or 0.0)
    if text == nil then
      return "plist: a date outside the years 0001 to 9999, which XML cannot hold"
    end
    write(w, out, indent .. "<date>" .. text .. "</date>\n")
  elseif kind == "uid" then
    write(w, out, indent .. "<dict>\n" .. indent .. INDENT .. "<key>CF$UID</key>\n" .. indent .. INDENT ..
        "<integer>" .. integer_text(value.uid or 0, false) .. "</integer>\n" .. indent .. "</dict>\n")
  elseif kind == "array" then
    local items = value.items or {}
    local entered = enter(w, value, depth)
    if entered ~= "" then return entered end
    write(w, out, indent .. (if #items == 0 then "<array/>\n" else "<array>\n" end))
    for _, item in ipairs(items) do
      local item_why = write_xml(w, out, item, level + 1, depth + 1)
      if item_why ~= "" then return item_why end
    end
    if #items > 0 then write(w, out, indent .. "</array>\n") end
    w.open[value] = nil
  else
    local entered = enter(w, value, depth)
    if entered ~= "" then return entered end
    local entries, entries_why = ordered(w, value.entries or {}, carried)
    if entries == nil then return entries_why end
    write(w, out, indent .. (if #entries == 0 then "<dict/>\n" else "<dict>\n" end))
    for _, entry in ipairs(entries) do
      write(w, out, indent .. INDENT .. "<key>" .. escaped(entry.key) .. "</key>\n")
      local entry_why = write_xml(w, out, entry.value, level + 1, depth + 1)
      if entry_why ~= "" then return entry_why end
    end
    if #entries > 0 then write(w, out, indent .. "</dict>\n") end
    w.open[value] = nil
  end
  return ""
end

local XML_HEADER <const> = '<?xml version="1.0" encoding="UTF-8"?>\n' ..
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n' ..
  '<plist version="1.0">\n'

local XML_FOOTER <const> = "</plist>\n"

local function encode_xml(w: Writing, value: Plist.Value): string?, string
  local out: mut {string} = { XML_HEADER }
  w.size = #XML_HEADER + #XML_FOOTER
  local why = write_xml(w, out, value, 0, 0)
  if why == "" then why = too_much(w) end
  if why ~= "" then return nil, why end
  out[#out + 1] = XML_FOOTER
  return table.concat(out), ""
end

--- One object of the binary form: a value, and for an array or a dict the numbers of the objects it holds,
--- a dict's keys before its values.
local record Node
  value: Plist.Value
  mut refs?: {integer}
end

--- The objects of a value, in the order `plistlib` numbers them: each before what it holds, an array's
--- items in order, a dict's keys and then its values. Equal scalars are one object; an array, a dict, a UID
--- and a real that is not a number are one object for each table.
local record Flat
  writing: Writing
  nodes: mut {Node}
  --- The number of the object written for each string, data and integer, by its value.
  strings: mut {string: integer}
  datas: mut {string: integer}
  integers: mut {integer: integer}
  unsigneds: mut {integer: integer}
  --- For a boolean, a real and a date, by a letter for the kind and the bytes of the value.
  others: mut {string: integer}
  --- For what is one object for each table.
  tables: mut {Plist.Value: integer}
end

--- The number, from 0, of the object that stands for `value`, adding it and what it holds when it is new;
--- nil and why when it cannot be written.
local function flatten(flat: Flat, value: Plist.Value, depth: integer): integer?, string
  local why = unfit(value)
  if why ~= "" then return nil, why end
  local kind = value.kind
  local nodes = flat.nodes
  local function add(): integer
    nodes[#nodes + 1] = { value = value }
    return #nodes - 1
  end
  if kind == "string" or kind == "data" then
    local by_value = if kind == "string" then flat.strings else flat.datas end
    local bytes = (if kind == "string" then value.text else value.data end) or ""
    local known = by_value[bytes]
    if known ~= nil then return known, "" end
    local ref = add()
    by_value[bytes] = ref
    return ref, ""
  elseif kind == "integer" then
    local n = value.integer or 0
    local by_value = if n < 0 and value.unsigned == true then flat.unsigneds else flat.integers end
    local known = by_value[n]
    if known ~= nil then return known, "" end
    local ref = add()
    by_value[n] = ref
    return ref, ""
  end
  local real = value.real
  local key: string? = nil
  if kind == "boolean" then
    key = if value.boolean == true then "t" else "f" end
  elseif kind == "real" and real ~= nil and real == real then
    key = "r" .. string.pack(">d", real)
  elseif kind == "date" then
    key = "d" .. string.pack(">d", value.date or 0.0)
  end
  if key ~= nil then
    local known = flat.others[key]
    if known ~= nil then return known, "" end
    local ref = add()
    flat.others[key] = ref
    return ref, ""
  end
  local known = flat.tables[value]
  if known ~= nil then
    if flat.writing.open[value] == true then
      return nil, "plist: an array or a dict holds itself"
    end
    return known, ""
  end
  local ref = add()
  flat.tables[value] = ref
  if kind ~= "array" and kind ~= "dict" then return ref, "" end
  local entered = enter(flat.writing, value, depth)
  if entered ~= "" then return nil, entered end
  local node = assert(nodes[ref + 1])
  local refs: mut {integer} = {}
  if kind == "array" then
    for _, item in ipairs(value.items or {}) do
      local item_ref, item_why = flatten(flat, item, depth + 1)
      if item_ref == nil then return nil, item_why end
      refs[#refs + 1] = item_ref
    end
  else
    local entries, entries_why = ordered(flat.writing, value.entries or {}, function(key_text: string): boolean
      return utf8.len(key_text) ~= nil
    end)
    if entries == nil then return nil, entries_why end
    for _, entry in ipairs(entries) do
      local key_value: Plist.Value = { kind = "string", text = entry.key }
      local key_ref, key_why = flatten(flat, key_value, depth + 1)
      if key_ref == nil then return nil, key_why end
      refs[#refs + 1] = key_ref
    end
    for _, entry in ipairs(entries) do
      local value_ref, value_why = flatten(flat, entry.value, depth + 1)
      if value_ref == nil then return nil, value_why end
      refs[#refs + 1] = value_ref
    end
  end
  node.refs = refs
  flat.writing.open[value] = nil
  return ref, ""
end

--- The fewest bytes, of 1, 2, 4 and 8, that hold a count.
local function width_of(count: integer): integer
  if count < 1 << 8 then return 1 end
  if count < 1 << 16 then return 2 end
  if count < 1 << 32 then return 4 end
  return 8
end

--- A marker with a length: in the marker's low half under 15, and in an integer after it otherwise.
local function sized(token: integer, length: integer): string
  if length < 15 then return string.char(token | length) end
  local width = width_of(length)
  local power = if width == 1 then 0 elseif width == 2 then 1 elseif width == 4 then 2 else 3 end
  return string.pack(">BBI" .. tostring(width), token | 15, 0x10 | power, length)
end

--- The bytes of one object, its references `ref_size` wide.
local function object_bytes(node: Node, ref_size: integer): string
  local value = node.value
  local kind = value.kind
  if kind == "boolean" then
    return if value.boolean == true then "\x09" else "\x08" end
  elseif kind == "integer" then
    local n = value.integer or 0
    if n < 0 then
      -- Sixteen bytes for what is past a signed 64 bits, as `plistlib` writes it.
      if value.unsigned == true then return string.pack(">Bi8i8", 0x14, 0, n) end
      return string.pack(">Bi8", 0x13, n)
    end
    local width = width_of(n)
    if width == 1 then return string.pack(">BB", 0x10, n) end
    if width == 2 then return string.pack(">BI2", 0x11, n) end
    if width == 4 then return string.pack(">BI4", 0x12, n) end
    return string.pack(">Bi8", 0x13, n)
  elseif kind == "real" then
    return string.pack(">Bd", 0x23, value.real or 0.0)
  elseif kind == "date" then
    return string.pack(">Bd", 0x33, value.date or 0.0)
  elseif kind == "data" then
    local data = value.data or ""
    return sized(0x40, #data) .. data
  elseif kind == "string" then
    local text = value.text or ""
    if text:find("[\128-\255]") == nil then return sized(0x50, #text) .. text end
    local wide, units = to_utf16(text)
    return sized(0x60, units) .. wide
  elseif kind == "uid" then
    local uid = value.uid or 0
    local width = width_of(uid)
    return string.pack(">BI" .. tostring(width), 0x80 | width - 1, uid)
  end
  local refs = node.refs or {}
  local parts: mut {string} = { if kind == "array" then sized(0xA0, #refs) else sized(0xD0, #refs // 2) end }
  local format = ">I" .. tostring(ref_size)
  for _, ref in ipairs(refs) do put(parts, string.pack(format, ref)) end
  return table.concat(parts)
end

local function encode_binary(w: Writing, value: Plist.Value): string?, string
  local flat: Flat = { writing = w, nodes = {}, strings = {}, datas = {}, integers = {}, unsigneds = {}, others = {},
    tables = {} }
  local top, why = flatten(flat, value, 0)
  if top == nil then return nil, why end
  local count = #flat.nodes
  local ref_size = width_of(count)
  local out: mut {string} = { "bplist00" }
  local offsets: mut {integer} = {}
  local at = HEADER
  for _, node in ipairs(flat.nodes) do
    local bytes = object_bytes(node, ref_size)
    offsets[#offsets + 1] = at
    out[#out + 1] = bytes
    at = at + #bytes
    w.size = at
    local why_much = too_much(w)
    if why_much ~= "" then return nil, why_much end
  end
  w.size = at + count * width_of(at) + TRAILER
  local whole_why = too_much(w)
  if whole_why ~= "" then return nil, whole_why end
  local offset_format = ">I" .. tostring(width_of(at))
  for _, offset in ipairs(offsets) do put(out, string.pack(offset_format, offset)) end
  put(out, string.pack(">I5BBBI8I8I8", 0, 0, width_of(at), ref_size, count, top, at))
  return table.concat(out), ""
end

--- Which form `bytes` are in, by how they begin: "binary" after `bplist`, "xml" where the first character is
--- `<`, after a byte order mark or whitespace or neither, and nil for anything else. It reads no further, so
--- bytes it names may still not decode.
function Plist.form(bytes: string): Plist.Form?
  if bytes:sub(1, 6) == "bplist" then return "binary" end
  if bytes:find("^[%s\0\xEF\xBB\xBF\xFE\xFF]*<") ~= nil then return "xml" end
  return nil
end

--- The value `bytes` hold, in whichever form they are; nil and why when they are in neither or are refused,
--- as the module's doc lists.
function Plist.decode(bytes: string, opts?: Plist.DecodeOptions): Plist.Value?, string
  local max_depth = depth_of(if opts == nil then nil else opts.max_depth end)
  local form = Plist.form(bytes)
  if form == "binary" then return decode_binary(bytes, max_depth) end
  if form == "xml" then return decode_xml(bytes, max_depth) end
  return nil, "plist: neither a binary property list nor XML"
end

--- `value` as the bytes of a property list, in the binary form or the one `opts.form` names, laid out as the
--- module's doc says. Nil and why for what no property list holds: a value whose `kind` names a field it
--- lacks, a string or a key that is not UTF-8, a date that is not a number, a negative UID, a dict that holds
--- a key twice, an array or a dict that holds itself, nesting deeper than `max_depth`, and a value that takes
--- more than `max_bytes`. The XML form also refuses what it cannot carry: a string or a key with a control
--- character other than tab, line feed and carriage return, or with U+FFFE or U+FFFF, and a date outside
--- the years 0001 to 9999.
---
--- The binary form writes a table that stands in several places once, as one object. The XML form writes it
--- at each place.
function Plist.encode(value: Plist.Value, opts?: Plist.EncodeOptions): string?, string
  local w: Writing = {
    sort_keys = opts ~= nil and opts.sort_keys == true,
    max_depth = depth_of(if opts == nil then nil else opts.max_depth end),
    open = {},
    max_bytes = (if opts == nil then nil else opts.max_bytes end) or math.maxinteger,
    size = 0,
  }
  if opts ~= nil and opts.form == "xml" then return encode_xml(w, value) end
  return encode_binary(w, value)
end

--- A boolean.
function Plist.boolean(value: boolean): Plist.Value
  return { kind = "boolean", boolean = value }
end

--- An integer. With `unsigned`, `value` is the 64 bits of an integer of 2^63 or more, so
--- `Plist.integer(-1, true)` is 2^64 - 1.
function Plist.integer(value: integer, unsigned?: boolean): Plist.Value
  if unsigned == true and value < 0 then
    return { kind = "integer", integer = value, unsigned = true }
  end
  return { kind = "integer", integer = value }
end

--- A real.
function Plist.real(value: number): Plist.Value
  return { kind = "real", real = value * 1.0 }
end

--- A string of `text`, which is UTF-8.
function Plist.string(text: string): Plist.Value
  return { kind = "string", text = text }
end

--- Data of `bytes`.
function Plist.data(bytes: string): Plist.Value
  return { kind = "data", data = bytes }
end

--- A date, `seconds` from 1970-01-01T00:00:00Z, as `os.time` counts them. The value holds them from 2001:
--- whole seconds are exact, and a fraction is as near as a double from 2001 holds it.
function Plist.date(seconds: number): Plist.Value
  return { kind = "date", date = seconds - REFERENCE_DATE + 0.0 }
end

--- An array of `items`.
function Plist.array(items: {Plist.Value}): Plist.Value
  return { kind = "array", items = items }
end

--- A dict of `entries`, in their order.
function Plist.dict(entries: {Plist.Entry}): Plist.Value
  return { kind = "dict", entries = entries }
end

--- A UID of `number`, from 0.
function Plist.uid(number: integer): Plist.Value
  return { kind = "uid", uid = number }
end

--- The value of `key` in `dict`; nil when it has no such key, or `dict` is not a dict.
function Plist.get(dict: Plist.Value, key: string): Plist.Value?
  for _, entry in ipairs(dict.entries or {}) do
    if entry.key == key then return entry.value end
  end
  return nil
end

return Plist
