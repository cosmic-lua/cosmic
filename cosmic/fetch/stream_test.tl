#!/usr/bin/env cosmic
--- Streaming fetch tests (parts 2-3) against forked loopback
--- servers: chunk reads, line iteration, bodyless-response EOF, and
--- mid-body failure propagation through read() and lines().
local fetch = require("cosmic.fetch")
local net = require("cosmic.net")
local proc = require("cosmic.proc")
local check = require("cosmic.check")

--- Fork a loopback server answering one request per response string,
--- closing the connection right after each send.
local function serve(responses: {string}): integer, integer
  local srv, port = net.listen_tcp("127.0.0.1", 0)
  local s = check.must(srv, "listen_tcp failed")
  local pid = proc.fork()
  if pid == 0 then
    for _, resp in ipairs(responses) do
      local conn = s:accept()
      if conn is net.Socket then
        local c = conn
        local buf = ""
        while not buf:find("\r\n\r\n", 1, true) do
          local data = c:recv(4096)
          if not data or #data == 0 then break end
          buf = buf .. data
        end
        if #resp > 0 then
          c:send(resp)
        end
        c:close()
      end
    end
    os.exit(0)
  end
  s:close()
  return math.tointeger(port), pid
end

local function body_response(body: string): string
  return "HTTP/1.1 200 OK\r\nContent-Length: " .. #body
  .. "\r\nConnection: close\r\n\r\n" .. body
end

local function test_stream_reads_body_and_reports_url()
  local port, pid = serve({body_response("streamed body")})
  local url = "http://127.0.0.1:" .. port .. "/"
  local result = fetch.stream(url, {allow_private = true})
  assert(result.ok == true, "stream should succeed: " .. tostring(result.error))
  assert(result.status == 200, "status should be 200")
  assert(result.url == url, "result.url should be the effective URL")
  assert(result:is_success() == true, "is_success must be true for 200")
  local chunks: {string} = {}
  while true do
    local chunk, err = result.reader:read()
    assert(err == nil, "no read error expected, got: " .. tostring(err))
    if not chunk then break end
    table.insert(chunks, chunk)
  end
  assert(table.concat(chunks) == "streamed body", "body should arrive intact")
  result.reader:close()
  proc.wait(pid)
end
test_stream_reads_body_and_reports_url()

local function test_stream_lines_iterates()
  local port, pid = serve({body_response("one\ntwo\nthree")})
  local result = fetch.stream("http://127.0.0.1:" .. port .. "/", {allow_private = true})
  assert(result.ok == true, "stream should succeed: " .. tostring(result.error))
  local lines: {string} = {}
  for line in result.reader:lines() do
    table.insert(lines, line)
  end
  assert(#lines == 3, "expected 3 lines, got " .. #lines)
  assert(lines[1] == "one" and lines[2] == "two" and lines[3] == "three",
    "lines must arrive in order; final unterminated line included")
  result.reader:close()
  proc.wait(pid)
end
test_stream_lines_iterates()

local function test_stream_204_is_clean_eof()
  -- a bodyless 204 must read as EOF (nil, no error), not "reader closed"
  local port, pid = serve({"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"})
  local result = fetch.stream("http://127.0.0.1:" .. port .. "/", {allow_private = true})
  assert(result.ok == true, "204 stream should succeed: " .. tostring(result.error))
  assert(result.status == 204, "status should be 204")
  local chunk, err = result.reader:read()
  assert(chunk == nil, "204 has no body")
  assert(err == nil, "204 EOF must not be an error, got: " .. tostring(err))
  result.reader:close()
  proc.wait(pid)
end
test_stream_204_is_clean_eof()

local function test_stream_truncated_body_surfaces_error()
  -- Content-Length promises 100 bytes but the server closes after 21:
  -- read() must eventually return an error, not a clean EOF.
  local truncated = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n"
  .. "partial line no end\r\n"
  local port, pid = serve({truncated})
  local result = fetch.stream("http://127.0.0.1:" .. port .. "/", {allow_private = true})
  assert(result.ok == true, "response head arrived; stream opens: " .. tostring(result.error))
  local saw_error: string = nil
  while true do
    local chunk, err = result.reader:read()
    if err then
      saw_error = err
      break
    end
    if not chunk then break end
  end
  assert(saw_error ~= nil, "a truncated body must surface a read error, not clean EOF")
  result.reader:close()
  proc.wait(pid)
end
test_stream_truncated_body_surfaces_error()

local function test_stream_lines_propagates_error_then_stops()
  -- lines() yields nil, err once for a mid-stream failure, then plain nil;
  -- a truncated stream is distinguishable from a graceful close.
  local truncated = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n"
  .. "complete line\npartial"
  local port, pid = serve({truncated})
  local result = fetch.stream("http://127.0.0.1:" .. port .. "/", {allow_private = true})
  assert(result.ok == true, "stream opens: " .. tostring(result.error))
  local iter = result.reader:lines()
  local first, err1 = iter()
  assert(first == "complete line", "the complete line arrives first, got: " .. tostring(first))
  assert(err1 == nil, "no error on the complete line")
  local second, err2 = iter()
  assert(second == nil, "truncation must not fake a line")
  assert(err2 ~= nil, "the error must be yielded, not swallowed EOF")
  local third, err3 = iter()
  assert(third == nil and err3 == nil, "after the error, the iterator is exhausted")
  result.reader:close()
  proc.wait(pid)
end
test_stream_lines_propagates_error_then_stops()

local function test_stream_reader_close_idempotent()
  local port, pid = serve({body_response("x")})
  local result = fetch.stream("http://127.0.0.1:" .. port .. "/", {allow_private = true})
  assert(result.ok == true, "stream should succeed")
  assert(not result.reader:closed(), "reader should not be closed initially")
  assert(result.reader:close() == true, "first close should return true")
  assert(result.reader:close() == true, "second close should also return true")
  assert(result.reader:closed(), "reader should be closed after close()")
  local chunk, err = result.reader:read()
  assert(chunk == nil and err == "reader closed", "read after close is an error")
  proc.wait(pid)
end
test_stream_reader_close_idempotent()

local function test_stream_validation_and_error_kind()
  local result = fetch.stream("ftp://example.com/x")
  assert(result.ok == false, "ftp scheme must be rejected")
  assert(result.error:find("unsupported URL scheme") ~= nil,
    "validation error expected, got: " .. tostring(result.error))

  local refused = fetch.stream("http://127.0.0.1:1/", {allow_private = true})
  assert(refused.ok == false, "dead port must fail")
  assert(refused.error_kind == "connect",
    "stream error_kind should be 'connect', got " .. tostring(refused.error_kind))

  local blocked = fetch.stream("http://127.0.0.1:1/")
  assert(blocked.ok == false and blocked.error_kind == "blocked",
    "SSRF guard applies to streams, got " .. tostring(blocked.error_kind))
end
test_stream_validation_and_error_kind()
