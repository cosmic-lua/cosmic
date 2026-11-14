--- cosmic.http.message case by case: what a reader takes, what it
--- refuses and why, that where the feeds split decides nothing, and
--- what the formatters write.

local Message = require("cosmic.http.message")

--- Reads `text` as one request: fed whole, then the stream ended.
local function request(text: string, opts?: Message.Options): Message.RequestRead
  local reader = Message.request_reader(opts)
  local read = reader:feed(text)
  if read.status == "more" then read = reader:finish() end
  return read
end

--- Reads `text` as one response: fed whole, then the stream ended.
local function response(text: string, opts?: Message.Options): Message.ResponseRead
  local reader = Message.response_reader(opts)
  local read = reader:feed(text)
  if read.status == "more" then read = reader:finish() end
  return read
end

--- A header map as text, names in order.
local function listed(headers: {string:string}): string
  local names: mut {string} = {}
  for name in pairs(headers) do names[#names + 1] = name end
  table.sort(names)
  local out: mut {string} = {}
  for _, name in ipairs(names) do out[#out + 1] = name .. "=" .. (headers[name] or "") end
  return table.concat(out, "|")
end

--- What a request read says, as text, `next` left out: it is a
--- position in the last feed, so it differs with the split.
local function request_text(read: Message.RequestRead): string
  local got = read.request
  if got == nil then return read.status .. " " .. read.reason end
  return table.concat({ read.status, tostring(read.consumed), got.method, got.target, got.protocol,
    listed(got.headers), got.body }, "\n")
end

--- [`request_text`] for a response.
local function response_text(read: Message.ResponseRead): string
  local got = read.response
  if got == nil then return read.status .. " " .. read.reason end
  return table.concat({ read.status, tostring(read.consumed), got.protocol, tostring(got.status), got.reason,
    listed(got.headers), got.body }, "\n")
end

--- `text` read as a request, fed in pieces of `size` bytes.
local function request_in_pieces(text: string, size: integer, opts?: Message.Options): Message.RequestRead
  local reader = Message.request_reader(opts)
  for at = 1, #text, size do
    local read = reader:feed(text:sub(at, at + size - 1))
    if read.status ~= "more" then return read end
  end
  return reader:finish()
end

--- `text` read as a response, fed in pieces of `size` bytes.
local function response_in_pieces(text: string, size: integer, opts?: Message.Options): Message.ResponseRead
  local reader = Message.response_reader(opts)
  for at = 1, #text, size do
    local read = reader:feed(text:sub(at, at + size - 1))
    if read.status ~= "more" then return read end
  end
  return reader:finish()
end

--- Why `text` is refused as a request, whole and a byte at a time;
--- fails where it is taken or the two differ.
local function refusal(text: string, opts?: Message.Options): string
  local whole = request(text, opts)
  assert(whole.status == "refused", "not refused: " .. text)
  local bytewise = request_in_pieces(text, 1, opts)
  assert(bytewise.status == "refused" and bytewise.reason == whole.reason,
    ("%q: whole %q, a byte at a time %q"):format(text, whole.reason, bytewise.reason))
  assert(whole.request == nil and whole.consumed == 0 and whole.next == 1)
  return whole.reason
end

--- [`refusal`] of a response.
local function response_refusal(text: string, opts?: Message.Options): string
  local whole = response(text, opts)
  assert(whole.status == "refused", "not refused: " .. text)
  local bytewise = response_in_pieces(text, 1, opts)
  assert(bytewise.status == "refused" and bytewise.reason == whole.reason,
    ("%q: whole %q, a byte at a time %q"):format(text, whole.reason, bytewise.reason))
  return whole.reason
end

local function test_a_request_with_a_content_length_is_read_with_its_body()
  local text = "POST /a?b HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\nX-A:  1 \r\nx-a: 2\r\n\r\nhelloNEXT"
  local read = request(text)
  local got = assert(read.request, read.reason)
  assert(read.status == "done" and read.reason == "")
  assert(got.method == "POST" and got.target == "/a?b" and got.protocol == "HTTP/1.1")
  assert(got.body == "hello", got.body)
  assert(got.headers["host"] == "h" and got.headers["x-a"] == "1, 2", got.headers["x-a"])
  local values = assert(got.values["x-a"])
  assert(#values == 2 and values[1] == "1" and values[2] == "2")
  assert(text:sub(read.next) == "NEXT" and read.consumed == #text - 4, tostring(read.consumed))
end

local function test_a_request_with_no_length_has_no_body()
  local text = "GET / HTTP/1.1\r\nHost: h\r\n\r\nGET /2 HTTP/1.1\r\n\r\n"
  local read = request(text)
  local got = assert(read.request, read.reason)
  assert(got.body == "" and text:sub(read.next) == "GET /2 HTTP/1.1\r\n\r\n", tostring(read.next))
  -- A reader holds no rule above the message: no Host is taken.
  local second = assert(Message.request_reader():feed(text, read.next).request)
  assert(second.target == "/2" and next(second.headers) == nil)
end

local function test_repeated_headers_are_joined_and_kept_apart()
  local read = response("HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nContent-Length: 0\r\nset-cookie: b=2\r\n\r\n")
  local got = assert(read.response, read.reason)
  assert(got.headers["set-cookie"] == "a=1, b=2", got.headers["set-cookie"])
  local cookies = assert(got.values["set-cookie"])
  assert(#cookies == 2 and cookies[1] == "a=1" and cookies[2] == "b=2")
  local asked = assert(request("GET / HTTP/1.1\r\nCookie: a=1\r\nCookie: b=2\r\n\r\n").request)
  assert(asked.headers["cookie"] == "a=1; b=2", asked.headers["cookie"])
end

local function test_a_chunked_body_is_decoded_and_its_trailers_dropped()
  local text = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" ..
    "5;ext=1\r\nhello\r\n006\r\n world\r\n0\r\nX-Trailer: t\r\n\r\nrest"
  local read = request(text)
  local got = assert(read.request, read.reason)
  assert(got.body == "hello world", got.body)
  assert(got.headers["x-trailer"] == nil and text:sub(read.next) == "rest")
  assert(read.consumed == #text - 4)
  local answered = assert(response("HTTP/1.1 200 OK\r\ntransfer-encoding: Chunked\r\n\r\n1\r\na\r\n0\r\n\r\n").response)
  assert(answered.body == "a")
end

local function test_a_response_with_no_length_runs_to_the_end_of_the_stream()
  local reader = Message.response_reader()
  assert(reader:feed("HTTP/1.0 200 OK\r\nServer: s\r\n\r\nall of").status == "more")
  assert(reader:feed(" it").status == "more")
  local read = reader:finish()
  local got = assert(read.response, read.reason)
  assert(got.body == "all of it" and got.protocol == "HTTP/1.0" and read.consumed == 39, tostring(read.consumed))
  assert(read.next == 1)
end

local function test_a_response_that_takes_no_body_ends_at_its_head()
  for _, status in ipairs({ "100", "101", "204", "304" }) do
    local text = "HTTP/1.1 " .. status .. " X\r\nContent-Length: 5\r\n\r\nNEXT!"
    local read = response(text)
    local got = assert(read.response, read.reason)
    assert(got.body == "" and text:sub(read.next) == "NEXT!", status)
  end
  local head = response("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nNEXT!", { head_only = true })
  assert(assert(head.response).body == "" and head.next == 39)
  local chunked = response("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nNEXT!", { head_only = true })
  assert(assert(chunked.response).body == "" and chunked.next == 48)
  -- The framing a bodiless response names is still held to the grammar.
  assert(response_refusal("HTTP/1.1 204 No Content\r\nContent-Length: x\r\n\r\n") == "Content-Length is not digits")
end

local function test_a_status_line_is_read_with_or_without_a_reason()
  local with = assert(response("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n").response)
  assert(with.status == 404 and with.reason == "Not Found")
  local without = assert(response("HTTP/1.1 200\r\nContent-Length: 0\r\n\r\n").response)
  assert(without.status == 200 and without.reason == "")
  local blank = assert(response("HTTP/1.1 200 \r\nContent-Length: 0\r\n\r\n").response)
  assert(blank.reason == "")
  assert(response_refusal("HTTP/1.1 200OK\r\n\r\n") == "the status line is not protocol, status and reason")
  assert(response_refusal("HTTP/1.1 20 OK\r\n\r\n") == "the status line is not protocol, status and reason")
  assert(response_refusal("HTTP/1.1 2000 OK\r\n\r\n") == "the status line is not protocol, status and reason")
  assert(response_refusal("HTTP/1.1 099 Low\r\n\r\n") == "the status is below 100")
  assert(response_refusal("HTTP/1.1 200 a\0b\r\n\r\n") == "the reason phrase holds a control byte")
  assert(response_refusal("GET / HTTP/1.1\r\n\r\n") == "the status line is not protocol, status and reason")
end

local function test_rtsp_is_read_where_it_is_asked_for()
  local rtsp: Message.Options = { protocol = "RTSP/1.0" }
  local asked = request("DESCRIBE rtsp://cam.test/stream RTSP/1.0\r\nCSeq: 2\r\nAccept: application/sdp\r\n\r\n", rtsp)
  local got = assert(asked.request, asked.reason)
  assert(got.method == "DESCRIBE" and got.target == "rtsp://cam.test/stream" and got.protocol == "RTSP/1.0")
  assert(got.headers["cseq"] == "2" and got.body == "")
  local sdp = "v=0\r\nm=video 0 RTP/AVP 96\r\n"
  local answered = response("RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Type: application/sdp\r\nContent-Length: " ..
      tostring(#sdp) .. "\r\n\r\n" .. sdp, rtsp)
  local reply = assert(answered.response, answered.reason)
  assert(reply.protocol == "RTSP/1.0" and reply.status == 200 and reply.body == sdp)
  local star = assert(request("OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n", rtsp).request)
  assert(star.target == "*")
end

local function test_a_protocol_not_asked_for_is_refused()
  assert(refusal("OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n") == "the protocol is not HTTP/1.0 or HTTP/1.1")
  assert(refusal("GET / HTTP/2.0\r\n\r\n") == "the protocol is not HTTP/1.0 or HTTP/1.1")
  assert(refusal("GET / http/1.1\r\n\r\n") == "the protocol is not HTTP/1.0 or HTTP/1.1")
  local rtsp: Message.Options = { protocol = "RTSP/1.0" }
  assert(refusal("GET / HTTP/1.1\r\n\r\n", rtsp) == "the protocol is not RTSP/1.0")
  assert(refusal("OPTIONS * RTSP/2.0\r\n\r\n", rtsp) == "the protocol is not RTSP/1.0")
  assert(response_refusal("HTTP/1.1 200 OK\r\n\r\n", rtsp) == "the protocol is not RTSP/1.0")
  assert(assert(request("GET / HTTP/1.0\r\n\r\n").request).protocol == "HTTP/1.0")
  assert(refusal("GET / HTTP/1.1\r\n\r\n", { protocol = "HTTP/1.0" }) == "the protocol is not HTTP/1.0")
end

local function test_a_malformed_first_line_is_refused()
  local why = "the request line is not method, target and protocol"
  assert(refusal("GET /\r\n\r\n") == why)
  assert(refusal("GET  / HTTP/1.1\r\n\r\n") == why)
  assert(refusal("GET / HTTP/1.1 \r\n\r\n") == why)
  assert(refusal(" GET / HTTP/1.1\r\n\r\n") == why)
  assert(refusal("GET /a b HTTP/1.1\r\n\r\n") == why)
  assert(refusal("G(T / HTTP/1.1\r\n\r\n") == "the method is no token")
  assert(refusal("GET /\1 HTTP/1.1\r\n\r\n") == "the target holds a byte outside visible ASCII")
  assert(refusal("GET /\xc3\xa9 HTTP/1.1\r\n\r\n") == "the target holds a byte outside visible ASCII")
  assert(refusal("GET /\t HTTP/1.1\r\n\r\n") == "the target holds a byte outside visible ASCII")
end

local function test_a_line_end_that_is_not_crlf_is_refused()
  assert(refusal("GET / HTTP/1.1\nHost: h\r\n\r\n") == "a line ends in a bare LF")
  assert(refusal("GET / HTTP/1.1\r\nHost: h\n\r\n") == "a line ends in a bare LF")
  assert(refusal("GET / HTTP/1.1\r\nHost: h\r\n\n") == "a line ends in a bare LF")
  assert(refusal("\nGET / HTTP/1.1\r\n\r\n") == "a line ends in a bare LF")
  assert(refusal("GET / HTTP/1.1\r\nA: b\rc\r\n\r\n") == "a line holds a bare CR")
  assert(refusal("GET / HTTP/1.1\r\r\n\r\n") == "a line holds a bare CR")
  assert(refusal("GET / HTTP/1.1\r\nA: b\r\r\n\r\n") == "a line holds a bare CR")
end

local function test_blank_lines_before_the_first_line_are_passed_over()
  local read = request("\r\n\r\nGET / HTTP/1.1\r\n\r\n")
  assert(assert(read.request).method == "GET" and read.consumed == 22)
end

local function test_a_malformed_header_line_is_refused()
  assert(refusal("GET / HTTP/1.1\r\n folded: x\r\n\r\n") == "a header line is folded (obs-fold)")
  assert(refusal("GET / HTTP/1.1\r\nA: b\r\n\tmore\r\n\r\n") == "a header line is folded (obs-fold)")
  assert(refusal("GET / HTTP/1.1\r\nno colon\r\n\r\n") == "a header line holds no ':'")
  assert(refusal("GET / HTTP/1.1\r\nA : b\r\n\r\n") == "a header's name is no token (space before ':'?)")
  assert(refusal("GET / HTTP/1.1\r\n: b\r\n\r\n") == "a header's name is no token (space before ':'?)")
  assert(refusal("GET / HTTP/1.1\r\nA: b\0c\r\n\r\n") == "header A holds a control byte")
  assert(refusal("GET / HTTP/1.1\r\nA: b\127\r\n\r\n") == "header A holds a control byte")
  assert(assert(request("GET / HTTP/1.1\r\nA: b\tc\r\n\r\n").request).headers["a"] == "b\tc")
end

--- The shapes that let two readers disagree on where a message ends.
local function test_request_smuggling_shapes_are_refused()
  local both = "a message holds both Content-Length and Transfer-Encoding"
  assert(refusal("POST / HTTP/1.1\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n") == both)
  assert(refusal("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\n0\r\n\r\n") == both)
  assert(response_refusal("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n") == both)
  assert(refusal("POST / HTTP/1.1\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\nabcde") == "Content-Length's values differ")
  assert(refusal("POST / HTTP/1.1\r\nContent-Length: 4, 5\r\n\r\nabcde") == "Content-Length's values differ")
  assert(refusal("POST / HTTP/1.1\r\nContent-Length: +4\r\n\r\nabcd") == "Content-Length is not digits")
  assert(refusal("POST / HTTP/1.1\r\nContent-Length: 4 4\r\n\r\nabcd") == "Content-Length is not digits")
  assert(refusal("POST / HTTP/1.1\r\nContent-Length: 0x4\r\n\r\nabcd") == "Content-Length is not digits")
  assert(refusal("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == "Content-Length is not digits")
  assert(refusal("POST / HTTP/1.1\r\nContent-Length:\r\n\r\n") == "Content-Length is empty")
  assert(refusal("POST / HTTP/1.1\r\nContent-Length : 4\r\n\r\nabcd") == "a header's name is no token (space before ':'?)")
  assert(refusal("POST / HTTP/1.1\r\nContent-Length: 4\r\n Transfer-Encoding: chunked\r\n\r\n") ==
      "a header line is folded (obs-fold)")
  local coding = "the transfer coding is not chunked alone"
  assert(refusal("POST / HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n") == coding)
  assert(refusal("POST / HTTP/1.1\r\nTransfer-Encoding: chunked, chunked\r\n\r\n0\r\n\r\n") == coding)
  assert(refusal("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n") == coding)
  assert(refusal("POST / HTTP/1.1\r\nTransfer-Encoding: xchunked\r\n\r\n0\r\n\r\n") == coding)
  assert(refusal("POST / HTTP/1.1\r\nTransfer-Encoding: identity\r\n\r\n") == coding)
  assert(refusal("POST / HTTP/1.1\r\nTransfer-Encoding:\r\n\r\n") == coding)
  assert(response_refusal("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n") == coding)
  local version = "a message that is not HTTP/1.1 holds Transfer-Encoding"
  assert(refusal("POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n") == version)
  assert(refusal("SETUP * RTSP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", { protocol = "RTSP/1.0" }) == version)
  -- Values that agree are one length (RFC 9112 6.3).
  assert(assert(request("POST / HTTP/1.1\r\nContent-Length: 4\r\nContent-Length: 04\r\n\r\nabcd").request).body == "abcd")
end

local function test_malformed_chunked_framing_is_refused()
  local head = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
  assert(refusal(head .. "x\r\n") == "a chunk's size is not hex")
  assert(refusal(head .. "\r\n") == "a chunk's size is not hex")
  assert(refusal(head .. "-1\r\n") == "a chunk's size is not hex")
  assert(refusal(head .. "0x5\r\nhello\r\n0\r\n\r\n") == "a chunk's extension is malformed")
  assert(refusal(head .. "5 5\r\nhello\r\n0\r\n\r\n") == "a chunk's extension is malformed")
  assert(refusal(head .. "5\nhello\r\n0\r\n\r\n") == "a line ends in a bare LF")
  assert(refusal(head .. "5\r\nhello\n0\r\n\r\n") == "a line ends in a bare LF")
  assert(refusal(head .. "5\r\nhelloX\r\n0\r\n\r\n") == "a chunk's data is not followed by CRLF")
  assert(refusal(head .. "5\r\nhello!\n0\r\n\r\n") == "a line ends in a bare LF")
  assert(refusal(head .. "5\r\nhello\r\r\n") == "a chunk's data is not followed by CRLF")
  assert(refusal(head .. "0\r\nbad trailer\r\n\r\n") == "a trailer is malformed: a header line holds no ':'")
  assert(refusal(head .. "0\r\n folded: t\r\n\r\n") == "a trailer is malformed: a header line is folded (obs-fold)")
  assert(refusal(head .. "ffffffffffffffff\r\n") == "the body is longer than 1048576 bytes")
  assert(refusal(head .. "5\r\nhel") == "the stream ended within a message")
  assert(refusal(head .. "5\r\nhello\r\n0\r\n") == "the stream ended within a message")
end

local function test_each_limit_is_held()
  local small: Message.Options = { head_bytes = 64, line_bytes = 32, max_headers = 2, body_bytes = 8 }
  assert(assert(request("GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\n\r\n", small).request).headers["b"] == "2")
  assert(refusal("GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n", small) == "more than 2 headers")
  assert(refusal("GET /" .. ("a"):rep(40) .. " HTTP/1.1\r\n\r\n", small) == "a line is longer than 32 bytes")
  assert(refusal("GET / HTTP/1.1\r\nA: " .. ("a"):rep(40), small) == "a line is longer than 32 bytes")
  -- A line of exactly line_bytes, its CRLF counted, is taken.
  assert(request("GET /" .. ("a"):rep(16) .. " HTTP/1.1\r\n\r\n", small).status == "done")
  assert(refusal("GET /" .. ("a"):rep(17) .. " HTTP/1.1\r\n\r\n", small) == "a line is longer than 32 bytes")
  local long = "GET / HTTP/1.1\r\nA: " .. ("a"):rep(20) .. "\r\nB: " .. ("b"):rep(17) .. "\r\n\r\n"
  assert(#long == 65 and refusal(long, small) == "the head is longer than 64 bytes")
  local fits = "GET / HTTP/1.1\r\nA: " .. ("a"):rep(20) .. "\r\nB: " .. ("b"):rep(16) .. "\r\n\r\n"
  assert(#fits == 64 and request(fits, small).status == "done")
  assert(refusal(("\r\n"):rep(40), small) == "the head is longer than 64 bytes")
  assert(refusal("POST / HTTP/1.1\r\nContent-Length: 9\r\n\r\n", small) == "the body is longer than 8 bytes")
  assert(refusal("POST / HTTP/1.1\r\nContent-Length: 99999999999999999999999\r\n\r\n", { body_bytes = 8 }) ==
      "the body is longer than 8 bytes")
  assert(assert(request("POST / HTTP/1.1\r\nContent-Length: 8\r\n\r\n12345678", small).request).body == "12345678")
  local chunked = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
  local roomy: Message.Options = { head_bytes = 64, body_bytes = 8 }
  assert(refusal(chunked .. "5\r\nhello\r\n4\r\n", roomy) == "the body is longer than 8 bytes")
  assert(refusal(chunked .. "9\r\n", roomy) == "the body is longer than 8 bytes")
  assert(assert(request(chunked .. "5\r\nhello\r\n3\r\n wo\r\n0\r\n\r\n", roomy).request).body == "hello wo")
  -- Extensions, zeros before a size and trailers count against the head.
  local spent = "a chunked body's extensions and trailers pass 64 bytes"
  assert(refusal(chunked .. "1;" .. ("e"):rep(20) .. "\r\na\r\n", roomy) == spent)
  assert(refusal(chunked .. ("0"):rep(20) .. "1\r\na\r\n", roomy) == spent)
  assert(refusal(chunked .. "0\r\nT: " .. ("t"):rep(20) .. "\r\n\r\n", roomy) == spent)
  assert(response_refusal("HTTP/1.1 200 OK\r\n\r\n123456789", roomy) == "the body is longer than 8 bytes")
  assert(assert(response("HTTP/1.1 200 OK\r\n\r\n12345678", roomy).response).body == "12345678")
end

local function test_the_stream_ending_is_empty_before_a_message_and_a_refusal_within_one()
  assert(Message.request_reader():finish().status == "empty")
  assert(Message.response_reader():finish().status == "empty")
  assert(request("\r\n\r\n").status == "empty")
  for _, cut in ipairs({ "G", "GET / HTTP/1.1\r", "GET / HTTP/1.1\r\n", "GET / HTTP/1.1\r\nA: b\r\n",
      "POST / HTTP/1.1\r\nContent-Length: 3\r\n\r\nab" }) do
    assert(refusal(cut) == "the stream ended within a message", cut)
  end
  assert(response_refusal("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nab") == "the stream ended within a message")
end

local function test_an_answer_but_more_is_final()
  local reader = Message.request_reader()
  local done = reader:feed("GET / HTTP/1.1\r\n\r\nrest")
  assert(done.status == "done" and done.next == 19)
  assert(reader:feed("GET /other HTTP/1.1\r\n\r\n") == done and reader:finish() == done)
  local refuser = Message.response_reader()
  local refused = refuser:feed("nonsense\r\n")
  assert(refused.status == "refused")
  assert(refuser:feed("HTTP/1.1 200 OK\r\n\r\n") == refused and refuser:finish() == refused)
  local ended = Message.request_reader()
  local empty = ended:finish()
  assert(ended:feed("GET / HTTP/1.1\r\n\r\n") == empty and empty.status == "empty")
end

--- Messages of every framing, each cut in two at every byte and fed a
--- byte at a time.
local function test_where_the_feeds_split_decides_nothing()
  local requests = {
    "GET / HTTP/1.1\r\nHost: h\r\n\r\n",
    "\r\nPOST /p HTTP/1.1\r\nContent-Length: 11\r\nA: 1\r\na: 2\r\n\r\nhello world",
    "PUT / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5;x=y\r\nhello\r\n1\r\n!\r\n0\r\nT: t\r\n\r\n",
    "GET / HTTP/1.1\r\nA: b\rc\r\n\r\n",
    "POST / HTTP/1.1\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n",
    "PUT / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloXX\r\n0\r\n\r\n",
    "GET / HTTP/1.1\r\nA: " .. ("a"):rep(80) .. "\r\n\r\n",
  }
  local opts: Message.Options = { line_bytes = 64 }
  for _, text in ipairs(requests) do
    local whole = request_text(request(text, opts))
    for cut = 1, #text - 1 do
      local reader = Message.request_reader(opts)
      local read = reader:feed(text:sub(1, cut))
      if read.status == "more" then read = reader:feed(text:sub(cut + 1)) end
      if read.status == "more" then read = reader:finish() end
      assert(request_text(read) == whole, ("cut at %d of %q: %s"):format(cut, text, request_text(read)))
    end
    assert(request_text(request_in_pieces(text, 1, opts)) == whole, text)
    assert(request_text(request_in_pieces(text, 3, opts)) == whole, text)
  end
  local responses = {
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    "HTTP/1.1 200 OK\r\n\r\nto the end",
    "HTTP/1.1 204 No Content\r\n\r\n",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n",
    "HTTP/1.1 200\tOK\r\n\r\n",
  }
  for _, text in ipairs(responses) do
    local whole = response_text(response(text))
    for cut = 1, #text - 1 do
      local reader = Message.response_reader()
      local read = reader:feed(text:sub(1, cut))
      if read.status == "more" then read = reader:feed(text:sub(cut + 1)) end
      if read.status == "more" then read = reader:finish() end
      assert(response_text(read) == whole, ("cut at %d of %q: %s"):format(cut, text, response_text(read)))
    end
    assert(response_text(response_in_pieces(text, 1)) == whole, text)
  end
end

--- Three requests in one feed are read one after another, each reader
--- fed the chunk from where the one before stopped.
local function test_pipelined_messages_are_read_one_reader_each()
  local bytes = "GET /1 HTTP/1.1\r\n\r\n" ..
    "POST /2 HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc" ..
    "POST /3 HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\ndef\r\n0\r\n\r\n"
  local seen: mut {string} = {}
  local consumed = 0
  local at = 1
  while at <= #bytes do
    local read = Message.request_reader():feed(bytes, at)
    local got = assert(read.request, read.reason)
    seen[#seen + 1] = got.target .. "=" .. got.body
    consumed = consumed + read.consumed
    at = read.next
  end
  assert(table.concat(seen, " ") == "/1= /2=abc /3=def", table.concat(seen, " "))
  assert(consumed == #bytes)
  -- A feed that ends exactly at a message's end leaves nothing.
  local exact = Message.request_reader():feed("GET /1 HTTP/1.1\r\n\r\n")
  assert(exact.status == "done" and exact.next == 20 and exact.consumed == 19)
end

--- A body sent a byte at a time costs its length: a megabyte fed so
--- would not end under a reader that copied what it held at each feed.
local function test_a_large_body_fed_in_small_pieces_is_read()
  local body = ("0123456789abcdef"):rep(4096)
  local text = "POST / HTTP/1.1\r\nContent-Length: " .. tostring(#body) .. "\r\n\r\n" .. body
  local read = request_in_pieces(text, 7)
  assert(assert(read.request, read.reason).body == body)
end

--- A feed of many lines costs its length: a reader that copied the rest
--- of the feed at each line would spend the square of it, and not end
--- within a test's time.
local function test_a_feed_of_many_lines_is_read_in_time_linear_in_it()
  local chunks: mut {string} = { "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" }
  for _ = 1, 200000 do chunks[#chunks + 1] = "1\r\na\r\n" end
  chunks[#chunks + 1] = "0\r\n\r\n"
  local read = request(table.concat(chunks))
  assert(#assert(read.request, read.reason).body == 200000)
  local blank = request(("\r\n"):rep(500000) .. "GET / HTTP/1.1\r\n\r\n", { head_bytes = 2 * 1024 * 1024 })
  assert(blank.status == "done", blank.reason)
end

--- Many small messages in one feed cost its length: an answer that
--- copied the bytes after its message would cost the square of it.
local function test_many_pipelined_messages_in_one_feed_are_read_in_time_linear_in_it()
  local bytes = ("GET / HTTP/1.1\r\n\r\n"):rep(100000)
  local count, at = 0, 1
  while at <= #bytes do
    local read = Message.request_reader():feed(bytes, at)
    assert(read.status == "done", read.reason)
    count, at = count + 1, read.next
  end
  assert(count == 100000 and at == #bytes + 1)
end

--- A chunked body's extensions, zeros and trailers may bring the head's
--- count to head_bytes and no further.
local function test_chunked_framing_is_counted_to_the_byte()
  local head = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
  assert(#head == 47)
  -- 4 of extension, 4 of zeros and 6 of trailer: 61 in all.
  local body = "1;abc\r\na\r\n000001\r\nb\r\n0\r\nT: t\r\n\r\n"
  assert(assert(request(head .. body, { head_bytes = 61 }).request).body == "ab")
  assert(refusal(head .. body, { head_bytes = 60 }) == "a chunked body's extensions and trailers pass 60 bytes")
end

--- A position before the chunk's first byte reads from the first, and
--- one past its last reads nothing: neither counts from the chunk's end,
--- as a negative position given to a string function would.
local function test_a_position_outside_the_chunk_is_held_to_it()
  local bytes = "GET /1 HTTP/1.1\r\n\r\nGET /2 HTTP/1.1\r\n\r\n"
  for _, from in ipairs({ 0, -1, -19, math.mininteger }) do
    local read = Message.request_reader():feed(bytes, from)
    assert(assert(read.request, read.reason).target == "/1" and read.next == 20 and read.consumed == 19, tostring(from))
  end
  for _, from in ipairs({ #bytes + 1, #bytes + 100, math.maxinteger }) do
    local reader = Message.request_reader()
    assert(reader:feed(bytes, from).status == "more" and reader:finish().status == "empty", tostring(from))
  end
end

local function test_options_that_are_not_what_they_say_raise()
  local ok, why = pcall(Message.request_reader, { protocol = "rtsp" })
  assert(not ok and tostring(why):find("is not a name and version", 1, true) ~= nil, tostring(why))
  ok, why = pcall(Message.response_reader, { body_bytes = 0 })
  assert(not ok and tostring(why):find("body_bytes must be positive", 1, true) ~= nil, tostring(why))
  ok, why = pcall(Message.request_reader, { max_headers = -1 })
  assert(not ok and tostring(why):find("max_headers must be positive", 1, true) ~= nil, tostring(why))
end

local function test_a_request_is_written_from_its_parts()
  local text = assert(Message.format_request({
    method = "POST", target = "/a?b",
    headers = { Host = "h.test", ["X-List"] = { "1", "2" }, Accept = "*/*" }, body = "hello",
  }))
  assert(text == "POST /a?b HTTP/1.1\r\nAccept: */*\r\nHost: h.test\r\nX-List: 1\r\nX-List: 2\r\n" ..
      "Content-Length: 5\r\n\r\nhello", text)
  assert(Message.format_request({ method = "GET", target = "/" }) == "GET / HTTP/1.1\r\n\r\n")
  local given = assert(Message.format_request({ method = "PUT", target = "/", body = "ab",
    headers = { ["content-length"] = "2" } }))
  assert(given == "PUT / HTTP/1.1\r\ncontent-length: 2\r\n\r\nab", given)
  local rtsp = assert(Message.format_request({ method = "PLAY", target = "rtsp://cam.test/stream",
    protocol = "RTSP/1.0", headers = { CSeq = "4", Session = "12345678" } }))
  assert(rtsp == "PLAY rtsp://cam.test/stream RTSP/1.0\r\nCSeq: 4\r\nSession: 12345678\r\n\r\n", rtsp)
end

local function test_a_response_is_written_from_its_parts()
  local text = assert(Message.format_response({ status = 404, headers = { ["Content-Type"] = "text/plain" },
    body = "no\n" }))
  assert(text == "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 3\r\n\r\nno\n", text)
  assert(Message.format_response({ status = 204 }) == "HTTP/1.1 204 No Content\r\n\r\n")
  assert(Message.format_response({ status = 204, body = "" }) == "HTTP/1.1 204 No Content\r\n\r\n")
  assert(Message.format_response({ status = 200, body = "" }) == "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
  assert(Message.format_response({ status = 299, reason = "Fine" }) == "HTTP/1.1 299 Fine\r\n\r\n")
  assert(Message.format_response({ status = 299 }) == "HTTP/1.1 299 \r\n\r\n")
  local rtsp = assert(Message.format_response({ status = 200, protocol = "RTSP/1.0", headers = { CSeq = "4" } }))
  assert(rtsp == "RTSP/1.0 200 OK\r\nCSeq: 4\r\n\r\n", rtsp)
  -- A HEAD's reply names the size of a body it does not carry.
  local head = assert(Message.format_response({ status = 200, headers = { ["Content-Length"] = "10" } }))
  assert(head == "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n", head)
end

--- What a formatter refuses, with a fragment of why.
local function test_parts_a_reader_would_refuse_are_not_written()
  local function request_why(parts: Message.RequestParts): string
    local text, why = Message.format_request(parts)
    assert(text == nil, "written: " .. tostring(text))
    return why
  end
  local function response_why(parts: Message.ResponseParts): string
    local text, why = Message.format_response(parts)
    assert(text == nil, "written: " .. tostring(text))
    return why
  end
  assert(request_why({ method = "G T", target = "/" }) == "the method is no token")
  assert(request_why({ method = "", target = "/" }) == "the method is no token")
  assert(request_why({ method = "GET", target = "/a b" }) == "the target holds a byte outside visible ASCII")
  assert(request_why({ method = "GET", target = "" }) == "the target holds a byte outside visible ASCII")
  assert(request_why({ method = "GET", target = "/\r\nX: y" }) == "the target holds a byte outside visible ASCII")
  assert(request_why({ method = "GET", target = "/", protocol = "HTTP/1.1\r\nX: y" }):find("name and version", 1, true))
  assert(request_why({ method = "GET", target = "/", headers = { ["A B"] = "1" } }):find("its name is no token", 1, true))
  assert(request_why({ method = "GET", target = "/", headers = { A = "1\r\nB: 2" } }):find("control byte", 1, true))
  assert(request_why({ method = "GET", target = "/", headers = { A = { "ok", "1\n2" } } }):find("control byte", 1, true))
  assert(request_why({ method = "PUT", target = "/", body = "abc", headers = { ["Content-Length"] = "2" } }) ==
      "the Content-Length is 2, but the body is 3 bytes")
  assert(request_why({ method = "PUT", target = "/", headers = { ["Content-Length"] = "x" } }) ==
      "Content-Length is not one value of at most 18 digits")
  assert(request_why({ method = "PUT", target = "/", headers = { ["Content-Length"] = { "1", "1" } } }) ==
      "Content-Length is not one value of at most 18 digits")
  assert(request_why({ method = "PUT", target = "/",
    headers = { ["Content-Length"] = "1", ["content-length"] = "1" } }) == "Content-Length is given twice")
  assert(request_why({ method = "PUT", target = "/", headers = { ["Content-Length"] = ("9"):rep(19) } }) ==
      "Content-Length is not one value of at most 18 digits")
  local coded = "Transfer-Encoding"
  assert(request_why({ method = "PUT", target = "/", headers = { [coded] = "chunked", ["Content-Length"] = "0" } }) ==
      "Content-Length and Transfer-Encoding are both given")
  assert(response_why({ status = 200, headers = { [coded] = "chunked", ["content-length"] = "0" } }) ==
      "Content-Length and Transfer-Encoding are both given")
  assert(request_why({ method = "PUT", target = "/", headers = { [coded] = "gzip" } }) ==
      "the Transfer-Encoding is not chunked alone")
  assert(request_why({ method = "PUT", target = "/", headers = { [coded] = { "chunked", "chunked" } } }) ==
      "the Transfer-Encoding is not chunked alone")
  assert(request_why({ method = "PUT", target = "/",
    headers = { [coded] = "chunked", ["transfer-encoding"] = "chunked" } }) == "Transfer-Encoding is given twice")
  assert(request_why({ method = "PUT", target = "/", protocol = "HTTP/1.0", headers = { [coded] = "chunked" } }) ==
      "Transfer-Encoding goes with HTTP/1.1 alone")
  assert(response_why({ status = 200, protocol = "RTSP/1.0", headers = { [coded] = "chunked" } }) ==
      "Transfer-Encoding goes with HTTP/1.1 alone")
  assert(request_why({ method = "PUT", target = "/", body = "a", headers = { ["Transfer-Encoding"] = "chunked" } })
      :find("Transfer-Encoding", 1, true))
  assert(response_why({ status = 99 }) == "the status is not from 100 to 999")
  assert(response_why({ status = 1000 }) == "the status is not from 100 to 999")
  assert(response_why({ status = 200, reason = "a\r\nb" }) == "the reason phrase holds a control byte")
  assert(response_why({ status = 204, body = "x" }) == "no body goes with the status")
  assert(response_why({ status = 200, protocol = "rtsp/1.0" }):find("name and version", 1, true))
end

--- A status that takes no body is written the same with none and with
--- an empty one, a length the headers give kept (a 304 names a 200's).
local function test_a_bodiless_status_takes_an_empty_body_as_none()
  local headers: {string: string | {string}} = { ["Content-Length"] = "5" }
  local none = assert(Message.format_response({ status = 304, headers = headers }))
  assert(none == "HTTP/1.1 304 Not Modified\r\nContent-Length: 5\r\n\r\n", none)
  assert(Message.format_response({ status = 304, headers = headers, body = "" }) == none)
end

--- A request with a Transfer-Encoding header and no body is the head of
--- a body the caller chunks itself.
local function test_a_head_for_a_body_the_caller_chunks_is_written()
  local head = assert(Message.format_request({ method = "POST", target = "/",
    headers = { ["Transfer-Encoding"] = "chunked" } }))
  local read = request(head .. "3\r\nabc\r\n0\r\n\r\n")
  assert(assert(read.request, read.reason).body == "abc")
  local cased = assert(Message.format_response({ status = 200, headers = { ["transfer-encoding"] = "Chunked" } }))
  assert(cased == "HTTP/1.1 200 OK\r\ntransfer-encoding: Chunked\r\n\r\n", cased)
end
