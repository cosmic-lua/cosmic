--- Fuzz properties for the SQLite extensions the core is built with
--- (vendor/sqlite-ext/), each over the bytes a database or a caller can
--- hand it: `uncompress` reads a length and a zlib stream, `REGEXP`
--- compiles a pattern, `decimal` parses a number, and `base64`,
--- `base85` and `uuid_blob` decode text. Each is total: it answers a
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

--- A real's eight bytes, as ieee754.c and totype.c read a blob.
local function test_ieee754_and_totype_are_total_and_round_trip(tmp: string)
  Fuzz.run({
    name = "sqlite ieee754 totype total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local eight: {string} = {}
      for i = 1, 8 do eight[i] = string.char(src:int(0, 255)) end
      return Fuzz.pack({ table.concat(eight), Fuzz.bytes(src, 24) })
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local bits, other = fields[1], fields[2]
      local rows, trouble = Sqlite.text_rows(handle,
        "SELECT typeof(ieee754_from_blob(?1)), " ..
          "hex(ieee754_to_blob(ieee754_from_blob(?1))) = hex(?1), " ..
          "ieee754(ieee754_mantissa(?1), ieee754_exponent(?1)) = ieee754_from_blob(?1)",
        { { blob = bits } })
      if rows == nil then return false, "ieee754 failed its statement: " .. trouble end
      if rows[1][1] == "real" then
        Fuzz.label("a real")
        if rows[1][2] ~= "1" then return false, "ieee754_to_blob did not give the bytes back" end
        if rows[1][3] ~= "1" then return false, "mantissa and exponent did not rebuild the real" end
      else
        Fuzz.label("not a real")
      end
      for _, given in ipairs({ { blob = other } as Sqlite.Value, { text = other } as Sqlite.Value }) do
        if Sqlite.text_rows(handle, "SELECT tointeger(?1), toreal(?1), ieee754(?1)", { given }) == nil then
          return false, "totype failed its statement"
        end
      end
      return true, ""
    end,
    requires = { "a real" },
    shares = { ["a real"] = 0.5 },
  })
end

local function test_uint_orders_consistently(tmp: string)
  Fuzz.run({
    name = "sqlite uint collation order",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local alphabet = "0000123456789abcXYZ-+. "
      local function word(): string
        local chars: {string} = {}
        while Fuzz.more(src, #chars, 24) do
          local at = src:int(1, #alphabet)
          chars[#chars + 1] = alphabet:sub(at, at)
        end
        return table.concat(chars)
      end
      local first = word()
      -- Leading zeros on each run of digits leave a word equal to itself.
      if src:int(0, 2) == 0 then return Fuzz.pack({ first, (first:gsub("(%d+)", "0%1")) }) end
      return Fuzz.pack({ first, word() })
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local rows, trouble = Sqlite.text_rows(handle,
        "SELECT ?1 < ?2 COLLATE uint, ?2 < ?1 COLLATE uint, ?1 = ?2 COLLATE uint, " ..
          "?2 = ?1 COLLATE uint", { { text = fields[1] }, { text = fields[2] } })
      if rows == nil then return false, "uint failed its statement: " .. trouble end
      local less, more, equal, back = rows[1][1], rows[1][2], rows[1][3], rows[1][4]
      if equal ~= back then return false, "uint equality is not symmetric" end
      local held = (less == "1" and 1 or 0) + (more == "1" and 1 or 0) + (equal == "1" and 1 or 0)
      if held ~= 1 then return false, "exactly one of <, > and = must hold, not " .. held end
      Fuzz.label(equal == "1" and "equal" or "ordered")
      return true, ""
    end,
    requires = { "ordered", "equal" },
    shares = { ordered = 0.4, equal = 0.1 },
  })
end
