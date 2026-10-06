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
--- fetches the redirect's URL, which [`Http.download`] is handed without
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
  assert(called and ok, tostring(ok) .. tostring(why))
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
  ok, why = GithubApi.download(failing, "repos/o/r/artifacts/3/zip", tmp .. "/z")
  Http.download_result = real
  -- The signed URL stays out of the message.
  assert(not ok and why == "GET repos/o/r/artifacts/3/zip: HTTP 403", why)
end
