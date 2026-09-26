--- Proves the Reader/Writer constructors read and write exactly what
--- they are given, in bounded chunks, and that failures propagate.

local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local Time = require("cosmic.time")

--- A plain-table stand-in for a `cosmic.compress` codec, cast to one
--- where `transform` takes it.
local record Fake
  update: function(Fake, string): string | nil, string
  finish: function(Fake): string | nil, string
  done: function(Fake): boolean
  rest: function(Fake): string
  pending: function(Fake): boolean
end

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

local function test_from_string_refuses_a_skip_so_large_it_would_wrap()
  local r = Stream.from_string("abcdefgh")
  assert(r:read(2) == "ab")
  local skipped, why = r:skip(math.maxinteger)
  assert(skipped == false and why ~= "", why)
  local chunk, trouble = r:read()
  assert(chunk == nil and trouble == "")
end

local function test_from_string_reads_the_rest_for_a_read_so_large_it_would_wrap()
  local r = Stream.from_string("abcdefgh")
  assert(r:read(2) == "ab")
  local rest, trouble = r:read(math.maxinteger)
  assert(rest == "cdefgh", tostring(rest) .. " " .. tostring(trouble))
  local after, atrouble = r:read()
  assert(after == nil and atrouble == "")
end

local function test_from_string_refuses_a_negative_skip()
  local r = Stream.from_string("abcdefgh")
  assert(r:read(4) == "abcd")
  local skipped, why = r:skip(-2)
  assert(skipped == false and why ~= "", why)
  assert(r:read(1) == "e")
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
  local codec: Fake = {}
  codec.pending = function(_self: Fake): boolean return false end
  codec.update = function(_self: Fake, chunk: string): string | nil, string
    pending = pending .. chunk:upper()
    local out = pending:sub(1, 1)
    pending = pending:sub(2)
    return out, ""
  end
  codec.finish = function(_self: Fake): string | nil, string
    return pending, ""
  end
  codec.done = function(_self: Fake): boolean
    return pending == ""
  end
  codec.rest = function(_self: Fake): string
    return pending
  end
  local underlying = Stream.from_string("hello world")
  local transformed = Stream.transform(underlying, codec as Stream.Codec)
  assert(drain(transformed) == "HELLO WORLD")
end

local function test_transform_writer_flushes_the_codec_on_close()
  local held = ""
  local codec: Fake = {}
  codec.pending = function(_self: Fake): boolean return false end
  codec.update = function(_self: Fake, chunk: string): string | nil, string
    held = held .. chunk
    return "", ""
  end
  codec.finish = function(_self: Fake): string | nil, string
    return held, ""
  end
  codec.done = function(_self: Fake): boolean
    return true
  end
  codec.rest = function(_self: Fake): string
    return ""
  end
  local c = Stream.collect()
  local w = Stream.transform_writer(c, codec as Stream.Codec)
  assert(w:write("ab"))
  assert(w:write("cd"))
  assert(c:result() == "")
  assert(w:close())
  assert(c:result() == "abcd")
end

local function test_transform_writer_drains_a_decoder_in_bounded_writes()
  -- 16 MiB of zeros compresses to a few KiB; a writer that never
  -- drained `pending()` handed all 16 MiB to `finish` at close.
  local plain_size = 16 * 1024 * 1024
  local packed = assert(Compress.deflate("zlib", string.rep("\0", plain_size)))
  local total, largest = 0, 0
  local sink: Stream.Writer = {
    write = function(_s: Stream.Writer, d: string): boolean, string
      total = total + #d
      if #d > largest then largest = #d end
      return true, ""
    end,
    close = function(_s: Stream.Writer): boolean, string return true, "" end,
    abort = function(_s: Stream.Writer): boolean, string return true, "" end,
  }
  local w = Stream.transform_writer(sink, (assert(Compress.inflater("zlib"))))
  assert(w:write(packed))
  assert(w:close())
  assert(total == plain_size, tostring(total))
  assert(largest <= 1024 * 1024, "one write of " .. tostring(largest) .. " bytes")
end

local function test_transform_serves_small_reads_from_one_large_batch()
  -- A codec that hands back its entire input as one batch on the
  -- first update, then nothing more. `transform` used to re-slice the
  -- whole remaining batch on every read (`pending = pending:sub(want
  -- + 1)`), which is quadratic when a caller reads in small pieces --
  -- this proves reads of any size still see the batch intact and in
  -- order, not just that it eventually finishes.
  local given = false
  local codec: Fake = {}
  codec.pending = function(_self: Fake): boolean return false end
  codec.update = function(_self: Fake, chunk: string): string | nil, string
    if given then return "", "" end
    given = true
    return chunk, ""
  end
  codec.finish = function(_self: Fake): string | nil, string
    return "", ""
  end
  codec.done = function(_self: Fake): boolean
    return given
  end
  codec.rest = function(_self: Fake): string
    return ""
  end
  local big = string.rep("0123456789", 5000) -- 50,000 bytes, under the
    -- 64 KiB the transform Reader pulls from `underlying` at once, so
    -- the whole thing reaches the codec, and this Reader, in one batch
  local underlying = Stream.from_string(big)
  local transformed = Stream.transform(underlying, codec as Stream.Codec)
  local out = drain(transformed, 7) -- an odd small size, on purpose
  assert(out == big, "length " .. tostring(#out))
end

local function test_a_codec_error_is_sticky_rather_than_a_later_false_eof()
  local inflater = assert(Compress.inflater("gzip"))
  local r = Stream.transform(Stream.from_string(string.rep("x", 100)), inflater)
  local first, trouble = r:read()
  assert(first == nil and trouble ~= "")
  for _ = 1, 3 do
    local again, again_trouble = r:read()
    assert(again == nil and again_trouble == trouble, again_trouble)
  end
end

local function test_a_truncated_compressed_stream_fails_at_its_end_every_time()
  local deflater = assert(Compress.deflater("gzip"))
  local packed = assert(deflater:update("hello, world")) .. assert(deflater:finish())
  local inflater = assert(Compress.inflater("gzip"))
  local r = Stream.transform(Stream.from_string(packed:sub(1, #packed - 4)), inflater)
  local parts: {string} = {}
  local trouble = ""
  while true do
    local chunk, why = r:read()
    if chunk == nil then
      trouble = why
      break
    end
    parts[#parts + 1] = chunk
  end
  assert(trouble ~= "", "a truncated gzip stream ended cleanly")
  local again, again_trouble = r:read()
  assert(again == nil and again_trouble == trouble, again_trouble)
end

local function test_a_file_reader_skips_by_seeking_and_refuses_to_pass_the_end(tmp: string)
  local path = tmp .. "/f"
  assert(Fs.write(path, "0123456789"))
  local r = assert(Stream.open(path))
  assert(r.skip ~= nil)
  assert(r:skip(3))
  assert(r:read(2) == "34")
  assert(Stream.skip(r, 2))
  assert(r:read() == "789")
  local skipped, trouble = r:skip(1)
  assert(not skipped and trouble:find("end", 1, true) ~= nil, trouble)
  assert(r:close())
end

local function test_skip_falls_back_to_reading_for_a_reader_that_cannot_seek()
  local r = Stream.limit(Stream.from_string("abcdef"), 6)
  assert(r.skip == nil)
  assert(Stream.skip(r, 4))
  assert(r:read() == "ef")
  local skipped = Stream.skip(Stream.limit(Stream.from_string("ab"), 2), 3)
  assert(not skipped)
end

local function test_a_reader_refuses_reads_after_close(tmp: string)
  local path = tmp .. "/f"
  assert(Fs.write(path, "data"))
  local r = assert(Stream.open(path))
  assert(r:close())
  assert(r:close()) -- idempotent
  local chunk, trouble = r:read()
  assert(chunk == nil and trouble ~= "")
end

local function test_create_abort_leaves_neither_the_file_nor_a_temporary(tmp: string)
  local path = tmp .. "/target"
  local w = assert(Stream.create(path))
  assert(w:write("partial"))
  assert(w:abort())
  assert(w:close()) -- a close after abort commits nothing
  assert(Fs.exists(path) == false)
  local left = assert(Fs.list(tmp))
  assert(#left == 0, table.concat(left, ","))
end

local function test_writers_refuse_writes_after_close(tmp: string)
  local w = assert(Stream.create(tmp .. "/f"))
  assert(w:close())
  assert(w:close()) -- idempotent
  assert(not w:write("late"))
  local c = Stream.collect()
  assert(c:close())
  assert(not c:write("late"))
  local fd = assert(Fs.open_write(tmp .. "/g"))
  local f = Stream.to_fd(fd)
  assert(f:close())
  assert(not f:write("late"))
  assert(Fs.close(fd))
end

local function test_copy_moves_everything_and_can_be_capped()
  local c = Stream.collect()
  local n = assert(Stream.copy(Stream.from_string(string.rep("z", 100000)), c))
  assert(n == 100000 and c:result() == string.rep("z", 100000))
  -- A cap is a limited reader and a count, as the doc comment says.
  local capped = Stream.collect()
  local over = assert(Stream.copy(Stream.limit(Stream.from_string("0123456789"), 6), capped))
  assert(over == 6 and over > 5 and capped:result() == "012345")
end

local function test_tee_feeds_a_hashing_writer_beside_the_real_one()
  local Hash = require("cosmic.hash")
  local c = Stream.collect()
  local h = assert(Stream.hashing("sha256"))
  local w = Stream.tee(c, h)
  assert(w:write("hello "))
  assert(w:write("world"))
  assert(w:close())
  assert(c:result() == "hello world")
  assert(assert(h:digest()) == Hash.sha256("hello world"))
  assert(assert(h:digest()) == Hash.sha256("hello world")) -- asking again is fine
  assert(not h:write("more"))
end

local function test_transform_writer_aborts_its_writer_when_the_codec_fails_to_finish(tmp: string)
  local codec: Fake = {}
  codec.pending = function(_self: Fake): boolean return false end
  codec.update = function(_self: Fake, chunk: string): string | nil, string
    return chunk, ""
  end
  codec.finish = function(_self: Fake): string | nil, string
    return nil, "injected finish failure"
  end
  local path = tmp .. "/out"
  local w = Stream.transform_writer(assert(Stream.create(path)), codec as Stream.Codec)
  assert(w:write("data"))
  local ok, trouble = w:close()
  assert(not ok and trouble:find("injected", 1, true) ~= nil, trouble)
  assert(Fs.exists(path) == false)
  local left = assert(Fs.list(tmp))
  assert(#left == 0, table.concat(left, ","))
end

local function test_transform_drains_a_pending_codec_before_feeding_it_more()
  -- A codec that expands each input byte to ten and hands back at most
  -- four bytes per call, like a bounded decoder: it must be asked for
  -- the rest with update("") before it is given new input.
  local held = ""
  local codec: Fake = {}
  codec.update = function(_self: Fake, chunk: string): string | nil, string
    assert(chunk == "" or held == "", "fed new input while output was pending")
    for i = 1, #chunk do held = held .. string.rep(chunk:sub(i, i), 10) end
    local out = held:sub(1, 4)
    held = held:sub(5)
    return out, ""
  end
  codec.pending = function(_self: Fake): boolean return held ~= "" end
  codec.finish = function(_self: Fake): string | nil, string
    assert(held == "", "finished while output was pending")
    return "", ""
  end
  local transformed = Stream.transform(Stream.from_string("abc"), codec as Stream.Codec)
  assert(drain(transformed) == string.rep("a", 10) .. string.rep("b", 10) .. string.rep("c", 10))
end

--- Every line `Stream.lines` gives `reader`, through `read`, and why it
--- stopped.
local function all_lines(reader: Stream.Reader, max?: integer): {string}, string
  local lines = Stream.lines(reader, max)
  local got: {string} = {}
  while true do
    local line, trouble = lines:read()
    if line == nil then return got, trouble end
    got[#got + 1] = line
  end
end

--- A Reader handing out `s` a byte at a time, whatever it is asked for.
local function trickle(s: string): Stream.Reader
  local inner = Stream.from_string(s)
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, _max?: integer): string | nil, string
    return inner:read(1)
  end
  r.close = function(_self: Stream.Reader): boolean, string
    return inner:close()
  end
  return r
end

local function test_lines_split_on_newlines_whatever_the_chunks()
  local cases: {{string}} = {
    { "a\nb\n", "a", "b" },
    { "a\nb", "a", "b" },
    { "" },
    { "\n\n", "", "" },
    { "a\r\nb", "a\r", "b" },
    { "one\n\nthree", "one", "", "three" },
  }
  for _, case in ipairs(cases) do
    local want = table.concat(case, "|", 2)
    for _, reader in ipairs({ Stream.from_string(case[1]), trickle(case[1]) }) do
      local got, trouble = all_lines(reader)
      assert(trouble == "", trouble)
      assert(table.concat(got, "|") == want, string.format("%q: %s", case[1],
        table.concat(got, "|")))
    end
  end
end

--- A line may be as long as the limit, and no longer, ended by "\n" or
--- by the end of the stream; once it fails, it keeps failing.
local function test_lines_hold_a_line_to_the_limit()
  for _, reader in ipairs({ Stream.from_string("12345\n1234"), trickle("12345\n1234"),
      trickle("12345") }) do
    local got, trouble = all_lines(reader, 5)
    assert(trouble == "" and got[1] == "12345", trouble)
  end
  for _, text in ipairs({ "ok\n123456\nafter", "ok\n123456" }) do
    local lines = Stream.lines(trickle(text), 5)
    assert(lines:read() == "ok")
    local line, why = lines:read()
    assert(line == nil and why:find("longer than 5 bytes", 1, true) ~= nil, why)
    local again, again_why = lines:read()
    assert(again == nil and again_why == why)
  end
  for _, bad in ipairs({ 0, -1, 2.5, 0 / 0 } as {number}) do
    assert(not pcall(Stream.lines, Stream.from_string(""), bad as integer))
  end
end

--- A line spread over many small chunks is joined once, not re-copied
--- per chunk: a 256 KiB line a byte at a time finishes promptly, where
--- copying the partial line per byte would move some 32 GB.
local function test_a_long_line_in_small_chunks_costs_linear_time()
  local long = string.rep("x", 1 << 18)
  local started = Time.monotonic_ns()
  local got, trouble = all_lines(trickle(long .. "\nend"))
  local elapsed = Time.monotonic_ns() - started
  assert(trouble == "" and #got == 2 and got[1] == long and got[2] == "end", trouble)
  -- About a tenth of a second here; copying per byte takes some fifteen.
  assert(elapsed < 5 * 1000 * 1000 * 1000, "took " .. tostring(elapsed // 1000000) .. " ms")
end

--- A Reader's failure ends the lines with it, after the ones before.
local function test_lines_stop_at_a_reader_failure()
  local inner = Stream.from_string("a\nb")
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, max?: integer): string | nil, string
    local chunk, trouble = inner:read(max)
    if chunk == nil and trouble == "" then return nil, "boom" end
    return chunk, trouble
  end
  r.close = function(_self: Stream.Reader): boolean, string return true, "" end
  local lines = Stream.lines(r)
  local seen: {string} = {}
  for line in lines:each() do seen[#seen + 1] = line end
  assert(#seen == 1 and seen[1] == "a", table.concat(seen, "|"))
  assert(lines:failure() == "boom", lines:failure())
end

local function test_each_reads_every_line_and_leaves_no_failure()
  local lines = Stream.lines(Stream.from_string("x\ny\n"))
  local seen: {string} = {}
  for line in lines:each() do seen[#seen + 1] = line end
  assert(table.concat(seen, "|") == "x|y" and lines:failure() == "")
end
