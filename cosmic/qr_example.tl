--- Worked examples for [`cosmic.qr`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Qr = require("cosmic.qr")

local record Example end

--- A code of an address, at the default level M: the smallest version
--- that holds it, and the mask of the lowest penalty. Text past what a
--- version allows is refused, not raised.
function Example.encode()
  local code = assert(Qr.encode("https://example.com/"))
  print(code.version, code.size, code.level, code.mask)
  assert(code.version == 2 and code.size == 25 and code.level == "M")

  local small, why = Qr.encode(string.rep("a", 100), { level = "H", max_version = 5 })
  print(small, why)
  assert(small == nil and why == "qr: the text is 100 bytes, and a version 5 code at level H holds 44")
end

--- UTF-8 goes in as its bytes, which is how phones read it back. Every
--- module outside the code is light: its quiet zone, drawn here.
function Example.dark()
  local code = assert(Qr.encode("café ☕", { level = "Q" }))
  local lines: mut {string} = {}
  for y = -1, code.size do
    local line: mut {string} = {}
    for x = -1, code.size do line[#line + 1] = if Qr.dark(code, x, y) then "##" else "  " end end
    lines[#lines + 1] = table.concat(line)
  end
  print(table.concat(lines, "\n"))
  assert(#lines == code.size + 2 and Qr.dark(code, 0, 0) and not Qr.dark(code, -1, 0))
end

--- A code for a terminal: half blocks, two rows of modules a line, with
--- the quiet zone. Left as it is, it suits light text on a dark ground;
--- `invert` suits dark text on a light ground, and `ascii` a terminal with
--- no block characters. [`Qr.size`] is the side drawn, in modules.
function Example.text()
  local code = assert(Qr.encode("https://example.com/"))
  local text = Qr.text(code)
  print(text)
  local side = Qr.size(code)
  local _, lines = text:gsub("\n", "")
  assert(side == 33 and lines == (side + 1) // 2)

  local small = Qr.text(code, { quiet = 1, invert = true, ascii = true })
  local _, rows = small:gsub("\n", "")
  assert(rows == Qr.size(code, 1))
  assert(small:sub(1, 2) == "  " and small:find("##", 1, true) ~= nil)
end

--- An image for a page: an SVG with the quiet zone included, 8 pixels a
--- module unless `scale` says otherwise, which scales without blurring.
--- The title is what a screen reader says.
function Example.svg()
  local code = assert(Qr.encode("https://example.com/"))
  local svg = Qr.svg(code, { scale = 4, dark = "#101418", light = "none", title = "example.com" })
  print(svg:sub(1, 120))
  assert(svg:find('width="132" height="132" viewBox="0 0 33 33"', 1, true) ~= nil)
  assert(svg:find("<rect", 1, true) == nil and svg:find("<title>example.com</title>", 1, true) ~= nil)
end

return Example
