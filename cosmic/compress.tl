--- Compression and expansion in six formats -- the raw, zlib and gzip
--- framings of deflate, zstd, xz and bzip2 -- through four functions,
--- each taking the format first: [`Compress.encode`] and
--- [`Compress.decode`] for data whole, [`Compress.encoder`] and
--- [`Compress.decoder`] for a stream of it.
---
---     local packed = assert(Compress.encode("zstd", text, { level = 19 }))
---     local back = assert(Compress.decode("zstd", packed, { max_bytes = #text }))

-- The raw module behind the streaming codecs lives under the reserved
-- `cosmic.internal.` namespace -- see cosmic/store.tl for why it is off
-- the public surface.
local type raw_compress = require("cosmic.internal.compress")

local Failure = require("cosmic.failure")
local Stream = require("cosmic.stream")

local raw = require("cosmic.internal.compress")

-- A codec of the core as a Stream.Transform: the core's text failures
-- become Failures here, and the rest passes through.
local class Coder is Stream.Transform
  --- The core's codec this one stands over.
  raw: raw_compress.Stream

  --- Feeds `chunk`; the output that is ready, at most `max_bytes` of
  --- it for a decoder (1 MiB when not given).
  function update(self, chunk: string, max_bytes?: integer): (string) | (nil, Failure)
    local out, why = self.raw:update(chunk, max_bytes)
    if out == nil then return nil, Failure.new(why) end
    return out
  end

  --- No more input: what is left. It raises while `pending` is true.
  function finish(self): (string) | (nil, Failure)
    local out, why = self.raw:finish()
    if out == nil then return nil, Failure.new(why) end
    return out
  end

  --- Whether a decoder holds output that `update("")` gives out.
  function pending(self): boolean
    return self.raw:pending()
  end

  --- Whether a decoder has seen the end of the compressed data.
  function done(self): boolean
    return self.raw:done()
  end

  --- The input fed after the end of the compressed data, "" if none.
  function rest(self): string
    return self.raw:rest()
  end

  function __close(self, _: any)
    local _held <close> = self.raw
  end
end

local function coder(raw_stream: raw_compress.Stream): Coder
  return { raw = raw_stream }
end

local record Compress
  --- The formats: bare "raw" deflate (RFC 1951, as zip stores it),
  --- "zlib" (RFC 1950), "gzip" (RFC 1952), "zstd" (RFC 8878), "xz" (the
  --- .xz container) and "bz2" (bzip2).
  enum Format
    "raw"
    "zlib"
    "gzip"
    "zstd"
    "xz"
    "bz2"
  end

  --- One incremental transform, a chunk at a time: a
  --- [`Stream.Transform`], so [`Stream.transform`],
  --- [`Stream.transform_writer`] and [`Stream.run`] drive it. Every
  --- method that can fail, and each constructor, returns its value or
  --- nil and a [`Failure`].
  ---
  --- `update(chunk, max_bytes?)` feeds `chunk` and returns output,
  --- possibly "". A decoder returns at most `max_bytes` bytes per
  --- call (default 1 MiB), however far a small input expands: input it
  --- has not got to yet stays inside the stream, and [`pending()`] turns
  --- true.
  --- While [`pending()`] is true, `update("")` returns the next piece
  --- without new input (it may return "" once, when the limit fell
  --- exactly at the end). An encoder returns all of its output and
  --- is never pending. On corrupt data `update` returns nil and a
  --- Failure, and the stream is finished.
  ---
  --- [`finish()`] says no more input follows and returns what is left:
  --- an encoder's last block and trailer, and for a decoder only what
  --- follows its drained output (in practice ""). It raises while
  --- [`pending()`] is true, so its output is bounded too; drain first:
  ---
  ---     local out = assert(s:update(chunk))   -- use out
  ---     while s:pending() do
  ---       out = assert(s:update(""))          -- use out
  ---     end
  ---     ...                                   -- at end of input:
  ---     local last = assert(s:finish())       -- a small tail at most
  ---
  --- A decoder's `finish` fails when the compressed data stopped
  --- early ("truncated ... stream"). After `finish`, after an error,
  --- after a raise inside `update` or `finish` (out of memory: the
  --- codec may have taken input it can no longer account for), or
  --- once closed, `update` and `finish` throw. A stream is closeable:
  --- `local s <close> = assert(Compress.decoder("gzip"))` frees its
  --- codec at the end of the scope; [`rest()`] still works after.
  ---
  --- [`done()`] turns true once a decoder has seen the end of the
  --- compressed data, and [`rest()`] returns the input bytes fed after
  --- that end ("" if none). Raw deflate and zlib hold exactly one
  --- stream, so both end the moment it does. gzip, xz, bzip2 and zstd
  --- allow one member (for zstd, a frame or a skippable frame) after
  --- another, so after a member ends the decoder
  --- waits for the next input: bytes that begin that format's magic
  --- start another member, and anything else ends the data there and
  --- goes, in full, to [`rest()`] -- however the input was split into
  --- chunks. Until such a byte (or `finish`) arrives, [`done()`] stays
  --- false. At `finish`, a partial magic after at least one member is
  --- trailing bytes, not truncation. xz stream padding (NUL bytes in
  --- multiples of four between and after streams) is skipped; NULs
  --- that are not a whole multiple of four are trailing bytes.
  type Stream = Coder

  --- How [`Compress.encode`] and [`Compress.encoder`] compress. An option
  --- the format does not read raises.
  record EncodeOptions
    --- How hard to compress, by the format's own scale: 0 to 10 for
    --- "raw", "zlib" and "gzip" (default 6, miniz's); 1 to 19 for
    --- "zstd" (default 3, the `zstd` command's); 0 to 9 for "xz", its
    --- `-0` to `-9` preset (default 6); and 1 to 9 for "bz2", the block
    --- size in units of 100 kB (default 9). A level out of range raises.
    level?: integer
    --- "xz" alone: the preset's "extreme" variant, `xz -e`, slower for
    --- a little more compression. Default false.
    extreme?: boolean
  end

  --- How [`Compress.decode`] and [`Compress.decoder`] expand. An option
  --- the format does not read raises.
  record DecodeOptions
    --- [`Compress.decode`] alone: the most bytes of output; more is a
    --- failure rather than a result. Under 0 raises.
    max_bytes?: integer
    --- "xz" alone: the most bytes of decoder memory a stream's headers
    --- may ask for (default 256 MiB; `xz -9` needs 65 MiB); more fails
    --- with "xz memory limit exceeded". Not positive raises.
    max_memory?: integer
    --- "zstd" alone: the largest window a frame's header may declare
    --- (default 128 MiB, which every level the `zstd` command writes
    --- without `--long` or `--ultra` fits); a larger one fails with
    --- "zstd window larger than the limit", however the input is split.
    --- Under 1024 raises.
    max_window?: integer
  end
end

local record Range
  low: integer
  high: integer
end

-- Each format's lowest and highest level.
local levels <const>: {string: Range} = {
  raw = { low = 0, high = 10 }, zlib = { low = 0, high = 10 }, gzip = { low = 0, high = 10 },
  zstd = { low = 1, high = 19 }, xz = { low = 0, high = 9 }, bz2 = { low = 1, high = 9 },
}

--- Raises, blaming the caller of the public function that calls it, on
--- a format that is not one of [`Compress.Format`]'s, which a caller
--- past the checker can pass.
local function check_format(format: Compress.Format)
  if levels[format] == nil then
    error("compress: unknown format " .. string.format("%q", format), 4)
  end
end

--- Raises, blaming the caller of the public function that calls it, on
--- an option `format` does not read or a value out of its range. The
--- levels 3 and 4 count the frames from here (and from check_format)
--- to that caller, so each public function calls these directly.
local function check_encode(format: Compress.Format, opts?: Compress.EncodeOptions)
  check_format(format)
  if opts == nil then return end
  if opts.extreme ~= nil and format ~= "xz" then
    error("compress: extreme is not an option of " .. format, 3)
  end
  local level = opts.level
  if level ~= nil then
    local range = assert(levels[format])
    if level < range.low or level > range.high then
      error(string.format("compress: %s level must be %d to %d, not %d",
        format, range.low, range.high, level), 3)
    end
  end
end

--- As [`check_encode`], for decoding.
local function check_decode(format: Compress.Format, opts?: Compress.DecodeOptions)
  check_format(format)
  if opts == nil then return end
  if opts.max_memory ~= nil and format ~= "xz" then
    error("compress: max_memory is not an option of " .. format, 3)
  end
  if opts.max_window ~= nil and format ~= "zstd" then
    error("compress: max_window is not an option of " .. format, 3)
  end
  if opts.max_memory ~= nil and opts.max_memory <= 0 then
    error("compress: max_memory must be positive", 3)
  end
  if opts.max_window ~= nil and opts.max_window < 1024 then
    error("compress: max_window must be at least 1024", 3)
  end
end

local function deflate_family(format: Compress.Format): boolean
  return format == "raw" or format == "zlib" or format == "gzip"
end

-- Compress.encoder, its failure in words. `size`, when given, is the
-- whole input's length, which a zstd frame then declares.
local function encoder_text(format: Compress.Format, opts?: Compress.EncodeOptions, size?: integer): raw_compress.Stream?, string
  local level = if opts ~= nil then opts.level else nil end
  local extreme = if opts ~= nil then opts.extreme else nil end
  if deflate_family(format) then return raw.deflater(format, level) end
  if format == "zstd" then return raw.zstd_encoder(level, size) end
  if format == "xz" then return raw.xz_encoder(level, extreme == true) end
  return raw.bz2_encoder(level)
end

-- Compress.decoder, its failure in words.
local function decoder_text(format: Compress.Format, opts?: Compress.DecodeOptions): raw_compress.Stream?, string
  local max_memory = if opts ~= nil then opts.max_memory else nil end
  local max_window = if opts ~= nil then opts.max_window else nil end
  if deflate_family(format) then return raw.inflater(format) end
  if format == "zstd" then return raw.zstd_decoder(max_window) end
  if format == "xz" then return raw.xz_decoder(max_memory) end
  return raw.bz2_decoder()
end

--- A streaming encoder for `format`, at `opts.level` ([`Compress.EncodeOptions`]).
--- Each writes what its format's own command writes, the same from run
--- to run however the input is split:
---
--- - "gzip": a ten-byte header (mtime 0, OS 255, no extra fields) and
---   the CRC-32/ISIZE trailer.
--- - "zstd": one frame with a checksum of its content.
--- - "xz": one stream of one LZMA2 block with a CRC-64 check. Its
---   level sets the dictionary, and with it the memory the encoder
---   holds while it runs: about 3 MiB at 0, 9 at 1, 17 at 2, 32 at 3,
---   48 at 4, 94 at 5 and 6, 186 at 7, 370 at 8 and 674 at 9; with
---   `extreme`, 4 MiB at 0, 13 at 1, 25 at 2 and 48 at 3 to 9. The
---   decoder needs about the dictionary alone (65 MiB at 9). Lua's
---   accounting does not see that memory, so a caller that holds many
---   encoders, or uses levels 8 and 9 in a server, holds each
---   `<close>`. When the machine refuses an allocation, this call, or
---   `update` or `finish`, returns nil and a [`Failure`] "compress: out
---   of memory", and the stream is then finished. It runs on one
---   thread, and [`Compress.decoder`] reads what it writes at the
---   default `max_memory` at every level.
--- - "bz2": one stream, byte for byte what `bzip2 -c -<level>` writes;
---   given nothing, the 14 bytes of an empty stream. It holds about
---   262 kB plus eight times the block size (7.5 MB at level 9).
---
---     local gz <close> = assert(Compress.encoder("gzip", { level = 9 }))
function Compress.encoder(format: Compress.Format, opts?: Compress.EncodeOptions): (Compress.Stream) | (nil, Failure)
  check_encode(format, opts)
  local value, why = encoder_text(format, opts)
  if value == nil then return nil, Failure.new(why) end
  return coder(value)
end

--- A streaming decoder for `format`, held to `opts` ([`Compress.DecodeOptions`]).
--- Each reads every member of a multi-member input and checks what its
--- format carries:
---
--- - "gzip": the header (FEXTRA, FNAME, FCOMMENT and FHCRC too) and the
---   CRC-32 and ISIZE trailer.
--- - "zstd": frames one after another, skippable frames among them,
---   and each frame's checksum where it has one.
--- - "xz": streams and stream padding; the filters LZMA2, delta, x86
---   BCJ and ARM64 BCJ, and the checks CRC32, CRC64 and SHA-256, each
---   verified, or none (`xz --check=none`). A stream that names a check
---   the format reserves is refused with "unsupported xz integrity
---   check", since none of it could be verified.
--- - "bz2": streams one after another.
function Compress.decoder(format: Compress.Format, opts?: Compress.DecodeOptions): (Compress.Stream) | (nil, Failure)
  if opts ~= nil and opts.max_bytes ~= nil then
    error("compress: max_bytes is an option of Compress.decode, not of a decoder", 2)
  end
  check_decode(format, opts)
  local value, why = decoder_text(format, opts)
  if value == nil then return nil, Failure.new(why) end
  return coder(value)
end

--- `data` compressed whole in `format`, as [`Compress.encoder`] writes
--- it. A "zstd" frame made here also declares `#data` as its content
--- size and keeps its window to 8 MiB (2^23): the frame that a decoder
--- which refuses any other, such as the portable artifact's decode
--- stub, takes.
---
---     local packed = assert(Compress.encode("gzip", page))
function Compress.encode(format: Compress.Format, data: string, opts?: Compress.EncodeOptions): (string) | (nil, Failure)
  check_encode(format, opts)
  local encoder, why = encoder_text(format, opts, #data)
  if encoder == nil then return nil, Failure.new(why) end
  return Stream.run(coder(encoder), data)
end

--- `data` expanded whole from `format`, as [`Compress.decoder`] reads
--- it. More than `opts.max_bytes` bytes of output fails, as do bytes
--- after the end of the compressed data.
---
---     local text = assert(Compress.decode("gzip", body, { max_bytes = 1 << 20 }))
function Compress.decode(format: Compress.Format, data: string, opts?: Compress.DecodeOptions): (string) | (nil, Failure)
  if opts ~= nil and opts.max_bytes ~= nil and opts.max_bytes < 0 then
    error("compress: max_bytes must be at least 0", 2)
  end
  check_decode(format, opts)
  local raw_decoder, why = decoder_text(format, opts)
  if raw_decoder == nil then return nil, Failure.new(why) end
  local decoder = coder(raw_decoder)
  local max_bytes = if opts ~= nil then opts.max_bytes else nil end
  local out, trouble = Stream.run(decoder, data, max_bytes)
  if out == nil then return nil, trouble end
  if decoder:rest() ~= "" then
    return nil, Failure.new("compress: trailing bytes after the compressed data")
  end
  return out
end

return Compress
