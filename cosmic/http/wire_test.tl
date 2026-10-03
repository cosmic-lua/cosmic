--- cosmic.http.wire's reading of a request, case by case: what it
--- takes and what it refuses, with the status the server answers.

local Stream = require("cosmic.stream")
local wire = require("cosmic.http.wire")

local LIMITS <const>: wire.Limits = { head_bytes = 1024, body_bytes = 100 }

--- What reading `text` as one request's head gives.
local function read(text: string, limits?: wire.Limits): wire.Read
  return wire.read_head(wire.input(Stream.from_string(text)), limits or LIMITS)
end

--- The status reading `text` is refused with, failing where it is not.
local function refusal(text: string, limits?: wire.Limits): integer
  local got = read(text, limits)
  assert(got.head == nil, "taken: " .. text)
  return got.status
end

local function test_the_three_target_forms_are_read()
  local origin = assert(read("GET /a/b%20c?x=1&y HTTP/1.1\r\nHost: h\r\n\r\n").head)
  assert(origin.path == "/a/b%20c" and origin.query == "x=1&y", origin.path)
  local absolute = assert(read("GET http://H.test:8080?q HTTP/1.1\r\nHost: h\r\n\r\n").head)
  assert(absolute.path == "/" and absolute.query == "q", absolute.path)
  assert(absolute.headers["host"] == "h.test:8080", absolute.headers["host"])
  local v6 = assert(read("GET http://[::1]/ HTTP/1.1\r\nHost: h\r\n\r\n").head)
  assert(v6.headers["host"] == "[::1]", v6.headers["host"])
  assert(absolute.target == "http://H.test:8080?q")
  local star = assert(read("OPTIONS * HTTP/1.1\r\nHost: h\r\n\r\n").head)
  assert(star.path == "*" and star.query == "")
  assert(refusal("GET * HTTP/1.1\r\nHost: h\r\n\r\n") == 400)
  assert(refusal("CONNECT h.test:443 HTTP/1.1\r\nHost: h\r\n\r\n") == 400)
  assert(refusal("GET ftp://h/ HTTP/1.1\r\nHost: h\r\n\r\n") == 400)
  assert(refusal("GET http://u@h/ HTTP/1.1\r\nHost: h\r\n\r\n") == 400)
  assert(refusal("GET /a#b HTTP/1.1\r\nHost: h\r\n\r\n") == 400)
end

--- Bare LF ends a line as CRLF does, blank lines before the request
--- line are passed over, and repeated headers are joined.
local function test_a_lenient_head_is_read_as_its_strict_form()
  local got = assert(read("\r\n\nGET / HTTP/1.1\nHost: h\nAccept: a\r\naccept:  b \n\n").head)
  assert(got.headers["accept"] == "a, b", got.headers["accept"])
  assert(got.headers["host"] == "h")
  assert(got.length == 0 and not got.chunked and not got.close)
end

local function test_a_version_but_1_0_and_1_1_is_505_and_a_malformed_one_400()
  assert(refusal("GET / HTTP/2.0\r\nHost: h\r\n\r\n") == 505)
  assert(refusal("GET / HTTP/0.9\r\n\r\n") == 505)
  assert(refusal("GET / http/1.1\r\nHost: h\r\n\r\n") == 400)
  assert(refusal("GET /\r\n\r\n") == 400)
  assert(refusal("GET  / HTTP/1.1\r\nHost: h\r\n\r\n") == 400)
  local old = assert(read("GET / HTTP/1.0\r\n\r\n").head)
  assert(old.close)
end

local function test_host_must_be_named_once_in_1_1()
  assert(refusal("GET / HTTP/1.1\r\n\r\n") == 400)
  assert(refusal("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n") == 400)
  assert(refusal("GET / HTTP/1.0\r\nHost: a\r\nHost: a\r\n\r\n") == 400)
end

local function test_malformed_header_lines_are_400()
  for _, bad in ipairs({
    "Host: h\r\nX: a\rb\r\n",
    "Host: h\r\nX: a\r\n folded\r\n",
    "Host: h\r\nX : a\r\n",
    "Host: h\r\n: a\r\n",
    "Host: h\r\nno colon\r\n",
    "Host: h\r\nX: a\0b\r\n",
    "Host: h\r\nX: a\1b\r\n",
  }) do
    assert(refusal("GET / HTTP/1.1\r\n" .. bad .. "\r\n") == 400, bad)
  end
  local tab = assert(read("GET / HTTP/1.1\r\nHost: h\r\nX:\ta\tb\t\r\n\r\n").head)
  assert(tab.headers["x"] == "a\tb")
end

--- A head past head_bytes is 431, counted with the blank lines before it.
local function test_a_head_past_its_limit_is_431()
  local limits: wire.Limits = { head_bytes = 64, body_bytes = 100 }
  local request = "GET / HTTP/1.1\r\nHost: h\r\n\r\n"
  assert(read(request, limits).head ~= nil)
  assert(refusal(string.rep("\r\n", 20) .. request, limits) == 431)
  assert(refusal("GET / HTTP/1.1\r\nHost: h\r\nX: " .. string.rep("a", 40) .. "\r\n\r\n", limits) == 431)
  assert(refusal("GET /" .. string.rep("a", 100), limits) == 431)
end

--- The refusals that keep one request from being read as two.
local function test_ambiguous_framing_is_refused()
  local head = "POST / HTTP/1.1\r\nHost: h\r\n"
  assert(refusal(head .. "Content-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n") == 400)
  assert(refusal(head .. "Content-Length: 3\r\nContent-Length: 4\r\n\r\n") == 400)
  assert(refusal(head .. "Content-Length: 3, 4\r\n\r\n") == 400)
  assert(refusal(head .. "Content-Length: +3\r\n\r\n") == 400)
  assert(refusal(head .. "Content-Length: 0x3\r\n\r\n") == 400)
  assert(refusal(head .. "Content-Length:\r\n\r\n") == 400)
  assert(refusal(head .. "Transfer-Encoding: gzip\r\n\r\n") == 400)
  assert(refusal(head .. "Transfer-Encoding: chunked, chunked\r\n\r\n") == 400)
  assert(refusal(head .. "Transfer-Encoding: gzip, chunked\r\n\r\n") == 501)
  assert(refusal("POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n") == 400)
  local agreed = assert(read(head .. "Content-Length: 3\r\nContent-Length: 003\r\n\r\n").head)
  assert(agreed.length == 3)
  local chunked = assert(read(head .. "Transfer-Encoding: Chunked\r\n\r\n").head)
  assert(chunked.chunked and chunked.length == nil)
end

--- An expectation but 100-continue is 417; that one, in any case, is
--- waited on, and HTTP/1.0's is not.
local function test_an_expectation_but_100_continue_is_417()
  assert(refusal("PUT / HTTP/1.1\r\nHost: h\r\nExpect: something\r\n\r\n") == 417)
  assert(refusal("PUT / HTTP/1.1\r\nHost: h\r\nExpect: 100-continue, x\r\n\r\n") == 417)
  assert(read("PUT / HTTP/1.1\r\nHost: h\r\nExpect: 100-Continue\r\n\r\n").head.continue)
  local old = assert(read("PUT / HTTP/1.0\r\nExpect: 100-continue\r\n\r\n").head)
  assert(not old.continue)
end

local function test_a_declared_body_past_its_limit_is_413()
  local head = "POST / HTTP/1.1\r\nHost: h\r\n"
  assert(refusal(head .. "Content-Length: 101\r\n\r\n") == 413)
  assert(refusal(head .. "Content-Length: 99999999999999999999999999\r\n\r\n") == 413)
  assert(read(head .. "Content-Length: 100\r\n\r\n").head.length == 100)
end

--- Where the input ends: before a byte, a clean end; within a head, a
--- failure; neither is refused.
local function test_an_end_is_no_refusal()
  local clean = read("")
  assert(clean.head == nil and clean.status == 0 and clean.why == "")
  local cut = read("GET / HTTP/1.1\r\nHo")
  assert(cut.head == nil and cut.status == 0 and cut.why ~= "")
end

--- The body of `text`, a whole request, read whole: the bytes, and how
--- the body stands after.
local function body_of(text: string, limits?: wire.Limits): string, string
  local input = wire.input(Stream.from_string(text))
  local head = assert(wire.read_head(input, limits or LIMITS).head)
  local body = wire.body(input, head, limits or LIMITS)
  local got, _ = Stream.read_all(body)
  return got or "", body.state
end

local function test_a_chunked_body_is_decoded_and_held_to_its_limits()
  local head = "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n"
  local got, state = body_of(head .. "3;a=b\r\nabc\r\nA\r\n0123456789\r\n0\r\nX-T: 1\r\n\r\n")
  assert(got == "abc0123456789" and state == "done", got)
  local _, over = body_of(head .. "65\r\n" .. string.rep("x", 101) .. "\r\n0\r\n\r\n")
  assert(over == "over", over)
  local _, huge = body_of(head .. "fffffffffffffffffff\r\n")
  assert(huge == "over", huge)
  local _, long_trailers = body_of(head .. "0\r\nX: " .. string.rep("a", 1100) .. "\r\n\r\n")
  assert(long_trailers == "over", long_trailers)
  for _, bad in ipairs({ "z\r\n", "3\r\nabcd\r\n", "3 x\r\nabc\r\n", "3\r\nabc\r\n0\r\nbad trailer\r\n\r\n",
      "3\r\nabc\rx\n" }) do
    local _, why = body_of(head .. bad)
    assert(why == "bad", bad .. ": " .. why)
  end
  local _, cut = body_of(head .. "5\r\nab")
  assert(cut == "failed", cut)
  -- A bare LF ends no line of chunked framing, where a proxy may read
  -- the line on past it.
  for _, bare in ipairs({ "2\nab\r\n0\r\n\r\n", "2\r\nab\n0\r\n\r\n", "0\r\nX: 1\n\r\n",
      "0\r\n\n" }) do
    local _, why = body_of(head .. bare)
    assert(why == "bad", bare .. ": " .. why)
  end
  local _, long_extension = body_of(head .. "1;" .. string.rep("e", 1000) .. "\r\nx\r\n0\r\n\r\n")
  assert(long_extension == "over", long_extension)
end

--- The framing every chunk has counts against no limit but the body's:
--- many small chunks are taken as one large one is.
local function test_many_small_chunks_pass_as_one_large_one()
  local limits: wire.Limits = { head_bytes = 1024, body_bytes = 50000 }
  local parts: {string} = { "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n" }
  for _ = 1, 20000 do parts[#parts + 1] = "1\r\nx\r\n" end
  parts[#parts + 1] = "0\r\n\r\n"
  local got, state = body_of(table.concat(parts), limits)
  assert(state == "done" and #got == 20000, state)
end

--- What the writer refuses, for the server to answer 500.
local function test_check_refuses_what_cannot_be_sent()
  assert(wire.check({ status = 200, headers = { ["X-Ok"] = "fine" } }) == "")
  assert(wire.check({ status = 99 }) ~= "")
  assert(wire.check({ status = 200, headers = { ["Bad Name"] = "x" } }) ~= "")
  assert(wire.check({ status = 200, headers = { X = "a\nb" } }) ~= "")
  assert(wire.check({ status = 200, headers = { X = "a\0b" } }) ~= "")
  for _, owned in ipairs({ "Date", "content-length", "Transfer-Encoding", "CONNECTION" }) do
    assert(wire.check({ status = 200, headers = { [owned] = "x" } }) ~= "", owned)
  end
  assert(wire.check({ status = 304, body = "x" }) ~= "")
  assert(wire.check({ status = 204, body = Stream.from_string("") }) ~= "")
  assert(wire.check({ status = 204, body = "" }) == "")
  assert(wire.check({ status = 200, body = "x", length = 1 }) ~= "")
  assert(wire.check({ status = 200, body = Stream.from_string("x"), length = -1 }) ~= "")
end

--- A head is read in time that grows with its size alone: a value with
--- a run of spaces inside it, which a pattern trimming its ends
--- (`^[ \t]*(.-)[ \t]*$`) takes time growing with the square of to read
--- -- seconds at 64 KiB, past the test's timeout at this size -- and one
--- name repeated through the head.
local function test_a_head_of_spaces_or_repeats_is_read_in_linear_time()
  local limits: wire.Limits = { head_bytes = 1024 * 1024, body_bytes = 100 }
  local inside = "x" .. string.rep(" ", 1000000) .. "y"
  local spaces = assert(read("GET / HTTP/1.1\r\nHost: h\r\nX:  " .. inside .. " \t\r\n\r\n", limits).head)
  assert(spaces.headers["x"] == inside)
  local repeated = assert(read("GET / HTTP/1.1\r\nHost: h\r\n" .. string.rep("X: ab\r\n", 9000) ..
    "\r\n", limits).head)
  assert(#repeated.headers["x"] == 9000 * 4 - 2)
end
