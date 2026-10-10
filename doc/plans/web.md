# cosmic.web

A plan for `cosmic.web`: a standard-library module that makes an htmx web
interface, or a JSON HTTP API, or both in one program, a matter of a route
table, a few templates and a call to `Web.serve`. It layers on
[`cosmic.http.server`], which stays the low-level server it is.

[Starlette] is the reference: its Request and Response, Router, Route and
Mount, a middleware stack, TestClient, StaticFiles, session and CORS
middleware, lifespan, and streamed responses. Each is translated to Teal's
static types and cosmic's idioms (records, `nil, reason` for a runtime
failure, opaque safe types, no hidden globals), and each part says where
and why it departs.

This file holds the decisions, the shape of the whole, the order of the
work and the questions still open. The detail is in four parts:

- [core](web/core.md): Request, Response, Router, Route and Mount, typed
  routes, middleware, errors, App, serve and lifespan, TestClient, and the
  changes to [`cosmic.http.server`] they need.
- [input](web/input.md): query and form decoding, binding input to
  [`cosmic.shape`] specs with every field's error, JSON bodies, multipart,
  cookies, sessions (signed cookie and SQLite), CSRF, CORS, security
  headers and CSP, secrets.
- [templates](web/templates.md): attribute dialects in
  [`cosmic.template`], the htmx dialect, URL-component escaping,
  `SafeJson`, selector escaping, and `cosmic.web.htmx`'s request and
  response helpers.
- [assets](web/assets.md): the `static/` convention and `StaticFiles`,
  vendored htmx and its SSE extension with SRI, server-sent events and the
  channel under them, runtime notes (cooperative tasks, SQLite, shutdown,
  a dev loop), and the seam WebSockets will need.

Nothing here is built yet. Code citations are `path:line` at the commit
the plan was written against.

## decisions

Taken up front with the user and not reopened per PR.

1. **A new module, `cosmic.web`,** on [`cosmic.http.server`]. Small
   changes to existing modules are in scope where `cosmic.web` needs them;
   the server does not grow opinions.
2. **Routes are an explicit table in code**, built by constructors
   (`Web.get`, `Web.route`, `Web.mount`) into plain data, so a file-based
   routing layer can later generate the same table. A route may name
   [`cosmic.shape`] specs for its path parameters, query, and form or JSON
   body: its handler is then given checked, typed records, and input that
   fails them is answered before the handler runs. Without specs a handler
   reads strings.
3. **Sessions have one interface and two stores:** a signed cookie (the
   default) and a SQLite table holding the data under an opaque id (for
   revocation and size).
4. **The template compiler gets attribute dialects:** a table of extra URL,
   JSON, selector and code attributes that a template opts into with
   `{{use htmx}}`. The htmx dialect ships with the standard library.
5. **Middleware is Starlette's:** `function(Handler): Handler`, stacked
   around the app, each Mount with its own stack. Sessions, CSRF, CORS,
   security headers, logging and error pages are middleware.
2. **v1 includes server-sent events and a pinned htmx.** WebSockets are
   designed for (the seam is named) and built later. No OpenAPI in v1.

Taken after the parts were written:

3. **A value that fails its spec is 422;** input that cannot be decoded is
   400. "The request was malformed" and "the values were wrong" stay
   apart, as FastAPI keeps them.
4. **Multipart is in v1,** last, once the server's body deadline has
   landed.
5. **A slot in `hx-on*` or `hx-vars` is refused in every template,** with
   or without `{{use htmx}}`: it is script, and attribute escaping does not
   make it safe.
10. **`Web.app{ trusted_proxy = true }`,** off by default, takes the
    scheme, host and client from `X-Forwarded-Proto`, `X-Forwarded-Host`
    and `X-Forwarded-For`; with it off, `Secure` is configuration and a
    startup warning says so.

## the shape of it

An app with an htmx page, a form, and a JSON API under `/api`. Names are
the ones the parts settle on; the typed-route signature waits on the
generics spike (core.md, section 6.2).

```teal
local Html = require("cosmic.html")
local Web = require("cosmic.web")
local Htmx = require("cosmic.web.htmx")
local Input = require("cosmic.web.input")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local Secret = require("cosmic.web.secret")
local Csrf = require("cosmic.web.csrf")
local StaticFiles = require("cosmic.web.static")
local Shape = require("cosmic.shape")
local Net = require("cosmic.net")
local pages = require("pages")             -- pages/*.tmpl, `{{use htmx}}`
local db = require("app.db")

local record NewItem  title: string  qty: integer end
local NEW <const> = Shape.record_of("NewItem")

local function items(req: Web.Request): Web.Response
  local fragment = pages.items.render({ items = db.items() })
  return Htmx.page(req, fragment, function(body: Html.SafeHtml): Html.SafeHtml
    return pages.layout.render({ title = "Items", head = Htmx.head(), body = body })
  end)  -- the fragment alone for an htmx request, else the whole page
end

local function create(req: Web.Request, _: Web.None, _: Web.None, b: NewItem): Web.Response
  db.insert(b.title, b.qty)
  return Web.html(pages.item_row.render(b), { status = 201 })
end

local app = Web.app{
  routes = {
    Web.get("/", items, { name = "items" }),
    Web.post_typed("/items", Web.input(Web.NONE, Web.NONE, Web.form_body(NEW)), create, {
      on_invalid = function(req: Web.Request, bad: Input.Invalid): Web.Response
        return Web.html(pages.item_form.render(bad), { status = 422 })
      end,
    }),
    StaticFiles.mount("/static", {}),           -- named "static"
    Web.mount("/api", require("app.api").routes, { name = "api" }),
  },
  middleware = {
    Web.access_log(),
    Session.middleware{
      store = SessionCookie.store{ keys = assert(Secret.keys_from_env("COSMIC_SESSION_KEYS")) },
    },
    Csrf.middleware(),
  },
}

assert(Web.serve(app, { listeners = { Net.tcp("127.0.0.1", 8080) } }))
```

A template in the htmx dialect:

```
{{type Page from pages.data}}{{use htmx}}
<ul id="items">{{range .items}}
  <li hx-get="/items/{{.id}}" hx-target="#item-{{.id}}">{{.title}}</li>
{{end}}</ul>
```

`/items/{{.id}}` is a URL with a slot after literal text, escaped as one
path segment; `#item-{{.id}}` is a selector, escaped as a CSS identifier;
`{{.title}}` is text. A slot in `hx-on:click` or `hx-vars` is refused at
compile time whether or not the template uses the dialect.

The layout writes `{{.head}}`, which the handler above fills with `Htmx.head()`:
the `<meta name="htmx-config">` and the `<script>` tags, with SRI, for the
htmx built into the binary and served under `/_web/`.

A test drives the app in-process:

```teal
local client = Web.test_client(app)
local reply = client:post("/items", { form = { title = "x", qty = "two" },
  headers = { ["HX-Request"] = "true" } })
assert(reply.status == 422 and reply.text:find("qty", 1, true))
```

## modules

- `cosmic.web`: Request, Response constructors, Route, Mount, Router,
  typed routes, middleware composition, the exception layer, App, serve,
  lifespan, typed per-request keys (`Web.key<T>`).
- `cosmic.web.input`: query, form and JSON decoding, and binding them to
  a spec with every field's error collected (`Input.Invalid`).
- `cosmic.web.mime`: content types by file name.
- `cosmic.web.cookies`, `cosmic.web.session` (with its stores
  `cosmic.web.session.cookie` and `cosmic.web.session.sqlite`),
  `cosmic.web.secret` (keys from the environment, weak ones refused),
  `cosmic.web.csrf`, `cosmic.web.cors`, `cosmic.web.headers` (security
  headers and CSP).
- `cosmic.web.htmx`: HX-* request headers, HX-* response headers,
  `Htmx.page` (fragment or whole page, `Vary: HX-Request`), `Htmx.head`.
- `cosmic.web.static` and `cosmic.web.assets`: `StaticFiles` over
  embedded or on-disk assets, fingerprinted URLs.
- `cosmic.web.sse`: `Event`, `EventStream`, `Hub`.
- `cosmic.web.testing`: the in-process client and the loopback one.
- `cosmic.web.dev`: a supervisor that restarts the app on an edit and
  reloads the browser, on the loopback only.
- Beside it, not under it: `cosmic.channel` (a queue between tasks),
  [`Poll.notifier`] in [`cosmic.poll`], `cosmic.http.multipart`, and the
  htmx dialect in `cosmic/template/dialect/`.

## settled across the parts

The parts were written in parallel; these are where they met.

- **Per-request state is typed keys.** `Web.key<T>(name)` makes a key a
  module exports; `req:get(KEY)` and `req:set(KEY, v)` read and write it.
  The session, the CSRF token, the CSP nonce and a typed route's records
  are each a key. `req.state` is the untyped escape hatch only.
- **Status codes.** Undecodable input is 400, a wrong Content-Type 415, an
  oversized body 413, and a value that decodes but fails its spec 422
  (decision 7), which the shipped htmx config swaps, so a form's re-render
  with its errors reaches the page.
- **Validation collects every field's error** through `cosmic.web.input`,
  with [`Shape.into`] as the last check, so a form re-renders with all its
  messages and an API's problem+json `errors` lists them all. A route's
  `on_invalid` turns that into the re-render in one line.
- **One URL escaper.** `Router:reverse` and `url_for` escape a path
  parameter exactly as the template's [`Html.url_part`] does, which agrees
  with [`Url.escape`]; a test pins the three together. A Mount answers
  reverse lookups, so `url_for("static", { path = "app.css" })` gives the
  fingerprinted URL. `/_web/` is reserved for cosmic.web's own assets.
- **One htmx config,** written by `Htmx.head`: `allowEval` and
  `allowScriptTags` off (so a CSP without `unsafe-eval` holds),
  `includeIndicatorStyles` off (no inline style), `selfRequestsOnly` on,
  and `responseHandling` swapping 2xx and 422 but not 204.
- **Shutdown.** `Web.serve` gives `grace_ns` a default of 10 seconds,
  where the server's waits for every request and so for every event stream;
  [`Server.serve`] forwards a caller's `on_stop`; `app:stopping()` turns
  true, and every Hub and EventStream registered with the app closes.
- **Response headers take a list.** [`Server.Reply.headers`] widens to
  `{string: string | {string}}`, one header line per element, so a reply
  can set two cookies; existing literals still type-check. The Cookie
  request header is joined with `"; "`, not `", "`. `Web.add_header` is
  the one way to append (a `Vary` token, a `Set-Cookie`).
- **Dialects live in [`cosmic.template`],** not in `cosmic.web`: the
  build's compiler identity hashes `build.*` and `cosmic.template.*` alone
  (build/identity.tl:400), so a dialect anywhere else would leave stale
  templates after an edit.

## changes to existing modules

Each is a small PR of its own, landing before the module that needs it.

- [`cosmic.http.server`] and [`cosmic.http.wire`]: multi-valued reply
  headers; Cookie joined with `"; "` (wire.tl:434); `Request.peer`; a
  per-route body limit; forwarding `on_stop`; a body deadline (the
  `body_ns` TODO at server.tl:485), before uploads are recommended; and
  no longer closing the connection after every 4xx and 5xx (server.tl:429),
  which costs a reconnect per validation error. Later, `Reply.take` for
  WebSockets.
- [`cosmic.net`]: `Conn:peer()`, over the binding core/socket.c:786
  already has.
- [`cosmic.url`]: [`Url.decode_query`] (ordered pairs and by name, `+` as a
  space, invalid escapes refused unless lenient, a cap on pairs),
  [`Url.encode_query`], closing the roadmap item.
- [`cosmic.html`] (C in core/): `url_part` and `SafeUrlPart`,
  `url_query`, `local_href`, `escape_css_attr`, and `SafeJson`.
- [`cosmic.template`]: slots after literal text in a URL (the TODO at
  markup.tl:1052), selector and JSON slots, `{{use}}`, the dialect
  registry, and the `hx-on*` and `hx-vars` refusals, always on.
- [`cosmic.json`]: an `ascii` encode option, for JSON in a response
  header (`HX-Trigger`).
- [`cosmic.hash`]: `Hash.equal`, a constant-time compare, in Teal with a
  `TODO:` for a C binding.
- [`cosmic.poll`]: [`Poll.notifier`], a wait another task wakes.
- [`cosmic.layout`], build/derivation.tl and build/schema.tl: the
  `static/` convention, carried in the reserved `payload` table with each
  file's SHA-256, type and gzip; the vendored htmx in a `web_assets`
  table beside `zoneinfo`.

## order of work

Each step is one or more PRs with tests; a step starts when the steps it
needs have merged.

1. **Prerequisites,** the list above that needs nothing else: reply
   headers and the Cookie join, [`Url.decode_query`], `Conn:peer`,
   `on_stop`, the 4xx close, `Hash.equal`, the JSON `ascii` option,
   [`Poll.notifier`].
2. **A spike on typed-route generics.** Whether Teal infers `P`, `Q` and
   `B` through `Input<P,Q,B>` into the handler's parameters. If not, the
   constructor takes explicit type arguments; the rest of the design does
   not move.
3. **The core:** response constructors, the router (patterns, matching by
   specificity, 404, 405 with Allow, HEAD and OPTIONS, canonical paths,
   trailing-slash redirects, reverse routing, mounts), Request,
   middleware, the exception layer, App, serve, lifespan, the in-process
   TestClient and then the loopback one; the router and query decoding
   fuzzed.
4. **Template escaping and dialects:** the `cosmic.html` escapers, URL
   part slots (which alone make `href="/a/{{.id}}"` work), dialect
   plumbing with the always-on refusals, then the htmx dialect data.
5. **Input, state and security:** the binder and typed routes,
   cookies, sessions (signed, then SQLite), CSRF, CORS, security headers.
6. **htmx and assets:** vendored htmx and its SSE extension with their
   PINs, the `static/` convention and `StaticFiles`, `cosmic.web.htmx`
   and `Htmx.head`.
7. **Streaming and the rest:** `cosmic.channel`, `cosmic.web.sse`,
   `cosmic.http.multipart` (decision 8), and
   `cosmic.web.dev`.
8. **A guide,** doc/guides/web.md, which is a test of its own: one app
   built from an empty directory, its page, its form and its API.

## open questions

Each has a recommendation, which the work follows unless it is
overruled; the parts list smaller ones of their own.

1. **Signed-cookie sessions are readable by the client:** cosmic has no
   cipher. Recommendation: document it, and add an AEAD store when a cipher
   lands, rather than building one from HMAC.
6. **htmx in every executable** (about 55 KB) or only in a program that
   requires `cosmic.web`. Recommendation: every executable in v1, since
   the store has no per-program pruning of tables yet.
7. **The dev loop as a library or a verb.** Recommendation: a library
   (`cosmic.web.dev`) in v1; a `cosmic web dev` verb needs its own entry,
   guide and tests for little more.
8. **A gzip middleware.** input.md and assets.md assume one that leaves
   event streams and precompressed assets alone; core.md (open question 13)
   sketches it. Recommendation: a small `Web.gzip` in step 3, or none in
   v1 and a reverse proxy compresses.
9. **htmx 2.0.11 or 4.x.** 4.0.0 is npm's `next` tag, with SSE built in.
   Recommendation: 2.0.11 and the SSE extension 2.2.4 now; revisit when 4
   is `latest`.

Before any code depends on them, three htmx behaviours the parts state
from memory are to be checked against the pinned file: that `HX-Trigger`
is processed on a response htmx does not swap, that `hx-vars` is still
evaluated, and the names `responseHandling` takes.

## roadmap entries this adds

When the plan lands, doc/roadmap.md gains: file-based routing that
generates the route table; WebSockets over `Reply.take`; OpenAPI from
typed routes; an encrypted session store once there is a cipher; prompt
disconnect detection for event streams; a CSS string escaper and a
`SafeTrigger`, beside the JavaScript and CSS escapers already listed; and
a pool of worker processes for apps whose SQLite work outgrows one
cooperative process.

[Starlette]: https://www.starlette.io/
[`cosmic.hash`]: ../../cosmic/hash.tl
[`cosmic.html`]: ../../cosmic/html.tl
[`cosmic.http.server`]: ../../cosmic/http/server.tl
[`cosmic.json`]: ../../cosmic/json.tl
[`cosmic.layout`]: ../../cosmic/layout.tl
[`cosmic.net`]: ../../cosmic/net.tl
[`cosmic.poll`]: ../../cosmic/poll.tl
[`cosmic.shape`]: ../../cosmic/shape.tl
[`cosmic.template`]: ../../cosmic/template/init.tl
[`cosmic.url`]: ../../cosmic/url.tl
[`Url.escape`]: ../../cosmic/url.tl

[`cosmic.http.wire`]: ../../cosmic/http/wire.tl
[`Poll.notifier`]: ../../cosmic/poll.tl
[`Html.url_part`]: ../../cosmic/html.tl
[`Server.Reply.headers`]: ../../cosmic/http/server.tl
[`Server.serve`]: ../../cosmic/http/server.tl
[`Shape.into`]: ../../cosmic/shape.tl
[`Url.decode_query`]: ../../cosmic/url.tl
[`Url.encode_query`]: ../../cosmic/url.tl
