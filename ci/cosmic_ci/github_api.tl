--- A small client of GitHub's REST API over [`cosmic.http`], for the CI
--- driver in place of the `gh` CLI.
---
--- A [`GithubApi.Client`] holds two functions the live one fills over
--- [`cosmic.http`], so a test can answer from a table instead. `send` makes
--- one request to the API and never follows a redirect. `fetch` downloads
--- one URL the API redirected to, and is never given the token.
---
--- The token goes only to the API's own origin, `GITHUB_API_URL`'s: a
--- download takes the API's redirect by hand and fetches its `Location`
--- without it, since that URL is a signed link to another host.
local Clock = require("cosmic.clock")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Stream = require("cosmic.stream")
local Url = require("cosmic.url")

local record GithubApi
  --- One request to the API. `url` is absolute; `headers` are the ones
  --- the caller adds to those every request carries.
  record Request
    method: string
    url: string
    headers: {string:string}
    body: string | nil
  end
  --- An answer, whatever its status; `headers` are keyed by lowercased name.
  record Reply
    status: integer
    headers: {string:string}
    body: string
  end
  --- Sends `request`; the answer, or nil and why none came.
  type Send = function(Request): Reply | nil, string
  --- Downloads `url`, a link the API gave, to `path`: true, or false and why.
  type Fetch = function(url: string, path: string): boolean, string
  record Client
    send: Send
    fetch: Fetch
    --- The API's origin and path prefix, without a trailing "/".
    base: string
  end
  --- What a test changes about [`GithubApi.live`]: `script` holds one
  --- list of canned replies ([`cosmic.http`]'s `script`) for each call
  --- of `send` or `fetch`, in order, and `sent` collects what each
  --- `send` wrote to its connection.
  record Live
    script: {{string}}
    sent: {string}
  end
end

local default_base <const> = "https://api.github.com"
local api_version <const> = "2022-11-28"
local user_agent <const> = "cosmic-ci"
local request_ns <const> = Clock.seconds(60)
local download_ns <const> = Clock.seconds(300)
--- The redirects a download follows after the API's own, all without
--- the token.
local download_redirects <const> = 3
local redirect_statuses: {integer:boolean} = { [301] = true, [302] = true, [303] = true,
  [307] = true, [308] = true }

local default_ports: {string:integer} = { https = 443, http = 80 }

--- The origin of `url`, as one string that equals another's only when
--- scheme, host and port do: the port is the scheme's default where the
--- URL names none, and an IPv6 host is bracketed. Nil and why for a URL
--- that does not parse or has a scheme with no default port.
local function origin_of(url: string): string | nil, string
  local parts, why = Url.parse(url)
  if parts == nil then return nil, why end
  local port = parts.port or default_ports[parts.scheme]
  if port == nil then return nil, "the scheme " .. parts.scheme .. " has no default port" end
  local host = parts.host:find(":", 1, true) and ("[" .. parts.host .. "]") or parts.host
  return parts.scheme .. "://" .. host .. ":" .. port, ""
end

--- GitHub's explanation in an error answer's body: its `message`, or "".
local function message_of(body: string): string
  local decoded = Json.decode_object(body)
  local message = decoded and decoded.message
  if message is string then return message end
  return ""
end

--- A client of the API for `env`: its token from `GH_TOKEN`, else
--- `GITHUB_TOKEN`, and its address from `GITHUB_API_URL` (api.github.com
--- by default). Nil and why where there is no token.
function GithubApi.live(env: {string:string}, test?: GithubApi.Live): GithubApi.Client | nil, string
  local token = env.GH_TOKEN
  if token == nil or token == "" then token = env.GITHUB_TOKEN end
  if token == nil or token == "" then
    -- A `gh auth login` is not read: the driver does not run gh, so a
    -- person with gh exports GH_TOKEN=$(gh auth token).
    return nil, "no GitHub token: set GH_TOKEN or GITHUB_TOKEN"
  end
  -- GITHUB_API_URL is trusted as given, plain http included: the tests'
  -- script transport cannot do TLS.
  local base = env.GITHUB_API_URL
  if base == nil or base == "" then base = default_base end
  base = (base:gsub("/+$", ""))
  local api_origin, why = origin_of(base)
  if api_origin == nil then return nil, "GITHUB_API_URL: " .. why end
  local calls = 0
  local function script(): {string} | nil
    calls = calls + 1
    return test and test.script and test.script[calls] or nil
  end

  local function send(request: GithubApi.Request): GithubApi.Reply | nil, string
    -- The token is the one thing this function must not hand to any other host.
    local target = origin_of(request.url)
    if target ~= api_origin then
      return nil, "refusing to send the token to " .. tostring(target or request.url)
    end
    local headers: {string:string} = {}
    for name, value in pairs(request.headers) do headers[name] = value end
    headers.Authorization = "Bearer " .. token
    headers.Accept = headers.Accept or "application/vnd.github+json"
    headers["X-GitHub-Api-Version"] = api_version
    headers["User-Agent"] = user_agent
    if request.body ~= nil then headers.Expect = "" end
    local response, trouble = Http.open(request.url, { method = request.method,
      headers = headers, body = request.body, follow = false, timeout_ns = request_ns,
      script = script() })
    if response == nil then return nil, trouble end
    local body, read_trouble = Stream.read_all(response)
    if test and test.sent then test.sent[#test.sent + 1] = response:sent() end
    local status, reply_headers = response.status, response.headers
    response:close()
    if body == nil then return nil, read_trouble end
    return { status = status, headers = reply_headers, body = body }, ""
  end

  local function fetch(url: string, path: string): boolean, string
    local result = Http.download_result(url, path, { headers = { ["User-Agent"] = user_agent },
      redirect_protocols = { "https" }, max_redirects = download_redirects,
      timeout_ns = download_ns, script = script() })
    if result.kind == "downloaded" then return true, "" end
    -- The URL is a signed link, so it stays out of the message.
    if result.kind == "http_status" then return false, "HTTP " .. tostring(result.status) end
    return false, result.reason
  end

  return { send = send, fetch = fetch, base = base }, ""
end

local function request_for(client: GithubApi.Client, path: string): GithubApi.Request
  return { method = "GET", url = client.base .. "/" .. path, headers = {} }
end

--- What `reply` to a request for `path` says of a refusal, as an error.
local function refused(path: string, reply: GithubApi.Reply): string
  local said = message_of(reply.body)
  return "GET " .. path .. ": HTTP " .. reply.status .. (said ~= "" and (": " .. said) or "")
end

--- The body of GitHub's answer to a GET of `path` (relative to the API,
--- as "repos/o/r/actions/runs"), JSON text. Nil and why where there is
--- none or its status is not 2xx, the why naming the request, the
--- status and GitHub's message.
function GithubApi.get(client: GithubApi.Client, path: string): string | nil, string
  local reply, why = client.send(request_for(client, path))
  if reply == nil then return nil, "GET " .. path .. ": " .. why end
  if reply.status < 200 or reply.status > 299 then return nil, refused(path, reply) end
  return reply.body, ""
end

--- Downloads what the API serves at `path` (a redirect to a file, as an
--- artifact's `.../zip`) to the file `to`: true, or false and why. The API
--- must answer with a redirect to an https URL, which is fetched
--- without the token.
function GithubApi.download(client: GithubApi.Client, path: string, to: string): boolean, string
  local reply, why = client.send(request_for(client, path))
  if reply == nil then return false, "GET " .. path .. ": " .. why end
  if not redirect_statuses[reply.status] then
    if reply.status >= 200 and reply.status <= 299 then
      return false, "GET " .. path .. ": HTTP " .. reply.status .. " with no redirect to a file"
    end
    return false, refused(path, reply)
  end
  local location = reply.headers.location
  local parts = location and Url.parse(location)
  if parts == nil or parts.scheme ~= "https" then
    return false, "GET " .. path .. ": HTTP " .. reply.status ..
      " redirects somewhere other than an https URL"
  end
  local fetched, trouble = client.fetch(location, to)
  if not fetched then return false, "GET " .. path .. ": " .. trouble end
  return true, ""
end

return GithubApi
