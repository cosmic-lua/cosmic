# web sessions

<!-- policy: profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } -->

A session is a small JSON object kept for a browser: a name it gave, a
message to show once, who it is logged in as. [`cosmic.web`] keeps it
behind one interface and two stores, and this guide builds `visits`, a
small app that greets a visitor and logs one in, then tests both stores. It
starts from an empty directory and needs only what [web apps](web.md) says
about routes and the test client.

## the handle

[`Session.middleware`] reads the cookie lazily: a request that never
touches the session sends no cookie, and one that only reads sends none
either. A handler gets the handle with [`Session.of`] and uses `get`,
`set`, `delete`, `flash` and `take_flashes`. A flash is shown once, on the
next page: at most 10 are kept, of at most 500 bytes each.

## the two stores

- [`SessionCookie.store`] keeps the whole session in a signed cookie
  and nothing on the server. **The cookie is signed, not encrypted**: the
  browser can read it, so never put a secret in it. A copy stays valid until
  it expires, even after logout. The cookie line is limited to 3800 bytes,
  and a session that does not fit makes the request a 500, so keep ids in it,
  not objects, and bound what a visitor can put in it.
- [`SessionSqlite.store`] keeps the data in a SQLite table under a random id
  that the cookie holds alone. A session can be revoked, and
  `destroy_subject` ends all of one user's. It runs its queries on the
  serving thread: a point lookup is microseconds, but give the sessions a
  database of their own if another process writes to the file.

## keys come from the environment

A signed cookie needs a key, and a key is never in source.
[`Secret.keys_from_env`] reads a comma-separated list, newest first
(`new,old` while a key is rotated out), and refuses a key that is short or
has too few distinct bytes. [`Secret.generate`] makes one:
`cosmic -e 'print(require("cosmic.web.secret").generate())'`. There is no
default key: a published default is how an app's sessions get forged.

## the app

`greet.tl` takes the session options, so the same routes run over either
store. `hello` keeps the visitor's name in the session and flashes a
greeting. A visitor chooses the name, so the route bounds it before it
reaches the session: with the signed-cookie store an unbounded name could
push the cookie past its limit and the request would be a 500. (A form that
is not UTF-8 text is a 400 before the route reads it, which suits a session
that holds JSON.)

`login` calls `session:regenerate()`, which gives the session a new id and
drops the secret [the CSRF layer](web-security.md) keeps in it, so a cookie
planted before the login is worth nothing after it. Call it at login and on
any change of privilege, and `session:invalidate()` at logout.

```teal file=greet.tl
--- The visits app: a greeting kept in the session, and a login.

local Input = require("cosmic.web.input")
local Session = require("cosmic.web.session")
local Url = require("cosmic.url")
local Web = require("cosmic.web")

local record Greet
end

--- The longest name taken, in bytes: the signed-cookie store holds a
--- session in 3800 bytes, and a name is typed by whoever visits.
local MAX_NAME <const> = 100

--- The app over the sessions `options` describes.
function Greet.app(options: Session.Options): Web.App
  return Web.app{
    routes = {
      Web.get("/", function(req: Web.Request): Web.Response
        local session = Session.of(req)
        local lines: {string} = {}
        for _, note in ipairs(session:take_flashes()) do lines[#lines + 1] = note.text end
        lines[#lines + 1] = "name: " .. (session:get_string("name") or "")
        return Web.text(table.concat(lines, "\n"))
      end, { name = "home" }),

      Web.post("/hello", function(req: Web.Request): Web.Response
        local read = Input.form(req)
        local invalid = read.invalid
        if invalid ~= nil then return Web.abort(invalid.status, invalid.message) end
        local name = Url.query_last(assert(read.value), "name") or ""
        if #name > MAX_NAME then return Web.abort(422, "the name is longer than 100 bytes") end
        local session = Session.of(req)
        session:set("name", name)
        session:flash("success", "hello, " .. name)
        return Web.redirect((assert(req:url_for("home"))))
      end, { name = "hello" }),

      Web.post("/login", function(req: Web.Request): Web.Response
        local session = Session.of(req)
        session:regenerate()
        session:set("user", "ada")
        session:bind_subject("ada")
        return Web.text("in")
      end),

      Web.post("/logout", function(req: Web.Request): Web.Response
        Session.of(req):invalidate()
        return Web.text("out")
      end),

      Web.get("/me", function(req: Web.Request): Web.Response
        return Web.text(Session.of(req):get_string("user") or "anonymous")
      end),
    },
    middleware = { Session.middleware(options) },
  }
end

return Greet
```

The program picks the store from the environment: `VISITS_DB` names a
SQLite file, and without it the sessions live in a signed cookie.

```teal file=app.tl
--- The program: serves the visits app on the loopback.

local Greet = require("greet")
local Env = require("cosmic.env")
local Log = require("cosmic.log")
local Net = require("cosmic.net")
local Secret = require("cosmic.web.secret")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local SessionSqlite = require("cosmic.web.session.sqlite")
local Sqlite = require("cosmic.sqlite")
local Web = require("cosmic.web")

local log = Log.new("visits")

--- The session store the environment asks for.
local function store(): Session.Store | nil, string
  local path = Env.get("VISITS_DB")
  if path ~= nil then
    local db, why = Sqlite.open(path)
    if db == nil then return nil, why end
    return SessionSqlite.store(db)
  end
  local keys, why = Secret.keys_from_env("VISITS_KEYS")
  if keys == nil then return nil, why end
  return SessionCookie.store{ keys = keys }
end

return function(): integer
  local sessions, why = store()
  if sessions == nil then
    log:complain(why)
    return 2
  end
  local ok, trouble = Web.serve(Greet.app{ store = sessions }, { listeners = { Net.tcp("127.0.0.1", 8080) } })
  if not ok then
    log:complain(trouble)
    return 1
  end
  return 0
end
```

## testing the stores

The tests build the app over each store. They show a weak key refused, a
greeting flashed once, a name that is too long refused, the
cookie a signed session sets, a stored session revoked for every device of
a user, and a login that changes the session's id. With `secure = true` the
cookie is named `__Host-session` (or `__Secure-session` with a `domain`),
the name a browser holds to `Secure`, path `/` and no domain; without it,
`Secure` follows the request's scheme, which a proxy that ends TLS supplies with `X-Forwarded-Proto` once
`trusted_proxy` is set ([the security guide](web-security.md)).

```teal file=greet_test.tl
local Greet = require("greet")
local Secret = require("cosmic.web.secret")
local SessionCookie = require("cosmic.web.session.cookie")
local SessionSqlite = require("cosmic.web.session.sqlite")
local Sqlite = require("cosmic.sqlite")
local Web = require("cosmic.web")

local function signed(): Web.TestClient
  return Web.test_client(Greet.app{ store = SessionCookie.store{ keys = { Secret.generate() } } })
end

local function test_a_weak_key_is_refused()
  local ok, why = Secret.check("changeme")
  assert(not ok and why:find("at least 32 bytes", 1, true))
  assert(#assert(Secret.parse_keys(Secret.generate() .. "," .. Secret.generate())) == 2)
end

local function test_a_greeting_is_flashed_once()
  local client = signed()
  local sent = client:post("/hello", { form = { name = "Ada" }, follow_redirects = true })
  assert(sent.body:find("hello, Ada", 1, true) and sent.body:find("name: Ada", 1, true))
  local again = client:get("/").body
  assert(not again:find("hello, Ada", 1, true) and again:find("name: Ada", 1, true), "a flash is shown once")
end

local function test_a_name_that_would_not_fit_is_refused_not_a_500()
  local client = signed()
  assert(client:post("/hello", { form = { name = ("x"):rep(101) } }).status == 422)
  assert(client:post("/hello", { form = { name = "\255\254" } }).status == 400, "text only")
  assert(client:post("/hello", { form = { name = ("x"):rep(100) } }).status == 303)
end

local function test_a_signed_cookie_is_not_readable_to_script()
  local cookie = signed():post("/login").headers["set-cookie"]
  assert(cookie:find("HttpOnly", 1, true) and cookie:find("SameSite=Lax", 1, true))
end

local function test_secure_renames_the_cookie()
  local store = SessionCookie.store{ keys = { Secret.generate() } }
  local cookie = Web.test_client(Greet.app{ store = store, secure = true }):post("/login").headers["set-cookie"]
  assert(cookie:find("^__Host%-session="), cookie)
  assert(cookie:find("Secure", 1, true) and cookie:find("Path=/", 1, true))
end

local function test_a_stored_session_can_be_revoked()
  local store = assert(SessionSqlite.store((assert(Sqlite.memory()))))
  local laptop = Web.test_client(Greet.app{ store = store })
  laptop:post("/login")
  assert(laptop:get("/me"):text() == "ada")
  assert(SessionSqlite.destroy_subject(store, "ada") == 1)
  assert(laptop:get("/me"):text() == "anonymous")
end

local function test_login_gives_the_session_a_new_id_and_logout_ends_it()
  local store = assert(SessionSqlite.store((assert(Sqlite.memory()))))
  local client = Web.test_client(Greet.app{ store = store })
  local before = client:post("/hello", { form = { name = "Ada" } }).headers["set-cookie"]
  local after = client:post("/login").headers["set-cookie"]
  assert(before ~= nil and after ~= nil and before:match("^[^;]+") ~= after:match("^[^;]+"))
  client:post("/logout")
  assert(client:get("/me"):text() == "anonymous")
end
```

`cosmic test` builds the project and runs the file. The next block does it
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
test: 7 tests passed
```

[`cosmic.child`]: ../../cosmic/child.tl
[`cosmic.web`]: ../../cosmic/web/init.tl
[`Secret.generate`]: ../../cosmic/web/secret.tl
[`Secret.keys_from_env`]: ../../cosmic/web/secret.tl
[`Session.middleware`]: ../../cosmic/web/session/init.tl
[`Session.of`]: ../../cosmic/web/session/init.tl
[`SessionCookie.store`]: ../../cosmic/web/session/cookie.tl
[`SessionSqlite.store`]: ../../cosmic/web/session/sqlite.tl
