--- HTTP/1.1 on the wire, for [`Http.serve`]: a request's head read
--- from a connection's bytes, its body decoded as the handler reads it,
--- and a reply's head and body written. It is apart from the server so
--- that what reads untrusted bytes is fuzzed on its own
--- (cosmic/http/wire_fuzz_test.tl), over any Reader and any chunking of
--- its bytes.
---
--- A head is read a line at a time, each line found in the chunk that
--- ends it, so a head sent a byte at a time costs what one sent whole
--- does; the bytes read past one request stay in the [`Input`] for the
--- next, which is how a pipelined request is kept.

local Stream = require("cosmic.stream")
local String = require("cosmic.string")
local Url = require("cosmic.url")

local record wire
  --- The bounds one request is read under.
  record Limits
    --- The most bytes of a head, its request line and blank lines before
    --- it included, and of the head with a chunked body's chunk
    --- extensions and trailers.
    head_bytes: integer
    --- The most bytes of a body, once decoded.
    body_bytes: integer
  end

  --- A connection's bytes, read ahead: what was read past one request
  --- stays here for the next.
  record Input
    --- Where the bytes come from: the connection.
    source: Stream.Reader
    --- Bytes read and not yet taken, from `at`.
    buf: string
    --- Where in `buf` the bytes not yet taken start.
    at: integer
    --- Every byte taken from it so far.
    taken: integer
    --- Set where the last line asked for passed its budget.
    long: boolean
  end

  --- A request's head, read whole.
  record Head
    --- The method, as sent.
    method: string
    --- The request target, as sent.
    target: string
    --- The target's path, still %-escaped; "*" for an OPTIONS of the
    --- server, and an absolute-form target's path ("/" when it has none).
    path: string
    --- What follows the target's first "?", "" when none.
    query: string
    --- "HTTP/1.1" or "HTTP/1.0".
    version: string
    --- By lowercased name, a repeated name's values joined with ", ".
    headers: {string:string}
    --- The Content-Length, 0 for a request with neither it nor a
    --- chunked body, nil for a chunked one.
    length: integer
    --- Whether the body is chunked.
    chunked: boolean
    --- Whether the connection closes after this request: the client
    --- said `Connection: close`, or is HTTP/1.0.
    close: boolean
    --- Whether the client waits for `100 Continue` before its body.
    continue: boolean
    --- Bytes of the head, counted against `head_bytes` with a chunked
    --- body's chunk extensions and trailers.
    spent: integer
  end

  --- What [`wire.read_head`] read: a head, or why there is none.
  record Read
    --- The head; nil where none was read.
    head: Head
    --- The status a refused request is answered with, 0 where none was
    --- refused.
    status: integer
    --- Why none was read: what was refused, or how reading failed;
    --- "" where the input ended before the request's first byte.
    why: string
  end

  --- How [`wire.send`] went.
  record Sent
    --- Whether the connection must close after the reply.
    close: boolean
    --- The writer's failure, "" for none.
    write_failure: string
    --- The Reader body's failure, "" for none.
    body_failure: string
  end

  --- How a body stands: "open" while there may be more; "done" once
  --- read to its end; "over" where it passed `body_bytes` (413); "bad"
  --- where its chunked framing is malformed (400); "failed" where the
  --- connection failed or ended before the body did.
  enum BodyState
    "open"
    "done"
    "over"
    "bad"
    "failed"
  end

  --- A request's body, decoded as it is read: a [`Stream.Reader`] that
  --- fails, and says how in `state`, past `body_bytes` or on framing it
  --- cannot read.
  interface Body is Stream.Reader
    --- How the body stands.
    state: BodyState
    --- Why it failed, as every read after answers; "" until then.
    failure: string
    --- Called once, before the first byte is read from the connection:
    --- where the server sends `100 Continue`.
    on_first_read: function()
    --- Whether anything was asked of it yet.
    touched: boolean
    --- Reads to the end, discarding: true once the body is done, false
    --- where it is over, bad or failed.
    drain: function(Body): boolean
  end

  --- A reply to write, checked by [`wire.check`] first.
  record Reply
    --- The status, from 100 to 999.
    status: integer
    --- Name to value, written as given, in name order, but for a
    --- Content-Length (any case of the name), which is the body's size
    --- as `length` is, and is written as the server frames the body.
    headers: {string:string}
    --- nil for none, a string, or a Reader, which [`wire.send`] closes.
    body: string | Stream.Reader
    --- The body's size: a string's own, a Reader's, or, with no body,
    --- 0, but for a HEAD the size of a GET's body, and for a 304 a
    --- 200's. A Reader without it goes chunked to an HTTP/1.1 client,
    --- and to an HTTP/1.0 one until the connection closes.
    length: integer
    --- Whether the connection closes after the reply.
    close: boolean
    --- The request's method; nil is taken for one that is not HEAD.
    method: string
    --- The request's version.
    version: string
    --- The Date header's value.
    date: string
  end
end

--- What a single read of the source asks for at most.
local CHUNK <const> = 64 * 1024

--- Characters of a token (RFC 9110 5.6.2): a method, a header's name.
local TOKEN <const> = "^[%w!#$%%&'*+%-.^_`|~]+$"

--- A byte no header value holds: a control other than HTAB, or DEL.
local VALUE_CONTROL <const> = "[%z\1-\8\10-\31\127]"

--- The reason phrase of each status this server names.
local REASONS <const>: {integer:string} = {
  [100] = "Continue", [101] = "Switching Protocols",
  [200] = "OK", [201] = "Created", [202] = "Accepted", [203] = "Non-Authoritative Information",
  [204] = "No Content", [205] = "Reset Content", [206] = "Partial Content",
  [300] = "Multiple Choices", [301] = "Moved Permanently", [302] = "Found", [303] = "See Other",
  [304] = "Not Modified", [307] = "Temporary Redirect", [308] = "Permanent Redirect",
  [400] = "Bad Request", [401] = "Unauthorized", [403] = "Forbidden", [404] = "Not Found",
  [405] = "Method Not Allowed", [406] = "Not Acceptable", [408] = "Request Timeout",
  [409] = "Conflict", [410] = "Gone", [411] = "Length Required", [412] = "Precondition Failed",
  [413] = "Content Too Large", [414] = "URI Too Long", [415] = "Unsupported Media Type",
  [416] = "Range Not Satisfiable", [417] = "Expectation Failed", [421] = "Misdirected Request",
  [422] = "Unprocessable Content", [426] = "Upgrade Required", [428] = "Precondition Required",
  [429] = "Too Many Requests", [431] = "Request Header Fields Too Large",
  [500] = "Internal Server Error", [501] = "Not Implemented", [502] = "Bad Gateway",
  [503] = "Service Unavailable", [504] = "Gateway Timeout", [505] = "HTTP Version Not Supported",
}

--- The headers the server writes itself, by lowercased name. It writes
--- Content-Length too, but a reply may give one, which [`wire.check`]
--- holds to the body.
local OWNED <const>: {string:boolean} = {
  date = true, ["transfer-encoding"] = true, connection = true,
}

--- `status`'s reason phrase, "" for one this server does not name.
function wire.reason(status: integer): string
  return REASONS[status] or ""
end

--- An Input over `source`, holding nothing read yet.
function wire.input(source: Stream.Reader): wire.Input
  return { source = source, buf = "", at = 1, taken = 0, long = false }
end

--- Whether `input` holds bytes read and not taken.
function wire.buffered(input: wire.Input): boolean
  return input.at <= #input.buf
end

--- Reads one chunk into `input` when it holds none: true once it holds
--- bytes, or false and "" at the source's end, or false and why.
function wire.fill(input: wire.Input): boolean, string
  if wire.buffered(input) then return true, "" end
  local chunk, why = input.source:read(CHUNK)
  if chunk == nil then return false, why end
  input.buf, input.at = chunk, 1
  return true, ""
end

--- Up to `most` bytes, from what is held first, then from the source:
--- nil and "" at its end, or nil and why.
local function take(input: wire.Input, most: integer): string | nil, string
  if wire.buffered(input) then
    local piece = input.buf:sub(input.at, input.at + most - 1)
    input.at = input.at + #piece
    input.taken = input.taken + #piece
    return piece, ""
  end
  local chunk, why = input.source:read(math.min(most, CHUNK))
  if chunk == nil then return nil, why end
  input.taken = input.taken + #chunk
  return chunk, ""
end

--- The next line, its LF taken and not answered, a CR before it kept:
--- nil and why once it would take more than `budget` bytes with its
--- LF, `input.long` set; nil and "" where the source ends first, or nil
--- and why. Each chunk read is searched once, so a line costs its
--- length however it arrives.
local function line(input: wire.Input, budget: integer): string | nil, string
  local parts: {string} = {}
  local size = 0
  input.long = false
  while true do
    local buf, at = input.buf, input.at
    local lf = buf:find("\n", at, true)
    local stop = lf or #buf + 1
    size = size + (stop - at) + (lf ~= nil and 1 or 0)
    if size > budget then
      input.long = true
      return nil, "a line passes the bytes left of limits.head_bytes"
    end
    parts[#parts + 1] = buf:sub(at, stop - 1)
    input.taken = input.taken + (stop - at) + (lf ~= nil and 1 or 0)
    if lf ~= nil then
      input.at = lf + 1
      return table.concat(parts), ""
    end
    input.buf, input.at = "", 1
    local chunk, why = input.source:read(CHUNK)
    if chunk == nil then return nil, why end
    input.buf = chunk
  end
end

--- `text` without a CR at its end, or nil where it holds a CR anywhere
--- else: a bare CR, which no line of HTTP holds.
local function without_cr(text: string): string | nil
  if text:sub(-1) == "\r" then text = text:sub(1, -2) end
  if text:find("\r", 1, true) then return nil end
  return text
end

--- A header line read.
local record Field
  --- Lowercased.
  name: string
  --- With the spaces around it trimmed.
  value: string
end

--- `text` without the spaces and tabs at either end. A pattern's
--- `^[ \t]*(.-)[ \t]*$` would do as much, in time that grows with the
--- square of a run of spaces: a head of nothing else would cost seconds.
local function trimmed(text: string): string
  local first = text:find("[^ \t]")
  if first == nil then return "" end
  local last = #text
  while true do
    local byte = text:byte(last)
    if byte ~= 32 and byte ~= 9 then break end
    last = last - 1
  end
  return text:sub(first, last)
end

--- One header line as a [`Field`]; nil and why where it is no header
--- line.
local function field(text: string): Field | nil, string
  local first = text:sub(1, 1)
  if first == " " or first == "\t" then
    return nil, "a header line is folded (obs-fold)"
  end
  local colon = text:find(":", 1, true)
  if colon == nil then return nil, "a header line holds no ':'" end
  local name = text:sub(1, colon - 1)
  if not name:find(TOKEN) then
    return nil, "a header's name is no token (space before ':'?)"
  end
  local value = trimmed(text:sub(colon + 1))
  if value:find(VALUE_CONTROL) then
    return nil, "header " .. name .. " holds a control byte"
  end
  return { name = name:lower(), value = value }, ""
end

--- A refusal's status and why, where there is no head to answer.
local function refused(status: integer, why: string): wire.Read
  return { status = status, why = why }
end

--- The comma-separated members of a header's value, trimmed, the
--- empty ones dropped.
local function members(value: string): {string}
  local out: {string} = {}
  for member in value:gmatch("[^,]+") do
    local bare = trimmed(member)
    if bare ~= "" then out[#out + 1] = bare end
  end
  return out
end

--- The size a Content-Length's digits name, `math.maxinteger` for one
--- past what an integer holds; nil where they are no digits.
local function decimal(digits: string): integer | nil
  if not digits:find("^%d+$") then return nil end
  digits = digits:gsub("^0+", "")
  if digits == "" then return 0 end
  if #digits > 18 then return math.maxinteger end
  return math.tointeger(tonumber(digits))
end

--- A request target's path and query.
local record Target
  path: string
  query: string
  --- An absolute-form target's host, and port when it names one; nil
  --- for another form.
  authority: string
end

--- The request line's target as a [`Target`], or nil and why.
local function target_parts(method: string, target: string): Target | nil, string
  if target == "*" then
    if method ~= "OPTIONS" then return nil, "the target * is for OPTIONS alone" end
    return { path = "*", query = "" }, ""
  end
  if not target:find("^[!-\"$-~]+$") then
    return nil, "the target holds a byte no URL holds, or a '#'"
  end
  if target:sub(1, 1) ~= "/" then
    local parts, why = Url.parse(target)
    if parts == nil then return nil, "the target is neither a path nor an absolute URL: " .. why end
    if parts.scheme ~= "http" and parts.scheme ~= "https" then
      return nil, "an absolute target's scheme is not http or https"
    end
    if parts.userinfo ~= nil then return nil, "an absolute target holds userinfo" end
    local host = parts.host:find(":", 1, true) and "[" .. parts.host .. "]" or parts.host
    return { path = parts.path ~= "" and parts.path or "/", query = parts.query or "",
      authority = parts.port ~= nil and host .. ":" .. parts.port or host }, ""
  end
  local mark = target:find("?", 1, true)
  if mark == nil then return { path = target, query = "" }, "" end
  return { path = target:sub(1, mark - 1), query = target:sub(mark + 1) }, ""
end

--- Reads one request's head from `input`, leaving its body and anything
--- after where they are. Answers the head; or a status and why for one
--- refused -- 400 malformed, 413 a Content-Length past `body_bytes`, 417
--- an expectation other than 100-continue, 431 past `head_bytes`, 501 a
--- transfer coding other than chunked, 505 a version other than 1.0 or
--- 1.1; or, with status 0, why reading
--- failed, "" where the source ended before the request's first byte.
function wire.read_head(input: wire.Input, limits: wire.Limits): wire.Read
  local start = input.taken
  local stop: wire.Read = nil
  --- The next line of the head, without its CR; nil, `stop` set, where
  --- there is none.
  local function next_line(): string | nil
    local text, why = line(input, limits.head_bytes - (input.taken - start))
    if text == nil then
      if input.long then
        stop = refused(431, "the head is longer than limits.head_bytes")
      elseif why ~= "" then
        stop = refused(0, why)
      elseif input.taken == start then
        stop = refused(0, "")
      else
        stop = refused(0, "the connection ended within a head")
      end
      return nil
    end
    local bare = without_cr(text)
    if bare == nil then stop = refused(400, "a line holds a bare CR") end
    return bare
  end
  -- A blank line or more before the request line is passed over (RFC
  -- 9112 2.2).
  local request_line: string
  repeat
    request_line = next_line()
    if request_line == nil then return stop end
  until request_line ~= ""
  local method, target, version = request_line:match("^([^ ]+) ([^ ]+) ([^ ]+)$")
  if method == nil then
    return refused(400, "the request line is not method, target and version")
  end
  if not method:find(TOKEN) then return refused(400, "the method is no token") end
  if not version:find("^HTTP/%d%.%d$") then return refused(400, "the version is not HTTP/d.d") end
  if version ~= "HTTP/1.1" and version ~= "HTTP/1.0" then
    return refused(505, "this server speaks HTTP/1.1 and HTTP/1.0")
  end
  local parts, target_why = target_parts(method, target)
  if parts == nil then return refused(400, target_why) end
  -- Each name's values, joined once the head is read: joined as each
  -- came, a name repeated through the head would cost the square of it.
  local values: {string:{string}} = {}
  local names: {string} = {}
  while true do
    local text = next_line()
    if text == nil then return stop end
    if text == "" then break end
    local got, why = field(text)
    if got == nil then return refused(400, why) end
    local list = values[got.name]
    if list == nil then
      list = {}
      values[got.name] = list
      names[#names + 1] = got.name
    end
    list[#list + 1] = got.value
  end
  local headers: {string:string} = {}
  for _, name in ipairs(names) do headers[name] = table.concat(values[name], ", ") end
  local spent = input.taken - start
  local hosts = values["host"] ~= nil and #values["host"] or 0
  if hosts > 1 or (version == "HTTP/1.1" and hosts == 0) then
    return refused(400, "an HTTP/1.1 request names exactly one Host")
  end
  local length: integer = 0
  local chunked = false
  local te = headers["transfer-encoding"]
  local cl = headers["content-length"]
  if te ~= nil then
    if cl ~= nil then
      return refused(400, "a request holds both Content-Length and Transfer-Encoding")
    end
    if version == "HTTP/1.0" then
      return refused(400, "an HTTP/1.0 request holds Transfer-Encoding")
    end
    local codings = members(te:lower())
    if codings[#codings] ~= "chunked" then
      return refused(400, "a request's last transfer coding is not chunked")
    end
    for i = 1, #codings - 1 do
      if codings[i] == "chunked" then return refused(400, "a request is chunked twice") end
    end
    if #codings > 1 then
      return refused(501, "this server decodes no transfer coding but chunked")
    end
    chunked, length = true, nil
  elseif cl ~= nil then
    -- Repeated, or a list, its values must agree (RFC 9112 6.3).
    local lengths = members(cl)
    if #lengths == 0 then return refused(400, "Content-Length is empty") end
    local first = decimal(lengths[1])
    for _, value in ipairs(lengths) do
      local n = decimal(value)
      if n == nil then return refused(400, "Content-Length is not digits") end
      if n ~= first then return refused(400, "Content-Length's values differ") end
    end
    length = first
    if length > limits.body_bytes then
      return refused(413, "the body is longer than limits.body_bytes")
    end
  end
  local close = version == "HTTP/1.0"
  for _, option in ipairs(members((headers["connection"] or ""):lower())) do
    if option == "close" then close = true end
  end
  local continue = false
  local expect = headers["expect"]
  if version == "HTTP/1.1" and expect ~= nil then
    for _, expectation in ipairs(members(expect:lower())) do
      if expectation ~= "100-continue" then
        return refused(417, "this server meets no expectation but 100-continue")
      end
      continue = true
    end
  end
  -- An absolute-form target names the host, and Host is replaced by it
  -- (RFC 9112 3.2.2).
  if parts.authority ~= nil then headers["host"] = parts.authority end
  return { status = 0, why = "", head = {
    method = method, target = target, path = parts.path, query = parts.query, version = version,
    headers = headers, length = length, chunked = chunked, close = close,
    continue = continue, spent = spent,
  } }
end

-- The Body over Content-Length and over chunked framing are records of
-- their own, as a Stream's Readers are (see the note on objects in
-- cosmic/stream.tl).

local record BodyReader is wire.Body
  input: wire.Input
  limits: wire.Limits
  head: wire.Head
  --- Bytes left of the Content-Length, or of the chunk being read.
  left: integer
  --- Chunked only: "size", "data", "data end", "trailers".
  phase: string
  --- Bytes of the body read so far.
  total: integer
  failure: string
  closed: boolean
  read: function(BodyReader, max_bytes?: integer): string | nil, string
  close: function(BodyReader): boolean, string
  drain: function(BodyReader): boolean
end

local body_reader_mt: metatable<BodyReader> = { __index = BodyReader }

--- Fails the body for good: `state` says how, `why` what every later
--- read answers.
local function fail(self: BodyReader, state: wire.BodyState, why: string): nil, string
  self.state, self.failure = state, why
  return nil, why
end

--- [`fail`], answered as a step that did not go.
local function stopped(self: BodyReader, state: wire.BodyState, why: string): boolean, string
  self.state, self.failure = state, why
  return false, why
end

--- A chunked body's next line, ended by CRLF: a bare LF, which a
--- proxy before this server may read otherwise, is refused here though
--- a head may hold one. No line passes `head_bytes`, and `spent` counts
--- a trailer against it, and a size line's extension and the zeros
--- before its size ([`next_chunk`]), but not the framing every chunk
--- has, so many small chunks pass as one large one does.
local function meta_line(self: BodyReader): string | nil, string
  local text, why = line(self.input, self.limits.head_bytes)
  if text == nil then
    if self.input.long then
      return fail(self, "over", "http: a chunked body's extensions and trailers pass limits.head_bytes")
    end
    return fail(self, "failed", why ~= "" and why or "http: the request body ended early")
  end
  if text:sub(-1) ~= "\r" then
    return fail(self, "bad", "http: a chunked body's line ends in a bare LF")
  end
  local bare = without_cr(text)
  if bare == nil then return fail(self, "bad", "http: a chunked body holds a bare CR") end
  return bare, ""
end

--- Reads the next chunked size line, `left` and `phase` set from it:
--- true, or false and why where it fails.
local function next_chunk(self: BodyReader): boolean, string
  local text, why = meta_line(self)
  if text == nil then return false, why end
  local hex, rest = text:match("^(%x+)(.*)$")
  if hex == nil then return stopped(self, "bad", "http: a chunk's size is not hex") end
  if rest ~= "" and (not rest:find("^[ \t]*;") or rest:find(VALUE_CONTROL)) then
    return stopped(self, "bad", "http: a chunk's extension is malformed")
  end
  -- Zeros before a size are counted too: a size line of nothing else
  -- would otherwise carry a head's worth of bytes for each byte of body.
  local digits = #hex
  hex = hex:gsub("^0+", "")
  self.head.spent = self.head.spent + #rest + math.max(digits - #hex - 1, 0)
  if self.head.spent > self.limits.head_bytes then
    return stopped(self, "over", "http: a chunked body's extensions and trailers pass limits.head_bytes")
  end
  if #hex > 15 then
    return stopped(self, "over", "http: the body is longer than limits.body_bytes")
  end
  local size = hex == "" and 0 or math.tointeger(tonumber(hex, 16))
  if size == 0 then
    self.phase = "trailers"
    return true, ""
  end
  if size > self.limits.body_bytes - self.total then
    return stopped(self, "over", "http: the body is longer than limits.body_bytes")
  end
  self.left, self.phase = size, "data"
  return true, ""
end

--- Reads a chunked body's trailers, checked as header lines and
--- dropped: true at the blank line after them, or false and why.
local function trailers(self: BodyReader): boolean, string
  while true do
    local text, why = meta_line(self)
    if text == nil then return false, why end
    if text == "" then
      self.state = "done"
      return true, ""
    end
    self.head.spent = self.head.spent + #text + 2
    if self.head.spent > self.limits.head_bytes then
      return stopped(self, "over", "http: a chunked body's extensions and trailers pass limits.head_bytes")
    end
    local got, field_why = field(text)
    if got == nil then
      return stopped(self, "bad", "http: a trailer is malformed: " .. field_why)
    end
  end
end

function BodyReader:read(max_bytes?: integer): string | nil, string
  if self.closed then return nil, "http: the request body is closed" end
  if self.failure ~= "" then return nil, self.failure end
  if self.state == "done" then return nil, "" end
  local most = max_bytes or CHUNK
  if most < 1 then error("http: read's max_bytes must be positive", 2) end
  if not self.touched then
    self.touched = true
    if self.on_first_read ~= nil then self.on_first_read() end
  end
  if not self.head.chunked then
    if self.left == 0 then
      self.state = "done"
      return nil, ""
    end
    local piece, why = take(self.input, math.min(most, self.left))
    if piece == nil then
      return fail(self, "failed", why ~= "" and why or "http: the request body ended early")
    end
    self.left = self.left - #piece
    self.total = self.total + #piece
    if self.left == 0 then self.state = "done" end
    return piece, ""
  end
  while true do
    if self.phase == "size" then
      local ok, why = next_chunk(self)
      if not ok then return nil, why end
    elseif self.phase == "data" then
      local piece, why = take(self.input, math.min(most, self.left))
      if piece == nil then
        return fail(self, "failed", why ~= "" and why or "http: the request body ended early")
      end
      self.left = self.left - #piece
      self.total = self.total + #piece
      if self.left == 0 then self.phase = "data end" end
      return piece, ""
    elseif self.phase == "data end" then
      local text, why = meta_line(self)
      if text == nil then return nil, why end
      if text ~= "" then return fail(self, "bad", "http: a chunk's data runs past its size") end
      self.phase = "size"
    else
      local ok, why = trailers(self)
      if not ok then return nil, why end
      return nil, ""
    end
  end
end

--- Closing the body leaves the connection be: what of it is unread,
--- the server discards before the next request.
function BodyReader:close(): boolean, string
  self.closed = true
  return true, ""
end

function BodyReader:drain(): boolean
  -- Read past a close: the server discards what the handler left.
  local closed = self.closed
  self.closed = false
  while self.state == "open" do
    local piece, _ = self:read()
    if piece == nil then break end
  end
  self.closed = closed
  return self.state == "done"
end

--- The body of the request `head` describes, read from `input` as the
--- caller reads it: no byte is taken from the connection before the
--- first read, which calls `on_first_read` (nil for none).
function wire.body(input: wire.Input, head: wire.Head, limits: wire.Limits,
                   on_first_read?: function()): wire.Body
  local r: BodyReader = setmetatable({
    input = input, limits = limits, head = head, left = head.length or 0,
    phase = "size", total = 0, failure = "", closed = false, touched = false,
    on_first_read = on_first_read,
    state = (not head.chunked and (head.length or 0) == 0) and "done" or "open",
  }, body_reader_mt)
  return r
end

--- Why the server cannot send `headers` as given, or "": a name that is
--- no token, a value holding CR, LF or NUL, or a header the server
--- writes itself.
local function headers_trouble(headers: {string:string}): string
  for name, value in pairs(headers) do
    if not name:find(TOKEN) then return ("header %q: its name is no token"):format(name) end
    if value:find("[\r\n%z]") then
      return ("header %s: its value holds CR, LF or NUL"):format(name)
    end
    if OWNED[name:lower()] then return ("header %s: the server writes it itself"):format(name) end
  end
  return ""
end

--- Whether a reply of `status` carries no body: a 1xx, 204 or 304.
local function bodiless(status: integer): boolean
  return status < 200 or status == 204 or status == 304
end

--- The size a reply's Content-Length header gives, under any case of
--- its name, nil for none; or nil and why it cannot be sent: no digits,
--- a size past 18 of them, or the name given twice in different cases.
local function given_length(headers: {string:string}): integer | nil, string
  local names: {string} = {}
  for name in pairs(headers) do
    if name:lower() == "content-length" then names[#names + 1] = name end
  end
  if #names == 0 then return nil, "" end
  if #names > 1 then
    table.sort(names)
    return nil, ("headers %s: Content-Length is given twice"):format(table.concat(names, " and "))
  end
  local name, value = names[1], headers[names[1]]
  local size = decimal(value)
  if size == nil then return nil, ("header %s: %q is not digits"):format(name, value) end
  if size == math.maxinteger then return nil, ("header %s: %s is too large"):format(name, value) end
  return size, ""
end

--- The size `reply`, which [`wire.check`] passed, declares: its
--- Content-Length header's or its `length`, nil for neither.
local function declared(reply: wire.Reply): integer | nil
  local size, _ = given_length(reply.headers or {})
  return size or reply.length
end

--- Why `reply` cannot be sent, or "": a status outside 100 to 999, a
--- header [`headers_trouble`] refuses, a body given to a 1xx, 204 or
--- 304, or a size it declares, by Content-Length or `length`, that is
--- below 0, that the two give differently, that a 1xx or 204 is given
--- (RFC 9110 8.6), or that is not the body's: a string's own length, or
--- 0 where there is no body (nil or ""), but to HEAD, whose size is the
--- GET's. A 304's is the size of a 200's body, as RFC 9110 8.6 asks,
--- which no body here shows, and is passed on as given.
function wire.check(reply: wire.Reply): string
  local status = reply.status
  if status < 100 or status > 999 then return "the status is not from 100 to 999" end
  local headers = reply.headers or {}
  local trouble = headers_trouble(headers)
  if trouble ~= "" then return trouble end
  local given, why = given_length(headers)
  if why ~= "" then return why end
  local length = reply.length
  if length ~= nil and length < 0 then return "the length is below 0" end
  if given ~= nil and length ~= nil and given ~= length then
    return ("the Content-Length header is %d, but the length is %d"):format(given, length)
  end
  local size = given or length
  local body = reply.body
  if body == "" then body = nil end
  if bodiless(status) then
    if body ~= nil then return ("no body goes with status %d"):format(status) end
    if size ~= nil and status ~= 304 then
      return ("no Content-Length goes with status %d"):format(status)
    end
    return ""
  end
  if size == nil then return "" end
  if body is string then
    if size ~= #body then
      return ("the Content-Length is %d, but the body is %s"):format(size, String.counted(#body, "byte"))
    end
  elseif body == nil and size ~= 0 and reply.method ~= "HEAD" then
    return ("the Content-Length is %d, but the reply has no body: only a reply to HEAD gives a size" ..
      " without its bytes"):format(size)
  end
  return ""
end

--- How a reply is framed: the Content-Length to write (nil for none),
--- whether it goes chunked, and whether the connection closes after it.
local function framing(reply: wire.Reply): integer | nil, boolean, boolean
  local close = reply.close == true
  local size = declared(reply)
  if bodiless(reply.status) then return reply.status == 304 and size or nil, false, close end
  local body = reply.body
  if body == nil or body == "" then return size or 0, false, close end
  if body is string then return #body, false, close end
  if size ~= nil then return size, false, close end
  if reply.version == "HTTP/1.1" then return nil, true, close end
  -- An HTTP/1.0 client reads no chunks: the body ends where the
  -- connection does.
  return nil, false, true
end

--- The head of `reply`, framed by `length` and `chunked`.
local function head_text(reply: wire.Reply, length: integer | nil, chunked: boolean,
                         close: boolean): string
  local lines: {string} = {
    ("HTTP/1.1 %d %s"):format(reply.status, wire.reason(reply.status)),
    "Date: " .. reply.date,
  }
  local names: {string} = {}
  for name in pairs(reply.headers or {}) do
    if name:lower() ~= "content-length" then names[#names + 1] = name end
  end
  table.sort(names)
  for _, name in ipairs(names) do lines[#lines + 1] = name .. ": " .. reply.headers[name] end
  if length ~= nil then lines[#lines + 1] = "Content-Length: " .. length end
  if chunked then lines[#lines + 1] = "Transfer-Encoding: chunked" end
  if close then lines[#lines + 1] = "Connection: close" end
  return table.concat(lines, "\r\n") .. "\r\n\r\n"
end

--- Copies a Reader body to `w` as `length` bytes, as chunks, or until
--- it ends: "" and "" once sent; the writer's failure first, or the
--- Reader's second, where one failed. A Reader that ends short of
--- `length`, or fails, cuts the reply short.
local function copy_body(w: Stream.Writer, body: Stream.Reader, length: integer | nil,
                         chunked: boolean): string, string
  local left = length
  while left == nil or left > 0 do
    local piece, why = body:read(left ~= nil and math.min(left, CHUNK) or CHUNK)
    if piece == nil then
      if why ~= "" then return "", why end
      if left ~= nil then
        return "", "the reply body ended " .. String.counted(left, "byte") .. " short of its length"
      end
      break
    end
    -- What the Reader contract rules out, a user's Reader may still do:
    -- an empty chunk would end a chunked body early, and one longer than
    -- asked for run past the Content-Length, the bytes after read as a
    -- reply of their own.
    if piece == "" then return "", "the reply body's Reader gave an empty chunk" end
    if left ~= nil and #piece > left then
      return "", "the reply body's Reader gave more bytes than asked for"
    end
    if left ~= nil then left = left - #piece end
    local ok, write_why: boolean, string
    if chunked then
      ok, write_why = w:write(("%x\r\n"):format(#piece) .. piece .. "\r\n")
    else
      ok, write_why = w:write(piece)
    end
    if not ok then return write_why, "" end
  end
  if chunked then
    local ok, why = w:write("0\r\n\r\n")
    if not ok then return why, "" end
  end
  return "", ""
end

--- Writes `reply`, which [`wire.check`] passed, to `w`, and closes its
--- Reader body, if any. A HEAD's reply has the head a GET's would and
--- no body; a 1xx, 204 or 304 has no body, and a Content-Length only
--- where a 304 gives one.
--- A reply cut short, by the writer or the Reader body failing, closes
--- the connection.
function wire.send(w: Stream.Writer, reply: wire.Reply): wire.Sent
  local length, chunked, close = framing(reply)
  local head = head_text(reply, length, chunked, close)
  local body = reply.body
  local reader: Stream.Reader = nil
  if body ~= nil and not body is string then reader = body end
  local write_why, body_why = "", ""
  if reply.method == "HEAD" or bodiless(reply.status) then
    local ok, why = w:write(head)
    if not ok then write_why = why end
  elseif reader == nil then
    local ok, why = w:write(body is string and head .. body or head)
    if not ok then write_why = why end
  else
    local ok, why = w:write(head)
    if not ok then
      write_why = why
    else
      write_why, body_why = copy_body(w, reader, length, chunked)
    end
  end
  if reader ~= nil then local _, _ = reader:close() end
  return { close = close or write_why ~= "" or body_why ~= "", write_failure = write_why,
    body_failure = body_why }
end

return wire
