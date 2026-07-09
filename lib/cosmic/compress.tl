--- Compression and decompression utilities.
--- Provides zlib and raw deflate compression with consistent error handling.
local cosmo = require("cosmo")

--- Compress data using standard zlib framing.
--- The zlib format carries its own integrity check (Adler-32), and the
--- output interoperates with other zlib tooling. It can be decompressed
--- without knowing the original size.
--- @param data string The data to compress
--- @return string The compressed data
local function compress(data: string): string
  local result, err = cosmo.Deflate(data, {format = "zlib"})
  if not result then
    -- Unreachable with valid options; surface a loud failure rather than
    -- silently breaking the infallible contract.
    error("compress: " .. tostring(err))
  end
  return result
end

--- Decompress zlib-compressed data.
--- The decompressed size need not be known in advance; output is bounded
--- by max_output (default 64 MiB, enforced by the binding) so untrusted
--- input cannot balloon memory.
--- @param data string The compressed data (from compress())
--- @param max_output number? Cap on the decompressed size in bytes
--- @return string | nil The decompressed data, or nil on error
--- @return string? Error message if decompression failed
local function uncompress(data: string, max_output?: number): string | nil, string
  -- The binding reports truncated or corrupt input as nil, err.
  local result, err = cosmo.Inflate(data, {format = "zlib", maxsize = max_output})
  if not result then
    return nil, err as string
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
--- @return string | nil The compressed data with size prefix, or nil on error
--- @return string? Error message if input exceeds size limit
local function deflate(data: string): string | nil, string
  if #data > 0xFFFFFFFF then
    return nil, "deflate: input too large (max 4GB)"
  end
  local size = #data
  -- Store size as 4-byte little-endian prefix
  local prefix = string.char(
    size % 256,
    math.floor(size / 256) % 256,
    math.floor(size / 65536) % 256,
    math.floor(size / 16777216) % 256
  )
  local compressed, err = cosmo.Deflate(data)
  if not compressed then
    return nil, err as string
  end
  return prefix .. compressed
end

-- DEFLATE cannot expand by more than ~1032x (zlib's documented maximum
-- compression ratio), so a size prefix claiming more than that is forged.
local MAX_DEFLATE_RATIO < const > = 1032

--- Decompress raw deflate data.
--- Expects data from deflate() with the 4-byte size prefix.
--- Maximum decompressed size: ~4GB (limited by 32-bit size prefix).
--- The size prefix is attacker-controlled in untrusted input, so it is
--- validated BEFORE the output buffer is allocated: a declared size larger
--- than max_output (when given), or implausibly large for the compressed
--- payload (beyond DEFLATE's ~1032:1 maximum ratio), is rejected without
--- allocating, and the binding additionally caps decompression at the
--- declared size. Output that does not match the declared size exactly is
--- reported as corrupt.
--- Note: Only compatible with data produced by deflate() in this module.
--- @param data string The compressed data with size prefix
--- @param max_output number? Reject a declared size larger than this many bytes
--- @return string | nil The decompressed data, or nil on error
--- @return string? Error message if decompression failed
local function inflate(data: string, max_output?: number): string | nil, string
  if #data < 4 then
    return nil, "invalid deflate data: too short"
  end
  -- Read 4-byte little-endian size prefix
  local b1, b2, b3, b4 = data:byte(1, 4)
  local size = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
  if max_output and size > max_output then
    return nil, "inflate: declared size " .. size .. " exceeds max_output " .. max_output
  end
  local compressed_len = #data - 4
  if size > compressed_len * MAX_DEFLATE_RATIO then
    return nil, "inflate: declared size " .. size .. " is implausible for " .. compressed_len .. " compressed bytes"
  end
  local compressed = data:sub(5)
  -- The binding reports invalid input as nil, err. maxsize of 0 is not a
  -- valid cap, so an empty payload uses 1 and the exactness check below
  -- rejects any unexpected output.
  local result, err = cosmo.Inflate(compressed, {maxsize = math.max(size, 1)})
  if not result then
    return nil, err as string
  end
  if #result ~= size then
    return nil, "inflate: output size " .. #result .. " does not match declared size " .. size
  end
  return result
end

local record CompressModule
  compress: function(data: string): string
  uncompress: function(data: string, max_output?: number): string | nil, string
  deflate: function(data: string): string | nil, string
  inflate: function(data: string, max_output?: number): string | nil, string
end

local M: CompressModule = {
  compress = compress,
  uncompress = uncompress,
  deflate = deflate,
  inflate = inflate,
}

return M
