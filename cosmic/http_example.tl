--- Worked examples for [`cosmic.http`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table. A test has no network,
--- so each client one answers from [`Http.Options.script`], a canned
--- reply; a real call leaves `script` out.

local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Net = require("cosmic.net")
local Stream = require("cosmic.stream")
local Clock = require("cosmic.clock")

local Example = {}

--- A small body fetched whole. A status that is not 2xx is an answer,
--- not a failure: check `status`. `script` is a field for tests only,
--- standing in for the server here; a real call leaves it out:
--- `Http.get("https://example.com/status")`.
function Example.get()
  local reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ..
    "Content-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}"
  local got, trouble = Http.get("http://example.test/status", { script = { reply } })
  assert(got ~= nil, trouble)
  print(got.status, got.headers["content-type"], got.body)
  assert(got.status == 200 and got.body == '{"ok":true}', got.body)
end

--- Any method, its response read whole: a PUT with a body, then a
--- DELETE. The method is the first argument, case-sensitive as HTTP's
--- are. A real call leaves `script` out:
--- `Http.request("PUT", "https://example.com/items/1", { body = item })`.
function Example.request()
  local item = '{"name":"widget"}'
  local put, trouble = Http.request("PUT", "http://example.test/items/1", {
    headers = { ["Content-Type"] = "application/json" }, body = item,
    script = { "HTTP/1.1 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" } })
  assert(put ~= nil, trouble)
  local gone, why = Http.request("DELETE", "http://example.test/items/1",
    { script = { "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n" } })
  assert(gone ~= nil, why)
  print(put.status, gone.status)
  assert(put.status == 201 and gone.status == 204)
end

--- A body sent whole, here a gzip of a string, with the method and
--- headers it needs; the response is read from the handle `open`
--- answers, and closed by its `<close>` variable. A real call leaves
--- `script` out: `Http.open("https://example.com/upload", { method = "PUT", body = gzip })`.
function Example.open()
  local reply = "HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n"
  local gzip = assert(Stream.run(assert(Compress.deflater("gzip")), string.rep("sent whole\n", 1000)))
  local response <close> = assert(Http.open("http://example.test/upload", {
    method = "PUT", headers = { ["Content-Encoding"] = "gzip" }, body = gzip,
    script = { reply } }))
  print(response.status)
  assert(response.status == 201)
end

--- A key-value store over HTTP: PUT stores a body under its path, GET
--- (and HEAD) answers it, 404 when there is none. A HEAD is answered as
--- the GET is: the server sends its head, Content-Length included, and
--- drops the body. The server writes each reply's Content-Length, Date
--- and Connection itself. A real one
--- listens at `Net.tcp("127.0.0.1", 8080)` for any client; here it
--- listens on a socket file, and the client writes raw HTTP over
--- [`Net.connect`], two requests pipelined, since [`Http.get`] holds the
--- thread the server runs on until it returns.
function Example.serve()
  local dir = assert(Fs.mkdtemp("cosmic-http-example-"))
  local store: {string:string} = {}
  assert(Http.serve{
    listeners = { Net.unix(dir .. "/kv.sock") },
    limits = { body_bytes = 64 * 1024 },
    handle = function(req: Http.Request): Http.Reply
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
  assert(Fs.remove_tree(dir))
end

--- A handler's answer to a GET of a file it holds in memory, honoring
--- Range: 206 with the span asked for, 416 for a range holding none of
--- its bytes, and 200 with the whole for no Range, or one it ignores.
function Example.range()
  local data = "0123456789"
  local function answer(range: string | nil): Http.Reply
    local r = Http.range(range, #data)
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
  local function answer(if_none_match: string | nil): Http.Reply
    if Http.none_match(if_none_match, etag) then
      return { status = 304, headers = { ETag = etag } }
    end
    return { status = 200, headers = { ETag = etag }, body = "version 7\n" }
  end
  print(answer('W/"v6", W/"v7"').status, answer('"v6"').status)
  assert(answer('W/"v6", W/"v7"').status == 304 and answer("*").status == 304)
  assert(answer('"v6"').status == 200 and answer(nil).status == 200)
end

return Example
