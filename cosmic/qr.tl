--- QR codes (ISO/IEC 18004 Model 2) for text: [`Qr.encode`] makes one,
--- [`Qr.text`] draws it for a terminal and [`Qr.svg`] draws it as an image.
---
---     local code = assert(Qr.encode("https://example.com/"))
---     print(code.version, code.size)  -- 2  25
---     print(Qr.text(code))            -- half blocks, for a dark terminal
---     print(Qr.svg(code))             -- <svg ... width="264" ...>
---
--- `cosmic qr <text>` does the same from a shell (`cosmic help qr`).
---
--- What it makes: versions 1 to 40 (21 to 177 modules a side), the
--- smallest that holds the text; any of the four error correction
--- levels; and the mask of the lowest penalty, scored as the standard
--- says, unless one is named. The text is put in byte mode, one segment,
--- as its bytes. UTF-8 is carried as it is, with no ECI header: the
--- standard's default for byte mode is ISO-8859-1, but phone cameras
--- and the common readers take valid UTF-8 as UTF-8. Numeric,
--- alphanumeric and kanji modes, ECI, structured append and Micro QR are
--- not made, so a code of digits alone is a little larger than one a
--- mode-switching encoder would make.
---
--- The most a code holds is 2953 bytes at level L, 2331 at M, 1663 at Q
--- and 1273 at H (version 40). More than that, or more than a version a
--- caller allows, is refused with nil and why. A mask outside 0 to 7, a
--- version outside 1 to 40 or a quiet zone or scale out of range is the
--- caller's mistake, and raises.
---
--- A reader needs dark modules on a light ground, with a light quiet
--- zone around the code: four modules wide by the standard, and many
--- readers take less.
---
--- It makes the same code, module for module, as Project Nayuki's QR
--- Code generator, whose algorithm it follows, given the text as one
--- byte segment at the same level, without raising the level, and with
--- the same mask or none named.

local String = require("cosmic.string")

local record Qr
  --- An error correction level: the share of a code's codewords that can
  --- be lost and mended. L about 7%, M 15%, Q 25% and H 30%.
  enum Level
    "L"
    "M"
    "Q"
    "H"
  end

  --- What [`Qr.encode`] may be told.
  record Options
    --- The error correction level (default `"M"`).
    level?: Qr.Level
    --- The mask, 0 to 7, in place of the one of the lowest penalty.
    mask?: integer
    --- The largest version to use (default 40), to keep a code small
    --- enough to read where it is shown: text that needs a larger one is
    --- refused.
    max_version?: integer
  end

  --- What [`Qr.text`] may be told.
  record TextOptions
    --- The light border around the code, in modules (default 4, the
    --- standard's; 0 to 16).
    quiet?: integer
    --- Draw the dark modules with the characters, in place of the light
    --- ones and the quiet zone. Leave it off for a terminal of light text
    --- on a dark ground, the common case: the characters then show the
    --- light modules, and the terminal's ground shows the dark ones. Set
    --- it for a terminal of dark text on a light ground, and for paper.
    invert?: boolean
    --- ASCII alone, for a terminal or a font without block characters:
    --- each module is two characters, `##` or two spaces, and each row a
    --- line, so the code is twice as tall in lines.
    ascii?: boolean
  end

  --- What [`Qr.svg`] may be told. The image is deterministic: the same
  --- code and options give the same bytes.
  record SvgOptions
    --- The light border around the code, in modules (default 4, the
    --- standard's; 0 to 16).
    quiet?: integer
    --- The pixels a module takes in the image's `width` and `height`
    --- (default 8; 1 to 1000). The image scales without blurring either
    --- way: its `viewBox` is a unit a module.
    scale?: integer
    --- The SVG paint of the dark modules (default `"#000"`).
    dark?: string
    --- The SVG paint of the ground (default `"#fff"`); `"none"` leaves
    --- the ground out, transparent. A reader still needs it light.
    light?: string
    --- What the image shows, for a screen reader: an SVG `<title>`
    --- and `aria-label`. None when nil.
    title?: string
  end

  --- A QR code: `size` modules a side, with no quiet zone. [`Qr.dark`]
  --- says which are dark.
  record Code
    --- 1 to 40; `size` is `version * 4 + 17`.
    version: integer
    --- The modules a side, without the quiet zone: what to size a
    --- drawing by. [`Qr.size`] adds a quiet zone.
    size: integer
    --- The error correction level it was drawn at.
    level: Qr.Level
    --- The mask it was drawn with, 0 to 7.
    mask: integer
    --- The modules by `y * size + x` from the top left at 0, true where
    --- dark; a light one may be false or absent. Read it with [`Qr.dark`].
    modules: {integer: boolean}
  end
end

-- By level, then version: error correction codewords per block, and blocks.
local ECC_PER_BLOCK <const>: {Qr.Level: {integer}} = {
  L = { 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30,
    30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
  M = { 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28,
    28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 },
  Q = { 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30,
    30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
  H = { 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30,
    30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
}
local BLOCKS <const>: {Qr.Level: {integer}} = {
  L = { 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18,
    19, 19, 20, 21, 22, 24, 25 },
  M = { 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31,
    33, 35, 37, 38, 40, 43, 45, 47, 49 },
  Q = { 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40,
    43, 45, 48, 51, 53, 56, 59, 62, 65, 68 },
  H = { 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48,
    51, 54, 57, 60, 63, 66, 70, 74, 77, 81 },
}
-- Each level's two bits in the format information.
local FORMAT_LEVEL <const>: {Qr.Level: integer} = { L = 1, M = 0, Q = 3, H = 2 }

--- What a level is drawn with, by version.
local record Shape
  level: Qr.Level
  ecc: {integer}
  blocks: {integer}
  format: integer
end

local function shape(level: Qr.Level): Shape
  local ecc, blocks, format = ECC_PER_BLOCK[level], BLOCKS[level], FORMAT_LEVEL[level]
  if ecc == nil or blocks == nil or format == nil then
    error("qr: the level is L, M, Q or H, not " .. tostring(level), 3)
  end
  return { level = level, ecc = ecc, blocks = blocks, format = format }
end

--- A list of bytes as a map from 1 with its length: what the codec reads
--- and writes in place.
local record Bytes
  n: integer
  at: mut {integer: integer}
end

local function bytes(n: integer): Bytes
  local made: Bytes = { n = n, at = {} }
  for i = 1, n do made.at[i] = 0 end
  return made
end

local function byte_at(b: Bytes, i: integer): integer
  return b.at[i] or 0
end

--- The product of `x` and `y` in GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1.
local function multiply(x: integer, y: integer): integer
  local z = 0
  for i = 7, 0, -1 do
    z = ((z << 1) ~ ((z >> 7) * 0x11D)) & 0xFF
    z = z ~ (((y >> i) & 1) * x)
  end
  return z
end

--- The Reed-Solomon generator of `degree`, without its leading 1: the
--- product of (x - 2^i) for i from 0 to `degree` less 1.
local function divisor(degree: integer): Bytes
  local result = bytes(degree)
  result.at[degree] = 1
  local root = 1
  for _ = 1, degree do
    for j = 1, degree do
      result.at[j] = multiply(byte_at(result, j), root)
      if j < degree then result.at[j] = byte_at(result, j) ~ byte_at(result, j + 1) end
    end
    root = multiply(root, 0x02)
  end
  return result
end

--- The error correction codewords of `data` for the generator `div`.
local function remainder(data: Bytes, div: Bytes): Bytes
  local result = bytes(div.n)
  for k = 1, data.n do
    local factor = byte_at(data, k) ~ byte_at(result, 1)
    for i = 1, div.n - 1 do result.at[i] = byte_at(result, i + 1) end
    result.at[div.n] = 0
    for i = 1, div.n do result.at[i] = byte_at(result, i) ~ multiply(byte_at(div, i), factor) end
  end
  return result
end

--- How many modules of a code of `version` hold data and error correction.
local function raw_modules(version: integer): integer
  local result = (16 * version + 128) * version + 64
  if version >= 2 then
    local align = version // 7 + 2
    result = result - ((25 * align - 10) * align - 55)
    if version >= 7 then result = result - 36 end
  end
  return result
end

local function data_codewords(version: integer, s: Shape): integer
  return raw_modules(version) // 8 - (s.ecc[version] or 0) * (s.blocks[version] or 0)
end

--- The bits of byte mode's character count at `version`.
local function count_bits(version: integer): integer
  return if version <= 9 then 8 else 16 end
end

--- Where the alignment patterns of `version` are centred, on either axis.
local function alignments(version: integer, size: integer): {integer}
  if version == 1 then return {} end
  local count = version // 7 + 2
  local step = (version * 8 + count * 3 + 5) // (count * 4 - 4) * 2
  local result: mut {integer} = { 6 }
  for i = count - 2, 0, -1 do result[#result + 1] = size - 7 - i * step end
  return result
end

--- A code being drawn: its modules, and which belong to function patterns.
local record Grid
  size: integer
  dark: mut {integer: boolean}
  fixed: mut {integer: boolean}
end

local function set(g: Grid, x: integer, y: integer, dark: boolean)
  g.dark[y * g.size + x] = dark
  g.fixed[y * g.size + x] = true
end

local function is_dark(g: Grid, x: integer, y: integer): boolean
  return g.dark[y * g.size + x] == true
end

local function is_fixed(g: Grid, x: integer, y: integer): boolean
  return g.fixed[y * g.size + x] == true
end

--- The format information, the level and the mask with their BCH(15, 5)
--- check and XORed with 101010000010010, drawn twice.
local function format_bits(g: Grid, s: Shape, mask: integer)
  local data = (s.format << 3) | mask
  local rem = data
  for _ = 1, 10 do rem = (rem << 1) ~ ((rem >> 9) * 0x537) end
  local bits = ((data << 10) | rem) ~ 0x5412
  local function bit(i: integer): boolean return ((bits >> i) & 1) ~= 0 end
  for i = 0, 5 do set(g, 8, i, bit(i)) end
  set(g, 8, 7, bit(6))
  set(g, 8, 8, bit(7))
  set(g, 7, 8, bit(8))
  for i = 9, 14 do set(g, 14 - i, 8, bit(i)) end
  for i = 0, 7 do set(g, g.size - 1 - i, 8, bit(i)) end
  for i = 8, 14 do set(g, 8, g.size - 15 + i, bit(i)) end
  set(g, 8, g.size - 8, true)
end

--- The version information of a version 7 or later, with its BCH(18, 6)
--- check, drawn twice.
local function version_bits(g: Grid, version: integer)
  if version < 7 then return end
  local rem = version
  for _ = 1, 12 do rem = (rem << 1) ~ ((rem >> 11) * 0x1F25) end
  local bits = (version << 12) | rem
  for i = 0, 17 do
    local dark = ((bits >> i) & 1) ~= 0
    local a, b = g.size - 11 + i % 3, i // 3
    set(g, a, b, dark)
    set(g, b, a, dark)
  end
end

local function function_patterns(g: Grid, version: integer, s: Shape)
  for i = 0, g.size - 1 do
    set(g, 6, i, i % 2 == 0)
    set(g, i, 6, i % 2 == 0)
  end
  for _, centre in ipairs({ { 3, 3 }, { g.size - 4, 3 }, { 3, g.size - 4 } }) do
    local cx, cy = centre[1] or 0, centre[2] or 0
    for dy = -4, 4 do
      for dx = -4, 4 do
        local x, y = cx + dx, cy + dy
        if x >= 0 and x < g.size and y >= 0 and y < g.size then
          local distance = math.max(math.abs(dx), math.abs(dy))
          set(g, x, y, distance ~= 2 and distance ~= 4)
        end
      end
    end
  end
  local positions = alignments(version, g.size)
  local last = #positions
  for i, px in ipairs(positions) do
    for j, py in ipairs(positions) do
      if not ((i == 1 and j == 1) or (i == 1 and j == last) or (i == last and j == 1)) then
        for dy = -2, 2 do
          for dx = -2, 2 do set(g, px + dx, py + dy, math.max(math.abs(dx), math.abs(dy)) ~= 1) end
        end
      end
    end
  end
  -- Reserved here so the codewords go around it; drawn for the mask later.
  format_bits(g, s, 0)
  version_bits(g, version)
end

--- `data`'s bits into the modules no pattern holds, in two-column strips
--- from the right, zigzagging up and down, skipping the vertical timing
--- column. The remainder bits stay light.
local function codewords(g: Grid, data: Bytes)
  local i = 0
  local total = data.n * 8
  local right = g.size - 1
  while right >= 1 do
    if right == 6 then right = 5 end
    for vertical = 0, g.size - 1 do
      for j = 0, 1 do
        local x = right - j
        local upward = ((right + 1) & 2) == 0
        local y = if upward then g.size - 1 - vertical else vertical end
        if not is_fixed(g, x, y) and i < total then
          g.dark[y * g.size + x] = ((byte_at(data, (i >> 3) + 1) >> (7 - (i & 7))) & 1) ~= 0
          i = i + 1
        end
      end
    end
    right = right - 2
  end
end

local function masked(mask: integer, x: integer, y: integer): boolean
  if mask == 0 then return (x + y) % 2 == 0 end
  if mask == 1 then return y % 2 == 0 end
  if mask == 2 then return x % 3 == 0 end
  if mask == 3 then return (x + y) % 3 == 0 end
  if mask == 4 then return (x // 3 + y // 2) % 2 == 0 end
  if mask == 5 then return x * y % 2 + x * y % 3 == 0 end
  if mask == 6 then return (x * y % 2 + x * y % 3) % 2 == 0 end
  return ((x + y) % 2 + x * y % 3) % 2 == 0
end

--- Flips the data modules `mask` selects; a second call undoes the first.
local function apply_mask(g: Grid, mask: integer)
  for y = 0, g.size - 1 do
    for x = 0, g.size - 1 do
      if not is_fixed(g, x, y) and masked(mask, x, y) then
        g.dark[y * g.size + x] = not is_dark(g, x, y)
      end
    end
  end
end

--- The penalty of the code as it stands, by the standard's four rules:
--- runs of five or more, two by two blocks, the 1:1:3:1:1 finder-like
--- pattern with four light modules on a side (the quiet zone counting as
--- light), and the balance of dark and light.
local function penalty(g: Grid): integer
  local n = g.size
  local score = 0
  -- The lengths of the last seven runs in a line, the newest first.
  local history: mut {integer: integer} = {}
  local function h(i: integer): integer return history[i] or 0 end
  local function push(length: integer)
    if h(1) == 0 then length = length + n end -- the quiet zone before the line
    for i = 7, 2, -1 do history[i] = h(i - 1) end
    history[1] = length
  end
  -- How many finder-like patterns end at the light run just pushed: 0 to 2.
  local function finders(): integer
    local w = h(2)
    local core = w > 0 and h(3) == w and h(5) == w and h(6) == w and h(4) == w * 3
    if not core then return 0 end
    return (if h(1) >= w * 4 and h(7) >= w then 1 else 0 end) + (if h(7) >= w * 4 and h(1) >= w then 1 else 0 end)
  end
  for pass = 1, 2 do
    for a = 0, n - 1 do
      for i = 1, 7 do history[i] = 0 end
      local colour, run = false, 0
      for b = 0, n - 1 do
        local here = if pass == 1 then is_dark(g, b, a) else is_dark(g, a, b) end
        if here == colour then
          run = run + 1
          if run == 5 then score = score + 3 elseif run > 5 then score = score + 1 end
        else
          push(run)
          if not colour then score = score + finders() * 40 end
          colour, run = here, 1
        end
      end
      -- The quiet zone after the line ends it with a light run.
      if colour then
        push(run)
        run = 0
      end
      push(run + n)
      score = score + finders() * 40
    end
  end
  local dark = 0
  for y = 0, n - 1 do
    for x = 0, n - 1 do
      local c = is_dark(g, x, y)
      if c then dark = dark + 1 end
      if x < n - 1 and y < n - 1 and is_dark(g, x + 1, y) == c and is_dark(g, x, y + 1) == c and
          is_dark(g, x + 1, y + 1) == c then
        score = score + 3
      end
    end
  end
  -- The smallest k for which dark/total is within (50 ± 5(k + 1))%.
  local total = n * n
  local k = (math.abs(dark * 20 - total * 10) + total - 1) // total - 1
  return score + k * 10
end

--- `data` split into blocks, each followed by its error correction, and
--- the blocks' codewords interleaved.
local function interleave(data: Bytes, version: integer, s: Shape): Bytes
  local blocks_n, ecc_len = s.blocks[version] or 1, s.ecc[version] or 0
  local raw = raw_modules(version) // 8
  local short_blocks = blocks_n - raw % blocks_n
  local short_len = raw // blocks_n
  local div = divisor(ecc_len)
  -- Each block at the long length, a short one with a gap before its ECC.
  local blocks: mut {integer: Bytes} = {}
  local k = 1
  for i = 0, blocks_n - 1 do
    local length = short_len - ecc_len + (if i < short_blocks then 0 else 1 end)
    local block = bytes(length)
    for j = 1, length do block.at[j] = byte_at(data, k + j - 1) end
    k = k + length
    local ecc = remainder(block, div)
    local whole = bytes(short_len + 1)
    for j = 1, length do whole.at[j] = byte_at(block, j) end
    local at = length + (if i < short_blocks then 1 else 0 end)
    for j = 1, ecc.n do whole.at[at + j] = byte_at(ecc, j) end
    blocks[i + 1] = whole
  end
  local all = bytes(raw)
  local placed = 0
  for i = 1, short_len + 1 do
    for j = 1, blocks_n do
      if i ~= short_len - ecc_len + 1 or j > short_blocks then
        local block = blocks[j]
        placed = placed + 1
        all.at[placed] = if block ~= nil then byte_at(block, i) else 0 end
      end
    end
  end
  return all
end

--- The QR code of `text`'s bytes and "", or nil and why where no
--- allowed version holds them at the level.
function Qr.encode(text: string, options?: Qr.Options): Qr.Code?, string
  local level: Qr.Level = options and options.level or "M"
  local s = shape(level)
  local mask = options and options.mask
  if mask ~= nil and (math.type(mask) ~= "integer" or mask < 0 or mask > 7) then
    error("qr: a mask is 0 to 7, not " .. tostring(mask), 2)
  end
  local max_version = options and options.max_version or 40
  if math.type(max_version) ~= "integer" or max_version < 1 or max_version > 40 then
    error("qr: a version is 1 to 40, not " .. tostring(max_version), 2)
  end
  local version = 0
  for v = 1, max_version do
    if 4 + count_bits(v) + #text * 8 <= data_codewords(v, s) * 8 then
      version = v
      break
    end
  end
  if version == 0 then
    local most = (data_codewords(max_version, s) * 8 - 4 - count_bits(max_version)) // 8
    return nil, ("qr: the text is %s, and a version %d code at level %s holds %d"):format(
      String.counted(#text, "byte"), max_version, level, most)
  end
  -- The bits: byte mode, the count, the bytes, a terminator, and padding.
  local capacity = data_codewords(version, s)
  local data = bytes(capacity)
  local nbits = 0
  local function put(value: integer, length: integer)
    for i = length - 1, 0, -1 do
      local at = (nbits >> 3) + 1
      data.at[at] = byte_at(data, at) | (((value >> i) & 1) << (7 - (nbits & 7)))
      nbits = nbits + 1
    end
  end
  put(4, 4)
  put(#text, count_bits(version))
  for i = 1, #text do put(text:byte(i) or 0, 8) end
  put(0, math.min(4, capacity * 8 - nbits))
  put(0, (8 - nbits % 8) % 8)
  local pad = 0xEC
  for i = nbits // 8 + 1, capacity do
    data.at[i] = pad
    pad = if pad == 0xEC then 0x11 else 0xEC end
  end
  -- Draw it, and keep the named mask or the one of the lowest penalty.
  local size = version * 4 + 17
  local g: Grid = { size = size, dark = {}, fixed = {} }
  function_patterns(g, version, s)
  codewords(g, interleave(data, version, s))
  if mask == nil then
    local best, best_score = 0, math.maxinteger
    for m = 0, 7 do
      apply_mask(g, m)
      format_bits(g, s, m)
      local score = penalty(g)
      if score < best_score then best, best_score = m, score end
      apply_mask(g, m)
    end
    mask = best
  end
  apply_mask(g, mask)
  format_bits(g, s, mask)
  return { version = version, size = size, level = level, mask = mask, modules = g.dark }, ""
end

--- Whether the module at `x`, `y` of `code` (from the top left, at 0)
--- is dark. One outside the code is light, as its quiet zone is.
function Qr.dark(code: Qr.Code, x: integer, y: integer): boolean
  if x < 0 or y < 0 or x >= code.size or y >= code.size then return false end
  return code.modules[y * code.size + x] == true
end

--- The modules a side of `code` with a quiet zone of `quiet` modules
--- around it (default 4): the side of what [`Qr.svg`] draws, and of
--- what [`Qr.text`] draws in characters.
function Qr.size(code: Qr.Code, quiet?: integer): integer
  return code.size + 2 * (quiet or 4)
end

--- `value`, which must be an integer from `lo` to `hi`, or `default`
--- where nil; a caller's mistake raises.
local function bounded(value: integer?, default: integer, lo: integer, hi: integer, what: string): integer
  if value == nil then return default end
  if math.type(value) ~= "integer" or value < lo or value > hi then
    error(("qr: %s is %d to %d, not %s"):format(what, lo, hi, tostring(value)), 3)
  end
  return value
end

-- The half blocks by what each half of a cell shows: ink above, ink below.
local HALVES <const>: {string} = { " ", "\u{2584}", "\u{2580}", "\u{2588}" }

--- `code` as text for a terminal, each line ended by a newline. Each
--- character holds two rows of modules, with the half blocks `▀`, `▄`
--- and `█` and a space, so the code is about square in most fonts; a
--- last row alone has nothing below it. The quiet zone is drawn too.
--- Without `invert`, the characters show the light modules, for a dark
--- terminal ([`Qr.TextOptions`] says which to choose).
function Qr.text(code: Qr.Code, options?: Qr.TextOptions): string
  local quiet = bounded(options and options.quiet, 4, 0, 16, "a quiet zone")
  local invert = options ~= nil and options.invert == true
  local side = Qr.size(code, quiet)
  -- Whether a module of the drawing, quiet zone and all, takes ink.
  local function ink(x: integer, y: integer): boolean
    if y >= side then return false end
    return Qr.dark(code, x - quiet, y - quiet) == invert
  end
  local lines: mut {string} = {}
  if options ~= nil and options.ascii == true then
    for y = 0, side - 1 do
      local line: mut {string} = {}
      for x = 0, side - 1 do line[#line + 1] = if ink(x, y) then "##" else "  " end end
      lines[#lines + 1] = table.concat(line) .. "\n"
    end
  else
    for y = 0, side - 1, 2 do
      local line: mut {string} = {}
      for x = 0, side - 1 do
        line[#line + 1] = HALVES[(if ink(x, y) then 2 else 0 end) + (if ink(x, y + 1) then 1 else 0 end) + 1] or " "
      end
      lines[#lines + 1] = table.concat(line) .. "\n"
    end
  end
  return table.concat(lines)
end

local ESCAPES <const>: {string: string} = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }

local function attribute(value: string): string
  return (value:gsub('[&<>"]', ESCAPES))
end

--- `code` as an SVG image with its quiet zone, `width` and `height` in
--- pixels and a `viewBox` of a unit a module, so it shows at a size a
--- reader can take and scales without blurring. The dark modules are one
--- path, a rectangle for each run of them in a row, drawn with crisp
--- edges. Each paint and the title are escaped for where they go.
function Qr.svg(code: Qr.Code, options?: Qr.SvgOptions): string
  local quiet = bounded(options and options.quiet, 4, 0, 16, "a quiet zone")
  local scale = bounded(options and options.scale, 8, 1, 1000, "a scale")
  local dark = options and options.dark or "#000"
  local light = options and options.light or "#fff"
  local title = options and options.title
  local side = Qr.size(code, quiet)
  local path: mut {string} = {}
  for y = 0, code.size - 1 do
    local x = 0
    while x < code.size do
      if Qr.dark(code, x, y) then
        local run = 1
        while Qr.dark(code, x + run, y) do run = run + 1 end
        path[#path + 1] = ("M%d,%dh%dv1h-%dz"):format(x + quiet, y + quiet, run, run)
        x = x + run
      else
        x = x + 1
      end
    end
  end
  local parts: mut {string} = {
    ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" ' ..
      'shape-rendering="crispEdges"'):format(side * scale, side * scale, side, side),
  }
  if title ~= nil then
    parts[#parts + 1] = (' role="img" aria-label="%s"><title>%s</title>'):format(attribute(title), attribute(title))
  else
    parts[#parts + 1] = ">"
  end
  if light ~= "none" then
    parts[#parts + 1] = ('<rect width="100%%" height="100%%" fill="%s"/>'):format(attribute(light))
  end
  parts[#parts + 1] = ('<path d="%s" fill="%s"/>'):format(table.concat(path), attribute(dark))
  parts[#parts + 1] = "</svg>"
  return table.concat(parts)
end

return Qr
