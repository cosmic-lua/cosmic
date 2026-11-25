--- Fuzz properties for cosmic.http.message, whose readers are fed
--- bytes no one vouches for: reading is total and bounded, each
--- message's `consumed` and `next` account for every byte, and the same
--- bytes read the same wherever the feeds split; and a message written
--- from its parts is read back as those parts, under HTTP's name and
--- under RTSP's. A reader of either kind, and of both protocols, is held
--- to the same, and reads each message as the reader of its kind does.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Message = require("cosmic.http.message")

local LIMITS <const>: Message.Options = { head_bytes = 512, line_bytes = 128, max_headers = 6, body_bytes = 256 }

local METHODS <const> = { "GET", "POST", "OPTIONS", "DESCRIBE", "X-Custom!" }
local TARGETS <const> = { "/", "/a/b?c=d", "*", "rtsp://cam.test/s", "http://h.test:80/p" }
local PROTOCOLS <const> = { "HTTP/1.1", "HTTP/1.1", "HTTP/1.0", "RTSP/1.0" }
local STATUSES <const> = { "100", "200", "200", "204", "304", "404", "999" }
local NAMES <const> = { "Accept", "X-A", "x-a", "Cookie", "Set-Cookie", "CSeq" }
local VALUES <const> = { "a", "*/*", "a, b", "x\ty", "", "\xc3\xa9", "1" }
local CHUNKS <const> = { "a", "hello", "\r\n", "0\r\n\r\n", "GET / HTTP/1.1\r\n\r\n", ("z"):rep(40) }

--- Draws one message's text: a request or, with `response`, a
--- response, framed by a length, by chunks or by neither.
local function draw_message(src: Fuzz.Source, response: boolean): string
  local protocol = Fuzz.pick(src, PROTOCOLS)
  local lines: mut {string} = {}
  if response then
    lines[1] = protocol .. " " .. Fuzz.pick(src, STATUSES) .. Fuzz.pick(src, { " OK", "", " Not Found" })
  else
    lines[1] = Fuzz.pick(src, METHODS) .. " " .. Fuzz.pick(src, TARGETS) .. " " .. protocol
  end
  local count = 0
  while Fuzz.more(src, count, 4) do
    count = count + 1
    lines[#lines + 1] = Fuzz.pick(src, NAMES) .. ": " .. Fuzz.pick(src, VALUES)
  end
  local chunks: mut {string} = {}
  while Fuzz.more(src, #chunks, 4) do
    local chunk = if src:int(0, 3) == 0 then Fuzz.bytes(src, 8) else Fuzz.pick(src, CHUNKS) end
    chunks[#chunks + 1] = chunk
  end
  local body = table.concat(chunks)
  local framing = Fuzz.pick(src, { "none", "length", "length", "chunked" })
  local encoded = ""
  if framing == "length" then
    lines[#lines + 1] = "Content-Length: " .. tostring(#body)
    encoded = body
  elseif framing == "chunked" then
    lines[#lines + 1] = "Transfer-Encoding: chunked"
    local parts: mut {string} = {}
    for _, chunk in ipairs(chunks) do
      if chunk ~= "" then parts[#parts + 1] = ("%x"):format(#chunk) .. "\r\n" .. chunk .. "\r\n" end
    end
    parts[#parts + 1] = "0\r\n\r\n"
    encoded = table.concat(parts)
  end
  return table.concat(lines, "\r\n") .. "\r\n\r\n" .. encoded
end

--- One result of any reader, alike enough to be read as one.
local record Answer
  status: Message.Status
  --- When `done`, the kind of message read.
  kind?: Message.Kind
  consumed: integer
  next: integer
  reason: string
  --- When `done`: the message as text, and its body.
  text?: string
  body?: string
end

--- A header map as text, names in order.
local function listed(headers: {string:string}, values: {string:{string}}): string
  local names: mut {string} = {}
  for name in pairs(headers) do names[#names + 1] = name end
  table.sort(names)
  local out: mut {string} = {}
  for _, name in ipairs(names) do
    out[#out + 1] = name .. "=" .. (headers[name] or "") .. "=" .. table.concat(values[name] or {}, "\0")
  end
  return table.concat(out, "|")
end

local function request_answer(read: Message.RequestRead): Answer
  local got = read.request
  if got == nil then
    return { status = read.status, consumed = read.consumed, next = read.next, reason = read.reason }
  end
  return { status = read.status, kind = "request", consumed = read.consumed, next = read.next,
    reason = read.reason,
    text = table.concat({ got.method, got.target, got.protocol, listed(got.headers, got.values), got.body }, "\n"),
    body = got.body }
end

local function response_answer(read: Message.ResponseRead): Answer
  local got = read.response
  if got == nil then
    return { status = read.status, consumed = read.consumed, next = read.next, reason = read.reason }
  end
  return { status = read.status, kind = "response", consumed = read.consumed, next = read.next,
    reason = read.reason,
    text = table.concat({ got.protocol, tostring(got.status), got.reason, listed(got.headers, got.values),
      got.body }, "\n"), body = got.body }
end

--- What a reader of either kind returns, as the reader of its kind
--- would.
local function either_answer(read: Message.Read): Answer
  local request, response = read.request, read.response
  if read.kind == "request" and request ~= nil and response == nil then
    return request_answer({ status = read.status, request = request, consumed = read.consumed, next = read.next,
      reason = read.reason })
  elseif read.kind == "response" and response ~= nil and request == nil then
    return response_answer({ status = read.status, response = response, consumed = read.consumed,
      next = read.next, reason = read.reason })
  end
  assert(read.kind == nil and request == nil and response == nil, "a kind that is not the message's")
  return { status = read.status, consumed = read.consumed, next = read.next, reason = read.reason }
end

--- A reader of either kind, as its feed and finish.
local record Reader
  feed: function(chunk: string, from: integer): Answer
  finish: function(): Answer
end

--- A reader of `kind` (`request`, `response` or `either`), of
--- `protocol`, of RTSP/1.0 and HTTP/1.1 where that is `both`, or of
--- HTTP/1.1 with `lengthless = "empty"` where it is `HTTP/1.1 empty`.
local function new_reader(kind: string, protocol: string): Reader
  local opts: Message.Options = { ...LIMITS, protocol = protocol }
  if protocol == "both" then opts = { ...LIMITS, protocols = { "RTSP/1.0", "HTTP/1.1" } } end
  -- HTTP read with `lengthless = "empty"`, so that where a message with
  -- no length ends is held to every split too.
  if protocol == "HTTP/1.1 empty" then opts = { ...LIMITS, lengthless = "empty" } end
  if kind == "either" then
    local reader = Message.reader(opts)
    return {
      feed = function(chunk: string, from: integer): Answer
        return either_answer(reader:feed(chunk, from))
      end,
      finish = function(): Answer return either_answer(reader:finish()) end,
    }
  end
  if kind == "response" then
    local reader = Message.response_reader(opts)
    return {
      feed = function(chunk: string, from: integer): Answer
        return response_answer(reader:feed(chunk, from))
      end,
      finish = function(): Answer return response_answer(reader:finish()) end,
    }
  end
  local reader = Message.request_reader(opts)
  return {
    feed = function(chunk: string, from: integer): Answer
      return request_answer(reader:feed(chunk, from))
    end,
    finish = function(): Answer return request_answer(reader:finish()) end,
  }
end

--- What reading every message of `data`, fed in pieces of `sizes` and
--- then the rest whole, gives, as text: each message, the bytes it took,
--- and how reading ended. Raises where reading is not total and bounded:
--- a result that does not say what its status asks, a body past its
--- limit, or bytes a message neither took nor left.
local function transcript(data: string, sizes: {integer}, kind: string, protocol: string): string
  local out: mut {string} = {}
  local reader = new_reader(kind, protocol)
  local kinds: mut {string:boolean} = {}
  local messages = 0
  --- Bytes of `data` the messages read took.
  local taken = 0
  local at = 1
  local next_size = 1
  while at <= #data do
    local size = sizes[next_size] or #data
    next_size = next_size + 1
    local chunk = data:sub(at, at + size - 1)
    at = at + #chunk
    local from = 1
    while true do
      local read = reader.feed(chunk, from)
      if read.status == "more" then
        assert(read.consumed == 0 and read.next == 1 and read.reason == "" and read.text == nil)
        break
      end
      assert(reader.feed("more", 1).status == read.status, "an answer is not final")
      if read.status == "refused" then
        assert(read.reason ~= "" and read.text == nil and read.consumed == 0 and read.next == 1)
        Fuzz.label("refused")
        out[#out + 1] = "refused " .. read.reason
        return table.concat(out, "\n")
      end
      assert(read.status == "done", "a feed answered " .. read.status)
      local text, body = assert(read.text), assert(read.body)
      assert(#body <= 256, "a body past its limit")
      assert(read.consumed > 0 and read.next > from and read.next <= #chunk + 1,
        "next is not a position after the message in the last feed")
      taken = taken + read.consumed
      assert(taken == at - 1 - (#chunk + 1 - read.next), "consumed and next do not account for the bytes fed")
      messages = messages + 1
      Fuzz.label("done")
      if messages == 2 then Fuzz.label("second message") end
      if body ~= "" then Fuzz.label("body") end
      kinds[assert(read.kind)] = true
      if kinds["request"] == true and kinds["response"] == true then Fuzz.label("both kinds") end
      out[#out + 1] = ("done %s %d\n%s"):format(read.kind, read.consumed, text)
      reader = new_reader(kind, protocol)
      from = read.next
      if from > #chunk then break end
    end
  end
  local read = reader.finish()
  assert(read.status ~= "more", "finish answered more")
  if read.status == "done" then
    local text, body = assert(read.text), assert(read.body)
    assert(read.kind == "response" and #body <= 256 and read.next == 1 and taken + read.consumed == #data)
    Fuzz.label("to the end of the stream")
    out[#out + 1] = ("done %s %d\n%s"):format(read.kind, read.consumed, text)
  else
    out[#out + 1] = read.status .. " " .. read.reason
  end
  return table.concat(out, "\n")
end

--- A few messages, pipelined, sometimes edited, and where to cut them:
--- the kind read (`request`, `response`, or `either`, whose messages are
--- of both kinds), the protocol read, the bytes, then each piece's size.
local function gen_bytes(src: Fuzz.Source): string
  local kind = Fuzz.pick(src, { "request", "response", "either" })
  local parts: mut {string} = {}
  while #parts == 0 or Fuzz.more(src, #parts, 3) do
    local response = if kind == "either" then src:int(0, 1) == 1 else kind == "response" end
    local message = draw_message(src, response)
    parts[#parts + 1] = message
  end
  local data = table.concat(parts)
  if src:int(0, 2) == 0 then data = Fuzz.mutate(src, data, 4) end
  local packed: mut {string} = { kind, Fuzz.pick(src, { "HTTP/1.1", "HTTP/1.1", "RTSP/1.0", "both", "HTTP/1.1 empty" }), data }
  while Fuzz.more(src, #packed - 3, 12) do
    local size = tostring(src:int(1, 24))
    packed[#packed + 1] = size
  end
  return Fuzz.pack(packed)
end

--- What [`gen_bytes`] packed.
local function unpacked(input: string): string, string, string, {integer}
  local fields = Fuzz.unpack(input)
  local sizes: mut {integer} = {}
  for i = 4, #fields do
    sizes[#sizes + 1] = math.max(1, math.tointeger(tonumber(fields[i])) or 1)
  end
  local protocol, kind = "HTTP/1.1", "request"
  for _, name in ipairs({ "RTSP/1.0", "both", "HTTP/1.1 empty" }) do
    if fields[2] == name then protocol = name end
  end
  for _, name in ipairs({ "response", "either" }) do
    if fields[1] == name then kind = name end
  end
  return kind, protocol, fields[3] or "", sizes
end

-- Reading any bytes ends in messages, a refusal or the stream's end,
-- with every byte accounted for and no body past its limit.
local function test_reading_is_total_and_bounded(tmp: string)
  Fuzz.run({
    name = "http message total",
    dir = tmp,
    gen = gen_bytes,
    check = function(input: string): boolean, string
      local kind, protocol, data, sizes = unpacked(input)
      local _ = transcript(data, sizes, kind, protocol)
      return true, ""
    end,
    requires = { "done", "body", "second message", "refused", "to the end of the stream", "both kinds" },
    shares = { done = 0.2 },
  })
end

-- A reader of either kind reads each message as the reader of that
-- message's kind does, fed the same bytes from the same place: where
-- one of those reads it, the reader of either kind reads it the same,
-- and where both refuse, it refuses.
local function test_either_kind_reads_as_its_kind_does(tmp: string)
  Fuzz.run({
    name = "http message either kind",
    dir = tmp,
    gen = gen_bytes,
    check = function(input: string): boolean, string
      local _, protocol, data = unpacked(input)
      local at = 1
      while at <= #data do
        local function whole(kind: string): Answer
          local reader = new_reader(kind, protocol)
          local read = reader.feed(data, at)
          if read.status == "more" then read = reader.finish() end
          return read
        end
        local read, asked, answered = whole("either"), whole("request"), whole("response")
        local own: Answer? = nil
        if asked.status == "done" then
          own = asked
        elseif answered.status == "done" then
          own = answered
        end
        if own == nil then
          if read.status == "done" then
            return false, ("at %d, either read what neither kind reads"):format(at)
          end
          local function same(got: Answer): boolean
            return read.status == got.status and read.reason == got.reason
          end
          -- A first word that is neither a protocol nor a method is
          -- refused as neither kind, which no reader of one kind says.
          -- ... and only where the first word, past blank lines, is so.
          local word = data:sub(at):gsub("^[\r\n]*", ""):match("^[^ \r\n]*") or ""
          local neither = read.status == "refused" and asked.status == "refused" and
            answered.status == "refused" and not word:find("^%u+/%d%.%d$") and
            not word:find("^[!#$%%&'*+%-.^_`|~%w]+$") and
            read.reason == "the first line is neither a request line nor a status line"
          if neither then Fuzz.label("neither kind") end
          if not same(asked) and not same(answered) and not neither then
            return false, ("at %d, either answered %s %q"):format(at, read.status, read.reason)
          end
          Fuzz.label("refused")
          return true, ""
        end
        if own.text ~= read.text or own.kind ~= read.kind or own.consumed ~= read.consumed or own.next ~= read.next then
          return false, ("at %d, either: %s; %s: %s"):format(at, tostring(read.text), tostring(own.kind),
            tostring(own.text))
        end
        Fuzz.label(assert(own.kind))
        if read.next == 1 then return true, "" end
        at = read.next
      end
      return true, ""
    end,
    requires = { "request", "response", "refused", "neither kind" },
  })
end

-- The same bytes read the same wherever the feeds split.
local function test_any_split_reads_the_same(tmp: string)
  Fuzz.run({
    name = "http message split",
    dir = tmp,
    gen = gen_bytes,
    check = function(input: string): boolean, string
      local kind, protocol, data, sizes = unpacked(input)
      local whole = transcript(data, {}, kind, protocol)
      local cut = transcript(data, sizes, kind, protocol)
      if whole ~= cut then return false, "whole:\n" .. whole .. "\ncut:\n" .. cut end
      local bytewise: mut {integer} = {}
      for i = 1, #data do bytewise[i] = 1 end
      local single = transcript(data, bytewise, kind, protocol)
      if whole ~= single then
        return false, "whole:\n" .. whole .. "\na byte at a time:\n" .. single
      end
      return true, ""
    end,
    requires = { "done", "second message", "refused" },
  })
end

--- The headers a round trip gives: name and value pairs.
local PAIRS <const> = { { "Accept", "*/*" }, { "X-A", "1" }, { "x-b", "two words" }, { "CSeq", "7" },
  { "Set-Cookie", "a=1; Path=/" } }

-- A message written from its parts is read back as them.
local function test_a_written_message_reads_back(tmp: string)
  Fuzz.run({
    name = "http message round trip",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local fields: mut {string} = {
        Fuzz.pick(src, { "request", "response" }), Fuzz.pick(src, { "HTTP/1.1", "HTTP/1.0", "RTSP/1.0" }),
        Fuzz.pick(src, METHODS), Fuzz.pick(src, TARGETS), Fuzz.pick(src, STATUSES),
        Fuzz.pick(src, { "none", "empty", "bytes" }), Fuzz.bytes(src, 40), Fuzz.pick(src, { "headers", "fields" }),
      }
      while Fuzz.more(src, #fields - 8, 4) do
        local pair = tostring(src:int(1, #PAIRS))
        fields[#fields + 1] = pair
      end
      return Fuzz.pack(fields)
    end,
    check = function(input: string): boolean, string
      local f = Fuzz.unpack(input)
      local kind, protocol, method, target = f[1] or "request", f[2] or "HTTP/1.1", f[3] or "GET", f[4] or "/"
      local status = math.tointeger(tonumber(f[5] or "200")) or 200
      local framing = f[6] or "none"
      local body: string? = nil
      if framing == "empty" then body = "" end
      if framing == "bytes" then body = f[7] or "" end
      local headers: mut {string: string | {string}} = {}
      local expected: mut {string: mut {string}} = {}
      --- With `fields`, the header lines in the order they must be written.
      local ordered = f[8] == "fields"
      local fields: mut {Message.Field} = {}
      for i = 9, #f do
        local pair = PAIRS[math.tointeger(tonumber(f[i])) or 1]
        if pair ~= nil then
          local name, value = pair[1] or "X", pair[2] or ""
          if ordered then
            fields[#fields + 1] = { name = name, value = value }
            local list = expected[name:lower()] or {}
            list[#list + 1] = value
            expected[name:lower()] = list
          elseif headers[name] == nil then
            headers[name] = { value }
            expected[name:lower()] = { value }
          end
        end
      end
      local opts: Message.Options = { protocol = protocol }
      local text = ""
      local answer: Answer
      local bodiless = false
      if kind == "response" then
        bodiless = status < 200 or status == 204 or status == 304
        local sent, why = Message.format_response({ status = status, protocol = protocol, headers = headers,
          fields = fields, body = body })
        if bodiless and body ~= nil and body ~= "" then
          if sent ~= nil then
            return false, "a body for a " .. tostring(status) .. " was written"
          end
          Fuzz.label("refused body")
          return true, ""
        end
        if sent == nil then return false, "not written: " .. why end
        text = sent
        local reader = Message.response_reader(opts)
        local read = reader:feed(text)
        if read.status == "more" then
          if body ~= nil then
            return false, "a response with a length waits for the stream's end"
          end
          if protocol == "RTSP/1.0" then
            return false, "an RTSP response with no length waits for the stream's end"
          end
          Fuzz.label("to the end of the stream")
          read = reader:finish()
        end
        local got = read.response
        if got == nil then return false, "refused: " .. read.reason end
        if got.status ~= status or got.protocol ~= protocol then
          return false, "the status line differs"
        end
        answer = response_answer(read)
        Fuzz.label("response")
        if body == nil and not bodiless then
          -- Read as one that names no length has no body, it is its head.
          local empty = Message.response_reader({ protocol = protocol, lengthless = "empty" }):feed(text)
          if empty.status ~= "done" or assert(empty.response).body ~= "" or empty.consumed ~= #text then
            return false, "lengthless = \"empty\" did not end the response at its head"
          end
          Fuzz.label("lengthless")
        end
        if protocol == "RTSP/1.0" and body == nil and not bodiless then
          Fuzz.label("rtsp with no length")
        end
      else
        local sent, why = Message.format_request({ method = method, target = target, protocol = protocol,
          headers = headers, fields = fields, body = body })
        if sent == nil then return false, "not written: " .. why end
        text = sent
        local read = Message.request_reader(opts):feed(text)
        local got = read.request
        if got == nil then return false, "not read: " .. read.status .. " " .. read.reason end
        if got.method ~= method or got.target ~= target or got.protocol ~= protocol then
          return false, "the request line differs"
        end
        answer = request_answer(read)
        Fuzz.label("request")
      end
      if answer.consumed ~= #text or (answer.next ~= #text + 1 and answer.next ~= 1) then
        return false, "the message is not all the bytes"
      end
      if answer.body ~= (if bodiless then "" else body or "" end) then
        return false, "the body differs"
      end
      if ordered then
        local lines: mut {string} = {}
        for _, field in ipairs(fields) do lines[#lines + 1] = field.name .. ": " .. field.value end
        if body ~= nil and not bodiless then
          lines[#lines + 1] = "Content-Length: " .. tostring(#body)
        end
        local head = text:match("^[^\r]*\r\n(.-)\r\n\r\n") or ""
        if head ~= table.concat(lines, "\r\n") then
          return false, "the fields are not written in order"
        end
        if #fields > 1 then Fuzz.label("fields") end
      end
      if body ~= nil and not bodiless then
        expected["content-length"] = { tostring(#body) }
        if body ~= "" then Fuzz.label("body") end
      end
      local read_headers: {string:{string}}
      if kind == "response" then
        read_headers = assert(Message.response_reader({ ...opts, head_only = true }):feed(text).response).values
      else
        read_headers = assert(Message.request_reader(opts):feed(text).request).values
      end
      for name, values in pairs(expected) do
        if table.concat(read_headers[name] or {}, "\0") ~= table.concat(values, "\0") then
          return false, "header " .. name .. " differs"
        end
      end
      for name in pairs(read_headers) do
        if expected[name] == nil then return false, "header " .. name .. " was never given" end
      end
      if protocol == "RTSP/1.0" then Fuzz.label("rtsp") end
      return true, ""
    end,
    requires = { "request", "response", "body", "rtsp", "refused body", "to the end of the stream", "fields",
      "rtsp with no length", "lengthless" },
  })
end
