--- Worked examples for `cosmic.sys`, the syscall table, for the calls
--- no other module wraps. Shown by `cosmic docs` under the symbol each
--- one demonstrates and run by `cosmic test` like any other test.

local Fs = require("cosmic.fs")
local syscalls = require("cosmic.sys")

local Example = {}

--- A fresh directory holding `hello.txt`, which says "hello, world".
local function scratch(): string, string
  local dir = assert(Fs.mkdtemp("cosmic-sys-example-"))
  local path = dir .. "/hello.txt"
  assert(Fs.write(path, "hello, world"))
  return dir, path
end

local function clean(dir: string, path: string)
  assert(Fs.remove(path))
  assert(syscalls.rmdir(dir))
end

--- `syscalls.pread` reads from an explicit offset, leaving the
--- descriptor's own offset where it was.
function Example.pread()
  local dir, path = scratch()
  local fd = assert(syscalls.open(path, syscalls.O_RDONLY))
  local word = assert(syscalls.pread(fd, 5, 7))
  print(word)
  assert(word == "world", word)
  assert(syscalls.close(fd))
  clean(dir, path)
end

--- `syscalls.lseek` moves a descriptor's offset and returns the new
--- one: from the end, it is the file's size.
function Example.lseek()
  local dir, path = scratch()
  local fd = assert(syscalls.open(path, syscalls.O_RDONLY))
  local size = assert(syscalls.lseek(fd, 0, syscalls.SEEK_END))
  print(size)
  assert(size == 12, tostring(size))
  assert(syscalls.close(fd))
  clean(dir, path)
end

--- `syscalls.fstat` describes an open descriptor rather than a path.
function Example.fstat()
  local dir, path = scratch()
  local fd = assert(syscalls.open(path, syscalls.O_RDONLY))
  local stat = assert(syscalls.fstat(fd))
  print(stat.kind, stat.size)
  assert(stat.kind == "file" and stat.size == 12, stat.kind)
  assert(syscalls.close(fd))
  clean(dir, path)
end

--- `syscalls.lstat` describes a path itself, a symbolic link rather
--- than its target; a failure returns nil, the error, and the errno.
function Example.lstat()
  local dir, path = scratch()
  local stat = assert(syscalls.lstat(dir))
  print(stat.kind)
  assert(stat.kind == "dir", stat.kind)
  clean(dir, path)
  local gone, _, errno = syscalls.lstat(dir)
  assert(gone == nil and errno == syscalls.ENOENT, tostring(errno))
end

--- `syscalls.utimens_ns` sets an access time, a modification time or
--- both, in nanoseconds; a nil one is left as it was.
function Example.utimens_ns()
  local dir, path = scratch()
  assert(syscalls.utimens_ns(path, 86400 * 1000000000, nil))
  local stat = assert(syscalls.stat(path))
  print(stat.atime)
  assert(stat.atime == 86400 and stat.atime_ns == 0)
  clean(dir, path)
end

--- `syscalls.chmod` sets a path's permission bits.
function Example.chmod()
  local dir, path = scratch()
  assert(syscalls.chmod(path, tonumber("600", 8) as integer))
  local stat = assert(syscalls.stat(path))
  local bits = string.format("%o", stat.mode & tonumber("777", 8) as integer)
  print(bits)
  assert(bits == "600", bits)
  clean(dir, path)
end

--- `syscalls.chdir` moves the process to a directory, and
--- `syscalls.getcwd` says where it is.
function Example.chdir()
  local dir, path = scratch()
  local before = assert(syscalls.getcwd())
  assert(syscalls.chdir(dir))
  local here = assert(syscalls.getcwd())
  assert(syscalls.chdir(before))
  -- A temporary directory can sit under a symbolic link, as /tmp does
  -- on macOS, so compare the last name only.
  print(here:match("[^/]+$") == dir:match("[^/]+$"))
  assert(here:match("[^/]+$") == dir:match("[^/]+$"), here)
  clean(dir, path)
end

--- `syscalls.rmdir` removes an empty directory, and refuses one that
--- is not.
function Example.rmdir()
  local dir, path = scratch()
  local ok, _, errno = syscalls.rmdir(dir)
  assert(not ok and errno == syscalls.ENOTEMPTY, tostring(errno))
  assert(Fs.remove(path))
  assert(syscalls.rmdir(dir))
  print(Fs.is_dir(dir))
end

return Example
