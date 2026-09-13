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

--- Receives more bytes from a connection, or nil at end of stream.
local type Receiver = function(): (string | nil, string)

--- A `Transfer-Encoding: chunked` body, decoded.
local record Chunked
  --- The decoded payload; "" when the read stopped at the bound.
  body: string
  --- Bytes received past the terminating chunk. They are the next
  --- request's head on a keep-alive connection, so the loop keeps them.
  carry: string
  --- True when the decoded payload grew past the caller's bound and the
  --- read stopped. The body is not here to answer with; the server's
  --- answer is 413.
  oversize: boolean
end

--- Decode one chunked request body off the connection.
--- The decoder is `cosmo.http.unchunker`, which owns every byte fed to
--- it and reports, once the terminating chunk arrives, how many of
--- those raw bytes the body occupied. Everything past that count is the
--- carry-over, and it can only be in the last feed: a decoder that is
--- not done has consumed all of its input as framing.
---
--- The bound is on the DECODED payload, which is the size a handler
--- would see. A chunked body also carries framing the payload bound
--- says nothing about — a stream of one-byte chunks is mostly chunk
--- headers — so the raw byte count fed to the decoder is bounded too,
--- but only on a feed that does not finish the body: the check runs
--- each time round the loop, before the next `recv`, so a body whose
--- framing overhead crosses the bound while still arriving is caught
--- there. This holds the decoder's memory to roughly twice the bound
--- while a body is arriving gradually; it is not a guarantee that every
--- oversized-framing body is refused regardless of how the client sends
--- it — one whose bytes, terminating chunk included, land in a single
--- feed is decided by the decoded-payload check alone, since the raw
--- count is never re-examined once `consumed` comes back nonzero.
--- Neither check can fire while the raw count is still under the
--- bound, so the body — a buffer copy — is only asked for after it
--- passes.
--- @param recv Receiver Reads more bytes from the connection
--- @param initial string Bytes already received past the head
--- @param max_bytes integer The largest decoded body to accept
--- @return Chunked | nil The decoded body, or nil when the read failed
--- @return string Error message on failure
local function read_chunked(recv: Receiver, initial: string,
    max_bytes: integer): Chunked | nil, string
  local decoder = http.unchunker()
  local pending = initial
  local fed = 0
  local too_big: Chunked = {body = "", carry = "", oversize = true}
  while true do
    local consumed, ferr = decoder:feed(pending)
    if consumed == nil then
      return nil, "http: " .. (ferr or "malformed chunked body")
    end
    fed = fed + #pending
    if consumed > 0 then
      -- A whole body can arrive in one feed, so the bound is checked
      -- here too and not only on the way round the loop.
      local payload = decoder:body()
      if #payload > max_bytes then
        return too_big
      end
      return {
        body = payload,
        carry = pending:sub(#pending - (fed - consumed) + 1),
        oversize = false,
      }
    end
    if fed > max_bytes then
      local seen = #decoder:body()
      if seen > max_bytes or fed - seen > max_bytes then
        return too_big
      end
    end
    local chunk, rerr = recv()
    if chunk == nil or #chunk == 0 then
      return nil, rerr or "http: connection closed before the chunked body ended"
    end
    pending = chunk
  end
end

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
  --- The request body: exactly the bytes `Content-Length` declared, or
  --- the payload decoded from a `Transfer-Encoding: chunked` request.
  --- A request that framed no body has an empty body, not a missing
  --- one, so this returns "". The read happens once and is
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
  type Receiver = Receiver
  type Chunked = Chunked
  new: function(message: http.Message, peer: ip.Addr,
  read_body: BodyReader): Request | nil, string
  read_chunked: function(recv: Receiver, initial: string,
  max_bytes: integer): Chunked | nil, string
end

local M: HttpRequestModule = {
  new = new,
  read_chunked = read_chunked,
}

return M
