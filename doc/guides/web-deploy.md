# deploying a web app

<!-- policy: cpu_features = true, profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } -->

A [`cosmic.web`] app ships as one program: `cosmic build` makes an
executable with `static/` and htmx inside it, and the program is
configured by its environment. This guide builds `hello`, a tiny app with a
stylesheet, and the configuration a deployment needs: where it listens, the
keys, whether a proxy is in front, which hosts it answers to and whether the
site is https for good. It starts from an empty directory and needs only
what [web apps](web.md) says about routes and the app; the settings it
touches are explained in [the sessions](web-sessions.md) and
[security](web-security.md) guides.

## building

`cosmic build` writes the program of `cmd/hello/main.tl` (the name of its
directory) into the build directory, with every file under `static/` and the
htmx files inside it. `cosmic build --host` makes a native executable for
the machine it runs on, which needs no shell. Nothing is read from the
source tree at run time, so the executable can be copied alone to the
server.

```teal file=cmd/hello/main.tl
local app = require("app")

return function(): integer
  return app()
end
```

## static files and fingerprints

A file under `static/` is a public asset. [`StaticFiles.mount`] serves the
directory under a prefix and names itself `static`, and
`app:url_for("static", { path = "app.css" })` answers the fingerprinted
name: ten hex digits of the content hash are part of the name, as in
`/static/app.<10 hex>.css`, so a changed file has a new URL and an old one
may be cached for a year (`immutable`). A page links the fingerprinted name,
and a plain name still works with revalidation. A stale fingerprint is a
404, never a different file's bytes. A file is answered with a strong ETag
from its content hash, `If-None-Match`, `Range` and stored zstd and gzip variants,
and a request for a hidden file or a path that climbs out of the root is a
404.

```teal file=static/app.css
body { font-family: system-ui, sans-serif; max-width: 32rem; margin: 2rem auto; }
```

A test of the app gives it [`Assets.memory`] in place of the executable's
files, because a test of a project with a `cmd/` main is not a built program
and has none embedded. [`Assets.directory`] reads a directory and
[`Assets.embedded`] the executable's own.

## the settings

The program takes its settings from the environment, in a module of its own
so that a test can give it any environment it likes:

| variable | meaning |
| --- | --- |
| `HELLO_KEYS` | signing keys for the session cookie, newest first (required) |
| `HELLO_LISTEN` | `host:port` to listen on; default `127.0.0.1:8080` |
| `HELLO_BEHIND_PROXY` | `1` when a proxy that ends TLS is in front |
| `HELLO_HOSTS` | the host names the app answers to, comma-separated |
| `HELLO_HTTPS` | `1` when the site is https for good |

```teal file=config.tl
--- The settings of the hello program, read from its environment.

local Secret = require("cosmic.web.secret")
local String = require("cosmic.string")

local record Config
  --- What [`Config.read`] makes.
  record Settings
    --- Signing keys for the session cookie, newest first.
    keys: {string}
    --- The address to listen on.
    host: string
    port: integer
    --- Whether a proxy that ends TLS is in front.
    behind_proxy: boolean
    --- The hosts the app answers to; nil for any.
    hosts?: {string}
    --- Whether the site is https for good.
    https: boolean
  end
end

--- The settings `env` holds, or nil and why.
function Config.read(env: {string:string}): Config.Settings?, string
  local keys, why = Secret.parse_keys(env["HELLO_KEYS"] or "", "HELLO_KEYS")
  if keys == nil then return nil, why end
  local listen = env["HELLO_LISTEN"] or "127.0.0.1:8080"
  local host, text = listen:match("^(.+):(%d+)$")
  local port: integer? = nil
  if text ~= nil then port = math.tointeger(tonumber(text)) end
  if host == nil or port == nil or port > 65535 then
    return nil, "HELLO_LISTEN: want host:port, such as 127.0.0.1:8080"
  end
  local hosts: {string}? = nil
  local listed = env["HELLO_HOSTS"]
  if listed ~= nil then hosts = String.split(listed, ",") end
  return {
    keys = keys, host = host, port = port, hosts = hosts,
    behind_proxy = env["HELLO_BEHIND_PROXY"] == "1",
    https = env["HELLO_HTTPS"] == "1",
  }, ""
end

return Config
```

## the app

`hello.tl` turns the settings into the app. `HELLO_BEHIND_PROXY` becomes
`trusted_proxy`, and `HELLO_HOSTS` becomes `trusted_hosts`: [the security
guide](web-security.md) explains both, and why an app behind a proxy should
name its hosts, since the `Host` header is the client's.

`HELLO_HTTPS` is for the day the site is https for good. It turns on HSTS,
which a browser keeps for the whole `max_age`, so it stays off until then.
It also sets the session cookie to `secure = true`, which renames it
`__Host-session` (`__Secure-session` with a `domain`): a name the browser
accepts only from a secure origin, for path `/` and with no `domain`.
Without it, `Secure` follows the request's scheme, which a proxy's
`X-Forwarded-Proto` supplies once `trusted_proxy` is set.

```teal file=hello.tl
--- The hello app: a page that links its stylesheet, and the settings of a deployment.

local Assets = require("cosmic.web.assets")
local Headers = require("cosmic.web.headers")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local StaticFiles = require("cosmic.web.static")
local Web = require("cosmic.web")

local record Hello
  --- What [`Hello.app`] takes.
  record Options
    --- Signing keys for the session cookie, newest first.
    keys: {string}
    --- Where `/static` comes from; nil for the executable's own files.
    assets?: Assets.Source
    --- Whether a proxy that ends TLS is in front.
    behind_proxy?: boolean
    --- The hosts the app answers to; nil for any.
    hosts?: {string}
    --- Whether the site is https for good.
    https?: boolean
  end
end

--- The app.
function Hello.app(opts: Hello.Options): Web.App
  local headers: Headers.Options = {}
  if opts.https == true then headers = { hsts = { max_age = 31536000 } } end
  return Web.app{
    routes = {
      Web.get("/", function(req: Web.Request): Web.Response
        Session.of(req):set("seen", true)
        return Web.text((assert(req:url_for("static", { path = "app.css" }))))
      end),
      Web.get("/whoami", function(req: Web.Request): Web.Response
        local client = req.client
        return Web.text(req.scheme .. " " .. (if client ~= nil then client.host else "?" end))
      end),
      StaticFiles.mount("/static", { source = opts.assets }),
    },
    middleware = {
      Headers.middleware(headers),
      Session.middleware{ store = SessionCookie.store{ keys = opts.keys }, secure = if opts.https == true then true else nil end },
    },
    trusted_proxy = opts.behind_proxy,
    trusted_hosts = opts.hosts,
  }
end

return Hello
```

## serving

[`Web.serve`] runs the lifespan, listens and, on SIGINT or SIGTERM, stops
gracefully: open requests have `grace_ns` (10 seconds) to finish and the
app's hubs close their streams. It listens where `listeners` says, so the
address is a setting and not code: `HELLO_LISTEN=0.0.0.0:8080` serves on
every interface, and a proxy on the same machine reaches the default. It also
takes:

- **`limits`**: `body_bytes` is 1 MiB, for every request and before any
  route is known. A larger upload needs it raised here, for the whole app
  ([the forms guide](web-forms.md) explains the two other limits a route
  has).
- **The timeouts**: `head_ns`, `body_ns`, `idle_ns` and `timeout_ns`. A
  handler runs in its connection's task and must not block the thread.
- **`grace_ns`**, the time requests in flight have once the server stops.

The app itself keeps `debug` false, since `debug = true` shows a fault's
stack; `error_pages` and `error_view` make the pages that answer a status.
A development app ([`Dev.app`], see the first guide) refuses to listen beyond
the loopback.

```teal file=app.tl
--- The program: configured by its environment. `cosmic app.tl` runs it.

local Config = require("config")
local Env = require("cosmic.env")
local Hello = require("hello")
local Log = require("cosmic.log")
local Net = require("cosmic.net")
local Web = require("cosmic.web")

local log = Log.new("hello")

return function(): integer
  local settings, why = Config.read(Env.all())
  if settings == nil then
    log:complain(why)
    return 2
  end
  local app = Hello.app{
    keys = settings.keys, behind_proxy = settings.behind_proxy,
    hosts = settings.hosts, https = settings.https,
  }
  local ok, trouble = Web.serve(app, {
    listeners = { Net.tcp(settings.host, settings.port) },
    -- The default, written out: raise it for an app that takes uploads.
    limits = { body_bytes = 1024 * 1024 },
  })
  if not ok then
    log:complain(trouble)
    return 1
  end
  return 0
end
```

## the tests

The tests check the fingerprint, the settings, and what the proxy and https
options change.

```teal file=hello_test.tl
local Assets = require("cosmic.web.assets")
local Config = require("config")
local Hello = require("hello")
local Secret = require("cosmic.web.secret")
local Web = require("cosmic.web")

--- The options of an app with a fresh key, with the settings of a deployment as given.
local function options(behind_proxy?: boolean, hosts?: {string}, https?: boolean): Hello.Options
  return {
    keys = { Secret.generate() },
    assets = Assets.memory({ ["app.css"] = "body { margin: 0 }" }),
    behind_proxy = behind_proxy,
    hosts = hosts,
    https = https,
  }
end

local function test_a_page_links_the_fingerprinted_stylesheet()
  local client = Web.test_client(Hello.app(options()))
  local url = client:get("/"):text()
  assert(url:find("^/static/app%.%x%x%x%x%x%x%x%x%x%x%.css$"), url)
  local fetched = client:get(url)
  assert(fetched.status == 200 and (fetched.headers["cache-control"] or ""):find("immutable", 1, true) ~= nil)
  assert(client:get("/static/app.css").status == 200, "the plain name still works")
  assert(client:get("/static/app.0000000000.css").status == 404, "a stale fingerprint is a 404")
end

local function test_the_settings_are_read_from_the_environment()
  local key = Secret.generate()
  local settings = assert(Config.read({ HELLO_KEYS = key }))
  assert(settings.host == "127.0.0.1" and settings.port == 8080 and not settings.behind_proxy)
  local set = assert(Config.read({ HELLO_KEYS = key, HELLO_LISTEN = "0.0.0.0:9000",
    HELLO_BEHIND_PROXY = "1", HELLO_HOSTS = "a.example,b.example", HELLO_HTTPS = "1" }))
  assert(set.host == "0.0.0.0" and set.port == 9000 and set.behind_proxy and set.https)
  local hosts = set.hosts
  assert(hosts ~= nil and #hosts == 2 and hosts[2] == "b.example")
  assert(Config.read({}) == nil, "no key, no program")
  assert(Config.read({ HELLO_KEYS = key, HELLO_LISTEN = "nowhere" }) == nil)
end

local function test_a_proxy_is_believed_only_when_named()
  local seen = { ["X-Forwarded-Proto"] = "https", ["X-Forwarded-For"] = "203.0.113.9" }
  assert(Web.test_client(Hello.app(options(true))):get("/whoami", { headers = seen }):text() == "https 203.0.113.9")
  local alone = Web.test_client(Hello.app(options())):get("/whoami", { headers = seen }):text()
  assert(alone:find("^http "), "a header nobody vouched for is ignored")
end

local function test_only_the_named_hosts_are_answered()
  local client = Web.test_client(Hello.app(options(nil, { "hello.example.com" })))
  assert(client:get("/", { headers = { Host = "hello.example.com" } }).status == 200)
  assert(client:get("/", { headers = { Host = "evil.example" } }).status == 400)
end

local function test_https_for_good_turns_on_hsts_and_the_host_cookie()
  local plain = Web.test_client(Hello.app(options())):get("/")
  assert((plain.headers["set-cookie"] or ""):find("^session=") ~= nil)
  local client = Web.test_client(Hello.app(options(true, nil, true)))
  local reply = client:get("/", { headers = { ["X-Forwarded-Proto"] = "https" } })
  assert(reply.headers["strict-transport-security"] == "max-age=31536000")
  assert((reply.headers["set-cookie"] or ""):find("^__Host%-session=") ~= nil)
end
```

`cosmic test` builds the project and runs the file; the next block does it
through [`cosmic.child`], as the guide for the command line does.

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
test: 5 tests passed
```

[`Assets.directory`]: ../../cosmic/web/assets.tl
[`Assets.embedded`]: ../../cosmic/web/assets.tl
[`Assets.memory`]: ../../cosmic/web/assets.tl
[`cosmic.child`]: ../../cosmic/child.tl
[`cosmic.web`]: ../../cosmic/web/init.tl
[`Dev.app`]: ../../cosmic/web/dev.tl
[`StaticFiles.mount`]: ../../cosmic/web/static.tl
[`Web.serve`]: ../../cosmic/web/init.tl
