#!/usr/bin/env cosmic
--- Tests for the #560 fd contract: read() EOF/EAGAIN shape, sync placement.
local cfd = require("cosmic.fd")
local fs = require("cosmic.fs")

global TEST_TMPDIR: string

-- read() EOF contract — nil with no error means EOF; nil with an error
-- means failure. "" is never returned.

local function test_read_eof_returns_nil()
  local filepath = fs.join(TEST_TMPDIR, "io_test_eof.txt")
  assert(fs.write(filepath, "abc"))
  local f = assert(cfd.open(filepath, cfd.O_RDONLY)) as cfd.Handle
  assert(f:read(100) == "abc", "first read returns the content")
  local data, err = f:read(100)
  assert(data == nil, "read at EOF should return nil, got '" .. tostring(data) .. "'")
  assert(err == nil, "EOF is not an error, got: " .. tostring(err))
  assert(f:close())
  os.remove(filepath)
end
test_read_eof_returns_nil()

local function test_read_empty_file_returns_nil()
  local filepath = fs.join(TEST_TMPDIR, "io_test_empty.txt")
  assert(fs.write(filepath, ""))
  local f = assert(cfd.open(filepath, cfd.O_RDONLY)) as cfd.Handle
  local data, err = f:read(100)
  assert(data == nil, "first read of an empty file should return nil, got '" .. tostring(data) .. "'")
  assert(err == nil, "EOF is not an error, got: " .. tostring(err))
  assert(f:close())
  os.remove(filepath)
end
test_read_empty_file_returns_nil()

local function test_read_loop_terminates_on_nil()
  local filepath = fs.join(TEST_TMPDIR, "io_test_loop.txt")
  assert(fs.write(filepath, "0123456789"))
  local f = assert(cfd.open(filepath, cfd.O_RDONLY)) as cfd.Handle
  local parts: {string} = {}
  while true do
    local chunk, err = f:read(4)
    if not chunk then
      assert(err == nil, "loop should end on EOF, not an error: " .. tostring(err))
      break
    end
    parts[#parts + 1] = chunk
  end
  assert(table.concat(parts) == "0123456789", "chunked loop reassembles the file")
  assert(f:close())
  os.remove(filepath)
end
test_read_loop_terminates_on_nil()

-- Pin: a nonblocking read with no data is a FAILURE (nil + EAGAIN error),
-- distinct from EOF (nil + no error).
local function test_nonblocking_pipe_read_names_eagain()
  local p = assert(cfd.pipe(cfd.O_NONBLOCK)) as cfd.Pipe
  local data, err = p.reader:read(10)
  assert(data == nil, "empty nonblocking pipe read should return nil")
  assert(err and err:match("EAGAIN"), "error should name EAGAIN, got: " .. tostring(err))
  p:close()
end
test_nonblocking_pipe_read_names_eagain()

-- The system-wide sync(2) belongs to fs, not fd (no alias, pre-stable).
local function test_sync_moved_to_fs()
  assert((cfd as {string: any}).sync == nil, "fd.sync should be gone")
  local fs_sync = (fs as {string: any}).sync
  assert(type(fs_sync) == "function", "fs.sync should exist");
  (fs_sync as function())()
end
test_sync_moved_to_fs()
