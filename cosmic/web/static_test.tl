local Clock = require("cosmic.clock")
local Assets = require("cosmic.web.assets")
local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local StaticFiles = require("cosmic.web.static")
local Test = require("cosmic.test")
local Time = require("cosmic.time")
local Web = require("cosmic.web")

Test.policy{}

local CSS <const> = ("a { color: red }\n"):rep(200)
local SVG <const> = "<svg xmlns='http://www.w3.org/2000/svg'/>"

--- The files most tests serve.
local function files(): Assets.Source
  return Assets.memory({
    ["css/app.css"] = CSS, ["logo.svg"] = SVG, ["data.bin"] = "0123456789",
    ["LICENSE"] = "MIT", ["app.3f9a1c8e2b.js"] = "literal", ["docs/index.html"] = "<p>docs</p>",
    ["index.html"] = "<p>root</p>",
  }, { gzip = true })
end

local function app_of(opts?: StaticFiles.Options): Web.App
  local o: StaticFiles.Options = opts or {}
  if o.source == nil then o.source = files() end
  return Web.app{ routes = { StaticFiles.mount("/static", o), Web.get("/", function(_req: Web.Request): Web.Response
    return Web.text("home")
  end) } }
end

local function client_of(opts?: StaticFiles.Options): Web.TestClient
  return Web.test_client(app_of(opts))
end

local function test_a_file_is_served_with_its_type_validators_and_cache_headers()
  local res = client_of():get("/static/data.bin")
  assert(res.status == 200 and res.body == "0123456789")
  assert(res.headers["content-type"] == "application/octet-stream")
  assert(res.headers["etag"] == assert(files():get("data.bin")).etag)
  assert(res.headers["cache-control"] == "public, no-cache")
  assert(res.headers["x-content-type-options"] == "nosniff")
  assert(res.headers["accept-ranges"] == "bytes")
  assert(res.headers["content-length"] == "10")
  assert(res.headers["last-modified"] == nil, "an embedded asset has no time")
  assert(res.headers["vary"] == nil, "a file with no gzip variant does not vary")
end

local function test_head_answers_the_headers_of_get_with_no_body()
  local client = client_of()
  local get = client:get("/static/css/app.css")
  local head = client:head("/static/css/app.css")
  assert(head.status == 200 and head.body == "")
  assert(head.headers["content-length"] == get.headers["content-length"])
  assert(head.headers["etag"] == get.headers["etag"])
  assert(head.headers["content-type"] == "text/css; charset=utf-8")
end

local function test_only_get_and_head_are_answered()
  local client = client_of()
  for _, method in ipairs({ "POST", "PUT", "PATCH", "DELETE" }) do
    local res = client:request(method, "/static/data.bin")
    assert(res.status == 405 and res.headers["allow"] == "GET, HEAD", method)
  end
end

local function test_if_none_match_answers_304_with_the_validators_and_no_body()
  local client = client_of()
  local etag = assert(files():get("data.bin")).etag
  for _, header in ipairs({ etag, "W/" .. etag, '"other", ' .. etag, "*" }) do
    local res = client:get("/static/data.bin", { headers = { ["If-None-Match"] = header } })
    assert(res.status == 304 and res.body == "", header)
    assert(res.headers["etag"] == etag and res.headers["cache-control"] == "public, no-cache")
  end
  local head = client:head("/static/data.bin", { headers = { ["If-None-Match"] = etag } })
  assert(head.status == 304)
  local changed = client:get("/static/data.bin", { headers = { ["If-None-Match"] = '"stale"' } })
  assert(changed.status == 200 and changed.body == "0123456789")
end

local function test_a_range_is_a_206_with_its_content_range()
  local client = client_of()
  local function range(value: string): Web.TestResponse
    return client:get("/static/data.bin", { headers = { Range = value } })
  end
  local span = range("bytes=2-4")
  assert(span.status == 206 and span.body == "234" and span.headers["content-range"] == "bytes 2-4/10")
  assert(span.headers["content-length"] == "3" and span.headers["etag"] ~= nil)
  assert(range("bytes=7-").body == "789")
  local suffix = range("bytes=-3")
  assert(suffix.status == 206 and suffix.body == "789" and suffix.headers["content-range"] == "bytes 7-9/10")
  assert(range("bytes=8-99").body == "89")
  local past = range("bytes=10-")
  assert(past.status == 416 and past.headers["content-range"] == "bytes */10" and past.body == "")
  local many = range("bytes=0-1,4-5")
  assert(many.status == 200 and many.body == "0123456789")
  assert(range("items=0-1").status == 200)
  assert(range("bytes=5-2").status == 200)
end

local function test_head_ignores_a_range()
  local head = client_of():head("/static/data.bin", { headers = { Range = "bytes=2-4" } })
  assert(head.status == 200 and head.headers["content-length"] == "10")
end

local function test_if_range_keeps_the_range_only_for_the_current_strong_tag()
  local client = client_of()
  local etag = assert(files():get("data.bin")).etag
  local ok = client:get("/static/data.bin", { headers = { Range = "bytes=0-1", ["If-Range"] = etag } })
  assert(ok.status == 206 and ok.body == "01")
  for _, value in ipairs({ '"old"', "W/" .. etag, "Wed, 21 Oct 2015 07:28:00 GMT" }) do
    local res = client:get("/static/data.bin", { headers = { Range = "bytes=0-1", ["If-Range"] = value } })
    assert(res.status == 200 and res.body == "0123456789", value)
  end
end

local function test_gzip_is_sent_to_a_client_that_takes_it_with_its_own_tag()
  local client = client_of()
  local plain = client:get("/static/css/app.css")
  assert(plain.status == 200 and plain.body == CSS and plain.headers["content-encoding"] == nil)
  assert(plain.headers["vary"] == "Accept-Encoding")
  local zipped = client:get("/static/css/app.css", { headers = { ["Accept-Encoding"] = "br, gzip;q=0.5" } })
  assert(zipped.status == 200 and zipped.headers["content-encoding"] == "gzip")
  assert(Compress.inflate("gzip", zipped.body) == CSS and #zipped.body < #CSS)
  assert(zipped.headers["vary"] == "Accept-Encoding")
  assert(zipped.headers["etag"] == plain.headers["etag"]:sub(1, -2) .. '-gzip"')
  assert(zipped.headers["content-type"] == "text/css; charset=utf-8")
  local again = client:get("/static/css/app.css", { headers = { ["Accept-Encoding"] = "gzip",
    ["If-None-Match"] = zipped.headers["etag"] } })
  assert(again.status == 304 and again.headers["vary"] == "Accept-Encoding")
  local wrong = client:get("/static/css/app.css", { headers = { ["Accept-Encoding"] = "gzip",
    ["If-None-Match"] = plain.headers["etag"] } })
  assert(wrong.status == 200, "the identity tag does not name the gzip bytes")
end

local function test_gzip_is_refused_by_q_zero_and_taken_from_a_star()
  local client = client_of()
  local function encoding(value: string): string?
    return client:get("/static/css/app.css", { headers = { ["Accept-Encoding"] = value } }).headers["content-encoding"]
  end
  assert(encoding("gzip;q=0") == nil and encoding("gzip; q=0.0, *") == nil)
  assert(encoding("*") == "gzip" and encoding("identity, GZIP") == "gzip")
  assert(encoding("*;q=0") == nil and encoding("deflate") == nil)
  assert(encoding("*, gzip;q=0") == nil)
  assert(client_of({ gzip = false }):get("/static/css/app.css",
    { headers = { ["Accept-Encoding"] = "gzip" } }).headers["content-encoding"] == nil)
end

local function test_a_range_is_served_from_the_plain_bytes_whatever_the_client_accepts()
  local res = client_of():get("/static/css/app.css", { headers = { Range = "bytes=0-4",
    ["Accept-Encoding"] = "gzip" } })
  assert(res.status == 206 and res.body == CSS:sub(1, 5) and res.headers["content-encoding"] == nil)
end

local function test_a_fingerprinted_name_is_immutable_and_url_for_makes_it()
  local app = app_of()
  local client = Web.test_client(app)
  local asset = assert(files():get("css/app.css"))
  local digits = asset.sha256:sub(1, 10)
  local url = assert(app:url_for("static", { path = "css/app.css" }))
  assert(url == "/static/css/app." .. digits .. ".css")
  local res = client:get(url)
  assert(res.status == 200 and res.body == CSS)
  assert(res.headers["cache-control"] == "public, max-age=31536000, immutable")
  assert(res.headers["etag"] == asset.etag)
  local revalidated = client:get(url, { headers = { ["If-None-Match"] = asset.etag } })
  assert(revalidated.status == 304 and revalidated.headers["cache-control"] == "public, max-age=31536000, immutable")
  local plain = client:get("/static/css/app.css")
  assert(plain.headers["cache-control"] == "public, no-cache")
  assert(assert(app:url_for("static", { path = "LICENSE" })) ==
      "/static/LICENSE." .. assert(files():get("LICENSE")).sha256:sub(1, 10))
  local licence = client:get("/static/LICENSE." .. assert(files():get("LICENSE")).sha256:sub(1, 10))
  assert(licence.status == 200 and licence.body == "MIT")
end

local function test_a_stale_fingerprint_is_a_404_that_no_cache_keeps()
  local res = client_of():get("/static/css/app.0123456789.css")
  assert(res.status == 404 and res.headers["cache-control"] == "no-store")
  assert(not res.body:find("color", 1, true))
  local missing = client_of():get("/static/css/none.0123456789.css")
  assert(missing.status == 404 and missing.headers["cache-control"] == nil)
end

local function test_a_real_file_named_like_a_fingerprint_wins_over_the_rewrite()
  local res = client_of():get("/static/app.3f9a1c8e2b.js")
  assert(res.status == 200 and res.body == "literal")
  assert(res.headers["cache-control"] == "public, no-cache")
end

local function test_url_for_an_asset_the_source_lacks_says_so()
  local app = app_of()
  local url, why = app:url_for("static", { path = "nope.css" })
  assert(url == nil and why:find("no such asset", 1, true))
  local bare, bare_why = app:url_for("static", {})
  assert(bare == nil and bare_why ~= "")
  assert(StaticFiles.url(files(), "/", "LICENSE") ==
      "/LICENSE." .. assert(files():get("LICENSE")).sha256:sub(1, 10))
  assert(assert(StaticFiles.url(files(), "/assets/v1", "docs/index.html")):find("^/assets/v1/docs/index%.%x+%.html$"))
end

local function test_svg_is_sandboxed_and_an_option_header_replaces_a_default()
  local plain = client_of():get("/static/logo.svg")
  assert(plain.headers["content-type"] == "image/svg+xml; charset=utf-8")
  assert(plain.headers["content-security-policy"] == "sandbox")
  local custom = client_of({ headers = { ["Content-Security-Policy"] = "default-src 'none'",
    ["Access-Control-Allow-Origin"] = "*" } })
  local res = custom:get("/static/logo.svg")
  assert(res.headers["content-security-policy"] == "default-src 'none'")
  assert(res.headers["access-control-allow-origin"] == "*")
  assert(custom:get("/static/data.bin", { headers = { ["If-None-Match"] = "*" } }).headers["access-control-allow-origin"] == "*")
end

local function test_xml_and_xhtml_are_sandboxed_as_svg_is()
  local client = client_of({ source = Assets.memory({
    ["a.xml"] = "<a/>", ["page.xhtml"] = "<html/>", ["s.xsl"] = "<x/>", ["a.txt"] = "x" }) })
  for _, name in ipairs({ "a.xml", "page.xhtml", "s.xsl" }) do
    assert(client:get("/static/" .. name).headers["content-security-policy"] == "sandbox", name)
  end
  assert(client:get("/static/a.txt").headers["content-security-policy"] == nil)
end

local function test_cache_control_options_replace_both_defaults()
  local client = client_of({ cache_control = "no-store", immutable_control = "public, max-age=60" })
  assert(client:get("/static/data.bin").headers["cache-control"] == "no-store")
  local url = assert(StaticFiles.url(files(), "/static", "data.bin"))
  assert(client:get(url).headers["cache-control"] == "public, max-age=60")
end

local function test_a_directory_or_the_root_has_no_listing_and_is_a_404()
  local client = client_of()
  for _, path in ipairs({ "/static", "/static/", "/static/css", "/static/css/", "/static/docs",
      "/static/docs/" }) do
    local res = client:get(path)
    assert(res.status == 404 or res.status == 308, path .. " " .. res.status)
    assert(not res.body:find("app.css", 1, true) and not res.body:find("<p>", 1, true), path)
  end
  assert(client:get("/static/data.bin/").status == 404)
end

local function test_html_serves_an_index_for_a_directory_and_redirects_to_its_slash()
  local client = client_of({ html = true })
  local root = client:get("/static/")
  assert(root.status == 200 and root.body == "<p>root</p>" and root.headers["content-type"] == "text/html; charset=utf-8")
  local docs = client:get("/static/docs/")
  assert(docs.status == 200 and docs.body == "<p>docs</p>")
  local bare = client:get("/static/docs?x=1")
  assert(bare.status == 308 and bare.redirect_location == "/static/docs/?x=1")
  assert(client:get("/static/css/").status == 404)
  assert(client:get("/static/css").status == 404)
  assert(client:get("/static/data.bin/").status == 404)
end

local function test_not_found_is_the_option_or_the_apps_404()
  local custom = client_of({ not_found = function(_req: Web.Request): Web.Response
    return Web.text("lost", { status = 404 })
  end })
  assert(custom:get("/static/nothing").body == "lost" and custom:get("/static/").body == "lost")
  local plain = client_of():get("/static/nothing")
  assert(plain.status == 404 and plain.headers["content-type"] == "text/html; charset=utf-8")
  local json = client_of():get("/static/nothing", { headers = { Accept = "application/json" } })
  assert(json.status == 404 and json.headers["content-type"] == "application/problem+json")
end

local function test_the_mounts_prefix_is_stripped_wherever_it_sits()
  local app = Web.app{ routes = { Web.mount("/v1", { StaticFiles.mount("/files", { source = files() }) },
    { name = "v1" }) } }
  local client = Web.test_client(app)
  assert(client:get("/v1/files/data.bin").body == "0123456789")
  assert(client:get("/v1/files/v1/files/data.bin").status == 404)
  assert(client:get("/files/data.bin").status == 404)
  assert(assert(app:url_for("v1:static", { path = "data.bin" })):find("^/v1/files/data%.%x+%.bin$"))
end

--- Paths that must never reach `secret.txt` beside the served root.
local ESCAPES <const>: {string} = {
  "/static/../secret.txt", "/static/%2e%2e/secret.txt", "/static/%2E%2E/secret.txt",
  "/static/..%2fsecret.txt", "/static/%2e%2e%2fsecret.txt", "/static/sub/../../secret.txt",
  "/static/sub%2f..%2f..%2fsecret.txt", "/static/..%5csecret.txt", "/static/%2e%2e%5csecret.txt",
  "/static/..\\secret.txt", "/static//secret.txt", "/static/./../secret.txt",
  "/static/%252e%252e/secret.txt", "/static/ok.txt%00.png", "/static/%00", "/static/ok.txt%00",
  "/static//etc/passwd", "/static/%2fetc%2fpasswd", "/static/.%2e/secret.txt",
  "/static/....//secret.txt", "/static/..;/secret.txt",
}

local function test_no_spelling_of_a_path_reaches_a_file_outside_the_root(tmp: string)
  assert(Fs.mkdirs(tmp .. "/root/sub"))
  assert(Fs.write(tmp .. "/secret.txt", "TOPSECRET"))
  assert(Fs.write(tmp .. "/root/ok.txt", "fine"))
  assert(Fs.write(tmp .. "/root/sub/in.txt", "inner"))
  local client = client_of({ source = Assets.directory(tmp .. "/root") })
  assert(client:get("/static/ok.txt").body == "fine")
  for _, path in ipairs(ESCAPES) do
    local res = client:get(path, { follow_redirects = true })
    assert(res.status == 400 or res.status == 404, path .. " answered " .. res.status)
    assert(not res.body:find("TOPSECRET", 1, true), path)
    local head = client:head(path, { follow_redirects = true })
    assert(head.status == 400 or head.status == 404, path)
  end
  local memory = client_of()
  for _, path in ipairs(ESCAPES) do
    local res = memory:get(path, { follow_redirects = true })
    assert(res.status == 400 or res.status == 404, path)
  end
end

local function test_a_dotfile_a_link_out_and_a_directory_are_not_served(tmp: string)
  assert(Fs.mkdirs(tmp .. "/root/.git"))
  assert(Fs.mkdirs(tmp .. "/root/sub/.hidden"))
  assert(Fs.write(tmp .. "/secret.txt", "TOPSECRET"))
  assert(Fs.write(tmp .. "/root/.env", "KEY=TOPSECRET"))
  assert(Fs.write(tmp .. "/root/.git/config", "TOPSECRET"))
  assert(Fs.write(tmp .. "/root/sub/.hidden/x", "TOPSECRET"))
  assert(Fs.write(tmp .. "/root/sub/.htpasswd", "TOPSECRET"))
  assert(Fs.symlink(tmp .. "/secret.txt", tmp .. "/root/leak.txt"))
  assert(Fs.symlink(tmp, tmp .. "/root/up"))
  assert(Fs.write(tmp .. "/root/ok.txt", "fine"))
  local client = client_of({ source = Assets.directory(tmp .. "/root") })
  for _, path in ipairs({ "/static/.env", "/static/.git/config", "/static/sub/.hidden/x",
      "/static/sub/.htpasswd", "/static/leak.txt", "/static/up/secret.txt", "/static/sub", "/static/sub/",
      "/static/%2eenv", "/static/%2Eenv", "/static/.%65nv" }) do
    local res = client:get(path)
    assert(res.status == 404, path .. " answered " .. res.status)
    assert(not res.body:find("TOPSECRET", 1, true), path)
  end
  assert(client:get("/static/ok.txt").status == 200)
end

local function test_a_name_with_odd_bytes_is_served_by_its_escaped_url(tmp: string)
  assert(Fs.write(tmp .. "/a b.txt", "spaced"))
  local source = Assets.directory(tmp)
  local app = app_of({ source = source })
  local url = assert(app:url_for("static", { path = "a b.txt" }))
  assert(url:find("^/static/a%%20b%.%x+%.txt$"), url)
  assert(Web.test_client(app):get(url).body == "spaced")
end

local function test_the_directory_source_sends_last_modified_and_honors_if_modified_since(tmp: string)
  assert(Fs.write(tmp .. "/a.txt", "dated"))
  local mtime = 1700000000
  assert(Fs.set_mtime(tmp .. "/a.txt", mtime))
  local client = client_of({ source = Assets.directory(tmp) })
  local stamp = Time.format_http(mtime * 1000000000)
  local res = client:get("/static/a.txt")
  assert(res.status == 200 and res.headers["last-modified"] == stamp)
  local fresh = client:get("/static/a.txt", { headers = { ["If-Modified-Since"] = stamp } })
  assert(fresh.status == 304 and fresh.body == "" and fresh.headers["last-modified"] == stamp)
  local later = client:get("/static/a.txt", { headers = { ["If-Modified-Since"] = Time.format_http((mtime + 60) * 1000000000) } })
  assert(later.status == 304)
  local older = client:get("/static/a.txt", { headers = { ["If-Modified-Since"] = Time.format_http((mtime - 1) * 1000000000) } })
  assert(older.status == 200 and older.body == "dated")
  local junk = client:get("/static/a.txt", { headers = { ["If-Modified-Since"] = "yesterday" } })
  assert(junk.status == 200)
  local both = client:get("/static/a.txt", { headers = { ["If-Modified-Since"] = stamp,
    ["If-None-Match"] = '"other"' } })
  assert(both.status == 200, "If-None-Match decides, and If-Modified-Since is ignored beside it")
end

local function test_an_edit_in_the_directory_changes_the_tag_and_the_fingerprint(tmp: string)
  assert(Fs.write(tmp .. "/a.css", "one"))
  assert(Fs.set_mtime(tmp .. "/a.css", 1700000000))
  local app = app_of({ source = Assets.directory(tmp) })
  local client = Web.test_client(app)
  local first_url = assert(app:url_for("static", { path = "a.css" }))
  local first = client:get(first_url)
  assert(first.status == 200 and first.body == "one")
  assert(Fs.write(tmp .. "/a.css", "two"))
  assert(Fs.set_mtime(tmp .. "/a.css", 1700000100))
  local second_url = assert(app:url_for("static", { path = "a.css" }))
  assert(second_url ~= first_url)
  assert(client:get(second_url).body == "two")
  assert(client:get(first_url).status == 404, "the old fingerprint is stale, not the new bytes")
  assert(client:get("/static/a.css").headers["etag"] ~= first.headers["etag"])
end

local function test_blanks_in_accept_encoding_cost_time_linear_in_their_run()
  local client = Web.test_client(app_of())
  local start = Clock.monotonic_ns()
  local res = client:get("/static/css/app.css", { headers = { ["Accept-Encoding"] = "gzip;q=0.5" .. (" "):rep(60000) .. "y" } })
  local took = Clock.monotonic_ns() - start
  assert(res.status == 200)
  assert(took < Clock.seconds(1), "took " .. took // 1000000 .. " ms")
  local spaced = client:get("/static/css/app.css", { headers = { ["Accept-Encoding"] = "br , gzip ; q=0.5 " } })
  assert(spaced.headers["content-encoding"] == "gzip")
end
