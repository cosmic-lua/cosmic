--- Worked examples for `cosmic.stream`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Codec = require("cosmic.codec")
local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Stream = require("cosmic.stream")

local Example = {}

--- Bytes already in memory, read as a stream: at most `max` bytes a
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
--- leaves the descriptor open: whoever opened it closes it.
function Example.from_fd()
  local dir = assert(Fs.mkdtemp("cosmic-stream-example-"))
  assert(Fs.write(dir .. "/notes.txt", "one\ntwo\n"))
  local fd = assert(Fs.open_read(dir .. "/notes.txt"))
  local r = Stream.from_fd(fd)
  local text = assert(Stream.read_all(r))
  assert(r:close())
  assert(Fs.close(fd))
  assert(text == "one\ntwo\n", text)
  assert(Fs.remove_tree(dir))
end

--- A stream written to an open descriptor: here standard output.
function Example.to_fd()
  local w = Stream.to_fd(Fs.stdout)
  assert(Stream.copy(Stream.from_string("streamed to standard output\n"), w))
  assert(w:close())
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

return Example
