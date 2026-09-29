--- Worked examples for `cosmic.sys`, the syscall table, for the calls
--- no other module wraps. Shown by `cosmic docs` under the symbol each
--- one demonstrates and run by `cosmic test` like any other test.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")

local Example = {}

--- `sys.pread` reads from an explicit offset, leaving the
--- descriptor's own offset where it was.
function Example.pread()
  local dir = assert(Fs.mkdtemp("cosmic-sys-example-"))
  local path = dir .. "/hello.txt"
  assert(Fs.write(path, "hello, world"))
  local fd = assert(sys.open(path, sys.O_RDONLY))
  local word = assert(sys.pread(fd, 5, 7))
  print(word)
  assert(word == "world", word)
  assert(sys.close(fd))
  assert(Fs.remove(path))
  assert(sys.rmdir(dir))
end

--- `sys.lseek` moves a descriptor's offset and returns the new
--- one: from the end, it is the file's size.
function Example.lseek()
  local dir = assert(Fs.mkdtemp("cosmic-sys-example-"))
  local path = dir .. "/hello.txt"
  assert(Fs.write(path, "hello, world"))
  local fd = assert(sys.open(path, sys.O_RDONLY))
  local size = assert(sys.lseek(fd, 0, sys.SEEK_END))
  print(size)
  assert(size == 12, tostring(size))
  assert(sys.close(fd))
  assert(Fs.remove(path))
  assert(sys.rmdir(dir))
end

--- `sys.fstat` describes an open descriptor rather than a path.
function Example.fstat()
  local dir = assert(Fs.mkdtemp("cosmic-sys-example-"))
  local path = dir .. "/hello.txt"
  assert(Fs.write(path, "hello, world"))
  local fd = assert(sys.open(path, sys.O_RDONLY))
  local stat = assert(sys.fstat(fd))
  print(stat.kind, stat.size)
  assert(stat.kind == "file" and stat.size == 12, stat.kind)
  assert(sys.close(fd))
  assert(Fs.remove(path))
  assert(sys.rmdir(dir))
end

--- `sys.lstat` describes a path itself, a symbolic link rather
--- than its target; a failure returns nil, the error, and the errno.
function Example.lstat()
  local dir = assert(Fs.mkdtemp("cosmic-sys-example-"))
  local path = dir .. "/hello.txt"
  assert(Fs.write(path, "hello, world"))
  local stat = assert(sys.lstat(dir))
  print(stat.kind)
  assert(stat.kind == "dir", stat.kind)
  assert(Fs.remove(path))
  assert(sys.rmdir(dir))
  local gone, _, errno = sys.lstat(dir)
  assert(gone == nil and errno == sys.ENOENT, tostring(errno))
end

--- `sys.utimensat` sets an access time, a modification time or
--- both, each as seconds and nanoseconds the way a Stat reports them;
--- nil seconds leave that time as it was.
function Example.utimensat()
  local dir = assert(Fs.mkdtemp("cosmic-sys-example-"))
  local path = dir .. "/hello.txt"
  assert(Fs.write(path, "hello, world"))
  assert(sys.utimensat(path, 86400, 0, nil, nil))
  local stat = assert(sys.stat(path))
  print(stat.atime)
  assert(stat.atime == 86400 and stat.atime_ns == 0)
  assert(Fs.remove(path))
  assert(sys.rmdir(dir))
end

--- `sys.chmod` sets a path's permission bits.
function Example.chmod()
  local dir = assert(Fs.mkdtemp("cosmic-sys-example-"))
  local path = dir .. "/hello.txt"
  assert(Fs.write(path, "hello, world"))
  assert(sys.chmod(path, tonumber("600", 8) as integer))
  local stat = assert(sys.stat(path))
  local bits = string.format("%o", stat.mode & tonumber("777", 8) as integer)
  print(bits)
  assert(bits == "600", bits)
  assert(Fs.remove(path))
  assert(sys.rmdir(dir))
end

--- `sys.chdir` moves the process to a directory, and
--- `sys.getcwd` says where it is.
function Example.chdir()
  local dir = assert(Fs.mkdtemp("cosmic-sys-example-"))
  local path = dir .. "/hello.txt"
  assert(Fs.write(path, "hello, world"))
  local before = assert(sys.getcwd())
  assert(sys.chdir(dir))
  local here = assert(sys.getcwd())
  assert(sys.chdir(before))
  -- A temporary directory can sit under a symbolic link, as /tmp does
  -- on macOS, so compare the last name only.
  print(here:match("[^/]+$") == dir:match("[^/]+$"))
  assert(here:match("[^/]+$") == dir:match("[^/]+$"), here)
  assert(Fs.remove(path))
  assert(sys.rmdir(dir))
end

--- `sys.rmdir` removes an empty directory, and refuses one that
--- is not.
function Example.rmdir()
  local dir = assert(Fs.mkdtemp("cosmic-sys-example-"))
  local path = dir .. "/hello.txt"
  assert(Fs.write(path, "hello, world"))
  local ok, _, errno = sys.rmdir(dir)
  assert(not ok and errno == sys.ENOTEMPTY, tostring(errno))
  assert(Fs.remove(path))
  assert(sys.rmdir(dir))
  print(Fs.is_dir(dir))
end

return Example
