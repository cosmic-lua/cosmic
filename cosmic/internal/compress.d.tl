-- Streaming compression codecs at the Lua boundary, as the core
-- provides them.

local record compress
  record Stream
    userdata

    -- Feeds a chunk of input, returning all output it produces (which
    -- may be ""). nil, error on corrupt data; the stream is finished
    -- after an error.
    update: function(Stream, chunk: string): string | nil, string
    -- No more input: returns remaining output. For a decoder, errors
    -- if the compressed stream ended early.
    finish: function(Stream): string | nil, string
    -- Decoder only: whether the end of the compressed stream has been
    -- reached.
    done: function(Stream): boolean
    -- Decoder only: input bytes fed after the end of the stream, "" if
    -- none.
    rest: function(Stream): string
  end

  inflater: function(format: string): Stream | nil, string
  deflater: function(format: string, level?: integer): Stream | nil, string
  xz_decoder: function(): Stream | nil, string
  bz2_decoder: function(): Stream | nil, string
  crc32: function(data: string, crc?: integer): integer
end

return compress
