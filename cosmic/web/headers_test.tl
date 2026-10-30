local Csp = require("cosmic.web.csp")
local Headers = require("cosmic.web.headers")
local Html = require("cosmic.html")
local Htmx = require("cosmic.web.htmx")
local Web = require("cosmic.web")

--- A response one route shares between requests.
local shared: Web.Response = { status = 200, headers = { ["Content-Type"] = "text/plain" }, body = "shared" }

local function make_app(opts?: Headers.Options, more?: {Web.Route}, spec?: Web.AppSpec): Web.App
  local made: Web.AppSpec = spec or {}
  made.sink = { line = function(_self: Web.Sink, _text: string) end }
  made.middleware = { Headers.middleware(opts) }
  local routes: mut {Web.Route} = {
    Web.get("/", function(_req: Web.Request): Web.Response
      return Web.text("plain")
    end),
    Web.get("/page", function(req: Web.Request): Web.Response
      local nonce = assert(req:get(Headers.NONCE))
      return Web.html(Html.concat({ Html.trust("<head>"), Htmx.head{ nonce = nonce },
        Html.trust('</head><script nonce="' .. nonce .. '">1</script>') }))
    end),
    Web.get("/shared", function(_req: Web.Request): Web.Response
      return shared
    end),
    Web.get("/own", function(_req: Web.Request): Web.Response
      return Web.text("own", { headers = { ["content-security-policy"] = "default-src 'none'",
        ["X-FRAME-OPTIONS"] = "SAMEORIGIN", ["referrer-policy"] = "no-referrer",
        ["Cache-Control"] = "max-age=60" } })
    end),
    Web.get("/public", function(_req: Web.Request): Web.Response
      return Web.text("p", { headers = { ["cache-control"] = "Public, max-age=60, s-maxage=600" } })
    end),
    Web.get("/store", function(_req: Web.Request): Web.Response
      return Web.text("s", { headers = { ["Cache-Control"] = "no-store" } })
    end),
    Web.get("/private", function(_req: Web.Request): Web.Response
      return Web.text("s", { headers = { ["Cache-Control"] = "private, max-age=5" } })
    end),
    Web.get("/boom", function(_req: Web.Request): Web.Response
      error("a fault")
    end),
    Web.get("/denied", function(_req: Web.Request): Web.Response
      return Web.abort(403)
    end),
    Web.get("/not-modified", function(_req: Web.Request): Web.Response
      return Web.empty(304)
    end),
  }
  for _, each in ipairs(more or {}) do routes[#routes + 1] = each end
  made.routes = routes
  return Web.app(made)
end

local function test_the_defaults_are_set_and_the_opt_in_headers_are_not()
  local res = Web.test_client(make_app()):get("/")
  assert(res.headers["x-content-type-options"] == "nosniff")
  assert(res.headers["referrer-policy"] == "strict-origin-when-cross-origin")
  assert(res.headers["x-frame-options"] == "DENY")
  assert(res.headers["cross-origin-opener-policy"] == "same-origin")
  assert(res.headers["permissions-policy"] == "camera=(), microphone=(), geolocation=()")
  assert(res.headers["cross-origin-resource-policy"] == nil)
  assert(res.headers["strict-transport-security"] == nil)
  assert(res.headers["content-security-policy"] == nil)
  assert(res.headers["x-xss-protection"] == nil)
  assert(res.headers["cache-control"] == nil)
end

local function test_a_field_set_to_nothing_omits_its_header()
  local res = Web.test_client(make_app{ nosniff = false, referrer_policy = "", frame_options = "", coop = "",
    permissions_policy = "", corp = "same-site" }):get("/shared")
  for _, name in ipairs({ "x-content-type-options", "referrer-policy", "x-frame-options",
      "cross-origin-opener-policy", "permissions-policy" }) do
    assert(res.headers[name] == nil, name)
  end
  assert(res.headers["cross-origin-resource-policy"] == "same-site")
end

local function test_what_the_handler_set_is_kept_in_any_case_of_its_name()
  local res = Web.test_client(make_app{ csp = Csp.htmx_default() }):get("/own")
  assert(res.headers["content-security-policy"] == "default-src 'none'")
  assert(res.headers["x-frame-options"] == "SAMEORIGIN")
  assert(res.headers["referrer-policy"] == "no-referrer")
  assert(res.headers["cache-control"] == "max-age=60")
  assert(res.headers["x-content-type-options"] == "nosniff", "and the rest are still added")
  assert(#res:header_list("content-security-policy") == 1)
end

local function test_errors_and_not_modified_replies_get_the_headers_too()
  local client = Web.test_client(make_app{ csp = Csp.htmx_default() })
  for _, path in ipairs({ "/missing", "/boom", "/denied", "/not-modified" }) do
    local res = client:get(path)
    assert(res.headers["x-content-type-options"] == "nosniff", path .. " " .. tostring(res.status))
    assert(res.headers["content-security-policy"] ~= nil, path)
  end
  assert(client:head("/").headers["x-frame-options"] == "DENY")
  assert(client:request("DELETE", "/").status == 405)
  assert(client:request("DELETE", "/").headers["x-frame-options"] == "DENY")
end

local function test_a_response_a_handler_shares_is_not_changed()
  local client = Web.test_client(make_app{ csp = Csp.htmx_default(), hsts = { max_age = 1 } })
  assert(client:get("/shared").headers["content-security-policy"] ~= nil)
  assert(client:get("/shared").headers["x-frame-options"] == "DENY")
  local count = 0
  for _ in pairs(assert(shared.headers)) do count = count + 1 end
  assert(count == 1, "the shared table still holds its one header")
end

local function test_the_htmx_default_policy_is_the_one_the_plan_states()
  assert(Csp.format(Csp.htmx_default()) ==
      "base-uri 'none'; connect-src 'self'; default-src 'self'; font-src 'self'; form-action 'self'; " ..
      "frame-ancestors 'none'; img-src 'self' data:; object-src 'none'; script-src 'self'; style-src 'self'")
  local policy: Csp.Policy = { directives = { ["upgrade-insecure-requests"] = {}, ["script-src"] = { "'self'", "{nonce}" } } }
  assert(Csp.format(policy, "abc") == "script-src 'self' 'nonce-abc'; upgrade-insecure-requests")
end

local function test_a_policy_cannot_be_made_to_say_more_than_it_was_given()
  local function bad(directives: {string:{string}}, nonce?: string)
    assert(not pcall(Csp.format, { directives = directives }, nonce))
  end
  bad({ ["script-src"] = { "'self'; script-src *" } })
  bad({ ["script-src"] = { "'self' *" } })
  bad({ ["script-src"] = { "a,b" } })
  bad({ ["script-src"] = { "a\r\nSet-Cookie: x" } })
  bad({ ["script-src"] = { "" } })
  bad({ ["script-src *; x"] = { "'self'" } })
  bad({ ["Script-Src"] = { "'self'" } })
  bad({ [""] = { "'self'" } })
  bad({ ["script-src"] = { "{nonce}" } })
  bad({ ["script-src"] = { "{nonce}" } }, "")
end

local function test_report_only_and_the_frame_ancestors_that_follow_frame_options()
  local res = Web.test_client(make_app{ csp = { directives = { ["default-src"] = { "'self'" } } },
    csp_report_only = true, frame_options = "SAMEORIGIN" }):get("/")
  assert(res.headers["content-security-policy"] == nil)
  assert(res.headers["content-security-policy-report-only"] == "default-src 'self'; frame-ancestors 'self'")
  local deny = Web.test_client(make_app{ csp = { directives = { ["default-src"] = { "'self'" } } } }):get("/")
  assert(deny.headers["content-security-policy"] == "default-src 'self'; frame-ancestors 'none'")
  local explicit = Web.test_client(make_app{ csp = { directives = { ["frame-ancestors"] = { "https://a.example" } } } })
  assert(explicit:get("/").headers["content-security-policy"] == "frame-ancestors https://a.example")
  local off = Web.test_client(make_app{ csp = { directives = { ["default-src"] = { "'self'" } } }, frame_options = "" })
  assert(off:get("/").headers["content-security-policy"] == "default-src 'self'")
end

local function test_each_request_draws_its_own_nonce_for_the_policy_and_the_page()
  local client = Web.test_client(make_app{ nonce = true, csp = { directives = {
    ["script-src"] = { "'self'", "{nonce}" } } } })
  local first = client:get("/page")
  local second = client:get("/page")
  local one = assert(first.headers["content-security-policy"]:match("'nonce%-([%w_-]+)'"))
  local two = assert(second.headers["content-security-policy"]:match("'nonce%-([%w_-]+)'"))
  assert(one ~= two and #one == 22, "16 random bytes, base64url")
  assert(first.body:find('<script nonce="' .. one .. '">1</script>', 1, true), "the layout's own script")
  local decoded = first.body:gsub("&#45;", "-"):gsub("&#95;", "_")
  assert(decoded:find('nonce="' .. one .. '" defer', 1, true), "and Htmx.head's tag")
  assert(not first.body:find(two, 1, true))
  assert(first.headers["cache-control"] == "private", "a page with a nonce is not for a shared cache")
  assert(client:get("/").headers["cache-control"] == "private", "whatever the type")
  assert(client:get("/own").headers["cache-control"] == "max-age=60, private")
  assert(client:get("/public").headers["cache-control"] == "max-age=60, private", "public and s-maxage go")
  assert(client:get("/store").headers["cache-control"] == "no-store", "no-store stands")
  assert(client:get("/private").headers["cache-control"] == "private, max-age=5", "private stands")
end

local function test_without_nonce_the_key_is_empty_and_the_policy_may_not_ask_for_one()
  local seen: string? = nil
  local app = make_app({ csp = Csp.htmx_default() }, { Web.get("/n", function(req: Web.Request): Web.Response
    seen = req:get(Headers.NONCE)
    return Web.html(Html.trust("<p>x</p>"))
  end) })
  local res = Web.test_client(app):get("/n")
  assert(seen == "" and res.headers["cache-control"] == nil)
  assert(not pcall(Headers.middleware, { csp = { directives = { ["script-src"] = { "{nonce}" } } } }))
end

local function test_hsts_is_sent_only_over_https()
  local app = make_app({ hsts = { max_age = 31536000, include_subdomains = true, preload = true } },
    nil, { trusted_proxy = true })
  local client = Web.test_client(app)
  assert(client:get("/").headers["strict-transport-security"] == nil, "never on plain http")
  client.scheme = "https"
  assert(client:get("/").headers["strict-transport-security"] == "max-age=31536000; includeSubDomains; preload")
  local forged = Web.test_client(make_app({ hsts = { max_age = 5 } }))
  forged.scheme = "https"
  assert(forged:get("/", { headers = { ["X-Forwarded-Proto"] = "https" } }).headers["strict-transport-security"] == nil,
    "a header is believed only with trusted_proxy")
  local plain = Web.test_client(make_app({ hsts = { max_age = 0 } }, nil, { trusted_proxy = true }))
  plain.scheme = "https"
  assert(plain:get("/").headers["strict-transport-security"] == "max-age=0")
end

local function test_a_route_nearer_the_handler_has_the_last_word()
  local inner = Headers.middleware{ csp = { directives = { ["default-src"] = { "'none'" } } }, frame_options = "SAMEORIGIN",
    nonce = true }
  local app = make_app({ csp = Csp.htmx_default(), nonce = true }, {
    Web.get("/widget", function(req: Web.Request): Web.Response
      return Web.text(req:get(Headers.NONCE) or "-")
    end, { middleware = { inner } }),
  })
  local client = Web.test_client(app)
  local res = client:get("/widget")
  assert(res.headers["content-security-policy"] == "default-src 'none'; frame-ancestors 'self'")
  assert(res.headers["x-frame-options"] == "SAMEORIGIN")
  assert(#res:header_list("x-frame-options") == 1)
  assert(res.body ~= "" and res.body ~= "-", "the handler saw a nonce")
  assert(client:get("/").headers["content-security-policy"]:find("frame%-ancestors 'none'"), "elsewhere the app's")
end

local function test_options_that_cannot_work_raise()
  local function bad(opts: Headers.Options)
    assert(not pcall(Headers.middleware, opts))
  end
  bad({ frame_options = "ALLOW-FROM x" })
  bad({ frame_options = "deny" })
  bad({ coop = "same-origin\r\nSet-Cookie: a=b" })
  bad({ corp = "everyone" })
  bad({ referrer_policy = "no-referrer\n" })
  bad({ permissions_policy = "camera=()\r\nX: y" })
  bad({ hsts = { max_age = -1 } })
  bad({ hsts = { max_age = 100, preload = true, include_subdomains = true } })
  bad({ hsts = { max_age = 31536000, preload = true } })
  bad({ csp = { directives = { ["script-src"] = { "'self';" } } } })
end
