--- Fuzz properties for [`cosmic.qr`]: whatever bytes and options within
--- their ranges it is handed, [`Qr.encode`] answers a code or a refusal
--- and never raises; a code is as large as its version says, carries its
--- finders and the format information of its level and mask, and is the
--- smallest version that holds the text, within the one allowed; and a refusal comes only for text past what that
--- version holds. A code reads back as itself, and a damaged one reads
--- back where its error correction can mend it and never raises.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).

local Fixture = require("build.qr_fixture")
local Fuzz = require("build.fuzz")
local Qr = require("cosmic.qr")

local LEVELS <const>: {Qr.Level} = { "L", "M", "Q", "H" }
local FORMAT <const>: {Qr.Level: integer} = { L = 1, M = 0, Q = 3, H = 2 }
-- The most bytes a version 1 to 40 code holds at each level.
local MOST <const>: {Qr.Level: integer} = { L = 2953, M = 2331, Q = 1663, H = 1273 }

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
    if why.message == "" then return false, "refused without a reason" end
    if max_version == 40 and #text <= (MOST[level] or 0) then
      return false, "refused what version 40 holds"
    end
    if #text == 0 then return false, "refused the empty text" end
    -- A refusal below version 40 holds only where a larger version is needed.
    local larger, _ = Qr.encode(text, { level = level, mask = 0 })
    if larger ~= nil and larger.version <= max_version then
      return false, ("refused at %d what version %d holds"):format(max_version, larger.version)
    end
    return true, ""
  end
  if code.version < 1 or code.version > max_version then
    return false, ("version %d past %d"):format(code.version, max_version)
  end
  if code.version >= 7 then Fuzz.label("version information") end
  if code.version > 1 then
    local smaller, _ = Qr.encode(text, { level = level, max_version = code.version - 1, mask = 0 })
    if smaller ~= nil then
      return false, ("version %d where a smaller one holds the text"):format(code.version)
    end
  end
  if code.size ~= code.version * 4 + 17 or code.level ~= level then
    return false, "size or level"
  end
  if mask < 8 and code.mask ~= mask then
    return false, ("mask %d, not %d"):format(code.mask, mask)
  end
  if Fixture.format(code) ~= ((FORMAT[level] or 0) << 3) | code.mask then
    return false, "format information"
  end
  if not Fixture.finders(code) then return false, "finder patterns" end
  local read, read_why = Qr.decode(Qr.rows(code))
  if read == nil then return false, "does not read back: " .. read_why.message end
  if read.text ~= text or read.code.version ~= code.version or read.code.level ~= level or
      read.code.mask ~= code.mask or read.corrected ~= 0 then
    return false, "reads back as another code"
  end
  return true, ""
end

--- The text, the level and the modules to flip (`x,y` pairs), packed: a
--- code damaged in a few places, or in many.
local function gen_damage(src: Fuzz.Source): string
  local text = Fuzz.bytes(src, 48)
  local flips: mut {string} = {}
  local many = src:int(0, 3) == 0
  for _ = 1, if many then src:int(4, 80) else src:int(0, 3) end do
    flips[#flips + 1] = ("%d,%d"):format(src:int(0, 40), src:int(0, 40))
  end
  return Fuzz.pack({ Fuzz.pick(src, LEVELS), text, table.concat(flips, " ") })
end

--- Reading a damaged code never raises. Three flipped modules or fewer
--- touch three codewords at most and three bits of each copy of the
--- format information, which every level mends, so the text reads back.
local function check_damage(input: string): boolean, string
  local fields = Fuzz.unpack(input)
  local level: Qr.Level = "M"
  for _, l in ipairs(LEVELS) do
    if l == fields[1] then level = l end
  end
  local text = fields[2] or ""
  local code, _ = Qr.encode(text, { level = level, mask = 0 })
  if code == nil then return true, "" end
  local flipped: mut {integer: boolean} = {}
  local count = 0
  for xs, ys in (fields[3] or ""):gmatch("(%d+),(%d+)") do
    local x, y = assert(math.tointeger(xs)), assert(math.tointeger(ys))
    if x < code.size and y < code.size and flipped[y * code.size + x] == nil then
      flipped[y * code.size + x] = true
      count = count + 1
    end
  end
  local rows: mut {{boolean}} = {}
  for y, row in ipairs(Qr.rows(code)) do
    local copy: mut {boolean} = {}
    for x, v in ipairs(row) do
      local cx, cy = x - 5, y - 5
      local inside = cx >= 0 and cy >= 0 and cx < code.size and cy < code.size
      copy[#copy + 1] = v ~= (inside and flipped[cy * code.size + cx] == true)
    end
    rows[#rows + 1] = copy
  end
  local read: Qr.Decoded? = nil
  local why = ""
  local ok, raised = pcall(function()
    local decoded, failure = Qr.decode(rows)
    read = decoded
    if failure ~= nil then why = failure.message end
  end)
  if not ok then return false, "raised: " .. tostring(raised) end
  if count > 3 then
    Fuzz.label("many flips")
    if read == nil and why == "" then return false, "refused without a reason" end
    return true, ""
  end
  local got = read
  if got == nil then return false, ("%d flips do not read back: %s"):format(count, why) end
  if got.text ~= text then return false, ("%d flips read back as another text"):format(count) end
  if count > 0 then Fuzz.label("mended") end
  return true, ""
end

local function test_a_damaged_code_reads_back_or_is_refused(tmp: string)
  Fuzz.run({
    name = "qr decode",
    dir = tmp,
    gen = gen_damage,
    check = check_damage,
    requires = { "many flips", "mended" },
  })
end

local function test_encode_is_total_and_keeps_to_its_options(tmp: string)
  Fuzz.run({
    name = "qr encode",
    dir = tmp,
    gen = gen,
    check = check,
    -- A check encodes a text up to three times, the first trying all 8
    -- masks: a version near 40 spends about 60M VM instructions under
    -- coverage, past the default budget, where a code that runs for
    -- good would spend it many times over.
    budget = 200000000,
    requires = { "refused", "version information" },
  })
end
