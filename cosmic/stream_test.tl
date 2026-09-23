--- Proves the Reader/Writer constructors read and write exactly what
--- they are given, in bounded chunks, and that failures propagate.

local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")

local function drain(reader: Stream.Reader, max?: integer): string
  local parts: {string} = {}
  while true do
    local chunk, trouble = reader:read(max)
    assert(trouble == "", trouble)
    if chunk == nil then break end
    parts[#parts + 1] = chunk
  end
  return table.concat(parts)
end

local function test_from_string_reads_the_whole_thing_and_then_eof()
  local r = Stream.from_string("hello world")
  assert(drain(r) == "hello world")
  local chunk, trouble = r:read()
  assert(chunk == nil and trouble == "")
end

local function test_from_string_honors_max()
  local r = Stream.from_string("abcdefgh")
  assert(r:read(3) == "abc")
  assert(r:read(3) == "def")
  assert(r:read(3) == "gh")
  local chunk, trouble = r:read(3)
  assert(chunk == nil and trouble == "")
end

local function test_from_string_empty_is_immediate_eof()
  local r = Stream.from_string("")
  local chunk, trouble = r:read()
  assert(chunk == nil and trouble == "")
end

local function test_open_reads_a_file_and_closes_at_eof(tmp: string)
  local path = tmp .. "/data"
  assert(Fs.write(path, "some file contents"))
  local r = assert(Stream.open(path))
  assert(drain(r, 5) == "some file contents")
  -- a second read past eof is fine and stays eof
  local chunk, trouble = r:read()
  assert(chunk == nil and trouble == "")
end

local function test_open_missing_file_fails(tmp: string)
  local r, trouble = Stream.open(tmp .. "/missing")
  assert(r == nil and trouble:find(tmp, 1, true))
end

local function test_from_fd_does_not_close_the_descriptor(tmp: string)
  local path = tmp .. "/data"
  assert(Fs.write(path, "xyz"))
  local fd = assert(Fs.open_read(path))
  local r = Stream.from_fd(fd)
  assert(drain(r) == "xyz")
  -- the descriptor is still open: reading again from the start works
  assert(Fs.close(fd))
end

local function test_limit_stops_early_and_leaves_the_rest_unread()
  local underlying = Stream.from_string("0123456789")
  local limited = Stream.limit(underlying, 4)
  assert(drain(limited) == "0123")
  local chunk, trouble = limited:read()
  assert(chunk == nil and trouble == "")
  -- the underlying reader picks up right where the limit left off
  assert(drain(underlying) == "456789")
end

local function test_limit_tolerates_underlying_ending_early()
  local underlying = Stream.from_string("ab")
  local limited = Stream.limit(underlying, 10)
  assert(drain(limited) == "ab")
end

local function test_read_exact_reads_precisely_that_many_bytes()
  local r = Stream.from_string("abcdefgh")
  local chunk, trouble = Stream.read_exact(r, 5)
  assert(chunk == "abcde" and trouble == "")
  assert(r:read() == "fgh")
end

local function test_read_exact_fails_short_of_the_target()
  local r = Stream.from_string("abc")
  local chunk, trouble = Stream.read_exact(r, 5)
  assert(chunk == nil and trouble:find("wanted 5", 1, true))
end

local function test_read_exact_of_zero_never_touches_the_reader()
  local r = Stream.from_string("")
  local chunk, trouble = Stream.read_exact(r, 0)
  assert(chunk == "" and trouble == "")
end

local function test_read_all_concatenates_every_chunk()
  local r = Stream.from_string("abc")
  assert(Stream.read_all(r) == "abc")
end

local function test_to_fd_writes_without_closing(tmp: string)
  local path = tmp .. "/out"
  local fd = assert(Fs.open_write(path))
  local w = Stream.to_fd(fd)
  assert(w:write("hello "))
  assert(w:write("world"))
  assert(w:close())
  assert(Fs.close(fd))
  assert(Fs.read(path) == "hello world")
end

local function test_create_renames_into_place_only_on_close(tmp: string)
  local path = tmp .. "/target"
  local w = assert(Stream.create(path))
  assert(w:write("first "))
  assert(w:write("second"))
  -- nothing at the destination until close
  assert(Fs.exists(path) == false)
  assert(w:close())
  assert(Fs.read(path) == "first second")
end

local function test_create_leaves_no_temp_file_when_write_fails(tmp: string)
  local sys = require("cosmic.sys")
  local path = tmp .. "/target"
  local real_write = sys.write
  sys.write = function(_fd: integer, _data: string): integer | nil, string, integer
    return nil, "injected failure", 0
  end
  local w = assert(Stream.create(path))
  local ok = w:write("data")
  sys.write = real_write
  assert(not ok)
  local closed, trouble = w:close()
  assert(not closed and trouble:find("injected failure", 1, true))
  assert(Fs.exists(path) == false)
  local left = assert(Fs.list(tmp))
  assert(#left == 0, table.concat(left, ","))
end

local function test_collect_gathers_every_write()
  local c = Stream.collect()
  assert(c:write("a"))
  assert(c:write("b"))
  assert(c:write("c"))
  assert(c:result() == "abc")
  assert(c:close())
end

local function test_transform_applies_a_fake_codec_across_chunk_boundaries()
  -- A fake codec that upper-cases everything it sees, splitting its
  -- own output oddly to prove the transform Reader does not assume
  -- one chunk in yields one chunk out.
  local pending = ""
  local codec: Stream.CodecStream = {}
  codec.update = function(_self: Stream.CodecStream, chunk: string): string | nil, string
    pending = pending .. chunk:upper()
    local out = pending:sub(1, 1)
    pending = pending:sub(2)
    return out, ""
  end
  codec.finish = function(_self: Stream.CodecStream): string | nil, string
    return pending, ""
  end
  codec.done = function(_self: Stream.CodecStream): boolean
    return pending == ""
  end
  codec.rest = function(_self: Stream.CodecStream): string
    return pending
  end
  local underlying = Stream.from_string("hello world")
  local transformed = Stream.transform(underlying, codec)
  assert(drain(transformed) == "HELLO WORLD")
end

local function test_transform_writer_flushes_the_codec_on_close()
  local held = ""
  local codec: Stream.CodecStream = {}
  codec.update = function(_self: Stream.CodecStream, chunk: string): string | nil, string
    held = held .. chunk
    return "", ""
  end
  codec.finish = function(_self: Stream.CodecStream): string | nil, string
    return held, ""
  end
  codec.done = function(_self: Stream.CodecStream): boolean
    return true
  end
  codec.rest = function(_self: Stream.CodecStream): string
    return ""
  end
  local c = Stream.collect()
  local w = Stream.transform_writer(c as Stream.Writer, codec)
  assert(w:write("ab"))
  assert(w:write("cd"))
  assert(c:result() == "")
  assert(w:close())
  assert(c:result() == "abcd")
end

local function test_transform_serves_small_reads_from_one_large_batch()
  -- A codec that hands back its entire input as one batch on the
  -- first update, then nothing more. `transform` used to re-slice the
  -- whole remaining batch on every read (`pending = pending:sub(want
  -- + 1)`), which is quadratic when a caller reads in small pieces --
  -- this proves reads of any size still see the batch intact and in
  -- order, not just that it eventually finishes.
  local given = false
  local codec: Stream.CodecStream = {}
  codec.update = function(_self: Stream.CodecStream, chunk: string): string | nil, string
    if given then return "", "" end
    given = true
    return chunk, ""
  end
  codec.finish = function(_self: Stream.CodecStream): string | nil, string
    return "", ""
  end
  codec.done = function(_self: Stream.CodecStream): boolean
    return given
  end
  codec.rest = function(_self: Stream.CodecStream): string
    return ""
  end
  local big = string.rep("0123456789", 5000) -- 50,000 bytes, under the
    -- 64 KiB the transform Reader pulls from `underlying` at once, so
    -- the whole thing reaches the codec, and this Reader, in one batch
  local underlying = Stream.from_string(big)
  local transformed = Stream.transform(underlying, codec)
  local out = drain(transformed, 7) -- an odd small size, on purpose
  assert(out == big, "length " .. tostring(#out))
end
