--- Fuzz properties for `cosmic.time`'s POSIX TZ string reader, which
--- reads `TZ` and every TZif file's footer: `zone_from_posix` is total
--- -- whatever text it is handed, it answers a zone or a failure and
--- never raises, and a zone it answers names every moment without
--- raising -- and a string written from drawn offsets and rules reads
--- back as a zone that is only ever in standard or daylight saving
--- time, and reads every local time it names back as the moment it came
--- from. Inputs are mutations of the footers of the zones the binary
--- carries and of strings written here, and arbitrary bytes.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Store = require("cosmic.store")
local Time = require("cosmic.time")

local NS <const> = 1000000000

--- The footer of each zone the binary carries: every TZ string zic
--- writes.
local samples: {string} = {}
do
  local seen: {string:boolean} = {}
  for _, name in ipairs({ "America/New_York", "Europe/London", "Australia/Sydney", "Australia/Lord_Howe",
      "Asia/Kolkata", "Europe/Dublin", "America/Godthab", "Asia/Jerusalem", "Pacific/Chatham",
      "America/Santiago", "Africa/Casablanca", "Antarctica/Troll", "America/Scoresbysund" }) do
    local data = assert(Store.zoneinfo(name))
    local footer = data:match("\n([^\n]*)\n$")
    if footer ~= nil and footer ~= "" and not seen[footer] then
      seen[footer] = true
      samples[#samples + 1] = footer
    end
  end
  for _, extra in ipairs({ "EST5EDT", "EST5EDT4,0/0,J365/25", "AAA0BBB,J60/0,300/167",
      "AAA-24BBB24,M3.2.0/-167,M11.1.0/167", "<+0330>-3:30" }) do
    samples[#samples + 1] = extra
  end
end

--- Moments every zone read is asked about.
local PROBES <const> = { math.mininteger, math.maxinteger, 0, -1, 1790309361 * NS,
  1772953200 * NS, 1793512800 * NS, -2208988800 * NS, 4107542400 * NS }

local function total(tz: string): boolean, string
  local ok, zone, why = pcall(Time.zone_from_posix, tz)
  if not ok then return false, "zone_from_posix raised: " .. tostring(zone) end
  if zone == nil then
    Fuzz.label("refused")
    if why == "" then return false, "refused without a reason" end
    return true, ""
  end
  Fuzz.label("read")
  for _, ns in ipairs(PROBES) do
    local civil_ok, c = pcall(Time.civil, ns, zone)
    if not civil_ok then return false, ("civil(%d) raised: %s"):format(ns, tostring(c)) end
    if c.dst then Fuzz.label("daylight saving time") end
    local from_ok, back = pcall(Time.from_civil, c, zone)
    if not from_ok then return false, ("from_civil of civil(%d) raised: %s"):format(ns, tostring(back)) end
    if back ~= ns then
      return false, ("%s: civil(%d) read back as %s"):format(tz, ns, tostring(back))
    end
  end
  return true, ""
end

local function test_reading_a_tz_string_is_total(tmp: string)
  Fuzz.run({
    name = "posix tz read total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      if src:int(0, 5) == 0 then return Fuzz.bytes(src, 40) end
      return Fuzz.mutate(src, Fuzz.pick(src, samples), 4)
    end,
    check = total,
    requires = { "read", "refused", "daylight saving time" },
  })
end

--- `seconds` as a POSIX time, `[-]h[:mm[:ss]]`, west of UTC for an
--- offset.
local function hms(seconds: integer): string
  local a = math.abs(seconds)
  local text = ("%s%d"):format(seconds < 0 and "-" or "", a // 3600)
  if a % 3600 ~= 0 then
    text = text .. (":%02d"):format(a % 3600 // 60)
    if a % 60 ~= 0 then text = text .. (":%02d"):format(a % 60) end
  end
  return text
end

--- One of a rule's day forms, drawn.
local function day(src: Fuzz.Source): string
  local form = src:int(0, 2)
  local text: string
  if form == 0 then
    text = ("J%d"):format(src:int(1, 365))
  elseif form == 1 then
    text = ("%d"):format(src:int(0, 365))
  else
    text = ("M%d.%d.%d"):format(src:int(1, 12), src:int(1, 5), src:int(0, 6))
  end
  if src:int(0, 1) == 1 then text = text .. "/" .. hms(src:int(-167, 167) * 3600 + src:int(0, 3599)) end
  return text
end

--- A TZ string written from drawn offsets and rules, with the two
--- offsets it may name after it, as `TZ\0std\0dst`.
local function drawn(src: Fuzz.Source): string
  local std = src:int(-96, 96) * 900 + (src:int(0, 3) == 0 and src:int(0, 899) or 0)
  local names = { "<+0530>", "EST", "AAA", "<-03>", "CET" }
  local text = Fuzz.pick(src, names) .. hms(-std)
  if src:int(0, 3) == 0 then return text .. "\0" .. std .. "\0" .. std end
  local dst = std + 3600
  text = text .. Fuzz.pick(src, { "EDT", "BBB", "<+0630>", "CEST" })
  if src:int(0, 1) == 1 then
    dst = std + src:int(-8, 8) * 900
    if dst < -86399 or dst > 86399 then dst = std end
    text = text .. hms(-dst)
  end
  if src:int(0, 3) ~= 0 then text = text .. "," .. day(src) .. "," .. day(src) end
  return text .. "\0" .. std .. "\0" .. dst
end

--- A written string reads back, and every moment it is asked about is
--- in one of its two offsets and reads back from its local time.
local function reads_back(input: string): boolean, string
  local tz, std, dst = input:match("^([^\0]*)\0([^\0]*)\0([^\0]*)$")
  if tz == nil then return false, "not an input this property draws" end
  local zone, why = Time.zone_from_posix(tz)
  if zone == nil then return false, tz .. " was refused: " .. why end
  Fuzz.label("read")
  local offsets = { [math.tointeger(std)] = true, [math.tointeger(dst)] = true }
  for ns = 1451606400 * NS, 1956528000 * NS, 86400 * NS * 19 + 3 * 3600 * NS + 77 * NS do
    local c = Time.civil(ns, zone)
    if not offsets[c.offset] then
      return false, ("%s: %d has offset %d, neither %s nor %s"):format(tz, ns, c.offset, std, dst)
    end
    if c.dst then Fuzz.label("daylight saving time") end
    local back, back_why = Time.from_civil(c, zone)
    if back ~= ns then
      return false, ("%s: %s read back as %s: %s"):format(tz, Time.format_rfc3339(ns, { zone = zone }),
        tostring(back), back_why)
    end
  end
  return true, ""
end

local function test_a_written_tz_string_reads_back(tmp: string)
  Fuzz.run({
    name = "posix tz reads back",
    dir = tmp,
    gen = drawn,
    check = reads_back,
    requires = { "read", "daylight saving time" },
  })
end
