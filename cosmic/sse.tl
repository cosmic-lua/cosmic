--- Server-Sent Events: parse a stream of them, format one for the wire.
--- parse() reads SSE from any stream.Reader (a fetch.Reader, an fd
--- Handle wrapping a socket, a child's stdout) and yields complete
--- events, following the WHATWG event stream processing model:
--- unterminated events at EOF are discarded, empty-data dispatches
--- reset the event type buffer, the last event ID updates as soon as
--- an `id:` line is seen, and `retry:` accepts only ASCII digits.
--- format() is the serializing half, so a cosmic program can serve SSE
--- without hand-writing the wire framing.

local stream = require("cosmic.stream")

--- A parsed SSE event.
local record Event
  data: string -- concatenated data: lines (required)
  event: string -- event type, defaults to "message"
  id: string -- last event ID
  retry_ms: integer -- reconnection time in milliseconds
end

--- An open SSE event stream.
local record EventStream
  --- Next parsed event: an Event, or bare nil on a graceful close. On
  --- a mid-stream transport failure it yields nil plus the error
  --- message once, then plain nil — so truncation is distinguishable
  --- from a graceful close. The positive branch narrows the yield
  --- (a guard before a break does not):
  ---   while true do
  ---     local ev = s:next()
  ---     if ev then handle(ev) else break end
  ---   end
  next: function(self: EventStream): Event | nil, string
  --- The last seen event ID (nil until an id: line is seen), for
  --- reconnecting with a Last-Event-ID request header. Updates as soon
  --- as an id: line is parsed, even when no event is dispatched.
  last_event_id: function(self: EventStream): string | nil
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

-- Line iteration is cosmic.stream.lines — the same buffered,
-- error-then-nil algorithm fetch.Reader:lines() delegates to.
local line_iter = stream.lines

--- Parse SSE events from a streaming reader.
--- Returns an EventStream whose :next() yields Event values (see the
--- record for the loop shape and the truncation-vs-close contract). A
--- partially accumulated event at end-of-stream is discarded per the
--- SSE spec, not dispatched. :last_event_id() exposes the id for
--- reconnects.
--- @param reader stream.Reader the reader to parse events from
--- @return EventStream the open event stream
local function parse(reader: stream.Reader): EventStream
  local current_data: {string} = {}
  local current_event: string = nil
  local current_retry_ms: integer = nil
  local last_id: string = nil
  local lines_iter = line_iter(reader)
  local done = false

  local function next_event(_self: EventStream): Event | nil, string
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
          current_retry_ms = nil
        else
          local ev: Event = {
            data = data,
            event = current_event or "message",
            id = last_id,
            retry_ms = current_retry_ms,
          }
          current_event = nil
          current_retry_ms = nil
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
              current_retry_ms = math.tointeger(tonumber(value))
            end
          end
          -- ignore unknown field names per spec
        end
        -- comments (name is nil) are silently ignored
      end
    end
  end

  local function last_event_id(_self: EventStream): string | nil
    return last_id
  end

  return {
    next = next_event,
    last_event_id = last_event_id,
  }
end

--- Serialize one Event to its wire form: `event:`/`id:`/`retry:`
--- fields when present, one `data:` line per newline-separated data
--- segment, and the dispatching blank line. The inverse of parse for a
--- dispatchable event (data ~= ""): parse(format(ev)) yields ev back.
--- Infallible.
--- @param ev Event the event to serialize
--- @return string the wire bytes, terminator included
local function format(ev: Event): string
  local out: {string} = {}
  if ev.event and ev.event ~= "message" then
    out[#out + 1] = "event: " .. ev.event
  end
  if ev.id then
    out[#out + 1] = "id: " .. ev.id
  end
  if ev.retry_ms then
    out[#out + 1] = "retry: " .. tostring(ev.retry_ms)
  end
  -- One data: line per segment; a lone trailing newline in data would
  -- otherwise be silently lost on the round trip.
  local data = ev.data or ""
  local pos = 1
  while true do
    local nl = data:find("\n", pos, true)
    if nl then
      out[#out + 1] = "data: " .. data:sub(pos, nl - 1)
      pos = nl + 1
    else
      out[#out + 1] = "data: " .. data:sub(pos)
      break
    end
  end
  out[#out + 1] = "\n"
  return table.concat(out, "\n")
end

local record SseModule
  type Event = Event
  type EventStream = EventStream
  parse: function(reader: stream.Reader): EventStream
  format: function(ev: Event): string
end

local M: SseModule = {
  parse = parse,
  format = format,
}

return M
