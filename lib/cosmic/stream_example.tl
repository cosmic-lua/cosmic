--- Examples for cosmic.stream module.

-- Example_reader demonstrates the stream contract: one drain loop works
-- for ANY Reader — bare nil (no error) is end of stream. Here the Reader
-- is an fd pipe Handle; a fetch.Reader or a child.Handle drains with the
-- exact same code.
local function Example_reader()
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

  local p = fd.pipe() as fd.Pipe
  p.writer:write("hello, ")
  p.writer:write("stream")
  p.writer:close()

  print(drain(p.reader))
  p.reader:close()
  -- Output:
  -- hello, stream
end

-- Example_writer demonstrates the Writer half: anything with
-- write(data) -> bytes | nil, err accepts bytes the same way.
local function Example_writer()
  local fd = require("cosmic.fd")
  local stream = require("cosmic.stream")

  local function put(w: stream.Writer, data: string): number
    local n = assert(w:write(data))
    return n
  end

  local p = fd.pipe() as fd.Pipe
  print(put(p.writer, "ten bytes!"))
  p.writer:close()
  print(p.reader:read())
  p.reader:close()
  -- Output:
  -- 10
  -- ten bytes!
end

return {}
