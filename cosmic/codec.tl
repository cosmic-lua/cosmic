--- Byte-to-text encodings: hexadecimal and base64 (RFC 4648), in pure
--- Teal. Encoders take any bytes. Decoders are strict and total: text
--- that no encoder here would write -- a character outside the
--- alphabet, a bad length, misplaced padding, or nonzero trailing bits
--- -- answers `nil` and a reason rather than a guess, so every string a
--- decoder accepts encodes back to exactly itself.

local record Codec
end

--- Every byte's two lowercase hex digits, by the byte: `gsub` takes the
--- table as its replacement, one lookup per byte.
local hex_of: {string:string} = {}
--- Every pair of hex digits, either case, to the byte it spells.
local byte_of_hex: {string:string} = {}
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
function Codec.unhex(s: string): string | nil, string
  if #s % 2 ~= 0 then
    return nil, ("codec: hex text of odd length %d"):format(#s)
  end
  local at = s:find("[^0-9a-fA-F]")
  if at ~= nil then
    return nil, ("codec: byte 0x%02x at %d is not a hex digit"):format(s:byte(at), at)
  end
  return (s:gsub("..", byte_of_hex)), ""
end

--- One base64 alphabet's tables: `char` maps a 6-bit value to its
--- character, `pair` a 12-bit value to its two characters, `value` a
--- character's byte to its 6-bit value, and `class` is a pattern
--- matching any character outside the alphabet.
local record Alphabet
  char: {integer:string}
  pair: {integer:string}
  value: {integer:integer}
  class: string
end

local function alphabet(chars: string, class: string): Alphabet
  local a: Alphabet = { char = {}, pair = {}, value = {}, class = class }
  for i = 1, 64 do
    a.char[i - 1] = chars:sub(i, i)
    a.value[chars:byte(i)] = i - 1
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
  local out: {string} = {}
  local n = #s
  local k = 0
  local whole = n - n % 3
  for i = 1, whole, 3 do
    local b1, b2, b3 = s:byte(i, i + 2)
    local v = (b1 << 16) | (b2 << 8) | b3
    out[k + 1] = pair[v >> 12]
    out[k + 2] = pair[v & 4095]
    k = k + 2
  end
  local left = n - whole
  if left == 1 then
    local v = s:byte(n) << 4
    out[k + 1] = pair[v]
    if pad then out[k + 2] = "==" end
  elseif left == 2 then
    local b1, b2 = s:byte(n - 1, n)
    local v = (b1 << 10) | (b2 << 2)
    out[k + 1] = pair[v >> 6]
    out[k + 2] = a.char[v & 63]
    if pad then out[k + 3] = "=" end
  end
  return table.concat(out)
end

--- Characters of base64 decoded per `string.char` call: a multiple of
--- four, and few enough bytes to pass as arguments.
local BATCH <const> = 4096

--- The bytes `s` spells in `a`'s alphabet. `padded` says whether `s`
--- must carry `=` padding to a multiple of four characters or must
--- carry none.
local function decode(a: Alphabet, s: string, padded: boolean, name: string): string | nil, string
  local n = #s
  if padded then
    if n % 4 ~= 0 then
      return nil, ("codec: %s text of length %d, not a multiple of 4"):format(name, n)
    end
    if s:sub(-2) == "==" then
      n = n - 2
    elseif s:sub(-1) == "=" then
      n = n - 1
    end
  elseif n % 4 == 1 then
    return nil, ("codec: %s text of length %d leaves one character over"):format(name, n)
  end
  local at = s:find(a.class)
  if at ~= nil and at <= n then
    if s:byte(at) == 61 then
      return nil, ("codec: %s text has misplaced '=' padding at %d"):format(name, at)
    end
    return nil, ("codec: byte 0x%02x at %d is outside the %s alphabet"):format(s:byte(at), at, name)
  end
  local value = a.value
  local out: {string} = {}
  local k = 0
  local whole = n - n % 4
  -- Bytes gather in `buf` and leave a batch at a time through one
  -- `string.char`: a string per group would intern millions of them.
  local buf: {integer} = {}
  for first = 1, whole, BATCH do
    local last = math.min(first + BATCH - 1, whole)
    local m = 0
    for i = first, last, 4 do
      local c1, c2, c3, c4 = s:byte(i, i + 3)
      local v = (value[c1] << 18) | (value[c2] << 12) | (value[c3] << 6) | value[c4]
      buf[m + 1], buf[m + 2], buf[m + 3] = v >> 16, (v >> 8) & 255, v & 255
      m = m + 3
    end
    k = k + 1
    out[k] = string.char(table.unpack(buf, 1, m))
  end
  local left = n - whole
  if left == 2 then
    local c1, c2 = s:byte(n - 1, n)
    local v = (value[c1] << 6) | value[c2]
    if v & 15 ~= 0 then
      return nil, ("codec: %s text ends in nonzero padding bits"):format(name)
    end
    out[k + 1] = string.char(v >> 4)
  elseif left == 3 then
    local c1, c2, c3 = s:byte(n - 2, n)
    local v = (value[c1] << 12) | (value[c2] << 6) | value[c3]
    if v & 3 ~= 0 then
      return nil, ("codec: %s text ends in nonzero padding bits"):format(name)
    end
    out[k + 1] = string.char(v >> 10, (v >> 2) & 255)
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
function Codec.unbase64(s: string): string | nil, string
  return decode(STANDARD, s, true, "base64")
end

--- Bytes as unpadded base64 in the URL- and filename-safe alphabet
--- (`-` and `_` in place of `+` and `/`), the form JSON Web Tokens use.
--- @param s string The bytes to encode
--- @return string The base64url text, without `=` padding
function Codec.base64url(s: string): string
  return encode(URL, s, false)
end

--- The bytes unpadded base64url spells. Strict like `Codec.unbase64`,
--- and refuses `=` padding: answers `nil` and a reason for a length
--- that leaves one character over, a character outside the alphabet,
--- or a last character whose unused bits are not zero.
--- @param s string The base64url text
--- @return string | nil The decoded bytes
--- @return string Why the text was refused, or "" when it was not
function Codec.unbase64url(s: string): string | nil, string
  return decode(URL, s, false, "base64url")
end

return Codec
