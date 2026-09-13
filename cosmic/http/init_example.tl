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

-- Suppress unused warnings for examples
local _ = {Example_hello, Example_sse}
