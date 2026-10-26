--- The records of [`cosmic.web`], in one module so that a request, an app
--- and a route can name each other: every other module of the package
--- implements part of what these describe, and [`cosmic.web`] re-exports
--- the types under its own name.

local Net = require("cosmic.net")
local Server = require("cosmic.http.server")
local Shape = require("cosmic.shape")
local Stream = require("cosmic.stream")
local type Json = require("cosmic.json")
local Url = require("cosmic.url")

local record Types
  --- What a handler answers: the server's own [`Server.Reply`], so
  --- nothing is converted on the way out and the server's checks apply to
  --- it unchanged.
  type Response = Server.Reply

  --- Answers one request. A handler raises only for a fault of the
  --- program: [`Web.abort`] ends a request with a status, and the
  --- exception layer answers a raise with a 500.
  type Handler = function(Request): Response

  --- Wraps a [`Handler`] in another: the function receives the handler it
  --- calls and returns the handler that replaces it. It is applied once,
  --- when the app is built, so state it keeps is made in the factory that
  --- returns it, not per request. It may answer without calling the inner
  --- handler, change the request, and post-process the response; it must
  --- not read the body of a response that is a Reader, which belongs to the
  --- server.
  type Middleware = function(Handler): Handler

  --- What a handler of a typed route answers when its input fails: see
  --- [`Web.route_typed`]. It is given the request and every error the
  --- route's specs found.
  type InvalidHandler = function(Request, Invalid): Response

  --- Cleans up after the server has stopped: what an app's `lifespan`
  --- returns.
  type Shutdown = function()

  --- Something that ends when the server stops: what an app's `hubs`
  --- holds ([`Sse.Hub`] is one). `close` is safe to call twice and never
  --- waits.
  interface Closable
    --- Ends what it holds.
    close: function(Closable)
  end

  --- A typed key into a request's or an app's state: see [`Web.key`]. A key
  --- is its table, so two keys of one name are two keys, and a module
  --- exports the key it owns.
  record Key<T>
    --- The name, for messages.
    name: string
  end

  --- Where the request came from.
  record Client
    --- The numeric address.
    host: string
    --- The port; nil where the address came from a header, which names
    --- none.
    port?: integer
  end

  --- What a request matched, for logs and middleware.
  record RouteInfo
    --- The route's name with its mounts' names before it ("api:item"),
    --- or "" when it has none.
    name: string
    --- The whole pattern, mount prefixes included: "/api/items/:id"; a
    --- mount that serves a handler ends in "/*".
    pattern: string
    --- The methods the route answers; empty for a mount that serves a
    --- handler, which takes every method.
    methods: {string}
  end

  --- What the router does about a trailing "/": see [`Web.RouterOptions`].
  enum TrailingSlash
    "redirect"
    "strict"
  end

  --- What the router decided for a request: see [`Web.Outcome`].
  enum OutcomeKind
    "match"
    "not_found"
    "not_allowed"
    "options"
    "redirect"
    "bad_path"
    "bad_host"
  end

  --- How a request was left unrouted, or how it was routed: the router's
  --- answer, read by the terminal handler of [`Web.app`] and by
  --- [`Router.match`].
  record Outcome
    --- "match", "not_found", "not_allowed" (405), "options" (the
    --- automatic OPTIONS), "redirect" (a canonical or trailing-slash 308),
    --- "bad_path" (400) or "bad_host" (400).
    kind: OutcomeKind
    --- What matched; nil unless `kind` is "match".
    route?: RouteInfo
    --- The path parameters, decoded.
    params?: {string:string}
    --- The `Allow` header's value for "not_allowed" and "options".
    allow?: string
    --- Where "redirect" leads: a path starting with one "/", its query
    --- kept.
    location?: string
    --- Why "bad_path" or "bad_host".
    detail?: string
    --- The handler to call: the route's with its stacks of middleware
    --- around it for a match, the terminal inside the middleware of the
    --- innermost mount entered for any other kind.
    handler: Handler
    --- The prefix of the innermost mount entered; "" at the top.
    mount_path: string
  end

  --- One request, as a handler and its middleware see it. It wraps the
  --- server's [`Server.Request`] and is mutable by middleware (`state`,
  --- typed keys) and by the router (`params`, `route`) and nothing else.
  record Request
    --- The server's request, for anything not lifted below. Its `path` is
    --- as sent: authorization compares `path` or `segments`, never this.
    raw: Server.Request
    --- "GET", "POST", ... as sent. A HEAD stays "HEAD" although the route
    --- matched is the GET's.
    method: string
    --- The canonical path, still %-escaped: rebuilt from `segments`, so it
    --- holds no empty and no "." segment, and ends in "/" only where the
    --- request did and a segment precedes it. "/" for a path the router
    --- refused (400).
    path: string
    --- The decoded segments of `path`: {"items", "a b"} for /items/a%20b.
    segments: {string}
    --- The escaped query string as sent, without its "?".
    query_string: string
    --- Lowercased names; repeated headers joined with ", ", but `cookie`
    --- with "; ".
    headers: {string:string}
    --- Path parameters matched, decoded, all strings. Empty until the
    --- router has matched.
    params: {string:string}
    --- The full prefix of the mount serving this request; "" at the top.
    mount_path: string
    --- The route matched; nil for a 404, a 405 and the router's other
    --- answers.
    route?: RouteInfo
    --- The app serving this request.
    app: App
    --- The untyped escape hatch for ad-hoc scratch values; a module
    --- shipping middleware uses a typed [`Web.key`] instead.
    state: {string:any}
    --- The peer, or nil where the connection has none (a unix socket). With
    --- `trusted_proxy`, the address `X-Forwarded-For` ends in.
    client?: Client
    --- "http", or "https" when `trusted_proxy` is set and the proxy said so.
    scheme: string
    --- The host asked for, as the Host header gives it (with its port),
    --- or, with `trusted_proxy`, `X-Forwarded-Host`; nil where none was
    --- sent.
    host?: string
    --- What the router decided; set before the middleware stack runs.
    outcome?: Outcome

    --- Whether the path ended in "/" after its last segment.
    trailing: boolean
    --- The typed values of [`Web.key`], by key.
    slots: {any:any}
    --- The stream bodies made for this request ([`Sse.EventStream`]):
    --- the app closes those the final reply does not carry.
    bodies: mut {Stream.Reader}
    --- The body once read, nil until then.
    body_text?: string
    --- Why reading the body failed, nil until it did.
    body_failure?: string

    --- The first value of header `name`, matched in any case; nil when
    --- the request has none.
    header: function(self: Request, name: string): string?
    --- The body, read whole once and kept; also put back as
    --- `raw.body`, so a later reader of it sees the same bytes. Nil and
    --- why when the read fails (the server then answers 413, 400 or 408
    --- in place of the handler's reply), so a handler may `assert` it.
    bytes: function(self: Request): string?, string
    --- The body as text: the `bytes` when they are valid UTF-8, else
    --- nil and why.
    text: function(self: Request): string?, string
    --- The query string decoded by [`Url.decode_query`], once and kept;
    --- nil and why for a malformed escape, which is a 400. A query is not
    --- read leniently.
    query: function(self: Request): Url.Query?, string
    --- The offer the request's Accept header likes best, ties going to
    --- the offer earlier in `offers`; the first offer where the request
    --- sent no Accept; nil when it accepts none.
    accepts: function(self: Request, offers: {string}): string?
    --- The URL of the route named `name`: see [`App.url_for`].
    url_for: function(self: Request, name: string, params?: {string: string | integer},
        query?: {string:string}): string?, string
    --- The value `req:set` stored under `key`, or nil.
    get: function<T>(self: Request, key: Key<T>): T?
    --- Stores `value` under `key` for the rest of the request.
    set: function<T>(self: Request, key: Key<T>, value: T)
    --- "scheme://host[:port]" for building an absolute URL, only where the
    --- app has `trusted_hosts` (the Host header is the client's: a link made
    --- from it is open to host-header injection). It is made from the host
    --- and port the header was validated to hold, lowercase. Nil and why
    --- otherwise.
    base_url: function(self: Request): string?, string
  end

  --- Where an app writes its lines, and what [`Web.stderr_sink`] makes.
  record Sink
    --- Writes `text` as one line; the sink adds the newline.
    line: function(self: Sink, text: string)
  end

  --- One route or mount: plain data that [`Web.router`] and [`Web.app`]
  --- build their tables from.
  record Route
    --- The methods answered, uppercase; empty for a mount.
    methods: {string}
    --- The pattern; a mount's prefix.
    pattern: string
    --- The leaf's handler; nil for a mount.
    handler?: Handler
    --- The name [`App.url_for`] finds it by; "" for none.
    name: string
    --- Its own middleware, outermost first.
    middleware: {Middleware}
    --- A mount's routes; nil for a leaf and for a mount of a handler.
    routes?: {Route}
    --- A mount of a handler: everything under the prefix is sent to it.
    fallback: Handler
    --- A mount's reverse resolver: see [`Web.MountOptions.reverse`].
    reverse: function(prefix: string, params: {string:string}): string?, string
    --- What a typed route binds, erased of its types; nil for a plain
    --- route and for a mount.
    input?: RouteInput
  end

  --- What [`Web.route`] and the method constructors take beside the handler.
  -- TODO: once Server.ServeSpec has `body_limit(method, path)`, add
  -- `body_limit` here and give Web.serve the router's lookup of it, from
  -- `Route.input.max_bytes`.
  record RouteOptions
    --- The name [`App.url_for`] finds the route by, unique in its router.
    name?: string
    --- The route's own middleware, outermost first; inside the mount's and
    --- the app's.
    middleware?: {Middleware}
    --- For a typed route ([`Web.route_typed`]): answers input that fails
    --- the route's specs in place of the default problem or error page.
    on_invalid?: InvalidHandler
    --- For a typed route: the body limit, the names left out of a
    --- re-render and the rest of [`Input.Options`].
    input_options?: InputOptions
  end

  --- What [`Web.mount`] and [`Web.mount_handler`] take.
  record MountOptions
    --- The mount's name: its routes are named "name:inner", and a
    --- handler mount answers `url_for(name, ...)` through `reverse`.
    --- Without one the routes keep their own names.
    name?: string
    --- The mount's middleware, outermost first, around its whole router,
    --- so a 404 or 405 raised inside passes through it.
    middleware?: {Middleware}
    --- Answers `url_for(<mount name>, params)` for a handler mount: the
    --- full URL, given the mount's full prefix (outer mounts included)
    --- and the params as strings. Nil and why for params it cannot
    --- resolve.
    reverse?: function(prefix: string, params: {string:string}): string?, string
  end

  --- What [`Web.router`] takes.
  record RouterOptions
    --- "redirect" (default): a request that differs from a route's
    --- spelling only by a trailing "/" is answered 308 to the spelling;
    --- "strict": it is a 404.
    trailing_slash?: TrailingSlash
  end

  --- The type of an absent slot of [`Web.input`]: a path, query or body
  --- the route does not read. A handler is given an empty one for it.
  record None
  end

  --- One refused field of an input, as [`Input.Invalid`] lists it and as a
  --- problem body's `errors` repeats it.
  record FieldError
    --- Where the value came from: "path", "query", "form" or "body". (Not
    --- `in`, OpenAPI's word: it is a Lua keyword.)
    source: string
    --- The field: "email", "address.city", "tags.0", or "" for the whole
    --- body.
    field: string
    --- For a JSON body only: the JSON Pointer of the failing value
    --- ("/address/city", "" for the whole body); nil for the other sources.
    pointer?: string
    --- Plain text for a person ("must be a whole number"); it holds no
    --- more of the submitted value than a JSON type error names.
    message: string
    --- A stable code for a program: "required", "integer", "number",
    --- "boolean", "one_of", "type", "unknown", "repeated" and "invalid" (a
    --- handler's own, [`Input.fail`]) for a value that fails its spec, and
    --- "json", "utf8", "too_large", "content_type" and "malformed" for
    --- input that cannot be read.
    code: string
  end

  --- Input that was refused: data, not a response. [`Web.route_typed`]
  --- turns it into a problem body or an error page, or gives it to the
  --- route's `on_invalid`.
  record Invalid
    --- 400 for input that cannot be decoded, 408 for a body that came too
    --- slowly, 413 over the limit, 415 for a wrong Content-Type and 422 for
    --- a value that decodes but fails its spec.
    status: integer
    --- One line: the first error, and how many more there are.
    message: string
    --- Every error of the source that failed, in the spec's field order.
    errors: {FieldError}
    --- The values submitted, for re-rendering a form; the names in
    --- [`Input.Options.secret`] are left out. Nil for a JSON body.
    submitted?: Url.Query
  end

  --- What a reader or binder of cosmic.web.input answers: the value, or
  --- why there is none: `invalid` is set exactly when `value` is nil.
  record Parsed<T>
    --- What was read or bound; nil when `invalid` is set.
    value?: T
    --- Why not; nil when the input was read.
    invalid?: Invalid
  end

  --- What the readers and binders of cosmic.web.input take; every
  --- field is optional.
  record InputOptions
    --- The largest body read, in bytes (64 KiB; 16 MiB for
    --- [`Input.multipart`]). The server's own `limits.body_bytes` (1 MiB)
    --- comes first where it is lower: a larger upload needs [`Web.serve`]
    --- given a higher `limits.body_bytes`, for every route
    --- (see [`Input.multipart`]).
    max_bytes?: integer
    --- Field names left out of [`Invalid.submitted`]: passwords, tokens.
    secret?: {string}
    --- The `source` of the errors a binder writes: "form" by default, or
    --- "query" or "path". [`Input.bind_strings`] reads it.
    source?: string
    --- "error" refuses a scalar field sent twice (`code = "repeated"`);
    --- by default the last value wins.
    repeated?: string
    --- For a multipart body (the rest of these too): the largest file part,
    --- in bytes (8 MiB). A file part over it is a 413.
    max_file_bytes?: integer
    --- The largest text part, in bytes as sent (1 MiB).
    max_field_bytes?: integer
    --- Most file parts (10).
    max_files?: integer
    --- Most parts of either kind (100).
    max_parts?: integer
    --- The directory file parts are spooled to, under random names. It must
    --- exist. Without one, a private directory made under the system's temp
    --- directory is removed with its files when the request ends.
    dir?: string
  end

  --- A route's body slot: see [`Web.json_body`], [`Web.form_body`] and
  --- [`Web.multipart_body`].
  record Body<B>
    --- "json", "form", "multipart" or "none".
    kind: string
    --- The body's spec.
    typed: Shape.Typed<B>
  end

  --- A route's three slots, which [`Web.route_typed`] binds before the
  --- handler runs: see [`Web.input`].
  record Input<P,Q,B>
    --- The path parameters' spec.
    path: Shape.Typed<P>
    --- The query's spec.
    query: Shape.Typed<Q>
    --- The body's.
    body: Body<B>
  end

  --- What a typed route binds, without the types.
  record RouteInput
    --- The path spec; nil for none.
    path?: Shape.Spec
    --- The query spec; nil for none.
    query?: Shape.Spec
    --- "json", "form", "multipart" or "none".
    body_kind: string
    --- The body spec; nil for none.
    body?: Shape.Spec
    --- The body limit the route enforces.
    max_bytes: integer
  end

  --- One segment of a pattern: a literal, `:name`, or `*name`.
  record Segment
    --- "literal", "param" or "rest".
    kind: string
    --- The literal's text, or the parameter's name.
    text: string
  end

  --- One route at a node of the trie, for one method.
  record Terminal
    --- The route's description.
    info: RouteInfo
    --- The names of its parameters, in the order they appear.
    names: {string}
    --- Whether its pattern ends in "/".
    slash: boolean
    --- The handler with every middleware folded around it.
    handler: Handler
  end

  --- The routes that end at one node, by method.
  record Methods
    --- The terminal of each method.
    by_method: mut {string: Terminal}
  end

  --- What a mount makes of the segments after its prefix.
  record Mount
    --- The mount's full prefix: "/api".
    prefix: string
    --- Its description, for a mount that serves a handler.
    info?: RouteInfo
    --- A mount of a handler: the handler with its middleware folded in.
    handler: Handler
    --- A mount of routes: their router.
    router?: Router
  end

  --- One node of the trie of segments.
  record Node
    --- The children matching one literal segment.
    literal: mut {string: Node}
    --- The child matching any one segment, parameter names aside.
    param?: Node
    --- The routes whose pattern ends here.
    exact?: Methods
    --- The routes whose pattern ends here in `*name`.
    wild?: Methods
    --- A mount at this prefix; it has no other content.
    mount?: Mount
  end

  --- How [`url_for`] finds a name.
  record ReverseEntry
    --- The segments of the whole pattern; nil for a mount.
    segments?: {Segment}
    --- Whether the pattern ends in "/".
    slash?: boolean
    --- A mount's prefix.
    prefix?: string
    --- Whether the name is a mount's.
    mount?: boolean
    --- A mount's resolver.
    resolve: function(prefix: string, params: {string:string}): string?, string
  end

  --- Routes compiled for matching: see [`Web.router`].
  record Router
    --- What an app would do with a request of `method` for `path`, as the
    --- client sent it, without running a handler. "match" has the route and
    --- params; "not_allowed" and "options" have `allow`; "redirect" the
    --- `location`; "bad_path" the `detail`.
    match: function(self: Router, method: string, path: string): Outcome
    --- The URL of the route named `name`, filled with `params`, with
    --- `query` appended in name order; nil and why for an unknown name, a
    --- missing or extra parameter, or a mount without a reverse. A `:param`
    --- is escaped as [`Html.url_part`] does, a `*rest` split on "/" and
    --- each piece escaped.
    reverse: function(self: Router, name: string, params?: {string: string | integer},
        query?: {string:string}): string?, string

    --- The root of the trie.
    root: Node
    --- The trailing-slash policy.
    policy: TrailingSlash
    --- The names of the whole tree, mounts' included.
    names: {string: ReverseEntry}
    --- Every method any route of the tree answers.
    verbs: {string:boolean}
    --- The handler for a request this router cannot route: the terminal
    --- inside the middleware of the mount that holds the router.
    miss: Handler
    --- The prefix of the mount that holds the router; "" at the top.
    mount_path: string
  end

  --- What [`Web.app`] takes. A field not named here raises, naming it.
  record AppSpec
    --- The routes; order does not matter.
    routes?: {Route}
    --- The app's middleware, outermost first.
    middleware?: {Middleware}
    --- Called once before the listeners open, outside the event loop (it
    --- must not wait on [`cosmic.poll`]); returns the function that
    --- cleans up after the server stops, or nil for none. Nil and why
    --- stops [`Web.serve`] before it listens.
    lifespan?: function(app: App): Shutdown?, string
    --- Answers a fault with a page holding its message and stack
    --- (false by default, never taken from the environment): it
    --- exposes source paths and values.
    debug?: boolean
    --- "redirect" (default) or "strict": see [`Web.RouterOptions`].
    trailing_slash?: TrailingSlash
    --- Hosts the app answers to, each a name (or an IPv6 literal in
    --- brackets) without a port: an entry with a port, or that is no host,
    --- raises when the app is made. A request for another host, at any
    --- port, or whose Host header is not `host[:port]` whole, is a 400.
    trusted_hosts?: {string}
    --- Take the scheme, host and client from `X-Forwarded-Proto`,
    --- `X-Forwarded-Host` and `X-Forwarded-For` (false by default). Only
    --- the last entry of each is read: the one the proxy next to the app
    --- added, since the earlier ones are the client's.
    trusted_proxy?: boolean
    --- Answers a status in place of the default error page, by status.
    error_pages?: {integer: Handler}
    --- Makes the page of an error that has no entry in `error_pages`: the
    --- request, the status and the detail.
    error_view?: function(Request, integer, string): Response
    --- Where the app's lines go; [`Web.stderr_sink`] by default.
    sink?: Sink
    --- Serve htmx and its SSE extension under `/_web/` (true by default),
    --- ahead of the routes: a catch-all route cannot shadow them, and no
    --- route may be at or under `/_web/`. A path there that is none of
    --- these files is a 404. With false the app answers `/_web/` paths as
    --- any other, and a page that loads [`Htmx.head`] serves the files itself.
    builtin?: boolean
    --- Closed when the server begins to stop, in order, after the
    --- functions of `app:on_stop`: a hub's streams end at once, not at
    --- the grace. None by default.
    hubs?: {Closable}
    --- The most event streams open at once ([`Sse.EventStream`] answers
    --- 503 past it); half of the server's connection limit by default, so
    --- ordinary requests keep the other half.
    max_streams?: integer
    --- Set by [`Dev.app`] for an app in development mode: [`Web.serve`]
    --- refuses (false and why) a listener beyond the loopback and a
    --- `trusted_proxy`, since such an app shows a fault's stack and reloads
    --- pages, and logs one line saying so. The guard is in [`Web.serve`]:
    --- an app served through [`Server.serve`] directly skips it. Only
    --- [`Dev.app`] reads `COSMIC_WEB_DEV`; a [`Web.app`] ignores it. False
    --- by default.
    dev?: boolean
  end

  --- A built app: [`Web.app`] derives the router and the handler.
  record App
    --- The app's configuration, as given.
    spec: AppSpec
    --- Resource of the lifespan, by [`Web.key`]: `app.state[KEY] = db`.
    state: {any:any}
    --- The compiled routes.
    router: Router
    --- Answers one request of the server: the server's entry point alone
    --- ([`Web.serve`] and the test clients call it), taking the whole
    --- [`Server.Request`] and the full path; middleware and handlers are
    --- not called with it.
    handle: function(raw: Server.Request): Response
    --- [`Router.reverse`] on the app's routes.
    url_for: function(self: App, name: string, params?: {string: string | integer},
        query?: {string:string}): string?, string
    --- True once the server has begun to stop; false again when
    --- [`Web.serve`] starts. A long-lived response polls it.
    stopping: function(self: App): boolean
    --- Registers `fn`, run in registration order when the server begins to
    --- stop (before the caller's [`on_stop`]). An error in it goes to the
    --- sink and the rest still run.
    on_stop: function(self: App, fn: function())

    --- Whether the server has begun to stop.
    stopped: boolean
    --- The functions [`on_stop`] registered.
    stoppers: mut {function()}
    --- The open event streams: how to end each, by a key of its own. For
    --- [`Sse.EventStream`] alone.
    streams: {any: function()}
    --- How many event streams are open, which `streams` holds.
    stream_count: integer
    --- The most [`stream_count`] may reach: the app's `max_streams`, else
    --- half the connections [`Web.serve`] is given.
    stream_limit: integer
  end

  --- What [`Web.serve`] takes.
  record ServeOptions
    --- Where to listen, as [`Server.ServeSpec.listeners`].
    listeners: {Net.Address}
    --- As [`Server.ServeSpec.limits`].
    limits?: Server.ServeSpec.Limits
    --- As [`Server.ServeSpec.timeout_ns`].
    timeout_ns?: integer
    --- As [`Server.ServeSpec.idle_ns`].
    idle_ns?: integer
    --- As [`Server.ServeSpec.head_ns`].
    head_ns?: integer
    --- As [`Server.ServeSpec.body_ns`].
    body_ns?: integer
    --- How long requests in flight have to finish once the server stops
    --- (10 seconds): the server's own default waits for every request,
    --- and an event stream never ends.
    grace_ns?: integer
    --- As [`Server.ServeSpec.on_ready`].
    on_ready?: function({Net.Address}, Net.Server)
    --- Called when the server begins to stop, after `app:stopping()` is
    --- true and the functions of `app:on_stop` have run.
    on_stop?: function(Net.Server)
  end

  --- What a constructor takes beside its body.
  record ResponseOptions
    --- Replaces the constructor's status.
    status?: integer
    --- Added to the constructor's headers, replacing one of the same name
    --- in any case; a list writes one line per element.
    headers?: {string: string | {string}}
    --- Close the connection after the reply.
    close?: boolean
    --- The size of a [`Web.stream`] body, when it is known.
    length?: integer
  end

  --- What a test client's request takes.
  record TestOptions
    --- Request headers.
    headers?: {string:string}
    --- Appended to the path's query, in name order; a list repeats the
    --- name.
    query?: {string: string | {string}}
    --- An urlencoded form body.
    form?: {string: string | {string}}
    --- A JSON body, with its Content-Type.
    json?: Json.Value
    --- A body as it is, with `content_type`.
    body?: string | Stream.Reader
    --- The Content-Type of `body`.
    content_type?: string
    --- Follow 301, 302, 303, 307 and 308 (false): the first three turn a
    --- POST into a GET.
    follow_redirects?: boolean
    --- Cookies for this request alone, beside the client's jar.
    cookies?: {string:string}
    --- Leave a Reader body unread in `stream` (false: it is read whole
    --- into `body`).
    stream?: boolean
  end

  --- A reply as a test client saw it.
  record TestResponse
    --- The status.
    status: integer
    --- By lowercased name; repeated headers joined with ", ".
    headers: {string:string}
    --- Every line of a header by lowercased name, in order: Set-Cookie
    --- is read here.
    lines: {string:{string}}
    --- The body; "" for a stream, a HEAD and a status with none.
    body: string
    --- The unread Reader, only where the request asked for `stream`.
    stream?: Stream.Reader
    --- Whether the status is from 200 to 299.
    ok: boolean
    --- The Location header of a redirect; nil for any other reply.
    redirect_location?: string

    --- Every line of header `name`, in order; `{}` when it has none.
    header_list: function(self: TestResponse, name: string): {string}
    --- The body as text.
    text: function(self: TestResponse): string
    --- The body decoded as JSON; nil and why when it is none.
    json: function(self: TestResponse): any?, string
  end
end

return Types
