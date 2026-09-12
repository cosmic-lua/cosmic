--- The request half of cosmic.http: one parsed HTTP/1.1 request head.
--- The head arrives as a `cosmo.http` Message — method, target, version
--- and the raw header table — and this module turns it into the record a
--- handler reads: lowercase header views, a decoded path and query, and
--- a body the handler asks for rather than one the server always read.
---
--- The header views are the same two `cosmic.fetch` builds for a
--- response, through the same `cosmic.fetch.headers.normalize`: the
--- parser emits `cosmo.Fetch`'s shape by design, so there is one
--- normalizer for both directions and no second copy to drift.

local http = require("cosmo.http")
local fetch_headers = require("cosmic.fetch.headers")
local ip = require("cosmic.ip")
local url = require("cosmic.url")

--- Reads the declared request body off the connection, once.
--- The connection loop owns this closure because it also owns the
--- receive buffer: bytes that arrived after the body belong to the next
--- request on a keep-alive connection, and only the loop can keep them.
local type BodyReader = function(): (string | nil, string)

--- One HTTP/1.1 request, as a handler sees it.
local record Request
  --- Request method, uppercased: "GET", "POST".
  method: string
  --- The request-target exactly as it arrived, still percent-encoded.
  target: string
  --- The target's path, percent-decoded; "/" when the target has none.
  path: string
  --- The target's query: every key with all its values, in order.
  query: {string: {string}}
  --- Protocol version as a two-digit integer: 9, 10 or 11.
  version: integer
  --- Header values by lowercase name, repeats joined ", ".
  headers: {string: string}
  --- Header values by lowercase name, every value in arrival order.
  raw_headers: {string: {string}}
  --- The client's address.
  peer: ip.Addr
  --- Look up one header by name, case-insensitively.
  --- @param name string The header name, in any case
  --- @return string | nil The value, repeats joined ", "; nil when absent
  header: function(self: Request, name: string): string | nil
  --- The request body: exactly the bytes `Content-Length` declared.
  --- A request with no `Content-Length` has an empty body, not a
  --- missing one, so this returns "". The read happens once and is
  --- memoized, which is also why a handler that ignores the body costs
  --- nothing; the server drains it afterwards so the next request on a
  --- keep-alive connection starts where it should.
  --- @return string | nil The body bytes, or nil when the read failed
  --- @return string Error message on failure
  body: function(self: Request): string | nil, string
end

--- Build a Request from a parsed head.
--- A target `cosmic.url` refuses is the one failure here: the server
--- answers it with 400 before any handler runs, which is why this
--- returns nil rather than a Request carrying an empty path.
--- @param message http.Message The head a completed parse cut out
--- @param peer ip.Addr The client's address
--- @param read_body BodyReader Reads the declared body off the connection
--- @return Request | nil The request, or nil when the target is unparseable
--- @return string Error message on failure
local function new(message: http.Message, peer: ip.Addr,
    read_body: BodyReader): Request | nil, string
  local parsed, perr = url.parse(message.uri)
  if not parsed then
    return nil, perr
  end
  local target = parsed
  local headers, raw_headers = fetch_headers.normalize(message.headers)
  local req: Request = {
    method = message.method,
    target = message.uri,
    path = target.path ~= "" and target.path or "/",
    query = url.parse_query(target.query or ""),
    version = message.version,
    headers = headers,
    raw_headers = raw_headers,
    peer = peer,
  }

  function req:header(name: string): string | nil
    return self.headers[name:lower()]
  end

  -- The memo is two slots rather than one so a failed read stays failed:
  -- re-reading a body the connection already lost would hand the handler
  -- the NEXT request's bytes.
  local body_bytes: string = nil
  local body_err: string = nil

  function req:body(): string | nil, string
    if body_bytes ~= nil then
      return body_bytes
    end
    if body_err ~= nil then
      return nil, body_err
    end
    local data, derr = read_body()
    if data == nil then
      body_err = derr or "http: request body could not be read"
      return nil, body_err
    end
    body_bytes = data
    return body_bytes
  end

  return req
end

local record HttpRequestModule
  type Request = Request
  type BodyReader = BodyReader
  new: function(message: http.Message, peer: ip.Addr,
  read_body: BodyReader): Request | nil, string
end

local M: HttpRequestModule = {
  new = new,
}

return M
