--- Worked examples for [`cosmic.http`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table. A test has no network,
--- so each one answers from [`Http.Options.script`], a canned reply; a real
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

return Example
