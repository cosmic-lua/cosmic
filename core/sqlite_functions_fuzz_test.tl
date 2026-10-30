--- Fuzz properties for the SQLite extensions the core is built with
--- (vendor/sqlite-ext/), each over the bytes a database or a caller can
--- hand it: `uncompress` reads a length and a zlib stream, `REGEXP`
--- compiles a pattern, `decimal` parses a number, `base64`, `base85`
--- and `uuid_blob` decode text, `ieee754` takes bytes and
--- integers apart and back, `tointeger` reads an integer literal and
--- `toreal` text as `CAST` does, `uint` orders text, and `carray` reads
--- a bound list back. Each is total: it answers a
--- value or NULL, or fails its statement with a message, and never
--- takes the process down. What an encoder writes, its decoder reads
--- back. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).
---
--- SQLite is fuzzed upstream, but not these files of ext/misc/: the
--- nightly run on the checked core is what holds their C to its bounds.

local Fuzz = require("build.fuzz")
local Sqlite = require("cosmic.sqlite")

local handle = assert(Sqlite.memory())

--- Field `i` of an unpacked input, which the generators pack whole.
local function unpacked(fields: {string}, i: integer): string
  local field = fields[i]
  assert(field, "the generator packs field " .. tostring(i))
  return field
end

--- The first of `rows`, which the statement is known to yield.
local function first_row(rows: Sqlite.Rows): Sqlite.Row
  local found = rows[1]
  assert(found, "the statement yields a row")
  return found
end

--- The one value `sql` yields over `values`, as SQLite's text, or nil
--- and the statement's error.
local function value(sql: string, values: {Sqlite.Value}): string?, string
  local rows, trouble = Sqlite.text_rows(handle, sql, values)
  if rows == nil then return nil, trouble end
  assert(#rows == 1, sql .. ": " .. tostring(#rows) .. " rows")
  return first_row(rows):text(1), ""
end

--- A varint length as compress.c writes one: seven bits a byte, most
--- significant first, the last byte's top bit set.
local function length_prefix(n: integer): string
  local bytes: mut {integer} = {}
  repeat
    table.insert(bytes, 1, n & 0x7f)
    n = n >> 7
  until n == 0 or #bytes == 5
  local last = assert(table.remove(bytes))
  bytes[#bytes + 1] = last | 0x80
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
      Fuzz.label(if got == "null" then "refused" else "decoded" end)
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
      local parts: mut {string} = {}
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
        Fuzz.label(if got == "1" then "matched" else "did not match" end)
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
      local number, other = unpacked(fields, 1), unpacked(fields, 2)
      local values: {Sqlite.Value} = { { text = number }, { text = other } }
      local one: {Sqlite.Value} = { { text = number } }
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
          return false, "decimal read " .. number .. " once only: " .. trouble
        end
        local again = first_row(rows)
        if again:text(1) ~= read or again:text(2) ~= "0" then
          return false, "decimal(" .. number .. ") = " .. tostring(read) .. " does not read back as itself"
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
  local digits: mut {string} = {}
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
      local chars: mut {string} = {}
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
      local blob, text, uuid = unpacked(fields, 1), unpacked(fields, 2), unpacked(fields, 3)
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
      local decoded = first_row(rows)
      if decoded:text(1) == "1" then
        Fuzz.label("uuid refused")
      elseif decoded:text(2) == "1" then
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
--- integer and through `ieee754(M, E)`; `ieee754(M, E)` answers a real for
--- any integers but the least M, and `ieee754_inc` a real or NULL.
local function test_ieee754_is_total_and_round_trips(tmp: string)
  Fuzz.run({
    name = "sqlite ieee754 total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local eight: mut {string} = {}
      for i = 1, 8 do eight[i] = string.char(src:int(0, 255)) end
      local edges = { 0, 1, -1, 52, 53, 1023, 1024, 1074, 1075, 2000, -1074, -1075, -2000, 10001 }
      local e = src:int(0, 1) == 0 and Fuzz.pick(src, edges) or src:int(-3000, 3000)
      local m = if src:int(0, 2) == 0 then src:int(-8, 8)
        elseif src:int(0, 7) == 0 then math.mininteger
        else src:int(math.mininteger, math.maxinteger) end
      return Fuzz.pack({ table.concat(eight), tostring(m), tostring(e) })
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local rows, trouble = Sqlite.text_rows(handle,
        "SELECT typeof(ieee754_from_blob(?1)), " ..
          "hex(ieee754_to_blob(ieee754_from_blob(?1))) = hex(?1), " ..
          "hex(ieee754_to_blob(ieee754(ieee754_mantissa(?1), ieee754_exponent(?1)))) = hex(?1), " ..
          "hex(ieee754_to_blob(ieee754_from_int(ieee754_to_int(ieee754_from_blob(?1))))) = hex(?1), " ..
          "typeof(ieee754(?2, ?3)), typeof(ieee754_inc(ieee754_from_blob(?1), ?2))",
        { { blob = fields[1] }, { integer = math.tointeger(fields[2]) },
          { integer = math.tointeger(fields[3]) } })
      if rows == nil then return false, "ieee754 failed its statement: " .. trouble end
      local row = first_row(rows)
      local least = math.tointeger(fields[2]) == math.mininteger
      if row:text(5) ~= (if least then "null" else "real" end) then
        return false, "ieee754(M, E) answered " .. row:text(5)
      end
      if row:text(6) ~= "real" and row:text(6) ~= "null" then
        return false, "ieee754_inc answered " .. row:text(6)
      end
      if row:text(1) == "real" then
        Fuzz.label("a real")
        for i, what in ipairs({ "ieee754_to_blob", "ieee754(M, E)", "ieee754_to_int" }) do
          if row:text(i + 1) ~= "1" then return false, what .. " did not give the bytes back" end
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

--- The integer an integer literal names, a sign and digits, as the
--- decimal Lua writes it; nil for any other text and for a literal past
--- the 64-bit range. Read digit by digit: Lua's own reading of a literal
--- past the range falls back to a rounded real.
local function literal_of(text: string): string?
  local sign, digits = text:match("^([+-]?)(%d+)$")
  if digits == nil then return nil end
  digits = (digits:gsub("^0+", ""))
  if digits == "" then return "0" end
  local limit = if sign == "-" then "9223372036854775808" else "9223372036854775807" end
  if #digits > 19 or (#digits == 19 and digits > limit) then return nil end
  return (if sign == "-" then "-" else "" end) .. digits
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
    local out: mut {string} = {}
    while Fuzz.more(src, #out, max) do
      local at = src:int(1, 10)
      out[#out + 1] = digits:sub(at, at)
    end
    return if #out == 0 then "0" else table.concat(out) end
  end
  local shape = src:int(0, 5)
  if shape == 0 then
    local edges = { 0, 1, -1, 1 << 53, (1 << 53) + 1, -((1 << 53) + 1), math.maxinteger,
      math.maxinteger - 1, math.mininteger, math.mininteger + 1 }
    -- Literals just past the 64-bit range, and signs and zeros in front.
    local past = { "-9223372036854775809", "9223372036854775808", "-9223372036854776832",
      "18446744073709551617", "-0", "+007", "-00" }
    if src:int(0, 3) == 0 then return Fuzz.pack({ "integer", Fuzz.pick(src, past) }) end
    local n = src:int(0, 1) == 0 and Fuzz.pick(src, edges) or src:int(math.mininteger, math.maxinteger)
    return Fuzz.pack({ "integer", tostring(n) })
  end
  if shape <= 2 then
    local text = (if src:int(0, 1) == 0 then "-" else "" end) .. run(15) .. "." .. run(15) ..
      "e" .. tostring(src:int(-290, 290))
    return Fuzz.pack({ "well", text })
  end
  local pieces = { "-", "+", ".", "e", "E", " ", "\0", "x",
    "308", "309", "324", "400", "-308", "-324", "-400" }
  local parts: mut {string} = {}
  while Fuzz.more(src, #parts, 6) do
    parts[#parts + 1] = src:int(0, 1) == 0 and run(30) or Fuzz.pick(src, pieces)
  end
  return Fuzz.pack({ "any", table.concat(parts) })
end

--- What `tointeger` and `toreal` make of a text: `toreal` answers what
--- `CAST` does when it answers, and a well-formed decimal converts;
--- `tointeger` answers an integer literal an integer holds as itself, and
--- NULL for anything else.
local function test_totype_reads_text_exactly(tmp: string)
  Fuzz.run({
    name = "sqlite totype text",
    dir = tmp,
    gen = gen_number,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local shape, text = unpacked(fields, 1), unpacked(fields, 2)
      local rows, trouble = Sqlite.text_rows(handle,
        "SELECT typeof(toreal(?1)), toreal(?1) = CAST(?1 AS REAL), toreal(?1) - toreal(?1) = 0.0, " ..
          "typeof(tointeger(?1)), tointeger(?1), " ..
          "typeof(tointeger(?2)), typeof(toreal(?2))",
        { { text = text }, { blob = text } })
      if rows == nil then return false, "totype failed its statement: " .. trouble end
      local row = first_row(rows)
      if row:text(1) == "real" then
        Fuzz.label("read as a real")
        if row:text(2) ~= "1" then return false, "toreal(" .. text .. ") is not CAST's" end
        if row:text(3) ~= "1" then return false, "toreal(" .. text .. ") is not finite" end
      elseif shape == "well" then
        return false, "toreal refused the decimal " .. text
      end
      -- An integer literal an integer holds converts to itself; anything
      -- else is NULL.
      local literal = literal_of(text)
      if literal ~= nil then
        Fuzz.label("read as an integer")
        if row:text(5) ~= literal then
          return false, "tointeger(" .. text .. ") answered " .. row:text(5)
        end
      elseif row:text(4) ~= "null" then
        return false, "tointeger(" .. text .. ") is no integer literal it holds, but answered " .. row:text(5)
      end
      if shape == "integer" and literal ~= nil then
        local n = assert(math.tointeger(literal))
        local exact = math.tointeger((n as number) + 0.0) == n
        if (row:text(1) == "real") ~= exact then
          return false, "toreal(" .. text .. ") is " .. row:text(1) .. " though a real holds it " ..
            (if exact then "exactly" else "inexactly" end)
        end
      end
      if row:text(6) ~= (if #text == 8 then "integer" else "null" end) then
        return false, "tointeger of a " .. tostring(#text) .. "-byte blob answered " .. row:text(6)
      end
      if #text ~= 8 and row:text(7) ~= "null" then
        return false, "toreal of a " .. tostring(#text) .. "-byte blob answered " .. row:text(7)
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
        local chars: mut {string} = {}
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
      local a, b, c = unpacked(fields, 1), unpacked(fields, 2), unpacked(fields, 3)
      -- Leading zeros on each run of digits leave a word equal to itself.
      local padded = (a:gsub("(%d+)", "00%1"))
      local function cmp(x: string, y: string): integer
        local rows = assert(Sqlite.text_rows(handle,
          "SELECT ?1 < ?2 COLLATE uint, ?1 = ?2 COLLATE uint, ?2 < ?1 COLLATE uint",
          { { text = x }, { text = y } }))
        local answer = first_row(rows)
        local less, equal, more = answer:text(1) == "1", answer:text(2) == "1", answer:text(3) == "1"
        local held = (if less then 1 else 0 end) + (if equal then 1 else 0 end) + (if more then 1 else 0 end)
        assert(held == 1, "exactly one of <, = and > holds, not " .. tostring(held))
        return if less then -1 elseif equal then 0 else 1 end
      end
      if cmp(a, padded) ~= 0 then return false, "zeros before digits changed the order" end
      local ab, bc, ac = cmp(a, b), cmp(b, c), cmp(a, c)
      if ab == bc and ac ~= ab then return false, "uint is not transitive" end
      if cmp(b, a) ~= -ab then return false, "uint is not antisymmetric" end
      Fuzz.label(if ab == 0 then "equal" else "ordered" end)
      return true, ""
    end,
    requires = { "ordered" },
    shares = { ordered = 0.5 },
  })
end

--- The ways a file can damage an R*Tree, each on a tree of one to three
--- levels: a depth header that lies, a child pointer sent anywhere, bytes
--- overwritten inside a node, a node cut short or run long, a
--- `_parent` or `_rowid` row moved or dropped, a wide root whose every
--- cell points back at itself over a `_node` table padded with rows the
--- tree never reaches, or at its own row of a node number 2^32 from the
--- next or chosen to collide under a fixed multiplicative hash, and a node
--- numbered 0 or -1 whose cells point at itself below a root whose depth
--- header lies. A check that may read a node more than once, keeps the
--- nodes it has read in a hash such numbers collide in, or lets numbers
--- below 1 past its set, takes minutes or more on one of them.
local DAMAGES <const> = { "depth", "child", "bytes", "length", "parent", "rowid", "wide", "below" }

--- A file holding an R*Tree damaged in one of those ways, written to
--- disk and opened again, so a damaged root reaches the table's connect
--- as well as its queries: querying, checking and writing the tree each
--- answer or fail their statement, in bounded time, and never take the
--- process down.
local function test_rtree_survives_damaged_trees(tmp: string)
  local Clock = require("cosmic.clock")
  local Fs = require("cosmic.fs")
  local path = tmp .. "/rtree.db"
  Fuzz.run({
    name = "sqlite rtree damaged trees",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return Fuzz.pack({ tostring(Fuzz.pick(src, { 1, 40, 600, 3000 })), Fuzz.pick(src, DAMAGES),
        tostring(src:int(0, 1 << 30)), Fuzz.bytes(src, 24) })
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local rows_n, damage = assert(math.tointeger(unpacked(fields, 1))), unpacked(fields, 2)
      local pick, bytes = assert(math.tointeger(unpacked(fields, 3))), unpacked(fields, 4)
      Fs.remove(path)
      local db = assert(Sqlite.open(path, { writable = true, create = true }))
      assert(db:exec("CREATE VIRTUAL TABLE b USING rtree_i32(id, x0, x1, y0, y1); BEGIN"))
      for i = 1, rows_n do
        local x, y = (i * 7919) % 2000 - 1000, (i * 104729) % 2000 - 1000
        assert(Sqlite.run(db, "INSERT INTO b VALUES (?1, ?2, ?2 + 9, ?3, ?3 + 9)",
          { { integer = i }, { integer = x }, { integer = y } }))
      end
      assert(db:exec("COMMIT"))
      local nodes = assert(Sqlite.rows(db, "SELECT nodeno, data FROM b_node ORDER BY nodeno"))
      local root = first_row(nodes):blob(2)
      if string.unpack(">I2", root) > 0 then Fuzz.label("a tree of more than one level") end
      local at = nodes[pick % #nodes + 1]
      assert(at, "pick selects one of the nodes")
      local nodeno, blob = at:integer(1), at:blob(2)
      local n = #blob
      local sql: string
      local values: {Sqlite.Value}
      if damage == "depth" then
        sql, values = "UPDATE b_node SET data = ?1 WHERE nodeno = 1",
          { { blob = string.pack(">I2", pick % 64) .. root:sub(3) } }
      elseif damage == "child" then
        -- A cell's first 8 bytes are its child's node number.
        local cells = math.max(string.unpack(">I2", blob, 3), 1)
        local cell = 5 + (pick % cells) * 24
        -- The root, the node itself, a node that does not exist, or none.
        local targets = { 1, nodeno, #nodes + 5, -1, 0 }
        local target = targets[pick % #targets + 1]
        assert(target, "pick selects one of the targets")
        local child = string.pack(">i8", target)
        sql, values = "UPDATE b_node SET data = ?1 WHERE nodeno = ?2",
          { { blob = blob:sub(1, cell - 1) .. child .. blob:sub(cell + 8) }, { integer = nodeno } }
      elseif damage == "bytes" then
        local start = pick % n + 1
        sql, values = "UPDATE b_node SET data = ?1 WHERE nodeno = ?2",
          { { blob = (blob:sub(1, start - 1) .. bytes .. blob:sub(start + #bytes)):sub(1, n) },
            { integer = nodeno } }
      elseif damage == "length" then
        local cut = pick % (2 * n)
        sql, values = "UPDATE b_node SET data = ?1 WHERE nodeno = ?2",
          { { blob = cut < n and blob:sub(1, cut) or blob .. string.rep("\0", cut - n) },
            { integer = nodeno } }
      elseif damage == "parent" then
        sql, values = if pick % 2 == 0 then "DELETE FROM b_parent WHERE nodeno = ?2" else
          "UPDATE b_parent SET parentnode = ?1 WHERE nodeno = ?2" end,
          { { integer = pick % 7 - 2 }, { integer = nodeno } }
      elseif damage == "wide" then
        local cells, padding = 4096 + pick % 61440, 1000 + (pick >> 16) % 19000
        -- The root's cells point at itself, or each at its own row: node
        -- numbers 2^32 apart, or multiples of the inverse of the golden
        -- ratio multiplier mod 2^64, which that hash sends to one slot.
        local spread = if #bytes > 0 then (assert(bytes:byte(1), "bytes is not empty")) % 3 else 0 end
        local apart = spread > 0
        local parts: mut {string} = {}
        assert(db:exec("BEGIN"))
        if apart then
          local j = 0
          while #parts < cells do
            j = j + 1
            local child = if spread == 1 then 2 + j * (1 << 32) else j * 0xF1DE83E19937733D end
            if child >= 2 then
              assert(Sqlite.run(db, "INSERT INTO b_node VALUES (?1, x'00000000')", { { integer = child } }))
              parts[#parts + 1] = string.pack(">i8", child) .. string.rep("\0", 16)
            end
          end
        else
          for i = 1, padding do
            assert(Sqlite.run(db, "INSERT INTO b_node VALUES (?1, x'00000000')",
              { { integer = #nodes + 100 + i } }))
          end
          parts[1] = string.rep(string.pack(">i8", 1) .. string.rep("\0", 16), cells)
        end
        assert(db:exec("COMMIT"))
        sql, values = "UPDATE b_node SET data = ?1 WHERE nodeno = 1",
          { { blob = string.pack(">I2>I2", if apart then 1 else 1 + pick % 3 end, cells) .. table.concat(parts) } }
      elseif damage == "below" then
        local below = -(pick % 2)
        local cell = string.pack(">i8", below) .. string.rep("\0", 16)
        assert(Sqlite.run(db, "INSERT INTO b_node VALUES (?1, ?2)",
          { { integer = below }, { blob = string.pack(">I2>I2", 0, 2) .. cell .. cell } }))
        local cells = math.max(string.unpack(">I2", root, 3), 2)
        sql, values = "UPDATE b_node SET data = ?1 WHERE nodeno = 1",
          { { blob = string.pack(">I2>I2", 40, cells) .. cell .. cell .. root:sub(4 + 2 * 24 + 1) } }
      else
        sql, values = if pick % 2 == 0 then "DELETE FROM b_rowid WHERE rowid = ?2" else
          "UPDATE b_rowid SET nodeno = ?1 WHERE rowid = ?2" end,
          { { integer = pick % 7 - 2 }, { integer = pick % rows_n + 1 } }
      end
      assert(Sqlite.run(db, sql, values))
      db:close()
      local start = Clock.monotonic_ns()
      local reopened = assert(Sqlite.open(path, { writable = true }))
      local refused, reported = false, false
      for _, q in ipairs({ "SELECT count(*) FROM b WHERE x1 >= 0 AND x0 <= 50 AND y1 >= 0 AND y0 <= 50",
          "SELECT count(*) FROM b", "SELECT rtreecheck('b')", "PRAGMA quick_check",
          "INSERT INTO b VALUES (100000, 1, 2, 1, 2)", "DELETE FROM b WHERE id = 1",
          "UPDATE b SET x1 = x1 + 1 WHERE id = 2" }) do
        local rows, trouble = Sqlite.text_rows(reopened, q)
        if rows == nil then
          refused = true
          if trouble == "" then return false, q .. " failed without saying why" end
        elseif q == "SELECT rtreecheck('b')" and first_row(rows):text(1) ~= "ok" then
          reported = true
        end
      end
      reopened:close()
      local spent = (Clock.monotonic_ns() - start) // 1000000
      if spent > 5000 then
        return false, damage .. " damage took " .. tostring(spent) .. " ms to read and check"
      end
      if reported then Fuzz.label("rtreecheck reported the damage") end
      if refused then Fuzz.label("a statement refused the damage") end
      Fuzz.label("damaged " .. damage)
      return true, ""
    end,
    requires = { "a tree of more than one level", "rtreecheck reported the damage",
      "damaged depth", "damaged child", "damaged wide", "damaged below" },
    shares = { ["a tree of more than one level"] = 0.3, ["rtreecheck reported the damage"] = 0.3 },
  })
end

--- The kinds of list a Value binds for carray().
local LISTS <const> = { "integers", "numbers", "texts", "blobs" }

local function gen_list(src: Fuzz.Source): string
  local kind = Fuzz.pick(src, LISTS)
  local fields: mut {string} = { kind }
  while Fuzz.more(src, #fields - 1, 40) do
    if kind == "integers" then
      fields[#fields + 1] = string.pack("<i8", src:int(math.mininteger, math.maxinteger))
    elseif kind == "numbers" then
      -- Any 8 bytes but a NaN's, which SQLite reads as NULL.
      local bits = string.pack("<i8", src:int(math.mininteger, math.maxinteger))
      local n = string.unpack("<d", bits)
      fields[#fields + 1] = n ~= n and string.pack("<d", math.huge) or bits
    elseif kind == "texts" then
      fields[#fields + 1] = (Fuzz.bytes(src, 12):gsub("%z", "\1"))
    else
      fields[#fields + 1] = Fuzz.bytes(src, 12)
    end
  end
  return Fuzz.pack(fields)
end

--- A list bound for carray() reads back as the same elements in order,
--- each of its kind's storage class.
local function test_carray_reads_back_a_bound_list(tmp: string)
  Fuzz.run({
    name = "sqlite carray round trip",
    dir = tmp,
    gen = gen_list,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local kind = unpacked(fields, 1)
      local list: Sqlite.Value
      local integers: mut {integer} = {}
      local numbers: mut {number} = {}
      local strings: mut {string} = {}
      for i = 2, #fields do
        if kind == "integers" then
          integers[#integers + 1] = (string.unpack("<i8", unpacked(fields, i)))
        elseif kind == "numbers" then
          numbers[#numbers + 1] = (string.unpack("<d", unpacked(fields, i)))
        else
          strings[#strings + 1] = unpacked(fields, i)
        end
      end
      if kind == "integers" then
        list = { integers = integers }
      elseif kind == "numbers" then
        list = { numbers = numbers }
      elseif kind == "texts" then
        list = { texts = strings }
      else
        list = { blobs = strings }
      end
      -- The plain and the captured helpers bind through different paths
      -- (cosmic/sqlite.tl's bind, core/sqlite.c's bind_values_result).
      local rows: Sqlite.Rows?
      local trouble = ""
      if #input % 2 == 0 then
        rows, trouble = Sqlite.rows(handle, "SELECT value FROM carray(?1)", { list })
        if rows ~= nil then Fuzz.label("bound in Lua") end
      else
        local result = Sqlite.rows_result(handle, "SELECT value FROM carray(?1)", { list })
        rows, trouble = result.rows, result.reason
        if rows ~= nil then Fuzz.label("bound in C") end
      end
      if rows == nil then return false, "carray failed its statement: " .. trouble end
      if #rows ~= #fields - 1 then
        return false, "carray read " .. tostring(#rows) .. " of " .. tostring((#fields - 1)) .. " " .. kind
      end
      for i, row in ipairs(rows) do
        local held = row:kind(1)
        local same: boolean
        if kind == "integers" then
          same = held == "integer" and row:integer(1) == integers[i]
        elseif kind == "numbers" then
          local expected = numbers[i]
          assert(expected, "the list holds element " .. tostring(i))
          same = held == "number" and row:number(1) == expected and
            (1 / row:number(1)) == (1 / expected)
        elseif kind == "texts" then
          same = held == "text" and row:text(1) == strings[i]
        else
          same = held == "blob" and row:blob(1) == strings[i]
        end
        if not same then
          return false, "carray read element " .. tostring(i) .. " of " .. kind .. " back changed"
        end
      end
      Fuzz.label(kind)
      if #rows == 0 then Fuzz.label("empty") end
      return true, ""
    end,
    requires = { "integers", "numbers", "texts", "blobs", "empty", "bound in Lua", "bound in C" },
  })
end
