local Fs = require("cosmic.fs")
local GithubApi = require("cosmic_ci.github_api")
local Http = require("cosmic.http")

-- The live client's transport runs over [`cosmic.http`]'s `script`, whose
-- connections are socket pairs: no network is reached.

local token <const> = "tok-123"

--- A whole reply: a status line, `head`'s header lines, and `body`.
local function reply(status: string, head: string, body?: string): string
  body = body or ""
  return "HTTP/1.1 " .. status .. "\r\n" .. head ..
    "Content-Length: " .. tostring(#body) .. "\r\nConnection: close\r\n\r\n" .. body
end

--- The live client over a plain-HTTP API (a script cannot finish a TLS
--- handshake), its calls answered by `script` in order; `sent` collects
--- what each `send` wrote.
local function live(script: {{string}}, env?: {string:string}): GithubApi.Client, {string}
  local sent: {string} = {}
  env = env or {}
  env.GH_TOKEN = env.GH_TOKEN or token
  env.GITHUB_API_URL = env.GITHUB_API_URL or "http://api.test/"
  local client, why = GithubApi.live(env, { script = script, sent = sent })
  assert(client ~= nil, why)
  return client, sent
end

local function has(text: string, needle: string)
  assert(text:find(needle, 1, true), "lacks " .. needle .. ":\n" .. text)
end

local function test_a_get_sends_the_token_and_the_headers_github_requires()
  local client, sent = live({ { reply("200 OK", "", '{"a":1}') } })
  local body, why = GithubApi.get(client, "repos/o/r/actions/runs?status=completed&per_page=2")
  assert(body == '{"a":1}', why)
  assert(#sent == 1)
  assert(sent[1]:find("GET /repos/o/r/actions/runs?status=completed&per_page=2 HTTP/1.1\r\n", 1, true) == 1, sent[1])
  has(sent[1], "\r\nHost: api.test\r\n")
  has(sent[1], "\r\nAuthorization: Bearer " .. token .. "\r\n")
  has(sent[1], "\r\nAccept: application/vnd.github+json\r\n")
  has(sent[1], "\r\nX-GitHub-Api-Version: 2022-11-28\r\n")
  has(sent[1], "\r\nUser-Agent: cosmic-ci\r\n")
end

local function test_the_token_is_read_from_gh_token_then_github_token()
  local client, sent = live({ { reply("200 OK", "", "{}") } }, { GH_TOKEN = "", GITHUB_TOKEN = "second" })
  assert(GithubApi.get(client, "x"))
  has(sent[1], "Authorization: Bearer second\r\n")
  client, sent = live({ { reply("200 OK", "", "{}") } }, { GH_TOKEN = "first", GITHUB_TOKEN = "second" })
  assert(GithubApi.get(client, "x"))
  has(sent[1], "Authorization: Bearer first\r\n")
end

local function test_there_is_no_client_without_a_token()
  local client, why = GithubApi.live({})
  assert(client == nil and why:find("GH_TOKEN or GITHUB_TOKEN", 1, true), tostring(why))
  client, why = GithubApi.live({ GH_TOKEN = "", GITHUB_TOKEN = "" })
  assert(client == nil, "an empty token was taken")
  client, why = GithubApi.live({ GH_TOKEN = token, GITHUB_API_URL = "not a url" })
  assert(client == nil and why:find("GITHUB_API_URL", 1, true), tostring(why))
end

local function test_the_api_is_github_by_default_and_named_by_github_api_url()
  local client = assert(GithubApi.live({ GH_TOKEN = token }))
  assert(client.base == "https://api.github.com", client.base)
  client = assert(GithubApi.live({ GH_TOKEN = token, GITHUB_API_URL = "https://ghe.test/api/v3//" }))
  assert(client.base == "https://ghe.test/api/v3", client.base)
end

local function test_a_status_outside_2xx_is_an_error_naming_the_request_and_githubs_message()
  local client = live({ { reply("404 Not Found", "", '{"message":"Not Found","status":"404"}') },
    { reply("500 Internal Server Error", "", "<html>oops</html>") },
    { reply("302 Found", "Location: http://elsewhere.test/\r\n") } })
  local body, why = GithubApi.get(client, "repos/o/r/missing")
  assert(body == nil and why == "GET repos/o/r/missing: HTTP 404: Not Found", why)
  body, why = GithubApi.get(client, "repos/o/r/x")
  assert(body == nil and why == "GET repos/o/r/x: HTTP 500", why)
  -- The API's own redirect is not followed with the token.
  body, why = GithubApi.get(client, "repos/o/r/y")
  assert(body == nil and why == "GET repos/o/r/y: HTTP 302", why)
end

local function test_a_request_that_gets_no_answer_fails_naming_the_path()
  local client = live({})
  local body, why = GithubApi.get(client, "repos/o/r")
  assert(body == nil and why:find("GET repos/o/r: ", 1, true) == 1, tostring(why))
end

local function test_the_token_goes_to_no_other_origin()
  local client, sent = live({ { reply("200 OK", "", "{}") } })
  for _, url in ipairs({ "http://other.test/repos/o/r", "http://api.test:8080/x", "https://api.test/x" }) do
    local answered, why = client.send({ method = "GET", url = url, headers = {} })
    assert(answered == nil and why:find("refusing to send the token", 1, true), url .. ": " .. tostring(why))
  end
  assert(#sent == 0)
end

local function test_a_body_is_sent_whole_with_its_content_type()
  local client, sent = live({ { reply("201 Created", "", "{}") } })
  local answered, why = client.send({ method = "POST", url = client.base .. "/repos/o/r/git/refs",
    headers = { ["Content-Type"] = "application/json" }, body = '{"ref":"r"}' })
  assert(answered ~= nil and answered.status == 201, why)
  has(sent[1], "POST /repos/o/r/git/refs HTTP/1.1\r\n")
  has(sent[1], "\r\nContent-Type: application/json\r\n")
  has(sent[1], '\r\n\r\n{"ref":"r"}')
  assert(not sent[1]:find("Expect:", 1, true), sent[1])
end

--- A download asks the API with the token, takes its redirect by hand and
--- fetches the redirect's URL, which [`Http.download_result`] is handed without
--- one.
local function test_a_download_fetches_the_redirect_without_the_token(tmp: string)
  local client, sent = live({ { reply("302 Found", "Location: https://blob.test/signed?sig=abc\r\n") }, {} })
  local urls: {string} = {}
  local options: Http.Options = {}
  local real = Http.download_result
  Http.download_result = function(url: string, path: string, opts?: Http.Options): Http.DownloadResult
    urls[#urls + 1] = url
    options = opts as Http.Options
    assert(Fs.write(path, "zip bytes"))
    return { kind = "downloaded", reason = "" }
  end
  local called, ok, why = pcall(GithubApi.download, client, "repos/o/r/actions/artifacts/7/zip",
    tmp .. "/a.zip")
  Http.download_result = real
  assert(called, tostring(ok))
  assert(ok, why)
  has(sent[1], "GET /repos/o/r/actions/artifacts/7/zip HTTP/1.1\r\n")
  has(sent[1], "Authorization: Bearer " .. token)
  assert(#urls == 1 and urls[1] == "https://blob.test/signed?sig=abc", table.concat(urls, " "))
  assert(Fs.read(tmp .. "/a.zip") == "zip bytes")
  for name in pairs(options.headers or {}) do
    assert(name:lower() ~= "authorization", "the token went to the redirect's host")
  end
  assert(options.redirect_protocols and #options.redirect_protocols == 1 and
      options.redirect_protocols[1] == "https", "a redirect may leave https")
  assert(options.follow ~= false and (options.max_redirects or 0) <= 3)
end

local function test_a_download_refuses_a_location_that_is_not_https(tmp: string)
  local client = live({
    { reply("302 Found", "Location: http://blob.test/x\r\n") },
    { reply("302 Found", "Location: /relative\r\n") },
    { reply("302 Found", "") },
    { reply("200 OK", "", "inline") },
  })
  local fetched = false
  local real = client.fetch
  client.fetch = function(url: string, path: string): boolean, string
    fetched = true
    return real(url, path)
  end
  for i = 1, 4 do
    local ok, why = GithubApi.download(client, "repos/o/r/z" .. i, tmp .. "/z")
    assert(not ok and why:find("GET repos/o/r/z" .. i .. ": ", 1, true) == 1, tostring(why))
  end
  assert(not fetched, "a URL was fetched")
  assert(not Fs.exists(tmp .. "/z"))
end

local function test_a_download_reports_the_apis_refusal_and_the_fetchs_failure(tmp: string)
  local client = live({ { reply("404 Not Found", "", '{"message":"Not Found"}') },
    { reply("410 Gone", "", '{"message":"Artifact has expired"}') } })
  local ok, why = GithubApi.download(client, "repos/o/r/artifacts/1/zip", tmp .. "/z")
  assert(not ok and why == "GET repos/o/r/artifacts/1/zip: HTTP 404: Not Found", why)
  ok, why = GithubApi.download(client, "repos/o/r/artifacts/2/zip", tmp .. "/z")
  assert(not ok and why == "GET repos/o/r/artifacts/2/zip: HTTP 410: Artifact has expired", why)
  local failing = GithubApi.live({ GH_TOKEN = token, GITHUB_API_URL = "http://api.test" },
    { script = { { reply("302 Found", "Location: https://blob.test/signed?sig=abc\r\n") },
      { reply("403 Forbidden", "", "expired") } } })
  assert(failing ~= nil)
  local real = Http.download_result
  Http.download_result = function(): Http.DownloadResult
    return { kind = "http_status", reason = "", status = 403 }
  end
  local called, got, trouble = pcall(GithubApi.download, failing, "repos/o/r/artifacts/3/zip",
    tmp .. "/z")
  Http.download_result = real
  assert(called, tostring(got))
  ok, why = got as boolean, trouble
  -- The signed URL stays out of the message.
  assert(not ok and why == "GET repos/o/r/artifacts/3/zip: HTTP 403", why)
end

--- Origins compare by scheme, host and port, a default port being the
--- scheme's: a look-alike never gets the token.
local function test_origins_are_compared_by_scheme_host_and_port()
  local client, sent = live({ { reply("200 OK", "", "{}") }, { reply("200 OK", "", "{}") } },
    { GITHUB_API_URL = "http://api.test:80" })
  -- The same origin written with and without its default port, in any case.
  for _, url in ipairs({ "http://api.test/a", "http://API.test:80/a" }) do
    local answered, why = client.send({ method = "GET", url = url, headers = {} })
    assert(answered ~= nil, url .. ": " .. tostring(why))
  end
  assert(#sent == 2)
  for _, url in ipairs({ "http://api.test:81/a", "https://api.test:80/a",
      "http://api.test.evil.test/a", "http://api.test@evil.test/a", "http://[::1]/a" }) do
    local answered, why = client.send({ method = "GET", url = url, headers = {} })
    assert(answered == nil and why:find("refusing", 1, true), url .. ": " .. tostring(why))
  end
  assert(#sent == 2)
end

--- A request, a download's included, is refused where the client's base is
--- not the origin its token belongs to.
local function test_a_client_whose_base_is_another_origin_sends_nothing(tmp: string)
  local client, sent = live({ { reply("200 OK", "", "{}") } })
  client.base = "http://other.test"
  local body, why = GithubApi.get(client, "repos/o/r")
  assert(body == nil and why:find("refusing to send the token", 1, true), tostring(why))
  local ok, trouble = GithubApi.download(client, "repos/o/r/zip", tmp .. "/z")
  assert(not ok and trouble:find("refusing to send the token", 1, true), tostring(trouble))
  assert(#sent == 0)
end

local function test_a_json_body_is_sent_whole_by_any_method()
  local client, sent = live({ { reply("201 Created", "", '{"id":9}') }, { reply("200 OK", "", '{"id":9}') } })
  local made, why = GithubApi.request(client, "POST", "repos/o/r/releases",
    { tag_name = "t", draft = true })
  assert(made ~= nil and made.status == 201, why)
  local patched = GithubApi.request(client, "PATCH", "repos/o/r/releases/9", { draft = false })
  assert(patched ~= nil and patched.status == 200)
  has(sent[1], "POST /repos/o/r/releases HTTP/1.1\r\n")
  has(sent[1], "\r\nContent-Type: application/json\r\n")
  has(sent[1], "\r\nAuthorization: Bearer " .. token .. "\r\n")
  has(sent[1], '\r\n\r\n{"draft":true,"tag_name":"t"}')
  has(sent[2], "PATCH /repos/o/r/releases/9 HTTP/1.1\r\n")
  has(sent[2], '\r\n\r\n{"draft":false}')
  assert(not sent[1]:find("Expect:", 1, true) and not sent[2]:find("Expect:", 1, true))
end

local function test_a_request_answers_a_refusal_and_reports_no_answer()
  local client = live({ { reply("403 Forbidden", "", '{"message":"Resource not accessible by integration"}') } })
  local refused = GithubApi.request(client, "POST", "repos/o/r/git/refs", { ref = "r" })
  assert(refused ~= nil and refused.status == 403 and refused.body:find("not accessible", 1, true))
  local none, why = GithubApi.request(client, "POST", "repos/o/r/git/refs", { ref = "r" })
  assert(none == nil and why:find("POST repos/o/r/git/refs: ", 1, true) == 1, tostring(why))
end

local function test_an_object_is_the_decoded_answer_or_why_not()
  local client = live({ { reply("201 Created", "", '{"id":9}') },
    { reply("422 Unprocessable Entity", "", '{"message":"Validation Failed"}') },
    { reply("200 OK", "", "[1]") } })
  local object, why = GithubApi.object(client, "POST", "repos/o/r/releases", { tag_name = "t" })
  assert(object ~= nil and object.id == 9, why)
  object, why = GithubApi.object(client, "POST", "repos/o/r/releases", { tag_name = "t" })
  assert(object == nil and why == "POST repos/o/r/releases: HTTP 422: Validation Failed", why)
  object, why = GithubApi.object(client, "GET", "repos/o/r/releases/1")
  assert(object == nil and why:find("GET repos/o/r/releases/1: no JSON object", 1, true) == 1, why)
end

local function test_a_download_asks_for_the_bytes_where_told_to(tmp: string)
  local client, sent = live({ { reply("302 Found", "Location: https://blob.test/signed\r\n") }, {} })
  local real = Http.download_result
  Http.download_result = function(_url: string, path: string): Http.DownloadResult
    assert(Fs.write(path, "asset bytes"))
    return { kind = "downloaded", reason = "" }
  end
  local called, ok, why = pcall(GithubApi.download, client, "repos/o/r/releases/assets/5",
    tmp .. "/a", "application/octet-stream")
  Http.download_result = real
  assert(called, tostring(ok))
  assert(ok, why)
  has(sent[1], "GET /repos/o/r/releases/assets/5 HTTP/1.1\r\n")
  has(sent[1], "\r\nAccept: application/octet-stream\r\n")
  assert(not sent[1]:find("vnd.github", 1, true), sent[1])
  assert(Fs.read(tmp .. "/a") == "asset bytes")
end

local function test_the_upload_origin_follows_the_api()
  local function uploads(url: string): string, string
    local client = assert(GithubApi.live({ GH_TOKEN = token, GITHUB_API_URL = url }))
    return client.upload_origin, client.upload_path
  end
  local origin, path = uploads("https://api.github.com")
  assert(origin == "https://uploads.github.com:443" and path == "", origin .. path)
  origin, path = uploads("https://api.octo.ghe.com/")
  assert(origin == "https://uploads.octo.ghe.com:443" and path == "", origin .. path)
  -- An Enterprise Server serves its uploads itself.
  origin, path = uploads("https://ghe.test/api/v3")
  assert(origin == "https://ghe.test:443" and path == "/api/uploads", origin .. path)
  origin, path = uploads("http://api.test:8080")
  assert(origin == "http://uploads.test:8080" and path == "", origin .. path)
end

local release_assets <const> = "http://uploads.test/repos/o/r/releases/5/assets"

local function test_an_upload_sends_the_bytes_to_the_upload_origin_with_the_token()
  local client, sent = live({ { reply("201 Created", "", '{"id":1,"name":"a b","state":"uploaded"}') } })
  -- Small enough to fit one write to the script's socket on every leg:
  -- the script answers at once, and curl ends the request once the
  -- answer is whole, so macOS's small socket buffer would leave the
  -- rest of a larger body unsent and unrecorded.
  -- TODO: send a body the size of a real asset once core/http.c's
  -- script holds its reply until the request it answers is whole.
  local bytes = "\0\1binary\255" .. string.rep("x", 2000)
  local ok, why = GithubApi.upload(client, release_assets .. "{?name,label}", "a b", bytes)
  assert(ok, why)
  assert(#sent == 1)
  has(sent[1], "POST /repos/o/r/releases/5/assets?name=a%20b HTTP/1.1\r\n")
  has(sent[1], "\r\nHost: uploads.test\r\n")
  has(sent[1], "\r\nAuthorization: Bearer " .. token .. "\r\n")
  has(sent[1], "\r\nContent-Type: application/octet-stream\r\n")
  has(sent[1], "\r\nContent-Length: " .. #bytes .. "\r\n")
  has(sent[1], "\r\n\r\n" .. bytes)
  assert(not sent[1]:find("Expect:", 1, true), "an Expect header was sent")
end

local function test_an_upload_goes_to_no_other_origin_or_path()
  local client, sent = live({})
  for _, url in ipairs({ "http://api.test/repos/o/r/releases/5/assets",
      "http://other.test/repos/o/r/releases/5/assets",
      "https://uploads.test/repos/o/r/releases/5/assets",
      "http://uploads.test:8080/repos/o/r/releases/5/assets",
      "http://uploads.test.evil.test/repos/o/r/releases/5/assets",
      "http://u:p@uploads.test/repos/o/r/releases/5/assets",
      "http://uploads.test@evil.test/repos/o/r/releases/5/assets",
      release_assets .. "?name=x", release_assets .. "#x",
      "http://uploads.test/repos/o/r/releases/x/assets",
      "http://uploads.test/api/uploads/repos/o/r/releases/5/assets",
      "http://uploads.test/repos/o/r/releases/5/assets/6",
      "http://uploads.test/repos/../r/releases/5/assets",
      "http://uploads.test/repos/o/%2E%2e/releases/5/assets",
      "http://uploads.test/repos/./r/releases/5/assets",
      "http://uploads.test/x/repos/o/r/releases/5/assets", "not a url", "" }) do
    local ok, why = GithubApi.upload(client, url, "cosmic", "bytes")
    assert(not ok and why:find("upload", 1, true), url .. ": " .. tostring(why))
  end
  local ok, why = GithubApi.upload(client, release_assets, "", "bytes")
  assert(not ok and why:find("no asset name", 1, true), tostring(why))
  assert(#sent == 0, "something was sent")
end

--- An Enterprise Server's uploads are under /api/uploads on its own host.
local function test_an_enterprise_servers_upload_path_is_its_own()
  local client, sent = live({ { reply("201 Created", "", "{}") } },
    { GITHUB_API_URL = "http://ghe.test/api/v3" })
  local ok, why = GithubApi.upload(client, "http://ghe.test/api/uploads/repos/o/r/releases/5/assets{?name}",
    "cosmic", "b")
  assert(ok, why)
  has(sent[1], "POST /api/uploads/repos/o/r/releases/5/assets?name=cosmic HTTP/1.1\r\n")
  ok = GithubApi.upload(client, "http://ghe.test/repos/o/r/releases/5/assets", "cosmic", "b")
  assert(not ok)
  assert(#sent == 1)
end

local function test_an_upload_fails_naming_githubs_refusal()
  local client = live({
    { reply("422 Unprocessable Entity", "", '{"message":"Validation Failed","errors":[{"code":"already_exists"}]}') },
    { reply("500 Internal Server Error", "", "oops") },
    { reply("302 Found", "Location: http://elsewhere.test/\r\n") } })
  local ok, why = GithubApi.upload(client, release_assets, "cosmic", "b")
  assert(not ok and why == "POST /repos/o/r/releases/5/assets (cosmic): HTTP 422: Validation Failed " ..
      "(the release holds an asset of that name)", why)
  ok, why = GithubApi.upload(client, release_assets, "cosmic", "b")
  assert(not ok and why == "POST /repos/o/r/releases/5/assets (cosmic): HTTP 500", why)
  ok, why = GithubApi.upload(client, release_assets, "cosmic", "b")
  assert(not ok and why:find("HTTP 302", 1, true), why)
  ok, why = GithubApi.upload(client, release_assets, "cosmic", "b")
  assert(not ok and why:find("POST /repos/o/r/releases/5/assets (cosmic): ", 1, true) == 1, why)
end

--- The upload origin takes the token only for an upload: a request to it
--- that is not one, and a page's next link to it, never do.
local function test_the_upload_origin_takes_the_token_for_uploads_alone()
  local client, sent = live({})
  local answered, why = client.send({ method = "GET", url = release_assets, headers = {} })
  assert(answered == nil and why:find("refusing to send the token", 1, true), tostring(why))
  answered, why = client.send({ method = "POST", url = "http://other.test/x", headers = {},
    upload = true })
  assert(answered == nil and why:find("refusing to send the token", 1, true), tostring(why))
  assert(#sent == 0)
end

local function test_the_upload_origin_takes_the_token_only_for_a_release_s_assets()
  local client, sent = live({})
  for _, path in ipairs({ "/", "/repos/o/r/releases", "/repos/o/r/contents/x",
      "/repos/o/../releases/5/assets" }) do
    local answered, why = client.send({ method = "POST", url = "http://uploads.test" .. path,
      headers = {}, body = "b", upload = true })
    assert(answered == nil and why:find("refusing to send the token", 1, true), path .. ": " .. tostring(why))
  end
  assert(#sent == 0)
end

local function test_an_upload_sets_the_type_it_is_given()
  local client, sent = live({ { reply("201 Created", "", "{}") } })
  assert(GithubApi.upload(client, release_assets, "source.json", "{}", "application/json"))
  has(sent[1], "\r\nContent-Type: application/json\r\n")
  assert(not sent[1]:find("octet-stream", 1, true), sent[1])
end

--- Asked for as bytes, the API may answer with them, not a redirect.
local function test_a_download_takes_the_bytes_when_the_api_answers_with_them(tmp: string)
  local client, sent = live({ { reply("200 OK", "Content-Type: application/octet-stream\r\n", "\0asset\255") } })
  local ok, why = GithubApi.download(client, "repos/o/r/releases/assets/5", tmp .. "/a",
    "application/octet-stream")
  assert(ok, why)
  has(sent[1], "\r\nAccept: application/octet-stream\r\n")
  assert(Fs.read(tmp .. "/a") == "\0asset\255")
  -- Without that ask a 200 is no file.
  client = live({ { reply("200 OK", "", "x") } })
  ok, why = GithubApi.download(client, "repos/o/r/z", tmp .. "/b")
  assert(not ok and why:find("no redirect to a file", 1, true), tostring(why))
  assert(not Fs.exists(tmp .. "/b"))
end

--- A client whose `send` answers each page after `cost_ns` of a clock
--- the test steps, recording the timeout each request was given.
local function stepped(pages: integer, cost_ns: integer): GithubApi.Client, {integer}
  local clock = 0
  local timeouts: {integer} = {}
  local function send(request: GithubApi.Request): GithubApi.Reply | nil, string
    timeouts[#timeouts + 1] = request.timeout_ns as integer
    clock = clock + cost_ns
    local number = #timeouts
    local head = {}
    if number < pages then head["link"] = '<http://api.test/next' .. number .. '>; rel="next"' end
    return { status = 200, headers = head, body = "[]" }, ""
  end
  return { send = send, fetch = nil as GithubApi.Fetch, base = "http://api.test",
    upload_origin = "", upload_path = "", now_ns = function(): integer return clock end }, timeouts
end

local function test_pages_share_one_deadline_so_each_gets_the_time_left()
  local client, timeouts = stepped(3, 300)
  local pages, why = GithubApi.pages(client, "repos/o/r/x", 1)
  assert(pages ~= nil and #pages == 3, why)
  assert(timeouts[1] == 1000000000 and timeouts[2] == 999999700 and timeouts[3] == 999999400,
    table.concat(timeouts, ","))
end

local function test_pages_that_are_each_timely_fail_once_the_total_runs_out()
  local client, timeouts = stepped(5, 400000000)
  local pages, why = GithubApi.pages(client, "repos/o/r/x", 1)
  assert(pages == nil, "succeeded past the budget")
  assert(why:find("page 4", 1, true) and why:find("ran out", 1, true), why)
  assert(#timeouts == 3, "a request began after the deadline: " .. #timeouts)
  assert(timeouts[1] > timeouts[2] and timeouts[2] > timeouts[3])
end
