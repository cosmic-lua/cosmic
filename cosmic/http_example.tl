--- Worked examples for [`cosmic.http`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table. A test has no network,
--- so each client one answers from [`Http.Options.script`], a canned
--- reply; a real call leaves `script` out.

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

--- A status that is not 2xx, checked by hand: the call succeeds, since
--- the server answered, and hands back the body the server sent with
--- its 404. `assert` on the call refuses only a request that got no
--- answer at all. A real call leaves `script` out:
--- `Http.get("https://example.com/missing")`.
function Example.status()
  local reply = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n" ..
    "Connection: close\r\n\r\nno widget"
  local got = assert(Http.get("http://example.test/missing", { script = { reply } }))
  local found = got.status // 100 == 2
  print(got.status, found, got.body)
  assert(not found and got.status == 404 and got.body == "no widget", got.body)
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

return Example
