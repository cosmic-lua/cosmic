--- Worked examples for [`cosmic.http.server`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local Server = require("cosmic.http.server")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")

--- The server example listens on the worker's own loopback.
Test.policy{ loopback = { "127.0.0.1" } }

local Example = {}

--- A key-value store over HTTP: PUT stores a body under its path, GET
--- (and HEAD) answers it, 404 when there is none. A HEAD is answered as
--- the GET is: the server sends its head, Content-Length included, and
--- drops the body. The server writes each reply's Content-Length, Date
--- and Connection itself. A real one
--- listens at `Net.tcp("127.0.0.1", 8080)` for any client; here it
--- listens on the loopback at a port the kernel chooses, and the client writes raw HTTP over
--- [`Net.connect`], two requests pipelined, since [`Http.get`] holds the
--- thread the server runs on until it returns.
function Example.serve()
  local store: {string:string} = {}
  assert(Server.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    limits = { body_bytes = 64 * 1024 },
    handle = function(req: Server.Request): Server.Reply
      if req.method == "PUT" then
        -- Past limits.body_bytes the read fails, and the server answers 413.
        store[req.path] = assert(Stream.read_all(req.body))
        return { status = 204 }
      elseif req.method == "GET" or req.method == "HEAD" then
        local value = store[req.path]
        if value == nil then return { status = 404, body = "no such key\n" } end
        return { status = 200, headers = { ["Content-Type"] = "text/plain" }, body = value }
      end
      return { status = 405, headers = { Allow = "GET, HEAD, PUT" } }
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local conn <close> = assert(Net.connect(addresses[1], { timeout_ns = Clock.seconds(5) }))
      assert(conn:write("PUT /greeting HTTP/1.1\r\nHost: kv\r\nContent-Length: 5\r\n\r\nhello" ..
          "GET /greeting HTTP/1.1\r\nHost: kv\r\nConnection: close\r\n\r\n"))
      local answer = assert(Stream.read_all(conn))
      print(answer)
      assert(answer:find("^HTTP/1.1 204 No Content\r\n") and answer:find("\r\n\r\nhello$"), answer)
      server:stop()
    end,
  })
end

--- A handler's answer to a GET of a file it holds in memory, honoring
--- Range: 206 with the span asked for, 416 for a range holding none of
--- its bytes, and 200 with the whole for no Range, or one it ignores.
function Example.range()
  local data = "0123456789"
  local function answer(range: string | nil): Server.Reply
    local r = Server.range(range, #data)
    if r.kind == "span" then
      return { status = 206, body = data:sub(r.first + 1, r.last + 1),
        headers = { ["Content-Range"] = ("bytes %d-%d/%d"):format(r.first, r.last, #data) } }
    elseif r.kind == "unsatisfiable" then
      return { status = 416, headers = { ["Content-Range"] = ("bytes */%d"):format(#data) } }
    end
    return { status = 200, body = data }
  end
  local tail = answer("bytes=-3")
  print(tail.status, tail.headers["Content-Range"], tail.body)
  assert(tail.status == 206 and tail.body == "789" and tail.headers["Content-Range"] == "bytes 7-9/10")
  assert(answer("bytes=20-").status == 416)
  assert(answer("bytes=0-1,5-6").status == 200 and answer(nil).status == 200)
end

--- A handler's answer to a GET a client may already hold: 304, with
--- no body, where If-None-Match names the version it would send.
function Example.none_match()
  local etag = '"v7"'
  local function answer(if_none_match: string | nil): Server.Reply
    if Server.none_match(if_none_match, etag) then
      return { status = 304, headers = { ETag = etag } }
    end
    return { status = 200, headers = { ETag = etag }, body = "version 7\n" }
  end
  print(answer('W/"v6", W/"v7"').status, answer('"v6"').status)
  assert(answer('W/"v6", W/"v7"').status == 304 and answer("*").status == 304)
  assert(answer('"v6"').status == 200 and answer(nil).status == 200)
end

return Example
