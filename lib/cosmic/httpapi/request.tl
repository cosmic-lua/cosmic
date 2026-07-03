--- HTTP request parsing.
--- Parses raw HTTP/1.1 request bytes into a typed Request record.
local url = require("cosmic.url")

--- Parsed HTTP request.
local record Request
  --- HTTP method (GET, POST, etc.).
  method: string
  --- URL path without query string.
  path: string
  --- Raw query string (without leading ?).
  query: string
  --- Parsed query parameters.
  query_params: {string: string}
  --- HTTP headers (lowercase keys).
  headers: {string: string}
  --- Request body (from Content-Length).
  body: string
  --- Path parameters populated by the router.
  params: {string: string}
  --- Full request target as received (path + query).
  raw_path: string
end

--- Parse a raw HTTP/1.1 request string into a Request.
--- Expects at minimum a complete request line and headers (terminated by \r\n\r\n).
--- If Content-Length is present and body data follows the headers, it is captured.
--- @param raw string Raw HTTP request bytes
--- @return Request Parsed request, or nil on error
--- @return string Error message on failure
local function parse(raw: string): Request, string
  if raw == "" then
    return nil, "empty request"
  end
  -- Find end of headers
  local header_end = raw:find("\r\n\r\n", 1, true)
  if not header_end then
    return nil, "incomplete request: no header terminator"
  end
  -- Parse request line
  local line_end = raw:find("\r\n", 1, true)
  if not line_end then
    return nil, "no request line"
  end
  local request_line = raw:sub(1, line_end - 1)
  local method, target, version = request_line:match("^(%S+)%s+(%S+)%s+(%S+)$")
  if not method or not target or not version then
    return nil, "invalid request line: " .. request_line
  end
  -- Parse path and query from target
  local path: string
  local query: string
  local qpos = target:find("?", 1, true)
  if qpos then
    path = target:sub(1, qpos - 1)
    query = target:sub(qpos + 1)
  else
    path = target
    query = ""
  end
  -- Parse query params
  local query_params: {string: string} = {}
  if query ~= "" then
    query_params = url.parse(query)
  end
  -- Parse headers
  local headers: {string: string} = {}
  local header_block = raw:sub(line_end + 2, header_end - 1)
  for line in header_block:gmatch("([^\r\n]+)") do
    local name, value = line:match("^([^:]+):%s*(.+)$")
    if name then
      headers[name:lower()] = value
    end
  end
  -- Parse body if Content-Length present
  local body = ""
  local content_length_str = headers["content-length"]
  if content_length_str then
    local content_length = tonumber(content_length_str)
    if content_length and content_length > 0 then
      local body_start = header_end + 4
      body = raw:sub(body_start, body_start + (content_length as integer) - 1)
    end
  end
  local _ = version
  return {
    method = method,
    path = path,
    query = query,
    query_params = query_params,
    headers = headers,
    body = body,
    params = {},
    raw_path = target,
  }
end

return {
  Request = Request,
  parse = parse,
}
