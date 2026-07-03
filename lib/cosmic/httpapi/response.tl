--- HTTP response building and serialization.
--- Provides typed response records and helpers for common content types.
local json = require("cosmic.json")

--- HTTP response.
local record Response
  --- HTTP status code.
  status: number
  --- Response headers.
  headers: {string: string}
  --- Response body.
  body: string
end

local status_text: {number: string} = {
  [200] = "OK",
  [201] = "Created",
  [204] = "No Content",
  [301] = "Moved Permanently",
  [302] = "Found",
  [304] = "Not Modified",
  [400] = "Bad Request",
  [401] = "Unauthorized",
  [403] = "Forbidden",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [500] = "Internal Server Error",
}

--- Create a new response.
--- @param status number HTTP status code
--- @param body string Response body
--- @param headers {string:string} Optional headers
--- @return Response
local function new(status: number, body: string, headers?: {string: string}): Response
  return {
    status = status,
    body = body,
    headers = headers or {},
  }
end

--- Create a JSON response.
--- @param data any Value to JSON-encode
--- @param status number HTTP status code (default 200)
--- @return Response
local function json_response(data: any, status?: number): Response
  local encoded = json.encode(data)
  return {
    status = status or 200,
    body = encoded,
    headers = {["Content-Type"] = "application/json"},
  }
end

--- Create a plain text response.
--- @param body string Text body
--- @param status number HTTP status code (default 200)
--- @return Response
local function text(body: string, status?: number): Response
  return {
    status = status or 200,
    body = body,
    headers = {["Content-Type"] = "text/plain; charset=utf-8"},
  }
end

--- Create an HTML response.
--- @param body string HTML body
--- @param status number HTTP status code (default 200)
--- @return Response
local function html(body: string, status?: number): Response
  return {
    status = status or 200,
    body = body,
    headers = {["Content-Type"] = "text/html; charset=utf-8"},
  }
end

--- Create a redirect response.
--- @param url string Redirect target URL
--- @param status number HTTP status code (default 302)
--- @return Response
local function redirect(url: string, status?: number): Response
  return {
    status = status or 302,
    body = "",
    headers = {["Location"] = url},
  }
end

--- Serialize a response to HTTP/1.1 wire format.
--- @param resp Response The response to serialize
--- @return string Raw HTTP response bytes
local function serialize(resp: Response): string
  local reason = status_text[resp.status] or "Unknown"
  local parts: {string} = {}
  table.insert(parts, "HTTP/1.1 " .. tostring(resp.status) .. " " .. reason .. "\r\n")
  -- Set Content-Length if not already present
  if not resp.headers["Content-Length"] then
    table.insert(parts, "Content-Length: " .. tostring(#resp.body) .. "\r\n")
  end
  for k, v in pairs(resp.headers) do
    table.insert(parts, k .. ": " .. v .. "\r\n")
  end
  table.insert(parts, "\r\n")
  table.insert(parts, resp.body)
  return table.concat(parts)
end

return {
  Response = Response,
  new = new,
  json = json_response,
  text = text,
  html = html,
  redirect = redirect,
  serialize = serialize,
}
