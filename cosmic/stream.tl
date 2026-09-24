--- Pull and push byte streams: the small abstraction `tar`, `zip` and
--- `archive` are built on, so they can walk an archive or a compressed
--- body in bounded memory, one chunk at a time, without caring whether
--- the bytes come from a string, a descriptor, or a decompressor.
---
--- A Reader's `read` returns a non-empty chunk of at most `max` bytes
--- -- or, when `max` is omitted, of whatever size suits that Reader
--- (the rest of a string, 64 KiB of a file) -- or nil and `""` at end
--- of file, or nil and an error. An error is sticky: every later
--- `read` returns the same error rather than a false end of file.
--- A Writer's `write` takes one chunk at a time; `close` commits what
--- was written, `abort` discards it where that means anything (a
--- `Stream.create` file is never renamed into place), and a `write`
--- after either fails. Every constructor here gives `close` (and each
--- Writer `abort`), even where it does nothing, and each is safe to
--- call more than once, so a caller never has to ask which kind it
--- holds.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Compress = require("cosmic.compress")
local sys = require("cosmic.sys")

local record Stream
  interface Reader
    read: function(Reader, max?: integer): string | nil, string
    close: function(Reader): boolean, string
    --- Present only on a Reader that can move forward without reading
    --- (one over a regular file): skips `n` bytes, failing when that
    --- would pass the end of the file. A caller checks for it and
    --- falls back to reading and discarding.
    skip: function(Reader, n: integer): boolean, string
  end

  interface Writer
    write: function(Writer, string): boolean, string
    close: function(Writer): boolean, string
    abort: function(Writer): boolean, string
  end

  --- An in-memory Writer that also hands back everything written to it.
  record Collector is Writer
    result: function(Collector): string
  end

  --- A Writer that digests everything written to it.
  record Hashing is Writer
    --- The raw digest of everything written so far, or nil and why
    --- the hasher could not finish; the Writer takes no more writes
    --- afterward, and asking again answers the same.
    digest: function(Hashing): string | nil, string
  end

  --- The incremental codec `transform` and `transform_writer` drive:
  --- one of `cosmic.compress`'s inflaters, deflaters or decoders.
  type Codec = Compress.Stream
end

local chunk_size = 1 << 16

local closed_message <const> = "stream: already closed"

--- A Reader over bytes already in memory.
function Stream.from_string(s: string): Stream.Reader
  local at = 1
  local closed = false
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, max: integer): string | nil, string
    if closed then return nil, closed_message end
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
    closed = true
    return true, ""
  end
  r.skip = function(_self: Stream.Reader, n: integer): boolean, string
    if closed then return false, closed_message end
    if at + n > #s + 1 then
      at = #s + 1
      return false, "stream: skip past the end of the data"
    end
    at = at + n
    return true, ""
  end
  return r
end

local function make_fd_reader(fd: integer, owned: boolean): Stream.Reader
  -- `ended` is a clean end of file (reads keep answering it); `closed`
  -- is an explicit close (reads fail); `failed` is a sticky error.
  local ended = false
  local closed = false
  local failed: string
  local released = false
  local function release(): boolean, string
    if released or not owned then return true, "" end
    released = true
    return Fs.close(fd)
  end
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, max: integer): string | nil, string
    if failed then return nil, failed end
    if closed then return nil, closed_message end
    if ended then return nil, "" end
    local data, trouble = Fs.take(fd, max or chunk_size)
    if data == nil then
      failed = trouble ~= "" and trouble or "stream: read failed"
      return nil, failed
    end
    if #data == 0 then
      ended = true
      local _, _ = release()
      return nil, ""
    end
    return data, ""
  end
  r.close = function(_self: Stream.Reader): boolean, string
    if closed then return true, "" end
    closed = true
    return release()
  end
  -- Only a regular file can seek; a pipe or socket reads and discards.
  local st, _ = sys.fstat(fd)
  if st ~= nil and st.kind == "file" then
    local size = st.size
    r.skip = function(_self: Stream.Reader, n: integer): boolean, string
      if failed then return false, failed end
      if closed then return false, closed_message end
      if n == 0 then return true, "" end
      if ended then
        failed = "stream: skip past the end of the file"
        return false, failed
      end
      local at, trouble = sys.lseek(fd, n, sys.SEEK_CUR)
      if at == nil then
        failed = trouble
        return false, failed
      end
      -- lseek happily moves past the end; the size says whether that
      -- skipped bytes the file never had. It is asked for again only
      -- when the one from opening says so, in case the file grew.
      if at > size then
        local now, _ = sys.fstat(fd)
        if now ~= nil then size = now.size end
        if at > size then
          failed = "stream: skip past the end of the file"
          return false, failed
        end
      end
      return true, ""
    end
  end
  return r
end

--- A Reader over an already-open descriptor. The descriptor is not
--- closed at end of file or by `close`; use `Stream.open` for a
--- Reader that owns the file it reads. Over a regular file the Reader
--- can `skip`.
function Stream.from_fd(fd: integer): Stream.Reader
  return make_fd_reader(fd, false)
end

--- A Reader over a file at `path`, which it closes at end of file or
--- at `close`, whichever comes first. Over a regular file it can
--- `skip`.
function Stream.open(path: string): Stream.Reader | nil, string
  local fd, trouble = Fs.open_read(path)
  if fd == nil then return nil, trouble end
  return make_fd_reader(fd, true), ""
end

--- A Reader that pipes another Reader through an incremental codec:
--- `reader`'s chunks go through `codec:update`, and `codec:finish` is
--- called once, at `reader`'s end of file, for whatever the codec was
--- still holding. A codec or `reader` error ends it, stickily.
function Stream.transform(reader: Stream.Reader, codec: Stream.Codec): Stream.Reader
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
  local failed: string
  local closed = false

  --- One step of the codec: its next batch of output (possibly ""), or
  --- nil and an error. A decoder hands back a bounded batch per call
  --- and says `pending` while it still holds input it has not
  --- expanded; that is drained with `update("")` before any more input
  --- goes in, so memory stays bounded however far the input expands.
  --- `finish` runs once, at the end of `reader`, when nothing is
  --- pending, and so returns only the codec's small tail.
  local function step(): string | nil, string
    if codec:pending() then return codec:update("") end
    if at_eof then
      finished = true
      return codec:finish()
    end
    local chunk, trouble = reader:read(chunk_size)
    if chunk == nil then
      if trouble ~= "" then return nil, trouble end
      at_eof = true
      return "", ""
    end
    return codec:update(chunk)
  end

  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, max: integer): string | nil, string
    if failed then return nil, failed end
    if closed then return nil, closed_message end
    while at > #pending and not finished do
      local out, trouble = step()
      if out == nil then
        failed = trouble ~= "" and trouble or "stream: codec failed"
        pending, at = "", 1
        return nil, failed
      end
      pending, at = out, 1
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
    if closed then return true, "" end
    closed = true
    pending, at = "", 1
    return reader:close()
  end
  return r
end

--- A Reader that yields at most `n` bytes of `reader`, then ends,
--- however much `reader` still has. Closing it does not close `reader`,
--- since the usual reason for a limit is more of `reader` still to come.
function Stream.limit(reader: Stream.Reader, n: integer): Stream.Reader
  local left = n
  local closed = false
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, max: integer): string | nil, string
    if closed then return nil, closed_message end
    if left <= 0 then return nil, "" end
    local want = max or chunk_size
    if want > left then want = left end
    local chunk, trouble = reader:read(want)
    if chunk == nil then return nil, trouble end
    left = left - #chunk
    return chunk, ""
  end
  r.close = function(_self: Stream.Reader): boolean, string
    closed = true
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

--- Moves `reader` forward `n` bytes: with its `skip` when it has one,
--- by reading and discarding otherwise. Fails when the stream ends
--- first.
function Stream.skip(reader: Stream.Reader, n: integer): boolean, string
  if n <= 0 then return true, "" end
  if reader.skip ~= nil then return reader:skip(n) end
  local left = n
  while left > 0 do
    local want = left
    if want > chunk_size then want = chunk_size end
    local chunk, trouble = reader:read(want)
    if chunk == nil then
      if trouble ~= "" then return false, trouble end
      return false, "unexpected end of stream: skipping " .. tostring(n) .. " bytes"
    end
    left = left - #chunk
  end
  return true, ""
end

--- Reads a Reader to its end of file and returns everything as one
--- string. For bounded, whole-file cases; a streaming caller reads
--- `Reader.read` in a loop instead, or `copy`s to a Writer.
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

--- Copies `reader` to `writer` until `reader`'s end of file, and
--- returns how many bytes went across. Closes neither side: on failure
--- the caller decides whether to `abort` `writer` or `close` it. To
--- cap a copy, copy `Stream.limit(reader, max + 1)` and compare the
--- count with `max`: a count is a caller's to read, a reason is not.
function Stream.copy(reader: Stream.Reader, writer: Stream.Writer): integer | nil, string
  local total = 0
  while true do
    local chunk, trouble = reader:read(chunk_size)
    if chunk == nil then
      if trouble ~= "" then return nil, trouble end
      return total, ""
    end
    total = total + #chunk
    local ok, wtrouble = writer:write(chunk)
    if not ok then return nil, wtrouble end
  end
end

--- A Writer over an already-open descriptor. The descriptor is not
--- closed by this Writer's `close`; `abort` cannot take back what
--- already reached it.
function Stream.to_fd(fd: integer): Stream.Writer
  local closed = false
  local w: Stream.Writer = {}
  w.write = function(_self: Stream.Writer, data: string): boolean, string
    if closed then return false, closed_message end
    return Fs.put(fd, data)
  end
  w.close = function(_self: Stream.Writer): boolean, string
    closed = true
    return true, ""
  end
  w.abort = w.close
  return w
end

--- The Writer `Stream.create` returns: its methods live on one shared
--- metatable, so creating a file costs a table, not three closures.
local record FileWriter is Stream.Writer
  path: string
  temporary: sys.TemporaryFile
  failed: string
  closed: boolean
end

local FileWriter_methods: {string:any} = {}
local file_writer_mt: metatable<FileWriter> = { __index = FileWriter_methods }

FileWriter_methods.write = function(self: FileWriter, data: string): boolean, string
  if self.closed then return false, closed_message end
  if self.failed then return false, self.failed end
  local ok, why = Fs.put(self.temporary.fd, data)
  if not ok then
    self.failed = why
    return false, why
  end
  return true, ""
end

FileWriter_methods.abort = function(self: FileWriter): boolean, string
  if self.closed then return true, "" end
  self.closed = true
  local _, _ = Fs.close(self.temporary.fd)
  local _, _ = sys.unlink(self.temporary.path)
  return true, ""
end

FileWriter_methods.close = function(self: FileWriter): boolean, string
  local temporary = self.temporary
  if self.closed then
    if self.failed then return false, temporary.path .. ": " .. self.failed end
    return true, ""
  end
  self.closed = true
  if self.failed then
    local _, _ = Fs.close(temporary.fd)
    local _, _ = sys.unlink(temporary.path)
    return false, temporary.path .. ": " .. self.failed
  end
  local ok, close_trouble = Fs.close(temporary.fd)
  if not ok then
    self.failed = close_trouble
    local _, _ = sys.unlink(temporary.path)
    return false, temporary.path .. ": " .. close_trouble
  end
  local moved, why = sys.rename(temporary.path, self.path)
  if not moved then
    self.failed = why
    local _, _ = sys.unlink(temporary.path)
    return false, self.path .. ": " .. why
  end
  return true, ""
end

--- A Writer over a file at `path`: bytes go to a temporary neighbor,
--- which is renamed onto `path` only when `close` succeeds, so a
--- reader of `path` never sees a partial write. A write or close
--- failure, or `abort`, leaves `path` untouched and removes the
--- temporary file.
function Stream.create(path: string, mode?: integer): Stream.Writer | nil, string
  local opened, trouble = sys.open_temporary(path, mode or 0x1a4)
  if opened == nil then return nil, path .. ": " .. trouble end
  local w: FileWriter = setmetatable({
    path = path, temporary = opened, closed = false,
  }, file_writer_mt)
  return w, ""
end

--- A Writer that keeps everything written to it in memory, for a
--- caller building a small archive body it will hand elsewhere (a
--- request body, say) rather than write straight to a file. `abort`
--- drops what it holds.
function Stream.collect(): Stream.Collector
  local parts: {string} = {}
  local closed = false
  local c: Stream.Collector = {}
  c.write = function(_self: Stream.Writer, data: string): boolean, string
    if closed then return false, closed_message end
    parts[#parts + 1] = data
    return true, ""
  end
  c.close = function(_self: Stream.Writer): boolean, string
    closed = true
    return true, ""
  end
  c.abort = function(_self: Stream.Writer): boolean, string
    closed = true
    parts = {}
    return true, ""
  end
  c.result = function(_self: Stream.Collector): string
    local whole = table.concat(parts)
    parts = { whole }
    return whole
  end
  return c
end

--- A Writer that digests what is written to it under `algorithm`,
--- for checking a body against a published digest as it streams past
--- -- `tee` it beside the Writer the body is really going to.
function Stream.hashing(algorithm: Hash.Algorithm): Stream.Hashing | nil, string
  local made, trouble = Hash.hasher(algorithm)
  if made == nil then return nil, trouble end
  local hasher: Hash.Hasher = made
  local result: string
  local failure = ""
  local closed = false
  local h: Stream.Hashing = {}
  h.write = function(_self: Stream.Writer, data: string): boolean, string
    if closed or result ~= nil then return false, closed_message end
    hasher:update(data)
    return true, ""
  end
  h.close = function(_self: Stream.Writer): boolean, string
    closed = true
    return true, ""
  end
  h.abort = h.close
  h.digest = function(_self: Stream.Hashing): string | nil, string
    if result == nil and failure == "" then
      closed = true
      local digest, digest_trouble = hasher:digest()
      if digest == nil then
        failure = digest_trouble
        return nil, failure
      end
      result = digest
    end
    if result == nil then return nil, failure end
    return result, ""
  end
  return h, ""
end

--- A Writer that passes every chunk to both `a` and `b`, in that
--- order; `close` and `abort` go to both too.
function Stream.tee(a: Stream.Writer, b: Stream.Writer): Stream.Writer
  local w: Stream.Writer = {}
  w.write = function(_self: Stream.Writer, data: string): boolean, string
    local ok, trouble = a:write(data)
    if not ok then return false, trouble end
    return b:write(data)
  end
  w.close = function(_self: Stream.Writer): boolean, string
    local ok, trouble = a:close()
    local ok2, trouble2 = b:close()
    if not ok then return false, trouble end
    if not ok2 then return false, trouble2 end
    return true, ""
  end
  w.abort = function(_self: Stream.Writer): boolean, string
    local _, _ = a:abort()
    local _, _ = b:abort()
    return true, ""
  end
  return w
end

--- A Writer that pipes each chunk written to it through an incremental
--- codec before passing it to `writer`; `close` flushes the codec's
--- last bytes with `codec:finish` and then closes `writer`, or aborts
--- `writer` when the codec or a write fails. `abort` aborts `writer`
--- without finishing the codec. A decoder's held output is drained
--- (`update("")` while `pending()`) after each write and before
--- `finish`, so each write to `writer` stays bounded however far the
--- input expands.
function Stream.transform_writer(writer: Stream.Writer, codec: Stream.Codec): Stream.Writer
  local closed = false
  local failed: string
  local w: Stream.Writer = {}
  --- Feeds `data` to the codec and writes its output on, then keeps
  --- draining while the codec says it is still holding output.
  local function feed(data: string): boolean, string
    while true do
      local out, trouble = codec:update(data)
      if out == nil then return false, trouble end
      if #out > 0 then
        local ok, why = writer:write(out)
        if not ok then return false, why end
      end
      if not codec:pending() then return true, "" end
      data = ""
    end
  end
  w.write = function(_self: Stream.Writer, data: string): boolean, string
    if closed then return false, closed_message end
    if failed then return false, failed end
    local ok, trouble = feed(data)
    if not ok then
      failed = trouble
      return false, trouble
    end
    return true, ""
  end
  w.abort = function(_self: Stream.Writer): boolean, string
    if closed then return true, "" end
    closed = true
    return writer:abort()
  end
  w.close = function(_self: Stream.Writer): boolean, string
    if closed then
      if failed then return false, failed end
      return true, ""
    end
    closed = true
    if not failed then
      local out, trouble = codec:finish()
      if out == nil then
        failed = trouble
      elseif #out > 0 then
        local ok, why = writer:write(out)
        if not ok then failed = why end
      end
    end
    if failed then
      local _, _ = writer:abort()
      return false, failed
    end
    local ok, why = writer:close()
    if not ok then
      failed = why
      return false, why
    end
    return true, ""
  end
  return w
end

return Stream
