--- The response half of cosmic.http: the Response a handler writes to.
--- A handler sets `status`, adds headers, and calls exactly one of the
--- send verbs; the head is assembled at that moment, so `Date`,
--- `Content-Length`, `Transfer-Encoding` and `Connection` are always the
--- server's to compute and never a handler's to get wrong.
---
--- A response is written one of two ways, and the choice is made by the
--- first verb called. `send` and its typed wrappers write head and body
--- as one write, with a `Content-Length` the server counted. `start`,
--- `write` and `finish` stream: the head goes out first, then each
--- chunk as the handler produces it, which is what an SSE endpoint or
--- any long-lived push needs. The two are exclusive — `send` after
--- `start` writes nothing and fails — because a response has exactly
--- one framing and mixing them is what a client reads as the next
--- response starting early.
---
--- `html` is the typed verb: it takes `cosmic.html.SafeHtml`, so a raw
--- `string` is a compile error rather than an injection, which is how
--- `cosmic.template`'s escaping guarantee reaches the wire.
---
--- A header name or value carrying a CR, LF or NUL would end the header
--- line early and let whatever follows be read as further headers, or as
--- the body — response splitting, from any handler that echoes client
--- input into a header or a redirect target. Such a header is REFUSED,
--- never stripped: stripping hides the handler's bug and a value ending
--- in a bare CR still splices against the writer's own CRLF. The refusal
--- is remembered and every send verb then fails with it, so a response
--- with one bad header puts no bytes at all on the wire.
---
--- The connection loop needs three answers about a response the handler
--- had — did it send anything, may the connection be reused, and was a
--- header refused — that a handler has no business setting. Those live
--- on the Exchange this module returns, beside the Response rather than
--- on it.

local cosmo = require("cosmo")
local html_mod = require("cosmic.html")
local json_mod = require("cosmic.json")
local net = require("cosmic.net")
local sse = require("cosmic.sse")
local time = require("cosmic.time")

--- Headers the server computes; a handler that sets one of these by
--- hand is dropped from the head, because only the server knows the
--- framing. `transfer-encoding` is here for the same reason the other
--- three are: a handler that declared `chunked` on a `send` response
--- would put it on the wire beside the `Content-Length` the server
--- counted, and RFC 9112 §6.1 leaves a recipient reading two framings
--- free to pick either one — the request-smuggling shape, written from
--- the server's end. A response that really is chunked gets the header
--- from `start`, which is the only place that also writes the framing
--- to match it.
local COMPUTED: {string: boolean} = {
  ["date"] = true,
  ["content-length"] = true,
  ["connection"] = true,
  ["transfer-encoding"] = true,
}

--- True when s carries a CR, LF, or NUL — the bytes that would end a
--- header line early. The same rule `cosmic.fetch` applies to the
--- headers it sends, read from the other end of the connection.
--- @param s string The header name or value to scan
--- @return boolean True when s would break out of its header line
local function has_forbidden_byte(s: string): boolean
  return s:find("[\r\n\0]") ~= nil
end

--- Why this name/value pair may not be written, or nil when it may be.
--- The message names the header but never echoes the control bytes back.
--- @param name string The header name as the handler wrote it
--- @param value string The header value as the handler wrote it
--- @return string | nil The reason to refuse, or nil when the pair is safe
local function header_refusal(name: string, value: string): string | nil
  if name == "" then
    return "http: invalid header name: must not be empty"
  end
  if has_forbidden_byte(name) then
    return "http: invalid header name: must not contain CR, LF, or NUL"
  end
  if has_forbidden_byte(value) then
    return "http: invalid value for header '" .. name
    .. "': must not contain CR, LF, or NUL"
  end
  return nil
end

--- One HTTP/1.1 response, as a handler writes it.
local record Response
  --- The status code the next send writes. 200 until set otherwise.
  status: integer
  --- Set a header, replacing every value a previous set or add gave it.
  --- A name or value carrying a CR, LF or NUL is refused rather than
  --- written or stripped; the refusal surfaces at the send verb, which
  --- then sends nothing at all.
  --- @param name string The header name, written as it should appear
  --- @param value string The header value
  set_header: function(self: Response, name: string, value: string)
  --- Append a header value, keeping the ones already there.
  --- A name or value carrying a CR, LF or NUL is refused, exactly as
  --- `set_header` refuses it.
  --- @param name string The header name, written as it should appear
  --- @param value string The header value
  add_header: function(self: Response, name: string, value: string)
  --- Send the head and body as one write, finishing the response.
  --- A second send on the same response fails rather than writing a
  --- second head onto the connection, and so does a send after a
  --- refused header.
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
  --- Write the head and begin a streamed body, leaving the response
  --- open for `write`. An HTTP/1.1 response is framed
  --- `Transfer-Encoding: chunked` and the connection survives it; an
  --- HTTP/1.0 one has no chunked encoding to use, so it is framed by
  --- the connection closing and the head says `Connection: close`.
  --- Either way there is no `Content-Length`, because the server does
  --- not know one yet. A second `start`, a `start` after a send, or a
  --- `start` after a refused header all fail and write nothing.
  --- @return boolean True when the head reached the socket
  --- @return string Error message on failure
  start: function(self: Response): boolean, string
  --- Write one chunk of a started response's body.
  --- A zero-length chunk is a no-op rather than the terminating chunk,
  --- so a handler that produces nothing this round cannot end the
  --- response by accident; `finish` is the only terminator. Answering
  --- HEAD drops the bytes and reports success, exactly as `send` does.
  --- @param chunk string The body bytes to write
  --- @return boolean True when the chunk reached the socket
  --- @return string Error message on failure
  write: function(self: Response, chunk: string): boolean, string
  --- End a started response: the terminating chunk, and nothing after.
  --- A chunked HTTP/1.1 connection is reusable from here; an HTTP/1.0
  --- one is closed by the server, since closing is its framing.
  --- @return boolean True when the terminator reached the socket
  --- @return string Error message on failure
  finish: function(self: Response): boolean, string
  --- Write one Server-Sent Event, starting the stream on first call.
  --- The first call sets `Content-Type: text/event-stream` and
  --- `Cache-Control: no-cache` and calls `start`; every call writes
  --- `cosmic.sse.format(ev)`, so the wire framing is the one
  --- `cosmic.sse.parse` reads back. Call `finish` when the stream ends.
  --- @param ev sse.Event The event to serialize and write
  --- @return boolean True when the event reached the socket
  --- @return string Error message on failure
  event: function(self: Response, ev: sse.Event): boolean, string
end

--- One request/response exchange: the Response a handler writes, plus
--- the three questions only the connection loop asks about it.
local record Exchange
  --- The Response handed to the handler.
  response: Response
  --- Whether the handler has sent a response yet.
  --- @return boolean True once a send verb wrote a head
  is_finished: function(self: Exchange): boolean
  --- Whether the connection must close after this response.
  --- True when the answer carried `Connection: close`, and also when a
  --- handler started a streamed response and never finished it: the
  --- chunked body it left open has no terminator, so anything written
  --- next would be read as more of it.
  --- @return boolean True when this must be the connection's last exchange
  will_close: function(self: Exchange): boolean
  --- Why no send verb on this response can succeed, if a header was
  --- refused. The loop logs it; a handler that checks its send verb's
  --- error has already been told the same thing.
  --- @return string | nil The refusal reason, or nil when none was made
  refusal: function(self: Exchange): string | nil
end

--- Create a response for one exchange on a connection.
--- `close_requested` is the request's half of the keep-alive decision —
--- an HTTP/1.0 request that did not ask for keep-alive, or any request
--- that sent `Connection: close`. A handler can only add to it, by
--- setting `Connection: close` itself; it can never talk the server back
--- into reusing a connection the client is done with.
---
--- `suppress_body` is the HEAD case: RFC 9112 §6.3 says a client never
--- reads content after a HEAD response's head, so sending any would be
--- read as the start of the next response and desynchronize keep-alive.
--- The head is still computed as if the body had been sent —
--- `Content-Length` reports what a GET would have returned — and only
--- the body bytes are dropped, which is what makes the two responses
--- agree on everything a HEAD is asked to report.
---
--- `version` is the request's, and it picks the streaming framing:
--- chunked from 1.1, connection-close from anything older. It does not
--- change the status line, which is HTTP/1.1 either way — a 1.1 server
--- answering a 1.0 client says so.
--- @param conn net.Socket The connection to write the response to
--- @param version integer The request's version: 9, 10 or 11
--- @param close_requested boolean Whether the request ruled out reuse
--- @param suppress_body boolean Whether to send the head only (HEAD)
--- @return Exchange The response and the loop's view of it
local function new(conn: net.Socket, version: integer,
    close_requested: boolean, suppress_body: boolean): Exchange
  -- Header state is three parallel pieces: the lowercase names in
  -- insertion order, the spelling each was written with, and the values.
  -- Lowercase is the identity (HTTP header names are case-insensitive,
  -- so a set must replace a differently-spelled earlier one); the
  -- spelling is kept only so the wire reads the way the handler wrote it.
  local order: {string} = {}
  local spelling: {string: string} = {}
  local values: {string: {string}} = {}
  local finished = false
  -- Streaming is its own two bits: `streaming` says a head went out
  -- with no length behind it, `stream_done` that the terminator
  -- followed. `finished` covers both shapes, because what the loop
  -- asks is only whether this response already owns the connection.
  local streaming = false
  local stream_done = false
  local must_close = close_requested
  -- Chunked needs HTTP/1.1; an older client gets the one framing it
  -- does understand, which is the server closing the connection.
  local can_chunk = version >= 11
  -- The FIRST refusal is the one reported: a handler that set two bad
  -- headers has one bug, and the first one names where it started.
  local refused: string = nil

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

  --- Refuse a header outright rather than record it: a refused pair
  --- never enters `values`, so no later send can write it even by
  --- accident, and the remembered reason makes every send fail.
  --- @param name string The header name the handler wrote
  --- @param value string The header value the handler wrote
  --- @return boolean True when the pair may be written
  local function admit(name: string, value: string): boolean
    local reason = header_refusal(name, value)
    if reason == nil then
      return true
    end
    if refused == nil then
      refused = reason
    end
    return false
  end

  function res:set_header(name: string, value: string)
    if not admit(name, value) then
      return
    end
    local key = remember(name)
    values[key] = {value}
    note_close(key, value)
  end

  function res:add_header(name: string, value: string)
    if not admit(name, value) then
      return
    end
    local key = remember(name)
    table.insert(values[key], value)
    note_close(key, value)
  end

  --- The status line, the Date, and every header the handler set that
  --- the server does not compute itself. The framing headers are the
  --- caller's to append, because they are the only thing `send` and
  --- `start` disagree about.
  --- @param status integer The status code to write
  --- @return {string} The head so far, one line per entry
  local function head_lines(status: integer): {string}
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
    return out
  end

  function res:send(body: string): boolean, string
    if refused ~= nil then
      -- Not marked finished: the loop's fallback answer is what this
      -- client gets, built on a response with none of these headers.
      return false, refused
    end
    if streaming then
      -- The head on the wire says chunked, or says nothing about length
      -- at all; a Content-Length now would contradict it, and the body
      -- would land inside the stream as one more piece of it.
      return false, "http: response already started"
    end
    if finished then
      return false, "http: response already sent"
    end
    finished = true
    local status = self.status or 200
    local out = head_lines(status)
    out[#out + 1] = "Content-Length: " .. #body .. "\r\n"
    out[#out + 1] = "Connection: " .. (must_close and "close" or "keep-alive") .. "\r\n"
    out[#out + 1] = "\r\n"
    -- The head above already counted the body; answering HEAD means
    -- writing that count and stopping, so the next thing the client
    -- reads on a kept-alive connection is the next response's status line.
    if not suppress_body then
      out[#out + 1] = body
    end
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

  function res:start(): boolean, string
    if refused ~= nil then
      return false, refused
    end
    if streaming then
      return false, "http: response already started"
    end
    if finished then
      return false, "http: response already sent"
    end
    streaming = true
    -- Finished from the loop's side the moment the head is out: the
    -- connection is this response's now, so no fallback 500 may be
    -- written behind it even if the handler never calls `finish`.
    finished = true
    local out = head_lines(self.status or 200)
    if can_chunk then
      out[#out + 1] = "Transfer-Encoding: chunked\r\n"
      out[#out + 1] = "Connection: " .. (must_close and "close" or "keep-alive") .. "\r\n"
    else
      -- Without chunked there is no in-band end of body, so the close
      -- IS the framing and the client must be told to expect it.
      must_close = true
      out[#out + 1] = "Connection: close\r\n"
    end
    out[#out + 1] = "\r\n"
    return conn:send_all(table.concat(out))
  end

  function res:write(chunk: string): boolean, string
    if not streaming then
      return false, "http: response not started"
    end
    if stream_done then
      return false, "http: response already finished"
    end
    -- `0\r\n\r\n` is the terminator, so an empty chunk written as one
    -- would end the body; a handler with nothing to say writes nothing.
    if #chunk == 0 then
      return true
    end
    -- RFC 9112 §6.3: a HEAD response carries no content, and the head
    -- already said what a GET would have framed.
    if suppress_body then
      return true
    end
    if not can_chunk then
      return conn:send_all(chunk)
    end
    return conn:send_all(string.format("%x\r\n", #chunk) .. chunk .. "\r\n")
  end

  function res:finish(): boolean, string
    if not streaming then
      return false, "http: response not started"
    end
    if stream_done then
      return false, "http: response already finished"
    end
    stream_done = true
    if not can_chunk or suppress_body then
      -- Nothing to terminate: an HTTP/1.0 body ends when the loop
      -- closes the connection, and a HEAD response has no body at all.
      return true
    end
    return conn:send_all("0\r\n\r\n")
  end

  function res:event(ev: sse.Event): boolean, string
    if not streaming then
      self:set_header("Content-Type", "text/event-stream")
      self:set_header("Cache-Control", "no-cache")
      local ok, err = self:start()
      if not ok then
        return false, err
      end
    end
    return self:write(sse.format(ev))
  end

  local ex: Exchange = {response = res}

  function ex:is_finished(): boolean
    return finished
  end

  function ex:will_close(): boolean
    -- A stream the handler opened and never terminated leaves the
    -- connection mid-body; the next response would be read as the rest
    -- of it, so the close is the only honest way out.
    return must_close or (streaming and not stream_done)
  end

  function ex:refusal(): string | nil
    return refused
  end

  return ex
end

local record HttpResponseModule
  type Response = Response
  type Exchange = Exchange
  new: function(conn: net.Socket, version: integer,
  close_requested: boolean, suppress_body: boolean): Exchange
end

local M: HttpResponseModule = {
  new = new,
}

return M
