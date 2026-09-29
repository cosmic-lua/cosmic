--- Fuzz properties for the text `cosmic time` reads (`cosmic.time`'s
--- `parse_duration` and `parse_input`): a duration that `format_duration`
--- writes parses back to itself; `parse_duration` is total -- any bytes,
--- and any mutation of a well-formed duration, answer a duration or a
--- failure and never raise, and a duration it accepts formats to text
--- that parses to the same one; and `parse_input` is total the same way,
--- over every form it reads, with a moment it accepts inside the range
--- and a moment `format_rfc3339` writes read back unchanged.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Time = require("cosmic.time")

local NS <const> = 1000000000

local ZONES <const> = { "UTC", "America/New_York", "Europe/Berlin", "Asia/Kolkata", "Australia/Lord_Howe" }

local function gen_number(src: Fuzz.Source): integer
  if src:int(0, 3) == 0 then return Fuzz.pick(src, { 0, 1, 999999999 }) end
  return src:int(0, 100000)
end

--- A duration as its own text: units in order, each present or not, from
--- the fields `gen_duration` draws.
local function gen_duration_text(src: Fuzz.Source): string
  local parts: {string} = {}
  if src:int(0, 4) == 0 then parts[1] = Fuzz.pick(src, { "-", "+" }) end
  for _, unit in ipairs({ "y", "mo", "d", "h", "m", "s" }) do
    if src:int(0, 1) == 0 then
      local n = tostring(gen_number(src))
      if unit == "s" and src:int(0, 2) == 0 then n = n .. "." .. tostring(src:int(0, 999999999)) end
      parts[#parts + 1] = n .. unit
    end
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
    nanoseconds = sign * ns }
  local text = Time.format_duration(d)
  Fuzz.label(sign < 0 and "negative" or "positive")
  local back, why = Time.parse_duration(text)
  if back == nil then return false, text .. " refused: " .. why end
  if back.years ~= d.years or back.months ~= d.months or back.days ~= d.days
      or back.nanoseconds ~= d.nanoseconds then
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
  if again.years ~= d.years or again.months ~= d.months or again.days ~= d.days
      or again.nanoseconds ~= d.nanoseconds then
    return false, "its own text read as another duration"
  end
  return true, ""
end

local SHAPES <const> = { "2026-03-08", "2026-03-08T02:30", "2026-03-08T02:30:15.5", "2026-03-08T02:30:15Z",
  "2026-03-08T02:30:15+05:30", "2026-03-08T02:30:15-04:00[America/New_York]", "@1700000000", "@-1.5", "@0" }

local function gen_input_text(src: Fuzz.Source): string
  local roll = src:int(0, 4)
  if roll == 0 then return Fuzz.bytes(src, 30) end
  if roll == 1 then
    return ("%04d-%02d-%02dT%02d:%02d:%02d"):format(src:int(1600, 2300), src:int(0, 13),
      src:int(0, 32), src:int(0, 24), src:int(0, 60), src:int(0, 61))
  end
  if roll == 2 then return "@" .. tostring(src:int(-99999999999, 99999999999)) end
  return Fuzz.mutate(src, Fuzz.pick(src, SHAPES), 2)
end

--- The input packed with the zone to read it in.
local function gen_input(src: Fuzz.Source): string
  return Fuzz.pack({ gen_input_text(src), Fuzz.pick(src, ZONES), Fuzz.pick(src,
    { "reject", "earlier", "later", "compatible" }) })
end

local function input_is_total(input: string): boolean, string
  local fields = Fuzz.unpack(input)
  local zone = assert(Time.zone(fields[2]))
  local ok, got, why = pcall(Time.parse_input, fields[1], zone,
    { disambiguation = fields[3] as Time.Disambiguation })
  if not ok then return false, "raised: " .. tostring(got) end
  if got == nil then
    if not why is string or why == "" then return false, "refused with no reason" end
    Fuzz.label("refused")
    return true, ""
  end
  Fuzz.label("read")
  local text = fields[1]
  if text:sub(1, 1) == "@" then Fuzz.label("epoch")
  elseif #text == 10 then Fuzz.label("date")
  elseif not text:find("[Zz+%-]", 11) then Fuzz.label("local")
  else Fuzz.label("rfc3339") end
  local moment = got as Time.Zoned
  -- What it read is a moment the calendar holds: one `format_rfc3339` can write.
  local _ = Time.format_rfc3339(moment.ns, { zone = zone })
  return true, ""
end

local function gen_moment(src: Fuzz.Source): string
  local s = src:int(-9000000000, 9000000000)
  local n = src:int(0, 2) == 0 and 0 or src:int(0, NS - 1)
  return string.pack("<i8i4", s, n) .. Fuzz.pick(src, ZONES)
end

local function moment_round_trips(input: string): boolean, string
  local s, n = string.unpack("<i8i4", input)
  local zone = assert(Time.zone(input:sub(13)))
  local ns = s * NS + n
  local text = Time.format_rfc3339(ns, { zone = zone, zone_name = true })
  local got, why = Time.parse_input(text, zone)
  if got == nil then return false, text .. " refused: " .. why end
  Fuzz.label("zoned text")
  if got.ns ~= ns then return false, text .. " read as another moment" end
  local epoch = ("@%d.%09d"):format(s, n)
  local by_epoch = Time.parse_input(epoch, zone)
  if s >= 0 then
    Fuzz.label("epoch text")
    if by_epoch == nil or by_epoch.ns ~= ns then return false, epoch .. " read as another moment" end
  end
  -- The local clock reading, read back in its zone, is the moment when the
  -- zone has no other with that reading.
  local c = Time.civil(ns, zone)
  local local_text = ("%04d-%02d-%02dT%02d:%02d:%02d"):format(c.year, c.month, c.day, c.hour, c.minute, c.second)
  local local_got = Time.parse_input(local_text, zone, { disambiguation = "earlier" })
  if local_got ~= nil and local_got.ns // NS == ns // NS then Fuzz.label("local text") end
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

local function test_reading_a_time_is_total(tmp: string)
  Fuzz.run({
    name = "input total",
    dir = tmp,
    gen = gen_input,
    check = input_is_total,
    requires = { "read", "refused", "epoch", "local", "date" },
    shares = { read = 0.1, refused = 0.1, epoch = 0.05 },
  })
end

local function test_a_moment_reads_back_from_its_text(tmp: string)
  Fuzz.run({
    name = "moment round trip",
    dir = tmp,
    gen = gen_moment,
    check = moment_round_trips,
    requires = { "zoned text", "epoch text", "local text" },
    shares = { ["zoned text"] = 0.5 },
  })
end
