--- Tests for [`cosmic.qr`]: codes module for module as two other encoders
--- draw them (testdata/qr/README.md says which), the patterns every code
--- carries, and what it refuses.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Qr = require("cosmic.qr")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "testdata/qr/vectors.txt", letters = "r" } } }

--- A case of testdata/qr/vectors.txt.
local record Vector
  text: string
  level: Qr.Level
  --- The mask asked for, or -1 for the lowest penalty's.
  mask: integer
  version: integer
  drawn: integer
  rows: {string}
end

local LEVELS <const>: {string: Qr.Level} = { L = "L", M = "M", Q = "Q", H = "H" }

--- The case of a block of lines: five of `key value`, then the rows.
local function vector(lines: {string}): Vector
  local fields: mut {string: string} = {}
  local rows: mut {string} = {}
  for _, line in ipairs(lines) do
    local key, value = line:match("^(%a+) (.*)$")
    if key ~= nil and value ~= nil then fields[key] = value else rows[#rows + 1] = line end
  end
  return {
    text = assert(Codec.unhex(fields["text"] or "")),
    level = assert(LEVELS[fields["level"] or ""]),
    mask = math.tointeger(fields["mask"] or "") or -1,
    version = assert(math.tointeger(fields["version"] or "")),
    drawn = assert(math.tointeger(fields["drawn"] or "")),
    rows = rows,
  }
end

local function vectors(): {Vector}
  local found: mut {Vector} = {}
  local lines: mut {string} = {}
  local text = assert(Fs.read("testdata/qr/vectors.txt"))
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line == "" then
      if #lines > 0 then found[#found + 1] = vector(lines) end
      lines = {}
    elseif line:sub(1, 1) ~= "#" then
      lines[#lines + 1] = line
    end
  end
  if #lines > 0 then found[#found + 1] = vector(lines) end
  return found
end

--- `code`'s row `y` in the hex of testdata/qr/vectors.txt.
local function row(code: Qr.Code, y: integer): string
  local digits: mut {string} = {}
  for x = 0, code.size - 1, 4 do
    local digit = 0
    for i = 0, 3 do digit = (digit << 1) | (if Qr.dark(code, x + i, y) then 1 else 0 end) end
    digits[#digits + 1] = ("%x"):format(digit)
  end
  return table.concat(digits)
end

local function test_codes_match_the_reference_encoders_module_for_module()
  local cases = vectors()
  assert(#cases == 20, #cases)
  for _, v in ipairs(cases) do
    local name = ("%d bytes at %s, mask %d"):format(#v.text, v.level, v.mask)
    local options: Qr.Options = { level = v.level }
    if v.mask >= 0 then options = { level = v.level, mask = v.mask } end
    local code = assert(Qr.encode(v.text, options))
    assert(code.version == v.version, ("%s: version %d"):format(name, code.version))
    assert(code.mask == v.drawn, ("%s: mask %d"):format(name, code.mask))
    assert(code.level == v.level and code.size == #v.rows, name)
    for y = 0, code.size - 1 do
      assert(row(code, y) == v.rows[y + 1], ("%s: row %d"):format(name, y))
    end
  end
end

--- Whether the finder pattern of the code is at `x`, `y`: a dark ring, a
--- light ring and a dark three by three.
local function finder(code: Qr.Code, x: integer, y: integer): boolean
  for dy = 0, 6 do
    for dx = 0, 6 do
      local ring = math.max(math.abs(dx - 3), math.abs(dy - 3))
      if Qr.dark(code, x + dx, y + dy) ~= (ring ~= 2) then return false end
    end
  end
  return true
end

local function test_a_version_is_chosen_by_length_and_drawn_with_its_patterns()
  local cases: {{string | integer}} = {
    { "HELLO", 1 }, { "https://example.com/", 2 }, { string.rep("x", 150), 8 }, { string.rep("y", 213), 10 },
    { string.rep("z", 2331), 40 },
  }
  for _, case in ipairs(cases) do
    local text, version = case[1], case[2]
    assert(text is string and version is integer)
    local code = assert(Qr.encode(text))
    assert(code.version == version and code.size == version * 4 + 17 and code.level == "M", #text)
    assert(finder(code, 0, 0) and finder(code, code.size - 7, 0) and finder(code, 0, code.size - 7))
    -- The one module always dark, and the timing pattern between finders.
    assert(Qr.dark(code, 8, code.size - 8))
    for i = 8, code.size - 9 do
      assert(Qr.dark(code, i, 6) == (i % 2 == 0) and Qr.dark(code, 6, i) == (i % 2 == 0))
    end
    assert(not Qr.dark(code, -1, 0) and not Qr.dark(code, 0, code.size))
  end
end

--- The format information in the top left: level and mask, read back
--- through its fixed XOR, past the timing modules.
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

local function test_the_level_and_mask_are_in_the_format_information()
  local levels: {Qr.Level: integer} = { L = 1, M = 0, Q = 3, H = 2 }
  for level, bits in pairs(levels) do
    for mask = 0, 7 do
      local code = assert(Qr.encode("format", { level = level, mask = mask }))
      assert(code.mask == mask and format_of(code) == (bits << 3) | mask, ("%s%d"):format(level, mask))
    end
  end
end

local function test_each_level_holds_what_the_standard_says_and_no_more()
  local most: {Qr.Level: integer} = { L = 2953, M = 2331, Q = 1663, H = 1273 }
  for level, n in pairs(most) do
    local code = assert(Qr.encode(string.rep("a", n), { level = level }))
    assert(code.version == 40, level)
    local none, why = Qr.encode(string.rep("a", n + 1), { level = level })
    assert(none == nil, level)
    assert(why == ("qr: %d bytes are more than a version 40 code holds at level %s (%d)"):format(n + 1, level, n),
      why)
  end
end

local function test_a_maximum_version_refuses_what_needs_a_larger_one()
  assert(assert(Qr.encode(string.rep("y", 213), { max_version = 10 })).version == 10)
  local none, why = Qr.encode(string.rep("z", 214), { max_version = 10 })
  assert(none == nil and why == "qr: 214 bytes are more than a version 10 code holds at level M (213)", why)
end

local function test_options_that_are_the_callers_mistake_raise()
  local bad: {Qr.Options} = { { mask = 8 }, { mask = -1 }, { max_version = 0 }, { max_version = 41 } }
  for _, options in ipairs(bad) do
    local ok, err = pcall(Qr.encode, "x", options)
    assert(not ok and tostring(err):find("qr: ", 1, true) ~= nil, tostring(err))
  end
end

local function test_the_same_text_is_the_same_svg_and_paints_are_escaped()
  local a, b = assert(Qr.encode("https://example.com/")), assert(Qr.encode("https://example.com/"))
  assert(Qr.svg(a) == Qr.svg(b))
  local svg = Qr.svg(a, "#101418", "#ffffff")
  assert(svg:find('viewBox="0 0 33 33"', 1, true) ~= nil and svg:find('fill="#101418"', 1, true) ~= nil, svg)
  assert(svg:find('fill="#ffffff"', 1, true) ~= nil)
  local escaped = Qr.svg(a, 'red"/><script>', "a&b")
  assert(escaped:find("<script>", 1, true) == nil and escaped:find("red&quot;/&gt;&lt;script&gt;", 1, true) ~= nil)
  assert(escaped:find('fill="a&amp;b"', 1, true) ~= nil)
end
