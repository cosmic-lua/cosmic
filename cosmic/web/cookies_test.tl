local Cookies = require("cosmic.web.cookies")
local Time = require("cosmic.time")
local Web = require("cosmic.web")

local function test_parse_reads_pairs_and_the_first_of_a_name_wins()
  local got = Cookies.parse("a=1; b=2;c=3; a=9")
  assert(got.a == "1" and got.b == "2" and got.c == "3")
  assert(next(Cookies.parse(nil)) == nil and next(Cookies.parse("")) == nil)
end

local function test_parse_tolerates_a_comma_joined_header()
  local got = Cookies.parse("a=1, b=2; c=3")
  assert(got.a == "1" and got.b == "2" and got.c == "3")
end

local function test_parse_strips_quotes_and_skips_malformed_pieces()
  local got = Cookies.parse('q="x y"; flag; =orphan; ok=1; ;; e=')
  assert(got.q == "x y" and got.ok == "1" and got.e == "")
  assert(got.flag == nil and got[""] == nil)
  assert(Cookies.parse("v=%41")["v"] == "%41", "values are not percent-decoded")
end

local function test_parse_reads_at_most_100_cookies_and_8_kib()
  local parts: mut {string} = {}
  for i = 1, 150 do parts[i] = "c" .. tostring(i) .. "=v" end
  local got = Cookies.parse(table.concat(parts, "; "))
  local n = 0
  for _ in pairs(got) do n = n + 1 end
  assert(n == 100 and got.c1 == "v" and got.c101 == nil)
  local big = "a=1; b=" .. ("x"):rep(9000) .. "; c=3"
  local cut = Cookies.parse(big)
  assert(cut.a == "1" and cut.c == nil)
  assert(cut.b == nil or #cut.b < 9000, "no half cookie is read as a whole one")
end

local function test_format_writes_attributes_in_a_fixed_order_with_safe_defaults()
  assert(Cookies.format("n", "v") == "n=v; Path=/; HttpOnly; SameSite=Lax")
  local line = assert(Cookies.format("n", "v", { path = "/app", max_age = 60, domain = ".Example.com",
    secure = true, same_site = "Strict", partitioned = true }))
  assert(line == "n=v; Path=/app; Max-Age=60; Domain=Example.com; Secure; HttpOnly; SameSite=Strict; Partitioned", line)
  assert(assert(Cookies.format("n", "v", { http_only = false })) == "n=v; Path=/; SameSite=Lax")
  local dated = assert(Cookies.format("n", "v", { expires_ns = 0 }))
  assert(dated:find("Expires=Thu, 01 Jan 1970 00:00:00 GMT", 1, true), dated)
end

local function test_format_refuses_a_name_or_value_a_cookie_cannot_hold()
  local line, why = Cookies.format("bad name", "v")
  assert(line == nil and why:find("name", 1, true), why)
  for _, value in ipairs({ "a;b", "a b", "a,b", 'a"b', "a\\b", "a\nb", "é" }) do
    line, why = Cookies.format("n", value)
    assert(line == nil and why:find("value", 1, true), value)
  end
  line, why = Cookies.format("n", "v", { path = "/a;b" })
  assert(line == nil and why:find("path", 1, true), why)
  line, why = Cookies.format("n", "v", { domain = "a b" })
  assert(line == nil and why:find("domain", 1, true), why)
end

local function test_format_enforces_prefixes_and_samesite_none()
  local line, why = Cookies.format("__Host-id", "v")
  assert(line == nil and why:find("__Host-", 1, true), why)
  line, why = Cookies.format("__Host-id", "v", { secure = true, path = "/x" })
  assert(line == nil, "__Host- needs Path=/")
  line, why = Cookies.format("__Host-id", "v", { secure = true, domain = "example.com" })
  assert(line == nil, "__Host- takes no Domain")
  assert(Cookies.format("__Host-id", "v", { secure = true }) ~= nil)
  line, why = Cookies.format("__secure-id", "v")
  assert(line == nil and why:find("Secure", 1, true), why)
  assert(Cookies.format("__Secure-id", "v", { secure = true, domain = "example.com" }) ~= nil)
  line, why = Cookies.format("n", "v", { same_site = "None" })
  assert(line == nil and why:find("SameSite=None needs Secure", 1, true), why)
  assert(Cookies.format("n", "v", { same_site = "None", secure = true }) ~= nil)
  line, why = Cookies.format("n", "v", { partitioned = true })
  assert(line == nil and why:find("Partitioned", 1, true), why)
end

local function test_format_refuses_a_line_over_4096_bytes_with_the_count()
  local line, why = Cookies.format("n", ("x"):rep(4090))
  assert(line == nil and why:find("browsers keep at most 4096", 1, true), why)
  assert(why:find("%d%d%d%d bytes") ~= nil, why)
  local fit = assert(Cookies.format("n", ("x"):rep(4000)))
  assert(#fit <= 4096)
end

local function test_parse_reads_back_what_format_wrote()
  local line = assert(Cookies.format("sid", "abc", { max_age = 30, secure = true, same_site = "None",
    domain = "example.com", path = "/app", expires_ns = 0 }))
  local got = assert(Cookies.parse_set_cookie(line))
  assert(got.name == "sid" and got.value == "abc" and got.path == "/app" and got.max_age == 30)
  assert(got.domain == "example.com" and got.secure and got.http_only and got.same_site == "None")
  assert(got.expires_ns == 0 and not got.partitioned)
  assert(Cookies.parse("sid=abc").sid == got.value)
end

local function test_expire_deletes_with_max_age_zero_and_a_past_date()
  local line = assert(Cookies.expire("sid", { path = "/app", secure = true, domain = "example.com" }))
  local got = assert(Cookies.parse_set_cookie(line))
  assert(got.value == "" and got.max_age == 0 and got.expires_ns == 0)
  assert(got.path == "/app" and got.secure and got.domain == "example.com")
  assert(Cookies.expire("__Host-sid") == nil, "a __Host- cookie is expired with Secure")
  assert(Cookies.expire("__Host-sid", { secure = true }) ~= nil)
end

local function test_parse_set_cookie_is_lenient_about_what_it_does_not_know()
  local got = assert(Cookies.parse_set_cookie("a=1; path=/x; MAX-AGE=-5; Foo=bar; samesite=weird; Expires=junk; Secure"))
  assert(got.name == "a" and got.value == "1" and got.path == "/x" and got.max_age == -5)
  assert(got.secure and got.same_site == nil and got.expires_ns == nil)
  assert(assert(Cookies.parse_set_cookie("a=1; Path=relative")).path == nil)
  local when = assert(Time.parse_http("Sun, 06 Nov 1994 08:49:37 GMT"))
  assert(assert(Cookies.parse_set_cookie("a=1; Expires=Sun, 06 Nov 1994 08:49:37 GMT")).expires_ns == when)
  local nothing, why = Cookies.parse_set_cookie("novalue; Path=/")
  assert(nothing == nil and why:find("name=value", 1, true), why)
  nothing = Cookies.parse_set_cookie("=v")
  assert(nothing == nil)
end

local function test_set_appends_lines_and_leaves_the_response_alone_on_refusal()
  local res = Web.text("x")
  assert(Cookies.set(res, "a", "1"))
  assert(Cookies.set(res, "b", "2", { max_age = 5 }))
  local lines = assert(res.headers)["Set-Cookie"]
  assert(lines is {string} and #lines == 2 and lines[1]:find("^a=1;") and lines[2]:find("^b=2;"))
  local ok, why = Cookies.set(res, "c", "bad value")
  assert(not ok and why:find("value", 1, true))
  assert(#(assert(res.headers)["Set-Cookie"] as {string}) == 2)
end
