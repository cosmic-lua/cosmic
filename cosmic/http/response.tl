--- The response half of cosmic.http: the Response a handler writes to.
--- A handler sets `status`, adds headers, and calls exactly one of the
--- send verbs; the head is assembled at that moment, so `Date`,
--- `Content-Length` and `Connection` are always the server's to compute
--- and never a handler's to get wrong.
---
--- `html` is the typed verb: it takes `cosmic.html.SafeHtml`, so a raw
--- `string` is a compile error rather than an injection, which is how
--- `cosmic.template`'s escaping guarantee reaches the wire.
---
--- The connection loop needs two answers about a response the handler
--- had — did it send anything, and may the connection be reused — that
--- a handler has no business setting. Those live on the Exchange this
--- module returns, beside the Response rather than on it.

local cosmo = require("cosmo")
local html_mod = require("cosmic.html")
local json_mod = require("cosmic.json")
local net = require("cosmic.net")
local time = require("cosmic.time")

--- Headers the server computes; a handler that sets one of these by
--- hand is overridden, because only the server knows the framing.
local COMPUTED: {string: boolean} = {
  ["date"] = true,
  ["content-length"] = true,
  ["connection"] = true,
}

--- One HTTP/1.1 response, as a handler writes it.
local record Response
  --- The status code the next send writes. 200 until set otherwise.
  status: integer
  --- Set a header, replacing every value a previous set or add gave it.
  --- @param name string The header name, written as it should appear
  --- @param value string The header value
  set_header: function(self: Response, name: string, value: string)
  --- Append a header value, keeping the ones already there.
  --- @param name string The header name, written as it should appear
  --- @param value string The header value
  add_header: function(self: Response, name: string, value: string)
  --- Send the head and body as one write, finishing the response.
  --- A second send on the same response fails rather than writing a
  --- second head onto the connection.
  --- @param body string The response body; "" for no body
  --- @return boolean True when the whole response reached the socket
  --- @return string Error message on failure
  send: function(self: Response, body: string): boolean, string
  --- Send a `text/plain; charset=utf-8` body.
  --- @param s string The body text
  --- @return boolean True when the whole response reached the socket
  --- @return string Error message on failure
  text: function(self: Response, s: string): boolean, string
  --- Send a `text/html; charset=utf-8` body. The argument is SafeHtml,
  --- not a string: escaping is proved by the type, at compile time.
  --- @param h html_mod.SafeHtml The escaped or explicitly trusted markup
  --- @return boolean True when the whole response reached the socket
  --- @return string Error message on failure
  html: function(self: Response, h: html_mod.SafeHtml): boolean, string
  --- Send an `application/json` body, encoded with cosmic.json.
  --- A value the encoder refuses fails here and sends nothing.
  --- @param v any The value to encode
  --- @return boolean True when the whole response reached the socket
  --- @return string Error message on failure
  json: function(self: Response, v: any): boolean, string
  --- Send a redirect: a Location header and an empty body.
  --- @param location string The URL to redirect to
  --- @param status integer? The status code (default 303)
  --- @return boolean True when the whole response reached the socket
  --- @return string Error message on failure
  redirect: function(self: Response, location: string, status?: integer): boolean, string
end

--- One request/response exchange: the Response a handler writes, plus
--- the two questions only the connection loop asks about it.
local record Exchange
  --- The Response handed to the handler.
  response: Response
  --- Whether the handler has sent a response yet.
  --- @return boolean True once a send verb wrote a head
  is_finished: function(self: Exchange): boolean
  --- Whether the connection must close after this response.
  --- @return boolean True when the answer carried `Connection: close`
  will_close: function(self: Exchange): boolean
end

--- Create a response for one exchange on a connection.
--- `close_requested` is the request's half of the keep-alive decision —
--- an HTTP/1.0 request that did not ask for keep-alive, or any request
--- that sent `Connection: close`. A handler can only add to it, by
--- setting `Connection: close` itself; it can never talk the server back
--- into reusing a connection the client is done with.
--- @param conn net.Socket The connection to write the response to
--- @param close_requested boolean Whether the request ruled out reuse
--- @return Exchange The response and the loop's view of it
local function new(conn: net.Socket, close_requested: boolean): Exchange
  -- Header state is three parallel pieces: the lowercase names in
  -- insertion order, the spelling each was written with, and the values.
  -- Lowercase is the identity (HTTP header names are case-insensitive,
  -- so a set must replace a differently-spelled earlier one); the
  -- spelling is kept only so the wire reads the way the handler wrote it.
  local order: {string} = {}
  local spelling: {string: string} = {}
  local values: {string: {string}} = {}
  local finished = false
  local must_close = close_requested

  local res: Response = {status = 200}

  local function remember(name: string): string
    local key = name:lower()
    if values[key] == nil then
      order[#order + 1] = key
      values[key] = {}
    end
    spelling[key] = name
    return key
  end

  local function note_close(key: string, value: string)
    if key == "connection" and value:lower():find("close", 1, true) then
      must_close = true
    end
  end

  function res:set_header(name: string, value: string)
    local key = remember(name)
    values[key] = {value}
    note_close(key, value)
  end

  function res:add_header(name: string, value: string)
    local key = remember(name)
    table.insert(values[key], value)
    note_close(key, value)
  end

  function res:send(body: string): boolean, string
    if finished then
      return false, "http: response already sent"
    end
    finished = true
    local status = self.status or 200
    local out: {string} = {
      "HTTP/1.1 " .. status .. " " .. cosmo.GetHttpReason(status) .. "\r\n",
      "Date: " .. time.format_http(os.time()) .. "\r\n",
    }
    for _, key in ipairs(order) do
      if not COMPUTED[key] then
        for _, value in ipairs(values[key]) do
          out[#out + 1] = spelling[key] .. ": " .. value .. "\r\n"
        end
      end
    end
    out[#out + 1] = "Content-Length: " .. #body .. "\r\n"
    out[#out + 1] = "Connection: " .. (must_close and "close" or "keep-alive") .. "\r\n"
    out[#out + 1] = "\r\n"
    out[#out + 1] = body
    -- One write for head and body: two would let a client see a
    -- complete head with no payload behind it on a slow link.
    return conn:send_all(table.concat(out))
  end

  function res:text(s: string): boolean, string
    self:set_header("Content-Type", "text/plain; charset=utf-8")
    return self:send(s)
  end

  function res:html(h: html_mod.SafeHtml): boolean, string
    self:set_header("Content-Type", "text/html; charset=utf-8")
    return self:send(h.raw)
  end

  function res:json(v: any): boolean, string
    local encoded, err = json_mod.encode(v)
    if encoded == nil then
      return false, err
    end
    self:set_header("Content-Type", "application/json")
    return self:send(encoded)
  end

  function res:redirect(location: string, status?: integer): boolean, string
    self.status = status or 303
    self:set_header("Location", location)
    return self:send("")
  end

  local ex: Exchange = {response = res}

  function ex:is_finished(): boolean
    return finished
  end

  function ex:will_close(): boolean
    return must_close
  end

  return ex
end

local record HttpResponseModule
  type Response = Response
  type Exchange = Exchange
  new: function(conn: net.Socket, close_requested: boolean): Exchange
end

local M: HttpResponseModule = {
  new = new,
}

return M
