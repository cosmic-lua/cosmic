--- The app's half of the development loop ([`Dev.app`], [`Dev.static`]): the
--- tag in pages, the script, the event stream, the loopback-only rule. The
--- supervisor is in cosmic/web/dev_supervise_test.tl.

local Dev = require("cosmic.web.dev")
local Fs = require("cosmic.fs")
local Headers = require("cosmic.web.headers")
local Html = require("cosmic.html")
local Net = require("cosmic.net")
local Test = require("cosmic.test")
local Web = require("cosmic.web")

Test.policy{}

local TAG <const> = '<script src="/_web/dev.js" defer></script>'

--- The message of the error `fn` raises; fails where it raises none.
local function raised(fn: function()): string
  local ok, err = pcall(function(): any
    fn()
    return nil
  end)
  assert(not ok, "expected a raise")
  return tostring(err)
end

local PAGE <const> = Html.trust("<html><body><p>hi</p></body></html>")

local shared: Web.Response = Web.html(PAGE)

local function routes(): {Web.Route}
  return {
    Web.get("/", function(_req: Web.Request): Web.Response return Web.html(PAGE) end),
    Web.get("/upper", function(_req: Web.Request): Web.Response
      return Web.html(Html.trust("<HTML><BODY>x</BODY></HTML>"))
    end),
    Web.get("/twice", function(_req: Web.Request): Web.Response
      return Web.html(Html.trust("<body>a</body><pre>&lt;/body&gt;</pre></body>"))
    end),
    Web.get("/fragment", function(_req: Web.Request): Web.Response
      return Web.html(Html.trust("<p>a fragment</p>"))
    end),
    Web.get("/json", function(_req: Web.Request): Web.Response
      return Web.json({ a = "</body>" })
    end),
    Web.get("/shared", function(_req: Web.Request): Web.Response return shared end),
    Web.get("/boom", function(_req: Web.Request): Web.Response error("kaboom") end),
  }
end

--- `opts` naming a host the development app trusts, as a browser's would.
local function local_opts(opts?: Web.TestOptions, host?: string): Web.TestOptions
  local made: Web.TestOptions = {}
  for key, value in pairs((opts or {}) as {string:any}) do (made as {string:any})[key] = value end
  local headers: {string:string} = { host = host or "localhost:8080" }
  for name, value in pairs((opts and opts.headers) or {}) do headers[name:lower()] = value end
  made.headers = headers
  return made
end

local function get(client: Web.TestClient, path: string, opts?: Web.TestOptions): Web.TestResponse
  return client:get(path, local_opts(opts))
end

local function send(client: Web.TestClient, method: string, path: string): Web.TestResponse
  return client:request(method, path, local_opts())
end

local function quiet(): Web.Sink
  return { line = function(_self: Web.Sink, _text: string) end }
end

local function test_without_development_mode_the_app_is_the_plain_one()
  local app = Dev.app({ routes = routes(), sink = quiet() }, { enabled = false })
  assert(not app.spec.dev and not app.spec.debug)
  Web.with_client(app, function(client: Web.TestClient)
    assert(get(client, "/").body == "<html><body><p>hi</p></body></html>")
    assert(get(client, "/_web/dev.js").status == 404)
    assert(get(client, "/_web/dev/events").status == 404)
    local boom = get(client, "/boom")
    assert(boom.status == 500 and not boom.body:find("kaboom", 1, true))
  end)
end

local function test_a_page_gets_the_script_before_its_last_body_end()
  local app = Dev.app({ routes = routes(), sink = quiet() }, { enabled = true })
  assert(app.spec.dev and app.spec.debug)
  Web.with_client(app, function(client: Web.TestClient)
    local page = get(client, "/")
    assert(page.body == "<html><body><p>hi</p>" .. TAG .. "</body></html>")
    assert(page.headers["content-length"] == tostring(#page.body))
    assert(get(client, "/upper").body == "<HTML><BODY>x" .. TAG .. "</BODY></HTML>")
    assert(get(client, "/twice").body == "<body>a</body><pre>&lt;/body&gt;</pre>" .. TAG .. "</body>")
  end)
end

local function test_the_tag_carries_the_nonce_the_headers_middleware_drew()
  local policy = Headers.Csp.htmx_default()
  policy.directives["script-src"] = { "'self'", "{nonce}" }
  local app = Dev.app({ routes = routes(), sink = quiet(),
    middleware = { Headers.middleware{ csp = policy, nonce = true } } }, { enabled = true })
  Web.with_client(app, function(client: Web.TestClient)
    local page = get(client, "/")
    local nonce = assert(page.headers["content-security-policy"]:match("'nonce%-([%w_-]+)'"))
    -- A byte that is no letter or digit is written as a character reference.
    local written = nonce:gsub("[_-]", function(byte: string): string
      return ("&#%d;"):format(byte:byte())
    end)
    assert(page.body == '<html><body><p>hi</p><script src="/_web/dev.js" nonce="' .. written ..
        '" defer></script></body></html>', page.body)
    local second = get(client, "/").headers["content-security-policy"]
    assert(second ~= page.headers["content-security-policy"], "each request draws its own nonce")
  end)
end

local function test_only_pages_with_an_end_of_body_are_touched()
  local app = Dev.app({ routes = routes(), sink = quiet() }, { enabled = true })
  Web.with_client(app, function(client: Web.TestClient)
    assert(get(client, "/fragment").body == "<p>a fragment</p>")
    assert(get(client, "/json").body == '{"a":"</body>"}')
    assert(get(client, "/missing").status == 404)
  end)
end

local function test_a_response_a_handler_keeps_is_not_changed()
  local app = Dev.app({ routes = routes(), sink = quiet() }, { enabled = true })
  Web.with_client(app, function(client: Web.TestClient)
    local first = get(client, "/shared").body
    local second = get(client, "/shared").body
    assert(first == second and first:find(TAG, 1, true) ~= nil)
    assert(select(2, first:gsub("dev%.js", "")) == 1, "the tag is added once")
    assert(shared.body == "<html><body><p>hi</p></body></html>")
  end)
end

local function test_the_script_is_served_without_an_inline_script()
  local app = Dev.app({ routes = routes(), sink = quiet() }, { enabled = true })
  Web.with_client(app, function(client: Web.TestClient)
    local res = get(client, "/_web/dev.js")
    assert(res.status == 200 and res.headers["content-type"]:find("^text/javascript") ~= nil)
    assert(res.headers["cache-control"] == "no-store")
    assert(res.body:find("/_web/dev/events", 1, true) and res.body:find("EventSource", 1, true))
    assert(not res.body:find("<script", 1, true))
    assert(send(client, "POST", "/_web/dev.js").status ~= 200)
  end)
end

local function test_a_fault_shows_its_stack_in_development_mode_only()
  local app = Dev.app({ routes = routes(), sink = quiet() }, { enabled = true })
  Web.with_client(app, function(client: Web.TestClient)
    local boom = get(client, "/boom")
    assert(boom.status == 500 and boom.body:find("kaboom", 1, true))
  end)
end

--- Reads from `res` until `needle` has arrived; returns all it read.
local function read_until(res: Web.TestResponse, needle: string): string
  local got = ""
  for _ = 1, 20 do
    local piece, why = assert(res.stream):read()
    assert(piece ~= nil, "the stream ended: " .. why)
    got = got .. piece
    if got:find(needle, 1, true) then return got end
  end
  error("never saw " .. needle)
end

--- Writes `data` to `path` and moves its time on, so a change shows by
--- either.
local function put(path: string, data: string, seconds: integer)
  assert(Fs.write(path, data))
  assert(Fs.set_mtime(path, seconds))
end

local function test_the_stream_tells_the_boot_then_what_moved_under_static(tmp: string)
  local static = tmp .. "/static"
  assert(Fs.mkdirs(static))
  put(static .. "/app.css", "a{}", 1000000)
  put(static .. "/app.js", "1", 1000000)
  local app = Dev.app({ routes = routes(), sink = quiet() },
    { enabled = true, static = static, interval_ns = 5000000, boot = "7" })
  Web.with_client(app, function(client: Web.TestClient)
    local res = get(client, "/_web/dev/events", { stream = true })
    assert(res.status == 200 and res.headers["content-type"] == "text/event-stream")
    local head = read_until(res, "event: boot")
    assert(head:find("retry: 300", 1, true))
    if not head:find("data: 7", 1, true) then read_until(res, "data: 7") end
    put(static .. "/app.css", "a{color:red}", 1000001)
    local css = read_until(res, "event: css")
    assert(css:find("app.css", 1, true) and not css:find("event: reload", 1, true))
    put(static .. "/app.js", "22", 1000002)
    assert(read_until(res, "event: reload"))
    put(static .. "/new.css", "b{}", 1000003)
    put(static .. "/new.js", "c", 1000003)
    local mixed = read_until(res, "event: ")
    assert(mixed:find("event: reload", 1, true), "a css change with a script change reloads")
    assert(assert(res.stream):close())
  end)
  assert(app.stream_count == 0)
end

local function test_a_stream_ends_when_the_app_stops(tmp: string)
  local app = Dev.app({ routes = routes(), sink = quiet() },
    { enabled = true, static = tmp, interval_ns = 5000000 })
  Web.with_client(app, function(client: Web.TestClient)
    local res = get(client, "/_web/dev/events", { stream = true })
    read_until(res, "event: boot")
    assert(app.stream_count == 1)
    app.stopped = true
    for _, close in pairs(app.streams) do close() end
    local piece = assert(res.stream):read()
    assert(piece == nil, "the stream ended")
    assert(app.stream_count == 0)
  end)
end

local function test_a_development_app_serves_the_loopback_only()
  local app = Dev.app({ routes = routes(), sink = quiet() }, { enabled = true })
  for _, host in ipairs({ "0.0.0.0", "10.0.0.5", "127.evil.example", "::", "::2", "127.0.0" }) do
    local ok, why = Web.serve(app, { listeners = { Net.tcp(host, 0) } })
    assert(ok == false and why:find("loopback", 1, true), host .. ": " .. tostring(why))
  end
  local ok, why = Web.serve(app, { listeners = { Net.tcp("127.0.0.1", 0), Net.tcp("10.1.2.3", 0) } })
  assert(ok == false and why:find("loopback", 1, true), "one address beyond the loopback is enough")
end

local function test_the_plain_app_and_a_debug_app_are_left_to_the_caller()
  local app = Web.app{ routes = routes(), debug = true, sink = quiet() }
  assert(not app.spec.dev)
  local plain = Dev.app({ routes = routes(), sink = quiet() }, { enabled = false })
  assert(not plain.spec.dev)
end

local function test_static_is_served_from_disk_and_never_cached_in_development(tmp: string)
  local static = tmp .. "/static"
  assert(Fs.mkdirs(static))
  put(static .. "/a.css", "one", 1000000)
  local app = Web.app{ routes = { Dev.static("/assets", { enabled = true, static = static }) },
    sink = quiet() }
  Web.with_client(app, function(client: Web.TestClient)
    local first = get(client, "/assets/a.css")
    assert(first.status == 200 and first.body == "one")
    assert(first.headers["cache-control"] == "no-store")
    put(static .. "/a.css", "three", 1000001)
    assert(get(client, "/assets/a.css").body == "three")
    assert(get(client, "/assets/missing.css").status == 404)
  end)
  assert(app:url_for("static", { path = "a.css" }) ~= nil)
end

local function test_an_option_of_the_wrong_kind_raises()
  local wrong: any = { enabled = "yes" }
  assert(raised(function() Dev.app({}, wrong as Dev.Options) end):find("enabled", 1, true))
  local unknown: any = { stat = "x" }
  assert(raised(function() Dev.app({}, unknown as Dev.Options) end):find("no field stat", 1, true))
  assert(raised(function() Dev.app({}, { interval_ns = 0 }) end):find("interval_ns", 1, true))
  assert(raised(function() Dev.static("/s", { static = "" }) end):find("static", 1, true))
end

local function test_a_page_htmx_swaps_in_gets_no_second_script()
  local app = Dev.app({ routes = routes(), sink = quiet() }, { enabled = true })
  Web.with_client(app, function(client: Web.TestClient)
    local boosted = client:get("/", local_opts({ headers = { ["HX-Request"] = "true", ["HX-Boosted"] = "true" } }))
    assert(boosted.status == 200 and boosted.body == "<html><body><p>hi</p></body></html>")
    assert(get(client, "/").body:find(TAG, 1, true) ~= nil, "a plain request still gets it")
  end)
end

local function test_the_script_runs_once_per_window()
  local app = Dev.app({ routes = routes(), sink = quiet() }, { enabled = true })
  Web.with_client(app, function(client: Web.TestClient)
    local body = get(client, "/_web/dev.js").body
    local guard = body:find("if (window.__cosmicDev) return;", 1, true)
    local open = body:find("new EventSource", 1, true)
    assert(guard ~= nil and open ~= nil and guard < open, "the guard comes before the stream opens")
  end)
end

local function test_a_host_the_app_does_not_trust_is_refused()
  local app = Dev.app({ routes = routes(), sink = quiet() }, { enabled = true })
  assert(assert(app.spec.trusted_hosts)[1] == "localhost")
  Web.with_client(app, function(client: Web.TestClient)
    for _, path in ipairs({ "/", "/_web/dev.js", "/_web/dev/events", "/boom" }) do
      local res = client:get(path, local_opts(nil, "evil.example"))
      assert(res.status == 400, path .. ": " .. res.status)
      assert(not res.body:find("kaboom", 1, true) and not res.body:find("EventSource", 1, true))
    end
    for _, host in ipairs({ "localhost:8080", "127.0.0.1:9", "[::1]:3000", "LOCALHOST" }) do
      assert(client:get("/_web/dev.js", local_opts(nil, host)).status == 200, host)
      assert(client:get("/", local_opts(nil, host)).body:find(TAG, 1, true), host)
    end
  end)
end

local function test_named_trusted_hosts_replace_the_loopback_default()
  local app = Dev.app({ routes = routes(), sink = quiet(), trusted_hosts = { "dev.test" } }, { enabled = true })
  Web.with_client(app, function(client: Web.TestClient)
    assert(client:get("/_web/dev.js", local_opts(nil, "dev.test")).status == 200)
    assert(client:get("/_web/dev.js", local_opts(nil, "localhost")).status == 400)
  end)
end

local function test_a_development_app_with_a_trusted_proxy_is_refused()
  local app = Dev.app({ routes = routes(), sink = quiet(), trusted_proxy = true }, { enabled = true })
  local ok, why = Web.serve(app, { listeners = { Net.tcp("127.0.0.1", 0) } })
  assert(ok == false and why:find("trusted_proxy", 1, true), tostring(why))
end

local function test_a_missing_static_directory_is_watched_without_a_spurious_reload(tmp: string)
  local static = tmp .. "/later"
  local app = Dev.app({ routes = routes(), sink = quiet() },
    { enabled = true, static = static, interval_ns = 5000000 })
  Web.with_client(app, function(client: Web.TestClient)
    local res = get(client, "/_web/dev/events", { stream = true })
    assert(res.status == 200)
    read_until(res, "event: boot")
    assert(Fs.mkdirs(static))
    put(static .. "/a.css", "a{}", 1000000)
    local got = read_until(res, "event: ")
    assert(got:find("event: css", 1, true) and not got:find("event: reload", 1, true), got)
    assert(Fs.remove(static .. "/a.css"))
    assert(read_until(res, "event: css"))
    assert(assert(res.stream):close())
  end)
end
