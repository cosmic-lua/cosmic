--- Worked examples for [`cosmic.zip`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Stream = require("cosmic.stream")
local Zip = require("cosmic.zip")

local Example = {}

--- A zip made in memory: `writer` over a [`Stream.collect`], each entry
--- added in turn, and `close` writing the central directory.
function Example.writer()
  local out = Stream.collect()
  local w = Zip.writer(out)
  assert(w:add_dir("docs"))
  assert(w:add_file("docs/hello.txt", "hello, world"))
  assert(w:close())
  local data = out:result()
  print(#data)
  assert(data:sub(1, 4) == "PK\3\4")
end

--- A symlink, held as Info-ZIP holds one: its target is the entry's
--- body, and a reader answers it as a "symlink" with its `linkpath`.
function Example.add_symlink()
  local out = Stream.collect()
  local w = Zip.writer(out)
  assert(w:add_file("docs/hello.txt", "hello, world"))
  assert(w:add_symlink("docs/latest", "hello.txt"))
  assert(w:close())
  local r = assert(Zip.open_string(out:result()))
  local entries = assert(r:entries())
  for _, entry in ipairs(entries) do
    print(entry.path, entry.kind, entry.linkpath)
  end
  local link = assert(entries[2])
  assert(link.kind == "symlink" and link.linkpath == "hello.txt", link.linkpath)
  assert(r:close())
end

--- A zip already in memory, read without a file: `entries` lists what
--- it holds, and each entry's `open` reads its body.
function Example.open_string()
  local out = Stream.collect()
  local w = Zip.writer(out)
  assert(w:add_file("hello.txt", "hello, world"))
  assert(w:close())
  local r = assert(Zip.open_string(out:result()))
  local entries = assert(r:entries())
  for _, entry in ipairs(entries) do
    print(entry.path, entry.kind, entry.size)
  end
  local hello = assert(entries[1])
  assert(#entries == 1 and hello.path == "hello.txt")
  local body = assert(hello:open())
  local text = assert(Stream.read_all(body))
  assert(text == "hello, world", text)
  assert(r:close())
end

--- `entry` opens one entry by its path, as a format built of named
--- parts (a spreadsheet, an EPUB) reads each part it needs.
function Example.entry()
  local out = Stream.collect()
  local w = Zip.writer(out)
  assert(w:add_file("docs/readme.txt", "read me"))
  assert(w:add_file("data.csv", "a,b\n"))
  assert(w:close())
  local r = assert(Zip.open_string(out:result()))
  local readme = assert(r:entry("docs/readme.txt"))
  assert(assert(Stream.read_all((assert(readme:open())))) == "read me")
  local none, why = r:entry("missing.txt")
  assert(none == nil)
  print(why) -- zip: no entry "missing.txt"
  assert(r:close())
end

return Example
