local Clock = require("cosmic.clock")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local Web = require("cosmic.web")

--- The message of the error `fn` raises; fails where it raises none.
local function raised(fn: function()): string
  local ok, err = pcall(function(): any
    fn()
    return nil
  end)
  assert(not ok, "expected a raise")
  return tostring(err)
end

--- An app that echoes what a request carried.
local function echo(): Web.App
  return Web.app{ routes = {
    Web.route({ "GET", "POST", "PUT", "PATCH", "DELETE" }, "/echo", function(req: Web.Request): Web.Response
      local query = assert(req:query())
      local pairs_: mut {string} = {}
      for _, pair in ipairs(query.pairs) do pairs_[#pairs_ + 1] = pair.name .. "=" .. pair.value end
      return Web.json({ method = req.method, query = pairs_, body = req:text() or "", ct = req:header("content-type") or "",
        cookie = req:header("cookie") or "", length = req:header("content-length") or "" })
    end),
  } }
end

local function test_the_client_builds_the_query_form_json_and_body_of_a_request()
  local client = Web.test_client(echo())
  local get = assert(client:get("/echo?a=1", { query = { b = "2", c = { "x", "y z" } } }):json())
  assert(get is {string:any} and get.method == "GET")
  local query = get.query
  assert(query is {string} and table.concat(query, "&") == "a=1&b=2&c=x&c=y z")
  local form = assert(client:post("/echo", { form = { title = "a b", qty = "2" } }):json())
  assert(form is {string:any} and form.body == "qty=2&title=a+b" and form.ct == "application/x-www-form-urlencoded")
  local json = assert(client:put("/echo", { json = { n = 1 } }):json())
  assert(json is {string:any} and json.body == '{"n":1}' and json.ct == "application/json" and json.length == "7")
  local raw = assert(client:patch("/echo", { body = "abc", content_type = "text/plain" }):json())
  assert(raw is {string:any} and raw.body == "abc" and raw.ct == "text/plain")
  local reader = assert(client:delete("/echo", { body = Stream.from_string("xyz") }):json())
  assert(reader is {string:any} and reader.method == "DELETE" and reader.body == "xyz")
  local headers = assert(client:post("/echo", { headers = { ["Content-Type"] = "text/csv" }, body = "a,b" }):json())
  assert(headers is {string:any} and headers.ct == "text/csv")
end

local function test_a_response_reads_as_text_json_and_header_lines()
  local app = Web.app{ routes = { Web.get("/", function(_req: Web.Request): Web.Response
    local res = Web.json({ ok = true })
    Web.add_header(res, "Set-Cookie", "a=1")
    Web.add_header(res, "Set-Cookie", "b=2")
    return res
  end), Web.get("/plain", function(_req: Web.Request): Web.Response return Web.text("not json") end) } }
  local client = Web.test_client(app)
  local res = client:get("/")
  assert(res.ok and res:text() == '{"ok":true}' and res.headers["content-length"] == "11")
  local lines = res:header_list("Set-Cookie")
  assert(#lines == 2 and lines[1] == "a=1" and lines[2] == "b=2" and res.headers["set-cookie"] == "a=1, b=2")
  assert(#res:header_list("x-none") == 0 and res.redirect_location == nil)
  local value = assert(res:json())
  assert(value is {string:any} and value.ok == true)
  local none, why = client:get("/plain"):json()
  assert(none == nil and why:find("json:", 1, true), why)
end

local function test_the_jar_keeps_cookies_between_calls_and_drops_a_deleted_one()
  local app = Web.app{ routes = {
    Web.get("/set", function(_req: Web.Request): Web.Response
      local res = Web.text("set")
      Web.add_header(res, "Set-Cookie", "a=1; Path=/; HttpOnly")
      Web.add_header(res, "Set-Cookie", "b=2")
      return res
    end),
    Web.get("/drop", function(_req: Web.Request): Web.Response
      local res = Web.text("drop")
      Web.add_header(res, "Set-Cookie", "a=; Max-Age=0")
      return res
    end),
    Web.get("/see", function(req: Web.Request): Web.Response
      return Web.text(req:header("cookie") or "none")
    end),
  } }
  local client = Web.test_client(app)
  assert(client:get("/see"):text() == "none")
  client:get("/set")
  assert(client:get("/see"):text() == "a=1; b=2" and client.jar.a == "1")
  assert(client:get("/see", { cookies = { c = "3" } }):text() == "a=1; b=2; c=3")
  assert(client:get("/see"):text() == "a=1; b=2", "extra cookies are not kept")
  client:get("/drop")
  assert(client:get("/see"):text() == "b=2")
  assert(Web.test_client(app):get("/see"):text() == "none", "another client has its own jar")
end

local function test_redirects_are_followed_when_asked_with_the_methods_rule()
  local app = Web.app{ routes = {
    Web.post("/form", function(_req: Web.Request): Web.Response return Web.redirect("/done") end),
    Web.post("/keep", function(_req: Web.Request): Web.Response
      return Web.redirect("/landing", { status = 307 })
    end),
    Web.route({ "GET", "POST" }, "/landing", function(req: Web.Request): Web.Response
      return Web.text(req.method .. ":" .. (req:text() or ""))
    end),
    Web.get("/done", function(req: Web.Request): Web.Response
      return Web.text("done " .. req.method)
    end),
    Web.get("/loop", function(_req: Web.Request): Web.Response return Web.redirect("/loop") end),
    Web.get("/abs", function(_req: Web.Request): Web.Response
      return Web.redirect("https://example.com/done?x=1")
    end),
  } }
  local client = Web.test_client(app)
  local stopped = client:post("/form")
  assert(stopped.status == 303 and stopped.redirect_location == "/done")
  assert(client:post("/form", { follow_redirects = true }):text() == "done GET")
  assert(client:post("/keep", { body = "payload", follow_redirects = true }):text() == "POST:payload")
  local looping = client:get("/loop", { follow_redirects = true })
  assert(looping.status == 303, "ten hops, then the redirect is handed back")
  assert(client:get("/abs", { follow_redirects = true }):text() == "done GET")
end

local function test_a_reader_body_is_read_whole_or_left_as_a_stream_or_closed_for_head()
  local closed = { value = 0 }
  local function reader(): Stream.Reader
    local inner = Stream.from_string("streamed")
    return {
      read = function(_self: Stream.Reader, max?: integer): string?, string
        return inner:read(max)
      end,
      close = function(_self: Stream.Reader): boolean, string
        closed.value = closed.value + 1
        return true, ""
      end,
    }
  end
  local app = Web.app{ routes = { Web.get("/s", function(_req: Web.Request): Web.Response
    return Web.stream(reader(), "text/plain")
  end) } }
  local client = Web.test_client(app)
  local whole = client:get("/s")
  assert(whole:text() == "streamed" and closed.value == 1 and whole.stream == nil)
  local head = client:head("/s")
  assert(head.body == "" and closed.value == 2)
  local streaming = client:get("/s", { stream = true })
  local streaming_stream = streaming.stream
  assert(streaming.body == "" and streaming_stream ~= nil and closed.value == 2)
  assert(Stream.read_all(streaming_stream) == "streamed")
end

local function test_the_client_fails_a_reply_the_server_would_answer_500_for()
  local closed = { value = false }
  local app = Web.app{ routes = {
    Web.get("/header", function(_req: Web.Request): Web.Response
      return { status = 200, headers = { ["X-A"] = "a\r\nSet-Cookie: x=1" }, body = "x" }
    end),
    Web.get("/length", function(_req: Web.Request): Web.Response
      return { status = 200, body = "abc", length = 9 }
    end),
    Web.get("/body", function(_req: Web.Request): Web.Response
      return { status = 204, body = "oops" }
    end),
    Web.get("/reader", function(_req: Web.Request): Web.Response
      return { status = 204, body = { read = function(_s: Stream.Reader, _m?: integer): string?, string
        return nil, ""
      end,
        close = function(_s: Stream.Reader): boolean, string
          closed.value = true
          return true, ""
        end } }
    end),
  } }
  local client = Web.test_client(app)
  for _, path in ipairs({ "/header", "/length", "/body", "/reader" }) do
    local message = raised(function() client:get(path) end)
    assert(message:find("the server would answer 500", 1, true), path .. ": " .. message)
  end
  assert(closed.value, "an unsent Reader body is closed")
  assert(raised(function() client:get("nowhere") end):find("must start with '/'", 1, true))
end

local function test_a_handler_may_wait_in_the_loop_the_client_runs_it_in()
  local app = Web.app{ routes = { Web.get("/slow", function(_req: Web.Request): Web.Response
    assert(Poll.delay(Clock.ms(5)))
    return Web.text("waited")
  end) } }
  assert(Web.test_client(app):get("/slow"):text() == "waited", "outside a task: the client runs its own")
  Web.with_client(app, function(client: Web.TestClient)
    assert(Poll.in_task())
    assert(client:get("/slow"):text() == "waited")
    assert(client:get("/slow"):text() == "waited")
  end)
end

local function test_the_lifespan_runs_at_the_first_request_and_cleans_up_on_close()
  local DB: Web.Key<{string}> = Web.key("db")
  local events: mut {string} = {}
  local function make(): Web.App
    return Web.app{
      routes = { Web.get("/", function(req: Web.Request): Web.Response
        local db = req.app.state[DB] as {string}
        db[#db + 1] = "request"
        return Web.text(#db .. "")
      end) },
      lifespan = function(app: Web.App): Web.Shutdown?, string
        events[#events + 1] = "start"
        app.state[DB] = events
        return function() events[#events + 1] = "stop" end, ""
      end,
    }
  end
  do
    local client <close> = Web.test_client(make())
    assert(#events == 0, "nothing runs before the first request")
    assert(client:get("/"):text() == "2")
    assert(client:get("/"):text() == "3")
    assert(#events == 3)
  end
  assert(table.concat(events, " ") == "start request request stop", table.concat(events, " "))
  for i = #events, 1, -1 do events[i] = nil end
  Web.with_client(make(), function(client: Web.TestClient)
    assert(#events == 1)
    client:get("/")
  end)
  assert(table.concat(events, " ") == "start request stop")
end

local function test_a_failed_lifespan_fails_the_first_request()
  local app = Web.app{ routes = {}, lifespan = function(_app: Web.App): Web.Shutdown?, string
    return nil, "no database"
  end }
  assert(raised(function() Web.test_client(app):get("/") end):find("the lifespan failed: no database", 1, true))
end

local function test_a_lifespan_that_failed_is_run_again_by_the_next_request()
  local starts = { value = 0 }
  local app = Web.app{ routes = { Web.get("/", function(_req: Web.Request): Web.Response
    return Web.text("up")
  end) }, lifespan = function(_app: Web.App): Web.Shutdown?, string
    starts.value = starts.value + 1
    if starts.value == 1 then return nil, "not yet" end
    return function() end, ""
  end }
  local client = Web.test_client(app)
  assert(raised(function() client:get("/") end):find("the lifespan failed: not yet", 1, true))
  assert(client:get("/"):text() == "up", "the second request starts it, since the first did not")
  assert(starts.value == 2)
  assert(client:get("/").status == 200 and starts.value == 2, "started once it has succeeded")
end

local function test_the_jar_sends_a_cookie_only_where_its_path_matches()
  local app = Web.app{ routes = {
    Web.get("/set", function(_req: Web.Request): Web.Response
      local res = Web.text("set")
      Web.add_header(res, "Set-Cookie", "deep=1; Path=/admin")
      Web.add_header(res, "Set-Cookie", "root=1; Path=/")
      return res
    end),
    Web.get("/area/set", function(_req: Web.Request): Web.Response
      local res = Web.text("set")
      Web.add_header(res, "Set-Cookie", "here=1")
      return res
    end),
    Web.get("/*rest", function(req: Web.Request): Web.Response
      return Web.text(req:header("cookie") or "none")
    end),
  } }
  local client = Web.test_client(app)
  client:get("/set")
  client:get("/area/set")
  assert(client:get("/admin"):text() == "deep=1; root=1")
  assert(client:get("/admin/users"):text() == "deep=1; root=1")
  assert(client:get("/administrator"):text() == "root=1", "/admin is not a prefix of /administrator by segment")
  assert(client:get("/other"):text() == "root=1")
  assert(client:get("/area/page"):text() == "here=1; root=1", "no Path: the directory of the request")
end

local function test_the_jar_expires_a_cookie_by_max_age_and_by_expires_date()
  local app = Web.app{ routes = {
    Web.get("/set", function(_req: Web.Request): Web.Response
      local res = Web.text("set")
      Web.add_header(res, "Set-Cookie", "short=1; Max-Age=60")
      Web.add_header(res, "Set-Cookie", "old=1; Expires=Thu, 01 Jan 1970 00:00:00 GMT")
      Web.add_header(res, "Set-Cookie", "future=1; Expires=Fri, 01 Jan 2100 00:00:00 GMT")
      Web.add_header(res, "Set-Cookie", "plain=1")
      return res
    end),
    Web.get("/see", function(req: Web.Request): Web.Response
      return Web.text(req:header("cookie") or "none")
    end),
  } }
  local client = Web.test_client(app)
  client:get("/set")
  assert(client:get("/see"):text() == "future=1; plain=1; short=1", "a cookie set already expired is not kept")
  client.attrs.short.expires_ns = 1
  assert(client:get("/see"):text() == "future=1; plain=1", "a lapsed cookie is dropped")
  assert(client.jar.short == nil)
end

local function test_the_jar_sends_a_secure_cookie_only_for_an_https_client()
  local app = Web.app{ trusted_proxy = true, routes = {
    Web.get("/set", function(_req: Web.Request): Web.Response
      local res = Web.text("set")
      Web.add_header(res, "Set-Cookie", "s=1; Secure")
      return res
    end),
    Web.get("/see", function(req: Web.Request): Web.Response
      return Web.text((req:header("cookie") or "none") .. " " .. req.scheme)
    end),
  } }
  local client = Web.test_client(app)
  client:get("/set")
  assert(client:get("/see"):text() == "none http")
  client.scheme = "https"
  assert(client:get("/see"):text() == "s=1 https")
end

local function test_a_delete_at_another_path_leaves_the_cookie_as_a_browser_does()
  local app = Web.app{ routes = {
    Web.get("/set", function(_req: Web.Request): Web.Response
      local res = Web.text("set")
      Web.add_header(res, "Set-Cookie", "a=1; Path=/x")
      return res
    end),
    Web.get("/drop", function(_req: Web.Request): Web.Response
      local res = Web.text("drop")
      Web.add_header(res, "Set-Cookie", "a=; Path=/y; Max-Age=0")
      return res
    end),
    Web.get("/drop-x", function(_req: Web.Request): Web.Response
      local res = Web.text("drop")
      Web.add_header(res, "Set-Cookie", "a=; Path=/x; Max-Age=0")
      return res
    end),
  } }
  local client = Web.test_client(app)
  client:get("/set")
  client:get("/drop")
  assert(client.jar.a == "1")
  client:get("/drop-x")
  assert(client.jar.a == nil)
end

local function test_a_huge_max_age_does_not_overflow_into_a_lapsed_cookie()
  local app = Web.app{ routes = {
    Web.get("/set", function(_req: Web.Request): Web.Response
      local res = Web.text("set")
      Web.add_header(res, "Set-Cookie", "a=1; Max-Age=9223372036854775807")
      return res
    end),
    Web.get("/see", function(req: Web.Request): Web.Response
      return Web.text(req:header("cookie") or "none")
    end),
  } }
  local client = Web.test_client(app)
  client:get("/set")
  assert(client:get("/see"):text() == "a=1")
  assert(assert(client.attrs.a.expires_ns) > 0)
end

--- A cookie set with neither Max-Age nor Expires is a session cookie: the
--- test client records no expiry for it.
local function test_a_session_cookie_has_no_expiry()
  local app = Web.app{ routes = { Web.get("/", function(_req: Web.Request): Web.Response
    local res = Web.text("ok")
    Web.add_header(res, "Set-Cookie", "a=1")
    return res
  end) } }
  local client = Web.test_client(app)
  assert(client:get("/").status == 200)
  assert(client.attrs.a.expires_ns == nil)
end
