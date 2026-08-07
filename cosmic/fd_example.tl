--- Examples for the cosmic.fd module.
--- Demonstrates descriptor-level file I/O — open flags, seek,
--- pread-style positional reads — and in-process pipes. For
--- whole-file path convenience use cosmic.fs; cosmic.fd is the layer
--- beneath it.

-- Example_open_write_read demonstrates opening with flags (mode 420
-- is 0644), writing, seeking back, and reading. The <close>
-- attribute releases the descriptor on scope exit (Lua 5.4
-- to-be-closed).
local function Example_open_write_read()
  local check = require("cosmic.check")
  local fd = require("cosmic.fd")
  local fs = require("cosmic.fs")
  local base = os.getenv("TEST_TMPDIR") or "/tmp"
  local dir = check.must(fs.temp_dir(fs.join(base, "fd_example_XXXXXX")))
  local path = fs.join(dir, "note.txt")

  local h < close > = check.must(fd.open(path, fd.O_RDWR | fd.O_CREAT, 420))
  print(check.must(h:write("hello fd")))
  assert(h:seek(0, fd.SEEK_SET))
  print(check.must(h:read(5)))
  assert(fs.remove_all(dir))
  -- Output:
  -- 8
  -- hello
end

-- Example_positional demonstrates pread-style access: passing an
-- offset reads from that position without moving the file cursor, so
-- the follow-up read still starts at the beginning.
local function Example_positional()
  local check = require("cosmic.check")
  local fd = require("cosmic.fd")
  local fs = require("cosmic.fs")
  local base = os.getenv("TEST_TMPDIR") or "/tmp"
  local dir = check.must(fs.temp_dir(fs.join(base, "fd_example_XXXXXX")))
  local path = fs.join(dir, "data.txt")
  assert(fs.write(path, "abcdef"))

  local h < close > = check.must(fd.open(path, fd.O_RDONLY))
  print(check.must(h:read(3, 2)))
  print(check.must(h:read(2)))
  assert(fs.remove_all(dir))
  -- Output:
  -- cde
  -- ab
end

-- Example_pipe demonstrates in-process pipes: bytes written to the
-- writer end come back from the reader end in order.
local function Example_pipe()
  local check = require("cosmic.check")
  local fd = require("cosmic.fd")
  local p < close > = check.must(fd.pipe())
  assert(p.writer:write("ping"))
  print(check.must(p.reader:read(4)))
  -- Output:
  -- ping
end

-- Suppress unused warnings for examples
local _ = {Example_open_write_read, Example_positional, Example_pipe}
