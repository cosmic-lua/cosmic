--- Compression and expansion over the core's miniz, xz and bzip2
--- bindings: one-shot deflate/inflate in any deflate framing, and
--- streaming codecs for deflate/zlib/gzip, xz and bzip2.

--- The raw module behind the streaming codecs lives under the reserved
--- `cosmic.internal.` namespace -- see cosmic/store.tl for why this
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
  --- The deflate framings: bare "raw" deflate (RFC 1951, as zip
  --- stores it), "zlib" (RFC 1950), and "gzip" (RFC 1952).
  enum Format
    "raw"
    "zlib"
    "gzip"
  end

  --- One incremental transform, a chunk at a time. Every call that
  --- can fail answers `value, ""` on success and `nil, error` on
  --- failure, like the constructors.
  ---
  --- `update(chunk, max?)` feeds `chunk` and returns output, possibly
  --- "". A decoder returns at most `max` bytes per call (default
  --- 1 MiB), however far a small input expands: input it has not got
  --- to yet stays inside the stream, and `pending()` turns true.
  --- While `pending()` is true, `update("")` returns the next piece
  --- without new input (it may return "" once, when the limit fell
  --- exactly at the end). An encoder returns all of its output and
  --- is never pending. On corrupt data `update` returns nil and an
  --- error, and the stream is finished.
  ---
  --- `finish()` says no more input follows and returns what is left:
  --- an encoder's last block and trailer, and for a decoder only what
  --- follows its drained output (in practice ""). It raises while
  --- `pending()` is true, so its output is bounded too; drain first:
  ---
  ---     local out = assert(s:update(chunk))   -- use out
  ---     while s:pending() do
  ---       out = assert(s:update(""))          -- use out
  ---     end
  ---     ...                                   -- at end of input:
  ---     local last = assert(s:finish())       -- a small tail at most
  ---
  --- A decoder's `finish` errors when the compressed data stopped
  --- early ("truncated ... stream"). After `finish`, after an error,
  --- after a raise inside `update` or `finish` (out of memory: the
  --- codec may have taken input it can no longer account for), or
  --- once closed, `update` and `finish` throw. A stream is closeable:
  --- `local s <close> = assert(Compress.inflater("gzip"))` frees its
  --- codec at the end of the scope; `rest()` still answers after.
  ---
  --- `done()` turns true once a decoder has seen the end of the
  --- compressed data, and `rest()` returns the input bytes fed after
  --- that end ("" if none). Raw deflate and zlib hold exactly one
  --- stream, so both end the moment it does. gzip, xz and bzip2 allow
  --- one member after another, so after a member ends the decoder
  --- waits for the next input: bytes that begin that format's magic
  --- start another member, and anything else ends the data there and
  --- goes, in full, to `rest()` -- however the input was split into
  --- chunks. Until such a byte (or `finish`) arrives, `done()` stays
  --- false. At `finish`, a partial magic after at least one member is
  --- trailing bytes, not truncation. xz stream padding (NUL bytes in
  --- multiples of four between and after streams) is skipped; NULs
  --- that are not a whole multiple of four are trailing bytes.
  type Stream = raw_compress.Stream
end

--- Compresses `data` whole in the `format` framing, at `level` as
--- `deflater(format, level)` takes it; raises where that does.
function Compress.deflate(format: Compress.Format, data: string, level?: integer):
    string | nil, string
  local enc, trouble = raw.deflater(format, level)
  if enc == nil then return nil, trouble end
  local head, update_trouble = enc:update(data)
  if head == nil then return nil, update_trouble end
  local tail, ftrouble = enc:finish()
  if tail == nil then return nil, ftrouble end
  return head .. tail, ""
end

--- Expands `data`, whole, from the `format` framing, such as `deflate`
--- produced; raises on an unknown format. When `max` is given, more
--- than `max` bytes of output is an error rather than an answer. Bytes
--- after the end of the compressed data are an error too.
function Compress.inflate(format: Compress.Format, data: string, max?: integer):
    string | nil, string
  local dec, trouble = raw.inflater(format)
  if dec == nil then return nil, trouble end
  local parts: {string} = {}
  local total = 0
  local out, utrouble = dec:update(data)
  while true do
    if out == nil then return nil, utrouble end
    total = total + #out
    if max ~= nil and total > max then
      return nil, "expanded data is larger than " .. tostring(max) .. " bytes"
    end
    parts[#parts + 1] = out
    if not dec:pending() then break end
    out, utrouble = dec:update("")
  end
  local last, ftrouble = dec:finish()
  if last == nil then return nil, ftrouble end
  if dec:rest() ~= "" then
    return nil, "trailing bytes after the compressed data"
  end
  parts[#parts + 1] = last
  return table.concat(parts), ""
end

--- A streaming decoder for `format`. A gzip decoder parses the header
--- (including FEXTRA/FNAME/FCOMMENT/FHCRC), verifies the CRC-32 and
--- ISIZE trailer, and decodes every member of a multi-member stream.
--- Raises on an unknown format.
function Compress.inflater(format: Compress.Format): Compress.Stream | nil, string
  return raw.inflater(format)
end

--- A streaming encoder for `format` at `level`, 0 to 10 (default the
--- miniz default, 6); raises on an unknown format or a level out of
--- range. A gzip encoder writes a minimal ten-byte header (mtime 0,
--- OS 255, no extra fields) and the CRC-32/ISIZE trailer.
function Compress.deflater(format: Compress.Format, level?: integer): Compress.Stream | nil, string
  return raw.deflater(format, level)
end

--- A streaming decoder for the .xz container: multi-stream and stream
--- padding are handled, and every filter and check the tree needs to
--- decode is supported. The decoder refuses, with "xz memory limit
--- exceeded", a stream whose headers ask for more than `memlimit`
--- bytes of decoder memory (default 256 MiB; `xz -9` needs 65 MiB).
--- Raises when `memlimit` is not positive.
function Compress.xz_decoder(memlimit?: integer): Compress.Stream | nil, string
  return raw.xz_decoder(memlimit)
end

--- A streaming decoder for .bz2: multi-stream is handled.
function Compress.bz2_decoder(): Compress.Stream | nil, string
  return raw.bz2_decoder()
end

--- The running CRC-32 (IEEE) of `data`. Pass the previous value as
--- `crc` to continue it over more than one call; raises when `crc` is
--- outside 0 to 0xffffffff.
function Compress.crc32(data: string, crc?: integer): integer
  return raw.crc32(data, crc)
end

return Compress
