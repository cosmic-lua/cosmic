--- Worked examples for `cosmic.fs`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")

local Example = {}

--- Standard input is a descriptor like any other: `Fs.take` reads it,
--- and `sys.isatty` says whether a person is typing into it.
function Example.stdin()
  if sys.isatty(Fs.stdin) then
    print("standard input is a terminal")
  else
    print("standard input is a pipe, a file or nothing")
  end
end

--- A link stores its target as written, and `readlink` reads it back
--- without following it.
function Example.readlink()
  local dir = assert(Fs.mkdtemp("cosmic-fs-example-"))
  assert(Fs.symlink("notes-2026.txt", dir .. "/latest"))
  local target = assert(Fs.readlink(dir .. "/latest"))
  print(target)
  assert(target == "notes-2026.txt", target)
  assert(Fs.remove_tree(dir))
end

--- A file set to an exact size through a descriptor open for writing:
--- shorter cuts it, longer pads it with zero bytes.
function Example.truncate()
  local dir = assert(Fs.mkdtemp("cosmic-fs-example-"))
  local path = dir .. "/record"
  local fd = assert(Fs.open_write(path))
  assert(Fs.put(fd, "header and body"))
  assert(Fs.truncate(fd, 6))
  assert(Fs.close(fd))
  local data = assert(Fs.read(path))
  print(data)
  assert(data == "header", data)
  assert(Fs.remove_tree(dir))
end

--- A whole tree copied, as `cp -Rp` copies it: files, directories and
--- links, with their permissions and modification times.
function Example.copy_tree()
  local dir = assert(Fs.mkdtemp("cosmic-fs-example-"))
  assert(Fs.mkdirs(dir .. "/site/css"))
  assert(Fs.write(dir .. "/site/css/main.css", "body {}"))
  assert(Fs.copy_tree(dir .. "/site", dir .. "/backup"))
  local copied = assert(Fs.read(dir .. "/backup/css/main.css"))
  print(copied)
  assert(copied == "body {}", copied)
  assert(Fs.remove_tree(dir))
end

return Example
