local Html = require("cosmic.html")
local Url = require("cosmic.url")
local Web = require("cosmic.web")
local Test = require("cosmic.test")

local function ok(_req: Web.Request): Web.Response
  return Web.text("ok")
end

--- The route table of a few patterns, each named after itself.
local function table_of(patterns: {string}): Web.Router
  local routes: mut {Web.Route} = {}
  for _, pattern in ipairs(patterns) do
    routes[#routes + 1] = Web.get(pattern, ok, { name = pattern })
  end
  return Web.router(routes)
end

--- The pattern `router` matches `path` to for a GET, or the kind it fails with.
local function route_of(router: Web.Router, path: string, method?: string): string
  local outcome = router:match(method or "GET", path)
  if outcome.kind == "match" then return assert(outcome.route).pattern end
  return outcome.kind
end

local function test_a_pattern_binds_literals_params_and_the_rest()
  local router = table_of({ "/", "/about", "/items/:id", "/items/:id/tags/:tag", "/static/*path" })
  assert(route_of(router, "/") == "/" and route_of(router, "/about") == "/about")
  local item = router:match("GET", "/items/a%20b")
  assert(item.kind == "match" and assert(item.params).id == "a b" and assert(item.route).name == "/items/:id")
  local tag = router:match("GET", "/items/7/tags/x")
  assert(assert(tag.params).id == "7" and assert(tag.params).tag == "x")
  assert(route_of(router, "/items") == "not_found" and route_of(router, "/items/7/tags") == "not_found")
  assert(route_of(router, "/About") == "not_found", "literals are case-sensitive")
end

local function test_the_rest_takes_zero_or_more_decoded_segments_joined()
  local router = table_of({ "/static/*path" })
  assert(assert(router:match("GET", "/static/css/app%20x.css").params).path == "css/app x.css")
  assert(assert(router:match("GET", "/static/a").params).path == "a")
  assert(assert(router:match("GET", "/static").params).path == "")
  assert(assert(router:match("GET", "/static/").params).path == "", "the rest swallows the slash: no redirect")
  assert(route_of(router, "/other") == "not_found")
end

local function test_the_most_specific_route_wins_whatever_the_order()
  local patterns = { "/items/new", "/items/:id", "/items/*rest", "/:any/new" }
  for _ = 1, 4 do
    local router = table_of(patterns)
    assert(route_of(router, "/items/new") == "/items/new")
    assert(route_of(router, "/items/7") == "/items/:id")
    assert(route_of(router, "/items/7/x") == "/items/*rest")
    assert(route_of(router, "/other/new") == "/:any/new")
    local first = table.remove(patterns, 1)
    table.insert(patterns, first)
  end
end

local function test_a_branch_without_a_route_for_the_rest_falls_back()
  local router = table_of({ "/a/b/c", "/a/:x/d", "/a/*rest" })
  assert(route_of(router, "/a/b/c") == "/a/b/c")
  assert(route_of(router, "/a/b/d") == "/a/:x/d", "literal b has no d: the parameter takes it")
  assert(route_of(router, "/a/b/e") == "/a/*rest")
  assert(route_of(router, "/a/b") == "/a/*rest")
end

local function test_a_method_other_than_the_routes_is_405_with_a_sorted_allow()
  local router = Web.router({
    Web.get("/x", ok), Web.post("/x", ok), Web.route({ "PUT", "DELETE" }, "/x/:id", ok),
  })
  local outcome = router:match("PATCH", "/x")
  assert(outcome.kind == "not_allowed" and outcome.allow == "GET, HEAD, OPTIONS, POST", outcome.allow)
  assert(router:match("POST", "/x/1").allow == "DELETE, OPTIONS, PUT")
  assert(route_of(router, "/nope", "PATCH") == "not_found", "a path that matches nothing is 404")
end

local function test_head_uses_the_get_route_unless_one_is_declared()
  local router = Web.router({ Web.get("/a", ok, { name = "a" }), Web.get("/b", ok), Web.route("HEAD", "/b", ok, { name = "b" }) })
  assert(assert(router:match("HEAD", "/a").route).name == "a")
  assert(assert(router:match("HEAD", "/b").route).methods[1] == "HEAD")
  local post_only = Web.router({ Web.post("/p", ok) })
  assert(post_only:match("HEAD", "/p").kind == "not_allowed")
  assert(post_only:match("HEAD", "/p").allow == "OPTIONS, POST")
end

local function test_options_is_answered_with_allow_unless_a_route_declares_it()
  local router = Web.router({ Web.get("/a", ok), Web.route("OPTIONS", "/b", ok, { name = "b" }) })
  local auto = router:match("OPTIONS", "/a")
  assert(auto.kind == "options" and auto.allow == "GET, HEAD, OPTIONS")
  assert(assert(router:match("OPTIONS", "/b").route).name == "b")
  assert(route_of(router, "/missing", "OPTIONS") == "not_found")
  local star = router:match("OPTIONS", "*")
  assert(star.kind == "options" and star.allow == "GET, HEAD, OPTIONS", star.allow)
  assert(router:match("GET", "*").kind == "bad_path")
end

local function test_a_trailing_slash_is_a_308_to_the_routes_spelling()
  local router = Web.router({ Web.get("/items", ok), Web.get("/docs/", ok, { name = "docs" }),
    Web.get("/files/*rest", ok) })
  local plain = router:match("GET", "/items/")
  assert(plain.kind == "redirect" and plain.location == "/items")
  local docs = router:match("GET", "/docs")
  assert(docs.kind == "redirect" and docs.location == "/docs/")
  assert(route_of(router, "/docs/") == "/docs/" and route_of(router, "/items") == "/items")
  assert(route_of(router, "/files/") == "/files/*rest" and route_of(router, "/files") == "/files/*rest")
  assert(route_of(router, "/nothing/") == "not_found", "only when the other spelling matches")
  assert(router:match("POST", "/items/").kind == "not_allowed", "a method nobody answers is 405 first")
end

local function test_strict_policy_has_no_redirect()
  local router = Web.router({ Web.get("/items", ok), Web.get("/docs/", ok) }, { trailing_slash = "strict" })
  assert(route_of(router, "/items/") == "not_found" and route_of(router, "/docs") == "not_found")
  assert(route_of(router, "/items") == "/items" and route_of(router, "/docs/") == "/docs/")
  local loose: any = { trailing_slash = "loose" }
  assert(Test.raises(function() Web.router({}, loose as Web.RouterOptions) end):find("trailing_slash", 1, true))
end

local function test_a_noncanonical_path_is_redirected_to_its_canonical_form()
  local router = table_of({ "/a/b", "/evil.com/" })
  for path, location in pairs({ ["//a/b"] = "/a/b", ["/a//b"] = "/a/b", ["/a/./b"] = "/a/b",
      ["/a/%2e/b"] = "/a/b", ["/./a/b"] = "/a/b", ["/a/b/."] = "/a/b", ["///"] = "/",
      ["//evil.com/"] = "/evil.com/", ["//evil.com//"] = "/evil.com/", ["/a/b//"] = "/a/b/" }) do
    local outcome = router:match("GET", path)
    assert(outcome.kind == "redirect" and outcome.location == location, path .. " -> " .. tostring(outcome.location))
  end
end

local function test_a_path_that_climbs_or_hides_a_separator_is_a_bad_request()
  local router = table_of({ "/a/b" })
  for _, path in ipairs({ "/a/../b", "/a/%2e%2e/b", "/a/%2E%2e", "/..", "/a%2fb", "/a%2Fb", "/a%00b",
      "/a/%zz", "/a/%" }) do
    local outcome = router:match("GET", path)
    assert(outcome.kind == "bad_path" and assert(outcome.detail):find("url:", 1, true) ~= nil, path .. ": " .. outcome.kind)
  end
  assert(router:match("GET", "a/b").kind == "bad_path")
  assert(router:match("GET", "").kind == "bad_path")
end

local function test_percent_variants_of_one_name_match_without_a_redirect()
  local router = table_of({ "/a~b", "/x y" })
  assert(route_of(router, "/a%7eb") == "/a~b" and route_of(router, "/a~b") == "/a~b")
  assert(route_of(router, "/x%20y") == "/x y")
  assert(route_of(router, "/%61~b") == "/a~b")
end

local function test_canonical_is_idempotent_and_always_one_leading_slash()
  local Router = require("cosmic.web.router")
  for _, path in ipairs({ "/", "//", "/a", "/a/", "//a//b//", "/%2e/./x%20y/", "/é/ü" }) do
    local canon = assert(Router.canonical(path))
    assert(canon.path:sub(1, 1) == "/" and canon.path:sub(2, 2) ~= "/", path)
    local again = assert(Router.canonical(canon.path))
    assert(again.path == canon.path and not again.changed, path)
  end
end

local function test_a_mount_hands_the_rest_to_its_routes_and_answers_its_own_404()
  local api = {
    Web.get("/", ok, { name = "root" }), Web.get("/items/:id", ok, { name = "item" }),
    Web.mount("/v1", { Web.get("/ping", ok, { name = "ping" }) }, { name = "v1" }),
  }
  local router = Web.router({ Web.get("/home", ok), Web.mount("/api", api, { name = "api" }) })
  local item = router:match("GET", "/api/items/7")
  assert(item.kind == "match" and assert(item.params).id == "7" and assert(item.route).name == "api:item")
  assert(assert(item.route).pattern == "/api/items/:id")
  assert(assert(router:match("GET", "/api").route).name == "api:root")
  assert(assert(router:match("GET", "/api/v1/ping").route).pattern == "/api/v1/ping")
  assert(assert(router:match("GET", "/api/v1/ping").route).name == "api:v1:ping")
  assert(route_of(router, "/api/nope") == "not_found", "no fallthrough from a mount")
  assert(router:match("POST", "/api/items/7").kind == "not_allowed")
  assert(route_of(router, "/api/") == "redirect" and router:match("GET", "/api/").location == "/api")
  assert(route_of(router, "/home") == "/home")
end

local function test_a_mount_of_a_handler_takes_every_method_and_path_below()
  local router = Web.router({ Web.mount_handler("/legacy", ok, { name = "legacy" }) })
  for _, method in ipairs({ "GET", "POST", "DELETE" }) do
    local outcome = router:match(method, "/legacy/a/b")
    assert(outcome.kind == "match" and assert(outcome.route).pattern == "/legacy/*" and outcome.mount_path == "/legacy")
  end
  assert(router:match("GET", "/legacy").kind == "match")
  assert(route_of(router, "/legacyx") == "not_found")
end

local function test_a_pattern_that_is_not_valid_raises_naming_it()
  local cases: {{string}} = {
    { "items", "must start with '/'" }, { "/a//b", "empty segment" }, { "/a/id-:id", "mixes text" },
    { "/a/:id-x", "not a parameter name" }, { "/*rest/more", "last segment" }, { "/a/:x/:x", "named twice" },
    { "/a/:1x", "not a parameter name" }, { "/a/:", "not a parameter name" }, { "/a/./b", "canonical" },
    { "/a/../b", "canonical" }, { "/a/\1", "control byte" }, { "", "must start with '/'" },
    { "/_web/x", "reserved" }, { "/_web", "reserved" },
  }
  for _, case in ipairs(cases) do
    local case_1 = assert(case[1], "expected case[1]")
    local message = Test.raises(function() Web.router({ Web.get(case_1, ok) }) end)
    local case_2 = assert(case[2], "expected case[2]")
    assert(message:find(case_2, 1, true), case_1 .. ": " .. message)
    assert(message:find(("%q"):format(case[1]), 1, true), "names the pattern: " .. message)
  end
end

local record Refusal
  expect: string
  build: function()
end

local function test_registration_refuses_conflicts_and_bad_routes()
  local cases: {Refusal} = {
    { expect = "already answered", build = function()
      Web.router({ Web.get("/a/:x", ok), Web.get("/a/:y", ok) })
    end },
    { expect = "already answered", build = function()
      Web.router({ Web.get("/a", ok), Web.route({ "GET", "POST" }, "/a", ok) })
    end },
    { expect = "already answered", build = function()
      Web.router({ Web.get("/a/*x", ok), Web.get("/a/*y", ok) })
    end },
    { expect = "already answered", build = function()
      Web.router({ Web.get("/a", ok), Web.get("/a/", ok) })
    end },
    { expect = "already used", build = function()
      Web.router({ Web.get("/a", ok, { name = "n" }), Web.get("/b", ok, { name = "n" }) })
    end },
    { expect = "already used", build = function()
      Web.router({ Web.mount("/m", { Web.get("/a", ok, { name = "n" }) }, { name = "x" }),
        Web.get("/n", ok, { name = "x:n" }) })
    end },
    { expect = "not a method in capitals", build = function()
      Web.router({ Web.route("get", "/a", ok) })
    end },
    { expect = "names no method", build = function() Web.router({ Web.route({}, "/a", ok) }) end },
    { expect = "no handler", build = function()
      local headless: Web.Route = { methods = { "GET" }, pattern = "/a", name = "", middleware = {} }
      Web.router({ headless })
    end },
    { expect = "no parameter", build = function() Web.router({ Web.mount("/u/:id", {}) }) end },
    { expect = "reserved", build = function() Web.router({ Web.mount("/_web", {}) }) end },
    { expect = "holds no ':'", build = function()
      Web.router({ Web.mount("/m", {}, { name = "a:b" }) })
    end },
    { expect = "under the mount at /api", build = function()
      Web.router({ Web.mount("/api", {}), Web.get("/api/x", ok) })
    end },
    { expect = "under the mount at /api", build = function()
      Web.router({ Web.mount("/api", {}), Web.get("/api", ok) })
    end },
    { expect = "routes already stand", build = function()
      Web.router({ Web.get("/api/x", ok), Web.mount("/api", {}) })
    end },
    { expect = "routes already stand", build = function()
      Web.router({ Web.get("/", ok), Web.mount("/", {}) })
    end },
    { expect = "under the mount at /api", build = function()
      Web.router({ Web.mount("/api", {}), Web.mount("/api/v1", {}) })
    end },
  }
  for i, case in ipairs(cases) do
    local message = Test.raises(case.build)
    assert(message:find(case.expect, 1, true), ("case %d: %s"):format(i, message))
  end
end

local function test_reverse_builds_urls_with_the_html_escaper()
  local router = Web.router({
    Web.get("/", ok, { name = "home" }), Web.get("/items/:id", ok, { name = "item" }),
    Web.get("/files/*path", ok, { name = "file" }), Web.get("/docs/", ok, { name = "docs" }),
    Web.mount("/api", { Web.get("/items/:id", ok, { name = "item" }) }, { name = "api" }),
    Web.mount("/plain", { Web.get("/thing", ok, { name = "thing" }) }),
  })
  assert(router:reverse("home") == "/")
  assert(router:reverse("item", { id = 42 }) == "/items/42")
  assert(router:reverse("item", { id = "a b/c" }, { v = "2", a = "x&y" }) == "/items/a%20b%2Fc?a=x%26y&v=2")
  assert(router:reverse("api:item", { id = "x" }) == "/api/items/x")
  assert(router:reverse("thing") == "/plain/thing", "an unnamed mount leaves its names as they are")
  assert(router:reverse("file", { path = "css/a b.css" }) == "/files/css/a%20b.css")
  assert(router:reverse("file", { path = "" }) == "/files/")
  assert(router:reverse("docs") == "/docs/")
  assert(router:reverse("item", { id = ".." }) == "/items/%252E%252E")
end

local function test_reverse_refuses_what_it_cannot_build()
  local router = Web.router({ Web.get("/items/:id", ok, { name = "item" }),
    Web.get("/f/*path", ok, { name = "file" }), Web.mount("/m", { Web.get("/x", ok) }, { name = "m" }) })
  local function reason(name: string, params: {string: string | integer}): string
    local url, why = router:reverse(name, params)
    assert(url == nil)
    return why
  end
  assert(reason("nope", {}):find("no route named", 1, true))
  assert(reason("item", {}):find("missing id", 1, true))
  assert(reason("item", { id = "1", extra = "x" }):find("unknown param extra", 1, true))
  assert(reason("item", { id = "" }):find("is empty", 1, true))
  assert(reason("file", { path = "a//b" }):find("empty segment", 1, true))
  assert(reason("m", {}):find('mount "m" has no reverse', 1, true))
end

local function test_a_mount_answers_reverse_through_its_resolver()
  local router = Web.router({ Web.mount_handler("/assets", ok, { name = "assets",
    reverse = function(prefix: string, params: {string:string}): string?, string
      if params.path == nil then return nil, "assets: a path is needed" end
      return prefix .. "/" .. params.path .. ".v1", ""
    end }) })
  assert(router:reverse("assets", { path = "app.css" }) == "/assets/app.css.v1")
  assert(router:reverse("assets", { path = "app.css" }, { x = "1" }) == "/assets/app.css.v1?x=1")
  local none, why = router:reverse("assets", {})
  assert(none == nil and why == "assets: a path is needed")
  local nested = Web.router({ Web.mount("/outer", { Web.mount_handler("/in", ok, { name = "in",
    reverse = function(prefix: string, _params: {string:string}): string?, string
      return prefix, ""
    end }) }, { name = "outer" }) })
  assert(nested:reverse("outer:in") == "/outer/in", "the resolver is given the full prefix")
end

local function test_a_reversed_url_matches_back_to_its_params()
  local router = Web.router({
    Web.get("/items/:id/tags/:tag", ok, { name = "tag" }), Web.get("/files/*path", ok, { name = "file" }),
    Web.mount("/api", { Web.get("/u/:name", ok, { name = "user" }) }, { name = "api" }),
  })
  local hostile = { "a b", "?x=1#y", "é", "%2e", "100%", "a+b", "x;y", "\\", "..a", "~" }
  for _, value in ipairs(hostile) do
    local url = assert(router:reverse("tag", { id = value, tag = "t" }))
    local found = router:match("GET", url)
    assert(found.kind == "match" and assert(found.params).id == value and assert(found.params).tag == "t", url)
    local user = assert(router:reverse("api:user", { name = value }))
    assert(assert(router:match("GET", user).params).name == value, user)
  end
  local slash = assert(router:reverse("tag", { id = "a/b", tag = "t" }))
  assert(router:match("GET", slash).kind == "bad_path", "an escaped slash is refused, never another route")
  local file = assert(router:reverse("file", { path = "a/b c/d" }))
  assert(assert(router:match("GET", file).params).path == "a/b c/d")
end

local function test_url_escape_html_url_part_and_reverse_agree()
  local router = Web.router({ Web.get("/x/:v", ok, { name = "x" }) })
  local values = { "", "a", "a b", "a/b", "..", ".", "...", "%", "%41", "?", "#", "&", "=", "+", "@", ":",
    "\\", "é", "\0", "~-._", "\r\n", "'\"<>", "x%252E" }
  for _, value in ipairs(values) do
    local part = Html.raw_url_part(Html.url_part(value))
    if value == "." or value == ".." then
      assert(part == "%252E" or part == "%252E%252E", value)
    else
      assert(part == Url.escape(value), ("%q: %s vs %s"):format(value, part, Url.escape(value)))
    end
    if value ~= "" then
      assert(router:reverse("x", { v = value }) == "/x/" .. part, value)
      local back = Url.unescape(part)
      assert(back == value or value == "." or value == "..", value)
    end
  end
end

local function test_a_method_the_most_specific_node_lacks_falls_back_to_the_next_node_that_has_it()
  local router = Web.router({
    Web.post("/files", ok, { name = "upload" }),
    Web.get("/files/*r", ok, { name = "download" }),
    Web.put("/files/:id", ok, { name = "put" }),
  })
  local get = router:match("GET", "/files")
  assert(get.kind == "match" and assert(get.route).name == "download" and assert(get.params).r == "", "the wildcard answers")
  assert(router:match("HEAD", "/files").kind == "match")
  assert(assert(router:match("POST", "/files").route).name == "upload")
  local other = router:match("DELETE", "/files")
  assert(other.kind == "not_allowed" and other.allow == "OPTIONS, POST",
    "405 names the most specific node's methods: " .. tostring(other.allow))
  local one = router:match("GET", "/files/7")
  assert(one.kind == "match" and assert(one.route).name == "download" and assert(one.params).r == "7",
    "the param node lacks GET: the wildcard above it answers")
  assert(assert(router:match("PUT", "/files/7").route).name == "put")
  local nobody = router:match("PATCH", "/files/7")
  assert(nobody.kind == "not_allowed" and nobody.allow == "OPTIONS, PUT", nobody.allow)
  assert(router:match("OPTIONS", "/files").kind == "options")
end

local function test_a_405_needs_no_node_to_answer_the_method()
  local router = Web.router({ Web.post("/p", ok), Web.get("/p/*r", ok) })
  local outcome = router:match("DELETE", "/p")
  assert(outcome.kind == "not_allowed" and outcome.allow == "OPTIONS, POST", outcome.allow)
  assert(router:match("GET", "/p").kind == "match")
end

local function test_the_reserved_prefix_is_judged_by_the_full_path()
  for _, pattern in ipairs({ "/_web", "/_web/a" }) do
    local message = Test.raises(function() Web.router({ Web.get(pattern, ok) }) end)
    assert(message:find("reserved", 1, true), message)
  end
  assert(Test.raises(function() Web.router({ Web.mount("/_web", { Web.get("/x", ok) }) }) end):find("reserved", 1, true))
  assert(Test.raises(function() Web.router({ Web.mount_handler("/_web", ok) }) end):find("reserved", 1, true))
  -- A name that is only reserved at the root: inside a mount it is the app's.
  local router = Web.router({ Web.mount("/x", { Web.get("/_web/a", ok, { name = "a" }) }) })
  assert(route_of(router, "/x/_web/a") == "/x/_web/a")
  local deeper = Web.router({ Web.mount("/x", { Web.mount("/_web", { Web.get("/b", ok) }) }) })
  assert(route_of(deeper, "/x/_web/b") == "/x/_web/b")
  -- A catch-all at the root is allowed; the built-in assets will be tried first.
  assert(route_of(Web.router({ Web.get("/*p", ok) }), "/_web/x") == "/*p")
  assert(route_of(Web.router({ Web.get("/:p", ok) }), "/_web") == "/:p")
  assert(route_of(Web.router({ Web.mount_handler("/", ok) }), "/_web/x") == "/*")
end
