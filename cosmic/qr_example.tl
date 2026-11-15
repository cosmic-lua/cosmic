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
  assert(small == nil and why == "qr: 100 bytes are more than a version 5 code holds at level H (44)")
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

--- An image for a page: an SVG with the quiet zone included, which
--- scales without blurring.
function Example.svg()
  local code = assert(Qr.encode("https://example.com/"))
  local svg = Qr.svg(code, "#101418", "#ffffff")
  print(svg:sub(1, 90))
  assert(svg:find('viewBox="0 0 33 33"', 1, true) ~= nil)
end

return Example
