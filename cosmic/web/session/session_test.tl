local Cookies = require("cosmic.web.cookies")
local Json = require("cosmic.json")
local Secret = require("cosmic.web.secret")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local SessionSqlite = require("cosmic.web.session.sqlite")
local Sqlite = require("cosmic.sqlite")
local Web = require("cosmic.web")

local KEY <const> = "k3Jf9Lq0Zx7Rw2Ub8Tn5Vc1Hd6Ym4Ga0Pe7Sx2Wq9Ac"

--- The session cookie's name, which is Secure.
local NAME <const> = "__Host-session"

--- A client acting as a browser on an https page, which sends a Secure
--- cookie back.
local function browser(app: Web.App): Web.TestClient
  local client = Web.test_client(app)
  client.scheme = "https"
  return client
end

--- The time the sessions see, which a test moves.
local now = 1000000

local function cookie_store(): Session.Store
  return SessionCookie.store{ keys = { KEY } }
end

local function sqlite_store(): Session.Store, Sqlite.Handle
  local db = assert(Sqlite.memory())
  return assert(SessionSqlite.store(db)), db
end

--- Sessions for tests: the options, with the clock.
local record Extra
  cookie_name?: string
  max_age?: integer
  rolling?: boolean
  secure?: boolean
  same_site?: Cookies.SameSite
  path?: string
  domain?: string
end

local function options(store: Session.Store, extra?: Extra): Session.Options
  local x: Extra = extra or {}
  return { store = store, cookie_name = x.cookie_name, max_age = x.max_age, rolling = x.rolling,
    secure = x.secure, same_site = x.same_site, path = x.path, domain = x.domain,
    now = function(): integer return now end }
end

local seen: mut {Session.Handle} = {}

--- An app with routes over the session.
local function make_app(opts: Session.Options, spec?: Web.AppSpec): Web.App
  local lines: mut {string} = {}
  local given: Web.AppSpec = spec or {}
  local sink: Web.Sink = given.sink or { line = function(_self: Web.Sink, text: string)
    lines[#lines + 1] = text
  end }
  local routes: {Web.Route} = {
    Web.get("/nothing", function(_req: Web.Request): Web.Response
      return Web.text("nothing")
    end),
    Web.get("/get/:key", function(req: Web.Request): Web.Response
      local handle = Session.of(req)
      seen[#seen + 1] = handle
      return Web.text(handle:get_string(assert(req.params["key"])) or "-")
    end),
    Web.post("/set/:key/:value", function(req: Web.Request): Web.Response
      Session.of(req):set(assert(req.params["key"]), req.params["value"])
      return Web.text("ok")
    end),
    Web.post("/flash/:kind/:text", function(req: Web.Request): Web.Response
      Session.of(req):flash(assert(req.params["kind"]), assert(req.params["text"]))
      return Web.text("ok")
    end),
    Web.get("/flashes", function(req: Web.Request): Web.Response
      local out: mut {string} = {}
      for _, each in ipairs(Session.of(req):take_flashes()) do
        out[#out + 1] = each.kind .. ":" .. each.text
      end
      return Web.text(table.concat(out, "|"))
    end),
    Web.get("/id", function(req: Web.Request): Web.Response
      return Web.text(Session.of(req):id())
    end),
    Web.get("/new", function(req: Web.Request): Web.Response
      return Web.text(tostring(Session.of(req):is_new()))
    end),
    Web.post("/login", function(req: Web.Request): Web.Response
      local handle = Session.of(req)
      handle:regenerate()
      handle:set("user", "ada")
      handle:bind_subject("ada")
      return Web.text("in")
    end),
    Web.post("/logout", function(req: Web.Request): Web.Response
      Session.of(req):invalidate()
      return Web.text("out")
    end),
    Web.post("/fail", function(req: Web.Request): Web.Response
      Session.of(req):set("lost", "yes")
      return Web.abort(403)
    end),
    Web.post("/bad", function(req: Web.Request): Web.Response
      Session.of(req):set("f", "\xff")
      return Web.text("unreachable")
    end),
    Web.post("/clear", function(req: Web.Request): Web.Response
      Session.of(req):clear()
      return Web.text("cleared")
    end),
    Web.post("/pop/:key", function(req: Web.Request): Web.Response
      return Web.text(tostring(Session.of(req):pop(assert(req.params["key"]))))
    end),
    Web.get("/cached", function(req: Web.Request): Web.Response
      Session.of(req):get("x")
      return Web.text("c", { headers = { ["Cache-Control"] = "max-age=60" } })
    end),
    Web.get("/bare", function(_req: Web.Request): Web.Response
      return Web.text(tostring(Session.of(_req):get_integer("n")))
    end),
  }
  return Web.app({ ...given, sink = sink, middleware = { Session.middleware(opts) }, routes = routes })
end

local function set_cookies(res: Web.TestResponse): {string}
  return res:header_list("set-cookie")
end

--- The number of rows in the session table.
local function session_count(db: Sqlite.Handle): integer
  local rows = assert(Sqlite.rows(db, "SELECT count(*) FROM web_sessions"))
  local row = assert(rows[1], "a count query answers one row")
  return row:integer(1)
end

--- The first `Set-Cookie` line of `res`, read back.
local function first_set_cookie(res: Web.TestResponse): Cookies.Parsed
  local line = assert(set_cookies(res)[1], "expected a Set-Cookie line")
  return (assert(Cookies.parse_set_cookie(line)))
end

local function test_a_request_that_never_touches_the_session_sends_no_cookie_and_no_vary()
  local client = browser(make_app(options(cookie_store())))
  local res = client:get("/nothing")
  assert(#set_cookies(res) == 0 and res.headers["vary"] == nil and res.headers["cache-control"] == nil)
end

local function test_a_read_only_request_sends_vary_and_private_but_no_cookie()
  local client = browser(make_app(options(cookie_store())))
  local res = client:get("/get/user")
  assert(res:text() == "-" and #set_cookies(res) == 0)
  assert(res.headers["vary"] == "Cookie" and res.headers["cache-control"] == "private")
  local cached = client:get("/cached")
  assert(cached.headers["cache-control"] == "max-age=60", "the app's Cache-Control is kept")
  assert(cached.headers["vary"] == "Cookie")
end

local function test_a_write_sends_one_cookie_that_the_next_request_reads_back()
  local client = browser(make_app(options(cookie_store())))
  local res = client:post("/set/user/ada")
  local lines = set_cookies(res)
  assert(#lines == 1 and res.headers["vary"] == "Cookie")
  local parsed = assert(Cookies.parse_set_cookie(lines[1]))
  assert(parsed.name == NAME and parsed.http_only and parsed.same_site == "Lax" and parsed.path == "/")
  assert(parsed.secure and parsed.max_age == 14 * 86400)
  local read = client:get("/get/user")
  assert(read:text() == "ada")
  assert(#set_cookies(read) == 0, "a request that only reads writes nothing")
  assert(client:get("/new"):text() == "false")
  assert(browser(make_app(options(cookie_store()))):get("/new"):text() == "true")
end

local function test_values_of_every_type_survive_the_cookie_store()
  local app = make_app(options(cookie_store()))
  local client = browser(app)
  client:post("/set/n/7")
  assert(client:get("/get/n"):text() == "7", "the value is the string that was set")
  local both = Web.app{
    middleware = { Session.middleware(options(cookie_store())) },
    routes = {
      Web.post("/put", function(req: Web.Request): Web.Response
        local s = Session.of(req)
        s:set("i", 42)
        s:set("b", true)
        s:set("t", { a = { 1, 2 }, b = "x" })
        return Web.text("ok")
      end),
      Web.get("/back", function(req: Web.Request): Web.Response
        local s = Session.of(req)
        local t = s:get("t")
        local fields, _ = Json.to_object(t)
        assert(fields, "expected the stored object")
        return Web.text(tostring(s:get_integer("i")) .. tostring(s:get_boolean("b")) .. tostring(s:get_string("i")) ..
            tostring(s:get_integer("b")) .. tostring(fields["b"]))
      end),
    },
  }
  local c2 = browser(both)
  c2:post("/put")
  assert(c2:get("/back"):text() == "42truenilnilx")
end

local function test_a_flash_is_shown_once_and_the_taking_is_a_write()
  local client = browser(make_app(options(cookie_store())))
  client:post("/flash/success/Saved")
  client:post("/flash/error/Oops")
  assert(client:get("/flashes"):text() == "success:Saved|error:Oops")
  assert(client:get("/flashes"):text() == "")
  local again = client:get("/flashes")
  assert(#set_cookies(again) == 0, "nothing was taken, so nothing is written")
end

local function test_flashes_are_capped_in_number_and_size()
  local client = browser(make_app(options(cookie_store())))
  for i = 1, 12 do client:post("/flash/info/m" .. tostring(i)) end
  local texts = client:get("/flashes"):text()
  assert(not texts:find("m1|", 1, true) and not texts:find("m2|", 1, true) and texts:find("m12", 1, true) ~= nil)
  local _, bars = texts:gsub("|", "")
  assert(bars == 9, "ten are kept")
  local long = browser(Web.app{
    middleware = { Session.middleware(options(cookie_store())) },
    routes = { Web.post("/f", function(req: Web.Request): Web.Response
      Session.of(req):flash("info", ("é"):rep(400))
      local flash = assert(Session.of(req):take_flashes()[1], "expected the flash just set")
      return Web.text(tostring(#flash.text))
    end) },
  })
  local n = math.tointeger(tonumber(long:post("/f"):text())) as integer -- checked: cast_refused
  assert(n <= 500 and n % 2 == 0, "cut on a character, not in the middle of one")
end

local function test_a_tampered_or_unknown_cookie_is_anonymous_and_expired_on_the_way_out()
  local client = browser(make_app(options(cookie_store())))
  local res = client:get("/get/user", { cookies = { [NAME] = "garbage.garbage" } })
  assert(res:text() == "-")
  local lines = set_cookies(res)
  assert(#lines == 1)
  local gone = assert(Cookies.parse_set_cookie(lines[1]))
  assert(gone.name == NAME and gone.value == "" and gone.max_age == 0)
  local untouched = client:get("/nothing", { cookies = { [NAME] = "garbage" } })
  assert(#set_cookies(untouched) == 0, "an unread session is never inspected")
  local written = client:post("/set/a/b", { cookies = { [NAME] = "garbage" } })
  assert(#set_cookies(written) == 1 and first_set_cookie(written).value ~= "")
end

local function test_an_expired_cookie_session_is_anonymous()
  local client = browser(make_app(options(cookie_store(), { max_age = 100 })))
  client:post("/set/user/ada")
  now = now + 99
  assert(client:get("/get/user"):text() == "ada")
  now = now + 1
  assert(client:get("/get/user"):text() == "-")
end

local function test_rolling_extends_the_lifetime_once_half_is_gone()
  local client = browser(make_app(options(cookie_store(), { max_age = 1000, rolling = true })))
  client:post("/set/user/ada")
  now = now + 400
  assert(#set_cookies(client:get("/get/user")) == 0, "more than half is left")
  now = now + 200
  local res = client:get("/get/user")
  assert(res:text() == "ada" and #set_cookies(res) == 1, "less than half is left")
  now = now + 900
  assert(client:get("/get/user"):text() == "ada", "the renewed session outlived the first lifetime")
  local fixed = browser(make_app(options(cookie_store(), { max_age = 1000 })))
  fixed:post("/set/user/ada")
  now = now + 600
  assert(#set_cookies(fixed:get("/get/user")) == 0)
  now = now + 500
  assert(fixed:get("/get/user"):text() == "-", "not rolling: the lifetime is from the start")
end

local function test_a_cookie_signed_under_a_retired_key_is_reissued_under_the_new_one()
  local old = browser(make_app(options(SessionCookie.store{ keys = { "Qp8Ws2Ed5Rf7Tg1Yh3Uj6Ik9Ol0Pm4NbXz3Lk8Mv5Rs" } })))
  old:post("/set/user/ada")
  local rotated = make_app(options(SessionCookie.store{ keys = { KEY, "Qp8Ws2Ed5Rf7Tg1Yh3Uj6Ik9Ol0Pm4NbXz3Lk8Mv5Rs" } }))
  local client = browser(rotated)
  client.jar[NAME] = assert(old.jar[NAME])
  local res = client:get("/get/user")
  assert(res:text() == "ada" and #set_cookies(res) == 1, "re-issued although only read")
  assert(client.jar[NAME] ~= old.jar[NAME])
  assert(#set_cookies(client:get("/get/user")) == 0)
end

local function test_a_handler_that_raises_saves_nothing_but_a_4xx_keeps_its_changes()
  local lines: mut {string} = {}
  local app = Web.app{
    sink = { line = function(_self: Web.Sink, text: string) lines[#lines + 1] = text end },
    middleware = { Session.middleware(options(cookie_store())) },
    routes = {
      Web.post("/boom", function(req: Web.Request): Web.Response
        Session.of(req):set("lost", "yes")
        error("boom")
      end),
      Web.post("/invalid", function(req: Web.Request): Web.Response
        Session.of(req):flash("error", "Fix the form")
        return Web.text("no", { status = 422 })
      end),
      Web.get("/get/:key", function(req: Web.Request): Web.Response
        return Web.text(Session.of(req):get_string(assert(req.params["key"])) or "-")
      end),
    },
  }
  local client = browser(app)
  local res = client:post("/boom")
  assert(res.status == 500 and #set_cookies(res) == 0 and client.jar[NAME] == nil)
  assert(client:get("/get/lost"):text() == "-")
  local kept = client:post("/invalid")
  assert(kept.status == 422 and #set_cookies(kept) == 1)
end

local function test_a_value_that_is_not_json_raises_at_the_set()
  local client = browser(make_app(options(cookie_store())))
  assert(client:post("/bad").status == 500)
  local reasons = {} as {string} -- checked: cast_refused, literal_needs_type
  local app = Web.app{
    middleware = { Session.middleware(options(cookie_store())) },
    routes = { Web.get("/", function(req: Web.Request): Web.Response
      local s = Session.of(req)
      local _, f = pcall(function() s:set("f", "\xff") end)
      local _, e = pcall(function() s:set("", 1) end)
      local _, r = pcall(function() s:set("_flash", 1) end)
      reasons = { tostring(f), tostring(e), tostring(r) }
      return Web.text("done")
    end) },
  }
  assert(browser(app):get("/").status == 200)
  assert(reasons[1]:find("cannot keep f", 1, true), reasons[1])
  assert(reasons[2]:find("non-empty string", 1, true), reasons[2])
  assert(reasons[3]:find("reserved", 1, true), reasons[3])
end

local function test_the_handle_is_frozen_once_the_response_is_built()
  local client = browser(make_app(options(cookie_store())))
  client:get("/get/user")
  local handle = assert(seen[#seen], "expected seen[#seen]")
  local ok, why = pcall(function() handle:set("late", "write") end)
  assert(not ok and tostring(why):find("written after the response head was built", 1, true) ~= nil, tostring(why))
  ok = pcall(function() handle:flash("info", "late") end) -- checked: alternatives_as_value
  assert(not ok)
  assert(handle:get_string("late") == nil)
end

local function test_pop_and_clear_remove_values_and_clearing_nothing_writes_nothing()
  local client = browser(make_app(options(cookie_store())))
  client:post("/set/a/1")
  client:post("/set/b/2")
  assert(client:post("/pop/a"):text() == "1")
  assert(client:get("/get/a"):text() == "-" and client:get("/get/b"):text() == "2")
  client:post("/clear")
  assert(client:get("/get/b"):text() == "-")
  assert(#set_cookies(browser(make_app(options(cookie_store()))):post("/clear")) == 0,
    "clearing an anonymous empty session writes nothing")
end

local function test_session_of_without_the_middleware_raises()
  local app = Web.app{ routes = { Web.get("/", function(req: Web.Request): Web.Response
    return Web.text(Session.of(req):get_string("x") or "-")
  end) }, sink = { line = function(_self: Web.Sink, _text: string) end } }
  assert(browser(app):get("/").status == 500)
end

local function test_a_failing_store_is_a_500_and_a_cookie_over_the_limit_is_raised_for_the_developer()
  local failing: Session.Store = {
    revocable = false,
    load = function(_: Session.Store, _t: string, _n: integer, _c: string): Session.Data?, string
      return nil, "disk on fire"
    end,
    save = function(_: Session.Store, _p: string, _d: Session.Data, _ch: Session.Changes, _n: integer,
                    _c: string): string?, string
      return nil, "no space"
    end,
    destroy = function(_: Session.Store, _t: string): boolean, string return true, "" end,
  }
  local lines: mut {string} = {}
  local spec: Web.AppSpec = { sink = { line = function(_self: Web.Sink, text: string)
    lines[#lines + 1] = text
  end } }
  local app = make_app(options(failing), spec)
  local client = browser(app)
  local ok, why = pcall(function() client:post("/set/a/b") end)
  assert(not ok and tostring(why):find("session: no space", 1, true) ~= nil, tostring(why))
  -- A load runs in the handler, where the exception layer answers 500 and logs the fault.
  assert(client:get("/get/a", { cookies = { [NAME] = "anything" } }).status == 500)
  assert(table.concat(lines, "\n"):find("session: disk on fire", 1, true))
  local big = browser(make_app(options(SessionCookie.store{ keys = { KEY }, max_bytes = 200 }), spec))
  ok, why = pcall(function() big:post("/set/a/" .. ("x"):rep(300)) end)
  assert(not ok and tostring(why):find("cookie would be", 1, true) ~= nil, tostring(why))
end

local function test_a_request_over_http_still_gets_a_secure_host_prefixed_cookie()
  -- Behind a proxy that ends TLS with no trusted_proxy, the app sees http.
  local client = browser(make_app(options(cookie_store())))
  local parsed = first_set_cookie(client:post("/set/user/ada", { headers = { ["X-Forwarded-Proto"] = "https" } }))
  assert(parsed.name == NAME and parsed.secure and parsed.path == "/" and parsed.domain == nil)
  assert(client:get("/get/user"):text() == "ada")
  client.scheme = "http"
  assert(client:get("/get/user"):text() == "-", "a Secure cookie is not sent over http")
end

local function test_a_planted_cookie_without_the_prefix_is_never_read()
  local store, _db = sqlite_store()
  local app = make_app(options(store))
  -- The attacker's own valid session, planted under the name a sibling
  -- subdomain or a page over http can set.
  local attacker = browser(app)
  attacker:post("/login")
  local planted = assert(attacker.jar[NAME])
  local victim = browser(app)
  assert(victim:get("/get/user", { cookies = { session = planted } }):text() == "-")
  assert(victim:get("/get/user", { cookies = { [NAME] = planted } }):text() == "ada")
  victim:post("/set/user/grace")
  local own = assert(victim.jar[NAME])
  local both = victim:get("/get/user", { cookies = { session = planted, [NAME] = own } })
  assert(both:text() == "grace", "the prefixed cookie is the session read beside a planted one")
end

local function test_logout_expires_the_prefixed_cookie()
  local client = browser(make_app(options((sqlite_store()))))
  client:post("/login")
  local gone = first_set_cookie(client:post("/logout"))
  assert(gone.name == NAME and gone.value == "" and gone.max_age == 0)
  assert(gone.secure and gone.path == "/" and gone.domain == nil, "expired with the attributes it was set with")
  assert(client.jar[NAME] == nil)
end

local function test_development_mode_follows_the_scheme_and_secure_false_never_sets_secure()
  local dev = Web.test_client(make_app(options(cookie_store()), { dev = true }))
  local parsed = first_set_cookie(dev:post("/set/user/ada"))
  assert(parsed.name == "session" and not parsed.secure)
  assert(dev:get("/get/user"):text() == "ada", "plain http works on the loopback")
  local plain = Web.test_client(make_app(options(cookie_store(), { secure = false })))
  parsed = first_set_cookie(plain:post("/set/user/ada"))
  assert(parsed.name == "session" and not parsed.secure)
  assert(plain:get("/get/user"):text() == "ada")
end

local function test_a_cookie_name_takes_the_prefix_and_a_domain_takes_secure_prefix()
  local named = browser(make_app(options(cookie_store(), { cookie_name = "sid" })))
  assert(first_set_cookie(named:post("/set/a/1")).name == "__Host-sid")
  local wide = first_set_cookie(browser(make_app(options(cookie_store(), { domain = "example.com" }))):post("/set/a/1"))
  assert(wide.name == "__Secure-session" and wide.secure and wide.domain == "example.com")
end

local function test_options_that_cannot_work_are_refused_before_serving()
  local ok, why = pcall(Session.middleware, options(cookie_store(), { max_age = 0 }))
  assert(not ok and tostring(why):find("max_age", 1, true) ~= nil)
  for _, name in ipairs({ "__Host-x", "__secure-x" }) do
    ok, why = pcall(Session.middleware, options(cookie_store(), { cookie_name = name }))
    assert(not ok and tostring(why):find("prefix", 1, true) ~= nil, tostring(why))
  end
  ok = pcall(Session.middleware, options(cookie_store(), { cookie_name = "bad name" })) -- checked: alternatives_as_value
  assert(not ok)
  ok, why = pcall(Session.middleware, options(cookie_store(), { path = "/app" }))
  assert(not ok and tostring(why):find("Path=/", 1, true) ~= nil, tostring(why))
  ok, why = pcall(Session.middleware, options(cookie_store(), { path = "/app", secure = false }))
  assert(ok, "a cookie that is never Secure may take a path: " .. tostring(why))
end

local function test_sqlite_sessions_are_revocable_by_logout_and_by_subject()
  local store, db = sqlite_store()
  local app = make_app(options(store))
  local client = browser(app)
  client:post("/login")
  local stolen = assert(client.jar[NAME])
  assert(#stolen == 43 and client:get("/get/user"):text() == "ada")
  assert(client:get("/id"):text() == stolen)
  local out = client:post("/logout")
  local gone = first_set_cookie(out)
  assert(gone.max_age == 0 and gone.value == "" and client.jar[NAME] == nil)
  local thief = browser(app)
  assert(thief:get("/get/user", { cookies = { [NAME] = stolen } }):text() == "-", "the id is revoked")
  assert(session_count(db) == 0)
  local first, second = browser(app), browser(app)
  first:post("/login")
  second:post("/login")
  assert(SessionSqlite.destroy_subject(store, "ada") == 2)
  assert(first:get("/get/user"):text() == "-" and second:get("/get/user"):text() == "-")
end

local function test_regenerate_changes_the_id_and_keeps_the_data()
  local store = sqlite_store()
  local app = make_app(options(store))
  local client = browser(app)
  client:post("/set/theme/dark")
  local before = assert(client.jar[NAME])
  local res = client:post("/login")
  assert(before ~= client.jar[NAME] and #set_cookies(res) == 1)
  assert(client:get("/get/theme"):text() == "dark" and client:get("/get/user"):text() == "ada")
  assert(browser(app):get("/get/theme", { cookies = { [NAME] = before } }):text() == "-")
  local cookie_app = browser(make_app(options(cookie_store())))
  cookie_app:post("/set/theme/dark")
  local first = assert(cookie_app.jar[NAME])
  now = now + 5
  cookie_app:post("/login")
  assert(cookie_app.jar[NAME] ~= first)
  assert(cookie_app:get("/get/theme"):text() == "dark")
end

local function test_a_signed_cookie_logout_clears_the_browser_but_cannot_revoke_the_copy()
  local app = make_app(options(cookie_store()))
  local client = browser(app)
  client:post("/login")
  local copy = assert(client.jar[NAME])
  client:post("/logout")
  assert(client.jar[NAME] == nil and client:get("/get/user"):text() == "-")
  assert(browser(app):get("/get/user", { cookies = { [NAME] = copy } }):text() == "ada")
  assert(client:get("/id"):text() == "", "a signed cookie has no id to log")
end

local function test_invalidate_then_write_starts_a_new_session()
  local app = Web.app{
    middleware = { Session.middleware(options((sqlite_store()))) },
    routes = { Web.post("/swap", function(req: Web.Request): Web.Response
      local s = Session.of(req)
      s:invalidate()
      s:set("fresh", "yes")
      return Web.text("ok")
    end), Web.get("/get/:key", function(req: Web.Request): Web.Response
      return Web.text(Session.of(req):get_string(assert(req.params["key"])) or "-")
    end), Web.post("/set/:key/:value", function(req: Web.Request): Web.Response
      Session.of(req):set(assert(req.params["key"]), req.params["value"])
      return Web.text("ok")
    end) },
  }
  local client = browser(app)
  client:post("/set/old/1")
  local before = assert(client.jar[NAME])
  client:post("/swap")
  assert(client.jar[NAME] ~= before)
  assert(client:get("/get/old"):text() == "-" and client:get("/get/fresh"):text() == "yes")
end

local function test_sqlite_expiry_and_rolling_follow_the_clock()
  local store = sqlite_store()
  local client = browser(make_app(options(store, { max_age = 1000, rolling = true })))
  client:post("/set/user/ada")
  now = now + 600
  assert(client:get("/get/user"):text() == "ada")
  now = now + 900
  assert(client:get("/get/user"):text() == "ada", "the read at 600 renewed it")
  now = now + 1000
  assert(client:get("/get/user"):text() == "-")
end

local function test_the_session_survives_in_a_secret_key_from_the_environment_shape()
  local keys = assert(Secret.parse_keys(KEY))
  local client = browser(make_app(options(SessionCookie.store{ keys = keys })))
  client:post("/set/user/ada")
  assert(client:get("/get/user"):text() == "ada")
end

--- A value nested `levels` arrays deep.
local function nest(levels: integer): Json.Value
  local value: Json.Value = 1
  for _ = 1, levels do value = { value } end
  return value
end

local function test_a_response_shared_between_requests_is_not_given_a_cookie()
  for _, make in ipairs({ cookie_store, function(): Session.Store return (sqlite_store()) end }) do
    local shared = Web.text("not found", { status = 404 })
    Web.add_header(shared, "Set-Cookie", "a=1")
    Web.add_header(shared, "Set-Cookie", "b=2")
    local app = Web.app{
      middleware = { Session.middleware(options(make())) },
      routes = { Web.post("/shared/:v", function(req: Web.Request): Web.Response
        Session.of(req):set("v", req.params["v"])
        return shared
      end) },
    }
    local first = browser(app):post("/shared/one")
    local second = browser(app):post("/shared/two")
    for _, res in ipairs({ first, second }) do
      local own = 0
      for _, line in ipairs(set_cookies(res)) do
        if line:find("^__Host%-session=") then own = own + 1 end
      end
      assert(own == 1 and #set_cookies(res) == 3, "its own one session cookie beside the shared two")
    end
    assert(set_cookies(first)[3] ~= set_cookies(second)[3])
    local lines = assert(shared.headers)["Set-Cookie"]
    assert(lines is {string} and #lines == 2, "the shared response is unchanged") -- checked: is_on_record
    assert(Web.header(shared, "Vary") == nil and Web.header(shared, "Cache-Control") == nil)
  end
end

local function test_a_value_at_the_depth_limit_survives_and_one_past_it_raises_at_the_set()
  for _, make in ipairs({ cookie_store, function(): Session.Store return (sqlite_store()) end }) do
    local reasons: mut {string} = {}
    local app = Web.app{
      middleware = { Session.middleware(options(make())) },
      routes = {
        Web.post("/deep", function(req: Web.Request): Web.Response
          local s = Session.of(req)
          s:set("ok", nest(Session.MAX_DEPTH - 1))
          local ran, why = pcall(function() s:set("too", nest(Session.MAX_DEPTH)) end)
          table.insert(reasons, if ran then "no error" else tostring(why) end)
          return Web.text("ok")
        end),
        Web.get("/has/:key", function(req: Web.Request): Web.Response
          return Web.text(tostring(Session.of(req):get(assert(req.params["key"])) ~= nil))
        end),
        Web.get("/new", function(req: Web.Request): Web.Response
          return Web.text(tostring(Session.of(req):is_new()))
        end),
      },
    }
    local client = browser(app)
    assert(client:post("/deep").status == 200)
    local reasons_1 = assert(reasons[1], "expected reasons[1]")
    assert(reasons_1:find("cannot keep too", 1, true), reasons[1])
    assert(client:get("/new"):text() == "false", "the next request still has the session")
    assert(client:get("/has/ok"):text() == "true" and client:get("/has/too"):text() == "false")
  end
end

local function test_a_flash_that_is_not_utf8_raises_at_the_call()
  local reasons: mut {string} = {}
  local app = Web.app{
    middleware = { Session.middleware(options(cookie_store())) },
    routes = { Web.post("/f", function(req: Web.Request): Web.Response
      local ran, why = pcall(function() Session.of(req):flash("info", "bad \xff text") end)
      table.insert(reasons, if ran then "no error" else tostring(why) end)
      return Web.text("ok")
    end) },
  }
  local res = browser(app):post("/f")
  assert(res.status == 200 and #set_cookies(res) == 0, "nothing was kept")
  local reasons_1 = assert(reasons[1], "expected reasons[1]")
  assert(reasons_1:find("session: cannot flash", 1, true), reasons[1])
end

local function test_setting_nil_removes_the_key_in_both_stores()
  for _, make in ipairs({ cookie_store, function(): Session.Store return (sqlite_store()) end }) do
    local app = Web.app{
      middleware = { Session.middleware(options(make())) },
      routes = {
        Web.post("/set/:key/:value", function(req: Web.Request): Web.Response
          Session.of(req):set(assert(req.params["key"]), req.params["value"])
          return Web.text("ok")
        end),
        Web.post("/unset/:key", function(req: Web.Request): Web.Response
          Session.of(req):set(assert(req.params["key"]), nil)
          return Web.text("ok")
        end),
        Web.get("/get/:key", function(req: Web.Request): Web.Response
          return Web.text(Session.of(req):get_string(assert(req.params["key"])) or "-")
        end),
      },
    }
    local client = browser(app)
    client:post("/set/a/1")
    client:post("/set/b/2")
    client:post("/unset/a")
    assert(client:get("/get/a"):text() == "-" and client:get("/get/b"):text() == "2")
  end
end

local function test_same_site_none_is_secure_and_refused_over_http_in_development_mode()
  local parsed = first_set_cookie(Web.test_client(make_app(options(cookie_store(), { same_site = "None" }))):post("/set/a/1"))
  assert(parsed.secure and parsed.same_site == "None", "Secure whatever the scheme")
  local dev = Web.test_client(make_app(options(cookie_store(), { same_site = "None" }), { dev = true }))
  assert(#set_cookies(dev:get("/get/a")) == 0, "reading over http is fine")
  local ok, why = pcall(function() dev:post("/set/a/1") end)
  assert(not ok and tostring(why):find("needs a Secure cookie", 1, true) ~= nil, tostring(why))
  ok = pcall(Session.middleware, options(cookie_store(), { same_site = "None", secure = false })) -- checked: alternatives_as_value
  assert(not ok, "an explicit secure = false can never work")
end

local function test_invalidate_revokes_even_when_the_response_is_a_500()
  local store, db = sqlite_store()
  local app = Web.app{
    middleware = { Session.middleware(options(store)) },
    routes = {
      Web.post("/set/:key/:value", function(req: Web.Request): Web.Response
        Session.of(req):set(assert(req.params["key"]), req.params["value"])
        return Web.text("ok")
      end),
      Web.post("/logout-fails", function(req: Web.Request): Web.Response
        local s = Session.of(req)
        s:invalidate()
        s:set("after", "x")
        return Web.text("broken", { status = 500 })
      end),
    },
  }
  local client = browser(app)
  client:post("/set/user/ada")
  local before = assert(client.jar[NAME])
  local res = client:post("/logout-fails")
  assert(res.status == 500)
  assert(session_count(db) == 0, "the row is gone")
  assert(store:load(before, now, NAME) == nil)
  assert(#set_cookies(res) == 1 and client.jar[NAME] == nil, "and the cookie is expired")
end

local function test_regenerate_drops_the_csrf_secret_and_keeps_the_rest()
  local store = sqlite_store()
  local app = Web.app{
    middleware = { Session.middleware(options(store)) },
    routes = {
      Web.post("/seed", function(req: Web.Request): Web.Response
        local s = Session.of(req)
        s:set(Session.CSRF_KEY, "secret")
        s:set("user", "ada")
        return Web.text("ok")
      end),
      Web.post("/regenerate", function(req: Web.Request): Web.Response
        Session.of(req):regenerate()
        return Web.text("ok")
      end),
      Web.get("/peek", function(req: Web.Request): Web.Response
        local s = Session.of(req)
        return Web.text((s:get_string(Session.CSRF_KEY) or "-") .. "/" .. (s:get_string("user") or "-"))
      end),
    },
  }
  local client = browser(app)
  client:post("/seed")
  assert(client:get("/peek").body == "secret/ada")
  client:post("/regenerate")
  assert(client:get("/peek").body == "-/ada")
end

local function test_a_label_is_bounded_text_and_a_no_op_on_a_signed_cookie()
  local reasons: mut {string} = {}
  local app = Web.app{
    middleware = { Session.middleware(options(cookie_store())) },
    routes = { Web.post("/l", function(req: Web.Request): Web.Response
      local session = Session.of(req)
      for _, text in ipairs({ "bad \xff", ("x"):rep(Session.MAX_LABEL + 1) }) do
        local ran, why = pcall(function() session:label(text) end)
        table.insert(reasons, if ran then "no error" else tostring(why) end)
      end
      session:label(("x"):rep(Session.MAX_LABEL))
      return Web.text("ok")
    end) },
  }
  local res = browser(app):post("/l")
  assert(res.status == 200 and #set_cookies(res) == 0, "a label alone changes nothing a cookie keeps")
  assert(#reasons == 2)
  for _, why in ipairs(reasons) do
    assert(why:find("session: a label is UTF-8 text", 1, true), why)
  end
end
