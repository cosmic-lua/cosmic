--- A web application on [`cosmic.http.server`]: a route table in code, a
--- request and a response that are plain typed data, middleware, an
--- exception layer and error pages, and an in-process test client. It
--- makes an htmx page, a JSON API, or both in one program a matter of a
--- list of routes and a call to [`Web.serve`].
---
---     local Net = require("cosmic.net")
---     local Web = require("cosmic.web")
---
---     local app = Web.app{
---       routes = {
---         Web.get("/", function(req: Web.Request): Web.Response
---           return Web.json({ hello = "world" })
---         end, { name = "home" }),
---         Web.get("/items/:id", function(req: Web.Request): Web.Response
---           return Web.json({ id = req.params.id })
---         end, { name = "item" }),
---       },
---       middleware = { Web.access_log() },
---     }
---     assert(Web.serve(app, { listeners = { Net.tcp("127.0.0.1", 8080) } }))
---
--- - A [`Web.Request`] wraps the server's, with the canonical path, the
---   matched route's `params`, lazy `bytes`, `text` and `query`, and typed
---   per-request state ([`Web.key`], `req:get`, `req:set`).
--- - A [`Web.Response`] is the server's own reply: [`Web.html`],
---   [`Web.json`], [`Web.text`], [`Web.redirect`], [`Web.empty`],
---   [`Web.stream`] and [`Web.problem`] make one, and [`Web.add_header`]
---   appends a header line (a `Set-Cookie`, a `Vary` token).
--- - Routes are data ([`Web.route`], [`Web.get`], [`Web.mount`]) that
---   [`Web.app`] compiles. The most specific route wins whatever the order,
---   a path is canonical before any middleware sees it, a HEAD is answered
---   by the GET, an OPTIONS and a 405 by `Allow`, and
---   `app:url_for("item", { id = 7 })` builds a URL back.
--- - Middleware is a function from a handler to a handler, stacked app,
---   then mount, then route. The exception layer sits inside the app's
---   middleware, so a 500 passes out through all of it; with `debug` off
---   it tells the client nothing of the fault.
--- - [`Web.test_client`] calls the app in-process and fails a reply the
---   server would refuse; [`Web.with_server`] serves it on the loopback for
---   what only the wire shows.
---
--- A handler runs in its connection's task, so it must not block the
--- thread: see [`Server.serve`].

local App = require("cosmic.web.app")
local Html = require("cosmic.html")
local Stack = require("cosmic.web.middleware")
local Request = require("cosmic.web.request")
local Response = require("cosmic.web.response")
local Route = require("cosmic.web.route")
local Router = require("cosmic.web.router")
local Testing = require("cosmic.web.testing")
local Stream = require("cosmic.stream")
local Types = require("cosmic.web.types")

local record Web
  --- What a handler answers: the server's own [`Server.Reply`].
  type Response = Types.Response
  --- Answers one request.
  type Handler = Types.Handler
  --- Wraps a [`Web.Handler`] in another, once, when the app is built.
  type Middleware = Types.Middleware
  --- What an app's `lifespan` returns to clean up.
  type Shutdown = Types.Shutdown
  --- A typed key for per-request or per-app state: see [`Web.key`].
  type Key<T> = Types.Key<T>
  --- Where a request came from.
  type Client = Types.Client
  --- What a request matched.
  type RouteInfo = Types.RouteInfo
  --- What the router decided for a request.
  type Outcome = Types.Outcome
  --- A request, as handlers and middleware see it.
  type Request = Types.Request
  --- Where an app writes its lines.
  type Sink = Types.Sink
  --- One route or mount.
  type Route = Types.Route
  --- What a route constructor takes beside the handler.
  type RouteOptions = Types.RouteOptions
  --- What a mount constructor takes.
  type MountOptions = Types.MountOptions
  --- What [`Web.router`] takes.
  type RouterOptions = Types.RouterOptions
  --- Routes compiled for matching.
  type Router = Types.Router
  --- What [`Web.app`] takes.
  type AppSpec = Types.AppSpec
  --- A built app.
  type App = Types.App
  --- What [`Web.serve`] takes.
  type ServeOptions = Types.ServeOptions
  --- What a response constructor takes beside its body.
  type ResponseOptions = Types.ResponseOptions
  --- What [`Web.access_log`] takes.
  type AccessLogOptions = Stack.AccessLogOptions
  --- What a test client's request takes.
  type TestOptions = Types.TestOptions
  --- A reply as a test client saw it.
  type TestResponse = Types.TestResponse
  --- An app driven in-process.
  type TestClient = Testing.Client
  --- A client of an app served on the loopback.
  type LoopbackClient = Testing.Loopback

  --- A typed key into a request's or an app's state, a table that names
  --- itself: `local SESSION: Web.Key<Session> = Web.key("session")`, then
  --- `req:set(SESSION, s)` and `req:get(SESSION)`. A module exports the keys
  --- it owns; two keys of one name are two keys.
  key: function<T>(name: string): Types.Key<T>

  --- Makes `body`, only [`Html.SafeHtml`] (a string does not type-check), a page
  --- or a fragment of `text/html`: see [`Response.html`].
  html: function(body: Html.SafeHtml, opts?: Types.ResponseOptions): Types.Response
  --- Makes `value` a JSON body, `nosniff`; a value that cannot be encoded raises,
  --- and the exception layer answers 500: see [`Response.json`].
  json: function(value: any, opts?: Types.ResponseOptions): Types.Response
  --- Makes `body` a plain-text body: see [`Response.text`].
  text: function(body: string, opts?: Types.ResponseOptions): Types.Response
  --- Redirects, 303 unless told, to a local path or an http(s) URL; any other
  --- target raises, which keeps a client-sent `next` from an open redirect:
  --- see [`Response.redirect`].
  redirect: function(location: string, opts?: Types.ResponseOptions): Types.Response
  --- Takes a redirect target a client sent where it is a local path, else a default: see [`Response.safe_next`].
  safe_next: function(input: string | nil, default: string): string
  --- Whether a text is a path on this origin: see [`Response.local_path`].
  local_path: function(target: string): boolean
  --- Answers with no body, 204 unless told: see [`Response.empty`].
  empty: function(status?: integer, opts?: Types.ResponseOptions): Types.Response
  --- Answers with a Reader body read as it is sent: see [`Response.stream`].
  stream: function(body: Stream.Reader, content_type: string,
      opts?: Types.ResponseOptions): Types.Response
  --- Answers with an RFC 9457 problem body: see [`Response.problem`].
  problem: function(status: integer, detail?: string, extra?: {string:any}): Types.Response
  --- Ends the request with an error status from anywhere, with a detail the
  --- error page shows; it returns a response only to type-check
  --- `return Web.abort(404)`: see [`Response.abort`].
  abort: function(status: integer, detail?: string, extra?: {string:any}): Types.Response
  --- Reads the first value of a response header, in any case: see [`Response.header`].
  header: function(res: Types.Response, name: string): string | nil
  --- Replaces a response header, whatever case it was set in; raises for
  --- `Set-Cookie`, which [`Web.add_header`] appends to: see [`Response.set_header`].
  set_header: function(res: Types.Response, name: string, value: string)
  --- Appends a line to a response header: a second `Set-Cookie` keeps the first,
  --- and a `Vary` token is merged into the line instead of repeated: see
  --- [`Response.add_header`].
  add_header: function(res: Types.Response, name: string, value: string)

  --- A route answering some methods at a pattern: see [`Route.route`].
  route: function(methods: string | {string}, pattern: string, handler: Types.Handler,
      opts?: Types.RouteOptions): Types.Route
  --- A route answering GET: see [`Route.get`].
  get: function(pattern: string, handler: Types.Handler, opts?: Types.RouteOptions): Types.Route
  --- A route answering POST: see [`Route.post`].
  post: function(pattern: string, handler: Types.Handler, opts?: Types.RouteOptions): Types.Route
  --- A route answering PUT: see [`Route.put`].
  put: function(pattern: string, handler: Types.Handler, opts?: Types.RouteOptions): Types.Route
  --- A route answering PATCH: see [`Route.patch`].
  patch: function(pattern: string, handler: Types.Handler, opts?: Types.RouteOptions): Types.Route
  --- A route answering DELETE: see [`Route.delete`].
  delete: function(pattern: string, handler: Types.Handler, opts?: Types.RouteOptions): Types.Route
  --- A prefix with routes below it: see [`Route.mount`].
  mount: function(prefix: string, routes: {Types.Route}, opts?: Types.MountOptions): Types.Route
  --- A prefix whose every request goes to one handler: see [`Route.mount_handler`].
  mount_handler: function(prefix: string, handler: Types.Handler,
      opts?: Types.MountOptions): Types.Route

  --- Middleware writing one line per request: see [`Stack.access_log`].
  access_log: function(opts?: Stack.AccessLogOptions): Types.Middleware
  --- A sink writing lines to standard error: see [`Stack.stderr_sink`].
  stderr_sink: function(name?: string): Types.Sink

  --- Compiles routes and middleware into an app: see [`App.new`].
  app: function(spec: Types.AppSpec): Types.App
  --- Serves an app until the server stops: see [`App.serve`].
  serve: function(app: Types.App, opts: Types.ServeOptions): boolean, string

  --- A client calling an app in-process: see [`Testing.test_client`].
  test_client: function(app: Types.App): Testing.Client
  --- Runs a test with a client in one event loop, the lifespan around it: see [`Testing.with_client`].
  with_client: function(app: Types.App, fn: function(client: Testing.Client))
  --- Runs a test with a client of the app served on the loopback: see [`Testing.with_server`].
  with_server: function(app: Types.App, fn: function(client: Testing.Loopback))
end

Web.key = Request.key
Web.html = Response.html
Web.json = Response.json
Web.text = Response.text
Web.redirect = Response.redirect
Web.safe_next = Response.safe_next
Web.local_path = Response.local_path
Web.empty = Response.empty
Web.stream = Response.stream
Web.problem = Response.problem
Web.abort = Response.abort
Web.header = Response.header
Web.set_header = Response.set_header
Web.add_header = Response.add_header
Web.route = Route.route
Web.get = Route.get
Web.post = Route.post
Web.put = Route.put
Web.patch = Route.patch
Web.delete = Route.delete
Web.mount = Route.mount
Web.mount_handler = Route.mount_handler
Web.access_log = Stack.access_log
Web.stderr_sink = Stack.stderr_sink
Web.app = App.new
Web.serve = App.serve
Web.test_client = Testing.test_client
Web.with_client = Testing.with_client
Web.with_server = Testing.with_server

--- Compiles `routes` into a router without an app, for tests and for
--- generated modules: `router:match(method, path)` says what an app would
--- do, and `router:reverse(name, params)` builds a URL. A route that cannot
--- be registered raises, naming the pattern. See [`Web.get`] for patterns.
--- @param routes {Types.Route} The routes
--- @param opts RouterOptions | nil The trailing-slash policy
--- @return Types.Router The router
function Web.router(routes: {Types.Route}, opts?: Types.RouterOptions): Types.Router
  local policy: Types.TrailingSlash = nil
  if opts ~= nil then policy = opts.trailing_slash end
  return Router.build(routes, function(_req: Types.Request): Types.Response
    error("web: a router built by Web.router has no app to answer with", 0)
  end, policy)
end

return Web
