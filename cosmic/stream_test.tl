--- Proves the Reader/Writer constructors read and write exactly what
--- they are given, in bounded chunks, and that failures propagate.

local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local Clock = require("cosmic.clock")

--- A plain-table stand-in for a [`cosmic.compress`] codec.
local record Fake is Stream.Transform
  done: function(Fake): boolean
  rest: function(Fake): string
end

local function drain(reader: Stream.Reader, max_bytes?: integer): string
  local parts: {string} = {}
  while true do
    local chunk, trouble = reader:read(max_bytes)
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

local function test_from_string_honors_max_bytes()
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

--- A write after a close says the writer is closed, whichever writer it is,
--- and a read of a closed reader says the reader is.
local function test_a_closed_writer_and_a_closed_reader_say_which_they_are(tmp: string)
  local fd = assert(Fs.open_write(tmp .. "/closed"))
  local collected = Stream.collect()
  local codec: Fake = {}
  codec.pending = function(_self: Fake): boolean return false end
  codec.update = function(_self: Fake, chunk: string): string | nil, string return chunk, "" end
  codec.finish = function(_self: Fake): string | nil, string return "", "" end
  local transformed = Stream.transform_writer(Stream.collect(), codec)
  local hashing = assert(Stream.hashing("sha256"))
  local writers: {Stream.Writer} = { collected, Stream.to_fd(fd), hashing, transformed }
  for i, w in ipairs(writers) do
    assert(w:close())
    local ok, why = w:write("x")
    assert(not ok and why:find("stream: the writer is closed", 1, true) == 1, i .. ": " .. why)
  end
  assert(Fs.close(fd))
  local reader = Stream.from_string("abc")
  assert(reader:close())
  local data, why = reader:read()
  assert(data == nil and why == "stream: the reader is closed", why)
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
  local ok, why = w:write("data")
  sys.write = real_write
  assert(not ok and why == path .. ": injected failure", why)
  local closed, trouble = w:close()
  assert(not closed and trouble == why, trouble)
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
  local transformed = Stream.transform(underlying, codec)
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
  local w = Stream.transform_writer(c, codec)
  assert(w:write("ab"))
  assert(w:write("cd"))
  assert(c:result() == "")
  assert(w:close())
  assert(c:result() == "abcd")
end

local function test_transform_writer_drains_a_decoder_in_bounded_writes()
  -- 16 MiB of zeros compresses to a few KiB; a writer that never
  -- drained `pending()` would hand all 16 MiB to `finish` at close.
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
  -- first update, then nothing more. Re-slicing the whole remaining
  -- batch on every read (`pending = pending:sub(want + 1)`) would be
  -- quadratic for small reads; reads of any size must still see the
  -- batch intact and in order.
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
  local transformed = Stream.transform(underlying, codec)
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

local function test_prepend_yields_the_prefix_then_the_reader()
  local r = Stream.prepend("abc", Stream.from_string("defg"))
  assert(r:read(2) == "ab")
  assert(r:read() == "c")
  assert(r:read(3) == "def")
  assert(r:read() == "g")
  local done, trouble = r:read()
  assert(done == nil and trouble == "", trouble)
  assert(r:close())
  local none, why = r:read()
  assert(none == nil and why ~= "")
end

local function test_prepend_of_nothing_is_the_reader_and_close_closes_it()
  local inner = Stream.from_string("xy")
  local r = Stream.prepend("", inner)
  assert(Stream.read_all(r) == "xy")
  assert(r:close())
  local none, why = inner:read()
  assert(none == nil and why ~= "")
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

--- A file's `sync` goes through the Writer `create` returns, so a caller
--- that wants the bytes durable before the rename asks for it there.
local function test_create_syncs_before_it_closes(tmp: string)
  local path = tmp .. "/target"
  local w = assert(Stream.create(path))
  assert(w:write("kept"))
  assert(w:sync())
  assert(Fs.exists(path) == false)
  assert(w:close())
  assert(Fs.read(path) == "kept")
  local missing = tmp .. "/missing/target"
  local made, trouble = Stream.create(missing)
  assert(made == nil and trouble:find(missing .. ": ", 1, true) == 1, trouble)
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

local function test_hashing_with_a_key_answers_the_hmac_and_none_means_plain()
  local Hash = require("cosmic.hash")
  local algorithms: {Hash.Algorithm} = { "sha256", "sha512", "sha3-256" }
  for _, algorithm in ipairs(algorithms) do
    for _, key in ipairs({ "", "k", string.rep("\xaa", 200) }) do
      local h = assert(Stream.hashing(algorithm, key))
      assert(h:write("hello "))
      assert(h:write("world"))
      assert(assert(h:digest()) == Hash.hmac(algorithm, key, "hello world"), algorithm .. " " .. #key)
      assert(assert(h:digest()) == Hash.hmac(algorithm, key, "hello world")) -- again
      assert(not h:write("more"))
    end
    local plain = assert(Stream.hashing(algorithm, nil))
    assert(plain:write("abc"))
    assert(assert(plain:digest()) == Hash.digest(algorithm, "abc"))
  end
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
  local w = Stream.transform_writer(assert(Stream.create(path)), codec)
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
  local transformed = Stream.transform(Stream.from_string("abc"), codec)
  assert(drain(transformed) == string.rep("a", 10) .. string.rep("b", 10) .. string.rep("c", 10))
end

--- A Transform with nothing but the two required calls, which holds
--- nothing back: it upper-cases, and ends with "!".
local function shouting(): Stream.Transform
  local t: Stream.Transform = {}
  t.update = function(_self: Stream.Transform, chunk: string): string | nil, string
    return chunk:upper(), ""
  end
  t.finish = function(_self: Stream.Transform): string | nil, string
    return "!", ""
  end
  return t
end

local function test_a_transform_without_pending_runs_through_every_driver()
  assert(Stream.run(shouting(), "hi") == "HI!")
  assert(drain(Stream.transform(Stream.from_string("hi"), shouting())) == "HI!")
  local c = Stream.collect()
  local w = Stream.transform_writer(c, shouting())
  assert(w:write("hi"))
  assert(w:close())
  assert(c:result() == "HI!")
end

--- A Writer that keeps what it is given and whether it was closed or
--- aborted, for a test of what a held write lets through.
local record Recorded is Stream.Writer
  got: string
  ended: string
end

local function recording(): Recorded
  local r: Recorded = { got = "", ended = "" }
  r.write = function(_self: Stream.Writer, data: string): boolean, string
    r.got = r.got .. data
    return true, ""
  end
  r.close = function(_self: Stream.Writer): boolean, string
    r.ended = "closed"
    return true, ""
  end
  r.abort = function(_self: Stream.Writer): boolean, string
    r.ended = "aborted"
    return true, ""
  end
  return r
end

--- A Transform that upper-cases, refuses a chunk holding "!" at
--- `update`, and at `finish` either ends with "." or, when `cut`,
--- refuses.
local function strict(cut?: boolean): Stream.Transform
  local t: Stream.Transform = {}
  t.update = function(_self: Stream.Transform, chunk: string): string | nil, string
    if chunk:find("!", 1, true) then return nil, "bang" end
    return chunk:upper(), ""
  end
  t.finish = function(_self: Stream.Transform): string | nil, string
    if cut then return nil, "cut short" end
    return ".", ""
  end
  return t
end

local function test_transform_writer_hold_releases_a_write_when_the_next_goes_through()
  local out = recording()
  local w = Stream.transform_writer(out, strict(), { hold = 1 })
  assert(w:write("ab"))
  assert(out.got == "", "a write's output was released at once")
  assert(w:write("cd"))
  assert(out.got == "AB")
  assert(w:write("ef"))
  assert(out.got == "ABCD")
  assert(out.ended == "")
  assert(w:close())
  -- Close commits the last write's output and the codec's own, whole.
  assert(out.got == "ABCDEF." and out.ended == "closed")
end

local function test_transform_writer_hold_counts_writes_not_bytes()
  local out = recording()
  local w = Stream.transform_writer(out, strict(), { hold = 2 })
  assert(w:write("a"))
  assert(w:write("b"))
  assert(out.got == "")
  assert(w:write("c"))
  assert(out.got == "A")
  assert(w:write("d"))
  assert(out.got == "AB")
  assert(w:close())
  assert(out.got == "ABCD.")
end

local function test_transform_writer_hold_writes_nothing_of_a_stream_the_codec_cuts_short()
  local out = recording()
  local w = Stream.transform_writer(out, strict(true), { hold = 1 })
  assert(w:write("ab"))
  local ok, trouble = w:close()
  assert(not ok and trouble == "cut short", trouble)
  assert(out.got == "" and out.ended == "aborted")
  -- Without the hold the same run has let its text out before the cut.
  out = recording()
  w = Stream.transform_writer(out, strict(true))
  assert(w:write("ab"))
  assert(out.got == "AB")
  assert(not w:close())
  assert(out.ended == "aborted")
end

local function test_transform_writer_hold_writes_nothing_when_a_write_is_refused()
  local out = recording()
  local w = Stream.transform_writer(out, strict(), { hold = 1 })
  assert(w:write("ab"))
  local ok, trouble = w:write("c!")
  assert(not ok and trouble == "bang", trouble)
  assert(out.got == "", "a refused write released the one before it")
  -- The refusal is kept: later writes and `close` answer it, and `close`
  -- aborts the writer without finishing the codec.
  ok, trouble = w:write("de")
  assert(not ok and trouble == "bang", trouble)
  ok, trouble = w:close()
  assert(not ok and trouble == "bang", trouble)
  assert(out.got == "" and out.ended == "aborted")
end

local function test_transform_writer_hold_keeps_what_an_earlier_write_released()
  local out = recording()
  local w = Stream.transform_writer(out, strict(), { hold = 1 })
  assert(w:write("ab"))
  assert(w:write("cd"))
  assert(not w:write("!"))
  assert(out.got == "AB", out.got)
  assert(not w:close())
  assert(out.got == "AB" and out.ended == "aborted")
end

local function test_transform_writer_hold_is_dropped_by_abort()
  local out = recording()
  local w = Stream.transform_writer(out, strict(), { hold = 1 })
  assert(w:write("ab"))
  assert(w:abort())
  assert(out.got == "" and out.ended == "aborted")
  local ok = w:write("cd")
  assert(not ok)
end

--- A Writer that refuses the write that brings its text to `limit`
--- bytes or more: for a test of a sink that fails as held output is
--- released.
local function failing_after(limit: integer): Recorded
  local r = recording()
  local inner = r.write
  r.write = function(self: Stream.Writer, data: string): boolean, string
    if #r.got + #data >= limit then return false, "sink full" end
    return inner(self, data)
  end
  return r
end

local function test_transform_writer_hold_reports_a_sink_that_fails_as_a_write_is_released()
  local out = failing_after(1)
  local w = Stream.transform_writer(out, strict(), { hold = 1 })
  assert(w:write("a"))
  local ok, trouble = w:write("bc")
  assert(not ok and trouble == "sink full", trouble)
  ok, trouble = w:close()
  assert(not ok and trouble == "sink full", trouble)
  assert(out.got == "" and out.ended == "aborted")
end

local function test_transform_writer_hold_reports_a_sink_that_fails_at_the_commit()
  local out = failing_after(3)
  local w = Stream.transform_writer(out, strict(), { hold = 1 })
  assert(w:write("ab"))
  local ok, trouble = w:close()
  assert(not ok and trouble == "sink full", trouble)
  assert(out.got == "" and out.ended == "aborted")
end

local function test_transform_writer_hold_closes_once()
  local out = recording()
  local w = Stream.transform_writer(out, strict(), { hold = 1 })
  assert(w:write("ab"))
  assert(w:close())
  assert(w:close())
  assert(out.got == "AB.")
  local ok = w:write("cd")
  assert(not ok)
  -- A close that failed answers its failure again.
  w = Stream.transform_writer(recording(), strict(true), { hold = 1 })
  assert(w:write("ab"))
  local _, first = w:close()
  local again, second = w:close()
  assert(again == false and second == first and first == "cut short", second)
end

local function test_transform_writer_hold_reports_a_drain_that_fails_mid_write()
  -- The second call of one write, the drain, refuses.
  local calls = 0
  local t: Stream.Transform = {}
  t.update = function(_self: Stream.Transform, _chunk: string): string | nil, string
    calls = calls + 1
    if calls == 2 then return nil, "drain failed" end
    return "x", ""
  end
  t.pending = function(_self: Stream.Transform): boolean return true end
  t.finish = function(_self: Stream.Transform): string | nil, string return "", "" end
  local out = recording()
  local w = Stream.transform_writer(out, t, { hold = 1 })
  local ok, trouble = w:write("ab")
  assert(not ok and trouble == "drain failed", trouble)
  assert(out.got == "")
  assert(not w:close() and out.ended == "aborted")
end

local function test_transform_writer_hold_does_not_count_an_empty_write()
  local out = recording()
  local w = Stream.transform_writer(out, strict(), { hold = 1 })
  assert(w:write("ab"))
  assert(w:write(""))
  assert(out.got == "", "an empty write released a held one")
  assert(w:close())
  assert(out.got == "AB.")
end

local function test_transform_writer_hold_holds_a_writes_drained_output_as_one()
  -- A decoder's output for one write can take several calls to drain:
  -- all of it is that write's, and none is released before the next.
  local plain = string.rep("\0", 3 << 20)
  local packed = assert(Compress.deflate("zlib", plain))
  local out = recording()
  local w = Stream.transform_writer(out, assert(Compress.inflater("zlib")), { hold = 1 })
  assert(w:write(packed))
  assert(out.got == "")
  assert(w:close())
  assert(out.got == plain)
end

local function test_transform_writer_without_a_hold_releases_each_write_at_once()
  for _, opts in ipairs({ {} as Stream.TransformWriterOptions, { hold = 0 } }) do
    local out = recording()
    local w = Stream.transform_writer(out, strict(), opts)
    assert(w:write("ab"))
    assert(out.got == "AB")
    assert(w:close())
    assert(out.got == "AB.")
  end
end

local function test_transform_writer_raises_on_a_hold_that_is_not_a_whole_count()
  for _, bad in ipairs({ -1, 1.5, "1", true } as {any}) do
    local ok, trouble = pcall(Stream.transform_writer, recording(), strict(),
      { hold = bad as integer })
    assert(not ok and tostring(trouble):find("hold must be an integer of at least 0", 1, true),
      tostring(trouble))
  end
end

local function test_run_drains_a_decoder_that_holds_output_back()
  local plain = string.rep("\0", 3 << 20)
  local packed = assert(Compress.deflate("zlib", plain))
  -- A decoder's one call returns at most 1 MiB, so the whole answer
  -- takes `update("")` calls past the first.
  assert(Stream.run(assert(Compress.inflater("zlib")), packed) == plain)
  assert(Stream.run(assert(Compress.deflater("gzip")), "") ~= nil)
end

local function test_run_bounds_what_it_returns()
  local plain = string.rep("x", 1000)
  local packed = assert(Compress.deflate("raw", plain))
  assert(Stream.run(assert(Compress.inflater("raw")), packed, 1000) == plain)
  local out, trouble = Stream.run(assert(Compress.inflater("raw")), packed, 999)
  assert(out == nil and trouble == "stream: output is larger than 999 bytes", trouble)
  -- The bound counts what `finish` returns too, and 0 is a bound.
  out, trouble = Stream.run(shouting(), "", 0)
  assert(out == nil and trouble == "stream: output is larger than 0 bytes", trouble)
  assert(Stream.run(shouting(), "", 1) == "!")
  assert(Stream.run(shouting(), "", 1 << 62) == "!")
  assert(Stream.run(shouting(), "") == "!")
end

local function test_run_bounds_output_met_while_draining_a_decoder()
  -- A decoder's first call gives 1 MiB; the bound falls in a later
  -- `update("")`, in the drain loop.
  local packed = assert(Compress.deflate("zlib", string.rep("\0", 3 << 20)))
  local out, trouble = Stream.run(assert(Compress.inflater("zlib")), packed, (1 << 20) + 5)
  assert(out == nil and trouble:find("larger than", 1, true) ~= nil, trouble)
end

local function test_run_answers_a_transform_failure()
  local out, trouble = Stream.run(assert(Compress.inflater("zlib")), "not zlib")
  assert(out == nil and trouble ~= "", trouble)
  local packed = assert(Compress.deflate("zlib", "some text to cut"))
  out, trouble = Stream.run(assert(Compress.inflater("zlib")), packed:sub(1, -3))
  assert(out == nil and trouble:find("truncated", 1, true) ~= nil, trouble)
end

local function test_run_raises_on_a_max_bytes_that_is_not_a_whole_count()
  for _, bad in ipairs({ -1, 1.5, "10", math.huge } as {any}) do
    local ok, trouble = pcall(Stream.run, shouting(), "x", bad as integer)
    assert(not ok and tostring(trouble):find("max_bytes", 1, true) ~= nil, tostring(bad))
  end
end

--- Every line [`Stream.lines`] gives `reader`, through `read`, and why it
--- stopped.
local function all_lines(reader: Stream.Reader, max_bytes?: integer): {string}, string
  local lines = Stream.lines(reader, max_bytes)
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
  r.read = function(_self: Stream.Reader, _max_bytes?: integer): string | nil, string
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
--- per chunk: one 128 KiB line a byte at a time takes about as long as
--- eight 16 KiB lines do, where copying the partial line per byte would
--- take eight times as long or more. The bound is on that ratio of two runs
--- over the same bytes, alike in length, not on wall time, so it holds
--- on a slow core and on a loaded host.
local function test_a_long_line_in_small_chunks_costs_linear_time()
  local short = string.rep("x", 1 << 14)
  local long = string.rep(short, 8)
  local shorts = string.rep(short .. "\n", 8)
  -- The time to read `text` a byte at a time, checking its lines.
  local function timed(text: string, want: {string}): integer
    local started = Clock.monotonic_ns()
    local got, trouble = all_lines(trickle(text))
    local elapsed = Clock.monotonic_ns() - started
    assert(trouble == "" and #got == #want, trouble)
    for i, line in ipairs(want) do assert(got[i] == line) end
    return elapsed
  end
  local eight: {string} = {}
  for i = 1, 8 do eight[i] = short end
  -- The least of three of each, taken in turn, so a pause elsewhere on
  -- the host inflates neither.
  local one_ns, eight_ns = math.maxinteger, math.maxinteger
  for _ = 1, 3 do
    one_ns = math.min(one_ns, timed(long .. "\n", { long }))
    eight_ns = math.min(eight_ns, timed(shorts, eight))
  end
  local ratio = one_ns / math.max(eight_ns, 1)
  -- About 1 here, on the checked core too; copying per byte gives 13 to 17.
  assert(ratio < 3, string.format("one line took %d ms, eight %d ms: %.1fx",
    one_ns // 1000000, eight_ns // 1000000, ratio))
end

--- A Reader's failure ends the lines with it, after the ones before.
local function test_lines_stop_at_a_reader_failure()
  local inner = Stream.from_string("a\nb")
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, max_bytes?: integer): string | nil, string
    local chunk, trouble = inner:read(max_bytes)
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

--- `rest` gives exactly the bytes after the last line read: those the
--- lines read ahead, then the Reader's own, however the Reader chunks
--- them, a partial last line and none at all among them.
local function test_rest_gives_the_bytes_after_the_last_line()
  local long = string.rep("x", 200000)
  local cases: {{any}} = {
    { "a\nb\nbody", 1, "b\nbody" },
    { "a\nb\nbody", 2, "body" },
    { "a\nb\n", 2, "" },
    { "a\nb", 1, "b" },
    { "a\n", 0, "a\n" },
    { "", 0, "" },
    { "head\r\n\r\n" .. long, 2, long },
  }
  for _, case in ipairs(cases) do
    local text, count, want = case[1] as string, case[2] as integer, case[3] as string
    for _, reader in ipairs({ Stream.from_string(text), trickle(text) }) do
      local lines = Stream.lines(reader)
      for _ = 1, count do assert(lines:read() ~= nil) end
      local rest = lines:rest()
      local got = assert(Stream.read_all(rest))
      assert(got == want, string.format("%q after %d: %q", text:sub(1, 20), count,
        got:sub(1, 20)))
      local after, trouble = rest:read()
      assert(after == nil and trouble == "", trouble)
    end
  end
end

--- Once the lines have met the end, `rest` has nothing, and reads the
--- Reader no more.
local function test_rest_after_the_last_line_reads_nothing_more()
  local inner = Stream.from_string("a\nb")
  local ended = false
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, max_bytes?: integer): string | nil, string
    assert(not ended, "read past the end")
    local chunk, trouble = inner:read(max_bytes)
    if chunk == nil then ended = true end
    return chunk, trouble
  end
  r.close = function(_self: Stream.Reader): boolean, string return true, "" end
  local lines = Stream.lines(r)
  local seen: {string} = {}
  for line in lines:each() do seen[#seen + 1] = line end
  assert(table.concat(seen, "|") == "a|b")
  local chunk, trouble = lines:rest():read()
  assert(chunk == nil and trouble == "", trouble)
end

--- A failure stays: `rest` of failed lines answers it on every read,
--- and gives none of the bytes past it.
local function test_rest_after_a_failure_answers_the_failure()
  local lines = Stream.lines(trickle("ok\n123456\nafter"), 5)
  assert(lines:read() == "ok")
  local _, why = lines:read()
  assert(why:find("longer than 5 bytes", 1, true) ~= nil, why)
  local rest = lines:rest()
  for _ = 1, 2 do
    local chunk, trouble = rest:read()
    assert(chunk == nil and trouble == why, trouble)
  end
end

--- A Reader that raises in the middle of a line leaves that line's
--- start with the lines, and `rest` gives it back before the rest.
local function test_rest_after_a_raise_keeps_the_start_of_a_line()
  local answers: {string | boolean} = { "a\npar", false, "tial\nbody" }
  local next_answer = 0
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, _max_bytes?: integer): string | nil, string
    next_answer = next_answer + 1
    local answer = answers[next_answer]
    if answer == false then error("raised") end
    return answer as string, ""
  end
  r.close = function(_self: Stream.Reader): boolean, string return true, "" end
  local lines = Stream.lines(r)
  assert(lines:read() == "a")
  assert(not pcall(lines.read, lines))
  local got = assert(Stream.read_all(lines:rest()))
  assert(got == "partial\nbody", got)
end

--- `rest` ends the lines: a later `read`, `each` or `rest` raises
--- rather than take bytes the Reader gave away; closing the Reader it
--- gave closes the lines' Reader, once.
local function test_rest_ends_the_lines_and_closes_the_reader()
  local closes = 0
  local inner = Stream.from_string("a\nb\n")
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, max_bytes?: integer): string | nil, string
    return inner:read(max_bytes)
  end
  r.close = function(_self: Stream.Reader): boolean, string
    closes = closes + 1
    return true, ""
  end
  local lines = Stream.lines(r)
  assert(lines:read() == "a")
  local rest = lines:rest()
  for _, call in ipairs({
      function() lines:read() end,
      function() lines:rest() end,
      function()
        for _ in lines:each() do end
      end,
  }) do
    local ok, trouble = pcall(call) as (boolean, any)
    assert(not ok and tostring(trouble):find("ended at `rest`", 1, true) ~= nil,
      tostring(trouble))
  end
  assert(assert(Stream.read_all(rest)) == "b\n")
  assert(rest:close())
  assert(rest:close())
  assert(closes == 1, tostring(closes))
end

--- A Writer whose writes fail from the `fails_at`th on, counting its
--- aborts and closes.
local record Failing is Stream.Writer
  aborts: integer
  closes: integer
end

local function failing(fails_at: integer): Failing
  local writes = 0
  local f: Failing = { aborts = 0, closes = 0 }
  f.write = function(_self: Stream.Writer, _data: string): boolean, string
    writes = writes + 1
    if writes >= fails_at then return false, "disk full" end
    return true, ""
  end
  f.close = function(_self: Stream.Writer): boolean, string
    f.closes = f.closes + 1
    return true, ""
  end
  f.abort = function(_self: Stream.Writer): boolean, string
    f.aborts = f.aborts + 1
    return true, ""
  end
  return f
end

--- A Reader that gives `chunks` one `read` at a time, whatever `max_bytes`
--- asks, then fails with `failure` (an end of file when it is "").
local function chunked(chunks: {string}, failure: string): Stream.Reader
  local at = 0
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, _max_bytes?: integer): string | nil, string
    at = at + 1
    if chunks[at] == nil then return nil, failure end
    return chunks[at], ""
  end
  r.close = function(_self: Stream.Reader): boolean, string return true, "" end
  return r
end

local function test_read_up_to_gathers_pieces_up_to_the_count()
  local got, why = Stream.read_up_to(chunked({ "ab", "c", "def" }, ""), 6)
  assert(got == "abcdef" and why == "", tostring(got))
  got, why = Stream.read_up_to(Stream.from_string("abcdef"), 4)
  assert(got == "abcd" and why == "")
  assert(Stream.read_up_to(Stream.from_string("abc"), 0) == "")
end

local function test_read_up_to_tells_a_clean_end_from_a_truncation()
  local got, why = Stream.read_up_to(Stream.from_string(""), 4)
  assert(got == "" and why == "", tostring(got))
  got, why = Stream.read_up_to(chunked({ "ab", "c" }, ""), 4)
  assert(got == "abc" and why == "", tostring(got))
end

local function test_read_up_to_answers_a_failure_and_drops_what_was_read()
  local got, why = Stream.read_up_to(chunked({ "ab" }, "disk on fire"), 4)
  assert(got == nil and why == "disk on fire", tostring(why))
  got, why = Stream.read_up_to(chunked({}, "disk on fire"), 4)
  assert(got == nil and why == "disk on fire", tostring(why))
end

local function test_copy_n_copies_exactly_n_bytes_and_no_more()
  local r = Stream.from_string(string.rep("x", 200000) .. "tail")
  local c = Stream.collect()
  local ok, why = Stream.copy_n(r, c, 200000)
  assert(ok and why == "", why)
  assert(c:result() == string.rep("x", 200000))
  assert(drain(r) == "tail", "copy_n read past its count")
  ok, why = Stream.copy_n(r, c, 0)
  assert(ok and why == "")
end

local function test_copy_n_fails_on_a_short_reader_and_on_either_side_failing()
  local c = Stream.collect()
  local ok, why = Stream.copy_n(Stream.from_string("abc"), c, 10)
  assert(not ok and why:find("stated size", 1, true) and why:find("wanted 10 bytes, got 3", 1, true), why)
  assert(c:result() == "abc")
  ok, why = Stream.copy_n(chunked({ "ab" }, "disk on fire"), Stream.collect(), 10)
  assert(not ok and why == "disk on fire", why)
  ok, why = Stream.copy_n(Stream.from_string("abc"), failing(1), 3)
  assert(not ok and why == "disk full", why)
end

local function test_sticky_keeps_the_first_failure_and_aborts_once()
  local w = failing(2)
  local sink = Stream.sticky(w, "fmt")
  assert(sink:put("a"))
  local ok, trouble = sink:put("b")
  assert(not ok and trouble == "disk full", trouble)
  ok, trouble = sink:put("c")
  assert(not ok and trouble == "disk full", trouble)
  ok, trouble = sink:close("trailer")
  assert(not ok and trouble == "disk full", trouble)
  assert(w.aborts == 1 and w.closes == 0)
end

local function test_sticky_names_its_own_failures()
  local sink = Stream.sticky(failing(99), "fmt")
  local ok, trouble = sink:fail("")
  assert(not ok and trouble == "fmt: write failed", trouble)
  sink = Stream.sticky(failing(99), "fmt")
  assert(sink:close(""))
  ok, trouble = sink:usable()
  assert(not ok and trouble == "fmt: the writer is closed", trouble)
end

local function test_sticky_closes_once_with_its_trailer()
  local c = Stream.collect()
  local sink = Stream.sticky(c, "fmt")
  assert(sink:put("body."))
  assert(sink:close("end"))
  assert(sink:close("again"))
  assert(sink:abort())
  assert(c:result() == "body.end", c:result())
end
