--- MIME base64 decoding, as an email attachment carries it: `bin/cosmic bench/base64.tl [name...]`.
--- Follows Lemire, "Decoding base64 email attachments" (2026-11-20): one MiB of random bytes, encoded as base64 in
--- lines of 76 characters that end in CRLF (1.43 MB of text, the post's 1.37 MiB), decoded and checked. Each case
--- keeps the best of ten timed decodes and prints it, and the median, in GB/s of input text. It measures; it gates
--- nothing, and no test reads its numbers. The post's table runs from 0.61 GB/s (PHP 8.5) to 18.4 GB/s (C++ with
--- simdutf) on one Xeon Gold 6548N core; Go is 1.6, Java 1.2, Zig 0.85.
local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Rand = require("cosmic.rand")

local LINE <const> = 76

--- `text` broken into lines of `LINE` characters, each ending in CRLF, as RFC 2045 writes a base64 body.
local function wrapped(text: string): string
  local lines: mut {string} = {}
  for i = 1, #text, LINE do lines[#lines + 1] = text:sub(i, i + LINE - 1) end
  return table.concat(lines, "\r\n") .. "\r\n"
end

local bytes = Rand.new(2026):bytes(1024 * 1024)
local flat = Codec.base64(bytes)
local body = wrapped(flat)

local record Case
  name: string
  input: string
  decode: function(text: string): string
  expect: string
end

local cases: {Case} = {
  -- The decoder for text in lines: the core skips the line breaks itself.
  { name = "mime unbase64_lines", input = body,
    expect = bytes, decode = function(text: string): string
      return assert(Codec.unbase64_lines(text))
    end },
  -- The way cosmic.acme and cosmic.key decode a wrapped body: strip whitespace, then decode.
  { name = "mime strip %s + unbase64", input = body,
    expect = bytes, decode = function(text: string): string
      return assert(Codec.unbase64((text:gsub("%s", ""))))
    end },
  -- The same with only the CRLF line endings stripped.
  { name = "mime strip CRLF + unbase64", input = body,
    expect = bytes, decode = function(text: string): string
      return assert(Codec.unbase64((text:gsub("\r\n", ""))))
    end },
  -- The strip alone, to split the cost of the two steps above.
  { name = "mime strip %s only", input = body,
    expect = flat, decode = function(text: string): string return (text:gsub("%s", "")) end },
  -- The same bytes with no line endings: the decoder's own speed, the post's "without line endings" case.
  { name = "flat unbase64", input = flat,
    expect = bytes, decode = function(text: string): string return assert(Codec.unbase64(text)) end },
}

--- Times ten decodes of `c.input`, after one checked against `c.expect`, and prints the best and the median in GB/s.
local function measure(c: Case)
  assert(c.decode(c.input) == c.expect, c.name .. " returned the wrong result")
  local rates: mut {number} = {}
  for i = 1, 10 do
    collectgarbage("collect")
    local start = Clock.monotonic_ns()
    c.decode(c.input)
    rates[i] = #c.input / (Clock.monotonic_ns() - start)
  end
  table.sort(rates, function(a: number, b: number): boolean return a > b end)
  print(string.format("%-28s %8.3f GB/s  (median %.3f, input %d bytes)", c.name, assert(rates[1]),
    ((assert(rates[5]) + assert(rates[6])) / 2), #c.input))
end

local wanted: mut {string: boolean} = {}
for _, name in ipairs(arg) do wanted[name] = true end
for _, c in ipairs(cases) do
  local selected = next(wanted) == nil
  for name in pairs(wanted) do
    if c.name:find(name, 1, true) ~= nil then selected = true end
  end
  if selected then measure(c) end
end
