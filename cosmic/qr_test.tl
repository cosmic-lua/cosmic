--- Tests for [`cosmic.qr`]: codes module for module as two other encoders
--- draw them (testdata/qr/README.md says which), the patterns every code
--- carries, and what it refuses.

local Codec = require("cosmic.codec")
local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")
local Fixture = require("build.qr_fixture")
local Qr = require("cosmic.qr")
local Test = require("cosmic.test")
local Bench = require("cosmic.bench")

Test.policy{ grants = { { path = "testdata/qr/vectors.txt", letters = "r" },
  { path = "testdata/qr/segments.txt", letters = "r" } } }

--- A case of testdata/qr/vectors.txt or segments.txt.
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

local function vectors(path?: string): {Vector}
  local found: mut {Vector} = {}
  local lines: mut {string} = {}
  local text = assert(Fs.read(path or "testdata/qr/vectors.txt"))
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
    assert(why.message == ("qr: the text is %d bytes, and a version %d code at level %s holds %d"):format(n + 1, version,
      level, n), tostring(why))
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
  assert(none == nil and why.message == "qr: the text is 214 bytes, and a version 10 code at level M holds 213", why)
end

local function test_options_that_are_the_callers_mistake_raise()
  local bad: {Qr.Options} = { { mask = 8 }, { mask = -1 }, { max_version = 0 }, { max_version = 41 } }
  for _, options in ipairs(bad) do
    local ok, err = pcall(function() local _, _ = Qr.encode("x", options) end)
    -- The caller is blamed: the message names this file, not cosmic/qr.tl.
    assert(not ok and tostring(err):find("^cosmic%.qr_test:%d+: qr: ") ~= nil, tostring(err))
  end
end

--- The codes the drawings are held to: versions 1, 2, 7 (the first with
--- version information), 10, 27 and 40. Every side drawn is odd, so the
--- half blocks' last line always holds a row alone.
local function codes(): {Qr.Code}
  local found: mut {Qr.Code} = {}
  for _, n in ipairs({ 14, 20, 122, 213, 1125, 2331 }) do
    found[#found + 1] = assert(Qr.encode(string.rep("q", n), { mask = 0 }))
  end
  return found
end

-- The half blocks by whether each puts ink above, and below.
local ABOVE <const>: {string: boolean} = { [" "] = false, ["\u{2580}"] = true, ["\u{2584}"] = false, ["\u{2588}"] = true }
local BELOW <const>: {string: boolean} = { [" "] = false, ["\u{2580}"] = false, ["\u{2584}"] = true, ["\u{2588}"] = true }

--- The modules `text` puts ink on, by `y * side + x`, read back from its
--- characters, and the count of its rows; raises on a line of the wrong
--- width or a character not drawn.
local function inked(text: string, side: integer, ascii: boolean): {integer: boolean}, integer
  local ink: mut {integer: boolean} = {}
  local y = 0
  for line in text:gmatch("([^\n]*)\n") do
    if ascii then
      assert(#line == side * 2, ("row %d is %d bytes"):format(y, #line))
      for x = 0, side - 1 do
        local cell = line:sub(x * 2 + 1, x * 2 + 2)
        assert(cell == "##" or cell == "  ", cell)
        ink[y * side + x] = cell == "##"
      end
      y = y + 1
    else
      local x = 0
      for _, point in utf8.codes(line) do
        local char = utf8.char(point)
        local above, below = ABOVE[char], BELOW[char]
        assert(above ~= nil and below ~= nil, ("U+%04X"):format(point))
        ink[y * side + x] = above
        ink[(y + 1) * side + x] = below
        x = x + 1
      end
      assert(x == side, ("line %d is %d characters"):format(y // 2, x))
      y = y + 2
    end
  end
  assert(#text > 0 and text:sub(-1) == "\n")
  return ink, y
end

--- `text` read back is `code` with a quiet zone of `quiet`: ink on each
--- light module when not inverted, on each dark one when inverted.
local function reads_back(code: Qr.Code, text: string, quiet: integer, invert: boolean, ascii: boolean)
  local side = Qr.size(code, quiet)
  local name = ("version %d, quiet %d, invert %s, ascii %s"):format(code.version, quiet, invert, ascii)
  local ink, rows = inked(text, side, ascii)
  assert(side % 2 == 1 and rows == (if ascii then side else side + 1 end), ("%s: %d rows"):format(name, rows))
  for y = 0, side - 1 do
    for x = 0, side - 1 do
      local want = Qr.dark(code, x - quiet, y - quiet) == invert
      assert(ink[y * side + x] == want, ("%s: module %d, %d"):format(name, x, y))
    end
  end
  -- A last row alone has nothing below it.
  for x = 0, side - 1 do assert(ink[side * side + x] ~= true, name) end
end

local function test_text_reads_back_as_the_modules_with_the_quiet_zone()
  for _, code in ipairs(codes()) do
    for _, quiet in ipairs({ 4, 1, 0 }) do
      for _, invert in ipairs({ false, true }) do
        local options: Qr.TextOptions = { quiet = quiet, invert = invert }
        reads_back(code, Qr.text(code, options), quiet, invert, false)
        options = { quiet = quiet, invert = invert, ascii = true }
        reads_back(code, Qr.text(code, options), quiet, invert, true)
      end
    end
    reads_back(code, Qr.text(code), 4, false, false)
  end
end

local function test_text_without_invert_draws_the_quiet_zone_and_inverted_does_not()
  local code = assert(Qr.encode("x"))
  local plain, inverted = Qr.text(code), Qr.text(code, { invert = true })
  local full = ("\u{2588}"):rep(Qr.size(code)) .. "\n"
  assert(plain:sub(1, #full) == full, plain)
  assert(inverted:sub(1, Qr.size(code) + 1) == (" "):rep(Qr.size(code)) .. "\n", inverted)
end

local function test_the_size_is_the_side_with_its_quiet_zone()
  for _, code in ipairs(codes()) do
    assert(Qr.size(code) == code.size + 8 and Qr.size(code, 0) == code.size and Qr.size(code, 2) == code.size + 4)
  end
end

local function test_a_quiet_zone_or_scale_out_of_range_raises()
  local code = assert(Qr.encode("x"))
  local bad: {function(): string} = {
    function(): string return Qr.text(code, { quiet = -1 }) end,
    function(): string return Qr.text(code, { quiet = 17 }) end,
    function(): string return Qr.svg(code, { quiet = -1 }) end,
    function(): string return Qr.svg(code, { scale = 0 }) end,
    function(): string return Qr.svg(code, { scale = 1001 }) end,
    function(): string return tostring(Qr.size(code, -1)) end,
  }
  for i, call in ipairs(bad) do
    local ok, err = pcall(call)
    assert(not ok and tostring(err):find("qr: ", 1, true) ~= nil, ("%d: %s"):format(i, tostring(err)))
  end
end

local function test_the_same_text_is_the_same_svg_and_paints_are_escaped()
  local a, b = assert(Qr.encode("https://example.com/")), assert(Qr.encode("https://example.com/"))
  assert(Qr.svg(a) == Qr.svg(b))
  local svg = Qr.svg(a, { dark = "#101418", light = "#ffffff" })
  assert(svg:find('viewBox="0 0 33 33"', 1, true) ~= nil and svg:find('fill="#101418"', 1, true) ~= nil, svg)
  assert(svg:find('fill="#ffffff"', 1, true) ~= nil)
  local escaped = Qr.svg(a, { dark = 'red"/><script>', light = "a&b", title = "<b>&" })
  assert(escaped:find("<script>", 1, true) == nil and escaped:find("red&quot;/&gt;&lt;script&gt;", 1, true) ~= nil)
  assert(escaped:find('fill="a&amp;b"', 1, true) ~= nil)
  assert(escaped:find('role="img" aria-label="&lt;b&gt;&amp;"><title>&lt;b&gt;&amp;</title>', 1, true) ~= nil, escaped)
end

local function test_the_svg_has_a_size_in_pixels_and_a_ground_that_can_be_left_out()
  local code = assert(Qr.encode("https://example.com/"))
  local svg = Qr.svg(code)
  assert(svg:find('^<svg xmlns="http://www.w3.org/2000/svg" width="264" height="264" viewBox="0 0 33 33" ' ..
      'shape%-rendering="crispEdges"><rect width="100%%" height="100%%" fill="#fff"/><path d="M4,4h7v1h%-7z'), svg)
  assert(svg:find("<title>", 1, true) == nil and svg:find("aria", 1, true) == nil)
  local bare = Qr.svg(code, { quiet = 0, scale = 3, light = "none" })
  assert(bare:find('width="75" height="75" viewBox="0 0 25 25"', 1, true) ~= nil, bare)
  assert(bare:find("<rect", 1, true) == nil and bare:find('d="M0,0h7v1h-7z', 1, true) ~= nil, bare)
end

--- The rectangles of `svg`'s path, read back into the modules they cover.
local function covered(svg: string): {integer: boolean}, integer
  local d = assert(svg:match(' d="([^"]*)"'))
  local seen: mut {integer: boolean} = {}
  local runs = 0
  local read: mut {string} = {}
  for whole, x, y, w, back in d:gmatch("(M(%d+),(%d+)h(%d+)v1h%-(%d+)z)") do
    read[#read + 1] = whole
    assert(w == back, w .. " " .. back)
    local x0, y0, n = assert(math.tointeger(x)), assert(math.tointeger(y)), assert(math.tointeger(w))
    for i = 0, n - 1 do
      assert(seen[y0 * 1000 + x0 + i] == nil, "a module drawn twice")
      seen[y0 * 1000 + x0 + i] = true
    end
    runs = runs + 1
  end
  assert(table.concat(read) == d, d)
  return seen, runs
end

local function test_the_svg_path_covers_each_dark_module_once_in_runs_of_a_row()
  for _, code in ipairs(codes()) do
    for _, quiet in ipairs({ 4, 0, 2 }) do
      local seen, runs = covered(Qr.svg(code, { quiet = quiet }))
      local want_runs = 0
      for y = 0, code.size - 1 do
        for x = 0, code.size - 1 do
          local dark = Qr.dark(code, x, y)
          assert((seen[(y + quiet) * 1000 + x + quiet] == true) == dark, ("%d, %d"):format(x, y))
          if dark and not Qr.dark(code, x - 1, y) then want_runs = want_runs + 1 end
        end
      end
      -- Each run is one rectangle: none is split, and none crosses a light module.
      assert(runs == want_runs, ("%d runs of %d"):format(runs, want_runs))
    end
  end
end

--- `v`'s modules as the rows [`Qr.decode`] reads, with a quiet zone of 2.
local function vector_rows(v: Vector): {{boolean}}
  local rows: mut {{boolean}} = {}
  local blank: mut {boolean} = {}
  for _ = 1, #v.rows + 4 do blank[#blank + 1] = false end
  rows[#rows + 1] = blank
  rows[#rows + 1] = blank
  for _, hex in ipairs(v.rows) do
    local cells: mut {boolean} = { false, false }
    for x = 0, #v.rows - 1 do
      local digit = assert(math.tointeger(tonumber(hex:sub(x // 4 + 1, x // 4 + 1), 16)))
      cells[#cells + 1] = (digit >> (3 - x % 4)) & 1 == 1
    end
    cells[#cells + 1] = false
    cells[#cells + 1] = false
    rows[#rows + 1] = cells
  end
  rows[#rows + 1] = blank
  rows[#rows + 1] = blank
  return rows
end

local function reads_as(v: Vector, name: string)
  local read, why = Qr.decode(vector_rows(v))
  assert(read ~= nil, ("%s: %s"):format(name, tostring(why)))
  assert(read.text == v.text, name)
  assert(read.code.version == v.version and read.code.level == v.level and read.code.mask == v.drawn, name)
  assert(read.corrected == 0, name)
end

local function test_decode_reads_the_reference_encoders_byte_codes()
  for _, v in ipairs(vectors()) do
    reads_as(v, ("%d bytes at %s, mask %d"):format(#v.text, v.level, v.mask))
  end
end

local function test_decode_reads_numeric_alphanumeric_mixed_and_eci_segments()
  local cases = vectors("testdata/qr/segments.txt")
  assert(#cases == 13, #cases)
  for _, v in ipairs(cases) do reads_as(v, v.text:sub(1, 30)) end
end

--- A copy of `rows` with the modules `flip` names (`x, y` from 1) flipped.
local function damaged(rows: {{boolean}}, flip: function(x: integer, y: integer): boolean): {{boolean}}
  local copy: mut {{boolean}} = {}
  for y, cells in ipairs(rows) do
    local r: mut {boolean} = {}
    for x, v in ipairs(cells) do r[#r + 1] = v ~= flip(x, y) end
    copy[#copy + 1] = r
  end
  return copy
end

--- Each of the 32 codes (4 levels by 8 masks) reads back from its rows at each quiet zone and as light on dark, and the
--- 15 other drawings (svg and text at each quiet zone, text inverted or ascii) take turns over them, so every drawing
--- reads two codes or more and every code is read from one drawing besides its rows. How a drawing is made does not
--- turn on the level or the mask, so one drawing for each code covers them.
local record Drawing
  svg: boolean
  quiet: integer
  invert: boolean
  ascii: boolean
end

local function test_every_drawing_reads_back_at_each_level_and_mask()
  local drawings: mut {Drawing} = {}
  for _, quiet in ipairs({ 4, 1, 0 }) do
    drawings[#drawings + 1] = { svg = true, quiet = quiet, invert = false, ascii = false }
    for _, invert in ipairs({ false, true }) do
      for _, ascii in ipairs({ false, true }) do
        drawings[#drawings + 1] = { svg = false, quiet = quiet, invert = invert, ascii = ascii }
      end
    end
  end
  assert(#drawings == 15, #drawings)
  local turn = 0
  for _, level in ipairs({ "L", "M", "Q", "H" }) do
    assert(level is Qr.Level)
    for mask = 0, 7 do
      local text = ("level %s, mask %d: https://example.com/?q=%d"):format(level, mask, mask)
      local code = assert(Qr.encode(text, { level = level, mask = mask }))
      local function holds(how: string, read: Qr.Decoded?, why?: Failure)
        assert(read ~= nil, ("%s%d %s: %s"):format(level, mask, how, tostring(why)))
        assert(read.text == text and read.code.level == level and read.code.mask == mask, how)
      end
      for _, quiet in ipairs({ 4, 1, 0 }) do
        local read, why = Qr.decode(Qr.rows(code, quiet))
        holds(("rows, quiet %d"):format(quiet), read, why)
      end
      -- A grid of light on dark reads too.
      local dark_read, dark_why = Qr.decode(damaged(Qr.rows(code), function(_: integer, _: integer): boolean
        return true
      end))
      holds("light on dark", dark_read, dark_why)
      local index = turn % #drawings + 1
      turn = turn + 1
      local d = assert(drawings[index])
      if d.svg then
        local read, why = Qr.read(Qr.svg(code, { quiet = d.quiet }))
        holds(("svg, quiet %d"):format(d.quiet), read, why)
      else
        local read, why = Qr.read(Qr.text(code, { quiet = d.quiet, invert = d.invert, ascii = d.ascii }))
        holds(("text, quiet %d, invert %s, ascii %s"):format(d.quiet, d.invert, d.ascii), read, why)
      end
    end
  end
end

local function test_every_drawing_reads_back_at_large_versions()
  for _, code in ipairs(codes()) do
    local text = string.rep("q", #assert(Qr.decode(Qr.rows(code))).text)
    assert(assert(Qr.read(Qr.text(code))).text == text, code.version)
    assert(assert(Qr.read(Qr.text(code, { invert = true, quiet = 0 }))).text == text, code.version)
    assert(assert(Qr.read(Qr.svg(code))).text == text, code.version)
  end
end

local function test_text_a_terminal_mangled_still_reads()
  local code = assert(Qr.encode("https://example.com/"))
  -- Spaces dropped at the ends of lines, CRLF, and blank lines around it.
  local drawn = Qr.text(code, { invert = true })
  local mangled = "\n\n" .. drawn:gsub(" +\n", "\n"):gsub("\n", "\r\n") .. "\n  \n"
  assert(assert(Qr.read(mangled)).text == "https://example.com/")
end

local function test_text_copied_indented_or_with_no_break_spaces_still_reads()
  local code = assert(Qr.encode("https://example.com/"))
  local drawings: {Qr.TextOptions} = { {}, { invert = true }, { ascii = true }, { ascii = true, invert = true },
    { quiet = 1 }, { quiet = 0, invert = true } }
  for n, options in ipairs(drawings) do
    local drawn = Qr.text(code, options)
    -- An indent of any width, as a page, a message or a log adds.
    for _, indent in ipairs({ " ", "  ", "   ", "    " }) do
      local indented = drawn:gsub("[^\n]+", function(line: string): string return indent .. line end)
      local read, why = Qr.read(indented)
      assert(read ~= nil and read.text == "https://example.com/", ("drawing %d, indent %d: %s"):format(n, #indent, tostring(why)))
    end
    -- A tab before each line, and spaces after it.
    local tabbed = drawn:gsub("[^\n]+", function(line: string): string
      return "\t" .. line .. "   "
    end)
    local read_tabbed, tabbed_why = Qr.read(tabbed)
    assert(read_tabbed ~= nil and read_tabbed.text == "https://example.com/", ("drawing %d, tabbed: %s"):format(n,
      tostring(tabbed_why)))
    -- Spaces a copy turned into no-break spaces.
    local read, why = Qr.read((drawn:gsub(" ", "\u{a0}")))
    assert(read ~= nil and read.text == "https://example.com/", ("drawing %d, no-break spaces: %s"):format(n, tostring(why)))
  end
end

local function test_color_paints_each_line_dark_on_light_and_reads_back()
  local code = assert(Qr.encode("https://example.com/"))
  for _, ascii in ipairs({ false, true }) do
    local painted = Qr.text(code, { color = true, ascii = ascii })
    -- The characters are those of the inverted drawing, invert or not.
    assert(painted == Qr.text(code, { color = true, ascii = ascii, invert = false }))
    local plain = Qr.text(code, { invert = true, ascii = ascii })
    local lines = 0
    for line in painted:gmatch("([^\n]*)\n") do
      lines = lines + 1
      assert(line:sub(1, 9) == "\27[30;107m" and line:sub(-4) == "\27[0m", line)
    end
    assert(painted:gsub("\27%[[%d;]*m", "") == plain)
    assert(select(2, plain:gsub("\n", "")) == lines)
    assert(assert(Qr.read(painted)).text == "https://example.com/")
    assert(assert(Qr.read((painted:gsub("[^\n]+", "  %0")))).text == "https://example.com/")
    -- Escapes a terminal adds besides colour, such as erase to the end of the line.
    assert(assert(Qr.read((painted:gsub("\n", "\27[K\n")))).text == "https://example.com/")
  end
end

local function test_damage_within_the_level_is_mended_and_past_it_refused()
  local code = assert(Qr.encode("damaged", { level = "H" }))
  local rows = Qr.rows(code, 0)
  -- Version 1 at H: 17 error correction codewords mend 8. A 7 by 7 square
  -- at 10 spoils 8 codewords, and a 9 by 9 square more.
  local function square(n: integer): function(x: integer, y: integer): boolean
    return function(x: integer, y: integer): boolean
      return x >= 10 and x < 10 + n and y >= 10 and y < 10 + n
    end
  end
  local mended = assert(Qr.decode(damaged(rows, square(7))))
  assert(mended.text == "damaged" and mended.corrected == 8, mended.corrected)
  local none, why = Qr.decode(damaged(rows, square(9)))
  assert(none == nil and why.message == "qr: block 1 of the version 1 code at level H has more errors than it can mend", why)
  -- The format information beside the top left finder lost to light.
  local function first_copy(x: integer, y: integer): boolean
    return ((y == 9 and x <= 9 and x ~= 7) or (x == 9 and y <= 8 and y ~= 7)) and assert(rows[y])[x] == true
  end
  local lost = assert(Qr.decode(damaged(rows, first_copy)))
  assert(lost.text == "damaged" and lost.code.mask == code.mask and lost.code.level == "H")
  -- Three bits of each copy wrong.
  local three = assert(Qr.decode(damaged(rows, function(x: integer, y: integer): boolean
    return (x == 9 and y <= 3) or (y == 9 and x >= 19 and x <= 21)
  end)))
  assert(three.text == "damaged" and three.code.mask == code.mask and three.code.level == "H")
  -- Versions whose blocks differ in length: a few modules spoiled in each.
  local mixed: {{integer | string}} = { { 80, "Q" }, { 300, "H" }, { 1000, "M" } }
  for _, case in ipairs(mixed) do
    local n, level = case[1], case[2]
    assert(n is integer and level is Qr.Level)
    local text = string.rep("m", n)
    local big = assert(Qr.encode(text, { level = level }))
    local spoiled = assert(Qr.decode(damaged(Qr.rows(big, 0), function(x: integer, y: integer): boolean
      return (x * 7 + y * 13) % 97 == 0 and x > 9 and y > 9
    end)))
    assert(spoiled.text == text and spoiled.corrected > 0, ("version %d"):format(big.version))
  end
end

local function test_what_is_no_code_is_refused_with_why()
  local code = assert(Qr.encode("x"))
  local cases: {{string}} = {
    { "", "qr: the text draws nothing" },
    { "hello\n", 'qr: line 1 holds "he", where a module is ## or two spaces' },
    { "\u{2588}x\n", "qr: line 1 holds U+0078, which no code draws" },
    { '<svg viewBox="0 0 10 12"></svg>', "qr: the SVG has no square viewBox of a module a unit" },
    { '<svg viewBox="0 0 29 29"><path d="M0,0h3v1h-3zL1,1"/></svg>', "qr: the SVG's path is not the runs of modules Qr.svg draws" },
    { '<svg viewBox="0 0 29 29"><path d="M27,0h3v1h-3z"/></svg>', "qr: the SVG's path holds M27,0h3v1h-3z, which is no run of modules inside it" },
    { "  \n  \n", "qr: the text draws nothing" },
    { "  ##\n####\n", "qr: a code is 21 to 177 modules a side, 4 apart, not 2" },
  }
  for _, case in ipairs(cases) do
    local read, why = Qr.read(case[1] or "")
    assert(read == nil and why.message == case[2], tostring(why))
  end
  local none, why = Qr.decode({ { false, false }, { false, false } })
  assert(none == nil and why.message == "qr: no module is dark", tostring(why))
  local wide, wide_why = Qr.decode({ { true, true, true } })
  assert(wide == nil and wide_why.message == "qr: the dark modules span 3 by 1, not a square", tostring(wide_why))
  -- The format information blanked in both copies leaves no level to read by.
  local blank, blank_why = Qr.decode(damaged(Qr.rows(code, 0), function(x: integer, y: integer): boolean
    return ((y == 9 and (x <= 9 or x >= 14)) or (x == 9 and (y <= 9 or y >= 15))) and
      assert(Qr.rows(code, 0)[y])[x] == true
  end))
  assert(blank == nil and blank_why.message == "qr: the format information is unreadable", tostring(blank_why))
end

--- Benches. A URL encoded to a code, then to an SVG and to text.
local BENCH_URL <const> = "https://example.com/a/path?with=a&query=string&and=more-than-a-few-characters"

local function bench_encode_url(b: Bench.B)
  for _ = 1, b.n do local _ = Qr.encode(BENCH_URL)! end
end

local function bench_svg_url(b: Bench.B)
  local code = Qr.encode(BENCH_URL)!
  b.reset()
  for _ = 1, b.n do local _ = Qr.svg(code) end
end

local function bench_text_url(b: Bench.B)
  local code = Qr.encode(BENCH_URL)!
  b.reset()
  for _ = 1, b.n do local _ = Qr.text(code) end
end
