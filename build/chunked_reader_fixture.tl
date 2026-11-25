--- A stream that gives a text in chunks, for the tests of the readers
--- that take a [`Stream.Reader`] (cosmic/json_reader_test.tl and
--- cosmic/json_reader_fuzz_test.tl, cosmic/http/multipart_test.tl and
--- cosmic/http/multipart_fuzz_test.tl). Test support.

local Failure = require("cosmic.failure")
local Stream = require("cosmic.stream")

local record chunked_reader_fixture
end

local class Chunked is Stream.Reader
  skip?: function(Chunked, n: integer): (true) | (false, Failure)
  text: string
  mut at: integer
  size: integer
  last: string

  function read(self, _max_bytes?: integer): (string | false) | (nil, Failure)
    if self.at > #self.text then
      if self.last == "" then return false end
      return nil, Failure.new(self.last)
    end
    local chunk = self.text:sub(self.at, self.at + self.size - 1)
    self.at = self.at + self.size
    return chunk
  end

  function close(self): (true) | (false, Failure)
    return true
  end
end

--- Skips `n` bytes as an in-memory Reader does: failing on a negative
--- count and on running past the end, which leaves the Reader at the end.
local function skip(self: Chunked, n: integer): (true) | (false, Failure)
  if n < 0 then return false, Failure.new("stream: skip of a negative count") end
  -- Compared this way round, so a huge `n` cannot wrap `at + n`.
  if n > #self.text + 1 - self.at then
    self.at = #self.text + 1
    return false, Failure.new("stream: skip past the end of the data")
  end
  self.at = self.at + n
  return true
end

--- A Reader that gives `text` in chunks of `size` bytes, then `last`
--- (nil for the end) on every read after.
--- @param text what it gives
--- @param size the bytes of each chunk
--- @param last the failure every read after the text returns; the end where nil
--- @return the reader
function chunked_reader_fixture.chunked(text: string, size: integer, last?: string): Stream.Reader
  local r: Chunked = { skip = skip, text = text, at = 1, size = size, last = last or "" }
  return r
end

local class Dripped is Stream.Reader
  skip?: function(Dripped, n: integer): (true) | (false, Failure)
  inner: Stream.Reader
  most: integer

  function read(self, max_bytes?: integer): (string | false) | (nil, Failure)
    return self.inner:read(math.min(self.most, max_bytes or self.most))
  end

  function close(self): (true) | (false, Failure)
    return self.inner:close()
  end
end

--- Skips `n` bytes of what `self` hands out, as the reader it wraps does.
local function dripped_skip(self: Dripped, n: integer): (true) | (false, Failure)
  return Stream.skip(self.inner, n)
end

--- A Reader over `text` that hands out at most `n` bytes a read.
--- @param text what it reads
--- @param n the most a read returns
--- @return the reader
function chunked_reader_fixture.drip(text: string, n: integer): Stream.Reader
  local r: Dripped = { skip = dripped_skip, inner = Stream.from_string(text), most = n }
  return r
end

return chunked_reader_fixture
