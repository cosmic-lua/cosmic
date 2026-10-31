--- Compression and expansion: one-shot deflate and inflate in the raw,
--- zlib and gzip framings, streaming encoders and decoders for the same
--- three, for zstd, for xz and for bzip2.

-- The raw module behind the streaming codecs lives under the reserved
-- `cosmic.internal.` namespace -- see cosmic/store.tl for why it is off
-- the public surface.
local type raw_compress = require("cosmic.internal.compress")

local Stream = require("cosmic.stream")

local raw = require("cosmic.internal.compress")

--- What a failure of this module answers, nil and `why` under the
--- module's name.
local function refuse(why: string): nil, string
  return nil, "compress: " .. why
end

local record Compress
  --- The deflate framings: bare "raw" deflate (RFC 1951, as zip
  --- stores it), "zlib" (RFC 1950), and "gzip" (RFC 1952).
  enum Format
    "raw"
    "zlib"
    "gzip"
  end

  --- One incremental transform, a chunk at a time: a
  --- [`Stream.Transform`], so [`Stream.transform`],
  --- [`Stream.transform_writer`] and [`Stream.run`] drive it. Every
  --- call that can fail answers `value, ""` on success and
  --- `nil, error` on failure, like the constructors.
  ---
  --- `update(chunk, max_bytes?)` feeds `chunk` and returns output,
  --- possibly "". A decoder returns at most `max_bytes` bytes per
  --- call (default 1 MiB), however far a small input expands: input it
  --- has not got to yet stays inside the stream, and `pending()` turns
  --- true.
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
  --- stream, so both end the moment it does. gzip, xz, bzip2 and zstd
  --- allow one member (for zstd, a frame or a skippable frame) after
  --- another, so after a member ends the decoder
  --- waits for the next input: bytes that begin that format's magic
  --- start another member, and anything else ends the data there and
  --- goes, in full, to `rest()` -- however the input was split into
  --- chunks. Until such a byte (or `finish`) arrives, `done()` stays
  --- false. At `finish`, a partial magic after at least one member is
  --- trailing bytes, not truncation. xz stream padding (NUL bytes in
  --- multiples of four between and after streams) is skipped; NULs
  --- that are not a whole multiple of four are trailing bytes.
  type Stream = raw_compress.Stream

  --- What [`Compress.xz_encoder`] takes besides the preset.
  record XzOptions
    --- The preset's "extreme" variant, `xz -e`: slower, for a little
    --- more compression. Default false.
    extreme: boolean
  end
end

--- Compresses `data` whole in the `format` framing, at `level` as
--- `deflater(format, level)` takes it; raises where that does.
function Compress.deflate(format: Compress.Format, data: string, level?: integer):
    string?, string
  local enc, trouble = raw.deflater(format, level)
  if enc == nil then return nil, trouble end
  return Stream.run(enc, data)
end

--- Expands `data`, whole, from the `format` framing, such as `deflate`
--- produced; raises on an unknown format. When `max_bytes` is given,
--- more than `max_bytes` bytes of output is an error rather than an
--- answer, and a `max_bytes` under 0
--- raises. Bytes after the end of the compressed data are an error
--- too.
function Compress.inflate(format: Compress.Format, data: string, max_bytes?: integer):
    string?, string
  if max_bytes ~= nil and max_bytes < 0 then
    error("compress: max_bytes must be at least 0", 2)
  end
  local dec, trouble = raw.inflater(format)
  if dec == nil then return nil, trouble end
  local out, run_trouble = Stream.run(dec, data, max_bytes)
  if out == nil then return nil, run_trouble end
  if dec:rest() ~= "" then
    return refuse("trailing bytes after the compressed data")
  end
  return out, ""
end

--- A streaming decoder for `format`. A gzip decoder parses the header
--- (including FEXTRA/FNAME/FCOMMENT/FHCRC), verifies the CRC-32 and
--- ISIZE trailer, and decodes every member of a multi-member stream.
--- Raises on an unknown format.
function Compress.inflater(format: Compress.Format): Compress.Stream?, string
  return raw.inflater(format)
end

--- A streaming encoder for `format` at `level`, 0 to 10 (default the
--- miniz default, 6); raises on an unknown format or a level out of
--- range. A gzip encoder writes a minimal ten-byte header (mtime 0,
--- OS 255, no extra fields) and the CRC-32/ISIZE trailer.
function Compress.deflater(format: Compress.Format, level?: integer): Compress.Stream?, string
  return raw.deflater(format, level)
end

--- A streaming decoder for the .xz container: multi-stream and stream
--- padding are handled. The filters are LZMA2, delta, x86 BCJ and
--- ARM64 BCJ, and the checks are CRC32, CRC64 and SHA-256. The decoder
--- refuses, with "xz memory limit exceeded", a stream whose headers
--- ask for more than `max_memory` bytes of decoder memory (default 256
--- MiB; `xz -9` needs 65 MiB).
--- Raises when `max_memory` is not positive.
function Compress.xz_decoder(max_memory?: integer): Compress.Stream?, string
  return raw.xz_decoder(max_memory)
end

--- A streaming decoder for .bz2: multi-stream is handled.
function Compress.bz2_decoder(): Compress.Stream?, string
  return raw.bz2_decoder()
end

--- A streaming decoder for zstd (RFC 8878): frames one after another
--- and skippable frames among them are handled, and each frame's
--- checksum, when it has one, is verified. The decoder refuses, with
--- "zstd window larger than the limit", a frame whose header declares
--- a window over `max_window` bytes (default 128 MiB, which every level
--- the `zstd` command writes without `--long` or `--ultra` fits): the
--- limit is compared with the window the header declares, which is not
--- always a power of two, however the input is split.
--- Raises when `max_window` is under 1024.
function Compress.zstd_decoder(max_window?: integer): Compress.Stream?, string
  return raw.zstd_decoder(max_window)
end

--- A streaming zstd encoder at `level`, 1 to 19 (default 3, the `zstd`
--- command's); raises on a level out of range. It writes one frame,
--- with a checksum of its content, as the `zstd` command does; its
--- output for the same input and level is the same from run to run.
function Compress.zstd_encoder(level?: integer): Compress.Stream?, string
  return raw.zstd_encoder(level)
end

--- A streaming encoder for the .xz container, one stream of one LZMA2
--- block with a CRC-64 check, as the `xz` command writes: `preset` is
--- its `-0` to `-9` (default 6) and `opts.extreme` its `-e`. Raises on
--- a preset out of range. The output for the same input and options is
--- the same from run to run, and does not depend on how the input is
--- split into chunks.
---
--- A preset sets the encoder's dictionary, and with it the memory the
--- encoder takes while it runs: about 3 MiB at `0`, 9 at `1`, 17 at `2`,
--- 32 at `3`, 48 at `4`, 94 at `5` and `6`, 186 at `7`, 370 at `8` and
--- 674 at `9`. With `extreme` it is 4 MiB at `0`, 13 at `1`, 25 at `2`
--- and 48 at `3`, and the same at `4` to `9`. The decoder needs about
--- the dictionary alone (65 MiB for a stream written at `9`).
---
--- An encoder keeps that memory until `finish`, `close` or collection,
--- and Lua's accounting does not see it: a caller that holds many
--- encoders, or uses presets 8 and 9 in a server, should hold each
--- `<close>`. Presets are not capped below 9, as the `xz` command's are
--- not; an allocation the machine refuses answers nil and "compress:
--- out of memory" (from the constructor) or, from `update` or
--- `finish`, finishes the stream and answers the same. Only a single
--- thread is used. [`Compress.xz_decoder`] reads what this writes at
--- its default memory limit through preset 9.
function Compress.xz_encoder(preset?: integer, opts?: Compress.XzOptions): Compress.Stream?, string
  local extreme: boolean? = nil
  if opts ~= nil then extreme = opts.extreme == true end
  return raw.xz_encoder(preset, extreme)
end

--- A streaming bzip2 encoder: `level` is the block size in units of
--- 100 kB, 1 to 9 (default 9, the `bzip2` command's); raises on a level
--- out of range. It writes one stream, byte for byte what `bzip2 -c
--- -<level>` writes for the same input however the input is split, and
--- an encoder given nothing writes the 14 bytes of an empty stream.
--- It holds about 262 kB plus eight times the block size (7.5 MB at
--- level 9, where the block is 900 kB) until it finishes.
function Compress.bz2_encoder(level?: integer): Compress.Stream?, string
  return raw.bz2_encoder(level)
end

return Compress
