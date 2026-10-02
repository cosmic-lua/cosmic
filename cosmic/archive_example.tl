--- Worked examples for [`cosmic.archive`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Archive = require("cosmic.archive")
local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")

local Example = {}

--- An archive walked entry by entry, whatever it turns out to be: here
--- a gzipped tar, which `open` knows by its first bytes, not its name.
function Example.open()
  local dir = assert(Fs.mkdtemp("cosmic-archive-example-"))
  local path = dir .. "/release"
  local file = assert(Stream.create(path))
  local w = Tar.writer(Stream.transform_writer(file, (assert(Compress.deflater("gzip")))))
  assert(w:add_file("README", "read me first"))
  assert(w:close())

  local r = assert(Archive.open(path))
  local entry = assert(r:next())
  local body = assert(entry:open())
  local text = assert(Stream.read_all(body))
  print(entry.path, text)
  assert(entry.path == "README" and text == "read me first")
  assert(r:close())
  assert(Fs.remove_tree(dir))
end

--- An archive written in the format its name asks for, and read back:
--- here a zip, which stays out of `path` until `close` commits it.
function Example.create()
  local dir = assert(Fs.mkdtemp("cosmic-archive-example-"))
  local path = dir .. "/site.zip"
  local w = assert(Archive.create(path))
  assert(w:add_dir("site"))
  assert(w:add_file("site/index.html", "<h1>hello</h1>"))
  assert(w:close())

  local entries = assert(Archive.list(path))
  for _, entry in ipairs(entries) do print(entry.path, entry.kind, entry.size) end
  assert(#entries == 2 and entries[2].path == "site/index.html" and entries[2].size == 14)
  assert(Fs.remove_tree(dir))
end

--- The entries of an archive a reader walks, listed at once: the reader
--- is read to its end and closed, so the entries' bodies are not there.
function Example.list_reader()
  local out = Stream.collect()
  local w = Tar.writer(out)
  assert(w:add_file("README", "read me first"))
  assert(w:add_dir("docs"))
  assert(w:close())

  local reader = assert(Archive.open_stream(Stream.from_string(out:result())))
  local entries = assert(Archive.list_reader(reader))
  for _, entry in ipairs(entries) do print(entry.path, entry.kind, entry.size) end
  assert(#entries == 2 and entries[1].path == "README" and entries[2].kind == "dir")
end

return Example
