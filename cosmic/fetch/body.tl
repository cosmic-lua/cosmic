--- Internal helper for cosmic.fetch: the streaming Body reader.
--- Lives in its own file so fetch/init.tl stays under the 500-line
--- cap; init re-exports the Body type on its public record.
local cosmo = require("cosmo")
local stream_mod = require("cosmic.stream")

--- Streaming body reader for incremental access. Conforms to the
--- stream contract (cosmic.stream): read(n?) returns the next chunk
--- (at most n bytes when n is given), bare nil at end of stream, or
--- nil + error on failure.
local record Body is stream_mod.Reader
  metamethod __close: function(self: Body)
  read: function(self: Body, n?: integer): string | nil, string
  --- Read up to (and consuming) the next delim; stream.DelimReader.
  read_until: function(self: Body, delim: string): string | nil, string
  --- Close the reader; boolean, string like every stdlib close.
  close: function(self: Body): boolean, string
  closed: function(self: Body): boolean
  lines: function(self: Body): function(): string | nil, string
end

--- Create a Body wrapping a raw stream reader.
--- @param raw_reader cosmo.StreamReader The raw reader from FetchStream
--- @return Body wrapped reader with read(n?)/read_until/lines support
local function make_body(raw_reader: cosmo.StreamReader): Body
  local is_closed = false
  -- Bytes read(n) sliced off a transport chunk and did not return yet;
  -- always drained before the next transport read so order is kept.
  local carry: string = nil
  local body: Body = {}

  --- Read the next chunk from the stream, at most n bytes when n is
  --- given (the stream contract's size argument — stream.copy's
  --- buf_size arrives here). Chunk sizes are otherwise
  --- transport-determined.
  --- @param n integer? Maximum bytes to return
  --- @return string | nil chunk, or nil on EOF or failure
  --- @return string error message on failure (nil on clean EOF)
  function body:read(n?: integer): string | nil, string
    if is_closed then
      return nil, "reader closed"
    end
    local chunk: string
    if carry then
      chunk = carry
      carry = nil
    else
      local c, err = raw_reader:read()
      if err then
        return nil, err
      end
      if c == nil then
        return nil
      end
      chunk = c
    end
    if n and n > 0 and #chunk > n then
      carry = chunk:sub(n + 1)
      return chunk:sub(1, n)
    end
    return chunk
  end

  --- Read the bytes before the next occurrence of delim, consuming
  --- the delimiter (multi-byte allowed, never included in the result).
  --- Buffered in C by cosmo.StreamReader on the fast path; when a
  --- read(n) left a remainder the scan runs wrapper-side so bytes are
  --- never reordered and a delimiter straddling the remainder is still
  --- found. At end of stream an unterminated remainder is returned
  --- once, then bare nil.
  --- @param delim string non-empty delimiter to scan for
  --- @return string | nil bytes before the delimiter, or nil on EOF or failure
  --- @return string error message on failure (nil on clean EOF)
  function body:read_until(delim: string): string | nil, string
    if is_closed then
      return nil, "reader closed"
    end
    if delim == "" then
      -- The C binding rejects an empty delimiter by throwing; keep the
      -- library contract of nil + message instead.
      return nil, "read_until: delimiter must be non-empty"
    end
    if carry == nil then
      return raw_reader:read_until(delim)
    end
    -- Wrapper-side scan: accumulate transport chunks until the
    -- delimiter appears, so one straddling the carry boundary is found.
    local buffer = carry
    carry = nil
    while true do
      local idx = buffer:find(delim, 1, true)
      if idx then
        local before = buffer:sub(1, idx - 1)
        local rest = buffer:sub(idx + #delim)
        if rest ~= "" then
          carry = rest
        end
        return before
      end
      local c, err = raw_reader:read()
      if err then
        return nil, err
      end
      if c == nil then
        if buffer == "" then
          return nil
        end
        return buffer
      end
      buffer = buffer .. c
    end
  end

  --- Close the reader. Idempotent; cannot fail today.
  function body:close(): boolean, string
    if not is_closed then
      raw_reader:close()
      is_closed = true
    end
    return true
  end

  --- Returns true if the reader has been closed.
  --- @return boolean closed state
  function body:closed(): boolean
    return is_closed
  end

  --- Return an iterator that yields complete lines.
  --- Buffers partial lines across chunks until a newline is received.
  --- On clean EOF a final unterminated line is yielded, then nil. On a
  --- read error (reset, truncation, TLS failure) the iterator yields
  --- nil plus the error message once — the buffered partial line is
  --- truncated data and is discarded — then plain nil forever.
  --- The algorithm lives in cosmic.stream.lines; this delegates.
  --- @return function iterator yielding lines without trailing newline
  function body:lines(): function(): string | nil, string
    return stream_mod.lines(self)
  end

  return setmetatable(body, {
      __close = function(self: Body) local _ok, _err = self:close() end
    }) as Body -- cast: table seeded as record
end

local record BodyModule
  type Body = Body
  make_body: function(raw_reader: cosmo.StreamReader): Body
end

local M: BodyModule = {
  make_body = make_body,
}

return M
