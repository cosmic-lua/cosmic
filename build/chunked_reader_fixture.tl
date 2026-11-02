--- A stream that answers a text in chunks, for the tests of the readers
--- that take a [`Stream.Reader`] (cosmic/json_reader_test.tl and
--- cosmic/json_reader_fuzz_test.tl, cosmic/http/multipart_test.tl and
--- cosmic/http/multipart_fuzz_test.tl). Test support.

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

--- Skips `n` bytes as an in-memory Reader does: failing on a negative
--- count and on running past the end, which leaves the Reader at the end.
local function skip(self: Chunked, n: integer): boolean, string
  if n < 0 then return false, "stream: skip of a negative count" end
  -- Compared this way round, so a huge `n` cannot wrap `at + n`.
  if n > #self.text + 1 - self.at then
    self.at = #self.text + 1
    return false, "stream: skip past the end of the data"
  end
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

local class Dripped is Stream.Reader
  mut skip: function(Dripped, n: integer): boolean, string
  inner: Stream.Reader
  most: integer

  function read(self, max_bytes?: integer): string?, string
    return self.inner:read(math.min(self.most, max_bytes or self.most))
  end

  function close(self): boolean, string
    return self.inner:close()
  end
end

--- Skips `n` bytes of the reader `self` hands out.
local function dripped_skip(self: Dripped, n: integer): boolean, string
  return self.inner:skip(n)
end

--- A Reader over `text` that hands out at most `n` bytes a read.
--- @param text what it reads
--- @param n the most a read answers
--- @return the reader
function chunked_reader_fixture.drip(text: string, n: integer): Stream.Reader
  local r: Dripped = { skip = dripped_skip, inner = Stream.from_string(text), most = n }
  return r
end

return chunked_reader_fixture
