--- Server-Sent Events parser for streaming HTTP responses.
--- Parses SSE format from any stream.Reader (a fetch.Reader, an fd
--- Handle wrapping a socket, a child's stdout) and yields complete
--- events, following the WHATWG event stream processing model:
--- unterminated events at EOF are discarded, empty-data dispatches
--- reset the event type buffer, the last event ID updates as soon as
--- an `id:` line is seen, and `retry:` accepts only ASCII digits.

local stream = require("cosmic.stream")

--- A parsed SSE event.
local record Event
  data: string -- concatenated data: lines (required)
  event: string -- event type, defaults to "message"
  id: string -- last event ID
  retry: number -- reconnection time in milliseconds
end

--- An open SSE event stream.
local record Stream
  --- Iterator over parsed events: yields Event values; on a mid-stream
  --- transport failure yields nil plus the error message once, then
  --- plain nil — so truncation is distinguishable from a graceful close.
  next: function(): Event | nil, string
  --- The last seen event ID (nil until an id: line is seen), for
  --- reconnecting with a Last-Event-ID request header. Updates as soon
  --- as an id: line is parsed, even when no event is dispatched.
  last_event_id: function(): string
end

--- Parse a single field line into name and value.
--- Returns nil for comment lines (starting with :).
--- @param line string the line to parse
--- @return string field name
--- @return string field value
local function parse_field(line: string): string, string
  if line:sub(1, 1) == ":" then
    return nil, nil -- comment line
  end

  local colon = line:find(":")
  if not colon then
    -- field name only, no value
    return line, ""
  end

  local name = line:sub(1, colon - 1)
  local value = line:sub(colon + 1)

  -- strip single leading space if present
  if value:sub(1, 1) == " " then
    value = value:sub(2)
  end

  return name, value
end

--- Buffered line iterator over any stream.Reader, with the semantics of
--- fetch.Reader:lines(): complete lines without the trailing newline; on
--- clean EOF a final unterminated line is yielded once, then nil; on a
--- read error the buffered partial line is truncated data and is
--- discarded — the iterator yields nil plus the error once, then plain
--- nil forever. Private to sse until the post-stable buffered-reader
--- battery generalizes it.
local function line_iter(reader: stream.Reader): function(): string | nil, string
  -- Scan-position index into buffer: `pos` is the first unread byte
  -- (same linear-time scheme as fetch.Reader:lines()).
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
        if pos <= #buffer then
          local remaining = buffer:sub(pos)
          pos = #buffer + 1
          return remaining
        end
        return nil
      end

      if pos > 1 then
        buffer = buffer:sub(pos)
        pos = 1
      end
      local chunk, err = reader:read()
      if err then
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

--- Parse SSE events from a streaming reader.
--- Returns a Stream whose next() yields Event values (iterate with
--- `for ev in stream.next do`); when the underlying reader fails
--- mid-body (reset, truncation, TLS error) next() yields nil plus the
--- error message once, then nil — so a truncated stream is
--- distinguishable from a graceful close. A partially accumulated event
--- at end-of-stream is discarded per the SSE spec, not dispatched.
--- stream.last_event_id() exposes the id for reconnects.
--- @param reader stream.Reader the reader to parse events from
--- @return Stream the open event stream
local function events(reader: stream.Reader): Stream
  local current_data: {string} = {}
  local current_event: string = nil
  local current_retry: number = nil
  local last_id: string = nil
  local lines_iter = line_iter(reader)
  local done = false

  local function next_event(): Event | nil, string
    if done then
      return nil
    end

    while true do
      local line, read_err = lines_iter()
      if not line then
        done = true
        -- Stream ended. A pending unterminated event is discarded per
        -- spec: without its blank line it may be truncated mid-field.
        if read_err then
          return nil, read_err
        end
        return nil
      end

      -- strip trailing CR if present (handles \r\n line endings)
      if string.sub(line, -1) == "\r" then
        line = string.sub(line, 1, -2)
      end

      if line == "" then
        -- blank line: dispatch the accumulated event
        local data = table.concat(current_data, "\n")
        current_data = {}
        if data == "" then
          -- empty data buffer: reset the event type and retry too,
          -- dispatch nothing. Otherwise a retry: from this discarded
          -- block would leak into the next dispatched event.
          current_event = nil
          current_retry = nil
        else
          local ev: Event = {
            data = data,
            event = current_event or "message",
            id = last_id,
            retry = current_retry,
          }
          current_event = nil
          current_retry = nil
          return ev
        end
      else
        local name, value = parse_field(line)
        if name then
          if name == "data" then
            table.insert(current_data, value)
          elseif name == "event" then
            current_event = value
          elseif name == "id" then
            -- takes effect immediately, even if no event is dispatched;
            -- ids carrying a NUL are ignored per spec
            if not value:find("\0", 1, true) then
              last_id = value
            end
          elseif name == "retry" then
            -- digits-only per spec; anything else is ignored
            if value:match("^%d+$") then
              current_retry = tonumber(value)
            end
          end
          -- ignore unknown field names per spec
        end
        -- comments (name is nil) are silently ignored
      end
    end
  end

  local function last_event_id(): string
    return last_id
  end

  return {
    next = next_event,
    last_event_id = last_event_id,
  }
end

local record sse
  Event: Event
  Stream: Stream
  events: function(reader: stream.Reader): Stream
end

local M: sse = {
  events = events,
}

return M
