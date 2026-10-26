local Csrf = require("cosmic.web.csrf")
local Cors = require("cosmic.web.cors")
local Html = require("cosmic.html")
local Input = require("cosmic.web.input")
local Session = require("cosmic.web.session")
local Stream = require("cosmic.stream")
local Web = require("cosmic.web")

local SELF <const> = "http://testserver"

--- A revocable store that keeps sessions in a table, under ids.
local function memory_store(): Session.Store
  local rows: mut {string:Session.Data} = {}
  local count = { value = 0 }
  local store: Session.Store = {
    revocable = true,
    load = function(_self: Session.Store, token: string, now: integer, _cookie: string): Session.Data?, string
      local row = rows[token]
      if row == nil or row.expires <= now then return nil, "" end
      local values: mut {string:any} = {}
      for k, v in pairs(row.values) do values[k] = v end
      return { values = values, created = row.created, expires = row.expires }, ""
    end,
    save = function(_self: Session.Store, previous: string, data: Session.Data, changes: Session.Changes,
                    _now: integer, _cookie: string): string?, string
      local id = previous
      if id == "" or changes.regenerated then
        count.value = count.value + 1
        id = "id" .. count.value
        rows[previous] = nil
      end
      local values: mut {string:any} = {}
      for k, v in pairs(data.values) do values[k] = v end
      rows[id] = { values = values, created = data.created, expires = data.expires }
      return id, ""
    end,
    destroy = function(_self: Session.Store, token: string): boolean, string
      rows[token] = nil
      return true, ""
    end,
  }
  return store
end

--- The lines the app's sink received.
local lines = { value = {} as {string} }

--- An app with a form page, state-changing routes and a login, behind the
--- session and `Csrf.middleware(opts)`.
local function make_app(opts?: Csrf.Options, spec?: Web.AppSpec): Web.App
  local made: Web.AppSpec = spec or {}
  made.sink = { line = function(_self: Web.Sink, text: string)
    lines.value[#lines.value + 1] = text
  end }
  made.middleware = {
    Session.middleware{ store = memory_store() },
    Csrf.middleware(opts),
  }
  made.routes = {
    Web.get("/token", function(req: Web.Request): Web.Response
      return Web.text(Csrf.token(req))
    end),
    Web.get("/field", function(req: Web.Request): Web.Response
      return Web.html(Html.concat({ Html.trust("<form>"), Csrf.field(req), Html.trust("</form>") }))
    end),
    Web.get("/meta", function(req: Web.Request): Web.Response
      return Web.html(Csrf.meta(req))
    end),
    Web.get("/hx", function(req: Web.Request): Web.Response
      return Web.text(Html.raw_json(Csrf.hx_headers(req)))
    end),
    Web.get("/mutates", function(_req: Web.Request): Web.Response
      return Web.text("a GET")
    end),
    Web.post("/do", function(req: Web.Request): Web.Response
      return Web.text("done:" .. (req:text() or "?"))
    end),
    Web.route({ "PUT", "PATCH", "DELETE" }, "/do", function(_req: Web.Request): Web.Response
      return Web.text("changed")
    end),
    Web.route("HEAD", "/head-only", function(_req: Web.Request): Web.Response
      return Web.text("state changed")
    end),
    Web.route("OPTIONS", "/opts-only", function(_req: Web.Request): Web.Response
      return Web.text("state changed")
    end),
    Web.post("/login", function(req: Web.Request): Web.Response
      Session.of(req):regenerate()
      return Web.text("in")
    end),
    Web.post("/form", function(req: Web.Request): Web.Response
      local got = Input.form(req)
      if got.invalid ~= nil then return Web.text("invalid", { status = 400 }) end
      local query = assert(got.value)
      return Web.text("name=" .. (query.by_name["name"] or { "-" })[1])
    end),
    Web.post("/upload", function(req: Web.Request): Web.Response
      local got = Input.multipart(req)
      if got.invalid ~= nil then return Web.text("invalid", { status = 400 }) end
      local multipart = assert(got.value)
      local count = 0
      for _ in pairs(multipart.files) do count = count + 1 end
      return Web.text(("name=%s files=%d"):format((multipart.fields.by_name["name"] or { "-" })[1], count))
    end),
  }
  return Web.app(made)
end

--- A client with a session that has drawn its token, and the token.
local function session_with_token(app: Web.App): Web.TestClient, string
  local client = Web.test_client(app)
  local res = client:get("/token")
  assert(res.status == 200)
  return client, res.body
end

local function test_a_form_field_or_a_header_carries_the_token()
  local client, token = session_with_token(make_app())
  assert(#token == 86, "the token is 64 bytes of base64url")
  local res = client:post("/form", { form = { name = "ada", csrf_token = token } })
  assert(res.status == 200 and res.body == "name=ada", res.body)
  res = client:post("/do", { body = "hi", content_type = "text/plain", headers = { ["X-CSRF-Token"] = token } })
  assert(res.status == 200 and res.body == "done:hi", res.body)
  res = client:put("/do", { headers = { ["x-csrf-token"] = token } })
  assert(res.body == "changed")
  assert(client:delete("/do", { headers = { ["X-CSRF-Token"] = token } }).status == 200)
  assert(client:patch("/do", { json = { a = 1 }, headers = { ["X-CSRF-Token"] = token } }).status == 200)
end

local function test_each_token_is_masked_differently_and_every_one_works()
  local app = make_app()
  local client, first = session_with_token(app)
  local second = client:get("/token").body
  assert(first ~= second, "a fresh mask for each call")
  for _, token in ipairs({ first, second }) do
    assert(client:post("/form", { form = { name = "x", csrf_token = token } }).status == 200)
  end
end

local function test_a_missing_or_wrong_token_is_refused()
  local client, token = session_with_token(make_app())
  assert(client:post("/form", { form = { name = "x" } }).status == 403, "no token")
  assert(client:post("/do").status == 403, "no body at all")
  assert(client:post("/form", { form = { name = "x", csrf_token = "" } }).status == 403)
  local other = Web.test_client(make_app())
  local stranger = other:get("/token").body
  assert(client:post("/form", { form = { name = "x", csrf_token = stranger } }).status == 403,
    "a token of another session")
  assert(client:put("/do", { headers = { ["X-CSRF-Token"] = stranger } }).status == 403)
  assert(client:delete("/do").status == 403)
  assert(client:request("FOO", "/do").status == 403, "an unknown method is unsafe")
  assert(client:post("/form", { form = { name = "x", csrf_token = token } }).status == 200)
end

local function test_a_token_altered_in_any_way_is_refused()
  local client, token = session_with_token(make_app())
  local function refused(text: string)
    local res = client:post("/form", { form = { name = "x", csrf_token = text } })
    assert(res.status == 403, "accepted: " .. text)
  end
  refused(token:sub(1, 85))
  refused(token .. "A")
  refused(token .. "=")
  refused(token:sub(1, 85) .. (if token:sub(86, 86) == "A" then "B" else "A" end))
  refused(token:sub(33, 86) .. token:sub(1, 32))
  refused(("A"):rep(86))
  refused(("!"):rep(86))
  refused(token:upper())
  refused(" " .. token)
  local flipped = token:sub(1, 40) .. (if token:sub(41, 41) == "A" then "B" else "A" end) .. token:sub(42)
  refused(flipped)
  local two = client:post("/do", { headers = { ["X-CSRF-Token"] = token .. ", " .. token } })
  assert(two.status == 403, "a repeated header is joined, and then it is no token")
  local dup = client:post("/form", { body = "name=x&csrf_token=" .. token .. "&csrf_token=" .. token,
    content_type = "application/x-www-form-urlencoded" })
  assert(dup.status == 403, "a field sent twice")
end

local function test_a_request_without_a_session_has_nothing_to_match()
  local app = make_app()
  local client, token = session_with_token(app)
  local fresh = Web.test_client(app)
  local res = fresh:post("/form", { form = { name = "x", csrf_token = token } })
  assert(res.status == 403, "a well-formed token and no session cookie")
  local loud = Web.test_client(app):post("/do")
  assert(loud.status == 403)
  assert(client:post("/form", { form = { name = "x", csrf_token = token } }).status == 200)
end

local function test_the_token_is_not_read_from_the_query_or_a_cookie()
  local client, token = session_with_token(make_app())
  assert(client:post("/do?csrf_token=" .. token).status == 403)
  assert(client:post("/do", { cookies = { csrf_token = token } }).status == 403)
  assert(client:post("/do", { json = { csrf_token = token } }).status == 403,
    "a JSON body takes the header alone")
end

local function test_safe_methods_pass_unless_the_route_registered_them()
  local client = Web.test_client(make_app())
  assert(client:get("/mutates").status == 200)
  assert(client:head("/mutates").status == 200)
  assert(client:options("/do").status == 204 or client:options("/do").status == 200, "automatic OPTIONS")
  assert(client:head("/head-only").status == 403, "a handler registered for HEAD can change state")
  assert(client:options("/opts-only").status == 403, "and one for OPTIONS")
  local with, own = session_with_token(make_app())
  assert(with:head("/head-only", { headers = { ["X-CSRF-Token"] = own } }).status == 200)
end

local function test_an_unsafe_request_from_another_origin_is_refused_even_with_the_token()
  local client, token = session_with_token(make_app())
  local function post(origin: string?, extra?: {string:string}): integer
    local headers = extra or {}
    if origin ~= nil then headers["Origin"] = origin end
    headers["X-CSRF-Token"] = token
    return client:post("/do", { headers = headers }).status
  end
  assert(post(SELF) == 200, "the request's own origin")
  assert(post("HTTP://TestServer") == 200, "in any case")
  assert(post("http://testserver:80") == 200, "a default port is none")
  assert(post(nil) == 200, "no Origin: not a browser")
  assert(post("https://evil.example") == 403)
  assert(post("https://testserver") == 403, "another scheme")
  assert(post("http://testserver:8080") == 403, "another port")
  assert(post("http://testserver.evil.example") == 403, "a longer name")
  assert(post("http://evil.example/testserver") == 403)
  assert(post("http://evil.example@testserver") == 403, "userinfo")
  assert(post("http://testserver/") == 403, "an Origin has no path")
  assert(post("null") == 403, "a sandboxed frame")
  assert(post("") == 403)
  assert(post(SELF .. ", https://evil.example") == 403, "two Origins")
  assert(post(SELF, { ["Sec-Fetch-Site"] = "cross-site" }) == 403, "the browser says cross-site")
  assert(post(nil, { ["Sec-Fetch-Site"] = "cross-site" }) == 403)
  assert(post(SELF, { ["Sec-Fetch-Site"] = "same-origin" }) == 200)
  assert(post(nil, { ["Sec-Fetch-Site"] = "none" }) == 200, "a typed URL")
  assert(post(nil, { ["Sec-Fetch-Site"] = "same-site" }) == 200, "a sibling subdomain, by default")
end

local function test_strict_same_site_refuses_a_sibling()
  local client, token = session_with_token(make_app({ strict_same_site = true }))
  local res = client:post("/do", { headers = { ["Sec-Fetch-Site"] = "same-site", ["X-CSRF-Token"] = token } })
  assert(res.status == 403)
  res = client:post("/do", { headers = { ["Sec-Fetch-Site"] = "same-origin", ["X-CSRF-Token"] = token } })
  assert(res.status == 200)
end

local function test_the_referer_stands_in_for_a_missing_origin()
  local client, token = session_with_token(make_app())
  local function post(referer: string): integer
    return client:post("/do", { headers = { ["Referer"] = referer, ["X-CSRF-Token"] = token } }).status
  end
  assert(post(SELF .. "/page?x=1#top") == 200)
  assert(post("https://evil.example/page") == 403)
  assert(post("http://testserver.evil.example/") == 403)
  assert(post("not a url") == 403, "a Referer that names no origin")
  assert(post("http://evil.example@testserver/") == 403)
  local res = client:post("/do", { headers = { ["Origin"] = SELF, ["Referer"] = "https://evil.example/",
    ["X-CSRF-Token"] = token } })
  assert(res.status == 200, "the Origin decides when there is one")
end

local function test_trusted_origins_pass_the_origin_layer_and_still_need_the_token()
  local app = make_app({ trusted_origins = { "https://partner.example:443", "null" } })
  local client, token = session_with_token(app)
  local function post(origin: string, with_token: boolean): integer
    local headers: mut {string:string} = { Origin = origin, ["Sec-Fetch-Site"] = "cross-site" }
    if with_token then headers["X-CSRF-Token"] = token end
    return client:post("/do", { headers = headers }).status
  end
  assert(post("https://partner.example", true) == 200)
  assert(post("https://partner.example", false) == 403, "a partner has no free pass from the token")
  assert(post("https://other.example", true) == 403)
  assert(post("null", true) == 200, "null, when listed")
  assert(Cors.trusted({ allow_origins = { "https://A.example", "*", "null", "http://b.example:80" } })[1] ==
      "https://a.example")
  assert(#Cors.trusted({ allow_origins = { "*", "null" } }) == 0, "neither * nor null is trusted for state changes")
  for _, bad in ipairs({ "*", "partner.example", "https://partner.example/x", "ftp://x", "" }) do
    local ok = pcall(Csrf.middleware, { trusted_origins = { bad } })
    assert(not ok, "accepted " .. bad)
  end
end

local function test_a_bearer_request_skips_the_token_but_basic_auth_does_not()
  local client = Web.test_client(make_app())
  assert(client:post("/do", { headers = { Authorization = "Bearer abc" } }).status == 200)
  assert(client:post("/do", { headers = { Authorization = "bearer abc" } }).status == 200)
  assert(client:post("/do", { headers = { Authorization = "Basic YTpi" } }).status == 403)
  assert(client:post("/do", { headers = { Authorization = "Bearer" } }).status == 403)
  assert(client:post("/do", { headers = { Authorization = "Bearer " } }).status == 403)
  local cross = client:post("/do", { headers = { Authorization = "Bearer abc", Origin = "https://evil.example" } })
  assert(cross.status == 403, "the Origin layer still applies")
  local strict = Web.test_client(make_app({ bearer_exempt = false }))
  assert(strict:post("/do", { headers = { Authorization = "Bearer abc" } }).status == 403)
end

local function test_exempt_and_the_two_layers_can_be_turned_off()
  local skipped = Web.test_client(make_app({ exempt = function(req: Web.Request): boolean
    return req.path == "/do"
  end }))
  assert(skipped:post("/do", { headers = { Origin = "https://evil.example" } }).status == 200)
  assert(skipped:post("/form", { form = { name = "x" } }).status == 403)

  local no_origin = Web.test_client(make_app({ origin_check = false }))
  local token = no_origin:get("/token").body
  local res = no_origin:post("/do", { headers = { Origin = "https://evil.example", ["X-CSRF-Token"] = token } })
  assert(res.status == 200)
  assert(no_origin:post("/do", { headers = { Origin = "https://evil.example" } }).status == 403,
    "the token layer stays")

  local no_token = Web.test_client(make_app({ token = false }))
  assert(no_token:post("/do", { headers = { Origin = SELF } }).status == 200)
  assert(no_token:post("/do", { headers = { Origin = "https://evil.example" } }).status == 403)
end

local function test_the_origin_layer_alone_needs_no_session()
  local app = Web.app{
    middleware = { Csrf.middleware{ token = false } },
    routes = { Web.post("/x", function(_req: Web.Request): Web.Response return Web.text("ok") end) },
  }
  local client = Web.test_client(app)
  assert(client:post("/x").status == 200)
  assert(client:post("/x", { headers = { Origin = "null" } }).status == 403)
  local bare = Web.app{ routes = { Web.get("/t", function(req: Web.Request): Web.Response
    return Web.text(Csrf.token(req))
  end) }, sink = { line = function(_self: Web.Sink, _text: string) end } }
  assert(Web.test_client(bare):get("/t").status == 500, "a token needs the session middleware")
end

local function test_regenerating_the_session_retires_every_token_seen_before()
  local app = make_app()
  local client, token = session_with_token(app)
  assert(client:post("/login", { headers = { ["X-CSRF-Token"] = token } }).status == 200)
  assert(client:post("/do", { headers = { ["X-CSRF-Token"] = token } }).status == 403,
    "the token of the page rendered before login")
  local fresh = client:get("/token").body
  assert(client:post("/do", { headers = { ["X-CSRF-Token"] = fresh } }).status == 200)
end

local function test_a_session_cookie_planted_before_login_carries_no_token_across()
  local app = make_app()
  local attacker, token = session_with_token(app)
  local victim = Web.test_client(app)
  victim.jar.session = attacker.jar.session
  assert(victim:post("/login", { headers = { ["X-CSRF-Token"] = token } }).status == 200)
  assert(attacker:post("/do", { headers = { ["X-CSRF-Token"] = token } }).status == 403,
    "the planted id is revoked, so the attacker's token has nothing to match")
  local after = victim:get("/token").body
  assert(victim:post("/do", { headers = { ["X-CSRF-Token"] = after } }).status == 200)
  assert(victim:post("/do", { headers = { ["X-CSRF-Token"] = token } }).status == 403,
    "and the victim's new secret is not the one the attacker saw")
end

local function test_the_refusal_is_a_403_that_says_why_without_the_token()
  lines.value = {}
  local client, token = session_with_token(make_app())
  local res = client:post("/do", { headers = { Origin = "https://evil.example\1" } })
  assert(res.status == 403)
  assert(res.body:find("another site", 1, true), res.body)
  local missing = client:post("/do")
  assert(missing.status == 403 and missing.body:find("security token", 1, true), missing.body)
  local htmx = client:post("/do", { headers = { ["HX-Request"] = "true" } })
  assert(htmx.status == 403 and htmx.body:find("reload the page", 1, true), htmx.body)
  assert(#lines.value >= 3 and lines.value[1]:find("csrf: refused POST /do (origin)", 1, true), lines.value[1])
  assert(not lines.value[1]:find("\1", 1, true), "a control byte of the client's is not written")
  for _, line in ipairs(lines.value) do assert(not line:find(token, 1, true)) end
  local with = client:post("/do", { headers = { ["X-CSRF-Token"] = token .. "x" } })
  assert(with.status == 403)
  for _, line in ipairs(lines.value) do
    assert(not line:find(token, 1, true), "the token is not logged")
  end
end

local function test_on_failure_gets_the_reason()
  local reasons: mut {string} = {}
  local client = Web.test_client(make_app({ on_failure = function(_req: Web.Request, why: string): Web.Response
    reasons[#reasons + 1] = why
    return Web.text("no", { status = 418 })
  end }))
  local token = client:get("/token").body
  assert(client:post("/do").status == 418)
  assert(client:post("/do", { headers = { Origin = "null", ["X-CSRF-Token"] = token } }).status == 418)
  assert(client:post("/do", { headers = { ["Sec-Fetch-Site"] = "cross-site" } }).status == 418)
  assert(client:post("/do", { headers = { Referer = "x" } }).status == 418)
  assert(table.concat(reasons, ",") == "token,origin,cross-site,referer", table.concat(reasons, ","))
end

local function test_the_field_the_meta_tag_and_the_header_object_carry_a_working_token()
  local client = Web.test_client(make_app())
  local field = client:get("/field").body
  local token = assert(field:match('^<form><input type="hidden" name="csrf_token" value="([%w_-]+)"></form>$'), field)
  assert(client:post("/form", { form = { name = "x", csrf_token = token } }).status == 200)
  local meta = client:get("/meta").body
  token = assert(meta:match('^<meta name="csrf%-token" content="([%w_-]+)">$'), meta)
  assert(client:post("/do", { headers = { ["X-CSRF-Token"] = token } }).status == 200)
  local json = client:get("/hx").body
  token = assert(json:match('^{"X%-CSRF%-Token":"([%w_-]+)"}$'), json)
  assert(client:post("/do", { headers = { ["X-CSRF-Token"] = token } }).status == 200)
end

local B <const> = "----csrf-boundary"
local TYPE <const> = "multipart/form-data; boundary=" .. B

local function part(name: string, value: string, filename?: string): string
  return "--" .. B .. '\r\nContent-Disposition: form-data; name="' .. name .. '"' ..
    (if filename ~= nil then ('; filename="' .. filename .. '"') else "" end) .. "\r\n\r\n" .. value .. "\r\n"
end

local function multipart(...: string): string
  return table.concat({ ... }) .. "--" .. B .. "--\r\n"
end

local function test_a_multipart_form_carries_the_token_as_its_first_part()
  local client, token = session_with_token(make_app())
  local good = multipart(part("csrf_token", token), part("name", "ada"), part("file", ("x"):rep(40000), "a.bin"))
  local res = client:post("/upload", { body = good, content_type = TYPE })
  assert(res.status == 200 and res.body == "name=ada files=1", res.body)
end

local function test_a_multipart_token_anywhere_but_first_is_refused_and_a_header_always_works()
  local client, token = session_with_token(make_app())
  local late = multipart(part("name", "ada"), part("csrf_token", token))
  assert(client:post("/upload", { body = late, content_type = TYPE }).status == 403, "second part")
  local file = multipart(part("csrf_token", token, "t.txt"), part("name", "ada"))
  assert(client:post("/upload", { body = file, content_type = TYPE }).status == 403, "a file part named csrf_token")
  local last = token:sub(1, 40) .. (if token:sub(41, 41) == "A" then "B" else "A" end) .. token:sub(42)
  local wrong = multipart(part("csrf_token", last), part("name", "ada"))
  assert(client:post("/upload", { body = wrong, content_type = TYPE }).status == 403)
  local none = multipart(part("name", "ada"))
  assert(client:post("/upload", { body = none, content_type = TYPE }).status == 403)
  local broken = "--" .. B .. "\r\nContent-Disposition: form-data; name=\"csrf_token\"\r\n\r\n" .. token
  assert(client:post("/upload", { body = broken, content_type = TYPE }).status == 403, "a part that never ends")
  assert(client:post("/upload", { body = "", content_type = TYPE }).status == 403)
  assert(client:post("/upload", { body = "junk", content_type = "multipart/form-data" }).status == 403, "no boundary")
  local res = client:post("/upload", { body = none, content_type = TYPE, headers = { ["X-CSRF-Token"] = token } })
  assert(res.status == 200 and res.body == "name=ada files=0", res.body)
  local huge = multipart(part("name", ("y"):rep(30000)), part("csrf_token", token))
  assert(client:post("/upload", { body = huge, content_type = TYPE }).status == 403,
    "a token behind more than the peek reads is not looked for")
end

local function test_a_cookieless_post_is_refused_before_its_body_is_read()
  local read = { value = 0 }
  local app = make_app({ exempt = function(req: Web.Request): boolean
    local inner = req.raw.body
    req.raw.body = { read = function(_self: Stream.Reader, max_bytes?: integer): string?, string
      read.value = read.value + 1
      return inner:read(max_bytes)
    end, close = function(_self: Stream.Reader): boolean, string
      return inner:close()
    end }
    return false
  end })
  local _, token = session_with_token(app)
  local body = multipart(part("csrf_token", token), part("file", ("x"):rep(100), "a.bin"))
  local res = Web.test_client(app):post("/upload", { body = body, content_type = TYPE })
  assert(res.status == 403)
  local form = Web.test_client(app):post("/form", { body = "csrf_token=" .. token,
    content_type = "application/x-www-form-urlencoded" })
  assert(form.status == 403)
  assert(read.value == 0, "no secret, no read: " .. read.value)
end

local function test_a_big_urlencoded_form_carries_its_token_within_the_peek()
  local client, token = session_with_token(make_app())
  local pad = ("y"):rep(70000)
  local FORM <const> = "application/x-www-form-urlencoded"
  local body = "a=1&csrf_token=" .. token .. "&pad=" .. pad
  local res = client:post("/do", { body = body, content_type = FORM })
  assert(res.status == 200 and res.body == "done:" .. body, "the whole body reaches the handler")
  local behind = client:post("/do", { body = "pad=" .. pad .. "&csrf_token=" .. token, content_type = FORM })
  assert(behind.status == 403, "a field behind the peek is not looked for")
  local twice = client:post("/do", { body = "csrf_token=" .. token .. "&csrf_token=" .. token, content_type = FORM })
  assert(twice.status == 403, "a repeated field")
  local other = client:post("/do", { body = "xcsrf_token=" .. token, content_type = FORM })
  assert(other.status == 403, "another name")
end

local function test_a_urlencoded_body_is_still_there_for_the_handler()
  local client, token = session_with_token(make_app())
  local res = client:post("/form", { body = "name=grace&csrf_token=" .. token,
    content_type = "application/x-www-form-urlencoded" })
  assert(res.status == 200 and res.body == "name=grace", res.body)
  local other = client:post("/form", { body = "name=grace", content_type = "text/plain" })
  assert(other.status == 403)
end
