--- Byte-to-text encodings: hexadecimal and base64 (RFC 4648). The
--- encoders are Teal and take any bytes; the base64 decoders run in the
--- core. Decoders are strict and total: for text
--- that no encoder here would write -- a character outside the
--- alphabet, a bad length, misplaced padding, or nonzero trailing bits
--- -- they return nil and a [`Failure`] rather than a guess, so every string
--- a decoder accepts encodes back to exactly itself, but for the case of
--- hex digits and the line breaks [`Codec.unbase64_lines`] skips.
---
--- - [`Codec.hex`] and [`Codec.unhex`]: lower-case hex, the way to show a
---   digest or a key. The decoder reads either case.
--- - [`Codec.base64`] and [`Codec.unbase64`]: the standard alphabet, padded,
---   for data in text formats and headers.
--- - [`Codec.unbase64_lines`]: the same, broken into lines, as an email
---   attachment (MIME, RFC 2045) or a PEM block carries it.
--- - [`Codec.base64url`] and [`Codec.unbase64url`]: the URL- and
---   filename-safe alphabet, unpadded, for tokens and file names.
---
--- Every function takes and returns a whole string. The `cosmic codec`
--- verb streams the same encodings for input too large for one.
---
---     local text = Codec.base64("hello")      -- "aGVsbG8="
---     local bytes = assert(Codec.unbase64(text))

local Failure = require("cosmic.failure")
local raw = require("cosmic.internal.text")

local record Codec
end

--- The byte at `index` of `text`, raising at the caller where there is
--- none, as [`cosmic.string.byte_at`] does, with a message of its own. Written here rather than required:
--- the test harness reaches this module (through [`cosmic.hash`]), and an
--- edit to a module it reaches moves every verdict's key
--- (build/harness_epoch.tl's `library`).
local function byte_at(text: string, index: integer): integer
  local byte = if index >= 1 then text:byte(index) else nil end
  if byte == nil then
    error(("codec: byte %d is outside the text (1 to %d)"):format(index, #text), 2)
  end
  return byte
end

--- What a function returns for a failure of this module: nil and a
--- Failure of `why` under the module's name.
local function refuse(why: string): nil, Failure
  return nil, Failure.new("codec: " .. why)
end

--- Every byte's two lowercase hex digits, by the byte: `gsub` takes the
--- table as its replacement, one lookup per byte.
local hex_of: mut {string:string} = {}
for byte = 0, 255 do
  hex_of[string.char(byte)] = ("%02x"):format(byte)
end

--- [`hex_bytes`]'s table, once built.
local byte_of_hex: {string:string}? = nil

--- Every pair of hex digits, either case, to the byte it spells, built
--- on first use: most programs that load this module (through
--- [`cosmic.hash`]) decode no hex.
local function hex_bytes(): {string:string}
  local found = byte_of_hex
  if found == nil then
    local made: mut {string:string} = {}
    for byte = 0, 255 do
      local ch = string.char(byte)
      local lower = ("%02x"):format(byte)
      made[lower] = ch
      made[lower:upper()] = ch
      made[lower:sub(1, 1):upper() .. lower:sub(2, 2)] = ch
      made[lower:sub(1, 1) .. lower:sub(2, 2):upper()] = ch
    end
    byte_of_hex = made
    found = made
  end
  return found
end

--- Bytes as lowercase hexadecimal, two digits per byte.
--- @param s string The bytes to encode
--- @return string Twice as many hex digits
function Codec.hex(s: string): string
  return (s:gsub(".", hex_of))
end

--- The bytes hexadecimal text spells, reading either case. Returns
--- nil and a Failure for an odd number of digits or a character that
--- is not a hex digit.
--- @param s string The hex text
function Codec.unhex(s: string): (string) | (nil, Failure)
  if #s % 2 ~= 0 then
    return refuse(("hex text of odd length %d"):format(#s))
  end
  local at = s:find("[^0-9a-fA-F]")
  if at ~= nil then
    return refuse(("byte 0x%02x at %d is not a hex digit"):format(byte_at(s, at), at))
  end
  return (s:gsub("..", hex_bytes()))
end

--- One base64 alphabet's encoding tables: `char` maps a 6-bit value to
--- its character and `pair` a 12-bit value to its two characters.
local record Alphabet
  char: mut {integer:string}
  pair: mut {integer:string}
end

local function alphabet(chars: string): Alphabet
  local a: Alphabet = { char = {}, pair = {} }
  for i = 1, 64 do
    a.char[i - 1] = chars:sub(i, i)
  end
  for v = 0, 4095 do
    local high = assert(a.char[v >> 6], "char holds every index 0 to 63")
    local low = assert(a.char[v & 63], "char holds every index 0 to 63")
    a.pair[v] = high .. low
  end
  return a
end

local standard_alphabet: Alphabet? = nil
local url_alphabet: Alphabet? = nil

--- The standard base64 alphabet's tables, built on first use.
local function standard(): Alphabet
  local a = standard_alphabet
  if a == nil then
    a = alphabet("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    standard_alphabet = a
  end
  return a
end

--- The URL- and filename-safe base64 alphabet's tables, built on first use.
local function url(): Alphabet
  local a = url_alphabet
  if a == nil then
    a = alphabet("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    url_alphabet = a
  end
  return a
end

--- `s` in `a`'s alphabet, `=`-padded to a multiple of four characters
--- when `pad`.
local function encode(a: Alphabet, s: string, pad: boolean): string
  local pair = a.pair
  local out: mut {string} = {}
  local n = #s
  local whole = n - n % 3
  for i = 1, whole, 3 do
    local b1, b2, b3 = s:byte(i, i + 2)
    assert(b1 and b2 and b3, "i + 2 is at most whole, which is at most #s")
    local v = (b1 << 16) | (b2 << 8) | b3
    local first, second = assert(pair[v >> 12]), assert(pair[v & 4095])
    out[#out + 1] = first
    out[#out + 1] = second
  end
  local left = n - whole
  if left == 1 then
    local v = byte_at(s, n) << 4
    local first = assert(pair[v])
    out[#out + 1] = first
    if pad then out[#out + 1] = "==" end
  elseif left == 2 then
    local v = (byte_at(s, n - 1) << 10) | (byte_at(s, n) << 2)
    local first, second = assert(pair[v >> 6]), assert(a.char[v & 63])
    out[#out + 1] = first
    out[#out + 1] = second
    if pad then out[#out + 1] = "=" end
  end
  return table.concat(out)
end

--- The bytes `s` spells in base64, decoded by the core: the URL-safe
--- alphabet where `url`, else the standard one. `padded` says whether `s`
--- must carry `=` padding to a multiple of four characters or must carry
--- none; `lines` skips every CR and LF first. `name` names the encoding in
--- a refusal.
local function decode(s: string, url_safe: boolean, padded: boolean, lines: boolean,
                      name: string): (string) | (nil, Failure)
  local bytes, at, kind = raw.unbase64(s, url_safe, padded, lines)
  if bytes ~= nil then return bytes end
  local length = if lines then "length %d without its line breaks" else "length %d" end
  if kind == "length" then
    return refuse(("%s text of " .. length .. ", not a multiple of 4"):format(name, at))
  elseif kind == "over" then
    return refuse(("%s text of " .. length .. " leaves one character over"):format(name, at))
  elseif kind == "padding" then
    return refuse(("%s text has misplaced '=' padding at %d"):format(name, at))
  elseif kind == "byte" then
    return refuse(("byte 0x%02x at %d is outside the %s alphabet"):format(byte_at(s, at), at, name))
  end
  return refuse(("%s text ends in nonzero padding bits"):format(name))
end

--- Bytes as base64 in the standard alphabet (`A-Z a-z 0-9 + /`),
--- `=`-padded to a multiple of four characters, with no line breaks.
--- @param s string The bytes to encode
--- @return string The base64 text
function Codec.base64(s: string): string
  return encode(standard(), s, true)
end

--- The bytes standard, padded base64 spells. Strict: returns nil and
--- a Failure for a length that is not a multiple of four, a character
--- outside the alphabet (whitespace and line breaks included), `=`
--- anywhere but the last one or two places, or a last character whose
--- unused bits are not zero.
--- @param s string The base64 text
function Codec.unbase64(s: string): (string) | (nil, Failure)
  return decode(s, false, true, false, "base64")
end

--- The bytes standard, padded base64 spells when broken into lines, as
--- MIME (RFC 2045) writes an email attachment and PEM a key: every CR and
--- LF is skipped, and the rest is as strict as [`Codec.unbase64`]. Any
--- other whitespace refuses it.
--- @param s string The base64 text, in lines
function Codec.unbase64_lines(s: string): (string) | (nil, Failure)
  return decode(s, false, true, true, "base64")
end

--- Bytes as unpadded base64 in the URL- and filename-safe alphabet
--- (`-` and `_` in place of `+` and `/`), the form JSON Web Tokens use.
--- @param s string The bytes to encode
--- @return string The base64url text, without `=` padding
function Codec.base64url(s: string): string
  return encode(url(), s, false)
end

--- The bytes unpadded base64url spells. Strict like [`Codec.unbase64`],
--- and refuses `=` padding: returns nil and a Failure for a length
--- that leaves one character over, a character outside the alphabet,
--- or a last character whose unused bits are not zero.
--- @param s string The base64url text
function Codec.unbase64url(s: string): (string) | (nil, Failure)
  return decode(s, true, false, false, "base64url")
end

return Codec
