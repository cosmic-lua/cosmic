#!/usr/bin/env cosmic
local io_m = require("cosmic.io")
local fs = require("cosmic.fs")

global TEST_TMPDIR: string

local function test_open_read_write_close()
  local filepath = fs.join(TEST_TMPDIR, "io_test_basic.txt")
  local content = "hello, cosmic.io!"

  local f, err = io_m.open(filepath, io_m.O_WRONLY | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8))
  assert(f, "open for write failed: " .. (err or ""))
  local fh = f as io_m.Handle

  local n, werr = fh:write(content)
  assert(n == #content, "write failed: " .. (werr or "") .. " wrote " .. tostring(n) .. " expected " .. #content)
  assert(fh:close(), "close failed")

  f, err = io_m.open(filepath, io_m.O_RDONLY)
  assert(f, "open for read failed: " .. (err or ""))
  fh = f as io_m.Handle

  local data, rerr = fh:read(1024)
  assert(data == content, "read failed: " .. (rerr or "") .. " got '" .. tostring(data) .. "'")
  assert(fh:close(), "close failed")

  os.remove(filepath)
end
test_open_read_write_close()

local function test_seek()
  local filepath = fs.join(TEST_TMPDIR, "io_test_seek.txt")
  local content = "0123456789"

  local f = assert(io_m.open(filepath, io_m.O_WRONLY | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8))) as io_m.Handle
  assert(f:write(content))
  assert(f:close())

  f = assert(io_m.open(filepath, io_m.O_RDONLY)) as io_m.Handle

  local pos, err = f:seek(5, io_m.SEEK_SET)
  assert(pos == 5, "seek SEEK_SET failed: " .. (err or "") .. " pos=" .. tostring(pos))

  local data = assert(f:read(5))
  assert(data == "56789", "expected '56789' got '" .. data .. "'")

  pos = assert(f:seek(-3, io_m.SEEK_CUR))
  assert(pos == 7, "seek SEEK_CUR failed, pos=" .. tostring(pos))

  pos = assert(f:seek(0, io_m.SEEK_END))
  assert(pos == 10, "seek SEEK_END failed, pos=" .. tostring(pos))

  assert(f:close())
  os.remove(filepath)
end
test_seek()

local function test_handle_truncate()
  local filepath = fs.join(TEST_TMPDIR, "io_test_htrunc.txt")
  local content = "0123456789"

  local f = assert(io_m.open(filepath, io_m.O_RDWR | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8))) as io_m.Handle
  assert(f:write(content))

  local ok, err = f:truncate(5)
  assert(ok, "truncate failed: " .. (err or ""))

  assert(f:seek(0, io_m.SEEK_SET))
  local data = assert(f:read(100))
  assert(data == "01234", "expected '01234' got '" .. data .. "'")

  assert(f:close())
  os.remove(filepath)
end
test_handle_truncate()

local function test_truncate()
  local filepath = fs.join(TEST_TMPDIR, "io_test_trunc.txt")
  local content = "0123456789"

  local f = assert(io_m.open(filepath, io_m.O_WRONLY | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8))) as io_m.Handle
  assert(f:write(content))
  assert(f:close())

  local ok, err = io_m.truncate(filepath, 3)
  assert(ok, "truncate failed: " .. (err or ""))

  f = assert(io_m.open(filepath, io_m.O_RDONLY)) as io_m.Handle
  local data = assert(f:read(100))
  assert(data == "012", "expected '012' got '" .. data .. "'")
  assert(f:close())

  os.remove(filepath)
end
test_truncate()

local function test_dup()
  local filepath = fs.join(TEST_TMPDIR, "io_test_dup.txt")
  local content = "dup test"

  local f = assert(io_m.open(filepath, io_m.O_RDWR | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8))) as io_m.Handle
  assert(f:write(content))

  local f2, err = f:dup()
  assert(f2, "dup failed: " .. (err or ""))
  local f2h = f2 as io_m.Handle
  assert(f2h:fd() ~= f:fd(), "dup should return different fd")

  assert(f2h:seek(0, io_m.SEEK_SET))
  local data = assert(f2h:read(100))
  assert(data == content, "read from dup'd handle failed: got '" .. data .. "'")

  assert(f:close())
  assert(f2h:close())
  os.remove(filepath)
end
test_dup()

local function test_pipe()
  local p, err = io_m.pipe()
  assert(p, "pipe failed: " .. (err or ""))
  local ph = p as io_m.Pipe
  assert(ph.reader, "pipe missing reader")
  assert(ph.writer, "pipe missing writer")
  assert(ph.reader:fd() ~= ph.writer:fd(), "reader and writer should be different fds")

  local msg = "pipe test message"
  local n = assert(ph.writer:write(msg))
  assert(n == #msg, "write to pipe failed")

  local data = assert(ph.reader:read(#msg))
  assert(data == msg, "read from pipe failed: got '" .. data .. "'")

  assert(ph:close())
  assert(ph:closed(), "pipe should be closed")
end
test_pipe()

local function test_sync()
  local filepath = fs.join(TEST_TMPDIR, "io_test_sync.txt")

  local f = assert(io_m.open(filepath, io_m.O_WRONLY | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8))) as io_m.Handle
  assert(f:write("sync test"))

  local ok, err = f:sync()
  assert(ok, "sync failed: " .. (err or ""))

  assert(f:close())
  os.remove(filepath)
end
test_sync()

local function test_constants()
  assert(io_m.O_RDONLY ~= nil, "O_RDONLY not exported")
  assert(io_m.O_WRONLY ~= nil, "O_WRONLY not exported")
  assert(io_m.O_RDWR ~= nil, "O_RDWR not exported")
  assert(io_m.O_CREAT ~= nil, "O_CREAT not exported")
  assert(io_m.O_TRUNC ~= nil, "O_TRUNC not exported")
  assert(io_m.O_APPEND ~= nil, "O_APPEND not exported")
  assert(io_m.O_EXCL ~= nil, "O_EXCL not exported")
  assert(io_m.O_CLOEXEC ~= nil, "O_CLOEXEC not exported")
  assert(io_m.O_DIRECT ~= nil, "O_DIRECT not exported")
  assert(io_m.O_DIRECTORY ~= nil, "O_DIRECTORY not exported")
  assert(io_m.O_NOFOLLOW ~= nil, "O_NOFOLLOW not exported")

  assert(io_m.SEEK_SET ~= nil, "SEEK_SET not exported")
  assert(io_m.SEEK_CUR ~= nil, "SEEK_CUR not exported")
  assert(io_m.SEEK_END ~= nil, "SEEK_END not exported")

  assert(io_m.F_GETFD ~= nil, "F_GETFD not exported")
  assert(io_m.F_SETFD ~= nil, "F_SETFD not exported")
  assert(io_m.F_GETFL ~= nil, "F_GETFL not exported")
  assert(io_m.F_SETFL ~= nil, "F_SETFL not exported")
  assert(io_m.F_RDLCK ~= nil, "F_RDLCK not exported")
  assert(io_m.F_WRLCK ~= nil, "F_WRLCK not exported")
  assert(io_m.F_UNLCK ~= nil, "F_UNLCK not exported")
  assert(io_m.FD_CLOEXEC ~= nil, "FD_CLOEXEC not exported")

  assert(io_m.AT_FDCWD ~= nil, "AT_FDCWD not exported")
end
test_constants()

local function test_fcntl()
  local filepath = fs.join(TEST_TMPDIR, "io_test_fcntl.txt")

  local f = assert(io_m.open(filepath, io_m.O_RDWR | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8))) as io_m.Handle

  -- Get file descriptor flags
  local fdflags, err = f:fcntl(io_m.F_GETFD)
  assert(fdflags ~= nil, "fcntl F_GETFD failed: " .. (err or ""))

  -- Set close-on-exec
  local ok: number
  ok, err = f:fcntl(io_m.F_SETFD, io_m.FD_CLOEXEC)
  assert(ok ~= nil, "fcntl F_SETFD failed: " .. (err or ""))

  assert(f:close())
  os.remove(filepath)
end
test_fcntl()

local function test_open_nonexistent_fails()
  local f, err = io_m.open("/nonexistent/path/to/file.txt", io_m.O_RDONLY)
  assert(f == nil, "opening nonexistent file should fail")
  assert(err ~= nil, "should have error message")
end
test_open_nonexistent_fails()

local function test_append_mode()
  local filepath = fs.join(TEST_TMPDIR, "io_test_append.txt")

  local f = assert(io_m.open(filepath, io_m.O_WRONLY | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8))) as io_m.Handle
  assert(f:write("hello"))
  assert(f:close())

  f = assert(io_m.open(filepath, io_m.O_WRONLY | io_m.O_APPEND)) as io_m.Handle
  assert(f:write(" world"))
  assert(f:close())

  f = assert(io_m.open(filepath, io_m.O_RDONLY)) as io_m.Handle
  local data = assert(f:read(100))
  assert(data == "hello world", "append mode failed: got '" .. data .. "'")
  assert(f:close())

  os.remove(filepath)
end
test_append_mode()

local function test_slurp_barf()
  local filepath = fs.join(TEST_TMPDIR, "io_test_slurp.txt")
  local content = "hello from slurp test\nwith multiple lines"

  local ok, err = io_m.barf(filepath, content)
  assert(ok, "barf failed: " .. (err or ""))

  local data: string
  data, err = io_m.slurp(filepath)
  assert(data == content, "slurp failed: " .. (err or "") .. " got '" .. tostring(data) .. "'")

  os.remove(filepath)
end
test_slurp_barf()

local function test_slurp_nonexistent()
  local data, err = io_m.slurp("/nonexistent/file/path.txt")
  assert(data == nil, "slurp of nonexistent file should return nil")
  assert(err ~= nil, "slurp of nonexistent file should return error")
end
test_slurp_nonexistent()

local function test_closed_handle()
  local filepath = fs.join(TEST_TMPDIR, "io_test_closed.txt")

  local f = assert(io_m.open(filepath, io_m.O_WRONLY | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8))) as io_m.Handle
  assert(not f:closed(), "handle should not be closed yet")
  assert(f:close())
  assert(f:closed(), "handle should be closed")

  local data, err = f:read(100)
  assert(data == nil and err == "handle closed", "read on closed handle should fail")

  local n: number
  n, err = f:write("test")
  assert(n == nil and err == "handle closed", "write on closed handle should fail")

  assert(f:close(), "close should be idempotent")

  os.remove(filepath)
end
test_closed_handle()

local function test_fd_method()
  local filepath = fs.join(TEST_TMPDIR, "io_test_fd.txt")

  local f = assert(io_m.open(filepath, io_m.O_WRONLY | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8))) as io_m.Handle
  local fd = f:fd()
  assert(fd > 0, "fd should be positive")

  assert(f:close())
  assert(f:fd() == -1, "fd should be -1 after close")

  os.remove(filepath)
end
test_fd_method()

local function test_close_metamethod_exists()
  local filepath = fs.join(TEST_TMPDIR, "io_test_meta.txt")

  local f = assert(io_m.open(filepath, io_m.O_WRONLY | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8))) as io_m.Handle
  local mt = getmetatable(f)
  assert(mt, "handle should have metatable")
  assert(mt.__close, "handle metatable should have __close")

  mt.__close(f)
  assert(f:closed(), "handle should be closed after __close")

  os.remove(filepath)
end
test_close_metamethod_exists()

local function test_pipe_close_metamethod_exists()
  local p = assert(io_m.pipe()) as io_m.Pipe
  local mt = getmetatable(p)
  assert(mt, "pipe should have metatable")
  assert(mt.__close, "pipe metatable should have __close")

  mt.__close(p)
  assert(p:closed(), "pipe should be closed after __close")
end
test_pipe_close_metamethod_exists()

local function test_read_write_with_offset()
  local filepath = fs.join(TEST_TMPDIR, "io_test_pread.txt")

  local f = assert(io_m.open(filepath, io_m.O_RDWR | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8))) as io_m.Handle
  assert(f:write("0123456789"))

  -- Read at offset (pread behavior)
  local data, err = f:read(3, 5)
  assert(data == "567", "read with offset failed: " .. (err or "") .. " got '" .. tostring(data) .. "'")

  -- Write at offset (pwrite behavior)
  local n: number
  n, err = f:write("ABC", 2)
  assert(n == 3, "write with offset failed: " .. (err or ""))

  -- Verify
  assert(f:seek(0, io_m.SEEK_SET))
  data = assert(f:read(100))
  assert(data == "01ABC56789", "write with offset result: got '" .. data .. "'")

  assert(f:close())
  os.remove(filepath)
end
test_read_write_with_offset()

local function test_barf_with_mode()
  local filepath = fs.join(TEST_TMPDIR, "io_test_barf_mode.txt")
  local content = "file with specific mode"

  local ok, err = io_m.barf(filepath, content, tonumber("600", 8))
  assert(ok, "barf with mode failed: " .. (err or ""))

  local data = assert(io_m.slurp(filepath))
  assert(data == content, "content mismatch after barf with mode")

  os.remove(filepath)
end
test_barf_with_mode()

local function test_datasync()
  local filepath = fs.join(TEST_TMPDIR, "io_test_datasync.txt")

  local f = assert(io_m.open(filepath, io_m.O_WRONLY | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8))) as io_m.Handle
  assert(f:write("datasync test"))

  local ok, err = f:datasync()
  assert(ok, "datasync failed: " .. (err or ""))

  assert(f:close())
  os.remove(filepath)
end
test_datasync()

-- FIX 5: handle:close() must propagate unix.close() failure instead of
-- always returning true.  The error path is hard to trigger directly, so we
-- verify: (a) successful close returns true, (b) idempotent second close
-- returns true, and (c) the return type is boolean (not always true when
-- unix.close would fail on a bad fd).
local function test_close_returns_boolean_and_is_idempotent()
  local filepath = fs.join(TEST_TMPDIR, "io_test_close_bool.txt")

  local f = assert(io_m.open(filepath, io_m.O_WRONLY | io_m.O_CREAT | io_m.O_TRUNC, tonumber("644", 8))) as io_m.Handle
  assert(f:write("x"))

  -- First close should succeed and return true
  local ok, err = f:close()
  assert(ok == true, "first close should return true, got: " .. tostring(ok) .. " err=" .. tostring(err))
  assert(err == nil, "first close should have no error, got: " .. tostring(err))

  -- Second close (already closed) should return true (idempotent)
  ok, err = f:close()
  assert(ok == true, "second close (idempotent) should return true, got: " .. tostring(ok))
  assert(err == nil, "second close should have no error, got: " .. tostring(err))

  os.remove(filepath)
end
test_close_returns_boolean_and_is_idempotent()
