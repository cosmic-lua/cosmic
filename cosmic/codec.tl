--- Byte-to-text encodings: hexadecimal and base64 (RFC 4648), in pure
--- Teal. Encoders take any bytes. Decoders are strict and total: text
--- that no encoder here would write -- a character outside the
--- alphabet, a bad length, misplaced padding, or nonzero trailing bits
--- -- answers `nil` and a reason rather than a guess, so every string a
--- decoder accepts encodes back to exactly itself.
---
--- - [`Codec.hex`] and [`Codec.unhex`]: lower-case hex, the way to show a
---   digest or a key. The decoder reads either case.
--- - [`Codec.base64`] and [`Codec.unbase64`]: the standard alphabet, padded,
---   for data in text formats and headers.
--- - [`Codec.base64url`] and [`Codec.unbase64url`]: the URL- and
---   filename-safe alphabet, unpadded, for tokens and file names.
---
--- Every function takes and answers a whole string. The `cosmic codec`
--- verb streams the same encodings for input too large for one.
---
---     local text = Codec.base64("hello")      -- "aGVsbG8="
---     local bytes = assert(Codec.unbase64(text))

local String = require("cosmic.string")

local record Codec
end

--- What a failure of this module answers, nil and `why` under the
--- module's name.
local function refuse(why: string): nil, string
  return nil, "codec: " .. why
end

--- Every byte's two lowercase hex digits, by the byte: `gsub` takes the
--- table as its replacement, one lookup per byte.
local hex_of: mut {string:string} = {}
--- Every pair of hex digits, either case, to the byte it spells.
local byte_of_hex: mut {string:string} = {}
do
  local digits = "0123456789abcdef"
  local upper = "0123456789ABCDEF"
  for byte = 0, 255 do
    local hi, lo = (byte >> 4) + 1, (byte & 15) + 1
    local ch = string.char(byte)
    hex_of[ch] = digits:sub(hi, hi) .. digits:sub(lo, lo)
    for _, h in ipairs({ digits:sub(hi, hi), upper:sub(hi, hi) }) do
      for _, l in ipairs({ digits:sub(lo, lo), upper:sub(lo, lo) }) do
        byte_of_hex[h .. l] = ch
      end
    end
  end
end

--- Bytes as lowercase hexadecimal, two digits per byte.
--- @param s string The bytes to encode
--- @return string Twice as many hex digits
function Codec.hex(s: string): string
  return (s:gsub(".", hex_of))
end

--- The bytes hexadecimal text spells, reading either case. Answers
--- `nil` and a reason for an odd number of digits or a character that
--- is not a hex digit.
--- @param s string The hex text
--- @return string | nil The decoded bytes, half as many
--- @return string Why the text was refused, or "" when it was not
function Codec.unhex(s: string): string?, string
  if #s % 2 ~= 0 then
    return refuse(("hex text of odd length %d"):format(#s))
  end
  local at = s:find("[^0-9a-fA-F]")
  if at ~= nil then
    return refuse(("byte 0x%02x at %d is not a hex digit"):format(String.byte_at(s, at), at))
  end
  return (s:gsub("..", byte_of_hex)), ""
end

--- One base64 alphabet's tables: `char` maps a 6-bit value to its
--- character, `pair` a 12-bit value to its two characters, `value` a
--- character's byte to its 6-bit value, and `class` is a pattern
--- matching any character outside the alphabet.
local record Alphabet
  char: mut {integer:string}
  pair: mut {integer:string}
  value: mut {integer:integer}
  class: string
end

local function alphabet(chars: string, class: string): Alphabet
  local a: Alphabet = { char = {}, pair = {}, value = {}, class = class }
  for i = 1, 64 do
    a.char[i - 1] = chars:sub(i, i)
    a.value[String.byte_at(chars, i)] = i - 1
  end
  for v = 0, 4095 do
    a.pair[v] = a.char[v >> 6] .. a.char[v & 63]
  end
  return a
end

local STANDARD <const> = alphabet(
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", "[^A-Za-z0-9+/]")
local URL <const> = alphabet(
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_", "[^A-Za-z0-9_-]")

--- `s` in `a`'s alphabet, `=`-padded to a multiple of four characters
--- when `pad`.
local function encode(a: Alphabet, s: string, pad: boolean): string
  local pair = a.pair
  local out: mut {string} = {}
  local n = #s
  local whole = n - n % 3
  for i = 1, whole, 3 do
    local b1, b2, b3 = s:byte(i, i + 2)
    local v = (b1 << 16) | (b2 << 8) | b3
    local first, second = assert(pair[v >> 12]), assert(pair[v & 4095])
    out[#out + 1] = first
    out[#out + 1] = second
  end
  local left = n - whole
  if left == 1 then
    local v = String.byte_at(s, n) << 4
    local first = assert(pair[v])
    out[#out + 1] = first
    if pad then out[#out + 1] = "==" end
  elseif left == 2 then
    local v = (String.byte_at(s, n - 1) << 10) | (String.byte_at(s, n) << 2)
    local first, second = assert(pair[v >> 6]), assert(a.char[v & 63])
    out[#out + 1] = first
    out[#out + 1] = second
    if pad then out[#out + 1] = "=" end
  end
  return table.concat(out)
end

--- Characters of base64 decoded per `string.char` call: a multiple of
--- four, and few enough bytes to pass as arguments.
local BATCH <const> = 4096

--- Appends to `out` the bytes the first `whole` characters of `s` spell
--- (a multiple of four, all in the alphabet whose values are `value`).
--- Bytes gather in a buffer and leave a batch at a time through one
--- `string.char`: a string per group would intern millions of them.
local function expand(value: {integer:integer}, s: string, whole: integer, out: mut {string})
  for first = 1, whole, BATCH do
    local buf: mut {integer} = {}
    local last = math.min(first + BATCH - 1, whole)
    for i = first, last, 4 do
      local c1, c2, c3, c4 = s:byte(i, i + 3)
      local v = (value[c1] << 18) | (value[c2] << 12) | (value[c3] << 6) | value[c4]
      buf[#buf + 1] = v >> 16
      buf[#buf + 1] = (v >> 8) & 255
      buf[#buf + 1] = v & 255
    end
    local chunk = string.char(table.unpack(buf))
    out[#out + 1] = chunk
  end
end

--- The bytes `s` spells in `a`'s alphabet. `padded` says whether `s`
--- must carry `=` padding to a multiple of four characters or must
--- carry none.
local function decode(a: Alphabet, s: string, padded: boolean, name: string): string?, string
  local n = #s
  if padded then
    if n % 4 ~= 0 then
      return refuse(("%s text of length %d, not a multiple of 4"):format(name, n))
    end
    if s:sub(-2) == "==" then
      n = n - 2
    elseif s:sub(-1) == "=" then
      n = n - 1
    end
  elseif n % 4 == 1 then
    return refuse(("%s text of length %d leaves one character over"):format(name, n))
  end
  local at = s:find(a.class)
  if at ~= nil and at <= n then
    if s:byte(at) == 61 then
      return refuse(("%s text has misplaced '=' padding at %d"):format(name, at))
    end
    return refuse(("byte 0x%02x at %d is outside the %s alphabet"):format(String.byte_at(s, at), at, name))
  end
  local value = a.value
  local out: mut {string} = {}
  local whole = n - n % 4
  expand(value, s, whole, out)
  local left = n - whole
  if left == 2 then
    local c1, c2 = s:byte(n - 1, n)
    local v = (value[c1] << 6) | value[c2]
    if v & 15 ~= 0 then
      return refuse(("%s text ends in nonzero padding bits"):format(name))
    end
    local last = string.char(v >> 4)
    out[#out + 1] = last
  elseif left == 3 then
    local c1, c2, c3 = s:byte(n - 2, n)
    local v = (value[c1] << 12) | (value[c2] << 6) | value[c3]
    if v & 3 ~= 0 then
      return refuse(("%s text ends in nonzero padding bits"):format(name))
    end
    local last = string.char(v >> 10, (v >> 2) & 255)
    out[#out + 1] = last
  end
  return table.concat(out), ""
end

--- Bytes as base64 in the standard alphabet (`A-Z a-z 0-9 + /`),
--- `=`-padded to a multiple of four characters, with no line breaks.
--- @param s string The bytes to encode
--- @return string The base64 text
function Codec.base64(s: string): string
  return encode(STANDARD, s, true)
end

--- The bytes standard, padded base64 spells. Strict: answers `nil` and
--- a reason for a length that is not a multiple of four, a character
--- outside the alphabet (whitespace and line breaks included), `=`
--- anywhere but the last one or two places, or a last character whose
--- unused bits are not zero.
--- @param s string The base64 text
--- @return string | nil The decoded bytes
--- @return string Why the text was refused, or "" when it was not
function Codec.unbase64(s: string): string?, string
  return decode(STANDARD, s, true, "base64")
end

--- Bytes as unpadded base64 in the URL- and filename-safe alphabet
--- (`-` and `_` in place of `+` and `/`), the form JSON Web Tokens use.
--- @param s string The bytes to encode
--- @return string The base64url text, without `=` padding
function Codec.base64url(s: string): string
  return encode(URL, s, false)
end

--- The bytes unpadded base64url spells. Strict like [`Codec.unbase64`],
--- and refuses `=` padding: answers `nil` and a reason for a length
--- that leaves one character over, a character outside the alphabet,
--- or a last character whose unused bits are not zero.
--- @param s string The base64url text
--- @return string | nil The decoded bytes
--- @return string Why the text was refused, or "" when it was not
function Codec.unbase64url(s: string): string?, string
  return decode(URL, s, false, "base64url")
end

return Codec
