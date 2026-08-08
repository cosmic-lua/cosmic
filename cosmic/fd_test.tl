#!/usr/bin/env cosmic
local check = require("cosmic.check")
local cfd = require("cosmic.fd")
local fs = require("cosmic.fs")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

local function test_open_read_write_close()
  local filepath = fs.join(TEST_TMPDIR, "io_test_basic.txt")
  local content = "hello, cosmic.fd!"

  local fh = check.must(cfd.open(filepath, cfd.O_WRONLY | cfd.O_CREAT | cfd.O_TRUNC, tonumber("644", 8)))

  local n, werr = fh:write(content)
  assert(n == #content, "write failed: " .. (werr or "") .. " wrote " .. tostring(n) .. " expected " .. #content)
  assert(fh:close(), "close failed")

  fh = check.must(cfd.open(filepath, cfd.O_RDONLY))

  local data, rerr = fh:read(1024)
  assert(data == content, "read failed: " .. (rerr or "") .. " got '" .. tostring(data) .. "'")
  assert(fh:close(), "close failed")

  assert(os.remove(filepath))
end
test_open_read_write_close()

local function test_seek()
  local filepath = fs.join(TEST_TMPDIR, "io_test_seek.txt")
  local content = "0123456789"

  local f = check.must(cfd.open(filepath, cfd.O_WRONLY | cfd.O_CREAT | cfd.O_TRUNC, tonumber("644", 8)))
  assert(f:write(content))
  assert(f:close())

  f = check.must(cfd.open(filepath, cfd.O_RDONLY))

  local pos, err = f:seek(5, cfd.SEEK_SET)
  assert(pos == 5, "seek SEEK_SET failed: " .. (err or "") .. " pos=" .. tostring(pos))

  local data = assert(f:read(5))
  assert(data == "56789", "expected '56789' got '" .. data .. "'")

  pos = assert(f:seek(-3, cfd.SEEK_CUR))
  assert(pos == 7, "seek SEEK_CUR failed, pos=" .. tostring(pos))

  pos = assert(f:seek(0, cfd.SEEK_END))
  assert(pos == 10, "seek SEEK_END failed, pos=" .. tostring(pos))

  assert(f:close())
  assert(os.remove(filepath))
end
test_seek()

local function test_handle_truncate()
  local filepath = fs.join(TEST_TMPDIR, "io_test_htrunc.txt")
  local content = "0123456789"

  local f = check.must(cfd.open(filepath, cfd.O_RDWR | cfd.O_CREAT | cfd.O_TRUNC, tonumber("644", 8)))
  assert(f:write(content))

  local ok, err = f:truncate(5)
  assert(ok, "truncate failed: " .. (err or ""))

  assert(f:seek(0, cfd.SEEK_SET))
  local data = assert(f:read(100))
  assert(data == "01234", "expected '01234' got '" .. data .. "'")

  assert(f:close())
  assert(os.remove(filepath))
end
test_handle_truncate()

local function test_truncate()
  local filepath = fs.join(TEST_TMPDIR, "io_test_trunc.txt")
  local content = "0123456789"

  local f = check.must(cfd.open(filepath, cfd.O_WRONLY | cfd.O_CREAT | cfd.O_TRUNC, tonumber("644", 8)))
  assert(f:write(content))
  assert(f:close())

  -- Path-based truncate lives in fs; the fd layer only truncates handles.
  local ok, err = fs.truncate(filepath, 3)
  assert(ok, "truncate failed: " .. (err or ""))

  f = check.must(cfd.open(filepath, cfd.O_RDONLY))
  local data = assert(f:read(100))
  assert(data == "012", "expected '012' got '" .. data .. "'")
  assert(f:close())

  assert(os.remove(filepath))
end
test_truncate()

local function test_dup()
  local filepath = fs.join(TEST_TMPDIR, "io_test_dup.txt")
  local content = "dup test"

  local f = check.must(cfd.open(filepath, cfd.O_RDWR | cfd.O_CREAT | cfd.O_TRUNC, tonumber("644", 8)))
  assert(f:write(content))

  local f2h = check.must(f:dup())
  assert(f2h:fd() ~= f:fd(), "dup should return different fd")

  assert(f2h:seek(0, cfd.SEEK_SET))
  local data = assert(f2h:read(100))
  assert(data == content, "read from dup'd handle failed: got '" .. data .. "'")

  assert(f:close())
  assert(f2h:close())
  assert(os.remove(filepath))
end
test_dup()

local function test_pipe()
  local ph = check.must(cfd.pipe())
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

  local f = check.must(cfd.open(filepath, cfd.O_WRONLY | cfd.O_CREAT | cfd.O_TRUNC, tonumber("644", 8)))
  assert(f:write("sync test"))

  local ok, err = f:sync()
  assert(ok, "sync failed: " .. (err or ""))

  assert(f:close())
  assert(os.remove(filepath))
end
test_sync()

local function test_constants()
  assert(cfd.O_RDONLY ~= nil, "O_RDONLY not exported")
  assert(cfd.O_WRONLY ~= nil, "O_WRONLY not exported")
  assert(cfd.O_RDWR ~= nil, "O_RDWR not exported")
  assert(cfd.O_CREAT ~= nil, "O_CREAT not exported")
  assert(cfd.O_TRUNC ~= nil, "O_TRUNC not exported")
  assert(cfd.O_APPEND ~= nil, "O_APPEND not exported")
  assert(cfd.O_EXCL ~= nil, "O_EXCL not exported")
  assert(cfd.O_CLOEXEC ~= nil, "O_CLOEXEC not exported")
  assert(cfd.O_DIRECT ~= nil, "O_DIRECT not exported")
  assert(cfd.O_DIRECTORY ~= nil, "O_DIRECTORY not exported")
  assert(cfd.O_NOFOLLOW ~= nil, "O_NOFOLLOW not exported")

  assert(cfd.SEEK_SET ~= nil, "SEEK_SET not exported")
  assert(cfd.SEEK_CUR ~= nil, "SEEK_CUR not exported")
  assert(cfd.SEEK_END ~= nil, "SEEK_END not exported")

  assert(cfd.F_GETFD ~= nil, "F_GETFD not exported")
  assert(cfd.F_SETFD ~= nil, "F_SETFD not exported")
  assert(cfd.F_GETFL ~= nil, "F_GETFL not exported")
  assert(cfd.F_SETFL ~= nil, "F_SETFL not exported")
  assert(cfd.F_RDLCK ~= nil, "F_RDLCK not exported")
  assert(cfd.F_WRLCK ~= nil, "F_WRLCK not exported")
  assert(cfd.F_UNLCK ~= nil, "F_UNLCK not exported")
  assert(cfd.FD_CLOEXEC ~= nil, "FD_CLOEXEC not exported")

  assert(cfd.AT_FDCWD ~= nil, "AT_FDCWD not exported")
end
test_constants()

local function test_fcntl()
  local filepath = fs.join(TEST_TMPDIR, "io_test_fcntl.txt")

  local f = check.must(cfd.open(filepath, cfd.O_RDWR | cfd.O_CREAT | cfd.O_TRUNC, tonumber("644", 8)))

  -- Get file descriptor flags
  local fdflags, err = f:fcntl(cfd.F_GETFD)
  assert(fdflags ~= nil, "fcntl F_GETFD failed: " .. (err or ""))

  -- Set close-on-exec
  local ok: number
  ok, err = f:fcntl(cfd.F_SETFD, cfd.FD_CLOEXEC)
  assert(ok ~= nil, "fcntl F_SETFD failed: " .. (err or ""))

  assert(f:close())
  assert(os.remove(filepath))
end
test_fcntl()

local function test_open_nonexistent_fails()
  local f, err = cfd.open("/nonexistent/path/to/file.txt", cfd.O_RDONLY)
  assert(f == nil, "opening nonexistent file should fail")
  assert(err ~= nil, "should have error message")
end
test_open_nonexistent_fails()

local function test_append_mode()
  local filepath = fs.join(TEST_TMPDIR, "io_test_append.txt")

  local f = check.must(cfd.open(filepath, cfd.O_WRONLY | cfd.O_CREAT | cfd.O_TRUNC, tonumber("644", 8)))
  assert(f:write("hello"))
  assert(f:close())

  f = check.must(cfd.open(filepath, cfd.O_WRONLY | cfd.O_APPEND))
  assert(f:write(" world"))
  assert(f:close())

  f = check.must(cfd.open(filepath, cfd.O_RDONLY))
  local data = assert(f:read(100))
  assert(data == "hello world", "append mode failed: got '" .. data .. "'")
  assert(f:close())

  assert(os.remove(filepath))
end
test_append_mode()

local function test_read_write_roundtrip()
  local filepath = fs.join(TEST_TMPDIR, "io_test_slurp.txt")
  local content = "hello from fs.read test\nwith multiple lines"

  local ok, err = fs.write(filepath, content)
  assert(ok, "fs.write failed: " .. (err or ""))

  local data: string
  data, err = fs.read(filepath)
  assert(data == content, "fs.read failed: " .. (err or "") .. " got '" .. tostring(data) .. "'")

  assert(os.remove(filepath))
end
test_read_write_roundtrip()

local function test_read_nonexistent()
  local data, err = fs.read("/nonexistent/file/path.txt")
  assert(data == nil, "fs.read of nonexistent file should return nil")
  assert(err ~= nil, "fs.read of nonexistent file should return error")
end
test_read_nonexistent()

-- Errors carry the errno name and enough context to act on:
-- a failed read names ENOENT, a failed open names both the path and the
-- errno, and fd-level failures surface the binding's errno string instead
-- of a fabricated message.
local function test_read_error_names_errno()
  local _, err = fs.read("/nonexistent/file/path.txt")
  assert(err:match("ENOENT"), "fs.read error should name ENOENT, got: " .. err)
  assert(err:match("/nonexistent/file/path%.txt"), "fs.read error should name the path, got: " .. err)
end
test_read_error_names_errno()

local function test_write_path_error_names_errno()
  local _, err = fs.write("/nonexistent/dir/file.txt", "data")
  assert(err:match("ENOENT"), "fs.write error should name ENOENT, got: " .. err)
end
test_write_path_error_names_errno()

local function test_wrap_tmpfd()
  -- fs.temp_fd returns a Handle now (#988); take its fd to exercise wrap.
  local th = check.must(fs.temp_fd())
  local rawfd = th:fd()
  local h = cfd.wrap(rawfd)
  assert(h:fd() == rawfd, "wrap should expose the same fd")
  assert(h:write("wrapped"))
  assert(h:seek(0, cfd.SEEK_SET))
  assert(h:read(100) == "wrapped", "read through wrapped handle")
  assert(h:close(), "close through wrapped handle")
  assert(h:closed(), "wrapped handle should report closed")
end
test_wrap_tmpfd()

local function test_tmpfile_handle()
  local tf = check.must(fs.temp_file(fs.join(TEST_TMPDIR, "wrap_XXXXXX")),
    "temp_file should succeed")
  assert(tf.handle:write("via temp_file"))
  assert(tf.handle:close())
  assert(fs.read(tf.path) == "via temp_file", "data lands in the temp_file")
  assert(fs.remove(tf.path))
end
test_tmpfile_handle()

local function test_open_error_names_path_and_errno()
  local _, err = cfd.open("/nonexistent/path/to/file.txt", cfd.O_RDONLY)
  assert(err:match("ENOENT"), "open error should name ENOENT, got: " .. err)
  assert(err:match("/nonexistent/path/to/file%.txt"), "open error should name the path, got: " .. err)
end
test_open_error_names_path_and_errno()

local function test_truncate_error_names_path_and_errno()
  local ok, err = fs.truncate("/nonexistent/path/to/file.txt")
  assert(ok == false, "truncate of nonexistent file should fail")
  assert(err:match("ENOENT"), "truncate error should name ENOENT, got: " .. err)
  assert(err:match("/nonexistent/path/to/file%.txt"), "truncate error should name the path, got: " .. err)
end
test_truncate_error_names_path_and_errno()

local function test_write_error_names_errno()
  local filepath = fs.join(TEST_TMPDIR, "io_test_rdonly.txt")
  assert(fs.write(filepath, "content"))
  local f = check.must(cfd.open(filepath, cfd.O_RDONLY))
  local n, err = f:write("nope")
  assert(n == nil, "write to O_RDONLY handle should fail")
  assert(err:match("EBADF"), "write error should name EBADF, got: " .. err)
  assert(f:close())
  assert(os.remove(filepath))
end
test_write_error_names_errno()

local function test_closed_handle()
  local filepath = fs.join(TEST_TMPDIR, "io_test_closed.txt")

  local f = check.must(cfd.open(filepath, cfd.O_WRONLY | cfd.O_CREAT | cfd.O_TRUNC, tonumber("644", 8)))
  assert(not f:closed(), "handle should not be closed yet")
  assert(f:close())
  assert(f:closed(), "handle should be closed")

  local data, err = f:read(100)
  assert(data == nil and err == "handle closed", "read on closed handle should fail")

  local n: number
  n, err = f:write("test")
  assert(n == nil and err == "handle closed", "write on closed handle should fail")

  assert(f:close(), "close should be idempotent")

  assert(os.remove(filepath))
end
test_closed_handle()

local function test_fd_method()
  local filepath = fs.join(TEST_TMPDIR, "io_test_fd.txt")

  local f = check.must(cfd.open(filepath, cfd.O_WRONLY | cfd.O_CREAT | cfd.O_TRUNC, tonumber("644", 8)))
  local fd = f:fd()
  assert(fd > 0, "fd should be positive")

  assert(f:close())
  assert(f:fd() == -1, "fd should be -1 after close")

  assert(os.remove(filepath))
end
test_fd_method()

local function test_close_metamethod_exists()
  local filepath = fs.join(TEST_TMPDIR, "io_test_meta.txt")

  local f = check.must(cfd.open(filepath, cfd.O_WRONLY | cfd.O_CREAT | cfd.O_TRUNC, tonumber("644", 8)))
  local mt = getmetatable(f)
  assert(mt, "handle should have metatable")
  assert(mt.__close, "handle metatable should have __close")

  do
    local _ < close > = f
  end
  assert(f:closed(), "handle should be closed after __close")

  assert(os.remove(filepath))
end
test_close_metamethod_exists()

-- Pipe:close must surface a close failure instead of always returning
-- true, and it must still close BOTH ends even when one fails.
local function test_pipe_close_propagates_error_and_closes_both()
  local p = check.must(cfd.pipe())
  local dead_fd = p.reader:fd()
  assert(p.reader:close(), "reader close should succeed the first time")
  -- The reader's Handle now reports closed, but the OS fd it held is
  -- really gone. Point a fresh Handle at that same (now-invalid) fd so
  -- Pipe:close's internal unix.close() call fails with EBADF, while the
  -- writer must still be closed.
  p.reader = cfd.wrap(dead_fd)

  local ok, err = p:close()
  assert(ok == false, "close should report the reader's failure")
  assert(err ~= nil and err:match("EBADF"), "expected EBADF, got: " .. tostring(err))
  assert(p.writer:closed(), "writer should still be closed despite the reader failing")
end
test_pipe_close_propagates_error_and_closes_both()

local function test_pipe_close_metamethod_exists()
  local p = check.must(cfd.pipe())
  local mt = getmetatable(p)
  assert(mt, "pipe should have metatable")
  assert(mt.__close, "pipe metatable should have __close")

  do
    local _ < close > = p
  end
  assert(p:closed(), "pipe should be closed after __close")
end
test_pipe_close_metamethod_exists()

local function test_read_write_with_offset()
  local filepath = fs.join(TEST_TMPDIR, "io_test_pread.txt")

  local f = check.must(cfd.open(filepath, cfd.O_RDWR | cfd.O_CREAT | cfd.O_TRUNC, tonumber("644", 8)))
  assert(f:write("0123456789"))

  -- Read at offset (pread behavior)
  local data, err = f:read(3, 5)
  assert(data == "567", "read with offset failed: " .. (err or "") .. " got '" .. tostring(data) .. "'")

  -- Write at offset (pwrite behavior)
  local n: number
  n, err = f:write("ABC", 2)
  assert(n == 3, "write with offset failed: " .. (err or ""))

  -- Verify
  assert(f:seek(0, cfd.SEEK_SET))
  data = assert(f:read(100))
  assert(data == "01ABC56789", "write with offset result: got '" .. data .. "'")

  assert(f:close())
  assert(os.remove(filepath))
end
test_read_write_with_offset()

local function test_write_with_mode()
  local filepath = fs.join(TEST_TMPDIR, "io_test_barf_mode.txt")
  local content = "file with specific mode"

  local ok, err = fs.write(filepath, content, {mode = tonumber("600", 8)})
  assert(ok, "fs.write with mode failed: " .. (err or ""))

  local data = assert(fs.read(filepath))
  assert(data == content, "content mismatch after fs.write with mode")

  assert(os.remove(filepath))
end
test_write_with_mode()

local function test_datasync()
  local filepath = fs.join(TEST_TMPDIR, "io_test_datasync.txt")

  local f = check.must(cfd.open(filepath, cfd.O_WRONLY | cfd.O_CREAT | cfd.O_TRUNC, tonumber("644", 8)))
  assert(f:write("datasync test"))

  local ok, err = f:datasync()
  assert(ok, "datasync failed: " .. (err or ""))

  assert(f:close())
  assert(os.remove(filepath))
end
test_datasync()

-- FIX 5: handle:close() must propagate unix.close() failure instead of
-- always returning true.  The error path is hard to trigger directly, so we
-- verify: (a) successful close returns true, (b) idempotent second close
-- returns true, and (c) the return type is boolean (not always true when
-- unix.close would fail on a bad fd).
local function test_close_returns_boolean_and_is_idempotent()
  local filepath = fs.join(TEST_TMPDIR, "io_test_close_bool.txt")

  local f = check.must(cfd.open(filepath, cfd.O_WRONLY | cfd.O_CREAT | cfd.O_TRUNC, tonumber("644", 8)))
  assert(f:write("x"))

  -- First close should succeed and return true
  local ok, err = f:close()
  assert(ok == true, "first close should return true, got: " .. tostring(ok) .. " err=" .. tostring(err))
  assert(err == nil, "first close should have no error, got: " .. tostring(err))

  -- Second close (already closed) should return true (idempotent)
  ok, err = f:close()
  assert(ok == true, "second close (idempotent) should return true, got: " .. tostring(ok))
  assert(err == nil, "second close should have no error, got: " .. tostring(err))

  assert(os.remove(filepath))
end
test_close_returns_boolean_and_is_idempotent()
