--- Fuzz properties for [`cosmic.qr`]: whatever bytes and options within
--- their ranges it is handed, [`Qr.encode`] answers a code or a refusal
--- and never raises; a code is as large as its version says, carries its
--- finders and the format information of its level and mask, and keeps to
--- the version allowed; and a refusal comes only for text past what that
--- version holds. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Qr = require("cosmic.qr")

local LEVELS <const>: {Qr.Level} = { "L", "M", "Q", "H" }
local FORMAT <const>: {Qr.Level: integer} = { L = 1, M = 0, Q = 3, H = 2 }
-- The most bytes a version 1 to 40 code holds at each level.
local MOST <const>: {Qr.Level: integer} = { L = 2953, M = 2331, Q = 1663, H = 1273 }

--- The format information in the top left, read back through its XOR.
local function format_of(code: Qr.Code): integer
  local bits = 0
  local function take(x: integer, y: integer)
    bits = (bits << 1) | (if Qr.dark(code, x, y) then 1 else 0 end)
  end
  for x = 0, 5 do take(x, 8) end
  take(7, 8)
  take(8, 8)
  take(8, 7)
  for y = 5, 0, -1 do take(8, y) end
  return (bits ~ 0x5412) >> 10
end

local function finder(code: Qr.Code, x: integer, y: integer): boolean
  for dy = 0, 6 do
    for dx = 0, 6 do
      local ring = math.max(math.abs(dx - 3), math.abs(dy - 3))
      if Qr.dark(code, x + dx, y + dy) ~= (ring ~= 2) then return false end
    end
  end
  return true
end

--- The level, the mask (8 for none), the largest version and the text,
--- packed. Most texts are short; some are a drawn run repeated, long
--- enough to pass what a small version holds.
local function gen(src: Fuzz.Source): string
  local text = Fuzz.bytes(src, 64)
  if src:int(0, 3) == 0 and #text > 0 then text = text:rep(src:int(2, 40)) end
  return Fuzz.pack({ Fuzz.pick(src, LEVELS), tostring(src:int(0, 8)), tostring(src:int(1, 40)), text })
end

local function check(input: string): boolean, string
  local fields = Fuzz.unpack(input)
  local level: Qr.Level = "M"
  for _, l in ipairs(LEVELS) do
    if l == fields[1] then level = l end
  end
  local mask = math.tointeger(fields[2] or "") or 8
  local max_version = math.tointeger(fields[3] or "") or 40
  local text = fields[4] or ""
  local options: Qr.Options = { level = level, max_version = max_version }
  if mask < 8 then options = { level = level, max_version = max_version, mask = mask } end
  local code, why = Qr.encode(text, options)
  if code == nil then
    Fuzz.label("refused")
    if why == "" then return false, "refused without a reason" end
    if max_version == 40 and #text <= (MOST[level] or 0) then
      return false, "refused what version 40 holds"
    end
    if #text == 0 then return false, "refused the empty text" end
    return true, ""
  end
  if why ~= "" then return false, "a code with a reason: " .. why end
  if code.version < 1 or code.version > max_version then
    return false, ("version %d past %d"):format(code.version, max_version)
  end
  if code.version >= 7 then Fuzz.label("version information") end
  if code.size ~= code.version * 4 + 17 or code.level ~= level then
    return false, "size or level"
  end
  if mask < 8 and code.mask ~= mask then
    return false, ("mask %d, not %d"):format(code.mask, mask)
  end
  if format_of(code) ~= ((FORMAT[level] or 0) << 3) | code.mask then
    return false, "format information"
  end
  if not (finder(code, 0, 0) and finder(code, code.size - 7, 0) and finder(code, 0, code.size - 7)) then
    return false, "finder patterns"
  end
  return true, ""
end

local function test_encode_is_total_and_keeps_to_its_options(tmp: string)
  Fuzz.run({
    name = "qr encode",
    dir = tmp,
    gen = gen,
    check = check,
    requires = { "refused", "version information" },
  })
end
