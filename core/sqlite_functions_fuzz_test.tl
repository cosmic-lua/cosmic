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
    shares = { ["round-tripped"] = 0.1, refused = 0.2 },
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
    shares = { matched = 0.05, ["did not match"] = 0.1, ["refused a pattern"] = 0.02 },
  })
end

local NUMBERS <const> = { "0", "-0", "1.5", "-2", "1e10", "1E-400", "123456789012345678901234567890",
  "0.000000000000000000001", "+7", ".5", "5.", "1e", "--1", "1..2", "0x1F", " 3 ", "", "9e999999999" }

local function test_decimal_is_total(tmp: string)
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
      for _, sql in ipairs({ "SELECT decimal(?1)", "SELECT decimal_add(?1, ?2)",
          "SELECT decimal_mul(?1, ?2)", "SELECT decimal_cmp(?1, ?2)" }) do
        local got = value(sql, values)
        Fuzz.label(got == nil and "refused" or "answered")
      end
      return true, ""
    end,
    shares = { answered = 0.5 },
  })
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
      return Fuzz.pack({ Fuzz.bytes(src, 64), table.concat(chars) })
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local blob, text = fields[1], fields[2]
      for _, name in ipairs({ "base64", "base85" }) do
        local back, trouble = value("SELECT hex(" .. name .. "(" .. name .. "(?1))) = hex(?1)",
          { { blob = blob } })
        if back ~= "1" then
          return false, name .. " did not round-trip: " .. (back or trouble)
        end
        local got = value("SELECT typeof(" .. name .. "(?1))", { { text = text } })
        Fuzz.label(name .. (got == "blob" and " decoded" or " refused"))
      end
      local got = value("SELECT typeof(uuid_blob(?1))", { { text = text } })
      Fuzz.label(got == "blob" and "uuid decoded" or "uuid refused")
      return true, ""
    end,
    shares = { ["base64 decoded"] = 0.2, ["uuid refused"] = 0.5 },
  })
end
