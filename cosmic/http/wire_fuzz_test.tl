--- Fuzz properties for cosmic.http.wire, which reads the bytes any
--- client sends [`Http.serve`]: reading requests is total and bounded,
--- answering a head or one of the server's refusals; a request written
--- out is read back as it was; the same bytes read the same in any
--- chunking, which a reader that kept bytes it read ahead in the wrong
--- place would not; and a reply is written with no body where it may
--- carry none, and with a Content-Length equal to the bytes sent, given
--- one by the handler or not.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Stream = require("cosmic.stream")
local wire = require("cosmic.http.wire")

local LIMITS <const>: wire.Limits = { head_bytes = 512, body_bytes = 256 }

--- The statuses a request may be refused with.
local REFUSALS <const>: {integer:boolean} = { [400] = true, [413] = true, [417] = true,
  [431] = true, [501] = true, [505] = true }

local METHODS <const> = { "GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "X-Custom!" }

--- Targets, and the path, query and Host each is read as.
local TARGETS <const> = {
  { "/", "/", "", "h.test" }, { "/a/b", "/a/b", "", "h.test" }, { "/a?b=c&d", "/a", "b=c&d", "h.test" },
  { "/%41?", "/%41", "", "h.test" }, { "/x?y?z", "/x", "y?z", "h.test" },
  { "http://other.test/p?q", "/p", "q", "other.test" }, { "https://H.test:8443", "/", "", "h.test:8443" },
}

local NAMES <const> = { "Accept", "X-A", "user-agent", "Cookie", "X-Empty", "Expect" }
local VALUES <const> = { "a", "*/*", "a, b", "x\ty", "", "100-continue", "\xc3\xa9" }
local CHUNKS <const> = { "a", "hello", "\r\n", "0\r\n\r\n", "GET / HTTP/1.1\r\n", string.rep("z", 40) }

--- One request as drawn: what the writer below makes into bytes.
local record Request
  method: string
  target: integer
  version: string
  --- "\r\n" or "\n".
  eol: string
  --- Name and value pairs.
  headers: {{string}}
  --- "none", "length" or "chunked".
  framing: string
  chunks: {string}
end

--- Draws one request's fields onto `fields`, each a letter and its text.
local function draw_request(src: Fuzz.Source, fields: {string})
  fields[#fields + 1] = "r"
  fields[#fields + 1] = "m" .. Fuzz.pick(src, METHODS)
  fields[#fields + 1] = "t" .. tostring(src:int(1, #TARGETS))
  fields[#fields + 1] = "v" .. Fuzz.pick(src, { "HTTP/1.1", "HTTP/1.1", "HTTP/1.0" })
  fields[#fields + 1] = "e" .. Fuzz.pick(src, { "\r\n", "\n" })
  local count = 0
  while Fuzz.more(src, count, 4) do
    count = count + 1
    fields[#fields + 1] = "h" .. Fuzz.pick(src, NAMES) .. "\0" .. Fuzz.pick(src, VALUES)
  end
  fields[#fields + 1] = "f" .. Fuzz.pick(src, { "none", "length", "chunked" })
  local chunks = 0
  while Fuzz.more(src, chunks, 4) do
    chunks = chunks + 1
    fields[#fields + 1] = "c" .. (src:int(0, 3) == 0 and Fuzz.bytes(src, 8) or Fuzz.pick(src, CHUNKS))
  end
end

--- The requests `fields` hold, from the first "r" on.
local function requests_of(fields: {string}): {Request}
  local out: {Request} = {}
  local current: Request = nil
  for _, f in ipairs(fields) do
    local letter, text = f:sub(1, 1), f:sub(2)
    if letter == "r" then
      current = { method = "GET", target = 1, version = "HTTP/1.1", eol = "\r\n", headers = {},
        framing = "none", chunks = {} }
      out[#out + 1] = current
    elseif current ~= nil then
      if letter == "m" then current.method = text
      elseif letter == "t" then current.target = math.tointeger(tonumber(text)) or 1
      elseif letter == "v" then current.version = text
      elseif letter == "e" then current.eol = text
      elseif letter == "h" then
        local zero = text:find("\0", 1, true) or #text + 1
        current.headers[#current.headers + 1] = { text:sub(1, zero - 1), text:sub(zero + 1) }
      elseif letter == "f" then current.framing = text
      elseif letter == "c" then current.chunks[#current.chunks + 1] = text
      end
    end
  end
  return out
end

--- `r` as the bytes a client sends: its head's lines ended by `eol`,
--- and a chunked body's by CRLF, as a server holds them to. An
--- HTTP/1.0 request is never chunked, which that version cannot carry.
local function written(r: Request): string
  local eol = r.eol
  local framing = r.framing
  if framing == "chunked" and r.version == "HTTP/1.0" then framing = "length" end
  local lines: {string} = { r.method .. " " .. TARGETS[r.target][1] .. " " .. r.version, "Host: h.test" }
  for _, pair in ipairs(r.headers) do lines[#lines + 1] = pair[1] .. ": " .. pair[2] end
  local body = table.concat(r.chunks)
  local encoded = ""
  if framing == "length" then
    lines[#lines + 1] = "Content-Length: " .. #body
    encoded = body
  elseif framing == "chunked" then
    lines[#lines + 1] = "Transfer-Encoding: chunked"
    local parts: {string} = {}
    for _, chunk in ipairs(r.chunks) do
      if chunk ~= "" then parts[#parts + 1] = ("%x"):format(#chunk) .. "\r\n" .. chunk .. "\r\n" end
    end
    parts[#parts + 1] = "0\r\n\r\n"
    encoded = table.concat(parts)
  end
  return table.concat(lines, eol) .. eol .. eol .. encoded
end

--- A Reader of `data` in pieces of `sizes`, then the rest whole; a read
--- asking for less gets less.
local record Pieces is Stream.Reader
  data: string
  sizes: {integer}
  at: integer
  next_size: integer
  read: function(Pieces, max_bytes?: integer): string | nil, string
  close: function(Pieces): boolean, string
end

local pieces_mt: metatable<Pieces> = { __index = Pieces }

function Pieces:read(max_bytes?: integer): string | nil, string
  if self.at > #self.data then return nil, "" end
  local n = self.sizes[self.next_size] or #self.data
  self.next_size = self.next_size + 1
  if max_bytes ~= nil and max_bytes < n then n = max_bytes end
  local piece = self.data:sub(self.at, self.at + n - 1)
  self.at = self.at + #piece
  return piece, ""
end

function Pieces:close(): boolean, string
  return true, ""
end

local function pieces(data: string, sizes: {integer}): Stream.Reader
  local r: Pieces = setmetatable({ data = data, sizes = sizes, at = 1, next_size = 1 }, pieces_mt)
  return r
end

--- What reading every request of `data`, cut into `sizes`, gives, as
--- text: each head's fields and its body, and how reading ended. Raises
--- where reading is not total and bounded: a status the server never
--- answers, a body past its limit, or more requests than bytes.
local function transcript(data: string, sizes: {integer}): string
  local input = wire.input(pieces(data, sizes))
  local out: {string} = {}
  for count = 1, #data + 1 do
    local read = wire.read_head(input, LIMITS)
    local head = read.head
    if head == nil then
      assert(read.status == 0 or REFUSALS[read.status], "status " .. read.status)
      if read.status ~= 0 then Fuzz.label("refused") end
      out[#out + 1] = "end " .. read.status
      return table.concat(out, "\n")
    end
    Fuzz.label("head")
    if count == 2 then Fuzz.label("second pipelined request") end
    local names: {string} = {}
    for name in pairs(head.headers) do names[#names + 1] = name end
    table.sort(names)
    local fields: {string} = { head.method, head.target, head.path, head.query, head.version,
      tostring(head.length), tostring(head.chunked), tostring(head.close), tostring(head.continue) }
    for _, name in ipairs(names) do fields[#fields + 1] = name .. "=" .. head.headers[name] end
    out[#out + 1] = table.concat(fields, "|")
    local body = wire.body(input, head, LIMITS)
    local got, _ = Stream.read_all(body)
    assert(got == nil or #got <= LIMITS.body_bytes, "a body past its limit")
    out[#out + 1] = "body " .. body.state .. " " .. (got or "")
    if body.state ~= "done" then return table.concat(out, "\n") end
    if got ~= nil and got ~= "" then
      Fuzz.label(head.chunked and "chunked body" or "content-length body")
    end
  end
  error("more requests read than bytes")
end

--- Requests, a few pipelined, sometimes edited, and where to cut them:
--- the bytes, then the size of each piece.
local function gen_bytes(src: Fuzz.Source): string
  local fields: {string} = {}
  local count = 0
  while count == 0 or Fuzz.more(src, count, 3) do
    count = count + 1
    draw_request(src, fields)
  end
  local parts: {string} = {}
  for _, r in ipairs(requests_of(fields)) do parts[#parts + 1] = written(r) end
  local data = table.concat(parts)
  if src:int(0, 2) == 0 then data = Fuzz.mutate(src, data, 4) end
  local packed: {string} = { data }
  while Fuzz.more(src, #packed - 1, 12) do packed[#packed + 1] = tostring(src:int(1, 24)) end
  return Fuzz.pack(packed)
end

local function bytes_and_sizes(input: string): string, {integer}
  local fields = Fuzz.unpack(input)
  local sizes: {integer} = {}
  for i = 2, #fields do sizes[#sizes + 1] = math.max(1, math.tointeger(tonumber(fields[i])) or 1) end
  return fields[1] or "", sizes
end

-- Reading any bytes ends, in a head or a refusal the server answers,
-- with no body past its limit.
local function test_reading_requests_is_total_and_bounded(tmp: string)
  Fuzz.run({
    name = "http wire total",
    dir = tmp,
    gen = gen_bytes,
    check = function(input: string): boolean, string
      local data, sizes = bytes_and_sizes(input)
      local _ = transcript(data, sizes)
      return true, ""
    end,
    requires = { "head", "content-length body", "chunked body", "second pipelined request", "refused" },
    shares = { head = 0.3 },
  })
end

-- The same bytes read the same however they arrive.
local function test_any_chunking_reads_the_same(tmp: string)
  Fuzz.run({
    name = "http wire chunking",
    dir = tmp,
    gen = gen_bytes,
    check = function(input: string): boolean, string
      local data, sizes = bytes_and_sizes(input)
      local whole = transcript(data, {})
      local cut = transcript(data, sizes)
      if whole ~= cut then return false, "whole:\n" .. whole .. "\ncut:\n" .. cut end
      local bytewise: {integer} = {}
      for i = 1, #data do bytewise[i] = 1 end
      local single = transcript(data, bytewise)
      if whole ~= single then return false, "whole:\n" .. whole .. "\na byte at a time:\n" .. single end
      return true, ""
    end,
    requires = { "head", "second pipelined request" },
  })
end

-- A request written out is read back as it was written.
local function test_a_written_request_reads_back(tmp: string)
  Fuzz.run({
    name = "http wire round trip",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local fields: {string} = {}
      draw_request(src, fields)
      return Fuzz.pack(fields)
    end,
    check = function(input: string): boolean, string
      local r = requests_of(Fuzz.unpack(input))[1]
      if r == nil then return true, "" end
      local framing = r.framing
      if framing == "chunked" and r.version == "HTTP/1.0" then framing = "length" end
      local body = table.concat(r.chunks)
      if #body > LIMITS.body_bytes then return true, "" end
      local in_put = wire.input(Stream.from_string(written(r)))
      local read = wire.read_head(in_put, LIMITS)
      local head = read.head
      local expectations: {string} = {}
      for _, pair in ipairs(r.headers) do
        if pair[1] == "Expect" and r.version == "HTTP/1.1" then
          for member in pair[2]:lower():gmatch("[^,]+") do
            local bare = member:match("^%s*(%S.-)%s*$")
            if bare ~= nil then expectations[#expectations + 1] = bare end
          end
        end
      end
      for _, expectation in ipairs(expectations) do
        if expectation ~= "100-continue" then
          if read.status ~= 417 then return false, "an expectation was taken: " .. expectation end
          Fuzz.label("refused expectation")
          return true, ""
        end
      end
      if head == nil then return false, "refused: " .. read.status .. " " .. read.why end
      local target = TARGETS[r.target]
      if head.method ~= r.method or head.target ~= target[1] or head.version ~= r.version or
          head.path ~= target[2] or head.query ~= target[3] then
        return false, "the request line read differs"
      end
      local expected: {string:string} = {}
      for _, pair in ipairs(r.headers) do
        local name = pair[1]:lower()
        expected[name] = expected[name] ~= nil and expected[name] .. ", " .. pair[2] or pair[2]
      end
      expected["host"] = target[4]
      if framing == "length" then expected["content-length"] = tostring(#body) end
      if framing == "chunked" then expected["transfer-encoding"] = "chunked" end
      for name, value in pairs(expected) do
        if head.headers[name] ~= value then
          return false, ("header %s: %q, not %q"):format(name, tostring(head.headers[name]), value)
        end
      end
      for name in pairs(head.headers) do
        if expected[name] == nil then return false, "header " .. name .. " was never sent" end
      end
      local got, why = Stream.read_all(wire.body(in_put, head, LIMITS))
      if got ~= (framing == "none" and "" or body) then return false, "the body differs: " .. why end
      if head.chunked ~= (framing == "chunked") then return false, "chunked differs" end
      if framing ~= "chunked" and head.length ~= (framing == "length" and #body or 0) then
        return false, "the length differs"
      end
      Fuzz.label(framing .. " framing")
      return true, ""
    end,
    requires = { "chunked framing", "length framing", "none framing" },
  })
end

--- A Reader body that ends short of a reply's length: the bytes it has.
local SHORT <const> = "short"

--- The spellings of a Content-Length header a handler gives.
local LENGTH_NAMES <const> = { "Content-Length", "content-length", "CONTENT-LENGTH" }

-- A reply carries no body where it may not, and its Content-Length is
-- the bytes sent after its head, one the handler gave held to them; a
-- reply cut short closes.
local function test_a_reply_is_framed_as_its_status_and_method_say(tmp: string)
  Fuzz.run({
    name = "http wire reply",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local status = src:int(0, 2) == 0 and src:int(100, 999) or
        Fuzz.pick(src, { 100, 200, 201, 204, 304, 404, 500 })
      return Fuzz.pack({
        Fuzz.pick(src, { "GET", "HEAD", "POST" }), tostring(status),
        Fuzz.pick(src, { "HTTP/1.1", "HTTP/1.0" }),
        Fuzz.pick(src, { "none", "string", "reader", "sized", SHORT }),
        src:int(0, 2) == 0 and "" or Fuzz.bytes(src, 40),
        -- A Content-Length the handler gives: none, the body's size, or
        -- one more.
        Fuzz.pick(src, { "", "", "same", "more" }), Fuzz.pick(src, LENGTH_NAMES),
      })
    end,
    check = function(input: string): boolean, string
      local f = Fuzz.unpack(input)
      local method, status, version, kind, text = f[1], math.tointeger(tonumber(f[2])), f[3], f[4], f[5]
      local given, given_name = f[6] or "", f[7] or "Content-Length"
      local reply: wire.Reply = { status = status, headers = { ["X-A"] = "1" }, method = method,
        version = version, date = "Thu, 01 Jan 1970 00:00:00 GMT" }
      if kind == "string" then reply.body = text end
      if kind == "reader" then reply.body = Stream.from_string(text) end
      if kind == "sized" then reply.body, reply.length = Stream.from_string(text), #text end
      if kind == SHORT then reply.body, reply.length = Stream.from_string(text), #text + 3 end
      local declared: integer = nil
      if given ~= "" then
        declared = given == "same" and #text or #text + 1
        reply.headers[given_name] = tostring(declared)
      end
      local bodiless = status < 200 or status == 204 or status == 304
      local sent_text = kind == "none" and "" or text
      local why = wire.check(reply)
      if bodiless and kind ~= "none" and not (kind == "string" and text == "") then
        if why == "" then return false, "a body for a " .. status .. " was taken" end
        Fuzz.label("bodiless")
        return true, ""
      end
      -- What a given size may not be: other than `length`, given a 1xx
      -- or 204, or not the body's, which is 0 for none but to HEAD.
      local own: integer = nil
      if kind == "string" and text ~= "" then
        own = #text
      elseif (kind == "none" or kind == "string") and method ~= "HEAD" then
        own = 0
      end
      if declared ~= nil and ((reply.length ~= nil and declared ~= reply.length) or
          (bodiless and status ~= 304) or (not bodiless and own ~= nil and declared ~= own)) then
        if why == "" then return false, "a Content-Length of " .. declared .. " was taken" end
        Fuzz.label("refused length")
        return true, ""
      end
      if why ~= "" then return false, "refused: " .. why end
      if declared ~= nil then Fuzz.label("given length") end
      -- A Reader given a size past its bytes ends short of it.
      local short = kind == SHORT or (kind == "reader" and given == "more")
      local sink = Stream.collect()
      local sent = wire.send(sink, reply)
      local out = sink:result()
      local stop = out:find("\r\n\r\n", 1, true)
      if stop == nil then return false, "no head" end
      local head, rest = out:sub(1, stop + 1), out:sub(stop + 4)
      local headers: {string:string} = {}
      for name, value in head:gmatch("\r\n([^:]+): ([^\r]*)") do
        if headers[name:lower()] ~= nil then return false, "header " .. name .. " is written twice" end
        headers[name:lower()] = value
      end
      if declared ~= nil and headers["content-length"] ~= tostring(declared) then
        return false, ("a Content-Length of %d was sent as %s"):format(declared,
          tostring(headers["content-length"]))
      end
      if bodiless then
        Fuzz.label("bodiless")
        if (declared == nil and headers["content-length"] ~= nil) or headers["transfer-encoding"] ~= nil then
          return false, "a " .. status .. " reply is framed"
        end
        if rest ~= "" then return false, "a " .. status .. " reply carries a body" end
        return true, ""
      end
      if method == "HEAD" then
        Fuzz.label("head")
        if rest ~= "" then return false, "a HEAD reply carries a body" end
      end
      local cl = headers["content-length"]
      if cl ~= nil then
        Fuzz.label("content-length")
        if method == "HEAD" then return true, "" end
        local n = math.tointeger(tonumber(cl))
        if short then
          if not (sent.close and sent.body_failure ~= "" and #rest < n) then
            return false, "a body cut short was not said so"
          end
        elseif #rest ~= n or rest ~= sent_text then
          return false, ("Content-Length %s, %d bytes sent"):format(cl, #rest)
        end
      elseif headers["transfer-encoding"] == "chunked" then
        Fuzz.label("chunked")
        if method == "HEAD" then return true, "" end
        local got: {string} = {}
        local at = 1
        while true do
          local size_text, after = rest:match("^(%x+)\r\n()", at)
          if size_text == nil then return false, "malformed chunks" end
          local size = math.tointeger(tonumber(size_text, 16))
          if size == 0 then
            if rest:sub(after) ~= "\r\n" then return false, "bytes after the last chunk" end
            break
          end
          got[#got + 1] = rest:sub(after, after + size - 1)
          at = after + size + 2
        end
        if table.concat(got) ~= sent_text then return false, "the chunks differ from the body" end
      else
        Fuzz.label("until close")
        if not (version == "HTTP/1.0" and kind == "reader" and sent.close) then
          return false, "a reply framed by neither length nor chunks keeps the connection"
        end
        if method ~= "HEAD" and rest ~= sent_text then return false, "the body differs" end
      end
      return true, ""
    end,
    requires = { "bodiless", "head", "content-length", "chunked", "until close", "given length",
      "refused length" },
  })
end
