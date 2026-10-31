local Origin = require("cosmic.web.origin")
local Web = require("cosmic.web")

local function test_an_origin_has_one_spelling()
  assert(Origin.normalize("https://Example.COM") == "https://example.com")
  assert(Origin.normalize("HTTP://example.com:80") == "http://example.com")
  assert(Origin.normalize("https://example.com:443") == "https://example.com")
  assert(Origin.normalize("https://example.com:80") == "https://example.com:80")
  assert(Origin.normalize("http://example.com:0080") == "http://example.com")
  assert(Origin.normalize("http://localhost:3000") == "http://localhost:3000")
  assert(Origin.normalize("http://[::1]:8080") == "http://[::1]:8080")
  assert(Origin.normalize("http://127.0.0.1") == "http://127.0.0.1")
end

local function test_a_host_may_have_underscores_and_inner_dashes()
  assert(Origin.normalize("http://My_App:8080") == "http://my_app:8080")
  assert(Origin.normalize("https://a-b.c_d.example") == "https://a-b.c_d.example")
  assert(Origin.of_url("http://my_app:8080/x") == "http://my_app:8080")
end

local function test_what_is_no_origin_is_nil()
  for _, text in ipairs({ "", "null", "example.com", "//example.com", "ftp://example.com", "file:///x",
      "javascript://example.com", "https://", "https://example.com/", "https://example.com/x",
      "https://example.com?x", "https://example.com#x", "https://user@example.com",
      "https://example.com:", "https://example.com:0", "https://example.com:65536", "https://example.com:x",
      "https://exa mple.com", "https://example.com, https://evil.example",
      "https://[::1", "https://example.com\r\n", "https://..", "https://-.", "https://a..b",
      "https://.example.com", "https://example.com.", "https://-a.com", "https://a-.com", "https://a.-b.com", ("https://" .. ("a"):rep(400)) }) do
    assert(Origin.normalize(text) == nil, "accepted " .. text)
  end
end

local function test_the_origin_of_a_url_ignores_its_path_but_not_its_userinfo()
  assert(Origin.of_url("https://Example.com:443/a/b?c=d#e") == "https://example.com")
  assert(Origin.of_url("http://example.com") == "http://example.com")
  assert(Origin.of_url("https://user:pw@example.com/") == nil)
  assert(Origin.of_url("https://example.com@evil.example/") == nil)
  assert(Origin.of_url("not a url") == nil)
  assert(Origin.of_url("/relative") == nil)
  assert(Origin.of_url("data:text/html,x") == nil)
end

local function test_the_origin_of_a_request_is_its_scheme_and_host()
  local seen: mut {string} = {}
  local app = Web.app{ routes = { Web.get("/", function(req: Web.Request): Web.Response
    table.insert(seen, Origin.of_request(req) or "-")
    return Web.text("ok")
  end) }, trusted_proxy = true }
  local client = Web.test_client(app)
  client:get("/", { headers = { Host = "App.Example:8080" } })
  client:get("/", { headers = { Host = "app.example", ["X-Forwarded-Proto"] = "https" } })
  client:get("/", { headers = { Host = "my_app:8080" } })
  assert(seen[1] == "http://app.example:8080" and seen[2] == "https://app.example" and seen[3] == "http://my_app:8080",
    table.concat(seen, ","))
end
