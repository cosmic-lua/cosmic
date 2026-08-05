--- Compression and decompression utilities.
--- Wraps DEFLATE in the three standard framings — zlib (default), gzip,
--- and raw (headerless, as used inside ZIP files) — so output
--- interoperates with standard tooling for each format (api-review-2,
---). Raw callers who need the original length carry it themselves
--- and should checksum the output separately.
local cosmo = require("cosmo")

--- Stream framing, one enum for both directions: "zlib" (default),
--- "gzip", "raw" (headerless, as inside ZIP files), and "auto" —
--- decompress-only header detection. One enum instead of the old
--- compress/decompress pair, so round-tripping your own format value
--- no longer needs an enum-widening cast; compress() rejects "auto"
--- at runtime (it names no producible framing).
local enum Format
  "zlib"
  "gzip"
  "raw"
  "auto"
end

--- Options for compress().
local record CompressOptions
  --- output framing; defaults to "zlib" ("auto" is rejected)
  format: Format
end

--- Options for decompress().
local record DecompressOptions
  --- input framing; defaults to "zlib"
  format: Format
  --- cap on the decompressed size in bytes (default 64 MiB)
  max_output: integer
end

--- Compress data using a standard framing.
--- zlib (default) and gzip carry their own integrity checks and can be
--- decompressed without knowing the original size. Raw is headerless
--- DEFLATE, suitable for embedding into formats like ZIP files.
--- @param data string The data to compress
--- @param opts CompressOptions? format: "zlib" (default) | "gzip" | "raw"
--- @return string | nil The compressed data
--- @return string? Error message on failure ("auto" format, or a
--- binding failure — the old infallible signature hid the error()
--- this used to throw from library code)
local function compress(data: string, opts?: CompressOptions): string | nil, string
  local format: Format = opts and opts.format or "zlib"
  if format == "auto" then
    return nil, "compress: format \"auto\" is decompress-only; name the framing"
  end
  -- cast: one Format enum, narrowed above; the binding's compress enum lacks "auto"
  local result, err = cosmo.Deflate(data, {format = format as cosmo.CompressFormat})
  if not result then
    return nil, "compress: " .. tostring(err)
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
  local format: Format = opts and opts.format or "zlib"
  local max_output = opts and opts.max_output
  -- The binding reports truncated or corrupt input as nil, err.
  -- cast: one Format enum; the binding's decompress enum is the same word set
  local result, err = cosmo.Inflate(data,
    {format = format as cosmo.UncompressFormat, maxsize = max_output})
  if not result then
    return nil, "decompress: " .. tostring(err)
  end
  return result
end

local record CompressModule
  type Format = Format
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
