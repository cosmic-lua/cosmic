--- Examples for cosmic.stream module.

-- Example_reader demonstrates the stream contract: one drain loop works
-- for ANY Reader — bare nil (no error) is end of stream. Here the Reader
-- is an fd pipe Handle; a fetch.Reader or a child.Handle drains with the
-- exact same code.
local function Example_reader()
  local check = require("cosmic.check")
  local fd = require("cosmic.fd")
  local stream = require("cosmic.stream")

  local function drain(r: stream.Reader): string
    local parts: {string} = {}
    while true do
      local chunk, err = r:read(4096)
      assert(err == nil, err)
      if chunk == nil then
        break
      end
      parts[#parts + 1] = chunk
    end
    return table.concat(parts)
  end

  local p = check.must(fd.pipe())
  assert(p.writer:write("hello, "))
  assert(p.writer:write("stream"))
  assert(p.writer:close())

  print(drain(p.reader))
  assert(p.reader:close())
  -- Output:
  -- hello, stream
end

-- Example_writer demonstrates the Writer half: anything with
-- write(data) -> bytes | nil, err accepts bytes the same way.
local function Example_writer()
  local check = require("cosmic.check")
  local fd = require("cosmic.fd")
  local stream = require("cosmic.stream")

  local function put(w: stream.Writer, data: string): number
    local n = assert(w:write(data))
    return n
  end

  local p = check.must(fd.pipe())
  print(put(p.writer, "ten bytes!"))
  assert(p.writer:close())
  print(check.must(p.reader:read()))
  assert(p.reader:close())
  -- Output:
  -- 10
  -- ten bytes!
end

-- Example_new_reader demonstrates wrapping bytes already in hand as a
-- Reader: in-memory data drives any stream consumer — here the shared
-- line iterator — without touching a descriptor.
local function Example_new_reader()
  local check = require("cosmic.check")
  local stream = require("cosmic.stream")

  local iter = stream.lines(stream.new_reader("alpha\nbeta\n"))
  print(check.must(iter()))
  print(check.must(iter()))
  -- Output:
  -- alpha
  -- beta
end

-- Example_new_buffer demonstrates the in-memory Writer: point any
-- Reader-to-Writer plumbing at it and read the result back as a
-- string. With new_reader on the other end, a whole pipeline runs
-- without touching a descriptor.
local function Example_new_buffer()
  local check = require("cosmic.check")
  local stream = require("cosmic.stream")

  local buf = stream.new_buffer()
  check.must(stream.copy(buf, stream.new_reader("round trip")))
  print(buf:contents())
  -- Output:
  -- round trip
end

-- Suppress unused warnings for examples
local _ = {Example_reader, Example_writer, Example_new_reader, Example_new_buffer}
