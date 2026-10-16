# a web JSON API

<!-- policy: profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } -->

[`cosmic.web`] answers JSON as readily as markup. This guide builds `notes`,
a small API under `/api`: JSON in and out, errors as problem documents, a
bearer token for changes and CORS for pages on another origin. It starts from
an empty directory and needs only what [web apps](web.md) says about routes
and the test client; [the forms guide](web-forms.md) explains the typed
routes it uses.

## routes under a prefix

An API is routes under a prefix, here `Web.mount("/api", ...)` returned by
`Api.mount`. Its routes are typed routes: `json_body` reads and checks the
body, and a refusal is an `application/problem+json` with each error's JSON
Pointer (a JSON body reports its first failure). A JSON body is read up to
64 KiB unless the route's `input_options` say more. A handler that wants an
error calls [`Web.abort`]; a client that asks for JSON (an `Accept` header)
gets a problem body and a browser gets a page. An empty Lua table encodes as
`{}`, so a list that may be empty goes through [`Json.array`] to encode as
`[]`.

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
    local limit = q.limit
    for _, note in ipairs(notes) do
      if limit == nil or #out < limit then out[#out + 1] = note end
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

## the token comes from the environment

The API is guarded by a bearer token, not a cookie. A secret is compared
with [`Hash.equal`], never `==`, and it is never in source: the program
reads it from the environment, and refuses to start without one.

```teal file=app.tl
--- The program: serves the notes API on the loopback.

local Api = require("api")
local Env = require("cosmic.env")
local Log = require("cosmic.log")
local Net = require("cosmic.net")
local String = require("cosmic.string")
local Web = require("cosmic.web")

local log = Log.new("notes")

return function(): integer
  local token = Env.get("NOTES_TOKEN")
  if token == nil or token == "" then
    log:complain("NOTES_TOKEN is not set; make a long random one and set it")
    return 2
  end
  local origins = String.split(Env.get_or("NOTES_ORIGINS", ""), ",")
  if #origins == 1 and origins[1] == "" then origins = {} end
  local app = Web.app{ routes = { Api.mount{ token = token, origins = origins } } }
  local ok, trouble = Web.serve(app, { listeners = { Net.tcp("127.0.0.1", 8080) } })
  if not ok then
    log:complain(trouble)
    return 1
  end
  return 0
end
```

An app that has pages as well puts the API beside them, and tells the CSRF
middleware to leave it alone (`exempt`): no cookie authenticates a request
to it, so a cross-site page has nothing to forge. An app that is only an
API, like this one, has no session and no CSRF middleware at all. The
[security guide](web-security.md) covers the CSRF layer for the pages.

## cors

[`cosmic.web.cors`] is for pages on another origin that call the API.
[`Cors.middleware`] answers a preflight and marks the responses a listed
origin may read; it is not authorization, it only tells a browser whose
scripts may read a response. It goes on the mount here, so a 404 or a 401
from the API carries the headers too and a browser shows the problem.
Origins match exactly on scheme, host and port; `"*"` cannot be combined
with credentials.

CORS says which scripts may read a reply. It does not let a cross-site page
post to a route behind the CSRF middleware. A page on another origin that
sends cookie-authenticated changes to such a route must also be named in
the CSRF middleware's `trusted_origins`; [`Cors.trusted`] makes that list
from the CORS one, and the token is still required.

## the tests

The tests build a site with a page, the cookie and CSRF middleware and the
API, as an app that has both would. The token in `TOKEN` is a literal because
this is a test: a real one is read from the environment, as above.

```teal file=api_test.tl
local Api = require("api")
local Csrf = require("cosmic.web.csrf")
local Secret = require("cosmic.web.secret")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local Web = require("cosmic.web")

local TOKEN <const> = "test-only-token"
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
test: 3 tests passed
```

[`Cors.middleware`]: ../../cosmic/web/cors.tl
[`Cors.trusted`]: ../../cosmic/web/cors.tl
[`cosmic.child`]: ../../cosmic/child.tl
[`cosmic.web.cors`]: ../../cosmic/web/cors.tl
[`cosmic.web`]: ../../cosmic/web/init.tl
[`Hash.equal`]: ../../cosmic/hash.tl
[`Json.array`]: ../../cosmic/json.tl
[`Web.abort`]: ../../cosmic/web/init.tl
