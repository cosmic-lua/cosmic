local Cors = require("cosmic.web.cors")
local Csrf = require("cosmic.web.csrf")
local Web = require("cosmic.web")

local APP <const> = "https://app.example.com"

--- Handlers of the app under test count how often they run.
local ran = { count = 0 }

--- A response one handler returns for every request.
local shared: Web.Response = { status = 200, headers = { ["Content-Type"] = "text/plain", Vary = "Accept" },
  body = "shared" }

local function make_app(opts: Cors.Options, more?: {Web.Middleware}): Web.App
  local stack: mut {Web.Middleware} = { Cors.middleware(opts) }
  for _, each in ipairs(more or {}) do stack[#stack + 1] = each end
  return Web.app{
    sink = { line = function(_self: Web.Sink, _text: string) end },
    middleware = stack,
    routes = {
      Web.get("/data", function(_req: Web.Request): Web.Response
        ran.count = ran.count + 1
        return Web.json({ ok = true })
      end),
      Web.get("/shared", function(_req: Web.Request): Web.Response
        return shared
      end),
      Web.get("/vary", function(_req: Web.Request): Web.Response
        return Web.text("v", { headers = { Vary = "Accept-Encoding" } })
      end),
      Web.get("/denied", function(_req: Web.Request): Web.Response
        return Web.abort(403, "no")
      end),
      Web.get("/boom", function(_req: Web.Request): Web.Response
        error("a fault")
      end),
      Web.post("/save", function(_req: Web.Request): Web.Response
        ran.count = ran.count + 1
        return Web.text("saved")
      end),
    },
  }
end

local function get(client: Web.TestClient, origin: string?, path?: string): Web.TestResponse
  local headers: mut {string:string} = {}
  if origin ~= nil then headers["Origin"] = origin end
  return client:get(path or "/data", { headers = headers })
end

local function preflight(client: Web.TestClient, origin: string, method: string?,
                         asked?: string): Web.TestResponse
  local headers: mut {string:string} = { Origin = origin }
  if method ~= nil then headers["Access-Control-Request-Method"] = method end
  if asked ~= nil then headers["Access-Control-Request-Headers"] = asked end
  return client:options("/save", { headers = headers })
end

local function test_an_allowed_origin_is_echoed_with_credentials_and_exposed_headers()
  local client = Web.test_client(make_app{ allow_origins = { APP }, allow_credentials = true,
    expose_headers = { "X-Total", "ETag" } })
  local res = get(client, APP)
  assert(res.status == 200)
  assert(res.headers["access-control-allow-origin"] == APP)
  assert(res.headers["access-control-allow-credentials"] == "true")
  assert(res.headers["access-control-expose-headers"] == "X-Total, ETag")
  assert(res.headers["vary"] == "Origin")
end

local function test_a_stranger_gets_no_grant_and_the_cache_is_told_the_answer_varies()
  local client = Web.test_client(make_app{ allow_origins = { APP }, allow_credentials = true })
  ran.count = 0
  local res = client:post("/save", { headers = { Origin = "https://evil.example" } })
  assert(res.status == 200 and ran.count == 1, "CORS is not authorization: the request still runs")
  assert(res.headers["access-control-allow-origin"] == nil)
  assert(res.headers["access-control-allow-credentials"] == nil)
  assert(res.headers["vary"] == "Origin")
  local none = get(client, nil)
  assert(none.headers["access-control-allow-origin"] == nil)
  assert(none.headers["vary"] == "Origin", "a request without an Origin varies too")
end

local function test_vary_is_merged_into_the_one_the_handler_sent()
  local client = Web.test_client(make_app{ allow_origins = { APP } })
  assert(get(client, APP, "/vary").headers["vary"] == "Accept-Encoding, Origin")
  assert(get(client, APP, "/shared").headers["vary"] == "Accept, Origin")
end

local function test_a_response_a_handler_shares_is_not_changed()
  local client = Web.test_client(make_app{ allow_origins = { APP }, allow_credentials = true })
  assert(get(client, APP, "/shared").headers["access-control-allow-origin"] == APP)
  assert(get(client, "https://evil.example", "/shared").headers["access-control-allow-origin"] == nil)
  local shared_headers = assert(shared.headers)
  assert(shared_headers["Access-Control-Allow-Origin"] == nil and shared_headers["Vary"] == "Accept",
    "the shared table is the handler's")
end

local function test_errors_carry_the_headers_so_the_browser_shows_them()
  local client = Web.test_client(make_app{ allow_origins = { APP } })
  for _, case in ipairs({ { "/missing", 404 }, { "/denied", 403 }, { "/boom", 500 } }) do
    local res = get(client, APP, case[1] as string)
    assert(res.status == case[2], case[1] as string .. " " .. res.status)
    assert(res.headers["access-control-allow-origin"] == APP, case[1] as string)
    assert(res.headers["vary"]:find("Origin", 1, true), case[1] as string)
  end
  local wrong = client:request("DELETE", "/data", { headers = { Origin = APP } })
  assert(wrong.status == 405 and wrong.headers["access-control-allow-origin"] == APP)
end

local function test_a_wildcard_grants_any_origin_but_never_with_credentials_or_null()
  local client = Web.test_client(make_app{ allow_origins = { "*" } })
  local res = get(client, "https://anyone.example")
  assert(res.headers["access-control-allow-origin"] == "*")
  assert(res.headers["access-control-allow-credentials"] == nil)
  assert(get(client, "null").headers["access-control-allow-origin"] == nil, "* does not cover null")
  assert(get(client, "not an origin").headers["access-control-allow-origin"] == nil)
  assert(not pcall(Cors.middleware, { allow_origins = { "https://.." } }), "a host of empty labels")
  assert(not pcall(Cors.middleware, { allow_origins = { "*" }, allow_credentials = true }))
  assert(not pcall(Cors.middleware, { allow_origins = { "*", APP } }))
end

local function test_null_is_allowed_only_by_being_listed()
  local listed = Web.test_client(make_app{ allow_origins = { "null" } })
  assert(get(listed, "null").headers["access-control-allow-origin"] == "null")
  local always = Web.test_client(make_app{ allow_origin = function(_origin: string): boolean
    return true
  end })
  assert(get(always, "null").headers["access-control-allow-origin"] == nil, "a predicate is not asked about null")
  assert(get(always, "https://x.example").headers["access-control-allow-origin"] == "https://x.example")
end

local function test_origins_match_exactly_in_scheme_host_and_port()
  local client = Web.test_client(make_app{ allow_origins = { "https://App.Example.com:443", "http://localhost:3000" } })
  local function allowed(origin: string): boolean
    return get(client, origin).headers["access-control-allow-origin"] == origin
  end
  assert(allowed("https://app.example.com"))
  assert(allowed("https://APP.example.com:443"), "case and a default port")
  assert(allowed("http://localhost:3000"))
  assert(not allowed("http://app.example.com"), "scheme")
  assert(not allowed("https://app.example.com:8443"), "port")
  assert(not allowed("http://localhost"), "port")
  assert(not allowed("https://app.example.com.evil.example"))
  assert(not allowed("https://evilapp.example.com"))
  assert(not allowed("https://app.example.com/"), "no path")
  assert(not allowed("https://app.example.com/x"))
  assert(not allowed("https://user@app.example.com"))
  assert(not allowed("https://app.example.com, https://evil.example"))
  assert(not allowed("https://app.example.com\t"))
end

local function test_a_predicate_sees_a_normalized_origin_and_never_a_malformed_one()
  local seen: mut {string} = {}
  local client = Web.test_client(make_app{ allow_origin = function(origin: string): boolean
    seen[#seen + 1] = origin
    return origin:find("%.example%.com$") ~= nil
  end })
  assert(get(client, "https://SUB.example.com:443").headers["access-control-allow-origin"] == "https://SUB.example.com:443")
  assert(get(client, "https://evil.example.org").headers["access-control-allow-origin"] == nil)
  assert(get(client, "https://a.example.com/path").headers["access-control-allow-origin"] == nil)
  assert(get(client, "https://a.example.com@evil.example").headers["access-control-allow-origin"] == nil)
  assert(table.concat(seen, ",") == "https://sub.example.com,https://evil.example.org", table.concat(seen, ","))
end

local function test_a_preflight_is_answered_without_the_router()
  local client = Web.test_client(make_app{ allow_origins = { APP }, allow_credentials = true,
    allow_methods = { "GET", "POST", "DELETE" }, allow_headers = { "X-Token", "Authorization" }, max_age = 120 })
  ran.count = 0
  local res = preflight(client, APP, "DELETE", "X-Token, authorization")
  assert(res.status == 204 and res.body == "")
  assert(res.headers["access-control-allow-origin"] == APP)
  assert(res.headers["access-control-allow-credentials"] == "true")
  assert(res.headers["access-control-allow-methods"] == "GET, POST, DELETE")
  assert(res.headers["access-control-allow-headers"] == "x-token, authorization")
  assert(res.headers["access-control-max-age"] == "120")
  assert(res.headers["vary"] == "Origin, Access-Control-Request-Method, Access-Control-Request-Headers")
  assert(ran.count == 0)
  local plain = preflight(client, APP, "POST")
  assert(plain.status == 204 and plain.headers["access-control-allow-headers"] == "X-Token, Authorization",
    "no headers asked: the configured ones")
  local safelisted = preflight(client, APP, "POST", "Content-Type, Accept")
  assert(safelisted.status == 204 and safelisted.headers["access-control-allow-headers"] == "content-type, accept")
end

local function test_a_preflight_the_config_does_not_allow_is_a_403_without_a_grant()
  local client = Web.test_client(make_app{ allow_origins = { APP }, allow_credentials = true,
    allow_headers = { "X-Token" } })
  local function refused(res: Web.TestResponse, why: string)
    assert(res.status == 403, why .. " " .. res.status)
    for name in pairs(res.headers) do
      assert(not name:find("^access%-control%-allow"), why .. " leaked " .. name)
    end
    assert(res.headers["vary"]:find("Origin", 1, true), why)
  end
  refused(preflight(client, "https://evil.example", "POST"), "origin")
  refused(preflight(client, "null", "POST"), "null")
  refused(preflight(client, APP, "DELETE"), "method")
  refused(preflight(client, APP, "post"), "method case")
  refused(preflight(client, APP, "POST", "X-Other"), "header")
  refused(preflight(client, APP, "POST", "X-Token, X-Other"), "second header")
  refused(preflight(client, APP, "POST", "X-Token, ,X-Token"), "blank header name")
  refused(preflight(client, APP, "POST", "x token"), "not a token")
  refused(preflight(client, APP, "POST", ("X"):rep(3000)), "too long")
  refused(preflight(client, APP, "POST,DELETE"), "two methods")
end

local function test_an_options_that_is_no_preflight_goes_to_the_router()
  local client = Web.test_client(make_app{ allow_origins = { APP } })
  local res = client:options("/data", { headers = { Origin = APP } })
  assert(res.headers["allow"] ~= nil, "the router's own answer")
  assert(res.headers["access-control-allow-origin"] == APP)
  assert(res.headers["access-control-allow-methods"] == nil)
  assert(client:options("/data").headers["access-control-allow-origin"] == nil)
end

local function test_a_wildcard_header_list_repeats_only_valid_names()
  local client = Web.test_client(make_app{ allow_origins = { APP }, allow_headers = { "*" }, allow_credentials = true })
  local res = preflight(client, APP, "POST", "X-One, X-Two")
  assert(res.status == 204 and res.headers["access-control-allow-headers"] == "x-one, x-two")
  assert(preflight(client, APP, "POST", "X-One\r\nSet-Cookie: a=b").status == 403)
  assert(preflight(client, APP, "POST", "a b").status == 403)
  assert(res.headers["access-control-allow-headers"]:find("*", 1, true) == nil, "never a literal *")
end

local function test_a_preflight_has_a_default_age_and_method_list()
  local client = Web.test_client(make_app{ allow_origins = { APP } })
  local res = preflight(client, APP, "GET")
  assert(res.headers["access-control-max-age"] == "600")
  assert(res.headers["access-control-allow-methods"] == "GET, HEAD, POST")
  assert(res.headers["access-control-allow-headers"] == nil)
  assert(preflight(client, APP, "PUT").status == 403)
  local zero = Web.test_client(make_app{ allow_origins = { APP }, max_age = 0 })
  assert(preflight(zero, APP, "GET").headers["access-control-max-age"] == "0")
end

local function test_a_config_that_cannot_work_raises_at_construction()
  local function bad(opts: Cors.Options)
    assert(not pcall(Cors.middleware, opts))
  end
  bad({ allow_origins = { "app.example.com" } })
  bad({ allow_origins = { "https://app.example.com/path" } })
  bad({ allow_origins = { "https://*.example.com" } })
  bad({ allow_origins = { "ftp://app.example.com" } })
  bad({ allow_origins = { "https://app.example.com?x" } })
  bad({ allow_origins = { "" } })
  bad({ allow_origins = { APP }, allow_methods = { "*" } })
  bad({ allow_origins = { APP }, allow_methods = { "get" } })
  bad({ allow_origins = { APP }, allow_methods = { "GE T" } })
  bad({ allow_origins = { APP }, allow_headers = { "X Bad" } })
  bad({ allow_origins = { APP }, expose_headers = { "X\r\nBad" } })
  bad({ allow_origins = { APP }, max_age = -1 })
end

local function test_cors_outside_csrf_lets_a_refusal_reach_the_page()
  local app = make_app({ allow_origins = { APP }, allow_credentials = true }, {
    Csrf.middleware{ token = false, trusted_origins = Cors.trusted({ allow_origins = { APP } }) },
  })
  local client = Web.test_client(app)
  local res = client:post("/save", { headers = { Origin = "https://evil.example" } })
  assert(res.status == 403 and res.headers["access-control-allow-origin"] == nil)
  local partner = client:post("/save", { headers = { Origin = APP, ["Sec-Fetch-Site"] = "cross-site" } })
  assert(partner.status == 200 and partner.headers["access-control-allow-origin"] == APP)
  assert(preflight(client, APP, "POST").status == 204, "the preflight never reaches CSRF")
end
