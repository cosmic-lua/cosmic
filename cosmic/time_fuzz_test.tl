--- Fuzz properties for `cosmic.time`'s RFC 3339 text: what
--- `format_rfc3339` writes, in UTC or moved to any offset, parses back
--- to the moment it came from; and `parse_rfc3339` is total -- whatever
--- bytes it is handed, it answers a moment or a failure and never
--- raises, and a moment it accepts formats back to text naming the same
--- one. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Time = require("cosmic.time")

local NS <const> = 1000000000

--- A moment, anywhere in an integer's range: its seconds and
--- nanoseconds drawn apart, so shrinking lowers each toward the range's
--- start.
local function gen_moment(src: Fuzz.Source): integer
  if src:int(0, 3) == 0 then
    return Fuzz.pick(src, { math.mininteger, math.maxinteger, 0, -1, 1, 951782400 * NS })
  end
  local s = src:int(math.mininteger // NS + 1, math.maxinteger // NS - 1)
  local n = src:int(0, 2) == 0 and 0 or src:int(0, NS - 1)
  return s * NS + n
end

--- A moment, an offset in minutes east of UTC, and the fraction's
--- digits (-1 for the default), packed as the input.
local function gen_stamp(src: Fuzz.Source): string
  return string.pack("<i8i4i1", gen_moment(src), src:int(-1439, 1439), src:int(-1, 9))
end

--- `ns` as RFC 3339 text `minutes` east of UTC, or nil when the local
--- clock reading is outside what an integer holds.
local function at_offset(ns: integer, minutes: integer, opts: Time.FormatOptions): string
  local shift = minutes * 60 * NS
  if (shift > 0 and ns > math.maxinteger - shift) or (shift < 0 and ns < math.mininteger - shift) then
    return nil
  end
  local sign = minutes < 0 and "-" or "+"
  local text = Time.format_rfc3339(ns + shift, opts)
  return text:sub(1, -2) .. ("%s%02d:%02d"):format(sign, math.abs(minutes) // 60, math.abs(minutes) % 60)
end

local function round_trips(input: string): boolean, string
  local ns, minutes, digits = string.unpack("<i8i4i1", input)
  local opts: Time.FormatOptions = digits >= 0 and { digits = digits } or nil
  local want = ns
  if digits >= 0 then
    local unit = 1
    for _ = digits + 1, 9 do unit = unit * 10 end
    if ns < math.mininteger + ns % unit then
      -- Cut toward the past, the range's first second names a moment
      -- before it, which parse refuses.
      Fuzz.label("cut before the range")
      want = nil
    else
      want = ns - ns % unit
    end
    if want ~= ns then Fuzz.label("cut") end
  end
  local utc = Time.format_rfc3339(ns, opts)
  local back, why = Time.parse_rfc3339(utc)
  if back ~= want then
    return false, ("%d wrote %s, which parsed as %s: %s"):format(ns, utc, tostring(back), why)
  end
  local moved = at_offset(ns, minutes, opts)
  if moved ~= nil and want ~= nil then
    Fuzz.label("offset")
    back, why = Time.parse_rfc3339(moved)
    if back ~= want then
      return false, ("%d wrote %s, which parsed as %s: %s"):format(ns, moved, tostring(back), why)
    end
  end
  return true, ""
end

local function test_format_then_parse_is_the_same_moment(tmp: string)
  Fuzz.run({
    name = "rfc3339 round trip",
    dir = tmp,
    gen = gen_stamp,
    check = round_trips,
    requires = { "offset", "cut" },
  })
end

--- Timestamps to mutate: every form the grammar allows, and the range's
--- edges.
local SAMPLES <const> = {
  "2026-09-25T04:09:21Z", "2026-09-25t04:09:21.5z", "2026-09-25T09:39:21.000000001+05:30",
  "1969-12-31T23:59:59.999999999-08:00", "2000-02-29T00:00:00-00:00",
  "1677-09-21T00:12:43.145224192Z", "2262-04-11T23:47:16.854775807Z",
}

local function parse_holds(input: string): boolean, string
  local ok, ns, why = pcall(Time.parse_rfc3339, input)
  if not ok then return false, "raised: " .. tostring(ns) end
  if ns == nil then
    Fuzz.label("refused")
    if why == "" then return false, "refused without a reason" end
    return true, ""
  end
  Fuzz.label("parsed")
  if why ~= "" then return false, "parsed with a reason: " .. why end
  local again, again_why = Time.parse_rfc3339(Time.format_rfc3339(ns))
  if again ~= ns then
    return false, ("%q parsed as %d, whose text parsed as %s: %s"):format(input, ns,
      tostring(again), again_why)
  end
  return true, ""
end

local function test_parse_is_total(tmp: string)
  Fuzz.run({
    name = "rfc3339 parse total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      if src:int(0, 3) == 0 then return Fuzz.bytes(src, 40) end
      return Fuzz.mutate(src, Fuzz.pick(src, SAMPLES), 3)
    end,
    check = parse_holds,
    requires = { "parsed", "refused" },
  })
end
