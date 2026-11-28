# web apps

<!-- policy: profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } -->

[`cosmic.web`] makes an htmx page, a JSON API, or both in one program a
matter of a route table, a few templates and a call to [`Web.serve`]. It
layers on [`cosmic.http.server`] and borrows Starlette's vocabulary:
a request and a response that are plain data, routes, mounts, middleware
as `function(Handler): Handler`, a test client, `StaticFiles`.

This is the first of seven guides. It builds `tasks`, a small task list
whose buttons talk to the server with htmx, from an empty directory. Each
file below is written there. The block at the end of the guide runs the
tests of the finished project, so what you read is what runs. The other
guides each take one subject further, with a small project of their own,
and can be read alone. The map at the end of this one lists them. The guide for
a first project, `cosmic docs project`, covers the verbs this one
uses.

## the files

A web project is an ordinary project ([`cosmic.layout`]) with two
conventions added.

    tasks/
      static/app.css            carried verbatim in the executable
      pages/data.tl             the records the templates are given
      pages/tasks.tmpl          templates: pages.tasks, pages.layout
      store.tl                  the tasks, in memory
      view.tl  site.tl          the pages
      tasks.tl                  the app, with its middleware
      app.tl  dev.tl            the program, and its development loop
      cmd/tasks/main.tl         what `cosmic build` makes into `tasks`
      tasks_test.tl             tests of the pages

Every file under `static/` is a public asset. `cosmic build` carries
them in the executable and [`cosmic.web.static`] serves them; run from
source, the same code serves the directory. A project of several programs
gives one its own files under `cmd/<name>/static/`, which that program
alone carries, each in place of a file of the same path under `static/`. A `.tmpl` file is a typed
template, built into a module of the same path.

## templates

The compiler refuses a slot where no escaping is right, and says where and
why. A slot in `hx-on*`, `hx-vars`, `hx-trigger` or a `<script>` is refused
in every template, with or without `{{use htmx}}`, but for a script's `src`
(a whole `SafeResourceUrl`, as a `<link>`'s `href` takes), `nonce`
and `integrity`; the dialect adds the
rules for URL, selector and JSON attributes. This example checks some of
what is refused, and prints how many of its templates the compiler turned away.

```teal
local Template = require("cosmic.template")

do
  local tally = { refused = 0 }
  local header = "{{type Page from site.page}}{{use htmx}}\n"
  local function reason(markup: string, plain?: boolean): string
    local source, why = Template.compile((if plain == true then "{{type Page from site.page}}\n" else header end) .. markup, "page.tmpl")
    assert(source == nil, markup)
    tally.refused = tally.refused + 1
    return tostring(why)
  end
  -- A script's src and a link's href take a slot only as the whole value, a
  -- SafeResourceUrl the program vouched for: a part of one could name any script.
  assert(reason('<script src="/js/{{.name}}" defer></script>'):find("must be the whole value, a SafeResourceUrl", 1, true))
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
  local ok, _ = Template.compile(header .. '<a hx-get="/tasks/{{.id}}" hx-target="#task-{{.id}}">x</a>\n', "page.tmpl")
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
    mut done: boolean
  end
  record Panel
    title: string
    error: string?
    tasks: {Task}
  end
  record Page
    panel: Panel
  end
  record Layout
    title: string
    css: Html.SafeResourceUrl
    htmx: Html.SafeHtml
    csrf: Html.SafeJson
    body: Html.SafeHtml
  end
end

return data
```

The page, the panel on it and each row are one file. The body is the
page; each `{{define name Type}} .. {{end}}` after it is a template of its
own, of a record of the same module, which `| name` calls and the module
exports beside `render`: `pages.tasks` answers `render`, `panel` and
`row`, so a route that changes one task responds with its row alone.

`{{use htmx}}` makes the template read htmx's attributes:
`hx-post="/tasks/{{.id}}/toggle"` is a URL with a slot after literal text,
escaped as one path segment, and `hx-target="#task-{{.id}}"` is a
selector, escaped as a CSS identifier. A slot is escaped for the place it
lands, so `{{.title}}` in the text cannot start a tag and `{{.id}}` in a
URL cannot add a `/`. The `-}}` that ends a `{{define}}` drops the newline
after it, so a row starts at its `<li>`. Each define is checked as a whole template is, so it
must end where it began: a row cannot leave an attribute open for what
follows it. The panel is the form and the list together, because the
server responds to an `add` with the whole panel: the new row appears, and
the form is empty again or shows what was wrong with it.

```teal file=pages/tasks.tmpl
{{type Page from pages.data}}{{use htmx}}
<h1>tasks</h1>
{{.panel | panel}}
{{define panel Panel -}}
<section id="panel">
  <form hx-post="/tasks" hx-target="#panel" hx-swap="outerHTML">
    <input name="title" value="{{.title}}" placeholder="what needs doing?" autofocus>
    <button>add</button>
    {{if .error}}<p class="error">{{.error}}</p>{{end}}
  </form>
  <ul id="tasks">{{range .tasks}}{{. | row}}{{else}}<li>nothing to do</li>{{end}}</ul>
</section>
{{end}}
{{define row Task -}}
<li id="task-{{.id}}" class="{{if .done}}done{{end}}">
  <button hx-post="/tasks/{{.id}}/toggle" hx-target="#task-{{.id}}" hx-swap="outerHTML">{{if .done}}undo{{else}}done{{end}}</button>
  <span class="title">{{.title}}</span>
  <button hx-delete="/tasks/{{.id}}" hx-target="#task-{{.id}}" hx-swap="outerHTML">delete</button>
</li>
{{end}}
```

Another file calls a define by its import path:
`{{.x | pages.tasks.panel}}`.

The layout is the page around it. `hx-headers` takes an [`Html.SafeJson`]
as its whole value (it carries the CSRF token, which [the security
guide](web-security.md) explains). The stylesheet's `href` takes only a
whole [`Html.SafeResourceUrl`], a URL the program vouches for, since a
stylesheet or script from a URL that data chose could be anyone's. htmx's
own tags arrive ready made from [`Htmx.head`], for a reason a later section
shows.

```teal file=pages/layout.tmpl
{{type Layout from pages.data}}{{use htmx}}
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{.title}}</title>
<link rel="stylesheet" href="{{.css}}">
{{.htmx}}
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
The most specific route wins, whatever the order. A path is made canonical
before any middleware sees it. The GET route responds to a HEAD, and a
wrong method gets a 405 with `Allow`. `name` is how a route is found again:
`app:url_for("toggle", { id = 3 })` and `req:url_for(...)` build the URL,
escaping a parameter as a template does. A [`Web.mount`] puts routes under
a prefix and, if it is named, prefixes theirs (`api:show`).

A handler takes a [`Web.Request`] and returns a [`Web.Response`], the
server's own reply record. The constructors are [`Web.html`] (which takes
only [`Html.SafeHtml`], never a string), [`Web.json`], [`Web.text`],
[`Web.redirect`], [`Web.empty`], [`Web.stream`] and [`Web.problem`].
[`Web.abort`] ends the request from anywhere with a status. A handler
that raises any other error gets a 500, with nothing of the fault shown
(`debug = true` shows it, in development only). A response is a
table, so [`Web.add_header`] appends a header line, as for a second
`Set-Cookie`.

The store holds the tasks. One process serves every request on one
thread, so a plain table is consistent.

```teal file=store.tl
--- The tasks, in memory: one per process, which is all a cooperative
--- server needs to keep them consistent.

local data = require("pages.data")

local class Store
  --- Tasks in the order they were added.
  tasks: mut {data.Task}
  --- The id the next task takes.
  mut next_id: integer

  --- Adds a task and returns it.
  function add(self, title: string): data.Task
    local task: data.Task = { id = self.next_id, title = title, done = false }
    self.next_id = self.next_id + 1
    self.tasks[#self.tasks + 1] = task
    return task
  end

  --- The task with `id`, or nil.
  function get(self, id: integer): data.Task?
    for _, task in ipairs(self.tasks) do
      if task.id == id then return task end
    end
    return nil
  end

  --- Flips a task's `done`; the task, or nil.
  function toggle(self, id: integer): data.Task?
    local task = self:get(id)
    if task ~= nil then task.done = not task.done end
    return task
  end

  --- Removes a task; whether there was one.
  function remove(self, id: integer): boolean
    for at, task in ipairs(self.tasks) do
      if task.id == id then
        table.remove(self.tasks, at)
        return true
      end
    end
    return false
  end
end

--- A store with no tasks.
function Store.new(): Store
  return { tasks = {}, next_id = 1 }
end

return Store
```

The pages' routes follow. `home` returns a whole page or a fragment.
`create`, `toggle` and `remove` return what a button asked for. `create`
reads the form with [`Input.form`], which returns a status to pass on for
a body it cannot decode. [The forms guide](web-forms.md) shows routes that
name the shape of their input and have it checked before the handler runs.

```teal file=site.tl
--- The pages: the list, the form, and what a button does to a task.

local Html = require("cosmic.html")
local Input = require("cosmic.web.input")
local Store = require("store")
local String = require("cosmic.string")
local Url = require("cosmic.url")
local View = require("view")
local Web = require("cosmic.web")
local data = require("pages.data")
local tasks = require("pages.tasks")

local record Site
end

--- Routes over `store`.
function Site.routes(store: Store): {Web.Route}
  local function panel_of(title: string, problem?: string): data.Panel
    return { title = title, error = problem, tasks = store.tasks }
  end

  local function shown(title: string, problem?: string): Html.SafeHtml
    return tasks.panel(panel_of(title, problem))
  end

  local function home(req: Web.Request): Web.Response
    return View.page(req, "tasks", tasks.render({ panel = panel_of("") }))
  end

  local function create(req: Web.Request): Web.Response
    local read = Input.form(req)
    local invalid = read.invalid
    if invalid ~= nil then return Web.abort(invalid.status, invalid.message) end
    local title = String.trim(Url.query_last(assert(read.value), "title") or "")
    if title == "" then
      return Web.html(shown("", "give the task a name"), { status = 422 })
    end
    store:add(title)
    return Web.html(shown(""), { status = 201 })
  end

  --- The task a request's `:id` names, or nil.
  local function named(req: Web.Request): integer?
    return math.tointeger(tonumber(req.params["id"]))
  end

  local function toggle(req: Web.Request): Web.Response
    local id = named(req)
    local task = if id ~= nil then store:toggle(id) else nil end
    if task == nil then return Web.abort(404, "no such task") end
    return Web.html(tasks.row(task))
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
          return Web.json({ hello = assert(req.params["name"]) })
        end
        local query = req:query()
        local loud = query ~= nil and #query.pairs > 0
        return Web.text("hello " .. assert(req.params["name"]) .. (if loud then "!" else "" end))
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
  local redirected, trouble = pcall(Web.redirect, "javascript:alert(1)")
  assert(not redirected, tostring(trouble))
end
```

[`Web.key`] makes a typed key for per-request state: `req:set(KEY, v)` and
`req:get(KEY)`. A module exports the keys it owns, as the session, CSRF and
CSP modules do. `req.state` is an untyped table for scratch values only.

## htmx

[`cosmic.web.htmx`] is the server's half of htmx. [`Htmx.request`] reads
the `HX-*` headers a request carries and [`Htmx.partial`] says whether it
wants a fragment. They are client-controlled: use them to choose what to
show, never to decide what is allowed. [`Htmx.page`] returns the fragment for a
fragment request and the whole page for any other, and marks both
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

--- Returns the response to `req`: `content` alone for an htmx request,
--- else the whole page.
function View.page(req: Web.Request, title: string, content: Html.SafeHtml): Web.Response
  return Htmx.page(req, content, function(body: Html.SafeHtml): Html.SafeHtml
    -- The stylesheet's URL is the app's own route, which the program vouches for.
    local path = assert(req:url_for("static", { path = "app.css" }))
    local css = Html.trust_resource_url(path)
    return layout.render({ title = title, css = css, htmx = Htmx.head{ nonce = req:get(Headers.NONCE) },
      csrf = Csrf.hx_headers(req), body = body })
  end)
end

return View
```

[`Htmx.head`] writes the `<meta name="htmx-config">` tag and the script
tags for the htmx the binary carries (and for its SSE extension, with
`sse = true`, which [the live guide](web-live.md) uses), each with a
subresource integrity value computed from the bytes served. The
configuration is closed: no `eval`, no script in swapped HTML, no injected
style, and same-origin requests only. A 422 is swapped in, so a form's
errors reach the page. Other 4xx and 5xx responses are not swapped in. The files
themselves are served under `/_web/` by every [`Web.app`], ahead of the
routes, at paths that carry the version, so no route may live there.
[`Htmx.head`] is one call, not a template's slots, because it writes the
`htmx-config` tag and every script tag with an `integrity` the binary
computed from the bytes it serves: a template takes the lot as one
`SafeHtml`.

A response tells htmx in headers what to do with it. [`Htmx.apply`] writes
them, and refuses a redirect to another origin, since htmx navigates by
script. After a form post, [`Htmx.redirect_to`] returns an `HX-Redirect` for an
htmx request, and an ordinary redirect for any other.
[`Htmx.stop_polling`] returns a 286, which ends an `every 2s` poll.

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
  assert(refused == nil)
  assert(tostring(why):find("same-origin", 1, true))
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

A page's own script works beside htmx, and a few things trip it:

- A `<script>` in swapped HTML does not run: [`Htmx.head`] turns off
  htmx's `allowScriptTags`. Put the behavior in a static script and call
  it from `htmx.onLoad(fn)`. htmx calls `fn` once with `body` when it has
  taken in the page, and after a swap once for each top-level element
  swapped in, so `fn` looks in the element it is given and everything
  inside it (`el.querySelectorAll(sel)`).
- [`Htmx.head`] loads htmx with `defer`, and htmx takes in the page, and
  reads its `htmx-config`, at `DOMContentLoaded`. A `defer` script after
  htmx's tag runs before that. Add its listeners (`htmx:configRequest`,
  `htmx:beforeSwap`) there, as the script runs, with
  `document.addEventListener`. A listener added later misses the page's
  first requests, such as a `load` trigger's. `htmx.on` adds it later, at
  `DOMContentLoaded`, after htmx's own start. Send no request
  from there, since htmx's own defaults, not the page's configuration,
  would still hold.
- An element with `hx-get` and no `hx-trigger` sends its request on a
  click (on a change for a text-like `input`, `textarea` and `select`,
  on a submit for a form). A request the script starts with `htmx.ajax("GET", url,
  { source, target, swap })` needs no `hx-get` on its element. Leave it
  out, so a click does not send the request again.
- `htmx.trigger(element, name)` dispatches the event at once, but an
  element's `hx-trigger` hears it only after htmx has taken in that
  element, at `DOMContentLoaded` or after a swap.
- A URL that returns both a fragment and a whole page varies on the
  headers that chose: [`Htmx.page`] marks `Vary: HX-Request,
  HX-History-Restore-Request, HX-Boosted`. A service worker's
  `cache.match` keeps the two apart unless it is passed `ignoreVary`.

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
local Csp = require("cosmic.web.csp")
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
  local directives: mut {string: {string}} = {}
  for name, sources in pairs(Csp.htmx_default().directives) do directives[name] = sources end
  directives["script-src"] = { "'self'", "{nonce}" }
  local csp: Csp.Policy = { directives = directives }

  local routes: mut {Web.Route} = {}
  for _, route in ipairs(Site.routes(Store.new())) do routes[#routes + 1] = route end
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
    log:complain(tostring(why))
    return 2
  end
  local app = Tasks.app{
    keys = keys,
  }
  local ok, trouble = Web.serve(app, { listeners = { Net.tcp("127.0.0.1", 8080) } })
  if not ok then
    log:complain(tostring(trouble))
    return 1
  end
  return 0
end
```

`cosmic build` makes a program of `cmd/tasks/main.tl`, which only reruns
`app.tl`:

```teal file=cmd/tasks/main.tl
local app = require("app")

return function(): integer
  return app()
end
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
[`Dev.app`], is in development mode:

- It shows a fault's stack.
- It serves `static/` from disk with `Cache-Control: no-store`. A program
  run as `cosmic cmd/<name>/main.tl` lays its own `cmd/<name>/static/`
  over it, as its built executable does. `app.tl` is no program's main,
  and has no `cmd/<name>/static/`.
- It adds a script to every page. The script reloads the browser when the
  process is replaced, and swaps the stylesheets when only a `.css` file
  changed. The script's tag carries the page's CSP nonce.

An app that shows source paths to whoever asks serves the loopback only.
[`Web.serve`] refuses a development app a listener elsewhere, a socket
file (how a proxy reaches an app) and a `trusted_proxy`. The app responds
only to `localhost`, `127.0.0.1` and `[::1]`, unless `trusted_hosts` names
others, so a page on another site cannot reach it by a name that resolves
to the loopback.

## testing

[`Web.test_client`] calls the app in-process: no socket, a cookie jar that
works like a browser's, and the same checks of a reply the server would
make. `post` takes `form`, `json`, `body` and `content_type`, `headers`,
`query` and `follow_redirects`. [`Web.with_client`] runs a test with the
lifespan around it and an event loop, which a stream needs (`stream = true`
leaves the body unread in `reply.stream`); [`Web.with_server`] serves the
app on the loopback for what only a socket shows, such as the server's
body limit.

A test of the app does not read `static/`. A program that has a `cmd/`
main takes `/static` from the executable's embedded files, and a test
does not have them. So `Tasks.app` takes the files as `assets`, and the
test gives it [`Assets.memory`]. [`Assets.directory`] reads a directory and
[`Assets.embedded`] the executable's own.

The tests of the finished app go through a page for its tokens as a
browser does, and check the 422 and the refusal of a post without a token.
The session cookie is `Secure`, which a client sends back only as a
browser on an https page: `scheme = "https"`.

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

--- A browser on an https page of the app.
local function browser(): Web.TestClient
  local client = Web.test_client(app())
  client.scheme = "https"
  return client
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
  local client = browser()
  local page = client:get("/")
  assert(page.status == 200 and page.body:find("<h1>tasks</h1>", 1, true) ~= nil)
  assert(page.body:find("/_web/htmx-", 1, true), "the page loads htmx")
  assert(page.body:find("/static/app%.%x+%.css"), "and the stylesheet by its fingerprint")
  local fragment = client:get("/", { headers = { ["HX-Request"] = "true" } })
  assert(fragment.status == 200 and not fragment.body:find("<html", 1, true))
end

local function test_adding_a_task()
  local client = browser()
  local token = csrf_of(client)
  local added = client:post("/tasks", { form = { title = "write the guide" }, headers = htmx(token) })
  assert(added.status == 201 and added.body:find("write the guide", 1, true) ~= nil)
  assert(client:get("/").body:find("write the guide", 1, true))
  local done = client:post("/tasks/1/toggle", { headers = htmx(token) })
  assert(done.status == 200 and done.body:find('class="done"', 1, true) ~= nil)
  local gone = client:delete("/tasks/1", { headers = htmx(token) })
  assert(gone.status == 200 and gone.body == "")
  assert(client:delete("/tasks/1", { headers = htmx(token) }).status == 404)
end

local function test_a_blank_title_is_refused_with_its_message()
  local client = browser()
  local refused = client:post("/tasks", { form = { title = "  " }, headers = htmx(csrf_of(client)) })
  assert(refused.status == 422 and refused.body:find("give the task a name", 1, true) ~= nil)
end

local function test_a_post_without_the_token_is_refused()
  local client = browser()
  csrf_of(client)
  assert(client:post("/tasks", { form = { title = "x" } }).status == 403)
  local stranger = browser():post("/tasks", { form = { title = "x" },
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
local out = (said.stderr or "") .. (said.stdout or "")
-- The whole run where it did not pass, so a failure says which test and why.
print(out:match("test: %d+ tests? passed") or out)
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
[`cosmic.child`]: ../../cosmic/child/init.tl
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
[`Html.SafeResourceUrl`]: ../../cosmic/html.tl
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
