--- Structured per-file test outcomes and their sidecar grammar.
---
--- `.got` remains the build graph's numeric compatibility record. The
--- adjacent `.result` sidecar preserves distinctions an exit code cannot:
--- product failure, declared capability absence, and timeout.

local enum Status
  "pass"
  "fail"
  "skip"
  "unavailable"
  "timeout"
end

local record Result
  status: Status
  fatal: boolean
  detail: string
  timeout_ms: integer
  cleanup_error: string
end

local VALID < const >: {string: boolean} = {
  pass = true,
  fail = true,
  skip = true,
  unavailable = true,
  timeout = true,
}

local function clean(value: string): string
  local cleaned = (value or ""):gsub("[\r\n\t]", " ")
  return cleaned
end

--- Encode one result for `<output>.result`.
--- @param result Result The structured outcome
--- @return string Versioned line-oriented bytes
local function encode(result: Result): string
  return table.concat({
      "testrun-result 1",
      "status " .. result.status,
      "fatal " .. (result.fatal and "1" or "0"),
      "timeout_ms " .. tostring(result.timeout_ms or 0),
      "detail " .. clean(result.detail),
      "cleanup_error " .. clean(result.cleanup_error),
      "",
    }, "\n")
end

--- Decode a `.result` sidecar, refusing missing, duplicate, or unknown fields.
--- @param content string Sidecar bytes
--- @return Result|nil The result, or nil for malformed bytes
--- @return string Error explaining malformed bytes
local function decode(content: string): Result | nil, string
  local lines: {string} = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  if lines[1] ~= "testrun-result 1" then
    return nil, "missing testrun-result 1 header"
  end
  local fields: {string: string} = {}
  for i = 2, #lines do
    local line = lines[i]
    if line ~= "" then
      local key, value = line:match("^(%S+) (.*)$")
      if not key then return nil, "malformed line " .. tostring(i) end
      if fields[key] ~= nil then return nil, "duplicate field " .. key end
      fields[key] = value
    end
  end
  for _, key in ipairs({"status", "fatal", "timeout_ms", "detail",
      "cleanup_error"}) do
    if fields[key] == nil then return nil, "missing field " .. key end
  end
  for key in pairs(fields) do
    if key ~= "status" and key ~= "fatal" and key ~= "timeout_ms"
    and key ~= "detail" and key ~= "cleanup_error" then
      return nil, "unknown field " .. key
    end
  end
  if not VALID[fields.status] then
    return nil, "unknown status " .. fields.status
  end
  if fields.fatal ~= "0" and fields.fatal ~= "1" then
    return nil, "fatal must be 0 or 1"
  end
  local timeout_number = tonumber(fields.timeout_ms)
  if not timeout_number then
    return nil, "timeout_ms must be a non-negative integer"
  end
  local timeout_ms = math.tointeger(timeout_number)
  if not timeout_ms or timeout_ms < 0 then
    return nil, "timeout_ms must be a non-negative integer"
  end
  return {
    status = fields.status as Status, -- cast: validated against the closed enum
    fatal = fields.fatal == "1",
    timeout_ms = timeout_ms,
    detail = fields.detail,
    cleanup_error = fields.cleanup_error,
  }
end

local record ResultModule
  type Status = Status
  type Result = Result
  encode: function(result: Result): string
  decode: function(content: string): Result | nil, string
end

local M: ResultModule = {
  encode = encode,
  decode = decode,
}

return M
