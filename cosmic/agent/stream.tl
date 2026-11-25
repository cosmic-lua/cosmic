--- @public
--- A streamed reply of the Messages API (`"stream": true`), read as
--- server-sent events and put back together as the message the API
--- sends without a stream: its content blocks whole, a tool call's
--- input decoded, the usage of its start and its end in one.
---
---     local message, why = Stream.message(read, function() first = Clock.now_ns() end)

local Json = require("cosmic.json")

local record Stream
  --- Reads the next bytes of the stream: nil and "" at its end, nil and
  --- why where it failed.
  type Read = function(): string?, string
end

--- A copy of `v`, an object, that may be changed; empty where `v` is none.
local function copy(v?: Json.Value): mut {string: Json.Value}
  local out: mut {string: Json.Value} = {}
  local from, _ = Json.to_object(v)
  for k, x in pairs(from or {}) do out[k] = x end
  return out
end

--- The message streamed by `read`, or nil and why. `delta` is told of
--- each piece of content as it comes, the first of them first.
function Stream.message(read: Stream.Read, delta?: function()): {string: Json.Value}?, string
  local message: mut {string: Json.Value} = {}
  local usage: mut {string: Json.Value} = {}
  local blocks: mut {integer: mut {string: Json.Value}} = {}
  local partial: mut {integer: string} = {}
  local last = -1
  local started, stopped = false, false
  local pending = ""

  --- Acts on one event's data: false and why where the stream says it failed.
  local function act(data: string): boolean, string
    local event, bad = Json.decode_object(data, { null_value = Json.null })
    if event == nil then return false, "a streamed event is not JSON: " .. tostring(bad) end
    local kind = event["type"]
    local at = event["index"]
    local index = if at is integer then at elseif at is number then math.tointeger(at) or -1 else -1 end
    if kind == "message_start" then
      message = copy(event["message"])
      for k, v in pairs(copy(message["usage"])) do
        if v ~= Json.null then usage[k] = v end
      end
      started = true
    elseif kind == "content_block_start" then
      blocks[index] = copy(event["content_block"])
      if index > last then last = index end
    elseif kind == "content_block_delta" then
      local block = blocks[index]
      if block == nil then return false, "a delta for a block not started: " .. tostring(index) end
      if delta ~= nil then delta() end
      for k, v in pairs(copy(event["delta"])) do
        if k == "partial_json" and v is string then
          partial[index] = (partial[index] or "") .. v
        elseif k ~= "type" and v is string then
          local had = block[k]
          block[k] = (if had is string then had else "" end) .. v
        elseif k == "citation" then
          local list, _ = Json.to_array(block["citations"])
          local more: mut {Json.Value} = {}
          for _, c in ipairs(list or {}) do more[#more + 1] = c end
          more[#more + 1] = v
          block["citations"] = Json.array(more)
        end
      end
    elseif kind == "content_block_stop" then
      local json = partial[index]
      local block = blocks[index]
      -- A call with no input streams none: the start's input stands.
      if json ~= nil and block ~= nil and not json:match("^%s*$") then
        local input, input_bad = Json.decode(json, { null_value = Json.null })
        if input == nil then
          return false, "a tool call's streamed input is not JSON: " .. tostring(input_bad)
        end
        block["input"] = input
        partial[index] = nil
      end
    elseif kind == "message_delta" then
      for k, v in pairs(copy(event["delta"])) do message[k] = v end
      -- Its counts are the whole so far; a null leaves the start's.
      for k, v in pairs(copy(event["usage"])) do
        if v ~= Json.null then usage[k] = v end
      end
    elseif kind == "message_stop" then
      stopped = true
    elseif kind == "error" then
      local e = copy(event["error"])
      local said = e["message"]
      local named = e["type"]
      return false, "the stream failed: " .. (if named is string then named .. ": " else "" end) ..
        (if said is string then said else data end)
    end
    return true, ""
  end

  --- Acts on each whole event in `pending`.
  local function events(): boolean, string
    while true do
      local cut, after = pending:find("\n\n", 1, true)
      if cut == nil then return true, "" end
      local block = pending:sub(1, cut - 1)
      pending = pending:sub(assert(after) + 1)
      local data: mut {string} = {}
      for line in (block .. "\n"):gmatch("([^\n]*)\n") do
        local value = line:match("^data: ?(.*)$")
        if value ~= nil then data[#data + 1] = value end
      end
      if #data > 0 then
        local ok, why = act(table.concat(data, "\n"))
        if not ok then return false, why end
      end
    end
  end

  while not stopped do
    local chunk, why = read()
    if chunk == nil then
      if why ~= "" then return nil, why end
      break
    end
    -- Line ends as one: a CR held back at the end may yet begin a CRLF.
    pending = pending .. chunk
    local held = pending:sub(-1) == "\r"
    if held then pending = pending:sub(1, -2) end
    pending = pending:gsub("\r\n", "\n"):gsub("\r", "\n")
    if held then pending = pending .. "\r" end
    local ok, events_why = events()
    if not ok then return nil, events_why end
  end
  -- An event the stream ended without its blank line after.
  if not stopped and pending:match("^%s*$") == nil then
    -- One cut short says nothing more than that the stream was.
    pending = pending:gsub("\r$", "") .. "\n\n"
    local _, _ = events()
  end
  if not started then return nil, "the stream ended before its message began" end
  if not stopped then return nil, "the stream ended before its message did" end
  local content: mut {Json.Value} = {}
  for i = 0, last do
    local block = blocks[i]
    if block ~= nil then content[#content + 1] = block end
  end
  message["content"] = Json.array(content)
  message["usage"] = usage
  return message, ""
end

return Stream
