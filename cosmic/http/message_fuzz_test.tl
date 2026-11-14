--- Fuzz properties for cosmic.http.message, whose readers are fed
--- bytes no one vouches for: reading is total and bounded, each
--- message's `consumed` and `rest` account for every byte, and the same
--- bytes read the same wherever the feeds split; and a message written
--- from its parts is read back as those parts, under HTTP's name and
--- under RTSP's.
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

--- One answer of either reader, alike enough to be read as one.
local record Answer
  status: Message.Status
  consumed: integer
  rest: string
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
    return { status = read.status, consumed = read.consumed, rest = read.rest, reason = read.reason }
  end
  return { status = read.status, consumed = read.consumed, rest = read.rest, reason = read.reason,
    text = table.concat({ got.method, got.target, got.protocol, listed(got.headers, got.values), got.body }, "\n"),
    body = got.body }
end

local function response_answer(read: Message.ResponseRead): Answer
  local got = read.response
  if got == nil then
    return { status = read.status, consumed = read.consumed, rest = read.rest, reason = read.reason }
  end
  return { status = read.status, consumed = read.consumed, rest = read.rest, reason = read.reason,
    text = table.concat({ got.protocol, tostring(got.status), got.reason, listed(got.headers, got.values),
      got.body }, "\n"), body = got.body }
end

--- A reader of either kind, as its feed and finish.
local record Reader
  feed: function(chunk: string): Answer
  finish: function(): Answer
end

local function new_reader(response: boolean, protocol: string): Reader
  local opts: Message.Options = { ...LIMITS, protocol = protocol }
  if response then
    local reader = Message.response_reader(opts)
    return {
      feed = function(chunk: string): Answer return response_answer(reader:feed(chunk)) end,
      finish = function(): Answer return response_answer(reader:finish()) end,
    }
  end
  local reader = Message.request_reader(opts)
  return {
    feed = function(chunk: string): Answer return request_answer(reader:feed(chunk)) end,
    finish = function(): Answer return request_answer(reader:finish()) end,
  }
end

--- What reading every message of `data`, fed in pieces of `sizes` and
--- then the rest whole, gives, as text: each message, the bytes it took,
--- and how reading ended. Raises where reading is not total and bounded:
--- an answer that does not say what its status asks, a body past its
--- limit, or bytes a message neither took nor left.
local function transcript(data: string, sizes: {integer}, response: boolean, protocol: string): string
  local out: mut {string} = {}
  local reader = new_reader(response, protocol)
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
    while true do
      local read = reader.feed(chunk)
      if read.status == "more" then
        assert(read.consumed == 0 and read.rest == "" and read.reason == "" and read.text == nil)
        break
      end
      assert(reader.feed("more").status == read.status, "an answer is not final")
      if read.status == "refused" then
        assert(read.reason ~= "" and read.text == nil and read.consumed == 0 and read.rest == "")
        Fuzz.label("refused")
        out[#out + 1] = "refused " .. read.reason
        return table.concat(out, "\n")
      end
      assert(read.status == "done", "a feed answered " .. read.status)
      local text, body = assert(read.text), assert(read.body)
      assert(#body <= 256, "a body past its limit")
      assert(read.consumed > 0 and #read.rest <= #chunk and chunk:sub(#chunk - #read.rest + 1) == read.rest,
        "rest is not the end of the last feed")
      taken = taken + read.consumed
      assert(taken == at - 1 - #read.rest, "consumed and rest do not account for the bytes fed")
      messages = messages + 1
      Fuzz.label("done")
      if messages == 2 then Fuzz.label("second message") end
      if body ~= "" then Fuzz.label("body") end
      out[#out + 1] = ("done %d\n%s"):format(read.consumed, text)
      reader = new_reader(response, protocol)
      chunk = read.rest
      if chunk == "" then break end
    end
  end
  local read = reader.finish()
  assert(read.status ~= "more", "finish answered more")
  if read.status == "done" then
    local text, body = assert(read.text), assert(read.body)
    assert(response and #body <= 256 and read.rest == "" and taken + read.consumed == #data)
    Fuzz.label("to the end of the stream")
    out[#out + 1] = ("done %d\n%s"):format(read.consumed, text)
  else
    out[#out + 1] = read.status .. " " .. read.reason
  end
  return table.concat(out, "\n")
end

--- A few messages of one kind, pipelined, sometimes edited, and where to
--- cut them: the kind, the protocol read, the bytes, then each piece's
--- size.
local function gen_bytes(src: Fuzz.Source): string
  local response = src:int(0, 1) == 1
  local parts: mut {string} = {}
  while #parts == 0 or Fuzz.more(src, #parts, 3) do
    local message = draw_message(src, response)
    parts[#parts + 1] = message
  end
  local data = table.concat(parts)
  if src:int(0, 2) == 0 then data = Fuzz.mutate(src, data, 4) end
  local packed: mut {string} = { if response then "response" else "request" end,
    Fuzz.pick(src, { "HTTP/1.1", "HTTP/1.1", "RTSP/1.0" }), data }
  while Fuzz.more(src, #packed - 3, 12) do
    local size = tostring(src:int(1, 24))
    packed[#packed + 1] = size
  end
  return Fuzz.pack(packed)
end

--- What [`gen_bytes`] packed.
local function unpacked(input: string): boolean, string, string, {integer}
  local fields = Fuzz.unpack(input)
  local sizes: mut {integer} = {}
  for i = 4, #fields do
    sizes[#sizes + 1] = math.max(1, math.tointeger(tonumber(fields[i])) or 1)
  end
  local protocol = if fields[2] == "RTSP/1.0" then "RTSP/1.0" else "HTTP/1.1" end
  return fields[1] == "response", protocol, fields[3] or "", sizes
end

-- Reading any bytes ends in messages, a refusal or the stream's end,
-- with every byte accounted for and no body past its limit.
local function test_reading_is_total_and_bounded(tmp: string)
  Fuzz.run({
    name = "http message total",
    dir = tmp,
    gen = gen_bytes,
    check = function(input: string): boolean, string
      local response, protocol, data, sizes = unpacked(input)
      local _ = transcript(data, sizes, response, protocol)
      return true, ""
    end,
    requires = { "done", "body", "second message", "refused", "to the end of the stream" },
    shares = { done = 0.2 },
  })
end

-- The same bytes read the same wherever the feeds split.
local function test_any_split_reads_the_same(tmp: string)
  Fuzz.run({
    name = "http message split",
    dir = tmp,
    gen = gen_bytes,
    check = function(input: string): boolean, string
      local response, protocol, data, sizes = unpacked(input)
      local whole = transcript(data, {}, response, protocol)
      local cut = transcript(data, sizes, response, protocol)
      if whole ~= cut then return false, "whole:\n" .. whole .. "\ncut:\n" .. cut end
      local bytewise: mut {integer} = {}
      for i = 1, #data do bytewise[i] = 1 end
      local single = transcript(data, bytewise, response, protocol)
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
        Fuzz.pick(src, { "none", "empty", "bytes" }), Fuzz.bytes(src, 40),
      }
      while Fuzz.more(src, #fields - 7, 4) do
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
      local expected: mut {string:{string}} = {}
      for i = 8, #f do
        local pair = PAIRS[math.tointeger(tonumber(f[i])) or 1]
        if pair ~= nil then
          local name, value = pair[1] or "X", pair[2] or ""
          if headers[name] == nil then
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
          body = body })
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
      else
        local sent, why = Message.format_request({ method = method, target = target, protocol = protocol,
          headers = headers, body = body })
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
      if answer.consumed ~= #text or answer.rest ~= "" then
        return false, "the message is not all the bytes"
      end
      if answer.body ~= (if bodiless then "" else body or "" end) then
        return false, "the body differs"
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
    requires = { "request", "response", "body", "rtsp", "refused body", "to the end of the stream" },
  })
end
