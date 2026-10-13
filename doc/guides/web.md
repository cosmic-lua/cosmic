# web apps

<!-- policy: profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } -->

[`cosmic.web`] makes an htmx page, a JSON API, or both in one program a
matter of a route table, a few templates and a call to [`Web.serve`]. It
layers on [`cosmic.http.server`] and borrows Starlette's vocabulary:
a request and a response that are plain data, routes, mounts, middleware
as `function(Handler): Handler`, a test client, `StaticFiles`.

This is the first of seven guides. It builds `tasks`, a small task list
whose buttons talk to the server with htmx, from an empty directory: each
file below is written there, and the block at the end of the guide runs the
tests of the finished project, so what you read is what runs. The other
guides each take one subject further, with a small project of their own, and
can be read alone; the map at the end of this one lists them. The guide for
a first project, `cosmic docs doc.guides.project`, covers the verbs this one
uses.

## the files

A web project is an ordinary project ([`cosmic.layout`]) with two
conventions added.

    tasks/
      static/app.css            carried verbatim in the executable
      pages/data.tl             the records the templates are given
      pages/layout.tmpl         templates: pages.layout, pages.row, ...
      store.tl                  the tasks, in memory
      view.tl  site.tl          the pages
      tasks.tl                  the app, with its middleware
      app.tl  dev.tl            the program, and its development loop
      cmd/tasks/main.tl         what `cosmic build` makes into `tasks`
      tasks_test.tl             tests of the pages

Every file under `static/` is a public asset. `cosmic build` carries
them in the executable and [`cosmic.web.static`] serves them; run from
source, the same code serves the directory. A `.tmpl` file is a typed
template, built into a module of the same path.

## templates

The compiler refuses a slot where no escaping is right, and says where and
why. A slot in `hx-on*`, `hx-vars`, `hx-trigger` or a `<script>` is refused
in every template, with or without `{{use htmx}}`; the dialect adds the
rules for URL, selector and JSON attributes. This example checks some of
what is refused, and prints how many of its templates the compiler turned away.

```teal
local Template = require("cosmic.template")

do
  local tally = { refused = 0 }
  local header = "{{type Page from site.page}}{{use htmx}}\n"
  local function reason(markup: string, plain?: boolean): string
    local source, why = Template.compile((plain and "{{type Page from site.page}}\n" or header) .. markup, "page.tmpl")
    assert(source == nil, markup)
    tally.refused = tally.refused + 1
    return why
  end
  -- A link can load anything, so its href takes no slot: the layout is
  -- given a ready made head.
  assert(reason('<link rel="stylesheet" href="{{.css}}">'):find("would make the page load or run it", 1, true))
  -- Script: handlers, filters and code cannot be escaped into safety.
  assert(reason('<a hx-on:click="{{.code}}">x</a>'):find("htmx runs it as JavaScript", 1, true))
  assert(reason('<a hx-trigger="click[{{.filter}}]">x</a>'):find("'[filter]'", 1, true))
  assert(reason('<script>var id = {{.id}};</script>'):find("has no escaper", 1, true))
  -- A selector takes a slot only inside an identifier after # or .
  assert(reason("<a hx-target=\"[data-id='{{.id}}']\">x</a>"):find("inside an identifier", 1, true))
  -- A quoted value is always escaped, so an unquoted one is refused.
  assert(reason('<a href={{.url}}>x</a>'):find("quote the value", 1, true))
  -- JSON that htmx may run takes a Json value, and only under {{use htmx}}.
  assert(reason("<b hx-vals='{{.vals}}'>x</b>", true):find("{{use htmx}}", 1, true))
  local ok = Template.compile(header .. '<a hx-get="/tasks/{{.id}}" hx-target="#task-{{.id}}">x</a>\n', "page.tmpl")
  assert(ok ~= nil)
  print(tally.refused)
end
```

```output
7
```

A template names the record it is given, so a misspelled field is a type
error with the template's own line number. Here the records live in one
module, and `{{type Task from pages.data}}` names one of them.

```teal file=pages/data.tl
local Html = require("cosmic.html")

--- What the templates beside it render.
local record data
  record Task
    id: integer
    title: string
    done: boolean
  end
  record Tasks
    tasks: {Task}
  end
  record Panel
    title: string
    error: string | nil
    rows: Html.SafeHtml
  end
  record Page
    panel: Html.SafeHtml
  end
  record Layout
    title: string
    head: Html.SafeHtml
    csrf: Html.SafeJson
    body: Html.SafeHtml
  end
end

return data
```

One task is a row. `{{use htmx}}` makes the template read htmx's
attributes: `hx-post="/tasks/{{.id}}/toggle"` is a URL with a slot after
literal text, escaped as one path segment, and `hx-target="#task-{{.id}}"`
is a selector, escaped as a CSS identifier. A slot is escaped for the place
it lands, so `{{.title}}` in the text cannot start a tag and `{{.id}}` in a
URL cannot add a `/`.

```teal file=pages/row.tmpl
{{type Task from pages.data}}{{use htmx}}
<li id="task-{{.id}}" class="{{if .done}}done{{end}}">
  <button hx-post="/tasks/{{.id}}/toggle" hx-target="#task-{{.id}}" hx-swap="outerHTML">{{if .done}}undo{{else}}done{{end}}</button>
  <span class="title">{{.title}}</span>
  <button hx-delete="/tasks/{{.id}}" hx-target="#task-{{.id}}" hx-swap="outerHTML">delete</button>
</li>
```

A template can use another as a stage of a slot, by the other's import
path: the list is the row, once per task, or a line saying there are none.

```teal file=pages/rows.tmpl
{{type Tasks from pages.data}}
{{range .tasks}}{{. | pages.row.render}}{{else}}<li>nothing to do</li>{{end}}
```

The panel is the form and the list together, because the server answers
an `add` with the whole panel: the new row appears and the form is empty
again, or shows what was wrong with it. `{{.rows}}` is
markup the program already made safe (an [`Html.SafeHtml`]), taken as it is.

```teal file=pages/panel.tmpl
{{type Panel from pages.data}}{{use htmx}}
<section id="panel">
  <form hx-post="/tasks" hx-target="#panel" hx-swap="outerHTML">
    <input name="title" value="{{.title}}" placeholder="what needs doing?" autofocus>
    <button>add</button>
    {{if .error}}<p class="error">{{.error}}</p>{{end}}
  </form>
  <ul id="tasks">{{.rows}}</ul>
</section>
```

```teal file=pages/index.tmpl
{{type Page from pages.data}}
<h1>tasks</h1>
{{.panel}}
```

The layout is the page around it. `hx-headers` takes an [`Html.SafeJson`]
as its whole value (it carries the CSRF token, which [the security
guide](web-security.md) explains); the head arrives ready made, for a
reason a later section shows.

```teal file=pages/layout.tmpl
{{type Layout from pages.data}}{{use htmx}}
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{.title}}</title>
{{.head}}
</head>
<body hx-headers='{{.csrf}}'>
{{.body}}
</body>
</html>
```

## routes

A route is data: a method, a pattern and a handler, built by [`Web.get`],
[`Web.post`], [`Web.delete`] and the other method constructors. A pattern
is literal segments, `:name` for one segment and `*name` for the rest.
The most specific route wins whatever the order, a path is made canonical
before any middleware sees it, a HEAD is answered by the GET, and a wrong
method is a 405 with `Allow`. `name` is how a route is found again:
`app:url_for("toggle", { id = 3 })` and `req:url_for(...)` build the URL,
escaping a parameter as a template does. A [`Web.mount`] puts routes under
a prefix and, if it is named, prefixes theirs (`api:show`).

A handler takes a [`Web.Request`] and answers a [`Web.Response`], the
server's own reply record. The constructors are [`Web.html`] (which takes
only [`Html.SafeHtml`], never a string), [`Web.json`], [`Web.text`],
[`Web.redirect`], [`Web.empty`], [`Web.stream`] and [`Web.problem`];
[`Web.abort`] ends the request from anywhere with a status, and a handler
that raises any other error is answered 500 with nothing of the fault
shown (`debug = true` shows it, in development only). A response is a
table, so [`Web.add_header`] appends a header line, as for a second
`Set-Cookie`.

The store holds the tasks. One process serves every request on one
thread, so a plain table is consistent.

```teal file=store.tl
--- The tasks, in memory: one per process, which is all a cooperative
--- server needs to keep them consistent.

local data = require("pages.data")

local record Store
  --- Tasks in the order they were added.
  tasks: {data.Task}
  --- The id the next task takes.
  next_id: integer
  --- Adds a task and answers it.
  add: function(self: Store, title: string): data.Task
  --- The task with `id`, or nil.
  get: function(self: Store, id: integer): data.Task | nil
  --- Flips a task's `done`; the task, or nil.
  toggle: function(self: Store, id: integer): data.Task | nil
  --- Removes a task; whether there was one.
  remove: function(self: Store, id: integer): boolean
end

local store_mt: metatable<Store> = { __index = Store }

--- A store with no tasks.
function Store.new(): Store
  return setmetatable({ tasks = {}, next_id = 1 }, store_mt)
end

function Store:add(title: string): data.Task
  local task: data.Task = { id = self.next_id, title = title, done = false }
  self.next_id = self.next_id + 1
  self.tasks[#self.tasks + 1] = task
  return task
end

function Store:get(id: integer): data.Task | nil
  for _, task in ipairs(self.tasks) do
    if task.id == id then return task end
  end
  return nil
end

function Store:toggle(id: integer): data.Task | nil
  local task = self:get(id)
  if task ~= nil then task.done = not task.done end
  return task
end

function Store:remove(id: integer): boolean
  for at, task in ipairs(self.tasks) do
    if task.id == id then
      table.remove(self.tasks, at)
      return true
    end
  end
  return false
end

return Store
```

The pages' routes follow. `home` answers a whole page or a fragment;
`create`, `toggle` and `remove` answer what a button asked for. `create`
reads the form with [`Input.form`], which answers a body it cannot decode
with a status to pass on; [the forms guide](web-forms.md) shows routes that
name the shape of their input and have it checked before the handler runs.

```teal file=site.tl
--- The pages: the list, the form, and what a button does to a task.

local Html = require("cosmic.html")
local Input = require("cosmic.web.input")
local Store = require("store")
local Url = require("cosmic.url")
local View = require("view")
local Web = require("cosmic.web")
local index = require("pages.index")
local panel = require("pages.panel")
local row = require("pages.row")
local rows = require("pages.rows")

local record Site
end

--- Routes over `store`.
function Site.routes(store: Store): {Web.Route}
  local function shown(title: string, problem?: string): Html.SafeHtml
    return panel.render({ title = title, error = problem, rows = rows.render({ tasks = store.tasks }) })
  end

  local function home(req: Web.Request): Web.Response
    return View.page(req, "tasks", index.render({ panel = shown("") }))
  end

  local function create(req: Web.Request): Web.Response
    local read = Input.form(req)
    if read.invalid ~= nil then return Web.abort(read.invalid.status, read.invalid.message) end
    local title = (Url.query_last(assert(read.value), "title") or ""):match("^%s*(.-)%s*$")
    if title == "" then
      return Web.html(shown("", "give the task a name"), { status = 422 })
    end
    store:add(title)
    return Web.html(shown(""), { status = 201 })
  end

  --- The task a request's `:id` names, or nil.
  local function named(req: Web.Request): integer | nil
    return math.tointeger(tonumber(req.params.id))
  end

  local function toggle(req: Web.Request): Web.Response
    local id = named(req)
    local task = id ~= nil and store:toggle(id) or nil
    if task == nil then return Web.abort(404, "no such task") end
    return Web.html(row.render(task))
  end

  local function remove(req: Web.Request): Web.Response
    local id = named(req)
    if id == nil or not store:remove(id) then return Web.abort(404, "no such task") end
    return Web.html(Html.trust(""))
  end

  return {
    Web.get("/", home, { name = "home" }),
    Web.post("/tasks", create, { name = "create" }),
    Web.post("/tasks/:id/toggle", toggle, { name = "toggle" }),
    Web.delete("/tasks/:id", remove, { name = "remove" }),
  }
end

return Site
```

The helpers around a request and a response, in a small app of their own:

```teal
do
  local Web = require("cosmic.web")
  local REQUEST_ID: Web.Key<string> = Web.key("request-id")
  local function tagged(inner: Web.Handler): Web.Handler
    return function(req: Web.Request): Web.Response
      req:set(REQUEST_ID, "r-1")
      local res = inner(req)
      Web.add_header(res, "X-Request-Id", req:get(REQUEST_ID) or "")
      return res
    end
  end
  local app = Web.app{
    routes = {
      Web.get("/hello/:name", function(req: Web.Request): Web.Response
        if req:accepts({ "text/html", "application/json" }) == "application/json" then
          return Web.json({ hello = req.params.name })
        end
        local query = req:query()
        local loud = query ~= nil and #query.pairs > 0
        return Web.text("hello " .. req.params.name .. (loud and "!" or ""))
      end, { name = "hello" }),
      Web.post("/jump", function(req: Web.Request): Web.Response
        return Web.redirect(Web.safe_next(req:header("referer"), "/"))
      end),
    },
    middleware = { tagged },
  }
  local client = Web.test_client(app)
  assert(client:get("/hello/ada"):text() == "hello ada")
  assert(client:get("/hello/ada?loud=1"):text() == "hello ada!")
  local reply = client:get("/hello/ada", { headers = { Accept = "application/json" } })
  assert(reply:text() == '{"hello":"ada"}' and reply.headers["x-request-id"] == "r-1")
  assert(app:url_for("hello", { name = "a b" }, { x = "1" }) == "/hello/a%20b?x=1")
  assert(client:get("/nowhere").status == 404)
  local wrong = client:delete("/hello/ada")
  assert(wrong.status == 405 and wrong.headers["allow"] == "GET, HEAD, OPTIONS")
  assert(client:head("/hello/ada").body == "")
  -- A redirect goes to a local path or a web URL; a target from the client
  -- (a referer, a ?next=) is taken only if it is a local path.
  local jumped = client:post("/jump", { headers = { Referer = "https://evil.example/" } })
  assert(jumped.status == 303 and jumped.redirect_location == "/")
  assert(not pcall(Web.redirect, "javascript:alert(1)"))
end
```

[`Web.key`] makes a typed key for per-request state: `req:set(KEY, v)` and
`req:get(KEY)`. A module exports the keys it owns, as the session, CSRF and
CSP modules do. `req.state` is an untyped table for scratch values only.

## htmx

[`cosmic.web.htmx`] is the server's half of htmx. [`Htmx.request`] reads
the `HX-*` headers a request carries and [`Htmx.partial`] says whether it
wants a fragment. They are client-controlled: use them to choose what to
show, never to decide what is allowed. [`Htmx.page`] answers a fragment
request with the fragment and any other with the whole page, and marks both
`Vary` on the headers that chose, so a cache keeps them apart. Here is the
page around a fragment, with the head every page needs:

```teal file=view.tl
--- The page around a fragment: the layout, with the head every page needs.

local Csrf = require("cosmic.web.csrf")
local Headers = require("cosmic.web.headers")
local Html = require("cosmic.html")
local Htmx = require("cosmic.web.htmx")
local Web = require("cosmic.web")
local layout = require("pages.layout")

local record View
end

--- The tags every page's head holds: the stylesheet and htmx.
local function head(req: Web.Request): Html.SafeHtml
  local css = assert(req:url_for("static", { path = "app.css" }))
  local link = '<link rel="stylesheet" href="' .. Html.raw_attr(Html.escape_attr(css)) .. '">'
  return Html.concat({
    Html.trust(link),
    Htmx.head{ nonce = req:get(Headers.NONCE) },
  })
end

--- Answers `req` with `content` alone for an htmx request, else with the
--- whole page.
function View.page(req: Web.Request, title: string, content: Html.SafeHtml): Web.Response
  return Htmx.page(req, content, function(body: Html.SafeHtml): Html.SafeHtml
    return layout.render({ title = title, head = head(req), csrf = Csrf.hx_headers(req), body = body })
  end)
end

return View
```

[`Htmx.head`] writes the `<meta name="htmx-config">` tag and the script
tags for the htmx the binary carries (and for its SSE extension, with
`sse = true`, which [the live guide](web-live.md) uses), each with a
subresource integrity value computed from the bytes served. The
configuration is closed: no `eval`, no script in swapped HTML, no injected
style, same-origin requests only, and a 422 is swapped in so a form's errors
reach the page while other 4xx and 5xx responses are not. The files
themselves are served under `/_web/` by every [`Web.app`], ahead of the
routes, at paths that carry the version, so no route may live there. The
head is Teal because `<link href>` and `<script src>` take no slot in a
template.

An answer says what htmx should do with it in headers. [`Htmx.apply`] writes
them, and refuses a redirect to another origin since htmx navigates by
script. After a form post, [`Htmx.redirect_to`] answers an htmx request with
`HX-Redirect` and any other with an ordinary redirect. [`Htmx.stop_polling`]
answers 286, which ends an `every 2s` poll.

```teal continue
do
  local Html = require("cosmic.html")
  local Htmx = require("cosmic.web.htmx")
  local Web = require("cosmic.web")
  local res = Web.html(Html.trust("<p>saved</p>"))
  assert(Htmx.apply(res, { push_url = "/tasks/7", trigger = { { name = "saved", detail = { id = 7 } } } }))
  assert(Web.header(res, "HX-Push-Url") == "/tasks/7")
  assert(Web.header(res, "HX-Trigger") == '{"saved":{"id":7}}')
  local refused, why = Htmx.apply(Web.empty(200), { redirect = "https://evil.example/" })
  assert(refused == nil and why:find("same-origin", 1, true))
  local app = Web.app{ routes = { Web.post("/login", function(req: Web.Request): Web.Response
    return (assert(Htmx.redirect_to(req, "/")))
  end) } }
  local client = Web.test_client(app)
  local fetched = client:post("/login", { headers = { ["HX-Request"] = "true" } })
  assert(fetched.status == 200 and fetched.headers["hx-redirect"] == "/")
  assert(client:post("/login").status == 303)
  assert(client:get(Htmx.path()).status == 200, "htmx is served from the binary")
  assert(Htmx.integrity():find("^sha384%-"))
end
```

## static files

The project's stylesheet is a plain file under `static/`.

```teal file=static/app.css
body { font-family: system-ui, sans-serif; max-width: 32rem; margin: 2rem auto; }
li.done .title { text-decoration: line-through; }
.error { color: #b00020; }
```

[`StaticFiles.mount`] serves the project's `static/` under a prefix and
names itself `static`; [`Dev.static`] is the same route that reads the
directory from disk, uncached, while the app is in development. A page asks
for a file by `app:url_for("static", { path = "app.css" })`, which gives the
fingerprinted name `view.tl` links; [the deployment guide](web-deploy.md)
explains the fingerprint and what a deployed program serves.

## the app

[`Dev.app`] is [`Web.app`] with a development mode: in production it is the
plain app. The pieces of the middleware list are stacked in order, the
first outermost: the log, then the security headers (so errors get them
too), the session and the CSRF check. The exception layer sits inside, so a
500 passes out through all of it. Each piece has a guide of its own: the
[sessions](web-sessions.md) and [security](web-security.md) guides explain
what they do, and this app uses them as they come.

```teal file=tasks.tl
--- The tasks app: the pages and the middleware they share.

local Assets = require("cosmic.web.assets")
local Csrf = require("cosmic.web.csrf")
local Dev = require("cosmic.web.dev")
local Headers = require("cosmic.web.headers")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local Site = require("site")
local StaticFiles = require("cosmic.web.static")
local Store = require("store")
local Web = require("cosmic.web")

local record Tasks
  --- What [`Tasks.app`] takes.
  record Options
    --- Signing keys for the session cookie, newest first.
    keys: {string}
    --- Where `/static` comes from; nil for the project's `static/`
    --- (the executable's, or the directory in development).
    assets?: Assets.Source
  end
end

--- The app. In development mode (`COSMIC_WEB_DEV=1`) it reloads pages.
function Tasks.app(opts: Tasks.Options): Web.App
  local csp = Headers.Csp.htmx_default()
  csp.directives["script-src"] = { "'self'", "{nonce}" }

  local routes = Site.routes(Store.new())
  if opts.assets ~= nil then
    routes[#routes + 1] = StaticFiles.mount("/static", { source = opts.assets })
  else
    routes[#routes + 1] = Dev.static("/static")
  end

  return Dev.app{
    routes = routes,
    middleware = {
      Web.access_log(),
      Headers.middleware{ csp = csp, nonce = true },
      Session.middleware{ store = SessionCookie.store{ keys = opts.keys } },
      Csrf.middleware(),
    },
  }
end

return Tasks
```

The program reads its secrets from the environment and serves on the
loopback. [`Web.serve`] runs the lifespan, listens and, on SIGINT or SIGTERM,
stops gracefully: open requests have `grace_ns` (10 seconds) to finish.

```teal file=app.tl
--- The program: serves the app on the loopback. `cosmic app.tl` runs it.

local Log = require("cosmic.log")
local Net = require("cosmic.net")
local Secret = require("cosmic.web.secret")
local Tasks = require("tasks")
local Web = require("cosmic.web")

local log = Log.new("tasks")

return function(): integer
  local keys, why = Secret.keys_from_env("TASKS_KEYS")
  if keys == nil then
    log:complain(why)
    return 2
  end
  local app = Tasks.app{
    keys = keys,
  }
  local ok, trouble = Web.serve(app, { listeners = { Net.tcp("127.0.0.1", 8080) } })
  if not ok then
    log:complain(trouble)
    return 1
  end
  return 0
end
```

`cosmic build` makes a program of `cmd/tasks/main.tl`, which only reruns
`app.tl`:

```teal file=cmd/tasks/main.tl
local app = require("app")

return app
```

## the development loop

`dev.tl` is a supervisor, [`Dev.supervise`]. It runs `cosmic app.tl`, looks at the files every
300 ms and replaces the process, SIGTERM first, when one changed. A
template compiles into a module, so a restart is what an edit to one
needs.

```teal file=dev.tl
--- The development loop: restarts `app.tl` when a file changed.

local Dev = require("cosmic.web.dev")
local Log = require("cosmic.log")

local log = Log.new("tasks")

return function(): integer
  local ok, why = Dev.supervise{}
  if not ok then
    log:complain(why)
    return 1
  end
  return 0
end
```

Run it with `TASKS_KEYS=$(cosmic -e 'print(require("cosmic.web.secret").generate())') cosmic dev.tl`.
Because the supervisor sets `COSMIC_WEB_DEV=1` the app, built by
[`Dev.app`], is in development mode: it shows a fault's stack, serves
`static/` from disk with `Cache-Control: no-store`, adds a script to every
page that reloads the browser when the process is replaced and swaps the
stylesheets when only a `.css` file changed, and carries the page's CSP
nonce on that script's tag. An app that shows source paths to whoever asks
serves the loopback only: [`Web.serve`] refuses a development app a listener
elsewhere and a `trusted_proxy`, and the app answers only `localhost`,
`127.0.0.1` and `[::1]` unless `trusted_hosts` names others, so a page on
another site cannot reach it by a name that resolves to the loopback.

## testing

[`Web.test_client`] calls the app in-process: no socket, a cookie jar that
works like a browser's, and the same checks of a reply the server would
make. `post` takes `form`, `json`, `body` and `content_type`, `headers`,
`query` and `follow_redirects`. [`Web.with_client`] runs a test with the
lifespan around it and an event loop, which a stream needs (`stream = true`
leaves the body unread in `reply.stream`); [`Web.with_server`] serves the
app on the loopback for what only a socket shows, such as the server's
body limit.

A test of the app does not read `static/`: a program that has a `cmd/`
main takes `/static` from the executable's embedded files, which a test
does not have, so `Tasks.app` takes the files as `assets` and the test gives
it [`Assets.memory`]. [`Assets.directory`] reads a directory and
[`Assets.embedded`] the executable's own.

The tests of the finished app go through a page for its tokens as a
browser does, and check the 422 and the refusal of a post without a token:

```teal file=tasks_test.tl
local Assets = require("cosmic.web.assets")
local Secret = require("cosmic.web.secret")
local Tasks = require("tasks")
local Web = require("cosmic.web")

local function app(): Web.App
  return Tasks.app{
    keys = { Secret.generate() },
    assets = Assets.memory({ ["app.css"] = "body { margin: 0 }" }),
  }
end

--- The CSRF token a page carries in its `hx-headers`.
local function csrf_of(client: Web.TestClient): string
  local page = client:get("/")
  return assert(page.body:match("X%-CSRF%-Token&quot;:&quot;([%w_-]+)&quot;"))
end

local function htmx(token: string): {string:string}
  return { ["HX-Request"] = "true", ["X-CSRF-Token"] = token }
end

local function test_page_and_fragment()
  local client = Web.test_client(app())
  local page = client:get("/")
  assert(page.status == 200 and page.body:find("<h1>tasks</h1>", 1, true))
  assert(page.body:find("/_web/htmx-", 1, true), "the page loads htmx")
  assert(page.body:find("&#47;static&#47;app&#46;%x+&#46;css"), "and the stylesheet by its fingerprint")
  local fragment = client:get("/", { headers = { ["HX-Request"] = "true" } })
  assert(fragment.status == 200 and not fragment.body:find("<html", 1, true))
end

local function test_adding_a_task()
  local client = Web.test_client(app())
  local token = csrf_of(client)
  local added = client:post("/tasks", { form = { title = "write the guide" }, headers = htmx(token) })
  assert(added.status == 201 and added.body:find("write the guide", 1, true))
  assert(client:get("/").body:find("write the guide", 1, true))
  local done = client:post("/tasks/1/toggle", { headers = htmx(token) })
  assert(done.status == 200 and done.body:find('class="done"', 1, true))
  local gone = client:delete("/tasks/1", { headers = htmx(token) })
  assert(gone.status == 200 and gone.body == "")
  assert(client:delete("/tasks/1", { headers = htmx(token) }).status == 404)
end

local function test_a_blank_title_is_refused_with_its_message()
  local client = Web.test_client(app())
  local refused = client:post("/tasks", { form = { title = "  " }, headers = htmx(csrf_of(client)) })
  assert(refused.status == 422 and refused.body:find("give the task a name", 1, true))
end

local function test_a_post_without_the_token_is_refused()
  local client = Web.test_client(app())
  csrf_of(client)
  assert(client:post("/tasks", { form = { title = "x" } }).status == 403)
  local stranger = Web.test_client(app()):post("/tasks", { form = { title = "x" },
    headers = { ["X-CSRF-Token"] = "forged" } })
  assert(stranger.status == 403)
end
```

`cosmic test` builds the tree, which type-checks every module and compiles
every template, then runs each `*_test.tl`. The next block runs it on the
files of this guide through [`cosmic.child`], as the guide for the command
line does. Run `cosmic fix` as well in a project of your own: it checks and
formats every file.

```teal continue
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")
local Clock = require("cosmic.clock")

local relaunch = assert(Proc.relaunch())
local env = Env.all()
for name, value in pairs(relaunch.env) do env[name] = value end
env["COSMIC_TEST_SANDBOX"] = "0"
local argv = { table.unpack(relaunch.argv) }
argv[#argv + 1] = "test"
local said = assert(Child.run(argv,
  { env = env, fds = relaunch.fds, cwd = tmp, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(120) }))
print(((said.stderr or "") .. (said.stdout or "")):match("test: %d+ tests? passed"))
```

```output
test: 4 tests passed
```

## where next

Each guide below builds a small project of its own and can be read alone.

- [Forms and uploads](web-forms.md): typed routes, how input is checked
  and refused (400, 413, 415, 422), re-rendering a form with its errors,
  multipart uploads and their limits.
- [Sessions](web-sessions.md): the cookie and SQLite stores, secrets from
  the environment, flash messages, login and `regenerate`.
- [Security](web-security.md): CSRF with and without htmx, the security
  headers and the CSP nonce, `trusted_proxy` and `trusted_hosts`, and the
  defaults to leave alone.
- [Live updates](web-live.md): server-sent events, hubs, reconnection with
  `Last-Event-ID` and htmx's SSE extension.
- [A JSON API](web-api.md): JSON in and out, problem responses, bearer
  tokens and CORS.
- [Deploying](web-deploy.md): `cosmic build`, `static/` and fingerprints,
  body limits, running behind a proxy and what [`Web.serve`] takes.

[`Assets.directory`]: ../../cosmic/web/assets.tl
[`Assets.embedded`]: ../../cosmic/web/assets.tl
[`Assets.memory`]: ../../cosmic/web/assets.tl
[`cosmic.child`]: ../../cosmic/child.tl
[`cosmic.http.server`]: ../../cosmic/http/server.tl
[`cosmic.layout`]: ../../cosmic/layout.tl
[`cosmic.web.htmx`]: ../../cosmic/web/htmx.tl
[`cosmic.web.static`]: ../../cosmic/web/static.tl
[`cosmic.web`]: ../../cosmic/web/init.tl
[`Dev.app`]: ../../cosmic/web/dev.tl
[`Dev.static`]: ../../cosmic/web/dev.tl
[`Dev.supervise`]: ../../cosmic/web/dev.tl
[`Html.SafeHtml`]: ../../cosmic/html.tl
[`Html.SafeJson`]: ../../cosmic/html.tl
[`Htmx.apply`]: ../../cosmic/web/htmx.tl
[`Htmx.head`]: ../../cosmic/web/htmx.tl
[`Htmx.page`]: ../../cosmic/web/htmx.tl
[`Htmx.partial`]: ../../cosmic/web/htmx.tl
[`Htmx.redirect_to`]: ../../cosmic/web/htmx.tl
[`Htmx.request`]: ../../cosmic/web/htmx.tl
[`Htmx.stop_polling`]: ../../cosmic/web/htmx.tl
[`Input.form`]: ../../cosmic/web/input.tl
[`StaticFiles.mount`]: ../../cosmic/web/static.tl
[`Web.abort`]: ../../cosmic/web/init.tl
[`Web.add_header`]: ../../cosmic/web/init.tl
[`Web.app`]: ../../cosmic/web/init.tl
[`Web.delete`]: ../../cosmic/web/init.tl
[`Web.empty`]: ../../cosmic/web/init.tl
[`Web.get`]: ../../cosmic/web/init.tl
[`Web.html`]: ../../cosmic/web/init.tl
[`Web.json`]: ../../cosmic/web/init.tl
[`Web.key`]: ../../cosmic/web/init.tl
[`Web.mount`]: ../../cosmic/web/init.tl
[`Web.post`]: ../../cosmic/web/init.tl
[`Web.problem`]: ../../cosmic/web/init.tl
[`Web.redirect`]: ../../cosmic/web/init.tl
[`Web.Request`]: ../../cosmic/web/init.tl
[`Web.Response`]: ../../cosmic/web/init.tl
[`Web.serve`]: ../../cosmic/web/init.tl
[`Web.stream`]: ../../cosmic/web/init.tl
[`Web.test_client`]: ../../cosmic/web/init.tl
[`Web.text`]: ../../cosmic/web/init.tl
[`Web.with_client`]: ../../cosmic/web/init.tl
[`Web.with_server`]: ../../cosmic/web/init.tl
