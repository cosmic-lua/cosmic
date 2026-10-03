--- Fuzz properties for [`cosmic.time`]'s duration text: a duration that
--- `format_duration` writes parses back to itself, and `parse_duration`
--- is total -- any bytes, and any mutation of a well-formed duration,
--- answer a duration or a failure and never raise, and a duration it
--- accepts formats to text that parses to the same one. `FUZZ_SEED` and
--- `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Time = require("cosmic.time")

local NS <const> = 1000000000

local function gen_number(src: Fuzz.Source): integer
  if src:int(0, 3) == 0 then return Fuzz.pick(src, { 0, 1, 999999999 }) end
  return src:int(0, 100000)
end

--- A duration as its own text: units in order, each present or not, from
--- the fields `gen_duration` draws.
local function gen_duration_text(src: Fuzz.Source): string
  local parts: {string} = {}
  if src:int(0, 4) == 0 then parts[1] = Fuzz.pick(src, { "-", "+" }) end
  local units = { "y", "mo", "d", "h", "m", "s" }
  -- Each unit drawn after a `more`, so shrinking can drop one.
  local at = 0
  while at < 6 and Fuzz.more(src, #parts, 6) do
    at = at + src:int(1, 6 - at)
    local n = tostring(gen_number(src))
    if units[at] == "s" and src:int(0, 2) == 0 then
      n = n .. "." .. tostring(src:int(0, 999999999))
    end
    parts[#parts + 1] = n .. units[at]
  end
  return table.concat(parts)
end

local function gen_duration_input(src: Fuzz.Source): string
  local text = gen_duration_text(src)
  local roll = src:int(0, 3)
  if roll == 0 then return Fuzz.mutate(src, text, 2) end
  if roll == 1 then return Fuzz.bytes(src, 12) end
  return text
end

--- A duration as fields, packed: a sign and each part.
local function gen_fields(src: Fuzz.Source): string
  return string.pack("<i1i4i4i4i8", src:int(-1, 1), src:int(0, 120000), src:int(0, 120000),
    src:int(0, 3650000), src:int(0, 1000000 * NS))
end

local function fields_round_trip(input: string): boolean, string
  local sign, years, months, days, ns = string.unpack("<i1i4i4i4i8", input)
  local d: Time.Duration = { years = sign * years, months = sign * months, days = sign * days,
    ns = sign * ns }
  local text = Time.format_duration(d)
  Fuzz.label(sign < 0 and "negative" or "positive")
  local back, why = Time.parse_duration(text)
  if back == nil then return false, text .. " refused: " .. why end
  if back.years ~= d.years or back.months ~= d.months or back.days ~= d.days or
      back.ns ~= d.ns then
    return false, text .. " read back as another duration"
  end
  return true, ""
end

local function duration_is_total(input: string): boolean, string
  local ok, got, why = pcall(Time.parse_duration, input)
  if not ok then return false, "raised: " .. tostring(got) end
  if got == nil then
    if not why is string or why == "" then return false, "refused with no reason" end
    Fuzz.label("refused")
    return true, ""
  end
  Fuzz.label("read")
  local d = got as Time.Duration
  local again, again_why = Time.parse_duration(Time.format_duration(d))
  if again == nil then return false, "its own text refused: " .. again_why end
  if again.years ~= d.years or again.months ~= d.months or again.days ~= d.days or
      again.ns ~= d.ns then
    return false, "its own text read as another duration"
  end
  return true, ""
end

local function test_a_duration_writes_and_reads_back(tmp: string)
  Fuzz.run({
    name = "duration round trip",
    dir = tmp,
    gen = gen_fields,
    check = fields_round_trip,
    requires = { "negative", "positive" },
    shares = { negative = 0.1 },
  })
end

local function test_reading_a_duration_is_total(tmp: string)
  Fuzz.run({
    name = "duration total",
    dir = tmp,
    gen = gen_duration_input,
    check = duration_is_total,
    requires = { "read", "refused" },
    shares = { read = 0.1, refused = 0.1 },
  })
end
