# web security

<!-- policy: profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } -->

The defences of [`cosmic.web`] are middleware you list in the app, so the
list shows what protects it. This guide builds `guestbook`, a page with a
plain form and an htmx button, behind the three that every page with a
cookie needs: sessions, a CSRF check and security headers. It then covers
limiting failed logins, what an app behind a proxy says about itself, and
the defaults to leave alone. It starts from an empty directory and needs
only what [web apps](web.md) says about routes and templates; the CSRF
token lives in a [session](web-sessions.md).

## csrf

A cookie is sent by the browser whoever made the page, so a form on another
site could post to yours. [`Csrf.middleware`] checks every request whose
method changes state, with two layers:

- **Where it came from.** The `Origin` header (the `Referer`'s origin where
  there is none) must be the app's own, or one of `trusted_origins`;
  `Origin: null` is refused, and so is `Sec-Fetch-Site: cross-site`
  whatever `Origin` says. A request with neither header (curl, a server) passes
  this layer.
- **A synchronizer token.** A masked token kept in the session must come
  back in the `X-CSRF-Token` header or the `csrf_token` field of the form.

GET and TRACE are never checked, so a GET must not change anything. The
middleware sits inside the session middleware. `trusted_origins` is for a
page on another origin that is meant to post to this one; it still needs
its token, and [the API guide](web-api.md) says how it differs from CORS.

A page carries the token two ways. `Csrf.hx_headers(req)` is a JSON value
for `<body hx-headers='...'>`: every htmx request below the element sends
the header, so no form needs to remember it. [`Csrf.field`] is the hidden
input of a plain form, and [`Csrf.meta`] a `<meta>` tag for a script that
sets the header itself. A urlencoded form's token must lie in the first 16
KiB of the body, and a multipart form's must be its first part: put the
field first. `session:regenerate()` drops the secret, so tokens seen before
a login stop working; a boosted login should end with `HX-Redirect`, which
loads a fresh page.

The `HX-Request` header exempts nothing. A request with `Authorization:
Bearer` skips the token layer by default, since a cross-site page cannot
set that header without a preflight. For an API, it is better that no
cookie authenticates it, as [the API guide](web-api.md) shows.

## the page

The layout carries the token for htmx in `hx-headers`, and the index has a
plain form with the field and a button that posts with htmx. The head is
[`Htmx.head`]'s, for the reason [the first guide](web.md) gives.

```teal file=pages/data.tl
local Html = require("cosmic.html")

--- What the templates beside it render.
local record data
  record Page
    field: Html.SafeHtml
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

```teal file=pages/layout.tmpl
{{type Layout from pages.data}}{{use htmx}}
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{{.title}}</title>
{{.head}}
</head>
<body hx-headers='{{.csrf}}'>
{{.body}}
</body>
</html>
```

```teal file=pages/index.tmpl
{{type Page from pages.data}}{{use htmx}}
<form method="post" action="/notes">
  {{.field}}
  <input name="text">
  <button>sign</button>
</form>
<button hx-post="/clap" hx-swap="outerHTML">clap</button>
```

```teal file=site.tl
--- The guestbook's pages: a form post and an htmx post, both changing state.

local Csrf = require("cosmic.web.csrf")
local Headers = require("cosmic.web.headers")
local Html = require("cosmic.html")
local Htmx = require("cosmic.web.htmx")
local Web = require("cosmic.web")
local index = require("pages.index")
local layout = require("pages.layout")

local record Site
end

--- The routes.
function Site.routes(): {Web.Route}
  return {
    Web.get("/", function(req: Web.Request): Web.Response
      return Web.html(layout.render({
        title = "guestbook",
        head = Htmx.head{ nonce = req:get(Headers.NONCE) },
        csrf = Csrf.hx_headers(req),
        body = index.render({ field = Csrf.field(req) }),
      }))
    end),
    Web.post("/notes", function(_req: Web.Request): Web.Response
      return Web.text("signed", { status = 201 })
    end),
    Web.post("/clap", function(_req: Web.Request): Web.Response
      return Web.html(Html.trust("<span>clapped</span>"))
    end),
  }
end

return Site
```

## security headers

[`Headers.middleware`] sets, on every response that passes out through it:
`X-Content-Type-Options: nosniff`, `Referrer-Policy`,
`X-Frame-Options: DENY`, `Cross-Origin-Opener-Policy` and a
`Permissions-Policy` that turns the camera, the microphone and geolocation
off. A header the handler already set stays. It also holds the two that an
app chooses:

- **`csp`**, a Content-Security-Policy, which is off until asked for.
  [`Csp.htmx_default()`] of [`cosmic.web.csp`] lets an htmx app load its own
  scripts, styles, images and connections and nothing else. Try a new policy
  with `csp_report_only = true` first.
- **`hsts`**, `Strict-Transport-Security`, sent on https requests only. A
  browser keeps it for the whole `max_age`, so an app turns it on only once
  the site is https for good. The app below takes it as an
  option, and [the deployment guide](web-deploy.md) reads it from the
  environment.

With `nonce = true` each request draws a nonce, `req:get(Headers.NONCE)`
reads it, and a `{nonce}` source in a directive becomes `'nonce-<value>'`.
The nonce is for an inline script the layout carries; pass it to
[`Htmx.head`] too, as `site.tl` does, so htmx's tags and its own inline use
carry it. A page with a nonce is not for a shared cache, and the response is
marked private.

## the app

The middleware list is stacked in order, the first outermost: the headers
(so errors get them too), then the session and the CSRF check. `trusted_hosts`
and `trusted_proxy` are the app's own words about where it runs, below.

```teal file=guestbook.tl
--- The guestbook app: the pages behind sessions, CSRF and security headers.

local Csp = require("cosmic.web.csp")
local Csrf = require("cosmic.web.csrf")
local Headers = require("cosmic.web.headers")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local Site = require("site")
local Web = require("cosmic.web")

local record Guestbook
  --- What [`Guestbook.app`] takes.
  record Options
    --- Signing keys for the session cookie, newest first.
    keys: {string}
    --- Send HSTS on https requests; only once the site is https for good.
    hsts?: boolean
    --- The hosts the app responds to; nil for any.
    trusted_hosts?: {string}
    --- Where the proxy that ends TLS connects from; nil for no proxy.
    trusted_proxy?: {string}
  end
end

--- The app.
function Guestbook.app(opts: Guestbook.Options): Web.App
  local directives: mut {string: {string}} = {}
  for name, sources in pairs(Csp.htmx_default().directives) do directives[name] = sources end
  directives["script-src"] = { "'self'", "{nonce}" }
  local csp: Csp.Policy = { directives = directives }
  local headers: Headers.Options = { csp = csp, nonce = true }
  if opts.hsts == true then headers = { csp = csp, nonce = true, hsts = { max_age = 31536000 } } end
  return Web.app{
    routes = Site.routes(),
    middleware = {
      Headers.middleware(headers),
      Session.middleware{ store = SessionCookie.store{ keys = opts.keys } },
      Csrf.middleware(),
    },
    trusted_hosts = opts.trusted_hosts,
    trusted_proxy = opts.trusted_proxy,
  }
end

return Guestbook
```

## failed attempts

A password or a one-time code can be guessed, so a login limits wrong
guesses. [`Attempts.limiter`] counts failures per key in memory: after
`limit` of them within `window_ns`, the key is refused until the oldest is
`window_ns` old. The handler asks before it checks the secret, records a
failure, and forgets the key after a success; [`Attempts.too_many`]
returns a 429 with `Retry-After`. Read the form first and do not wait on
anything between asking and recording, or concurrent guesses each see the
count from before the others failed.

The key is the choice that matters. One key for everyone stops a guesser
however many addresses it has, but anyone can lock everyone out; it suits
an app with a few known users. A key per client address,
`req.client.host`, locks out the guesser alone. But behind a proxy every
request comes from the proxy, so there is one key for all, unless the app
sets `trusted_proxy` (the next section). A key per account name lets
anyone lock that account out. The limiter keeps at most `max_keys` keys.
A flood of new keys (made-up names, many addresses) pushes old ones out
and starts their count over, so limit an account key together with an
address key. The counts live in memory, so a restart forgets them and each
process of an app keeps its own.

## behind a proxy

A proxy that ends TLS makes every request arrive as plain http from the
proxy's address. `trusted_proxy` names where the proxy connects from, and
the app believes what a request from there says: the scheme, host and
client then come from `X-Forwarded-Proto`, `X-Forwarded-Host` and
`X-Forwarded-For`. Each entry is an address (`"10.0.0.2"`), a prefix
(`"10.0.0.0/8"`), `"loopback"` for a proxy on the same machine, or `"unix"`
for one that connects to a unix-socket listener. Then the CSRF origin check
compares https origins and HSTS is sent. The session cookie is `Secure` and
named `__Host-session` either way, whatever scheme the app sees ([the
sessions guide](web-sessions.md)). Without it every https `Origin` looks
foreign to CSRF.

A request from any other peer keeps its own scheme, host and address,
whatever headers it sends. So a client that reaches the app past the proxy
cannot pass for https, another host or another address. Only the last
entry of `X-Forwarded-Proto` and `X-Forwarded-Host` is read, the one the
proxy added. The client is the right-most entry of `X-Forwarded-For` that
is none of the proxy's addresses, since every entry left of it is the
client's own to write. Where there is none, the client is the proxy itself.
Name the proxy alone: a prefix wider than the proxy
lets every address in it say what it likes.

"The one the proxy added" holds only where the proxy sets each of the three
headers on every request. One that passes a header on as the client sent it
leaves its last entry to the client. nginx sets none of them unless told, so
its configuration names all three. The first two replace what the client
sent. The third appends the client's address to what the client sent, and
the app reads that last entry. `$http_host` keeps a port the client named.

```text
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $http_host;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```

Caddy's `reverse_proxy` and Tailscale Serve set all three already.

`trusted_hosts` lists the hosts the app responds to. A request for another
host, at any port, is a 400. The `Host` header is the client's. So an app
that builds absolute links from it, or that sits behind a proxy forwarding
any host, should name its own hosts. Otherwise a forged `Host` can put an
attacker's name in a password-reset link. It also makes `req:base_url()`
available for building absolute links.

## the tests

The tests go through a page for its token as a browser does. They check the
two layers of CSRF, the headers and the nonce, and what the proxy options
change.

```teal file=guestbook_test.tl
local Guestbook = require("guestbook")
local Net = require("cosmic.net")
local Secret = require("cosmic.web.secret")
local Web = require("cosmic.web")

--- The options of an app with a fresh key, with the settings of a deployment as given.
local function options(trusted_proxy?: {string}, hsts?: boolean, trusted_hosts?: {string}): Guestbook.Options
  return { keys = { Secret.generate() }, trusted_proxy = trusted_proxy, hsts = hsts, trusted_hosts = trusted_hosts }
end

local function app(): Web.App
  return Guestbook.app(options())
end

--- A browser on an https page of the app, which sends the Secure session cookie back.
local function browser(): Web.TestClient
  local client = Web.test_client(app())
  client.scheme = "https"
  return client
end

--- The CSRF token a page carries in its `hx-headers`.
local function token_of(client: Web.TestClient): string
  return assert(client:get("/").body:match("X%-CSRF%-Token&quot;:&quot;([%w_-]+)&quot;"))
end

local function test_a_post_needs_the_token_from_the_page()
  local client = browser()
  local token = token_of(client)
  assert(client:post("/notes", { form = { text = "hi" } }).status == 403, "no token")
  assert(client:post("/notes", { form = { text = "hi", csrf_token = token } }).status == 201, "the form field")
  assert(client:post("/clap", { headers = { ["HX-Request"] = "true", ["X-CSRF-Token"] = token } }).status == 200,
    "the header htmx sends from hx-headers")
  assert(client:post("/clap", { headers = { ["HX-Request"] = "true" } }).status == 403, "HX-Request exempts nothing")
end

local function test_a_cross_site_post_is_refused_even_with_the_token()
  local client = browser()
  local token = token_of(client)
  local forged = { ["X-CSRF-Token"] = token, ["Origin"] = "https://evil.example" }
  assert(client:post("/clap", { headers = forged }).status == 403, "another origin")
  local fetched = { ["X-CSRF-Token"] = token, ["Sec-Fetch-Site"] = "cross-site" }
  assert(client:post("/clap", { headers = fetched }).status == 403, "the browser says cross-site")
end

local function test_the_nonce_in_the_policy_is_the_one_in_the_tags()
  local page = browser():get("/")
  assert(page.headers["x-content-type-options"] == "nosniff" and page.headers["x-frame-options"] == "DENY")
  local policy = page.headers["content-security-policy"] or ""
  local nonce = assert(policy:match("'nonce%-([%w_-]+)'"))
  assert(page.body:find('nonce="' .. nonce .. '"', 1, true))
end

local function test_hsts_is_for_https_and_only_when_asked()
  local secure = { ["X-Forwarded-Proto"] = "https" }
  local plain = Web.test_client(Guestbook.app(options({ "loopback" })))
  assert(plain:get("/", { headers = secure }).headers["strict-transport-security"] == nil)
  local client = Web.test_client(Guestbook.app(options({ "loopback" }, true)))
  assert(client:get("/", { headers = secure }).headers["strict-transport-security"] == "max-age=31536000")
  assert(client:get("/").headers["strict-transport-security"] == nil, "not on http")
  local direct = client:get("/", { headers = secure, peer = Net.tcp("192.0.2.7", 1) })
  assert(direct.headers["strict-transport-security"] == nil, "a peer that is not the proxy is ignored")
end

local function test_the_session_cookie_is_secure_with_or_without_the_proxy()
  local secure = { ["X-Forwarded-Proto"] = "https" }
  local behind = Web.test_client(Guestbook.app(options({ "loopback" }))):get("/", { headers = secure })
  assert((behind.headers["set-cookie"] or ""):find("^__Host%-session=.*; Secure") ~= nil)
  local alone = Web.test_client(app()):get("/", { headers = secure })
  assert((alone.headers["set-cookie"] or ""):find("^__Host%-session=.*; Secure") ~= nil, "Secure over http too")
end

local function test_a_host_the_app_does_not_name_is_400()
  local client = Web.test_client(Guestbook.app(options(nil, nil, { "app.example.com" })))
  assert(client:get("/", { headers = { Host = "app.example.com" } }).status == 200)
  assert(client:get("/", { headers = { Host = "evil.example" } }).status == 400)
end
```

## safe defaults

Most of the safety is that the unsafe thing is not the easy one:

- A template escapes each slot for the place it lands, and refuses a slot
  where no escaping is right; [`Web.html`] takes only markup that was made
  safe, never a string.
- A redirect target from the client (a referer, a `?next=`) goes through
  [`Web.safe_next`], which keeps a local path only.
- A fault gets a 500 with nothing of it shown; `debug` is false unless
  set, and is never read from the environment.
- The session cookie is `HttpOnly` and `SameSite=Lax`, and keys come from
  the environment, never from source.
- The files htmx needs are served from the binary with integrity values, and
  the htmx configuration allows no `eval`, no script in swapped HTML and
  only same-origin requests.

`cosmic test` builds the project and runs the file; the next block does it
through [`cosmic.child`].

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
print(((said.stderr or "") .. (said.stdout or "")):match("test: %d+ tests? passed"))
```

```output
test: 6 tests passed
```

[`Attempts.limiter`]: ../../cosmic/web/attempts.tl
[`Attempts.too_many`]: ../../cosmic/web/attempts.tl
[`cosmic.child`]: ../../cosmic/child/init.tl
[`cosmic.web.csp`]: ../../cosmic/web/csp.tl
[`cosmic.web`]: ../../cosmic/web/init.tl
[`Csp.htmx_default()`]: ../../cosmic/web/csp.tl
[`Csrf.field`]: ../../cosmic/web/csrf.tl
[`Csrf.meta`]: ../../cosmic/web/csrf.tl
[`Csrf.middleware`]: ../../cosmic/web/csrf.tl
[`Headers.middleware`]: ../../cosmic/web/headers.tl
[`Htmx.head`]: ../../cosmic/web/htmx.tl
[`Web.html`]: ../../cosmic/web/init.tl
[`Web.safe_next`]: ../../cosmic/web/init.tl
