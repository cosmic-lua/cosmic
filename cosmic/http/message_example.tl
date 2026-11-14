--- Worked examples for [`cosmic.http.message`], shown by `cosmic docs`
--- under the symbol each one demonstrates and run by `cosmic test` like
--- any other test -- see doc/design.md's `examples` table.

local Message = require("cosmic.http.message")

local record Example
end

--- A server's side of a channel the program owns: bytes arrive in
--- pieces that end anywhere, and each request is read by a reader of its
--- own, the next one fed the piece from where the last stopped.
function Example.request_reader()
  local arriving = {
    "POST /notes HTTP/1.1\r\nHost: h.test\r\nContent-Le",
    "ngth: 5\r\n\r\nhelloGET /notes HTTP/1.1\r\nHo",
    "st: h.test\r\n\r\n",
  }
  local seen: mut {string} = {}
  local reader = Message.request_reader({ body_bytes = 64 * 1024 })
  for _, piece in ipairs(arriving) do
    local at = 1
    while at <= #piece do
      local read = reader:feed(piece, at)
      if read.status == "more" then break end
      -- A refusal's reason is fit to log; the connection is then closed.
      local request = assert(read.request, read.reason)
      seen[#seen + 1] = request.method .. " " .. request.target .. " " .. tostring(#request.body)
      reader = Message.request_reader({ body_bytes = 64 * 1024 })
      at = read.next
    end
  end
  -- The stream ended between requests, not within one.
  assert(reader:finish().status == "empty")
  print(table.concat(seen, ", "))
  assert(table.concat(seen, ", ") == "POST /notes 5, GET /notes 0")
end

--- A client's side: a response whose head names no length runs to the
--- end of the stream, which `finish` says; the answer to a HEAD is its
--- head alone, whatever length it names. Each `Set-Cookie` is kept
--- apart in `values`.
function Example.response_reader()
  local reader = Message.response_reader()
  assert(reader:feed("HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\nto the").status == "more")
  assert(reader:feed(" end").status == "more")
  local read = reader:finish()
  local response = assert(read.response, read.reason)
  local cookies = assert(response.values["set-cookie"])
  print(response.status, response.body, #cookies)
  assert(response.body == "to the end" and #cookies == 2 and response.headers["set-cookie"] == "a=1, b=2")

  local head = Message.response_reader({ head_only = true }):feed("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n")
  assert(head.status == "done" and assert(head.response).headers["content-length"] == "1000")

  -- What two readers could read differently is refused, never guessed.
  local smuggled = Message.response_reader():feed(
    "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n")
  print(smuggled.status, smuggled.reason)
  assert(smuggled.status == "refused")
end

--- An RTSP/1.0 exchange: the protocol is a parameter of the formatter
--- and of the reader, and the message grammar is HTTP's.
function Example.format_request()
  local describe = assert(Message.format_request({
    method = "DESCRIBE", target = "rtsp://cam.test/stream", protocol = "RTSP/1.0",
    headers = { CSeq = "2", Accept = "application/sdp" },
  }))
  print((describe:gsub("\r\n", "|")))
  assert(describe == "DESCRIBE rtsp://cam.test/stream RTSP/1.0\r\nAccept: application/sdp\r\nCSeq: 2\r\n\r\n")

  local answer = "RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Type: application/sdp\r\nContent-Length: 5\r\n\r\nv=0\r\n"
  local read = Message.response_reader({ protocol = "RTSP/1.0" }):feed(answer)
  local response = assert(read.response, read.reason)
  assert(response.headers["cseq"] == "2" and response.body == "v=0\r\n")
  -- A reader asked for RTSP reads nothing else.
  assert(Message.response_reader({ protocol = "RTSP/1.0" }):feed("HTTP/1.1 200 OK\r\n\r\n").status == "refused")
end

--- A response written from its parts: the body's size is its
--- Content-Length, a list writes a line for each element, and parts a
--- reader would refuse are not written.
function Example.format_response()
  local text = assert(Message.format_response({
    status = 404, headers = { ["Content-Type"] = "text/plain", ["Set-Cookie"] = { "a=1", "b=2" } },
    body = "no such note\n",
  }))
  print((text:gsub("\r\n", "|")))
  local read = Message.response_reader():feed(text)
  assert(assert(read.response, read.reason).body == "no such note\n" and read.consumed == #text)
  local refused, why = Message.format_response({ status = 200, headers = { ["X-Note"] = "a\r\nSet-Cookie: stolen" } })
  print(refused, why)
  assert(refused == nil)
end

return Example
