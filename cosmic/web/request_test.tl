local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local Server = require("cosmic.http.server")
local Stream = require("cosmic.stream")
local Web = require("cosmic.web")

--- An app with one route that records the request it was given.
local function recording(spec?: Web.AppSpec): Web.App, mut {Web.Request}
  local seen: mut {Web.Request} = {}
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
  local req = assert(seen[1], "expected seen[1]")
  assert(req.method == "GET" and req.path == "/items/a~b" and req.query_string == "x=1&y=2")
  assert(#req.segments == 2 and req.segments[2] == "a~b")
  assert(req.params.id == "a~b" and req.mount_path == "")
  local route = assert(req.route)
  assert(route.pattern == "/items/:id" and route.methods[1] == "GET")
  assert(req.app == app and req.scheme == "http" and req.host == "testserver")
  assert(assert(req.client).host == "127.0.0.1")
end

local function test_header_reads_a_name_in_any_case()
  local app, seen = recording()
  Web.test_client(app):get("/items/1", { headers = { ["X-Thing"] = "yes" } })
  local seen_1 = assert(seen[1], "expected seen[1]")
  assert(seen_1:header("x-thing") == "yes" and seen_1:header("X-THING") == "yes")
  assert(seen_1:header("x-none") == nil)
end

local function test_the_body_is_read_once_and_put_back()
  local app, seen = recording()
  Web.test_client(app):post("/items/1", { body = "héllo", content_type = "text/plain" })
  local req = assert(seen[1], "expected seen[1]")
  assert(req:bytes() == "héllo" and req:text() == "héllo")
  assert(req:bytes() == "héllo", "a second read returns the kept bytes")
  assert(Stream.read_all(req.raw.body) == "héllo", "raw.body reads them again")
end

local function test_text_refuses_a_body_that_is_not_utf8()
  local app, seen = recording()
  Web.test_client(app):post("/items/1", { body = "\xff\xfe" })
  local req = assert(seen[1], "expected seen[1]")
  assert(req:bytes() == "\xff\xfe")
  local text, why = req:text()
  assert(text == nil and why:find("UTF-8", 1, true) ~= nil, why)
end

local function test_a_failed_body_read_answers_nil_and_why()
  local req: Web.Request? = nil
  local app = Web.app{ routes = { Web.post("/", function(r: Web.Request): Web.Response
    req = r
    return Web.text("ok")
  end) } }
  local broken: Stream.Reader = {
    read = function(_self: Stream.Reader, _max?: integer): string?, string
      return nil, "http: the body is over the limit"
    end,
    close = function(_self: Stream.Reader): boolean, string return true, "" end,
  }
  local raw: Server.Request = { method = "POST", target = "/", path = "/", query = "", version = "HTTP/1.1",
    headers = { host = "x" }, body = broken, length = 5 }
  assert(app.handle(raw).status == 200)
  local data, why = assert(req, "the handler never ran"):bytes()
  assert(data == nil and why:find("over the limit", 1, true) ~= nil, why)
end

local function test_query_decodes_once_and_refuses_a_malformed_escape()
  local app, seen = recording()
  local client = Web.test_client(app)
  client:get("/items/1?a=1&a=2&b=x+y")
  local seen_1 = assert(seen[1], "expected seen[1]")
  local query = assert(seen_1:query())
  assert(query.by_name.a[2] == "2" and query.by_name.b[1] == "x y")
  assert(seen_1:query() == query, "the decode is kept")
  client:get("/items/1?a=%zz")
  local seen_2 = assert(seen[2], "expected seen[2]")
  local bad, why = seen_2:query()
  assert(bad == nil and why:find("url:", 1, true) ~= nil, why)
end

local function test_accepts_picks_the_best_offer()
  local app, seen = recording()
  Web.test_client(app):get("/items/1", { headers = { accept = "application/json;q=0.9, text/html" } })
  local seen_1 = assert(seen[1], "expected seen[1]")
  assert(seen_1:accepts({ "application/json", "text/html" }) == "text/html")
  assert(seen_1:accepts({ "image/png" }) == nil)
end

local function test_typed_keys_carry_a_value_per_request()
  local COUNT: Web.Key<integer> = Web.key("count")
  local NAME: Web.Key<string> = Web.key("count")
  local app, seen = recording()
  Web.test_client(app):get("/items/1")
  local req = assert(seen[1], "expected seen[1]")
  assert(req:get(COUNT) == nil)
  req:set(COUNT, 3)
  req:set(NAME, "three")
  assert(req:get(COUNT) == 3, "two keys of one name are two keys")
  assert(req:get(NAME) == "three")
  Web.test_client(app):get("/items/2")
  local seen_2 = assert(seen[2], "expected seen[2]")
  assert(seen_2:get(COUNT) == nil, "another request has its own")
  local ok = pcall(Web.key, "")
  assert(not ok)
end

local function test_url_for_resolves_a_name_from_the_request()
  local _, seen = recording()
  local named = Web.app{ routes = { Web.get("/items/:id", function(r: Web.Request): Web.Response
    seen[#seen + 1] = r
    return Web.text("ok")
  end, { name = "item" }) } }
  Web.test_client(named):get("/items/1")
  local seen_1 = assert(seen[1], "expected seen[1]")
  assert(seen_1:url_for("item", { id = 42 }, { v = "2" }) == "/items/42?v=2")
end

local function test_client_info_ignores_forwarded_headers_unless_the_proxy_is_trusted()
  local app, seen = recording()
  local headers = { ["x-forwarded-for"] = "6.6.6.6, 203.0.113.9", ["x-forwarded-proto"] = "https",
    ["x-forwarded-host"] = "app.example.com" }
  Web.test_client(app):get("/items/1", { headers = headers })
  local seen_1 = assert(seen[1], "expected seen[1]")
  assert(assert(seen_1.client).host == "127.0.0.1" and seen_1.scheme == "http" and seen_1.host == "testserver")
  local trusting, trusted_seen = recording({ trusted_proxy = true })
  Web.test_client(trusting):get("/items/1", { headers = headers })
  local req = assert(trusted_seen[1], "expected trusted_seen[1]")
  assert(assert(req.client).host == "203.0.113.9" and assert(req.client).port == nil, "the last entry is the proxy's")
  assert(req.scheme == "https" and req.host == "app.example.com")
  Web.test_client(trusting):get("/items/1", { headers = { ["x-forwarded-for"] = "not an address",
    ["x-forwarded-proto"] = "gopher" } })
  local trusted_seen_2 = assert(trusted_seen[2], "expected trusted_seen[2]")
  assert(assert(trusted_seen_2.client).host == "127.0.0.1" and trusted_seen_2.scheme == "http")
end

local function test_a_connection_without_a_peer_has_no_client()
  local seen: Web.Request? = nil
  local app = Web.app{ routes = { Web.get("/", function(r: Web.Request): Web.Response
    seen = r
    return Web.text("ok")
  end) } }
  local raw: Server.Request = { method = "GET", target = "/", path = "/", query = "", version = "HTTP/1.1",
    headers = { host = "x" }, body = Stream.from_string(""), length = 0 }
  assert(app.handle(raw).status == 200 and assert(seen, "the handler never ran").client == nil)
  local unix: Server.Request = { method = "GET", target = "/", path = "/", query = "", version = "HTTP/1.1",
    headers = {}, body = Stream.from_string(""), length = 0, peer = Net.unix("/tmp/x") }
  assert(app.handle(unix).status == 200)
  local over_unix = assert(seen, "the handler never ran")
  assert(over_unix.client == nil and over_unix.host == nil)
end

local function test_base_url_needs_trusted_hosts()
  local app, seen = recording()
  Web.test_client(app):get("/items/1")
  local seen_1 = assert(seen[1], "expected seen[1]")
  local none, why = seen_1:base_url()
  assert(none == nil and why:find("trusted_hosts", 1, true) ~= nil, why)
  local trusting, trusted_seen = recording({ trusted_hosts = { "testserver" } })
  Web.test_client(trusting):get("/items/1")
  local trusted_seen_1 = assert(trusted_seen[1], "expected trusted_seen[1]")
  assert(trusted_seen_1:base_url() == "http://testserver")
end

local function test_a_host_header_is_valid_whole_or_it_is_a_400()
  local app, seen = recording({ trusted_hosts = { "good.com" } })
  local client = Web.test_client(app)
  local bad: {string} = {
    "good.com:@evil.com", "good.com:x/y", "good.com:80\\@evil.com", "good.com@evil.com", "good.com:",
    "good.com:80:80", "good.com:65536", "good.com:123456", "good.com/x", "good.com evil.com",
    "good.com#x", "good.com?x", "[::1]@evil.com", "[good.com]", "[::1", "[::g]", "", "good.com\\evil.com",
  }
  for _, host in ipairs(bad) do
    local res = client:get("/items/1", { headers = { host = host } })
    assert(res.status == 400, ("%q answered %d"):format(host, res.status))
  end
  assert(#seen == 0, "no handler saw a request with a bad host")
  assert(client:get("/items/1", { headers = { host = "GOOD.com:65535" } }).status == 200)
  local seen_1 = assert(seen[1], "expected seen[1]")
  assert(seen_1:base_url() == "http://good.com:65535")
  assert(client:get("/items/1", { headers = { host = "good.com" } }).status == 200)
  local seen_2 = assert(seen[2], "expected seen[2]")
  assert(seen_2:base_url() == "http://good.com")
  assert(client:get("/items/1", { headers = { host = "good.com:080" } }).status == 200)
  local seen_3 = assert(seen[3], "expected seen[3]")
  assert(seen_3:base_url() == "http://good.com:80", "a port is written as a number")
end

local function test_base_url_is_made_from_the_validated_host_and_port_alone()
  local app, seen = recording({ trusted_hosts = { "[::1]", "10.0.0.1" }, trusted_proxy = true })
  local client = Web.test_client(app)
  assert(client:get("/items/1", { headers = { host = "[::1]:8080" } }).status == 200)
  local seen_1 = assert(seen[1], "expected seen[1]")
  assert(seen_1:base_url() == "http://[::1]:8080")
  assert(client:get("/items/1", { headers = { host = "10.0.0.1" } }).status == 200)
  local seen_2 = assert(seen[2], "expected seen[2]")
  assert(seen_2:base_url() == "http://10.0.0.1")
  local forwarded = { ["x-forwarded-proto"] = "https", ["x-forwarded-host"] = "10.0.0.1:443" }
  assert(client:get("/items/1", { headers = forwarded }).status == 200)
  local seen_3 = assert(seen[3], "expected seen[3]")
  assert(seen_3:base_url() == "https://10.0.0.1:443")
  for _, host in ipairs({ "10.0.0.1:@evil.com", "[::1]@evil.com", "10.0.0.1:x/y", "10.0.0.1:80\\@evil.com" }) do
    local attack = { ["x-forwarded-host"] = host }
    assert(client:get("/items/1", { headers = attack }).status == 400, host .. " by X-Forwarded-Host")
  end
  assert(#seen == 3)
end

local function test_a_trusted_host_with_a_port_or_no_host_raises_when_the_app_is_made()
  for _, entry in ipairs({ "good.com:8080", "good.com:", "good.com@evil.com", "", "a b", "[::1]:80" }) do
    local ok, err = pcall(Web.app, { routes = {}, trusted_hosts = { entry } })
    assert(not ok and tostring(err):find("trusted_hosts", 1, true) ~= nil and
        tostring(err):find("without a port", 1, true) ~= nil, entry .. ": " .. tostring(err))
  end
  local app, seen = recording({ trusted_hosts = { "Good.COM" } })
  local client = Web.test_client(app)
  assert(client:get("/items/1", { headers = { host = "good.com:9999" } }).status == 200, "any port matches")
  local seen_1 = assert(seen[1], "expected seen[1]")
  assert(seen_1:base_url() == "http://good.com:9999")
end

local function test_a_failed_body_read_is_remembered()
  local reads: integer = 0
  local seen: Web.Request? = nil
  local app = Web.app{ routes = { Web.post("/", function(r: Web.Request): Web.Response
    seen = r
    return Web.text("ok")
  end) } }
  local body: Stream.Reader = {
    read = function(_self: Stream.Reader, _max?: integer): string?, string
      reads = reads + 1
      return nil, "the client went away"
    end,
    close = function(_self: Stream.Reader): boolean, string return true, "" end,
  }
  local raw: Server.Request = { method = "POST", target = "/", path = "/", query = "", version = "HTTP/1.1",
    headers = { host = "x" }, body = body, length = 5 }
  assert(app.handle(raw).status == 200)
  local request = assert(seen, "the handler never ran")
  local first, first_why = request:bytes()
  assert(first == nil and first_why == "the client went away")
  local reads_after_first = reads
  local second, second_why = request:bytes()
  assert(second == nil and second_why == first_why, "the same failure again")
  local third, third_why = request:text()
  assert(third == nil and third_why == first_why)
  assert(reads == reads_after_first, "the spent reader is not read again")
end

local function test_a_forwarded_client_is_an_address_or_the_peer()
  local app, seen = recording({ trusted_proxy = true })
  local client = Web.test_client(app)
  local record Forwarded
    header: string
    host: string
  end
  local cases: {Forwarded} = {
    { header = "203.0.113.9", host = "203.0.113.9" },
    { header = "2001:db8::1", host = "2001:db8::1" },
    { header = "::1", host = "::1" },
    { header = "999.1.1.1", host = "127.0.0.1" },
    { header = "1.2.3.4.5", host = "127.0.0.1" },
    { header = "1.2.3", host = "127.0.0.1" },
    { header = "abc", host = "127.0.0.1" },
    { header = "1.2.3.4:80", host = "127.0.0.1" },
    { header = "dead:beef", host = "127.0.0.1" },
    { header = ":::", host = "127.0.0.1" },
    { header = "...", host = "127.0.0.1" },
    { header = "1:2:3:4:5:6:7:8:9", host = "127.0.0.1" },
  }
  for i, case in ipairs(cases) do
    client:get("/items/1", { headers = { ["x-forwarded-for"] = case.header } })
    local seen_i = assert(seen[i], "expected seen[i]")
    assert(assert(seen_i.client).host == case.host, ("%q gave %s"):format(case.header, assert(seen_i.client).host))
  end
end

local function test_blanks_in_a_forwarding_header_cost_time_linear_in_their_run()
  local trusting, seen = recording({ trusted_proxy = true })
  local client = Web.test_client(trusting)
  local start = Clock.monotonic_ns()
  client:get("/items/1", { headers = { ["x-forwarded-for"] = "6.6.6.6, 203.0.113.9" .. (" "):rep(60000) .. "y" } })
  client:get("/items/1", { headers = { ["x-forwarded-for"] = ("a"):rep(60000) .. "," .. ("b"):rep(60000) } })
  local took = Clock.monotonic_ns() - start
  local seen_1 = assert(seen[1], "expected seen[1]")
  assert(assert(seen_1.client).host == "127.0.0.1", "an entry with junk in it is no address")
  assert(took < Clock.seconds(1), "took " .. tostring(took // 1000000) .. " ms")
  client:get("/items/1", { headers = { ["x-forwarded-for"] = "6.6.6.6,  203.0.113.9  " } })
  local seen_3 = assert(seen[3], "expected seen[3]")
  assert(assert(seen_3.client).host == "203.0.113.9")
end
