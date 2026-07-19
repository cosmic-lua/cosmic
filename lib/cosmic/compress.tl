--- Compression and decompression utilities.
--- Wraps DEFLATE in the three standard framings — zlib (default), gzip,
--- and raw (headerless, as used inside ZIP files) — so output
--- interoperates with standard tooling for each format (api-review-2,
--- #590). Raw callers who need the original length carry it themselves
--- and should checksum the output separately.
local cosmo = require("cosmo")

--- Compressed stream framing produced by compress().
local enum Format
  "zlib"
  "gzip"
  "raw"
end

--- Framing accepted by decompress(). "auto" detects zlib or gzip from
--- the stream header; raw streams carry no header and must be named
--- explicitly.
local enum DecompressFormat
  "zlib"
  "gzip"
  "raw"
  "auto"
end

--- Options for compress().
local record CompressOptions
  --- output framing; defaults to "zlib"
  format: Format
end

--- Options for decompress().
local record DecompressOptions
  --- input framing; defaults to "zlib"
  format: DecompressFormat
  --- cap on the decompressed size in bytes (default 64 MiB)
  max_output: integer
end

--- Compress data using a standard framing.
--- zlib (default) and gzip carry their own integrity checks and can be
--- decompressed without knowing the original size. Raw is headerless
--- DEFLATE, suitable for embedding into formats like ZIP files.
--- @param data string The data to compress
--- @param opts CompressOptions? format: "zlib" (default) | "gzip" | "raw"
--- @return string The compressed data
local function compress(data: string, opts?: CompressOptions): string
  local format: Format = opts and opts.format or "zlib"
  local result, err = cosmo.Deflate(data, {format = format})
  if not result then
    -- Unreachable with valid options; surface a loud failure rather than
    -- silently breaking the infallible contract.
    error("compress: " .. tostring(err))
  end
  return result
end

--- Decompress data in a standard framing.
--- The decompressed size need not be known in advance; output is bounded
--- by max_output (default 64 MiB, enforced by the binding) so untrusted
--- input cannot balloon memory.
--- @param data string The compressed data
--- @param opts DecompressOptions? format: "zlib" (default) | "gzip" | "raw" | "auto"; max_output: output byte cap
--- @return string | nil The decompressed data, or nil on error
--- @return string? Error message if decompression failed
local function decompress(data: string, opts?: DecompressOptions): string | nil, string
  local format: DecompressFormat = opts and opts.format or "zlib"
  local max_output = opts and opts.max_output
  -- The binding reports truncated or corrupt input as nil, err.
  local result, err = cosmo.Inflate(data, {format = format, maxsize = max_output})
  if not result then
    return nil, err as string
  end
  return result
end

local record CompressModule
  type Format = Format
  type DecompressFormat = DecompressFormat
  type CompressOptions = CompressOptions
  type DecompressOptions = DecompressOptions
  compress: function(data: string, opts?: CompressOptions): string
  decompress: function(data: string, opts?: DecompressOptions): string | nil, string
end

local M: CompressModule = {
  compress = compress,
  decompress = decompress,
}

return M
