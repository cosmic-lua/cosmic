--- The stream contract: the byte-stream interfaces every producer and
--- consumer in the standard library composes over (api-review-2).
---
--- Reader is the one EOF convention: read() returns a non-empty chunk,
--- or bare nil (no error) at end of stream, or nil plus an error message
--- on failure. Reads after EOF keep returning bare nil. The optional
--- size argument is an upper bound, not a demand — implementations may
--- return fewer bytes — and must be positive when given.
---
--- Writer accepts a string and returns the number of bytes written
--- (which may be short) or nil plus an error message.
---
--- Conforming types: fd.Handle (Reader and Writer), net.Socket
--- (Reader and Writer — read/write alias recv/send), fetch.Reader
--- (Reader), child.Handle (Reader, over the child's stdout).
---
--- EINTR posture (the signal-safety wave; a pre-stable decision):
--- blocking calls on the ergonomic wrappers retry automatically
--- when a signal interrupts them — EINTR never surfaces from
--- fd.Handle read/write, socket send/recv/accept, child wait/read,
--- poll, or shm futex waits. Pending Lua signal handlers still run:
--- delivery is deferred to the VM, so each handler fires between an
--- interrupted call and its retry. To break out of a blocking call,
--- give it a deadline (socket set_timeout, poll's timeout, shm wait's
--- absolute deadline) or close the descriptor from the handler.
--- The deliberate exceptions, where the interruption IS the result:
--- time.sleep (returns the remainder plus an EINTR error),
--- signal.sigsuspend, socket connect (POSIX keeps connecting in the
--- background after EINTR, so a blind retry would misreport), and the
--- raw cosmic.proc/cosmo.unix passthroughs, which surface errnos
--- verbatim.
local record stream
  --- A source of bytes. read(n?) returns the next chunk (at most n
  --- bytes when n is given), bare nil at end of stream, or nil plus an
  --- error message on failure.
  interface Reader
    read: function(self: Reader, n?: number): string | nil, string
  end

  --- A sink for bytes. write(data) returns the number of bytes
  --- written (possibly short), or nil plus an error message.
  interface Writer
    write: function(self: Writer, data: string): number | nil, string
  end

  --- A Writer that accumulates in memory (the sink from_string is the
  --- source of): contents() returns everything written so far.
  record Buffer is Writer
    contents: function(self: Buffer): string
  end

  write_all: function(w: Writer, data: string): boolean, string
  read_all: function(r: Reader, max?: integer): string | nil, string
  copy: function(dst: Writer, src: Reader, buf_size?: integer): integer | nil, string
  lines: function(r: Reader): function(): string | nil, string
  from_string: function(data: string): Reader
  buffer: function(): Buffer
end

--- Write all of data, retrying short writes until done. The two
--- things every Writer caller wants — this and read_all — used to be
--- five independent hand-rolled loops across the stdlib.
--- Bytes written before a failure stay written.
--- @param w Writer The sink
--- @param data string The bytes to write
--- @return boolean True when everything was written
--- @return string? Error message on failure
function stream.write_all(w: stream.Writer, data: string): boolean, string
  local off = 0
  local len = #data
  while off < len do
    local n, err = w:write(off == 0 and data or data:sub(off + 1))
    if n == nil then
      return false, err or "write failed"
    end
    if n <= 0 then
      -- A zero-byte non-error write would loop forever; report it.
      return false, "write made no progress"
    end
    off = off + math.floor(n)
  end
  return true
end

--- Read to end of stream and return everything as one string.
--- @param r Reader The source
--- @param max integer? Cap on the result size; exceeding it is an error
---   (untrusted input must not balloon memory silently)
--- @return string | nil The bytes read, or nil on error
--- @return string? Error message on failure
function stream.read_all(r: stream.Reader, max?: integer): string | nil, string
  local parts: {string} = {}
  local total = 0
  while true do
    local chunk, err = r:read()
    if err then
      return nil, err
    end
    if chunk == nil then
      return table.concat(parts)
    end
    total = total + #chunk
    if max and total > max then
      return nil, "read_all: stream exceeds " .. tostring(max) .. " bytes"
    end
    parts[#parts + 1] = chunk
  end
end

--- Pump src into dst until src ends. Returns the byte count copied.
--- @param dst Writer The sink
--- @param src Reader The source
--- @param buf_size integer? Read bound per chunk (default: the reader's own)
--- @return integer | nil Bytes copied, or nil on error
--- @return string? Error message on failure
function stream.copy(dst: stream.Writer, src: stream.Reader, buf_size?: integer): integer | nil, string
  local copied = 0
  while true do
    local chunk, rerr = src:read(buf_size)
    if rerr then
      return nil, rerr
    end
    if chunk == nil then
      return copied
    end
    local ok, werr = stream.write_all(dst, chunk)
    if not ok then
      return nil, werr
    end
    copied = copied + #chunk
  end
end

--- Wrap bytes already in hand as a Reader, so in-memory data (a file
--- read whole, a decompressed buffer, a test fixture) feeds any stream
--- consumer — stream.lines, sse.events, stream.copy — without a
--- hand-rolled adapter. read(n?) returns successive chunks (at most n
--- bytes when n is given, the whole remainder otherwise), then bare
--- nil at end of stream, per the Reader contract; n must be positive
--- when given.
--- @param data string The bytes to serve
--- @return Reader A reader over the bytes
function stream.from_string(data: string): stream.Reader
  local pos = 1
  local reader = {
    read = function(_self: stream.Reader, n?: number): string | nil, string
      if pos > #data then
        return nil
      end
      local last = #data
      if n then
        if n <= 0 then
          return nil, "read: size must be positive"
        end
        last = math.min(last, pos + math.floor(n) - 1)
      end
      local chunk = data:sub(pos, last)
      pos = last + 1
      return chunk
    end,
  }
  return reader as stream.Reader -- cast: table implements the Reader interface
end

--- Collect writes in memory: the Writer half of from_string. write()
--- appends and reports the chunk fully written; contents() returns
--- everything written so far. Point stream.copy (or any Writer taker)
--- at one to materialize a pipeline's output as a string.
--- @return Buffer The in-memory writer
function stream.buffer(): stream.Buffer
  local parts: {string} = {}
  local buf = {
    write = function(_self: stream.Writer, data: string): number | nil, string
      parts[#parts + 1] = data
      return #data
    end,
    contents = function(_self: stream.Buffer): string
      return table.concat(parts)
    end,
  }
  return buf as stream.Buffer -- cast: table implements the Buffer record
end

--- Iterate complete lines from a Reader, buffering partial lines
--- across chunks. On clean EOF a final unterminated line is yielded
--- once, then nil. On a read error the buffered partial line is
--- truncated data and is discarded — the iterator yields nil plus the
--- error once, then plain nil forever. (Promoted from fetch.Reader's
--- lines(); cosmic.sse consumes the same iterator.)
--- @param r Reader The source
--- @return function Iterator yielding lines without the trailing newline
function stream.lines(r: stream.Reader): function(): string | nil, string
  -- Scan-position index into buffer: `pos` is the first unread byte.
  -- Advancing it instead of slicing off each returned line, and
  -- dropping the consumed prefix only when we must read more, keeps
  -- the whole loop linear in the byte count.
  local buffer = ""
  local pos = 1
  local done = false
  local pending_err: string = nil

  return function(): string | nil, string
    while true do
      local newline_pos = buffer:find("\n", pos, true)
      if newline_pos then
        local line = buffer:sub(pos, newline_pos - 1)
        pos = newline_pos + 1
        return line
      end

      if pending_err then
        local err = pending_err
        pending_err = nil
        done = true
        return nil, err
      end

      if done then
        -- Clean EOF with a final unterminated line still buffered:
        -- yield it once.
        if pos <= #buffer then
          local remaining = buffer:sub(pos)
          pos = #buffer + 1
          return remaining
        end
        return nil
      end

      -- No newline in the unread region; we need more data. Compact
      -- away the already-returned prefix first so the buffer stays
      -- bounded and the concat below copies only the unread tail.
      if pos > 1 then
        buffer = buffer:sub(pos)
        pos = 1
      end
      local chunk, err = r:read()
      if err then
        -- The buffered tail has no newline: it is truncated data, not
        -- a line. Drop it and surface the error on the next iteration.
        pending_err = err
        buffer = ""
        pos = 1
      elseif not chunk then
        done = true
      else
        buffer = buffer .. chunk
      end
    end
  end
end

return stream
