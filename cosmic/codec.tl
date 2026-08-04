--- Encoding and decoding utilities for various formats.
--- Provides hex, base64, base32, Latin-1, and Lua serialization codecs
--- with consistent error handling, plus CRC-32 checksums (checksums are
--- encoding-adjacent error detection, not crypto — see cosmic.hash for
--- digests).
local cosmo = require("cosmo")

--- Encode a string as hexadecimal.
--- Each byte becomes two lowercase hex characters.
--- @param data string The binary data to encode
--- @return string The hexadecimal representation
local function encode_hex(data: string): string
  return cosmo.EncodeHex(data)
end

--- Decode a hexadecimal string to binary data.
--- Accepts both uppercase and lowercase hex characters.
--- @param hex string The hexadecimal string to decode
--- @return string | nil The decoded binary data, or nil on error
--- @return string? Error message if decoding failed
local function decode_hex(hex: string): string | nil, string
  -- The binding validates the input (odd length, non-hex characters)
  -- and reports bad data as nil, err; forward its error verbatim.
  local result, err = cosmo.DecodeHex(hex)
  if not result then
    return nil, err
  end
  return result
end

--- Encode a Lua value as Lua source code.
--- The output can be loaded with decode_lua to reconstruct the value.
--- @param value any The Lua value to encode (table, string, number, boolean, or nil)
--- @param opts {string:any}? Optional encoding options
--- @return string | nil The Lua source code representation, or nil on error
--- @return string? Error message if encoding failed
local function encode_lua(value: any, opts?: {string: any}): string | nil, string
  -- cast: map to options record
  local result, err = cosmo.EncodeLua(value, opts as cosmo.EncoderOptions)
  if result == nil then
    return nil, err
  end
  return result
end

--- Decode Lua source code to a value with a restricted environment.
--- Only loads the code in text mode with an empty environment table,
--- preventing access to globals like os, io, and require.
--- Table constructors and literal values still work.
--- WARNING: This still executes Lua code. Only use with trusted input.
--- @param code string The Lua source code to decode
--- @return any | nil The decoded Lua value, or nil on error
--- @return string? Error message if decoding failed
local function decode_lua_unsafe(code: string): any | nil, string
  local chunk, err = load("return " .. code, "=(decode_lua_unsafe)", "t", {})
  if not chunk then
    return nil, err
  end
  local ok, result = pcall(chunk)
  if not ok then
    return nil, result as string -- cast: from any
  end
  return result, nil
end

--- Encode binary data as base64.
--- Uses standard base64 encoding (RFC 4648).
--- @param data string The binary data to encode
--- @return string The base64 encoded string
local function encode_base64(data: string): string
  return cosmo.EncodeBase64(data)
end

--- Validate a base64-family string's structure (alphabet characters,
--- then "=" padding, then end) in one pass. On the happy path this is
--- the only scan needed; a mismatch means either an invalid character
--- anywhere or padding not confined to the end, so a second, cheaper
--- scan runs only then to tell which. Shared by decode_base64 and
--- decode_base64url, which differ only in alphabet and error label.
--- @param str string The string to validate
--- @param content_pattern string Lua pattern for the alphabet, zero or more (e.g. "[A-Za-z0-9+/]*")
--- @param bad_char_pattern string Lua pattern matching a character outside the alphabet and not "=" (e.g. "[^A-Za-z0-9+/=]")
--- @param label string Name used in error messages ("base64" or "base64url")
--- @return string | nil The alphabet characters with any "=" padding stripped, or nil if invalid
--- @return string? Error message if invalid
local function validate_base64_family(
    str: string, content_pattern: string, bad_char_pattern: string, label: string
  ): string | nil, string
  local content, padding = str:match("^(" .. content_pattern .. ")(%=*)$")
  if not content then
    if str:match(bad_char_pattern) then
      return nil, "invalid " .. label .. " character"
    end
    return nil, "invalid " .. label .. ": padding in middle"
  end
  if #padding > 2 then
    return nil, "invalid " .. label .. " padding"
  end
  return content
end

--- Decode a base64 string to binary data.
--- Accepts standard base64 encoding with or without padding.
--- @param str string The base64 string to decode
--- @return string | nil The decoded binary data, or nil on error
--- @return string? Error message if decoding failed
local function decode_base64(str: string): string | nil, string
  local _, err = validate_base64_family(str, "[A-Za-z0-9+/]*", "[^A-Za-z0-9+/=]", "base64")
  if err then
    return nil, err
  end
  return cosmo.DecodeBase64(str)
end

--- Encode binary data as base64url (RFC 4648 section 5).
--- The URL- and filename-safe variant: "-" and "_" replace "+" and
--- "/", and no "=" padding is emitted.
--- @param data string The binary data to encode
--- @return string The base64url encoded string
local function encode_base64url(data: string): string
  local b64 = cosmo.EncodeBase64(data)
  b64 = string.gsub(b64, "%+", "-")
  b64 = string.gsub(b64, "/", "_")
  b64 = string.gsub(b64, "=", "")
  return b64
end

--- Decode a base64url string to binary data.
--- Accepts the URL-safe alphabet ("-" and "_") with or without "="
--- padding. Standard-alphabet characters ("+", "/") are rejected.
--- @param str string The base64url string to decode
--- @return string | nil The decoded binary data, or nil on error
--- @return string? Error message if decoding failed
local function decode_base64url(str: string): string | nil, string
  local content, err = validate_base64_family(str, "[A-Za-z0-9%-_]*", "[^A-Za-z0-9%-_=]", "base64url")
  if err then
    return nil, err
  end
  local b64 = string.gsub(content, "%-", "+")
  b64 = string.gsub(b64, "_", "/")
  return cosmo.DecodeBase64(b64)
end

--- Encode binary data as base32.
--- Uses lowercase base32 alphabet (0-9a-z excluding i, l, o, u).
--- @param data string The binary data to encode
--- @return string The base32 encoded string
local function encode_base32(data: string): string
  -- The binding is fallible only when a custom alphabet of invalid
  -- length is supplied; with the default alphabet it cannot fail.
  return (cosmo.EncodeBase32(data))
end

--- Decode a base32 string to binary data.
--- Uses lowercase base32 alphabet (0-9a-z excluding i, l, o, u).
--- @param str string The base32 string to decode
--- @return string | nil The decoded binary data, or nil on error
--- @return string? Error message if decoding failed
local function decode_base32(str: string): string | nil, string
  -- cosmo base32 alphabet: 0123456789abcdefghjkmnpqrstvwxyz (32 chars, no i,l,o,u)
  -- The binding decodes permissively (it stops at the first character
  -- outside the alphabet), so this strict validation is load-bearing.
  if str:match("[^0-9a-hj-km-np-tv-z]") then
    return nil, "invalid base32 character"
  end
  -- The binding is fallible only for custom alphabets of invalid
  -- length; forward its error anyway rather than swallowing it.
  local result, err = cosmo.DecodeBase32(str)
  if not result then
    return nil, err
  end
  return result
end

--- Compute the CRC-32 checksum of data (ISO 3309 / "Phil Katz" CRC,
--- as used by zip, zlib, and gzip; the same value zip.Stat reports).
--- Checksums are error-detection codes, not cryptographic digests —
--- for those, see cosmic.hash.digest.
--- Pass a previous result as initial to checksum a stream
--- incrementally: crc32(b, crc32(a)) == crc32(a .. b).
--- @param data string The data to checksum
--- @param initial integer? Checksum to continue from (default 0)
--- @return integer The CRC-32 checksum as an unsigned 32-bit integer
local function crc32(data: string, initial?: integer): integer
  return cosmo.Crc32(initial or 0, data)
end

--- Compute the CRC-32C (Castagnoli) checksum of data, the variant
--- used by iSCSI, ext4, and LevelDB. Same contract as crc32.
--- @param data string The data to checksum
--- @param initial integer? Checksum to continue from (default 0)
--- @return integer The CRC-32C checksum as an unsigned 32-bit integer
local function crc32c(data: string, initial?: integer): integer
  return cosmo.Crc32c(initial or 0, data)
end

--- Encode a UTF-8 string as Latin-1 (ISO-8859-1).
--- Characters outside the Latin-1 range will cause an error.
--- @param str string The UTF-8 string to encode
--- @return string | nil The Latin-1 encoded bytes, or nil on error
--- @return string? Error message if encoding failed
local function encode_latin1(str: string): string | nil, string
  -- cosmo.EncodeLatin1 still raises on input it cannot re-encode
  -- (its declared signature is a bare string), so the pcall stays.
  local ok, result = pcall(cosmo.EncodeLatin1, str)
  if not ok then
    return nil, "cannot encode to Latin-1: character out of range"
  end
  return result, nil
end

--- Decode Latin-1 (ISO-8859-1) bytes to a UTF-8 string.
--- @param data string The Latin-1 bytes to decode
--- @return string The UTF-8 string
local function decode_latin1(data: string): string
  return cosmo.DecodeLatin1(data)
end

local record CodecModule
  encode_hex: function(data: string): string
  decode_hex: function(hex: string): string | nil, string
  encode_lua: function(value: any, opts?: {string: any}): string | nil, string
  decode_lua_unsafe: function(code: string): any | nil, string
  encode_base64: function(data: string): string
  decode_base64: function(str: string): string | nil, string
  encode_base64url: function(data: string): string
  decode_base64url: function(str: string): string | nil, string
  encode_base32: function(data: string): string
  decode_base32: function(str: string): string | nil, string
  crc32: function(data: string, initial?: integer): integer
  crc32c: function(data: string, initial?: integer): integer
  encode_latin1: function(str: string): string | nil, string
  decode_latin1: function(data: string): string
end

local M: CodecModule = {
  encode_hex = encode_hex,
  decode_hex = decode_hex,
  encode_lua = encode_lua,
  decode_lua_unsafe = decode_lua_unsafe,
  encode_base64 = encode_base64,
  decode_base64 = decode_base64,
  encode_base64url = encode_base64url,
  decode_base64url = decode_base64url,
  encode_base32 = encode_base32,
  decode_base32 = decode_base32,
  crc32 = crc32,
  crc32c = crc32c,
  encode_latin1 = encode_latin1,
  decode_latin1 = decode_latin1,
}

return M
