local Cookies = require("cosmic.web.cookies")
local Secret = require("cosmic.web.secret")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local SessionSqlite = require("cosmic.web.session.sqlite")
local Sqlite = require("cosmic.sqlite")
local Web = require("cosmic.web")

local KEY <const> = "k3Jf9Lq0Zx7Rw2Ub8Tn5Vc1Hd6Ym4Ga0"

--- The time the sessions see, which a test moves.
local clock = { now = 1000000 }

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
end

local function options(store: Session.Store, extra?: Extra): Session.Options
  local o: Session.Options = { store = store }
  if extra ~= nil then
    o.cookie_name, o.max_age, o.rolling = extra.cookie_name, extra.max_age, extra.rolling
    o.secure, o.same_site = extra.secure, extra.same_site
  end
  o.now = function(): integer return clock.now end
  return o
end

local seen: {Session.Handle} = {}

--- An app with routes over the session.
local function make_app(opts: Session.Options, spec?: Web.AppSpec): Web.App
  local lines: {string} = {}
  local made: Web.AppSpec = spec or {}
  if made.sink == nil then
    made.sink = { line = function(_self: Web.Sink, text: string)
      lines[#lines + 1] = text
    end }
  end
  made.middleware = { Session.middleware(opts) }
  made.routes = {
    Web.get("/nothing", function(_req: Web.Request): Web.Response
      return Web.text("nothing")
    end),
    Web.get("/get/:key", function(req: Web.Request): Web.Response
      local handle = Session.of(req)
      seen[#seen + 1] = handle
      return Web.text(handle:get_string(req.params.key) or "-")
    end),
    Web.post("/set/:key/:value", function(req: Web.Request): Web.Response
      Session.of(req):set(req.params.key, req.params.value)
      return Web.text("ok")
    end),
    Web.post("/flash/:kind/:text", function(req: Web.Request): Web.Response
      Session.of(req):flash(req.params.kind, req.params.text)
      return Web.text("ok")
    end),
    Web.get("/flashes", function(req: Web.Request): Web.Response
      local out: {string} = {}
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
      Session.of(req):set("f", print as any)
      return Web.text("unreachable")
    end),
    Web.post("/clear", function(req: Web.Request): Web.Response
      Session.of(req):clear()
      return Web.text("cleared")
    end),
    Web.post("/pop/:key", function(req: Web.Request): Web.Response
      return Web.text(tostring(Session.of(req):pop(req.params.key)))
    end),
    Web.get("/cached", function(req: Web.Request): Web.Response
      Session.of(req):get("x")
      return Web.text("c", { headers = { ["Cache-Control"] = "max-age=60" } })
    end),
    Web.get("/bare", function(_req: Web.Request): Web.Response
      return Web.text(tostring(Session.of(_req):get_integer("n")))
    end),
  }
  return Web.app(made)
end

local function set_cookies(res: Web.TestResponse): {string}
  return res:header_list("set-cookie")
end

local function test_a_request_that_never_touches_the_session_sends_no_cookie_and_no_vary()
  local client = Web.test_client(make_app(options(cookie_store())))
  local res = client:get("/nothing")
  assert(#set_cookies(res) == 0 and res.headers["vary"] == nil and res.headers["cache-control"] == nil)
end

local function test_a_read_only_request_sends_vary_and_private_but_no_cookie()
  local client = Web.test_client(make_app(options(cookie_store())))
  local res = client:get("/get/user")
  assert(res:text() == "-" and #set_cookies(res) == 0)
  assert(res.headers["vary"] == "Cookie" and res.headers["cache-control"] == "private")
  local cached = client:get("/cached")
  assert(cached.headers["cache-control"] == "max-age=60", "the app's Cache-Control is kept")
  assert(cached.headers["vary"] == "Cookie")
end

local function test_a_write_sends_one_cookie_that_the_next_request_reads_back()
  local client = Web.test_client(make_app(options(cookie_store())))
  local res = client:post("/set/user/ada")
  local lines = set_cookies(res)
  assert(#lines == 1 and res.headers["vary"] == "Cookie")
  local parsed = assert(Cookies.parse_set_cookie(lines[1]))
  assert(parsed.name == "session" and parsed.http_only and parsed.same_site == "Lax" and parsed.path == "/")
  assert(not parsed.secure and parsed.max_age == 14 * 86400)
  local read = client:get("/get/user")
  assert(read:text() == "ada")
  assert(#set_cookies(read) == 0, "a request that only reads writes nothing")
  assert(client:get("/new"):text() == "false")
  assert(Web.test_client(make_app(options(cookie_store()))):get("/new"):text() == "true")
end

local function test_values_of_every_type_survive_the_cookie_store()
  local app = make_app(options(cookie_store()))
  local client = Web.test_client(app)
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
        assert(t is {string:any})
        return Web.text(tostring(s:get_integer("i")) .. tostring(s:get_boolean("b")) .. tostring(s:get_string("i")) ..
            tostring(s:get_integer("b")) .. tostring(t.b))
      end),
    },
  }
  local c2 = Web.test_client(both)
  c2:post("/put")
  assert(c2:get("/back"):text() == "42truenilnilx")
end

local function test_a_flash_is_shown_once_and_the_taking_is_a_write()
  local client = Web.test_client(make_app(options(cookie_store())))
  client:post("/flash/success/Saved")
  client:post("/flash/error/Oops")
  assert(client:get("/flashes"):text() == "success:Saved|error:Oops")
  assert(client:get("/flashes"):text() == "")
  local again = client:get("/flashes")
  assert(#set_cookies(again) == 0, "nothing was taken, so nothing is written")
end

local function test_flashes_are_capped_in_number_and_size()
  local client = Web.test_client(make_app(options(cookie_store())))
  for i = 1, 12 do client:post("/flash/info/m" .. i) end
  local texts = client:get("/flashes"):text()
  assert(not texts:find("m1|", 1, true) and not texts:find("m2|", 1, true) and texts:find("m12", 1, true))
  local _, bars = texts:gsub("|", "")
  assert(bars == 9, "ten are kept")
  local long = Web.test_client(Web.app{
    middleware = { Session.middleware(options(cookie_store())) },
    routes = { Web.post("/f", function(req: Web.Request): Web.Response
      Session.of(req):flash("info", ("é"):rep(400))
      return Web.text(tostring(#Session.of(req):take_flashes()[1].text))
    end) },
  })
  local n = math.tointeger(tonumber(long:post("/f"):text())) as integer
  assert(n <= 500 and n % 2 == 0, "cut on a character, not in the middle of one")
end

local function test_a_tampered_or_unknown_cookie_is_anonymous_and_expired_on_the_way_out()
  local client = Web.test_client(make_app(options(cookie_store())))
  local res = client:get("/get/user", { cookies = { session = "garbage.garbage" } })
  assert(res:text() == "-")
  local lines = set_cookies(res)
  assert(#lines == 1)
  local gone = assert(Cookies.parse_set_cookie(lines[1]))
  assert(gone.name == "session" and gone.value == "" and gone.max_age == 0)
  local untouched = client:get("/nothing", { cookies = { session = "garbage" } })
  assert(#set_cookies(untouched) == 0, "an unread session is never inspected")
  local written = client:post("/set/a/b", { cookies = { session = "garbage" } })
  assert(#set_cookies(written) == 1 and assert(Cookies.parse_set_cookie(set_cookies(written)[1])).value ~= "")
end

local function test_an_expired_cookie_session_is_anonymous()
  local client = Web.test_client(make_app(options(cookie_store(), { max_age = 100 })))
  client:post("/set/user/ada")
  clock.now = clock.now + 99
  assert(client:get("/get/user"):text() == "ada")
  clock.now = clock.now + 1
  assert(client:get("/get/user"):text() == "-")
end

local function test_rolling_extends_the_lifetime_once_half_is_gone()
  local client = Web.test_client(make_app(options(cookie_store(), { max_age = 1000, rolling = true })))
  client:post("/set/user/ada")
  clock.now = clock.now + 400
  assert(#set_cookies(client:get("/get/user")) == 0, "more than half is left")
  clock.now = clock.now + 200
  local res = client:get("/get/user")
  assert(res:text() == "ada" and #set_cookies(res) == 1, "less than half is left")
  clock.now = clock.now + 900
  assert(client:get("/get/user"):text() == "ada", "the renewed session outlived the first lifetime")
  local fixed = Web.test_client(make_app(options(cookie_store(), { max_age = 1000 })))
  fixed:post("/set/user/ada")
  clock.now = clock.now + 600
  assert(#set_cookies(fixed:get("/get/user")) == 0)
  clock.now = clock.now + 500
  assert(fixed:get("/get/user"):text() == "-", "not rolling: the lifetime is from the start")
end

local function test_a_cookie_signed_under_a_retired_key_is_reissued_under_the_new_one()
  local old = Web.test_client(make_app(options(SessionCookie.store{ keys = { "Qp8Ws2Ed5Rf7Tg1Yh3Uj6Ik9Ol0Pm4Nb" } })))
  old:post("/set/user/ada")
  local rotated = make_app(options(SessionCookie.store{ keys = { KEY, "Qp8Ws2Ed5Rf7Tg1Yh3Uj6Ik9Ol0Pm4Nb" } }))
  local client = Web.test_client(rotated)
  client.jar.session = old.jar.session
  local res = client:get("/get/user")
  assert(res:text() == "ada" and #set_cookies(res) == 1, "re-issued although only read")
  assert(client.jar.session ~= old.jar.session)
  assert(#set_cookies(client:get("/get/user")) == 0)
end

local function test_a_handler_that_raises_saves_nothing_but_a_4xx_keeps_its_changes()
  local lines: {string} = {}
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
        return Web.text(Session.of(req):get_string(req.params.key) or "-")
      end),
    },
  }
  local client = Web.test_client(app)
  local res = client:post("/boom")
  assert(res.status == 500 and #set_cookies(res) == 0 and client.jar.session == nil)
  assert(client:get("/get/lost"):text() == "-")
  local kept = client:post("/invalid")
  assert(kept.status == 422 and #set_cookies(kept) == 1)
end

local function test_a_value_that_is_not_json_raises_at_the_set()
  local client = Web.test_client(make_app(options(cookie_store())))
  assert(client:post("/bad").status == 500)
  local reasons = { value = {} as {string} }
  local app = Web.app{
    middleware = { Session.middleware(options(cookie_store())) },
    routes = { Web.get("/", function(req: Web.Request): Web.Response
      local s = Session.of(req)
      local _, f = pcall(function() s:set("f", print as any) end)
      local _, e = pcall(function() s:set("", 1) end)
      local _, r = pcall(function() s:set("_flash", 1) end)
      reasons.value = { tostring(f), tostring(e), tostring(r) }
      return Web.text("done")
    end) },
  }
  assert(Web.test_client(app):get("/").status == 200)
  assert(reasons.value[1]:find("cannot keep f", 1, true), reasons.value[1])
  assert(reasons.value[2]:find("non-empty string", 1, true), reasons.value[2])
  assert(reasons.value[3]:find("reserved", 1, true), reasons.value[3])
end

local function test_the_handle_is_frozen_once_the_response_is_built()
  local client = Web.test_client(make_app(options(cookie_store())))
  client:get("/get/user")
  local handle = seen[#seen]
  local ok, why = pcall(function() handle:set("late", "write") end)
  assert(not ok and tostring(why):find("written after the response head was built", 1, true), tostring(why))
  ok = pcall(function() handle:flash("info", "late") end)
  assert(not ok)
  assert(handle:get_string("late") == nil)
end

local function test_pop_and_clear_remove_values_and_clearing_nothing_writes_nothing()
  local client = Web.test_client(make_app(options(cookie_store())))
  client:post("/set/a/1")
  client:post("/set/b/2")
  assert(client:post("/pop/a"):text() == "1")
  assert(client:get("/get/a"):text() == "-" and client:get("/get/b"):text() == "2")
  client:post("/clear")
  assert(client:get("/get/b"):text() == "-")
  assert(#set_cookies(Web.test_client(make_app(options(cookie_store()))):post("/clear")) == 0,
    "clearing an anonymous empty session writes nothing")
end

local function test_session_of_without_the_middleware_raises()
  local app = Web.app{ routes = { Web.get("/", function(req: Web.Request): Web.Response
    return Web.text(Session.of(req):get_string("x") or "-")
  end) }, sink = { line = function(_self: Web.Sink, _text: string) end } }
  assert(Web.test_client(app):get("/").status == 500)
end

local function test_a_failing_store_is_a_500_and_a_cookie_over_the_limit_is_raised_for_the_developer()
  local failing: Session.Store = {
    revocable = false,
    load = function(_: Session.Store, _t: string, _n: integer, _c: string): Session.Data | nil, string
      return nil, "disk on fire"
    end,
    save = function(_: Session.Store, _p: string, _d: Session.Data, _ch: Session.Changes, _n: integer,
                    _c: string): string | nil, string
      return nil, "no space"
    end,
    destroy = function(_: Session.Store, _t: string): boolean, string return true, "" end,
  }
  local lines: {string} = {}
  local spec: Web.AppSpec = { sink = { line = function(_self: Web.Sink, text: string)
    lines[#lines + 1] = text
  end } }
  local app = make_app(options(failing), spec)
  local client = Web.test_client(app)
  local ok, why = pcall(function() client:post("/set/a/b") end)
  assert(not ok and tostring(why):find("session: no space", 1, true), tostring(why))
  -- A load runs in the handler, where the exception layer answers 500 and logs the fault.
  assert(client:get("/get/a", { cookies = { session = "anything" } }).status == 500)
  assert(table.concat(lines, "\n"):find("session: disk on fire", 1, true))
  local big = Web.test_client(make_app(options(SessionCookie.store{ keys = { KEY }, max_bytes = 200 }), spec))
  ok, why = pcall(function() big:post("/set/a/" .. ("x"):rep(300)) end)
  assert(not ok and tostring(why):find("cookie would be", 1, true), tostring(why))
end

local function test_secure_follows_the_scheme_and_a_secure_cookie_is_sent_only_over_https()
  local app = make_app(options(cookie_store()), { trusted_proxy = true })
  local client = Web.test_client(app)
  local plain = client:post("/set/user/ada")
  assert(not assert(Cookies.parse_set_cookie(set_cookies(plain)[1])).secure)
  local https = Web.test_client(app)
  https.scheme = "https"
  local res = https:post("/set/user/ada")
  local parsed = assert(Cookies.parse_set_cookie(set_cookies(res)[1]))
  assert(parsed.secure and parsed.name == "session")
  assert(https:get("/get/user"):text() == "ada")
  https.scheme = "http"
  assert(https:get("/get/user"):text() == "-", "a Secure cookie is not sent over http")
end

local function test_secure_true_names_the_cookie_host_prefixed_and_always_sets_secure()
  local app = make_app(options(cookie_store(), { secure = true }), { trusted_proxy = true })
  local client = Web.test_client(app)
  local res = client:post("/set/user/ada")
  local parsed = assert(Cookies.parse_set_cookie(set_cookies(res)[1]))
  assert(parsed.name == "__Host-session" and parsed.secure and parsed.path == "/" and parsed.domain == nil)
  assert(client:get("/get/user"):text() == "-", "a Secure cookie is not sent over http")
  client.scheme = "https"
  assert(client:get("/get/user"):text() == "ada")
end

local function test_options_that_cannot_work_are_refused_before_serving()
  local ok, why = pcall(Session.middleware, {} as Session.Options)
  assert(not ok and tostring(why):find("needs a store", 1, true))
  ok, why = pcall(Session.middleware, options(cookie_store(), { max_age = 0 }))
  assert(not ok and tostring(why):find("max_age", 1, true))
  ok, why = pcall(Session.middleware, options(cookie_store(), { cookie_name = "__Host-x" }))
  assert(not ok and tostring(why):find("__Host-", 1, true), tostring(why))
  ok = pcall(Session.middleware, options(cookie_store(), { cookie_name = "bad name" }))
  assert(not ok)
end

local function test_sqlite_sessions_are_revocable_by_logout_and_by_subject()
  local store, db = sqlite_store()
  local app = make_app(options(store))
  local client = Web.test_client(app)
  client:post("/login")
  local stolen = client.jar.session
  assert(#stolen == 43 and client:get("/get/user"):text() == "ada")
  assert(client:get("/id"):text() == stolen)
  local out = client:post("/logout")
  local gone = assert(Cookies.parse_set_cookie(set_cookies(out)[1]))
  assert(gone.max_age == 0 and gone.value == "" and client.jar.session == nil)
  local thief = Web.test_client(app)
  assert(thief:get("/get/user", { cookies = { session = stolen } }):text() == "-", "the id is revoked")
  assert(assert(Sqlite.rows(db, "SELECT count(*) FROM web_sessions"))[1]:integer(1) == 0)
  local first, second = Web.test_client(app), Web.test_client(app)
  first:post("/login")
  second:post("/login")
  assert(SessionSqlite.destroy_subject(store, "ada") == 2)
  assert(first:get("/get/user"):text() == "-" and second:get("/get/user"):text() == "-")
end

local function test_regenerate_changes_the_id_and_keeps_the_data()
  local store = sqlite_store()
  local app = make_app(options(store))
  local client = Web.test_client(app)
  client:post("/set/theme/dark")
  local before = client.jar.session
  local res = client:post("/login")
  local after = client.jar.session
  assert(before ~= after and #set_cookies(res) == 1)
  assert(client:get("/get/theme"):text() == "dark" and client:get("/get/user"):text() == "ada")
  assert(Web.test_client(app):get("/get/theme", { cookies = { session = before } }):text() == "-")
  local cookie_app = Web.test_client(make_app(options(cookie_store())))
  cookie_app:post("/set/theme/dark")
  local first = cookie_app.jar.session
  clock.now = clock.now + 5
  cookie_app:post("/login")
  assert(cookie_app.jar.session ~= first)
  assert(cookie_app:get("/get/theme"):text() == "dark")
end

local function test_a_signed_cookie_logout_clears_the_browser_but_cannot_revoke_the_copy()
  local app = make_app(options(cookie_store()))
  local client = Web.test_client(app)
  client:post("/login")
  local copy = client.jar.session
  client:post("/logout")
  assert(client.jar.session == nil and client:get("/get/user"):text() == "-")
  assert(Web.test_client(app):get("/get/user", { cookies = { session = copy } }):text() == "ada")
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
      return Web.text(Session.of(req):get_string(req.params.key) or "-")
    end), Web.post("/set/:key/:value", function(req: Web.Request): Web.Response
      Session.of(req):set(req.params.key, req.params.value)
      return Web.text("ok")
    end) },
  }
  local client = Web.test_client(app)
  client:post("/set/old/1")
  local before = client.jar.session
  client:post("/swap")
  assert(client.jar.session ~= before)
  assert(client:get("/get/old"):text() == "-" and client:get("/get/fresh"):text() == "yes")
end

local function test_sqlite_expiry_and_rolling_follow_the_clock()
  local store = sqlite_store()
  local client = Web.test_client(make_app(options(store, { max_age = 1000, rolling = true })))
  client:post("/set/user/ada")
  clock.now = clock.now + 600
  assert(client:get("/get/user"):text() == "ada")
  clock.now = clock.now + 900
  assert(client:get("/get/user"):text() == "ada", "the read at 600 renewed it")
  clock.now = clock.now + 1000
  assert(client:get("/get/user"):text() == "-")
end

local function test_the_session_survives_in_a_secret_key_from_the_environment_shape()
  local keys = assert(Secret.parse_keys(KEY))
  local client = Web.test_client(make_app(options(SessionCookie.store{ keys = keys })))
  client:post("/set/user/ada")
  assert(client:get("/get/user"):text() == "ada")
end

--- A value nested `levels` arrays deep.
local function nest(levels: integer): any
  local value: any = 1
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
        Session.of(req):set("v", req.params.v)
        return shared
      end) },
    }
    local first = Web.test_client(app):post("/shared/one")
    local second = Web.test_client(app):post("/shared/two")
    for _, res in ipairs({ first, second }) do
      local own = 0
      for _, line in ipairs(set_cookies(res)) do
        if line:find("^session=") then own = own + 1 end
      end
      assert(own == 1 and #set_cookies(res) == 3, "its own one session cookie beside the shared two")
    end
    assert(set_cookies(first)[3] ~= set_cookies(second)[3])
    local lines = assert(shared.headers)["Set-Cookie"]
    assert(lines is {string} and #lines == 2, "the shared response is unchanged")
    assert(Web.header(shared, "Vary") == nil and Web.header(shared, "Cache-Control") == nil)
  end
end

local function test_a_value_at_the_depth_limit_survives_and_one_past_it_raises_at_the_set()
  for _, make in ipairs({ cookie_store, function(): Session.Store return (sqlite_store()) end }) do
    local reasons: {string} = {}
    local app = Web.app{
      middleware = { Session.middleware(options(make())) },
      routes = {
        Web.post("/deep", function(req: Web.Request): Web.Response
          local s = Session.of(req)
          s:set("ok", nest(Session.MAX_DEPTH - 1))
          local ran, why = pcall(function() s:set("too", nest(Session.MAX_DEPTH)) end)
          reasons[#reasons + 1] = ran and "no error" or tostring(why)
          return Web.text("ok")
        end),
        Web.get("/has/:key", function(req: Web.Request): Web.Response
          return Web.text(tostring(Session.of(req):get(req.params.key) ~= nil))
        end),
        Web.get("/new", function(req: Web.Request): Web.Response
          return Web.text(tostring(Session.of(req):is_new()))
        end),
      },
    }
    local client = Web.test_client(app)
    assert(client:post("/deep").status == 200)
    assert(reasons[1]:find("cannot keep too", 1, true), reasons[1])
    assert(client:get("/new"):text() == "false", "the next request still has the session")
    assert(client:get("/has/ok"):text() == "true" and client:get("/has/too"):text() == "false")
  end
end

local function test_a_flash_that_is_not_utf8_raises_at_the_call()
  local reasons: {string} = {}
  local app = Web.app{
    middleware = { Session.middleware(options(cookie_store())) },
    routes = { Web.post("/f", function(req: Web.Request): Web.Response
      local ran, why = pcall(function() Session.of(req):flash("info", "bad \xff text") end)
      reasons[#reasons + 1] = ran and "no error" or tostring(why)
      return Web.text("ok")
    end) },
  }
  local res = Web.test_client(app):post("/f")
  assert(res.status == 200 and #set_cookies(res) == 0, "nothing was kept")
  assert(reasons[1]:find("session: cannot flash", 1, true), reasons[1])
end

local function test_setting_nil_removes_the_key_in_both_stores()
  for _, make in ipairs({ cookie_store, function(): Session.Store return (sqlite_store()) end }) do
    local app = Web.app{
      middleware = { Session.middleware(options(make())) },
      routes = {
        Web.post("/set/:key/:value", function(req: Web.Request): Web.Response
          Session.of(req):set(req.params.key, req.params.value)
          return Web.text("ok")
        end),
        Web.post("/unset/:key", function(req: Web.Request): Web.Response
          Session.of(req):set(req.params.key, nil)
          return Web.text("ok")
        end),
        Web.get("/get/:key", function(req: Web.Request): Web.Response
          return Web.text(Session.of(req):get_string(req.params.key) or "-")
        end),
      },
    }
    local client = Web.test_client(app)
    client:post("/set/a/1")
    client:post("/set/b/2")
    client:post("/unset/a")
    assert(client:get("/get/a"):text() == "-" and client:get("/get/b"):text() == "2")
  end
end

local function test_same_site_none_follows_the_scheme_of_the_request()
  local app = make_app(options(cookie_store(), { same_site = "None" }), { trusted_proxy = true })
  local client = Web.test_client(app)
  client.scheme = "https"
  local parsed = assert(Cookies.parse_set_cookie(set_cookies(client:post("/set/a/1"))[1]))
  assert(parsed.secure and parsed.same_site == "None")
  local plain = Web.test_client(app)
  assert(#set_cookies(plain:get("/get/a")) == 0, "reading over http is fine")
  local ok, why = pcall(function() plain:post("/set/a/1") end)
  assert(not ok and tostring(why):find("needs a Secure cookie", 1, true), tostring(why))
  ok = pcall(Session.middleware, options(cookie_store(), { same_site = "None", secure = false }))
  assert(not ok, "an explicit secure = false can never work")
end

local function test_invalidate_revokes_even_when_the_response_is_a_500()
  local store, db = sqlite_store()
  local app = Web.app{
    middleware = { Session.middleware(options(store)) },
    routes = {
      Web.post("/set/:key/:value", function(req: Web.Request): Web.Response
        Session.of(req):set(req.params.key, req.params.value)
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
  local client = Web.test_client(app)
  client:post("/set/user/ada")
  local before = client.jar.session
  local res = client:post("/logout-fails")
  assert(res.status == 500)
  assert(assert(Sqlite.rows(db, "SELECT count(*) FROM web_sessions"))[1]:integer(1) == 0, "the row is gone")
  assert(store:load(before, clock.now, "session") == nil)
  assert(#set_cookies(res) == 1 and client.jar.session == nil, "and the cookie is expired")
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
  local client = Web.test_client(app)
  client:post("/seed")
  assert(client:get("/peek").body == "secret/ada")
  client:post("/regenerate")
  assert(client:get("/peek").body == "-/ada")
end
