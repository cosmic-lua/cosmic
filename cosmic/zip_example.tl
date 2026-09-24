--- Worked examples for `cosmic.zip`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Stream = require("cosmic.stream")
local Zip = require("cosmic.zip")

local Example = {}

--- A zip made in memory: `writer` over a `Stream.collect`, each entry
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

--- A zip already in memory, read without a file: `entries` lists what
--- it holds, and each entry's `open` reads its body.
function Example.open_string()
  local out = Stream.collect()
  local w = Zip.writer(out)
  assert(w:add_file("hello.txt", "hello, world"))
  assert(w:close())
  local r = assert(Zip.open_string(out:result()))
  local entries = r:entries()
  for _, entry in ipairs(entries) do
    print(entry.path, entry.kind, entry.size)
  end
  assert(#entries == 1 and entries[1].path == "hello.txt")
  local body = assert(entries[1]:open())
  local text = assert(Stream.read_all(body))
  assert(text == "hello, world", text)
  assert(r:close())
end

return Example
