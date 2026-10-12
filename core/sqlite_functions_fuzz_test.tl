--- Fuzz properties for the SQLite extensions the core is built with
--- (vendor/sqlite-ext/), each over the bytes a database or a caller can
--- hand it: `uncompress` reads a length and a zlib stream, `REGEXP`
--- compiles a pattern, `decimal` parses a number, `base64`, `base85`
--- and `uuid_blob` decode text, `ieee754` takes bytes and
--- integers apart and back, `tointeger` and `toreal` read text as `CAST`
--- does, and `uint` orders text. Each is total: it answers a
--- value or NULL, or fails its statement with a message, and never
--- takes the process down. What an encoder writes, its decoder reads
--- back. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).
---
--- SQLite is fuzzed upstream, but not these files of ext/misc/: the
--- nightly run on the checked core is what holds their C to its bounds.

local Fuzz = require("build.fuzz")
local Sqlite = require("cosmic.sqlite")

local handle = assert(Sqlite.memory())

--- The one value `sql` yields over `values`, as SQLite's text, or nil
--- and the statement's error.
local function value(sql: string, values: {Sqlite.Value}): string | nil, string
  local rows, trouble = Sqlite.text_rows(handle, sql, values)
  if rows == nil then return nil, trouble end
  assert(#rows == 1, sql .. ": " .. #rows .. " rows")
  return rows[1][1], ""
end

--- A varint length as compress.c writes one: seven bits a byte, most
--- significant first, the last byte's top bit set.
local function length_prefix(n: integer): string
  local bytes: {integer} = {}
  repeat
    table.insert(bytes, 1, n & 0x7f)
    n = n >> 7
  until n == 0 or #bytes == 5
  bytes[#bytes] = bytes[#bytes] | 0x80
  return string.char(table.unpack(bytes))
end

local function gen_compressed(src: Fuzz.Source): string
  local shape = src:int(0, 3)
  if shape == 0 then return Fuzz.pack({ "read", Fuzz.bytes(src, 64) }) end
  local plain = Fuzz.bytes(src, 200)
  local packed = assert(value("SELECT compress(?1)", { { blob = plain } }))
  if shape == 1 then return Fuzz.pack({ "round trip", plain, packed }) end
  if shape == 2 then return Fuzz.pack({ "read", Fuzz.mutate(src, packed, 4) }) end
  -- A length the stream does not hold, up to the five bytes' most.
  local claims = src:int(0, 1) == 0 and src:int(0, 1 << 20) or (1 << 35) - 1 - src:int(0, 255)
  return Fuzz.pack({ "read", length_prefix(claims) .. packed:sub(src:int(1, #packed + 1)) })
end

local function test_uncompress_is_total_and_round_trips(tmp: string)
  Fuzz.run({
    name = "sqlite uncompress total",
    dir = tmp,
    gen = gen_compressed,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      if fields[1] == "round trip" then
        local back, trouble = value("SELECT hex(uncompress(?1)) = hex(?2)",
          { { blob = fields[3] }, { blob = fields[2] } })
        if back ~= "1" then return false, "compress did not round-trip: " .. (back or trouble) end
        Fuzz.label("round-tripped")
        return true, ""
      end
      local got, trouble = value("SELECT typeof(uncompress(?1))", { { blob = fields[2] } })
      if got == nil then return false, "uncompress failed its statement: " .. trouble end
      Fuzz.label(got == "null" and "refused" or "decoded")
      return true, ""
    end,
    requires = { "round-tripped", "decoded", "refused" },
    shares = { ["round-tripped"] = 0.1, decoded = 0.02, refused = 0.2 },
  })
end

--- What regexp.c's patterns are made of.
local PATTERN_TOKENS <const> = { "a", "b", ".", "*", "+", "?", "|", "(", ")", "[", "]", "^", "$",
  "\\", "\\d", "\\w", "\\s", "\\b", "{", "}", "{2}", "{1,3}", "{,", "-", "[^", "\xc3\xa9", "\0",
  "\xff" }

local function test_regexp_is_total(tmp: string)
  Fuzz.run({
    name = "sqlite regexp total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local parts: {string} = {}
      while Fuzz.more(src, #parts, 16) do parts[#parts + 1] = Fuzz.pick(src, PATTERN_TOKENS) end
      return Fuzz.pack({ table.concat(parts), Fuzz.bytes(src, 32) })
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local got, trouble = value("SELECT ?2 REGEXP ?1",
        { { text = fields[1] }, { text = fields[2] } })
      if got == nil then
        Fuzz.label("refused a pattern")
        if trouble == "" then return false, "a refusal must say why" end
      elseif got == "1" or got == "0" then
        Fuzz.label(got == "1" and "matched" or "did not match")
      else
        return false, "REGEXP answered " .. tostring(got)
      end
      return true, ""
    end,
    requires = { "matched", "did not match", "refused a pattern" },
    shares = { matched = 0.05, ["did not match"] = 0.1, ["refused a pattern"] = 0.02 },
  })
end

local NUMBERS <const> = { "0", "-0", "1.5", "-2", "1e10", "1E-400", "123456789012345678901234567890",
  "0.000000000000000000001", "+7", ".5", "5.", "1e", "--1", "1..2", "0x1F", " 3 ", "", "9e999" }

--- What `decimal` makes of a text, which it reads leniently, never as
--- NULL: a decimal reads back as itself and compares equal to itself,
--- and adding or multiplying two answers a value or fails its statement.
--- A NULL is `""` here, and a statement's failure is nil.
local function test_decimal_is_total_and_canonical(tmp: string)
  Fuzz.run({
    name = "sqlite decimal total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return Fuzz.pack({ Fuzz.mutate(src, Fuzz.pick(src, NUMBERS), 2),
        Fuzz.mutate(src, Fuzz.pick(src, NUMBERS), 2) })
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local values: {Sqlite.Value} = { { text = fields[1] }, { text = fields[2] } }
      local one: {Sqlite.Value} = { values[1] }
      local read = value("SELECT decimal(?1)", one)
      if read == nil then
        Fuzz.label("failed its statement")
      elseif read == "" then
        Fuzz.label("not a number")
      else
        Fuzz.label("read")
        local rows, trouble = Sqlite.text_rows(handle,
          "SELECT decimal(decimal(?1)), decimal_cmp(?1, ?1)", one)
        if rows == nil then
          return false, "decimal read " .. fields[1] .. " once only: " .. trouble
        end
        if rows[1][1] ~= read or rows[1][2] ~= "0" then
          return false, "decimal(" .. fields[1] .. ") = " .. tostring(read) .. " does not read back as itself"
        end
      end
      for _, sql in ipairs({ "SELECT decimal_add(?1, ?2)", "SELECT decimal_mul(?1, ?2)" }) do
        if value(sql, values) == nil then Fuzz.label("arithmetic failed its statement") end
      end
      return true, ""
    end,
    requires = { "read" },
    shares = { read = 0.5 },
  })
end

--- A UUID's text, in each form uuid_blob reads: plain, braced, with or
--- without its dashes.
local function uuid_text(src: Fuzz.Source): string
  local hex = "0123456789abcdefABCDEF"
  local digits: {string} = {}
  for i = 1, 32 do
    local at = src:int(1, #hex)
    digits[i] = hex:sub(at, at)
  end
  local plain = table.concat(digits)
  local text = src:int(0, 1) == 0 and plain or (plain:sub(1, 8) .. "-" .. plain:sub(9, 12) .. "-" ..
    plain:sub(13, 16) .. "-" .. plain:sub(17, 20) .. "-" .. plain:sub(21))
  if src:int(0, 2) == 0 then text = "{" .. text .. "}" end
  return text
end

local function test_text_decoders_are_total_and_round_trip(tmp: string)
  Fuzz.run({
    name = "sqlite base64 base85 uuid total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=-{}! \n#~"
      local chars: {string} = {}
      while Fuzz.more(src, #chars, 48) do
        local at = src:int(1, #alphabet)
        chars[#chars + 1] = alphabet:sub(at, at)
      end
      local uuid = uuid_text(src)
      if src:int(0, 1) == 0 then uuid = Fuzz.mutate(src, uuid, 2) end
      return Fuzz.pack({ Fuzz.bytes(src, 64), table.concat(chars), uuid })
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local blob, text, uuid = fields[1], fields[2], fields[3]
      for _, name in ipairs({ "base64", "base85" }) do
        local back, trouble = value("SELECT hex(" .. name .. "(" .. name .. "(?1))) = hex(?1)",
          { { blob = blob } })
        if back ~= "1" then
          return false, name .. " did not round-trip: " .. (back or trouble)
        end
        if value("SELECT typeof(" .. name .. "(?1))", { { text = text } }) == nil then
          return false, name .. " failed its statement on text"
        end
      end
      local rows, trouble = Sqlite.text_rows(handle, "SELECT uuid_blob(?1) IS NULL, " ..
          "hex(uuid_blob(uuid_str(?1))) = hex(uuid_blob(?1))", { { text = uuid } })
      if rows == nil then return false, "uuid_blob failed its statement: " .. trouble end
      if rows[1][1] == "1" then
        Fuzz.label("uuid refused")
      elseif rows[1][2] == "1" then
        Fuzz.label("uuid decoded")
      else
        return false, "uuid_str did not round-trip " .. uuid
      end
      return true, ""
    end,
    requires = { "uuid decoded", "uuid refused" },
    shares = { ["uuid decoded"] = 0.3, ["uuid refused"] = 0.1 },
  })
end

--- A real's eight bytes, as ieee754.c reads a blob: whatever real they
--- hold goes back to the same bytes, through `ieee754_to_blob`, through its
--- integer and through `ieee754(M, E)`; and `ieee754(M, E)` answers a
--- real for any integers but the least M.
local function test_ieee754_is_total_and_round_trips(tmp: string)
  Fuzz.run({
    name = "sqlite ieee754 total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local eight: {string} = {}
      for i = 1, 8 do eight[i] = string.char(src:int(0, 255)) end
      local edges = { 0, 1, -1, 52, 53, 1023, 1024, 1074, 1075, 2000, -1074, -1075, -2000, 10001 }
      local e = src:int(0, 1) == 0 and Fuzz.pick(src, edges) or src:int(-3000, 3000)
      local m = src:int(0, 2) == 0 and src:int(-8, 8) or src:int(0, 7) == 0 and math.mininteger or
        src:int(math.mininteger, math.maxinteger)
      return Fuzz.pack({ table.concat(eight), tostring(m), tostring(e) })
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local rows, trouble = Sqlite.text_rows(handle,
        "SELECT typeof(ieee754_from_blob(?1)), " ..
          "hex(ieee754_to_blob(ieee754_from_blob(?1))) = hex(?1), " ..
          "hex(ieee754_to_blob(ieee754(ieee754_mantissa(?1), ieee754_exponent(?1)))) = hex(?1), " ..
          "hex(ieee754_to_blob(ieee754_from_int(ieee754_to_int(ieee754_from_blob(?1))))) = hex(?1), " ..
          "typeof(ieee754(?2, ?3))",
        { { blob = fields[1] }, { integer = math.tointeger(fields[2]) },
          { integer = math.tointeger(fields[3]) } })
      if rows == nil then return false, "ieee754 failed its statement: " .. trouble end
      local row = rows[1]
      local least = math.tointeger(fields[2]) == math.mininteger
      if row[5] ~= (least and "null" or "real") then
        return false, "ieee754(M, E) answered " .. row[5]
      end
      if row[1] == "real" then
        Fuzz.label("a real")
        for i, what in ipairs({ "ieee754_to_blob", "ieee754(M, E)", "ieee754_to_int" }) do
          if row[i + 1] ~= "1" then return false, what .. " did not give the bytes back" end
        end
      else
        Fuzz.label("a NaN")
      end
      return true, ""
    end,
    requires = { "a real" },
    shares = { ["a real"] = 0.5 },
  })
end

--- Number-shaped text, from the pieces totype's reading turns on: runs of
--- digits past an integer's 19, exponents around a real's limits, signs,
--- points, spaces and NUL. A text drawn whole as a plain decimal is
--- `well`: it must convert. One drawn as a 64-bit integer, edges among
--- them, is `integer`: `tointeger` must answer it, and `toreal` must
--- answer it exactly or not at all.
local function gen_number(src: Fuzz.Source): string
  local digits = "0123456789"
  local function run(max: integer): string
    local out: {string} = {}
    while Fuzz.more(src, #out, max) do
      local at = src:int(1, 10)
      out[#out + 1] = digits:sub(at, at)
    end
    return #out == 0 and "0" or table.concat(out)
  end
  local shape = src:int(0, 5)
  if shape == 0 then
    local edges = { 0, 1, -1, 1 << 53, (1 << 53) + 1, -((1 << 53) + 1), math.maxinteger,
      math.maxinteger - 1, math.mininteger, math.mininteger + 1 }
    local n = src:int(0, 1) == 0 and Fuzz.pick(src, edges) or src:int(math.mininteger, math.maxinteger)
    return Fuzz.pack({ "integer", tostring(n) })
  end
  if shape <= 2 then
    local text = (src:int(0, 1) == 0 and "-" or "") .. run(15) .. "." .. run(15) ..
      "e" .. tostring(src:int(-290, 290))
    return Fuzz.pack({ "well", text })
  end
  local pieces = { "-", "+", ".", "e", "E", " ", "\0", "x",
    "308", "309", "324", "400", "-308", "-324", "-400" }
  local parts: {string} = {}
  while Fuzz.more(src, #parts, 6) do
    parts[#parts + 1] = src:int(0, 1) == 0 and run(30) or Fuzz.pick(src, pieces)
  end
  return Fuzz.pack({ "any", table.concat(parts) })
end

--- What `tointeger` and `toreal` make of a text: `toreal` answers what
--- `CAST` does when it answers, and a well-formed decimal converts;
--- `tointeger` answers an integer literal an integer holds as itself, and
--- NULL for anything else.
local function test_totype_reads_text_as_cast_does(tmp: string)
  Fuzz.run({
    name = "sqlite totype as cast",
    dir = tmp,
    gen = gen_number,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local shape, text = fields[1], fields[2]
      local rows, trouble = Sqlite.text_rows(handle,
        "SELECT typeof(toreal(?1)), toreal(?1) = CAST(?1 AS REAL), toreal(?1) - toreal(?1) = 0.0, " ..
          "typeof(tointeger(?1)), tointeger(?1), " ..
          "typeof(tointeger(?2)), typeof(toreal(?2))",
        { { text = text }, { blob = text } })
      if rows == nil then return false, "totype failed its statement: " .. trouble end
      local row = rows[1]
      if row[1] == "real" then
        Fuzz.label("read as a real")
        if row[2] ~= "1" then return false, "toreal(" .. text .. ") is not CAST's" end
        if row[3] ~= "1" then return false, "toreal(" .. text .. ") is not finite" end
      elseif shape == "well" then
        return false, "toreal refused the decimal " .. text
      end
      -- An integer literal an integer holds converts to itself; anything
      -- else is NULL.
      local literal = text:match("^[+-]?%d+$") and math.tointeger((text:gsub("^%+", "")))
      if literal ~= nil then
        Fuzz.label("read as an integer")
        if row[5] ~= tostring(literal) then
          return false, "tointeger(" .. text .. ") answered " .. row[5]
        end
      elseif row[4] ~= "null" then
        return false, "tointeger(" .. text .. ") is no integer literal, but answered " .. row[5]
      end
      if shape == "integer" then
        local n = math.tointeger(text)
        if row[5] ~= text then return false, "tointeger(" .. text .. ") answered " .. row[5] end
        local exact = math.tointeger((n as number) + 0.0) == n
        if (row[1] == "real") ~= exact then
          return false, "toreal(" .. text .. ") is " .. row[1] .. " though a real holds it " ..
            (exact and "exactly" or "inexactly")
        end
      end
      if row[6] ~= (#text == 8 and "integer" or "null") then
        return false, "tointeger of a " .. #text .. "-byte blob answered " .. row[6]
      end
      if #text ~= 8 and row[7] ~= "null" then
        return false, "toreal of a " .. #text .. "-byte blob answered " .. row[7]
      end
      return true, ""
    end,
    requires = { "read as a real", "read as an integer" },
    shares = { ["read as a real"] = 0.3, ["read as an integer"] = 0.02 },
  })
end

local function test_uint_orders_consistently(tmp: string)
  Fuzz.run({
    name = "sqlite uint collation order",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local alphabet = "0000123456789abcXYZ-+. \xc3\xa9\xff"
      local function word(): string
        local chars: {string} = {}
        while Fuzz.more(src, #chars, 40) do
          local at = src:int(1, #alphabet)
          chars[#chars + 1] = alphabet:sub(at, at)
        end
        return table.concat(chars)
      end
      return Fuzz.pack({ word(), word(), word() })
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local a, b, c = fields[1], fields[2], fields[3]
      -- Leading zeros on each run of digits leave a word equal to itself.
      local padded = (a:gsub("(%d+)", "00%1"))
      local function cmp(x: string, y: string): integer
        local rows = assert(Sqlite.text_rows(handle,
          "SELECT ?1 < ?2 COLLATE uint, ?1 = ?2 COLLATE uint, ?2 < ?1 COLLATE uint",
          { { text = x }, { text = y } }))
        local less, equal, more = rows[1][1] == "1", rows[1][2] == "1", rows[1][3] == "1"
        local held = (less and 1 or 0) + (equal and 1 or 0) + (more and 1 or 0)
        assert(held == 1, "exactly one of <, = and > holds, not " .. held)
        return less and -1 or equal and 0 or 1
      end
      if cmp(a, padded) ~= 0 then return false, "zeros before digits changed the order" end
      local ab, bc, ac = cmp(a, b), cmp(b, c), cmp(a, c)
      if ab == bc and ac ~= ab then return false, "uint is not transitive" end
      if cmp(b, a) ~= -ab then return false, "uint is not antisymmetric" end
      Fuzz.label(ab == 0 and "equal" or "ordered")
      return true, ""
    end,
    requires = { "ordered" },
    shares = { ordered = 0.5 },
  })
end
