--- What cosmic/poll_test.tl and cosmic/stream_fd_test.tl share: a named pipe to wait on or read. Test support.

local sys = require("cosmic.sys")

local record fifo_fixture
  --- The two ends of a pipe.
  record Ends
    reader: integer
    writer: integer
  end
end

--- The two ends of a named pipe in `dir`, neither waiting: the reading
--- end open first, as a pipe with no reader refuses a nonblocking writer.
--- @param dir where to make it
--- @param name its name there
--- @return the descriptors of its ends
function fifo_fixture.fifo(dir: string, name: string): fifo_fixture.Ends
  local path = dir .. "/" .. name
  assert(sys.mkfifo(path, 384))
  local reader = assert(sys.open(path, sys.O_RDONLY | sys.O_NONBLOCK, 0))
  local writer = assert(sys.open(path, sys.O_WRONLY | sys.O_NONBLOCK, 0))
  return { reader = reader, writer = writer }
end

return fifo_fixture
