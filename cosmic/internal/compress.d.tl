-- Streaming compression codecs at the Lua boundary, as the core
-- provides them. cosmic/compress.tl documents the contract.

local record compress
  record Stream
    userdata

    -- Feeds a chunk, returning at most `max` bytes of output (a
    -- decoder's default 1 MiB; an encoder returns everything). nil,
    -- error on corrupt data; the stream is finished after an error.
    -- Raises when `max` is not positive.
    update: function(Stream, chunk: string, max?: integer): string | nil, string
    -- No more input: returns all remaining output. For a decoder,
    -- errors if the compressed stream ended early.
    finish: function(Stream): string | nil, string
    -- Decoder only: whether the end of the compressed data was seen.
    done: function(Stream): boolean
    -- Decoder only: whether the last call stopped at its output limit,
    -- so `update("")` may have more to give.
    pending: function(Stream): boolean
    -- Decoder only: input bytes fed after the end of the stream, "" if
    -- none.
    rest: function(Stream): string
  end

  -- Raise on a format other than "raw", "zlib" or "gzip", and on a
  -- level outside 0 to 10.
  inflater: function(format: string): Stream | nil, string
  deflater: function(format: string, level?: integer): Stream | nil, string
  -- Raises when `memlimit` is not positive.
  xz_decoder: function(memlimit?: integer): Stream | nil, string
  bz2_decoder: function(): Stream | nil, string
  -- Raises when `crc` is outside 0 to 0xffffffff.
  crc32: function(data: string, crc?: integer): integer
end

return compress
