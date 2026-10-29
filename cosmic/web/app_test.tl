local Json = require("cosmic.json")
local Server = require("cosmic.http.server")
local Stream = require("cosmic.stream")
local Web = require("cosmic.web")

--- A sink that keeps its lines.
local function recording(): Web.Sink, {string}
  local lines: mut {string} = {}
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

local function hello(_req: Web.Request): Web.Response
  return Web.text("hello")
end

--- A middleware that notes when it is entered and left.
local function tracing(trace: mut {string}, name: string): Web.Middleware
  return function(inner: Web.Handler): Web.Handler
    return function(req: Web.Request): Web.Response
      trace[#trace + 1] = name
      local res = inner(req)
      trace[#trace + 1] = "/" .. name
      return res
    end
  end
end

local function test_middleware_nests_app_then_mount_then_route()
  local trace: mut {string} = {}
  local app = Web.app{
    routes = {
      Web.mount("/api", {
        Web.get("/x", function(_req: Web.Request): Web.Response
          trace[#trace + 1] = "handler"
          return Web.text("x")
        end, { middleware = { tracing(trace, "R1"), tracing(trace, "R2") } }),
      }, { middleware = { tracing(trace, "M1"), tracing(trace, "M2") } }),
    },
    middleware = { tracing(trace, "A1"), tracing(trace, "A2") },
  }
  assert(Web.test_client(app):get("/api/x").status == 200)
  assert(table.concat(trace, " ") == "A1 A2 M1 M2 R1 R2 handler /R2 /R1 /M2 /M1 /A2 /A1", table.concat(trace, " "))
end

local function test_a_miss_passes_through_the_middleware_around_where_it_happened()
  local trace: mut {string} = {}
  local app = Web.app{
    routes = { Web.get("/top", hello), Web.mount("/api", { Web.get("/x", hello) },
      { middleware = { tracing(trace, "M") } }) },
    middleware = { tracing(trace, "A") },
  }
  local client = Web.test_client(app)
  assert(client:get("/api/missing").status == 404)
  assert(table.concat(trace, " ") == "A M /M /A", "a 404 inside a mount passes through its middleware")
  for i = #trace, 1, -1 do trace[i] = nil end
  assert(client:get("/missing").status == 404)
  assert(table.concat(trace, " ") == "A /A", "a 404 beside the mount does not")
  for i = #trace, 1, -1 do trace[i] = nil end
  assert(client:post("/api/x").status == 405)
  assert(table.concat(trace, " ") == "A M /M /A", "nor does a 405 inside it")
end

--- A middleware that answers nothing is out of contract: the app raises
--- (the server answers that 500, as it did for the nil it was given before),
--- and says which layer failed to answer.
local function test_a_stack_that_answers_nothing_raises_and_is_not_a_nil_response()
  local app = Web.app{
    routes = { Web.get("/", hello) },
    middleware = { function(_inner: Web.Handler): Web.Handler
      return function(_req: Web.Request): Web.Response
        local nothing: any = nil
        return nothing as Web.Response
      end
    end },
  }
  local client = Web.test_client(app)
  local ok, why = pcall(function() local _ = client:get("/") end)
  assert(not ok and tostring(why):find("the handler stack answered no Response", 1, true) ~= nil,
    tostring(why))
end

local function test_middleware_may_answer_alone_and_change_the_request()
  local MARK: Web.Key<string> = Web.key("mark")
  local app = Web.app{
    routes = { Web.get("/", function(req: Web.Request): Web.Response
      return Web.text(req:get(MARK) or "unmarked")
    end), Web.get("/secret", hello) },
    middleware = {
      function(inner: Web.Handler): Web.Handler
        return function(req: Web.Request): Web.Response
          if req.path == "/secret" then return Web.text("no", { status = 401 }) end
          req:set(MARK, "marked")
          return inner(req)
        end
      end,
    },
  }
  local client = Web.test_client(app)
  assert(client:get("/"):text() == "marked" and client:get("/secret").status == 401)
end

local function test_middleware_sees_only_the_canonical_path()
  local seen: mut {string} = {}
  local app = Web.app{
    routes = { Web.get("/admin", hello), Web.get("/admin/users", hello) },
    middleware = {
      function(inner: Web.Handler): Web.Handler
        return function(req: Web.Request): Web.Response
          seen[#seen + 1] = req.path
          if req.path == "/admin" or req.segments[1] == "admin" then
            return Web.text("denied", { status = 401 })
          end
          return inner(req)
        end
      end,
    },
  }
  local client = Web.test_client(app)
  for _, path in ipairs({ "//admin", "/./admin", "/admin/.", "/x/../admin", "/%61dmin", "/admin%2fusers",
      "/admin//users", "/a/%2e%2e/admin" }) do
    local status = client:get(path).status
    assert(status == 401 or status == 400, path .. ": " .. tostring(status))
  end
  for _, path in ipairs(seen) do
    assert(path:sub(1, 1) == "/" and not path:find("//", 1, true) and not path:find("/%.", 1) and
        not path:find("%2f", 1, true), "the middleware was given " .. path)
  end
end

local function test_the_router_answers_with_status_and_headers_by_accept()
  local app = Web.app{ routes = { Web.get("/x", hello), Web.post("/x", hello) } }
  local client = Web.test_client(app)
  local page = client:get("/missing")
  assert(page.status == 404 and page.headers["content-type"] == "text/html; charset=utf-8")
  assert(page.body:find("<h1>404 Not Found</h1>", 1, true))
  local problem = client:get("/missing", { headers = { accept = "application/json" } })
  assert(problem.status == 404 and problem.headers["content-type"] == "application/problem+json")
  local body = assert(Json.decode_object(problem:text()))
  assert(body.status == 404 and body.title == "Not Found")
  local anything = client:get("/missing", { headers = { accept = "*/*" } })
  assert(anything.headers["content-type"] == "text/html; charset=utf-8", "a tie goes to HTML")
  local picky = client:get("/missing", { headers = { accept = "application/json, text/html;q=0.1" } })
  assert(picky.headers["content-type"] == "application/problem+json")
  local denied = client:put("/x")
  assert(denied.status == 405 and denied.headers["allow"] == "GET, HEAD, OPTIONS, POST")
end

local function test_head_is_the_gets_head_and_options_lists_the_methods()
  local app = Web.app{ routes = { Web.get("/x", function(req: Web.Request): Web.Response
    return Web.text("body of " .. req.method)
  end), Web.post("/x", hello) } }
  local client = Web.test_client(app)
  local head = client:head("/x")
  assert(head.status == 200 and head.body == "" and head.headers["content-length"] == "12", head.headers["content-length"])
  assert(head.headers["content-type"] == "text/plain; charset=utf-8")
  local options = client:options("/x")
  assert(options.status == 204 and options.headers["allow"] == "GET, HEAD, OPTIONS, POST" and options.body == "")
  assert(client:options("/missing").status == 404)
  assert(client:request("OPTIONS", "*").headers["allow"] == "GET, HEAD, OPTIONS, POST")
  assert(client:get("*").status == 400)
end

local function test_a_trailing_slash_and_a_noncanonical_path_redirect_with_the_query()
  local app = Web.app{ routes = { Web.get("/items", hello), Web.post("/items", hello) } }
  local client = Web.test_client(app)
  local slash = client:get("/items/?page=2&q=a%20b")
  assert(slash.status == 308 and slash.redirect_location == "/items?page=2&q=a%20b", tostring(slash.redirect_location))
  local post = client:post("/items/")
  assert(post.status == 308 and post.redirect_location == "/items", "the method survives a 308")
  local dots = client:get("//evil.com//items")
  assert(dots.status == 308 and dots.redirect_location == "/evil.com/items", tostring(dots.redirect_location))
  local followed = client:get("/items/", { follow_redirects = true })
  assert(followed.status == 200)
  local strict = Web.app{ routes = { Web.get("/items", hello) }, trailing_slash = "strict" }
  assert(Web.test_client(strict):get("/items/").status == 404)
end

local function test_a_path_that_climbs_is_a_400_with_the_reason()
  local app = Web.app{ routes = { Web.get("/a", hello) } }
  local res = Web.test_client(app):get("/a/../a")
  assert(res.status == 400 and res.body:find("climbs out of the path", 1, true), res.body)
end

local function test_a_raise_is_a_500_that_tells_the_client_nothing()
  local sink, lines = recording()
  local seen_status = { value = nil as integer? }
  local app = Web.app{
    routes = { Web.get("/boom", function(_req: Web.Request): Web.Response
      error("secret detail <b>")
    end) },
    middleware = { function(inner: Web.Handler): Web.Handler
      return function(req: Web.Request): Web.Response
        local res = inner(req)
        seen_status.value = res.status
        return res
      end
    end },
    sink = sink,
  }
  local res = Web.test_client(app):get("/boom")
  assert(res.status == 500 and seen_status.value == 500, "the middleware outside sees the 500")
  assert(res.body:find("500 Internal Server Error", 1, true))
  assert(not res.body:find("secret", 1, true) and not res.body:find("traceback", 1, true), res.body)
  assert(not res.body:find("router_test", 1, true) and not res.body:find("app_test", 1, true))
  assert(#lines == 1 and lines[1]:find("GET /boom", 1, true) and lines[1]:find("secret detail", 1, true))
  assert(lines[1]:find("stack traceback", 1, true), "the sink has the stack")
  local json = Web.test_client(app):get("/boom", { headers = { accept = "application/json" } })
  assert(json.status == 500 and not json.body:find("secret", 1, true))
end

local function test_debug_shows_the_fault_and_its_stack_escaped()
  local sink = recording()
  local app = Web.app{
    routes = { Web.get("/boom", function(_req: Web.Request): Web.Response
      error("secret detail <b>")
    end) },
    debug = true, sink = sink,
  }
  local res = Web.test_client(app):get("/boom")
  assert(res.status == 500 and res.body:find("secret detail &lt;b&gt;", 1, true), res.body)
  assert(res.body:find("stack traceback", 1, true) and res.body:find("debug is on", 1, true))
  assert(not res.body:find("<b>", 1, true))
  local json = Web.test_client(app):get("/boom", { headers = { accept = "application/json" } })
  local body = assert(Json.decode_object(json:text()))
  local detail = body.detail
  assert(json.status == 500 and detail is string and detail:find("secret detail <b>", 1, true))
  assert(body.trace ~= nil)
end

local function test_debug_is_off_unless_asked_and_a_bad_response_is_a_fault_only_in_debug()
  local function bad(_req: Web.Request): Web.Response
    return { status = 200, body = "abc", length = 9 }
  end
  local plain = Web.app{ routes = { Web.get("/bad", bad) } }
  assert(plain.spec.debug == false)
  assert(raised(function() Web.test_client(plain):get("/bad") end):find("would answer 500", 1, true))
  local debugging = Web.app{ routes = { Web.get("/bad", bad) }, debug = true, sink = recording() }
  local res = Web.test_client(debugging):get("/bad")
  assert(res.status == 500 and res.body:find("cannot be sent", 1, true), res.body)
end

local function test_in_debug_a_handler_that_returns_nothing_is_told_as_the_server_tells_it()
  local function nothing(_req: Web.Request): Web.Response
    return nil as Web.Response
  end
  local debugging = Web.app{ routes = { Web.get("/nothing", nothing) }, debug = true, sink = recording() }
  local res = Web.test_client(debugging):get("/nothing")
  assert(res.status == 500 and res.body:find("the handler answered nil, not a Server.Reply", 1, true), res.body)
end

local function test_abort_answers_its_status_and_detail_in_the_negotiated_form()
  local app = Web.app{ routes = {
    Web.get("/gone", function(_req: Web.Request): Web.Response
      return Web.abort(410, "removed <b>", { reason = "x" })
    end),
    Web.get("/down", function(_req: Web.Request): Web.Response
      return Web.abort(503)
    end),
  }, sink = recording() }
  local client = Web.test_client(app)
  local page = client:get("/gone")
  assert(page.status == 410 and page.body:find("removed &lt;b&gt;", 1, true) and not page.body:find("<b>", 1, true))
  local json = client:get("/gone", { headers = { accept = "application/json" } })
  local body = assert(Json.decode_object(json:text()))
  assert(json.status == 410 and body.detail == "removed <b>" and body.reason == "x")
  assert(client:get("/down").status == 503)
end

local function test_error_pages_and_error_view_replace_the_default()
  local app = Web.app{
    routes = { Web.get("/gone", function(_req: Web.Request): Web.Response
      return Web.abort(410, "bye")
    end),
      Web.get("/x", hello) },
    error_pages = { [404] = function(_req: Web.Request): Web.Response
      return Web.text("custom 404", { status = 404 })
    end },
    error_view = function(_req: Web.Request, status: integer, detail: string): Web.Response
      return Web.text(("view %d %s"):format(status, detail), { status = status })
    end,
  }
  local client = Web.test_client(app)
  assert(client:get("/missing"):text() == "custom 404")
  local gone = client:get("/gone")
  assert(gone.status == 410 and gone:text() == "view 410 bye")
  local denied = client:post("/x")
  assert(denied.status == 405 and denied:text() == "view 405 " and denied.headers["allow"] == "GET, HEAD, OPTIONS")
end

local function test_a_page_that_raises_falls_back_to_a_plain_500()
  local sink = recording()
  local app = Web.app{
    routes = { Web.get("/x", hello) },
    error_pages = { [404] = function(_req: Web.Request): Web.Response
      error("the page is broken")
    end },
    sink = sink,
  }
  local res = Web.test_client(app):get("/missing")
  assert(res.status == 500 and res.body:find("500 Internal Server Error", 1, true), res.body)
  local both = Web.app{
    routes = { Web.get("/x", hello) },
    error_pages = { [404] = function(_req: Web.Request): Web.Response
      error("the page is broken")
    end,
      [500] = function(_req: Web.Request): Web.Response error("so is this one") end },
    sink = sink,
  }
  local last = Web.test_client(both):get("/missing")
  assert(last.status == 500 and last:text() == "Internal Server Error\n")
end

local function test_trusted_hosts_answer_only_their_own()
  local app = Web.app{ routes = { Web.get("/", hello) }, trusted_hosts = { "App.Example.com", "localhost" } }
  local client = Web.test_client(app)
  assert(client:get("/", { headers = { host = "app.example.com" } }).status == 200)
  assert(client:get("/", { headers = { host = "APP.example.com:8080" } }).status == 200)
  assert(client:get("/", { headers = { host = "localhost:3000" } }).status == 200)
  assert(client:get("/", { headers = { host = "evil.com" } }).status == 400)
  assert(client:get("/", { headers = { host = "app.example.com.evil.com" } }).status == 400)
  assert(client:get("/").status == 400, "testserver is not listed")
end

local function test_access_log_writes_one_line_without_the_query()
  local sink, lines = recording()
  local app = Web.app{
    routes = { Web.get("/items/:id", hello), Web.get("/stream", function(_req: Web.Request): Web.Response
      return Web.stream(require("cosmic.stream").from_string("abc"), "text/plain")
    end) },
    middleware = { Web.access_log() }, sink = sink,
  }
  local client = Web.test_client(app)
  client:get("/items/42?token=secret")
  client:get("/missing")
  client:get("/stream")
  assert(lines[1]:find("^GET /items/42 200 %d+ms 5B client=127%.0%.0%.1$"), lines[1])
  assert(not lines[1]:find("secret", 1, true))
  assert(lines[2]:find("^GET /missing 404 ", 1) ~= nil, lines[2])
  assert(lines[3]:find(" stream client=", 1, true), lines[3])
end

local function test_access_log_options_choose_the_sink_format_and_what_to_skip()
  local own, own_lines = recording()
  local default, default_lines = recording()
  local app = Web.app{
    routes = { Web.get("/items", hello), Web.get("/health", hello), Web.get("/big", function(_req: Web.Request): Web.Response
      return Web.text(("x"):rep(3000))
    end) },
    middleware = { Web.access_log({ sink = own, log_query = true, skip = function(req: Web.Request): boolean
      return req.path == "/health"
    end }) },
    sink = default,
  }
  local client = Web.test_client(app)
  client:get("/items?a=1")
  client:get("/health")
  client:get("/big")
  assert(#own_lines == 2 and #default_lines == 0)
  assert(own_lines[1]:find("^GET /items%?a=1 200 "), own_lines[1])
  assert(own_lines[2]:find(" 2%.9KB ", 1), own_lines[2])
  local formatted, formatted_lines = recording()
  local custom = Web.app{
    routes = { Web.get("/items", hello) },
    middleware = { Web.access_log({ sink = formatted, format = function(req: Web.Request, res: Web.Response, ns: integer): string
      return ("%s %d %s"):format(req.method, res.status, if ns >= 0 then "timed" else "?" end)
    end }) },
  }
  Web.test_client(custom):get("/items")
  assert(formatted_lines[1] == "GET 200 timed")
end

local function test_an_app_refuses_a_spec_with_a_field_it_does_not_have()
  local spec: any = { routes = {}, middlewares = {} }
  assert(raised(function() Web.app(spec as Web.AppSpec) end):find("app has no field middlewares", 1, true))
end

local function test_a_missing_handler_or_bad_registration_raises_when_the_app_is_built()
  local ok, err = pcall(function(): any
    Web.app{ routes = { Web.get("/a", hello), Web.get("/a", hello) } }
    return nil
  end)
  assert(not ok and tostring(err):find("already answered", 1, true), tostring(err))
end

local function test_url_for_resolves_names_on_the_app()
  local app = Web.app{ routes = { Web.get("/items/:id", hello, { name = "item" }) } }
  assert(app:url_for("item", { id = 3 }) == "/items/3")
  local none, why = app:url_for("nope")
  assert(none == nil and why:find("no route named", 1, true), why)
end

local function test_stopping_starts_false()
  local app = Web.app{ routes = {} }
  assert(app:stopping() == false)
end

--- A middleware that aborts every request with 403 before its handler.
local function aborting(trace: mut {string}): Web.Middleware
  return function(_inner: Web.Handler): Web.Handler
    return function(_req: Web.Request): Web.Response
      trace[#trace + 1] = "abort"
      return Web.abort(403, "no entry")
    end
  end
end

local function test_abort_from_app_middleware_is_answered_and_seen_by_the_middleware_outside()
  local trace: mut {string} = {}
  local sink, lines = recording()
  local app = Web.app{
    routes = { Web.get("/", hello) },
    middleware = { Web.access_log(), tracing(trace, "A"), aborting(trace) },
    sink = sink,
  }
  local res = Web.test_client(app):get("/", { headers = { accept = "application/json" } })
  assert(res.status == 403, "answered, not raised")
  local body = assert(res:json()) as {string:any}
  assert(body.detail == "no entry" and body.status == 403)
  assert(table.concat(trace, " ") == "A abort /A", table.concat(trace, " "))
  assert(#lines == 1 and lines[1]:find("^GET / 403 "), table.concat(lines, "|"))
  assert(Web.test_client(app):get("/").status == 403, "an error page, negotiated like any")
end

local function test_abort_from_mount_and_route_middleware_is_answered()
  local trace: mut {string} = {}
  local app = Web.app{
    routes = {
      Web.mount("/m", { Web.get("/x", hello) }, { middleware = { aborting(trace) } }),
      Web.get("/r", hello, { middleware = { tracing(trace, "R"), aborting(trace) } }),
      Web.mount("/ok", { Web.get("/x", hello, { middleware = { aborting(trace) } }) }),
    },
    middleware = { tracing(trace, "A") },
  }
  local client = Web.test_client(app)
  assert(client:get("/m/x").status == 403)
  assert(client:get("/m/missing").status == 403, "a miss inside the mount passes its middleware too")
  assert(client:get("/r").status == 403)
  assert(client:get("/ok/x").status == 403)
  assert(table.concat(trace, " ") == "A abort /A A abort /A A R abort /R /A A abort /A", table.concat(trace, " "))
end

local function test_a_fault_in_app_middleware_still_reaches_the_server_not_the_middleware_outside()
  local seen: mut {integer} = {}
  local function faulting(_inner: Web.Handler): Web.Handler
    return function(_req: Web.Request): Web.Response
      error("middleware bug")
    end
  end
  local function watching(inner: Web.Handler): Web.Handler
    return function(req: Web.Request): Web.Response
      local res = inner(req)
      seen[#seen + 1] = res.status
      return res
    end
  end
  local app = Web.app{ routes = { Web.get("/", hello) }, middleware = { watching, faulting } }
  local message = raised(function() Web.test_client(app):get("/") end)
  assert(message:find("middleware bug", 1, true), message)
  assert(#seen == 0)
  local trail = select(2, message:gsub("stack traceback:", ""))
  assert(trail == 1, "traced once, by the first layer that saw it")
end

local function test_access_log_escapes_control_bytes_of_the_query()
  local sink, lines = recording()
  local app = Web.app{ routes = { Web.get("/", hello) }, middleware = { Web.access_log{ log_query = true } },
    sink = sink }
  local raw: Server.Request = { method = "GET", target = "/?a=1\r\nFAKE 200", path = "/",
    query = "a=1\r\nFAKE 200 line\127", version = "HTTP/1.1", headers = { host = "x" },
    body = Stream.from_string(""), length = 0 }
  assert(app.handle(raw).status == 200)
  assert(#lines == 1 and not lines[1]:find("[\r\n\127]"), lines[1])
  assert(lines[1]:find("?a=1%0D%0AFAKE 200 line%7F", 1, true), lines[1])
end
