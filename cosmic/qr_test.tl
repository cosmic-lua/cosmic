--- Tests for [`cosmic.qr`]: codes module for module as two other encoders
--- draw them (testdata/qr/README.md says which), the patterns every code
--- carries, and what it refuses.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Fixture = require("build.qr_fixture")
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
    assert(Fixture.finders(code))
    -- The one module always dark, and the timing pattern between finders.
    assert(Qr.dark(code, 8, code.size - 8))
    for i = 8, code.size - 9 do
      assert(Qr.dark(code, i, 6) == (i % 2 == 0) and Qr.dark(code, 6, i) == (i % 2 == 0))
    end
    assert(not Qr.dark(code, -1, 0) and not Qr.dark(code, 0, code.size))
  end
end

local function test_the_level_and_mask_are_in_the_format_information()
  local levels: {Qr.Level: integer} = { L = 1, M = 0, Q = 3, H = 2 }
  for level, bits in pairs(levels) do
    for mask = 0, 7 do
      local code = assert(Qr.encode("format", { level = level, mask = mask }))
      assert(code.mask == mask and Fixture.format(code) == (bits << 3) | mask, ("%s%d"):format(level, mask))
    end
  end
end

--- The most bytes each version holds at each level in byte mode, from
--- the standard's table of data codewords less the mode and count bits,
--- as Project Nayuki's qrcodegen 1.8.0 computes them.
local CAPACITY <const>: {Qr.Level: {integer}} = {
  L = {
    17, 32, 53, 78, 106, 134, 154, 192, 230, 271, 321, 367, 425, 458,
    520, 586, 644, 718, 792, 858, 929, 1003, 1091, 1171, 1273, 1367, 1465, 1528,
    1628, 1732, 1840, 1952, 2068, 2188, 2303, 2431, 2563, 2699, 2809, 2953,
  },
  M = {
    14, 26, 42, 62, 84, 106, 122, 152, 180, 213, 251, 287, 331, 362,
    412, 450, 504, 560, 624, 666, 711, 779, 857, 911, 997, 1059, 1125, 1190,
    1264, 1370, 1452, 1538, 1628, 1722, 1809, 1911, 1989, 2099, 2213, 2331,
  },
  Q = {
    11, 20, 32, 46, 60, 74, 86, 108, 130, 151, 177, 203, 241, 258,
    292, 322, 364, 394, 442, 482, 509, 565, 611, 661, 715, 751, 805, 868,
    908, 982, 1030, 1112, 1168, 1228, 1283, 1351, 1423, 1499, 1579, 1663,
  },
  H = {
    7, 14, 24, 34, 44, 58, 64, 84, 98, 119, 137, 155, 177, 194,
    220, 250, 280, 310, 338, 382, 403, 439, 461, 511, 535, 593, 625, 658,
    698, 742, 790, 842, 898, 958, 983, 1051, 1093, 1139, 1219, 1273,
  },
}

--- Each version of `level` holds its bytes of CAPACITY, and refuses one
--- more. Mask 0 is named to leave out the penalty, which is what makes a
--- large code slow and is held by the vectors.
local function holds_what_the_standard_says(level: Qr.Level)
  for version, n in ipairs(CAPACITY[level] or {}) do
    local name = ("%s%d"):format(level, version)
    local code = assert(Qr.encode(string.rep("a", n), { level = level, mask = 0 }))
    assert(code.version == version, name)
    local none, why = Qr.encode(string.rep("a", n + 1), { level = level, mask = 0, max_version = version })
    assert(none == nil, name)
    assert(why == ("qr: the text is %d bytes, and a version %d code at level %s holds %d"):format(n + 1, version,
      level, n), why)
  end
end

local function test_each_version_at_level_l_holds_what_the_standard_says()
  holds_what_the_standard_says("L")
end
local function test_each_version_at_level_m_holds_what_the_standard_says()
  holds_what_the_standard_says("M")
end
local function test_each_version_at_level_q_holds_what_the_standard_says()
  holds_what_the_standard_says("Q")
end
local function test_each_version_at_level_h_holds_what_the_standard_says()
  holds_what_the_standard_says("H")
end

local function test_a_maximum_version_refuses_what_needs_a_larger_one()
  assert(assert(Qr.encode(string.rep("y", 213), { max_version = 10 })).version == 10)
  local none, why = Qr.encode(string.rep("z", 214), { max_version = 10 })
  assert(none == nil and why == "qr: the text is 214 bytes, and a version 10 code at level M holds 213", why)
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

local function test_the_svg_path_has_a_square_per_dark_module_inside_the_border()
  local code = assert(Qr.encode("https://example.com/"))
  local want: mut {string: boolean} = {}
  local dark = 0
  for y = 0, code.size - 1 do
    for x = 0, code.size - 1 do
      if Qr.dark(code, x, y) then
        dark = dark + 1
        want[("M%d,%dh1v1h-1z"):format(x + 4, y + 4)] = true
      end
    end
  end
  local svg = Qr.svg(code)
  local drawn = 0
  for square in svg:gmatch("M%d+,%d+h1v1h%-1z") do
    assert(want[square] == true, square)
    drawn = drawn + 1
  end
  assert(drawn == dark and dark > 0, ("%d of %d"):format(drawn, dark))
  -- The first square is the top left finder's corner, four modules in.
  assert(svg:find('d="M4,4h1v1h-1z', 1, true) ~= nil)
end
