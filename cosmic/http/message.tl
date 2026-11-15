--- HTTP/1.1 messages as bytes, for a program that owns its connection:
--- a channel it encrypts itself, a socket it was handed, or a protocol
--- with HTTP's message grammar under another name, as RTSP/1.0 is.
--- [`cosmic.http`] and [`cosmic.http.server`] own theirs. A reader here
--- is fed the bytes as they arrive and answers one message (a request,
--- a response, or with [`Message.reader`] either, as its first line
--- says), and [`Message.format_request`] and [`Message.format_response`]
--- write one.
--- Nothing here opens, reads or writes a connection.
---
---     local reader = Message.request_reader()
---     local read = reader:feed(bytes)
---     while read.status == "more" do read = reader:feed(more_bytes()) end
---     local request = assert(read.request, read.reason)
---
--- A reader reads one message. `feed` answers `more` until the bytes
--- decide it, then `done` with the message, `consumed` (the count of
--- bytes, of all fed, that it took) and `next` (where in the last chunk
--- fed the bytes after it start, which are the next message's: feed the
--- chunk from there to a new reader), or `refused` and why. `finish`
--- says the stream ended: it answers an HTTP response that is read to
--- the end of the stream, `empty` where no message began (nothing came,
--- or blank lines alone), and a refusal where one was cut short. An
--- answer but `more` is final, and every later call gives it again, its `next`
--- still a position in the chunk that decided it.
---
--- The bytes are not trusted. A reader never raises on them, does work
--- linear in the bytes fed, holds no more than its limits allow
--- ([`Message.Options`]), and answers the same status, reason, message
--- and `consumed` wherever the feeds split.
--- Blank lines before the first line are passed over (RFC 9112 2.2).
--- It refuses what two readers could read differently:
---
--- - a line that does not end in CRLF, and a bare CR;
--- - a first line that is not `method target protocol` or `protocol
---   status reason`, a method that is no token, a target that holds a
---   byte outside visible ASCII, a status that is not three digits from
---   100, and a protocol other than those asked for;
--- - a header line that is folded, has no `:`, has a name that is no
---   token (a space before the `:` too) or a value that holds a control
---   byte other than a tab;
--- - a `Content-Length` that is empty or not digits, or whose values
---   differ, and one together with `Transfer-Encoding`;
--- - a `Transfer-Encoding` other than `chunked` alone, or in a message
---   that is not HTTP/1.1, and a chunked body whose size, extension,
---   line ends or trailers are malformed;
--- - a head, a line, a count of headers or a body past its limit.
---
--- A list's empty members are dropped, as RFC 9110 5.6.1.2 has a
--- recipient do: `Transfer-Encoding: chunked,` is chunked, and
--- `Content-Length: 3,` is 3.
---
--- A message's body is the `Content-Length` bytes after its head, or
--- its chunks decoded (the trailers checked and dropped). With neither,
--- a request has no body, and so has a response of any protocol but
--- HTTP, as RTSP has it (RFC 2326 12.14, RFC 7826 18.17); an HTTP
--- response's body is then every byte up to the end of the stream (RFC
--- 9112 6.3). A response with a status below 200, 204 or 304, and one
--- read with `head_only`, has no body whatever its headers say.
---
--- The protocol is a parameter: a reader made with `protocol =
--- "RTSP/1.0"` reads RTSP/1.0 messages and no other, and the default,
--- HTTP/1.1, reads HTTP/1.0 too. One made with `protocols = {"RTSP/1.0",
--- "HTTP/1.1"}` reads any of them, as a connection that carries both
--- does, and each message is framed by the protocol it names, which the
--- message read holds. Only the name differs: methods and headers keep
--- HTTP's grammar, and nothing else of another protocol is read (RTSP's
--- interleaved binary frames are not). A reader holds no rule of HTTP
--- above the message: a server that needs one `Host`, or a target of a
--- given form, checks it in what the reader answers.
--- @public

local String = require("cosmic.string")
local wire = require("cosmic.http.wire")

local record Message
  --- What a reader has decided so far.
  enum Status
    "more"
    "done"
    "refused"
    "empty"
  end

  --- Which kind of message was read.
  enum Kind
    "request"
    "response"
  end

  --- What a reader is made with.
  record Options
    --- The protocol's name and version, "HTTP/1.1" when nil. A reader of
    --- "HTTP/1.1" reads "HTTP/1.0" messages too; any other reads its own
    --- alone.
    protocol?: string
    --- In place of `protocol`, the names of every protocol read, each as
    --- `protocol` would read it: `{"RTSP/1.0", "HTTP/1.1"}` reads RTSP/1.0,
    --- HTTP/1.1 and HTTP/1.0. Giving both, or an empty list, raises.
    protocols?: {string}
    --- Most bytes of a head, with the blank lines before it, and of the
    --- head with a chunked body's extensions and trailers (64 KiB).
    head_bytes?: integer
    --- Most bytes of one line, its CRLF included (8 KiB).
    line_bytes?: integer
    --- Most header lines (100).
    max_headers?: integer
    --- Most bytes of a body, once decoded (1 MiB).
    body_bytes?: integer
    --- Of a response alone: the response answers a HEAD, or a CONNECT
    --- that was accepted, so its head is all of it.
    head_only?: boolean
  end

  --- A request read.
  record Request
    --- The method, as sent.
    method: string
    --- The request target, as sent.
    target: string
    --- The protocol and version, as sent.
    protocol: string
    --- By lowercased name, a repeated name's values joined with ", ",
    --- but a repeated `cookie`'s with "; " (RFC 6265 5.4).
    headers: {string:string}
    --- By lowercased name, each line's value apart, in the order sent:
    --- for a header whose values cannot be joined (`Set-Cookie`).
    values: {string:{string}}
    --- The body, decoded; "" for none.
    body: string
  end

  --- A response read.
  record Response
    --- The protocol and version, as sent.
    protocol: string
    --- The status, from 100 to 999.
    status: integer
    --- The reason phrase, "" for none.
    reason: string
    --- As [`Message.Request.headers`].
    headers: {string:string}
    --- As [`Message.Request.values`].
    values: {string:{string}}
    --- The body, decoded; "" for none.
    body: string
  end

  --- What a [`Message.RequestReader`] answers.
  record RequestRead
    --- How far the bytes have decided it.
    status: Status
    --- The request, when `done`.
    request?: Request
    --- When `done`, the bytes of everything fed that the request took;
    --- 0 until then.
    consumed: integer
    --- When `done` by a feed, where in the chunk fed the bytes after the
    --- request start, past its end where it took them all; 1 otherwise.
    next: integer
    --- When `refused`, why; "" otherwise.
    reason: string
  end

  --- What a [`Message.ResponseReader`] answers.
  record ResponseRead
    --- How far the bytes have decided it.
    status: Status
    --- The response, when `done`.
    response?: Response
    --- As [`Message.RequestRead.consumed`].
    consumed: integer
    --- As [`Message.RequestRead.next`].
    next: integer
    --- When `refused`, why; "" otherwise.
    reason: string
  end

  --- What a [`Message.Reader`] answers.
  record Read
    --- How far the bytes have decided it.
    status: Status
    --- When `done`, which kind the message is: `request` is set for a
    --- request and `response` for a response.
    kind?: Kind
    --- The request, when `done` with one.
    request?: Request
    --- The response, when `done` with one.
    response?: Response
    --- As [`Message.RequestRead.consumed`].
    consumed: integer
    --- As [`Message.RequestRead.next`].
    next: integer
    --- When `refused`, why; "" otherwise.
    reason: string
  end

  --- Reads one request from the bytes fed to it.
  record RequestReader
    --- Feeds the next bytes, `chunk` from the position `from` (1 when
    --- nil), and answers what all fed so far say.
    feed: function(RequestReader, chunk: string, from?: integer): RequestRead
    --- Says the stream ended: `empty` where no request began, a refusal
    --- where one was cut short.
    finish: function(RequestReader): RequestRead
  end

  --- Reads one response from the bytes fed to it.
  record ResponseReader
    --- As [`Message.RequestReader.feed`].
    feed: function(ResponseReader, chunk: string, from?: integer): ResponseRead
    --- Says the stream ended: `done` for a response whose body is every
    --- byte up to there, `empty` where no response began, a refusal
    --- where one was cut short.
    finish: function(ResponseReader): ResponseRead
  end

  --- Reads one message of either kind from the bytes fed to it.
  record Reader
    --- As [`Message.RequestReader.feed`].
    feed: function(Reader, chunk: string, from?: integer): Read
    --- As [`Message.ResponseReader.finish`].
    finish: function(Reader): Read
  end

  --- A header line to write, in [`Message.RequestParts.fields`].
  record Field
    --- A token: `CSeq`, `Content-Type`.
    name: string
    --- The value, one line's.
    value: string
  end

  --- A request to write.
  record RequestParts
    --- A token: `GET`, `DESCRIBE`.
    method: string
    --- Visible ASCII with no space: `/a?b`, `*`, `rtsp://host/stream`.
    target: string
    --- "HTTP/1.1" when nil.
    protocol?: string
    --- Name to value, written in name order; a list value writes one
    --- line per element. A reader trims the spaces and tabs around a
    --- value. `Content-Length` and `Transfer-Encoding` are one value
    --- each, never a list.
    headers?: {string: string | {string}}
    --- Header lines written in the order given, before those of
    --- `headers`, for a peer that reads an order: `{ { name = "CSeq",
    --- value = "3" } }`. A name may repeat, but `Content-Length` and
    --- `Transfer-Encoding` are each given at most once across `fields`
    --- and `headers`.
    fields?: {Field}
    --- The body. Its size is written as `Content-Length` unless the
    --- headers or fields give one, which must be its size and is written
    --- where they put it; with none given, the one written goes last. nil
    --- writes no body and no `Content-Length` but one they give.
    body?: string
  end

  --- A response to write.
  record ResponseParts
    --- From 100 to 999.
    status: integer
    --- The reason phrase; nil writes the one HTTP names for `status`, ""
    --- for a status it does not name.
    reason?: string
    --- "HTTP/1.1" when nil.
    protocol?: string
    --- As [`Message.RequestParts.headers`].
    headers?: {string: string | {string}}
    --- As [`Message.RequestParts.fields`].
    fields?: {Field}
    --- As [`Message.RequestParts.body`]. A status below 200, 204 or 304
    --- takes none but `""`, which is none: no `Content-Length` is added
    --- to it, and one the headers or fields give is written as given. A
    --- reader takes any other HTTP response written with neither a body
    --- nor a length to run to the end of the stream: give `""` for an
    --- empty one.
    body?: string
  end
end

local KIB <const> = 1024

--- A protocol's name and version: `HTTP/1.1`, `RTSP/1.0`.
local PROTOCOL <const> = "^%u+/%d%.%d$"

--- A request target: visible ASCII.
local TARGET <const> = "^[!-~]+$"

--- A reader's bounds, and what it reads, settled from its
--- [`Message.Options`].
local record Settings
  --- The protocols a first line may name.
  accepted: {string:boolean}
  head_bytes: integer
  line_bytes: integer
  max_headers: integer
  body_bytes: integer
  head_only: boolean
  --- The kind of message read; nil reads either, as its first line says.
  kind?: Message.Kind
end

--- What any reader answers, before it is a [`Message.RequestRead`], a
--- [`Message.ResponseRead`] or a [`Message.Read`].
local record Outcome
  status: Message.Status
  consumed: integer
  next: integer
  reason: string
  --- When `done`: the message's kind, and its first line's three parts,
  --- in the order sent.
  kind?: Message.Kind
  first?: string
  second?: string
  third?: string
  headers?: {string:string}
  values?: {string:{string}}
  body?: string
end

--- Where a reader is in its message. A line phase reads to the next LF;
--- "length", "data" and "end" take body bytes.
local enum Phase
  "start"
  "headers"
  "length"
  "size"
  "data"
  "data end"
  "trailers"
  "end"
end

local LINE_PHASE <const>: {Phase:boolean} = {
  start = true, headers = true, size = true, ["data end"] = true, trailers = true,
}

--- A reader's state.
local record State
  mut final?: Outcome
  mut phase: Phase
  --- Whether the message is a response, which the first line settles.
  mut response: boolean
  --- Bytes of the message taken so far.
  mut taken: integer
  --- The unfinished line's pieces, and their bytes.
  mut pieces: mut {string}
  mut line_size: integer
  --- Most bytes the line being read may take, and why a longer one is
  --- refused. Both are settled where the line starts, so that where the
  --- feeds split decides neither.
  mut budget: integer
  mut budget_reason: string
  --- Bytes counted against `head_bytes`: the head, then a chunked body's
  --- extensions and trailers.
  mut spent: integer
  mut first: string
  mut second: string
  mut third: string
  --- Each header's values by lowercased name, and the names in the
  --- order first sent.
  values: mut {string: mut {string}}
  names: mut {string}
  mut count: integer
  --- Bytes left of the Content-Length, or of the chunk being read.
  mut left: integer
  body: mut {string}
  mut body_size: integer
end

local MORE <const>: Outcome = { status = "more", consumed = 0, next = 1, reason = "" }

--- The integer `value` of the option `name`, or `default`; raises where
--- it is below 1.
local function bound(name: string, value: integer?, default: integer): integer
  if value == nil then return default end
  if value < 1 then error("http: " .. name .. " must be positive", 4) end
  return value
end

--- `opts` as [`Settings`] of a reader of `kind`; raises on a protocol
--- that is no name and version, on `protocol` and `protocols` both or
--- an empty list, and on a limit below 1.
local function settings(opts: Message.Options?, kind: Message.Kind?): Settings
  local o: Message.Options = opts or {}
  local protocols = o.protocols or { o.protocol or "HTTP/1.1" }
  if o.protocols ~= nil and o.protocol ~= nil then
    error("http: give protocol or protocols, not both", 3)
  end
  if #protocols == 0 then error("http: protocols is empty", 3) end
  local accepted: mut {string:boolean} = {}
  for _, protocol in ipairs(protocols) do
    if not protocol:find(PROTOCOL) then
      error(("http: the protocol %q is not a name and version, as HTTP/1.1 is"):format(protocol), 3)
    end
    accepted[protocol] = true
    if protocol == "HTTP/1.1" then accepted["HTTP/1.0"] = true end
  end
  return {
    accepted = accepted,
    head_bytes = bound("head_bytes", o.head_bytes, 64 * KIB),
    line_bytes = bound("line_bytes", o.line_bytes, 8 * KIB),
    max_headers = bound("max_headers", o.max_headers, 100),
    body_bytes = bound("body_bytes", o.body_bytes, 1024 * KIB),
    head_only = o.head_only == true,
    kind = kind,
  }
end

--- The reader under all three: of `set.kind`, or of either kind.
local record Machine
  feed: function(chunk: string, from: integer): Outcome
  finish: function(): Outcome
end

--- A reader held to `set`.
local function machine(set: Settings): Machine
  local st: State = {
    phase = "start", response = set.kind == "response", taken = 0, pieces = {}, line_size = 0, budget = 0, budget_reason = "", spent = 0,
    first = "", second = "", third = "", values = {}, names = {}, count = 0, left = 0, body = {},
    body_size = 0,
  }

  local function settle(answer: Outcome): Outcome
    st.final = answer
    st.pieces = {}
    return answer
  end

  local function refuse(why: string): Outcome
    return settle({ status = "refused", consumed = 0, next = 1, reason = why })
  end

  --- The message, read whole, the bytes after it at `after` of the
  --- chunk fed.
  local function done(after: integer): Outcome
    local headers: mut {string:string} = {}
    for _, name in ipairs(st.names) do
      local list = st.values[name]
      if list ~= nil then
        headers[name] = table.concat(list, if name == "cookie" then "; " else ", " end)
      end
    end
    return settle({
      status = "done", consumed = st.taken, next = after, reason = "",
      kind = if st.response then "response" else "request" end, first = st.first, second = st.second,
      third = st.third, headers = headers, values = st.values, body = table.concat(st.body),
    })
  end

  --- Sets the budget of a line of the head that starts here.
  local function head_line()
    local left = set.head_bytes - st.taken
    if left < set.line_bytes then
      st.budget, st.budget_reason = left, "the head is longer than " .. String.counted(set.head_bytes, "byte")
    else
      st.budget, st.budget_reason = set.line_bytes, "a line is longer than " .. String.counted(set.line_bytes, "byte")
    end
  end

  --- Sets the budget of a chunked body's line that starts here.
  local function meta_line(phase: Phase)
    st.phase = phase
    if phase == "data end" then
      st.budget, st.budget_reason = 2, "a chunk's data is not followed by CRLF"
    else
      st.budget, st.budget_reason = set.line_bytes, "a line is longer than " .. String.counted(set.line_bytes, "byte")
    end
  end

  --- Counts `bytes` of a chunked body's framing against the head's
  --- limit: whether they fit.
  local function spend(bytes: integer): boolean
    st.spent = st.spent + bytes
    return st.spent <= set.head_bytes
  end

  local OVER_HEAD <const> = "a chunked body's extensions and trailers pass " ..
    String.counted(set.head_bytes, "byte")
  local OVER_BODY <const> = "the body is longer than " .. String.counted(set.body_bytes, "byte")

  --- What the first line decides: a refusal, or nil to go on.
  local function first_line(text: string): Outcome?
    local protocol: string
    if set.kind == nil then
      -- A status line starts with a protocol, which holds a `/` that no
      -- method may: the first word tells the kinds apart.
      st.response = (text:match("^[^ ]*") or ""):find(PROTOCOL) ~= nil
    end
    if st.response then
      local name, status, rest = text:match("^([^ ]+) (%d%d%d)(.*)$")
      if name == nil or status == nil or rest == nil or (rest ~= "" and rest:sub(1, 1) ~= " ") then
        return refuse("the status line is not protocol, status and reason")
      end
      if status < "100" then return refuse("the status is below 100") end
      if wire.controls(rest) then return refuse("the reason phrase holds a control byte") end
      protocol = name
      st.first, st.second, st.third = name, status, rest:sub(2)
    else
      local method, target, name = text:match("^([^ ]+) ([^ ]+) ([^ ]+)$")
      if method == nil or target == nil or name == nil then
        return refuse("the request line is not method, target and protocol")
      end
      if not wire.token(method) then return refuse("the method is no token") end
      if not target:find(TARGET) then
        return refuse("the target holds a byte outside visible ASCII")
      end
      protocol = name
      st.first, st.second, st.third = method, target, name
    end
    if set.accepted[protocol] ~= true then
      local names: mut {string} = {}
      for accepted in pairs(set.accepted) do names[#names + 1] = accepted end
      table.sort(names)
      return refuse("the protocol is not " .. table.concat(names, " or "))
    end
    st.phase = "headers"
    return nil
  end

  --- What the head, read whole, says of the body: an answer, or nil
  --- where a body follows, `phase` set for it. `after` is where the
  --- chunk fed goes on after the head.
  local function framed(after: integer): Outcome?
    st.spent = st.taken
    local te, cl = st.values["transfer-encoding"], st.values["content-length"]
    if te ~= nil and cl ~= nil then
      return refuse("a message holds both Content-Length and Transfer-Encoding")
    end
    local protocol = if st.response then st.first else st.third end
    local length: integer? = nil
    if te ~= nil then
      if protocol ~= "HTTP/1.1" then
        return refuse("a message that is not HTTP/1.1 holds Transfer-Encoding")
      end
      local codings = wire.members(table.concat(te, ", "):lower())
      if #codings ~= 1 or codings[1] ~= "chunked" then
        return refuse("the transfer coding is not chunked alone")
      end
    elseif cl ~= nil then
      local size, why = wire.content_length(table.concat(cl, ", "))
      if size == nil then return refuse(why) end
      length = size
    end
    if st.response then
      local status = st.second
      if set.head_only or status < "200" or status == "204" or status == "304" then
        return done(after)
      end
    end
    if te ~= nil then
      meta_line("size")
      return nil
    end
    if length == nil then
      if not st.response or protocol:sub(1, 5) ~= "HTTP/" then return done(after) end
      st.phase = "end"
      return nil
    end
    if length > set.body_bytes then return refuse(OVER_BODY) end
    if length == 0 then return done(after) end
    st.left, st.phase = length, "length"
    return nil
  end

  --- What a whole line, without its LF, decides: an answer, or nil to
  --- go on. `after` is where the chunk fed goes on after the line.
  local function line(raw: string, after: integer): Outcome?
    if raw:sub(-1) ~= "\r" then return refuse("a line ends in a bare LF") end
    local text = raw:sub(1, -2)
    if text:find("\r", 1, true) then return refuse("a line holds a bare CR") end
    local phase = st.phase
    if phase == "start" then
      if text == "" then
        head_line()
        return nil
      end
      local answer = first_line(text)
      if answer == nil then head_line() end
      return answer
    elseif phase == "headers" then
      if text == "" then return framed(after) end
      st.count = st.count + 1
      if st.count > set.max_headers then
        return refuse("more than " .. String.counted(set.max_headers, "header"))
      end
      local got, why = wire.field(text)
      if got == nil then return refuse(why) end
      if st.values[got.name] == nil then
        st.values[got.name] = {}
        st.names[#st.names + 1] = got.name
      end
      local list = assert(st.values[got.name])
      list[#list + 1] = got.value
      head_line()
      return nil
    elseif phase == "size" then
      local chunk, why = wire.chunk_size(text)
      if chunk == nil then return refuse(why) end
      if not spend(chunk.extra) then return refuse(OVER_HEAD) end
      if chunk.huge then return refuse(OVER_BODY) end
      if chunk.size == 0 then
        meta_line("trailers")
        return nil
      end
      if chunk.size > set.body_bytes - st.body_size then return refuse(OVER_BODY) end
      st.left, st.phase = chunk.size, "data"
      return nil
    elseif phase == "data end" then
      if text ~= "" then return refuse("a chunk's data is not followed by CRLF") end
      meta_line("size")
      return nil
    end
    if text == "" then return done(after) end
    if not spend(#text + 2) then return refuse(OVER_HEAD) end
    local got, why = wire.field(text)
    if got == nil then return refuse("a trailer is malformed: " .. why) end
    meta_line("trailers")
    return nil
  end

  head_line()

  local function feed(chunk: string, from: integer): Outcome
    local final = st.final
    if final ~= nil then return final end
    local size = #chunk
    local pos = math.max(from, 1)
    while pos <= size do
      local phase = st.phase
      if LINE_PHASE[phase] == true then
        local lf = chunk:find("\n", pos, true)
        local stop = lf or size + 1
        local got = stop - pos + (if lf ~= nil then 1 else 0 end)
        if st.line_size + got > st.budget then return refuse(st.budget_reason) end
        st.taken = st.taken + got
        if stop > pos then
          local piece = chunk:sub(pos, stop - 1)
          st.pieces[#st.pieces + 1] = piece
        end
        if lf == nil then
          st.line_size = st.line_size + got
          return MORE
        end
        local raw = table.concat(st.pieces)
        st.pieces, st.line_size = {}, 0
        pos = lf + 1
        local answer = line(raw, pos)
        if answer ~= nil then return answer end
      elseif phase == "end" then
        local got = size - pos + 1
        if got > set.body_bytes - st.body_size then return refuse(OVER_BODY) end
        local piece = chunk:sub(pos)
        st.body[#st.body + 1] = piece
        st.body_size = st.body_size + got
        st.taken = st.taken + got
        return MORE
      else
        local piece = chunk:sub(pos, pos + st.left - 1)
        pos = pos + #piece
        st.body[#st.body + 1] = piece
        st.body_size = st.body_size + #piece
        st.taken = st.taken + #piece
        st.left = st.left - #piece
        if st.left == 0 then
          if phase == "length" then return done(pos) end
          meta_line("data end")
        end
      end
    end
    return MORE
  end

  local function finish(): Outcome
    local final = st.final
    if final ~= nil then return final end
    if st.phase == "end" then return done(1) end
    if st.phase == "start" and st.line_size == 0 then
      return settle({ status = "empty", consumed = 0, next = 1, reason = "" })
    end
    return refuse("the stream ended within a message")
  end

  return { feed = feed, finish = finish }
end

--- `read` as what a request reader answers.
local function request_read(read: Outcome): Message.RequestRead
  local method, target, protocol, headers, values, body =
    read.first, read.second, read.third, read.headers, read.values, read.body
  if read.status ~= "done" or method == nil or target == nil or protocol == nil or headers == nil or
      values == nil or body == nil then
    return { status = read.status, consumed = 0, next = 1, reason = read.reason }
  end
  return {
    status = "done", consumed = read.consumed, next = read.next, reason = "",
    request = { method = method, target = target, protocol = protocol, headers = headers, values = values,
      body = body },
  }
end

--- `read` as what a response reader answers.
local function response_read(read: Outcome): Message.ResponseRead
  local protocol, status, reason, headers, values, body =
    read.first, math.tointeger(tonumber(read.second or "")), read.third, read.headers, read.values, read.body
  if read.status ~= "done" or protocol == nil or status == nil or reason == nil or headers == nil or
      values == nil or body == nil then
    return { status = read.status, consumed = 0, next = 1, reason = read.reason }
  end
  return {
    status = "done", consumed = read.consumed, next = read.next, reason = "",
    response = { protocol = protocol, status = status, reason = reason, headers = headers, values = values,
      body = body },
  }
end

--- `read` as what a reader of either kind answers.
local function either_read(read: Outcome): Message.Read
  if read.kind == "request" then
    local got = request_read(read)
    return { status = got.status, kind = "request", request = got.request, consumed = got.consumed,
      next = got.next, reason = got.reason }
  elseif read.kind == "response" then
    local got = response_read(read)
    return { status = got.status, kind = "response", response = got.response, consumed = got.consumed,
      next = got.next, reason = got.reason }
  end
  return { status = read.status, consumed = 0, next = 1, reason = read.reason }
end

--- A reader of one request, for the side of a connection that is asked:
--- a request with neither a `Content-Length` nor chunks has no body.
--- `opts` are the defaults when nil; an option that is not what
--- [`Message.Options`] says raises.
function Message.request_reader(opts?: Message.Options): Message.RequestReader
  local reader = machine(settings(opts, "request"))
  local last: mut {Message.RequestRead} = {}
  --- One record for each answer of the machine, so a final answer is the
  --- same value at every call.
  local function answer(read: Outcome): Message.RequestRead
    local kept = last[1]
    if kept ~= nil and read.status ~= "more" then return kept end
    local out = request_read(read)
    if read.status ~= "more" then last[1] = out end
    return out
  end
  return {
    feed = function(_: Message.RequestReader, chunk: string, from?: integer): Message.RequestRead
      return answer(reader.feed(chunk, from or 1))
    end,
    finish = function(_: Message.RequestReader): Message.RequestRead
      return answer(reader.finish())
    end,
  }
end

--- A reader of one response, for the side that asked. Its `opts` are
--- [`Message.request_reader`]'s, with `head_only` for the answer to a
--- HEAD; the caller says when the stream ends, with `finish`, which is
--- where an HTTP response that names no length ends.
function Message.response_reader(opts?: Message.Options): Message.ResponseReader
  local reader = machine(settings(opts, "response"))
  local last: mut {Message.ResponseRead} = {}
  local function answer(read: Outcome): Message.ResponseRead
    local kept = last[1]
    if kept ~= nil and read.status ~= "more" then return kept end
    local out = response_read(read)
    if read.status ~= "more" then last[1] = out end
    return out
  end
  return {
    feed = function(_: Message.ResponseReader, chunk: string, from?: integer): Message.ResponseRead
      return answer(reader.feed(chunk, from or 1))
    end,
    finish = function(_: Message.ResponseReader): Message.ResponseRead
      return answer(reader.finish())
    end,
  }
end

--- A reader of one message of either kind, for a connection whose
--- requests and responses share a stream (each side asks the other),
--- or a side that passes over what it is asked while it waits for an
--- answer. Its first line says which kind it is: a status line starts
--- with a protocol, and a method is never one. A first line whose first
--- word is no protocol is read as a request line, so a malformed status
--- line (`HTTP/2 200 OK`) is refused for what a request line holds. Its
--- `opts` are
--- [`Message.response_reader`]'s, `head_only` holding of a response
--- alone, and a message is framed as the reader of its own kind would.
function Message.reader(opts?: Message.Options): Message.Reader
  local reader = machine(settings(opts, nil))
  local last: mut {Message.Read} = {}
  local function answer(read: Outcome): Message.Read
    local kept = last[1]
    if kept ~= nil and read.status ~= "more" then return kept end
    local out = either_read(read)
    if read.status ~= "more" then last[1] = out end
    return out
  end
  return {
    feed = function(_: Message.Reader, chunk: string, from?: integer): Message.Read
      return answer(reader.feed(chunk, from or 1))
    end,
    finish = function(_: Message.Reader): Message.Read
      return answer(reader.finish())
    end,
  }
end

--- A header line to be written, from fields or headers.
local record Line
  name: string
  value: string | {string}
end

--- The message of `first` line, `fields` then `headers`, and `body` as
--- bytes, or nil and why it cannot be written. `bodiless` is a response
--- whose status takes no body, `chunkable` a message of HTTP/1.1.
local function written(first: string, fields: {Message.Field}, headers: {string: string | {string}},
                       body: string?, bodiless: boolean, chunkable: boolean): string?, string
  local header_lines: mut {Line} = {}
  for _, field in ipairs(fields) do
    header_lines[#header_lines + 1] = { name = field.name, value = field.value }
  end
  local names: mut {string} = {}
  for name in pairs(headers) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    header_lines[#header_lines + 1] = { name = name, value = assert(headers[name]) }
  end
  local given: string? = nil
  local coded = false
  for _, header in ipairs(header_lines) do
    local name, value = header.name, header.value
    if not wire.token(name) then return nil, ("header %q: its name is no token"):format(name) end
    local lower = name:lower()
    if lower == "content-length" then
      if given ~= nil then return nil, "Content-Length is given twice" end
      if value is string and value:find("^%d+$") ~= nil and #value <= 18 then
        given = value
      else
        return nil, "Content-Length is not one value of at most 18 digits"
      end
    elseif lower == "transfer-encoding" then
      if coded then return nil, "Transfer-Encoding is given twice" end
      coded = true
      if body ~= nil then
        return nil, "a body is written by its Content-Length: give no body with Transfer-Encoding"
      end
      if not chunkable then return nil, "Transfer-Encoding goes with HTTP/1.1 alone" end
      if not (value is string and value:lower() == "chunked") then
        return nil, "the Transfer-Encoding is not chunked alone"
      end
    end
  end
  if coded and given ~= nil then
    return nil, "Content-Length and Transfer-Encoding are both given"
  end
  if bodiless and body ~= nil and body ~= "" then return nil, "no body goes with the status" end
  if given ~= nil and body ~= nil and not bodiless and math.tointeger(tonumber(given)) ~= #body then
    return nil, ("the Content-Length is %s, but the body is %s"):format(given, String.counted(#body, "byte"))
  end
  local lines: mut {string} = { first }
  for _, header in ipairs(header_lines) do
    local name, value = header.name, header.value
    local list: {string} = if value is string then { value } else value end
    for _, entry in ipairs(list) do
      if wire.controls(entry) then
        return nil, ("header %s: its value holds a control byte"):format(name)
      end
      lines[#lines + 1] = name .. ": " .. entry
    end
  end
  if body ~= nil and given == nil and not bodiless then
    lines[#lines + 1] = "Content-Length: " .. tostring(#body)
  end
  return table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or ""), ""
end

--- `parts` as the bytes of a request, or nil and why it cannot be
--- written: a method, target, protocol or header line that a reader
--- refuses, a `Content-Length` that is not the body's size or is past 18
--- digits, or a `Transfer-Encoding` that is not `chunked` alone, is
--- given a message that is not HTTP/1.1, or comes with a body or a
--- `Content-Length`. A reader's limits are its own: it may still refuse
--- what is written here as too long.
function Message.format_request(parts: Message.RequestParts): string?, string
  local protocol = parts.protocol or "HTTP/1.1"
  if not protocol:find(PROTOCOL) then
    return nil, "the protocol is not a name and version, as HTTP/1.1 is"
  end
  if not wire.token(parts.method) then return nil, "the method is no token" end
  if not parts.target:find(TARGET) then
    return nil, "the target holds a byte outside visible ASCII"
  end
  return written(parts.method .. " " .. parts.target .. " " .. protocol, parts.fields or {}, parts.headers or {},
    parts.body, false, protocol == "HTTP/1.1")
end

--- `parts` as the bytes of a response, or nil and why it cannot be
--- written: a status or reason that a reader refuses, a body with a
--- status that takes none, and what [`Message.format_request`] refuses
--- of a protocol, a header, a `Content-Length` and a
--- `Transfer-Encoding`.
function Message.format_response(parts: Message.ResponseParts): string?, string
  local protocol = parts.protocol or "HTTP/1.1"
  if not protocol:find(PROTOCOL) then
    return nil, "the protocol is not a name and version, as HTTP/1.1 is"
  end
  local status = parts.status
  if status < 100 or status > 999 then return nil, "the status is not from 100 to 999" end
  local reason = parts.reason or wire.reason(status)
  if wire.controls(reason) then return nil, "the reason phrase holds a control byte" end
  local bodiless = status < 200 or status == 204 or status == 304
  return written(("%s %d %s"):format(protocol, status, reason), parts.fields or {}, parts.headers or {},
    parts.body, bodiless, protocol == "HTTP/1.1")
end

return Message
