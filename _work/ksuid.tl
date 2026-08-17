--- KSUIDs for work items: 20 bytes — a 4-byte big-endian timestamp
--- (seconds since the KSUID epoch, 2014-05-13) followed by 16 random
--- bytes — base62-encoded to a fixed 27 characters. The alphabet is
--- ascending ASCII, so LEXICOGRAPHIC ORDER IS CREATION ORDER: sorting
--- item files sorts them oldest-first, and no separate `opened` field
--- exists to drift from the truth. Two sessions minting ids never
--- coordinate and never collide (128 random bits), which is exactly
--- what committed-file state needs where issue numbers used to come
--- from GitHub's central counter.
local rand = require("cosmic.rand")
local time = require("cosmic.time")

--- 2014-05-13T16:53:20Z: KSUID's epoch, giving the 32-bit timestamp
--- field headroom into the 22nd century.
local EPOCH < const > = 1400000000

local ALPHABET < const > =
"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

local LEN < const > = 27
local BYTES < const > = 20

local VALUE_OF: {string: integer} = {}
for i = 1, #ALPHABET do
  VALUE_OF[ALPHABET:sub(i, i)] = i - 1
end

--- Whether a string is a well-formed KSUID: exactly 27 base62 bytes.
--- @param id string Candidate id
--- @return boolean True when well-formed
local function is_id(id: string): boolean
  return id ~= nil and #id == LEN and id:match("^[%w]+$") ~= nil
end

--- A KSUID from its two fields. The one constructor `new` and the
--- tests share, so a test minting deterministic ids exercises the
--- same encoding a live session does.
--- @param seconds integer Unix seconds; must be at or after the KSUID epoch
--- @param payload string Exactly 16 bytes of entropy
--- @return string | nil The 27-character id
--- @return string Error message
local function encode(seconds: integer, payload: string): string | nil, string
  if payload == nil or #payload ~= 16 then
    return nil, "payload must be exactly 16 bytes"
  end
  local ts = seconds - EPOCH
  if ts < 0 or ts > 0xffffffff then
    return nil, "seconds outside the KSUID timestamp range"
  end
  local bytes: {integer} = {
    (ts >> 24) & 0xff, (ts >> 16) & 0xff, (ts >> 8) & 0xff, ts & 0xff,
  }
  for i = 1, 16 do
    bytes[#bytes + 1] = payload:byte(i)
  end
  -- Base-256 to base-62 by repeated division; digits come out least
  -- significant first and reverse into place.
  local out: {string} = {}
  local src = bytes
  while #src > 0 do
    local quotient: {integer} = {}
    local rem = 0
    for _, b in ipairs(src) do
      local acc = rem * 256 + b
      local q = acc // 62
      rem = acc % 62
      if #quotient > 0 or q > 0 then
        quotient[#quotient + 1] = q
      end
    end
    out[#out + 1] = ALPHABET:sub(rem + 1, rem + 1)
    src = quotient
  end
  while #out < LEN do
    out[#out + 1] = "0"
  end
  local reversed: {string} = {}
  for i = #out, 1, -1 do
    reversed[#reversed + 1] = out[i]
  end
  return table.concat(reversed)
end

--- A fresh id: now, with 16 CSPRNG bytes.
--- @return string The 27-character id
local function new(): string
  local seconds = time.now()
  local id = encode(seconds, rand.bytes(16))
  -- encode fails only on a malformed payload or a clock outside the
  -- 32-bit window; rand.bytes(16) and any sane clock satisfy both.
  return assert(id)
end

--- The creation time an id carries.
--- @param id string A KSUID
--- @return integer | nil Unix seconds
--- @return string Error message for a malformed id
local function time_of(id: string): integer | nil, string
  if not is_id(id) then
    return nil, ("not a ksuid: %s"):format(tostring(id))
  end
  -- Base-62 back to base-256; only the leading 4 timestamp bytes are
  -- read, but the conversion must consume the whole number.
  local bytes: {integer} = {}
  for i = 1, #id do
    local v = VALUE_OF[id:sub(i, i)]
    if v == nil then
      return nil, ("not a ksuid: %s"):format(id)
    end
    local carry = v
    for j = #bytes, 1, -1 do
      local acc = bytes[j] * 62 + carry
      bytes[j] = acc & 0xff
      carry = acc >> 8
    end
    while carry > 0 do
      table.insert(bytes, 1, carry & 0xff)
      carry = carry >> 8
    end
  end
  while #bytes < BYTES do
    table.insert(bytes, 1, 0)
  end
  if #bytes > BYTES then
    return nil, ("not a ksuid: %s"):format(id)
  end
  local ts = (bytes[1] << 24) | (bytes[2] << 16) | (bytes[3] << 8) | bytes[4]
  return ts + EPOCH
end

local record ksuid
  LEN: integer
  is_id: function(id: string): boolean
  encode: function(seconds: integer, payload: string): string | nil, string
  new: function(): string
  time_of: function(id: string): integer | nil, string
end

local M: ksuid = {
  LEN = LEN,
  is_id = is_id,
  encode = encode,
  new = new,
  time_of = time_of,
}

return M
