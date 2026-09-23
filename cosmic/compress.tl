--- Compression and expansion over the core's miniz, xz and bzip2
--- bindings: one-shot deflate/inflate, and streaming codecs for
--- deflate/zlib/gzip, xz and bzip2.

local sys = require("cosmic.sys")

--- The raw module behind the streaming codecs lives under the reserved
--- `cosmic.internal.` namespace -- see cosmic/sqlite.tl for why this
--- indirection exists.
local type raw_compress = require("cosmic.internal.compress")

local extra: any = select(2, ...)
local raw: raw_compress
if type(extra) == "table" then
  raw = extra as raw_compress
else
  raw = require("cosmic.internal.compress")
end

local record Compress
  --- One incremental transform, over a chunk at a time: `update` feeds
  --- input and returns all output produced so far (possibly ""),
  --- nil plus an error on corrupt data; `finish` signals no more input
  --- and returns whatever output remains, erroring for a decoder whose
  --- compressed stream ended early. A decoder's `done` reports whether
  --- the end of the compressed stream has been reached, and `rest`
  --- returns any input bytes fed after that point -- useful for a
  --- concatenated container or trailer that follows the stream.
  type Stream = raw_compress.Stream
end

--- Compresses bytes.
function Compress.deflate(data: string): string | nil, string
  local packed, trouble = sys.deflate(data)
  if packed == nil then
    return nil, trouble
  end
  return packed, ""
end

--- Expands bytes that `deflate` compressed. The expanded size is what
--- the caller recorded when it compressed them.
function Compress.inflate(data: string, size: integer): string | nil, string
  local out, trouble = sys.inflate(data, size)
  if out == nil then
    return nil, trouble
  end
  return out, ""
end

--- A streaming decoder for "raw" deflate, "zlib", or "gzip". A gzip
--- decoder parses the header (including FEXTRA/FNAME/FCOMMENT/FHCRC),
--- verifies the CRC-32 and ISIZE trailer, and decodes every member of a
--- multi-member stream.
function Compress.inflater(format: string): Compress.Stream | nil, string
  return raw.inflater(format)
end

--- A streaming encoder for "raw" deflate, "zlib", or "gzip", at
--- `level` (0 to 10, default the miniz default). A gzip encoder writes
--- a minimal ten-byte header (mtime 0, OS 255, no extra fields) and the
--- CRC-32/ISIZE trailer.
function Compress.deflater(format: string, level?: integer): Compress.Stream | nil, string
  return raw.deflater(format, level)
end

--- A streaming decoder for the .xz container: multi-stream and stream
--- padding are handled, and every filter and check the tree needs to
--- decode is supported.
function Compress.xz_decoder(): Compress.Stream | nil, string
  return raw.xz_decoder()
end

--- A streaming decoder for .bz2: multi-stream is handled.
function Compress.bz2_decoder(): Compress.Stream | nil, string
  return raw.bz2_decoder()
end

--- The running CRC-32 (IEEE) of `data`. Pass the previous value as
--- `crc` to continue it over more than one call.
function Compress.crc32(data: string, crc?: integer): integer
  return raw.crc32(data, crc)
end

return Compress
