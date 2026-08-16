--- Fuzz properties for cosmic.json: decode answers on any bytes at all,
--- the encode/decode round trip preserves the value, and a corrupted
--- encoding is still answered rather than thrown on. Every property runs
--- under _fuzz.driver, so a failure names the seed, the iteration and the
--- failing input in base64, and FUZZ_SEED replays it.

local check = require("cosmic.check")
local deep = require("cosmic.deep")
local driver = require("_fuzz.driver")
local json = require("cosmic.json")

--- The deepest nesting the value generator builds.
local MAX_DEPTH = 4
--- Generated integers are drawn from [-2^53, 2^53].
local INT_LIMIT = 9007199254740992
--- Bounds on a generated string's length and a generated table's width.
local MAX_STRING_LEN = 12
local MAX_TABLE_LEN = 4
--- The longest arbitrary input the totality property decodes.
local MAX_INPUT_LEN = 512

-- Two domain bounds below are deliberate, not laziness:
--
-- 1. floats are bounded below 2^53 because the C encoder serializes a
--    float in ~[1e17, 2^63) to an integer-shaped token the decoder
--    integer-parses -- a real defect, filed as whilp/cosmopolitan#265;
--    when its fix arrives via a cosmos pin bump, this bound comes off.
-- 2. strings stay ASCII because a byte above 0x7f encodes as \u00xx and
--    decodes as that codepoint's two-byte UTF-8 form -- JSON strings
--    carry text, not arbitrary bytes; callers with binary use
--    cosmic.codec first. This is the module's contract, not a defect.
local STRING_ALPHABET = "abcXYZ019 _-{}[]:,\0\"\\/\t\n\r\1\31\127"

--- Draw one character from the alphabet.
--- @return string A single byte
local function random_char(): string
  local i = math.random(1, #STRING_ALPHABET)
  return STRING_ALPHABET:sub(i, i)
end

--- Draw a string of alphabet characters.
--- @return string A string of 0 to MAX_STRING_LEN characters
local function random_string(): string
  local out: {string} = {}
  for i = 1, math.random(0, MAX_STRING_LEN) do
    out[i] = random_char()
  end
  return table.concat(out)
end

--- Draw a finite float, spread across magnitudes but kept below 2^53
--- (see the domain-bounds comment above). NaN and infinity stay out of
--- the generator: encode rejects them by contract, so they belong to
--- the mutation property rather than the round trip.
--- @return number A finite float with |v| < 2^53
local function random_float(): number
  return (math.random() * 2.0 - 1.0) * 10.0 ^ math.random(-30, 15)
end

--- Draw a random JSON-representable value. depth is the level being
--- built; tables stop being offered at MAX_DEPTH, so nesting stops
--- there. Nothing drawn is nil, so no array gets a hole and no object
--- key vanishes — both are encode errors rather than round-trip losses.
--- @param depth integer The nesting level of the value being built
--- @return any The generated value
local function random_value(depth: integer): any
  local kind = math.random(1, depth < MAX_DEPTH and 6 or 4)
  if kind == 1 then
    return math.random(0, 1) == 1
  elseif kind == 2 then
    return math.random(-INT_LIMIT, INT_LIMIT)
  elseif kind == 3 then
    return random_float()
  elseif kind == 4 then
    return random_string()
  elseif kind == 5 then
    local items: {any} = {}
    for i = 1, math.random(0, MAX_TABLE_LEN) do
      items[i] = random_value(depth + 1)
    end
    return items
  end
  local fields: {string: any} = {}
  for _ = 1, math.random(0, MAX_TABLE_LEN) do
    fields[random_string()] = random_value(depth + 1)
  end
  return fields
end

--- The value behind the encoding the generator produced last. The driver
--- hands a property only the generated string, so the round trip reads
--- the value that string was built from here.
local generated: any

--- Generate one valid encoding, recording the value it came from.
--- @return string The encoding of a fresh random value
local function generate_encoding(): string
  local value = random_value(1)
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
      gen = function(): string
        return driver.bytes(MAX_INPUT_LEN)
      end,
      check = decodes_or_explains,
    })
  check.truthy(ok, msg)
end
test_decode_totality()

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
        return true
      end,
    })
  check.truthy(ok, msg)
end
test_round_trip()

local function test_mutation_survival()
  local ok, msg = driver.run({
      name = "mutation_survival",
      gen = function(): string
        return driver.mutate(generate_encoding(), math.random(1, 8))
      end,
      check = decodes_or_explains,
    })
  check.truthy(ok, msg)
end
test_mutation_survival()
