--- Compression and decompression utilities.
--- Wraps DEFLATE in the three standard framings — zlib (default), gzip,
--- and raw (headerless, as used inside ZIP files) — so output
--- interoperates with standard tooling for each format. Raw callers
--- who need the original length carry it themselves and should
--- checksum the output separately.
local cosmo = require("cosmo")

--- Framings compress() can produce: "zlib" (default), "gzip", and
--- "raw" (headerless, as inside ZIP files). The binding's own enum.
local type CompressFormat = cosmo.CompressFormat

--- Framings decompress() can consume: the three producible ones plus
--- "auto", header detection for zlib or gzip input. Two enums rather
--- than one is what makes "auto" decompress-only by TYPE, so passing
--- it to compress() cannot type-check. Named for the direction this
--- module calls it (rule 6: decode, not uncompress) while remaining
--- the binding's own enum, so a value crosses between the two layers
--- without a cast.
local type DecompressFormat = cosmo.UncompressFormat

--- Options for compress().
local record CompressOptions
  --- output framing; defaults to "zlib"
  format: CompressFormat
end

--- Options for decompress().
local record DecompressOptions
  --- input framing; defaults to "zlib"
  format: DecompressFormat
  --- cap on the decompressed size in bytes, default 64 MiB
  max_output_bytes: integer
end

--- Compress data using a standard framing.
--- zlib (default) and gzip carry their own integrity checks and can be
--- decompressed without knowing the original size. Raw is headerless
--- DEFLATE, suitable for embedding into formats like ZIP files.
--- @param data string The data to compress
--- @param opts CompressOptions? format: "zlib" (default) | "gzip" | "raw"
--- @return string | nil The compressed data
--- @return string? Error message on a binding failure (the old
--- infallible signature hid the error() this used to throw from
--- library code)
local function compress(data: string, opts?: CompressOptions): string | nil, string
  local format: CompressFormat = opts and opts.format or "zlib"
  -- cast: same word set; the binding names its enum independently
  local result, err = cosmo.Deflate(data, {format = format})
  if not result then
    return nil, "compress: " .. tostring(err)
  end
  return result
end

--- Decompress data in a standard framing.
--- The decompressed size need not be known in advance; output is
--- bounded by max_output_bytes (default 64 MiB, enforced by the
--- binding) so untrusted input cannot balloon memory.
--- @param data string The compressed data
--- @param opts DecompressOptions? format: "zlib" (default) | "gzip" | "raw" | "auto"; max_output_bytes: output byte cap
--- @return string | nil The decompressed data, or nil on error
--- @return string? Error message if decompression failed
local function decompress(data: string, opts?: DecompressOptions): string | nil, string
  local format: DecompressFormat = opts and opts.format or "zlib"
  local max_output_bytes = opts and opts.max_output_bytes
  -- The binding reports truncated or corrupt input as nil, err.
  -- cast: same word set; the binding names its enum independently
  local result, err = cosmo.Inflate(data, {format = format, maxsize = max_output_bytes})
  if not result then
    return nil, "decompress: " .. tostring(err)
  end
  return result
end

local record CompressModule
  type CompressFormat = CompressFormat
  type DecompressFormat = DecompressFormat
  type CompressOptions = CompressOptions
  type DecompressOptions = DecompressOptions
  compress: function(data: string, opts?: CompressOptions): string | nil, string
  decompress: function(data: string, opts?: DecompressOptions): string | nil, string
end

local M: CompressModule = {
  compress = compress,
  decompress = decompress,
}

return M
