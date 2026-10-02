--- Worked examples for [`cosmic.stream`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Codec = require("cosmic.codec")
local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")

local Example = {}

--- Bytes already in memory, read as a stream: at most `max_bytes` bytes a
--- `read`, and nil and `""` at the end.
function Example.from_string()
  local r = Stream.from_string("hello, world")
  local first = assert(r:read(5))
  print(first)
  assert(first == "hello", first)
  local rest = assert(Stream.read_all(r))
  assert(rest == ", world", rest)
  assert(r:close())
end

--- Everything a Writer is given, kept in memory and handed back whole.
function Example.collect()
  local c = Stream.collect()
  local count = assert(Stream.copy(Stream.from_string("abc"), c))
  assert(c:close())
  print(count, c:result())
  assert(count == 3 and c:result() == "abc")
end

--- A descriptor opened elsewhere, read as a stream. Closing the Reader
--- leaves the descriptor open: whoever opened it closes it. A
--- non-blocking one can be waited on, for as long as `timeout_ns`: here a
--- named pipe with a writer that says nothing, which fails the read with [`Poll.TIMEOUT`].
function Example.from_fd()
  local dir = assert(Fs.mkdtemp("cosmic-stream-example-"))
  assert(Fs.write(dir .. "/notes.txt", "one\ntwo\n"))
  local fd = assert(Fs.open_read(dir .. "/notes.txt"))
  local r = Stream.from_fd(fd)
  local text = assert(Stream.read_all(r))
  assert(r:close())
  assert(Fs.close(fd))
  assert(text == "one\ntwo\n", text)
  assert(sys.mkfifo(dir .. "/quiet", 384))
  local quiet = assert(sys.open(dir .. "/quiet", sys.O_RDONLY | sys.O_NONBLOCK, 0))
  local writer = assert(sys.open(dir .. "/quiet", sys.O_WRONLY | sys.O_NONBLOCK, 0))
  local waiting = Stream.from_fd(quiet, { nonblocking = true, timeout_ns = Time.ms(20) })
  local chunk, why = waiting:read()
  print(why)
  assert(chunk == nil and why == Poll.TIMEOUT, why)
  assert(Fs.close(quiet))
  assert(Fs.close(writer))
  assert(Fs.remove_tree(dir))
end

--- A file read a line at a time, in bounded memory however large it
--- is; `failure` says afterward whether the loop saw every line.
function Example.lines()
  local dir = assert(Fs.mkdtemp("cosmic-stream-example-"))
  assert(Fs.write(dir .. "/log.txt", "start\nwarn: disk\nstop\n"))
  local reader = assert(Stream.open(dir .. "/log.txt"))
  local lines = Stream.lines(reader)
  local warnings = 0
  for line in lines:each() do
    if line:sub(1, 5) == "warn:" then warnings = warnings + 1 end
  end
  assert(lines:failure() == "", lines:failure())
  assert(reader:close())
  print(warnings)
  assert(warnings == 1)
  assert(Fs.remove_tree(dir))
end

--- A stream written to an open descriptor: here standard output. A
--- non-blocking one can be waited on for room, for as long as
--- `timeout_ns`: here a named pipe nobody reads, which takes what it
--- holds, and then fails the write with [`Poll.TIMEOUT`]; `written` says
--- how much of the body went before it did.
function Example.to_fd()
  local w = Stream.to_fd(Fs.stdout)
  assert(Stream.copy(Stream.from_string("streamed to standard output\n"), w))
  assert(w:close())
  local dir = assert(Fs.mkdtemp("cosmic-stream-example-"))
  assert(sys.mkfifo(dir .. "/full", 384))
  local reader = assert(sys.open(dir .. "/full", sys.O_RDONLY | sys.O_NONBLOCK, 0))
  local pipe = assert(sys.open(dir .. "/full", sys.O_WRONLY | sys.O_NONBLOCK, 0))
  local slow = Stream.to_fd(pipe, { nonblocking = true, timeout_ns = Time.ms(20) })
  local body = string.rep("x", 1 << 20)
  local ok, why = slow:write(body)
  print(why, slow:written())
  assert(not ok and why == Poll.TIMEOUT, why)
  assert(slow:written() > 0 and slow:written() < #body)
  assert(Fs.close(pipe))
  assert(Fs.close(reader))
  assert(Fs.remove_tree(dir))
end

--- A body checked against its published digest as it streams to where
--- it is going: `tee` it to a `hashing` Writer beside the real one.
function Example.hashing()
  local body = "the release archive"
  local published = Hash.hex_sha256(body)
  local kept = Stream.collect()
  local digest = assert(Stream.hashing("sha256"))
  local both = Stream.tee(kept, digest)
  assert(Stream.copy(Stream.from_string(body), both))
  assert(both:close())
  local got = Codec.hex((assert(digest:digest())))
  print(got == published)
  assert(got == published and kept:result() == body)
end

--- Compressed on the way to a Writer: each chunk goes through the
--- codec, and `close` writes the codec's last bytes. `transform` is
--- the Reader's side, here undoing it.
function Example.transform_writer()
  local packed = Stream.collect()
  local w = Stream.transform_writer(packed, (assert(Compress.deflater("gzip"))))
  assert(w:write("hello, "))
  assert(w:write("world"))
  assert(w:close())
  local unpacked = Stream.transform(Stream.from_string(packed:result()),
    (assert(Compress.inflater("gzip"))))
  local text = assert(Stream.read_all(unpacked))
  print(text)
  assert(text == "hello, world", text)
end

--- A Reader cut off after `n` bytes, however much it still has: here a
--- prefix of a longer body. Closing the limit leaves the Reader open.
function Example.limit()
  local source = Stream.from_string("0123456789")
  local head = Stream.limit(source, 4)
  local text = assert(Stream.read_all(head))
  print(text)
  assert(text == "0123", text)
  assert(head:close())
  assert(Stream.read_all(source) == "456789", "the Reader keeps the rest")
end

--- A header read whole, or found short: [`read_up_to`] gathers what a
--- Reader gives in pieces, and answers "" at a clean end of the stream.
function Example.read_up_to()
  local block, why = Stream.read_up_to(Stream.from_string("0123456789"), 4)
  print(block)
  assert(block == "0123", why)
  local short = assert(Stream.read_up_to(Stream.from_string("012"), 4))
  assert(short == "012", "a stream that ends first gives what it had")
  local ended = assert(Stream.read_up_to(Stream.from_string(""), 4))
  assert(ended == "", "a clean end is \"\"")
end

--- A body of a size a header stated, copied and no further: the Reader
--- keeps what comes after it, and one that ends early fails.
function Example.copy_n()
  local source = Stream.from_string("body" .. "next header")
  local out = Stream.collect()
  assert(Stream.copy_n(source, out, 4))
  print(out:result(), assert(Stream.read_all(source)))
  assert(out:result() == "body")
  local ok, why = Stream.copy_n(Stream.from_string("ab"), Stream.collect(), 4)
  print(why)
  assert(not ok and why:find("wanted 4 bytes, got 2", 1, true), why)
end

--- A Transform driven over a whole string: `run` feeds it, drains what
--- it holds back and finishes it. A decoder's `max_bytes` bounds the
--- output, so a small body that expands greatly fails instead of filling
--- memory. Any table with `update` and `finish` is a Transform, such
--- as this one that shouts.
function Example.run()
  local packed = assert(Stream.run(assert(Compress.deflater("gzip")), string.rep("a", 10000)))
  local back = assert(Stream.run(assert(Compress.inflater("gzip")), packed, 10000))
  assert(back == string.rep("a", 10000))
  local out, why = Stream.run(assert(Compress.inflater("gzip")), packed, 100)
  print(why)
  assert(out == nil and why == "stream: output is larger than 100 bytes", why)
  local shouting: Stream.Transform = {}
  shouting.update = function(_self: Stream.Transform, chunk: string): string, string
    return chunk:upper(), ""
  end
  shouting.finish = function(_self: Stream.Transform): string, string
    return "!", ""
  end
  local shouted = assert(Stream.run(shouting, "hello"))
  print(shouted)
  assert(shouted == "HELLO!", shouted)
end

return Example
