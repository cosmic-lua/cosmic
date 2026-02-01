#!/usr/bin/env cosmic
local io_m = require("cosmic.io")
local path = require("cosmo.path")

global TEST_TMPDIR: string

local function test_open_read_write_close()
  local filepath = path.join(TEST_TMPDIR, "io_test_basic.txt")
  local content = "hello, cosmic.io!"

  -- Open for writing (create)
  local fd, err = io_m.open(filepath, io_m.O_WRONLY | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8))
  assert(fd, "open for write failed: " .. (err or ""))

  -- Write
  local n, werr = io_m.write(fd, content)
  assert(n == #content, "write failed: " .. (werr or "") .. " wrote " .. tostring(n) .. " expected " .. #content)

  -- Close
  local ok, cerr = io_m.close(fd)
  assert(ok, "close failed: " .. (cerr or ""))

  -- Open for reading
  fd, err = io_m.open(filepath, io_m.O_RDONLY)
  assert(fd, "open for read failed: " .. (err or ""))

  -- Read
  local data, rerr = io_m.read(fd, 1024)
  assert(data == content, "read failed: " .. (rerr or "") .. " got '" .. tostring(data) .. "'")

  -- Close
  ok, cerr = io_m.close(fd)
  assert(ok, "close failed: " .. (cerr or ""))

  -- Cleanup
  os.remove(filepath)
end
test_open_read_write_close()

local function test_lseek()
  local filepath = path.join(TEST_TMPDIR, "io_test_lseek.txt")
  local content = "0123456789"

  -- Create file with content
  local fd = assert(io_m.open(filepath, io_m.O_WRONLY | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8)))
  assert(io_m.write(fd, content))
  assert(io_m.close(fd))

  -- Open for reading and test seek
  fd = assert(io_m.open(filepath, io_m.O_RDONLY))

  -- Seek to position 5
  local pos, err = io_m.lseek(fd, 5, io_m.SEEK_SET)
  assert(pos == 5, "lseek SEEK_SET failed: " .. (err or "") .. " pos=" .. tostring(pos))

  -- Read from position 5
  local data = assert(io_m.read(fd, 5))
  assert(data == "56789", "expected '56789' got '" .. data .. "'")

  -- Seek back 3 from current
  pos = assert(io_m.lseek(fd, -3, io_m.SEEK_CUR))
  assert(pos == 7, "lseek SEEK_CUR failed, pos=" .. tostring(pos))

  -- Seek to end
  pos = assert(io_m.lseek(fd, 0, io_m.SEEK_END))
  assert(pos == 10, "lseek SEEK_END failed, pos=" .. tostring(pos))

  assert(io_m.close(fd))
  os.remove(filepath)
end
test_lseek()

local function test_ftruncate()
  local filepath = path.join(TEST_TMPDIR, "io_test_ftrunc.txt")
  local content = "0123456789"

  -- Create file with content
  local fd = assert(io_m.open(filepath, io_m.O_RDWR | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8)))
  assert(io_m.write(fd, content))

  -- Truncate to 5 bytes
  local ok, err = io_m.ftruncate(fd, 5)
  assert(ok, "ftruncate failed: " .. (err or ""))

  -- Seek to start and read
  assert(io_m.lseek(fd, 0, io_m.SEEK_SET))
  local data = assert(io_m.read(fd, 100))
  assert(data == "01234", "expected '01234' got '" .. data .. "'")

  assert(io_m.close(fd))
  os.remove(filepath)
end
test_ftruncate()

local function test_truncate()
  local filepath = path.join(TEST_TMPDIR, "io_test_trunc.txt")
  local content = "0123456789"

  -- Create file with content
  local fd = assert(io_m.open(filepath, io_m.O_WRONLY | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8)))
  assert(io_m.write(fd, content))
  assert(io_m.close(fd))

  -- Truncate using path
  local ok, err = io_m.truncate(filepath, 3)
  assert(ok, "truncate failed: " .. (err or ""))

  -- Verify
  fd = assert(io_m.open(filepath, io_m.O_RDONLY))
  local data = assert(io_m.read(fd, 100))
  assert(data == "012", "expected '012' got '" .. data .. "'")
  assert(io_m.close(fd))

  os.remove(filepath)
end
test_truncate()

local function test_dup()
  local filepath = path.join(TEST_TMPDIR, "io_test_dup.txt")
  local content = "dup test"

  -- Create and write file
  local fd = assert(io_m.open(filepath, io_m.O_RDWR | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8)))
  assert(io_m.write(fd, content))

  -- Duplicate the fd
  local fd2, err = io_m.dup(fd)
  assert(fd2, "dup failed: " .. (err or ""))
  assert(fd2 ~= fd, "dup should return different fd")

  -- Seek to start on duplicated fd and read
  assert(io_m.lseek(fd2, 0, io_m.SEEK_SET))
  local data = assert(io_m.read(fd2, 100))
  assert(data == content, "read from dup'd fd failed: got '" .. data .. "'")

  assert(io_m.close(fd))
  assert(io_m.close(fd2))
  os.remove(filepath)
end
test_dup()

local function test_pipe()
  local result, err = io_m.pipe()
  assert(result, "pipe failed: " .. (err or ""))
  assert(result.reader, "pipe missing reader")
  assert(result.writer, "pipe missing writer")
  assert(result.reader ~= result.writer, "reader and writer should be different fds")

  -- Write to pipe
  local msg = "pipe test message"
  local n = assert(io_m.write(result.writer, msg))
  assert(n == #msg, "write to pipe failed")

  -- Read from pipe
  local data = assert(io_m.read(result.reader, #msg))
  assert(data == msg, "read from pipe failed: got '" .. data .. "'")

  assert(io_m.close(result.reader))
  assert(io_m.close(result.writer))
end
test_pipe()

local function test_fsync_fdatasync()
  local filepath = path.join(TEST_TMPDIR, "io_test_sync.txt")

  local fd = assert(io_m.open(filepath, io_m.O_WRONLY | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8)))
  assert(io_m.write(fd, "sync test"))

  -- Test fsync
  local ok, err = io_m.fsync(fd)
  assert(ok, "fsync failed: " .. (err or ""))

  -- Test fdatasync
  ok, err = io_m.fdatasync(fd)
  assert(ok, "fdatasync failed: " .. (err or ""))

  assert(io_m.close(fd))
  os.remove(filepath)
end
test_fsync_fdatasync()

local function test_constants()
  -- Verify constants are exported
  assert(io_m.O_RDONLY ~= nil, "O_RDONLY not exported")
  assert(io_m.O_WRONLY ~= nil, "O_WRONLY not exported")
  assert(io_m.O_RDWR ~= nil, "O_RDWR not exported")
  assert(io_m.O_CREAT ~= nil, "O_CREAT not exported")
  assert(io_m.O_TRUNC ~= nil, "O_TRUNC not exported")
  assert(io_m.O_APPEND ~= nil, "O_APPEND not exported")
  assert(io_m.O_EXCL ~= nil, "O_EXCL not exported")
  assert(io_m.O_CLOEXEC ~= nil, "O_CLOEXEC not exported")

  assert(io_m.SEEK_SET ~= nil, "SEEK_SET not exported")
  assert(io_m.SEEK_CUR ~= nil, "SEEK_CUR not exported")
  assert(io_m.SEEK_END ~= nil, "SEEK_END not exported")

  assert(io_m.F_GETFD ~= nil, "F_GETFD not exported")
  assert(io_m.F_SETFD ~= nil, "F_SETFD not exported")
  assert(io_m.F_GETFL ~= nil, "F_GETFL not exported")
  assert(io_m.F_SETFL ~= nil, "F_SETFL not exported")
  assert(io_m.FD_CLOEXEC ~= nil, "FD_CLOEXEC not exported")

  assert(io_m.AT_FDCWD ~= nil, "AT_FDCWD not exported")
end
test_constants()

local function test_fcntl_getfl_setfl()
  local filepath = path.join(TEST_TMPDIR, "io_test_fcntl.txt")

  local fd = assert(io_m.open(filepath, io_m.O_RDWR | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8)))

  -- Get flags
  local flags = io_m.fcntl(fd, io_m.F_GETFL)
  assert(flags ~= nil, "fcntl F_GETFL failed")

  assert(io_m.close(fd))
  os.remove(filepath)
end
test_fcntl_getfl_setfl()

local function test_open_nonexistent_fails()
  local fd, err = io_m.open("/nonexistent/path/to/file.txt", io_m.O_RDONLY)
  assert(fd == nil, "opening nonexistent file should fail")
  assert(err ~= nil, "should have error message")
end
test_open_nonexistent_fails()

local function test_append_mode()
  local filepath = path.join(TEST_TMPDIR, "io_test_append.txt")

  -- Create file with initial content
  local fd = assert(io_m.open(filepath, io_m.O_WRONLY | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8)))
  assert(io_m.write(fd, "hello"))
  assert(io_m.close(fd))

  -- Open in append mode
  fd = assert(io_m.open(filepath, io_m.O_WRONLY | io_m.O_APPEND))
  assert(io_m.write(fd, " world"))
  assert(io_m.close(fd))

  -- Verify content
  fd = assert(io_m.open(filepath, io_m.O_RDONLY))
  local data = assert(io_m.read(fd, 100))
  assert(data == "hello world", "append mode failed: got '" .. data .. "'")
  assert(io_m.close(fd))

  os.remove(filepath)
end
test_append_mode()

local function test_slurp()
  local filepath = path.join(TEST_TMPDIR, "io_test_slurp.txt")
  local content = "hello from slurp test\nwith multiple lines"

  -- Write file using barf
  local ok, err = io_m.barf(filepath, content)
  assert(ok, "barf failed: " .. (err or ""))

  -- Read file using slurp
  local data: string
  data, err = io_m.slurp(filepath)
  assert(data == content, "slurp failed: " .. (err or "") .. " got '" .. tostring(data) .. "'")

  os.remove(filepath)
end
test_slurp()

local function test_barf_with_mode()
  local filepath = path.join(TEST_TMPDIR, "io_test_barf_mode.txt")
  local content = "file with specific mode"

  local ok, err = io_m.barf(filepath, content, tonumber("600", 8))
  assert(ok, "barf with mode failed: " .. (err or ""))

  local data = assert(io_m.slurp(filepath))
  assert(data == content, "content mismatch after barf with mode")

  os.remove(filepath)
end
test_barf_with_mode()

local function test_slurp_nonexistent()
  local data, err = io_m.slurp("/nonexistent/file/path.txt")
  assert(data == nil, "slurp of nonexistent file should return nil")
  assert(err ~= nil, "slurp of nonexistent file should return error")
end
test_slurp_nonexistent()

local function test_read_write_with_offset()
  local filepath = path.join(TEST_TMPDIR, "io_test_pread.txt")

  -- Create file with content
  local fd = assert(io_m.open(filepath, io_m.O_RDWR | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8)))
  assert(io_m.write(fd, "0123456789"))

  -- Read at offset (pread behavior)
  local data, err = io_m.read(fd, 3, 5)
  assert(data == "567", "read with offset failed: " .. (err or "") .. " got '" .. tostring(data) .. "'")

  -- Write at offset (pwrite behavior)
  local n: number
  n, err = io_m.write(fd, "ABC", 2)
  assert(n == 3, "write with offset failed: " .. (err or ""))

  -- Verify
  assert(io_m.lseek(fd, 0, io_m.SEEK_SET))
  data = assert(io_m.read(fd, 100))
  assert(data == "01ABC56789", "write with offset result: got '" .. data .. "'")

  assert(io_m.close(fd))
  os.remove(filepath)
end
test_read_write_with_offset()
