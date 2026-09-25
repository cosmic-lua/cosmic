--- Worked examples for `cosmic.fs`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")

local Example = {}

--- Standard input is a descriptor like any other: `Fs.take` reads it,
--- and `Proc.is_tty` says whether a person is typing into it.
function Example.stdin()
  if Proc.is_tty(Fs.stdin) then
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

--- A script made executable by its owner alone, then read back from
--- its stat: `chmod 700`, written 0x1c0 since Teal has no octal.
function Example.chmod()
  local dir = assert(Fs.mkdtemp("cosmic-fs-example-"))
  local path = dir .. "/run.sh"
  assert(Fs.write(path, "#!/bin/sh\necho hi\n"))
  assert(Fs.chmod(path, 0x1c0))
  local bits = assert(Fs.stat(path)).mode & 0xfff
  print(string.format("%o", bits))
  assert(bits == 0x1c0, bits)
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

--- A file's modification time set to the nanosecond, as a build does
--- to mark an output made at a given moment; its access time is left
--- alone.
function Example.set_mtime()
  local dir = assert(Fs.mkdtemp("cosmic-fs-example-"))
  local path = dir .. "/out"
  assert(Fs.write(path, "made"))
  assert(Fs.set_mtime(path, 1700000000, 250000000))
  local st = assert(Fs.stat(path))
  print(st.mtime, st.mtime_ns)
  assert(st.mtime == 1700000000 and st.mtime_ns == 250000000)
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
