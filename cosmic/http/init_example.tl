--- Examples for the cosmic.http module.
--- The server is real but local: it listens on an OS-assigned loopback
--- port and a forked child serves exactly one connection, so the output
--- is deterministic and no external host is contacted.

-- Example_hello demonstrates the whole surface in one exchange: listen
-- on an ephemeral port, serve one connection in a forked child, and
-- fetch from it. allow_private opts the client out of the SSRF guard
-- that otherwise blocks loopback addresses.
local function Example_hello()
  local check = require("cosmic.check")
  local fetch = require("cosmic.fetch")
  local http = require("cosmic.http")
  local proc = require("cosmic.proc")

  local srv = check.must(http.listen("127.0.0.1", 0))
  local port = srv:port()
  local pid = check.must(proc.fork())
  if pid == 0 then
    assert(srv:serve_one(function(req: http.Request, res: http.Response)
          local _ok, _err = res:text("hello " .. req.path .. "\n")
        end))
    os.exit(0)
  end
  assert(srv:close())

  local result = check.must(fetch.fetch("http://127.0.0.1:" .. port .. "/world",
      {allow_private = true}))
  assert(proc.wait(pid))
  print(result.status)
  io.write(result.body)
  -- Output:
  -- 200
  -- hello /world
end

-- Example_sse serves Server-Sent Events: the handler calls res:event
-- once per event and finishes the stream, which is the whole server
-- half of SSE. The client reads the body as it arrives and hands that
-- reader to sse.parse, so what comes back out is the events that went in.
local function Example_sse()
  local check = require("cosmic.check")
  local fetch = require("cosmic.fetch")
  local http = require("cosmic.http")
  local proc = require("cosmic.proc")
  local sse = require("cosmic.sse")

  local srv = check.must(http.listen("127.0.0.1", 0))
  local port = srv:port()
  local pid = check.must(proc.fork())
  if pid == 0 then
    assert(srv:serve_one(function(_req: http.Request, res: http.Response)
          assert(res:event({data = "tick 1", event = "tick"}))
          assert(res:event({data = "tick 2", event = "tick"}))
          assert(res:finish())
        end))
    os.exit(0)
  end
  assert(srv:close())

  local result = check.must(fetch.stream("http://127.0.0.1:" .. port .. "/events",
      {allow_private = true}))
  print(result.headers["content-type"])
  local events = sse.parse(result.reader)
  while true do
    local ev = events:next()
    if ev then
      print(ev.event .. ": " .. ev.data)
    else
      break
    end
  end
  assert(proc.wait(pid))
  -- Output:
  -- text/event-stream
  -- tick: tick 1
  -- tick: tick 2
end

-- Example_router shows the whole router surface: three routes, and the
-- server answering two requests through one serve_one call each. The
-- router's handler() is an ordinary http.Handler, so it is handed to
-- serve_one exactly like the plain function in Example_hello.
local function Example_router()
  local check = require("cosmic.check")
  local fetch = require("cosmic.fetch")
  local http = require("cosmic.http")
  local proc = require("cosmic.proc")
  local router = require("cosmic.http.router")

  local rt = router.new()
  assert(rt:get("/todos/:id", function(req: http.Request, res: http.Response)
        local _ok, _err = res:text("todo " .. req.params.id .. "\n")
      end))
  assert(rt:post("/todos", function(_req: http.Request, res: http.Response)
        res.status = 201
        local _ok, _err = res:text("created\n")
      end))
  assert(rt:delete("/todos/:id", function(req: http.Request, res: http.Response)
        local _ok, _err = res:text("deleted " .. req.params.id .. "\n")
      end))

  local srv = check.must(http.listen("127.0.0.1", 0))
  local port = srv:port()
  local pid = check.must(proc.fork())
  if pid == 0 then
    local handler = rt:handler()
    assert(srv:serve_one(handler))
    assert(srv:serve_one(handler))
    os.exit(0)
  end
  assert(srv:close())

  local got = check.must(fetch.fetch("http://127.0.0.1:" .. port .. "/todos/7",
      {allow_private = true}))
  print(got.status)
  io.write(got.body)

  local deleted = check.must(fetch.delete("http://127.0.0.1:" .. port .. "/todos/7",
      {allow_private = true}))
  print(deleted.status)
  io.write(deleted.body)
  assert(proc.wait(pid))
  -- Output:
  -- 200
  -- todo 7
  -- 200
  -- deleted 7
end

-- Suppress unused warnings for examples
local _ = {Example_hello, Example_sse, Example_router}
