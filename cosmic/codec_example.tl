--- Worked examples for `cosmic.codec`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Codec = require("cosmic.codec")

local Example = {}

--- Bytes as lowercase hex, and back again from either case.
function Example.hex()
  local text = Codec.hex("\x00\xffok")
  print(text)
  assert(text == "00ff6f6b", "unexpected hex: " .. text)
  assert(Codec.unhex("00FF6F6B") == "\x00\xffok")
end

--- Malformed hex is a failure the caller handles, not a raise: the
--- decoder answers `nil` and why.
function Example.unhex()
  local bytes, why = Codec.unhex("abc")
  print(why)
  assert(bytes == nil and why == "codec: hex text of odd length 3", why)
end

--- Standard base64 pads to a multiple of four characters; the strict
--- decoder takes back exactly what the encoder writes.
function Example.base64()
  local text = Codec.base64("cosmic")
  print(text)
  assert(text == "Y29zbWlj", "unexpected base64: " .. text)
  assert(Codec.unbase64(Codec.base64("hi")) == "hi")
end

--- Line breaks are not base64: text wrapped into lines, as MIME
--- writes it, is refused until the breaks are taken out.
function Example.unbase64()
  local wrapped = "aGVsbG8g\nd29ybGQ="
  local bytes, why = Codec.unbase64(wrapped)
  print(why)
  assert(bytes == nil)
  assert(Codec.unbase64((wrapped:gsub("\n", ""))) == "hello world")
end

--- The URL-safe alphabet without padding, as JSON Web Tokens use it.
function Example.base64url()
  local text = Codec.base64url("\xfb\xff?")
  print(text)
  assert(text == "-_8_", "unexpected base64url: " .. text)
  assert(Codec.unbase64url(text) == "\xfb\xff?")
end

return Example
