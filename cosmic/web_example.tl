--- Worked examples for [`cosmic.web`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test. They drive an app through [`Web.test_client`], which calls its
--- handler in-process; `web_serve_example.tl` serves one on the loopback.

local Html = require("cosmic.html")
local Json = require("cosmic.json")
local Stream = require("cosmic.stream")
local Web = require("cosmic.web")

local Example = {}

--- A JSON API: routes are data built by [`Web.get`] and the like and compiled
--- by [`Web.app`]; `:id` binds one segment into `req.params`; an unknown path
--- is a 404 and a wrong method a 405 with `Allow`, in the form the client's
--- Accept asks for. `app:url_for` builds a URL back from a route's name.
function Example.api()
  local items = { { id = 1, title = "tea" }, { id = 2, title = "milk" } }
  local app = Web.app{ routes = {
    Web.get("/items", function(_req: Web.Request): Web.Response
      return Web.json(Json.array(items))
    end, { name = "items" }),
    Web.get("/items/:id", function(req: Web.Request): Web.Response
      local item = items[math.tointeger(tonumber(req.params["id"])) or 0]
      if item == nil then return Web.abort(404, "no such item") end
      return Web.json(item)
    end, { name = "item" }),
    Web.post("/items", function(req: Web.Request): Web.Response
      local added = { id = #items + 1, title = req:text() or "" }
      items[#items + 1] = added
      return Web.json(added, { status = 201, headers = { Location = assert(req:url_for("item", { id = added.id })) } })
    end),
  } }
  local client = Web.test_client(app)
  local one = client:get("/items/2")
  print(one.status, one.body) -- 200  {"id":2,"title":"milk"}
  assert(one.status == 200 and one.headers["content-type"] == "application/json")
  local created = client:post("/items", { body = "bread", content_type = "text/plain" })
  print(created.status, created.headers["location"]) -- 201  /items/3
  assert(created.status == 201 and created.redirect_location == nil and created.headers["location"] == "/items/3")
  local missing = client:get("/items/9", { headers = { accept = "application/json" } })
  print(missing.status, missing.headers["content-type"]) -- 404  application/problem+json
  assert(missing.status == 404 and assert(Json.decode_object(missing:text()))["detail"] == "no such item")
  local wrong = client:delete("/items")
  print(wrong.status, wrong.headers["allow"]) -- 405  GET, HEAD, OPTIONS, POST
  assert(wrong.status == 405)
  local url = assert(app:url_for("item", { id = 7 }, { fields = "title" }))
  print(url) -- /items/7?fields=title
  assert(url == "/items/7?fields=title")
end

--- A page: [`Web.html`] takes only escaped or vouched-for markup, so a title
--- from a client cannot become script. A POST answers with [`Web.redirect`],
--- 303 by default, to a local path; [`Web.safe_next`] keeps a client-sent
--- target from leaving the site.
function Example.pages()
  local app = Web.app{ routes = {
    Web.get("/hello/:name", function(req: Web.Request): Web.Response
      return Web.html(Html.concat({ Html.trust("<h1>Hello, "), Html.escape(assert(req.params["name"])), Html.trust("</h1>") }))
    end),
    Web.post("/login", function(req: Web.Request): Web.Response
      local query = assert(req:query())
      local next_urls = query.by_name["next"]
      return Web.redirect(Web.safe_next(next_urls and next_urls[1], "/home"))
    end),
  } }
  local client = Web.test_client(app)
  local page = client:get("/hello/%3Cb%3E")
  print(page.body) -- <h1>Hello, &lt;b&gt;</h1>
  assert(page.body == "<h1>Hello, &lt;b&gt;</h1>")
  local login = client:post("/login?next=/orders")
  assert(login.status == 303 and login.redirect_location == "/orders")
  local hostile = client:post("/login?next=//evil.com")
  print(hostile.redirect_location) -- /home
  assert(hostile.redirect_location == "/home" and Web.local_path("/orders") and not Web.local_path("//evil.com"))
  local ok, why = pcall(Web.redirect, "//evil.com")
  print(ok, tostring(why):match("not a local path[^\n]*")) -- false  not a local path or an http(s) URL
  assert(not ok)
end

--- The other response constructors: [`Web.text`], an empty reply, a Reader
--- body, and a problem. The header helpers read in any case and append:
--- [`Web.add_header`] adds a `Set-Cookie` line without dropping the first and
--- merges `Vary` tokens, where [`Web.set_header`] replaces.
function Example.responses()
  local text = Web.text("plain")
  Web.set_header(text, "x-request-id", "abc")
  Web.add_header(text, "Set-Cookie", "a=1")
  Web.add_header(text, "Set-Cookie", "b=2")
  Web.add_header(text, "Vary", "Cookie")
  Web.add_header(text, "vary", "cookie, HX-Request")
  print(Web.header(text, "X-Request-ID"), Web.header(text, "vary")) -- abc  Cookie, HX-Request
  assert(Web.header(text, "X-Request-ID") == "abc" and Web.header(text, "vary") == "Cookie, HX-Request")
  local cookies = assert(text.headers)["Set-Cookie"]
  assert(type(cookies) == "table" and #cookies == 2)
  local empty = Web.empty()
  assert(empty.status == 204 and empty.body == nil)
  local problem = Web.problem(422, "qty must be a number", { field = "qty" })
  print(problem.body) -- {"detail":"qty must be a number","field":"qty","status":422,"title":"Unprocessable Content","type":"about:blank"}
  assert(Web.header(problem, "content-type") == "application/problem+json")
  local streamed = Web.stream(Stream.from_string("lines\n"), "text/plain")
  assert(streamed.status == 200 and streamed.body ~= nil)
  local verbs: {Web.Route} = {
    Web.put("/a", function(_req: Web.Request): Web.Response return empty end),
    Web.patch("/a", function(_req: Web.Request): Web.Response return empty end),
    Web.delete("/a", function(_req: Web.Request): Web.Response return empty end),
    Web.route({ "GET", "POST" }, "/b", function(_req: Web.Request): Web.Response return empty end),
  }
  local router = Web.router(verbs)
  print(router:match("PATCH", "/a").kind, router:match("PUT", "/b").allow) -- match  GET, HEAD, OPTIONS, POST
  assert(router:match("PATCH", "/a").kind == "match")
end

--- Routing picks the most specific route whatever the declaration order,
--- turns a path into its canonical form before any middleware sees it, and
--- answers HEAD from the GET and OPTIONS with `Allow`. [`Web.router`] builds
--- the table without an app, to ask what an app would do.
function Example.routing()
  local function handler(_req: Web.Request): Web.Response
    return Web.text("ok")
  end
  local router = Web.router({
    Web.get("/files/*path", handler, { name = "file" }),
    Web.get("/files/readme", handler),
    Web.get("/files/:name/info", handler),
  })
  print(assert(router:match("GET", "/files/readme").route).pattern) -- /files/readme
  print(assert(router:match("GET", "/files/a/info").route).pattern) -- /files/:name/info
  local rest = router:match("GET", "/files/css/app.css")
  local rest_params = assert(rest.params)
  print(assert(rest.route).pattern, rest_params["path"]) -- /files/*path  css/app.css
  assert(rest_params["path"] == "css/app.css")
  local twice = router:match("GET", "//files//readme")
  print(twice.kind, twice.location) -- redirect  /files/readme
  assert(twice.kind == "redirect" and twice.location == "/files/readme")
  local climb = router:match("GET", "/files/../secret")
  print(climb.kind) -- bad_path
  assert(climb.kind == "bad_path")
  assert(router:reverse("file", { path = "css/a b.css" }) == "/files/css/a%20b.css")
end

--- A mount hands the rest of the path to its own routes, which are named
--- "mount:route"; [`Web.mount_handler`] sends everything below a prefix to one
--- handler and answers `url_for` through a resolver of its own.
function Example.mounts()
  local function show(req: Web.Request): Web.Response
    return Web.text(req.mount_path .. " " .. assert(req.route).pattern)
  end
  local app = Web.app{ routes = {
    Web.get("/", show, { name = "home" }),
    Web.mount("/api", {
      Web.get("/users/:id", show, { name = "user" }),
      Web.mount("/v2", { Web.get("/ping", show, { name = "ping" }) }, { name = "v2" }),
    }, { name = "api" }),
    Web.mount_handler("/static", function(req: Web.Request): Web.Response
      return Web.text("static " .. table.concat(req.segments, "/", 2))
    end, { name = "static", reverse = function(prefix: string, params: {string:string}): string | nil, string
      local path = params["path"]
      if path == nil then return nil, "static: a path is needed" end
      return prefix .. "/" .. path .. "?v=1", ""
    end }),
  } }
  local client = Web.test_client(app)
  print(client:get("/api/users/7"):text()) -- /api /api/users/:id
  print(client:get("/api/v2/ping"):text()) -- /api/v2 /api/v2/ping
  print(client:get("/static/css/app.css"):text()) -- static css/app.css
  assert(client:get("/api/nothing").status == 404)
  local ping, asset = assert(app:url_for("api:v2:ping")), assert(app:url_for("static", { path = "app.css" }))
  print(ping, asset) -- /api/v2/ping  /static/app.css?v=1
  assert(ping == "/api/v2/ping" and asset == "/static/app.css?v=1")
  assert(app:url_for("api:user", { id = "a b" }) == "/api/users/a%20b")
end

--- Middleware is a function from a handler to a handler. The first of the
--- app's list is outermost; a mount's and a route's sit inside it; and the
--- exception layer sits inside all of them, so a 500 travels out through
--- every one. [`Web.access_log`] writes a line to the app's sink.
function Example.middleware()
  local lines: {string} = {}
  local sink: Web.Sink = { line = function(_self: Web.Sink, text: string)
    lines[#lines + 1] = text
  end }
  local function stamped(label: string): Web.Middleware
    return function(inner: Web.Handler): Web.Handler
      return function(req: Web.Request): Web.Response
        local res = inner(req)
        Web.add_header(res, "X-Seen-By", label)
        return res
      end
    end
  end
  local app = Web.app{
    routes = {
      Web.get("/", function(_req: Web.Request): Web.Response return Web.text("home") end,
        { middleware = { stamped("route") } }),
      Web.get("/boom", function(_req: Web.Request): Web.Response error("a bug") end),
    },
    middleware = { Web.access_log(), stamped("app") },
    sink = sink,
  }
  local client = Web.test_client(app)
  local home = client:get("/")
  print(table.concat(home:header_list("x-seen-by"), ", ")) -- route, app
  assert(table.concat(home:header_list("x-seen-by"), ", ") == "route, app")
  local boom = client:get("/boom")
  print(boom.status, boom.headers["x-seen-by"]) -- 500  app
  assert(boom.status == 500 and not boom.body:find("a bug", 1, true))
  print(lines[1]) -- GET / 200 0ms 4B client=127.0.0.1
  assert(assert(lines[1]):find("^GET / 200 %d+ms 4B client=127%.0%.0%.1$"))
  assert(type(Web.stderr_sink("web").line) == "function")
end

--- Typed per-request state: a module exports the [`Web.key`] it owns, a
--- middleware sets it with `req:set` and a handler reads it with
--- `req:get`; two keys of one name never collide.
function Example.keys()
  local USER: Web.Key<string> = Web.key("user")
  local app = Web.app{
    routes = { Web.get("/me", function(req: Web.Request): Web.Response
      return Web.text(req:get(USER) or "nobody")
    end) },
    middleware = { function(inner: Web.Handler): Web.Handler
      return function(req: Web.Request): Web.Response
        local name = req:header("x-user")
        if name ~= nil then req:set(USER, name) end
        return inner(req)
      end
    end },
  }
  local client = Web.test_client(app)
  print(client:get("/me", { headers = { ["X-User"] = "ada" } }):text(), client:get("/me"):text()) -- ada  nobody
  assert(client:get("/me", { headers = { ["X-User"] = "ada" } }):text() == "ada")
end

--- Errors: [`Web.abort`] ends a request with a status from anywhere; the
--- page for a status can be the app's own; a raise is a 500 that tells the
--- client nothing and the sink everything; and `debug = true` shows the
--- fault, which it must never do on a public listener.
function Example.errors()
  local sink: Web.Sink = { line = function(_self: Web.Sink, _text: string) end }
  local function routes(): {Web.Route}
    return {
      Web.get("/teapot", function(_req: Web.Request): Web.Response
        return Web.abort(418, "short and stout")
      end),
      Web.get("/bug", function(_req: Web.Request): Web.Response error("division by zero") end),
    }
  end
  local plain = Web.test_client(Web.app{ routes = routes(), sink = sink })
  print(plain:get("/teapot").status, plain:get("/bug").status, plain:get("/bug").body:find("division", 1, true)) -- 418  500  nil
  assert(plain:get("/bug").body:find("division", 1, true) == nil)
  local branded = Web.test_client(Web.app{ routes = routes(), sink = sink,
    error_pages = { [404] = function(_req: Web.Request): Web.Response
      return Web.html(Html.trust("<p>Lost? Try the <a href=\"/\">home page</a>.</p>"), { status = 404 })
    end } })
  assert(branded:get("/nowhere").body:find("Lost?", 1, true))
  local debugging = Web.test_client(Web.app{ routes = routes(), sink = sink, debug = true })
  print(debugging:get("/bug").body:find("division by zero", 1, true) ~= nil) -- true
  assert(debugging:get("/bug").body:find("division by zero", 1, true))
end

--- The test client keeps a cookie jar across calls, follows redirects when
--- asked, and reads a reply's header lines one by one. [`Web.with_client`]
--- runs the app's lifespan around a test in one event loop.
function Example.client()
  local app = Web.app{
    routes = {
      Web.post("/login", function(_req: Web.Request): Web.Response
        local res = Web.redirect("/account")
        Web.add_header(res, "Set-Cookie", "session=abc123; Path=/; HttpOnly")
        return res
      end),
      Web.get("/account", function(req: Web.Request): Web.Response
        if not (req:header("cookie") or ""):find("session=abc123", 1, true) then
          return Web.abort(401)
        end
        return Web.text("welcome back")
      end),
    },
    lifespan = function(app: Web.App): Web.Shutdown | nil, string
      local opened = true
      app.state["opened"] = opened
      return function() print("closed") end, ""
    end,
  }
  Web.with_client(app, function(client: Web.TestClient)
    assert(client:get("/account").status == 401)
    local login = client:post("/login")
    print(login.status, login:header_list("set-cookie")[1]) -- 303  session=abc123; Path=/; HttpOnly
    local account = client:get("/account", { follow_redirects = true })
    assert(account:text() == "welcome back")
    assert(client:post("/login", { follow_redirects = true }):text() == "welcome back")
  end)
end

return Example
