--- MIME base64 decoding, as an email attachment carries it: `bin/cosmic bench/base64.tl [name...]`.
--- Follows Lemire, "Decoding base64 email attachments" (2026-11-20): one MiB of random bytes, encoded as base64 in
--- lines of 76 characters that end in CRLF (1.43 MB of text, the post's 1.37 MiB), decoded and checked once.
--- [`bench.harness`] times each case and prints its rate in GB/s of input text beside its time. A batch runs its
--- decodes back to back after one collection, so their garbage is part of the time. The post's table
--- runs from 0.61 GB/s (PHP 8.5) to 18.4 GB/s (C++ with simdutf) on one Xeon Gold 6548N core; Go is 1.6, Java 1.2,
--- Zig 0.85.
local Bench = require("bench.harness")
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

local bench = Bench.new("base64")

--- A case that decodes `input` with `decode`, checked once against `expect` before it is timed.
local function decoder(name: string, input: string, expect: string, decode: function(text: string): string)
  bench.case(name, function(n: integer)
    for _ = 1, n do decode(input) end
  end, { bytes = #input, setup = function()
    assert(decode(input) == expect, name .. " returned the wrong result")
  end })
end

-- The decoder for text in lines: the core skips the line breaks itself.
decoder("mime unbase64_lines", body, bytes, function(text: string): string
  return assert(Codec.unbase64_lines(text))
end)
-- The way cosmic.acme and cosmic.key decode a wrapped body: strip whitespace, then decode.
decoder("mime strip %s + unbase64", body, bytes, function(text: string): string
  return assert(Codec.unbase64((text:gsub("%s", ""))))
end)
-- The same with only the CRLF line endings stripped.
decoder("mime strip CRLF + unbase64", body, bytes, function(text: string): string
  return assert(Codec.unbase64((text:gsub("\r\n", ""))))
end)
-- The strip alone, to split the cost of the two steps above.
decoder("mime strip %s only", body, flat, function(text: string): string
  return (text:gsub("%s", ""))
end)
-- The same bytes with no line endings: the decoder's own speed, the post's "without line endings" case.
decoder("flat unbase64", flat, bytes, function(text: string): string
  return assert(Codec.unbase64(text))
end)

return function(argv: {string}): integer return bench.main(argv) end
