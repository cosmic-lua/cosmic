--- Compression and decompression utilities.
--- Provides zlib and raw deflate compression with consistent error handling.
local cosmo = require("cosmo")

--- Compress data using zlib (with header).
--- The compressed output includes size information and can be decompressed
--- without knowing the original size.
--- @param data string The data to compress
--- @return string The compressed data
local function compress(data: string): string
  return cosmo.Compress(data)
end

--- Decompress zlib-compressed data.
--- @param data string The compressed data (from compress())
--- @return string The decompressed data, or nil on error
--- @return string? Error message if decompression failed
local function uncompress(data: string): string, string
  local ok, result = pcall(cosmo.Uncompress, data)
  if not ok then
    return nil, "decompression failed: " .. tostring(result)
  end
  return result
end

--- Compress data using raw deflate (no header).
--- The output is prefixed with a 4-byte little-endian size to enable
--- decompression without knowing the original size.
--- Maximum input size: ~4GB (limited by 32-bit size prefix).
--- Note: The output format is specific to this module and is not compatible
--- with standard raw deflate streams. Use compress/uncompress for
--- interoperable zlib format.
--- @param data string The data to compress
--- @return string The compressed data with size prefix
local function deflate(data: string): string
  if #data > 0xFFFFFFFF then
    error("deflate: input too large (max 4GB)")
  end
  local size = #data
  -- Store size as 4-byte little-endian prefix
  local prefix = string.char(
    size % 256,
    math.floor(size / 256) % 256,
    math.floor(size / 65536) % 256,
    math.floor(size / 16777216) % 256
  )
  return prefix .. cosmo.Deflate(data)
end

--- Decompress raw deflate data.
--- Expects data from deflate() with the 4-byte size prefix.
--- Maximum decompressed size: ~4GB (limited by 32-bit size prefix).
--- Note: Only compatible with data produced by deflate() in this module.
--- @param data string The compressed data with size prefix
--- @return string The decompressed data, or nil on error
--- @return string? Error message if decompression failed
local function inflate(data: string): string, string
  if #data < 4 then
    return nil, "invalid deflate data: too short"
  end
  -- Read 4-byte little-endian size prefix
  local b1, b2, b3, b4 = data:byte(1, 4)
  local size = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
  local compressed = data:sub(5)
  local ok, result = pcall(cosmo.Inflate, compressed, size)
  if not ok then
    return nil, "decompression failed: " .. tostring(result)
  end
  if result == nil then
    return nil, "decompression failed: invalid data"
  end
  return result
end

local record CompressModule
  compress: function(data: string): string
  uncompress: function(data: string): string, string
  deflate: function(data: string): string
  inflate: function(data: string): string, string
end

local M: CompressModule = {
  compress = compress,
  uncompress = uncompress,
  deflate = deflate,
  inflate = inflate,
}

return M
