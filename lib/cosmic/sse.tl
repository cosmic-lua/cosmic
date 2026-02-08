--- Server-Sent Events parser for streaming HTTP responses.
--- Parses SSE format from a fetch.Reader and yields complete events.

local fetch = require("cosmic.fetch")

--- A parsed SSE event.
local record Event
  data: string    -- concatenated data: lines (required)
  event: string   -- event type, defaults to "message"
  id: string      -- last event ID
  retry: number   -- reconnection time in milliseconds
end

--- Parse a single field line into name and value.
--- Returns nil for comment lines (starting with :).
--- @param line string the line to parse
--- @return string field name
--- @return string field value
local function parse_field(line: string): string, string
  if line:sub(1, 1) == ":" then
    return nil, nil  -- comment line
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

--- Parse SSE events from a streaming reader.
--- @param reader fetch.Reader the reader to parse events from
--- @return function iterator yielding Event or nil, error string
local function events(reader: fetch.Reader): function(): Event, string
  local current_data: {string} = {}
  local current_event: string = nil
  local current_id: string = nil
  local current_retry: number = nil
  local last_id: string = nil
  local lines_iter = reader:lines()
  local done = false

  return function(): Event, string
    if done then
      return nil
    end

    while true do
      local line = lines_iter()
      if not line then
        done = true
        -- stream ended: dispatch final event if we have pending data
        if #current_data > 0 then
          local ev: Event = {
            data = table.concat(current_data, "\n"),
            event = current_event or "message",
            id = current_id or last_id,
            retry = current_retry,
          }
          current_data = {}
          return ev
        end
        return nil
      end

      -- strip trailing CR if present (handles \r\n line endings)
      if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
      end

      if line == "" then
        -- blank line: dispatch event if we have data
        if #current_data > 0 then
          local ev: Event = {
            data = table.concat(current_data, "\n"),
            event = current_event or "message",
            id = current_id or last_id,
            retry = current_retry,
          }

          -- update last_id for subsequent events
          if current_id then
            last_id = current_id
          end

          -- reset accumulators for next event
          current_data = {}
          current_event = nil
          current_id = nil
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
            current_id = value
          elseif name == "retry" then
            local n = tonumber(value)
            if n then
              current_retry = n
            end
          end
          -- ignore unknown field names per spec
        end
        -- comments (name is nil) are silently ignored
      end
    end
  end
end

local record sse
  Event: Event
  events: function(reader: fetch.Reader): function(): Event, string
end

local M: sse = {
  events = events,
}

return M
