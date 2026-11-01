--- A stream that answers a text in chunks, for the tests of the readers
--- that take a [`Stream.Reader`] (cosmic/json_reader_test.tl and
--- cosmic/json_reader_fuzz_test.tl). Test support.

local Stream = require("cosmic.stream")

local record chunked_reader_fixture
end

local class Chunked is Stream.Reader
  mut skip: function(Chunked, n: integer): boolean, string
  text: string
  mut at: integer
  size: integer
  last: string

  function read(self, _max_bytes?: integer): string?, string
    if self.at > #self.text then return nil, self.last end
    local chunk = self.text:sub(self.at, self.at + self.size - 1)
    self.at = self.at + self.size
    return chunk, ""
  end

  function close(self): boolean, string
    return true, ""
  end
end

local function skip(self: Chunked, n: integer): boolean, string
  self.at = self.at + n
  return true, ""
end

--- A Reader that answers `text` in chunks of `size` bytes, then `last`
--- (nil for the end) on every read after.
--- @param text what it answers
--- @param size the bytes of each chunk
--- @param last the failure every read after the text answers; the end where nil
--- @return the reader
function chunked_reader_fixture.chunked(text: string, size: integer, last?: string): Stream.Reader
  local r: Chunked = { skip = skip, text = text, at = 1, size = size, last = last or "" }
  return r
end

return chunked_reader_fixture
