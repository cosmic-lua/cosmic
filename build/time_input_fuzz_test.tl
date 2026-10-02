--- Fuzz properties for the text `cosmic time` reads (build/time.tl's
--- `parse_input`): it is total -- any bytes, and any mutation of a
--- well-formed time, answer a moment or a failure and never raise, over
--- every form it reads, with a moment it accepts inside the range -- and a
--- moment `format_rfc3339` writes reads back unchanged. `FUZZ_SEED` and
--- `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Time = require("cosmic.time")
local time_verb = require("build.time")

local NS <const> = 1000000000

local ZONES <const> = { "UTC", "America/New_York", "Europe/Berlin", "Asia/Kolkata", "Australia/Lord_Howe" }

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
  local ok, got, why = pcall(time_verb.parse_input, fields[1], zone, fields[3] as Time.Disambiguation)
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
  local _ = Time.format_rfc3339(moment.ns, zone)
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
  local text = Time.format_rfc3339(ns, zone, { zone_name = true })
  local got, why = time_verb.parse_input(text, zone)
  if got == nil then return false, text .. " refused: " .. why end
  Fuzz.label("zoned text")
  if got.ns ~= ns then return false, text .. " read as another moment" end
  local epoch = ("@%d.%09d"):format(s, n)
  local by_epoch = time_verb.parse_input(epoch, zone)
  if s >= 0 then
    Fuzz.label("epoch text")
    if by_epoch == nil or by_epoch.ns ~= ns then return false, epoch .. " read as another moment" end
  end
  return true, ""
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
    requires = { "zoned text", "epoch text" },
    shares = { ["zoned text"] = 0.5 },
  })
end
