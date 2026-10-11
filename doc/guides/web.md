# web apps

<!-- policy: loopback = { "127.0.0.1" }, profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } -->

[`cosmic.web`] makes an htmx page, a JSON API, or both in one program a
matter of a route table, a few templates and a call to [`Web.serve`]. It
layers on [`cosmic.http.server`] and borrows Starlette's vocabulary:
a request and a response that are plain data, routes, mounts, middleware
as `function(Handler): Handler`, a test client, `StaticFiles`.

This guide builds `tasks`, a small task list: a page whose buttons talk
to the server with htmx, a form that checks its input, a live list that
every open page shares, and a JSON API under `/api`. It starts from an
empty directory. Each file below is written there, and the last section
runs the tests of the finished project, so what you read is what runs.
The guide for a first project, `cosmic docs doc.guides.project`, covers
the verbs this one uses.

## the files

A web project is an ordinary project ([`cosmic.layout`]) with two
conventions added.

    tasks/
      static/app.css            carried verbatim in the executable
      pages/data.tl             the records the templates are given
      pages/layout.tmpl         templates: pages.layout, pages.row, ...
      store.tl                  the tasks, in memory
      view.tl  site.tl          the pages
      live.tl                   the event stream
      tasks.tl                  the app, with its middleware
      app.tl  dev.tl            the program, and its development loop
      cmd/tasks/main.tl         what `cosmic build` makes into `tasks`
      tasks_test.tl             tests of the pages and the live list

Every file under `static/` is a public asset. `cosmic build` carries
them in the executable and [`cosmic.web.static`] serves them; run from
source, the same code serves the directory. A `.tmpl` file is a typed
template, built into a module of the same path.

The JSON API, the tests of forms and uploads and the tests of the session
stores are small projects of their own, in the sections after the app.

## templates

The compiler refuses a slot where no escaping is right, and says where and
why. A slot in `hx-on*`, `hx-vars`, `hx-trigger` or a `<script>` is refused
in every template, with or without `{{use htmx}}`; the dialect adds the
rules for URL, selector and JSON attributes. This example checks some of
what is refused, and prints how many of its templates the compiler turned away.

```teal
local Template = require("cosmic.template")

do
  local refused = 0
  local header = "{{type Page from site.page}}{{use htmx}}\n"
  local function reason(markup: string, plain?: boolean): string
    local source, why = Template.compile((plain and "{{type Page from site.page}}\n" or header) .. markup, "page.tmpl")
    assert(source == nil, markup)
    refused = refused + 1
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
  print(refused)
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
  record Form
    title: string
    error: string | nil
  end
  record Page
    notes: {string}
    name: string
    field: Html.SafeHtml
    rows: Html.SafeHtml
    form: Html.SafeHtml
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

The form is its own template, because the server answers a refusal with
the form alone.

```teal file=pages/form.tmpl
{{type Form from pages.data}}{{use htmx}}
<form id="new" hx-post="/tasks" hx-target="#new" hx-swap="outerHTML">
  <input name="title" value="{{.title}}" placeholder="what needs doing?" autofocus>
  <button>add</button>
  {{if .error}}<p class="error">{{.error}}</p>{{end}}
</form>
```

The page puts the pieces together. `{{.field}}` and `{{.rows}}` are
`Html.SafeHtml`: markup the program already made safe, taken as it is.
The list opens a stream with `sse-connect` and swaps in whatever the
server sends under the event name `tasks`.

```teal file=pages/index.tmpl
{{type Page from pages.data}}{{use htmx}}
{{range .notes}}<p class="note">{{.}}</p>{{end}}
<h1>tasks</h1>
<form method="post" action="/hello">
  {{.field}}
  <input name="name" value="{{.name}}" placeholder="your name">
  <button>say hello</button>
</form>
<ul id="tasks" hx-ext="sse" sse-connect="/events" sse-swap="tasks">{{.rows}}</ul>
{{.form}}
```

The layout is the page around it. `hx-headers` takes an [`Html.SafeJson`]
as its whole value; the head arrives ready made, for a reason the next
example shows.

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

The pages' routes follow. `home` answers a whole page or a fragment,
`create`, `toggle` and `remove` answer what a button asked for and tell
every open page. Their parameters are the checked records that the section on forms
below explains.

```teal file=site.tl
--- The pages: the list, the form, and what a button does to a task.

local Csrf = require("cosmic.web.csrf")
local Html = require("cosmic.html")
local Input = require("cosmic.web.input")
local Session = require("cosmic.web.session")
local Shape = require("cosmic.shape")
local Sse = require("cosmic.web.sse")
local Store = require("store")
local Url = require("cosmic.url")
local View = require("view")
local Web = require("cosmic.web")
local form = require("pages.form")
local index = require("pages.index")
local row = require("pages.row")
local rows = require("pages.rows")

local record Site
end

local record NewTask
  title: string
end
local NEW <const> = Shape.record_of("NewTask")

local record TaskPath
  id: integer
end
local TASK <const> = Shape.record_of("TaskPath")

--- Routes over `store`; a change is published on `hub` for every open page.
function Site.routes(store: Store, hub: Sse.Hub): {Web.Route}
  local function publish()
    hub:publish("tasks", Sse.Event.html("tasks", rows.render({ tasks = store.tasks })))
  end

  local function home(req: Web.Request): Web.Response
    local session = Session.of(req)
    local notes: {string} = {}
    for _, note in ipairs(session:take_flashes()) do notes[#notes + 1] = note.text end
    local body = index.render({
      notes = notes,
      name = session:get_string("name") or "",
      field = Csrf.field(req),
      rows = rows.render({ tasks = store.tasks }),
      form = form.render({ title = "" }),
    })
    return View.page(req, "tasks", body)
  end

  local function hello(req: Web.Request): Web.Response
    local read = Input.form(req)
    if read.invalid ~= nil then return Web.abort(read.invalid.status, read.invalid.message) end
    local name = Url.query_last(read.value, "name") or ""
    local session = Session.of(req)
    session:set("name", name)
    session:flash("success", "hello, " .. name)
    return Web.redirect((assert(req:url_for("home"))))
  end

  local function refuse(_req: Web.Request, bad: Web.Invalid): Web.Response
    local shown = form.render({ title = Input.value(bad, "title"), error = Input.errors_by_field(bad).title })
    return Web.html(shown, { status = bad.status })
  end

  local function create(req: Web.Request, _p: Web.None, _q: Web.None, b: NewTask): Web.Response
    local title = b.title:match("^%s*(.-)%s*$")
    if title == "" then
      return refuse(req, Input.fail(req, "title", "give the task a name"))
    end
    store:add(title)
    publish()
    return Web.html(form.render({ title = "" }), { status = 201 })
  end

  local function toggle(_req: Web.Request, p: TaskPath, _q: Web.None, _b: Web.None): Web.Response
    local task = store:toggle(p.id)
    if task == nil then return Web.abort(404, "no such task") end
    publish()
    return Web.html(row.render(task))
  end

  local function remove(_req: Web.Request, p: TaskPath, _q: Web.None, _b: Web.None): Web.Response
    if not store:remove(p.id) then return Web.abort(404, "no such task") end
    publish()
    return Web.html(Html.trust(""))
  end

  return {
    Web.get("/", home, { name = "home" }),
    Web.post("/hello", hello, { name = "hello" }),
    Web.post_typed("/tasks", Web.input(Web.NONE, Web.NONE, Web.form_body(NEW)), create,
      { name = "create", on_invalid = refuse }),
    Web.post_typed("/tasks/:id/toggle", Web.input(TASK, Web.NONE, Web.no_body), toggle,
      { name = "toggle" }),
    Web.delete_typed("/tasks/:id", Web.input(TASK, Web.NONE, Web.no_body), remove,
      { name = "remove" }),
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
CSP modules below do. `req.state` is an untyped table for scratch values
only.

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
    Htmx.head{ sse = true, nonce = req:get(Headers.NONCE) },
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
`sse = true`), each with a subresource integrity value computed from the
bytes served. The configuration is closed: no `eval`, no script in swapped
HTML, no injected style, same-origin requests only, and a 422 is swapped in
so a form's errors reach the page while other 4xx and 5xx responses are not.
The files themselves are served under `/_web/` by every [`Web.app`], ahead
of the routes, at paths that carry the version, so no route may live there.
The head is Teal because `<link href>` and `<script src>` take no slot in
a template.

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
directory from disk, uncached, while the app is in development. A file is
answered with a strong ETag from its content hash, `If-None-Match`,
`Range` and a stored gzip variant. A request for a hidden file or a path
that climbs out of the root is a 404.

`app:url_for("static", { path = "app.css" })` is the fingerprinted name,
`/static/app.b481c67fb0.css`: ten hex digits of the content hash are part
of the name, so a changed file has a new URL and an old one may be cached for a
year. A page links the fingerprinted name (`view.tl` above does) and a
plain name still works with revalidation. A stale fingerprint is a 404,
never a different file's bytes.

## csrf

A cookie is sent by the browser whoever made the page, so a form on
another site could post to yours. [`Csrf.middleware`] answers that on every
request whose method changes state. It checks that the `Origin` (or the
`Referer`'s origin) is the app's own, and that a masked synchronizer token
kept in the session (see the section on sessions below) came back in the `X-CSRF-Token` header or the
`csrf_token` field of the form. GET and TRACE are never checked, so a GET
must not change anything. It sits inside the session middleware.

A page carries the token two ways. `Csrf.hx_headers(req)` is a JSON value
for `<body hx-headers='...'>`: every htmx request below the element sends
the header, so no form needs to remember it (`layout.tmpl` above does this).
[`Csrf.field`] is the hidden input of a plain form, for `hello` in
`index.tmpl`, and [`Csrf.meta`] a `<meta>` tag for a script that sets the
header itself. A urlencoded form's token must lie in the first 16 KiB of
the body, and a multipart form's must be its first part: put the field
first. `session:regenerate()` drops the secret, so tokens seen before a
login stop working; a boosted login should end with `HX-Redirect`, which
loads a fresh page.

The `HX-Request` header exempts nothing. A request with `Authorization:
Bearer` skips the token layer by default, since a cross-site page cannot
set that header without a preflight; the better answer for an API is that
no cookie authenticates it, which the section on the API below shows.

## security headers

[`Headers.middleware`] sets, on every response that passes out through
it: `X-Content-Type-Options: nosniff`, `Referrer-Policy`,
`X-Frame-Options: DENY`, `Cross-Origin-Opener-Policy` and a
`Permissions-Policy` that turns the camera, the microphone and
geolocation off. A header the handler already set stays. `hsts` is
sent on https requests only (behind a proxy, `trusted_proxy` decides
that), and a CSP is off until asked for.

`Headers.Csp.htmx_default()` is a policy that lets an htmx app load its
own scripts, styles, images and connections and nothing else. With
`nonce = true` each request draws a nonce, `req:get(Headers.NONCE)` reads
it, and a `{nonce}` source in a directive becomes `'nonce-<value>'`. The
nonce is for an inline script the layout carries; pass it to [`Htmx.head`]
too, as `view.tl` does, so htmx's tags and its own inline use carry it. A
page with a nonce is not for a shared cache, and the response is marked
private. Try a new policy with `csp_report_only = true` first.

## live updates

[`cosmic.web.sse`] streams server-sent events. A `Hub` fans events out to
the streams of many pages by topic and keeps a short replay ring, so a
browser that reconnects with `Last-Event-ID` resumes where it left off, and
one whose last id is not in the ring gets a `reset` event, on which
the page fetches its state anew. `publish` never waits, and a slow client costs only its own queue.
The app is given the hub in `hubs`, which closes its streams when the
server stops; the stream also sends a heartbeat so a client that left is
found. [`Sse.Event.html`] makes an event whose data is markup, which is what
the list's `sse-swap="tasks"` swaps in.

```teal file=live.tl
--- The event stream every open page listens to.

local Sse = require("cosmic.web.sse")
local Web = require("cosmic.web")

local record Live
end

--- A route streaming `hub`'s "tasks" topic. A browser that reconnects
--- sends `Last-Event-ID`, and the stream resumes after it.
function Live.routes(hub: Sse.Hub): {Web.Route}
  return {
    Web.get("/events", function(req: Web.Request): Web.Response
      local sub, why = hub:subscribe({ "tasks" }, { after = Sse.last_event_id(req) })
      if sub == nil then
        return Web.text(why, { status = 503, headers = { ["Retry-After"] = "5" } })
      end
      return Sse.EventStream(req, sub)
    end, { name = "events" }),
  }
end

return Live
```

## the app

[`Dev.app`] is [`Web.app`] with a development mode: in production it is the
plain app. The pieces of the middleware list are stacked in order, the
first outermost: the log, then the headers (so errors get them too), the
session and the CSRF check. The exception layer sits inside, so a 500
passes out through all of it.

```teal file=tasks.tl
--- The tasks app: the pages, the event stream and the middleware they share.

local Assets = require("cosmic.web.assets")
local Csrf = require("cosmic.web.csrf")
local Dev = require("cosmic.web.dev")
local Headers = require("cosmic.web.headers")
local Live = require("live")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local Site = require("site")
local Sse = require("cosmic.web.sse")
local StaticFiles = require("cosmic.web.static")
local Store = require("store")
local Web = require("cosmic.web")

local record Tasks
  --- What [`Tasks.app`] takes.
  record Options
    --- Signing keys for the session cookie, newest first.
    keys: {string}
    --- Whether the app is behind a proxy that ends TLS.
    behind_proxy: boolean
    --- Where `/static` comes from; nil for the project's `static/`
    --- (the executable's, or the directory in development).
    assets: Assets.Source
  end
end

--- The app. In development mode (`COSMIC_WEB_DEV=1`) it reloads pages.
function Tasks.app(opts: Tasks.Options): Web.App
  local store = Store.new()
  local hub = Sse.new_hub{}
  local csp = Headers.Csp.htmx_default()
  csp.directives["script-src"] = { "'self'", "{nonce}" }

  local routes = Site.routes(store, hub)
  for _, route in ipairs(Live.routes(hub)) do routes[#routes + 1] = route end
  if opts.assets ~= nil then
    routes[#routes + 1] = StaticFiles.mount("/static", { source = opts.assets })
  else
    routes[#routes + 1] = Dev.static("/static")
  end

  return Dev.app{
    routes = routes,
    middleware = {
      Web.access_log(),
      Headers.middleware{ csp = csp, nonce = true, hsts = { max_age = 31536000 } },
      Session.middleware{ store = SessionCookie.store{ keys = opts.keys } },
      Csrf.middleware(),
    },
    hubs = { hub },
    trusted_proxy = opts.behind_proxy,
  }
end

return Tasks
```

The program reads its secrets from the environment and serves on the
loopback. [`Web.serve`] runs the lifespan, listens and, on SIGINT or SIGTERM,
stops gracefully: open requests have `grace_ns` (10 seconds) to finish, and
the app's hubs close their streams.

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
--- The development loop: restarts `app.tl` when a file changes.

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

Run it with `cosmic dev.tl`. Because the supervisor sets `COSMIC_WEB_DEV=1`
the app, built by [`Dev.app`], is in development mode: it shows a fault's
stack, serves `static/` from disk with `Cache-Control: no-store`, adds
a script to every page that reloads the browser when the process is
replaced and swaps the stylesheets when only a `.css` file changed, and
carries the page's CSP nonce on that script's tag. An app that shows
source paths to whoever asks serves the loopback only: [`Web.serve`]
refuses a development app a listener elsewhere and a `trusted_proxy`, and
the app answers only `localhost`, `127.0.0.1` and `[::1]` unless
`trusted_hosts` names others, so a page on another site cannot reach it by a
name that resolves to the loopback.

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
browser does, check the 422, the flash, the nonce and the live stream:

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
  assert(added.status == 201 and added.body:find('id="new"', 1, true))
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
  local missing = client:post("/tasks", { form = {}, headers = htmx(csrf_of(client)) })
  assert(missing.status == 422 and missing.body:find("is required", 1, true))
end

local function test_a_post_without_the_token_is_refused()
  local client = Web.test_client(app())
  csrf_of(client)
  local refused = client:post("/tasks", { form = { title = "x" } })
  assert(refused.status == 403)
  local stranger = Web.test_client(app()):post("/tasks", { form = { title = "x" },
    headers = { ["X-CSRF-Token"] = "forged" } })
  assert(stranger.status == 403)
end

local function test_hello_flashes_once()
  local client = Web.test_client(app())
  local token = csrf_of(client)
  local sent = client:post("/hello", { form = { name = "Ada", csrf_token = token }, follow_redirects = true })
  assert(sent.body:find("hello, Ada", 1, true))
  assert(not client:get("/").body:find("hello, Ada</p>", 1, true), "a flash is shown once")
end

local function test_the_nonce_in_the_policy_is_the_one_in_the_tags()
  local page = Web.test_client(app()):get("/")
  local nonce = assert(page.headers["content-security-policy"]:match("'nonce%-([%w_-]+)'"))
  -- The page writes a byte that is no letter or digit as a character reference.
  local written = nonce:gsub("[_-]", function(byte: string): string
    return ("&#%d;"):format(byte:byte())
  end)
  assert(page.body:find('nonce="' .. written .. '"', 1, true))
end

local function test_a_new_task_reaches_an_open_page()
  Web.with_client(app(), function(client: Web.TestClient)
    local token = csrf_of(client)
    local open = client:get("/events", { stream = true })
    assert(open.status == 200 and open.headers["content-type"] == "text/event-stream")
    local body = assert(open.stream)
    assert(body:read() == "retry: 3000\n\n")
    client:post("/tasks", { form = { title = "live" }, headers = htmx(token) })
    local event = assert(body:read())
    assert(event:find("event: tasks", 1, true) and event:find("live", 1, true), event)
    assert(body:close())
  end)
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
print(((said.stderr or "") .. (said.stdout or "")):match("test: [A-Z]+"))
```

```output
test: PASS
```

## forms and uploads

The routes of `site.tl` are typed. A route made with [`Web.post_typed`] and its siblings names
[`cosmic.shape`] specs for its path parameters, its query and its body
([`Web.input`]). The handler is then given checked records in that order,
after the request, and input that fails them is answered before it runs:
`NEW` above is `Shape.record_of("NewTask")`, so `create` reads `b.title` as
a `string` that is certainly there. A slot a route does not read is
[`Web.NONE`] (or [`Web.no_body`]) and its parameter is nil.

The statuses keep two failures apart. Input that cannot be decoded is 400
(a bad percent-escape, malformed JSON). A wrong `Content-Type` is 415, a
body over its limit is 413, and a value that decodes but fails its spec is
422. A form re-renders on 422 with every field's error; an API answers
`application/problem+json`, each error with the JSON Pointer of the value
that failed (a JSON body reports its first failure). A route's `on_invalid` turns the
refusal into whatever the route wants, as `refuse` does for the form;
[`Input.errors_by_field`] gives the messages and [`Input.value`] the text
the person typed (leave a password out with `secret`). A rule no spec can
state, such as a blank title, is the handler's, reported the same way with
[`Input.fail`].

The next two files are tests of small projects of their own, which the last
block of the API section runs.

A form is text, so the binder reads by the spec: `integer` from digits,
a `boolean` from its presence, a list from a name sent twice, an empty
optional field as nil. [`Web.form_body`] reads a urlencoded form,
[`Web.json_body`] a JSON body and [`Web.multipart_body`] an upload. A route
that wants to read for itself calls [`Input.form`], [`Input.json`] or
[`Input.multipart`] on its request.

```teal file=signup_test.tl
local Shape = require("cosmic.shape")
local Web = require("cosmic.web")

local record Signup
  email: string
  age: integer | nil
end
local SIGNUP <const> = Shape.record_of("Signup")

local function client(): Web.TestClient
  return Web.test_client(Web.app{ routes = {
    Web.post_typed("/signup", Web.input(Web.NONE, Web.NONE, Web.form_body(SIGNUP)),
      function(_req: Web.Request, _p: Web.None, _q: Web.None, form: Signup): Web.Response
        return Web.text("welcome " .. form.email, { status = 201 })
      end),
  } })
end

local function test_a_form_that_binds_reaches_the_handler()
  local reply = client():post("/signup", { form = { email = "ada@example.org", age = "36" } })
  assert(reply.status == 201 and reply:text() == "welcome ada@example.org")
end

local function test_a_value_that_fails_its_spec_is_422()
  assert(client():post("/signup", { form = { age = "old" } }).status == 422)
end

local function test_input_that_cannot_be_decoded_is_400()
  local reply = client():post("/signup", { body = "email=%zz",
    content_type = "application/x-www-form-urlencoded" })
  assert(reply.status == 400)
end

local function test_a_form_route_reads_no_json()
  assert(client():post("/signup", { json = { email = "x" } }).status == 415)
end
```

An upload is a multipart form. Its text parts bind to the record and each
file part is spooled to a private file under a random name, removed when
the handler returns unless it moves the file. The client's file name is for
display only. Two limits apply and the smaller wins: the route's
`input_options` (`max_file_bytes` is 8 MiB by default) and the server's
`limits.body_bytes`, 1 MiB for every route, past which the server answers
413 before the route is known. A larger upload needs [`Web.serve`] given a
higher `limits.body_bytes`, for the whole app. The test client calls the
app in-process and does not meet the server's limit; [`Web.with_server`]
serves the app on the loopback and does. A test that opens a socket
declares `loopback` in its [`Test.policy`].

```teal file=upload_test.tl
local Input = require("cosmic.web.input")
local Shape = require("cosmic.shape")
local Test = require("cosmic.test")
local Web = require("cosmic.web")

Test.policy{ loopback = { "127.0.0.1" } }

local record Avatar
  name: string
end
local AVATAR <const> = Shape.record_of("Avatar")

local BOUNDARY <const> = "multipart/form-data; boundary=xyz"

local function app(): Web.App
  return Web.app{ routes = {
    Web.post_typed("/avatar", Web.input(Web.NONE, Web.NONE, Web.multipart_body(AVATAR)),
      function(req: Web.Request, _p: Web.None, _q: Web.None, form: Avatar): Web.Response
        local file = assert(Input.multipart(req).value).files["avatar"][1]
        return Web.text(form.name .. ":" .. file.filename .. ":" .. file.size)
      end, { input_options = { max_file_bytes = 4 * 1024 * 1024 } }),
  } }
end

local function test_a_file_part_is_spooled_and_the_text_part_bound()
  local body = '--xyz\r\nContent-Disposition: form-data; name="name"\r\n\r\nAda\r\n' ..
    '--xyz\r\nContent-Disposition: form-data; name="avatar"; filename="../a.png"\r\n' ..
    'Content-Type: image/png\r\n\r\nPNG\r\n--xyz--\r\n'
  local sent = Web.test_client(app()):post("/avatar", { body = body, content_type = BOUNDARY })
  assert(sent:text() == "Ada:a.png:3", "the client's path is cut to its last component")
end

local function test_the_servers_body_limit_comes_before_the_route_allows_more()
  Web.with_server(app(), function(client: Web.LoopbackClient)
    local big = ("x"):rep(2 * 1024 * 1024)
    local refused = assert(client:post("/avatar", { body = big, content_type = BOUNDARY }))
    assert(refused.status == 413)
  end)
end
```

## sessions

A session is a small JSON object kept for a browser, behind one interface
and two stores. [`Session.middleware`] reads the cookie lazily: a request
that never touches the session sends no cookie, and one that only reads
sends none either. A handler gets the handle with [`Session.of`] and uses
`get`, `set`, `delete`, `flash` and `take_flashes`, as `site.tl` above does.
A flash is shown once, on the next page.

- [`SessionCookie.store`] keeps the whole session in a signed cookie
  and nothing on the server. **The cookie is signed, not encrypted**: the
  browser can read it, so never put a secret in it. A copy stays valid until
  it expires, even after logout.
- [`SessionSqlite.store`] keeps the data in a SQLite table under a random id
  that the cookie holds alone. A session can be revoked, and
  `destroy_subject` ends all of one user's.

Call `session:regenerate()` at login and on any change of privilege, and
`session:invalidate()` at logout. Keys come from the environment, never
from source: [`Secret.keys_from_env`] reads a comma-separated list, newest
first (`new,old` while a key is rotated out), and refuses a key that is
short or has too few distinct bytes. [`Secret.generate`] makes one:
`cosmic -e 'print(require("cosmic.web.secret").generate())'`.

```teal file=session_test.tl
local Secret = require("cosmic.web.secret")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local SessionSqlite = require("cosmic.web.session.sqlite")
local Sqlite = require("cosmic.sqlite")
local Web = require("cosmic.web")

local function login(store: Session.Store): Web.App
  return Web.app{
    routes = {
      Web.post("/login", function(req: Web.Request): Web.Response
        local session = Session.of(req)
        session:regenerate()
        session:set("user", "ada")
        session:bind_subject("ada")
        return Web.text("in")
      end),
      Web.get("/me", function(req: Web.Request): Web.Response
        return Web.text(Session.of(req):get_string("user") or "anonymous")
      end),
    },
    middleware = { Session.middleware{ store = store } },
  }
end

local function test_a_weak_key_is_refused()
  local ok, why = Secret.check("changeme")
  assert(not ok and why:find("at least 32 bytes", 1, true))
  assert(#assert(Secret.parse_keys(Secret.generate() .. "," .. Secret.generate())) == 2)
end

local function test_a_stored_session_can_be_revoked()
  local store = assert(SessionSqlite.store((assert(Sqlite.memory()))))
  local laptop = Web.test_client(login(store))
  laptop:post("/login")
  assert(laptop:get("/me"):text() == "ada")
  assert(SessionSqlite.destroy_subject(store, "ada") == 1)
  assert(laptop:get("/me"):text() == "anonymous")
end

local function test_a_signed_cookie_is_not_readable_to_script()
  local store = SessionCookie.store{ keys = { Secret.generate() } }
  local cookie = Web.test_client(login(store)):post("/login").headers["set-cookie"]
  assert(cookie:find("HttpOnly", 1, true) and cookie:find("SameSite=Lax", 1, true))
end
```

The tests show the three: a weak key refused, a stored session revoked
for every device of a user, and the cookie a signed session sets.

The SQLite store runs its queries on the serving thread: a point lookup
is microseconds, but give the sessions a database of their own if another
process writes to the file.

## a JSON API

An API is routes under a prefix, here `Web.mount("/api", ...)` returned by
`Api.mount`. Its routes are typed routes: `json_body` reads and checks the
body, and a refusal is an `application/problem+json` with each error's JSON
Pointer. A handler that wants an error calls [`Web.abort`]; a client that
asks for JSON (an `Accept` header) gets a problem body and a browser gets a
page. An empty Lua table encodes as `{}`, so a list that may be empty goes
through [`Json.array`] to encode as `[]`.

```teal file=api.tl
--- A JSON API over a list of notes, to mount in any app.

local Cors = require("cosmic.web.cors")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Shape = require("cosmic.shape")
local Web = require("cosmic.web")

local record Api
  --- What [`Api.mount`] takes.
  record Options
    --- The bearer token a change needs.
    token: string
    --- The origins whose pages may call the API.
    origins: {string}
  end
  --- One note.
  record Note
    id: integer
    title: string
  end
end

local record NewNote
  title: string
end
local NEW <const> = Shape.record_of("NewNote")

local record NotePath
  id: integer
end
local NOTE <const> = Shape.record_of("NotePath")

local record Page
  limit: integer | nil
end
local PAGE <const> = Shape.record_of("Page")

--- Middleware: a change needs `Authorization: Bearer <token>`; a read does not.
local function require_token(token: string): Web.Middleware
  if token == "" then error("api: the token must not be empty", 2) end
  local wanted = "Bearer " .. token
  return function(inner: Web.Handler): Web.Handler
    return function(req: Web.Request): Web.Response
      if req.method ~= "GET" and req.method ~= "HEAD" and req.method ~= "OPTIONS" then
        if not Hash.equal(req:header("authorization") or "", wanted) then
          local denied = Web.problem(401, "a bearer token is required")
          Web.set_header(denied, "WWW-Authenticate", "Bearer")
          return denied
        end
      end
      return inner(req)
    end
  end
end

--- The API under `/api`, with its own notes.
function Api.mount(opts: Api.Options): Web.Route
  local notes: {Api.Note} = {}

  local function list(_req: Web.Request, _p: Web.None, q: Page, _b: Web.None): Web.Response
    local out: {Api.Note} = {}
    for _, note in ipairs(notes) do
      if q.limit == nil or #out < q.limit then out[#out + 1] = note end
    end
    return Web.json({ notes = Json.array(out) })
  end

  local function create(req: Web.Request, _p: Web.None, _q: Web.None, b: NewNote): Web.Response
    local note: Api.Note = { id = #notes + 1, title = b.title }
    notes[#notes + 1] = note
    return Web.json(note, { status = 201, headers = { Location = assert(req:url_for("api:show", { id = note.id })) } })
  end

  local function show(_req: Web.Request, p: NotePath, _q: Web.None, _b: Web.None): Web.Response
    local note = notes[p.id]
    if note == nil then return Web.abort(404, "no such note") end
    return Web.json(note)
  end

  return Web.mount("/api", {
    Web.get_typed("/notes", Web.input(Web.NONE, PAGE, Web.no_body), list),
    Web.post_typed("/notes", Web.input(Web.NONE, Web.NONE, Web.json_body(NEW)), create),
    Web.get_typed("/notes/:id", Web.input(NOTE, Web.NONE, Web.no_body), show, { name = "show" }),
  }, {
    name = "api",
    middleware = { Cors.middleware{
      allow_origins = opts.origins,
      allow_methods = { "GET", "POST" },
      allow_headers = { "Authorization", "Content-Type" },
    }, require_token(opts.token) },
  })
end

return Api
```

The API is guarded by a bearer token, not a cookie. A secret is compared
with [`Hash.equal`], never `==`. An app that has pages as well puts the API
beside them, and tells the CSRF middleware to leave it alone (`exempt`):
no cookie authenticates a request to it, so a cross-site page has nothing
to forge. An app that is only an API has no session and no CSRF middleware
at all.

[`cosmic.web.cors`] is for pages on another origin that call the API.
[`Cors.middleware`] answers a preflight and marks the responses a listed
origin may read; it is not authorization, it only tells a browser whose
scripts may read a response. It goes on the mount here, so a 404 or a 401 from
the API carries the headers too and a browser shows the problem. Origins
match exactly on scheme, host and port; `"*"` cannot be combined with
credentials. The test builds a site with a page, the cookie and CSRF
middleware and the API:

```teal file=api_test.tl
local Api = require("api")
local Csrf = require("cosmic.web.csrf")
local Secret = require("cosmic.web.secret")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local Web = require("cosmic.web")

local TOKEN <const> = "s3cret-token"
local ORIGIN <const> = "https://app.example.com"

--- The API beside a page, behind the cookie and CSRF middleware a site has;
--- the API is exempt, as no cookie authenticates it.
local function client(): Web.TestClient
  return Web.test_client(Web.app{
    routes = {
      Web.get("/", function(_req: Web.Request): Web.Response return Web.text("page") end),
      Api.mount{ token = TOKEN, origins = { ORIGIN } },
    },
    middleware = {
      Session.middleware{ store = SessionCookie.store{ keys = { Secret.generate() } } },
      Csrf.middleware{ exempt = function(req: Web.Request): boolean
        return req.path == "/api" or req.path:sub(1, 5) == "/api/"
      end },
    },
  })
end

local function test_a_change_needs_the_token()
  local c = client()
  assert(c:get("/api/notes").body == '{"notes":[]}', "an empty list is [], not {}")
  assert(c:post("/api/notes", { json = { title = "x" } }).status == 401)
  local made = c:post("/api/notes", { json = { title = "first" },
    headers = { Authorization = "Bearer " .. TOKEN } })
  assert(made.status == 201 and made.headers["location"] == "/api/notes/1")
  assert(c:get("/api/notes/1"):text() == '{"id":1,"title":"first"}')
  assert(c:post("/", { form = {} }).status == 403, "the page is still behind CSRF")
end

local function test_a_refusal_is_a_problem_body()
  local c = client()
  local bad = c:post("/api/notes", { json = { title = 7 }, headers = { Authorization = "Bearer " .. TOKEN } })
  assert(bad.status == 422 and bad.headers["content-type"] == "application/problem+json")
  local missing = c:get("/api/notes/9", { headers = { Accept = "application/json" } })
  assert(missing.status == 404 and missing.headers["content-type"] == "application/problem+json")
  assert(c:get("/api/notes/one").status == 422)
  assert(c:get("/api/notes?limit=0"):text() == '{"notes":[]}')
end

local function test_cors_admits_only_the_listed_origin()
  local c = client()
  local ask = { Origin = ORIGIN, ["Access-Control-Request-Method"] = "POST",
    ["Access-Control-Request-Headers"] = "authorization" }
  local preflight = c:options("/api/notes", { headers = ask })
  assert(preflight.status == 204 and preflight.headers["access-control-allow-origin"] == ORIGIN)
  ask.Origin = "https://evil.example"
  assert(c:options("/api/notes", { headers = ask }).headers["access-control-allow-origin"] == nil)
  local read = c:get("/api/notes", { headers = { Origin = ORIGIN } })
  assert(read.headers["access-control-allow-origin"] == ORIGIN)
end
```

These small projects are tested together, apart from the tasks app: the
form, upload, session and API tests above. The runner is the one used before.

```teal
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
print(((said.stderr or "") .. (said.stdout or "")):match("test: [A-Z]+"))
```

## deploying

Build one program: `cosmic build` writes `tasks` into the build directory,
with `static/` and htmx inside it, and `cosmic build --host` a native
executable that needs no shell. The program is configured by environment:
`TASKS_KEYS` here.

- **A proxy.** Behind a proxy that ends TLS, set `trusted_proxy = true`
  (`behind_proxy` in `Tasks.Options`): the scheme, host and client then come
  from `X-Forwarded-Proto`, `X-Forwarded-Host` and `X-Forwarded-For`, of
  which only the last entry is read, the one the proxy added. The session
  cookie is then `Secure` and the CSRF origin check compares https origins.
  Without it, every https `Origin` looks foreign to CSRF and the session
  cookie needs `secure = true` by hand.
- **Hosts.** `trusted_hosts` lists the hosts the app answers to; a request
  for another host is a 400, and `req:base_url()` becomes available for
  building absolute links.
- **Limits.** [`Web.serve`] takes `limits` (`body_bytes` is 1 MiB), the
  timeouts (`head_ns`, `body_ns`, `idle_ns`, `timeout_ns`) and `grace_ns`.
  A handler runs in its connection's task and must not block the thread.
- **Errors.** `debug` stays false: it shows stacks. `error_pages` and
  `error_view` make the pages that answer a status.
- **HSTS.** Turn it on once the site is https for good; a browser keeps it
  for the whole `max_age`.

```teal continue
do
  local Web = require("cosmic.web")
  local app = Web.app{
    routes = { Web.get("/", function(req: Web.Request): Web.Response
      return Web.text(req.scheme .. " " .. (req.client ~= nil and req.client.host or "?"))
    end) },
    trusted_proxy = true,
  }
  local seen = Web.test_client(app):get("/", { headers = {
    ["X-Forwarded-Proto"] = "https", ["X-Forwarded-For"] = "203.0.113.9" } })
  assert(seen:text() == "https 203.0.113.9")
end
```

```output
test: PASS
```

[`Assets.directory`]: ../../cosmic/web/assets.tl
[`Assets.embedded`]: ../../cosmic/web/assets.tl
[`Assets.memory`]: ../../cosmic/web/assets.tl
[`Cors.middleware`]: ../../cosmic/web/cors.tl
[`cosmic.child`]: ../../cosmic/child.tl
[`cosmic.http.server`]: ../../cosmic/http/server.tl
[`cosmic.layout`]: ../../cosmic/layout.tl
[`cosmic.shape`]: ../../cosmic/shape.tl
[`cosmic.web.cors`]: ../../cosmic/web/cors.tl
[`cosmic.web.htmx`]: ../../cosmic/web/htmx.tl
[`cosmic.web.sse`]: ../../cosmic/web/sse.tl
[`cosmic.web.static`]: ../../cosmic/web/static.tl
[`cosmic.web`]: ../../cosmic/web/init.tl
[`Csrf.field`]: ../../cosmic/web/csrf.tl
[`Csrf.meta`]: ../../cosmic/web/csrf.tl
[`Csrf.middleware`]: ../../cosmic/web/csrf.tl
[`Dev.app`]: ../../cosmic/web/dev.tl
[`Dev.static`]: ../../cosmic/web/dev.tl
[`Dev.supervise`]: ../../cosmic/web/dev.tl
[`Hash.equal`]: ../../cosmic/hash.tl
[`Headers.middleware`]: ../../cosmic/web/headers.tl
[`Html.SafeHtml`]: ../../cosmic/html.tl
[`Html.SafeJson`]: ../../cosmic/html.tl
[`Htmx.apply`]: ../../cosmic/web/htmx.tl
[`Htmx.head`]: ../../cosmic/web/htmx.tl
[`Htmx.page`]: ../../cosmic/web/htmx.tl
[`Htmx.partial`]: ../../cosmic/web/htmx.tl
[`Htmx.redirect_to`]: ../../cosmic/web/htmx.tl
[`Htmx.request`]: ../../cosmic/web/htmx.tl
[`Htmx.stop_polling`]: ../../cosmic/web/htmx.tl
[`Input.errors_by_field`]: ../../cosmic/web/input.tl
[`Input.fail`]: ../../cosmic/web/input.tl
[`Input.form`]: ../../cosmic/web/input.tl
[`Input.json`]: ../../cosmic/web/input.tl
[`Input.multipart`]: ../../cosmic/web/input.tl
[`Input.value`]: ../../cosmic/web/input.tl
[`Json.array`]: ../../cosmic/json.tl
[`Secret.generate`]: ../../cosmic/web/secret.tl
[`Secret.keys_from_env`]: ../../cosmic/web/secret.tl
[`Session.middleware`]: ../../cosmic/web/session/init.tl
[`Session.of`]: ../../cosmic/web/session/init.tl
[`SessionCookie.store`]: ../../cosmic/web/session/cookie.tl
[`SessionSqlite.store`]: ../../cosmic/web/session/sqlite.tl
[`Sse.Event.html`]: ../../cosmic/web/sse.tl
[`StaticFiles.mount`]: ../../cosmic/web/static.tl
[`Test.policy`]: ../../cosmic/test.tl
[`Web.abort`]: ../../cosmic/web/init.tl
[`Web.add_header`]: ../../cosmic/web/init.tl
[`Web.app`]: ../../cosmic/web/init.tl
[`Web.delete`]: ../../cosmic/web/init.tl
[`Web.empty`]: ../../cosmic/web/init.tl
[`Web.form_body`]: ../../cosmic/web/init.tl
[`Web.get`]: ../../cosmic/web/init.tl
[`Web.html`]: ../../cosmic/web/init.tl
[`Web.input`]: ../../cosmic/web/init.tl
[`Web.json_body`]: ../../cosmic/web/init.tl
[`Web.json`]: ../../cosmic/web/init.tl
[`Web.key`]: ../../cosmic/web/init.tl
[`Web.mount`]: ../../cosmic/web/init.tl
[`Web.multipart_body`]: ../../cosmic/web/init.tl
[`Web.no_body`]: ../../cosmic/web/init.tl
[`Web.NONE`]: ../../cosmic/web/init.tl
[`Web.post_typed`]: ../../cosmic/web/init.tl
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
