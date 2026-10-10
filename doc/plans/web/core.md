# cosmic.web: the core (Request, Response, Router, typed routes, middleware, App, testing)

Part of the cosmic.web design: see ../web.md for the overview, decisions and phasing.

This file designs the spine of `cosmic.web`: everything an application
needs to turn a [`Server.Request`] into a [`Server.Reply`] through a routing
table and a middleware stack. Input binding, cookies, sessions, CSRF, CORS
and security headers are input.md; templates and the htmx dialect are
templates.md; assets, SSE and the dev loop are assets.md. They plug into
the seams defined here and are referred to by file and section.

Facts read from the tree are cited as path:line.

## 1. Starting points and departures from Starlette

What the tree already gives us:

- [`Server.serve`] calls one `handle: function(Request): Reply` per request,
  in the connection's task (cosmic/http/server.tl:571, 395). Everything
  cooperative: a read of `req.body`, a [`Poll.delay`], a `Net` wait yields;
  SQLite and [`Http.get`] block every connection (server.tl:561-566).
- A raise in `handle`, or a reply `reply_trouble`/[`wire.check`] refuses, is
  answered 500 (plain text) and the trace goes to `ServeSpec.on_error`
  (server.tl:411-428).
- HEAD arrives as HEAD; the handler answers as for GET and the server drops
  the body (server.tl:31-37).
- `req.path` is the still-escaped path, `req.query` the still-escaped query
  (server.tl:43-45); [`cosmic.url`] has `escape`, `unescape`, `segments` and
  no query decoding (cosmic/url.tl:86-131, doc/roadmap.md:243).
- [`Shape.into`] does no string coercion: `integer` refuses `"1"`
  (cosmic/shape.tl:59-61); input.md section 3 therefore owns the
  spec-directed binder that typed routes call.

Where this design departs from Starlette, and why:

- No ASGI-style scope/receive/send. Starlette's `Request` wraps a scope and
  its `Response` is a callable ASGI app. Here `Handler` is plain
  `function(Request): Response` and `Response` is a data record. Teal types
  and cosmic's `Server` already provide the plumbing ASGI exists to
  standardise. Middleware is therefore `function(Handler): Handler` over
  records, not "pure ASGI" classes, and cannot see the connection.
- `Response` is [`Server.Reply`] itself (an alias, section 3), not a second
  class: zero conversion and the server's validation applies unchanged.
- One `Route` record covers both leaf routes and mounts (Teal cannot
  discriminate a union of two table types), built by `Web.route`/`Web.get`
  and `Web.mount`.
- Routing is by specificity, not declaration order (section 5). Starlette
  matches first-declared; that makes route order a hidden input and a
  file-based generator would have to sort. Here order never matters.
- Path parameters carry no converter syntax (`{id:int}`). Types come from
  [`cosmic.shape`] specs attached to the route (section 6), so the pattern
  stays a plain string usable for reverse routing and for a generator.
- Typed handlers: the type flows through a generic constructor
  (`Web.route_typed<P,Q,B>`), the Teal answer to FastAPI's signature
  inspection.
- The error middleware sits innermost, not outermost (section 8), so
  middleware such as CORS and logging see the 500 the handler produced.
- No `BackgroundTask`: spawn with [`Poll.spawn`] (a task outlives the
  request; document, don't wrap).
- No per-request threads, so no sync-handler thread pool story: a handler
  that blocks stalls the server, as server.tl:561 says. The docs repeat it.

## 2. Request

`Web.Request` wraps the server's request. It is created once per request by
`Web.App` and is mutable by middleware (`state`, `params`), nothing else.

```teal
local record Web
  record Request
    --- The server's request, for anything not lifted below.
    raw: Server.Request
    --- "GET", "POST", ... as sent. A HEAD stays "HEAD" although the route
    --- matched is the GET's.
    method: string
    --- The canonical path, still %-escaped, relative to the application
    --- root (see `mount_path`). Never holds an empty or "." segment; see 5.4.
    path: string
    --- The decoded segments of `path`: {"items", "a b"} for /items/a%20b.
    --- Authorization middleware compares these, never `raw.path`.
    segments: {string}
    --- The escaped query string as sent.
    query_string: string
    --- Lowercased names; same joining as Server.Request.headers, except
    --- `cookie`, joined with "; " (wire.tl:434, see 13.2).
    headers: {string:string}
    --- Path parameters matched, decoded, all strings; typed routes get a
    --- record as well (section 6). Mounts add their own (none in v1).
    params: {string:string}
    --- The prefix of the Mount that is serving this request ("" at the top).
    mount_path: string
    --- The route matched: its name, pattern and options; nil in a 404/405.
    route: Web.RouteInfo
    --- The app serving this request (for url_for, state, config).
    app: Web.App
    --- The untyped escape hatch for ad-hoc scratch values. Shipped
    --- middleware (sessions, CSRF, the CSP nonce, htmx, request id) use
    --- typed keys instead, see 2.3.
    state: {string:any}
    --- The peer, or nil where unknown. See 13.3.
    client: Web.Client
    --- "http"; "https" only when a trusted-proxy middleware (TODO, not v1)
    --- sets it from X-Forwarded-Proto.
    scheme: string
  end
  record Client
    host: string
    port: integer
  end
end
```

Methods (functions taking the request, in cosmic's usual `function(self, ...)`
style, all failure-returning as `nil, reason`):

```teal
header:    function(self: Request, name: string): string | nil     -- case-insensitive
text:      function(self: Request): string | nil, string
bytes:     function(self: Request): string | nil, string
accepts:   function(self: Request, offers: {string}): string | nil
url_for:   function(self: Request, name: string, params?: {string:string|integer},
                    query?: {string:string}): string | nil, string
get:       function<T>(self: Request, key: Web.Key<T>): T | nil
set:       function<T>(self: Request, key: Web.Key<T>, value: T)
```

### 2.1 Lazy decoding

Nothing is decoded until asked, and each result is cached on the request.
The request has no decoding methods of its own beyond the raw body: query,
urlencoded form, JSON and multipart decoding are `cosmic.web.input`'s
(`Input.query(req)`, `Input.form(req)`, `Input.json(req)`,
`Input.multipart(req)`; input.md sections 1 and 2), which keeps the
request type free of a dependency on the decoder. They share the decoder
[`Url.decode_query`] (input.md section 1, 13.5 here) and cache their results
under exported keys (`Input.QUERY`, `Input.FORM`, `Input.JSON`, 2.3), so a
middleware and the handler share one decode. Rules that bind the core:

- A malformed percent-escape in a query or urlencoded body is
  undecodable input: 400, in both (the status rules are in 6.4;
  input.md section 1 has the decoder's rule). A query is not decoded
  leniently.
- `bytes()`/`text()`: the body read once, bounded by `limits.body_bytes`
  and the route's `body_limit` (13.4). Reading twice returns the cached
  string. The cached bytes are also put back as `req.raw.body`
  ([`Stream.from_string`]), so a later `Input.form` or a handler reading
  `req.raw.body` still sees them. A handler streaming an upload uses
  `req.raw.body` and never calls the helpers.
- Cookies: the cookie jar is `cosmic.web.cookies` (input.md section 6). Core
  guarantees only that `req:header("cookie")` is the single joined line
  (13.2) and that `Web.Response` can carry several Set-Cookie lines (13.1).

### 2.2 Client info

`req.client` comes from the connection's peer address. Core exposes it only
where `Server.Request.peer` exists (13.3). `X-Forwarded-For` is never read
by default. `Web.app{ trusted_proxy = true }` (off by default; ../web.md,
open question 4) makes `req.scheme`, `req.host` and `req.client` come from
`X-Forwarded-Proto`, `X-Forwarded-Host` and `X-Forwarded-For`. Reason:
spoofable by default is worse than absent.

### 2.3 Per-request state

Starlette's `request.state` is an attribute bag. Teal has no attribute bag,
and string keys collide between middleware. So per-request state is typed
keys; the session, the CSRF token, the CSP nonce, htmx's parsed request and
the decoded input are each an exported key (`Session.KEY`,
`Headers.NONCE`, `Htmx.KEY`, `Input.QUERY` and the like in their modules),
never a field of `req.state`:

```teal
local record Key<T>  name: string end
function Web.key<T>(name: string): Web.Key<T>

-- in the session middleware's module:
local SESSION <const> = Web.key<Session>("session")   -- exported
-- in the middleware:    req:set(SESSION, session)
-- in a handler:         local s = req:get(SESSION)
```

`Key` identity is by the table (two `Web.key` calls with one name are two
keys), stored internally as `state[key]` so collisions are impossible. The
public `req.state: {string:any}` exists only as the untyped escape hatch
for ad-hoc use; shipped middleware (sessions, CSRF, the CSP nonce, htmx,
request id) use keys. `get` casts
`any` to `T` once, inside web, with the "cast:" comment shape.lua uses
(cosmic/shape.tl:501). A key is a value, not a global: a module exports its
key, and `Web.App` itself has an `app.state` of the same kind for lifespan
resources (section 9.3).

## 3. Response

`Web.Response` is [`Server.Reply`]:

```teal
type Response = Server.Reply
type Handler = function(Request): Response
type Middleware = function(Handler): Handler
```

Constructors build the table Server expects; none touches the connection.
Every constructor takes a trailing `opts?: Web.ResponseOptions`
`{ status?, headers?, close? }` so any can override status and add headers.

```teal
function Web.html(body: Html.SafeHtml, opts?): Response
function Web.json(value: any, opts?): Response
function Web.text(body: string, opts?): Response
function Web.redirect(location: string, opts?): Response   -- status default 303
function Web.empty(status?: integer, opts?): Response      -- default 204
function Web.stream(body: Stream.Reader, content_type: string, opts?): Response
function Web.file(req: Request, path: string, opts?: Web.FileOptions): Response
function Web.problem(status: integer, detail?: string, extra?: {string:any}): Response
```

Behaviours and edge cases:

- `html` takes only [`Html.SafeHtml`] (cosmic/html.tl:46), unwrapped with
  [`Html.raw`]. A plain string does not type check. The escape hatch is
  [`Html.trust`], which is greppable. `Content-Type: text/html; charset=utf-8`.
- `json` encodes with [`Json.encode`]. Encode failure (a cycle, a function)
  is a programming error: it raises, the error middleware answers 500.
  `Content-Type: application/json` (no charset; it is UTF-8 by definition).
  [`Json.array`] and [`Json.null`] follow cosmic.json's rules, nothing added.
  Always sets `X-Content-Type-Options: nosniff` (cheap and always right for
  API bodies).
- `text`: `text/plain; charset=utf-8`, plus nosniff.
- `redirect`: default 303 See Other (right after a POST; htmx follows it).
  `opts.status` accepts 301/302/303/307/308. `location` is validated:
  it must be a path starting with exactly one `/` (not `//`, not `/\`), or
  an absolute `http:`/`https:` URL ([`Url.parse`]), and hold no control
  byte; otherwise it raises. This is the guard against open redirects in
  `Web.redirect(req:query():get("next"))`: that call raises (500) for
  `next=//evil.com`; apps must pass user input through
  `Web.safe_next(input, default)`, which returns `default` unless the input
  is a local path. (Safe by default rather than by memory.)
- `empty`: no body, no Content-Type. Default 204; `status = 200` gives an
  empty 200 with `Content-Length: 0` from the server.
- `stream`: body is a [`Stream.Reader`]; no length means chunked
  (HTTP/1.0 clients: close-delimited), see server.tl:96-98. The Reader is
  read cooperatively and closed by the server when sent or abandoned
  (server.tl:93-94, 363-373): a client disconnect surfaces as a failed
  write, `close` on the reader, and an `on_error` report. SSE
  (`Sse.EventStream`, assets.md section 5) is `stream` with
  `text/event-stream`, `Cache-Control: no-cache, no-transform` and a
  Reader over the channel; it adds no server feature.
- `file`: opens `path`, [`Stream.open`], sets `Content-Length` from stat,
  weak ETag from size+mtime unless `opts.etag`, `Last-Modified`, answers
  304 via [`Server.none_match`] (server.tl:747) and Range via [`Server.range`]
  (server.tl:678) for GET only. `FileOptions`: `content_type` (default
  `Mime.of(name)` from cosmic.web.mime, assets.md section 1.4;
  octet-stream if unknown), `download_name` (sets `Content-Disposition:
  attachment; filename*=UTF-8''<escaped>`), `cache_control`. Path
  containment is the caller's (`StaticFiles` in assets.md section 3 checks
  segments with [`Url.segments`]); `Web.file` takes a path the app trusts and
  says so.
- `problem(status, detail, extra)`: RFC 9457 `application/problem+json`
  `{type:"about:blank", title:<reason>, status, detail, ...extra}`. Used by
  the validation and error layers, public for API handlers. For invalid
  input `extra.errors` is filled from `Input.Invalid` (6.4).

Header helpers, because the type admits lists (section 13.1) and names
are case-preserving. `Web.add_header` is the one way every part appends a
header, whether a `Set-Cookie` line or a `Vary` token:

```teal
function Web.header(res: Response, name: string): string | nil   -- first value, any case
function Web.set_header(res: Response, name: string, value: string)   -- replaces all cases
function Web.add_header(res: Response, name: string, value: string)   -- appends
```

`add_header` promotes a string value to `{old, new}`. A response built by a
constructor always has a `headers` table, so middleware never nil-checks.
`Vary` is merged rather than repeated: `add_header(res, "Vary", "Cookie")`
adds the token to the existing `Vary` line unless it is already listed
(case-insensitively), and a `Vary: *` absorbs everything; `Cookies.set`
(input.md section 6), `Htmx.page` (templates.md section 6.4), the CORS and
session middleware and `StaticFiles` all go through it. Every other name
gets a line of its own. `Set-Cookie` MUST use `add_header`; `set_header` on
it replaces every cookie, and the helper raises for `Set-Cookie` to say so
(use `Cookies.set`, which calls `add_header`).

Mapping to [`Server.Reply`] is the identity; nothing is copied, so a
middleware that mutates `res.headers` after `next(req)` is cheap.

## 4. Handler shapes and the plain (untyped) route

```teal
Web.get("/health", function(req: Web.Request): Web.Response
  return Web.json({ ok = true })
end)

Web.get("/items/:id", function(req)
  local item = db:find(req.params.id)       -- string
  if item == nil then return Web.abort(404) end
  return Web.html(views.item.render({ item = item }))
end, { name = "item" })
```

`Web.abort(status, detail?, extra?)` raises a tagged table
(`{ web_abort = true, status, detail }`), never returns, and is declared to
return `Response` so `return Web.abort(404)` type checks (Teal has no
bottom type). The exception middleware (8.2) turns it into the error
response for the request's `Accept`. Raising is the one place web uses a
raise for a request-level outcome; it is the analogue of Starlette's
`HTTPException` and keeps deeply nested helpers from threading
`Response | nil, err` upward. Everything else (a bad read, a decode) is
`nil, reason`.

## 5. Routing

### 5.1 Declaring routes

```teal
record Route                      -- one record for leaf and mount
  methods: {string}               -- {} for a mount
  pattern: string                 -- "/items/:id"; a mount's prefix
  handler: Handler                -- nil for a mount
  name: string
  middleware: {Middleware}        -- this route's / mount's own
  input: Web.Input                -- typed-input metadata, section 6; nil if untyped
  on_invalid: function(Web.Request, Input.Invalid): Web.Response   -- section 6.4; nil: the default
  body_limit: integer
  mount: Web.Router               -- non-nil for a mount
  kind: string                    -- "http" now; "websocket" reserved
end
record RouteOptions
  name: string
  middleware: {Middleware}
  body_limit: integer
  --- Answers input that fails the route's specs (6.4); `Input` is
  --- cosmic.web.input (input.md section 2). Core owns the hook.
  on_invalid: function(Web.Request, Input.Invalid): Web.Response
end

function Web.route(methods: string | {string}, pattern: string, handler: Handler,
                   opts?: RouteOptions): Route
function Web.get/post/put/patch/delete(pattern, handler, opts?): Route
function Web.mount(prefix: string, routes: {Route}, opts?: MountOptions): Route
```

`MountOptions` = `{ name, middleware, reverse }` (`reverse` is 5.7's resolver,
used by `mount_handler`). A `Router` is built from a list
of Routes by `Web.router(routes, opts?)` (what `Web.App` does internally,
exposed for tests and for generated modules that return a router). All
registration errors raise at construction, naming the pattern: they are the
program's bug, not the data's (same convention as `Shape`'s spec errors,
cosmic/shape.tl:155-163).

Why constructors, not an object with `:add`: the table is data; it can be
returned from a module, concatenated, and produced by a generator.

```teal
local routes = {
  Web.get("/", home, { name = "home" }),
  Web.get("/items", list_items, { name = "items" }),
  Web.route({"GET", "POST"}, "/items/new", new_item),
  Web.get("/items/:id", show_item, { name = "item" }),
  Web.get("/static/*path", serve_static),
  Web.mount("/api", api_routes, { name = "api", middleware = { Web.cors(...) } }),
}
```

### 5.2 Pattern syntax

- Literal segments: `/about`, `/api/v1/items`. Case-sensitive.
- `:name`: one non-empty segment, percent-decoded. Name matches
  `[A-Za-z_][A-Za-z0-9_]*`, unique within the pattern.
- `*name`: must be last; matches zero or more remaining segments, decoded
  and rejoined with `/` (so it never contains `..`; [`Url.segments`] already
  refused those, cosmic/url.tl:131-153). Empty string when none. A
  segment cannot mix literal and param (`/items/id-:id` is a registration
  error): keeps reverse routing and generation trivial.
- No regexes, no optional segments, no inline converters. A route needing
  `:id` to be an integer says so in its spec (section 6).
- The pattern is the whole path. The root is `/`. A pattern must start
  with `/` and holds no empty segment; it need not end without `/` (see
  5.3).

### 5.3 Trailing slash policy

Patterns are written without a trailing slash (except `/`) and that form
is canonical. `Web.App.trailing_slash`:

- `"redirect"` (default): a request for `/items/` when `/items` would
  match is answered 308 to `/items` (query kept; method kept, so a POST
  survives). The reverse (pattern ends in `/`, request lacks it) is the
  same. Only when the other spelling matches; otherwise 404. This is
  Starlette's `redirect_slashes`, with 308 rather than 307 to match its
  meaning ("permanent, method preserved") and for caches.
- `"strict"`: no redirect, `/items/` is 404.

`*rest` patterns swallow the slash (`/static/` matches `/static/*path` with
`path = ""`), so no redirect arises for them.

### 5.4 Canonical paths (a security rule)

Before matching, the router parses `raw.path` with [`Url.segments`]:

- `..` or an encoded `/` or NUL in a segment: [`Url.segments`] returns
  `nil, why` and the router answers 400 (not 404: the request is malformed).
- An empty segment (`//a`) or a `.`/`%2e` segment is normalised away by
  [`Url.segments`] (cosmic/url.tl:137-152). If that changed the path, the
  router answers 308 to the canonical form, built from the decoded
  segments re-escaped with [`Url.escape`], always starting with exactly one
  `/`. Because the Location is rebuilt from segments, a request for
  `//evil.com/` redirects to `/evil.com/`, never to the protocol-relative
  `//evil.com/`: no open redirect.
- `req.path` and `req.segments` are set from this canonical form, before
  any middleware... but note middleware runs *outside* the router (8.1).
  To keep the invariant, canonicalisation happens in `App.handle` before
  the middleware stack, not inside `Router`. Authorization middleware that
  matches `/admin` against `req.path` therefore cannot be bypassed by
  `//admin` or `/a/../admin`, and cannot disagree with the router.
- Percent-encoding variance (`%7e` vs `~`) does not trigger a redirect;
  `segments` are decoded either way, so matching is on decoded text.

### 5.5 Matching

At construction the router compiles routes to a trie keyed by segment:
literal children, at most one param child, at most one wildcard leaf, each
node holding `{method: Route}`. Specificity: at each segment prefer a
literal child, then the param child, then the wildcard, backtracking if
the preferred branch has no route for the remaining path. So
`/items/new` always beats `/items/:id` whatever the declaration order.

Registration refuses (raises): two routes with the same method and the same
shape (`/a/:x` and `/a/:y` are one shape), duplicate route names in one
router, a pattern that is not valid (5.2), `*name` not last, a
mount whose prefix has params in v1 (reason: reverse routing and the trie
stay a plain prefix; a generator emits a nested mount directory anyway),
and any user route or mount at or under the reserved prefix `/_web/`, where
cosmic.web serves its built-in assets (the vendored htmx, the dev reload
script; assets.md sections 4.4 and 6.4). `Web.app` adds those routes
itself, so the prefix is the app's, never a user's.

Result of a lookup is one of: `match(route, params)`, `method_not_allowed(allow)`,
`not_found`.

- Method not allowed: the path matches at least one route but not this
  method. The response is 405 with `Allow` (sorted, comma-separated) and
  an error body via the error layer (8.3). If any GET exists, `HEAD` is in
  `Allow`; `OPTIONS` is always in `Allow`.
- Automatic HEAD: `HEAD` with no explicit HEAD route dispatches to the GET
  route. The handler runs with `req.method == "HEAD"`; the server sends the
  head the GET would and drops the body (server.tl:31-37). A route can
  declare `HEAD` itself for the size-only form.
- Automatic OPTIONS: `OPTIONS` with no explicit OPTIONS route is answered
  204 with `Allow`. CORS preflight is the CORS middleware's, positioned
  outside the router (8.1) so it answers before this fallback.
  `OPTIONS *` (server.tl:43) gets 204 `Allow: GET, HEAD, POST, ...` of the
  app's union.
- 404: `not_found` handled by the error layer (8.3).

### 5.6 Mount

`Web.mount("/admin", routes, opts)` makes a sub-router. The mount prefix
consumes literal segments; the sub-router sees the rest (it matches against
`segments` beyond the prefix). In the sub-router `req.mount_path` is
`"/admin"` while `req.path` stays full (Starlette's `root_path` + `path`
split, but `path` is not rewritten, so logging and CSRF see the full path).
A mount has no fallthrough: once the prefix matches, the sub-router's 404
is the answer (deterministic; no ordering dependence). Mount-scoped
middleware (`opts.middleware`) wraps the sub-router's dispatch, so a 404
or 405 produced inside it passes through it (an `/api` CORS mount decorates
`/api/nope`'s 404). Mounted routers may themselves contain mounts.

A mount may also serve a foreign handler: `Web.mount_handler(prefix, handler,
opts)` sends everything under prefix to a `Handler` (what `StaticFiles` in
assets.md section 3 is). It is a Route with `mount.fallback = handler`.
Its `opts.reverse` is the mount's reverse resolver (5.7).

### 5.7 Reverse routing: `url_for`

Each router records `name -> pattern chain`. A mount's name prefixes the
inner names with `:` (`api:item`), as Starlette does. A handler-mount
(`Web.mount_handler`) has no inner routes to name; instead it may carry a
reverse resolver, so a name that is a mount's reaches it:

```teal
record MountOptions
  ...
  --- Answers `url_for(<mount name>, params)`: the full URL given the
  --- mount's own full prefix (outer mounts included) and the params.
  --- nil and why for params it cannot resolve.
  reverse: function(prefix: string, params: {string:string}): string | nil, string
end
```

`StaticFiles` supplies one (`StaticFiles.mount(prefix, opts?)` in assets.md
section 3.1 builds the Route with it), so
`app:url_for("static", { path = "css/app.css" })` calls
`StaticFiles:url(prefix, "css/app.css")` and returns the fingerprinted
`/static/css/app.3f9a1c8e2b.css`. A mount with no resolver answers
`nil, 'url_for: mount "x" has no reverse'`.

`Router:reverse(name, params?, query?)` is the router-level primitive;
`app:url_for` and `req:url_for` call it (a request adds nothing but the
convenience).

```teal
req:url_for("item", { id = 42 })              -- "/items/42"
req:url_for("api:item", { id = "a b" }, { v = "2" })  -- "/api/items/a%20b?v=2"
```

`app:url_for(name, params, query)` is the same without a request (a
mount's prefix is part of the chain, so no request needed). Rules:
every `:param` must be given (`nil, 'url_for "item": missing id'`); extra
params are an error (typos should not be silent); integer values are
formatted `%d`; `*rest` values are split on `/` and each segment escaped;
`:param` values are escaped with exactly the escaper [`Html.url_part`] uses
(the C function behind it, core/html.c; templates.md section 3), `/`
included, so a slash in an id cannot change the route, and a value that is
exactly `.` or `..` comes out as `%252E`/`%252E%252E` so it cannot become a
dot segment. That escaper writes the same bytes as [`Url.escape`]
(cosmic/url.tl:86) for every input but those two values; there is one
escaper in the web layer, and a test pins [`Url.escape`], [`Html.url_part`] and
`Router:reverse` together on a table of hostile values (the same test
templates.md section 8 describes). `query` encodes `name=value` pairs with
it, in sorted order (deterministic for tests). Unknown name: `nil, 'url_for: no route named "x"'`.

Result is a relative path, always starting with `/` and never `//`: safe as
a URL in a template slot (templates.md sections 3 and 7). A template reaches
`url_for` through a stage over an application module of typed builders
(templates.md section 7), or through its data record (e.g. `urls:
function(string, {string:string}): string`): templates are typed and use no
global. Convenience: `Web.urls(req): Web.Urls`, a record `{ for_:
function(...) }` bound to the request, so the template data holds one
field. Failing to resolve in a template should be loud; a `Urls.must`
variant raises (a template build mistake), `url_for` returns `nil, why`.

An absolute URL builder (`req:base_url()`) is deliberately omitted until a
`trusted_hosts` list exists: building from the `Host` header is a
host-header-injection hole (password reset links). `App.trusted_hosts`
(list of host strings) is a v1 field; if set, a request whose Host is not
in it is answered 400, and `req:base_url()` returns scheme + Host.

### 5.8 What a file-based router generates

The table above is the target of a generator. A page file
`routes/items/[id].tl` maps to `Web.get("/items/:id", mod.GET, {name = "items.id", input = mod.INPUT})`,
a directory to a `Web.mount`, `[...rest]` to `*rest`. Nothing in the
runtime depends on declaration order (5.5), names are plain strings, and
types attach through `opts.input`, which a generated file can write as
the module's `SPEC` constant. A generated `routes.tl` is `return {...}`
of `Route`s and is consumed as `Web.App{ routes = require("routes") }`.
That layer is a roadmap item.

## 6. Typed routes

### 6.1 The problem

Teal is nominal and statically typed: a route table is heterogeneous (each
route has its own record types), but a table value is a single type.
Strategy: the generic is resolved at the call that constructs a route, and
the result is erased to the non-generic `Route` whose `handler` closes over
the parsing.

### 6.2 API

```teal
record Input<P,Q,B>     -- built by Web.input
  path:  Shape.Typed<P>
  query: Shape.Typed<Q>
  body:  Web.Body<B>
end
record Body<B>
  kind: string           -- "json" | "form"
  typed: Shape.Typed<B>
end

Web.NONE: Shape.Typed<Web.None>     -- record None end; the absent slot
function Web.json_body<B>(t: Shape.Typed<B>): Body<B>
function Web.form_body<B>(t: Shape.Typed<B>): Body<B>
function Web.input<P,Q,B>(path: Shape.Typed<P>, query: Shape.Typed<Q>, body: Body<B>): Input<P,Q,B>

function Web.route_typed<P,Q,B>(methods: string | {string}, pattern: string,
    input: Input<P,Q,B>, fn: function(Request, P, Q, B): Response, opts?): Route
-- sugar: Web.get_typed, Web.post_typed, ...
```

The three slots are positional with `Web.NONE`/`Web.no_body` fillers: the
handler always has `(req, p, q, b)`. (`Web.input` builds this bundle; it is
unrelated to the module `cosmic.web.input`, which it calls.) Alternatives considered: one merged
record (collisions between path, query and body names and no way to say
where a bad value came from); optional slots with overloads (Teal cannot
infer a generic that is never mentioned). Inference needs a spike: Teal
infers `P` from a `Shape.Typed<P>` argument (that is how `record_of`
works, cosmic/shape.tl:111-119, 580); the spike in step 1 of the build
order must confirm it also infers across `Input<P,Q,B>` into the function
parameter list, else fall back to explicit type arguments in the
constructor (`Web.route_typed<ItemPath, ItemQuery, ItemBody>(...)`), which
is uglier but certain.

```teal
local record ItemPath   id: integer end
local record Listing    page: integer | nil  tag: {string} | nil  sort: string | nil end
local record NewItem    title: string  qty: integer end
local PATH  <const> = Shape.record_of("ItemPath")
local QUERY <const> = Shape.record_of("Listing")
local NEW   <const> = Shape.record_of("NewItem")

Web.get_typed("/items/:id", Web.input(PATH, QUERY, Web.no_body),
  function(req, p: ItemPath, q: Listing, _): Web.Response
    return Web.json(db:find(p.id, q.page or 1))
  end, { name = "item" })

Web.post_typed("/items", Web.input(Web.NONE, Web.NONE, Web.json_body(NEW)),
  function(req, _, _, b: NewItem): Web.Response
    local id = db:insert(b.title, b.qty)
    return Web.json({ id = id }, { status = 201,
      headers = { Location = req:url_for("item", { id = id }) } })
  end)
```

(The parameter types of the handler are inferred from `input`; the
annotations above are for reading. `record_of` requires its string-literal
form and the build to rewrite it, cosmic/shape.tl:554-574, so a route
module is a normal built module.) A route may add `on_invalid` in its
options (6.4).

### 6.3 What is checked, and how strings become typed

Shape does not coerce (shape.tl:59), and path parameters, query values and
urlencoded form fields are all strings. Typed routes therefore bind through
`cosmic.web.input`'s spec-directed binder (input.md section 3), not through
a coercion pass of their own:

- Path: the matched `params` become a [`Url.Query`] (names are unique) and go
  through `Input.bind_strings(q, spec, { source = "path" })`, so path, query and
  form coerce by one set of rules (input.md section 3, "Coercion rules").
- Query: `Input.query_into(req, spec)`; urlencoded form body:
  `Input.form_into(req, spec)`; JSON body: `Input.json_into(req, spec)`,
  which is [`Shape.into`] over the decoded value (input.md section 5).
- The binder collects every field's error and ends with [`Shape.into`] on the
  coerced tree as the final check, so the typed record the handler gets is
  exactly what Shape produces. A failure is an `Input.Invalid` (fields in
  6.4), with all errors for the source in `errors`.
- Multipart bodies are `Input.multipart_into` (input.md section 4, step 7
  of ../web.md's order); a route names it with a
  `Web.multipart_body(t)` body slot once that lands.
- Unknown query/form keys are ignored (the spec is the allow-list), as
  input.md section 3 states; `Web.strict(typed)` is not provided in v1
  (shape has a TODO for a strict `Typed`, shape.tl:581).

Registration checks: every `:param`/`*param` name in the pattern is a field
of the path spec (string, integer, boolean or one_of kind only) and the
other way round; a spec a flat string source cannot carry is refused by
`Input.check_spec` (input.md section 3); a body spec only on methods that
take one (POST, PUT, PATCH, DELETE; a GET with a body spec raises).

### 6.4 Failure responses and `on_invalid`

Order of checks: path, then query, then body. The first source that fails
ends the request; within a source the binder has collected every field.

Statuses (the same set everywhere in cosmic.web; the overview's open
question 1 is about the last row of this list):

- Undecodable input (a bad percent-escape, malformed JSON, bad multipart
  framing): 400.
- Wrong Content-Type for the body the route declares: 415.
- Over the body limit: 413 (the server answers; web maps the read failure
  to `abort(413)` so middleware sees it).
- A value that decodes but fails its shape spec: 422 (../web.md, decision
  7), which the shipped htmx config swaps (templates.md section 6.6).

A route that wants the re-render passes `on_invalid` (`RouteOptions` and
`Route`, 5.1): `function(Web.Request, Input.Invalid): Web.Response`. Core
calls it in place of the default answer, for any `Input.Invalid` the route's
specs produced, with the request, so the hook can branch on
`Htmx.request(req).active` or on `Accept`. The handler is then not called.

`Input.Invalid` is defined in input.md section 2: `status`, `message`,
`errors: {Input.FieldError}` and the submitted values for a re-render. Its
`FieldError` has the fields `source` ("path", "query", "form" or "body"),
`field` (the dotted name, `"address.city"`, `""` for the whole body),
`pointer` (the JSON Pointer of a failing JSON body value, nil for the other
sources), `message` and `code`. Without `on_invalid` the answer depends on
`req:accepts{"text/html","application/json"}`: the list order is
`{"application/json","text/html"}` when the route has a JSON body spec and
`{"text/html","application/json"}` otherwise, ties broken by that order.

JSON (`application/problem+json`, built by `Web.problem` with `errors`
filled from `Input.Invalid.errors`):

```json
{"type":"about:blank","title":"Unprocessable Content","status":422,
 "detail":"qty: expected integer, got \"x\"",
 "errors":[{"source":"body","field":"qty","pointer":"/qty",
            "message":"expected integer, got \"x\"","code":"integer"}]}
```

`errors` holds every failed field of a path, query or form source, and one
entry for a JSON body in v1, because [`Shape.into`] reports only the first
failure of a JSON value (input.md section 5). It is a list so a later
collect-all mode in Shape changes no client.

HTML: a small page from `App.error_view` (section 8.3), by default a
minimal self-contained document with the status and `detail` escaped
([`Html.escape`]). For an htmx request the page should be a fragment; that is
what `error_view` and `on_invalid` are for, and both get the `Request` to
branch on `HX-Request`. (htmx by default does not swap 4xx; templates.md
section 6.7 covers the swap config.)

### 6.5 Why this stays generatable

The typed constructor is `Web.route_typed(methods, pattern, input, fn, opts)`.
A file-based layer emits calls to exactly that, with `input` taken from a
`SPEC` export of the route file; the types (`P`,`Q`,`B`) come from the
same file's `record_of` declarations, so the generator never needs to
know Teal types, only names to paste. No decorator or registration side
effect exists.

## 7. Middleware

### 7.1 Model and ordering

```teal
type Handler    = function(Request): Response
type Middleware = function(Handler): Handler
```

`App.middleware = { A, B, C }`: A is outermost (sees the request first and
the response last), as Starlette's list. Composition folds from the end:
`h = router_dispatch; for i = #mw, 1, -1 do h = mw[i](h) end`. A
middleware is a function, typically returned by a factory:

```teal
function Web.timing(): Web.Middleware
  return function(next: Web.Handler): Web.Handler
    return function(req: Web.Request): Web.Response
      local t0 = Clock.monotonic_ns()
      local res = next(req)
      Web.set_header(res, "Server-Timing", ("app;dur=%d"):format((Clock.monotonic_ns() - t0) // 1000000))
      return res
    end
  end
end
```

Layers, outside to inside:

1. `Web.App.handle`: canonicalise the path (5.4), build the `Request`,
   host check.
2. The app's `middleware` list, in order.
3. Router dispatch: match -> per-mount middleware -> per-route middleware
   -> route handler. Unmatched becomes the 404/405 (8.3) *here*, so the
   app-level stack sees them.
4. The exception layer (8.2) wraps (3) tightly; hence it is inside user
   middleware, and the response it makes for a raise travels back out
   through them.

A mount's middleware wraps that mount's sub-router; a route's wraps its
handler; both are `function(Handler): Handler` lists with the same order
rule. The order "app > mount > route" is fixed.

Middleware may short-circuit by returning without calling `next` (auth,
CORS preflight, rate limit), may change the request (`req:set`), and may
post-process the response (`add_header`). It must not read `res.body` if
it is a Reader (the gzip middleware wraps it with [`Stream.transform`],
stream.tl:655, and drops `Content-Length`).

### 7.2 Which pieces are middleware

Shipped in core: `Web.access_log`, `Web.timing`, `Web.request_id`
(sets `X-Request-ID` and a key), `Web.trusted_hosts` (also an App field),
`Web.limit_body(n)`. Others by their modules: sessions (`cosmic.web.session`),
CSRF (`cosmic.web.csrf`), CORS (`cosmic.web.cors`), security headers
(`cosmic.web.headers`) and htmx (`cosmic.web.htmx`), all in input.md and
templates.md. A gzip middleware is named by assets.md (it must skip
`text/event-stream` and already-encoded responses) but no part designs it:
open question 13. Because a middleware is just a function, user code mixes
freely.

### 7.3 WebSocket seam (designed-for only)

Nothing is built; the places are reserved so adding it later is additive:

- `Route.kind = "http"`, with `"websocket"` reserved; a `Web.websocket(pattern,
  fn)` constructor would produce a route of that kind.
- The router already distinguishes handler results by returning a
  `Response`; an upgrade is a `Response` with a new [`Server.Reply`] field
  `take: function(conn: Net.Conn, rest: string)` (assets.md section 7),
  status 101 allowed only with it. The server writes the head, then calls
  `take` in the connection's task with any bytes it had read past the head,
  and closes the connection when it returns. This is a `server.tl` change
  (reply_trouble, wire.check admit 101 + take) not
  made in v1; write the TODO in `server.tl`'s status check: "once
  cosmic.web's WebSocket support needs a connection handed over".
- `Request` has `raw` and (once `Server.Request.conn` exists) the socket;
  middleware that must not apply to upgrades checks `req.route.kind`.
- Middleware is `Handler -> Handler`, so an upgrade passes through
  logging, sessions, CSRF unchanged; a middleware that rewrites bodies
  (gzip) must skip a response with `take`. The `Middleware` doc says so.

## 8. Errors

### 8.1 Where the layer sits

Starlette puts its error middleware outermost, so CORS and session
middleware never see the 500. Here two layers cooperate:

- Inner (8.2): inside the user stack, catches raises from handlers and
  route middleware, produces a `Response`.
- Outer: the server itself (server.tl:411-415) catches anything the user
  stack raises (a buggy middleware): plain 500, trace to `on_error`.

### 8.2 Exception layer

`xpcall(next, handler)` with a message handler that keeps the stack
([`errors.trace`], as server.tl:290 does). Cases:

- `Web.abort` table: build `Web.problem` or HTML via `error_view`, status
  and detail as given. No logging (a 404 is not a fault); 5xx aborts are
  logged.
- Any other raise: log at error level with the trace (via `on_error`/logger),
  answer 500. In production the body is the generic `Internal Server Error`
  (problem+json or HTML by Accept) with the request id if present, no
  detail. In `app.debug = true` the body is an HTML page (or JSON
  `{"error":..., "trace":...}` for JSON clients) holding the message and
  trace, escaped with [`Html.escape`], and a note that debug is on. Debug
  exposes source paths and values, so: `debug` defaults false, is
  never derived from the environment implicitly, and `serve` prints a
  warning line when `debug` and a non-loopback listener are combined.
- A `Response` with an invalid shape is the server's 500 (server.tl:417-426).
  The exception layer additionally validates in debug mode only, so the
  trace names the handler, not just the server's message.

### 8.3 404/405/other statuses

`App.error_pages: {integer: Handler}` and `App.error_view:
function(Request, status: integer, detail: string): Response`. Resolution:
`error_pages[status]` if set (Starlette's `exception_handlers`); else the
negotiated default: problem+json for an API client, a minimal HTML page
otherwise. 405 adds `Allow`. These apply to router-generated 404/405,
aborts, the default answers for invalid input (400/413/415, 6.4), and 500. They do *not* apply to responses a
handler returned itself.

Status-level errors the server answers before any handler runs (400 for a
malformed head, 408, 413 over the limit, 431, 505; server.tl:393-409,
519-558) are plain text (`answer`, server.tl:296): web cannot rewrite
them without a server hook. Accepted for v1 and documented; an
`ServeSpec.error_reply` hook is noted in 13.6.

### 8.4 Request logging

[`cosmic.log`] is a command-line logger: `say`, `complain`, `verdict`, no
levels, no fields (cosmic/log.tl:11-30). It is the wrong shape for a
server. Core defines the small interface web needs and adapts to it:

```teal
record Sink
  --- One line, newline added by the sink.
  line: function(Sink, text: string)
end
function Web.stderr_sink(name?: string): Sink     -- over Log.new(name):complain
```

`Web.access_log(opts?: { sink?, format?, skip?: function(Request): boolean })`
writes one line per request after the response is produced:
`GET /items/42 200 3ms 1.2KB id=ab12 client=127.0.0.1`. `Content-Length`
of a Reader body is unknown; log `stream`. The middleware sits where the
user puts it (typically first/outermost, so it times everything and sees
mounts' 404s). It never logs the query string by default (tokens in
queries); `opts.log_query = true` opts in. Application errors go to
`ServeSpec.on_error` (the sink wraps it, 9.2). Open question 14.6: whether
[`cosmic.log`] itself should grow levels.

## 9. App and serve

### 9.1 App

```teal
record App
  routes: {Route}
  middleware: {Middleware}
  --- Called once before the listeners open; returns the shutdown function
  --- (or nil). Runs outside the event loop, see 9.3.
  lifespan: function(app: App): function() | nil, string
  debug: boolean
  trailing_slash: string                -- "redirect" (default) | "strict"
  trusted_hosts: {string}
  --- Hubs closed when the server stops (9.3; assets.md section 5.7).
  hubs: {Sse.Hub}
  --- Most open event streams (default: half of the connection limit;
  --- assets.md section 5.9).
  max_streams: integer
  --- Serve files from disk and add the reload script (assets.md sections
  --- 1.6 and 6.4); default from COSMIC_WEB_DEV.
  dev: boolean
  --- Register the built-in routes under /_web/ (default true; 5.5).
  builtin: boolean
  error_pages: {integer: Handler}
  error_view: function(Request, integer, string): Response
  sink: Sink                            -- default stderr
  state: {any:any}                      -- Web.Key<T> -> value
  --- Filled by Web.app(...)
  handle: Handler
  router: Router
  url_for: function(App, string, {string:string|integer}?, {string:string}?): string | nil, string
  --- True once the server has begun to stop (9.3). Long-lived responses
  --- poll it; it never goes back to false.
  stopping: function(App): boolean
  --- Registers a function run when the server begins to stop (9.3). A Hub
  --- registers its `close`, an EventStream its stream's, through this
  --- (assets.md sections 5.5, 5.7 and 6.3).
  on_stop: function(App, fn: function())
end

function Web.app(spec: Web.AppSpec): Web.App
```

`Web.app` takes an `AppSpec` (the fields above, user-settable ones) and
returns the built `App`: routes compiled, middleware folded, registration
errors raised. A `Web.App{...}` literal is not constructible directly
because `handle` and the compiled router are derived; the constructor is
`Web.app{routes=..., middleware=...}` (a function call, so derivation has a
place to happen). The AppSpec rejects unknown fields by name, like
[`Server.ServeSpec`] (server.tl:195-236).

`app.handle` is a `Handler`, so an App is itself mountable: another app's
route can `Web.mount_handler("/legacy", other.handle)`.

### 9.2 serve

```teal
record ServeOptions
  listeners: {Net.Address}
  limits: Server.ServeSpec.Limits
  timeout_ns, idle_ns, head_ns: integer
  grace_ns: integer                  -- default 10 seconds (Server's default is wait forever)
  on_ready: function({Net.Address}, Net.Server)
  --- Called when the server begins to stop, after the app's own stop
  --- functions (9.3).
  on_stop: function(Net.Server)
end
function Web.serve(app: App, opts: ServeOptions): boolean, string
```

Wiring: `Server.serve{ listeners, handle = app.handle, limits, timeouts,
on_ready, on_stop = <9.3>, on_error = app.sink-based, body_limit = app.router
body limit }`.
Returns Server.serve's `boolean, string`. Raises for a spec of the wrong
shape, like the layer below. A default `grace_ns` of 10 seconds because
`nil` waits for every request, and an SSE stream never ends, so a
graceful stop hangs forever otherwise. Documented in `ServeOptions`.

### 9.3 Lifespan and graceful stop

[`Server.serve`] runs its own [`Poll.run`] and refuses to start inside a task
(server.tl:573). Hence lifespan functions cannot be tasks that wait on
`Poll`. Design: `Web.serve` does

```
local shutdown, why = app.lifespan(app)         -- before listening
if shutdown == nil and why ~= nil then return false, why end
local ok, err = Server.serve{...}                -- returns after graceful stop
if shutdown then pcall(shutdown) end             -- after in-flight requests drained
return ok, err
```

The startup runs synchronously before any listener opens: opening a SQLite
file, migrating, loading templates are fine; anything needing `Poll`
(an HTTP client wait, a timer) is not. Shutdown runs after [`Server.serve`]
returns, i.e. after requests in flight finished or the grace passed, so
closing the database there is safe. A startup error returns `false, why`
without listening. `lifespan` is a single function returning the cleanup
closure (the Teal analogue of Starlette's `asynccontextmanager` yield):

```teal
lifespan = function(app)
  local db = assert(Sqlite.open("app.db"))
  app.state[DB] = db
  return function() db:close() end
end
```

`on_startup`/`on_shutdown` lists (older Starlette) are not provided: one
function covers both and keeps open/close paired.

Graceful stop is the existing behaviour: SIGINT/SIGTERM stop accepting,
idle keep-alives close, in-flight requests finish within `grace_ns`
(net.tl:203-228, server.tl:593-598), and [`Server.stop`] from `on_ready` or a
task works for tests. One mechanism makes long-lived responses (SSE streams)
end promptly instead of at the grace; assets.md section 6.3 describes the
streaming side of it and refers back here:

1. `grace_ns` defaults to 10 s in `Web.serve`. The server's default
   (nil) waits for every request, and an event stream never ends, so a
   graceful stop would hang forever.
2. [`Server.serve`] forwards a caller's `on_stop`: `ServeSpec` gains
   `on_stop: function(server: Net.Server)`, called at the end of the
   server's own `on_stop` (server.tl:597-603), after it has closed the idle
   connections and marked the server stopping; an error in it goes to
   `on_error`, as Net's does (13.7).
3. `Web.serve` passes an `on_stop` that (in this order) sets the flag behind
   `app:stopping()`, runs every function registered with `app:on_stop(fn)`
   in registration order, and then calls the caller's `ServeOptions.on_stop`.
4. Every `Sse.Hub` and every `Sse.EventStream` registered with the App
   registers its close with `app:on_stop` (a Hub through `hub:attach(app)`
   or `AppSpec.hubs`, an EventStream when it is made from a request, which
   reaches the app through `req.app`). Their streams end with a clean last
   chunk, the browsers reconnect to the next process within the `retry:`
   delay, and the server then finds nothing in flight, so the stop returns
   well before `grace_ns`.
5. A stream whose producer ignores its close is killed at the grace, and its
   `<close>` guard runs (assets.md section 5.5).

`app:stopping()` is for a Reader or task that polls rather than being
closed (a custom `EventSource`, a background task started in the lifespan).
The lifespan's shutdown function runs after [`Server.serve`] returns (above),
so it sees streams already closed.

A startup-time TODO is placed in `Web.serve`: "once Server.ServeSpec has an
`on_start` run in a task before the listeners open (so lifespan may wait
on Poll)".

## 10. Testing

### 10.1 In-process TestClient

```teal
local client = Web.test_client(app)          -- cosmic.web.testing
local res = client:get("/items/42", { headers = {...}, query = {page="2"} })
assert(res.status == 200)
assert(res:json().id == 42)
res = client:post("/items", { json = { title = "a", qty = 1 } })
res = client:post("/login", { form = { user = "u", password = "p" } })
```

- Methods: `get head post put patch delete options request(method, path,
  opts)`. Options: `headers`, `query` (table, repeated names via lists),
  `form` (urlencoded), `json` (encoded, Content-Type set), `body`
  (string or Reader) + `content_type`, `follow_redirects` (default false;
  when true follows 301/302/303/307/308, switching to GET for 301/302/303
  after POST), `cookies` (extra, not jar).
- It builds a [`Server.Request`] (`method`, `target`, `path`, `query`,
  `headers` with `host: testserver`, lowercased, `body = Stream.from_string`,
  `length`, `version = "HTTP/1.1"`) and calls `app.handle` directly: no
  socket, same middleware, same router. A cookie jar is kept across calls
  (reads Set-Cookie lines, sends `Cookie`), so session tests are one
  client. The jar understands path/expiry/Secure minimally (the cookies
  module, `cosmic.web.cookies`, owns semantics; the client uses a
  `Cookies.parse_set_cookie(line)` that input.md section 6 adds for it, and
  a first version may keep name=value and delete on `Max-Age=0`).
- Fidelity: the in-process path skips the server's checks, so a handler
  can return an invalid reply that passes in tests and 500s live. The
  client therefore runs the same [`wire.check`] the server does
  (cosmic/http/wire.tl:742-790) on every reply and fails with the server's
  message (tests may require [`cosmic.http.wire`]; the harness epoch is
  untouched). A HEAD reply is emulated the same way: body dropped,
  `Content-Length` of the GET kept. A Reader body is drained for
  `res.body` (`res:text()`) unless `stream = true`, in which case
  `res.stream` is the Reader and the test reads events as they come.
- `TestResponse`: `status`, `headers` (lowercased names, value joined),
  `header_list(name)` (every line, for Set-Cookie), `body`, `text()`,
  `json()`, `redirect_location`, `ok`.
- Context: a handler may wait ([`Poll.delay`], a channel read). Each call
  runs inside [`Poll.run`] when the caller is not already in a task
  ([`Poll.in_task()`], poll.tl:831); `Web.with_client(app, fn)` runs the
  lifespan (startup/shutdown) around `fn(client)` in one [`Poll.run`], so a
  test using the database resource works; the simple `Web.test_client(app)`
  runs lifespan lazily at the first request and registers shutdown via
  `<close>` (`local client <close> = Web.test_client(app)`).
- A deterministic clock for sessions/expiry is `Session.Options.now`
  (input.md section 7); the client does not fake time.

### 10.2 Over loopback

```teal
Test.policy{ loopback = { "127.0.0.1" } }

local function test_keep_alive()
  Web.with_server(app, function(client: Web.LoopbackClient)
    local a = assert(client:get("/one"))
    local b = assert(client:get("/two"))      -- same connection
    assert(b.status == 200)
  end)
end
```

`Web.with_server(app, fn)` calls `Web.serve` on `127.0.0.1:0` from a test
(not inside a task; [`Server.serve`] makes its own [`Poll.run`]), runs `fn`
from `on_ready` in a task via [`Net.connect`], then `server:stop()` and
returns. The loopback client speaks plain HTTP/1.1 itself (write a request,
read status line, headers, Content-Length or chunked body) rather than
going through [`Http.get`], which holds the thread the server runs on
(server_example.tl:23-25). The response reader is about 80 lines
(`cosmic/web/testing.tl`), tested against hand-written frames. It exists
for what in-process cannot see: real framing (HEAD, chunked streams,
`Connection: close`, 413/408/431 produced by the server itself, multiple
Set-Cookie lines on the wire) and graceful stop. Expect a handful of such
tests; the bulk run in-process (no loopback policy, and cheap to key).

### 10.3 Conventions

- Test files: `cosmic/web/*_test.tl` with top-level `local function test_*`;
  no top-level `return`; every test calls `assert` (the worker counts them,
  AGENTS.md "NO ASSERT").
- Router: table-driven matcher tests (pattern, request path, expected
  route/params/allow/status), a reverse-routing round trip
  (`match(url_for(name, p))` yields `p`), and registration-error cases
  (pcall plus assert on message).
- Fuzz (parsers of untrusted bytes, AGENTS.md): `router_fuzz_test.tl`
  (arbitrary paths never raise, canonicalisation is idempotent, any
  `Location` produced starts with exactly one `/`), `accept_fuzz_test.tl`
  (Accept parsing; query/form decoding is fuzzed in `url_fuzz_test.tl`,
  input.md section 12), using
  [`build.fuzz`]'s `run`, [`Fuzz.label`] for what an input reached; corpora
  under `testdata/fuzz/<property>/` after any failure.
- Typed-route tests build tiny apps inline; shape-dependent ones need the
  `record_of` build splice, so they are ordinary modules, not
  `--standalone` snippets (shape.tl:567-574).
- `Test.policy`: in-process modules need none; loopback modules declare
  `loopback = { "127.0.0.1" }` and, per AGENTS.md, a test starting a
  server starts its own on 127.0.0.1. Files are separate modules so only
  the loopback ones carry the network key.
- Examples: `cosmic/web/web_example.tl` shows a JSON API and an HTML page
  with `Test.policy{ loopback }` like server_example.tl:12.

## 11. Security summary

- Path canonicalisation before any middleware; auth keyed to
  `req.segments`/`req.path` cannot be bypassed by `//`, `.`, `%2e`, `..`
  (rejected), encoded slash (rejected) (5.4).
- Redirects rebuilt from segments; `Web.redirect` validates targets;
  `safe_next` for user input (3).
- `Web.html` accepts `SafeHtml` only; error pages and the debug page escape.
- Debug off by default, never from the environment, loud warning when
  combined with a non-loopback listener (8.2).
- Host header: `trusted_hosts`; no `base_url` without it (5.7).
- `X-Forwarded-*` untrusted unless the app sets `trusted_proxy` (2.2).
- Header injection: Server already refuses CR/LF/NUL (wire.tl:699-707);
  `add_header` and constructors do not re-implement.
- DoS: query pair cap; body read once and bounded by `limits.body_bytes` and
  a per-route `body_limit`; JSON depth limit via [`Json.decode`]'s
  `max_depth`; typed routes bounded lists (`list` of at most 1000 values).
  Cooperative scheduling means a CPU-bound handler stalls all (docs).
- Problem and error bodies never echo raw user input unescaped: JSON is
  encoded by [`Json.encode`], HTML via [`Html.escape`]; shape messages quote
  values (`shown`, truncated to 40 bytes, shape.tl:281-287).
- Typed keys prevent middleware state collisions (2.3).

## 12. Module layout and build order

- `cosmic/web/init.tl`: the `Web` record, re-exports, doc comment with the
  main example.
- `cosmic/web/request.tl`, `response.tl`,
  `router.tl` (pattern parse, trie, reverse), `typed.tl`, `middleware.tl`
  (log, timing, request id), `errors.tl` (exception layer, negotiation,
  problem), `app.tl` (App, serve, lifespan), `testing.tl`.
- The other files add modules beside: `cosmic.web.input`,
  `cosmic.web.cookies`, `cosmic.web.session` (with `.cookie` and `.sqlite`
  stores), `cosmic.web.csrf`, `cosmic.web.cors`, `cosmic.web.headers`
  (input.md); `cosmic.web.htmx` (templates.md); `cosmic.web.static`,
  `cosmic.web.sse`, `cosmic.web.dev`, and the support modules
  `cosmic.web.assets` and `cosmic.web.mime` (assets.md).

Order of work (each a PR, tests included):

1. Server/Wire/Url prerequisites (13).
2. Spike: typed route generics across `Input<P,Q,B>`.
3. Response constructors, header helpers (`Web.add_header`); the query/form
   decoder is [`Url.decode_query`] from step 1.
4. Router: parse, trie, match, 404/405, HEAD/OPTIONS, reverse, mounts,
   canonical path, redirects; fuzz.
5. Request, middleware composition, exception layer, App, serve, lifespan.
6. Typed routes over `cosmic.web.input`'s binder (input.md section 3) +
   `on_invalid` + the 400/413/415 negotiation.
7. TestClient (in-process), then loopback client.

## 13. Required changes to existing modules

### 13.1 Multi-valued response headers (Set-Cookie)

`Server.Reply.headers: {string:string}` (server.tl:91) cannot carry two
Set-Cookie lines; joining with ", " is forbidden for Set-Cookie (RFC 9110
5.3, 7.1 of 6265: `Expires` has a comma). Proposal, exact:

```teal
-- server.tl, record Reply
headers: {string: string | {string}}
```

A list value is written as one header line per element, in list order;
the name is written as given on each line. A string value is the status
quo. Compatibility: every existing literal (`{ ETag = etag }`) keeps
type checking, because `string` is a member of the union; no behaviour
changes for them. Code that *reads* `reply.headers[k]` as a string now has
a union (the in-tree readers are tests: server_test.tl, server_example.tl:70-71,
which print or compare and need `is string` narrowings checked when the
change lands; run `bin/cosmic fix` to find them). Teal discriminates
`string | {string}` fine (string vs table). Why not a second field
(`header_lines`): two places to look, and the name-keyed duplicate rule
(Content-Length twice) must then span both; the union keeps one table and
one checker.

Places to change:

- server.tl:339-346 `reply_trouble`: accept `value is string or list of
  strings`; empty list allowed (writes nothing); non-string element is
  "the reply's headers must map names to strings or lists of them".
- wire.tl:699-707 `headers_trouble`: check CR/LF/NUL and OWNED per
  element; wire.tl:718-731 `given_length`: a list value for
  Content-Length is refused ("Content-Length is given more than once");
  wire.tl:809-813 `head_text`: emit one line per element (sorted by name
  as today; elements keep their order). [`wire.Reply.headers`] (wire.tl:132)
  gets the same type.
- Docs: Reply.headers comment gains: "A list writes one line per element;
  use it for Set-Cookie, which cannot be joined". `Web.add_header` (section
  3) is the one helper that appends to it.
- Tests: server_test (two Set-Cookie lines arrive in order; a CR in one
  element is a 500; a list for Content-Length is a 500), wire_test (head
  text), a fuzz-corpus entry for list values.
- `Web.add_header` is the only API most code uses.

### 13.2 Request.headers joining (Cookie)

wire.tl:434 joins repeated request headers with ", ". For `cookie` RFC
9113 8.2.3 (HTTP/2) joins with "; "; HTTP/1.1 clients rarely repeat it, but
if one does, ", " yields a corrupt first cookie value on parse. Change:
`table.concat(values[name], name == "cookie" and "; " or ", ")`. Add a test
in wire_test. (Not needed for correctness of well-behaved clients; cheap.)

### 13.3 Peer address on Request

Add `peer: Net.Address` to [`Server.Request`] (server.tl:30-66), filled in
`exchange` from the connection (server.tl:390). [`Net.Conn`] has no peer
accessor today (connection.tl documents read/write/shutdown only), yet a
raw `peer` binding exists (core/socket.c:786). Needed: `Conn:peer(): Address
| nil, string` on [`Net.Conn`], backed by it, with a net_test. Unix-socket
connections give a unix Address with no path; `web.Client` is then nil.
Without this change `req.client` stays nil and everything else works
(TODO placed at [`Request.client`]: "once Net.Conn:peer exists").

### 13.4 Per-route body limit

`limits.body_bytes` (1 MiB default, server.tl:119-120) is one value per
server; an upload route wants more and a JSON API route less. Proposal:
`ServeSpec.body_limit: function(method: string, path: string): integer |
nil` consulted once the head is read, before the body Reader is made
(wire.body takes `s.limits`, server.tl:389); the answer replaces
`body_bytes` for this request (and a `Content-Length` above it is 413 at
once, as now). `Web.serve` passes the router's lookup (route.body_limit
or the app default). Without it, web enforces smaller limits itself
(`Input`'s Content-Length check and [`Stream.limit`], stream.tl:690, which
fails the read -> 413 abort; input.md section 2) but cannot raise the cap
for one route, so input.md section 2 describes the fallback of raising the
server-wide `body_bytes` to the largest route limit.

### 13.5 Query/form decoding in cosmic.url

Land the doc/roadmap.md:243-247 item as input.md section 1 specifies it:
`Url.decode_query(text, opts?)` returning a [`Url.Query`] (ordered pairs and
values by name), `+` as space, `%XX` decoded, a malformed escape or more
than `max_pairs` refused (`lenient` is an option no cosmic.web caller sets),
with [`Url.encode_query`] and the accessors. `cosmic.web.input` wraps it for
both the query and the urlencoded body. If this lands slowly,
`cosmic/web/input.tl` carries a private copy with a TODO "once cosmic.url
has decode_query".

### 13.6 Smaller server.tl observations

- server.tl:429 closes the connection after every reply with status >= 400.
  For a server answering htmx fragments and APIs, every validation error,
  404 (a missing favicon) and 401 forces a TCP reconnect. The body is
  already drained or lingered for (server.tl:476-479), so the clause looks
  unnecessary for correctness. Proposal: close only for 5xx and for the
  statuses the server itself writes (answer()) and when the body is
  unread/failed; test with an unread POST body and a 400 reply. Flagged as
  a recommendation, with a keep-alive loopback test; not required to ship
  web.
- Status 101 + `take` (7.3), unbuilt.
- `ServeSpec.on_start` (9.3), unbuilt.
- Server-generated error replies are text/plain (server.tl:300-304);
  an `error_reply: function(status, why): Reply` hook would let web render
  its error views there. Not v1.
- `report` writes to stderr unless `on_error` is given (server.tl:281-287);
  `Web.serve` always supplies `on_error` (the sink).

### 13.7 Forwarding `on_stop`

[`Server.ServeSpec`] has no `on_stop` and the server's own (server.tl:597) is
fixed. Add `on_stop: function(server: Net.Server)` to `ServeSpec` (server.tl
106-146) and call it at the end of the server's own `on_stop`, after the
idle connections are closed and `stopping` is set; an error in it goes to
`on_error`, as Net does for its own. `Web.serve` uses it (9.3). Test: a
[`ServeSpec.on_stop`] runs once on [`Server.stop`], after the idle connections
close, and a raise in it reaches `on_error` without stopping the drain.

## 14. Open questions and recommendations

1. Inference of `Input<P,Q,B>` in Teal (6.2). Recommendation: spike first;
   if it fails, use explicit type arguments on `route_typed`. Either way
   the public shape (`input` value + handler `(req, p, q, b)`) stays.
2. 400 versus 404 for a path param that fails its spec. Decided: 400; the
   route still "exists".
3. `Web.app{}` instead of `Web.App{}` (derived fields). Recommendation:
   keep `Web.App` as the type name and `Web.app` as the constructor.
4. `Response` as an alias of [`Server.Reply`] versus a distinct record.
   Recommendation: alias (zero cost); revisit only if the `take` field makes
   some Replies illegal in some contexts.
5. 400 versus 422 for input that decodes but fails its shape spec (6.4).
   Decided: 422 (../web.md, decision 7).
6. [`cosmic.log`] is CLI-only. Recommendation: do not extend it for web v1;
   `Web.Sink` over `Log.new(...)`, and decide on levels when a second
   consumer exists.
7. Async lifespan (waiting on Poll before listening). Recommendation:
   synchronous in v1; add `ServeSpec.on_start` later.
8. Mount prefix with params (`/users/:uid/...`). Recommendation: not in v1.
9. Structured multi-error validation is settled (6.3, 6.4): the binder in
   input.md collects every error of a path, query or form source. What
   stays open is a collect-all mode for JSON bodies, which needs a change in
   cosmic.shape (input.md open question 2); until then a JSON body gives one
   entry in `errors`.
10. The mime table lives in cosmic.web.mime (`Mime.of`, assets.md section
    1.4), which `Web.file` calls; `file` takes `content_type` explicitly to
    override it.
11. 4xx closing the connection (13.6). Recommendation: change, with a test,
    as a separate PR before web ships.
12. Whether `Web.test_client` should run [`wire.check`] (10.1).
    Recommendation: yes, always; the point of a test client is that a 200
    in the test is a 200 on the wire.
13. A gzip middleware: assets.md and input.md assume one (it must leave
    `text/event-stream`, `Content-Encoding` and `take` responses
    alone), but no part designs it. Recommendation: a small `Web.gzip`
    middleware in the core, after the first release, using
    [`Stream.transform`] (stream.tl:655).
14. Shutdown awareness for streams is settled (9.3): `app:stopping()` and
    `app:on_stop(fn)`, fed by a forwarded [`ServeSpec.on_stop`]; the
    alternative of `Poll` task cancellation was rejected because `Server`
    has no per-connection cancel today.

[`build.fuzz`]: ../../../build/fuzz/init.tl
[`cosmic.http.wire`]: ../../../cosmic/http/wire.tl
[`cosmic.log`]: ../../../cosmic/log.tl
[`cosmic.shape`]: ../../../cosmic/shape.tl
[`cosmic.url`]: ../../../cosmic/url.tl
[`errors.trace`]: ../../../cosmic/internal/errors.d.tl
[`Fuzz.label`]: ../../../build/fuzz/init.tl
[`Html.escape`]: ../../../cosmic/html.tl
[`Html.raw`]: ../../../cosmic/html.tl
[`Html.SafeHtml`]: ../../../cosmic/html.tl
[`Html.trust`]: ../../../cosmic/html.tl
[`Html.url_part`]: ../../../cosmic/html.tl
[`Http.get`]: ../../../cosmic/http/init.tl
[`Json.array`]: ../../../cosmic/json.tl
[`Json.decode`]: ../../../cosmic/json.tl
[`Json.encode`]: ../../../cosmic/json.tl
[`Json.null`]: ../../../cosmic/json.tl
[`Net.Conn`]: ../../../cosmic/net.tl
[`Net.connect`]: ../../../cosmic/net.tl
[`Poll.delay`]: ../../../cosmic/poll.tl
[`Poll.in_task()`]: ../../../cosmic/poll.tl
[`Poll.run`]: ../../../cosmic/poll.tl
[`Poll.spawn`]: ../../../cosmic/poll.tl
[`Request.client`]: ../../../cosmic/internal/relay_server.tl
[`Server.none_match`]: ../../../cosmic/http/server.tl
[`Server.range`]: ../../../cosmic/http/server.tl
[`Server.Reply`]: ../../../cosmic/http/server.tl
[`Server.Request`]: ../../../cosmic/http/server.tl
[`Server.serve`]: ../../../cosmic/http/server.tl
[`Server.ServeSpec`]: ../../../cosmic/http/server.tl
[`Server.stop`]: ../../../cosmic/net.tl
[`ServeSpec.on_stop`]: ../../../cosmic/net.tl
[`Shape.into`]: ../../../cosmic/shape.tl
[`Stream.from_string`]: ../../../cosmic/stream.tl
[`Stream.limit`]: ../../../cosmic/stream.tl
[`Stream.open`]: ../../../cosmic/stream.tl
[`Stream.Reader`]: ../../../cosmic/stream.tl
[`Stream.transform`]: ../../../cosmic/stream.tl
[`Url.decode_query`]: ../../../cosmic/url.tl
[`Url.encode_query`]: ../../../cosmic/url.tl
[`Url.escape`]: ../../../cosmic/url.tl
[`Url.parse`]: ../../../cosmic/url.tl
[`Url.Query`]: ../../../cosmic/url.tl
[`Url.segments`]: ../../../cosmic/url.tl
[`wire.check`]: ../../../cosmic/http/wire.tl
[`wire.Reply.headers`]: ../../../cosmic/http/wire.tl
