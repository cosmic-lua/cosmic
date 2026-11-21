--- What the tests of [`cosmic.qr`] read back from a code (cosmic/qr_test.tl
--- and cosmic/qr_fuzz_test.tl). Test support.

local Qr = require("cosmic.qr")

local record qr_fixture
end

--- Whether a finder pattern of `code` has its top left at `x`, `y`: a
--- dark ring, a light ring and a dark three by three.
local function finder(code: Qr.Code, x: integer, y: integer): boolean
  for dy = 0, 6 do
    for dx = 0, 6 do
      local ring = math.max(math.abs(dx - 3), math.abs(dy - 3))
      if Qr.dark(code, x + dx, y + dy) ~= (ring ~= 2) then return false end
    end
  end
  return true
end

--- Whether `code` has its three finder patterns.
function qr_fixture.finders(code: Qr.Code): boolean
  local far = code.size - 7
  return finder(code, 0, 0) and finder(code, far, 0) and finder(code, 0, far)
end

--- The five data bits of the format information in the top left, the
--- level's two and the mask's three, read back through its fixed XOR,
--- past the timing modules.
function qr_fixture.format(code: Qr.Code): integer
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

return qr_fixture
