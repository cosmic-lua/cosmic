--- [`Web.serve`] and the loopback client: what only a socket shows, on the
--- worker's own loopback.

local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Server = require("cosmic.http.server")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local Web = require("cosmic.web")

Test.policy{ loopback = { "127.0.0.1" } }

--- A sink that keeps its lines.
local function recording(): Web.Sink, {string}
  local lines: {string} = {}
  local sink: Web.Sink = { line = function(_self: Web.Sink, text: string)
    lines[#lines + 1] = text
  end }
  return sink, lines
end

--- The message of the error `fn` raises; fails where it raises none.
local function raised(fn: function()): string
  local ok, err = pcall(function(): any
    fn()
    return nil
  end)
  assert(not ok, "expected a raise")
  return tostring(err)
end

--- A reader of `pieces`, one a read.
local function pieces_of(pieces: {string}): Stream.Reader
  local at = 0
  return {
    read = function(_self: Stream.Reader, _max?: integer): string | nil, string
      at = at + 1
      return pieces[at], ""
    end,
    close = function(_self: Stream.Reader): boolean, string return true, "" end,
  }
end

local function test_a_connection_is_kept_across_requests_including_after_a_404()
  local app = Web.app{ routes = {
    Web.get("/port", function(req: Web.Request): Web.Response
      return Web.text(tostring(req.client.port))
    end),
    Web.post("/echo", function(req: Web.Request): Web.Response return Web.text(req:text() or "") end),
  } }
  Web.with_server(app, function(client: Web.LoopbackClient)
    local first = assert(client:get("/port"))
    local missing = assert(client:get("/nothing"))
    local second = assert(client:get("/port"))
    local echoed = assert(client:post("/echo", { body = "ping", content_type = "text/plain" }))
    local third = assert(client:get("/port"))
    assert(first.status == 200 and missing.status == 404 and second.status == 200)
    assert(first.body == second.body and second.body == third.body, "one connection served them all")
    assert(echoed.body == "ping" and missing.headers["content-type"] == "text/html; charset=utf-8")
  end)
end

local function test_head_has_the_gets_head_and_no_body_on_the_wire()
  local app = Web.app{ routes = { Web.get("/x", function(_req: Web.Request): Web.Response
    return Web.text("twelve bytes")
  end) } }
  Web.with_server(app, function(client: Web.LoopbackClient)
    local head = assert(client:head("/x"))
    assert(head.status == 200 and head.body == "" and head.headers["content-length"] == "12")
    local after = assert(client:get("/x"))
    assert(after.body == "twelve bytes", "the connection is in step after a HEAD")
  end)
end

local function test_two_set_cookie_lines_arrive_as_two_lines()
  local app = Web.app{ routes = { Web.get("/", function(_req: Web.Request): Web.Response
    local res = Web.text("x")
    Web.add_header(res, "Set-Cookie", "a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT")
    Web.add_header(res, "Set-Cookie", "b=2")
    Web.add_header(res, "Vary", "Cookie")
    return res
  end) } }
  Web.with_server(app, function(client: Web.LoopbackClient)
    local res = assert(client:get("/"))
    local lines = res:header_list("set-cookie")
    assert(#lines == 2 and lines[1]:find("^a=1; Expires=") and lines[2] == "b=2")
    assert(res.headers["vary"] == "Cookie")
  end)
end

local function test_a_reader_body_goes_out_chunked()
  local app = Web.app{ routes = { Web.get("/s", function(_req: Web.Request): Web.Response
    return Web.stream(pieces_of({ "one ", "two ", "three" }), "text/plain")
  end) } }
  Web.with_server(app, function(client: Web.LoopbackClient)
    local res = assert(client:get("/s"))
    assert(res.status == 200 and res.body == "one two three")
    assert(res.headers["transfer-encoding"] == "chunked" and res.headers["content-length"] == nil)
  end)
end

local function test_a_path_the_router_refuses_is_the_apps_400_and_the_connection_survives()
  local app = Web.app{ routes = { Web.get("/a", function(_req: Web.Request): Web.Response
    return Web.text("a")
  end) } }
  Web.with_server(app, function(client: Web.LoopbackClient)
    local bad = assert(client:raw("GET /a/../a HTTP/1.1\r\nHost: x\r\n\r\n"))
    assert(bad.status == 400 and bad.body:find("climbs out of the path", 1, true), bad.body)
    local slash = assert(client:raw("GET //a HTTP/1.1\r\nHost: x\r\n\r\n"))
    assert(slash.status == 308 and slash.headers["location"] == "/a")
    assert(assert(client:get("/a")).body == "a")
    local closing = assert(client:raw("GET /a HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"))
    assert(closing.status == 200 and closing.headers["connection"] == "close")
  end)
end

local function test_a_failure_inside_the_client_function_is_raised_after_the_server_stops()
  local app = Web.app{ routes = {} }
  local message = raised(function()
    Web.with_server(app, function(_client: Web.LoopbackClient) error("the test failed") end)
  end)
  assert(message:find("the test failed", 1, true), message)
end

local function test_stopping_ends_a_stream_and_runs_the_stop_functions_in_order()
  local events: {string} = {}
  local app: Web.App = nil
  app = Web.app{
    routes = { Web.get("/events", function(_req: Web.Request): Web.Response
      local sent = false
      return Web.stream({
        read = function(_self: Stream.Reader, _max?: integer): string | nil, string
          if not sent then
            sent = true
            return "data: hello\n\n", ""
          end
          while not app:stopping() do assert(Poll.delay(Clock.ms(5))) end
          events[#events + 1] = "stream saw stopping"
          return nil, ""
        end,
        close = function(_self: Stream.Reader): boolean, string return true, "" end,
      }, "text/event-stream")
    end) },
    lifespan = function(_app: Web.App): Web.Shutdown | nil, string
      events[#events + 1] = "lifespan start"
      return function() events[#events + 1] = "lifespan stop" end, ""
    end,
  }
  app:on_stop(function() events[#events + 1] = "app stop 1" end)
  app:on_stop(function()
    events[#events + 1] = "app stop 2"
    error("a failing stop function")
  end)
  app:on_stop(function() events[#events + 1] = "app stop 3" end)
  local started = Clock.monotonic_ns()
  local sink, lines = recording()
  app.spec.sink = sink
  local ok, why = Web.serve(app, {
    listeners = { Net.tcp("127.0.0.1", 0) },
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local conn <close> = assert(Net.connect(addresses[1], { timeout_ns = Clock.seconds(5) }))
      assert(conn:write("GET /events HTTP/1.1\r\nHost: x\r\n\r\n"))
      local got = ""
      while not got:find("data: hello", 1, true) do got = got .. assert(conn:read()) end
      assert(not app:stopping())
      server:stop()
    end,
    on_stop = function(_server: Net.Server) events[#events + 1] = "caller stop" end,
  })
  assert(ok, why)
  assert(Clock.monotonic_ns() - started < Clock.seconds(5), "the stream ended at once, not at the grace")
  assert(table.concat(events, ", ") == "lifespan start, app stop 1, app stop 2, app stop 3, caller stop, " ..
      "stream saw stopping, lifespan stop", table.concat(events, ", "))
  assert(app:stopping() and #lines == 1 and lines[1]:find("a failing stop function", 1, true), table.concat(lines, "|"))
end

local function test_a_lifespan_that_fails_stops_serve_before_it_listens()
  local listened = false
  local app = Web.app{ routes = {}, lifespan = function(_app: Web.App): Web.Shutdown | nil, string
    return nil, "no database"
  end }
  local ok, why = Web.serve(app, { listeners = { Net.tcp("127.0.0.1", 0) },
    on_ready = function(_addresses: {Net.Address}, _server: Net.Server) listened = true end })
  assert(not ok and why == "no database" and not listened)
end

local function test_serve_warns_when_debug_meets_a_listener_beyond_the_loopback()
  local sink, lines = recording()
  local app = Web.app{ routes = {}, debug = true, sink = sink }
  -- Not an address of this host: the bind fails, after the warning.
  local ok = Web.serve(app, { listeners = { Net.tcp("10.255.255.1", 0) } })
  assert(not ok)
  assert(#lines >= 1 and lines[1]:find("debug is on", 1, true), table.concat(lines, "|"))
  local quiet_sink, quiet = recording()
  local local_app = Web.app{ routes = {}, debug = true, sink = quiet_sink }
  assert(Web.serve(local_app, { listeners = { Net.tcp("127.0.0.1", 0) },
    on_ready = function(_addresses: {Net.Address}, server: Net.Server) server:stop() end }))
  assert(#quiet == 0)
end

local function test_serve_refuses_an_option_it_does_not_have()
  local app = Web.app{ routes = {} }
  local options: any = { listeners = { Net.tcp("127.0.0.1", 0) }, port = 80 }
  assert(raised(function() Web.serve(app, options as Web.ServeOptions) end):find("serve has no field port", 1, true))
end

local function test_serve_gives_the_server_a_grace_of_ten_seconds_unless_told_otherwise()
  local graces: {integer} = {}
  local real = Server.serve
  Server.serve = function(spec: Server.ServeSpec): boolean, string
    graces[#graces + 1] = spec.grace_ns
    return true, ""
  end
  local ran, err = pcall(function()
    local app = Web.app{ routes = {} }
    assert(Web.serve(app, { listeners = { Net.tcp("127.0.0.1", 0) } }))
    assert(Web.serve(app, { listeners = { Net.tcp("127.0.0.1", 0) }, grace_ns = Clock.ms(250) }))
  end)
  Server.serve = real
  assert(ran, tostring(err))
  assert(graces[1] == Clock.seconds(10), "the default grace: " .. tostring(graces[1]))
  assert(graces[2] == Clock.ms(250), "an explicit grace is forwarded")
end

local function test_a_handler_that_ignores_stopping_is_cut_off_at_the_grace()
  local app = Web.app{ routes = { Web.get("/forever", function(_req: Web.Request): Web.Response
    return Web.stream({
      read = function(_self: Stream.Reader, _max?: integer): string | nil, string
        assert(Poll.delay(Clock.ms(5)))
        return "x", ""
      end,
      close = function(_self: Stream.Reader): boolean, string return true, "" end,
    }, "text/plain")
  end) } }
  local started = Clock.monotonic_ns()
  local ok, why = Web.serve(app, {
    listeners = { Net.tcp("127.0.0.1", 0) },
    grace_ns = Clock.ms(200),
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local conn <close> = assert(Net.connect(addresses[1], { timeout_ns = Clock.seconds(5) }))
      assert(conn:write("GET /forever HTTP/1.1\r\nHost: x\r\n\r\n"))
      assert(conn:read())
      server:stop()
    end,
  })
  assert(ok, why)
  assert(Clock.monotonic_ns() - started < Clock.seconds(5), "the grace ended the stream, not its own end")
end

--- A client of `fn`'s server whose connection leads to a server of its own
--- making: `script` is what that server sends once the client has written.
local function scripted(client: Web.LoopbackClient, script: string)
  local listener <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  local conn = assert(Net.connect(listener.address, { timeout_ns = Clock.seconds(5) }))
  local peer <close> = assert(listener:accept())
  client.conn = conn
  client.buf = ""
  if script ~= "" then assert(peer:write(script)) end
end

local function test_the_loopback_client_refuses_a_chunk_size_that_is_garbage()
  local app = Web.app{ routes = {} }
  Web.with_server(app, function(client: Web.LoopbackClient)
    scripted(client, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nabc\r\n0\r\n\r\n")
    local res, why = client:get("/")
    assert(res == nil and why:find("not a chunk size: zz", 1, true), tostring(why))
    scripted(client, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3x\r\nabc\r\n0\r\n\r\n")
    local second, second_why = client:get("/")
    assert(second == nil and second_why:find("not a chunk size: 3x", 1, true), tostring(second_why))
    scripted(client, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;ext=1\r\nabc\r\n0\r\n\r\n")
    local fine = assert(client:get("/"))
    assert(fine:text() == "abc")
  end)
end

local function test_the_loopback_client_fails_when_the_server_goes_silent()
  local app = Web.app{ routes = {} }
  Web.with_server(app, function(client: Web.LoopbackClient)
    scripted(client, "")
    client.conn:set_timeout(Clock.ms(100))
    local started = Clock.monotonic_ns()
    local res, why = client:get("/")
    assert(res == nil and why ~= "", "a silent server is a failure, not a wait")
    assert(Clock.monotonic_ns() - started < Clock.seconds(3))
  end)
end
