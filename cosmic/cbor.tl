--- CBOR, the Concise Binary Object Representation (RFC 8949): the binary
--- format WebAuthn, COSE and CTAP speak. [`Cbor.decode`] reads bytes into
--- an [`Cbor.Item`] tree and [`Cbor.encode`] writes one back.
---
---     local item = assert(Cbor.decode("\xa2\x01\x02\x63key\x44\x01\x02\x03\x04"))
---     assert(Cbor.get(item, 1).integer == 2)
---     assert(Cbor.get(item, "key").bytes == "\1\2\3\4")
---     assert(Cbor.encode(item) == "\xa2\x01\x02\x63key\x44\x01\x02\x03\x04")
---
--- An item says its kind, as CBOR has it, and holds its value in the
--- field of that kind: a byte string and a text string are both Lua
--- strings in `bytes`, told apart by `kind`. An integer of the 64-bit
--- signed range is an "integer"; one past it, which CBOR's 64-bit heads
--- can spell, is a "big", its magnitude in `bytes`. A tag number of 2^63
--- or more, which no registered tag has, is refused, and every NaN is
--- written as the one quiet NaN, `f97e00`, its payload not kept.
---
--- Decoding takes bytes from anyone: what is not CBOR, or nests past
--- `max_depth`, returns nil and a reason, and nothing raises but a
--- failure to allocate. Each item is a Lua table, a hundred bytes or
--- more, so bound the length of what is decoded where memory counts. A map that
--- holds a key twice is refused, as RFC 8949 section 5.6 lets a decoder
--- do, so a reader of one key cannot be shown a value another reader
--- does not see. A length longer than the bytes left is refused before
--- anything is made of it.
---
--- Encoding writes the preferred serialization (section 4.1): each head
--- as short as it can be, definite lengths, and each float in the
--- shortest of half, single and double that holds it exactly.
--- `sort = true` also sorts each map's keys by their encoded bytes, which
--- with the rest is section 4.2.1's core deterministic encoding.
--- @public

local record Cbor
  --- What kind of item an [`Item`] is.
  enum Kind
    --- An integer of the 64-bit signed range: `integer`.
    "integer"
    --- An integer past it: the magnitude, big-endian, in `bytes`, and
    --- `negative`. A negative one is -1 less the magnitude, as CBOR's
    --- major type 1 has it.
    "big"
    --- A byte string: `bytes`.
    "bytes"
    --- A text string, UTF-8: `bytes`.
    "text"
    --- An array: `items`.
    "array"
    --- A map: `entries`, in the order the bytes hold them.
    "map"
    --- A tagged item: `tag`, and the item in `of`.
    "tag"
    --- A float: `number`.
    "float"
    --- A simple value: `simple`, 20 for false, 21 for true, 22 for
    --- null, 23 for undefined.
    "simple"
  end

  --- One CBOR data item.
  record Item
    --- What sort of item it is, which says which fields below it has.
    kind: Kind
    --- An "integer"'s value.
    integer?: integer
    --- A "bytes" or "text" item's bytes; a "big" item's magnitude.
    bytes?: string
    --- Whether a "big" item is negative.
    negative?: boolean
    --- An "array"'s items.
    items?: {Item}
    --- A "map"'s entries.
    entries?: {Entry}
    --- A "tag" item's tag number.
    tag?: integer
    --- What a "tag" item tags.
    of?: Item
    --- A "float"'s value.
    number?: number
    --- A "simple" item's value, 0 to 255.
    simple?: integer
  end

  --- One key and its value, of a map.
  record Entry
    --- The key.
    key: Item
    --- Its value.
    value: Item
  end

  --- What [`Cbor.decode`] takes.
  record DecodeOptions
    --- How many arrays, maps and tags may nest, 1 to 1000 (64).
    max_depth?: integer
  end

  --- What [`Cbor.decode_first`] answers.
  record Decoded
    --- The item.
    item: Item
    --- Where the bytes after it start.
    next: integer
  end

  --- What [`Cbor.encode`] takes.
  record EncodeOptions
    --- Sort each map's keys by their encoded bytes (false).
    sort?: boolean
  end
end

local type Item = Cbor.Item

local DEFAULT_DEPTH <const> = 64
--- The deepest `max_depth`: each level is a Lua call, and Lua's stack
--- holds about 200000.
local MAX_DEPTH <const> = 1000

--- A head of `major` with the argument `n`, as short as it can be.
local function head(major: integer, n: integer): string
  if n < 0 then error(("cbor: an argument of %d cannot be written"):format(n), 0) end
  local m = major << 5
  if n < 24 then return string.char(m | n) end
  if n < 0x100 then return string.char(m | 24, n) end
  if n < 0x10000 then return string.char(m | 25) .. string.pack(">I2", n) end
  if n < 0x100000000 then return string.char(m | 26) .. string.pack(">I4", n) end
  return string.char(m | 27) .. string.pack(">i8", n)
end

--- The 16 bits of `x` as a half, where a half holds it exactly.
local function to_half(x: number): integer?
  if x ~= x then return 0x7e00 end
  local sign = if x < 0 or 1 / x < 0 then 0x8000 else 0 end
  local a = math.abs(x)
  if a == math.huge then return sign | 0x7c00 end
  if a == 0 then return sign end
  for exp = 1, 30 do
    local mant = a / 2.0 ^ (exp - 25) - 1024
    if mant >= 0 and mant < 1024 and mant == math.floor(mant) then
      return sign | (exp << 10) | assert(math.tointeger(mant))
    end
  end
  local sub = a / 2.0 ^ -24
  if sub < 1024 and sub == math.floor(sub) then return sign | assert(math.tointeger(sub)) end
  return nil
end

--- Whether `a` sorts before `b` byte by byte, as RFC 8949 section 4.2.1
--- orders keys: `<` on strings follows the C library's collation.
local function bytewise_less(a: string, b: string): boolean
  for i = 1, math.min(#a, #b) do
    local x, y = assert(a:byte(i)), assert(b:byte(i))
    if x ~= y then return x < y end
  end
  return #a < #b
end

local function write(item: Cbor.Item, sort: boolean, out: mut {string})
  local kind = item.kind
  if kind == "integer" then
    local n = assert(item.integer, "cbor: an integer item has no integer")
    local spelled = if n >= 0 then head(0, n) else head(1, -1 - n) end
    out[#out + 1] = spelled
  elseif kind == "big" then
    local magnitude = assert(item.bytes, "cbor: a big item has no bytes")
    local trimmed = magnitude:gsub("^\0+", "")
    if #trimmed > 8 then error("cbor: a big item is past 64 bits", 0) end
    local padded = ("\0"):rep(8 - #trimmed) .. trimmed
    local major = if item.negative == true then 1 else 0 end
    if (padded:byte(1) or 0) >= 0x80 then
      local piece = string.char((major << 5) | 27) .. padded
      out[#out + 1] = piece
    else
      local piece = head(major, (string.unpack(">i8", padded)))
      out[#out + 1] = piece
    end
  elseif kind == "bytes" or kind == "text" then
    local s = assert(item.bytes, "cbor: a string item has no bytes")
    local piece = head(if kind == "bytes" then 2 else 3 end, #s) .. s
    out[#out + 1] = piece
  elseif kind == "array" then
    local items = item.items or {}
    local piece = head(4, #items)
    out[#out + 1] = piece
    for _, each in ipairs(items) do write(each, sort, out) end
  elseif kind == "map" then
    local entries = item.entries or {}
    local piece = head(5, #entries)
    out[#out + 1] = piece
    local spelled: mut {{string}} = {}
    for i, entry in ipairs(entries) do
      local k: mut {string} = {}
      write(entry.key, sort, k)
      local v: mut {string} = {}
      write(entry.value, sort, v)
      spelled[i] = { table.concat(k), table.concat(v) }
    end
    if sort then
      table.sort(spelled, function(a: {string}, b: {string}): boolean
        return bytewise_less(assert(a[1]), assert(b[1]))
      end)
    end
    for _, pair in ipairs(spelled) do
      local joined = assert(pair[1]) .. assert(pair[2])
      out[#out + 1] = joined
    end
  elseif kind == "tag" then
    local piece = head(6, (assert(item.tag, "cbor: a tag item has no tag")))
    out[#out + 1] = piece
    write(assert(item.of, "cbor: a tag item tags nothing"), sort, out)
  elseif kind == "float" then
    local x = assert(item.number, "cbor: a float item has no number")
    local h = to_half(x)
    if h ~= nil then
      local piece = string.char(0xf9) .. string.pack(">I2", h)
      out[#out + 1] = piece
    elseif (string.unpack(">f", string.pack(">f", x))) == x then
      local piece = string.char(0xfa) .. string.pack(">f", x)
      out[#out + 1] = piece
    else
      local piece = string.char(0xfb) .. string.pack(">d", x)
      out[#out + 1] = piece
    end
  else
    local v = assert(item.simple, "cbor: a simple item has no value")
    if v < 24 then
      local piece = string.char(0xe0 | v)
      out[#out + 1] = piece
    elseif v >= 32 and v <= 255 then
      local piece = string.char(0xf8, v)
      out[#out + 1] = piece
    else
      error(("cbor: a simple value of %d cannot be written"):format(v), 0)
    end
  end
end

--- Why the decode under way stopped, set where it raises. A decode
--- never yields, so one is under way at a time.
local failure: string? = nil

local function stop(why: string)
  failure = why
  error("cbor: " .. why, 0)
end

--- The decoder's state over `text`.
local record Reader
  text: string
  mut at: integer
  max_depth: integer
end

local function byte_at(r: Reader): integer
  local b = r.text:byte(r.at)
  if b == nil then stop("the bytes end inside an item") end
  r.at = r.at + 1
  return assert(b)
end

local function take(r: Reader, n: integer): string
  if n < 0 or n > #r.text - r.at + 1 then stop("a length runs past the end of the bytes") end
  local out = r.text:sub(r.at, r.at + n - 1)
  r.at = r.at + n
  return out
end

--- The argument of a head whose additional information is `ai`: nil
--- for an indefinite length (31), and the 8 bytes as they are for a
--- 64-bit argument past the signed range, as the second value.
local function argument(r: Reader, ai: integer): integer?, string
  if ai < 24 then return ai, "" end
  if ai == 24 then return byte_at(r), "" end
  if ai == 25 then return (string.unpack(">I2", take(r, 2))), "" end
  if ai == 26 then return (string.unpack(">I4", take(r, 4))), "" end
  if ai == 27 then
    local raw = take(r, 8)
    if (raw:byte(1) or 0) >= 0x80 then return nil, raw end
    return (string.unpack(">i8", raw)), ""
  end
  if ai == 31 then return nil, "" end
  stop(("a head's additional information %d is reserved"):format(ai))
  return nil, ""
end

--- A length: a definite argument within the bytes left, else a stop.
local function length(r: Reader, ai: integer): integer?
  local n, big = argument(r, ai)
  if big ~= "" then stop("a length runs past the end of the bytes") end
  return n
end

--- A float of the 16 bits `h` (IEEE 754 half precision).
local function half(h: integer): number
  local exp = (h >> 10) & 0x1f
  local mant = h & 0x3ff
  local value: number
  if exp == 0 then
    value = mant * 2.0 ^ -24
  elseif exp == 31 then
    value = if mant == 0 then math.huge else 0.0 / 0.0 end
  else
    value = (mant + 1024) * 2.0 ^ (exp - 25)
  end
  if h & 0x8000 ~= 0 then return -value end
  return value
end

--- The chunks of an indefinite-length string of `major`, joined.
local function chunks(r: Reader, major: integer): string
  local parts: mut {string} = {}
  while true do
    local b = byte_at(r)
    if b == 0xff then break end
    if b >> 5 ~= major then stop("a chunk of an indefinite string is of another type") end
    local n = length(r, b & 0x1f)
    if n == nil then stop("a chunk of an indefinite string is itself indefinite") end
    local chunk = take(r, assert(n))
    -- RFC 8949 section 3.2.3: each chunk of a text string is UTF-8 alone.
    if major == 3 and utf8.len(chunk) == nil then stop("a chunk of a text string is not UTF-8") end
    parts[#parts + 1] = chunk
  end
  return table.concat(parts)
end

--- Whether the next byte is the break that ends an indefinite item,
--- taken if so.
local function at_break(r: Reader): boolean
  if r.text:byte(r.at) == 0xff then
    r.at = r.at + 1
    return true
  end
  return false
end

local function read(r: Reader, depth: integer): Item
  local b = byte_at(r)
  local major, ai = b >> 5, b & 0x1f
  if major >= 4 and major <= 6 and depth > r.max_depth then
    stop(("items nest past max_depth (%d)"):format(r.max_depth))
  end
  if major == 0 or major == 1 then
    local n, big = argument(r, ai)
    if ai == 31 then stop("an integer cannot be indefinite") end
    if n == nil then return { kind = "big", bytes = big, negative = major == 1 } end
    if major == 0 then return { kind = "integer", integer = n } end
    return { kind = "integer", integer = -1 - assert(n) }
  elseif major == 2 or major == 3 then
    local n = length(r, ai)
    local s = if n == nil then chunks(r, major) else take(r, n) end
    if major == 3 then
      if utf8.len(s) == nil then stop("a text string is not UTF-8") end
      return { kind = "text", bytes = s }
    end
    return { kind = "bytes", bytes = s }
  elseif major == 4 then
    local n = length(r, ai)
    local items: mut {Item} = {}
    if n == nil then
      while not at_break(r) do items[#items + 1] = read(r, depth + 1) end
    else
      -- Each item is at least a byte, so a count past those left is a lie.
      if n > #r.text - r.at + 1 then stop("a length runs past the end of the bytes") end
      for _ = 1, n do
        local each = read(r, depth + 1)
        items[#items + 1] = each
      end
    end
    return { kind = "array", items = items }
  elseif major == 5 then
    local n = length(r, ai)
    local entries: mut {Cbor.Entry} = {}
    local seen: mut {string: boolean} = {}
    local function entry()
      local key = read(r, depth + 1)
      -- Compared as written back, so that one key spelled two ways (a
      -- longer head, an indefinite string) is still one key.
      local out: mut {string} = {}
      write(key, false, out)
      local spelled = table.concat(out)
      if seen[spelled] == true then stop("a map holds a key twice") end
      seen[spelled] = true
      local value = read(r, depth + 1)
      entries[#entries + 1] = { key = key, value = value }
    end
    if n == nil then
      while not at_break(r) do entry() end
    else
      if n > (#r.text - r.at + 1) // 2 then stop("a length runs past the end of the bytes") end
      for _ = 1, n do entry() end
    end
    return { kind = "map", entries = entries }
  elseif major == 6 then
    local n, big = argument(r, ai)
    if n == nil then
      stop(if big ~= "" then "a tag number past the 64-bit signed range is not taken" else "a tag cannot be indefinite" end)
    end
    return { kind = "tag", tag = n, of = read(r, depth + 1) }
  end
  if ai < 24 then return { kind = "simple", simple = ai } end
  if ai == 24 then
    local v = byte_at(r)
    if v < 32 then stop("a simple value under 32 is spelled in one byte") end
    return { kind = "simple", simple = v }
  end
  if ai == 25 then return { kind = "float", number = half((string.unpack(">I2", take(r, 2)))) } end
  if ai == 26 then return { kind = "float", number = (string.unpack(">f", take(r, 4))) } end
  if ai == 27 then return { kind = "float", number = (string.unpack(">d", take(r, 8))) } end
  if ai == 31 then stop("a break where no indefinite item is open") end
  stop(("a head's additional information %d is reserved"):format(ai))
  return { kind = "simple", simple = 0 }
end

--- The first item of `text` from byte `at` (1, and no less), and where
--- the bytes after it start; nil and why for bytes that do not start
--- with an item. Raises on a `max_depth` out of its range.
---
---     local first = assert(Cbor.decode_first("\x01\x02"))
---     assert(first.item.integer == 1 and first.next == 2)
function Cbor.decode_first(text: string, at?: integer, opts?: Cbor.DecodeOptions): Cbor.Decoded?, string
  local start = at or 1
  if start < 1 then return nil, "cbor: at is from 1" end
  local depth = (opts or {}).max_depth or DEFAULT_DEPTH
  if math.type(depth) ~= "integer" or depth < 1 or depth > MAX_DEPTH then
    error(("cbor: max_depth is from 1 to %d"):format(MAX_DEPTH), 2)
  end
  local r: Reader = { text = text, at = start, max_depth = depth }
  failure = nil
  match pcall(read, r, 1) do
  | (true, item) then
    return { item = item, next = r.at }, ""
  | (false, why) then
    local stopped = failure
    if stopped == nil then error(why, 0) end
    failure = nil
    return nil, "cbor: " .. stopped
  end
end

--- The one item `text` holds; nil and why for bytes that are not
--- exactly one item.
---
---     local item = assert(Cbor.decode("\x83\x01\x02\x03"))
---     assert(#item.items == 3)
function Cbor.decode(text: string, opts?: Cbor.DecodeOptions): Cbor.Item?, string
  local first, why = Cbor.decode_first(text, 1, opts)
  if first == nil then return nil, why end
  if first.next <= #text then
    return nil, ("cbor: more follows the item, from byte %d"):format(first.next)
  end
  return first.item, ""
end

--- The value of `map` at `key`, an integer or a text key; nil where
--- `map` is no map or holds no such key.
---
---     local alg = Cbor.get(cose_key, 3)
function Cbor.get(map: Cbor.Item, key: integer | string): Cbor.Item?
  if map.kind ~= "map" then return nil end
  for _, entry in ipairs(map.entries or {}) do
    local k = entry.key
    if key is integer then
      if k.kind == "integer" and k.integer == key then return entry.value end
    elseif k.kind == "text" and k.bytes == key then
      return entry.value
    end
  end
  return nil
end

--- An integer item.
function Cbor.integer(n: integer): Cbor.Item
  return { kind = "integer", integer = n }
end

--- A byte string item.
function Cbor.bytes(s: string): Cbor.Item
  return { kind = "bytes", bytes = s }
end

--- A text string item. Raises on text that is not UTF-8.
function Cbor.text(s: string): Cbor.Item
  if utf8.len(s) == nil then error("cbor: text is not UTF-8", 2) end
  return { kind = "text", bytes = s }
end

--- An array item.
function Cbor.array(items: {Cbor.Item}): Cbor.Item
  return { kind = "array", items = items }
end

--- A map item of `entries`, each a key and its value, in order.
---
---     local key = Cbor.map({ { Cbor.integer(1), Cbor.integer(2) } })
function Cbor.map(entries: {{Cbor.Item}}): Cbor.Item
  local out: mut {Cbor.Entry} = {}
  for i, pair in ipairs(entries) do
    out[i] = { key = assert(pair[1], "cbor: an entry is a key and a value"), value = assert(pair[2], "cbor: an entry is a key and a value") }
  end
  return { kind = "map", entries = out }
end

--- A float item.
function Cbor.float(x: number): Cbor.Item
  return { kind = "float", number = x }
end

--- `true` or `false`.
function Cbor.boolean(b: boolean): Cbor.Item
  return { kind = "simple", simple = if b then 21 else 20 end }
end

--- The CBOR bytes of `item`, in the preferred serialization; with
--- `opts.sort`, each map's keys sorted, the core deterministic encoding.
--- Raises on an item that is not whole: a kind whose field is missing.
---
---     assert(Cbor.encode(Cbor.array({ Cbor.integer(1), Cbor.text("a") })) == "\x82\x01\x61a")
function Cbor.encode(item: Cbor.Item, opts?: Cbor.EncodeOptions): string
  local out: mut {string} = {}
  write(item, (opts or {}).sort == true, out)
  return table.concat(out)
end

return Cbor
