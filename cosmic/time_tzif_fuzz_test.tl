--- Fuzz properties for `cosmic.time`'s TZif reader (RFC 8536), which
--- reads files from the host and from wherever a caller's bytes came
--- from: `zone_from_tzif` is total -- whatever bytes it is handed, it
--- answers a zone or a failure and never raises, and a zone it answers
--- names every moment without raising -- and a file written from drawn
--- transitions and types reads back as what was drawn. Inputs are
--- mutations of the zones the binary carries, of files written here,
--- and arbitrary bytes. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Store = require("cosmic.store")
local Time = require("cosmic.time")

local NS <const> = 1000000000

--- Real zones to mutate, chosen for what their files hold: a footer
--- with rules, one without, a half-hour change, a skipped day, negative
--- daylight saving time, a two-hour change, and no transitions at all.
local CARRIED <const> = { "America/New_York", "Asia/Kolkata", "Australia/Lord_Howe", "Pacific/Apia",
  "Europe/Dublin", "Antarctica/Troll", "UTC", "America/Sao_Paulo", "Pacific/Chatham" }

local samples: {string} = {}
for _, name in ipairs(CARRIED) do
  samples[#samples + 1] = assert(Store.zoneinfo(name))
end

--- Moments every zone read is asked about: the range's ends, the epoch,
--- around 32-bit time's end, and now-ish.
local PROBES <const> = { math.mininteger, math.maxinteger, 0, -1, 2147483647 * NS,
  2147483648 * NS, 1790309361 * NS, -2208988800 * NS, 4107542400 * NS }

--- Footers a written file may carry.
local FOOTERS <const> = { "", "UTC0", "EST5EDT,M3.2.0,M11.1.0", "<+0330>-3:30",
  "AEST-10AEDT,M10.1.0,M4.1.0/3", "EST5EDT4,0/0,J365/25", "<-03>3<-02>,M3.5.0/-2,M10.5.0/-1" }

local ABBREVIATIONS <const> = { "UTC", "EST", "EDT", "+0530", "-00", "LMT", "CEST" }

--- One local time type: an offset east of UTC, whether it is daylight
--- saving time, and its abbreviation.
local record Type
  offset: integer
  dst: boolean
  abbreviation: string
end

--- What a written file should say: its bytes, and the transitions and
--- types drawn for it.
local record Drawn
  bytes: string
  times: {integer}
  indices: {integer}
  types: {Type}
end

--- A TZif file as zic writes one: for version 2 and later, a version 1
--- block standing for nothing (a reader of the 64-bit block skips it),
--- then the 64-bit block and the footer.
local function write(version: string, times: {integer}, indices: {integer}, types: {Type},
    footer: string): string
  local chars: {string} = {}
  local at: {string:integer} = {}
  local length = 0
  for _, t in ipairs(types) do
    if at[t.abbreviation] == nil then
      at[t.abbreviation] = length
      chars[#chars + 1] = t.abbreviation .. "\0"
      length = length + #t.abbreviation + 1
    end
  end
  local function block(wide: boolean, count: integer): string
    local parts = { "TZif", version, ("\0"):rep(15),
      string.pack(">I4I4I4I4I4I4", 0, 0, 0, count, #types, length) }
    for i = 1, count do parts[#parts + 1] = string.pack(wide and ">i8" or ">i4", times[i]) end
    for i = 1, count do parts[#parts + 1] = string.char(indices[i] - 1) end
    for _, t in ipairs(types) do
      parts[#parts + 1] = string.pack(">i4BB", t.offset, t.dst and 1 or 0, at[t.abbreviation])
    end
    parts[#parts + 1] = table.concat(chars)
    return table.concat(parts)
  end
  if version == "\0" then return block(false, #times) end
  return block(false, 0) .. block(true, #times) .. "\n" .. footer .. "\n"
end

--- Transitions and types drawn into a file: each collection one
--- element at a time, so shrinking can cut any of them.
local function draw(src: Fuzz.Source): Drawn
  local version = Fuzz.pick(src, { "\0", "2", "3", "4" })
  local types: {Type} = {}
  repeat
    types[#types + 1] = {
      offset = src:int(0, 1) == 0 and src:int(-56, 56) * 900 or src:int(-89999, 93599),
      dst = src:int(0, 1) == 1,
      abbreviation = Fuzz.pick(src, ABBREVIATIONS),
    }
  until not Fuzz.more(src, #types, 6)
  local times: {integer} = {}
  local indices: {integer} = {}
  -- 32-bit times for a version 1 file, and any for later ones.
  local wide = version ~= "\0"
  local t = wide and src:int(-(1 << 40), 1 << 34) or src:int(-(1 << 31), 0)
  while Fuzz.more(src, #times, 12) do
    t = t + src:int(1, wide and 1 << 30 or 1 << 26)
    if not wide and t > (1 << 31) - 1 then break end
    times[#times + 1] = t
    indices[#indices + 1] = src:int(1, #types)
  end
  local footer = version ~= "\0" and Fuzz.pick(src, FOOTERS) or ""
  return { bytes = write(version, times, indices, types, footer), times = times, indices = indices,
    types = types }
end

--- A file of many local time types over many bytes of abbreviations,
--- with its NULs few and far along: the shape that makes a reader
--- searching from each type to the end take time quadratic in its
--- length.
local function crowded(src: Fuzz.Source): string
  local count = src:int(1, 40000)
  local chars = count * src:int(1, 6)
  local index = src:int(0, 255)
  local abbreviations = ("A"):rep(chars)
  local nul = src:int(1, chars)
  abbreviations = abbreviations:sub(1, nul - 1) .. "\0" .. abbreviations:sub(nul + 1)
  return table.concat({ "TZif", "\0", ("\0"):rep(15),
    string.pack(">I4I4I4I4I4I4", 0, 0, 0, 0, count, chars),
    string.pack(">i4BB", 0, 0, math.min(index, chars - 1)):rep(count), abbreviations })
end

--- Whatever `data` is, reading it and asking the zone about moments
--- raises nothing, and a refusal says why. Reading takes time linear in
--- the length: under a second for anything drawn here.
local function total(data: string): boolean, string
  local started = Time.monotonic_ns()
  local ok, zone, why = pcall(Time.zone_from_tzif, data, "Fuzz/Zone")
  local elapsed = Time.monotonic_ns() - started
  if elapsed > NS then
    return false, ("reading %d bytes took %d ms"):format(#data, elapsed // 1000000)
  end
  if #data > 100000 then Fuzz.label("large") end
  if not ok then return false, "zone_from_tzif raised: " .. tostring(zone) end
  if zone == nil then
    Fuzz.label("refused")
    if why == "" then return false, "refused without a reason" end
    return true, ""
  end
  Fuzz.label("read")
  for _, ns in ipairs(PROBES) do
    local civil_ok, c = pcall(Time.civil, ns, zone)
    if not civil_ok then return false, ("civil(%d) raised: %s"):format(ns, tostring(c)) end
    if c.offset < -89999 or c.offset > 93599 then
      return false, ("civil(%d) has offset %d"):format(ns, c.offset)
    end
    local from_ok, back = pcall(Time.from_civil, c, zone)
    if not from_ok then return false, ("from_civil of civil(%d) raised: %s"):format(ns, tostring(back)) end
    if back == ns then Fuzz.label("round trip") end
    local format_ok, text = pcall(Time.format_rfc3339, ns, { zone = zone, zone_name = true })
    if not format_ok then return false, ("format_rfc3339(%d) raised: %s"):format(ns, text) end
  end
  return true, ""
end

local function test_reading_tzif_is_total(tmp: string)
  Fuzz.run({
    name = "tzif read total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local kind = src:int(0, 7)
      if kind == 0 then return Fuzz.bytes(src, 80) end
      if kind == 7 then return crowded(src) end
      if kind == 1 then return Fuzz.mutate(src, draw(src).bytes, 6) end
      return Fuzz.mutate(src, Fuzz.pick(src, samples), 6)
    end,
    check = total,
    requires = { "read", "refused", "round trip", "large" },
  })
end

--- A file written from drawn transitions reads back as drawn: type 0
--- before the first transition, and each transition's type from it on,
--- with every local time it names read back as the moment it came from.
local function reads_back(input: string): boolean, string
  local bytes, times_text, types_text = string.unpack("<s4s4s4", input)
  local zone, why = Time.zone_from_tzif(bytes, "Fuzz/Zone")
  if zone == nil then return false, "a written file was refused: " .. why end
  Fuzz.label("read")
  local types: {Type} = {}
  for offset, dst, abbreviation in types_text:gmatch("(%S+) (%S+) (%S+)\n") do
    types[#types + 1] = { offset = math.tointeger(offset), dst = dst == "true", abbreviation = abbreviation }
  end
  local function holds(ns: integer, t: Type): string
    local c = Time.civil(ns, zone)
    if c.offset ~= t.offset or c.dst ~= t.dst or c.abbreviation ~= t.abbreviation then
      return ("at %d: %d %s %s, want %d %s %s"):format(ns, c.offset, tostring(c.dst),
        c.abbreviation, t.offset, tostring(t.dst), t.abbreviation)
    end
    local back, back_why = Time.from_civil(c, zone)
    if back ~= ns then
      return ("at %d: %s read back as %s: %s"):format(ns, Time.format_rfc3339(ns, { zone = zone }),
        tostring(back), back_why)
    end
    return nil
  end
  local first = true
  for s, index in times_text:gmatch("(%S+) (%S+)\n") do
    local seconds, i = math.tointeger(s), math.tointeger(index)
    -- Only moments an integer of nanoseconds holds can be asked about.
    if seconds > math.mininteger // NS + 1 and seconds < math.maxinteger // NS then
      if first then
        local wrong = holds((seconds - 1) * NS, types[1])
        if wrong ~= nil then return false, "before the first transition, " .. wrong end
      end
      local wrong = holds(seconds * NS, types[i])
      if wrong ~= nil then return false, wrong end
      Fuzz.label("transition")
    end
    first = false
  end
  return true, ""
end

local function test_a_written_file_reads_back_as_drawn(tmp: string)
  Fuzz.run({
    name = "tzif reads back",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local drawn = draw(src)
      local times: {string} = {}
      for i, t in ipairs(drawn.times) do times[i] = ("%d %d\n"):format(t, drawn.indices[i]) end
      local types: {string} = {}
      for i, t in ipairs(drawn.types) do
        types[i] = ("%d %s %s\n"):format(t.offset, tostring(t.dst), t.abbreviation)
      end
      return string.pack("<s4s4s4", drawn.bytes, table.concat(times), table.concat(types))
    end,
    check = reads_back,
    requires = { "read", "transition" },
  })
end
