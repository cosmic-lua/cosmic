--- Fuzz properties for cosmic.json: decode answers on any bytes at all,
--- the encode/decode round trip preserves the value, and a corrupted
--- encoding is still answered rather than thrown on. Every property runs
--- under _fuzz.driver, so a failure names the seed, the iteration and the
--- failing input in base64, and FUZZ_SEED replays it.
--- env: FUZZ_SEED FUZZ_ITERS

local check = require("cosmic.check")
local deep = require("cosmic.deep")
local driver = require("_fuzz.driver")
local json = require("cosmic.json")
local source = require("_fuzz.source")

--- The deepest nesting the value generator builds.
local MAX_DEPTH = 4
--- Generated integers are drawn from [-2^53, 2^53].
local INT_LIMIT = 9007199254740992
--- Bounds on a generated string's length and a generated table's width.
local MAX_STRING_LEN = 12
local MAX_TABLE_LEN = 4
--- The longest arbitrary input the totality property decodes.
local MAX_INPUT_LEN = 512

-- One domain bound below is deliberate, not laziness: strings stay ASCII
-- because a byte above 0x7f encodes as \u00xx and decodes as that
-- codepoint's two-byte UTF-8 form -- JSON strings carry text, not
-- arbitrary bytes; callers with binary use cosmic.codec first. This is
-- the module's contract, not a defect.
local STRING_ALPHABET = "abcXYZ019 _-{}[]:,\0\"\\/\t\n\r\1\31\127"

--- Draw one character from the alphabet.
--- @param src source.Recorder The source to draw from
--- @return string A single byte
local function random_char(src: source.Recorder): string
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

--- Draw a finite float, spread across the whole finite double range. An
--- integral float far above 2^53 is deliberately in the domain: the
--- encoder always writes a float with a `.` or an exponent, so the
--- decoder takes its double path and the value AND its float-ness come
--- back. A mantissa below 1 keeps the product finite at both ends. NaN
--- and infinity stay out of the generator: encode rejects them by
--- contract, so they belong to the mutation property rather than the
--- round trip.
--- @param src source.Recorder The source to draw from
--- @return number A finite float
local function random_float(src: source.Recorder): number
  return (src:float() * 2.0 - 1.0) * 10.0 ^ src:int(-300, 300)
end

--- Draw a random JSON-representable value. depth is the level being
--- built; tables stop being offered at MAX_DEPTH, so nesting stops
--- there. Nothing drawn is nil, so no array gets a hole and no object
--- key vanishes — both are encode errors rather than round-trip losses.
--- @param src source.Recorder The source to draw from
--- @param depth integer The nesting level of the value being built
--- @return any The generated value
local function random_value(src: source.Recorder, depth: integer): any
  local kind = src:int(1, depth < MAX_DEPTH and 6 or 4)
  if kind == 1 then
    return src:int(0, 1) == 1
  elseif kind == 2 then
    return src:int(-INT_LIMIT, INT_LIMIT)
  elseif kind == 3 then
    return random_float(src)
  elseif kind == 4 then
    return random_string(src)
  elseif kind == 5 then
    local items: {any} = {}
    for i = 1, src:int(0, MAX_TABLE_LEN) do
      items[i] = random_value(src, depth + 1)
    end
    return items
  end
  local fields: {string: any} = {}
  for _ = 1, src:int(0, MAX_TABLE_LEN) do
    fields[random_string(src)] = random_value(src, depth + 1)
  end
  return fields
end

--- The value behind the encoding the generator produced last. The driver
--- hands a property only the generated string, so the round trip reads
--- the value that string was built from here.
local generated: any

--- Generate one valid encoding, recording the value it came from.
--- @param src source.Recorder The source to draw from
--- @return string The encoding of a fresh random value
local function generate_encoding(src: source.Recorder): string
  local value = random_value(src, 1)
  generated = value
  return check.must(json.encode(value))
end

--- Decode must always answer: a value, or nil with a non-empty message
--- saying why. Throwing is the driver's business — it reports one as a
--- failure — so this only judges the returns.
--- @param input string The bytes to decode
--- @return boolean True when decode answered
--- @return string What decode returned instead
local function decodes_or_explains(input: string): boolean, string
  local value, err = json.decode(input)
  if err then
    if #err == 0 then
      return false, "decode failed with an empty message"
    end
    return true
  end
  if value == nil then
    return false, "decode returned nil with no message"
  end
  return true
end

local function test_decode_totality()
  local ok, msg = driver.run({
      name = "decode_totality",
      gen = function(src: source.Recorder): string
        return driver.bytes(src, MAX_INPUT_LEN)
      end,
      check = decodes_or_explains,
    })
  check.truthy(ok, msg)
end
test_decode_totality()

--- Compare two values for numeric TYPE, which deep.equal cannot see:
--- 5.0 equals 5 in Lua, so a decoder that handed back an integer where a
--- float was encoded would pass the value comparison silently. Walks the
--- two in parallel over the expected side's keys; deep.equal has already
--- established that the shapes agree.
--- @param decoded any The value decode returned
--- @param expected any The value it was encoded from
--- @return boolean Whether every number matches in math.type
--- @return string Which pair did not
local function number_types_match(decoded: any, expected: any): boolean, string
  if expected is number and decoded is number then
    local want, got = math.type(expected), math.type(decoded)
    if want ~= got then
      return false, "decoded a " .. tostring(want) .. " as a " .. tostring(got)
    end
    return true
  end
  if expected is {any: any} and decoded is {any: any} then
    for key, value in pairs(expected) do
      local ok, why = number_types_match(decoded[key], value)
      if not ok then
        return false, why
      end
    end
  end
  return true
end

local function test_round_trip()
  local ok, msg = driver.run({
      name = "round_trip",
      gen = generate_encoding,
      check = function(input: string): boolean, string
        local expected = generated
        local decoded, err = json.decode(input)
        if err then
          return false, "decode failed: " .. err
        end
        if not deep.equal(decoded, expected) then
          local shown = json.encode(decoded)
          return false, "decoded value differs: " .. tostring(shown)
        end
        local same, why = number_types_match(decoded, expected)
        if not same then
          return false, "decoded number type differs: " .. why
        end
        return true
      end,
    })
  check.truthy(ok, msg)
end
test_round_trip()

local function test_mutation_survival()
  local ok, msg = driver.run({
      name = "mutation_survival",
      gen = function(src: source.Recorder): string
        return driver.mutate(src, generate_encoding(src), src:int(1, 8))
      end,
      check = decodes_or_explains,
    })
  check.truthy(ok, msg)
end
test_mutation_survival()
