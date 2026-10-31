--- An HTTP/1.1 server, over [`Net.serve`]: [`Server.serve`] calls a handler
--- with each [`Request`], its body a Reader, and writes the [`Reply`] it
--- answers. [`Server.range`] and [`Server.none_match`] read a request's
--- Range and If-None-Match for it, [`Server.encoding`] its Accept-Encoding,
--- and [`ServeSpec.compress`] has the server compress replies. It is apart from [`cosmic.http`], the
--- client, so a program that only fetches does not carry the networking
--- stack a server needs.
---
---     local Net = require("cosmic.net")
---     local Server = require("cosmic.http.server")
---
---     assert(Server.serve{
---       listeners = { Net.tcp("127.0.0.1", 8080) },
---       handle = function(req: Server.Request): Server.Reply
---         return { status = 200, body = "you asked for " .. req.path .. "\n" }
---       end,
---     })

local Clock = require("cosmic.clock")
local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Number = require("cosmic.number")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local Time = require("cosmic.time")
local errors = require("cosmic.internal.errors")
local wire = require("cosmic.http.wire")

local record Server
  --- One request [`Server.serve`] hands its handler. Its head is read
  --- whole; its body is not read yet.
  record Request
    --- The method, case-sensitive: "GET", "PUT". A HEAD is passed on as
    --- itself: answer it as GET, and the server sends the head the GET's
    --- reply has, its Content-Length (or `Transfer-Encoding: chunked`)
    --- included, and no body; or, without the bytes, give the size alone,
    --- with no body: `{ status = 200, headers = { ["Content-Length"] =
    --- tostring(size) } }`.
    method: string
    --- The request target as sent: "/items/a%20b?full=1".
    target: string
    --- The target's path, still %-escaped -- [`Url.segments`] decodes
    --- it -- or an absolute-form target's ("/" when it names none), or
    --- "*" for `OPTIONS *`.
    path: string
    --- What follows the target's first "?", still escaped; "" when none.
    query: string
    --- "HTTP/1.1" or "HTTP/1.0".
    version: string
    --- The headers, by lowercased name; a name sent more than once has
    --- its values joined with ", ", but `cookie`'s with "; " (RFC
    --- 6265 5.4). For an absolute-form target, `host`
    --- is the target's host and port, whatever Host said.
    headers: {string:string}
    --- The body, read as it arrives: a Content-Length's bytes, or a
    --- chunked body decoded, and nothing for a request with neither.
    --- [`Stream.read_all`] reads it whole, for the common case; it
    --- holds at most `limits.body_bytes`. A read past that fails, and
    --- the server answers 413 in place of the handler's reply (so a
    --- handler may simply `assert` the read); a chunked body
    --- malformed fails the same way, answered 400. A body the handler
    --- leaves unread is read and dropped after its reply, the
    --- connection closed instead where it fails. Closing it does
    --- nothing more than end the handler's reads.
    body: Stream.Reader
    --- The Content-Length: the body's size, 0 for a request with no
    --- body, nil for a chunked one.
    length?: integer
    --- Where the request came from: the numeric TCP address of the
    --- connection's far end, as the kernel names it, and the proxy's
    --- where one sits between (no header is read). Nil where the
    --- connection has none ([`Net.Conn.peer`] says when).
    peer?: Net.Address
  end

  --- What a handler answers. The server writes `Date`,
  --- `Content-Length` (or `Transfer-Encoding: chunked`) and
  --- `Connection` itself. A handler may give `Content-Length` too, as
  --- `length` or a header: it must be the body's size, and the server
  --- writes it once. A reply naming `Date`, `Connection` or
  --- `Transfer-Encoding`, a header holding CR, LF or NUL, a
  --- Content-Length that is no digits, past 18 of them, named twice in
  --- different cases, other than `length`, given a 204, or not the
  --- body's size, a body for a 204 or 304, or anything but such a
  --- record, is answered 500 instead and reported to
  --- [`Server.ServeSpec.on_error`].
  record Reply
    --- The status, from 200 to 999: the server sends `100 Continue`
    --- itself, and no other 1xx.
    status: integer
    --- Headers, name to value, written as given, but for a
    --- `Content-Length` (any case of the name), which is the body's size
    --- as `length` is: digits, equal to a string body's length, and
    --- naming the size of a Reader body. Without a body (nil or "") it
    --- is 0, but in a reply to HEAD, where it is the size of the body a
    --- GET would get, sent with no bytes; and in a 304, where RFC 9110
    --- 8.6 has it the size of a 200's body, and it is passed on
    --- unchecked. A 204 has none. A list value writes one line per
    --- element, in order: use it for Set-Cookie, which cannot be joined
    --- with ", " (RFC 6265 3, RFC 9110 5.3). An empty list writes
    --- nothing; a list of Content-Length is refused.
    headers?: {string: string | {string}}
    --- nil for none, the bytes, or a Reader, which the server reads to
    --- its end (or to `length`) as it writes and then closes, read or
    --- not.
    body?: string | Stream.Reader
    --- The body's size in bytes, as a `Content-Length` header gives it:
    --- the two, given both, must agree. A Reader without either goes
    --- chunked, or, to an HTTP/1.0 client, until the connection closes.
    length?: integer
    --- Close the connection after this reply.
    close?: boolean
  end

  --- What [`Server.serve`] serves, and how. A field of the wrong shape, or
  --- one not named here, raises, naming it.
  record ServeSpec
    --- Where to listen, as [`Net.ServeSpec.listeners`].
    listeners?: {Net.Address}
    --- Answers one request, in the connection's task: see [`Server.serve`].
    handle: function(Request): Reply
    --- What a server takes on at most; a field left nil has its default.
    record Limits
      --- The most connections open at once (256).
      connections?: integer
      --- The most bytes of a request's head (64 KiB), past which it is
      --- answered 431, and of the head with a chunked body's chunk
      --- extensions and trailers, past which 413.
      head_bytes?: integer
      --- The most bytes of a request's body (1 MiB); past it, 413.
      -- TODO: let a request's route choose its own limit
      -- (`ServeSpec.body_limit(method, path)`, doc/plans/web/core.md
      -- 13.4). A lower one needs only exchange to consult it before
      -- wire.body; a higher one (an upload route) waits on
      -- wire.read_head, which answers 413 for a Content-Length past the
      -- server-wide `body_bytes` before the route is known: it would
      -- take the Content-Length check out of read_head into the caller.
      body_bytes?: integer
    end
    --- Bounds on what the server takes on; nil for every default.
    limits?: Limits
    --- How long any one read or write of a connection waits once a
    --- request's head is in -- the body's reads, the reply's writes
    --- -- (30 seconds); see [`Net.ServeSpec.timeout_ns`].
    timeout_ns?: integer
    --- As [`Net.ServeSpec.grace_ns`]: how long requests in flight have
    --- to finish once the server stops; nil to wait for every one.
    grace_ns?: integer
    --- How long a connection waits for the first byte of a request, its
    --- first or the next after a reply, before it is closed (5 seconds).
    idle_ns?: integer
    --- How long a request's head may take to arrive whole, from its
    --- first byte (30 seconds): past it, 408 and the connection closed,
    --- so a client sending a head a byte at a time holds a connection
    --- no longer.
    head_ns?: integer
    --- How long a request's body may take (30 seconds), however steadily
    --- its bytes come. The time runs from the handler's first read of
    --- the body, so a handler working before it reads costs the client
    --- none; the server's own drop of a body the handler left unread
    --- has a window of its own. Past it the read fails as a
    --- [`Poll.TIMEOUT`] does and the server answers 408 in place of the
    --- handler's reply and closes, so a client sending a body a byte
    --- at a time holds a connection no longer; a body that was unread
    --- and is not dropped in time closes the connection after the
    --- handler's reply. A request with no body has none. A server taking
    --- uploads past what 30 seconds carry raises it.
    body_ns?: integer
    --- Compresses replies for the `Accept-Encoding` the request sent:
    --- `true` for the defaults, or a [`Server.Compression`]. See
    --- [`Server.serve`]. Nil leaves every reply as the handler made it.
    compress?: boolean | Compression
    --- As [`Net.ServeSpec.on_ready`].
    on_ready?: function(addresses: {Net.Address}, server: Net.Server)
    --- As [`Net.ServeSpec.on_stop`]: called once, as the server begins
    --- to stop, in a task of its run. The server has by then marked
    --- itself stopping (a reply in flight is sent with `Connection:
    --- close`) and closed the connections idle between requests, so it
    --- is where a long-lived reply, a stream, is told to end. What it
    --- raises goes to [`Server.ServeSpec.on_error`] and the server stops
    --- all the same.
    on_stop?: function(server: Net.Server)
    --- Given what a handler raised, with its stack, or why its reply
    --- could not be sent; nil to write each to stderr. See
    --- [`Net.ServeSpec.on_error`].
    on_error?: function(trouble: string)
  end

  --- How [`Server.ServeSpec.compress`] compresses.
  record Compression
    --- The smallest body to compress, in bytes (1024): a reply whose
    --- size is known and below it is sent as it is. A Reader body
    --- without a size is compressed, whatever its length turns out.
    min_bytes?: integer
  end

  --- What a Range header asks of a representation, as [`Server.range`]
  --- reads it: all of it, one span of its bytes, or none.
  enum RangeKind
    "whole"
    "span"
    "unsatisfiable"
  end

  --- One Range header read against a representation's size: see
  --- [`Server.range`].
  record Range
    --- "whole" for a 200 with every byte, "span" for a 206 with the
    --- bytes from `first` to `last`, "unsatisfiable" for a 416.
    kind: RangeKind
    --- The span's first byte, counted from 0; set only for "span".
    first?: integer
    --- The span's last byte, counted from 0 and sent with it; set only
    --- for "span".
    last?: integer
  end
end

-- The server. Each connection is a task of [`Net.serve`]'s, reading one
-- request after another from a [`wire.Input`] over it, so the bytes of a
-- pipelined request read with the one before stay for it.

local KIB <const> = 1024

--- How long a closing connection is read, and what it sends dropped,
--- after a reply that left part of the request unread, so the client
--- reads the reply before the close: closed with bytes unread, a TCP
--- connection resets, and the reset can reach the client first.
local LINGER_NS <const> = Clock.seconds(1)
local LINGER_BYTES <const> = 256 * KIB

local SPEC_FIELDS <const>: {string:boolean} = {
  listeners = true, handle = true, limits = true, compress = true, timeout_ns = true, grace_ns = true,
  idle_ns = true, head_ns = true, body_ns = true, on_ready = true, on_stop = true,
  on_error = true,
}

local LIMIT_FIELDS <const>: {string:boolean} = {
  connections = true, head_bytes = true, body_bytes = true,
}

local REPLY_FIELDS <const>: {string:boolean} = {
  status = true, headers = true, body = true, length = true, close = true,
}

--- Raises for the spec's `field`, at the caller of [`Server.serve`].
local function spec_error(field: string, must: string): never
  error("http: spec." .. field .. " must be " .. must, 4)
end

--- Raises, naming the field, where `spec` is no [`Server.ServeSpec`]; an
--- address [`Net.serve`] checks itself.
local function checked_spec(spec: any)
  if not spec is {any: any} then error("http: serve takes a spec table", 3) end
  for key in pairs(spec) do
    if not (key is string and SPEC_FIELDS[key] == true) then
      error("http: spec has no field " .. tostring(key), 3)
    end
  end
  local listeners = spec.listeners
  if not listeners is {any} or #listeners == 0 then
    spec_error("listeners", "a list of one address or more")
  end
  if type(spec.handle) ~= "function" then spec_error("handle", "a function of a request") end
  local limits = spec.limits
  if limits ~= nil then
    if not limits is {any: any} then
      spec_error("limits", "a table")
    else
      for key, value in pairs(limits) do
        if not (key is string and LIMIT_FIELDS[key] == true) then
          error("http: spec.limits has no field " .. tostring(key), 3)
        end
        if not (value is integer and value >= 1) then
          spec_error("limits." .. tostring(key), "nil or an integer from 1")
        end
      end
    end
  end
  for _, field in ipairs({ "timeout_ns", "grace_ns", "idle_ns", "head_ns", "body_ns" }) do
    Poll.checked_ns(spec[field], "http", "spec." .. field, 3)
  end
  for _, field in ipairs({ "on_ready", "on_stop", "on_error" }) do
    local fn = spec[field]
    if fn ~= nil and type(fn) ~= "function" then spec_error(field, "nil or a function") end
  end
end

--- A connection read under a deadline: each read waits at most `each`,
--- and none past `deadline`, a [`Clock.monotonic_ns`] reading (nil for
--- none).
local class Timed is Stream.Reader
  conn: Net.Conn
  each: integer
  mut deadline?: integer

  function read(self, max_bytes?: integer): string?, string
    local wait = self.each
    local deadline = self.deadline
    if deadline ~= nil then
      local left = deadline - Clock.monotonic_ns()
      if left <= 0 then return nil, Poll.TIMEOUT end
      if wait == nil or left < wait then wait = left end
    end
    self.conn:set_timeout(wait)
    return self.conn:read(max_bytes)
  end

  --- The connection is the server's to close.
  function close(self): boolean, string
    return true, ""
  end
end

--- A server's state for the length of its run.
local record Serving
  spec: Server.ServeSpec
  limits: wire.Limits
  timeout_ns: integer
  idle_ns: integer
  head_ns: integer
  body_ns: integer
  mut stopping: boolean
  --- The smallest body to compress; nil where replies are not compressed.
  compress_from?: integer
  --- Each connection waiting for its next request's first byte, which
  --- stopping closes at once.
  idle: mut {Net.Conn: boolean}
end

--- Gives `trouble` to the spec's [`Server.ServeSpec.on_error`], or stderr.
local function report(s: Serving, trouble: string)
  local on_error = s.spec.on_error
  if on_error ~= nil then
    on_error(trouble)
    return
  end
  local _, _ = Fs.put(Fs.stderr, trouble .. "\n")
end

--- What a handler raised, with the stack it raised from.
local function traced(err: any): string
  return errors.trace(tostring(err), 2)
end

--- Sends the server's own reply of `status` to the request `head` (nil
--- where there is none), saying `why` in its body, and closes after it.
local function answer(s: Serving, conn: Net.Conn, head: wire.Head?, status: integer, why: string)
  local text = ("%d %s"):format(status, wire.reason(status))
  if why ~= "" then text = text .. ": " .. why end
  conn:set_timeout(s.timeout_ns)
  local _ = wire.send(conn, {
    status = status, headers = { ["Content-Type"] = "text/plain; charset=utf-8" },
    body = text .. "\n", close = true, method = head ~= nil and head.method or "GET",
    version = head ~= nil and head.version or "HTTP/1.1", date = Time.format_http(Clock.now_ns()),
  })
end

--- Ends what `conn` sends and reads what it still sends, dropping it,
--- for at most `LINGER_NS` and `LINGER_BYTES`, so the reply just written
--- reaches the client before the close.
local function linger(conn: Net.Conn)
  local _, _ = conn:shutdown("write")
  local deadline = Clock.monotonic_ns() + LINGER_NS
  local dropped = 0
  while dropped < LINGER_BYTES do
    local left = deadline - Clock.monotonic_ns()
    if left <= 0 then return end
    conn:set_timeout(left)
    local piece, _ = conn:read()
    if piece == nil then return end
    dropped = dropped + #piece
  end
end

--- Why `reply`, what a handler answered, is no reply the server can
--- send, or "".
local function reply_trouble(reply: any): string
  if not reply is {any: any} then
    return "the handler answered " .. type(reply) .. ", not a Server.Reply"
  end
  for key in pairs(reply) do
    if not (key is string and REPLY_FIELDS[key] == true) then
      return "the reply has no field " .. tostring(key)
    end
  end
  local status = reply.status
  if not (status is integer and status >= 200 and status <= 999) then
    return "the reply's status must be an integer from 200 to 999"
  end
  local headers = reply.headers
  if headers ~= nil then
    if not headers is {any: any} then return "the reply's headers must be a table" end
    for name, value in pairs(headers) do
      if not name is string then return "the reply's headers must map names to strings" end
      if value is {any: any} then
        -- A list: keys 1..n, all strings.
        local count = 0
        for key, line in pairs(value) do
          if not (key is integer and line is string) then
            return "the reply's headers must map names to strings or lists of them"
          end
          count = count + 1
        end
        for i = 1, count do
          if value[i] == nil then
            return "the reply's headers must map names to strings or lists of them"
          end
        end
      elseif not value is string then
        return "the reply's headers must map names to strings or lists of them"
      end
    end
  end
  local body = reply.body
  if body ~= nil and not body is string and
      not (body is {any: any} and type(body.read) == "function" and type(body.close) == "function") then
    return "the reply's body must be nil, a string or a Stream.Reader"
  end
  local length, close = reply.length, reply.close
  if length ~= nil and not length is integer then
    return "the reply's length must be an integer"
  end
  if close ~= nil and not close is boolean then
    return "the reply's close must be a boolean"
  end
  return ""
end

--- Closes the Reader body of `reply`, what a handler answered, where it
--- has one the server will not send: checked as it runs, since the
--- handler's answer is a [`Reply`] only by its declaration.
local function drop_body(reply: Server.Reply?)
  if type(reply) ~= "table" then return end
  local body = reply.body
  if body == nil then return end
  if type(body) == "table" and not body is string and type(body.close) == "function" then
    -- Protected: a close that raised once, in the reply's send, may again.
    local _, _ = pcall(body.close, body)
  end
end

--- Why the server cannot send `reply`, what a handler answered to a request
--- of `method` (GET when nil), or "": the checks it makes before it
--- writes one, and for which it answers 500 instead -- a field the
--- [`Server.Reply`] lacks, a header that cannot be written, a body or a
--- Content-Length that disagree. A test that calls a handler without a
--- server asks it what the server would.
---
---     assert(Server.check({ status = 200, body = "hi" }) == "")
---     assert(Server.check({ status = 200, body = "hi", length = 5 }) ~= "")
--- @param reply Server.Reply The handler's answer
--- @param method string | nil The request's method
--- @return string Why it cannot be sent, or ""
function Server.check(reply: Server.Reply, method?: string): string
  local trouble = reply_trouble(reply)
  if trouble ~= "" then return trouble end
  -- `check` reads no date: the one sent is made as the reply goes out.
  return wire.check({ status = reply.status, headers = reply.headers, body = reply.body,
    length = reply.length, method = method, date = "" })
end

--- The reason phrase of `status` as the server writes it ("Not Found"),
--- or "" for a status it does not name.
--- @param status integer An HTTP status
--- @return string Its phrase
function Server.reason(status: integer): string
  return wire.reason(status)
end

-- What a handler reads of a request's Accept-Encoding, and how the
-- server compresses a reply for it, as RFC 9110 section 12.5.3 says.

--- Whether byte `b` is a space or a tab, RFC 9110's OWS; nil, past
--- the text's end, is not.
local function ows(b: integer?): boolean
  return b == 32 or b == 9
end

--- `text` from `from` to `to`, without the spaces and tabs at either
--- end. Scanned a byte at a time: a pattern anchored at `$` would retry
--- at every position of an inner run of them.
local function stripped(text: string, from: integer, to: integer): string
  while from <= to and ows(text:byte(from)) do from = from + 1 end
  while to >= from and ows(text:byte(to)) do to = to - 1 end
  return text:sub(from, to)
end

--- The codings the server writes, best first.
local CODINGS <const>: {string} = { "zstd", "gzip" }

local TOKEN <const> = "^[%w!#$%%&'*+%-.^_`|~]+$"

--- The qvalue `text` writes, in thousandths, or nil where it is none
--- (RFC 9110 12.4.2: `0` to `1`, at most three decimals).
local function weight(text: string): integer?
  if text == "0" then return 0 end
  if text == "1" then return 1000 end
  local decimals = text:match("^0%.(%d?%d?%d?)$")
  if decimals ~= nil then return math.tointeger(tonumber((decimals .. "00"):sub(1, 3))) end
  if text:find("^1%.0?0?0?$") ~= nil then return 1000 end
  return nil
end

--- Chooses the content coding of a reply from the request's
--- Accept-Encoding `header` (nil where it sent none), as RFC 9110
--- section 12.5.3 says: the one of `offered` (best first; "zstd" then
--- "gzip" when nil) with the greatest qvalue, the first of them on a
--- tie, and "identity" where none has a qvalue above 0. Answers nil
--- where the client accepts neither: it refused identity, by
--- `identity;q=0` or by `*;q=0` with no `identity` of its own.
---
---     assert(Server.encoding("gzip, zstd;q=0.5") == "gzip")
---     assert(Server.encoding("*;q=0") == nil)
---     assert(Server.encoding(nil) == "identity")
---
--- Coding names compare in any case, `x-gzip` is `gzip`, and `*` stands
--- for every coding not named. A coding named twice has its first
--- weight. An element that is no coding, or whose weight is no
--- qvalue, is ignored, as are parameters other than the weight. A
--- client naming `identity` with a weight above every coding's is
--- answered "identity"; one that leaves it unnamed is answered a
--- coding it accepts before it. An empty header accepts identity alone.
--- @param header string | nil The request's Accept-Encoding
--- @param offered {string} | nil The codings the caller can write
--- @return string | nil The coding, "identity", or nil for none
function Server.encoding(header: string?, offered?: {string}): string?
  local choices = offered or CODINGS
  if header == nil then return "identity" end
  local named: mut {string: integer} = {}
  local star: integer? = nil
  local from = 1
  while true do
    local comma = header:find(",", from, true)
    local element = stripped(header, from, if comma ~= nil then comma - 1 else #header end)
    local semicolon = element:find(";", 1, true)
    local name = stripped(element, 1, if semicolon ~= nil then semicolon - 1 else #element end):lower()
    local q: integer? = 1000
    if semicolon ~= nil then
      local given = stripped(element, semicolon + 1, #element):match("^[qQ]=(.*)$")
      q = if given ~= nil then weight(given) else nil end
    end
    if q ~= nil then
      if name == "*" then
        if star == nil then star = q end
      elseif name:find(TOKEN) ~= nil then
        if name == "x-gzip" then name = "gzip" end
        if named[name] == nil then named[name] = q end
      end
    end
    if comma == nil then break end
    from = comma + 1
  end
  local best: string? = nil
  local best_q = 0
  for _, coding in ipairs(choices) do
    local q = named[coding] or star or 0
    if q > best_q then best, best_q = coding, q end
  end
  local identity = named["identity"]
  if best ~= nil and not (identity ~= nil and identity > best_q) then return best end
  local accepted = if identity ~= nil then identity > 0 else star ~= 0 end
  return if accepted then "identity" else nil end
end

--- The names in `headers` that are `lower` in any case, in name order.
local function named_as(headers: {string: string | {string}}, lower: string): {string}
  local names: mut {string} = {}
  for name in pairs(headers) do
    if name:lower() == lower then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

--- The value of header `lower` joined as a list ("" where there is none).
local function joined(headers: {string: string | {string}}, lower: string): string
  local parts: mut {string} = {}
  for _, name in ipairs(named_as(headers, lower)) do
    local value = headers[name]
    if value is string then
      parts[#parts + 1] = value
    elseif value ~= nil then
      for _, entry in ipairs(value) do parts[#parts + 1] = entry end
    end
  end
  return table.concat(parts, ", ")
end

--- Media types besides text/* whose bytes compress.
local COMPRESSIBLE <const>: {string: boolean} = {
  ["application/json"] = true, ["application/javascript"] = true, ["application/xml"] = true,
  ["application/x-ndjson"] = true, ["application/wasm"] = true, ["image/svg+xml"] = true,
}

--- Whether a body of Content-Type `content_type` is worth compressing:
--- text but a stream of events, whose chunks must not wait on a
--- compressor, and the structured formats above and any `+json` or `+xml`.
local function compressible(content_type: string): boolean
  local media = stripped(content_type:match("^[^;]*") or content_type, 1, #content_type):lower()
  if media == "text/event-stream" then return false end
  return media:sub(1, 5) == "text/" or COMPRESSIBLE[media] == true or
    media:find("%+json$") ~= nil or media:find("%+xml$") ~= nil
end

--- `headers` copied, but for the Content-Length, which a compressed
--- body changes, and with `Accept-Encoding` among the Vary: added to
--- the first Vary line, or on a line of its own, unless a Vary names
--- it or `*` already.
local function varied(headers: {string: string | {string}}, drop_length: boolean):
    mut {string: string | {string}}
  local copy: mut {string: string | {string}} = {}
  for name, value in pairs(headers) do
    if not (drop_length and name:lower() == "content-length") then copy[name] = value end
  end
  for token in (joined(copy, "vary") .. ","):gmatch("([^,]*),") do
    local field = stripped(token, 1, #token):lower()
    if field == "*" or field == "accept-encoding" then return copy end
  end
  local vary = named_as(copy, "vary")[1]
  local value = if vary ~= nil then copy[vary] else nil end
  if vary == nil or value == nil then
    copy["Vary"] = "Accept-Encoding"
  elseif value is string then
    copy[vary] = if value == "" then "Accept-Encoding" else value .. ", Accept-Encoding" end
  else
    local list: mut {string} = {}
    for i, entry in ipairs(value) do list[i] = entry end
    list[#list + 1] = "Accept-Encoding"
    copy[vary] = list
  end
  return copy
end

--- Makes a strong entity tag weak in `headers`: the compressed
--- bytes are another representation than the one it names.
local function weakened(headers: mut {string: string | {string}})
  for _, name in ipairs(named_as(headers, "etag")) do
    local value = headers[name]
    if value is string and value:sub(1, 2) ~= "W/" then headers[name] = "W/" .. value end
  end
end

--- A new encoder for `coding`, nil where there is none.
local function encoder_for(coding: string): Compress.Stream?
  if coding == "zstd" then
    local encoder, _ = Compress.zstd_encoder()
    return encoder
  end
  local encoder, _ = Compress.deflater("gzip")
  return encoder
end

--- `reply` for a request of `accepts` (its Accept-Encoding) compressed
--- as [`Server.serve`] describes, or as it is where it is not to be.
local function compressed(min_bytes: integer, accepts: string?, reply: Server.Reply): Server.Reply
  local status, body = reply.status, reply.body
  if status == 206 or status == 204 or status == 304 or body == nil or body == "" then
    return reply
  end
  local headers = reply.headers or {}
  if #named_as(headers, "content-encoding") > 0 or #named_as(headers, "content-range") > 0 then
    return reply
  end
  if joined(headers, "cache-control"):lower():find("no%-transform") ~= nil then return reply end
  local content_type = joined(headers, "content-type")
  if content_type == "" or not compressible(content_type) then return reply end
  local size: integer? = nil
  if body is string then
    size = #body
  else
    size = math.tointeger(tonumber(joined(headers, "content-length"))) or reply.length
  end
  if size ~= nil and size < min_bytes then return reply end
  local coding = Server.encoding(accepts)
  if coding == nil then
    drop_body(reply)
    return { status = 406, close = reply.close, body = "406 Not Acceptable: this reply is sent identity" ..
        " or compressed, and the request refuses both\n",
      headers = varied({ ["Content-Type"] = "text/plain; charset=utf-8" }, false) }
  end
  local unchanged: Server.Reply = { status = status, headers = varied(headers, false), body = body,
    length = reply.length, close = reply.close }
  if coding == "identity" then return unchanged end
  local encoder = encoder_for(coding)
  if encoder == nil then return unchanged end
  local smaller: string | Stream.Reader
  if body is string then
    local out, _ = Stream.run(encoder, body)
    if out == nil or #out >= #body then return unchanged end
    smaller = out
  else
    smaller = Stream.transform(body, encoder)
  end
  local out_headers = varied(headers, true)
  out_headers["Content-Encoding"] = coding
  weakened(out_headers)
  return { status = status, headers = out_headers, body = smaller, close = reply.close }
end

--- Serves the request `head` read from `input`: calls the handler and
--- writes its reply, or the server's own. True where the connection
--- stays open for the next request.
local function exchange(s: Serving, conn: Net.Conn, input: wire.Input, head: wire.Head,
                        timed: Timed, peer: Net.Address?): boolean
  -- Whether `100 Continue` went, and whether the final head has: an
  -- interim reply after it would be read as the final reply's body.
  local interim = { continued = false, replied = false }
  local function go_on()
    if head.continue and interim.continued ~= true and interim.replied ~= true then
      interim.continued = true
      conn:set_timeout(s.timeout_ns)
      local _, _ = conn:write("HTTP/1.1 100 Continue\r\n\r\n")
    end
  end
  -- The body's deadline starts at the handler's first read, so the
  -- handler's own time before it is the client's no more.
  local body = wire.body(input, head, s.limits, function()
    timed.deadline = Clock.monotonic_ns() + s.body_ns
    go_on()
  end)
  local request: Server.Request = {
    method = head.method, target = head.target, path = head.path, query = head.query,
    version = head.version, headers = head.headers, body = body, length = head.length, peer = peer,
  }
  local ok, reply = xpcall(s.spec.handle, traced, request)
  -- A body that failed is answered for, whatever the handler made of
  -- it: its raise, or its reply, followed from the failed read.
  local state = body.state
  if state == "over" or state == "bad" or state == "failed" then
    if ok then drop_body(reply) end
    if state ~= "failed" then
      answer(s, conn, head, if state == "over" then 413 else 400 end, (body.failure:gsub("^http: ", "")))
      linger(conn)
    elseif body.failure == Poll.TIMEOUT then
      answer(s, conn, head, 408, "the body came slower than body_ns or timeout_ns")
      linger(conn)
    end
    return false
  end
  local where = head.method .. " " .. head.target
  if not ok then
    report(s, "http: " .. where .. ": " .. tostring(reply))
    answer(s, conn, head, 500, "")
    if body.state == "open" then linger(conn) end
    return false
  end
  -- A handler is a Reply only by its declaration: it may answer nothing.
  local trouble: string
  if reply == nil then
    trouble = reply_trouble(reply)
  else
    trouble = Server.check(reply, head.method)
  end
  if trouble ~= "" or reply == nil then
    drop_body(reply)
    report(s, "http: " .. where .. ": " .. trouble)
    answer(s, conn, head, 500, "")
    if body.state == "open" then linger(conn) end
    return false
  end
  -- The handler ran (`ok`), so `reply` is its answer, not an error's text.
  if reply is string then error("http: a handler's answer is text", 0) end
  local given: Server.Reply = reply
  if s.compress_from ~= nil then
    given = compressed(s.compress_from, head.headers["accept-encoding"], given)
  end
  local close = given.close == true or head.close or s.stopping
  -- A client still waiting for `100 Continue` sends its body only once
  -- told to, or not at all. A Reader reply may read the request's body
  -- as it goes, so the client is told now; after another, what follows
  -- on the connection is unknown, and it closes.
  if head.continue and interim.continued ~= true and body.state == "open" then
    local given_body = given.body
    local sends_body = head.method ~= "HEAD" and given.status ~= 204 and given.status ~= 304
    if given_body ~= nil and not given_body is string and sends_body and not close then
      go_on()
    else
      close = true
    end
  end
  interim.replied = true
  conn:set_timeout(s.timeout_ns)
  -- The reply is built inside the protected call, as its date is read there.
  local function send_reply(to: Net.Conn): wire.Sent
    return wire.send(to, {
      status = given.status, headers = given.headers, body = given.body,
      length = given.length,
      close = close, method = head.method, version = head.version,
      date = Time.format_http(Clock.now_ns()),
    })
  end
  local sending, sent = xpcall(send_reply, traced, conn)
  if not sending then
    -- A Reader body that raised: the reply is cut short.
    drop_body(given)
    report(s, "http: " .. where .. ": the reply's body: " .. tostring(sent))
    return false
  end
  -- The send answered once it did not raise.
  local result = sent
  if result == nil then return false end
  local failed = body.state ~= "open" and body.state ~= "done"
  if result.body_failure ~= "" and not failed then
    report(s, "http: " .. where .. ": the reply's body: " .. result.body_failure)
  end
  if result.close then
    if result.write_failure == "" and body.state == "open" then linger(conn) end
    return false
  end
  -- A reply Reader that read the request's body may have ended cleanly
  -- where the body failed: what follows it on the connection is no
  -- request to read.
  if failed then
    if body.state ~= "failed" then linger(conn) end
    return false
  end
  -- What of the body the handler left is dropped, so the next request
  -- starts where this one ends.
  if body.state == "open" then
    -- A window of its own: the handler's time, and its reads', are spent.
    timed.deadline = Clock.monotonic_ns() + s.body_ns
  end
  if body.state == "open" and not body:drain() then
    linger(conn)
    return false
  end
  return true
end

--- Serves `conn`, one request after another, until it closes, fails,
--- or idles past `idle_ns`.
local function serve_conn(s: Serving, conn: Net.Conn)
  local timed: Timed = { conn = conn, each = s.timeout_ns, deadline = nil }
  local input = wire.input(timed)
  -- Nil where the connection has none (a unix one); the request then has no peer.
  local peer, _ = conn:peer()
  while true do
    if not wire.buffered(input) then
      if s.stopping then return end
      s.idle[conn] = true
      timed.deadline = Clock.monotonic_ns() + s.idle_ns
      local ok, _ = wire.fill(input)
      s.idle[conn] = nil
      if not ok then return end
    end
    timed.deadline = Clock.monotonic_ns() + s.head_ns
    local read = wire.read_head(input, s.limits)
    timed.deadline = nil
    local head = read.head
    if head == nil then
      if read.status ~= 0 then
        answer(s, conn, nil, read.status, read.why)
        linger(conn)
      elseif read.why == Poll.TIMEOUT then
        answer(s, conn, nil, 408, "the head took longer than head_ns")
      end
      return
    end
    local kept = exchange(s, conn, input, head, timed, peer)
    timed.deadline = nil
    if not kept then return end
  end
end

--- Serves HTTP/1.1 at each of `spec.listeners`, calling `spec.handle`
--- for each request, until the server stops: [`Net.serve`], whose
--- connections, signals and stopping it shares, speaking HTTP. It
--- answers as [`Net.serve`] does, and raises for a spec of the wrong
--- shape, naming the field.
---
---     assert(Server.serve{
---       listeners = { Net.tcp("127.0.0.1", 8080) },
---       handle = function(req: Server.Request): Server.Reply
---         if req.method ~= "GET" then return { status = 405 } end
---         return { status = 200, headers = { ["Content-Type"] = "text/plain" },
---           body = "hello\n" }
---       end,
---     })
---
--- A connection serves one request after another (keep-alive), and
--- answers requests pipelined on it in order; it closes after a reply
--- to HTTP/1.0, to `Connection: close`, with `Reply.close`, and once the server is
--- stopping; a 4xx or 5xx reply keeps it open (a handler wanting it
--- closed says `close`), unless the request's body was left unread and
--- could not be dropped (past `limits.body_bytes`, malformed, or slower
--- than `body_ns`), or the server answered for the handler: its own
--- 4xx and 5xx close the connection. It closes once idle
--- for `idle_ns` too, and at once when the server stops: a request in
--- flight then finishes, answered with `Connection: close`.
---
--- The server refuses for the handler what HTTP/1.1 (RFC 9112) says to:
--- a malformed request line or header, no Host or more than one in
--- HTTP/1.1, a request holding both Content-Length and
--- Transfer-Encoding, or a transfer coding other than a last chunked
--- (400, or 501 for a coding it does not decode); a version but 1.0 or
--- 1.1 (505); a head past `limits.head_bytes` (431); a head slower than
--- `head_ns` (408), or a body slower than `body_ns` or one of its reads
--- slower than `timeout_ns` (408); a body past `limits.body_bytes` (413, at once where the Content-Length
--- says so, before a client waiting with `Expect: 100-continue` sends
--- it); any other expectation (417). A client sending that expectation
--- is sent `100 Continue` when the handler first reads the body.
---
--- A handler that raises, or answers what [`Reply`] refuses, is
--- answered 500, and what it raised, with its stack, or why its reply
--- was refused, goes to [`Server.ServeSpec.on_error`]. A HEAD's reply is the
--- GET's head, its framing headers with it, and no body: a handler
--- answers HEAD as it would GET, and a Reader body is closed unread; or
--- it gives the size alone, as a `Content-Length` header and no body (see
--- [`Server.Request.method`]).
---
--- With `compress`, a reply is compressed for the request's
--- `Accept-Encoding`, as [`Server.encoding`] chooses: zstd, or gzip,
--- by the client's weights, or identity. The server then sets
--- `Content-Encoding`, drops the `Content-Length` (a whole body gets
--- the compressed size, a Reader goes chunked), makes a strong `ETag`
--- weak, and adds `Accept-Encoding` to `Vary`, merged into the one the
--- handler wrote; a body that compressed no smaller is sent as it was.
--- A reply is left alone, and gets no `Vary`, where it has a
--- `Content-Encoding`, a `Content-Range` or the status 206 (so a range
--- from [`Server.range`] is of the bytes the handler gave), no body, a
--- `Cache-Control: no-transform`, a body below `min_bytes` (1024) of
--- known size, or a `Content-Type` that is not text, JSON, XML,
--- JavaScript, SVG or WebAssembly (and not `text/event-stream`, whose
--- events must not wait on a compressor). A HEAD whose reply has a
--- body gets the head its GET gets; one that gives the size alone is
--- sent as given. A client that refuses identity and everything the
--- server writes is answered 406.
---
--- Every handler runs in the task of its connection, and the server
--- serves the next only while one waits on the run: a read of
--- `req.body`, a [`cosmic.net`] wait, [`Poll.delay`]. A handler that
--- blocks the thread -- [`Http.get`] to another server, a
--- [`cosmic.sqlite`] query, a long computation -- stalls every
--- connection until it returns.
-- TODO: drive curl's multi handle from Poll.run's loop (a socket and
-- timer callback per handle, waited on as a Net.Conn's descriptor is),
-- so Http.open, Http.get and Http.request in a handler wait through the
-- run rather than holding every connection.
-- TODO: let a handler compress at a level of its own, and add brotli,
-- once a caller needs either; the codings are zstd and gzip at their
-- defaults.
function Server.serve(spec: Server.ServeSpec): boolean, string
  checked_spec(spec)
  if Poll.in_task() then
    error("http: serve runs a Poll.run of its own, and cannot be called in a task of another", 2)
  end
  local listeners = spec.listeners
  assert(listeners, "http: checked_spec refuses a spec without listeners")
  local limits = spec.limits or {}
  local compress = spec.compress
  local compress_from: integer? = nil
  if compress is boolean then
    if compress then compress_from = 1024 end
  elseif compress ~= nil then
    if type(compress) ~= "table" then
      error("http: spec.compress must be nil, a boolean or a table", 2)
    end
    local min_bytes = compress.min_bytes
    if min_bytes ~= nil and not (math.type(min_bytes) == "integer" and min_bytes >= 0) then
      error("http: spec.compress.min_bytes must be nil or an integer from 0", 2)
    end
    compress_from = min_bytes or 1024
  end
  local s: Serving = {
    spec = spec,
    limits = { head_bytes = limits.head_bytes or 64 * KIB, body_bytes = limits.body_bytes or 1024 * KIB },
    timeout_ns = spec.timeout_ns or Clock.seconds(30),
    idle_ns = spec.idle_ns or Clock.seconds(5),
    head_ns = spec.head_ns or Clock.seconds(30),
    body_ns = spec.body_ns or Clock.seconds(30),
    stopping = false,
    compress_from = compress_from,
    idle = {},
  }
  return Net.serve{
    listeners = listeners,
    serve = function(conn: Net.Conn) serve_conn(s, conn) end,
    limits = { connections = limits.connections or 256 },
    timeout_ns = s.timeout_ns,
    grace_ns = spec.grace_ns,
    on_ready = spec.on_ready,
    on_stop = function(server: Net.Server)
      s.stopping = true
      local idle: mut {Net.Conn} = {}
      for conn in pairs(s.idle) do idle[#idle + 1] = conn end
      for _, conn in ipairs(idle) do local _, _ = conn:close() end
      local on_stop = spec.on_stop
      if on_stop ~= nil then on_stop(server) end
    end,
    on_error = spec.on_error,
  }
end

-- What a handler reads of a request's Range and If-None-Match, as RFC
-- 9110 sections 13 and 14 say.

--- Decimal `digits` without the zeros that lead them, but the last.
local function significant(digits: string): string
  local from = 1
  while from < #digits and digits:byte(from) == 48 do from = from + 1 end
  return digits:sub(from)
end

--- Whether the count in [`significant`] digits `a` is less than `b`'s.
local function fewer(a: string, b: string): boolean
  if #a ~= #b then return #a < #b end
  return a < b
end

local MOST <const> = tostring(math.maxinteger)

--- The count in [`significant`] `digits`, or math.maxinteger where it
--- is more: no size is, so a count compared with a size or clamped to
--- one comes out the same either way.
local function count(digits: string): integer
  if fewer(MOST, digits) then return math.maxinteger end
  return Number.integer(digits)
end

--- Reads the Range `header` of a GET (nil where it sent none) against
--- a representation of `size` bytes, as RFC 9110 section 14 says. A
--- handler of [`Server.serve`] answers what it says:
---
--- - "span": 206 with `Content-Range: bytes <first>-<last>/<size>` and
---   the `last - first + 1` bytes from `first`;
--- - "unsatisfiable": 416 with `Content-Range: bytes */<size>`;
--- - "whole": 200 with every byte, as though no Range were sent.
---
---     local r = Server.range(req.headers["range"], #data)
---     if r.kind == "span" then
---       return { status = 206, body = data:sub(r.first + 1, r.last + 1),
---         headers = { ["Content-Range"] = ("bytes %d-%d/%d"):format(r.first, r.last, #data) } }
---     end
---
--- One range is served, in each of its forms: `bytes=a-b` (`b` past
--- the end taken as the last byte), `bytes=a-` (from `a` on) and
--- `bytes=-n` (the last `n`, or every byte where there are fewer). The
--- unit is "bytes" in any case; a comma-separated list may hold empty
--- elements and spaces or tabs beside its commas, but none between
--- `=` and the range, nor within it. A server may ignore Range, and
--- this one does, answering "whole", for any other unit, a range the
--- RFC holds invalid (`b` before `a`) or that is none (a sign, a
--- space), and more than one range: it writes no
--- `multipart/byteranges`. A valid range holding none of the bytes --
--- `a` at or past `size`, or `-0` -- is "unsatisfiable". `bytes=-n`
--- of an empty representation is "whole": the RFC holds it
--- satisfiable, so no 416, yet a 206 would have no bytes to carry. A count past the largest integer is read as that integer,
--- which no size passes, so it is answered as the count it is.
---
--- Range concerns only GET, and a server ignores it for every other
--- method; a handler that honors If-Range passes nil where its
--- validator does not match. A `size` below 0
--- raises.
function Server.range(header: string?, size: integer): Server.Range
  if size < 0 then
    error("http: Server.range's size must be from 0", 2)
  end
  local unranged: Server.Range = { kind = "whole" }
  if header == nil then return unranged end
  local value = stripped(header, 1, #header)
  local equals = value:find("=", 1, true)
  if equals == nil or value:sub(1, equals - 1):lower() ~= "bytes" or ows(value:byte(equals + 1)) then
    return unranged
  end
  local spec: string? = nil
  local from = equals + 1
  while true do
    local comma = value:find(",", from, true)
    local element = stripped(value, from, if comma ~= nil then comma - 1 else #value end)
    if element ~= "" then
      if spec ~= nil then return unranged end
      spec = element
    end
    if comma == nil then break end
    from = comma + 1
  end
  if spec == nil then return unranged end
  local first_digits, last_digits = spec:match("^([0-9]+)%-([0-9]*)$")
  if first_digits ~= nil and last_digits ~= nil then
    local first_count, last_count = significant(first_digits), significant(last_digits)
    if last_digits ~= "" and fewer(last_count, first_count) then return unranged end
    local first = count(first_count)
    if first >= size then return { kind = "unsatisfiable" } end
    local last = size - 1
    if last_digits ~= "" then last = math.min(count(last_count), last) end
    return { kind = "span", first = first, last = last }
  end
  local suffix = spec:match("^%-([0-9]+)$")
  if suffix == nil then return unranged end
  local n = count(significant(suffix))
  if n == 0 then return { kind = "unsatisfiable" } end
  if size == 0 then return unranged end
  return { kind = "span", first = size - math.min(n, size), last = size - 1 }
end

local record EntityTag
  last: integer
  opaque: string
end

--- Where the entity tag that starts at `at` in `text` ends, and its
--- opaque tag, quotes and all, which a weak comparison compares; nil
--- where none starts there.
local function entity_tag(text: string, at: integer): EntityTag?
  local from = at
  if text:sub(at, at + 1) == "W/" then from = at + 2 end
  local _, last = text:find('^"[!\x23-\x7e\x80-\xff]*"', from)
  if last == nil then return nil end
  return { last = last, opaque = text:sub(from, last) }
end

--- Whether the If-None-Match `header` (nil where none was sent) names
--- `etag`, the entity tag the server sends for the representation
--- (`"v1"`, or `W/"v1"` for a weak one), as RFC 9110 section 13.1.2
--- says: `*` names any, and a list names each tag in it, compared
--- weakly -- `W/"v1"` and `"v1"` name the same. Where it does, the
--- request's condition fails, and a handler answers a GET or HEAD 304
--- Not Modified, with the ETag and no body, and any other method 412.
---
---     local etag = '"' .. version .. '"'
---     if Server.none_match(req.headers["if-none-match"], etag) then
---       return { status = 304, headers = { ETag = etag } }
---     end
---
--- `*` names a representation that exists, so a handler asks only of
--- one it has. A list element that is no entity tag names nothing, and
--- the rest are still read. An `etag` that is no entity tag raises.
function Server.none_match(header: string?, etag: string): boolean
  local own = entity_tag(etag, 1)
  if own == nil or own.last ~= #etag then
    error(("http: Server.none_match's etag %q is no entity tag, as \"v1\" or W/\"v1\""):format(etag), 2)
  end
  if header == nil then return false end
  local value = stripped(header, 1, #header)
  if value == "*" then return true end
  local at = 1
  while at <= #value do
    local b = value:byte(at)
    if b == 44 or ows(b) then
      at = at + 1
    else
      local found = entity_tag(value, at)
      local after = if found ~= nil then found.last + 1 else at end
      while ows(value:byte(after)) do after = after + 1 end
      if found ~= nil and (after > #value or value:byte(after) == 44) then
        if found.opaque == own.opaque then return true end
      else
        -- What is no entity tag runs to the next comma.
        after = value:find(",", after, true) or #value + 1
      end
      at = after
    end
  end
  return false
end

return Server
