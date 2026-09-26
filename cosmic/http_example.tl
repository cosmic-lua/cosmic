--- Worked examples for `cosmic.http`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table. A test has no network,
--- so each one answers from `Options.script`, a canned reply; a real
--- call leaves `script` out.

local Compress = require("cosmic.compress")
local Http = require("cosmic.http")
local Stream = require("cosmic.stream")

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

--- A body streamed up rather than held whole: here a gzip of a string
--- as it is compressed, and as well a file (`Stream.open(path)`), a
--- child's output or another response. With no `body_size` the body
--- goes chunked. A real call leaves `script` out:
--- `Http.upload("https://example.com/upload", { method = "PUT" })`.
function Example.upload()
  local reply = "HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n"
  local up = assert(Http.upload("http://example.test/upload", {
    method = "PUT", headers = { ["Content-Encoding"] = "gzip" }, script = { reply } }))
  local gzip = Stream.transform(Stream.from_string(string.rep("streamed\n", 1000)),
    (assert(Compress.deflater("gzip"))))
  assert(Stream.copy(gzip, up))
  assert(up:close())
  local response <close> = assert(up:response())
  print(response.status)
  assert(response.status == 201)
end

return Example
