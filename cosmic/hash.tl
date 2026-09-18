--- Content hashes.

local sys = require("cosmic.sys")

local record Hash
end

local hex = "0123456789abcdef"

--- The 32 raw bytes of a SHA-256 digest.
function Hash.sha256(data: string): string
  return sys.sha256(data)
end

--- A digest as 64 lowercase hexadecimal characters.
function Hash.hex(digest: string): string
  local out: {string} = {}
  for i = 1, #digest do
    local byte = digest:byte(i)
    out[#out + 1] = hex:sub((byte >> 4) + 1, (byte >> 4) + 1)
    out[#out + 1] = hex:sub((byte & 15) + 1, (byte & 15) + 1)
  end
  return table.concat(out)
end

--- The hexadecimal SHA-256 of some bytes, which is the form the build
--- writes into keys.
function Hash.hex_sha256(data: string): string
  return Hash.hex(sys.sha256(data))
end

return Hash
