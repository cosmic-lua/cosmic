--- Fuzz properties for cosmic.literal: parse answers on any bytes at
--- all, the format/parse round trip preserves the value in either
--- layout, format is total over a domain that includes everything it
--- must refuse, and a corrupted literal is still answered rather than
--- thrown on. Every property runs under _fuzz.driver, so a failure
--- names the seed, the iteration and the failing input in base64, and
--- FUZZ_SEED replays it.
--- env: FUZZ_SEED FUZZ_ITERS

local check = require("cosmic.check")
local deep = require("cosmic.deep")
local driver = require("_fuzz.driver")
local literal = require("cosmic.literal")
local source = require("_fuzz.source")

--- The deepest nesting the value generators build.
local MAX_DEPTH = 4
--- Bounds on a generated string's length and a generated table's width.
local MAX_STRING_LEN = 12
local MAX_TABLE_LEN = 4
--- The longest arbitrary input the totality property parses.
local MAX_INPUT_LEN = 512
--- How long a cycle's chain of tables may be before it closes.
local MAX_CYCLE_LEN = 3
--- Edits a mutated source receives.
local MAX_EDITS = 8

--- Both layouts `format` writes. They admit the same values and refuse
--- the same ones, so every property that formats loops over both
--- rather than duplicating itself.
local LAYOUTS: {string} = {"pin", "compact"}

-- Three domain bounds below are deliberate, not laziness. One of them
-- (1) is a known defect this file found on one of its first runs and
-- must not keep re-reporting; it names the board item that owns it
-- and comes off when that item lands.
--
-- 1. generated values nest at most MAX_DEPTH tables, far below the
--    reader's 32-table cap. That is not only to keep inputs small: at
--    depth 33 exactly, a flat innermost table is rendered inline by a
--    path that never checks the cap, so `format` writes source `parse`
--    then refuses -- a real round-trip break, filed as board item
--    3ICDKhO3. Generating it would report a failure already known
--    rather than a new one; when that item lands, this bound is what
--    comes off.
-- 2. numbers stay finite. NaN and the infinities have no spelling this
--    grammar admits, so `format` refuses them by name -- the module's
--    contract, not a defect. They belong to the format-totality
--    property, whose domain is widened to include exactly the values
--    that must be refused, and they are drawn there.
-- 3. a generated cycle is a chain of tables with one table child each,
--    never a cycle inside a fan-out. `format` detects a cycle by
--    running out of depth, so a cyclic table that also branches costs
--    exponential work before it is refused -- a property of the
--    refusal mechanism, not a bug in it. The chain reaches the cap in
--    32 linear steps and gets the same refusal.
--
-- Strings are drawn from an alphabet of the bytes that make a writer
-- and a reader disagree -- quotes, the backslash, the newline, the
-- tab, NUL, bytes above 0x7f, and the grammar's own punctuation --
-- with an occasional uniform byte mixed in, so the draw is
-- concentrated rather than bounded.
local STRING_ALPHABET =
"abcXYZ019 _-{}[]=,;.:\0\"'\\\t\n\r\1\31\127\128\200\255"

--- Integers whose spelling is where a writer and a reader part ways:
--- the ends of the 64-bit range, the byte and word boundaries, and the
--- values a sign or a width bug lands on.
local INT_EDGES: {integer} = {
  0, 1, -1, 255, 256, -256, 65535, 2147483647, -2147483648,
  4294967296, 9007199254740992, -9007199254740992,
  math.maxinteger, math.mininteger,
}

--- Floats whose spelling is where a writer and a reader part ways: the
--- signed zeroes, the subnormal floor, the smallest normal, the ends
--- of the exponent range, and values with no exact decimal form.
local FLOAT_EDGES: {number} = {
  0.0, -0.0, 0.5, -0.5, 0.1, 1.0 / 3.0,
  5e-324, 2.2250738585072014e-308, 1e308, -1e308,
  9007199254740992.0, -9007199254740993.0,
}

--- Draw one character: usually from the alphabet, occasionally any
--- byte at all, so the concentration on interesting bytes does not
--- become a ceiling on which bytes are seen.
--- @param src source.Recorder The source to draw from
--- @return string A single byte
local function random_char(src: source.Recorder): string
  if src:int(1, 8) == 1 then
    return string.char(src:int(0, 255))
  end
  local i = src:int(1, #STRING_ALPHABET)
  return STRING_ALPHABET:sub(i, i)
end

--- Draw a string of alphabet characters.
--- @param src source.Recorder The source to draw from
--- @return string A string of 0 to MAX_STRING_LEN characters
local function random_string(src: source.Recorder): string
  local out: {string} = {}
  for i = 1, src:int(0, MAX_STRING_LEN) do
    out[i] = random_char(src)
  end
  return table.concat(out)
end

--- Draw an integer: an edge value a third of the time, otherwise
--- uniform across a band wide enough to spread over magnitudes.
--- @param src source.Recorder The source to draw from
--- @return integer The generated integer
local function random_integer(src: source.Recorder): integer
  if src:int(1, 3) == 1 then
    return INT_EDGES[src:int(1, #INT_EDGES)]
  end
  return src:int(-1099511627776, 1099511627776)
end

--- Draw a finite float: an edge value a third of the time, otherwise
--- a mantissa in [-1, 1) scaled across the exponent range. Nothing
--- drawn here is NaN or an infinity (see the domain-bounds comment).
--- @param src source.Recorder The source to draw from
--- @return number The generated float
local function random_float(src: source.Recorder): number
  if src:int(1, 3) == 1 then
    return FLOAT_EDGES[src:int(1, #FLOAT_EDGES)]
  end
  return (src:float() * 2.0 - 1.0) * 10.0 ^ src:int(-300, 300)
end

--- Draw a scalar the grammar admits: a string, a boolean, an integer
--- or a finite float.
--- @param src source.Recorder The source to draw from
--- @return any The generated scalar
local function random_scalar(src: source.Recorder): any
  local kind = src:int(1, 4)
  if kind == 1 then
    return random_string(src)
  elseif kind == 2 then
    return src:int(0, 1) == 1
  elseif kind == 3 then
    return random_integer(src)
  end
  return random_float(src)
end

--- Draw a table inside the grammar: string keys, scalar or table
--- values, nesting stopping at MAX_DEPTH. depth is the level being
--- built, so the root is 1.
--- @param src source.Recorder The source to draw from
--- @param depth integer The nesting level of the table being built
--- @return {string: any} The generated table
local function random_table(src: source.Recorder, depth: integer): {string: any}
  local fields: {string: any} = {}
  for _ = 1, src:int(0, MAX_TABLE_LEN) do
    local key = random_string(src)
    if depth < MAX_DEPTH and src:int(1, 3) == 1 then
      fields[key] = random_table(src, depth + 1)
    else
      fields[key] = random_scalar(src)
    end
  end
  return fields
end

--- Draw a key from outside the grammar: a number or a boolean, both of
--- which `format` must refuse by key path.
---
--- A TABLE key is deliberately not drawn. The refusal names the key
--- with `tostring`, so a table key would put its address in the
--- message this file reports as the failing input, and the same seed
--- would report different bytes in every process. The writer refuses
--- every non-string key the same way, so nothing is lost by keeping
--- the report reproducible.
--- @param src source.Recorder The source to draw from
--- @return any The generated key
local function foreign_key(src: source.Recorder): any
  local kind = src:int(1, 3)
  if kind == 1 then
    return random_integer(src)
  elseif kind == 2 then
    return src:int(0, 1) == 1
  end
  return random_float(src)
end

--- Build a cyclic value: a chain of tables, each holding one table,
--- the last pointing back at the head. One table child per link, so
--- reaching the depth cap that detects the cycle is linear work (see
--- the domain-bounds comment).
--- @param src source.Recorder The source to draw from
--- @return {any: any} The head of the cycle
local function cyclic_chain(src: source.Recorder): {any: any}
  local head: {any: any} = {}
  local last = head
  for _ = 1, src:int(0, MAX_CYCLE_LEN) do
    local next_link: {any: any} = {}
    last["next"] = next_link
    last = next_link
  end
  last["loop"] = head
  return head
end

--- Draw a value from outside the grammar: the ones a writer must
--- refuse rather than spell. A function and a coroutine are the two
--- types with no literal form; NaN and the infinities are the numbers
--- with none.
--- @param src source.Recorder The source to draw from
--- @return any The generated value
local function foreign_value(src: source.Recorder): any
  local kind = src:int(1, 5)
  if kind == 1 then
    return print
  elseif kind == 2 then
    return coroutine.create(function() end)
  elseif kind == 3 then
    return 0.0 / 0.0
  elseif kind == 4 then
    return math.huge
  end
  return -math.huge
end

--- Draw a table from the widened domain: mostly inside the grammar,
--- with foreign keys, foreign values and cycles mixed in, so `format`
--- meets the values it exists to refuse as often as the ones it
--- writes.
--- @param src source.Recorder The source to draw from
--- @param depth integer The nesting level of the table being built
--- @return {any: any} The generated table
local function widened_table(src: source.Recorder, depth: integer): {any: any}
  local fields: {any: any} = {}
  for _ = 1, src:int(0, MAX_TABLE_LEN) do
    local key: any = random_string(src)
    if src:int(1, 8) == 1 then
      key = foreign_key(src)
    end
    local roll = src:int(1, 10)
    if roll == 1 then
      fields[key] = foreign_value(src)
    elseif roll == 2 then
      fields[key] = cyclic_chain(src)
    elseif roll <= 4 and depth < MAX_DEPTH then
      fields[key] = widened_table(src, depth + 1)
    else
      fields[key] = random_scalar(src)
    end
  end
  return fields
end

--- Draw a root value from the widened domain. Usually a table, but
--- sometimes a scalar or a function, which `format` must refuse
--- because a literal file returns a table and nothing else.
--- @param src source.Recorder The source to draw from
--- @return any The generated value
local function widened_root(src: source.Recorder): any
  local kind = src:int(1, 8)
  if kind == 1 then
    return random_scalar(src)
  elseif kind == 2 then
    return foreign_value(src)
  end
  return widened_table(src, 1)
end

--- The value behind the source the generator produced last. The driver
--- hands a property only the generated string, so a property that
--- judges the value reads it from here.
local generated: any

--- Generate one valid literal source, recording the value and the
--- layout it came from.
--- @param src source.Recorder The source to draw from
--- @return string The formatted source of a fresh random value
local function generate_source(src: source.Recorder): string
  local value = random_table(src, 1)
  generated = value
  local layout = LAYOUTS[src:int(1, #LAYOUTS)]
  return check.must(literal.format(value, {layout = layout}))
end

--- The widened value behind the source the widened generator produced
--- last, read back by the format-totality property.
local widened: any

--- Generate one widened value, returning what `format` said about it
--- so the reported input describes the case rather than a placeholder.
--- @param src source.Recorder The source to draw from
--- @return string The formatted source, or the refusal that replaced it
local function generate_widened(src: source.Recorder): string
  local value = widened_root(src)
  widened = value
  local text, err = literal.format(value)
  return text or ("refused: " .. tostring(err))
end

--- Splice a run of bytes taken from one source into another, at a
--- random position. Byte edits alone rarely produce a fragment that
--- lexes; a spliced run of real literal text does, which is how the
--- mutation property reaches the parser's deeper refusals.
--- @param src source.Recorder The source to draw from
--- @param base string The source to splice into
--- @param donor string The source to take a run from
--- @return string The spliced source
local function splice(src: source.Recorder, base: string, donor: string): string
  if #donor == 0 then
    return base
  end
  local from = src:int(1, #donor)
  local to = src:int(from, #donor)
  local at = src:int(1, #base + 1)
  return base:sub(1, at - 1) .. donor:sub(from, to) .. base:sub(at)
end

--- Parse must always answer: a table, or nil with a non-empty message
--- saying why. Throwing is the driver's business — it reports one as a
--- failure — so this only judges the returns.
--- @param input string The bytes to parse
--- @return boolean True when parse answered
--- @return string What parse returned instead
local function parses_or_explains(input: string): boolean, string
  local value, err = literal.parse(input)
  if err then
    if #err == 0 then
      return false, "parse failed with an empty message"
    end
    return true
  end
  if value == nil then
    return false, "parse returned nil with no message"
  end
  return true
end

local function test_parse_totality()
  local ok, msg = driver.run({
      name = "parse_totality",
      gen = function(src: source.Recorder): string
        return driver.bytes(src, MAX_INPUT_LEN)
      end,
      check = parses_or_explains,
    })
  check.truthy(ok, msg)
end
test_parse_totality()

local function test_round_trip()
  local ok, msg = driver.run({
      name = "round_trip",
      gen = generate_source,
      check = function(input: string): boolean, string
        local expected = generated
        local parsed, err = literal.parse(input)
        if not parsed then
          return false, "parse refused what format wrote: " .. tostring(err)
        end
        if not deep.equal(parsed, expected) then
          return false, "parsed value differs from the value formatted"
        end
        return true
      end,
    })
  check.truthy(ok, msg)
end
test_round_trip()

-- The property that catches a writer emitting what its own reader
-- cannot read. Over a domain that includes functions, coroutines,
-- cycles, foreign keys, NaN and the infinities, `format` must either
-- refuse with a message or write source that reads back as the value
-- it was given -- in either layout, which admit the same values.
local function test_format_totality()
  local ok, msg = driver.run({
      name = "format_totality",
      gen = generate_widened,
      check = function(_input: string): boolean, string
        local value = widened
        for _, layout in ipairs(LAYOUTS) do
          local text, err = literal.format(value, {layout = layout})
          if not text then
            if err == nil or #err == 0 then
              return false, layout .. ": refused with an empty message"
            end
          else
            local parsed, perr = literal.parse(text)
            if not parsed then
              return false, layout .. ": wrote source parse refuses: " ..
              tostring(perr)
            end
            if not deep.equal(parsed, value) then
              return false, layout .. ": round trip changed the value"
            end
          end
        end
        return true
      end,
    })
  check.truthy(ok, msg)
end
test_format_totality()

local function test_mutation_survival()
  local ok, msg = driver.run({
      name = "mutation_survival",
      gen = function(src: source.Recorder): string
        local base = generate_source(src)
        if src:int(1, 4) == 1 then
          base = splice(src, base, generate_source(src))
        end
        return driver.mutate(src, base, src:int(1, MAX_EDITS))
      end,
      check = parses_or_explains,
    })
  check.truthy(ok, msg)
end
test_mutation_survival()
