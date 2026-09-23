--- Pull and push byte streams: the small abstraction `tar`, `zip` and
--- `archive` are built on, so they can walk an archive or a compressed
--- body in bounded memory, one chunk at a time, without caring whether
--- the bytes come from a string, a descriptor, or a decompressor.
---
--- A Reader's `read` returns a non-empty chunk of at most `max` bytes
--- (64 KiB when `max` is omitted), or nil and `""` at end of file, or
--- nil and an error. A Writer's `write` takes one chunk at a time.
--- Every constructor here also gives a `close`, even where closing does
--- nothing, so a caller never has to ask which kind it holds.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")

local record Stream
  record Reader
    read: function(Reader, max?: integer): string | nil, string
    close: function(Reader): boolean, string
  end

  record Writer
    write: function(Writer, string): boolean, string
    close: function(Writer): boolean, string
  end

  --- An in-memory Writer that also hands back everything written to it.
  record Collector
    write: function(Collector, string): boolean, string
    close: function(Collector): boolean, string
    result: function(Collector): string
  end

  --- The shape `cosmic.compress`'s incremental codecs take: an
  --- inflater, a deflater, or a decoder, each a stateful transform
  --- over chunks. A real `Compress.Stream` satisfies this shape; kept
  --- as its own record, rather than an alias for it, so a plain-table
  --- fake codec can still stand in for one in a test.
  record CodecStream
    update: function(CodecStream, string): string | nil, string
    finish: function(CodecStream): string | nil, string
    done: function(CodecStream): boolean
    rest: function(CodecStream): string
  end
end

local chunk_size = 1 << 16

--- A Reader over bytes already in memory.
function Stream.from_string(s: string): Stream.Reader
  local at = 1
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, max: integer): string | nil, string
    if at > #s then return nil, "" end
    local want = max or (#s - at + 1)
    if want <= 0 then return nil, "" end
    local stop = at + want - 1
    if stop > #s then stop = #s end
    local chunk = s:sub(at, stop)
    at = stop + 1
    return chunk, ""
  end
  r.close = function(_self: Stream.Reader): boolean, string
    return true, ""
  end
  return r
end

local function make_fd_reader(fd: integer, auto_close: boolean): Stream.Reader
  local closed = false
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, max: integer): string | nil, string
    if closed then return nil, "" end
    local data, trouble = Fs.take(fd, max or chunk_size)
    if data == nil then return nil, trouble end
    if #data == 0 then
      if auto_close then
        closed = true
        Fs.close(fd)
      end
      return nil, ""
    end
    return data, ""
  end
  r.close = function(_self: Stream.Reader): boolean, string
    if closed then return true, "" end
    closed = true
    return Fs.close(fd)
  end
  return r
end

--- A Reader over an already-open descriptor. The descriptor is not
--- closed at end of file; call `close` when done with it, or use
--- `Stream.open` for a Reader that owns the file it reads.
function Stream.from_fd(fd: integer): Stream.Reader
  return make_fd_reader(fd, false)
end

--- A Reader over a file at `path`, closed automatically at end of file
--- and safe to `close` early too.
function Stream.open(path: string): Stream.Reader | nil, string
  local fd, trouble = Fs.open_read(path)
  if fd == nil then return nil, trouble end
  return make_fd_reader(fd, true), ""
end

--- A Reader that pipes another Reader through an incremental codec:
--- `reader`'s chunks go through `codec:update`, and `codec:finish` is
--- called once, at `reader`'s end of file, for whatever the codec was
--- still holding.
function Stream.transform(reader: Stream.Reader, codec: Stream.CodecStream): Stream.Reader
  -- `pending` holds the codec's last batch of output, and `at` is how
  -- far into it this reader has already given out -- an offset rather
  -- than shrinking `pending` on every read, since a codec can hand
  -- back megabytes at once and a caller that reads in small pieces
  -- (a tar header at a time, say) would otherwise re-copy the whole
  -- remaining batch on every read.
  local pending = ""
  local at = 1
  local at_eof = false
  local finished = false
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, max: integer): string | nil, string
    while at > #pending and not finished do
      if at_eof then
        local out, trouble = codec:finish()
        finished = true
        if out == nil then return nil, trouble end
        pending, at = out, 1
      else
        local chunk, trouble = reader:read(chunk_size)
        if chunk == nil then
          if trouble ~= "" then return nil, trouble end
          at_eof = true
        else
          local out, ctrouble = codec:update(chunk)
          if out == nil then return nil, ctrouble end
          pending, at = out, 1
        end
      end
    end
    if at > #pending then return nil, "" end
    local want = max or chunk_size
    local avail = #pending - at + 1
    if want >= avail then
      local piece = at == 1 and pending or pending:sub(at)
      pending, at = "", 1
      return piece, ""
    end
    local piece = pending:sub(at, at + want - 1)
    at = at + want
    return piece, ""
  end
  r.close = function(_self: Stream.Reader): boolean, string
    return reader:close()
  end
  return r
end

--- A Reader that yields at most `n` bytes of `reader`, then ends,
--- however much `reader` still has. Closing it does not close `reader`,
--- since the usual reason for a limit is more of `reader` still to come.
function Stream.limit(reader: Stream.Reader, n: integer): Stream.Reader
  local left = n
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, max: integer): string | nil, string
    if left <= 0 then return nil, "" end
    local want = max or chunk_size
    if want > left then want = left end
    local chunk, trouble = reader:read(want)
    if chunk == nil then return nil, trouble end
    left = left - #chunk
    return chunk, ""
  end
  r.close = function(_self: Stream.Reader): boolean, string
    return true, ""
  end
  return r
end

--- Reads exactly `n` bytes, or nil and an error when the stream ends
--- first.
function Stream.read_exact(reader: Stream.Reader, n: integer): string | nil, string
  if n == 0 then return "", "" end
  local parts: {string} = {}
  local got = 0
  while got < n do
    local chunk, trouble = reader:read(n - got)
    if chunk == nil then
      if trouble ~= "" then return nil, trouble end
      return nil, "unexpected end of stream: wanted " .. tostring(n) ..
        " bytes, got " .. tostring(got)
    end
    parts[#parts + 1] = chunk
    got = got + #chunk
  end
  if #parts == 1 then return parts[1], "" end
  return table.concat(parts), ""
end

--- Reads a Reader to its end of file and returns everything as one
--- string. For bounded, whole-file cases; a streaming caller reads
--- `Reader.read` in a loop instead.
function Stream.read_all(reader: Stream.Reader): string | nil, string
  local parts: {string} = {}
  while true do
    local chunk, trouble = reader:read(chunk_size)
    if chunk == nil then
      if trouble ~= "" then return nil, trouble end
      return table.concat(parts), ""
    end
    parts[#parts + 1] = chunk
  end
end

--- A Writer over an already-open descriptor. The descriptor is not
--- closed by this Writer's `close`.
function Stream.to_fd(fd: integer): Stream.Writer
  local w: Stream.Writer = {}
  w.write = function(_self: Stream.Writer, data: string): boolean, string
    return Fs.put(fd, data)
  end
  w.close = function(_self: Stream.Writer): boolean, string
    return true, ""
  end
  return w
end

--- A Writer over a file at `path`: bytes go to a temporary neighbor,
--- which is renamed onto `path` only when `close` succeeds, so a
--- reader of `path` never sees a partial write. A write or close
--- failure leaves `path` untouched and removes the temporary file.
function Stream.create(path: string, mode?: integer): Stream.Writer | nil, string
  local opened, trouble = sys.open_temporary(path, mode or 0x1a4)
  if opened == nil then return nil, path .. ": " .. trouble end
  local temporary: sys.TemporaryFile = opened
  local failed: string
  local closed = false
  local w: Stream.Writer = {}
  w.write = function(_self: Stream.Writer, data: string): boolean, string
    if failed then return false, failed end
    local ok, why = Fs.put(temporary.fd, data)
    if not ok then failed = why end
    return ok, why
  end
  w.close = function(_self: Stream.Writer): boolean, string
    if closed then return true, "" end
    closed = true
    if failed then
      Fs.close(temporary.fd)
      sys.unlink(temporary.path)
      return false, temporary.path .. ": " .. failed
    end
    local ok, close_trouble = Fs.close(temporary.fd)
    if not ok then
      sys.unlink(temporary.path)
      return false, temporary.path .. ": " .. close_trouble
    end
    local moved, why = sys.rename(temporary.path, path)
    if not moved then
      sys.unlink(temporary.path)
      return false, path .. ": " .. why
    end
    return true, ""
  end
  return w, ""
end

--- A Writer that keeps everything written to it in memory, for a
--- caller building a small archive body it will hand elsewhere (a
--- request body, say) rather than write straight to a file.
function Stream.collect(): Stream.Collector
  local parts: {string} = {}
  local c: Stream.Collector = {}
  c.write = function(_self: Stream.Collector, data: string): boolean, string
    parts[#parts + 1] = data
    return true, ""
  end
  c.close = function(_self: Stream.Collector): boolean, string
    return true, ""
  end
  c.result = function(_self: Stream.Collector): string
    local whole = table.concat(parts)
    parts = { whole }
    return whole
  end
  return c
end

--- A Writer that pipes each chunk written to it through an incremental
--- codec before passing it to `writer`; `close` flushes the codec's
--- last bytes with `codec:finish` and then closes `writer`.
function Stream.transform_writer(writer: Stream.Writer, codec: Stream.CodecStream): Stream.Writer
  local w: Stream.Writer = {}
  w.write = function(_self: Stream.Writer, data: string): boolean, string
    local out, trouble = codec:update(data)
    if out == nil then return false, trouble end
    if #out > 0 then
      local ok, why = writer:write(out)
      if not ok then return false, why end
    end
    return true, ""
  end
  w.close = function(_self: Stream.Writer): boolean, string
    local out, trouble = codec:finish()
    if out == nil then return false, trouble end
    if #out > 0 then
      local ok, why = writer:write(out)
      if not ok then return false, why end
    end
    return writer:close()
  end
  return w
end

return Stream
