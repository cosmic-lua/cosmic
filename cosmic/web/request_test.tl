local Net = require("cosmic.net")
local Server = require("cosmic.http.server")
local Stream = require("cosmic.stream")
local Web = require("cosmic.web")

--- An app with one route that records the request it was given.
local function recording(spec?: Web.AppSpec): Web.App, {Web.Request}
  local seen: {Web.Request} = {}
  local routes: {Web.Route} = {
    Web.route({ "GET", "POST" }, "/items/:id", function(req: Web.Request): Web.Response
      seen[#seen + 1] = req
      return Web.text("ok")
    end),
  }
  local made: Web.AppSpec = spec or {}
  made.routes = routes
  return Web.app(made), seen
end

local function test_a_handler_sees_the_canonical_path_params_and_route()
  local app, seen = recording()
  local client = Web.test_client(app)
  assert(client:get("/items/a%7eb?x=1&y=2").status == 200)
  local req = seen[1]
  assert(req.method == "GET" and req.path == "/items/a~b" and req.query_string == "x=1&y=2")
  assert(#req.segments == 2 and req.segments[2] == "a~b")
  assert(req.params.id == "a~b" and req.mount_path == "")
  assert(req.route.pattern == "/items/:id" and req.route.methods[1] == "GET")
  assert(req.app == app and req.scheme == "http" and req.host == "testserver")
  assert(req.client.host == "127.0.0.1")
end

local function test_header_reads_a_name_in_any_case()
  local app, seen = recording()
  Web.test_client(app):get("/items/1", { headers = { ["X-Thing"] = "yes" } })
  assert(seen[1]:header("x-thing") == "yes" and seen[1]:header("X-THING") == "yes")
  assert(seen[1]:header("x-none") == nil)
end

local function test_the_body_is_read_once_and_put_back()
  local app, seen = recording()
  Web.test_client(app):post("/items/1", { body = "héllo", content_type = "text/plain" })
  local req = seen[1]
  assert(req:bytes() == "héllo" and req:text() == "héllo")
  assert(req:bytes() == "héllo", "a second read returns the kept bytes")
  assert(Stream.read_all(req.raw.body) == "héllo", "raw.body reads them again")
end

local function test_text_refuses_a_body_that_is_not_utf8()
  local app, seen = recording()
  Web.test_client(app):post("/items/1", { body = "\xff\xfe" })
  local req = seen[1]
  assert(req:bytes() == "\xff\xfe")
  local text, why = req:text()
  assert(text == nil and why:find("UTF-8", 1, true), why)
end

local function test_a_failed_body_read_answers_nil_and_why()
  local req: Web.Request = nil
  local app = Web.app{ routes = { Web.post("/", function(r: Web.Request): Web.Response
    req = r
    return Web.text("ok")
  end) } }
  local broken: Stream.Reader = {
    read = function(_self: Stream.Reader, _max?: integer): string | nil, string
      return nil, "http: the body is over the limit"
    end,
    close = function(_self: Stream.Reader): boolean, string return true, "" end,
  }
  local raw: Server.Request = { method = "POST", target = "/", path = "/", query = "", version = "HTTP/1.1",
    headers = { host = "x" }, body = broken, length = 5 }
  assert(app.handle(raw).status == 200)
  local data, why = req:bytes()
  assert(data == nil and why:find("over the limit", 1, true), why)
end

local function test_query_decodes_once_and_refuses_a_malformed_escape()
  local app, seen = recording()
  local client = Web.test_client(app)
  client:get("/items/1?a=1&a=2&b=x+y")
  local query = assert(seen[1]:query())
  assert(query.by_name.a[2] == "2" and query.by_name.b[1] == "x y")
  assert(seen[1]:query() == query, "the decode is kept")
  client:get("/items/1?a=%zz")
  local bad, why = seen[2]:query()
  assert(bad == nil and why:find("url:", 1, true), why)
end

local function test_accepts_picks_the_best_offer()
  local app, seen = recording()
  Web.test_client(app):get("/items/1", { headers = { accept = "application/json;q=0.9, text/html" } })
  assert(seen[1]:accepts({ "application/json", "text/html" }) == "text/html")
  assert(seen[1]:accepts({ "image/png" }) == nil)
end

local function test_typed_keys_carry_a_value_per_request()
  local COUNT: Web.Key<integer> = Web.key("count")
  local NAME: Web.Key<string> = Web.key("count")
  local app, seen = recording()
  Web.test_client(app):get("/items/1")
  local req = seen[1]
  assert(req:get(COUNT) == nil)
  req:set(COUNT, 3)
  req:set(NAME, "three")
  assert(req:get(COUNT) == 3, "two keys of one name are two keys")
  assert(req:get(NAME) == "three")
  Web.test_client(app):get("/items/2")
  assert(seen[2]:get(COUNT) == nil, "another request has its own")
  local ok = pcall(Web.key, "")
  assert(not ok)
end

local function test_url_for_resolves_a_name_from_the_request()
  local app, seen = recording()
  local named = Web.app{ routes = { Web.get("/items/:id", function(r: Web.Request): Web.Response
    seen[#seen + 1] = r
    return Web.text("ok")
  end, { name = "item" }) } }
  Web.test_client(named):get("/items/1")
  assert(seen[1]:url_for("item", { id = 42 }, { v = "2" }) == "/items/42?v=2")
  assert(app ~= nil)
end

local function test_client_info_ignores_forwarded_headers_unless_the_proxy_is_trusted()
  local app, seen = recording()
  local headers = { ["x-forwarded-for"] = "6.6.6.6, 203.0.113.9", ["x-forwarded-proto"] = "https",
    ["x-forwarded-host"] = "app.example.com" }
  Web.test_client(app):get("/items/1", { headers = headers })
  assert(seen[1].client.host == "127.0.0.1" and seen[1].scheme == "http" and seen[1].host == "testserver")
  local trusting, trusted_seen = recording({ trusted_proxy = true })
  Web.test_client(trusting):get("/items/1", { headers = headers })
  local req = trusted_seen[1]
  assert(req.client.host == "203.0.113.9" and req.client.port == nil, "the last entry is the proxy's")
  assert(req.scheme == "https" and req.host == "app.example.com")
  Web.test_client(trusting):get("/items/1", { headers = { ["x-forwarded-for"] = "not an address",
    ["x-forwarded-proto"] = "gopher" } })
  assert(trusted_seen[2].client.host == "127.0.0.1" and trusted_seen[2].scheme == "http")
end

local function test_a_connection_without_a_peer_has_no_client()
  local seen: Web.Request = nil
  local app = Web.app{ routes = { Web.get("/", function(r: Web.Request): Web.Response
    seen = r
    return Web.text("ok")
  end) } }
  local raw: Server.Request = { method = "GET", target = "/", path = "/", query = "", version = "HTTP/1.1",
    headers = { host = "x" }, body = Stream.from_string(""), length = 0 }
  assert(app.handle(raw).status == 200 and seen.client == nil)
  local unix: Server.Request = { method = "GET", target = "/", path = "/", query = "", version = "HTTP/1.1",
    headers = {}, body = Stream.from_string(""), length = 0, peer = Net.unix("/tmp/x") }
  assert(app.handle(unix).status == 200 and seen.client == nil and seen.host == nil)
end

local function test_base_url_needs_trusted_hosts()
  local app, seen = recording()
  Web.test_client(app):get("/items/1")
  local none, why = seen[1]:base_url()
  assert(none == nil and why:find("trusted_hosts", 1, true), why)
  local trusting, trusted_seen = recording({ trusted_hosts = { "testserver" } })
  Web.test_client(trusting):get("/items/1")
  assert(trusted_seen[1]:base_url() == "http://testserver")
end
