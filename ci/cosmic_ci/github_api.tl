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
    --- How long the request may take, in nanoseconds; a minute where nil.
    timeout_ns: integer | nil
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
  -- [`cosmic.http`] reads no HTTPS_PROXY, which gh honoured. CI's runners
  -- are GitHub-hosted and reach the API directly, so none is needed.
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
    -- A redirect (a renamed repository's 301, say) fails the call rather
    -- than being followed: the token must not follow one.
    local response, trouble = Http.open(request.url, { method = request.method,
      headers = headers, body = request.body, follow = false,
      timeout_ns = request.timeout_ns or request_ns,
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

local function request_for(client: GithubApi.Client, method: string, path: string,
                           seconds?: integer): GithubApi.Request
  return { method = method, url = client.base .. "/" .. path, headers = {},
    timeout_ns = seconds and Clock.seconds(seconds) or nil }
end

--- What `reply` to a request for `path` says of a refusal, as an error.
local function refused(method: string, path: string, reply: GithubApi.Reply): string
  local said = message_of(reply.body)
  return method .. " " .. path .. ": HTTP " .. reply.status .. (said ~= "" and (": " .. said) or "")
end

local function succeeded(reply: GithubApi.Reply): boolean
  return reply.status >= 200 and reply.status <= 299
end

--- The body of GitHub's answer to a GET of `path` (relative to the API,
--- as "repos/o/r/actions/runs"), JSON text. Nil and why where there is
--- none or its status is not 2xx, the why naming the request, the
--- status and GitHub's message. A request that takes longer than
--- `seconds` (a minute where nil) fails.
function GithubApi.get(client: GithubApi.Client, path: string, seconds?: integer): string | nil, string
  local reply, why = client.send(request_for(client, "GET", path, seconds))
  if reply == nil then return nil, "GET " .. path .. ": " .. why end
  if not succeeded(reply) then return nil, refused("GET", path, reply) end
  return reply.body, ""
end

--- The URL the `Link` header's `rel="next"` names, nil where it has none.
local function next_link(link: string | nil): string | nil
  for target, params in (link or ""):gmatch("<([^>]*)>([^<]*)") do
    for param in params:gmatch("[^;,]+") do
      if param:match('^%s*rel%s*=%s*"?next"?%s*$') then return target end
    end
  end
  return nil
end

--- A GET that cannot loop for ever on a `Link` that points to itself.
local max_pages <const> = 1000

--- Every page of the list at `path`, as `get` asks the first and the
--- `Link` header's `rel="next"` URLs name the rest, each page decoded
--- (an object or an array). Nil and why where a request fails, a page is
--- not JSON, or the list runs past 1000 pages. A next URL on another
--- origin than the API's is refused by `send`, so it fails the listing
--- and never receives the token. `seconds` bounds each request.
function GithubApi.pages(client: GithubApi.Client, path: string, seconds?: integer): {any} | nil, string
  local pages: {any} = {}
  local request = request_for(client, "GET", path, seconds)
  local seen: {string:boolean} = { [request.url] = true }
  for number = 1, max_pages do
    local label = number == 1 and path or (path .. " (page " .. number .. ")")
    local reply, why = client.send(request)
    if reply == nil then return nil, "GET " .. label .. ": " .. why end
    if not succeeded(reply) then return nil, refused("GET", label, reply) end
    local page, trouble = Json.decode(reply.body)
    if not (page is table) then
      return nil, "GET " .. label .. ": " .. (trouble ~= "" and trouble or "not an object or an array")
    end
    pages[#pages + 1] = page
    local target = next_link(reply.headers.link)
    if target == nil then return pages, "" end
    if seen[target] then return nil, "GET " .. label .. ": the next page repeats " .. target end
    seen[target] = true
    request = { method = "GET", url = target, headers = {}, timeout_ns = request.timeout_ns }
  end
  return nil, "GET " .. path .. ": more than " .. max_pages .. " pages"
end

--- Deletes `path` (relative to the API): true, or false and why, naming
--- the request, the status and GitHub's message where it is not 2xx. A
--- request that takes longer than `seconds` (a minute where nil) fails.
function GithubApi.delete(client: GithubApi.Client, path: string, seconds?: integer): boolean, string
  local reply, why = client.send(request_for(client, "DELETE", path, seconds))
  if reply == nil then return false, "DELETE " .. path .. ": " .. why end
  if not succeeded(reply) then return false, refused("DELETE", path, reply) end
  return true, ""
end

--- Downloads what the API serves at `path` (a redirect to a file, as an
--- artifact's `.../zip`) to the file `to`: true, or false and why. The API
--- must answer with a redirect to an https URL, which is fetched
--- without the token.
function GithubApi.download(client: GithubApi.Client, path: string, to: string): boolean, string
  local reply, why = client.send(request_for(client, "GET", path))
  if reply == nil then return false, "GET " .. path .. ": " .. why end
  if not redirect_statuses[reply.status] then
    if reply.status >= 200 and reply.status <= 299 then
      return false, "GET " .. path .. ": HTTP " .. reply.status .. " with no redirect to a file"
    end
    return false, refused("GET", path, reply)
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
