--- Worked examples for [`cosmic.fs`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")

local Example = {}

--- Standard input is a descriptor like any other: [`Fs.take`] reads it,
--- and [`Proc.is_tty`] says whether a person is typing into it.
function Example.stdin()
  if Proc.is_tty(Fs.stdin) then
    print("standard input is a terminal")
  else
    print("standard input is a pipe, a file or nothing")
  end
end

--- A file is read whole, as bytes, in one call: the counterpart of
--- [`Fs.write`], which puts a whole string in its place.
function Example.read()
  local dir = assert(Fs.mkdtemp("cosmic-fs-example-"))
  local path = dir .. "/note"
  assert(Fs.write(path, "hello"))
  local data = assert(Fs.read(path))
  print(data)
  assert(data == "hello", data)
  assert(Fs.remove_tree(dir))
end

--- Add log records with [`Fs.append`], preserving what is already there.
function Example.append()
  local dir = assert(Fs.mkdtemp("cosmic-fs-example-"))
  local path = dir .. "/log"
  assert(Fs.append(path, "started\n"))
  assert(Fs.append(path, "finished\n"))
  local data = assert(Fs.read(path))
  print(data)
  assert(data == "started\nfinished\n", data)
  assert(Fs.remove_tree(dir))
end

--- What `stat` says of a file: its kind and its size in bytes. `mode`
--- holds the permission bits too (`mode & 0xfff`, as `chmod` sets them),
--- less the umask for a file just made.
function Example.stat()
  local dir = assert(Fs.mkdtemp("cosmic-fs-example-"))
  local path = dir .. "/notes.txt"
  assert(Fs.write(path, "hello\n"))
  local st = assert(Fs.stat(path))
  print(st.kind, st.size)
  assert(st.kind == "file" and st.size == 6, st.kind)
  assert(Fs.remove_tree(dir))
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

--- A file written under a temporary name and renamed onto its path
--- when `close` succeeds, so a reader never sees half of it: `abort`
--- (or a failure) leaves the path as it was. `sync` first makes the
--- bytes durable before the rename can reach the disk.
function Example.create()
  local dir = assert(Fs.mkdtemp("cosmic-fs-example-"))
  local path = dir .. "/record"
  assert(Fs.write(path, "old"))
  local draft = assert(Fs.create(path))
  assert(draft:write("new, but not yet"))
  assert(draft:abort())
  assert(Fs.read(path) == "old")
  local file = assert(Fs.create(path))
  assert(file:write("new"))
  assert(file:sync())
  assert(file:close())
  local data = assert(Fs.read(path))
  print(data)
  assert(data == "new", data)
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

--- Each path [`Fs.walk`] answers is relative to the root it was given,
--- with no leading `./`, so a file is opened as `root .. "/" .. path`.
function Example.walk()
  local dir = assert(Fs.mkdtemp("cosmic-fs-example-"))
  local root = dir .. "/site"
  assert(Fs.mkdirs(root .. "/css"))
  assert(Fs.write(root .. "/index.html", "<p>hi</p>"))
  assert(Fs.write(root .. "/css/main.css", "body {}"))
  local paths = assert(Fs.walk(root))
  local lines: {string} = {}
  for _, path in ipairs(paths) do
    local data = assert(Fs.read(root .. "/" .. path))
    lines[#lines + 1] = path .. " " .. #data
  end
  print(table.concat(lines, "\n"))
  assert(table.concat(lines, ",") == "css/main.css 7,index.html 9", table.concat(lines, ","))
  assert(Fs.remove_tree(dir))
end

return Example
